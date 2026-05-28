#!/usr/bin/env bash
# Measure control-plane convergence time under endpoint churn.
# Simultaneously scales deployments on all clusters, then polls istiod and
# sidecar admin endpoints to measure how long until the mesh converges.
#
# Usage:
#   ./tests/churn/002-run-churn-probe.sh --source-context CTX [options]
#
# Examples:
#   # 2-cluster churn test:
#   ./tests/churn/002-run-churn-probe.sh --source-context rosa-001 --remote-contexts rosa-002
#
#   # Scale 10 deployments from 1 to 10 replicas:
#   ./tests/churn/002-run-churn-probe.sh --source-context rosa-001 \
#     --deployment-count 10 --scale-to 10 --iterations 3
# ci-dry-run: --source-context ci-dummy
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

SOURCE_CTX=""
REMOTE_CONTEXTS_CSV=""
MESH_SIZE=""
DEPLOYMENT_COUNT="${CHURN_DEPLOYMENT_COUNT:-5}"
BASE_REPLICAS="${CHURN_BASE_REPLICAS:-1}"
SCALE_TO="${CHURN_SCALE_TO_REPLICAS:-5}"
ITERATIONS="${CHURN_ITERATIONS:-5}"
TIMEOUT_SEC="${CHURN_TIMEOUT_SEC:-120}"
POLL_INTERVAL_S="0.$(printf '%03d' "${CHURN_POLL_INTERVAL_MS:-250}")"
OUTPUT_DIR="${ROOT}/tests/churn/results"
DRY_RUN=0
NS="${CHURN_TEST_NAMESPACE:-churn-test}"
BASE_PF_PORT=15014
BASE_ENVOY_PF_PORT=15100

die() { echo "error: $*" >&2; exit 1; }

# Portable nanosecond-resolution Unix timestamp. macOS BSD `date` does not
# support `%N`, so we detect the best available source once and cache it.
NOW_NS_IMPL=""
_detect_now_ns() {
	[[ -n "$NOW_NS_IMPL" ]] && return
	if [[ "$(date -u +%s%N 2>/dev/null)" =~ ^[0-9]+$ ]]; then
		NOW_NS_IMPL="date"
	elif command -v gdate >/dev/null 2>&1 \
		&& [[ "$(gdate -u +%s%N 2>/dev/null)" =~ ^[0-9]+$ ]]; then
		NOW_NS_IMPL="gdate"
	elif command -v python3 >/dev/null 2>&1; then
		NOW_NS_IMPL="python3"
	elif command -v perl >/dev/null 2>&1; then
		NOW_NS_IMPL="perl"
	else
		die "no nanosecond-resolution time source: install GNU coreutils (gdate), python3, or perl"
	fi
}
now_ns() {
	_detect_now_ns
	case "$NOW_NS_IMPL" in
	date)    date -u +%s%N ;;
	gdate)   gdate -u +%s%N ;;
	python3) python3 -c 'import time; print(int(time.time()*1e9))' ;;
	perl)    perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time()*1e9' ;;
	esac
}

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --source-context CTX     Kube context for the source cluster (required).
  --remote-contexts CSV    Remote cluster contexts (comma-separated).
  --mesh-size N            Metadata tag (default: 1 + remotes).
  --deployment-count N     Churn target deployments (default: $DEPLOYMENT_COUNT).
  --scale-to N             Scale targets to N replicas (default: $SCALE_TO).
  --iterations N           Number of churn iterations (default: $ITERATIONS).
  --timeout SEC            Timeout per iteration (default: $TIMEOUT_SEC).
  --output-dir DIR         Results directory (default: tests/churn/results).
  --dry-run                Show plan without executing.
  -h, --help               Show this help.
EOF
}

split_csv() {
	local csv="$1"
	local -n _out="$2"
	_out=()
	local x
	IFS=',' read -ra _raw <<<"$csv"
	for x in "${_raw[@]}"; do
		x="${x#"${x%%[![:space:]]*}"}"
		x="${x%"${x##*[![:space:]]}"}"
		[[ -n "$x" ]] && _out+=("$x")
	done
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--source-context)
		[[ -n "${2:-}" ]] || die "--source-context requires a value"
		SOURCE_CTX="$2"
		shift 2
		;;
	--remote-contexts)
		[[ -n "${2:-}" ]] || die "--remote-contexts requires a value"
		REMOTE_CONTEXTS_CSV="$2"
		shift 2
		;;
	--mesh-size)
		[[ -n "${2:-}" ]] || die "--mesh-size requires a value"
		MESH_SIZE="$2"
		shift 2
		;;
	--deployment-count)
		[[ -n "${2:-}" ]] || die "--deployment-count requires a value"
		DEPLOYMENT_COUNT="$2"
		shift 2
		;;
	--scale-to)
		[[ -n "${2:-}" ]] || die "--scale-to requires a value"
		SCALE_TO="$2"
		shift 2
		;;
	--iterations)
		[[ -n "${2:-}" ]] || die "--iterations requires a value"
		ITERATIONS="$2"
		shift 2
		;;
	--timeout)
		[[ -n "${2:-}" ]] || die "--timeout requires a value"
		TIMEOUT_SEC="$2"
		shift 2
		;;
	--output-dir)
		[[ -n "${2:-}" ]] || die "--output-dir requires a value"
		OUTPUT_DIR="$2"
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown option: $1 (try --help)"
		;;
	esac
done

[[ -n "$SOURCE_CTX" ]] || die "--source-context is required"

if command -v oc >/dev/null 2>&1; then
	KUBECTL=(oc)
elif command -v kubectl >/dev/null 2>&1; then
	KUBECTL=(kubectl)
else
	die "neither oc nor kubectl found on PATH"
fi

command -v curl >/dev/null 2>&1 || die "curl not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

REMOTES=()
if [[ -n "$REMOTE_CONTEXTS_CSV" ]]; then
	split_csv "$REMOTE_CONTEXTS_CSV" REMOTES
fi

[[ -z "$MESH_SIZE" ]] && MESH_SIZE=$(( 1 + ${#REMOTES[@]} ))
ALL_CTXS=("$SOURCE_CTX" "${REMOTES[@]}")

RUN_ID="$(date +%Y%m%dT%H%M%S)-$$"
mkdir -p "$OUTPUT_DIR"
TSV_FILE="${OUTPUT_DIR}/churn-${RUN_ID}.tsv"

if ((DRY_RUN)); then
	echo "=== Dry-run: churn probe ==="
	echo "Source: $SOURCE_CTX | Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
	echo "Deployments: $DEPLOYMENT_COUNT | Scale: $BASE_REPLICAS -> $SCALE_TO | Iterations: $ITERATIONS"
	exit 0
fi

cat > "$TSV_FILE" <<EOF
# Churn convergence test — $(date -Iseconds)
# Source: $SOURCE_CTX  Remotes: ${REMOTES[*]:-none}  Mesh size: $MESH_SIZE
# Deployments: $DEPLOYMENT_COUNT  Scale: $BASE_REPLICAS -> $SCALE_TO  Iterations: $ITERATIONS
EOF
echo -e "run_id\tmesh_size\tchurn_intensity\titeration\tt0_epoch_ns\tconvergence_local_ms\tconvergence_remote_ms\tpush_triggers_delta\txds_pushes_delta\tqueue_time_p99_ms\tstatus" >> "$TSV_FILE"

PF_PIDS=()
POLL_PIDS=()

cleanup() {
	for pid in "${POLL_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
	POLL_PIDS=()
	for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
	PF_PIDS=()
}
trap cleanup EXIT

start_port_forward() {
	local ctx="$1" local_port="$2"
	"${KUBECTL[@]}" --context="$ctx" -n istio-system port-forward svc/istiod "$local_port":15014 >/dev/null 2>&1 &
	PF_PIDS+=($!)
	local attempts=0
	while ! curl -s -o /dev/null "http://localhost:$local_port/debug/syncz" 2>/dev/null; do
		attempts=$((attempts + 1))
		((attempts > 30)) && die "port-forward to istiod on $ctx (port $local_port) failed"
		sleep 0.5
	done
}

start_envoy_port_forward() {
	local ctx="$1" local_port="$2"
	"${KUBECTL[@]}" --context="$ctx" -n "$NS" port-forward deploy/churn-watcher "$local_port":15000 >/dev/null 2>&1 &
	PF_PIDS+=($!)
	local attempts=0
	while ! curl -s -o /dev/null "http://localhost:$local_port/clusters" 2>/dev/null; do
		attempts=$((attempts + 1))
		((attempts > 30)) && die "port-forward to watcher envoy on $ctx (port $local_port) failed"
		sleep 0.5
	done
}

get_counter() {
	local port="$1" name="$2"
	curl -s "http://localhost:$port/metrics" 2>/dev/null | awk -v name="^${name}" '$0 ~ name && !/^#/ { sum += $NF } END { printf "%.0f\n", sum+0 }'
}

get_histogram_p99() {
	local port="$1" name="$2"
	curl -s "http://localhost:$port/metrics" 2>/dev/null | awk -v name="${name}_bucket" -v q="0.99" '
	$0 ~ name && /le="/ {
		line = $0
		sub(/.*le="/, "", line); sub(/".*/, "", line); le = line
		count = $NF + 0
		buckets[++n] = le " " count
	}
	END {
		if(n==0) { print "N/A"; exit }
		total=0; for(i=1;i<=n;i++) { split(buckets[i],p," "); total=p[2] }
		target = total * q
		for(i=1;i<=n;i++) {
			split(buckets[i], p, " ")
			if(p[2]+0 >= target) { v=p[1]; if(v=="+Inf") v=0; printf "%.0f\n", v*1000; exit }
		}
		print "N/A"
	}'
}

bucket_range() {
	local v="${1:-0}"
	[[ "$v" == "N/A" ]] && { echo "N/A"; return; }
	(( v <= 0 ))     && { echo "N/A"; return; }
	(( v <= 100 ))   && { echo "0-100"; return; }
	(( v <= 500 ))   && { echo "100-500"; return; }
	(( v <= 1000 ))  && { echo "500-1000"; return; }
	(( v <= 3000 ))  && { echo "1000-3000"; return; }
	(( v <= 5000 ))  && { echo "3000-5000"; return; }
	(( v <= 10000 )) && { echo "5000-10000"; return; }
	(( v <= 20000 )) && { echo "10000-20000"; return; }
	(( v <= 30000 )) && { echo "20000-30000"; return; }
	echo ">30000"
}

poll_syncz_converged() {
	local port="$1" t0="$2" result_file="$3"
	local deadline=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	while true; do
		local now_ms=$(now_ns)
		now_ms=$(( now_ms / 1000000 ))
		((now_ms > deadline)) && echo "TIMEOUT" > "$result_file" && return
		local syncz stale
		syncz=$(curl -s "http://localhost:$port/debug/syncz" 2>/dev/null) || { sleep "$POLL_INTERVAL_S"; continue; }
		stale=$(echo "$syncz" | jq -r '[.[] | select(.proxy_status != null) | select(.proxy_status | to_entries | map(select(.value != "SYNCED")) | length > 0)] | length' 2>/dev/null) || { sleep "$POLL_INTERVAL_S"; continue; }
		if [[ "$stale" == "0" ]]; then
			now_ns > "$result_file"
			return
		fi
		sleep "$POLL_INTERVAL_S"
	done
}

poll_endpoint_count_changed() {
	local envoy_port="$1" t0="$2" baseline_count="$3" result_file="$4"
	local deadline=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	while true; do
		local now_ms=$(now_ns)
		now_ms=$(( now_ms / 1000000 ))
		((now_ms > deadline)) && echo "TIMEOUT" > "$result_file" && return
		local clusters count
		clusters=$(curl -s "http://localhost:$envoy_port/clusters" 2>/dev/null) || { sleep "$POLL_INTERVAL_S"; continue; }
		count=$(echo "$clusters" | grep -c "churn-target.*health_flags::healthy" || true)
		if ((count > baseline_count)); then
			now_ns > "$result_file"
			return
		fi
		sleep "$POLL_INTERVAL_S"
	done
}

compute_delta_ms() {
	local result_file="$1" t0="$2"
	local ts
	ts=$(<"$result_file")
	if [[ "$ts" == "TIMEOUT" ]]; then echo "TIMEOUT"; return; fi
	echo $(( (ts - t0) / 1000000 ))
}

echo "=== Churn convergence probe ==="
echo "Source: $SOURCE_CTX | Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
echo "Deployments: $DEPLOYMENT_COUNT | Scale: $BASE_REPLICAS -> $SCALE_TO"
echo "Iterations: $ITERATIONS | Timeout: ${TIMEOUT_SEC}s"
echo ""

echo "Starting port-forwards..."
start_port_forward "$SOURCE_CTX" "$BASE_PF_PORT"
for i in "${!REMOTES[@]}"; do
	start_port_forward "${REMOTES[i]}" $(( BASE_PF_PORT + i + 1 ))
	start_envoy_port_forward "${REMOTES[i]}" $(( BASE_ENVOY_PF_PORT + i ))
done
echo "Port-forwards ready."

TMPDIR_RUN=$(mktemp -d)
trap 'cleanup; rm -rf "$TMPDIR_RUN"' EXIT

for ((iter = 1; iter <= ITERATIONS; iter++)); do
	echo ""
	echo "--- Iteration $iter/$ITERATIONS ---"

	pre_triggers=$(get_counter "$BASE_PF_PORT" "pilot_push_triggers")
	pre_pushes=$(get_counter "$BASE_PF_PORT" "pilot_xds_pushes")

	BASELINE_COUNTS=()
	for i in "${!REMOTES[@]}"; do
		envoy_port=$(( BASE_ENVOY_PF_PORT + i ))
		bc=$(curl -s "http://localhost:$envoy_port/clusters" 2>/dev/null | grep -c "churn-target.*health_flags::healthy" || echo 0)
		BASELINE_COUNTS+=("$bc")
	done

	T0=$(now_ns)
	echo "  Scaling $DEPLOYMENT_COUNT deployments to $SCALE_TO replicas on all clusters..."
	SCALE_PIDS=()
	for ctx in "${ALL_CTXS[@]}"; do
		for ((d = 0; d < DEPLOYMENT_COUNT; d++)); do
			"${KUBECTL[@]}" --context="$ctx" -n "$NS" scale deployment/churn-target-${d} --replicas="$SCALE_TO" >/dev/null 2>&1 &
			SCALE_PIDS+=($!)
		done
	done
	for pid in "${SCALE_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done

	LOCAL_FILE="$TMPDIR_RUN/local_conv"
	echo "" > "$LOCAL_FILE"
	poll_syncz_converged "$BASE_PF_PORT" "$T0" "$LOCAL_FILE" &
	POLL_PIDS=($!)

	REMOTE_FILES=()
	for i in "${!REMOTES[@]}"; do
		rf="$TMPDIR_RUN/remote_${i}"
		echo "" > "$rf"
		REMOTE_FILES+=("$rf")
		poll_endpoint_count_changed $(( BASE_ENVOY_PF_PORT + i )) "$T0" "${BASELINE_COUNTS[i]}" "$rf" &
		POLL_PIDS+=($!)
	done

	for pid in "${POLL_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
	POLL_PIDS=()

	conv_local=$(compute_delta_ms "$LOCAL_FILE" "$T0")
	echo "  Convergence (local syncz): ${conv_local}ms"

	conv_remote="N/A"
	if [[ ${#REMOTES[@]} -gt 0 ]]; then
		max_remote=0
		all_ok=1
		for i in "${!REMOTES[@]}"; do
			r=$(compute_delta_ms "${REMOTE_FILES[i]}" "$T0")
			echo "  Convergence (remote ${REMOTES[i]}): ${r}ms"
			if [[ "$r" == "TIMEOUT" ]]; then
				all_ok=0
			elif ((r > max_remote)); then
				max_remote="$r"
			fi
		done
		if ((all_ok)); then conv_remote="$max_remote"; else conv_remote="TIMEOUT"; fi
	fi

	post_triggers=$(get_counter "$BASE_PF_PORT" "pilot_push_triggers")
	post_pushes=$(get_counter "$BASE_PF_PORT" "pilot_xds_pushes")
	triggers_delta=$((post_triggers - pre_triggers))
	pushes_delta=$((post_pushes - pre_pushes))
	queue_p99=$(get_histogram_p99 "$BASE_PF_PORT" "pilot_proxy_queue_time")

	echo "  Push triggers delta: $triggers_delta  xDS pushes delta: $pushes_delta  Queue p99: $(bucket_range "$queue_p99")ms"

	status="OK"
	[[ "$conv_local" == "TIMEOUT" ]] && status="TIMEOUT_LOCAL"
	[[ "$conv_remote" == "TIMEOUT" ]] && status="TIMEOUT_REMOTE"

	echo -e "${RUN_ID}\t${MESH_SIZE}\t${DEPLOYMENT_COUNT}\t${iter}\t${T0}\t${conv_local}\t${conv_remote}\t${triggers_delta}\t${pushes_delta}\t${queue_p99}\t${status}" >> "$TSV_FILE"

	echo "  Scaling back to $BASE_REPLICAS replicas..."
	SCALE_PIDS=()
	for ctx in "${ALL_CTXS[@]}"; do
		for ((d = 0; d < DEPLOYMENT_COUNT; d++)); do
			"${KUBECTL[@]}" --context="$ctx" -n "$NS" scale deployment/churn-target-${d} --replicas="$BASE_REPLICAS" >/dev/null 2>&1 &
			SCALE_PIDS+=($!)
		done
	done
	for pid in "${SCALE_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done

	if ((iter < ITERATIONS)); then
		echo "  Waiting for scale-down to settle..."
		sleep 5
	fi
done

echo ""
echo "Results written to $TSV_FILE"

MD_FILE="${OUTPUT_DIR}/churn-${RUN_ID}.md"
{
	echo "# Churn Convergence Results"
	echo ""
	echo "| Field | Value |"
	echo "|-------|-------|"
	echo "| Run ID | \`${RUN_ID}\` |"
	echo "| Date | $(date -Iseconds) |"
	echo "| Source | ${SOURCE_CTX} |"
	echo "| Remotes | ${REMOTES[*]:-none} |"
	echo "| Mesh size | ${MESH_SIZE} |"
	echo "| Deployments | ${DEPLOYMENT_COUNT} |"
	echo "| Scale range | ${BASE_REPLICAS} -> ${SCALE_TO} |"
	echo "| Iterations | ${ITERATIONS} |"
	echo "| Timeout | ${TIMEOUT_SEC}s |"
	echo ""
	echo "## Summary"
	echo ""
	echo "| Iteration | Local (ms) | Remote (ms) | Push Triggers | xDS Pushes | Queue p99 (ms) | Status |"
	echo "|-----------|------------|-------------|---------------|------------|----------------|--------|"
	awk -F'\t' '
	function bucket_range(upper_ms) {
		if (upper_ms+0 <= 0)     return "N/A"
		if (upper_ms+0 <= 100)   return "0-100"
		if (upper_ms+0 <= 500)   return "100-500"
		if (upper_ms+0 <= 1000)  return "500-1000"
		if (upper_ms+0 <= 3000)  return "1000-3000"
		if (upper_ms+0 <= 5000)  return "3000-5000"
		if (upper_ms+0 <= 10000) return "5000-10000"
		if (upper_ms+0 <= 20000) return "10000-20000"
		if (upper_ms+0 <= 30000) return "20000-30000"
		return ">30000"
	}
	!/^#/ && !/^run_id/ && NF>=11 {
		printf "| %s | %s | %s | %s | %s | %s | %s |\n", $4, $6, $7, $8, $9, bucket_range($10), $11
	}' "$TSV_FILE"
	echo ""
	echo "## Raw Data"
	echo ""
	echo "TSV: [\`$(basename "$TSV_FILE")\`]($(basename "$TSV_FILE"))"
} > "$MD_FILE"
echo "Summary written to $MD_FILE"

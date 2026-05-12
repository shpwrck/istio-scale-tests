#!/usr/bin/env bash
# Measure endpoint propagation latency across a multi-cluster Istio mesh.
# Deploys a canary service on a source cluster, then polls istiod debug endpoints
# and sidecar proxy-config on remote clusters to measure wall-clock propagation time.
#
# Usage:
#   ./propagation-test/002-run-endpoint-probe.sh --source-context CTX [--remote-contexts CSV] [options]
#
# Examples:
#   # Measure 2-cluster propagation, 10 iterations:
#   ./propagation-test/002-run-endpoint-probe.sh --source-context rosa-001 --remote-contexts rosa-002
#
#   # Measure single-cluster baseline (local xDS push only):
#   ./propagation-test/002-run-endpoint-probe.sh --source-context rosa-001 --mesh-size 1
#
#   # 3-cluster sweep, 5 iterations:
#   ./propagation-test/002-run-endpoint-probe.sh --source-context rosa-001 \
#     --remote-contexts rosa-002,rosa-003 --mesh-size 3 --iterations 5
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

SOURCE_CTX=""
REMOTE_CONTEXTS_CSV=""
MESH_SIZE=""
ITERATIONS="${PROPAGATION_ITERATIONS}"
PAUSE_SEC="${PROPAGATION_PAUSE_SEC}"
TIMEOUT_SEC="${PROPAGATION_TIMEOUT_SEC}"
POLL_INTERVAL_S="0.$(printf '%03d' "$((PROPAGATION_POLL_INTERVAL_MS))")"
OUTPUT_DIR="${ROOT}/propagation-test/results"
DRY_RUN=0
KEEP_CANARY=0
NS="${PROPAGATION_TEST_NAMESPACE}"
BASE_PF_PORT=15014
CHART_DIR="${ROOT}/charts/propagation-test"

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --source-context CTX      Kube context for the source cluster (required).
  --remote-contexts CSV     Remote cluster contexts (comma-separated). Omit for single-cluster baseline.
  --mesh-size N             Metadata tag for TSV output (default: 1 + number of remotes).
  --iterations N            Number of probe iterations (default: \$PROPAGATION_ITERATIONS=$ITERATIONS).
  --pause SEC               Seconds between iterations (default: \$PROPAGATION_PAUSE_SEC=$PAUSE_SEC).
  --timeout SEC             Timeout per iteration (default: \$PROPAGATION_TIMEOUT_SEC=$TIMEOUT_SEC).
  --poll-interval-ms MS     Poll interval in ms (default: \$PROPAGATION_POLL_INTERVAL_MS).
  --output-dir DIR          Results directory (default: propagation-test/results).
  --keep-canary             Do not delete canary after the final iteration.
  --dry-run                 Render and print canary manifests without applying.
  -h, --help                Show this help.

Environment:
  SETUP_CONTEXTS, PROPAGATION_TEST_NAMESPACE, PROPAGATION_POLL_INTERVAL_MS,
  PROPAGATION_TIMEOUT_SEC, PROPAGATION_ITERATIONS, PROPAGATION_PAUSE_SEC.
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
	--iterations)
		[[ -n "${2:-}" ]] || die "--iterations requires a value"
		ITERATIONS="$2"
		shift 2
		;;
	--pause)
		[[ -n "${2:-}" ]] || die "--pause requires a value"
		PAUSE_SEC="$2"
		shift 2
		;;
	--timeout)
		[[ -n "${2:-}" ]] || die "--timeout requires a value"
		TIMEOUT_SEC="$2"
		shift 2
		;;
	--poll-interval-ms)
		[[ -n "${2:-}" ]] || die "--poll-interval-ms requires a value"
		POLL_INTERVAL_S="0.$(printf '%03d' "$2")"
		shift 2
		;;
	--output-dir)
		[[ -n "${2:-}" ]] || die "--output-dir requires a value"
		OUTPUT_DIR="$2"
		shift 2
		;;
	--keep-canary)
		KEEP_CANARY=1
		shift
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

command -v helm >/dev/null 2>&1 || die "helm not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
command -v curl >/dev/null 2>&1 || die "curl not found on PATH"
command -v istioctl >/dev/null 2>&1 || die "istioctl not found on PATH"

REMOTES=()
if [[ -n "$REMOTE_CONTEXTS_CSV" ]]; then
	split_csv "$REMOTE_CONTEXTS_CSV" REMOTES
fi

if [[ -z "$MESH_SIZE" ]]; then
	MESH_SIZE=$(( 1 + ${#REMOTES[@]} ))
fi

RUN_ID="$(date +%Y%m%dT%H%M%S)-$$"
mkdir -p "$OUTPUT_DIR"
TSV_FILE="${OUTPUT_DIR}/endpoint-${RUN_ID}.tsv"

if ((DRY_RUN)); then
	echo "=== Dry-run: canary manifests for source context $SOURCE_CTX ==="
	helm template propagation-test "$CHART_DIR" \
		--set clusterName="$SOURCE_CTX" \
		--set namespace="$NS" \
		--set canary.enabled=true \
		--set canary.runId="$RUN_ID"
	exit 0
fi

cat > "$TSV_FILE" <<EOF
# Endpoint propagation latency test — $(date -Iseconds)
# Source: $SOURCE_CTX  Remotes: ${REMOTES[*]:-none}  Mesh size: $MESH_SIZE
# Iterations: $ITERATIONS  Poll interval: ${POLL_INTERVAL_S}s  Timeout: ${TIMEOUT_SEC}s
EOF
echo -e "run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_local_ms\tp2_discovery_ms\tp3_dataplane_ms\tstatus" >> "$TSV_FILE"

PF_PIDS=()

cleanup_port_forwards() {
	for pid in "${PF_PIDS[@]}"; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	PF_PIDS=()
}

trap cleanup_port_forwards EXIT

start_port_forward() {
	local ctx="$1" local_port="$2"
	"${KUBECTL[@]}" --context="$ctx" -n istio-system port-forward svc/istiod "$local_port":15014 >/dev/null 2>&1 &
	PF_PIDS+=($!)
	local attempts=0
	while ! curl -s -o /dev/null "http://localhost:$local_port/debug/syncz" 2>/dev/null; do
		((attempts++))
		((attempts > 30)) && die "port-forward to istiod on $ctx (port $local_port) failed to connect"
		sleep 0.5
	done
}

poll_p1_local_sync() {
	local port="$1" t0="$2" result_file="$3"
	local deadline=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	while true; do
		local now_ms=$(( $(date +%s%N) / 1000000 ))
		((now_ms > deadline)) && echo "TIMEOUT" > "$result_file" && return
		local synced=1
		local syncz
		syncz=$(curl -s "http://localhost:$port/debug/syncz" 2>/dev/null) || { sleep "$POLL_INTERVAL_S"; continue; }
		local stale
		stale=$(echo "$syncz" | jq -r '[.[] | select(.proxy_status != null) | select(.proxy_status | to_entries | map(select(.value != "SYNCED")) | length > 0)] | length' 2>/dev/null) || { sleep "$POLL_INTERVAL_S"; continue; }
		if [[ "$stale" == "0" ]]; then
			echo "$(date +%s%N)" > "$result_file"
			return
		fi
		sleep "$POLL_INTERVAL_S"
	done
}

poll_p2_remote_discovery() {
	local port="$1" t0="$2" result_file="$3"
	local deadline=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	while true; do
		local now_ms=$(( $(date +%s%N) / 1000000 ))
		((now_ms > deadline)) && echo "TIMEOUT" > "$result_file" && return
		local endpoints
		endpoints=$(curl -s "http://localhost:$port/debug/endpointz" 2>/dev/null) || { sleep "$POLL_INTERVAL_S"; continue; }
		if echo "$endpoints" | grep -q "propagation-canary"; then
			echo "$(date +%s%N)" > "$result_file"
			return
		fi
		sleep "$POLL_INTERVAL_S"
	done
}

poll_p3_sidecar_endpoints() {
	local remote_ctx="$1" t0="$2" result_file="$3"
	local deadline=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	while true; do
		local now_ms=$(( $(date +%s%N) / 1000000 ))
		((now_ms > deadline)) && echo "TIMEOUT" > "$result_file" && return
		local ep
		ep=$(istioctl proxy-config endpoints deploy/propagation-watcher \
			-n "$NS" --context="$remote_ctx" 2>/dev/null) || { sleep "$POLL_INTERVAL_S"; continue; }
		if echo "$ep" | grep -q "propagation-canary.*HEALTHY"; then
			echo "$(date +%s%N)" > "$result_file"
			return
		fi
		sleep "$POLL_INTERVAL_S"
	done
}

compute_delta_ms() {
	local result_file="$1" t0="$2"
	local ts
	ts=$(<"$result_file")
	if [[ "$ts" == "TIMEOUT" ]]; then
		echo "TIMEOUT"
		return
	fi
	echo $(( (ts - t0) / 1000000 ))
}

echo "=== Endpoint propagation probe ==="
echo "Source: $SOURCE_CTX | Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
echo "Iterations: $ITERATIONS | Timeout: ${TIMEOUT_SEC}s | Pause: ${PAUSE_SEC}s"
echo ""

echo "Starting port-forwards to istiod..."
start_port_forward "$SOURCE_CTX" "$BASE_PF_PORT"
for i in "${!REMOTES[@]}"; do
	start_port_forward "${REMOTES[i]}" $(( BASE_PF_PORT + i + 1 ))
done
echo "Port-forwards ready."

TMPDIR_RUN=$(mktemp -d)
trap 'cleanup_port_forwards; rm -rf "$TMPDIR_RUN"' EXIT

for ((iter = 1; iter <= ITERATIONS; iter++)); do
	echo ""
	echo "--- Iteration $iter/$ITERATIONS ---"

	ITER_RUN_ID="${RUN_ID}-${iter}"
	T0=$(date +%s%N)

	echo "  Deploying canary on $SOURCE_CTX..."
	helm template propagation-test "$CHART_DIR" \
		--set clusterName="$SOURCE_CTX" \
		--set namespace="$NS" \
		--set canary.enabled=true \
		--set canary.runId="$ITER_RUN_ID" \
		| "${KUBECTL[@]}" apply --context="$SOURCE_CTX" -f - >/dev/null

	P1_FILE="$TMPDIR_RUN/p1"
	echo "" > "$P1_FILE"
	poll_p1_local_sync "$BASE_PF_PORT" "$T0" "$P1_FILE" &
	POLL_PIDS=($!)

	P2_FILES=()
	P3_FILES=()
	for i in "${!REMOTES[@]}"; do
		p2f="$TMPDIR_RUN/p2_${i}"
		p3f="$TMPDIR_RUN/p3_${i}"
		echo "" > "$p2f"
		echo "" > "$p3f"
		P2_FILES+=("$p2f")
		P3_FILES+=("$p3f")
		poll_p2_remote_discovery $(( BASE_PF_PORT + i + 1 )) "$T0" "$p2f" &
		POLL_PIDS+=($!)
		poll_p3_sidecar_endpoints "${REMOTES[i]}" "$T0" "$p3f" &
		POLL_PIDS+=($!)
	done

	for pid in "${POLL_PIDS[@]}"; do
		wait "$pid" 2>/dev/null || true
	done

	p1_ms=$(compute_delta_ms "$P1_FILE" "$T0")
	echo "  P1 (local xDS push): ${p1_ms}ms"

	if [[ ${#REMOTES[@]} -eq 0 ]]; then
		status="OK"
		[[ "$p1_ms" == "TIMEOUT" ]] && status="TIMEOUT_P1"
		echo -e "${RUN_ID}\t${MESH_SIZE}\t${iter}\t${SOURCE_CTX}\tN/A\t${T0}\t${p1_ms}\tN/A\tN/A\t${status}" >> "$TSV_FILE"
	else
		for i in "${!REMOTES[@]}"; do
			p2_ms=$(compute_delta_ms "${P2_FILES[i]}" "$T0")
			p3_ms=$(compute_delta_ms "${P3_FILES[i]}" "$T0")
			echo "  P2 (remote istiod ${REMOTES[i]}): ${p2_ms}ms"
			echo "  P3 (remote sidecar ${REMOTES[i]}): ${p3_ms}ms"

			status="OK"
			[[ "$p1_ms" == "TIMEOUT" ]] && status="TIMEOUT_P1"
			[[ "$p2_ms" == "TIMEOUT" ]] && status="TIMEOUT_P2"
			[[ "$p3_ms" == "TIMEOUT" ]] && status="TIMEOUT_P3"
			[[ "$p1_ms" == "TIMEOUT" && "$p2_ms" == "TIMEOUT" && "$p3_ms" == "TIMEOUT" ]] && status="TIMEOUT_ALL"

			echo -e "${RUN_ID}\t${MESH_SIZE}\t${iter}\t${SOURCE_CTX}\t${REMOTES[i]}\t${T0}\t${p1_ms}\t${p2_ms}\t${p3_ms}\t${status}" >> "$TSV_FILE"
		done
	fi

	if ((iter < ITERATIONS)) || ((! KEEP_CANARY)); then
		echo "  Cleaning up canary..."
		"${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" delete deploy/propagation-canary svc/propagation-canary --ignore-not-found=true >/dev/null
	fi

	if ((iter < ITERATIONS)); then
		echo "  Pausing ${PAUSE_SEC}s..."
		sleep "$PAUSE_SEC"
	fi
done

echo ""
echo "=== Results written to $TSV_FILE ==="
echo ""
echo "Summary:"
if [[ ${#REMOTES[@]} -eq 0 ]]; then
	awk -F'\t' 'NR>1 && !/^#/ && $7 != "TIMEOUT" {
		sum+=$7; n++; if(!min||$7<min)min=$7; if($7>max)max=$7
	} END {
		if(n>0) printf "  P1 local: n=%d min=%dms max=%dms avg=%dms\n", n, min, max, sum/n
		else print "  No successful measurements."
	}' "$TSV_FILE"
else
	awk -F'\t' 'NR>1 && !/^#/ {
		if($7!="TIMEOUT"){p1s+=$7;p1n++;if(!p1min||$7<p1min)p1min=$7;if($7>p1max)p1max=$7}
		if($8!="TIMEOUT"){p2s+=$8;p2n++;if(!p2min||$8<p2min)p2min=$8;if($8>p2max)p2max=$8}
		if($9!="TIMEOUT"){p3s+=$9;p3n++;if(!p3min||$9<p3min)p3min=$9;if($9>p3max)p3max=$9}
	} END {
		if(p1n>0) printf "  P1 local xDS push:     n=%d min=%dms max=%dms avg=%dms\n", p1n, p1min, p1max, p1s/p1n
		if(p2n>0) printf "  P2 remote istiod disc: n=%d min=%dms max=%dms avg=%dms\n", p2n, p2min, p2max, p2s/p2n
		if(p3n>0) printf "  P3 remote sidecar:     n=%d min=%dms max=%dms avg=%dms\n", p3n, p3min, p3max, p3s/p3n
	}' "$TSV_FILE"
fi

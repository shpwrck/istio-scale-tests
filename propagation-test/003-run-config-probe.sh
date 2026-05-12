#!/usr/bin/env bash
# Measure config (VirtualService / DestinationRule) propagation latency across a multi-cluster Istio mesh.
# Applies Istio routing config on a source cluster, then polls remote cluster sidecars to measure
# how long until the configuration is reflected.
#
# Prerequisites: canary service must already be deployed on the source cluster.
#   Run 002-run-endpoint-probe.sh with --keep-canary first, or deploy manually:
#   helm template propagation-test charts/propagation-test --set canary.enabled=true | oc apply -f -
#
# Usage:
#   ./propagation-test/003-run-config-probe.sh --source-context CTX [--remote-contexts CSV] [options]
#
# Examples:
#   # Measure VirtualService propagation:
#   ./propagation-test/003-run-config-probe.sh --source-context rosa-001 --remote-contexts rosa-002
#
#   # Measure both VirtualService and DestinationRule:
#   ./propagation-test/003-run-config-probe.sh --source-context rosa-001 \
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
  --dry-run                 Render and print manifests without applying.
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
TSV_FILE="${OUTPUT_DIR}/config-${RUN_ID}.tsv"

if ((DRY_RUN)); then
	echo "=== Dry-run: VirtualService manifest ==="
	helm template propagation-test "$CHART_DIR" \
		--set clusterName="$SOURCE_CTX" \
		--set namespace="$NS" \
		--set canary.enabled=true \
		--set canary.virtualservice.enabled=true \
		--set canary.destinationrule.enabled=true
	exit 0
fi

# Verify canary exists on source cluster
"${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" get deploy/propagation-canary >/dev/null 2>&1 \
	|| die "canary deployment not found on $SOURCE_CTX. Run 002-run-endpoint-probe.sh --keep-canary first."

cat > "$TSV_FILE" <<EOF
# Config propagation latency test — $(date -Iseconds)
# Source: $SOURCE_CTX  Remotes: ${REMOTES[*]:-none}  Mesh size: $MESH_SIZE
# Iterations: $ITERATIONS  Poll interval: ${POLL_INTERVAL_S}s  Timeout: ${TIMEOUT_SEC}s
EOF
echo -e "run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tconfig_type\tt0_epoch_ns\tc1_local_ms\tc2_remote_ms\tstatus" >> "$TSV_FILE"

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
		attempts=$((attempts + 1))
		((attempts > 30)) && die "port-forward to istiod on $ctx (port $local_port) failed to connect"
		sleep 0.5
	done
}

poll_c1_local_sync() {
	local port="$1" t0="$2" result_file="$3"
	local deadline=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	while true; do
		local now_ms=$(( $(date +%s%N) / 1000000 ))
		((now_ms > deadline)) && echo "TIMEOUT" > "$result_file" && return
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

poll_c2_vs_remote_routes() {
	local remote_ctx="$1" t0="$2" result_file="$3" host="$4"
	local deadline=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	while true; do
		local now_ms=$(( $(date +%s%N) / 1000000 ))
		((now_ms > deadline)) && echo "TIMEOUT" > "$result_file" && return
		local routes
		routes=$(istioctl proxy-config routes deploy/propagation-watcher \
			-n "$NS" --context="$remote_ctx" 2>/dev/null) || { sleep "$POLL_INTERVAL_S"; continue; }
		if echo "$routes" | grep -q "$host"; then
			echo "$(date +%s%N)" > "$result_file"
			return
		fi
		sleep "$POLL_INTERVAL_S"
	done
}

poll_c2_dr_remote_clusters() {
	local remote_ctx="$1" t0="$2" result_file="$3"
	local deadline=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	while true; do
		local now_ms=$(( $(date +%s%N) / 1000000 ))
		((now_ms > deadline)) && echo "TIMEOUT" > "$result_file" && return
		local clusters
		clusters=$(istioctl proxy-config clusters deploy/propagation-watcher \
			-n "$NS" --context="$remote_ctx" 2>/dev/null) || { sleep "$POLL_INTERVAL_S"; continue; }
		if echo "$clusters" | grep -q "propagation-canary.*$NS"; then
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

echo "=== Config propagation probe ==="
echo "Source: $SOURCE_CTX | Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
echo "Iterations: $ITERATIONS | Timeout: ${TIMEOUT_SEC}s | Pause: ${PAUSE_SEC}s"
echo ""

echo "Starting port-forwards to istiod..."
start_port_forward "$SOURCE_CTX" "$BASE_PF_PORT"
echo "Port-forwards ready."

TMPDIR_RUN=$(mktemp -d)
trap 'cleanup_port_forwards; rm -rf "$TMPDIR_RUN"' EXIT

VS_C1_SUM=0; VS_C1_COUNT=0; VS_C1_MIN=""; VS_C1_MAX=""
VS_C2_SUM=0; VS_C2_COUNT=0; VS_C2_MIN=""; VS_C2_MAX=""
DR_C1_SUM=0; DR_C1_COUNT=0; DR_C1_MIN=""; DR_C1_MAX=""
DR_C2_SUM=0; DR_C2_COUNT=0; DR_C2_MIN=""; DR_C2_MAX=""

VS_HOST="propagation-canary.local"

for ((iter = 1; iter <= ITERATIONS; iter++)); do
	echo ""
	echo "--- Iteration $iter/$ITERATIONS ---"

	# --- VirtualService probe ---
	echo "  Applying VirtualService on $SOURCE_CTX..."
	T0=$(date +%s%N)
	helm template propagation-test "$CHART_DIR" \
		--set clusterName="$SOURCE_CTX" \
		--set namespace="$NS" \
		--set canary.enabled=true \
		--set canary.virtualservice.enabled=true \
		--set canary.virtualservice.host="$VS_HOST" \
		| "${KUBECTL[@]}" apply --context="$SOURCE_CTX" -f - >/dev/null

	C1_FILE="$TMPDIR_RUN/c1_vs"
	echo "" > "$C1_FILE"
	poll_c1_local_sync "$BASE_PF_PORT" "$T0" "$C1_FILE" &
	POLL_PIDS=($!)

	C2_VS_FILES=()
	for i in "${!REMOTES[@]}"; do
		c2f="$TMPDIR_RUN/c2_vs_${i}"
		echo "" > "$c2f"
		C2_VS_FILES+=("$c2f")
		poll_c2_vs_remote_routes "${REMOTES[i]}" "$T0" "$c2f" "$VS_HOST" &
		POLL_PIDS+=($!)
	done

	for pid in "${POLL_PIDS[@]}"; do
		wait "$pid" 2>/dev/null || true
	done

	c1_ms=$(compute_delta_ms "$C1_FILE" "$T0")
	echo "  VS C1 (local sync): ${c1_ms}ms"

	if [[ "$c1_ms" != "TIMEOUT" ]]; then
		VS_C1_SUM=$((VS_C1_SUM + c1_ms))
		VS_C1_COUNT=$((VS_C1_COUNT + 1))
		[[ -z "$VS_C1_MIN" || "$c1_ms" -lt "$VS_C1_MIN" ]] && VS_C1_MIN="$c1_ms"
		[[ -z "$VS_C1_MAX" || "$c1_ms" -gt "$VS_C1_MAX" ]] && VS_C1_MAX="$c1_ms"
	fi

	if [[ ${#REMOTES[@]} -eq 0 ]]; then
		status="OK"
		[[ "$c1_ms" == "TIMEOUT" ]] && status="TIMEOUT_C1"
		echo -e "${RUN_ID}\t${MESH_SIZE}\t${iter}\t${SOURCE_CTX}\tN/A\tVirtualService\t${T0}\t${c1_ms}\tN/A\t${status}" >> "$TSV_FILE"
	else
		for i in "${!REMOTES[@]}"; do
			c2_ms=$(compute_delta_ms "${C2_VS_FILES[i]}" "$T0")
			echo "  VS C2 (remote routes ${REMOTES[i]}): ${c2_ms}ms"

			if [[ "$c2_ms" != "TIMEOUT" ]]; then
				VS_C2_SUM=$((VS_C2_SUM + c2_ms))
				VS_C2_COUNT=$((VS_C2_COUNT + 1))
				[[ -z "$VS_C2_MIN" || "$c2_ms" -lt "$VS_C2_MIN" ]] && VS_C2_MIN="$c2_ms"
				[[ -z "$VS_C2_MAX" || "$c2_ms" -gt "$VS_C2_MAX" ]] && VS_C2_MAX="$c2_ms"
			fi

			status="OK"
			[[ "$c1_ms" == "TIMEOUT" ]] && status="TIMEOUT_C1"
			[[ "$c2_ms" == "TIMEOUT" ]] && status="TIMEOUT_C2"
			echo -e "${RUN_ID}\t${MESH_SIZE}\t${iter}\t${SOURCE_CTX}\t${REMOTES[i]}\tVirtualService\t${T0}\t${c1_ms}\t${c2_ms}\t${status}" >> "$TSV_FILE"
		done
	fi

	# Clean up VirtualService
	"${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" delete virtualservice/propagation-canary --ignore-not-found=true >/dev/null

	# --- DestinationRule probe ---
	echo "  Applying DestinationRule on $SOURCE_CTX..."
	T0=$(date +%s%N)
	helm template propagation-test "$CHART_DIR" \
		--set clusterName="$SOURCE_CTX" \
		--set namespace="$NS" \
		--set canary.enabled=true \
		--set canary.destinationrule.enabled=true \
		| "${KUBECTL[@]}" apply --context="$SOURCE_CTX" -f - >/dev/null

	C1_FILE="$TMPDIR_RUN/c1_dr"
	echo "" > "$C1_FILE"
	poll_c1_local_sync "$BASE_PF_PORT" "$T0" "$C1_FILE" &
	POLL_PIDS=($!)

	C2_DR_FILES=()
	for i in "${!REMOTES[@]}"; do
		c2f="$TMPDIR_RUN/c2_dr_${i}"
		echo "" > "$c2f"
		C2_DR_FILES+=("$c2f")
		poll_c2_dr_remote_clusters "${REMOTES[i]}" "$T0" "$c2f" &
		POLL_PIDS+=($!)
	done

	for pid in "${POLL_PIDS[@]}"; do
		wait "$pid" 2>/dev/null || true
	done

	c1_ms=$(compute_delta_ms "$C1_FILE" "$T0")
	echo "  DR C1 (local sync): ${c1_ms}ms"

	if [[ "$c1_ms" != "TIMEOUT" ]]; then
		DR_C1_SUM=$((DR_C1_SUM + c1_ms))
		DR_C1_COUNT=$((DR_C1_COUNT + 1))
		[[ -z "$DR_C1_MIN" || "$c1_ms" -lt "$DR_C1_MIN" ]] && DR_C1_MIN="$c1_ms"
		[[ -z "$DR_C1_MAX" || "$c1_ms" -gt "$DR_C1_MAX" ]] && DR_C1_MAX="$c1_ms"
	fi

	if [[ ${#REMOTES[@]} -eq 0 ]]; then
		status="OK"
		[[ "$c1_ms" == "TIMEOUT" ]] && status="TIMEOUT_C1"
		echo -e "${RUN_ID}\t${MESH_SIZE}\t${iter}\t${SOURCE_CTX}\tN/A\tDestinationRule\t${T0}\t${c1_ms}\tN/A\t${status}" >> "$TSV_FILE"
	else
		for i in "${!REMOTES[@]}"; do
			c2_ms=$(compute_delta_ms "${C2_DR_FILES[i]}" "$T0")
			echo "  DR C2 (remote clusters ${REMOTES[i]}): ${c2_ms}ms"

			if [[ "$c2_ms" != "TIMEOUT" ]]; then
				DR_C2_SUM=$((DR_C2_SUM + c2_ms))
				DR_C2_COUNT=$((DR_C2_COUNT + 1))
				[[ -z "$DR_C2_MIN" || "$c2_ms" -lt "$DR_C2_MIN" ]] && DR_C2_MIN="$c2_ms"
				[[ -z "$DR_C2_MAX" || "$c2_ms" -gt "$DR_C2_MAX" ]] && DR_C2_MAX="$c2_ms"
			fi

			status="OK"
			[[ "$c1_ms" == "TIMEOUT" ]] && status="TIMEOUT_C1"
			[[ "$c2_ms" == "TIMEOUT" ]] && status="TIMEOUT_C2"
			echo -e "${RUN_ID}\t${MESH_SIZE}\t${iter}\t${SOURCE_CTX}\t${REMOTES[i]}\tDestinationRule\t${T0}\t${c1_ms}\t${c2_ms}\t${status}" >> "$TSV_FILE"
		done
	fi

	# Clean up DestinationRule
	"${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" delete destinationrule/propagation-canary --ignore-not-found=true >/dev/null

	if ((iter < ITERATIONS)); then
		echo "  Pausing ${PAUSE_SEC}s..."
		sleep "$PAUSE_SEC"
	fi
done

echo ""
echo "=== Results written to $TSV_FILE ==="
echo ""
echo "Summary:"
if ((VS_C1_COUNT > 0)); then
	printf "  VS C1 local sync:      n=%d min=%dms max=%dms avg=%dms\n" "$VS_C1_COUNT" "$VS_C1_MIN" "$VS_C1_MAX" "$((VS_C1_SUM / VS_C1_COUNT))"
fi
if ((VS_C2_COUNT > 0)); then
	printf "  VS C2 remote:          n=%d min=%dms max=%dms avg=%dms\n" "$VS_C2_COUNT" "$VS_C2_MIN" "$VS_C2_MAX" "$((VS_C2_SUM / VS_C2_COUNT))"
fi
if ((DR_C1_COUNT > 0)); then
	printf "  DR C1 local sync:      n=%d min=%dms max=%dms avg=%dms\n" "$DR_C1_COUNT" "$DR_C1_MIN" "$DR_C1_MAX" "$((DR_C1_SUM / DR_C1_COUNT))"
fi
if ((DR_C2_COUNT > 0)); then
	printf "  DR C2 remote:          n=%d min=%dms max=%dms avg=%dms\n" "$DR_C2_COUNT" "$DR_C2_MIN" "$DR_C2_MAX" "$((DR_C2_SUM / DR_C2_COUNT))"
fi
if ((VS_C1_COUNT == 0 && DR_C1_COUNT == 0)); then
	echo "  No successful measurements."
fi

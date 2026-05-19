#!/usr/bin/env bash
# Measure cross-cluster data-plane latency and throughput using fortio.
# Runs fortio load tests from a client pod to local and remote servers,
# capturing latency percentiles and throughput at multiple QPS levels.
#
# Usage:
#   ./tests/dataplane/002-run-latency-probe.sh --source-context CTX [options]
#
# Examples:
#   # Baseline + cross-cluster latency:
#   ./tests/dataplane/002-run-latency-probe.sh --source-context rosa-001 --remote-contexts rosa-002
#
#   # Custom QPS levels and duration:
#   ./tests/dataplane/002-run-latency-probe.sh --source-context rosa-001 \
#     --remote-contexts rosa-002 --qps-levels 10,100,1000 --duration 60
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

SOURCE_CTX=""
REMOTE_CONTEXTS_CSV=""
MESH_SIZE=""
QPS_LEVELS="${DATAPLANE_QPS_LEVELS:-10,100,500,1000}"
DURATION="${DATAPLANE_DURATION_SEC:-30}"
CONNECTIONS="${DATAPLANE_NUM_CONNECTIONS:-8}"
OUTPUT_DIR="${ROOT}/tests/dataplane/results"
DRY_RUN=0
NS="${DATAPLANE_TEST_NAMESPACE:-dataplane-test}"

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --source-context CTX     Kube context for the fortio client (required).
  --remote-contexts CSV    Remote cluster contexts (comma-separated).
  --mesh-size N            Metadata tag for TSV (default: 1 + remotes).
  --qps-levels CSV         QPS levels to test (default: $QPS_LEVELS).
  --duration SEC           Duration per QPS level (default: $DURATION).
  --connections N          Concurrent connections (default: $CONNECTIONS).
  --output-dir DIR         Results directory (default: tests/dataplane/results).
  --dry-run                Show plan without executing.
  -h, --help               Show this help.

Environment:
  DATAPLANE_TEST_NAMESPACE, DATAPLANE_QPS_LEVELS, DATAPLANE_DURATION_SEC,
  DATAPLANE_NUM_CONNECTIONS.
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
	--qps-levels)
		[[ -n "${2:-}" ]] || die "--qps-levels requires a value"
		QPS_LEVELS="$2"
		shift 2
		;;
	--duration)
		[[ -n "${2:-}" ]] || die "--duration requires a value"
		DURATION="$2"
		shift 2
		;;
	--connections)
		[[ -n "${2:-}" ]] || die "--connections requires a value"
		CONNECTIONS="$2"
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

command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

REMOTES=()
if [[ -n "$REMOTE_CONTEXTS_CSV" ]]; then
	split_csv "$REMOTE_CONTEXTS_CSV" REMOTES
fi

QPS_ARR=()
split_csv "$QPS_LEVELS" QPS_ARR

[[ -z "$MESH_SIZE" ]] && MESH_SIZE=$(( 1 + ${#REMOTES[@]} ))

RUN_ID="$(date +%Y%m%dT%H%M%S)-$$"
mkdir -p "$OUTPUT_DIR"
TSV_FILE="${OUTPUT_DIR}/latency-${RUN_ID}.tsv"

if ((DRY_RUN)); then
	echo "=== Dry-run: data-plane latency probe ==="
	echo "Source: $SOURCE_CTX | Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
	echo "QPS levels: ${QPS_ARR[*]} | Duration: ${DURATION}s | Connections: $CONNECTIONS"
	exit 0
fi

cat > "$TSV_FILE" <<EOF
# Data-plane latency test — $(date -Iseconds)
# Source: $SOURCE_CTX  Remotes: ${REMOTES[*]:-none}  Mesh size: $MESH_SIZE
# QPS levels: ${QPS_ARR[*]}  Duration: ${DURATION}s  Connections: $CONNECTIONS
EOF
echo -e "run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus" >> "$TSV_FILE"

CLIENT_POD=$("${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" get pod -l app=dataplane-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) \
	|| die "no client pod found on $SOURCE_CTX"

echo "=== Data-plane latency probe ==="
echo "Source: $SOURCE_CTX (pod: $CLIENT_POD)"
echo "Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
echo "QPS levels: ${QPS_ARR[*]} | Duration: ${DURATION}s | Connections: $CONNECTIONS"
echo ""

run_fortio() {
	local target_ctx="$1" target_url="$2"
	for qps in "${QPS_ARR[@]}"; do
		echo "  QPS=$qps -> $target_url"
		local json_output
		json_output=$("${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" exec "$CLIENT_POD" -c fortio -- \
			fortio load -qps "$qps" -c "$CONNECTIONS" -t "${DURATION}s" -json - -quiet "$target_url" 2>/dev/null) || {
			echo "    FAILED"
			echo -e "${RUN_ID}\t${MESH_SIZE}\t${SOURCE_CTX}\t${target_ctx}\t${qps}\t0\t${CONNECTIONS}\t${DURATION}\t0\t0\t0\t0\t0\tFAILED" >> "$TSV_FILE"
			continue
		}

		local qps_actual p50 p90 p99 p999 max_lat
		qps_actual=$(echo "$json_output" | jq -r '.ActualQPS // 0' 2>/dev/null)
		p50=$(echo "$json_output" | jq -r '(.DurationHistogram.Percentiles[] | select(.Percentile == 50) | .Value // 0) * 1000' 2>/dev/null || echo 0)
		p90=$(echo "$json_output" | jq -r '(.DurationHistogram.Percentiles[] | select(.Percentile == 90) | .Value // 0) * 1000' 2>/dev/null || echo 0)
		p99=$(echo "$json_output" | jq -r '(.DurationHistogram.Percentiles[] | select(.Percentile == 99) | .Value // 0) * 1000' 2>/dev/null || echo 0)
		p999=$(echo "$json_output" | jq -r '(.DurationHistogram.Percentiles[] | select(.Percentile == 99.9) | .Value // 0) * 1000' 2>/dev/null || echo 0)
		max_lat=$(echo "$json_output" | jq -r '(.DurationHistogram.Max // 0) * 1000' 2>/dev/null || echo 0)

		printf "    actual_qps=%.1f p50=%.1fms p99=%.1fms max=%.1fms\n" "$qps_actual" "$p50" "$p99" "$max_lat"
		printf "%s\t%s\t%s\t%s\t%s\t%.2f\t%s\t%s\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\tOK\n" \
			"$RUN_ID" "$MESH_SIZE" "$SOURCE_CTX" "$target_ctx" "$qps" "$qps_actual" \
			"$CONNECTIONS" "$DURATION" "$p50" "$p90" "$p99" "$p999" "$max_lat" >> "$TSV_FILE"
	done
}

echo "--- Local baseline (same-cluster) ---"
run_fortio "$SOURCE_CTX" "http://dataplane-server.${NS}.svc.cluster.local:8080/echo"

for remote_ctx in "${REMOTES[@]}"; do
	echo ""
	echo "--- Cross-cluster: $SOURCE_CTX -> $remote_ctx ---"
	run_fortio "$remote_ctx" "http://dataplane-server.${NS}.svc.cluster.local:8080/echo"
done

echo ""
echo "Results written to $TSV_FILE"

MD_FILE="${OUTPUT_DIR}/latency-${RUN_ID}.md"
{
	echo "# Data-Plane Latency Results"
	echo ""
	echo "| Field | Value |"
	echo "|-------|-------|"
	echo "| Run ID | \`${RUN_ID}\` |"
	echo "| Date | $(date -Iseconds) |"
	echo "| Source | ${SOURCE_CTX} |"
	echo "| Remotes | ${REMOTES[*]:-none} |"
	echo "| Mesh size | ${MESH_SIZE} |"
	echo "| QPS levels | ${QPS_ARR[*]} |"
	echo "| Duration | ${DURATION}s |"
	echo "| Connections | ${CONNECTIONS} |"
	echo ""
	echo "## Summary"
	echo ""
	echo "| Target | QPS Target | QPS Actual | p50 (ms) | p90 (ms) | p99 (ms) | p99.9 (ms) | Max (ms) | Status |"
	echo "|--------|------------|------------|----------|----------|----------|------------|----------|--------|"
	awk -F'\t' '!/^#/ && !/^run_id/ && NF>=14 {
		printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $4, $5, $6, $9, $10, $11, $12, $13, $14
	}' "$TSV_FILE"
	echo ""
	echo "## Raw Data"
	echo ""
	echo "TSV: [\`$(basename "$TSV_FILE")\`]($(basename "$TSV_FILE"))"
} > "$MD_FILE"
echo "Summary written to $MD_FILE"

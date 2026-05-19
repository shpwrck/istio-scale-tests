#!/usr/bin/env bash
# Collect istiod resource usage and Prometheus metrics for control-plane analysis.
# Scrapes kubectl top, istiod /metrics, and writes a TSV row per cluster.
#
# Usage:
#   ./tests/controlplane/002-collect-resource-metrics.sh [--contexts CSV] [options]
#
# Examples:
#   # One-shot collection from all clusters:
#   ./tests/controlplane/002-collect-resource-metrics.sh --mesh-size 3 --service-count 10
#
#   # Watch mode during load test:
#   ./tests/controlplane/002-collect-resource-metrics.sh --watch --interval 15
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
OUTPUT_DIR="${ROOT}/tests/controlplane/results"
MESH_SIZE=""
SERVICE_COUNT="${CONTROLPLANE_SERVICE_COUNT:-10}"
REPLICAS="${CONTROLPLANE_REPLICAS_PER_SERVICE:-3}"
WATCH=0
INTERVAL=15
DRY_RUN=0
BASE_PF_PORT=15014

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV       Kube contexts to scrape (default: \$SETUP_CONTEXTS).
  --mesh-size N        Metadata tag for TSV output.
  --service-count N    Metadata tag for TSV output (default: $SERVICE_COUNT).
  --replicas N         Metadata tag for TSV output (default: $REPLICAS).
  --output-dir DIR     Results directory (default: tests/controlplane/results).
  --watch              Loop continuously.
  --interval SEC       Seconds between scrapes in watch mode (default: 15).
  --dry-run            Show what would be scraped without connecting.
  -h, --help           Show this help.

Environment:
  SETUP_CONTEXTS.
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
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"
		shift 2
		;;
	--mesh-size)
		[[ -n "${2:-}" ]] || die "--mesh-size requires a value"
		MESH_SIZE="$2"
		shift 2
		;;
	--service-count)
		[[ -n "${2:-}" ]] || die "--service-count requires a value"
		SERVICE_COUNT="$2"
		shift 2
		;;
	--replicas)
		[[ -n "${2:-}" ]] || die "--replicas requires a value"
		REPLICAS="$2"
		shift 2
		;;
	--output-dir)
		[[ -n "${2:-}" ]] || die "--output-dir requires a value"
		OUTPUT_DIR="$2"
		shift 2
		;;
	--watch)
		WATCH=1
		shift
		;;
	--interval)
		[[ -n "${2:-}" ]] || die "--interval requires a value"
		INTERVAL="$2"
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

if command -v oc >/dev/null 2>&1; then
	KUBECTL=(oc)
elif command -v kubectl >/dev/null 2>&1; then
	KUBECTL=(kubectl)
else
	die "neither oc nor kubectl found on PATH"
fi

command -v curl >/dev/null 2>&1 || die "curl not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_csv "$CONTEXTS_CSV" CONTEXTS
else
	split_csv "$SETUP_CONTEXTS" CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

[[ -z "$MESH_SIZE" ]] && MESH_SIZE="${#CONTEXTS[@]}"

if ((DRY_RUN)); then
	echo "Would scrape istiod metrics from: ${CONTEXTS[*]}"
	echo "Mesh size: $MESH_SIZE  Services: $SERVICE_COUNT  Replicas: $REPLICAS"
	exit 0
fi

mkdir -p "$OUTPUT_DIR"

RUN_ID="$(date +%Y%m%dT%H%M%S)-$$"
TSV_FILE="${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv"
cat > "$TSV_FILE" <<EOF
# Control-plane resource metrics — $(date -Iseconds)
# Contexts: ${CONTEXTS[*]}  Mesh size: $MESH_SIZE  Services: $SERVICE_COUNT  Replicas: $REPLICAS
EOF
echo -e "timestamp\tcontext\tmesh_size\tservice_count\treplicas\tistiod_cpu_m\tistiod_mem_mi\tconvergence_p50_ms\tconvergence_p99_ms\tqueue_p50_ms\tqueue_p99_ms\txds_pushes\tk8s_events\tconnected_proxies\tconfig_size_bytes" >> "$TSV_FILE"

PF_PIDS=()

cleanup() {
	for pid in "${PF_PIDS[@]}"; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	PF_PIDS=()
}

trap cleanup EXIT

echo "Starting port-forwards to istiod..."
for i in "${!CONTEXTS[@]}"; do
	ctx="${CONTEXTS[i]}"
	port=$(( BASE_PF_PORT + i ))
	"${KUBECTL[@]}" --context="$ctx" -n istio-system port-forward svc/istiod "$port":15014 >/dev/null 2>&1 &
	PF_PIDS+=($!)
done

sleep 3

for i in "${!CONTEXTS[@]}"; do
	port=$(( BASE_PF_PORT + i ))
	attempts=0
	while ! curl -s -o /dev/null "http://localhost:$port/metrics" 2>/dev/null; do
		attempts=$((attempts + 1))
		((attempts > 20)) && die "port-forward to istiod on ${CONTEXTS[i]} (port $port) failed"
		sleep 0.5
	done
done
echo "Port-forwards ready."

extract_histogram_quantile() {
	local metrics="$1" name="$2" quantile="$3"
	echo "$metrics" | awk -v name="${name}_bucket" -v q="$quantile" '
	$0 ~ name && /le="/ {
		line = $0
		sub(/.*le="/, "", line); sub(/".*/, "", line)
		le = line
		count = $NF + 0
		buckets[++n] = le " " count
	}
	END {
		if(n==0) { print "N/A"; exit }
		total=0
		for(i=1;i<=n;i++) {
			split(buckets[i], parts, " ")
			total = parts[2]
		}
		target = total * q
		for(i=1;i<=n;i++) {
			split(buckets[i], parts, " ")
			if(parts[2]+0 >= target) {
				le_val = parts[1]
				if(le_val == "+Inf") le_val = 0
				printf "%.0f\n", le_val * 1000
				exit
			}
		}
		print "N/A"
	}'
}

extract_gauge() {
	local metrics="$1" name="$2"
	echo "$metrics" | awk -v name="^${name}" '$0 ~ name && !/^#/ { print $NF+0; exit }'
}

extract_counter() {
	local metrics="$1" name="$2"
	echo "$metrics" | awk -v name="^${name}" '$0 ~ name && !/^#/ { sum += $NF } END { printf "%.0f\n", sum+0 }'
}

scrape_all() {
	local ts
	ts=$(date -Iseconds)
	for i in "${!CONTEXTS[@]}"; do
		ctx="${CONTEXTS[i]}"
		port=$(( BASE_PF_PORT + i ))

		local cpu_m="N/A" mem_mi="N/A"
		local top_output
		top_output=$("${KUBECTL[@]}" --context="$ctx" -n istio-system top pod -l app=istiod --no-headers 2>/dev/null) || true
		if [[ -n "$top_output" ]]; then
			cpu_m=$(echo "$top_output" | awk '{gsub(/m/,"",$2); sum+=$2} END{printf "%.0f", sum}')
			mem_mi=$(echo "$top_output" | awk '{gsub(/Mi/,"",$3); sum+=$3} END{printf "%.0f", sum}')
		fi

		local metrics
		metrics=$(curl -s "http://localhost:$port/metrics" 2>/dev/null) || { echo "warning: failed to scrape $ctx" >&2; continue; }

		local conv_p50 conv_p99 queue_p50 queue_p99
		conv_p50=$(extract_histogram_quantile "$metrics" "pilot_proxy_convergence_time" "0.5")
		conv_p99=$(extract_histogram_quantile "$metrics" "pilot_proxy_convergence_time" "0.99")
		queue_p50=$(extract_histogram_quantile "$metrics" "pilot_proxy_queue_time" "0.5")
		queue_p99=$(extract_histogram_quantile "$metrics" "pilot_proxy_queue_time" "0.99")

		local xds_pushes k8s_events connected_proxies config_size
		xds_pushes=$(extract_counter "$metrics" "pilot_xds_pushes")
		k8s_events=$(extract_counter "$metrics" "pilot_k8s_cfg_events")
		connected_proxies=$(extract_gauge "$metrics" "pilot_xds{")
		config_size=$(extract_counter "$metrics" "pilot_xds_config_size_bytes")

		echo -e "${ts}\t${ctx}\t${MESH_SIZE}\t${SERVICE_COUNT}\t${REPLICAS}\t${cpu_m}\t${mem_mi}\t${conv_p50}\t${conv_p99}\t${queue_p50}\t${queue_p99}\t${xds_pushes}\t${k8s_events}\t${connected_proxies}\t${config_size}" >> "$TSV_FILE"
		echo "  Scraped $ctx: cpu=${cpu_m}m mem=${mem_mi}Mi proxies=${connected_proxies} pushes=${xds_pushes}"
	done
}

if ((WATCH)); then
	echo "Watch mode: scraping every ${INTERVAL}s (Ctrl-C to stop)"
	while true; do
		echo ""
		echo "=== Scrape at $(date -Iseconds) ==="
		scrape_all
		sleep "$INTERVAL"
	done
else
	echo ""
	echo "=== Scraping control-plane metrics ==="
	scrape_all
	echo ""
	echo "Results appended to $TSV_FILE"

	MD_FILE="${OUTPUT_DIR}/controlplane-${RUN_ID}.md"
	{
		echo "# Control-Plane Resource Metrics"
		echo ""
		echo "| Field | Value |"
		echo "|-------|-------|"
		echo "| Run ID | \`${RUN_ID}\` |"
		echo "| Date | $(date -Iseconds) |"
		echo "| Contexts | ${CONTEXTS[*]} |"
		echo "| Mesh size | ${MESH_SIZE} |"
		echo "| Service count | ${SERVICE_COUNT} |"
		echo "| Replicas | ${REPLICAS} |"
		echo ""
		echo "## Summary"
		echo ""
		echo "| Context | CPU (m) | Memory (Mi) | Conv p50 (ms) | Conv p99 (ms) | Queue p50 (ms) | Queue p99 (ms) | Proxies | Pushes |"
		echo "|---------|---------|-------------|---------------|---------------|----------------|----------------|---------|--------|"
		awk -F'\t' '!/^#/ && !/^timestamp/ && NF>=15 {
			printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $2, $6, $7, $8, $9, $10, $11, $14, $12
		}' "$TSV_FILE"
		echo ""
		echo "## Raw Data"
		echo ""
		echo "TSV: [\`$(basename "$TSV_FILE")\`]($(basename "$TSV_FILE"))"
	} > "$MD_FILE"
	echo "Summary written to $MD_FILE"
fi

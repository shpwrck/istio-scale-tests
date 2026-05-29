#!/usr/bin/env bash
# Scrape istiod Prometheus metrics via port-forward for passive analysis.
# Supplements OpenShift User Workload Monitoring — useful when UWM is not yet enabled
# or for quick point-in-time snapshots during load tests.
#
# Usage:
#   ./tests/propagation/004-collect-pilot-metrics.sh [--contexts CSV] [--output-dir DIR] [--watch --interval SEC]
#
# Examples:
#   # One-shot snapshot from all clusters:
#   ./tests/propagation/004-collect-pilot-metrics.sh
#
#   # Watch mode, scrape every 10s:
#   ./tests/propagation/004-collect-pilot-metrics.sh --watch --interval 10
#
#   # Specific clusters:
#   ./tests/propagation/004-collect-pilot-metrics.sh --contexts rosa-001,rosa-002
# ci-dry-run: --contexts ci-dummy
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
OUTPUT_DIR="${ROOT}/tests/propagation/results"
WATCH=0
INTERVAL=10
DRY_RUN=0
BASE_PF_PORT=15014


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV     Kube contexts to scrape (default: \$SETUP_CONTEXTS).
  --output-dir DIR   Results directory (default: tests/propagation/results).
  --watch            Loop continuously.
  --interval SEC     Seconds between scrapes in watch mode (default: 10).
  --dry-run          Show what would be scraped without connecting.
  -h, --help         Show this help.

Environment:
  SETUP_CONTEXTS.
EOF
}


while [[ $# -gt 0 ]]; do
	case "$1" in
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"
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

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_csv "$CONTEXTS_CSV" CONTEXTS
else
	split_csv "$SETUP_CONTEXTS" CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

if ((DRY_RUN)); then
	echo "Would scrape istiod metrics from: ${CONTEXTS[*]}"
	echo "Output directory: $OUTPUT_DIR"
	echo "Watch mode: $WATCH (interval: ${INTERVAL}s)"
	exit 0
fi

mkdir -p "$OUTPUT_DIR"

PILOT_METRICS_REGEX="^(pilot_proxy_convergence_time|pilot_proxy_queue_time|pilot_xds_push_time|pilot_xds_pushes|pilot_xds[^_]|pilot_k8s_cfg_events|pilot_push_triggers|pilot_xds_config_size_bytes|pilot_conflict)"

PF_PIDS=()

cleanup_port_forwards() {
	for pid in "${PF_PIDS[@]}"; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	PF_PIDS=()
}

trap cleanup_port_forwards EXIT

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

scrape_all() {
	local ts
	ts=$(date -Iseconds)
	for i in "${!CONTEXTS[@]}"; do
		ctx="${CONTEXTS[i]}"
		port=$(( BASE_PF_PORT + i ))
		outfile="${OUTPUT_DIR}/${ctx}-${ts}.prom"
		curl -s "http://localhost:$port/metrics" 2>/dev/null \
			| grep -E "$PILOT_METRICS_REGEX" \
			> "$outfile" || echo "warning: failed to scrape $ctx" >&2
		echo "  Scraped $ctx -> $outfile ($(wc -l < "$outfile") lines)"
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
	echo "=== Scraping metrics ==="
	scrape_all
	echo ""
	echo "Done. Files in $OUTPUT_DIR"
fi

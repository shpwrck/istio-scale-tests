#!/usr/bin/env bash
# Snapshot istiod pilot_* metrics from every Running istiod pod via port-forward.
# Useful when OpenShift User Workload Monitoring is not enabled, or for
# point-in-time snapshots during a load test. Writes one .prom file per pod.
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
#   ./tests/propagation/004-collect-pilot-metrics.sh --contexts <mesh-a-ctx>,<mesh-b-ctx>
#
#   # Contexts and results dir from a run config:
#   ./tests/propagation/004-collect-pilot-metrics.sh --config tests/propagation/configs/smoke.env
# ci-dry-run: --contexts ci-dummy
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
config_preload propagation "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/timestamp.sh"
# Own port block so a snapshot can run while 002 (or another suite) holds the
# FANOUT_PF_BASE block. Assigned after versions.env, which exports FANOUT_PF_BASE.
# shellcheck disable=SC2034  # read by tests/lib/fanout.sh
FANOUT_PF_BASE="${PROPAGATION_SNAPSHOT_PF_BASE:-22014}"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fanout.sh"

CONTEXTS_CSV=""
OUTPUT_DIR="$(config_repo_path "${PROPAGATION_RESULTS_DIR}")"
WATCH=0
INTERVAL=10
DRY_RUN=0


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE      Run config of KEY=value lines (config/options.env keys; see
                     tests/propagation/README.md, "Run config"). Precedence: flag >
                     --config > environment > default.
  --contexts CSV     Kube contexts to scrape (default: \$SETUP_CONTEXTS).
  --output-dir DIR   Results directory (default: ${PROPAGATION_RESULTS_DIR}).
  --watch            Loop continuously.
  --interval SEC     Seconds between scrapes in watch mode (default: 10).
  --dry-run          Show what would be scraped without connecting.
  -h, --help         Show this help.

Writes <ctx>-<pod>-<timestamp>.prom per istiod pod, filtered to pilot_* series.

Environment:
  SETUP_CONTEXTS, METRICS_SCRAPE_TIMEOUT (curl --max-time per scrape, default 30),
  PROPAGATION_SNAPSHOT_PF_BASE (local port block base, default 22014; kept
  apart from FANOUT_PF_BASE so this can run alongside 002),
  PROPAGATION_RESULTS_DIR (--output-dir; relative to the repo root).
EOF
}


while [[ $# -gt 0 ]]; do
	case "$1" in
	--config)
		# Loaded by config_preload above.
		[[ -n "${2:-}" ]] || die "--config requires a value"
		shift 2
		;;
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

is_pos_int "$INTERVAL" || die "--interval must be a positive integer (got: $INTERVAL)"

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_contexts "$CONTEXTS_CSV" CONTEXTS --contexts
else
	split_contexts "$SETUP_CONTEXTS" CONTEXTS SETUP_CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

if ((DRY_RUN)); then
	echo "Would scrape every Running istiod pod on: ${CONTEXTS[*]}"
	echo "Output directory: $OUTPUT_DIR (one .prom file per pod per scrape)"
	echo "Watch mode: $WATCH (interval: ${INTERVAL}s)"
	echo "Local port block: $(fanout_ctx_port_base 0)+ (${FANOUT_CTX_STRIDE} ports per context)"
	exit 0
fi

KUBECTL=()
resolve_kubectl KUBECTL
command -v curl >/dev/null 2>&1 || die "curl not found on PATH"

mkdir -p "$OUTPUT_DIR"

PILOT_METRICS_REGEX="^(pilot_proxy_convergence_time|pilot_proxy_queue_time|pilot_xds_push_time|pilot_xds_pushes|pilot_xds[^_]|pilot_k8s_cfg_events|pilot_push_triggers|pilot_xds_config_size_bytes|pilot_conflict)"

PF_PIDS=()
SCRAPE_DIR="$(mktemp -d)"
declare -A CTX_PORTS=() CTX_PODS=()

cleanup() {
	local pid
	for pid in "${PF_PIDS[@]}"; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	PF_PIDS=()
	rm -rf "$SCRAPE_DIR"
}
trap cleanup EXIT

# (Re)open one port-forward per Running istiod pod on every context.
open_all() {
	local pid i ctx
	for pid in "${PF_PIDS[@]}"; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	PF_PIDS=()
	for i in "${!CONTEXTS[@]}"; do
		ctx="${CONTEXTS[i]}"
		# Out-array names must not collide with fanout_open's own locals (ports/pods).
		local -a ctx_ports=() ctx_pods=()
		fanout_open "$ctx" "$i" PF_PIDS ctx_ports ctx_pods "${KUBECTL[@]}"
		CTX_PORTS["$i"]="${ctx_ports[*]}"
		CTX_PODS["$i"]="${ctx_pods[*]}"
	done
}

# Scrape every pod; returns 1 if any pod's scrape failed.
scrape_all() {
	local ts i j ctx safe_ctx outfile failed=0
	local -a ports=() pods=()
	ts=$(date -u +%Y%m%dT%H%M%SZ)
	for i in "${!CONTEXTS[@]}"; do
		ctx="${CONTEXTS[i]}"
		safe_ctx="${ctx//[^A-Za-z0-9._-]/_}"
		read -ra ports <<<"${CTX_PORTS[$i]}"
		read -ra pods <<<"${CTX_PODS[$i]}"
		fanout_scrape_all "$SCRAPE_DIR" "ctx${i}" "${ports[@]}" >/dev/null || failed=1
		for j in "${!pods[@]}"; do
			outfile="${OUTPUT_DIR}/${safe_ctx}-${pods[j]}-${ts}.prom"
			grep -E "$PILOT_METRICS_REGEX" "${SCRAPE_DIR}/ctx${i}-${j}.metrics" > "$outfile" || true
			if [[ -s "$outfile" ]]; then
				echo "  Scraped $ctx/${pods[j]} -> $outfile ($(wc -l < "$outfile") lines)"
			else
				echo "warning: no pilot_* metrics from $ctx/${pods[j]}" >&2
				failed=1
			fi
		done
	done
	return "$failed"
}

echo "Starting port-forwards to every istiod pod..."
open_all
echo "Port-forwards ready."

if ((WATCH)); then
	echo "Watch mode: scraping every ${INTERVAL}s (Ctrl-C to stop)"
	while true; do
		echo ""
		echo "=== Scrape at $(date -u -Iseconds) ==="
		if ! scrape_all; then
			echo "warning: re-opening port-forwards (pod restart or dead port-forward?)" >&2
			open_all
		fi
		sleep "$INTERVAL"
	done
else
	echo ""
	echo "=== Scraping metrics ==="
	rc=0
	scrape_all || rc=$?
	echo ""
	echo "Done. Files in $OUTPUT_DIR"
	exit "$rc"
fi

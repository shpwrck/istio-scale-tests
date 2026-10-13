#!/usr/bin/env bash
# Collect istiod resource usage and Prometheus metrics for control-plane analysis.
# Scrapes istiod /metrics, computes delta-window stats for the histograms and
# counters that are cumulative since istiod start, and writes a TSV row per
# cluster. Optionally samples per-sidecar /config_dump byte size (plus CDS cluster
# count and CDS/RDS size) for Sidecar CR scoping and VS/DR analysis.
#
# Delta-window approach (chosen because Prometheus UWM is not guaranteed to be
# reachable from where this script runs): we take a *baseline* scrape on entry,
# wait `--settle SEC` (passed through by 003), take a *final* scrape, and
# compute deltas per histogram bucket / counter. p50 and p99 are derived from
# the windowed cumulative buckets via the standard linear-interp algorithm.
#
# Usage:
#   ./tests/controlplane/002-collect-resource-metrics.sh [--contexts CSV] [options]
#
# Examples:
#   # One-shot collection from all clusters (60-second window):
#   ./tests/controlplane/002-collect-resource-metrics.sh --mesh-size 3 \
#     --service-count 10 --settle 60
#
#   # Watch mode during load test (per-tick deltas at the interval cadence):
#   ./tests/controlplane/002-collect-resource-metrics.sh --watch --interval 15
#
#   # Settle, results dir and metadata tags from a run config:
#   ./tests/controlplane/002-collect-resource-metrics.sh --config tests/controlplane/configs/smoke.env
# ci-dry-run: --contexts ci-dummy
set -euo pipefail
# Loud ERR trap for unexpected aborts (per-pod faults become N/A rows).
trap 'rc=$?; echo "FATAL: ${0##*/} aborted (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # config_preload, config_preamble_lines
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
config_preload controlplane "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/timestamp.sh"
# shellcheck disable=SC1091
source "${ROOT}/config/options.env"  # SCALE_* preamble keys
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/capacity.sh"  # read-only capacity probes
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"  # probe_kube_versions, infra_preamble_lines, tuning_baseline_state
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/metrics.sh"  # extract_counter_sum, extract_counter_by_label, extract_gauge_sum
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fanout.sh"  # fanout_gauge_sum_strict, fanout_list_istiod_pods (needs metrics.sh first)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/envelope.sh"  # env_collect_infra (istiod req/lim, network topology)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/reach.sh"  # reach_sanitize (used by istiod-diag.sh)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/istiod-diag.sh"  # istiod_diag_after_window (restart evidence)

CONTEXTS_CSV=""
OUTPUT_DIR="$(config_repo_path "${CONTROLPLANE_RESULTS_DIR}")"
MESH_SIZE=""
SERVICE_COUNT="${CONTROLPLANE_SERVICE_COUNT:-10}"
REPLICAS="${CONTROLPLANE_REPLICAS_PER_SERVICE:-3}"
NAMESPACE_COUNT="${CONTROLPLANE_NAMESPACE_COUNT:-1}"
SIDECAR_SCOPING="${CONTROLPLANE_SIDECAR_SCOPING:-none}"
TRAFFIC_CONFIG="${CONTROLPLANE_TRAFFIC_CONFIG:-none}"
VSDR_EVERY="${CONTROLPLANE_VSDR_EVERY:-1}"
VSDR_SUBSETS="${CONTROLPLANE_VSDR_SUBSETS:-2}"
CONFIG_DUMP_SAMPLES="${CONTROLPLANE_CONFIG_DUMP_SAMPLES:-3}"
SETTLE_SEC="${CONTROLPLANE_SETTLE_SEC:-60}"
WATCH=0
INTERVAL=15
DRY_RUN=0
BASE_PF_PORT=15014
PHASE=combined
STATE_DIR=""
RUN_ID_OVERRIDE=""


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE        Run config of KEY=value lines (config/options.env keys; see
                       tests/controlplane/README.md, "Run config").
                       Precedence: flag > --config > environment > default.
  --contexts CSV       Kube contexts to scrape (default: \$SETUP_CONTEXTS).
  --mesh-size N        Metadata tag for TSV output.
  --service-count N    Metadata tag for TSV output (default: $SERVICE_COUNT).
  --replicas N         Metadata tag for TSV output (default: $REPLICAS).
  --namespace-count N  Metadata tag for TSV output (default: $NAMESPACE_COUNT).
  --sidecar-scoping M  Metadata tag: none|namespace|explicit (default: $SIDECAR_SCOPING).
  --traffic-config M   Metadata tag: none|vsdr (default: $TRAFFIC_CONFIG). Must match
                       what 001 deployed.
  --vsdr-every N       Metadata tag: 001's --vsdr-every (default: $VSDR_EVERY). With
                       --service-count it sets the vsdr_services column.
  --vsdr-subsets N     Metadata tag: 001's --vsdr-subsets (default: $VSDR_SUBSETS).
  --config-dump-samples N  Random pods per cluster to exec /config_dump on
                       (default: $CONFIG_DUMP_SAMPLES; 0 disables).
  --settle SEC         Delta-window length (seconds) between baseline and
                       final scrape (default: $SETTLE_SEC). Must match the
                       settle time used by the calling orchestrator.
  --output-dir DIR     Results directory (default: ${CONTROLPLANE_RESULTS_DIR}).
  --run-id ID          Reuse an existing sweep RUN_ID (writes into sweep-<ID>/).
  --watch              Loop continuously (delta window = --interval).
  --interval SEC       Seconds between scrapes in watch mode (default: 15).
  --phase PHASE        Orchestration phase, one of:
                         combined  baseline + settle + final + emit (default,
                                   for standalone use)
                         baseline  scrape baseline metrics only, write to
                                   --state-dir, exit without emitting a row.
                                   No settle; caller (003) should invoke 001
                                   AFTER this so the deploy storm lands inside
                                   the scrape window.
                         final     scrape final metrics, read baseline from
                                   --state-dir, compute deltas, emit one row.
  --state-dir DIR      Required for --phase baseline (must be empty/writable)
                       and --phase final (must contain a prior baseline's
                       output). Used to ferry baseline metrics across the
                       deploy step in split-phase mode. Ignored for combined.
  --dry-run            Show what would be scraped without connecting.
  -h, --help           Show this help.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_SERVICE_COUNT, CONTROLPLANE_REPLICAS_PER_SERVICE,
  CONTROLPLANE_NAMESPACE_COUNT, CONTROLPLANE_SIDECAR_SCOPING,
  CONTROLPLANE_TRAFFIC_CONFIG, CONTROLPLANE_VSDR_EVERY, CONTROLPLANE_VSDR_SUBSETS,
  CONTROLPLANE_CONFIG_DUMP_SAMPLES, CONTROLPLANE_SETTLE_SEC (--settle),
  CONTROLPLANE_RESULTS_DIR (--output-dir; relative to the repo root).
  CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT (default 10), CONTROLPLANE_PROXY_CHECK_MIN_DIFF
  (default 2): proxy_check warns when a cluster's connected proxies (pilot_xds summed
  over its istiod pods) and its Running sidecar pods differ by more than
  max(tolerance % of the sidecar pods, min diff). A warning only; rows are kept.
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
	--namespace-count)
		[[ -n "${2:-}" ]] || die "--namespace-count requires a value"
		NAMESPACE_COUNT="$2"
		shift 2
		;;
	--sidecar-scoping)
		[[ -n "${2:-}" ]] || die "--sidecar-scoping requires a value"
		SIDECAR_SCOPING="$2"
		shift 2
		;;
	--traffic-config)
		[[ -n "${2:-}" ]] || die "--traffic-config requires a value"
		TRAFFIC_CONFIG="$2"
		shift 2
		;;
	--vsdr-every)
		[[ -n "${2:-}" ]] || die "--vsdr-every requires a value"
		VSDR_EVERY="$2"
		shift 2
		;;
	--vsdr-subsets)
		[[ -n "${2:-}" ]] || die "--vsdr-subsets requires a value"
		VSDR_SUBSETS="$2"
		shift 2
		;;
	--config-dump-samples)
		[[ -n "${2:-}" ]] || die "--config-dump-samples requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--config-dump-samples must be a non-negative integer; got '$2'"
		CONFIG_DUMP_SAMPLES="$2"
		shift 2
		;;
	--settle)
		[[ -n "${2:-}" ]] || die "--settle requires a value"
		SETTLE_SEC="$2"
		shift 2
		;;
	--output-dir)
		[[ -n "${2:-}" ]] || die "--output-dir requires a value"
		OUTPUT_DIR="$2"
		shift 2
		;;
	--run-id)
		[[ -n "${2:-}" ]] || die "--run-id requires a value"
		RUN_ID_OVERRIDE="$2"
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
	--phase)
		[[ -n "${2:-}" ]] || die "--phase requires a value"
		PHASE="$2"
		shift 2
		;;
	--state-dir)
		[[ -n "${2:-}" ]] || die "--state-dir requires a value"
		STATE_DIR="$2"
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

is_pos_int "$SERVICE_COUNT" || die "--service-count must be a positive integer (got: $SERVICE_COUNT)"
is_pos_int "$REPLICAS" || die "--replicas must be a positive integer (got: $REPLICAS)"
is_pos_int "$NAMESPACE_COUNT" || die "--namespace-count must be a positive integer (got: $NAMESPACE_COUNT)"
is_nonneg_int "$SETTLE_SEC" || die "--settle must be a non-negative integer (got: $SETTLE_SEC)"
is_nonneg_int "$CONFIG_DUMP_SAMPLES" || die "--config-dump-samples must be a non-negative integer (got: $CONFIG_DUMP_SAMPLES)"
validate_scoping "$SIDECAR_SCOPING"
validate_traffic_config "$TRAFFIC_CONFIG"
is_pos_int "$VSDR_EVERY" || die "--vsdr-every must be a positive integer (got: $VSDR_EVERY)"
is_pos_int "$VSDR_SUBSETS" || die "--vsdr-subsets must be a positive integer (got: $VSDR_SUBSETS)"
# Services that carry a VS+DR (configured; same rule as the chart). 0 for none.
VSDR_SERVICES=0
[[ "$TRAFFIC_CONFIG" == vsdr ]] && VSDR_SERVICES="$(vsdr_service_count "$SERVICE_COUNT" "$VSDR_EVERY")"
case "$PHASE" in
combined|baseline|final) ;;
*) die "--phase must be one of: combined, baseline, final (got: $PHASE)";;
esac
if [[ "$PHASE" != combined ]]; then
	[[ -n "$STATE_DIR" ]] || die "--phase $PHASE requires --state-dir"
fi
if ((WATCH)) && [[ "$PHASE" != combined ]]; then
	die "--watch is only valid with --phase combined"
fi
is_pos_int "$INTERVAL" || die "--interval must be a positive integer (got: $INTERVAL)"
PROXY_CHECK_TOL_PCT="${CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT:-10}"
PROXY_CHECK_MIN_DIFF="${CONTROLPLANE_PROXY_CHECK_MIN_DIFF:-2}"
is_nonneg_int "$PROXY_CHECK_TOL_PCT" || die "CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT must be a non-negative integer percent (got: $PROXY_CHECK_TOL_PCT)"
is_nonneg_int "$PROXY_CHECK_MIN_DIFF" || die "CONTROLPLANE_PROXY_CHECK_MIN_DIFF must be a non-negative integer (got: $PROXY_CHECK_MIN_DIFF)"

KUBECTL=()
resolve_kubectl KUBECTL

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
is_pos_int "$MESH_SIZE" || die "--mesh-size must be a positive integer (got: $MESH_SIZE)"

if [[ -n "$RUN_ID_OVERRIDE" ]]; then
	RUN_ID="$RUN_ID_OVERRIDE"
else
	RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
HARNESS_SHA="$(git -C "$ROOT" describe --always --dirty --abbrev=7 2>/dev/null || echo unknown)"

echo "[002] RUN_ID=$RUN_ID  SETTLE_SEC=$SETTLE_SEC  HARNESS_SHA=$HARNESS_SHA"
echo "[002] Contexts: ${CONTEXTS[*]}  Mesh: $MESH_SIZE  Services: $SERVICE_COUNT  Replicas: $REPLICAS  Namespaces: $NAMESPACE_COUNT  Scoping: $SIDECAR_SCOPING  ConfigDumpSamples: $CONFIG_DUMP_SAMPLES"
echo "[002] Traffic: $TRAFFIC_CONFIG  VS+DR services: $VSDR_SERVICES  (every $VSDR_EVERY, $VSDR_SUBSETS subsets)"
echo "[002] Proxy check: warn when connected proxies and Running sidecar pods differ by > max(${PROXY_CHECK_TOL_PCT}%, ${PROXY_CHECK_MIN_DIFF}) per cluster"

if ((DRY_RUN)); then
	echo "Would scrape istiod metrics from: ${CONTEXTS[*]}"
	exit 0
fi

if [[ "$PHASE" != baseline ]]; then
	mkdir -p "$OUTPUT_DIR"
fi
if [[ "$PHASE" != combined ]]; then
	mkdir -p "$STATE_DIR"
fi

ISTIO_VERSION_TAG="${ISTIO_VERSION:-unknown}"

# Kube server version per context (concurrent, 5s timeout each).
KUBE_VERSIONS_CSV="$(probe_kube_versions "$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}")"

# Source context's node allocatable + istiod limits for the preamble (read-only;
# `unknown` on failure). Skipped for --phase baseline (no preamble written then).
PRE_NODE_ALLOC_CPU_M="unknown"
PRE_NODE_ALLOC_MEM_MI="unknown"
PRE_ISTIOD_CPU_LIMIT_M="unknown"
PRE_ISTIOD_MEM_LIMIT_MI="unknown"
if [[ "$PHASE" != baseline ]]; then
	src_ctx="${CONTEXTS[0]}"
	# shellcheck disable=SC2207
	nt_kv=($(cap_node_totals "$src_ctx" "${KUBECTL[@]}"))
	for kv in "${nt_kv[@]}"; do
		case "$kv" in
			cpu_m=*) PRE_NODE_ALLOC_CPU_M="${kv#cpu_m=}" ;;
			mem_mi=*) PRE_NODE_ALLOC_MEM_MI="${kv#mem_mi=}" ;;
		esac
	done
	# shellcheck disable=SC2207
	il_kv=($(cap_istiod_limits "$src_ctx" "${KUBECTL[@]}"))
	for kv in "${il_kv[@]}"; do
		case "$kv" in
			cpu_m=*) PRE_ISTIOD_CPU_LIMIT_M="${kv#cpu_m=}" ;;
			mem_mi=*) PRE_ISTIOD_MEM_LIMIT_MI="${kv#mem_mi=}" ;;
		esac
	done
fi

# Live tuning-baseline state from the source cluster. Keep the key set identical
# to 003's precreate_tsv_preamble (002 writes the preamble only when standalone).
PRE_TUNING_BASELINE="TUNING_BASELINE=unknown"
PRE_SIDECAR_EGRESS_HOSTS="SIDECAR_EGRESS_HOSTS=unknown"
if [[ "$PHASE" != baseline ]]; then
	tb_kv=""
	while IFS= read -r tb_kv; do
		case "$tb_kv" in
			TUNING_BASELINE=*) PRE_TUNING_BASELINE="$tb_kv" ;;
			SIDECAR_EGRESS_HOSTS=*) PRE_SIDECAR_EGRESS_HOSTS="$tb_kv" ;;
		esac
	done < <(tuning_baseline_state "${CONTEXTS[0]}" "${KUBECTL[@]}")
fi

TSV_FILE="${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv"
if [[ "$PHASE" != baseline && ! -f "$TSV_FILE" ]]; then
	# Cluster-infra block, collected only when 002 writes the preamble itself
	# (003 pre-creates it in a sweep). Same shared emitter as 003.
	PRE_INFRA_KV="$(env_collect_infra "$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}")"
	{
		echo "# Control-plane resource metrics — $(date -u -Iseconds)"
		echo "# CONTROLPLANE_SCHEMA=51"
		echo "# CONTROLPLANE_INFRA_SCHEMA=2"
		echo "# ISTIO_VERSION=${ISTIO_VERSION_TAG}"
		echo "# HARNESS_SHA=${HARNESS_SHA}"
		echo "# KUBE_VERSIONS=${KUBE_VERSIONS_CSV}"
		echo "# SETTLE_SEC=${SETTLE_SEC}"
		echo "# RUN_ID=${RUN_ID}"
		echo "# PHASE=${PHASE}"
		echo "# SIDECAR_SCOPING=${SIDECAR_SCOPING}"
		echo "# CONFIG_DUMP_SAMPLES=${CONFIG_DUMP_SAMPLES}"
		echo "# NODE_ALLOC_CPU_M=${PRE_NODE_ALLOC_CPU_M}"
		echo "# NODE_ALLOC_MEM_MI=${PRE_NODE_ALLOC_MEM_MI}"
		echo "# ISTIOD_CPU_LIMIT_M=${PRE_ISTIOD_CPU_LIMIT_M}"
		echo "# ISTIOD_MEM_LIMIT_MI=${PRE_ISTIOD_MEM_LIMIT_MI}"
		echo "# SCALE_TARGET_FRACTION=${SCALE_TARGET_FRACTION:-unknown}"
		echo "# SCALE_SIZING_MODE=${SCALE_SIZING_MODE:-unknown}"
		echo "# PROXY_CHECK_TOLERANCE_PCT=${PROXY_CHECK_TOL_PCT}"
		echo "# PROXY_CHECK_MIN_DIFF=${PROXY_CHECK_MIN_DIFF}"
		echo "# TRAFFIC_CONFIG=${TRAFFIC_CONFIG}"
		echo "# VSDR_EVERY=${VSDR_EVERY}"
		echo "# VSDR_SUBSETS=${VSDR_SUBSETS}"
		config_preamble_lines
		# shellcheck disable=SC2086
		infra_preamble_lines $PRE_INFRA_KV
		echo "# ${PRE_TUNING_BASELINE}"
		echo "# ${PRE_SIDECAR_EGRESS_HOSTS}"
		echo "# Contexts: ${CONTEXTS[*]}  Mesh size: $MESH_SIZE  Services: $SERVICE_COUNT  Replicas: $REPLICAS  Namespaces: $NAMESPACE_COUNT  Scoping: $SIDECAR_SCOPING  Traffic: $TRAFFIC_CONFIG"
	} > "$TSV_FILE"
fi

# Schema (TSV header — 51 columns; must equal 003's CONTROLPLANE_TSV_HEADER, which
# tests/lib/test/preamble.bats checks):
#   timestamp context mesh_size service_count replicas namespace_count sidecar_scoping
#   istiod_mem_mi
#   convergence_p50_ms convergence_p99_ms queue_p50_ms queue_p99_ms
#   xds_pushes_delta xds_pushes_rate
#   xds_pushes_cds xds_pushes_eds xds_pushes_lds xds_pushes_rds xds_pushes_nds
#   k8s_events_delta k8s_events_rate
#   connected_proxies config_size_avg_bytes
#   sidecar_config_bytes_avg sidecar_config_bytes_p50 sidecar_config_bytes_max sidecar_config_bytes_samples
#   scrape_window_sec scrape_skew_ms settle_sec istiod_restarted
#   istiod_cpu_m_delta
#   go_heap_alloc_mi go_heap_inuse_mi
#   (cols 35-40) istiod_cpu_pct_of_limit istiod_mem_pct_of_limit
#                   node_cpu_pct node_mem_pct pods_scheduled pods_allocatable
#   (cols 41-43) cluster_connected_proxies sidecar_pods proxy_check
#     Per CONTEXT (same value on every row of that context in one window):
#     cluster_connected_proxies = pilot_xds summed over the context's istiod pods from
#     the same final batch (N/A when any pod scrape is incomplete or the Running istiod
#     pod set changed); sidecar_pods = Running, non-terminating pods with the
#     sidecar.istio.io/status annotation; proxy_check = OK|LOW|HIGH|N/A.
#     connected_proxies (col 22) stays the per-pod (per-replica) value.
#   (cols 44-51) traffic_config vsdr_services istiod_virt_services
#                push_time_avg_ms pushcontext_init_avg_ms
#                sidecar_clusters_avg sidecar_cds_bytes_avg sidecar_rds_bytes_avg
#     traffic_config / vsdr_services: what 001 deployed (none|vsdr; services with a
#     VS+DR, 0 for none). istiod_virt_services = pilot_virt_services (final scrape;
#     mesh-config gauge, identical on every replica, never summed across pods, PL28).
#     push_time_avg_ms / pushcontext_init_avg_ms = 1000 * Δsum/Δcount of the
#     pilot_xds_push_time / pilot_pushcontext_init_seconds histograms (PL11), N/A on a
#     restarted/unknown row or with no observation in the window (PL13).
#     sidecar_*: averages over the sampled config dumps (dynamic CDS clusters, compact
#     JSON size of the CDS and RDS sections); N/A without a sample.
if [[ "$PHASE" != baseline ]] && ! grep -q '^timestamp' "$TSV_FILE" 2>/dev/null; then
	echo -e "timestamp\tcontext\tmesh_size\tservice_count\treplicas\tnamespace_count\tsidecar_scoping\tistiod_mem_mi\tconvergence_p50_ms\tconvergence_p99_ms\tqueue_p50_ms\tqueue_p99_ms\txds_pushes_delta\txds_pushes_rate\txds_pushes_cds\txds_pushes_eds\txds_pushes_lds\txds_pushes_rds\txds_pushes_nds\tk8s_events_delta\tk8s_events_rate\tconnected_proxies\tconfig_size_avg_bytes\tsidecar_config_bytes_avg\tsidecar_config_bytes_p50\tsidecar_config_bytes_max\tsidecar_config_bytes_samples\tscrape_window_sec\tscrape_skew_ms\tsettle_sec\tistiod_restarted\tistiod_cpu_m_delta\tgo_heap_alloc_mi\tgo_heap_inuse_mi\tistiod_cpu_pct_of_limit\tistiod_mem_pct_of_limit\tnode_cpu_pct\tnode_mem_pct\tpods_scheduled\tpods_allocatable\tcluster_connected_proxies\tsidecar_pods\tproxy_check\ttraffic_config\tvsdr_services\tistiod_virt_services\tpush_time_avg_ms\tpushcontext_init_avg_ms\tsidecar_clusters_avg\tsidecar_cds_bytes_avg\tsidecar_rds_bytes_avg" >> "$TSV_FILE"
fi

PF_PIDS=()
TMP_DIR="$(mktemp -d -t controlplane-002.XXXXXX)"

cleanup() {
	for pid in "${PF_PIDS[@]}"; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	PF_PIDS=()
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Per-pod port-forward targeting.
# ---------------------------------------------------------------------------
# Port-forward to individual istiod pods (not svc/istiod) so that split-phase
# baseline/final scrapes always hit the same physical process.  In multi-replica
# deployments each replica gets its own port-forward and emits its own TSV row.

POD_CTXS=()
POD_NAMES=()
# Contexts with zero running istiod pods. Persisted to the state-dir so the final
# phase emits one degraded N/A row per dropped context (counted in n_total,
# excluded from n_valid).
DROPPED_CTXS=()

resolve_pods() {
	POD_CTXS=()
	POD_NAMES=()
	for ctx in "${CONTEXTS[@]}"; do
		local pods
		pods=$("${KUBECTL[@]}" --context="$ctx" -n istio-system get pods -l app=istiod \
			--field-selector=status.phase=Running \
			-o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
		# One context with zero istiod pods is dropped (degraded row later); only
		# zero pods across ALL contexts is fatal.
		if [[ -z "$pods" ]]; then
			echo "warning: context $ctx: no running istiod pods in istio-system; dropping this context (will emit a degraded N/A row)" >&2
			DROPPED_CTXS+=("$ctx")
			continue
		fi
		for pod in $pods; do
			POD_CTXS+=("$ctx")
			POD_NAMES+=("$pod")
		done
	done
	((${#POD_CTXS[@]})) || die "no running istiod pods found in istio-system across ANY context (${CONTEXTS[*]}) — cannot proceed"
}

save_pod_manifest() {
	local dir="$1"
	for k in "${!POD_CTXS[@]}"; do
		printf '%d\t%s\t%s\n' "$k" "${POD_CTXS[k]}" "${POD_NAMES[k]}"
	done > "${dir}/pods.tsv"
	# Persist dropped (zero-pod) contexts so the final phase can emit N/A rows.
	: > "${dir}/dropped-ctxs.tsv"
	local dctx
	for dctx in "${DROPPED_CTXS[@]}"; do
		printf '%s\n' "$dctx" >> "${dir}/dropped-ctxs.tsv"
	done
}

load_pod_manifest() {
	local dir="$1"
	local manifest="${dir}/pods.tsv"
	[[ -f "$manifest" ]] || die "no pods.tsv in $dir — run --phase baseline first"
	POD_CTXS=()
	POD_NAMES=()
	while IFS=$'\t' read -r _idx ctx pod; do
		POD_CTXS+=("$ctx")
		POD_NAMES+=("$pod")
	done < "$manifest"
	((${#POD_CTXS[@]})) || die "pods.tsv in $dir is empty"
	# Reload dropped contexts recorded at baseline.
	DROPPED_CTXS=()
	if [[ -f "${dir}/dropped-ctxs.tsv" ]]; then
		local dctx
		while IFS= read -r dctx; do
			[[ -n "$dctx" ]] && DROPPED_CTXS+=("$dctx")
		done < "${dir}/dropped-ctxs.tsv"
	fi
	for k in "${!POD_CTXS[@]}"; do
		if ! "${KUBECTL[@]}" --context="${POD_CTXS[k]}" -n istio-system get pod "${POD_NAMES[k]}" &>/dev/null; then
			echo "warning: pod ${POD_NAMES[k]} on ${POD_CTXS[k]} no longer exists; row will show as restarted" >&2
		fi
	done
}

if [[ "$PHASE" == final ]]; then
	load_pod_manifest "$STATE_DIR"
else
	resolve_pods
	if [[ "$PHASE" == baseline ]]; then
		save_pod_manifest "$STATE_DIR"
	fi
fi

echo "Starting port-forwards to istiod..."
for k in "${!POD_CTXS[@]}"; do
	port=$(( BASE_PF_PORT + k ))
	"${KUBECTL[@]}" --context="${POD_CTXS[k]}" -n istio-system port-forward "pod/${POD_NAMES[k]}" "$port":15014 >/dev/null 2>&1 &
	PF_PIDS+=($!)
done

sleep 3

for k in "${!POD_CTXS[@]}"; do
	port=$(( BASE_PF_PORT + k ))
	attempts=0
	restarts=0
	# --max-time bounds each probe: without it a stuck/half-open port-forward makes
	# curl block ~30s/attempt, so one bad PF among 35-50 at scale hangs the sweep for
	# minutes before failing. A transient kubectl port-forward failure is common at
	# high concurrency, so restart this pod's PF (up to 3x) instead of dying outright.
	# Intentionally NOT routed through METRICS_SCRAPE_TIMEOUT: this is a lightweight
	# PF-liveness probe (-o /dev/null discards the body, so payload size is irrelevant)
	# that must fail FAST to drive the PF-restart loop -- a 30s ceiling here would
	# stall the loop for minutes. Only the body-fetch scrapes (scrape_one_context,
	# poll_peak_metrics) honor the shared knob; this readiness check stays short.
	while ! curl -s -o /dev/null --max-time 2 "http://localhost:$port/metrics" 2>/dev/null; do
		attempts=$((attempts + 1))
		if ((attempts > 20)); then
			if ((restarts >= 3)); then
				# Give up on this pod: its empty final scrape becomes an N/A row
				# (restarted=unknown), counted in n_total but not n_valid.
				echo "warning: port-forward to istiod pod ${POD_NAMES[k]} on ${POD_CTXS[k]} (port $port) failed after ${restarts} restarts; this pod will emit an N/A row (restarted=unknown)" >&2
				kill "${PF_PIDS[k]}" 2>/dev/null || true
				break
			fi
			restarts=$((restarts + 1))
			attempts=0
			# Kill the stuck PF (free its local port) and replace its slot before retrying.
			kill "${PF_PIDS[k]}" 2>/dev/null || true
			"${KUBECTL[@]}" --context="${POD_CTXS[k]}" -n istio-system port-forward "pod/${POD_NAMES[k]}" "$port":15014 >/dev/null 2>&1 &
			PF_PIDS[k]=$!
			sleep 1
		fi
		sleep 0.5
	done
done
echo "Port-forwards ready."

# ---------------------------------------------------------------------------
# Metric extraction helpers.
# ---------------------------------------------------------------------------

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
		split(buckets[n], lastp, " ")
		total = lastp[2] + 0
		if (total <= 0) { print "N/A"; exit }
		target = total * q
		# Linear interpolation WITHIN the matched bucket (Prometheus
		# histogram_quantile semantics: uniform distribution assumed within a
		# bucket). Buckets are cumulative and ascending by le; the lower bound
		# of the first bucket is 0. Emitting the bucket upper bound (le) instead
		# floors the quantile and understates the tail when mass sits inside a
		# coarse bucket (FINDING #5 — convergence floored to 100ms at small scale).
		prev_le = 0; prev_cum = 0
		for(i=1;i<=n;i++) {
			split(buckets[i], parts, " ")
			cum = parts[2] + 0
			if(cum >= target) {
				if(parts[1] == "+Inf") { print "overflow"; exit }
				le_val = parts[1] + 0
				if(cum > prev_cum)
					val = prev_le + (le_val - prev_le) * (target - prev_cum) / (cum - prev_cum)
				else
					val = le_val
				printf "%.0f\n", val * 1000
				exit
			}
			prev_le = parts[1] + 0
			prev_cum = cum
		}
		print "N/A"
	}'
}

extract_gauge_exact() {
	local metrics="$1" name="$2"
	echo "$metrics" | awk -v name="$name" '
	BEGIN { pat = "^" name "(\\{| )" }
	!/^#/ && $0 ~ pat { val = $NF+0 }
	END { if (val == "") print "N/A"; else print val }
	'
}

extract_hist_sum() {
	local metrics="$1" name="$2"
	echo "$metrics" | awk -v name="${name}_sum" '
	BEGIN { pat = "^" name "(\\{| )" }
	!/^#/ && $0 ~ pat { s += $NF+0 }
	END { printf "%.6f\n", s+0 }
	'
}
extract_hist_count() {
	local metrics="$1" name="$2"
	echo "$metrics" | awk -v name="${name}_count" '
	BEGIN { pat = "^" name "(\\{| )" }
	!/^#/ && $0 ~ pat { c += $NF+0 }
	END { printf "%.0f\n", c+0 }
	'
}

# hist_delta_avg_ms <baseline> <final> <name>: average observation over the window,
# 1000 * Δ<name>_sum / Δ<name>_count (a seconds histogram -> ms), summed over all
# label series (PL11). N/A when nothing was observed (Δcount <= 0) or Δsum < 0.
hist_delta_avg_ms() {
	local baseline="$1" final="$2" name="$3" b_sum f_sum b_cnt f_cnt
	b_sum=$([[ -n "$baseline" ]] && extract_hist_sum "$baseline" "$name" || echo 0)
	f_sum=$(extract_hist_sum "$final" "$name")
	b_cnt=$([[ -n "$baseline" ]] && extract_hist_count "$baseline" "$name" || echo 0)
	f_cnt=$(extract_hist_count "$final" "$name")
	awk -v bs="$b_sum" -v fs="$f_sum" -v bc="$b_cnt" -v fc="$f_cnt" '
		BEGIN {
			ds = fs - bs; dc = fc - bc
			if (dc <= 0 || ds < 0) { print "N/A"; exit }
			printf "%.2f", 1000 * ds / dc
		}'
}

delta_histogram() {
	local baseline="$1" final="$2" name="$3"
	awk -v name="${name}_bucket" '
	function leval(line) {
		s = line; sub(/.*le="/, "", s); sub(/".*/, "", s); return s
	}
	function le_key(le,    k) {
		if (le == "+Inf") return 1e308
		k = le + 0
		return k
	}
	NR==FNR {
		if ($0 ~ name && /le="/) base[leval($0)] += $NF+0
		next
	}
	$0 ~ name && /le="/ {
		le = leval($0)
		final_v[le] += $NF+0
		if (!(le in seen)) { seen[le] = 1; les[++n] = le }
	}
	END {
		for (i = 1; i <= n; i++) sortable[i] = les[i]
		for (i = 2; i <= n; i++) {
			j = i
			while (j > 1 && le_key(sortable[j-1]) > le_key(sortable[j])) {
				t = sortable[j-1]; sortable[j-1] = sortable[j]; sortable[j] = t
				j--
			}
		}
		# PL14: if ANY per-bucket delta is negative, the histogram is
		# corrupt (counter rotation / label drift / undetected restart).
		# Emit nothing so the caller produces N/A for all quantiles.
		mname = name; sub(/_bucket$/, "", mname)
		bad = 0
		for (i = 1; i <= n; i++) {
			le = sortable[i]
			delta = final_v[le] - (le in base ? base[le] : 0)
			if (delta < 0) { bad = 1; break }
		}
		if (bad) exit
		for (i = 1; i <= n; i++) {
			le = sortable[i]
			delta = final_v[le] - (le in base ? base[le] : 0)
			printf "%s_bucket{le=\"%s\"} %d\n", mname, le, delta
		}
	}
	' <(echo "$baseline") <(echo "$final")
}

# ---------------------------------------------------------------------------
# Per-sidecar /config_dump sampling.
# ---------------------------------------------------------------------------

deterministic_pick() {
	local n="$1" seed="$2"
	awk -v n="$n" -v seed="$seed" '
	function ord(c) { return index("\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !\"#$%&\x27()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~", c) }
	function hash(s,   i, h) {
		h=5381
		for(i=1; i<=length(s); i++) h = (h*131 + ord(substr(s,i,1))) % 2147483647
		for(i=length(s); i>=1; i--) h = (h*131 + ord(substr(s,i,1))) % 2147483647
		return h
	}
	NF { lines[++idx]=$0; keys[idx]=hash($0 "|" seed) }
	END {
		for(i=1;i<=idx;i++) for(j=i+1;j<=idx;j++) if (keys[i] > keys[j]) {
			t=keys[i]; keys[i]=keys[j]; keys[j]=t
			t=lines[i]; lines[i]=lines[j]; lines[j]=t
		}
		k = (n < idx ? n : idx)
		for(i=1;i<=k;i++) print lines[i]
	}'
}

# Prints "<bytes csv>|attempted=<n>|got=<n>|clusters=<csv>|cds=<csv>|rds=<csv>": per
# sampled pod, the dump size and its config_dump_breakdown fields (N/A for a failed
# sample or an unparseable dump).
collect_config_dump_samples() {
	local ctx="$1" samples="$2"
	local out_csv="" got=0 attempted=0 cl_csv="" cds_csv="" rds_csv=""
	local dump_file="${TMP_DIR}/config-dump-sample.json"
	if (( samples == 0 )); then
		echo ""
		return 0
	fi
	local pod_lines
	pod_lines="$("${KUBECTL[@]}" get pods --context="$ctx" --all-namespaces \
		-l app.kubernetes.io/instance=controlplane-test \
		-o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.namespace}{"|"}{.metadata.name}{"\n"}{end}' \
		2>/dev/null || true)"
	local seed="${RUN_ID}-${ctx}"
	local picked
	picked="$(echo "$pod_lines" | grep -v '^$' | deterministic_pick "$samples" "$seed" 2>/dev/null || true)"
	[[ -z "$picked" ]] && { echo ""; return 0; }
	while IFS='|' read -r ns pod; do
		[[ -z "$pod" ]] && continue
		attempted=$((attempted + 1))
		# P2: bound the config_dump exec — at 10k services the dump is multi-MB and a
		# wedged sidecar/exec must not stall the sweep. On timeout the dump is empty ->
		# bytes=0 -> counted as a FAILED sample (got not incremented), never a partial/
		# misleading byte count (capturing first lets us drop a timed-out exec cleanly).
		local dump bytes bd v
		dump="$(timeout "${CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S:-30}s" "${KUBECTL[@]}" --context="$ctx" -n "$ns" exec "$pod" -c istio-proxy -- \
			pilot-agent request GET "/config_dump?include_eds" 2>/dev/null)" || dump=""
		bytes="$(printf '%s' "$dump" | wc -c)"
		bytes="$(echo "$bytes" | tr -d '[:space:]')"
		bd="unknown"
		if [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]]; then
			got=$((got + 1))
			out_csv+="${bytes},"
			# CDS/RDS breakdown of the same dump (one jq pass; unknown if unparseable).
			printf '%s' "$dump" > "$dump_file"
			bd="$(config_dump_breakdown "$dump_file")"
			rm -f "$dump_file"
		else
			out_csv+="N/A,"
		fi
		v="$(kv_get clusters "$bd")"; [[ "$v" =~ ^[0-9]+$ ]] || v="N/A"; cl_csv+="${v},"
		v="$(kv_get cds_bytes "$bd")"; [[ "$v" =~ ^[0-9]+$ ]] || v="N/A"; cds_csv+="${v},"
		v="$(kv_get rds_bytes "$bd")"; [[ "$v" =~ ^[0-9]+$ ]] || v="N/A"; rds_csv+="${v},"
	done <<<"$picked"
	out_csv="${out_csv%,}"
	echo "${out_csv}|attempted=${attempted}|got=${got}|clusters=${cl_csv%,}|cds=${cds_csv%,}|rds=${rds_csv%,}"
}

aggregate_sample_bytes() {
	local csv="$1"
	[[ -z "$csv" ]] && { echo "N/A|N/A|N/A"; return; }
	echo "$csv" | awk -F',' '
	{
		n=0
		for(i=1;i<=NF;i++) {
			if($i ~ /^[0-9]+$/) vals[++n]=$i+0
		}
		if(n==0){print "N/A|N/A|N/A"; exit}
		for(i=1;i<=n;i++) for(j=i+1;j<=n;j++) if(vals[i]>vals[j]){t=vals[i];vals[i]=vals[j];vals[j]=t}
		sum=0; for(i=1;i<=n;i++) sum+=vals[i]
		avg=sum/n
		p50=vals[int((n+1)/2)]
		max=vals[n]
		printf "%.0f|%.0f|%.0f\n", avg, p50, max
	}'
}

# ---------------------------------------------------------------------------
# Peak metrics poller (combined mode).
# ---------------------------------------------------------------------------
# Polls process_resident_memory_bytes and process_cpu_seconds_total every
# POLL_INTERVAL seconds, tracking peak memory and peak CPU rate per pod. The rate
# divides by the measured time between samples (a slow scrape stretches it).
# Results are written to ${TMP_DIR}/peak-{mem,cpu}-${k}.val.
POLL_INTERVAL=5

poll_peak_metrics() {
	local duration="$1"
	(( duration > 0 )) || return 0
	echo "  Polling peak metrics every ${POLL_INTERVAL}s for ${duration}s..."
	local elapsed=0
	while (( elapsed < duration )); do
		for k in "${!POD_CTXS[@]}"; do
			local port=$(( BASE_PF_PORT + k ))
			local body
			# Full /metrics body: honor METRICS_SCRAPE_TIMEOUT (MB-class at 10k services).
			body=$(curl -s --max-time "${METRICS_SCRAPE_TIMEOUT:-30}" "http://localhost:${port}/metrics" 2>/dev/null) || continue
			local now_t
			now_t=$(now_ms)

			# Peak memory.
			local mem_val
			mem_val=$(echo "$body" | awk '/^process_resident_memory_bytes[{ ]/ && !/^#/ { print $NF+0 }')
			if [[ -n "$mem_val" && "$mem_val" != "0" ]]; then
				local prev_mem=0
				[[ -s "${TMP_DIR}/peak-mem-${k}.val" ]] && prev_mem=$(<"${TMP_DIR}/peak-mem-${k}.val")
				if awk -v a="$mem_val" -v b="$prev_mem" 'BEGIN{ exit !(a+0 > b+0) }'; then
					printf '%s' "$mem_val" > "${TMP_DIR}/peak-mem-${k}.val"
				fi
			fi

			# Peak CPU rate in millicores: cpu-seconds delta / elapsed seconds * 1000.
			local cpu_val
			cpu_val=$(echo "$body" | awk '/^process_cpu_seconds_total[{ ]/ && !/^#/ { print $NF+0 }')
			if [[ -n "$cpu_val" && "$cpu_val" != "0" ]]; then
				local prev_cpu_file="${TMP_DIR}/prev-cpu-${k}.val"
				if [[ -s "$prev_cpu_file" ]]; then
					local prev_cpu prev_t rate_m
					read -r prev_cpu prev_t < "$prev_cpu_file" || true
					rate_m=$(awk -v c="$cpu_val" -v p="$prev_cpu" -v dt="$(( now_t - prev_t ))" \
						'BEGIN{ if (dt <= 0) { print 0; exit }; d=(c-p)*1000000/dt; if(d<0) d=0; printf "%.0f", d }')
					local prev_peak=0
					[[ -s "${TMP_DIR}/peak-cpu-${k}.val" ]] && prev_peak=$(<"${TMP_DIR}/peak-cpu-${k}.val")
					if awk -v a="$rate_m" -v b="$prev_peak" 'BEGIN{ exit !(a+0 > b+0) }'; then
						printf '%s' "$rate_m" > "${TMP_DIR}/peak-cpu-${k}.val"
					fi
				fi
				printf '%s %s\n' "$cpu_val" "$now_t" > "$prev_cpu_file"
			fi
		done
		sleep "$POLL_INTERVAL"
		elapsed=$(( elapsed + POLL_INTERVAL ))
	done
}

# ---------------------------------------------------------------------------
# Scrape infrastructure.
# ---------------------------------------------------------------------------

scrape_one_context() {
	local ctx="$1" port="$2" out="$3" ts_start="$4" ts_end="$5"
	local body t_start t_end
	t_start=$(now_ms)
	# P4: --max-time bounds the scrape so a stuck/half-open PF among 35-50 returns 1
	# (-> empty metrics file -> N/A row via scrape_window) instead of hanging the
	# whole sweep. This is the PRIMARY body scrape feeding every TSV row, so it must
	# honor the shared METRICS_SCRAPE_TIMEOUT knob (default 30s): a multi-MB /metrics
	# body at 10k services can exceed a hardcoded 10s -> empty file -> silent N/A row,
	# the exact data-loss the configurable timeout closes. t_start/t_end wrap the curl
	# so a slow-but-successful scrape stamps real completion times -> scrape_window_sec
	# stays the true wall-clock window (PL3), not a settle-derived figure.
	body=$(curl -s --max-time "${METRICS_SCRAPE_TIMEOUT:-30}" "http://localhost:${port}/metrics" 2>/dev/null) || return 1
	t_end=$(now_ms)
	printf '%s' "$body" > "$out"
	printf '%s' "$t_start" > "$ts_start"
	printf '%s' "$t_end" > "$ts_end"
}

scrape_all_parallel() {
	local out_prefix="$1"
	local -a pids=()
	local -a ts_files=()
	local k port
	for k in "${!POD_CTXS[@]}"; do
		port=$(( BASE_PF_PORT + k ))
		local m_out="${out_prefix}-${k}.metrics"
		local t_out="${out_prefix}-${k}.ts"
		local te_out="${out_prefix}-${k}.tsend"
		(
			scrape_one_context "${POD_CTXS[k]}" "$port" "$m_out" "$t_out" "$te_out" || exit 1
		) &
		pids+=($!)
		ts_files+=("$t_out")
	done
	local rc=0
	for pid in "${pids[@]}"; do
		wait "$pid" || rc=$((rc + 1))
	done
	[[ $rc -eq 0 ]] || echo "warning: $rc scrape(s) failed for $out_prefix" >&2

	local min="" max="" t
	for t_out in "${ts_files[@]}"; do
		[[ -s "$t_out" ]] || continue
		t=$(<"$t_out")
		[[ -z "$min" || "$t" -lt "$min" ]] && min="$t"
		[[ -z "$max" || "$t" -gt "$max" ]] && max="$t"
	done
	if [[ -n "$min" && -n "$max" ]]; then
		echo $(( max - min ))
	else
		echo 0
	fi
}

compute_skew_ms() {
	local prefix="$1"
	local min="" max="" t k
	for k in "${!POD_CTXS[@]}"; do
		local t_file="${prefix}-${k}.ts"
		[[ -s "$t_file" ]] || continue
		t=$(<"$t_file")
		[[ -z "$min" || "$t" -lt "$min" ]] && min="$t"
		[[ -z "$max" || "$t" -gt "$max" ]] && max="$t"
	done
	if [[ -n "$min" && -n "$max" ]]; then
		echo $(( max - min ))
	else
		echo 0
	fi
}

# ---------------------------------------------------------------------------
# Per-context capacity columns (35-40).
# ---------------------------------------------------------------------------
# Cheap read-only kubectl gets (NOT in the scrape window — called once per ctx at
# row assembly). Each cap_* tolerates failure -> `unknown` -> we emit N/A so the
# report's is_num/NF logic treats it like any other N/A column. Results cached
# per ctx so multi-replica rows on the same ctx don't re-read.
declare -A CAP_CACHE  # ctx -> "icpu_pct imem_pct ncpu_pct nmem_pct pods_sched pods_alloc"
# The node list and the pod list are read first, together, by read_pod_counts_for_ctx:
# compute_cluster_proxies needs the sidecar count right after the final scrape (PL21),
# before any slow `kubectl top` read. Raw key=value strings, parsed by their consumers.
declare -A NODE_KV_CACHE  # ctx -> cap_node_totals output (cpu_m= mem_mi= pods= nodes= names=)
declare -A POD_KV_CACHE   # ctx -> cap_pod_count output (scheduled= sidecars=)

# kv_get <key> <kv_string>: one `key=value` token from a space-separated string, else unknown.
kv_get() {
	local key="$1" tok
	for tok in $2; do
		[[ "$tok" == "${key}="* ]] && { echo "${tok#"${key}="}"; return 0; }
	done
	echo "unknown"
}

# read_pod_counts_for_ctx <ctx>: fill NODE_KV_CACHE/POD_KV_CACHE once per window.
# Must run in the main shell (not in $(...)), or the cache is lost.
read_pod_counts_for_ctx() {
	local ctx="$1"
	[[ -n "${POD_KV_CACHE[$ctx]:-}" ]] && return 0
	local nt="" pc="" worker_csv
	# `|| true` keeps the parser's all-unknown line when kubectl fails (pipefail).
	nt="$(cap_node_totals "$ctx" "${KUBECTL[@]}")" || true
	NODE_KV_CACHE[$ctx]="$nt"
	worker_csv="$(kv_get names "$nt")"
	[[ "$worker_csv" == unknown ]] && worker_csv=""
	pc="$(cap_pod_count "$ctx" "$worker_csv" "${KUBECTL[@]}")" || true
	[[ -n "$pc" ]] || pc="scheduled=unknown sidecars=unknown"
	POD_KV_CACHE[$ctx]="$pc"
}

collect_capacity_for_ctx() {
	local ctx="$1"
	[[ -n "${CAP_CACHE[$ctx]:-}" ]] && return 0

	read_pod_counts_for_ctx "$ctx"
	local node_cpu_m node_mem_mi node_pods worker_csv pods_sched
	node_cpu_m="$(kv_get cpu_m "${NODE_KV_CACHE[$ctx]}")"
	node_mem_mi="$(kv_get mem_mi "${NODE_KV_CACHE[$ctx]}")"
	node_pods="$(kv_get pods "${NODE_KV_CACHE[$ctx]}")"
	worker_csv="$(kv_get names "${NODE_KV_CACHE[$ctx]}")"
	[[ "$worker_csv" == unknown ]] && worker_csv=""
	pods_sched="$(kv_get scheduled "${POD_KV_CACHE[$ctx]}")"

	local kv
	local used_cpu_m="unknown" used_mem_mi="unknown"
	# shellcheck disable=SC2207
	local -a nu=($(cap_node_used "$ctx" "$worker_csv" "${KUBECTL[@]}"))
	for kv in "${nu[@]}"; do
		case "$kv" in
			cpu_m=*) used_cpu_m="${kv#cpu_m=}" ;;
			mem_mi=*) used_mem_mi="${kv#mem_mi=}" ;;
		esac
	done

	# cap_istiod_limits returns the PER-REPLICA container limit + the replica count.
	# cap_istiod_used (below) SUMS usage across ALL istiod replicas, so the %-of-limit
	# denominator must be the AGGREGATE limit (per-replica × replicas) for the ratio to
	# share scope with its numerator — otherwise a healthy R-replica control plane reads
	# up to ~R×100%. (cf PL28 sum-vs-invariant scope.)
	local istd_cpu_m="unknown" istd_mem_mi="unknown" istd_rep="unknown"
	# shellcheck disable=SC2207
	local -a il=($(cap_istiod_limits "$ctx" "${KUBECTL[@]}"))
	for kv in "${il[@]}"; do
		case "$kv" in
			cpu_m=*) istd_cpu_m="${kv#cpu_m=}" ;;
			mem_mi=*) istd_mem_mi="${kv#mem_mi=}" ;;
			replicas=*) istd_rep="${kv#replicas=}" ;;
		esac
	done
	# Aggregate limit across replicas (unknown if any input is non-numeric).
	local istd_cpu_total="unknown" istd_mem_total="unknown"
	if [[ "$istd_cpu_m" =~ ^[0-9]+$ && "$istd_rep" =~ ^[0-9]+$ ]]; then istd_cpu_total=$(( istd_cpu_m * istd_rep )); fi
	if [[ "$istd_mem_mi" =~ ^[0-9]+$ && "$istd_rep" =~ ^[0-9]+$ ]]; then istd_mem_total=$(( istd_mem_mi * istd_rep )); fi

	local istd_used_cpu_m="unknown" istd_used_mem_mi="unknown"
	# shellcheck disable=SC2207
	local -a iu=($(cap_istiod_used "$ctx" "${KUBECTL[@]}"))
	for kv in "${iu[@]}"; do
		case "$kv" in
			cpu_m=*) istd_used_cpu_m="${kv#cpu_m=}" ;;
			mem_mi=*) istd_used_mem_mi="${kv#mem_mi=}" ;;
		esac
	done

	# Percent columns (N/A when any input unknown).
	local icpu_pct imem_pct ncpu_pct nmem_pct
	icpu_pct=$(cap_pct "$istd_used_cpu_m" "$istd_cpu_total"); [[ "$icpu_pct" == unknown ]] && icpu_pct="N/A"
	imem_pct=$(cap_pct "$istd_used_mem_mi" "$istd_mem_total"); [[ "$imem_pct" == unknown ]] && imem_pct="N/A"
	ncpu_pct=$(cap_pct "$used_cpu_m" "$node_cpu_m"); [[ "$ncpu_pct" == unknown ]] && ncpu_pct="N/A"
	nmem_pct=$(cap_pct "$used_mem_mi" "$node_mem_mi"); [[ "$nmem_pct" == unknown ]] && nmem_pct="N/A"
	[[ "$pods_sched" == unknown ]] && pods_sched="N/A"
	local pods_alloc="$node_pods"; [[ "$pods_alloc" == unknown ]] && pods_alloc="N/A"

	CAP_CACHE[$ctx]="${icpu_pct} ${imem_pct} ${ncpu_pct} ${nmem_pct} ${pods_sched} ${pods_alloc}"
}

# ---------------------------------------------------------------------------
# Per-cluster connected proxies + sanity check (cols 41-43).
# ---------------------------------------------------------------------------
# connected_proxies (col 22) is per istiod pod. Each proxy holds one istiod
# connection, so a cluster's total is pilot_xds summed over ALL its istiod pods
# (PL28), taken from the same final batch (PL8). The sum is strict (PL29): an empty
# or short pod scrape makes it N/A instead of a silent undercount, and so does a
# change in the Running istiod pod set since the pods were resolved (a new replica's
# proxies would be missing from the sum). The expected count is the context's
# Running injected pods, read right after the batch, outside the window (PL21; the
# few seconds between the two reads remain, which is why this is a warning with a
# tolerance). LOW/HIGH never filters a row.
declare -A CLUSTER_PROXIES  # ctx -> sum | N/A
declare -A SIDECAR_PODS     # ctx -> Running injected pods | N/A
declare -A PROXY_CHECK      # ctx -> OK | LOW | HIGH | N/A

compute_cluster_proxies() {
	local ctx k live scraped n_pods n_live total sidecars check
	local -a ctxs=() files=()
	local -A seen=()
	for k in "${!POD_CTXS[@]}"; do
		ctx="${POD_CTXS[k]}"
		[[ -n "${seen[$ctx]:-}" ]] && continue
		seen[$ctx]=1
		ctxs+=("$ctx")
	done
	# Expected side first, for every context, so it lands as close to the batch as
	# possible. Same node + pod lists the capacity columns use (no extra API call).
	for ctx in "${ctxs[@]}" "${DROPPED_CTXS[@]}"; do
		read_pod_counts_for_ctx "$ctx"
		sidecars="$(kv_get sidecars "${POD_KV_CACHE[$ctx]}")"
		[[ "$sidecars" =~ ^[0-9]+$ ]] || sidecars="N/A"
		SIDECAR_PODS[$ctx]="$sidecars"
	done
	for ctx in "${ctxs[@]}"; do
		files=()
		scraped=""
		for k in "${!POD_CTXS[@]}"; do
			[[ "${POD_CTXS[k]}" == "$ctx" ]] || continue
			files+=("${TMP_DIR}/final-${k}.metrics")
			scraped+="${POD_NAMES[k]}"$'\n'
		done
		n_pods=${#files[@]}
		scraped="$(printf '%s' "$scraped" | LC_ALL=C sort)"
		# PL40: a failed read degrades to N/A; it never aborts the run.
		live="$(fanout_list_istiod_pods "$ctx" "${KUBECTL[@]}")" || live=""
		if [[ -z "$live" ]]; then
			echo "warning: ${ctx}: could not list Running istiod pods after the final scrape; cluster_connected_proxies=N/A" >&2
			total="N/A"
		elif [[ "$live" != "$scraped" ]]; then
			n_live="$(printf '%s\n' "$live" | grep -c .)" || n_live="?"
			echo "warning: ${ctx}: Running istiod pod set changed during the window (scraped ${n_pods} pod(s), now ${n_live}); cluster_connected_proxies=N/A" >&2
			total="N/A"
		else
			total="$(fanout_gauge_sum_strict pilot_xds "${files[@]}")"
			if [[ "$total" == unknown ]]; then
				echo "warning: ${ctx}: an istiod pod's final scrape is empty or short; cluster_connected_proxies=N/A (no partial sum)" >&2
				total="N/A"
			fi
		fi
		sidecars="${SIDECAR_PODS[$ctx]}"
		check="$(cap_proxy_check "$total" "$sidecars" "$PROXY_CHECK_TOL_PCT" "$PROXY_CHECK_MIN_DIFF")"
		CLUSTER_PROXIES[$ctx]="$total"
		PROXY_CHECK[$ctx]="$check"
		echo "  Cluster ${ctx}: connected_proxies=${total} over ${n_pods} istiod pod(s), sidecar_pods=${sidecars}, proxy_check=${check}"
		if [[ "$check" == LOW || "$check" == HIGH ]]; then
			echo "warning: ${ctx}: connected proxies ${total} (sum over ${n_pods} istiod pods) vs Running sidecar pods ${sidecars}: ${check} (differ by more than max(${PROXY_CHECK_TOL_PCT}%, ${PROXY_CHECK_MIN_DIFF}))" >&2
		fi
	done
	# Dropped (zero-pod) contexts: no total, no check; the sidecar count was read above.
	for ctx in "${DROPPED_CTXS[@]}"; do
		CLUSTER_PROXIES[$ctx]="N/A"
		PROXY_CHECK[$ctx]="N/A"
	done
}

# cluster_fields <ctx>: cols 41-43 for a row of that context, tab-separated.
cluster_fields() {
	local ctx="$1"
	printf '%s\t%s\t%s' "${CLUSTER_PROXIES[$ctx]:-N/A}" "${SIDECAR_PODS[$ctx]:-N/A}" "${PROXY_CHECK[$ctx]:-N/A}"
}

# traffic_na_fields: cols 44-51 for a row with nothing measured (no final scrape, or a
# dropped context): the deployed traffic config, then N/A.
traffic_na_fields() {
	printf '%s\t%s\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A' "$TRAFFIC_CONFIG" "$VSDR_SERVICES"
}

# ---------------------------------------------------------------------------
# Main scrape_window: baseline + final + deltas + emit TSV rows.
# ---------------------------------------------------------------------------

scrape_window() {
	local sleep_sec="$1"
	local skip_baseline="${2:-0}"
	local settle_input_sec="${3:-$sleep_sec}"
	local baseline_skew_ms final_skew_ms
	if (( skip_baseline )); then
		echo "  Baseline scrape: skipped (using pre-populated baseline from state-dir)."
		baseline_skew_ms=$(compute_skew_ms "${TMP_DIR}/baseline")
	else
		echo "  Baseline scrape..."
		baseline_skew_ms=$(scrape_all_parallel "${TMP_DIR}/baseline")
	fi
	if (( sleep_sec > 0 )); then
		poll_peak_metrics "$sleep_sec"
	fi
	echo "  Final scrape..."
	final_skew_ms=$(scrape_all_parallel "${TMP_DIR}/final")
	local total_skew_ms=$(( baseline_skew_ms > final_skew_ms ? baseline_skew_ms : final_skew_ms ))
	# Per-cluster total + check (cols 41-43), right after the final batch.
	compute_cluster_proxies

	local b_max_ms="" f_min_ms="" ts_val
	for k in "${!POD_CTXS[@]}"; do
		local bt="${TMP_DIR}/baseline-${k}.tsend"
		local ft="${TMP_DIR}/final-${k}.ts"
		if [[ -s "$bt" ]]; then
			ts_val=$(<"$bt")
			[[ -z "$b_max_ms" || "$ts_val" -gt "$b_max_ms" ]] && b_max_ms="$ts_val"
		fi
		if [[ -s "$ft" ]]; then
			ts_val=$(<"$ft")
			[[ -z "$f_min_ms" || "$ts_val" -lt "$f_min_ms" ]] && f_min_ms="$ts_val"
		fi
	done
	local window_sec window_positive
	if [[ -n "$b_max_ms" && -n "$f_min_ms" ]] && (( f_min_ms > b_max_ms )); then
		window_sec=$(awk -v ms=$(( f_min_ms - b_max_ms )) 'BEGIN{ printf "%.1f", ms/1000 }')
	else
		window_sec=$(awk -v s="$settle_input_sec" 'BEGIN{ printf "%.1f", s+0 }')
	fi
	window_positive=$(awk -v w="$window_sec" 'BEGIN{ print (w+0 > 0) ? 1 : 0 }')

	local ts
	ts=$(date -u -Iseconds)

	for k in "${!POD_CTXS[@]}"; do
		ctx="${POD_CTXS[k]}"

		local b_file="${TMP_DIR}/baseline-${k}.metrics"
		local f_file="${TMP_DIR}/final-${k}.metrics"
		if [[ ! -s "$f_file" ]]; then
			echo "warning: no final scrape for $ctx/${POD_NAMES[k]}; emitting N/A row" >&2
			# PL13: push-by-type and config-sample columns are N/A (nothing measured),
			# not literal 0/0/0 which would read as a real zero-push observation.
			# Capacity columns are still meaningful for a real context.
			# Cols 41-43 come from the cluster: its total is already N/A (strict sum).
			collect_capacity_for_ctx "$ctx"
			cap_fields="${CAP_CACHE[$ctx]}"; cap_fields="${cap_fields// /$'\t'}"
			echo -e "${ts}\t${ctx}\t${MESH_SIZE}\t${SERVICE_COUNT}\t${REPLICAS}\t${NAMESPACE_COUNT}\t${SIDECAR_SCOPING}\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t${window_sec}\t${total_skew_ms}\t${settle_input_sec}\tunknown\tN/A\tN/A\tN/A\t${cap_fields}\t$(cluster_fields "$ctx")\t$(traffic_na_fields)" >> "$TSV_FILE"
			continue
		fi
		local baseline final
		baseline=$([[ -s "$b_file" ]] && cat "$b_file" || echo "")
		final=$(cat "$f_file")

		# Memory: peak of (baseline, polled peaks, final) in MiB.
		local final_mem_bytes baseline_mem_bytes peak_mem_bytes mem_mi
		final_mem_bytes=$(extract_gauge_exact "$final" process_resident_memory_bytes)
		baseline_mem_bytes=$([[ -n "$baseline" ]] \
			&& extract_gauge_exact "$baseline" process_resident_memory_bytes || echo 0)
		peak_mem_bytes=0
		[[ -s "${TMP_DIR}/peak-mem-${k}.val" ]] && peak_mem_bytes=$(<"${TMP_DIR}/peak-mem-${k}.val")
		if [[ "$final_mem_bytes" != "N/A" ]]; then
			mem_mi=$(awk -v f="$final_mem_bytes" -v b="$baseline_mem_bytes" -v p="$peak_mem_bytes" '
				BEGIN {
					m = f+0
					if (b+0 > m) m = b+0
					if (p+0 > m) m = p+0
					printf "%.0f", m / 1048576
				}')
		else
			mem_mi="N/A"
		fi

		# Connected proxies on THIS pod (per replica): pilot_xds summed across its label
		# series (PL12, final scrape). Same completeness rule as the cluster sum: a
		# complete body with no pilot_xds series is 0 (a replica with no connections);
		# an empty or short body stays N/A (PL29).
		local connected_proxies
		connected_proxies=$(fanout_gauge_sum_strict pilot_xds "$f_file")
		[[ "$connected_proxies" == "unknown" ]] && connected_proxies="N/A"

		# Restart detection (must run before delta computations so the
		# restart guard can protect counter/histogram columns — PL9/PL13).
		local b_pst f_pst istiod_restarted
		b_pst=$([[ -n "$baseline" ]] && extract_gauge_exact "$baseline" process_start_time_seconds || echo N/A)
		f_pst=$(extract_gauge_exact "$final" process_start_time_seconds)
		istiod_restarted=$(awk -v b="$b_pst" -v f="$f_pst" '
			BEGIN {
				if (b == "N/A" || f == "N/A") { print "unknown"; exit }
				print (f+0 > b+0) ? 1 : 0
			}')
		if [[ "$istiod_restarted" == "1" ]]; then
			echo "warning: istiod restart detected during scrape window on ${ctx} (process_start_time_seconds ${b_pst} -> ${f_pst})" >&2
		fi

		# Restart guard: when istiod restarted (or state is unknown), all
		# counter deltas, histogram quantiles, and derived rates are invalid
		# because the counters reset to zero mid-window (PL13).
		local restarted_or_unknown=0
		if [[ "$istiod_restarted" == "1" || "$istiod_restarted" == "unknown" ]]; then
			restarted_or_unknown=1
		fi

		# Delta-window histograms.
		local conv_p50 conv_p99 queue_p50 queue_p99
		if (( restarted_or_unknown )); then
			conv_p50="N/A"; conv_p99="N/A"; queue_p50="N/A"; queue_p99="N/A"
		else
			local conv_delta_text queue_delta_text
			conv_delta_text=$(delta_histogram "$baseline" "$final" "pilot_proxy_convergence_time")
			queue_delta_text=$(delta_histogram "$baseline" "$final" "pilot_proxy_queue_time")
			conv_p50=$(extract_histogram_quantile "$conv_delta_text" "pilot_proxy_convergence_time" "0.5")
			conv_p99=$(extract_histogram_quantile "$conv_delta_text" "pilot_proxy_convergence_time" "0.99")
			queue_p50=$(extract_histogram_quantile "$queue_delta_text" "pilot_proxy_queue_time" "0.5")
			queue_p99=$(extract_histogram_quantile "$queue_delta_text" "pilot_proxy_queue_time" "0.99")
		fi

		# Counter deltas (xds pushes + k8s events).
		local pushes_delta pushes_rate evts_delta evts_rate
		if (( restarted_or_unknown )); then
			pushes_delta="N/A"; pushes_rate="N/A"
			evts_delta="N/A"; evts_rate="N/A"
		else
			local b_pushes f_pushes
			b_pushes=$([[ -s "$b_file" ]] && extract_counter_sum "$b_file" pilot_xds_pushes || echo 0)
			f_pushes=$(extract_counter_sum "$f_file" pilot_xds_pushes)
			pushes_delta=$(( f_pushes - b_pushes ))
			(( pushes_delta < 0 )) && pushes_delta=0
			if (( window_positive )); then
				pushes_rate=$(awk -v d="$pushes_delta" -v w="$window_sec" 'BEGIN{ printf "%.2f", d/w }')
			else
				pushes_rate="N/A"
			fi

			local b_evts f_evts
			b_evts=$([[ -s "$b_file" ]] && extract_counter_sum "$b_file" pilot_k8s_cfg_events || echo 0)
			f_evts=$(extract_counter_sum "$f_file" pilot_k8s_cfg_events)
			evts_delta=$(( f_evts - b_evts ))
			(( evts_delta < 0 )) && evts_delta=0
			if (( window_positive )); then
				evts_rate=$(awk -v d="$evts_delta" -v w="$window_sec" 'BEGIN{ printf "%.2f", d/w }')
			else
				evts_rate="N/A"
			fi
		fi

		# Per-type xds_pushes deltas.
		local types=(cds eds lds rds nds)
		local push_by_type=()
		if (( restarted_or_unknown )); then
			push_by_type=("N/A" "N/A" "N/A" "N/A" "N/A")
		else
			for t in "${types[@]}"; do
				local b_t f_t d_t
				b_t=$([[ -s "$b_file" ]] && extract_counter_by_label "$b_file" pilot_xds_pushes type "$t" || echo 0)
				f_t=$(extract_counter_by_label "$f_file" pilot_xds_pushes type "$t")
				d_t=$(( f_t - b_t ))
				(( d_t < 0 )) && d_t=0
				push_by_type+=("$d_t")
			done
		fi

		# CPU: peak of (window average, per-interval peak) in millicores.
		local cpu_m_delta
		if (( restarted_or_unknown )); then
			cpu_m_delta="N/A"
		else
			local b_cpu_s f_cpu_s window_avg_m=0
			b_cpu_s=$([[ -n "$baseline" ]] && extract_gauge_exact "$baseline" process_cpu_seconds_total || echo N/A)
			f_cpu_s=$(extract_gauge_exact "$final" process_cpu_seconds_total)
			window_avg_m=$(awk -v b="$b_cpu_s" -v f="$f_cpu_s" -v w="$window_sec" '
				BEGIN {
					if (b == "N/A" || f == "N/A" || w+0 <= 0) { print 0; exit }
					d = (f - b) * 1000 / w
					if (d < 0) { print 0; exit }
					printf "%.0f", d
				}')
			local peak_cpu_m=0
			[[ -s "${TMP_DIR}/peak-cpu-${k}.val" ]] && peak_cpu_m=$(<"${TMP_DIR}/peak-cpu-${k}.val")
			cpu_m_delta=$(awk -v avg="$window_avg_m" -v peak="$peak_cpu_m" '
				BEGIN {
					m = avg+0
					if (peak+0 > m) m = peak+0
					if (m == 0) { print "N/A"; exit }
					printf "%.0f", m
				}')
		fi

		# Go heap metrics: point-in-time from final scrape (not peak).
		# These reveal steady-state memory independently of RSS, which
		# stays inflated after GC due to MADV_FREE.
		local go_heap_alloc_mi go_heap_inuse_mi
		local alloc_bytes inuse_bytes
		alloc_bytes=$(extract_gauge_exact "$final" go_memstats_alloc_bytes)
		inuse_bytes=$(extract_gauge_exact "$final" go_memstats_heap_inuse_bytes)
		if [[ "$alloc_bytes" != "N/A" ]]; then
			go_heap_alloc_mi=$(awk -v b="$alloc_bytes" 'BEGIN{ printf "%.0f", b / 1048576 }')
		else
			go_heap_alloc_mi="N/A"
		fi
		if [[ "$inuse_bytes" != "N/A" ]]; then
			go_heap_inuse_mi=$(awk -v b="$inuse_bytes" 'BEGIN{ printf "%.0f", b / 1048576 }')
		else
			go_heap_inuse_mi="N/A"
		fi

		# config_size: histogram, avg = (sum_delta / count_delta) bytes.
		local cs_avg
		if (( restarted_or_unknown )); then
			cs_avg="N/A"
		else
			local b_sum f_sum b_cnt f_cnt
			b_sum=$([[ -n "$baseline" ]] && extract_hist_sum "$baseline" pilot_xds_config_size_bytes || echo 0)
			f_sum=$(extract_hist_sum "$final" pilot_xds_config_size_bytes)
			b_cnt=$([[ -n "$baseline" ]] && extract_hist_count "$baseline" pilot_xds_config_size_bytes || echo 0)
			f_cnt=$(extract_hist_count "$final" pilot_xds_config_size_bytes)
			cs_avg=$(awk -v bs="$b_sum" -v fs="$f_sum" -v bc="$b_cnt" -v fc="$f_cnt" '
				BEGIN {
					ds = fs - bs; dc = fc - bc
					if (ds < 0) ds = 0
					if (dc <= 0) { print "N/A"; exit }
					printf "%.0f", ds/dc
				}')
		fi

		# Traffic-management istiod columns (44-51 are appended below). pilot_virt_services
		# is a gauge from the final scrape; the two timing averages are histogram deltas,
		# so they follow the restart guard like every other counter/histogram (PL13).
		local virt_services push_time_avg pushctx_avg
		virt_services=$(extract_gauge_exact "$final" pilot_virt_services)
		if (( restarted_or_unknown )); then
			push_time_avg="N/A"; pushctx_avg="N/A"
		else
			push_time_avg=$(hist_delta_avg_ms "$baseline" "$final" pilot_xds_push_time)
			pushctx_avg=$(hist_delta_avg_ms "$baseline" "$final" pilot_pushcontext_init_seconds)
		fi

		# Per-sidecar /config_dump sampling (only in final/combined phase).
		local cd_avg="N/A" cd_p50="N/A" cd_max="N/A" cd_samples="0/0"
		local sc_clusters="N/A" sc_cds="N/A" sc_rds="N/A"
		if (( CONFIG_DUMP_SAMPLES > 0 )); then
			local cd_out cd_csv cd_meta
			cd_out="$(collect_config_dump_samples "$ctx" "$CONFIG_DUMP_SAMPLES" || true)"
			cd_csv="${cd_out%%|*}"
			cd_meta="${cd_out#*|}"
			local attempted=0 got=0
			[[ "$cd_meta" =~ attempted=([0-9]+) ]] && attempted="${BASH_REMATCH[1]}"
			[[ "$cd_meta" =~ got=([0-9]+) ]] && got="${BASH_REMATCH[1]}"
			local agg
			agg="$(aggregate_sample_bytes "$cd_csv")"
			cd_avg="${agg%%|*}"
			cd_p50="$(echo "$agg" | awk -F'|' '{print $2}')"
			cd_max="$(echo "$agg" | awk -F'|' '{print $3}')"
			cd_samples="${got}/${attempted}"
			# Averages of the per-sample breakdown (first field of avg|p50|max).
			[[ "$cd_meta" =~ (^|\|)clusters=([^|]*) ]] && { agg="$(aggregate_sample_bytes "${BASH_REMATCH[2]}")"; sc_clusters="${agg%%|*}"; }
			[[ "$cd_meta" =~ (^|\|)cds=([^|]*) ]] && { agg="$(aggregate_sample_bytes "${BASH_REMATCH[2]}")"; sc_cds="${agg%%|*}"; }
			[[ "$cd_meta" =~ (^|\|)rds=([^|]*) ]] && { agg="$(aggregate_sample_bytes "${BASH_REMATCH[2]}")"; sc_rds="${agg%%|*}"; }
		fi

		# Capacity columns (read-only, cached per ctx, outside the scrape window).
		collect_capacity_for_ctx "$ctx"
		local cap_fields="${CAP_CACHE[$ctx]}"; cap_fields="${cap_fields// /$'\t'}"

		local tm_fields="${TRAFFIC_CONFIG}\t${VSDR_SERVICES}\t${virt_services}\t${push_time_avg}\t${pushctx_avg}\t${sc_clusters}\t${sc_cds}\t${sc_rds}"
		echo -e "${ts}\t${ctx}\t${MESH_SIZE}\t${SERVICE_COUNT}\t${REPLICAS}\t${NAMESPACE_COUNT}\t${SIDECAR_SCOPING}\t${mem_mi}\t${conv_p50}\t${conv_p99}\t${queue_p50}\t${queue_p99}\t${pushes_delta}\t${pushes_rate}\t${push_by_type[0]}\t${push_by_type[1]}\t${push_by_type[2]}\t${push_by_type[3]}\t${push_by_type[4]}\t${evts_delta}\t${evts_rate}\t${connected_proxies}\t${cs_avg}\t${cd_avg}\t${cd_p50}\t${cd_max}\t${cd_samples}\t${window_sec}\t${total_skew_ms}\t${settle_input_sec}\t${istiod_restarted}\t${cpu_m_delta}\t${go_heap_alloc_mi}\t${go_heap_inuse_mi}\t${cap_fields}\t$(cluster_fields "$ctx")\t${tm_fields}" >> "$TSV_FILE"
		echo "  Scraped $ctx/${POD_NAMES[k]}: cpu_delta=${cpu_m_delta}m mem=${mem_mi}Mi heap_alloc=${go_heap_alloc_mi}Mi heap_inuse=${go_heap_inuse_mi}Mi proxies=${connected_proxies} cluster=${CLUSTER_PROXIES[$ctx]:-N/A} sidecars=${SIDECAR_PODS[$ctx]:-N/A} check=${PROXY_CHECK[$ctx]:-N/A} pushes_delta=${pushes_delta} (eds=${push_by_type[1]} cds=${push_by_type[0]}) cfg_dump_avg=${cd_avg}"
		echo "    traffic=${TRAFFIC_CONFIG} vsdr_services=${VSDR_SERVICES} istiod_virt_services=${virt_services} push_time_avg=${push_time_avg}ms pushctx_init_avg=${pushctx_avg}ms sidecar_clusters_avg=${sc_clusters} cds_bytes_avg=${sc_cds} rds_bytes_avg=${sc_rds}"
	done

	# One degraded row per dropped (zero-pod) context: the context column keeps the
	# context name, restarted=unknown and every numeric column is N/A, so the row is
	# counted in n_total but excluded from n_valid.
	local dctx
	for dctx in "${DROPPED_CTXS[@]}"; do
		echo "warning: context ${dctx}: dropped (zero istiod pods); emitting degraded N/A row" >&2
		# Node capacity is still readable with zero istiod pods.
		collect_capacity_for_ctx "$dctx"
		local cap_fields="${CAP_CACHE[$dctx]}"; cap_fields="${cap_fields// /$'\t'}"
		echo -e "${ts}\t${dctx}\t${MESH_SIZE}\t${SERVICE_COUNT}\t${REPLICAS}\t${NAMESPACE_COUNT}\t${SIDECAR_SCOPING}\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t${window_sec}\t${total_skew_ms}\t${settle_input_sec}\tunknown\tN/A\tN/A\tN/A\t${cap_fields}\t$(cluster_fields "$dctx")\t$(traffic_na_fields)" >> "$TSV_FILE"
	done

	# istiod restart evidence for the contexts whose rows above say istiod_restarted 1 or
	# unknown (tests/lib/istiod-diag.sh, istiod-diag-<RUN_ID>/ next to the TSV). Reads the
	# rows back; no API call without a restart, and it never fails the window.
	istiod_diag_after_window "$ts"
}

if ((WATCH)); then
	echo "Watch mode: ${INTERVAL}s window between baseline and final scrapes (Ctrl-C to stop)"
	while true; do
		echo ""
		echo "=== Window at $(date -u -Iseconds) ==="
		# CAP_CACHE is a per-ctx memo so multi-replica rows in ONE window don't re-read
		# capacity. In watch mode each window is a fresh point-in-time sample, so clear it
		# between windows — otherwise the capacity columns (node util, istiod %-of-limit,
		# pods scheduled) freeze at the first window's read and silently go stale. Reads
		# are cheap, read-only, and outside the scrape window, so re-reading is safe.
		# The per-cluster proxy total, sidecar count and check are per window too.
		CAP_CACHE=()
		NODE_KV_CACHE=()
		POD_KV_CACHE=()
		CLUSTER_PROXIES=()
		SIDECAR_PODS=()
		PROXY_CHECK=()
		scrape_window "$INTERVAL"
	done
elif [[ "$PHASE" == baseline ]]; then
	echo ""
	echo "=== Baseline scrape only (phase=baseline) ==="
	echo "  Writing baseline metrics to $STATE_DIR"
	scrape_all_parallel "${STATE_DIR}/baseline" >/dev/null
	echo "  Baseline complete. Caller should now deploy workloads, settle, and"
	echo "  invoke this script again with --phase final --state-dir $STATE_DIR"
elif [[ "$PHASE" == final ]]; then
	echo ""
	echo "=== Final scrape + emit (phase=final) ==="
	echo "  Reading baseline from $STATE_DIR"
	for f in "${STATE_DIR}/baseline-"*; do
		[[ -e "$f" ]] || die "no baseline files in $STATE_DIR — run --phase baseline first"
		cp "$f" "${TMP_DIR}/$(basename "$f")"
	done
	for f in "${STATE_DIR}/peak-mem-"*.val "${STATE_DIR}/peak-cpu-"*.val; do
		[[ -e "$f" ]] && cp "$f" "${TMP_DIR}/$(basename "$f")"
	done
	scrape_window 0 1 "$SETTLE_SEC"
	echo ""
	echo "Results appended to $TSV_FILE"
else
	echo ""
	echo "=== Scraping control-plane metrics (phase=combined, window=${SETTLE_SEC}s) ==="
	scrape_window "$SETTLE_SEC"
	echo ""
	echo "Results appended to $TSV_FILE"
fi

# Generate per-run MD summary.
if [[ "$PHASE" == combined || "$PHASE" == final ]]; then
	MD_FILE="${OUTPUT_DIR}/controlplane-${RUN_ID}.md"
	{
		echo "# Control-Plane Resource Metrics"
		echo ""
		echo "| Field | Value |"
		echo "|-------|-------|"
		echo "| Run ID | \`${RUN_ID}\` |"
		echo "| Date | $(date -u -Iseconds) |"
		echo "| Phase | ${PHASE} |"
		echo "| Istio version | ${ISTIO_VERSION_TAG} |"
		echo "| Harness SHA | ${HARNESS_SHA} |"
		echo "| Run config | \`${RUN_CONFIG:-none}\` (sha256 \`${RUN_CONFIG_SHA256:-none}\`) |"
		echo "| Kube versions | ${KUBE_VERSIONS_CSV} |"
		echo "| Contexts | ${CONTEXTS[*]} |"
		echo "| Mesh size | ${MESH_SIZE} |"
		echo "| Service count | ${SERVICE_COUNT} |"
		echo "| Replicas | ${REPLICAS} |"
		echo "| Namespace count | ${NAMESPACE_COUNT} |"
		echo "| Sidecar scoping | ${SIDECAR_SCOPING} |"
		echo "| Traffic config | ${TRAFFIC_CONFIG} (VS+DR services ${VSDR_SERVICES}; every ${VSDR_EVERY}, ${VSDR_SUBSETS} subsets) |"
		echo "| Config-dump samples | ${CONFIG_DUMP_SAMPLES} |"
		echo "| Settle (s) | ${SETTLE_SEC} |"
		echo "| Proxy check tolerance | ${PROXY_CHECK_TOL_PCT}% (min diff ${PROXY_CHECK_MIN_DIFF}) |"
		echo ""
		echo "## Summary"
		echo ""
		echo "Proxies is per istiod pod; Cluster proxies sums them over the cluster's istiod pods."
		echo ""
		echo "| Context | mesh | svc | reps | ns | scoping | traffic | CPU avg (m) | Mem RSS (Mi) | Heap alloc (Mi) | Heap inuse (Mi) | Conv p99 (ms) | Queue p99 (ms) | Proxies | Cluster proxies | Sidecar pods | Proxy check | Pushes Δ | EDS Δ | CDS Δ | istiod VS | Cfg dump avg (MB) | Sidecar clusters |"
		echo "|---------|------|-----|------|----|---------|---------|-------------|--------------|-----------------|-----------------|---------------|----------------|---------|-----------------|--------------|-------------|----------|-------|-------|-----------|-------------------|------------------|"
		# Cols 41+ are read by header name: a reused older file (40 columns) has none.
		awk -F'\t' '
		/^timestamp\t/ { delete ix; for (i = 1; i <= NF; i++) ix[$i] = i; next }
		function c(name) { return ((name in ix) && NF >= ix[name]) ? $(ix[name]) : "N/A" }
		!/^#/ && NF>=40 {
			cfg_mb = ($24+0 > 0) ? sprintf("%.1f", $24/1048576) : "N/A"
			tc = c("traffic_config"); if (tc == "N/A") tc = "none"
			printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $2, $3, $4, $5, $6, $7, tc, $32, $8, $33, $34, $10, $12, $22, c("cluster_connected_proxies"), c("sidecar_pods"), c("proxy_check"), $13, $16, $15, c("istiod_virt_services"), cfg_mb, c("sidecar_clusters_avg")
		}' "$TSV_FILE"
		echo ""
		echo "## Raw Data"
		echo ""
		echo "TSV: [\`$(basename "$TSV_FILE")\`]($(basename "$TSV_FILE"))"
	} > "$MD_FILE"
	echo "Summary written to $MD_FILE"
fi

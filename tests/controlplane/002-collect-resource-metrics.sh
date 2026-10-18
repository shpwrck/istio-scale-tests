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
#   ./tests/controlplane/002-collect-resource-metrics.sh \
#     --config tests/controlplane/configs/smoke.env
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
source "${ROOT}/tests/lib/growth.sh"  # gateway Envoy stats, root-cert count (growth mode)
# shellcheck disable=SC1091
source "${ROOT}/config/options.env"  # SCALE_* preamble keys
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/capacity.sh"  # read-only capacity probes
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"  # probe_kube_versions, infra_preamble_lines, tuning_baseline_state
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/metrics.sh"  # counter_delta, extract_gauge_sum
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fanout.sh"  # fanout_gauge_sum_strict, fanout_replica_counter, fanout_list_istiod_pods (needs metrics.sh first)
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
# Namespace scaling (growth mode) metadata, what 001/003 deployed (cols 52-57).
SERVICES_PER_NAMESPACE="${CONTROLPLANE_SERVICES_PER_NAMESPACE:-0}"
WORKLOAD_MODE="${CONTROLPLANE_WORKLOAD_MODE:-pods}"
MEASUREMENT_PODS="${CONTROLPLANE_MEASUREMENT_PODS:-4}"
OUTSIDE_NAMESPACES="${CONTROLPLANE_OUTSIDE_NAMESPACES:-0}"
OUTSIDE_MODE="${CONTROLPLANE_OUTSIDE_MODE:-none}"
WINDOW_KIND=deploy
SERIES=""


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE        Run config of KEY=value lines (config/options.env keys; see
                       tests/controlplane/README.md, "Run config").
                       Precedence: flag > --config > environment > default.
  --contexts CSV       Kube contexts to scrape (default: \$SETUP_CONTEXTS).
  --mesh-size N        Metadata tag for TSV output (default: the number of contexts;
                       at most that, as the reports expect a row per member).
  --service-count N    Metadata tag for TSV output (default: $SERVICE_COUNT).
  --replicas N         Metadata tag for TSV output (default: $REPLICAS).
  --namespace-count N  Metadata tag for TSV output (default: $NAMESPACE_COUNT).
  --sidecar-scoping M  Metadata tag: none|namespace|wide|explicit (default: $SIDECAR_SCOPING).
  --traffic-config M   Metadata tag: none|vsdr (default: $TRAFFIC_CONFIG). Must match
                       what 001 deployed.
  --vsdr-every N       Metadata tag: 001's --vsdr-every (default: $VSDR_EVERY). With
                       --service-count it sets the vsdr_services column.
  --vsdr-subsets N     Metadata tag: 001's --vsdr-subsets (default: $VSDR_SUBSETS).

  Namespace scaling (growth mode; metadata tags, they must match what 001 deployed):
  --services-per-namespace K  Services per namespace (default: $SERVICES_PER_NAMESPACE; 0 =
                       legacy layout). K > 0 also reads the gateway and root-cert columns
                       and the sampled sidecars' Envoy memory.
  --workload-mode M    pods|config-only (default: $WORKLOAD_MODE).
  --measurement-pods M config-only measurement pods (default: $MEASUREMENT_PODS).
  --outside-namespaces X  Namespaces outside the mesh present in the window (default:
                       $OUTSIDE_NAMESPACES).
  --outside-mode M     none|unlabeled|labeled (default: $OUTSIDE_MODE).
  --window-kind K      deploy|grow|probe|outside|traffic: what the window measured
                       (default: $WINDOW_KIND). deploy = a full deploy (the legacy sweep
                       and --growth fresh); grow = namespaces added to a series; probe = one
                       probe namespace onboarded; outside = outside namespaces applied;
                       traffic = only the VirtualServices/DestinationRules, applied after
                       the workloads were Ready (003 --vsdr-apply split; none cells: an
                       idle window over the same workloads).
  --series ID          Growth series id: the config-dump sampler draws only from its
                       pods.

  --config-dump-samples N  Random pods per cluster to exec /config_dump on
                       (default: $CONFIG_DUMP_SAMPLES; 0 disables).
  --settle SEC         Delta-window length (seconds) between baseline and
                       final scrape (default: $SETTLE_SEC). Must match the
                       settle time used by the calling orchestrator.
  --output-dir DIR     Results directory (default: ${CONTROLPLANE_RESULTS_DIR}).
  --run-id ID          Reuse an existing sweep RUN_ID (writes into sweep-<ID>/). The
                       report keys a growth series by RUN_ID, mesh size, K and workload,
                       so give a second series of the same mesh size and K its own ID.
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
  ISTIO_VERSION_CHECK (fail, the default, or warn): stop before any change, or warn and
  record what the mesh runs, when a member's active IstioRevision version is not
  ISTIO_VERSION. ISTIO_VERSION_READY_WAIT_SEC / ISTIO_VERSION_READY_POLL_SEC (60 / 5): how
  long, and how often, to read again a member whose istiod or IstioCNI is not ready, or
  whose istiod is rolling out; a rollout still running after the wait reads as unknown.
  SETUP_CONTEXTS, CONTROLPLANE_SERVICE_COUNT, CONTROLPLANE_REPLICAS_PER_SERVICE,
  CONTROLPLANE_NAMESPACE_COUNT, CONTROLPLANE_SIDECAR_SCOPING,
  CONTROLPLANE_TRAFFIC_CONFIG, CONTROLPLANE_VSDR_EVERY, CONTROLPLANE_VSDR_SUBSETS,
  CONTROLPLANE_CONFIG_DUMP_SAMPLES, CONTROLPLANE_SETTLE_SEC (--settle),
  CONTROLPLANE_RESULTS_DIR (--output-dir; relative to the repo root),
  CONTROLPLANE_SERVICES_PER_NAMESPACE, CONTROLPLANE_WORKLOAD_MODE,
  CONTROLPLANE_MEASUREMENT_PODS, CONTROLPLANE_OUTSIDE_NAMESPACES, CONTROLPLANE_OUTSIDE_MODE.
  CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT (default 10), CONTROLPLANE_PROXY_CHECK_MIN_DIFF
  (default 2): proxy_check warns when a cluster's connected proxies (pilot_xds summed
  over its istiod pods) and its Running sidecar pods differ by more than
  max(tolerance % of the sidecar pods, min diff). A warning only; rows are kept.
  ISTIO_PROXY_READ_PARALLEL (20): members whose proxy versions are read at once.

Requires GNU timeout for a live run (it bounds each config-dump and Envoy-stats exec;
on macOS: brew install coreutils, which installs gtimeout). Without it a live run
stops at startup; --dry-run does not need it.
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
	--services-per-namespace)
		[[ -n "${2:-}" ]] || die "--services-per-namespace requires a value"
		SERVICES_PER_NAMESPACE="$2"
		shift 2
		;;
	--workload-mode)
		[[ -n "${2:-}" ]] || die "--workload-mode requires a value"
		WORKLOAD_MODE="$2"
		shift 2
		;;
	--measurement-pods)
		[[ -n "${2:-}" ]] || die "--measurement-pods requires a value"
		MEASUREMENT_PODS="$2"
		shift 2
		;;
	--outside-namespaces)
		[[ -n "${2:-}" ]] || die "--outside-namespaces requires a value"
		OUTSIDE_NAMESPACES="$2"
		shift 2
		;;
	--outside-mode)
		[[ -n "${2:-}" ]] || die "--outside-mode requires a value"
		OUTSIDE_MODE="$2"
		shift 2
		;;
	--window-kind)
		[[ -n "${2:-}" ]] || die "--window-kind requires a value"
		WINDOW_KIND="$2"
		shift 2
		;;
	--series)
		[[ -n "${2:-}" ]] || die "--series requires a value"
		SERIES="$2"
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
is_nonneg_int "$SERVICES_PER_NAMESPACE" || die "--services-per-namespace must be a non-negative integer (got: $SERVICES_PER_NAMESPACE)"
validate_workload_mode "$WORKLOAD_MODE"
is_pos_int "$MEASUREMENT_PODS" || die "--measurement-pods must be a positive integer (got: $MEASUREMENT_PODS)"
is_nonneg_int "$OUTSIDE_NAMESPACES" || die "--outside-namespaces must be a non-negative integer (got: $OUTSIDE_NAMESPACES)"
validate_outside_mode "$OUTSIDE_MODE"
case "$WINDOW_KIND" in
deploy | grow | probe | outside | traffic) ;;
*) die "--window-kind must be one of [deploy, grow, probe, outside, traffic]; got '$WINDOW_KIND'" ;;
esac
[[ -z "$SERIES" || "$SERIES" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "--series must be lowercase letters, digits and '-' (got: $SERIES)"
GROWTH=0
((SERVICES_PER_NAMESPACE > 0)) && GROWTH=1
# measurement_pods (col 54): the injected test pods the config-dump sampler draws
# from: min(M, namespaces) in config-only mode, every pod (services x replicas) with
# pods. outside_discovery (col 56) is none while no outside namespace exists.
if [[ "$WORKLOAD_MODE" == config-only ]]; then
	MEASUREMENT_PODS_COL=$(( MEASUREMENT_PODS < NAMESPACE_COUNT ? MEASUREMENT_PODS : NAMESPACE_COUNT ))
else
	MEASUREMENT_PODS_COL=$(( SERVICE_COUNT * REPLICAS ))
fi
OUTSIDE_DISCOVERY=none
((OUTSIDE_NAMESPACES > 0)) && OUTSIDE_DISCOVERY="$OUTSIDE_MODE"
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
# The config-dump and Envoy-stats samples run under timeout/gtimeout; without either,
# every sample would read N/A with no message. --dry-run does not need it.
((DRY_RUN)) || require_timeout

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_contexts "$CONTEXTS_CSV" CONTEXTS --contexts
else
	split_contexts "$SETUP_CONTEXTS" CONTEXTS SETUP_CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

[[ -z "$MESH_SIZE" ]] && MESH_SIZE="${#CONTEXTS[@]}"
is_pos_int "$MESH_SIZE" || die "--mesh-size must be a positive integer (got: $MESH_SIZE)"
# Every member writes a row: rows naming fewer members than their mesh size read as a cell
# cut short (INCOMPLETE) in the reports, so a larger mesh size is refused here.
((MESH_SIZE <= ${#CONTEXTS[@]})) || die "--mesh-size ${MESH_SIZE} is larger than the ${#CONTEXTS[@]} context(s) given (${CONTEXTS[*]}): its rows would name fewer members than their mesh size, which the reports read as a cell cut short (INCOMPLETE). Give a context per member, or a smaller --mesh-size."

if [[ -n "$RUN_ID_OVERRIDE" ]]; then
	RUN_ID="$RUN_ID_OVERRIDE"
else
	RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
# The harness (PL2): <describe>, or <describe>-dirty.<8hex> for uncommitted changes, and the
# content key of its files (HARNESS_CONTENT_KEY), from one read; when (UTC) for the
# HARNESS_CHANGED_AT line a window may write (harness_change_line).
HARNESS_SHA="" HARNESS_CONTENT_KEY=""
harness_read HARNESS_SHA HARNESS_CONTENT_KEY --exclude "$OUTPUT_DIR"
HARNESS_READ_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "[002] RUN_ID=$RUN_ID  SETTLE_SEC=$SETTLE_SEC  HARNESS_SHA=$HARNESS_SHA"
echo "[002] Contexts: ${CONTEXTS[*]}  Mesh: $MESH_SIZE  Services: $SERVICE_COUNT  Replicas: $REPLICAS  Namespaces: $NAMESPACE_COUNT  Scoping: $SIDECAR_SCOPING  ConfigDumpSamples: $CONFIG_DUMP_SAMPLES"
echo "[002] Traffic: $TRAFFIC_CONFIG  VS+DR services: $VSDR_SERVICES  (every $VSDR_EVERY, $VSDR_SUBSETS subsets)"
echo "[002] Proxy check: warn when connected proxies and Running sidecar pods differ by > max(${PROXY_CHECK_TOL_PCT}%, ${PROXY_CHECK_MIN_DIFF}) per cluster"
((GROWTH)) && echo "[002] Growth: window=${WINDOW_KIND} services_per_namespace=${SERVICES_PER_NAMESPACE} workload=${WORKLOAD_MODE} measurement_pods=${MEASUREMENT_PODS_COL} outside=${OUTSIDE_NAMESPACES}/${OUTSIDE_DISCOVERY} series=${SERIES:-none}"

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

# The Istio version the members run, before the first scrape (inherited when 003
# runs this step; read here when it runs alone, a read-only API GET like the version
# and capacity reads below). ISTIO_VERSION_CHECK=fail stops on a mismatch.
istio_version_resolve "$(IFS=,; echo "${CONTEXTS[*]}")" 0 "${KUBECTL[@]}"

# Kube server version per context (concurrent, 5s timeout each).
KUBE_VERSIONS_CSV="$(probe_kube_versions "$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}")"

# Source context's node allocatable + istiod limits for the preamble (read-only;
# `unknown` on failure). Skipped when no preamble is written: --phase baseline, or a TSV
# that exists (003 writes it before a sweep's first window).
TSV_FILE="${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv"
PRE_NODE_ALLOC_CPU_M="unknown"
PRE_NODE_ALLOC_MEM_MI="unknown"
PRE_ISTIOD_CPU_LIMIT_M="unknown"
PRE_ISTIOD_MEM_LIMIT_MI="unknown"
if [[ "$PHASE" != baseline && ! -f "$TSV_FILE" ]]; then
	src_ctx="${CONTEXTS[0]}"
	# shellcheck disable=SC2207
	nt_kv=($(cap_node_totals "$src_ctx" "${KUBECTL[@]}"))
	for kv in ${nt_kv[@]+"${nt_kv[@]}"}; do
		case "$kv" in
			cpu_m=*) PRE_NODE_ALLOC_CPU_M="${kv#cpu_m=}" ;;
			mem_mi=*) PRE_NODE_ALLOC_MEM_MI="${kv#mem_mi=}" ;;
		esac
	done
	# shellcheck disable=SC2207
	il_kv=($(cap_istiod_limits "$src_ctx" "${KUBECTL[@]}"))
	for kv in ${il_kv[@]+"${il_kv[@]}"}; do
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
if [[ "$PHASE" != baseline && ! -f "$TSV_FILE" ]]; then
	tb_kv=""
	while IFS= read -r tb_kv; do
		case "$tb_kv" in
			TUNING_BASELINE=*) PRE_TUNING_BASELINE="$tb_kv" ;;
			SIDECAR_EGRESS_HOSTS=*) PRE_SIDECAR_EGRESS_HOSTS="$tb_kv" ;;
		esac
	done < <(tuning_baseline_state "${CONTEXTS[0]}" "${KUBECTL[@]}")
fi

if [[ "$PHASE" != baseline && ! -f "$TSV_FILE" ]]; then
	# Cluster-infra block, collected only when 002 writes the preamble itself
	# (003 pre-creates it in a sweep). Same shared emitter as 003.
	PRE_INFRA_KV="$(env_collect_infra "$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}")"
	{
		echo "# Control-plane resource metrics — $(date -u -Iseconds)"
		echo "# CONTROLPLANE_SCHEMA=66"
		echo "# CONTROLPLANE_INFRA_SCHEMA=2"
		istio_version_kv | sed 's/^/# /'
		echo "# HARNESS_SHA=${HARNESS_SHA}"
		echo "# HARNESS_CONTENT_KEY=${HARNESS_CONTENT_KEY}"
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
		# The sweep's VS/DR apply mode (003 --vsdr-apply); a standalone window has none.
		echo "# VSDR_APPLY=n/a"
		config_preamble_lines
		# Namespace-scaling keys, same shared emitter as 003 (PL36). A standalone run is
		# no growth sweep, so the sweep-only keys read n/a.
		growth_preamble_lines SERVICES_PER_NAMESPACE="$SERVICES_PER_NAMESPACE" GROWTH_MODE=n/a \
			WORKLOAD_MODE="$WORKLOAD_MODE" MEASUREMENT_PODS="$MEASUREMENT_PODS" \
			MEASUREMENT_PROXY_MEM_LIMIT="${CONTROLPLANE_MEASUREMENT_PROXY_MEM_LIMIT:-unknown}" \
			OUTSIDE_NAMESPACES="$OUTSIDE_NAMESPACES" OUTSIDE_MODES="$OUTSIDE_MODE" \
			PROBE_SETTLE_SEC=n/a MEM_STOP_PCT=n/a MEM_GUARD_CONTEXTS=n/a SERIES_RETIRE=n/a \
			DISCOVERY_LABEL=istio-discovery=enabled LEFTOVER_TEST_NAMESPACES=n/a \
			LEFTOVER_NS_WARN="${CONTROLPLANE_LEFTOVER_NS_WARN:-100}"
		# shellcheck disable=SC2086
		infra_preamble_lines $PRE_INFRA_KV
		echo "# ${PRE_TUNING_BASELINE}"
		echo "# ${PRE_SIDECAR_EGRESS_HOSTS}"
		echo "# Contexts: ${CONTEXTS[*]}  Mesh size: $MESH_SIZE  Services: $SERVICE_COUNT  Replicas: $REPLICAS  Namespaces: $NAMESPACE_COUNT  Scoping: $SIDECAR_SCOPING  Traffic: $TRAFFIC_CONFIG"
	} > "$TSV_FILE"
fi

# Schema (TSV header — 66 columns; must equal 003's CONTROLPLANE_TSV_HEADER, which
# tests/lib/test/preamble.bats checks):
#   timestamp context mesh_size service_count replicas namespace_count sidecar_scoping
#   istiod_mem_mi
#   convergence_p50_ms convergence_p99_ms queue_p50_ms queue_p99_ms
#   xds_pushes_delta xds_pushes_rate
#   xds_pushes_cds xds_pushes_eds xds_pushes_lds xds_pushes_rds xds_pushes_nds
#   k8s_events_delta k8s_events_rate
#   connected_proxies config_size_avg_bytes
#   sidecar_config_bytes_avg sidecar_config_bytes_p50 sidecar_config_bytes_max
#   sidecar_config_bytes_samples
#   scrape_window_sec scrape_skew_ms settle_sec istiod_restarted
#   istiod_cpu_m_delta
#   go_heap_alloc_mi go_heap_inuse_mi
#   (cols 35-40) istiod_cpu_pct_of_limit istiod_mem_pct_of_limit
#                   node_cpu_pct node_mem_pct pods_scheduled pods_allocatable
#     istiod_*_pct_of_limit = `kubectl top` usage summed over the istiod pods it lists,
#     over the per-replica limit times that pod count (a Pending replica counts in neither).
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
#   (cols 52-63) namespace scaling (growth mode):
#                services_per_namespace workload_mode measurement_pods
#                outside_namespaces outside_discovery window_kind
#                istiod_services istiod_cpu_s_delta sidecar_mem_mi_avg
#                gateway_clusters_max gateway_mem_mi_max root_cert_configmaps
#     52-57 are what 001/003 deployed (a legacy run reads 0 pods <services x replicas>
#     0 none deploy). istiod_services = pilot_services (final scrape; mesh-global,
#     identical on every replica, never summed, PL28). istiod_cpu_s_delta =
#     Δprocess_cpu_seconds_total over the window (CPU-seconds; N/A on a restarted row,
#     PL13), so a window's cost is not inflated by istiod_cpu_m_delta's per-interval
#     peak. The last four are read in growth mode only (N/A otherwise):
#     sidecar_mem_mi_avg = Envoy server.memory_allocated of the sampled sidecars;
#     gateway_* = max over the context's ingress/east-west gateways (Envoy
#     cluster_manager.active_clusters, server.memory_allocated); root_cert_configmaps =
#     istio-ca-root-cert ConfigMaps on the context (one per namespace istiod serves).
#   (cols 64-66, CONTROLPLANE_SCHEMA=66; growth mode only, N/A otherwise):
#                gateway_physical_mi_max gateway_ws_mi_max leftover_test_namespaces
#     gateway_physical_mi_max = max Envoy server.memory_physical_size (the tcmalloc
#     heap with the freed pages it kept) and gateway_ws_mi_max = max istio-proxy
#     container working set (kubectl top; N/A without the metrics API) over the
#     context's gateways: what the OOM killer acts on, which ran 1.2-2.9x the allocated
#     figure on ROSA after config bursts (BACKLOG 9.5). leftover_test_namespaces =
#     controlplane-test namespaces on the context that are not this series' (earlier
#     series or runs, discovered or not; they stay in istiod's informers, BACKLOG 9.10).
if [[ "$PHASE" != baseline ]] && ! grep -q '^timestamp' "$TSV_FILE" 2>/dev/null; then
	echo -e "timestamp\tcontext\tmesh_size\tservice_count\treplicas\tnamespace_count\tsidecar_scoping\tistiod_mem_mi\tconvergence_p50_ms\tconvergence_p99_ms\tqueue_p50_ms\tqueue_p99_ms\txds_pushes_delta\txds_pushes_rate\txds_pushes_cds\txds_pushes_eds\txds_pushes_lds\txds_pushes_rds\txds_pushes_nds\tk8s_events_delta\tk8s_events_rate\tconnected_proxies\tconfig_size_avg_bytes\tsidecar_config_bytes_avg\tsidecar_config_bytes_p50\tsidecar_config_bytes_max\tsidecar_config_bytes_samples\tscrape_window_sec\tscrape_skew_ms\tsettle_sec\tistiod_restarted\tistiod_cpu_m_delta\tgo_heap_alloc_mi\tgo_heap_inuse_mi\tistiod_cpu_pct_of_limit\tistiod_mem_pct_of_limit\tnode_cpu_pct\tnode_mem_pct\tpods_scheduled\tpods_allocatable\tcluster_connected_proxies\tsidecar_pods\tproxy_check\ttraffic_config\tvsdr_services\tistiod_virt_services\tpush_time_avg_ms\tpushcontext_init_avg_ms\tsidecar_clusters_avg\tsidecar_cds_bytes_avg\tsidecar_rds_bytes_avg\tservices_per_namespace\tworkload_mode\tmeasurement_pods\toutside_namespaces\toutside_discovery\twindow_kind\tistiod_services\tistiod_cpu_s_delta\tsidecar_mem_mi_avg\tgateway_clusters_max\tgateway_mem_mi_max\troot_cert_configmaps\tgateway_physical_mi_max\tgateway_ws_mi_max\tleftover_test_namespaces" >> "$TSV_FILE"
fi

PF_PIDS=()
TMP_DIR="$(mktemp -d -t controlplane-002.XXXXXX)"

cleanup() {
	for pid in ${PF_PIDS[@]+"${PF_PIDS[@]}"}; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	PF_PIDS=()
	rm -rf "$TMP_DIR"
}

# Also on a SIGTERM the sweep forwards (sweep_step): bash runs the EXIT trap on a fatal
# signal it does not trap and still dies of it (143), at once. A TERM trap would wait for
# the command in progress to end first.
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
# Each member's istiod Deployment .spec.replicas at the window's baseline (cap_istiod_limits;
# unknown when unread), persisted with the pods: the WINDOW_ROWS line records it next to the
# rows the member wrote, so a report tells a member that ran the cell on fewer istiod pods
# than it wants (one evicted or Pending) from one that runs fewer replicas. ISTIOD_LIMITS
# keeps that read's whole line (its per-replica limits too) for the rows' %-of-limit
# columns (collect_capacity_for_ctx), so a window reads each member's Deployment once.
# ISTIOD_NOTREADY: its Running istiod pods that were not Ready then (space-separated), for
# the window's "# ISTIOD_NOT_READY=" line.
declare -A ISTIOD_SPEC=()
declare -A ISTIOD_LIMITS=()
declare -A ISTIOD_NOTREADY=()

resolve_pods() {
	POD_CTXS=()
	POD_NAMES=()
	ISTIOD_SPEC=()
	ISTIOD_LIMITS=()
	ISTIOD_NOTREADY=()
	local spec kv n lim notready
	for ctx in "${CONTEXTS[@]}"; do
		local pods
		# <name>=<its Ready condition> per Running pod (a pod name has no "="; a bare name is
		# one whose condition was not read).
		pods=$("${KUBECTL[@]}" --context="$ctx" -n istio-system get pods -l app=istiod \
			--field-selector=status.phase=Running \
			-o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status}{" "}{end}' 2>/dev/null)
		spec=unknown
		lim="$(cap_istiod_limits "$ctx" "${KUBECTL[@]}")"
		ISTIOD_LIMITS[$ctx]="$lim"
		for kv in $lim; do [[ "$kv" != replicas=* ]] || spec="${kv#replicas=}"; done
		[[ "$spec" =~ ^[0-9]+$ ]] || spec=unknown
		ISTIOD_SPEC[$ctx]="$spec"
		# One context with zero istiod pods is dropped (degraded row later); only
		# zero pods across ALL contexts is fatal.
		if [[ -z "$pods" ]]; then
			echo "warning: context $ctx: no running istiod pods in istio-system; dropping this context (will emit a degraded N/A row)" >&2
			DROPPED_CTXS+=("$ctx")
			continue
		fi
		n=0 notready=""
		for pod in $pods; do
			[[ "$pod" != *=* || "${pod#*=}" == True ]] || notready+="${notready:+ }${pod%%=*}"
			POD_CTXS+=("$ctx")
			POD_NAMES+=("${pod%%=*}")
			n=$((n + 1))
		done
		ISTIOD_NOTREADY[$ctx]="$notready"
		if [[ "$spec" != unknown ]] && ((n < spec)); then
			echo "warning: context $ctx: ${n} istiod pod(s) Running, but its Deployment wants ${spec} (one evicted or Pending?): this window measures it on ${n} replica(s), and its WINDOW_ROWS entry (${ctx}=${n}/${spec}) tells the reports so" >&2
		fi
		# A Running replica that is not Ready is scraped and writes a row, but the Service
		# sends it no new proxy; the window's ISTIOD_NOT_READY line records it.
		[[ -z "$notready" ]] \
			|| echo "warning: context $ctx: istiod pod(s) Running but not Ready: ${notready// /, } (a replacement still syncing its remote clusters, an old replica shutting down, or one failing its readiness probe under load?): such a pod takes no new proxy connections but keeps the ones it has (its connected_proxies column), and the window's ISTIOD_NOT_READY line tells the reports so" >&2
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
	for dctx in ${DROPPED_CTXS[@]+"${DROPPED_CTXS[@]}"}; do
		printf '%s\n' "$dctx" >> "${dir}/dropped-ctxs.tsv"
	done
	# The limits line is never empty (- when unread): a tab is IFS whitespace, so read would
	# shift the not-Ready pods into it.
	for dctx in "${!ISTIOD_SPEC[@]}"; do
		printf '%s\t%s\t%s\t%s\n' "$dctx" "${ISTIOD_SPEC[$dctx]}" "${ISTIOD_LIMITS[$dctx]:--}" "${ISTIOD_NOTREADY[$dctx]:-}"
	done > "${dir}/istiod-spec.tsv"
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
	# The baseline's istiod Deployment replicas, its read's line and the pods not Ready then
	# (none from an older baseline: unknown, and collect_capacity_for_ctx reads the
	# Deployment itself).
	ISTIOD_SPEC=()
	ISTIOD_LIMITS=()
	ISTIOD_NOTREADY=()
	if [[ -f "${dir}/istiod-spec.tsv" ]]; then
		local sctx sval slim snr
		while IFS=$'\t' read -r sctx sval slim snr; do
			[[ -z "$sctx" ]] || { ISTIOD_SPEC[$sctx]="$sval"; ISTIOD_LIMITS[$sctx]="$slim"; ISTIOD_NOTREADY[$sctx]="$snr"; }
		done < "${dir}/istiod-spec.tsv"
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
	b_sum=0 b_cnt=0
	if [[ -n "$baseline" ]]; then
		b_sum=$(extract_hist_sum "$baseline" "$name")
		b_cnt=$(extract_hist_count "$baseline" "$name")
	fi
	f_sum=$(extract_hist_sum "$final" "$name")
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

# Prints "<bytes csv>|attempted=<n>|got=<n>|clusters=<csv>|cds=<csv>|rds=<csv>|mem=<csv>":
# per sampled pod, the dump size, its config_dump_breakdown fields and (growth mode
# only) its Envoy server.memory_allocated in MiB (N/A for a failed sample or an
# unparseable dump). With --series only that series' pods are sampled.
collect_config_dump_samples() {
	local ctx="$1" samples="$2"
	local out_csv="" got=0 attempted=0 cl_csv="" cds_csv="" rds_csv="" mem_csv=""
	local dump_file="${TMP_DIR}/config-dump-sample.json"
	if (( samples == 0 )); then
		echo ""
		return 0
	fi
	local selector="app.kubernetes.io/instance=controlplane-test"
	[[ -n "$SERIES" ]] && selector="${selector},controlplane-test.series=${SERIES}"
	local pod_lines
	pod_lines="$("${KUBECTL[@]}" get pods --context="$ctx" --all-namespaces \
		-l "$selector" \
		-o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.namespace}{"|"}{.metadata.name}{"\n"}{end}' \
		2>/dev/null || true)"
	local seed="${RUN_ID}-${ctx}"
	local picked
	picked="$(echo "$pod_lines" | grep -v '^$' | deterministic_pick "$samples" "$seed" 2>/dev/null || true)"
	[[ -z "$picked" ]] && { echo ""; return 0; }
	while IFS='|' read -r ns pod; do
		[[ -z "$pod" ]] && continue
		attempted=$((attempted + 1))
		# Bound the config_dump exec — at 10k services the dump is multi-MB and a
		# wedged sidecar/exec must not stall the sweep. On timeout the dump is empty ->
		# bytes=0 -> counted as a FAILED sample (got not incremented), never a partial/
		# misleading byte count (capturing first lets us drop a timed-out exec cleanly).
		local dump bytes bd v
		dump="$(run_timeout "${CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S:-30}s" "${KUBECTL[@]}" --context="$ctx" -n "$ns" exec "$pod" -c istio-proxy -- \
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
		# Envoy memory of the same proxy (growth mode; one more bounded exec).
		v="N/A"
		if ((GROWTH)) && [[ "$bd" != unknown ]]; then
			v="$(kv_get mem_mi "$(growth_envoy_stats "$ctx" "$ns" "$pod" "${KUBECTL[@]}")")"
			[[ "$v" =~ ^[0-9]+$ ]] || v="N/A"
		fi
		mem_csv+="${v},"
	done <<<"$picked"
	out_csv="${out_csv%,}"
	echo "${out_csv}|attempted=${attempted}|got=${got}|clusters=${cl_csv%,}|cds=${cds_csv%,}|rds=${rds_csv%,}|mem=${mem_csv%,}"
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
	# --max-time bounds the scrape so a stuck/half-open PF among 35-50 returns 1
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
		# Empty this scrape's files first: a failed curl writes nothing, so in watch mode
		# the previous window's body and timestamps would otherwise stand in for it (stale
		# gauges, a backwards counter read as a reset). An empty file reads as no scrape.
		: > "$m_out"
		: > "$t_out"
		: > "$te_out"
		(
			scrape_one_context "${POD_CTXS[k]}" "$port" "$m_out" "$t_out" "$te_out" || exit 1
		) &
		pids+=($!)
		# PL8: the skew is the spread of the completion stamps (.tsend), not the starts.
		ts_files+=("$te_out")
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

# compute_skew_ms <prefix>: scrape_all_parallel's skew for a batch scraped earlier (the
# baseline a --phase final reads from the state dir): the spread of its completion stamps
# (.tsend, PL8), as scrape_all_parallel computes it.
compute_skew_ms() {
	local prefix="$1"
	local min="" max="" t k
	for k in "${!POD_CTXS[@]}"; do
		local t_file="${prefix}-${k}.tsend"
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
# The config_dump samples of a context, once per window (collect_config_dump_samples
# output): every istiod replica's row of that context reads the same sampled proxies, so
# a context with R replicas execs into the proxies once, not R times (300 execs per
# mesh-20 cell with 3 replicas and 5 samples became 100).
declare -A CD_CACHE
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
	for kv in ${nu[@]+"${nu[@]}"}; do
		case "$kv" in
			cpu_m=*) used_cpu_m="${kv#cpu_m=}" ;;
			mem_mi=*) used_mem_mi="${kv#mem_mi=}" ;;
		esac
	done

	# cap_istiod_limits returns the PER-REPLICA container limit + the replica count.
	# cap_istiod_used (below) SUMS usage across the istiod pods `kubectl top` lists, so the
	# %-of-limit denominator must be the AGGREGATE limit over those same pods (per-replica ×
	# the pods it summed) for the ratio to share scope with its numerator — otherwise a
	# healthy R-replica control plane reads up to ~R×100%, and one with a Pending or evicted
	# replica (counted in .spec.replicas, absent from top) reads low. The Deployment's
	# replicas only when that count is unknown. (cf PL28 sum-vs-invariant scope, PL35.)
	# The Deployment as resolve_pods read it at the window's baseline (ISTIOD_LIMITS), read
	# again only when that read lacks a limit. A limit changed during the window rolls istiod
	# out: its pods restart, and the restart guard marks the rows.
	local istd_cpu_m="unknown" istd_mem_mi="unknown" istd_rep="unknown" lim_re='cpu_m=[0-9]+ mem_mi=[0-9]+'
	local il="${ISTIOD_LIMITS[$ctx]:-}"
	[[ "$il" =~ $lim_re ]] || il="$(cap_istiod_limits "$ctx" "${KUBECTL[@]}")"
	for kv in $il; do
		case "$kv" in
			cpu_m=*) istd_cpu_m="${kv#cpu_m=}" ;;
			mem_mi=*) istd_mem_mi="${kv#mem_mi=}" ;;
			replicas=*) istd_rep="${kv#replicas=}" ;;
		esac
	done
	local istd_used_cpu_m="unknown" istd_used_mem_mi="unknown" istd_used_pods="unknown"
	# shellcheck disable=SC2207
	local -a iu=($(cap_istiod_used "$ctx" "${KUBECTL[@]}"))
	for kv in ${iu[@]+"${iu[@]}"}; do
		case "$kv" in
			cpu_m=*) istd_used_cpu_m="${kv#cpu_m=}" ;;
			mem_mi=*) istd_used_mem_mi="${kv#mem_mi=}" ;;
			pods=*) istd_used_pods="${kv#pods=}" ;;
		esac
	done
	# Aggregate limit over the pods summed (unknown if any input is non-numeric).
	[[ ! "$istd_used_pods" =~ ^[1-9][0-9]*$ ]] || istd_rep="$istd_used_pods"
	local istd_cpu_total="unknown" istd_mem_total="unknown"
	if [[ "$istd_cpu_m" =~ ^[0-9]+$ && "$istd_rep" =~ ^[0-9]+$ ]]; then istd_cpu_total=$(( istd_cpu_m * istd_rep )); fi
	if [[ "$istd_mem_mi" =~ ^[0-9]+$ && "$istd_rep" =~ ^[0-9]+$ ]]; then istd_mem_total=$(( istd_mem_mi * istd_rep )); fi

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
	for ctx in "${ctxs[@]}" ${DROPPED_CTXS[@]+"${DROPPED_CTXS[@]}"}; do
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
	for ctx in ${DROPPED_CTXS[@]+"${DROPPED_CTXS[@]}"}; do
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

# growth_meta_fields: cols 52-57, what 001/003 deployed for this window (the same on
# every row).
growth_meta_fields() {
	printf '%s\t%s\t%s\t%s\t%s\t%s' "$SERVICES_PER_NAMESPACE" "$WORKLOAD_MODE" "$MEASUREMENT_PODS_COL" \
		"$OUTSIDE_NAMESPACES" "$OUTSIDE_DISCOVERY" "$WINDOW_KIND"
}

# growth_na_fields: cols 52-66 for a row with nothing measured.
growth_na_fields() {
	printf '%s\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A' "$(growth_meta_fields)"
}

# Growth-mode context reads (cols 61-63 and 64-66): the gateways' Envoy clusters and
# memory (allocated, physical, container working set), the istio-ca-root-cert
# ConfigMap count and the leftover test namespaces, once per context per window,
# after the final scrape (outside the window). N/A outside growth mode, so a legacy
# sweep pays no extra exec. Must run in the main shell (the cache is a global).
declare -A GROWTH_CTX_CACHE  # ctx -> "gw_clusters<TAB>gw_mem_mi<TAB>root_cert_cms" (cols 61-63)
declare -A GROWTH_CTX_CACHE2 # ctx -> "gw_physical_mi<TAB>gw_ws_mi<TAB>leftover_ns" (cols 64-66)
collect_growth_for_ctx() {
	local ctx="$1" kv cl mem phy ws rc left
	[[ -n "${GROWTH_CTX_CACHE[$ctx]:-}" ]] && return 0
	if ! ((GROWTH)); then
		GROWTH_CTX_CACHE[$ctx]=$'N/A\tN/A\tN/A'
		GROWTH_CTX_CACHE2[$ctx]=$'N/A\tN/A\tN/A'
		return 0
	fi
	kv="$(growth_gateway_summary "$ctx" "${KUBECTL[@]}")" || kv=""
	cl="$(kv_get clusters_max "$kv")"; [[ "$cl" =~ ^[0-9]+$ ]] || cl="N/A"
	mem="$(kv_get mem_mi_max "$kv")"; [[ "$mem" =~ ^[0-9]+$ ]] || mem="N/A"
	phy="$(kv_get physical_mi_max "$kv")"; [[ "$phy" =~ ^[0-9]+$ ]] || phy="N/A"
	ws="$(kv_get ws_mi_max "$kv")"; [[ "$ws" =~ ^[0-9]+$ ]] || ws="N/A"
	rc="$(growth_root_cert_count "$ctx" "${KUBECTL[@]}")" || rc="N/A"
	[[ "$rc" =~ ^[0-9]+$ ]] || rc="N/A"
	# Namespaces of this suite that are not this series' (the plain legacy namespace
	# included); set-based != also matches a namespace without the series label.
	left="$("${KUBECTL[@]}" --context="$ctx" --request-timeout=60s get namespaces \
		-l "app.kubernetes.io/instance=controlplane-test,controlplane-test.series!=${SERIES:-none}" -o name 2>/dev/null | wc -l | tr -d ' ')" || left="N/A"
	[[ "$left" =~ ^[0-9]+$ ]] || left="N/A"
	GROWTH_CTX_CACHE[$ctx]="${cl}"$'\t'"${mem}"$'\t'"${rc}"
	GROWTH_CTX_CACHE2[$ctx]="${phy}"$'\t'"${ws}"$'\t'"${left}"
	echo "  Cluster ${ctx}: gateways $(kv_get pods "$kv") (clusters max ${cl}; Envoy allocated max ${mem} Mi, physical max ${phy} Mi; container working set max ${ws} Mi), istio-ca-root-cert ConfigMaps ${rc}, leftover test namespaces ${left}"
}

# harness_change_line: the "# HARNESS_CHANGED_AT=<UTC Z> HARNESS_SHA=<v> HARNESS_CONTENT_KEY=<k>"
# line a window writes before its rows when they ran other harness files than the TSV's
# last record of them: its preamble's HARNESS_SHA and HARNESS_CONTENT_KEY, then each
# "# RESUMED_AT=" and "# HARNESS_CHANGED_AT=" line. A sweep's TSV keeps the preamble of its
# start, so without it the rows of a file edited (or a checkout) during the sweep would be
# credited to the start's harness; controlplane_attempts reads the line as a boundary of the
# rows' provenance. Compared by content key (harness_same: a commit or tag that left the
# harness files as they were is no change), by HARNESS_SHA when either key is unknown. A
# final phase whose baseline (its read in --state-dir) ran other files than it did spans
# both: its rows go to the baseline's when that differs from the record (and HCL_AFTER, a
# second line the window writes after its rows, records the final's, which the next
# window's rows are compared with), else to the final's. Prints nothing when they match;
# warns when it prints a line.
HCL_AFTER=""
harness_change_line() {
	local rec_s rec_k s="$HARNESS_SHA" k="$HARNESS_CONTENT_KEY" t="$HARNESS_READ_AT" bs="" bk="" bt=""
	HCL_AFTER=""
	IFS=$'\t' read -r rec_s rec_k < <(awk '
		function lv(k,    p, v) { if (!(p = index($0, " " k "="))) return "unknown"; v = substr($0, p + length(k) + 2); sub(/ .*/, "", v); return (v == "" ? "unknown" : v) }
		/^timestamp\t/ { hdr = 1; next }
		!/^#/ { next }
		!hdr && index($0, "# HARNESS_SHA=") == 1 { s = substr($0, 15) }
		!hdr && index($0, "# HARNESS_CONTENT_KEY=") == 1 { k = substr($0, 23) }
		index($0, "# RESUMED_AT=") == 1 || index($0, "# HARNESS_CHANGED_AT=") == 1 { s = lv("HARNESS_SHA"); k = lv("HARNESS_CONTENT_KEY") }
		END { printf "%s\t%s\n", (s == "" ? "unknown" : s), (k == "" ? "unknown" : k) }' "$TSV_FILE" 2>/dev/null) || true
	if [[ "$PHASE" == final && -f "${STATE_DIR}/harness" ]]; then
		IFS=$'\t' read -r bs bk bt < "${STATE_DIR}/harness" || true
		if [[ -n "$bs" && -n "$bk" ]] && ! harness_same "$bs" "$bk" "$s" "$k"; then
			echo "warning: [002] this window's baseline ran other harness files (HARNESS_SHA=${bs}) than its final scrape (HARNESS_SHA=${s}): a harness file was edited, or a checkout ran, during the window; the TSV records both" >&2
			if ! harness_same "$bs" "$bk" "${rec_s:-unknown}" "${rec_k:-unknown}"; then
				HCL_AFTER="$(printf '# HARNESS_CHANGED_AT=%s HARNESS_SHA=%s HARNESS_CONTENT_KEY=%s' "$t" "$s" "$k")"
				s="$bs" k="$bk" t="${bt:-$t}"
			fi
		fi
	fi
	harness_same "$s" "$k" "${rec_s:-unknown}" "${rec_k:-unknown}" && return 0
	echo "warning: [002] these rows ran other harness files than ${TSV_FILE##*/} records (HARNESS_SHA=${rec_s:-unknown}, HARNESS_CONTENT_KEY=${rec_k:-unknown}; now HARNESS_SHA=${s}, HARNESS_CONTENT_KEY=${k}): a HARNESS_CHANGED_AT line before them records it" >&2
	printf '# HARNESS_CHANGED_AT=%s HARNESS_SHA=%s HARNESS_CONTENT_KEY=%s\n' "$t" "$s" "$k"
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
	# The window's rows go to one file first and into the TSV in one append at the end
	# (degraded rows too), so a sweep cut short while this window writes leaves all of its
	# member rows or none: a cell never reads as measured from some members' rows (003
	# counts a cell whose rows name fewer members than its mesh size as INCOMPLETE).
	local rows_file="${TMP_DIR}/rows"
	: > "$rows_file"

	# Per-replica pilot_xds_pushes: a replica that never pushed has no series
	# and no `# TYPE` line, so "renamed or idle" is decided once over the whole batch
	# (every baseline and final body, all members: one Istio version, checked at the
	# start). Any complete body with the counter makes a complete body without it a
	# real 0; none with it leaves it unknown, and counter_delta warns "renamed?".
	# pilot_k8s_cfg_events is not read this way: every replica's informers see every
	# config event, so a replica without it has the counter missing, not idle.
	local -a batch_files=()
	for k in "${!POD_CTXS[@]}"; do
		batch_files+=("${TMP_DIR}/baseline-${k}.metrics" "${TMP_DIR}/final-${k}.metrics")
	done
	local xds_pushes_in_batch
	xds_pushes_in_batch=$(fanout_counter_in_batch pilot_xds_pushes "${batch_files[@]}")

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
			echo -e "${ts}\t${ctx}\t${MESH_SIZE}\t${SERVICE_COUNT}\t${REPLICAS}\t${NAMESPACE_COUNT}\t${SIDECAR_SCOPING}\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t${window_sec}\t${total_skew_ms}\t${settle_input_sec}\tunknown\tN/A\tN/A\tN/A\t${cap_fields}\t$(cluster_fields "$ctx")\t$(traffic_na_fields)\t$(growth_na_fields)" >> "$rows_file"
			continue
		fi
		local baseline final
		baseline=""
		if [[ -s "$b_file" ]]; then baseline="$(cat "$b_file" 2>/dev/null || true)"; fi
		final=$(cat "$f_file")

		# Memory: peak of (baseline, polled peaks, final) in MiB.
		local final_mem_bytes baseline_mem_bytes peak_mem_bytes mem_mi
		final_mem_bytes=$(extract_gauge_exact "$final" process_resident_memory_bytes)
		baseline_mem_bytes=0
		if [[ -n "$baseline" ]]; then baseline_mem_bytes=$(extract_gauge_exact "$baseline" process_resident_memory_bytes); fi
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
		b_pst=N/A
		if [[ -n "$baseline" ]]; then b_pst=$(extract_gauge_exact "$baseline" process_start_time_seconds); fi
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

		# Counter deltas (xds pushes + k8s events). counter_delta (metrics.sh): a
		# counter missing from both scrapes, or one that went backwards, is N/A with a
		# warning, never 0; one first registered in the window counts from 0; an
		# incomplete scrape (`unscraped`, PL29) is N/A. Pushes: see xds_pushes_in_batch.
		local pushes_delta pushes_rate evts_delta evts_rate
		if (( restarted_or_unknown )); then
			pushes_delta="N/A"; pushes_rate="N/A"
			evts_delta="N/A"; evts_rate="N/A"
		else
			pushes_delta=$(counter_delta "$(fanout_replica_counter "$xds_pushes_in_batch" "$b_file" pilot_xds_pushes)" \
				"$(fanout_replica_counter "$xds_pushes_in_batch" "$f_file" pilot_xds_pushes)" "pilot_xds_pushes on ${ctx}/${POD_NAMES[k]}")
			if (( window_positive )) && [[ "$pushes_delta" != "N/A" ]]; then
				pushes_rate=$(awk -v d="$pushes_delta" -v w="$window_sec" 'BEGIN{ printf "%.2f", d/w }')
			else
				pushes_rate="N/A"
			fi

			evts_delta=$(counter_delta "$(fanout_replica_counter 0 "$b_file" pilot_k8s_cfg_events)" \
				"$(fanout_replica_counter 0 "$f_file" pilot_k8s_cfg_events)" "pilot_k8s_cfg_events on ${ctx}/${POD_NAMES[k]}")
			if (( window_positive )) && [[ "$evts_delta" != "N/A" ]]; then
				evts_rate=$(awk -v d="$evts_delta" -v w="$window_sec" 'BEGIN{ printf "%.2f", d/w }')
			else
				evts_rate="N/A"
			fi
		fi

		# Per-type xds_pushes deltas. A type with no series while pilot_xds_pushes itself
		# is in the scrape is a real 0 (extract_counter_by_label), as is an idle replica's
		# (xds_pushes_in_batch); N/A as above.
		local types=(cds eds lds rds nds)
		local push_by_type=()
		if (( restarted_or_unknown )); then
			push_by_type=("N/A" "N/A" "N/A" "N/A" "N/A")
		else
			for t in "${types[@]}"; do
				push_by_type+=("$(counter_delta "$(fanout_replica_counter "$xds_pushes_in_batch" "$b_file" pilot_xds_pushes type "$t")" \
					"$(fanout_replica_counter "$xds_pushes_in_batch" "$f_file" pilot_xds_pushes type "$t")" "pilot_xds_pushes{type=${t}} on ${ctx}/${POD_NAMES[k]}")")
			done
		fi

		# CPU: peak of (window average, per-interval peak) in millicores. cpu_s_delta is
		# the window's CPU-seconds (col 59; the per-window cost the scaling fits use).
		local cpu_m_delta cpu_s_delta="N/A"
		if (( restarted_or_unknown )); then
			cpu_m_delta="N/A"
		else
			local b_cpu_s f_cpu_s window_avg_m=0
			b_cpu_s=N/A
			if [[ -n "$baseline" ]]; then b_cpu_s=$(extract_gauge_exact "$baseline" process_cpu_seconds_total); fi
			f_cpu_s=$(extract_gauge_exact "$final" process_cpu_seconds_total)
			cpu_s_delta=$(awk -v b="$b_cpu_s" -v f="$f_cpu_s" '
				BEGIN { if (b == "N/A" || f == "N/A" || f - b < 0) print "N/A"; else printf "%.2f", f - b }')
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
			b_sum=0 b_cnt=0
			if [[ -n "$baseline" ]]; then
				b_sum=$(extract_hist_sum "$baseline" pilot_xds_config_size_bytes)
				b_cnt=$(extract_hist_count "$baseline" pilot_xds_config_size_bytes)
			fi
			f_sum=$(extract_hist_sum "$final" pilot_xds_config_size_bytes)
			f_cnt=$(extract_hist_count "$final" pilot_xds_config_size_bytes)
			cs_avg=$(awk -v bs="$b_sum" -v fs="$f_sum" -v bc="$b_cnt" -v fc="$f_cnt" '
				BEGIN {
					ds = fs - bs; dc = fc - bc
					# Nothing observed, or the sum went backwards (a reset): N/A, not 0.
					if (dc <= 0 || ds < 0) { print "N/A"; exit }
					printf "%.0f", ds/dc
				}')
		fi

		# Traffic-management istiod columns (44-51 are appended below). pilot_virt_services
		# is a gauge from the final scrape; the two timing averages are histogram deltas,
		# so they follow the restart guard like every other counter/histogram (PL13).
		local virt_services push_time_avg pushctx_avg istiod_services
		virt_services=$(extract_gauge_exact "$final" pilot_virt_services)
		# Services istiod knows (col 58): mesh-global gauge from the same final scrape,
		# summed over its series within this pod, never across pods (PL28).
		istiod_services=$(extract_gauge_sum "$f_file" pilot_services)
		[[ "$istiod_services" == unknown ]] && istiod_services="N/A"
		if (( restarted_or_unknown )); then
			push_time_avg="N/A"; pushctx_avg="N/A"
		else
			push_time_avg=$(hist_delta_avg_ms "$baseline" "$final" pilot_xds_push_time)
			pushctx_avg=$(hist_delta_avg_ms "$baseline" "$final" pilot_pushcontext_init_seconds)
		fi

		# Per-sidecar /config_dump sampling (only in final/combined phase).
		local cd_avg="N/A" cd_p50="N/A" cd_max="N/A" cd_samples="0/0"
		local sc_clusters="N/A" sc_cds="N/A" sc_rds="N/A" sc_mem="N/A"
		if (( CONFIG_DUMP_SAMPLES > 0 )); then
			local cd_out cd_csv cd_meta
			if [[ -z "${CD_CACHE[$ctx]+x}" ]]; then
				CD_CACHE[$ctx]="$(collect_config_dump_samples "$ctx" "$CONFIG_DUMP_SAMPLES" || true)"
			fi
			cd_out="${CD_CACHE[$ctx]}"
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
			[[ "$cd_meta" =~ (^|\|)mem=([^|]*) ]] && { agg="$(aggregate_sample_bytes "${BASH_REMATCH[2]}")"; sc_mem="${agg%%|*}"; }
		fi

		# Capacity columns (read-only, cached per ctx, outside the scrape window).
		collect_capacity_for_ctx "$ctx"
		local cap_fields="${CAP_CACHE[$ctx]}"; cap_fields="${cap_fields// /$'\t'}"
		# Growth-mode gateway and root-cert columns (cached per ctx, outside the window).
		collect_growth_for_ctx "$ctx"

		local tm_fields="${TRAFFIC_CONFIG}\t${VSDR_SERVICES}\t${virt_services}\t${push_time_avg}\t${pushctx_avg}\t${sc_clusters}\t${sc_cds}\t${sc_rds}"
		local gr_fields
		gr_fields="$(growth_meta_fields)\t${istiod_services}\t${cpu_s_delta}\t${sc_mem}\t${GROWTH_CTX_CACHE[$ctx]}\t${GROWTH_CTX_CACHE2[$ctx]}"
		echo -e "${ts}\t${ctx}\t${MESH_SIZE}\t${SERVICE_COUNT}\t${REPLICAS}\t${NAMESPACE_COUNT}\t${SIDECAR_SCOPING}\t${mem_mi}\t${conv_p50}\t${conv_p99}\t${queue_p50}\t${queue_p99}\t${pushes_delta}\t${pushes_rate}\t${push_by_type[0]}\t${push_by_type[1]}\t${push_by_type[2]}\t${push_by_type[3]}\t${push_by_type[4]}\t${evts_delta}\t${evts_rate}\t${connected_proxies}\t${cs_avg}\t${cd_avg}\t${cd_p50}\t${cd_max}\t${cd_samples}\t${window_sec}\t${total_skew_ms}\t${settle_input_sec}\t${istiod_restarted}\t${cpu_m_delta}\t${go_heap_alloc_mi}\t${go_heap_inuse_mi}\t${cap_fields}\t$(cluster_fields "$ctx")\t${tm_fields}\t${gr_fields}" >> "$rows_file"
		echo "  Scraped $ctx/${POD_NAMES[k]}: cpu_delta=${cpu_m_delta}m mem=${mem_mi}Mi heap_alloc=${go_heap_alloc_mi}Mi heap_inuse=${go_heap_inuse_mi}Mi proxies=${connected_proxies} cluster=${CLUSTER_PROXIES[$ctx]:-N/A} sidecars=${SIDECAR_PODS[$ctx]:-N/A} check=${PROXY_CHECK[$ctx]:-N/A} pushes_delta=${pushes_delta} (eds=${push_by_type[1]} cds=${push_by_type[0]}) cfg_dump_avg=${cd_avg}"
		echo "    traffic=${TRAFFIC_CONFIG} vsdr_services=${VSDR_SERVICES} istiod_virt_services=${virt_services} push_time_avg=${push_time_avg}ms pushctx_init_avg=${pushctx_avg}ms sidecar_clusters_avg=${sc_clusters} cds_bytes_avg=${sc_cds} rds_bytes_avg=${sc_rds}"
		echo "    window=${WINDOW_KIND} services_per_namespace=${SERVICES_PER_NAMESPACE} workload=${WORKLOAD_MODE} istiod_services=${istiod_services} cpu_s=${cpu_s_delta} sidecar_envoy_mem=${sc_mem}Mi"
	done

	# One degraded row per dropped (zero-pod) context: the context column keeps the
	# context name, restarted=unknown and every numeric column is N/A, so the row is
	# counted in n_total but excluded from n_valid.
	local dctx
	for dctx in ${DROPPED_CTXS[@]+"${DROPPED_CTXS[@]}"}; do
		echo "warning: context ${dctx}: dropped (zero istiod pods); emitting degraded N/A row" >&2
		# Node capacity is still readable with zero istiod pods.
		collect_capacity_for_ctx "$dctx"
		local cap_fields="${CAP_CACHE[$dctx]}"; cap_fields="${cap_fields// /$'\t'}"
		echo -e "${ts}\t${dctx}\t${MESH_SIZE}\t${SERVICE_COUNT}\t${REPLICAS}\t${NAMESPACE_COUNT}\t${SIDECAR_SCOPING}\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t${window_sec}\t${total_skew_ms}\t${settle_input_sec}\tunknown\tN/A\tN/A\tN/A\t${cap_fields}\t$(cluster_fields "$dctx")\t$(traffic_na_fields)\t$(growth_na_fields)" >> "$rows_file"
	done
	# One write: a HARNESS_CHANGED_AT line when these rows ran other harness files than the
	# TSV records, then an ISTIOD_NOT_READY line when an istiod pod was Running but not Ready
	# at the baseline (<member>=<pod>, one entry per pod, comma-separated: its rows average in
	# a replica that took no new proxy connections), then a WINDOW_ROWS line (each member's
	# row count, and after a / the replicas its istiod Deployment wanted at the baseline, when
	# read: a report tells a write that was cut from a member with fewer istiod replicas,
	# CP_CELL_AWK, and a member that ran the cell on fewer pods than it wants), then the
	# rows, then the final phase's HARNESS_CHANGED_AT line when it ran other files than the
	# rows are credited to (HCL_AFTER).
	local win_file="${TMP_DIR}/window" sctx wr_spec="" nr_line="" nrp
	for sctx in "${!ISTIOD_SPEC[@]}"; do wr_spec+="${sctx}"$'\t'"${ISTIOD_SPEC[$sctx]}"$'\n'; done
	for sctx in "${CONTEXTS[@]}"; do
		for nrp in ${ISTIOD_NOTREADY[$sctx]:-}; do nr_line+="${nr_line:+,}${sctx}=${nrp}"; done
	done
	if [[ -s "$rows_file" ]]; then
		{
			harness_change_line
			[[ -z "$nr_line" ]] || printf '# ISTIOD_NOT_READY=%s\n' "$nr_line"
			WR_SPEC="$wr_spec" awk -F'\t' '
				BEGIN { ns = split(ENVIRON["WR_SPEC"], sl, "\n"); for (i = 1; i <= ns; i++) if (split(sl[i], f, "\t") == 2 && f[2] ~ /^[0-9]+$/) sp[f[1]] = f[2] }
				{ if (!($2 in n)) o[++k] = $2; n[$2]++ }
				END { printf "# WINDOW_ROWS="; for (i = 1; i <= k; i++) printf "%s%s=%d%s", (i > 1 ? "," : ""), o[i], n[o[i]], ((o[i] in sp) ? "/" sp[o[i]] : ""); print "" }' "$rows_file"
			cat "$rows_file"
			[[ -z "$HCL_AFTER" ]] || printf '%s\n' "$HCL_AFTER"
		} > "$win_file" || die "could not write the window's rows to ${win_file}"
		# A write cut short (a full disk, a step killed while it appended) leaves the TSV's
		# last line without its newline: end it, so these lines do not merge onto it.
		tsv_end_line "$TSV_FILE" || die "could not end the last line of ${TSV_FILE} (a write cut short left it without a newline), so the window's rows would merge with it"
		cat "$win_file" >> "$TSV_FILE" || die "could not append the window's rows to ${TSV_FILE}"
	fi

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
		CD_CACHE=()
		NODE_KV_CACHE=()
		POD_KV_CACHE=()
		CLUSTER_PROXIES=()
		SIDECAR_PODS=()
		PROXY_CHECK=()
		GROWTH_CTX_CACHE=()
		# The polled peaks are this window's too: without this, istiod_mem_mi and the
		# peak CPU keep the highest value of every earlier window.
		rm -f "${TMP_DIR}"/peak-mem-*.val "${TMP_DIR}"/peak-cpu-*.val "${TMP_DIR}"/prev-cpu-*.val
		scrape_window "$INTERVAL"
		# resolve_pods read the pods' readiness once, before the first window: later
		# windows were not read, so their rows get no ISTIOD_NOT_READY line.
		ISTIOD_NOTREADY=()
	done
elif [[ "$PHASE" == baseline ]]; then
	echo ""
	echo "=== Baseline scrape only (phase=baseline) ==="
	echo "  Writing baseline metrics to $STATE_DIR"
	# The baseline's harness, for the final's rows (harness_change_line).
	rm -f "${STATE_DIR}/harness"
	printf '%s\t%s\t%s\n' "$HARNESS_SHA" "$HARNESS_CONTENT_KEY" "$HARNESS_READ_AT" > "${STATE_DIR}/harness" \
		|| echo "warning: could not write ${STATE_DIR}/harness: the final phase credits its rows to its own harness only" >&2
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
		echo "| Istio version | $(istio_version_label) |"
		echo "| Harness SHA | ${HARNESS_SHA} |"
		echo "| Run config | \`${RUN_CONFIG:-none}\` (sha256 \`${RUN_CONFIG_SHA256:-none}\`) |"
		echo "| Kube versions | ${KUBE_VERSIONS_CSV} |"
		echo "| Contexts | ${CONTEXTS[*]} |"
		echo "| Last window written | mesh ${MESH_SIZE}, ${SERVICE_COUNT} services x ${REPLICAS} replicas in ${NAMESPACE_COUNT} namespace(s), scoping ${SIDECAR_SCOPING}, traffic ${TRAFFIC_CONFIG} (VS+DR services ${VSDR_SERVICES}; every ${VSDR_EVERY}, ${VSDR_SUBSETS} subsets) |"
		echo "| Config-dump samples | ${CONFIG_DUMP_SAMPLES} |"
		echo "| Settle (s) | ${SETTLE_SEC} |"
		echo "| Proxy check tolerance | ${PROXY_CHECK_TOL_PCT}% (min diff ${PROXY_CHECK_MIN_DIFF}) |"
		echo ""
		echo "## Summary"
		echo ""
		echo "Every row of the TSV (one per istiod pod per window). Proxies is per istiod pod; Cluster proxies sums them over the cluster's istiod pods. CPU peak = the larger of the window average and the busiest 5 s poll; p99 values are istiod histogram buckets (ms), † = pinned in the first bucket (unresolved below 100 ms). MiB = 1024 x 1024 bytes."
		echo ""
		echo "| Context | mesh | svc | reps | ns | scoping | traffic | CPU peak (m) | RSS peak (Mi) | Heap alloc (Mi) | Heap inuse (Mi) | Conv p99 (ms) | Queue p99 (ms) | Proxies | Cluster proxies | Sidecar pods | Proxy check | Pushes Δ | EDS Δ | CDS Δ | istiod VS | Cfg dump avg (MiB) | Sidecar clusters |"
		echo "|---------|------|-----|------|----|---------|---------|--------------|---------------|-----------------|-----------------|---------------|----------------|---------|-----------------|--------------|-------------|----------|-------|-------|-----------|--------------------|------------------|"
		# Cols 41+ are read by header name: a reused older file (40 columns) has none.
		awk -F'\t' '
		/^timestamp\t/ { delete ix; for (i = 1; i <= NF; i++) ix[$i] = i; hn = NF; next }
		function c(name) { return ((name in ix) && NF >= ix[name]) ? $(ix[name]) : "N/A" }
		function bucket(v) {
			if (v == "overflow") return "overflow"
			if (v !~ /^[0-9.]+$/ || v + 0 <= 0) return "N/A"
			if (v + 0 <= 100) return "0-100 †"
			if (v + 0 <= 500) return "100-500"
			if (v + 0 <= 1000) return "500-1000"
			if (v + 0 <= 3000) return "1000-3000"
			if (v + 0 <= 5000) return "3000-5000"
			if (v + 0 <= 10000) return "5000-10000"
			if (v + 0 <= 20000) return "10000-20000"
			if (v + 0 <= 30000) return "20000-30000"
			return ">30000"
		}
		# A row has its header'"'"'s columns (CP_CELL_AWK cp_isrow): a shorter one was cut.
		!/^#/ && NF >= (hn > 40 ? hn : 40) {
			cfg_mb = ($24+0 > 0) ? sprintf("%.2f", $24/1048576) : "N/A"
			tc = c("traffic_config"); if (tc == "N/A") tc = "none"
			printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $2, $3, $4, $5, $6, $7, tc, $32, $8, $33, $34, bucket($10), bucket($12), $22, c("cluster_connected_proxies"), c("sidecar_pods"), c("proxy_check"), $13, $16, $15, c("istiod_virt_services"), cfg_mb, c("sidecar_clusters_avg")
		}' "$TSV_FILE"
		echo ""
		echo "## Raw Data"
		echo ""
		echo "TSV: [\`$(basename "$TSV_FILE")\`]($(basename "$TSV_FILE"))"
	} > "$MD_FILE"
	echo "Summary written to $MD_FILE"
fi

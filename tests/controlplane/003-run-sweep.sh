#!/usr/bin/env bash
# Orchestrate control-plane resource collection across the cross-product of
# six sweep axes: mesh size × service count × replicas × namespace count
# × sidecar scoping × traffic config (none / vsdr).
#
# For every combination, deploys dummy workloads, settles, scrapes istiod, and
# cleans up before moving on. Uses split-phase metrics so the deploy-time
# istiod push storm lands inside the measurement window.
#
# Usage:
#   ./tests/controlplane/003-run-sweep.sh [options]
#
# Examples:
#   # Default sweep: mesh sizes 1..N with 10 svc x 3 replicas x 1 ns:
#   ./tests/controlplane/003-run-sweep.sh --contexts <mesh-a-ctx>,<mesh-b-ctx>
#
#   # Service count x Sidecar scoping at mesh size 2:
#   ./tests/controlplane/003-run-sweep.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> \
#     --mesh-sizes 2 --service-counts 10,100 --sidecar-scopings none,namespace,explicit
#
#   # Bare services vs a VirtualService + DestinationRule per service, back to back:
#   ./tests/controlplane/003-run-sweep.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> \
#     --mesh-sizes 2 --service-counts 10 --replica-counts 2 --traffic-configs none,vsdr
#
#   # Dry-run to see the planned matrix:
#   ./tests/controlplane/003-run-sweep.sh --dry-run --contexts <mesh-a-ctx>,<mesh-b-ctx>
#
#   # The whole sweep from a run config (axes, settle, results dir; flags still win):
#   ./tests/controlplane/003-run-sweep.sh --config tests/controlplane/configs/smoke.env --dry-run
# ci-dry-run: --traffic-configs none,vsdr
set -euo pipefail
# Loud ERR trap for unexpected aborts; per-combo failures become row statuses.
trap 'rc=$?; echo "FATAL: ${0##*/} aborted (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # config_preload, config_preamble_lines
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
# The steps this sweep runs inherit them (and RUN_CONFIG*) from the environment; the
# per-combo flags it passes still win.
config_preload controlplane "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/config/options.env"  # SCALE_* preamble keys
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/timestamp.sh"  # now_ms for the peak poller
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"  # harness_sha / probe_kube_versions for the pre-created preamble
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/capacity.sh"  # cap_node_totals / cap_istiod_limits for the capacity lines
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/envelope.sh"  # cluster-infra preamble + campaign-end scale envelope
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/metrics.sh"  # extractors fanout.sh needs (growth memory guard)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fanout.sh"  # per-pod istiod port-forwards (growth memory guard)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/growth.sh"  # istiod heap, gateway Envoy memory (growth memory guard)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fit.sh"  # mem_guard_project / mem_guard_verdict

CONTEXTS_CSV=""
# Axes: the plural key (a CSV, PL7), else the singular key 001/002 use, else the default.
MESH_SIZES_CSV="${CONTROLPLANE_MESH_SIZES:-}"
SERVICE_COUNTS_CSV="${CONTROLPLANE_SERVICE_COUNTS:-${CONTROLPLANE_SERVICE_COUNT:-10}}"
REPLICA_COUNTS_CSV="${CONTROLPLANE_REPLICA_COUNTS:-${CONTROLPLANE_REPLICAS_PER_SERVICE:-3}}"
NAMESPACE_COUNTS_CSV="${CONTROLPLANE_NAMESPACE_COUNTS:-${CONTROLPLANE_NAMESPACE_COUNT:-1}}"
SIDECAR_SCOPINGS_CSV="${CONTROLPLANE_SIDECAR_SCOPINGS:-${CONTROLPLANE_SIDECAR_SCOPING:-none}}"
TRAFFIC_CONFIGS_CSV="${CONTROLPLANE_TRAFFIC_CONFIGS:-${CONTROLPLANE_TRAFFIC_CONFIG:-none}}"
VSDR_EVERY="${CONTROLPLANE_VSDR_EVERY:-1}"
VSDR_SUBSETS="${CONTROLPLANE_VSDR_SUBSETS:-2}"
VSDR_APPLY="${CONTROLPLANE_VSDR_APPLY:-together}"
VSDR_APPLY_FLAG=0
# 1 when passed as a flag: --resume refuses a flag that conflicts with the resumed
# preamble, and otherwise adopts the preamble's value.
VSDR_EVERY_FLAG=0
VSDR_SUBSETS_FLAG=0
CONFIG_DUMP_SAMPLES="${CONTROLPLANE_CONFIG_DUMP_SAMPLES:-3}"
OUTPUT_DIR_BASE="$(config_repo_path "${CONTROLPLANE_RESULTS_DIR}")"
# 1 when --output-dir is passed (--resume refuses it; a results dir from the
# environment or --config does not count).
OUTPUT_DIR_FROM_FLAG=0
SETTLE_SEC="${CONTROLPLANE_SETTLE_SEC:-60}"
DRY_RUN=0
METRICS_API_STATUS="unknown"  # set by metrics_preflight; recorded in the preamble
FORCE_LARGE_MATRIX=0
MAX_MATRIX="${CONTROLPLANE_MAX_MATRIX:-64}"
# --resume: reuse an existing sweep dir + RUN_ID and skip combos that already
# have a valid row (istiod_restarted=="0" for the same six axis values).
RESUME_DIR=""
# 1 when --service-counts is passed (growth mode refuses it: services = N x K).
SERVICE_COUNTS_FLAG=0

# Namespace scaling (growth mode). CSV axes take the plural key (PL7), else the
# singular one 001/002 read.
SPN_CSV="${CONTROLPLANE_SERVICES_PER_NAMESPACES:-${CONTROLPLANE_SERVICES_PER_NAMESPACE:-0}}"
GROWTH_MODE="${CONTROLPLANE_GROWTH_MODE:-in-place}"
WORKLOAD_MODE="${CONTROLPLANE_WORKLOAD_MODE:-pods}"
MEASUREMENT_POD_COUNTS_CSV="${CONTROLPLANE_MEASUREMENT_POD_COUNTS:-${CONTROLPLANE_MEASUREMENT_PODS:-4}}"
OUTSIDE_NAMESPACES="${CONTROLPLANE_OUTSIDE_NAMESPACES:-0}"
OUTSIDE_MODES_CSV="${CONTROLPLANE_OUTSIDE_MODES:-${CONTROLPLANE_OUTSIDE_MODE:-none}}"
PROBE_SETTLE_SEC="${CONTROLPLANE_PROBE_SETTLE_SEC:-60}"
MEM_STOP_PCT="${CONTROLPLANE_MEM_STOP_PCT:-70}"
MEM_GUARD_CONTEXTS_CSV="${CONTROLPLANE_MEM_GUARD_CONTEXTS:-}"
SERIES_RETIRE="${CONTROLPLANE_SERIES_RETIRE:-undiscover}"
NS_DELETE_SEC_PER_NS="${CONTROLPLANE_NS_DELETE_SEC_PER_NS:-1.0}"
# A series retire is retried, then verified (no namespace of the series still discovered).
RETIRE_ATTEMPTS="${CONTROLPLANE_RETIRE_ATTEMPTS:-3}"
RETIRE_BACKOFF_S="${CONTROLPLANE_RETIRE_BACKOFF_S:-10}"
# Absolute gateway memory model of the guard (Mi per 1000 discovered Services, burst factor).
GW_MI_INTERCEPT="${CONTROLPLANE_GW_MI_INTERCEPT:-10}"
EWGW_MI_PER_1000="${CONTROLPLANE_EWGW_MI_PER_1000_SVC:-145}"
EWGW_BURST="${CONTROLPLANE_EWGW_BURST_FACTOR:-2.0}"
INGW_MI_PER_1000="${CONTROLPLANE_INGW_MI_PER_1000_SVC:-91}"
INGW_BURST="${CONTROLPLANE_INGW_BURST_FACTOR:-1.2}"
# Leftover test namespaces at a series start: undiscovered ones above this count warn.
LEFTOVER_NS_WARN="${CONTROLPLANE_LEFTOVER_NS_WARN:-100}"

NS="${CONTROLPLANE_TEST_NAMESPACE:-controlplane-test}"

usage() {
	local mesh_sizes_default='"1,2,...,len(contexts)"'
	[[ -z "$MESH_SIZES_CSV" ]] || mesh_sizes_default="$MESH_SIZES_CSV"
	cat <<EOF
Usage: $(basename "$0") [options]

Run config:
  --config FILE               Run config of KEY=value lines (config/options.env keys; see
                              tests/controlplane/README.md, "Run config"). The steps the
                              sweep runs inherit it. Precedence: flag > --config >
                              environment > default.

Sweep dimensions (cross-product):
  --contexts CSV              All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV            Cluster counts (default: ${mesh_sizes_default}).
  --service-counts CSV        Dummy services per cluster (default: $SERVICE_COUNTS_CSV).
  --replica-counts CSV        Replicas per service (default: $REPLICA_COUNTS_CSV).
  --namespace-counts CSV      Namespaces to spread services across (default: $NAMESPACE_COUNTS_CSV).
  --sidecar-scopings CSV      Sidecar CR scoping modes: none,namespace,wide,explicit
                              (default: $SIDECAR_SCOPINGS_CSV). wide = a per-namespace
                              Sidecar with egress */* (unscoped).
  --traffic-configs CSV       Traffic management per service: none,vsdr
                              (default: $TRAFFIC_CONFIGS_CSV).
                              vsdr adds a VirtualService + DestinationRule per
                              configured service; innermost axis, so each none/vsdr
                              pair runs back to back. --traffic-config is an alias.

Traffic management (scalars, recorded in the TSV preamble):
  --vsdr-every N              Configure service i when i mod N == 0 (default: $VSDR_EVERY).
  --vsdr-subsets N            DestinationRule subsets; the service's replicas are split
                              over this many Deployments, so it must be <= every
                              --replica-counts value (default: $VSDR_SUBSETS).
  --vsdr-apply MODE           together: one apply inside the window (the pods start while
                              the VS/DR already exist); split: apply the workloads (and
                              wait for Ready) before the baseline, then only the VS/DR
                              inside the window (rows window_kind traffic; a none cell's
                              window is then idle). split separates the VS/DR push cost
                              from pod startup (BACKLOG 9.11). Default: $VSDR_APPLY.

Namespace scaling (growth mode; README "Namespace scaling"). Any K > 0 switches the
sweep to growth series: --namespace-counts is the ladder of N (ascending), services
are N x K (so --service-counts is refused), one replica count, traffic none, no
explicit scoping, no --resume.
  --services-per-namespaces CSV
                              K values, one growth series each (default: $SPN_CSV;
                              0 = the legacy sweep). --services-per-namespace is an alias.
  --growth MODE               in-place: grow one set of namespaces step by step and
                              measure a grow window plus one probe window per scoping
                              at each N; fresh: deploy and clean up every N x scoping
                              cell (the PL34 fidelity check). Default: $GROWTH_MODE.
  --workload-mode MODE        pods|config-only (default: $WORKLOAD_MODE). config-only:
                              Services without pods plus M measurement pods.
  --measurement-pod-counts CSV
                              config-only: measurement pods M, ascending (default:
                              $MEASUREMENT_POD_COUNTS_CSV). The first is the base; each further
                              value re-probes every scoping at the largest N (the
                              M-sweep: does istiod heap grow with M?). --measurement-pods
                              is an alias.
  --outside-namespaces X      Namespaces outside the mesh added at the largest N
                              (default: $OUTSIDE_NAMESPACES).
  --outside-modes CSV         unlabeled,labeled: the outside phases, in order (default:
                              $OUTSIDE_MODES_CSV; none = no phase). --outside-mode is an alias.
  --probe-settle SEC          Probe window: settle after a probe namespace is applied,
                              and again after its teardown (default: $PROBE_SETTLE_SEC).
  --mem-stop-pct PCT          Memory stop guard: skip a cell (SKIPPED_MEM_GUARD row) when
                              projected istiod heap or gateway Envoy memory exceeds PCT %
                              of its limit (default: $MEM_STOP_PCT; 0 disables).
  --mem-guard-contexts CSV    Contexts the guard samples (default: --contexts plus
                              \$SETUP_CONTEXTS: every member ingests the Services). A
                              live run adds the members the measured contexts' remote
                              secrets name, and warns about one without a kube context.
  --series-retire MODE        End of a series: undiscover (drop discovery labels, keep
                              the namespaces; 005 --undiscover --no-delete), delete (also
                              queue the namespace deletes, no wait) or keep (default:
                              $SERIES_RETIRE). undiscover and delete are retried
                              (CONTROLPLANE_RETIRE_ATTEMPTS) and verified: when a namespace
                              of the series is still discovered afterwards, the sweep
                              records RETIRE_FAILED, runs no further series and exits 1.

  The memory guard projects each component two ways and stops on either: relative
  (base + (current - base) x ratio^power, from the series start) and, for gateways,
  absolute ((CONTROLPLANE_GW_MI_INTERCEPT + Mi per 1000 Services x Services after the
  step / 1000) x burst factor; CONTROLPLANE_{EWGW,INGW}_MI_PER_1000_SVC and
  _BURST_FACTOR). It compares the container working set (kubectl top; else Envoy
  server.memory_physical_size, else server.memory_allocated) and istiod RSS with the
  limit. A live sweep also adds every mesh member its remote secrets name to the
  guard set (or warns when a member has no kube context), and refuses to start
  while a controlplane-test namespace of an earlier run is still discovered.

Other:
  --config-dump-samples N     Random pods per cluster to exec /config_dump on
                              (default: $CONFIG_DUMP_SAMPLES; 0 disables).
  --settle SEC                Seconds for the delta-window between baseline
                              and final scrape (default: $SETTLE_SEC).
  --output-dir DIR            Results base directory; each sweep gets a
                              sweep-<RUN_ID>/ subdir under it
                              (default: ${CONTROLPLANE_RESULTS_DIR}).
  --resume DIR                Resume an interrupted sweep in this sweep-<RUN_ID>/
                              dir: reuse its RUN_ID and skip combos that already
                              have a valid row. Scalars recorded once in the TSV
                              preamble (VSDR_EVERY and VSDR_SUBSETS when the run
                              includes vsdr, PROXY_CHECK_*) are taken from it; a
                              conflicting --vsdr-every/--vsdr-subsets flag is
                              refused. Not valid with --output-dir or --dry-run.
                              A sweep started with --config resumes only with the
                              same file (same sha256; add --config
                              <DIR>/run-config-<RUN_ID>.env); one started without
                              it warns when --config is given.
  --force-large-matrix        Allow matrix > $MAX_MATRIX combinations (default: refuse).
  --dry-run                   Print plan and matrix, then exit.
  -h, --help                  Show this help.

Exit codes:
  0  every cell ran; rows with istiod_restarted 1/unknown are measurement outcomes,
     counted in the report's n_total and left out of n_valid
  1  the sweep stopped: a bad flag or precondition, an unexpected error, or a series
     that could not be retired (RETIRE_FAILED; the reports are written)
  4  the sweep finished and wrote its reports, but N cells have a status row instead of
     a measurement (SETUP_FAILED, PROBE_FAILED, GROW_FAILED, SWITCH_FAILED,
     SKIPPED_MEM_GUARD, SKIPPED_SERIES_STOPPED); stderr ends with "N of M cells failed"
     by reason

Environment:
  ISTIO_VERSION_CHECK (fail, the default, or warn): stop before any change, or warn and
  record what the mesh runs, when the members' Istio CR version is not ISTIO_VERSION.
  SETUP_CONTEXTS, CONTROLPLANE_SERVICE_COUNT, CONTROLPLANE_REPLICAS_PER_SERVICE,
  CONTROLPLANE_NAMESPACE_COUNT, CONTROLPLANE_SIDECAR_SCOPING,
  CONTROLPLANE_TRAFFIC_CONFIG, CONTROLPLANE_VSDR_EVERY, CONTROLPLANE_VSDR_SUBSETS,
  CONTROLPLANE_CONFIG_DUMP_SAMPLES, CONTROLPLANE_MAX_MATRIX.
  Axis CSVs: CONTROLPLANE_MESH_SIZES, CONTROLPLANE_SERVICE_COUNTS,
  CONTROLPLANE_REPLICA_COUNTS, CONTROLPLANE_NAMESPACE_COUNTS,
  CONTROLPLANE_SIDECAR_SCOPINGS, CONTROLPLANE_TRAFFIC_CONFIGS (each, when empty, falls
  back to the singular key above). CONTROLPLANE_SETTLE_SEC (--settle),
  CONTROLPLANE_RESULTS_DIR (--output-dir; relative to the repo root),
  CONTROLPLANE_WAIT_TIMEOUT_SEC (001's pod readiness wait). The sweep checks the knobs
  only its steps read (CONTROLPLANE_WAIT_TIMEOUT_SEC, CONTROLPLANE_SETUP_NS_WAIT_SEC,
  CONTROLPLANE_APPLY_*, CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S,
  CONTROLPLANE_NS_DELETE_TIMEOUT_SEC, CONTROLPLANE_CLEANUP_GRACE_SEC) before the first
  setup, --dry-run included.
  SCALE_SIZING_MODE (must be fixed: the sweep refuses auto, which only standalone 001
  supports), SCALE_TARGET_FRACTION (recorded in the TSV preamble).
  Growth mode: CONTROLPLANE_SERVICES_PER_NAMESPACES (else ..._SERVICES_PER_NAMESPACE),
  CONTROLPLANE_GROWTH_MODE, CONTROLPLANE_WORKLOAD_MODE,
  CONTROLPLANE_MEASUREMENT_POD_COUNTS (else ..._MEASUREMENT_PODS),
  CONTROLPLANE_MEASUREMENT_PROXY_MEM_LIMIT, CONTROLPLANE_OUTSIDE_NAMESPACES,
  CONTROLPLANE_OUTSIDE_MODES (else ..._OUTSIDE_MODE), CONTROLPLANE_PROBE_SETTLE_SEC,
  CONTROLPLANE_MEM_STOP_PCT, CONTROLPLANE_MEM_GUARD_CONTEXTS, CONTROLPLANE_SERIES_RETIRE,
  CONTROLPLANE_NS_DELETE_SEC_PER_NS (the plan's namespace-deletion estimate),
  CONTROLPLANE_RETIRE_ATTEMPTS, CONTROLPLANE_RETIRE_BACKOFF_S, CONTROLPLANE_GW_MI_INTERCEPT,
  CONTROLPLANE_EWGW_MI_PER_1000_SVC, CONTROLPLANE_EWGW_BURST_FACTOR,
  CONTROLPLANE_INGW_MI_PER_1000_SVC, CONTROLPLANE_INGW_BURST_FACTOR,
  CONTROLPLANE_LEFTOVER_NS_WARN.
  SCALE_PER_POD_CPU_M: per-pod CPU of the capacity plan; empty (default) = the live
  Istio CR's sidecar CPU request on the first context (Istio's 100m when the CR sets
  none); a value wins over the live reading. The plan compares the largest combo with
  each member's free CPU (allocatable minus what other pods request); 001 refuses a step
  that does not fit unless SCALE_CPU_PREFLIGHT_ENFORCE=0 (warn only, for a node autoscaler).
  METRICS_READY_TIMEOUT (default 120; 0 disables), METRICS_READY_INTERVAL (10):
  pre-sweep wait for 'kubectl top nodes'; warns (never aborts) if unavailable.
  CAP_TOP_TIMEOUT (default 15), CAP_TOP_ATTEMPTS (2), CAP_TOP_BACKOFF_S (2):
  timeout and retry for the kubectl top reads.
  METRICS_SCRAPE_TIMEOUT (default 30): curl --max-time for istiod /metrics.
  CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT (default 10), CONTROLPLANE_PROXY_CHECK_MIN_DIFF
  (default 2): warn when a cluster's connected proxies and its Running sidecar pods
  differ by more than max(tolerance %, min diff); recorded in the TSV preamble.

Requires GNU timeout for a live run (002's config-dump samples, the memory guard's
Envoy-stats reads; on macOS: brew install coreutils, which installs gtimeout). Without
it a live sweep stops before any cluster change; --dry-run does not need it.
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
	--mesh-sizes)
		[[ -n "${2:-}" ]] || die "--mesh-sizes requires a value"
		MESH_SIZES_CSV="$2"
		shift 2
		;;
	--service-counts)
		[[ -n "${2:-}" ]] || die "--service-counts requires a value"
		SERVICE_COUNTS_CSV="$2"
		SERVICE_COUNTS_FLAG=1
		shift 2
		;;
	--services-per-namespaces | --services-per-namespace)
		[[ -n "${2:-}" ]] || die "$1 requires a value"
		# PL7: the singular form (001/002 spelling) is an alias.
		[[ "$1" == --services-per-namespace ]] && echo "note: --services-per-namespace is an alias; the sweep flag is --services-per-namespaces CSV" >&2
		SPN_CSV="$2"
		shift 2
		;;
	--growth)
		[[ -n "${2:-}" ]] || die "--growth requires a value"
		GROWTH_MODE="$2"
		shift 2
		;;
	--workload-mode)
		[[ -n "${2:-}" ]] || die "--workload-mode requires a value"
		WORKLOAD_MODE="$2"
		shift 2
		;;
	--measurement-pod-counts | --measurement-pods)
		[[ -n "${2:-}" ]] || die "$1 requires a value"
		[[ "$1" == --measurement-pods ]] && echo "note: --measurement-pods is an alias; the sweep flag is --measurement-pod-counts CSV" >&2
		MEASUREMENT_POD_COUNTS_CSV="$2"
		shift 2
		;;
	--outside-namespaces)
		[[ -n "${2:-}" ]] || die "--outside-namespaces requires a value"
		OUTSIDE_NAMESPACES="$2"
		shift 2
		;;
	--outside-modes | --outside-mode)
		[[ -n "${2:-}" ]] || die "$1 requires a value"
		[[ "$1" == --outside-mode ]] && echo "note: --outside-mode is an alias; the sweep flag is --outside-modes CSV" >&2
		OUTSIDE_MODES_CSV="$2"
		shift 2
		;;
	--probe-settle)
		[[ -n "${2:-}" ]] || die "--probe-settle requires a value"
		PROBE_SETTLE_SEC="$2"
		shift 2
		;;
	--mem-stop-pct)
		[[ -n "${2:-}" ]] || die "--mem-stop-pct requires a value"
		MEM_STOP_PCT="$2"
		shift 2
		;;
	--mem-guard-contexts)
		[[ -n "${2:-}" ]] || die "--mem-guard-contexts requires a value"
		MEM_GUARD_CONTEXTS_CSV="$2"
		shift 2
		;;
	--series-retire)
		[[ -n "${2:-}" ]] || die "--series-retire requires a value"
		SERIES_RETIRE="$2"
		shift 2
		;;
	--replica-counts)
		[[ -n "${2:-}" ]] || die "--replica-counts requires a value"
		REPLICA_COUNTS_CSV="$2"
		shift 2
		;;
	--namespace-counts)
		[[ -n "${2:-}" ]] || die "--namespace-counts requires a value"
		NAMESPACE_COUNTS_CSV="$2"
		shift 2
		;;
	--sidecar-scopings)
		[[ -n "${2:-}" ]] || die "--sidecar-scopings requires a value"
		SIDECAR_SCOPINGS_CSV="$2"
		shift 2
		;;
	--traffic-configs | --traffic-config)
		[[ -n "${2:-}" ]] || die "$1 requires a value"
		# PL7: the singular form (001/002 spelling) is a one-value alias.
		[[ "$1" == --traffic-config ]] && echo "note: --traffic-config is an alias; the sweep flag is --traffic-configs CSV" >&2
		TRAFFIC_CONFIGS_CSV="$2"
		shift 2
		;;
	--vsdr-every)
		[[ -n "${2:-}" ]] || die "--vsdr-every requires a value"
		VSDR_EVERY="$2"
		VSDR_EVERY_FLAG=1
		shift 2
		;;
	--vsdr-subsets)
		[[ -n "${2:-}" ]] || die "--vsdr-subsets requires a value"
		VSDR_SUBSETS="$2"
		VSDR_SUBSETS_FLAG=1
		shift 2
		;;
	--vsdr-apply)
		[[ -n "${2:-}" ]] || die "--vsdr-apply requires a value"
		VSDR_APPLY="$2"
		VSDR_APPLY_FLAG=1
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
		OUTPUT_DIR_BASE="$2"
		OUTPUT_DIR_FROM_FLAG=1
		shift 2
		;;
	--resume)
		[[ -n "${2:-}" ]] || die "--resume requires a value (an existing sweep dir)"
		RESUME_DIR="$2"
		shift 2
		;;
	--force-large-matrix)
		FORCE_LARGE_MATRIX=1
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

is_nonneg_int "$SETTLE_SEC" || die "--settle must be a non-negative integer (got: $SETTLE_SEC)"
is_pos_int "$MAX_MATRIX" || die "CONTROLPLANE_MAX_MATRIX must be a positive integer (got: $MAX_MATRIX)"
# 002 reads the same two knobs per combo; validate once here so a typo fails the
# sweep up front instead of turning every combo into PROBE_FAILED.
PROXY_CHECK_TOL_PCT="${CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT:-10}"
PROXY_CHECK_MIN_DIFF="${CONTROLPLANE_PROXY_CHECK_MIN_DIFF:-2}"
is_nonneg_int "$PROXY_CHECK_TOL_PCT" || die "CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT must be a non-negative integer percent (got: $PROXY_CHECK_TOL_PCT)"
is_nonneg_int "$PROXY_CHECK_MIN_DIFF" || die "CONTROLPLANE_PROXY_CHECK_MIN_DIFF must be a non-negative integer (got: $PROXY_CHECK_MIN_DIFF)"
is_nonneg_int "$CONFIG_DUMP_SAMPLES" || die "--config-dump-samples (or CONTROLPLANE_CONFIG_DUMP_SAMPLES) must be a non-negative integer (got: $CONFIG_DUMP_SAMPLES)"
# SCALE_SIZING_MODE=auto makes 001 deploy a capacity-derived service count, while every
# row would carry the sweep's --service-counts value: a flat, mislabelled scaling curve
# (R16). Refused in every mode, before any cluster change; standalone 001 keeps auto.
case "${SCALE_SIZING_MODE:-fixed}" in
fixed) ;;
auto) die "SCALE_SIZING_MODE=auto is for a standalone 001 setup: in a sweep, 001 would deploy a capacity-derived service count while every row records the --service-counts value. Set SCALE_SIZING_MODE=fixed (environment or --config) and choose --service-counts; the capacity plan check a live sweep prints at startup says how many services fit." ;;
*) die "SCALE_SIZING_MODE must be fixed or auto (got: ${SCALE_SIZING_MODE})" ;;
esac
# Empty = read the live Istio CR's sidecar requests (capacity plan, 001 auto-sizing).
[[ -z "${SCALE_PER_POD_CPU_M:-}" ]] || is_pos_int "$SCALE_PER_POD_CPU_M" || die "SCALE_PER_POD_CPU_M must be empty (read the live sidecar request) or a positive integer of millicores (got: $SCALE_PER_POD_CPU_M)"
[[ -z "${SCALE_PER_POD_MEM_MI:-}" ]] || is_pos_int "$SCALE_PER_POD_MEM_MI" || die "SCALE_PER_POD_MEM_MI must be empty (read the live sidecar request) or a positive integer of Mi (got: $SCALE_PER_POD_MEM_MI)"
# So do 001, 002 and 005 with these; a typo would otherwise fail every setup or skip
# every cleanup mid-sweep, and pass --dry-run.
is_nonneg_int "${CONTROLPLANE_WAIT_TIMEOUT_SEC:-300}" || die "CONTROLPLANE_WAIT_TIMEOUT_SEC (read by 001) must be a non-negative integer (got: ${CONTROLPLANE_WAIT_TIMEOUT_SEC:-})"
[[ "${SCALE_CPU_PREFLIGHT_ENFORCE:-1}" =~ ^[01]$ ]] || die "SCALE_CPU_PREFLIGHT_ENFORCE (read by 001) must be 0 or 1 (got: ${SCALE_CPU_PREFLIGHT_ENFORCE:-})"
# The cleanup bound first: options.env defaults the setup wait to it.
is_pos_int "${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300}" || die "CONTROLPLANE_NS_DELETE_TIMEOUT_SEC (read by 005) must be a positive integer (got: ${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-})"
is_nonneg_int "${CONTROLPLANE_SETUP_NS_WAIT_SEC:-${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300}}" || die "CONTROLPLANE_SETUP_NS_WAIT_SEC (read by 001) must be a non-negative integer (got: ${CONTROLPLANE_SETUP_NS_WAIT_SEC:-})"
is_pos_int "${CONTROLPLANE_APPLY_ATTEMPTS:-3}" || die "CONTROLPLANE_APPLY_ATTEMPTS (read by 001) must be a positive integer (got: ${CONTROLPLANE_APPLY_ATTEMPTS:-})"
is_nonneg_int "${CONTROLPLANE_APPLY_BACKOFF_S:-5}" || die "CONTROLPLANE_APPLY_BACKOFF_S (read by 001) must be a non-negative integer (got: ${CONTROLPLANE_APPLY_BACKOFF_S:-})"
[[ "${CONTROLPLANE_APPLY_CHUNK_OBJECTS:-200}" =~ ^-?[0-9]+$ ]] || die "CONTROLPLANE_APPLY_CHUNK_OBJECTS (read by 001) must be an integer (got: ${CONTROLPLANE_APPLY_CHUNK_OBJECTS:-})"
is_pos_int "${CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S:-30}" || die "CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S (read by 002) must be a positive integer (got: ${CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S:-})"
is_pos_int "${CONTROLPLANE_CLEANUP_GRACE_SEC:-5}" || die "CONTROLPLANE_CLEANUP_GRACE_SEC (read by 005) must be a positive integer (got: ${CONTROLPLANE_CLEANUP_GRACE_SEC:-})"
# --resume already names the full sweep dir; refuse a custom --output-dir with it.
if [[ -n "$RESUME_DIR" ]] && ((OUTPUT_DIR_FROM_FLAG)); then
	die "--resume and --output-dir are mutually exclusive (--resume already names the full sweep dir)"
fi

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_csv "$CONTEXTS_CSV" CONTEXTS
else
	split_csv "$SETUP_CONTEXTS" CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

MESH_SIZES=()
if [[ -n "$MESH_SIZES_CSV" ]]; then
	split_csv "$MESH_SIZES_CSV" MESH_SIZES
else
	for ((i = 1; i <= ${#CONTEXTS[@]}; i++)); do
		MESH_SIZES+=("$i")
	done
fi
((${#MESH_SIZES[@]})) || die "no mesh sizes resolved"

SERVICE_COUNTS=()
split_csv "$SERVICE_COUNTS_CSV" SERVICE_COUNTS
((${#SERVICE_COUNTS[@]})) || die "--service-counts produced an empty list"

REPLICA_COUNTS=()
split_csv "$REPLICA_COUNTS_CSV" REPLICA_COUNTS
((${#REPLICA_COUNTS[@]})) || die "--replica-counts produced an empty list"

NAMESPACE_COUNTS=()
split_csv "$NAMESPACE_COUNTS_CSV" NAMESPACE_COUNTS
((${#NAMESPACE_COUNTS[@]})) || die "--namespace-counts produced an empty list"

SCOPINGS=()
split_csv "$SIDECAR_SCOPINGS_CSV" SCOPINGS
((${#SCOPINGS[@]})) || die "--sidecar-scopings produced an empty list"

TRAFFIC_CONFIGS=()
split_csv "$TRAFFIC_CONFIGS_CSV" TRAFFIC_CONFIGS
((${#TRAFFIC_CONFIGS[@]})) || die "--traffic-configs produced an empty list"

MAX_MESH_SIZE=0
for ms in "${MESH_SIZES[@]}"; do
	is_pos_int "$ms" || die "mesh-size '$ms' is not a positive integer"
	((ms >= 1 && ms <= ${#CONTEXTS[@]})) || die "mesh-size $ms out of range (have ${#CONTEXTS[@]} contexts)"
	((ms > MAX_MESH_SIZE)) && MAX_MESH_SIZE="$ms"
done
for sc in "${SERVICE_COUNTS[@]}"; do
	is_pos_int "$sc" || die "service-count '$sc' is not a positive integer"
done
for rc in "${REPLICA_COUNTS[@]}"; do
	is_pos_int "$rc" || die "replica-count '$rc' is not a positive integer"
done
for nc in "${NAMESPACE_COUNTS[@]}"; do
	is_pos_int "$nc" || die "namespace-count '$nc' is not a positive integer"
done
for scp in "${SCOPINGS[@]}"; do
	validate_scoping "$scp"
done
is_pos_int "$VSDR_EVERY" || die "--vsdr-every must be a positive integer (got: $VSDR_EVERY)"
is_pos_int "$VSDR_SUBSETS" || die "--vsdr-subsets must be a positive integer (got: $VSDR_SUBSETS)"
case "$VSDR_APPLY" in together | split) ;; *) die "--vsdr-apply must be together or split (got: $VSDR_APPLY)" ;; esac
# The rows' window kind: a split apply measures the VS/DR apply alone.
LEGACY_WINDOW_KIND=deploy
[[ "$VSDR_APPLY" == split ]] && LEGACY_WINDOW_KIND=traffic
HAS_VSDR=0
for tc in "${TRAFFIC_CONFIGS[@]}"; do
	validate_traffic_config "$tc"
	[[ "$tc" == vsdr ]] && HAS_VSDR=1
done

# Namespace scaling (growth mode): any K > 0 turns the sweep into growth series.
SPNS=()
split_csv "$SPN_CSV" SPNS
((${#SPNS[@]})) || die "--services-per-namespaces produced an empty list"
GROWTH=0
for k in "${SPNS[@]}"; do
	is_nonneg_int "$k" || die "services-per-namespace '$k' is not a non-negative integer"
	((k > 0)) && GROWTH=1
done
M_LIST=()
OUTSIDE_PHASES=()
if ((GROWTH)); then
	for k in "${SPNS[@]}"; do
		((k > 0)) || die "--services-per-namespaces mixes 0 (the legacy sweep) with growth series; run them separately"
	done
	# One series per mesh size x K: the report keys a series by RUN_ID, mesh size, K and
	# workload, so a repeated value would merge two series into one curve.
	[[ "$(printf '%s\n' "${SPNS[@]}" | sort -u | grep -c .)" == "${#SPNS[@]}" ]] \
		|| die "--services-per-namespaces repeats a value (${SPN_CSV}): each K is one growth series"
	[[ "$(printf '%s\n' "${MESH_SIZES[@]}" | sort -u | grep -c .)" == "${#MESH_SIZES[@]}" ]] \
		|| die "--mesh-sizes repeats a value ($(IFS=,; echo "${MESH_SIZES[*]}")): each mesh size is one growth series per K"
	((SERVICE_COUNTS_FLAG)) && die "--service-counts conflicts with --services-per-namespaces: a growth series has namespaces x services-per-namespace services"
	[[ -z "$RESUME_DIR" ]] || die "--resume is not supported for growth series; start a new sweep (one per series if needed)"
	case "$GROWTH_MODE" in in-place | fresh) ;; *) die "--growth must be in-place or fresh (got: $GROWTH_MODE)" ;; esac
	validate_workload_mode "$WORKLOAD_MODE"
	split_csv "$MEASUREMENT_POD_COUNTS_CSV" M_LIST
	((${#M_LIST[@]})) || die "--measurement-pod-counts produced an empty list"
	prev_m=0
	for m in "${M_LIST[@]}"; do
		is_pos_int "$m" || die "measurement-pod count '$m' is not a positive integer"
		((m > prev_m)) || die "--measurement-pod-counts must be strictly ascending (the M-sweep only adds measurement pods): ${MEASUREMENT_POD_COUNTS_CSV}"
		prev_m="$m"
	done
	if ((${#M_LIST[@]} > 1)) && [[ "$WORKLOAD_MODE" != config-only || "$GROWTH_MODE" != in-place ]]; then
		die "an M-sweep (several --measurement-pod-counts) needs --workload-mode config-only and --growth in-place"
	fi
	is_nonneg_int "$OUTSIDE_NAMESPACES" || die "--outside-namespaces must be a non-negative integer (got: $OUTSIDE_NAMESPACES)"
	_omodes=()
	split_csv "$OUTSIDE_MODES_CSV" _omodes
	for om in "${_omodes[@]}"; do
		validate_outside_mode "$om"
		[[ "$om" == none ]] || OUTSIDE_PHASES+=("$om")
	done
	if ((${#OUTSIDE_PHASES[@]})); then
		((OUTSIDE_NAMESPACES > 0)) || die "--outside-modes ${OUTSIDE_MODES_CSV} needs --outside-namespaces > 0"
		[[ "$GROWTH_MODE" == in-place ]] || die "the outside phase (--outside-modes) runs with --growth in-place only"
	elif ((OUTSIDE_NAMESPACES > 0)); then
		echo "note: --outside-namespaces ${OUTSIDE_NAMESPACES} without an --outside-modes phase (unlabeled,labeled) adds nothing" >&2
	fi
	is_nonneg_int "$PROBE_SETTLE_SEC" || die "--probe-settle must be a non-negative integer (got: $PROBE_SETTLE_SEC)"
	[[ "$MEM_STOP_PCT" =~ ^(0|[1-9][0-9]?|100)$ ]] || die "--mem-stop-pct must be an integer 0-100 (got: $MEM_STOP_PCT)"
	case "$SERIES_RETIRE" in undiscover | delete | keep) ;; *) die "--series-retire must be undiscover, delete or keep (got: $SERIES_RETIRE)" ;; esac
	if [[ "$SERIES_RETIRE" == keep && "$GROWTH_MODE" == in-place ]] && (( ${#MESH_SIZES[@]} * ${#SPNS[@]} > 1 )); then
		die "--series-retire keep leaves a series discovered, so every later series of this sweep would run on top of it (BACKLOG 9.3/9.10); run one series per sweep with keep"
	fi
	[[ "$NS_DELETE_SEC_PER_NS" =~ ^([0-9]+(\.[0-9]+)?|\.[0-9]+)$ ]] || die "CONTROLPLANE_NS_DELETE_SEC_PER_NS must be a non-negative number (got: $NS_DELETE_SEC_PER_NS)"
	is_pos_int "$RETIRE_ATTEMPTS" || die "CONTROLPLANE_RETIRE_ATTEMPTS must be a positive integer (got: $RETIRE_ATTEMPTS)"
	is_nonneg_int "$RETIRE_BACKOFF_S" || die "CONTROLPLANE_RETIRE_BACKOFF_S must be a non-negative integer (got: $RETIRE_BACKOFF_S)"
	is_nonneg_int "$LEFTOVER_NS_WARN" || die "CONTROLPLANE_LEFTOVER_NS_WARN must be a non-negative integer (got: $LEFTOVER_NS_WARN)"
	for _gk in CONTROLPLANE_GW_MI_INTERCEPT:"$GW_MI_INTERCEPT" CONTROLPLANE_EWGW_MI_PER_1000_SVC:"$EWGW_MI_PER_1000" \
		CONTROLPLANE_INGW_MI_PER_1000_SVC:"$INGW_MI_PER_1000" CONTROLPLANE_EWGW_BURST_FACTOR:"$EWGW_BURST" \
		CONTROLPLANE_INGW_BURST_FACTOR:"$INGW_BURST"; do
		[[ "${_gk#*:}" =~ ^([0-9]+(\.[0-9]+)?|\.[0-9]+)$ ]] || die "${_gk%%:*} must be a non-negative number (got: ${_gk#*:})"
	done
	for _gk in "$EWGW_BURST" "$INGW_BURST"; do
		awk -v f="$_gk" 'BEGIN { exit !(f + 0 >= 1) }' || die "a gateway burst factor below 1 would project less than the steady state (got: $_gk)"
	done
	for scp in "${SCOPINGS[@]}"; do
		[[ "$scp" != explicit ]] || die "growth series do not support --sidecar-scopings explicit (use none, namespace and/or wide)"
	done
	for tc in "${TRAFFIC_CONFIGS[@]}"; do
		[[ "$tc" == none ]] || die "growth series do not support --traffic-configs vsdr"
	done
	[[ "$VSDR_APPLY" == together ]] || die "--vsdr-apply split is for the legacy sweep (growth series have no VS/DR)"
	((${#REPLICA_COUNTS[@]} == 1)) || die "growth series take one --replica-counts value (got: ${REPLICA_COUNTS_CSV})"
	# The ladder of N runs ascending (in place, each step adds namespaces).
	_sorted_ns="$(printf '%s\n' "${NAMESPACE_COUNTS[@]}" | sort -n -u | awk '{ printf "%s%s", (NR > 1 ? "," : ""), $0 }')"
	if [[ "$_sorted_ns" != "$(IFS=,; echo "${NAMESPACE_COUNTS[*]}")" ]]; then
		echo "note: growth series run --namespace-counts ascending without repeats: ${_sorted_ns}" >&2
	fi
	split_csv "$_sorted_ns" NAMESPACE_COUNTS
else
	for sc in "${SERVICE_COUNTS[@]}"; do
		for nc in "${NAMESPACE_COUNTS[@]}"; do
			(( nc <= sc )) || die "namespace-count $nc > service-count $sc; some namespaces would be empty. Reduce --namespace-counts to at most --service-counts."
		done
	done
fi

if ((GROWTH)); then
	# Cells per series: in-place = each step's grow window plus one probe per scoping,
	# each outside phase's window plus its probes, and the M-sweep's probes; fresh =
	# one deploy cell per N x scoping.
	_S=${#SCOPINGS[@]}
	_NN=${#NAMESPACE_COUNTS[@]}
	_NO=${#OUTSIDE_PHASES[@]}
	_NM=$(( ${#M_LIST[@]} - 1 ))
	if [[ "$GROWTH_MODE" == in-place ]]; then
		CELLS_PER_SERIES=$(( _NN * (1 + _S) + _NO * (1 + _S) + _NM * _S ))
		MATRIX_FACTORS="${#MESH_SIZES[@]} mesh × ${#SPNS[@]} K × (${_NN} steps × (1 grow + ${_S} probes) + ${_NO} outside × (1 + ${_S}) + ${_NM} M-sweep × ${_S})"
	else
		CELLS_PER_SERIES=$(( _NN * _S ))
		MATRIX_FACTORS="${#MESH_SIZES[@]} mesh × ${#SPNS[@]} K × ${_NN} N × ${_S} scope (fresh)"
	fi
	MATRIX_SIZE=$(( ${#MESH_SIZES[@]} * ${#SPNS[@]} * CELLS_PER_SERIES ))
else
	MATRIX_SIZE=$(( ${#MESH_SIZES[@]} * ${#SERVICE_COUNTS[@]} * ${#REPLICA_COUNTS[@]} * ${#NAMESPACE_COUNTS[@]} * ${#SCOPINGS[@]} * ${#TRAFFIC_CONFIGS[@]} ))
	MATRIX_FACTORS="${#MESH_SIZES[@]}×${#SERVICE_COUNTS[@]}×${#REPLICA_COUNTS[@]}×${#NAMESPACE_COUNTS[@]}×${#SCOPINGS[@]}×${#TRAFFIC_CONFIGS[@]}"
fi

SCRIPT_DIR="${ROOT}/tests/controlplane"

# Resume reuses the dir + RUN_ID (002 appends to the same TSV); otherwise mint a
# fresh RUN_ID and sweep-<RUN_ID>/ subdir.
if [[ -n "$RESUME_DIR" ]]; then
	((DRY_RUN)) && die "--resume is not valid with --dry-run (nothing to resume in a plan-only run)"
	[[ -d "$RESUME_DIR" ]] || die "--resume: sweep dir not found: $RESUME_DIR"
	OUTPUT_DIR="$RESUME_DIR"
	# Recover RUN_ID from the existing TSV (controlplane-<RUN_ID>.tsv); fall back to
	# the sweep-<RUN_ID> dir name. RUN_ID must match so 002 appends to the same TSV
	# and the report/envelope filenames line up with the originals.
	_existing_tsv="$(find "$OUTPUT_DIR" -maxdepth 1 -name 'controlplane-*.tsv' -type f 2>/dev/null | sort | head -1)"
	if [[ -n "$_existing_tsv" ]]; then
		RUN_ID="$(basename "$_existing_tsv")"; RUN_ID="${RUN_ID#controlplane-}"; RUN_ID="${RUN_ID%.tsv}"
	else
		RUN_ID="$(basename "$OUTPUT_DIR")"; RUN_ID="${RUN_ID#sweep-}"
	fi
	[[ -n "$RUN_ID" ]] || die "--resume: could not recover RUN_ID from $RESUME_DIR (no controlplane-*.tsv and dir is not sweep-<RUN_ID>)"
	echo "Resuming sweep RUN_ID=${RUN_ID} in ${OUTPUT_DIR} (completed combos will be skipped)" >&2
else
	RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
	OUTPUT_DIR="${OUTPUT_DIR_BASE}/sweep-${RUN_ID}"
fi

# combo_already_done <mesh> <svc> <rep> <ns> <scope> <traffic>: true if the resume TSV
# has a valid row for that key (same gate as the report's n_valid, so failed rows
# re-run). traffic_config is found by header name; --resume only accepts a TSV of
# this harness's width (checked below), which has it. The VS/DR scalars are not part
# of the key: --resume pins them to the preamble's values (below).
combo_already_done() {
	[[ -n "$RESUME_DIR" ]] || return 1
	local tsv="${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv"
	[[ -f "$tsv" ]] || return 1
	awk -F'\t' -v ms="$1" -v sc="$2" -v rc="$3" -v nc="$4" -v scp="$5" -v tc="$6" -v wk="$LEGACY_WINDOW_KIND" '
		/^timestamp\t/ { tcol = 0; wcol = 0; for (i = 1; i <= NF; i++) { if ($i == "traffic_config") tcol = i; if ($i == "window_kind") wcol = i }; next }
		!/^#/ && NF>=40 && $31=="0" \
			&& $3==ms && $4==sc && $5==rc && $6==nc && $7==scp \
			&& ((tcol && NF >= tcol) ? $tcol : "none") == tc \
			&& ((wcol && NF >= wcol) ? $wcol : "deploy") == wk { found=1; exit }
		END { exit (found ? 0 : 1) }' "$tsv"
}

# The 66-column TSV schema header. 002 writes the same literal when it runs
# standalone; tests/lib/test/preamble.bats checks that the two are identical.
CONTROLPLANE_TSV_HEADER="timestamp\tcontext\tmesh_size\tservice_count\treplicas\tnamespace_count\tsidecar_scoping\tistiod_mem_mi\tconvergence_p50_ms\tconvergence_p99_ms\tqueue_p50_ms\tqueue_p99_ms\txds_pushes_delta\txds_pushes_rate\txds_pushes_cds\txds_pushes_eds\txds_pushes_lds\txds_pushes_rds\txds_pushes_nds\tk8s_events_delta\tk8s_events_rate\tconnected_proxies\tconfig_size_avg_bytes\tsidecar_config_bytes_avg\tsidecar_config_bytes_p50\tsidecar_config_bytes_max\tsidecar_config_bytes_samples\tscrape_window_sec\tscrape_skew_ms\tsettle_sec\tistiod_restarted\tistiod_cpu_m_delta\tgo_heap_alloc_mi\tgo_heap_inuse_mi\tistiod_cpu_pct_of_limit\tistiod_mem_pct_of_limit\tnode_cpu_pct\tnode_mem_pct\tpods_scheduled\tpods_allocatable\tcluster_connected_proxies\tsidecar_pods\tproxy_check\ttraffic_config\tvsdr_services\tistiod_virt_services\tpush_time_avg_ms\tpushcontext_init_avg_ms\tsidecar_clusters_avg\tsidecar_cds_bytes_avg\tsidecar_rds_bytes_avg\tservices_per_namespace\tworkload_mode\tmeasurement_pods\toutside_namespaces\toutside_discovery\twindow_kind\tistiod_services\tistiod_cpu_s_delta\tsidecar_mem_mi_avg\tgateway_clusters_max\tgateway_mem_mi_max\troot_cert_configmaps\tgateway_physical_mi_max\tgateway_ws_mi_max\tleftover_test_namespaces"
CONTROLPLANE_TSV_WIDTH="$(echo -e "$CONTROLPLANE_TSV_HEADER" | awk -F'\t' '{ print NF }')"

# --resume appends to the existing TSV, so its header must have this harness's width;
# otherwise the file would mix row widths. Start a new sweep across a schema change.
if [[ -n "$RESUME_DIR" ]]; then
	_resume_tsv="${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv"
	if [[ -f "$_resume_tsv" ]]; then
		_resume_width="$(grep -m1 '^timestamp' "$_resume_tsv" | awk -F'\t' '{ print NF }')" || _resume_width=""
		if [[ -n "$_resume_width" && "$_resume_width" != "$CONTROLPLANE_TSV_WIDTH" ]]; then
			die "--resume: $_resume_tsv has a ${_resume_width}-column header, but this harness writes ${CONTROLPLANE_TSV_WIDTH} columns. Start a new sweep instead of resuming across a schema change."
		fi
		# Sweep-level scalars live only in the preamble (pre-create skips an existing
		# one), so the resumed rows must use the recorded values; the report reads them
		# for every row. The VS/DR pair matters only when this run has vsdr cells.
		if [[ -n "$_resume_width" ]]; then
			resume_preamble_scalar "$_resume_tsv" PROXY_CHECK_TOLERANCE_PCT PROXY_CHECK_TOL_PCT CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT 0
			resume_preamble_scalar "$_resume_tsv" PROXY_CHECK_MIN_DIFF PROXY_CHECK_MIN_DIFF CONTROLPLANE_PROXY_CHECK_MIN_DIFF 0
			is_nonneg_int "$PROXY_CHECK_TOL_PCT" || die "--resume: PROXY_CHECK_TOLERANCE_PCT in $_resume_tsv is not a non-negative integer: $PROXY_CHECK_TOL_PCT"
			is_nonneg_int "$PROXY_CHECK_MIN_DIFF" || die "--resume: PROXY_CHECK_MIN_DIFF in $_resume_tsv is not a non-negative integer: $PROXY_CHECK_MIN_DIFF"
			# 002 reads these from the environment.
			export CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT="$PROXY_CHECK_TOL_PCT"
			export CONTROLPLANE_PROXY_CHECK_MIN_DIFF="$PROXY_CHECK_MIN_DIFF"
			if grep -q '^# VSDR_APPLY=' "$_resume_tsv"; then
				resume_preamble_scalar "$_resume_tsv" VSDR_APPLY VSDR_APPLY --vsdr-apply "$VSDR_APPLY_FLAG"
				LEGACY_WINDOW_KIND=deploy
				[[ "$VSDR_APPLY" == split ]] && LEGACY_WINDOW_KIND=traffic
			fi
			if ((HAS_VSDR)); then
				resume_preamble_scalar "$_resume_tsv" VSDR_EVERY VSDR_EVERY --vsdr-every "$VSDR_EVERY_FLAG"
				resume_preamble_scalar "$_resume_tsv" VSDR_SUBSETS VSDR_SUBSETS --vsdr-subsets "$VSDR_SUBSETS_FLAG"
				is_pos_int "$VSDR_EVERY" || die "--resume: VSDR_EVERY in $_resume_tsv is not a positive integer: $VSDR_EVERY"
				is_pos_int "$VSDR_SUBSETS" || die "--resume: VSDR_SUBSETS in $_resume_tsv is not a positive integer: $VSDR_SUBSETS"
			fi
		fi
	fi
fi

# --resume keeps the TSV preamble the sweep started with, RUN_CONFIG* included, so the
# new rows must come from that config. A sweep that started with --config resumes only
# with the same file (same sha256): without --config the axes would fall back to
# env/defaults, and another file would build a different matrix, either way appended
# under the recorded RUN_CONFIG. The preamble decides; the snapshot (best effort) only
# counts for a sweep whose TSV has no preamble yet. A sweep that started without one
# (RUN_CONFIG=none) still resumes with any --config, with a warning.
if [[ -n "$RESUME_DIR" ]]; then
	_resume_snapshot="${OUTPUT_DIR}/run-config-${RUN_ID}.env"
	_resume_cfg="" _resume_sha="" _resume_with_cfg=0
	if [[ -f "$_resume_tsv" ]]; then
		_resume_cfg="$(awk -v k="# RUN_CONFIG=" '/^timestamp\t/ { exit } index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$_resume_tsv")"
		_resume_sha="$(awk -v k="# RUN_CONFIG_SHA256=" '/^timestamp\t/ { exit } index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$_resume_tsv")"
	fi
	if [[ -n "$_resume_cfg" && "$_resume_cfg" != none ]]; then
		_resume_with_cfg=1
	elif [[ -z "$_resume_cfg" && -f "$_resume_snapshot" ]]; then
		_resume_with_cfg=1
		_resume_cfg="$(basename "$_resume_snapshot")"
		_resume_sha="$(_config_sha256 "$_resume_snapshot")"
	fi
	_resume_hint=""
	if [[ -f "$_resume_snapshot" ]]; then
		_resume_hint=" To resume with the same values, add --config $(printf '%q' "$_resume_snapshot"):
  $(printf '%q' "$0") --resume $(printf '%q' "$RESUME_DIR") --config $(printf '%q' "$_resume_snapshot")"
	fi
	if ((_resume_with_cfg)) && [[ "${RUN_CONFIG:-none}" == none ]]; then
		[[ -f "$_resume_snapshot" ]] && die "--resume: this sweep was started with --config ${_resume_cfg}; without it the axes and settings fall back to the environment and defaults, and the new rows would not match the recorded RUN_CONFIG.${_resume_hint}"
		die "--resume: this sweep was started with --config ${_resume_cfg} (RUN_CONFIG_SHA256=${_resume_sha:-not recorded}), and its snapshot ${_resume_snapshot} is missing. Pass --config with that file (the sha256 must match), or start a new sweep."
	elif ((_resume_with_cfg)) && [[ "$_resume_sha" != "${RUN_CONFIG_SHA256:-none}" ]]; then
		die "--resume: --config ${RUN_CONFIG} (sha256 ${RUN_CONFIG_SHA256:0:12}) is not the config this sweep started with (${_resume_cfg}, RUN_CONFIG_SHA256=${_resume_sha:-not recorded}); its rows would be credited to a config that did not produce them. Pass the original file, or start a new sweep.${_resume_hint}"
	elif ((!_resume_with_cfg)) && [[ "${RUN_CONFIG:-none}" != none ]]; then
		echo "warning: --resume: --config ${RUN_CONFIG} (sha256 ${RUN_CONFIG_SHA256:0:12}) is not the config this sweep started with (RUN_CONFIG_SHA256=${_resume_sha:-not recorded}). The TSV keeps the original provenance, and values recorded only in its preamble (SETTLE_SEC, CONFIG_DUMP_SAMPLES, ...) may not match the new rows." >&2
	fi
fi

# Each DestinationRule subset needs at least one pod, at every replica count in the
# sweep. Checked after --resume, which can adopt the recorded --vsdr-subsets.
if ((HAS_VSDR)); then
	for rc in "${REPLICA_COUNTS[@]}"; do
		(( VSDR_SUBSETS <= rc )) || die "--vsdr-subsets $VSDR_SUBSETS > replica-count $rc: each DestinationRule subset needs at least one pod. Lower --vsdr-subsets or drop replica counts below it."
	done
fi

# Pre-create controlplane-${RUN_ID}.tsv with the full preamble before the first
# combo, so provenance survives a first-combo failure; 002 and the failed-row
# emitter only append.
precreate_tsv_preamble() {
	local tsv="${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv"
	[[ -f "$tsv" ]] && grep -q '^timestamp' "$tsv" 2>/dev/null && return 0
	mkdir -p "$OUTPUT_DIR"
	local harness kver
	harness="$(harness_sha)"
	kver="$(probe_kube_versions "$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}")"
	# Capacity provenance (read-only, source context; `unknown` on failure). These
	# are the report's denominators for the "Achieved scale vs capacity" block.
	local src_ctx="${CONTEXTS[0]}"
	local node_alloc_cpu_m="unknown" node_alloc_mem_mi="unknown"
	local istiod_cpu_limit_m="unknown" istiod_mem_limit_mi="unknown"
	local kv
	# shellcheck disable=SC2207
	local -a nt_kv=($(cap_node_totals "$src_ctx" "${KUBECTL[@]}"))
	for kv in "${nt_kv[@]}"; do
		case "$kv" in
			cpu_m=*) node_alloc_cpu_m="${kv#cpu_m=}" ;;
			mem_mi=*) node_alloc_mem_mi="${kv#mem_mi=}" ;;
		esac
	done
	# shellcheck disable=SC2207
	local -a il_kv=($(cap_istiod_limits "$src_ctx" "${KUBECTL[@]}"))
	for kv in "${il_kv[@]}"; do
		case "$kv" in
			cpu_m=*) istiod_cpu_limit_m="${kv#cpu_m=}" ;;
			mem_mi=*) istiod_mem_limit_mi="${kv#mem_mi=}" ;;
		esac
	done
	# Cluster-infra block via the shared emitter (same key set as 002's standalone preamble).
	local infra_kv
	infra_kv="$(env_collect_infra "$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}")"
	# Live tuning-baseline state from the source cluster (sweep-wide scalar).
	local tb_line="TUNING_BASELINE=unknown" eh_line="SIDECAR_EGRESS_HOSTS=unknown"
	local tb_kv
	while IFS= read -r tb_kv; do
		case "$tb_kv" in
			TUNING_BASELINE=*) tb_line="$tb_kv" ;;
			SIDECAR_EGRESS_HOSTS=*) eh_line="$tb_kv" ;;
		esac
	done < <(tuning_baseline_state "$src_ctx" "${KUBECTL[@]}")
	{
		echo "# Control-plane resource metrics — $(date -u -Iseconds)"
		echo "# CONTROLPLANE_SCHEMA=66"
		echo "# CONTROLPLANE_INFRA_SCHEMA=2"
		istio_version_kv | sed 's/^/# /'
		echo "# HARNESS_SHA=${harness}"
		echo "# KUBE_VERSIONS=${kver}"
		echo "# SETTLE_SEC=${SETTLE_SEC}"
		echo "# RUN_ID=${RUN_ID}"
		echo "# PHASE=sweep"
		echo "# SIDECAR_SCOPING=${SIDECAR_SCOPINGS_CSV}"
		echo "# CONFIG_DUMP_SAMPLES=${CONFIG_DUMP_SAMPLES}"
		echo "# NODE_ALLOC_CPU_M=${node_alloc_cpu_m}"
		echo "# NODE_ALLOC_MEM_MI=${node_alloc_mem_mi}"
		echo "# ISTIOD_CPU_LIMIT_M=${istiod_cpu_limit_m}"
		echo "# ISTIOD_MEM_LIMIT_MI=${istiod_mem_limit_mi}"
		echo "# SCALE_TARGET_FRACTION=${SCALE_TARGET_FRACTION:-unknown}"
		echo "# SCALE_SIZING_MODE=${SCALE_SIZING_MODE:-unknown}"
		echo "# PROXY_CHECK_TOLERANCE_PCT=${PROXY_CHECK_TOL_PCT}"
		echo "# PROXY_CHECK_MIN_DIFF=${PROXY_CHECK_MIN_DIFF}"
		echo "# TRAFFIC_CONFIG=${TRAFFIC_CONFIGS_CSV}"
		echo "# VSDR_EVERY=${VSDR_EVERY}"
		echo "# VSDR_SUBSETS=${VSDR_SUBSETS}"
		echo "# VSDR_APPLY=${VSDR_APPLY}"
		config_preamble_lines
		# Namespace-scaling keys through the emitter 002 uses too (PL36). A legacy sweep
		# records GROWTH_MODE=off.
		local growth_mode_key="off"
		((GROWTH)) && growth_mode_key="$GROWTH_MODE"
		growth_preamble_lines SERVICES_PER_NAMESPACE="$SPN_CSV" GROWTH_MODE="$growth_mode_key" \
			WORKLOAD_MODE="$WORKLOAD_MODE" MEASUREMENT_PODS="$MEASUREMENT_POD_COUNTS_CSV" \
			MEASUREMENT_PROXY_MEM_LIMIT="${CONTROLPLANE_MEASUREMENT_PROXY_MEM_LIMIT:-unknown}" \
			OUTSIDE_NAMESPACES="$OUTSIDE_NAMESPACES" OUTSIDE_MODES="$OUTSIDE_MODES_CSV" \
			PROBE_SETTLE_SEC="$PROBE_SETTLE_SEC" MEM_STOP_PCT="$MEM_STOP_PCT" \
			MEM_GUARD_CONTEXTS="$(IFS=,; echo "${GUARD_CONTEXTS[*]:-}")" SERIES_RETIRE="$SERIES_RETIRE" \
			DISCOVERY_LABEL=istio-discovery=enabled LEFTOVER_TEST_NAMESPACES="$LEFTOVER_AT_START" \
			LEFTOVER_NS_WARN="$LEFTOVER_NS_WARN"
		echo "# ${tb_line}"
		echo "# ${eh_line}"
		echo "# METRICS_API=${METRICS_API_STATUS:-unknown}"
		# shellcheck disable=SC2086
		infra_preamble_lines $infra_kv
		echo "# NOTE=preamble pre-created by 003-run-sweep.sh so provenance survives a first-combo setup/baseline failure"
		echo "# Contexts: ${CONTEXTS[*]}  Mesh sizes: ${MESH_SIZES[*]}  Services: ${SERVICE_COUNTS_CSV}  Replicas: ${REPLICA_COUNTS_CSV}  Namespaces: ${NAMESPACE_COUNTS_CSV}  Scopings: ${SIDECAR_SCOPINGS_CSV}  Traffic: ${TRAFFIC_CONFIGS_CSV}"
	} > "$tsv"
	echo -e "$CONTROLPLANE_TSV_HEADER" >> "$tsv"
}

# Plan-time capacity warning: compare the largest combo's sidecar CPU request
# (pods x the per-pod request) with the free node CPU of the tightest measured member
# (allocatable minus what other pods already request). The per-pod
# request is SCALE_PER_POD_CPU_M when set, else the live Istio CR's sidecar request
# (the test pods' app containers request nothing; BACKLOG 9.7), else Istio's 100m.
# Warn only; 001's preflight is the hard gate. Dry-run prints only the requested cores
# (no cluster contact).
capacity_plan_warn() {
	local ppr per_pod_cpu_m per_pod_src live
	if ((DRY_RUN)) || ! ((${#KUBECTL[@]})); then
		ppr="$(cap_per_pod_requests "" "${SCALE_PER_POD_CPU_M:-}" "${SCALE_PER_POD_MEM_MI:-}")"
	else
		ppr="$(cap_per_pod_requests "${CONTEXTS[0]}" "${SCALE_PER_POD_CPU_M:-}" "${SCALE_PER_POD_MEM_MI:-}" "${KUBECTL[@]}")"
	fi
	per_pod_cpu_m="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^cpu_m=/) print substr($i, 7) }' <<<"$ppr")"
	per_pod_src="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^cpu_src=/) print substr($i, 9) }' <<<"$ppr" | tr '_' ' ')"
	live="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^live=/) print substr($i, 6) }' <<<"$ppr")"
	if [[ -n "${SCALE_PER_POD_CPU_M:-}" && "$live" != none && "${live%%/*}" != "$per_pod_cpu_m" ]]; then
		per_pod_src="${per_pod_src}; the live Istio CR requests ${live%%/*}m, SCALE_PER_POD_CPU_M wins"
	fi
	# Largest combo: max service_count × max replica_count.
	local max_sc=0 max_rc=0 v
	for v in "${SERVICE_COUNTS[@]}"; do (( v > max_sc )) && max_sc="$v"; done
	for v in "${REPLICA_COUNTS[@]}"; do (( v > max_rc )) && max_rc="$v"; done
	local needed_pods=$(( max_sc * max_rc )) combo_label="${max_sc} svc × ${max_rc} rep"
	if ((GROWTH)); then
		# Growth series: pods mode runs every Service's pods at the largest step;
		# config-only runs only the measurement pods.
		local max_n=0 max_k=0 max_m="${M_LIST[${#M_LIST[@]}-1]}"
		for v in "${NAMESPACE_COUNTS[@]}"; do (( v > max_n )) && max_n="$v"; done
		for v in "${SPNS[@]}"; do (( v > max_k )) && max_k="$v"; done
		if [[ "$WORKLOAD_MODE" == config-only ]]; then
			needed_pods=$(( max_m < max_n ? max_m : max_n ))
			combo_label="config-only: ${needed_pods} measurement pods"
		else
			needed_pods=$(( max_n * max_k * max_rc ))
			combo_label="growth: ${max_n} namespaces × ${max_k} svc × ${max_rc} rep"
		fi
		max_sc=$(( max_n * max_k ))
	fi
	local needed_cpu_m=$(( needed_pods * per_pod_cpu_m ))
	echo "--- Capacity plan check (largest combo: ${combo_label}) ---" >&2
	echo "  requested: ${needed_pods} sidecar-pods × ${per_pod_cpu_m}m = ~$(awk -v m="$needed_cpu_m" 'BEGIN { printf "%.1f", m / 1000 }') cores/cluster (per pod: ${per_pod_src})" >&2

	if ((DRY_RUN)); then
		echo "  WARN: dry-run does not contact clusters; free-capacity comparison skipped. Run without --dry-run for the services-that-fit estimate." >&2
		echo "" >&2
		return 0
	fi
	(( ${#KUBECTL[@]} )) || { echo "  WARN: no oc/kubectl; cannot read node capacity for the fit estimate." >&2; echo "" >&2; return 0; }

	# cores <millicores>: one decimal (a few small pods must not read as "~0 cores").
	cores() { awk -v m="$1" 'BEGIN { printf "%.1f", m / 1000 }'; }
	# Free CPU per measured member = worker allocatable − the CPU other pods already
	# request (what the scheduler sees: OpenShift, istiod, gateways, monitoring). The
	# test's own pods are left out: needed_pods already counts the whole largest combo.
	# The tightest member decides. When the pod list is unreadable, fall back to
	# allocatable − istiod's limit × replicas, which overstates the free CPU.
	local ctx kv alloc_cpu_m workers req_cpu_m istiod_cpu_m istiod_rep free_cpu_m min_free="" min_ctx=""
	local -A seen=()
	for ctx in "${CONTEXTS[@]}"; do
		[[ -n "${seen[$ctx]:-}" ]] && continue
		seen[$ctx]=1
		alloc_cpu_m="" workers="" req_cpu_m="" istiod_cpu_m="" istiod_rep=""
		# shellcheck disable=SC2207
		local -a nt=($(cap_node_totals "$ctx" "${KUBECTL[@]}"))
		for kv in "${nt[@]}"; do
			case "$kv" in
				cpu_m=*) alloc_cpu_m="${kv#cpu_m=}" ;;
				names=*) workers="${kv#names=}" ;;
			esac
		done
		if ! [[ "$alloc_cpu_m" =~ ^[0-9]+$ ]]; then
			echo "  $ctx: WARN: node allocatable CPU unreadable; left out of the fit estimate." >&2
			continue
		fi
		# shellcheck disable=SC2207
		local -a rq=($(cap_requested "$ctx" "$workers" "app.kubernetes.io/instance=controlplane-test" "${KUBECTL[@]}"))
		for kv in "${rq[@]}"; do case "$kv" in cpu_m=*) req_cpu_m="${kv#cpu_m=}" ;; esac; done
		if [[ "$req_cpu_m" =~ ^[0-9]+$ ]]; then
			free_cpu_m=$(( alloc_cpu_m - req_cpu_m ))
			(( free_cpu_m < 0 )) && free_cpu_m=0
			echo "  $ctx: node alloc CPU ~$(cores "$alloc_cpu_m") cores; requested by other pods ~$(cores "$req_cpu_m") -> ~$(cores "$free_cpu_m") cores free" >&2
		else
			# shellcheck disable=SC2207
			local -a il=($(cap_istiod_limits "$ctx" "${KUBECTL[@]}"))
			for kv in "${il[@]}"; do
				case "$kv" in
					cpu_m=*) istiod_cpu_m="${kv#cpu_m=}" ;;
					replicas=*) istiod_rep="${kv#replicas=}" ;;
				esac
			done
			local istiod_baseline_m=0
			if [[ "$istiod_cpu_m" =~ ^[0-9]+$ && "$istiod_rep" =~ ^[0-9]+$ ]]; then
				istiod_baseline_m=$(( istiod_cpu_m * istiod_rep ))
			fi
			free_cpu_m=$(( alloc_cpu_m - istiod_baseline_m ))
			(( free_cpu_m < 0 )) && free_cpu_m=0
			echo "  $ctx: node alloc CPU ~$(cores "$alloc_cpu_m") cores; pod requests unreadable, istiod baseline ~$(cores "$istiod_baseline_m") cores (${istiod_cpu_m:-unknown}m × ${istiod_rep:-unknown} rep) -> ~$(cores "$free_cpu_m") cores free (an overstatement)" >&2
		fi
		if [[ -z "$min_free" ]] || (( free_cpu_m < min_free )); then
			min_free="$free_cpu_m"
			min_ctx="$ctx"
		fi
	done
	if [[ -z "$min_free" ]]; then
		echo "  WARN: node allocatable CPU unreadable on every context; cannot estimate services-that-fit." >&2
		echo "" >&2
		return 0
	fi
	free_cpu_m="$min_free"
	local max_services=0
	if (( max_rc > 0 && per_pod_cpu_m > 0 )); then
		max_services=$(( free_cpu_m / (max_rc * per_pod_cpu_m) ))
	fi
	# Growth series in config-only mode run only measurement pods: report pods, not services.
	local fit_label="~${max_services} services would fit at ${max_rc} replicas"
	if ((GROWTH)) && [[ "$WORKLOAD_MODE" == config-only ]] && ((per_pod_cpu_m > 0)); then
		fit_label="~$(( free_cpu_m / per_pod_cpu_m )) pods would fit"
	fi
	if (( needed_cpu_m > free_cpu_m )); then
		echo "  WARN: combo needs ~$(cores "$needed_cpu_m") cores/cluster, ~$(cores "$free_cpu_m") free on ${min_ctx} (${fit_label}). Reduce the workload, add nodes, or expect 001 to refuse (or FailedScheduling/SETUP_FAILED on) the largest combo." >&2
	else
		echo "  OK: largest combo fits (~$(cores "$needed_cpu_m") needed <= ~$(cores "$free_cpu_m") free on ${min_ctx}; ${fit_label})." >&2
	fi
	echo "" >&2
}

# Metrics-API readiness gate for the utilization-% columns (kubectl top). Polls
# each context up to METRICS_READY_TIMEOUT, records METRICS_API_STATUS for the
# preamble and warns; never aborts. METRICS_READY_TIMEOUT=0 disables it.
metrics_preflight() {
	local timeout="${METRICS_READY_TIMEOUT:-120}" interval="${METRICS_READY_INTERVAL:-10}"
	if (( timeout <= 0 )); then
		echo "Metrics-API preflight: disabled (METRICS_READY_TIMEOUT=0)." >&2
		METRICS_API_STATUS="unknown"
		return 0
	fi
	local deadline=$(( SECONDS + timeout ))
	local -a pending=("${CONTEXTS[@]}")
	echo "Metrics-API preflight: probing 'kubectl top nodes' on ${#pending[@]} context(s) (timeout ${timeout}s)..." >&2
	while :; do
		local -a still=()
		local ctx
		for ctx in "${pending[@]}"; do
			[[ "$(cap_metrics_ready "$ctx" "${KUBECTL[@]}")" == ready ]] || still+=("$ctx")
		done
		pending=("${still[@]}")
		(( ${#pending[@]} == 0 )) && break
		(( SECONDS >= deadline )) && break
		echo "  metrics not ready on ${#pending[@]} context(s): ${pending[*]}; retrying in ${interval}s..." >&2
		sleep "$interval"
	done
	if (( ${#pending[@]} == 0 )); then
		METRICS_API_STATUS="available"
		echo "  metrics API available on all contexts." >&2
	else
		local csv; csv=$(IFS=,; echo "${pending[*]}")
		METRICS_API_STATUS="unavailable:${csv}"
		echo "  WARN: metrics API unavailable on ${csv} after ${timeout}s." >&2
		echo "  WARN: utilization-% columns (istiod_*_pct_of_limit, node_*_pct) will be N/A for combos on those contexts;" >&2
		echo "  WARN: the run PROCEEDS (utilization is observability) — verify metrics-server and re-run if you need utilization-%." >&2
	fi
}

# Record a failed combo as a degraded row (context column = status, restarted =
# unknown, numerics N/A): counted in n_total, excluded from n_valid. The sweep
# continues. <status> is PROBE_FAILED or SETUP_FAILED; growth series also record
# GROW_FAILED, SWITCH_FAILED, SKIPPED_MEM_GUARD, SKIPPED_SERIES_STOPPED and
# RETIRE_FAILED (window_kind retire; the sweep stops after it).
# Optional args 8-13 are the growth columns 52-57 (services_per_namespace,
# workload_mode, measurement_pods, outside_namespaces, outside_discovery,
# window_kind); a legacy cell defaults to 0 pods <svc x replicas> 0 none deploy.
emit_failed_row() {
	local status="$1" ms="$2" sc="$3" rc="$4" nc="$5" scp="$6" tc="$7"
	local g_spn="${8:-0}" g_wm="${9:-pods}" g_mp="${10:-$(( $3 * $4 ))}" g_ox="${11:-0}" g_od="${12:-none}" g_wk="${13:-deploy}"
	local tsv="${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv"
	# Configured VS+DR services for the cell (0 for none), like service_count.
	local vsdr_svcs=0
	[[ "$tc" == vsdr ]] && vsdr_svcs="$(vsdr_service_count "$sc" "$VSDR_EVERY")"
	# Defensive: ensure header exists (pre-create runs before the loop, but keep this
	# idempotent guard so a row is never written into a header-less file).
	if ! grep -q '^timestamp' "$tsv" 2>/dev/null; then
		precreate_tsv_preamble
	fi
	# 66 fields: cols 41-43 (cluster proxies, sidecar pods, proxy check) are N/A too;
	# cols 44-45 keep the cell's traffic config, cols 46-51 are N/A; cols 52-57 keep
	# the cell's growth metadata, cols 58-66 are N/A.
	echo -e "$(date -u -Iseconds)\t${status}\t${ms}\t${sc}\t${rc}\t${nc}\t${scp}\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t${SETTLE_SEC}\tunknown\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t${tc}\t${vsdr_svcs}\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t${g_spn}\t${g_wm}\t${g_mp}\t${g_ox}\t${g_od}\t${g_wk}\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A" >> "$tsv"
}

# Growth memory guard contexts: every member whose istiod and gateways ingest the
# series' Services through remote discovery (PL38), not only the measured ones.
GUARD_CONTEXTS=()
if ((GROWTH)); then
	if [[ -n "$MEM_GUARD_CONTEXTS_CSV" ]]; then
		split_csv "$MEM_GUARD_CONTEXTS_CSV" GUARD_CONTEXTS
	else
		_setup_ctxs=()
		split_csv "${SETUP_CONTEXTS:-}" _setup_ctxs
		declare -A _gseen=()
		for _c in "${CONTEXTS[@]}" "${_setup_ctxs[@]}"; do
			[[ -n "${_gseen[$_c]:-}" ]] && continue
			_gseen[$_c]=1
			GUARD_CONTEXTS+=("$_c")
		done
		unset _gseen
	fi
fi
# guard_add_mesh_members: in a live growth sweep, add every mesh member the measured
# contexts' Istio remote secrets name (BACKLOG 9.6: without --config the guard sampled
# only --contexts + SETUP_CONTEXTS and missed the third member). Context names equal
# cluster names in the repo's kubeconfigs. A member with no kube context of its name
# stops the sweep (an unguarded member could OOM mid-series) unless
# --mem-guard-contexts was given, which only warns.
guard_add_mesh_members() {
	((GROWTH && !DRY_RUN && MEM_STOP_PCT > 0)) || return 0
	((${#KUBECTL[@]})) || return 0
	local -A have=() known=()
	local c m members
	local -a missing=() new_members=()
	for c in "${GUARD_CONTEXTS[@]}"; do have[$c]=1; done
	while IFS= read -r c; do [[ -n "$c" ]] && known[$c]=1; done < <("${KUBECTL[@]}" config get-contexts -o name 2>/dev/null)
	for c in "${CONTEXTS[@]:0:${MAX_MESH_SIZE}}"; do
		if ! members="$(growth_mesh_members "$c" "${KUBECTL[@]}")"; then
			echo "warn: memory guard: cannot list the Istio remote secrets on ${c}; the guard samples ${GUARD_CONTEXTS[*]}" >&2
			continue
		fi
		while IFS= read -r m; do
			[[ -n "$m" && -z "${have[$m]:-}" ]] || continue
			have[$m]=1
			if [[ -n "$MEM_GUARD_CONTEXTS_CSV" ]]; then missing+=("$m")
			elif [[ -n "${known[$m]:-}" ]]; then GUARD_CONTEXTS+=("$m"); new_members+=("$m")
			else missing+=("$m")
			fi
		done <<<"$members"
	done
	((${#new_members[@]} == 0)) || echo "Memory guard: added mesh member(s) ${new_members[*]} (named by the remote secrets); samples ${GUARD_CONTEXTS[*]}"
	((${#missing[@]})) || return 0
	if [[ -n "$MEM_GUARD_CONTEXTS_CSV" ]]; then
		echo "WARNING: memory guard: mesh member(s) ${missing[*]} ingest the series' Services but are not in --mem-guard-contexts (${MEM_GUARD_CONTEXTS_CSV}); their istiod and gateways are not guarded unless a context of another name covers them." >&2
		return 0
	fi
	die "memory guard: mesh member(s) ${missing[*]} (named by the Istio remote secrets) have no kube context of that name, so their istiod and gateways could not be guarded. Pass --mem-guard-contexts with a context for every member (or the subset you accept), or set MEM_STOP_PCT 0 to run unguarded."
}

# leftover_preflight: before a live growth sweep, count the controlplane-test namespaces
# on every measured context (BACKLOG 9.10: thousands of undiscovered leftovers stayed in
# istiod's informers and inflated later series). A discovered one stops the sweep (it
# would add its Services to every cell); undiscovered ones above
# CONTROLPLANE_LEFTOVER_NS_WARN warn. LEFTOVER_AT_START (<ctx>=<total>/<discovered>,...)
# goes into the preamble.
LEFTOVER_AT_START="n/a"
leftover_preflight() {
	((GROWTH && !DRY_RUN)) || return 0
	((${#KUBECTL[@]})) || return 0
	local c kv total disc out="" bad=""
	for c in "${CONTEXTS[@]:0:${MAX_MESH_SIZE}}"; do
		kv="$(growth_test_ns_counts "$c" "${KUBECTL[@]}")"
		total="$(_growth_kv total "$kv")"
		disc="$(_growth_kv discovered "$kv")"
		out="${out:+${out},}${c}=${total}/${disc}"
		if [[ "$disc" =~ ^[0-9]+$ ]] && ((disc > 0)); then
			bad="${bad:+${bad}; }${c}: ${disc} discovered"
		elif [[ "$total" =~ ^[0-9]+$ ]] && ((total > LEFTOVER_NS_WARN)); then
			echo "WARNING: ${c} holds ${total} undiscovered controlplane-test namespaces from earlier runs. They stay in istiod's informers, so this sweep's absolute istiod figures (heap, RSS) are inflated; deltas within a series stay valid. Delete them for clean numbers: ${SCRIPT_DIR}/005-cleanup.sh --contexts ${c} --timeout <about 1 s per namespace>." >&2
		elif ! [[ "$total" =~ ^[0-9]+$ ]]; then
			echo "warn: could not count the controlplane-test namespaces on ${c}" >&2
		fi
	done
	LEFTOVER_AT_START="$out"
	[[ -z "$bad" ]] || die "controlplane-test namespaces of an earlier run are still discovered (${bad}); every cell would include their Services. Retire them first: ${SCRIPT_DIR}/005-cleanup.sh --contexts <ctx> --undiscover --no-delete (all series), then start the sweep again."
}

# Series ids: unique per run (namespaces of an earlier run may still exist,
# undiscovered or Terminating), DNS-safe: s<MMDDhhmmss>-<n>.
SERIES_PREFIX="s${RUN_ID:4:4}${RUN_ID:9:6}"
LIFECYCLE_FILE="${OUTPUT_DIR}/ns-lifecycle-${RUN_ID}.tsv"
GUARD_FILE="${OUTPUT_DIR}/mem-guard-${RUN_ID}.tsv"

{
	echo "=========================================="
	echo "  Control-Plane Resource Sweep"
	echo "=========================================="
	echo "Contexts:          ${CONTEXTS[*]}"
	echo "Mesh sizes:        ${MESH_SIZES[*]}"
	if ((GROWTH)); then
		echo "Growth series:     K=${SPNS[*]} services per namespace, ${GROWTH_MODE}, workload ${WORKLOAD_MODE}"
		echo "Namespace counts:  ${NAMESPACE_COUNTS[*]} (ascending ladder)"
		[[ "$WORKLOAD_MODE" == config-only ]] && echo "Measurement pods:  ${M_LIST[*]} (first = base$( ((${#M_LIST[@]} > 1)) && echo '; the rest = M-sweep at the largest N'))"
		echo "Replicas:          ${REPLICA_COUNTS[*]}$([[ "$WORKLOAD_MODE" == config-only ]] && echo ' (pods mode only; measurement pods run 1)')"
		echo "Outside:           ${OUTSIDE_NAMESPACES} namespace(s), phases: ${OUTSIDE_PHASES[*]:-none}"
		echo "Probe settle:      ${PROBE_SETTLE_SEC}s"
		echo "Memory guard:      stop at ${MEM_STOP_PCT}% of the istiod / gateway memory limit$( ((MEM_STOP_PCT == 0)) && echo ' (disabled)'); samples ${GUARD_CONTEXTS[*]}"
		echo "Series retire:     ${SERIES_RETIRE}"
	else
		echo "Service counts:    ${SERVICE_COUNTS[*]}"
		echo "Replica counts:    ${REPLICA_COUNTS[*]}"
		echo "Namespace counts:  ${NAMESPACE_COUNTS[*]}"
	fi
	echo "Sidecar scopings:  ${SCOPINGS[*]}"
	echo "Traffic configs:   ${TRAFFIC_CONFIGS[*]}  (vsdr: every ${VSDR_EVERY}, ${VSDR_SUBSETS} subsets; apply ${VSDR_APPLY}$([[ "$VSDR_APPLY" == split ]] && echo ': workloads before the baseline, the window measures the VS/DR apply only'))"
	echo "Config-dump samples: ${CONFIG_DUMP_SAMPLES}"
	echo "Settle time:       ${SETTLE_SEC}s"
	echo "Run ID:            ${RUN_ID}"
	echo "Output:            ${OUTPUT_DIR}"
	if [[ "${RUN_CONFIG:-none}" != none ]]; then
		echo "Run config:        ${RUN_CONFIG} (sha256 ${RUN_CONFIG_SHA256:0:12})"
	fi
	echo ""
	if ((GROWTH)); then
		echo "Planned matrix:    ${MATRIX_SIZE} cells = ${MATRIX_FACTORS}"
	else
		echo "Planned matrix:    ${MATRIX_SIZE} = ${MATRIX_FACTORS} (mesh × svc × rep × ns × scope × traffic)"
	fi
	echo ""
} >&2

if ((MATRIX_SIZE > MAX_MATRIX)) && ! ((FORCE_LARGE_MATRIX)); then
	if ((GROWTH)); then
		die "growth plan has $MATRIX_SIZE cells = ${MATRIX_FACTORS}, above the safety limit $MAX_MATRIX; re-run with --force-large-matrix to proceed"
	fi
	die "matrix size $MATRIX_SIZE = ${MATRIX_FACTORS} (mesh × svc × rep × ns × scope × traffic) exceeds safety limit $MAX_MATRIX; re-run with --force-large-matrix to proceed"
fi

# The dry-run plan needs no CLI, so tolerate a missing one here (resolve_kubectl dies).
if command -v kubectl >/dev/null 2>&1; then
	KUBECTL=(kubectl)
elif command -v oc >/dev/null 2>&1; then
	KUBECTL=(oc)
else
	KUBECTL=()
fi
# 002's config-dump samples and the growth memory guard's Envoy-stats reads run under
# timeout/gtimeout; a live sweep without either stops here, before any cluster change,
# instead of recording every sample N/A (R17). The plan (--dry-run) does not need it.
((DRY_RUN)) || require_timeout
# R4: the Istio version every member runs, read once before any cluster change and
# exported, so 001, 002 and 005 record it (ISTIO_VERSION_CHECK=fail stops here on a
# mismatch). --dry-run reads nothing: the pin, ISTIO_VERSION_SOURCE=pin.
istio_version_resolve "$(IFS=,; echo "${CONTEXTS[*]}")" "$DRY_RUN" ${KUBECTL[@]+"${KUBECTL[@]}"}
echo "Istio version:     $(istio_version_label)" >&2
# --resume appends to a TSV whose preamble names the version the sweep started on: rows
# measured on another one would be credited to it.
if [[ -n "$RESUME_DIR" && "$ISTIO_VERSION_SOURCE" == live ]]; then
	_resume_iv="$(grep -m1 '^# ISTIO_VERSION=' "${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv" 2>/dev/null || true)"
	_resume_iv="${_resume_iv#*=}"
	if [[ -n "$_resume_iv" && "${_resume_iv#v}" != "${ISTIO_VERSION#v}" ]]; then
		_resume_msg="--resume: this sweep recorded ISTIO_VERSION=${_resume_iv}, but the mesh now runs ${ISTIO_VERSION}, so its new rows would be credited to ${_resume_iv}"
		[[ "${ISTIO_VERSION_CHECK:-fail}" == warn ]] || die "${_resume_msg}. Start a new sweep (or set ISTIO_VERSION_CHECK=warn to resume anyway)."
		echo "warning: ${_resume_msg} (ISTIO_VERSION_CHECK=warn)." >&2
	fi
fi

capacity_plan_warn
guard_add_mesh_members
leftover_preflight

if ((DRY_RUN)) && ! ((GROWTH)); then
	echo "--- Combinations (dry-run) ---" >&2
fi

fmt_ns_pattern() {
	local nc="$1"
	if (( nc <= 1 )); then
		printf '%s\n' "$NS"
	else
		printf '%s-0..%s-%d\n' "$NS" "$NS" "$(( nc - 1 ))"
	fi
}

ensure_output_dir() {
	[[ -d "$OUTPUT_DIR" ]] && return 0
	mkdir -p "$OUTPUT_DIR"
	echo "Output directory: $OUTPUT_DIR" >&2
}

# ---------------------------------------------------------------------------
# Background peak-memory poller for split-phase mode.
# ---------------------------------------------------------------------------
# Runs between the baseline and final 002 invocations, using the same port
# range (15014+k). Safe because 002-baseline has exited and freed its ports.
# Same sampling as 002's poll_peak_metrics; results land in the state dir.
PEAK_POLLER_PID=""
PEAK_PF_PIDS=()
BASE_PF_PORT=15014
POLL_INTERVAL=5

start_peak_metrics_poller() {
	local state_dir="$1"
	local manifest="${state_dir}/pods.tsv"
	[[ -f "$manifest" ]] || return 0
	(( ${#KUBECTL[@]} )) || return 0

	local -a pod_ctxs=() pod_names=()
	while IFS=$'\t' read -r _idx ctx pod; do
		pod_ctxs+=("$ctx")
		pod_names+=("$pod")
	done < "$manifest"
	(( ${#pod_ctxs[@]} )) || return 0

	PEAK_PF_PIDS=()
	for k in "${!pod_ctxs[@]}"; do
		local port=$(( BASE_PF_PORT + k ))
		"${KUBECTL[@]}" --context="${pod_ctxs[k]}" -n istio-system \
			port-forward "pod/${pod_names[k]}" "$port":15014 >/dev/null 2>&1 &
		PEAK_PF_PIDS+=($!)
	done
	sleep 2

	(
		trap 'exit 0' TERM
		while true; do
			for k in "${!pod_ctxs[@]}"; do
				local port=$(( BASE_PF_PORT + k ))
				local body now_t
				body=$(curl -s --max-time "${METRICS_SCRAPE_TIMEOUT:-30}" "http://localhost:${port}/metrics" 2>/dev/null) || continue
				now_t=$(now_ms)

				# Peak memory.
				local mem_val
				mem_val=$(echo "$body" | awk '/^process_resident_memory_bytes[{ ]/ && !/^#/ { print $NF+0 }')
				if [[ -n "$mem_val" && "$mem_val" != "0" ]]; then
					local prev_mem=0
					[[ -s "${state_dir}/peak-mem-${k}.val" ]] && prev_mem=$(<"${state_dir}/peak-mem-${k}.val")
					if awk -v a="$mem_val" -v b="$prev_mem" 'BEGIN{ exit !(a+0 > b+0) }'; then
						printf '%s' "$mem_val" > "${state_dir}/peak-mem-${k}.val"
					fi
				fi

				# Peak CPU rate in millicores over the measured time between samples.
				local cpu_val
				cpu_val=$(echo "$body" | awk '/^process_cpu_seconds_total[{ ]/ && !/^#/ { print $NF+0 }')
				if [[ -n "$cpu_val" && "$cpu_val" != "0" ]]; then
					local prev_cpu_file="${state_dir}/prev-cpu-${k}.val"
					if [[ -s "$prev_cpu_file" ]]; then
						local prev_cpu prev_t rate_m
						read -r prev_cpu prev_t < "$prev_cpu_file" || true
						rate_m=$(awk -v c="$cpu_val" -v p="$prev_cpu" -v dt="$(( now_t - prev_t ))" \
							'BEGIN{ if (dt <= 0) { print 0; exit }; d=(c-p)*1000000/dt; if(d<0) d=0; printf "%.0f", d }')
						local prev_peak=0
						[[ -s "${state_dir}/peak-cpu-${k}.val" ]] && prev_peak=$(<"${state_dir}/peak-cpu-${k}.val")
						if awk -v a="$rate_m" -v b="$prev_peak" 'BEGIN{ exit !(a+0 > b+0) }'; then
							printf '%s' "$rate_m" > "${state_dir}/peak-cpu-${k}.val"
						fi
					fi
					printf '%s %s\n' "$cpu_val" "$now_t" > "$prev_cpu_file"
				fi
			done
			sleep "$POLL_INTERVAL"
		done
	) &
	PEAK_POLLER_PID=$!
}

stop_peak_metrics_poller() {
	if [[ -n "$PEAK_POLLER_PID" ]]; then
		kill "$PEAK_POLLER_PID" 2>/dev/null || true
		wait "$PEAK_POLLER_PID" 2>/dev/null || true
		PEAK_POLLER_PID=""
	fi
	for pid in "${PEAK_PF_PIDS[@]}"; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	PEAK_PF_PIDS=()
}

trap 'stop_peak_metrics_poller 2>/dev/null || true' EXIT

# Pre-create the TSV preamble before any combo (skipped in dry-run). A fresh sweep with
# --config also gets the run-config-<RUN_ID>.env replay copy; a resumed one keeps the
# config it started with.
if ((! DRY_RUN)); then
	metrics_preflight
	precreate_tsv_preamble
	[[ -n "$RESUME_DIR" ]] || config_snapshot "$OUTPUT_DIR" "$RUN_ID"
	if ((GROWTH)); then
		# Namespace-lifecycle timings (001/005 append) and the memory guard's decisions.
		ns_lifecycle_init "$LIFECYCLE_FILE" "$RUN_ID"
		mapfile -t _iv_kv < <(istio_version_kv)
		write_preamble "Memory stop guard (controlplane growth mode)" "$GUARD_FILE" \
			"RUN_ID=${RUN_ID}" "HARNESS_SHA=$(harness_sha)" "${_iv_kv[@]}" \
			"MEM_STOP_PCT=${MEM_STOP_PCT}" "MEM_GUARD_CONTEXTS=$(IFS=,; echo "${GUARD_CONTEXTS[*]}")" \
			"GUARD_SCHEMA=2" "GW_MODEL=intercept ${GW_MI_INTERCEPT} Mi; eastwestgateway ${EWGW_MI_PER_1000} Mi per 1000 Services x ${EWGW_BURST}; ingressgateway ${INGW_MI_PER_1000} Mi per 1000 Services x ${INGW_BURST}" \
			"NOTE=rel_projected = base + (current - base) x ratio^power from the series start (ratio 1: the first step and changes that add no Services); abs_projected (gateways) = (intercept + Mi per 1000 Services x services_after / 1000) x burst factor, plus the non-heap part of a working-set reading (ws - Envoy physical heap); services_after = the context's istiod pilot_services + the Services the step adds; projected = the larger, compared with stop_pct % of limit_mi. metric: rss = istiod process_resident_memory_bytes (max over replicas, per-replica limit); ws = the gateway container's working set (kubectl top), else physical = Envoy server.memory_physical_size, else allocated = server.memory_allocated (istio-proxy limit). verdict stale_base: a gateway's Envoy allocated memory exceeded 1.5 x the model + 100 Mi at the series start (memory kept from an earlier series)."
		printf 'timestamp\tseries\tcell\tcontext\tcomponent\tmetric\tcurrent_mi\tbase_mi\tratio\tpower\trel_projected_mi\tservices_after\tabs_projected_mi\tprojected_mi\tlimit_mi\tstop_pct\tverdict\n' >> "$GUARD_FILE"
	fi
fi

# ---------------------------------------------------------------------------
# Namespace scaling (growth mode).
# ---------------------------------------------------------------------------
# One series per mesh size x K. In place, a series grows one set of namespaces up
# the --namespace-counts ladder. At each N: switch back to namespace scoping (grow
# rows are always scoping namespace), a grow window (baseline -> 001 adds namespaces
# N_prev..N-1 -> settle -> final), then per scoping a switch (001 --parts sidecars)
# and a probe window (baseline -> 001 --parts probe -> probe settle -> final); 005
# --probe then retires the probe namespace (Services and Sidecar first) and the
# probe settle runs again before the next baseline. At the largest N come the outside
# phases and the M-sweep; the series ends per --series-retire. Every step is wrapped
# (PL32): a failure becomes a status row and the sweep goes on; a failed grow stops
# the series and its remaining cells are recorded as SKIPPED_SERIES_STOPPED. Before
# each larger step the memory guard projects istiod heap and gateway memory on every
# guard context and records a cell that would cross MEM_STOP_PCT % of a limit as
# SKIPPED_MEM_GUARD.

CELL_IDX=0
PROBE_IDX=0
declare -A GUARD_BASE=()  # "<ctx>|<component>" -> MiB at the series start
declare -A GUARD_WIDE=()  # "<ctx>|istiod" -> heap MiB after the last wide probe
GUARD_WIDE_N=0            # discovered namespaces at that measurement
# Series state (set by run_growth_series / run_growth_fresh).
G_SID=""
G_K=0
G_MS=0
G_ACTIVE_CSV=""
G_REPLICAS=1
G_M=1
G_CUR_SCOPE=""
G_STOPPED=""
G_WIDE_STOPPED=0

# g_ratio <a> <b>: a / b (4 decimals); 1 when b is not positive.
g_ratio() { awk -v a="$1" -v b="$2" 'BEGIN { if (b + 0 <= 0) print 1; else printf "%.4f\n", a / b }'; }

# guard_sample_ctx <ctx> <ctx_index>: one istiod line and one line per gateway:
#   "istiod <rss_mi> rss <limit_mi> <services> istiod <heap_inuse_mi>"
#   "gw:<pod> <guard_mi> <metric> <limit_mi> <services> <kind> <allocated_mi> <physical_mi>"
# istiod: max process_resident_memory_bytes over the context's istiod pods (the RSS
# the OOM killer acts on; heap_inuse ran about half of it on ROSA), the per-replica
# limit, and pilot_services (max over pods). Gateways (BACKLOG 9.5): the container
# working set from kubectl top (metric ws), else Envoy server.memory_physical_size
# (physical: the tcmalloc heap with the freed pages it kept), else
# server.memory_allocated (allocated, an underestimate after config bursts); kind is
# the istio label; services is the context's istiod pilot_services. The port-forwards
# close on return. A context without a reachable istiod prints no istiod line (and its
# gateways read services -); nothing here can abort the sweep (PL40).
guard_sample_ctx() {
	local ctx="$1" ci="$2" ist svc="-"
	ist="$(
		local -a pids=() ports=() pods=()
		local dir i r h s max="" hmax="" smax="" lim="unknown" kv
		dir="$(mktemp -d -t controlplane-guard.XXXXXX)"
		trap 'for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$dir"' EXIT
		fanout_open "$ctx" "$ci" pids ports pods "${KUBECTL[@]}" 2>/dev/null
		fanout_scrape_all "$dir" g "${ports[@]}" >/dev/null 2>&1 || true
		for i in "${!ports[@]}"; do
			r="$(awk '/^process_resident_memory_bytes[ {]/ { v = $NF } END { if (v != "") printf "%.0f\n", v / 1048576 }' "${dir}/g-${i}.metrics" 2>/dev/null)"
			h="$(growth_istiod_heap_mi "${dir}/g-${i}.metrics")"
			s="$(awk '/^pilot_services[ {]/ { v += $NF; seen = 1 } END { if (seen) printf "%.0f\n", v }' "${dir}/g-${i}.metrics" 2>/dev/null)"
			if [[ "$r" =~ ^[0-9]+$ ]] && { [[ -z "$max" ]] || ((r > max)); }; then max="$r"; fi
			if [[ "$h" =~ ^[0-9]+$ ]] && { [[ -z "$hmax" ]] || ((h > hmax)); }; then hmax="$h"; fi
			if [[ "$s" =~ ^[0-9]+$ ]] && { [[ -z "$smax" ]] || ((s > smax)); }; then smax="$s"; fi
		done
		for kv in $(cap_istiod_limits "$ctx" "${KUBECTL[@]}"); do
			[[ "$kv" == mem_mi=* ]] && lim="${kv#mem_mi=}"
		done
		[[ -n "$max" ]] && echo "istiod ${max} rss ${lim} ${smax:--} istiod ${hmax:--}"
		exit 0
	)" || ist=""
	if [[ -n "$ist" ]]; then
		echo "$ist"
		svc="$(awk '{ print $5 }' <<<"$ist")"
	fi
	local pod plim kind kv mem phy ws metric val
	declare -A wsm=()
	while IFS=$'\t' read -r pod ws; do
		[[ -n "$pod" ]] && wsm[$pod]="$ws"
	done < <(growth_gateway_ws "$ctx" "${KUBECTL[@]}")
	while IFS=$'\t' read -r pod plim kind; do
		[[ -n "$pod" ]] || continue
		kv="$(growth_envoy_stats "$ctx" istio-system "$pod" "${KUBECTL[@]}")"
		mem="$(_growth_kv mem_mi "$kv")"
		phy="$(_growth_kv physical_mi "$kv")"
		ws="${wsm[$pod]:-}"
		if [[ "$ws" =~ ^[0-9]+$ ]]; then metric=ws; val="$ws"
		elif [[ "$phy" =~ ^[0-9]+$ ]]; then metric=physical; val="$phy"
		elif [[ "$mem" =~ ^[0-9]+$ ]]; then metric=allocated; val="$mem"
		else continue
		fi
		[[ "$mem" =~ ^[0-9]+$ ]] || mem="-"
		[[ "$phy" =~ ^[0-9]+$ ]] || phy="-"
		echo "gw:${pod} ${val} ${metric} ${plim} ${svc} ${kind:-unknown} ${mem} ${phy}"
	done < <(growth_gateway_pods "$ctx" "${KUBECTL[@]}")
	return 0
}

# guard_collect <assoc_name>: sample every guard context into "<ctx>|<component>" ->
# "<current_mi> <metric> <limit_mi> <services> <kind> <allocated_mi> <physical_mi>".
guard_collect() {
	local -n _gc="$1"
	_gc=()
	local ci comp rest
	for ci in "${!GUARD_CONTEXTS[@]}"; do
		while read -r comp rest; do
			[[ -n "$comp" ]] || continue
			_gc["${GUARD_CONTEXTS[ci]}|${comp}"]="$rest"
		done < <(guard_sample_ctx "${GUARD_CONTEXTS[ci]}" "$ci")
	done
}

# guard_gw_model <kind>: "<mi_per_1000_services> <burst_factor>" of the absolute model
# (an unknown kind takes the east-west figures, the larger).
guard_gw_model() {
	case "$1" in
	ingressgateway) echo "$INGW_MI_PER_1000 $INGW_BURST" ;;
	*) echo "$EWGW_MI_PER_1000 $EWGW_BURST" ;;
	esac
}

# guard_log <cell> <ctx> <component> <metric> <cur> <base> <ratio> <power> <rel_proj>
#           <services_after> <abs_proj> <projected> <limit> <verdict>
guard_log() {
	[[ -f "$GUARD_FILE" ]] || return 0
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u -Iseconds)" "$G_SID" \
		"$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" "${13}" "$MEM_STOP_PCT" "${14}" >> "$GUARD_FILE"
}

# guard_baseline: the empty-mesh reference of a series (before its first step). Warns
# when a gateway already holds far more than the absolute model expects for the
# Services the mesh has now (BACKLOG 9.4: Envoy kept about 500 Mi after a series was
# undiscovered, which inflated the next series' base): restart the gateways first.
guard_baseline() {
	GUARD_BASE=()
	GUARD_WIDE=()
	GUARD_WIDE_N=0
	((MEM_STOP_PCT > 0)) || return 0
	local -A now=()
	guard_collect now
	local key cur metric lim svc kind alloc ctx amodel per burst stale=0
	for key in "${!now[@]}"; do
		read -r cur metric lim svc kind alloc _ <<<"${now[$key]}"
		GUARD_BASE[$key]="$cur"
		[[ "${key#*|}" == gw:* && "$svc" =~ ^[0-9]+$ && "$alloc" =~ ^[0-9]+$ ]] || continue
		read -r per burst <<<"$(guard_gw_model "$kind")"
		# Envoy's allocated memory tracks its live config: far above the model for the
		# Services the mesh has now (x1.5 + 100 Mi) means memory kept from earlier config.
		amodel="$(mem_guard_project_abs "$svc" "$per" "$GW_MI_INTERCEPT" 1.5)"
		[[ "$amodel" =~ ^[0-9]+$ ]] || continue
		if ((alloc > amodel + 100)); then
			stale=1
			echo "WARNING: memory guard: ${key}: Envoy allocated ${alloc} Mi at the series start, above the ${amodel} Mi the model allows for ${svc} Services (memory kept from an earlier series). Restart the gateways between series (oc -n istio-system rollout restart deploy -l 'istio in (ingressgateway,eastwestgateway)' on each member, nothing measuring) for clean numbers; the absolute projection still guards every step." >&2
			guard_log "series start" "${key%%|*}" "${key#*|}" allocated "$alloc" "$alloc" 1 1 "$alloc" "$svc" "$amodel" "$alloc" "$lim" stale_base
		fi
	done
	for ctx in "${GUARD_CONTEXTS[@]}"; do
		[[ -n "${GUARD_BASE["${ctx}|istiod"]:-}" ]] \
			|| echo "warn: memory guard: no istiod RSS readable on ${ctx}; its istiod is not guarded and its gateways get no absolute projection" >&2
	done
	echo "Memory guard baseline: ${#GUARD_BASE[@]} component(s) on ${#GUARD_CONTEXTS[@]} context(s) (stop at ${MEM_STOP_PCT}% of a limit)$( ((stale)) && echo '; stale gateway memory, see the warning')"
}

# guard_check <cell> <istiod_ratio> <istiod_power> <gateway_ratio> <use_wide>
#             <added_services>: 0 to run the cell, 1 to skip it. Each component is
# projected relative to the series start, base + (current - base) x ratio^power (with
# use_wide, istiod's "current" is its RSS after the last wide probe, GUARD_WIDE, so a
# wide cell projects quadratically from the last wide measurement; ratio 1 = current
# usage only). Gateways are also projected absolutely for the Services the mesh holds
# after the step (pilot_services + added_services; mem_guard_project_abs), which also
# covers a series' first step (ratio 1) and an inflated base (BACKLOG 9.4). The model is
# Envoy's heap; a working-set reading adds the container's non-heap memory (working set
# minus Envoy's physical heap: pilot-agent, binary, page cache; 40-200 Mi on the lab). The
# larger projection stops the cell when it exceeds MEM_STOP_PCT % of the limit.
guard_check() {
	local cell="$1" ir="$2" ip="$3" gr="$4" use_wide="${5:-0}" added="${6:-0}"
	((MEM_STOP_PCT > 0)) || return 0
	local -A now=()
	guard_collect now
	if ((${#now[@]} == 0)); then
		echo "warn: memory guard: nothing could be sampled before '${cell}'; running it unguarded" >&2
		guard_log "$cell" - - - - - - - - - - - - unknown
		return 0
	fi
	local key cur metric lim svc kind phy base r p rel abs sa per burst proj verdict stop=0 comp over
	for key in "${!now[@]}"; do
		read -r cur metric lim svc kind _ phy <<<"${now[$key]}"
		comp="${key#*|}"
		base="${GUARD_BASE[$key]:-$cur}"
		abs="-"
		sa="-"
		if [[ "$comp" == istiod ]]; then
			r="$ir"
			p="$ip"
			if ((use_wide)) && [[ -n "${GUARD_WIDE[$key]:-}" ]]; then cur="${GUARD_WIDE[$key]}"; fi
		else
			r="$gr"
			p=1
			if [[ "$svc" =~ ^[0-9]+$ ]]; then
				sa=$((svc + added))
				read -r per burst <<<"$(guard_gw_model "$kind")"
				abs="$(mem_guard_project_abs "$sa" "$per" "$GW_MI_INTERCEPT" "$burst")"
				over=0
				[[ "$metric" == ws && "${phy:-}" =~ ^[0-9]+$ ]] && ((cur > phy)) && over=$((cur - phy))
				[[ "$abs" =~ ^[0-9]+$ ]] && abs=$((abs + over))
			fi
		fi
		rel="$(mem_guard_project "$cur" "$base" "$r" "$p")"
		proj="$rel"
		if [[ "$abs" =~ ^[0-9]+$ ]] && { ! [[ "$proj" =~ ^[0-9]+$ ]] || ((abs > proj)); }; then proj="$abs"; fi
		verdict="$(mem_guard_verdict "$proj" "$lim" "$MEM_STOP_PCT")"
		guard_log "$cell" "${key%%|*}" "$comp" "$metric" "$cur" "$base" "$r" "$p" "$rel" "$sa" "$abs" "$proj" "$lim" "$verdict"
		if [[ "$verdict" == stop ]]; then
			echo "  memory guard: ${key}: projected ${proj} Mi > ${MEM_STOP_PCT}% of ${lim} Mi (${metric} now ${cur} Mi, base ${base} Mi, x ${r}^${p} = ${rel} Mi$([[ "$abs" == - ]] || echo "; model for ${sa} Services ${abs} Mi")); skipping '${cell}'" >&2
			stop=1
		fi
	done
	((stop == 0))
}

# guard_note_wide <discovered_namespaces>: remember istiod RSS after a wide probe.
guard_note_wide() {
	((MEM_STOP_PCT > 0)) || return 0
	local -A now=()
	guard_collect now
	local key cur rest
	for key in "${!now[@]}"; do
		[[ "${key#*|}" == istiod ]] || continue
		read -r cur rest <<<"${now[$key]}"
		GUARD_WIDE[$key]="$cur"
	done
	GUARD_WIDE_N="$1"
}

# g001 <args...>: 001 with the series' common arguments.
g001() {
	"$SCRIPT_DIR/001-setup-controlplane-test.sh" --contexts "$G_ACTIVE_CSV" \
		--services-per-namespace "$G_K" --series "$G_SID" --workload-mode "$WORKLOAD_MODE" \
		--replicas "${REPLICA_COUNTS[0]}" --lifecycle-file "$LIFECYCLE_FILE" "$@"
}

# g002 <phase> <state_dir> <n> <scoping> <window_kind> <outside_x> <outside_mode> <m> [args...]
g002() {
	local phase="$1" state="$2" n="$3" scp="$4" kind="$5" ox="$6" od="$7" m="$8"
	shift 8
	"$SCRIPT_DIR/002-collect-resource-metrics.sh" --phase "$phase" --state-dir "$state" \
		--contexts "$G_ACTIVE_CSV" --mesh-size "$G_MS" \
		--service-count "$(( n * G_K ))" --replicas "$G_REPLICAS" --namespace-count "$n" \
		--sidecar-scoping "$scp" --traffic-config none \
		--services-per-namespace "$G_K" --workload-mode "$WORKLOAD_MODE" --measurement-pods "$m" \
		--outside-namespaces "$ox" --outside-mode "$od" --window-kind "$kind" --series "$G_SID" \
		--run-id "$RUN_ID" "$@"
}

# g_row <status> <n> <scoping> <window_kind> <outside_x> <outside_mode> <m>: a status
# row for a growth cell (same growth columns 002 writes).
g_row() {
	local status="$1" n="$2" scp="$3" kind="$4" ox="$5" od="$6" m="$7" mp
	if [[ "$WORKLOAD_MODE" == config-only ]]; then
		mp=$(( m < n ? m : n ))
	else
		mp=$(( n * G_K * G_REPLICAS ))
	fi
	((ox > 0)) || od=none
	emit_failed_row "$status" "$G_MS" "$(( n * G_K ))" "$G_REPLICAS" "$n" "$scp" none \
		"$G_K" "$WORKLOAD_MODE" "$mp" "$ox" "$od" "$kind"
}

# g_skip <status> <n> <scoping> <window_kind> <outside_x> <outside_mode> <m>: a planned
# cell that does not run.
g_skip() {
	CELL_IDX=$((CELL_IDX + 1))
	printf "  [%d/%d] series=%s N=%s %s scope=%s: %s\n" "$CELL_IDX" "$MATRIX_SIZE" "$G_SID" "$2" "$4" "$3" "$1" >&2
	g_row "$@"
}

# g_window <window_kind> <n> <scoping> <outside_x> <outside_mode> <m> <settle>
#          <fail_status> <001 args...>: one measured window around one 001 call.
# Returns 1 when 001 failed (a <fail_status> row is recorded), else 0. A failed
# baseline is recorded as PROBE_FAILED and 001 still runs, so the series goes on.
g_window() {
	local kind="$1" n="$2" scp="$3" ox="$4" od="$5" m="$6" settle="$7" fail_status="$8"
	shift 8
	CELL_IDX=$((CELL_IDX + 1))
	local label="series=${G_SID} K=${G_K} N=${n} ${kind} scope=${scp} M=${m} outside=${ox}/${od}"
	local state="${OUTPUT_DIR}/state-cell-${CELL_IDX}" measured=1
	echo "=========================================="
	printf "  Growth cell [%d/%d]: %s\n" "$CELL_IDX" "$MATRIX_SIZE" "$label"
	echo "=========================================="
	mkdir -p "$state"
	if ! g002 baseline "$state" "$n" "$scp" "$kind" "$ox" "$od" "$m" --settle "$settle"; then
		echo "warn: baseline probe failed for '${label}'; recording PROBE_FAILED and applying anyway" >&2
		g_row PROBE_FAILED "$n" "$scp" "$kind" "$ox" "$od" "$m"
		measured=0
	fi
	((measured)) && start_peak_metrics_poller "$state"
	if ! g001 "$@"; then
		stop_peak_metrics_poller
		echo "warn: setup failed for '${label}'; recording ${fail_status}" >&2
		((measured)) && g_row "$fail_status" "$n" "$scp" "$kind" "$ox" "$od" "$m"
		rm -rf "$state"
		return 1
	fi
	if ((settle > 0)); then
		echo "--- Settling ${settle}s before the final scrape ---"
		sleep "$settle"
	fi
	stop_peak_metrics_poller
	if ((measured)); then
		if ! g002 final "$state" "$n" "$scp" "$kind" "$ox" "$od" "$m" \
			--config-dump-samples "$CONFIG_DUMP_SAMPLES" --settle "$settle" --output-dir "$OUTPUT_DIR"; then
			echo "warn: final probe failed for '${label}'; recording PROBE_FAILED" >&2
			g_row PROBE_FAILED "$n" "$scp" "$kind" "$ox" "$od" "$m"
		fi
	fi
	rm -rf "$state"
	return 0
}

# g_switch <scoping> <n>: switch the series' n namespaces to a scoping in place.
g_switch() {
	local scp="$1" n="$2"
	echo "--- Scoping switch: series ${G_SID} -> ${scp} (${n} namespaces) ---"
	if g001 --parts sidecars --namespace-count "$n" --sidecar-scoping "$scp" --measurement-pods "$G_M"; then
		G_CUR_SCOPE="$scp"
		if ((SETTLE_SEC > 0)); then sleep "$SETTLE_SEC"; fi
		return 0
	fi
	G_CUR_SCOPE="?"
	return 1
}

# g_probe <n> <scoping> <outside_x> <outside_mode> <m>: one probe window, then the
# probe namespace's retirement and the probe settle (also after a failed apply).
g_probe() {
	local n="$1" scp="$2" ox="$3" od="$4" m="$5"
	PROBE_IDX=$((PROBE_IDX + 1))
	local pname="${NS}-${G_SID}-p${PROBE_IDX}"
	g_window probe "$n" "$scp" "$ox" "$od" "$m" "$PROBE_SETTLE_SEC" SETUP_FAILED \
		--parts probe --probe "$pname" --namespace-count "$n" --sidecar-scoping "$scp" --measurement-pods "$G_M" || true
	"$SCRIPT_DIR/005-cleanup.sh" --contexts "$G_ACTIVE_CSV" --probe "$pname" --lifecycle-file "$LIFECYCLE_FILE" \
		|| echo "warn: retiring probe namespace ${pname} reported a failure" >&2
	if ((PROBE_SETTLE_SEC > 0)); then
		echo "--- Probe settle ${PROBE_SETTLE_SEC}s after the probe teardown ---"
		sleep "$PROBE_SETTLE_SEC"
	fi
}

# g_probe_scopings <n> <outside_x> <outside_mode> <m> <discovered_namespaces>: one
# probe per scoping at the current step, each behind its own guard check. The scoping
# the series already has goes first (after a grow that is namespace), which saves one
# rewrite of every Sidecar of the series per step.
g_probe_scopings() {
	local n="$1" ox="$2" od="$3" m="$4" n_disc="$5" scp r
	local -a order=()
	for scp in "${SCOPINGS[@]}"; do [[ "$scp" == "$G_CUR_SCOPE" ]] && order+=("$scp"); done
	for scp in "${SCOPINGS[@]}"; do [[ "$scp" == "$G_CUR_SCOPE" ]] || order+=("$scp"); done
	for scp in "${order[@]}"; do
		if [[ -n "$G_STOPPED" ]]; then
			g_skip "$G_STOPPED" "$n" "$scp" probe "$ox" "$od" "$m"
			continue
		fi
		if [[ "$scp" == wide ]] && ((G_WIDE_STOPPED)); then
			g_skip SKIPPED_MEM_GUARD "$n" "$scp" probe "$ox" "$od" "$m"
			continue
		fi
		if [[ "$scp" != "$G_CUR_SCOPE" ]]; then
			if [[ "$scp" == wide ]]; then
				r=1
				((GUARD_WIDE_N > 0)) && r="$(g_ratio "$n_disc" "$GUARD_WIDE_N")"
				if ! guard_check "probe wide N=${n}" "$r" 2 1 1 "$G_K"; then
					G_WIDE_STOPPED=1
					g_skip SKIPPED_MEM_GUARD "$n" "$scp" probe "$ox" "$od" "$m"
					continue
				fi
			elif ! guard_check "probe ${scp} N=${n}" 1 1 1 0 "$G_K"; then
				g_skip SKIPPED_MEM_GUARD "$n" "$scp" probe "$ox" "$od" "$m"
				continue
			fi
			if ! g_switch "$scp" "$n"; then
				g_skip SWITCH_FAILED "$n" "$scp" probe "$ox" "$od" "$m"
				continue
			fi
		fi
		g_probe "$n" "$scp" "$ox" "$od" "$m"
		[[ "$scp" == wide ]] && guard_note_wide "$n_disc"
	done
	return 0
}

# SWEEP_STOPPED: set when a series could not be retired; no later series runs and the
# sweep exits 1 after its report (BACKLOG 9.3: R1b's failed retire left 2000
# namespaces discovered under the next series).
SWEEP_STOPPED=""

# g_retire_cmd <series> <cleanup args...>: retire a series' (or fresh cell's)
# namespaces through 005 and verify on the active contexts that none is still
# discovered (growth_retire_verified: CONTROLPLANE_RETIRE_ATTEMPTS tries). 1 = not.
g_retire_cmd() {
	local sid="$1"
	shift
	growth_retire_verified KUBECTL "$G_ACTIVE_CSV" "app.kubernetes.io/instance=controlplane-test,controlplane-test.series=${sid}" \
		"$RETIRE_ATTEMPTS" "$RETIRE_BACKOFF_S" -- \
		"$SCRIPT_DIR/005-cleanup.sh" --contexts "$G_ACTIVE_CSV" --series "$sid" --lifecycle-file "$LIFECYCLE_FILE" "$@"
}

# g_retire_failed <series> <n> <window_kind_detail>: record RETIRE_FAILED and stop the sweep.
g_retire_failed() {
	local sid="$1" n="$2"
	g_row RETIRE_FAILED "$n" namespace retire 0 none "$G_M"
	SWEEP_STOPPED="series ${sid} was not retired on ${G_ACTIVE_CSV} (the cleanup failed, or its namespaces are still discovered)"
	echo "ERROR: ${SWEEP_STOPPED}. No further series runs. Retire it by hand before any other sweep: ${SCRIPT_DIR}/005-cleanup.sh --contexts ${G_ACTIVE_CSV} --series ${sid} --undiscover --no-delete" >&2
}

# g_retire <n>: end a series per --series-retire (then the PL18 settle).
g_retire() {
	local n="$1"
	echo "--- Retiring series ${G_SID} (${SERIES_RETIRE}) ---"
	case "$SERIES_RETIRE" in
	undiscover)
		g_retire_cmd "$G_SID" --undiscover --no-delete || g_retire_failed "$G_SID" "$n"
		;;
	delete)
		g_retire_cmd "$G_SID" --undiscover --no-wait || g_retire_failed "$G_SID" "$n"
		;;
	keep)
		echo "Series ${G_SID} stays discovered (--series-retire keep); remove it later with 005 --series ${G_SID}."
		;;
	esac
	if ((SETTLE_SEC > 0)); then sleep "$SETTLE_SEC"; fi
}

# g_series_start_count: log the controlplane-test namespaces on the active contexts at a
# series start (BACKLOG 9.10) to the namespace-lifecycle TSV (action leftover-check:
# namespaces = all of them, objects = the discovered ones; status LEFTOVER above
# CONTROLPLANE_LEFTOVER_NS_WARN). Every row of the series also carries its own count
# (column leftover_test_namespaces).
g_series_start_count() {
	local c kv total disc st
	for c in "${CONTEXTS[@]:0:$G_MS}"; do
		kv="$(growth_test_ns_counts "$c" "${KUBECTL[@]}")"
		total="$(_growth_kv total "$kv")"
		disc="$(_growth_kv discovered "$kv")"
		st=OK
		[[ "$total" =~ ^[0-9]+$ ]] && ((total > LEFTOVER_NS_WARN)) && st=LEFTOVER
		echo "Series ${G_SID} start: ${c} holds ${total} controlplane-test namespace(s) from earlier series or runs (${disc} discovered)"
		ns_lifecycle_row "$LIFECYCLE_FILE" "$c" "$G_SID" 0 leftover-check "$total" "$disc" N/A N/A N/A N/A "$st"
	done
}

# run_growth_series <mesh_size> <K> <series_index>: one in-place series.
run_growth_series() {
	G_MS="$1"
	G_K="$2"
	G_SID="${SERIES_PREFIX}-$3"
	local -a active=("${CONTEXTS[@]:0:$G_MS}")
	G_ACTIVE_CSV="$(IFS=,; echo "${active[*]}")"
	G_REPLICAS="${REPLICA_COUNTS[0]}"
	[[ "$WORKLOAD_MODE" == config-only ]] && G_REPLICAS=1
	G_M="${M_LIST[0]}"
	G_CUR_SCOPE=""
	G_STOPPED=""
	G_WIDE_STOPPED=0
	echo ""
	echo "########## Growth series ${G_SID}: mesh=${G_MS} K=${G_K} on ${active[*]} ##########"
	g_series_start_count
	guard_baseline
	local n n_prev=0 r
	for n in "${NAMESPACE_COUNTS[@]}"; do
		if [[ -z "$G_STOPPED" && -n "$G_CUR_SCOPE" && "$G_CUR_SCOPE" != namespace ]]; then
			# Grow rows are always measured under namespace scoping (switch back first).
			if ! g_switch namespace "$n_prev"; then
				g_skip SWITCH_FAILED "$n" namespace grow 0 none "$G_M"
				G_STOPPED=SKIPPED_SERIES_STOPPED
				g_probe_scopings "$n" 0 none "$G_M" "$n"
				continue
			fi
		fi
		if [[ -n "$G_STOPPED" ]]; then
			g_skip "$G_STOPPED" "$n" namespace grow 0 none "$G_M"
			g_probe_scopings "$n" 0 none "$G_M" "$n"
			continue
		fi
		r=1
		((n_prev > 0)) && r="$(g_ratio "$n" "$n_prev")"
		if ! guard_check "grow ${n_prev}->${n}" "$r" 1 "$r" 0 "$(( (n - n_prev) * G_K ))"; then
			G_STOPPED=SKIPPED_MEM_GUARD
			g_skip SKIPPED_MEM_GUARD "$n" namespace grow 0 none "$G_M"
			g_probe_scopings "$n" 0 none "$G_M" "$n"
			continue
		fi
		if ! g_window grow "$n" namespace 0 none "$G_M" "$SETTLE_SEC" GROW_FAILED \
			--namespace-start "$n_prev" --namespace-count "$n" --sidecar-scoping namespace --measurement-pods "$G_M"; then
			G_STOPPED=SKIPPED_SERIES_STOPPED
			g_probe_scopings "$n" 0 none "$G_M" "$n"
			continue
		fi
		G_CUR_SCOPE=namespace
		n_prev="$n"
		g_probe_scopings "$n" 0 none "$G_M" "$n"
	done
	local n_last="$n_prev" om ox_state=0 od_state=none n_disc="$n_prev"
	# Outside phases at the largest N reached, in order (unlabeled, then the label flip).
	for om in "${OUTSIDE_PHASES[@]}"; do
		local stopped="${G_STOPPED:-}"
		((n_last > 0)) || stopped="${stopped:-SKIPPED_SERIES_STOPPED}"
		if [[ -z "$stopped" && "$G_CUR_SCOPE" != namespace ]] && ! g_switch namespace "$n_last"; then
			stopped=SWITCH_FAILED
		fi
		r=1
		local o_added=0
		[[ "$om" == labeled ]] && r="$(g_ratio "$(( n_last + OUTSIDE_NAMESPACES ))" "$n_last")" && o_added=$(( OUTSIDE_NAMESPACES * G_K ))
		if [[ -z "$stopped" ]] && ! guard_check "outside ${om} N=${n_last}" "$r" 1 "$r" 0 "$o_added"; then
			stopped=SKIPPED_MEM_GUARD
		fi
		if [[ -z "$stopped" ]] && ! g_window outside "$n_last" namespace "$OUTSIDE_NAMESPACES" "$om" "$G_M" "$SETTLE_SEC" SETUP_FAILED \
			--parts outside --outside-namespaces "$OUTSIDE_NAMESPACES" --outside-mode "$om" \
			--namespace-count "$n_last" --sidecar-scoping namespace --measurement-pods "$G_M"; then
			# The window recorded SETUP_FAILED; its probes cannot run against an unknown state.
			local scp
			for scp in "${SCOPINGS[@]}"; do g_skip SKIPPED_SERIES_STOPPED "$n_last" "$scp" probe "$OUTSIDE_NAMESPACES" "$om" "$G_M"; done
			continue
		fi
		if [[ -n "$stopped" ]]; then
			g_skip "$stopped" "$n_last" namespace outside "$OUTSIDE_NAMESPACES" "$om" "$G_M"
			local scp
			for scp in "${SCOPINGS[@]}"; do g_skip "$stopped" "$n_last" "$scp" probe "$OUTSIDE_NAMESPACES" "$om" "$G_M"; done
			continue
		fi
		G_CUR_SCOPE=namespace
		ox_state="$OUTSIDE_NAMESPACES"
		od_state="$om"
		n_disc="$n_last"
		[[ "$om" == labeled ]] && n_disc=$(( n_last + OUTSIDE_NAMESPACES ))
		g_probe_scopings "$n_last" "$ox_state" "$od_state" "$G_M" "$n_disc"
	done
	# M-sweep at the largest N: more measurement pods, every scoping again.
	local m
	for m in "${M_LIST[@]:1}"; do
		local mstop="${G_STOPPED:-}"
		((n_last > 0)) || mstop="${mstop:-SKIPPED_SERIES_STOPPED}"
		if [[ -z "$mstop" ]]; then
			echo "--- M-sweep: measurement pods ${G_M} -> ${m} (N=${n_last}) ---"
			if g001 --parts measurement --measurement-pods "$m" --namespace-count "$n_last" --sidecar-scoping namespace; then
				G_M="$m"
				if ((SETTLE_SEC > 0)); then sleep "$SETTLE_SEC"; fi
			else
				mstop=SETUP_FAILED
			fi
		fi
		if [[ -n "$mstop" ]]; then
			local scp
			for scp in "${SCOPINGS[@]}"; do g_skip "$mstop" "$n_last" "$scp" probe "$ox_state" "$od_state" "$m"; done
			continue
		fi
		g_probe_scopings "$n_last" "$ox_state" "$od_state" "$m" "$n_disc"
	done
	g_retire "$n_last"
}

# run_growth_fresh <mesh_size> <K> <series_index>: --growth fresh, one full deploy and
# cleanup per N x scoping cell (each cell its own series id, so a Terminating
# namespace of the previous cell never collides with the next).
run_growth_fresh() {
	G_MS="$1"
	G_K="$2"
	local base_sid="${SERIES_PREFIX}-$3" f=0 n scp timeout
	local -a active=("${CONTEXTS[@]:0:$G_MS}")
	G_ACTIVE_CSV="$(IFS=,; echo "${active[*]}")"
	G_REPLICAS="${REPLICA_COUNTS[0]}"
	[[ "$WORKLOAD_MODE" == config-only ]] && G_REPLICAS=1
	G_M="${M_LIST[0]}"
	G_STOPPED=""
	echo ""
	echo "########## Growth series ${base_sid} (fresh): mesh=${G_MS} K=${G_K} on ${active[*]} ##########"
	G_SID="$base_sid"
	g_series_start_count
	guard_baseline
	for n in "${NAMESPACE_COUNTS[@]}"; do
		for scp in "${SCOPINGS[@]}"; do
			f=$((f + 1))
			G_SID="${base_sid}f${f}"
			if ! guard_check "fresh N=${n} ${scp}" 1 1 1 0 "$(( n * G_K ))"; then
				g_skip SKIPPED_MEM_GUARD "$n" "$scp" deploy 0 none "$G_M"
				continue
			fi
			g_window deploy "$n" "$scp" 0 none "$G_M" "$SETTLE_SEC" SETUP_FAILED \
				--namespace-count "$n" --sidecar-scoping "$scp" --measurement-pods "$G_M" || true
			# Bounded wait (PL4/PL37), scaled to the namespaces this cell deletes. The cell
			# is verified gone or undiscovered before the next one (BACKLOG 9.3).
			timeout="$(awk -v n="$n" -v s="$NS_DELETE_SEC_PER_NS" -v t="${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300}" \
				'BEGIN { v = int(2 * n * s + 60); print (v > t ? v : t) }')"
			if ! g_retire_cmd "$G_SID" --timeout "$timeout"; then
				g_retire_failed "$G_SID" "$n"
				return 0
			fi
			if ((SETTLE_SEC > 0)); then
				echo "--- Post-cleanup settle (${SETTLE_SEC}s) ---" >&2
				sleep "$SETTLE_SEC"
			fi
		done
	done
}

# print_growth_plan: the series, steps and cells; object and namespace counts; the
# later namespace-deletion estimate. Printed before a live run and by --dry-run.
print_growth_plan() {
	local ms k idx=0 n prev probes pods peak_ns deletes=0 s_list="${SCOPINGS[*]}" x=0
	((${#OUTSIDE_PHASES[@]})) && x="$OUTSIDE_NAMESPACES"
	echo "--- Growth plan (${GROWTH_MODE}) ---"
	for ms in "${MESH_SIZES[@]}"; do
		for k in "${SPNS[@]}"; do
			idx=$((idx + 1))
			echo "  series ${SERIES_PREFIX}-${idx}: mesh=${ms} K=${k} workload=${WORKLOAD_MODE} on ${CONTEXTS[*]:0:$ms}"
			if [[ "$GROWTH_MODE" == fresh ]]; then
				for n in "${NAMESPACE_COUNTS[@]}"; do
					echo "    N=${n}: one deploy cell per scoping (${s_list}): ${n} namespaces, $(( n * k )) Services each, then 005 deletes them and waits"
					deletes=$(( deletes + n * ${#SCOPINGS[@]} ))
				done
				continue
			fi
			prev=0
			probes=0
			for n in "${NAMESPACE_COUNTS[@]}"; do
				echo "    step N=${n}: +$(( n - prev )) namespaces, +$(( (n - prev) * k )) Services, +$(( n - prev )) Sidecars; cells: grow (namespace), probe ${s_list}"
				prev="$n"
				probes=$(( probes + ${#SCOPINGS[@]} ))
			done
			if ((${#OUTSIDE_PHASES[@]})); then
				echo "    outside at N=${prev}: ${OUTSIDE_NAMESPACES} namespaces outside the mesh (+$(( OUTSIDE_NAMESPACES * k )) Services), phases ${OUTSIDE_PHASES[*]}; cells per phase: outside, probe ${s_list}"
				probes=$(( probes + ${#OUTSIDE_PHASES[@]} * ${#SCOPINGS[@]} ))
			fi
			if ((${#M_LIST[@]} > 1)); then
				echo "    M-sweep at N=${prev}: measurement pods ${M_LIST[*]:1}; cells per M: probe ${s_list}"
				probes=$(( probes + (${#M_LIST[@]} - 1) * ${#SCOPINGS[@]} ))
			fi
			if [[ "$WORKLOAD_MODE" == config-only ]]; then
				pods="${M_LIST[${#M_LIST[@]}-1]}"
				((pods > prev)) && pods="$prev"
				pods="${pods} measurement pod(s)"
			else
				pods="$(( prev * k * REPLICA_COUNTS[0] )) pod(s)"
			fi
			peak_ns=$(( prev + x + 1 ))
			echo "    peak on the measured member(s): ${peak_ns} namespaces, $(( peak_ns * k )) Services, up to $(( prev + 1 )) Sidecars, ${pods}; ${probes} probe namespace(s) created and retired"
			echo "    then: ${SERIES_RETIRE}"
			# Probe namespaces are deleted during the run (each one empty).
			deletes=$(( deletes + prev + x ))
		done
	done
	echo "  namespaces left to delete afterwards: ~${deletes}, about $(awk -v n="$deletes" -v s="$NS_DELETE_SEC_PER_NS" 'BEGIN { printf "%.0f", n * s / 60 }') min at ${NS_DELETE_SEC_PER_NS} s each (CONTROLPLANE_NS_DELETE_SEC_PER_NS; calibrate with the rate 005 prints)"
	echo ""
}

# run_growth_sweep: every series, in mesh-size then K order.
run_growth_sweep() {
	local ms k idx=0
	for ms in "${MESH_SIZES[@]}"; do
		for k in "${SPNS[@]}"; do
			idx=$((idx + 1))
			if [[ -n "$SWEEP_STOPPED" ]]; then
				echo "Series ${SERIES_PREFIX}-${idx} (mesh=${ms} K=${k}) not run: ${SWEEP_STOPPED}" >&2
				continue
			fi
			if [[ "$GROWTH_MODE" == fresh ]]; then
				run_growth_fresh "$ms" "$k" "$idx"
			else
				run_growth_series "$ms" "$k" "$idx"
			fi
		done
	done
}

# legacy_failed <status>: the current legacy cell's status row (the loop's ms sc rc nc
# scp tc), with the window kind the sweep measures.
legacy_failed() {
	emit_failed_row "$1" "$ms" "$sc" "$rc" "$nc" "$scp" "$tc" 0 pods "$(( sc * rc ))" 0 none "$LEGACY_WINDOW_KIND"
}

combo_idx=0
if ((GROWTH)); then
	print_growth_plan >&2
	if ! ((DRY_RUN)); then
		run_growth_sweep
	fi
	combo_idx="$CELL_IDX"
	((DRY_RUN)) && combo_idx="$MATRIX_SIZE"
else
for ms in "${MESH_SIZES[@]}"; do
	active_ctxs=("${CONTEXTS[@]:0:$ms}")
	active_csv=$(IFS=,; echo "${active_ctxs[*]}")
	for sc in "${SERVICE_COUNTS[@]}"; do
		for rc in "${REPLICA_COUNTS[@]}"; do
			for nc in "${NAMESPACE_COUNTS[@]}"; do
				for scp in "${SCOPINGS[@]}"; do
					# Innermost axis: a none/vsdr pair runs back to back on the same base cell.
					for tc in "${TRAFFIC_CONFIGS[@]}"; do
						combo_idx=$((combo_idx + 1))
						label="mesh=$ms svcs=$sc reps=$rc ns=$nc scope=$scp traffic=$tc"
						ns_pattern=$(fmt_ns_pattern "$nc")

						if ((DRY_RUN)); then
							printf "  [%2d/%2d] %s  (clusters: %s)  Namespaces: %s\n" \
								"$combo_idx" "$MATRIX_SIZE" "$label" "${active_ctxs[*]}" "$ns_pattern" >&2
							continue
						fi

						# Skip a combo already completed in the resumed sweep.
						if combo_already_done "$ms" "$sc" "$rc" "$nc" "$scp" "$tc"; then
							printf "  [%d/%d] %s — already has a valid row; skipping (resume)\n" \
								"$combo_idx" "$MATRIX_SIZE" "$label" >&2
							continue
						fi

						ensure_output_dir

						echo "=========================================="
						printf "  Sweep [%d/%d]: %s\n" "$combo_idx" "$MATRIX_SIZE" "$label"
						echo "  Clusters:   ${active_ctxs[*]}"
						echo "  Namespaces: ${ns_pattern}"
						echo "=========================================="
						echo ""

						STATE_DIR_COMBO="${OUTPUT_DIR}/state-combo-${combo_idx}"
						mkdir -p "$STATE_DIR_COMBO"
						# The cell's axes for 001 and 002; a split VS/DR apply measures window kind traffic.
						cell_args=(--contexts "$active_csv" --service-count "$sc" --replicas "$rc" --namespace-count "$nc"
							--sidecar-scoping "$scp" --traffic-config "$tc" --vsdr-every "$VSDR_EVERY" --vsdr-subsets "$VSDR_SUBSETS")
						m002_args=("${cell_args[@]}" --mesh-size "$ms" --window-kind "$LEGACY_WINDOW_KIND" --settle "$SETTLE_SEC" --run-id "$RUN_ID")

						if [[ "$VSDR_APPLY" == split ]]; then
							# Phase 0 (outside the window): the namespaces, Services, Sidecars and the
							# per-subset Deployments, Ready before the baseline (BACKLOG 9.11).
							echo "--- Deploying workloads before the window (split apply, scoping=$scp, traffic=$tc) ---"
							if ! "$SCRIPT_DIR/001-setup-controlplane-test.sh" "${cell_args[@]}" --parts workloads; then
								echo "warn: [$combo_idx/$MATRIX_SIZE] workloads setup failed for '$label'; recording SETUP_FAILED row and continuing" >&2
								legacy_failed SETUP_FAILED
								"$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
									echo "warn: cleanup after setup failure also reported failure for '$label'" >&2
								rm -rf "$STATE_DIR_COMBO"
								if (( SETTLE_SEC > 0 )); then sleep "$SETTLE_SEC"; fi
								continue
							fi
							# Let the workload pushes finish before the baseline.
							if (( SETTLE_SEC > 0 )); then
								echo "--- Settling ${SETTLE_SEC}s after the workloads before the baseline ---"
								sleep "$SETTLE_SEC"
							fi
							echo ""
						fi

						echo "--- Baseline metrics scrape (phase 1/3) ---"
						if ! "$SCRIPT_DIR/002-collect-resource-metrics.sh" --phase baseline --state-dir "$STATE_DIR_COMBO" "${m002_args[@]}"; then
							# Baseline failed: record the combo, clean up, move on.
							echo "warn: [$combo_idx/$MATRIX_SIZE] baseline probe failed for '$label'; recording PROBE_FAILED row and continuing" >&2
							legacy_failed PROBE_FAILED
							"$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
								echo "warn: cleanup after baseline failure also reported failure for '$label'" >&2
							rm -rf "$STATE_DIR_COMBO"
							if (( SETTLE_SEC > 0 )); then sleep "$SETTLE_SEC"; fi
							continue
						fi
						echo ""

						start_peak_metrics_poller "$STATE_DIR_COMBO"

						# Setup failed: stop the poller, record SETUP_FAILED, clean up, move on.
						setup_ok=1
						if [[ "$VSDR_APPLY" == split ]]; then
							if [[ "$tc" == vsdr ]]; then
								echo "--- Applying the VirtualServices and DestinationRules (phase 2/3, split apply) ---"
								"$SCRIPT_DIR/001-setup-controlplane-test.sh" "${cell_args[@]}" --parts traffic || setup_ok=0
							else
								echo "--- Phase 2/3: nothing to apply (traffic none, split apply: an idle window over the same workloads) ---"
							fi
						else
							echo "--- Deploying workloads (phase 2/3, scoping=$scp, traffic=$tc) ---"
							"$SCRIPT_DIR/001-setup-controlplane-test.sh" "${cell_args[@]}" || setup_ok=0
						fi
						if ! ((setup_ok)); then
							echo "warn: [$combo_idx/$MATRIX_SIZE] setup failed for '$label'; recording SETUP_FAILED row and continuing" >&2
							stop_peak_metrics_poller   # MUST stop before continue — poller runs in background
							legacy_failed SETUP_FAILED
							"$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
								echo "warn: cleanup after setup failure also reported failure for '$label'" >&2
							rm -rf "$STATE_DIR_COMBO"
							if (( SETTLE_SEC > 0 )); then sleep "$SETTLE_SEC"; fi
							continue
						fi
						echo ""

						if (( SETTLE_SEC > 0 )); then
							echo "--- Settling ${SETTLE_SEC}s for steady-state before final scrape ---"
							sleep "$SETTLE_SEC"
							echo ""
						fi

						stop_peak_metrics_poller

						echo "--- Final metrics scrape + emit (phase 3/3) — window covers baseline → apply → settle ---"
						if ! "$SCRIPT_DIR/002-collect-resource-metrics.sh" --phase final --state-dir "$STATE_DIR_COMBO" "${m002_args[@]}" \
							--config-dump-samples "$CONFIG_DUMP_SAMPLES" --output-dir "$OUTPUT_DIR"; then
							# Final scrape failed: record PROBE_FAILED; cleanup still runs below.
							echo "warn: [$combo_idx/$MATRIX_SIZE] final probe failed for '$label'; recording PROBE_FAILED row and continuing" >&2
							legacy_failed PROBE_FAILED
						fi
						rm -rf "$STATE_DIR_COMBO"
						echo ""

						echo "--- Cleaning up ---"
						# 005 waits (bounded) for namespace termination. A failure only warns:
						# the next 001 waits for any leftover namespace before applying.
						"$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
							echo "warn: [$combo_idx/$MATRIX_SIZE] cleanup reported failure for '$label'; next setup waits for the namespace to clear" >&2

						# Post-cleanup settle: when 005 deletes the test namespace,
						# istiod re-pushes a broader (no-Sidecar) config to remaining
						# proxies. Without this sleep, the next combo's baseline scrape
						# lands inside that push storm.
						if (( SETTLE_SEC > 0 )); then
							echo "--- Post-cleanup settle (${SETTLE_SEC}s) ---" >&2
							sleep "$SETTLE_SEC"
						fi
						echo ""
					done
				done
			done
		done
	done
done
fi

if ((DRY_RUN)); then
	echo "" >&2
	echo "Dry-run complete. $combo_idx combinations enumerated; no clusters touched." >&2
	exit 0
fi

echo "=========================================="
if [[ -n "$SWEEP_STOPPED" ]]; then
	echo "  Sweep STOPPED early ($combo_idx cells; see the ERROR below)"
else
	echo "  Sweep finished ($combo_idx combinations)"
fi
echo "=========================================="
echo ""
echo "Generating report..."
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$OUTPUT_DIR"

MD_FILE="${OUTPUT_DIR}/sweep-${RUN_ID}.md"
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$OUTPUT_DIR" --format markdown > "$MD_FILE"
echo "Markdown summary written to $MD_FILE"

CHARTS_FILE="${OUTPUT_DIR}/sweep-charts-${RUN_ID}.md"
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$OUTPUT_DIR" --format charts > "$CHARTS_FILE"
echo "Charts written to $CHARTS_FILE"

# Campaign scale envelope (docs/campaigns/TEMPLATE.md), best-effort: a render
# failure warns but never fails the sweep.
ENVELOPE_FILE="${OUTPUT_DIR}/scale-envelope-${RUN_ID}.md"
# Keep the render's stderr so the warning shows the actual reason.
ENVELOPE_ERR="$(mktemp)"
# Subshell: render_scale_envelope uses die(), which must not abort the sweep.
if ( render_scale_envelope "$OUTPUT_DIR" "$SCRIPT_DIR/004-report-results.sh" \
		"$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}" ) > "$ENVELOPE_FILE" 2>"$ENVELOPE_ERR"; then
	echo "Scale envelope written to $ENVELOPE_FILE"
else
	rm -f "$ENVELOPE_FILE"
	echo "warning: scale-envelope generation failed (sweep data is safe above):" >&2
	sed 's/^/  /' "$ENVELOPE_ERR" >&2
fi
rm -f "$ENVELOPE_ERR"

# R19: every cell without a measurement has the status row emit_failed_row wrote (its
# context column is the status); count them by reason. The RETIRE_FAILED stop (exit 1)
# wins over 4 (some cells failed).
FAILED_CELLS=()
mapfile -t FAILED_CELLS < <(awk -F'\t' '$1 != "timestamp" && !/^#/ && $2 ~ /^(SETUP_FAILED|PROBE_FAILED|GROW_FAILED|SWITCH_FAILED|SKIPPED_MEM_GUARD|SKIPPED_SERIES_STOPPED|RETIRE_FAILED)$/ { print $2 }' \
	"${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv" 2>/dev/null || true)
outcome_rc=0 stop_args=()
[[ -z "$SWEEP_STOPPED" ]] || stop_args=(--stopped 1)
sweep_outcome ${stop_args[@]+"${stop_args[@]}"} "$MATRIX_SIZE" ${FAILED_CELLS[@]+"${FAILED_CELLS[@]}"} || outcome_rc=$?
if [[ -n "$SWEEP_STOPPED" ]]; then
	echo "" >&2
	echo "ERROR: the sweep stopped early: ${SWEEP_STOPPED} (RETIRE_FAILED row in the report). The cells above it are valid; later series did not run." >&2
	exit 1
fi
exit "$outcome_rc"

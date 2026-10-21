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

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# Loud ERR trap for unexpected aborts; per-combo failures become row statuses.
# sweep_err_trap prints the FATAL line and keeps it as the stop reason a sweep that
# aborts after its start records (the EXIT trap sweep_start sets).
trap 'sweep_err_trap "$?" "$LINENO" "$BASH_COMMAND"' ERR
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
source "${ROOT}/tests/lib/preamble.sh"  # probe_kube_versions for the pre-created preamble
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/platform.sh"  # platform_probe, platform_preamble_lines (the platform record)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/reach.sh"  # reach_sanitize (platform_probe's warnings)
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
CONFIG_DUMP_SAMPLES="${CONTROLPLANE_CONFIG_DUMP_SAMPLES:-3}"
OUTPUT_DIR_BASE="$(config_repo_path "${CONTROLPLANE_RESULTS_DIR}")"
SETTLE_SEC="${CONTROLPLANE_SETTLE_SEC:-60}"
DRY_RUN=0
METRICS_API_STATUS="unknown"  # set by metrics_preflight; recorded in the preamble
FORCE_LARGE_MATRIX=0
MAX_MATRIX="${CONTROLPLANE_MAX_MATRIX:-64}"
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
EWGW_BURST="${CONTROLPLANE_EWGW_BURST_FACTOR:-2.5}"
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
explicit scoping.
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
  guard set (and stops when one has no kube context of its name; with
  --mem-guard-contexts it warns), and refuses to start
  while a controlplane-test namespace of an earlier run is still discovered.

Other:
  --config-dump-samples N     Random pods per cluster to exec /config_dump on
                              (default: $CONFIG_DUMP_SAMPLES; 0 disables).
  --settle SEC                Seconds for the delta-window between baseline
                              and final scrape (default: $SETTLE_SEC).
  --output-dir DIR            Results base directory; each sweep gets a
                              sweep-<RUN_ID>/ subdir under it
                              (default: ${CONTROLPLANE_RESULTS_DIR}).
  --force-large-matrix        Allow matrix > $MAX_MATRIX combinations (default: refuse).
  --dry-run                   Print plan and matrix, then exit (no cluster is read: it
                              says what a live run's leftover check would do).
  -h, --help                  Show this help.

Exit codes:
  0  every cell ran; rows with istiod_restarted 1/unknown are measurement outcomes,
     counted in the report's n_total and left out of n_valid
  1  the sweep stopped: a bad flag or precondition, an unexpected error, or a series that
     could not be retired (RETIRE_FAILED; the reports are written)
  4  the sweep finished and wrote its reports, but N cells failed (a status row
     instead of a measurement: SETUP_FAILED, PROBE_FAILED, GROW_FAILED, SWITCH_FAILED,
     or INTERRUPTED, the cell a run that stopped or was interrupted was in, unless every
     member's rows were written; or a legacy cell whose rows cover fewer members than
     its mesh size, or a member with fewer rows than its window's WINDOW_ROWS line names
     (in rows an older harness wrote one by one: than its istiod replicas), INCOMPLETE:
     cut short while its rows were written; stderr ends with "N of M cells failed" by
     reason), or the Istio version or active revision changed during the sweep (read
     again at its end), or the generation of a member's Istio CR or active
     IstioRevision moved at the same version (an edit of the Istio CR, or Sail rendering
     it again), or the harness (a file under tests/, config/, charts/ or terraform/)
     changed during the sweep (HARNESS_SHA read at its start and its end), or the cells
     could not be counted (TOTAL=unknown). A cell counts once, by its last row: a
     status row fails it, with that reason; a measurement does not. M covers every cell of
     the matrix; one without a row fails as NOT_RUN. Cells the memory guard skipped
     (SKIPPED_MEM_GUARD, SKIPPED_SERIES_STOPPED) are counted apart, on stdout, and do
     not make it 4. The outcome is also in sweep-outcome.txt, the markdown report and
     the scale envelope.
     From its start until then, sweep-outcome.txt says STATUS=running: a sweep killed
     outright keeps it, and its reports say so; one interrupted (SIGHUP, Ctrl-C,
     SIGTERM: exit 129, 130, 143) records STATUS=interrupted with the signal and its
     time; one that stops on an error after its start (exit 1) STATUS=stopped with its
     reason. After any of them, run 005-cleanup.sh, then the sweep again into a new dir
     with the mesh sizes it did not finish.
     On a signal, the running step's process group gets SIGTERM, and SIGKILL
     SWEEP_STOP_GRACE_SEC later. While a run goes on, the sweep dir holds its lock
     (.sweep.lock, its PID).

Environment:
  ISTIO_VERSION_CHECK (fail, the default, or warn): before any change, every member's
  Istio version (its active IstioRevision's) is read; one unknown, members that differ, a
  version other than ISTIO_VERSION, or a member still not ready stops the run, or under
  warn is warned about and recorded. ISTIO_VERSION_READY_WAIT_SEC (60): how long the one
  wait for members not ready may take.
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
$(platform_help_lines all)
  SWEEP_STOP_GRACE_SEC (30): how long a signalled sweep waits for its step's processes
  before SIGKILL. Environment only (config/options.env).

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
		shift 2
		;;
	--vsdr-subsets)
		[[ -n "${2:-}" ]] || die "--vsdr-subsets requires a value"
		VSDR_SUBSETS="$2"
		shift 2
		;;
	--vsdr-apply)
		[[ -n "${2:-}" ]] || die "--vsdr-apply requires a value"
		VSDR_APPLY="$2"
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

platform_validate
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
# row would carry the sweep's --service-counts value: a flat, mislabelled scaling curve.
# Refused in every mode, before any cluster change; standalone 001 keeps auto.
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

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_contexts "$CONTEXTS_CSV" CONTEXTS --contexts
else
	split_contexts "$SETUP_CONTEXTS" CONTEXTS SETUP_CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"
# Each member under a name of its own in the platform record (platform_members_check): refused
# here, before any cluster call, in a --dry-run too.
platform_members_check "${CONTEXTS[@]}"

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
	for om in ${_omodes[@]+"${_omodes[@]}"}; do
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
	# Each value of an axis is one set of cells; a repeated one would run them twice
	# under one key (the outcome counts it once), as growth refuses.
	for _ax in "--mesh-sizes:${MESH_SIZES[*]}" "--service-counts:${SERVICE_COUNTS[*]}" \
		"--replica-counts:${REPLICA_COUNTS[*]}" "--namespace-counts:${NAMESPACE_COUNTS[*]}" \
		"--sidecar-scopings:${SCOPINGS[*]}" "--traffic-configs:${TRAFFIC_CONFIGS[*]}"; do
		_axv="${_ax#*:}"
		[[ "$(tr ' ' '\n' <<<"$_axv" | sort -u | grep -c .)" == "$(tr ' ' '\n' <<<"$_axv" | grep -c .)" ]] \
			|| die "${_ax%%:*} repeats a value (${_axv// /,}): each value is one set of cells; list it once"
	done
	# Sizes the leftover cleanup's --timeout (legacy_leftover_preflight).
	[[ "$NS_DELETE_SEC_PER_NS" =~ ^([0-9]+(\.[0-9]+)?|\.[0-9]+)$ ]] || die "CONTROLPLANE_NS_DELETE_SEC_PER_NS must be a non-negative number (got: $NS_DELETE_SEC_PER_NS)"
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

# A fresh RUN_ID and sweep-<RUN_ID>/ subdir.
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OUTPUT_DIR="${OUTPUT_DIR_BASE}/sweep-${RUN_ID}"
# The harness at this run's start, for the preambles it writes and its sweep-outcome.txt;
# its results under the output dir do not count, for its steps either (HARNESS_SHA_EXCLUDE:
# each step records the harness it reads). sweep_finish reads it again: a harness that
# changed during the sweep is a problem in its outcome (exit 4).
HARNESS_SHA_EXCLUDE="$OUTPUT_DIR_BASE"
[[ "$HARNESS_SHA_EXCLUDE" == /* ]] || HARNESS_SHA_EXCLUDE="${PWD%/}/${HARNESS_SHA_EXCLUDE}"
export HARNESS_SHA_EXCLUDE
HARNESS_SHA="$(harness_sha)"

# matrix_cell_keys: this run's legacy matrix, one tab-separated key per line.
matrix_cell_keys() {
	local ms sc rc nc scp tc
	for ms in "${MESH_SIZES[@]}"; do for sc in "${SERVICE_COUNTS[@]}"; do for rc in "${REPLICA_COUNTS[@]}"; do
		for nc in "${NAMESPACE_COUNTS[@]}"; do for scp in "${SCOPINGS[@]}"; do for tc in "${TRAFFIC_CONFIGS[@]}"; do
			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ms" "$sc" "$rc" "$nc" "$scp" "$tc" "$LEGACY_WINDOW_KIND"
		done; done; done
	done; done; done
}

# The 66-column TSV schema header. 002 writes the same literal when it runs
# standalone; tests/lib/test/preamble.bats checks that the two are identical.
CONTROLPLANE_TSV_HEADER="timestamp\tcontext\tmesh_size\tservice_count\treplicas\tnamespace_count\tsidecar_scoping\tistiod_mem_mi\tconvergence_p50_ms\tconvergence_p99_ms\tqueue_p50_ms\tqueue_p99_ms\txds_pushes_delta\txds_pushes_rate\txds_pushes_cds\txds_pushes_eds\txds_pushes_lds\txds_pushes_rds\txds_pushes_nds\tk8s_events_delta\tk8s_events_rate\tconnected_proxies\tconfig_size_avg_bytes\tsidecar_config_bytes_avg\tsidecar_config_bytes_p50\tsidecar_config_bytes_max\tsidecar_config_bytes_samples\tscrape_window_sec\tscrape_skew_ms\tsettle_sec\tistiod_restarted\tistiod_cpu_m_delta\tgo_heap_alloc_mi\tgo_heap_inuse_mi\tistiod_cpu_pct_of_limit\tistiod_mem_pct_of_limit\tnode_cpu_pct\tnode_mem_pct\tpods_scheduled\tpods_allocatable\tcluster_connected_proxies\tsidecar_pods\tproxy_check\ttraffic_config\tvsdr_services\tistiod_virt_services\tpush_time_avg_ms\tpushcontext_init_avg_ms\tsidecar_clusters_avg\tsidecar_cds_bytes_avg\tsidecar_rds_bytes_avg\tservices_per_namespace\tworkload_mode\tmeasurement_pods\toutside_namespaces\toutside_discovery\twindow_kind\tistiod_services\tistiod_cpu_s_delta\tsidecar_mem_mi_avg\tgateway_clusters_max\tgateway_mem_mi_max\troot_cert_configmaps\tgateway_physical_mi_max\tgateway_ws_mi_max\tleftover_test_namespaces"

# Each DestinationRule subset needs at least one pod, at every replica count in the sweep.
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
	local kver
	kver="$(probe_kube_versions "$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}")"
	# Capacity provenance (read-only, source context; `unknown` on failure). These
	# are the report's denominators for the "Achieved scale vs capacity" block.
	local src_ctx="${CONTEXTS[0]}"
	local node_alloc_cpu_m="unknown" node_alloc_mem_mi="unknown"
	local istiod_cpu_limit_m="unknown" istiod_mem_limit_mi="unknown"
	local kv
	# shellcheck disable=SC2207
	local -a nt_kv=($(cap_node_totals "$src_ctx" "${KUBECTL[@]}"))
	for kv in ${nt_kv[@]+"${nt_kv[@]}"}; do
		case "$kv" in
			cpu_m=*) node_alloc_cpu_m="${kv#cpu_m=}" ;;
			mem_mi=*) node_alloc_mem_mi="${kv#mem_mi=}" ;;
		esac
	done
	# shellcheck disable=SC2207
	local -a il_kv=($(cap_istiod_limits "$src_ctx" "${KUBECTL[@]}"))
	for kv in ${il_kv[@]+"${il_kv[@]}"}; do
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
		echo "# HARNESS_SHA=${HARNESS_SHA}"
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
		platform_preamble_lines "$(IFS=,; echo "${CONTEXTS[*]}")"
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
		for kv in ${nt[@]+"${nt[@]}"}; do
			case "$kv" in
				cpu_m=*) alloc_cpu_m="${kv#cpu_m=}" ;;
				names=*) workers="${kv#names=}" ;;
			esac
		done
		if ! [[ "$alloc_cpu_m" =~ ^[0-9]+$ ]]; then
			echo "  $ctx: WARN: node allocatable CPU unreadable (the node list failed, or no node counts as a worker: infra and tainted control-plane/master nodes are left out); left out of the fit estimate." >&2
			continue
		fi
		# shellcheck disable=SC2207
		local -a rq=($(cap_requested "$ctx" "$workers" "app.kubernetes.io/instance=controlplane-test" "${KUBECTL[@]}"))
		for kv in ${rq[@]+"${rq[@]}"}; do case "$kv" in cpu_m=*) req_cpu_m="${kv#cpu_m=}" ;; esac; done
		if [[ "$req_cpu_m" =~ ^[0-9]+$ ]]; then
			free_cpu_m=$(( alloc_cpu_m - req_cpu_m ))
			(( free_cpu_m < 0 )) && free_cpu_m=0
			echo "  $ctx: node alloc CPU ~$(cores "$alloc_cpu_m") cores; requested by other pods ~$(cores "$req_cpu_m") -> ~$(cores "$free_cpu_m") cores free" >&2
		else
			# shellcheck disable=SC2207
			local -a il=($(cap_istiod_limits "$ctx" "${KUBECTL[@]}"))
			for kv in ${il[@]+"${il[@]}"}; do
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
		echo "  WARN: node allocatable CPU unreadable on every context (the node list failed, or no node counts as a worker); cannot estimate services-that-fit." >&2
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
	# A window write cut short (a full disk, a step killed while it appended) leaves the
	# last line without its newline: end it, so this row is not merged onto a cut row (the
	# merged line would read as that member's measurement, and the cell as done).
	tsv_end_line "$tsv" || die "could not end the last line of ${tsv} (a write cut short left it without a newline), so the cell's ${status} row cannot start a line of its own. Fix the sweep dir (permissions, disk space)."
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
		split_contexts "$MEM_GUARD_CONTEXTS_CSV" GUARD_CONTEXTS "--mem-guard-contexts (or CONTROLPLANE_MEM_GUARD_CONTEXTS)"
	else
		_setup_ctxs=()
		split_csv "${SETUP_CONTEXTS:-}" _setup_ctxs
		declare -A _gseen=()
		for _c in "${CONTEXTS[@]}" ${_setup_ctxs[@]+"${_setup_ctxs[@]}"}; do
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
		echo "WARNING: memory guard: mesh member(s) ${missing[*]} (named by the Istio remote secrets) are not in --mem-guard-contexts (${MEM_GUARD_CONTEXTS_CSV}); their istiod and gateways are not guarded unless a context of another name covers them. A member that left the mesh stays named until its remote secret is deleted (README.md, \"Grow the mesh\")." >&2
		return 0
	fi
	die "memory guard: mesh member(s) ${missing[*]} (named by the Istio remote secrets) have no kube context of that name, so their istiod and gateways could not be guarded. A member that left the mesh stays named until its remote secret is deleted from every other member: their wiring gate reads NotReady and prints the delete command (README.md, \"Grow the mesh\"). Otherwise pass --mem-guard-contexts with a context for every member (or the subset you accept), or set MEM_STOP_PCT 0 to run unguarded."
}

# leftover_preflight: before a live growth sweep, count the controlplane-test namespaces
# on every measured context (BACKLOG 9.10: thousands of undiscovered leftovers stayed in
# istiod's informers and inflated later series). A discovered one stops the sweep (it
# would add its Services to every cell); undiscovered ones above
# CONTROLPLANE_LEFTOVER_NS_WARN warn. LEFTOVER_AT_START (<ctx>=<total>/<discovered>,...)
# goes into the preamble.
LEFTOVER_AT_START="n/a"
leftover_preflight() {
	if ((DRY_RUN)); then
		((GROWTH)) || echo "Leftover check: a live run counts the controlplane-test namespaces on the members (and on the mesh members their Istio remote secrets name), deletes those an earlier run left on the --contexts members through 005-cleanup.sh before the first cell, then waits --settle (${SETTLE_SEC}s) before it; it deletes nothing on the other mesh members, and stops first when they hold some; a dry run reads no cluster." >&2
		return 0
	fi
	((${#KUBECTL[@]})) || return 0
	if ! ((GROWTH)); then
		legacy_leftover_preflight
		return 0
	fi
	local c kv total disc out="" bad=""
	for c in "${CONTEXTS[@]:0:${MAX_MESH_SIZE}}"; do
		kv="$(growth_test_ns_counts "$c" "${KUBECTL[@]}")"
		total="$(kv_value total "$kv")"
		disc="$(kv_value discovered "$kv")"
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

# leftover_counts <dir> <ctx>...: the controlplane-test namespaces on every context, counted at
# once (one background list each, growth_test_ns_counts, into <dir>), then one line per
# context in order: "<ctx>\t<total>" (N/A: not read). Nothing here stops the sweep.
leftover_counts() {
	local dir="$1" i=0 ctx pid
	shift
	local -a lc_pids=()
	mkdir -p "$dir" 2>/dev/null || true
	for ctx in "$@"; do
		(kv_value total "$(growth_test_ns_counts "$ctx" "${KUBECTL[@]}")" > "${dir}/${i}" 2>/dev/null) &
		lc_pids+=("$!")
		i=$((i + 1))
	done
	for pid in ${lc_pids[@]+"${lc_pids[@]}"}; do wait "$pid" 2>/dev/null || true; done
	i=0
	for ctx in "$@"; do
		printf '%s\t%s\n' "$ctx" "$(cat "${dir}/${i}" 2>/dev/null || echo N/A)"
		i=$((i + 1))
	done
}

# legacy_leftover_preflight: a legacy cell deploys its controlplane-test namespaces and
# deletes them at its end (005-cleanup.sh deletes every one, growth series' kept ones
# included), so any found before the first cell were left by a run cut short (or a growth
# series), and a cell would measure on top of them: a re-run cell's apply finds its objects
# in place (no push storm in its window, a valid row of almost nothing), another cell counts
# their Services. Every cell's cleanup deletes them anyway, so this deletes them once more,
# before the first cell (005-cleanup.sh, so the operator runs one command, not two), then
# counts again: any still there stop the sweep before its start, as a precondition (nothing
# measured yet). A member whose namespaces cannot be counted only warns. It reads the
# measured members (--contexts, up to the largest mesh size) and the other mesh members
# their Istio remote secrets name that have a kube context of that name (their Services
# reach every member's istiod through remote discovery, multi-primary); a member without
# one is named in a warning. Every count runs on all of them at once. It deletes only on
# members the operator named (--contexts): leftovers on another mesh member stop the sweep
# before any change, with the 005 command for them. LEFTOVER_AT_START records the counts
# (and that 005 deleted them), for the preamble; the record says so too (a NOTE). When it
# deleted anything, the first cell waits SETTLE_SEC first, as after every cell's cleanup
# (LEFTOVER_DELETED): its baseline must not land inside the deletion's push storm.
LEFTOVER_DELETED=0
legacy_leftover_preflight() {
	local ctx total m members found="" found_kv="" unread="" csv max=0 sized
	local -a lp_members=("${CONTEXTS[@]:0:${MAX_MESH_SIZE}}") lp_nokube=() lp_del=() lp_other=()
	local -A lp_have=() lp_known=() lp_given=()
	local other="" omax=0
	for ctx in "${lp_members[@]}"; do lp_have[$ctx]=1; done
	for ctx in "${CONTEXTS[@]}"; do lp_given[$ctx]=1; done
	while IFS= read -r ctx; do [[ -z "$ctx" ]] || lp_known[$ctx]=1; done < <("${KUBECTL[@]}" config get-contexts -o name 2>/dev/null || true)
	# The mesh members the measured ones' remote secrets name, read on all of them at once.
	local i=0 pid
	local -a lp_pids=()
	mkdir -p "${SWEEP_TMP}/mesh-members" 2>/dev/null || true
	for ctx in "${CONTEXTS[@]:0:${MAX_MESH_SIZE}}"; do
		(growth_mesh_members "$ctx" "${KUBECTL[@]}" > "${SWEEP_TMP}/mesh-members/${i}" 2>/dev/null) &
		lp_pids+=("$!")
		i=$((i + 1))
	done
	for pid in ${lp_pids[@]+"${lp_pids[@]}"}; do wait "$pid" 2>/dev/null || true; done
	for ((i = 0; i < MAX_MESH_SIZE; i++)); do
		members="$(cat "${SWEEP_TMP}/mesh-members/${i}" 2>/dev/null || true)"
		while IFS= read -r m; do
			[[ -n "$m" && -z "${lp_have[$m]:-}" ]] || continue
			lp_have[$m]=1
			if [[ -n "${lp_known[$m]:-}" ]]; then lp_members+=("$m"); else lp_nokube+=("$m"); fi
		done <<<"$members"
	done
	((${#lp_members[@]} == MAX_MESH_SIZE)) || echo "Leftover check: also counts on mesh member(s) ${lp_members[*]:${MAX_MESH_SIZE}} (named by the Istio remote secrets, not measured): their Services reach every member's istiod" >&2
	((${#lp_nokube[@]} == 0)) || echo "warn: mesh member(s) ${lp_nokube[*]} (named by the Istio remote secrets) have no kube context of that name, so their controlplane-test namespaces are not counted, though their Services reach every member's istiod; check each with: kubectl --context <its context> get namespaces -l app.kubernetes.io/instance=controlplane-test" >&2
	while IFS=$'\t' read -r ctx total; do
		if ! [[ "$total" =~ ^[0-9]+$ ]]; then
			unread="${unread:+${unread}, }${ctx}"
		elif ((total > 0)) && [[ -z "${lp_given[$ctx]:-}" ]]; then
			other="${other:+${other}, }${ctx}: ${total}"
			lp_other+=("$ctx")
			if ((total > omax)); then omax="$total"; fi
		elif ((total > 0)); then
			found="${found:+${found}, }${ctx}: ${total}"
			found_kv="${found_kv:+${found_kv},}${ctx}=${total}"
			lp_del+=("$ctx")
			if ((total > max)); then max="$total"; fi
		fi
	done < <(leftover_counts "${SWEEP_TMP}/leftover-1" "${lp_members[@]}")
	# Not on a cluster the operator did not name: those stop the sweep, before any change.
	if [[ -n "$other" ]]; then
		sized="$(awk -v n="$omax" -v r="$NS_DELETE_SEC_PER_NS" -v d="${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300}" 'BEGIN { t = int(n * r + 0.999); if (t < d + 0) t = d + 0; print t }')"
		die "controlplane-test namespaces an earlier run left are on mesh members outside --contexts (${other}; named by the Istio remote secrets of the measured members): their Services reach every member's istiod, so a cell would measure on top of them. The sweep deletes leftovers only on the --contexts members, so nothing was deleted or measured. Delete these with: ${SCRIPT_DIR}/005-cleanup.sh --contexts $(IFS=,; echo "${lp_other[*]}") --timeout ${sized} (about ${NS_DELETE_SEC_PER_NS} s per namespace), then run this command again${found:+ (it then deletes those on the --contexts members: ${found})}."
	fi
	[[ -z "$unread" ]] || echo "warn: could not count the controlplane-test namespaces on ${unread}, so a cell there may run on top of an earlier run's leftovers; check with: kubectl --context <ctx> get namespaces -l app.kubernetes.io/instance=controlplane-test" >&2
	if [[ -z "$found" ]]; then
		LEFTOVER_AT_START="none"
		[[ -z "$unread" ]] || LEFTOVER_AT_START="none counted (unread: ${unread// /})"
		return 0
	fi
	csv="$(IFS=,; echo "${lp_del[*]}")"
	# About 1 s per namespace (CONTROLPLANE_NS_DELETE_SEC_PER_NS), and never less than
	# 005's own default: the members are cleaned at once, so the largest count sizes it.
	sized="$(awk -v n="$max" -v r="$NS_DELETE_SEC_PER_NS" -v d="${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300}" 'BEGIN { t = int(n * r + 0.999); if (t < d + 0) t = d + 0; print t }')"
	echo "note: controlplane-test namespaces are left on the members (${found}) by a run cut short or a growth series. A cell would measure on top of them, and every cell deletes them at its end anyway, so 005-cleanup.sh deletes them now, before the first cell. Its --timeout is ${sized} s (about ${NS_DELETE_SEC_PER_NS} s per namespace, ${max} on the fullest member), and the first cell then waits ${SETTLE_SEC}s for the deletion's pushes to settle." >&2
	sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$csv" --timeout "$sized" \
		|| echo "warn: 005-cleanup.sh reported a failure; counting the namespaces again" >&2
	LEFTOVER_DELETED=1
	LEFTOVER_AT_START="${found_kv} (deleted by 005-cleanup.sh before the first cell)"
	sweep_note "the leftover check found controlplane-test namespaces an earlier run left (${found}) and 005-cleanup.sh deleted them before the first cell, which waited SETTLE_SEC=${SETTLE_SEC}s after"
	found=""
	while IFS=$'\t' read -r ctx total; do
		if [[ "$total" =~ ^[0-9]+$ ]] && ((total > 0)); then
			found="${found:+${found}, }${ctx}: ${total}"
		fi
	done < <(leftover_counts "${SWEEP_TMP}/leftover-2" "${lp_members[@]}")
	[[ -z "$found" ]] || die "controlplane-test namespaces are still on the members after 005-cleanup.sh (${found}: still Terminating, or the delete failed), and a cell would measure on top of them; nothing was measured. Run ${SCRIPT_DIR}/005-cleanup.sh --contexts ${csv} until it leaves none, then run this command again. Give it --timeout ${sized} (about ${NS_DELETE_SEC_PER_NS} s per namespace, ${max} on the fullest member; its default is ${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300} s)."
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
# instead of recording every sample N/A. The plan (--dry-run) does not need it.
((DRY_RUN)) || require_timeout
# SWEEP_TMP: this run's scratch files (the cell count, the leftover counts, the memory
# guard's scrapes, the envelope's stderr), in one dir that this trap removes until
# sweep_start's EXIT trap replaces it: then cp_sweep_cleanup (a sweep that ends before its
# end) or the sweep's end removes it.
SWEEP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/controlplane-sweep.XXXXXX")" \
	|| die "could not create a scratch dir under ${TMPDIR:-/tmp}; nothing was run."
trap 'rm -rf "$SWEEP_TMP" 2>/dev/null || true' EXIT
# The Istio version every member runs, read once before any cluster change and
# exported, so 001, 002 and 005 record it (ISTIO_VERSION_CHECK=fail stops here on a
# mismatch). --dry-run reads nothing: the pin, ISTIO_VERSION_SOURCE=pin.
istio_version_resolve "$(IFS=,; echo "${CONTEXTS[*]}")" "$DRY_RUN" ${KUBECTL[@]+"${KUBECTL[@]}"}
echo "Istio version:     $(istio_version_label)" >&2
# The status rows of a cell (CP_CELL_AWK cp_cell_state reads a cell's state by them, by the
# rule 004 also uses). INTERRUPTED: the row cp_sweep_cleanup writes for the cell in progress
# when the sweep is interrupted or stops (CELL_IN_PROGRESS).
CELL_STATUS_RE='^(SETUP_FAILED|PROBE_FAILED|GROW_FAILED|SWITCH_FAILED|SKIPPED_MEM_GUARD|SKIPPED_SERIES_STOPPED|RETIRE_FAILED|INTERRUPTED)$'
# ensure_output_dir: create the sweep dir and say where it is.
ensure_output_dir() {
	[[ -d "$OUTPUT_DIR" ]] && return 0
	mkdir -p "$OUTPUT_DIR"
	echo "Output directory: $OUTPUT_DIR" >&2
}
# The platform record of every member, read once before the first cell: each 002 reads it from
# platform-record.txt in the sweep dir (platform_probe_share), the pre-created preamble writes it
# (tests/lib/platform.sh).
if ! ((DRY_RUN)); then
	platform_probe "$(IFS=,; echo "${CONTEXTS[*]}")"
	ensure_output_dir
	platform_probe_share "$OUTPUT_DIR"
	platform_start_warnings "$(IFS=,; echo "${CONTEXTS[*]}")"
fi
# The cleanup the console names when the sweep ends before its end (cp_sweep_cleanup does
# not touch the members), from the repo root as the other sweeps name theirs.
# shellcheck disable=SC2034  # read by sweep_start's EXIT trap (tests/lib/common.sh)
SWEEP_CLEANUP_CMD="./tests/controlplane/005-cleanup.sh --contexts $(IFS=,; echo "${CONTEXTS[*]}")"
((GROWTH)) || SWEEP_CLEANUP_CMD+="; the next run of the sweep also deletes the namespaces before its first cell"
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
	for pid in ${PEAK_PF_PIDS[@]+"${PEAK_PF_PIDS[@]}"}; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	PEAK_PF_PIDS=()
}

# CELL_IN_PROGRESS: the cell whose rows are not all written yet, as the command that writes
# its status row without the status (legacy_failed, or g_row and its arguments); empty
# between cells. cell_interrupted_row (cp_sweep_cleanup) appends an INTERRUPTED row for it when
# the sweep ends there (interrupted, or stopped), so the cell reads as failed, never as
# measured from the rows written so far. A sweep killed outright writes none: the reports
# then find it INCOMPLETE (fewer member rows than its mesh size) or, when all its rows were
# written, done. A legacy cell whose rows were already written in full (002 --phase final
# appended every member's, and the sweep ended in its diagnostics or the cleanup after) gets
# no INTERRUPTED row: it is done, by the rule the reports use (CP_CELL_AWK cp_cell_state).
CELL_IN_PROGRESS=()
# legacy_cell_written: true when the TSV's rows make the current legacy cell (the loop's ms
# sc rc nc scp tc) done: every member's rows, one per istiod replica, and its last row a
# measurement row.
# shellcheck disable=SC2329  # invoked by cell_interrupted_row
legacy_cell_written() {
	local tsv="${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv" r
	[[ -f "$tsv" ]] || return 1
	r="$(awk -F'\t' -v st="$CELL_STATUS_RE" -v ms="${ms:-}" -v sc="${sc:-}" -v rc="${rc:-}" \
		-v nc="${nc:-}" -v scp="${scp:-}" -v tc="${tc:-}" -v wk="$LEGACY_WINDOW_KIND" "${CP_CELL_AWK}"'
		BEGIN { want = ms SUBSEP sc SUBSEP rc SUBSEP nc SUBSEP scp SUBSEP tc SUBSEP wk }
		/^timestamp\t/ { cp_header(); next }
		/^#/ { cp_comment(); next }
		!cp_isrow() { next }
		{ k = cp_key(); if (k == want) cp_cell_row(k, st) }
		END { cp_end(); if ((want in cp_ms) && cp_cell_state(want) == "") print "done" }' "$tsv" 2>/dev/null)" || return 1
	[[ "$r" == "done" ]]
}
# shellcheck disable=SC2329  # invoked by cp_sweep_cleanup
cell_interrupted_row() {
	((${#CELL_IN_PROGRESS[@]})) || return 0
	[[ "${BASHPID:-$$}" == "$$" ]] || return 0
	local -a cir=("${CELL_IN_PROGRESS[@]}")
	CELL_IN_PROGRESS=()
	if [[ "${cir[0]}" == legacy_failed ]] && legacy_cell_written; then
		echo "note: the cell in progress (${label:-the last cell}) had written every member's rows before the sweep ended: it is done (no INTERRUPTED row)" >&2
		return 0
	fi
	# A subshell: emit_failed_row dies when it cannot end a cut last line, and an exit in
	# the EXIT trap would skip the rest of it.
	( "${cir[0]}" INTERRUPTED "${cir[@]:1}" ) 2>/dev/null \
		|| echo "warning: could not write the INTERRUPTED row of the cell in progress; the reports judge it by its rows" >&2
}

# cp_sweep_cleanup: what the EXIT trap runs when the sweep ends before its end (die, an
# unexpected abort, Ctrl-C), after it recorded how (tests/lib/common.sh, sweep_start): the
# poller and scratch dir (SWEEP_TMP), then the cell in progress (cell_interrupted_row).
# shellcheck disable=SC2329  # run by sweep_start's EXIT trap
cp_sweep_cleanup() {
	stop_peak_metrics_poller 2>/dev/null || true
	rm -rf "$SWEEP_TMP" 2>/dev/null || true
	cell_interrupted_row || true
}

# Pre-create the TSV preamble before any combo (skipped in dry-run). A sweep with --config
# also gets the run-config-<RUN_ID>.env replay copy.
if ((! DRY_RUN)); then
	# sweep-outcome.txt says the sweep runs until sweep_finish writes its outcome; one that
	# ends before records how, then runs cp_sweep_cleanup.
	sweep_start "$OUTPUT_DIR" "$RUN_ID" --cleanup cp_sweep_cleanup
	metrics_preflight
	precreate_tsv_preamble
	config_snapshot "$OUTPUT_DIR" "$RUN_ID"
	if ((GROWTH)); then
		# Namespace-lifecycle timings (001/005 append) and the memory guard's decisions.
		ns_lifecycle_init "$LIFECYCLE_FILE" "$RUN_ID"
		mapfile -t _iv_kv < <(istio_version_kv)
		write_preamble "Memory stop guard (controlplane growth mode)" "$GUARD_FILE" \
			"RUN_ID=${RUN_ID}" "HARNESS_SHA=${HARNESS_SHA}" "${_iv_kv[@]}" \
			"MEM_STOP_PCT=${MEM_STOP_PCT}" "MEM_GUARD_CONTEXTS=$(IFS=,; echo "${GUARD_CONTEXTS[*]}")" \
			"GUARD_SCHEMA=2" "GW_MODEL=intercept ${GW_MI_INTERCEPT} Mi; eastwestgateway ${EWGW_MI_PER_1000} Mi per 1000 Services x ${EWGW_BURST}; ingressgateway ${INGW_MI_PER_1000} Mi per 1000 Services x ${INGW_BURST}" \
			"NOTE=rel_projected = base + (current - base) x ratio^power from the series start (ratio 1: the first step and changes that add no Services); abs_projected (gateways) = (intercept + Mi per 1000 Services x services_after / 1000) x burst factor, plus the non-heap part of a working-set reading (ws - Envoy physical heap); services_after = the context's istiod pilot_services + the Services the step adds; projected = the larger, compared with stop_pct % of limit_mi. metric: rss = istiod process_resident_memory_bytes (max over replicas, per-replica limit); ws = the gateway container's working set (kubectl top), else physical = Envoy server.memory_physical_size, else allocated = server.memory_allocated (istio-proxy limit). verdict stale_base: a gateway's Envoy allocated memory exceeded 1.5 x the model + 100 Mi at the series start (memory kept from an earlier series)."
		{ config_preamble_lines; platform_preamble_lines "$(platform_probed_contexts)"; } >> "$GUARD_FILE"
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
		dir="$(mktemp -d "${SWEEP_TMP}/guard.XXXXXX")"
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
		mem="$(kv_value mem_mi "$kv")"
		phy="$(kv_value physical_mi "$kv")"
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
			echo "WARNING: memory guard: ${key}: Envoy allocated ${alloc} Mi at the series start, above the ${amodel} Mi the model allows for ${svc} Services (memory kept from an earlier series). Restart the gateways between series (kubectl -n istio-system rollout restart deploy -l 'istio in (ingressgateway,eastwestgateway)' on each member, nothing measuring) for clean numbers; the absolute projection still guards every step." >&2
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
	sweep_step "$SCRIPT_DIR/001-setup-controlplane-test.sh" --contexts "$G_ACTIVE_CSV" \
		--services-per-namespace "$G_K" --series "$G_SID" --workload-mode "$WORKLOAD_MODE" \
		--replicas "${REPLICA_COUNTS[0]}" --lifecycle-file "$LIFECYCLE_FILE" "$@"
}

# g002 <phase> <state_dir> <n> <scoping> <window_kind> <outside_x> <outside_mode> <m> [args...]
g002() {
	local phase="$1" state="$2" n="$3" scp="$4" kind="$5" ox="$6" od="$7" m="$8"
	shift 8
	sweep_step "$SCRIPT_DIR/002-collect-resource-metrics.sh" --phase "$phase" --state-dir "$state" \
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
	CELL_IN_PROGRESS=(g_row "$n" "$scp" "$kind" "$ox" "$od" "$m")
	if ! g002 baseline "$state" "$n" "$scp" "$kind" "$ox" "$od" "$m" --settle "$settle"; then
		echo "warn: baseline probe failed for '${label}'; recording PROBE_FAILED and applying anyway" >&2
		CELL_IN_PROGRESS=()
		g_row PROBE_FAILED "$n" "$scp" "$kind" "$ox" "$od" "$m"
		measured=0
	fi
	((measured)) && start_peak_metrics_poller "$state"
	if ! g001 "$@"; then
		stop_peak_metrics_poller
		echo "warn: setup failed for '${label}'; recording ${fail_status}" >&2
		CELL_IN_PROGRESS=()
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
			CELL_IN_PROGRESS=()
			g_row PROBE_FAILED "$n" "$scp" "$kind" "$ox" "$od" "$m"
		fi
	fi
	CELL_IN_PROGRESS=()
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
	sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$G_ACTIVE_CSV" --probe "$pname" --lifecycle-file "$LIFECYCLE_FILE" \
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
		sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$G_ACTIVE_CSV" --series "$sid" --lifecycle-file "$LIFECYCLE_FILE" "$@"
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
		total="$(kv_value total "$kv")"
		disc="$(kv_value discovered "$kv")"
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
	CELL_IN_PROGRESS=()
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
# The leftover check deleted namespaces before the first cell (legacy_leftover_preflight):
# that cell's baseline waits for the deletion's pushes, as after every cell's cleanup.
if ((LEFTOVER_DELETED && SETTLE_SEC > 0)); then
	echo "--- Post-cleanup settle (${SETTLE_SEC}s) ---" >&2
	sleep "$SETTLE_SEC"
fi
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

						ensure_output_dir

						echo "=========================================="
						printf "  Sweep [%d/%d]: %s\n" "$combo_idx" "$MATRIX_SIZE" "$label"
						echo "  Clusters:   ${active_ctxs[*]}"
						echo "  Namespaces: ${ns_pattern}"
						echo "=========================================="
						echo ""

						STATE_DIR_COMBO="${OUTPUT_DIR}/state-combo-${combo_idx}"
						mkdir -p "$STATE_DIR_COMBO"
						CELL_IN_PROGRESS=(legacy_failed)
						# The cell's axes for 001 and 002; a split VS/DR apply measures window kind
						# traffic.
						cell_args=(--contexts "$active_csv" --service-count "$sc" --replicas "$rc" --namespace-count "$nc"
							--sidecar-scoping "$scp" --traffic-config "$tc" --vsdr-every "$VSDR_EVERY" --vsdr-subsets "$VSDR_SUBSETS")
						m002_args=("${cell_args[@]}" --mesh-size "$ms" --window-kind "$LEGACY_WINDOW_KIND" --settle "$SETTLE_SEC" --run-id "$RUN_ID")

						if [[ "$VSDR_APPLY" == split ]]; then
							# Phase 0 (outside the window): the namespaces, Services, Sidecars
							# and the per-subset Deployments, Ready before the baseline (BACKLOG
							# 9.11).
							echo "--- Deploying workloads before the window (split apply, scoping=$scp, traffic=$tc) ---"
							if ! sweep_step "$SCRIPT_DIR/001-setup-controlplane-test.sh" "${cell_args[@]}" --parts workloads; then
								echo "warn: [$combo_idx/$MATRIX_SIZE] workloads setup failed for '$label'; recording SETUP_FAILED row and continuing" >&2
								legacy_failed SETUP_FAILED
								sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
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
						if ! sweep_step "$SCRIPT_DIR/002-collect-resource-metrics.sh" --phase baseline --state-dir "$STATE_DIR_COMBO" "${m002_args[@]}"; then
							# Baseline failed: record the combo, clean up, move on.
							echo "warn: [$combo_idx/$MATRIX_SIZE] baseline probe failed for '$label'; recording PROBE_FAILED row and continuing" >&2
							legacy_failed PROBE_FAILED
							sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
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
								sweep_step "$SCRIPT_DIR/001-setup-controlplane-test.sh" "${cell_args[@]}" --parts traffic || setup_ok=0
							else
								echo "--- Phase 2/3: nothing to apply (traffic none, split apply: an idle window over the same workloads) ---"
							fi
						else
							echo "--- Deploying workloads (phase 2/3, scoping=$scp, traffic=$tc) ---"
							sweep_step "$SCRIPT_DIR/001-setup-controlplane-test.sh" "${cell_args[@]}" || setup_ok=0
						fi
						if ! ((setup_ok)); then
							echo "warn: [$combo_idx/$MATRIX_SIZE] setup failed for '$label'; recording SETUP_FAILED row and continuing" >&2
							stop_peak_metrics_poller   # MUST stop before continue — poller runs in background
							legacy_failed SETUP_FAILED
							sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
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
						if ! sweep_step "$SCRIPT_DIR/002-collect-resource-metrics.sh" --phase final --state-dir "$STATE_DIR_COMBO" "${m002_args[@]}" \
							--config-dump-samples "$CONFIG_DUMP_SAMPLES" --output-dir "$OUTPUT_DIR"; then
							# Final scrape failed: record PROBE_FAILED; cleanup still runs below.
							echo "warn: [$combo_idx/$MATRIX_SIZE] final probe failed for '$label'; recording PROBE_FAILED row and continuing" >&2
							legacy_failed PROBE_FAILED
						fi
						CELL_IN_PROGRESS=()
						rm -rf "$STATE_DIR_COMBO"
						echo ""

						echo "--- Cleaning up ---"
						# 005 waits (bounded) for namespace termination. A failure only warns:
						# the next 001 waits for any leftover namespace before applying.
						sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
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
# A build that changed during the sweep goes to its reports (tests/lib/platform.sh).
platform_drift_check "$OUTPUT_DIR" "$(IFS=,; echo "${CONTEXTS[*]}")"

echo "=========================================="
if [[ -n "$SWEEP_STOPPED" ]]; then
	echo "  Sweep STOPPED early ($combo_idx cells; see the ERROR below)"
else
	echo "  Sweep finished ($combo_idx combinations)"
fi
echo "=========================================="
echo ""
# The Istio version again, after the last window and before the reports (read-only): a
# change is a problem of the outcome, a member it cannot confirm a note.
istio_version_recheck ${KUBECTL[@]+"${KUBECTL[@]}"}
# Every cell without a measurement has the status row emit_failed_row wrote (its
# context column is the status); count them by reason, the memory guard's SKIPPED_* apart
# (skipped on purpose, not failed: C2), before the reports (they read sweep-outcome.txt).
# The RETIRE_FAILED stop (exit 1) wins over 4 (some cells failed, or the Istio version or
# active revision changed under the sweep). Once per cell, keyed by the five axes,
# traffic_config and window_kind, and decided by the rule the reports use (CP_CELL_AWK
# cp_cell_state): a last row that is a status row fails it, with that row's reason (also
# after a context's rows: a partial failure; INTERRUPTED: the run ended inside it); a last
# row that is a measurement (valid or not) does not, unless the cell's rows name fewer
# members than its mesh size, or fewer than its WINDOW_ROWS lines name (INCOMPLETE: cut
# short while they were written). The total is every cell of the TSV and of this run's
# matrix, and a matrix cell with no row counts failed as NOT_RUN. A growth series' cells
# share that key (M-sweep, outside phases), so each of its status rows is a cell of its
# own, of the plan.
CELL_KEYS=""
if ! ((GROWTH)); then
	CELL_KEYS="$(matrix_cell_keys)"
fi
# The matrix's keys go in a file (in the environment, past about 4,200 cells, awk could
# not even start), and a count that does not end with its TOTAL line is a problem (the
# total then reads unknown), never "all cells ran". As the report, a line shorter than 40
# columns is not a row. A keys file that cannot be read is that too (getline -1 would end
# the loop and count the rows only).
CELL_RESULT=()
_cells_dir="${SWEEP_TMP}/cells"
mkdir -p "$_cells_dir" 2>/dev/null || true
printf '%s\n' "$CELL_KEYS" > "${_cells_dir}/keys"
_cells_rc=0
awk -F'\t' -v growth="$GROWTH" -v keys="${_cells_dir}/keys" -v st="$CELL_STATUS_RE" "${CP_CELL_AWK}"'
	function addkey(k) { if (!(k in cell)) { cell[k] = 1; ncell++; korder[++nk] = k } }
	BEGIN {
		while ((r = (getline line < keys)) > 0)
			if (split(line, f, "\t") >= 7) addkey(f[1] SUBSEP f[2] SUBSEP f[3] SUBSEP f[4] SUBSEP f[5] SUBSEP f[6] SUBSEP f[7])
		if (r < 0) { print "awk: cannot read the matrix cell keys file" > "/dev/stderr"; bad = 1; exit 2 }
		close(keys)
	}
	/^timestamp\t/ { cp_header(); next }
	/^#/ { cp_comment(); next }
	!cp_isrow() { next }
	{
		k = cp_key()
		if (!(k in cell)) { cell[k] = 1; ncell++ }
		if (!(k in row)) order[++n] = k
		row[k] = 1
		if (cp_cell_row(k, st) && growth) print "FAILED\t" $2
	}
	END {
		if (bad) exit 2
		cp_end()
		print "TOTAL\t" ncell
		if (!growth) for (i = 1; i <= n; i++) {
			s = cp_cell_state(order[i])
			if (s == "") continue
			print "FAILED\t" s
			if (s == "INCOMPLETE") ninc++
			else if (order[i] in cp_valid) npw++
		}
		print "PARTWAY\t" npw + 0
		print "INCOMPLETE\t" ninc + 0
		for (i = 1; i <= nk; i++) if (!(korder[i] in row)) {
			split(korder[i], f, SUBSEP)
			printf "NOTRUN\tmesh=%s svcs=%s reps=%s ns=%s scope=%s traffic=%s\n", f[1], f[2], f[3], f[4], f[5], f[6]
		}
	}' "${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv" > "${_cells_dir}/out" 2> "${_cells_dir}/err" || _cells_rc=$?
[[ ! -f "${_cells_dir}/out" ]] || mapfile -t CELL_RESULT < "${_cells_dir}/out"
# The why goes into the record: no local path in it (the temp dir, the sweep dir).
_cells_why="$(head -n 1 "${_cells_dir}/err")"
_cells_why="${_cells_why//"$_cells_dir"/<tmp>}"
_cells_why="${_cells_why//"$OUTPUT_DIR"/<sweep dir>}"
_cells_why="${_cells_why:0:200}"
rm -rf "$_cells_dir"
_cells_dir=""
FAILED_CELLS=() NOTRUN_CELLS=()
CELLS_TOTAL="" _cells_seen="" _cells_pw=0 _cells_inc=0 _cells_counted=1
for _cell_line in ${CELL_RESULT[@]+"${CELL_RESULT[@]}"}; do
	case "$_cell_line" in
	FAILED$'\t'*) FAILED_CELLS+=("${_cell_line#FAILED$'\t'}") ;;
	TOTAL$'\t'*) _cells_seen="${_cell_line#TOTAL$'\t'}" ;;
	PARTWAY$'\t'*) _cells_pw="${_cell_line#PARTWAY$'\t'}" ;;
	INCOMPLETE$'\t'*) _cells_inc="${_cell_line#INCOMPLETE$'\t'}" ;;
	NOTRUN$'\t'*)
		FAILED_CELLS+=(NOT_RUN)
		NOTRUN_CELLS+=("${_cell_line#NOTRUN$'\t'}")
		;;
	esac
done
_cells_where="The report includes their status rows as placeholder rows (in n_total, not n_valid)"
((${#NOTRUN_CELLS[@]} == 0)) || _cells_where+="; NOT_RUN cells have no row"
if ((_cells_rc == 0)) && is_nonneg_int "$_cells_seen"; then
	CELLS_TOTAL="$_cells_seen"
	((GROWTH == 0 && CELLS_TOTAL > 0)) || CELLS_TOTAL="$MATRIX_SIZE"
	if is_nonneg_int "$_cells_pw" && ((_cells_pw > 0)); then
		_cells_where+="; ${_cells_pw} of them failed partway (a valid row, then a status row)"
	fi
	if is_nonneg_int "$_cells_inc" && ((_cells_inc > 0)); then
		_cells_where+="; ${_cells_inc} of them (INCOMPLETE) were cut short while their member rows were written (fewer members have a row than the mesh size, or a member fewer rows than its window wrote, or in rows an older harness wrote one by one than its istiod replicas, and no status row): the report keeps their rows with a data warning"
	fi
	if ((${#NOTRUN_CELLS[@]})); then
		_nr_list="$(printf '%s; ' "${NOTRUN_CELLS[@]:0:5}")"
		_nr_list="${_nr_list%; }"
		((${#NOTRUN_CELLS[@]} <= 5)) || _nr_list+="; and $((${#NOTRUN_CELLS[@]} - 5)) more"
		sweep_note "${#NOTRUN_CELLS[@]} cell(s) of the matrix have no row (NOT_RUN: never reached): ${_nr_list}. To measure them, run the sweep again into a new dir with their axis values"
	fi
else
	# The rows are intact, and the reports count them. The sweep dir (a local path) goes to
	# stderr only, below, never into the record.
	FAILED_CELLS=() CELLS_TOTAL=unknown _cells_counted=0
	sweep_problem "could not count the sweep's cells: ${_cells_why:-awk exited ${_cells_rc} with no count}; the rows are intact: 004-report-results.sh counts them from the sweep dir"
fi
outcome_rc=0 stop_args=()
[[ -z "$SWEEP_STOPPED" ]] || stop_args=(--stopped 1 --stop-reason "RETIRE_FAILED: ${SWEEP_STOPPED}")
sweep_finish ${stop_args[@]+"${stop_args[@]}"} --where "$_cells_where" \
	"$CELLS_TOTAL" ${FAILED_CELLS[@]+"${FAILED_CELLS[@]}"} || outcome_rc=$?
((_cells_counted)) || echo "The sweep dir: ${OUTPUT_DIR} (count its cells with: ${SCRIPT_DIR}/004-report-results.sh --results-dir ${OUTPUT_DIR})" >&2

echo "Generating report..."
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$OUTPUT_DIR"

MD_FILE="${OUTPUT_DIR}/sweep-${RUN_ID}.md"
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$OUTPUT_DIR" --format markdown > "$MD_FILE"
echo "Markdown summary written to $MD_FILE"

CHARTS_FILE="${OUTPUT_DIR}/sweep-charts-${RUN_ID}.md"
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$OUTPUT_DIR" --format charts > "$CHARTS_FILE"
echo "Charts written to $CHARTS_FILE"

# Campaign scale envelope (docs/campaigns/TEMPLATE.md), best-effort: a render
# failure warns but never fails the sweep. It repeats the sweep's outcome.
ENVELOPE_FILE="${OUTPUT_DIR}/scale-envelope-${RUN_ID}.md"
# Keep the render's stderr so the warning shows the actual reason.
ENVELOPE_ERR="${SWEEP_TMP}/envelope.err"
# Subshell: render_scale_envelope uses die(), which must not abort the sweep.
if ( render_scale_envelope "$OUTPUT_DIR" "$SCRIPT_DIR/004-report-results.sh" \
		"$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}" ) > "$ENVELOPE_FILE" 2>"$ENVELOPE_ERR"; then
	echo "Scale envelope written to $ENVELOPE_FILE"
else
	rm -f "$ENVELOPE_FILE"
	echo "warning: scale-envelope generation failed (sweep data is safe above):" >&2
	sed 's/^/  /' "$ENVELOPE_ERR" >&2
fi
rm -rf "$SWEEP_TMP"
if [[ -n "$SWEEP_STOPPED" ]]; then
	echo "" >&2
	echo "ERROR: the sweep stopped early: ${SWEEP_STOPPED} (RETIRE_FAILED row in the report). The cells above it are valid; later series did not run." >&2
	exit 1
fi
exit "$outcome_rc"

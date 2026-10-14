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
                              \$SETUP_CONTEXTS: every member ingests the Services).
  --series-retire MODE        End of a series: undiscover (drop discovery labels, keep
                              the namespaces; 005 --undiscover --no-delete), delete (also
                              queue the namespace deletes, no wait) or keep (default:
                              $SERIES_RETIRE).

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

Environment:
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
  SCALE_SIZING_MODE, SCALE_TARGET_FRACTION (recorded in the TSV preamble).
  Growth mode: CONTROLPLANE_SERVICES_PER_NAMESPACES (else ..._SERVICES_PER_NAMESPACE),
  CONTROLPLANE_GROWTH_MODE, CONTROLPLANE_WORKLOAD_MODE,
  CONTROLPLANE_MEASUREMENT_POD_COUNTS (else ..._MEASUREMENT_PODS),
  CONTROLPLANE_MEASUREMENT_PROXY_MEM_LIMIT, CONTROLPLANE_OUTSIDE_NAMESPACES,
  CONTROLPLANE_OUTSIDE_MODES (else ..._OUTSIDE_MODE), CONTROLPLANE_PROBE_SETTLE_SEC,
  CONTROLPLANE_MEM_STOP_PCT, CONTROLPLANE_MEM_GUARD_CONTEXTS, CONTROLPLANE_SERIES_RETIRE,
  CONTROLPLANE_NS_DELETE_SEC_PER_NS (the plan's namespace-deletion estimate).
  METRICS_READY_TIMEOUT (default 120; 0 disables), METRICS_READY_INTERVAL (10):
  pre-sweep wait for 'kubectl top nodes'; warns (never aborts) if unavailable.
  CAP_TOP_TIMEOUT (default 15), CAP_TOP_ATTEMPTS (2), CAP_TOP_BACKOFF_S (2):
  timeout and retry for the kubectl top reads.
  METRICS_SCRAPE_TIMEOUT (default 30): curl --max-time for istiod /metrics.
  CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT (default 10), CONTROLPLANE_PROXY_CHECK_MIN_DIFF
  (default 2): warn when a cluster's connected proxies and its Running sidecar pods
  differ by more than max(tolerance %, min diff); recorded in the TSV preamble.
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
# So do 001, 002 and 005 with these; a typo would otherwise fail every setup or skip
# every cleanup mid-sweep, and pass --dry-run.
is_nonneg_int "${CONTROLPLANE_WAIT_TIMEOUT_SEC:-300}" || die "CONTROLPLANE_WAIT_TIMEOUT_SEC (read by 001) must be a non-negative integer (got: ${CONTROLPLANE_WAIT_TIMEOUT_SEC:-})"
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

for ms in "${MESH_SIZES[@]}"; do
	is_pos_int "$ms" || die "mesh-size '$ms' is not a positive integer"
	((ms >= 1 && ms <= ${#CONTEXTS[@]})) || die "mesh-size $ms out of range (have ${#CONTEXTS[@]} contexts)"
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
	[[ "$NS_DELETE_SEC_PER_NS" =~ ^([0-9]+(\.[0-9]+)?|\.[0-9]+)$ ]] || die "CONTROLPLANE_NS_DELETE_SEC_PER_NS must be a non-negative number (got: $NS_DELETE_SEC_PER_NS)"
	for scp in "${SCOPINGS[@]}"; do
		[[ "$scp" != explicit ]] || die "growth series do not support --sidecar-scopings explicit (use none, namespace and/or wide)"
	done
	for tc in "${TRAFFIC_CONFIGS[@]}"; do
		[[ "$tc" == none ]] || die "growth series do not support --traffic-configs vsdr"
	done
	((${#REPLICA_COUNTS[@]} == 1)) || die "growth series take one --replica-counts value (got: ${REPLICA_COUNTS_CSV})"
	[[ "${SCALE_SIZING_MODE:-fixed}" != auto ]] || die "SCALE_SIZING_MODE=auto derives service counts, which growth series do not use; set SCALE_SIZING_MODE=fixed"
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
	awk -F'\t' -v ms="$1" -v sc="$2" -v rc="$3" -v nc="$4" -v scp="$5" -v tc="$6" '
		/^timestamp\t/ { tcol = 0; for (i = 1; i <= NF; i++) if ($i == "traffic_config") tcol = i; next }
		!/^#/ && NF>=40 && $31=="0" \
			&& $3==ms && $4==sc && $5==rc && $6==nc && $7==scp \
			&& ((tcol && NF >= tcol) ? $tcol : "none") == tc { found=1; exit }
		END { exit (found ? 0 : 1) }' "$tsv"
}

# The 63-column TSV schema header. 002 writes the same literal when it runs
# standalone; tests/lib/test/preamble.bats checks that the two are identical.
CONTROLPLANE_TSV_HEADER="timestamp\tcontext\tmesh_size\tservice_count\treplicas\tnamespace_count\tsidecar_scoping\tistiod_mem_mi\tconvergence_p50_ms\tconvergence_p99_ms\tqueue_p50_ms\tqueue_p99_ms\txds_pushes_delta\txds_pushes_rate\txds_pushes_cds\txds_pushes_eds\txds_pushes_lds\txds_pushes_rds\txds_pushes_nds\tk8s_events_delta\tk8s_events_rate\tconnected_proxies\tconfig_size_avg_bytes\tsidecar_config_bytes_avg\tsidecar_config_bytes_p50\tsidecar_config_bytes_max\tsidecar_config_bytes_samples\tscrape_window_sec\tscrape_skew_ms\tsettle_sec\tistiod_restarted\tistiod_cpu_m_delta\tgo_heap_alloc_mi\tgo_heap_inuse_mi\tistiod_cpu_pct_of_limit\tistiod_mem_pct_of_limit\tnode_cpu_pct\tnode_mem_pct\tpods_scheduled\tpods_allocatable\tcluster_connected_proxies\tsidecar_pods\tproxy_check\ttraffic_config\tvsdr_services\tistiod_virt_services\tpush_time_avg_ms\tpushcontext_init_avg_ms\tsidecar_clusters_avg\tsidecar_cds_bytes_avg\tsidecar_rds_bytes_avg\tservices_per_namespace\tworkload_mode\tmeasurement_pods\toutside_namespaces\toutside_discovery\twindow_kind\tistiod_services\tistiod_cpu_s_delta\tsidecar_mem_mi_avg\tgateway_clusters_max\tgateway_mem_mi_max\troot_cert_configmaps"
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
		echo "# CONTROLPLANE_SCHEMA=63"
		echo "# CONTROLPLANE_INFRA_SCHEMA=2"
		echo "# ISTIO_VERSION=${ISTIO_VERSION:-unknown}"
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
			DISCOVERY_LABEL=istio-discovery=enabled
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
# (services x replicas x SCALE_PER_POD_CPU_M) with free node CPU on the source
# context. Warn only; 001's preflight is the hard gate. Dry-run prints only the
# requested cores (no cluster contact).
capacity_plan_warn() {
	local per_pod_cpu_m="${SCALE_PER_POD_CPU_M:-200}"
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
	echo "  requested: ${needed_pods} sidecar-pods × ${per_pod_cpu_m}m = ~$(( needed_cpu_m / 1000 )) cores/cluster (SCALE_PER_POD_CPU_M=${per_pod_cpu_m})" >&2

	if ((DRY_RUN)); then
		echo "  WARN: dry-run does not contact clusters; free-capacity comparison skipped. Run without --dry-run for the services-that-fit estimate." >&2
		echo "" >&2
		return 0
	fi
	(( ${#KUBECTL[@]} )) || { echo "  WARN: no oc/kubectl; cannot read node capacity for the fit estimate." >&2; echo "" >&2; return 0; }

	local src_ctx="${CONTEXTS[0]}" alloc_cpu_m="" istiod_cpu_m="" istiod_rep="" kv
	# shellcheck disable=SC2207
	local -a nt=($(cap_node_totals "$src_ctx" "${KUBECTL[@]}"))
	for kv in "${nt[@]}"; do case "$kv" in cpu_m=*) alloc_cpu_m="${kv#cpu_m=}" ;; esac; done
	# shellcheck disable=SC2207
	local -a il=($(cap_istiod_limits "$src_ctx" "${KUBECTL[@]}"))
	for kv in "${il[@]}"; do
		case "$kv" in
			cpu_m=*) istiod_cpu_m="${kv#cpu_m=}" ;;
			replicas=*) istiod_rep="${kv#replicas=}" ;;
		esac
	done
	if ! [[ "$alloc_cpu_m" =~ ^[0-9]+$ ]]; then
		echo "  WARN: node allocatable CPU unreadable on $src_ctx; cannot estimate services-that-fit." >&2
		echo "" >&2
		return 0
	fi
	# istiod baseline = per-replica istiod CPU limit × replicas (the aggregate control-
	# plane reservation on the cluster). Unknown istiod limit -> baseline 0 (conservative
	# overstate of free CPU; still flags the gross over-provision case).
	local istiod_baseline_m=0
	if [[ "$istiod_cpu_m" =~ ^[0-9]+$ && "$istiod_rep" =~ ^[0-9]+$ ]]; then
		istiod_baseline_m=$(( istiod_cpu_m * istiod_rep ))
	fi
	local free_cpu_m=$(( alloc_cpu_m - istiod_baseline_m ))
	(( free_cpu_m < 0 )) && free_cpu_m=0
	local max_services=0
	if (( max_rc > 0 && per_pod_cpu_m > 0 )); then
		max_services=$(( free_cpu_m / (max_rc * per_pod_cpu_m) ))
	fi
	echo "  node alloc CPU: ~$(( alloc_cpu_m / 1000 )) cores; istiod baseline: ~$(( istiod_baseline_m / 1000 )) cores (${istiod_cpu_m:-unknown}m × ${istiod_rep:-unknown} rep) -> ~$(( free_cpu_m / 1000 )) cores free" >&2
	if (( needed_cpu_m > free_cpu_m )); then
		echo "  WARN: combo needs ~$(( needed_cpu_m / 1000 )) cores/cluster, ~$(( free_cpu_m / 1000 )) free -> ~${max_services} services max (at ${max_rc} replicas). Reduce --service-counts to <= ${max_services}, add nodes, or expect FailedScheduling/SETUP_FAILED on the largest combo." >&2
	else
		echo "  OK: largest combo fits (~$(( needed_cpu_m / 1000 )) needed <= ~$(( free_cpu_m / 1000 )) free; ~${max_services} services would fit at ${max_rc} replicas)." >&2
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
# GROW_FAILED, SWITCH_FAILED, SKIPPED_MEM_GUARD and SKIPPED_SERIES_STOPPED.
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
	# 63 fields: cols 41-43 (cluster proxies, sidecar pods, proxy check) are N/A too;
	# cols 44-45 keep the cell's traffic config, cols 46-51 are N/A; cols 52-57 keep
	# the cell's growth metadata, cols 58-63 are N/A.
	echo -e "$(date -u -Iseconds)\t${status}\t${ms}\t${sc}\t${rc}\t${nc}\t${scp}\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t${SETTLE_SEC}\tunknown\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t${tc}\t${vsdr_svcs}\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t${g_spn}\t${g_wm}\t${g_mp}\t${g_ox}\t${g_od}\t${g_wk}\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A" >> "$tsv"
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
	echo "Traffic configs:   ${TRAFFIC_CONFIGS[*]}  (vsdr: every ${VSDR_EVERY}, ${VSDR_SUBSETS} subsets)"
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

capacity_plan_warn

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
		write_preamble "Memory stop guard (controlplane growth mode)" "$GUARD_FILE" \
			"RUN_ID=${RUN_ID}" "HARNESS_SHA=$(harness_sha)" "ISTIO_VERSION=${ISTIO_VERSION:-unknown}" \
			"MEM_STOP_PCT=${MEM_STOP_PCT}" "MEM_GUARD_CONTEXTS=$(IFS=,; echo "${GUARD_CONTEXTS[*]}")" \
			"NOTE=projected = base + (current - base) x ratio^power; istiod from go_memstats_heap_inuse_bytes (max over replicas) vs the per-replica memory limit, gateways from Envoy server.memory_allocated vs the istio-proxy limit; the first step and changes that add no Services use the current value (ratio 1)"
		printf 'timestamp\tseries\tcell\tcontext\tcomponent\tcurrent_mi\tbase_mi\tratio\tpower\tprojected_mi\tlimit_mi\tstop_pct\tverdict\n' >> "$GUARD_FILE"
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

# guard_sample_ctx <ctx> <ctx_index>: "istiod <heap_mi> <limit_mi>" (max
# go_memstats_heap_inuse over the context's istiod pods, per-replica memory limit)
# and one "gw:<pod> <envoy_mi> <limit_mi>" line per gateway. The port-forwards close
# on return. A context without a reachable istiod prints no istiod line; nothing here
# can abort the sweep (PL40).
guard_sample_ctx() {
	local ctx="$1" ci="$2"
	(
		local -a pids=() ports=() pods=()
		local dir i h max="" lim="unknown" kv
		dir="$(mktemp -d -t controlplane-guard.XXXXXX)"
		trap 'for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$dir"' EXIT
		fanout_open "$ctx" "$ci" pids ports pods "${KUBECTL[@]}" 2>/dev/null
		fanout_scrape_all "$dir" g "${ports[@]}" >/dev/null 2>&1 || true
		for i in "${!ports[@]}"; do
			h="$(growth_istiod_heap_mi "${dir}/g-${i}.metrics")"
			[[ "$h" =~ ^[0-9]+$ ]] || continue
			if [[ -z "$max" ]] || ((h > max)); then max="$h"; fi
		done
		for kv in $(cap_istiod_limits "$ctx" "${KUBECTL[@]}"); do
			[[ "$kv" == mem_mi=* ]] && lim="${kv#mem_mi=}"
		done
		[[ -n "$max" ]] && echo "istiod ${max} ${lim}"
		exit 0
	) || true
	local pod plim kv mem
	while IFS=$'\t' read -r pod plim; do
		[[ -n "$pod" ]] || continue
		kv="$(growth_envoy_stats "$ctx" istio-system "$pod" "${KUBECTL[@]}")"
		mem="${kv#mem_mi=}"
		mem="${mem%% *}"
		[[ "$mem" =~ ^[0-9]+$ ]] && echo "gw:${pod} ${mem} ${plim}"
	done < <(growth_gateway_pods "$ctx" "${KUBECTL[@]}")
	return 0
}

# guard_collect <assoc_name>: sample every guard context into "<ctx>|<component>" ->
# "<current_mi> <limit_mi>".
guard_collect() {
	local -n _gc="$1"
	_gc=()
	local ci comp cur lim
	for ci in "${!GUARD_CONTEXTS[@]}"; do
		while read -r comp cur lim; do
			[[ -n "$comp" ]] || continue
			_gc["${GUARD_CONTEXTS[ci]}|${comp}"]="${cur} ${lim}"
		done < <(guard_sample_ctx "${GUARD_CONTEXTS[ci]}" "$ci")
	done
}

# guard_log <cell> <ctx> <component> <cur> <base> <ratio> <power> <projected> <limit> <verdict>
guard_log() {
	[[ -f "$GUARD_FILE" ]] || return 0
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u -Iseconds)" "$G_SID" \
		"$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "$MEM_STOP_PCT" "${10}" >> "$GUARD_FILE"
}

# guard_baseline: the empty-mesh reference of a series (before its first step).
guard_baseline() {
	GUARD_BASE=()
	GUARD_WIDE=()
	GUARD_WIDE_N=0
	((MEM_STOP_PCT > 0)) || return 0
	local -A now=()
	guard_collect now
	local key cur lim ctx
	for key in "${!now[@]}"; do
		read -r cur lim <<<"${now[$key]}"
		GUARD_BASE[$key]="$cur"
	done
	for ctx in "${GUARD_CONTEXTS[@]}"; do
		[[ -n "${GUARD_BASE["${ctx}|istiod"]:-}" ]] \
			|| echo "warn: memory guard: no istiod heap readable on ${ctx}; that context is not guarded" >&2
	done
	echo "Memory guard baseline: ${#GUARD_BASE[@]} component(s) on ${#GUARD_CONTEXTS[@]} context(s) (stop at ${MEM_STOP_PCT}% of a limit)"
}

# guard_check <cell> <istiod_ratio> <istiod_power> <gateway_ratio> <use_wide>: 0 to
# run the cell, 1 to skip it. Projects each component to base + (current - base) x
# ratio^power and stops when that exceeds MEM_STOP_PCT % of its limit. With use_wide,
# istiod's "current" is its heap after the last wide probe (GUARD_WIDE), so a wide
# cell projects quadratically from the last wide measurement. Ratio 1 = current usage
# only (the first step, and changes that add no Services).
guard_check() {
	local cell="$1" ir="$2" ip="$3" gr="$4" use_wide="${5:-0}"
	((MEM_STOP_PCT > 0)) || return 0
	local -A now=()
	guard_collect now
	if ((${#now[@]} == 0)); then
		echo "warn: memory guard: nothing could be sampled before '${cell}'; running it unguarded" >&2
		guard_log "$cell" - - - - - - - - unknown
		return 0
	fi
	local key cur lim base r p proj verdict stop=0 comp
	for key in "${!now[@]}"; do
		read -r cur lim <<<"${now[$key]}"
		comp="${key#*|}"
		base="${GUARD_BASE[$key]:-$cur}"
		if [[ "$comp" == istiod ]]; then
			r="$ir"
			p="$ip"
			if ((use_wide)) && [[ -n "${GUARD_WIDE[$key]:-}" ]]; then cur="${GUARD_WIDE[$key]}"; fi
		else
			r="$gr"
			p=1
		fi
		proj="$(mem_guard_project "$cur" "$base" "$r" "$p")"
		verdict="$(mem_guard_verdict "$proj" "$lim" "$MEM_STOP_PCT")"
		guard_log "$cell" "${key%%|*}" "$comp" "$cur" "$base" "$r" "$p" "$proj" "$lim" "$verdict"
		if [[ "$verdict" == stop ]]; then
			echo "  memory guard: ${key}: projected ${proj} Mi > ${MEM_STOP_PCT}% of ${lim} Mi (now ${cur} Mi, base ${base} Mi, x ${r}^${p}); skipping '${cell}'" >&2
			stop=1
		fi
	done
	((stop == 0))
}

# guard_note_wide <discovered_namespaces>: remember istiod heap after a wide probe.
guard_note_wide() {
	((MEM_STOP_PCT > 0)) || return 0
	local -A now=()
	guard_collect now
	local key cur lim
	for key in "${!now[@]}"; do
		[[ "${key#*|}" == istiod ]] || continue
		read -r cur lim <<<"${now[$key]}"
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
				if ! guard_check "probe wide N=${n}" "$r" 2 1 1; then
					G_WIDE_STOPPED=1
					g_skip SKIPPED_MEM_GUARD "$n" "$scp" probe "$ox" "$od" "$m"
					continue
				fi
			elif ! guard_check "probe ${scp} N=${n}" 1 1 1 0; then
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

# g_retire: end a series per --series-retire (then the PL18 settle).
g_retire() {
	echo "--- Retiring series ${G_SID} (${SERIES_RETIRE}) ---"
	case "$SERIES_RETIRE" in
	undiscover)
		"$SCRIPT_DIR/005-cleanup.sh" --contexts "$G_ACTIVE_CSV" --series "$G_SID" --undiscover --no-delete \
			--lifecycle-file "$LIFECYCLE_FILE" || echo "warn: series ${G_SID}: undiscover reported a failure" >&2
		;;
	delete)
		"$SCRIPT_DIR/005-cleanup.sh" --contexts "$G_ACTIVE_CSV" --series "$G_SID" --undiscover --no-wait \
			--lifecycle-file "$LIFECYCLE_FILE" || echo "warn: series ${G_SID}: undiscover + delete reported a failure" >&2
		;;
	keep)
		echo "Series ${G_SID} stays discovered (--series-retire keep); remove it later with 005 --series ${G_SID}."
		;;
	esac
	if ((SETTLE_SEC > 0)); then sleep "$SETTLE_SEC"; fi
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
		if ! guard_check "grow ${n_prev}->${n}" "$r" 1 "$r" 0; then
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
		[[ "$om" == labeled ]] && r="$(g_ratio "$(( n_last + OUTSIDE_NAMESPACES ))" "$n_last")"
		if [[ -z "$stopped" ]] && ! guard_check "outside ${om} N=${n_last}" "$r" 1 "$r" 0; then
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
	g_retire
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
	guard_baseline
	for n in "${NAMESPACE_COUNTS[@]}"; do
		for scp in "${SCOPINGS[@]}"; do
			f=$((f + 1))
			G_SID="${base_sid}f${f}"
			if ! guard_check "fresh N=${n} ${scp}" 1 1 1 0; then
				g_skip SKIPPED_MEM_GUARD "$n" "$scp" deploy 0 none "$G_M"
				continue
			fi
			g_window deploy "$n" "$scp" 0 none "$G_M" "$SETTLE_SEC" SETUP_FAILED \
				--namespace-count "$n" --sidecar-scoping "$scp" --measurement-pods "$G_M" || true
			# Bounded wait (PL4/PL37), scaled to the namespaces this cell deletes.
			timeout="$(awk -v n="$n" -v s="$NS_DELETE_SEC_PER_NS" -v t="${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300}" \
				'BEGIN { v = int(2 * n * s + 60); print (v > t ? v : t) }')"
			"$SCRIPT_DIR/005-cleanup.sh" --contexts "$G_ACTIVE_CSV" --series "$G_SID" --timeout "$timeout" \
				--lifecycle-file "$LIFECYCLE_FILE" \
				|| echo "warn: cleanup of fresh cell ${G_SID} reported a failure; the next cell uses new namespace names" >&2
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
			if [[ "$GROWTH_MODE" == fresh ]]; then
				run_growth_fresh "$ms" "$k" "$idx"
			else
				run_growth_series "$ms" "$k" "$idx"
			fi
		done
	done
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

						echo "--- Baseline metrics scrape (phase 1/3) ---"
						if ! "$SCRIPT_DIR/002-collect-resource-metrics.sh" \
							--phase baseline \
							--state-dir "$STATE_DIR_COMBO" \
							--contexts "$active_csv" \
							--mesh-size "$ms" \
							--service-count "$sc" \
							--replicas "$rc" \
							--namespace-count "$nc" \
							--sidecar-scoping "$scp" \
							--traffic-config "$tc" \
							--vsdr-every "$VSDR_EVERY" \
							--vsdr-subsets "$VSDR_SUBSETS" \
							--settle "$SETTLE_SEC" \
							--run-id "$RUN_ID"; then
							# Baseline failed: record the combo, clean up, move on.
							echo "warn: [$combo_idx/$MATRIX_SIZE] baseline probe failed for '$label'; recording PROBE_FAILED row and continuing" >&2
							emit_failed_row PROBE_FAILED "$ms" "$sc" "$rc" "$nc" "$scp" "$tc"
							"$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
								echo "warn: cleanup after baseline failure also reported failure for '$label'" >&2
							rm -rf "$STATE_DIR_COMBO"
							if (( SETTLE_SEC > 0 )); then sleep "$SETTLE_SEC"; fi
							continue
						fi
						echo ""

						start_peak_metrics_poller "$STATE_DIR_COMBO"

						echo "--- Deploying workloads (phase 2/3, scoping=$scp, traffic=$tc) ---"
						# Setup failed: stop the poller, record SETUP_FAILED, clean up, move on.
						if ! "$SCRIPT_DIR/001-setup-controlplane-test.sh" \
							--contexts "$active_csv" \
							--service-count "$sc" \
							--replicas "$rc" \
							--namespace-count "$nc" \
							--sidecar-scoping "$scp" \
							--traffic-config "$tc" \
							--vsdr-every "$VSDR_EVERY" \
							--vsdr-subsets "$VSDR_SUBSETS"; then
							echo "warn: [$combo_idx/$MATRIX_SIZE] setup failed for '$label'; recording SETUP_FAILED row and continuing" >&2
							stop_peak_metrics_poller   # MUST stop before continue — poller runs in background
							emit_failed_row SETUP_FAILED "$ms" "$sc" "$rc" "$nc" "$scp" "$tc"
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

						echo "--- Final metrics scrape + emit (phase 3/3) — window covers baseline → deploy → settle ---"
						if ! "$SCRIPT_DIR/002-collect-resource-metrics.sh" \
							--phase final \
							--state-dir "$STATE_DIR_COMBO" \
							--contexts "$active_csv" \
							--mesh-size "$ms" \
							--service-count "$sc" \
							--replicas "$rc" \
							--namespace-count "$nc" \
							--sidecar-scoping "$scp" \
							--traffic-config "$tc" \
							--vsdr-every "$VSDR_EVERY" \
							--vsdr-subsets "$VSDR_SUBSETS" \
							--config-dump-samples "$CONFIG_DUMP_SAMPLES" \
							--settle "$SETTLE_SEC" \
							--output-dir "$OUTPUT_DIR" \
							--run-id "$RUN_ID"; then
							# Final scrape failed: record PROBE_FAILED; cleanup still runs below.
							echo "warn: [$combo_idx/$MATRIX_SIZE] final probe failed for '$label'; recording PROBE_FAILED row and continuing" >&2
							emit_failed_row PROBE_FAILED "$ms" "$sc" "$rc" "$nc" "$scp" "$tc"
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
echo "  Sweep complete ($combo_idx combinations)"
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

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
  --sidecar-scopings CSV      Sidecar CR scoping modes: none,namespace,explicit
                              (default: $SIDECAR_SCOPINGS_CSV).
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
for sc in "${SERVICE_COUNTS[@]}"; do
	for nc in "${NAMESPACE_COUNTS[@]}"; do
		(( nc <= sc )) || die "namespace-count $nc > service-count $sc; some namespaces would be empty. Reduce --namespace-counts to at most --service-counts."
	done
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

MATRIX_SIZE=$(( ${#MESH_SIZES[@]} * ${#SERVICE_COUNTS[@]} * ${#REPLICA_COUNTS[@]} * ${#NAMESPACE_COUNTS[@]} * ${#SCOPINGS[@]} * ${#TRAFFIC_CONFIGS[@]} ))
MATRIX_FACTORS="${#MESH_SIZES[@]}×${#SERVICE_COUNTS[@]}×${#REPLICA_COUNTS[@]}×${#NAMESPACE_COUNTS[@]}×${#SCOPINGS[@]}×${#TRAFFIC_CONFIGS[@]}"

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

# The 51-column TSV schema header. 002 writes the same literal when it runs
# standalone; tests/lib/test/preamble.bats checks that the two are identical.
CONTROLPLANE_TSV_HEADER="timestamp\tcontext\tmesh_size\tservice_count\treplicas\tnamespace_count\tsidecar_scoping\tistiod_mem_mi\tconvergence_p50_ms\tconvergence_p99_ms\tqueue_p50_ms\tqueue_p99_ms\txds_pushes_delta\txds_pushes_rate\txds_pushes_cds\txds_pushes_eds\txds_pushes_lds\txds_pushes_rds\txds_pushes_nds\tk8s_events_delta\tk8s_events_rate\tconnected_proxies\tconfig_size_avg_bytes\tsidecar_config_bytes_avg\tsidecar_config_bytes_p50\tsidecar_config_bytes_max\tsidecar_config_bytes_samples\tscrape_window_sec\tscrape_skew_ms\tsettle_sec\tistiod_restarted\tistiod_cpu_m_delta\tgo_heap_alloc_mi\tgo_heap_inuse_mi\tistiod_cpu_pct_of_limit\tistiod_mem_pct_of_limit\tnode_cpu_pct\tnode_mem_pct\tpods_scheduled\tpods_allocatable\tcluster_connected_proxies\tsidecar_pods\tproxy_check\ttraffic_config\tvsdr_services\tistiod_virt_services\tpush_time_avg_ms\tpushcontext_init_avg_ms\tsidecar_clusters_avg\tsidecar_cds_bytes_avg\tsidecar_rds_bytes_avg"
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
		echo "# CONTROLPLANE_SCHEMA=51"
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
	local needed_pods=$(( max_sc * max_rc ))
	local needed_cpu_m=$(( needed_pods * per_pod_cpu_m ))
	echo "--- Capacity plan check (largest combo: ${max_sc} svc × ${max_rc} rep) ---" >&2
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
# continues. <status> is PROBE_FAILED or SETUP_FAILED.
emit_failed_row() {
	local status="$1" ms="$2" sc="$3" rc="$4" nc="$5" scp="$6" tc="$7"
	local tsv="${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv"
	# Configured VS+DR services for the cell (0 for none), like service_count.
	local vsdr_svcs=0
	[[ "$tc" == vsdr ]] && vsdr_svcs="$(vsdr_service_count "$sc" "$VSDR_EVERY")"
	# Defensive: ensure header exists (pre-create runs before the loop, but keep this
	# idempotent guard so a row is never written into a header-less file).
	if ! grep -q '^timestamp' "$tsv" 2>/dev/null; then
		precreate_tsv_preamble
	fi
	# 51 fields: cols 41-43 (cluster proxies, sidecar pods, proxy check) are N/A too;
	# cols 44-45 keep the cell's traffic config, cols 46-51 are N/A.
	echo -e "$(date -u -Iseconds)\t${status}\t${ms}\t${sc}\t${rc}\t${nc}\t${scp}\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t${SETTLE_SEC}\tunknown\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t${tc}\t${vsdr_svcs}\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A" >> "$tsv"
}

{
	echo "=========================================="
	echo "  Control-Plane Resource Sweep"
	echo "=========================================="
	echo "Contexts:          ${CONTEXTS[*]}"
	echo "Mesh sizes:        ${MESH_SIZES[*]}"
	echo "Service counts:    ${SERVICE_COUNTS[*]}"
	echo "Replica counts:    ${REPLICA_COUNTS[*]}"
	echo "Namespace counts:  ${NAMESPACE_COUNTS[*]}"
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
	echo "Planned matrix:    ${MATRIX_SIZE} = ${MATRIX_FACTORS} (mesh × svc × rep × ns × scope × traffic)"
	echo ""
} >&2

if ((MATRIX_SIZE > MAX_MATRIX)) && ! ((FORCE_LARGE_MATRIX)); then
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

if ((DRY_RUN)); then
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
fi

combo_idx=0
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

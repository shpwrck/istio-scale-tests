#!/usr/bin/env bash
# Orchestrate the churn-dataplane co-exec test across (mesh-size × churn-rate).
# Per mesh-size:
#   setup (001) once
#   for each churn rate × repetition:
#     (after the first) reset churn-targets to base + settle
#     baseline (002): fortio against a steady mesh
#     churn    (003): fortio + concurrent churn; computes Δp99 vs baseline
#   cleanup (006) once, then settle before the next mesh-size
# Under --on-unreachable fail, a baseline that stops on an unreachable remote
# (002 exit 3) records REMOTE_UNREACHABLE rows for its combo and ends the sweep
# after that mesh size's cleanup; the reports still run and the sweep exits 3. A
# combo whose setup, reset or probe failed gets its failed rows and the reports
# still run; the sweep then exits 4 (R19).
#
# Usage:
#   ./tests/churn-dataplane/004-run-sweep.sh [options]
#   # The whole sweep from a run config (mesh sizes, churn rates, durations; flags still win):
#   ./tests/churn-dataplane/004-run-sweep.sh --config tests/churn-dataplane/configs/smoke.env --dry-run
# ci-dry-run:
set -euo pipefail
# Report the failing line on an unexpected abort. Per-combo failures are handled
# below and recorded as row statuses.
trap 'rc=$?; echo "FATAL: ${0##*/} aborted (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # config_preload, config_preamble_lines, config_snapshot
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
# The steps this sweep runs inherit them (and RUN_CONFIG*) from the environment; the
# per-step flags it passes still win.
config_preload churn-dataplane "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fanout.sh" # FANOUT_* defaults + istiod preflight for the preamble
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fortio.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/reach.sh" # REACH_EXIT_CODE, reach_validate

CONTEXTS_CSV=""
MESH_SIZES_CSV="${COEXEC_MESH_SIZES:-}"
CHURN_RATES_CSV="${COEXEC_CHURN_RATES:-1,5,10}"
BASELINE_DURATION="${COEXEC_BASELINE_DURATION_SEC:-60}"
CHURN_DURATION="${COEXEC_CHURN_DURATION_SEC:-60}"
SETTLE_SEC="${COEXEC_SETTLE_SEC:-10}"
INTER_COMBO_SETTLE_SEC="${COEXEC_INTER_COMBO_SETTLE_SEC:-15}"
QPS="${COEXEC_QPS:-200}"
CONNECTIONS="${COEXEC_NUM_CONNECTIONS:-8}"
CHURN_DEPLOYMENT_COUNT_OPT="${CHURN_DEPLOYMENT_COUNT:-5}"
CHURN_BASE_REPLICAS_OPT="${CHURN_BASE_REPLICAS:-1}"
CHURN_SCALE_TO_OPT="${CHURN_SCALE_TO_REPLICAS:-5}"
CHURN_SEED="${COEXEC_CHURN_SEED:-42}"
REPETITIONS="${COEXEC_REPETITIONS:-1}"
MIN_PCT_200="${COEXEC_MIN_PCT_200:-0.99}"
ON_UNREACHABLE="${REACH_ON_UNREACHABLE:-warn}"
REACH_REQUESTS="${REACH_REQUESTS:-10}"
OUTPUT_DIR="$(config_repo_path "${COEXEC_RESULTS_DIR}")"
# Same namespace as 001/002/003/006; used by the reset-to-base step.
NS="${COEXEC_TEST_NAMESPACE:-churn-dataplane-test}"
NS_DELETE_TIMEOUT_SEC="${COEXEC_NS_DELETE_TIMEOUT_SEC:-240}"
# 001's wait for the previous mesh-size's namespace (PL37). options.env defaults it to
# the cleanup bound; --ns-delete-timeout sets both.
SETUP_NS_WAIT_SEC="${COEXEC_SETUP_NS_WAIT_SEC:-$NS_DELETE_TIMEOUT_SEC}"
MATRIX_CAP=64
FORCE_LARGE_MATRIX=0
DRY_RUN=0

usage() {
	local mesh_sizes_default="1..len(contexts)"
	[[ -z "$MESH_SIZES_CSV" ]] || mesh_sizes_default="$MESH_SIZES_CSV"
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE             Run config of KEY=value lines (config/options.env keys; see
                            tests/churn-dataplane/README.md, "Run config"). The steps the
                            sweep runs inherit it. Precedence: flag > --config >
                            environment > default.
  --contexts CSV            All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV          Mesh-size dimension (default: ${mesh_sizes_default}).
  --churn-rates CSV         Churn rate dimension, "deployment scale ops/s" (default: $CHURN_RATES_CSV).
  --baseline-duration SEC   Baseline-phase fortio duration (default: $BASELINE_DURATION).
  --churn-duration SEC      Churn-phase fortio + churn duration (default: $CHURN_DURATION).
  --settle-sec N            Pre-window settle delay (default: $SETTLE_SEC).
  --inter-combo-settle N    Settle gap in seconds (default: $INTER_COMBO_SETTLE_SEC), used between
                            mesh-sizes and after each reset-to-base between churn rates.
  --qps N                   Target QPS for both phases (default: $QPS).
  --connections N           Concurrent fortio connections (default: $CONNECTIONS).
  --deployment-count N      Churn-target Deployments per cluster (default: $CHURN_DEPLOYMENT_COUNT_OPT).
  --base-replicas N         Scale-down replica count (default: $CHURN_BASE_REPLICAS_OPT).
  --scale-to N              Scale-up replica count, above --base-replicas (default: $CHURN_SCALE_TO_OPT).
  --seed N                  Seed for the deterministic churn order (default: $CHURN_SEED).
  --repetitions N           Probe repetitions per combination (default: $REPETITIONS).
  --output-dir DIR          Top-level results directory (default: ${COEXEC_RESULTS_DIR}).
  --ns-delete-timeout SEC   Max wait for namespace deletion (default: $NS_DELETE_TIMEOUT_SEC). Also sets
                            001's wait for the previous mesh-size's namespace to go away,
                            which is otherwise COEXEC_SETUP_NS_WAIT_SEC (default: $SETUP_NS_WAIT_SEC).
  --on-unreachable POLICY   warn or fail, passed to 002 (default: $ON_UNREACHABLE). Under
                            fail, a remote that is UNREACHABLE or UNKNOWN before a baseline
                            records REMOTE_UNREACHABLE rows for that combo and stops the
                            sweep after the mesh size's cleanup (exit 3).
  --reach-requests N        Reach-check requests per target, passed to 002; 0 turns the
                            check off (default: $REACH_REQUESTS).
  --force-large-matrix      Allow more than $MATRIX_CAP combinations.
  --dry-run                 Print plan only; do not touch clusters.
  -h, --help                Show this help.

Note: \`--churn-rates 0\` (or a CSV element with value 0) is accepted and runs
the churn phase against a steady mesh — useful as a sanity check that the
churn phase reports the same numbers as the baseline phase. Rates < 0 are
rejected.

Environment:
  ISTIO_VERSION_CHECK (fail, the default, or warn): stop before any change, or warn and
  record what the mesh runs, when the members' Istio CR version is not ISTIO_VERSION.
  SETUP_CONTEXTS, COEXEC_CHURN_RATES, COEXEC_BASELINE_DURATION_SEC,
  COEXEC_CHURN_DURATION_SEC, COEXEC_SETTLE_SEC, COEXEC_INTER_COMBO_SETTLE_SEC,
  COEXEC_QPS, COEXEC_NUM_CONNECTIONS, COEXEC_CHURN_SEED, COEXEC_REPETITIONS,
  COEXEC_NS_DELETE_TIMEOUT_SEC, COEXEC_SETUP_NS_WAIT_SEC, CHURN_DEPLOYMENT_COUNT, CHURN_BASE_REPLICAS,
  CHURN_SCALE_TO_REPLICAS, COEXEC_MIN_PCT_200 (read by 002/003), REACH_ON_UNREACHABLE,
  REACH_REQUESTS, and REACH_QPS, REACH_HTTP_TIMEOUT_SEC, REACH_DETAIL_TIMEOUT_SEC,
  REACH_ATTEMPTS, REACH_RETRY_SEC (read by 002). COEXEC_MESH_SIZES (--mesh-sizes), COEXEC_RESULTS_DIR (--output-dir;
  relative to the repo root), COEXEC_WAIT_TIMEOUT_SEC and COEXEC_SERVICE_PORT (read by
  001), COEXEC_CLEANUP_GRACE_SEC (read by 006). The sweep checks every numeric one of
  them, and the flags that set them, before the first setup, --dry-run included.

Exit codes:
  0  every cell (mesh size x churn rate x repetition) ran; rows with a non-OK status
     are measurement outcomes, counted in the report's n_total and left out of n_valid
  1  the sweep stopped: a bad flag or precondition, or an unexpected error
  3  --on-unreachable fail stopped the sweep (the reports are written)
  4  the sweep finished and wrote its reports, but N cells failed (setup, churn-target
     reset or a probe exited non-zero); stderr ends with "N of M cells failed" by reason
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--config)
		# Loaded by config_preload above.
		[[ -n "${2:-}" ]] || die "--config requires a value"
		shift 2 ;;
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"; shift 2 ;;
	--mesh-sizes)
		[[ -n "${2:-}" ]] || die "--mesh-sizes requires a value"
		MESH_SIZES_CSV="$2"; shift 2 ;;
	--churn-rates)
		[[ -n "${2:-}" ]] || die "--churn-rates requires a value"
		CHURN_RATES_CSV="$2"; shift 2 ;;
	--baseline-duration)
		[[ -n "${2:-}" ]] || die "--baseline-duration requires a value"
		BASELINE_DURATION="$2"; shift 2 ;;
	--churn-duration)
		[[ -n "${2:-}" ]] || die "--churn-duration requires a value"
		CHURN_DURATION="$2"; shift 2 ;;
	--settle-sec)
		[[ -n "${2:-}" ]] || die "--settle-sec requires a value"
		SETTLE_SEC="$2"; shift 2 ;;
	--inter-combo-settle)
		[[ -n "${2:-}" ]] || die "--inter-combo-settle requires a value"
		INTER_COMBO_SETTLE_SEC="$2"; shift 2 ;;
	--qps)
		[[ -n "${2:-}" ]] || die "--qps requires a value"
		QPS="$2"; shift 2 ;;
	--connections)
		[[ -n "${2:-}" ]] || die "--connections requires a value"
		CONNECTIONS="$2"; shift 2 ;;
	--deployment-count)
		[[ -n "${2:-}" ]] || die "--deployment-count requires a value"
		CHURN_DEPLOYMENT_COUNT_OPT="$2"; shift 2 ;;
	--base-replicas)
		[[ -n "${2:-}" ]] || die "--base-replicas requires a value"
		CHURN_BASE_REPLICAS_OPT="$2"; shift 2 ;;
	--scale-to)
		[[ -n "${2:-}" ]] || die "--scale-to requires a value"
		CHURN_SCALE_TO_OPT="$2"; shift 2 ;;
	--seed)
		[[ -n "${2:-}" ]] || die "--seed requires a value"
		CHURN_SEED="$2"; shift 2 ;;
	--repetitions)
		[[ -n "${2:-}" ]] || die "--repetitions requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--repetitions must be a positive integer"
		(( $2 > 0 )) || die "--repetitions must be > 0"
		REPETITIONS="$2"; shift 2 ;;
	--output-dir)
		[[ -n "${2:-}" ]] || die "--output-dir requires a value"
		OUTPUT_DIR="$2"; shift 2 ;;
	--ns-delete-timeout)
		[[ -n "${2:-}" ]] || die "--ns-delete-timeout requires a value"
		NS_DELETE_TIMEOUT_SEC="$2"; SETUP_NS_WAIT_SEC="$2"; shift 2 ;;
	--on-unreachable)
		[[ -n "${2:-}" ]] || die "--on-unreachable requires a value"
		ON_UNREACHABLE="$2"; shift 2 ;;
	--reach-requests)
		[[ -n "${2:-}" ]] || die "--reach-requests requires a value"
		REACH_REQUESTS="$2"; shift 2 ;;
	--force-large-matrix)
		FORCE_LARGE_MATRIX=1; shift ;;
	--dry-run)
		DRY_RUN=1; shift ;;
	-h | --help)
		usage; exit 0 ;;
	*)
		die "unknown option: $1 (try --help)" ;;
	esac
done

reach_msg="$(reach_validate "$ON_UNREACHABLE")" || die "$reach_msg"
is_ratio "$MIN_PCT_200" || [[ "$MIN_PCT_200" =~ ^0(\.0+)?$ ]] \
	|| die "COEXEC_MIN_PCT_200 must be 0 (rule off) or a decimal in (0,1]; got '$MIN_PCT_200'"
# The churn shape 003 gets: scale-to must exceed base, or the churn phase scales every
# Deployment to the count it already has and its rows still read OK (as tests/churn).
is_pos_int "$CHURN_DEPLOYMENT_COUNT_OPT" || die "--deployment-count (or CHURN_DEPLOYMENT_COUNT) must be a positive integer; got '$CHURN_DEPLOYMENT_COUNT_OPT'"
is_nonneg_int "$CHURN_BASE_REPLICAS_OPT" || die "--base-replicas (or CHURN_BASE_REPLICAS) must be a non-negative integer; got '$CHURN_BASE_REPLICAS_OPT'"
is_pos_int "$CHURN_SCALE_TO_OPT" || die "--scale-to (or CHURN_SCALE_TO_REPLICAS) must be a positive integer; got '$CHURN_SCALE_TO_OPT'"
((CHURN_SCALE_TO_OPT > CHURN_BASE_REPLICAS_OPT)) \
	|| die "--scale-to ($CHURN_SCALE_TO_OPT) must be greater than --base-replicas ($CHURN_BASE_REPLICAS_OPT)"
# The measurement window 002/003 get as flags. 002 builds `fortio -t "${DURATION}s"`, so
# a duration of `5m` would run a 5 ms baseline that every Δp99 is computed against.
is_pos_int "$BASELINE_DURATION" || die "--baseline-duration (or COEXEC_BASELINE_DURATION_SEC) must be a positive integer; got '$BASELINE_DURATION'"
is_pos_int "$CHURN_DURATION" || die "--churn-duration (or COEXEC_CHURN_DURATION_SEC) must be a positive integer; got '$CHURN_DURATION'"
is_pos_int "$QPS" || die "--qps (or COEXEC_QPS) must be a positive integer; got '$QPS'"
is_pos_int "$CONNECTIONS" || die "--connections (or COEXEC_NUM_CONNECTIONS) must be a positive integer; got '$CONNECTIONS'"
is_nonneg_int "$SETTLE_SEC" || die "--settle-sec (or COEXEC_SETTLE_SEC) must be a non-negative integer; got '$SETTLE_SEC'"
is_nonneg_int "$INTER_COMBO_SETTLE_SEC" || die "--inter-combo-settle (or COEXEC_INTER_COMBO_SETTLE_SEC) must be a non-negative integer; got '$INTER_COMBO_SETTLE_SEC'"
is_nonneg_int "$CHURN_SEED" || die "--seed (or COEXEC_CHURN_SEED) must be a non-negative integer; got '$CHURN_SEED'"
is_pos_int "$REPETITIONS" || die "--repetitions (or COEXEC_REPETITIONS) must be a positive integer; got '$REPETITIONS'"
is_pos_int "$NS_DELETE_TIMEOUT_SEC" || die "--ns-delete-timeout (or COEXEC_NS_DELETE_TIMEOUT_SEC) must be a positive integer; got '$NS_DELETE_TIMEOUT_SEC'"
is_nonneg_int "$SETUP_NS_WAIT_SEC" || die "COEXEC_SETUP_NS_WAIT_SEC (read by 001) must be a non-negative integer; got '$SETUP_NS_WAIT_SEC'"
# 001 and 006 read these themselves; reject a bad value before the first setup, also in
# --dry-run, instead of a SETUP_FAILED mesh size or a skipped cleanup.
is_pos_int "${COEXEC_WAIT_TIMEOUT_SEC:-300}" || die "COEXEC_WAIT_TIMEOUT_SEC (read by 001) must be a positive integer; got '${COEXEC_WAIT_TIMEOUT_SEC:-}'"
if ! is_pos_int "${COEXEC_SERVICE_PORT:-8080}" || ((${COEXEC_SERVICE_PORT:-8080} > 65535)); then
	die "COEXEC_SERVICE_PORT (read by 001) must be a port number (1-65535); got '${COEXEC_SERVICE_PORT:-}'"
fi
is_pos_int "${COEXEC_CLEANUP_GRACE_SEC:-5}" || die "COEXEC_CLEANUP_GRACE_SEC (read by 006) must be a positive integer (0 would SIGKILL); got '${COEXEC_CLEANUP_GRACE_SEC:-}'"

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
	((${#MESH_SIZES[@]})) || die "--mesh-sizes produced an empty list (got '${MESH_SIZES_CSV}')"
else
	for ((i = 1; i <= ${#CONTEXTS[@]}; i++)); do MESH_SIZES+=("$i"); done
fi
for ms in "${MESH_SIZES[@]}"; do
	[[ "$ms" =~ ^[0-9]+$ ]] || die "--mesh-sizes: '$ms' is not an integer"
	((ms >= 1 && ms <= ${#CONTEXTS[@]})) || die "mesh-size $ms out of range (have ${#CONTEXTS[@]} contexts)"
done

CHURN_RATES=()
split_csv "$CHURN_RATES_CSV" CHURN_RATES
((${#CHURN_RATES[@]})) || die "--churn-rates resolved to an empty list"
for cr in "${CHURN_RATES[@]}"; do
	[[ "$cr" =~ ^[0-9]+$ ]] || die "--churn-rates: '$cr' is not a non-negative integer"
done

# Matrix cap.
MATRIX_SIZE=$(( ${#MESH_SIZES[@]} * ${#CHURN_RATES[@]} * REPETITIONS ))
if (( MATRIX_SIZE > MATRIX_CAP )); then
	if ((FORCE_LARGE_MATRIX)); then
		echo "warn: matrix is ${MATRIX_SIZE} combinations (> $MATRIX_CAP); --force-large-matrix set, proceeding" >&2
	else
		die "matrix is ${MATRIX_SIZE} combinations (> $MATRIX_CAP). Re-run with --force-large-matrix to bypass."
	fi
fi

# Per-sweep output subdir (created below, not in --dry-run).
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SWEEP_DIR="${OUTPUT_DIR}/sweep-${RUN_ID}"
TSV_FILE="${SWEEP_DIR}/churn-dataplane-${RUN_ID}.tsv"
HARNESS_SHA="$(harness_sha)"

echo "=========================================="
echo "  churn-dataplane co-exec sweep"
echo "=========================================="
echo "Contexts:       ${CONTEXTS[*]}"
echo "Mesh sizes:     ${MESH_SIZES[*]}"
echo "Churn rates:    ${CHURN_RATES[*]} (ops/s)"
echo "Repetitions:    ${REPETITIONS}"
echo "Matrix:         ${MATRIX_SIZE} combinations"
echo "Baseline dur:   ${BASELINE_DURATION}s | Churn dur: ${CHURN_DURATION}s"
echo "Settle:         ${SETTLE_SEC}s | Inter-combo: ${INTER_COMBO_SETTLE_SEC}s"
echo "QPS:            $QPS  Connections: $CONNECTIONS"
echo "Reach check:    ${REACH_REQUESTS} requests per target  On unreachable: ${ON_UNREACHABLE}  Min pct_200: ${MIN_PCT_200}"
echo "Output:         $TSV_FILE"
if [[ "${RUN_CONFIG:-none}" != none ]]; then
	echo "Run config:     ${RUN_CONFIG} (sha256 ${RUN_CONFIG_SHA256:0:12})"
fi
((DRY_RUN)) && echo "Mode:           dry-run"

SCRIPT_DIR="${ROOT}/tests/churn-dataplane"

if command -v kubectl >/dev/null 2>&1 || command -v oc >/dev/null 2>&1; then
	KUBECTL=()
	resolve_kubectl KUBECTL
else
	((DRY_RUN)) || die "neither kubectl nor oc found on PATH"
	KUBECTL=(kubectl) # placeholder for the dry-run plan only
fi

# R4: the Istio version every member runs, read once before the first setup and
# exported, so 001, 002, 003 and this preamble record it (ISTIO_VERSION_CHECK=fail stops
# here on a mismatch). --dry-run reads nothing: the pin, ISTIO_VERSION_SOURCE=pin.
istio_version_resolve "$(IFS=,; echo "${CONTEXTS[*]}")" "$DRY_RUN" "${KUBECTL[@]}"
echo "Istio:          $(istio_version_label)"
mapfile -t IV_KV < <(istio_version_kv)

# Live tuning levers + sidecar egress hosts, read once from CONTEXTS[0] and passed
# to 002/003 and this preamble. Skipped in --dry-run (stays "unknown").
TUNING_BASELINE="unknown"
SIDECAR_EGRESS_HOSTS="unknown"
if ! ((DRY_RUN)); then
	tb_kv=""
	while IFS= read -r tb_kv; do
		case "$tb_kv" in
			TUNING_BASELINE=*) TUNING_BASELINE="${tb_kv#TUNING_BASELINE=}" ;;
			SIDECAR_EGRESS_HOSTS=*) SIDECAR_EGRESS_HOSTS="${tb_kv#SIDECAR_EGRESS_HOSTS=}" ;;
		esac
	done < <(tuning_baseline_state "${CONTEXTS[0]}" "${KUBECTL[@]}")
fi

# Construct preamble + header once at the top of the sweep TSV.
if ! ((DRY_RUN)); then
	mkdir -p "$SWEEP_DIR"
	config_snapshot "$SWEEP_DIR" "$RUN_ID"
	ALL_CTXS_CSV="$(IFS=,; echo "${CONTEXTS[*]}")"
	KUBE_VERSIONS_CSV="$(probe_kube_versions "$ALL_CTXS_CSV" "${KUBECTL[@]}")"
	ISTIOD_REPLICAS="$(fanout_preflight_istiod "${CONTEXTS[0]}" "${KUBECTL[@]}")"
	write_preamble "churn-dataplane co-exec test" "$TSV_FILE" \
		"RUN_ID=$RUN_ID" \
		"HARNESS_SHA=$HARNESS_SHA" \
		"${IV_KV[@]}" \
		"KUBE_VERSIONS=$KUBE_VERSIONS_CSV" \
		"TUNING_BASELINE=$TUNING_BASELINE" \
		"SIDECAR_EGRESS_HOSTS=$SIDECAR_EGRESS_HOSTS" \
		"ISTIOD_REPLICAS=$ISTIOD_REPLICAS" \
		"SETTLE_SEC=$SETTLE_SEC" \
		"BASELINE_DURATION_SEC=$BASELINE_DURATION" \
		"CHURN_DURATION_SEC=$CHURN_DURATION" \
		"QPS=$QPS" \
		"CONNECTIONS=$CONNECTIONS" \
		"NAMESPACE=${COEXEC_TEST_NAMESPACE:-churn-dataplane-test}" \
		"MATRIX_SIZE=$MATRIX_SIZE" \
		"REPETITIONS=$REPETITIONS" \
		"SETUP_NS_WAIT_SEC=$SETUP_NS_WAIT_SEC" \
		"CLEANUP_GRACE_SEC=${COEXEC_CLEANUP_GRACE_SEC:-5}" \
		"NS_DELETE_TIMEOUT_SEC=$NS_DELETE_TIMEOUT_SEC" \
		"FANOUT_MAX_SKEW_MS=$FANOUT_MAX_SKEW_MS" \
		"FANOUT_METRICS_TIMEOUT=$FANOUT_METRICS_TIMEOUT" \
		"MIN_PCT_200=$MIN_PCT_200" \
		"REACH_REQUESTS=$REACH_REQUESTS" \
		"REACH_QPS=${REACH_QPS:-10}" \
		"REACH_HTTP_TIMEOUT_SEC=${REACH_HTTP_TIMEOUT_SEC:-3}" \
		"REACH_DETAIL_TIMEOUT_SEC=${REACH_DETAIL_TIMEOUT_SEC:-35}" \
		"REACH_ATTEMPTS=${REACH_ATTEMPTS:-3}" \
		"REACH_RETRY_SEC=${REACH_RETRY_SEC:-10}" \
		"ON_UNREACHABLE=$ON_UNREACHABLE"
	config_preamble_lines >> "$TSV_FILE"
	printf 'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms\n' >> "$TSV_FILE"
fi

# emit_cd_row <status> <combo_id> <ms> <cr> <phase>
#   Append one degraded 25-col row (restarted=unknown, all numerics N/A).
emit_cd_row() {
	local status="$1" combo_id="$2" ms="$3" cr="$4" phase="$5"
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$RUN_ID" "$HARNESS_SHA" "$combo_id" "$ms" "$cr" "$phase" \
		"0" "0" "0" \
		"N/A" "N/A" "N/A" "N/A" "N/A" \
		"N/A" "unknown" "$status" \
		"N/A" "N/A" \
		"N/A" "N/A" "N/A" "N/A" "N/A" "N/A" >> "$TSV_FILE"
}

# emit_failed_rows <status> <combo_id> <ms> <cr>
#   Emit a baseline AND a churn degraded row so 005 counts the combo in its real
#   (mesh_size, churn_rate) cell (n_total, not n_valid). Used when a combo produced no data.
emit_failed_rows() {
	local status="$1" combo_id="$2" ms="$3" cr="$4"
	emit_cd_row "$status" "$combo_id" "$ms" "$cr" "baseline"
	emit_cd_row "$status" "$combo_id" "$ms" "$cr" "churn"
}

# emit_cleanup_timeout_row <combo_id> <ms> <cr>
#   Record a cleanup failure in the TSV (status=CLEANUP_TIMEOUT).
emit_cleanup_timeout_row() {
	local combo_id="$1" ms="$2" cr="$3"
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$RUN_ID" "$HARNESS_SHA" "$combo_id" "$ms" "$cr" "cleanup" \
		"0" "0" "0" \
		"N/A" "N/A" "N/A" "N/A" "N/A" \
		"N/A" "unknown" "CLEANUP_TIMEOUT" \
		"N/A" "N/A" \
		"N/A" "N/A" "N/A" "N/A" "N/A" "N/A" >> "$TSV_FILE"
}

# combo_id_for <ms> <cr> <rep>
#   Includes -r<rep> only when REPETITIONS > 1.
combo_id_for() {
	if (( REPETITIONS > 1 )); then
		echo "ms$1-cr$2-r$3"
	else
		echo "ms$1-cr$2"
	fi
}

# reset_churn_targets_to_base <active_csv>
#   003 assumes all-base at start and resets the targets when it finishes; this
#   guard repeats the reset (e.g. after an aborted 003) before each later rate's
#   baseline, on every context. Returns non-zero if any context failed; the
#   caller then records RESET_FAILED and skips that rate.
reset_churn_targets_to_base() {
	local csv="$1" rctx rpids=() rpid rc=0
	local rctxs=()
	split_csv "$csv" rctxs
	for rctx in "${rctxs[@]}"; do
		(
			"${KUBECTL[@]}" --context="$rctx" -n "$NS" --request-timeout=10s scale deployment \
				-l churn-target=true --replicas="$CHURN_BASE_REPLICAS_OPT" >/dev/null \
				|| { echo "warn: churn-target reset to base failed on $rctx" >&2; exit 1; }
		) &
		rpids+=($!)
	done
	for rpid in "${rpids[@]}"; do
		wait "$rpid" || rc=1
	done
	return "$rc"
}

COMBO_INDEX=0
# Set when a baseline exits REACH_EXIT_CODE (--on-unreachable fail): the sweep stops
# after this mesh size's cleanup, the reports still run, and the sweep exits 3.
REACH_GATE_STOP=0
# One reason per cell (combo) whose setup, reset or probe failed (R19).
FAILED_CELLS=()
ms_done=0
for ms in "${MESH_SIZES[@]}"; do
	ms_done=$((ms_done + 1))
	active_ctxs=("${CONTEXTS[@]:0:$ms}")
	source_ctx="${active_ctxs[0]}"
	remote_ctxs=()
	((ms > 1)) && remote_ctxs=("${active_ctxs[@]:1}")
	remote_csv=""
	for rc in "${remote_ctxs[@]}"; do
		[[ -n "$remote_csv" ]] && remote_csv+=","
		remote_csv+="$rc"
	done
	active_csv="$(IFS=,; echo "${active_ctxs[*]}")"

	# --- setup once per mesh-size (001) ---
	# --ns-wait-timeout: wait out the previous mesh-size's namespace deletion.
	setup_args=(
		--source-context "$source_ctx"
		--deployment-count "$CHURN_DEPLOYMENT_COUNT_OPT"
		--base-replicas "$CHURN_BASE_REPLICAS_OPT"
		--ns-wait-timeout "$SETUP_NS_WAIT_SEC"
	)
	[[ -n "$remote_csv" ]] && setup_args+=(--remote-contexts "$remote_csv")

	if ((DRY_RUN)); then
		echo "=========================================="
		echo "[mesh-size $ms] ctxs=${active_csv}"
		echo "=========================================="
		echo "  [dry-run] 001 ${setup_args[*]}" >&2
	else
		echo "=========================================="
		echo "[mesh-size $ms] setup  ctxs=${active_csv}"
		echo "=========================================="
		echo "--- setup (once per mesh-size) ---"
		# On setup failure: record SETUP_FAILED rows for every (rate, rep) combo of this
		# mesh-size, clean up, settle and move on.
		if ! "$SCRIPT_DIR/001-setup-coexec-test.sh" "${setup_args[@]}"; then
			echo "warn: [mesh-size $ms] setup failed; recording SETUP_FAILED rows for all rates of this mesh-size and continuing" >&2
			for cr in "${CHURN_RATES[@]}"; do
				for ((rep = 1; rep <= REPETITIONS; rep++)); do
					COMBO_INDEX=$((COMBO_INDEX + 1))
					COMBO_ID="$(combo_id_for "$ms" "$cr" "$rep")"
					emit_failed_rows SETUP_FAILED "$COMBO_ID" "$ms" "$cr"
					FAILED_CELLS+=(SETUP_FAILED)
				done
			done
			"$SCRIPT_DIR/006-cleanup.sh" --contexts "$active_csv" --wait-deletion --timeout "$NS_DELETE_TIMEOUT_SEC" || \
				echo "warn: cleanup after setup failure also reported failure for mesh-size $ms" >&2
			if (( COMBO_INDEX < MATRIX_SIZE )); then sleep "$INTER_COMBO_SETTLE_SEC"; fi
			continue
		fi
	fi

	meshsize_combo_seq=0
	for cr in "${CHURN_RATES[@]}"; do
		for ((rep = 1; rep <= REPETITIONS; rep++)); do
		COMBO_INDEX=$((COMBO_INDEX + 1))
		COMBO_ID="$(combo_id_for "$ms" "$cr" "$rep")"

		echo "=========================================="
		echo "[combo $COMBO_INDEX/$MATRIX_SIZE] $COMBO_ID  rep=$rep/$REPETITIONS  ctxs=${active_csv}  rate=${cr}/s"
		echo "=========================================="

		baseline_args=(
			--source-context "$source_ctx"
			--mesh-size "$ms"
			--combo-id "$COMBO_ID"
			--run-id "$RUN_ID"
			--duration "$BASELINE_DURATION"
			--qps "$QPS"
			--connections "$CONNECTIONS"
			--settle-sec "$SETTLE_SEC"
			--output-file "$TSV_FILE"
			--tuning-baseline "$TUNING_BASELINE"
			--sidecar-egress-hosts "$SIDECAR_EGRESS_HOSTS"
			--on-unreachable "$ON_UNREACHABLE"
			--reach-requests "$REACH_REQUESTS"
			--append
		)
		churn_args=(
			--source-context "$source_ctx"
			--mesh-size "$ms"
			--combo-id "$COMBO_ID"
			--run-id "$RUN_ID"
			--churn-rate "$cr"
			--duration "$CHURN_DURATION"
			--qps "$QPS"
			--connections "$CONNECTIONS"
			--settle-sec "$SETTLE_SEC"
			--deployment-count "$CHURN_DEPLOYMENT_COUNT_OPT"
			--base-replicas "$CHURN_BASE_REPLICAS_OPT"
			--scale-to "$CHURN_SCALE_TO_OPT"
			--seed "$CHURN_SEED"
			--output-file "$TSV_FILE"
			--baseline-file "$TSV_FILE"
			--tuning-baseline "$TUNING_BASELINE"
			--sidecar-egress-hosts "$SIDECAR_EGRESS_HOSTS"
		)
		if [[ -n "$remote_csv" ]]; then
			baseline_args+=(--remote-contexts "$remote_csv")
			churn_args+=(--remote-contexts "$remote_csv")
		fi

		if ((DRY_RUN)); then
			{
				if (( meshsize_combo_seq > 0 )); then
					echo "  [dry-run] reset churn-targets to base (-l churn-target=true) on $active_csv, then sleep $INTER_COMBO_SETTLE_SEC"
				fi
				echo "  [dry-run] 002 ${baseline_args[*]}"
				echo "  [dry-run] 003 ${churn_args[*]}"
			} >&2
			meshsize_combo_seq=$((meshsize_combo_seq + 1))
			continue
		fi

		# After the first rate of a mesh-size, reset churn-targets to base and settle
		# so this baseline starts from the same all-base state. A failed reset records
		# RESET_FAILED for this rate and skips it.
		if (( meshsize_combo_seq > 0 )); then
			echo "--- reset churn-targets to base + settle ---"
			if ! reset_churn_targets_to_base "$active_csv"; then
				echo "warn: [combo $COMBO_INDEX/$MATRIX_SIZE] churn-target reset failed for $COMBO_ID; recording RESET_FAILED rows and skipping this rate's measurement" >&2
				emit_failed_rows RESET_FAILED "$COMBO_ID" "$ms" "$cr"
				FAILED_CELLS+=(RESET_FAILED)
				meshsize_combo_seq=$((meshsize_combo_seq + 1))
				continue
			fi
			echo "Draining reset EDS pushes: settle ${INTER_COMBO_SETTLE_SEC}s before baseline..."
			sleep "$INTER_COMBO_SETTLE_SEC"
		fi
		meshsize_combo_seq=$((meshsize_combo_seq + 1))

		echo "--- baseline phase ---"
		# A failed baseline records PROBE_FAILED rows for both phases (so 005 counts the
		# combo in its real cell) and moves on; the workload stays for the next rate.
		# Exit 3 is the reachability gate (--on-unreachable fail): REMOTE_UNREACHABLE
		# rows for this combo, then leave both loops so the mesh size is cleaned up.
		baseline_rc=0
		"$SCRIPT_DIR/002-run-baseline-probe.sh" "${baseline_args[@]}" || baseline_rc=$?
		if ((baseline_rc == REACH_EXIT_CODE)); then
			echo "STOPPING SWEEP: [combo $COMBO_INDEX/$MATRIX_SIZE] $COMBO_ID stopped on an unreachable remote (--on-unreachable fail); recording REMOTE_UNREACHABLE rows, cleaning up this mesh size, skipping the rest, then writing the reports" >&2
			emit_failed_rows REMOTE_UNREACHABLE "$COMBO_ID" "$ms" "$cr"
			REACH_GATE_STOP=1
			break 2
		elif ((baseline_rc != 0)); then
			echo "warn: [combo $COMBO_INDEX/$MATRIX_SIZE] baseline probe failed for $COMBO_ID (exit $baseline_rc); recording PROBE_FAILED rows and continuing" >&2
			emit_failed_rows PROBE_FAILED "$COMBO_ID" "$ms" "$cr"
			FAILED_CELLS+=(PROBE_FAILED)
			continue
		fi

		echo "--- churn phase ---"
		# A failed churn phase records one PROBE_FAILED churn row (the baseline row exists).
		if ! "$SCRIPT_DIR/003-run-churn-probe.sh" "${churn_args[@]}"; then
			echo "warn: [combo $COMBO_INDEX/$MATRIX_SIZE] churn probe failed for $COMBO_ID; recording PROBE_FAILED row and continuing" >&2
			emit_cd_row PROBE_FAILED "$COMBO_ID" "$ms" "$cr" "churn"
			FAILED_CELLS+=(PROBE_FAILED)
		fi
		done
	done

	# --- cleanup once per mesh-size (006), after all rates ---
	if ((DRY_RUN)); then
		echo "  [dry-run] 006 --contexts $active_csv --wait-deletion --timeout $NS_DELETE_TIMEOUT_SEC" >&2
		if (( COMBO_INDEX < MATRIX_SIZE )); then
			echo "  [dry-run] sleep $INTER_COMBO_SETTLE_SEC before the next mesh-size" >&2
		fi
	else
		echo "--- cleanup (once per mesh-size) ---"
		cleanup_args=(--contexts "$active_csv" --wait-deletion --timeout "$NS_DELETE_TIMEOUT_SEC")
		"$SCRIPT_DIR/006-cleanup.sh" "${cleanup_args[@]}" || {
			echo "warn: cleanup reported failure for mesh-size $ms; recording CLEANUP_TIMEOUT row" >&2
			# combo_id "ms<N>-cleanup"; 005 ignores phase=cleanup rows when bucketing.
			emit_cleanup_timeout_row "ms${ms}-cleanup" "$ms" "0"
		}

		if ((REACH_GATE_STOP)); then
			not_run=("${MESH_SIZES[@]:ms_done}")
			echo "Sweep stopped at mesh-size $ms; mesh sizes not run: ${not_run[*]:-none}" >&2
			break
		fi
		# Settle before the next mesh-size's setup.
		if (( COMBO_INDEX < MATRIX_SIZE )); then
			echo "Inter-mesh-size settle ${INTER_COMBO_SETTLE_SEC}s..."
			sleep "$INTER_COMBO_SETTLE_SEC"
		fi
	fi
done

if ((DRY_RUN)); then
	echo "Dry-run complete. Planned ${MATRIX_SIZE} combinations." >&2
	exit 0
fi

echo "=========================================="
echo "Sweep finished: $TSV_FILE"
echo "Running 005-report-results.sh..."
"$SCRIPT_DIR/005-report-results.sh" --results-dir "$SWEEP_DIR"

MD_FILE="${SWEEP_DIR}/sweep-summary-${RUN_ID}.md"
"$SCRIPT_DIR/005-report-results.sh" --results-dir "$SWEEP_DIR" --format md > "$MD_FILE"
echo "Markdown summary: $MD_FILE"

CHARTS_FILE="${SWEEP_DIR}/sweep-charts-${RUN_ID}.md"
"$SCRIPT_DIR/005-report-results.sh" --results-dir "$SWEEP_DIR" --format charts > "$CHARTS_FILE"
echo "Charts written to $CHARTS_FILE"

# R19: the reports are written; now say how many cells failed. Exit 3 (the reach gate
# stopped the sweep) wins over 4 (some cells failed).
outcome_rc=0 stop_args=()
((REACH_GATE_STOP == 0)) || stop_args=(--stopped "$REACH_EXIT_CODE")
sweep_outcome ${stop_args[@]+"${stop_args[@]}"} "$MATRIX_SIZE" ${FAILED_CELLS[@]+"${FAILED_CELLS[@]}"} || outcome_rc=$?
if ((REACH_GATE_STOP)); then
	echo "Sweep stopped early by the reachability gate (--on-unreachable fail); see Remote coverage in $MD_FILE" >&2
	exit "$REACH_EXIT_CODE"
fi
exit "$outcome_rc"

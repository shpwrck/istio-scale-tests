#!/usr/bin/env bash
# Orchestrate data-plane latency probes across multiple mesh sizes.
# Mints a sweep-${RUN_ID} subdirectory so each sweep's TSVs stay together.
# Under --on-unreachable fail, a probe that stops on an unreachable remote (exit 3)
# ends the sweep after that mesh size's cleanup; the reports still run and the
# sweep exits 3. A mesh size whose setup or probe failed still gets its placeholder
# row and the reports; the sweep then exits 4.
#
# Usage:
#   ./tests/dataplane/003-run-sweep.sh [--contexts CSV] [--mesh-sizes CSV] [options]
#
# Examples:
#   # Sweep 1 and 2 clusters:
#   ./tests/dataplane/003-run-sweep.sh --contexts <mesh-a-ctx>,<mesh-b-ctx>
#
#   # The whole sweep from a run config (mesh sizes, QPS levels, results dir; flags still win):
#   ./tests/dataplane/003-run-sweep.sh --config tests/dataplane/configs/smoke.env --dry-run
# ci-dry-run:
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# Loud ERR trap for unexpected aborts; per-combo failures are handled below.
# sweep_err_trap prints the FATAL line and keeps it as the stop reason a sweep that
# aborts after its start records (the EXIT trap sweep_start sets).
trap 'sweep_err_trap "$?" "$LINENO" "$BASH_COMMAND"' ERR
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # config_preload, config_preamble_lines, config_snapshot
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
# The steps this sweep runs inherit them (and RUN_CONFIG*) from the environment; the
# per-step flags it passes still win.
config_preload dataplane "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"  # tuning_baseline_state
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/platform.sh"  # platform_probe, platform_preamble_lines
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fortio.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/reach.sh"  # REACH_EXIT_CODE, reach_validate

CONTEXTS_CSV=""
MESH_SIZES_CSV="${DATAPLANE_MESH_SIZES:-}"
QPS_LEVELS="${DATAPLANE_QPS_LEVELS:-10,100,500,1000}"
DURATION="${DATAPLANE_DURATION_SEC:-30}"
CONNECTIONS="${DATAPLANE_NUM_CONNECTIONS:-8}"
SETTLE_SEC="${DATAPLANE_SETTLE_SEC:-30}"
WARMUP_DURATION="${DATAPLANE_WARMUP_DURATION_SEC:-5}"
MAX_MATRIX="${DATAPLANE_MAX_MATRIX:-64}"
INTER_COMBO_SETTLE="${DATAPLANE_INTER_COMBO_SETTLE_SEC:-15}"
REPETITIONS="${DATAPLANE_REPETITIONS:-1}"
SERVER_REPLICAS="${DATAPLANE_SERVER_REPLICAS:-2}"
MIN_QPS_RATIO="${DATAPLANE_MIN_QPS_RATIO:-0.95}"
ON_UNREACHABLE="${REACH_ON_UNREACHABLE:-warn}"
REACH_REQUESTS="${REACH_REQUESTS:-10}"
OUTPUT_DIR_BASE="$(config_repo_path "${DATAPLANE_RESULTS_DIR}")"
DRY_RUN=0
FORCE_LARGE_MATRIX=0


usage() {
	local mesh_sizes_default='"1,2,...,len(contexts)"'
	[[ -z "$MESH_SIZES_CSV" ]] || mesh_sizes_default="$MESH_SIZES_CSV"
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE        Run config of KEY=value lines (config/options.env keys; see
                       tests/dataplane/README.md, "Run config"). The steps the sweep
                       runs inherit it. Precedence: flag > --config > environment >
                       default.
  --contexts CSV       All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV     Cluster counts to test (default: ${mesh_sizes_default}).
  --qps-levels CSV     QPS levels to test (default: $QPS_LEVELS).
  --duration SEC       Duration per QPS level (default: $DURATION).
  --connections N      Concurrent connections (default: $CONNECTIONS).
  --settle SEC         Seconds to sleep before probing (default: $SETTLE_SEC).
  --warmup-duration SEC
                       Envoy warmup per probe, 0 to disable (default: $WARMUP_DURATION).
  --output-dir DIR     Base results directory (default: ${DATAPLANE_RESULTS_DIR}).
                       A per-sweep subdir sweep-\${RUN_ID}/ is created here.
  --repetitions N      Probe repetitions per mesh size (default: $REPETITIONS).
  --server-replicas N  fortio server pods per cluster, passed to 001 (default: $SERVER_REPLICAS).
  --min-qps-ratio R    Below R x target QPS a row is QPS_SHORTFALL, passed to 002
                       (default: $MIN_QPS_RATIO).
  --on-unreachable POLICY
                       warn or fail, passed to 002 (default: $ON_UNREACHABLE). Under
                       fail, a remote that is UNREACHABLE or UNKNOWN before the load
                       stops the sweep after that mesh size's cleanup (exit 3).
  --reach-requests N   Reach-check requests per target, passed to 002; 0 turns the
                       check off (default: $REACH_REQUESTS).
  --force-large-matrix Bypass the ${MAX_MATRIX}-combo matrix safety cap.
  --dry-run            Show plan without executing.
  -h, --help           Show this help.

Environment:
  ISTIO_VERSION_CHECK (fail, the default, or warn): before any change, every member's
  Istio version (its active IstioRevision's) is read; one unknown, members that differ, a
  version other than ISTIO_VERSION, or a member still not ready stops the run, or under
  warn is warned about and recorded. ISTIO_VERSION_READY_WAIT_SEC (60): how long the one
  wait for members not ready may take.
  SETUP_CONTEXTS, DATAPLANE_QPS_LEVELS, DATAPLANE_DURATION_SEC,
  DATAPLANE_NUM_CONNECTIONS, DATAPLANE_SETTLE_SEC, DATAPLANE_WARMUP_DURATION_SEC,
  DATAPLANE_MAX_MATRIX, DATAPLANE_INTER_COMBO_SETTLE_SEC, DATAPLANE_REPETITIONS,
  DATAPLANE_SERVER_REPLICAS, DATAPLANE_MIN_QPS_RATIO, DATAPLANE_MIN_PCT_200 (read by 002),
  REACH_ON_UNREACHABLE, REACH_REQUESTS, and REACH_QPS, REACH_HTTP_TIMEOUT_SEC,
  REACH_DETAIL_TIMEOUT_SEC, REACH_ATTEMPTS, REACH_RETRY_SEC (read by 002).
  DATAPLANE_MESH_SIZES (--mesh-sizes), DATAPLANE_RESULTS_DIR (--output-dir; relative
  to the repo root),
  DATAPLANE_WAIT_TIMEOUT_SEC (read by 001), DATAPLANE_NS_DELETE_TIMEOUT_SEC (read by 005).
  The sweep checks every numeric one of them, and the flags that set them, before the
  first setup, --dry-run included.
$(platform_help_lines all)
  SWEEP_STOP_GRACE_SEC (30): how long a signalled sweep waits for its step's processes
  before SIGKILL. Environment only (config/options.env).

Exit codes:
  0  every cell (mesh size) ran; rows with a non-OK status are measurement outcomes,
     counted in the report's n_total and left out of n_valid
  1  the sweep stopped: a bad flag or precondition (or another live run holds the
     sweep dir: .sweep.lock names its PID), or an unexpected error; after its start,
     sweep-outcome.txt records the stop and its reason (STATUS=stopped, STOP_REASON)
  3  --on-unreachable fail stopped the sweep (the reports are written)
  4  the sweep finished and wrote its reports, but N cells failed (setup or probe
     exited non-zero; stderr ends with "N of M cells failed" by reason), or the Istio
     version, the active revision or the generation of the Istio CR or its active
     IstioRevision changed during the sweep (read again at its end), or the harness
     (a file under tests/, config/, charts/ or terraform/) changed during the sweep
     (HARNESS_SHA read at its start and its end); the outcome is also in
     sweep-outcome.txt and every report
  129/130/143  interrupted (SIGHUP, Ctrl-C, SIGTERM): the running step's process group
     gets SIGTERM, and SIGKILL SWEEP_STOP_GRACE_SEC later; sweep-outcome.txt records
     STATUS=interrupted with the signal and its time
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
	--qps-levels)
		[[ -n "${2:-}" ]] || die "--qps-levels requires a value"
		QPS_LEVELS="$2"
		shift 2
		;;
	--duration)
		[[ -n "${2:-}" ]] || die "--duration requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--duration must be a positive integer"
		(( $2 > 0 )) || die "--duration must be > 0"
		DURATION="$2"
		shift 2
		;;
	--connections)
		[[ -n "${2:-}" ]] || die "--connections requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--connections must be a positive integer"
		(( $2 > 0 )) || die "--connections must be > 0"
		CONNECTIONS="$2"
		shift 2
		;;
	--settle)
		[[ -n "${2:-}" ]] || die "--settle requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--settle must be a non-negative integer"
		SETTLE_SEC="$2"
		shift 2
		;;
	--warmup-duration)
		[[ -n "${2:-}" ]] || die "--warmup-duration requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--warmup-duration must be a non-negative integer"
		WARMUP_DURATION="$2"
		shift 2
		;;
	--output-dir)
		[[ -n "${2:-}" ]] || die "--output-dir requires a value"
		OUTPUT_DIR_BASE="$2"
		shift 2
		;;
	--repetitions)
		[[ -n "${2:-}" ]] || die "--repetitions requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--repetitions must be a positive integer"
		(( $2 > 0 )) || die "--repetitions must be > 0"
		REPETITIONS="$2"
		shift 2
		;;
	--server-replicas)
		[[ -n "${2:-}" ]] || die "--server-replicas requires a value"
		SERVER_REPLICAS="$2"
		shift 2
		;;
	--min-qps-ratio)
		[[ -n "${2:-}" ]] || die "--min-qps-ratio requires a value"
		MIN_QPS_RATIO="$2"
		shift 2
		;;
	--on-unreachable)
		[[ -n "${2:-}" ]] || die "--on-unreachable requires a value"
		ON_UNREACHABLE="$2"
		shift 2
		;;
	--reach-requests)
		[[ -n "${2:-}" ]] || die "--reach-requests requires a value"
		REACH_REQUESTS="$2"
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

# The probe window 002 gets as flags; from the environment or --config these reach 002
# unchecked, and a bad one fails every probe.
is_pos_int "$DURATION" || die "--duration (or DATAPLANE_DURATION_SEC) must be a positive integer; got '$DURATION'"
is_pos_int "$CONNECTIONS" || die "--connections (or DATAPLANE_NUM_CONNECTIONS) must be a positive integer; got '$CONNECTIONS'"
is_nonneg_int "$SETTLE_SEC" || die "--settle (or DATAPLANE_SETTLE_SEC) must be a non-negative integer; got '$SETTLE_SEC'"
is_nonneg_int "$WARMUP_DURATION" || die "--warmup-duration (or DATAPLANE_WARMUP_DURATION_SEC) must be a non-negative integer; got '$WARMUP_DURATION'"
is_nonneg_int "$INTER_COMBO_SETTLE" || die "DATAPLANE_INTER_COMBO_SETTLE_SEC must be a non-negative integer; got '$INTER_COMBO_SETTLE'"
is_pos_int "$REPETITIONS" || die "--repetitions (or DATAPLANE_REPETITIONS) must be a positive integer; got '$REPETITIONS'"
is_pos_int "$MAX_MATRIX" || die "DATAPLANE_MAX_MATRIX must be a positive integer; got '$MAX_MATRIX'"
is_pos_int "$SERVER_REPLICAS" || die "--server-replicas (or DATAPLANE_SERVER_REPLICAS) must be a positive integer; got '$SERVER_REPLICAS'"
is_ratio "$MIN_QPS_RATIO" || die "--min-qps-ratio (or DATAPLANE_MIN_QPS_RATIO) must be a decimal in (0,1]; got '$MIN_QPS_RATIO'"
# 002 reads DATAPLANE_MIN_PCT_200 itself; reject a bad value before the first setup.
is_ratio "${DATAPLANE_MIN_PCT_200:-0.99}" || die "DATAPLANE_MIN_PCT_200 must be a decimal in (0,1]; got '${DATAPLANE_MIN_PCT_200:-}'"
# So do 001 and 005 with these; a typo would otherwise fail every setup and skip every
# cleanup (the namespaces stay), and pass --dry-run.
is_pos_int "${DATAPLANE_WAIT_TIMEOUT_SEC:-300}" || die "DATAPLANE_WAIT_TIMEOUT_SEC (read by 001) must be a positive integer; got '${DATAPLANE_WAIT_TIMEOUT_SEC:-}'"
is_pos_int "${DATAPLANE_NS_DELETE_TIMEOUT_SEC:-180}" || die "DATAPLANE_NS_DELETE_TIMEOUT_SEC (read by 005) must be a positive integer; got '${DATAPLANE_NS_DELETE_TIMEOUT_SEC:-}'"
reach_msg="$(reach_validate "$ON_UNREACHABLE")" || die "$reach_msg"

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
	((${#MESH_SIZES[@]})) || die "--mesh-sizes produced an empty list (got '${MESH_SIZES_CSV}')"
else
	for ((i = 1; i <= ${#CONTEXTS[@]}; i++)); do
		MESH_SIZES+=("$i")
	done
fi

for ms in "${MESH_SIZES[@]}"; do
	[[ "$ms" =~ ^[0-9]+$ ]] || die "mesh-size must be a positive integer: $ms"
	((ms >= 1 && ms <= ${#CONTEXTS[@]})) || die "mesh-size $ms out of range (have ${#CONTEXTS[@]} contexts)"
done

SCRIPT_DIR="${ROOT}/tests/dataplane"

# Count QPS levels for matrix size check.
QPS_ARR_TMP=()
split_csv "$QPS_LEVELS" QPS_ARR_TMP
((${#QPS_ARR_TMP[@]})) || die "--qps-levels produced an empty list (got '${QPS_LEVELS}')"
for q in "${QPS_ARR_TMP[@]}"; do
	is_pos_int "$q" || die "--qps-levels (or DATAPLANE_QPS_LEVELS): '$q' is not a positive integer (got '${QPS_LEVELS}')"
done
MATRIX_SIZE=$(( ${#MESH_SIZES[@]} * ${#QPS_ARR_TMP[@]} * REPETITIONS ))
if (( MATRIX_SIZE > MAX_MATRIX )) && (( !FORCE_LARGE_MATRIX )); then
	die "matrix size ${MATRIX_SIZE} exceeds cap ${MAX_MATRIX} (${#MESH_SIZES[@]} mesh_sizes × ${#QPS_ARR_TMP[@]} qps_levels × ${REPETITIONS} reps); use --force-large-matrix to override"
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OUTPUT_DIR="${OUTPUT_DIR_BASE}/sweep-${RUN_ID}"
# The harness at the sweep's start; its results under the output dir do not count, for
# its steps either (HARNESS_SHA_EXCLUDE). sweep_finish reads it again: a harness that
# changed during the sweep is a problem in its outcome (exit 4).
HARNESS_SHA_EXCLUDE="$OUTPUT_DIR_BASE"
[[ "$HARNESS_SHA_EXCLUDE" == /* ]] || HARNESS_SHA_EXCLUDE="${PWD%/}/${HARNESS_SHA_EXCLUDE}"
export HARNESS_SHA_EXCLUDE
HARNESS_SHA="$(harness_sha)"

# Live tuning-baseline provenance, queried once on the source context and passed
# to 002 and the placeholder writer. Skipped in --dry-run (stays "unknown").
TUNING_BASELINE="unknown"
SIDECAR_EGRESS_HOSTS="unknown"
KUBECTL=()
if ((! DRY_RUN)); then
	if command -v kubectl >/dev/null 2>&1 || command -v oc >/dev/null 2>&1; then
		resolve_kubectl KUBECTL
	fi
fi
# The Istio version every member runs, read once before the first setup and
# exported, so 001, 002 and the placeholders record it (ISTIO_VERSION_CHECK=fail stops
# here on a mismatch). --dry-run reads nothing: the pin, ISTIO_VERSION_SOURCE=pin.
istio_version_resolve "$(IFS=,; echo "${CONTEXTS[*]}")" "$DRY_RUN" ${KUBECTL[@]+"${KUBECTL[@]}"}
if ((! DRY_RUN)); then
	if ((${#KUBECTL[@]})); then
		tb_kv=""
		while IFS= read -r tb_kv; do
			case "$tb_kv" in
				TUNING_BASELINE=*) TUNING_BASELINE="${tb_kv#TUNING_BASELINE=}" ;;
				SIDECAR_EGRESS_HOSTS=*) SIDECAR_EGRESS_HOSTS="${tb_kv#SIDECAR_EGRESS_HOSTS=}" ;;
			esac
		done < <(tuning_baseline_state "${CONTEXTS[0]}" "${KUBECTL[@]}")
	fi
fi
# The platform record of every member, read once here; each 002 reads it from
# platform-record.txt in the sweep dir (platform_probe_share) and the placeholders write it
# (tests/lib/platform.sh). --dry-run reads nothing (unknown) and writes no file.
platform_probe "$(IFS=,; echo "${CONTEXTS[*]}")"
platform_probe_share "$OUTPUT_DIR"
platform_start_warnings "$(IFS=,; echo "${CONTEXTS[*]}")"

# Placeholder TSV for a mesh size whose setup/probe failed before writing any row,
# so the size still shows in the report (one qps=0, class=na row; counted in
# n_total, excluded from n_valid).
# Usage: emit_dataplane_placeholder <status> <mesh_size> <source_ctx>
emit_dataplane_placeholder() {
	local status="$1" ms="$2" sctx="$3"
	mkdir -p "$OUTPUT_DIR"
	local f="${OUTPUT_DIR}/latency-zzfail-ms${ms}-${RUN_ID}.tsv"
	{
		echo "# Data-plane latency test (placeholder — mesh size failed before any row)"
		echo "# HARNESS_SHA=${HARNESS_SHA}"
		istio_version_kv | sed 's/^/# /'
		echo "# TUNING_BASELINE=${TUNING_BASELINE}"
		echo "# SIDECAR_EGRESS_HOSTS=${SIDECAR_EGRESS_HOSTS}"
		# Same keys as 002's preamble (PL36); replicas were never read live here.
		echo "# SERVER_REPLICAS=unknown"
		echo "# MIN_QPS_RATIO=${MIN_QPS_RATIO}"
		echo "# MIN_PCT_200=${DATAPLANE_MIN_PCT_200:-0.99}"
		echo "# REACH_REQUESTS=${REACH_REQUESTS}"
		echo "# REACH_QPS=${REACH_QPS:-10}"
		echo "# REACH_HTTP_TIMEOUT_SEC=${REACH_HTTP_TIMEOUT_SEC:-3}"
		echo "# REACH_DETAIL_TIMEOUT_SEC=${REACH_DETAIL_TIMEOUT_SEC:-35}"
		echo "# REACH_ATTEMPTS=${REACH_ATTEMPTS:-3}"
		echo "# REACH_RETRY_SEC=${REACH_RETRY_SEC:-10}"
		echo "# ON_UNREACHABLE=${ON_UNREACHABLE}"
		config_preamble_lines
		platform_preamble_lines "$(IFS=,; echo "${CONTEXTS[*]:0:$ms}")"
		echo "# NOTE=${status}: setup or probe exited non-zero; counted in n_total, excluded from n_valid"
		# 17-col header (matches 002-run-latency-probe.sh).
		printf 'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class\n'
		# One degraded row: qps_target=0, status sentinel, restarted=unknown, class=na.
		printf '%s\t%s\t%s\tN/A\t0\tN/A\t%s\t%s\tN/A\tN/A\tN/A\tN/A\tN/A\t%s\tN/A\tunknown\tna\n' \
			"$RUN_ID" "$ms" "$sctx" "$CONNECTIONS" "$DURATION" "$status"
	} > "$f"
}

echo "=========================================="
echo "  Data-Plane Latency Sweep"
echo "=========================================="
echo "Contexts: ${CONTEXTS[*]}"
echo "Istio: $(istio_version_label)"
echo "Mesh sizes: ${MESH_SIZES[*]}"
echo "QPS levels: $QPS_LEVELS"
echo "Repetitions: ${REPETITIONS}"
echo "Server replicas: ${SERVER_REPLICAS} per cluster | Min QPS ratio: ${MIN_QPS_RATIO}"
echo "Reach check: ${REACH_REQUESTS} requests per target | On unreachable: ${ON_UNREACHABLE}"
echo "Matrix: ${MATRIX_SIZE} combos (cap: ${MAX_MATRIX})"
echo "Settle: ${SETTLE_SEC}s | Warmup: ${WARMUP_DURATION}s | Inter-combo settle: ${INTER_COMBO_SETTLE}s"
echo "Sweep output dir: $OUTPUT_DIR"
if [[ "${RUN_CONFIG:-none}" != none ]]; then
	echo "Run config: ${RUN_CONFIG} (sha256 ${RUN_CONFIG_SHA256:0:12})"
fi
echo ""

# Per-mesh-size dry-run plan goes to stderr so > redirect of stdout still works.
if ((DRY_RUN)); then
	echo "=== Planned matrix (dry-run) ===" >&2
fi

if ((! DRY_RUN)); then
	mkdir -p "$OUTPUT_DIR"
	config_snapshot "$OUTPUT_DIR" "$RUN_ID"
	# The cleanup the console names when the sweep ends before its end.
	SWEEP_CLEANUP_CMD="./tests/dataplane/005-cleanup.sh --contexts $(IFS=,; echo "${CONTEXTS[*]}")"
	# sweep-outcome.txt says the sweep runs until sweep_finish writes its outcome; one that
	# ends before (die, an unexpected abort, Ctrl-C) records how (tests/lib/common.sh).
	sweep_start "$OUTPUT_DIR" "$RUN_ID"
fi

# Set when a probe exits REACH_EXIT_CODE (--on-unreachable fail): the sweep stops
# after this mesh size's cleanup, the reports still run, and the sweep exits 3.
REACH_GATE_STOP=0
# One reason per cell (mesh size) whose setup or probe failed.
FAILED_CELLS=()
ms_done=0
for ms in "${MESH_SIZES[@]}"; do
	ms_done=$((ms_done + 1))
	active_ctxs=("${CONTEXTS[@]:0:$ms}")
	source_ctx="${active_ctxs[0]}"
	remote_ctxs=()
	if ((ms > 1)); then
		remote_ctxs=("${active_ctxs[@]:1}")
	fi
	remote_csv=""
	for rc in ${remote_ctxs[@]+"${remote_ctxs[@]}"}; do
		[[ -n "$remote_csv" ]] && remote_csv+=","
		remote_csv+="$rc"
	done

	echo "=========================================="
	echo "  Sweep: mesh_size=$ms"
	echo "  Source: $source_ctx  Remotes: ${remote_ctxs[*]:-none}"
	echo "=========================================="

	probe_args=(
		--source-context "$source_ctx"
		--mesh-size "$ms"
		--qps-levels "$QPS_LEVELS"
		--duration "$DURATION"
		--connections "$CONNECTIONS"
		--settle "$SETTLE_SEC"
		--warmup-duration "$WARMUP_DURATION"
		--output-dir "$OUTPUT_DIR"
		--tuning-baseline "$TUNING_BASELINE"
		--sidecar-egress-hosts "$SIDECAR_EGRESS_HOSTS"
		--min-qps-ratio "$MIN_QPS_RATIO"
		--on-unreachable "$ON_UNREACHABLE"
		--reach-requests "$REACH_REQUESTS"
	)
	[[ -n "$remote_csv" ]] && probe_args+=(--remote-contexts "$remote_csv")
	setup_args=(--source-context "$source_ctx")
	[[ -n "$remote_csv" ]] && setup_args+=(--remote-contexts "$remote_csv")
	setup_args+=(--server-replicas "$SERVER_REPLICAS")

	if ((DRY_RUN)); then
		{
			echo "  mesh_size=$ms source=$source_ctx remotes=${remote_csv:-none} reps=${REPETITIONS}"
			echo "    001-setup-dataplane-test.sh ${setup_args[*]}"
			for ((rep = 1; rep <= REPETITIONS; rep++)); do
				echo "    [rep $rep/$REPETITIONS] 002-run-latency-probe.sh ${probe_args[*]}"
			done
			echo "    005-cleanup.sh --contexts $(IFS=,; echo "${active_ctxs[*]}")"
		} >&2
		continue
	fi

	echo "--- Setting up ---"
	# A setup failure records a placeholder, cleans up and moves to the next size.
	if ! sweep_step "$SCRIPT_DIR/001-setup-dataplane-test.sh" "${setup_args[@]}"; then
		echo "warn: setup failed for mesh_size=$ms; recording SETUP_FAILED placeholder and continuing" >&2
		emit_dataplane_placeholder SETUP_FAILED "$ms" "$source_ctx"
		FAILED_CELLS+=(SETUP_FAILED)
		sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$(IFS=,; echo "${active_ctxs[*]}")" || \
			echo "warn: cleanup after setup failure also reported failure for mesh_size=$ms" >&2
		echo ""
		continue
	fi
	echo ""

	dp_probe_failed=0
	for ((rep = 1; rep <= REPETITIONS; rep++)); do
		echo "--- Running latency probe (mesh_size=$ms, rep $rep/$REPETITIONS) ---"
		# A probe failure is logged; one placeholder per mesh size is added below.
		# Exit 3 is the reachability gate: 002 already wrote its UNREACHABLE and
		# STOPPED_UNREACHABLE rows, so no PROBE_FAILED placeholder for it.
		probe_rc=0
		sweep_step "$SCRIPT_DIR/002-run-latency-probe.sh" "${probe_args[@]}" || probe_rc=$?
		if ((probe_rc == REACH_EXIT_CODE)); then
			echo "" >&2
			echo "STOPPING SWEEP: mesh_size=$ms rep=$rep/$REPETITIONS stopped on an unreachable remote (--on-unreachable fail); cleaning up this mesh size, skipping the rest, then writing the reports" >&2
			REACH_GATE_STOP=1
			break
		elif ((probe_rc != 0)); then
			echo "warn: latency probe failed for mesh_size=$ms rep=$rep/$REPETITIONS (exit $probe_rc); continuing to next rep/combo" >&2
			dp_probe_failed=1
		fi
		echo ""
	done
	if (( dp_probe_failed )); then
		emit_dataplane_placeholder PROBE_FAILED "$ms" "$source_ctx"
		FAILED_CELLS+=(PROBE_FAILED)
	fi

	echo "--- Cleaning up ---"
	# A cleanup failure only warns; check for a leftover namespace before the next run.
	sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$(IFS=,; echo "${active_ctxs[*]}")" || \
		echo "warn: cleanup reported failure for mesh_size=$ms; a leftover ${DATAPLANE_TEST_NAMESPACE:-dataplane-test} namespace may remain" >&2

	if ((REACH_GATE_STOP)); then
		not_run=("${MESH_SIZES[@]:ms_done}")
		echo "Sweep stopped at mesh_size=$ms; mesh sizes not run: ${not_run[*]:-none}" >&2
		break
	fi
	if ((INTER_COMBO_SETTLE > 0)); then
		echo "Inter-combo settle: ${INTER_COMBO_SETTLE}s..."
		sleep "$INTER_COMBO_SETTLE"
	fi
	echo ""
done

if ((DRY_RUN)); then
	echo "Dry-run complete."
	exit 0
fi
# A build that changed during the sweep goes to its reports (tests/lib/platform.sh).
platform_drift_check "$OUTPUT_DIR" "$(IFS=,; echo "${CONTEXTS[*]}")"

echo "=========================================="
echo "  Sweep finished"
echo "=========================================="
echo ""
# The Istio version again, after the last window and before the reports (read-only): a
# change is a problem of the outcome, a member it cannot confirm a note.
istio_version_recheck ${KUBECTL[@]+"${KUBECTL[@]}"}
# The outcome first (sweep-outcome.txt, which the reports read): how many cells failed.
# Exit 3 (the reach gate stopped the sweep) wins over 4 (some cells failed, or the Istio
# version changed under the sweep).
outcome_rc=0 stop_args=()
((REACH_GATE_STOP == 0)) || stop_args=(--stopped "$REACH_EXIT_CODE" --stop-reason "the reachability gate (--on-unreachable fail) found an unreachable remote; later mesh sizes did not run")
sweep_finish ${stop_args[@]+"${stop_args[@]}"} \
	"${#MESH_SIZES[@]}" ${FAILED_CELLS[@]+"${FAILED_CELLS[@]}"} || outcome_rc=$?
echo "Generating report..."
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$OUTPUT_DIR"

MD_FILE="${OUTPUT_DIR}/sweep-${RUN_ID}.md"
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$OUTPUT_DIR" --format markdown > "$MD_FILE"
echo "Markdown summary written to $MD_FILE"

CHARTS_FILE="${OUTPUT_DIR}/sweep-charts-${RUN_ID}.md"
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$OUTPUT_DIR" --format charts > "$CHARTS_FILE"
echo "Charts written to $CHARTS_FILE"

if ((REACH_GATE_STOP)); then
	echo "Sweep stopped early by the reachability gate (--on-unreachable fail); see Remote coverage in $MD_FILE" >&2
	exit "$REACH_EXIT_CODE"
fi
exit "$outcome_rc"

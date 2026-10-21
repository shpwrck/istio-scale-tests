#!/usr/bin/env bash
# Orchestrate churn probes across mesh sizes and churn intensities.
#
# Usage:
#   ./tests/churn/003-run-sweep.sh [--contexts CSV] [--mesh-sizes CSV] [options]
#
# Examples:
#   ./tests/churn/003-run-sweep.sh --contexts <mesh-a-ctx>,<mesh-b-ctx>
#   ./tests/churn/003-run-sweep.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> --churn-intensities 5,10,20
#   # The whole sweep from a run config (mesh sizes, intensities, results dir; flags still win):
#   ./tests/churn/003-run-sweep.sh --config tests/churn/configs/smoke.env --dry-run
# ci-dry-run:
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# Report the failing line on an unexpected abort. Per-combo setup/probe/cleanup
# failures are handled below and do not stop the sweep.
# sweep_err_trap prints the FATAL line and keeps it as the stop reason a sweep that
# aborts after its start records (the EXIT trap sweep_start sets).
trap 'sweep_err_trap "$?" "$LINENO" "$BASH_COMMAND"' ERR
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # config_preload, config_preamble_lines, config_snapshot
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
# The steps this sweep runs inherit them (and RUN_CONFIG*) from the environment; the
# per-step flags it passes still win.
config_preload churn "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/platform.sh"  # platform_probe, platform_preamble_lines
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/reach.sh"  # reach_sanitize (platform_probe's warnings)

CONTEXTS_CSV=""
MESH_SIZES_CSV="${CHURN_MESH_SIZES:-}"
# Deployment counts (CSV, PL7); empty = the singular CHURN_DEPLOYMENT_COUNT.
CHURN_INTENSITIES_CSV="${CHURN_INTENSITIES:-}"
SCALE_TO="${CHURN_SCALE_TO_REPLICAS:-5}"
ITERATIONS="${CHURN_ITERATIONS:-5}"
TIMEOUT_SEC="${CHURN_TIMEOUT_SEC:-120}"
OUTPUT_DIR_BASE="$(config_repo_path "${CHURN_RESULTS_DIR}")"
DRY_RUN=0


usage() {
	local mesh_sizes_default='"1,2,...,len(contexts)"' intensities_default="\$CHURN_DEPLOYMENT_COUNT"
	[[ -z "$MESH_SIZES_CSV" ]] || mesh_sizes_default="$MESH_SIZES_CSV"
	[[ -z "$CHURN_INTENSITIES_CSV" ]] || intensities_default="$CHURN_INTENSITIES_CSV"
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE             Run config of KEY=value lines (config/options.env keys; see
                            tests/churn/README.md, "Run config"). The steps the sweep
                            runs inherit it. Precedence: flag > --config > environment >
                            default.
  --contexts CSV            All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV          Cluster counts to test (default: ${mesh_sizes_default}).
  --churn-intensities CSV   Deployment counts to test (default: ${intensities_default}).
  --scale-to N              Scale targets to N replicas (default: $SCALE_TO).
  --iterations N            Iterations per combination (default: $ITERATIONS).
  --timeout SEC             Timeout per iteration (default: $TIMEOUT_SEC).
  --output-dir DIR          Results base directory (default: ${CHURN_RESULTS_DIR}).
  --dry-run                 Show plan without executing.
  -h, --help                Show this help.

Exit codes:
  0  every cell (mesh size x churn intensity) ran; rows with a non-OK status are
     measurement outcomes, counted in the report's n_total and left out of n_valid
  1  the sweep stopped: a bad flag or precondition (or another live run holds the
     sweep dir: .sweep.lock names its PID), or an unexpected error; after its start,
     sweep-outcome.txt records the stop and its reason (STATUS=stopped, STOP_REASON)
  4  the sweep finished and wrote its report, but N cells failed (setup or probe
     exited non-zero; stderr ends with "N of M cells failed" by reason), or the Istio
     version, the active revision or the generation of the Istio CR or its active
     IstioRevision changed during the sweep (read again at its end), or that
     end-of-sweep check failed, or the harness (a file under tests/, config/, charts/
     or terraform/) changed during the sweep (HARNESS_SHA read at its start and its
     end); the outcome is also in sweep-outcome.txt and every report
  129/130/143  interrupted (SIGHUP, Ctrl-C, SIGTERM): the running step's process group
     gets SIGTERM, and SIGKILL SWEEP_STOP_GRACE_SEC later; sweep-outcome.txt records
     STATUS=interrupted with the signal and its time

Environment:
  ISTIO_VERSION_CHECK (fail, the default, or warn): stop before any change, or warn and
  record what the mesh runs, when a member's active IstioRevision version is not
  ISTIO_VERSION. ISTIO_VERSION_READY_WAIT_SEC / ISTIO_VERSION_READY_POLL_SEC (60 / 5): how
  long, and how often, to read again a member whose istiod or IstioCNI is not ready, or
  whose istiod is rolling out; a rollout still running after the wait reads as unknown.
  SETUP_CONTEXTS, CHURN_MESH_SIZES (--mesh-sizes), CHURN_INTENSITIES (--churn-intensities;
  empty: CHURN_DEPLOYMENT_COUNT), CHURN_SCALE_TO_REPLICAS, CHURN_ITERATIONS,
  CHURN_TIMEOUT_SEC, CHURN_RESULTS_DIR (--output-dir; relative to the repo root), and
  CHURN_BASE_REPLICAS, CHURN_SETTLE_SEC, CHURN_POLL_INTERVAL_MS, CHURN_WAIT_TIMEOUT_SEC
  (read by 001/002; the sweep checks them before the first setup, --dry-run included).
$(platform_help_lines all)
  SWEEP_STOP_GRACE_SEC (30): how long a signalled sweep waits for its step's processes
  before SIGKILL; ISTIO_PROXY_READ_PARALLEL (20): members whose proxy versions are read
  at once. Environment only (config/options.env).
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
	--churn-intensities)
		[[ -n "${2:-}" ]] || die "--churn-intensities requires a value"
		CHURN_INTENSITIES_CSV="$2"
		shift 2
		;;
	--scale-to)
		[[ -n "${2:-}" ]] || die "--scale-to requires a value"
		SCALE_TO="$2"
		shift 2
		;;
	--iterations)
		[[ -n "${2:-}" ]] || die "--iterations requires a value"
		ITERATIONS="$2"
		shift 2
		;;
	--timeout)
		[[ -n "${2:-}" ]] || die "--timeout requires a value"
		TIMEOUT_SEC="$2"
		shift 2
		;;
	--output-dir)
		[[ -n "${2:-}" ]] || die "--output-dir requires a value"
		OUTPUT_DIR_BASE="$2"
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

platform_validate

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
# A mesh size above the context count would run with fewer remotes than its label says.
for ms in "${MESH_SIZES[@]}"; do
	is_pos_int "$ms" || die "mesh-size must be a positive integer: $ms"
	((ms <= ${#CONTEXTS[@]})) || die "mesh-size $ms out of range (have ${#CONTEXTS[@]} contexts)"
done

INTENSITIES=()
if [[ -n "$CHURN_INTENSITIES_CSV" ]]; then
	split_csv "$CHURN_INTENSITIES_CSV" INTENSITIES
	((${#INTENSITIES[@]})) || die "--churn-intensities produced an empty list (got '${CHURN_INTENSITIES_CSV}')"
else
	INTENSITIES=("${CHURN_DEPLOYMENT_COUNT:-5}")
fi
for ci in "${INTENSITIES[@]}"; do
	is_pos_int "$ci" || die "churn intensity must be a positive integer (--churn-intensities, CHURN_INTENSITIES or CHURN_DEPLOYMENT_COUNT): $ci"
done

is_pos_int "$SCALE_TO" || die "--scale-to must be a positive integer"
is_nonneg_int "${CHURN_BASE_REPLICAS:-1}" || die "CHURN_BASE_REPLICAS (read by 001/002) must be a non-negative integer; got '${CHURN_BASE_REPLICAS:-}'"
((SCALE_TO > ${CHURN_BASE_REPLICAS:-1})) || die "--scale-to ($SCALE_TO) must be greater than CHURN_BASE_REPLICAS (${CHURN_BASE_REPLICAS:-1})"
is_pos_int "$ITERATIONS" || die "--iterations (or CHURN_ITERATIONS) must be a positive integer; got '$ITERATIONS'"
is_pos_int "$TIMEOUT_SEC" || die "--timeout (or CHURN_TIMEOUT_SEC) must be a positive integer; got '$TIMEOUT_SEC'"
# 001 and 002 read these themselves; reject a bad value before the first setup, also in
# --dry-run, instead of a SETUP_FAILED or PROBE_FAILED row per combo.
is_pos_int "${CHURN_WAIT_TIMEOUT_SEC:-300}" || die "CHURN_WAIT_TIMEOUT_SEC (read by 001) must be a positive integer; got '${CHURN_WAIT_TIMEOUT_SEC:-}'"
is_nonneg_int "${CHURN_SETTLE_SEC:-3}" || die "CHURN_SETTLE_SEC (read by 002) must be a non-negative integer; got '${CHURN_SETTLE_SEC:-}'"
is_pos_int "${CHURN_POLL_INTERVAL_MS:-250}" || die "CHURN_POLL_INTERVAL_MS (read by 002) must be a positive integer; got '${CHURN_POLL_INTERVAL_MS:-}'"

SCRIPT_DIR="${ROOT}/tests/churn"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SWEEP_DIR="${OUTPUT_DIR_BASE}/sweep-${RUN_ID}"
# The harness at the sweep's start; its results under the output dir do not count, for
# its steps either (HARNESS_SHA_EXCLUDE). sweep_finish reads it again: a harness that
# changed during the sweep is a problem in its outcome (exit 4).
HARNESS_SHA_EXCLUDE="$OUTPUT_DIR_BASE"
[[ "$HARNESS_SHA_EXCLUDE" == /* ]] || HARNESS_SHA_EXCLUDE="${PWD%/}/${HARNESS_SHA_EXCLUDE}"
export HARNESS_SHA_EXCLUDE
HARNESS_SHA="$(harness_sha)"
# base_replicas the probe will use, so placeholder rows land in the same report cell.
CHURN_BASE_REPLICAS_DEFAULT="${CHURN_BASE_REPLICAS:-1}"

# Live tuning levers + sidecar egress hosts, read once from CONTEXTS[0] and passed
# to every probe and placeholder row. Skipped in --dry-run (stays "unknown").
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
platform_probe_share "$SWEEP_DIR"
platform_start_warnings "$(IFS=,; echo "${CONTEXTS[*]}")"

# Write a one-row placeholder TSV for a combo whose setup or probe failed before
# any row was written, so the report still counts it (n_total, not n_valid).
# Usage: emit_churn_placeholder <status> <mesh_size> <intensity>
emit_churn_placeholder() {
	local status="$1" ms="$2" intensity="$3"
	mkdir -p "$SWEEP_DIR"
	local f="${SWEEP_DIR}/churn-zzfail-ms${ms}-i${intensity}-${RUN_ID}.tsv"
	{
		echo "# Churn convergence test (placeholder — combo failed before any row)"
		echo "# HARNESS_SHA=${HARNESS_SHA}"
		istio_version_kv | sed 's/^/# /'
		# Same preamble keys as 002 (004 may read this file first); read now, after the failure.
		echo "# KUBE_VERSIONS=$(probe_kube_versions "$(IFS=,; echo "${CONTEXTS[*]:0:$ms}")" "${KUBECTL[@]}")"
		echo "# CHURN_SCALE_SCOPE=source"
		echo "# TUNING_BASELINE=${TUNING_BASELINE}"
		echo "# SIDECAR_EGRESS_HOSTS=${SIDECAR_EGRESS_HOSTS}"
		config_preamble_lines
		platform_preamble_lines "$(IFS=,; echo "${CONTEXTS[*]:0:$ms}")"
		echo "# NOTE=${status}: setup or probe exited non-zero; counted in n_total, excluded from n_valid"
		# 21-col header (matches 002-run-churn-probe.sh).
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			run_id mesh_size churn_intensity base_replicas scale_to iteration t0_epoch_ns \
			convergence_local_ms remote_endpoint_reachable_ms convergence_remote_eds_ms \
			source_push_triggers_delta remote_push_triggers_delta \
			source_xds_pushes_delta remote_xds_pushes_delta \
			source_queue_time_p99_ms remote_queue_time_p99_ms \
			source_connected_proxies remote_connected_proxies \
			source_push_time_p99_ms remote_push_time_p99_ms \
			status
		# One degraded row: key cols set, numerics N/A, status sentinel in $21.
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$RUN_ID" "$ms" "$intensity" "$CHURN_BASE_REPLICAS_DEFAULT" "$SCALE_TO" "0" "N/A" \
			"N/A" "N/A" "N/A" \
			"N/A" "N/A" \
			"N/A" "N/A" \
			"N/A" "N/A" \
			"N/A" "N/A" \
			"N/A" "N/A" \
			"$status"
	} > "$f"
}

echo "=========================================="
echo "  Churn Convergence Sweep"
echo "=========================================="
echo "Run ID: $RUN_ID"
echo "Contexts: ${CONTEXTS[*]}"
echo "Istio: $(istio_version_label)"
echo "Mesh sizes: ${MESH_SIZES[*]}"
echo "Churn intensities: ${INTENSITIES[*]}"
echo "Scale: -> $SCALE_TO replicas"
echo "Output: $SWEEP_DIR"
if [[ "${RUN_CONFIG:-none}" != none ]]; then
	echo "Run config: ${RUN_CONFIG} (sha256 ${RUN_CONFIG_SHA256:0:12})"
fi
echo ""
if ((! DRY_RUN)); then
	config_snapshot "$SWEEP_DIR" "$RUN_ID"
	# The cleanup the console names when the sweep ends before its end.
	SWEEP_CLEANUP_CMD="./tests/churn/005-cleanup.sh --contexts $(IFS=,; echo "${CONTEXTS[*]}")"
	# sweep-outcome.txt says the sweep runs until sweep_finish writes its outcome; one that
	# ends before (die, an unexpected abort, Ctrl-C) records how (tests/lib/common.sh).
	sweep_start "$SWEEP_DIR" "$RUN_ID"
fi

# One reason per cell whose setup or probe failed: reported, then the exit code.
FAILED_CELLS=()
for ms in "${MESH_SIZES[@]}"; do
	active_ctxs=("${CONTEXTS[@]:0:$ms}")
	active_csv=$(IFS=,; echo "${active_ctxs[*]}")
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

	for intensity in "${INTENSITIES[@]}"; do
		echo "=========================================="
		echo "  Sweep: mesh_size=$ms  churn_intensity=$intensity"
		echo "  Clusters: ${active_ctxs[*]}"
		echo "=========================================="

		probe_args=(
			--source-context "$source_ctx"
			--mesh-size "$ms"
			--deployment-count "$intensity"
			--scale-to "$SCALE_TO"
			--iterations "$ITERATIONS"
			--timeout "$TIMEOUT_SEC"
			--output-dir "$SWEEP_DIR"
			--tuning-baseline "$TUNING_BASELINE"
			--sidecar-egress-hosts "$SIDECAR_EGRESS_HOSTS"
		)
		[[ -n "$remote_csv" ]] && probe_args+=(--remote-contexts "$remote_csv")

		if ((DRY_RUN)); then
			echo "  [dry-run] Would run:"
			echo "    001-setup-churn-test.sh --contexts $active_csv --deployment-count $intensity"
			echo "    002-run-churn-probe.sh ${probe_args[*]}"
			echo "    005-cleanup.sh --contexts $active_csv"
			echo ""
			continue
		fi

		[[ -d "$SWEEP_DIR" ]] || mkdir -p "$SWEEP_DIR"

		echo "--- Setting up ---"
		# On setup failure: record a placeholder row, clean up, next combo.
		if ! sweep_step "$SCRIPT_DIR/001-setup-churn-test.sh" --contexts "$active_csv" --deployment-count "$intensity"; then
			echo "warn: setup failed for mesh_size=$ms churn_intensity=$intensity; recording SETUP_FAILED placeholder and continuing" >&2
			emit_churn_placeholder SETUP_FAILED "$ms" "$intensity"
			FAILED_CELLS+=(SETUP_FAILED)
			sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
				echo "warn: cleanup after setup failure also reported failure for mesh_size=$ms churn_intensity=$intensity" >&2
			echo ""
			continue
		fi
		echo ""

		echo "--- Running churn probe ---"
		# A probe failure must not abort the sweep; record a placeholder row so the
		# combo stays visible even if the probe wrote nothing.
		if ! sweep_step "$SCRIPT_DIR/002-run-churn-probe.sh" "${probe_args[@]}"; then
			echo "warn: churn probe failed for mesh_size=$ms churn_intensity=$intensity; recording PROBE_FAILED placeholder and continuing (cleanup runs below)" >&2
			emit_churn_placeholder PROBE_FAILED "$ms" "$intensity"
			FAILED_CELLS+=(PROBE_FAILED)
		fi
		echo ""

		echo "--- Cleaning up ---"
		# A cleanup failure must not abort the sweep.
		sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
			echo "warn: cleanup reported failure for mesh_size=$ms churn_intensity=$intensity; continuing" >&2
		echo ""
	done
done

if ((DRY_RUN)); then
	echo "Dry-run complete."
	exit 0
fi
# A build that changed during the sweep goes to its reports (tests/lib/platform.sh).
platform_drift_check "$SWEEP_DIR" "$(IFS=,; echo "${CONTEXTS[*]}")"

echo "=========================================="
echo "  Sweep finished"
echo "=========================================="
echo ""
# The Istio version again, after the last window and before the reports (read-only).
IV_END=()
istio_version_recheck IV_END ${KUBECTL[@]+"${KUBECTL[@]}"}
# The outcome first (sweep-outcome.txt, which the reports read): how many cells failed,
# and exit non-zero if any did (or the Istio version changed under the sweep).
outcome_rc=0
sweep_finish ${IV_END[@]+"${IV_END[@]}"} \
	"$(( ${#MESH_SIZES[@]} * ${#INTENSITIES[@]} ))" ${FAILED_CELLS[@]+"${FAILED_CELLS[@]}"} || outcome_rc=$?
echo "Generating report..."
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$SWEEP_DIR"

MD_FILE="${SWEEP_DIR}/sweep-${RUN_ID}.md"
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$SWEEP_DIR" --format md > "$MD_FILE"
echo "Markdown summary written to $MD_FILE"

CHARTS_FILE="${SWEEP_DIR}/sweep-charts-${RUN_ID}.md"
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$SWEEP_DIR" --format charts > "$CHARTS_FILE"
echo "Charts written to $CHARTS_FILE"
exit "$outcome_rc"

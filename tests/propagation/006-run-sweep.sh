#!/usr/bin/env bash
# Run the endpoint propagation probe at each mesh size (1, 2, ... N clusters)
# and write one per-sweep results directory for side-by-side comparison.
#
# Usage:
#   ./tests/propagation/006-run-sweep.sh [--contexts CSV] [--mesh-sizes CSV] [--iterations N] [options]
#
# Examples:
#   # Sweep 1 and 2 clusters (TSVs and the 005 reports are always written):
#   ./tests/propagation/006-run-sweep.sh --contexts <mesh-a-ctx>,<mesh-b-ctx>
#
#   # Dry-run to see what would be executed:
#   ./tests/propagation/006-run-sweep.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> --dry-run
#
#   # The whole sweep from a run config (mesh sizes, iterations, results dir; flags still win):
#   ./tests/propagation/006-run-sweep.sh --config tests/propagation/configs/smoke.env --dry-run
# ci-dry-run:
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# Loud ERR trap for unexpected aborts; per-step failures are handled below.
# sweep_err_trap prints the FATAL line and keeps it as the stop reason a sweep that
# aborts after its start records (the EXIT trap sweep_start sets).
trap 'sweep_err_trap "$?" "$LINENO" "$BASH_COMMAND"' ERR
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # config_preload, config_preamble_lines, config_snapshot
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
# The steps this sweep runs inherit them (and RUN_CONFIG*) from the environment; the
# per-step flags it passes still win.
config_preload propagation "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"  # tuning_baseline_state
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/propagation.sh"  # PROP_TSV_HEADER, prop_placeholder_row (PL36)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/platform.sh"  # platform_probe, platform_preamble_lines
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/reach.sh"  # reach_sanitize (platform_probe's warnings)

CONTEXTS_CSV=""
MESH_SIZES_CSV="${PROPAGATION_MESH_SIZES:-}"
ITERATIONS="${PROPAGATION_ITERATIONS}"
TIMEOUT_SEC="${PROPAGATION_TIMEOUT_SEC}"
SETTLE_SEC="${PROPAGATION_SETTLE_SEC}"
MAX_MATRIX="${PROPAGATION_MAX_MATRIX:-64}"
OUTPUT_DIR="$(config_repo_path "${PROPAGATION_RESULTS_DIR}")"
WATCHER_REPLICAS="${PROPAGATION_WATCHER_REPLICAS}"
DRY_RUN=0
COLLECT_METRICS=0
FORCE_LARGE_MATRIX=0


usage() {
	local mesh_sizes_default='"1,2,...,len(contexts)"'
	[[ -z "$MESH_SIZES_CSV" ]] || mesh_sizes_default="$MESH_SIZES_CSV"
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE          Run config of KEY=value lines (config/options.env keys; see
                         tests/propagation/README.md, "Run config"). The steps the
                         sweep runs inherit it. Precedence: flag > --config >
                         environment > default.
  --contexts CSV         All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV       Cluster counts to test (default: ${mesh_sizes_default}).
  --watcher-replicas N   Watcher pod replicas per cluster
                         (default: \$PROPAGATION_WATCHER_REPLICAS=$WATCHER_REPLICAS).
  --iterations N         Iterations per mesh size (default: \$PROPAGATION_ITERATIONS=$ITERATIONS).
  --timeout SEC          Timeout per iteration (default: \$PROPAGATION_TIMEOUT_SEC=$TIMEOUT_SEC).
  --settle-sec SEC       Settle gap between iterations and between mesh-size steps (default: $SETTLE_SEC).
  --output-dir DIR       Results root (default: ${PROPAGATION_RESULTS_DIR}). A new
                         per-sweep subdir 'sweep-\${RUN_ID}/' is created underneath.
  --tsv                  Accepted for old command lines; does nothing. The sweep always
                         writes per-iteration TSVs and the 005 reports (sweep-summary.md,
                         sweep-charts.md).
  --collect-metrics      Also run 004-collect-pilot-metrics.sh at each mesh size.
  --force-large-matrix   Bypass matrix safety cap (default: $MAX_MATRIX iterations).
  --dry-run              Print planned matrix to stderr; exit without touching clusters.
  -h, --help             Show this help.

Environment:
  ISTIO_VERSION_CHECK (fail, the default, or warn): before any change, every member's
  Istio version (its active IstioRevision's) is read; one unknown, members that differ, a
  version other than ISTIO_VERSION, or a member still not ready stops the run, or under
  warn is warned about and recorded. ISTIO_VERSION_READY_WAIT_SEC (60): how long the one
  wait for members not ready may take.
  SETUP_CONTEXTS, PROPAGATION_ITERATIONS, PROPAGATION_TIMEOUT_SEC, PROPAGATION_SETTLE_SEC,
  PROPAGATION_WATCHER_REPLICAS, PROPAGATION_MAX_MATRIX. PROPAGATION_MESH_SIZES
  (--mesh-sizes), PROPAGATION_RESULTS_DIR (--output-dir; relative to the repo root),
  PROPAGATION_WAIT_TIMEOUT_SEC (read by 001), PROPAGATION_POLL_INTERVAL_MS and
  PROPAGATION_DRAIN_TIMEOUT_SEC (read by 002); the sweep checks these before the first
  setup, --dry-run included.
  TEST_PLATFORM (${TEST_PLATFORM:-auto}), PLATFORM_READ_TIMEOUT (${PLATFORM_READ_TIMEOUT}) and
  PLATFORM_READ_PARALLEL (${PLATFORM_READ_PARALLEL}): the platform record's reads (config/options.env).
  SWEEP_STOP_GRACE_SEC (30): how long a signalled sweep waits for its step's processes
  before SIGKILL. Environment only (config/options.env).

Exit codes:
  0  every cell (mesh size) ran; rows with a non-OK status are measurement outcomes,
     counted in the report's n_total and left out of n_valid
  1  the sweep stopped: a bad flag or precondition (or another live run holds the
     sweep dir: .sweep.lock names its PID), or an unexpected error; after its start,
     sweep-outcome.txt records the stop and its reason (STATUS=stopped, STOP_REASON)
  4  the sweep finished and wrote its reports, but N cells failed (setup or probe
     exited non-zero; stderr ends with "N of M cells failed" by reason), or the Istio
     version, the active revision or the generation of the Istio CR or its active
     IstioRevision changed during the sweep (read again at its end), or a member's
     platform record (a build, istiod's env: read again at its end), or the harness
     (a file under tests/, config/, charts/ or terraform/) changed during the sweep
     (HARNESS_SHA read at its start and its end); the outcome is also in
     sweep-outcome.txt and every report
  129/130/143  interrupted (SIGHUP, Ctrl-C, SIGTERM): the running step's process group
     gets SIGTERM, and SIGKILL SWEEP_STOP_GRACE_SEC later; sweep-outcome.txt records
     STATUS=interrupted with the signal and its time, then the sweep's exit runs
     007-cleanup.sh on every member
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
	--settle-sec)
		[[ -n "${2:-}" ]] || die "--settle-sec requires a value"
		SETTLE_SEC="$2"
		shift 2
		;;
	--output-dir)
		[[ -n "${2:-}" ]] || die "--output-dir requires a value"
		OUTPUT_DIR="$2"
		shift 2
		;;
	--collect-metrics)
		COLLECT_METRICS=1
		shift
		;;
	--tsv)
		# A no-op: TSVs and reports are always written.
		echo "note: --tsv is the default now (the sweep always writes the TSVs and the 005 reports); it changes nothing" >&2
		shift
		;;
	--watcher-replicas)
		[[ -n "${2:-}" ]] || die "--watcher-replicas requires a value"
		WATCHER_REPLICAS="$2"
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
	is_pos_int "$ms" || die "mesh-size must be a positive integer: $ms"
	((ms <= ${#CONTEXTS[@]})) || die "mesh-size $ms out of range (have ${#CONTEXTS[@]} contexts)"
done
is_pos_int "$ITERATIONS" || die "--iterations must be a positive integer (got: $ITERATIONS)"
is_pos_int "$TIMEOUT_SEC" || die "--timeout (or PROPAGATION_TIMEOUT_SEC) must be a positive integer (got: $TIMEOUT_SEC)"
is_nonneg_int "$SETTLE_SEC" || die "--settle-sec (or PROPAGATION_SETTLE_SEC) must be a non-negative integer (got: $SETTLE_SEC)"
is_pos_int "$WATCHER_REPLICAS" || die "--watcher-replicas (or PROPAGATION_WATCHER_REPLICAS) must be a positive integer (got: $WATCHER_REPLICAS)"
# 001 and 002 read these themselves; reject a bad value before the first setup, also in
# --dry-run.
is_pos_int "${PROPAGATION_WAIT_TIMEOUT_SEC:-300}" || die "PROPAGATION_WAIT_TIMEOUT_SEC (read by 001) must be a positive integer (got: ${PROPAGATION_WAIT_TIMEOUT_SEC:-})"
is_pos_int "${PROPAGATION_POLL_INTERVAL_MS:-250}" || die "PROPAGATION_POLL_INTERVAL_MS (read by 002) must be a positive integer (got: ${PROPAGATION_POLL_INTERVAL_MS:-})"
is_pos_int "${PROPAGATION_DRAIN_TIMEOUT_SEC:-20}" || die "PROPAGATION_DRAIN_TIMEOUT_SEC (read by 002) must be a positive integer (got: ${PROPAGATION_DRAIN_TIMEOUT_SEC:-})"

MATRIX_SIZE=$(( ${#MESH_SIZES[@]} * ITERATIONS ))
if (( MATRIX_SIZE > MAX_MATRIX && !FORCE_LARGE_MATRIX )); then
	die "matrix too large: ${#MESH_SIZES[@]} mesh_sizes × $ITERATIONS iterations = $MATRIX_SIZE (max $MAX_MATRIX). Use --force-large-matrix to override."
fi

SCRIPT_DIR="${ROOT}/tests/propagation"
SWEEP_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SWEEP_DIR="${OUTPUT_DIR}/sweep-${SWEEP_RUN_ID}"
# The harness at the sweep's start; its results under the output dir do not count, for
# its steps either (HARNESS_SHA_EXCLUDE). sweep_finish reads it again: a harness that
# changed during the sweep is a problem in its outcome (exit 4).
HARNESS_SHA_EXCLUDE="$OUTPUT_DIR"
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
platform_probe_share "$SWEEP_DIR"
platform_start_warnings "$(IFS=,; echo "${CONTEXTS[*]}")"

# Placeholder TSV for a mesh size whose setup/probe failed before writing any row,
# so the size still shows in the report (counted in n_total, excluded from n_valid).
# Carries the same sweep-level preamble keys as 002.
# Usage: emit_propagation_placeholder <status> <mesh_size> <source_ctx>
emit_propagation_placeholder() {
	local status="$1" ms="$2" sctx="$3"
	mkdir -p "$SWEEP_DIR"
	local f="${SWEEP_DIR}/endpoint-zzfail-ms${ms}-${SWEEP_RUN_ID}.tsv"
	{
		echo "# Endpoint propagation latency test (placeholder — combo failed before any row)"
		echo "# SWEEP_RUN_ID=${SWEEP_RUN_ID}"
		echo "# RUN_ID=${SWEEP_RUN_ID}-failms${ms}"
		echo "# HARNESS_SHA=${HARNESS_SHA}"
		istio_version_kv | sed 's/^/# /'
		echo "# SOURCE_CTX=${sctx}"
		echo "# MESH_SIZE=${ms}"
		echo "# ITERATIONS=${ITERATIONS}"
		echo "# TIMEOUT_SEC=${TIMEOUT_SEC}"
		echo "# SETTLE_SEC=${SETTLE_SEC}"
		echo "# TUNING_BASELINE=${TUNING_BASELINE}"
		echo "# SIDECAR_EGRESS_HOSTS=${SIDECAR_EGRESS_HOSTS}"
		config_preamble_lines
		platform_preamble_lines "$(IFS=,; echo "${CONTEXTS[*]:0:$ms}")"
		echo "# NOTE=${status}: setup or probe exited non-zero; counted in n_total, excluded from n_valid"
		# The schema 002 writes (PL36: one header, tests/lib/propagation.sh).
		printf '%s\n' "$PROP_TSV_HEADER"
		# One degraded row: the status in status, p1_status and remote_status,
		# restarted=unknown, numerics N/A.
		prop_placeholder_row "${SWEEP_RUN_ID}-failms${ms}" "$ms" "$sctx" "$status"
	} > "$f"
}

# plan_mesh_size <ms>: set active_ctxs, inactive_ctxs, source_ctx, remote_csv and
# endpoint_args (the exact 002 arguments) for one mesh size.
plan_mesh_size() {
	local ms="$1" c ac match
	active_ctxs=("${CONTEXTS[@]:0:$ms}")
	source_ctx="${active_ctxs[0]}"
	remote_csv="$(IFS=,; echo "${active_ctxs[*]:1}")"
	inactive_ctxs=()
	for c in "${CONTEXTS[@]}"; do
		match=0
		for ac in "${active_ctxs[@]}"; do [[ "$c" == "$ac" ]] && { match=1; break; }; done
		((match)) || inactive_ctxs+=("$c")
	done
	endpoint_args=(
		--source-context "$source_ctx"
		--mesh-size "$ms"
		--sweep-run-id "$SWEEP_RUN_ID"
		--iterations "$ITERATIONS"
		--timeout "$TIMEOUT_SEC"
		--settle-sec "$SETTLE_SEC"
		--output-dir "$SWEEP_DIR"
		--tuning-baseline "$TUNING_BASELINE"
		--sidecar-egress-hosts "$SIDECAR_EGRESS_HOSTS"
		--tsv
	)
	[[ -n "$remote_csv" ]] && endpoint_args+=(--remote-contexts "$remote_csv")
	return 0
}

# --- dry-run: print planned matrix to stderr, exit cleanly --------------------
if ((DRY_RUN)); then
	{
		echo "=========================================="
		echo "  Propagation Latency Sweep [DRY RUN]"
		echo "=========================================="
		echo "Contexts: ${CONTEXTS[*]}"
		echo "Mesh sizes: ${MESH_SIZES[*]}"
		echo "Iterations per size: $ITERATIONS"
		echo "Total iterations: $MATRIX_SIZE (cap: $MAX_MATRIX)"
		echo "Settle: ${SETTLE_SEC}s"
		echo "Istio: $(istio_version_label); live check ISTIO_VERSION_CHECK=${ISTIO_VERSION_CHECK:-fail} skipped in --dry-run"
		echo "Output (would create): $SWEEP_DIR"
		if [[ "${RUN_CONFIG:-none}" != none ]]; then
			echo "Run config: ${RUN_CONFIG} (sha256 ${RUN_CONFIG_SHA256:0:12})"
		fi
		echo ""
		for ms in "${MESH_SIZES[@]}"; do
			plan_mesh_size "$ms"
			echo "--- Plan: mesh_size=$ms ---"
			if ((${#inactive_ctxs[@]})); then
				echo "  007-cleanup.sh --contexts $(IFS=,; echo "${inactive_ctxs[*]}")"
			fi
			echo "  001-setup-propagation-test.sh --contexts $(IFS=,; echo "${active_ctxs[*]}") --watcher-replicas $WATCHER_REPLICAS"
			echo "  002-run-endpoint-probe.sh ${endpoint_args[*]}"
			if ((COLLECT_METRICS)); then
				echo "  004-collect-pilot-metrics.sh --contexts $(IFS=,; echo "${active_ctxs[*]}") --output-dir $SWEEP_DIR"
			fi
			echo ""
		done
		echo "Dry-run complete — no clusters touched."
	} >&2
	exit 0
fi

sweep_cleanup() {
	echo ""
	echo "--- Final cleanup: all contexts ---"
	sweep_step "$SCRIPT_DIR/007-cleanup.sh" --contexts "$(IFS=,; echo "${CONTEXTS[*]}")" || true
}
mkdir -p "$SWEEP_DIR"
config_snapshot "$SWEEP_DIR" "$SWEEP_RUN_ID"
# The cleanup the console names when the sweep ends before its end (its exit runs it too,
# sweep_cleanup; again by hand when that failed, or a second Ctrl-C cut it short).
SWEEP_CLEANUP_CMD="./tests/propagation/007-cleanup.sh --contexts $(IFS=,; echo "${CONTEXTS[*]}")"
# sweep-outcome.txt says the sweep runs until sweep_finish writes its outcome; one that ends
# before (die, an unexpected abort, Ctrl-C) records how, then runs sweep_cleanup
# (tests/lib/common.sh).
sweep_start "$SWEEP_DIR" "$SWEEP_RUN_ID" --cleanup sweep_cleanup


echo "=========================================="
echo "  Propagation Latency Sweep"
echo "=========================================="
echo "Contexts: ${CONTEXTS[*]}"
echo "Mesh sizes: ${MESH_SIZES[*]}"
echo "Iterations per size: $ITERATIONS"
echo "Settle: ${SETTLE_SEC}s"
echo "Istio: $(istio_version_label)"
echo "Output: $SWEEP_DIR"
if [[ "${RUN_CONFIG:-none}" != none ]]; then
	echo "Run config: ${RUN_CONFIG} (sha256 ${RUN_CONFIG_SHA256:0:12})"
fi
echo ""

# One reason per cell whose setup or probe failed: reported, then the exit code.
FAILED_CELLS=()
for ms in "${MESH_SIZES[@]}"; do
	plan_mesh_size "$ms"

	echo "=========================================="
	echo "  Sweep: mesh_size=$ms"
	echo "  Clusters: ${active_ctxs[*]}"
	echo "  Source: $source_ctx"
	echo "  Remotes: ${remote_csv:-none}"
	echo "=========================================="
	echo ""

	# Remove watchers from contexts outside this mesh size so their sidecars do
	# not count toward the source istiod's connected proxies.
	if ((${#inactive_ctxs[@]} > 0)); then
		echo "--- Cleaning up inactive contexts: ${inactive_ctxs[*]} ---"
		sweep_step "$SCRIPT_DIR/007-cleanup.sh" --contexts "$(IFS=,; echo "${inactive_ctxs[*]}")" || \
			echo "warn: cleanup of inactive contexts failed for mesh_size=$ms; continuing" >&2
	fi

	echo "--- Setting up watchers ---"
	# A setup failure records a placeholder row and moves to the next mesh size.
	if ! sweep_step "$SCRIPT_DIR/001-setup-propagation-test.sh" --contexts "$(IFS=,; echo "${active_ctxs[*]}")" --watcher-replicas "$WATCHER_REPLICAS"; then
		echo "warn: watcher setup failed for mesh_size=$ms; recording SETUP_FAILED placeholder and continuing" >&2
		emit_propagation_placeholder SETUP_FAILED "$ms" "$source_ctx"
		FAILED_CELLS+=(SETUP_FAILED)
		echo ""
		continue
	fi
	echo ""

	echo "--- Running endpoint probe (mesh_size=$ms) ---"
	# A probe failure records a placeholder row (additive if the probe already wrote
	# rows) and the sweep continues.
	if ! sweep_step "$SCRIPT_DIR/002-run-endpoint-probe.sh" "${endpoint_args[@]}"; then
		echo "warn: endpoint probe failed for mesh_size=$ms; recording PROBE_FAILED placeholder and continuing" >&2
		emit_propagation_placeholder PROBE_FAILED "$ms" "$source_ctx"
		FAILED_CELLS+=(PROBE_FAILED)
	fi
	echo ""

	if ((COLLECT_METRICS)); then
		echo "--- Collecting pilot metrics (mesh_size=$ms) ---"
		# Non-fatal: optional supplementary collection must not abort the sweep.
		sweep_step "$SCRIPT_DIR/004-collect-pilot-metrics.sh" --contexts "$(IFS=,; echo "${active_ctxs[*]}")" --output-dir "$SWEEP_DIR" || \
			echo "warn: pilot metrics collection failed for mesh_size=$ms; continuing" >&2
		echo ""
	fi

	echo "  Sweep step settle (${SETTLE_SEC}s)..."
	sleep "$SETTLE_SEC"

	echo ""
done
# The platform record again: a build or istiod setting that changed during the sweep is a
# problem of its outcome (tests/lib/platform.sh).
platform_drift_check "$(IFS=,; echo "${CONTEXTS[*]}")"

echo "=========================================="
echo "  Sweep finished"
echo "=========================================="
echo ""
# The Istio version again, after the last window and before the reports (read-only): a
# change is a problem of the outcome, a member it cannot confirm a note.
istio_version_recheck ${KUBECTL[@]+"${KUBECTL[@]}"}
sweep_cleanup
# The outcome before the reports (sweep-outcome.txt, which they read): how many cells
# failed, and exit non-zero if any did (or the Istio version changed under the sweep).
outcome_rc=0
sweep_finish "${#MESH_SIZES[@]}" ${FAILED_CELLS[@]+"${FAILED_CELLS[@]}"} || outcome_rc=$?
echo ""
echo "Generating aggregated report..."
"$SCRIPT_DIR/005-report-results.sh" --results-dir "$SWEEP_DIR" --format text
echo ""

COMBINED="${SWEEP_DIR}/sweep-summary.md"
"$SCRIPT_DIR/005-report-results.sh" --results-dir "$SWEEP_DIR" --format markdown > "$COMBINED"
echo "Combined report: $COMBINED"

CHARTS_FILE="${SWEEP_DIR}/sweep-charts.md"
"$SCRIPT_DIR/005-report-results.sh" --results-dir "$SWEEP_DIR" --format charts > "$CHARTS_FILE"
echo "Charts written to $CHARTS_FILE"
exit "$outcome_rc"

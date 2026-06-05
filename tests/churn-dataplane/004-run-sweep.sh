#!/usr/bin/env bash
# Orchestrate the churn-dataplane co-exec test across (mesh-size × churn-rate).
# O8 item 1: deploy-once-per-mesh-size. Setup (001) and cleanup (006) are hoisted
# OUT of the churn-rate/repetition loop so one deployed workload is reused across
# all churn rates of a mesh-size. Per mesh-size:
#   --- setup (001) ONCE ---
#   for cr × rep:
#     (non-first combo) reset churn-targets to base + settle  [fidelity guard]
#     2. baseline (002) — fortio against steady mesh (PER-RATE, kept)
#     3. churn    (003) — fortio + concurrent churn; computes Δp99 vs baseline
#   --- cleanup (006) ONCE ---
#   settle — PL18 gap before the next mesh-size's setup
#
# Usage:
#   ./tests/churn-dataplane/004-run-sweep.sh [options]
# ci-dry-run:
set -euo pipefail
# P3: loud ERR trap so an unexpected abort self-reports the failing line. Per-combo
# probe/cleanup failures are caught explicitly below and degraded to a row status.
trap 'rc=$?; echo "FATAL: ${0##*/} aborted (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"

CONTEXTS_CSV=""
MESH_SIZES_CSV=""
CHURN_RATES_CSV="${COEXEC_CHURN_RATES:-1,5,10}"
# PL7: legacy singular alias — accepted with a stderr deprecation warning.
CHURN_RATE_SINGULAR=""
BASELINE_DURATION="${COEXEC_BASELINE_DURATION_SEC:-60}"
CHURN_DURATION="${COEXEC_CHURN_DURATION_SEC:-60}"
SETTLE_SEC="${COEXEC_SETTLE_SEC:-10}"
INTER_COMBO_SETTLE_SEC="${COEXEC_INTER_COMBO_SETTLE_SEC:-15}"
QPS="${COEXEC_QPS:-200}"
CONNECTIONS="${COEXEC_NUM_CONNECTIONS:-8}"
CHURN_DEPLOYMENT_COUNT_OPT="${CHURN_DEPLOYMENT_COUNT:-10}"
CHURN_BASE_REPLICAS_OPT="${CHURN_BASE_REPLICAS:-1}"
CHURN_SCALE_TO_OPT="${CHURN_SCALE_TO_REPLICAS:-3}"
CHURN_SEED="${COEXEC_CHURN_SEED:-42}"
REPETITIONS="${COEXEC_REPETITIONS:-1}"
OUTPUT_DIR="${ROOT}/tests/churn-dataplane/results"
# NS must match what 001/002/003/006 use (COEXEC_TEST_NAMESPACE) so the O8 item-1
# reset-to-base fidelity guard (`-n "$NS"`) targets the right namespace.
NS="${COEXEC_TEST_NAMESPACE:-churn-dataplane-test}"
NS_DELETE_TIMEOUT_SEC="${COEXEC_NS_DELETE_TIMEOUT_SEC:-240}"
MATRIX_CAP=64
FORCE_LARGE_MATRIX=0
DRY_RUN=0

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV            All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV          Mesh-size dimension (default: 1..len(contexts)).
  --mesh-size N             DEPRECATED singular alias for --mesh-sizes.
  --churn-rates CSV         Churn rate dimension, "deployment scale ops/s" (default: $CHURN_RATES_CSV).
  --churn-rate N            DEPRECATED singular alias for --churn-rates.
  --baseline-duration SEC   Baseline-phase fortio duration (default: $BASELINE_DURATION).
  --churn-duration SEC      Churn-phase fortio + churn duration (default: $CHURN_DURATION).
  --settle-sec N            Pre-window settle delay (default: $SETTLE_SEC).
  --inter-combo-settle N    Settle gap (default: $INTER_COMBO_SETTLE_SEC) [PL18]. Used BOTH between
                            mesh-sizes (after the once-per-mesh-size cleanup) AND
                            between churn rates within a mesh-size (to drain the
                            post-churn reset-to-base before the next baseline).
  --qps N                   Target QPS for both phases (default: $QPS).
  --connections N           Concurrent fortio connections (default: $CONNECTIONS).
  --deployment-count N      Churn-target Deployments per cluster (default: $CHURN_DEPLOYMENT_COUNT_OPT).
  --base-replicas N         Scale-down replica count (default: $CHURN_BASE_REPLICAS_OPT).
  --scale-to N              Scale-up replica count (default: $CHURN_SCALE_TO_OPT).
  --seed N                  Seed for the deterministic churn order (default: $CHURN_SEED).
  --repetitions N           Probe repetitions per combination (default: $REPETITIONS).
  --output-dir DIR          Top-level results directory (default: tests/churn-dataplane/results).
  --ns-delete-timeout SEC   Bound on async namespace teardown wait (default: $NS_DELETE_TIMEOUT_SEC).
                            Also bounds 001's pre-apply wait for the PRIOR mesh-size's
                            namespace to finish Terminating (cleanup-cascade fix A).
  --force-large-matrix      Bypass the PL10 matrix cap of $MATRIX_CAP combinations.
  --dry-run                 Print plan only; do not touch clusters.
  -h, --help                Show this help.

Note: \`--churn-rates 0\` (or a CSV element with value 0) is accepted and runs
the churn phase against a steady mesh — useful as a sanity check that the
churn phase reports the same numbers as the baseline phase. Rates < 0 are
rejected.

Environment:
  SETUP_CONTEXTS, COEXEC_CHURN_RATES, COEXEC_BASELINE_DURATION_SEC,
  COEXEC_CHURN_DURATION_SEC, COEXEC_SETTLE_SEC, COEXEC_INTER_COMBO_SETTLE_SEC,
  COEXEC_QPS, COEXEC_NUM_CONNECTIONS, COEXEC_CHURN_SEED, COEXEC_REPETITIONS,
  COEXEC_NS_DELETE_TIMEOUT_SEC, CHURN_DEPLOYMENT_COUNT, CHURN_BASE_REPLICAS,
  CHURN_SCALE_TO_REPLICAS.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"; shift 2 ;;
	--mesh-sizes)
		[[ -n "${2:-}" ]] || die "--mesh-sizes requires a value"
		MESH_SIZES_CSV="$2"; shift 2 ;;
	--mesh-size)
		[[ -n "${2:-}" ]] || die "--mesh-size requires a value"
		echo "warn: --mesh-size is deprecated; use --mesh-sizes CSV" >&2
		MESH_SIZES_CSV="$2"; shift 2 ;;
	--churn-rates)
		[[ -n "${2:-}" ]] || die "--churn-rates requires a value"
		CHURN_RATES_CSV="$2"; shift 2 ;;
	--churn-rate)
		[[ -n "${2:-}" ]] || die "--churn-rate requires a value"
		CHURN_RATE_SINGULAR="$2"; shift 2 ;;
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
		NS_DELETE_TIMEOUT_SEC="$2"; shift 2 ;;
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

if [[ -n "$CHURN_RATE_SINGULAR" ]]; then
	echo "warn: --churn-rate is deprecated; use --churn-rates CSV (treating value as a single-element CSV)" >&2
	CHURN_RATES_CSV="$CHURN_RATE_SINGULAR"
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

# PL10: matrix cap.
MATRIX_SIZE=$(( ${#MESH_SIZES[@]} * ${#CHURN_RATES[@]} * REPETITIONS ))
if (( MATRIX_SIZE > MATRIX_CAP )); then
	if ((FORCE_LARGE_MATRIX)); then
		echo "warn: matrix is ${MATRIX_SIZE} combinations (> $MATRIX_CAP); --force-large-matrix set, proceeding" >&2
	else
		die "matrix is ${MATRIX_SIZE} combinations (> $MATRIX_CAP). Re-run with --force-large-matrix to bypass."
	fi
fi

# PL6: per-sweep output subdir.
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SWEEP_DIR="${OUTPUT_DIR}/sweep-${RUN_ID}"
mkdir -p "$SWEEP_DIR"
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
echo "Output:         $TSV_FILE"
((DRY_RUN)) && echo "Mode:           dry-run"

SCRIPT_DIR="${ROOT}/tests/churn-dataplane"

if command -v oc >/dev/null 2>&1; then
	KUBECTL=(oc)
elif command -v kubectl >/dev/null 2>&1; then
	KUBECTL=(kubectl)
else
	((DRY_RUN)) || die "neither oc nor kubectl found on PATH"
	KUBECTL=(kubectl) # placeholder for dry-run plan only
fi

# Construct preamble + header once at the top of the sweep TSV.
if ! ((DRY_RUN)); then
	ALL_CTXS_CSV="$(IFS=,; echo "${CONTEXTS[*]}")"
	KUBE_VERSIONS_CSV="$(probe_kube_versions "$ALL_CTXS_CSV" "${KUBECTL[@]}")"
	write_preamble "churn-dataplane co-exec test" "$TSV_FILE" \
		"RUN_ID=$RUN_ID" \
		"HARNESS_SHA=$HARNESS_SHA" \
		"ISTIO_VERSION=${ISTIO_VERSION:-unknown}" \
		"KUBE_VERSIONS=$KUBE_VERSIONS_CSV" \
		"SETTLE_SEC=$SETTLE_SEC" \
		"BASELINE_DURATION_SEC=$BASELINE_DURATION" \
		"CHURN_DURATION_SEC=$CHURN_DURATION" \
		"QPS=$QPS" \
		"CONNECTIONS=$CONNECTIONS" \
		"NAMESPACE=${COEXEC_TEST_NAMESPACE:-churn-dataplane-test}" \
		"MATRIX_SIZE=$MATRIX_SIZE" \
		"REPETITIONS=$REPETITIONS" \
		"SETUP_NS_WAIT_SEC=$NS_DELETE_TIMEOUT_SEC" \
		"CLEANUP_GRACE_SEC=${COEXEC_CLEANUP_GRACE_SEC:-5}" \
		"NS_DELETE_TIMEOUT_SEC=$NS_DELETE_TIMEOUT_SEC"
	printf 'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms\n' >> "$TSV_FILE"
fi

# emit_cd_row <status> <combo_id> <ms> <cr> <phase>
#   Append one degraded 25-col row (restarted=unknown, all numerics N/A) for the given
#   phase/status (PL13). Mirrors the CLEANUP_TIMEOUT row's layout.
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
#   B3: emit BOTH a baseline AND a churn degraded row so 005-report-results.sh buckets
#   the combo via ch_seen into the REAL (mesh_size, churn_rate) cell — incrementing that
#   cell's n_total (not a phantom (ms,0) cell) while excluding it from n_valid (PL15).
#   Used for setup failures and baseline failures (the entire combo produced no data).
emit_failed_rows() {
	local status="$1" combo_id="$2" ms="$3" cr="$4"
	emit_cd_row "$status" "$combo_id" "$ms" "$cr" "baseline"
	emit_cd_row "$status" "$combo_id" "$ms" "$cr" "churn"
}

# emit_cleanup_timeout_row <combo_id> <ms> <cr>
#   PL23: propagate a cleanup-timeout into the TSV (status=CLEANUP_TIMEOUT) instead
#   of polluting the next mesh-size's setup.
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
#   Combo-id naming is unchanged: includes -r<rep> only when REPETITIONS > 1.
combo_id_for() {
	if (( REPETITIONS > 1 )); then
		echo "ms$1-cr$2-r$3"
	else
		echo "ms$1-cr$2"
	fi
}

# reset_churn_targets_to_base <active_csv>
#   O8 item-1 FIDELITY GUARD. 003-run-churn-probe.sh initializes its per-index
#   PARITY tracker to all-base (PARITY[i]=0) and toggles from there; it does NOT
#   reset deployment replicas at the end, so after a churn phase the churn-targets
#   are left in a MIXED replica state. With deploy-once-per-mesh-size we no longer
#   redeploy between rates, so before each SUBSEQUENT rate's baseline we must
#   restore the workload to the clean all-base state a fresh setup used to give:
#     (a) otherwise the next rate's BASELINE measures a contaminated (non-all-base)
#         mesh — residual-churn contamination, violating "no baseline reuse"; and
#     (b) the next rate's churn-phase PARITY tracker would desync from reality,
#         issuing `scale --replicas=scale-to` against deployments already AT
#         scale-to → no-op scales → undercounted EDS/xDS push deltas.
#   The churn-targets carry label churn-target=true (fortio server/client do NOT),
#   so the selector scopes the reset precisely. The per-context scales are fanned
#   out concurrently (parallelism is bounded by the active-context count, ≤ the
#   mesh size). `--request-timeout` bounds a hung apiserver so a stuck reset
#   degrades to a failure (caller poisons the combo) instead of stalling the sweep
#   — mirroring O6's --max-time discipline. Returns non-zero if ANY context's scale
#   failed: the caller records a RESET_FAILED row and SKIPS this rate's measurement
#   rather than measuring against a known-contaminated (non-all-base) mesh — the
#   reset failure is the deploy-once analogue of a setup failure. On success the
#   reset's EDS pushes are drained by the INTER_COMBO_SETTLE_SEC settle that follows
#   this call, before the next baseline measures.
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
for ms in "${MESH_SIZES[@]}"; do
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

	# --- setup ONCE per mesh-size (001) ---
	setup_args=(
		--source-context "$source_ctx"
		--deployment-count "$CHURN_DEPLOYMENT_COUNT_OPT"
		--base-replicas "$CHURN_BASE_REPLICAS_OPT"
		# Cleanup-cascade fix (A): bound 001's pre-apply wait for a still-Terminating
		# namespace from the PREVIOUS mesh-size's cleanup to the SAME timeout 006 used
		# (--ns-delete-timeout), so a slow teardown DELAYS this setup rather than failing
		# the apply into a Terminating namespace and cascading to SETUP_FAILED.
		--ns-wait-timeout "$NS_DELETE_TIMEOUT_SEC"
	)
	[[ -n "$remote_csv" ]] && setup_args+=(--remote-contexts "$remote_csv")

	if ((DRY_RUN)); then
		echo "=========================================="
		echo "[mesh-size $ms] ctxs=${active_csv}"
		echo "=========================================="
		echo "  [dry-run] 001 --source-context $source_ctx --remote-contexts $remote_csv --deployment-count $CHURN_DEPLOYMENT_COUNT_OPT --ns-wait-timeout $NS_DELETE_TIMEOUT_SEC  # ONCE per mesh-size; waits out a still-Terminating ns from the prior mesh-size before applying" >&2
	else
		echo "=========================================="
		echo "[mesh-size $ms] setup ONCE  ctxs=${active_csv}"
		echo "=========================================="
		echo "--- setup (once per mesh-size) ---"
		echo "    note: setup may wait up to ${NS_DELETE_TIMEOUT_SEC}s for the prior mesh-size's namespace ($NS) to finish Terminating before applying (Cleanup-cascade fix A)"
		# B1/PL15/PL32: setup is the most probable per-combo failure at scale. A bare
		# call under set -e would abort the whole sweep, discarding every completed
		# combo (the report runs only after the loop). On failure: record SETUP_FAILED
		# rows for BOTH phases of EVERY (cr,rep) combo of THIS mesh-size (advancing
		# COMBO_INDEX for each so the [combo x/total] counter stays correct), so 005
		# buckets each into its real (ms,cr) cell (n_total++, excluded from n_valid);
		# then clean up ONCE, settle if more mesh-sizes remain, and continue.
		if ! "$SCRIPT_DIR/001-setup-coexec-test.sh" "${setup_args[@]}"; then
			echo "warn: [mesh-size $ms] setup failed; recording SETUP_FAILED rows for all rates of this mesh-size and continuing" >&2
			for cr in "${CHURN_RATES[@]}"; do
				for ((rep = 1; rep <= REPETITIONS; rep++)); do
					COMBO_INDEX=$((COMBO_INDEX + 1))
					COMBO_ID="$(combo_id_for "$ms" "$cr" "$rep")"
					emit_failed_rows SETUP_FAILED "$COMBO_ID" "$ms" "$cr"
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

		if ((DRY_RUN)); then
			{
				if (( meshsize_combo_seq > 0 )); then
					echo "  [dry-run] reset churn-targets to base (-l churn-target=true) on $active_csv + sleep $INTER_COMBO_SETTLE_SEC  # O8 fidelity guard: drain before next baseline"
				fi
				echo "  [dry-run] 002 --source-context $source_ctx --combo-id $COMBO_ID --mesh-size $ms --duration $BASELINE_DURATION --qps $QPS --output-file $TSV_FILE --append"
				echo "  [dry-run] 003 --source-context $source_ctx --combo-id $COMBO_ID --mesh-size $ms --churn-rate $cr --duration $CHURN_DURATION --qps $QPS --output-file $TSV_FILE --baseline-file $TSV_FILE"
			} >&2
			meshsize_combo_seq=$((meshsize_combo_seq + 1))
			continue
		fi

		# O8 item-1 fidelity guard: for every combo AFTER the first of this mesh-size,
		# the prior rate's churn phase left churn-targets in a mixed replica state.
		# Reset them to base on ALL active contexts and drain the resulting EDS pushes
		# (settle) BEFORE this rate's baseline measures — reproducing the clean
		# all-base starting condition that per-combo setup used to provide.
		if (( meshsize_combo_seq > 0 )); then
			echo "--- post-churn reset + settle (O8 fidelity guard) ---"
			# If the reset fails on any context the mesh is left in an unknown
			# (possibly non-all-base) state, so measuring this rate would silently
			# contaminate its baseline/churn and its istiod-side deltas. Record a
			# RESET_FAILED row for BOTH phases (buckets via ch_seen into the real
			# (ms,cr) cell — n_total++, excluded from n_valid because status!=OK) and
			# skip this rate's measurement. The NEXT rate still re-resets (seq stays >0).
			if ! reset_churn_targets_to_base "$active_csv"; then
				echo "warn: [combo $COMBO_INDEX/$MATRIX_SIZE] churn-target reset failed for $COMBO_ID; recording RESET_FAILED rows and skipping this rate's measurement" >&2
				emit_failed_rows RESET_FAILED "$COMBO_ID" "$ms" "$cr"
				meshsize_combo_seq=$((meshsize_combo_seq + 1))
				continue
			fi
			echo "Draining reset EDS pushes: settle ${INTER_COMBO_SETTLE_SEC}s before baseline..."
			sleep "$INTER_COMBO_SETTLE_SEC"
		fi
		meshsize_combo_seq=$((meshsize_combo_seq + 1))

		echo "--- baseline phase ---"
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
			--append
		)
		[[ -n "$remote_csv" ]] && baseline_args+=(--remote-contexts "$remote_csv")
		# P0/PL15: a probe failure must be a RECORDED failed combo, not a sweep abort.
		# 005-report-results.sh keys n_total on (mesh_size, churn_rate) and only admits
		# status=OK + restarted=0 rows to n_valid. B3: emit BOTH phases' rows so the combo
		# buckets via ch_seen into the real (ms,cr) cell — a baseline-only row would
		# mis-bucket to a phantom (ms,0) cell (005:171-175) and understate the failure.
		# O8 item-1: the workload is SHARED across rates — do NOT cleanup here, and do
		# NOT settle here (the reset+settle at the top of the next rate handles isolation).
		if ! "$SCRIPT_DIR/002-run-baseline-probe.sh" "${baseline_args[@]}"; then
			echo "warn: [combo $COMBO_INDEX/$MATRIX_SIZE] baseline probe failed for $COMBO_ID; recording PROBE_FAILED rows and continuing" >&2
			emit_failed_rows PROBE_FAILED "$COMBO_ID" "$ms" "$cr"
			continue
		fi

		echo "--- churn phase ---"
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
		)
		[[ -n "$remote_csv" ]] && churn_args+=(--remote-contexts "$remote_csv")
		# P0/PL15: failed churn phase → phase=churn status=PROBE_FAILED row (counted in
		# n_total, excluded from n_valid because status!=OK). Fall through (no cleanup —
		# the workload is shared; cleanup happens once after all rates).
		if ! "$SCRIPT_DIR/003-run-churn-probe.sh" "${churn_args[@]}"; then
			echo "warn: [combo $COMBO_INDEX/$MATRIX_SIZE] churn probe failed for $COMBO_ID; recording PROBE_FAILED row and continuing" >&2
			# Baseline row already exists; only the churn row is needed — it buckets via
			# ch_seen into the real (ms,cr) cell (n_total++, excluded from n_valid).
			emit_cd_row PROBE_FAILED "$COMBO_ID" "$ms" "$cr" "churn"
		fi
		done
	done

	# --- cleanup ONCE per mesh-size (006), after all rates ---
	if ((DRY_RUN)); then
		echo "  [dry-run] 006 --contexts $active_csv --wait-deletion --timeout $NS_DELETE_TIMEOUT_SEC  # ONCE per mesh-size" >&2
		if (( COMBO_INDEX < MATRIX_SIZE )); then
			echo "  [dry-run] sleep $INTER_COMBO_SETTLE_SEC  # PL18 settle before next mesh-size setup" >&2
		fi
	else
		echo "--- cleanup (once per mesh-size) ---"
		cleanup_args=(--contexts "$active_csv" --wait-deletion --timeout "$NS_DELETE_TIMEOUT_SEC")
		"$SCRIPT_DIR/006-cleanup.sh" "${cleanup_args[@]}" || {
			echo "warn: cleanup reported failure for mesh-size $ms; recording CLEANUP_TIMEOUT row" >&2
			# PL23: propagate cleanup timeout into the TSV instead of polluting the next
			# mesh-size. Cleanup is now per-mesh-size (not per-rate), so the row carries a
			# synthetic combo_id "ms${ms}-cleanup" rather than an arbitrary rate's id — the
			# failure is mesh-size-scoped and 005 ignores phase=cleanup rows for bucketing.
			emit_cleanup_timeout_row "ms${ms}-cleanup" "$ms" "0"
		}

		# PL18: settle gap before the next mesh-size's setup.
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
echo "Sweep complete: $TSV_FILE"
echo "Running 005-report-results.sh..."
"$SCRIPT_DIR/005-report-results.sh" --results-dir "$SWEEP_DIR"

MD_FILE="${SWEEP_DIR}/sweep-summary-${RUN_ID}.md"
"$SCRIPT_DIR/005-report-results.sh" --results-dir "$SWEEP_DIR" --format md > "$MD_FILE"
echo "Markdown summary: $MD_FILE"

CHARTS_FILE="${SWEEP_DIR}/sweep-charts-${RUN_ID}.md"
"$SCRIPT_DIR/005-report-results.sh" --results-dir "$SWEEP_DIR" --format charts > "$CHARTS_FILE"
echo "Charts written to $CHARTS_FILE"

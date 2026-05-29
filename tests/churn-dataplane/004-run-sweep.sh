#!/usr/bin/env bash
# Orchestrate the churn-dataplane co-exec test across (mesh-size × churn-rate).
# For each combination:
#   1. setup    (001) — shared-namespace fortio + churn-target workloads
#   2. baseline (002) — fortio against steady mesh
#   3. churn    (003) — fortio + concurrent churn; computes Δp99 vs baseline
#   4. cleanup  (006) — delete the shared namespace on every active context
#   5. settle   — PL18 gap before the next combo's setup
#
# Usage:
#   ./tests/churn-dataplane/004-run-sweep.sh [options]
# ci-dry-run:
set -euo pipefail

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
NS_DELETE_TIMEOUT_SEC="${COEXEC_NS_DELETE_TIMEOUT_SEC:-180}"
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
  --inter-combo-settle N    Settle gap between combos, after cleanup (default: $INTER_COMBO_SETTLE_SEC) [PL18].
  --qps N                   Target QPS for both phases (default: $QPS).
  --connections N           Concurrent fortio connections (default: $CONNECTIONS).
  --deployment-count N      Churn-target Deployments per cluster (default: $CHURN_DEPLOYMENT_COUNT_OPT).
  --base-replicas N         Scale-down replica count (default: $CHURN_BASE_REPLICAS_OPT).
  --scale-to N              Scale-up replica count (default: $CHURN_SCALE_TO_OPT).
  --seed N                  Seed for the deterministic churn order (default: $CHURN_SEED).
  --repetitions N           Probe repetitions per combination (default: $REPETITIONS).
  --output-dir DIR          Top-level results directory (default: tests/churn-dataplane/results).
  --ns-delete-timeout SEC   Bound on async namespace teardown wait (default: $NS_DELETE_TIMEOUT_SEC).
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
		"REPETITIONS=$REPETITIONS"
	printf 'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms\n' >> "$TSV_FILE"
fi

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

	for cr in "${CHURN_RATES[@]}"; do
		for ((rep = 1; rep <= REPETITIONS; rep++)); do
		COMBO_INDEX=$((COMBO_INDEX + 1))
		if (( REPETITIONS > 1 )); then
			COMBO_ID="ms${ms}-cr${cr}-r${rep}"
		else
			COMBO_ID="ms${ms}-cr${cr}"
		fi

		echo "=========================================="
		echo "[combo $COMBO_INDEX/$MATRIX_SIZE] $COMBO_ID  rep=$rep/$REPETITIONS  ctxs=${active_csv}  rate=${cr}/s"
		echo "=========================================="

		if ((DRY_RUN)); then
			{
				echo "  [dry-run] 001 --source-context $source_ctx --remote-contexts $remote_csv --deployment-count $CHURN_DEPLOYMENT_COUNT_OPT"
				echo "  [dry-run] 002 --source-context $source_ctx --combo-id $COMBO_ID --mesh-size $ms --duration $BASELINE_DURATION --qps $QPS --output-file $TSV_FILE --append"
				echo "  [dry-run] 003 --source-context $source_ctx --combo-id $COMBO_ID --mesh-size $ms --churn-rate $cr --duration $CHURN_DURATION --qps $QPS --output-file $TSV_FILE --baseline-file $TSV_FILE"
				echo "  [dry-run] 006 --contexts $active_csv --wait-deletion --timeout $NS_DELETE_TIMEOUT_SEC"
				echo "  [dry-run] sleep $INTER_COMBO_SETTLE_SEC  # PL18 inter-combo settle"
			} >&2
			continue
		fi

		echo "--- setup ---"
		setup_args=(
			--source-context "$source_ctx"
			--deployment-count "$CHURN_DEPLOYMENT_COUNT_OPT"
			--base-replicas "$CHURN_BASE_REPLICAS_OPT"
		)
		[[ -n "$remote_csv" ]] && setup_args+=(--remote-contexts "$remote_csv")
		"$SCRIPT_DIR/001-setup-coexec-test.sh" "${setup_args[@]}"

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
		"$SCRIPT_DIR/002-run-baseline-probe.sh" "${baseline_args[@]}"

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
		"$SCRIPT_DIR/003-run-churn-probe.sh" "${churn_args[@]}"

		echo "--- cleanup ---"
		cleanup_args=(--contexts "$active_csv" --wait-deletion --timeout "$NS_DELETE_TIMEOUT_SEC")
		"$SCRIPT_DIR/006-cleanup.sh" "${cleanup_args[@]}" || {
			echo "warn: cleanup reported failure; recording row status to keep next combo isolated" >&2
			# PL23: propagate cleanup timeout into the TSV instead of polluting next combo.
			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
				"$RUN_ID" "$HARNESS_SHA" "$COMBO_ID" "$ms" "$cr" "cleanup" \
				"0" "0" "0" \
				"N/A" "N/A" "N/A" "N/A" "N/A" \
				"N/A" "unknown" "CLEANUP_TIMEOUT" \
				"N/A" "N/A" \
				"N/A" "N/A" "N/A" "N/A" "N/A" "N/A" >> "$TSV_FILE"
		}

		# PL18: settle gap before next combo.
		if (( COMBO_INDEX < MATRIX_SIZE )); then
			echo "Inter-combo settle ${INTER_COMBO_SETTLE_SEC}s..."
			sleep "$INTER_COMBO_SETTLE_SEC"
		fi
		done
	done
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

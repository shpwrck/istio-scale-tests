#!/usr/bin/env bash
# Orchestrate data-plane latency probes across multiple mesh sizes.
# Mints a sweep-${RUN_ID} subdirectory so each sweep's TSVs stay together.
#
# Usage:
#   ./tests/dataplane/003-run-sweep.sh [--contexts CSV] [--mesh-sizes CSV] [options]
#
# Examples:
#   # Sweep 1, 2, 3 clusters:
#   ./tests/dataplane/003-run-sweep.sh --contexts cluster-001,cluster-002,cluster-003
# ci-dry-run:
set -euo pipefail
# P3: loud ERR trap so an unexpected abort self-reports the failing line. Per-combo
# probe/cleanup failures are caught explicitly below and degraded to warn+continue.
trap 'rc=$?; echo "FATAL: ${0##*/} aborted (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"  # B6: harness_sha for the placeholder TSV preamble

CONTEXTS_CSV=""
MESH_SIZES_CSV=""
QPS_LEVELS="${DATAPLANE_QPS_LEVELS:-10,100,500,1000}"
DURATION="${DATAPLANE_DURATION_SEC:-30}"
CONNECTIONS="${DATAPLANE_NUM_CONNECTIONS:-8}"
SETTLE_SEC="${DATAPLANE_SETTLE_SEC:-30}"
MAX_MATRIX="${DATAPLANE_MAX_MATRIX:-64}"
INTER_COMBO_SETTLE="${DATAPLANE_INTER_COMBO_SETTLE_SEC:-15}"
REPETITIONS="${DATAPLANE_REPETITIONS:-1}"
OUTPUT_DIR_BASE="${ROOT}/tests/dataplane/results"
DRY_RUN=0
FORCE_LARGE_MATRIX=0


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV       All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV     Cluster counts to test (default: "1,2,...,len(contexts)").
  --qps-levels CSV     QPS levels to test (default: $QPS_LEVELS).
  --duration SEC       Duration per QPS level (default: $DURATION).
  --connections N      Concurrent connections (default: $CONNECTIONS).
  --settle SEC         Seconds to sleep before probing (default: $SETTLE_SEC).
  --output-dir DIR     Base results directory (default: tests/dataplane/results).
                       A per-sweep subdir sweep-\${RUN_ID}/ is created here.
  --repetitions N      Probe repetitions per mesh size (default: $REPETITIONS).
  --force-large-matrix Bypass the ${MAX_MATRIX}-combo matrix safety cap.
  --dry-run            Show plan without executing.
  -h, --help           Show this help.

Environment:
  SETUP_CONTEXTS, DATAPLANE_QPS_LEVELS, DATAPLANE_DURATION_SEC,
  DATAPLANE_NUM_CONNECTIONS, DATAPLANE_SETTLE_SEC, DATAPLANE_MAX_MATRIX,
  DATAPLANE_INTER_COMBO_SETTLE_SEC, DATAPLANE_REPETITIONS.
EOF
}


while [[ $# -gt 0 ]]; do
	case "$1" in
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

for ms in "${MESH_SIZES[@]}"; do
	[[ "$ms" =~ ^[0-9]+$ ]] || die "mesh-size must be a positive integer: $ms"
	((ms >= 1 && ms <= ${#CONTEXTS[@]})) || die "mesh-size $ms out of range (have ${#CONTEXTS[@]} contexts)"
done

SCRIPT_DIR="${ROOT}/tests/dataplane"

# Count QPS levels for matrix size check.
QPS_ARR_TMP=()
split_csv "$QPS_LEVELS" QPS_ARR_TMP
MATRIX_SIZE=$(( ${#MESH_SIZES[@]} * ${#QPS_ARR_TMP[@]} * REPETITIONS ))
if (( MATRIX_SIZE > MAX_MATRIX )) && (( !FORCE_LARGE_MATRIX )); then
	die "matrix size ${MATRIX_SIZE} exceeds cap ${MAX_MATRIX} (${#MESH_SIZES[@]} mesh_sizes × ${#QPS_ARR_TMP[@]} qps_levels × ${REPETITIONS} reps); use --force-large-matrix to override"
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OUTPUT_DIR="${OUTPUT_DIR_BASE}/sweep-${RUN_ID}"
HARNESS_SHA="$(harness_sha)"

# B6: emit a minimal placeholder TSV for a mesh size whose setup/probe crashed before
# the probe wrote any row. Without it the mesh size vanishes from the report (looks
# like never-planned). 004-report-results.sh globs latency-*.tsv and counts
# count_total per (mesh, qps, target_class) for NF>=17 rows, admitting only
# status==OK && restart==0 to count_valid (PL15). The probe sweeps qps INTERNALLY, so
# one placeholder row (qps=0, class=na) makes the MESH SIZE visible. Sorts AFTER the
# real latency-<RUN_ID> files.
# Usage: emit_dataplane_placeholder <status> <mesh_size> <source_ctx>
emit_dataplane_placeholder() {
	local status="$1" ms="$2" sctx="$3"
	mkdir -p "$OUTPUT_DIR"
	local f="${OUTPUT_DIR}/latency-zzfail-ms${ms}-${RUN_ID}.tsv"
	{
		echo "# Data-plane latency test (placeholder — mesh size failed before any row)"
		echo "# HARNESS_SHA=${HARNESS_SHA}"
		echo "# ISTIO_VERSION=${ISTIO_VERSION:-unknown}"
		echo "# NOTE=${status}: setup or probe exited non-zero; counted in n_total, excluded from n_valid"
		# 17-col header (matches 002-run-latency-probe.sh).
		printf 'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class\n'
		# One degraded row: mesh in $2, qps_target=0, status sentinel in $14,
		# restarted=unknown in $16, target_class=na in $17; numerics N/A (PL13).
		printf '%s\t%s\t%s\tN/A\t0\tN/A\t%s\t%s\tN/A\tN/A\tN/A\tN/A\tN/A\t%s\tN/A\tunknown\tna\n' \
			"$RUN_ID" "$ms" "$sctx" "$CONNECTIONS" "$DURATION" "$status"
	} > "$f"
}

echo "=========================================="
echo "  Data-Plane Latency Sweep"
echo "=========================================="
echo "Contexts: ${CONTEXTS[*]}"
echo "Mesh sizes: ${MESH_SIZES[*]}"
echo "QPS levels: $QPS_LEVELS"
echo "Repetitions: ${REPETITIONS}"
echo "Matrix: ${MATRIX_SIZE} combos (cap: ${MAX_MATRIX})"
echo "Settle: ${SETTLE_SEC}s | Inter-combo settle: ${INTER_COMBO_SETTLE}s"
echo "Sweep output dir: $OUTPUT_DIR"
echo ""

# Per-mesh-size dry-run plan goes to stderr so > redirect of stdout still works.
if ((DRY_RUN)); then
	echo "=== Planned matrix (dry-run) ===" >&2
fi

((DRY_RUN)) || mkdir -p "$OUTPUT_DIR"

for ms in "${MESH_SIZES[@]}"; do
	active_ctxs=("${CONTEXTS[@]:0:$ms}")
	source_ctx="${active_ctxs[0]}"
	remote_ctxs=()
	if ((ms > 1)); then
		remote_ctxs=("${active_ctxs[@]:1}")
	fi
	remote_csv=""
	for rc in "${remote_ctxs[@]}"; do
		[[ -n "$remote_csv" ]] && remote_csv+=","
		remote_csv+="$rc"
	done

	echo "=========================================="
	echo "  Sweep: mesh_size=$ms"
	echo "  Source: $source_ctx  Remotes: ${remote_ctxs[*]:-none}"
	echo "=========================================="

	if ((DRY_RUN)); then
		{
			echo "  mesh_size=$ms source=$source_ctx remotes=${remote_csv:-none} reps=${REPETITIONS}"
			echo "    001-setup-dataplane-test.sh --source-context $source_ctx${remote_csv:+ --remote-contexts $remote_csv}"
			for ((rep = 1; rep <= REPETITIONS; rep++)); do
				echo "    [rep $rep/$REPETITIONS] 002-run-latency-probe.sh --source-context $source_ctx${remote_csv:+ --remote-contexts $remote_csv} --mesh-size $ms --settle $SETTLE_SEC --output-dir $OUTPUT_DIR"
			done
			echo "    005-cleanup.sh --contexts $(IFS=,; echo "${active_ctxs[*]}")"
		} >&2
		continue
	fi

	echo "--- Setting up ---"
	setup_args=(--source-context "$source_ctx")
	[[ -n "$remote_csv" ]] && setup_args+=(--remote-contexts "$remote_csv")
	# B1/B6: setup is a probable per-combo failure at scale; bare under set -e it would
	# abort the whole sweep. On failure record a placeholder row (so this mesh size is
	# visible in the report), clean up, and continue to the next mesh size.
	if ! "$SCRIPT_DIR/001-setup-dataplane-test.sh" "${setup_args[@]}"; then
		echo "warn: setup failed for mesh_size=$ms; recording SETUP_FAILED placeholder and continuing" >&2
		emit_dataplane_placeholder SETUP_FAILED "$ms" "$source_ctx"
		"$SCRIPT_DIR/005-cleanup.sh" --contexts "$(IFS=,; echo "${active_ctxs[*]}")" || \
			echo "warn: cleanup after setup failure also reported failure for mesh_size=$ms" >&2
		echo ""
		continue
	fi
	echo ""

	dp_probe_failed=0
	for ((rep = 1; rep <= REPETITIONS; rep++)); do
		echo "--- Running latency probe (mesh_size=$ms, rep $rep/$REPETITIONS) ---"
		probe_args=(
			--source-context "$source_ctx"
			--mesh-size "$ms"
			--qps-levels "$QPS_LEVELS"
			--duration "$DURATION"
			--connections "$CONNECTIONS"
			--settle "$SETTLE_SEC"
			--output-dir "$OUTPUT_DIR"
		)
		[[ -n "$remote_csv" ]] && probe_args+=(--remote-contexts "$remote_csv")
		# P0/B6: a probe failure must NOT abort the multi-hour sweep. The latency probe
		# writes its own rows into $OUTPUT_DIR (self-tagging non-OK status). If a rep
		# crashes before writing any row, the mesh size could vanish from the report;
		# we record (once per mesh size, after the rep loop) a placeholder so it stays
		# visible. Log-and-continue per rep.
		if ! "$SCRIPT_DIR/002-run-latency-probe.sh" "${probe_args[@]}"; then
			echo "warn: latency probe failed for mesh_size=$ms rep=$rep/$REPETITIONS; continuing to next rep/combo" >&2
			dp_probe_failed=1
		fi
		echo ""
	done
	# B6: one placeholder per mesh size if any rep failed — keeps the size visible even
	# if every rep crashed before writing a row (n_total++, excluded from n_valid).
	if (( dp_probe_failed )); then
		emit_dataplane_placeholder PROBE_FAILED "$ms" "$source_ctx"
	fi

	echo "--- Cleaning up ---"
	# P0/PL23: a cleanup hiccup must not abort the sweep — the next combo's setup also
	# cleans the namespace. Warn and continue.
	"$SCRIPT_DIR/005-cleanup.sh" --contexts "$(IFS=,; echo "${active_ctxs[*]}")" || \
		echo "warn: cleanup reported failure for mesh_size=$ms; next combo's setup will re-clean" >&2

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

echo "=========================================="
echo "  Sweep complete"
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

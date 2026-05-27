#!/usr/bin/env bash
# Orchestrate data-plane latency probes across multiple mesh sizes.
# Mints a sweep-${RUN_ID} subdirectory so each sweep's TSVs stay together.
#
# Usage:
#   ./tests/dataplane/003-run-sweep.sh [--contexts CSV] [--mesh-sizes CSV] [options]
#
# Examples:
#   # Sweep 1, 2, 3 clusters:
#   ./tests/dataplane/003-run-sweep.sh --contexts rosa-001,rosa-002,rosa-003
# ci-dry-run:
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

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

die() { echo "error: $*" >&2; exit 1; }

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

split_csv() {
	local csv="$1"
	local -n _out="$2"
	_out=()
	local x
	IFS=',' read -ra _raw <<<"$csv"
	for x in "${_raw[@]}"; do
		x="${x#"${x%%[![:space:]]*}"}"
		x="${x%"${x##*[![:space:]]}"}"
		[[ -n "$x" ]] && _out+=("$x")
	done
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
	"$SCRIPT_DIR/001-setup-dataplane-test.sh" "${setup_args[@]}"
	echo ""

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
		"$SCRIPT_DIR/002-run-latency-probe.sh" "${probe_args[@]}"
		echo ""
	done

	echo "--- Cleaning up ---"
	"$SCRIPT_DIR/005-cleanup.sh" --contexts "$(IFS=,; echo "${active_ctxs[*]}")"

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

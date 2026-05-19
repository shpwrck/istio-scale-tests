#!/usr/bin/env bash
# Orchestrate churn probes across mesh sizes and churn intensities.
#
# Usage:
#   ./tests/churn/003-run-sweep.sh [--contexts CSV] [--mesh-sizes CSV] [options]
#
# Examples:
#   # Sweep 1, 2, 3 clusters with default churn:
#   ./tests/churn/003-run-sweep.sh --contexts rosa-001,rosa-002,rosa-003
#
#   # Sweep churn intensities (deployment counts):
#   ./tests/churn/003-run-sweep.sh --churn-intensities 5,10,20
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
MESH_SIZES_CSV=""
CHURN_INTENSITIES_CSV=""
SCALE_TO="${CHURN_SCALE_TO_REPLICAS:-5}"
ITERATIONS="${CHURN_ITERATIONS:-5}"
TIMEOUT_SEC="${CHURN_TIMEOUT_SEC:-120}"
OUTPUT_DIR="${ROOT}/tests/churn/results"
DRY_RUN=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV            All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV          Cluster counts to test (default: "1,2,...,len(contexts)").
  --churn-intensities CSV   Deployment counts to test (default: \$CHURN_DEPLOYMENT_COUNT).
  --scale-to N              Scale targets to N replicas (default: $SCALE_TO).
  --iterations N            Iterations per combination (default: $ITERATIONS).
  --timeout SEC             Timeout per iteration (default: $TIMEOUT_SEC).
  --output-dir DIR          Results directory (default: tests/churn/results).
  --dry-run                 Show plan without executing.
  -h, --help                Show this help.
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
		OUTPUT_DIR="$2"
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

CHURN_INTENSITIES=()
if [[ -n "$CHURN_INTENSITIES_CSV" ]]; then
	split_csv "$CHURN_INTENSITIES_CSV" CHURN_INTENSITIES
else
	CHURN_INTENSITIES=("${CHURN_DEPLOYMENT_COUNT:-5}")
fi

SCRIPT_DIR="${ROOT}/tests/churn"

echo "=========================================="
echo "  Churn Convergence Sweep"
echo "=========================================="
echo "Contexts: ${CONTEXTS[*]}"
echo "Mesh sizes: ${MESH_SIZES[*]}"
echo "Churn intensities: ${CHURN_INTENSITIES[*]}"
echo "Scale: -> $SCALE_TO replicas"
echo "Output: $OUTPUT_DIR"
echo ""

for ms in "${MESH_SIZES[@]}"; do
	active_ctxs=("${CONTEXTS[@]:0:$ms}")
	active_csv=$(IFS=,; echo "${active_ctxs[*]}")
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

	for intensity in "${CHURN_INTENSITIES[@]}"; do
		echo "=========================================="
		echo "  Sweep: mesh_size=$ms  churn_intensity=$intensity"
		echo "  Clusters: ${active_ctxs[*]}"
		echo "=========================================="

		if ((DRY_RUN)); then
			echo "  [dry-run] Would run:"
			echo "    001-setup-churn-test.sh --contexts $active_csv --deployment-count $intensity"
			echo "    002-run-churn-probe.sh --source-context $source_ctx --deployment-count $intensity --scale-to $SCALE_TO"
			echo "    005-cleanup.sh --contexts $active_csv"
			echo ""
			continue
		fi

		echo "--- Setting up ---"
		"$SCRIPT_DIR/001-setup-churn-test.sh" --contexts "$active_csv" --deployment-count "$intensity"
		echo ""

		echo "--- Running churn probe ---"
		probe_args=(
			--source-context "$source_ctx"
			--mesh-size "$ms"
			--deployment-count "$intensity"
			--scale-to "$SCALE_TO"
			--iterations "$ITERATIONS"
			--timeout "$TIMEOUT_SEC"
			--output-dir "$OUTPUT_DIR"
		)
		[[ -n "$remote_csv" ]] && probe_args+=(--remote-contexts "$remote_csv")
		"$SCRIPT_DIR/002-run-churn-probe.sh" "${probe_args[@]}"
		echo ""

		echo "--- Cleaning up ---"
		"$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv"
		echo ""
	done
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

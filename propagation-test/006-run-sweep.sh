#!/usr/bin/env bash
# Orchestrate endpoint propagation probes across multiple mesh sizes for comparison.
# Runs endpoint probes at each mesh size (1, 2, 3, ... N clusters),
# producing results tagged by cluster count for side-by-side analysis.
#
# Usage:
#   ./propagation-test/006-run-sweep.sh [--contexts CSV] [--mesh-sizes CSV] [--iterations N] [options]
#
# Examples:
#   # Sweep 1, 2, 3 clusters:
#   ./propagation-test/006-run-sweep.sh --contexts rosa-001,rosa-002,rosa-003
#
#   # Sweep specific sizes with fewer iterations:
#   ./propagation-test/006-run-sweep.sh --contexts rosa-001,rosa-002,rosa-003 \
#     --mesh-sizes 1,3 --iterations 5
#
#   # Dry-run to see what would be executed:
#   ./propagation-test/006-run-sweep.sh --dry-run
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
MESH_SIZES_CSV=""
ITERATIONS="${PROPAGATION_ITERATIONS}"
TIMEOUT_SEC="${PROPAGATION_TIMEOUT_SEC}"
OUTPUT_DIR="${ROOT}/propagation-test/results"
DRY_RUN=0
WRITE_TSV=0
COLLECT_METRICS=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV       All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV     Cluster counts to test (default: "1,2,...,len(contexts)").
  --iterations N       Iterations per mesh size (default: \$PROPAGATION_ITERATIONS=$ITERATIONS).
  --timeout SEC        Timeout per iteration (default: \$PROPAGATION_TIMEOUT_SEC=$TIMEOUT_SEC).
  --output-dir DIR     Results directory (default: propagation-test/results).
  --tsv                Also write per-iteration TSV files (enables 005 report).
  --collect-metrics    Also run 004-collect-pilot-metrics.sh at each mesh size.
  --dry-run            Show plan without executing.
  -h, --help           Show this help.

Environment:
  SETUP_CONTEXTS, PROPAGATION_ITERATIONS, PROPAGATION_TIMEOUT_SEC.
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
	--collect-metrics)
		COLLECT_METRICS=1
		shift
		;;
	--tsv)
		WRITE_TSV=1
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
	((ms >= 1 && ms <= ${#CONTEXTS[@]})) || die "mesh-size $ms out of range (have ${#CONTEXTS[@]} contexts)"
done

SCRIPT_DIR="${ROOT}/propagation-test"

echo "=========================================="
echo "  Propagation Latency Sweep"
echo "=========================================="
echo "Contexts: ${CONTEXTS[*]}"
echo "Mesh sizes: ${MESH_SIZES[*]}"
echo "Iterations per size: $ITERATIONS"
echo "Output: $OUTPUT_DIR"
echo ""

MD_FILES=()

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
	echo "  Clusters: ${active_ctxs[*]}"
	echo "  Source: $source_ctx"
	echo "  Remotes: ${remote_ctxs[*]:-none}"
	echo "=========================================="
	echo ""

	if ((DRY_RUN)); then
		echo "  [dry-run] Would run:"
		echo "    001-setup-propagation-test.sh --contexts $(IFS=,; echo "${active_ctxs[*]}")"
		echo "    002-run-endpoint-probe.sh --source-context $source_ctx --remote-contexts $remote_csv --mesh-size $ms --iterations $ITERATIONS"
		if ((COLLECT_METRICS)); then
			echo "    004-collect-pilot-metrics.sh --contexts $(IFS=,; echo "${active_ctxs[*]}")"
		fi
		echo ""
		continue
	fi

	echo "--- Setting up watchers ---"
	"$SCRIPT_DIR/001-setup-propagation-test.sh" --contexts "$(IFS=,; echo "${active_ctxs[*]}")"
	echo ""

	echo "--- Running endpoint probe (mesh_size=$ms) ---"
	endpoint_args=(
		--source-context "$source_ctx"
		--mesh-size "$ms"
		--iterations "$ITERATIONS"
		--timeout "$TIMEOUT_SEC"
		--output-dir "$OUTPUT_DIR"
	)
	((WRITE_TSV)) && endpoint_args+=(--tsv)
	if [[ -n "$remote_csv" ]]; then
		endpoint_args+=(--remote-contexts "$remote_csv")
	fi
	"$SCRIPT_DIR/002-run-endpoint-probe.sh" "${endpoint_args[@]}"

	newest_md=$(ls -t "$OUTPUT_DIR"/endpoint-*.md 2>/dev/null | head -1)
	[[ -n "$newest_md" ]] && MD_FILES+=("$newest_md")
	echo ""

	if ((COLLECT_METRICS)); then
		echo "--- Collecting pilot metrics (mesh_size=$ms) ---"
		"$SCRIPT_DIR/004-collect-pilot-metrics.sh" --contexts "$(IFS=,; echo "${active_ctxs[*]}")" --output-dir "$OUTPUT_DIR"
		echo ""
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
if ((WRITE_TSV)); then
	echo "Generating TSV report..."
	"$SCRIPT_DIR/005-report-results.sh" --results-dir "$OUTPUT_DIR" --format text
	echo ""
fi

if ((${#MD_FILES[@]} > 0)); then
	COMBINED="${OUTPUT_DIR}/sweep-$(date +%Y%m%dT%H%M%S).md"
	{
		echo "# Propagation Latency Sweep"
		echo ""
		echo "| Field | Value |"
		echo "|-------|-------|"
		echo "| Date | $(date -Iseconds) |"
		echo "| Contexts | ${CONTEXTS[*]} |"
		echo "| Mesh sizes | ${MESH_SIZES[*]} |"
		echo "| Iterations per size | ${ITERATIONS} |"
		echo "| Timeout | ${TIMEOUT_SEC}s |"
		echo ""
		for i in "${!MD_FILES[@]}"; do
			echo "## Mesh Size ${MESH_SIZES[i]}"
			echo ""
			awk '/^## Summary$/{found=1;next} /^## /{found=0} found{print}' "${MD_FILES[i]}"
			echo ""
		done
	} > "$COMBINED"
	echo "Combined report: $COMBINED"
fi

#!/usr/bin/env bash
# Orchestrate endpoint propagation probes across multiple mesh sizes for comparison.
# Runs endpoint probes at each mesh size (1, 2, 3, ... N clusters),
# producing results tagged by cluster count for side-by-side analysis.
#
# Usage:
#   ./tests/propagation/006-run-sweep.sh [--contexts CSV] [--mesh-sizes CSV] [--iterations N] [options]
#
# Examples:
#   # Sweep 1, 2, 3 clusters:
#   ./tests/propagation/006-run-sweep.sh --contexts rosa-001,rosa-002,rosa-003
#
#   # Sweep specific sizes with fewer iterations:
#   ./tests/propagation/006-run-sweep.sh --contexts rosa-001,rosa-002,rosa-003 \
#     --mesh-sizes 1,3 --iterations 5
#
#   # Dry-run to see what would be executed:
#   ./tests/propagation/006-run-sweep.sh --dry-run
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
MESH_SIZES_CSV=""
ITERATIONS="${PROPAGATION_ITERATIONS}"
TIMEOUT_SEC="${PROPAGATION_TIMEOUT_SEC}"
SETTLE_SEC="${PROPAGATION_SETTLE_SEC}"
MAX_MATRIX="${PROPAGATION_MAX_MATRIX:-64}"
OUTPUT_DIR="${ROOT}/tests/propagation/results"
DRY_RUN=0
WRITE_TSV=0
COLLECT_METRICS=0
FORCE_LARGE_MATRIX=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV         All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV       Cluster counts to test (default: "1,2,...,len(contexts)").
  --mesh-size N          DEPRECATED single-size alias (prints warning to stderr).
  --iterations N         Iterations per mesh size (default: \$PROPAGATION_ITERATIONS=$ITERATIONS).
  --timeout SEC          Timeout per iteration (default: \$PROPAGATION_TIMEOUT_SEC=$TIMEOUT_SEC).
  --settle-sec SEC       Settle gap after cleanup between mesh-size steps (default: $SETTLE_SEC).
  --output-dir DIR       Results root (default: tests/propagation/results). A new
                         per-sweep subdir 'sweep-\${RUN_ID}/' is created underneath.
  --tsv                  Also write per-iteration TSV files (enables 005 report).
  --collect-metrics      Also run 004-collect-pilot-metrics.sh at each mesh size.
  --force-large-matrix   Bypass matrix safety cap (default: $MAX_MATRIX iterations).
  --dry-run              Print planned matrix to stderr; exit without touching clusters.
  -h, --help             Show this help.

Environment:
  SETUP_CONTEXTS, PROPAGATION_ITERATIONS, PROPAGATION_TIMEOUT_SEC, PROPAGATION_SETTLE_SEC,
  PROPAGATION_MAX_MATRIX.
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
	--mesh-size)
		# Deprecated singular alias — forward to --mesh-sizes.
		[[ -n "${2:-}" ]] || die "--mesh-size requires a value"
		echo "warning: --mesh-size is deprecated; use --mesh-sizes CSV (treating as single-size sweep)" >&2
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
		WRITE_TSV=1
		shift
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
	((ms >= 1 && ms <= ${#CONTEXTS[@]})) || die "mesh-size $ms out of range (have ${#CONTEXTS[@]} contexts)"
done

MATRIX_SIZE=$(( ${#MESH_SIZES[@]} * ITERATIONS ))
if (( MATRIX_SIZE > MAX_MATRIX && !FORCE_LARGE_MATRIX )); then
	die "matrix too large: ${#MESH_SIZES[@]} mesh_sizes × $ITERATIONS iterations = $MATRIX_SIZE (max $MAX_MATRIX). Use --force-large-matrix to override."
fi

SCRIPT_DIR="${ROOT}/tests/propagation"
SWEEP_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SWEEP_DIR="${OUTPUT_DIR}/sweep-${SWEEP_RUN_ID}"

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
		echo "Output (would create): $SWEEP_DIR"
		echo ""
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
			echo "--- Plan: mesh_size=$ms ---"
			echo "  001-setup-propagation-test.sh --contexts $(IFS=,; echo "${active_ctxs[*]}")"
			echo "  002-run-endpoint-probe.sh --source-context $source_ctx --remote-contexts $remote_csv --mesh-size $ms --iterations $ITERATIONS --settle-sec $SETTLE_SEC"
			if ((COLLECT_METRICS)); then
				echo "  004-collect-pilot-metrics.sh --contexts $(IFS=,; echo "${active_ctxs[*]}")"
			fi
			echo ""
		done
		echo "Dry-run complete — no clusters touched."
	} >&2
	exit 0
fi

mkdir -p "$SWEEP_DIR"

echo "=========================================="
echo "  Propagation Latency Sweep"
echo "=========================================="
echo "Contexts: ${CONTEXTS[*]}"
echo "Mesh sizes: ${MESH_SIZES[*]}"
echo "Iterations per size: $ITERATIONS"
echo "Settle: ${SETTLE_SEC}s"
echo "Output: $SWEEP_DIR"
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

	# Clean up watchers on contexts not active at this mesh size to prevent
	# orphan sidecars from inflating histogram baselines (R5-S3).
	inactive_ctxs=()
	for c in "${CONTEXTS[@]}"; do
		_match=0
		for ac in "${active_ctxs[@]}"; do
			[[ "$c" == "$ac" ]] && { _match=1; break; }
		done
		((_match)) || inactive_ctxs+=("$c")
	done
	if ((${#inactive_ctxs[@]} > 0)); then
		echo "--- Cleaning up watchers on inactive contexts: ${inactive_ctxs[*]} ---"
		"$SCRIPT_DIR/001-setup-propagation-test.sh" --cleanup --contexts "$(IFS=,; echo "${inactive_ctxs[*]}")" || true
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
		--settle-sec "$SETTLE_SEC"
		--output-dir "$SWEEP_DIR"
	)
	((WRITE_TSV)) && endpoint_args+=(--tsv)
	if [[ -n "$remote_csv" ]]; then
		endpoint_args+=(--remote-contexts "$remote_csv")
	fi
	"$SCRIPT_DIR/002-run-endpoint-probe.sh" "${endpoint_args[@]}"

	# Pick the newest endpoint-*.md emitted by the just-finished probe.
	newest_md=""
	while IFS= read -r f; do
		if [[ -z "$newest_md" || "$f" -nt "$newest_md" ]]; then
			newest_md="$f"
		fi
	done < <(find "$SWEEP_DIR" -maxdepth 1 -name 'endpoint-*.md' -type f 2>/dev/null)
	[[ -n "$newest_md" ]] && MD_FILES+=("$newest_md")
	echo ""

	if ((COLLECT_METRICS)); then
		echo "--- Collecting pilot metrics (mesh_size=$ms) ---"
		"$SCRIPT_DIR/004-collect-pilot-metrics.sh" --contexts "$(IFS=,; echo "${active_ctxs[*]}")" --output-dir "$SWEEP_DIR"
		echo ""
	fi

	echo "  Sweep step settle (${SETTLE_SEC}s)..."
	sleep "$SETTLE_SEC"

	echo ""
done

echo "=========================================="
echo "  Sweep complete"
echo "=========================================="
echo ""
if ((WRITE_TSV)); then
	echo "Generating aggregated report..."
	"$SCRIPT_DIR/005-report-results.sh" --results-dir "$SWEEP_DIR" --format text
	echo ""
fi

if ((${#MD_FILES[@]} > 0)); then
	COMBINED="${SWEEP_DIR}/sweep-summary.md"
	{
		echo "# Propagation Latency Sweep"
		echo ""
		echo "| Field | Value |"
		echo "|-------|-------|"
		echo "| Sweep run ID | \`${SWEEP_RUN_ID}\` |"
		echo "| Date | $(date -u -Iseconds) |"
		echo "| Contexts | ${CONTEXTS[*]} |"
		echo "| Mesh sizes | ${MESH_SIZES[*]} |"
		echo "| Iterations per size | ${ITERATIONS} |"
		echo "| Timeout | ${TIMEOUT_SEC}s |"
		echo "| Settle | ${SETTLE_SEC}s |"
		echo ""
		for i in "${!MD_FILES[@]}"; do
			echo "## Mesh Size ${MESH_SIZES[i]}"
			echo ""
			awk '/^## Summary$/{found=1;next} /^## /{found=0} found{print}' "${MD_FILES[i]}"
			echo ""
		done

		TSV_SWEEP_FILES=()
		for mf in "${MD_FILES[@]}"; do
			[[ -f "${mf%.md}.tsv" ]] && TSV_SWEEP_FILES+=("${mf%.md}.tsv")
		done
		if ((${#TSV_SWEEP_FILES[@]} > 0)); then
			echo "## Comparison (rows with restarted, overflow, non-OK status dropped; p2_ms dropped when p2_dirty=1)"
			echo ""
			echo "| Mesh Size | P1 wall avg (ms) | P1 conv_p99 avg (ms) | P2 EDS avg (ms) | P3 sidecar avg (ms) |"
			echo "|-----------|------------------|----------------------|-----------------|---------------------|"
			# H2: asorti() is gawk-only; emit a manual sort that works under mawk.
			cat "${TSV_SWEEP_FILES[@]}" | awk -F'\t' '
			!/^#/ && !/^run_id/ && NF>=10 {
				ms = $2
				status = $10
				p1 = $7; p2 = $8; p3 = $9
				cp99 = ($12 == "") ? "N/A" : $12
				overflow = ($15 == "") ? "0" : $15
				restarted = ($16 == "") ? "0" : $16
				p2_dirty = (NF >= 19 && $17 != "") ? $17 : "0"
				if (restarted == "1" || restarted == "unknown") next
				if (overflow == "1") next
				if (status != "" && status != "OK") next
				if (p1 != "TIMEOUT" && p1 != "N/A" && p1 ~ /^[0-9]+$/) { p1_sum[ms] += p1; p1_n[ms]++ }
				if (p2_dirty != "1" && p2 != "TIMEOUT" && p2 != "N/A" && p2 ~ /^[0-9]+$/) { p2_sum[ms] += p2; p2_n[ms]++ }
				if (p3 != "TIMEOUT" && p3 != "N/A" && p3 ~ /^[0-9]+$/) { p3_sum[ms] += p3; p3_n[ms]++ }
				if (cp99 != "N/A" && cp99 != "overflow" && cp99 ~ /^[0-9]+$/) { cp99_sum[ms] += cp99; cp99_n[ms]++ }
				seen[ms] = 1
			}
			END {
				# Manual sort: gather keys, insertion-sort. Same approach as 005.
				n = 0
				for (k in seen) { sizes[++n] = k }
				for (i = 2; i <= n; i++) {
					tmp = sizes[i]; j = i - 1
					while (j >= 1 && sizes[j] > tmp) { sizes[j+1] = sizes[j]; j-- }
					sizes[j+1] = tmp
				}
				for (s = 1; s <= n; s++) {
					m = sizes[s]
					p1_avg   = (p1_n[m]   > 0) ? sprintf("%d", p1_sum[m]   / p1_n[m])   : "--"
					cp99_avg = (cp99_n[m] > 0) ? sprintf("%d", cp99_sum[m] / cp99_n[m]) : "--"
					p2_avg   = (p2_n[m]   > 0) ? sprintf("%d", p2_sum[m]   / p2_n[m])   : "--"
					p3_avg   = (p3_n[m]   > 0) ? sprintf("%d", p3_sum[m]   / p3_n[m])   : "--"
					printf "| %s | %s | %s | %s | %s |\n", m, p1_avg, cp99_avg, p2_avg, p3_avg
				}
			}'
			echo ""
		fi
	} > "$COMBINED"
	echo "Combined report: $COMBINED"
fi

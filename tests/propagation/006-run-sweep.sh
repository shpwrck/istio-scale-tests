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
#   ./tests/propagation/006-run-sweep.sh --contexts cluster-001,cluster-002,cluster-003
#
#   # Sweep specific sizes with fewer iterations:
#   ./tests/propagation/006-run-sweep.sh --contexts cluster-001,cluster-002,cluster-003 \
#     --mesh-sizes 1,3 --iterations 5
#
#   # Dry-run to see what would be executed:
#   ./tests/propagation/006-run-sweep.sh --dry-run
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
ITERATIONS="${PROPAGATION_ITERATIONS}"
TIMEOUT_SEC="${PROPAGATION_TIMEOUT_SEC}"
SETTLE_SEC="${PROPAGATION_SETTLE_SEC}"
MAX_MATRIX="${PROPAGATION_MAX_MATRIX:-64}"
OUTPUT_DIR="${ROOT}/tests/propagation/results"
WATCHER_REPLICAS="${PROPAGATION_WATCHER_REPLICAS}"
DRY_RUN=0
WRITE_TSV=0
COLLECT_METRICS=0
FORCE_LARGE_MATRIX=0


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV         All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV       Cluster counts to test (default: "1,2,...,len(contexts)").
  --mesh-size N          DEPRECATED single-size alias (prints warning to stderr).
  --watcher-replicas N   Watcher pod replicas per cluster (default: \$PROPAGATION_WATCHER_REPLICAS=$WATCHER_REPLICAS).
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
  PROPAGATION_WATCHER_REPLICAS, PROPAGATION_MAX_MATRIX.
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
HARNESS_SHA="$(harness_sha)"

# Tuning-baseline provenance (PL2/PL26): query the LIVE deployed tuning levers +
# sidecar egress graph ONCE, against the source context (CONTEXTS[0]) — a sweep-wide
# scalar (the mesh's tuning is identical regardless of how many clusters a combo
# measures). The sidecar-scoping / discoverySelectors / telemetry levers directly
# change what xDS/EDS propagation measures, so a run on the baked baseline is
# provenance-blind without these. Threaded to 002 (--tuning-baseline /
# --sidecar-egress-hosts) AND emitted by the placeholder writer above (PL36 contract).
# Skipped in --dry-run (cluster read); stays "unknown".
TUNING_BASELINE="unknown"
SIDECAR_EGRESS_HOSTS="unknown"
if ((! DRY_RUN)); then
	if command -v oc >/dev/null 2>&1; then
		KUBECTL=(oc)
	elif command -v kubectl >/dev/null 2>&1; then
		KUBECTL=(kubectl)
	else
		KUBECTL=()
	fi
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

# B6: emit a minimal placeholder TSV for a mesh size whose setup/probe crashed before
# the probe could write its own rows. Without this, that size is absent from the
# report and indistinguishable from "never planned". 005-report-results.sh globs
# endpoint-*.tsv and counts n_total[mesh_size] for any NF>=10 row, excluding non-OK
# status from n_valid (PL15). Only meaningful when --tsv is set (the report runs only
# then). The file is named so it sorts AFTER the real endpoint-<RUN_ID> files, and it
# carries the SAME sweep-level scalar preamble keys (SWEEP_RUN_ID/HARNESS_SHA/
# ISTIO_VERSION/SOURCE_CTX/ITERATIONS/TIMEOUT_SEC/SETTLE_SEC/TUNING_BASELINE/
# SIDECAR_EGRESS_HOSTS) so PL26 scalar homogeneity holds; per-iteration
# RUN_ID/MESH_SIZE are this combo's.
# Usage: emit_propagation_placeholder <status> <mesh_size> <source_ctx>
emit_propagation_placeholder() {
	((WRITE_TSV)) || return 0
	local status="$1" ms="$2" sctx="$3"
	mkdir -p "$SWEEP_DIR"
	local f="${SWEEP_DIR}/endpoint-zzfail-ms${ms}-${SWEEP_RUN_ID}.tsv"
	{
		echo "# Endpoint propagation latency test (placeholder — combo failed before any row)"
		echo "# SWEEP_RUN_ID=${SWEEP_RUN_ID}"
		echo "# RUN_ID=${SWEEP_RUN_ID}-failms${ms}"
		echo "# HARNESS_SHA=${HARNESS_SHA}"
		echo "# ISTIO_VERSION=${ISTIO_VERSION:-unknown}"
		echo "# SOURCE_CTX=${sctx}"
		echo "# MESH_SIZE=${ms}"
		echo "# ITERATIONS=${ITERATIONS}"
		echo "# TIMEOUT_SEC=${TIMEOUT_SEC}"
		echo "# SETTLE_SEC=${SETTLE_SEC}"
		# PL36: emit the same tuning-baseline keys 002 writes so this placeholder file
		# (potentially the report's first TSV) carries identical sweep-level provenance.
		echo "# TUNING_BASELINE=${TUNING_BASELINE}"
		echo "# SIDECAR_EGRESS_HOSTS=${SIDECAR_EGRESS_HOSTS}"
		echo "# NOTE=${status}: setup or probe exited non-zero; counted in n_total, excluded from n_valid"
		echo -e "run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms"
		# One degraded row: status carries the sentinel, restarted=unknown -> filtered
		# from n_valid; numerics N/A (PL13).
		echo -e "${SWEEP_RUN_ID}-failms${ms}\t${ms}\t0\t${sctx}\tN/A\tN/A\tN/A\tN/A\tN/A\t${status}\tN/A\tN/A\tN/A\tN/A\tN/A\tunknown\t0\tN/A\tN/A"
	} > "$f"
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
			echo "  001-setup-propagation-test.sh --contexts $(IFS=,; echo "${active_ctxs[*]}") --watcher-replicas $WATCHER_REPLICAS"
			echo "  002-run-endpoint-probe.sh --source-context $source_ctx --remote-contexts $remote_csv --mesh-size $ms --sweep-run-id $SWEEP_RUN_ID --iterations $ITERATIONS --settle-sec $SETTLE_SEC"
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

sweep_cleanup() {
	echo ""
	echo "--- Final cleanup: all contexts ---"
	"$SCRIPT_DIR/007-cleanup.sh" --contexts "$(IFS=,; echo "${CONTEXTS[*]}")" || true
}
trap sweep_cleanup EXIT

echo "=========================================="
echo "  Propagation Latency Sweep"
echo "=========================================="
echo "Contexts: ${CONTEXTS[*]}"
echo "Mesh sizes: ${MESH_SIZES[*]}"
echo "Iterations per size: $ITERATIONS"
echo "Settle: ${SETTLE_SEC}s"
echo "Output: $SWEEP_DIR"
echo ""

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
	# B1/B6: setup is a probable per-combo failure at scale; bare under set -e it would
	# abort the whole sweep. On failure record a placeholder row (so this mesh size is
	# visible in the report), then continue to the next mesh size.
	if ! "$SCRIPT_DIR/001-setup-propagation-test.sh" --contexts "$(IFS=,; echo "${active_ctxs[*]}")" --watcher-replicas "$WATCHER_REPLICAS"; then
		echo "warn: watcher setup failed for mesh_size=$ms; recording SETUP_FAILED placeholder and continuing" >&2
		emit_propagation_placeholder SETUP_FAILED "$ms" "$source_ctx"
		echo ""
		continue
	fi
	echo ""

	echo "--- Running endpoint probe (mesh_size=$ms) ---"
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
	)
	((WRITE_TSV)) && endpoint_args+=(--tsv)
	if [[ -n "$remote_csv" ]]; then
		endpoint_args+=(--remote-contexts "$remote_csv")
	fi
	# P0/B6: a probe failure must NOT abort the multi-hour sweep. The endpoint probe
	# writes its own per-iteration rows into $SWEEP_DIR (self-tagging TIMEOUT_*/
	# DRAIN_TIMEOUT/RESTART/SCRAPE_INCOMPLETE). If it crashed BEFORE writing any row,
	# this mesh size would vanish from the report (indistinguishable from never-planned),
	# so emit a placeholder row to make the combo visible (n_total++, excluded from
	# n_valid). If the probe DID write rows, the placeholder is additive (one extra
	# non-OK row in n_total) and still honest.
	if ! "$SCRIPT_DIR/002-run-endpoint-probe.sh" "${endpoint_args[@]}"; then
		echo "warn: endpoint probe failed for mesh_size=$ms; recording PROBE_FAILED placeholder and continuing" >&2
		emit_propagation_placeholder PROBE_FAILED "$ms" "$source_ctx"
	fi
	echo ""

	if ((COLLECT_METRICS)); then
		echo "--- Collecting pilot metrics (mesh_size=$ms) ---"
		# Non-fatal: optional supplementary collection must not abort the sweep.
		"$SCRIPT_DIR/004-collect-pilot-metrics.sh" --contexts "$(IFS=,; echo "${active_ctxs[*]}")" --output-dir "$SWEEP_DIR" || \
			echo "warn: pilot metrics collection failed for mesh_size=$ms; continuing" >&2
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

	# Markdown sweep summary is generated by the report script (AGENTS.md "Markdown
	# Summary" rule). The report's YAML frontmatter carries the run metadata
	# (RUN_ID, SOURCE_CTX, REMOTES, MESH_SIZE, ITERATIONS, TIMEOUT_SEC, SETTLE_SEC,
	# DATE, HARNESS_SHA, ISTIO_VERSION, KUBE_VERSIONS) that the previous hand-rolled
	# header surfaced; the cross-mesh-size comparison table lives at the bottom of
	# the report's markdown output.
	COMBINED="${SWEEP_DIR}/sweep-summary.md"
	"$SCRIPT_DIR/005-report-results.sh" --results-dir "$SWEEP_DIR" --format markdown > "$COMBINED"
	echo "Combined report: $COMBINED"

	CHARTS_FILE="${SWEEP_DIR}/sweep-charts.md"
	"$SCRIPT_DIR/005-report-results.sh" --results-dir "$SWEEP_DIR" --format charts > "$CHARTS_FILE"
	echo "Charts written to $CHARTS_FILE"
fi

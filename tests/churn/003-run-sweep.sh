#!/usr/bin/env bash
# Orchestrate churn probes across mesh sizes and churn intensities.
#
# Usage:
#   ./tests/churn/003-run-sweep.sh [--contexts CSV] [--mesh-sizes CSV] [options]
#
# Examples:
#   # Sweep 1, 2, 3 clusters with default churn:
#   ./tests/churn/003-run-sweep.sh --contexts cluster-001,cluster-002,cluster-003
#
#   # Sweep churn intensities (deployment counts):
#   ./tests/churn/003-run-sweep.sh --churn-intensities 5,10,20
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
CHURN_INTENSITIES_CSV=""
SCALE_TO="${CHURN_SCALE_TO_REPLICAS:-5}"
ITERATIONS="${CHURN_ITERATIONS:-5}"
TIMEOUT_SEC="${CHURN_TIMEOUT_SEC:-120}"
OUTPUT_DIR_BASE="${ROOT}/tests/churn/results"
DRY_RUN=0


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV            All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV          Cluster counts to test (default: "1,2,...,len(contexts)").
  --churn-intensities CSV   Deployment counts to test (default: \$CHURN_DEPLOYMENT_COUNT).
  --scale-to N              Scale targets to N replicas (default: $SCALE_TO).
  --iterations N            Iterations per combination (default: $ITERATIONS).
  --timeout SEC             Timeout per iteration (default: $TIMEOUT_SEC).
  --output-dir DIR          Results base directory (default: tests/churn/results).
  --dry-run                 Show plan without executing.
  -h, --help                Show this help.
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

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SWEEP_DIR="${OUTPUT_DIR_BASE}/sweep-${RUN_ID}"
HARNESS_SHA="$(harness_sha)"
# base_replicas the probe will use (matched here so the placeholder buckets into the
# SAME (mesh,intensity,base_replicas,scale_to) cell the real probe rows would).
CHURN_BASE_REPLICAS_DEFAULT="${CHURN_BASE_REPLICAS:-1}"

# Tuning-baseline provenance (PL2/PL26): query the LIVE deployed tuning levers +
# sidecar egress graph ONCE, against the source context (CONTEXTS[0]) — a sweep-wide
# scalar (the mesh's tuning is identical across all combos). The sidecar-scoping /
# discoverySelectors / telemetry levers directly change what churn convergence
# measures, so a run on the baked baseline is provenance-blind without these. Threaded
# to 002 (--tuning-baseline / --sidecar-egress-hosts) AND emitted by the placeholder
# writer (PL36 contract). Skipped in --dry-run (cluster read); stays "unknown".
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

# B6: emit a minimal placeholder TSV for a combo whose setup/probe crashed before the
# probe wrote any row. Without it the combo vanishes from the report (looks like
# never-planned). 004-report-results.sh globs churn-*.tsv and counts n_total per
# (mesh,intensity,base_replicas,scale_to) for NF>=21 rows, excluding non-OK $21 from
# n_valid (PL15). Named to sort AFTER the real churn-<RUN_ID> files.
# Usage: emit_churn_placeholder <status> <mesh_size> <intensity>
emit_churn_placeholder() {
	local status="$1" ms="$2" intensity="$3"
	mkdir -p "$SWEEP_DIR"
	local f="${SWEEP_DIR}/churn-zzfail-ms${ms}-i${intensity}-${RUN_ID}.tsv"
	{
		echo "# Churn convergence test (placeholder — combo failed before any row)"
		echo "# HARNESS_SHA=${HARNESS_SHA}"
		echo "# ISTIO_VERSION=${ISTIO_VERSION:-unknown}"
		# PL36: match 002's preamble key set so the placeholder file (which 004 may read
		# as TSV_FILES[0]) carries the same tuning-baseline provenance.
		echo "# TUNING_BASELINE=${TUNING_BASELINE}"
		echo "# SIDECAR_EGRESS_HOSTS=${SIDECAR_EGRESS_HOSTS}"
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
echo "Mesh sizes: ${MESH_SIZES[*]}"
echo "Churn intensities: ${CHURN_INTENSITIES[*]}"
echo "Scale: -> $SCALE_TO replicas"
echo "Output: $SWEEP_DIR"
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
			echo "    002-run-churn-probe.sh --source-context $source_ctx --deployment-count $intensity --scale-to $SCALE_TO --output-dir $SWEEP_DIR --tuning-baseline <live> --sidecar-egress-hosts <live>"
			echo "    005-cleanup.sh --contexts $active_csv"
			echo ""
			continue
		fi

		[[ -d "$SWEEP_DIR" ]] || mkdir -p "$SWEEP_DIR"

		echo "--- Setting up ---"
		# B1/B6: setup is a probable per-combo failure at scale; bare under set -e it
		# would abort the whole sweep. On failure record a placeholder row (so this combo
		# is visible in the report), clean up, and continue to the next combo.
		if ! "$SCRIPT_DIR/001-setup-churn-test.sh" --contexts "$active_csv" --deployment-count "$intensity"; then
			echo "warn: setup failed for mesh_size=$ms churn_intensity=$intensity; recording SETUP_FAILED placeholder and continuing" >&2
			emit_churn_placeholder SETUP_FAILED "$ms" "$intensity"
			"$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
				echo "warn: cleanup after setup failure also reported failure for mesh_size=$ms churn_intensity=$intensity" >&2
			echo ""
			continue
		fi
		echo ""

		echo "--- Running churn probe ---"
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
		# P0/B6: a probe failure must NOT abort the multi-hour sweep. The churn probe
		# writes its own per-iteration rows into $SWEEP_DIR (self-tagging POISONED_*/
		# SCRAPE_INCOMPLETE/TIMEOUT_*). If it crashed BEFORE writing any row, this combo
		# would vanish from the report (indistinguishable from never-planned), so emit a
		# placeholder row to keep the combo visible (n_total++, excluded from n_valid).
		if ! "$SCRIPT_DIR/002-run-churn-probe.sh" "${probe_args[@]}"; then
			echo "warn: churn probe failed for mesh_size=$ms churn_intensity=$intensity; recording PROBE_FAILED placeholder and continuing (cleanup runs below)" >&2
			emit_churn_placeholder PROBE_FAILED "$ms" "$intensity"
		fi
		echo ""

		echo "--- Cleaning up ---"
		# P0/PL23: a cleanup hiccup must not abort the sweep — the next combo's setup also
		# cleans the namespace. Warn and continue.
		"$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
			echo "warn: cleanup reported failure for mesh_size=$ms churn_intensity=$intensity; next combo's setup will re-clean" >&2
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
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$SWEEP_DIR"

MD_FILE="${SWEEP_DIR}/sweep-${RUN_ID}.md"
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$SWEEP_DIR" --format markdown > "$MD_FILE"
echo "Markdown summary written to $MD_FILE"

CHARTS_FILE="${SWEEP_DIR}/sweep-charts-${RUN_ID}.md"
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$SWEEP_DIR" --format charts > "$CHARTS_FILE"
echo "Charts written to $CHARTS_FILE"

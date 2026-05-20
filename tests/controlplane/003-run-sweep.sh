#!/usr/bin/env bash
# Orchestrate control-plane resource collection across the cross-product of
# four sweep axes: mesh size × service count × replicas × namespace count.
#
# For every combination, deploys dummy workloads, settles, scrapes istiod, and
# cleans up before moving on. Istiod push cost scales with services × sidecars
# × endpoints — not just cluster count — so exposing these as independent
# sweep dimensions lets operators locate the knee and separate the effect of
# "more clusters" from "more config" and namespace-informer overhead.
#
# Usage:
#   ./tests/controlplane/003-run-sweep.sh [options]
#
# Examples:
#   # Default sweep — mesh sizes 1..N with default (10 svc × 3 replicas × 1 ns):
#   ./tests/controlplane/003-run-sweep.sh --contexts rosa-001,rosa-002,rosa-003
#
#   # Two-axis sweep: service count × namespace count, fixed mesh size of 3:
#   ./tests/controlplane/003-run-sweep.sh \
#     --contexts rosa-001,rosa-002,rosa-003 \
#     --mesh-sizes 3 --service-counts 10,100,500 --namespace-counts 1,5,25
#
#   # Singular-form aliases (compat with older single-value invocations):
#   ./tests/controlplane/003-run-sweep.sh --contexts a --service-count 50 --replicas 3
#
#   # Dry-run to see the planned matrix:
#   ./tests/controlplane/003-run-sweep.sh --dry-run \
#     --contexts a,b,c --service-counts 10,100 --namespace-counts 1,5
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
MESH_SIZES_CSV=""
SERVICE_COUNTS_CSV="${CONTROLPLANE_SERVICE_COUNT:-10}"
REPLICA_COUNTS_CSV="${CONTROLPLANE_REPLICAS_PER_SERVICE:-3}"
NAMESPACE_COUNTS_CSV="${CONTROLPLANE_NAMESPACE_COUNT:-1}"
OUTPUT_DIR_BASE="${ROOT}/tests/controlplane/results"
SETTLE_SEC=60
DRY_RUN=0
FORCE_LARGE_MATRIX=0
# Safety cap on cross-product matrix size; opt out with --force-large-matrix.
# Default lives in config/options.env (CONTROLPLANE_MAX_MATRIX, sourced via
# versions.env above). The :- fallback here is a belt-and-braces guard in
# case options.env is ever bypassed; it should never fire in normal use.
MAX_MATRIX="${CONTROLPLANE_MAX_MATRIX:-64}"

NS="${CONTROLPLANE_TEST_NAMESPACE:-controlplane-test}"

die() { echo "error: $*" >&2; exit 1; }

is_pos_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
is_nonneg_int() { [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Sweep dimensions (cross-product):
  --contexts CSV              All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV            Cluster counts (default: "1,2,...,len(contexts)").
  --service-counts CSV        Dummy services per cluster (default: $SERVICE_COUNTS_CSV).
  --replica-counts CSV        Replicas per service (default: $REPLICA_COUNTS_CSV).
  --namespace-counts CSV      Namespaces to spread services across (default: $NAMESPACE_COUNTS_CSV).

Singular aliases (one CSV value each — handy for copy-paste from older runs):
  --service-count N           Alias for --service-counts N.
  --replicas N                Alias for --replica-counts N.
  --replicas-counts CSV       Deprecated alias for --replica-counts (will be removed in a future release).
  --namespace-count N         Alias for --namespace-counts N.

Other:
  --settle SEC                Seconds for the delta-window between baseline
                              and final scrape (default: $SETTLE_SEC). Threaded
                              into 002 verbatim — 002 owns the actual sleep.
  --output-dir DIR            Results base directory; each sweep gets a
                              sweep-<RUN_ID>/ subdir under it
                              (default: tests/controlplane/results).
  --force-large-matrix        Allow matrix > $MAX_MATRIX combinations (default: refuse).
  --dry-run                   Print plan and matrix, then exit.
  -h, --help                  Show this help.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_SERVICE_COUNT, CONTROLPLANE_REPLICAS_PER_SERVICE,
  CONTROLPLANE_NAMESPACE_COUNT, CONTROLPLANE_MAX_MATRIX.

Notes:
  * The sweep iterates the cross-product
        mesh-sizes × service-counts × replica-counts × namespace-counts.
    For 4 mesh sizes × 3 service counts × 2 replica counts × 3 ns counts the
    sweep runs 72 combinations — refuse-unless-forced threshold is $MAX_MATRIX.
  * 001/005 are invoked between every combination so istiod starts from a
    known empty state. Settle time is single-valued; bump --settle when
    pushing many services so metrics reflect steady state.
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
	--service-counts)
		[[ -n "${2:-}" ]] || die "--service-counts requires a value"
		SERVICE_COUNTS_CSV="$2"
		shift 2
		;;
	--service-count)
		# Singular alias — one CSV value.
		[[ -n "${2:-}" ]] || die "--service-count requires a value"
		SERVICE_COUNTS_CSV="$2"
		shift 2
		;;
	--replica-counts)
		[[ -n "${2:-}" ]] || die "--replica-counts requires a value"
		REPLICA_COUNTS_CSV="$2"
		shift 2
		;;
	--replicas-counts)
		# Deprecated alias for --replica-counts.
		[[ -n "${2:-}" ]] || die "--replicas-counts requires a value"
		echo "warning: --replicas-counts is deprecated; use --replica-counts" >&2
		REPLICA_COUNTS_CSV="$2"
		shift 2
		;;
	--replicas)
		# Singular alias — one CSV value.
		[[ -n "${2:-}" ]] || die "--replicas requires a value"
		REPLICA_COUNTS_CSV="$2"
		shift 2
		;;
	--namespace-counts)
		[[ -n "${2:-}" ]] || die "--namespace-counts requires a value"
		NAMESPACE_COUNTS_CSV="$2"
		shift 2
		;;
	--namespace-count)
		# Singular alias — one CSV value.
		[[ -n "${2:-}" ]] || die "--namespace-count requires a value"
		NAMESPACE_COUNTS_CSV="$2"
		shift 2
		;;
	--settle)
		[[ -n "${2:-}" ]] || die "--settle requires a value"
		SETTLE_SEC="$2"
		shift 2
		;;
	--output-dir)
		[[ -n "${2:-}" ]] || die "--output-dir requires a value"
		OUTPUT_DIR_BASE="$2"
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

is_nonneg_int "$SETTLE_SEC" || die "--settle must be a non-negative integer (got: $SETTLE_SEC)"
is_pos_int "$MAX_MATRIX" || die "CONTROLPLANE_MAX_MATRIX must be a positive integer (got: $MAX_MATRIX)"

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
((${#MESH_SIZES[@]})) || die "no mesh sizes resolved"

SERVICE_COUNTS=()
split_csv "$SERVICE_COUNTS_CSV" SERVICE_COUNTS
((${#SERVICE_COUNTS[@]})) || die "--service-counts produced an empty list"

REPLICA_COUNTS=()
split_csv "$REPLICA_COUNTS_CSV" REPLICA_COUNTS
((${#REPLICA_COUNTS[@]})) || die "--replica-counts produced an empty list"

NAMESPACE_COUNTS=()
split_csv "$NAMESPACE_COUNTS_CSV" NAMESPACE_COUNTS
((${#NAMESPACE_COUNTS[@]})) || die "--namespace-counts produced an empty list"

for ms in "${MESH_SIZES[@]}"; do
	is_pos_int "$ms" || die "mesh-size '$ms' is not a positive integer"
	((ms >= 1 && ms <= ${#CONTEXTS[@]})) || die "mesh-size $ms out of range (have ${#CONTEXTS[@]} contexts)"
done
for sc in "${SERVICE_COUNTS[@]}"; do
	is_pos_int "$sc" || die "service-count '$sc' is not a positive integer"
done
for rc in "${REPLICA_COUNTS[@]}"; do
	is_pos_int "$rc" || die "replica-count '$rc' is not a positive integer"
done
for nc in "${NAMESPACE_COUNTS[@]}"; do
	is_pos_int "$nc" || die "namespace-count '$nc' is not a positive integer"
done

MATRIX_SIZE=$(( ${#MESH_SIZES[@]} * ${#SERVICE_COUNTS[@]} * ${#REPLICA_COUNTS[@]} * ${#NAMESPACE_COUNTS[@]} ))

SCRIPT_DIR="${ROOT}/tests/controlplane"

# Per-sweep output subdirectory so back-to-back sweeps don't conflate.
# RUN_ID intentionally uses UTC to align with 002's preamble timestamps.
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OUTPUT_DIR="${OUTPUT_DIR_BASE}/sweep-${RUN_ID}"

# Banner goes to stderr so it stays visible even when stdout is piped/captured.
{
	echo "=========================================="
	echo "  Control-Plane Resource Sweep"
	echo "=========================================="
	echo "Contexts:         ${CONTEXTS[*]}"
	echo "Mesh sizes:       ${MESH_SIZES[*]}"
	echo "Service counts:   ${SERVICE_COUNTS[*]}"
	echo "Replica counts:   ${REPLICA_COUNTS[*]}"
	echo "Namespace counts: ${NAMESPACE_COUNTS[*]}"
	echo "Settle time:      ${SETTLE_SEC}s"
	echo "Run ID:           ${RUN_ID}"
	echo "Output:           ${OUTPUT_DIR}"
	echo ""
	echo "Planned matrix:   ${MATRIX_SIZE} = ${#MESH_SIZES[@]}×${#SERVICE_COUNTS[@]}×${#REPLICA_COUNTS[@]}×${#NAMESPACE_COUNTS[@]} (mesh × svc × rep × ns)"
	echo ""
} >&2

if ((MATRIX_SIZE > MAX_MATRIX)) && ! ((FORCE_LARGE_MATRIX)); then
	die "matrix size $MATRIX_SIZE = ${#MESH_SIZES[@]}×${#SERVICE_COUNTS[@]}×${#REPLICA_COUNTS[@]}×${#NAMESPACE_COUNTS[@]} exceeds safety limit $MAX_MATRIX; re-run with --force-large-matrix to proceed"
fi

# Pick kubectl/oc for defense-in-depth cleanup wait.
if command -v oc >/dev/null 2>&1; then
	KUBECTL=(oc)
elif command -v kubectl >/dev/null 2>&1; then
	KUBECTL=(kubectl)
else
	KUBECTL=()
fi

if ((DRY_RUN)); then
	echo "--- Combinations (dry-run) ---" >&2
fi

# Pretty-print the namespace pattern for the per-combo banner.
fmt_ns_pattern() {
	local nc="$1"
	if (( nc <= 1 )); then
		printf '%s\n' "$NS"
	else
		printf '%s-0..%s-%d\n' "$NS" "$NS" "$(( nc - 1 ))"
	fi
}

# Create the per-sweep output dir lazily on first real combo (dry-run skips).
ensure_output_dir() {
	[[ -d "$OUTPUT_DIR" ]] && return 0
	mkdir -p "$OUTPUT_DIR"
	echo "Output directory: $OUTPUT_DIR" >&2
}

combo_idx=0
for ms in "${MESH_SIZES[@]}"; do
	active_ctxs=("${CONTEXTS[@]:0:$ms}")
	active_csv=$(IFS=,; echo "${active_ctxs[*]}")
	for sc in "${SERVICE_COUNTS[@]}"; do
		for rc in "${REPLICA_COUNTS[@]}"; do
			for nc in "${NAMESPACE_COUNTS[@]}"; do
				combo_idx=$((combo_idx + 1))
				label="mesh=$ms svcs=$sc reps=$rc ns=$nc"
				ns_pattern=$(fmt_ns_pattern "$nc")

				if ((DRY_RUN)); then
					printf "  [%2d/%2d] %s  (clusters: %s)  Namespaces: %s\n" \
						"$combo_idx" "$MATRIX_SIZE" "$label" "${active_ctxs[*]}" "$ns_pattern" >&2
					continue
				fi

				ensure_output_dir

				echo "=========================================="
				printf "  Sweep [%d/%d]: %s\n" "$combo_idx" "$MATRIX_SIZE" "$label"
				echo "  Clusters:   ${active_ctxs[*]}"
				echo "  Namespaces: ${ns_pattern}"
				echo "=========================================="
				echo ""

				# Split-phase metrics collection: scrape baseline BEFORE 001
				# deploys, so the deploy-time istiod CPU spike and xDS push
				# storm land inside the measurement window. The previous
				# arrangement put the entire window AFTER 001 had returned
				# (workloads already Available, istiod back to idle), which
				# made `cpu_m_delta` consistently miss the actual work and
				# read near-zero on quiet clusters.
				STATE_DIR_COMBO="${OUTPUT_DIR}/state-combo-${combo_idx}"
				mkdir -p "$STATE_DIR_COMBO"

				echo "--- Baseline metrics scrape (phase 1/3) ---"
				"$SCRIPT_DIR/002-collect-resource-metrics.sh" \
					--phase baseline \
					--state-dir "$STATE_DIR_COMBO" \
					--contexts "$active_csv" \
					--mesh-size "$ms" \
					--service-count "$sc" \
					--replicas "$rc" \
					--namespace-count "$nc" \
					--settle "$SETTLE_SEC"
				echo ""

				echo "--- Deploying workloads (phase 2/3) ---"
				"$SCRIPT_DIR/001-setup-controlplane-test.sh" \
					--contexts "$active_csv" \
					--service-count "$sc" \
					--replicas "$rc" \
					--namespace-count "$nc"
				echo ""

				if (( SETTLE_SEC > 0 )); then
					echo "--- Settling ${SETTLE_SEC}s for steady-state before final scrape ---"
					sleep "$SETTLE_SEC"
					echo ""
				fi

				echo "--- Final metrics scrape + emit (phase 3/3) — window covers baseline → deploy → settle ---"
				"$SCRIPT_DIR/002-collect-resource-metrics.sh" \
					--phase final \
					--state-dir "$STATE_DIR_COMBO" \
					--contexts "$active_csv" \
					--mesh-size "$ms" \
					--service-count "$sc" \
					--replicas "$rc" \
					--namespace-count "$nc" \
					--settle "$SETTLE_SEC" \
					--output-dir "$OUTPUT_DIR"
				rm -rf "$STATE_DIR_COMBO"
				echo ""

				echo "--- Cleaning up ---"
				"$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv"

				# Defense-in-depth: even after 005 returns, give the API server
				# a moment to actually finalize ns deletion before the next
				# 001 starts re-creating. 005 already waits, this is belt+brace
				# and is a no-op once the namespaces are gone. Run per-context
				# in parallel — sequential waits compound badly on big meshes —
				# and match 005's own polling timeout (300s) so we don't trip
				# before the cleanup script itself would have.
				if (( ${#KUBECTL[@]} )); then
					wait_pids=()
					for ctx in "${active_ctxs[@]}"; do
						"${KUBECTL[@]}" --context="$ctx" wait --for=delete \
							namespace -l app.kubernetes.io/instance=controlplane-test \
							--timeout=300s >/dev/null 2>&1 &
						wait_pids+=($!)
					done
					for pid in "${wait_pids[@]}"; do
						wait "$pid" 2>/dev/null || true
					done
				fi
				echo ""
			done
		done
	done
done

if ((DRY_RUN)); then
	echo "" >&2
	echo "Dry-run complete. $combo_idx combinations enumerated; no clusters touched." >&2
	exit 0
fi

echo "=========================================="
echo "  Sweep complete ($combo_idx combinations)"
echo "=========================================="
echo ""
echo "Generating report..."
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$OUTPUT_DIR"

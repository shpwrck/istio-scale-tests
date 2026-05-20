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
REPLICAS_COUNTS_CSV="${CONTROLPLANE_REPLICAS_PER_SERVICE:-3}"
NAMESPACE_COUNTS_CSV="${CONTROLPLANE_NAMESPACE_COUNT:-1}"
OUTPUT_DIR="${ROOT}/tests/controlplane/results"
SETTLE_SEC=60
DRY_RUN=0
FORCE_LARGE_MATRIX=0
MAX_MATRIX=64

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
  --replicas-counts CSV       Replicas per service (default: $REPLICAS_COUNTS_CSV).
  --namespace-counts CSV      Namespaces to spread services across (default: $NAMESPACE_COUNTS_CSV).

Other:
  --settle SEC                Seconds to wait after deploy before collecting (default: $SETTLE_SEC).
  --output-dir DIR            Results directory (default: tests/controlplane/results).
  --force-large-matrix        Allow matrix > $MAX_MATRIX combinations (default: refuse).
  --dry-run                   Print plan and matrix, then exit.
  -h, --help                  Show this help.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_SERVICE_COUNT, CONTROLPLANE_REPLICAS_PER_SERVICE,
  CONTROLPLANE_NAMESPACE_COUNT.

Notes:
  * The sweep iterates the cross-product
        mesh-sizes × service-counts × replicas-counts × namespace-counts.
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
	--replicas-counts)
		[[ -n "${2:-}" ]] || die "--replicas-counts requires a value"
		REPLICAS_COUNTS_CSV="$2"
		shift 2
		;;
	--namespace-counts)
		[[ -n "${2:-}" ]] || die "--namespace-counts requires a value"
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
		OUTPUT_DIR="$2"
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

REPLICAS_COUNTS=()
split_csv "$REPLICAS_COUNTS_CSV" REPLICAS_COUNTS
((${#REPLICAS_COUNTS[@]})) || die "--replicas-counts produced an empty list"

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
for rc in "${REPLICAS_COUNTS[@]}"; do
	is_pos_int "$rc" || die "replicas-count '$rc' is not a positive integer"
done
for nc in "${NAMESPACE_COUNTS[@]}"; do
	is_pos_int "$nc" || die "namespace-count '$nc' is not a positive integer"
done

MATRIX_SIZE=$(( ${#MESH_SIZES[@]} * ${#SERVICE_COUNTS[@]} * ${#REPLICAS_COUNTS[@]} * ${#NAMESPACE_COUNTS[@]} ))

SCRIPT_DIR="${ROOT}/tests/controlplane"

echo "=========================================="
echo "  Control-Plane Resource Sweep"
echo "=========================================="
echo "Contexts:         ${CONTEXTS[*]}"
echo "Mesh sizes:       ${MESH_SIZES[*]}"
echo "Service counts:   ${SERVICE_COUNTS[*]}"
echo "Replicas counts:  ${REPLICAS_COUNTS[*]}"
echo "Namespace counts: ${NAMESPACE_COUNTS[*]}"
echo "Settle time:      ${SETTLE_SEC}s"
echo "Output:           $OUTPUT_DIR"
echo ""
echo "Planned matrix:   ${#MESH_SIZES[@]} × ${#SERVICE_COUNTS[@]} × ${#REPLICAS_COUNTS[@]} × ${#NAMESPACE_COUNTS[@]} = $MATRIX_SIZE combinations"
echo ""

if ((MATRIX_SIZE > MAX_MATRIX)) && ! ((FORCE_LARGE_MATRIX)); then
	die "matrix size $MATRIX_SIZE exceeds safety limit $MAX_MATRIX; re-run with --force-large-matrix to proceed"
fi

if ((DRY_RUN)); then
	echo "--- Combinations (dry-run) ---"
fi

combo_idx=0
for ms in "${MESH_SIZES[@]}"; do
	active_ctxs=("${CONTEXTS[@]:0:$ms}")
	active_csv=$(IFS=,; echo "${active_ctxs[*]}")
	for sc in "${SERVICE_COUNTS[@]}"; do
		for rc in "${REPLICAS_COUNTS[@]}"; do
			for nc in "${NAMESPACE_COUNTS[@]}"; do
				combo_idx=$((combo_idx + 1))
				label="mesh=$ms svcs=$sc reps=$rc ns=$nc"

				if ((DRY_RUN)); then
					printf "  [%2d/%2d] %s  (clusters: %s)\n" "$combo_idx" "$MATRIX_SIZE" "$label" "${active_ctxs[*]}"
					continue
				fi

				echo "=========================================="
				printf "  Sweep [%d/%d]: %s\n" "$combo_idx" "$MATRIX_SIZE" "$label"
				echo "  Clusters: ${active_ctxs[*]}"
				echo "=========================================="
				echo ""

				echo "--- Deploying workloads ---"
				"$SCRIPT_DIR/001-setup-controlplane-test.sh" \
					--contexts "$active_csv" \
					--service-count "$sc" \
					--replicas "$rc" \
					--namespace-count "$nc"
				echo ""

				echo "--- Settling for ${SETTLE_SEC}s ---"
				sleep "$SETTLE_SEC"

				echo "--- Collecting metrics ($label) ---"
				"$SCRIPT_DIR/002-collect-resource-metrics.sh" \
					--contexts "$active_csv" \
					--mesh-size "$ms" \
					--service-count "$sc" \
					--replicas "$rc" \
					--namespace-count "$nc" \
					--output-dir "$OUTPUT_DIR"
				echo ""

				echo "--- Cleaning up ---"
				"$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv"
				echo ""
			done
		done
	done
done

if ((DRY_RUN)); then
	echo ""
	echo "Dry-run complete. $combo_idx combinations enumerated; no clusters touched."
	exit 0
fi

echo "=========================================="
echo "  Sweep complete ($combo_idx combinations)"
echo "=========================================="
echo ""
echo "Generating report..."
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$OUTPUT_DIR"

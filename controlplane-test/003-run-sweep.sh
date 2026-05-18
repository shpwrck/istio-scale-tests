#!/usr/bin/env bash
# Orchestrate control-plane resource collection across multiple mesh sizes.
# For each mesh size, deploys dummy workloads, collects metrics, then cleans up.
#
# Usage:
#   ./controlplane-test/003-run-sweep.sh [--contexts CSV] [--mesh-sizes CSV] [options]
#
# Examples:
#   # Sweep 1, 2, 3 clusters with 10 services:
#   ./controlplane-test/003-run-sweep.sh --contexts rosa-001,rosa-002,rosa-003
#
#   # Custom service counts per sweep step:
#   ./controlplane-test/003-run-sweep.sh --mesh-sizes 1,2,3 --service-count 50
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
MESH_SIZES_CSV=""
SERVICE_COUNT="${CONTROLPLANE_SERVICE_COUNT:-10}"
REPLICAS="${CONTROLPLANE_REPLICAS_PER_SERVICE:-3}"
OUTPUT_DIR="${ROOT}/controlplane-test/results"
SETTLE_SEC=30
DRY_RUN=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV       All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV     Cluster counts to test (default: "1,2,...,len(contexts)").
  --service-count N    Dummy services per cluster (default: $SERVICE_COUNT).
  --replicas N         Replicas per service (default: $REPLICAS).
  --settle SEC         Seconds to wait after deploy before collecting (default: $SETTLE_SEC).
  --output-dir DIR     Results directory (default: controlplane-test/results).
  --dry-run            Show plan without executing.
  -h, --help           Show this help.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_SERVICE_COUNT, CONTROLPLANE_REPLICAS_PER_SERVICE.
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
	--service-count)
		[[ -n "${2:-}" ]] || die "--service-count requires a value"
		SERVICE_COUNT="$2"
		shift 2
		;;
	--replicas)
		[[ -n "${2:-}" ]] || die "--replicas requires a value"
		REPLICAS="$2"
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

SCRIPT_DIR="${ROOT}/controlplane-test"

echo "=========================================="
echo "  Control-Plane Resource Sweep"
echo "=========================================="
echo "Contexts: ${CONTEXTS[*]}"
echo "Mesh sizes: ${MESH_SIZES[*]}"
echo "Workload: ${SERVICE_COUNT} services × ${REPLICAS} replicas"
echo "Settle time: ${SETTLE_SEC}s"
echo "Output: $OUTPUT_DIR"
echo ""

for ms in "${MESH_SIZES[@]}"; do
	active_ctxs=("${CONTEXTS[@]:0:$ms}")
	active_csv=$(IFS=,; echo "${active_ctxs[*]}")

	echo "=========================================="
	echo "  Sweep: mesh_size=$ms"
	echo "  Clusters: ${active_ctxs[*]}"
	echo "=========================================="
	echo ""

	if ((DRY_RUN)); then
		echo "  [dry-run] Would run:"
		echo "    001-setup-controlplane-test.sh --contexts $active_csv --service-count $SERVICE_COUNT --replicas $REPLICAS"
		echo "    (settle ${SETTLE_SEC}s)"
		echo "    002-collect-resource-metrics.sh --contexts $active_csv --mesh-size $ms"
		echo "    005-cleanup.sh --contexts $active_csv"
		echo ""
		continue
	fi

	echo "--- Deploying workloads ---"
	"$SCRIPT_DIR/001-setup-controlplane-test.sh" \
		--contexts "$active_csv" \
		--service-count "$SERVICE_COUNT" \
		--replicas "$REPLICAS"
	echo ""

	echo "--- Settling for ${SETTLE_SEC}s ---"
	sleep "$SETTLE_SEC"

	echo "--- Collecting metrics (mesh_size=$ms) ---"
	"$SCRIPT_DIR/002-collect-resource-metrics.sh" \
		--contexts "$active_csv" \
		--mesh-size "$ms" \
		--service-count "$SERVICE_COUNT" \
		--replicas "$REPLICAS" \
		--output-dir "$OUTPUT_DIR"
	echo ""

	echo "--- Cleaning up ---"
	"$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv"
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

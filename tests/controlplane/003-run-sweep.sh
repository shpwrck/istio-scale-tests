#!/usr/bin/env bash
# Orchestrate control-plane resource collection across (mesh_size × sidecar_scoping).
# For each combination, deploys dummy workloads, collects metrics, then cleans up.
#
# Usage:
#   ./tests/controlplane/003-run-sweep.sh [--contexts CSV] [--mesh-sizes CSV] [options]
#
# Examples:
#   # Sweep mesh sizes 1,2,3 across all three scoping modes:
#   ./tests/controlplane/003-run-sweep.sh \
#     --contexts rosa-001,rosa-002,rosa-003 \
#     --mesh-sizes 1,2,3 \
#     --sidecar-scopings none,namespace,explicit
#
#   # Dry-run to see plan:
#   ./tests/controlplane/003-run-sweep.sh --dry-run \
#     --contexts a,b --sidecar-scopings none,namespace,explicit
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
MESH_SIZES_CSV=""
SIDECAR_SCOPINGS_CSV=""
SERVICE_COUNT="${CONTROLPLANE_SERVICE_COUNT:-10}"
REPLICAS="${CONTROLPLANE_REPLICAS_PER_SERVICE:-3}"
OUTPUT_DIR="${ROOT}/tests/controlplane/results"
CONFIG_DUMP_SAMPLES="${CONTROLPLANE_CONFIG_DUMP_SAMPLES:-3}"
SETTLE_SEC=30
MAX_COMBOS=64
DRY_RUN=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV               All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV             Cluster counts to test (default: "1,2,...,len(contexts)").
  --mesh-size N                Singular alias: a single mesh-size value.
  --sidecar-scopings CSV       Scoping modes to sweep: none,namespace,explicit
                               (default: \$CONTROLPLANE_SIDECAR_SCOPING or "none").
  --sidecar-scoping VALUE      Singular alias: a single scoping mode.
  --service-count N            Dummy services per cluster (default: $SERVICE_COUNT).
  --replicas N                 Replicas per service (default: $REPLICAS).
  --config-dump-samples N      Pods per cluster to exec /config_dump on (default: $CONFIG_DUMP_SAMPLES; 0 disables).
  --settle SEC                 Seconds to wait after deploy before collecting (default: $SETTLE_SEC).
  --output-dir DIR             Results directory (default: tests/controlplane/results).
  --max-combos N               Safety cap on matrix size (default: $MAX_COMBOS).
  --dry-run                    Show plan without executing.
  -h, --help                   Show this help.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_SERVICE_COUNT, CONTROLPLANE_REPLICAS_PER_SERVICE,
  CONTROLPLANE_SIDECAR_SCOPING, CONTROLPLANE_CONFIG_DUMP_SAMPLES.
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

validate_scoping_value() {
	case "$1" in
	none | namespace | explicit) return 0 ;;
	# F1: error wording matches 001/002 (`--sidecar-scoping must be one of …`).
	*) die "--sidecar-scoping must be one of [none, namespace, explicit]; got '$1'" ;;
	esac
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
		# PL7 singular alias.
		[[ -n "${2:-}" ]] || die "--mesh-size requires a value"
		echo "deprecated: prefer --mesh-sizes (CSV) on sweep scripts" >&2
		MESH_SIZES_CSV="$2"
		shift 2
		;;
	--sidecar-scopings)
		[[ -n "${2:-}" ]] || die "--sidecar-scopings requires a value"
		SIDECAR_SCOPINGS_CSV="$2"
		shift 2
		;;
	--sidecar-scoping)
		# PL7 singular alias.
		[[ -n "${2:-}" ]] || die "--sidecar-scoping requires a value"
		echo "deprecated: prefer --sidecar-scopings (CSV) on sweep scripts" >&2
		SIDECAR_SCOPINGS_CSV="$2"
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
	--config-dump-samples)
		[[ -n "${2:-}" ]] || die "--config-dump-samples requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--config-dump-samples must be a non-negative integer; got '$2'"
		CONFIG_DUMP_SAMPLES="$2"
		shift 2
		;;
	--settle)
		[[ -n "${2:-}" ]] || die "--settle requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--settle must be a non-negative integer; got '$2'"
		SETTLE_SEC="$2"
		shift 2
		;;
	--output-dir)
		[[ -n "${2:-}" ]] || die "--output-dir requires a value"
		OUTPUT_DIR="$2"
		shift 2
		;;
	--max-combos)
		[[ -n "${2:-}" ]] || die "--max-combos requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--max-combos must be a positive integer; got '$2'"
		MAX_COMBOS="$2"
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
	[[ "$ms" =~ ^[0-9]+$ ]] || die "mesh-size '$ms' is not a positive integer"
	((ms >= 1 && ms <= ${#CONTEXTS[@]})) || die "mesh-size $ms out of range (have ${#CONTEXTS[@]} contexts)"
done

SCOPINGS=()
if [[ -n "$SIDECAR_SCOPINGS_CSV" ]]; then
	split_csv "$SIDECAR_SCOPINGS_CSV" SCOPINGS
else
	SCOPINGS=("${CONTROLPLANE_SIDECAR_SCOPING:-none}")
fi
((${#SCOPINGS[@]})) || die "no sidecar-scopings resolved"
for s in "${SCOPINGS[@]}"; do
	validate_scoping_value "$s"
done

# PL10: matrix-size cap.
COMBOS=$(( ${#MESH_SIZES[@]} * ${#SCOPINGS[@]} ))
if (( COMBOS > MAX_COMBOS )); then
	die "planned matrix size ${COMBOS} exceeds --max-combos ${MAX_COMBOS} (axes: mesh_sizes=${#MESH_SIZES[@]} × sidecar_scopings=${#SCOPINGS[@]}); raise --max-combos or trim axes"
fi

# PL6: per-sweep RUN_ID + subdir.
RUN_ID="$(date +%Y%m%dT%H%M%S)-$$"
SWEEP_DIR="${OUTPUT_DIR}/sweep-${RUN_ID}"
mkdir -p "$SWEEP_DIR"

SCRIPT_DIR="${ROOT}/tests/controlplane"

# PL5 (D5): print planned matrix to stderr before starting.
{
	echo "=========================================="
	echo "  Control-Plane Resource Sweep (RUN_ID=${RUN_ID})"
	echo "=========================================="
	echo "Contexts:           ${CONTEXTS[*]}"
	echo "Mesh sizes (n=${#MESH_SIZES[@]}):    ${MESH_SIZES[*]}"
	echo "Sidecar scopings (n=${#SCOPINGS[@]}): ${SCOPINGS[*]}"
	echo "Planned combinations: ${COMBOS} (cap ${MAX_COMBOS})"
	echo "Workload:           ${SERVICE_COUNT} services × ${REPLICAS} replicas"
	echo "Settle time:        ${SETTLE_SEC}s (pre-baseline, baseline→final, AND post-cleanup)"
	echo "Config-dump samples: ${CONFIG_DUMP_SAMPLES}"
	echo "Output:             ${SWEEP_DIR}"
	echo ""
	echo "Planned matrix:"
	for ms in "${MESH_SIZES[@]}"; do
		for sc in "${SCOPINGS[@]}"; do
			echo "  - mesh_size=${ms}  sidecar_scoping=${sc}"
		done
	done
	echo ""
} >&2

for ms in "${MESH_SIZES[@]}"; do
	active_ctxs=("${CONTEXTS[@]:0:$ms}")
	active_csv=$(IFS=,; echo "${active_ctxs[*]}")
	for sc in "${SCOPINGS[@]}"; do
		echo "=========================================="
		echo "  Sweep: mesh_size=$ms  sidecar_scoping=$sc"
		echo "  Clusters: ${active_ctxs[*]}"
		echo "=========================================="
		echo ""

		if ((DRY_RUN)); then
			echo "  [dry-run] Would run:"
			echo "    001-setup-controlplane-test.sh --contexts $active_csv --service-count $SERVICE_COUNT --replicas $REPLICAS --sidecar-scoping $sc"
			echo "    (settle ${SETTLE_SEC}s)"
			echo "    002-collect-resource-metrics.sh --contexts $active_csv --mesh-size $ms --sidecar-scoping $sc --config-dump-samples $CONFIG_DUMP_SAMPLES --run-id $RUN_ID"
			echo "    005-cleanup.sh --contexts $active_csv"
			echo ""
			continue
		fi

		echo "--- Deploying workloads (sidecar_scoping=$sc) ---"
		"$SCRIPT_DIR/001-setup-controlplane-test.sh" \
			--contexts "$active_csv" \
			--service-count "$SERVICE_COUNT" \
			--replicas "$REPLICAS" \
			--sidecar-scoping "$sc"
		echo ""

		echo "--- Settling pre-baseline for ${SETTLE_SEC}s ---"
		sleep "$SETTLE_SEC"

		echo "--- Collecting metrics (mesh_size=$ms, scoping=$sc) ---"
		"$SCRIPT_DIR/002-collect-resource-metrics.sh" \
			--contexts "$active_csv" \
			--mesh-size "$ms" \
			--service-count "$SERVICE_COUNT" \
			--replicas "$REPLICAS" \
			--sidecar-scoping "$sc" \
			--config-dump-samples "$CONFIG_DUMP_SAMPLES" \
			--settle "$SETTLE_SEC" \
			--output-dir "$OUTPUT_DIR" \
			--run-id "$RUN_ID"
		echo ""

		echo "--- Cleaning up ---"
		"$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv"
		echo ""

		# D1: post-cleanup settle. When 005 deletes the test namespace, istiod
		# re-pushes a broader (no-Sidecar) config to remaining proxies. Without
		# this sleep, the next combo's baseline scrape lands inside that push
		# storm and corrupts the counter/quantile deltas. Use the same
		# SETTLE_SEC value as the baseline→final window so the system is at
		# rest before the next 001.
		echo "--- Settling post-cleanup (${SETTLE_SEC}s) ---" >&2
		sleep "$SETTLE_SEC"
	done
done

if ((DRY_RUN)); then
	echo "Dry-run complete."
	exit 0
fi

echo "=========================================="
echo "  Sweep complete (RUN_ID=${RUN_ID})"
echo "=========================================="
echo ""
echo "Generating report..."
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$SWEEP_DIR"

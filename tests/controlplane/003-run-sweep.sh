#!/usr/bin/env bash
# Orchestrate control-plane resource collection across the cross-product of
# five sweep axes: mesh size × service count × replicas × namespace count
# × sidecar scoping.
#
# For every combination, deploys dummy workloads, settles, scrapes istiod, and
# cleans up before moving on. Uses split-phase metrics so the deploy-time
# istiod push storm lands inside the measurement window.
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
#   # Cross-product mesh size with Sidecar scoping:
#   ./tests/controlplane/003-run-sweep.sh \
#     --contexts rosa-001,rosa-002,rosa-003 \
#     --mesh-sizes 1,2,3 --sidecar-scopings none,namespace,explicit
#
#   # Dry-run to see the planned matrix:
#   ./tests/controlplane/003-run-sweep.sh --dry-run \
#     --contexts a,b,c --service-counts 10,100 --sidecar-scopings none,namespace
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
MESH_SIZES_CSV=""
SERVICE_COUNTS_CSV="${CONTROLPLANE_SERVICE_COUNT:-10}"
REPLICA_COUNTS_CSV="${CONTROLPLANE_REPLICAS_PER_SERVICE:-3}"
NAMESPACE_COUNTS_CSV="${CONTROLPLANE_NAMESPACE_COUNT:-1}"
SIDECAR_SCOPINGS_CSV="${CONTROLPLANE_SIDECAR_SCOPING:-none}"
CONFIG_DUMP_SAMPLES="${CONTROLPLANE_CONFIG_DUMP_SAMPLES:-3}"
OUTPUT_DIR_BASE="${ROOT}/tests/controlplane/results"
SETTLE_SEC=60
DRY_RUN=0
FORCE_LARGE_MATRIX=0
MAX_MATRIX="${CONTROLPLANE_MAX_MATRIX:-64}"

NS="${CONTROLPLANE_TEST_NAMESPACE:-controlplane-test}"

die() { echo "error: $*" >&2; exit 1; }

is_pos_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
is_nonneg_int() { [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]; }

validate_scoping_value() {
	case "$1" in
	none | namespace | explicit) return 0 ;;
	*) die "--sidecar-scoping must be one of [none, namespace, explicit]; got '$1'" ;;
	esac
}

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Sweep dimensions (cross-product):
  --contexts CSV              All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV            Cluster counts (default: "1,2,...,len(contexts)").
  --service-counts CSV        Dummy services per cluster (default: $SERVICE_COUNTS_CSV).
  --replica-counts CSV        Replicas per service (default: $REPLICA_COUNTS_CSV).
  --namespace-counts CSV      Namespaces to spread services across (default: $NAMESPACE_COUNTS_CSV).
  --sidecar-scopings CSV      Sidecar CR scoping modes: none,namespace,explicit
                              (default: \$CONTROLPLANE_SIDECAR_SCOPING or "none").

Singular aliases (one CSV value each):
  --service-count N           Alias for --service-counts N.
  --replicas N                Alias for --replica-counts N.
  --replicas-counts CSV       Deprecated alias for --replica-counts.
  --namespace-count N         Alias for --namespace-counts N.
  --sidecar-scoping VALUE     Alias for --sidecar-scopings VALUE.

Other:
  --config-dump-samples N     Random pods per cluster to exec /config_dump on
                              (default: $CONFIG_DUMP_SAMPLES; 0 disables).
  --settle SEC                Seconds for the delta-window between baseline
                              and final scrape (default: $SETTLE_SEC).
  --output-dir DIR            Results base directory; each sweep gets a
                              sweep-<RUN_ID>/ subdir under it
                              (default: tests/controlplane/results).
  --force-large-matrix        Allow matrix > $MAX_MATRIX combinations (default: refuse).
  --dry-run                   Print plan and matrix, then exit.
  -h, --help                  Show this help.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_SERVICE_COUNT, CONTROLPLANE_REPLICAS_PER_SERVICE,
  CONTROLPLANE_NAMESPACE_COUNT, CONTROLPLANE_SIDECAR_SCOPING,
  CONTROLPLANE_CONFIG_DUMP_SAMPLES, CONTROLPLANE_MAX_MATRIX.
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
		[[ -n "${2:-}" ]] || die "--service-count requires a value"
		echo "warning: --service-count is deprecated; use --service-counts" >&2
		SERVICE_COUNTS_CSV="$2"
		shift 2
		;;
	--replica-counts)
		[[ -n "${2:-}" ]] || die "--replica-counts requires a value"
		REPLICA_COUNTS_CSV="$2"
		shift 2
		;;
	--replicas-counts)
		[[ -n "${2:-}" ]] || die "--replicas-counts requires a value"
		echo "warning: --replicas-counts is deprecated; use --replica-counts" >&2
		REPLICA_COUNTS_CSV="$2"
		shift 2
		;;
	--replicas)
		[[ -n "${2:-}" ]] || die "--replicas requires a value"
		echo "warning: --replicas is deprecated; use --replica-counts" >&2
		REPLICA_COUNTS_CSV="$2"
		shift 2
		;;
	--namespace-counts)
		[[ -n "${2:-}" ]] || die "--namespace-counts requires a value"
		NAMESPACE_COUNTS_CSV="$2"
		shift 2
		;;
	--namespace-count)
		[[ -n "${2:-}" ]] || die "--namespace-count requires a value"
		echo "warning: --namespace-count is deprecated; use --namespace-counts" >&2
		NAMESPACE_COUNTS_CSV="$2"
		shift 2
		;;
	--sidecar-scopings)
		[[ -n "${2:-}" ]] || die "--sidecar-scopings requires a value"
		SIDECAR_SCOPINGS_CSV="$2"
		shift 2
		;;
	--sidecar-scoping)
		[[ -n "${2:-}" ]] || die "--sidecar-scoping requires a value"
		echo "warning: --sidecar-scoping is deprecated; use --sidecar-scopings" >&2
		SIDECAR_SCOPINGS_CSV="$2"
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

SCOPINGS=()
split_csv "$SIDECAR_SCOPINGS_CSV" SCOPINGS
((${#SCOPINGS[@]})) || die "--sidecar-scopings produced an empty list"

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
for scp in "${SCOPINGS[@]}"; do
	validate_scoping_value "$scp"
done

MATRIX_SIZE=$(( ${#MESH_SIZES[@]} * ${#SERVICE_COUNTS[@]} * ${#REPLICA_COUNTS[@]} * ${#NAMESPACE_COUNTS[@]} * ${#SCOPINGS[@]} ))

SCRIPT_DIR="${ROOT}/tests/controlplane"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OUTPUT_DIR="${OUTPUT_DIR_BASE}/sweep-${RUN_ID}"

{
	echo "=========================================="
	echo "  Control-Plane Resource Sweep"
	echo "=========================================="
	echo "Contexts:          ${CONTEXTS[*]}"
	echo "Mesh sizes:        ${MESH_SIZES[*]}"
	echo "Service counts:    ${SERVICE_COUNTS[*]}"
	echo "Replica counts:    ${REPLICA_COUNTS[*]}"
	echo "Namespace counts:  ${NAMESPACE_COUNTS[*]}"
	echo "Sidecar scopings:  ${SCOPINGS[*]}"
	echo "Config-dump samples: ${CONFIG_DUMP_SAMPLES}"
	echo "Settle time:       ${SETTLE_SEC}s"
	echo "Run ID:            ${RUN_ID}"
	echo "Output:            ${OUTPUT_DIR}"
	echo ""
	echo "Planned matrix:    ${MATRIX_SIZE} = ${#MESH_SIZES[@]}×${#SERVICE_COUNTS[@]}×${#REPLICA_COUNTS[@]}×${#NAMESPACE_COUNTS[@]}×${#SCOPINGS[@]} (mesh × svc × rep × ns × scope)"
	echo ""
} >&2

if ((MATRIX_SIZE > MAX_MATRIX)) && ! ((FORCE_LARGE_MATRIX)); then
	die "matrix size $MATRIX_SIZE = ${#MESH_SIZES[@]}×${#SERVICE_COUNTS[@]}×${#REPLICA_COUNTS[@]}×${#NAMESPACE_COUNTS[@]}×${#SCOPINGS[@]} exceeds safety limit $MAX_MATRIX; re-run with --force-large-matrix to proceed"
fi

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

fmt_ns_pattern() {
	local nc="$1"
	if (( nc <= 1 )); then
		printf '%s\n' "$NS"
	else
		printf '%s-0..%s-%d\n' "$NS" "$NS" "$(( nc - 1 ))"
	fi
}

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
				for scp in "${SCOPINGS[@]}"; do
					combo_idx=$((combo_idx + 1))
					label="mesh=$ms svcs=$sc reps=$rc ns=$nc scope=$scp"
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
						--sidecar-scoping "$scp" \
						--settle "$SETTLE_SEC"
					echo ""

					echo "--- Deploying workloads (phase 2/3, scoping=$scp) ---"
					"$SCRIPT_DIR/001-setup-controlplane-test.sh" \
						--contexts "$active_csv" \
						--service-count "$sc" \
						--replicas "$rc" \
						--namespace-count "$nc" \
						--sidecar-scoping "$scp"
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
						--sidecar-scoping "$scp" \
						--config-dump-samples "$CONFIG_DUMP_SAMPLES" \
						--settle "$SETTLE_SEC" \
						--output-dir "$OUTPUT_DIR" \
						--run-id "$RUN_ID"
					rm -rf "$STATE_DIR_COMBO"
					echo ""

					echo "--- Cleaning up ---"
					"$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv"

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

					# Post-cleanup settle: when 005 deletes the test namespace,
					# istiod re-pushes a broader (no-Sidecar) config to remaining
					# proxies. Without this sleep, the next combo's baseline scrape
					# lands inside that push storm.
					if (( SETTLE_SEC > 0 )); then
						echo "--- Post-cleanup settle (${SETTLE_SEC}s) ---" >&2
						sleep "$SETTLE_SEC"
					fi
					echo ""
				done
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

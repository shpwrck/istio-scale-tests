#!/usr/bin/env bash
# Orchestrate data-plane latency probes across multiple mesh sizes.
#
# Usage:
#   ./dataplane-test/003-run-sweep.sh [--contexts CSV] [--mesh-sizes CSV] [options]
#
# Examples:
#   # Sweep 1, 2, 3 clusters:
#   ./dataplane-test/003-run-sweep.sh --contexts rosa-001,rosa-002,rosa-003
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
MESH_SIZES_CSV=""
QPS_LEVELS="${DATAPLANE_QPS_LEVELS:-10,100,500,1000}"
DURATION="${DATAPLANE_DURATION_SEC:-30}"
CONNECTIONS="${DATAPLANE_NUM_CONNECTIONS:-8}"
OUTPUT_DIR="${ROOT}/dataplane-test/results"
DRY_RUN=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV       All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV     Cluster counts to test (default: "1,2,...,len(contexts)").
  --qps-levels CSV     QPS levels to test (default: $QPS_LEVELS).
  --duration SEC       Duration per QPS level (default: $DURATION).
  --connections N      Concurrent connections (default: $CONNECTIONS).
  --output-dir DIR     Results directory (default: dataplane-test/results).
  --dry-run            Show plan without executing.
  -h, --help           Show this help.
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
	--qps-levels)
		[[ -n "${2:-}" ]] || die "--qps-levels requires a value"
		QPS_LEVELS="$2"
		shift 2
		;;
	--duration)
		[[ -n "${2:-}" ]] || die "--duration requires a value"
		DURATION="$2"
		shift 2
		;;
	--connections)
		[[ -n "${2:-}" ]] || die "--connections requires a value"
		CONNECTIONS="$2"
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

SCRIPT_DIR="${ROOT}/dataplane-test"

echo "=========================================="
echo "  Data-Plane Latency Sweep"
echo "=========================================="
echo "Contexts: ${CONTEXTS[*]}"
echo "Mesh sizes: ${MESH_SIZES[*]}"
echo "QPS levels: $QPS_LEVELS"
echo "Output: $OUTPUT_DIR"
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
	echo "  Source: $source_ctx  Remotes: ${remote_ctxs[*]:-none}"
	echo "=========================================="

	if ((DRY_RUN)); then
		echo "  [dry-run] Would run:"
		echo "    001-setup-dataplane-test.sh --source-context $source_ctx --remote-contexts $remote_csv"
		echo "    002-run-latency-probe.sh --source-context $source_ctx --remote-contexts $remote_csv --mesh-size $ms"
		echo "    005-cleanup.sh --contexts $(IFS=,; echo "${active_ctxs[*]}")"
		echo ""
		continue
	fi

	echo "--- Setting up ---"
	setup_args=(--source-context "$source_ctx")
	[[ -n "$remote_csv" ]] && setup_args+=(--remote-contexts "$remote_csv")
	"$SCRIPT_DIR/001-setup-dataplane-test.sh" "${setup_args[@]}"
	echo ""

	echo "--- Running latency probe (mesh_size=$ms) ---"
	probe_args=(
		--source-context "$source_ctx"
		--mesh-size "$ms"
		--qps-levels "$QPS_LEVELS"
		--duration "$DURATION"
		--connections "$CONNECTIONS"
		--output-dir "$OUTPUT_DIR"
	)
	[[ -n "$remote_csv" ]] && probe_args+=(--remote-contexts "$remote_csv")
	"$SCRIPT_DIR/002-run-latency-probe.sh" "${probe_args[@]}"
	echo ""

	echo "--- Cleaning up ---"
	"$SCRIPT_DIR/005-cleanup.sh" --contexts "$(IFS=,; echo "${active_ctxs[*]}")"
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

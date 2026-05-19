#!/usr/bin/env bash
# Clean up all propagation-test resources from target clusters.
# Removes canary deployments, Istio config (VirtualService/DestinationRule),
# watcher pods, and the propagation-test namespace.
#
# Safe to run at any time — all deletes use --ignore-not-found.
#
# Usage:
#   ./tests/propagation/007-cleanup.sh [--contexts CSV] [--dry-run]
#
# Examples:
#   # Clean up all default clusters:
#   ./tests/propagation/007-cleanup.sh
#
#   # Clean up specific clusters:
#   ./tests/propagation/007-cleanup.sh --contexts istio-002,istio-003
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
DRY_RUN=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV   Kube contexts to clean up (default: \$SETUP_CONTEXTS).
  --dry-run        Show what would be deleted without deleting.
  -h, --help       Show this help.

Environment:
  SETUP_CONTEXTS, PROPAGATION_TEST_NAMESPACE.
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

if command -v oc >/dev/null 2>&1; then
	KUBECTL=(oc)
elif command -v kubectl >/dev/null 2>&1; then
	KUBECTL=(kubectl)
else
	die "neither oc nor kubectl found on PATH"
fi

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_csv "$CONTEXTS_CSV" CONTEXTS
else
	split_csv "$SETUP_CONTEXTS" CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

NS="${PROPAGATION_TEST_NAMESPACE}"

run_delete() {
	if ((DRY_RUN)); then
		echo "  [dry-run] $*"
	else
		"$@" 2>/dev/null || true
	fi
}

cleanup_context() {
	local ctx="$1"
	echo "--- Cleaning up context: $ctx ---"

	if ! "${KUBECTL[@]}" --context="$ctx" get namespace "$NS" >/dev/null 2>&1; then
		echo "  [$ctx] Namespace $NS does not exist, skipping."
		return 0
	fi

	echo "  [$ctx] Removing canary resources..."
	run_delete "${KUBECTL[@]}" --context="$ctx" -n "$NS" delete virtualservice/propagation-canary --ignore-not-found=true
	run_delete "${KUBECTL[@]}" --context="$ctx" -n "$NS" delete destinationrule/propagation-canary --ignore-not-found=true
	run_delete "${KUBECTL[@]}" --context="$ctx" -n "$NS" delete deploy/propagation-canary --ignore-not-found=true
	run_delete "${KUBECTL[@]}" --context="$ctx" -n "$NS" delete svc/propagation-canary --ignore-not-found=true

	echo "  [$ctx] Removing watcher resources..."
	run_delete "${KUBECTL[@]}" --context="$ctx" -n "$NS" delete deploy/propagation-watcher --ignore-not-found=true
	run_delete "${KUBECTL[@]}" --context="$ctx" -n "$NS" delete svc/propagation-watcher --ignore-not-found=true

	echo "  [$ctx] Deleting namespace $NS..."
	run_delete "${KUBECTL[@]}" --context="$ctx" delete namespace "$NS" --ignore-not-found=true
	echo "  [$ctx] Done."
}

echo "=== Propagation test cleanup ==="
echo "Contexts: ${CONTEXTS[*]}"
echo "Namespace: $NS"
((DRY_RUN)) && echo "Mode: dry-run"
echo ""

PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	cleanup_context "$ctx" &
	PIDS+=($!)
done

FAILED=0
for pid in "${PIDS[@]}"; do
	wait "$pid" || FAILED=$((FAILED + 1))
done

echo ""
if ((FAILED > 0)); then
	echo "Cleanup finished with $FAILED failed context(s)."
	exit 1
fi
echo "Cleanup complete."

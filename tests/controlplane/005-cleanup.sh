#!/usr/bin/env bash
# Clean up all controlplane-test resources from target clusters.
#
# Usage:
#   ./tests/controlplane/005-cleanup.sh [--contexts CSV] [--dry-run]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
DRY_RUN=0
NS="${CONTROLPLANE_TEST_NAMESPACE:-controlplane-test}"

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV   Kube contexts to clean up (default: \$SETUP_CONTEXTS).
  --dry-run        Show what would be deleted without deleting.
  -h, --help       Show this help.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_TEST_NAMESPACE.
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

run_delete() {
	if ((DRY_RUN)); then
		echo "  [dry-run] $*"
	else
		"$@" 2>/dev/null || true
	fi
}

echo "=== Control-plane test cleanup ==="
echo "Contexts: ${CONTEXTS[*]}"
echo "Namespace: $NS"
((DRY_RUN)) && echo "Mode: dry-run"
echo ""

PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	(
		echo "--- Cleaning up context: $ctx ---"
		if ! "${KUBECTL[@]}" --context="$ctx" get namespace "$NS" >/dev/null 2>&1; then
			echo "  [$ctx] Namespace $NS does not exist, skipping."
			exit 0
		fi
		run_delete "${KUBECTL[@]}" --context="$ctx" delete namespace "$NS" --ignore-not-found=true
		echo "  [$ctx] Done."
	) &
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

#!/usr/bin/env bash
# Deploy propagation-test namespace and watcher pods on target clusters.
#
# Usage:
#   ./tests/propagation/001-setup-propagation-test.sh [--contexts CSV] [--dry-run] [--cleanup]
#
# Examples:
#   # Setup on all default clusters:
#   ./tests/propagation/001-setup-propagation-test.sh
#
#   # Setup on specific clusters:
#   ./tests/propagation/001-setup-propagation-test.sh --contexts rosa-001,rosa-002
#
#   # Tear down from all clusters:
#   ./tests/propagation/001-setup-propagation-test.sh --cleanup
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
DRY_RUN=0
CLEANUP=0
WAIT_TIMEOUT=300

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV   Kube contexts to target (default: \$SETUP_CONTEXTS).
  --dry-run        Pass --dry-run=client to oc apply.
  --cleanup        Remove propagation-test namespace from all contexts.
  --wait-timeout N Seconds to wait for watcher pods (default: 300).
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
	--cleanup)
		CLEANUP=1
		shift
		;;
	--wait-timeout)
		[[ -n "${2:-}" ]] || die "--wait-timeout requires a value"
		WAIT_TIMEOUT="$2"
		shift 2
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

if ((CLEANUP)); then
	for ctx in "${CONTEXTS[@]}"; do
		echo "Cleaning up namespace $NS on context $ctx"
		if ((DRY_RUN)); then
			"${KUBECTL[@]}" --context="$ctx" delete namespace "$NS" --dry-run=client 2>/dev/null || true
		else
			"${KUBECTL[@]}" --context="$ctx" delete namespace "$NS" --ignore-not-found=true
		fi
	done
	echo "Cleanup complete."
	exit 0
fi

command -v helm >/dev/null 2>&1 || die "helm not found on PATH"

apply=("${KUBECTL[@]}" apply --server-side --force-conflicts)
((DRY_RUN)) && apply=("${KUBECTL[@]}" apply --dry-run=client)

CHART_DIR="${ROOT}/tests/propagation/chart"

for ctx in "${CONTEXTS[@]}"; do
	echo "Setting up propagation-test on context $ctx"
	helm template propagation-test "$CHART_DIR" \
		--set clusterName="$ctx" \
		--set namespace="$NS" \
		--set canary.enabled=false \
		| "${apply[@]}" --context="$ctx" -f -
done

if ((DRY_RUN)); then
	echo "Dry-run complete."
	exit 0
fi

echo "Waiting for watcher pods to be ready (timeout: ${WAIT_TIMEOUT}s)..."
for ctx in "${CONTEXTS[@]}"; do
	echo "  Waiting on context $ctx..."
	"${KUBECTL[@]}" --context="$ctx" -n "$NS" wait deployment/propagation-watcher \
		--for=condition=Available --timeout="${WAIT_TIMEOUT}s" || die "watcher not ready on $ctx"
	echo "  Watcher ready on $ctx."
done

echo "Setup complete. Watcher pods running on: ${CONTEXTS[*]}"

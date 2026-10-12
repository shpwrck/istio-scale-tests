#!/usr/bin/env bash
# Tear down the shared churn-dataplane-test namespace on every active context.
# By default issues an asynchronous delete; with --wait-deletion blocks until
# the namespace is fully gone, up to --timeout seconds.
#
# Usage:
#   ./tests/churn-dataplane/006-cleanup.sh [--contexts CSV] [--wait-deletion] [--timeout SEC] [--dry-run]
# ci-dry-run: --contexts ci-dummy
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"

CONTEXTS_CSV=""
DRY_RUN=0
WAIT_DELETION=0
TIMEOUT_SEC="${COEXEC_NS_DELETE_TIMEOUT_SEC:-240}"
NS="${COEXEC_TEST_NAMESPACE:-churn-dataplane-test}"
# Delete the sidecar-injected pods with a short grace period before the namespace,
# so istio-proxy drain does not dominate teardown. Keep it > 0 (0 would SIGKILL).
FAST_DRAIN_GRACE_SEC="${COEXEC_CLEANUP_GRACE_SEC:-5}"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV     Kube contexts to clean up (default: \$SETUP_CONTEXTS).
  --wait-deletion    Block until the namespace is fully removed on every context.
  --timeout SEC      Maximum seconds to wait for deletion (default: $TIMEOUT_SEC).
  --grace-period SEC Pod-delete grace period for the pre-delete fast-drain of
                     sidecar-injected workloads (default: $FAST_DRAIN_GRACE_SEC).
  --dry-run          Show what would be deleted; do not touch clusters.
  -h, --help         Show this help.

Environment:
  SETUP_CONTEXTS, COEXEC_TEST_NAMESPACE, COEXEC_NS_DELETE_TIMEOUT_SEC,
  COEXEC_CLEANUP_GRACE_SEC (pre-delete pod fast-drain grace period; default 5).
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"; shift 2 ;;
	--wait-deletion)
		WAIT_DELETION=1; shift ;;
	--timeout)
		[[ -n "${2:-}" ]] || die "--timeout requires a value"
		TIMEOUT_SEC="$2"; shift 2 ;;
	--grace-period)
		[[ -n "${2:-}" ]] || die "--grace-period requires a value"
		FAST_DRAIN_GRACE_SEC="$2"; shift 2 ;;
	--dry-run)
		DRY_RUN=1; shift ;;
	-h | --help)
		usage; exit 0 ;;
	*)
		die "unknown option: $1 (try --help)" ;;
	esac
done

KUBECTL=()
resolve_kubectl KUBECTL

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_csv "$CONTEXTS_CSV" CONTEXTS
else
	split_csv "$SETUP_CONTEXTS" CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

echo "=== churn-dataplane cleanup ==="
echo "Contexts:    ${CONTEXTS[*]}"
echo "Namespace:   $NS"
echo "Wait:        $WAIT_DELETION (timeout ${TIMEOUT_SEC}s)"
echo "Fast-drain:  pods grace ${FAST_DRAIN_GRACE_SEC}s before namespace delete"
((DRY_RUN)) && echo "Mode:        dry-run"

clean_one() {
	local ctx="$1"
	if ((DRY_RUN)); then
		echo "  [$ctx] [dry-run] delete pods --all --grace-period=${FAST_DRAIN_GRACE_SEC} (fast-drain), then delete namespace/$NS"
		return 0
	fi
	if ! "${KUBECTL[@]}" --context="$ctx" get namespace "$NS" >/dev/null 2>&1; then
		echo "  [$ctx] namespace $NS does not exist, skipping."
		return 0
	fi
	# Best-effort fast drain; the namespace delete (and wait) below is authoritative.
	echo "  [$ctx] fast-draining workload pods (grace ${FAST_DRAIN_GRACE_SEC}s) before namespace delete..."
	"${KUBECTL[@]}" --context="$ctx" -n "$NS" delete pods --all \
		--grace-period="$FAST_DRAIN_GRACE_SEC" --wait=false >/dev/null 2>&1 || true
	"${KUBECTL[@]}" --context="$ctx" delete namespace "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
	if ! ((WAIT_DELETION)); then
		echo "  [$ctx] delete issued (async)."
		return 0
	fi
	# Wait for the namespace to fully disappear.
	local deadline now
	deadline=$(( $(date +%s) + TIMEOUT_SEC ))
	while "${KUBECTL[@]}" --context="$ctx" get namespace "$NS" >/dev/null 2>&1; do
		now=$(date +%s)
		if (( now > deadline )); then
			echo "  [$ctx] timeout waiting for namespace $NS to delete (>${TIMEOUT_SEC}s)" >&2
			return 1
		fi
		sleep 2
	done
	echo "  [$ctx] namespace $NS fully deleted."
	return 0
}

PIDS=()
RC=()
for ctx in "${CONTEXTS[@]}"; do
	clean_one "$ctx" &
	PIDS+=($!)
done

FAILED=0
for pid in "${PIDS[@]}"; do
	if ! wait "$pid"; then
		RC+=("$pid")
		FAILED=$((FAILED + 1))
	fi
done

if (( FAILED > 0 )); then
	echo "Cleanup finished with $FAILED failed context(s)." >&2
	exit 1
fi
echo "Cleanup complete."

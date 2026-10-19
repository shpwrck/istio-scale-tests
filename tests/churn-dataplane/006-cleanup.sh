#!/usr/bin/env bash
# Tear down the shared churn-dataplane-test namespace on every active context.
# By default issues an asynchronous delete; with --wait-deletion blocks until
# the namespace is fully gone, up to --timeout seconds.
#
# Usage:
#   ./tests/churn-dataplane/006-cleanup.sh [--config FILE] [--contexts CSV] [--wait-deletion] [--timeout SEC] [--dry-run]
# ci-dry-run: --contexts ci-dummy
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
config_preload churn-dataplane "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/platform.sh"  # platform_validate (TEST_PLATFORM)

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

  --config FILE      Run config of KEY=value lines (config/options.env keys; see
                     tests/churn-dataplane/README.md, "Run config"). Precedence: flag >
                     --config > environment > default.
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
	--config)
		# Loaded by config_preload above.
		[[ -n "${2:-}" ]] || die "--config requires a value"
		shift 2 ;;
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

platform_validate
is_pos_int "$TIMEOUT_SEC" || die "--timeout must be a positive integer"
is_pos_int "$FAST_DRAIN_GRACE_SEC" || die "--grace-period must be a positive integer (0 would SIGKILL)"

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
		echo "  [$ctx] [dry-run] scale deployments to 0, delete pods --all --grace-period=${FAST_DRAIN_GRACE_SEC} (fast-drain), then delete namespace/$NS"
		return 0
	fi
	# --ignore-not-found: a missing namespace is empty output; an unreachable
	# context is an error, not "already clean".
	local found start
	if ! found=$("${KUBECTL[@]}" --context="$ctx" get namespace "$NS" --ignore-not-found -o name); then
		echo "  [$ctx] error: could not query namespace $NS" >&2
		return 1
	fi
	if [[ -z "$found" ]]; then
		echo "  [$ctx] namespace $NS does not exist, skipping."
		return 0
	fi
	start=$(date +%s)
	# Best-effort fast drain; the namespace delete (and wait) below is authoritative.
	# Scale to 0 first so the ReplicaSets do not recreate the deleted pods.
	echo "  [$ctx] fast-draining workload pods (grace ${FAST_DRAIN_GRACE_SEC}s) before namespace delete..."
	"${KUBECTL[@]}" --context="$ctx" -n "$NS" scale deployment --all --replicas=0 >/dev/null 2>&1 || true
	"${KUBECTL[@]}" --context="$ctx" -n "$NS" delete pods --all \
		--grace-period="$FAST_DRAIN_GRACE_SEC" --wait=false >/dev/null 2>&1 || true
	if ((WAIT_DELETION)); then
		# Let the pods go first: pods left when the namespace controller runs make it
		# back off, and the empty namespace then lingers for tens of seconds.
		"${KUBECTL[@]}" --context="$ctx" -n "$NS" wait --for=delete pods --all \
			--timeout="${TIMEOUT_SEC}s" >/dev/null 2>&1 || true
		echo "  [$ctx] pods drained after $(( $(date +%s) - start ))s; deleting namespace..."
	fi
	"${KUBECTL[@]}" --context="$ctx" delete namespace "$NS" --ignore-not-found=true --wait=false >/dev/null \
		|| { echo "  [$ctx] error: could not delete namespace $NS" >&2; return 1; }
	if ! ((WAIT_DELETION)); then
		echo "  [$ctx] delete issued (async)."
		return 0
	fi
	# Wait for the namespace to fully disappear. A failed query is retried until
	# the deadline rather than read as "gone".
	local deadline=$(( start + TIMEOUT_SEC ))
	while :; do
		if found=$("${KUBECTL[@]}" --context="$ctx" get namespace "$NS" --ignore-not-found -o name 2>/dev/null) \
			&& [[ -z "$found" ]]; then
			break
		fi
		if (( $(date +%s) > deadline )); then
			echo "  [$ctx] timeout waiting for namespace $NS to delete (>${TIMEOUT_SEC}s)" >&2
			return 1
		fi
		sleep 2
	done
	echo "  [$ctx] namespace $NS fully deleted in $(( $(date +%s) - start ))s."
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

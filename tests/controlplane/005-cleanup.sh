#!/usr/bin/env bash
# Clean up all controlplane-test resources from target clusters.
#
# Deletes every namespace labelled app.kubernetes.io/instance=controlplane-test
# (the chart labels each namespace it creates, single or multi-namespace), plus
# the plain $CONTROLPLANE_TEST_NAMESPACE if present, then waits (bounded) for
# them to finish terminating.
#
# Usage:
#   ./tests/controlplane/005-cleanup.sh [--contexts CSV] [--dry-run]
# ci-dry-run: --contexts ci-dummy
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"

CONTEXTS_CSV=""
DRY_RUN=0
NS="${CONTROLPLANE_TEST_NAMESPACE:-controlplane-test}"
LABEL_SELECTOR="app.kubernetes.io/instance=controlplane-test"
# Short grace period for deleting the workload pods first, so istio-proxy drain
# does not stretch the namespace teardown at scale.
FAST_DRAIN_GRACE_SEC="${CONTROLPLANE_CLEANUP_GRACE_SEC:-5}"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV     Kube contexts to clean up (default: \$SETUP_CONTEXTS).
  --grace-period SEC Grace period for deleting the workload pods before the
                     namespace delete (default: $FAST_DRAIN_GRACE_SEC).
  --dry-run          Print the delete commands without contacting any cluster.
  -h, --help         Show this help.

Behavior:
  Deletes the workload pods with a short grace period, then every namespace
  labelled '${LABEL_SELECTOR}' plus '\$CONTROLPLANE_TEST_NAMESPACE' (default
  'controlplane-test'), and waits up to CONTROLPLANE_NS_DELETE_TIMEOUT_SEC for
  them to disappear. A context that times out or cannot be reached fails.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_TEST_NAMESPACE, CONTROLPLANE_NS_DELETE_TIMEOUT_SEC
  (default 300), CONTROLPLANE_CLEANUP_GRACE_SEC (default 5).
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"
		shift 2
		;;
	--grace-period)
		[[ -n "${2:-}" ]] || die "--grace-period requires a value"
		FAST_DRAIN_GRACE_SEC="$2"
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

KUBECTL=()
resolve_kubectl KUBECTL

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_csv "$CONTEXTS_CSV" CONTEXTS
else
	split_csv "$SETUP_CONTEXTS" CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

# Same bound 001 uses for its pre-apply namespace wait.
TERMINATION_TIMEOUT="${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300}"
is_pos_int "$TERMINATION_TIMEOUT" || die "CONTROLPLANE_NS_DELETE_TIMEOUT_SEC must be a positive integer (got: $TERMINATION_TIMEOUT)"
# kubectl allows --grace-period=0 only with --force, so require >= 1.
is_pos_int "$FAST_DRAIN_GRACE_SEC" || die "--grace-period / CONTROLPLANE_CLEANUP_GRACE_SEC must be a positive integer (got: $FAST_DRAIN_GRACE_SEC)"

echo "=== Control-plane test cleanup ==="
echo "Contexts:        ${CONTEXTS[*]}"
echo "Label selector:  $LABEL_SELECTOR"
echo "Namespace:       $NS"
echo "Pod grace:       ${FAST_DRAIN_GRACE_SEC}s"
((DRY_RUN)) && echo "Mode:            dry-run"
echo ""

if ((DRY_RUN)); then
	for ctx in "${CONTEXTS[@]}"; do
		echo "  [dry-run] ${KUBECTL[*]} --context=$ctx delete pods -A -l $LABEL_SELECTOR --grace-period=$FAST_DRAIN_GRACE_SEC --wait=false"
		echo "  [dry-run] ${KUBECTL[*]} --context=$ctx delete namespace -l $LABEL_SELECTOR --wait=false"
		echo "  [dry-run] ${KUBECTL[*]} --context=$ctx delete namespace $NS --ignore-not-found=true --wait=false"
		echo "  [dry-run] wait up to ${TERMINATION_TIMEOUT}s for those namespaces to disappear"
		echo "  [dry-run] warn on any Sidecar, VirtualService or DestinationRule still labelled $LABEL_SELECTOR"
	done
	exit 0
fi

# 0 when no labelled namespace and no $NS remain; 1 on timeout.
wait_ns_terminated() {
	local ctx="$1" waited=0 left
	while :; do
		left=$("${KUBECTL[@]}" --context="$ctx" get ns -l "$LABEL_SELECTOR" -o name 2>/dev/null || true)
		if [[ "$left" != *"namespace/$NS"* ]] && "${KUBECTL[@]}" --context="$ctx" get ns "$NS" -o name >/dev/null 2>&1; then
			left+=" namespace/$NS"
		fi
		[[ -z "${left// /}" ]] && return 0
		if (( waited >= TERMINATION_TIMEOUT )); then
			echo "  [$ctx] namespace termination timeout after ${TERMINATION_TIMEOUT}s: ${left//$'\n'/ }" >&2
			return 1
		fi
		sleep 2
		waited=$(( waited + 2 ))
	done
}

PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	(
		set -e
		echo "--- Cleaning up context: $ctx ---"
		# Reachability check: a failed get means the context is unusable.
		matches=$("${KUBECTL[@]}" --context="$ctx" get namespace -l "$LABEL_SELECTOR" -o name) \
			|| { echo "  [$ctx] error: cannot list namespaces" >&2; exit 1; }
		if [[ -n "$matches" ]]; then
			echo "  [$ctx] Labelled namespaces: ${matches//$'\n'/ }"
			# Best-effort fast pod drain; the namespace delete below is authoritative.
			"${KUBECTL[@]}" --context="$ctx" delete pods -A -l "$LABEL_SELECTOR" \
				--grace-period="$FAST_DRAIN_GRACE_SEC" --wait=false >/dev/null 2>&1 || true
			# shellcheck disable=SC2086
			"${KUBECTL[@]}" --context="$ctx" delete $matches --ignore-not-found=true --wait=false
		else
			echo "  [$ctx] No labelled namespaces found."
		fi
		# The plain namespace, only if the labelled delete did not already cover it.
		if [[ $'\n'"$matches"$'\n' != *$'\n'"namespace/$NS"$'\n'* ]]; then
			"${KUBECTL[@]}" --context="$ctx" delete namespace "$NS" --ignore-not-found=true --wait=false
		fi

		echo "  [$ctx] Waiting for namespace termination (timeout ${TERMINATION_TIMEOUT}s)..."
		wait_ns_terminated "$ctx"
		# Sidecar CRs are namespaced; warn if any survived outside the deleted namespaces.
		sc_left=$("${KUBECTL[@]}" --context="$ctx" get sidecars.networking.istio.io \
			-A -l "$LABEL_SELECTOR" --no-headers --ignore-not-found 2>/dev/null | wc -l | tr -d ' ')
		[[ -z "$sc_left" ]] && sc_left=0
		if (( sc_left > 0 )); then
			echo "  [$ctx] WARNING: ${sc_left} Sidecar CR(s) still present" >&2
		fi
		# Same for the --traffic-config vsdr VirtualServices/DestinationRules.
		vsdr_left=$("${KUBECTL[@]}" --context="$ctx" get \
			virtualservices.networking.istio.io,destinationrules.networking.istio.io \
			-A -l "$LABEL_SELECTOR" --no-headers --ignore-not-found 2>/dev/null | wc -l | tr -d ' ')
		[[ -z "$vsdr_left" ]] && vsdr_left=0
		if (( vsdr_left > 0 )); then
			echo "  [$ctx] WARNING: ${vsdr_left} VirtualService/DestinationRule(s) still present" >&2
		fi
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

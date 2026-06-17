#!/usr/bin/env bash
# Clean up all controlplane-test resources from target clusters.
#
# Approach: delete every namespace carrying the chart's instance label,
# `app.kubernetes.io/instance=controlplane-test`. The chart stamps that label
# on every namespace it creates (single or multi-namespace mode), so a single
# label-selector delete covers both the legacy `controlplane-test` namespace
# and all `${NS}-N` sweep namespaces in one call — robust against partially
# completed setup runs and against namespaceCount drift between sweep steps.
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
# P1-2 fast-drain: pre-delete the sidecar-injected workload pods with a SHORT
# grace period BEFORE deleting the namespace, so at 10k pods the istio-proxy drain
# doesn't serialize the namespace teardown past CONTROLPLANE_NS_DELETE_TIMEOUT_SEC
# and cascade into the next combo's SETUP_FAILED (PL37). Ported from
# churn-dataplane 006 (COEXEC_CLEANUP_GRACE_SEC). Best-effort speedup; the
# label-selector namespace delete + termination wait stay authoritative.
FAST_DRAIN_GRACE_SEC="${CONTROLPLANE_CLEANUP_GRACE_SEC:-5}"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV     Kube contexts to clean up (default: \$SETUP_CONTEXTS).
  --grace-period SEC Pod-delete grace period for the pre-delete fast-drain of
                     sidecar-injected workloads (default: $FAST_DRAIN_GRACE_SEC).
  --dry-run          Show what would be deleted without deleting.
  -h, --help         Show this help.

Behavior:
  Fast-drains the labelled workload pods with a short grace period (P1-2) so
  istio-proxy drain doesn't dominate the teardown at scale, then deletes every
  namespace labelled '${LABEL_SELECTOR}' on each context, plus the legacy single
  namespace '\$CONTROLPLANE_TEST_NAMESPACE' (default 'controlplane-test') if it
  lacks the label, and waits out async termination (PL4/PL37).

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_TEST_NAMESPACE, CONTROLPLANE_NS_DELETE_TIMEOUT_SEC,
  CONTROLPLANE_CLEANUP_GRACE_SEC (pre-delete pod fast-drain grace; default 5).
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

# P1-1: resolve_kubectl appends --qps/--burst (KUBE_CLIENT_QPS/BURST) to every call.
KUBECTL=()
resolve_kubectl KUBECTL

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_csv "$CONTEXTS_CSV" CONTEXTS
else
	split_csv "$SETUP_CONTEXTS" CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

# PL37 contract: same bound 001 reuses for its pre-apply poll-until-gone wait
# (CONTROLPLANE_SETUP_NS_WAIT_SEC defaults from this), so an operator override
# applies symmetrically to cleanup and the next setup.
TERMINATION_TIMEOUT="${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300}"
is_pos_int "$TERMINATION_TIMEOUT" || die "CONTROLPLANE_NS_DELETE_TIMEOUT_SEC must be a positive integer (got: $TERMINATION_TIMEOUT)"
is_nonneg_int "$FAST_DRAIN_GRACE_SEC" || die "--grace-period / CONTROLPLANE_CLEANUP_GRACE_SEC must be a non-negative integer (got: $FAST_DRAIN_GRACE_SEC)"

run_delete() {
	if ((DRY_RUN)); then
		echo "  [dry-run] $*"
		return 0
	fi
	"$@"
}

wait_ns_terminated() {
	local ctx="$1"
	local waited=0
	while "${KUBECTL[@]}" --context="$ctx" get ns \
			-l "$LABEL_SELECTOR" -o name 2>/dev/null | grep -q .; do
		sleep 2
		waited=$(( waited + 2 ))
		if (( waited >= TERMINATION_TIMEOUT )); then
			echo "  [$ctx] namespace termination timeout after ${TERMINATION_TIMEOUT}s" >&2
			return 1
		fi
	done
	return 0
}

echo "=== Control-plane test cleanup ==="
echo "Contexts:        ${CONTEXTS[*]}"
echo "Label selector:  $LABEL_SELECTOR"
echo "Legacy fallback: $NS"
echo "Fast-drain:      pods grace ${FAST_DRAIN_GRACE_SEC}s before namespace delete"
((DRY_RUN)) && echo "Mode:            dry-run"
echo ""

# P1-2 fast-drain (ported from churn-dataplane 006): pre-delete the sidecar-
# injected workload pods in a namespace with a SHORT grace period so the
# istio-proxy drain doesn't dominate the subsequent namespace-delete window.
# Best-effort (|| true): if there are no pods, or the delete races the namespace
# delete, we still fall through to the authoritative namespace delete + PL4 wait.
# --wait=false so we don't block on per-pod termination here (the namespace
# termination wait below is the real gate).
fast_drain_ns() {
	local ctx="$1" ns="$2"
	if ((DRY_RUN)); then
		echo "  [$ctx] [dry-run] delete pods -n $ns --all --grace-period=${FAST_DRAIN_GRACE_SEC} (fast-drain)"
		return 0
	fi
	"${KUBECTL[@]}" --context="$ctx" -n "$ns" delete pods --all \
		--grace-period="$FAST_DRAIN_GRACE_SEC" --wait=false >/dev/null 2>&1 || true
}

PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	(
		set -e
		echo "--- Cleaning up context: $ctx ---"
		matches=$("${KUBECTL[@]}" --context="$ctx" get namespace \
			-l "$LABEL_SELECTOR" \
			-o name 2>/dev/null || true)
		if [[ -n "$matches" ]]; then
			echo "  [$ctx] Labelled namespaces:"
			# shellcheck disable=SC2086
			printf '    %s\n' $matches
			# P1-2: fast-drain each labelled namespace's pods (short grace) BEFORE
			# the namespace delete so istio-proxy drain doesn't dominate teardown.
			# shellcheck disable=SC2086
			for m in $matches; do
				fast_drain_ns "$ctx" "${m#namespace/}"
			done
			# shellcheck disable=SC2086
			run_delete "${KUBECTL[@]}" --context="$ctx" delete $matches --ignore-not-found=true
		else
			echo "  [$ctx] No labelled namespaces found."
		fi

		# Fallback: legacy single namespace from a pre-label deployment.
		if "${KUBECTL[@]}" --context="$ctx" get namespace "$NS" >/dev/null 2>&1; then
			echo "  [$ctx] Removing legacy namespace $NS (no chart label)."
			fast_drain_ns "$ctx" "$NS"
			run_delete "${KUBECTL[@]}" --context="$ctx" delete namespace "$NS" --ignore-not-found=true
		fi

		if ! ((DRY_RUN)); then
			echo "  [$ctx] Waiting for namespace termination (timeout ${TERMINATION_TIMEOUT}s)..."
			wait_ns_terminated "$ctx"
			# Sidecar CRs are namespace-scoped and go away with the namespace.
			# Confirm none leaked in a still-existing namespace.
			sc_left=$("${KUBECTL[@]}" --context="$ctx" get sidecars.networking.istio.io \
				-A -l "$LABEL_SELECTOR" --no-headers --ignore-not-found 2>/dev/null | wc -l | tr -d ' ')
			[[ -z "$sc_left" ]] && sc_left=0
			if (( sc_left > 0 )); then
				echo "  [$ctx] WARNING: ${sc_left} Sidecar CR(s) still present" >&2
			fi
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

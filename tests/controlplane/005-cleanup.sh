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

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV   Kube contexts to clean up (default: \$SETUP_CONTEXTS).
  --dry-run        Show what would be deleted without deleting.
  -h, --help       Show this help.

Behavior:
  Deletes every namespace labelled '${LABEL_SELECTOR}' on each context, plus
  the legacy single namespace '\$CONTROLPLANE_TEST_NAMESPACE' (default
  'controlplane-test') if it lacks the label.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_TEST_NAMESPACE.
EOF
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

# PL37 contract: same bound 001 reuses for its pre-apply poll-until-gone wait
# (CONTROLPLANE_SETUP_NS_WAIT_SEC defaults from this), so an operator override
# applies symmetrically to cleanup and the next setup.
TERMINATION_TIMEOUT="${CONTROLPLANE_NS_DELETE_TIMEOUT_SEC:-300}"

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
((DRY_RUN)) && echo "Mode:            dry-run"
echo ""

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
			# shellcheck disable=SC2086
			run_delete "${KUBECTL[@]}" --context="$ctx" delete $matches --ignore-not-found=true
		else
			echo "  [$ctx] No labelled namespaces found."
		fi

		# Fallback: legacy single namespace from a pre-label deployment.
		if "${KUBECTL[@]}" --context="$ctx" get namespace "$NS" >/dev/null 2>&1; then
			echo "  [$ctx] Removing legacy namespace $NS (no chart label)."
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

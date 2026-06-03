#!/usr/bin/env bash
# Deploy churn target workloads and watcher pods for convergence testing.
#
# Usage:
#   ./tests/churn/001-setup-churn-test.sh [--contexts CSV] [options]
#
# Examples:
#   # Setup on all default clusters:
#   ./tests/churn/001-setup-churn-test.sh
#
#   # Setup with custom churn targets:
#   ./tests/churn/001-setup-churn-test.sh --deployment-count 10 --base-replicas 1
# ci-dry-run-skip: needs valid kubeconfig context for kubectl apply --dry-run=client
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
DRY_RUN=0
WAIT_TIMEOUT=300
NS="${CHURN_TEST_NAMESPACE:-churn-test}"
DEPLOYMENT_COUNT="${CHURN_DEPLOYMENT_COUNT:-5}"
BASE_REPLICAS="${CHURN_BASE_REPLICAS:-1}"


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV         Kube contexts to target (default: \$SETUP_CONTEXTS).
  --deployment-count N   Number of churn target deployments (default: $DEPLOYMENT_COUNT).
  --base-replicas N      Initial replicas per deployment (default: $BASE_REPLICAS).
  --dry-run              Pass --dry-run=client to oc apply.
  --wait-timeout N       Seconds to wait for pods (default: 300).
  -h, --help             Show this help.

Environment:
  SETUP_CONTEXTS, CHURN_TEST_NAMESPACE, CHURN_DEPLOYMENT_COUNT, CHURN_BASE_REPLICAS.
EOF
}


while [[ $# -gt 0 ]]; do
	case "$1" in
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"
		shift 2
		;;
	--deployment-count)
		[[ -n "${2:-}" ]] || die "--deployment-count requires a value"
		DEPLOYMENT_COUNT="$2"
		shift 2
		;;
	--base-replicas)
		[[ -n "${2:-}" ]] || die "--base-replicas requires a value"
		BASE_REPLICAS="$2"
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
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

command -v helm >/dev/null 2>&1 || die "helm not found on PATH"

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_csv "$CONTEXTS_CSV" CONTEXTS
else
	split_csv "$SETUP_CONTEXTS" CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

apply=("${KUBECTL[@]}" apply)
((DRY_RUN)) && apply=("${KUBECTL[@]}" apply --dry-run=client)

CHART_DIR="${ROOT}/tests/churn/chart"

# O8 item 2(b): apply each context's chart concurrently — setup-only, disjoint
# contexts, fidelity-neutral. A non-zero exit in ANY context fails the join below,
# preserving the original `set -e` abort semantics.
APPLY_PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	(
		echo "Setting up churn-test on context $ctx (${DEPLOYMENT_COUNT} deployments × ${BASE_REPLICAS} replicas)"
		helm template churn-test "$CHART_DIR" \
			--set clusterName="$ctx" \
			--set namespace="$NS" \
			--set deploymentCount="$DEPLOYMENT_COUNT" \
			--set baseReplicas="$BASE_REPLICAS" \
			| "${apply[@]}" --context="$ctx" -f - \
			|| { echo "error: apply failed on $ctx" >&2; exit 1; }
	) &
	APPLY_PIDS+=($!)
done
for pid in "${APPLY_PIDS[@]}"; do
	wait "$pid" || die "one or more contexts failed the churn-test apply"
done

if ((DRY_RUN)); then
	echo "Dry-run complete."
	exit 0
fi

# O8 item 2(a): one label-selector wait per context (the chart stamps
# app.kubernetes.io/instance=churn-test on BOTH the churn-targets AND the
# churn-watcher, so one selector covers all), parallelized across contexts. Same
# readiness gate as the old per-deployment loop; setup-only, fidelity-neutral.
echo "Waiting for deployments to be ready (timeout: ${WAIT_TIMEOUT}s)..."
WAIT_PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	(
		echo "  Waiting on context $ctx..."
		"${KUBECTL[@]}" --context="$ctx" -n "$NS" wait \
			--for=condition=Available deployment \
			-l app.kubernetes.io/instance=churn-test \
			--timeout="${WAIT_TIMEOUT}s" \
			|| { echo "error: deployments not ready on $ctx" >&2; exit 1; }
		echo "  All deployments ready on $ctx."
	) &
	WAIT_PIDS+=($!)
done
for pid in "${WAIT_PIDS[@]}"; do
	wait "$pid" || die "one or more contexts failed deployment readiness check"
done

echo "Setup complete. ${DEPLOYMENT_COUNT} churn targets + watcher on: ${CONTEXTS[*]}"

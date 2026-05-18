#!/usr/bin/env bash
# Deploy churn target workloads and watcher pods for convergence testing.
#
# Usage:
#   ./churn-test/001-setup-churn-test.sh [--contexts CSV] [options]
#
# Examples:
#   # Setup on all default clusters:
#   ./churn-test/001-setup-churn-test.sh
#
#   # Setup with custom churn targets:
#   ./churn-test/001-setup-churn-test.sh --deployment-count 10 --base-replicas 1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
DRY_RUN=0
WAIT_TIMEOUT=300
NS="${CHURN_TEST_NAMESPACE:-churn-test}"
DEPLOYMENT_COUNT="${CHURN_DEPLOYMENT_COUNT:-5}"
BASE_REPLICAS="${CHURN_BASE_REPLICAS:-1}"

die() { echo "error: $*" >&2; exit 1; }

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

CHART_DIR="${ROOT}/charts/churn-test"

for ctx in "${CONTEXTS[@]}"; do
	echo "Setting up churn-test on context $ctx (${DEPLOYMENT_COUNT} deployments × ${BASE_REPLICAS} replicas)"
	helm template churn-test "$CHART_DIR" \
		--set clusterName="$ctx" \
		--set namespace="$NS" \
		--set deploymentCount="$DEPLOYMENT_COUNT" \
		--set baseReplicas="$BASE_REPLICAS" \
		| "${apply[@]}" --context="$ctx" -f -
done

if ((DRY_RUN)); then
	echo "Dry-run complete."
	exit 0
fi

echo "Waiting for deployments to be ready (timeout: ${WAIT_TIMEOUT}s)..."
for ctx in "${CONTEXTS[@]}"; do
	echo "  Waiting on context $ctx..."
	for ((i = 0; i < DEPLOYMENT_COUNT; i++)); do
		"${KUBECTL[@]}" --context="$ctx" -n "$NS" wait deployment/churn-target-${i} \
			--for=condition=Available --timeout="${WAIT_TIMEOUT}s" || die "churn-target-${i} not ready on $ctx"
	done
	"${KUBECTL[@]}" --context="$ctx" -n "$NS" wait deployment/churn-watcher \
		--for=condition=Available --timeout="${WAIT_TIMEOUT}s" || die "churn-watcher not ready on $ctx"
	echo "  All deployments ready on $ctx."
done

echo "Setup complete. ${DEPLOYMENT_COUNT} churn targets + watcher on: ${CONTEXTS[*]}"

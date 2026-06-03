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
#   ./tests/propagation/001-setup-propagation-test.sh --contexts cluster-001,cluster-002
#
#   # Tear down from all clusters:
#   ./tests/propagation/001-setup-propagation-test.sh --cleanup
# ci-dry-run-skip: needs valid kubeconfig context for kubectl apply --dry-run=client
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
DRY_RUN=0
CLEANUP=0
WAIT_TIMEOUT=300
WATCHER_REPLICAS="${PROPAGATION_WATCHER_REPLICAS}"
# R3-2: pre-warmed backer image pin (O1). Sourced from config/versions.env; the
# default guard keeps it bound under `set -u` if the pin is ever removed there.
# Wired into the helm template below via --set so the chart values.yaml literal is
# not the sole effective pin (mirrors tests/dataplane/001 --set fortioImage.tag).
: "${HTTP_ECHO_VERSION:=1.0}"


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV        Kube contexts to target (default: \$SETUP_CONTEXTS).
  --watcher-replicas N  Watcher pod replicas per cluster (default: \$PROPAGATION_WATCHER_REPLICAS=$WATCHER_REPLICAS).
  --dry-run             Pass --dry-run=client to oc apply.
  --cleanup             Remove propagation-test namespace from all contexts.
  --wait-timeout N      Seconds to wait for watcher pods AND the pre-warmed backer
                        pod (propagation-canary) to become Ready (default: 300).
  -h, --help            Show this help.

Environment:
  SETUP_CONTEXTS, PROPAGATION_TEST_NAMESPACE, PROPAGATION_WATCHER_REPLICAS.
EOF
}


while [[ $# -gt 0 ]]; do
	case "$1" in
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"
		shift 2
		;;
	--watcher-replicas)
		[[ -n "${2:-}" ]] || die "--watcher-replicas requires a value"
		WATCHER_REPLICAS="$2"
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
	# O1: render the pre-warmed backer Deployment + canary Service alongside the
	# watcher. backer.enabled=true warms the http-echo pod (image pre-pulled,
	# sidecar up, readinessProbe) and creates the canary Service; backer.active
	# stays false so the Service has ZERO endpoints until the probe flips the
	# active label at t0. The render is uniform across contexts — the source
	# cluster's backer is the one the probe flips; on remotes the Service simply
	# stays at zero endpoints (harmless).
	helm template propagation-test "$CHART_DIR" \
		--set clusterName="$ctx" \
		--set namespace="$NS" \
		--set backer.enabled=true \
		--set backer.active=false \
		--set backer.image.tag="$HTTP_ECHO_VERSION" \
		--set watcher.replicaCount="$WATCHER_REPLICAS" \
		| "${apply[@]}" --context="$ctx" -f -
done

if ((DRY_RUN)); then
	echo "Dry-run complete."
	exit 0
fi

echo "Waiting for watcher and backer pods to be ready (timeout: ${WAIT_TIMEOUT}s)..."
for ctx in "${CONTEXTS[@]}"; do
	echo "  Waiting on context $ctx..."
	"${KUBECTL[@]}" --context="$ctx" -n "$NS" wait deployment/propagation-watcher \
		--for=condition=Available --timeout="${WAIT_TIMEOUT}s" || die "watcher not ready on $ctx"
	# O1: the backer must be Available BEFORE any probe iteration so the t0 label
	# flip is a pure config push with no pod boot inside P3's window.
	"${KUBECTL[@]}" --context="$ctx" -n "$NS" wait deployment/propagation-canary \
		--for=condition=Available --timeout="${WAIT_TIMEOUT}s" || die "backer not ready on $ctx"
	echo "  Watcher + backer ready on $ctx."
done

echo "Setup complete. Watcher + pre-warmed backer pods running on: ${CONTEXTS[*]}"

#!/usr/bin/env bash
# Deploy co-located fortio (server + client) and churn-target workloads in a
# single shared namespace for measuring data-plane latency delta under churn.
#
# Usage:
#   ./tests/churn-dataplane/001-setup-coexec-test.sh \
#       --source-context CTX [--remote-contexts CSV] [options]
#
# Examples:
#   # Source on rosa-001 with two remote clusters as additional server endpoints:
#   ./tests/churn-dataplane/001-setup-coexec-test.sh \
#     --source-context rosa-001 --remote-contexts rosa-002,rosa-003
#
#   # Dry-run (templates rendered through `oc apply --dry-run=client`):
#   ./tests/churn-dataplane/001-setup-coexec-test.sh \
#     --source-context rosa-001 --remote-contexts rosa-002 --dry-run
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/churn-dataplane/lib/preamble.sh"

SOURCE_CTX=""
REMOTE_CONTEXTS_CSV=""
DRY_RUN=0
WAIT_TIMEOUT=300
NS="${COEXEC_TEST_NAMESPACE:-churn-dataplane-test}"
CHURN_DEPLOYMENT_COUNT_OPT="${CHURN_DEPLOYMENT_COUNT:-10}"
CHURN_BASE_REPLICAS_OPT="${CHURN_BASE_REPLICAS:-1}"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --source-context CTX     Context where fortio-client is deployed (required).
  --remote-contexts CSV    Additional contexts that also receive fortio-server +
                           churn-target workloads (comma-separated).
  --deployment-count N     Number of churn-target Deployments (default: $CHURN_DEPLOYMENT_COUNT_OPT).
  --base-replicas N        Initial replicas per churn-target Deployment (default: $CHURN_BASE_REPLICAS_OPT).
  --wait-timeout N         Seconds to wait for Deployments to become Available (default: $WAIT_TIMEOUT).
  --dry-run                Pass --dry-run=client to oc apply; do not touch clusters.
  -h, --help               Show this help.

Environment:
  SETUP_CONTEXTS, COEXEC_TEST_NAMESPACE, CHURN_DEPLOYMENT_COUNT, CHURN_BASE_REPLICAS.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--source-context)
		[[ -n "${2:-}" ]] || die "--source-context requires a value"
		SOURCE_CTX="$2"
		shift 2
		;;
	--remote-contexts)
		[[ -n "${2:-}" ]] || die "--remote-contexts requires a value"
		REMOTE_CONTEXTS_CSV="$2"
		shift 2
		;;
	--deployment-count)
		[[ -n "${2:-}" ]] || die "--deployment-count requires a value"
		CHURN_DEPLOYMENT_COUNT_OPT="$2"
		shift 2
		;;
	--base-replicas)
		[[ -n "${2:-}" ]] || die "--base-replicas requires a value"
		CHURN_BASE_REPLICAS_OPT="$2"
		shift 2
		;;
	--wait-timeout)
		[[ -n "${2:-}" ]] || die "--wait-timeout requires a value"
		WAIT_TIMEOUT="$2"
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

[[ -n "$SOURCE_CTX" ]] || die "--source-context is required"

if command -v oc >/dev/null 2>&1; then
	KUBECTL=(oc)
elif command -v kubectl >/dev/null 2>&1; then
	KUBECTL=(kubectl)
else
	die "neither oc nor kubectl found on PATH"
fi

command -v helm >/dev/null 2>&1 || die "helm not found on PATH"

REMOTES=()
if [[ -n "$REMOTE_CONTEXTS_CSV" ]]; then
	split_csv "$REMOTE_CONTEXTS_CSV" REMOTES
fi
ALL_CTXS=("$SOURCE_CTX" "${REMOTES[@]}")

CHART_DIR="${ROOT}/tests/churn-dataplane/chart"

# PL5: server-side apply by default; allow --dry-run=client for verification.
apply=("${KUBECTL[@]}" apply --server-side --force-conflicts)
if ((DRY_RUN)); then
	apply=("${KUBECTL[@]}" apply --dry-run=client)
fi

render_for() {
	local ctx="$1" role="$2"
	helm template churn-dataplane-test "$CHART_DIR" \
		--set clusterName="$ctx" \
		--set namespace="$NS" \
		--set fortioRole="$role" \
		--set churnDeploymentCount="$CHURN_DEPLOYMENT_COUNT_OPT" \
		--set churnBaseReplicas="$CHURN_BASE_REPLICAS_OPT"
}

# Source context: fortio server+client+churn-targets all in shared NS.
echo "Setup [source=$SOURCE_CTX]: fortio (server+client) + ${CHURN_DEPLOYMENT_COUNT_OPT} churn-targets in ns=${NS}"
render_for "$SOURCE_CTX" both | "${apply[@]}" --context="$SOURCE_CTX" -f -

# Remote contexts: server + churn-targets (no client; that lives on source).
for ctx in "${REMOTES[@]}"; do
	echo "Setup [remote=$ctx]: fortio-server + ${CHURN_DEPLOYMENT_COUNT_OPT} churn-targets in ns=${NS}"
	render_for "$ctx" server | "${apply[@]}" --context="$ctx" -f -
done

if ((DRY_RUN)); then
	echo "Dry-run complete."
	exit 0
fi

echo "Waiting for Deployments to be Available (timeout: ${WAIT_TIMEOUT}s)..."
for ctx in "${ALL_CTXS[@]}"; do
	echo "  [$ctx] fortio-server"
	"${KUBECTL[@]}" --context="$ctx" -n "$NS" wait deployment/fortio-server \
		--for=condition=Available --timeout="${WAIT_TIMEOUT}s" \
		|| die "fortio-server not ready on $ctx"
	for ((i = 0; i < CHURN_DEPLOYMENT_COUNT_OPT; i++)); do
		"${KUBECTL[@]}" --context="$ctx" -n "$NS" wait deployment/churn-target-${i} \
			--for=condition=Available --timeout="${WAIT_TIMEOUT}s" \
			|| die "churn-target-${i} not ready on $ctx"
	done
done

echo "  [$SOURCE_CTX] fortio-client"
"${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" wait deployment/fortio-client \
	--for=condition=Available --timeout="${WAIT_TIMEOUT}s" \
	|| die "fortio-client not ready on $SOURCE_CTX"

echo "Setup complete. Contexts: ${ALL_CTXS[*]}  Namespace: ${NS}"

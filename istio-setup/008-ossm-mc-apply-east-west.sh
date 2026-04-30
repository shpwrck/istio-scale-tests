#!/usr/bin/env bash
# Apply east-west gateway + cross-network Gateway from templates (OSSM 3.3 — see AGENTS.md).
#
# Requires: envsubst (gettext), oc
# Usage (repo root): ./istio-setup/008-ossm-mc-apply-east-west.sh [--dry-run]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
export PATH="${ROOT}/.bin:${PATH}"

if ! command -v envsubst >/dev/null 2>&1; then
	echo "error: envsubst not found (install gettext / gettext-envsubst)" >&2
	exit 2
fi

DRY_RUN=0
for a in "$@"; do
	[[ "$a" == "--dry-run" ]] && DRY_RUN=1
done

apply=(oc apply)
((DRY_RUN)) && apply=(oc apply --dry-run=client)

EW="${ROOT}/manifests/ossm-multi-cluster"
TPL="${EW}/templates"
CLUSTERS=(rosa-001 rosa-002 rosa-003)

for ctx in "${CLUSTERS[@]}"; do
	export CLUSTER_KEY="$ctx"
	export NETWORK="${CLUSTER_KEY}-${NETWORK_SUFFIX}"
	echo "[$ctx] applying east-west gateway (${NETWORK})"
	envsubst <"${TPL}/east-west-gateway.yaml.tpl" | "${apply[@]}" --context="$ctx" -f -
	echo "[$ctx] applying cross-network-gateway (TLS AUTO_PASSTHROUGH :15443)"
	"${apply[@]}" --context="$ctx" -n istio-system -f "${EW}/east-west/common/expose-services.yaml"
	if ((DRY_RUN)); then
		echo "[$ctx] dry-run: skipping rollout wait / svc get"
		echo ""
		continue
	fi
	echo "[$ctx] waiting for istio-eastwestgateway rollout (timeout 10m)"
	if oc --context="$ctx" rollout status -n istio-system deploy/istio-eastwestgateway --timeout=10m 2>/dev/null; then
		:
	else
		echo "[$ctx] warn: rollout wait failed or deployment missing — check: oc --context=$ctx -n istio-system get deploy,pods -l app=istio-eastwestgateway"
	fi
	echo "[$ctx] istio-eastwestgateway Service (LoadBalancer status)"
	if ! oc --context="$ctx" get svc -n istio-system istio-eastwestgateway -o wide 2>/dev/null; then
		echo "[$ctx] warn: could not get Service — check context/login"
	fi
	EXIP="$(oc --context="$ctx" get svc -n istio-system istio-eastwestgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
	if [[ -z "${EXIP}" ]]; then
		echo "[$ctx] note: EXTERNAL-IP not assigned yet (pending LB). On ROSA this usually resolves once AWS LB provisions."
	fi
	echo ""
done
echo "Done."

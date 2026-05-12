#!/usr/bin/env bash
set -euo pipefail

# Restart istiod and gateway deployments on a spoke cluster to ensure:
#   1. istiod picks up the cacerts secret (shared mesh root CA)
#   2. Gateways get proper sidecar injection (image: auto → real image)
#
# Reads from environment variables (set by Terraform local-exec):
#   SPOKE_NAME, API_URL, SPOKE_TOKEN

: "${SPOKE_NAME:?SPOKE_NAME is required}"
: "${API_URL:?API_URL is required}"
: "${SPOKE_TOKEN:?SPOKE_TOKEN is required}"

KC="kubectl --server=$API_URL --token=$SPOKE_TOKEN --insecure-skip-tls-verify"
NS="istio-system"

echo "[$SPOKE_NAME] Waiting for istiod deployment..."
ELAPSED=0
while [ $ELAPSED -lt 300 ]; do
  if $KC get deployment istiod -n "$NS" &>/dev/null; then
    break
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

if ! $KC get deployment istiod -n "$NS" &>/dev/null; then
  echo "[$SPOKE_NAME] istiod deployment not found after 300s — skipping"
  exit 0
fi

echo "[$SPOKE_NAME] Restarting istiod..."
$KC rollout restart deployment/istiod -n "$NS"
$KC rollout status deployment/istiod -n "$NS" --timeout=180s

for GW in istio-ingressgateway istio-eastwestgateway; do
  if $KC get deployment "$GW" -n "$NS" &>/dev/null; then
    echo "[$SPOKE_NAME] Restarting $GW..."
    $KC rollout restart deployment/"$GW" -n "$NS"
    $KC rollout status deployment/"$GW" -n "$NS" --timeout=180s
  fi
done

echo "[$SPOKE_NAME] Mesh restart complete"

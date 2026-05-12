#!/usr/bin/env bash
set -euo pipefail

# Patch an ACM-created ArgoCD cluster secret with the real API URL and bearer token.
# ACM's GitOps addon creates secrets with internal control-plane URLs that are
# unreachable from the hub; this replaces them with the public API endpoint.
#
# Reads from environment variables (set by Terraform local-exec):
#   SPOKE_NAME, API_URL, SPOKE_TOKEN, HUB_TOKEN_SCRIPT, HUB_API_URL, HUB_ADMIN_PASS, GITOPS_NAMESPACE

: "${SPOKE_NAME:?SPOKE_NAME is required}"
: "${API_URL:?API_URL is required}"
: "${SPOKE_TOKEN:?SPOKE_TOKEN is required}"
: "${HUB_TOKEN_SCRIPT:?HUB_TOKEN_SCRIPT is required}"
: "${HUB_API_URL:?HUB_API_URL is required}"
: "${HUB_ADMIN_PASS:?HUB_ADMIN_PASS is required}"
: "${GITOPS_NAMESPACE:?GITOPS_NAMESPACE is required}"

HUB_TOKEN=$("$HUB_TOKEN_SCRIPT" "$HUB_API_URL" "cluster-admin" "$HUB_ADMIN_PASS" | jq -r '.status.token')
KC="kubectl --server=$HUB_API_URL --token=$HUB_TOKEN --insecure-skip-tls-verify"

SECRET_NAME="${SPOKE_NAME}-application-manager-cluster-secret"

if ! $KC get secret "$SECRET_NAME" -n "$GITOPS_NAMESPACE" &>/dev/null; then
  echo "Secret $SECRET_NAME not found in $GITOPS_NAMESPACE — skipping (addon may not have created it yet)"
  exit 0
fi

HOST=$(echo "$API_URL" | sed 's|https://||;s|:443||')
CA_PEM=$(openssl s_client -connect "${HOST}:443" -showcerts </dev/null 2>/dev/null \
  | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/')
CA_B64_DATA=$(echo -n "$CA_PEM" | base64 -w0)

SERVER_B64=$(echo -n "$API_URL" | base64 -w0)
CONFIG_B64=$(jq -nc --arg t "$SPOKE_TOKEN" --arg ca "$CA_B64_DATA" \
  '{bearerToken: $t, tlsClientConfig: {insecure: false, caData: $ca}}' | base64 -w0)

$KC patch secret "$SECRET_NAME" -n "$GITOPS_NAMESPACE" --type merge \
  -p "{\"data\":{\"server\":\"${SERVER_B64}\",\"config\":\"${CONFIG_B64}\"}}"

echo "Patched $SECRET_NAME with server=$API_URL"

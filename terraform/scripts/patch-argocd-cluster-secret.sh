#!/usr/bin/env bash
set -euo pipefail

# Patch an ACM-created ArgoCD cluster secret with the real API URL and bearer token.
# ACM's GitOps addon creates secrets with internal control-plane URLs that are
# unreachable from the hub; this replaces them with the public API endpoint.
#
# Usage: patch-argocd-cluster-secret.sh <spoke_name> <api_url> <spoke_token> <hub_token_script> <hub_api_url> <hub_admin_pass> <gitops_namespace>

SPOKE="${1:?usage: $0 <spoke_name> <api_url> <spoke_token> <hub_token_script> <hub_api_url> <hub_admin_pass> <gitops_namespace>}"
API_URL="${2:?}"
SPOKE_TOKEN="${3:?}"
HUB_TOKEN_SCRIPT="${4:?}"
HUB_API_URL="${5:?}"
HUB_ADMIN_PASS="${6:?}"
NS="${7:?}"

HUB_TOKEN=$("$HUB_TOKEN_SCRIPT" "$HUB_API_URL" "cluster-admin" "$HUB_ADMIN_PASS" | jq -r '.status.token')
KC="kubectl --server=$HUB_API_URL --token=$HUB_TOKEN --insecure-skip-tls-verify"

SECRET_NAME="${SPOKE}-application-manager-cluster-secret"

if ! $KC get secret "$SECRET_NAME" -n "$NS" &>/dev/null; then
  echo "Secret $SECRET_NAME not found in $NS — skipping (addon may not have created it yet)"
  exit 0
fi

HOST=$(echo "$API_URL" | sed 's|https://||;s|:443||')
CA_PEM=$(openssl s_client -connect "${HOST}:443" -showcerts </dev/null 2>/dev/null \
  | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/')
CA_B64_DATA=$(echo -n "$CA_PEM" | base64 -w0)

SERVER_B64=$(echo -n "$API_URL" | base64 -w0)
CONFIG_B64=$(jq -nc --arg t "$SPOKE_TOKEN" --arg ca "$CA_B64_DATA" \
  '{bearerToken: $t, tlsClientConfig: {insecure: false, caData: $ca}}' | base64 -w0)

$KC patch secret "$SECRET_NAME" -n "$NS" --type merge \
  -p "{\"data\":{\"server\":\"${SERVER_B64}\",\"config\":\"${CONFIG_B64}\"}}" &>/dev/null

echo "Patched $SECRET_NAME with server=$API_URL"

#!/usr/bin/env bash
set -euo pipefail

# Patch an ACM-created ArgoCD cluster secret with the real API URL and bearer token.
# ACM's GitOps addon creates secrets with internal *-control-plane URLs that are
# unreachable from the hub; this replaces them with the public API endpoint.
# Also fetches the spoke API server's TLS CA chain so ExternalSecrets can verify.
#
# Usage: patch-argocd-cluster-secret.sh <spoke_name> <api_url> <bearer_token> <gitops_namespace>
#
# Outputs JSON for Terraform external data source: {"patched":"true"|"false"}

SPOKE="${1:?usage: $0 <spoke_name> <api_url> <bearer_token> <gitops_namespace>}"
API_URL="${2:?}"
TOKEN="${3:?}"
NS="${4:?}"

SECRET_NAME="${SPOKE}-application-manager-cluster-secret"

if ! kubectl get secret "$SECRET_NAME" -n "$NS" &>/dev/null; then
  echo '{"patched":"false","reason":"secret_not_found"}'
  exit 0
fi

HOST=$(echo "$API_URL" | sed 's|https://||;s|:443||')
CA_PEM=$(openssl s_client -connect "${HOST}:443" -showcerts </dev/null 2>/dev/null \
  | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/')
CA_B64_DATA=$(echo -n "$CA_PEM" | base64 -w0)

SERVER_B64=$(echo -n "$API_URL" | base64 -w0)
CONFIG_B64=$(jq -nc --arg t "$TOKEN" --arg ca "$CA_B64_DATA" \
  '{bearerToken: $t, tlsClientConfig: {insecure: false, caData: $ca}}' | base64 -w0)

kubectl patch secret "$SECRET_NAME" -n "$NS" --type merge \
  -p "{\"data\":{\"server\":\"${SERVER_B64}\",\"config\":\"${CONFIG_B64}\"}}" &>/dev/null

echo '{"patched":"true","reason":"success"}'

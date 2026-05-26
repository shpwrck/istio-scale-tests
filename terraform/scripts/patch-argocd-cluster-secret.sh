#!/usr/bin/env bash
set -euo pipefail

# Patch an ACM-created ArgoCD cluster secret with the real API URL and bearer token.
# ACM's GitOps addon creates secrets with internal control-plane URLs that are
# unreachable from the hub; this replaces them with the public API endpoint.
#
# Auth modes (via environment variables):
#   Kubeconfig: KUBECONFIG_PATH + HUB_CONTEXT + SPOKE_CONTEXT
#   Token:      HUB_TOKEN_SCRIPT + HUB_API_URL + HUB_ADMIN_PASS + SPOKE_TOKEN
#
# Required: SPOKE_NAME, API_URL, GITOPS_NAMESPACE, MANAGED_SA_NAME

: "${SPOKE_NAME:?SPOKE_NAME is required}"
: "${API_URL:?API_URL is required}"
: "${GITOPS_NAMESPACE:?GITOPS_NAMESPACE is required}"
: "${MANAGED_SA_NAME:?MANAGED_SA_NAME is required}"

if [[ -n "${KUBECONFIG_PATH:-}" ]] && [[ -n "${HUB_CONTEXT:-}" ]]; then
  KC="kubectl --kubeconfig=$KUBECONFIG_PATH --context=$HUB_CONTEXT"
elif [[ -n "${HUB_TOKEN_SCRIPT:-}" ]] && [[ -n "${HUB_API_URL:-}" ]] && [[ -n "${HUB_ADMIN_PASS:-}" ]]; then
  HUB_TOKEN=$("$HUB_TOKEN_SCRIPT" "$HUB_API_URL" "cluster-admin" "$HUB_ADMIN_PASS" | jq -r '.status.token')
  KC="kubectl --server=$HUB_API_URL --token=$HUB_TOKEN --insecure-skip-tls-verify"
else
  echo "error: set KUBECONFIG_PATH+HUB_CONTEXT or HUB_TOKEN_SCRIPT+HUB_API_URL+HUB_ADMIN_PASS" >&2
  exit 1
fi

SECRET_NAME="${SPOKE_NAME}-${MANAGED_SA_NAME}-cluster-secret"

if ! $KC get secret "$SECRET_NAME" -n "$GITOPS_NAMESPACE" &>/dev/null; then
  echo "Secret $SECRET_NAME not found in $GITOPS_NAMESPACE — skipping (addon may not have created it yet)"
  exit 0
fi

# Build config JSON for the ArgoCD cluster secret.
# Kubeconfig mode: extract client cert+key from the kubeconfig for the spoke context.
# Token mode: use bearer token from env var.
if [[ -n "${KUBECONFIG_PATH:-}" ]] && [[ -n "${SPOKE_CONTEXT:-}" ]]; then
  SPOKE_KC_JSON=$(kubectl --kubeconfig="$KUBECONFIG_PATH" config view --raw --minify --context="$SPOKE_CONTEXT" --flatten -o json)
  CLIENT_CERT=$(echo "$SPOKE_KC_JSON" | jq -r '.users[0].user["client-certificate-data"] // empty')
  CLIENT_KEY=$(echo "$SPOKE_KC_JSON" | jq -r '.users[0].user["client-key-data"] // empty')
  CA_DATA=$(echo "$SPOKE_KC_JSON" | jq -r '.clusters[0].cluster["certificate-authority-data"] // empty')
  SPOKE_TOKEN_VALUE=$(echo "$SPOKE_KC_JSON" | jq -r '.users[0].user.token // empty')

  if [[ -n "$CLIENT_CERT" ]] && [[ -n "$CLIENT_KEY" ]]; then
    # Create an SA token so spoke SecretStores can use bearer-token auth universally.
    # The cert data is still included for kubeconfig generation (ESO template prefers certs).
    SPOKE_TOKEN_VALUE=$(kubectl --kubeconfig="$KUBECONFIG_PATH" --context="$SPOKE_CONTEXT" \
      create token "$MANAGED_SA_NAME" --namespace open-cluster-management-agent-addon --duration=87600h 2>/dev/null) || SPOKE_TOKEN_VALUE=""
    if [[ -n "$SPOKE_TOKEN_VALUE" ]]; then
      CONFIG_JSON=$(jq -nc \
        --arg cert "$CLIENT_CERT" --arg key "$CLIENT_KEY" --arg ca "${CA_DATA:-}" --arg t "$SPOKE_TOKEN_VALUE" \
        '{bearerToken: $t, tlsClientConfig: {certData: $cert, keyData: $key, caData: $ca, insecure: false}}')
    else
      echo "WARNING: could not create SA token on spoke $SPOKE_NAME; cert-only config (spoke SecretStore may need authType=cert)"
      CONFIG_JSON=$(jq -nc \
        --arg cert "$CLIENT_CERT" --arg key "$CLIENT_KEY" --arg ca "${CA_DATA:-}" \
        '{tlsClientConfig: {certData: $cert, keyData: $key, caData: $ca, insecure: false}}')
    fi
  elif [[ -n "$SPOKE_TOKEN_VALUE" ]]; then
    CONFIG_JSON=$(jq -nc \
      --arg t "$SPOKE_TOKEN_VALUE" --arg ca "${CA_DATA:-}" \
      '{bearerToken: $t, tlsClientConfig: {insecure: false, caData: $ca}}')
  else
    SPOKE_TOKEN_VALUE=$(kubectl --kubeconfig="$KUBECONFIG_PATH" --context="$SPOKE_CONTEXT" \
      create token "$MANAGED_SA_NAME" --namespace open-cluster-management-agent-addon --duration=87600h 2>/dev/null) || {
      echo "WARNING: could not create SA token on spoke $SPOKE_NAME, using empty token"
      SPOKE_TOKEN_VALUE=""
    }
    CONFIG_JSON=$(jq -nc \
      --arg t "$SPOKE_TOKEN_VALUE" --arg ca "${CA_DATA:-}" \
      '{bearerToken: $t, tlsClientConfig: {insecure: false, caData: $ca}}')
  fi
elif [[ -n "${SPOKE_TOKEN:-}" ]]; then
  SPOKE_TOKEN_VALUE="$SPOKE_TOKEN"
  HOST=$(echo "$API_URL" | sed 's|https\?://||;s|/.*||')
  if ! echo "$HOST" | grep -q ':'; then HOST="${HOST}:443"; fi
  CA_PEM=$(openssl s_client -connect "${HOST}" -showcerts </dev/null 2>/dev/null \
    | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/')
  CA_B64_DATA=$(echo -n "$CA_PEM" | base64 | tr -d '\n')
  CONFIG_JSON=$(jq -nc --arg t "$SPOKE_TOKEN_VALUE" --arg ca "$CA_B64_DATA" \
    '{bearerToken: $t, tlsClientConfig: {insecure: false, caData: $ca}}')
else
  echo "error: need SPOKE_TOKEN or KUBECONFIG_PATH+SPOKE_CONTEXT for spoke auth" >&2
  exit 1
fi

SERVER_B64=$(echo -n "$API_URL" | base64 | tr -d '\n')
CONFIG_B64=$(echo -n "$CONFIG_JSON" | base64 | tr -d '\n')

$KC patch secret "$SECRET_NAME" -n "$GITOPS_NAMESPACE" --type merge \
  -p "{\"data\":{\"server\":\"${SERVER_B64}\",\"config\":\"${CONFIG_B64}\"}}"

echo "Patched $SECRET_NAME with server=$API_URL"

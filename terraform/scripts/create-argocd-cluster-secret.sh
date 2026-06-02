#!/usr/bin/env bash
set -euo pipefail

# Authoritatively create (oc apply) the Argo CD cluster Secret for a spoke,
# pointing at the spoke's direct external API URL.
#
# This REPLACES the old patch-argocd-cluster-secret.sh workaround. Previously
# ACM's GitOpsCluster controller created these secrets and forced an
# unreachable server URL (https://<name>-control-plane in gitops-addon/pull
# mode, or a flaky cluster-proxy tunnel URL in push mode), and Terraform fought
# it on every apply. We now own the secret outright: the GitOpsCluster has been
# removed, so nothing reconciles the server field back to an internal value.
#
# The secret name and data keys match what ACM used and what the
# hub-kubeconfig-from-argosecret ESO chart reads (name/server/config), so the
# Argo CD push-sync AND the ESO mesh-CA distribution both resolve the spoke via
# the same reliable external URL.
#
# Auth modes (via environment variables):
#   Kubeconfig: KUBECONFIG_PATH + HUB_CONTEXT + SPOKE_CONTEXT
#   Token:      HUB_TOKEN_SCRIPT + HUB_API_URL + HUB_ADMIN_PASS  (spoke auth via ManagedServiceAccount token)
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

# Build the Argo CD cluster config JSON (bearerToken + tlsClientConfig).
# Kubeconfig mode: extract client cert+key+CA from the spoke kubeconfig context.
# Token mode: use the spoke's ManagedServiceAccount token (long-lived, cluster-admin
#   via the MSA RBAC ManifestWork) and the external API CA chain.
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
else
  # Token mode (ROSA): read the spoke's ManagedServiceAccount token from the hub
  # (namespace = spoke name, secret name = MANAGED_SA_NAME). The managed-serviceaccount
  # addon rotates this secret, so re-running on apply refreshes the token.
  SPOKE_TOKEN_VALUE=$($KC get secret "$MANAGED_SA_NAME" -n "$SPOKE_NAME" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
  if [[ -z "$SPOKE_TOKEN_VALUE" ]]; then
    echo "error: ManagedServiceAccount token secret $SPOKE_NAME/$MANAGED_SA_NAME not found on hub" >&2
    exit 1
  fi
  # The external API serving cert is signed by the cluster's own CA chain; capture it.
  HOST=$(echo "$API_URL" | sed 's|https\?://||;s|/.*||')
  if ! echo "$HOST" | grep -q ':'; then HOST="${HOST}:443"; fi
  CA_PEM=$(openssl s_client -connect "${HOST}" -showcerts </dev/null 2>/dev/null \
    | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/')
  CA_B64_DATA=$(echo -n "$CA_PEM" | base64 | tr -d '\n')
  CONFIG_JSON=$(jq -nc --arg t "$SPOKE_TOKEN_VALUE" --arg ca "$CA_B64_DATA" \
    '{bearerToken: $t, tlsClientConfig: {insecure: false, caData: $ca}}')
fi

NAME_B64=$(echo -n "$SPOKE_NAME" | base64 | tr -d '\n')
SERVER_B64=$(echo -n "$API_URL" | base64 | tr -d '\n')
CONFIG_B64=$(echo -n "$CONFIG_JSON" | base64 | tr -d '\n')

# Apply the full Argo CD cluster Secret. `apply` is idempotent: it creates the
# secret on a fresh deploy and updates it (server/config/token refresh) on
# subsequent applies, adopting any pre-existing same-named secret.
$KC apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${GITOPS_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
data:
  name: ${NAME_B64}
  server: ${SERVER_B64}
  config: ${CONFIG_B64}
EOF

echo "Applied $SECRET_NAME with server=$API_URL"

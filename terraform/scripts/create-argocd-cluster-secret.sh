#!/usr/bin/env bash
set -euo pipefail

# Create (oc apply) the Argo CD cluster Secret for a spoke, pointing at the
# spoke's direct external API URL. Terraform owns this Secret; ACM's
# GitOpsCluster is not used because it rewrites the server URL. The name and
# keys (name/server/config) are what the hub-kubeconfig-from-argosecret chart reads.
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
  INSECURE=$(echo "$SPOKE_KC_JSON" | jq -r '.clusters[0].cluster["insecure-skip-tls-verify"] // false')

  # Prefer a long-lived token for the ManagedServiceAccount (ESO's spoke
  # SecretStores use bearer-token auth). Fall back to the context's own token,
  # which is usually a short-lived `oc login` token.
  SPOKE_TOKEN_VALUE=$(kubectl --kubeconfig="$KUBECONFIG_PATH" --context="$SPOKE_CONTEXT" \
    create token "$MANAGED_SA_NAME" --namespace open-cluster-management-agent-addon --duration=87600h 2>/dev/null) || SPOKE_TOKEN_VALUE=""
  if [[ -z "$SPOKE_TOKEN_VALUE" ]]; then
    SPOKE_TOKEN_VALUE=$(echo "$SPOKE_KC_JSON" | jq -r '.users[0].user.token // empty')
    if [[ -n "$SPOKE_TOKEN_VALUE" ]]; then
      echo "WARNING: could not create a $MANAGED_SA_NAME token on spoke $SPOKE_NAME; using the kubeconfig context token (it may expire)" >&2
    else
      echo "WARNING: no bearer token for spoke $SPOKE_NAME; client-cert-only config" >&2
    fi
  fi

  CONFIG_JSON=$(jq -nc \
    --arg t "$SPOKE_TOKEN_VALUE" --arg cert "$CLIENT_CERT" --arg key "$CLIENT_KEY" \
    --arg ca "$CA_DATA" --argjson insecure "$INSECURE" \
    '{tlsClientConfig: ({insecure: $insecure}
        + (if $ca != "" and ($insecure | not) then {caData: $ca} else {} end)
        + (if $cert != "" then {certData: $cert, keyData: $key} else {} end))}
     + (if $t != "" then {bearerToken: $t} else {} end)')
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

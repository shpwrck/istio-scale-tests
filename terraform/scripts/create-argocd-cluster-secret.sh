#!/usr/bin/env bash
set -euo pipefail

# Create (kubectl apply) the Argo CD cluster Secret for a spoke, pointing at the
# spoke's direct external API URL. Terraform owns this Secret. The name and keys
# (name/server/config) are what the hub-kubeconfig-from-argosecret chart reads. Mesh
# members (MESH_MEMBER=true) carry the label istio-mesh-member=true, which the
# ApplicationSets' clusters generator selects on platform kubernetes.
#
# Platforms (PLATFORM):
#   kubernetes (default): the spoke credential is a ServiceAccount this script creates on
#     the spoke (MANAGED_SA_NAME in SPOKE_SA_NAMESPACE, bound to cluster-admin) and its
#     long-lived token Secret. Kubeconfig mode only. ACTION=delete removes the cluster
#     Secret and the spoke's ServiceAccount, binding and token (destroy).
#   openshift: the credential is the spoke's ACM ManagedServiceAccount. ACM's
#     GitOpsCluster is not used because it rewrites the server URL.
#
# Auth modes (via environment variables):
#   Kubeconfig: KUBECONFIG_PATH + HUB_CONTEXT + SPOKE_CONTEXT
#   Token:      HUB_TOKEN_SCRIPT + HUB_API_URL + HUB_ADMIN_PASS  (openshift; spoke auth via ManagedServiceAccount token)
#
# Required: SPOKE_NAME, GITOPS_NAMESPACE, MANAGED_SA_NAME, API_URL (except ACTION=delete)
# Optional: PLATFORM (kubernetes), ACTION (apply|delete), MESH_MEMBER (true|false),
#   SPOKE_SA_NAMESPACE (kube-system)

: "${SPOKE_NAME:?SPOKE_NAME is required}"
: "${GITOPS_NAMESPACE:?GITOPS_NAMESPACE is required}"
: "${MANAGED_SA_NAME:?MANAGED_SA_NAME is required}"
PLATFORM="${PLATFORM:-kubernetes}"
ACTION="${ACTION:-apply}"
MESH_MEMBER="${MESH_MEMBER:-false}"
SPOKE_SA_NAMESPACE="${SPOKE_SA_NAMESPACE:-kube-system}"

case "$PLATFORM" in kubernetes | openshift) ;; *) echo "error: PLATFORM must be kubernetes or openshift (got: $PLATFORM)" >&2; exit 1 ;; esac
case "$ACTION" in apply | delete) ;; *) echo "error: ACTION must be apply or delete (got: $ACTION)" >&2; exit 1 ;; esac
case "$MESH_MEMBER" in true | false) ;; *) echo "error: MESH_MEMBER must be true or false (got: $MESH_MEMBER)" >&2; exit 1 ;; esac
[[ "$ACTION" == delete ]] || : "${API_URL:?API_URL is required}"

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

if [[ "$PLATFORM" == kubernetes ]]; then
  if [[ -z "${KUBECONFIG_PATH:-}" ]] || [[ -z "${SPOKE_CONTEXT:-}" ]]; then
    echo "error: platform kubernetes needs KUBECONFIG_PATH and SPOKE_CONTEXT (the spoke's ServiceAccount is created through them)" >&2
    exit 1
  fi
  SKC=(kubectl "--kubeconfig=$KUBECONFIG_PATH" "--context=$SPOKE_CONTEXT" --request-timeout=60s)
  TOKEN_SECRET="${MANAGED_SA_NAME}-token"
  BINDING="${MANAGED_SA_NAME}-cluster-admin"
fi

# --- ACTION=delete (kubernetes): best effort, so a spoke that is already gone does not
# block the destroy; anything left behind is named with the command that removes it.
if [[ "$ACTION" == delete ]]; then
  if [[ "$PLATFORM" != kubernetes ]]; then
    echo "Nothing to delete on platform $PLATFORM (ACM removes the ManagedServiceAccount with the spoke)."
    exit 0
  fi
  # shellcheck disable=SC2086 # $KC is a word-split command, as everywhere in this script
  $KC --request-timeout=60s delete secret "$SECRET_NAME" -n "$GITOPS_NAMESPACE" --ignore-not-found ||
    echo "WARNING: could not delete the cluster Secret ${GITOPS_NAMESPACE}/${SECRET_NAME} on the hub (it holds a cluster-admin token for ${SPOKE_NAME}); delete it by hand" >&2
  "${SKC[@]}" delete clusterrolebinding "$BINDING" --ignore-not-found &&
    "${SKC[@]}" delete secret "$TOKEN_SECRET" -n "$SPOKE_SA_NAMESPACE" --ignore-not-found &&
    "${SKC[@]}" delete serviceaccount "$MANAGED_SA_NAME" -n "$SPOKE_SA_NAMESPACE" --ignore-not-found ||
    echo "WARNING: could not remove the ServiceAccount ${SPOKE_SA_NAMESPACE}/${MANAGED_SA_NAME}, its token Secret and the ClusterRoleBinding ${BINDING} on ${SPOKE_NAME}; if the cluster still exists, delete them by hand" >&2
  echo "Removed the Argo CD access to ${SPOKE_NAME}"
  exit 0
fi

# Build the Argo CD cluster config JSON (bearerToken + tlsClientConfig).
if [[ "$PLATFORM" == kubernetes ]]; then
  # The spoke's ServiceAccount and a long-lived token for it. A token Secret, not
  # `kubectl create token`: the API server caps requested token lifetimes on some
  # distributions, and an expired token would silently stop Argo CD and the ESO pushes.
  "${SKC[@]}" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${MANAGED_SA_NAME}
  namespace: ${SPOKE_SA_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: istio-scale-tests
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${BINDING}
  labels:
    app.kubernetes.io/part-of: istio-scale-tests
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: ${MANAGED_SA_NAME}
    namespace: ${SPOKE_SA_NAMESPACE}
---
apiVersion: v1
kind: Secret
metadata:
  name: ${TOKEN_SECRET}
  namespace: ${SPOKE_SA_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: istio-scale-tests
  annotations:
    kubernetes.io/service-account.name: ${MANAGED_SA_NAME}
type: kubernetes.io/service-account-token
EOF
  SPOKE_TOKEN_VALUE=""
  for _ in $(seq 1 30); do
    SPOKE_TOKEN_VALUE=$("${SKC[@]}" get secret "$TOKEN_SECRET" -n "$SPOKE_SA_NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null || true)
    [[ -n "$SPOKE_TOKEN_VALUE" ]] && break
    sleep 2
  done
  if [[ -z "$SPOKE_TOKEN_VALUE" ]]; then
    echo "error: the token controller did not fill ${SPOKE_SA_NAMESPACE}/${TOKEN_SECRET} on spoke ${SPOKE_NAME} within 60s" >&2
    exit 1
  fi
  SPOKE_TOKEN_VALUE=$(printf '%s' "$SPOKE_TOKEN_VALUE" | base64 --decode)

  # Trust what the kubeconfig trusts: its CA data, or the system roots when it has none.
  SPOKE_KC_JSON=$(kubectl --kubeconfig="$KUBECONFIG_PATH" config view --raw --minify --context="$SPOKE_CONTEXT" --flatten -o json)
  CA_DATA=$(echo "$SPOKE_KC_JSON" | jq -r '.clusters[0].cluster["certificate-authority-data"] // empty')
  INSECURE=$(echo "$SPOKE_KC_JSON" | jq -r '.clusters[0].cluster["insecure-skip-tls-verify"] // false')
  CONFIG_JSON=$(jq -nc --arg t "$SPOKE_TOKEN_VALUE" --arg ca "$CA_DATA" --argjson insecure "$INSECURE" \
    '{bearerToken: $t, tlsClientConfig: ({insecure: $insecure}
        + (if $ca != "" and ($insecure | not) then {caData: $ca} else {} end))}')
# Kubeconfig mode: extract client cert+key+CA from the spoke kubeconfig context.
# Token mode: use the spoke's ManagedServiceAccount token (long-lived, cluster-admin
#   via the MSA RBAC ManifestWork) and the external API CA chain.
elif [[ -n "${KUBECONFIG_PATH:-}" ]] && [[ -n "${SPOKE_CONTEXT:-}" ]]; then
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
MEMBER_LABEL=""
[[ "$MESH_MEMBER" == true ]] && MEMBER_LABEL='    istio-mesh-member: "true"'

# Apply the full Argo CD cluster Secret. `apply` is idempotent: it creates the
# secret on a fresh deploy and updates it (server/config/token refresh, the mesh-member
# label) on subsequent applies, adopting any pre-existing same-named secret.
$KC apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${GITOPS_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: cluster
${MEMBER_LABEL}
type: Opaque
data:
  name: ${NAME_B64}
  server: ${SERVER_B64}
  config: ${CONFIG_B64}
EOF

echo "Applied $SECRET_NAME with server=$API_URL (mesh member: $MESH_MEMBER)"

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
#     long-lived token Secret. Kubeconfig mode only. The namespace is created, with the label
#     istio-scale-tests/created-by, when it does not exist. When an earlier run put the
#     ServiceAccount in another namespace (the binding's subject says where), the binding
#     moves to the new one once its token exists, and the old ServiceAccount and token go
#     after the hub Secret carries the new token (the hub Secret itself is only ever updated).
#     ACTION=delete removes the cluster Secret, the spoke's ServiceAccount, binding and
#     token, and the namespace if this script created it (destroy).
#   openshift: the credential is the spoke's ACM ManagedServiceAccount. ACM's
#     GitOpsCluster is not used because it rewrites the server URL.
#
# Auth modes (via environment variables):
#   Kubeconfig: KUBECONFIG_PATH + HUB_CONTEXT + SPOKE_CONTEXT
#   Token:      HUB_TOKEN_SCRIPT + HUB_API_URL + HUB_ADMIN_PASS  (openshift; spoke auth via ManagedServiceAccount token)
#
# Required: SPOKE_NAME, GITOPS_NAMESPACE, MANAGED_SA_NAME, API_URL (except ACTION=delete)
# Optional: PLATFORM (kubernetes), ACTION (apply|delete), MESH_MEMBER (true|false),
#   SPOKE_SA_NAMESPACE (istio-scale-tests-access)

: "${SPOKE_NAME:?SPOKE_NAME is required}"
: "${GITOPS_NAMESPACE:?GITOPS_NAMESPACE is required}"
: "${MANAGED_SA_NAME:?MANAGED_SA_NAME is required}"
PLATFORM="${PLATFORM:-kubernetes}"
ACTION="${ACTION:-apply}"
MESH_MEMBER="${MESH_MEMBER:-false}"
SPOKE_SA_NAMESPACE="${SPOKE_SA_NAMESPACE:-istio-scale-tests-access}"

case "$PLATFORM" in kubernetes | openshift) ;; *) echo "error: PLATFORM must be kubernetes or openshift (got: $PLATFORM)" >&2; exit 1 ;; esac
case "$ACTION" in apply | delete) ;; *) echo "error: ACTION must be apply or delete (got: $ACTION)" >&2; exit 1 ;; esac
case "$MESH_MEMBER" in true | false) ;; *) echo "error: MESH_MEMBER must be true or false (got: $MESH_MEMBER)" >&2; exit 1 ;; esac
[[ "$SPOKE_SA_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "error: SPOKE_SA_NAMESPACE must be a namespace name (got: $SPOKE_SA_NAMESPACE)" >&2; exit 1; }
[[ "$ACTION" == delete ]] || : "${API_URL:?API_URL is required}"

# Every hub call gets the same request timeout as the spoke calls (SKC below).
if [[ -n "${KUBECONFIG_PATH:-}" ]] && [[ -n "${HUB_CONTEXT:-}" ]]; then
  KC="kubectl --kubeconfig=$KUBECONFIG_PATH --context=$HUB_CONTEXT --request-timeout=60s"
elif [[ -n "${HUB_TOKEN_SCRIPT:-}" ]] && [[ -n "${HUB_API_URL:-}" ]] && [[ -n "${HUB_ADMIN_PASS:-}" ]]; then
  HUB_TOKEN=$("$HUB_TOKEN_SCRIPT" "$HUB_API_URL" "cluster-admin" "$HUB_ADMIN_PASS" | jq -r '.status.token')
  KC="kubectl --server=$HUB_API_URL --token=$HUB_TOKEN --insecure-skip-tls-verify --request-timeout=60s"
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

# What this script creates on a spoke carries OWNED_LABEL; a namespace it created also
# CREATED_BY_LABEL, and only such a namespace is ever deleted.
OWNED_LABEL="app.kubernetes.io/part-of=istio-scale-tests"
CREATED_BY_LABEL="istio-scale-tests/created-by=create-argocd-cluster-secret"

# delete_created_namespace <ns>: delete <ns> on the spoke only when this script created it
# (never kube-system), and wait until it is gone: objects cannot be created in a terminating
# namespace, so a re-apply would fail. Returns 1 when that fails or takes over 120s.
delete_created_namespace() {
  local ns="$1" ours left i
  [[ "$ns" != kube-system ]] || return 0
  ours=$("${SKC[@]}" get namespaces -l "$CREATED_BY_LABEL" --field-selector "metadata.name=${ns}" -o name) || return 1
  [[ -n "$ours" ]] || return 0
  "${SKC[@]}" delete namespace "$ns" --wait=false || return 1
  for ((i = 0; i < 60; i++)); do
    left=$("${SKC[@]}" get namespace "$ns" --ignore-not-found -o name) || return 1
    [[ -n "$left" ]] || return 0
    sleep 2
  done
  echo "the namespace ${ns} on ${SPOKE_NAME} is still terminating after 120s" >&2
  return 1
}

# --- ACTION=delete (kubernetes): best effort, so a spoke that is already gone does not
# block the destroy; anything left behind is named with the command that removes it.
if [[ "$ACTION" == delete ]]; then
  if [[ "$PLATFORM" != kubernetes ]]; then
    echo "Nothing to delete on platform $PLATFORM (ACM removes the ManagedServiceAccount with the spoke)."
    exit 0
  fi
  left=""
  # shellcheck disable=SC2086 # $KC is a word-split command, as everywhere in this script
  if ! $KC delete secret "$SECRET_NAME" -n "$GITOPS_NAMESPACE" --ignore-not-found; then
    left=1
    echo "WARNING: could not delete the cluster Secret ${GITOPS_NAMESPACE}/${SECRET_NAME} on the hub (it holds a cluster-admin token for ${SPOKE_NAME}); delete it by hand" >&2
  fi
  if ! { "${SKC[@]}" delete clusterrolebinding "$BINDING" --ignore-not-found &&
    "${SKC[@]}" delete secret "$TOKEN_SECRET" -n "$SPOKE_SA_NAMESPACE" --ignore-not-found &&
    "${SKC[@]}" delete serviceaccount "$MANAGED_SA_NAME" -n "$SPOKE_SA_NAMESPACE" --ignore-not-found &&
    delete_created_namespace "$SPOKE_SA_NAMESPACE"; }; then
    left=1
    echo "WARNING: could not remove the ServiceAccount ${SPOKE_SA_NAMESPACE}/${MANAGED_SA_NAME}, its token Secret, the ClusterRoleBinding ${BINDING} and (if this script created it) the namespace ${SPOKE_SA_NAMESPACE} on ${SPOKE_NAME}; if the cluster still exists, delete them by hand" >&2
  fi
  if [[ -n "$left" ]]; then
    echo "Not all of the Argo CD access to ${SPOKE_NAME} was removed (WARNING above); exiting 0 so the destroy goes on"
  else
    echo "Removed the Argo CD access to ${SPOKE_NAME}"
  fi
  exit 0
fi

# Build the Argo CD cluster config JSON (bearerToken + tlsClientConfig).
OLD_SA_NAMESPACES=()
if [[ "$PLATFORM" == kubernetes ]]; then
  # The namespace: created (and labelled as created here) only when it does not exist, so
  # kube-system or a namespace someone else made is never claimed, and so never deleted.
  NS_PHASE=$("${SKC[@]}" get namespace "$SPOKE_SA_NAMESPACE" --ignore-not-found -o jsonpath='{.status.phase}')
  case "$NS_PHASE" in
  "")
    "${SKC[@]}" create -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${SPOKE_SA_NAMESPACE}
  labels:
    ${OWNED_LABEL%%=*}: ${OWNED_LABEL#*=}
    ${CREATED_BY_LABEL%%=*}: ${CREATED_BY_LABEL#*=}
EOF
    echo "Created the namespace ${SPOKE_SA_NAMESPACE} on ${SPOKE_NAME} (label ${CREATED_BY_LABEL})"
    ;;
  Terminating)
    echo "error: the namespace ${SPOKE_SA_NAMESPACE} on spoke ${SPOKE_NAME} is being deleted (an earlier destroy?); re-run the apply once 'kubectl --context ${SPOKE_CONTEXT} get namespace ${SPOKE_SA_NAMESPACE}' finds nothing" >&2
    exit 1
    ;;
  esac

  # Where an earlier run put the ServiceAccount: the subjects of this script's binding (a
  # binding of that name without OWNED_LABEL is not ours, and its subjects are left alone).
  SUBJECTS=$("${SKC[@]}" get clusterrolebinding -l "$OWNED_LABEL" --field-selector "metadata.name=${BINDING}" \
    -o jsonpath='{range .items[*].subjects[*]}{.kind} {.namespace} {.name}{"\n"}{end}')
  while read -r kind ns name; do
    [[ "$kind" == ServiceAccount && "$name" == "$MANAGED_SA_NAME" && -n "$ns" && "$ns" != "$SPOKE_SA_NAMESPACE" ]] &&
      OLD_SA_NAMESPACES+=("$ns")
  done <<<"$SUBJECTS"

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
  for ((i = 0; i < 30; i++)); do
    SPOKE_TOKEN_VALUE=$("${SKC[@]}" get secret "$TOKEN_SECRET" -n "$SPOKE_SA_NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null || true)
    [[ -n "$SPOKE_TOKEN_VALUE" ]] && break
    sleep 2
  done
  if [[ -z "$SPOKE_TOKEN_VALUE" ]]; then
    echo "error: the token controller did not fill ${SPOKE_SA_NAMESPACE}/${TOKEN_SECRET} on spoke ${SPOKE_NAME} within 60s" >&2
    exit 1
  fi
  SPOKE_TOKEN_VALUE=$(printf '%s' "$SPOKE_TOKEN_VALUE" | base64 --decode)

  # The binding last: only now does it move off an old ServiceAccount, so a failure above
  # leaves the old access working.
  "${SKC[@]}" apply -f - <<EOF
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
EOF

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
  SPOKE_TOKEN_VALUE=$(kubectl --kubeconfig="$KUBECONFIG_PATH" --context="$SPOKE_CONTEXT" --request-timeout=60s \
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

# remove_old_access <ns>: the ServiceAccount moved out of <ns> (spoke_service_account_namespace
# changed), and the binding and the hub Secret now use the new one. Delete the old token
# Secret and ServiceAccount (only with OWNED_LABEL) and <ns> if this script created it, and
# print one line for each: removed, not found, or left (no OWNED_LABEL, so not this script's).
remove_old_access() {
  local ns="$1" obj out
  for obj in "secret/${TOKEN_SECRET}" "serviceaccount/${MANAGED_SA_NAME}"; do
    # -o name prints <kind>/<name> for what it deleted (and "No resources found" otherwise).
    out=$("${SKC[@]}" delete "${obj%%/*}" -n "$ns" -l "$OWNED_LABEL" --field-selector "metadata.name=${obj#*/}" -o name) || return 1
    if grep -qxF "$obj" <<<"$out"; then
      echo "removed ${ns}/${obj#*/}"
      continue
    fi
    out=$("${SKC[@]}" get "$obj" -n "$ns" --ignore-not-found -o name) || return 1
    if [[ -n "$out" ]]; then
      echo "left ${ns}/${obj#*/}, which lacks the label ${OWNED_LABEL}"
    else
      echo "${ns}/${obj#*/} was not found"
    fi
  done
  # Prints kubectl's own line only when it deleted the namespace.
  out=$(delete_created_namespace "$ns") || return 1
  [[ -z "$out" ]] || echo "removed the namespace ${ns}, which this script created"
}

# Best effort: the new access already works, so a failure here only leaves the old objects.
if ((${#OLD_SA_NAMESPACES[@]} > 0)); then
  ERR_FILE=$(mktemp)
  trap 'rm -f "$ERR_FILE"' EXIT
  for ns in "${OLD_SA_NAMESPACES[@]}"; do
    if DONE=$(remove_old_access "$ns" 2>"$ERR_FILE"); then
      echo "Moved the ServiceAccount ${MANAGED_SA_NAME} on ${SPOKE_NAME} from ${ns} to ${SPOKE_SA_NAMESPACE}; ${DONE//$'\n'/; }"
    else
      echo "WARNING: the ServiceAccount ${MANAGED_SA_NAME} on ${SPOKE_NAME} moved from ${ns} to ${SPOKE_SA_NAMESPACE}, but removing the old one failed: $(tr '\n' ' ' <"$ERR_FILE")" >&2
      echo "WARNING: delete them by hand: kubectl --context ${SPOKE_CONTEXT} -n ${ns} delete secret ${TOKEN_SECRET}; kubectl --context ${SPOKE_CONTEXT} -n ${ns} delete serviceaccount ${MANAGED_SA_NAME} (and the namespace ${ns} if it has the label ${CREATED_BY_LABEL})" >&2
    fi
  done
fi

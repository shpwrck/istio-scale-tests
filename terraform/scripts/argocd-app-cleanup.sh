#!/usr/bin/env bash
set -euo pipefail

# Cascade-delete all Argo CD Applications and ApplicationSets before terraform destroy.
#
# Auth modes (via environment variables):
#   Kubeconfig: KUBECONFIG_PATH + KUBE_CONTEXT
#   Token:      TOKEN_SCRIPT + API_URL + ADMIN_PASS
#
# Required: GITOPS_NS
#
# Also accepts positional args for backwards compatibility:
#   argocd-app-cleanup.sh <token_script> <api_url> <admin_pass> <gitops_namespace>

if [[ $# -ge 4 ]]; then
  TOKEN_SCRIPT="${1}"
  API_URL="${2}"
  ADMIN_PASS="${3}"
  GITOPS_NS="${4}"
  export TOKEN_SCRIPT API_URL ADMIN_PASS GITOPS_NS
fi

: "${GITOPS_NS:?GITOPS_NS is required}"

if [[ -n "${KUBECONFIG_PATH:-}" ]] && [[ -n "${KUBE_CONTEXT:-}" ]]; then
  KC="kubectl --kubeconfig=$KUBECONFIG_PATH --context=$KUBE_CONTEXT"
elif [[ -n "${TOKEN_SCRIPT:-}" ]] && [[ -n "${API_URL:-}" ]] && [[ -n "${ADMIN_PASS:-}" ]]; then
  TOKEN=$("$TOKEN_SCRIPT" "$API_URL" "cluster-admin" "$ADMIN_PASS" | jq -r '.status.token')
  KC="kubectl --server=$API_URL --token=$TOKEN --insecure-skip-tls-verify"
else
  echo "error: set KUBECONFIG_PATH+KUBE_CONTEXT or TOKEN_SCRIPT+API_URL+ADMIN_PASS" >&2
  exit 1
fi

echo "=== Deleting hub-gitops-root Application (cascade via finalizer) ==="
$KC delete application.argoproj.io "hub-gitops-root" -n "$GITOPS_NS" --wait=false 2>/dev/null || true

echo "=== Waiting for Applications and ApplicationSets to be cleaned up (timeout: 600s) ==="
ELAPSED=0
while [ $ELAPSED -lt 600 ]; do
  APPS=$($KC get applications.argoproj.io -n "$GITOPS_NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
  APPSETS=$($KC get applicationsets.argoproj.io -n "$GITOPS_NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
  TOTAL=$((APPS + APPSETS))
  if [ "$TOTAL" -eq 0 ]; then
    echo "  All Applications and ApplicationSets removed."
    exit 0
  fi
  echo "  $TOTAL resources remaining (apps=$APPS, appsets=$APPSETS). Waiting 10s..."
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

echo "WARNING: Timeout. Force-clearing finalizers on remaining resources..."
for app in $($KC get applications.argoproj.io -n "$GITOPS_NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  $KC patch application.argoproj.io "$app" -n "$GITOPS_NS" --type=json \
    -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
  $KC delete application.argoproj.io "$app" -n "$GITOPS_NS" --wait=false 2>/dev/null || true
done
for appset in $($KC get applicationsets.argoproj.io -n "$GITOPS_NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  $KC delete applicationset.argoproj.io "$appset" -n "$GITOPS_NS" --wait=false 2>/dev/null || true
done
echo "=== ArgoCD Application cleanup complete ==="

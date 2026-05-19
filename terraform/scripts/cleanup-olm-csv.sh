#!/usr/bin/env bash
set -euo pipefail

# Delete an OLM Subscription and its ClusterServiceVersions on destroy.
# Deletes the Subscription first so OLM does not recreate the CSV.
#
# Auth modes (via environment variables):
#   Kubeconfig: KUBECONFIG_PATH + KUBE_CONTEXT
#   Token:      TOKEN_SCRIPT + API_URL + ADMIN_PASS
#
# Required: SUB_NAMESPACE, SUB_NAME, PACKAGE_NAME

# Also accept positional args for backwards compatibility
if [[ $# -ge 6 ]]; then
  TOKEN_SCRIPT="${1}"
  API_URL="${2}"
  ADMIN_PASS="${3}"
  SUB_NAMESPACE="${4}"
  SUB_NAME="${5}"
  PACKAGE_NAME="${6}"
  export TOKEN_SCRIPT API_URL ADMIN_PASS SUB_NAMESPACE SUB_NAME PACKAGE_NAME
fi

: "${SUB_NAMESPACE:?SUB_NAMESPACE is required}"
: "${SUB_NAME:?SUB_NAME is required}"
: "${PACKAGE_NAME:?PACKAGE_NAME is required}"

if [[ -n "${KUBECONFIG_PATH:-}" ]] && [[ -n "${KUBE_CONTEXT:-}" ]]; then
  KC="kubectl --kubeconfig=$KUBECONFIG_PATH --context=$KUBE_CONTEXT"
elif [[ -n "${TOKEN_SCRIPT:-}" ]] && [[ -n "${API_URL:-}" ]] && [[ -n "${ADMIN_PASS:-}" ]]; then
  TOKEN=$("$TOKEN_SCRIPT" "$API_URL" "cluster-admin" "$ADMIN_PASS" | jq -r '.status.token')
  KC="kubectl --server=$API_URL --token=$TOKEN --insecure-skip-tls-verify"
else
  echo "error: set KUBECONFIG_PATH+KUBE_CONTEXT or TOKEN_SCRIPT+API_URL+ADMIN_PASS" >&2
  exit 1
fi

echo "=== Deleting Subscription $SUB_NAME in $SUB_NAMESPACE ==="
$KC delete subscription.operators.coreos.com "$SUB_NAME" -n "$SUB_NAMESPACE" --wait=false 2>/dev/null || true

echo "Waiting 10s for OLM to settle..."
sleep 10

echo "=== Deleting CSVs matching '$PACKAGE_NAME' in $SUB_NAMESPACE ==="
CSVS=$($KC get csv -n "$SUB_NAMESPACE" -o name 2>/dev/null | grep "$PACKAGE_NAME" || true)
if [ -z "$CSVS" ]; then
  echo "No CSVs matching '$PACKAGE_NAME' in $SUB_NAMESPACE — nothing to clean up."
  exit 0
fi

echo "$CSVS" | while read -r csv; do
  echo "Deleting $csv in $SUB_NAMESPACE..."
  $KC delete "$csv" -n "$SUB_NAMESPACE" --wait=false 2>/dev/null || true
done
echo "CSV cleanup complete for $PACKAGE_NAME."

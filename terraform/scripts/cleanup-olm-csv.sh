#!/usr/bin/env bash
set -euo pipefail

# Delete an OLM Subscription and its ClusterServiceVersions on destroy.
# Deletes the Subscription first so OLM does not recreate the CSV.
# Usage: cleanup-olm-csv.sh <token_script> <api_url> <admin_pass> <sub_namespace> <sub_name> <package_name>

TOKEN_SCRIPT="${1:?usage: $0 <token_script> <api_url> <admin_pass> <sub_namespace> <sub_name> <package_name>}"
API_URL="${2:?}"
ADMIN_PASS="${3:?}"
SUB_NS="${4:?}"
SUB_NAME="${5:?}"
PACKAGE="${6:?}"

TOKEN=$("$TOKEN_SCRIPT" "$API_URL" "cluster-admin" "$ADMIN_PASS" | jq -r '.status.token')
KC="kubectl --server=$API_URL --token=$TOKEN --insecure-skip-tls-verify"

echo "=== Deleting Subscription $SUB_NAME in $SUB_NS ==="
$KC delete subscription.operators.coreos.com "$SUB_NAME" -n "$SUB_NS" --wait=false 2>/dev/null || true

echo "Waiting 10s for OLM to settle..."
sleep 10

echo "=== Deleting CSVs matching '$PACKAGE' in $SUB_NS ==="
CSVS=$($KC get csv -n "$SUB_NS" -o name 2>/dev/null | grep "$PACKAGE" || true)
if [ -z "$CSVS" ]; then
  echo "No CSVs matching '$PACKAGE' in $SUB_NS — nothing to clean up."
  exit 0
fi

echo "$CSVS" | while read -r csv; do
  echo "Deleting $csv in $SUB_NS..."
  $KC delete "$csv" -n "$SUB_NS" --wait=false 2>/dev/null || true
done
echo "CSV cleanup complete for $PACKAGE."

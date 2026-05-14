#!/usr/bin/env bash
set -euo pipefail

# Delete OLM ClusterServiceVersions for a given operator package on destroy.
# Usage: cleanup-olm-csv.sh <token_script> <api_url> <admin_pass> <csv_namespace> <package_name>

TOKEN_SCRIPT="${1:?usage: $0 <token_script> <api_url> <admin_pass> <csv_namespace> <package_name>}"
API_URL="${2:?}"
ADMIN_PASS="${3:?}"
CSV_NS="${4:?}"
PACKAGE="${5:?}"

TOKEN=$("$TOKEN_SCRIPT" "$API_URL" "cluster-admin" "$ADMIN_PASS" | jq -r '.status.token')
KC="kubectl --server=$API_URL --token=$TOKEN --insecure-skip-tls-verify"

CSVS=$($KC get csv -n "$CSV_NS" -o name 2>/dev/null | grep "$PACKAGE" || true)
if [ -z "$CSVS" ]; then
  echo "No CSVs matching '$PACKAGE' in $CSV_NS — nothing to clean up."
  exit 0
fi

echo "$CSVS" | while read -r csv; do
  echo "Deleting $csv in $CSV_NS..."
  $KC delete "$csv" -n "$CSV_NS" --wait=false 2>/dev/null || true
done
echo "CSV cleanup complete for $PACKAGE."

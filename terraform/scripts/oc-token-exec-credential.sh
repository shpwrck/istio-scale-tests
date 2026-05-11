#!/usr/bin/env bash
set -euo pipefail

# Obtain an OpenShift OAuth bearer token and emit ExecCredential JSON
# for the Terraform kubernetes/helm provider exec plugin.
#
# Usage:  oc-token-exec-credential.sh <api_server_url> <username> <password>

API_SERVER="${1:?usage: $0 <api_server_url> <username> <password>}"
USERNAME="${2:?usage: $0 <api_server_url> <username> <password>}"
PASSWORD="${3:?usage: $0 <api_server_url> <username> <password>}"

oauth_authorize=$(curl -sk "${API_SERVER}/.well-known/oauth-authorization-server" \
  | jq -r '.authorization_endpoint')

location=$(curl -sk -u "${USERNAME}:${PASSWORD}" \
  "${oauth_authorize}?client_id=openshift-challenging-client&response_type=token" \
  -H "X-CSRF-Token: 1" \
  -D - -o /dev/null 2>/dev/null \
  | grep -i '^location:')

token=$(echo "$location" | sed -n 's/.*access_token=\([^&]*\).*/\1/p' | tr -d '\r')

if [[ -z "${token}" ]]; then
  echo "ERROR: failed to obtain OAuth token from ${API_SERVER}" >&2
  exit 1
fi

cat <<EOF
{
  "apiVersion": "client.authentication.k8s.io/v1beta1",
  "kind": "ExecCredential",
  "status": {
    "token": "${token}"
  }
}
EOF

#!/usr/bin/env bash
# Reads SPEC JSON from env (cluster list + current_context). Writes merged kubeconfig to OUT.
# Needs: bash, curl, jq, kubectl
set -euo pipefail

: "${OUT:?}"
: "${SPEC:?}"
: "${SCRIPTDIR:?}"

command -v kubectl >/dev/null || {
  echo "kubectl is required to assemble kubeconfig (install kubectl or oc with kubectl symlink)." >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export KUBECONFIG="${TMP}/empty"
touch "$KUBECONFIG"

CUR="$(echo "$SPEC" | jq -r .current_context)"

while IFS= read -r row; do
  key="$(echo "$row" | jq -r .key)"
  api="$(echo "$row" | jq -r .api_url)"
  insecure="$(echo "$row" | jq -r .insecure)"
  ca_b64="$(echo "$row" | jq -r .ca_b64)"

  tok_json="$(echo "$row" | jq '{api_url,cluster_domain,username,password}' | bash "${SCRIPTDIR}/openshift-token-from-password.sh")"
  tok="$(echo "$tok_json" | jq -r .token)"

  cred="rosa-admin-${key}"
  if [[ "$insecure" == "true" ]]; then
    kubectl config set-cluster "$key" --server="$api" --insecure-skip-tls-verify=true >/dev/null
  else
    caf="${TMP}/ca-${key}.pem"
    echo "$ca_b64" | base64 -d >"$caf"
    kubectl config set-cluster "$key" --server="$api" --certificate-authority="$caf" --embed-certs=true >/dev/null
  fi
  kubectl config set-credentials "$cred" --token="$tok" >/dev/null
  kubectl config set-context "$key" --cluster="$key" --user="$cred" --namespace=default >/dev/null
done < <(echo "$SPEC" | jq -c '.clusters[]')

kubectl config use-context "$CUR" >/dev/null
kubectl config view --flatten >"${TMP}/final.yaml"
cp "${TMP}/final.yaml" "$OUT"
chmod 600 "$OUT"

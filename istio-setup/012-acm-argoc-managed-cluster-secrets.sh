#!/usr/bin/env bash
# Patch ACM-created Argo CD cluster Secrets (*-application-manager-cluster-secret) so the hub can reach spoke APIs from pods:
#   - data.server = ManagedCluster.spec.managedClusterClientConfigs[0].url (public ROSA API; not internal *.control-plane hostnames)
#   - data.config = JSON { bearerToken, tlsClientConfig } from local kubeconfig (oc whoami -t --context <cluster>)
#
# Run on a workstation whose kubeconfig has hub context + one context per ManagedCluster name (e.g. rosa-002).
# GitOps / multicloud operators may overwrite these secrets — re-run after addon reconcile if needed.
#
# Usage (repo root):
#   ./istio-setup/012-acm-argoc-managed-cluster-secrets.sh --hub-context rosa-001 [--gitops-namespace openshift-gitops] [--dry-run]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

die() { echo "error: $*" >&2; exit 1; }

HUB_CTX=""
DRY_RUN=0
NS="${GITOPS_NAMESPACE:-openshift-gitops}"

usage() {
	cat <<EOF
Usage: $(basename "$0") --hub-context NAME [options]

  --hub-context NAME    oc/kubectl context for the ACM hub (required).
  --gitops-namespace NS Namespace with Argo CD + ACM cluster secrets (default ${NS}).
  --dry-run             Print patches only.

Environment: GITOPS_NAMESPACE (default openshift-gitops).
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--hub-context)
		[[ -n "${2:-}" ]] || die "--hub-context requires a value"
		HUB_CTX="$2"
		shift 2
		;;
	--gitops-namespace)
		[[ -n "${2:-}" ]] || die "--gitops-namespace requires a value"
		NS="$2"
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown option: $1"
		;;
	esac
done

[[ -n "$HUB_CTX" ]] || die "pass --hub-context"

command -v oc >/dev/null 2>&1 || die "oc not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

build_config_b64() {
	local ctx="$1"
	local token
	token="$(oc whoami -t --context "$ctx")" || die "cannot read token for context ${ctx} (log in)"
	jq -nc --arg t "$token" '{bearerToken: $t, tlsClientConfig: {insecure: false}}' | base64 -w0
}

secrets="$(oc --context "$HUB_CTX" get secrets -n "$NS" -l apps.open-cluster-management.io/acm-cluster=true -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
[[ -n "$secrets" ]] || die "no ACM cluster secrets in ${NS} (label apps.open-cluster-management.io/acm-cluster=true)"

while IFS= read -r secname; do
	[[ -z "$secname" ]] && continue
	case "$secname" in
	*-application-manager-cluster-secret) ;;
	*) continue ;;
	esac

	mc="$(oc --context "$HUB_CTX" get secret "$secname" -n "$NS" -o jsonpath='{.metadata.labels.apps\.open-cluster-management\.io/cluster-name}' 2>/dev/null || true)"
	[[ -n "$mc" ]] || die "secret ${secname}: missing cluster-name label"

	url="$(oc --context "$HUB_CTX" get managedcluster "$mc" -o jsonpath='{.spec.managedClusterClientConfigs[0].url}' 2>/dev/null || true)"
	[[ -n "$url" ]] || die "ManagedCluster ${mc}: no managedClusterClientConfigs[0].url"

	cfg64="$(build_config_b64 "$mc")"
	srv64="$(echo -n "$url" | base64 -w0)"

	echo "### ${secname} -> server=${url} tokenContext=${mc}"
	if ((DRY_RUN)); then
		continue
	fi
	oc --context "$HUB_CTX" patch secret "$secname" -n "$NS" --type merge -p "{\"data\":{\"server\":\"${srv64}\",\"config\":\"${cfg64}\"}}"
done <<<"$secrets"

if ((DRY_RUN)); then
	echo "dry-run: done."
	exit 0
fi

echo "Restarting Argo CD application controller (reloads cluster secrets)..."
oc --context "$HUB_CTX" delete pod -n "$NS" -l app.kubernetes.io/name=openshift-gitops-application-controller --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
echo "Done."
exit 0

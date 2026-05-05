#!/usr/bin/env bash
# Install OpenShift GitOps on the ACM hub (Helm), wait until Argo CD is ready, apply hub Argo “app of apps” + cert-manager (Helm), then apply RHACM GitOps wiring (Helm):
# ManagedClusterSetBinding, Placement (all clusters in the set except the hub / local-cluster), GitOpsCluster — and wait for success.
# Optionally patch ACM-created Argo cluster Secrets (public API URL + bearer token); RHACM often emits unusable internal URLs.
# Repo note: mesh CA / Istio lives under `istio-setup/` (starts at 001-ossm-mc-cacerts.sh). Hub cert-manager samples: `manifests/cert-manager-samples/`. Hub Argo: `charts/gitops-hub-app-of-apps` installs `hub-gitops-root` (directory-sync `charts/gitops-hub-apps/applications`); child Applications include `hub-acm-openshift-gitops-resources` (default: `charts/acm-openshift-gitops-resources` when `GITOPS_ACM_RESOURCES_VIA_ARGO=1`) and charts under `charts/cert-manager-operator`, `charts/hub-mesh-ca`, `charts/hub-mesh-ca-intermediate`, `charts/gitops-hub-mesh-ca-intermediate-appset`, `charts/external-secrets-operator`, `charts/gitops-hub-external-secrets-operator-appset`. This script is `platform-setup/002` (after `platform-setup/001` ACM hub).
#
# Ref: https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/gitops/gitops-overview
# Prerequisites: RHACM hub (`platform-setup/001`); spokes in ManagedClusterSet ${ACM_CLUSTER_SET} (cluster.open-cluster-management.io/clusterset label from hub install).
#
# Usage (repo root):
#   ./platform-setup/002-acm-openshift-gitops.sh [--context NAME] [--terraform-dir DIR] [--dry-run] [--skip-wait]
#       [--skip-acm-gitops-resources] [--skip-hub-app-of-apps] [--skip-argocd-applicationset-any-namespace] [--skip-argocd-applicationset-source-namespaces] [--hub-app-repo-url URL] [--gitops-repo-token-file PATH] [--merge-kubeconfig]
#       [--local-cluster-name NAME] [--skip-argoc-cluster-secret-fix] [--gitops-namespace NS]
#   ./platform-setup/002-acm-openshift-gitops.sh --patch-argoc-cluster-secrets-only --context NAME [--dry-run] [--gitops-namespace NS]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

die() { echo "error: $*" >&2; exit 1; }

# Map common SSH clone URLs to HTTPS so Argo CD on-cluster can fetch without SSH keys.
normalize_git_clone_url_to_https() {
	local u="$1"
	case "$u" in
	git@github.com:*)
		echo "https://github.com/${u#git@github.com:}"
		return 0
		;;
	ssh://git@github.com/*)
		echo "https://github.com/${u#ssh://git@github.com/}"
		return 0
		;;
	git@gitlab.com:*)
		echo "https://gitlab.com/${u#git@gitlab.com:}"
		return 0
		;;
	*)
		echo "$u"
		;;
	esac
}

CONTEXT=""
LOCAL_CLUSTER_NAME_OVERRIDE=""
DRY_RUN=0
SKIP_WAIT=0
SKIP_ACM_GITOPS_RESOURCES=0
SKIP_ARGO_CLUSTER_SECRET_FIX=0
PATCH_ARGO_CLUSTER_SECRETS_ONLY=0
SKIP_HUB_APP_OF_APPS=0
SKIP_APPLICATION_SET_SOURCE_NS=0
SKIP_APPLICATION_SET_ANY_NAMESPACE=0
HUB_APP_REPO_URL_CLI=""
HUB_APP_REPO_TOKEN_FILE_CLI=""
MERGE_KUBECONFIG=0
TF_DIR="${ACM_TERRAFORM_DIR:-${ROOT}/terraform/rosa-hcp}"
TF_LOGIN_SCRIPT="${ROOT}/terraform/scripts/001-oc-login-merge-kubeconfig.sh"
MC_KUBECONFIG=""
INSECURE_LOGIN=()

GITOPS_NAMESPACE="${GITOPS_NAMESPACE:-openshift-gitops}"
GITOPS_OPERATOR_NAMESPACE="${GITOPS_OPERATOR_NAMESPACE:-openshift-operators}"
GITOPS_HELM_RELEASE="${GITOPS_HELM_RELEASE:-openshift-gitops-operator}"
GITOPS_RESOURCES_RELEASE="${GITOPS_RESOURCES_RELEASE:-acm-openshift-gitops-resources}"
GITOPS_HUB_APP_OF_APPS_RELEASE="${GITOPS_HUB_APP_OF_APPS_RELEASE:-gitops-hub-app-of-apps}"
GITOPS_APP_REPO_URL="${GITOPS_APP_REPO_URL:-}"
GITOPS_APP_REPO_REVISION="${GITOPS_APP_REPO_REVISION:-main}"

# When unset, use this clone's origin URL so hub Argo Applications point at the same repo.
# Map SSH remotes to HTTPS unless using SSH deploy keys (GITOPS_APP_REPO_SSH_PRIVATE_KEY_FILE or GITOPS_APP_REPO_PREFER_SSH=1).
if [[ -z "${GITOPS_APP_REPO_URL}" ]] && git -C "${ROOT}" rev-parse --git-dir &>/dev/null; then
	GITOPS_APP_REPO_URL="$(git -C "${ROOT}" remote get-url origin 2>/dev/null || true)"
	if [[ "${GITOPS_APP_REPO_PREFER_SSH:-0}" != "1" && -z "${GITOPS_APP_REPO_SSH_PRIVATE_KEY_FILE:-}" ]]; then
		GITOPS_APP_REPO_URL="$(normalize_git_clone_url_to_https "${GITOPS_APP_REPO_URL}")"
	fi
fi

CHART_GITOPS_OPERATOR="${ROOT}/charts/openshift-gitops-operator"
CHART_ACM_GITOPS_RESOURCES="${ROOT}/charts/acm-openshift-gitops-resources"
CHART_HUB_APP_OF_APPS="${ROOT}/charts/gitops-hub-app-of-apps"
CHART_CERT_MANAGER_OPERATOR="${ROOT}/charts/cert-manager-operator"
CHART_GITOPS_HUB_APPS="${ROOT}/charts/gitops-hub-apps"
CHART_HUB_MESH_CA="${ROOT}/charts/hub-mesh-ca"
CHART_HUB_MESH_CA_INTERMEDIATE="${ROOT}/charts/hub-mesh-ca-intermediate"
CHART_GITOPS_HUB_MESH_CA_INTERMEDIATE_APPSET="${ROOT}/charts/gitops-hub-mesh-ca-intermediate-appset"
CHART_EXTERNAL_SECRETS_OPERATOR="${ROOT}/charts/external-secrets-operator"
CHART_GITOPS_HUB_EXTERNAL_SECRETS_OPERATOR_APPSET="${ROOT}/charts/gitops-hub-external-secrets-operator-appset"
GITOPS_APPSET_ANY_NS_MANIFEST_DIR="${ROOT}/platform-setup/manifests/gitops-appset-any-namespace"

ACM_CLUSTER_SET="${ACM_CLUSTER_SET:-istio-scale-tests}"
GITOPS_PLACEMENT_NAME="${GITOPS_PLACEMENT_NAME:-acm-openshift-gitops-placement}"
GITOPS_CLUSTER_CR_NAME="${GITOPS_CLUSTER_CR_NAME:-acm-openshift-gitops}"
# When 1 (default), charts/acm-openshift-gitops-resources is synced by Argo (hub-acm-openshift-gitops-resources Application); 002 patches Helm parameters from the environment. When 0, 002 installs that chart with Helm before hub-gitops-root so Argo can adopt the release.
GITOPS_ACM_RESOURCES_VIA_ARGO="${GITOPS_ACM_RESOURCES_VIA_ARGO:-1}"
HUB_ACM_GITOPS_APP_WAIT_SEC="${HUB_ACM_GITOPS_APP_WAIT_SEC:-600}"
GITOPS_ADDON_ENABLED="${GITOPS_ADDON_ENABLED:-true}"
GITOPS_CLUSTER_READY_WAIT_SEC="${GITOPS_CLUSTER_READY_WAIT_SEC:-1800}"
ARGOCD_STABILIZE_WAIT_SEC="${ARGOCD_STABILIZE_WAIT_SEC:-900}"
GITOPS_ADDON_FEATURE_WAIT_SEC="${GITOPS_ADDON_FEATURE_WAIT_SEC:-900}"

readonly _ACM_LOCAL_CLUSTER_NAME_MAX_LEN=34

cleanup_mc_kubeconfig() {
	if [[ -n "${MC_KUBECONFIG}" && -f "${MC_KUBECONFIG}" ]]; then
		rm -f "${MC_KUBECONFIG}" || true
	fi
	return 0
}
trap cleanup_mc_kubeconfig EXIT

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  Full install:
  1) Helm: charts/openshift-gitops-operator into ${GITOPS_OPERATOR_NAMESPACE}; wait for CSV + Argo CD instance to stabilize; configure Argo CD ApplicationSets — RHACM-style any-namespace (\`GITOPS_RHACM_APPSET_ANY_NAMESPACE\`: \`spec.applicationSet.enabled\`, controller env \`ARGOCD_APPLICATIONSET_CONTROLLER_NAMESPACES=*\`, ClusterRole/Binding from \`platform-setup/manifests/gitops-appset-any-namespace/\`) and optionally merge \`GITOPS_APPLICATION_SET_SOURCE_NAMESPACES\` into \`spec.applicationSet.sourceNamespaces\`.
  2a/2b) ACM GitOps resources: either Argo Application \`hub-acm-openshift-gitops-resources\` (default when \`GITOPS_ACM_RESOURCES_VIA_ARGO=1\` and hub-gitops-root can sync Git) or direct Helm (\`GITOPS_ACM_RESOURCES_VIA_ARGO=0\`, chart installed before hub-gitops-root). ManagedClusterSetBinding, Placement, GitOpsCluster; optional shared ApplicationSet placement ConfigMap.
  2c) Helm: charts/gitops-hub-app-of-apps — optional Argo CD repository Secret then Application hub-gitops-root (directory sync \`charts/gitops-hub-apps/applications\`; skipped if no repo URL / \`GITOPS_APP_REPO_URL\` defaults from \`git remote get-url origin\`).
  3) Wait for GitOpsCluster success + gitops-addon feature label on each ManagedCluster in ACM_CLUSTER_SET when applicable (skipped when no spokes unless GITOPS_FORCE_ACM_GITOPS_WAITS=1).
  4) Patch ACM Argo cluster Secrets (public API URL + bearer token) unless --skip-argoc-cluster-secret-fix.

  Patch only (e.g. after ACM/GitOps reconciles secrets): --patch-argoc-cluster-secrets-only --context HUB

  --context NAME              kube/oc context for the hub (recommended).
  --terraform-dir DIR         Terraform root for auto hub context / localClusterName (default: ${TF_DIR}).
  --dry-run                   Helm client dry-run for charts; with --patch-argoc-cluster-secrets-only, print patches only.
  --skip-wait                 Do not wait for CSV / Argo CD / GitOpsCluster readiness.
  --skip-acm-gitops-resources Install only the GitOps operator chart (skip ACM Placement / GitOpsCluster chart).
  --skip-hub-app-of-apps      Skip charts/gitops-hub-app-of-apps (Argo hub-gitops-root app-of-apps Application).
  --skip-argocd-applicationset-source-namespaces  Do not merge GITOPS_APPLICATION_SET_SOURCE_NAMESPACES into ArgoCD.spec.applicationSet.sourceNamespaces.
  --skip-argocd-applicationset-any-namespace     Do not apply RHACM ApplicationSet-in-any-namespace steps (ArgoCD env patch + ClusterRole/Binding); see GITOPS_RHACM_APPSET_ANY_NAMESPACE.
  --hub-app-repo-url URL      Override GITOPS_APP_REPO_URL for Argo CD Git source (HTTPS or SSH clone URL of this repo/fork).
  --gitops-repo-token-file PATH  Read HTTPS token from file (avoid env); stored only in the cluster Argo repo Secret. Same as GITOPS_APP_REPO_TOKEN_FILE.
  --skip-argoc-cluster-secret-fix  Skip step (4) after GitOpsCluster (RHACM may leave unusable internal *.control-plane URLs).
  --patch-argoc-cluster-secrets-only  Only patch ACM *-application-manager-cluster Secrets; requires hub --context (and spoke contexts in kubeconfig).
  --gitops-namespace NS       Operand namespace / Argo CD + ACM CRs (default ${GITOPS_NAMESPACE}).
  --merge-kubeconfig          Run terraform/scripts/001-oc-login-merge-kubeconfig.sh (same as platform-setup/001).
  --local-cluster-name NAME   Hub ManagedCluster name for GitOpsCluster.spec.argoServer.cluster (max ${_ACM_LOCAL_CLUSTER_NAME_MAX_LEN} chars).
  --insecure-skip-tls-verify  Forward to kubeconfig merge helper.

Environment:
  GITOPS_NAMESPACE              Operand namespace / Argo CD + ACM CRs (default ${GITOPS_NAMESPACE}).
  GITOPS_ARGOCD_CR_NAME         Argo CD custom resource name on the hub (default ${GITOPS_ARGOCD_CR_NAME:-openshift-gitops}).
  GITOPS_RHACM_APPSET_ANY_NAMESPACE  When 1 (default), run RHACM doc enable-gitops-appset equivalent: ArgoCD applicationSet controller env + manifests/gitops-appset-any-namespace RBAC. Set 0/false to skip.
  GITOPS_APPLICATION_SET_SOURCE_NAMESPACES  Comma-separated namespaces merged into ArgoCD.spec.applicationSet.sourceNamespaces (optional extra allowlist). Wildcards are not supported. Set empty to skip merge.
  GITOPS_OPERATOR_NAMESPACE     openshift-gitops-operator Subscription (default ${GITOPS_OPERATOR_NAMESPACE}).
  GITOPS_OPERATOR_CHANNEL       OLM channel (default ${GITOPS_OPERATOR_CHANNEL} from versions.env).
  GITOPS_HELM_RELEASE           Helm release for openshift-gitops-operator chart (default ${GITOPS_HELM_RELEASE}).
  GITOPS_RESOURCES_RELEASE       Helm release for acm-openshift-gitops-resources chart (default ${GITOPS_RESOURCES_RELEASE}).
  GITOPS_HUB_APP_OF_APPS_RELEASE Helm release for gitops-hub-app-of-apps chart (default ${GITOPS_HUB_APP_OF_APPS_RELEASE}).
  GITOPS_APP_REPO_URL           Git URL Argo CD uses for hub Application sources (HTTPS or SSH). When unset, defaults to this repository's \`origin\` remote (\`git remote get-url origin\` from repo root); SSH URLs are mapped to HTTPS for github.com / gitlab.com unless GITOPS_APP_REPO_PREFER_SSH=1 or GITOPS_APP_REPO_SSH_PRIVATE_KEY_FILE is set.
  GITOPS_APP_REPO_REVISION      Branch/tag/commit for hub Applications (default ${GITOPS_APP_REPO_REVISION}).
  GITOPS_APP_REPO_CREDENTIALS_SECRET_NAME  Name of Secret with label argocd.argoproj.io/secret-type=repository (default gitops-hub-app-repo).
  GITOPS_APP_REPO_USERNAME      HTTPS username (optional; defaults to git when using PAT/token).
  GITOPS_APP_REPO_PASSWORD      HTTPS password or PAT (prefer GITOPS_APP_REPO_TOKEN_FILE for CI).
  GITOPS_APP_REPO_TOKEN         Same as password for PAT-only flows.
  GITOPS_APP_REPO_TOKEN_FILE    Path to file containing token or PAT (newline trimmed).
  GITOPS_APP_REPO_SSH_PRIVATE_KEY_FILE  Path to SSH private key for Git over SSH; set GITOPS_APP_REPO_URL to matching SSH URL (or GITOPS_APP_REPO_PREFER_SSH=1 with SSH origin).
  GITOPS_APP_REPO_PREFER_SSH    When 1, default origin URL from git is not rewritten to HTTPS (use with SSH deploy keys).
  ACM_CLUSTER_SET               ManagedClusterSet for ManagedClusterSetBinding (default ${ACM_CLUSTER_SET}).
  GITOPS_PLACEMENT_NAME         Placement metadata.name → Helm --set placement.name (default ${GITOPS_PLACEMENT_NAME}).
  GITOPS_CLUSTER_CR_NAME        GitOpsCluster metadata.name → Helm --set gitopsCluster.name (default ${GITOPS_CLUSTER_CR_NAME}).
  GITOPS_ADDON_ENABLED          GitOpsCluster gitopsAddon.enabled (default ${GITOPS_ADDON_ENABLED}).
  GITOPS_CLUSTER_READY_WAIT_SEC Max wait for GitOpsCluster success (default ${GITOPS_CLUSTER_READY_WAIT_SEC}).
  ARGOCD_STABILIZE_WAIT_SEC     Max wait for Argo CD after CSV (default ${ARGOCD_STABILIZE_WAIT_SEC}).
  GITOPS_ADDON_FEATURE_WAIT_SEC Max wait for feature.open-cluster-management.io/addon-gitops-addon=available on each ManagedCluster in ACM_CLUSTER_SET (default ${GITOPS_ADDON_FEATURE_WAIT_SEC}).
  GITOPS_FORCE_ACM_GITOPS_WAITS   When 1, always run GitOpsCluster / per-ManagedCluster gitops-addon waits even if there are zero spoke ManagedClusters (hub-only). Default: those waits are skipped when no spokes match Placement (same as excluding the hub).

  GITOPS_ACM_RESOURCES_VIA_ARGO  When 1 (default), skip direct Helm for charts/acm-openshift-gitops-resources; Argo syncs it (see hub-acm-openshift-gitops-resources Application) and 002 patches Helm parameters. When 0, 002 installs that chart with Helm before hub-gitops-root.
  HUB_ACM_GITOPS_APP_WAIT_SEC   Max wait for Argo Application hub-acm-openshift-gitops-resources to appear before patching (default ${HUB_ACM_GITOPS_APP_WAIT_SEC}).

  Step (4) / patch-only mode requires kubeconfig contexts named like each spoke ManagedCluster (e.g. rosa-002); use --merge-kubeconfig or log in spokes first. Hub ManagedCluster cluster Secrets are not patched (kube context is the hub).
  ACM_HUB_CONTEXT               Default hub context when --context omitted.
  ACM_LOCAL_CLUSTER_NAME        Hub ManagedCluster name when --local-cluster-name omitted.

RHACM GitOps overview:
https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/gitops/gitops-overview
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--context)
		[[ -n "${2:-}" ]] || die "--context requires a value"
		CONTEXT="$2"
		shift 2
		;;
	--terraform-dir)
		[[ -n "${2:-}" ]] || die "--terraform-dir requires a value"
		TF_DIR="$2"
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--skip-wait)
		SKIP_WAIT=1
		shift
		;;
	--skip-acm-gitops-resources)
		SKIP_ACM_GITOPS_RESOURCES=1
		shift
		;;
	--skip-hub-app-of-apps)
		SKIP_HUB_APP_OF_APPS=1
		shift
		;;
	--skip-argocd-applicationset-source-namespaces)
		SKIP_APPLICATION_SET_SOURCE_NS=1
		shift
		;;
	--skip-argocd-applicationset-any-namespace)
		SKIP_APPLICATION_SET_ANY_NAMESPACE=1
		shift
		;;
	--hub-app-repo-url)
		[[ -n "${2:-}" ]] || die "--hub-app-repo-url requires a value"
		HUB_APP_REPO_URL_CLI="$2"
		shift 2
		;;
	--gitops-repo-token-file)
		[[ -n "${2:-}" ]] || die "--gitops-repo-token-file requires a path"
		HUB_APP_REPO_TOKEN_FILE_CLI="$2"
		shift 2
		;;
	--skip-argoc-cluster-secret-fix)
		SKIP_ARGO_CLUSTER_SECRET_FIX=1
		shift
		;;
	--patch-argoc-cluster-secrets-only)
		PATCH_ARGO_CLUSTER_SECRETS_ONLY=1
		shift
		;;
	--gitops-namespace)
		[[ -n "${2:-}" ]] || die "--gitops-namespace requires a value"
		GITOPS_NAMESPACE="$2"
		shift 2
		;;
	--merge-kubeconfig)
		MERGE_KUBECONFIG=1
		shift
		;;
	--local-cluster-name)
		[[ -n "${2:-}" ]] || die "--local-cluster-name requires a value"
		LOCAL_CLUSTER_NAME_OVERRIDE="$2"
		shift 2
		;;
	--insecure-skip-tls-verify)
		INSECURE_LOGIN+=(--insecure-skip-tls-verify)
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown option: $1 (try --help)"
		;;
	esac
done

# Env override: disable RHACM ApplicationSet-in-any-namespace block without passing --skip-argocd-applicationset-any-namespace.
case "${GITOPS_RHACM_APPSET_ANY_NAMESPACE:-1}" in
0 | false | False | FALSE | no | No | NO)
	SKIP_APPLICATION_SET_ANY_NAMESPACE=1
	;;
esac

command -v oc >/dev/null 2>&1 || {
	echo "error: oc not found" >&2
	exit 2
}
command -v jq >/dev/null 2>&1 || {
	echo "error: jq not found" >&2
	exit 2
}

build_argoc_cluster_secret_config_b64() {
	local ctx="$1"
	local token
	token="$(oc whoami -t --context "$ctx")" || die "cannot read token for context ${ctx} (log in)"
	jq -nc --arg t "$token" '{bearerToken: $t, tlsClientConfig: {insecure: false}}' | base64 -w0
}

patch_acm_argoc_managed_cluster_secrets() {
	local hub_ctx="$1"
	local ns="$2"
	local dry="$3"

	local secrets secname mc url cfg64 srv64
	secrets="$(oc --context "$hub_ctx" get secrets -n "$ns" -l apps.open-cluster-management.io/acm-cluster=true -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
	[[ -n "$secrets" ]] || die "no ACM cluster secrets in ${ns} (label apps.open-cluster-management.io/acm-cluster=true)"

	while IFS= read -r secname; do
		[[ -z "$secname" ]] && continue
		case "$secname" in
		*-application-manager-cluster-secret) ;;
		*) continue ;;
		esac

		mc="$(oc --context "$hub_ctx" get secret "$secname" -n "$ns" -o jsonpath='{.metadata.labels.apps\.open-cluster-management\.io/cluster-name}' 2>/dev/null || true)"
		[[ -n "$mc" ]] || die "secret ${secname}: missing cluster-name label"

		if [[ -n "${ACM_LOCAL_CLUSTER_NAME:-}" && "$mc" == "${ACM_LOCAL_CLUSTER_NAME}" ]]; then
			echo "### ${secname} -> skip (hub ManagedCluster ${mc}; Argo runs on-cluster)"
			continue
		fi

		url="$(oc --context "$hub_ctx" get managedcluster "$mc" -o jsonpath='{.spec.managedClusterClientConfigs[0].url}' 2>/dev/null || true)"
		[[ -n "$url" ]] || die "ManagedCluster ${mc}: no managedClusterClientConfigs[0].url"

		cfg64="$(build_argoc_cluster_secret_config_b64 "$mc")"
		srv64="$(echo -n "$url" | base64 -w0)"

		echo "### ${secname} -> server=${url} tokenContext=${mc}"
		if ((dry)); then
			continue
		fi
		oc --context "$hub_ctx" patch secret "$secname" -n "$ns" --type merge -p "{\"data\":{\"server\":\"${srv64}\",\"config\":\"${cfg64}\"}}"
	done <<<"$secrets"

	if ((dry)); then
		echo "dry-run: patch preview done."
		return 0
	fi

	echo "Restarting Argo CD application controller (reloads cluster secrets)..."
	oc --context "$hub_ctx" delete pod -n "$ns" -l app.kubernetes.io/name=openshift-gitops-application-controller --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
	echo "Argo cluster secret patch done."
}

normalize_url() {
	local u="$1"
	u="${u%/}"
	echo "$u"
}

# Argo CD matches repository Secrets to Application.spec.source.repoURL by URL prefix — use the same normalized URL for both.
normalize_git_repo_url_for_argo() {
	local u="$1"
	while [[ "$u" == */ ]]; do
		u="${u%/}"
	done
	case "$u" in
	https://github.com/* | http://github.com/* | https://gitlab.com/* | http://gitlab.com/*)
		if [[ "$u" == *.git ]]; then
			u="${u%.git}"
		fi
		;;
	esac
	echo "$u"
}

# Trim PAT/password for GitHub/GitLab (editor BOM, trailing newline/spaces break auth; private repos then return "not found").
trim_git_https_secret() {
	local s="$1"
	# UTF-8 BOM
	if [[ "${s:0:3}" == $'\xEF\xBB\xBF' ]]; then
		s="${s:3}"
	fi
	s="${s#"${s%%[![:space:]]*}"}"
	s="${s%"${s##*[![:space:]]}"}"
	printf '%s' "$s"
}

resolve_gitops_app_repo_https_password() {
	local raw="" tf=""
	if [[ -n "${GITOPS_APP_REPO_TOKEN:-}" ]]; then
		raw="${GITOPS_APP_REPO_TOKEN}"
	elif [[ -n "${GITOPS_APP_REPO_PASSWORD:-}" ]]; then
		raw="${GITOPS_APP_REPO_PASSWORD}"
	else
		tf="${HUB_APP_REPO_TOKEN_FILE_CLI:-}"
		[[ -n "$tf" ]] || tf="${GITOPS_APP_REPO_TOKEN_FILE:-}"
		if [[ -n "$tf" ]]; then
			[[ -f "$tf" ]] || die "GITOPS_APP_REPO_TOKEN_FILE not a readable file: ${tf}"
			raw="$(<"$tf")"
		fi
	fi
	[[ -z "$raw" ]] && return 0
	trim_git_https_secret "$(printf '%s' "$raw" | tr -d '\n\r')"
}

# Repo-server caches credentials; pick up new or fixed repository Secrets without waiting for a sync interval.
restart_openshift_gitops_repo_server() {
	if ((DRY_RUN)); then
		return 0
	fi
	if ! oc --context "$CTX" get deployment openshift-gitops-repo-server -n "$GITOPS_NAMESPACE" &>/dev/null; then
		return 0
	fi
	echo "Restarting openshift-gitops-repo-server so Argo CD reloads repository credentials..."
	oc --context "$CTX" rollout restart deployment openshift-gitops-repo-server -n "$GITOPS_NAMESPACE" >/dev/null \
		|| true
}

# Ref: https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#repositories
ensure_hub_argoc_git_repo_credentials() {
	local repo_url="$1"
	local secret_name="${GITOPS_APP_REPO_CREDENTIALS_SECRET_NAME:-gitops-hub-app-repo}"
	local ssh_file="${GITOPS_APP_REPO_SSH_PRIVATE_KEY_FILE:-}"
	local pass=""
	local user=""

	repo_url="$(normalize_git_repo_url_for_argo "$repo_url")"

	pass="$(resolve_gitops_app_repo_https_password)"
	user="${GITOPS_APP_REPO_USERNAME:-}"

	if [[ -n "$ssh_file" && -n "$pass" ]]; then
		die "use either GITOPS_APP_REPO_SSH_PRIVATE_KEY_FILE (SSH) or GITOPS_APP_REPO_TOKEN / GITOPS_APP_REPO_PASSWORD / token file (HTTPS), not both"
	fi
	if [[ -z "$ssh_file" && -z "$pass" ]]; then
		return 0
	fi

	if [[ -n "$ssh_file" ]]; then
		[[ -f "$ssh_file" ]] || die "GITOPS_APP_REPO_SSH_PRIVATE_KEY_FILE is not a readable file: ${ssh_file}"
		case "$repo_url" in
		git@* | ssh://*) ;;
		*)
			echo "warn: repo URL does not look like SSH — Argo CD repository Secrets must use the same URL form as Application.spec.source.repoURL; set GITOPS_APP_REPO_URL or GITOPS_APP_REPO_PREFER_SSH=1." >&2
			;;
		esac
		if ((DRY_RUN)); then
			echo "dry-run: would create/update Secret ${secret_name} (Argo CD repo credentials, SSH key from file, url=${repo_url})."
			return 0
		fi
		echo "Applying Argo CD repository credentials Secret ${secret_name} (SSH key, namespace ${GITOPS_NAMESPACE})..."
		oc --context "$CTX" create secret generic "$secret_name" -n "$GITOPS_NAMESPACE" \
			--from-literal=type=git \
			--from-literal=url="$repo_url" \
			--from-file=sshPrivateKey="$ssh_file" \
			--dry-run=client -o yaml | oc --context "$CTX" apply -f -
		oc --context "$CTX" label secret "$secret_name" -n "$GITOPS_NAMESPACE" \
			argocd.argoproj.io/secret-type=repository --overwrite
		restart_openshift_gitops_repo_server
		return 0
	fi

	[[ -n "$pass" ]] || return 0
	[[ -n "$user" ]] || user="git"
	if ((DRY_RUN)); then
		echo "dry-run: would create/update Secret ${secret_name} (Argo CD repo credentials, HTTPS token/password, url=${repo_url})."
		return 0
	fi
	echo "Applying Argo CD repository credentials Secret ${secret_name} (HTTPS token, namespace ${GITOPS_NAMESPACE})..."
	oc --context "$CTX" create secret generic "$secret_name" -n "$GITOPS_NAMESPACE" \
		--from-literal=type=git \
		--from-literal=url="$repo_url" \
		--from-literal=username="$user" \
		--from-literal=password="$pass" \
		--dry-run=client -o yaml | oc --context "$CTX" apply -f -
	oc --context "$CTX" label secret "$secret_name" -n "$GITOPS_NAMESPACE" \
		argocd.argoproj.io/secret-type=repository --overwrite
	restart_openshift_gitops_repo_server
}

resolve_gitops_app_repo_url() {
	local out="${HUB_APP_REPO_URL_CLI:-}"
	if [[ -z "$out" ]]; then
		out="${GITOPS_APP_REPO_URL:-}"
	fi
	echo "$out"
}

context_for_server() {
	local want
	want="$(normalize_url "$1")"
	oc config view -o json | jq -r --arg want "$want" '
		def trim_slash(s): s | sub("/+$"; "");
		(trim_slash($want)) as $w
		| .contexts[] as $ctx
		| ($ctx.context.cluster) as $cn
		| (.clusters[] | select(.name == $cn) | .cluster.server) as $srv
		| select($srv != null and $srv != "")
		| select(trim_slash($srv) == $w)
		| $ctx.name
	' | head -1
}

merge_kubeconfig_from_terraform() {
	[[ -f "${TF_LOGIN_SCRIPT}" ]] || die "missing ${TF_LOGIN_SCRIPT}"
	command -v terraform >/dev/null 2>&1 || die "terraform not on PATH (required for --merge-kubeconfig)"
	MC_KUBECONFIG="$(mktemp "${TMPDIR:-/tmp}/002-gitops-kubeconfig.XXXXXX")"
	chmod 600 "${MC_KUBECONFIG}"
	bash "${TF_LOGIN_SCRIPT}" --terraform-dir "${TF_DIR}" --output "${MC_KUBECONFIG}" "${INSECURE_LOGIN[@]}"
	export KUBECONFIG="${MC_KUBECONFIG}"
	echo "Using merged kubeconfig from ${TF_LOGIN_SCRIPT} (${KUBECONFIG})."
}

resolve_context() {
	if [[ -n "$CONTEXT" ]]; then
		echo "$CONTEXT"
		return 0
	fi
	if [[ -n "${ACM_HUB_CONTEXT:-}" ]]; then
		echo "$ACM_HUB_CONTEXT"
		return 0
	fi
	command -v terraform >/dev/null 2>&1 || die "terraform not on PATH; use --context or ACM_HUB_CONTEXT."
	local api
	api="$(terraform -chdir="$TF_DIR" output -json first_cluster 2>/dev/null | jq -r '.cluster_api_url // empty')"
	[[ -n "$api" ]] || die "terraform output first_cluster unavailable (init/apply remote state or pass --context)."
	local matched
	matched="$(context_for_server "$api")"
	[[ -n "$matched" ]] || die "no kube context with server ${api}; run ${TF_LOGIN_SCRIPT} or pass --context."
	echo "$matched"
}

resolve_local_cluster_name() {
	if [[ -n "${LOCAL_CLUSTER_NAME_OVERRIDE}" ]]; then
		echo "${LOCAL_CLUSTER_NAME_OVERRIDE}"
		return 0
	fi
	if [[ -n "${ACM_LOCAL_CLUSTER_NAME:-}" ]]; then
		echo "${ACM_LOCAL_CLUSTER_NAME}"
		return 0
	fi
	if command -v terraform >/dev/null 2>&1; then
		local fj cn k pick=""
		fj="$(terraform -chdir="$TF_DIR" output -json first_cluster 2>/dev/null)" || true
		if [[ -n "$fj" ]]; then
			cn="$(echo "$fj" | jq -r '.cluster_name // empty')"
			k="$(echo "$fj" | jq -r '.key // empty')"
			[[ "$cn" == "null" ]] && cn=""
			[[ "$k" == "null" ]] && k=""
			if [[ -n "$cn" && ${#cn} -le ${_ACM_LOCAL_CLUSTER_NAME_MAX_LEN} ]]; then
				pick="$cn"
			elif [[ -n "$cn" && ${#cn} -gt ${_ACM_LOCAL_CLUSTER_NAME_MAX_LEN} ]]; then
				echo "warn: terraform cluster_name (${#cn} chars) exceeds ${_ACM_LOCAL_CLUSTER_NAME_MAX_LEN}-char RHACM limit; using key \"${k}\"." >&2
				pick="$k"
			elif [[ -n "$k" ]]; then
				pick="$k"
			fi
			if [[ -n "$pick" ]]; then
				echo "$pick"
				return 0
			fi
		fi
	fi
	echo "$CTX"
}

ensure_gitops_operand_namespace() {
	oc --context="$CTX" get namespace "${GITOPS_NAMESPACE}" &>/dev/null && return 0
	echo "Creating namespace ${GITOPS_NAMESPACE}..."
	oc --context="$CTX" create namespace "${GITOPS_NAMESPACE}"
}

wait_for_gitops_csv_succeeded() {
	echo "Waiting for openshift-gitops-operator ClusterServiceVersion in ${GITOPS_OPERATOR_NAMESPACE} (up to 15m)..."
	local found=""
	for _ in $(seq 1 90); do
		found="$(oc --context="$CTX" get csv -n "${GITOPS_OPERATOR_NAMESPACE}" -o json 2>/dev/null | jq -r '
			.items[]
			| select(.metadata.name | test("^openshift-gitops-operator\\."))
			| select(.status.phase != null)
			| .metadata.name + " " + .status.phase
		' | head -1 || true)"
		if [[ -n "$found" ]]; then
			local ph="${found##* }"
			[[ "$ph" == "Succeeded" ]] && break
		fi
		sleep 10
	done
	[[ "${found##* }" == "Succeeded" ]] || die "OpenShift GitOps CSV did not reach Succeeded (last: ${found:-none}). Check: oc --context=$CTX get csv -n ${GITOPS_OPERATOR_NAMESPACE}"
	echo "OpenShift GitOps operator CSV ready: ${found}"
}

wait_for_argocd_stabilized() {
	local deadline=$((SECONDS + ARGOCD_STABILIZE_WAIT_SEC))
	local cr="${GITOPS_ARGOCD_CR_NAME:-openshift-gitops}"
	local srv="${cr}-server"
	echo "Waiting for Argo CD instance ${cr} to stabilize (up to ${ARGOCD_STABILIZE_WAIT_SEC}s)..."
	while ((SECONDS < deadline)); do
		if ! oc --context="$CTX" get argocd "$cr" -n "${GITOPS_NAMESPACE}" &>/dev/null; then
			sleep 10
			continue
		fi
		local phase
		phase="$(oc --context="$CTX" get argocd "$cr" -n "${GITOPS_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
		if [[ -n "$phase" ]]; then
			local pl="${phase,,}"
			if [[ "$pl" == "available" || "$pl" == "successful" || "$pl" == "completed" ]]; then
				echo "ArgoCD status.phase: ${phase}"
				return 0
			fi
		fi
		local desired ready
		desired="$(oc --context="$CTX" get deployment "$srv" -n "${GITOPS_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
		ready="$(oc --context="$CTX" get deployment "$srv" -n "${GITOPS_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
		if [[ -n "${desired:-}" && "${desired:-0}" != "0" && "$ready" == "$desired" ]]; then
			echo "${srv} Deployment ready (${ready}/${desired})."
			return 0
		fi
		sleep 15
	done
	die "Argo CD did not stabilize in time; check: oc --context=$CTX describe argocd ${cr} -n ${GITOPS_NAMESPACE}"
}

# RHACM GitOps doc "Enabling the ApplicationSet resource in any namespace" (setup-appset-any-namespace.sh): ArgoCD
# spec.applicationSet.enabled + controller env ARGOCD_APPLICATIONSET_CONTROLLER_NAMESPACES=* , ClusterRole/Binding;
# optionally merge GITOPS_APPLICATION_SET_SOURCE_NAMESPACES into spec.applicationSet.sourceNamespaces.
configure_argocd_applicationset() {
	local argocd_name="${GITOPS_ARGOCD_CR_NAME:-openshift-gitops}"
	local app_set_deploy="${argocd_name}-applicationset-controller"
	local rhacm=1 merge_sn=1
	local csv add_json patch_compact

	((SKIP_APPLICATION_SET_ANY_NAMESPACE)) && rhacm=0

	((SKIP_APPLICATION_SET_SOURCE_NS)) && merge_sn=0
	csv="${GITOPS_APPLICATION_SET_SOURCE_NAMESPACES:-}"
	if [[ -z "${csv// }" ]]; then
		merge_sn=0
	fi

	if ((rhacm == 0 && merge_sn == 0)); then
		echo "Skipping ArgoCD spec.applicationSet updates (RHACM ApplicationSet-in-any-namespace disabled and sourceNamespaces unset or skipped)."
		return 0
	fi

	if ! oc --context="$CTX" get argocd "$argocd_name" -n "${GITOPS_NAMESPACE}" &>/dev/null; then
		echo "warn: ArgoCD ${argocd_name} not found in ${GITOPS_NAMESPACE}; skip ApplicationSet configuration." >&2
		return 0
	fi

	add_json='[]'
	if ((merge_sn)); then
		add_json="$(echo "$csv" | tr ',' '\n' | sed '/^$/d' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -s -c 'map(select(length > 0))')"
	fi

	patch_compact="$(oc --context="$CTX" get argocd "$argocd_name" -n "${GITOPS_NAMESPACE}" -o json \
		| jq --argjson rhacm "$rhacm" --argjson merge_sn "$merge_sn" --argjson ns_add "$add_json" '
			.spec.applicationSet |= (. // {})
			| if $rhacm == 1 then
				.spec.applicationSet.enabled = true
				| (.spec.applicationSet.env // []) as $e
				| .spec.applicationSet.env = (
					($e | map(select(
						.name != "ARGOCD_APPLICATIONSET_CONTROLLER_NAMESPACES" and
						.name != "ARGOCD_APPLICATIONSET_CONTROLLER_ENABLE_SCM_PROVIDERS"
					)))
					+ [
						{"name":"ARGOCD_APPLICATIONSET_CONTROLLER_NAMESPACES","value":"*"},
						{"name":"ARGOCD_APPLICATIONSET_CONTROLLER_ENABLE_SCM_PROVIDERS","value":"false"}
					]
				)
			else . end
			| if $merge_sn == 1 then
				(.spec.applicationSet.sourceNamespaces // []) as $cur
				| .spec.applicationSet.sourceNamespaces = ($cur + $ns_add | unique | sort)
			else . end
			| {spec: {applicationSet: .spec.applicationSet}}
		' | jq -c .)" || die "failed to build ArgoCD applicationSet patch"

	if [[ -z "$patch_compact" || "$patch_compact" == "null" ]]; then
		die "empty patch for ArgoCD applicationSet"
	fi

	if ((DRY_RUN)); then
		echo "--- dry-run: oc patch argocd ${argocd_name} --type merge (spec.applicationSet) ---"
		echo "$patch_compact" | jq .
	else
		oc --context="$CTX" patch argocd "$argocd_name" -n "${GITOPS_NAMESPACE}" --type merge -p "$patch_compact" \
			|| die "patch argocd applicationSet failed"
		echo "Patched ArgoCD ${argocd_name} spec.applicationSet (RHACM any-namespace enabled=${rhacm}, merge sourceNamespaces=${merge_sn})."
	fi

	if ((rhacm)); then
		[[ -d "${GITOPS_APPSET_ANY_NS_MANIFEST_DIR}" ]] || die "missing manifests: ${GITOPS_APPSET_ANY_NS_MANIFEST_DIR}"
		[[ -f "${GITOPS_APPSET_ANY_NS_MANIFEST_DIR}/argocd-applicationset-controller-clusterrole.yaml" ]] \
			|| die "missing ClusterRole manifest under ${GITOPS_APPSET_ANY_NS_MANIFEST_DIR}"
		[[ -f "${GITOPS_APPSET_ANY_NS_MANIFEST_DIR}/argocd-applicationset-controller-clusterrolebinding.yaml.tpl" ]] \
			|| die "missing ClusterRoleBinding template under ${GITOPS_APPSET_ANY_NS_MANIFEST_DIR}"
		command -v envsubst >/dev/null 2>&1 || die "envsubst not found (install gettext)"
		if ((DRY_RUN)); then
			echo "--- dry-run: oc apply ClusterRole / ClusterRoleBinding (ApplicationSet controller any-namespace RBAC) ---"
			oc --context="$CTX" apply --dry-run=client -f "${GITOPS_APPSET_ANY_NS_MANIFEST_DIR}/argocd-applicationset-controller-clusterrole.yaml"
			envsubst < "${GITOPS_APPSET_ANY_NS_MANIFEST_DIR}/argocd-applicationset-controller-clusterrolebinding.yaml.tpl" \
				| oc --context="$CTX" apply --dry-run=client -f -
		else
			echo "--- Applying ClusterRole / ClusterRoleBinding for ApplicationSet controller (RHACM any-namespace) ---"
			oc --context="$CTX" apply -f "${GITOPS_APPSET_ANY_NS_MANIFEST_DIR}/argocd-applicationset-controller-clusterrole.yaml"
			envsubst < "${GITOPS_APPSET_ANY_NS_MANIFEST_DIR}/argocd-applicationset-controller-clusterrolebinding.yaml.tpl" \
				| oc --context="$CTX" apply -f -
		fi
	fi

	if ((DRY_RUN)); then
		return 0
	fi

	if oc --context="$CTX" get deployment "$app_set_deploy" -n "${GITOPS_NAMESPACE}" &>/dev/null; then
		echo "Restarting ${app_set_deploy} to pick up ApplicationSet configuration..."
		oc --context="$CTX" rollout restart deployment "$app_set_deploy" -n "${GITOPS_NAMESPACE}" >/dev/null \
			|| echo "warn: rollout restart ${app_set_deploy} failed (non-fatal)." >&2
	fi
}

helm_gitops_operator_install() {
	local -a cmd=(
		helm --kube-context "$CTX" upgrade --install "$GITOPS_HELM_RELEASE" "$CHART_GITOPS_OPERATOR"
		--namespace "$GITOPS_OPERATOR_NAMESPACE"
		--set subscription.channel="$GITOPS_OPERATOR_CHANNEL"
	)
	if ((DRY_RUN)); then
		cmd+=(--dry-run=client)
	fi
	"${cmd[@]}"
}

gitops_addon_helm_bool() {
	# Helm --set expects YAML/scalar bool; normalize string env "true"/"false".
	case "${GITOPS_ADDON_ENABLED,,}" in
	true | 1 | yes) echo true ;;
	*) echo false ;;
	esac
}

# Returns 0 when charts/acm-openshift-gitops-resources should be synced by Argo (hub-acm-openshift-gitops-resources), not installed by helm_acm_gitops_resources_install here.
should_install_acm_gitops_resources_via_argo() {
	((SKIP_ACM_GITOPS_RESOURCES)) && return 1
	((GITOPS_ACM_RESOURCES_VIA_ARGO)) || return 1
	((SKIP_HUB_APP_OF_APPS)) && return 1
	local repo_url
	repo_url="$(resolve_gitops_app_repo_url)"
	[[ -n "$repo_url" ]]
}

wait_and_patch_hub_acm_gitops_resources_application() {
	if ((DRY_RUN)); then
		echo "dry-run: would wait for Application hub-acm-openshift-gitops-resources and patch Helm parameters from environment."
		return 0
	fi
	local deadline=$((SECONDS + HUB_ACM_GITOPS_APP_WAIT_SEC))
	echo "Waiting for Argo CD Application hub-acm-openshift-gitops-resources (up to ${HUB_ACM_GITOPS_APP_WAIT_SEC}s)..."
	while ((SECONDS < deadline)); do
		if oc --context="$CTX" get applications.argoproj.io hub-acm-openshift-gitops-resources -n "$GITOPS_NAMESPACE" &>/dev/null; then
			break
		fi
		sleep 3
	done
	if ! oc --context="$CTX" get applications.argoproj.io hub-acm-openshift-gitops-resources -n "$GITOPS_NAMESPACE" &>/dev/null; then
		die "timeout waiting for Application hub-acm-openshift-gitops-resources in ${GITOPS_NAMESPACE} (ensure hub-gitops-root can sync charts/gitops-hub-apps/applications)."
	fi
	local tmp cur addon
	addon="$(gitops_addon_helm_bool)"
	tmp="$(mktemp)"
	cur="$(oc --context="$CTX" get applications.argoproj.io hub-acm-openshift-gitops-resources -n "$GITOPS_NAMESPACE" -o json)"
	jq --arg gitopsNs "$GITOPS_NAMESPACE" \
		--arg cs "$ACM_CLUSTER_SET" \
		--arg pn "$GITOPS_PLACEMENT_NAME" \
		--arg gn "$GITOPS_CLUSTER_CR_NAME" \
		--arg cluster "$ACM_LOCAL_CLUSTER_NAME" \
		--arg addon "$addon" \
		'.spec.source.helm.parameters = [
			{name:"gitopsNamespace",value:$gitopsNs},
			{name:"clusterSet",value:$cs},
			{name:"placement.name",value:$pn},
			{name:"gitopsCluster.name",value:$gn},
			{name:"argoServer.cluster",value:$cluster},
			{name:"gitopsAddon.enabled",value:$addon}
		]' <<<"$cur" > "$tmp"
	oc --context="$CTX" apply -f "$tmp"
	rm -f "$tmp"
	echo "Patched hub-acm-openshift-gitops-resources Helm parameters (argoServer.cluster=${ACM_LOCAL_CLUSTER_NAME})."
}

helm_acm_gitops_resources_install() {
	local addon
	addon="$(gitops_addon_helm_bool)"
	local -a cmd=(
		helm --kube-context "$CTX" upgrade --install "$GITOPS_RESOURCES_RELEASE" "$CHART_ACM_GITOPS_RESOURCES"
		--namespace "$GITOPS_NAMESPACE"
		--create-namespace
		--set gitopsNamespace="$GITOPS_NAMESPACE"
		--set clusterSet="$ACM_CLUSTER_SET"
		--set placement.name="$GITOPS_PLACEMENT_NAME"
		--set gitopsCluster.name="$GITOPS_CLUSTER_CR_NAME"
		--set argoServer.cluster="$ACM_LOCAL_CLUSTER_NAME"
		--set "gitopsAddon.enabled=${addon}"
	)
	if ((DRY_RUN)); then
		cmd+=(--dry-run=client)
	fi
	"${cmd[@]}"
}

verify_hub_argoc_applications() {
	local ns="$1"
	if ! oc --context="$CTX" get crd applications.argoproj.io &>/dev/null; then
		echo "warn: applications.argoproj.io CRD not found yet (OpenShift GitOps still installing?)." >&2
		return 0
	fi
	echo "Argo CD Applications in ${ns}:"
	oc --context="$CTX" get applications.argoproj.io -n "$ns" -o wide 2>/dev/null || true
}

helm_hub_app_of_apps_install() {
	local repo_url
	repo_url="$(resolve_gitops_app_repo_url)"
	if ((SKIP_HUB_APP_OF_APPS)); then
		echo "Skipping hub app-of-apps Helm chart (--skip-hub-app-of-apps)."
		return 0
	fi
	[[ -d "$CHART_HUB_APP_OF_APPS" ]] || die "chart not found: ${CHART_HUB_APP_OF_APPS}"
	if [[ -z "$repo_url" ]]; then
		echo "" >&2
		echo "NOTICE: hub app-of-apps (Argo CD Applications) was skipped — no Git URL for spec.source.repoURL." >&2
		echo "  Set: export GITOPS_APP_REPO_URL=\"https://github.com/ORG/istio-scale-tests.git\"" >&2
		echo "  Or:  ./platform-setup/002-acm-openshift-gitops.sh --hub-app-repo-url \"https://...\"" >&2
		echo "  Or run this script from a git clone so \`git remote get-url origin\` resolves (SSH URLs are mapped to HTTPS for github.com / gitlab.com)." >&2
		echo "" >&2
		return 0
	fi
	repo_url="$(normalize_git_repo_url_for_argo "$repo_url")"
	echo "Using Git repo URL for hub Application sources: ${repo_url}"
	ensure_hub_argoc_git_repo_credentials "$repo_url"
	local -a cmd=(
		helm --kube-context "$CTX" upgrade --install "$GITOPS_HUB_APP_OF_APPS_RELEASE" "$CHART_HUB_APP_OF_APPS"
		--namespace "$GITOPS_NAMESPACE"
		--set gitopsNamespace="$GITOPS_NAMESPACE"
		--set-string repo.url="$repo_url"
		--set-string repo.revision="$GITOPS_APP_REPO_REVISION"
	)
	if ((DRY_RUN)); then
		cmd+=(--dry-run=client)
	fi
	"${cmd[@]}"
	if ((DRY_RUN == 0)); then
		verify_hub_argoc_applications "$GITOPS_NAMESPACE"
	fi
}

# Placement selects ManagedClusters in ACM_CLUSTER_SET without label local-cluster=true (same as charts/acm-openshift-gitops-resources Placement).
count_spoke_managedclusters_for_gitops_placement() {
	local out=""
	out="$(oc --context "$CTX" get managedcluster -o json 2>/dev/null \
		| jq -r --arg cs "${ACM_CLUSTER_SET}" '
			[.items[]
				| select(.metadata.labels["cluster.open-cluster-management.io/clusterset"] == $cs)
				| select((.metadata.labels["local-cluster"] // "") != "true")]
			| length
		' 2>/dev/null || true)"
	echo "${out:-}"
}

skip_acm_gitops_cluster_and_addon_waits() {
	if [[ "${GITOPS_FORCE_ACM_GITOPS_WAITS:-0}" == "1" ]]; then
		return 1
	fi
	local n=""
	n="$(count_spoke_managedclusters_for_gitops_placement)"
	if [[ -z "$n" ]] || ! [[ "$n" =~ ^[0-9]+$ ]]; then
		return 1
	fi
	if [[ "$n" != "0" ]]; then
		return 1
	fi
	echo "Skipping GitOpsCluster success wait and spoke ManagedCluster gitops-addon label wait: zero spoke ManagedClusters in clusterset ${ACM_CLUSTER_SET} (hub-only — same exclusion as Placement local-cluster). Set GITOPS_FORCE_ACM_GITOPS_WAITS=1 to wait anyway."
	return 0
}

wait_for_gitopscluster_ready() {
	local deadline=$((SECONDS + GITOPS_CLUSTER_READY_WAIT_SEC))
	echo "Waiting for GitOpsCluster ${GITOPS_CLUSTER_CR_NAME} (up to ${GITOPS_CLUSTER_READY_WAIT_SEC}s)..."
	while ((SECONDS < deadline)); do
		local phase
		phase="$(oc --context="$CTX" get gitopscluster "${GITOPS_CLUSTER_CR_NAME}" -n "${GITOPS_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
		if [[ -n "$phase" ]]; then
			local pl="${phase,,}"
			if [[ "$pl" == *successful* ]]; then
				echo "GitOpsCluster status.phase: ${phase}"
				return 0
			fi
		fi
		if oc --context="$CTX" get gitopscluster "${GITOPS_CLUSTER_CR_NAME}" -n "${GITOPS_NAMESPACE}" -o json 2>/dev/null \
			| jq -e '(.status.conditions // []) | map(select(.type=="Successful")) | .[0].status == "True"' >/dev/null 2>&1; then
			echo "GitOpsCluster reports Successful=True."
			return 0
		fi
		sleep 15
	done
	die "GitOpsCluster ${GITOPS_CLUSTER_CR_NAME} did not report success in time; oc --context=$CTX describe gitopscluster -n ${GITOPS_NAMESPACE} ${GITOPS_CLUSTER_CR_NAME}"
}

# Every ManagedCluster in ACM_CLUSTER_SET (hub and spokes). RHACM sets feature.open-cluster-management.io/addon-gitops-addon on each ManagedCluster.
list_managedclusters_in_clusterset() {
	oc --context "$CTX" get managedcluster -o json 2>/dev/null \
		| jq -r --arg cs "${ACM_CLUSTER_SET}" '
			[.items[]
				| select(.metadata.labels["cluster.open-cluster-management.io/clusterset"] == $cs)]
			| .[].metadata.name
		' 2>/dev/null || true
}

managedcluster_gitops_addon_feature_available() {
	local mc="$1"
	local val=""
	val="$(oc --context "$CTX" get managedcluster "$mc" -o json 2>/dev/null \
		| jq -r '.metadata.labels["feature.open-cluster-management.io/addon-gitops-addon"] // empty' 2>/dev/null || true)"
	[[ "${val}" == "available" ]]
}

wait_for_gitops_addon_feature_on_managedclusters() {
	local deadline=$((SECONDS + GITOPS_ADDON_FEATURE_WAIT_SEC))
	local key="feature.open-cluster-management.io/addon-gitops-addon"
	local names pending
	names="$(list_managedclusters_in_clusterset)"
	names="$(echo "$names" | sed '/^[[:space:]]*$/d')"
	if [[ -z "$names" ]]; then
		echo "No ManagedClusters in clusterset ${ACM_CLUSTER_SET}; nothing to wait for for ${key}."
		return 0
	fi
	echo "Waiting for ManagedCluster label ${key}=available on each cluster in clusterset ${ACM_CLUSTER_SET} (up to ${GITOPS_ADDON_FEATURE_WAIT_SEC}s)..."
	while ((SECONDS < deadline)); do
		pending=""
		while IFS= read -r mc; do
			[[ -z "$mc" ]] && continue
			if managedcluster_gitops_addon_feature_available "$mc"; then
				continue
			fi
			pending="${pending}${pending:+, }${mc}"
		done <<<"$names"
		if [[ -z "$pending" ]]; then
			echo "All ManagedClusters in clusterset ${ACM_CLUSTER_SET} have ${key}=available."
			return 0
		fi
		echo "  Pending (${key}): ${pending}"
		sleep 15
	done
	die "Timed out waiting for ${key}=available on every ManagedCluster in clusterset ${ACM_CLUSTER_SET}; try: oc --context=$CTX get managedcluster -o json | jq '.items[] | {name: .metadata.name, addonGitOps: .metadata.labels[\"feature.open-cluster-management.io/addon-gitops-addon\"]}'"
}

lint_charts() {
	helm lint "$CHART_GITOPS_OPERATOR" >/dev/null || die "helm lint failed: ${CHART_GITOPS_OPERATOR}"
	helm lint "$CHART_ACM_GITOPS_RESOURCES" --set argoServer.cluster=helm-lint-placeholder >/dev/null \
		|| die "helm lint failed: ${CHART_ACM_GITOPS_RESOURCES}"
	helm lint "$CHART_CERT_MANAGER_OPERATOR" >/dev/null || die "helm lint failed: ${CHART_CERT_MANAGER_OPERATOR}"
	helm lint "$CHART_GITOPS_HUB_APPS" >/dev/null || die "helm lint failed: ${CHART_GITOPS_HUB_APPS}"
	helm lint "$CHART_HUB_APP_OF_APPS" --set repo.url=https://example.com/org/repo.git >/dev/null \
		|| die "helm lint failed: ${CHART_HUB_APP_OF_APPS}"
	helm lint "$CHART_HUB_MESH_CA" >/dev/null || die "helm lint failed: ${CHART_HUB_MESH_CA}"
	helm lint "$CHART_HUB_MESH_CA_INTERMEDIATE" >/dev/null || die "helm lint failed: ${CHART_HUB_MESH_CA_INTERMEDIATE}"
	helm lint "$CHART_GITOPS_HUB_MESH_CA_INTERMEDIATE_APPSET" --set repo.url=https://example.com/org/repo.git >/dev/null \
		|| die "helm lint failed: ${CHART_GITOPS_HUB_MESH_CA_INTERMEDIATE_APPSET}"
	helm lint "$CHART_EXTERNAL_SECRETS_OPERATOR" >/dev/null || die "helm lint failed: ${CHART_EXTERNAL_SECRETS_OPERATOR}"
	helm lint "$CHART_GITOPS_HUB_EXTERNAL_SECRETS_OPERATOR_APPSET" --set repo.url=https://example.com/org/repo.git >/dev/null \
		|| die "helm lint failed: ${CHART_GITOPS_HUB_EXTERNAL_SECRETS_OPERATOR_APPSET}"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
if ((MERGE_KUBECONFIG == 1)); then
	if ((PATCH_ARGO_CLUSTER_SECRETS_ONLY == 1)) || ((DRY_RUN == 0)); then
		merge_kubeconfig_from_terraform
	fi
fi

CTX="$(resolve_context)"

ACM_LOCAL_CLUSTER_NAME="$(resolve_local_cluster_name)"
if (( ${#ACM_LOCAL_CLUSTER_NAME} > _ACM_LOCAL_CLUSTER_NAME_MAX_LEN )); then
	die "GitOpsCluster argoServer.cluster must be at most ${_ACM_LOCAL_CLUSTER_NAME_MAX_LEN} characters (got ${#ACM_LOCAL_CLUSTER_NAME}: ${ACM_LOCAL_CLUSTER_NAME})."
fi
if [[ -z "${ACM_LOCAL_CLUSTER_NAME}" ]]; then
	die "hub ManagedCluster name is empty; use --local-cluster-name or ACM_LOCAL_CLUSTER_NAME."
fi

if ((PATCH_ARGO_CLUSTER_SECRETS_ONLY == 1)); then
	configure_argocd_applicationset
	patch_acm_argoc_managed_cluster_secrets "$CTX" "$GITOPS_NAMESPACE" "$DRY_RUN"
	exit 0
fi

command -v helm >/dev/null 2>&1 || {
	echo "error: helm not found" >&2
	exit 2
}

[[ -d "$CHART_GITOPS_OPERATOR" ]] || die "chart not found: ${CHART_GITOPS_OPERATOR}"
[[ -d "$CHART_ACM_GITOPS_RESOURCES" ]] || die "chart not found: ${CHART_ACM_GITOPS_RESOURCES}"
[[ -d "$CHART_HUB_APP_OF_APPS" ]] || die "chart not found: ${CHART_HUB_APP_OF_APPS}"
[[ -d "$CHART_CERT_MANAGER_OPERATOR" ]] || die "chart not found: ${CHART_CERT_MANAGER_OPERATOR}"
[[ -d "$CHART_GITOPS_HUB_APPS" ]] || die "chart not found: ${CHART_GITOPS_HUB_APPS}"

echo "Hub context: ${CTX}"
echo "GitOps operator Subscription namespace: ${GITOPS_OPERATOR_NAMESPACE}"
echo "GitOps / Argo CD / ACM CR namespace: ${GITOPS_NAMESPACE}"
echo "GitOps operator channel: ${GITOPS_OPERATOR_CHANNEL}"
echo "GitOpsCluster.spec.argoServer.cluster (hub ManagedCluster): ${ACM_LOCAL_CLUSTER_NAME}"

lint_charts

echo "--- 1) Install OpenShift GitOps operator (${GITOPS_HELM_RELEASE}) ---"
helm_gitops_operator_install

if ((DRY_RUN)); then
	echo "--- dry-run: ApplicationSet configuration (ArgoCD patch + RBAC if enabled) ---"
	configure_argocd_applicationset
	echo "--- dry-run: ACM GitOps resources + hub app-of-apps ---"
	if ((SKIP_ACM_GITOPS_RESOURCES)); then
		helm_hub_app_of_apps_install
	elif should_install_acm_gitops_resources_via_argo; then
		helm_hub_app_of_apps_install
		wait_and_patch_hub_acm_gitops_resources_application
	else
		helm_acm_gitops_resources_install
		helm_hub_app_of_apps_install
	fi
	echo "dry-run: done."
	exit 0
fi

if ((SKIP_WAIT)); then
	echo "Skipping readiness waits (--skip-wait)."
	ensure_gitops_operand_namespace
	if oc --context="$CTX" get argocd "${GITOPS_ARGOCD_CR_NAME:-openshift-gitops}" -n "${GITOPS_NAMESPACE}" &>/dev/null; then
		echo "--- 1b) Configure Argo CD ApplicationSet (RHACM any-namespace + optional sourceNamespaces) ---"
		configure_argocd_applicationset
	fi
	echo "--- 2) Hub app-of-apps + ACM GitOps resources (requires Application CRD for Argo path) ---"
	if oc --context="$CTX" get crd applications.argoproj.io &>/dev/null; then
		if ((SKIP_ACM_GITOPS_RESOURCES)); then
			helm_hub_app_of_apps_install
		elif should_install_acm_gitops_resources_via_argo; then
			helm_hub_app_of_apps_install
			wait_and_patch_hub_acm_gitops_resources_application
		else
			helm_acm_gitops_resources_install
			helm_hub_app_of_apps_install
		fi
	else
		echo "warn: applications.argoproj.io CRD not ready yet — hub app-of-apps not installed. Re-run 002 without --skip-wait after the GitOps CSV succeeds, or set GITOPS_APP_REPO_URL and apply ${CHART_HUB_APP_OF_APPS} manually." >&2
		if ((SKIP_ACM_GITOPS_RESOURCES == 0)); then
			echo "Installing ACM GitOps resources via Helm (Application CRD not ready)."
			helm_acm_gitops_resources_install
		fi
	fi
	echo "Done (--skip-wait)."
	exit 0
fi

wait_for_gitops_csv_succeeded
ensure_gitops_operand_namespace
wait_for_argocd_stabilized

echo "--- 1b) Configure Argo CD ApplicationSet (RHACM any-namespace + optional sourceNamespaces) ---"
configure_argocd_applicationset

if ((SKIP_ACM_GITOPS_RESOURCES)); then
	echo "--- 2) Install hub app-of-apps (${GITOPS_HUB_APP_OF_APPS_RELEASE}) ---"
	helm_hub_app_of_apps_install
	echo "Skipping ACM GitOps resources (--skip-acm-gitops-resources)."
	echo "Done (operator + hub GitOps Applications only)."
	exit 0
fi

if should_install_acm_gitops_resources_via_argo; then
	echo "--- 2a) Install hub app-of-apps (${GITOPS_HUB_APP_OF_APPS_RELEASE}) ---"
	helm_hub_app_of_apps_install
	echo "--- 2b) Patch Argo Application hub-acm-openshift-gitops-resources ---"
	wait_and_patch_hub_acm_gitops_resources_application
else
	echo "--- 2a) Install ACM GitOps resources (${GITOPS_RESOURCES_RELEASE}) via Helm ---"
	helm_acm_gitops_resources_install
	echo "--- 2b) Install hub app-of-apps (${GITOPS_HUB_APP_OF_APPS_RELEASE}) ---"
	helm_hub_app_of_apps_install
fi

if skip_acm_gitops_cluster_and_addon_waits; then
	:
else
	wait_for_gitopscluster_ready
	wait_for_gitops_addon_feature_on_managedclusters
fi

if ((SKIP_ARGO_CLUSTER_SECRET_FIX == 0)); then
	echo "--- 4) Patch ACM → Argo managed-cluster Secrets (${GITOPS_NAMESPACE}) ---"
	patch_acm_argoc_managed_cluster_secrets "$CTX" "$GITOPS_NAMESPACE" 0
else
	echo "Skipping Argo cluster secret patch (--skip-argoc-cluster-secret-fix)."
fi

echo "Done. Placement ${GITOPS_PLACEMENT_NAME} selects all clusters in ${ACM_CLUSTER_SET} except the hub (local-cluster label)."
exit 0

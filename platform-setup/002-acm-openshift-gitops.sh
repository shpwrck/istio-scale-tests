#!/usr/bin/env bash
# Install OpenShift GitOps on the ACM hub (Helm), wait until Argo CD is ready, then apply RHACM GitOps wiring (Helm):
# ManagedClusterSetBinding, Placement (all clusters in the set except the hub / local-cluster), GitOpsCluster — and wait for success.
# Optionally patch ACM-created Argo cluster Secrets (public API URL + bearer token); RHACM often emits unusable internal URLs.
# Repo note: mesh CA / Istio lives under `istio-setup/` (starts at 002-ossm-mc-cacerts.sh). This script is `platform-setup/002` (after `platform-setup/001` ACM hub).
#
# Ref: https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/gitops/gitops-overview
# Prerequisites: RHACM hub (`platform-setup/001`); spokes in ManagedClusterSet ${ACM_CLUSTER_SET} (cluster.open-cluster-management.io/clusterset label from hub install).
#
# Usage (repo root):
#   ./platform-setup/002-acm-openshift-gitops.sh [--context NAME] [--terraform-dir DIR] [--dry-run] [--skip-wait]
#       [--skip-acm-gitops-resources] [--merge-kubeconfig] [--local-cluster-name NAME]
#       [--skip-argoc-cluster-secret-fix] [--gitops-namespace NS]
#   ./platform-setup/002-acm-openshift-gitops.sh --patch-argoc-cluster-secrets-only --context NAME [--dry-run] [--gitops-namespace NS]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

die() { echo "error: $*" >&2; exit 1; }

CONTEXT=""
LOCAL_CLUSTER_NAME_OVERRIDE=""
DRY_RUN=0
SKIP_WAIT=0
SKIP_ACM_GITOPS_RESOURCES=0
SKIP_ARGO_CLUSTER_SECRET_FIX=0
PATCH_ARGO_CLUSTER_SECRETS_ONLY=0
MERGE_KUBECONFIG=0
TF_DIR="${ACM_TERRAFORM_DIR:-${ROOT}/terraform/rosa-hcp}"
TF_LOGIN_SCRIPT="${ROOT}/terraform/scripts/001-oc-login-merge-kubeconfig.sh"
MC_KUBECONFIG=""
INSECURE_LOGIN=()

GITOPS_NAMESPACE="${GITOPS_NAMESPACE:-openshift-gitops}"
GITOPS_OPERATOR_NAMESPACE="${GITOPS_OPERATOR_NAMESPACE:-openshift-operators}"
GITOPS_HELM_RELEASE="${GITOPS_HELM_RELEASE:-openshift-gitops-operator}"
GITOPS_RESOURCES_RELEASE="${GITOPS_RESOURCES_RELEASE:-acm-openshift-gitops-resources}"

CHART_GITOPS_OPERATOR="${ROOT}/charts/openshift-gitops-operator"
CHART_ACM_GITOPS_RESOURCES="${ROOT}/charts/acm-openshift-gitops-resources"

ACM_CLUSTER_SET="${ACM_CLUSTER_SET:-istio-scale-tests}"
GITOPS_PLACEMENT_NAME="${GITOPS_PLACEMENT_NAME:-acm-openshift-gitops-placement}"
GITOPS_CLUSTER_CR_NAME="${GITOPS_CLUSTER_CR_NAME:-acm-openshift-gitops}"
GITOPS_ADDON_ENABLED="${GITOPS_ADDON_ENABLED:-true}"
GITOPS_CLUSTER_READY_WAIT_SEC="${GITOPS_CLUSTER_READY_WAIT_SEC:-1800}"
ARGOCD_STABILIZE_WAIT_SEC="${ARGOCD_STABILIZE_WAIT_SEC:-900}"

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
  1) Helm: charts/openshift-gitops-operator into ${GITOPS_OPERATOR_NAMESPACE}; wait for CSV + Argo CD instance to stabilize.
  2) Helm: charts/acm-openshift-gitops-resources into ${GITOPS_NAMESPACE} — ManagedClusterSetBinding, Placement (hub excluded via local-cluster label), GitOpsCluster; wait for GitOpsCluster success.
  3) Patch ACM Argo cluster Secrets (public API URL + bearer token) unless --skip-argoc-cluster-secret-fix.

  Patch only (e.g. after ACM/GitOps reconciles secrets): --patch-argoc-cluster-secrets-only --context HUB

  --context NAME              kube/oc context for the hub (recommended).
  --terraform-dir DIR         Terraform root for auto hub context / localClusterName (default: ${TF_DIR}).
  --dry-run                   Helm client dry-run for charts; with --patch-argoc-cluster-secrets-only, print patches only.
  --skip-wait                 Do not wait for CSV / Argo CD / GitOpsCluster readiness.
  --skip-acm-gitops-resources Install only the GitOps operator chart (skip ACM Placement / GitOpsCluster chart).
  --skip-argoc-cluster-secret-fix  Skip step (3) after GitOpsCluster (RHACM may leave unusable internal *.control-plane URLs).
  --patch-argoc-cluster-secrets-only  Only patch ACM *-application-manager-cluster Secrets; requires hub --context (and spoke contexts in kubeconfig).
  --gitops-namespace NS       Operand namespace / Argo CD + ACM CRs (default ${GITOPS_NAMESPACE}).
  --merge-kubeconfig          Run terraform/scripts/001-oc-login-merge-kubeconfig.sh (same as platform-setup/001).
  --local-cluster-name NAME   Hub ManagedCluster name for GitOpsCluster.spec.argoServer.cluster (max ${_ACM_LOCAL_CLUSTER_NAME_MAX_LEN} chars).
  --insecure-skip-tls-verify  Forward to kubeconfig merge helper.

Environment:
  GITOPS_NAMESPACE              Operand namespace / Argo CD + ACM CRs (default ${GITOPS_NAMESPACE}).
  GITOPS_OPERATOR_NAMESPACE     openshift-gitops-operator Subscription (default ${GITOPS_OPERATOR_NAMESPACE}).
  GITOPS_OPERATOR_CHANNEL       OLM channel (default ${GITOPS_OPERATOR_CHANNEL} from versions.env).
  GITOPS_HELM_RELEASE           Helm release for openshift-gitops-operator chart (default ${GITOPS_HELM_RELEASE}).
  GITOPS_RESOURCES_RELEASE       Helm release for acm-openshift-gitops-resources chart (default ${GITOPS_RESOURCES_RELEASE}).
  ACM_CLUSTER_SET               ManagedClusterSet for ManagedClusterSetBinding (default ${ACM_CLUSTER_SET}).
  GITOPS_PLACEMENT_NAME         Placement metadata.name → Helm --set placement.name (default ${GITOPS_PLACEMENT_NAME}).
  GITOPS_CLUSTER_CR_NAME        GitOpsCluster metadata.name → Helm --set gitopsCluster.name (default ${GITOPS_CLUSTER_CR_NAME}).
  GITOPS_ADDON_ENABLED          GitOpsCluster gitopsAddon.enabled (default ${GITOPS_ADDON_ENABLED}).
  GITOPS_CLUSTER_READY_WAIT_SEC Max wait for GitOpsCluster success (default ${GITOPS_CLUSTER_READY_WAIT_SEC}).
  ARGOCD_STABILIZE_WAIT_SEC     Max wait for Argo CD after CSV (default ${ARGOCD_STABILIZE_WAIT_SEC}).

  Step (3) / patch-only mode requires kubeconfig contexts named like each spoke ManagedCluster (e.g. rosa-002); use --merge-kubeconfig or log in spokes first.
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
	echo "Waiting for Argo CD instance openshift-gitops to stabilize (up to ${ARGOCD_STABILIZE_WAIT_SEC}s)..."
	while ((SECONDS < deadline)); do
		if ! oc --context="$CTX" get argocd openshift-gitops -n "${GITOPS_NAMESPACE}" &>/dev/null; then
			sleep 10
			continue
		fi
		local phase
		phase="$(oc --context="$CTX" get argocd openshift-gitops -n "${GITOPS_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
		if [[ -n "$phase" ]]; then
			local pl="${phase,,}"
			if [[ "$pl" == "available" || "$pl" == "successful" || "$pl" == "completed" ]]; then
				echo "ArgoCD status.phase: ${phase}"
				return 0
			fi
		fi
		local desired ready
		desired="$(oc --context="$CTX" get deployment openshift-gitops-server -n "${GITOPS_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
		ready="$(oc --context="$CTX" get deployment openshift-gitops-server -n "${GITOPS_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
		if [[ -n "${desired:-}" && "${desired:-0}" != "0" && "$ready" == "$desired" ]]; then
			echo "openshift-gitops-server Deployment ready (${ready}/${desired})."
			return 0
		fi
		sleep 15
	done
	die "Argo CD did not stabilize in time; check: oc --context=$CTX describe argocd openshift-gitops -n ${GITOPS_NAMESPACE}"
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

lint_charts() {
	helm lint "$CHART_GITOPS_OPERATOR" >/dev/null || die "helm lint failed: ${CHART_GITOPS_OPERATOR}"
	helm lint "$CHART_ACM_GITOPS_RESOURCES" --set argoServer.cluster=helm-lint-placeholder >/dev/null \
		|| die "helm lint failed: ${CHART_ACM_GITOPS_RESOURCES}"
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

if ((PATCH_ARGO_CLUSTER_SECRETS_ONLY == 1)); then
	patch_acm_argoc_managed_cluster_secrets "$CTX" "$GITOPS_NAMESPACE" "$DRY_RUN"
	exit 0
fi

command -v helm >/dev/null 2>&1 || {
	echo "error: helm not found" >&2
	exit 2
}

ACM_LOCAL_CLUSTER_NAME="$(resolve_local_cluster_name)"
if (( ${#ACM_LOCAL_CLUSTER_NAME} > _ACM_LOCAL_CLUSTER_NAME_MAX_LEN )); then
	die "GitOpsCluster argoServer.cluster must be at most ${_ACM_LOCAL_CLUSTER_NAME_MAX_LEN} characters (got ${#ACM_LOCAL_CLUSTER_NAME}: ${ACM_LOCAL_CLUSTER_NAME})."
fi
if [[ -z "${ACM_LOCAL_CLUSTER_NAME}" ]]; then
	die "hub ManagedCluster name is empty; use --local-cluster-name or ACM_LOCAL_CLUSTER_NAME."
fi

[[ -d "$CHART_GITOPS_OPERATOR" ]] || die "chart not found: ${CHART_GITOPS_OPERATOR}"
[[ -d "$CHART_ACM_GITOPS_RESOURCES" ]] || die "chart not found: ${CHART_ACM_GITOPS_RESOURCES}"

echo "Hub context: ${CTX}"
echo "GitOps operator Subscription namespace: ${GITOPS_OPERATOR_NAMESPACE}"
echo "GitOps / Argo CD / ACM CR namespace: ${GITOPS_NAMESPACE}"
echo "GitOps operator channel: ${GITOPS_OPERATOR_CHANNEL}"
echo "GitOpsCluster.spec.argoServer.cluster (hub ManagedCluster): ${ACM_LOCAL_CLUSTER_NAME}"

lint_charts

echo "--- 1) Install OpenShift GitOps operator (${GITOPS_HELM_RELEASE}) ---"
helm_gitops_operator_install

if ((DRY_RUN)); then
	echo "--- dry-run: ACM GitOps resources (${GITOPS_RESOURCES_RELEASE}) ---"
	if ((SKIP_ACM_GITOPS_RESOURCES == 0)); then
		helm_acm_gitops_resources_install
	fi
	echo "dry-run: done."
	exit 0
fi

if ((SKIP_WAIT)); then
	echo "Skipping readiness waits (--skip-wait)."
	if ((SKIP_ACM_GITOPS_RESOURCES == 0)); then
		ensure_gitops_operand_namespace
		helm_acm_gitops_resources_install
	fi
	exit 0
fi

wait_for_gitops_csv_succeeded
ensure_gitops_operand_namespace
wait_for_argocd_stabilized

if ((SKIP_ACM_GITOPS_RESOURCES)); then
	echo "Skipping ACM GitOps Helm chart (--skip-acm-gitops-resources)."
	echo "Done (operator only)."
	exit 0
fi

echo "--- 2) Install ACM GitOps resources (${GITOPS_RESOURCES_RELEASE}) ---"
helm_acm_gitops_resources_install

wait_for_gitopscluster_ready

if ((SKIP_ARGO_CLUSTER_SECRET_FIX == 0)); then
	echo "--- 3) Patch ACM → Argo managed-cluster Secrets (${GITOPS_NAMESPACE}) ---"
	patch_acm_argoc_managed_cluster_secrets "$CTX" "$GITOPS_NAMESPACE" 0
else
	echo "Skipping Argo cluster secret patch (--skip-argoc-cluster-secret-fix)."
fi

echo "Done. Placement ${GITOPS_PLACEMENT_NAME} selects all clusters in ${ACM_CLUSTER_SET} except the hub (local-cluster label)."
exit 0

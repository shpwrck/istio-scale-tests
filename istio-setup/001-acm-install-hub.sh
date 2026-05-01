#!/usr/bin/env bash
# Install Red Hat Advanced Cluster Management hub on one OpenShift cluster (OperatorHub subscription + MultiClusterHub).
# Pair OpenShift and ACM trains using config/versions.env (defaults: OCP 4.21.x + ACM channel release-2.16).
#
# Ref: https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/install/installing-advanced-cluster-management
# Support matrix: https://access.redhat.com/articles/7133095
#
# When registering Terraform spokes: builds a merged kubeconfig via terraform/scripts/001-oc-login-merge-kubeconfig.sh,
# installs charts/acm-managed-cluster once per non-hub cluster key, then applies RHACM import YAML on each spoke
# (secret <cluster>-import / import.yaml on hub — see RHACM "Importing a managed cluster with the CLI").
#
# Requires: Helm 3, oc, jq, base64; terraform when using spoke registration (not --skip-managed-clusters).
# Usage (repo root):
#   ./istio-setup/001-acm-install-hub.sh [--context NAME] [--terraform-dir DIR] [--dry-run] [--skip-wait]
#       [--skip-managed-clusters] [--skip-import] [--insecure-skip-tls-verify] [--local-cluster-name NAME]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

die() { echo "error: $*" >&2; exit 1; }

CONTEXT=""
LOCAL_CLUSTER_NAME_OVERRIDE=""
DRY_RUN=0
SKIP_WAIT=0
SKIP_MANAGED_CLUSTERS=0
SKIP_IMPORT=0
TF_DIR="${ACM_TERRAFORM_DIR:-${ROOT}/terraform/rosa-hcp}"
TF_LOGIN_SCRIPT="${ROOT}/terraform/scripts/001-oc-login-merge-kubeconfig.sh"
MC_KUBECONFIG=""
INSECURE_LOGIN=()

ACM_IMPORT_WAIT_SEC="${ACM_IMPORT_WAIT_SEC:-900}"

cleanup_mc_kubeconfig() {
	[[ -n "${MC_KUBECONFIG}" && -f "${MC_KUBECONFIG}" ]] && rm -f "${MC_KUBECONFIG}"
}
trap cleanup_mc_kubeconfig EXIT

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  Install RHACM hub operator on the target cluster (namespace ${ACM_NAMESPACE}).

  --context NAME       kube/oc context for the hub (recommended). If omitted, tries ACM_HUB_CONTEXT,
                       then matches terraform output first_cluster.cluster_api_url to kubeconfig.
  --terraform-dir DIR  Terraform root with applied state (default: ${ROOT}/terraform/rosa-hcp).
  --dry-run            Client-side Helm dry-run; skip waits, kubeconfig merge, and spoke import apply.
  --skip-wait          Do not wait for CSV / MultiClusterHub Running (skips spoke Helm + import).
  --skip-managed-clusters
                       Do not merge kubeconfig, Helm charts/acm-managed-cluster, or import spokes.
  --skip-import        Apply hub-side ManagedCluster Helm only; do not pull import.yaml / oc apply on spokes.
  --insecure-skip-tls-verify
                       Forward to terraform/scripts/001-oc-login-merge-kubeconfig.sh (ROSA API TLS).
  --local-cluster-name NAME
                       MultiClusterHub spec.localClusterName (overrides terraform/env). Max 34 characters (RHACM).

Environment:
  ACM_HUB_CONTEXT                  Default hub context when --context is omitted.
  ACM_CHANNEL                      OLM channel (default ${ACM_CHANNEL} from versions.env).
  ACM_NAMESPACE                    Install namespace (default ${ACM_NAMESPACE}).
  ACM_TERRAFORM_DIR                Override terraform root for auto context + spoke list.
  ACM_HELM_RELEASE                 Hub release name (default acm-hub).
  ACM_MANAGED_CLUSTER_RELEASE_PREFIX
                                   Prefix for per-spoke releases (default acm-managed-cluster → acm-managed-cluster-<key>).
  ACM_IMPORT_WAIT_SEC              Seconds to wait per spoke for hub import secret (default ${ACM_IMPORT_WAIT_SEC}).
  ACM_LOCAL_CLUSTER_NAME           MultiClusterHub spec.localClusterName when --local-cluster-name is not used.

OpenShift ${OPENSHIFT_VERSION} is pinned with ACM channel ${ACM_CHANNEL}; bump both together per RHACM support matrix.
Requires cluster-admin on the hub and on each spoke for import apply.
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
	--skip-managed-clusters)
		SKIP_MANAGED_CLUSTERS=1
		shift
		;;
	--skip-import)
		SKIP_IMPORT=1
		shift
		;;
	--insecure-skip-tls-verify)
		INSECURE_LOGIN+=(--insecure-skip-tls-verify)
		shift
		;;
	--local-cluster-name)
		[[ -n "${2:-}" ]] || die "--local-cluster-name requires a value"
		LOCAL_CLUSTER_NAME_OVERRIDE="$2"
		shift 2
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

if ! command -v oc >/dev/null 2>&1; then
	echo "error: oc not found" >&2
	exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
	echo "error: jq not found" >&2
	exit 2
fi
if ! command -v helm >/dev/null 2>&1; then
	echo "error: helm not found (Helm 3 required)" >&2
	exit 2
fi
if ! command -v base64 >/dev/null 2>&1; then
	echo "error: base64 not found" >&2
	exit 2
fi

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
	command -v terraform >/dev/null 2>&1 || die "terraform not on PATH (required for spoke kubeconfig merge)"
	MC_KUBECONFIG="$(mktemp "${TMPDIR:-/tmp}/001-acm-kubeconfig.XXXXXX")"
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

# RHACM limits spec.localClusterName length (see MultiClusterHub advanced configuration in RHACM install docs).
readonly _ACM_LOCAL_CLUSTER_NAME_MAX_LEN=34

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
				echo "warn: terraform cluster_name (${#cn} chars) exceeds ${_ACM_LOCAL_CLUSTER_NAME_MAX_LEN}-char RHACM limit; using terraform key \"${k}\" for localClusterName." >&2
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

# Emit spoke Terraform keys (map keys excluding hub), one per line.
list_spoke_cluster_keys() {
	command -v terraform >/dev/null 2>&1 || return 1
	local keys hub
	keys="$(terraform -chdir="$TF_DIR" output -json cluster_keys 2>/dev/null)" || return 1
	hub="$(terraform -chdir="$TF_DIR" output -raw first_cluster_key 2>/dev/null)" || return 1
	echo "$keys" | jq -r --arg hub "$hub" '
		(if type == "array" then . else [] end) as $k
		| $k[] | select(. != $hub)
	'
}

extract_import_yaml_from_hub() {
	local cluster="$1"
	local hub="${CTX}"
	local raw sec

	if raw="$(oc --context="$hub" get secret "${cluster}-import" -n "${cluster}" -o json 2>/dev/null)"; then
		sec="$(echo "$raw" | jq -r '.data["import.yaml"] // empty')"
		if [[ -n "$sec" ]]; then
			echo "$sec" | base64 -d
			return 0
		fi
	fi

	if oc --context="$hub" get secret "import-${cluster}-manual-import" -n "${cluster}" &>/dev/null; then
		raw="$(oc --context="$hub" get secret "import-${cluster}-manual-import" -n "${cluster}" -o json)"
		for key in import.yaml cr.yaml; do
			sec="$(echo "$raw" | jq -r --arg k "$key" '.data[$k] // empty')"
			if [[ -n "$sec" ]]; then
				echo "$sec" | base64 -d
				return 0
			fi
		done
	fi

	return 1
}

wait_import_yaml_from_hub() {
	local cluster="$1"
	local deadline=$((SECONDS + ACM_IMPORT_WAIT_SEC))
	local yaml=""
	while ((SECONDS < deadline)); do
		if yaml="$(extract_import_yaml_from_hub "$cluster")" && [[ -n "$yaml" ]]; then
			echo "$yaml"
			return 0
		fi
		sleep 10
	done
	return 1
}

apply_import_on_spoke() {
	local cluster="$1"
	local yaml
	if ! yaml="$(wait_import_yaml_from_hub "$cluster")"; then
		die "timed out after ${ACM_IMPORT_WAIT_SEC}s waiting for import secret on hub for cluster ${cluster} (see RHACM import docs)."
	fi
	echo "${yaml}" | oc --context="$cluster" apply -f -
}

HELM_RELEASE="${ACM_HELM_RELEASE:-acm-hub}"
HELM_MC_PREFIX="${ACM_MANAGED_CLUSTER_RELEASE_PREFIX:-acm-managed-cluster}"
CHART_DIR="${ROOT}/charts/acm-hub"
CHART_DIR_MC="${ROOT}/charts/acm-managed-cluster"

if ((SKIP_MANAGED_CLUSTERS == 0)) && ((DRY_RUN == 0)); then
	merge_kubeconfig_from_terraform
fi

CTX="$(resolve_context)"

LOCAL_CLUSTER_NAME="$(resolve_local_cluster_name)"
if (( ${#LOCAL_CLUSTER_NAME} > _ACM_LOCAL_CLUSTER_NAME_MAX_LEN )); then
	die "MultiClusterHub spec.localClusterName must be at most ${_ACM_LOCAL_CLUSTER_NAME_MAX_LEN} characters (got ${#LOCAL_CLUSTER_NAME}: ${LOCAL_CLUSTER_NAME}); use --local-cluster-name or shorten terraform cluster_name."
fi
if [[ -z "${LOCAL_CLUSTER_NAME}" ]]; then
	die "resolved localClusterName is empty"
fi

echo "Using hub context: ${CTX}"
echo "MultiClusterHub spec.localClusterName: ${LOCAL_CLUSTER_NAME}"
echo "ACM channel: ${ACM_CHANNEL} (OpenShift pin in versions.env: ${OPENSHIFT_VERSION})"
echo "Hub Helm release: ${HELM_RELEASE} (chart: ${CHART_DIR})"
echo "Per-spoke chart: ${CHART_DIR_MC} (release prefix: ${HELM_MC_PREFIX}-<cluster-key>)"

if ((DRY_RUN == 0)); then
	ocv="$(oc --context="$CTX" version -o json 2>/dev/null | jq -r '.openshiftVersion // empty')"
	if [[ -n "$ocv" ]]; then
		echo "Hub cluster reports OpenShift version: ${ocv}"
		majmin_env="${OPENSHIFT_VERSION%.*}"
		majmin_cls="${ocv%.*}"
		if [[ "$majmin_env" != "$majmin_cls" ]]; then
			echo "warn: hub cluster minor ${majmin_cls} differs from OPENSHIFT_VERSION minor ${majmin_env} — verify ACM_CHANNEL matches RHACM support matrix." >&2
		fi
	fi
fi

[[ -d "$CHART_DIR" ]] || die "chart not found: ${CHART_DIR}"
[[ -d "$CHART_DIR_MC" ]] || die "chart not found: ${CHART_DIR_MC}"

helm_upgrade_managed_clusters_and_import() {
	local -a keys
	if ((SKIP_MANAGED_CLUSTERS)); then
		echo "Skipping spoke registration (--skip-managed-clusters)."
		return 0
	fi

	if ! mapfile -t keys < <(list_spoke_cluster_keys); then
		echo "warn: Terraform outputs cluster_keys / first_cluster_key unavailable under ${TF_DIR}; skipping spokes." >&2
		return 0
	fi
	if ((${#keys[@]} == 0)); then
		echo "No spoke clusters in Terraform (hub only); skipping ${CHART_DIR_MC}."
		return 0
	fi

	local k rel
	for k in "${keys[@]}"; do
		[[ -z "$k" ]] && continue
		rel="${HELM_MC_PREFIX}-${k}"
		echo "Helm upgrade --install ${rel} (ManagedCluster name=${k})."
		local -a cmd=(
			helm --kube-context "$CTX" upgrade --install "$rel" "$CHART_DIR_MC"
			--namespace "$ACM_NAMESPACE"
			--create-namespace
			--set managedCluster.name="$k"
		)
		if ((DRY_RUN)); then
			cmd+=(--dry-run=client)
		fi
		"${cmd[@]}"
	done

	if ((DRY_RUN)); then
		echo "dry-run: skipping import apply on spokes."
		return 0
	fi

	if ((SKIP_IMPORT)); then
		echo "Skipping spoke import apply (--skip-import)."
		return 0
	fi

	for k in "${keys[@]}"; do
		[[ -z "$k" ]] && continue
		echo "Importing klusterlet on spoke context ${k} (hub import secret → oc apply)."
		apply_import_on_spoke "$k"
	done
}

helm_upgrade_hub() {
	local -a cmd=(
		helm --kube-context "$CTX" upgrade --install "$HELM_RELEASE" "$CHART_DIR"
		--namespace "$ACM_NAMESPACE"
		--create-namespace
		--set subscription.channel="$ACM_CHANNEL"
		--set-string multiclusterHub.spec.localClusterName="$LOCAL_CLUSTER_NAME"
	)
	if ((DRY_RUN)); then
		cmd+=(--dry-run=client)
	fi
	"${cmd[@]}"
}

if ((DRY_RUN == 0)); then
	helm lint "$CHART_DIR" >/dev/null || die "helm lint failed for ${CHART_DIR}"
	helm lint "$CHART_DIR_MC" >/dev/null || die "helm lint failed for ${CHART_DIR_MC}"
fi

echo "Applying charts/acm-hub (namespace, OperatorGroup, Subscription, MultiClusterHub)."
helm_upgrade_hub

if ((DRY_RUN)); then
	helm_upgrade_managed_clusters_and_import || die "spoke Helm dry-run failed."
	echo "dry-run: skipping CSV / MultiClusterHub wait."
	exit 0
fi

if ((SKIP_WAIT == 0)); then
	echo "Waiting for advanced-cluster-management ClusterServiceVersion (up to 15m)..."
	found=""
	for _ in $(seq 1 90); do
		found="$(oc --context="$CTX" get csv -n "${ACM_NAMESPACE}" -o json 2>/dev/null | jq -r '
			.items[]
			| select(.metadata.name | test("^advanced-cluster-management\\."))
			| select(.status.phase != null)
			| .metadata.name + " " + .status.phase
		' | head -1 || true)"
		if [[ -n "$found" ]]; then
			ph="${found##* }"
			[[ "$ph" == "Succeeded" ]] && break
		fi
		sleep 10
	done
	[[ "${found##* }" == "Succeeded" ]] || die "CSV did not reach Succeeded (last: ${found:-none}). Check: oc --context=$CTX get csv -n ${ACM_NAMESPACE}"
	echo "CSV ready: ${found}"
fi

if ((SKIP_WAIT)); then
	echo "Skipping MultiClusterHub status wait (--skip-wait); re-run without --skip-wait for spoke Helm + import."
	echo "Done (hub apply issued)."
	exit 0
fi

echo "Waiting for MultiClusterHub phase Running (up to 20m)..."
for _ in $(seq 1 120); do
	ph="$(oc --context="$CTX" get multiclusterhub multiclusterhub -n "${ACM_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
	if [[ "$ph" == "Running" ]]; then
		echo "MultiClusterHub status: Running"
		helm_upgrade_managed_clusters_and_import || die "spoke registration failed."
		echo "Done."
		exit 0
	fi
	sleep 10
done

die "MultiClusterHub did not reach Running in time; check: oc --context=$CTX get mch -n ${ACM_NAMESPACE} -o yaml"

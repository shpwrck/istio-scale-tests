#!/usr/bin/env bash
# Install RHACM hub: merge kubeconfigs from Terraform; three Helm charts on hub (operator → MultiClusterHub → KlusterletConfig);
# then per spoke cluster: ManagedCluster Helm → wait hub import/auto-import secret → apply CRD docs from import.yaml → apply full import.yaml on spoke.
# Each spoke ManagedCluster gets label cluster.open-cluster-management.io/clusterset=<ACM_CLUSTER_SET> (default istio-scale-tests via charts/acm-managed-cluster).
# Pair OpenShift and ACM using config/versions.env (defaults: OCP 4.21.x + ACM channel release-2.16).
#
# Ref: https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/install/installing-advanced-cluster-management
#
# Requires: Helm 3, oc, jq, base64; terraform when merging kubeconfig / listing spokes (unless --skip-managed-clusters).
#
# Migration: if the hub namespace still has an older single Helm release (e.g. acm-hub from the previous monolithic chart),
# uninstall it when safe before installing these releases, or Helm will error on OperatorGroup ownership / pruning.
# Usage (repo root):
#   ./platform-setup/001-acm-install-hub.sh [--context NAME] [--terraform-dir DIR] [--dry-run] [--skip-wait]
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
# Hub secret import.yaml often applies Klusterlet before the spoke has registered the Klusterlet CRD; retry apply.
ACM_IMPORT_APPLY_RETRY_SEC="${ACM_IMPORT_APPLY_RETRY_SEC:-900}"
# After import.yaml exists, poll for hub secret key crds.yaml (RHACM split) before falling back to CRDs embedded in import.yaml.
ACM_CRDS_YAML_WAIT_SEC="${ACM_CRDS_YAML_WAIT_SEC:-180}"
ACM_INSTALL_KLUSTERLETCONFIG="${ACM_INSTALL_KLUSTERLETCONFIG:-1}"
ACM_KLUSTERLETCONFIG_CRD_WAIT_SEC="${ACM_KLUSTERLETCONFIG_CRD_WAIT_SEC:-900}"
ACM_OCM_WEBHOOK_READY_WAIT_SEC="${ACM_OCM_WEBHOOK_READY_WAIT_SEC:-300}"
ACM_WAIT_MANAGED_CLUSTER_READY="${ACM_WAIT_MANAGED_CLUSTER_READY:-1}"
ACM_MANAGED_CLUSTER_READY_WAIT_SEC="${ACM_MANAGED_CLUSTER_READY_WAIT_SEC:-3600}"

CHART_OPERATOR="${ROOT}/charts/acm-operator"
CHART_MULTICLUSTER_HUB="${ROOT}/charts/acm-multicluster-hub"
CHART_KLUSTERLET_CONFIG="${ROOT}/charts/acm-klusterlet-config"
CHART_MANAGED_CLUSTER="${ROOT}/charts/acm-managed-cluster"

RELEASE_OPERATOR="${ACM_OPERATOR_RELEASE:-acm-operator}"
RELEASE_MULTICLUSTER_HUB="${ACM_MULTICLUSTER_HUB_RELEASE:-acm-multicluster-hub}"
RELEASE_KLUSTERLET_CONFIG="${ACM_KLUSTERLET_CONFIG_RELEASE:-acm-klusterlet-config}"
RELEASE_MC_PREFIX="${ACM_MANAGED_CLUSTER_RELEASE_PREFIX:-acm-managed-cluster}"

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

  1) Merge kubeconfig from Terraform (unless --skip-managed-clusters or --dry-run).
  2) Helm: charts/acm-operator → wait for ACM CSV Succeeded.
  3) Helm: charts/acm-multicluster-hub → wait for MultiClusterHub Running.
  4) Helm: charts/acm-klusterlet-config (unless ACM_INSTALL_KLUSTERLETCONFIG=0) after KlusterletConfig CRD exists.
  5) Per spoke (Terraform keys except hub): Helm ManagedCluster → wait hub import/auto-import secret → CRDs from import.yaml → full import.yaml on spoke.
  6) Wait until every Terraform cluster name has ManagedCluster Joined+Available on the hub (optional).

  --context NAME       kube/oc context for the hub (recommended). If omitted, tries ACM_HUB_CONTEXT,
                       then matches terraform output first_cluster.cluster_api_url to kubeconfig.
  --terraform-dir DIR  Terraform root with applied state (default: ${ROOT}/terraform/rosa-hcp).
  --dry-run            Client dry-run for Helm operator; helm template for CR charts that need CRDs.
  --skip-wait          Do not wait for CSV / MultiClusterHub (skips steps 2–4 readiness and spoke Helm + import).
  --skip-managed-clusters
                       Do not merge kubeconfig, ManagedCluster Helm, or import apply.
  --skip-import        Hub-side ManagedCluster Helm only; no oc apply import on spokes.
  --insecure-skip-tls-verify
                       Forward to terraform/scripts/001-oc-login-merge-kubeconfig.sh (ROSA API TLS).
  --local-cluster-name NAME
                       MultiClusterHub spec.localClusterName (overrides terraform/env). Max 34 characters (RHACM).

Environment:
  ACM_HUB_CONTEXT                  Default hub context when --context is omitted.
  ACM_CHANNEL                      OLM channel (default ${ACM_CHANNEL} from versions.env).
  ACM_NAMESPACE                    Install namespace (default ${ACM_NAMESPACE}).
  ACM_TERRAFORM_DIR                Override terraform root for auto context + spoke list.
  ACM_OPERATOR_RELEASE             Helm release for charts/acm-operator (default ${RELEASE_OPERATOR}).
  ACM_MULTICLUSTER_HUB_RELEASE     Helm release for charts/acm-multicluster-hub (default ${RELEASE_MULTICLUSTER_HUB}).
  ACM_KLUSTERLET_CONFIG_RELEASE    Helm release for charts/acm-klusterlet-config (default ${RELEASE_KLUSTERLET_CONFIG}).
  ACM_MANAGED_CLUSTER_RELEASE_PREFIX  Prefix for per-spoke releases (default ${RELEASE_MC_PREFIX}-<key>).
  ACM_IMPORT_WAIT_SEC              Seconds to wait per spoke for hub import secret (default ${ACM_IMPORT_WAIT_SEC}).
  ACM_IMPORT_APPLY_RETRY_SEC       Seconds to retry oc apply of import.yaml on each spoke if CRDs are not ready (default ${ACM_IMPORT_APPLY_RETRY_SEC}).
  ACM_CRDS_YAML_WAIT_SEC           Seconds to wait for hub secret data key crds.yaml after import.yaml exists (default ${ACM_CRDS_YAML_WAIT_SEC}).
  ACM_INSTALL_KLUSTERLETCONFIG     If 1 (default), install KlusterletConfig chart after CRD exists; set 0 to skip.
  ACM_KLUSTERLETCONFIG_CRD_WAIT_SEC  Seconds to wait for KlusterletConfig CRD (default ${ACM_KLUSTERLETCONFIG_CRD_WAIT_SEC}).
  ACM_OCM_WEBHOOK_READY_WAIT_SEC   Seconds to wait for OCM validating webhook TLS readiness before spoke registration (default ${ACM_OCM_WEBHOOK_READY_WAIT_SEC}).
  ACM_WAIT_MANAGED_CLUSTER_READY   If 1 (default), after imports wait for ManagedCluster Joined+Available for each Terraform cluster_keys name.
  ACM_MANAGED_CLUSTER_READY_WAIT_SEC  Max seconds for that wait (default ${ACM_MANAGED_CLUSTER_READY_WAIT_SEC}).
  ACM_LOCAL_CLUSTER_NAME           MultiClusterHub spec.localClusterName when --local-cluster-name is not used.
  ACM_CLUSTER_SET                  Sets label cluster.open-cluster-management.io/clusterset on each spoke ManagedCluster (default istio-scale-tests). Must match ManagedClusterSet / Binding / Placement.clusterSets (`charts/acm-openshift-gitops-resources` / `platform-setup/002-acm-openshift-gitops.sh`).

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

command -v oc >/dev/null 2>&1 || {
	echo "error: oc not found" >&2
	exit 2
}
command -v jq >/dev/null 2>&1 || {
	echo "error: jq not found" >&2
	exit 2
}
command -v helm >/dev/null 2>&1 || {
	echo "error: helm not found (Helm 3 required)" >&2
	exit 2
}
command -v base64 >/dev/null 2>&1 || {
	echo "error: base64 not found" >&2
	exit 2
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
	command -v terraform >/dev/null 2>&1 || die "terraform not on PATH (required for spoke kubeconfig merge)"
	MC_KUBECONFIG="$(mktemp "${TMPDIR:-/tmp}/001-acm-kubeconfig.XXXXXX")"
	chmod 600 "${MC_KUBECONFIG}"
	bash "${TF_LOGIN_SCRIPT}" --terraform-dir "${TF_DIR}" --output "${MC_KUBECONFIG}" "${INSECURE_LOGIN[@]}" &>/dev/null
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

# All logical cluster keys from Terraform (hub + spokes) — matches ManagedCluster metadata.name on the hub.
list_all_terraform_cluster_keys() {
	command -v terraform >/dev/null 2>&1 || return 1
	terraform -chdir="$TF_DIR" output -json cluster_keys 2>/dev/null | jq -r '(if type == "array" then . else [] end)[]'
}

extract_import_yaml_from_hub() {
	local cluster="$1"
	local hub="${CTX}"
	local raw sec

	# RHACM may expose import payloads as ${cluster}-import, auto-import-secret, or manual-import (see import docs).
	if raw="$(oc --context="$hub" get secret "${cluster}-import" -n "${cluster}" -o json 2>/dev/null)"; then
		sec="$(echo "$raw" | jq -r '.data["import.yaml"] // empty')"
		if [[ -n "$sec" ]]; then
			echo "$sec" | base64 -d
			return 0
		fi
	fi

	if raw="$(oc --context="$hub" get secret "auto-import-secret" -n "${cluster}" -o json 2>/dev/null)"; then
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

# Decode hub secret data key crds.yaml (${cluster}-import, auto-import-secret, or manual-import).
extract_crds_yaml_from_hub() {
	local cluster="$1"
	local hub="${CTX}"
	local raw sec

	if raw="$(oc --context="$hub" get secret "${cluster}-import" -n "${cluster}" -o json 2>/dev/null)"; then
		sec="$(echo "$raw" | jq -r '.data["crds.yaml"] // empty')"
		if [[ -n "$sec" ]]; then
			echo "$sec" | base64 -d
			return 0
		fi
	fi

	if raw="$(oc --context="$hub" get secret "auto-import-secret" -n "${cluster}" -o json 2>/dev/null)"; then
		sec="$(echo "$raw" | jq -r '.data["crds.yaml"] // empty')"
		if [[ -n "$sec" ]]; then
			echo "$sec" | base64 -d
			return 0
		fi
	fi

	if oc --context="$hub" get secret "import-${cluster}-manual-import" -n "${cluster}" &>/dev/null; then
		raw="$(oc --context="$hub" get secret "import-${cluster}-manual-import" -n "${cluster}" -o json)"
		sec="$(echo "$raw" | jq -r '.data["crds.yaml"] // empty')"
		if [[ -n "$sec" ]]; then
			echo "$sec" | base64 -d
			return 0
		fi
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

# Apply only CustomResourceDefinition documents first so the spoke API recognizes kinds (e.g. Klusterlet) before the rest.
apply_crd_documents_from_import_first() {
	local ctx="$1"
	local yaml="$2"
	local doc=""
	local line
	local applied=0
	while IFS= read -r line || [[ -n "${line:-}" ]]; do
		if [[ "$line" == "---" ]]; then
			if [[ -n "${doc//[$'\t\n\r ']/}" ]] && printf '%s' "$doc" | grep -q 'kind:[[:space:]]*CustomResourceDefinition'; then
				echo "${doc}" | oc --context="$ctx" apply -f -
				applied=1
			fi
			doc=""
		else
			doc+="${line}"$'\n'
		fi
	done <<< "${yaml}"
	if [[ -n "${doc//[$'\t\n\r ']/}" ]] && printf '%s' "$doc" | grep -q 'kind:[[:space:]]*CustomResourceDefinition'; then
		echo "${doc}" | oc --context="$ctx" apply -f -
		applied=1
	fi
	if ((applied)); then
		echo "Applied CRD manifest(s) from import bundle on spoke ${ctx}."
	else
		echo "No CustomResourceDefinition documents embedded in import.yaml for ${ctx}."
	fi
}

# Prefer hub secret key crds.yaml (RHACM); poll briefly; else split import.yaml for CRD kinds.
apply_hub_crds_yaml_then_fallback_embedded() {
	local cluster="$1"
	local import_yaml="$2"
	local hub_crds=""
	local deadline=$((SECONDS + ACM_CRDS_YAML_WAIT_SEC))
	while ((SECONDS < deadline)); do
		if hub_crds="$(extract_crds_yaml_from_hub "$cluster" 2>/dev/null)" && [[ -n "${hub_crds//[$'\t\n\r ']/}" ]]; then
			echo "Applying hub secret crds.yaml on spoke ${cluster}..."
			echo "${hub_crds}" | oc --context="$cluster" apply -f -
			return 0
		fi
		sleep 5
	done
	echo "hub secret crds.yaml not available within ${ACM_CRDS_YAML_WAIT_SEC}s; trying CRD documents inside import.yaml..."
	apply_crd_documents_from_import_first "$cluster" "$import_yaml"
}

# Full multi-document import.yaml; retries until CRDs/operators on the spoke have settled.
apply_import_bundle_with_retry() {
	local cluster="$1"
	local yaml="$2"
	local deadline=$((SECONDS + ACM_IMPORT_APPLY_RETRY_SEC))
	while ((SECONDS < deadline)); do
		if echo "${yaml}" | oc --context="$cluster" apply -f -; then
			return 0
		fi
		echo "warn: oc apply on spoke ${cluster} failed (retrying until ${ACM_IMPORT_APPLY_RETRY_SEC}s; CRDs/operators may still be registering)..." >&2
		sleep 15
	done
	die "oc apply on spoke ${cluster} failed after ${ACM_IMPORT_APPLY_RETRY_SEC}s; check: oc --context=${cluster} get crd | grep -i klusterlet"
}

# Per spoke: Helm ManagedCluster on hub → wait hub import/auto-import secret → CRDs on spoke → full import.yaml on spoke.
register_spoke_cluster() {
	local k="$1"
	local rel="${RELEASE_MC_PREFIX}-${k}"

	echo ""
	echo "========== Spoke: ${k} =========="

	if ((DRY_RUN)); then
		helm template "$rel" "$CHART_MANAGED_CLUSTER" \
			--namespace "$ACM_NAMESPACE" \
			--set managedCluster.name="$k" \
			--set clustersetName="${ACM_CLUSTER_SET:-istio-scale-tests}" >/dev/null
		echo "dry-run: would wait for hub import secret, apply crds.yaml (or embedded CRDs), then full import.yaml on context ${k}."
		return 0
	fi

	echo "1) Helm ManagedCluster on hub: release ${rel} (label cluster.open-cluster-management.io/clusterset=${ACM_CLUSTER_SET:-istio-scale-tests})"
	helm --kube-context "$CTX" upgrade --install "$rel" "$CHART_MANAGED_CLUSTER" \
		--namespace "$ACM_NAMESPACE" \
		--create-namespace \
		--set managedCluster.name="$k" \
		--set clustersetName="${ACM_CLUSTER_SET:-istio-scale-tests}"

	if ((SKIP_IMPORT)); then
		echo "Skipping import for ${k} (--skip-import)."
		return 0
	fi

	echo "2) Waiting for hub import / auto-import secret (import.yaml) for ${k}..."
	local yaml=""
	if ! yaml="$(wait_import_yaml_from_hub "$k")"; then
		die "timed out after ${ACM_IMPORT_WAIT_SEC}s waiting for import secret on hub for cluster ${k} (${k}-import / auto-import-secret / manual-import; see RHACM import docs)."
	fi

	echo "3) Applying CRDs on spoke ${k} (hub secret crds.yaml, else CRDs embedded in import.yaml)"
	apply_hub_crds_yaml_then_fallback_embedded "$k" "$yaml"

	echo "4) Applying full import.yaml on spoke ${k}"
	apply_import_bundle_with_retry "$k" "$yaml"
	echo "Spoke ${k} import applied."
}

# ------------------------------------------------------------------------------
# Spokes: one Helm release + import sequence per cluster (hub uses merged kubeconfig when enabled)
# ------------------------------------------------------------------------------
helm_managed_clusters_and_import() {
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
		echo "No spoke clusters in Terraform (hub only); skipping ${CHART_MANAGED_CLUSTER}."
		return 0
	fi

	local k
	for k in "${keys[@]}"; do
		[[ -z "$k" ]] && continue
		register_spoke_cluster "$k"
	done
}

# OCM ManagedCluster: ManagedClusterJoined + ManagedClusterConditionAvailable must be True (open-cluster-management.io/api).
managed_cluster_joined_and_available() {
	local name="$1"
	oc --context="$CTX" get managedcluster "$name" -o json 2>/dev/null | jq -e '
		(.status.conditions // []) as $c
		| (($c | map(select(.type=="ManagedClusterJoined")) | .[0].status // "") == "True")
		  and
		  (($c | map(select(.type=="ManagedClusterConditionAvailable")) | .[0].status // "") == "True")
	' >/dev/null
}

wait_for_all_managed_clusters_ready() {
	if [[ "${ACM_WAIT_MANAGED_CLUSTER_READY:-1}" != "1" ]]; then
		echo "Skipping ManagedCluster Ready wait (ACM_WAIT_MANAGED_CLUSTER_READY!=1)."
		return 0
	fi
	if ((SKIP_MANAGED_CLUSTERS)); then
		echo "Skipping ManagedCluster Ready wait (--skip-managed-clusters)."
		return 0
	fi
	if ((SKIP_IMPORT)); then
		echo "Skipping ManagedCluster Ready wait (--skip-import)."
		return 0
	fi

	local -a names
	if ! mapfile -t names < <(list_all_terraform_cluster_keys); then
		echo "warn: Terraform cluster_keys unavailable; skipping ManagedCluster Ready wait." >&2
		return 0
	fi
	if ((${#names[@]} == 0)); then
		return 0
	fi

	echo "--- 6) Wait until all ManagedClusters are Joined and Available (hub) ---"
	echo "Expecting ManagedCluster objects: ${names[*]}"

	local deadline=$((SECONDS + ACM_MANAGED_CLUSTER_READY_WAIT_SEC))
	local iter=0
	while ((SECONDS < deadline)); do
		local all_ok=1
		local pending=""
		local n
		for n in "${names[@]}"; do
			[[ -z "$n" ]] && continue
			if ! managed_cluster_joined_and_available "$n"; then
				all_ok=0
				pending+="${n} "
			fi
		done
		if ((all_ok)); then
			echo "All ManagedClusters Ready (Joined+Available): ${names[*]}"
			return 0
		fi
		((iter++))
		if ((iter % 4 == 1)); then
			echo "Still waiting for: ${pending:-unknown}"
		fi
		sleep 15
	done

	echo "ManagedCluster status (debug):" >&2
	for n in "${names[@]}"; do
		[[ -z "$n" ]] && continue
		if ! oc --context="$CTX" get managedcluster "$n" -o json 2>/dev/null \
			| jq -e --arg n "$n" '{name:$n, joined:(.status.conditions // []) | map(select(.type=="ManagedClusterJoined")) | .[0], avail:(.status.conditions // []) | map(select(.type=="ManagedClusterConditionAvailable")) | .[0]}' >&2; then
			echo "(no ManagedCluster named ${n})" >&2
		fi
	done
	die "Timed out after ${ACM_MANAGED_CLUSTER_READY_WAIT_SEC}s waiting for ManagedClusters Joined+Available."
}

wait_for_acm_csv_succeeded() {
	echo "Waiting for advanced-cluster-management ClusterServiceVersion (up to 15m)..."
	local found=""
	for _ in $(seq 1 90); do
		found="$(oc --context="$CTX" get csv -n "${ACM_NAMESPACE}" -o json 2>/dev/null | jq -r '
			.items[]
			| select(.metadata.name | test("^advanced-cluster-management\\."))
			| select(.status.phase != null)
			| .metadata.name + " " + .status.phase
		' | head -1 || true)"
		if [[ -n "$found" ]]; then
			local ph="${found##* }"
			[[ "$ph" == "Succeeded" ]] && break
		fi
		sleep 10
	done
	[[ "${found##* }" == "Succeeded" ]] || die "CSV did not reach Succeeded (last: ${found:-none}). Check: oc --context=$CTX get csv -n ${ACM_NAMESPACE}"
	echo "ACM operator CSV ready: ${found}"
}

wait_for_multicluster_hub_running() {
	echo "Waiting for MultiClusterHub phase Running (up to 20m)..."
	local ph=""
	for _ in $(seq 1 120); do
		ph="$(oc --context="$CTX" get multiclusterhub multiclusterhub -n "${ACM_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
		if [[ "$ph" == "Running" ]]; then
			echo "MultiClusterHub status: Running"
			return 0
		fi
		sleep 10
	done
	die "MultiClusterHub did not reach Running in time; check: oc --context=$CTX get mch -n ${ACM_NAMESPACE} -o yaml"
}

wait_for_klusterletconfig_crd() {
	local deadline=$((SECONDS + ACM_KLUSTERLETCONFIG_CRD_WAIT_SEC))
	echo "Waiting for KlusterletConfig CRD klusterletconfigs.config.open-cluster-management.io (up to ${ACM_KLUSTERLETCONFIG_CRD_WAIT_SEC}s)..."
	while ((SECONDS < deadline)); do
		if oc --context="$CTX" get crd klusterletconfigs.config.open-cluster-management.io &>/dev/null; then
			echo "KlusterletConfig CRD is available."
			return 0
		fi
		sleep 10
	done
	die "Timed out waiting for KlusterletConfig CRD. Increase ACM_KLUSTERLETCONFIG_CRD_WAIT_SEC or set ACM_INSTALL_KLUSTERLETCONFIG=0."
}

wait_for_ocm_webhook_ready() {
	local deadline=$((SECONDS + ACM_OCM_WEBHOOK_READY_WAIT_SEC))
	echo "Waiting for OCM validating webhook TLS readiness (up to ${ACM_OCM_WEBHOOK_READY_WAIT_SEC}s)..."
	while ((SECONDS < deadline)); do
		if oc --context="$CTX" create -f - --dry-run=server 2>/dev/null <<-'PROBE'
			apiVersion: cluster.open-cluster-management.io/v1
			kind: ManagedCluster
			metadata:
			  name: ocm-webhook-probe
			spec:
			  hubAcceptsClient: false
		PROBE
		then
			echo "OCM validating webhook is ready."
			return 0
		fi
		sleep 10
	done
	die "OCM webhook not ready after ${ACM_OCM_WEBHOOK_READY_WAIT_SEC}s; check: oc --context=${CTX} get validatingwebhookconfigurations ocm.validating.webhook.admission.open-cluster-management.io -o yaml"
}

lint_charts() {
	helm lint "$CHART_OPERATOR" >/dev/null || die "helm lint failed: ${CHART_OPERATOR}"
	helm lint "$CHART_MULTICLUSTER_HUB" >/dev/null || die "helm lint failed: ${CHART_MULTICLUSTER_HUB}"
	helm lint "$CHART_KLUSTERLET_CONFIG" >/dev/null || die "helm lint failed: ${CHART_KLUSTERLET_CONFIG}"
	helm lint "$CHART_MANAGED_CLUSTER" --set managedCluster.name=helm-lint-placeholder >/dev/null \
		|| die "helm lint failed: ${CHART_MANAGED_CLUSTER}"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
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

[[ -d "$CHART_OPERATOR" ]] || die "chart not found: ${CHART_OPERATOR}"
[[ -d "$CHART_MULTICLUSTER_HUB" ]] || die "chart not found: ${CHART_MULTICLUSTER_HUB}"
[[ -d "$CHART_KLUSTERLET_CONFIG" ]] || die "chart not found: ${CHART_KLUSTERLET_CONFIG}"
[[ -d "$CHART_MANAGED_CLUSTER" ]] || die "chart not found: ${CHART_MANAGED_CLUSTER}"

echo "Hub context: ${CTX}"
echo "MultiClusterHub spec.localClusterName: ${LOCAL_CLUSTER_NAME}"
echo "Charts: ${CHART_OPERATOR} → ${CHART_MULTICLUSTER_HUB} → ${CHART_KLUSTERLET_CONFIG}; spokes: ${CHART_MANAGED_CLUSTER}"

if ((DRY_RUN == 0)); then
	ocv="$(oc --context="$CTX" version -o json 2>/dev/null | jq -r '.openshiftVersion // empty')"
	if [[ -n "$ocv" ]]; then
		echo "Hub cluster OpenShift version: ${ocv}"
		majmin_env="${OPENSHIFT_VERSION%.*}"
		majmin_cls="${ocv%.*}"
		if [[ "$majmin_env" != "$majmin_cls" ]]; then
			echo "warn: hub cluster minor ${majmin_cls} differs from OPENSHIFT_VERSION minor ${majmin_env} — verify ACM_CHANNEL matches RHACM support matrix." >&2
		fi
	fi
fi

lint_charts

# --- 1) ACM operator (OLM) ---
echo "--- 1) Install ACM operator (Helm: ${RELEASE_OPERATOR}) ---"
helm_operator_cmd=(
	helm --kube-context "$CTX" upgrade --install "$RELEASE_OPERATOR" "$CHART_OPERATOR"
	--namespace "$ACM_NAMESPACE"
	--create-namespace
	--set subscription.channel="$ACM_CHANNEL"
)
if ((DRY_RUN)); then
	helm_operator_cmd+=(--dry-run=client)
fi
"${helm_operator_cmd[@]}"

if ((DRY_RUN)); then
	echo "--- dry-run: render MultiClusterHub + KlusterletConfig (no cluster CRDs required) ---"
	helm template "$RELEASE_MULTICLUSTER_HUB" "$CHART_MULTICLUSTER_HUB" \
		--namespace "$ACM_NAMESPACE" \
		--set-string multiclusterHub.spec.localClusterName="$LOCAL_CLUSTER_NAME" >/dev/null
	helm template "$RELEASE_KLUSTERLET_CONFIG" "$CHART_KLUSTERLET_CONFIG" \
		--namespace "$ACM_NAMESPACE" >/dev/null
	helm_managed_clusters_and_import || die "spoke dry-run failed."
	echo "dry-run: would wait for ManagedCluster Joined+Available on hub for each Terraform cluster_keys name."
	exit 0
fi

if ((SKIP_WAIT)); then
	echo "Skipping waits (--skip-wait). Operator subscription applied; re-run without --skip-wait for MultiClusterHub, KlusterletConfig, and spokes."
	exit 0
fi

wait_for_acm_csv_succeeded

# --- 2) MultiClusterHub ---
echo "--- 2) Install MultiClusterHub (Helm: ${RELEASE_MULTICLUSTER_HUB}) ---"
helm --kube-context "$CTX" upgrade --install "$RELEASE_MULTICLUSTER_HUB" "$CHART_MULTICLUSTER_HUB" \
	--namespace "$ACM_NAMESPACE" \
	--create-namespace \
	--set-string multiclusterHub.spec.localClusterName="$LOCAL_CLUSTER_NAME"

wait_for_multicluster_hub_running

# --- 3) KlusterletConfig (optional) ---
if [[ "${ACM_INSTALL_KLUSTERLETCONFIG}" == "1" ]]; then
	wait_for_klusterletconfig_crd
	echo "--- 3) Install KlusterletConfig (Helm: ${RELEASE_KLUSTERLET_CONFIG}) ---"
	helm --kube-context "$CTX" upgrade --install "$RELEASE_KLUSTERLET_CONFIG" "$CHART_KLUSTERLET_CONFIG" \
		--namespace "$ACM_NAMESPACE" \
		--create-namespace
else
	echo "--- 3) Skipping KlusterletConfig (ACM_INSTALL_KLUSTERLETCONFIG!=1) ---"
fi

wait_for_ocm_webhook_ready

# --- 4) Spokes ---
echo "--- 4) Register spoke clusters ---"
helm_managed_clusters_and_import || die "spoke registration failed."

wait_for_all_managed_clusters_ready

echo "Done."
exit 0

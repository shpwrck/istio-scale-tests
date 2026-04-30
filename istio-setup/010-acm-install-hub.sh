#!/usr/bin/env bash
# Install Red Hat Advanced Cluster Management hub on one OpenShift cluster (OperatorHub subscription + MultiClusterHub).
# Pair OpenShift and ACM trains using config/versions.env (defaults: OCP 4.18.x + ACM channel release-2.15).
#
# Ref: https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html/install/installing-advanced-cluster-management
# Support matrix: https://access.redhat.com/articles/7133095
#
# Requires: oc, jq; optional terraform (to resolve kube context from terraform/rosa-hcp outputs).
# Usage (repo root):
#   ./istio-setup/010-acm-install-hub.sh [--context NAME] [--terraform-dir DIR] [--dry-run] [--skip-wait]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

die() { echo "error: $*" >&2; exit 1; }

CONTEXT=""
DRY_RUN=0
SKIP_WAIT=0
TF_DIR="${ACM_TERRAFORM_DIR:-${ROOT}/terraform/rosa-hcp}"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  Install RHACM hub operator on the target cluster (namespace ${ACM_NAMESPACE}).

  --context NAME       kube/oc context (recommended). If omitted, tries ACM_HUB_CONTEXT,
                       then matches terraform output first_cluster.cluster_api_url to kubeconfig.
  --terraform-dir DIR  Terraform root with applied state (default: ${ROOT}/terraform/rosa-hcp).
  --dry-run            oc apply --dry-run=client only.
  --skip-wait          Do not wait for CSV / MultiClusterHub Running.

Environment:
  ACM_HUB_CONTEXT      Default context when --context is omitted.
  ACM_CHANNEL          OLM channel (default ${ACM_CHANNEL} from versions.env).
  ACM_NAMESPACE        Install namespace (default ${ACM_NAMESPACE}).
  ACM_TERRAFORM_DIR    Override terraform root for auto context resolution.

OpenShift ${OPENSHIFT_VERSION} is pinned with ACM channel ${ACM_CHANNEL}; bump both together per RHACM support matrix.
Requires cluster-admin on the hub.
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
	[[ -n "$matched" ]] || die "no kube context with server ${api}; login with oc login or pass --context."
	echo "$matched"
}

CTX="$(resolve_context)"

apply=(oc apply)
((DRY_RUN)) && apply=(oc apply --dry-run=client)

echo "Using context: ${CTX}"
echo "ACM channel: ${ACM_CHANNEL} (OpenShift pin in versions.env: ${OPENSHIFT_VERSION})"

if ((DRY_RUN == 0)); then
	ocv="$(oc --context="$CTX" version -o json 2>/dev/null | jq -r '.openshiftVersion // empty')"
	if [[ -n "$ocv" ]]; then
		echo "Cluster reports OpenShift version: ${ocv}"
		majmin_env="${OPENSHIFT_VERSION%.*}"
		majmin_cls="${ocv%.*}"
		if [[ "$majmin_env" != "$majmin_cls" ]]; then
			echo "warn: cluster minor ${majmin_cls} differs from OPENSHIFT_VERSION minor ${majmin_env} — verify ACM_CHANNEL matches RHACM support matrix." >&2
		fi
	fi
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"${tmp}/namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${ACM_NAMESPACE}
EOF

cat >"${tmp}/operatorgroup.yaml" <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: default
  namespace: ${ACM_NAMESPACE}
spec:
  targetNamespaces:
  - ${ACM_NAMESPACE}
EOF

cat >"${tmp}/subscription.yaml" <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: acm-operator-subscription
  namespace: ${ACM_NAMESPACE}
spec:
  sourceNamespace: openshift-marketplace
  source: redhat-operators
  channel: ${ACM_CHANNEL}
  installPlanApproval: Automatic
  name: advanced-cluster-management
EOF

cat >"${tmp}/multiclusterhub.yaml" <<EOF
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: ${ACM_NAMESPACE}
spec: {}
EOF

"${apply[@]}" --context="$CTX" -f "${tmp}/namespace.yaml"
"${apply[@]}" --context="$CTX" -f "${tmp}/operatorgroup.yaml"
"${apply[@]}" --context="$CTX" -f "${tmp}/subscription.yaml"

if ((DRY_RUN)); then
	echo "dry-run: skipping CSV wait and MultiClusterHub apply."
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

oc --context="$CTX" apply -f "${tmp}/multiclusterhub.yaml"

if ((SKIP_WAIT)); then
	echo "Skipping MultiClusterHub status wait (--skip-wait)."
	echo "Done (apply issued)."
	exit 0
fi

echo "Waiting for MultiClusterHub phase Running (up to 20m)..."
for _ in $(seq 1 120); do
	ph="$(oc --context="$CTX" get multiclusterhub multiclusterhub -n "${ACM_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
	if [[ "$ph" == "Running" ]]; then
		echo "MultiClusterHub status: Running"
		echo "Done."
		exit 0
	fi
	sleep 10
done

die "MultiClusterHub did not reach Running in time; check: oc --context=$CTX get mch -n ${ACM_NAMESPACE} -o yaml"

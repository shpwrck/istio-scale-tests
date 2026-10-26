#!/usr/bin/env bash
# Read-only check of a saved platform plan: does it create an object that exists on the hub?
#
# Objects outlive a lost Terraform state (a rebuild from scratch, a deleted state file). The
# apply then stops partway with "Cannot create resource that already exists" (kubernetes
# provider) or "cannot re-use a name that is still in use" (Helm): on the homelab rebuild of
# 2026-10-26, at two RBAC objects an earlier deployment had left. This lists every object the
# plan creates that exists already, with the terraform import command that adopts it. Run it
# between the plan and the apply; a non-zero exit means: import or delete those objects, then
# plan again.
#
# Usage (in terraform/platform):
#   terraform plan -out=platform.tfplan
#   ./scripts/002-plan-leftover-check.sh platform.tfplan
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"

KUBECONFIG_FILE=""
CONTEXT=""
PLAN=""

usage() {
	cat >&2 <<EOF
Usage: ${0##*/} [--kubeconfig PATH] [--context NAME] PLANFILE

  PLANFILE           A saved plan of terraform/platform (terraform plan -out=PLANFILE).
  --kubeconfig PATH  The hub's kubeconfig (default: the plan's kubeconfig_path; with
                     cluster_provider = "rosa", terraform/rosa-hcp/kubeconfig).
  --context NAME     The hub's context (default: the plan's hub_cluster_context; with
                     cluster_provider = "rosa", the kubeconfig's current context, the hub).

Lists every object the plan creates on the hub (kubernetes_manifest, helm_release,
kubernetes_secret_v1) that exists there already, with the terraform import command that adopts
it. Exit 0: none exists; 1: some exist, or the hub could not be read. Changes neither the hub
nor the state.
EOF
}

while (($#)); do
	case "$1" in
		--kubeconfig)
			[[ -n "${2:-}" ]] || die "--kubeconfig requires a value"
			KUBECONFIG_FILE="$2"; shift 2 ;;
		--context)
			[[ -n "${2:-}" ]] || die "--context requires a value"
			CONTEXT="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		-*) usage; die "unknown argument: $1" ;;
		*)
			[[ -z "$PLAN" ]] || die "one plan file only (got: $PLAN and $1)"
			PLAN="$1"; shift ;;
	esac
done

[[ -n "$PLAN" ]] || { usage; die "PLANFILE is required"; }
[[ -f "$PLAN" ]] || die "no plan file: $PLAN"
PLAN="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"
command -v terraform >/dev/null 2>&1 || die "terraform is required"
command -v kubectl >/dev/null 2>&1 || die "kubectl is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

# terraform show reads the plan with the providers of the root that wrote it.
json="$(cd "${ROOT}/terraform/platform" && terraform show -json "$PLAN")" \
	|| die "terraform show -json ${PLAN} failed: run it in terraform/platform after terraform init"

provider="$(jq -r '.variables.cluster_provider.value // "kubeconfig"' <<<"$json")"
if [[ -z "$KUBECONFIG_FILE" ]]; then
	if [[ "$provider" == rosa ]]; then
		KUBECONFIG_FILE="${ROOT}/terraform/rosa-hcp/kubeconfig"
	else
		KUBECONFIG_FILE="$(jq -r '.variables.kubeconfig_path.value // ""' <<<"$json")"
	fi
fi
if [[ -z "$CONTEXT" && "$provider" != rosa ]]; then
	CONTEXT="$(jq -r '.variables.hub_cluster_context.value // ""' <<<"$json")"
fi
KUBECONFIG_FILE="${KUBECONFIG_FILE/#\~/$HOME}"
[[ -f "$KUBECONFIG_FILE" ]] || die "no kubeconfig file: ${KUBECONFIG_FILE:-<none>} (set --kubeconfig)"
KC=(kubectl "--kubeconfig=${KUBECONFIG_FILE}" --request-timeout=30s)
if [[ -n "$CONTEXT" ]]; then KC+=("--context=${CONTEXT}"); fi

# One line per object the plan creates: address, import ID, what it is, namespace, then the
# kubectl type, name and label selector that find it ("-" for an empty field: read collapses
# empty tabs). A Helm release is found by the Secret Helm keeps for it.
objects="$(jq -r '
	def row(id; what; ns; type; name; sel): [.address, id, what, (ns // "-"), type, (name // "-"), (sel // "-")] | join("\t");
	.resource_changes[]?
	| select(.change.actions == ["create"])
	| if .type == "kubernetes_manifest" then
			(.change.after.manifest // {}) as $m
			| ($m.apiVersion // "" | split("/")) as $gv
			| if ($m.kind // "") == "" or ($m.metadata.name // "") == "" then "unknown\t\(.address)"
				else row(
					"apiVersion=\($m.apiVersion),kind=\($m.kind)" + (if $m.metadata.namespace then ",namespace=\($m.metadata.namespace)" else "" end) + ",name=\($m.metadata.name)";
					"\($m.kind) \($m.metadata.name)";
					$m.metadata.namespace;
					($m.kind | ascii_downcase) + (if ($gv | length) == 2 then ".\($gv[1]).\($gv[0])" else "" end);
					$m.metadata.name; null)
				end
		elif .type == "helm_release" then
			(.change.after.namespace // "default") as $ns
			| if (.change.after.name // "") == "" then "unknown\t\(.address)"
				else row("\($ns)/\(.change.after.name)"; "Helm release \(.change.after.name)"; $ns; "secret"; null; "owner=helm,name=\(.change.after.name)") end
		elif .type == "kubernetes_secret_v1" then
			(.change.after.metadata[0] // {}) as $md
			| ($md.namespace // "default") as $ns
			| if ($md.name // "") == "" then "unknown\t\(.address)"
				else row("\($ns)/\($md.name)"; "Secret \($md.name)"; $ns; "secret"; $md.name; null) end
		else empty end
' <<<"$json")"

echo "=== Objects this plan creates that exist on the hub already ==="
echo "Hub: ${KUBECONFIG_FILE}${CONTEXT:+, context ${CONTEXT}}"
n=0 found=0 failed=0
while IFS=$'\t' read -r addr id what ns type name sel; do
	[[ -n "$addr" ]] || continue
	if [[ "$addr" == unknown ]]; then
		echo "  cannot check ${id}: its name is known only at apply"
		failed=$((failed + 1))
		continue
	fi
	n=$((n + 1))
	args=(get "$type")
	if [[ "$name" != - ]]; then args+=("$name"); fi
	if [[ "$sel" != - ]]; then args+=(-l "$sel"); fi
	if [[ "$ns" != - ]]; then args+=(-n "$ns"); fi
	if out="$("${KC[@]}" "${args[@]}" -o name --ignore-not-found 2>&1)"; then
		[[ -n "$out" ]] || continue
		found=$((found + 1))
		if [[ "$ns" != - ]]; then what+=" in ${ns}"; fi
		echo "  ${addr}: ${what} exists"
		echo "    terraform import '${addr}' '${id}'"
	elif [[ "$out" == *"have a resource type"* ]]; then
		continue # its CRD is not installed yet, so neither is the object
	else
		echo "  cannot check ${addr}: $(tr '\n' ' ' <<<"$out")"
		failed=$((failed + 1))
	fi
done <<<"$objects"

if ((failed)); then
	echo "error: ${failed} object(s) could not be checked: this plan may still stop on one that exists" >&2
	exit 1
fi
if ((found)); then
	echo "error: ${found} of the ${n} objects this plan creates exist on the hub already: an earlier apply whose state is lost left them, or something else made them. Adopt each one with its terraform import command above, or delete the ones nothing needs (deleting a namespace deletes everything in it); then plan again." >&2
	exit 1
fi
echo "None of the ${n} objects this plan creates exists on the hub yet."

#!/usr/bin/env bats
# terraform/platform/scripts/002-plan-leftover-check.sh against a stub terraform (show -json
# prints a fixture plan) and a stub kubectl: every object the plan creates that exists on the
# hub is listed with its terraform import command; updates and non-cluster resources are not
# checked; a hub it cannot read fails the check.

bats_require_minimum_version 1.5.0
load test_helper

SCRIPT="${ROOT}/terraform/platform/scripts/002-plan-leftover-check.sh"

# plan_json <cluster_provider> <name of the Subscription>: a plan that creates a ClusterRole, a
# Subscription, an OperatorGroup, a Helm release and an ACM auto-import Secret, and updates a
# Namespace and creates a terraform_data (neither is checked).
plan_json() {
	cat <<EOF
{"format_version":"1.2","variables":{"cluster_provider":{"value":"$1"},"kubeconfig_path":{"value":"${STUB_DIR}/kubeconfig"},"hub_cluster_context":{"value":"hub"}},
"resource_changes":[
{"address":"kubernetes_manifest.appset_cluster_role[0]","type":"kubernetes_manifest","change":{"actions":["create"],"after":{"manifest":{"apiVersion":"rbac.authorization.k8s.io/v1","kind":"ClusterRole","metadata":{"name":"openshift-gitops-applicationset-controller"}}}}},
{"address":"kubernetes_manifest.gitops_subscription[0]","type":"kubernetes_manifest","change":{"actions":["create"],"after":{"manifest":{"apiVersion":"operators.coreos.com/v1alpha1","kind":"Subscription","metadata":{"name":$2,"namespace":"openshift-gitops-operator"}}}}},
{"address":"kubernetes_manifest.gitops_operator_group[0]","type":"kubernetes_manifest","change":{"actions":["create"],"after":{"manifest":{"apiVersion":"operators.coreos.com/v1","kind":"OperatorGroup","metadata":{"name":"openshift-gitops-operator","namespace":"openshift-gitops-operator"}}}}},
{"address":"helm_release.argocd_config[0]","type":"helm_release","change":{"actions":["create"],"after":{"name":"argocd-config","namespace":"openshift-gitops"}}},
{"address":"kubernetes_secret_v1.auto_import[\"mesh-a\"]","type":"kubernetes_secret_v1","change":{"actions":["create"],"after":{"metadata":[{"name":"auto-import-secret","namespace":"mesh-a"}]}}},
{"address":"kubernetes_manifest.acm_namespace[0]","type":"kubernetes_manifest","change":{"actions":["update"],"after":{"manifest":{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"open-cluster-management"}}}}},
{"address":"terraform_data.acm_csv_cleanup[0]","type":"terraform_data","change":{"actions":["create"],"after":{}}}
]}
EOF
}

setup() {
	STUB_DIR="${BATS_TEST_TMPDIR}/stub"
	STUB_LOG="${STUB_DIR}/calls.log"
	export STUB_DIR STUB_LOG
	mkdir -p "${STUB_DIR}/bin"
	: >"$STUB_LOG"
	: >"${STUB_DIR}/kubeconfig"
	: >"${STUB_DIR}/exists"
	plan_json kubeconfig '"openshift-gitops-operator"' >"${STUB_DIR}/plan.json"
	: >"${STUB_DIR}/platform.tfplan"
	cat >"${STUB_DIR}/bin/terraform" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == "show -json" && -f "$3" ]] || exit 1
cat "$STUB_DIR/plan.json"
EOF
	# kubectl: an object whose "<type> <name or selector>" is a line of $STUB_DIR/exists is
	# there; the OperatorGroup's CRD is not installed; KUBECTL_FAIL=1 fails every read.
	cat >"${STUB_DIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STUB_LOG"
[[ "${KUBECTL_FAIL:-0}" == 1 ]] && { echo "error: You must be logged in to the server (Unauthorized)" >&2; exit 1; }
set -- "${@:4}"
[[ "$1" == get ]] || exit 1
if [[ "$2" == operatorgroup.* ]]; then echo "error: the server doesn't have a resource type \"operatorgroup\"" >&2; exit 1; fi
key="$2 $3"
[[ "$3" == -l ]] && key="$2 $4"
if grep -qxF -- "$key" "$STUB_DIR/exists"; then echo "${2%%.*}/x"; fi
exit 0
EOF
	chmod +x "${STUB_DIR}/bin/terraform" "${STUB_DIR}/bin/kubectl"
	export PATH="${STUB_DIR}/bin:${PATH}"
}

@test "each object the plan creates that exists is listed with its import command; updates and terraform_data are not read" {
	printf '%s\n' "clusterrole.v1.rbac.authorization.k8s.io openshift-gitops-applicationset-controller" \
		"secret owner=helm,name=argocd-config" "secret auto-import-secret" >"${STUB_DIR}/exists"
	run bash "$SCRIPT" "${STUB_DIR}/platform.tfplan"
	assert_failure
	assert_output --partial "kubernetes_manifest.appset_cluster_role[0]: ClusterRole openshift-gitops-applicationset-controller exists"
	assert_output --partial "terraform import 'kubernetes_manifest.appset_cluster_role[0]' 'apiVersion=rbac.authorization.k8s.io/v1,kind=ClusterRole,name=openshift-gitops-applicationset-controller'"
	assert_output --partial "helm_release.argocd_config[0]: Helm release argocd-config in openshift-gitops exists"
	assert_output --partial "terraform import 'helm_release.argocd_config[0]' 'openshift-gitops/argocd-config'"
	assert_output --partial "terraform import 'kubernetes_secret_v1.auto_import[\"mesh-a\"]' 'mesh-a/auto-import-secret'"
	assert_output --partial "error: 3 of the 5 objects this plan creates exist on the hub already"
	refute_output --partial "gitops_subscription"
	refute_output --partial "operator_group"
	# One read per created object, with the plan's kubeconfig and hub context.
	[ "$(wc -l <"$STUB_LOG")" -eq 5 ]
	[ "$(grep -c -- "--kubeconfig=${STUB_DIR}/kubeconfig --request-timeout=30s --context=hub get " "$STUB_LOG")" -eq 5 ]
	grep -q 'get subscription.v1alpha1.operators.coreos.com openshift-gitops-operator -n openshift-gitops-operator -o name --ignore-not-found' "$STUB_LOG"
	run ! grep -q 'namespace\|acm_csv' "$STUB_LOG"
}

@test "none exists: exit 0; a hub it cannot read, or a name known only at apply, fails the check" {
	run bash "$SCRIPT" "${STUB_DIR}/platform.tfplan"
	assert_success
	assert_output --partial "None of the 5 objects this plan creates exists on the hub yet."
	KUBECTL_FAIL=1 run bash "$SCRIPT" --context other "${STUB_DIR}/platform.tfplan"
	assert_failure
	assert_output --partial "cannot check kubernetes_manifest.appset_cluster_role[0]: error: You must be logged in to the server (Unauthorized)"
	assert_output --partial "error: 5 object(s) could not be checked"
	grep -q -- '--context=other get ' "$STUB_LOG"
	plan_json kubeconfig null >"${STUB_DIR}/plan.json"
	run bash "$SCRIPT" "${STUB_DIR}/platform.tfplan"
	assert_failure
	assert_output --partial "cannot check kubernetes_manifest.gitops_subscription[0]: its name is known only at apply"
}

@test "with cluster_provider rosa the hub is terraform/rosa-hcp/kubeconfig's current context; a missing plan is refused" {
	plan_json rosa '"openshift-gitops-operator"' >"${STUB_DIR}/plan.json"
	run bash "$SCRIPT" "${STUB_DIR}/platform.tfplan"
	if [[ -f "${ROOT}/terraform/rosa-hcp/kubeconfig" ]]; then
		run ! grep -q -- '--context=' "$STUB_LOG"
	else
		assert_failure
		assert_output --partial "no kubeconfig file: ${ROOT}/terraform/rosa-hcp/kubeconfig"
	fi
	run bash "$SCRIPT" "${STUB_DIR}/missing.tfplan"
	assert_failure
	assert_output --partial "no plan file: ${STUB_DIR}/missing.tfplan"
}

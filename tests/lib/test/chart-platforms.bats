#!/usr/bin/env bats
# The charts on both platforms (kubernetes by default, openshift through overlays): every
# chart with a values-openshift.yaml renders both ways and its Kubernetes render never names
# OpenShift; the ApplicationSet presets select the members by the cluster-Secret label in
# argocd on kubernetes, and by the ACM Placement in openshift-gitops, with each member
# chart's values-openshift.yaml (which must exist), on openshift; the app-of-apps hands its
# children the platform's presets and operator sources; any other platform fails the render;
# the gate's ApplicationSet, with Terraform's values, gives each member's gate the members' names
# and its own on both platforms. Needs helm; skips without it.

bats_require_minimum_version 1.5.0
load test_helper

APPSET="${ROOT}/charts/gitops-hub-ocm-placement-appset"
REPO=(--set repo.url=https://example.invalid/istio-scale-tests.git --set repo.revision=main)
# Member charts render only with a cluster name (the ApplicationSet sets it), the Gateway API
# check also with its workload member; the other charts ignore both.
MEMBER=(--set clusterName=member-a --set workloadCluster=member-a)
# Charts that only the openshift platform installs (OLM), so their defaults are OpenShift's.
OPENSHIFT_ONLY_CHARTS=" cert-manager-operator external-secrets-operator spoke-ossm-operator "
# Presets that only the openshift platform uses (OLM).
OPENSHIFT_ONLY_PRESETS=" values-ossm-operator.yaml values-external-secrets-olm.yaml "

setup() {
	command -v helm >/dev/null 2>&1 || skip "helm not installed"
}

# overlay_charts: every chart dir with a values-openshift.yaml, one per line.
overlay_charts() {
	local o
	for o in "${ROOT}"/charts/*/values-openshift.yaml "${ROOT}"/tests/*/chart/values-openshift.yaml; do
		[[ -f "$o" ]] && dirname "$o"
	done
}

@test "charts: every chart with a values-openshift.yaml renders with its defaults and with the overlay" {
	local c n=0
	while IFS= read -r c; do
		helm template t "$c" "${MEMBER[@]}" >/dev/null || { echo "${c#"$ROOT"/}: the kubernetes (default) render fails"; false; }
		helm template t "$c" -f "${c}/values-openshift.yaml" "${MEMBER[@]}" >/dev/null || { echo "${c#"$ROOT"/}: the openshift render fails"; false; }
		n=$((n + 1))
	done < <(overlay_charts)
	((n >= 15)) || { echo "only $n charts have a values-openshift.yaml"; false; }
}

@test "charts: the Kubernetes render of every platform-neutral chart never names OpenShift" {
	local c name out
	while IFS= read -r c; do
		name="$(basename "$c")"
		[[ "$OPENSHIFT_ONLY_CHARTS" != *" ${name} "* ]] || continue
		out="$(helm template t "$c" "${MEMBER[@]}")"
		if grep -in openshift <<<"$out"; then
			echo "${c#"$ROOT"/}: its default (kubernetes) render names OpenShift (above)"
			false
		fi
	done < <(overlay_charts)
}

# appset_render <preset> <platform>: the ApplicationSet chart with the preset and the overlay.
appset_render() {
	helm template preset "$APPSET" -f "${APPSET}/$1" -f "${APPSET}/platform-$2.yaml" "${REPO[@]}"
}

@test "ApplicationSet presets: kubernetes selects istio-mesh-member=true in argocd; openshift the ACM Placement in openshift-gitops" {
	local v name k8s ocp path
	for v in "${APPSET}"/values-*.yaml; do
		name="$(basename "$v")"
		k8s="$(appset_render "$name" kubernetes)" || { echo "$name: kubernetes render fails"; false; }
		ocp="$(appset_render "$name" openshift)" || { echo "$name: openshift render fails"; false; }
		# ApplicationSet namespace: the platform's Argo CD.
		grep -A3 '^kind: ApplicationSet' <<<"$k8s" | grep -q '  namespace: "argocd"' || { echo "$name: kubernetes ApplicationSet not in argocd"; false; }
		grep -A3 '^kind: ApplicationSet' <<<"$ocp" | grep -q '  namespace: "openshift-gitops"' || { echo "$name: openshift ApplicationSet not in openshift-gitops"; false; }
		! grep -q 'clusterDecisionResource' <<<"$k8s" || { echo "$name: kubernetes render uses the ACM generator"; false; }
		if grep -q '^    - clusters:' <<<"$k8s"; then
			# A member preset: the cluster-Secret label on kubernetes, the Placement on openshift.
			grep -A3 '^    - clusters:' <<<"$k8s" | grep -q 'istio-mesh-member: "true"' || { echo "$name: kubernetes clusters generator without the istio-mesh-member selector"; false; }
			grep -q '^    - clusterDecisionResource:' <<<"$ocp" || { echo "$name: openshift render does not use the Placement"; false; }
			grep -q 'cluster.open-cluster-management.io/placement: "acm-openshift-gitops-placement"' <<<"$ocp" || { echo "$name: openshift render not on the mesh Placement"; false; }
		else
			# A hub preset: the hub only, by its Argo CD name, on both platforms.
			grep -A2 '^    - list:' <<<"$k8s" | grep -q 'name: "in-cluster"' || { echo "$name: neither the member selector nor the hub list on kubernetes"; false; }
			grep -A2 '^    - list:' <<<"$ocp" | grep -q 'clusterName: "in-cluster"' || { echo "$name: no hub list on openshift"; false; }
		fi
		if [[ "$OPENSHIFT_ONLY_PRESETS" != *" ${name} "* ]] && grep -in openshift <<<"$k8s"; then
			echo "$name: its kubernetes render names OpenShift (above)"
			false
		fi
		# A chart from this repo gets values-openshift.yaml on openshift, so it must have one;
		# none on kubernetes. A Helm repository chart gets neither.
		path="$(sed -n 's/^        path: "\(.*\)"$/\1/p' <<<"$k8s")"
		if [[ -n "$path" ]]; then
			[[ -f "${ROOT}/${path}/values-openshift.yaml" ]] || { echo "$name: ${path} has no values-openshift.yaml, which its openshift Applications list"; false; }
			grep -A1 '^          valueFiles:' <<<"$ocp" | grep -q -- '- values-openshift.yaml' || { echo "$name: openshift Applications do not add values-openshift.yaml"; false; }
		fi
		! grep -q 'values-openshift.yaml' <<<"$k8s" || { echo "$name: kubernetes Applications add values-openshift.yaml"; false; }
	done
}

# gate_values <render> <member>: the gate ApplicationSet's valuesObject in <render>, as the values
# Argo CD hands <member>'s Application (the generator's placeholder filled in with its name).
gate_values() {
	awk -v m="$2" '
		/^          valuesObject:$/ { on = 1; next }
		on && substr($0, 1, 12) == "            " {
			l = substr($0, 13)
			while ((i = index(l, "{{name}}")) > 0) l = substr(l, 1, i - 1) m substr(l, i + 8)
			while ((i = index(l, "{{clusterName}}")) > 0) l = substr(l, 1, i - 1) m substr(l, i + 15)
			print l
			next
		}
		on { exit }' <<<"$1"
}

@test "mesh-wiring gate: Terraform's values and the preset give each member's gate the members' names and its own, on both platforms" {
	local p out m dep extra
	# Terraform's values document for the gate ApplicationSet (platform_gitops.tf) and its set value
	# (a string, type = "string").
	grep -q '^      expectedClusters = local.mesh_member_spoke_keys$' "${ROOT}/terraform/platform/platform_gitops.tf" ||
		{ echo "platform_gitops.tf no longer sets expectedClusters from local.mesh_member_spoke_keys: update this test"; false; }
	printf '%s\n' '{"template":{"source":{"helm":{"valuesObject":{"expectedClusters":["member-a","member-b"]}}}}}' >"${BATS_TEST_TMPDIR}/tf.json"
	for p in kubernetes openshift; do
		out="$(helm template preset "$APPSET" -f "${APPSET}/values-mesh-wiring-verify.yaml" -f "${APPSET}/platform-${p}.yaml" \
			-f "${BATS_TEST_TMPDIR}/tf.json" --set-string template.source.helm.valuesObject.expectedMembers=2 "${REPO[@]}")"
		# The generator's own placeholder: the cluster Secret's name, or the PlacementDecision's.
		if [[ "$p" == kubernetes ]]; then
			grep -qx "            clusterName: '{{name}}'" <<<"$out" || { echo "$p: clusterName is not {{name}}"; false; }
			extra=()
		else
			grep -qx "            clusterName: '{{clusterName}}'" <<<"$out" || { echo "$p: clusterName is not {{clusterName}}"; false; }
			extra=(-f "${ROOT}/charts/mesh-wiring-verify/values-openshift.yaml")
		fi
		for m in member-a member-b; do
			gate_values "$out" "$m" >"${BATS_TEST_TMPDIR}/${p}-${m}.yaml"
			dep="$(helm template mesh-wiring-verify "${ROOT}/charts/mesh-wiring-verify" -f "${BATS_TEST_TMPDIR}/${p}-${m}.yaml" "${extra[@]}" \
				--show-only templates/deployment.yaml)" || { echo "$p/$m: the gate does not render with the Application's values"; false; }
			grep -A1 'name: EXPECTED_CLUSTERS$' <<<"$dep" | grep -q 'value: "member-a,member-b"' || { echo "$p/$m: EXPECTED_CLUSTERS is not member-a,member-b"; false; }
			grep -A1 'name: CLUSTER_NAME$' <<<"$dep" | grep -q "value: \"${m}\"" || { echo "$p/$m: CLUSTER_NAME is not ${m}"; false; }
			grep -A1 'name: EXPECTED_MEMBERS$' <<<"$dep" | grep -q 'value: "2"' || { echo "$p/$m: EXPECTED_MEMBERS is not 2"; false; }
		done
	done
	# Without Terraform's names (a manual install of the preset): by count, and clusterName unused.
	out="$(appset_render values-mesh-wiring-verify.yaml kubernetes)"
	gate_values "$out" member-a >"${BATS_TEST_TMPDIR}/count.yaml"
	dep="$(helm template mesh-wiring-verify "${ROOT}/charts/mesh-wiring-verify" -f "${BATS_TEST_TMPDIR}/count.yaml" --show-only templates/deployment.yaml)"
	grep -A1 'name: EXPECTED_CLUSTERS$' <<<"$dep" | grep -q 'value: ""'
}

@test "app-of-apps: each platform's children get its presets and operator sources; other platforms fail" {
	local k8s ocp
	k8s="$(helm template root "${ROOT}/charts/gitops-hub-apps" "${REPO[@]}")"
	ocp="$(helm template root "${ROOT}/charts/gitops-hub-apps" "${REPO[@]}" --set platform=openshift --set gitopsNamespace=openshift-gitops)"
	[ "$(grep -c -- '- platform-kubernetes.yaml' <<<"$k8s")" -ge 9 ]
	# (Every child passes the Placement name; only the openshift generator reads it.)
	! grep -qE -- '- (platform|values)-openshift\.yaml|namespace: "?openshift-gitops' <<<"$k8s" || false
	grep -q -- '- values-sail-operator.yaml' <<<"$k8s"
	grep -q -- '- values-external-secrets.yaml' <<<"$k8s"
	grep -q 'repoURL: "https://charts.jetstack.io"' <<<"$k8s"
	[ "$(grep -c -- '- platform-openshift.yaml' <<<"$ocp")" -ge 9 ]
	! grep -q 'platform-kubernetes.yaml' <<<"$ocp" || false
	grep -q -- '- values-ossm-operator.yaml' <<<"$ocp"
	grep -q -- '- values-external-secrets-olm.yaml' <<<"$ocp"
	grep -q 'path: charts/cert-manager-operator' <<<"$ocp"
	run helm template root "${ROOT}/charts/gitops-hub-apps" "${REPO[@]}" --set platform=okd
	assert_failure
	assert_output --partial 'platform must be kubernetes or openshift, not "okd"'
	run helm template root "${ROOT}/charts/gitops-hub-app-of-apps" "${REPO[@]}"
	assert_success
	assert_output --partial 'platform: "kubernetes"'
}

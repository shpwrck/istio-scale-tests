#!/usr/bin/env bats
# terraform/scripts/olm-subscription-wait.sh against a stub kubectl: it waits for the
# Subscription to be AtLatestKnown with its CSV Succeeded, and names what blocks the install
# (a Manual InstallPlan, a blocking condition) once, when first seen. A failing case runs with
# a 0 s timeout: it fails after its first poll.

load test_helper

SCRIPT="${ROOT}/terraform/scripts/olm-subscription-wait.sh"

# sub_json <state> <installedCSV> <installPlan> [conditions JSON array]
sub_json() {
	printf '{"status":{"state":"%s","installedCSV":"%s","installPlanRef":{"name":"%s"},"conditions":%s}}\n' "$1" "$2" "$3" "${4:-[]}"
}

setup() {
	STUB_DIR="${BATS_TEST_TMPDIR}/stub"
	STUB_LOG="${STUB_DIR}/calls.log"
	export STUB_DIR STUB_LOG
	mkdir -p "${STUB_DIR}/bin"
	: >"$STUB_LOG"
	# kubectl: the Subscription answers from sub.<n>.json in call order (the last one repeats),
	# the namespace's Subscriptions from subs.json, the InstallPlan from ip.json and the CSV's
	# phase from csv.phase.
	cat >"${STUB_DIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STUB_LOG"
args=" $* "
case "$args" in
*" get subscriptions.operators.coreos.com -o json "*) cat "$STUB_DIR/subs.json" ;;
*" get subscriptions.operators.coreos.com "*)
	n=$(( $(cat "$STUB_DIR/sub.n" 2>/dev/null || echo 0) + 1 ))
	echo "$n" >"$STUB_DIR/sub.n"
	f="$STUB_DIR/sub.${n}.json"
	[[ -f "$f" ]] || f="$(ls "$STUB_DIR"/sub.*.json | sort -t. -k2 -n | tail -1)"
	cat "$f" ;;
*" get installplans.operators.coreos.com "*) [[ -f "$STUB_DIR/ip.json" ]] || exit 1; cat "$STUB_DIR/ip.json" ;;
*" get clusterserviceversions.operators.coreos.com "*) [[ -f "$STUB_DIR/csv.phase" ]] || exit 1; cat "$STUB_DIR/csv.phase" ;;
*) exit 1 ;;
esac
EOF
	chmod +x "${STUB_DIR}/bin/kubectl"
	export PATH="${STUB_DIR}/bin:${PATH}"
	export KUBECONFIG_PATH=/dev/null KUBE_CONTEXT=acm-hub SUB_NAMESPACE=openshift-operators SUB_NAME=openshift-gitops-operator
	export POLL_SEC=0 TIMEOUT_SEC=5
}

@test "waits until the Subscription is AtLatestKnown and its CSV Succeeded" {
	sub_json UpgradePending - install-1 >"${STUB_DIR}/sub.1.json"
	sub_json AtLatestKnown gitops.v1 install-1 >"${STUB_DIR}/sub.2.json"
	echo '{"spec":{"approval":"Automatic","approved":true},"status":{"phase":"Complete"}}' >"${STUB_DIR}/ip.json"
	printf Succeeded >"${STUB_DIR}/csv.phase"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "openshift-operators/openshift-gitops-operator: state=UpgradePending csv=- phase=- installPlan=install-1"
	assert_output --partial "openshift-operators/openshift-gitops-operator: gitops.v1 Succeeded"
	refute_output --partial "manual approval"
}

@test "a Manual InstallPlan is named once, with the Manual Subscription, the CSVs and the approve command; the wait fails at its deadline" {
	export TIMEOUT_SEC=1
	sub_json UpgradePending - install-abc >"${STUB_DIR}/sub.1.json"
	echo '{"spec":{"approval":"Manual","approved":false,"clusterServiceVersionNames":["gitops.v1","ossm.v3"]},"status":{"phase":"RequiresApproval"}}' >"${STUB_DIR}/ip.json"
	echo '{"items":[{"metadata":{"name":"openshift-gitops-operator"},"spec":{"installPlanApproval":"Automatic"}},{"metadata":{"name":"servicemeshoperator3"},"spec":{"installPlanApproval":"Manual"}}]}' >"${STUB_DIR}/subs.json"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "InstallPlan install-abc waits for a manual approval (it installs gitops.v1, ossm.v3): OLM makes every InstallPlan in openshift-operators Manual while a Subscription there asks for Manual approval (servicemeshoperator3)."
	assert_output --partial "kubectl --context acm-hub -n openshift-operators patch installplan install-abc --type merge -p '{\"spec\":{\"approved\":true}}'"
	assert_output --partial "error: openshift-operators/openshift-gitops-operator did not install its operator within 1s (state=UpgradePending csv=- phase=- installPlan=install-abc)"
	# Once when first seen, once more under the error, however many polls ran.
	[ "$(grep -c 'waits for a manual approval' <<<"$output")" -eq 2 ]
	[ "$(grep -c ' get subscriptions.operators.coreos.com openshift-gitops-operator ' "$STUB_LOG")" -ge 2 ]
}

@test "a blocking condition and a failed InstallPlan are named; missing auth and a bad timeout are refused" {
	export TIMEOUT_SEC=0
	sub_json UpgradePending - install-2 '[{"type":"ResolutionFailed","status":"True","message":"constraints not satisfiable:\nno operators found in channel bogus"},{"type":"CatalogSourcesUnhealthy","status":"False"}]' >"${STUB_DIR}/sub.1.json"
	echo '{"spec":{"approval":"Automatic","approved":true},"status":{"phase":"Failed","conditions":[{"type":"Installed","status":"False","reason":"InstallComponentFailed","message":"error creating csv gitops.v1"}]}}' >"${STUB_DIR}/ip.json"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "ResolutionFailed: constraints not satisfiable: no operators found in channel bogus"
	assert_output --partial "InstallPlan install-2 failed: error creating csv gitops.v1"
	refute_output --partial "CatalogSourcesUnhealthy"
	TIMEOUT_SEC=soon run bash "$SCRIPT"
	assert_failure
	assert_output --partial "TIMEOUT_SEC must be a non-negative integer (got: soon)"
	unset KUBECONFIG_PATH
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "set KUBECONFIG_PATH+KUBE_CONTEXT or TOKEN_SCRIPT+API_URL+ADMIN_PASS"
}

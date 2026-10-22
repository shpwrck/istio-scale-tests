#!/usr/bin/env bats
# terraform/scripts/argocd-controller-reshard.sh (BACKLOG 9.1) against a stub kubectl: the
# restart waits for the operator's reconcile to settle, deletes the controller pods once and
# waits for Ready replacements (MODE=app-status is in argocd-app-status.bats). A failing case
# runs with a 0 s timeout: it fails after its first poll.

load test_helper

SCRIPT="${ROOT}/terraform/scripts/argocd-controller-reshard.sh"

# sts_json <replicas> <ready> <updated> <current_rev> <update_rev> [generation] [observed]
sts_json() {
	printf '{"metadata":{"generation":%s},"spec":{"replicas":%s},"status":{"observedGeneration":%s,"readyReplicas":%s,"updatedReplicas":%s,"currentRevision":"%s","updateRevision":"%s"}}\n' \
		"${6:-1}" "$1" "${7:-${6:-1}}" "$2" "$3" "$4" "$5"
}

# pods_json <uid:ready[:terminating]>...
pods_json() {
	local items="" p uid ready term
	for p in "$@"; do
		IFS=: read -r uid ready term <<<"$p"
		items+="${items:+,}{\"metadata\":{\"uid\":\"${uid}\"$([[ "${term:-0}" == 1 ]] && echo ',"deletionTimestamp":"x"')},\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"$(if [[ "$ready" == 1 ]]; then echo True; else echo False; fi)\"}]}}"
	done
	printf '{"items":[%s]}\n' "$items"
}

setup() {
	STUB_DIR="${BATS_TEST_TMPDIR}/stub"
	STUB_LOG="${STUB_DIR}/calls.log"
	export STUB_DIR STUB_LOG
	mkdir -p "${STUB_DIR}/bin"
	: >"$STUB_LOG"
	# kubectl: the StatefulSet answers from sts.<n>.json in call order (the last one repeats);
	# pods from pods.json until a delete, then from pods.after.json.
	cat >"${STUB_DIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STUB_LOG"
args=" $* "
case "$args" in
*" get statefulset "*" -o name "*) [[ -f "$STUB_DIR/sts.1.json" ]] || exit 1; echo "statefulset.apps/x" ;;
*" get statefulset "*" -o json "*)
	n=$(( $(cat "$STUB_DIR/sts.n" 2>/dev/null || echo 0) + 1 ))
	echo "$n" >"$STUB_DIR/sts.n"
	f="$STUB_DIR/sts.${n}.json"
	[[ -f "$f" ]] || f="$(ls "$STUB_DIR"/sts.*.json | sort -t. -k2 -n | tail -1)"
	cat "$f" ;;
*" get pods "*)
	if [[ -f "$STUB_DIR/deleted" ]]; then cat "$STUB_DIR/pods.after.json"; else cat "$STUB_DIR/pods.json"; fi ;;
*" delete pod "*) touch "$STUB_DIR/deleted" ;;
*) exit 1 ;;
esac
EOF
	chmod +x "${STUB_DIR}/bin/kubectl"
	export PATH="${STUB_DIR}/bin:${PATH}"
	export KUBECONFIG_PATH=/dev/null KUBE_CONTEXT=acm-hub GITOPS_NS=openshift-gitops ARGOCD_NAME=openshift-gitops
	export SETTLE_SEC=0 POLL_SEC=0 STABLE_POLLS=2 ROLLOUT_TIMEOUT_SEC=2
}

# reset_stub: a StatefulSet read from its first state again, no delete yet, an empty call log.
reset_stub() {
	rm -f "${STUB_DIR}"/sts.* "${STUB_DIR}"/pods.* "${STUB_DIR}/deleted"
	: >"$STUB_LOG"
}

@test "reshard: waits out the operator's scale-up, restarts the pods once, waits for Ready" {
	# The operator is mid-change (2 replicas wanted, 1 Ready), then settles at revision r2.
	sts_json 2 1 1 r1 r2 >"${STUB_DIR}/sts.1.json"
	sts_json 2 2 2 r2 r2 >"${STUB_DIR}/sts.2.json"
	pods_json a:1 b:1 >"${STUB_DIR}/pods.json"
	pods_json c:1 d:1 >"${STUB_DIR}/pods.after.json"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "settled at 2 replica(s), revision r2 (2 polls in a row)"
	assert_output --partial "Restarting 2 application-controller pod(s)"
	assert_output --partial "2/2 replacement pod(s) Ready"
	[ "$(grep -c ' delete pod ' "$STUB_LOG")" -eq 1 ]
	grep -q -- '-l app.kubernetes.io/name=openshift-gitops-application-controller' "$STUB_LOG"
	# No delete before the StatefulSet was read settled twice.
	first_delete="$(grep -n ' delete pod ' "$STUB_LOG" | cut -d: -f1)"
	[ "$(head -n "$first_delete" "$STUB_LOG" | grep -c 'get statefulset .* -o json')" -ge 3 ]
}

@test "reshard: a terminating pod or a pending rollout is not settled: it fails without deleting anything" {
	export ROLLOUT_TIMEOUT_SEC=0
	sts_json 1 1 1 r1 r1 >"${STUB_DIR}/sts.1.json"
	pods_json a:1:1 >"${STUB_DIR}/pods.json"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "did not settle within 0s"
	run grep -c ' delete pod ' "$STUB_LOG"
	assert_output 0
	reset_stub
	sts_json 2 2 2 r1 r2 >"${STUB_DIR}/sts.1.json"
	pods_json a:1 b:1 >"${STUB_DIR}/pods.json"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "did not settle within 0s (last state: settled=0 replicas=2 revision=r2)"
	run grep -c ' delete pod ' "$STUB_LOG"
	assert_output 0
}

@test "reshard: replacements that never get Ready, or an old pod that is still listed (not a replacement), fail the step" {
	export STABLE_POLLS=1 ROLLOUT_TIMEOUT_SEC=0
	sts_json 1 1 1 r1 r1 >"${STUB_DIR}/sts.1.json"
	pods_json a:1 >"${STUB_DIR}/pods.json"
	pods_json b:0 >"${STUB_DIR}/pods.after.json"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "replacement pods not Ready within 0s (0/1 Ready, old pods left: 0)"
	reset_stub
	sts_json 1 1 1 r1 r1 >"${STUB_DIR}/sts.1.json"
	pods_json a:1 >"${STUB_DIR}/pods.json"
	pods_json a:1 >"${STUB_DIR}/pods.after.json"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "(0/1 Ready, old pods left: 1)"
}

@test "an unknown MODE, missing auth and a missing StatefulSet are refused" {
	MODE=bogus run bash "$SCRIPT"
	assert_failure
	assert_output --partial "MODE must be reshard or app-status"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "StatefulSet openshift-gitops/openshift-gitops-application-controller not found"
	unset KUBECONFIG_PATH
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "set KUBECONFIG_PATH+KUBE_CONTEXT or TOKEN_SCRIPT+API_URL+ADMIN_PASS"
}

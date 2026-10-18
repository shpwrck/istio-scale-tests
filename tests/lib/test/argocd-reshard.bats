#!/usr/bin/env bats
# terraform/scripts/argocd-controller-reshard.sh (BACKLOG 9.1) against a stub kubectl: the
# restart waits for the operator's reconcile to settle, deletes the controller pods once and
# waits for Ready replacements; the app-status check names Applications without a status
# and expected destinations that no Application targets yet.

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
	STUB_DIR="$(mktemp -d)"
	STUB_LOG="${STUB_DIR}/calls.log"
	export STUB_DIR STUB_LOG
	mkdir -p "${STUB_DIR}/bin"
	: >"$STUB_LOG"
	# kubectl: the StatefulSet answers from sts.<n>.json in call order (the last one repeats);
	# pods from pods.json until a delete, then from pods.after.json; Applications from apps.json.
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
*" get applications.argoproj.io -o name "*) jq -r '.items[] | "application.argoproj.io/" + .metadata.name' "$STUB_DIR/apps.json" ;;
*" get applications.argoproj.io -o json "*) cat "$STUB_DIR/apps.json" ;;
*) exit 1 ;;
esac
EOF
	chmod +x "${STUB_DIR}/bin/kubectl"
	export PATH="${STUB_DIR}/bin:${PATH}"
	export KUBECONFIG_PATH=/dev/null KUBE_CONTEXT=acm-hub GITOPS_NS=openshift-gitops ARGOCD_NAME=openshift-gitops
	export SETTLE_SEC=0 POLL_SEC=0 STABLE_POLLS=2 ROLLOUT_TIMEOUT_SEC=2 APP_STATUS_TIMEOUT_SEC=1
}

teardown() {
	rm -rf "$STUB_DIR"
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

@test "reshard: a terminating pod counts as not settled" {
	sts_json 1 1 1 r1 r1 >"${STUB_DIR}/sts.1.json"
	pods_json a:1:1 >"${STUB_DIR}/pods.json"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "did not settle within 2s"
	run grep -c ' delete pod ' "$STUB_LOG"
	assert_output 0
}

@test "reshard: never settled (rollout pending) fails without deleting anything" {
	sts_json 2 2 2 r1 r2 >"${STUB_DIR}/sts.1.json"
	pods_json a:1 b:1 >"${STUB_DIR}/pods.json"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "did not settle within 2s (last state: settled=0 replicas=2 revision=r2)"
	run grep -c ' delete pod ' "$STUB_LOG"
	assert_output 0
}

@test "reshard: replacements that never get Ready fail the step" {
	sts_json 1 1 1 r1 r1 >"${STUB_DIR}/sts.1.json"
	pods_json a:1 >"${STUB_DIR}/pods.json"
	pods_json b:0 >"${STUB_DIR}/pods.after.json"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "replacement pods not Ready within 2s (0/1 Ready, old pods left: 0)"
}

@test "reshard: an old pod that is still listed is not a replacement" {
	sts_json 1 1 1 r1 r1 >"${STUB_DIR}/sts.1.json"
	pods_json a:1 >"${STUB_DIR}/pods.json"
	pods_json a:1 >"${STUB_DIR}/pods.after.json"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "old pods left: 1"
}

@test "reshard: a missing StatefulSet is an error" {
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "StatefulSet openshift-gitops/openshift-gitops-application-controller not found"
}

@test "app-status: every Application has a sync and health status" {
	cat >"${STUB_DIR}/apps.json" <<'EOF'
{"items":[{"metadata":{"name":"in-cluster-ossm"},"spec":{"destination":{"name":"in-cluster"}},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}},
{"metadata":{"name":"mesh-b-ossm"},"spec":{"destination":{"name":"mesh-b"}},"status":{"sync":{"status":"OutOfSync"},"health":{"status":"Progressing"}}}]}
EOF
	MODE=app-status run bash "$SCRIPT"
	assert_success
	assert_output --partial "all 2 Application(s) have a sync and health status"
}

@test "app-status: names the Applications without status and their destination cluster" {
	cat >"${STUB_DIR}/apps.json" <<'EOF'
{"items":[{"metadata":{"name":"in-cluster-ossm"},"spec":{"destination":{"name":"in-cluster"}},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}},
{"metadata":{"name":"mesh-b-ossm"},"spec":{"destination":{"name":"mesh-b"}},"status":{}},
{"metadata":{"name":"mesh-b-ingress"},"spec":{"destination":{"server":"https://api.mesh-b.example:6443"}},"status":{"sync":{"status":"Synced"}}}]}
EOF
	MODE=app-status run bash "$SCRIPT"
	assert_failure
	assert_output --partial "mesh-b-ossm (destination mesh-b)"
	assert_output --partial "mesh-b-ingress (destination https://api.mesh-b.example:6443)"
	refute_output --partial "in-cluster-ossm"
}

@test "app-status: waits for an Application on every expected destination (name or server)" {
	cat >"${STUB_DIR}/apps.json" <<'EOF'
{"items":[{"metadata":{"name":"in-cluster-ossm"},"spec":{"destination":{"server":"https://kubernetes.default.svc"}},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}},
{"metadata":{"name":"mesh-a-ossm"},"spec":{"destination":{"name":"mesh-a"}},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}},
{"metadata":{"name":"mesh-b-ossm"},"spec":{"destination":{"server":"https://api.mesh-b.example:6443"}},"status":{"sync":{"status":"OutOfSync"},"health":{"status":"Missing"}}}]}
EOF
	MODE=app-status EXPECTED_DESTINATIONS="mesh-a,https://api.mesh-b.example:6443" run bash "$SCRIPT"
	assert_success
	assert_output --partial "all 3 Application(s) have a sync and health status, and every expected destination has Applications"
}

@test "app-status: an expected destination with no Application fails, named, even when every status is set" {
	# The ApplicationSets have generated nothing for mesh-c yet: only the hub's own
	# Applications and mesh-b's exist, all with a status (the 2026-10-16 timing).
	cat >"${STUB_DIR}/apps.json" <<'EOF'
{"items":[{"metadata":{"name":"in-cluster-ossm"},"spec":{"destination":{"name":"in-cluster"}},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}},
{"metadata":{"name":"mesh-b-ossm"},"spec":{"destination":{"name":"mesh-b"}},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}}]}
EOF
	MODE=app-status EXPECTED_DESTINATIONS="mesh-b mesh-c" run bash "$SCRIPT"
	assert_failure
	assert_output --partial "no Application targets these destination clusters after 1s"
	assert_output --partial "  mesh-c"
	refute_output --partial "  mesh-b"
	refute_output --partial "without a sync or health status"
}

@test "app-status: no Applications at all is a failure, not a pass" {
	echo '{"items":[]}' >"${STUB_DIR}/apps.json"
	MODE=app-status run bash "$SCRIPT"
	assert_failure
	assert_output --partial "no Applications found in openshift-gitops"
}

@test "an unknown MODE and missing auth are refused" {
	MODE=bogus run bash "$SCRIPT"
	assert_failure
	assert_output --partial "MODE must be reshard or app-status"
	unset KUBECONFIG_PATH
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "set KUBECONFIG_PATH+KUBE_CONTEXT or TOKEN_SCRIPT+API_URL+ADMIN_PASS"
}

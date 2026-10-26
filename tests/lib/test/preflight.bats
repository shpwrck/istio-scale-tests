#!/usr/bin/env bats
# tests/preflight/001-check-mesh.sh against a stub kubectl and curl: a ready mesh passes; the
# example contexts, the hub listed as a member, a NotReady gate, different root CAs and a
# version off the pin each fail with a fix; --echo applies the echo app on the hub, waits for
# it, passes once every member answered and fails naming one that never did, and removes the
# app on every exit.

load test_helper
bats_require_minimum_version 1.5.0

SCRIPT="${ROOT}/tests/preflight/001-check-mesh.sh"

setup() {
	STUB_DIR="${BATS_TEST_TMPDIR}/stub"
	STUB_LOG="${STUB_DIR}/calls.log"
	export STUB_DIR STUB_LOG ROOT
	mkdir -p "${STUB_DIR}/bin"
	: >"$STUB_LOG"
	printf '%s\n' mesh-a mesh-b hub >"${STUB_DIR}/contexts"
	for c in mesh-a mesh-b; do
		echo "Ready: secrets=2 expected=2 members=member-a,member-b ca=shared synced=1 replicas=3 root=0123456789abcdef eastwest=192.0.2.1" >"${STUB_DIR}/gate.${c}"
	done
	printf '%s\n' member-a member-b >"${STUB_DIR}/answers"
	# kubectl: logs each call; the contexts file lists the kubeconfig's contexts; hub has no Sail
	# operator; gate.<ctx> is that member's gate output (a NotReady line fails it); the Istio
	# reads go to the shared fixture; the hub holds hub-gitops-root in argocd; apply/delete of
	# the echo app are logged with the manifest saved; rollout status succeeds.
	cat >"${STUB_DIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STUB_LOG"
ctx="" prev=""
for a in "$@"; do
	[[ "$prev" == --context ]] && ctx="$a"
	case "$a" in --context=*) ctx="${a#--context=}" ;; esac
	prev="$a"
done
case " $* " in
*" config get-contexts "*) cat "$STUB_DIR/contexts" ;;
*" get --raw /version "*) echo '{}' ;;
*" exec deploy/mesh-wiring-verify "*)
	cat "$STUB_DIR/gate.${ctx}"
	grep -q '^Ready:' "$STUB_DIR/gate.${ctx}" ;;
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*)
	if [[ "$ctx" == hub ]]; then
		echo 'error: the server doesn'"'"'t have a resource type "istios"' >&2
		exit 1
	fi
	exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" -n argocd get applications.argoproj.io hub-gitops-root "*) printf '%s' 'https://example.invalid/repo.git main' ;;
*" get applications.argoproj.io hub-gitops-root "*) exit 1 ;;
*" apply -f - "*) cat >"$STUB_DIR/applied.yaml" ;;
*" delete "*" -f - "*) cat >"$STUB_DIR/deleted.yaml" ;;
*" rollout status deploy/mesh-verify-echo "*) exit 0 ;;
*" get svc istio-ingressgateway "*) printf '%s' 192.0.2.80 ;;
*) exit 1 ;;
esac
EOF
	# curl: answers in turn with the lines of the answers file.
	cat >"${STUB_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
n=$(cat "$STUB_DIR/curl.n" 2>/dev/null || echo 0)
mapfile -t a <"$STUB_DIR/answers"
echo "${a[n % ${#a[@]}]}"
echo $((n + 1)) >"$STUB_DIR/curl.n"
EOF
	# helm: on PATH only.
	printf '#!/bin/sh\nexit 0\n' >"${STUB_DIR}/bin/helm"
	chmod +x "${STUB_DIR}/bin/"*
}

preflight() {
	PATH="${STUB_DIR}/bin:${PATH}" run --separate-stderr bash "$SCRIPT" "$@"
}

@test "a ready mesh passes every check; the hub is refused as a member before any call" {
	SETUP_CONTEXTS=mesh-a,mesh-b preflight
	assert_success
	assert_line --partial "ok    mesh-a: answers, and runs the mesh's Istio CR"
	assert_line --partial "ok    mesh-b: Ready: secrets=2"
	assert_line --partial "ok    every member reads the same root CA (root=0123456789abcdef)"
	assert_line --partial "ok    Istio v1.30.5 on every member: mesh-a=v1.30.5,mesh-b=v1.30.5"
	assert_line --partial "Preflight passed"
	: >"$STUB_LOG"
	preflight --contexts mesh-a,hub --hub-context hub
	assert_failure
	[[ "$stderr" == *"--hub-context hub is also in the member list"* ]]
	[ ! -s "$STUB_LOG" ]
}

@test "each failure names its fix: the example contexts, a cluster with no Sail operator, a NotReady gate, different roots, a version off the pin" {
	unset SETUP_CONTEXTS
	preflight
	assert_failure
	assert_line --partial "(these are the example contexts from config/versions.env"
	assert_line --partial "FAIL  cluster-002: no such context in your kubeconfig"
	assert_line --partial "it is an example name: export SETUP_CONTEXTS="
	SETUP_CONTEXTS=mesh-a,hub preflight
	assert_failure
	assert_line --partial "FAIL  hub: no Sail operator here (no istios.sailoperator.io)"
	echo "NotReady: no remote secret here for mesh member(s) member-b" >"${STUB_DIR}/gate.mesh-b"
	SETUP_CONTEXTS=mesh-a,mesh-b preflight
	assert_failure
	assert_line --partial "FAIL  mesh-b: the gate is not Ready"
	assert_line --partial "| NotReady: no remote secret here for mesh member(s) member-b"
	echo "Ready: members=member-a,member-b ca=shared root=fedcba9876543210" >"${STUB_DIR}/gate.mesh-b"
	SETUP_CONTEXTS=mesh-a,mesh-b preflight
	assert_failure
	assert_line --partial "FAIL  the members read different root CAs"
	cp "${STUB_DIR}/gate.mesh-a" "${STUB_DIR}/gate.mesh-b"
	SETUP_CONTEXTS=mesh-a,mesh-b ISTIO_VERSION=v1.29.0 STUB_ISTIO_VERSION=v1.30.5 preflight
	assert_failure
	assert_line --partial "FAIL  the version check failed; the suites would stop on it"
	assert_line --partial "not the pin ISTIO_VERSION=v1.29.0"
}

@test "--echo: applies the echo app from what the hub syncs, passes once every member answered, fails naming one that never did, and removes it on every exit" {
	SETUP_CONTEXTS=mesh-a,mesh-b preflight --hub-context hub --echo --echo-requests 5
	assert_success
	assert_line --partial "applied the echo app from https://example.invalid/repo.git at main (Argo CD namespace argocd)"
	assert_line --partial "every member answered within 2 requests"
	grep -q 'repoURL: https://example.invalid/repo.git' "${STUB_DIR}/applied.yaml"
	grep -q 'platform-kubernetes.yaml' "${STUB_DIR}/applied.yaml"
	! grep -qE '<(repo-url|revision|platform|gitops-namespace)>' "${STUB_DIR}/applied.yaml" || false
	cmp "${STUB_DIR}/applied.yaml" "${STUB_DIR}/deleted.yaml"
	rm -f "${STUB_DIR}/deleted.yaml" "${STUB_DIR}/curl.n"
	echo member-a >"${STUB_DIR}/answers"
	SETUP_CONTEXTS=mesh-a,mesh-b preflight --hub-context hub --echo --echo-requests 5
	assert_failure
	assert_line --partial "after 5 requests, answers came from: member-a ; never from: member-b"
	[ -s "${STUB_DIR}/deleted.yaml" ]
	preflight --contexts mesh-a,mesh-b --echo
	assert_failure
	[[ "$stderr" == *"--echo needs the hub's context"* ]]
}

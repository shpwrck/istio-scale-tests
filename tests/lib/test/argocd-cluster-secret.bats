#!/usr/bin/env bats
# terraform/scripts/create-argocd-cluster-secret.sh on platform kubernetes, against a stub
# kubectl: the spoke's ServiceAccount, cluster-admin binding and token Secret, the hub's Argo
# CD cluster Secret (token, the kubeconfig's CA or its insecure flag, the mesh-member label),
# a token that never appears, the destroy-time delete (best effort, never silent) and the
# input checks that stop before any call.

load test_helper

SCRIPT="${ROOT}/terraform/scripts/create-argocd-cluster-secret.sh"

setup() {
	STUB_DIR="$(mktemp -d)"
	STUB_LOG="${STUB_DIR}/calls.log"
	export STUB_DIR STUB_LOG
	mkdir -p "${STUB_DIR}/bin"
	: >"$STUB_LOG"
	# kubectl: logs each call; an apply saves its stdin as apply.<context>.<n>.yaml; the token
	# Secret answers from token.b64 (absent: empty, as before the token controller fills it);
	# config view prints kubeconfig.json; a context listed in down.txt fails every call.
	cat >"${STUB_DIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STUB_LOG"
ctx=""
for a in "$@"; do case "$a" in --context=*) ctx="${a#--context=}" ;; esac; done
if [[ -n "$ctx" ]] && grep -qx "$ctx" "$STUB_DIR/down.txt" 2>/dev/null; then
	echo "error: dial tcp 192.0.2.10:6443: connect: connection refused" >&2
	exit 1
fi
args=" $* "
case "$args" in
*" config view "*) cat "$STUB_DIR/kubeconfig.json" ;;
*" apply -f - "*)
	n=$(ls "$STUB_DIR"/apply."$ctx".*.yaml 2>/dev/null | wc -l | tr -d ' ')
	cat >"$STUB_DIR/apply.${ctx}.$((n + 1)).yaml" ;;
*" get secret "*"jsonpath={.data.token}"*) cat "$STUB_DIR/token.b64" 2>/dev/null || true ;;
*" delete "*) ;;
*) exit 1 ;;
esac
EOF
	# sleep: the token wait polls 30 times; do not wait in a test.
	printf '#!/usr/bin/env bash\nexit 0\n' >"${STUB_DIR}/bin/sleep"
	chmod +x "${STUB_DIR}/bin/kubectl" "${STUB_DIR}/bin/sleep"
	export PATH="${STUB_DIR}/bin:${PATH}"
	printf '%s' 'spoke-token' | base64 >"${STUB_DIR}/token.b64"
	kubeconfig_json false
	export PLATFORM=kubernetes KUBECONFIG_PATH=/dev/null HUB_CONTEXT=hub SPOKE_CONTEXT=mesh-a
	export SPOKE_NAME=mesh-a API_URL=https://mesh-a-control-plane:6443 GITOPS_NAMESPACE=argocd
	export MANAGED_SA_NAME=argocd-gitops SPOKE_SA_NAMESPACE=kube-system MESH_MEMBER=true
	unset ACTION
}

teardown() {
	rm -rf "$STUB_DIR"
}

# kubeconfig_json <insecure>: the spoke context's minified kubeconfig, with CA data unless insecure.
kubeconfig_json() {
	if [[ "$1" == true ]]; then
		echo '{"clusters":[{"name":"mesh-a","cluster":{"server":"https://127.0.0.1:1","insecure-skip-tls-verify":true}}],"users":[{"name":"u","user":{}}]}' >"${STUB_DIR}/kubeconfig.json"
	else
		echo '{"clusters":[{"name":"mesh-a","cluster":{"server":"https://127.0.0.1:1","certificate-authority-data":"Q0EtREFUQQ=="}}],"users":[{"name":"u","user":{}}]}' >"${STUB_DIR}/kubeconfig.json"
	fi
}

# secret_field <file> <key>: the decoded data.<key> of the cluster Secret manifest.
secret_field() {
	awk -v k="$2" '/^data:/ { d = 1; next } /^[^ ]/ { d = 0 } d && $1 == k ":" { print $2 }' "$1" | base64 --decode
}

@test "cluster secret (kubernetes): the spoke ServiceAccount, binding and token, then the hub Secret with token, CA and member label" {
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Applied mesh-a-argocd-gitops-cluster-secret with server=https://mesh-a-control-plane:6443 (mesh member: true)"
	local spoke="${STUB_DIR}/apply.mesh-a.1.yaml" hub="${STUB_DIR}/apply.hub.1.yaml" cfg
	grep -q '^kind: ServiceAccount' "$spoke"
	grep -A3 '^roleRef:' "$spoke" | grep -q 'name: cluster-admin'
	grep -q 'type: kubernetes.io/service-account-token' "$spoke"
	grep -q 'kubernetes.io/service-account.name: argocd-gitops' "$spoke"
	[ "$(grep -c 'namespace: kube-system' "$spoke")" -eq 3 ]
	grep -q 'argocd.argoproj.io/secret-type: cluster' "$hub"
	grep -q 'istio-mesh-member: "true"' "$hub"
	grep -q 'namespace: argocd' "$hub"
	[ "$(secret_field "$hub" name)" = mesh-a ]
	[ "$(secret_field "$hub" server)" = https://mesh-a-control-plane:6443 ]
	cfg="$(secret_field "$hub" config)"
	[ "$(jq -r .bearerToken <<<"$cfg")" = spoke-token ]
	[ "$(jq -r .tlsClientConfig.caData <<<"$cfg")" = Q0EtREFUQQ== ]
	[ "$(jq -r .tlsClientConfig.insecure <<<"$cfg")" = false ]
	# The spoke objects go in through the spoke context, the cluster Secret through the hub's.
	grep -q -- '--context=mesh-a --request-timeout=60s apply -f -' "$STUB_LOG"
	grep -q -- '--context=hub apply -f -' "$STUB_LOG"
}

@test "cluster secret (kubernetes): a spoke that is not a mesh member gets no istio-mesh-member label" {
	MESH_MEMBER=false run bash "$SCRIPT"
	assert_success
	! grep -q 'istio-mesh-member' "${STUB_DIR}/apply.hub.1.yaml" || false
	grep -q 'argocd.argoproj.io/secret-type: cluster' "${STUB_DIR}/apply.hub.1.yaml"
}

@test "cluster secret (kubernetes): a kubeconfig that skips TLS verification gives insecure: true and no CA" {
	kubeconfig_json true
	run bash "$SCRIPT"
	assert_success
	local cfg
	cfg="$(secret_field "${STUB_DIR}/apply.hub.1.yaml" config)"
	[ "$(jq -r .tlsClientConfig.insecure <<<"$cfg")" = true ]
	[ "$(jq -r '.tlsClientConfig | has("caData")' <<<"$cfg")" = false ]
}

@test "cluster secret (kubernetes): a token the controller never fills fails, naming the Secret, and writes no hub Secret" {
	rm "${STUB_DIR}/token.b64"
	run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "the token controller did not fill kube-system/argocd-gitops-token on spoke mesh-a within 60s"
	[ ! -e "${STUB_DIR}/apply.hub.1.yaml" ]
	[ "$(grep -c 'jsonpath={.data.token}' "$STUB_LOG")" -eq 30 ]
}

@test "cluster secret (kubernetes): ACTION=delete removes the hub Secret and the spoke binding, token and ServiceAccount" {
	ACTION=delete API_URL='' run bash "$SCRIPT"
	assert_success
	assert_output --partial "Removed the Argo CD access to mesh-a"
	grep -q -- '--context=hub --request-timeout=60s delete secret mesh-a-argocd-gitops-cluster-secret -n argocd --ignore-not-found' "$STUB_LOG"
	grep -q -- '--context=mesh-a --request-timeout=60s delete clusterrolebinding argocd-gitops-cluster-admin --ignore-not-found' "$STUB_LOG"
	grep -q -- '--context=mesh-a --request-timeout=60s delete secret argocd-gitops-token -n kube-system --ignore-not-found' "$STUB_LOG"
	grep -q -- '--context=mesh-a --request-timeout=60s delete serviceaccount argocd-gitops -n kube-system --ignore-not-found' "$STUB_LOG"
	! grep -q ' apply ' "$STUB_LOG" || false
}

@test "cluster secret (kubernetes): ACTION=delete with the spoke or the hub gone warns, names what is left, and exits 0" {
	echo mesh-a >"${STUB_DIR}/down.txt"
	ACTION=delete run bash "$SCRIPT"
	assert_success
	assert_output --partial "WARNING: could not remove the ServiceAccount kube-system/argocd-gitops, its token Secret and the ClusterRoleBinding argocd-gitops-cluster-admin on mesh-a"
	echo hub >"${STUB_DIR}/down.txt"
	ACTION=delete run bash "$SCRIPT"
	assert_success
	assert_output --partial "WARNING: could not delete the cluster Secret argocd/mesh-a-argocd-gitops-cluster-secret on the hub (it holds a cluster-admin token for mesh-a)"
}

@test "cluster secret: a bad PLATFORM, ACTION or MESH_MEMBER, or kubernetes without a kubeconfig, stops before any call" {
	PLATFORM=okd run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "PLATFORM must be kubernetes or openshift (got: okd)"
	ACTION=remove run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "ACTION must be apply or delete (got: remove)"
	MESH_MEMBER=yes run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "MESH_MEMBER must be true or false (got: yes)"
	SPOKE_CONTEXT='' run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "platform kubernetes needs KUBECONFIG_PATH and SPOKE_CONTEXT"
	[ ! -s "$STUB_LOG" ]
}

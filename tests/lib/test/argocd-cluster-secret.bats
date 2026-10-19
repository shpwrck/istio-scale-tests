#!/usr/bin/env bats
# terraform/scripts/create-argocd-cluster-secret.sh on platform kubernetes, against a stub
# kubectl: the spoke's namespace (created and labelled only when it does not exist), its
# ServiceAccount, token Secret and cluster-admin binding, the hub's Argo CD cluster Secret
# (token, the kubeconfig's CA or its insecure flag, the mesh-member label, the controller shard
# pin: written, changed, absent, and a pin someone else set), a token that never appears, the
# move from an earlier run's namespace (reporting only what it removed), the destroy-time
# delete (best effort, never silent, never a namespace the script did not create) and the
# input checks that stop before any call.

load test_helper

SCRIPT="${ROOT}/terraform/scripts/create-argocd-cluster-secret.sh"
OWNED="app.kubernetes.io/part-of=istio-scale-tests"

setup() {
	STUB_DIR="$(mktemp -d)"
	STUB_LOG="${STUB_DIR}/calls.log"
	export STUB_DIR STUB_LOG
	mkdir -p "${STUB_DIR}/bin"
	: >"$STUB_LOG"
	# kubectl: logs each call. A context listed in down.txt fails every call, and so does a call
	# whose arguments contain a line of fail.txt. Spoke namespaces are files: ns.<name> holds
	# the phase, ns.<name>.ours marks the created-by label; `create -f -` makes one (saved as
	# create.<context>.yaml) and `delete namespace` removes it unless stuck.txt exists. An apply
	# saves its stdin as apply.<context>.<n>.yaml; the binding's subjects come from
	# subjects.txt; the token Secret answers from token.b64 (absent: empty, as before the token
	# controller fills it), the hub Secret's shard key from shard.b64 (absent: empty); config
	# view prints kubeconfig.json. An earlier run's ServiceAccount
	# and token Secret are files obj.<ns>.<kind>.<name> holding labelled or unlabelled: a
	# `delete -l ... -o name` removes a labelled one and prints <kind>/<name> (else "No resources
	# found", on stdout as kubectl prints it); `get <kind>/<name> -o name` finds either.
	cat >"${STUB_DIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STUB_LOG"
ctx="" name="" field="" prev="" nsarg="" obj=""
for a in "$@"; do
	case "$a" in
	--context=*) ctx="${a#--context=}" ;;
	metadata.name=*) field="${a#metadata.name=}" ;;
	esac
	[[ "$prev" == namespace && "$a" != -* ]] && name="$a"
	[[ "$prev" == -n ]] && nsarg="$a"
	[[ "$prev" == delete || "$prev" == get ]] && obj="$a"
	prev="$a"
done
if [[ -n "$ctx" ]] && grep -qx "$ctx" "$STUB_DIR/down.txt" 2>/dev/null; then
	echo "error: dial tcp 192.0.2.10:6443: connect: connection refused" >&2
	exit 1
fi
if [[ -f "$STUB_DIR/fail.txt" ]]; then
	while IFS= read -r pat; do
		if [[ -n "$pat" && " $* " == *"$pat"* ]]; then
			echo "error: stub refused: $pat" >&2
			exit 1
		fi
	done <"$STUB_DIR/fail.txt"
fi
args=" $* "
case "$args" in
*" config view "*) cat "$STUB_DIR/kubeconfig.json" ;;
*" create -f - "*)
	cat >"$STUB_DIR/create.${ctx}.yaml"
	ns=$(awk '$1 == "name:" { print $2; exit }' "$STUB_DIR/create.${ctx}.yaml")
	echo Active >"$STUB_DIR/ns.${ns}"
	if grep -q 'istio-scale-tests/created-by: create-argocd-cluster-secret' "$STUB_DIR/create.${ctx}.yaml"; then
		: >"$STUB_DIR/ns.${ns}.ours"
	fi ;;
*" apply -f - "*)
	n=$(ls "$STUB_DIR"/apply."$ctx".*.yaml 2>/dev/null | wc -l | tr -d ' ')
	cat >"$STUB_DIR/apply.${ctx}.$((n + 1)).yaml" ;;
*" get namespace "*"jsonpath={.status.phase}"*) cat "$STUB_DIR/ns.${name}" 2>/dev/null || true ;;
*" get namespaces -l istio-scale-tests/created-by=create-argocd-cluster-secret "*)
	if [[ -e "$STUB_DIR/ns.${field}.ours" ]]; then echo "namespace/${field}"; fi ;;
*" get namespace "*" -o name "*)
	if [[ -e "$STUB_DIR/ns.${name}" ]]; then echo "namespace/${name}"; fi ;;
*" delete namespace "*)
	echo "namespace \"${name}\" deleted"
	if [[ -e "$STUB_DIR/stuck.txt" ]]; then
		echo Terminating >"$STUB_DIR/ns.${name}"
	else
		rm -f "$STUB_DIR/ns.${name}" "$STUB_DIR/ns.${name}.ours"
	fi ;;
*" get clusterrolebinding "*) cat "$STUB_DIR/subjects.txt" 2>/dev/null || true ;;
*" get secret "*"jsonpath={.data.token}"*) cat "$STUB_DIR/token.b64" 2>/dev/null || true ;;
*" get secret "*"jsonpath={.data.shard}"*) cat "$STUB_DIR/shard.b64" 2>/dev/null || true ;;
*" get secret/"* | *" get serviceaccount/"*)
	if [[ -e "$STUB_DIR/obj.${nsarg}.${obj%%/*}.${obj#*/}" ]]; then echo "$obj"; fi ;;
*" delete "*" -o name "*)
	if [[ "$(cat "$STUB_DIR/obj.${nsarg}.${obj}.${field}" 2>/dev/null)" == labelled ]]; then
		rm -f "$STUB_DIR/obj.${nsarg}.${obj}.${field}"
		echo "${obj}/${field}"
	else
		echo "No resources found"
	fi ;;
*" delete "*) ;;
*) exit 1 ;;
esac
EOF
	# sleep: the token and namespace waits poll; do not wait in a test.
	printf '#!/usr/bin/env bash\nexit 0\n' >"${STUB_DIR}/bin/sleep"
	chmod +x "${STUB_DIR}/bin/kubectl" "${STUB_DIR}/bin/sleep"
	export PATH="${STUB_DIR}/bin:${PATH}"
	printf '%s' 'spoke-token' | base64 >"${STUB_DIR}/token.b64"
	kubeconfig_json false
	export PLATFORM=kubernetes KUBECONFIG_PATH=/dev/null HUB_CONTEXT=hub SPOKE_CONTEXT=mesh-a
	export SPOKE_NAME=mesh-a API_URL=https://mesh-a-control-plane:6443 GITOPS_NAMESPACE=argocd
	export MANAGED_SA_NAME=argocd-gitops MESH_MEMBER=true
	unset ACTION SPOKE_SA_NAMESPACE SHARD
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

# namespace <name> <phase> [ours]: a namespace that exists on the spoke (ours: with the
# created-by label).
namespace() {
	echo "$2" >"${STUB_DIR}/ns.$1"
	if [[ "${3:-}" == ours ]]; then : >"${STUB_DIR}/ns.$1.ours"; fi
}

# old_object <ns> <kind>/<name> [unlabelled]: an earlier run's object on the spoke (unlabelled:
# without OWNED, so not the script's).
old_object() {
	if [[ "${3:-}" == unlabelled ]]; then
		echo unlabelled >"${STUB_DIR}/obj.$1.${2%%/*}.${2#*/}"
	else
		echo labelled >"${STUB_DIR}/obj.$1.${2%%/*}.${2#*/}"
	fi
}

# secret_field <file> <key>: the decoded data.<key> of the cluster Secret manifest.
secret_field() {
	awk -v k="$2" '/^data:/ { d = 1; next } /^[^ ]/ { d = 0 } d && $1 == k ":" { print $2 }' "$1" | base64 --decode
}

# line_of <fixed string>: the number of the first call-log line that contains it.
line_of() {
	grep -nF -- "$1" "$STUB_LOG" | head -n 1 | cut -d: -f1
}

@test "cluster secret (kubernetes): a new namespace, the ServiceAccount and token, then the binding, then the hub Secret" {
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Created the namespace istio-scale-tests-access on mesh-a (label istio-scale-tests/created-by=create-argocd-cluster-secret)"
	assert_output --partial "Applied mesh-a-argocd-gitops-cluster-secret with server=https://mesh-a-control-plane:6443 (mesh member: true; controller shard: not pinned)"
	local ns="${STUB_DIR}/create.mesh-a.yaml" sa="${STUB_DIR}/apply.mesh-a.1.yaml" crb="${STUB_DIR}/apply.mesh-a.2.yaml"
	local hub="${STUB_DIR}/apply.hub.1.yaml" cfg
	grep -q '^kind: Namespace' "$ns"
	grep -q 'name: istio-scale-tests-access' "$ns"
	grep -q 'app.kubernetes.io/part-of: istio-scale-tests' "$ns"
	grep -q 'istio-scale-tests/created-by: create-argocd-cluster-secret' "$ns"
	grep -q '^kind: ServiceAccount' "$sa"
	grep -q 'type: kubernetes.io/service-account-token' "$sa"
	grep -q 'kubernetes.io/service-account.name: argocd-gitops' "$sa"
	! grep -q 'ClusterRoleBinding' "$sa" || false
	[ "$(grep -c 'namespace: istio-scale-tests-access' "$sa")" -eq 2 ]
	grep -q '^kind: ClusterRoleBinding' "$crb"
	grep -A3 '^roleRef:' "$crb" | grep -q 'name: cluster-admin'
	grep -A3 '^subjects:' "$crb" | grep -q 'namespace: istio-scale-tests-access'
	# The binding moves only once the token exists.
	[ "$(line_of 'jsonpath={.data.token}')" -lt "$(grep -n -- '--context=mesh-a --request-timeout=60s apply -f -' "$STUB_LOG" | sed -n 2p | cut -d: -f1)" ]
	grep -q 'argocd.argoproj.io/secret-type: cluster' "$hub"
	grep -q 'istio-mesh-member: "true"' "$hub"
	grep -q 'namespace: argocd' "$hub"
	[ "$(secret_field "$hub" name)" = mesh-a ]
	[ "$(secret_field "$hub" server)" = https://mesh-a-control-plane:6443 ]
	cfg="$(secret_field "$hub" config)"
	[ "$(jq -r .bearerToken <<<"$cfg")" = spoke-token ]
	[ "$(jq -r .tlsClientConfig.caData <<<"$cfg")" = Q0EtREFUQQ== ]
	[ "$(jq -r .tlsClientConfig.insecure <<<"$cfg")" = false ]
	# Every call has a request timeout: the spoke objects through the spoke context, the
	# cluster Secret through the hub's. A fresh spoke has nothing to move.
	grep -q -- '--context=mesh-a --request-timeout=60s create -f -' "$STUB_LOG"
	grep -q -- '--context=hub --request-timeout=60s apply -f -' "$STUB_LOG"
	! grep -q ' delete ' "$STUB_LOG" || false
	refute_output --partial "Moved the ServiceAccount"
}

@test "cluster secret (kubernetes): an existing namespace (kube-system here) is used as it is, never created or labelled" {
	namespace kube-system Active
	SPOKE_SA_NAMESPACE=kube-system run bash "$SCRIPT"
	assert_success
	! grep -q -e ' create ' -e ' label ' -e ' delete ' "$STUB_LOG" || false
	refute_output --partial "Created the namespace"
	[ "$(grep -c 'namespace: kube-system' "${STUB_DIR}/apply.mesh-a.1.yaml")" -eq 2 ]
	grep -A3 '^subjects:' "${STUB_DIR}/apply.mesh-a.2.yaml" | grep -q 'namespace: kube-system'
	[ -e "${STUB_DIR}/apply.hub.1.yaml" ]
}

@test "cluster secret (kubernetes): a terminating namespace fails, naming it, before any apply" {
	namespace istio-scale-tests-access Terminating ours
	run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "the namespace istio-scale-tests-access on spoke mesh-a is being deleted"
	! grep -q -e ' apply ' -e ' create ' "$STUB_LOG" || false
}

@test "cluster secret (kubernetes): moving from kube-system re-points the binding, then removes only the old labelled ServiceAccount and token" {
	namespace kube-system Active
	old_object kube-system secret/argocd-gitops-token
	old_object kube-system serviceaccount/argocd-gitops
	printf 'ServiceAccount kube-system argocd-gitops\n' >"${STUB_DIR}/subjects.txt"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Moved the ServiceAccount argocd-gitops on mesh-a from kube-system to istio-scale-tests-access; removed kube-system/argocd-gitops-token; removed kube-system/argocd-gitops"
	refute_output --partial "removed the namespace"
	[ ! -e "${STUB_DIR}/obj.kube-system.secret.argocd-gitops-token" ]
	[ ! -e "${STUB_DIR}/obj.kube-system.serviceaccount.argocd-gitops" ]
	grep -q -- "get clusterrolebinding -l ${OWNED} --field-selector metadata.name=argocd-gitops-cluster-admin" "$STUB_LOG"
	grep -A3 '^subjects:' "${STUB_DIR}/apply.mesh-a.2.yaml" | grep -q 'namespace: istio-scale-tests-access'
	local token="delete secret -n kube-system -l ${OWNED} --field-selector metadata.name=argocd-gitops-token"
	local sa="delete serviceaccount -n kube-system -l ${OWNED} --field-selector metadata.name=argocd-gitops"
	grep -qF -- "$token" "$STUB_LOG"
	grep -qF -- "$sa" "$STUB_LOG"
	# The old objects go only after the hub Secret carries the new token; kube-system stays.
	[ "$(line_of '--context=hub --request-timeout=60s apply -f -')" -lt "$(line_of "$token")" ]
	! grep -q -e 'delete namespace' -e 'delete clusterrolebinding' "$STUB_LOG" || false
	! grep -q 'delete secret mesh-a-argocd-gitops-cluster-secret' "$STUB_LOG" || false
}

@test "cluster secret (kubernetes): other subjects of the binding are not moved or deleted" {
	printf 'User kube-system admin\nServiceAccount kube-system someone-else\nServiceAccount istio-scale-tests-access argocd-gitops\n' >"${STUB_DIR}/subjects.txt"
	run bash "$SCRIPT"
	assert_success
	! grep -q ' delete ' "$STUB_LOG" || false
	refute_output --partial "Moved the ServiceAccount"
}

@test "cluster secret (kubernetes): moving out of a namespace the script created deletes that namespace and waits for it" {
	namespace old-access Active ours
	old_object old-access secret/argocd-gitops-token
	old_object old-access serviceaccount/argocd-gitops
	printf 'ServiceAccount old-access argocd-gitops\n' >"${STUB_DIR}/subjects.txt"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "from old-access to istio-scale-tests-access; removed old-access/argocd-gitops-token; removed old-access/argocd-gitops; removed the namespace old-access, which this script created"
	grep -q -- '--context=mesh-a --request-timeout=60s delete namespace old-access --wait=false' "$STUB_LOG"
	grep -q -- 'get namespace old-access --ignore-not-found -o name' "$STUB_LOG"
	[ ! -e "${STUB_DIR}/ns.old-access" ]
}

@test "cluster secret (kubernetes): a failed removal of the old ServiceAccount warns with the commands and keeps the new access" {
	namespace kube-system Active
	printf 'ServiceAccount kube-system argocd-gitops\n' >"${STUB_DIR}/subjects.txt"
	printf 'delete serviceaccount -n kube-system\n' >"${STUB_DIR}/fail.txt"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "WARNING: the ServiceAccount argocd-gitops on mesh-a moved from kube-system to istio-scale-tests-access, but removing the old one failed: error: stub refused: delete serviceaccount -n kube-system"
	assert_output --partial "WARNING: delete them by hand: kubectl --context mesh-a -n kube-system delete secret argocd-gitops-token; kubectl --context mesh-a -n kube-system delete serviceaccount argocd-gitops"
	refute_output --partial "Moved the ServiceAccount"
	[ -e "${STUB_DIR}/apply.hub.1.yaml" ]
}

@test "cluster secret (kubernetes): an old token Secret without the label is left and named, and an old ServiceAccount already gone is not called removed" {
	namespace kube-system Active
	old_object kube-system secret/argocd-gitops-token unlabelled
	printf 'ServiceAccount kube-system argocd-gitops\n' >"${STUB_DIR}/subjects.txt"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Moved the ServiceAccount argocd-gitops on mesh-a from kube-system to istio-scale-tests-access; left kube-system/argocd-gitops-token, which lacks the label ${OWNED}; kube-system/argocd-gitops was not found"
	refute_output --partial "removed kube-system/"
	refute_output --partial "No resources found"
	[ -e "${STUB_DIR}/obj.kube-system.secret.argocd-gitops-token" ]
	grep -qF -- "get secret/argocd-gitops-token -n kube-system --ignore-not-found -o name" "$STUB_LOG"
	grep -qF -- "get serviceaccount/argocd-gitops -n kube-system --ignore-not-found -o name" "$STUB_LOG"
}

@test "cluster secret (kubernetes): a spoke that is not a mesh member gets no istio-mesh-member label" {
	MESH_MEMBER=false run bash "$SCRIPT"
	assert_success
	! grep -q 'istio-mesh-member' "${STUB_DIR}/apply.hub.1.yaml" || false
	grep -q 'argocd.argoproj.io/secret-type: cluster' "${STUB_DIR}/apply.hub.1.yaml"
}

@test "cluster secret (kubernetes): SHARD pins the controller shard in the hub Secret, and a new SHARD changes it" {
	SHARD=2 run bash "$SCRIPT"
	assert_success
	assert_output --partial "(mesh member: true; controller shard: 2)"
	[ "$(secret_field "${STUB_DIR}/apply.hub.1.yaml" shard)" = 2 ]
	# With a pin there is nothing to read back.
	! grep -q 'jsonpath={.data.shard}' "$STUB_LOG" || false
	SHARD=0 run bash "$SCRIPT"
	assert_success
	assert_output --partial "(mesh member: true; controller shard: 0)"
	[ "$(secret_field "${STUB_DIR}/apply.hub.2.yaml" shard)" = 0 ]
	refute_output --partial WARNING
}

@test "cluster secret (kubernetes): without SHARD the hub Secret has no shard key, and the read-back finds none" {
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "(mesh member: true; controller shard: not pinned)"
	# apply then removes a pin that this script's last apply wrote.
	! grep -q '^  shard:' "${STUB_DIR}/apply.hub.1.yaml" || false
	grep -q -- '--context=hub --request-timeout=60s get secret mesh-a-argocd-gitops-cluster-secret -n argocd -o jsonpath={.data.shard}' "$STUB_LOG"
	[ "$(line_of '--context=hub --request-timeout=60s apply -f -')" -lt "$(line_of 'jsonpath={.data.shard}')" ]
	refute_output --partial WARNING
}

@test "cluster secret (kubernetes): without SHARD a shard key someone else set is named with the command that removes it" {
	printf '%s' 1 | base64 >"${STUB_DIR}/shard.b64"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "WARNING: argocd/mesh-a-argocd-gitops-cluster-secret keeps shard=1, which this script did not set: Argo CD keeps mesh-a on that controller replica."
	assert_output --partial "kubectl -n argocd patch secret mesh-a-argocd-gitops-cluster-secret --type=json -p '[{\"op\":\"remove\",\"path\":\"/data/shard\"}]'"
	! grep -q ' patch ' "$STUB_LOG" || false
	printf 'jsonpath={.data.shard}\n' >"${STUB_DIR}/fail.txt"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "WARNING: could not read argocd/mesh-a-argocd-gitops-cluster-secret back to check for a shard key"
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

@test "cluster secret (kubernetes): a token the controller never fills fails, naming the Secret; the binding and the old access stay" {
	rm "${STUB_DIR}/token.b64"
	printf 'ServiceAccount kube-system argocd-gitops\n' >"${STUB_DIR}/subjects.txt"
	run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "the token controller did not fill istio-scale-tests-access/argocd-gitops-token on spoke mesh-a within 60s"
	[ "$(grep -c 'jsonpath={.data.token}' "$STUB_LOG")" -eq 30 ]
	[ ! -e "${STUB_DIR}/apply.mesh-a.2.yaml" ]
	[ ! -e "${STUB_DIR}/apply.hub.1.yaml" ]
	! grep -q ' delete ' "$STUB_LOG" || false
}

@test "cluster secret (kubernetes): ACTION=delete removes the hub Secret, the spoke binding, token, ServiceAccount and the namespace it created" {
	namespace istio-scale-tests-access Active ours
	ACTION=delete API_URL='' run bash "$SCRIPT"
	assert_success
	assert_output --partial "Removed the Argo CD access to mesh-a"
	refute_output --partial "Not all of the Argo CD access"
	grep -q -- '--context=hub --request-timeout=60s delete secret mesh-a-argocd-gitops-cluster-secret -n argocd --ignore-not-found' "$STUB_LOG"
	grep -q -- '--context=mesh-a --request-timeout=60s delete clusterrolebinding argocd-gitops-cluster-admin --ignore-not-found' "$STUB_LOG"
	grep -q -- '--context=mesh-a --request-timeout=60s delete secret argocd-gitops-token -n istio-scale-tests-access --ignore-not-found' "$STUB_LOG"
	grep -q -- '--context=mesh-a --request-timeout=60s delete serviceaccount argocd-gitops -n istio-scale-tests-access --ignore-not-found' "$STUB_LOG"
	grep -q -- 'get namespaces -l istio-scale-tests/created-by=create-argocd-cluster-secret --field-selector metadata.name=istio-scale-tests-access -o name' "$STUB_LOG"
	grep -q -- '--context=mesh-a --request-timeout=60s delete namespace istio-scale-tests-access --wait=false' "$STUB_LOG"
	[ ! -e "${STUB_DIR}/ns.istio-scale-tests-access" ]
	! grep -q ' apply ' "$STUB_LOG" || false
}

@test "cluster secret (kubernetes): ACTION=delete never deletes kube-system or a namespace the script did not create" {
	namespace kube-system Active ours
	SPOKE_SA_NAMESPACE=kube-system ACTION=delete run bash "$SCRIPT"
	assert_success
	! grep -q 'delete namespace' "$STUB_LOG" || false
	: >"$STUB_LOG"
	namespace shared Active
	SPOKE_SA_NAMESPACE=shared ACTION=delete run bash "$SCRIPT"
	assert_success
	grep -q -- 'delete serviceaccount argocd-gitops -n shared --ignore-not-found' "$STUB_LOG"
	! grep -q 'delete namespace' "$STUB_LOG" || false
	[ -e "${STUB_DIR}/ns.shared" ]
}

@test "cluster secret (kubernetes): ACTION=delete warns when its namespace is still terminating after 120s, and exits 0" {
	namespace istio-scale-tests-access Active ours
	: >"${STUB_DIR}/stuck.txt"
	ACTION=delete run bash "$SCRIPT"
	assert_success
	assert_output --partial "the namespace istio-scale-tests-access on mesh-a is still terminating after 120s"
	assert_output --partial "WARNING: could not remove the ServiceAccount istio-scale-tests-access/argocd-gitops"
	assert_output --partial "Not all of the Argo CD access to mesh-a was removed (WARNING above); exiting 0 so the destroy goes on"
	refute_output --partial "Removed the Argo CD access"
	[ "$(grep -c 'get namespace istio-scale-tests-access --ignore-not-found -o name' "$STUB_LOG")" -eq 60 ]
}

@test "cluster secret (kubernetes): ACTION=delete with the spoke or the hub gone warns, names what is left, and exits 0" {
	echo mesh-a >"${STUB_DIR}/down.txt"
	ACTION=delete run bash "$SCRIPT"
	assert_success
	assert_output --partial "WARNING: could not remove the ServiceAccount istio-scale-tests-access/argocd-gitops, its token Secret, the ClusterRoleBinding argocd-gitops-cluster-admin and (if this script created it) the namespace istio-scale-tests-access on mesh-a"
	assert_output --partial "Not all of the Argo CD access to mesh-a was removed"
	refute_output --partial "Removed the Argo CD access"
	echo hub >"${STUB_DIR}/down.txt"
	ACTION=delete run bash "$SCRIPT"
	assert_success
	assert_output --partial "WARNING: could not delete the cluster Secret argocd/mesh-a-argocd-gitops-cluster-secret on the hub (it holds a cluster-admin token for mesh-a)"
	assert_output --partial "Not all of the Argo CD access to mesh-a was removed"
	refute_output --partial "Removed the Argo CD access"
}

@test "cluster secret: a bad PLATFORM, ACTION, MESH_MEMBER, SPOKE_SA_NAMESPACE or SHARD, or kubernetes without a kubeconfig, stops before any call" {
	PLATFORM=okd run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "PLATFORM must be kubernetes or openshift (got: okd)"
	ACTION=remove run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "ACTION must be apply or delete (got: remove)"
	MESH_MEMBER=yes run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "MESH_MEMBER must be true or false (got: yes)"
	SPOKE_SA_NAMESPACE=Kube_System run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "SPOKE_SA_NAMESPACE must be a namespace name (got: Kube_System)"
	SHARD=-1 run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "SHARD must be empty or a shard number (got: -1)"
	SPOKE_CONTEXT='' run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "platform kubernetes needs KUBECONFIG_PATH and SPOKE_CONTEXT"
	[ ! -s "$STUB_LOG" ]
}

#!/usr/bin/env bats
# charts/mesh-wiring-verify readiness.sh (POSIX sh + curl) against a stub curl that answers
# for the Kubernetes API and istiod's /metrics: Ready only with every remote secret, the
# shared root from cacerts in istio-ca-root-cert and istiod managing every member; any
# failed API read is NotReady, never Ready.

load test_helper

TEMPLATE="${ROOT}/charts/mesh-wiring-verify/templates/configmap-check-script.yaml"

# pem <label>: a PEM-shaped block (the check compares base64 bodies, not certificates).
pem() {
	printf -- '-----BEGIN CERTIFICATE-----\n%s\n%s\n-----END CERTIFICATE-----\n' \
		"$(printf '%s' "root-$1-line-one" | base64)" "$(printf '%s' "root-$1-line-two" | base64)"
}

# json_str: stdin as a JSON string body (newlines as \n).
json_str() { awk 'BEGIN { ORS = "" } { print $0 "\\n" }'; }

# table <n>: a Table listing with n rows.
table() {
	local rows="" i
	for ((i = 0; i < $1; i++)); do
		rows+="${rows:+,}{\"cells\":[\"istio-remote-secret-c${i}\",\"Opaque\",1,\"5m\"],\"object\":null}"
	done
	printf '{"kind":"Table","columnDefinitions":[{"name":"Name","type":"string"}],"rows":[%s]}\n' "$rows"
}

setup() {
	STUB_DIR="$(mktemp -d)"
	export STUB_DIR
	mkdir -p "${STUB_DIR}/bin" "${STUB_DIR}/sa"
	echo token >"${STUB_DIR}/sa/token"
	echo ca >"${STUB_DIR}/sa/ca.crt"
	# The script as the ConfigMap ships it; the service account path points at the stub.
	sed -n '/^  readiness.sh: |$/,$p' "$TEMPLATE" | sed '1d; s/^    //' |
		sed "s#^SA=/var/run/secrets/kubernetes.io/serviceaccount#SA=${STUB_DIR}/sa#" >"${STUB_DIR}/readiness.sh"
	# curl: <name>.code and <name>.body per endpoint; -w '\n%{http_code}' appends the code.
	cat >"${STUB_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="" w=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	-w) w="$2"; shift 2 ;;
	-A | -H | --cacert | --max-time) shift 2 ;;
	-*) shift ;;
	*) url="$1"; shift ;;
	esac
done
case "$url" in
*"/secrets?labelSelector=istio%2FmultiCluster%3Dtrue&includeObject=None") n=list ;;
*/secrets/cacerts) n=cacerts ;;
*/configmaps/istio-ca-root-cert) n=cm ;;
*:15014/metrics) n=metrics ;;
*) echo "stub curl: unexpected URL $url" >&2; exit 99 ;;
esac
code="$(cat "$STUB_DIR/$n.code" 2>/dev/null || echo 200)"
if [[ -z "$w" ]]; then
	# curl -sf: a failed request prints nothing and exits non-zero.
	[[ "$code" == 200 ]] || exit 22
	cat "$STUB_DIR/$n.body"
	exit 0
fi
[[ "$code" == 200 ]] && cat "$STUB_DIR/$n.body" || echo '{"kind":"Status"}'
printf '\n%s' "$code"
EOF
	chmod +x "${STUB_DIR}/bin/curl"
	export PATH="${STUB_DIR}/bin:${PATH}"
	export EXPECTED_MEMBERS=2
	ROOT_PEM="$(pem shared)"
	table 2 >"${STUB_DIR}/list.body"
	cacerts "$ROOT_PEM"
	configmap "$ROOT_PEM"
	metrics 1 1
}

teardown() {
	rm -rf "$STUB_DIR"
}

# cacerts <root pem>: the Secret as the API returns it (data base64, plus a CA key).
cacerts() {
	printf '{"kind":"Secret","metadata":{"name":"cacerts","managedFields":[{"fieldsV1":{"f:data":{"f:root-cert.pem":{}}}}]},"data":{"ca-key.pem":"%s","root-cert.pem":"%s"}}\n' \
		"$(printf 'KEY' | base64)" "$(printf '%s' "$1" | base64 | tr -d '\n')" >"${STUB_DIR}/cacerts.body"
}

# configmap <pem>: istio-ca-root-cert with a JSON-escaped root-cert.pem.
configmap() {
	printf '{"kind":"ConfigMap","data":{"root-cert.pem":"%s"}}\n' "$(printf '%s' "$1" | json_str)" >"${STUB_DIR}/cm.body"
}

# metrics <local> <remote>
metrics() {
	printf 'istiod_managed_clusters{cluster_type="local"} %s\nistiod_managed_clusters{cluster_type="remote"} %s\n' "$1" "$2" >"${STUB_DIR}/metrics.body"
}

@test "mesh-wiring gate: Ready with every secret, the shared root and every member ingested" {
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output "Ready: secrets=2 istiod_managed=2 (local=1 remote=1) expected=2 ca=shared"
}

@test "mesh-wiring gate: a root bundle that contains the shared root is Ready" {
	configmap "$(pem other)
${ROOT_PEM}"
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "ca=shared"
}

@test "mesh-wiring gate: istiod on its own self-signed root is NotReady" {
	configmap "$(pem other)"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "NotReady: istiod is not using the shared mesh root from cacerts"
}

@test "mesh-wiring gate: every failed API read is NotReady, with the HTTP status" {
	echo 403 >"${STUB_DIR}/list.code"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "NotReady: cannot list the remote secrets in istio-system (HTTP 403)"
	rm "${STUB_DIR}/list.code"

	echo 404 >"${STUB_DIR}/cacerts.code"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "NotReady: no cacerts secret in istio-system"
	echo 500 >"${STUB_DIR}/cacerts.code"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "NotReady: cannot read cacerts in istio-system (HTTP 500)"
	rm "${STUB_DIR}/cacerts.code"

	echo 404 >"${STUB_DIR}/cm.code"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "NotReady: no istio-ca-root-cert ConfigMap in istio-system"
	rm "${STUB_DIR}/cm.code"

	echo 503 >"${STUB_DIR}/metrics.code"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "NotReady: istiod metrics unreachable"
}

@test "mesh-wiring gate: missing remote secrets or remote clusters are NotReady" {
	table 1 >"${STUB_DIR}/list.body"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: remote secrets 1 < expected 2"

	table 2 >"${STUB_DIR}/list.body"
	metrics 2 0
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: istiod sees 0 remote clusters < expected 1 (N-1)"
}

@test "mesh-wiring gate: without an expected size, every remote secret must be ingested" {
	export EXPECTED_MEMBERS=0
	table 3 >"${STUB_DIR}/list.body"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: istiod manages 2 clusters < 3 remote secrets present"
}

@test "mesh-wiring gate: with the CA check off it says so instead of ca=shared" {
	configmap "$(pem other)"
	CA_CHECK_ENABLED=false run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "ca=unchecked"
}

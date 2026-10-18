#!/usr/bin/env bats
# charts/mesh-wiring-verify readiness.sh (POSIX sh + curl) against a stub curl that answers
# for the Kubernetes API and istiod's /metrics, and a stub clock: Ready only with every
# remote secret, the shared root from cacerts in istio-ca-root-cert (and its fingerprint),
# an east-west gateway address, and istiod managing and syncing every member; any failed
# API read is NotReady, never Ready; the requests share one time budget inside the probe's
# timeout.

load test_helper

TEMPLATE="${ROOT}/charts/mesh-wiring-verify/templates/configmap-check-script.yaml"

# der <label>: the bytes a fake certificate stands for (the check hashes them, never parses).
der() { printf 'fake-der-%s-0123456789abcdef-0123456789abcdef-0123456789abcdef-%s' "$1" "$1"; }

# pem <label>: a PEM block of der <label>, wrapped at 64 columns like a real one.
pem() {
	printf -- '-----BEGIN CERTIFICATE-----\n%s\n-----END CERTIFICATE-----\n' "$(der "$1" | base64 | tr -d '\n' | fold -w 64)"
}

# fingerprint <label>: what the check prints as root= for that certificate.
fingerprint() { der "$1" | sha256sum | cut -c1-16; }

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
	# <name>.rc makes the request itself fail with that curl exit code (28: timed out);
	# <name>.delay advances the stub clock by that many seconds. Each request's name and
	# --max-time go to requests.log.
	cat >"${STUB_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="" w="" mt=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	-w) w="$2"; shift 2 ;;
	--max-time) mt="$2"; shift 2 ;;
	-A | -H | --cacert) shift 2 ;;
	-*) shift ;;
	*) url="$1"; shift ;;
	esac
done
case "$url" in
*"/secrets?labelSelector=istio%2FmultiCluster%3Dtrue&includeObject=None") n=list ;;
*/secrets/cacerts) n=cacerts ;;
*/configmaps/istio-ca-root-cert) n=cm ;;
*/services/istio-eastwestgateway) n=ew ;;
*:15014/metrics) n=metrics ;;
*) echo "stub curl: unexpected URL $url" >&2; exit 99 ;;
esac
echo "$n ${mt:-none}" >>"$STUB_DIR/requests.log"
if [[ -f "$STUB_DIR/$n.delay" ]]; then
	echo $(( $(cat "$STUB_DIR/now") + $(cat "$STUB_DIR/$n.delay") )) >"$STUB_DIR/now"
fi
if [[ -f "$STUB_DIR/$n.rc" ]]; then
	echo "curl: ($(cat "$STUB_DIR/$n.rc")) stub failure" >&2
	[[ -z "$w" ]] || printf '\n000'
	exit "$(cat "$STUB_DIR/$n.rc")"
fi
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
	# date +%s: the stub clock.
	printf '#!/usr/bin/env bash\ncat "$STUB_DIR/now"\n' >"${STUB_DIR}/bin/date"
	chmod +x "${STUB_DIR}/bin/curl" "${STUB_DIR}/bin/date"
	echo 1000 >"${STUB_DIR}/now"
	export PATH="${STUB_DIR}/bin:${PATH}"
	export EXPECTED_MEMBERS=2
	unset CHECK_TIMEOUT CURL_TIMEOUT REQUIRE_REMOTE_SYNC EASTWEST_CHECK_ENABLED CA_CHECK_ENABLED
	ROOT_PEM="$(pem shared)"
	table 2 >"${STUB_DIR}/list.body"
	cacerts "$ROOT_PEM"
	configmap "$ROOT_PEM"
	service LoadBalancer '"ingress":[{"ip":"192.0.2.20","ipMode":"VIP"}]'
	metrics 1 1
	sync c1 synced
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

# service <type> [loadBalancer status fields]: the east-west gateway Service, one-line JSON.
service() {
	printf '{"kind":"Service","metadata":{"name":"istio-eastwestgateway","managedFields":[{"fieldsType":"FieldsV1","fieldsV1":{"f:spec":{"f:type":{}}}}]},"spec":{"ports":[{"name":"tls","protocol":"TCP","port":15443}],"type":"%s"},"status":{"loadBalancer":{%s}}}\n' \
		"$1" "${2:-}" >"${STUB_DIR}/ew.body"
}

# metrics <local> <remote>: istiod_managed_clusters; sync lines are appended by sync().
metrics() {
	printf 'istiod_managed_clusters{cluster_type="local"} %s\nistiod_managed_clusters{cluster_type="remote"} %s\n' "$1" "$2" >"${STUB_DIR}/metrics.body"
}

# sync <cluster> <status>: istiod_remote_cluster_sync_status for one remote cluster, 1 for
# <status> and 0 for the other three (as istiod exports them).
sync() {
	local s
	for s in closed synced syncing timeout; do
		printf 'istiod_remote_cluster_sync_status{cluster="%s",cluster_type="remote",status="%s"} %s\n' \
			"$1" "$s" "$([[ "$s" == "$2" ]] && echo 1 || echo 0)" >>"${STUB_DIR}/metrics.body"
	done
}

@test "mesh-wiring gate: Ready with every secret, the shared root, an east-west address and every member synced" {
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output "Ready: secrets=2 istiod_managed=2 (local=1 remote=1) expected=2 ca=shared synced=1 root=$(fingerprint shared) eastwest=192.0.2.20"
}

@test "mesh-wiring gate: a root bundle that contains the shared root is Ready; root= is the first certificate of cacerts" {
	configmap "$(pem other)
${ROOT_PEM}"
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "ca=shared"
	cacerts "${ROOT_PEM}
$(pem second)"
	configmap "${ROOT_PEM}
$(pem second)"
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "root=$(fingerprint shared) "
}

@test "mesh-wiring gate: a root that does not decode prints root=unknown, never a hash of nothing" {
	cacerts '-----BEGIN CERTIFICATE-----
!!!!
-----END CERTIFICATE-----'
	configmap '-----BEGIN CERTIFICATE-----
!!!!
-----END CERTIFICATE-----'
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "root=unknown"
	refute_output --partial "root=e3b0c44298fc1c14"
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

	echo 404 >"${STUB_DIR}/ew.code"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "NotReady: no east-west gateway Service istio-system/istio-eastwestgateway"
	echo 403 >"${STUB_DIR}/ew.code"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "NotReady: cannot read the Service istio-system/istio-eastwestgateway (HTTP 403)"
	rm "${STUB_DIR}/ew.code"

	echo 503 >"${STUB_DIR}/metrics.code"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "NotReady: istiod metrics unreachable"
}

@test "mesh-wiring gate: a request that times out is NotReady naming the timeout, not a bare HTTP 000" {
	echo 28 >"${STUB_DIR}/list.rc"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "NotReady: cannot list the remote secrets in istio-system (HTTP 000, no answer within 5s)"
	rm "${STUB_DIR}/list.rc"
	echo 7 >"${STUB_DIR}/cacerts.rc"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "NotReady: cannot read cacerts in istio-system (HTTP 000)"
}

@test "mesh-wiring gate: the requests share the check budget, and running out is NotReady with the reason" {
	# 8s budget: the list takes 4s, so cacerts may take only the 4s left; it takes them all.
	echo 4 >"${STUB_DIR}/list.delay"
	echo 4 >"${STUB_DIR}/cacerts.delay"
	CHECK_TIMEOUT=8 run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: the 8s check budget ran out before GET /api/v1/namespaces/istio-system/configmaps/istio-ca-root-cert (slow API server or istiod)"
	[ "$(cat "${STUB_DIR}/requests.log")" = "list 5
cacerts 4" ]
}

@test "mesh-wiring gate: istiod's /metrics gets only what is left of the budget" {
	echo 6 >"${STUB_DIR}/ew.delay"
	CHECK_TIMEOUT=8 run sh "${STUB_DIR}/readiness.sh"
	assert_success
	grep -qx 'metrics 2' "${STUB_DIR}/requests.log"
}

@test "mesh-wiring gate: the deployment gives the check the probe timeout minus 2s" {
	command -v helm >/dev/null || skip "helm not installed"
	run helm template x "${ROOT}/charts/mesh-wiring-verify" --show-only templates/deployment.yaml
	assert_success
	grep -A1 'name: CHECK_TIMEOUT' <<<"$output" | grep -q 'value: "8"'
	run helm template x "${ROOT}/charts/mesh-wiring-verify" --set probe.timeoutSeconds=2 --show-only templates/deployment.yaml
	assert_success
	grep -A1 'name: CHECK_TIMEOUT' <<<"$output" | grep -q 'value: "1"'
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

@test "mesh-wiring gate: a remote cluster istiod manages but has not synced is NotReady, named with its state" {
	metrics 1 1
	sync c1 timeout
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: istiod has synced 0 remote cluster(s) < 1; not synced: c1 (timeout). This member's istiod must reach each member's API server at the URL in its remote secret"

	export EXPECTED_MEMBERS=3
	table 3 >"${STUB_DIR}/list.body"
	metrics 1 2
	sync c1 synced
	sync c2 syncing
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "istiod has synced 1 remote cluster(s) < 2; not synced: c2 (syncing)"
}

@test "mesh-wiring gate: closed counts as synced (istiod's metric after a remote secret changed and the new connection synced)" {
	metrics 1 1
	sync c1 closed
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "synced=1"
	export EXPECTED_MEMBERS=3
	table 3 >"${STUB_DIR}/list.body"
	metrics 1 2
	sync c1 closed
	sync c2 timeout
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "istiod has synced 1 remote cluster(s) < 2; not synced: c2 (timeout)."
}

@test "mesh-wiring gate: without an expected size, every managed remote cluster must be synced" {
	export EXPECTED_MEMBERS=0
	metrics 1 2
	sync c1 synced
	sync c2 timeout
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "istiod has synced 1 remote cluster(s) < 2; not synced: c2 (timeout)"
	metrics 1 2
	sync c1 synced
	sync c2 synced
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "synced=2"
}

@test "mesh-wiring gate: no sync metric at all is NotReady unless requireRemoteSync is off" {
	metrics 1 1
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "NotReady: istiod exports no istiod_remote_cluster_sync_status"
	assert_output --partial "istiodCheck.requireRemoteSync=false"
	REQUIRE_REMOTE_SYNC=false run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "synced=unchecked"
}

@test "mesh-wiring gate: without an expected size, every remote secret must be ingested" {
	export EXPECTED_MEMBERS=0
	table 3 >"${STUB_DIR}/list.body"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: istiod manages 2 clusters < 3 remote secrets present"
}

@test "mesh-wiring gate: an east-west LoadBalancer without an address is NotReady; a hostname or another type is reported" {
	service LoadBalancer
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: the east-west gateway Service istio-system/istio-eastwestgateway has no external address yet (LoadBalancer <pending>)"
	service LoadBalancer '"ingress":[{"hostname":"ew.mesh-a.example"}]'
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "eastwest=ew.mesh-a.example"
	service NodePort
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "eastwest=NodePort"
}

@test "mesh-wiring gate: with the CA or east-west check off it says so instead of a value" {
	configmap "$(pem other)"
	CA_CHECK_ENABLED=false run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "ca=unchecked synced=1 root=unchecked"
	: >"${STUB_DIR}/requests.log"
	EASTWEST_CHECK_ENABLED=false CA_CHECK_ENABLED=false run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "eastwest=unchecked"
	! grep -q '^ew ' "${STUB_DIR}/requests.log" || false
}

@test "mesh-wiring gate: with the istiod check off, the line still carries the root and the east-west address" {
	ISTIOD_CHECK_ENABLED=false run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output "Ready: secrets=2 expected=2 ca=shared root=$(fingerprint shared) eastwest=192.0.2.20 (istiod check disabled)"
}

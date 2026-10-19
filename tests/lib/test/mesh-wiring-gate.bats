#!/usr/bin/env bats
# charts/mesh-wiring-verify readiness.sh (POSIX sh + curl) against a stub curl that answers
# for the Kubernetes API and each istiod replica's /metrics, and a stub clock: Ready only with
# every remote secret, the shared root from cacerts in istio-ca-root-cert (and its
# fingerprint), an east-west gateway address, and every Ready endpoint of the istiod Service
# managing and syncing every member (closed counts only on Istio 1.30 and later); any failed
# read is NotReady, never Ready, and names the replica; the requests share one time budget
# inside the probe's timeout, and the replicas are read at once.

load test_helper

TEMPLATE="${ROOT}/charts/mesh-wiring-verify/templates/configmap-check-script.yaml"
CHART="${ROOT}/charts/mesh-wiring-verify"

# The istiod replicas of most tests (documentation addresses).
A=198.51.100.11 B=198.51.100.12 C=198.51.100.13 V6=2001:db8::11

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
	mkdir -p "${STUB_DIR}/bin" "${STUB_DIR}/sa" "${STUB_DIR}/work"
	echo token >"${STUB_DIR}/sa/token"
	echo ca >"${STUB_DIR}/sa/ca.crt"
	# The script as the ConfigMap ships it; the service account path points at the stub.
	sed -n '/^  readiness.sh: |$/,$p' "$TEMPLATE" | sed '1d; s/^    //' |
		sed "s#^SA=/var/run/secrets/kubernetes.io/serviceaccount#SA=${STUB_DIR}/sa#" >"${STUB_DIR}/readiness.sh"
	# curl (POSIX sh): <name>.code and <name>.body per endpoint; -w '\n%{http_code}' appends the
	# code. An istiod replica's name is m_<address> (":" as "_"); one without a body refuses
	# the connection. <name>.rc makes the request itself fail with that curl exit code (28:
	# timed out); <name>.delay advances the stub clock by that many seconds. With a file
	# "barrier" holding k, each /metrics request waits until k of them have started (up to
	# 5s, then it times out): only requests made at once pass. Each request's name and
	# --max-time go to requests.log.
	cat >"${STUB_DIR}/bin/curl" <<'EOF'
#!/bin/sh
url="" w="" mt=""
while [ $# -gt 0 ]; do
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
*"/apis/discovery.k8s.io/v1/namespaces/istio-system/endpointslices?labelSelector=kubernetes.io%2Fservice-name%3Distiod") n=eps ;;
http://*:15014/metrics)
	a=${url#http://}; a=${a%:15014/metrics}
	case "$a" in \[*\]) a=${a#\[}; a=${a%\]} ;; *:*) echo "stub curl: IPv6 address without brackets in $url" >&2; exit 3 ;; esac
	n="m_$(printf '%s' "$a" | tr ':' '_')" ;;
*) echo "stub curl: unexpected URL $url" >&2; exit 99 ;;
esac
echo "$n ${mt:-none}" >>"$STUB_DIR/requests.log"
if [ -f "$STUB_DIR/barrier" ]; then
	case "$n" in m_*)
		: >"$STUB_DIR/arrived.$n"
		i=0
		while [ "$(ls "$STUB_DIR" | grep -c '^arrived\.')" -lt "$(cat "$STUB_DIR/barrier")" ]; do
			i=$((i + 1))
			if [ "$i" -gt 100 ]; then echo "curl: (28) stub barrier: the other requests never started" >&2; exit 28; fi
			sleep 0.05
		done ;;
	esac
fi
if [ -f "$STUB_DIR/$n.delay" ]; then
	echo $(( $(cat "$STUB_DIR/now") + $(cat "$STUB_DIR/$n.delay") )) >"$STUB_DIR/now"
fi
if [ -f "$STUB_DIR/$n.rc" ]; then
	echo "curl: ($(cat "$STUB_DIR/$n.rc")) stub failure" >&2
	[ -z "$w" ] || printf '\n000'
	exit "$(cat "$STUB_DIR/$n.rc")"
fi
code="$(cat "$STUB_DIR/$n.code" 2>/dev/null || echo 200)"
if [ -z "$w" ]; then
	# curl -sSf: a failed request prints only its error and exits non-zero.
	if [ "$code" != 200 ]; then echo "curl: (22) The requested URL returned error: $code" >&2; exit 22; fi
	if [ ! -f "$STUB_DIR/$n.body" ]; then echo "curl: (7) Failed to connect to $a port 15014: Connection refused" >&2; exit 7; fi
	cat "$STUB_DIR/$n.body"
	exit 0
fi
if [ "$code" = 200 ]; then cat "$STUB_DIR/$n.body"; else echo '{"kind":"Status"}'; fi
printf '\n%s' "$code"
EOF
	# date +%s: the stub clock.
	printf '#!/bin/sh\ncat "$STUB_DIR/now"\n' >"${STUB_DIR}/bin/date"
	chmod +x "${STUB_DIR}/bin/curl" "${STUB_DIR}/bin/date"
	echo 1000 >"${STUB_DIR}/now"
	export PATH="${STUB_DIR}/bin:${PATH}"
	export EXPECTED_MEMBERS=2 WORK_DIR="${STUB_DIR}/work"
	unset CHECK_TIMEOUT CURL_TIMEOUT REQUIRE_REMOTE_SYNC EASTWEST_CHECK_ENABLED CA_CHECK_ENABLED ISTIOD_SERVICE ISTIOD_PORT
	ROOT_PEM="$(pem shared)"
	table 2 >"${STUB_DIR}/list.body"
	cacerts "$ROOT_PEM"
	configmap "$ROOT_PEM"
	service LoadBalancer '"ingress":[{"ip":"192.0.2.20","ipMode":"VIP"}]'
	endpoints "$(slice istiod-abcde IPv4 "$A istiod-a true")"
	replica "$A"
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

# slice <name> <addressType> [endpoint...]: one EndpointSlice of the istiod Service, one-line
# JSON in the API's field order (metadata with managedFields first, ports last); each endpoint
# is "<address> <pod, or - for no targetRef> <ready: true, false or unset>". A not-ready
# endpoint reads like a pod being deleted (terminating, still serving); unset has no ready
# condition at all. Every endpoint carries zone hints (a "name" outside targetRef).
slice() {
	local name="$1" type="$2" e addr pod ready cond ref eps=""
	shift 2
	for e in "$@"; do
		read -r addr pod ready <<<"$e"
		case "$ready" in
		unset) cond='{}' ;;
		false) cond='{"ready":false,"serving":true,"terminating":true}' ;;
		*) cond='{"ready":true,"serving":true,"terminating":false}' ;;
		esac
		ref=""
		[[ "$pod" == - ]] || ref=",\"targetRef\":{\"kind\":\"Pod\",\"namespace\":\"istio-system\",\"name\":\"${pod}\",\"uid\":\"uid-${pod}\"}"
		eps+="${eps:+,}{\"addresses\":[\"${addr}\"],\"conditions\":${cond}${ref},\"nodeName\":\"node-${pod}\",\"zone\":\"zone-a\",\"hints\":{\"forZones\":[{\"name\":\"zone-a\"}]}}"
	done
	printf '{"metadata":{"name":"%s","generateName":"istiod-","namespace":"istio-system","labels":{"endpointslice.kubernetes.io/managed-by":"endpointslice-controller.k8s.io","kubernetes.io/service-name":"istiod"},"managedFields":[{"manager":"kube-controller-manager","operation":"Update","apiVersion":"discovery.k8s.io/v1","fieldsType":"FieldsV1","fieldsV1":{"f:addressType":{},"f:endpoints":{},"f:metadata":{"f:labels":{".":{},"f:kubernetes.io/service-name":{}}},"f:ports":{}}}]},"addressType":"%s","endpoints":%s,"ports":[{"name":"grpc-xds","protocol":"TCP","port":15010},{"name":"http-monitoring","protocol":"TCP","port":15014}]}' \
		"$name" "$type" "$([[ -n "$eps" ]] && echo "[${eps}]" || echo null)"
}

# endpoints [slice...]: the EndpointSliceList the API returns for the istiod Service.
endpoints() {
	local IFS=,
	printf '{"kind":"EndpointSliceList","apiVersion":"discovery.k8s.io/v1","metadata":{"resourceVersion":"42"},"items":[%s]}\n' "$*" >"${STUB_DIR}/eps.body"
}

# replica <address>: the istiod replica that metrics and sync write to next.
replica() { CUR="m_${1//:/_}"; }

# metrics <local> <remote> [tag]: a replica's /metrics with istiod_managed_clusters and
# istio_build{component="pilot"} (tag 1.30.5 unless named; none leaves istio_build out),
# among lines the check does not read; sync() appends the sync samples.
metrics() {
	{
		printf '# HELP istiod_managed_clusters Number of clusters managed by istiod\n# TYPE istiod_managed_clusters gauge\n'
		[[ "${3-1.30.5}" == none ]] || printf 'istio_build{component="pilot",tag="%s"} 1\n' "${3-1.30.5}"
		printf 'istiod_managed_clusters{cluster_type="local"} %s\nistiod_managed_clusters{cluster_type="remote"} %s\n' "$1" "$2"
		printf 'pilot_xds_pushes{type="cds"} 12\n'
	} >"${STUB_DIR}/${CUR}.body"
}

# sync <cluster> <status>: istiod_remote_cluster_sync_status for one remote cluster, 1 for
# <status> and 0 for the other three (as istiod exports them).
sync() {
	local s
	for s in closed synced syncing timeout; do
		printf 'istiod_remote_cluster_sync_status{cluster="%s",cluster_type="remote",status="%s"} %s\n' \
			"$1" "$s" "$([[ "$s" == "$2" ]] && echo 1 || echo 0)" >>"${STUB_DIR}/${CUR}.body"
	done
}

# synced_replica <address> [tag]: a replica that manages and synced both members.
synced_replica() {
	replica "$1"
	metrics 1 1 "${2:-1.30.5}"
	sync c1 synced
}

@test "mesh-wiring gate: Ready with every secret, the shared root, an east-west address and every member synced" {
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output "Ready: secrets=2 istiod_managed=2 (local=1 remote=1) expected=2 ca=shared synced=1 replicas=1 root=$(fingerprint shared) eastwest=192.0.2.20"
	# Nothing is left in the work directory.
	[ -z "$(ls -A "${STUB_DIR}/work")" ]
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

	# A Role without the EndpointSlice rule (a chart not yet synced) is a 403 too.
	echo 403 >"${STUB_DIR}/eps.code"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: cannot list the EndpointSlices of the istiod Service istio-system/istiod (HTTP 403)"
	rm "${STUB_DIR}/eps.code"

	echo 503 >"${STUB_DIR}/m_${A}.code"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: istiod pod istiod-a (${A}): metrics unreachable at http://${A}:15014/metrics (curl: (22) The requested URL returned error: 503)"
	[ -z "$(ls -A "${STUB_DIR}/work")" ]
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
	rm "${STUB_DIR}/cacerts.rc"
	echo 28 >"${STUB_DIR}/m_${A}.rc"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: istiod pod istiod-a (${A}): metrics unreachable at http://${A}:15014/metrics (no answer within 5s)"
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
	# The EndpointSlice list used up what was left: no replica is read.
	rm "${STUB_DIR}/cacerts.delay"
	: >"${STUB_DIR}/requests.log"
	echo 4 >"${STUB_DIR}/eps.delay"
	CHECK_TIMEOUT=8 run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: the 8s check budget ran out before reading /metrics from 1 istiod replica(s) (slow API server or istiod)"
	! grep -q '^m_' "${STUB_DIR}/requests.log" || false
}

@test "mesh-wiring gate: istiod's /metrics gets only what is left of the budget" {
	echo 6 >"${STUB_DIR}/ew.delay"
	CHECK_TIMEOUT=8 run sh "${STUB_DIR}/readiness.sh"
	assert_success
	grep -qx 'eps 2' "${STUB_DIR}/requests.log"
	grep -qx "m_${A} 2" "${STUB_DIR}/requests.log"
}

@test "mesh-wiring gate: the deployment gives the check the probe timeout minus 2s" {
	command -v helm >/dev/null || skip "helm not installed"
	run helm template x "$CHART" --show-only templates/deployment.yaml
	assert_success
	grep -A1 'name: CHECK_TIMEOUT' <<<"$output" | grep -q 'value: "8"'
	run helm template x "$CHART" --set probe.timeoutSeconds=2 --show-only templates/deployment.yaml
	assert_success
	grep -A1 'name: CHECK_TIMEOUT' <<<"$output" | grep -q 'value: "1"'
}

@test "mesh-wiring gate: the chart lets the check list the istiod EndpointSlices and write only to its emptyDir" {
	command -v helm >/dev/null || skip "helm not installed"
	run helm template x "$CHART" --show-only templates/rbac.yaml
	assert_success
	grep -A2 'apiGroups: \["discovery.k8s.io"\]' <<<"$output" | grep -q 'resources: \["endpointslices"\]'
	grep -A3 'apiGroups: \["discovery.k8s.io"\]' <<<"$output" | grep -q 'verbs: \["list"\]'
	run helm template x "$CHART" --set istiodCheck.enabled=false --show-only templates/rbac.yaml
	assert_success
	refute_output --partial endpointslices
	run helm template x "$CHART" --show-only templates/deployment.yaml
	assert_success
	grep -A1 'name: ISTIOD_SERVICE' <<<"$output" | grep -q 'value: "istiod"'
	grep -A1 'name: WORK_DIR' <<<"$output" | grep -q 'value: /work'
	grep -A1 -- '- name: work$' <<<"$output" | grep -q 'mountPath: /work'
	grep -q 'readOnlyRootFilesystem: true' <<<"$output"
	refute_output --partial ISTIOD_HOST
}

@test "mesh-wiring gate: an istiodCheck.host override fails the render, naming istiodCheck.service" {
	command -v helm >/dev/null || skip "helm not installed"
	run helm template x "$CHART" --set istiodCheck.host=istiod.istio-system.svc
	assert_failure
	assert_output --partial "istiodCheck.host was replaced by istiodCheck.service"
	run helm template x "$CHART" --set istiodCheck.service=istiod-canary --show-only templates/deployment.yaml
	assert_success
	grep -A1 'name: ISTIOD_SERVICE' <<<"$output" | grep -q 'value: "istiod-canary"'
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
	assert_output "NotReady: istiod pod istiod-a (${A}) sees 0 remote clusters < expected 1 (N-1)"
}

@test "mesh-wiring gate: a remote cluster istiod manages but has not synced is NotReady, named with its state" {
	metrics 1 1
	sync c1 timeout
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: istiod pod istiod-a (${A}) has synced 0 remote cluster(s) < 1; not synced: c1 (timeout). This member's istiod must reach each member's API server at the URL in its remote secret"

	export EXPECTED_MEMBERS=3
	table 3 >"${STUB_DIR}/list.body"
	metrics 1 2
	sync c1 synced
	sync c2 syncing
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "istiod-a (${A}) has synced 1 remote cluster(s) < 2; not synced: c2 (syncing)"
}

@test "mesh-wiring gate: closed counts as synced on Istio 1.30 and later (a remote secret changed and the new connection synced)" {
	local tag
	for tag in 1.30.5 1.30 1.30.0-beta.1 1.31-dev 2.0.0; do
		metrics 1 1 "$tag"
		sync c1 closed
		run sh "${STUB_DIR}/readiness.sh"
		assert_success
		assert_output --partial "synced=1 replicas=1"
	done
	export EXPECTED_MEMBERS=3
	table 3 >"${STUB_DIR}/list.body"
	metrics 1 2
	sync c1 closed
	sync c2 timeout
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: istiod pod istiod-a (${A}) has synced 1 remote cluster(s) < 2; not synced: c2 (timeout). This member's istiod must reach each member's API server at the URL in its remote secret"
}

@test "mesh-wiring gate: closed is not synced on Istio 1.29, and the reason names the build and the restart" {
	metrics 1 1 1.29.4
	sync c1 closed
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: istiod pod istiod-a (${A}) has synced 0 remote cluster(s) < 1; not synced: c1 (closed). closed counts as synced only on Istio 1.30 and later, and this replica's istio_build tag is 1.29.4 (before 1.30, closed can be a stopped connection that nothing replaced); restarting the pod (kubectl -n istio-system delete pod istiod-a) reconnects every remote cluster."
	# A closed and a timeout: both named, with both fixes.
	export EXPECTED_MEMBERS=3
	table 3 >"${STUB_DIR}/list.body"
	metrics 1 2 1.29.4
	sync c1 closed
	sync c2 timeout
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "not synced: c1 (closed), c2 (timeout). closed counts as synced only on Istio 1.30 and later, and this replica's istio_build tag is 1.29.4"
	assert_output --partial "reconnects every remote cluster. This member's istiod must reach each member's API server"
	# synced still counts on 1.29.
	export EXPECTED_MEMBERS=2
	table 2 >"${STUB_DIR}/list.body"
	metrics 1 1 1.29.4
	sync c1 synced
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
}

@test "mesh-wiring gate: closed with a missing or unparsable istio_build tag is not synced" {
	metrics 1 1 none
	sync c1 closed
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "not synced: c1 (closed). closed counts as synced only on Istio 1.30 and later, and this replica's istio_build tag is missing (before 1.30,"
	local tag
	for tag in custom-build v1.30.5 1 ""; do
		metrics 1 1 "$tag"
		sync c1 closed
		run sh "${STUB_DIR}/readiness.sh"
		assert_failure
		assert_output --partial "not synced: c1 (closed). closed counts"
	done
}

@test "mesh-wiring gate: without an expected size, every managed remote cluster must be synced" {
	export EXPECTED_MEMBERS=0
	metrics 1 2
	sync c1 synced
	sync c2 timeout
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "istiod-a (${A}) has synced 1 remote cluster(s) < 2; not synced: c2 (timeout)"
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
	assert_output --partial "NotReady: istiod pod istiod-a (${A}) exports no istiod_remote_cluster_sync_status"
	assert_output --partial "istiodCheck.requireRemoteSync=false"
	REQUIRE_REMOTE_SYNC=false run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "synced=unchecked replicas=1"
}

@test "mesh-wiring gate: without an expected size, every remote secret must be ingested" {
	export EXPECTED_MEMBERS=0
	table 3 >"${STUB_DIR}/list.body"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: istiod pod istiod-a (${A}) manages 2 clusters < 3 remote secrets present"
}

@test "mesh-wiring gate: two replicas, one synced and one timed out, is NotReady naming only the second pod" {
	endpoints "$(slice istiod-abcde IPv4 "$A istiod-a true" "$B istiod-b true")"
	synced_replica "$A"
	replica "$B"
	metrics 1 1
	sync c1 timeout
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: istiod pod istiod-b (${B}) has synced 0 remote cluster(s) < 1; not synced: c1 (timeout). This member's istiod must reach each member's API server at the URL in its remote secret"
	# A replica that does not answer at all is named the same way.
	synced_replica "$B"
	echo 28 >"${STUB_DIR}/m_${B}.rc"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: istiod pod istiod-b (${B}): metrics unreachable at http://${B}:15014/metrics (no answer within 5s)"
}

@test "mesh-wiring gate: two synced replicas are Ready with replicas=2; every failing replica is named" {
	endpoints "$(slice istiod-abcde IPv4 "$A istiod-a true" "$B istiod-b true")"
	synced_replica "$A"
	synced_replica "$B"
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output "Ready: secrets=2 istiod_managed=2 (local=1 remote=1) expected=2 ca=shared synced=1 replicas=2 root=$(fingerprint shared) eastwest=192.0.2.20"
	[ "$(grep -c '^m_' "${STUB_DIR}/requests.log")" = 2 ]
	# Both failing: one line each.
	replica "$A"
	metrics 1 1
	sync c1 syncing
	rm "${STUB_DIR}/m_${B}.body"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_line --index 0 --partial "NotReady: istiod pod istiod-a (${A}) has synced 0 remote cluster(s) < 1; not synced: c1 (syncing)."
	assert_line --index 1 "NotReady: istiod pod istiod-b (${B}): metrics unreachable at http://${B}:15014/metrics (curl: (7) Failed to connect to ${B} port 15014: Connection refused)"
}

@test "mesh-wiring gate: the Ready figures are the lowest any replica reports" {
	export EXPECTED_MEMBERS=0
	endpoints "$(slice istiod-abcde IPv4 "$A istiod-a true" "$B istiod-b true")"
	replica "$A"
	metrics 1 2
	sync c1 synced
	sync c2 synced
	synced_replica "$B"
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "istiod_managed=2 (local=1 remote=1) expected=0 ca=shared synced=1 replicas=2 "
}

@test "mesh-wiring gate: a not-ready (terminating) endpoint is skipped; one without a ready condition is read" {
	endpoints "$(slice istiod-abcde IPv4 "$A istiod-a true" "$B istiod-b false" "$C istiod-c unset")"
	synced_replica "$A"
	synced_replica "$C"
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "synced=1 replicas=2 "
	! grep -q "^m_${B} " "${STUB_DIR}/requests.log" || false
	grep -q "^m_${C} " "${STUB_DIR}/requests.log"
}

@test "mesh-wiring gate: no Ready endpoint is NotReady with the reason, never Ready" {
	endpoints "$(slice istiod-abcde IPv4)"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: the istiod Service istio-system/istiod has no Ready endpoint, so no istiod replica can be checked (kubectl -n istio-system get endpointslices -l kubernetes.io/service-name=istiod)"
	endpoints
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "has no Ready endpoint"
	endpoints "$(slice istiod-abcde IPv4 "$A istiod-a false")"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "has no Ready endpoint"
	! grep -q '^m_' "${STUB_DIR}/requests.log" || false
	# The Service is ISTIOD_SERVICE (istiodCheck.service); another name lists other slices.
	ISTIOD_SERVICE=istiod-canary run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "stub curl: unexpected URL https://kubernetes.default.svc/apis/discovery.k8s.io/v1/namespaces/istio-system/endpointslices?labelSelector=kubernetes.io%2Fservice-name%3Distiod-canary"
}

@test "mesh-wiring gate: an IPv6 endpoint is read in brackets; a pod in both slices of a dual-stack Service is read once" {
	endpoints "$(slice istiod-v6 IPv6 "$V6 istiod-a true")"
	synced_replica "$V6"
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "synced=1 replicas=1 "
	grep -qx "m_${V6//:/_} 5" "${STUB_DIR}/requests.log"
	echo 503 >"${STUB_DIR}/m_${V6//:/_}.code"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "NotReady: istiod pod istiod-a (${V6}): metrics unreachable at http://[${V6}]:15014/metrics"
	rm "${STUB_DIR}/m_${V6//:/_}.code"
	: >"${STUB_DIR}/requests.log"
	endpoints "$(slice istiod-v4 IPv4 "$A istiod-a true")" "$(slice istiod-v6 IPv6 "$V6 istiod-a true")"
	synced_replica "$A"
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "synced=1 replicas=1 "
	[ "$(grep -c '^m_' "${STUB_DIR}/requests.log")" = 1 ]
}

@test "mesh-wiring gate: an endpoint without a pod reference is named by its address" {
	endpoints "$(slice istiod-abcde IPv4 "$A - true")"
	replica "$A"
	metrics 1 1 1.29.4
	sync c1 closed
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "NotReady: istiod endpoint ${A} has synced 0 remote cluster(s) < 1"
	assert_output --partial "restarting that istiod reconnects every remote cluster."
}

@test "mesh-wiring gate: three replicas are read at once with the same budget; a slow one is named alone" {
	endpoints "$(slice istiod-abcde IPv4 "$A istiod-a true" "$B istiod-b true" "$C istiod-c true")"
	synced_replica "$A"
	synced_replica "$B"
	synced_replica "$C"
	# Each request waits until all three have started: read one after another, they time out.
	echo 3 >"${STUB_DIR}/barrier"
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "synced=1 replicas=3 "
	[ "$(grep '^m_' "${STUB_DIR}/requests.log" | sort)" = "m_${A} 5
m_${B} 5
m_${C} 5" ]
	rm "${STUB_DIR}/barrier"
	echo 28 >"${STUB_DIR}/m_${B}.rc"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: istiod pod istiod-b (${B}): metrics unreachable at http://${B}:15014/metrics (no answer within 5s)"
}

@test "mesh-wiring gate: the work directory is removed after each check; one a killed probe left is removed later" {
	mkdir "${STUB_DIR}/work/mesh-wiring-verify.old" "${STUB_DIR}/work/mesh-wiring-verify.recent" "${STUB_DIR}/work/other.old"
	touch -d '20 minutes ago' "${STUB_DIR}/work/mesh-wiring-verify.old" "${STUB_DIR}/work/other.old"
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	[ "$(ls "${STUB_DIR}/work" | sort)" = "mesh-wiring-verify.recent
other.old" ]
	chmod 0555 "${STUB_DIR}/work"
	WORK_DIR="${STUB_DIR}/work" run sh "${STUB_DIR}/readiness.sh"
	chmod 0755 "${STUB_DIR}/work"
	if [ "$(id -u)" != 0 ]; then
		assert_failure
		assert_output --partial "NotReady: cannot create a work directory in ${STUB_DIR}/work"
	fi
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
	assert_output --partial "ca=unchecked synced=1 replicas=1 root=unchecked"
	: >"${STUB_DIR}/requests.log"
	EASTWEST_CHECK_ENABLED=false CA_CHECK_ENABLED=false run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "eastwest=unchecked"
	! grep -q '^ew ' "${STUB_DIR}/requests.log" || false
}

@test "mesh-wiring gate: with the istiod check off, the line still carries the root and the east-west address" {
	: >"${STUB_DIR}/requests.log"
	ISTIOD_CHECK_ENABLED=false run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output "Ready: secrets=2 expected=2 ca=shared root=$(fingerprint shared) eastwest=192.0.2.20 (istiod check disabled)"
	! grep -q -e '^eps ' -e '^m_' "${STUB_DIR}/requests.log" || false
}

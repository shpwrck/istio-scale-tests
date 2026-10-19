#!/usr/bin/env bats
# charts/mesh-wiring-verify readiness.sh (POSIX sh + curl) against a stub curl that answers
# for the Kubernetes API and each istiod replica's /metrics, and a stub clock: Ready only with
# every remote secret, the shared root from cacerts in istio-ca-root-cert (and its
# fingerprint), an east-west gateway address, and every Ready endpoint of the istiod Service
# managing and syncing every member (closed counts only on Istio 1.30 and later); any failed
# read is NotReady, never Ready, and names the replica; the requests share one time budget
# inside the probe's timeout, and the replicas are read at once. With the members' names
# (expectedClusters, as Terraform sets them) every other member is checked by name, and a
# remote secret or remote cluster of no member (a removed member's) is NotReady, named; without
# them the gate counts, as a manual install does.

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

# secrets <member>...: a Table listing of istio-remote-secret-<member> for each; =<name> is a
# secret of that whole name.
secrets() {
	local rows="" s
	for s in "$@"; do
		if [[ "$s" == =* ]]; then s="${s#=}"; else s="istio-remote-secret-${s}"; fi
		rows+="${rows:+,}{\"cells\":[\"${s}\",\"Opaque\",1,\"5m\"],\"object\":null}"
	done
	printf '{"kind":"Table","columnDefinitions":[{"name":"Name","type":"string"}],"rows":[%s]}\n' "$rows"
}

# mesh <self> <member>...: the gate on member <self> of a mesh of these members, by name and
# count, as Terraform and the ApplicationSet set them.
mesh() {
	CLUSTER_NAME="$1"
	shift
	EXPECTED_CLUSTERS="$(IFS=,; echo "$*")"
	EXPECTED_MEMBERS="$#"
	export CLUSTER_NAME EXPECTED_CLUSTERS EXPECTED_MEMBERS
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
	unset CHECK_TIMEOUT CURL_TIMEOUT REQUIRE_REMOTE_SYNC EASTWEST_CHECK_ENABLED CA_CHECK_ENABLED ISTIOD_SERVICE ISTIOD_PORT \
		EXPECTED_CLUSTERS CLUSTER_NAME
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
	assert_output "Ready: secrets=2 istiod_managed=2 (local=1 remote=1) expected=2 members=unchecked ca=shared synced=1 replicas=1 root=$(fingerprint shared) eastwest=192.0.2.20"
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
	for tag in 1.30.5 1.30 1.30.0-beta.1 1.31-dev 1.100.0; do
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
	assert_output "Ready: secrets=2 istiod_managed=2 (local=1 remote=1) expected=2 members=unchecked ca=shared synced=1 replicas=2 root=$(fingerprint shared) eastwest=192.0.2.20"
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
	assert_output --partial "istiod_managed=2 (local=1 remote=1) expected=0 members=unchecked ca=shared synced=1 replicas=2 "
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
	assert_output "Ready: secrets=2 expected=2 members=unchecked ca=shared root=$(fingerprint shared) eastwest=192.0.2.20 (istiod check disabled)"
	! grep -q -e '^eps ' -e '^m_' "${STUB_DIR}/requests.log" || false
}

# --- By name (expectedClusters, as Terraform sets them; mesh-a is this member) ---

@test "mesh-wiring gate by name: Ready with every other member's secret and sync; members= lists the names" {
	mesh mesh-a mesh-a mesh-b mesh-c
	secrets mesh-a mesh-b mesh-c >"${STUB_DIR}/list.body"
	metrics 1 2
	sync mesh-b synced
	sync mesh-c closed
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output "Ready: secrets=3 istiod_managed=3 (local=1 remote=2) expected=3 members=mesh-a,mesh-b,mesh-c ca=shared synced=2 replicas=1 root=$(fingerprint shared) eastwest=192.0.2.20"
	# expectedMembers 0 takes the names' count; this member's own secret is not needed.
	EXPECTED_MEMBERS=0
	secrets mesh-b mesh-c >"${STUB_DIR}/list.body"
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "Ready: secrets=2 istiod_managed=3 (local=1 remote=2) expected=3 members=mesh-a,mesh-b,mesh-c ca=shared synced=2 "
	ISTIOD_CHECK_ENABLED=false run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output "Ready: secrets=2 expected=3 members=mesh-a,mesh-b,mesh-c ca=shared root=$(fingerprint shared) eastwest=192.0.2.20 (istiod check disabled)"
}

@test "mesh-wiring gate by name: a stale synced secret cannot stand in for a member that timed out" {
	# A member that left (mesh-d) keeps its secret here, and istiod its cluster, still synced.
	mesh mesh-a mesh-a mesh-b mesh-c
	secrets mesh-a mesh-b mesh-c mesh-d >"${STUB_DIR}/list.body"
	metrics 1 3
	sync mesh-b synced
	sync mesh-c timeout
	sync mesh-d synced
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_line --index 0 "NotReady: remote secret(s) of no mesh member (not in expectedClusters): istio-remote-secret-mesh-d. istiod keeps the cluster in each, and its last sync state, until the secret is deleted, and External Secrets leaves a removed member's behind; if that cluster left the mesh, delete them on this member: kubectl -n istio-system delete secret istio-remote-secret-mesh-d"
	assert_line --index 1 "NotReady: istiod pod istiod-a (${A}) has not synced mesh member(s) mesh-c (timeout). This member's istiod must reach each member's API server at the URL in its remote secret"
	# Stage 1 named the stale cluster: stage 2 does not name it again.
	[ "${#lines[@]}" -eq 2 ]
	# By count (no names), the stale cluster takes mesh-c's place: Ready.
	unset EXPECTED_CLUSTERS CLUSTER_NAME
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "expected=3 members=unchecked ca=shared synced=2 "
}

@test "mesh-wiring gate by name: a member swap (mesh-d out, mesh-c in) whose new member's secret never arrived" {
	mesh mesh-a mesh-a mesh-b mesh-c
	secrets mesh-a mesh-b mesh-d >"${STUB_DIR}/list.body"
	metrics 1 2
	sync mesh-b synced
	sync mesh-d synced
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_line --index 0 "NotReady: no remote secret here for mesh member(s) mesh-c (istio-system has no istio-remote-secret-mesh-c): External Secrets on the hub has not pushed it here; on the hub, kubectl -n external-secrets-operator describe pushsecret push-remote-secret-mesh-c shows the stores each one reached and its last error"
	assert_line --index 1 --partial "NotReady: remote secret(s) of no mesh member (not in expectedClusters): istio-remote-secret-mesh-d. "
	assert_line --index 1 --partial "if that cluster left the mesh, delete them on this member: kubectl -n istio-system delete secret istio-remote-secret-mesh-d"
	# mesh-c's missing secret is named once, not again as a cluster istiod lacks.
	[ "${#lines[@]}" -eq 2 ]
	# The count sees three secrets and two synced remote clusters: Ready.
	unset EXPECTED_CLUSTERS CLUSTER_NAME
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "Ready: secrets=3 istiod_managed=3 (local=1 remote=2) expected=3 members=unchecked "
}

@test "mesh-wiring gate by name: the stale secret of a dead cluster is NotReady with its delete command" {
	mesh mesh-a mesh-a mesh-b mesh-c
	secrets mesh-a mesh-b mesh-c mesh-d =istio-remote-secret-old >"${STUB_DIR}/list.body"
	metrics 1 4
	sync mesh-b synced
	sync mesh-c synced
	sync mesh-d timeout
	sync old syncing
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: remote secret(s) of no mesh member (not in expectedClusters): istio-remote-secret-mesh-d, istio-remote-secret-old. istiod keeps the cluster in each, and its last sync state, until the secret is deleted, and External Secrets leaves a removed member's behind; if that cluster left the mesh, delete them on this member: kubectl -n istio-system delete secret istio-remote-secret-mesh-d istio-remote-secret-old"
	# The istiod check off: still NotReady.
	ISTIOD_CHECK_ENABLED=false run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "istio-remote-secret-mesh-d, istio-remote-secret-old."
	refute_line --regexp "^Ready: "
	# By count: three members synced, so the dead one passes unseen.
	unset EXPECTED_CLUSTERS CLUSTER_NAME
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
}

@test "mesh-wiring gate by name: a labelled secret of another name and a cluster no member holds are named" {
	mesh mesh-a mesh-a mesh-b
	secrets mesh-a mesh-b =manual-remote >"${STUB_DIR}/list.body"
	metrics 1 2
	sync mesh-b synced
	sync legacy synced
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_line --index 0 --partial "NotReady: remote secret(s) of no mesh member (not in expectedClusters): manual-remote. "
	# Its cluster's name is not the secret's suffix, so stage 2 names it too.
	assert_line --index 1 "NotReady: istiod pod istiod-a (${A}) manages remote cluster(s) of no mesh member (not in expectedClusters): legacy (synced). istiod keeps a cluster until the remote secret that holds it is deleted: kubectl -n istio-system get secrets -l istio/multiCluster=true -o json | jq -r '.items[] | .metadata.name + \": \" + (.data // {} | keys | join(\",\"))' lists each remote secret's clusters; if that cluster left the mesh, delete its secret (or only that key, in a member's secret)"
	# A member's own secret that holds another cluster too: only stage 2 sees that cluster.
	secrets mesh-a mesh-b >"${STUB_DIR}/list.body"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "manages remote cluster(s) of no mesh member (not in expectedClusters): legacy (synced)."
	[ "${#lines[@]}" -eq 1 ]
	# The command it prints lists each remote secret's clusters (its data keys, never values).
	command -v jq >/dev/null || return 0
	local prog
	prog="$(sed -n "s/.* | jq -r '\([^']*\)' lists .*/\1/p" <<<"$output")"
	[ -n "$prog" ]
	run jq -r "$prog" <<<'{"items":[{"metadata":{"name":"istio-remote-secret-mesh-b"},"data":{"mesh-b":"a2M=","legacy":"a2M="}},{"metadata":{"name":"empty"}}]}'
	assert_success
	assert_output "istio-remote-secret-mesh-b: legacy,mesh-b
empty: "
}

@test "mesh-wiring gate by name: a member add and a removal, as each other member's gate sees them" {
	# Add mesh-c: the gate restarts with the new list before mesh-c's secret arrives.
	mesh mesh-a mesh-a mesh-b mesh-c
	secrets mesh-a mesh-b >"${STUB_DIR}/list.body"
	metrics 1 1
	sync mesh-b synced
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "NotReady: no remote secret here for mesh member(s) mesh-c (istio-system has no istio-remote-secret-mesh-c): "
	refute_output --partial "not managed"
	# Pushed: istiod connects.
	secrets mesh-a mesh-b mesh-c >"${STUB_DIR}/list.body"
	metrics 1 2
	sync mesh-b synced
	sync mesh-c syncing
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "has not synced mesh member(s) mesh-c (syncing). This member's istiod must reach"
	sync mesh-c synced
	metrics 1 2
	sync mesh-b synced
	sync mesh-c synced
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "members=mesh-a,mesh-b,mesh-c ca=shared synced=2 "
	# Two members added at once and neither pushed yet: both secrets and both PushSecrets named.
	mesh mesh-a mesh-a mesh-b mesh-c mesh-d mesh-e
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "for mesh member(s) mesh-d, mesh-e (istio-system has no istio-remote-secret-mesh-d, istio-remote-secret-mesh-e): External Secrets on the hub has not pushed it here; on the hub, kubectl -n external-secrets-operator describe pushsecret push-remote-secret-mesh-d push-remote-secret-mesh-e shows"
	# Remove mesh-b: its secret stays, and istiod keeps it synced, until it is deleted here.
	mesh mesh-a mesh-a mesh-c
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "(not in expectedClusters): istio-remote-secret-mesh-b. "
	assert_output --partial "kubectl -n istio-system delete secret istio-remote-secret-mesh-b"
	secrets mesh-a mesh-c >"${STUB_DIR}/list.body"
	metrics 1 1
	sync mesh-c synced
	run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "secrets=2 istiod_managed=2 (local=1 remote=1) expected=2 members=mesh-a,mesh-c "
}

@test "mesh-wiring gate: a missing member's PushSecret is named as charts/hub-mesh-push-secrets names it" {
	command -v helm >/dev/null || skip "helm not installed"
	# Cut at 63, the name ends in "-", which the chart trims.
	local long=mesh-member-with-a-long-name-0123456789-abc-xyz want
	want="$(helm template x "${ROOT}/charts/hub-mesh-push-secrets" --set clusterName="$long" --show-only templates/06-pushsecret-remote-secret.yaml |
		sed -n 's/^  name: "\(push-remote-secret-.*\)"$/\1/p')"
	[ "$want" = push-remote-secret-mesh-member-with-a-long-name-0123456789-abc ]
	mesh mesh-a mesh-a mesh-b "$long"
	secrets mesh-a >"${STUB_DIR}/list.body"
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "describe pushsecret push-remote-secret-mesh-b ${want} shows"
}

@test "mesh-wiring gate by name: a member whose secret istiod has not loaded reads not managed, with its log command" {
	mesh mesh-a mesh-a mesh-b mesh-c
	secrets mesh-a mesh-b mesh-c >"${STUB_DIR}/list.body"
	metrics 1 1
	sync mesh-b synced
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: istiod pod istiod-a (${A}) has not synced mesh member(s) mesh-c (not managed). not managed: the member's remote secret is here, but istiod holds no cluster of that name from it (a kubeconfig it cannot use, another data key, or a cluster ID another secret already holds; kubectl -n istio-system logs istiod-a | grep <member>)."
	# No remote cluster at all: no sync series to export, and every other member is not managed.
	metrics 1 0
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "has not synced mesh member(s) mesh-b (not managed), mesh-c (not managed)."
	refute_output --partial "exports no istiod_remote_cluster_sync_status"
}

@test "mesh-wiring gate by name: an istiod that manages this member's own name as a remote cluster is NotReady" {
	mesh mesh-a mesh-a mesh-b
	secrets mesh-a mesh-b >"${STUB_DIR}/list.body"
	metrics 1 2
	sync mesh-b synced
	sync mesh-a synced
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: istiod pod istiod-a (${A}) manages this member's own name as a remote cluster: mesh-a (synced). So its cluster ID is not mesh-a: clusterName must be the Istio cluster ID of this member (the Istio CR's spec.values.global.multiCluster.clusterName), whose own remote secret istiod then skips"
}

@test "mesh-wiring gate by name: two replicas, one has not synced a member: only that pod is named, with each state" {
	mesh mesh-a mesh-a mesh-b mesh-c
	secrets mesh-a mesh-b mesh-c >"${STUB_DIR}/list.body"
	endpoints "$(slice istiod-abcde IPv4 "$A istiod-a true" "$B istiod-b true")"
	replica "$A"
	metrics 1 2
	sync mesh-b synced
	sync mesh-c synced
	replica "$B"
	metrics 1 2 1.29.4
	sync mesh-b closed
	sync mesh-c syncing
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: istiod pod istiod-b (${B}) has not synced mesh member(s) mesh-b (closed), mesh-c (syncing). closed counts as synced only on Istio 1.30 and later, and this replica's istio_build tag is 1.29.4 (before 1.30, closed can be a stopped connection that nothing replaced); restarting the pod (kubectl -n istio-system delete pod istiod-b) reconnects every remote cluster. This member's istiod must reach each member's API server at the URL in its remote secret"
}

@test "mesh-wiring gate by name: bad names, a count that disagrees, no clusterName or a member not listed is NotReady" {
	EXPECTED_MEMBERS=0 CLUSTER_NAME=mesh-a EXPECTED_CLUSTERS='mesh-a,Mesh_B' run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: expectedClusters (mesh-a,Mesh_B) and clusterName (mesh-a) take only cluster names: lowercase letters, digits, '-' and '.', the list comma-separated"
	EXPECTED_MEMBERS=0 CLUSTER_NAME='mesh-*' EXPECTED_CLUSTERS='mesh-a,mesh-b' run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "take only cluster names"
	EXPECTED_MEMBERS=0 CLUSTER_NAME=mesh-a EXPECTED_CLUSTERS='mesh-a,,mesh-b' run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: expectedClusters (mesh-a,,mesh-b) holds an empty name"
	EXPECTED_MEMBERS=0 CLUSTER_NAME=mesh-a EXPECTED_CLUSTERS='mesh-a,mesh-b,mesh-a' run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: expectedClusters names mesh-a more than once (mesh-a,mesh-b,mesh-a)"
	EXPECTED_MEMBERS=3 CLUSTER_NAME=mesh-a EXPECTED_CLUSTERS='mesh-a,mesh-b' run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: expectedMembers is 3 but expectedClusters names 2 member(s) (mesh-a,mesh-b): set both from the same members, or expectedMembers to 0"
	EXPECTED_MEMBERS=2 CLUSTER_NAME= EXPECTED_CLUSTERS='mesh-a,mesh-b' run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: expectedClusters is set but clusterName is empty, so the gate cannot tell which member it runs on (the ApplicationSet sets it per member)"
	EXPECTED_MEMBERS=2 CLUSTER_NAME=mesh-z EXPECTED_CLUSTERS='mesh-a,mesh-b' run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: this member (mesh-z) is not in expectedClusters (mesh-a,mesh-b); a member the apply just added waits for the gate ApplicationSet's new list"
	# None of these asked the API anything.
	[ ! -s "${STUB_DIR}/requests.log" ]
}

@test "mesh-wiring gate by name: with requireRemoteSync off, the secrets are checked by name and istiod by count" {
	mesh mesh-a mesh-a mesh-b mesh-c
	secrets mesh-a mesh-b mesh-c >"${STUB_DIR}/list.body"
	metrics 1 1
	REQUIRE_REMOTE_SYNC=false run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output "NotReady: istiod pod istiod-a (${A}) manages 2 clusters (local=1 remote=1) < expected 3"
	secrets mesh-a mesh-b mesh-c mesh-d >"${STUB_DIR}/list.body"
	metrics 1 3
	REQUIRE_REMOTE_SYNC=false run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "NotReady: remote secret(s) of no mesh member (not in expectedClusters): istio-remote-secret-mesh-d."
	secrets mesh-a mesh-b mesh-c >"${STUB_DIR}/list.body"
	metrics 1 2
	REQUIRE_REMOTE_SYNC=false run sh "${STUB_DIR}/readiness.sh"
	assert_success
	assert_output --partial "expected=3 members=mesh-a,mesh-b,mesh-c ca=shared synced=unchecked "
}

@test "mesh-wiring gate: closed with a tag that does not read 1.<minor> (OSSM's is unverified) fails closed, advising a restart" {
	local tag
	# A build name, or a product's own version (OSSM 3.4), never reads as Istio 1.30 or later.
	for tag in unknown OSSM_3.4.0 servicemesh-3.4 3e7b1c2 release-1.30 3.4.0 2.0.0; do
		metrics 1 1 "$tag"
		sync c1 closed
		run sh "${STUB_DIR}/readiness.sh"
		assert_failure
		assert_output "NotReady: istiod pod istiod-a (${A}) has synced 0 remote cluster(s) < 1; not synced: c1 (closed). closed counts as synced only on Istio 1.30 and later, and this replica's istio_build tag is ${tag}, which does not read as 1.<minor> (before 1.30, closed can be a stopped connection that nothing replaced); restarting the pod (kubectl -n istio-system delete pod istiod-a) reconnects every remote cluster."
	done
	# By name too.
	mesh mesh-a mesh-a mesh-b
	secrets mesh-a mesh-b >"${STUB_DIR}/list.body"
	metrics 1 1 OSSM_3.4.0
	sync mesh-b closed
	run sh "${STUB_DIR}/readiness.sh"
	assert_failure
	assert_output --partial "has not synced mesh member(s) mesh-b (closed). closed counts as synced only on Istio 1.30 and later, and this replica's istio_build tag is OSSM_3.4.0, which does not read as 1.<minor> (before 1.30,"
	assert_output --partial "restarting the pod (kubectl -n istio-system delete pod istiod-a) reconnects every remote cluster."
}

@test "mesh-wiring gate: the chart passes the names and this member's own; bad names or a count that disagrees fail the render" {
	command -v helm >/dev/null || skip "helm not installed"
	run helm template x "$CHART" --set clusterName=mesh-a --set 'expectedClusters={mesh-a,mesh-b}' --set expectedMembers=2 --show-only templates/deployment.yaml
	assert_success
	grep -A1 'name: EXPECTED_CLUSTERS' <<<"$output" | grep -q 'value: "mesh-a,mesh-b"'
	grep -A1 'name: CLUSTER_NAME' <<<"$output" | grep -q 'value: "mesh-a"'
	# One comma-separated string works too; expectedMembers as Terraform's string.
	run helm template x "$CHART" --set clusterName=mesh-a --set-string 'expectedClusters=mesh-a\,mesh-b' --set-string expectedMembers=2 --show-only templates/deployment.yaml
	assert_success
	grep -A1 'name: EXPECTED_CLUSTERS' <<<"$output" | grep -q 'value: "mesh-a,mesh-b"'
	# Without names: by count.
	run helm template x "$CHART" --set expectedMembers=2 --show-only templates/deployment.yaml
	assert_success
	grep -A1 'name: EXPECTED_CLUSTERS' <<<"$output" | grep -q 'value: ""'
	run helm template x "$CHART" --set clusterName=mesh-a --set 'expectedClusters={mesh-a,mesh-b}' --set expectedMembers=3
	assert_failure
	assert_output --partial "expectedMembers is 3 but expectedClusters names 2 member(s) (mesh-a,mesh-b)"
	run helm template x "$CHART" --set 'expectedClusters={mesh-a,mesh-b}'
	assert_failure
	assert_output --partial 'clusterName "" is not a cluster name: with expectedClusters set it to this member'
	run helm template x "$CHART" --set clusterName=mesh-a --set 'expectedClusters={mesh-a,Mesh_B}'
	assert_failure
	assert_output --partial 'expectedClusters: "Mesh_B" is not a cluster name'
	run helm template x "$CHART" --set clusterName=mesh-a --set 'expectedClusters={mesh-a,mesh-b,mesh-a}'
	assert_failure
	assert_output --partial "expectedClusters names a member more than once: mesh-a,mesh-b,mesh-a"
}

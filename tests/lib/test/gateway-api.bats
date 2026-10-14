#!/usr/bin/env bats
# tests/gateway-api/001-run-ingress-check.sh (Gateway API multicluster ingress check) through
# its real entrypoint (PL33): flags and --help, the dry run, the chart <-> prediction-table
# contract (scenario set and render pin included), and whole runs against stub
# kubectl/curl/istioctl: the Service answers (M1/F2: only a route in place for the whole traffic
# window counts; M2: the Service read directly; F1: only the code of a dropped destination is a
# failure, with an empty body, repeated by the re-probe (G1), S7's too, on a RefNotPermitted route,
# against C1's empty 500; F3: the scenario must work through the workload member; S7b
# contradicting S2; late endpoints answered for a NO), the
# namespace answers (S7-S9, S7b) and their invalid-precondition rows, the not-deployed and
# unreachable-member stops (U1, with one retry), the data-plane gate (SC1: S1 and S3, rounds in a
# row) and the re-probe of late endpoints, builds and restarts (R1, PL9, unverified ones too), the
# scenario set (R2, unreadable too), STATUS_TIMEOUT (PL23), an unreachable ingress, best-effort
# steps that fail without killing the run (PL40), one preamble key set for every output (PL19,
# PL36), and no address in any output.
# Stub addresses are documentation addresses (192.0.2.0/24); the stub registry is example.invalid.

bats_require_minimum_version 1.5.0
load test_helper

GW="${ROOT}/tests/gateway-api/001-run-ingress-check.sh"
CHART="${ROOT}/charts/mesh-verify-gateway-api"

# The chart render that the script's SCENARIO_SET describes (R2): "<set> <sha256 of render_sha>".
# Any change to what the chart renders fails "the chart render is pinned to the scenario set"
# until the set is bumped: SCENARIO_SET in 001-run-ingress-check.sh, the scenarioSet define in
# templates/_helpers.tpl and Chart.yaml's version (v<N> = 0.<N>.0) together, then this pin, to the
# new set and the sha256 that test prints. A new render always needs a new set: never update the
# sha256 alone. Only "# Source:" lines are dropped. The render is helm 4 output (CI pins v4.2.2),
# RENDER_PIN_HELM_MAJOR: with another helm major version (AGENTS.md allows helm 3 or 4) the hash
# is not compared (the test is skipped with a message); never re-pin from another major.
RENDER_PIN="v3 ef2331e33be99cb2bbbe8383a92bc73a21e78f1786fac0b6833c586e29b1a1e8"
RENDER_PIN_HELM_MAJOR=4

setup() {
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: >"$EK"
	BIN="${BATS_TEST_TMPDIR}/bin"
	OUT="${BATS_TEST_TMPDIR}/results"
	mkdir -p "$BIN"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log" STUB_CURL_LOG="${BATS_TEST_TMPDIR}/curl.log"
	: >"$STUB_LOG"
	: >"$STUB_CURL_LOG"
	# The scenario set the script expects; the stub chart stamps it unless told otherwise.
	STUB_SCENARIO_SET="$(sed -n 's/^SCENARIO_SET=//p' "$GW")"
	export STUB_SCENARIO_SET

	# kubectl: ctx-a has no workload, ctx-b runs it (echo text member-b) and alone has the S7-S9
	# backend namespace; both have the S7b namespace and its ReferenceGrant; hub is the ACM hub; any
	# other context does not exist. STUB_NO_NS=<ctx>: the test namespace is missing there.
	# STUB_NO_REMOTE_NS=1 / STUB_NO_SHARED_NS=1: that backend namespace is missing on ctx-b.
	# STUB_REMOTE_NS_A=present|fail: ctx-a has the S7-S9 namespace too, or its read fails.
	# STUB_SHARED_A=absent|nogrant: ctx-a lacks the S7b namespace, or its ReferenceGrant.
	# STUB_SVC_A=<csv>: more Services in ctx-a's test namespace; STUB_NO_S3_STUB=1: no echo-s3 there.
	# STUB_NOSTATUS=<route>: that route has no status on ctx-a; STUB_NOSTATUS_ONCE=<route>: only in
	# ctx-a's first route read (the wait's); STUB_ROUTES_FAIL_ONCE=1: that read fails.
	# STUB_S7_REFS_A="<status> <reason>": S7's ResolvedRefs on ctx-a (default False RefNotPermitted).
	# STUB_NO_ECHO_TEXT=1: the echo Deployment has no -text argument (curl's 200s have no body).
	# STUB_SET_A/STUB_SET_B: the scenario set stamped on
	# ctx-a/ctx-b (STUB_SET_A=fail: ctx-a's test namespace read fails). STUB_RESTART=istiod: ctx-a's
	# istiod pod is new at the final read; =unknown: that read fails. STUB_FLAKY_A=<n>: ctx-a's
	# first n reads time out. STUB_HUB_FAIL=1: hub reads fail; STUB_REVISION: the revision the hub's
	# Applications synced. Anything else fails.
	cat >"${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
ctx="" args=()
for a in "$@"; do
	case "$a" in
	--context=*) ctx="${a#--context=}" ;;
	--request-timeout=*) ;;
	*) args+=("$a") ;;
	esac
done
cmd="${args[*]}"
case "$ctx" in
ctx-a | ctx-b | hub) ;;
*) echo "error: context \"${ctx}\" does not exist" >&2; exit 1 ;;
esac
if [[ "$ctx" == ctx-a && -n "${STUB_FLAKY_A:-}" ]]; then
	n="$(cat "${STUB_LOG}.flaky" 2>/dev/null || echo 0)"
	echo $((n + 1)) >"${STUB_LOG}.flaky"
	((n >= STUB_FLAKY_A)) || { echo "Unable to connect to the server: dial tcp 192.0.2.62:6443: i/o timeout" >&2; exit 1; }
fi
nf() { echo "Error from server (NotFound): $1 not found" >&2; exit 1; }
route() {
	if [[ "$1" == "${STUB_NOSTATUS_ONCE:-}" && "$ctx" == ctx-a && ! -f "${STUB_LOG}.once" ]]; then
		printf '{"metadata":{"name":"%s","generation":1},"status":{}}' "$1"
		return
	fi
	if [[ "$1" == "${STUB_NOSTATUS:-}" && "$ctx" == ctx-a ]]; then
		printf '{"metadata":{"name":"%s","generation":1},"status":{}}' "$1"
		return
	fi
	printf '{"metadata":{"name":"%s","generation":1},"status":{"parents":[{"controllerName":"istio.io/gateway-controller","parentRef":{"name":"mesh-verify-gwapi"},"conditions":[{"type":"Accepted","status":"True","reason":"Accepted","observedGeneration":1},{"type":"ResolvedRefs","status":"%s","reason":"%s","observedGeneration":1}]}]}}' "$1" "$2" "$3"
}
set_of() {
	if [[ "$ctx" == ctx-a && "${STUB_SET_A:-}" != fail ]]; then echo "${STUB_SET_A:-$STUB_SCENARIO_SET}"
	elif [[ "$ctx" == ctx-b ]]; then echo "${STUB_SET_B:-$STUB_SCENARIO_SET}"
	else echo "$STUB_SCENARIO_SET"; fi
}
# names <csv>: a list whose items have these names.
names() {
	local n out="" IFS=,
	for n in $1; do [[ -z "$n" ]] || out="${out:+${out},}{\"metadata\":{\"name\":\"${n}\"}}"; done
	printf '{"items":[%s]}\n' "$out"
}
# pods <name prefix> <container> <image> <count> <start>: Running pods of one container.
pods() {
	local i out="" digest
	digest="sha256:$(printf '%064d' 7)"
	for ((i = 1; i <= $4; i++)); do
		out="${out:+${out},}{\"metadata\":{\"name\":\"$1-p${i}\"},\"spec\":{\"containers\":[{\"name\":\"$2\",\"image\":\"$3\"}]},\"status\":{\"phase\":\"Running\",\"startTime\":\"$5\",\"containerStatuses\":[{\"name\":\"$2\",\"imageID\":\"${3%:*}@${digest}\",\"restartCount\":0}]}}"
	done
	printf '{"items":[%s]}\n' "$out"
}
LABELS='"labels":{"istio-discovery":"enabled","istio.io/rev":"default"}'
if [[ "$ctx" == hub ]]; then
	[[ -z "${STUB_HUB_FAIL:-}" ]] || { echo "Unable to connect to the server: dial tcp 192.0.2.50:6443: i/o timeout" >&2; exit 1; }
	case "$cmd" in
	"-n openshift-gitops get applicationsets.argoproj.io mesh-verify-gwapi -o json")
		echo '{"spec":{"template":{"spec":{"source":{"helm":{"valuesObject":{"workloadCluster":"member-b"}}}}}}}' ;;
	"-n openshift-gitops get applications.argoproj.io -o json")
		rev="${STUB_REVISION:-0123456789abcdef0123}"
		echo '{"items":[
			{"metadata":{"name":"member-a-mesh-verify-gwapi","ownerReferences":[{"kind":"ApplicationSet","name":"mesh-verify-gwapi"}]},"spec":{"destination":{"name":"member-a"}},
			 "status":{"health":{"status":"Degraded"},"sync":{"status":"Synced","revision":"'"$rev"'"},"resources":[{"kind":"HTTPRoute","name":"s2","health":{"status":"Degraded"}},{"kind":"HTTPRoute","name":"s3","health":{"status":"Healthy"}}]}},
			{"metadata":{"name":"member-b-mesh-verify-gwapi","ownerReferences":[{"kind":"ApplicationSet","name":"mesh-verify-gwapi"}]},"spec":{"destination":{"name":"member-b"}},
			 "status":{"health":{"status":"Healthy"},"sync":{"status":"Synced","revision":"'"$rev"'"}}},
			{"metadata":{"name":"unrelated"},"spec":{"destination":{"name":"member-a"}},"status":{}}]}' ;;
	*) echo "error: stub: unexpected hub call: $cmd" >&2; exit 1 ;;
	esac
	exit 0
fi
case "$cmd" in
"version --output=json") echo '{"serverVersion":{"gitVersion":"v1.33.4"}}' ;;
"get crd httproutes.gateway.networking.k8s.io -o json")
	echo '{"metadata":{"annotations":{"gateway.networking.k8s.io/bundle-version":"v1.3.0","gateway.networking.k8s.io/channel":"standard"}}}' ;;
"get gatewayclasses.gateway.networking.k8s.io istio -o json")
	echo '{"spec":{"controllerName":"istio.io/gateway-controller"},"status":{"conditions":[{"type":"Accepted","status":"True"}]}}' ;;
"get namespace mesh-verify-gwapi -o json")
	[[ "${STUB_NO_NS:-}" != "$ctx" ]] || nf 'namespaces "mesh-verify-gwapi"'
	if [[ "$ctx" == ctx-a && "${STUB_SET_A:-}" == fail ]]; then
		echo "Unable to connect to the server: dial tcp 192.0.2.61:6443: i/o timeout" >&2
		exit 1
	fi
	printf '{"metadata":{"annotations":{"mesh-verify-gwapi/scenario-set":"%s"},%s}}\n' "$(set_of)" "$LABELS" ;;
"get namespace mesh-verify-gwapi-remote -o json")
	if [[ "$ctx" == ctx-a && "${STUB_REMOTE_NS_A:-}" == fail ]]; then
		echo "Unable to connect to the server: dial tcp 192.0.2.60:6443: i/o timeout" >&2
		exit 1
	fi
	if [[ "$ctx" == ctx-b && -z "${STUB_NO_REMOTE_NS:-}" ]] || [[ "$ctx" == ctx-a && "${STUB_REMOTE_NS_A:-}" == present ]]; then
		echo "{\"metadata\":{${LABELS}}}"
	else
		nf 'namespaces "mesh-verify-gwapi-remote"'
	fi ;;
"get namespace mesh-verify-gwapi-shared -o json")
	if [[ "$ctx" == ctx-a && "${STUB_SHARED_A:-}" == absent ]] || [[ "$ctx" == ctx-b && -n "${STUB_NO_SHARED_NS:-}" ]]; then
		nf 'namespaces "mesh-verify-gwapi-shared"'
	fi
	echo "{\"metadata\":{${LABELS}}}" ;;
"-n mesh-verify-gwapi-shared get referencegrants.gateway.networking.k8s.io -o json")
	if [[ "$ctx" == ctx-a && -n "${STUB_SHARED_A:-}" ]]; then names ""; else names s7b; fi ;;
"-n mesh-verify-gwapi get svc -o json")
	if [[ "$ctx" == ctx-b ]]; then
		names echo-s1,echo-s2,echo-s3,echo-s4,echo-s5
	else
		names "$([[ -n "${STUB_NO_S3_STUB:-}" ]] || echo echo-s3),${STUB_SVC_A:-}"
	fi ;;
"-n mesh-verify-gwapi-shared get svc -o json")
	if [[ "$ctx" == ctx-b ]]; then names echo-s7b; else names ""; fi ;;
"-n istio-system get gateways.gateway.networking.k8s.io mesh-verify-gwapi -o json")
	printf '{"metadata":{"generation":1,"annotations":{"mesh-verify-gwapi/scenario-set":"%s"}},"status":{"conditions":[{"type":"Programmed","status":"True","reason":"Programmed","observedGeneration":1}]}}\n' "$(set_of)" ;;
"-n istio-system get deploy -l app=istiod -o json")
	echo '{"items":[{"spec":{"template":{"spec":{"containers":[{"name":"discovery","env":[{"name":"PILOT_ENABLE_GATEWAY_API","value":"true"}]}]}}}}]}' ;;
"-n istio-system get pods -l app=istiod -o json")
	n="$(cat "${STUB_LOG}.istiod-${ctx}" 2>/dev/null || echo 0)"
	echo $((n + 1)) >"${STUB_LOG}.istiod-${ctx}"
	start=2026-10-14T08:00:00Z
	[[ "${STUB_RESTART:-}" != istiod || "$ctx" != ctx-a || "$n" -lt 1 ]] || start=2026-10-14T09:00:00Z
	if [[ "${STUB_RESTART:-}" == unknown && "$ctx" == ctx-a && "$n" -ge 1 ]]; then
		echo "Unable to connect to the server: dial tcp 192.0.2.63:6443: i/o timeout" >&2
		exit 1
	fi
	pods istiod-6c9d8f discovery registry.example.invalid/openshift-service-mesh/istio-pilot-rhel9:1.30.5 1 "$start" ;;
"-n istio-system get pods -l istio=ingressgateway -o json")
	pods istio-ingressgateway-5d8f7 istio-proxy registry.example.invalid/openshift-service-mesh/istio-proxyv2-rhel9:1.30.5 2 2026-10-14T08:00:00Z ;;
"-n openshift-operators get clusterserviceversions.operators.coreos.com -o json")
	echo '{"items":[{"metadata":{"name":"servicemeshoperator3.v3.4.3"},"spec":{"version":"3.4.3"},"status":{"phase":"Succeeded"}},{"metadata":{"name":"other-operator.v1.0.0"},"spec":{"version":"1.0.0"},"status":{"phase":"Succeeded"}}]}' ;;
"get istios.sailoperator.io default -o json") echo '{"spec":{"version":"v1.30.5"}}' ;;
"-n mesh-verify-gwapi get deploy -l app=gwapi-echo -o json" | "-n mesh-verify-gwapi-remote get deploy -l app=gwapi-echo -o json" | \
	"-n mesh-verify-gwapi-shared get deploy -l app=gwapi-echo -o json")
	if [[ "$ctx" == ctx-b && ( "$cmd" != *-remote* || -z "${STUB_NO_REMOTE_NS:-}" ) && ( "$cmd" != *-shared* || -z "${STUB_NO_SHARED_NS:-}" ) ]]; then
		text='"-text=member-b"'
		[[ -z "${STUB_NO_ECHO_TEXT:-}" ]] || text='"-status-code=200"'
		echo '{"items":[{"spec":{"replicas":1,"template":{"spec":{"containers":[{"name":"http-echo","args":["-listen=:8080",'"$text"']}]}}},"status":{"readyReplicas":1}}]}'
	else
		echo '{"items":[]}'
	fi ;;
"-n mesh-verify-gwapi get pods -l app=gwapi-echo -o json" | "-n mesh-verify-gwapi-remote get pods -l app=gwapi-echo -o json" | \
	"-n mesh-verify-gwapi-shared get pods -l app=gwapi-echo -o json")
	if [[ "$ctx" == ctx-b && ( "$cmd" != *-remote* || -z "${STUB_NO_REMOTE_NS:-}" ) && ( "$cmd" != *-shared* || -z "${STUB_NO_SHARED_NS:-}" ) ]]; then
		echo '{"items":[{"spec":{"containers":[{"name":"http-echo"}],"initContainers":[{"name":"istio-proxy"}]}}]}'
	else
		echo '{"items":[]}'
	fi ;;
"-n istio-system get svc istio-ingressgateway -o json")
	if [[ "$ctx" == ctx-b ]]; then ip=192.0.2.2; else ip=192.0.2.1; fi
	echo "{\"status\":{\"loadBalancer\":{\"ingress\":[{\"ip\":\"${ip}\"}]}}}" ;;
"-n mesh-verify-gwapi get httproutes.gateway.networking.k8s.io -o json")
	if [[ "$ctx" == ctx-a && -n "${STUB_ROUTES_FAIL_ONCE:-}" && ! -f "${STUB_LOG}.rfail" ]]; then
		: >"${STUB_LOG}.rfail"
		echo "Unable to connect to the server: dial tcp 192.0.2.64:6443: i/o timeout" >&2
		exit 1
	fi
	# STUB_NOSTATUS_ONCE: from ctx-a's second route read on, the route has its status.
	if [[ "$ctx" == ctx-a && -n "${STUB_NOSTATUS_ONCE:-}" ]]; then
		n="$(cat "${STUB_LOG}.rcount" 2>/dev/null || echo 0)"
		echo $((n + 1)) >"${STUB_LOG}.rcount"
		((n < 1)) || : >"${STUB_LOG}.once"
	fi
	if [[ "$ctx" == ctx-b ]]; then
		printf '{"items":[%s,%s,%s,%s,%s,%s,%s,%s,%s]}\n' "$(route s2 True ResolvedRefs)" "$(route s3 True ResolvedRefs)" \
			"$(route s4 True ResolvedRefs)" "$(route s5 True ResolvedRefs)" "$(route s7 True ResolvedRefs)" \
			"$(route s7b True ResolvedRefs)" "$(route s8 False BackendNotFound)" "$(route c1 False BackendNotFound)" \
			"$(route c2 True ResolvedRefs)"
	else
		printf '{"items":[%s,%s,%s,%s,%s,%s,%s,%s]}\n' "$(route s2 False BackendNotFound)" "$(route s3 True ResolvedRefs)" \
			"$(route s4 True ResolvedRefs)" "$(route s5 False BackendNotFound)" "$(route s7 ${STUB_S7_REFS_A:-False RefNotPermitted})" \
			"$(route s7b False BackendNotFound)" "$(route s8 False BackendNotFound)" "$(route c1 False BackendNotFound)"
	fi ;;
"-n mesh-verify-gwapi get virtualservices.networking.istio.io -o json") echo '{"items":[{"metadata":{"name":"s1"}},{"metadata":{"name":"s9"}}]}' ;;
*) echo "error: stub: unexpected call: $cmd" >&2; exit 1 ;;
esac
STUB

	# curl: 192.0.2.1 = ctx-a's ingress, 192.0.2.2 = ctx-b's; answers as predicted unless
	# STUB_S<n>_OTHER (a code for S1, S2, S3, S7, S7B, S8 or S9 through ctx-a; S2's body is
	# STUB_S2_BODY, by default "no healthy upstream" for a 503 and empty otherwise, like Envoy's
	# local replies; S9's is STUB_S9_BODY, empty by default), STUB_S2_W (S2's code through ctx-b)
	# or STUB_DEAD=a (no answer). Requests per member and host are sequential (gate, cell,
	# re-probe), so counters say which request this is: STUB_S3_OK_FIRST=<n>: S3 through ctx-a
	# answers 200 to its first n requests (the gate's) before STUB_S3_OTHER;
	# STUB_<id>_REPROBE=<code> (S2, S7, S7B, S8, S9 through ctx-a; S2_W through ctx-b): that code
	# from the 4th request on, i.e. the re-probe of a 3-request run (none of them is a gate host);
	# STUB_S2_REPROBE=kill: the re-probe's first request kills its probe, which leaves no record;
	# STUB_S1_FLAKY=1: S1 through ctx-a alternates 200 and 503. STUB_C1_BODY: C1's 500 body
	# (empty by default). STUB_NO_ECHO_TEXT=1: a 200 has an empty body.
	cat >"${BIN}/curl" <<'STUB'
#!/usr/bin/env bash
out="" host="" url=""
while (($#)); do
	case "$1" in
	-o) out="$2"; shift 2 ;;
	-H) host="${2#Host: }"; shift 2 ;;
	-w | --max-time) shift 2 ;;
	-*) shift ;;
	*) url="$1"; shift ;;
	esac
done
printf '%s %s\n' "$url" "$host" >>"$STUB_CURL_LOG"
case "$url" in *192.0.2.1*) m=a ;; *192.0.2.2*) m=b ;; *) m=x ;; esac
if [[ "$m" == x || "$m" == "${STUB_DEAD:-}" ]]; then
	echo "curl: (28) Connection timed out after 5001 milliseconds to 192.0.2.1" >&2
	printf '000'
	exit 28
fi
echo200=member-b
[[ -z "${STUB_NO_ECHO_TEXT:-}" ]] || echo200=""
code=200 body="$echo200"
k="$(cat "${STUB_CURL_LOG}.${m}.${host}" 2>/dev/null || echo 0)"
k=$((k + 1))
echo "$k" >"${STUB_CURL_LOG}.${m}.${host}"
# body_of <code>: Envoy's local reply body for that code (the echo text for a 200).
body_of() { case "$1" in 200) echo "$echo200" ;; 503) echo "no healthy upstream" ;; *) echo "" ;; esac; }
# rp <code>: from the 4th request on (the re-probe), answer <code> instead; "kill" kills the
# probe on that request: the run script's subshell that runs it, the second-oldest ancestor whose
# command line is the script's (the oldest is the run itself).
rp() {
	[[ -n "$1" && "$k" -gt 3 ]] || return 0
	if [[ "$1" == kill ]]; then
		local p="$PPID" chain=()
		while [[ "$(ps -o args= -p "$p" 2>/dev/null)" == *001-run-ingress-check.sh* ]]; do
			chain+=("$p")
			p="$(ps -o ppid= -p "$p" | tr -d ' ')"
		done
		((${#chain[@]} < 2)) || kill -9 "${chain[${#chain[@]} - 2]}"
		exit 7
	fi
	code="$1"
	body="$(body_of "$1")"
}
case "$host" in
neg.gwapi.test) code=500 body="${STUB_C1_BODY:-}" ;;
s6.gwapi.test) [[ "$m" == b ]] || { code=404; body=""; } ;;
s1.classic.test) [[ "$m" == b || -z "${STUB_S1_OTHER:-}" ]] || { code="$STUB_S1_OTHER"; body="no healthy upstream"; }
	[[ "$m" == b || -z "${STUB_S1_FLAKY:-}" ]] || (( k % 2 )) || { code=503; body="no healthy upstream"; } ;;
s2.gwapi.test) [[ "$m" == b || -z "${STUB_S2_OTHER:-}" ]] || { code="$STUB_S2_OTHER"; body="${STUB_S2_BODY-$(body_of "$STUB_S2_OTHER")}"; }
	[[ "$m" != b || -z "${STUB_S2_W:-}" ]] || { code="$STUB_S2_W"; body=""; }
	if [[ "$m" == b ]]; then rp "${STUB_S2_W_REPROBE:-}"; else rp "${STUB_S2_REPROBE:-}"; fi ;;
s3.gwapi.test) [[ "$m" == b || -z "${STUB_S3_OTHER:-}" ]] || [[ "$k" -le "${STUB_S3_OK_FIRST:-0}" ]] \
		|| { code="$STUB_S3_OTHER"; body="no healthy upstream"; } ;;
s7.gwapi.test) [[ "$m" == b ]] || { code="${STUB_S7_OTHER:-500}"; [[ "$code" == 200 ]] || body=""; }
	[[ "$m" == b ]] || rp "${STUB_S7_REPROBE:-}" ;;
s7b.gwapi.test) [[ "$m" == b || -z "${STUB_S7B_OTHER:-}" ]] || { code="$STUB_S7B_OTHER"; body=""; }
	[[ "$m" == b ]] || rp "${STUB_S7B_REPROBE:-}" ;;
s8.gwapi.test) [[ "$m" == b || -z "${STUB_S8_OTHER:-}" ]] || { code="$STUB_S8_OTHER"; body=""; }
	[[ "$m" == b ]] || rp "${STUB_S8_REPROBE:-}" ;;
s9.classic.test) [[ "$m" == b || -z "${STUB_S9_OTHER:-}" ]] || { code="$STUB_S9_OTHER"; body="${STUB_S9_BODY:-}"; }
	[[ "$m" == b ]] || rp "${STUB_S9_REPROBE:-}" ;;
esac
printf '%s\n' "$body" >"$out"
printf '%s' "$code"
STUB

	# istioctl: one endpoints dump per ingress: ctx-b sees the local pod (8080), ctx-a the
	# east-west gateway (15443), for every backend but echo-none (no cluster), plus an unrelated
	# cluster. STUB_ISTIOCTL=fail|hang breaks every proxy-config call.
	cat >"${BIN}/istioctl" <<'STUB'
#!/usr/bin/env bash
case " $* " in *" version "*) echo '{"clientVersion":{"version":"1.30.5"}}'; exit 0 ;; esac
case "${STUB_ISTIOCTL:-}" in
fail) echo "Error: failed to reach the proxy at 192.0.2.8:15000" >&2; exit 1 ;;
hang) exec sleep 30 ;;
esac
printf '%s\n' "$*" >>"${STUB_LOG}.istioctl"
ctx=""
while (($#)); do
	case "$1" in
	--context) ctx="$2"; shift 2 ;;
	*) shift ;;
	esac
done
if [[ "$ctx" == ctx-b ]]; then port=8080; else port=15443; fi
out=""
for c in echo-s1.mesh-verify-gwapi echo-s2.mesh-verify-gwapi echo-s3.mesh-verify-gwapi echo-s4.mesh-verify-gwapi \
	echo-s5.mesh-verify-gwapi echo-s7.mesh-verify-gwapi-remote echo-s8.mesh-verify-gwapi-remote \
	echo-s9.mesh-verify-gwapi-remote echo-s7b.mesh-verify-gwapi-shared; do
	out="${out}{\"name\":\"outbound|8080||${c}.svc.cluster.local\",\"hostStatuses\":[{\"address\":{\"socketAddress\":{\"address\":\"192.0.2.9\",\"portValue\":${port}}},\"healthStatus\":{\"edsHealthStatus\":\"HEALTHY\"}}]},"
done
printf '[%s{"name":"outbound|80||unrelated.example.svc.cluster.local","hostStatuses":[{"address":{"socketAddress":{"address":"192.0.2.10","portValue":15443}}}]}]\n' "$out"
STUB
	chmod +x "${BIN}/kubectl" "${BIN}/curl" "${BIN}/istioctl"
}

# gw_run [args...]: a whole run against the stubs (ctx-a, ctx-b; workload ctx-b; hub), with no
# settle and no re-probe delay. One gate round unless GWAPI_GATE_PASSES says otherwise (each more
# round is a GATE_POLL_SEC sleep); the gate test runs the default. The stub logs and their request
# counters start empty.
gw_run() {
	rm -f "${STUB_LOG}".* "${STUB_CURL_LOG}".*
	: >"$STUB_LOG"
	: >"$STUB_CURL_LOG"
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" GWAPI_ISTIOCTL_TIMEOUT_SEC="${GWAPI_ISTIOCTL_TIMEOUT_SEC:-5}" GWAPI_SETTLE_SEC=0 \
		GWAPI_REPROBE_DELAY_SEC=0 GWAPI_GATE_PASSES="${GWAPI_GATE_PASSES:-1}" \
		run bash "$GW" --contexts ctx-a,ctx-b --workload-context ctx-b --requests 3 --wait-timeout 5 \
		--results-dir "$OUT" "$@"
}

# The run's files.
tsv() { ls "$OUT"/run-*/gateway-api-*.tsv; }
summary() { ls "$OUT"/run-*/summary-*.md; }

# col <name>: the 1-based column of a TSV header field.
col() { awk -F'\t' -v n="$1" '$1 == "run_id" { for (i = 1; i <= NF; i++) if ($i == n) { print i; exit } }' "$(tsv)"; }

# cell <ctx> <scenario> <column>: one field of one row.
cell() {
	local c
	c="$(col "$3")"
	awk -F'\t' -v x="$1" -v s="$2" -v c="$c" '$2 == x && $4 == s { print $c }' "$(tsv)"
}

# no_addresses: no stub address or registry host reached any output.
no_addresses() {
	if grep -rE '192\.0\.2\.|example\.invalid' "$OUT"; then
		echo "an address or a registry host reached the output"
		return 1
	fi
}

# preamble_keys <file>: the `# KEY=` keys of a TSV preamble, or the frontmatter keys of a summary.
preamble_keys() {
	case "$1" in
	*.md) awk 'NR == 1 && $0 == "---" { on = 1; next } on && $0 == "---" { exit } on { sub(/^"/, ""); sub(/": ".*$/, ""); print }' "$1" ;;
	*) awk '/^run_id\t/ { exit } /^# [A-Za-z_][^=]*=/ { l = substr($0, 3); print substr(l, 1, index(l, "=") - 1) }' "$1" ;;
	esac
}


# ---------------------------------------------------------------------------
# Flags, --help, --dry-run
# ---------------------------------------------------------------------------

@test "gateway-api: --help exits 0 and lists every flag the parser accepts" {
	run bash "$GW" --help
	assert_success
	local f n=0
	for f in $(grep -oE '^[[:space:]]+--[a-z-]+\)' "$GW" | tr -d ' \t)'); do
		[[ "$output" == *"$f"* ]] || { echo "--help does not list $f"; false; }
		n=$((n + 1))
	done
	[ "$n" -eq 11 ]
	assert_output --partial "-h, --help"
	# Every flag's environment key, and the relative-path rule of each results-dir source.
	local k
	for k in SETUP_CONTEXTS GWAPI_WORKLOAD_CONTEXT GWAPI_HUB_CONTEXT GWAPI_INGRESS GWAPI_REQUESTS GWAPI_TIMEOUT_SEC \
		GWAPI_WAIT_TIMEOUT_SEC GWAPI_RESULTS_DIR GWAPI_SKIP_PROXY_CONFIG GWAPI_GATE_PASSES GWAPI_SETTLE_SEC GWAPI_REPROBE_DELAY_SEC \
		GWAPI_SHARED_NAMESPACE; do
		assert_output --partial "$k"
	done
	assert_output --partial "relative value starts at the repo root"
	assert_output --partial "starts at the current directory"
	assert_output --partial "Exit status: 0 whenever the report is written"
}

@test "gateway-api: --dry-run with the CI args and smoke.env contacts nothing and shows every scenario" {
	local args
	args="$(sed -n 's/^# ci-dry-run://p' "$GW")"
	# shellcheck disable=SC2086  # the annotation's words
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run bash "$GW" --dry-run --config "${ROOT}/tests/gateway-api/configs/smoke.env" $args \
		--results-dir "$OUT"
	assert_success
	assert_output --partial "Dry-run complete"
	local h
	for h in s1.classic.test s2.gwapi.test s3.gwapi.test s4.gwapi.test s5.gwapi.test s7.gwapi.test s7b.gwapi.test \
		s8.gwapi.test s9.classic.test neg.gwapi.test s6.gwapi.test; do
		assert_output --partial "$h"
	done
	assert_output --partial "backend namespace mesh-verify-gwapi-remote on ci-b only"
	assert_output --partial "Service mesh-verify-gwapi-remote/echo-s7"
	assert_output --partial "Service mesh-verify-gwapi-shared/echo-s7b"
	assert_output --partial "scenario set $STUB_SCENARIO_SET"
	assert_output --partial "then s1.classic.test and s3.gwapi.test answering 200 with the echo text through every ingress 3 time(s) in a row"
	assert_output --partial "is re-probed once (5 requests) after 15 s (not through an ingress whose gate never passed)"
	assert_output --partial "Proxy evidence: skipped (--skip-proxy-config)"
	[ ! -s "$STUB_LOG" ]
	[ ! -s "$STUB_CURL_LOG" ]
	[ ! -e "$OUT" ]
}

@test "gateway-api: argument errors stop before any cluster call, --dry-run or not" {
	local -a cases=(
		"--contexts ctx-a --workload-context ctx-a|needs at least two mesh members"
		"--contexts ctx-a,ctx-b|--workload-context (or GWAPI_WORKLOAD_CONTEXT) is required"
		"--contexts ctx-a,ctx-b --workload-context ctx-c|is not one of --contexts"
		"--contexts ctx-a,ctx-b --workload-context ctx-b --hub-context ctx-a|never the ACM hub"
		"--contexts ctx-a,ctx-b --workload-context ctx-b --ingress ctx-c=192.0.2.1|ctx-c is not one of --contexts"
		"--contexts ctx-a,ctx-b --workload-context ctx-b --ingress ctx-a|takes CTX=ADDR[:PORT]"
		"--contexts ctx-a,ctx-b --workload-context ctx-b --wait-timeout 2m|--wait-timeout (or GWAPI_WAIT_TIMEOUT_SEC)"
	)
	local c args msg dry
	for c in "${cases[@]}"; do
		args="${c%%|*}"
		msg="${c#*|}"
		for dry in --dry-run ""; do
			# shellcheck disable=SC2086
			PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run bash "$GW" $dry $args
			[ "$status" -eq 1 ] || { echo "$args $dry: exit $status"; false; }
			[[ "$output" == *"$msg"* ]] || { echo "$args $dry: no '$msg' in: $output"; false; }
		done
	done
	# The backend namespaces must differ from the routes' and from each other.
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" GWAPI_REMOTE_NAMESPACE=mesh-verify-gwapi \
		run bash "$GW" --dry-run --contexts ctx-a,ctx-b --workload-context ctx-b
	assert_failure
	assert_output --partial "GWAPI_REMOTE_NAMESPACE must differ from GWAPI_NAMESPACE"
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" GWAPI_SHARED_NAMESPACE=mesh-verify-gwapi-remote \
		run bash "$GW" --dry-run --contexts ctx-a,ctx-b --workload-context ctx-b
	assert_failure
	assert_output --partial "GWAPI_SHARED_NAMESPACE must differ"
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" GWAPI_SETTLE_SEC=-1 \
		run bash "$GW" --dry-run --contexts ctx-a,ctx-b --workload-context ctx-b
	assert_failure
	assert_output --partial "GWAPI_SETTLE_SEC must be a non-negative integer"
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" GWAPI_GATE_PASSES=0 \
		run bash "$GW" --dry-run --contexts ctx-a,ctx-b --workload-context ctx-b
	assert_failure
	assert_output --partial "GWAPI_GATE_PASSES must be a positive integer"
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" GWAPI_REPROBE_DELAY_SEC=x \
		run bash "$GW" --dry-run --contexts ctx-a,ctx-b --workload-context ctx-b
	assert_failure
	assert_output --partial "GWAPI_REPROBE_DELAY_SEC must be a non-negative integer"
	# Fewer than 3 requests: a warning, not an error.
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run bash "$GW" --dry-run --contexts ctx-a,ctx-b --workload-context ctx-b --requests 2
	assert_success
	assert_output --partial "warning: --requests 2 (or GWAPI_REQUESTS) is below 3: a YES then rests on 2 request(s) per probe (two probes)"
	[ ! -s "$STUB_LOG" ]
}

# ---------------------------------------------------------------------------
# The chart and the prediction table describe the same scenarios
# ---------------------------------------------------------------------------

# rendered <clusterName>: what the chart renders for that member (workloadCluster member-b), one
# line per object: "route|host|kind|backend" per HTTPRoute (backend <ns>/<name> across
# namespaces), "route|host|VirtualService|<destination>" per classic route, "svc|<ns>/<name>",
# "ns|<name>", "deploy|<ns>/<name>" and "grant|<ns>|<from ns>|<to Service>".
rendered() {
	helm template t "$CHART" --set "clusterName=$1,workloadCluster=member-b" | awk '
		/^---/ { kind = ""; next }
		/^kind: / { kind = $2; name = ""; ns = ""; host = ""; bk = ""; bns = ""; bname = ""; from = ""; next }
		kind == "Namespace" && /^  name: / { print "ns|" $2 }
		(kind == "Service" || kind == "Deployment") && /^  name: / { name = $2 }
		kind == "Service" && /^  namespace: / { print "svc|" $2 "/" name }
		kind == "Deployment" && /^  namespace: / { print "deploy|" $2 "/" name }
		kind == "ReferenceGrant" && /^  namespace: / { ns = $2 }
		kind == "ReferenceGrant" && /^      namespace: / { from = $2 }
		kind == "ReferenceGrant" && /^      name: / { print "grant|" ns "|" from "|" $2 }
		kind == "HTTPRoute" && /^  name: / { name = $2 }
		kind == "HTTPRoute" && /^    - [a-z0-9.-]+\.test$/ { host = $2 }
		kind == "HTTPRoute" && /^          kind: / { bk = $2 }
		kind == "HTTPRoute" && /^          name: / { bname = $2 }
		kind == "HTTPRoute" && /^          namespace: / { bns = $2 "/" }
		kind == "HTTPRoute" && /^          port: / { print name "|" host "|" bk "|" bns bname }
		kind == "VirtualService" && /^  name: / { name = $2 }
		kind == "VirtualService" && /^    - [a-z0-9.-]+\.test$/ { host = $2 }
		kind == "VirtualService" && /^            host: / { print name "|" host "|VirtualService|" $2 }
	' | LC_ALL=C sort
}

# predicted <role>: the same lines from the script's SCENARIOS table. The test namespace and the
# shared (S7b) backend namespace are on every member; the remote (S7-S9) backend namespace, the
# echo Deployments and the remote grants on the workload member only. A Service exists on the
# workload member for every scenario that answers 200 there, and on another member exactly when
# the table predicts a resolved Service-like backend there (the S3 stub: the script's
# svc_wanted_other rule). A cross-namespace kind Service backend gets a grant in its namespace,
# wherever that namespace exists.
predicted() {
	local role="$1" line kind host route bkind backend bns st_w st_o code_w code_o st code ns name
	{
		echo "ns|mesh-verify-gwapi"
		echo "ns|mesh-verify-gwapi-shared"
		if [[ "$role" == workload ]]; then
			echo "ns|mesh-verify-gwapi-remote"
			echo "deploy|mesh-verify-gwapi/gwapi-echo"
			echo "deploy|mesh-verify-gwapi-remote/gwapi-echo"
			echo "deploy|mesh-verify-gwapi-shared/gwapi-echo"
		fi
		while IFS= read -r line; do
			IFS='|' read -r _ kind host route bkind backend bns st_w st_o code_w code_o _ <<<"$line"
			if [[ "$role" == workload ]]; then st="$st_w" code="$code_w"; else st="$st_o" code="$code_o"; fi
			case "$bns" in
			remote) ns=mesh-verify-gwapi-remote ;;
			shared) ns=mesh-verify-gwapi-shared ;;
			*) ns=mesh-verify-gwapi ;;
			esac
			if [[ "$role" == workload && "$code" == 200 ]] || [[ "$role" != workload && "$st" == *ResolvedRefs=True* && "$bkind" != Hostname ]]; then
				echo "svc|${ns}/${backend}"
			fi
			[[ "$st" != absent ]] || continue
			if [[ "$kind" == classic ]]; then
				echo "${route}|${host}|VirtualService|${backend}.${ns}.svc.cluster.local"
				continue
			fi
			case "$bkind" in
			Hostname) name="${backend}.${ns}.svc.cluster.local" ;;
			*) name="$backend"; [[ "$bns" == main ]] || name="${ns}/${backend}" ;;
			esac
			echo "${route}|${host}|${bkind}|${name}"
			if [[ "$bkind" == Service && "$bns" != main ]] && [[ "$bns" == shared || "$role" == workload ]]; then
				echo "grant|${ns}|mesh-verify-gwapi|${backend}"
			fi
		done < <(sed -n 's/^[[:space:]]*"\([SC][0-9][a-z]*|[^"]*\)"$/\1/p' "$GW" \
			| sed 's/\${ST_OK}/Accepted=True\/ResolvedRefs=True/g; s/\${ST_BNF}/Accepted=True\/ResolvedRefs=False:BackendNotFound/g; s/\${ST_RNP}/Accepted=True\/ResolvedRefs=False:RefNotPermitted/g')
	} | LC_ALL=C sort -u
}

# svc_doc <clusterName> <service>: that Service's rendered document.
svc_doc() {
	helm template t "$CHART" --set "clusterName=$1,workloadCluster=member-b" --show-only templates/services.yaml | awk -v n="$2" '
		/^---/ { if (hit) printf "%s", doc; doc = ""; hit = 0; next }
		{ doc = doc $0 "\n"; if ($0 == "  name: " n) hit = 1 }
		END { if (hit) printf "%s", doc }'
}

@test "gateway-api: the chart renders exactly the scenarios the prediction table describes, with the script's scenario set" {
	command -v helm >/dev/null 2>&1 || skip "helm not installed"
	# The table has its eleven rows, all routes on the workload member.
	[ "$(predicted workload | grep -vcE '^(svc|ns|deploy|grant)\|')" -eq 11 ]
	diff <(rendered member-b) <(predicted workload)
	diff <(rendered member-a) <(predicted other)
	# The S7-S9 backend namespace and everything in it are on the workload member only; the S7b
	# namespace and its grant are everywhere, its Service on the workload member only.
	rendered member-b | grep -qx 'grant|mesh-verify-gwapi-remote|mesh-verify-gwapi|echo-s7'
	rendered member-a | grep -qx 'grant|mesh-verify-gwapi-shared|mesh-verify-gwapi|echo-s7b'
	if rendered member-a | grep -E '^(ns|svc|deploy|grant)\|.*mesh-verify-gwapi-remote|^svc\|mesh-verify-gwapi-shared/'; then
		echo "a workload-only object reached a member without the workload"
		false
	fi
	# The S3 stub on another member is byte-identical to the workload's Service.
	[ -n "$(svc_doc member-a echo-s3)" ]
	diff <(svc_doc member-a echo-s3) <(svc_doc member-b echo-s3)
	# R2: every namespace and the Gateway carry the script's scenario set, and nothing else.
	local m n_obj
	for m in member-a member-b; do
		# Every Namespace plus the one Gateway API Gateway (the classic Istio Gateway carries none).
		n_obj="$(($(helm template t "$CHART" --set "clusterName=${m},workloadCluster=member-b" | grep -c '^kind: Namespace$') + 1))"
		[ "$(helm template t "$CHART" --set "clusterName=${m},workloadCluster=member-b" \
			| grep -c "^    mesh-verify-gwapi/scenario-set: \"${STUB_SCENARIO_SET}\"$")" -eq "$n_obj" ]
		if helm template t "$CHART" --set "clusterName=${m},workloadCluster=member-b" | grep 'scenario-set:' | grep -v "\"${STUB_SCENARIO_SET}\""; then
			echo "the chart stamps another scenario set than the script's ${STUB_SCENARIO_SET}"
			false
		fi
	done
}

# render_sha: sha256 of the chart's render for a member without and a member with the workload
# (fixed values), "# Source:" lines dropped: the input of RENDER_PIN.
render_sha() {
	local out
	out="$({
		helm template t "$CHART" --set clusterName=member-a,workloadCluster=member-b
		helm template t "$CHART" --set clusterName=member-b,workloadCluster=member-b
	} | grep -v '^# Source: ' | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; })"
	printf '%s\n' "${out%% *}"
}

@test "gateway-api chart: the chart render is pinned to the scenario set, and Chart.yaml's version mirrors it" {
	local set="${RENDER_PIN%% *}" pinned="${RENDER_PIN#* }" got hv
	# Without helm: the version and the pin's set still have to follow SCENARIO_SET.
	grep -qx "version: 0\.${STUB_SCENARIO_SET#v}\.0" "${CHART}/Chart.yaml" || {
		echo "charts/mesh-verify-gateway-api/Chart.yaml version must be 0.${STUB_SCENARIO_SET#v}.0 (scenario set ${STUB_SCENARIO_SET})"
		false
	}
	[ "$set" = "$STUB_SCENARIO_SET" ] || {
		echo "SCENARIO_SET is ${STUB_SCENARIO_SET} but RENDER_PIN is for ${set}: set RENDER_PIN to \"${STUB_SCENARIO_SET} <the sha256 this test prints with helm ${RENDER_PIN_HELM_MAJOR}>\""
		false
	}
	command -v helm >/dev/null 2>&1 || skip "helm not installed"
	hv="$(helm version --short 2>/dev/null)" || hv=""
	[[ "$hv" == "v${RENDER_PIN_HELM_MAJOR}."* ]] \
		|| skip "RENDER_PIN is helm ${RENDER_PIN_HELM_MAJOR} output and this helm is '${hv:-unknown}': the render hash is not compared (CI runs it)"
	got="$(render_sha)"
	[ "$got" = "$pinned" ] || {
		echo "the chart's render changed (sha256 ${got}, pinned ${pinned} for ${set}; helm ${hv}): bump SCENARIO_SET, the chart's scenarioSet and Chart.yaml's version together, then set RENDER_PIN to \"<new set> ${got}\""
		false
	}
}

@test "gateway-api chart: an ApplicationSet render without a valid workloadCluster fails; helm lint's default render does not" {
	command -v helm >/dev/null 2>&1 || skip "helm not installed"
	run helm template t "$CHART" --set clusterName=member-a
	assert_failure
	assert_output --partial "is not an ACM ManagedCluster name"
	run helm template t "$CHART" --set clusterName=member-a --set 'workloadCluster=<workload-cluster>'
	assert_failure
	run helm template t "$CHART" --set clusterName=member-b,workloadCluster=member-b,remoteNamespace=mesh-verify-gwapi
	assert_failure
	assert_output --partial "remoteNamespace \"mesh-verify-gwapi\" must differ from namespace"
	run helm template t "$CHART" --set clusterName=member-b,workloadCluster=member-b,sharedNamespace=mesh-verify-gwapi-remote
	assert_failure
	assert_output --partial "sharedNamespace \"mesh-verify-gwapi-remote\" must differ"
	run helm template t "$CHART"
	assert_success
	refute_output --partial "kind: Deployment"
	refute_output --partial "name: mesh-verify-gwapi-remote"
	# Only S7b's grant: S7's lives in the workload member's remote namespace.
	[ "$(grep -c '^kind: ReferenceGrant$' <<<"$output")" -eq 1 ]
	assert_output --partial "name: echo-s7b"
	# The preset passes the workload member through valuesObject.
	run helm template x "${ROOT}/charts/gitops-hub-ocm-placement-appset" \
		-f "${ROOT}/charts/gitops-hub-ocm-placement-appset/values-mesh-verify-gateway-api.yaml" \
		--set repo.url=https://example.invalid/repo.git --set template.source.helm.valuesObject.workloadCluster=member-b
	assert_success
	assert_output --partial "workloadCluster: member-b"
	assert_output --partial 'path: "charts/mesh-verify-gateway-api"'
}

# ---------------------------------------------------------------------------
# Whole runs against the stubs
# ---------------------------------------------------------------------------

@test "gateway-api run: the predicted world gives NO, every row MATCH, builds and readiness recorded, one key set in every output, no address" {
	gw_run --hub-context hub
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: NO — S2 answered 200 (3/3, body \`member-b\`) from the workload member \`ctx-b\` through \`ctx-a\`'s ingress, with no \`echo-s2\` Service there (read in the preflight)."
	assert_output --partial "Local namespace needed on the ingress cluster (backend namespace \`mesh-verify-gwapi-remote\` only on \`ctx-b\`):"
	assert_output --partial "  - kind: Service — YES, it needs the namespace (for the ReferenceGrant) but not the Service: S7 (no \`mesh-verify-gwapi-remote\` there) returned \`500:3\` through \`ctx-a\`'s ingress (500: Envoy had no cluster for the route's destination, i.e. istiod dropped it, as for C1) and again on the re-probe 0 s later (\`500:3\`), while S9/S8, with the backend in the same namespace, answered 200 there and S7 answered 200 through \`ctx-b\` itself; S7b (namespace \`mesh-verify-gwapi-shared\` and its ReferenceGrant there, no Service) answered 200 from \`ctx-b\`."
	assert_output --partial "  - Hostname — NO: S8 answered 200 from \`ctx-b\` through \`ctx-a\`'s ingress, without \`mesh-verify-gwapi-remote\` there."
	assert_output --partial "  - classic VirtualService — NO: S9 answered 200"
	assert_output --partial "Predictions: 22 MATCH, 0 DEVIATION, 0 UNKNOWN of 22 rows."
	assert_output --partial "results will go to ${OUT}/run-"
	assert_output --partial "Argo CD: ${OUT}/run-"
	# The gate's one line per member that passed (its seconds cross a second boundary at times).
	assert_output --regexp '  ctx-a: the data-plane gate passed after [0-9]+ s \(1 round\(s\) in a row\)'
	assert_output --partial "  ctx-b: the data-plane gate passed after"
	local t s a
	t="$(tsv)"
	s="$(summary)"
	a="$(ls "$OUT"/run-*/argocd-*.tsv)"
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id"' "$t" | wc -l)" -eq 22 ]
	# 21 columns, every row.
	[ "$(awk -F'\t' '!/^#/ && NF != 21' "$t" | wc -l)" -eq 0 ]
	[ "$(awk -F'\t' -v c="$(col verdict)" '!/^#/ && $1 != "run_id" && $c != "MATCH"' "$t" | wc -l)" -eq 0 ] \
		|| { grep -v '^#' "$t"; false; }
	[ "$(cell ctx-a S2 observed_status)" = "Accepted=True/ResolvedRefs=False:BackendNotFound" ]
	[ "$(cell ctx-a S2 observed_codes)" = "200:3" ]
	[ "$(cell ctx-a S2 body_match)" = yes ]
	[ "$(cell ctx-a S2 observed_endpoints)" = "remote-ewgw:15443" ]
	[ "$(cell ctx-b S2 observed_endpoints)" = direct ]
	[ "$(cell ctx-a C1 observed_codes)" = "500:3" ]
	[ "$(cell ctx-a C1 observed_endpoints)" = none ]
	[ "$(cell ctx-a C2 observed_status)" = absent ]
	[ "$(cell ctx-a C2 observed_codes)" = "404:3" ]
	# The namespace scenarios: S7 needs the grant (so the namespace), S7b has it and works without
	# the Service, S8 and S9 need neither.
	[ "$(cell ctx-a S7 backend)" = "Service mesh-verify-gwapi-remote/echo-s7" ]
	[ "$(cell ctx-a S7 observed_status)" = "Accepted=True/ResolvedRefs=False:RefNotPermitted" ]
	[ "$(cell ctx-a S7 observed_codes)" = "500:3" ]
	[ "$(cell ctx-a S7 observed_endpoints)" = "remote-ewgw:15443" ]
	# S7's failure makes the YES, so it was re-probed: twice the grant's 500 (T4).
	[ "$(cell ctx-a S7 row_status)" = REPROBE_FAILED ]
	[ "$(cell ctx-a S7 detail)" = "re-probed 0 s after the traffic: 500:3" ]
	[ "$(cell ctx-b S7 observed_status)" = "Accepted=True/ResolvedRefs=True" ]
	[ "$(cell ctx-a S7b backend)" = "Service mesh-verify-gwapi-shared/echo-s7b" ]
	[ "$(cell ctx-a S7b observed_status)" = "Accepted=True/ResolvedRefs=False:BackendNotFound" ]
	[ "$(cell ctx-a S7b observed_codes)" = "200:3" ]
	[ "$(cell ctx-a S7b observed_endpoints)" = "remote-ewgw:15443" ]
	[ "$(cell ctx-b S8 observed_status)" = "Accepted=True/ResolvedRefs=False:BackendNotFound" ]
	[ "$(cell ctx-a S8 observed_codes)" = "200:3" ]
	[ "$(cell ctx-a S8 body_match)" = yes ]
	[ "$(cell ctx-a S9 observed_codes)" = "200:3" ]
	[ "$(cell ctx-a S9 backend)" = "Service mesh-verify-gwapi-remote/echo-s9" ]
	# One istioctl dump per ingress, not one per backend.
	[ "$(wc -l <"${STUB_LOG}.istioctl")" -eq 2 ]
	grep -q 'proxy-config endpoints -n istio-system istio-ingressgateway-5d8f7-p1 -o json' "${STUB_LOG}.istioctl"
	# Provenance: live state per member (PL39), builds that ran (R1), restarts (PL9), the
	# data-plane gate (SC1), the scenario set (R2), the run config, the expected body.
	grep -qx '# GWAPI_SCHEMA=5' "$t"
	grep -qx '# GATEWAYCLASS\[ctx-a\]=istio.io/gateway-controller;Accepted=True' "$t"
	grep -qx '# ISTIOD_ENV\[ctx-b\]=PILOT_ENABLE_GATEWAY_API=true;PILOT_ENABLE_GATEWAY_API_STATUS=unset;PILOT_GATEWAY_API_CONTROLLER_NAME=unset;ENABLE_GATEWAY_API_MANUAL_DEPLOYMENT=unset;PILOT_FILTER_GATEWAY_CLUSTER_CONFIG=unset;PILOT_SCOPE_GATEWAY_TO_NAMESPACE=unset;PILOT_MULTI_NETWORK_DISCOVER_GATEWAY_API=unset;ENABLE_MCS_HOST=unset;ENABLE_MCS_SERVICE_DISCOVERY=unset;ENABLE_MCS_CLUSTER_LOCAL=unset' "$t"
	local digest
	digest="sha256:$(printf '%064d' 7)"
	grep -qx "# ISTIOD_IMAGE\[ctx-a\]=istio-pilot-rhel9:1.30.5@${digest}" "$t"
	grep -qx "# INGRESS_PROXY_IMAGE\[ctx-a\]=istio-proxyv2-rhel9:1.30.5@${digest}" "$t"
	grep -qx '# OSSM_OPERATOR\[ctx-b\]=3.4.3/Succeeded' "$t"
	grep -qx '# INGRESS_REPLICAS\[ctx-a\]=2' "$t"
	grep -qx '# PROXY_CONFIG_POD\[ctx-a\]=istio-ingressgateway-5d8f7-p1' "$t"
	grep -qx '# ISTIOD_RESTARTED\[ctx-a\]=0' "$t"
	grep -qx '# INGRESS_RESTARTED\[ctx-b\]=0' "$t"
	grep -qE '^# DATAPLANE_READY_SEC\[ctx-a\]=[0-9]+$' "$t"
	grep -qx '# DATAPLANE_GATE_HOSTS=s1.classic.test,s3.gwapi.test' "$t"
	grep -qx '# GATE_PASSES=1' "$t"
	grep -qx '# REPROBE_CELLS=1' "$t"
	grep -qx '# REPROBE_DELAY_SEC=0' "$t"
	grep -qx '# SETTLE_SEC=0' "$t"
	grep -qE '^# TRAFFIC_START=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$t"
	grep -qE '^# TRAFFIC_END=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$t"
	grep -qx "# SCENARIO_SET=${STUB_SCENARIO_SET}" "$t"
	grep -qx "# SCENARIO_SET\[ctx-a\]=${STUB_SCENARIO_SET}" "$t"
	grep -qx '# BACKEND_SERVICES\[ctx-a\]=mesh-verify-gwapi:echo-s3;mesh-verify-gwapi-shared:none' "$t"
	grep -qx '# BACKEND_SERVICES\[ctx-b\]=mesh-verify-gwapi:echo-s1,echo-s2,echo-s3,echo-s4,echo-s5;mesh-verify-gwapi-shared:echo-s7b' "$t"
	grep -qx '# SHARED_REFERENCEGRANTS\[ctx-a\]=s7b' "$t"
	grep -qx '# ECHO_DEPLOYMENT\[ctx-b\]=ready=1/1;sidecar=yes' "$t"
	grep -qx '# ECHO_DEPLOYMENT\[ctx-a\]=absent;sidecar=no-pods' "$t"
	grep -qx '# ECHO_SHARED_DEPLOYMENT\[ctx-b\]=ready=1/1;sidecar=yes' "$t"
	grep -qx '# REMOTE_NAMESPACE=mesh-verify-gwapi-remote' "$t"
	grep -qx '# SHARED_NAMESPACE=mesh-verify-gwapi-shared' "$t"
	grep -qx '# REMOTE_NAMESPACE_LABELS\[ctx-a\]=absent' "$t"
	grep -qx '# REMOTE_NAMESPACE_LABELS\[ctx-b\]=istio-discovery=enabled;istio.io/rev=default' "$t"
	grep -qx '# SHARED_NAMESPACE_LABELS\[ctx-a\]=istio-discovery=enabled;istio.io/rev=default' "$t"
	grep -qx '# ECHO_REMOTE_DEPLOYMENT\[ctx-b\]=ready=1/1;sidecar=yes' "$t"
	grep -qx '# GATEWAY_PROGRAMMED\[ctx-a\]=True' "$t"
	grep -qx '# EXPECTED_BODY=member-b' "$t"
	grep -qx '# INGRESS_ADDRESS_SOURCE\[ctx-a\]=lb-status' "$t"
	grep -qx '# RUN_CONFIG=none' "$t"
	grep -qx '# WORKLOAD_CLUSTER=member-b' "$t"
	# R2: the hub's revision is not this script's commit.
	if grep -qx '# HARNESS_SHA=unknown' "$t"; then
		grep -qx '# CHART_REVISION_VS_HARNESS=unknown' "$t"
	else
		grep -qx '# CHART_REVISION_VS_HARNESS=differs' "$t"
		assert_output --partial "Argo CD synced the chart from 0123456789ab, not from this script's commit"
	fi
	# PL36 + PL19: the Argo TSV and the summary's frontmatter carry the TSV's key set, and the
	# same generated_at.
	diff <(preamble_keys "$t") <(preamble_keys "$a")
	diff <(preamble_keys "$t") <(preamble_keys "$s")
	[ "$(grep '^# generated_at=' "$t")" = "$(grep '^# generated_at=' "$a")" ]
	# Argo CD: only the ApplicationSet's Applications, with the workload member's role.
	[ "$(grep -vc '^#\|^run_id' "$a")" -eq 2 ]
	grep -q $'\tmember-b-mesh-verify-gwapi\tmember-b\tworkload\tHealthy\tSynced\t0123456789ab\t-$' "$a"
	grep -q $'\tmember-a-mesh-verify-gwapi\tmember-a\tother\tDegraded\tSynced\t0123456789ab\ts2=Degraded,s3=Healthy$' "$a"
	grep -qx '# CHART_REVISION=0123456789ab' "$t"
	# The summary leads with the two answers, the namespace one a bullet per backend kind.
	[ "$(grep -v '^"\|^---\|^#\|^$' "$s" | head -1)" = "$(grep -m1 'Service needed' "$s")" ]
	[ "$(grep -v '^"\|^---\|^#\|^$' "$s" | sed -n 2p)" = "$(grep -m1 'Local namespace needed' "$s")" ]
	[ "$(grep -v '^"\|^---\|^#\|^$' "$s" | sed -n 3p)" = "$(grep -m1 '^- kind: Service' "$s")" ]
	grep -q '^- Hostname — \*\*NO\*\*' "$s"
	grep -q '| Run config | `none` (sha256 `none`) |' "$s"
	grep -q '| Traffic | ' "$s"
	grep -q "istio-pilot-rhel9:1.30.5@${digest}" "$s"
	# No address or registry host reaches any output.
	no_addresses
}

@test "gateway-api run: S2 (and S7b) returning 500 while the S3 stub works gives YES; S7b answering contradicts it; S2 and S3 failing while S1 answers blames the Gateway API path" {
	STUB_S2_OTHER=500 STUB_S7B_OTHER=500 gw_run
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: YES — S2 (its route in place for the whole traffic window, no \`echo-s2\` Service on the ingress member) returned \`500:3\` through \`ctx-a\`'s ingress (500: Envoy had no cluster for the route's destination, i.e. istiod dropped it, as for C1) and again on the re-probe 0 s later (\`500:3\`), while S3 (the same route plus a stub Service there) answered 200 from the workload member \`ctx-b\` and S2 answered 200 through \`ctx-b\` itself."
	[ "$(cell ctx-a S2 verdict)" = DEVIATION ]
	[ "$(cell ctx-a S3 verdict)" = MATCH ]
	# The failed predicted-200 cells were re-probed, and failed again the same way (G1).
	[[ "$(cell ctx-a S2 row_status)" == *REPROBE_FAILED* ]]
	[[ "$(cell ctx-a S2 detail)" == *"re-probed 0 s after the traffic: 500:3"* ]]
	# S2, S7b and S7 (predicted 500 there, but its failure makes a YES).
	grep -qx '# REPROBE_CELLS=3' "$(tsv)"
	# S7b failing like S2 agrees with the YES: the kind: Service line says so, not INCONCLUSIVE.
	assert_output --partial "S7b (namespace \`mesh-verify-gwapi-shared\` and its ReferenceGrant there, no Service) failed like S2, \`500:3\` through \`ctx-a\`'s ingress and again on the re-probe 0 s later (\`500:3\`), while S1 answered there: consistent with the first answer, so it needs the Service too."
	refute_output --partial "Whether it needs the Service too is INCONCLUSIVE"
	no_addresses
	rm -rf "$OUT"
	# S7b runs S2's code path: S2 failing where S7b answered is a contradiction, not a YES.
	STUB_S2_OTHER=500 gw_run
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE — 0 of 1 other members answered, 0 failed, 0 with a broken path, 1 unclear: S2 failed through \`ctx-a\` while S7b (the same code path: its grant passes, the local Service lookup misses, a soft error) answered 200 there: this contradicts S7b."
	refute_output --partial "traffic: YES"
	rm -rf "$OUT"
	# S3 passes the gate, then fails with S2: the Gateway API path broke, not the Service.
	STUB_S2_OTHER=500 STUB_S3_OTHER=500 STUB_S3_OK_FIRST=1 gw_run
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE — 0 of 1 other members answered, 0 failed, 1 with a broken path, 0 unclear: S2 and S3 all failed through \`ctx-a\`: S1 (classic) answered there, so the Gateway API path is broken, not the Service."
}

@test "gateway-api run: only a 500 counts as 'needed' for an HTTPRoute: a 503 or a 404 on an Accepted route is INCONCLUSIVE (F1)" {
	STUB_S2_OTHER=503 STUB_S7B_OTHER=500 gw_run
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "S2 through \`ctx-a\`: 503 on every request: the ingress has the backend's cluster but no healthy endpoint (EDS lag or the east-west path), so the route kept its destination"
	refute_output --partial "traffic: YES"
	[ "$(cell ctx-a S2 verdict)" = DEVIATION ]
	rm -rf "$OUT"
	STUB_S2_OTHER=404 STUB_S7B_OTHER=500 gw_run
	assert_success
	[ "$(cell ctx-a S2 observed_status)" = "Accepted=True/ResolvedRefs=False:BackendNotFound" ]
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "S2 through \`ctx-a\`: 404 on every request: no route for this host on the ingress (the route had not reached its Envoy)"
	refute_output --partial "traffic: YES"
	rm -rf "$OUT"
	# The same rule for the namespace lines: S7 answering 503 is no "kind: Service — YES".
	STUB_S7_OTHER=503 gw_run
	assert_success
	assert_output --partial "  - kind: Service — INCONCLUSIVE"
	assert_output --partial "S7 through \`ctx-a\`: 503 on every request"
	rm -rf "$OUT"
	# A 500 with a body is not Envoy's empty reply for a route without a cluster.
	STUB_S2_OTHER=500 STUB_S2_BODY="no healthy upstream from 192.0.2.7" STUB_S7B_OTHER=500 gw_run
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "S2 through \`ctx-a\`: 500 with a body (\`no healthy upstream from <ip>\`), not Envoy's empty reply for a route without a cluster; the re-probe got \`500:3\`"
	refute_output --partial "traffic: YES"
	# The answering body is in the row, its address masked.
	grep -q 'HTTP: expected 200 on all 3, got 500:3 (most frequent body: no healthy upstream from <ip>)' "$(tsv)"
	no_addresses
}

@test "gateway-api run: a failure counts toward YES only when its re-probe fails the same way (G1)" {
	# 500, then 503 "no healthy upstream" on the re-probe: the cluster appeared, so the remote
	# Service was discovered late, not dropped.
	STUB_S2_OTHER=500 STUB_S2_REPROBE=503 STUB_S7B_OTHER=500 gw_run
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "S2 through \`ctx-a\`: \`500:3\` with an empty body during the traffic, but the re-probe 0 s later answered \`503:3\` (body \`no healthy upstream\`): the failure was not stable (503: the backend's cluster was there by then, without a healthy endpoint, so its Service was discovered late, not dropped)"
	refute_output --partial "traffic: YES"
	[[ "$(cell ctx-a S2 row_status)" == *REPROBE_FAILED* ]]
	[[ "$(cell ctx-a S2 detail)" == *"re-probed 0 s after the traffic: 503:3 (most frequent body: no healthy upstream)"* ]]
	rm -rf "$OUT"
	# A classic route: an empty 503 (no cluster), then "no healthy upstream" (the cluster is there).
	STUB_S9_OTHER=503 STUB_S9_REPROBE=503 gw_run
	assert_success
	assert_output --partial "  - classic VirtualService — INCONCLUSIVE"
	assert_output --partial "S9 through \`ctx-a\`: \`503:3\` with an empty body during the traffic, but the re-probe 0 s later answered \`503:3\` (body \`no healthy upstream\`): the failure was not stable"
	refute_output --partial "classic VirtualService — YES"
	rm -rf "$OUT"
	# 500, then no answer at all on the re-probe.
	STUB_S2_OTHER=500 STUB_S2_REPROBE=000 STUB_S7B_OTHER=500 gw_run
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "the re-probe 0 s later answered \`000:3\`: the failure was not stable (HTTP \`000:3\`: requests without an answer within 5 s)"
	refute_output --partial "traffic: YES"
	rm -rf "$OUT"
	# 500 again on the re-probe: the failure is stable, and the YES stands.
	STUB_S2_OTHER=500 STUB_S2_REPROBE=500 STUB_S7B_OTHER=500 gw_run
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: YES — S2 (its route in place for the whole traffic window, no \`echo-s2\` Service on the ingress member) returned \`500:3\` through \`ctx-a\`'s ingress"
	assert_output --partial "as for C1) and again on the re-probe 0 s later (\`500:3\`), while S3"
	[[ "$(cell ctx-a S2 detail)" == *"re-probed 0 s after the traffic: 500:3"* ]]
}

@test "gateway-api run: every YES rests on two probes and its own evidence: S7 is re-probed and needs RefNotPermitted, C1 an empty 500, and a re-probe without a record confirms nothing" {
	# S7 (predicted 500 through ctx-a, a YES when it fails) is re-probed: a 503 then is no YES.
	STUB_S7_REPROBE=503 gw_run
	assert_success
	assert_output --partial "  - kind: Service — INCONCLUSIVE"
	assert_output --partial "S7 through \`ctx-a\`: \`500:3\` with an empty body during the traffic, but the re-probe 0 s later answered \`503:3\` (body \`no healthy upstream\`): the failure was not stable"
	refute_output --partial "kind: Service — YES"
	[[ "$(cell ctx-a S7 row_status)" == *REPROBE_FAILED* ]]
	[ "$(cell ctx-a S7 verdict)" = MATCH ]
	rm -rf "$OUT"
	# S7 answering only on the re-probe, where 500 was predicted: not judged, neither YES nor a
	# late NO.
	STUB_S7_REPROBE=200 gw_run
	assert_success
	assert_output --partial "  - kind: Service — INCONCLUSIVE"
	assert_output --partial "S7 through \`ctx-a\` is not judged: it answered 200 with the echo text on the re-probe, where 500 was predicted"
	[[ "$(cell ctx-a S7 row_status)" == *LATE_ENDPOINT* ]]
	rm -rf "$OUT"
	# A queued cell whose re-probe left no record (its probe died): the failure is not confirmed.
	STUB_S2_OTHER=500 STUB_S2_REPROBE=kill STUB_S7B_OTHER=500 gw_run
	assert_success
	[[ "$(cell ctx-a S2 row_status)" == *REPROBE_NO_RECORD* ]]
	[[ "$(cell ctx-a S2 detail)" == *"the re-probe 0 s after the traffic produced no result"* ]]
	assert_output --partial "S2 through \`ctx-a\`: \`500:3\` with an empty body during the traffic, but the re-probe produced no result: the failure is not confirmed"
	refute_output --partial "traffic: YES"
	rm -rf "$OUT"
	# S7's 500 on a route that does not read RefNotPermitted is not the missing grant's.
	STUB_S7_REFS_A="True ResolvedRefs" gw_run
	assert_success
	[ "$(cell ctx-a S7 observed_status)" = "Accepted=True/ResolvedRefs=True" ]
	assert_output --partial "  - kind: Service — INCONCLUSIVE"
	assert_output --partial "S7 failed through \`ctx-a\`, but its route there reads \`Accepted=True/ResolvedRefs=True\` after the traffic, not RefNotPermitted, so the 500 is not shown to be the missing ReferenceGrant's"
	rm -rf "$OUT"
	# C1's 500 with a body is no reference for an empty-bodied 500.
	STUB_C1_BODY="upstream connect error from 192.0.2.7" STUB_S2_OTHER=500 STUB_S7B_OTHER=500 gw_run
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "C1 (no backend anywhere) answered 500 through \`ctx-a\` with a body (\`upstream connect error from <ip>\`), not Envoy's empty reply, so S2's 500 there is not shown to be a dropped destination"
	assert_output --partial "  - kind: Service — INCONCLUSIVE"
	refute_output --partial "traffic: YES"
	no_addresses
	rm -rf "$OUT"
	# With the echo text unknown, a 200 on the re-probe says so instead of "with the echo text".
	STUB_NO_ECHO_TEXT=1 STUB_S2_OTHER=500 STUB_S2_REPROBE=200 STUB_S7B_OTHER=500 gw_run
	assert_success
	grep -qx '# EXPECTED_BODY=unknown' "$(tsv)"
	assert_output --partial "S2 through \`ctx-a\` is not judged: it answered 200 on the re-probe, echo text unknown"
	refute_output --partial "traffic: YES"
}

@test "gateway-api run: a classic route counts as 'needed' only on a 503 with an empty body (no cluster); 'no healthy upstream' is INCONCLUSIVE (F1)" {
	STUB_S9_OTHER=503 gw_run
	assert_success
	assert_output --partial "  - classic VirtualService — YES: S9 returned \`503:3\` through \`ctx-a\`'s ingress (503 with an empty body: Envoy had no cluster for the host) and again on the re-probe 0 s later (\`503:3\`), while S8, with the backend in the same namespace, answered 200 there and S9 answered 200 through \`ctx-b\` itself."
	rm -rf "$OUT"
	STUB_S9_OTHER=503 STUB_S9_BODY="no healthy upstream" gw_run
	assert_success
	assert_output --partial "  - classic VirtualService — INCONCLUSIVE"
	assert_output --partial "S9 through \`ctx-a\`: 503 with a body (\`no healthy upstream\`): Envoy has the cluster but no healthy endpoint"
}

@test "gateway-api run: a YES needs the scenario to work through the workload member (F3)" {
	STUB_S2_W=500 STUB_S2_OTHER=500 gw_run
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "S2 also fails through the workload member \`ctx-b\` (HTTP \`500:3\`), so its failure through \`ctx-a\` is not the ingress member's"
	refute_output --partial "traffic: YES"
	[ "$(cell ctx-b S2 verdict)" = DEVIATION ]
}

@test "gateway-api run: a failure on a route that is not in place for the whole traffic window is INCONCLUSIVE, never YES (M1, F2)" {
	STUB_NOSTATUS=s2 STUB_S2_OTHER=404 gw_run --wait-timeout 0
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	refute_output --partial "traffic: YES"
	assert_output --partial "S2's route on \`ctx-a\` was not in place for the whole traffic window (status when the wait ended \`no-status\`, after the traffic \`no-status\`, row status \`STATUS_TIMEOUT"
	[ "$(cell ctx-a S2 observed_codes)" = "404:3" ]
	[[ "$(cell ctx-a S2 row_status)" == *STATUS_TIMEOUT* ]]
	# The row is not a deviation either: the route had not been processed.
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S2 detail)" == *"not judged a deviation: the route had no current status from istio.io/gateway-controller (no-status)"* ]]
	# The same for the namespace answer: S7 without a status does not make "kind: Service — YES".
	rm -rf "$OUT"
	STUB_NOSTATUS=s7 gw_run --wait-timeout 0
	assert_success
	assert_output --partial "  - kind: Service — INCONCLUSIVE"
	assert_output --partial "S7's route on \`ctx-a\` was not in place"
	rm -rf "$OUT"
	# F2: no status when the wait ended, Accepted by the final read: the traffic may have run
	# without the route. Never YES, and the row is UNKNOWN (STATUS_CHANGED), not a DEVIATION.
	STUB_NOSTATUS_ONCE=s2 STUB_S2_OTHER=404 gw_run --wait-timeout 0
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	refute_output --partial "traffic: YES"
	[ "$(cell ctx-a S2 observed_status)" = "Accepted=True/ResolvedRefs=False:BackendNotFound" ]
	[[ "$(cell ctx-a S2 row_status)" == *STATUS_CHANGED* ]]
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S2 detail)" == *"not judged a deviation: the route was not in place when the wait ended (status no-status), only by the final read"* ]]
	assert_output --partial "S2's route on \`ctx-a\` was not in place for the whole traffic window (status when the wait ended \`no-status\`, after the traffic \`Accepted=True/ResolvedRefs=False:BackendNotFound\`"
	rm -rf "$OUT"
	# The same with the code a dropped destination gives: the route guard alone stops the YES.
	STUB_NOSTATUS_ONCE=s2 STUB_S2_OTHER=500 STUB_S7B_OTHER=500 gw_run --wait-timeout 0
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	refute_output --partial "traffic: YES"
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	rm -rf "$OUT"
	# A MATCH row with STATUS_CHANGED keeps the status the wait ended on in detail.
	STUB_NOSTATUS_ONCE=s2 gw_run --wait-timeout 0
	assert_success
	[ "$(cell ctx-a S2 verdict)" = MATCH ]
	[[ "$(cell ctx-a S2 row_status)" == *STATUS_CHANGED* ]]
	[ "$(cell ctx-a S2 detail)" = "status changed during the run (the wait ended on no-status)" ]
	rm -rf "$OUT"
	# A status that could not be read when the wait ended is "unread", not "not in place".
	STUB_ROUTES_FAIL_ONCE=1 STUB_S2_OTHER=500 STUB_S7B_OTHER=500 gw_run --wait-timeout 0
	assert_success
	[[ "$(cell ctx-a S2 row_status)" == *STATUS_CHANGED* ]]
	[[ "$(cell ctx-a S2 detail)" == *"status changed during the run (the wait ended on unread)"* ]]
	[[ "$(cell ctx-a S2 detail)" == *"not judged a deviation: the route's status was unread when the wait ended"* ]]
	assert_output --partial "S2's route on \`ctx-a\` was not in place for the whole traffic window (status when the wait ended \`unread\`"
	refute_output --partial "traffic: YES"
	no_addresses
}

@test "gateway-api run: the 'no local Service' precondition is read, not inferred: a Service where none belongs, or no S3 stub, is INCONCLUSIVE (M2)" {
	STUB_SVC_A=echo-s2 gw_run
	assert_success
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S2 row_status)" == *SVC_SCENARIO_INVALID* ]]
	[[ "$(cell ctx-a S2 detail)" == *"Service mesh-verify-gwapi/echo-s2 is present on this member (the scenario needs it absent there)"* ]]
	# C2 does not depend on the Service (no route there), so it stays judged.
	[ "$(cell ctx-a C2 verdict)" = MATCH ]
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "S2 on \`ctx-a\`: Service mesh-verify-gwapi/echo-s2 is present on this member"
	refute_output --partial "traffic: NO"
	grep -qx '# BACKEND_SERVICES\[ctx-a\]=mesh-verify-gwapi:echo-s2,echo-s3;mesh-verify-gwapi-shared:none' "$(tsv)"
	rm -rf "$OUT"
	# Without the S3 stub, S3 is no control for a YES.
	STUB_NO_S3_STUB=1 STUB_S2_OTHER=500 gw_run
	assert_success
	[[ "$(cell ctx-a S3 row_status)" == *SVC_SCENARIO_INVALID* ]]
	[[ "$(cell ctx-a S3 detail)" == *"Service mesh-verify-gwapi/echo-s3 is absent on this member (the scenario needs it present there)"* ]]
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "S2 failed through \`ctx-a\`, but its reference cannot count: S3 on \`ctx-a\`"
	refute_output --partial "traffic: YES"
}

@test "gateway-api run: S7 answering gives kind Service NO; S8 failing while S9 answers gives Hostname YES; all failing is a broken path" {
	STUB_S7_OTHER=200 STUB_S8_OTHER=500 gw_run
	assert_success
	assert_output --partial "  - kind: Service — NO: S7 answered 200 from \`ctx-b\` through \`ctx-a\`'s ingress"
	assert_output --partial "  - Hostname — YES: S8 returned \`500:3\` through \`ctx-a\`'s ingress (500: Envoy had no cluster for the route's destination, i.e. istiod dropped it, as for C1) and again on the re-probe 0 s later (\`500:3\`), while S9, with the backend in the same namespace, answered 200 there and S8 answered 200 through \`ctx-b\` itself."
	assert_output --partial "  - classic VirtualService — NO"
	[ "$(cell ctx-a S7 verdict)" = DEVIATION ]
	[ "$(cell ctx-a S8 verdict)" = DEVIATION ]
	# The Service answer does not depend on the namespace scenarios.
	assert_output --partial "traffic: NO"
	rm -rf "$OUT"
	# S7 500 (as predicted), S8 500 and S9 503 without a body: each failed the way a dropped backend
	# does, so with no reference answering the path to the namespace is broken.
	STUB_S8_OTHER=500 STUB_S9_OTHER=503 gw_run
	assert_success
	assert_output --partial "  - kind: Service — INCONCLUSIVE (0 of 1 other members answered, 0 failed, 1 with a broken path, 0 unclear): S7 and S9/S8 all failed through \`ctx-a\`: S7b or S1 answered there, so the path to \`mesh-verify-gwapi-remote\` is broken (check its istio-discovery label on the workload member, whether the echo pod there has a sidecar, and whether its EDS was pushed yet)"
	assert_output --partial "  - Hostname — INCONCLUSIVE"
	assert_output --partial "  - classic VirtualService — INCONCLUSIVE"
}

@test "gateway-api run: S7b is the 'namespace yes, Service no' control: its failure, or a missing grant, leaves that part INCONCLUSIVE" {
	STUB_S7B_OTHER=500 gw_run
	assert_success
	assert_output --partial "  - kind: Service — YES, it needs the namespace (for the ReferenceGrant): S7 (no \`mesh-verify-gwapi-remote\` there) returned \`500:3\` through \`ctx-a\`'s ingress ("
	assert_output --partial "answered 200 there and S7 answered 200 through \`ctx-b\` itself. Whether it needs the Service too is INCONCLUSIVE"
	assert_output --partial "S7b failed while S1 answered through \`ctx-a\`"
	[ "$(cell ctx-a S7b verdict)" = DEVIATION ]
	rm -rf "$OUT"
	STUB_SHARED_A=nogrant gw_run
	assert_success
	[ "$(cell ctx-a S7b verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S7b row_status)" == *NS_SCENARIO_INVALID* ]]
	[[ "$(cell ctx-a S7b detail)" == *"ReferenceGrant mesh-verify-gwapi-shared/s7b is missing on this member"* ]]
	assert_output --partial "Whether it needs the Service too is INCONCLUSIVE"
	grep -qx '# SHARED_REFERENCEGRANTS\[ctx-a\]=none' "$(tsv)"
	rm -rf "$OUT"
	STUB_SHARED_A=absent gw_run
	assert_success
	assert_output --partial "ctx-a: namespace mesh-verify-gwapi-shared is missing here"
	[[ "$(cell ctx-a S7b detail)" == *"namespace mesh-verify-gwapi-shared is missing on this member"* ]]
	no_addresses
}

@test "gateway-api run: the backend namespace on another member makes its S7-S9 rows UNKNOWN, never MATCH, and that answer INCONCLUSIVE" {
	STUB_REMOTE_NS_A=present gw_run
	assert_success
	assert_output --partial "ctx-a: namespace mesh-verify-gwapi-remote exists here"
	local id
	for id in S7 S8 S9; do
		[ "$(cell ctx-a "$id" verdict)" = UNKNOWN ]
		[[ "$(cell ctx-a "$id" row_status)" == *NS_SCENARIO_INVALID* ]]
		[[ "$(cell ctx-a "$id" detail)" == *"namespace mesh-verify-gwapi-remote exists on this member"* ]]
		[ "$(cell ctx-b "$id" verdict)" = MATCH ]
	done
	[ "$(cell ctx-a S2 verdict)" = MATCH ]
	[ "$(cell ctx-a S7b verdict)" = MATCH ]
	assert_output --partial "  - kind: Service — INCONCLUSIVE (0 of 1 other members answered, 0 failed, 0 with a broken path, 1 unclear): S7 on \`ctx-a\`: namespace mesh-verify-gwapi-remote exists on this member"
	assert_output --partial "traffic: NO"
	grep -qx '# REMOTE_NAMESPACE_LABELS\[ctx-a\]=istio-discovery=enabled;istio.io/rev=default' "$(tsv)"
	rm -rf "$OUT"
	# A failed read is not "absent": the rows say NS_SCENARIO_UNVERIFIED (PL39), and the warning
	# quotes kubectl's error, masked (U1).
	STUB_REMOTE_NS_A=fail gw_run
	assert_success
	assert_output --partial "ctx-a: could not read remote_namespace (recorded as unknown): Unable to connect to the server: dial tcp <ip>:6443: i/o timeout"
	[ "$(cell ctx-a S7 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S7 row_status)" == *NS_SCENARIO_UNVERIFIED* ]]
	grep -qx '# REMOTE_NAMESPACE_LABELS\[ctx-a\]=unknown' "$(tsv)"
	assert_output --partial "could not read whether namespace mesh-verify-gwapi-remote exists on this member"
	no_addresses
}

@test "gateway-api run: a check that is not deployed stops with a message and writes nothing" {
	STUB_NO_NS=ctx-a gw_run
	assert_failure
	assert_output --partial "ctx-a: namespace mesh-verify-gwapi is missing"
	assert_output --partial "charts/mesh-verify-gateway-api-appset.yaml"
	[ ! -e "$OUT" ]
	# The echo Deployment on another member than --workload-context.
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run bash "$GW" --contexts ctx-a,ctx-b --workload-context ctx-a --results-dir "$OUT"
	assert_failure
	assert_output --partial "ctx-a (--workload-context): no echo Deployment"
	assert_output --partial "ctx-b: runs the echo Deployment, but --workload-context is ctx-a"
	[ ! -e "$OUT" ]
	# A backend namespace missing on the workload member (an older chart revision).
	STUB_NO_REMOTE_NS=1 gw_run
	assert_failure
	assert_output --partial "ctx-b (--workload-context): namespace mesh-verify-gwapi-remote (the S7-S9 backends) is missing"
	[ ! -e "$OUT" ]
	STUB_NO_SHARED_NS=1 gw_run
	assert_failure
	assert_output --partial "ctx-b (--workload-context): namespace mesh-verify-gwapi-shared (the S7b backend) is missing"
	[ ! -e "$OUT" ]
}

@test "gateway-api run: a member that answers no preflight read stops the run fast, names it and quotes kubectl (U1)" {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run bash "$GW" --contexts ctx-a,ctx-b,ctx-typo --workload-context ctx-b \
		--wait-timeout 0 --results-dir "$OUT"
	assert_failure
	assert_output --partial "error: ctx-typo answered none of the preflight reads; first kubectl error: error: context \"ctx-typo\" does not exist"
	assert_output --partial "kubectl config get-contexts"
	assert_output --partial "Nothing was written."
	refute_output --partial "ctx-a answered none"
	[ ! -e "$OUT" ]
	# Two reads, one retry of the first and the version probe, not one timeout per preflight read.
	[ "$(grep -c -- '--context=ctx-typo' "$STUB_LOG")" -le 4 ]
	# A member whose first two reads time out but whose retry answers is not dead: the run goes
	# on, and the retried reads carry their values.
	STUB_FLAKY_A=2 gw_run
	assert_success
	refute_output --partial "answered none of the preflight reads"
	refute_output --partial "could not read namespace"
	[ "$(grep -c -- '--context=ctx-a .*get namespace mesh-verify-gwapi -o json' "$STUB_LOG")" -eq 2 ]
	grep -qx '# NAMESPACE_LABELS\[ctx-a\]=istio-discovery=enabled;istio.io/rev=default' "$(tsv)"
	grep -qx '# GATEWAY_API_CRD\[ctx-a\]=v1.3.0/standard' "$(tsv)"
	assert_output --partial "traffic: NO"
}

@test "gateway-api run: a route without status after the bounded wait reads STATUS_TIMEOUT, not a deviation (PL4, PL23)" {
	STUB_NOSTATUS=s4 gw_run --wait-timeout 0
	assert_success
	assert_output --partial "the wait timed out"
	[ "$(cell ctx-a S4 observed_status)" = no-status ]
	[ "$(cell ctx-a S4 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S4 row_status)" == *STATUS_TIMEOUT* ]]
	[ "$(cell ctx-b S4 verdict)" = MATCH ]
	grep -qx '# WAIT_TIMED_OUT=1' "$(tsv)"
	# The headline still answers from the traffic.
	assert_output --partial "traffic: NO"
}

@test "gateway-api run: an ingress whose gate never passes is DATAPLANE_NOT_READY: its failures are not blamed on a scenario (SC1)" {
	STUB_S1_OTHER=503 STUB_S2_OTHER=500 gw_run --wait-timeout 1
	assert_success
	assert_output --partial "ctx-a: s1.classic.test and s3.gwapi.test did not answer 200 with the echo text through its ingress 1 time(s) in a row before the wait's deadline (last round: s1.classic.test 503, s3.gwapi.test 200)"
	local t
	t="$(tsv)"
	grep -qx '# DATAPLANE_READY_SEC\[ctx-a\]=timeout' "$t"
	grep -qE '^# DATAPLANE_READY_SEC\[ctx-b\]=[0-9]+$' "$t"
	[[ "$(cell ctx-a S2 row_status)" == *DATAPLANE_NOT_READY* ]]
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S2 detail)" == *"not judged a deviation: s1.classic.test and s3.gwapi.test did not answer 200 through this ingress 1 time(s) in a row"* ]]
	# Its failed cells are not re-probed: the rows are tainted anyway.
	grep -qx '# REPROBE_CELLS=0' "$t"
	[[ "$(cell ctx-a S2 row_status)" != *REPROBE* && "$(cell ctx-a S2 row_status)" != *LATE_ENDPOINT* ]]
	refute_output --partial "Re-probe:"
	[ "$(cell ctx-a S3 verdict)" = MATCH ]
	[ "$(cell ctx-b S2 verdict)" = MATCH ]
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "the cross-cluster path through \`ctx-a\` was not ready"
	refute_output --partial "traffic: YES"
}

@test "gateway-api run: the gate takes S1 and S3 GWAPI_GATE_PASSES rounds in a row through every ingress (SC1)" {
	# The default, 3 rounds: both hosts at least 3 times through each ingress before the traffic.
	GWAPI_GATE_PASSES=3 gw_run
	assert_success
	local t
	t="$(tsv)"
	grep -qx '# GATE_PASSES=3' "$t"
	grep -qE '^# DATAPLANE_READY_SEC\[ctx-a\]=[0-9]+$' "$t"
	grep -qE '^# DATAPLANE_READY_SEC\[ctx-b\]=[0-9]+$' "$t"
	# 3 gate rounds plus the 3 traffic requests.
	[ "$(grep -c '^http://192.0.2.1/ s1.classic.test$' "$STUB_CURL_LOG")" -eq 6 ]
	[ "$(grep -c '^http://192.0.2.1/ s3.gwapi.test$' "$STUB_CURL_LOG")" -eq 6 ]
	assert_output --partial "traffic: NO"
	rm -rf "$OUT"
	: >"$STUB_CURL_LOG"
	# An ingress whose S1 answers only every other time never gets 3 in a row.
	GWAPI_GATE_PASSES=3 STUB_S1_FLAKY=1 gw_run --wait-timeout 1
	assert_success
	grep -qx '# DATAPLANE_READY_SEC\[ctx-a\]=timeout' "$(tsv)"
	assert_output --partial "ctx-a: s1.classic.test and s3.gwapi.test did not answer 200 with the echo text through its ingress 3 time(s) in a row"
	[[ "$(cell ctx-a S2 row_status)" == *DATAPLANE_NOT_READY* ]]
	rm -rf "$OUT"
	# S3 gates too: an ingress where the Gateway API route does not answer is not ready, so a
	# 500 there does not make a YES.
	STUB_S3_OTHER=404 STUB_S2_OTHER=500 STUB_S7B_OTHER=500 gw_run --wait-timeout 1
	assert_success
	grep -qx '# DATAPLANE_READY_SEC\[ctx-a\]=timeout' "$(tsv)"
	assert_output --partial "(last round: s1.classic.test 200, s3.gwapi.test 404)"
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "the cross-cluster path through \`ctx-a\` was not ready (s1.classic.test and s3.gwapi.test did not answer 200 there 1 time(s) in a row within the wait)"
}

@test "gateway-api run: a cell that answers only on the re-probe is a late endpoint: UNKNOWN, never a DEVIATION or a failure; answered for a NO, and named where it blocks a YES" {
	STUB_S2_OTHER=500 STUB_S2_REPROBE=200 STUB_S7B_OTHER=500 gw_run
	assert_success
	assert_output --partial "Re-probe: 3 cell(s) did not answer 200 with the echo text (predicted 200, or S7 through the other members)"
	[ "$(cell ctx-a S2 observed_codes)" = "500:3" ]
	[[ "$(cell ctx-a S2 row_status)" == *LATE_ENDPOINT* ]]
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S2 detail)" == *"re-probed 0 s after the traffic: 200:3 (most frequent body: member-b)"* ]]
	[[ "$(cell ctx-a S2 detail)" == *"not judged a deviation: it answered 200 with the echo text on the re-probe: a late endpoint push, not the scenario"* ]]
	# S7b failed on the re-probe too: a deviation that stands.
	[[ "$(cell ctx-a S7b row_status)" == *REPROBE_FAILED* ]]
	[ "$(cell ctx-a S7b verdict)" = DEVIATION ]
	grep -qx '# REPROBE_CELLS=3' "$(tsv)"
	# S2 answered, if late: a NO that says so.
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: NO — S2 answered 200 (3/3, body \`member-b\`) from the workload member \`ctx-b\` through \`ctx-a\`'s ingress, with no \`echo-s2\` Service there (read in the preflight). 1 of the 1 other members (\`ctx-a\`) answered S2 only on the re-probe 0 s after the traffic (a late endpoint push), not during it."
	refute_output --partial "traffic: YES"
	rm -rf "$OUT"
	# S7b answering only on the re-probe still contradicts an S2 failure (the safe side), and is
	# its own late "not the Service".
	STUB_S2_OTHER=500 STUB_S7B_OTHER=500 STUB_S7B_REPROBE=200 gw_run
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE — 0 of 1 other members answered, 0 failed, 0 with a broken path, 1 unclear: S2 failed through \`ctx-a\` while S7b (the same code path: its grant passes, the local Service lookup misses, a soft error) answered 200 there on the re-probe: this contradicts S7b."
	assert_output --partial "  - kind: Service — YES, it needs the namespace (for the ReferenceGrant) but not the Service:"
	assert_output --partial "answered 200 from \`ctx-b\`. 1 of the 1 other members (\`ctx-a\`) answered S7b only on the re-probe"
	rm -rf "$OUT"
	# The workload member's own cell answering only on the re-probe is named as such.
	STUB_S2_W=500 STUB_S2_W_REPROBE=200 STUB_S2_OTHER=500 STUB_S7B_OTHER=500 gw_run
	assert_success
	[[ "$(cell ctx-b S2 row_status)" == *LATE_ENDPOINT* ]]
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "S2 answered through the workload member \`ctx-b\` only on the re-probe (HTTP \`500:3\` during the traffic, \`200:3\` with the echo text on the re-probe 0 s later: a late endpoint push)"
	refute_output --partial "also fails through the workload member"
	rm -rf "$OUT"
	# References that answered only on the re-probe are named, not "a broken path"; S8 and S9
	# themselves count as answered.
	STUB_S8_OTHER=500 STUB_S8_REPROBE=200 STUB_S9_OTHER=503 STUB_S9_REPROBE=200 gw_run
	assert_success
	assert_output --partial "  - kind: Service — INCONCLUSIVE (0 of 1 other members answered, 0 failed, 0 with a broken path, 1 unclear): S7 failed through \`ctx-a\`, but its reference answered there only on the re-probe: S9 (HTTP \`503:3\` during the traffic"
	assert_output --partial "the path through \`ctx-a\` is not shown ready during the traffic"
	refute_output --partial "all failed through"
	assert_output --partial "  - Hostname — NO: S8 answered 200 from \`ctx-b\` through \`ctx-a\`'s ingress, without \`mesh-verify-gwapi-remote\` there. 1 of the 1 other members (\`ctx-a\`) answered S8 only on the re-probe"
	assert_output --partial "  - classic VirtualService — NO: S9 answered 200"
}

@test "gateway-api run: a chart synced from this script's own commit is 'same', or 'same-dirty' from a modified tree" {
	local head expect
	head="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || skip "not a git checkout"
	case "$(git -C "$ROOT" describe --always --dirty --abbrev=7 2>/dev/null)" in
	"") skip "git describe does not work here" ;;
	*-dirty) expect=same-dirty ;;
	*) expect=same ;;
	esac
	STUB_REVISION="$head" gw_run --hub-context hub
	assert_success
	grep -qx "# CHART_REVISION_VS_HARNESS=${expect}" "$(tsv)"
	refute_output --partial "Argo CD synced the chart from"
	grep -q "vs the script's commit: ${expect}" "$(summary)"
}

@test "gateway-api run: a deployed chart of another scenario set makes the rows UNKNOWN with a clear message (R2)" {
	STUB_SET_A=v0 gw_run
	assert_success
	assert_output --partial "ctx-a: the deployed chart is not the version this script expects: scenario set v0, expected ${STUB_SCENARIO_SET}"
	[ "$(awk -F'\t' -v c="$(col row_status)" '$2 == "ctx-a" && $c !~ /SCENARIO_SET_MISMATCH/' "$(tsv)" | wc -l)" -eq 0 ]
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[ "$(cell ctx-b S2 verdict)" = MATCH ]
	grep -qx '# SCENARIO_SET\[ctx-a\]=v0' "$(tsv)"
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "the chart deployed on this member (scenario set v0) is not the version this script expects"
	rm -rf "$OUT"
	# On the workload member, which holds every backend, it voids every member's rows.
	STUB_SET_B=v0 gw_run
	assert_success
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-b S3 row_status)" == *SCENARIO_SET_MISMATCH* ]]
	[[ "$(cell ctx-a S3 detail)" == *"the chart deployed on the workload member ctx-b (scenario set v0)"* ]]
	rm -rf "$OUT"
	# An unreadable stamp is not a match: the rows say SCENARIO_SET_UNVERIFIED, and a failure there
	# does not count.
	STUB_SET_A=fail STUB_S2_OTHER=500 STUB_S7B_OTHER=500 gw_run
	assert_success
	assert_output --partial "ctx-a: could not read the deployed scenario set (namespace=unknown;gateway=${STUB_SCENARIO_SET}); its rows say SCENARIO_SET_UNVERIFIED"
	[[ "$(cell ctx-a S2 row_status)" == *SCENARIO_SET_UNVERIFIED* ]]
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[ "$(cell ctx-a S3 verdict)" = MATCH ]
	assert_output --partial "S2 through \`ctx-a\` is not judged: the scenario set deployed on this member could not be read"
	refute_output --partial "traffic: YES"
	no_addresses
}

@test "gateway-api run: an istiod restart during the run is recorded and turns a deviation into UNKNOWN (PL9)" {
	STUB_RESTART=istiod STUB_S2_OTHER=500 gw_run
	assert_success
	assert_output --partial "ctx-a: an istiod pod restarted or was replaced during the run"
	grep -qx '# ISTIOD_RESTARTED\[ctx-a\]=1' "$(tsv)"
	grep -qx '# ISTIOD_RESTARTED\[ctx-b\]=0' "$(tsv)"
	[[ "$(cell ctx-a S2 row_status)" == *ISTIOD_RESTARTED* ]]
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[ "$(cell ctx-a S3 verdict)" = MATCH ]
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "istiod or the ingress on \`ctx-a\` restarted during the run"
	rm -rf "$OUT"
	# A restart that could not be checked taints the rows too (PL9: 1 and unknown alike).
	STUB_RESTART=unknown STUB_S2_OTHER=500 STUB_S7B_OTHER=500 gw_run
	assert_success
	grep -qx '# ISTIOD_RESTARTED\[ctx-a\]=unknown' "$(tsv)"
	[[ "$(cell ctx-a S2 row_status)" == *ISTIOD_RESTART_UNVERIFIED* ]]
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[ "$(cell ctx-a S3 verdict)" = MATCH ]
	[[ "$(cell ctx-b S2 row_status)" != *UNVERIFIED* ]]
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "S2 through \`ctx-a\` is not judged: whether an istiod pod restarted during the run could not be read"
	refute_output --partial "traffic: YES"
}

@test "gateway-api run: an ingress that never answers is UNKNOWN (INGRESS_UNREACHABLE), and the answer INCONCLUSIVE" {
	STUB_DEAD=a gw_run --wait-timeout 1
	assert_success
	assert_output --partial "pass --ingress ctx-a=ADDR[:PORT]"
	assert_output --partial "ctx-a: no HTTP answer from this ingress during the data-plane gate"
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S2 row_status)" == *INGRESS_UNREACHABLE* ]]
	[ "$(cell ctx-b S2 verdict)" = MATCH ]
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "\`ctx-a\`'s ingress never answered from here"
	no_addresses
}

@test "gateway-api run: failing istioctl and Argo CD reads do not kill the run; the reasons are shown (PL40)" {
	STUB_ISTIOCTL=fail STUB_HUB_FAIL=1 gw_run --hub-context hub
	assert_success
	assert_output --partial "the Argo CD health read failed"
	assert_output --partial "could not read ApplicationSet openshift-gitops/mesh-verify-gwapi on hub"
	assert_output --partial "istioctl on ctx-a: exit 1: Error: failed to reach the proxy at <ip>:15000"
	[ "$(cell ctx-a S2 observed_endpoints)" = unknown ]
	[[ "$(cell ctx-a S2 row_status)" == *PROXY_CONFIG_FAILED* ]]
	[ "$(cell ctx-a S2 verdict)" = MATCH ]
	assert_output --partial "Predictions: 22 MATCH (endpoints not read: 22 rows), 0 DEVIATION, 0 UNKNOWN of 22 rows."
	ls "$OUT"/run-*/argocd-*.tsv 2>/dev/null && false
	grep -q '^# ARGOCD=failed on hub' "$(tsv)"
	grep -qx '# CHART_REVISION=unknown' "$(tsv)"
	grep -qx '# CHART_REVISION_VS_HARNESS=unknown' "$(tsv)"
	assert_output --partial "traffic: NO"
	no_addresses
	# A hanging istioctl is stopped at GWAPI_ISTIOCTL_TIMEOUT_SEC.
	rm -rf "$OUT"
	STUB_ISTIOCTL=hang GWAPI_ISTIOCTL_TIMEOUT_SEC=1 gw_run
	assert_success
	assert_output --partial "istioctl on ctx-a: no answer within GWAPI_ISTIOCTL_TIMEOUT_SEC (1 s)"
	[ "$(cell ctx-a S2 observed_endpoints)" = timeout ]
	[[ "$(cell ctx-a S2 row_status)" == *PROXY_CONFIG_FAILED* ]]
}

@test "gateway-api run: --ingress replaces the LoadBalancer read and is recorded as an override with its port only" {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" GWAPI_INGRESS=ctx-b=192.0.2.99 GWAPI_SETTLE_SEC=0 GWAPI_REPROBE_DELAY_SEC=0 \
		run bash "$GW" --contexts ctx-a,ctx-b --workload-context ctx-b --requests 2 --wait-timeout 0 \
		--skip-proxy-config --results-dir "$OUT" --ingress ctx-a=192.0.2.1
	assert_success
	# The first --ingress replaced GWAPI_INGRESS, so ctx-b kept its LoadBalancer address.
	grep -qx '# INGRESS_ADDRESS_SOURCE\[ctx-a\]=override:port=80' "$(tsv)"
	grep -qx '# INGRESS_ADDRESS_SOURCE\[ctx-b\]=lb-status' "$(tsv)"
	grep -qx '# PROXY_CONFIG_POD\[ctx-a\]=-' "$(tsv)"
	grep -q '^http://192.0.2.1/ ' "$STUB_CURL_LOG"
	if grep -q '192.0.2.99' "$STUB_CURL_LOG"; then echo "GWAPI_INGRESS was used despite --ingress"; false; fi
	[ "$(cell ctx-a S2 observed_endpoints)" = skipped ]
	assert_output --partial "(endpoints not read: 22 rows)"
	no_addresses
	# A port is kept, the host is not; a run config is copied into the run directory.
	rm -rf "$OUT"
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" GWAPI_SETTLE_SEC=0 GWAPI_REPROBE_DELAY_SEC=0 \
		run bash "$GW" --config "${ROOT}/tests/gateway-api/configs/smoke.env" --contexts ctx-a,ctx-b \
		--workload-context ctx-b --requests 1 --wait-timeout 0 --results-dir "$OUT" --ingress ctx-a=192.0.2.1:8080
	assert_success
	grep -qx '# INGRESS_ADDRESS_SOURCE\[ctx-a\]=override:port=8080' "$(tsv)"
	grep -qx '# RUN_CONFIG=tests/gateway-api/configs/smoke.env' "$(tsv)"
	ls "$OUT"/run-*/run-config-*.env
	grep -q 'run-config-' "$(summary)"
	no_addresses
}

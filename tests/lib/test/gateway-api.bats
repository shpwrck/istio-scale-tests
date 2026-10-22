#!/usr/bin/env bats
# tests/gateway-api/001-run-ingress-check.sh (Gateway API multicluster ingress check) through
# its real entrypoint (PL33): the dry run and the argument errors, the chart <-> prediction-table
# contract (scenario set and render pin included), the stops before anything is written, and
# whole runs against stub kubectl/curl/istioctl. One test per rule of the answers (YES, NO,
# INCONCLUSIVE) and the rows (MATCH, DEVIATION, UNKNOWN): what counts as an answer or a dropped
# destination, the re-probe, the route in place for the whole window, the workload member, the
# references, the preconditions read, late endpoints, the data-plane gate, restarts (PL9), the
# scenario set, unread inputs (PL39), best-effort reads (PL40), one key set in every output
# (PL19), and no address in any output.
# A whole run costs about 3 s of CPU, so setup_file makes each one once (one per CPU at a time)
# and the tests read them: a run's knobs act on answer lines that do not depend on each other
# (S2: the Service answer; S7, S8, S9: the namespace lines) or on rows, and each test names the
# runs it reads.
# Stub addresses are documentation addresses (192.0.2.0/24); the stub registry is example.invalid.

bats_require_minimum_version 1.5.0
load test_helper

GW="${ROOT}/tests/gateway-api/001-run-ingress-check.sh"
CHART="${ROOT}/charts/mesh-verify-gateway-api"

# The chart render that the script's SCENARIO_SET describes: "<set> <sha256 of render_sha>".
# Any change to what the chart renders fails "the chart render is pinned to the scenario set"
# until the set is bumped: SCENARIO_SET in 001-run-ingress-check.sh, the scenarioSet define in
# templates/_helpers.tpl and Chart.yaml's version (v<N> = 0.<N>.0) together, then this pin, to the
# new set and the sha256 that test prints. A new render always needs a new set: never update the
# sha256 alone. Only "# Source:" lines are dropped. The render is helm 4 output (CI pins v4.2.2),
# RENDER_PIN_HELM_MAJOR: with another helm major version (AGENTS.md allows helm 3 or 4) the hash
# is not compared (the test is skipped with a message); never re-pin from another major.
RENDER_PIN="v3 ef2331e33be99cb2bbbe8383a92bc73a21e78f1786fac0b6833c586e29b1a1e8"
RENDER_PIN_HELM_MAJOR=4

# write_stubs: kubectl, curl and istioctl in $BIN.
write_stubs() {
	# kubectl: ctx-a has no workload, ctx-b runs it (echo text member-b) and alone has the S7-S9
	# backend namespace; both have the S7b namespace and its ReferenceGrant; both run OpenShift;
	# hub is the hub (on Kubernetes, Argo CD in argocd; STUB_HUB_PLATFORM=openshift: OpenShift, in
	# openshift-gitops); any other context does not exist. STUB_NO_NS=<ctx>: the test namespace is
	# missing there; STUB_NO_CRD=<ctx>: so are the Gateway API CRDs.
	# STUB_NO_REMOTE_NS=1: the S7-S9 backend namespace is missing on ctx-b; STUB_NO_SHARED_NS=<ctx>:
	# the S7b one is missing there.
	# STUB_REMOTE_NS_A=present|fail: ctx-a has the S7-S9 namespace too, or its read fails.
	# STUB_SHARED_A=nogrant: ctx-a lacks the S7b ReferenceGrant.
	# STUB_SVC_A=<csv>: more Services in ctx-a's test namespace; STUB_NO_S3_STUB=1: no echo-s3 there.
	# STUB_NOSTATUS=<routes csv>: those routes have no status on ctx-a; STUB_NOSTATUS_ONCE=<routes
	# csv>: only in ctx-a's first route read (the wait's); STUB_ROUTES_FAIL_ONCE=1: that read fails.
	# STUB_S7_REFS_A="<status> <reason>": S7's ResolvedRefs on ctx-a (default False RefNotPermitted).
	# STUB_NO_ECHO_TEXT=1: the echo Deployment has no -text argument (curl's 200s have no body).
	# STUB_SET_A/STUB_SET_B: the scenario set stamped on ctx-a/ctx-b (STUB_SET_A=fail: ctx-a's test
	# namespace read fails). STUB_RESTART=istiod: ctx-a's istiod pod is new at the final read;
	# =unknown: that read fails. STUB_FLAKY_A=<n>: ctx-a's first n reads time out (not counting the
	# platform record's, which run alongside the preflight). STUB_HUB_FAIL=1: hub reads fail;
	# STUB_REVISION: the revision the hub's Applications synced. Anything else fails.
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
# The platform record's reads (tests/lib/platform.sh), concurrent with the preflight's.
probe_read=""
case "$cmd" in
"api-versions" | "-n sail-operator get deployments.apps,pods -o json" | "-n istio-system get pods -o json" | "get nodes -o json" | \
	"-n openshift-operators get clusterserviceversions.operators.coreos.com -o json" | \
	"get destinationrules.networking.istio.io,sidecars.networking.istio.io,envoyfilters.networking.istio.io,telemetries.telemetry.istio.io,configmaps -A -l istio-scale-tests/tuning-profile -o json") probe_read=1 ;;
esac
if [[ "$ctx" == ctx-a && -n "${STUB_FLAKY_A:-}" && -z "$probe_read" ]]; then
	n="$(cat "${STUB_LOG}.flaky" 2>/dev/null || echo 0)"
	echo $((n + 1)) >"${STUB_LOG}.flaky"
	((n >= STUB_FLAKY_A)) || { echo "Unable to connect to the server: dial tcp 192.0.2.62:6443: i/o timeout" >&2; exit 1; }
fi
nf() { echo "Error from server (NotFound): $1 not found" >&2; exit 1; }
route() {
	if [[ ",${STUB_NOSTATUS_ONCE:-}," == *",$1,"* && "$ctx" == ctx-a && ! -f "${STUB_LOG}.once" ]]; then
		printf '{"metadata":{"name":"%s","generation":1},"status":{}}' "$1"
		return
	fi
	if [[ ",${STUB_NOSTATUS:-}," == *",$1,"* && "$ctx" == ctx-a ]]; then
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
# pods <name prefix> <container> <image> <count> <start> [labels JSON]: Running pods of one container.
pods() {
	local i out="" digest
	digest="sha256:$(printf '%064d' 7)"
	for ((i = 1; i <= $4; i++)); do
		out="${out:+${out},}{\"metadata\":{\"name\":\"$1-p${i}\"${6:+,\"labels\":$6}},\"spec\":{\"containers\":[{\"name\":\"$2\",\"image\":\"$3\"}]},\"status\":{\"phase\":\"Running\",\"startTime\":\"$5\",\"containerStatuses\":[{\"name\":\"$2\",\"imageID\":\"${3%:*}@${digest}\",\"restartCount\":0}]}}"
	done
	printf '{"items":[%s]}\n' "$out"
}
LABELS='"labels":{"istio-discovery":"enabled","istio.io/rev":"default"}'
if [[ "$ctx" == hub ]]; then
	[[ -z "${STUB_HUB_FAIL:-}" ]] || { echo "Unable to connect to the server: dial tcp 192.0.2.50:6443: i/o timeout" >&2; exit 1; }
	gns=argocd
	[[ "${STUB_HUB_PLATFORM:-}" != openshift ]] || gns=openshift-gitops
	case "$cmd" in
	"api-versions")
		printf '%s\n' apps/v1 argoproj.io/v1alpha1 v1
		[[ "$gns" != openshift-gitops ]] || printf '%s\n' security.openshift.io/v1 ;;
	"-n ${gns} get applicationsets.argoproj.io mesh-verify-gwapi -o json")
		echo '{"spec":{"template":{"spec":{"source":{"helm":{"valuesObject":{"workloadCluster":"member-b"}}}}}}}' ;;
	"-n ${gns} get applications.argoproj.io -o json")
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
	[[ "${STUB_NO_CRD:-}" != "$ctx" ]] || nf 'customresourcedefinitions.apiextensions.k8s.io "httproutes.gateway.networking.k8s.io"'
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
	[[ "${STUB_NO_SHARED_NS:-}" != "$ctx" ]] || nf 'namespaces "mesh-verify-gwapi-shared"'
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
# The members' platform (tests/lib/platform.sh): OpenShift.
"api-versions")
	printf '%s\n' apps/v1 gateway.networking.k8s.io/v1 v1 security.openshift.io/v1 ;;
"-n sail-operator get deployments.apps,pods -o json")
	echo '{"kind":"List","items":[{"kind":"Deployment","metadata":{"name":"sail-operator"},"spec":{"selector":{"matchLabels":{"app":"sail-operator"}},"template":{"spec":{"containers":[{"name":"sail-operator","image":"registry.example.invalid/sail-dev/sail-operator:1.31.1"}]}}},"status":{"availableReplicas":1}},
		{"kind":"Pod","metadata":{"name":"sail-operator-p1","labels":{"app":"sail-operator"}},"status":{"containerStatuses":[{"name":"sail-operator","imageID":"registry.example.invalid/sail-dev/sail-operator@sha256:'"$(printf '%064d' 7)"'"}]}}]}' ;;
"-n istio-system get pods -o json")
	jq -s '{items: (.[0].items + .[1].items)}' \
		<(pods istiod-6c9d8f discovery registry.example.invalid/openshift-service-mesh/istio-pilot-rhel9:1.30.5 1 2026-10-14T08:00:00Z '{"app":"istiod"}') \
		<(pods istio-ingressgateway-5d8f7 istio-proxy registry.example.invalid/openshift-service-mesh/istio-proxyv2-rhel9:1.30.5 2 2026-10-14T08:00:00Z '{"istio":"ingressgateway"}') ;;
"get nodes -o json")
	echo '{"items":[{"spec":{"providerID":"aws:///zone-a/i-0"}}]}' ;;
"get istios.sailoperator.io default -o json")
	echo '{"metadata":{"generation":1},"spec":{"version":"v1.30-latest"},"status":{"state":"Healthy","observedGeneration":1,"activeRevisionName":"default","revisions":{"total":1,"ready":1,"inUse":1}}}' ;;
"get istiorevisions.sailoperator.io default -o json")
	echo '{"metadata":{"generation":1},"spec":{"version":"v1.30.5","namespace":"istio-system"},"status":{"observedGeneration":1}}' ;;
"-n istio-system get deployments.apps istiod -o json")
	echo '{"metadata":{"generation":1},"status":{"observedGeneration":1,"replicas":1,"updatedReplicas":1,"readyReplicas":1}}' ;;
"get destinationrules.networking.istio.io,sidecars.networking.istio.io,envoyfilters.networking.istio.io,telemetries.telemetry.istio.io,configmaps -A -l istio-scale-tests/tuning-profile -o json")
	echo '{"kind":"List","items":[]}' ;;
"-n mesh-verify-gwapi get deploy -l app=gwapi-echo -o json" | "-n mesh-verify-gwapi-remote get deploy -l app=gwapi-echo -o json" | \
	"-n mesh-verify-gwapi-shared get deploy -l app=gwapi-echo -o json")
	if [[ "$ctx" == ctx-b && ( "$cmd" != *-remote* || -z "${STUB_NO_REMOTE_NS:-}" ) && ( "$cmd" != *-shared* || "${STUB_NO_SHARED_NS:-}" != ctx-b ) ]]; then
		text='"-text=member-b"'
		[[ -z "${STUB_NO_ECHO_TEXT:-}" ]] || text='"-status-code=200"'
		echo '{"items":[{"spec":{"replicas":1,"template":{"spec":{"containers":[{"name":"http-echo","args":["-listen=:8080",'"$text"']}]}}},"status":{"readyReplicas":1}}]}'
	else
		echo '{"items":[]}'
	fi ;;
"-n mesh-verify-gwapi get pods -l app=gwapi-echo -o json" | "-n mesh-verify-gwapi-remote get pods -l app=gwapi-echo -o json" | \
	"-n mesh-verify-gwapi-shared get pods -l app=gwapi-echo -o json")
	if [[ "$ctx" == ctx-b && ( "$cmd" != *-remote* || -z "${STUB_NO_REMOTE_NS:-}" ) && ( "$cmd" != *-shared* || "${STUB_NO_SHARED_NS:-}" != ctx-b ) ]]; then
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
	# STUB_S<n>_OTHER (a code for S2, S3, S7, S7B, S8 or S9 through ctx-a; S2's body is
	# STUB_S2_BODY, by default "no healthy upstream" for a 503 and empty otherwise, like Envoy's
	# local replies; S9's is STUB_S9_BODY, empty by default), STUB_S2_W / STUB_S9_W (that code
	# through ctx-b) or STUB_DEAD=a (no answer). Requests per member and host are sequential (gate,
	# cell, re-probe), so counters say which request this is: STUB_S3_OK_FIRST=<n>: S3 through ctx-a
	# answers 200 to its first n requests (the gate's) before STUB_S3_OTHER;
	# STUB_<id>_REPROBE=<code> (S2, S7, S7B, S8, S9 through ctx-a; S9_W through ctx-b): that
	# code from the 4th request on, i.e. the re-probe of a 3-request run (none of them is a gate
	# host); STUB_S2_REPROBE=kill: the re-probe's first request kills its probe, which leaves no
	# record; STUB_S1_FLAKY=1: S1 through ctx-a alternates 200 and 503. STUB_C1_BODY: C1's 500 body
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
s1.classic.test) [[ "$m" == b || -z "${STUB_S1_FLAKY:-}" ]] || (( k % 2 )) || { code=503; body="no healthy upstream"; } ;;
s2.gwapi.test) [[ "$m" == b || -z "${STUB_S2_OTHER:-}" ]] || { code="$STUB_S2_OTHER"; body="${STUB_S2_BODY-$(body_of "$STUB_S2_OTHER")}"; }
	[[ "$m" != b || -z "${STUB_S2_W:-}" ]] || { code="$STUB_S2_W"; body=""; }
	[[ "$m" == b ]] || rp "${STUB_S2_REPROBE:-}" ;;
s3.gwapi.test) [[ "$m" == b || -z "${STUB_S3_OTHER:-}" ]] || [[ "$k" -le "${STUB_S3_OK_FIRST:-0}" ]] \
		|| { code="$STUB_S3_OTHER"; body="no healthy upstream"; } ;;
s7.gwapi.test) [[ "$m" == b ]] || { code="${STUB_S7_OTHER:-500}"; [[ "$code" == 200 ]] || body=""; }
	[[ "$m" == b ]] || rp "${STUB_S7_REPROBE:-}" ;;
s7b.gwapi.test) [[ "$m" == b || -z "${STUB_S7B_OTHER:-}" ]] || { code="$STUB_S7B_OTHER"; body=""; }
	[[ "$m" == b ]] || rp "${STUB_S7B_REPROBE:-}" ;;
s8.gwapi.test) [[ "$m" == b || -z "${STUB_S8_OTHER:-}" ]] || { code="$STUB_S8_OTHER"; body=""; }
	[[ "$m" == b ]] || rp "${STUB_S8_REPROBE:-}" ;;
s9.classic.test) [[ "$m" == b || -z "${STUB_S9_OTHER:-}" ]] || { code="$STUB_S9_OTHER"; body="${STUB_S9_BODY:-}"; }
	[[ "$m" != b || -z "${STUB_S9_W:-}" ]] || { code="$STUB_S9_W"; body=""; }
	if [[ "$m" == b ]]; then rp "${STUB_S9_W_REPROBE:-}"; else rp "${STUB_S9_REPROBE:-}"; fi ;;
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

# gw_run_as <name> [KNOB=value...] [-- args...]: one whole run against the stubs (ctx-a, ctx-b;
# workload ctx-b) with those knobs (write_stubs) and arguments, no settle, no re-probe delay and
# one gate round unless GWAPI_GATE_PASSES says otherwise; its output, exit status, results and
# stub logs are kept in $RUNS/<name> (use).
gw_run_as() {
	local d="${RUNS}/$1" rc=0
	shift
	mkdir -p "$d"
	(
		while (($#)) && [[ "$1" != -- ]]; do
			export "${1?}"
			shift
		done
		(($# == 0)) || shift
		export STUB_LOG="${d}/kubectl.log" STUB_CURL_LOG="${d}/curl.log"
		: >"$STUB_LOG"
		: >"$STUB_CURL_LOG"
		PATH="${BIN}:${PATH}" KUBECONFIG="$EK" GWAPI_ISTIOCTL_TIMEOUT_SEC="${GWAPI_ISTIOCTL_TIMEOUT_SEC:-5}" \
			GWAPI_SETTLE_SEC=0 GWAPI_REPROBE_DELAY_SEC=0 GWAPI_GATE_PASSES="${GWAPI_GATE_PASSES:-1}" \
			bash "$GW" --contexts ctx-a,ctx-b --workload-context ctx-b --requests 3 --wait-timeout 5 \
			--results-dir "${d}/results" "$@" >"${d}/output" 2>&1
	) || rc=$?
	echo "$rc" >"${d}/status"
}

# gw_start <name> [KNOB=value...] [-- args...]: gw_run_as in the background. The runs are
# independent (each has its own stub logs, counters and results) and CPU-bound, so setup_file
# keeps one going per CPU (GW_JOBS), waiting for the oldest, and then for the rest.
gw_start() {
	gw_run_as "$@" &
	GW_PIDS+=("$!")
	if ((${#GW_PIDS[@]} >= GW_JOBS)); then
		wait "${GW_PIDS[0]}" || true
		GW_PIDS=("${GW_PIDS[@]:1}")
	fi
}

setup_file() {
	export EK="${BATS_FILE_TMPDIR}/kubeconfig" BIN="${BATS_FILE_TMPDIR}/bin" RUNS="${BATS_FILE_TMPDIR}/runs"
	: >"$EK"
	mkdir -p "$BIN" "$RUNS"
	# The scenario set the script expects; the stub chart stamps it unless told otherwise.
	STUB_SCENARIO_SET="$(sed -n 's/^SCENARIO_SET=//p' "$GW")"
	export STUB_SCENARIO_SET
	write_stubs
	local head p
	head="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || head=0123456789abcdef0123
	GW_JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null)" || GW_JOBS=2
	[[ "$GW_JOBS" =~ ^[1-9][0-9]*$ ]] || GW_JOBS=2
	GW_PIDS=()
	# The predicted world (ctx-a's first two reads time out, the retry answers), with the hub.
	gw_start predicted STUB_FLAKY_A=2 -- --hub-context hub
	# S2, S7b and S9 fail through ctx-a the way a dropped destination does; S7 fails as predicted.
	gw_start dropped STUB_S2_OTHER=500 STUB_S7B_OTHER=500 STUB_S9_OTHER=503
	# S2 fails through the workload member too; S9 answers there only on the re-probe; S7 answers;
	# ctx-a lacks the S7b namespace.
	gw_start workload STUB_S2_OTHER=500 STUB_S2_W=500 STUB_S7_OTHER=200 STUB_S9_OTHER=503 STUB_S9_W=503 \
		STUB_S9_W_REPROBE=200 STUB_NO_SHARED_NS=ctx-a
	# S7b fails through ctx-a while S2 answers.
	gw_start s7b-fails STUB_S7B_OTHER=500
	# S2 answers 503, S7 404; S9 503 with a body; TEST_PLATFORM names another platform than the
	# members serve.
	gw_start code503 STUB_S2_OTHER=503 STUB_S7_OTHER=404 STUB_S7B_OTHER=500 STUB_S9_OTHER=503 \
		'STUB_S9_BODY=no healthy upstream' TEST_PLATFORM=kubernetes
	# S2's 500 and C1's 500 have a body.
	gw_start bodies STUB_S2_OTHER=500 'STUB_S2_BODY=no healthy upstream from 192.0.2.7' STUB_S7B_OTHER=500 \
		'STUB_C1_BODY=upstream connect error from 192.0.2.7'
	# S2, S7 and S9 answer 503 "no healthy upstream" on the re-probe; ctx-a's ingress by --ingress
	# (GWAPI_INGRESS names another), no istioctl.
	gw_start reprobe503 STUB_S2_OTHER=500 STUB_S2_REPROBE=503 STUB_S7B_OTHER=500 STUB_S7_REPROBE=503 STUB_S9_OTHER=503 \
		STUB_S9_REPROBE=503 GWAPI_INGRESS=ctx-b=192.0.2.99 -- --ingress ctx-a=192.0.2.1 --skip-proxy-config
	# S2's re-probe leaves no record; S7 answers on its re-probe; S8 fails; read through smoke.env
	# and --ingress with a port.
	gw_start reprobe-gone STUB_S2_OTHER=500 STUB_S2_REPROBE=kill STUB_S7B_OTHER=500 STUB_S7_REPROBE=200 STUB_S8_OTHER=500 -- \
		--config "${ROOT}/tests/gateway-api/configs/smoke.env" --ingress ctx-a=192.0.2.1:8080
	# Routes without status: S2 and S5 when the wait ended, S4, S7 and S8 throughout; S2 and S8 fail.
	gw_start no-status STUB_NOSTATUS_ONCE=s2,s5 STUB_NOSTATUS=s4,s7,s8 STUB_S2_OTHER=500 STUB_S7B_OTHER=500 \
		STUB_S8_OTHER=500 -- --wait-timeout 0
	# S2 fails where S7b answers; S8 and S9 fail too.
	gw_start contradicted STUB_S2_OTHER=500 STUB_S8_OTHER=500 STUB_S9_OTHER=503
	# S3 passes the gate, then fails with S2; S7's route reads ResolvedRefs=True.
	gw_start broken STUB_S2_OTHER=500 STUB_S3_OTHER=500 STUB_S3_OK_FIRST=1 STUB_S7B_OTHER=500 \
		'STUB_S7_REFS_A=True ResolvedRefs'
	# S2 and S7b fail where S3 has no stub Service.
	gw_start s3-blocked STUB_NO_S3_STUB=1 STUB_S2_OTHER=500 STUB_S7B_OTHER=500
	# On ctx-a: an echo-s2 Service, the S7-S9 namespace, no S7b ReferenceGrant.
	gw_start preconditions STUB_SVC_A=echo-s2 STUB_REMOTE_NS_A=present STUB_SHARED_A=nogrant
	# S2, S8 and S9 answer only on the re-probe; S7b fails on both probes.
	gw_start late STUB_S2_OTHER=500 STUB_S2_REPROBE=200 STUB_S7B_OTHER=500 STUB_S8_OTHER=500 STUB_S8_REPROBE=200 \
		STUB_S9_OTHER=503 STUB_S9_REPROBE=200
	# S2 fails on both probes; S7b answers only on the re-probe.
	gw_start late-s7b STUB_S2_OTHER=500 STUB_S7B_OTHER=500 STUB_S7B_REPROBE=200
	# Three gate rounds; S1 through ctx-a answers every other time.
	gw_start gate STUB_S1_FLAKY=1 GWAPI_GATE_PASSES=3 STUB_S2_OTHER=500 -- --wait-timeout 1
	# ctx-a's ingress never answers.
	gw_start dead-ingress STUB_DEAD=a -- --wait-timeout 1
	# ctx-a runs another scenario set (a quote, a hash and a backslash in it); the hub runs OpenShift
	# but GWAPI_ARGOCD_NAMESPACE names argocd; istioctl fails.
	gw_start set-member 'STUB_SET_A=v0: \"q\" #1 \\b' STUB_HUB_PLATFORM=openshift GWAPI_ARGOCD_NAMESPACE=argocd \
		STUB_ISTIOCTL=fail -- --hub-context hub
	# The workload member runs another scenario set; the hub does not answer; istioctl hangs.
	gw_start set-workload STUB_SET_B=v0 STUB_HUB_FAIL=1 STUB_ISTIOCTL=hang GWAPI_ISTIOCTL_TIMEOUT_SEC=1 -- --hub-context hub
	# ctx-a's istiod restarts; S2 and S7b fail; an OpenShift hub synced this commit.
	gw_start restart STUB_RESTART=istiod STUB_S2_OTHER=500 STUB_S7B_OTHER=500 STUB_HUB_PLATFORM=openshift \
		"STUB_REVISION=${head}" -- --hub-context hub
	# Unread on ctx-a: the scenario set, the S7-S9 namespace, the final istiod read; the echo text is
	# unknown; S2 and S7b fail.
	gw_start unread STUB_SET_A=fail STUB_REMOTE_NS_A=fail STUB_RESTART=unknown STUB_NO_ECHO_TEXT=1 \
		STUB_S2_OTHER=500 STUB_S7B_OTHER=500
	# ctx-a's route read fails when the wait ends; S2 and S7b fail.
	gw_start route-unread STUB_ROUTES_FAIL_ONCE=1 STUB_S2_OTHER=500 STUB_S7B_OTHER=500 -- --wait-timeout 0
	for p in "${GW_PIDS[@]}"; do wait "$p" || true; done
}

setup() {
	OUT="${BATS_TEST_TMPDIR}/results"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log" STUB_CURL_LOG="${BATS_TEST_TMPDIR}/curl.log"
	: >"$STUB_LOG"
	: >"$STUB_CURL_LOG"
}

# use <name>: a run of setup_file: its output and exit status (for the assert helpers), its
# results ($OUT) and stub logs.
use() {
	local d="${RUNS}/$1"
	[[ -f "${d}/status" ]] || { echo "no run named $1"; return 1; }
	OUT="${d}/results"
	STUB_LOG="${d}/kubectl.log"
	STUB_CURL_LOG="${d}/curl.log"
	output="$(cat "${d}/output")"
	status="$(cat "${d}/status")"
	mapfile -t lines <<<"$output"
}

# gw_run [args...]: a run in the test itself (its output in $output), for the stops that end
# before any traffic.
gw_run() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run bash "$GW" --contexts ctx-a,ctx-b --workload-context ctx-b \
		--requests 3 --wait-timeout 5 --results-dir "$OUT" "$@"
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
# --dry-run and argument errors
# ---------------------------------------------------------------------------

@test "gateway-api: --dry-run with the CI args and smoke.env contacts nothing; the config's values reach the plan" {
	local args
	args="$(sed -n 's/^# ci-dry-run://p' "$GW")"
	# shellcheck disable=SC2086  # the annotation's words
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run bash "$GW" --dry-run --config "${ROOT}/tests/gateway-api/configs/smoke.env" $args \
		--results-dir "$OUT"
	assert_success
	assert_output --partial "Dry-run complete"
	# smoke.env's GWAPI_REQUESTS=5 and GWAPI_SKIP_PROXY_CONFIG=1.
	assert_output --partial "is re-probed once (5 requests)"
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
		"--contexts ctx-a,ctx-b --workload-context ctx-b --hub-context ctx-a|never the hub"
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
	assert_output --partial "warning: --requests 2 (or GWAPI_REQUESTS) is below 3"
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
	# Every namespace and the Gateway carry the script's scenario set, and nothing else.
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
	assert_output --partial "is not a member's cluster name"
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
# Stops before anything is written
# ---------------------------------------------------------------------------

@test "gateway-api run: a check that is not deployed stops with a message and writes nothing" {
	STUB_NO_NS=ctx-a gw_run
	assert_failure
	assert_output --partial "ctx-a: namespace mesh-verify-gwapi is missing"
	assert_output --partial "charts/mesh-verify-gateway-api-appset.yaml"
	[ ! -e "$OUT" ]
	# No Gateway API CRDs (Kubernetes does not ship them): the stop says where to get them.
	STUB_NO_CRD=ctx-a gw_run
	assert_failure
	assert_output --partial "ctx-a: no Gateway API CRDs (httproutes.gateway.networking.k8s.io): install the standard channel (tests/gateway-api/README.md, Deploy)"
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
	STUB_NO_SHARED_NS=ctx-b gw_run
	assert_failure
	assert_output --partial "ctx-b (--workload-context): namespace mesh-verify-gwapi-shared (the S7b backend) is missing"
	[ ! -e "$OUT" ]
}

@test "gateway-api run: a member that answers no preflight read stops the run fast, names it and quotes kubectl; one whose first reads time out is asked again" {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run bash "$GW" --contexts ctx-a,ctx-b,ctx-typo --workload-context ctx-b \
		--wait-timeout 0 --results-dir "$OUT"
	assert_failure
	assert_output --partial "error: ctx-typo answered none of the preflight reads; first kubectl error: error: context \"ctx-typo\" does not exist"
	assert_output --partial "kubectl config get-contexts"
	assert_output --partial "Nothing was written."
	refute_output --partial "ctx-a answered none"
	[ ! -e "$OUT" ]
	# Two reads, one retry of the first, the version probe and the platform record's first read
	# (it stops there), not one timeout per preflight read.
	[ "$(grep -c -- '--context=ctx-typo' "$STUB_LOG")" -le 5 ]
	# predicted: ctx-a's first two reads timed out, its retry answered: the run went on, and the
	# retried reads carry their values.
	use predicted
	assert_success
	refute_output --partial "answered none of the preflight reads"
	refute_output --partial "could not read namespace"
	[ "$(grep -c -- '--context=ctx-a .*get namespace mesh-verify-gwapi -o json' "$STUB_LOG")" -eq 2 ]
	grep -qx '# NAMESPACE_LABELS\[ctx-a\]=istio-discovery=enabled;istio.io/rev=default' "$(tsv)"
	grep -qx '# GATEWAY_API_CRD\[ctx-a\]=v1.3.0/standard' "$(tsv)"
}

# ---------------------------------------------------------------------------
# Whole runs (setup_file): the answers and the rows
# ---------------------------------------------------------------------------

@test "gateway-api run: the predicted world gives NO, every row MATCH, the record of what ran, one key set in every output, no address" {
	use predicted
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: NO — S2 answered 200 (3/3, body \`member-b\`) from the workload member \`ctx-b\` through \`ctx-a\`'s ingress"
	# S7 fails there as predicted (no grant without its namespace), S7b answers: the namespace is
	# needed, not the Service.
	assert_output --partial "  - kind: Service — YES, it needs the namespace (for the ReferenceGrant) but not the Service: S7 (no \`mesh-verify-gwapi-remote\` there) returned \`500:3\` through \`ctx-a\`'s ingress"
	assert_output --partial "  - Hostname — NO: S8 answered 200"
	assert_output --partial "  - classic VirtualService — NO: S9 answered 200"
	assert_output --partial "Predictions: 22 MATCH, 0 DEVIATION, 0 UNKNOWN of 22 rows."
	local t s a digest
	t="$(tsv)"
	s="$(summary)"
	a="$(ls "$OUT"/run-*/argocd-*.tsv)"
	digest="sha256:$(printf '%064d' 7)"
	# 22 rows of 21 columns, every one MATCH.
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id"' "$t" | wc -l)" -eq 22 ]
	[ "$(awk -F'\t' '!/^#/ && NF != 21' "$t" | wc -l)" -eq 0 ]
	[ "$(awk -F'\t' -v c="$(col verdict)" '!/^#/ && $1 != "run_id" && $c != "MATCH"' "$t" | wc -l)" -eq 0 ] \
		|| { grep -v '^#' "$t"; false; }
	# What the cells observed: status, codes, body, the endpoint class (the local pod, or the
	# workload member's east-west gateway), a backend in another namespace.
	[ "$(cell ctx-a S2 observed_status)" = "Accepted=True/ResolvedRefs=False:BackendNotFound" ]
	[ "$(cell ctx-a S2 observed_codes)" = "200:3" ]
	[ "$(cell ctx-a S2 body_match)" = yes ]
	[ "$(cell ctx-a S2 observed_endpoints)" = "remote-ewgw:15443" ]
	[ "$(cell ctx-b S2 observed_endpoints)" = direct ]
	[ "$(cell ctx-a C1 observed_codes)" = "500:3" ]
	[ "$(cell ctx-a C1 observed_endpoints)" = none ]
	[ "$(cell ctx-a C2 observed_status)" = absent ]
	[ "$(cell ctx-a C2 observed_codes)" = "404:3" ]
	[ "$(cell ctx-a S7 backend)" = "Service mesh-verify-gwapi-remote/echo-s7" ]
	[ "$(cell ctx-a S7 observed_status)" = "Accepted=True/ResolvedRefs=False:RefNotPermitted" ]
	# S7's failure makes that YES, so it was re-probed: twice the grant's 500.
	[ "$(cell ctx-a S7 row_status)" = REPROBE_FAILED ]
	[ "$(cell ctx-a S7 detail)" = "re-probed 0 s after the traffic: 500:3" ]
	# The record (PL39): live state per member, the builds that ran, restarts (PL9), the gate and
	# the traffic window, the scenario set, the preconditions as read, the expected body.
	grep -qx '# GWAPI_SCHEMA=5' "$t"
	grep -qx '# GATEWAYCLASS\[ctx-a\]=istio.io/gateway-controller;Accepted=True' "$t"
	grep -q '^# ISTIOD_ENV\[ctx-b\]=PILOT_ENABLE_GATEWAY_API=true;PILOT_ENABLE_GATEWAY_API_STATUS=unset;' "$t"
	grep -qx "# ISTIOD_IMAGE\[ctx-a\]=istio-pilot-rhel9:1.30.5@${digest}" "$t"
	grep -qx "# INGRESS_PROXY_IMAGE\[ctx-a\]=istio-proxyv2-rhel9:1.30.5@${digest}" "$t"
	grep -qx '# OSSM_OPERATOR\[ctx-b\]=servicemeshoperator3:3.4.3' "$t"
	# The version each member runs (its active IstioRevision), not the CR's alias.
	grep -qx '# ISTIO_VERSION=v1.30.5' "$t"
	grep -qx '# ISTIO_CR_VERSION\[ctx-a\]=v1.30-latest' "$t"
	grep -qx '# PLATFORM=openshift' "$t"
	grep -qx '# INGRESS_REPLICAS\[ctx-a\]=2' "$t"
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
	grep -qx '# SHARED_REFERENCEGRANTS\[ctx-a\]=s7b' "$t"
	grep -qx '# REMOTE_NAMESPACE_LABELS\[ctx-a\]=absent' "$t"
	grep -qx '# ECHO_DEPLOYMENT\[ctx-b\]=ready=1/1;sidecar=yes' "$t"
	grep -qx '# GATEWAY_PROGRAMMED\[ctx-a\]=True' "$t"
	grep -qx '# EXPECTED_BODY=member-b' "$t"
	grep -qx '# INGRESS_ADDRESS_SOURCE\[ctx-a\]=lb-status' "$t"
	grep -qx '# RUN_CONFIG=none' "$t"
	# PL36 + PL19: the Argo TSV and the summary's frontmatter carry the TSV's key set, and the
	# same generated_at.
	diff <(preamble_keys "$t") <(preamble_keys "$a")
	diff <(preamble_keys "$t") <(preamble_keys "$s")
	[ "$(grep '^# generated_at=' "$t")" = "$(grep '^# generated_at=' "$a")" ]
	no_addresses
}

@test "gateway-api run: TEST_PLATFORM never relabels the record: each member keeps the platform it serves, the override recorded beside it with a warning" {
	# code503: TEST_PLATFORM=kubernetes, OpenShift members.
	use code503
	assert_success
	grep -qx '# TEST_PLATFORM=kubernetes' "$(tsv)"
	grep -qx '# PLATFORM=openshift' "$(tsv)"
	grep -qx '# PLATFORM_BY_CONTEXT=ctx-a=openshift,ctx-b=openshift' "$(tsv)"
	grep -qx '# OSSM_OPERATOR\[ctx-b\]=servicemeshoperator3:3.4.3' "$(tsv)"
	assert_output --partial "ctx-b: TEST_PLATFORM=kubernetes, but the member serves openshift: the record keeps openshift (PLATFORM_BY_CONTEXT)"
}

@test "gateway-api run: an answer is YES where its scenario fails twice as a dropped destination does while its references answer, NO where it answers; S7b decides kind: Service's Service part (needed too where it fails like S2, INCONCLUSIVE where S2 answers)" {
	# dropped: S2, S7b and S9 fail through ctx-a; S7 fails there as predicted.
	use dropped
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: YES — S2 (its route in place for the whole traffic window, no \`echo-s2\` Service on the ingress member) returned \`500:3\` through \`ctx-a\`'s ingress (500: Envoy had no cluster for the route's destination, i.e. istiod dropped it, as for C1) and again on the re-probe 0 s later (\`500:3\`)"
	[ "$(cell ctx-a S2 verdict)" = DEVIATION ]
	[[ "$(cell ctx-a S2 row_status)" == *REPROBE_FAILED* ]]
	[ "$(cell ctx-a S3 verdict)" = MATCH ]
	# Every failed cell that can count was re-probed: S2, S7b and S9 (predicted 200) and S7.
	grep -qx '# REPROBE_CELLS=4' "$(tsv)"
	# S7b failing like S2 agrees with that YES: the Service too.
	assert_output --partial "  - kind: Service — YES, it needs the namespace (for the ReferenceGrant): S7"
	assert_output --partial "S7b (namespace \`mesh-verify-gwapi-shared\` and its ReferenceGrant there, no Service) failed like S2, \`500:3\` through \`ctx-a\`'s ingress and again on the re-probe 0 s later (\`500:3\`), while S1 answered there: consistent with the first answer, so it needs the Service too."
	assert_output --partial "  - classic VirtualService — YES: S9 returned \`503:3\` through \`ctx-a\`'s ingress (503 with an empty body: Envoy had no cluster for the host) and again on the re-probe 0 s later (\`503:3\`), while S8, with the backend in the same namespace, answered 200 there"
	assert_output --partial "  - Hostname — NO: S8 answered 200"
	no_addresses
	# reprobe-gone: S8 fails twice while S9 answers.
	use reprobe-gone
	assert_output --partial "  - Hostname — YES: S8 returned \`500:3\` through \`ctx-a\`'s ingress (500: Envoy had no cluster for the route's destination, i.e. istiod dropped it, as for C1) and again on the re-probe 0 s later (\`500:3\`), while S9"
	[ "$(cell ctx-a S8 verdict)" = DEVIATION ]
	# workload: S7 answers through ctx-a.
	use workload
	assert_output --partial "  - kind: Service — NO: S7 answered 200 from \`ctx-b\` through \`ctx-a\`'s ingress"
	[ "$(cell ctx-a S7 verdict)" = DEVIATION ]
	# s7b-fails: S7b fails while S2 answers: the namespace part stands, the Service part does not.
	use s7b-fails
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: NO"
	assert_output --partial "  - kind: Service — YES, it needs the namespace (for the ReferenceGrant): S7 (no \`mesh-verify-gwapi-remote\` there) returned \`500:3\` through \`ctx-a\`'s ingress ("
	assert_output --partial "Whether it needs the Service too is INCONCLUSIVE"
	assert_output --partial "S7b failed while S1 answered through \`ctx-a\`"
	[ "$(cell ctx-a S7b verdict)" = DEVIATION ]
}

@test "gateway-api run: only a 200 with the echo text answers, and only Envoy's empty reply is a dropped destination: a 503, a 404, a 500 with a body (or C1's), a classic 503 with a body is INCONCLUSIVE" {
	# code503: S2 answers 503 (S7b fails too, so only the code keeps S2 from a YES), S7 404; S9 a
	# 503 "no healthy upstream".
	use code503
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "S2 through \`ctx-a\`: 503 on every request: the ingress has the backend's cluster but no healthy endpoint (EDS lag or the east-west path), so the route kept its destination"
	[ "$(cell ctx-a S2 verdict)" = DEVIATION ]
	assert_output --partial "  - kind: Service — INCONCLUSIVE"
	assert_output --partial "S7 through \`ctx-a\`: 404 on every request: no route for this host on the ingress"
	assert_output --partial "  - classic VirtualService — INCONCLUSIVE"
	assert_output --partial "S9 through \`ctx-a\`: 503 with a body (\`no healthy upstream\`): Envoy has the cluster but no healthy endpoint"
	# bodies: S2's 500 has a body, and so has C1's, so S7's empty 500 is not shown to be a drop.
	use bodies
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "S2 through \`ctx-a\`: 500 with a body (\`no healthy upstream from <ip>\`), not Envoy's empty reply for a route without a cluster"
	# The answering body is in the row, its address masked.
	grep -q 'HTTP: expected 200 on all 3, got 500:3 (most frequent body: no healthy upstream from <ip>)' "$(tsv)"
	assert_output --partial "  - kind: Service — INCONCLUSIVE"
	assert_output --partial "C1 (no backend anywhere) answered 500 through \`ctx-a\` with a body (\`upstream connect error from <ip>\`), not Envoy's empty reply, so S7's 500 there is not shown to be a dropped destination"
	no_addresses
	# unread: the echo text is unknown (the Deployment has no -text, the 200s no body): a 200 is
	# no answer, so even the workload member's rows are UNKNOWN.
	use unread
	assert_success
	grep -qx '# EXPECTED_BODY=unknown' "$(tsv)"
	[ "$(cell ctx-b S2 body_match)" = unknown ]
	[ "$(cell ctx-b S2 verdict)" = UNKNOWN ]
	assert_output --partial "the workload's echo text is unknown"
}

@test "gateway-api run: a failure counts only where the scenario answers through the workload member during the traffic" {
	# workload: S2 fails through ctx-b too; S9 answers there only on the re-probe.
	use workload
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "S2 also fails through the workload member \`ctx-b\` (HTTP \`500:3\`), so its failure through \`ctx-a\` is not the ingress member's"
	[ "$(cell ctx-b S2 verdict)" = DEVIATION ]
	assert_output --partial "  - classic VirtualService — INCONCLUSIVE"
	assert_output --partial "S9 answered through the workload member \`ctx-b\` only on the re-probe (HTTP \`503:3\` during the traffic, \`200:3\` with the echo text on the re-probe 0 s later: a late endpoint push)"
	[[ "$(cell ctx-b S9 row_status)" == *LATE_ENDPOINT* ]]
}

@test "gateway-api run: a failure counts only when its re-probe repeats it: one that answers otherwise, or leaves no record, confirms nothing" {
	# reprobe503: S2's and S7's empty 500 and S9's empty 503 are 503 "no healthy upstream" on the
	# re-probe: the cluster appeared, so the remote Service was discovered late, not dropped.
	use reprobe503
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "S2 through \`ctx-a\`: \`500:3\` with an empty body during the traffic, but the re-probe 0 s later answered \`503:3\` (body \`no healthy upstream\`): the failure was not stable (503: the backend's cluster was there by then, without a healthy endpoint, so its Service was discovered late, not dropped)"
	[[ "$(cell ctx-a S2 row_status)" == *REPROBE_FAILED* ]]
	[[ "$(cell ctx-a S2 detail)" == *"re-probed 0 s after the traffic: 503:3 (most frequent body: no healthy upstream)"* ]]
	assert_output --partial "  - kind: Service — INCONCLUSIVE"
	assert_output --partial "S7 through \`ctx-a\`: \`500:3\` with an empty body during the traffic, but the re-probe 0 s later answered \`503:3\`"
	assert_output --partial "  - classic VirtualService — INCONCLUSIVE"
	assert_output --partial "S9 through \`ctx-a\`: \`503:3\` with an empty body during the traffic, but the re-probe 0 s later answered \`503:3\` (body \`no healthy upstream\`): the failure was not stable"
	# reprobe-gone: S2's re-probe died (no record); S7 answered on its re-probe, where 500 was
	# predicted: neither confirms a failure, nor is S7's a late NO.
	use reprobe-gone
	assert_success
	[[ "$(cell ctx-a S2 row_status)" == *REPROBE_NO_RECORD* ]]
	[[ "$(cell ctx-a S2 detail)" == *"the re-probe 0 s after the traffic produced no result"* ]]
	assert_output --partial "S2 through \`ctx-a\`: \`500:3\` with an empty body during the traffic, but the re-probe produced no result: the failure is not confirmed"
	refute_output --partial "traffic: YES"
	assert_output --partial "  - kind: Service — INCONCLUSIVE"
	assert_output --partial "S7 through \`ctx-a\` is not judged: it answered 200 with the echo text on the re-probe, where 500 was predicted"
	[[ "$(cell ctx-a S7 row_status)" == *LATE_ENDPOINT* ]]
}

@test "gateway-api run: a failure counts only on a route in place for the whole traffic window, S7's only reading RefNotPermitted; a route without status is UNKNOWN, never a DEVIATION (PL4, PL23)" {
	# no-status (--wait-timeout 0): S2 and S5 without status when the wait ended, S4, S7 and S8
	# throughout; S2 and S8 fail.
	use no-status
	assert_success
	assert_output --partial "the wait timed out"
	grep -qx '# WAIT_TIMED_OUT=1' "$(tsv)"
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "S2's route on \`ctx-a\` was not in place for the whole traffic window (status when the wait ended \`no-status\`, after the traffic \`Accepted=True/ResolvedRefs=False:BackendNotFound\`"
	[[ "$(cell ctx-a S2 row_status)" == *STATUS_CHANGED* ]]
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S2 detail)" == *"not judged a deviation: the route was not in place when the wait ended (status no-status), only by the final read"* ]]
	# A MATCH stays a MATCH, with the status the wait ended on in detail.
	[ "$(cell ctx-a S5 verdict)" = MATCH ]
	[[ "$(cell ctx-a S5 row_status)" == *STATUS_CHANGED* ]]
	[ "$(cell ctx-a S5 detail)" = "status changed during the run (the wait ended on no-status)" ]
	# No status at all: STATUS_TIMEOUT and UNKNOWN, whether the traffic answered (S4) or not (S8).
	[ "$(cell ctx-a S4 observed_status)" = no-status ]
	[[ "$(cell ctx-a S4 row_status)" == *STATUS_TIMEOUT* ]]
	[ "$(cell ctx-a S4 verdict)" = UNKNOWN ]
	[ "$(cell ctx-b S4 verdict)" = MATCH ]
	[ "$(cell ctx-a S8 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S8 detail)" == *"not judged a deviation: the route had no current status from istio.io/gateway-controller (no-status)"* ]]
	assert_output --partial "  - kind: Service — INCONCLUSIVE"
	assert_output --partial "S7's route on \`ctx-a\` was not in place"
	assert_output --partial "  - Hostname — INCONCLUSIVE"
	# broken: S7 fails as predicted, but its route reads ResolvedRefs=True after the traffic.
	use broken
	assert_output --partial "S7 failed through \`ctx-a\`, but its route there reads \`Accepted=True/ResolvedRefs=True\` after the traffic, not RefNotPermitted, so the 500 is not shown to be the missing ReferenceGrant's"
	# route-unread: ctx-a's route read failed when the wait ended: "unread", not in place either.
	use route-unread
	assert_success
	[[ "$(cell ctx-a S2 row_status)" == *STATUS_CHANGED* ]]
	[[ "$(cell ctx-a S2 detail)" == *"status changed during the run (the wait ended on unread)"* ]]
	[[ "$(cell ctx-a S2 detail)" == *"not judged a deviation: the route's status was unread when the wait ended"* ]]
	assert_output --partial "S2's route on \`ctx-a\` was not in place for the whole traffic window (status when the wait ended \`unread\`"
	refute_output --partial "traffic: YES"
}

@test "gateway-api run: a failure counts only beside a reference that answers: S2 and S3 failing together is a broken path, a reference whose own precondition fails cannot count, S7b answering (even only on the re-probe) contradicts S2, S7 failing with S9 and S8 is a broken path" {
	# contradicted: S2 fails where S7b (the same code path) answers; S8 and S9 fail too.
	use contradicted
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE — 0 of 1 other members answered, 0 failed, 0 with a broken path, 1 unclear: S2 failed through \`ctx-a\` while S7b (the same code path: its grant passes, the local Service lookup misses, a soft error) answered 200 there: this contradicts S7b."
	assert_output --partial "  - kind: Service — INCONCLUSIVE (0 of 1 other members answered, 0 failed, 1 with a broken path, 0 unclear): S7 and S9/S8 all failed through \`ctx-a\`: S7b or S1 answered there, so the path to \`mesh-verify-gwapi-remote\` is broken"
	assert_output --partial "  - Hostname — INCONCLUSIVE"
	assert_output --partial "  - classic VirtualService — INCONCLUSIVE"
	# late-s7b: S7b answered only on the re-probe: still a contradiction (the safe side).
	use late-s7b
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE — 0 of 1 other members answered, 0 failed, 0 with a broken path, 1 unclear: S2 failed through \`ctx-a\` while S7b (the same code path: its grant passes, the local Service lookup misses, a soft error) answered 200 there on the re-probe: this contradicts S7b."
	# broken: S3 passed the gate, then failed with S2: the Gateway API path broke, not the Service.
	use broken
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE — 0 of 1 other members answered, 0 failed, 1 with a broken path, 0 unclear: S2 and S3 all failed through \`ctx-a\`: S1 (classic) answered there, so the Gateway API path is broken, not the Service."
	# s3-blocked: S2 fails where S3 has no stub Service, so S3 is no reference there.
	use s3-blocked
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "S2 failed through \`ctx-a\`, but its reference cannot count: S3 on \`ctx-a\`"
}

@test "gateway-api run: the preconditions are read, not inferred: a Service where none belongs, no S3 stub, the S7-S9 namespace on another member, a missing S7b namespace or grant, or an unread namespace make those rows UNKNOWN and the answer INCONCLUSIVE" {
	use preconditions
	assert_success
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S2 row_status)" == *SVC_SCENARIO_INVALID* ]]
	[[ "$(cell ctx-a S2 detail)" == *"Service mesh-verify-gwapi/echo-s2 is present on this member (the scenario needs it absent there)"* ]]
	# C2 does not depend on the Service (no route there), so it stays judged.
	[ "$(cell ctx-a C2 verdict)" = MATCH ]
	grep -qx '# BACKEND_SERVICES\[ctx-a\]=mesh-verify-gwapi:echo-s2,echo-s3;mesh-verify-gwapi-shared:none' "$(tsv)"
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "S2 on \`ctx-a\`: Service mesh-verify-gwapi/echo-s2 is present on this member"
	assert_output --partial "ctx-a: namespace mesh-verify-gwapi-remote exists here"
	local id
	for id in S7 S8 S9; do
		[ "$(cell ctx-a "$id" verdict)" = UNKNOWN ]
		[[ "$(cell ctx-a "$id" row_status)" == *NS_SCENARIO_INVALID* ]]
		[[ "$(cell ctx-a "$id" detail)" == *"namespace mesh-verify-gwapi-remote exists on this member"* ]]
		[ "$(cell ctx-b "$id" verdict)" = MATCH ]
	done
	grep -qx '# REMOTE_NAMESPACE_LABELS\[ctx-a\]=istio-discovery=enabled;istio.io/rev=default' "$(tsv)"
	assert_output --partial "  - kind: Service — INCONCLUSIVE (0 of 1 other members answered, 0 failed, 0 with a broken path, 1 unclear): S7 on \`ctx-a\`: namespace mesh-verify-gwapi-remote exists on this member"
	[ "$(cell ctx-a S7b verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S7b row_status)" == *NS_SCENARIO_INVALID* ]]
	[[ "$(cell ctx-a S7b detail)" == *"ReferenceGrant mesh-verify-gwapi-shared/s7b is missing on this member"* ]]
	grep -qx '# SHARED_REFERENCEGRANTS\[ctx-a\]=none' "$(tsv)"
	# s3-blocked: no S3 stub Service on ctx-a.
	use s3-blocked
	[ "$(cell ctx-a S3 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S3 row_status)" == *SVC_SCENARIO_INVALID* ]]
	[[ "$(cell ctx-a S3 detail)" == *"Service mesh-verify-gwapi/echo-s3 is absent on this member (the scenario needs it present there)"* ]]
	# workload: ctx-a lacks the S7b namespace.
	use workload
	assert_output --partial "ctx-a: namespace mesh-verify-gwapi-shared is missing here"
	[ "$(cell ctx-a S7b verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S7b row_status)" == *NS_SCENARIO_INVALID* ]]
	[[ "$(cell ctx-a S7b detail)" == *"namespace mesh-verify-gwapi-shared is missing on this member"* ]]
	# unread: whether the S7-S9 namespace exists could not be read: NS_SCENARIO_UNVERIFIED (PL39),
	# and the warning quotes kubectl, its address masked.
	use unread
	assert_output --partial "ctx-a: could not read remote_namespace (recorded as unknown): Unable to connect to the server: dial tcp <ip>:6443: i/o timeout"
	[ "$(cell ctx-a S7 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S7 row_status)" == *NS_SCENARIO_UNVERIFIED* ]]
	grep -qx '# REMOTE_NAMESPACE_LABELS\[ctx-a\]=unknown' "$(tsv)"
	assert_output --partial "S7 on \`ctx-a\`: could not read whether namespace mesh-verify-gwapi-remote exists on this member"
	no_addresses
}

@test "gateway-api run: a cell that answers only on the re-probe is a late endpoint: UNKNOWN, never a DEVIATION or a failure; answered for a NO, and named where it blocks a YES" {
	use late
	assert_success
	[ "$(cell ctx-a S2 observed_codes)" = "500:3" ]
	[[ "$(cell ctx-a S2 row_status)" == *LATE_ENDPOINT* ]]
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S2 detail)" == *"re-probed 0 s after the traffic: 200:3 (most frequent body: member-b)"* ]]
	[[ "$(cell ctx-a S2 detail)" == *"not judged a deviation: it answered 200 with the echo text on the re-probe: a late endpoint push, not the scenario"* ]]
	# S7b failed on the re-probe too: a deviation that stands.
	[[ "$(cell ctx-a S7b row_status)" == *REPROBE_FAILED* ]]
	[ "$(cell ctx-a S7b verdict)" = DEVIATION ]
	# S2, S7, S7b, S8 and S9 through ctx-a.
	grep -qx '# REPROBE_CELLS=5' "$(tsv)"
	# S2 answered, if late: a NO that says so.
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: NO — S2 answered 200 (3/3, body \`member-b\`) from the workload member \`ctx-b\` through \`ctx-a\`'s ingress, with no \`echo-s2\` Service there (read in the preflight). 1 of the 1 other members (\`ctx-a\`) answered S2 only on the re-probe 0 s after the traffic (a late endpoint push), not during it."
	# References that answered only on the re-probe are named, not "a broken path"; S8 and S9
	# themselves count as answered.
	assert_output --partial "  - kind: Service — INCONCLUSIVE (0 of 1 other members answered, 0 failed, 0 with a broken path, 1 unclear): S7 failed through \`ctx-a\`, but its reference answered there only on the re-probe: S9 (HTTP \`503:3\` during the traffic"
	refute_output --partial "all failed through"
	assert_output --partial "  - Hostname — NO: S8 answered 200 from \`ctx-b\` through \`ctx-a\`'s ingress, without \`mesh-verify-gwapi-remote\` there. 1 of the 1 other members (\`ctx-a\`) answered S8 only on the re-probe"
	assert_output --partial "  - classic VirtualService — NO: S9 answered 200"
	# late-s7b: S7b, the "namespace yes, Service no" control, answered only on the re-probe.
	use late-s7b
	assert_output --partial "  - kind: Service — YES, it needs the namespace (for the ReferenceGrant) but not the Service:"
	assert_output --partial "answered 200 from \`ctx-b\`. 1 of the 1 other members (\`ctx-a\`) answered S7b only on the re-probe"
}

@test "gateway-api run: the gate takes S1 and S3 GWAPI_GATE_PASSES rounds in a row through every ingress; one that never does is DATAPLANE_NOT_READY, its failures not blamed on a scenario" {
	# gate: 3 rounds; S1 through ctx-a answers every other time, so never 3 in a row.
	use gate
	assert_success
	local t
	t="$(tsv)"
	grep -qx '# GATE_PASSES=3' "$t"
	grep -qE '^# DATAPLANE_READY_SEC\[ctx-b\]=[0-9]+$' "$t"
	# Through ctx-b: 3 gate rounds plus the 3 traffic requests, for both hosts.
	[ "$(grep -c '^http://192.0.2.2/ s1.classic.test$' "$STUB_CURL_LOG")" -eq 6 ]
	[ "$(grep -c '^http://192.0.2.2/ s3.gwapi.test$' "$STUB_CURL_LOG")" -eq 6 ]
	grep -qx '# DATAPLANE_READY_SEC\[ctx-a\]=timeout' "$t"
	assert_output --partial "ctx-a: s1.classic.test and s3.gwapi.test did not answer 200 with the echo text through its ingress 3 time(s) in a row"
	[[ "$(cell ctx-a S2 row_status)" == *DATAPLANE_NOT_READY* ]]
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S2 detail)" == *"not judged a deviation: s1.classic.test and s3.gwapi.test did not answer 200 through this ingress 3 time(s) in a row"* ]]
	# Its failed cells are not re-probed: the rows are tainted anyway.
	grep -qx '# REPROBE_CELLS=0' "$t"
	[ "$(cell ctx-a S3 verdict)" = MATCH ]
	[ "$(cell ctx-b S2 verdict)" = MATCH ]
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "the cross-cluster path through \`ctx-a\` was not ready"
}

@test "gateway-api run: an ingress that never answers is UNKNOWN (INGRESS_UNREACHABLE), and the answer INCONCLUSIVE" {
	use dead-ingress
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

@test "gateway-api run: a deployed chart of another scenario set makes its rows UNKNOWN (every member's when it is the workload's), and an unreadable stamp is no match" {
	use set-member
	assert_success
	assert_output --partial "ctx-a: the deployed chart is not the version this script expects: scenario set v0: "
	[ "$(awk -F'\t' -v c="$(col row_status)" '$2 == "ctx-a" && $c !~ /SCENARIO_SET_MISMATCH/' "$(tsv)" | wc -l)" -eq 0 ]
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[ "$(cell ctx-b S2 verdict)" = MATCH ]
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "the chart deployed on this member (scenario set v0: "
	# On the workload member, which holds every backend, it voids every member's rows.
	use set-workload
	assert_success
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-b S3 row_status)" == *SCENARIO_SET_MISMATCH* ]]
	[[ "$(cell ctx-a S3 detail)" == *"the chart deployed on the workload member ctx-b (scenario set v0)"* ]]
	# unread: ctx-a's stamp could not be read: SCENARIO_SET_UNVERIFIED, and a failure there does
	# not count.
	use unread
	assert_output --partial "ctx-a: could not read the deployed scenario set (namespace=unknown;gateway=${STUB_SCENARIO_SET}); its rows say SCENARIO_SET_UNVERIFIED"
	[[ "$(cell ctx-a S2 row_status)" == *SCENARIO_SET_UNVERIFIED* ]]
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S2 detail)" == *"the scenario set deployed on this member could not be read"* ]]
	assert_output --partial "the scenario set deployed on this member could not be read"
	refute_output --partial "traffic: YES"
}

# The summary's frontmatter is every `# KEY=value` preamble line of the TSV, as 001 reads them
# (up to the header row), so a value with a quote and a backslash must read back as itself.
@test "gateway-api run: the summary's frontmatter parses as YAML and reads back every TSV preamble value, a quote and a backslash included (PL19)" {
	python3 -I -c 'import yaml' 2>/dev/null || skip "python3 with PyYAML is needed"
	# set-member: the stub prints the stamp into its JSON as given: JSON-escaped there, read as
	# v0: "q" #1 \b (": " and " #" would also end a plain YAML scalar).
	use set-member
	assert_success
	grep -qxF '# SCENARIO_SET[ctx-a]=v0: "q" #1 \b' "$(tsv)"
	python3 -I -c '
import re, sys, yaml
want = {}
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\n")
    if line.startswith("run_id\t"):
        break
    m = re.match(r"^# ([A-Za-z_][^=]*)=(.*)$", line)
    if m:
        want[m.group(1)] = m.group(2)
lines = open(sys.argv[2], encoding="utf-8").read().split("\n")
if lines[0] != "---":
    sys.exit("the summary has no frontmatter")
got = yaml.safe_load("\n".join(lines[1:lines.index("---", 1)]))
if got != want:
    sys.exit("frontmatter %r\nTSV preamble %r" % (got, want))
if got.get("SCENARIO_SET[ctx-a]") != "v0: \"q\" #1 \\b":
    sys.exit("SCENARIO_SET[ctx-a] reads %r" % got.get("SCENARIO_SET[ctx-a]"))
' "$(tsv)" "$(summary)"
}

@test "gateway-api run: an istiod restart during the run, or one that could not be checked, turns a deviation into UNKNOWN and the answer INCONCLUSIVE (PL9)" {
	use restart
	assert_success
	assert_output --partial "ctx-a: an istiod pod restarted or was replaced during the run"
	grep -qx '# ISTIOD_RESTARTED\[ctx-a\]=1' "$(tsv)"
	grep -qx '# ISTIOD_RESTARTED\[ctx-b\]=0' "$(tsv)"
	[[ "$(cell ctx-a S2 row_status)" == *ISTIOD_RESTARTED* ]]
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	# A MATCH stays a MATCH: it was observed regardless.
	[ "$(cell ctx-a S3 verdict)" = MATCH ]
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: INCONCLUSIVE"
	assert_output --partial "istiod or the ingress on \`ctx-a\` restarted during the run"
	# unread: ctx-a's final istiod read failed: unknown, which taints the rows like 1.
	use unread
	grep -qx '# ISTIOD_RESTARTED\[ctx-a\]=unknown' "$(tsv)"
	[[ "$(cell ctx-a S2 row_status)" == *ISTIOD_RESTART_UNVERIFIED* ]]
	[[ "$(cell ctx-a S2 detail)" == *"whether an istiod pod restarted during the run could not be read"* ]]
	[[ "$(cell ctx-b S2 row_status)" != *UNVERIFIED* ]]
	assert_output --partial "S2 through \`ctx-a\` is not judged: whether an istiod pod restarted during the run could not be read"
	refute_output --partial "traffic: YES"
}

@test "gateway-api run: failing istioctl and Argo CD reads do not kill the run; the reasons are shown, addresses masked (PL40)" {
	# set-workload: the hub does not answer; istioctl hangs past GWAPI_ISTIOCTL_TIMEOUT_SEC=1.
	use set-workload
	assert_success
	assert_output --partial "the Argo CD health read failed"
	assert_output --partial "could not tell the hub's platform to pick its Argo CD namespace; set GWAPI_ARGOCD_NAMESPACE (argocd, or openshift-gitops on OpenShift)"
	assert_output --partial "dial tcp <ip>:6443: i/o timeout"
	refute_output --partial "192.0.2."
	ls "$OUT"/run-*/argocd-*.tsv 2>/dev/null && false
	grep -q '^# ARGOCD=failed on hub' "$(tsv)"
	grep -qx '# CHART_REVISION=unknown' "$(tsv)"
	grep -qx '# CHART_REVISION_VS_HARNESS=unknown' "$(tsv)"
	assert_output --partial "istioctl on ctx-a: no answer within GWAPI_ISTIOCTL_TIMEOUT_SEC (1 s)"
	[ "$(cell ctx-a S2 observed_endpoints)" = timeout ]
	[[ "$(cell ctx-a S2 row_status)" == *PROXY_CONFIG_FAILED* ]]
	no_addresses
	# set-member: istioctl fails.
	use set-member
	assert_success
	assert_output --partial "istioctl on ctx-a: exit 1: Error: failed to reach the proxy at <ip>:15000"
	[ "$(cell ctx-a S2 observed_endpoints)" = unknown ]
	[[ "$(cell ctx-a S2 row_status)" == *PROXY_CONFIG_FAILED* ]]
	assert_output --partial "(endpoints not read: 22 rows)"
	no_addresses
}

@test "gateway-api run: the hub's Argo CD rows come from its platform's namespace unless GWAPI_ARGOCD_NAMESPACE names it; the synced revision is compared with this script's commit" {
	# predicted: a Kubernetes hub (argocd) that synced another revision than this commit.
	use predicted
	assert_output --partial "Argo CD namespace on hub: argocd (from its platform; GWAPI_ARGOCD_NAMESPACE sets it)"
	local a expect
	a="$(ls "$OUT"/run-*/argocd-*.tsv)"
	# Only the ApplicationSet's Applications, with the workload member's role.
	[ "$(grep -vc '^#\|^run_id' "$a")" -eq 2 ]
	grep -q $'\tmember-b-mesh-verify-gwapi\tmember-b\tworkload\tHealthy\tSynced\t0123456789ab\t-$' "$a"
	grep -q $'\tmember-a-mesh-verify-gwapi\tmember-a\tother\tDegraded\tSynced\t0123456789ab\ts2=Degraded,s3=Healthy$' "$a"
	grep -qx '# CHART_REVISION=0123456789ab' "$(tsv)"
	grep -qx '# WORKLOAD_CLUSTER=member-b' "$(tsv)"
	if grep -qx '# HARNESS_SHA=unknown' "$(tsv)"; then
		grep -qx '# CHART_REVISION_VS_HARNESS=unknown' "$(tsv)"
	else
		grep -qx '# CHART_REVISION_VS_HARNESS=differs' "$(tsv)"
		assert_output --partial "Argo CD synced the chart from 0123456789ab, not from this script's commit"
	fi
	# set-member: GWAPI_ARGOCD_NAMESPACE=argocd on an OpenShift hub: used as given (no platform
	# read on the hub), and the failed read names the knob.
	use set-member
	! grep -q -- '--context=hub .*api-versions' "$STUB_LOG" || false
	refute_output --partial "Argo CD namespace on hub:"
	assert_output --partial "could not read ApplicationSet argocd/mesh-verify-gwapi on hub"
	assert_output --partial "GWAPI_ARGOCD_NAMESPACE and GWAPI_ARGOCD_APPSET name it"
	grep -q '^# ARGOCD=failed on hub' "$(tsv)"
	# restart: an OpenShift hub (openshift-gitops) that synced this script's own commit: "same", or
	# "same-dirty" from a modified tree (harness_sha: a dirty tree is <describe>-dirty).
	use restart
	assert_output --partial "Argo CD namespace on hub: openshift-gitops (from its platform; GWAPI_ARGOCD_NAMESPACE sets it)"
	grep -q -- '--context=hub .*-n openshift-gitops get applicationsets.argoproj.io mesh-verify-gwapi' "$STUB_LOG"
	grep -q '^# ARGOCD=read from hub: 2 Application(s) of openshift-gitops/mesh-verify-gwapi' "$(tsv)"
	git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1 || skip "not a git checkout"
	case "$(source "${ROOT}/tests/lib/common.sh"; source "${ROOT}/tests/lib/preamble.sh"; harness_sha)" in
	"" | unknown) skip "git describe does not work here" ;;
	*-dirty*) expect=same-dirty ;;
	*) expect=same ;;
	esac
	grep -qx "# CHART_REVISION_VS_HARNESS=${expect}" "$(tsv)"
	refute_output --partial "Argo CD synced the chart from"
	grep -q "vs the script's commit: ${expect}" "$(summary)"
}

@test "gateway-api run: --ingress replaces the LoadBalancer read and GWAPI_INGRESS, recorded as an override with its port only; a --config file is recorded and copied" {
	# reprobe503: GWAPI_INGRESS=ctx-b=192.0.2.99, --ingress ctx-a=192.0.2.1, --skip-proxy-config.
	use reprobe503
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
	# reprobe-gone: --config smoke.env and --ingress ctx-a=192.0.2.1:8080: the port is kept, the
	# host is not; the config is copied into the run directory.
	use reprobe-gone
	assert_success
	grep -qx '# INGRESS_ADDRESS_SOURCE\[ctx-a\]=override:port=8080' "$(tsv)"
	grep -qx '# RUN_CONFIG=tests/gateway-api/configs/smoke.env' "$(tsv)"
	ls "$OUT"/run-*/run-config-*.env
	grep -q 'run-config-' "$(summary)"
	no_addresses
}

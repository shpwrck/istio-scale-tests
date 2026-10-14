#!/usr/bin/env bats
# tests/gateway-api/001-run-ingress-check.sh (Gateway API multicluster ingress check) through
# its real entrypoint (PL33): flags and --help, the dry run, the chart <-> prediction-table
# contract, and whole runs against stub kubectl/curl/istioctl: the three Service answers, the
# namespace answers (S7-S9) and their invalid-precondition rows, the not-deployed stops,
# STATUS_TIMEOUT (PL23), an unreachable ingress, best-effort steps that fail without killing the
# run (PL40), one preamble key set for every output (PL19, PL36), and no address in any output.
# Stub addresses are documentation addresses (192.0.2.0/24).

bats_require_minimum_version 1.5.0
load test_helper

GW="${ROOT}/tests/gateway-api/001-run-ingress-check.sh"
CHART="${ROOT}/charts/mesh-verify-gateway-api"

setup() {
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: >"$EK"
	BIN="${BATS_TEST_TMPDIR}/bin"
	OUT="${BATS_TEST_TMPDIR}/results"
	mkdir -p "$BIN"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log" STUB_CURL_LOG="${BATS_TEST_TMPDIR}/curl.log"
	: >"$STUB_LOG"
	: >"$STUB_CURL_LOG"

	# kubectl: ctx-a has no workload, ctx-b runs it (echo text member-b) and alone has the S7-S9
	# backend namespace; hub is the ACM hub. STUB_NO_NS=<ctx>: the test namespace is missing there.
	# STUB_NO_REMOTE_NS=1: the backend namespace is missing on ctx-b. STUB_REMOTE_NS_A=present|fail:
	# ctx-a has it too, or its read fails. STUB_NOSTATUS=<route>: that route has no status on ctx-a.
	# STUB_HUB_FAIL=1: hub reads fail. Anything else fails.
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
nf() { echo "Error from server (NotFound): $1 not found" >&2; exit 1; }
route() {
	if [[ "$1" == "${STUB_NOSTATUS:-}" && "$ctx" == ctx-a ]]; then
		printf '{"metadata":{"name":"%s","generation":1},"status":{}}' "$1"
		return
	fi
	printf '{"metadata":{"name":"%s","generation":1},"status":{"parents":[{"controllerName":"istio.io/gateway-controller","parentRef":{"name":"mesh-verify-gwapi"},"conditions":[{"type":"Accepted","status":"True","reason":"Accepted","observedGeneration":1},{"type":"ResolvedRefs","status":"%s","reason":"%s","observedGeneration":1}]}]}}' "$1" "$2" "$3"
}
if [[ "$ctx" == hub ]]; then
	[[ -z "${STUB_HUB_FAIL:-}" ]] || { echo "Unable to connect to the server: dial tcp 192.0.2.50:6443: i/o timeout" >&2; exit 1; }
	case "$cmd" in
	"-n openshift-gitops get applicationsets.argoproj.io mesh-verify-gwapi -o json")
		echo '{"spec":{"template":{"spec":{"source":{"helm":{"valuesObject":{"workloadCluster":"member-b"}}}}}}}' ;;
	"-n openshift-gitops get applications.argoproj.io -o json")
		echo '{"items":[
			{"metadata":{"name":"member-a-mesh-verify-gwapi","ownerReferences":[{"kind":"ApplicationSet","name":"mesh-verify-gwapi"}]},"spec":{"destination":{"name":"member-a"}},
			 "status":{"health":{"status":"Degraded"},"sync":{"status":"Synced","revision":"0123456789abcdef0123"},"resources":[{"kind":"HTTPRoute","name":"s2","health":{"status":"Degraded"}},{"kind":"HTTPRoute","name":"s3","health":{"status":"Healthy"}}]}},
			{"metadata":{"name":"member-b-mesh-verify-gwapi","ownerReferences":[{"kind":"ApplicationSet","name":"mesh-verify-gwapi"}]},"spec":{"destination":{"name":"member-b"}},
			 "status":{"health":{"status":"Healthy"},"sync":{"status":"Synced","revision":"0123456789abcdef0123"}}},
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
	echo '{"metadata":{"labels":{"istio-discovery":"enabled","istio.io/rev":"default"}}}' ;;
"get namespace mesh-verify-gwapi-remote -o json")
	if [[ "$ctx" == ctx-a && "${STUB_REMOTE_NS_A:-}" == fail ]]; then
		echo "Unable to connect to the server: dial tcp 192.0.2.60:6443: i/o timeout" >&2
		exit 1
	fi
	if [[ "$ctx" == ctx-b && -z "${STUB_NO_REMOTE_NS:-}" ]] || [[ "$ctx" == ctx-a && "${STUB_REMOTE_NS_A:-}" == present ]]; then
		echo '{"metadata":{"labels":{"istio-discovery":"enabled","istio.io/rev":"default"}}}'
	else
		nf 'namespaces "mesh-verify-gwapi-remote"'
	fi ;;
"-n istio-system get gateways.gateway.networking.k8s.io mesh-verify-gwapi -o json")
	echo '{"metadata":{"generation":1},"status":{"conditions":[{"type":"Programmed","status":"True","reason":"Programmed","observedGeneration":1}]}}' ;;
"-n istio-system get deploy -l app=istiod -o json")
	echo '{"items":[{"spec":{"template":{"spec":{"containers":[{"name":"discovery","env":[{"name":"PILOT_ENABLE_GATEWAY_API","value":"true"}]}]}}}}]}' ;;
"get istios.sailoperator.io default -o json") echo '{"spec":{"version":"v1.30.5"}}' ;;
"-n mesh-verify-gwapi get deploy -l app=gwapi-echo -o json" | "-n mesh-verify-gwapi-remote get deploy -l app=gwapi-echo -o json")
	if [[ "$ctx" == ctx-b && ( "$cmd" != *-remote* || -z "${STUB_NO_REMOTE_NS:-}" ) ]]; then
		echo '{"items":[{"spec":{"replicas":1,"template":{"spec":{"containers":[{"name":"http-echo","args":["-listen=:8080","-text=member-b"]}]}}},"status":{"readyReplicas":1}}]}'
	else
		echo '{"items":[]}'
	fi ;;
"-n mesh-verify-gwapi get pods -l app=gwapi-echo -o json" | "-n mesh-verify-gwapi-remote get pods -l app=gwapi-echo -o json")
	if [[ "$ctx" == ctx-b && ( "$cmd" != *-remote* || -z "${STUB_NO_REMOTE_NS:-}" ) ]]; then
		echo '{"items":[{"spec":{"containers":[{"name":"http-echo"}],"initContainers":[{"name":"istio-proxy"}]}}]}'
	else
		echo '{"items":[]}'
	fi ;;
"-n istio-system get svc istio-ingressgateway -o json")
	if [[ "$ctx" == ctx-b ]]; then ip=192.0.2.2; else ip=192.0.2.1; fi
	echo "{\"status\":{\"loadBalancer\":{\"ingress\":[{\"ip\":\"${ip}\"}]}}}" ;;
"-n mesh-verify-gwapi get httproutes.gateway.networking.k8s.io -o json")
	if [[ "$ctx" == ctx-b ]]; then
		printf '{"items":[%s,%s,%s,%s,%s,%s,%s,%s]}\n' "$(route s2 True ResolvedRefs)" "$(route s3 True ResolvedRefs)" \
			"$(route s4 True ResolvedRefs)" "$(route s5 True ResolvedRefs)" "$(route s7 True ResolvedRefs)" \
			"$(route s8 False BackendNotFound)" "$(route c1 False BackendNotFound)" "$(route c2 True ResolvedRefs)"
	else
		printf '{"items":[%s,%s,%s,%s,%s,%s,%s]}\n' "$(route s2 False BackendNotFound)" "$(route s3 True ResolvedRefs)" \
			"$(route s4 True ResolvedRefs)" "$(route s5 False BackendNotFound)" "$(route s7 False RefNotPermitted)" \
			"$(route s8 False BackendNotFound)" "$(route c1 False BackendNotFound)"
	fi ;;
"-n mesh-verify-gwapi get virtualservices.networking.istio.io -o json") echo '{"items":[{"metadata":{"name":"s1"}},{"metadata":{"name":"s9"}}]}' ;;
*) echo "error: stub: unexpected call: $cmd" >&2; exit 1 ;;
esac
STUB

	# curl: 192.0.2.1 = ctx-a's ingress, 192.0.2.2 = ctx-b's; answers as predicted unless
	# STUB_S<n>_OTHER (a code for S2, S3, S7, S8 or S9 through ctx-a) or STUB_DEAD=a (no answer).
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
code=200 body=member-b
case "$host" in
neg.gwapi.test) code=500 body="" ;;
s6.gwapi.test) [[ "$m" == b ]] || { code=404; body=""; } ;;
s2.gwapi.test) [[ "$m" == b || -z "${STUB_S2_OTHER:-}" ]] || { code="$STUB_S2_OTHER"; body="no healthy upstream from 192.0.2.7"; } ;;
s3.gwapi.test) [[ "$m" == b || -z "${STUB_S3_OTHER:-}" ]] || { code="$STUB_S3_OTHER"; body="no healthy upstream"; } ;;
s7.gwapi.test) [[ "$m" == b ]] || { code="${STUB_S7_OTHER:-500}"; [[ "$code" == 200 ]] || body=""; } ;;
s8.gwapi.test) [[ "$m" == b || -z "${STUB_S8_OTHER:-}" ]] || { code="$STUB_S8_OTHER"; body=""; } ;;
s9.classic.test) [[ "$m" == b || -z "${STUB_S9_OTHER:-}" ]] || { code="$STUB_S9_OTHER"; body=""; } ;;
esac
printf '%s\n' "$body" >"$out"
printf '%s' "$code"
STUB

	# istioctl: ctx-b sees the local pod (8080), ctx-a the east-west gateway (15443); echo-none
	# has no endpoints. STUB_ISTIOCTL=fail|hang breaks every proxy-config call.
	cat >"${BIN}/istioctl" <<'STUB'
#!/usr/bin/env bash
case " $* " in *" version "*) echo '{"clientVersion":{"version":"1.30.5"}}'; exit 0 ;; esac
case "${STUB_ISTIOCTL:-}" in
fail) echo "Error: failed to reach the proxy at 192.0.2.8:15000" >&2; exit 1 ;;
hang) exec sleep 30 ;;
esac
ctx="" cluster=""
while (($#)); do
	case "$1" in
	--context) ctx="$2"; shift 2 ;;
	--cluster) cluster="$2"; shift 2 ;;
	*) shift ;;
	esac
done
case "$cluster" in *echo-none*) echo '[]'; exit 0 ;; esac
if [[ "$ctx" == ctx-b ]]; then port=8080; else port=15443; fi
printf '[{"name":"%s","hostStatuses":[{"address":{"socketAddress":{"address":"192.0.2.9","portValue":%d}},"healthStatus":{"edsHealthStatus":"HEALTHY"}}]}]\n' "$cluster" "$port"
STUB
	chmod +x "${BIN}/kubectl" "${BIN}/curl" "${BIN}/istioctl"
}

# gw_run [args...]: a whole run against the stubs (ctx-a, ctx-b; workload ctx-b; hub).
gw_run() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" GWAPI_ISTIOCTL_TIMEOUT_SEC="${GWAPI_ISTIOCTL_TIMEOUT_SEC:-5}" \
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

# no_addresses: no stub address reached any output.
no_addresses() {
	if grep -rE '192\.0\.2\.' "$OUT"; then
		echo "an address reached the output"
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
	for h in s1.classic.test s2.gwapi.test s3.gwapi.test s4.gwapi.test s5.gwapi.test s7.gwapi.test s8.gwapi.test \
		s9.classic.test neg.gwapi.test s6.gwapi.test; do
		assert_output --partial "$h"
	done
	assert_output --partial "backend namespace mesh-verify-gwapi-remote on ci-b only"
	assert_output --partial "Service mesh-verify-gwapi-remote/echo-s7"
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
	# The S7-S9 backend namespace must be another namespace than the routes'.
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" GWAPI_REMOTE_NAMESPACE=mesh-verify-gwapi \
		run bash "$GW" --dry-run --contexts ctx-a,ctx-b --workload-context ctx-b
	assert_failure
	assert_output --partial "GWAPI_REMOTE_NAMESPACE must differ from GWAPI_NAMESPACE"
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

# predicted <role>: the same lines from the script's SCENARIOS table. The test namespace is on
# every member; the backend namespace, both echo Deployments and the grants on the workload
# member only. A Service exists on the workload member for every scenario that answers 200 there,
# and on another member exactly when the table predicts a resolved Service-like backend there
# (the S3 stub). A cross-namespace kind Service backend gets a grant in its namespace.
predicted() {
	local role="$1" line kind host route bkind backend bns st_w st_o code_w code_o st code ns name
	{
		echo "ns|mesh-verify-gwapi"
		if [[ "$role" == workload ]]; then
			echo "ns|mesh-verify-gwapi-remote"
			echo "deploy|mesh-verify-gwapi/gwapi-echo"
			echo "deploy|mesh-verify-gwapi-remote/gwapi-echo"
		fi
		while IFS= read -r line; do
			IFS='|' read -r _ kind host route bkind backend bns st_w st_o code_w code_o _ <<<"$line"
			if [[ "$role" == workload ]]; then st="$st_w" code="$code_w"; else st="$st_o" code="$code_o"; fi
			ns=mesh-verify-gwapi
			[[ "$bns" != remote ]] || ns=mesh-verify-gwapi-remote
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
			*) name="$backend"; [[ "$bns" != remote ]] || name="${ns}/${backend}" ;;
			esac
			echo "${route}|${host}|${bkind}|${name}"
			if [[ "$role" == workload && "$bkind" == Service && "$bns" == remote ]]; then
				echo "grant|${ns}|mesh-verify-gwapi|${backend}"
			fi
		done < <(sed -n 's/^[[:space:]]*"\([SC][0-9]|[^"]*\)"$/\1/p' "$GW" \
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

@test "gateway-api: the chart renders exactly the scenarios the prediction table describes" {
	command -v helm >/dev/null 2>&1 || skip "helm not installed"
	# The table has its ten rows, all routes on the workload member.
	[ "$(predicted workload | grep -vcE '^(svc|ns|deploy|grant)\|')" -eq 10 ]
	diff <(rendered member-b) <(predicted workload)
	diff <(rendered member-a) <(predicted other)
	# The backend namespace and everything in it are on the workload member only.
	rendered member-b | grep -qx 'grant|mesh-verify-gwapi-remote|mesh-verify-gwapi|echo-s7'
	if rendered member-a | grep -E '^(ns|svc|deploy|grant)\|.*mesh-verify-gwapi-remote'; then
		echo "the backend namespace reached a member without the workload"
		false
	fi
	# The S3 stub on another member is byte-identical to the workload's Service.
	[ -n "$(svc_doc member-a echo-s3)" ]
	diff <(svc_doc member-a echo-s3) <(svc_doc member-b echo-s3)
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
	run helm template t "$CHART"
	assert_success
	refute_output --partial "kind: Deployment"
	refute_output --partial "kind: ReferenceGrant"
	refute_output --partial "name: mesh-verify-gwapi-remote"
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

@test "gateway-api run: the predicted world gives NO, every row MATCH, one key set in every output, no address" {
	gw_run --hub-context hub
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: NO"
	assert_output --partial "Local namespace needed on the ingress cluster (backend namespace \`mesh-verify-gwapi-remote\` only on \`ctx-b\`): kind: Service — YES (S7 returned \`500:3\`"
	assert_output --partial "; Hostname — NO (S8 answered 200 from \`ctx-b\` through \`ctx-a\`'s ingress, without \`mesh-verify-gwapi-remote\` there)"
	assert_output --partial "; classic VirtualService — NO (S9 answered 200"
	local t s a
	t="$(tsv)"
	s="$(summary)"
	a="$(ls "$OUT"/run-*/argocd-*.tsv)"
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id"' "$t" | wc -l)" -eq 20 ]
	[ "$(awk -F'\t' -v c="$(col verdict)" '!/^#/ && $1 != "run_id" && $c != "MATCH"' "$t" | wc -l)" -eq 0 ] \
		|| { grep -v '^#' "$t"; false; }
	[ "$(cell ctx-a S2 observed_status)" = "Accepted=True/ResolvedRefs=False:BackendNotFound" ]
	[ "$(cell ctx-a S2 observed_codes)" = "200:3" ]
	[ "$(cell ctx-a S2 body_match)" = yes ]
	[ "$(cell ctx-a S2 observed_endpoints)" = "remote-ewgw:15443" ]
	[ "$(cell ctx-b S2 observed_endpoints)" = local-pod ]
	[ "$(cell ctx-a C1 observed_codes)" = "500:3" ]
	[ "$(cell ctx-a C2 observed_status)" = absent ]
	[ "$(cell ctx-a C2 observed_codes)" = "404:3" ]
	# The namespace scenarios: S7 needs the grant (so the namespace), S8 and S9 do not.
	[ "$(cell ctx-a S7 backend)" = "Service mesh-verify-gwapi-remote/echo-s7" ]
	[ "$(cell ctx-a S7 observed_status)" = "Accepted=True/ResolvedRefs=False:RefNotPermitted" ]
	[ "$(cell ctx-a S7 observed_codes)" = "500:3" ]
	[ "$(cell ctx-a S7 observed_endpoints)" = "remote-ewgw:15443" ]
	[ "$(cell ctx-b S7 observed_status)" = "Accepted=True/ResolvedRefs=True" ]
	[ "$(cell ctx-b S8 observed_status)" = "Accepted=True/ResolvedRefs=False:BackendNotFound" ]
	[ "$(cell ctx-a S8 observed_codes)" = "200:3" ]
	[ "$(cell ctx-a S8 body_match)" = yes ]
	[ "$(cell ctx-a S9 observed_codes)" = "200:3" ]
	[ "$(cell ctx-a S9 backend)" = "Service mesh-verify-gwapi-remote/echo-s9" ]
	# Provenance: live state per member (PL39), the run config, the expected body.
	grep -qx '# GATEWAYCLASS\[ctx-a\]=istio.io/gateway-controller;Accepted=True' "$t"
	grep -qx '# ISTIOD_ENV\[ctx-b\]=PILOT_ENABLE_GATEWAY_API=true;ENABLE_GATEWAY_API_MANUAL_DEPLOYMENT=unset;PILOT_FILTER_GATEWAY_CLUSTER_CONFIG=unset;ENABLE_MCS_HOST=unset;ENABLE_MCS_SERVICE_DISCOVERY=unset' "$t"
	grep -qx '# ECHO_DEPLOYMENT\[ctx-b\]=ready=1/1;sidecar=yes' "$t"
	grep -qx '# ECHO_DEPLOYMENT\[ctx-a\]=absent;sidecar=no-pods' "$t"
	grep -qx '# REMOTE_NAMESPACE=mesh-verify-gwapi-remote' "$t"
	grep -qx '# REMOTE_NAMESPACE_LABELS\[ctx-a\]=absent' "$t"
	grep -qx '# REMOTE_NAMESPACE_LABELS\[ctx-b\]=istio-discovery=enabled;istio.io/rev=default' "$t"
	grep -qx '# ECHO_REMOTE_DEPLOYMENT\[ctx-b\]=ready=1/1;sidecar=yes' "$t"
	grep -qx '# GATEWAY_PROGRAMMED\[ctx-a\]=True' "$t"
	grep -qx '# EXPECTED_BODY=member-b' "$t"
	grep -qx '# INGRESS_ADDRESS_SOURCE\[ctx-a\]=lb-status' "$t"
	grep -qx '# RUN_CONFIG=none' "$t"
	grep -qx '# WORKLOAD_CLUSTER=member-b' "$t"
	# PL36 + PL19: the Argo TSV and the summary's frontmatter carry the TSV's key set.
	diff <(preamble_keys "$t") <(preamble_keys "$a")
	diff <(preamble_keys "$t") <(preamble_keys "$s")
	# Argo CD: only the ApplicationSet's Applications, with the workload member's role.
	[ "$(grep -vc '^#\|^run_id' "$a")" -eq 2 ]
	grep -q $'\tmember-b-mesh-verify-gwapi\tmember-b\tworkload\tHealthy\tSynced\t0123456789ab\t-$' "$a"
	grep -q $'\tmember-a-mesh-verify-gwapi\tmember-a\tother\tDegraded\tSynced\t0123456789ab\ts2=Degraded,s3=Healthy$' "$a"
	grep -qx '# CHART_REVISION=0123456789ab' "$t"
	# The summary leads with the two answers.
	[ "$(grep -v '^"\|^---\|^#\|^$' "$s" | head -1)" = "$(grep -m1 'Service needed' "$s")" ]
	[ "$(grep -v '^"\|^---\|^#\|^$' "$s" | sed -n 2p)" = "$(grep -m1 'Local namespace needed' "$s")" ]
	grep -q '| Run config | `none` (sha256 `none`) |' "$s"
	# No address reaches any output.
	no_addresses
}

@test "gateway-api run: S2 failing while the S3 stub works gives YES; both failing gives INCONCLUSIVE" {
	STUB_S2_OTHER=500 gw_run
	assert_success
	assert_output --partial "Service needed in every cluster for HTTPRoute traffic: YES"
	[ "$(cell ctx-a S2 verdict)" = DEVIATION ]
	[ "$(cell ctx-a S3 verdict)" = MATCH ]
	# The answering body is in the row, its address masked.
	grep -q 'HTTP: expected 200 on all 3, got 500:3 (most frequent body: no healthy upstream from <ip>)' "$(tsv)"
	no_addresses
	rm -rf "$OUT"
	STUB_S2_OTHER=503 STUB_S3_OTHER=503 gw_run
	assert_success
	assert_output --partial "INCONCLUSIVE"
	assert_output --partial "the cross-cluster path itself is broken"
}

@test "gateway-api run: S7 answering gives kind Service NO; S8 failing while S9 answers gives Hostname YES; all three failing is a broken path" {
	STUB_S7_OTHER=200 STUB_S8_OTHER=500 gw_run
	assert_success
	assert_output --partial "kind: Service — NO (S7 answered 200 from \`ctx-b\` through \`ctx-a\`'s ingress"
	assert_output --partial "Hostname — YES (S8 returned \`500:3\` through \`ctx-a\`'s ingress, while S9, with the backend in the same namespace, answered 200)"
	assert_output --partial "classic VirtualService — NO"
	[ "$(cell ctx-a S7 verdict)" = DEVIATION ]
	[ "$(cell ctx-a S8 verdict)" = DEVIATION ]
	# The Service answer does not depend on the namespace scenarios.
	assert_output --partial "traffic: NO"
	rm -rf "$OUT"
	STUB_S7_OTHER=503 STUB_S8_OTHER=503 STUB_S9_OTHER=503 gw_run
	assert_success
	assert_output --partial "kind: Service — INCONCLUSIVE (S7 and S8/S9 all failed through \`ctx-a\`: the path to \`mesh-verify-gwapi-remote\` itself is broken"
	assert_output --partial "Hostname — INCONCLUSIVE"
	assert_output --partial "classic VirtualService — INCONCLUSIVE"
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
	assert_output --partial "kind: Service — INCONCLUSIVE (\`ctx-a\` has a \`mesh-verify-gwapi-remote\` namespace itself)"
	assert_output --partial "traffic: NO"
	grep -qx '# REMOTE_NAMESPACE_LABELS\[ctx-a\]=istio-discovery=enabled;istio.io/rev=default' "$(tsv)"
	rm -rf "$OUT"
	# A failed read is not "absent": the rows say NS_SCENARIO_UNVERIFIED (PL39).
	STUB_REMOTE_NS_A=fail gw_run
	assert_success
	[ "$(cell ctx-a S7 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S7 row_status)" == *NS_SCENARIO_UNVERIFIED* ]]
	grep -qx '# REMOTE_NAMESPACE_LABELS\[ctx-a\]=unknown' "$(tsv)"
	assert_output --partial "could not read whether \`ctx-a\` has a \`mesh-verify-gwapi-remote\` namespace"
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
	# The S7-S9 backend namespace missing on the workload member (an older chart revision).
	STUB_NO_REMOTE_NS=1 gw_run
	assert_failure
	assert_output --partial "ctx-b (--workload-context): namespace mesh-verify-gwapi-remote (the S7-S9 backends) is missing"
	[ ! -e "$OUT" ]
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

@test "gateway-api run: an ingress that never answers is UNKNOWN (INGRESS_UNREACHABLE), and the answer INCONCLUSIVE" {
	STUB_DEAD=a gw_run
	assert_success
	[ "$(cell ctx-a S2 verdict)" = UNKNOWN ]
	[[ "$(cell ctx-a S2 row_status)" == *INGRESS_UNREACHABLE* ]]
	[ "$(cell ctx-b S2 verdict)" = MATCH ]
	assert_output --partial "INCONCLUSIVE"
	no_addresses
}

@test "gateway-api run: failing istioctl and Argo CD reads do not kill the run; the reasons are shown (PL40)" {
	STUB_ISTIOCTL=fail STUB_HUB_FAIL=1 gw_run --hub-context hub
	assert_success
	assert_output --partial "the Argo CD health read failed"
	assert_output --partial "could not read ApplicationSet openshift-gitops/mesh-verify-gwapi on hub"
	assert_output --partial "istioctl on ctx-a for echo-s2: exit 1"
	[ "$(cell ctx-a S2 observed_endpoints)" = unknown ]
	[[ "$(cell ctx-a S2 row_status)" == *PROXY_CONFIG_FAILED* ]]
	[ "$(cell ctx-a S2 verdict)" = MATCH ]
	ls "$OUT"/run-*/argocd-*.tsv 2>/dev/null && false
	grep -q '^# ARGOCD=failed on hub' "$(tsv)"
	grep -qx '# CHART_REVISION=unknown' "$(tsv)"
	assert_output --partial "traffic: NO"
	no_addresses
	# A hanging istioctl is stopped at GWAPI_ISTIOCTL_TIMEOUT_SEC.
	rm -rf "$OUT"
	STUB_ISTIOCTL=hang GWAPI_ISTIOCTL_TIMEOUT_SEC=1 gw_run
	assert_success
	[ "$(cell ctx-a S2 observed_endpoints)" = timeout ]
	[[ "$(cell ctx-a S2 row_status)" == *PROXY_CONFIG_FAILED* ]]
}

@test "gateway-api run: --ingress replaces the LoadBalancer read and is recorded as an override" {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" GWAPI_INGRESS=ctx-b=192.0.2.99 \
		run bash "$GW" --contexts ctx-a,ctx-b --workload-context ctx-b --requests 2 --wait-timeout 0 \
		--skip-proxy-config --results-dir "$OUT" --ingress ctx-a=192.0.2.1
	assert_success
	# The first --ingress replaced GWAPI_INGRESS, so ctx-b kept its LoadBalancer address.
	grep -qx '# INGRESS_ADDRESS_SOURCE\[ctx-a\]=override' "$(tsv)"
	grep -qx '# INGRESS_ADDRESS_SOURCE\[ctx-b\]=lb-status' "$(tsv)"
	grep -q '^http://192.0.2.1/ ' "$STUB_CURL_LOG"
	if grep -q '192.0.2.99' "$STUB_CURL_LOG"; then echo "GWAPI_INGRESS was used despite --ingress"; false; fi
	[ "$(cell ctx-a S2 observed_endpoints)" = skipped ]
	no_addresses
}

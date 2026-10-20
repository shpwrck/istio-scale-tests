#!/usr/bin/env bats
# tests/lib/platform.sh (the member platform and the suite charts' OpenShift overlay):
# platform_of over a fake kubectl (an OpenShift and a Kubernetes API version list,
# lookalike groups, an unreachable member), the TEST_PLATFORM override and its check,
# platform_chart_args (the overlay on OpenShift only, the offline dry-run, a chart without
# an overlay), the suite charts' two renders, and the 001 setup scripts that call it (PL33);
# the platform record: platform_probe, the reports' merge, the --resume and drift checks.
# No cluster: the fake kubectl answers from the test, and the entrypoint runs use an empty
# kubeconfig.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/platform.sh"
source "${ROOT}/tests/lib/reach.sh"  # reach_sanitize (platform_probe's warnings)
source "${ROOT}/tests/lib/config.sh"  # _config_sha256 (platform_probe's istiod env digest)
# What platform_resume_check reads with a source context, and platform_drift_check again.
source "${ROOT}/tests/lib/preamble.sh"  # tuning_baseline_state, probe_kube_versions, infra_preamble_lines
source "${ROOT}/tests/lib/capacity.sh"  # cap_istiod_limits, cap_node_totals
source "${ROOT}/tests/lib/envelope.sh"  # env_collect_infra

SUITES=(propagation churn churn-dataplane controlplane dataplane)

# _fake_kubectl: log the call; api-versions answers for FAKE_PLATFORM (kubernetes,
# openshift, lookalike or down).
_fake_kubectl() {
	printf '%s\n' "$*" >> "$CALLS"
	if [[ "${FAKE_PLATFORM:-kubernetes}" == down ]]; then
		echo "error: Unable to connect to the server: dial tcp 192.0.2.10:6443: i/o timeout" >&2
		return 1
	fi
	case " $* " in
	*" api-versions "*)
		printf '%s\n' admissionregistration.k8s.io/v1 apps/v1 gateway.networking.k8s.io/v1 v1
		if [[ "${FAKE_PLATFORM:-}" == openshift ]]; then
			printf '%s\n' route.openshift.io/v1 security.openshift.io/v1
		elif [[ "${FAKE_PLATFORM:-}" == lookalike ]]; then
			# A CRD group that only contains the name is not OpenShift.
			printf '%s\n' security.openshift.io/v1beta1 x.security.openshift.io/v1
		fi
		;;
	*) return 1 ;;
	esac
}

setup() {
	export CALLS="${BATS_TEST_TMPDIR}/calls.log"
	: > "$CALLS"
	KUBECTL=(_fake_kubectl)
	DRY_RUN=0
	unset TEST_PLATFORM FAKE_PLATFORM
	CHART="${BATS_TEST_TMPDIR}/chart"
	mkdir -p "$CHART"
	: > "${CHART}/values-openshift.yaml"
}

# ---------------------------------------------------------------------------
# platform_of
# ---------------------------------------------------------------------------

@test "platform_of: auto asks the member once and finds OpenShift by security.openshift.io/v1" {
	FAKE_PLATFORM=openshift run platform_of member-a
	assert_success
	assert_output openshift
	[ "$(wc -l < "$CALLS")" -eq 1 ]
	grep -q -- '--context=member-a' "$CALLS"
	grep -q ' api-versions$' "$CALLS"
}

@test "platform_of: auto on Kubernetes, lookalike groups included, is kubernetes" {
	FAKE_PLATFORM=kubernetes run platform_of member-a
	assert_success
	assert_output kubernetes
	FAKE_PLATFORM=lookalike run platform_of member-a
	assert_success
	assert_output kubernetes
}

@test "platform_of: a member it cannot ask is an error naming it, never a guess" {
	FAKE_PLATFORM=down run --separate-stderr platform_of member-b
	assert_failure 1
	[ -z "$output" ]
	[[ "$stderr" == *"cannot list the API versions of context member-b"* ]]
	[[ "$stderr" == *"set TEST_PLATFORM to skip the check"* ]]
	[[ "$stderr" == *"i/o timeout"* ]]
}

@test "platform_of: TEST_PLATFORM kubernetes or openshift is used as is, with no cluster call" {
	TEST_PLATFORM=openshift FAKE_PLATFORM=down run platform_of member-a
	assert_success
	assert_output openshift
	TEST_PLATFORM=kubernetes FAKE_PLATFORM=openshift run platform_of member-a
	assert_success
	assert_output kubernetes
	[ ! -s "$CALLS" ]
}

@test "platform_of: any other TEST_PLATFORM is an error before any cluster call" {
	TEST_PLATFORM=OpenShift run --separate-stderr platform_of member-a
	assert_failure 1
	[[ "$stderr" == *"TEST_PLATFORM must be auto, kubernetes or openshift (got: OpenShift)"* ]]
	TEST_PLATFORM=k8s run platform_of member-a
	assert_failure 1
	[ ! -s "$CALLS" ]
}

# ---------------------------------------------------------------------------
# platform_chart_args
# ---------------------------------------------------------------------------

@test "platform_chart_args: the overlay on OpenShift, nothing on Kubernetes" {
	local a=(stale)
	FAKE_PLATFORM=openshift platform_chart_args "$CHART" member-a a
	[ "${#a[@]}" -eq 2 ]
	[ "${a[0]}" = -f ]
	[ "${a[1]}" = "${CHART}/values-openshift.yaml" ]
	a=(stale)
	FAKE_PLATFORM=kubernetes platform_chart_args "$CHART" member-a a
	[ "${#a[@]}" -eq 0 ]
}

@test "platform_chart_args: an unreachable member fails and leaves the array empty" {
	local a=(stale)
	FAKE_PLATFORM=down run platform_chart_args "$CHART" member-b a
	assert_failure 1
	assert_output --partial "cannot list the API versions of context member-b"
	FAKE_PLATFORM=down platform_chart_args "$CHART" member-b a 2>/dev/null || true
	[ "${#a[@]}" -eq 0 ]
}

@test "platform_chart_args: a dry-run with auto asks no cluster; an explicit platform still renders" {
	local a=(stale)
	DRY_RUN=1
	FAKE_PLATFORM=openshift platform_chart_args "$CHART" member-a a
	[ "${#a[@]}" -eq 0 ]
	[ ! -s "$CALLS" ]
	TEST_PLATFORM=openshift platform_chart_args "$CHART" member-a a
	[ "${a[*]}" = "-f ${CHART}/values-openshift.yaml" ]
	[ ! -s "$CALLS" ]
}

@test "platform_chart_args: an OpenShift member and a chart without the overlay is an error" {
	local a=()
	rm "${CHART}/values-openshift.yaml"
	TEST_PLATFORM=openshift run platform_chart_args "$CHART" member-a a
	assert_failure 1
	assert_output --partial "has no values-openshift.yaml for OpenShift member member-a"
}

# ---------------------------------------------------------------------------
# The suite charts
# ---------------------------------------------------------------------------

# full_render_args <suite>: --set args that render every template with a container.
full_render_args() {
	case "$1" in
	propagation) echo "--set clusterName=member-a --set backer.enabled=true" ;;
	churn-dataplane) echo "--set clusterName=member-a --set fortioRole=both --set allClusterNames[0]=member-a" ;;
	dataplane) echo "--set clusterName=member-a --set role=both --set allClusterNames[0]=member-a" ;;
	*) echo "--set clusterName=member-a" ;;
	esac
}

@test "suite charts: every runAsNonRoot container gets the numeric UID; values-openshift.yaml drops it" {
	command -v helm >/dev/null 2>&1 || skip "helm not installed"
	local s c k8s ocp n
	for s in "${SUITES[@]}"; do
		c="${ROOT}/tests/${s}/chart"
		[ -f "${c}/values-openshift.yaml" ] || { echo "$s: no values-openshift.yaml"; false; }
		# shellcheck disable=SC2046
		k8s="$(helm template t "$c" $(full_render_args "$s"))"
		# shellcheck disable=SC2046
		ocp="$(helm template t "$c" -f "${c}/values-openshift.yaml" $(full_render_args "$s"))"
		n="$(grep -c 'runAsNonRoot: true' <<<"$k8s")"
		((n > 0)) || { echo "$s: no runAsNonRoot container rendered"; false; }
		[ "$(grep -c 'runAsUser: 65534$' <<<"$k8s")" -eq "$n" ] || { echo "$s: $n runAsNonRoot, not as many runAsUser: 65534"; false; }
		[ "$(grep -c 'runAsNonRoot: true' <<<"$ocp")" -eq "$n" ] || { echo "$s: the overlay changed runAsNonRoot"; false; }
		! grep -q 'runAsUser' <<<"$ocp" || { echo "$s: the OpenShift render keeps a runAsUser"; false; }
		# The overlay removes those lines and changes nothing else.
		diff <(grep -v '^ *runAsUser: 65534$' <<<"$k8s") <(printf '%s\n' "$ocp") || { echo "$s: the overlay changes more than runAsUser"; false; }
	done
}

# ---------------------------------------------------------------------------
# The 001 setup scripts (PL33)
# ---------------------------------------------------------------------------

@test "001 setup scripts: each sources platform.sh and every chart render takes its overlay args" {
	local s f renders wired
	for s in "${SUITES[@]}"; do
		f="$(ls "${ROOT}/tests/${s}"/001-*.sh)"
		grep -q 'source "${ROOT}/tests/lib/platform.sh"' "$f" || { echo "$f: does not source platform.sh"; false; }
		renders="$(grep -cE 'helm template [a-z-]+ "\$CHART_DIR"' "$f")"
		wired="$(grep -cE 'helm template [a-z-]+ "\$CHART_DIR" \$\{[A-Za-z_]+\[@\]\+"\$\{[A-Za-z_]+\[@\]\}"\}' "$f")"
		((renders > 0)) || { echo "$f: no chart render found"; false; }
		[ "$wired" -eq "$renders" ] || { echo "$f: $renders chart render(s), $wired with the platform args"; false; }
		[ "$(grep -c 'platform_chart_args "\$CHART_DIR"' "$f")" -ge "$renders" ] || { echo "$f: fewer platform_chart_args calls than renders"; false; }
	done
}

@test "controlplane 001: every overlay is resolved before the first apply and its t0" {
	# A platform read inside an apply would land in that apply's ns-lifecycle duration, and a
	# member it cannot tell would fail after others were already applied.
	local f="${ROOT}/tests/controlplane/001-setup-controlplane-test.sh" call pids t0
	call="$(grep -n 'platform_chart_args "\$CHART_DIR"' "$f" | cut -d: -f1)"
	pids="$(grep -n '^APPLY_PIDS=()' "$f" | cut -d: -f1)"
	t0="$(grep -n 't0="\$(now_ms)"' "$f" | head -n 1 | cut -d: -f1)"
	[ "$(wc -l <<<"$call")" -eq 1 ] || { echo "platform_chart_args at lines: $call"; false; }
	((call < pids && pids < t0)) || { echo "platform_chart_args at $call, APPLY_PIDS=() at $pids, the first t0 at $t0"; false; }
}

# helm_spy: a helm on PATH that logs its args, then runs the real one.
helm_spy() {
	local real
	real="$(command -v helm)"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export HELM_LOG="${BATS_TEST_TMPDIR}/helm.log"
	: > "$HELM_LOG"
	printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$HELM_LOG"' "exec \"${real}\" \"\$@\"" > "${BIN}/helm"
	chmod +x "${BIN}/helm"
}

@test "001 dry-runs (churn, churn-dataplane, controlplane): the overlay with TEST_PLATFORM=openshift only" {
	command -v helm >/dev/null 2>&1 || skip "helm not installed"
	command -v kubectl >/dev/null 2>&1 || command -v oc >/dev/null 2>&1 || skip "kubectl not installed"
	local ek="${BATS_TEST_TMPDIR}/kubeconfig" s cmd
	: > "$ek"
	helm_spy
	for s in churn churn-dataplane controlplane; do
		case "$s" in
		churn) cmd=(bash "${ROOT}/tests/churn/001-setup-churn-test.sh" --dry-run --contexts ci-a) ;;
		churn-dataplane) cmd=(bash "${ROOT}/tests/churn-dataplane/001-setup-coexec-test.sh" --dry-run --source-context ci-a) ;;
		controlplane) cmd=(bash "${ROOT}/tests/controlplane/001-setup-controlplane-test.sh" --dry-run --contexts ci-a) ;;
		esac
		: > "$HELM_LOG"
		PATH="${BIN}:${PATH}" KUBECONFIG="$ek" TEST_PLATFORM=openshift run "${cmd[@]}"
		assert_success
		grep -q -- "-f ${ROOT}/tests/${s}/chart/values-openshift.yaml" "$HELM_LOG" || { echo "$s: no overlay"; cat "$HELM_LOG"; false; }
		: > "$HELM_LOG"
		PATH="${BIN}:${PATH}" KUBECONFIG="$ek" run "${cmd[@]}"
		assert_success
		grep -q '^template ' "$HELM_LOG" || { echo "$s: no render"; false; }
		! grep -q 'values-openshift.yaml' "$HELM_LOG" || { echo "$s: overlay without TEST_PLATFORM=openshift"; false; }
		PATH="${BIN}:${PATH}" KUBECONFIG="$ek" TEST_PLATFORM=okd run "${cmd[@]}"
		assert_failure
		assert_output --partial "TEST_PLATFORM must be auto, kubernetes or openshift (got: okd)"
	done
}

# ---------------------------------------------------------------------------
# The platform record: platform_probe and its readers
# ---------------------------------------------------------------------------

DIG_A="sha256:$(printf 'a%.0s' {1..64})"
DIG_B="sha256:$(printf 'b%.0s' {1..64})"
DIG_C="sha256:$(printf 'c%.0s' {1..64})"

# _probe_istiod_pod <ctx> <name> <phase> <imageID|-> [image] [PILOT_PUSH_THROTTLE]: one istiod pod
# (CLUSTER_ID is its member, as on a real one); "-": no containerStatuses yet (just scheduled).
_probe_istiod_pod() {
	local st=""
	[[ "$4" == - ]] || st=",\"containerStatuses\":[{\"name\":\"discovery\",\"imageID\":\"$4\",\"restartCount\":0}]"
	printf '{"metadata":{"name":"%s","labels":{"app":"istiod"}},"spec":{"containers":[{"name":"discovery","image":"%s","env":[{"name":"CLUSTER_ID","value":"%s"},{"name":"PILOT_PUSH_THROTTLE","value":"%s"},{"name":"POD_NAME","valueFrom":{"fieldRef":{"fieldPath":"metadata.name","apiVersion":"v1"}}}]}]},"status":{"phase":"%s"%s}},' \
		"$2" "${5:-registry.example.invalid/istio/pilot:${PROBE_ISTIOD:-1.30.5}}" "$1" "${6:-${PROBE_ISTIOD_THROTTLE:-100}}" "$3" "$st"
}

# _probe_kubectl: one member for platform_probe; PROBE_PLATFORM picks it: kubernetes (default),
# openshift, down (no answer) or forbidden (api-versions refused, the rest answers). PROBE_SAIL
# empty: nothing in the Sail namespace; PROBE_SAIL_PODS: the operator's pod runs (running, the
# default), is Pending without an imageID (pending), is not there (none: scaled to 0), or there
# is none and the Deployment pins a digest (pinned); PROBE_SAIL_AVAILABLE its available replicas.
# PROBE_CSV other: no servicemeshoperator3 CSV. PROBE_EWGW: the east-west gateway pod runs the
# ingress gateway's build (same, default), another one (other, or docker: with a cri-dockerd
# docker://sha256: imageID) or is not there (none); an egress gateway pod never counts.
# PROBE_SAIL_PODS=docker and PROBE_ISTIOD_PODS=docker: those pods report docker:// imageIDs. PROBE_ISTIOD and PROBE_OPERATOR replace istiod's and the Sail
# operator's tag, PROBE_ISTIOD_THROTTLE istiod's PILOT_PUSH_THROTTLE. PROBE_ISTIOD_PODS: one
# running replica (running, the default) and another that is Pending (pending), ContainerCreating
# (creating: an empty imageID), evicted (evicted: Failed, an empty imageID; evicted-old: Failed,
# the old digest), runs another digest (two-digests) or other settings (env-rollout); or only a
# Pending one (only-pending), one whose spec pins PROBE_ISTIOD_PIN (pinned-pending), none (none).
# tuning_baseline_state's reads, NotFound unless --ignore-not-found as with kubectl:
# PROBE_TB_SIDECAR on (default) or off, PROBE_TB_TELEMETRY and PROBE_TB_ACCESS_LOG off (default)
# or on, PROBE_TB_UNSERVED=1 (the member serves none of these kinds), PROBE_TB_DS off (default),
# on or missing (no Istio CR named default), PROBE_TB_HOSTS (the root Sidecar's egress hosts,
# default "istio-system/* ./*"). The once-recorded values 003 reads: PROBE_KUBE_VERSION (default
# v1.33.1; PROBE_KUBE=down: no answer), istiod's Deployment (PROBE_ISTIOD_CPU_LIMIT 2,
# PROBE_ISTIOD_MEM_LIMIT 4Gi, PROBE_ISTIOD_REQ_CPU 500m, PROBE_ISTIOD_REPLICAS 1, PROBE_NETWORK
# net-<ctx>; PROBE_ISTIOD_DEPLOY=missing: none; on the member PROBE_ISTIOD_ON names,
# PROBE_ISTIOD_ON_CPU_LIMIT, PROBE_ISTIOD_ON_MEM_LIMIT, PROBE_ISTIOD_ON_REPLICAS and
# PROBE_ISTIOD_ON_DEPLOY instead), the nodes' allocatable (PROBE_NODE_CPU 8).
# PROBE_TUNING_OBJECTS: the objects labelled by a tuning profile: none (default), 04 (profile 04's
# DestinationRule), two (two profiles' objects, in reverse order), marker (profile 02's marker
# ConfigMap, all an env-only profile leaves), unserved (a kind the member does not serve) or
# timeout (no answer within the request timeout); with PROBE_TUNING_ON, on that member only.
# PROBE_FLAKY: the reads that get no answer the first time on each member, then answer (a read
# that timed out once): kube (the version), sidecar (the root Sidecar's) and istiod (istiod's
# Deployment), comma-separated.
_probe_kubectl() {
	local a ctx="" on img pod pods tobj
	printf '%s\n' "$*" >> "$CALLS"
	for a in "$@"; do [[ "$a" != --context=* ]] || ctx="${a#--context=}"; done
	if [[ "${PROBE_PLATFORM:-kubernetes}" == down ]]; then
		echo "error: Unable to connect to the server: dial tcp 192.0.2.10:6443: i/o timeout" >&2
		return 1
	fi
	case " $* " in
	*" api-versions "*)
		if [[ "${PROBE_PLATFORM:-}" == forbidden ]]; then
			echo 'Error from server (Forbidden): the server does not allow this user to list API versions' >&2
			return 1
		fi
		printf '%s\n' apps/v1 v1
		[[ "${PROBE_PLATFORM:-}" != openshift ]] || printf '%s\n' route.openshift.io/v1 security.openshift.io/v1
		;;
	*" -n sail-operator get deployments.apps,pods "*)
		if [[ "${PROBE_SAIL:-}" == empty ]]; then echo '{"kind":"List","items":[]}'; return 0; fi
		img="registry.example.invalid/sail/sail-operator:${PROBE_OPERATOR:-1.31.1}"
		pod='{"kind":"Pod","metadata":{"name":"sail-operator-1","labels":{"app.kubernetes.io/name":"sail-operator"}},"status":{"phase":"Running","containerStatuses":[{"name":"sail-operator","imageID":"registry.example.invalid/sail/sail-operator@'"${DIG_A}"'"}]}},'
		case "${PROBE_SAIL_PODS:-running}" in
		pending) pod='{"kind":"Pod","metadata":{"name":"sail-operator-1","labels":{"app.kubernetes.io/name":"sail-operator"}},"status":{"phase":"Pending","containerStatuses":[{"name":"sail-operator","imageID":""}]}},' ;;
		docker) pod='{"kind":"Pod","metadata":{"name":"sail-operator-1","labels":{"app.kubernetes.io/name":"sail-operator"}},"status":{"phase":"Running","containerStatuses":[{"name":"sail-operator","imageID":"docker://'"${DIG_A}"'"}]}},' ;;
		none) pod="" ;;
		pinned) pod="" img+="@${DIG_B}" ;;
		esac
		cat <<JSON
{"kind":"List","items":[
 {"kind":"Deployment","metadata":{"name":"sail-operator"},
  "spec":{"selector":{"matchLabels":{"app.kubernetes.io/name":"sail-operator"}},
   "template":{"spec":{"containers":[{"name":"sail-operator","image":"${img}"}]}}},
  "status":{"availableReplicas":${PROBE_SAIL_AVAILABLE:-1}}},
 ${pod}
 {"kind":"Pod","metadata":{"name":"unrelated","labels":{"app":"x"}},
  "status":{"containerStatuses":[{"name":"sail-operator","imageID":"${DIG_C}"}]}}
]}
JSON
		;;
	*" -n openshift-operators get clusterserviceversions.operators.coreos.com "*)
		if [[ "${PROBE_PLATFORM:-}" != openshift ]]; then
			echo "error: the server doesn't have a resource type \"clusterserviceversions\"" >&2
			return 1
		fi
		if [[ "${PROBE_CSV:-}" == other ]]; then
			echo '{"items":[{"metadata":{"name":"other-operator.v1.0.0"},"spec":{"version":"1.0.0"},"status":{"phase":"Succeeded"}}]}'
			return 0
		fi
		echo '{"items":[{"metadata":{"name":"servicemeshoperator3.v3.4.3"},"spec":{"version":"3.4.3"},"status":{"phase":"Succeeded"}},
			{"metadata":{"name":"other-operator.v1.0.0"},"spec":{"version":"1.0.0"},"status":{"phase":"Succeeded"}}]}'
		;;
	*" -n istio-system get pods "*)
		img="registry.example.invalid/istio/pilot@${DIG_B}"
		case "${PROBE_ISTIOD_PODS:-running}" in
		running) pods="$(_probe_istiod_pod "$ctx" istiod-1 Running "$img")" ;;
		pending) pods="$(_probe_istiod_pod "$ctx" istiod-1 Running "$img")$(_probe_istiod_pod "$ctx" istiod-2 Pending -)" ;;
		creating) pods="$(_probe_istiod_pod "$ctx" istiod-1 Running "$img")$(_probe_istiod_pod "$ctx" istiod-2 Pending "")" ;;
		evicted) pods="$(_probe_istiod_pod "$ctx" istiod-0 Failed "")$(_probe_istiod_pod "$ctx" istiod-1 Running "$img")" ;;
		evicted-old) pods="$(_probe_istiod_pod "$ctx" istiod-0 Failed "registry.example.invalid/istio/pilot@${DIG_A}")$(_probe_istiod_pod "$ctx" istiod-1 Running "$img")" ;;
		two-digests) pods="$(_probe_istiod_pod "$ctx" istiod-1 Running "$img")$(_probe_istiod_pod "$ctx" istiod-2 Running "registry.example.invalid/istio/pilot@${DIG_A}")" ;;
		env-rollout) pods="$(_probe_istiod_pod "$ctx" istiod-1 Running "$img")$(_probe_istiod_pod "$ctx" istiod-2 Running "$img" "" 50)" ;;
		only-pending) pods="$(_probe_istiod_pod "$ctx" istiod-1 Pending -)" ;;
		pinned-pending) pods="$(_probe_istiod_pod "$ctx" istiod-1 Pending - "registry.example.invalid/istio/pilot:1.30.5@${PROBE_ISTIOD_PIN:-$DIG_B}")" ;;
		docker) pods="$(_probe_istiod_pod "$ctx" istiod-1 Running "docker://${DIG_B}")" ;;
		none) pods="" ;;
		esac
		cat <<JSON
{"kind":"List","items":[ ${pods}
 {"metadata":{"name":"ingress-1","labels":{"istio":"ingressgateway"}},
  "spec":{"containers":[{"name":"istio-proxy","image":"registry.example.invalid/istio/proxyv2:1.30.5"}]},
  "status":{"phase":"Running","containerStatuses":[{"name":"istio-proxy","imageID":"${DIG_C}","restartCount":0}]}},
 {"metadata":{"name":"egress-1","labels":{"istio":"egressgateway"}},
  "spec":{"containers":[{"name":"istio-proxy","image":"registry.example.invalid/istio/proxyv2:9.9.9"}]},
  "status":{"phase":"Running","containerStatuses":[{"name":"istio-proxy","imageID":"${DIG_B}","restartCount":0}]}}
JSON
		case "${PROBE_EWGW:-same}" in
		same) printf ',{"metadata":{"name":"eastwest-1","labels":{"istio":"eastwestgateway"}},"spec":{"containers":[{"name":"istio-proxy","image":"registry.example.invalid/istio/proxyv2:1.30.5"}]},"status":{"phase":"Running","containerStatuses":[{"name":"istio-proxy","imageID":"%s","restartCount":0}]}}\n' "$DIG_C" ;;
		other) printf ',{"metadata":{"name":"eastwest-1","labels":{"istio":"eastwestgateway"}},"spec":{"containers":[{"name":"istio-proxy","image":"registry.example.invalid/istio/proxyv2:1.30.6"}]},"status":{"phase":"Running","containerStatuses":[{"name":"istio-proxy","imageID":"%s","restartCount":0}]}}\n' "$DIG_A" ;;
		docker) printf ',{"metadata":{"name":"eastwest-1","labels":{"istio":"eastwestgateway"}},"spec":{"containers":[{"name":"istio-proxy","image":"registry.example.invalid/istio/proxyv2:1.30.6"}]},"status":{"phase":"Running","containerStatuses":[{"name":"istio-proxy","imageID":"docker://%s","restartCount":0}]}}\n' "$DIG_A" ;;
		esac
		echo ']}'
		;;
	*" -n istio-system get sidecar.networking.istio.io default -o name "* | *" -n istio-system get telemetry.telemetry.istio.io "*" -o name "*)
		if [[ " $* " == *" sidecar.networking.istio.io "* ]] && _probe_flaky sidecar "$ctx"; then
			echo 'Unable to connect to the server: net/http: request canceled (Client.Timeout exceeded while awaiting headers)' >&2
			return 1
		fi
		# The kind and the name after "get".
		a="$*"
		a="${a#*" get "}"
		a="${a%%" -o name"*}"
		if ((${PROBE_TB_UNSERVED:-0})); then
			printf '%s\n' "error: the server doesn't have a resource type \"${a%%.*}\"" >&2
			return 1
		fi
		case " $* " in
		*" sidecar.networking.istio.io "*) on="${PROBE_TB_SIDECAR:-on}" ;;
		*" tuning-metrics "*) on="${PROBE_TB_TELEMETRY:-off}" ;;
		*) on="${PROBE_TB_ACCESS_LOG:-off}" ;;
		esac
		if [[ "$on" == on ]]; then
			echo "${a/ //}"
		elif [[ " $* " != *" --ignore-not-found "* ]]; then
			echo "Error from server (NotFound): ${a%% *} \"${a#* }\" not found" >&2
			return 1
		fi
		;;
	*" -n istio-system get sidecar.networking.istio.io default -o jsonpath="*) echo "${PROBE_TB_HOSTS:-istio-system/* ./*}" ;;
	*" get istio.sailoperator.io default "*)
		case "${PROBE_TB_DS:-off}" in
		on) echo '[{"matchLabels":{"istio-discovery":"enabled"}}]' ;;
		missing)
			echo 'Error from server (NotFound): istios.sailoperator.io "default" not found' >&2
			return 1
			;;
		*) echo '[]' ;;
		esac
		;;
	*" version --output=json "*)
		[[ "${PROBE_KUBE:-up}" != down ]] || return 1
		! _probe_flaky kube "$ctx" || return 1
		printf '{"serverVersion":{"gitVersion":"%s"}}\n' "${PROBE_KUBE_VERSION:-v1.33.1}"
		;;
	*" -n istio-system get deploy istiod "*)
		! _probe_flaky istiod "$ctx" || return 1
		local dep="${PROBE_ISTIOD_DEPLOY:-}" lcpu="${PROBE_ISTIOD_CPU_LIMIT:-2}" lmem="${PROBE_ISTIOD_MEM_LIMIT:-4Gi}" rep="${PROBE_ISTIOD_REPLICAS:-1}"
		if [[ -n "${PROBE_ISTIOD_ON:-}" && "$ctx" == "$PROBE_ISTIOD_ON" ]]; then
			dep="${PROBE_ISTIOD_ON_DEPLOY:-$dep}" lcpu="${PROBE_ISTIOD_ON_CPU_LIMIT:-$lcpu}" lmem="${PROBE_ISTIOD_ON_MEM_LIMIT:-$lmem}"
			rep="${PROBE_ISTIOD_ON_REPLICAS:-$rep}"
		fi
		if [[ "$dep" == missing ]]; then
			echo 'Error from server (NotFound): deployments.apps "istiod" not found' >&2
			return 1
		fi
		printf '{"spec":{"replicas":%s,"template":{"spec":{"containers":[{"name":"discovery","env":[{"name":"ISTIO_META_NETWORK","value":"%s"}],"resources":{"requests":{"cpu":"%s","memory":"2Gi"},"limits":{"cpu":"%s","memory":"%s"}}}]}}}}\n' \
			"$rep" "${PROBE_NETWORK:-net-${ctx}}" "${PROBE_ISTIOD_REQ_CPU:-500m}" "$lcpu" "$lmem"
		;;
	*" get ${PLATFORM_TUNING_KINDS} -A -l ${PLATFORM_TUNING_LABEL} "*)
		tobj="${PROBE_TUNING_OBJECTS:-none}"
		[[ -z "${PROBE_TUNING_ON:-}" || "$ctx" == "$PROBE_TUNING_ON" ]] || tobj=none
		case "$tobj" in
		none) echo '{"kind":"List","items":[]}' ;;
		marker) echo '{"kind":"List","items":[{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"tuning-profile-02-xds-cache-off","namespace":"istio-system","labels":{"istio-scale-tests/tuning-profile":"02-xds-cache-off"}}}]}' ;;
		04) echo '{"kind":"List","items":[{"kind":"DestinationRule","metadata":{"name":"tuning-connection-pool","namespace":"istio-system","labels":{"istio-scale-tests/tuning-profile":"04-connection-pools"}}}]}' ;;
		two) echo '{"kind":"List","items":[{"kind":"Sidecar","metadata":{"name":"tuning-x","namespace":"ns-b","labels":{"istio-scale-tests/tuning-profile":"09-x"}}},{"kind":"DestinationRule","metadata":{"name":"tuning-connection-pool","namespace":"istio-system","labels":{"istio-scale-tests/tuning-profile":"04-connection-pools"}}}]}' ;;
		unserved)
			echo "error: the server doesn't have a resource type \"envoyfilters\"" >&2
			return 1
			;;
		timeout)
			echo 'Unable to connect to the server: net/http: request canceled (Client.Timeout exceeded while awaiting headers)' >&2
			return 1
			;;
		esac
		;;
	*" get nodes "*)
		if [[ "${PROBE_PLATFORM:-}" == openshift ]]; then
			echo '{"items":[{"metadata":{"name":"node-0"},"spec":{"providerID":"aws:///zone-a/i-0"},"status":{"allocatable":{"cpu":"8","memory":"16Gi","pods":"110"}}},{"metadata":{"name":"node-1"},"spec":{"providerID":"aws:///zone-b/i-1"},"status":{"allocatable":{"cpu":"8","memory":"16Gi","pods":"110"}}}]}'
		else
			printf '{"items":[{"metadata":{"name":"node-0"},"spec":{"providerID":"kind://docker/lab/node-0"},"status":{"allocatable":{"cpu":"%s","memory":"16Gi","pods":"110"}}}]}\n' "${PROBE_NODE_CPU:-8}"
		fi
		;;
	*) return 1 ;;
	esac
}

# _probe_flaky <read> <ctx>: whether this read gets no answer: PROBE_FLAKY lists it, and it is the
# first such read on the member.
_probe_flaky() {
	[[ ",${PROBE_FLAKY:-}," == *",${1},"* ]] || return 1
	mkdir "${BATS_TEST_TMPDIR}/flaky-${1}-${2//\//_}" 2>/dev/null
}

# probe_setup: a fresh record over _probe_kubectl; warnings go to $WARN.
probe_setup() {
	KUBECTL=(_probe_kubectl)
	unset PLATFORM_PROBE_ROWS PROBE_PLATFORM PROBE_SAIL PROBE_CSV
	WARN="${BATS_TEST_TMPDIR}/warn"
	: > "$WARN"
}

# env_digest <json array>: ISTIOD_ENV_BY_CONTEXT's form of one env list (sorted name=value
# lines without CLUSTER_ID, as one JSON array line): the first 12 hex digits of its sha256.
env_digest() {
	printf '%s\n' "$1" > "${BATS_TEST_TMPDIR}/env-list.txt"
	_config_sha256 "${BATS_TEST_TMPDIR}/env-list.txt" | cut -c1-12
}
# The stub istiod's env: PILOT_PUSH_THROTTLE (100 unless PROBE_ISTIOD_THROTTLE) and POD_NAME from
# a fieldRef (its keys sorted), CLUSTER_ID left out.
env_list() {
	printf '["PILOT_PUSH_THROTTLE=%s","POD_NAME={\\"fieldRef\\":{\\"apiVersion\\":\\"v1\\",\\"fieldPath\\":\\"metadata.name\\"}}"]' "${1:-100}"
}

@test "platform_probe: a Kubernetes member records the Sail operator, the builds that ran and the node provider" {
	probe_setup
	platform_probe member-a 2>"$WARN"
	[ ! -s "$WARN" ] || { cat "$WARN"; false; }
	run platform_preamble_lines member-a
	assert_success
	assert_line "# PLATFORM=kubernetes"
	assert_line "# TEST_PLATFORM=auto"
	assert_line "# PLATFORM_BY_CONTEXT=member-a=kubernetes"
	# The Deployment's tag, the digest of its own pod (not the unrelated one), its state.
	assert_line "# MESH_OPERATOR_BY_CONTEXT=member-a=sail-operator:1.31.1@${DIG_A}/Available"
	assert_line "# ISTIOD_IMAGE_BY_CONTEXT=member-a=pilot:1.30.5@${DIG_B}"
	# A bare sha256 imageID (an image loaded with kind load) is kept.
	assert_line "# PROXY_IMAGE_BY_CONTEXT=member-a=proxyv2:1.30.5@${DIG_C}"
	assert_line "# NODE_PROVIDER_BY_CONTEXT=member-a=kind"
	# istiod's settings: a digest of its discovery env, from the pod list already read.
	assert_line "# ISTIOD_ENV_BY_CONTEXT=member-a=$(env_digest "$(env_list)")"
	# No tuning profile's objects applied.
	assert_line "# TUNING_OBJECTS_BY_CONTEXT=member-a=none"
	refute_output --partial "example.invalid"
	! grep -q 'clusterserviceversions' "$CALLS" || false
	[ "$(wc -l < "$CALLS")" -eq 5 ]
}

@test "platform_probe (R-S3): a docker:// imageID (cri-dockerd, a locally built image) is a started pod's digest, never @unknown" {
	probe_setup
	PROBE_SAIL_PODS=docker PROBE_ISTIOD_PODS=docker PROBE_EWGW=docker platform_probe member-a 2>"$WARN"
	[ ! -s "$WARN" ] || { cat "$WARN"; false; }
	run platform_preamble_lines member-a
	assert_line "# MESH_OPERATOR_BY_CONTEXT=member-a=sail-operator:1.31.1@${DIG_A}/Available"
	assert_line "# ISTIOD_IMAGE_BY_CONTEXT=member-a=pilot:1.30.5@${DIG_B}"
	assert_line "# PROXY_IMAGE_BY_CONTEXT=member-a=proxyv2:1.30.5@${DIG_C}+proxyv2:1.30.6@${DIG_A}"
	assert_line "# ISTIOD_ENV_BY_CONTEXT=member-a=$(env_digest "$(env_list)")"
	refute_output --partial "@unknown"
}

@test "platform_probe: an OpenShift member records its OSSM CSV and the cloud provider" {
	probe_setup
	PROBE_PLATFORM=openshift platform_probe member-o 2>"$WARN"
	[ ! -s "$WARN" ] || { cat "$WARN"; false; }
	run platform_preamble_lines member-o
	assert_line "# PLATFORM=openshift"
	assert_line "# MESH_OPERATOR_BY_CONTEXT=member-o=servicemeshoperator3:3.4.3/Succeeded"
	assert_line "# NODE_PROVIDER_BY_CONTEXT=member-o=aws"
	! grep -q 'sail-operator' "$CALLS" || false
}

@test "platform_probe: a member it cannot ask reads unknown with a warning and stops reading" {
	probe_setup
	PROBE_PLATFORM=down platform_probe member-d 2>"$WARN"
	grep -q 'member-d: could not read the platform' "$WARN"
	grep -q 'member-d: did not answer' "$WARN"
	run platform_preamble_lines member-d
	assert_line "# PLATFORM=unknown"
	assert_line "# MESH_OPERATOR_BY_CONTEXT=member-d=unknown"
	assert_line "# ISTIOD_IMAGE_BY_CONTEXT=member-d=unknown"
	assert_line "# NODE_PROVIDER_BY_CONTEXT=member-d=unknown"
	assert_line "# TUNING_OBJECTS_BY_CONTEXT=member-d=unknown"
	# One read (api-versions), then nothing more against a member that did not answer.
	[ "$(wc -l < "$CALLS")" -eq 1 ]
}

@test "platform_probe: a refused platform read leaves the operator unknown, never absent, and reads the rest" {
	probe_setup
	PROBE_PLATFORM=forbidden platform_probe member-f 2>"$WARN"
	grep -q 'member-f: could not read the platform (so the mesh operator build is not read either)' "$WARN"
	grep -q 'Forbidden' "$WARN"
	run platform_preamble_lines member-f
	assert_line "# PLATFORM=unknown"
	assert_line "# MESH_OPERATOR_BY_CONTEXT=member-f=unknown"
	assert_line "# ISTIOD_IMAGE_BY_CONTEXT=member-f=pilot:1.30.5@${DIG_B}"
	refute_output --partial "absent"
}

@test "platform_probe: absent only when the served platform's own kind answers with none" {
	probe_setup
	PROBE_SAIL=empty platform_probe member-a 2>"$WARN"
	PROBE_PLATFORM=openshift PROBE_CSV=other platform_probe member-o 2>>"$WARN"
	[ "$(platform_member_value member-a operator)" = absent ]
	[ "$(platform_member_value member-o operator)" = absent ]
	[ ! -s "$WARN" ] || { cat "$WARN"; false; }
	# A member that cannot be asked what it serves is looked at where TEST_PLATFORM says: no CSV
	# kind there is unknown with a warning, and no Sail Deployment there is unknown too (OSSM may
	# run), never absent.
	TEST_PLATFORM=openshift PROBE_PLATFORM=forbidden platform_probe member-k 2>>"$WARN"
	TEST_PLATFORM=kubernetes PROBE_PLATFORM=forbidden PROBE_SAIL=empty platform_probe member-s 2>>"$WARN"
	[ "$(platform_member_value member-k operator)" = unknown ]
	[ "$(platform_member_value member-k platform)" = unknown ]
	[ "$(platform_member_value member-s operator)" = unknown ]
	[ "$(platform_member_value member-s platform)" = unknown ]
	grep -q "member-k: could not read the platform it serves (its mesh operator is looked for where TEST_PLATFORM=openshift says)" "$WARN"
	grep -q "member-k: could not read the mesh operator build; recorded as unknown: .*doesn't have a resource type" "$WARN"
	grep -q "member-s: no mesh operator where TEST_PLATFORM=kubernetes looks, and the platform the member serves could not be read; recorded as unknown, not absent" "$WARN"
}

@test "platform_probe (H9): TEST_PLATFORM set still asks each member; a member that serves another platform warns" {
	probe_setup
	# A Kubernetes member under TEST_PLATFORM=openshift: the record keeps what it serves and reads
	# its operator there (the Sail operator, not a CSV).
	TEST_PLATFORM=openshift platform_probe member-k 2>"$WARN"
	grep -q -- '--context=member-k --request-timeout=20s api-versions' "$CALLS"
	[ "$(platform_member_value member-k platform)" = kubernetes ]
	[ "$(platform_member_value member-k operator)" = "sail-operator:1.31.1@${DIG_A}/Available" ]
	! grep -q 'clusterserviceversions' "$CALLS" || false
	grep -q "member-k: TEST_PLATFORM=openshift, but the member serves kubernetes: the record keeps kubernetes (PLATFORM_BY_CONTEXT), while the suite charts get the openshift overlay" "$WARN"
	TEST_PLATFORM=openshift run platform_preamble_lines member-k
	assert_line "# PLATFORM=kubernetes"
	assert_line "# TEST_PLATFORM=openshift"
	assert_line "# PLATFORM_BY_CONTEXT=member-k=kubernetes"
	# An OpenShift member under TEST_PLATFORM=kubernetes: its OSSM CSV.
	TEST_PLATFORM=kubernetes PROBE_PLATFORM=openshift platform_probe member-o 2>"$WARN"
	[ "$(platform_member_value member-o platform)" = openshift ]
	[ "$(platform_member_value member-o operator)" = servicemeshoperator3:3.4.3/Succeeded ]
	grep -q "member-o: TEST_PLATFORM=kubernetes, but the member serves openshift" "$WARN"
	# One that agrees warns nothing; the overlay choice still follows TEST_PLATFORM alone.
	: > "$CALLS"
	TEST_PLATFORM=kubernetes platform_probe member-a 2>"$WARN"
	[ ! -s "$WARN" ] || { cat "$WARN"; false; }
	grep -q -- '--context=member-a --request-timeout=20s api-versions' "$CALLS"
	: > "$CALLS"
	[ "$(TEST_PLATFORM=openshift platform_of member-k)" = openshift ]
	[ ! -s "$CALLS" ]
}

@test "platform_probe (H8): the gateway proxy build is the ingress and the east-west gateways', never another pod's" {
	probe_setup
	PROBE_EWGW=other platform_probe member-a 2>"$WARN"
	[ "$(platform_member_value member-a proxy)" = "proxyv2:1.30.5@${DIG_C}+proxyv2:1.30.6@${DIG_A}" ]
	probe_setup
	PROBE_EWGW=none platform_probe member-a 2>"$WARN"
	[ "$(platform_member_value member-a proxy)" = "proxyv2:1.30.5@${DIG_C}" ]
	# The egress gateway's 9.9.9 never shows.
	[[ "$(platform_preamble_lines member-a)" != *"9.9.9"* ]]
}

@test "platform_probe (H2): only containers that started count; with none, the spec image @unknown or the digest it pins" {
	local v
	# A Pending, ContainerCreating or evicted replica next to a running one: the running one's build.
	for v in pending creating evicted evicted-old; do
		probe_setup
		PROBE_ISTIOD_PODS="$v" platform_probe member-a 2>"$WARN"
		[ "$(platform_member_value member-a istiod)" = "pilot:1.30.5@${DIG_B}" ] || { echo "${v}: $(platform_member_value member-a istiod)"; false; }
		[ "$(platform_member_value member-a istiod_env)" = "$(env_digest "$(env_list)")" ]
		[ ! -s "$WARN" ] || { cat "$WARN"; false; }
	done
	# Two replicas that run two digests (a rollout): both, sorted.
	probe_setup
	PROBE_ISTIOD_PODS=two-digests platform_probe member-a 2>/dev/null
	[ "$(platform_member_value member-a istiod)" = "pilot:1.30.5@${DIG_A}+pilot:1.30.5@${DIG_B}" ]
	# Only a Pending replica: its spec image, @unknown (not read), unless the spec pins a digest.
	probe_setup
	PROBE_ISTIOD_PODS=only-pending platform_probe member-a 2>/dev/null
	[ "$(platform_member_value member-a istiod)" = "pilot:1.30.5@unknown" ]
	probe_setup
	PROBE_ISTIOD_PODS=pinned-pending platform_probe member-a 2>/dev/null
	[ "$(platform_member_value member-a istiod)" = "pilot:1.30.5@${DIG_B}" ]
	# No istiod pod at all: none, for its build and its settings.
	probe_setup
	PROBE_ISTIOD_PODS=none platform_probe member-a 2>"$WARN"
	[ "$(platform_member_value member-a istiod)" = none ]
	[ "$(platform_member_value member-a istiod_env)" = none ]
	[ ! -s "$WARN" ] || { cat "$WARN"; false; }
	# The Sail operator scaled to 0, or its pod Pending: @unknown; a digest its Deployment pins counts.
	probe_setup
	PROBE_SAIL_PODS=none PROBE_SAIL_AVAILABLE=0 platform_probe member-a 2>/dev/null
	[ "$(platform_member_value member-a operator)" = "sail-operator:1.31.1@unknown/Unavailable" ]
	probe_setup
	PROBE_SAIL_PODS=pending PROBE_SAIL_AVAILABLE=0 platform_probe member-a 2>/dev/null
	[ "$(platform_member_value member-a operator)" = "sail-operator:1.31.1@unknown/Unavailable" ]
	probe_setup
	PROBE_SAIL_PODS=pinned PROBE_SAIL_AVAILABLE=0 platform_probe member-a 2>/dev/null
	[ "$(platform_member_value member-a operator)" = "sail-operator:1.31.1@${DIG_B}/Unavailable" ]
}

@test "platform_probe (H25): ISTIOD_ENV_BY_CONTEXT is one digest for the same settings on every member; another setting or a rollout shows" {
	local d100 d50
	d100="$(env_digest "$(env_list)")"
	d50="$(env_digest "$(env_list 50)")"
	[[ "$d100" =~ ^[0-9a-f]{12}$ && "$d100" != "$d50" ]]
	# CLUSTER_ID differs by member and is left out; a valueFrom counts by its content.
	probe_setup
	platform_probe member-a,member-b 2>"$WARN"
	[ ! -s "$WARN" ] || { cat "$WARN"; false; }
	[ "$(platform_member_value member-a istiod_env)" = "$d100" ]
	[ "$(platform_member_value member-b istiod_env)" = "$d100" ]
	# A tuning profile's spec.values.pilot.env (another PILOT_PUSH_THROTTLE): another digest.
	probe_setup
	PROBE_ISTIOD_THROTTLE=50 platform_probe member-a 2>/dev/null
	[ "$(platform_member_value member-a istiod_env)" = "$d50" ]
	# During a rollout, both, sorted and "+"-joined.
	probe_setup
	PROBE_ISTIOD_PODS=env-rollout platform_probe member-a 2>/dev/null
	[ "$(platform_member_value member-a istiod_env)" = "$(printf '%s\n' "$d100" "$d50" | LC_ALL=C sort | paste -sd + -)" ]
	# platform_probe needs the sha256 helper (tests/lib/config.sh) before it reads anything.
	run bash -c 'source "$1/tests/lib/common.sh"; source "$1/tests/lib/platform.sh"; source "$1/tests/lib/reach.sh"
		KUBECTL=(false); DRY_RUN=0; platform_probe member-a' _ "$ROOT"
	assert_failure
	assert_output --partial "platform_probe needs _config_sha256 (source tests/lib/config.sh)"
	# Without a working sha256 tool: unknown, with a warning.
	probe_setup
	_config_sha256() { echo unknown; }
	platform_probe member-a 2>"$WARN"
	[ "$(platform_member_value member-a istiod_env)" = unknown ]
	grep -q "member-a: could not read istiod's settings (its discovery container env); recorded as unknown: the reply did not parse, or no sha256 tool" "$WARN"
}

@test "platform_probe (R5): TUNING_OBJECTS_BY_CONTEXT names the objects a tuning profile left applied; none when none; unread is unknown" {
	probe_setup
	platform_probe member-a 2>"$WARN"
	[ "$(platform_member_value member-a tuning_objects)" = none ]
	grep -q -- "--context=member-a --request-timeout=20s get ${PLATFORM_TUNING_KINDS} -A -l ${PLATFORM_TUNING_LABEL} -o json" "$CALLS"
	probe_setup
	PROBE_TUNING_OBJECTS=04 platform_probe member-a 2>"$WARN"
	[ ! -s "$WARN" ] || { cat "$WARN"; false; }
	[ "$(platform_member_value member-a tuning_objects)" = 04-connection-pools:DestinationRule/istio-system/tuning-connection-pool ]
	# Several objects: sorted and "+"-joined, each with its profile.
	probe_setup
	PROBE_TUNING_OBJECTS=two platform_probe member-a 2>"$WARN"
	[ "$(platform_member_value member-a tuning_objects)" = "04-connection-pools:DestinationRule/istio-system/tuning-connection-pool+09-x:Sidecar/ns-b/tuning-x" ]
	run platform_md_row member-a
	assert_output --partial "tuning objects 04-connection-pools:DestinationRule/istio-system/tuning-connection-pool+09-x:Sidecar/ns-b/tuning-x"
	# A kind the member does not serve: unknown with a warning, never none.
	probe_setup
	PROBE_TUNING_OBJECTS=unserved platform_probe member-a 2>"$WARN"
	[ "$(platform_member_value member-a tuning_objects)" = unknown ]
	grep -q "member-a: could not read the tuning profile objects (label istio-scale-tests/tuning-profile); recorded as unknown: error: the server doesn't have a resource type" "$WARN"
	# No answer in time: the knob to raise, and the record stops (this read is its last).
	probe_setup
	PROBE_TUNING_OBJECTS=timeout platform_probe member-a 2>"$WARN"
	[ "$(platform_member_value member-a tuning_objects)" = unknown ]
	[ "$(platform_member_value member-a nodes)" = kind ]
	grep -q "member-a: could not read the tuning profile objects (label istio-scale-tests/tuning-profile); recorded as unknown: Unable to connect to the server: net/http: request canceled (Client.Timeout exceeded while awaiting headers); no answer within PLATFORM_READ_TIMEOUT (20s); raise it in the environment, config/options.env or, in a script that takes one, the --config file, for a large or slow member" "$WARN"
	grep -q "member-a: did not answer within PLATFORM_READ_TIMEOUT (20s); its platform record stops here (the values not read are unknown)" "$WARN"
	# The key is not one a tuning pass is compared on (a profile applies its objects on purpose).
	[[ " ${PLATFORM_ROW_KEYS[*]} " == *" TUNING_OBJECTS_BY_CONTEXT "* && " ${PLATFORM_PASS_KEYS[*]} " != *" TUNING_OBJECTS_BY_CONTEXT "* ]]
}

@test "platform record (R5, R6): the tuning profile label and kinds it reads are the ones tuning.py applies and 005-cleanup.sh deletes" {
	local py="${ROOT}/tests/tuning/lib/tuning.py" cl="${ROOT}/tests/tuning/005-cleanup.sh" kinds
	grep -qx "LABEL = \"${PLATFORM_TUNING_LABEL}\"" "$py"
	# 005-cleanup.sh restores from the markers and deletes by platform.sh's own values.
	grep -qx 'LABEL="$PLATFORM_TUNING_LABEL"' "$cl"
	grep -qx 'KINDS="$PLATFORM_TUNING_RESOURCE_KINDS"' "$cl"
	grep -qx 'MARKER_KIND="$PLATFORM_TUNING_MARKER_KIND"' "$cl"
	# Each kind tuning.py allows, by its resource name, and the marker's.
	kinds="$(sed -n 's/^ALLOWED_KINDS = {\(.*\)}$/\1/p' "$py" | tr -d '" ' | tr , '\n' | LC_ALL=C sort | paste -sd , -)"
	[ "$kinds" = DestinationRule,EnvoyFilter,Sidecar,Telemetry ]
	[ "$(tr , '\n' <<<"$PLATFORM_TUNING_RESOURCE_KINDS" | LC_ALL=C sort | paste -sd , -)" = \
		destinationrules.networking.istio.io,envoyfilters.networking.istio.io,sidecars.networking.istio.io,telemetries.telemetry.istio.io ]
	grep -qx "MARKER_KIND = \"${PLATFORM_TUNING_MARKER_OBJECT_KIND}\"" "$py"
	[ "$PLATFORM_TUNING_MARKER_OBJECT_KIND" = ConfigMap ]
	[ "$PLATFORM_TUNING_MARKER_KIND" = configmaps ]
	# Where the marker is and how it is named: tuning 004 expects it on every member of a pass.
	grep -qx "MARKER_NAMESPACE = \"${PLATFORM_TUNING_MARKER_NS}\"" "$py"
	grep -qx "MARKER_PREFIX = \"${PLATFORM_TUNING_MARKER_PREFIX}\"" "$py"
	# The record lists both.
	[ "$PLATFORM_TUNING_KINDS" = "${PLATFORM_TUNING_RESOURCE_KINDS},configmaps" ]
}

@test "platform_tuning_objects_check (R6): a record's tuning objects against a pass's profile read other, unknown, own or none, with the members and objects" {
	local m02="02-x:ConfigMap/istio-system/tuning-profile-02-x" dr04="04-y:DestinationRule/istio-system/tuning-pool"
	run platform_tuning_objects_check "ctx-a=none,ctx-b=none"
	assert_output $'none\t\t'
	# A pass's own profile: own; any object without a profile (no tuning pass): other.
	run platform_tuning_objects_check "ctx-a=${m02},ctx-b=${m02}" 02-x
	assert_output $'own\t\t'
	run platform_tuning_objects_check "ctx-a=${m02},ctx-b=none"
	assert_output $'other\tctx-a\t'"${m02}"
	# Another profile's object next to its own: other, naming that object only.
	run platform_tuning_objects_check "ctx-a=${m02}+${dr04},ctx-b=${m02}" 02-x
	assert_output $'other\tctx-a\t'"${dr04}"
	# Inputs that differ on a member (mixed:) count each value.
	run platform_tuning_objects_check "ctx-a=mixed:none;${dr04},ctx-b=none" 02-x
	assert_output $'other\tctx-a\t'"${dr04}"
	# Not read on a member: unknown, unless another member holds a foreign object.
	run platform_tuning_objects_check "ctx-a=unknown,ctx-b=${m02}" 02-x
	assert_output $'unknown\tcould not be read on ctx-a\t'
	run platform_tuning_objects_check "ctx-a=unknown,ctx-b=${dr04}" 02-x
	assert_output $'other\tctx-b\t'"${dr04}"
	# Inputs from before the key: no member at all, or one input without it.
	run platform_tuning_objects_check unknown
	assert_output $'unknown\tare not recorded (the inputs predate the key)\t'
	run platform_tuning_objects_check "mixed:unknown,ctx-a=none"
	assert_output $'unknown\tare not recorded in every input (some predate the key)\t'
	run platform_tuning_objects_check "mixed:unknown,ctx-a=unknown,ctx-b=none"
	assert_output $'unknown\tcould not be read on ctx-a, and are not recorded in every input (some predate the key)\t'
	# A fleet: five names, then how many more; with _pl_no_members, a count.
	run platform_tuning_objects_check "m1=${dr04},m2=${dr04},m3=${dr04},m4=${dr04},m5=${dr04},m6=${dr04},m7=none"
	assert_output $'other\tm1, m2, m3, m4, m5 and 1 more\t'"${dr04}"
	_pl_no_members=1 run platform_tuning_objects_check "m1=${dr04},m2=unknown,m3=none"
	assert_output $'other\t1 of 3 members\t'"${dr04}"
	_pl_no_members=1 run platform_tuning_objects_check "m1=unknown,m2=unknown,m3=none"
	assert_output $'unknown\tcould not be read on 2 of 3 members\t'
}

@test "platform_tuning_objects_check (I6-B1): a pass's profile not on a member, in any value it was read with, reads missing, with the members and objects" {
	local m02="02-x:ConfigMap/istio-system/tuning-profile-02-x" s02="02-x:Sidecar/istio-system/tuning-02"
	local dr04="04-y:DestinationRule/istio-system/tuning-pool"
	# By default the profile's marker is expected on every member.
	run platform_tuning_objects_check "ctx-a=${m02},ctx-b=none" 02-x
	assert_output $'missing\tctx-b\t'"${m02}"
	run platform_tuning_objects_check "ctx-a=none,ctx-b=none" 02-x
	assert_output $'missing\tctx-a, ctx-b\t'"${m02}"
	# One input of a member's, or the read at the pass's end (a mixed: value), without it.
	run platform_tuning_objects_check "ctx-a=mixed:${m02};none,ctx-b=${m02}" 02-x
	assert_output $'missing\tctx-a\t'"${m02}"
	# The objects given: the marker and the profile's resources; a member without one lacks it.
	run platform_tuning_objects_check "ctx-a=${m02},ctx-b=${m02}+${s02}" 02-x "ConfigMap/istio-system/tuning-profile-02-x+Sidecar/istio-system/tuning-02"
	assert_output $'missing\tctx-a\t'"${s02}"
	run platform_tuning_objects_check "ctx-a=${m02}+${s02},ctx-b=${s02}+${m02}" 02-x "ConfigMap/istio-system/tuning-profile-02-x+Sidecar/istio-system/tuning-02"
	assert_output $'own\t\t'
	# Another profile's objects come first; missing before not read.
	run platform_tuning_objects_check "ctx-a=${dr04},ctx-b=none" 02-x
	assert_output $'other\tctx-a\t'"${dr04}"
	run platform_tuning_objects_check "ctx-a=unknown,ctx-b=none" 02-x
	assert_output $'missing\tctx-b\t'"${m02}"
	# Without a profile (the baseline, a run that is no tuning pass) nothing is expected.
	run platform_tuning_objects_check "ctx-a=none,ctx-b=none"
	assert_output $'none\t\t'
	# A fleet: five names, then how many more; with _pl_no_members, a count.
	run platform_tuning_objects_check "m1=none,m2=none,m3=none,m4=none,m5=none,m6=none,m7=none,m8=${m02}" 02-x
	assert_output $'missing\tm1, m2, m3, m4, m5 and 2 more\t'"${m02}"
	_pl_no_members=1 run platform_tuning_objects_check "m1=none,m2=${m02},m3=unknown" 02-x
	assert_output $'missing\t1 of 3 members\t'"${m02}"
}

@test "platform_start_warnings (R6, U5-Ba): a sweep warns as it starts when a member holds a tuning profile's objects or marker; silent otherwise and in a dry-run" {
	probe_setup
	PROBE_TUNING_ON=member-b PROBE_TUNING_OBJECTS=marker platform_probe member-a,member-b 2>/dev/null
	run --separate-stderr platform_start_warnings member-a,member-b
	assert_success
	assert_output ""
	[ "$stderr" = "warning: a tuning profile's objects are in place on member-b (TUNING_OBJECTS_BY_CONTEXT: 02-xds-cache-off:ConfigMap/istio-system/tuning-profile-02-xds-cache-off), so this sweep would measure that profile's configuration, not the charts'. Unless that is the point, stop it now (Ctrl-C); then, unless a tuning run is still in progress on these members (wait for it to end), undo them with ./tests/tuning/005-cleanup.sh --contexts member-a,member-b (add --results-dir <that run's --output-dir> if it had one, and --gitops-context <hub> to resume Argo CD if it paused it); every report of this run warns too" ] || { echo "$stderr"; false; }
	# Only the members asked about.
	run --separate-stderr platform_start_warnings member-a
	[ -z "$stderr" ]
	# None, or not read (its own warning came with the probe): nothing more.
	probe_setup
	platform_probe member-a 2>/dev/null
	run --separate-stderr platform_start_warnings member-a
	[ -z "$stderr" ]
	probe_setup
	PROBE_TUNING_OBJECTS=unserved platform_probe member-a 2>/dev/null
	run --separate-stderr platform_start_warnings member-a
	[ -z "$stderr" ]
	probe_setup
	DRY_RUN=1 PROBE_TUNING_OBJECTS=04 run --separate-stderr platform_start_warnings member-a
	[ -z "$stderr" ]
}

@test "platform_tuning_objects (R6): a member's tuning profile objects and marker, as the record holds them; why on stderr when they cannot be listed" {
	probe_setup
	run platform_tuning_objects member-a
	assert_success
	assert_output none
	grep -q -- "--context=member-a --request-timeout=20s get ${PLATFORM_TUNING_KINDS} -A -l ${PLATFORM_TUNING_LABEL} -o json" "$CALLS"
	PROBE_TUNING_OBJECTS=marker run platform_tuning_objects member-a
	assert_success
	assert_output "02-xds-cache-off:ConfigMap/istio-system/tuning-profile-02-xds-cache-off"
	PROBE_TUNING_OBJECTS=two run platform_tuning_objects member-a
	assert_output "04-connection-pools:DestinationRule/istio-system/tuning-connection-pool+09-x:Sidecar/ns-b/tuning-x"
	PROBE_TUNING_OBJECTS=timeout run --separate-stderr platform_tuning_objects member-a
	assert_failure
	assert_output ""
	[[ "$stderr" == "Unable to connect to the server: net/http: request canceled (Client.Timeout exceeded while awaiting headers); no answer within PLATFORM_READ_TIMEOUT (20s); raise it"* ]] || { echo "$stderr"; false; }
	PROBE_TUNING_OBJECTS=unserved run --separate-stderr platform_tuning_objects member-a
	assert_failure
	[ "$stderr" = 'error: the server doesn'"'"'t have a resource type "envoyfilters"' ] || { echo "$stderr"; false; }
	# In a work dir of the caller's.
	mkdir -p "${BATS_TEST_TMPDIR}/w"
	PROBE_TUNING_OBJECTS=04 run platform_tuning_objects member-a "${BATS_TEST_TMPDIR}/w"
	assert_output 04-connection-pools:DestinationRule/istio-system/tuning-connection-pool
	[ -s "${BATS_TEST_TMPDIR}/w/tuning.json" ]
}

@test "platform_tuning_objects_refuse (R6, I5-B1): stops a run over a member's profile objects or marker, or a member whose cannot be listed; nothing in a dry-run" {
	local csv
	probe_setup
	platform_tuning_objects_refuse member-a,member-b "this profile"
	[ "$(grep -c -- " get ${PLATFORM_TUNING_KINDS} -A " "$CALLS")" -eq 2 ]
	# An env-only profile left applied: only its marker, on member-b.
	PROBE_TUNING_ON=member-b PROBE_TUNING_OBJECTS=marker run platform_tuning_objects_refuse member-a,member-b "every pass of this sweep (the baseline included)"
	assert_failure
	assert_output --partial "a tuning profile's objects (label istio-scale-tests/tuning-profile) are on member-b already: 02-xds-cache-off:ConfigMap/istio-system/tuning-profile-02-xds-cache-off. Every pass of this sweep (the baseline included) would be measured with them. They are a tuning run still in progress on these members (wait for it to end), a profile left applied (a run stopped before its revert, in any checkout) or objects applied by hand; undo those with ./tests/tuning/005-cleanup.sh --contexts member-a,member-b (add --results-dir <that run's --output-dir> if it had one, and --gitops-context <hub> to resume Argo CD if it paused it), which also restores each member's Istio CR from the profile's marker, then start again"
	# A member that cannot be asked stops it too, whatever the others hold.
	PROBE_TUNING_ON=member-b PROBE_TUNING_OBJECTS=timeout run platform_tuning_objects_refuse member-a,member-b "this profile"
	assert_failure
	assert_output --partial "the tuning profile objects (label istio-scale-tests/tuning-profile) could not be listed on member-b (Unable to connect to the server: net/http: request canceled (Client.Timeout exceeded while awaiting headers); no answer within PLATFORM_READ_TIMEOUT (20s)"
	assert_output --partial "): a member that cannot be asked may hold a profile's objects, and this profile would be measured with them; fix the access (or raise PLATFORM_READ_TIMEOUT) and start again"
	# A fleet: five members and five objects named, then how many more; a long --contexts is not repeated.
	csv="$(printf 'member-%02d,' {1..40})"
	PROBE_TUNING_OBJECTS=two run platform_tuning_objects_refuse "${csv%,}" "this profile"
	assert_failure
	assert_output --partial "are on member-01, member-02, member-03, member-04, member-05 and 35 more already: 04-connection-pools:DestinationRule/istio-system/tuning-connection-pool, 09-x:Sidecar/ns-b/tuning-x. This profile would be measured with them."
	assert_output --partial "./tests/tuning/005-cleanup.sh the same --contexts (add --results-dir"
	# A dry-run asks nothing.
	probe_setup
	: >"$CALLS"
	DRY_RUN=1 PROBE_TUNING_OBJECTS=04 platform_tuning_objects_refuse member-a "this profile"
	[ ! -s "$CALLS" ]
	# 001-apply-profile.sh and 003-run-tuning-sweep.sh call it before they change anything.
	grep -q '^platform_tuning_objects_refuse "$CONTEXTS_CSV" "this profile"$' "${ROOT}/tests/tuning/001-apply-profile.sh"
	grep -q '^platform_tuning_objects_refuse "$CONTEXTS_CSV" "every pass of this sweep (the baseline included)"$' "${ROOT}/tests/tuning/003-run-tuning-sweep.sh"
	[ "$(grep -n '^platform_tuning_objects_refuse' "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" | cut -d: -f1)" -lt \
		"$(grep -n "^trap 'on_exit || true' EXIT" "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" | cut -d: -f1)" ]
	[ "$(grep -n '^platform_tuning_objects_refuse' "${ROOT}/tests/tuning/001-apply-profile.sh" | cut -d: -f1)" -lt \
		"$(grep -n '^mkdir -p "$STATE_DIR"' "${ROOT}/tests/tuning/001-apply-profile.sh" | cut -d: -f1)" ]
}

@test "_platform_rows_set (R6, Sc5-S3): each member's row replaced in place in one pass, the others appended in order, the index kept current" {
	PLATFORM_PROBE_ROWS=$'a\t1\nb\t1\nc\t1\n'
	_platform_index
	_platform_rows_set $'c\t2\nd\t2\na\t2\n'
	[ "$PLATFORM_PROBE_ROWS" = $'a\t2\nb\t1\nc\t2\nd\t2\n' ] || { printf '%q\n' "$PLATFORM_PROBE_ROWS"; false; }
	# The index serves the new rows without being built again.
	[ "$_PL_IDX_SRC" = "$PLATFORM_PROBE_ROWS" ]
	[ "${_PL_IDX[a]}" = $'a\t2' ] && [ "${_PL_IDX[b]}" = $'b\t1' ] && [ "${_PL_IDX[d]}" = $'d\t2' ]
	[ "$(_platform_row c)" = $'c\t2' ]
	# The last of a member's rows wins; a row without a member, or none at all, changes nothing.
	_platform_rows_set $'b\t3\nb\t4\n\tx\n'
	[ "$PLATFORM_PROBE_ROWS" = $'a\t2\nb\t4\nc\t2\nd\t2\n' ] || { printf '%q\n' "$PLATFORM_PROBE_ROWS"; false; }
	[ "${_PL_IDX[b]}" = $'b\t4' ]
	_platform_rows_set ""
	_platform_rows_set $'\tx\n'
	[ "$PLATFORM_PROBE_ROWS" = $'a\t2\nb\t4\nc\t2\nd\t2\n' ]
	# A record that held a member twice keeps its first place only.
	PLATFORM_PROBE_ROWS=$'a\t1\nb\t1\na\t9\n'
	_platform_rows_set $'a\t5\n'
	[ "$PLATFORM_PROBE_ROWS" = $'a\t5\nb\t1\n' ] || { printf '%q\n' "$PLATFORM_PROBE_ROWS"; false; }
}

@test "_platform_each (R6, Sc5-S2): at most PLATFORM_READ_PARALLEL members at once; each member's row and warnings in files of its own, in order" {
	local i n max=0 t="${BATS_TEST_TMPDIR}"
	# Each job counts the jobs alive (their dirs under running/) as it starts.
	_pool_member() {
		mkdir -p "${BATS_TEST_TMPDIR}/running/${1}"
		find "${BATS_TEST_TMPDIR}/running" -mindepth 1 -maxdepth 1 -type d | wc -l >"${2}/count"
		sleep 0.2
		rmdir "${BATS_TEST_TMPDIR}/running/${1}"
		echo "row of ${1}"
		echo "warn of ${1}" >&2
	}
	mkdir -p "${t}/pool3" "${t}/pool1" "${t}/fail"
	PLATFORM_READ_PARALLEL=3 _platform_each _pool_member "${t}/pool3" m0 m1 m2 m3 m4 m5 m6 m7
	for i in 0 1 2 3 4 5 6 7; do
		[ "$(cat "${t}/pool3/${i}.row")" = "row of m${i}" ]
		[ "$(cat "${t}/pool3/${i}.warn")" = "warn of m${i}" ]
		n="$(tr -d ' ' <"${t}/pool3/${i}/count")"
		((n <= max)) || max="$n"
	done
	((max >= 1 && max <= 3))
	PLATFORM_READ_PARALLEL=1 _platform_each _pool_member "${t}/pool1" m0 m1 m2
	for i in 0 1 2; do [ "$(tr -d ' ' <"${t}/pool1/${i}/count")" -eq 1 ]; done
	# A member whose read fails does not stop the others.
	_pool_fail() { [[ "$1" != m1 ]] || return 1; echo "row of ${1}"; }
	PLATFORM_READ_PARALLEL=2 _platform_each _pool_fail "${t}/fail" m0 m1 m2
	[ "$(cat "${t}/fail/0.row")" = "row of m0" ] && [ ! -s "${t}/fail/1.row" ] && [ "$(cat "${t}/fail/2.row")" = "row of m2" ]
}

@test "PLATFORM_READ_PARALLEL (R6, Sc5-S2): a whole number above zero; an options.env default every suite's --config can set" {
	local v s
	for v in 1 20 500; do
		PLATFORM_READ_PARALLEL="$v" run platform_validate
		assert_success
	done
	for v in 0 -1 abc 2.5 03 "4 "; do
		PLATFORM_READ_PARALLEL="$v" run platform_validate
		assert_failure
		assert_output --partial "PLATFORM_READ_PARALLEL must be a whole number above zero: how many members' platform records are read at once (got: ${v}); set it in the environment, config/options.env or, in a script that takes one, the --config file"
	done
	run bash -c 'unset PLATFORM_READ_PARALLEL; source "$1/config/options.env"; echo "$PLATFORM_READ_PARALLEL"' _ "$ROOT"
	assert_output 20
	for s in propagation churn churn-dataplane controlplane dataplane gateway-api; do
		config_allowed_keys "$s" | grep -qx PLATFORM_READ_PARALLEL || { echo "${s}: --config cannot set PLATFORM_READ_PARALLEL"; false; }
	done
	# Every member's record still comes out with one at a time.
	probe_setup
	PLATFORM_READ_PARALLEL=1 platform_probe member-a,member-b 2>/dev/null
	[ "$(platform_member_value member-a nodes)" = kind ]
	[ "$(platform_member_value member-b nodes)" = kind ]
}

@test "PLATFORM_READ_TIMEOUT (H27): every record read uses it; it is an options.env default every suite's --config can set" {
	local t s
	probe_setup
	PLATFORM_READ_TIMEOUT=45s platform_probe member-a 2>/dev/null
	[ "$(grep -c -- '--request-timeout=45s' "$CALLS")" -eq 5 ]
	! grep -q -- '--request-timeout=20s' "$CALLS" || false
	for t in 20s 1m 30 500ms 1m30s 1.5m; do
		PLATFORM_READ_TIMEOUT="$t" run platform_validate
		assert_success
	done
	for t in 0 0s 0.0m abc -5s 20x "20 s"; do
		PLATFORM_READ_TIMEOUT="$t" run platform_validate
		assert_failure
		assert_output --partial "PLATFORM_READ_TIMEOUT must be a kubectl --request-timeout above zero, such as 20s or 1m (got: ${t}); set it in the environment, config/options.env or, in a script that takes one, the --config file"
	done
	run bash -c 'unset PLATFORM_READ_TIMEOUT; source "$1/config/options.env"; echo "$PLATFORM_READ_TIMEOUT"' _ "$ROOT"
	assert_output 20s
	for s in propagation churn churn-dataplane controlplane dataplane gateway-api; do
		config_allowed_keys "$s" | grep -qx PLATFORM_READ_TIMEOUT || { echo "${s}: --config cannot set PLATFORM_READ_TIMEOUT"; false; }
	done
}

@test "platform_probe: --dry-run reads nothing and records unknown; a bad TEST_PLATFORM stops first" {
	probe_setup
	DRY_RUN=1 platform_probe member-a,member-b
	[ ! -s "$CALLS" ]
	run platform_preamble_lines member-a,member-b
	assert_line "# PLATFORM=unknown"
	assert_line "# MESH_OPERATOR_BY_CONTEXT=member-a=unknown,member-b=unknown"
	probe_setup
	TEST_PLATFORM=okd run platform_probe member-a
	assert_failure
	assert_output --partial "TEST_PLATFORM must be auto, kubernetes or openshift (got: okd)"
	[ ! -s "$CALLS" ]
}

@test "platform_probe (M9-S2): a member listed twice, or two members the record writes under one name, dies before any read, in a dry-run too" {
	probe_setup
	run platform_probe member-a,member-b,member-a
	assert_failure
	assert_output --partial "member-a is listed twice among the mesh members: list each member once (--contexts or SETUP_CONTEXTS; a probe's --source-context is not one of its --remote-contexts)"
	[ ! -s "$CALLS" ]
	# At 500 members, the one member only (SC10-N1).
	local ctxs
	ctxs="$(wide_ctxs 500)"
	run platform_probe "${ctxs},${ctxs%%,*}"
	assert_failure
	assert_output --partial "${ctxs%%,*} is listed twice among the mesh members: list each member once"
	awk 'length > 300 { bad = 1 } END { exit bad }' <<<"$output"
	[ ! -s "$CALLS" ]
	DRY_RUN=1 run platform_probe member-a,member-a
	assert_failure
	assert_output --partial "member-a is listed twice among the mesh members"
	# lab~a is lab_a in the record (its safe characters only): two members' values under one name.
	run platform_probe "lab~a,lab_a"
	assert_failure
	assert_output --partial "lab~a and lab_a would be recorded under one name, lab_a (the record writes a member's name with A-Z, a-z, 0-9 and _.:/@+- only): rename one of the two contexts"
	[ ! -s "$CALLS" ]
	# Each member once: read as before.
	run platform_probe member-a,member-b
	assert_success
	grep -q -- '--context=member-b' "$CALLS"
}

@test "platform_probe: an inherited record is reused and only new members are read; save and load keep it" {
	probe_setup
	PLATFORM_PROBE_ROWS=$'member-a\tkubernetes\tsail-operator:1.31.0/Available\tpilot:1.30.4\tproxyv2:1.30.4\tkind\t0123456789ab\n'
	export PLATFORM_PROBE_ROWS
	platform_probe member-a,member-b 2>"$WARN"
	! grep -q -- '--context=member-a' "$CALLS" || false
	grep -q -- '--context=member-b' "$CALLS"
	[ "$(platform_member_value member-a istiod)" = pilot:1.30.4 ]
	[ "$(platform_member_value member-b istiod)" = "pilot:1.30.5@${DIG_B}" ]
	[ "$(platform_probed_contexts)" = member-a,member-b ]
	platform_probe_save "${BATS_TEST_TMPDIR}/record.tsv"
	# A later phase: the saved record fills in; a row it already has wins.
	PLATFORM_PROBE_ROWS=$'member-b\topenshift\tx\ty\tz\taws\te\n'
	platform_probe_load "${BATS_TEST_TMPDIR}/record.tsv"
	[ "$(platform_member_value member-b platform)" = openshift ]
	[ "$(platform_member_value member-a operator)" = sail-operator:1.31.0/Available ]
	platform_probe_load "${BATS_TEST_TMPDIR}/missing.tsv"
	: > "$CALLS"
	platform_probe member-a,member-b
	[ ! -s "$CALLS" ]
	# A step of a sweep: the record holds every member the sweep read, the step's are its own.
	platform_probe member-b
	[ "$(platform_probed_contexts)" = member-b ]
	unset PLATFORM_PROBE_LAST
	[ "$(platform_probed_contexts)" = member-b,member-a ]
}

@test "platform record: a member never probed warns and reads unknown; values keep only safe characters" {
	probe_setup
	run --separate-stderr platform_preamble_lines member-x
	assert_line "# PLATFORM=unknown"
	assert_line "# PLATFORM_BY_CONTEXT=member-x=unknown"
	[[ "$stderr" == *"member-x: no platform record was read (platform_probe was not called for it)"* ]]
	[ "$(_platform_sanitize 'a b,c=d|e')" = a_b_c_d_e ]
	[ "$(_platform_sanitize '')" = unknown ]
	[ "$(_platform_sanitize 'img:1.0@sha256:ab+x/y')" = 'img:1.0@sha256:ab+x/y' ]
}

@test "platform_md_row: a value every member shares shows once, else per member" {
	probe_setup
	PLATFORM_PROBE_ROWS=$'m1\tkubernetes\top1\tistiod1\tproxy1\tkind\te1\tnone\nm2\tkubernetes\top2\tistiod1\tproxy1\tkind\te1\tnone\n'
	run platform_md_row m1,m2
	assert_output "| Platform | kubernetes (TEST_PLATFORM auto); nodes kind; operator m1=op1,m2=op2; istiod istiod1; gateway proxy proxy1; istiod env e1; tuning objects none |"
}

@test "platform_gitops_namespace: argocd on a Kubernetes hub, openshift-gitops on OpenShift, an error when unknown" {
	KUBECTL=(_probe_kubectl)
	run platform_gitops_namespace hub
	assert_output argocd
	PROBE_PLATFORM=openshift run platform_gitops_namespace hub
	assert_output openshift-gitops
	PROBE_PLATFORM=down run --separate-stderr platform_gitops_namespace hub
	assert_failure
	[[ "$stderr" == *"cannot list the API versions of context hub"* ]]
}

# ---------------------------------------------------------------------------
# The reports' side: platform_report_values and its helpers
# ---------------------------------------------------------------------------

@test "platform_report_values: one value, a member that differs (mixed, warned), a file without the record" {
	source "${ROOT}/tests/lib/config.sh"
	local d="$BATS_TEST_TMPDIR"
	printf '%s\n' '# PLATFORM=kubernetes' '# TEST_PLATFORM=auto' '# PLATFORM_BY_CONTEXT=m1=kubernetes,m2=kubernetes' \
		'# MESH_OPERATOR_BY_CONTEXT=m1=op1,m2=op1' '# NODE_PROVIDER_BY_CONTEXT=m1=kind,m2=kind' > "${d}/a.tsv"
	printf '%s\n' '# PLATFORM=kubernetes' '# TEST_PLATFORM=auto' '# PLATFORM_BY_CONTEXT=m1=kubernetes,m2=kubernetes' \
		'# MESH_OPERATOR_BY_CONTEXT=m1=op1,m2=op2' '# NODE_PROVIDER_BY_CONTEXT=m1=kind,m2=kind' > "${d}/b.tsv"
	printf '%s\n' '# HARNESS_SHA=x' > "${d}/legacy.tsv"
	run --separate-stderr platform_report_values "${d}/a.tsv" "${d}/b.tsv"
	assert_success
	assert_line "PLATFORM=kubernetes"
	assert_line "MESH_OPERATOR_BY_CONTEXT=m1=op1,m2=mixed:op1;op2"
	assert_line "NODE_PROVIDER_BY_CONTEXT=m1=kind,m2=kind"
	assert_line "ISTIOD_IMAGE_BY_CONTEXT=unknown"
	[[ "$stderr" == *"input TSVs disagree on MESH_OPERATOR_BY_CONTEXT for m2 (op1;op2)"* ]]
	[[ "$stderr" != *"PLATFORM line"* ]]
	run --separate-stderr platform_report_values "${d}/a.tsv" "${d}/legacy.tsv"
	assert_line "PLATFORM=mixed:kubernetes,unknown"
	assert_line "MESH_OPERATOR_BY_CONTEXT=mixed:unknown,m1=op1,m2=op1"
	[[ "$stderr" == *"1 of 2 input TSV(s) have no PLATFORM line: they predate the platform record"* ]]
	# The legacy warning says why; no "disagree" for a value that was never recorded.
	[[ "$stderr" != *"disagree"* ]]
	run --separate-stderr platform_report_values "${d}/legacy.tsv"
	assert_line "PLATFORM=unknown"
	assert_line "PLATFORM_BY_CONTEXT=unknown"
	[ "${#lines[@]}" -eq "${#PLATFORM_KEYS[@]}" ]
}

@test "platform_report_values: inputs with the record but from before a key (ISTIOD_ENV_BY_CONTEXT) warn, on stderr and in the body" {
	source "${ROOT}/tests/lib/config.sh"
	local d="$BATS_TEST_TMPDIR"
	printf '%s\n' '# PLATFORM=kubernetes' '# TEST_PLATFORM=auto' '# PLATFORM_BY_CONTEXT=m1=kubernetes' > "${d}/old.tsv"
	printf '%s\n' '# PLATFORM=kubernetes' '# TEST_PLATFORM=auto' '# PLATFORM_BY_CONTEXT=m1=kubernetes' \
		'# ISTIOD_ENV_BY_CONTEXT=m1=0123456789ab' > "${d}/new.tsv"
	run --separate-stderr platform_report_values "${d}/old.tsv" "${d}/new.tsv"
	assert_success
	assert_line "ISTIOD_ENV_BY_CONTEXT=mixed:unknown,m1=0123456789ab"
	[[ "$stderr" == *"warning: ISTIOD_ENV_BY_CONTEXT is not recorded in 1 of 2 input TSV(s) (written before the platform record had the key), while other inputs have it"* ]]
	[[ "$stderr" != *"PLATFORM line"* ]]
	run platform_report_warnings "${d}/old.tsv" "${d}/new.tsv"
	assert_output "ISTIOD_ENV_BY_CONTEXT is not recorded in 1 of 2 input TSV(s) (written before the platform record had the key), while other inputs have it: the report cannot tell whether those runs had the same istiod settings (its discovery container env) as the others"
	# Every input from before the key: unknown, nothing mixed, no warning.
	run --separate-stderr platform_report_values "${d}/old.tsv"
	assert_line "ISTIOD_ENV_BY_CONTEXT=unknown"
	[[ "$stderr" != *"not recorded in"* ]]
}

@test "platform_report_lines: every style, a value escaped for yaml and md, and platform_value_has finds kind in a mixed value" {
	local v=$'PLATFORM=kubernetes\nNODE_PROVIDER_BY_CONTEXT=m1=kind,m2=mixed:aws;kind'
	run platform_report_lines comment "$v"
	assert_output $'# PLATFORM=kubernetes\n# NODE_PROVIDER_BY_CONTEXT=m1=kind,m2=mixed:aws;kind'
	run platform_report_lines text "$v"
	assert_line "# platform: kubernetes"
	run platform_report_lines yaml "$v"
	assert_line 'node_provider_by_context: "m1=kind,m2=mixed:aws;kind"'
	run platform_report_lines md "$v"
	assert_line '| PLATFORM | `kubernetes` |'
	run platform_report_lines json "$v"
	assert_output '{"platform":"kubernetes","node_provider_by_context":"m1=kind,m2=mixed:aws;kind"}'
	run platform_report_lines xml "$v"
	assert_failure
	# A hand-edited value: the front matter stays parseable, the table row one row.
	v=$'PLATFORM=kube"r\\net|es'
	run platform_report_lines yaml "$v"
	assert_output 'platform: "kube\"r\\net|es"'
	run platform_report_lines md "$v"
	assert_output '| PLATFORM | `kube"r\net\|es` |'
	platform_value_has "m1=aws,m2=mixed:aws;kind" kind
	platform_value_has "m1=aws+kind" kind
	! platform_value_has "m1=aws,m2=kindest" kind || false
	! platform_value_has "unknown" kind || false
}

# ---------------------------------------------------------------------------
# Round 3: re-reads (H7), the overlay from the record (H15), TEST_PLATFORM checked up front (H6)
# ---------------------------------------------------------------------------

@test "platform_probe (H7): an inherited member with an unknown value is read again; a value only the inherited row has is kept" {
	probe_setup
	# The sweep's start: member-a did not answer, member-b did.
	PLATFORM_PROBE_ROWS=$'member-a\tunknown\tunknown\tunknown\tunknown\tunknown\tunknown\nmember-b\tkubernetes\tsail-operator:1.31.0/Available\tpilot:1.30.4\tproxyv2:1.30.4\tkind\t0123456789ab\n'
	export PLATFORM_PROBE_ROWS
	platform_probe member-a,member-b 2>"$WARN"
	grep -q -- '--context=member-a' "$CALLS"
	! grep -q -- '--context=member-b' "$CALLS" || false
	grep -q 'Platform record: reading again member-a (an unknown value in the record this step inherited)' "$WARN"
	[ "$(platform_member_value member-a platform)" = kubernetes ]
	# SC6-N1: a fleet's members read again are named five at most.
	(
		local m
		PLATFORM_PROBE_ROWS=""
		for m in m1 m2 m3 m4 m5 m6 m7; do PLATFORM_PROBE_ROWS+="${m}"$'\tunknown\tunknown\tunknown\tunknown\tunknown\tunknown\n'; done
		export PLATFORM_PROBE_ROWS
		platform_probe m1,m2,m3,m4,m5,m6,m7 2>"${WARN}.fleet"
	)
	grep -qx 'Platform record: reading again m1, m2, m3, m4, m5 and 2 more (an unknown value in the record this step inherited)' "${WARN}.fleet"
	[ "$(platform_member_value member-a istiod)" = "pilot:1.30.5@${DIG_B}" ]
	[ "$(platform_member_value member-b istiod)" = pilot:1.30.4 ]
	[ "$(platform_recorded_contexts)" = member-a,member-b ]
	# A read that gets less than the inherited row: the inherited values stay, each with a note.
	PLATFORM_PROBE_ROWS=$'member-c\tkubernetes\tunknown\tpilot:1.30.4\tproxyv2:1.30.4\tkind\t0123456789ab\n'
	: > "$CALLS"
	PROBE_PLATFORM=down platform_probe member-c 2>"$WARN"
	grep -q -- '--context=member-c' "$CALLS"
	[ "$(platform_member_value member-c platform)" = kubernetes ]
	[ "$(platform_member_value member-c operator)" = unknown ]
	[ "$(platform_member_value member-c istiod)" = pilot:1.30.4 ]
	grep -q "member-c: keeps the platform of the record it inherited (kubernetes), read before this step; this read could not get it" "$WARN"
	grep -q "member-c: keeps the gateway proxy build of the record it inherited (proxyv2:1.30.4)" "$WARN"
	grep -q "member-c: keeps the istiod settings (its discovery container env) of the record it inherited (0123456789ab)" "$WARN"
}

@test "platform_probe (H7): nothing is read again after platform_probe_load (inside a window) or in a dry-run" {
	probe_setup
	PLATFORM_PROBE_ROWS=$'member-a\tunknown\tunknown\tunknown\tunknown\tunknown\tunknown\n'
	export PLATFORM_PROBE_ROWS
	DRY_RUN=1 platform_probe member-a
	[ ! -s "$CALLS" ]
	platform_probe_load "${BATS_TEST_TMPDIR}/missing.tsv"
	platform_probe member-a
	[ ! -s "$CALLS" ]
	[ "$(platform_member_value member-a platform)" = unknown ]
	# A saved record that knows more replaces an inherited row of unknowns.
	printf 'member-a\tkubernetes\top\tistiod\tproxy\tkind\te\n' > "${BATS_TEST_TMPDIR}/saved.tsv"
	platform_probe_load "${BATS_TEST_TMPDIR}/saved.tsv"
	[ "$(platform_member_value member-a istiod)" = istiod ]
}

@test "platform_probe_share (S-B1): a 500-member record reaches a sweep's steps through a file, never the environment" {
	local i ctx csv="" rows="" dir="${BATS_TEST_TMPDIR}/sweep-x"
	probe_setup
	# 499 members as a sweep's start read them (long context names, full digests: about 330
	# bytes a row), the 500th read now: over 128 KiB, Linux's limit on one environment string.
	for ((i = 1; i <= 500; i++)); do
		printf -v ctx 'scale-campaign-region-a-member-%03d.example.invalid' "$i"
		csv+="${csv:+,}${ctx}"
		((i == 500)) || rows+="${ctx}"$'\t'kubernetes$'\t'"sail-operator:1.31.1@${DIG_A}/Available"$'\t'"pilot:1.30.5@${DIG_B}"$'\t'"proxyv2:1.30.5@${DIG_C}"$'\t'aws$'\t'0123456789ab$'\t'none$'\n'
	done
	PLATFORM_PROBE_ROWS="$rows"
	platform_probe "$csv" 2>"$WARN"
	[ "${#PLATFORM_PROBE_ROWS}" -gt 131072 ]
	# Only the 500th member was read; every command after the probe still runs (an exported
	# record made each one fail with "Argument list too long").
	[ "$(grep -c -- '--context=scale-campaign-region-a-member-500.example.invalid ' "$CALLS")" -eq 5 ]
	[ "$(wc -l < "$CALLS")" -eq 5 ]
	run env true
	assert_success
	platform_probe_share "$dir"
	[ "$PLATFORM_PROBE_FILE" = "${dir}/platform-record.txt" ]
	[ "$(wc -l < "$PLATFORM_PROBE_FILE")" -eq 500 ]
	# A step the sweep runs reads the file as it sources platform.sh: it holds every member, reads
	# none of them again, and its own commands run.
	: > "$CALLS"
	run bash -c 'set -euo pipefail; source "$1/tests/lib/common.sh"; source "$1/tests/lib/reach.sh"; source "$1/tests/lib/config.sh"; source "$1/tests/lib/platform.sh"
		_k() { printf "%s\n" "$*" >>"$CALLS"; return 1; }
		KUBECTL=(_k); DRY_RUN=0
		platform_probe "$2"
		env true
		echo "$(platform_recorded_contexts | tr , "\n" | grep -c .) $(platform_member_value "${2##*,}" istiod) $(platform_member_value "${2%%,*}" nodes)"' _ "$ROOT" "$csv"
	assert_success
	assert_output "500 pilot:1.30.5@${DIG_B} aws"
	[ ! -s "$CALLS" ]
	# A file that cannot be read: the step says so and reads its own members.
	run bash -c 'source "$1/tests/lib/common.sh"; source "$1/tests/lib/platform.sh"; echo "rows=${#PLATFORM_PROBE_ROWS}"' _ "$ROOT"
	assert_success
	assert_output --partial "rows=$(wc -c < "$PLATFORM_PROBE_FILE")"
	PLATFORM_PROBE_FILE="${dir}/missing.txt" run --separate-stderr bash -c 'source "$1/tests/lib/common.sh"; source "$1/tests/lib/platform.sh"; echo "rows=${#PLATFORM_PROBE_ROWS}"' _ "$ROOT"
	assert_output "rows=0"
	[[ "$stderr" == *"warning: cannot read the sweep's platform record (PLATFORM_PROBE_FILE: ${dir}/missing.txt); this step reads its own members' record"* ]]
	# A dry-run writes no file and exports no path.
	rm -rf "$dir"
	unset PLATFORM_PROBE_FILE
	DRY_RUN=1 platform_probe_share "$dir"
	[ ! -e "$dir" ]
	[ -z "${PLATFORM_PROBE_FILE:-}" ]
}

@test "platform_help_lines (U-S-a, R6): every sweep's --help names TEST_PLATFORM, PLATFORM_READ_TIMEOUT and PLATFORM_READ_PARALLEL with their values" {
	local f
	for f in tests/propagation/006-run-sweep.sh tests/controlplane/003-run-sweep.sh tests/dataplane/003-run-sweep.sh \
		tests/churn/003-run-sweep.sh tests/churn-dataplane/004-run-sweep.sh tests/gateway-api/001-run-ingress-check.sh \
		tests/tuning/003-run-tuning-sweep.sh; do
		PLATFORM_READ_TIMEOUT=45s PLATFORM_READ_PARALLEL=7 run --separate-stderr "${ROOT}/${f}" --help
		assert_success
		[ -z "$stderr" ] || { echo "${f}: ${stderr}"; false; }
		assert_output --partial "PLATFORM_READ_TIMEOUT (45s): the bound on each read of the"
		assert_output --partial "PLATFORM_READ_PARALLEL (7): how many members' platform records"
		assert_output --partial "TEST_PLATFORM ("
	done
	# 001-apply-profile.sh reads every member's tuning objects with them.
	PLATFORM_READ_PARALLEL=7 run "${ROOT}/tests/tuning/001-apply-profile.sh" --help
	assert_output --partial "PLATFORM_READ_PARALLEL (7): how many members' platform records"
	run platform_help_lines reads
	refute_output --partial TEST_PLATFORM
	assert_output --partial "PLATFORM_READ_TIMEOUT ("
	assert_output --partial "PLATFORM_READ_PARALLEL ("
	run platform_help_lines all
	assert_output --partial "TEST_PLATFORM ("
	assert_output --partial "PLATFORM_READ_TIMEOUT ("
	assert_output --partial "PLATFORM_READ_PARALLEL ("
	# Every caller names its variant: a call without one is shellcheck's SC2119 (CI's version
	# flags it).
	! grep -n 'platform_help_lines)' "$ROOT"/tests/*/0*.sh || false
}

# first_step_line <sweep>: the first line of its main flow (outside function bodies, comments
# skipped) that runs a step: a "$SCRIPT_DIR/0NN-..." command, through sweep_step or not, or a call
# of a function whose body runs one, itself or through another such function (controlplane's
# leftover check runs 005-cleanup.sh before the first cell).
first_step_line() {
	awk '
		function isstep(l) { return l ~ /(^|[[:space:];!(])(sweep_step[[:space:]]+)?"\$SCRIPT_DIR\/0[0-9][0-9]-/ }
		function mentions(l, g) { return match(l, "(^|[^A-Za-z0-9_])" g "([^A-Za-z0-9_]|$)") > 0 }
		{ line[NR] = $0 }
		END {
			infn = ""
			for (i = 1; i <= NR; i++) {
				l = line[i]
				if (infn == "" && l ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/) {
					f = substr(l, 1, index(l, "(") - 1)
					body[f] = body[f] "\n" l
					# A one-line definition ends where it starts.
					if (!(l ~ /\}[[:space:]]*$/ && l !~ /\{[[:space:]]*$/)) infn = f
					continue
				}
				if (infn != "") {
					if (l ~ /^\}/) infn = ""
					else if (l !~ /^[[:space:]]*#/) body[infn] = body[infn] "\n" l
					continue
				}
				main[i] = 1
			}
			for (f in body) if (isstep(body[f])) runs[f] = 1
			do {
				more = 0
				for (f in body) {
					if (f in runs) continue
					for (g in runs) if (mentions(body[f], g)) { runs[f] = 1; more = 1; break }
				}
			} while (more)
			for (i = 1; i <= NR; i++) {
				if (!(i in main) || line[i] ~ /^[[:space:]]*#/) continue
				if (isstep(line[i])) { print i; exit }
				for (g in runs) if (mentions(line[i], g)) { print i; exit }
			}
		}' "$1"
}

@test "platform_probe_share (S-B1, U5-Ba): every suite sweep shares its record right after its probe and warns from it, before its first step; nothing exports the record" {
	local f p sh sw st n=0
	for f in "$ROOT"/tests/*/0*-run-sweep.sh; do
		[[ "$f" != */tuning/* ]] || continue
		n=$((n + 1))
		p="$(grep -n '^[[:space:]]*platform_probe "' "$f" | head -n 1 | cut -d: -f1)"
		sh="$(grep -n '^[[:space:]]*platform_probe_share "' "$f" | head -n 1 | cut -d: -f1)"
		sw="$(grep -n '^[[:space:]]*platform_start_warnings "' "$f" | head -n 1 | cut -d: -f1)"
		st="$(first_step_line "$f")"
		[[ -n "$p" && -n "$sh" && -n "$sw" && -n "$st" ]] || { echo "${f}: probe '${p}', share '${sh}', warnings '${sw}', first step '${st}'"; false; }
		((p < sh && sh < sw && sw < st)) || { echo "${f}: probe (line ${p}), share (line ${sh}), warnings (line ${sw}), first step (line ${st}) out of order"; false; }
	done
	[ "$n" -eq 5 ]
	! grep -rn 'export PLATFORM_PROBE_ROWS\|export -p PLATFORM_PROBE_ROWS\|declare -x PLATFORM_PROBE_ROWS' "$ROOT"/tests/*/0*.sh "$ROOT"/tests/lib/*.sh || false
}

@test "platform_chart_args (H15): with auto, a member the record holds is not asked again; one it lacks or holds unknown is" {
	local a=(stale)
	PLATFORM_PROBE_ROWS=$'member-a\topenshift\tx\ty\tz\taws\te\nmember-u\tunknown\tunknown\tunknown\tunknown\tunknown\tunknown\n'
	FAKE_PLATFORM=kubernetes platform_chart_args "$CHART" member-a a
	[ "${a[*]}" = "-f ${CHART}/values-openshift.yaml" ]
	[ ! -s "$CALLS" ]
	FAKE_PLATFORM=kubernetes platform_chart_args "$CHART" member-u a
	[ "${#a[@]}" -eq 0 ]
	grep -q -- '--context=member-u' "$CALLS"
	: > "$CALLS"
	FAKE_PLATFORM=openshift platform_chart_args "$CHART" member-new a
	[ "${#a[@]}" -eq 2 ]
	grep -q -- '--context=member-new' "$CALLS"
	# An override wins over the record, exactly as in platform_of.
	: > "$CALLS"
	TEST_PLATFORM=kubernetes platform_chart_args "$CHART" member-a a
	[ "${#a[@]}" -eq 0 ]
	[ ! -s "$CALLS" ]
}

@test "H6: every CI dry-run and every report rejects a bad TEST_PLATFORM before anything else" {
	local ek="${BATS_TEST_TMPDIR}/kubeconfig" f args n=0
	: > "$ek"
	while IFS= read -r f; do
		args="$(grep -m1 '^# ci-dry-run:' "$f" | sed 's/^# ci-dry-run://')"
		# shellcheck disable=SC2086  # the annotation's words
		TEST_PLATFORM=k8s KUBECONFIG="$ek" run bash "$f" --dry-run $args
		[ "$status" -ne 0 ] || { echo "${f}: exit 0 with TEST_PLATFORM=k8s"; false; }
		[[ "$output" == *"TEST_PLATFORM must be auto, kubernetes or openshift (got: k8s)"* ]] || { echo "${f}: ${output}"; false; }
		n=$((n + 1))
	done < <(grep -l '^# ci-dry-run:' "$ROOT"/tests/*/0*.sh)
	[ "$n" -ge 26 ]
	for f in dataplane/004-report-results.sh propagation/005-report-results.sh churn/004-report-results.sh \
		churn-dataplane/005-report-results.sh controlplane/004-report-results.sh tuning/004-compare-profiles.sh; do
		TEST_PLATFORM=k8s run bash "${ROOT}/tests/${f}" --results-dir "$BATS_TEST_TMPDIR"
		assert_failure
		assert_output --partial "TEST_PLATFORM must be auto, kubernetes or openshift (got: k8s); set it in the environment, config/options.env or, in a script that takes one, the --config file"
	done
}

@test "H6: every suite script that sources platform.sh checks TEST_PLATFORM with its arguments (platform_validate)" {
	local f
	for f in "$ROOT"/tests/*/0*.sh; do
		grep -q 'source "${ROOT}/tests/lib/platform.sh"' "$f" || continue
		grep -qx 'platform_validate' "$f" || { echo "${f}: sources platform.sh without a top-level platform_validate"; false; }
	done
}

@test "H2, H10: every suite sweep checks its record for drift before its first report; every report warns in its body" {
	local f d r n=0
	# tuning 003 checks each pass instead (its own test) and compares the passes in 004.
	for f in "$ROOT"/tests/*/0*-run-sweep.sh; do
		[[ "$f" != */tuning/* ]] || continue
		n=$((n + 1))
		d="$(grep -n '^platform_drift_check "' "$f" | head -n 1 | cut -d: -f1)"
		r="$(grep -n 'report-results.sh"* --results-dir\|render_scale_envelope "' "$f" | head -n 1 | cut -d: -f1)"
		[[ -n "$d" && -n "$r" ]] || { echo "${f}: platform_drift_check at '${d}', first report at '${r}'"; false; }
		((d < r)) || { echo "${f}: platform_drift_check (line ${d}) after its first report (line ${r})"; false; }
	done
	[ "$n" -eq 5 ]
	for f in dataplane/004-report-results.sh propagation/005-report-results.sh churn/004-report-results.sh \
		churn-dataplane/005-report-results.sh controlplane/004-report-results.sh; do
		grep -q 'platform_report_warnings ' "${ROOT}/tests/${f}" || { echo "${f}: no platform_report_warnings"; false; }
	done
	# tuning 004 merges each pass's record and compares it with the reference pass's, on every
	# key but istiod's settings (a profile changes them on purpose) and on the tuning levers, the
	# root Sidecar's egress hosts and istiod's limits (platform_lever_values), and says what
	# changed or was not compared during each pass (platform_drift_changes and
	# platform_drift_unread, from the pass's drift file); its notes say what differs.
	f="${ROOT}/tests/tuning/004-compare-profiles.sh"
	grep -q 'platform_report_values ' "$f" || { echo "${f}: no platform_report_values"; false; }
	grep -q '^COMPARE_KEYS=("${PLATFORM_PASS_KEYS\[@\]}" ' "$f" || { echo "${f}: COMPARE_KEYS does not start with PLATFORM_PASS_KEYS"; false; }
	grep -q 'platform_compare_values .*"${COMPARE_KEYS\[@\]}"' "$f" || { echo "${f}: no platform_compare_values over COMPARE_KEYS"; false; }
	grep -q 'platform_lever_values ' "$f" || { echo "${f}: no platform_lever_values"; false; }
	grep -q 'platform_drift_changes ' "$f" || { echo "${f}: no platform_drift_changes"; false; }
	grep -q 'platform_drift_unread ' "$f" || { echo "${f}: no platform_drift_unread"; false; }
}

@test "H6: every script that calls platform_probe or platform_drift_check sources reach.sh and config.sh (address masking, the istiod env digest)" {
	local f seen=""
	for f in "$ROOT"/tests/*/0*.sh; do
		grep -qE '(^[[:space:]]*|(\|\||&&)[[:space:]]*)(platform_probe|platform_drift_check) ' "$f" || continue
		seen+=" ${f#"${ROOT}/tests/"}"
		grep -q 'source "${ROOT}/tests/lib/reach.sh"' "$f" || { echo "${f}: calls platform_probe or platform_drift_check without reach.sh"; false; }
		grep -q 'source "${ROOT}/tests/lib/config.sh"' "$f" || { echo "${f}: calls platform_probe or platform_drift_check without config.sh"; false; }
	done
	# A call after || counts: controlplane 001 and 005 read the record for a new ns-lifecycle TSV (H3).
	[[ "$seen " == *" controlplane/001-setup-controlplane-test.sh "* && "$seen " == *" controlplane/005-cleanup.sh "* ]] || { echo "callers:${seen}"; false; }
	# tuning 003 reads each pass's record, and its drift check reads istiod's limits (capacity.sh).
	[[ "$seen " == *" tuning/003-run-tuning-sweep.sh "* ]] || { echo "callers:${seen}"; false; }
	grep -q 'source "${ROOT}/tests/lib/capacity.sh"' "${ROOT}/tests/tuning/003-run-tuning-sweep.sh"
}

@test "tuning 003 (I6-B1): each pass forgets the last pass's record, reads its own and shares it before its probes, and reads it again after them" {
	local f="${ROOT}/tests/tuning/003-run-tuning-sweep.sh" body r p s w d
	body="$(sed -n '/^run_pass() {$/,/^}$/p' "$f")"
	[ -n "$body" ]
	r="$(grep -n '^[[:space:]]*platform_probe_reset$' <<<"$body" | cut -d: -f1)"
	p="$(grep -n '^[[:space:]]*platform_probe "$CONTEXTS_CSV"$' <<<"$body" | cut -d: -f1)"
	s="$(grep -n '^[[:space:]]*platform_probe_share "$dir"$' <<<"$body" | cut -d: -f1)"
	w="$(grep -n '^[[:space:]]*while probe_argv ' <<<"$body" | cut -d: -f1)"
	# Its messages name the pass, not the sweep (run=pass).
	d="$(grep -n '^[[:space:]]*platform_drift_check "$dir" "$CONTEXTS_CSV" pass$' <<<"$body" | cut -d: -f1)"
	[[ -n "$r" && -n "$p" && -n "$s" && -n "$w" && -n "$d" ]] || { echo "reset '${r}', probe '${p}', share '${s}', probes '${w}', drift '${d}'"; false; }
	((r < p && p < s && s < w && w < d)) || { echo "reset ${r}, probe ${p}, share ${s}, probes ${w}, drift ${d}: out of order"; false; }
	# A failed probe ends the probes, not the pass: its record is still read again.
	sed -n "${w},${d}p" <<<"$body" | grep -q '^[[:space:]]*break$'
	! sed -n "${w},${d}p" <<<"$body" | grep -q '^[[:space:]]*return' || false
}

@test "platform_probe_reset (I6-B1): the next platform_probe reads every member again and stops handing the old record to the steps" {
	local dir="${BATS_TEST_TMPDIR}/pass"
	probe_setup
	platform_probe member-a,member-b 2>/dev/null
	platform_probe_share "$dir"
	[ "$PLATFORM_PROBE_FILE" = "${dir}/platform-record.txt" ]
	: > "$CALLS"
	# Without the reset, the record read is reused.
	platform_probe member-a,member-b 2>/dev/null
	[ ! -s "$CALLS" ]
	platform_probe_reset
	[ -z "$PLATFORM_PROBE_ROWS" ]
	[ -z "${PLATFORM_PROBE_FILE+x}" ]
	[ -z "${PLATFORM_PROBE_LOADED+x}" ]
	PROBE_ISTIOD_THROTTLE=50 platform_probe member-a,member-b 2>/dev/null
	grep -q -- '--context=member-a' "$CALLS"
	grep -q -- '--context=member-b' "$CALLS"
	[ "$(platform_member_value member-a istiod_env)" = "$(env_digest "$(env_list 50)")" ]
	# After a platform_probe_load too (a step inside a window reads nothing until reset).
	printf 'member-a\tkubernetes\top\tistiod\tproxy\tkind\te\n' > "${BATS_TEST_TMPDIR}/saved.tsv"
	platform_probe_load "${BATS_TEST_TMPDIR}/saved.tsv"
	platform_probe_reset
	: > "$CALLS"
	platform_probe member-a 2>/dev/null
	grep -q -- '--context=member-a' "$CALLS"
	[ "$(platform_member_value member-a istiod)" != istiod ]
}

@test "platform_members_by_value (U6-S2): each value with its members, five named, mixed values spelled out, digests shortened" {
	local d="sha256:$(printf 'ab%.0s' {1..32})"
	run platform_members_by_value "a=x,b=y,c=x"
	assert_output "x on a, c; y on b"
	run platform_members_by_value "m1=x,m2=x,m3=x,m4=x,m5=x,m6=x,m7=x,n=pilot:1.30.5@${d}"
	assert_output "x on m1, m2, m3, m4, m5 and 2 more; pilot:1.30.5@sha256:abababababab on n"
	# A token without a member: some inputs predate the key (M13-N3).
	run platform_members_by_value "mixed:unknown,a=mixed:x;y,b=x"
	assert_output "not recorded in some of its TSVs; mixed: x and y on a; x on b"
}

@test "H3: every writer of the ns-lifecycle TSV reads the platform record before it creates the file" {
	local f p i n=0
	for f in "$ROOT"/tests/*/0*.sh; do
		i="$(grep -n '^[[:space:]]*ns_lifecycle_init "' "$f" | head -n 1 | cut -d: -f1)"
		[[ -n "$i" ]] || continue
		n=$((n + 1))
		p="$(grep -nE '(^[[:space:]]*|\|\|[[:space:]]*)platform_probe ' "$f" | head -n 1 | cut -d: -f1)"
		[[ -n "$p" ]] && ((p < i)) || { echo "${f}: ns_lifecycle_init at line ${i}, platform_probe at '${p}'"; false; }
	done
	[ "$n" -eq 3 ]
	# A standalone 001 or 005 reads it only for a new file: in a sweep, 003 created the file after
	# its own read, and a second read would be another call per member for nothing.
	for f in controlplane/001-setup-controlplane-test.sh controlplane/005-cleanup.sh; do
		grep -qxF '	[[ -f "$LIFECYCLE_FILE" ]] || platform_probe "$(IFS=,; echo "${CONTEXTS[*]}")"' "${ROOT}/tests/${f}" ||
			{ echo "${f}: no new-file platform_probe before ns_lifecycle_init"; false; }
	done
}

# ---------------------------------------------------------------------------
# --resume (H1): platform_resume_check against the TSV a sweep started
# ---------------------------------------------------------------------------

# resume_tsv <file> [sed program]: the controlplane TSV a sweep started on member-a,member-b, with
# what 003's preamble records from _probe_kubectl now (edited by the sed program): the record
# (platform_probe), KUBE_VERSIONS, the capacity lines of member-a (cap_node_totals,
# cap_istiod_limits), its tuning baseline (tuning_baseline_state) and the infra block
# (env_collect_infra); then a header and a row. Leaves PLATFORM_PROBE_ROWS reset.
resume_tsv() {
	local nt lim
	probe_setup
	platform_probe member-a,member-b 2>/dev/null
	nt="$(cap_node_totals member-a "${KUBECTL[@]}")"
	lim="$(cap_istiod_limits member-a "${KUBECTL[@]}")"
	{
		echo "# Control-plane resource metrics"
		{
			echo "# KUBE_VERSIONS=$(probe_kube_versions member-a,member-b "${KUBECTL[@]}")"
			echo "# NODE_ALLOC_CPU_M=$(_platform_kv "$nt" cpu_m)"
			echo "# NODE_ALLOC_MEM_MI=$(_platform_kv "$nt" mem_mi)"
			echo "# ISTIOD_CPU_LIMIT_M=$(_platform_kv "$lim" cpu_m)"
			echo "# ISTIOD_MEM_LIMIT_MI=$(_platform_kv "$lim" mem_mi)"
			platform_preamble_lines member-a,member-b
			tuning_baseline_state member-a "${KUBECTL[@]}" | sed 's/^/# /'
			# shellcheck disable=SC2046  # the infra block's KEY=value words
			infra_preamble_lines $(env_collect_infra member-a,member-b "${KUBECTL[@]}")
		} | sed "${2:-}"
		printf 'timestamp\tcontext\n'
		printf 't\tmember-a\n'
	} > "$1"
	probe_setup
	: > "$CALLS"
}

# resume_run <tsv> [ctxs_csv] [source ctx]: what 003 --resume runs: a fresh record of the members
# (platform_probe), then platform_resume_check (run, stderr apart) with the source member
# (member-a unless given; "" for none). The PROBE_* settings of the call apply to both.
resume_run() {
	probe_setup
	platform_probe "${2:-member-a,member-b}" 2>/dev/null
	run --separate-stderr platform_resume_check "$1" "${2:-member-a,member-b}" "${3-member-a}"
}

@test "platform_resume_check (H1, H18): the same record, levers, limits and versions proceed, with one line on stdout" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv"
	resume_tsv "$tsv"
	# What 003's preamble records, every value read.
	grep -qx '# KUBE_VERSIONS=member-a=v1.33.1,member-b=v1.33.1' "$tsv"
	grep -qx '# ISTIOD_CPU_LIMIT_M=2000' "$tsv"
	grep -qx '# ISTIOD_MEM_LIMIT_MI=4096' "$tsv"
	grep -qx '# NODE_ALLOC_CPU_M=8000' "$tsv"
	grep -qx '# ISTIOD_REPLICAS_BY_CONTEXT=member-a=1,member-b=1' "$tsv"
	grep -qx '# NETWORK_TOPOLOGY=multi-primary,multi-network:2' "$tsv"
	grep -qx '# TUNING_BASELINE=sidecar=on,discoverySelectors=off,telemetryFiltering=off,accessLogFiltering=off' "$tsv"
	resume_run "$tsv"
	assert_success
	[ -z "$stderr" ] || { echo "$stderr"; false; }
	assert_output "Platform record: comparing what member-a, member-b run now with what ${tsv} recorded at the sweep's start (--resume)"
	grep -q -- '--context=member-a .*get sidecar.networking.istio.io default -o name --ignore-not-found' "$CALLS"
	grep -q -- '--context=member-a .*-n istio-system get deploy istiod -o json' "$CALLS"
	grep -q -- '--context=member-b .*version --output=json' "$CALLS"
}

@test "platform_resume_check (H1): another build dies naming the member, the key, both values and how to start a new sweep" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv"
	resume_tsv "$tsv"
	PROBE_ISTIOD=1.30.6 resume_run "$tsv"
	assert_failure
	[[ "$stderr" == *"error: --resume: ${tsv} was started on other builds, settings or cluster values than the members have now:"* ]]
	# One line for the members that moved the same way (U5-S1).
	[[ "$stderr" == *"  member-a, member-b: ISTIOD_IMAGE_BY_CONTEXT recorded pilot:1.30.5@${DIG_B}, now pilot:1.30.6@${DIG_B}"* ]]
	[[ "$stderr" != *"  member-a: ISTIOD_IMAGE_BY_CONTEXT"* ]] || { echo "$stderr"; false; }
	[[ "$stderr" == *"The rows this run appends would be credited to what its preamble records. Start a new sweep instead: run "*" again with this sweep's flags (and --config) but without --resume; it writes a new sweep-<RUN_ID>/ in its results dir and leaves this one as it is. Or put the members back"* ]]
	[[ "$stderr" != *"config snapshot"* ]] || { echo "$stderr"; false; }
	# Another operator build too, and a cluster rebuilt onto other nodes; a sweep run with
	# --config names its snapshot, which replays the config.
	resume_tsv "$tsv" 's/member-b=kind/member-b=aws/'
	echo "CONTROLPLANE_MESH_SIZES=1,2" > "${BATS_TEST_TMPDIR}/run-config-r.env"
	PROBE_OPERATOR=1.31.2 resume_run "$tsv" member-a,member-b ""
	assert_failure
	[[ "$stderr" == *"  member-a, member-b: MESH_OPERATOR_BY_CONTEXT recorded sail-operator:1.31.1@${DIG_A}/Available, now sail-operator:1.31.2@${DIG_A}/Available"* ]]
	[[ "$stderr" == *"member-b: NODE_PROVIDER_BY_CONTEXT recorded aws, now kind"* ]]
	[[ "$stderr" == *"This sweep's config snapshot replays its --config values: "*" --config $(printf '%q' "${BATS_TEST_TMPDIR}/run-config-r.env") (plus the flags it ran with besides --config). Or put the members back"* ]]
}

@test "platform_resume_check (H1): another Kubernetes version, istiod limit or istiod settings die; what is not read warns, saying which side" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv"
	resume_tsv "$tsv"
	# A cluster rebuilt under the same name (on kind it differs only in its version).
	PROBE_KUBE_VERSION=v1.34.0 resume_run "$tsv"
	assert_failure
	[[ "$stderr" == *"  member-a, member-b: KUBE_VERSIONS recorded v1.33.1, now v1.34.0"* ]]
	# istiod's limits: the denominators of the report's istiod limit figures and its verdict.
	PROBE_ISTIOD_CPU_LIMIT=4 PROBE_ISTIOD_MEM_LIMIT=8Gi resume_run "$tsv"
	assert_failure
	[[ "$stderr" == *"  member-a: ISTIOD_CPU_LIMIT_M recorded 2000, now 4000"* ]]
	[[ "$stderr" == *"  member-a: ISTIOD_MEM_LIMIT_MI recorded 4096, now 8192"* ]]
	[[ "$stderr" == *"warning: --resume: member-a: ISTIOD_LIM_CPU_M recorded 2000, now 4000; the report shows the recorded value; its istiod limit figures use ISTIOD_CPU_LIMIT_M and ISTIOD_MEM_LIMIT_MI"* ]]
	[[ "$stderr" == *"Usual causes: ISTIOD_CPU_LIMIT_M: an Argo CD sync, a tuning profile or a hand edit of istiod's resources (the Istio CR's spec.values.pilot.resources); ISTIOD_MEM_LIMIT_MI: an Argo CD sync, "* ]]
	# istiod's settings (H25): a tuning profile's pilot env left applied.
	PROBE_ISTIOD_THROTTLE=50 resume_run "$tsv"
	assert_failure
	[[ "$stderr" == *"  member-a, member-b: ISTIOD_ENV_BY_CONTEXT recorded $(env_digest "$(env_list)"), now $(env_digest "$(env_list 50)")"* ]]
	# U-S-b: the refusal names each key's usual cause once, so the operator can revert and resume.
	[[ "$stderr" == *"Usual causes: ISTIOD_ENV_BY_CONTEXT: a tuning profile applied or reverted on these members (by a tuning run, or one stopped before its revert, which tests/tuning/005-cleanup.sh undoes), or a sync or hand edit of the Istio CR's spec.values.pilot.env."* ]]
	[ "$(grep -c 'Usual causes' <<<"$stderr")" -eq 1 ]
	# A tuning profile's objects left in place since the rows were measured (R5).
	PROBE_TUNING_OBJECTS=04 resume_run "$tsv"
	assert_failure
	[[ "$stderr" == *"  member-a, member-b: TUNING_OBJECTS_BY_CONTEXT recorded none, now 04-connection-pools:DestinationRule/istio-system/tuning-connection-pool"* ]] || { echo "$stderr"; false; }
	[[ "$stderr" == *"Usual causes: TUNING_OBJECTS_BY_CONTEXT: a tuning profile applied or reverted on these members (by a tuning run, or one stopped before its revert, which tests/tuning/005-cleanup.sh undoes from its marker), or a profile's objects applied or deleted by hand."* ]] || { echo "$stderr"; false; }
	# Not read now: a warning that says so (and why), and the run goes on.
	PROBE_KUBE=down resume_run "$tsv"
	assert_success
	[[ "$stderr" == *"warning: --resume: member-a, member-b: KUBE_VERSIONS: could not be read now (unreachable), so this run cannot tell whether it changed since its rows were measured"* ]] || { echo "$stderr"; false; }
	PROBE_ISTIOD_DEPLOY=missing resume_run "$tsv"
	assert_success
	[[ "$stderr" == *"warning: --resume: member-a: ISTIOD_CPU_LIMIT_M, ISTIOD_MEM_LIMIT_MI, ISTIOD_REQ_CPU_M, "*": could not be read now, so this run cannot tell whether they changed since its rows were measured"* ]] || { echo "$stderr"; false; }
	# A TSV from before a key: not in its record.
	resume_tsv "$tsv" '/KUBE_VERSIONS=\|ISTIOD_CPU_LIMIT_M=\|ISTIOD_ENV_BY_CONTEXT=/d'
	resume_run "$tsv"
	assert_success
	[[ "$stderr" == *"warning: --resume: member-a: ISTIOD_ENV_BY_CONTEXT, KUBE_VERSIONS, ISTIOD_CPU_LIMIT_M: not in the record of ${tsv} (it predates the key), so this run cannot tell whether they changed since its rows were measured"* ]] || { echo "$stderr"; false; }
	[[ "$stderr" == *"warning: --resume: member-b: ISTIOD_ENV_BY_CONTEXT, KUBE_VERSIONS: not in the record of ${tsv} (it predates the key)"* ]] || { echo "$stderr"; false; }
	[[ "$stderr" != *"error:"* ]]
}

@test "platform_resume_check (H1): what the report only shows warns and proceeds: node allocatable, istiod requests and replicas, the network topology" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv"
	resume_tsv "$tsv"
	PROBE_NODE_CPU=16 PROBE_ISTIOD_REQ_CPU=1 PROBE_ISTIOD_REPLICAS=2 PROBE_NETWORK=net-1 resume_run "$tsv"
	assert_success
	[[ "$stderr" == *"warning: --resume: member-a: NODE_ALLOC_CPU_M recorded 8000, now 16000; a cluster autoscaler moves it; each row's node figures are its own reads"* ]]
	[[ "$stderr" == *"warning: --resume: member-a: ISTIOD_REQ_CPU_M recorded 500, now 1000; the report shows the recorded value; its istiod limit figures use ISTIOD_CPU_LIMIT_M and ISTIOD_MEM_LIMIT_MI"* ]]
	[[ "$stderr" == *"warning: --resume: member-a, member-b: ISTIOD_REPLICAS_BY_CONTEXT recorded 1, now 2; an HPA moves it, the report shows the recorded count while each row records its own istiod pods"* ]]
	[[ "$stderr" == *"warning: --resume: member-a, member-b: NETWORK_TOPOLOGY recorded multi-primary,multi-network:2, now single-network; the report labels every row with the recorded one"* ]]
	[[ "$stderr" != *"error:"* ]]
}

@test "platform_resume_check (H2): a replica or the operator with no started pod warns (@unknown) and proceeds; a pinned digest is compared" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv"
	resume_tsv "$tsv"
	# A Pending or evicted istiod replica next to the running one: the same build, silently.
	PROBE_ISTIOD_PODS=pending resume_run "$tsv"
	assert_success
	[ -z "$stderr" ] || { echo "$stderr"; false; }
	PROBE_ISTIOD_PODS=evicted resume_run "$tsv"
	assert_success
	[ -z "$stderr" ] || { echo "$stderr"; false; }
	# Only a Pending replica, and the operator scaled to 0: not read, a warning, never another build.
	PROBE_ISTIOD_PODS=only-pending PROBE_SAIL_PODS=none PROBE_SAIL_AVAILABLE=0 resume_run "$tsv"
	assert_success
	[ "$(platform_member_value member-a istiod)" = "pilot:1.30.5@unknown" ]
	[ "$(platform_member_value member-a operator)" = "sail-operator:1.31.1@unknown/Unavailable" ]
	[[ "$stderr" == *"warning: --resume: member-a, member-b: MESH_OPERATOR_BY_CONTEXT, ISTIOD_IMAGE_BY_CONTEXT: read with a digest @unknown now (no pod has started), so this run cannot tell whether they changed since its rows were measured"* ]]
	[[ "$stderr" != *"error:"* ]]
	# A digest the spec pins is definite: the same one proceeds, another one stops.
	PROBE_ISTIOD_PODS=pinned-pending resume_run "$tsv"
	assert_success
	[ -z "$stderr" ] || { echo "$stderr"; false; }
	PROBE_ISTIOD_PODS=pinned-pending PROBE_ISTIOD_PIN="$DIG_A" resume_run "$tsv"
	assert_failure
	[[ "$stderr" == *"  member-a, member-b: ISTIOD_IMAGE_BY_CONTEXT recorded pilot:1.30.5@${DIG_B}, now pilot:1.30.5@${DIG_A}"* ]]
	# A TSV that recorded @unknown: a warning that says the record lacks the digest.
	resume_tsv "$tsv" "s/member-b=pilot:1.30.5@${DIG_B}/member-b=pilot:1.30.5@unknown/"
	resume_run "$tsv"
	assert_success
	[[ "$stderr" == *"warning: --resume: member-b: ISTIOD_IMAGE_BY_CONTEXT: recorded with a digest @unknown in ${tsv} (no pod had started), so this run cannot tell whether it changed since its rows were measured"* ]]
}

@test "platform_resume_check (H1): an operator that only changed its state proceeds" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv"
	resume_tsv "$tsv"
	PROBE_SAIL_AVAILABLE=0 resume_run "$tsv"
	[ "$(platform_member_value member-a operator)" = "sail-operator:1.31.1@${DIG_A}/Unavailable" ]
	assert_success
	[ -z "$stderr" ] || { echo "$stderr"; false; }
}

@test "platform_resume_check (H1, H11, H28): unknown on either side says which, a member on one side only, another TEST_PLATFORM: warnings only" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv"
	resume_tsv "$tsv" 's/member-b=pilot:[^,]*/member-b=unknown/'
	TEST_PLATFORM=kubernetes resume_run "$tsv"
	assert_success
	[[ "$stderr" == *"warning: --resume: member-b: ISTIOD_IMAGE_BY_CONTEXT: unknown in the record of ${tsv} (not read at the sweep's start), so this run cannot tell whether it changed since its rows were measured"* ]]
	[[ "$stderr" == *"warning: --resume: ${tsv} was started with TEST_PLATFORM=auto, this run has TEST_PLATFORM=kubernetes"* ]]
	# H26: no value printed twice.
	[[ "$stderr" != *unknownunknown* ]]
	# Now: member-a does not answer; member-c is new; member-b is no longer a member.
	resume_tsv "$tsv"
	probe_setup
	PROBE_PLATFORM=down platform_probe member-a 2>/dev/null
	platform_probe member-c 2>/dev/null
	run --separate-stderr platform_resume_check "$tsv" member-a,member-c
	assert_success
	[[ "$stderr" == *"warning: --resume: member-a: PLATFORM_BY_CONTEXT, MESH_OPERATOR_BY_CONTEXT, ISTIOD_IMAGE_BY_CONTEXT, PROXY_IMAGE_BY_CONTEXT, NODE_PROVIDER_BY_CONTEXT, ISTIOD_ENV_BY_CONTEXT, TUNING_OBJECTS_BY_CONTEXT: could not be read now (the warnings above say why), so this run cannot tell whether they changed since its rows were measured"* ]]
	[[ "$stderr" == *"warning: --resume: member-c is a member of this run but not of the record in ${tsv}: the preamble is not rewritten on --resume, so its builds are never recorded and the report does not list it; start a new sweep to record it"* ]]
	[[ "$stderr" == *"warning: --resume: member-b is in the record of ${tsv} but not a member of this run"* ]]
	# A source member that is not in this run: the levers and limits are read on this run's first.
	resume_tsv "$tsv"
	resume_run "$tsv" member-b member-b
	assert_success
	[[ "$stderr" == *"warning: --resume: ${tsv} read TUNING_BASELINE and istiod's limits on member-a, which is not a member of this run; comparing them with member-b's"* ]]
}

@test "platform_resume_check (H12): a context name the record sanitizes is compared under that name" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv"
	probe_setup
	platform_probe "member a,member-b" 2>/dev/null
	{ echo "# Control-plane resource metrics"; platform_preamble_lines "member a,member-b"; printf 'timestamp\tcontext\nt\tmember_a\n'; } > "$tsv"
	grep -qx '# PLATFORM_BY_CONTEXT=member_a=kubernetes,member-b=kubernetes' "$tsv"
	PROBE_ISTIOD=1.30.6 resume_run "$tsv" "member a,member-b" ""
	assert_failure
	[[ "$stderr" == *"  member_a, member-b: ISTIOD_IMAGE_BY_CONTEXT recorded pilot:1.30.5@${DIG_B}, now pilot:1.30.6@${DIG_B}"* ]]
	[[ "$stderr" != *"not a member"* && "$stderr" != *"not of the record"* ]] || { echo "$stderr"; false; }
	resume_run "$tsv" "member a,member-b" ""
	assert_success
	[ -z "$stderr" ] || { echo "$stderr"; false; }
}

@test "platform_drift_check and platform_resume_check (R6, U5-S1, Sc5-S1): 500 members that moved the same way read as one line each, five named" {
	local i ctx csv="" reps="" dir="${BATS_TEST_TMPDIR}/sweep-x" tsv="${BATS_TEST_TMPDIR}/resume-x/controlplane-r.tsv"
	mkdir -p "$dir" "${BATS_TEST_TMPDIR}/resume-x"
	for ((i = 1; i <= 500; i++)); do
		printf -v ctx 'm%03d' "$i"
		csv+="${csv:+,}${ctx}"
		reps+="${reps:+,}${ctx}=1"
	done
	probe_setup
	platform_probe "$csv" 2>/dev/null
	{ echo "# Control-plane resource metrics"; platform_preamble_lines "$csv"; echo "# ISTIOD_REPLICAS_BY_CONTEXT=${reps}"; printf 'timestamp\tcontext\nt\tm001\n'; } > "$tsv"
	# Every member upgraded during the sweep: one warning, and every member in the marker. The
	# sweep holds no TSV yet: the read names the record's values only.
	PROBE_ISTIOD=1.30.6 run --separate-stderr platform_drift_check "$dir" "$csv"
	assert_success
	assert_output "Platform record: reading m001, m002, m003, m004, m005 and 495 more again, to check that no build, istiod setting or tuning profile object changed during the sweep"
	[ "$(grep -c 'ISTIOD_IMAGE_BY_CONTEXT changed during the sweep' <<<"$stderr")" -eq 1 ]
	[[ "$stderr" == *"warning: m001, m002, m003, m004, m005 and 495 more: ISTIOD_IMAGE_BY_CONTEXT changed during the sweep: pilot:1.30.5@${DIG_B} at its start, pilot:1.30.6@${DIG_B} at its end;"* ]] || { echo "$stderr" | head -c 2000; false; }
	[ "$(grep '^# ISTIOD_IMAGE_BY_CONTEXT=' "${dir}/platform-drift.txt" | tr , '\n' | grep -c '=pilot:1.30.6@')" -eq 500 ]
	# A --resume on the upgraded members: one line in the refusal, one usual cause.
	PROBE_ISTIOD=1.30.6 resume_run "$tsv" "$csv" ""
	assert_failure
	assert_output "Platform record: comparing what m001, m002, m003, m004, m005 and 495 more run now with what ${tsv} recorded at the sweep's start (--resume)"
	[[ "$stderr" == *"  m001, m002, m003, m004, m005 and 495 more: ISTIOD_IMAGE_BY_CONTEXT recorded pilot:1.30.5@${DIG_B}, now pilot:1.30.6@${DIG_B}"$'\n'"Usual causes: ISTIOD_IMAGE_BY_CONTEXT: "* ]] || { echo "$stderr" | head -c 2000; false; }
	[ "$(wc -l <<<"$stderr")" -lt 10 ]
	# C11-S2: every member's istiod scaled from 1 to 2 during the sweep, as the drift file of the
	# read at its end records it (the SC11-S1 and I10-S1 tests run that read; a second one of 500
	# members here took minutes, SC12-N1): one finding in the reports (counts without member
	# names), and every member in tuning 004's values.
	cp "$tsv" "${dir}/controlplane-r.tsv"
	{
		echo '# DRIFT_READ_AT=2026-01-01T00:00:00Z'
		printf '# ISTIOD_REPLICAS_BY_CONTEXT=%s\n' "$(sed 's/,/=2,/g; s/$/=2/' <<<"$csv")"
	} > "${dir}/platform-drift.txt"
	run platform_report_warnings "${dir}/controlplane-r.tsv"
	assert_output --partial "ISTIOD_REPLICAS_BY_CONTEXT changed during the sweep in sweep-x (platform-drift.txt): 1 to 2 on m001, m002, m003, m004, m005 and 495 more;"
	run platform_report_warnings --no-members "${dir}/controlplane-r.tsv"
	assert_output --partial "ISTIOD_REPLICAS_BY_CONTEXT changed during the sweep in sweep-x (platform-drift.txt): 1 to 2 on 500 of 500 members;"
	refute_output --partial m001
	run platform_lever_values "${dir}/controlplane-r.tsv"
	[ "$(grep '^ISTIOD_REPLICAS_BY_CONTEXT=' <<<"$output" | tr , '\n' | grep -c '=mixed:1;2$')" -eq 500 ]
}

@test "platform_drift_check (SC11-S1): istiod replica counts that changed in more than five ways warn five times, then how many more members; the report's finding names five groups" {
	local i ctx csv="" reps="" dir="${BATS_TEST_TMPDIR}/sweep"
	mkdir -p "$dir"
	# Seven members, each started at another count (1 to 7), all at 9 at the end: seven groups.
	for ((i = 1; i <= 7; i++)); do
		csv+="${csv:+,}m${i}"
		reps+="${reps:+,}m${i}=${i}"
	done
	probe_setup
	platform_probe "$csv" 2>/dev/null
	{ platform_preamble_lines "$csv"; echo "# ISTIOD_REPLICAS_BY_CONTEXT=${reps}"; printf 'timestamp\tcontext\n'; } > "${dir}/controlplane-r.tsv"
	PROBE_ISTIOD_REPLICAS=9 run --separate-stderr platform_drift_check "$dir" "$csv"
	assert_success
	[ "$(grep -c '^warning: m[0-9]: ISTIOD_REPLICAS_BY_CONTEXT changed during the sweep' <<<"$stderr")" -eq 5 ] || { echo "$stderr"; false; }
	[[ "$stderr" == *"warning: m5: ISTIOD_REPLICAS_BY_CONTEXT changed during the sweep: 5 at its start, 9 at its end;"* ]] || { echo "$stderr"; false; }
	[[ "$stderr" != *"warning: m6:"* ]] || { echo "$stderr"; false; }
	[[ "$stderr" == *"warning: and 2 more members whose ISTIOD_REPLICAS_BY_CONTEXT changed otherwise during the sweep (written to ${dir}/platform-drift.txt, which its reports say in their body)"* ]] || { echo "$stderr"; false; }
	grep -qx '# ISTIOD_REPLICAS_BY_CONTEXT=m1=9,m2=9,m3=9,m4=9,m5=9,m6=9,m7=9' "${dir}/platform-drift.txt"
	run platform_report_warnings "${dir}/controlplane-r.tsv"
	assert_output --partial "ISTIOD_REPLICAS_BY_CONTEXT changed during the sweep in sweep (platform-drift.txt): 1 to 9 on m1; 2 to 9 on m2; 3 to 9 on m3; 4 to 9 on m4; 5 to 9 on m5; and 2 more members with other changes;"
	run platform_report_warnings --no-members "${dir}/controlplane-r.tsv"
	assert_output --partial "1 to 9 on 1 of 7 members; 2 to 9 on 1 of 7 members; 3 to 9 on 1 of 7 members; 4 to 9 on 1 of 7 members; 5 to 9 on 1 of 7 members; and 2 more members with other changes;"
	refute_output --regexp 'on m[0-9]'
	run platform_drift_changes "${dir}/controlplane-r.tsv"
	assert_output $'ISTIOD_REPLICAS_BY_CONTEXT\tistiod replica counts\t1 to 9 on m1; 2 to 9 on m2; 3 to 9 on m3; 4 to 9 on m4; 5 to 9 on m5; and 2 more members with other changes'
	# One more way, by one member: "1 more member".
	rm "${dir}/platform-drift.txt"
	sed -i 's/^# ISTIOD_REPLICAS_BY_CONTEXT=.*/# ISTIOD_REPLICAS_BY_CONTEXT=m1=1,m2=2,m3=3,m4=4,m5=5,m6=6,m7=6/' "${dir}/controlplane-r.tsv"
	PROBE_ISTIOD_REPLICAS=9 run --separate-stderr platform_drift_check "$dir" "$csv"
	assert_success
	[[ "$stderr" == *"warning: and 2 more members whose ISTIOD_REPLICAS_BY_CONTEXT changed otherwise during the sweep"* ]] || { echo "$stderr"; false; }
	sed -i 's/^# ISTIOD_REPLICAS_BY_CONTEXT=.*/# ISTIOD_REPLICAS_BY_CONTEXT=m1=1,m2=2,m3=3,m4=4,m5=5,m6=6,m7=9/' "${dir}/controlplane-r.tsv"
	rm "${dir}/platform-drift.txt"
	PROBE_ISTIOD_REPLICAS=9 run --separate-stderr platform_drift_check "$dir" "$csv"
	assert_success
	[[ "$stderr" == *"warning: and 1 more member whose ISTIOD_REPLICAS_BY_CONTEXT changed otherwise during the sweep"* ]] || { echo "$stderr"; false; }
	run platform_report_warnings "${dir}/controlplane-r.tsv"
	assert_output --partial "5 to 9 on m5; and 1 more member with other changes;"
	# A --resume that finds seven recorded counts at 9 warns five times too, then how many more
	# members (SC12-S1).
	sed -i 's/^# ISTIOD_REPLICAS_BY_CONTEXT=.*/# ISTIOD_REPLICAS_BY_CONTEXT=m1=1,m2=2,m3=3,m4=4,m5=5,m6=6,m7=7/' "${dir}/controlplane-r.tsv"
	PROBE_ISTIOD_REPLICAS=9 resume_run "${dir}/controlplane-r.tsv" "$csv" m1
	assert_success
	[ "$(grep -c '^warning: --resume: m[0-9]: ISTIOD_REPLICAS_BY_CONTEXT recorded' <<<"$stderr")" -eq 5 ] || { echo "$stderr"; false; }
	[[ "$stderr" == *"warning: --resume: m5: ISTIOD_REPLICAS_BY_CONTEXT recorded 5, now 9; an HPA moves it,"* ]] || { echo "$stderr"; false; }
	[[ "$stderr" != *"warning: --resume: m6:"* ]] || { echo "$stderr"; false; }
	[[ "$stderr" == *"warning: --resume: and 2 more members whose ISTIOD_REPLICAS_BY_CONTEXT is not the recorded one; an HPA moves it, the report shows the recorded count while each row records its own istiod pods"* ]] || { echo "$stderr"; false; }
	sed -i 's/^# ISTIOD_REPLICAS_BY_CONTEXT=.*/# ISTIOD_REPLICAS_BY_CONTEXT=m1=1,m2=2,m3=3,m4=4,m5=5,m6=6,m7=9/' "${dir}/controlplane-r.tsv"
	PROBE_ISTIOD_REPLICAS=9 resume_run "${dir}/controlplane-r.tsv" "$csv" m1
	assert_success
	[[ "$stderr" == *"warning: --resume: and 1 more member whose ISTIOD_REPLICAS_BY_CONTEXT is not the recorded one;"* ]] || { echo "$stderr"; false; }
}

@test "platform_resume_check (H1): a TSV from before the record warns and proceeds" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv"
	resume_tsv "$tsv" '/_BY_CONTEXT=\|PLATFORM=/d'
	! grep -q 'PLATFORM' "$tsv" || false
	resume_run "$tsv"
	assert_success
	[[ "$stderr" == *"warning: --resume: ${tsv} predates the platform record (no PLATFORM_BY_CONTEXT line)"* ]]
}

@test "platform_resume_check (H1): TUNING_BASELINE or SIDECAR_EGRESS_HOSTS that differ die; unknown warns; read on the TSV's member" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv"
	resume_tsv "$tsv"
	PROBE_TB_DS=on resume_run "$tsv"
	assert_failure
	[[ "$stderr" == *"  member-a: TUNING_BASELINE discoverySelectors recorded off, now on"* ]]
	PROBE_TB_HOSTS="istio-system/*" resume_run "$tsv"
	assert_failure
	[[ "$stderr" == *"  member-a: SIDECAR_EGRESS_HOSTS recorded istio-system/* ./*, now istio-system/*"* ]]
	# A lever recorded unknown cannot be compared: a warning that says the record lacks it.
	resume_tsv "$tsv" 's/discoverySelectors=off/discoverySelectors=unknown/'
	resume_run "$tsv"
	assert_success
	[[ "$stderr" == *"warning: --resume: member-a: TUNING_BASELINE discoverySelectors: unknown in the record of ${tsv} (not read at the sweep's start), so this run cannot tell whether it changed since its rows were measured"* ]]
	# --contexts in another order: the levers and limits are read on the member the TSV read them on.
	resume_tsv "$tsv"
	probe_setup
	platform_probe member-b,member-a 2>/dev/null
	: > "$CALLS"
	run --separate-stderr platform_resume_check "$tsv" member-b,member-a member-b
	assert_success
	[[ "$stderr" == *"--resume: reading TUNING_BASELINE and istiod's limits on member-a, the member ${tsv} read them on (this run lists member-b first)"* ]]
	[[ "$stderr" != *warning* ]] || { echo "$stderr"; false; }
	grep -q -- '--context=member-a .*get sidecar.networking.istio.io' "$CALLS"
	! grep -q -- '--context=member-b .*get sidecar.networking.istio.io' "$CALLS" || false
}

@test "platform_resume_check (H24): a root Sidecar removed since the sweep started dies (on, now off); a kind the member does not serve warns" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv"
	resume_tsv "$tsv"
	PROBE_TB_SIDECAR=off resume_run "$tsv"
	assert_failure
	[[ "$stderr" == *"  member-a: TUNING_BASELINE sidecar recorded on, now off"* ]]
	[[ "$stderr" == *"  member-a: SIDECAR_EGRESS_HOSTS recorded istio-system/* ./*, now none"* ]]
	# An absent lever reads off in the record too: a tuning Telemetry applied since stops the run.
	PROBE_TB_TELEMETRY=on resume_run "$tsv"
	assert_failure
	[[ "$stderr" == *"  member-a: TUNING_BASELINE telemetryFiltering recorded off, now on"* ]]
	# Kinds the member does not serve are not read: unknown, a warning, never off.
	PROBE_TB_UNSERVED=1 resume_run "$tsv"
	assert_success
	[[ "$stderr" == *"warning: --resume: member-a: TUNING_BASELINE sidecar, TUNING_BASELINE telemetryFiltering, TUNING_BASELINE accessLogFiltering, SIDECAR_EGRESS_HOSTS: could not be read now, so this run cannot tell whether they changed since its rows were measured"* ]]
	# No Istio CR named default: discoverySelectors unknown, never off.
	PROBE_TB_DS=missing resume_run "$tsv"
	assert_success
	[[ "$stderr" == *"warning: --resume: member-a: TUNING_BASELINE discoverySelectors: could not be read now, so this run cannot tell whether it changed since its rows were measured"* ]]
}

@test "platform_resume_check (H1): nothing in a dry-run or for a TSV without a header yet; with a source member it needs its readers" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv" f
	resume_tsv "$tsv"
	DRY_RUN=1 PROBE_ISTIOD=1.30.6 resume_run "$tsv"
	assert_success
	[ -z "$output" ]
	printf '# PLATFORM=kubernetes\n' > "${BATS_TEST_TMPDIR}/new.tsv"
	resume_run "${BATS_TEST_TMPDIR}/new.tsv"
	assert_success
	[ -z "$output" ]
	for f in "tuning_baseline_state preamble" "probe_kube_versions preamble" "cap_istiod_limits capacity" \
		"cap_node_totals capacity" "env_collect_infra envelope"; do
		run bash -c 'source "$1/tests/lib/common.sh"; source "$1/tests/lib/platform.sh"; source "$1/tests/lib/preamble.sh"
			source "$1/tests/lib/capacity.sh"; source "$1/tests/lib/envelope.sh"; unset -f "$2"; DRY_RUN=1
			platform_resume_check "$3" member-a member-a' _ "$ROOT" "${f% *}" "$tsv"
		assert_failure
		assert_output --partial "platform_resume_check needs ${f% *} (source tests/lib/${f#* }.sh)"
	done
}

# ---------------------------------------------------------------------------
# Drift during a sweep (H2): platform_drift_check and the reports' side
# ---------------------------------------------------------------------------

# drift_value_lines <file>: what a drift file (platform_drift_check) holds besides its header and
# its DRIFT_READ_AT lines: nothing when every read at the end found nothing changed and compared
# everything.
drift_value_lines() { grep -v '^# The platform record read again at the end of this \|^# DRIFT_READ_AT=' "$1" || true; }

# drift_unsourced <helper,...> <arg>...: platform_drift_check <arg>... in a subshell where those
# helpers are not defined (a script that did not source their library).
drift_unsourced() (
	local f
	local -a fs=()
	IFS=',' read -r -a fs <<<"$1"
	shift
	for f in "${fs[@]}"; do unset -f "$f"; done
	platform_drift_check "$@"
)

@test "platform_drift_check (H2, H8): a build that changed during the sweep warns with its cause and goes to the marker; a state-only change does not" {
	probe_setup
	platform_probe member-a,member-b 2>/dev/null
	local dir="${BATS_TEST_TMPDIR}/sweep"
	mkdir -p "$dir"
	: > "$CALLS"
	run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	# No TSV in the sweep yet: the record's values only (C11-S1).
	assert_output "Platform record: reading member-a, member-b again, to check that no build, istiod setting or tuning profile object changed during the sweep"
	[ -z "$stderr" ] || { echo "$stderr"; false; }
	# The file says the read ran (M8-S1), and that it found nothing.
	head -n 1 "${dir}/platform-drift.txt" | grep -q '^# The platform record read again at the end of this sweep (tests/lib/platform.sh platform_drift_check), one block per read: '
	grep -q '^# DRIFT_READ_AT=' "${dir}/platform-drift.txt"
	[ -z "$(drift_value_lines "${dir}/platform-drift.txt")" ]
	rm "${dir}/platform-drift.txt"
	# Fresh reads, not the record the sweep holds.
	grep -q -- '--context=member-a' "$CALLS"
	grep -q -- '--context=member-b' "$CALLS"
	# istiod upgraded; the operator only became Unavailable.
	PROBE_ISTIOD=1.30.6 PROBE_SAIL_AVAILABLE=0 run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	[[ "$stderr" == *"warning: member-a, member-b: ISTIOD_IMAGE_BY_CONTEXT changed during the sweep: pilot:1.30.5@${DIG_B} at its start, pilot:1.30.6@${DIG_B} at its end; rows measured after the change ran with the new value (written to ${dir}/platform-drift.txt, so its reports read ISTIOD_IMAGE_BY_CONTEXT mixed); the usual cause is an Argo CD sync of a new revision or an operator upgrade; for publishable figures, run the sweep again on one build"* ]]
	[[ "$stderr" != *MESH_OPERATOR* ]]
	grep -qx "# ISTIOD_IMAGE_BY_CONTEXT=member-a=pilot:1.30.6@${DIG_B},member-b=pilot:1.30.6@${DIG_B}" "${dir}/platform-drift.txt"
	grep -q '^# DRIFT_READ_AT=' "${dir}/platform-drift.txt"
	! grep -q MESH_OPERATOR "${dir}/platform-drift.txt" || false
	# istiod's settings (H25): a tuning profile left applied.
	rm "${dir}/platform-drift.txt"
	PROBE_ISTIOD_THROTTLE=50 run --separate-stderr platform_drift_check "$dir" member-a
	[[ "$stderr" == *"warning: member-a: ISTIOD_ENV_BY_CONTEXT changed during the sweep: $(env_digest "$(env_list)") at its start, $(env_digest "$(env_list 50)") at its end; rows measured after the change ran with the new value (written to ${dir}/platform-drift.txt, so its reports read ISTIOD_ENV_BY_CONTEXT mixed); the usual cause is a tuning profile applied or reverted on these members (by a tuning run, or one stopped before its revert, which tests/tuning/005-cleanup.sh undoes), or a sync or hand edit of the Istio CR's spec.values.pilot.env; for publishable figures, run the sweep again with istiod's settings fixed"* ]]
	grep -qx "# ISTIOD_ENV_BY_CONTEXT=member-a=$(env_digest "$(env_list 50)")" "${dir}/platform-drift.txt"
	# A tuning pass's check (pass): tuning 004 reads the file for the pass, not "its reports".
	rm "${dir}/platform-drift.txt"
	PROBE_ISTIOD_THROTTLE=50 run --separate-stderr platform_drift_check "$dir" member-a pass
	[[ "$stderr" == *"warning: member-a: ISTIOD_ENV_BY_CONTEXT changed during the pass: $(env_digest "$(env_list)") at its start, $(env_digest "$(env_list 50)") at its end; rows measured after the change ran with the new value (written to ${dir}/platform-drift.txt, which tuning 004 reads for this pass); the usual cause is"* ]]
	# (The fix still says to run the sweep again: the tuning sweep.)
	[[ "$stderr" != *"its reports"* && "$stderr" != *"during the sweep"* ]] || { echo "$stderr"; false; }
	# A member that does not answer at the end: a warning, and the file says what it could not
	# compare (M8-S1), no value of it.
	PROBE_PLATFORM=down run --separate-stderr platform_drift_check "${BATS_TEST_TMPDIR}" member-a
	assert_success
	[[ "$stderr" == *"warning: member-a: PLATFORM_BY_CONTEXT, MESH_OPERATOR_BY_CONTEXT, ISTIOD_IMAGE_BY_CONTEXT, PROXY_IMAGE_BY_CONTEXT, NODE_PROVIDER_BY_CONTEXT, ISTIOD_ENV_BY_CONTEXT, TUNING_OBJECTS_BY_CONTEXT not read at the sweep's start or end, so whether they changed during the sweep is not known"* ]]
	[ "$(drift_value_lines "${BATS_TEST_TMPDIR}/platform-drift.txt")" = "# NOT_COMPARED_AT_END=member-a=PLATFORM_BY_CONTEXT;MESH_OPERATOR_BY_CONTEXT;ISTIOD_IMAGE_BY_CONTEXT;PROXY_IMAGE_BY_CONTEXT;NODE_PROVIDER_BY_CONTEXT;ISTIOD_ENV_BY_CONTEXT;TUNING_OBJECTS_BY_CONTEXT" ]
	rm "${BATS_TEST_TMPDIR}/platform-drift.txt"
	# A dry-run reads nothing, and writes no file.
	: > "$CALLS"
	rm -f "${dir}/platform-drift.txt"
	DRY_RUN=1 run platform_drift_check "$dir" member-a,member-b
	assert_success
	[ -z "$output" ]
	[ ! -s "$CALLS" ]
	[ ! -e "${dir}/platform-drift.txt" ]
	# It never fails the sweep whose reports run next (PL40): without KUBECTL it warns, and writes
	# no file (nothing was read again: tuning 004 says so for a pass).
	KUBECTL=()
	run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	[[ "$stderr" == *"warning: platform_drift_check needs reach_sanitize (source tests/lib/reach.sh), _config_sha256 (tests/lib/config.sh) and KUBECTL; not checked"* ]]
	[ ! -s "$CALLS" ]
	[ ! -e "${dir}/platform-drift.txt" ]
}

@test "platform_drift_check (H2): a replica or the operator that has not started at the end is no change; another digest is" {
	local dir="${BATS_TEST_TMPDIR}/sweep"
	mkdir -p "$dir"
	probe_setup
	platform_probe member-a 2>/dev/null
	# A rescheduled istiod replica (Pending) or an evicted pod next to the running one: nothing.
	PROBE_ISTIOD_PODS=pending run --separate-stderr platform_drift_check "$dir" member-a
	assert_success
	[ -z "$stderr" ] || { echo "$stderr"; false; }
	PROBE_ISTIOD_PODS=evicted run --separate-stderr platform_drift_check "$dir" member-a
	[ -z "$stderr" ] || { echo "$stderr"; false; }
	[ -z "$(drift_value_lines "${dir}/platform-drift.txt")" ]
	# Only a Pending replica, and the operator scaled to 0: not read, a warning, and the file says
	# what it could not compare.
	PROBE_ISTIOD_PODS=only-pending PROBE_SAIL_PODS=none PROBE_SAIL_AVAILABLE=0 run --separate-stderr platform_drift_check "$dir" member-a
	assert_success
	[[ "$stderr" == *"warning: member-a: MESH_OPERATOR_BY_CONTEXT, ISTIOD_IMAGE_BY_CONTEXT read with a digest @unknown at the sweep's start or end (no pod had started), so whether they changed during the sweep is not known"* ]]
	[[ "$stderr" != *"changed during the sweep:"* ]]
	[ "$(drift_value_lines "${dir}/platform-drift.txt")" = "# NOT_COMPARED_AT_END=member-a=MESH_OPERATOR_BY_CONTEXT;ISTIOD_IMAGE_BY_CONTEXT" ]
	# So the sweep's reports read the values of its start, not mixed:.
	platform_preamble_lines member-a > "${dir}/s.tsv"
	run --separate-stderr platform_report_values "${dir}/s.tsv"
	assert_line "ISTIOD_IMAGE_BY_CONTEXT=member-a=pilot:1.30.5@${DIG_B}"
	assert_line "MESH_OPERATOR_BY_CONTEXT=member-a=sail-operator:1.31.1@${DIG_A}/Available"
	refute_output --partial "mixed"
	[ -z "$stderr" ] || { echo "$stderr"; false; }
	rm -f "${dir}/s.tsv"
	# A replica that runs another digest at the end: a change.
	PROBE_ISTIOD_PODS=two-digests run --separate-stderr platform_drift_check "$dir" member-a
	[[ "$stderr" == *"warning: member-a: ISTIOD_IMAGE_BY_CONTEXT changed during the sweep: pilot:1.30.5@${DIG_B} at its start, pilot:1.30.5@${DIG_A}+pilot:1.30.5@${DIG_B} at its end"* ]]
	grep -qx "# ISTIOD_IMAGE_BY_CONTEXT=member-a=pilot:1.30.5@${DIG_A}+pilot:1.30.5@${DIG_B}" "${dir}/platform-drift.txt"
}

@test "platform_drift_check (H7, H8): the levers and Kubernetes versions the sweep's TSVs record are read again; a change goes to the marker" {
	local dir="${BATS_TEST_TMPDIR}/sweep"
	mkdir -p "$dir"
	probe_setup
	platform_probe member-a,member-b 2>/dev/null
	# A sweep TSV records the levers of its first member and each member's Kubernetes version; a
	# reach TSV next to it records neither.
	{
		tuning_baseline_state member-a "${KUBECTL[@]}" | sed 's/^/# /'
		echo "# KUBE_VERSIONS=$(probe_kube_versions member-a,member-b "${KUBECTL[@]}")"
		printf 'timestamp\tcontext\n'
	} > "${dir}/controlplane-r.tsv"
	printf '# RUN_ID=r\ntimestamp\tcontext\n' > "${dir}/reach-r.tsv"
	: > "$CALLS"
	run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	[ -z "$stderr" ] || { echo "$stderr"; false; }
	# The banner names what these TSVs record (C12-S1).
	assert_output "Platform record: reading member-a, member-b again, to check that no build, istiod setting, tuning lever, tuning profile object or Kubernetes version changed during the sweep"
	[ -z "$(drift_value_lines "${dir}/platform-drift.txt")" ]
	rm "${dir}/platform-drift.txt"
	grep -q -- '--context=member-a .*get sidecar.networking.istio.io default -o name --ignore-not-found' "$CALLS"
	! grep -q -- '--context=member-b .*get sidecar.networking.istio.io' "$CALLS" || false
	grep -q -- '--context=member-b .*version --output=json' "$CALLS"
	# The root Sidecar removed (a GitOps self-heal, a hand edit) and a control-plane upgrade.
	PROBE_TB_SIDECAR=off PROBE_KUBE_VERSION=v1.33.2 run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	[[ "$stderr" == *"warning: member-a: TUNING_BASELINE changed during the sweep: sidecar from on to off; rows measured after the change ran with other tuning levers (written to ${dir}/platform-drift.txt, which its reports say in their body); the usual cause is a GitOps sync or self-heal that put a lever back, a tuning profile left applied, or a hand edit; for publishable figures, run the sweep again with the levers fixed"* ]]
	[[ "$stderr" == *"warning: member-a: SIDECAR_EGRESS_HOSTS changed during the sweep: istio-system/* ./* at its start, none at its end; rows measured after the change ran with other root Sidecar egress hosts"* ]]
	[[ "$stderr" == *"warning: member-a, member-b: KUBE_VERSIONS changed during the sweep: v1.33.1 at its start, v1.33.2 at its end; rows measured after the change ran on another Kubernetes version (written to ${dir}/platform-drift.txt, which its reports say in their body); the usual cause is a managed control-plane upgrade; for publishable figures, run the sweep again on one Kubernetes version"* ]]
	grep -qx '# TUNING_BASELINE=sidecar=off,discoverySelectors=off,telemetryFiltering=off,accessLogFiltering=off' "${dir}/platform-drift.txt"
	grep -qx '# SIDECAR_EGRESS_HOSTS=none' "${dir}/platform-drift.txt"
	grep -qx '# KUBE_VERSIONS=member-a=v1.33.2,member-b=v1.33.2' "${dir}/platform-drift.txt"
	! grep -q '_BY_CONTEXT=' "${dir}/platform-drift.txt" || false
	# Not read at the end (kinds the member does not serve, no answer): a warning, and the file
	# says what it could not compare, each lever by name.
	rm "${dir}/platform-drift.txt"
	PROBE_TB_UNSERVED=1 PROBE_KUBE=down run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	[[ "$stderr" == *"warning: member-a: TUNING_BASELINE sidecar, TUNING_BASELINE telemetryFiltering, TUNING_BASELINE accessLogFiltering, SIDECAR_EGRESS_HOSTS, KUBE_VERSIONS not read at the sweep's start or end, so whether they changed during the sweep is not known"* ]]
	[[ "$stderr" == *"warning: member-b: KUBE_VERSIONS not read at the sweep's start or end, so whether it changed during the sweep is not known"* ]]
	[ "$(drift_value_lines "${dir}/platform-drift.txt")" = "# NOT_COMPARED_AT_END=member-a=TUNING_BASELINE sidecar;TUNING_BASELINE telemetryFiltering;TUNING_BASELINE accessLogFiltering;SIDECAR_EGRESS_HOSTS;KUBE_VERSIONS,member-b=KUBE_VERSIONS" ]
	# What a report of the sweep says of it (the body; the TSVs' values of its start).
	run platform_drift_unread "${dir}/controlplane-r.tsv"
	assert_output $'TUNING_BASELINE sidecar\tmember-a\nTUNING_BASELINE telemetryFiltering\tmember-a\nTUNING_BASELINE accessLogFiltering\tmember-a\nSIDECAR_EGRESS_HOSTS\tmember-a\nKUBE_VERSIONS\tmember-a, member-b'
	_pl_no_members=1 run platform_drift_unread "${dir}/controlplane-r.tsv"
	assert_line $'KUBE_VERSIONS\t2 members'
	assert_line $'SIDECAR_EGRESS_HOSTS\t1 member'
	run --separate-stderr platform_report_warnings "${dir}/controlplane-r.tsv"
	assert_output --partial "the read again at the end of the sweep in sweep (platform-drift.txt) could not compare TUNING_BASELINE sidecar on member-a; TUNING_BASELINE telemetryFiltering on member-a; TUNING_BASELINE accessLogFiltering on member-a; SIDECAR_EGRESS_HOSTS on member-a; KUBE_VERSIONS on member-a, member-b (not read at its start or end, or read with a digest @unknown: no pod had started), so whether those changed during the sweep is not known; the report shows the values the TSVs recorded at its start"
	# A sweep whose TSVs record neither reads neither again.
	rm "${dir}/controlplane-r.tsv"
	: > "$CALLS"
	run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	! grep -q -- 'sidecar.networking.istio.io\|version --output=json' "$CALLS" || false
	# A pass's TSV that records the root Sidecar's egress hosts alone: a tuning lever, no
	# Kubernetes version.
	rm "${dir}/platform-drift.txt"
	tuning_baseline_state member-a "${KUBECTL[@]}" | sed -n 's/^SIDECAR_EGRESS_HOSTS=/# &/p' > "${dir}/controlplane-r.tsv"
	printf 'timestamp\tcontext\n' >> "${dir}/controlplane-r.tsv"
	run --separate-stderr platform_drift_check "$dir" member-a,member-b pass
	assert_success
	assert_output "Platform record: reading member-a, member-b again, to check that no build, istiod setting, tuning lever or tuning profile object changed during the pass"
}

@test "platform_drift_check (M-B1): istiod's limits the sweep's TSVs record are read again on their member; a change goes to the marker and the report" {
	local dir="${BATS_TEST_TMPDIR}/sweep" lim
	mkdir -p "$dir"
	probe_setup
	platform_probe member-a,member-b 2>/dev/null
	lim="$(cap_istiod_limits member-a "${KUBECTL[@]}")"
	{
		platform_preamble_lines member-a,member-b
		echo "# ISTIOD_CPU_LIMIT_M=$(_platform_kv "$lim" cpu_m)"
		echo "# ISTIOD_MEM_LIMIT_MI=$(_platform_kv "$lim" mem_mi)"
		printf 'timestamp\tcontext\n'
	} > "${dir}/controlplane-r.tsv"
	run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	[ -z "$stderr" ] || { echo "$stderr"; false; }
	[ -z "$(drift_value_lines "${dir}/platform-drift.txt")" ]
	rm "${dir}/platform-drift.txt"
	# The limits raised during the sweep (a sync of new resources, a tuning profile).
	PROBE_ISTIOD_CPU_LIMIT=4 run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	[[ "$stderr" == *"warning: member-a: ISTIOD_CPU_LIMIT_M changed during the sweep: 2000 at its start, 4000 at its end; rows measured after the change ran under another limit, but the report's window-peak CPU % (the highest istiod CPU of every member's rows) divides by the recorded one, as does the SLA verdict on it, while the kubectl top % use each row's own limit (written to ${dir}/platform-drift.txt, which its reports say in their body); the usual cause is an Argo CD sync, a tuning profile or a hand edit of istiod's resources (the Istio CR's spec.values.pilot.resources); for publishable figures, run the sweep again with istiod's limits fixed"* ]]
	[[ "$stderr" != *ISTIOD_MEM_LIMIT_MI* ]]
	grep -qx '# ISTIOD_CPU_LIMIT_M=4000' "${dir}/platform-drift.txt"
	! grep -q ISTIOD_MEM_LIMIT_MI "${dir}/platform-drift.txt" || false
	# The other member was raised too: its rows read against the recorded limit as well (R6).
	grep -qx '# ISTIOD_LIMITS_DIFFER_BY_CONTEXT=member-b=4000/4096' "${dir}/platform-drift.txt"
	# The sweep's reports say it in their body.
	run platform_report_warnings "${dir}/controlplane-r.tsv"
	assert_output --partial "ISTIOD_CPU_LIMIT_M changed during the sweep in sweep (platform-drift.txt): 2000 at its start, 4000 at its end; rows measured after the change ran under another limit, but the report's window-peak CPU % (the highest istiod CPU of every member's rows) divides by the one recorded at the start, as does the SLA verdict on it, and the report cannot tell which rows those are; the kubectl top % use each row's own limit; the usual cause is"
	assert_output --partial "istiod's limits per replica on member-b (CPU 4000m, memory 4096Mi) differ from those the TSVs recorded on their source member (CPU 2000m, memory 4096Mi) at the end of the sweep in sweep (platform-drift.txt)"
	# A tuning pass's check (tuning 003: pass) names the pass and leaves out the controlplane
	# report's percentages, which its comparison does not show; a member whose limits differ from
	# the source member's does not warn (S5: tuning 004 compares each member's with the reference
	# pass's), and still goes to the file.
	rm "${dir}/platform-drift.txt"
	PROBE_ISTIOD_CPU_LIMIT=4 run --separate-stderr platform_drift_check "$dir" member-a,member-b pass
	assert_success
	[[ "$stderr" == *"warning: member-a: ISTIOD_CPU_LIMIT_M changed during the pass: 2000 at its start, 4000 at its end; rows measured after the change ran under another limit (written to ${dir}/platform-drift.txt, which tuning 004 reads for this pass); the usual cause is"* ]]
	[[ "$stderr" != *"differ from those"* ]] || { echo "$stderr"; false; }
	[[ "$stderr" != *"which its reports say in their body"* ]] || { echo "$stderr"; false; }
	[[ "$stderr" != *window-peak* && "$stderr" != *"during the sweep"* ]] || { echo "$stderr"; false; }
	head -n 1 "${dir}/platform-drift.txt" | grep -q '^# The platform record read again at the end of this pass (tests/lib/platform.sh platform_drift_check), one block per read: '
	grep -qx '# ISTIOD_CPU_LIMIT_M=4000' "${dir}/platform-drift.txt"
	grep -qx '# ISTIOD_LIMITS_DIFFER_BY_CONTEXT=member-b=4000/4096' "${dir}/platform-drift.txt"
	# What tuning 004 compares for the pass: each member's limits, the source member's with its
	# value at the end.
	run platform_lever_values "${dir}/controlplane-r.tsv"
	assert_line "ISTIOD_CPU_LIMIT_M_BY_CONTEXT=member-a=mixed:2000;4000,member-b=4000"
	assert_line "ISTIOD_MEM_LIMIT_MI_BY_CONTEXT=member-a=4096,member-b=4096"
	# Not read at the end: a warning, and the file says what it could not compare.
	rm "${dir}/platform-drift.txt"
	PROBE_ISTIOD_DEPLOY=missing run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	[[ "$stderr" == *"warning: member-a: ISTIOD_CPU_LIMIT_M, ISTIOD_MEM_LIMIT_MI not read at the sweep's start or end"* ]]
	[[ "$stderr" == *"warning: istiod's limits could not be read on member-b at the sweep's end, so whether they are the ones the report divides those members' window-peak CPU and RSS % by is not known"* ]]
	grep -qx '# NOT_COMPARED_AT_END=member-a=ISTIOD_CPU_LIMIT_M;ISTIOD_MEM_LIMIT_MI,member-b=ISTIOD_LIMITS_DIFFER_BY_CONTEXT' "${dir}/platform-drift.txt"
	run platform_lever_values "${dir}/controlplane-r.tsv"
	assert_line "ISTIOD_CPU_LIMIT_M_BY_CONTEXT=member-a=2000,member-b=unknown"
}

@test "platform_drift_check (I10-S1): each member's istiod replica count the controlplane TSVs record is read again; a change warns and goes to the marker, the reports and tuning 004's values" {
	local dir="${BATS_TEST_TMPDIR}/sweep" lim
	mkdir -p "$dir"
	probe_setup
	platform_probe member-a,member-b 2>/dev/null
	lim="$(cap_istiod_limits member-a "${KUBECTL[@]}")"
	{
		platform_preamble_lines member-a,member-b
		echo "# ISTIOD_CPU_LIMIT_M=$(_platform_kv "$lim" cpu_m)"
		echo "# ISTIOD_MEM_LIMIT_MI=$(_platform_kv "$lim" mem_mi)"
		echo "# ISTIOD_REPLICAS=1"
		echo "# ISTIOD_REPLICAS_BY_CONTEXT=member-a=1,member-b=1"
		printf 'timestamp\tcontext\n'
	} > "${dir}/controlplane-r.tsv"
	run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	[ -z "$stderr" ] || { echo "$stderr"; false; }
	[ -z "$(drift_value_lines "${dir}/platform-drift.txt")" ]
	rm "${dir}/platform-drift.txt"
	# member-b's istiod scaled to 2 during the sweep (an HPA, a hand scale).
	PROBE_ISTIOD_ON=member-b PROBE_ISTIOD_ON_REPLICAS=2 run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	[[ "$stderr" == *"warning: member-b: ISTIOD_REPLICAS_BY_CONTEXT changed during the sweep: 1 at its start, 2 at its end; rows measured after the change ran with another istiod replica count (written to ${dir}/platform-drift.txt, which its reports say in their body); the usual cause is an HPA (the Istio CR's spec.values.pilot.autoscaleEnabled turned on), an Argo CD sync or a tuning profile that sets spec.values.pilot.replicaCount, or a hand scale of istiod's Deployment; for publishable figures, run the sweep again with istiod's replica count fixed (autoscaling off, as charts/spoke-ossm sets it)"* ]] || { echo "$stderr"; false; }
	[[ "$stderr" != *"member-a: ISTIOD_REPLICAS"* && "$stderr" != *"ISTIOD_CPU_LIMIT_M changed"* ]] || { echo "$stderr"; false; }
	[ "$(drift_value_lines "${dir}/platform-drift.txt")" = "# ISTIOD_REPLICAS_BY_CONTEXT=member-b=2" ]
	run platform_report_warnings "${dir}/controlplane-r.tsv"
	assert_output --partial "ISTIOD_REPLICAS_BY_CONTEXT changed during the sweep in sweep (platform-drift.txt): 1 to 2 on member-b; rows measured after the change ran with another istiod replica count; the report's istiod replicas show the count recorded at the start, while each cell's own count of istiod pods is in the csv's istiod_pods_avg, the json's istiod_pods_per_cluster_avg and the growth table's istiod pods / cluster; the usual cause is an HPA"
	# Where member names may not go (the scale envelope, pasted into campaign docs): how many of
	# the members the inputs record a count for (M11-B1).
	run platform_report_warnings --no-members "${dir}/controlplane-r.tsv"
	assert_output --partial "ISTIOD_REPLICAS_BY_CONTEXT changed during the sweep in sweep (platform-drift.txt): 1 to 2 on 1 of 2 members;"
	refute_output --partial member-b
	# A member whose count was not read at the start (a failed read records unknown) is one of
	# them too, as the unread warning beside it counts it (M12-S1).
	sed -i 's/^# ISTIOD_REPLICAS_BY_CONTEXT=member-a=1,/# ISTIOD_REPLICAS_BY_CONTEXT=member-a=unknown,/' "${dir}/controlplane-r.tsv"
	run platform_report_warnings --no-members "${dir}/controlplane-r.tsv"
	assert_output --partial "ISTIOD_REPLICAS_BY_CONTEXT changed during the sweep in sweep (platform-drift.txt): 1 to 2 on 1 of 2 members;"
	sed -i 's/^# ISTIOD_REPLICAS_BY_CONTEXT=member-a=unknown,/# ISTIOD_REPLICAS_BY_CONTEXT=member-a=1,/' "${dir}/controlplane-r.tsv"
	# The TSVs' banner names the replica counts and limits they record (C11-S1).
	rm "${dir}/platform-drift.txt"
	run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	assert_output "Platform record: reading member-a, member-b again, to check that no build, istiod setting, istiod limit, istiod replica count or tuning profile object changed during the sweep"
	rm "${dir}/platform-drift.txt"
	PROBE_ISTIOD_ON=member-b PROBE_ISTIOD_ON_REPLICAS=2 run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	run platform_lever_values "${dir}/controlplane-r.tsv"
	assert_line "ISTIOD_REPLICAS_BY_CONTEXT=member-a=1,member-b=mixed:1;2"
	run platform_drift_changes "${dir}/controlplane-r.tsv"
	assert_output $'ISTIOD_REPLICAS_BY_CONTEXT\tistiod replica counts\t1 to 2 on member-b'
	# A tuning pass's check names the pass; members that changed the same way share one warning.
	rm "${dir}/platform-drift.txt"
	PROBE_ISTIOD_REPLICAS=2 run --separate-stderr platform_drift_check "$dir" member-a,member-b pass
	assert_success
	[[ "$stderr" == *"warning: member-a, member-b: ISTIOD_REPLICAS_BY_CONTEXT changed during the pass: 1 at its start, 2 at its end; rows measured after the change ran with another istiod replica count (written to ${dir}/platform-drift.txt, which tuning 004 reads for this pass); the usual cause is"* ]] || { echo "$stderr"; false; }
	[ "$(grep -c 'ISTIOD_REPLICAS_BY_CONTEXT changed' <<<"$stderr")" -eq 1 ]
	grep -qx '# ISTIOD_REPLICAS_BY_CONTEXT=member-a=2,member-b=2' "${dir}/platform-drift.txt"
	run platform_drift_changes "${dir}/controlplane-r.tsv"
	assert_output $'ISTIOD_REPLICAS_BY_CONTEXT\tistiod replica counts\t1 to 2 on member-a, member-b'
	# Not read at the end (no Deployment): not compared, and the file says so.
	rm "${dir}/platform-drift.txt"
	PROBE_ISTIOD_DEPLOY=missing run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	[[ "$stderr" == *"warning: member-a: ISTIOD_CPU_LIMIT_M, ISTIOD_MEM_LIMIT_MI, ISTIOD_REPLICAS_BY_CONTEXT not read at the sweep's start or end"* ]] || { echo "$stderr"; false; }
	[[ "$stderr" == *"warning: member-b: ISTIOD_REPLICAS_BY_CONTEXT not read at the sweep's start or end"* ]] || { echo "$stderr"; false; }
	grep -qx '# NOT_COMPARED_AT_END=member-a=ISTIOD_CPU_LIMIT_M;ISTIOD_MEM_LIMIT_MI;ISTIOD_REPLICAS_BY_CONTEXT,member-b=ISTIOD_REPLICAS_BY_CONTEXT;ISTIOD_LIMITS_DIFFER_BY_CONTEXT' "${dir}/platform-drift.txt"
	run platform_drift_unread "${dir}/controlplane-r.tsv"
	assert_line $'ISTIOD_REPLICAS_BY_CONTEXT\tmember-a, member-b'
	# Not read at the start (unknown in the TSVs): not compared on that member only.
	rm "${dir}/platform-drift.txt"
	sed -i 's/^# ISTIOD_REPLICAS_BY_CONTEXT=.*/# ISTIOD_REPLICAS_BY_CONTEXT=member-a=1,member-b=unknown/' "${dir}/controlplane-r.tsv"
	PROBE_ISTIOD_REPLICAS=2 run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	[[ "$stderr" == *"warning: member-a: ISTIOD_REPLICAS_BY_CONTEXT changed during the sweep: 1 at its start, 2 at its end"* ]] || { echo "$stderr"; false; }
	[[ "$stderr" == *"warning: member-b: ISTIOD_REPLICAS_BY_CONTEXT not read at the sweep's start or end"* ]] || { echo "$stderr"; false; }
	grep -qx '# NOT_COMPARED_AT_END=member-b=ISTIOD_REPLICAS_BY_CONTEXT' "${dir}/platform-drift.txt"
	grep -qx '# ISTIOD_REPLICAS_BY_CONTEXT=member-a=2' "${dir}/platform-drift.txt"
	# Inputs that disagree on a member's count: either of them at its start.
	rm "${dir}/platform-drift.txt"
	sed 's/^# ISTIOD_REPLICAS_BY_CONTEXT=.*/# ISTIOD_REPLICAS_BY_CONTEXT=member-a=1,member-b=2/' "${dir}/controlplane-r.tsv" > "${dir}/controlplane-s.tsv"
	sed -i 's/^# ISTIOD_REPLICAS_BY_CONTEXT=.*/# ISTIOD_REPLICAS_BY_CONTEXT=member-a=1,member-b=1/' "${dir}/controlplane-r.tsv"
	PROBE_ISTIOD_ON=member-b PROBE_ISTIOD_ON_REPLICAS=3 run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	[[ "$stderr" == *"warning: member-b: ISTIOD_REPLICAS_BY_CONTEXT changed during the sweep: 1 or 2 at its start, 3 at its end"* ]] || { echo "$stderr"; false; }
	run platform_report_warnings "${dir}/controlplane-r.tsv" "${dir}/controlplane-s.tsv"
	assert_output --partial "ISTIOD_REPLICAS_BY_CONTEXT changed during the sweep in sweep (platform-drift.txt): 1 or 2 to 3 on member-b;"
	# Without cap_istiod_limits: not checked, and each member's recorded count goes to the file.
	rm "${dir}/platform-drift.txt" "${dir}/controlplane-s.tsv"
	run --separate-stderr drift_unsourced cap_istiod_limits "$dir" member-a,member-b
	assert_success
	[[ "$stderr" == *"warning: platform_drift_check needs cap_istiod_limits (source tests/lib/capacity.sh) and a temp dir to read istiod's limits and replica counts again; not checked"* ]] || { echo "$stderr"; false; }
	grep -qx '# NOT_COMPARED_AT_END=member-a=ISTIOD_CPU_LIMIT_M;ISTIOD_MEM_LIMIT_MI;ISTIOD_REPLICAS_BY_CONTEXT,member-b=ISTIOD_LIMITS_DIFFER_BY_CONTEXT;ISTIOD_REPLICAS_BY_CONTEXT' "${dir}/platform-drift.txt"
	# Another suite's count (propagation's ISTIOD_REPLICAS: Running istiod pods) is not read again.
	rm "${dir}/platform-drift.txt"
	sed -i -e '/^# ISTIOD_REPLICAS_BY_CONTEXT=/d' -e 's/^# ISTIOD_REPLICAS=.*/# ISTIOD_REPLICAS=member-a=1,member-b=1/' "${dir}/controlplane-r.tsv"
	PROBE_ISTIOD_REPLICAS=2 run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	[[ "$stderr" != *ISTIOD_REPLICAS* ]] || { echo "$stderr"; false; }
	[ -z "$(drift_value_lines "${dir}/platform-drift.txt")" ]
	# A context the record names with its safe characters only (lab~b is lab_b there): the count
	# the TSVs record under its own name is read again under the record's.
	rm "${dir}/platform-drift.txt"
	platform_probe_reset
	platform_probe member-a,lab~b 2>/dev/null
	{
		platform_preamble_lines member-a,lab~b
		echo "# ISTIOD_CPU_LIMIT_M=$(_platform_kv "$lim" cpu_m)"
		echo "# ISTIOD_MEM_LIMIT_MI=$(_platform_kv "$lim" mem_mi)"
		echo "# ISTIOD_REPLICAS=1"
		echo "# ISTIOD_REPLICAS_BY_CONTEXT=member-a=1,lab~b=1"
		printf 'timestamp\tcontext\n'
	} > "${dir}/controlplane-r.tsv"
	PROBE_ISTIOD_ON='lab~b' PROBE_ISTIOD_ON_REPLICAS=2 run --separate-stderr platform_drift_check "$dir" member-a,lab~b
	assert_success
	[[ "$stderr" == *"warning: lab_b: ISTIOD_REPLICAS_BY_CONTEXT changed during the sweep: 1 at its start, 2 at its end"* ]] || { echo "$stderr"; false; }
	[ "$(drift_value_lines "${dir}/platform-drift.txt")" = "# ISTIOD_REPLICAS_BY_CONTEXT=lab_b=2" ]
	run platform_report_warnings "${dir}/controlplane-r.tsv"
	assert_output --partial "ISTIOD_REPLICAS_BY_CONTEXT changed during the sweep in sweep (platform-drift.txt): 1 to 2 on lab_b;"
	run platform_lever_values "${dir}/controlplane-r.tsv"
	assert_line "ISTIOD_REPLICAS_BY_CONTEXT=member-a=1,lab_b=mixed:1;2"
	# TSVs from before istiod's limits were recorded: their replica counts are still read again,
	# and without cap_istiod_limits, those alone go to the file as not compared.
	rm "${dir}/platform-drift.txt"
	sed -i '/^# ISTIOD_CPU_LIMIT_M=\|^# ISTIOD_MEM_LIMIT_MI=/d' "${dir}/controlplane-r.tsv"
	PROBE_ISTIOD_ON='lab~b' PROBE_ISTIOD_ON_REPLICAS=2 run --separate-stderr platform_drift_check "$dir" member-a,lab~b
	assert_success
	[[ "$stderr" == *"warning: lab_b: ISTIOD_REPLICAS_BY_CONTEXT changed during the sweep: 1 at its start, 2 at its end"* ]] || { echo "$stderr"; false; }
	[ "$(drift_value_lines "${dir}/platform-drift.txt")" = "# ISTIOD_REPLICAS_BY_CONTEXT=lab_b=2" ]
	rm "${dir}/platform-drift.txt"
	run --separate-stderr drift_unsourced cap_istiod_limits "$dir" member-a,lab~b
	assert_success
	[[ "$stderr" == *"warning: platform_drift_check needs cap_istiod_limits (source tests/lib/capacity.sh) and a temp dir to read istiod's replica counts again; not checked"* ]] || { echo "$stderr"; false; }
	grep -qx '# NOT_COMPARED_AT_END=member-a=ISTIOD_REPLICAS_BY_CONTEXT,lab_b=ISTIOD_REPLICAS_BY_CONTEXT' "${dir}/platform-drift.txt"
}

@test "platform_drift_check (R6, M5-S2): a member whose istiod limits differ from the recorded ones warns, goes to the marker and the report; --no-members counts" {
	local dir="${BATS_TEST_TMPDIR}/sweep" lim
	mkdir -p "$dir"
	probe_setup
	platform_probe member-a,member-b,member-c 2>/dev/null
	lim="$(cap_istiod_limits member-a "${KUBECTL[@]}")"
	{
		platform_preamble_lines member-a,member-b,member-c
		echo "# ISTIOD_CPU_LIMIT_M=$(_platform_kv "$lim" cpu_m)"
		echo "# ISTIOD_MEM_LIMIT_MI=$(_platform_kv "$lim" mem_mi)"
		printf 'timestamp\tcontext\n'
	} > "${dir}/controlplane-r.tsv"
	# member-b's memory limit is half the source member's (a hand edit on that member only).
	PROBE_ISTIOD_ON=member-b PROBE_ISTIOD_ON_MEM_LIMIT=2Gi run --separate-stderr platform_drift_check "$dir" member-a,member-b,member-c
	assert_success
	[[ "$stderr" == *"warning: istiod's limits per replica on member-b (CPU 2000m, memory 2048Mi) differ from those the TSVs recorded on member-a, their source member (CPU 2000m, memory 4096Mi) at the sweep's end, but the report divides the window-peak CPU and RSS % of every member's rows (and the SLA verdict on them) by the recorded ones, so those members' rows read against another limit, while the kubectl top % use each row's own (written to ${dir}/platform-drift.txt, which its reports say in their body); the usual cause is a per-member change of istiod's resources"* ]]
	[[ "$stderr" != *"member-a: ISTIOD_"* && "$stderr" != *"member-c (CPU"* ]]
	grep -qx '# ISTIOD_LIMITS_DIFFER_BY_CONTEXT=member-b=2000/2048' "${dir}/platform-drift.txt"
	! grep -q '^# ISTIOD_CPU_LIMIT_M=\|^# ISTIOD_MEM_LIMIT_MI=' "${dir}/platform-drift.txt" || false
	run platform_report_warnings "${dir}/controlplane-r.tsv"
	assert_output --partial "istiod's limits per replica on member-b (CPU 2000m, memory 2048Mi) differ from those the TSVs recorded on their source member (CPU 2000m, memory 4096Mi) at the end of the sweep in sweep (platform-drift.txt), but the report divides the window-peak CPU and RSS % of every member's rows (and the SLA verdict on them) by the recorded ones, so those members' rows read against another limit; the kubectl top % use each row's own; the usual cause is a per-member change"
	# Where member names may not go (the scale envelope): how many.
	run platform_report_warnings --no-members "${dir}/controlplane-r.tsv"
	assert_output --partial "istiod's limits per replica on 1 member (CPU 2000m, memory 2048Mi) differ from those"
	refute_output --partial member-b
	# M6-N1: a second drift check (a resumed sweep's) adds member-c; both checks' members are named, each once.
	echo '# ISTIOD_LIMITS_DIFFER_BY_CONTEXT=member-c=4000/4096,member-b=2000/2048' >>"${dir}/platform-drift.txt"
	run platform_report_warnings "${dir}/controlplane-r.tsv"
	assert_output --partial "istiod's limits per replica on member-b (CPU 2000m, memory 2048Mi); member-c (CPU 4000m, memory 4096Mi) differ from those the TSVs recorded on their source member"
	[ "$(grep -o 'member-b (CPU' <<<"$output" | wc -l)" -eq 1 ]
	# A report of a suite that records no istiod limits says nothing of them.
	sed '/ISTIOD_CPU_LIMIT_M=\|ISTIOD_MEM_LIMIT_MI=/d' "${dir}/controlplane-r.tsv" > "${dir}/other.tsv"
	rm "${dir}/controlplane-r.tsv"
	run platform_report_warnings "${dir}/other.tsv"
	refute_output --partial "istiod's limits"
}

@test "platform_drift_check (SC9-S3, C9-S2): a read it cannot make (its helper not sourced) warns, and what it would have compared goes to the file as not compared at the end" {
	local dir="${BATS_TEST_TMPDIR}/sweep" lim
	mkdir -p "$dir"
	probe_setup
	platform_probe member-a,member-b 2>/dev/null
	lim="$(cap_istiod_limits member-a "${KUBECTL[@]}")"
	{
		platform_preamble_lines member-a,member-b
		tuning_baseline_state member-a "${KUBECTL[@]}" | sed 's/^/# /'
		echo "# KUBE_VERSIONS=$(probe_kube_versions member-a,member-b "${KUBECTL[@]}")"
		echo "# ISTIOD_CPU_LIMIT_M=$(_platform_kv "$lim" cpu_m)"
		echo "# ISTIOD_MEM_LIMIT_MI=$(_platform_kv "$lim" mem_mi)"
		printf 'timestamp\tcontext\n'
	} > "${dir}/controlplane-r.tsv"
	run --separate-stderr drift_unsourced tuning_baseline_state,cap_istiod_limits,probe_kube_versions "$dir" member-a,member-b
	assert_success
	[[ "$stderr" == *"warning: platform_drift_check needs tuning_baseline_state (source tests/lib/preamble.sh) to read the tuning levers again; not checked, so the reports cannot tell whether they changed during the sweep"* ]]
	[[ "$stderr" == *"warning: platform_drift_check needs cap_istiod_limits (source tests/lib/capacity.sh) and a temp dir to read istiod's limits again; not checked"* ]]
	[[ "$stderr" == *"warning: platform_drift_check needs probe_kube_versions (source tests/lib/preamble.sh) to read the Kubernetes versions again; not checked"* ]]
	# The source member's levers, hosts, limits and version; the other member's limits and version.
	[ "$(drift_value_lines "${dir}/platform-drift.txt")" = "# NOT_COMPARED_AT_END=member-a=TUNING_BASELINE;SIDECAR_EGRESS_HOSTS;ISTIOD_CPU_LIMIT_M;ISTIOD_MEM_LIMIT_MI;KUBE_VERSIONS,member-b=ISTIOD_LIMITS_DIFFER_BY_CONTEXT;KUBE_VERSIONS" ]
	# What tuning 004 and the sweep's reports make of it: the other member's limits are not known,
	# and the body says what was not compared, counted out of the members the TSVs record (U9-N3)
	# where member names may not go.
	run platform_lever_values "${dir}/controlplane-r.tsv"
	assert_line "ISTIOD_CPU_LIMIT_M_BY_CONTEXT=member-a=2000,member-b=unknown"
	_pl_no_members=1 run platform_drift_unread "${dir}/controlplane-r.tsv"
	assert_line $'KUBE_VERSIONS\t2 of 2 members'
	assert_line $'ISTIOD_LIMITS_DIFFER_BY_CONTEXT\t1 of 2 members'
	run --separate-stderr platform_report_warnings "${dir}/controlplane-r.tsv"
	assert_output --partial "the read again at the end of the sweep in sweep (platform-drift.txt) could not compare TUNING_BASELINE on member-a; SIDECAR_EGRESS_HOSTS on member-a; ISTIOD_CPU_LIMIT_M on member-a; ISTIOD_MEM_LIMIT_MI on member-a; KUBE_VERSIONS on member-a, member-b (not read at its start or end, or read with a digest @unknown: no pod had started); istiod's limits on member-b (not read at its end), so whether those changed during the sweep is not known"
}

@test "platform_drift_check (SC9-S2): an end read that gets no answer (a timeout) is made once more: the levers, each member's istiod limits and Kubernetes version" {
	local dir="${BATS_TEST_TMPDIR}/sweep" lim
	mkdir -p "$dir"
	probe_setup
	platform_probe member-a,member-b 2>/dev/null
	lim="$(cap_istiod_limits member-a "${KUBECTL[@]}")"
	{
		platform_preamble_lines member-a,member-b
		tuning_baseline_state member-a "${KUBECTL[@]}" | sed 's/^/# /'
		echo "# KUBE_VERSIONS=$(probe_kube_versions member-a,member-b "${KUBECTL[@]}")"
		echo "# ISTIOD_CPU_LIMIT_M=$(_platform_kv "$lim" cpu_m)"
		echo "# ISTIOD_MEM_LIMIT_MI=$(_platform_kv "$lim" mem_mi)"
		printf 'timestamp\tcontext\n'
	} > "${dir}/controlplane-r.tsv"
	: > "$CALLS"
	PROBE_FLAKY=kube,sidecar,istiod run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	[ -z "$stderr" ] || { echo "$stderr"; false; }
	[ -z "$(drift_value_lines "${dir}/platform-drift.txt")" ]
	# Each of those reads twice: the first got no answer.
	[ "$(grep -c -- '--context=member-a .*get sidecar.networking.istio.io default -o name' "$CALLS")" -eq 2 ]
	[ "$(grep -c -- '--context=member-a .*get deploy istiod' "$CALLS")" -eq 2 ]
	[ "$(grep -c -- '--context=member-b .*get deploy istiod' "$CALLS")" -eq 2 ]
	[ "$(grep -c -- '--context=member-a .*version --output=json' "$CALLS")" -eq 2 ]
	[ "$(grep -c -- '--context=member-b .*version --output=json' "$CALLS")" -eq 2 ]
	# No answer the second time either: not compared, as before; once more only, then on.
	rm "${dir}/platform-drift.txt"
	: > "$CALLS"
	PROBE_KUBE=down run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	[[ "$stderr" == *"warning: member-a, member-b: KUBE_VERSIONS not read at the sweep's start or end, so whether it changed during the sweep is not known"* ]]
	[ "$(grep -c -- '--context=member-b .*version --output=json' "$CALLS")" -eq 2 ]
	[ "$(grep -c -- '--context=member-a .*get deploy istiod' "$CALLS")" -eq 1 ]
}

@test "_platform_limits_differ (R6): members grouped by their limits, five names a group and five groups at most" {
	local v="" i
	for i in $(seq 1 7); do v+="${v:+,}m${i}=4000/2048"; done
	v+=",x1=1000/512"
	for i in $(seq 2 6); do v+=",y${i}=${i}000/${i}"; done
	run _platform_limits_differ "$v" 2000 4096 "recorded on src"
	assert_output "istiod's limits per replica on m1, m2, m3, m4, m5 and 2 more (CPU 4000m, memory 2048Mi); x1 (CPU 1000m, memory 512Mi); y2 (CPU 2000m, memory 2Mi); y3 (CPU 3000m, memory 3Mi); y4 (CPU 4000m, memory 4Mi); and 2 more members under other limits differ from those recorded on src (CPU 2000m, memory 4096Mi)"
	run _platform_limits_differ "a=unknown/2048" unknown 4096 "recorded on src"
	assert_output "istiod's limits per replica on a (CPU unknown, memory 2048Mi) differ from those recorded on src (CPU unknown, memory 4096Mi)"
	# U9-N3: one member more; without names (the scale envelope), how many a group has.
	run _platform_limits_differ "a1=1000/1,a2=2000/2,a3=3000/3,a4=4000/4,a5=5000/5,a6=6000/6" 2000 4096 "recorded on src"
	assert_output "istiod's limits per replica on a1 (CPU 1000m, memory 1Mi); a2 (CPU 2000m, memory 2Mi); a3 (CPU 3000m, memory 3Mi); a4 (CPU 4000m, memory 4Mi); a5 (CPU 5000m, memory 5Mi); and 1 more member under other limits differ from those recorded on src (CPU 2000m, memory 4096Mi)"
	_pl_no_members=1 run _platform_limits_differ "a=4000/2048,b=4000/2048,c=1000/512" 2000 4096 "recorded on src"
	assert_output "istiod's limits per replica on 2 members (CPU 4000m, memory 2048Mi); 1 member (CPU 1000m, memory 512Mi) differ from those recorded on src (CPU 2000m, memory 4096Mi)"
}

@test "platform_report_values (H2, H13): a sweep's drift marker makes its keys mixed; the body names the sweep's dir, never a path" {
	local d="${BATS_TEST_TMPDIR}/sweep" b="${BATS_TEST_TMPDIR}/base"
	mkdir -p "$d"
	platform_fixture_lines > "${d}/a.tsv"
	platform_fixture_lines > "${d}/b.tsv"
	printf '%s\n' '# Values that changed during this sweep' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' \
		'# ISTIOD_IMAGE_BY_CONTEXT=ctx-a=pilot:1.30.6' > "${d}/platform-drift.txt"
	run --separate-stderr platform_report_values "${d}/a.tsv" "${d}/b.tsv"
	assert_success
	assert_line "ISTIOD_IMAGE_BY_CONTEXT=ctx-a=mixed:pilot:1.30.5;pilot:1.30.6,ctx-b=pilot:1.30.5"
	assert_line "PROXY_IMAGE_BY_CONTEXT=ctx-a=proxyv2:1.30.5,ctx-b=proxyv2:1.30.5"
	[[ "$stderr" == *"warning: ISTIOD_IMAGE_BY_CONTEXT changed during the sweep (platform-drift.txt in sweep): ctx-a from pilot:1.30.5 to pilot:1.30.6; the TSVs record the value at the sweep's start, but rows measured after the change ran on other istiod builds, and the report cannot tell which rows those are; the usual cause is an Argo CD sync of a new revision or an operator upgrade; for publishable figures, run the sweep again on one build"* ]]
	[ "$(grep -c 'changed during the sweep' <<<"$stderr")" -eq 1 ]
	run platform_report_warnings "${d}/a.tsv" "${d}/b.tsv"
	assert_output --partial "ISTIOD_IMAGE_BY_CONTEXT changed during the sweep (platform-drift.txt in sweep): ctx-a from pilot:1.30.5 to pilot:1.30.6; the TSVs record the value at the sweep's start"
	refute_output --partial "warning:"
	# Another sweep's inputs are not touched by it.
	mkdir -p "${BATS_TEST_TMPDIR}/other"
	platform_fixture_lines > "${BATS_TEST_TMPDIR}/other/c.tsv"
	run platform_report_warnings "${BATS_TEST_TMPDIR}/other/c.tsv"
	[ -z "$output" ]
	# A report over a base dir with two sweeps (PL6) names the one that drifted, by its dir's name.
	mkdir -p "${b}/sweep-r1" "${b}/sweep-r2"
	cp "${d}/a.tsv" "${d}/platform-drift.txt" "${b}/sweep-r1/"
	cp "${d}/b.tsv" "${b}/sweep-r2/"
	run platform_report_warnings "${b}/sweep-r1/a.tsv" "${b}/sweep-r2/b.tsv"
	assert_output --partial "ISTIOD_IMAGE_BY_CONTEXT changed during the sweep (platform-drift.txt in sweep-r1): ctx-a from pilot:1.30.5 to pilot:1.30.6; "
	refute_output --partial "$BATS_TEST_TMPDIR"
	refute_output --partial "sweep-r2"
}

@test "platform_report_warnings (H7): the marker's KUBE_VERSIONS and tuning lines go to the body of the sweep's reports" {
	local d="${BATS_TEST_TMPDIR}/sweep"
	mkdir -p "$d"
	{
		platform_fixture_lines
		echo '# KUBE_VERSIONS=ctx-a=v1.33.1,ctx-b=v1.33.1'
		echo '# TUNING_BASELINE=sidecar=on,discoverySelectors=off,telemetryFiltering=off,accessLogFiltering=off'
		echo '# SIDECAR_EGRESS_HOSTS=istio-system/* ./*'
	} > "${d}/a.tsv"
	printf '%s\n' '# Values that changed during this sweep' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' '# KUBE_VERSIONS=ctx-b=v1.33.2' \
		'# TUNING_BASELINE=sidecar=off,discoverySelectors=off,telemetryFiltering=off,accessLogFiltering=off' \
		'# SIDECAR_EGRESS_HOSTS=none' > "${d}/platform-drift.txt"
	run platform_report_warnings "${d}/a.tsv"
	assert_line "KUBE_VERSIONS changed during the sweep (platform-drift.txt in sweep): ctx-b from v1.33.1 to v1.33.2; the TSVs record the value at the sweep's start, but rows measured after the change ran on other Kubernetes versions, and the report cannot tell which rows those are; the usual cause is a managed control-plane upgrade; for publishable figures, run the sweep again on one Kubernetes version"
	assert_line "TUNING_BASELINE changed during the sweep in sweep (platform-drift.txt): sidecar from on to off; rows measured after the change ran with other tuning levers, and the report cannot tell which rows those are; the usual cause is a GitOps sync or self-heal that put a lever back, a tuning profile left applied, or a hand edit; for publishable figures, run the sweep again with the levers fixed"
	assert_line --partial "SIDECAR_EGRESS_HOSTS changed during the sweep in sweep (platform-drift.txt): istio-system/* ./* at its start, none at its end; rows measured after the change ran with other root Sidecar egress hosts"
	# Merged (churn's --with KUBE_VERSIONS), it reads mixed, and the body says it once.
	run --separate-stderr platform_merge_by_context KUBE_VERSIONS "${d}/a.tsv"
	assert_output "ctx-a=v1.33.1,ctx-b=mixed:v1.33.1;v1.33.2"
	run platform_report_warnings --with KUBE_VERSIONS "${d}/a.tsv"
	[ "$(grep -c '^KUBE_VERSIONS changed during the sweep' <<<"$output")" -eq 1 ]
	# Only for keys the inputs record: a reach TSV next to them has neither.
	printf '# RUN_ID=r\ntimestamp\n' > "${d}/reach-r.tsv"
	run platform_report_warnings "${d}/reach-r.tsv"
	[ -z "$output" ]
}

@test "platform_drift_changes (M7-B1): what changed during one pass, a line per key from the drift file next to its TSVs; nothing without one" {
	local d="${BATS_TEST_TMPDIR}/pass"
	mkdir -p "$d"
	{
		platform_fixture_lines | sed "s#proxyv2:1.30.5#proxyv2:1.30.5@${DIG_A}#g"
		echo '# KUBE_VERSIONS=ctx-a=v1.33.1,ctx-b=v1.33.1'
		echo '# TUNING_BASELINE=sidecar=on,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on'
		echo '# SIDECAR_EGRESS_HOSTS=./* istio-system/*'
		echo '# ISTIOD_CPU_LIMIT_M=2000'
		echo '# ISTIOD_MEM_LIMIT_MI=4096'
	} > "${d}/a.tsv"
	run --separate-stderr platform_drift_changes "${d}/a.tsv"
	assert_success
	[ -z "$output" ]
	[ -z "$stderr" ]
	printf '%s\n' '# Values that changed during this pass' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' \
		"# PROXY_IMAGE_BY_CONTEXT=ctx-a=proxyv2:1.30.5@${DIG_B},ctx-b=proxyv2:1.30.5@${DIG_B}" \
		'# KUBE_VERSIONS=ctx-b=v1.33.2' \
		'# TUNING_BASELINE=sidecar=off,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on' \
		'# ISTIOD_CPU_LIMIT_M=4000' '# ISTIOD_LIMITS_DIFFER_BY_CONTEXT=ctx-b=2000/4096' > "${d}/platform-drift.txt"
	run --separate-stderr platform_drift_changes "${d}/a.tsv"
	assert_success
	[ -z "$stderr" ]
	# The record's keys, then KUBE_VERSIONS, the levers and the limits; digests shortened; the
	# members whose limits differ from the recorded ones are not a change (every read finds them).
	[ "${#lines[@]}" -eq 4 ]
	assert_line --index 0 $'PROXY_IMAGE_BY_CONTEXT\tgateway proxy builds\tproxyv2:1.30.5@sha256:aaaaaaaaaaaa to proxyv2:1.30.5@sha256:bbbbbbbbbbbb on ctx-a, ctx-b'
	assert_line --index 1 $'KUBE_VERSIONS\tKubernetes versions\tv1.33.1 to v1.33.2 on ctx-b'
	assert_line --index 2 $'TUNING_BASELINE\ttuning levers\tsidecar from on to off'
	assert_line --index 3 $'ISTIOD_CPU_LIMIT_M\tistiod CPU limits\t2000 at its start, 4000 at its end'
	# SC9-S1: a file with only the read's time and what it could not compare holds no change, and
	# nothing is merged for it (every key, over hundreds of members).
	printf '%s\n' '# Values that changed during this pass' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' \
		'# NOT_COMPARED_AT_END=ctx-b=KUBE_VERSIONS' > "${d}/platform-drift.txt"
	platform_merge_by_context() { : > "${BATS_TEST_TMPDIR}/merged"; }
	run --separate-stderr platform_drift_changes "${d}/a.tsv"
	assert_success
	[ -z "$output" ]
	[ ! -e "${BATS_TEST_TMPDIR}/merged" ]
	echo '# KUBE_VERSIONS=ctx-b=v1.33.2' >> "${d}/platform-drift.txt"
	run --separate-stderr platform_drift_changes "${d}/a.tsv"
	[ -e "${BATS_TEST_TMPDIR}/merged" ]
}

# ---------------------------------------------------------------------------
# The reports' body (H10): platform_report_warnings, platform_warning_lines and the helpers
# ---------------------------------------------------------------------------

@test "platform_report_warnings (H10, H2): per-key wording; unknown or a digest @unknown against known could not be read; a state-only difference is not mixed" {
	local d="$BATS_TEST_TMPDIR"
	platform_fixture_lines > "${d}/a.tsv"
	# ctx-a's operator only Unavailable: one build, both states kept, no warning.
	platform_fixture_lines | sed 's#/Available#/Unavailable#' > "${d}/state.tsv"
	run --separate-stderr platform_report_values "${d}/a.tsv" "${d}/state.tsv"
	assert_line "MESH_OPERATOR_BY_CONTEXT=ctx-a=sail-operator:1.31.1/Available;sail-operator:1.31.1/Unavailable,ctx-b=sail-operator:1.31.1/Available"
	refute_output --partial "mixed"
	[ -z "$stderr" ] || { echo "$stderr"; false; }
	run platform_report_warnings "${d}/a.tsv" "${d}/state.tsv"
	[ -z "$output" ]
	# A value that could not be read in one input, against a known one elsewhere.
	platform_fixture_lines | sed 's/ctx-b=pilot:1.30.5/ctx-b=unknown/' > "${d}/unread.tsv"
	run platform_report_warnings "${d}/a.tsv" "${d}/unread.tsv"
	assert_output "ISTIOD_IMAGE_BY_CONTEXT could not be read for ctx-b in 1 of 2 input TSV(s) (recorded unknown), while other inputs have a value: the report cannot tell whether those runs had the same istiod builds as the others"
	run platform_report_values "${d}/a.tsv" "${d}/unread.tsv"
	assert_line "ISTIOD_IMAGE_BY_CONTEXT=ctx-a=pilot:1.30.5,ctx-b=mixed:pilot:1.30.5;unknown"
	# A digest @unknown (no istiod pod had started) against the digest elsewhere: not read too,
	# never another build.
	platform_fixture_lines | sed "s/ctx-b=pilot:1.30.5/ctx-b=pilot:1.30.5@${DIG_A}/" > "${d}/dig.tsv"
	platform_fixture_lines | sed 's/ctx-b=pilot:1.30.5/ctx-b=pilot:1.30.5@unknown/' > "${d}/atu.tsv"
	run platform_report_warnings "${d}/dig.tsv" "${d}/atu.tsv"
	assert_output "ISTIOD_IMAGE_BY_CONTEXT could not be read for ctx-b in 1 of 2 input TSV(s) (recorded unknown, or with a digest @unknown: no pod had started), while other inputs have a value: the report cannot tell whether those runs had the same istiod builds as the others"
	run platform_report_values "${d}/dig.tsv" "${d}/atu.tsv"
	assert_line "ISTIOD_IMAGE_BY_CONTEXT=ctx-a=pilot:1.30.5,ctx-b=mixed:pilot:1.30.5@${DIG_A};pilot:1.30.5@unknown"
	# Two builds: the members and the values (digests shortened), per key's noun.
	platform_fixture_lines | sed "s/proxyv2:1.30.5/proxyv2:1.30.6@${DIG_A}/g" > "${d}/proxy.tsv"
	run platform_report_warnings "${d}/a.tsv" "${d}/proxy.tsv"
	assert_output "input TSVs disagree on PROXY_IMAGE_BY_CONTEXT for ctx-a (proxyv2:1.30.5;proxyv2:1.30.6@sha256:aaaaaaaaaaaa), ctx-b (proxyv2:1.30.5;proxyv2:1.30.6@sha256:aaaaaaaaaaaa): the report mixes runs on different gateway proxy builds; compare like with like"
	# --no-members counts them instead (the scale envelope).
	run platform_report_warnings --no-members "${d}/a.tsv" "${d}/proxy.tsv"
	assert_output "input TSVs disagree on PROXY_IMAGE_BY_CONTEXT for 2 of 2 members: the report mixes runs on different gateway proxy builds; compare like with like"
	# KUBE_VERSIONS (--with): different Kubernetes versions; unreachable is not read.
	printf '# KUBE_VERSIONS=ctx-a=v1.33.1,ctx-b=v1.33.1\n' >> "${d}/a.tsv"
	printf '# KUBE_VERSIONS=ctx-a=v1.34.0,ctx-b=unreachable\n' >> "${d}/state.tsv"
	run platform_report_warnings --with KUBE_VERSIONS "${d}/a.tsv" "${d}/state.tsv"
	assert_line "input TSVs disagree on KUBE_VERSIONS for ctx-a (v1.33.1;v1.34.0): the report mixes runs on different Kubernetes versions; compare like with like"
	assert_line "KUBE_VERSIONS could not be read for ctx-b in 1 of 2 input TSV(s) (recorded unknown or unreachable), while other inputs have a value: the report cannot tell whether those runs had the same Kubernetes versions as the others"
	# PLATFORM recorded unknown in one input.
	platform_fixture_lines | sed 's/^# PLATFORM=kubernetes$/# PLATFORM=unknown/' > "${d}/pu.tsv"
	run platform_report_warnings "${d}/a.tsv" "${d}/pu.tsv"
	assert_output "PLATFORM could not be read in 1 of 2 input TSV(s) (recorded unknown), while other inputs have a value: the report cannot tell whether those runs had the same platforms as the others"
	run platform_report_warnings --with
	assert_failure
}

@test "platform_report_warnings (R5): a tuning profile's objects in place warn, naming the members and the objects; none and unknown do not" {
	local d="$BATS_TEST_TMPDIR" o="04-connection-pools:DestinationRule/istio-system/tuning-04"
	platform_fixture_lines > "${d}/a.tsv"
	run platform_report_warnings "${d}/a.tsv"
	[ -z "$output" ]
	platform_fixture_lines | sed 's/ctx-b=none/ctx-b=unknown/' > "${d}/u.tsv"
	run platform_report_warnings "${d}/u.tsv"
	[ -z "$output" ]
	platform_fixture_lines | sed "s#ctx-a=none#ctx-a=${o}#" > "${d}/t.tsv"
	run platform_report_warnings "${d}/t.tsv"
	assert_output "a tuning profile's objects were in place on ctx-a when the run started (TUNING_OBJECTS_BY_CONTEXT: ${o}), so unless this is a tuning pass its figures are not those of the charts' configuration; tests/tuning/005-cleanup.sh undoes them"
	run platform_report_warnings --no-members "${d}/t.tsv"
	assert_output --partial "were in place on 1 of 2 members when the run started"
	# In one input of two: the disagreement warns as well, and the objects are named once.
	run platform_report_warnings "${d}/a.tsv" "${d}/t.tsv"
	assert_line --partial "input TSVs disagree on TUNING_OBJECTS_BY_CONTEXT for ctx-a (none;${o})"
	assert_line --partial "a tuning profile's objects were in place on ctx-a when the run started (TUNING_OBJECTS_BY_CONTEXT: ${o})"
	# (R6) Objects that appeared during the sweep (only the drift marker has them): the drift line
	# says so, and none were in place when the run started.
	mkdir "${d}/sweep-x"
	platform_fixture_lines > "${d}/sweep-x/a.tsv"
	printf '# TUNING_OBJECTS_BY_CONTEXT=ctx-a=%s\n' "$o" > "${d}/sweep-x/platform-drift.txt"
	run platform_report_warnings "${d}/sweep-x/a.tsv"
	assert_output "TUNING_OBJECTS_BY_CONTEXT changed during the sweep (platform-drift.txt in sweep-x): ctx-a from none to ${o}; the TSVs record the value at the sweep's start, but rows measured after the change ran on other tuning profile objects, and the report cannot tell which rows those are; the usual cause is a tuning profile applied or reverted on these members (by a tuning run, or one stopped before its revert, which tests/tuning/005-cleanup.sh undoes from its marker), or a profile's objects applied or deleted by hand; for publishable figures, run the sweep again without a profile's objects (or with the same ones throughout)"
	refute_output --partial "when the run started"
}

@test "platform_warning_lines: md, text, comment and json; nothing (or []) without a warning" {
	local w=$'first one\nsecond'
	run platform_warning_lines md "$w"
	assert_output $'> **Warning:** first one\n\n> **Warning:** second'
	run platform_warning_lines text "$w"
	assert_output $'WARNING: first one\nWARNING: second'
	run platform_warning_lines comment "$w"
	assert_output $'# WARNING: first one\n# WARNING: second'
	run platform_warning_lines json "$w"
	assert_output '["first one","second"]'
	run platform_warning_lines json ""
	assert_output '[]'
	run platform_warning_lines md ""
	assert_output ""
	run platform_warning_lines xml "$w"
	assert_failure
}

@test "platform_compare_values: same, differs or unknown per key; a state-only operator difference is the same build" {
	local ref v
	ref="$(printf '%s\n' PLATFORM=kubernetes TEST_PLATFORM=auto PLATFORM_BY_CONTEXT=a=kubernetes,b=kubernetes \
		"MESH_OPERATOR_BY_CONTEXT=a=sail-operator:1.31.1/Available,b=sail-operator:1.31.1/Available" \
		ISTIOD_IMAGE_BY_CONTEXT=a=pilot:1.30.5,b=pilot:1.30.5 PROXY_IMAGE_BY_CONTEXT=a=proxyv2:1.30.5,b=proxyv2:1.30.5 \
		NODE_PROVIDER_BY_CONTEXT=a=kind,b=kind ISTIOD_ENV_BY_CONTEXT=a=0123456789ab,b=0123456789ab \
		TUNING_OBJECTS_BY_CONTEXT=a=none,b=none)"
	v="${ref/a=sail-operator:1.31.1\/Available/a=sail-operator:1.31.1/Unavailable}"
	v="${v/b=pilot:1.30.5/b=pilot:1.30.6}"
	v="${v/a=proxyv2:1.30.5/a=unknown}"
	v="${v/NODE_PROVIDER_BY_CONTEXT=a=kind,b=kind/NODE_PROVIDER_BY_CONTEXT=a=kind}"
	run platform_compare_values "$ref" "$v"
	assert_success
	assert_line $'PLATFORM\tsame'
	assert_line $'TEST_PLATFORM\tsame'
	assert_line $'MESH_OPERATOR_BY_CONTEXT\tsame'
	assert_line $'ISTIOD_IMAGE_BY_CONTEXT\tdiffers'
	assert_line $'PROXY_IMAGE_BY_CONTEXT\tunknown'
	assert_line $'NODE_PROVIDER_BY_CONTEXT\tunknown'
	[ "${#lines[@]}" -eq "${#PLATFORM_KEYS[@]}" ]
	run platform_compare_values "$ref" "${ref/TEST_PLATFORM=auto/TEST_PLATFORM=openshift}"
	assert_line $'TEST_PLATFORM\tdiffers'
	run platform_compare_values "$ref" "$ref"
	refute_output --partial differs
	refute_output --partial unknown
	# A digest @unknown (no pod had started) is not read, never another build; its tag still is.
	ref="${ref//pilot:1.30.5/pilot:1.30.5@${DIG_B}}"
	run platform_compare_values "$ref" "${ref/a=pilot:1.30.5@${DIG_B}/a=pilot:1.30.5@unknown}"
	assert_line $'ISTIOD_IMAGE_BY_CONTEXT\tunknown'
	run platform_compare_values "$ref" "${ref/a=pilot:1.30.5@${DIG_B}/a=pilot:1.30.6@unknown}"
	assert_line $'ISTIOD_IMAGE_BY_CONTEXT\tdiffers'
	# Other istiod settings: a difference, except over the keys a tuning pass is compared on.
	v="${ref/a=0123456789ab/a=fedcba987654}"
	run platform_compare_values "$ref" "$v"
	assert_line $'ISTIOD_ENV_BY_CONTEXT\tdiffers'
	run platform_compare_values "$ref" "$v" "${PLATFORM_PASS_KEYS[@]}"
	refute_output --partial ISTIOD_ENV_BY_CONTEXT
	refute_output --partial differs
	[ "${#lines[@]}" -eq "${#PLATFORM_PASS_KEYS[@]}" ]
	# The passes compare each member's Kubernetes version too (M7-S2): another version differs, a
	# member that could not be read (unreachable) or a record without the key is not known, and a
	# k3s version keeps its "+" part (never two pods' values), in any member order.
	[[ " ${PLATFORM_PASS_KEYS[*]} " == *" KUBE_VERSIONS "* ]]
	run platform_compare_values "KUBE_VERSIONS=a=v1.33.1,b=v1.33.1" "KUBE_VERSIONS=a=v1.33.1,b=v1.34.0" KUBE_VERSIONS
	assert_output $'KUBE_VERSIONS\tdiffers'
	run platform_compare_values "KUBE_VERSIONS=a=v1.33.1,b=v1.33.1" "KUBE_VERSIONS=a=v1.33.1,b=unreachable" KUBE_VERSIONS
	assert_output $'KUBE_VERSIONS\tunknown'
	run platform_compare_values "KUBE_VERSIONS=a=v1.33.1" "PLATFORM=kubernetes" KUBE_VERSIONS
	assert_output $'KUBE_VERSIONS\tunknown'
	run platform_compare_values "KUBE_VERSIONS=a=v1.30.4+k3s1,b=v1.30.4+k3s1" "KUBE_VERSIONS=b=v1.30.4+k3s1,a=v1.30.4+k3s1" KUBE_VERSIONS
	assert_output $'KUBE_VERSIONS\tsame'
	run platform_compare_values "KUBE_VERSIONS=a=v1.30.4+k3s1" "KUBE_VERSIONS=a=v1.30.4+k3s2" KUBE_VERSIONS
	assert_output $'KUBE_VERSIONS\tdiffers'
	run platform_value_against KUBE_VERSIONS "a=v1.33.1,b=v1.34.0" "a=v1.33.1,b=v1.33.1"
	assert_output "b=v1.34.0 (1 of 2 members; the other 1 matches)"
	run platform_value_against KUBE_VERSIONS "a=v1.30.4+k3s1,b=v1.30.4+k3s1" "a=v1.30.4+k3s1,b=v1.30.4+k3s1"
	assert_output "v1.30.4+k3s1"
}

@test "_platform_build_cmp (H2): one build, another, or not known; @unknown and a state never make another build" {
	local k=ISTIOD_IMAGE_BY_CONTEXT
	[ "$(_platform_build_cmp "$k" "pilot:1.30.5@${DIG_B}" "pilot:1.30.5@${DIG_B}")" = same ]
	[ "$(_platform_build_cmp "$k" "pilot:1.30.5@${DIG_A}" "pilot:1.30.5@${DIG_B}")" = differs ]
	[ "$(_platform_build_cmp "$k" "pilot:1.30.5@unknown" "pilot:1.30.5@${DIG_B}")" = unknown ]
	[ "$(_platform_build_cmp "$k" "pilot:1.30.5@unknown" "pilot:1.30.5@unknown")" = unknown ]
	[ "$(_platform_build_cmp "$k" "pilot:1.30.5@unknown" "pilot:1.30.6@${DIG_B}")" = differs ]
	# A value recorded without a digest (before round 4): comparable only in part.
	[ "$(_platform_build_cmp "$k" "pilot:1.30.5" "pilot:1.30.5@${DIG_B}")" = unknown ]
	[ "$(_platform_build_cmp "$k" "pilot:1.30.5" "pilot:1.30.5")" = same ]
	# A rollout: every build of each side needs one on the other.
	[ "$(_platform_build_cmp "$k" "pilot:1.30.5@${DIG_A}+pilot:1.30.5@${DIG_B}" "pilot:1.30.5@${DIG_B}")" = differs ]
	[ "$(_platform_build_cmp "$k" "mixed:pilot:1.30.5@${DIG_B};pilot:1.30.5@unknown" "pilot:1.30.5@${DIG_B}")" = unknown ]
	# none (no such pod) is a definite value; unknown is not read.
	[ "$(_platform_build_cmp "$k" none "pilot:1.30.5@${DIG_B}")" = differs ]
	[ "$(_platform_build_cmp "$k" unknown "pilot:1.30.5@${DIG_B}")" = unknown ]
	[ "$(_platform_build_cmp MESH_OPERATOR_BY_CONTEXT "sail-operator:1.31.1@${DIG_A}/Available" "sail-operator:1.31.1@${DIG_A}/Unavailable")" = same ]
	# Kubernetes versions keep their "+" (k3s); unreachable is not read.
	[ "$(_platform_build_cmp KUBE_VERSIONS v1.30.4+k3s1 v1.30.4+k3s1)" = same ]
	[ "$(_platform_build_cmp KUBE_VERSIONS v1.30.4+k3s1 v1.30.4+k3s2)" = differs ]
	[ "$(_platform_build_cmp KUBE_VERSIONS unreachable v1.33.1)" = unknown ]
	[ "$(_platform_build_cmp ISTIOD_ENV_BY_CONTEXT 0123456789ab 0123456789ab+fedcba987654)" = differs ]
	# Nodes (R5): a node without a provider ID beside a provider's (a control-plane node, a
	# virtual node) is that provider's; none alone, or an unrecognized ID, is not.
	[ "$(_platform_build_cmp NODE_PROVIDER_BY_CONTEXT aws+none aws)" = same ]
	[ "$(_platform_build_cmp NODE_PROVIDER_BY_CONTEXT none aws)" = differs ]
	[ "$(_platform_build_cmp NODE_PROVIDER_BY_CONTEXT aws+unrecognized aws)" = differs ]
	[ "$(_platform_build_cmp NODE_PROVIDER_BY_CONTEXT aws+none kind+none)" = differs ]
}

@test "platform_compare_members and platform_value_against (R5): only the members that do not match, five at most" {
	run platform_compare_members PROXY_IMAGE_BY_CONTEXT "a=p:1,b=p:1,c=p:1" "a=p:1,b=p:2,d=p:1"
	assert_success
	assert_output "$(printf '%s\t%s\t%s\t%s\n' b p:1 p:2 differs c p:1 - unknown d - p:1 unknown)"
	# A state-only operator difference matches; a token without a member is left out.
	run platform_compare_members MESH_OPERATOR_BY_CONTEXT "a=s:1/Available" "mixed:unknown,a=s:1/Unavailable"
	assert_output ""
	# Every member shares one value: that value, as platform_collapse gives it.
	run platform_value_against PROXY_IMAGE_BY_CONTEXT "a=p:2,b=p:2" "a=p:1,b=p:1"
	assert_output "p:2"
	run platform_value_against PLATFORM kubernetes openshift
	assert_output kubernetes
	run platform_value_against PROXY_IMAGE_BY_CONTEXT "a=p:1,b=p:2,c=p:1" "a=p:1,b=p:1,c=p:1"
	assert_output "b=p:2 (1 of 3 members; the other 2 match)"
	run platform_value_against PROXY_IMAGE_BY_CONTEXT "a=p:2,b=p:3" "a=p:1,b=p:1"
	assert_output "a=p:2, b=p:3 (all 2 members)"
	run platform_value_against PROXY_IMAGE_BY_CONTEXT "mixed:unknown,a=p:1,b=p:2" "a=p:1,b=p:1,c=p:1"
	assert_output "not recorded in some of its TSVs, b=p:2, c not recorded (2 of 3 members; the other 1 matches)"
	run platform_value_against PROXY_IMAGE_BY_CONTEXT "mixed:unknown,a=p:1,b=p:2" "a=p:1,b=p:2"
	assert_output "not recorded in some of its TSVs, every member recorded matches"
	# U9-S3: the one value only when no member or every member differs, each recorded on both
	# sides; else the members that differ, so one that matches (by one of two values a reference
	# member ran: R9-B1) or that a side does not record is not hidden behind it.
	run platform_value_against PROXY_IMAGE_BY_CONTEXT "a=p:1,b=p:1" "a=p:1,b=p:1"
	assert_output "p:1"
	run platform_value_against PROXY_IMAGE_BY_CONTEXT "a=p:2,b=p:2" "a=p:1,b=p:2"
	assert_output "a=p:2 (1 of 2 members; the other 1 matches)"
	run platform_value_against PROXY_IMAGE_BY_CONTEXT "a=p:2,b=p:2" "a=mixed:p:1;p:2,b=p:1"
	assert_output "b=p:2 (1 of 2 members; the other 1 matches)"
	run platform_value_against PROXY_IMAGE_BY_CONTEXT "a=p:2,b=p:2" "a=p:1,b=p:1,c=p:1"
	assert_output "a=p:2, b=p:2, c not recorded (all 3 members)"
	# A member that ran more than one value (its inputs disagree) is shown though it matches by
	# one of them, its values joined (I11-N2); every member on the same two: those, once.
	run platform_value_against PROXY_IMAGE_BY_CONTEXT "a=mixed:p:1;p:2,b=p:1" "a=p:1,b=p:1"
	assert_output "a=mixed: p:1 and p:2 (1 of 2 members; the other 1 matches)"
	run platform_value_against PROXY_IMAGE_BY_CONTEXT "a=mixed:p:2;p:3,b=p:2" "a=p:1,b=p:1"
	assert_output "a=mixed: p:2 and p:3, b=p:2 (all 2 members)"
	run platform_value_against PROXY_IMAGE_BY_CONTEXT "a=mixed:p:1;p:2,b=mixed:p:1;p:2" "a=p:1,b=p:1"
	assert_output "mixed: p:1 and p:2"
	# The members that do not match come first: six that only ran two values do not push the one
	# that differs, or one not recorded, out of the five named (I12-B1); past five, how many more
	# members, so a mixed value's "and" does not run into it (I12-N1).
	local six="m1=mixed:1;2,m2=mixed:1;2,m3=mixed:1;2,m4=mixed:1;2,m5=mixed:1;2,m6=mixed:1;2"
	run platform_value_against ISTIOD_REPLICAS_BY_CONTEXT "${six},m7=3" "m1=1,m2=1,m3=1,m4=1,m5=1,m6=1,m7=1"
	assert_output "m7=3, m1=mixed: 1 and 2, m2=mixed: 1 and 2, m3=mixed: 1 and 2, m4=mixed: 1 and 2, and 2 more members (all 7 members)"
	run platform_value_against ISTIOD_REPLICAS_BY_CONTEXT "$six" "m1=1,m2=1,m3=1,m4=1,m5=1,m6=1,m7=1,m8=1"
	assert_output "m7 not recorded, m8 not recorded, m1=mixed: 1 and 2, m2=mixed: 1 and 2, m3=mixed: 1 and 2, and 3 more members (all 8 members)"
	# Those that differ before those not read on a side, so six failed reads do not push the one
	# that differs out either (I13-B1); then those that ran two values; one more, one member.
	run platform_value_against ISTIOD_REPLICAS_BY_CONTEXT "m1=unknown,m2=unknown,m3=unknown,m4=unknown,m5=unknown,m6=unknown,m7=3" "m1=1,m2=1,m3=1,m4=1,m5=1,m6=1,m7=1"
	assert_output "m7=3, m1=unknown, m2=unknown, m3=unknown, m4=unknown, and 2 more members (all 7 members)"
	run platform_value_against ISTIOD_REPLICAS_BY_CONTEXT "m1=mixed:1;2,m2=unknown,m3=2,m4=1,m5=1,m6=1,m7=1,m8=1" "m1=1,m2=1,m3=1,m4=1,m5=1,m6=1,m7=1,m8=1"
	assert_output "m3=2, m2=unknown, m1=mixed: 1 and 2 (3 of 8 members; the other 5 match)"
	run platform_value_against ISTIOD_REPLICAS_BY_CONTEXT "m1=2,m2=2,m3=2,m4=2,m5=2,m6=2,m7=1" "m1=1,m2=1,m3=1,m4=1,m5=1,m6=1,m7=1"
	assert_output "m1=2, m2=2, m3=2, m4=2, m5=2, and 1 more member (6 of 7 members; the other 1 matches)"
	# Counts from before the record (no member) that disagree (R11-N1).
	run platform_value_against ISTIOD_REPLICAS_BY_CONTEXT "mixed:2;1" 1
	assert_output "mixed: 2 and 1"
	run platform_members_by_value "mixed:1;2"
	assert_output "mixed: 1 and 2"
	run platform_summary "mixed:1;2,a=2"
	assert_output "mixed: 1 and 2, 2 (1 member)"
	# A fleet: 500 members, 7 of them on another build, named five at most.
	local ref="" v="" i
	for ((i = 1; i <= 500; i++)); do
		ref+="${ref:+,}m${i}=p:1"
		if ((i % 70 == 0)); then v+="${v:+,}m${i}=p:2"; else v+="${v:+,}m${i}=p:1"; fi
	done
	run platform_value_against PROXY_IMAGE_BY_CONTEXT "$v" "$ref"
	assert_output "m70=p:2, m140=p:2, m210=p:2, m280=p:2, m350=p:2, and 2 more members (7 of 500 members; the other 493 match)"
}

@test "platform_compare_members (U8-B1): a member with two values matches when one of them is the other side's build, else differs when a pair differs, else is not known" {
	# The reference pass's member changed during its pass (mixed:<a>;<b>): a pass on either matches.
	run platform_compare_members PROXY_IMAGE_BY_CONTEXT "a=mixed:p:1;p:2,b=p:1" "a=p:2,b=p:1"
	assert_success
	assert_output ""
	run platform_compare_members PROXY_IMAGE_BY_CONTEXT "a=mixed:p:1;p:2,b=p:1" "a=p:3,b=p:1"
	assert_output "$(printf '%s\t%s\t%s\t%s' a 'mixed:p:1;p:2' p:3 differs)"
	# On either side, or both: one build in common is enough.
	run platform_compare_members PROXY_IMAGE_BY_CONTEXT "a=p:2" "a=mixed:p:2;p:3"
	assert_output ""
	run platform_compare_members PROXY_IMAGE_BY_CONTEXT "a=mixed:p:1;p:2" "a=mixed:p:2;p:3"
	assert_output ""
	# One of them not read: another that differs still differs; else not known.
	run platform_compare_members PROXY_IMAGE_BY_CONTEXT "a=mixed:unknown;p:1" "a=p:2"
	assert_output "$(printf '%s\t%s\t%s\t%s' a 'mixed:unknown;p:1' p:2 differs)"
	run platform_compare_members PROXY_IMAGE_BY_CONTEXT "a=mixed:unknown;p:1" "a=p:1"
	assert_output ""
	run platform_compare_members PROXY_IMAGE_BY_CONTEXT "a=mixed:unknown;p:1@unknown" "a=p:1@${DIG_B}"
	assert_output "$(printf '%s\t%s\t%s\t%s' a 'mixed:unknown;p:1@unknown' "p:1@${DIG_B}" unknown)"
	# The same for a scalar, whose values a mixed: joins with ",".
	run platform_compare_values "TEST_PLATFORM=mixed:auto,kubernetes" "TEST_PLATFORM=kubernetes" TEST_PLATFORM
	assert_output $'TEST_PLATFORM\tsame'
	run platform_compare_values "TEST_PLATFORM=mixed:auto,kubernetes" "TEST_PLATFORM=openshift" TEST_PLATFORM
	assert_output $'TEST_PLATFORM\tdiffers'
}

@test "platform_lever_values (M8-B1): nothing for inputs that record none; a key one input lacks is mixed with unknown; without a drift file the other members' limits are not known" {
	local dir="${BATS_TEST_TMPDIR}/pass"
	mkdir -p "$dir"
	printf '%s\n' "# PLATFORM_BY_CONTEXT=a=kubernetes,b=kubernetes" c1 1 >"${dir}/legacy.tsv"
	run platform_lever_values "${dir}/legacy.tsv"
	assert_success
	assert_output ""
	printf '%s\n' "# TUNING_BASELINE=sidecar=on,discoverySelectors=off" "# SIDECAR_EGRESS_HOSTS=./* istio-system/*" \
		"# ISTIOD_CPU_LIMIT_M=2000" "# ISTIOD_MEM_LIMIT_MI=4096" "# PLATFORM_BY_CONTEXT=a=kubernetes,b=kubernetes" c1 1 \
		>"${dir}/r1.tsv"
	# The limits are read on the record's first member (the source); nothing read b's.
	run platform_lever_values "${dir}/r1.tsv"
	assert_output "TUNING_BASELINE=sidecar=on,discoverySelectors=off
SIDECAR_EGRESS_HOSTS=./* istio-system/*
ISTIOD_CPU_LIMIT_M_BY_CONTEXT=a=2000,b=unknown
ISTIOD_MEM_LIMIT_MI_BY_CONTEXT=a=4096,b=unknown"
	# An input from before the keys: each value is also not known there.
	run platform_lever_values "${dir}/r1.tsv" "${dir}/legacy.tsv"
	assert_output "TUNING_BASELINE=sidecar=mixed:on;unknown,discoverySelectors=mixed:off;unknown
SIDECAR_EGRESS_HOSTS=mixed:./* istio-system/*,unknown
ISTIOD_CPU_LIMIT_M_BY_CONTEXT=a=mixed:2000;unknown,b=unknown
ISTIOD_MEM_LIMIT_MI_BY_CONTEXT=a=mixed:4096;unknown,b=unknown"
	# Inputs that disagree on a lever and on the hosts hold both.
	sed 's/^# TUNING_BASELINE=sidecar=on/# TUNING_BASELINE=sidecar=off/; s|^# SIDECAR_EGRESS_HOSTS=.*|# SIDECAR_EGRESS_HOSTS=none|' \
		"${dir}/r1.tsv" >"${dir}/r2.tsv"
	run platform_lever_values "${dir}/r1.tsv" "${dir}/r2.tsv"
	assert_line "TUNING_BASELINE=sidecar=mixed:on;off,discoverySelectors=off"
	assert_line "SIDECAR_EGRESS_HOSTS=mixed:./* istio-system/*,none"
	assert_line "ISTIOD_CPU_LIMIT_M_BY_CONTEXT=a=2000,b=unknown"
}

@test "platform_lever_values (I9-B1): istiod's replicas as each suite records them, per member under its record name; inputs that disagree or lack a member hold each, unknown for the one without" {
	local dir="${BATS_TEST_TMPDIR}/pass"
	mkdir -p "$dir"
	# controlplane: every member's Deployment replicas (ISTIOD_REPLICAS_BY_CONTEXT), not their
	# summary (ISTIOD_REPLICAS, min-max).
	printf '%s\n' "# PLATFORM_BY_CONTEXT=a=kubernetes,b=kubernetes" "# ISTIOD_REPLICAS=1-3" \
		"# ISTIOD_REPLICAS_BY_CONTEXT=a=1,b=3" c1 1 >"${dir}/cp.tsv"
	run platform_lever_values "${dir}/cp.tsv"
	assert_success
	assert_output "ISTIOD_REPLICAS_BY_CONTEXT=a=1,b=3"
	# A controlplane TSV from before it read every member: the number, on the first.
	printf '%s\n' "# PLATFORM_BY_CONTEXT=a=kubernetes,b=kubernetes" "# ISTIOD_REPLICAS=3" \
		"# ISTIOD_REPLICAS_BY_CONTEXT=unknown" c1 1 >"${dir}/cp-first.tsv"
	run platform_lever_values "${dir}/cp-first.tsv"
	assert_output "ISTIOD_REPLICAS_BY_CONTEXT=a=3"
	# propagation: every member's Running pods by its context's name, which the record writes with
	# safe characters only (lab~a is lab_a there).
	printf '%s\n' "# PLATFORM_BY_CONTEXT=lab_a=kubernetes,b=kubernetes" "# ISTIOD_REPLICAS=lab~a=2,b=1" c1 1 >"${dir}/prop.tsv"
	run platform_lever_values "${dir}/prop.tsv"
	assert_output "ISTIOD_REPLICAS_BY_CONTEXT=lab_a=2,b=1"
	# churn and churn-dataplane: the source member's (the record's first).
	printf '%s\n' "# PLATFORM_BY_CONTEXT=a=kubernetes,b=kubernetes" "# ISTIOD_REPLICAS=2" c1 1 >"${dir}/churn.tsv"
	run platform_lever_values "${dir}/churn.tsv"
	assert_output "ISTIOD_REPLICAS_BY_CONTEXT=a=2"
	# Inputs that disagree hold both; a member one of them does not record holds unknown too.
	run platform_lever_values "${dir}/cp.tsv" "${dir}/churn.tsv"
	assert_output "ISTIOD_REPLICAS_BY_CONTEXT=a=mixed:1;2,b=mixed:3;unknown"
	printf '%s\n' "# PLATFORM_BY_CONTEXT=a=kubernetes,b=kubernetes" c1 1 >"${dir}/none.tsv"
	run platform_lever_values "${dir}/cp.tsv" "${dir}/none.tsv"
	assert_output "ISTIOD_REPLICAS_BY_CONTEXT=a=mixed:1;unknown,b=mixed:3;unknown"
	run platform_lever_values "${dir}/none.tsv"
	assert_output ""
	# An input from before the record (no member to name it by): its value without one.
	printf '%s\n' "# ISTIOD_REPLICAS=3" c1 1 >"${dir}/old.tsv"
	run platform_lever_values "${dir}/old.tsv"
	assert_output "ISTIOD_REPLICAS_BY_CONTEXT=3"
	run platform_lever_values "${dir}/old.tsv" "${dir}/cp.tsv"
	assert_output "ISTIOD_REPLICAS_BY_CONTEXT=mixed:3;unknown,a=mixed:1;unknown,b=mixed:3;unknown"
}

@test "_platform_compare_key (R10-S2): replica counts that name no member (inputs from before the record) compare as they are; a side without one, or one beside members, is not known" {
	run _platform_compare_key ISTIOD_REPLICAS_BY_CONTEXT 1 1
	assert_success
	assert_output same
	run _platform_compare_key ISTIOD_REPLICAS_BY_CONTEXT 1 2
	assert_output differs
	# Inputs that disagree (mixed:) match when one of their values does; unknown is no value.
	run _platform_compare_key ISTIOD_REPLICAS_BY_CONTEXT "mixed:1;2" 2
	assert_output same
	run _platform_compare_key ISTIOD_REPLICAS_BY_CONTEXT "mixed:1;unknown" 1
	assert_output same
	run _platform_compare_key ISTIOD_REPLICAS_BY_CONTEXT "mixed:1;unknown" 3
	assert_output differs
	run _platform_compare_key ISTIOD_REPLICAS_BY_CONTEXT unknown 1
	assert_output unknown
	run _platform_compare_key ISTIOD_REPLICAS_BY_CONTEXT 1 ""
	assert_output unknown
	run _platform_compare_key ISTIOD_REPLICAS_BY_CONTEXT "" 1
	assert_output unknown
	# A count without a member beside members' (an input from before the record and one after).
	run _platform_compare_key ISTIOD_REPLICAS_BY_CONTEXT 1 a=1
	assert_output unknown
	run _platform_compare_key ISTIOD_REPLICAS_BY_CONTEXT "mixed:3;unknown,a=1" "mixed:3;unknown,a=1"
	assert_output unknown
	run _platform_compare_key ISTIOD_REPLICAS_BY_CONTEXT "mixed:3;unknown,a=1" "mixed:3;unknown,a=2"
	assert_output differs
}

@test "platform_summary and platform_short_digests: no member names, counts when members differ, 12 hex digits" {
	run platform_summary "a=pilot:1.30.5@${DIG_B},b=pilot:1.30.5@${DIG_B}"
	assert_output "pilot:1.30.5@sha256:bbbbbbbbbbbb"
	run platform_summary "a=x,b=y,c=x"
	assert_output "x (2 members), y (1 member)"
	run platform_summary "mixed:unknown,a=x"
	assert_output "mixed:unknown, x (1 member)"
	# H17: a member whose inputs disagree; ";" stays inside nothing the reader has to split.
	run platform_summary "a=mixed:proxyv2:1.30.5;proxyv2:1.30.6@${DIG_A},b=proxyv2:1.30.5"
	assert_output "mixed: proxyv2:1.30.5 and proxyv2:1.30.6@sha256:aaaaaaaaaaaa (1 member), proxyv2:1.30.5 (1 member)"
	run platform_summary unknown
	assert_output unknown
	run platform_summary ""
	assert_output unknown
	run platform_short_digests "img@${DIG_A}+img2@${DIG_C} sha256:abc"
	assert_output "img@sha256:aaaaaaaaaaaa+img2@sha256:cccccccccccc sha256:abc"
}

@test "platform_kind_path_warning: the remote-path warning only when a member's nodes are kind's" {
	run platform_kind_path_warning "a=aws,b=mixed:aws;kind" "remote latency is not a cloud load balancer's"
	assert_output "Nodes on kind (NODE_PROVIDER_BY_CONTEXT): the cross-cluster path runs through cloud-provider-kind's userspace Envoy (the east-west gateway's LoadBalancer, ipMode: Proxy) on the host all kind clusters share, so remote latency is not a cloud load balancer's"
	run platform_kind_path_warning "a=aws,b=gce" "x"
	assert_success
	assert_output ""
	run platform_kind_path_warning unknown "x"
	assert_output ""
	# H5: a member whose node provider was not read may be on kind.
	run platform_kind_path_warning "a=aws,b=unknown" "remote latency is not a cloud load balancer's"
	assert_output "Node provider not read on 1 member(s) (NODE_PROVIDER_BY_CONTEXT unknown): if their nodes are kind's, the cross-cluster path runs through cloud-provider-kind's userspace Envoy (the east-west gateway's LoadBalancer, ipMode: Proxy) on the host all kind clusters share, so remote latency is not a cloud load balancer's"
	run platform_kind_path_warning "a=aws,b=mixed:aws;unknown" "x"
	assert_output --partial "Node provider not read on 1 member(s)"
	# Inputs from before the record name no member: nothing to say about one.
	run platform_kind_path_warning "mixed:unknown,a=aws" "x"
	assert_output ""
}

@test "platform_unread_members (H5): members whose value was not read in every input or in some; none for a memberless token" {
	[ "$(platform_unread_members "a=unknown,b=mixed:kind;unknown,c=aws,mixed:unknown")" -eq 2 ]
	[ "$(platform_unread_members "a=kind,b=aws")" -eq 0 ]
	[ "$(platform_unread_members unknown)" -eq 0 ]
	[ "$(platform_unread_members "")" -eq 0 ]
}

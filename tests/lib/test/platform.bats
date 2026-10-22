#!/usr/bin/env bats
# tests/lib/platform.sh: platform_of and the suite charts' OpenShift overlay (platform_chart_args,
# the charts' two renders, the 001 setup scripts that call it: PL33), platform_validate, and the
# platform record: platform_probe over a stub kubectl, the sweep's shared file, the writers, the
# reports' merge, the drift check, the tuning profile objects, the kind path warning.
# No cluster: the stub kubectl answers from the test, and the entrypoint runs use an empty
# kubeconfig.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/platform.sh"
source "${ROOT}/tests/lib/reach.sh"  # reach_sanitize (platform_probe's warnings)
source "${ROOT}/tests/lib/config.sh"  # config_allowed_keys (the keys --config can set)

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
	unset TEST_PLATFORM FAKE_PLATFORM PLATFORM_PROBE_FILE
	CHART="${BATS_TEST_TMPDIR}/chart"
	mkdir -p "$CHART"
	: > "${CHART}/values-openshift.yaml"
}

# ---------------------------------------------------------------------------
# platform_of, platform_chart_args, platform_validate
# ---------------------------------------------------------------------------

@test "platform_of: auto asks the member once (security.openshift.io/v1 is OpenShift, lookalikes are not); kubernetes or openshift is used as is" {
	FAKE_PLATFORM=openshift run platform_of member-a
	assert_success
	assert_output openshift
	[ "$(wc -l < "$CALLS")" -eq 1 ]
	grep -q -- '--context=member-a --request-timeout=20s api-versions$' "$CALLS"
	FAKE_PLATFORM=kubernetes run platform_of member-a
	assert_output kubernetes
	FAKE_PLATFORM=lookalike run platform_of member-a
	assert_output kubernetes
	: > "$CALLS"
	TEST_PLATFORM=openshift FAKE_PLATFORM=down run platform_of member-a
	assert_output openshift
	TEST_PLATFORM=kubernetes FAKE_PLATFORM=openshift run platform_of member-a
	assert_output kubernetes
	[ ! -s "$CALLS" ]
	# The hub's Argo CD namespace follows it.
	FAKE_PLATFORM=openshift run platform_gitops_namespace hub
	assert_output openshift-gitops
	run platform_gitops_namespace hub
	assert_output argocd
}

@test "platform_of: a member it cannot ask is an error naming it, never a guess; another TEST_PLATFORM fails before any call" {
	FAKE_PLATFORM=down run --separate-stderr platform_of member-b
	assert_failure 1
	[ -z "$output" ]
	[[ "$stderr" == *"cannot list the API versions of context member-b"* ]]
	[[ "$stderr" == *"set TEST_PLATFORM to skip the check"* ]]
	[[ "$stderr" == *"i/o timeout"* ]]
	FAKE_PLATFORM=down run platform_gitops_namespace hub
	assert_failure
	: > "$CALLS"
	TEST_PLATFORM=OpenShift run --separate-stderr platform_of member-a
	assert_failure 1
	[[ "$stderr" == *"TEST_PLATFORM must be auto, kubernetes or openshift (got: OpenShift)"* ]]
	[ ! -s "$CALLS" ]
}

@test "platform_chart_args: the overlay on OpenShift, nothing on Kubernetes; a dry-run with auto asks no cluster, an explicit platform still renders" {
	local a=(stale)
	FAKE_PLATFORM=openshift platform_chart_args "$CHART" member-a a
	[ "${a[*]}" = "-f ${CHART}/values-openshift.yaml" ]
	a=(stale)
	FAKE_PLATFORM=kubernetes platform_chart_args "$CHART" member-a a
	[ "${#a[@]}" -eq 0 ]
	: > "$CALLS"
	DRY_RUN=1
	FAKE_PLATFORM=openshift platform_chart_args "$CHART" member-a a
	[ "${#a[@]}" -eq 0 ]
	TEST_PLATFORM=openshift platform_chart_args "$CHART" member-a a
	[ "${a[*]}" = "-f ${CHART}/values-openshift.yaml" ]
	[ ! -s "$CALLS" ]
	# With auto, a member the record holds is not asked again.
	DRY_RUN=0
	_platform_put member-o $'openshift\tunknown\tunknown\tunknown\tunknown\tunknown'
	platform_chart_args "$CHART" member-o a
	[ "${a[*]}" = "-f ${CHART}/values-openshift.yaml" ]
	[ ! -s "$CALLS" ]
}

@test "platform_chart_args: an unreachable member fails and leaves the array empty; an OpenShift member and a chart without the overlay is an error" {
	local a=(stale)
	FAKE_PLATFORM=down run platform_chart_args "$CHART" member-b a
	assert_failure 1
	assert_output --partial "cannot list the API versions of context member-b"
	FAKE_PLATFORM=down platform_chart_args "$CHART" member-b a 2>/dev/null || true
	[ "${#a[@]}" -eq 0 ]
	rm "${CHART}/values-openshift.yaml"
	TEST_PLATFORM=openshift run platform_chart_args "$CHART" member-a a
	assert_failure 1
	assert_output --partial "has no values-openshift.yaml for OpenShift member member-a"
}

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

@test "platform_validate: TEST_PLATFORM, PLATFORM_READ_TIMEOUT and PLATFORM_READ_PARALLEL refused when not valid; options.env defaults every suite's --config can set" {
	local v s
	for v in auto kubernetes openshift ""; do TEST_PLATFORM="$v" run platform_validate; assert_success; done
	TEST_PLATFORM=k8s run platform_validate
	assert_failure
	assert_output --partial "TEST_PLATFORM must be auto, kubernetes or openshift (got: k8s); set it in the environment, config/options.env or, in a script that takes one, the --config file"
	for v in 20s 1m 30 500ms 1m30s 1.5m; do PLATFORM_READ_TIMEOUT="$v" run platform_validate; assert_success; done
	for v in 0 0s 0.0m abc -5s "20 s"; do
		PLATFORM_READ_TIMEOUT="$v" run platform_validate
		assert_failure
		assert_output --partial "PLATFORM_READ_TIMEOUT must be a kubectl --request-timeout above zero, such as 20s or 1m (got: ${v})"
	done
	for v in 1 20 500; do PLATFORM_READ_PARALLEL="$v" run platform_validate; assert_success; done
	for v in 0 -1 abc 2.5 03; do
		PLATFORM_READ_PARALLEL="$v" run platform_validate
		assert_failure
		assert_output --partial "PLATFORM_READ_PARALLEL must be a whole number above zero: how many members' platform records are read at once (got: ${v})"
	done
	run bash -c 'unset PLATFORM_READ_TIMEOUT PLATFORM_READ_PARALLEL; source "$1/config/options.env"; echo "$PLATFORM_READ_TIMEOUT $PLATFORM_READ_PARALLEL"' _ "$ROOT"
	assert_output "20s 20"
	for s in propagation churn churn-dataplane controlplane dataplane gateway-api; do
		for v in TEST_PLATFORM PLATFORM_READ_TIMEOUT PLATFORM_READ_PARALLEL; do
			config_allowed_keys "$s" | grep -qx "$v" || { echo "${s}: --config cannot set ${v}"; false; }
		done
	done
}

@test "platform_members_check: a member listed twice, or two the record writes under one name, dies before any read, in a dry-run too" {
	KUBECTL=(_probe_kubectl)
	run platform_probe member-a,member-b,member-a
	assert_failure
	assert_output --partial "member-a is listed twice among the mesh members: list each member once (--contexts or SETUP_CONTEXTS; a probe's --source-context is not one of its --remote-contexts)"
	DRY_RUN=1 run platform_members_check "lab~a" lab_a
	assert_failure
	assert_output --partial "lab~a and lab_a would be recorded under one name, lab_a (the record writes a member's name with A-Z, a-z, 0-9 and _.:/@+- only): rename one of the two contexts"
	run platform_members_check member-a "" member-b
	assert_success
	[ ! -s "$CALLS" ]
}

# ---------------------------------------------------------------------------
# The platform record: platform_probe over a stub kubectl
# ---------------------------------------------------------------------------

DIG_A="sha256:$(printf 'a%.0s' {1..64})"
DIG_B="sha256:$(printf 'b%.0s' {1..64})"
DIG_C="sha256:$(printf 'c%.0s' {1..64})"

# _probe_gw <name> <istio label> <tag> <digest>: one running gateway pod.
_probe_gw() {
	printf ',{"metadata":{"name":"%s","labels":{"istio":"%s"}},"spec":{"containers":[{"name":"istio-proxy","image":"registry.example.invalid/istio/proxyv2:%s"}]},"status":{"phase":"Running","containerStatuses":[{"name":"istio-proxy","imageID":"%s","restartCount":0}]}}' "$@"
}

# _probe_kubectl: a member's answers to the record's reads. PROBE_PLATFORM: kubernetes (default),
# openshift, down (no answer; PROBE_DOWN_ON: that member only) or forbidden (api-versions refused,
# the rest answers). PROBE_ISTIOD: istiod's tag (1.30.5); PROBE_ISTIOD_THROTTLE its
# PILOT_PUSH_THROTTLE (100); PROBE_ISTIOD_PODS=pending: its pod has not started. PROBE_EWGW=other:
# the east-west gateway runs another build than the ingress gateway's (an egress gateway never
# counts). PROBE_TUNING_OBJECTS: none (default), marker (profile 02's marker), two (two profiles'
# objects, in reverse order) or timeout; PROBE_TUNING_ON: on that member only.
_probe_kubectl() {
	local a ctx="" st tobj
	printf '%s\n' "$*" >> "$CALLS"
	for a in "$@"; do [[ "$a" != --context=* ]] || ctx="${a#--context=}"; done
	if [[ "${PROBE_PLATFORM:-kubernetes}" == down || ( -n "${PROBE_DOWN_ON:-}" && "$ctx" == "$PROBE_DOWN_ON" ) ]]; then
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
		printf '{"kind":"List","items":[{"kind":"Deployment","metadata":{"name":"sail-operator"},"spec":{"selector":{"matchLabels":{"app":"sail"}},"template":{"spec":{"containers":[{"name":"sail-operator","image":"registry.example.invalid/sail/sail-operator:1.31.1"}]}}}},{"kind":"Pod","metadata":{"name":"sail-1","labels":{"app":"sail"}},"status":{"phase":"Running","containerStatuses":[{"name":"sail-operator","imageID":"registry.example.invalid/sail/sail-operator@%s"}]}},{"kind":"Pod","metadata":{"name":"unrelated","labels":{"app":"x"}},"status":{"containerStatuses":[{"name":"sail-operator","imageID":"%s"}]}}]}\n' "$DIG_A" "$DIG_C"
		;;
	*" -n openshift-operators get clusterserviceversions.operators.coreos.com "*)
		[[ "${PROBE_PLATFORM:-}" == openshift ]] || { echo "error: the server doesn't have a resource type \"clusterserviceversions\"" >&2; return 1; }
		echo '{"items":[{"metadata":{"name":"servicemeshoperator3.v3.4.3"},"spec":{"version":"3.4.3"},"status":{"phase":"Succeeded"}},{"metadata":{"name":"other-operator.v1.0.0"},"spec":{"version":"1.0.0"}}]}'
		;;
	*" -n istio-system get pods "*)
		st=",\"containerStatuses\":[{\"name\":\"discovery\",\"imageID\":\"registry.example.invalid/istio/pilot@${DIG_B}\",\"restartCount\":0}]"
		[[ "${PROBE_ISTIOD_PODS:-}" != pending ]] || st=""
		printf '{"kind":"List","items":[{"metadata":{"name":"istiod-1","labels":{"app":"istiod"}},"spec":{"containers":[{"name":"discovery","image":"registry.example.invalid/istio/pilot:%s","env":[{"name":"CLUSTER_ID","value":"%s"},{"name":"PILOT_PUSH_THROTTLE","value":"%s"},{"name":"POD_NAME","valueFrom":{"fieldRef":{"fieldPath":"metadata.name","apiVersion":"v1"}}}]}]},"status":{"phase":"%s"%s}}' \
			"${PROBE_ISTIOD:-1.30.5}" "$ctx" "${PROBE_ISTIOD_THROTTLE:-100}" "$([[ -n "$st" ]] && echo Running || echo Pending)" "$st"
		_probe_gw ingress-1 ingressgateway 1.30.5 "$DIG_C"
		_probe_gw egress-1 egressgateway 9.9.9 "$DIG_B"
		if [[ "${PROBE_EWGW:-same}" == other ]]; then _probe_gw eastwest-1 eastwestgateway 1.30.6 "$DIG_A"; else _probe_gw eastwest-1 eastwestgateway 1.30.5 "$DIG_C"; fi
		echo ']}'
		;;
	*" get ${PLATFORM_TUNING_KINDS} -A -l ${PLATFORM_TUNING_LABEL} "*)
		tobj="${PROBE_TUNING_OBJECTS:-none}"
		[[ -z "${PROBE_TUNING_ON:-}" || "$ctx" == "$PROBE_TUNING_ON" ]] || tobj=none
		case "$tobj" in
		none) echo '{"kind":"List","items":[]}' ;;
		marker) echo '{"kind":"List","items":[{"kind":"ConfigMap","metadata":{"name":"tuning-profile-02-xds-cache-off","namespace":"istio-system","labels":{"istio-scale-tests/tuning-profile":"02-xds-cache-off"}}}]}' ;;
		two) echo '{"kind":"List","items":[{"kind":"Sidecar","metadata":{"name":"tuning-x","namespace":"ns-b","labels":{"istio-scale-tests/tuning-profile":"09-x"}}},{"kind":"DestinationRule","metadata":{"name":"tuning-connection-pool","namespace":"istio-system","labels":{"istio-scale-tests/tuning-profile":"04-connection-pools"}}}]}' ;;
		timeout)
			echo 'Unable to connect to the server: net/http: request canceled (Client.Timeout exceeded while awaiting headers)' >&2
			return 1
			;;
		esac
		;;
	*" get nodes "*)
		if [[ "${PROBE_PLATFORM:-}" == openshift ]]; then
			echo '{"items":[{"spec":{"providerID":"aws:///zone-a/i-0"}},{"spec":{"providerID":"aws:///zone-b/i-1"}},{"spec":{}}]}'
		else
			echo '{"items":[{"spec":{"providerID":"kind://docker/lab/node-0"}}]}'
		fi
		;;
	*) return 1 ;;
	esac
}

# probe_setup: the record's reads go to _probe_kubectl; warnings to $WARN.
probe_setup() {
	KUBECTL=(_probe_kubectl)
	WARN="${BATS_TEST_TMPDIR}/warn"
	: > "$WARN"
}

# env_digest [PILOT_PUSH_THROTTLE]: ISTIOD_ENV_BY_CONTEXT of the stub istiod's env (its sorted
# name=value lines without CLUSTER_ID, a fieldRef's keys sorted, as one JSON array line): the
# first 12 hex digits of its sha256.
env_digest() {
	printf '["PILOT_PUSH_THROTTLE=%s","POD_NAME={\\"fieldRef\\":{\\"apiVersion\\":\\"v1\\",\\"fieldPath\\":\\"metadata.name\\"}}"]\n' "${1:-100}" > "${BATS_TEST_TMPDIR}/env-list.txt"
	file_sha256 "${BATS_TEST_TMPDIR}/env-list.txt" | cut -c1-12
}

@test "platform_probe: a Kubernetes member records the Sail operator, the builds that ran (tag and digest, no registry) and the node provider; istiod's env without CLUSTER_ID" {
	probe_setup
	PLATFORM_READ_TIMEOUT=45s platform_probe member-a,member-b 2>"$WARN"
	[ ! -s "$WARN" ] || { cat "$WARN"; false; }
	run platform_preamble_lines member-a,member-b
	assert_success
	assert_line "# PLATFORM=kubernetes"
	assert_line "# TEST_PLATFORM=auto"
	assert_line "# PLATFORM_BY_CONTEXT=member-a=kubernetes,member-b=kubernetes"
	# The Deployment's tag and the digest its own pod runs (not the unrelated pod's); no state.
	assert_line "# MESH_OPERATOR_BY_CONTEXT=member-a=sail-operator:1.31.1@${DIG_A},member-b=sail-operator:1.31.1@${DIG_A}"
	assert_line "# ISTIOD_IMAGE_BY_CONTEXT=member-a=pilot:1.30.5@${DIG_B},member-b=pilot:1.30.5@${DIG_B}"
	# The ingress and east-west gateways' build, never the egress gateway's.
	assert_line "# PROXY_IMAGE_BY_CONTEXT=member-a=proxyv2:1.30.5@${DIG_C},member-b=proxyv2:1.30.5@${DIG_C}"
	assert_line "# NODE_PROVIDER_BY_CONTEXT=member-a=kind,member-b=kind"
	# Each member's istiod has its own CLUSTER_ID: one digest for the same settings.
	assert_line "# ISTIOD_ENV_BY_CONTEXT=member-a=$(env_digest),member-b=$(env_digest)"
	refute_output --partial "example.invalid"
	refute_output --partial "TUNING_OBJECTS"
	# Four reads a member, each bounded by PLATFORM_READ_TIMEOUT.
	[ "$(grep -c -- '--context=member-a --request-timeout=45s ' "$CALLS")" -eq 4 ]
	[ "$(wc -l < "$CALLS")" -eq 8 ]
	# Another setting, a rollout of another gateway build, a pod that has not started.
	probe_setup
	PROBE_ISTIOD_THROTTLE=50 PROBE_EWGW=other PROBE_ISTIOD_PODS=pending platform_probe member-c 2>"$WARN"
	[ "$(platform_member_value member-c istiod_env)" = "$(env_digest 50)" ]
	[ "$(platform_member_value member-c proxy)" = "proxyv2:1.30.5@${DIG_C}+proxyv2:1.30.6@${DIG_A}" ]
	[ "$(platform_member_value member-c istiod)" = "pilot:1.30.5@unknown" ]
}

@test "platform_probe: an OpenShift member records its OSSM CSV version and the cloud provider (a node without one left out)" {
	probe_setup
	PROBE_PLATFORM=openshift platform_probe member-o 2>"$WARN"
	[ ! -s "$WARN" ] || { cat "$WARN"; false; }
	run platform_preamble_lines member-o
	assert_line "# PLATFORM=openshift"
	assert_line "# MESH_OPERATOR_BY_CONTEXT=member-o=servicemeshoperator3:3.4.3"
	assert_line "# NODE_PROVIDER_BY_CONTEXT=member-o=aws"
	! grep -q 'sail-operator' "$CALLS" || false
}

@test "platform_probe: a value it cannot read is unknown with a warning; a member that does not answer is not asked again; a refused platform read leaves the operator unknown" {
	probe_setup
	PROBE_PLATFORM=down platform_probe member-d 2>"$WARN"
	grep -q 'warning: member-d: could not read the platform (so the mesh operator build is not read either); recorded as unknown: error: cannot list the API versions of context member-d' "$WARN"
	grep -q 'warning: member-d: did not answer; its platform record stops here' "$WARN"
	! grep -q '192.0.2.10' "$WARN" || false
	[ "$(wc -l < "$CALLS")" -eq 1 ]
	run platform_preamble_lines member-d
	assert_line "# PLATFORM=unknown"
	assert_line "# MESH_OPERATOR_BY_CONTEXT=member-d=unknown"
	assert_line "# ISTIOD_IMAGE_BY_CONTEXT=member-d=unknown"
	assert_line "# ISTIOD_ENV_BY_CONTEXT=member-d=unknown"
	# Forbidden: the platform and the operator unknown (never absent), the rest read.
	probe_setup
	PROBE_PLATFORM=forbidden platform_probe member-f 2>"$WARN"
	[ "$(platform_member_value member-f platform)" = unknown ]
	[ "$(platform_member_value member-f operator)" = unknown ]
	[ "$(platform_member_value member-f istiod)" = "pilot:1.30.5@${DIG_B}" ]
	[ "$(platform_member_value member-f nodes)" = kind ]
}

@test "platform_probe: a dry-run reads nothing and records unknown; a member never probed warns and reads unknown; values keep only safe characters" {
	probe_setup
	DRY_RUN=1 platform_probe member-a,member-b
	[ ! -s "$CALLS" ]
	run platform_preamble_lines member-a,member-b
	assert_line "# PLATFORM=unknown"
	assert_line "# MESH_OPERATOR_BY_CONTEXT=member-a=unknown,member-b=unknown"
	run --separate-stderr platform_preamble_lines member-x
	assert_line "# PLATFORM_BY_CONTEXT=member-x=unknown"
	[[ "$stderr" == *"member-x: no platform record was read (platform_probe was not called for it); its values read unknown"* ]]
	local v
	_platform_sanitize_to v 'a b,c=d|e'
	[ "$v" = a_b_c_d_e ]
	_platform_sanitize_to v ''
	[ "$v" = unknown ]
	_platform_sanitize_to v 'img:1.0@sha256:ab+x/y'
	[ "$v" = 'img:1.0@sha256:ab+x/y' ]
}

@test "platform_probe_share: a sweep's steps reuse its record file and read only the members it lacks; platform_probe in one shell reads what it is asked" {
	probe_setup
	platform_probe member-a 2>/dev/null
	local d="${BATS_TEST_TMPDIR}/sweep"
	platform_probe_share "$d"
	[ "$PLATFORM_PROBE_FILE" = "${d}/platform-record.txt" ]
	[ "$(cut -f1 "$PLATFORM_PROBE_FILE")" = member-a ]
	# A step: a shell that sources platform.sh with the file (member-a's build edited there, to
	# show it is not read again), with the stub kubectl.
	sed -i 's/pilot:1.30.5/pilot:from-the-sweep/' "$PLATFORM_PROBE_FILE"
	declare -f _probe_kubectl _probe_gw > "${BATS_TEST_TMPDIR}/stub.sh"
	printf 'DIG_A=%s DIG_B=%s DIG_C=%s\nPLATFORM_TUNING_KINDS=%s PLATFORM_TUNING_LABEL=%s\nsource "%s/tests/lib/common.sh"; source "%s/tests/lib/reach.sh"\n' \
		"$DIG_A" "$DIG_B" "$DIG_C" "$PLATFORM_TUNING_KINDS" "$PLATFORM_TUNING_LABEL" "$ROOT" "$ROOT" >> "${BATS_TEST_TMPDIR}/stub.sh"
	: > "$CALLS"
	run bash -c 'unset _PL_ROW _PL_SHARED _PL_MEMBERS; source "$2"; source "$1/tests/lib/platform.sh"; KUBECTL=(_probe_kubectl)
		platform_probe member-a,member-b 2>/dev/null; platform_preamble_lines member-a,member-b' _ "$ROOT" "${BATS_TEST_TMPDIR}/stub.sh"
	assert_success
	assert_line "# ISTIOD_IMAGE_BY_CONTEXT=member-a=pilot:from-the-sweep@${DIG_B},member-b=pilot:1.30.5@${DIG_B}"
	! grep -q -- '--context=member-a' "$CALLS" || false
	[ "$(grep -c -- '--context=member-b' "$CALLS")" -eq 4 ]
	# In one shell, each platform_probe reads its members again (tuning 003 probes each pass).
	: > "$CALLS"
	PROBE_ISTIOD=1.30.6 platform_probe member-a 2>/dev/null
	[ "$(grep -c -- '--context=member-a' "$CALLS")" -eq 4 ]
	[ "$(platform_member_value member-a istiod)" = "pilot:1.30.6@${DIG_B}" ]
	# A dry-run shares nothing.
	DRY_RUN=1 platform_probe_share "${BATS_TEST_TMPDIR}/dry"
	[ ! -e "${BATS_TEST_TMPDIR}/dry/platform-record.txt" ]
}

@test "platform_preamble_lines and platform_md_row: the record's keys in order; a value every member shares shows once, else per member" {
	_platform_put m1 $'kubernetes\top1\tistiod1\tproxy1\tkind\te1'
	_platform_put m2 $'kubernetes\top2\tistiod1\tproxy1\tkind\te1'
	run platform_preamble_lines m1,m2
	assert_output "# PLATFORM=kubernetes
# TEST_PLATFORM=auto
# PLATFORM_BY_CONTEXT=m1=kubernetes,m2=kubernetes
# MESH_OPERATOR_BY_CONTEXT=m1=op1,m2=op2
# ISTIOD_IMAGE_BY_CONTEXT=m1=istiod1,m2=istiod1
# PROXY_IMAGE_BY_CONTEXT=m1=proxy1,m2=proxy1
# NODE_PROVIDER_BY_CONTEXT=m1=kind,m2=kind
# ISTIOD_ENV_BY_CONTEXT=m1=e1,m2=e1"
	run platform_md_row m1,m2
	assert_output "| Platform | kubernetes (TEST_PLATFORM auto); nodes kind; operator m1=op1,m2=op2; istiod istiod1; gateway proxy proxy1; istiod env e1 |"
	# Both platforms: mixed, also beside a member not read; one platform beside it: unknown.
	_platform_put m3 $'openshift\top3\tistiod1\tproxy1\taws\te1'
	_platform_put m4 "$_PL_UNKNOWN"
	run platform_preamble_lines m1,m3,m4
	assert_line "# PLATFORM=mixed"
	run platform_preamble_lines m1,m4
	assert_line "# PLATFORM=unknown"
	TEST_PLATFORM=openshift run platform_md_row m3
	assert_output --partial "| Platform | openshift (TEST_PLATFORM openshift); nodes aws;"
}

# ---------------------------------------------------------------------------
# The reports: platform_report_values and its warnings
# ---------------------------------------------------------------------------

@test "platform_report_values: one value, a member with two values mixed, unknown where not read or recorded; one warning per key that differs, none for inputs from before the record" {
	local d="$BATS_TEST_TMPDIR"
	platform_fixture_lines m1,m2 > "${d}/a.tsv"
	platform_fixture_lines m1,m2 | sed 's/m2=pilot:1.30.5/m2=pilot:1.30.6/; s/m1=kind/m1=unknown/' > "${d}/b.tsv"
	printf '# HARNESS_SHA=x\n' > "${d}/old.tsv"
	run --separate-stderr platform_report_values "${d}/a.tsv" "${d}/b.tsv"
	assert_success
	assert_line "PLATFORM=kubernetes"
	assert_line "ISTIOD_IMAGE_BY_CONTEXT=m1=pilot:1.30.5,m2=mixed:pilot:1.30.5;pilot:1.30.6"
	assert_line "NODE_PROVIDER_BY_CONTEXT=m1=mixed:kind;unknown,m2=kind"
	assert_line "PROXY_IMAGE_BY_CONTEXT=m1=proxyv2:1.30.5,m2=proxyv2:1.30.5"
	[ "${#lines[@]}" -eq "${#PLATFORM_KEYS[@]}" ]
	run platform_report_warnings "${d}/a.tsv" "${d}/b.tsv"
	assert_output "input TSVs disagree on ISTIOD_IMAGE_BY_CONTEXT for m2 (pilot:1.30.5 or pilot:1.30.6): the report mixes runs with different values of it; compare like with like
NODE_PROVIDER_BY_CONTEXT is unknown in some input TSVs (not read for m1), while others have a value: the report cannot tell whether those runs had the same one"
	run platform_report_warnings --no-members --with KUBE_VERSIONS "${d}/a.tsv" "${d}/b.tsv"
	assert_line --index 0 "input TSVs disagree on ISTIOD_IMAGE_BY_CONTEXT for 1 of 2 members: the report mixes runs with different values of it; compare like with like"
	refute_output --partial "m2"
	# Inputs from before the record: unknown, with no warning of their own.
	run --separate-stderr platform_report_values "${d}/old.tsv"
	assert_line "PLATFORM=unknown"
	assert_line "PLATFORM_BY_CONTEXT=unknown"
	[ -z "$stderr" ]
	# Beside a current one: unknown in part.
	run --separate-stderr platform_report_values "${d}/a.tsv" "${d}/old.tsv"
	assert_line "PLATFORM=mixed:kubernetes,unknown"
	assert_line "MESH_OPERATOR_BY_CONTEXT=mixed:unknown,m1=sail-operator:1.31.1,m2=sail-operator:1.31.1"
	[[ "$stderr" == *"PLATFORM is unknown in 1 of 2 input TSV(s) (not read, or written before the record), while others have a value"* ]]
	[[ "$stderr" == *"MESH_OPERATOR_BY_CONTEXT is unknown in some input TSVs (not recorded in 1 of 2 (written before the record had it))"* ]]
	[[ "$stderr" != *"disagree"* ]]
	# Two platforms.
	sed 's/^# PLATFORM=kubernetes/# PLATFORM=openshift/' "${d}/a.tsv" > "${d}/c.tsv"
	run --separate-stderr platform_report_values "${d}/a.tsv" "${d}/c.tsv"
	assert_line "PLATFORM=mixed:kubernetes,openshift"
	[[ "$stderr" == *"input TSVs disagree on PLATFORM (kubernetes,openshift): the report mixes runs on different platforms; compare like with like"* ]]
}

@test "platform_report_lines and platform_warning_lines: every style, a value escaped for yaml and md" {
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
	v=$'PLATFORM=kube"r\\net|es'
	run platform_report_lines yaml "$v"
	assert_output 'platform: "kube\"r\\net|es"'
	run platform_report_lines md "$v"
	assert_output '| PLATFORM | `kube"r\net\|es` |'
	run platform_warning_lines md $'one\ntwo'
	assert_output $'> **Warning:** one\n\n> **Warning:** two'
	run platform_warning_lines text "one"
	assert_output "WARNING: one"
	run platform_warning_lines comment "one"
	assert_output "# WARNING: one"
	run platform_warning_lines json $'one\ntwo'
	assert_output '["one","two"]'
	run platform_warning_lines json ""
	assert_output '[]'
}

# ---------------------------------------------------------------------------
# platform_drift_check: the record read again after a sweep's last step
# ---------------------------------------------------------------------------

@test "platform_drift_check: a build that changed during the sweep is a problem of its outcome; a member not read again is a note; nothing in a dry-run" {
	probe_setup
	platform_probe member-a,member-b 2>/dev/null
	: > "$CALLS"
	platform_drift_check member-a,member-b
	[ "${#_SWEEP_PROBLEMS[@]}" -eq 0 ] && [ "${#_SWEEP_NOTES[@]}" -eq 0 ]
	# Fresh reads, not the record the sweep holds.
	grep -q -- '--context=member-b' "$CALLS"
	PROBE_ISTIOD=1.30.6 PROBE_DOWN_ON=member-b platform_drift_check member-a,member-b "baseline pass" 2>"$WARN"
	[ "${#_SWEEP_PROBLEMS[@]}" -eq 1 ]
	[ "${_SWEEP_PROBLEMS[0]}" = "ISTIOD_IMAGE_BY_CONTEXT on member-a changed during the baseline pass: pilot:1.30.5@sha256:bbbbbbbbbbbb at its start, pilot:1.30.6@sha256:bbbbbbbbbbbb at its end: its rows are not all from one build" ]
	[ "${_SWEEP_NOTES[*]}" = "member-b: PLATFORM_BY_CONTEXT, MESH_OPERATOR_BY_CONTEXT, ISTIOD_IMAGE_BY_CONTEXT, PROXY_IMAGE_BY_CONTEXT, NODE_PROVIDER_BY_CONTEXT, ISTIOD_ENV_BY_CONTEXT not compared between the start and the end of the baseline pass (not read at one of them: unknown); a change there would go unseen" ]
	# istiod's settings too; no platform-drift.txt.
	_SWEEP_PROBLEMS=() _SWEEP_NOTES=()
	PROBE_ISTIOD_THROTTLE=50 platform_drift_check member-a
	[[ "${_SWEEP_PROBLEMS[0]}" == "ISTIOD_ENV_BY_CONTEXT on member-a changed during the sweep: $(env_digest) at its start, $(env_digest 50) at its end:"* ]]
	[ -z "$(find "$BATS_TEST_TMPDIR" -name 'platform-drift*')" ]
	# A dry-run reads nothing; without kubectl it is a note, never a failure.
	_SWEEP_PROBLEMS=() _SWEEP_NOTES=()
	: > "$CALLS"
	DRY_RUN=1 PROBE_ISTIOD=1.30.6 platform_drift_check member-a
	[ ! -s "$CALLS" ] && [ "${#_SWEEP_PROBLEMS[@]}" -eq 0 ] && [ "${#_SWEEP_NOTES[@]}" -eq 0 ]
	KUBECTL=()
	platform_drift_check member-a
	[ "${_SWEEP_NOTES[0]}" = "the platform record was not read again at the end of the sweep (no kubectl, reach.sh or temp dir): a build that changed during it would go unseen" ]
}

# ---------------------------------------------------------------------------
# Tuning profile objects: tuning 001 and 003 refuse, the other sweeps warn
# ---------------------------------------------------------------------------

@test "platform record: the tuning profile label, kinds and marker are the ones tuning.py applies and 005-cleanup.sh deletes" {
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
	# Where the marker is and how it is named: 005 restores each member's Istio CR from it.
	grep -qx "MARKER_NAMESPACE = \"${PLATFORM_TUNING_MARKER_NS}\"" "$py"
	grep -qx "MARKER_PREFIX = \"${PLATFORM_TUNING_MARKER_PREFIX}\"" "$py"
	[ "$PLATFORM_TUNING_KINDS" = "${PLATFORM_TUNING_RESOURCE_KINDS},configmaps" ]
}

@test "platform_tuning_objects: a member's tuning profile objects and marker, <profile>:<Kind>/<ns>/<name> sorted, or none; why on stderr when they cannot be listed" {
	probe_setup
	run platform_tuning_objects member-a
	assert_success
	assert_output none
	grep -q -- "--context=member-a --request-timeout=20s get ${PLATFORM_TUNING_KINDS} -A -l ${PLATFORM_TUNING_LABEL} -o json" "$CALLS"
	PROBE_TUNING_OBJECTS=marker run platform_tuning_objects member-a
	assert_output "02-xds-cache-off:ConfigMap/istio-system/tuning-profile-02-xds-cache-off"
	PROBE_TUNING_OBJECTS=two run platform_tuning_objects member-a
	assert_output "04-connection-pools:DestinationRule/istio-system/tuning-connection-pool+09-x:Sidecar/ns-b/tuning-x"
	PROBE_TUNING_OBJECTS=timeout run --separate-stderr platform_tuning_objects member-a
	assert_failure
	assert_output ""
	[[ "$stderr" == "Unable to connect to the server: net/http: request canceled (Client.Timeout exceeded while awaiting headers); no answer within PLATFORM_READ_TIMEOUT (20s): raise it"* ]] || { echo "$stderr"; false; }
}

@test "platform_tuning_objects_refuse: tuning 001 and 003 stop over a member's profile objects or marker, or a member whose cannot be listed, before they change anything; nothing in a dry-run" {
	probe_setup
	platform_tuning_objects_refuse member-a,member-b "this profile"
	[ "$(grep -c -- " get ${PLATFORM_TUNING_KINDS} -A " "$CALLS")" -eq 2 ]
	PROBE_TUNING_ON=member-b PROBE_TUNING_OBJECTS=marker run platform_tuning_objects_refuse member-a,member-b "every pass of this sweep (the baseline included)"
	assert_failure
	assert_output --partial "a tuning profile's objects (label istio-scale-tests/tuning-profile) are on member-b already: 02-xds-cache-off:ConfigMap/istio-system/tuning-profile-02-xds-cache-off. Every pass of this sweep (the baseline included) would be measured with them."
	assert_output --partial "undo those with ./tests/tuning/005-cleanup.sh --contexts member-a,member-b (add --results-dir <that run's --output-dir> if it had one, and --gitops-context <hub> to resume Argo CD if it paused it), which also restores each member's Istio CR from the profile's marker, then start again"
	PROBE_TUNING_ON=member-b PROBE_TUNING_OBJECTS=timeout run platform_tuning_objects_refuse member-a,member-b "this profile"
	assert_failure
	assert_output --partial "the tuning profile objects (label istio-scale-tests/tuning-profile) could not be listed on member-b (Unable to connect to the server"
	assert_output --partial "): a member that cannot be asked may hold a profile's objects, and this profile would be measured with them; fix the access (or raise PLATFORM_READ_TIMEOUT) and start again"
	: > "$CALLS"
	DRY_RUN=1 PROBE_TUNING_OBJECTS=marker platform_tuning_objects_refuse member-a "this profile"
	[ ! -s "$CALLS" ]
	grep -q '^platform_tuning_objects_refuse "$CONTEXTS_CSV" "this profile"$' "${ROOT}/tests/tuning/001-apply-profile.sh"
	grep -q '^platform_tuning_objects_refuse "$CONTEXTS_CSV" "every pass of this sweep (the baseline included)"$' "${ROOT}/tests/tuning/003-run-tuning-sweep.sh"
	[ "$(grep -n '^platform_tuning_objects_refuse' "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" | cut -d: -f1)" -lt \
		"$(grep -n '^sweep_start ' "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" | cut -d: -f1)" ]
	[ "$(grep -n '^platform_tuning_objects_refuse' "${ROOT}/tests/tuning/001-apply-profile.sh" | cut -d: -f1)" -lt \
		"$(grep -n '^mkdir -p "$STATE_DIR"' "${ROOT}/tests/tuning/001-apply-profile.sh" | cut -d: -f1)" ]
}

@test "platform_start_warnings: the other sweeps warn as they start, and note it in their outcome, when a member holds a profile's objects or cannot be asked; silent otherwise and in a dry-run" {
	probe_setup
	PROBE_TUNING_ON=member-b PROBE_TUNING_OBJECTS=marker run --separate-stderr platform_start_warnings member-a,member-b
	assert_success
	[[ "$stderr" == "warning: a tuning profile's objects (label istio-scale-tests/tuning-profile) are on member-b: 02-xds-cache-off:ConfigMap/istio-system/tuning-profile-02-xds-cache-off; this sweep would measure that profile's configuration, not the charts'. Unless that is the point, stop it now (Ctrl-C); then, unless a tuning run is still in progress on these members (wait for it to end), undo them with ./tests/tuning/005-cleanup.sh --contexts member-a,member-b"* ]] || { echo "$stderr"; false; }
	PROBE_TUNING_ON=member-b PROBE_TUNING_OBJECTS=marker platform_start_warnings member-a,member-b 2>/dev/null
	[ "${_SWEEP_NOTES[0]}" = "a tuning profile's objects were on member-b at the sweep's start (02-xds-cache-off:ConfigMap/istio-system/tuning-profile-02-xds-cache-off): its results measure that profile's configuration, not the charts'" ]
	_SWEEP_NOTES=()
	PROBE_TUNING_OBJECTS=timeout platform_start_warnings member-a 2>"$WARN"
	grep -q '^warning: the tuning profile objects (label istio-scale-tests/tuning-profile) could not be listed on member-a (Unable to connect' "$WARN"
	[ "${_SWEEP_NOTES[0]}" = "the tuning profile objects could not be listed on member-a at the sweep's start: a profile left applied there would go unseen" ]
	_SWEEP_NOTES=()
	run --separate-stderr platform_start_warnings member-a
	[ -z "$stderr" ]
	: > "$CALLS"
	DRY_RUN=1 PROBE_TUNING_OBJECTS=marker run --separate-stderr platform_start_warnings member-a
	[ -z "$stderr" ] && [ ! -s "$CALLS" ]
}

# ---------------------------------------------------------------------------
# The envelope's and the dataplane reports' helpers
# ---------------------------------------------------------------------------

@test "platform_kind_path_warning, platform_summary: the remote-path warning only where a member's nodes may be kind's; values without member names, digests shortened" {
	run platform_kind_path_warning "a=aws,b=mixed:aws;kind" "remote latency is not a cloud load balancer's"
	assert_output "Nodes on kind (NODE_PROVIDER_BY_CONTEXT): the cross-cluster path runs through cloud-provider-kind's userspace Envoy (the east-west gateway's LoadBalancer, ipMode: Proxy) on the host all kind clusters share, so remote latency is not a cloud load balancer's"
	run platform_kind_path_warning "a=aws,b=gce" "x"
	assert_success
	assert_output ""
	run platform_kind_path_warning "a=aws,b=mixed:aws;unknown" "x"
	assert_output --partial "Node provider not read on 1 member(s) (NODE_PROVIDER_BY_CONTEXT unknown): if their nodes are kind's"
	run platform_summary "a=pilot:1.30.5@${DIG_B},b=pilot:1.30.5@${DIG_B}"
	assert_output "pilot:1.30.5@sha256:bbbbbbbbbbbb"
	run platform_summary "a=x,b=y,c=x"
	assert_output "x (2 members), y (1 member)"
	run platform_summary "mixed:unknown,a=mixed:x;y"
	assert_output "mixed:unknown, mixed: x and y (1 member)"
	run platform_summary ""
	assert_output unknown
}

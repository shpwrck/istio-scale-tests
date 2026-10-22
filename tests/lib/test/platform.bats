#!/usr/bin/env bats
# tests/lib/platform.sh: platform_of and the suite charts' OpenShift overlay (platform_chart_args,
# the charts' two renders, the 001 setup scripts' dry-runs: PL33), platform_validate, and the
# platform record: platform_probe over a stub kubectl, the writers, the reports' merge, the drift
# check, the tuning profile objects (and tuning 001 and 003 refusing over them), the kind path
# warning.
# No cluster: the stub kubectl answers from the test, and the entrypoint runs use an empty
# kubeconfig.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/platform.sh"
source "${ROOT}/tests/lib/reach.sh"  # reach_sanitize (platform_probe's warnings)

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

@test "platform_of: auto asks the member once (security.openshift.io/v1 is OpenShift, lookalikes are not), an explicit one asks nothing; a member it cannot ask is an error naming it, never a guess; a bad TEST_PLATFORM fails before any call" {
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
	FAKE_PLATFORM=down run --separate-stderr platform_of member-b
	assert_failure 1
	[ -z "$output" ]
	[[ "$stderr" == *"cannot list the API versions of context member-b"* ]]
	[[ "$stderr" == *"set TEST_PLATFORM to skip the check"* && "$stderr" == *"i/o timeout"* ]]
	FAKE_PLATFORM=down run platform_gitops_namespace hub
	assert_failure
	: > "$CALLS"
	TEST_PLATFORM=OpenShift run --separate-stderr platform_of member-a
	assert_failure 1
	[[ "$stderr" == *"TEST_PLATFORM must be auto, kubernetes or openshift (got: OpenShift)"* ]]
	[ ! -s "$CALLS" ]
}

@test "platform_chart_args: the overlay on OpenShift, nothing on Kubernetes; a dry-run with auto asks no cluster, an explicit platform still renders; an unreachable member fails with the array empty; an OpenShift member and a chart without the overlay is an error" {
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
	a=(stale)
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

# stub_bin: a helm on PATH that logs its args, then runs the real one, and a kubectl that logs
# its args and answers nothing (the dry-runs' kubectl apply --dry-run=client).
stub_bin() {
	local real
	real="$(command -v helm)"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export HELM_LOG="${BATS_TEST_TMPDIR}/helm.log" KUBECTL_LOG="${BATS_TEST_TMPDIR}/kubectl.log"
	: > "$HELM_LOG"
	printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$HELM_LOG"' "exec \"${real}\" \"\$@\"" > "${BIN}/helm"
	printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$KUBECTL_LOG"' 'cat > /dev/null' > "${BIN}/kubectl"
	chmod +x "${BIN}/helm" "${BIN}/kubectl"
}

@test "001 setup scripts, --dry-run: with TEST_PLATFORM=openshift every chart render takes the suite's values-openshift.yaml, without it none does" {
	command -v helm >/dev/null 2>&1 || skip "helm not installed"
	local ek="${BATS_TEST_TMPDIR}/kubeconfig" s f n_t n_o
	local -a args
	: > "$ek"
	stub_bin
	for s in "${SUITES[@]}"; do
		f="$(ls "${ROOT}/tests/${s}"/001-*.sh)"
		case "$s" in
		dataplane) args=(--source-context ci-a --remote-contexts ci-b) ;;
		churn-dataplane) args=(--source-context ci-a) ;;
		*) args=(--contexts ci-a) ;;
		esac
		: > "$HELM_LOG"
		PATH="${BIN}:${PATH}" KUBECONFIG="$ek" TEST_PLATFORM=openshift run bash "$f" --dry-run "${args[@]}"
		assert_success
		n_t="$(grep -c '^template ' "$HELM_LOG")"
		n_o="$(grep -c "^template .* -f ${ROOT}/tests/${s}/chart/values-openshift.yaml" "$HELM_LOG")"
		((n_t > 0 && n_o == n_t)) || { echo "${s}: ${n_t} render(s), ${n_o} with the overlay"; cat "$HELM_LOG"; false; }
		: > "$HELM_LOG"
		PATH="${BIN}:${PATH}" KUBECONFIG="$ek" run bash "$f" --dry-run "${args[@]}"
		assert_success
		grep -q '^template ' "$HELM_LOG" || { echo "${s}: no render"; false; }
		! grep -q 'values-openshift.yaml' "$HELM_LOG" || { echo "${s}: overlay without TEST_PLATFORM=openshift"; false; }
	done
}

@test "platform_validate: TEST_PLATFORM, PLATFORM_READ_TIMEOUT and PLATFORM_READ_PARALLEL refused when not valid; every suite's --config sets them" {
	local v f="${BATS_TEST_TMPDIR}/platform.env" want="" s
	for v in auto kubernetes openshift ""; do TEST_PLATFORM="$v" run platform_validate; assert_success; done
	TEST_PLATFORM=k8s run platform_validate
	assert_failure
	assert_output --partial "TEST_PLATFORM must be auto, kubernetes or openshift (got: k8s)"
	for v in 20s 1m 30 500ms 1m30s 1.5m; do PLATFORM_READ_TIMEOUT="$v" run platform_validate; assert_success; done
	for v in 0 0s 0.0m abc -5s "20 s"; do
		PLATFORM_READ_TIMEOUT="$v" run platform_validate
		assert_failure
		assert_output --partial "PLATFORM_READ_TIMEOUT must be a kubectl --request-timeout above zero"
		assert_output --partial "(got: ${v})"
	done
	for v in 1 20 500; do PLATFORM_READ_PARALLEL="$v" run platform_validate; assert_success; done
	for v in 0 -1 abc 2.5 03; do
		PLATFORM_READ_PARALLEL="$v" run platform_validate
		assert_failure
		assert_output --partial "PLATFORM_READ_PARALLEL must be a whole number above zero"
		assert_output --partial "(got: ${v})"
	done
	# In a child bash: the key lists' loops are slow under the bats DEBUG trap.
	printf '%s\n' TEST_PLATFORM=openshift PLATFORM_READ_TIMEOUT=45s PLATFORM_READ_PARALLEL=7 > "$f"
	set -- propagation churn churn-dataplane controlplane dataplane gateway-api
	run --separate-stderr bash -c 'source "$1/tests/lib/common.sh"; ROOT="$1"; source "$1/tests/lib/config.sh"; f="$2"; shift 2
		for s in "$@"; do (load_config "$f" "$s" > /dev/null && echo "$s $TEST_PLATFORM $PLATFORM_READ_TIMEOUT $PLATFORM_READ_PARALLEL"); done' _ "$ROOT" "$f" "$@"
	assert_success
	for s in "$@"; do want+="${s} openshift 45s 7"$'\n'; done
	assert_output "${want%$'\n'}"
}

@test "platform_members_check: a member listed twice, or two the record writes under one name, dies before any read, in a dry-run too" {
	KUBECTL=(_probe_kubectl)
	run platform_probe member-a,member-b,member-a
	assert_failure
	assert_output --partial "member-a is listed twice among the mesh members: list each member once"
	DRY_RUN=1 run platform_members_check "lab~a" lab_a
	assert_failure
	assert_output --partial "lab~a and lab_a would be recorded under one name, lab_a"
	assert_output --partial "rename one of the two contexts"
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

@test "platform_probe: what each member ran, its builds (tag and digest, no registry), its operator (the Sail operator, OSSM's CSV on OpenShift), node provider and istiod's env without CLUSTER_ID; every read bounded; each call reads again" {
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
	# Every read is bounded by PLATFORM_READ_TIMEOUT.
	[ -s "$CALLS" ]
	run grep -v -- '--request-timeout=45s ' "$CALLS"
	assert_failure 1
	# Another setting, a rollout of another gateway build, a pod that has not started.
	probe_setup
	PROBE_ISTIOD_THROTTLE=50 PROBE_EWGW=other PROBE_ISTIOD_PODS=pending platform_probe member-c 2>"$WARN"
	[ "$(platform_member_value member-c istiod_env)" = "$(env_digest 50)" ]
	[ "$(platform_member_value member-c proxy)" = "proxyv2:1.30.5@${DIG_C}+proxyv2:1.30.6@${DIG_A}" ]
	[ "$(platform_member_value member-c istiod)" = "pilot:1.30.5@unknown" ]
	# OpenShift: the OSSM CSV's version (the Sail operator not read), the cloud provider (a node
	# without one left out).
	probe_setup
	: > "$CALLS"
	PROBE_PLATFORM=openshift platform_probe member-o 2>"$WARN"
	[ ! -s "$WARN" ] || { cat "$WARN"; false; }
	run platform_preamble_lines member-o
	assert_line "# PLATFORM=openshift"
	assert_line "# MESH_OPERATOR_BY_CONTEXT=member-o=servicemeshoperator3:3.4.3"
	assert_line "# NODE_PROVIDER_BY_CONTEXT=member-o=aws"
	! grep -q 'sail-operator' "$CALLS" || false
	# In one shell, each platform_probe reads its members again (tuning 003 probes each pass).
	: > "$CALLS"
	PROBE_ISTIOD=1.30.6 platform_probe member-a 2>/dev/null
	grep -q -- '--context=member-a' "$CALLS"
	[ "$(platform_member_value member-a istiod)" = "pilot:1.30.6@${DIG_B}" ]
}

# A step that sources platform.sh with PLATFORM_PROBE_FILE records what the sweep read at its
# start, each value under its own member; the drift check then compares the end with that.
@test "platform_probe_share: a sweep's steps take its record for the members it read (each value under its member) and read only the members it lacks; a dry-run shares nothing" {
	probe_setup
	platform_probe member-a 2>/dev/null
	local d="${BATS_TEST_TMPDIR}/sweep" f
	platform_probe_share "$d"
	f="$PLATFORM_PROBE_FILE"
	[ "$f" = "${d}/platform-record.txt" ]
	# member-a's build edited in the file, to show the step does not read member-a again.
	sed 's/pilot:1\.30\.5/pilot:from-the-sweep/' "$f" > "${f}.new"
	mv "${f}.new" "$f"
	# The step: a shell that sources platform.sh with the file, over the same stub kubectl.
	declare -f _probe_kubectl _probe_gw > "${BATS_TEST_TMPDIR}/stub.sh"
	printf 'DIG_A=%s DIG_B=%s DIG_C=%s\nPLATFORM_TUNING_KINDS=%s PLATFORM_TUNING_LABEL=%s\nsource "%s/tests/lib/common.sh"; source "%s/tests/lib/reach.sh"\n' \
		"$DIG_A" "$DIG_B" "$DIG_C" "$PLATFORM_TUNING_KINDS" "$PLATFORM_TUNING_LABEL" "$ROOT" "$ROOT" >> "${BATS_TEST_TMPDIR}/stub.sh"
	: > "$CALLS"
	run bash -c 'unset _PL_ROW _PL_SHARED _PL_MEMBERS; source "$2"; source "$1/tests/lib/platform.sh"; KUBECTL=(_probe_kubectl)
		platform_probe member-a,member-b 2>/dev/null; platform_preamble_lines member-a,member-b' _ "$ROOT" "${BATS_TEST_TMPDIR}/stub.sh"
	assert_success
	assert_line "# ISTIOD_IMAGE_BY_CONTEXT=member-a=pilot:from-the-sweep@${DIG_B},member-b=pilot:1.30.5@${DIG_B}"
	assert_line "# MESH_OPERATOR_BY_CONTEXT=member-a=sail-operator:1.31.1@${DIG_A},member-b=sail-operator:1.31.1@${DIG_A}"
	assert_line "# NODE_PROVIDER_BY_CONTEXT=member-a=kind,member-b=kind"
	! grep -q -- '--context=member-a' "$CALLS" || false
	grep -q -- '--context=member-b' "$CALLS"
	DRY_RUN=1 platform_probe_share "${BATS_TEST_TMPDIR}/dry"
	[ ! -e "${BATS_TEST_TMPDIR}/dry/platform-record.txt" ]
}

@test "platform_probe: a value not read is unknown, never a guess (a member down or forbidden, a dry-run, a member never probed), with a warning; a member that does not answer is not asked again; values keep only safe characters" {
	probe_setup
	PROBE_PLATFORM=down platform_probe member-d 2>"$WARN"
	grep -q 'warning: member-d: could not read the platform .*recorded as unknown: error: cannot list the API versions of context member-d' "$WARN"
	grep -q 'warning: member-d: did not answer' "$WARN"
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
	probe_setup
	: > "$CALLS"
	DRY_RUN=1 platform_probe member-a,member-b
	[ ! -s "$CALLS" ]
	run platform_preamble_lines member-a,member-b
	assert_line "# PLATFORM=unknown"
	assert_line "# MESH_OPERATOR_BY_CONTEXT=member-a=unknown,member-b=unknown"
	run --separate-stderr platform_preamble_lines member-x
	assert_line "# PLATFORM_BY_CONTEXT=member-x=unknown"
	[[ "$stderr" == *"member-x: no platform record was read"*"its values read unknown"* ]]
	local v
	_platform_sanitize_to v 'a b,c=d|e'
	[ "$v" = a_b_c_d_e ]
	_platform_sanitize_to v ''
	[ "$v" = unknown ]
	_platform_sanitize_to v 'img:1.0@sha256:ab+x/y'
	[ "$v" = 'img:1.0@sha256:ab+x/y' ]
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
	[ "${#lines[@]}" -eq 2 ]
	assert_line --index 0 --partial "input TSVs disagree on ISTIOD_IMAGE_BY_CONTEXT for m2 (pilot:1.30.5 or pilot:1.30.6)"
	assert_line --index 1 --partial "NODE_PROVIDER_BY_CONTEXT is unknown in some input TSVs (not read for m1), while others have a value"
	run platform_report_warnings --no-members --with KUBE_VERSIONS "${d}/a.tsv" "${d}/b.tsv"
	assert_line --index 0 --partial "input TSVs disagree on ISTIOD_IMAGE_BY_CONTEXT for 1 of 2 members"
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
	[[ "$stderr" == *"PLATFORM is unknown in 1 of 2 input TSV(s)"* ]]
	[[ "$stderr" == *"MESH_OPERATOR_BY_CONTEXT is unknown in some input TSVs (not recorded in 1 of 2"* ]]
	[[ "$stderr" != *"disagree"* ]]
	# Two platforms.
	sed 's/^# PLATFORM=kubernetes/# PLATFORM=openshift/' "${d}/a.tsv" > "${d}/c.tsv"
	run --separate-stderr platform_report_values "${d}/a.tsv" "${d}/c.tsv"
	assert_line "PLATFORM=mixed:kubernetes,openshift"
	[[ "$stderr" == *"input TSVs disagree on PLATFORM (kubernetes,openshift)"* ]]
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

@test "platform_drift_check: a build or istiod setting that changed during the sweep is a problem of its outcome; a member not read again is a note; nothing in a dry-run" {
	probe_setup
	platform_probe member-a,member-b 2>/dev/null
	: > "$CALLS"
	platform_drift_check member-a,member-b
	[ "${#_SWEEP_PROBLEMS[@]}" -eq 0 ]
	[ "${#_SWEEP_NOTES[@]}" -eq 0 ]
	# Fresh reads, not the record the sweep holds.
	grep -q -- '--context=member-b' "$CALLS"
	PROBE_ISTIOD=1.30.6 PROBE_DOWN_ON=member-b platform_drift_check member-a,member-b "baseline pass" 2>"$WARN"
	[ "${#_SWEEP_PROBLEMS[@]}" -eq 1 ]
	[[ "${_SWEEP_PROBLEMS[0]}" == "ISTIOD_IMAGE_BY_CONTEXT on member-a changed during the baseline pass: pilot:1.30.5@sha256:bbbbbbbbbbbb at its start, pilot:1.30.6@sha256:bbbbbbbbbbbb at its end"* ]]
	[ "${#_SWEEP_NOTES[@]}" -eq 1 ]
	[[ "${_SWEEP_NOTES[0]}" == "member-b: PLATFORM_BY_CONTEXT, MESH_OPERATOR_BY_CONTEXT, ISTIOD_IMAGE_BY_CONTEXT, PROXY_IMAGE_BY_CONTEXT, NODE_PROVIDER_BY_CONTEXT, ISTIOD_ENV_BY_CONTEXT not compared between the start and the end of the baseline pass"* ]]
	_SWEEP_PROBLEMS=() _SWEEP_NOTES=()
	PROBE_ISTIOD_THROTTLE=50 platform_drift_check member-a
	[[ "${_SWEEP_PROBLEMS[0]}" == "ISTIOD_ENV_BY_CONTEXT on member-a changed during the sweep: $(env_digest) at its start, $(env_digest 50) at its end"* ]]
	# A dry-run reads nothing; without kubectl it is a note, never a failure.
	_SWEEP_PROBLEMS=() _SWEEP_NOTES=()
	: > "$CALLS"
	DRY_RUN=1 PROBE_ISTIOD=1.30.6 platform_drift_check member-a
	[ ! -s "$CALLS" ]
	[ "${#_SWEEP_PROBLEMS[@]}" -eq 0 ]
	[ "${#_SWEEP_NOTES[@]}" -eq 0 ]
	KUBECTL=()
	platform_drift_check member-a
	[[ "${_SWEEP_NOTES[0]}" == "the platform record was not read again at the end of the sweep"* ]]
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

@test "tuning profile objects: listed per member (<profile>:<Kind>/<ns>/<name> sorted, or none, why on stderr when they cannot be); tuning 001 and 003 refuse before they change anything; the other sweeps warn and note it in their outcome; nothing in a dry-run" {
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
	[[ "$stderr" == "Unable to connect to the server"*"no answer within PLATFORM_READ_TIMEOUT (20s): raise it"* ]] || { echo "$stderr"; false; }
	# The refusal (tuning 001 and 003): the objects, and the cleanup that undoes them.
	: > "$CALLS"
	platform_tuning_objects_refuse member-a,member-b "this profile"
	[ "$(grep -c -- " get ${PLATFORM_TUNING_KINDS} -A " "$CALLS")" -eq 2 ]
	PROBE_TUNING_ON=member-b PROBE_TUNING_OBJECTS=marker run platform_tuning_objects_refuse member-a,member-b "this profile"
	assert_failure
	assert_output --partial "are on member-b already: 02-xds-cache-off:ConfigMap/istio-system/tuning-profile-02-xds-cache-off. This profile would be measured with them."
	assert_output --partial "./tests/tuning/005-cleanup.sh --contexts member-a,member-b"
	PROBE_TUNING_ON=member-b PROBE_TUNING_OBJECTS=timeout run platform_tuning_objects_refuse member-a,member-b "this profile"
	assert_failure
	assert_output --partial "could not be listed on member-b (Unable to connect to the server"
	assert_output --partial "raise PLATFORM_READ_TIMEOUT"
	: > "$CALLS"
	DRY_RUN=1 PROBE_TUNING_OBJECTS=marker platform_tuning_objects_refuse member-a "this profile"
	[ ! -s "$CALLS" ]
	# The other sweeps: a warning as they start and a note in their outcome.
	PROBE_TUNING_ON=member-b PROBE_TUNING_OBJECTS=marker run --separate-stderr platform_start_warnings member-a,member-b
	assert_success
	[[ "$stderr" == "warning: a tuning profile's objects (label istio-scale-tests/tuning-profile) are on member-b: 02-xds-cache-off:ConfigMap/istio-system/tuning-profile-02-xds-cache-off;"*"005-cleanup.sh --contexts member-a,member-b"* ]] || { echo "$stderr"; false; }
	PROBE_TUNING_ON=member-b PROBE_TUNING_OBJECTS=marker platform_start_warnings member-a,member-b 2>/dev/null
	[[ "${_SWEEP_NOTES[0]}" == "a tuning profile's objects were on member-b at the sweep's start (02-xds-cache-off:ConfigMap/istio-system/tuning-profile-02-xds-cache-off)"* ]]
	_SWEEP_NOTES=()
	PROBE_TUNING_OBJECTS=timeout platform_start_warnings member-a 2>"$WARN"
	grep -q '^warning: the tuning profile objects (label istio-scale-tests/tuning-profile) could not be listed on member-a' "$WARN"
	[[ "${_SWEEP_NOTES[0]}" == "the tuning profile objects could not be listed on member-a at the sweep's start"* ]]
	_SWEEP_NOTES=()
	run --separate-stderr platform_start_warnings member-a
	[ -z "$stderr" ]
	: > "$CALLS"
	DRY_RUN=1 PROBE_TUNING_OBJECTS=marker run --separate-stderr platform_start_warnings member-a
	[ -z "$stderr" ]
	[ ! -s "$CALLS" ]
}

@test "tuning 001 and 003 entrypoints: a member holding a profile's marker stops them before any change (no state dir, no sweep dir, only the two lists)" {
	python3 -I -c 'import yaml' 2>/dev/null || skip "python3 with PyYAML not installed"
	local bin="${BATS_TEST_TMPDIR}/bin" log="${BATS_TEST_TMPDIR}/kubectl.log" ek="${BATS_TEST_TMPDIR}/kubeconfig"
	mkdir -p "$bin"
	: > "$ek"
	# ci-b holds profile 02's marker; every other read fails.
	cat > "${bin}/kubectl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${log}"
case " \$* " in
*" --context=ci-b "*" get ${PLATFORM_TUNING_KINDS} -A -l ${PLATFORM_TUNING_LABEL} "*)
	echo '{"kind":"List","items":[{"kind":"ConfigMap","metadata":{"name":"tuning-profile-02-xds-cache-off","namespace":"istio-system","labels":{"istio-scale-tests/tuning-profile":"02-xds-cache-off"}}}]}' ;;
*" get ${PLATFORM_TUNING_KINDS} -A -l ${PLATFORM_TUNING_LABEL} "*) echo '{"kind":"List","items":[]}' ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${bin}/kubectl"
	: > "$log"
	PATH="${bin}:${PATH}" KUBECONFIG="$ek" run --separate-stderr "${ROOT}/tests/tuning/001-apply-profile.sh" \
		--profile 01-push-throttling --contexts ci-a,ci-b --state-dir "${BATS_TEST_TMPDIR}/state"
	assert_failure
	[[ "$stderr" == *"are on ci-b already: 02-xds-cache-off:ConfigMap/istio-system/tuning-profile-02-xds-cache-off. This profile would be measured with them."* ]]
	[ ! -e "${BATS_TEST_TMPDIR}/state" ]
	[ "$(grep -vc -- " get ${PLATFORM_TUNING_KINDS} -A " "$log")" -eq 0 ]
	[ "$(wc -l < "$log")" -eq 2 ]
	: > "$log"
	PATH="${bin}:${PATH}" KUBECONFIG="$ek" run --separate-stderr "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" \
		--suite churn --contexts ci-a,ci-b --no-gitops-pause --profiles 01-push-throttling --output-dir "${BATS_TEST_TMPDIR}/out"
	assert_failure
	[[ "$stderr" == *"are on ci-b already: 02-xds-cache-off:ConfigMap/istio-system/tuning-profile-02-xds-cache-off. Every pass of this sweep (the baseline included) would be measured with them."* ]]
	[ -z "$(ls -A "${BATS_TEST_TMPDIR}/out" 2>/dev/null)" ]
	[ "$(grep -vc -- " get ${PLATFORM_TUNING_KINDS} -A " "$log")" -eq 0 ]
	[ "$(wc -l < "$log")" -eq 2 ]
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

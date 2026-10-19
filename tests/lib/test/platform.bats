#!/usr/bin/env bats
# tests/lib/platform.sh (the member platform and the suite charts' OpenShift overlay):
# platform_of over a fake kubectl (an OpenShift and a Kubernetes API version list,
# lookalike groups, an unreachable member), the TEST_PLATFORM override and its check,
# platform_chart_args (the overlay on OpenShift only, the offline dry-run, a chart without
# an overlay), the suite charts' two renders, and the 001 setup scripts that call it (PL33).
# No cluster: the fake kubectl answers from the test, and the entrypoint runs use an empty
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

# _probe_kubectl: one member for platform_probe; PROBE_PLATFORM picks it: kubernetes (default),
# openshift, down (no answer) or forbidden (api-versions refused, the rest answers). PROBE_SAIL
# empty: nothing in the Sail namespace; PROBE_CSV other: no servicemeshoperator3 CSV. PROBE_EWGW:
# the east-west gateway pod runs the ingress gateway's build (same, default), another one
# (other) or is not there (none); an egress gateway pod never counts. PROBE_ISTIOD and
# PROBE_OPERATOR replace istiod's and the Sail operator's tag. tuning_baseline_state's reads:
# PROBE_TB_SIDECAR on (default) or off, PROBE_TB_DS off (default) or on, PROBE_TB_HOSTS (the
# root Sidecar's egress hosts, default "istio-system/* ./*").
_probe_kubectl() {
	printf '%s\n' "$*" >> "$CALLS"
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
		cat <<JSON
{"kind":"List","items":[
 {"kind":"Deployment","metadata":{"name":"sail-operator"},
  "spec":{"selector":{"matchLabels":{"app.kubernetes.io/name":"sail-operator"}},
   "template":{"spec":{"containers":[{"name":"sail-operator","image":"registry.example.invalid/sail/sail-operator:${PROBE_OPERATOR:-1.31.1}"}]}}},
  "status":{"availableReplicas":${PROBE_SAIL_AVAILABLE:-1}}},
 {"kind":"Pod","metadata":{"name":"sail-operator-1","labels":{"app.kubernetes.io/name":"sail-operator"}},
  "status":{"containerStatuses":[{"name":"sail-operator","imageID":"registry.example.invalid/sail/sail-operator@${DIG_A}"}]}},
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
		cat <<JSON
{"kind":"List","items":[
 {"metadata":{"name":"istiod-1","labels":{"app":"istiod"}},
  "spec":{"containers":[{"name":"discovery","image":"registry.example.invalid/istio/pilot:${PROBE_ISTIOD:-1.30.5}"}]},
  "status":{"phase":"Running","containerStatuses":[{"name":"discovery","imageID":"registry.example.invalid/istio/pilot@${DIG_B}","restartCount":0}]}},
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
		esac
		echo ']}'
		;;
	*" -n istio-system get sidecar.networking.istio.io default -o name "*)
		[[ "${PROBE_TB_SIDECAR:-on}" != on ]] || echo sidecar.networking.istio.io/default
		;;
	*" -n istio-system get sidecar.networking.istio.io default -o jsonpath="*) echo "${PROBE_TB_HOSTS:-istio-system/* ./*}" ;;
	*" -n istio-system get telemetry.telemetry.istio.io "*) ;;
	*" get istio.sailoperator.io default "*)
		if [[ "${PROBE_TB_DS:-off}" == on ]]; then echo '[{"matchLabels":{"istio-discovery":"enabled"}}]'; else echo '[]'; fi
		;;
	*" get nodes "*)
		if [[ "${PROBE_PLATFORM:-}" == openshift ]]; then
			echo '{"items":[{"spec":{"providerID":"aws:///zone-a/i-0"}},{"spec":{"providerID":"aws:///zone-b/i-1"}}]}'
		else
			echo '{"items":[{"spec":{"providerID":"kind://docker/lab/node-0"}}]}'
		fi
		;;
	*) return 1 ;;
	esac
}

# probe_setup: a fresh record over _probe_kubectl; warnings go to $WARN.
probe_setup() {
	KUBECTL=(_probe_kubectl)
	unset PLATFORM_PROBE_ROWS PROBE_PLATFORM PROBE_SAIL PROBE_CSV
	WARN="${BATS_TEST_TMPDIR}/warn"
	: > "$WARN"
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
	refute_output --partial "example.invalid"
	! grep -q 'clusterserviceversions' "$CALLS" || false
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

@test "platform_probe: an inherited record is reused and only new members are read; save and load keep it" {
	probe_setup
	PLATFORM_PROBE_ROWS=$'member-a\tkubernetes\tsail-operator:1.31.0/Available\tpilot:1.30.4\tproxyv2:1.30.4\tkind\n'
	export PLATFORM_PROBE_ROWS
	platform_probe member-a,member-b 2>"$WARN"
	! grep -q -- '--context=member-a' "$CALLS" || false
	grep -q -- '--context=member-b' "$CALLS"
	[ "$(platform_member_value member-a istiod)" = pilot:1.30.4 ]
	[ "$(platform_member_value member-b istiod)" = "pilot:1.30.5@${DIG_B}" ]
	[ "$(platform_probed_contexts)" = member-a,member-b ]
	platform_probe_save "${BATS_TEST_TMPDIR}/record.tsv"
	# A later phase: the saved record fills in; a row it already has wins.
	PLATFORM_PROBE_ROWS=$'member-b\topenshift\tx\ty\tz\taws\n'
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
	PLATFORM_PROBE_ROWS=$'m1\tkubernetes\top1\tistiod1\tproxy1\tkind\nm2\tkubernetes\top2\tistiod1\tproxy1\tkind\n'
	run platform_md_row m1,m2
	assert_output "| Platform | kubernetes (TEST_PLATFORM auto); nodes kind; operator m1=op1,m2=op2; istiod istiod1; gateway proxy proxy1 |"
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

@test "platform_report_lines: every style, and platform_value_has finds kind in a mixed value" {
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
	PLATFORM_PROBE_ROWS=$'member-a\tunknown\tunknown\tunknown\tunknown\tunknown\nmember-b\tkubernetes\tsail-operator:1.31.0/Available\tpilot:1.30.4\tproxyv2:1.30.4\tkind\n'
	export PLATFORM_PROBE_ROWS
	platform_probe member-a,member-b 2>"$WARN"
	grep -q -- '--context=member-a' "$CALLS"
	! grep -q -- '--context=member-b' "$CALLS" || false
	grep -q 'Platform record: reading again member-a (an unknown value in the record this step inherited)' "$WARN"
	[ "$(platform_member_value member-a platform)" = kubernetes ]
	[ "$(platform_member_value member-a istiod)" = "pilot:1.30.5@${DIG_B}" ]
	[ "$(platform_member_value member-b istiod)" = pilot:1.30.4 ]
	[ "$(platform_recorded_contexts)" = member-a,member-b ]
	# A read that gets less than the inherited row: the inherited values stay, each with a note.
	PLATFORM_PROBE_ROWS=$'member-c\tkubernetes\tunknown\tpilot:1.30.4\tproxyv2:1.30.4\tkind\n'
	: > "$CALLS"
	PROBE_PLATFORM=down platform_probe member-c 2>"$WARN"
	grep -q -- '--context=member-c' "$CALLS"
	[ "$(platform_member_value member-c platform)" = kubernetes ]
	[ "$(platform_member_value member-c operator)" = unknown ]
	[ "$(platform_member_value member-c istiod)" = pilot:1.30.4 ]
	grep -q "member-c: keeps the platform of the record it inherited (kubernetes), read before this step; this read could not get it" "$WARN"
	grep -q "member-c: keeps the gateway proxy build of the record it inherited (proxyv2:1.30.4)" "$WARN"
}

@test "platform_probe (H7): nothing is read again after platform_probe_load (inside a window) or in a dry-run" {
	probe_setup
	PLATFORM_PROBE_ROWS=$'member-a\tunknown\tunknown\tunknown\tunknown\tunknown\n'
	export PLATFORM_PROBE_ROWS
	DRY_RUN=1 platform_probe member-a
	[ ! -s "$CALLS" ]
	platform_probe_load "${BATS_TEST_TMPDIR}/missing.tsv"
	platform_probe member-a
	[ ! -s "$CALLS" ]
	[ "$(platform_member_value member-a platform)" = unknown ]
	# A saved record that knows more replaces an inherited row of unknowns.
	printf 'member-a\tkubernetes\top\tistiod\tproxy\tkind\n' > "${BATS_TEST_TMPDIR}/saved.tsv"
	platform_probe_load "${BATS_TEST_TMPDIR}/saved.tsv"
	[ "$(platform_member_value member-a istiod)" = istiod ]
}

@test "platform_chart_args (H15): with auto, a member the record holds is not asked again; one it lacks or holds unknown is" {
	local a=(stale)
	PLATFORM_PROBE_ROWS=$'member-a\topenshift\tx\ty\tz\taws\nmember-u\tunknown\tunknown\tunknown\tunknown\tunknown\n'
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
		assert_output --partial "TEST_PLATFORM must be auto, kubernetes or openshift (got: k8s); set it in the environment, the --config file or config/options.env"
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
	# tuning 003 compares its passes with the baseline instead (004).
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
}

@test "H6: every script that calls platform_probe or platform_drift_check sources reach.sh (their warnings mask addresses)" {
	local f
	for f in "$ROOT"/tests/*/0*.sh; do
		grep -qE '^[[:space:]]*(platform_probe|platform_drift_check) ' "$f" || continue
		grep -q 'source "${ROOT}/tests/lib/reach.sh"' "$f" || { echo "${f}: calls platform_probe or platform_drift_check without reach.sh"; false; }
	done
}

# ---------------------------------------------------------------------------
# --resume (H1): platform_resume_check against the TSV a sweep started
# ---------------------------------------------------------------------------

# resume_tsv <file> [sed program]: the controlplane TSV a sweep started on member-a,member-b: the
# record platform_probe reads from _probe_kubectl now and the tuning baseline
# tuning_baseline_state reads on member-a now (both edited by the sed program), a header and a
# row. Leaves PLATFORM_PROBE_ROWS reset.
resume_tsv() {
	source "${ROOT}/tests/lib/preamble.sh"  # tuning_baseline_state
	probe_setup
	platform_probe member-a,member-b 2>/dev/null
	{
		echo "# Control-plane resource metrics"
		{ platform_preamble_lines member-a,member-b; tuning_baseline_state member-a "${KUBECTL[@]}" | sed 's/^/# /'; } |
			sed "${2:-}"
		printf 'timestamp\tcontext\n'
		printf 't\tmember-a\n'
	} > "$1"
	probe_setup
	: > "$CALLS"
}

@test "platform_resume_check (H1): the same record and levers proceed silently" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv"
	resume_tsv "$tsv"
	platform_probe member-a,member-b 2>/dev/null
	run --separate-stderr platform_resume_check "$tsv" member-a,member-b member-a
	assert_success
	[ -z "$stderr" ] || { echo "$stderr"; false; }
	grep -q -- '--context=member-a .*get sidecar.networking.istio.io default -o name' "$CALLS"
}

@test "platform_resume_check (H1): another build dies naming the member, the key, both values and how to start a new sweep" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv"
	resume_tsv "$tsv"
	PROBE_ISTIOD=1.30.6 platform_probe member-a,member-b 2>/dev/null
	run --separate-stderr platform_resume_check "$tsv" member-a,member-b member-a
	assert_failure
	[[ "$stderr" == *"error: --resume: ${tsv} was started on other builds or tuning levers than the members have now:"* ]]
	[[ "$stderr" == *"  member-a: ISTIOD_IMAGE_BY_CONTEXT recorded pilot:1.30.5@${DIG_B}, now pilot:1.30.6@${DIG_B}"* ]]
	[[ "$stderr" == *"  member-b: ISTIOD_IMAGE_BY_CONTEXT recorded pilot:1.30.5@${DIG_B}, now pilot:1.30.6@${DIG_B}"* ]]
	[[ "$stderr" == *"Start a new sweep instead: run "*" again with this sweep's flags (and --config) but without --resume; it writes a new sweep-<RUN_ID>/ in its results dir and leaves this one as it is. Or put the members back"* ]]
	[[ "$stderr" != *"config snapshot"* ]] || { echo "$stderr"; false; }
	# Another operator build too, and a cluster rebuilt onto other nodes; a sweep run with
	# --config names its snapshot, which replays the config.
	resume_tsv "$tsv" 's/member-b=kind/member-b=aws/'
	echo "CONTROLPLANE_MESH_SIZES=1,2" > "${BATS_TEST_TMPDIR}/run-config-r.env"
	PROBE_OPERATOR=1.31.2 platform_probe member-a,member-b 2>/dev/null
	run --separate-stderr platform_resume_check "$tsv" member-a,member-b
	assert_failure
	[[ "$stderr" == *"member-a: MESH_OPERATOR_BY_CONTEXT recorded sail-operator:1.31.1@${DIG_A}/Available, now sail-operator:1.31.2@${DIG_A}/Available"* ]]
	[[ "$stderr" == *"member-b: NODE_PROVIDER_BY_CONTEXT recorded aws, now kind"* ]]
	[[ "$stderr" == *"This sweep's config snapshot replays its --config values: "*" --config $(printf '%q' "${BATS_TEST_TMPDIR}/run-config-r.env") (plus the flags it ran with besides --config). Or put the members back"* ]]
}

@test "platform_resume_check (H1): an operator that only changed its state proceeds" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv"
	resume_tsv "$tsv"
	PROBE_SAIL_AVAILABLE=0 platform_probe member-a,member-b 2>/dev/null
	[ "$(platform_member_value member-a operator)" = "sail-operator:1.31.1@${DIG_A}/Unavailable" ]
	run --separate-stderr platform_resume_check "$tsv" member-a,member-b member-a
	assert_success
	[ -z "$stderr" ] || { echo "$stderr"; false; }
}

@test "platform_resume_check (H1): unknown on either side, a member on one side only, another TEST_PLATFORM: warnings only" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv"
	resume_tsv "$tsv" 's/member-b=pilot:[^,]*/member-b=unknown/'
	platform_probe member-a,member-b 2>/dev/null
	TEST_PLATFORM=kubernetes run --separate-stderr platform_resume_check "$tsv" member-a,member-b member-a
	assert_success
	[[ "$stderr" == *"warning: --resume: member-b: ISTIOD_IMAGE_BY_CONTEXT not read in the record of ${tsv} or now, so this run cannot tell whether they changed since its rows were measured"* ]]
	[[ "$stderr" == *"warning: --resume: ${tsv} was started with TEST_PLATFORM=auto, this run has TEST_PLATFORM=kubernetes"* ]]
	# Now: member-a does not answer; member-c is new; member-b is no longer a member.
	resume_tsv "$tsv"
	PROBE_PLATFORM=down platform_probe member-a 2>/dev/null
	platform_probe member-c 2>/dev/null
	run --separate-stderr platform_resume_check "$tsv" member-a,member-c
	assert_success
	[[ "$stderr" == *"member-a: PLATFORM_BY_CONTEXT, MESH_OPERATOR_BY_CONTEXT, ISTIOD_IMAGE_BY_CONTEXT, PROXY_IMAGE_BY_CONTEXT, NODE_PROVIDER_BY_CONTEXT not read"* ]]
	[[ "$stderr" == *"warning: --resume: member-c is a member of this run but not of the record in ${tsv}"* ]]
	[[ "$stderr" == *"warning: --resume: member-b is in the record of ${tsv} but not a member of this run"* ]]
}

@test "platform_resume_check (H1): a TSV from before the record warns and proceeds" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv"
	resume_tsv "$tsv" '/_BY_CONTEXT=\|PLATFORM=/d'
	! grep -q 'PLATFORM' "$tsv" || false
	platform_probe member-a,member-b 2>/dev/null
	run --separate-stderr platform_resume_check "$tsv" member-a,member-b member-a
	assert_success
	[[ "$stderr" == *"warning: --resume: ${tsv} predates the platform record (no PLATFORM_BY_CONTEXT line)"* ]]
}

@test "platform_resume_check (H1): TUNING_BASELINE or SIDECAR_EGRESS_HOSTS that differ die; unknown warns; read on the TSV's member" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv"
	resume_tsv "$tsv"
	platform_probe member-a,member-b 2>/dev/null
	PROBE_TB_DS=on run --separate-stderr platform_resume_check "$tsv" member-a,member-b member-a
	assert_failure
	[[ "$stderr" == *"  member-a: TUNING_BASELINE discoverySelectors recorded off, now on"* ]]
	PROBE_TB_HOSTS="istio-system/*" run --separate-stderr platform_resume_check "$tsv" member-a,member-b member-a
	assert_failure
	[[ "$stderr" == *"  member-a: SIDECAR_EGRESS_HOSTS recorded istio-system/* ./*, now istio-system/*"* ]]
	# A lever recorded unknown cannot be compared: a warning.
	resume_tsv "$tsv" 's/discoverySelectors=off/discoverySelectors=unknown/'
	platform_probe member-a,member-b 2>/dev/null
	run --separate-stderr platform_resume_check "$tsv" member-a,member-b member-a
	assert_success
	[[ "$stderr" == *"warning: --resume: TUNING_BASELINE discoverySelectors recorded unknown, now off on member-a"* ]]
	# --contexts in another order: the levers are read on the member the TSV read them on.
	resume_tsv "$tsv"
	platform_probe member-b,member-a 2>/dev/null
	: > "$CALLS"
	run --separate-stderr platform_resume_check "$tsv" member-b,member-a member-b
	assert_success
	[[ "$stderr" == *"--resume: reading TUNING_BASELINE on member-a, the member ${tsv} read it on (this run lists member-b first)"* ]]
	grep -q -- '--context=member-a .*get sidecar.networking.istio.io' "$CALLS"
	! grep -q -- '--context=member-b .*get sidecar.networking.istio.io' "$CALLS" || false
}

@test "platform_resume_check (H1): nothing in a dry-run or for a TSV without a header yet; it needs tuning_baseline_state for levers" {
	local tsv="${BATS_TEST_TMPDIR}/controlplane-r.tsv"
	resume_tsv "$tsv"
	PROBE_ISTIOD=1.30.6 platform_probe member-a,member-b 2>/dev/null
	DRY_RUN=1 run platform_resume_check "$tsv" member-a,member-b member-a
	assert_success
	printf '# PLATFORM=kubernetes\n' > "${BATS_TEST_TMPDIR}/new.tsv"
	run platform_resume_check "${BATS_TEST_TMPDIR}/new.tsv" member-a,member-b member-a
	assert_success
	unset -f tuning_baseline_state
	run platform_resume_check "$tsv" member-a,member-b member-a
	assert_failure
	assert_output --partial "platform_resume_check needs tuning_baseline_state (source tests/lib/preamble.sh)"
}

# ---------------------------------------------------------------------------
# Drift during a sweep (H2): platform_drift_check and the reports' side
# ---------------------------------------------------------------------------

@test "platform_drift_check (H2): a build that changed during the sweep warns and goes to the marker; a state-only change does not" {
	probe_setup
	platform_probe member-a,member-b 2>/dev/null
	local dir="${BATS_TEST_TMPDIR}/sweep"
	mkdir -p "$dir"
	: > "$CALLS"
	run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	assert_output "Platform record: reading member-a member-b again, to check that no build changed during the sweep"
	[ -z "$stderr" ] || { echo "$stderr"; false; }
	[ ! -e "${dir}/platform-drift.txt" ]
	# Fresh reads, not the record the sweep holds.
	grep -q -- '--context=member-a' "$CALLS"
	grep -q -- '--context=member-b' "$CALLS"
	# istiod upgraded; the operator only became Unavailable.
	PROBE_ISTIOD=1.30.6 PROBE_SAIL_AVAILABLE=0 run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	[[ "$stderr" == *"warning: member-a: ISTIOD_IMAGE_BY_CONTEXT changed during the sweep: pilot:1.30.5@${DIG_B} at its start, pilot:1.30.6@${DIG_B} at its end"* ]]
	[[ "$stderr" == *"(written to ${dir}/platform-drift.txt, so its reports read ISTIOD_IMAGE_BY_CONTEXT mixed)"* ]]
	[[ "$stderr" != *MESH_OPERATOR* ]]
	grep -qx "# ISTIOD_IMAGE_BY_CONTEXT=member-a=pilot:1.30.6@${DIG_B},member-b=pilot:1.30.6@${DIG_B}" "${dir}/platform-drift.txt"
	grep -q '^# DRIFT_READ_AT=' "${dir}/platform-drift.txt"
	! grep -q MESH_OPERATOR "${dir}/platform-drift.txt" || false
	# A member that does not answer at the end: a warning, no marker line for it.
	PROBE_PLATFORM=down run --separate-stderr platform_drift_check "${BATS_TEST_TMPDIR}" member-a
	assert_success
	[[ "$stderr" == *"member-a: PLATFORM_BY_CONTEXT, MESH_OPERATOR_BY_CONTEXT, ISTIOD_IMAGE_BY_CONTEXT, PROXY_IMAGE_BY_CONTEXT, NODE_PROVIDER_BY_CONTEXT not read at the sweep's start or end"* ]]
	[ ! -e "${BATS_TEST_TMPDIR}/platform-drift.txt" ]
	# A dry-run reads nothing.
	: > "$CALLS"
	DRY_RUN=1 run platform_drift_check "$dir" member-a,member-b
	assert_success
	[ -z "$output" ]
	[ ! -s "$CALLS" ]
	# It never fails the sweep whose reports run next (PL40): without KUBECTL it warns.
	KUBECTL=()
	run --separate-stderr platform_drift_check "$dir" member-a,member-b
	assert_success
	[[ "$stderr" == *"warning: platform_drift_check needs reach_sanitize (source tests/lib/reach.sh) and KUBECTL; not checked"* ]]
	[ ! -s "$CALLS" ]
}

@test "platform_report_values (H2): a sweep's drift marker makes its keys mixed, and the report's body says the build changed" {
	local d="${BATS_TEST_TMPDIR}/sweep"
	mkdir -p "$d"
	platform_fixture_lines > "${d}/a.tsv"
	platform_fixture_lines > "${d}/b.tsv"
	printf '%s\n' '# Platform builds that changed during this sweep' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' \
		'# ISTIOD_IMAGE_BY_CONTEXT=ctx-a=pilot:1.30.6' > "${d}/platform-drift.txt"
	run --separate-stderr platform_report_values "${d}/a.tsv" "${d}/b.tsv"
	assert_success
	assert_line "ISTIOD_IMAGE_BY_CONTEXT=ctx-a=mixed:pilot:1.30.5;pilot:1.30.6,ctx-b=pilot:1.30.5"
	assert_line "PROXY_IMAGE_BY_CONTEXT=ctx-a=proxyv2:1.30.5,ctx-b=proxyv2:1.30.5"
	[[ "$stderr" == *"warning: ISTIOD_IMAGE_BY_CONTEXT changed during the sweep for ctx-a (platform-drift.txt next to its TSVs)"* ]]
	[ "$(grep -c 'changed during the sweep' <<<"$stderr")" -eq 1 ]
	run platform_report_warnings "${d}/a.tsv" "${d}/b.tsv"
	assert_output --partial "ISTIOD_IMAGE_BY_CONTEXT changed during the sweep for ctx-a (platform-drift.txt next to its TSVs): the TSVs record the value at the sweep's start"
	refute_output --partial "warning:"
	# Another sweep's inputs are not touched by it.
	mkdir -p "${BATS_TEST_TMPDIR}/other"
	platform_fixture_lines > "${BATS_TEST_TMPDIR}/other/c.tsv"
	run platform_report_warnings "${BATS_TEST_TMPDIR}/other/c.tsv"
	[ -z "$output" ]
}

# ---------------------------------------------------------------------------
# The reports' body (H10): platform_report_warnings, platform_warning_lines and the helpers
# ---------------------------------------------------------------------------

@test "platform_report_warnings (H10): per-key wording; unknown against known could not be read; a state-only difference is not mixed" {
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
		NODE_PROVIDER_BY_CONTEXT=a=kind,b=kind)"
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
}

@test "platform_summary and platform_short_digests: no member names, counts when members differ, 12 hex digits" {
	run platform_summary "a=pilot:1.30.5@${DIG_B},b=pilot:1.30.5@${DIG_B}"
	assert_output "pilot:1.30.5@sha256:bbbbbbbbbbbb"
	run platform_summary "a=x,b=y,c=x"
	assert_output "x (2 members); y (1 member)"
	run platform_summary "mixed:unknown,a=x"
	assert_output "mixed:unknown; x (1 member)"
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
}

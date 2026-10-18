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
# empty: nothing in the Sail namespace; PROBE_CSV other: no servicemeshoperator3 CSV.
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
   "template":{"spec":{"containers":[{"name":"sail-operator","image":"registry.example.invalid/sail/sail-operator:1.31.1"}]}}},
  "status":{"availableReplicas":1}},
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
  "spec":{"containers":[{"name":"discovery","image":"registry.example.invalid/istio/pilot:1.30.5"}]},
  "status":{"phase":"Running","containerStatuses":[{"name":"discovery","imageID":"registry.example.invalid/istio/pilot@${DIG_B}","restartCount":0}]}},
 {"metadata":{"name":"ingress-1","labels":{"istio":"ingressgateway"}},
  "spec":{"containers":[{"name":"istio-proxy","image":"registry.example.invalid/istio/proxyv2:1.30.5"}]},
  "status":{"phase":"Running","containerStatuses":[{"name":"istio-proxy","imageID":"${DIG_C}","restartCount":0}]}}
]}
JSON
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

@test "platform_probe: absent only when the platform's own kind answers with none" {
	probe_setup
	PROBE_SAIL=empty platform_probe member-a 2>"$WARN"
	PROBE_PLATFORM=openshift PROBE_CSV=other platform_probe member-o 2>>"$WARN"
	# TEST_PLATFORM=openshift on a Kubernetes member: no CSV kind there, so unknown with a warning.
	TEST_PLATFORM=openshift platform_probe member-k 2>>"$WARN"
	# TEST_PLATFORM=kubernetes on an OpenShift member: no Sail Deployment, but the platform was
	# not asked, so none there is unknown too (OSSM may run), never absent.
	TEST_PLATFORM=kubernetes PROBE_PLATFORM=openshift PROBE_SAIL=empty platform_probe member-s 2>>"$WARN"
	[ "$(platform_member_value member-a operator)" = absent ]
	[ "$(platform_member_value member-o operator)" = absent ]
	[ "$(platform_member_value member-k operator)" = unknown ]
	[ "$(platform_member_value member-k platform)" = openshift ]
	[ "$(platform_member_value member-s operator)" = unknown ]
	[ "$(platform_member_value member-s platform)" = kubernetes ]
	grep -q "member-k: could not read the mesh operator build; recorded as unknown: .*doesn't have a resource type" "$WARN"
	grep -q "member-s: no mesh operator where TEST_PLATFORM=kubernetes looks, and the member's platform was not asked; recorded as unknown, not absent" "$WARN"
	[ "$(grep -c 'could not read' "$WARN")" -eq 1 ]
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
	assert_output "| Platform | kubernetes (TEST_PLATFORM auto); nodes kind; operator m1=op1,m2=op2; istiod istiod1; proxy proxy1 |"
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
	[[ "$stderr" == *"input TSVs disagree on PLATFORM (kubernetes,unknown)"* ]]
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

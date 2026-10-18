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

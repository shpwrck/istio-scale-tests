#!/usr/bin/env bats
# terraform/scripts/argocd-controller-reshard.sh MODE=app-status against a stub kubectl: an
# Application whose sync status is Unknown because Argo CD cannot load state from its
# cluster fails the check at the deadline, one quoted message per cluster, naming
# cluster_api_url_overrides, and is reported once as soon as it is seen; a repo or manifest
# error is not a cluster error but fails too; a cluster that comes back before the deadline
# passes; a status from before the check is not trusted until Argo CD has compared the
# Application again (a refresh is requested once); an Application without a status, an
# unreadable or empty list and a missing mesh member are named; the check waits for every
# Application or ApplicationSet an Application lists, and for every member ApplicationSet of
# this repo to own an Application per member.

load test_helper

SCRIPT="${ROOT}/terraform/scripts/argocd-controller-reshard.sh"

setup() {
	STUB_DIR="${BATS_TEST_TMPDIR}/stub"
	STUB_LOG="${STUB_DIR}/calls.log"
	export STUB_DIR STUB_LOG
	mkdir -p "${STUB_DIR}/bin"
	: >"$STUB_LOG"
	# kubectl: the Applications answer from apps.<n>.json in call order (the last one
	# repeats), the ApplicationSets from appsets.<n>.json the same way (none: an empty list);
	# with fail.txt every call fails with its text on stderr, with appsets.fail only the
	# ApplicationSets read; the refresh annotation succeeds unless annotate.fail exists (its
	# text on stderr).
	cat >"${STUB_DIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STUB_LOG"
if [[ -f "$STUB_DIR/fail.txt" ]]; then cat "$STUB_DIR/fail.txt" >&2; exit 1; fi
case " $* " in
*" annotate applications.argoproj.io --all argocd.argoproj.io/refresh=normal --overwrite "*)
	if [[ -f "$STUB_DIR/annotate.fail" ]]; then cat "$STUB_DIR/annotate.fail" >&2; exit 1; fi ;;
*" get applications.argoproj.io -o json "*)
	n=$(( $(cat "$STUB_DIR/apps.n" 2>/dev/null || echo 0) + 1 ))
	echo "$n" >"$STUB_DIR/apps.n"
	f="$STUB_DIR/apps.${n}.json"
	[[ -f "$f" ]] || f="$(ls "$STUB_DIR"/apps.*.json | sort -t. -k2 -n | tail -1)"
	cat "$f" ;;
*" get applicationsets.argoproj.io -o json "*)
	if [[ -f "$STUB_DIR/appsets.fail" ]]; then cat "$STUB_DIR/appsets.fail" >&2; exit 1; fi
	n=$(( $(cat "$STUB_DIR/appsets.n" 2>/dev/null || echo 0) + 1 ))
	echo "$n" >"$STUB_DIR/appsets.n"
	f="$STUB_DIR/appsets.${n}.json"
	[[ -f "$f" ]] || f="$(ls "$STUB_DIR"/appsets.*.json 2>/dev/null | sort -t. -k2 -n | tail -1)"
	if [[ -n "$f" ]]; then cat "$f"; else echo '{"items":[]}'; fi ;;
*) exit 1 ;;
esac
EOF
	chmod +x "${STUB_DIR}/bin/kubectl"
	export PATH="${STUB_DIR}/bin:${PATH}"
	export KUBECONFIG_PATH=/dev/null KUBE_CONTEXT=hub GITOPS_NS=argocd ARGOCD_NAME=argocd MODE=app-status
	export POLL_SEC=0 APP_STATUS_TIMEOUT_SEC=1 TMPDIR="$BATS_TEST_TMPDIR"
	unset EXPECTED_DESTINATIONS
}

# reset_stub: no Application or ApplicationSet lists yet, no failure, an empty call log.
reset_stub() {
	rm -f "${STUB_DIR}"/apps.* "${STUB_DIR}"/appsets.* "${STUB_DIR}/annotate.fail" "${STUB_DIR}/fail.txt"
	: >"$STUB_LOG"
}

# app <name> <destination> <sync> <health> [ComparisonError message] [reconciledAt]: one
# Application, JSON (without reconciledAt: never compared before, so never stale).
app() {
	local cond='[]'
	[[ -z "${5:-}" ]] || cond="$(jq -nc --arg m "$5" '[{type: "ComparisonError", message: $m}]')"
	jq -nc --arg n "$1" --arg d "$2" --arg s "$3" --arg h "$4" --argjson c "$cond" --arg r "${6:-}" \
		'{metadata: {name: $n}, spec: {destination: {name: $d}}, status: ({sync: {status: $s}, health: {status: $h}, conditions: $c} + (if $r == "" then {} else {reconciledAt: $r} end))}'
}

# apps <n> <app JSON>...: the Application list the <n>th read returns.
apps() {
	local n="$1"
	shift
	printf '%s\n' "$@" | jq -sc '{items: .}' >"${STUB_DIR}/apps.${n}.json"
}

# owned <appset> <app JSON>: the Application as that ApplicationSet generates it.
owned() {
	jq -c --arg s "$1" '.metadata.ownerReferences = [{apiVersion: "argoproj.io/v1alpha1", kind: "ApplicationSet", name: $s, uid: ("uid-" + $s), controller: true}]' <<<"$2"
}

# lists <app JSON> <Kind/name[/prune|@namespace]>...: the Application listing those
# Applications or ApplicationSets in .status.resources (/prune: requiresPruning; @ns: in
# another namespace).
lists() {
	local app="$1" r kind name ns prune
	shift
	for r in "$@"; do
		kind="${r%%/*}" name="${r#*/}" ns=argocd prune=false
		[[ "$name" != */prune ]] || { name="${name%/prune}"; prune=true; }
		[[ "$name" != *@* ]] || { ns="${name#*@}"; name="${name%@*}"; }
		app="$(jq -c --arg k "$kind" --arg n "$name" --arg ns "$ns" --argjson p "$prune" \
			'.status.resources += [{group: "argoproj.io", version: "v1alpha1", kind: $k, name: $n, namespace: $ns, status: "OutOfSync"} + (if $p then {requiresPruning: true} else {} end)]' <<<"$app")"
	done
	printf '%s\n' "$app"
}

# appset <name> <generator: clusters, cdr (clusterDecisionResource), matrix (clusters in a
# matrix) or list> [ours|foreign] [ErrorOccurred message]: one ApplicationSet, JSON; ours
# carries this repo's chart label.
appset() {
	local gen
	case "$2" in
	clusters) gen='[{clusters: {selector: {matchLabels: {"istio-mesh-member": "true"}}}}]' ;;
	cdr) gen='[{clusterDecisionResource: {configMapRef: "acm-gitops-placement-generator", labelSelector: {matchLabels: {"cluster.open-cluster-management.io/placement": "p"}}}}]' ;;
	matrix) gen='[{matrix: {generators: [{clusters: {selector: {matchLabels: {"istio-mesh-member": "true"}}}}, {list: {elements: [{x: "1"}]}}]}}]' ;;
	list) gen='[{list: {elements: [{name: "in-cluster"}]}}]' ;;
	esac
	jq -nc --arg n "$1" --arg l "${3:-ours}" --arg e "${4:-}" "
		{metadata: {name: \$n, uid: (\"uid-\" + \$n),
			labels: (if \$l == \"ours\" then {\"app.kubernetes.io/name\": \"gitops-hub-ocm-placement-appset\"} else {\"app.kubernetes.io/name\": \"someone-else\"} end)},
		 spec: {generators: ${gen}},
		 status: {conditions: [{type: \"ErrorOccurred\", status: (if \$e == \"\" then \"False\" else \"True\" end), message: \$e},
			{type: \"ResourcesUpToDate\", status: \"True\", message: \"All applications have been generated successfully\"}]}}"
}

# appsets <n> <appset JSON>...: the ApplicationSet list the <n>th read returns.
appsets() {
	local n="$1"
	shift
	printf '%s\n' "$@" | jq -sc '{items: .}' >"${STUB_DIR}/appsets.${n}.json"
}

# member_app <member> <suffix> <appset> [sync] [health]: a member Application its
# ApplicationSet generated (destination: the member).
member_app() { owned "$3" "$(app "$1-$2" "$1" "${4:-Synced}" "${5:-Healthy}")"; }

# hub_app <member> <suffix> <appset>: a hub-side preset's Application for a member (its
# destination is the hub).
hub_app() { owned "$3" "$(app "$1-$2" in-cluster Synced Healthy)"; }

REFUSED='Failed to load target state: failed to get cluster version for cluster "https://127.0.0.1:41234": failed to get cluster info for "https://127.0.0.1:41234": error synchronizing cache state : failed to sync cluster https://127.0.0.1:41234: failed to load initial state of resource Pod: Get "https://127.0.0.1:41234/api/v1/pods?limit=500": dial tcp 127.0.0.1:41234: connect: connection refused'
LIVE='Failed to load live state: failed to get cluster info for "https://203.0.113.7:6443": dial tcp 203.0.113.7:6443: i/o timeout'
REPO='Failed to load target state: failed to generate manifest for source 1 of 1: rpc error: code = Unknown desc = repository not found'

# A deadline of 0 s: the check fails after its first poll, so a test of what it names at the
# deadline waits for nothing. What needs several polls passes before its deadline instead.

@test "app-status: Applications sync Unknown fail at the deadline: one quoted message per unreachable cluster (on one line), a repo or manifest error apart, a missing member named; each error reported once when first seen; a cluster that comes back passes" {
	local fail='Failed to load target state: failed to generate manifest for source 1 of 1: rpc error: code = Unknown desc = helm template . --name-template mesh-wiring-verify: execution error at (mesh-wiring-verify/templates/deployment.yaml:2:4): istiodCheck.host was replaced by istiodCheck.service'
	apps 1 \
		"$(app hub-apps in-cluster Synced Healthy)" \
		"$(app mesh-b-ossm mesh-b Unknown Unknown "$REFUSED")" \
		"$(app mesh-b-cni mesh-b Unknown Unknown "$REFUSED")" \
		"$(app mesh-b-ingress mesh-b Unknown Unknown "$REFUSED")" \
		"$(app mesh-c-ossm mesh-c Unknown Missing "$LIVE")" \
		"$(app mesh-e-ossm mesh-e Unknown Unknown "$(printf 'Failed to load live state:\n\tdial tcp 192.0.2.1:6443: connect: no route to host')")" \
		"$(app mesh-d-ossm mesh-d Unknown Healthy "$REPO")" \
		"$(app mesh-a-gate mesh-a Unknown Healthy "$fail")"
	# mesh-z is a mesh member no Application targets: named too.
	EXPECTED_DESTINATIONS="mesh-a mesh-b mesh-z" APP_STATUS_TIMEOUT_SEC=0 run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "cannot load state from these clusters after 0s"
	assert_line "  mesh-b: mesh-b-ossm and 2 more: ${REFUSED}"
	assert_line "  mesh-c: mesh-c-ossm: ${LIVE}"
	assert_line "  mesh-e: mesh-e-ossm: Failed to load live state: dial tcp 192.0.2.1:6443: connect: no route to host"
	assert_output --partial "cluster_api_url_overrides"
	[ "$(grep -c '^  mesh-b: ' <<<"$output")" -eq 1 ]
	# The repo and manifest errors: not cluster errors, quoted per Application.
	assert_output --partial "cannot compare these Applications after 0s"
	assert_line "  mesh-d-ossm (destination mesh-d): ${REPO}"
	assert_line "  mesh-a-gate (destination mesh-a): ${fail}"
	refute_line --partial "  mesh-d: "
	refute_line --partial "  mesh-a: "
	assert_output --partial "no Application targets these destination clusters after 0s"
	assert_line "  mesh-z"
	refute_output --partial "hub-apps"
	refute_output --partial "Application(s) have a sync and health status"
	# The warning, when first seen, comes before the deadline's error.
	assert_output --partial "WARNING: Argo CD cannot load state from cluster mesh-b (Application mesh-b-ossm): ${REFUSED}. The check fails in"
	[ "$(grep -n '^WARNING: Argo CD cannot compare' <<<"$output" | head -1 | cut -d: -f1)" -lt "$(grep -n '^error: Argo CD cannot compare' <<<"$output" | cut -d: -f1)" ]
	# Over three polls, a cluster is reported once for its two Applications and a message once
	# for the two that share it; then the cluster comes back and the error clears: it passes.
	reset_stub
	local bad
	bad=("$(app mesh-b-ossm mesh-b Unknown Unknown "$REFUSED")" "$(app mesh-b-cni mesh-b Unknown Unknown "$REFUSED")"
		"$(app mesh-a-gate mesh-a Unknown Healthy "$fail")" "$(app mesh-d-gate mesh-d Unknown Healthy "$fail")")
	apps 1 "${bad[@]}"
	apps 2 "${bad[@]}"
	apps 3 "$(app mesh-b-ossm mesh-b Synced Healthy)" "$(app mesh-b-cni mesh-b Synced Healthy)" \
		"$(app mesh-a-gate mesh-a Synced Healthy)" "$(app mesh-d-gate mesh-d Synced Healthy)"
	APP_STATUS_TIMEOUT_SEC=60 run bash "$SCRIPT"
	assert_success
	assert_output --partial "all 4 Application(s) have a sync and health status"
	[ "$(grep -c 'get applications.argoproj.io -o json' "$STUB_LOG")" -eq 3 ]
	[ "$(grep -c '^WARNING: Argo CD cannot load state from cluster mesh-b ' <<<"$output")" -eq 1 ]
	[ "$(grep -cF "so it does not deploy: ${fail}. The check fails in" <<<"$output")" -eq 1 ]
}

@test "app-status: a status from before the check counts only once Argo CD has compared the Application again; one not compared again fails at the deadline, named; a refused refresh request warns, and the check passes once Argo CD compares on its own" {
	# The statuses say Synced/Healthy, compared at T1, before the check started.
	apps 1 "$(app hub-apps in-cluster Synced Healthy '' 2026-01-01T00:00:01Z)" "$(app mesh-b-ossm mesh-b Synced Healthy '' 2026-01-01T00:00:01Z)"
	APP_STATUS_TIMEOUT_SEC=0 run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "has not compared these Applications again in the 0s since this check started"
	assert_line "  mesh-b-ossm (destination mesh-b)"
	assert_line "  hub-apps (destination in-cluster)"
	refute_output --partial "Application(s) have a sync and health status"
	[ "$(grep -c ' annotate ' "$STUB_LOG")" -eq 1 ]
	# hub-apps is compared again at the second poll, mesh-b-ossm only at the third; the
	# refresh request is refused, so Argo CD compares them on its own.
	reset_stub
	echo 'error: applications.argoproj.io is forbidden' >"${STUB_DIR}/annotate.fail"
	apps 1 "$(app hub-apps in-cluster Synced Healthy '' 2026-01-01T00:00:01Z)" "$(app mesh-b-ossm mesh-b Synced Healthy '' 2026-01-01T00:00:01Z)"
	apps 2 "$(app hub-apps in-cluster Synced Healthy '' 2026-01-01T00:00:02Z)" "$(app mesh-b-ossm mesh-b Synced Healthy '' 2026-01-01T00:00:01Z)"
	apps 3 "$(app hub-apps in-cluster Synced Healthy '' 2026-01-01T00:00:02Z)" "$(app mesh-b-ossm mesh-b Synced Healthy '' 2026-01-01T00:05:01Z)"
	APP_STATUS_TIMEOUT_SEC=60 run bash "$SCRIPT"
	assert_success
	assert_output --partial "WARNING: could not request a refresh of the Applications (error: applications.argoproj.io is forbidden )"
	assert_line --regexp '^  waiting \([0-9]+s left\): 2 not compared again yet$'
	assert_line --regexp '^  waiting \([0-9]+s left\): 1 not compared again yet$'
	assert_output --partial "all 2 Application(s) have a sync and health status"
	[ "$(grep -c ' annotate ' "$STUB_LOG")" -eq 1 ]
}

@test "app-status: Applications without a sync or health status fail at the deadline, named with their destination (name or server)" {
	apps 1 "$(app in-cluster-ossm in-cluster Synced Healthy)" \
		'{"metadata":{"name":"mesh-b-ossm"},"spec":{"destination":{"name":"mesh-b"}},"status":{}}' \
		'{"metadata":{"name":"mesh-b-ingress"},"spec":{"destination":{"server":"https://api.mesh-b.example:6443"}},"status":{"sync":{"status":"Synced"}}}'
	APP_STATUS_TIMEOUT_SEC=0 run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "Applications without a sync or health status after 0s"
	assert_line "  mesh-b-ossm (destination mesh-b)"
	assert_line "  mesh-b-ingress (destination https://api.mesh-b.example:6443)"
	refute_output --partial "in-cluster-ossm"
}

@test "app-status: an expected destination (a name or a server URL) with no Application fails, named, even when every status is set; once each has one it passes" {
	# The ApplicationSets have generated nothing for mesh-c yet: only the hub's own
	# Applications and mesh-b's exist, all with a status (the 2026-10-16 timing).
	apps 1 "$(app in-cluster-ossm in-cluster Synced Healthy)" "$(app mesh-b-ossm mesh-b Synced Healthy)"
	EXPECTED_DESTINATIONS="mesh-b mesh-c" APP_STATUS_TIMEOUT_SEC=0 run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "no Application targets these destination clusters after 0s"
	assert_output --partial "kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster --show-labels"
	assert_line "  mesh-c"
	refute_line "  mesh-b"
	refute_output --partial "without a sync or health status"
	reset_stub
	apps 1 '{"metadata":{"name":"in-cluster-ossm"},"spec":{"destination":{"server":"https://kubernetes.default.svc"}},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}}' \
		"$(app mesh-a-ossm mesh-a Synced Healthy)" \
		'{"metadata":{"name":"mesh-b-ossm"},"spec":{"destination":{"server":"https://api.mesh-b.example:6443"}},"status":{"sync":{"status":"OutOfSync"},"health":{"status":"Missing"}}}'
	EXPECTED_DESTINATIONS="mesh-a,https://api.mesh-b.example:6443" run bash "$SCRIPT"
	assert_success
	assert_output --partial "all 3 Application(s) have a sync and health status"
	assert_output --partial "an Application for each of the 2 members"
}

@test "app-status: no Applications at all, or a list that cannot be read, fails at the deadline (with kubectl's error), never passes" {
	export APP_STATUS_TIMEOUT_SEC=0
	echo '{"items":[]}' >"${STUB_DIR}/apps.1.json"
	run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "no Applications found in argocd after 0s"
	echo 'Unable to connect to the server: dial tcp 192.0.2.9:6443: i/o timeout' >"${STUB_DIR}/fail.txt"
	run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "could not read the Applications in argocd after 0s: Unable to connect to the server: dial tcp 192.0.2.9:6443: i/o timeout"
	refute_output --partial "no Applications found"
	reset_stub
	apps 1 "$(app mesh-b-ossm mesh-b Synced Healthy)"
	echo 'error: the server does not have a resource type "applicationsets"' >"${STUB_DIR}/appsets.fail"
	run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial 'could not read the ApplicationSets in argocd after 0s: error: the server does not have a resource type "applicationsets"'
}

@test "app-status: what an Application lists keeps it waiting until it exists (an ApplicationSet too); at the deadline it names what does not, neither one to prune nor one in another namespace" {
	# A greenfield apply at its first poll (kind 2026-10-18, scale reviewer's stub): the
	# app-of-apps has compared and lists its children, none created yet; the gate
	# ApplicationSet (created by Terraform) already has both members' Applications.
	apps 1 \
		"$(lists "$(app hub-gitops-root in-cluster OutOfSync Missing)" Application/spoke-ossm-appset Application/hub-mesh-ca Application/gone/prune Application/elsewhere@other-ns)" \
		"$(member_app m1 mesh-wiring-verify mesh-wiring-verify OutOfSync Missing)" \
		"$(member_app m2 mesh-wiring-verify mesh-wiring-verify OutOfSync Missing)"
	appsets 1 "$(appset mesh-wiring-verify clusters)"
	EXPECTED_DESTINATIONS="m1 m2" APP_STATUS_TIMEOUT_SEC=0 run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "still do not exist after 0s"
	assert_line "  Application spoke-ossm-appset (listed by Application hub-gitops-root)"
	assert_line "  Application hub-mesh-ca (listed by Application hub-gitops-root)"
	assert_output --partial "kubectl -n argocd get applications.argoproj.io <listing Application> -o jsonpath='{.status.operationState.message}'"
	assert_line --regexp '^  waiting \([0-9]+s left\): 2 listed but not created yet$'
	refute_output --partial "Application gone "
	refute_output --partial "elsewhere"
	refute_output --partial "Application(s) have a sync and health status"
	# A listed ApplicationSet that is created at the second poll: it waits, then passes.
	reset_stub
	local root child
	root="$(lists "$(app hub-gitops-root in-cluster Synced Healthy)" Application/spoke-ossm-appset)"
	child="$(lists "$(app spoke-ossm-appset in-cluster OutOfSync Missing)" ApplicationSet/spoke-ossm)"
	apps 1 "$root" "$child"
	apps 2 "$root" "$(lists "$(app spoke-ossm-appset in-cluster Synced Healthy)" ApplicationSet/spoke-ossm)" "$(member_app m1 ossm spoke-ossm)"
	appsets 1 '{"metadata":{"name":"other"}}'
	appsets 2 "$(appset spoke-ossm clusters)"
	EXPECTED_DESTINATIONS=m1 APP_STATUS_TIMEOUT_SEC=60 run bash "$SCRIPT"
	assert_success
	assert_line --regexp '^  waiting \([0-9]+s left\): 1 listed but not created yet; no Application for m1$'
	assert_output --partial "all 3 Application(s) have a sync and health status"
	[ "$(grep -c ' get applicationsets.argoproj.io -o json' "$STUB_LOG")" -eq 2 ]
}

@test "app-status: each of this repo's ApplicationSets that select clusters must own an Application per member (hub-side ones counted, not matched): short keeps it waiting, and at the deadline it is named with k of N and its ErrorOccurred message" {
	# hub-mesh-push-secrets generates one Application per member whose destination is the hub.
	apps 1 \
		"$(member_app m1 ossm spoke-ossm)" "$(member_app m2 ossm spoke-ossm)" \
		"$(hub_app m1 hub-mesh-push-secrets hub-mesh-push-secrets)"
	apps 2 \
		"$(member_app m1 ossm spoke-ossm)" "$(member_app m2 ossm spoke-ossm)" \
		"$(hub_app m1 hub-mesh-push-secrets hub-mesh-push-secrets)" "$(hub_app m2 hub-mesh-push-secrets hub-mesh-push-secrets)"
	appsets 1 "$(appset spoke-ossm clusters)" "$(appset hub-mesh-push-secrets clusters)"
	EXPECTED_DESTINATIONS="m1,m2" APP_STATUS_TIMEOUT_SEC=60 run bash "$SCRIPT"
	assert_success
	assert_line --regexp '^  waiting \([0-9]+s left\): ApplicationSet hub-mesh-push-secrets 1 of 2$'
	assert_output --partial "all 4 Application(s) have a sync and health status"
	[ "$(grep -c ' get applications.argoproj.io -o json' "$STUB_LOG")" -eq 2 ]
	# Still short at the deadline.
	export APP_STATUS_TIMEOUT_SEC=0
	reset_stub
	local err='failed to get cluster secrets: secrets is forbidden: User "system:serviceaccount:argocd:argocd-applicationset-controller" cannot list resource "secrets"'
	apps 1 "$(member_app m1 ossm spoke-ossm)" "$(member_app m2 ossm spoke-ossm)" "$(member_app m1 gw spoke-ingress-gateway)"
	appsets 1 "$(appset spoke-ossm clusters)" "$(appset spoke-ingress-gateway clusters ours "$err")" "$(appset spoke-east-west-gateway cdr)"
	EXPECTED_DESTINATIONS="m1 m2" run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "own fewer than the 2 members (m1 m2)"
	assert_line "  spoke-ingress-gateway: 1 of 2 Applications; ErrorOccurred: ${err}"
	assert_line "  spoke-east-west-gateway: 0 of 2 Applications; no ErrorOccurred condition"
	refute_line --partial "  spoke-ossm:"
	# Only this repo's ApplicationSets that select clusters count: not a list generator (the
	# hub's own), nor another team's clusters ApplicationSet; a clusters generator inside a
	# matrix does.
	reset_stub
	apps 1 "$(member_app m1 ossm spoke-ossm)" "$(member_app m2 ossm spoke-ossm)" "$(member_app m1 eso hub-external-secrets-operator)"
	appsets 1 "$(appset hub-external-secrets-operator list)" "$(appset their-appset clusters foreign)" "$(appset spoke-ossm matrix)"
	EXPECTED_DESTINATIONS="m1 m2" run bash "$SCRIPT"
	assert_success
	appsets 1 "$(appset hub-external-secrets-operator list)" "$(appset their-appset clusters foreign)" "$(appset spoke-ossm matrix)" "$(appset spoke-mx matrix)"
	run bash "$SCRIPT"
	assert_success
	EXPECTED_DESTINATIONS="m1 m2" run bash "$SCRIPT"
	assert_failure 1
	assert_line "  spoke-mx: 0 of 2 Applications; no ErrorOccurred condition"
	refute_output --partial "their-appset"
	refute_output --partial "hub-external-secrets-operator:"
}

@test "app-status: complete (every listed object, every member ApplicationSet at N, fresh statuses) passes at the first poll: one read of each list and one refresh request, each with a request timeout" {
	apps 1 \
		"$(lists "$(app hub-gitops-root in-cluster Synced Healthy)" Application/spoke-ossm-appset Application/hub-mesh-push-secrets-appset)" \
		"$(lists "$(app spoke-ossm-appset in-cluster Synced Healthy)" ApplicationSet/spoke-ossm)" \
		"$(lists "$(app hub-mesh-push-secrets-appset in-cluster Synced Healthy)" ApplicationSet/hub-mesh-push-secrets)" \
		"$(member_app m1 ossm spoke-ossm)" "$(member_app m2 ossm spoke-ossm OutOfSync Progressing)" \
		"$(hub_app m1 hub-mesh-push-secrets hub-mesh-push-secrets)" "$(hub_app m2 hub-mesh-push-secrets hub-mesh-push-secrets)" \
		"$(member_app m1 mesh-wiring-verify mesh-wiring-verify)" "$(member_app m2 mesh-wiring-verify mesh-wiring-verify)"
	appsets 1 "$(appset spoke-ossm clusters)" "$(appset hub-mesh-push-secrets clusters)" "$(appset mesh-wiring-verify clusters)"
	EXPECTED_DESTINATIONS="m1 m2" run bash "$SCRIPT"
	assert_success
	assert_output --partial "all 9 Application(s) have a sync and health status"
	assert_output --partial "an Application for each of the 2 members"
	refute_output --partial "waiting"
	[ "$(wc -l <"$STUB_LOG" | tr -d ' ')" -eq 3 ]
	grep -q -- '--context=hub --request-timeout=60s -n argocd get applications.argoproj.io -o json' "$STUB_LOG"
	grep -q -- '--context=hub --request-timeout=60s -n argocd get applicationsets.argoproj.io -o json' "$STUB_LOG"
	grep -q -- '--context=hub --request-timeout=60s -n argocd annotate applications.argoproj.io --all argocd.argoproj.io/refresh=normal --overwrite' "$STUB_LOG"
}

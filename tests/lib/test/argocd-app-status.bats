#!/usr/bin/env bats
# terraform/scripts/argocd-controller-reshard.sh MODE=app-status against a stub kubectl: an
# Application whose sync status is Unknown because Argo CD cannot load state from its
# cluster fails the check at the deadline, one quoted message per cluster, naming
# cluster_api_url_overrides, and is reported once as soon as it is seen; a repo or manifest
# error is not a cluster error but fails too; a cluster that comes back before the deadline
# passes; a status from before the check is not trusted until Argo CD has compared the
# Application again (a refresh is requested once); an unreadable list and a missing mesh
# member are named; the check waits for every Application or ApplicationSet an Application
# lists, and for every member ApplicationSet of this repo to own an Application per member.

load test_helper

SCRIPT="${ROOT}/terraform/scripts/argocd-controller-reshard.sh"

setup() {
	STUB_DIR="$(mktemp -d)"
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
	export POLL_SEC=0 APP_STATUS_TIMEOUT_SEC=1
	unset EXPECTED_DESTINATIONS
}

teardown() {
	rm -rf "$STUB_DIR"
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

@test "app-status: Applications sync Unknown on unreachable clusters fail at the deadline, one message per cluster" {
	apps 1 \
		"$(app hub-apps in-cluster Synced Healthy)" \
		"$(app mesh-b-ossm mesh-b Unknown Unknown "$REFUSED")" \
		"$(app mesh-b-cni mesh-b Unknown Unknown "$REFUSED")" \
		"$(app mesh-b-ingress mesh-b Unknown Unknown "$REFUSED")" \
		"$(app mesh-c-ossm mesh-c Unknown Missing "$LIVE")"
	run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "Argo CD on the hub cannot load state from these clusters after 1s (their Applications are sync Unknown)"
	assert_line "  mesh-b: mesh-b-ossm and 2 more: ${REFUSED}"
	assert_line "  mesh-c: mesh-c-ossm: ${LIVE}"
	assert_output --partial "cluster_api_url_overrides"
	assert_output --partial "the hub and every other member (istiod reads the same URL) must reach it"
	[ "$(grep -c '^  mesh-b: ' <<<"$output")" -eq 1 ]
	refute_output --partial "hub-apps"
	refute_output --partial "all 5 Application(s)"
}

@test "app-status: a multi-line ComparisonError is quoted on one line" {
	apps 1 "$(app mesh-b-ossm mesh-b Unknown Unknown "$(printf 'Failed to load live state:\n\tdial tcp 192.0.2.1:6443: connect: no route to host')")"
	run bash "$SCRIPT"
	assert_failure 1
	assert_line "  mesh-b: mesh-b-ossm: Failed to load live state: dial tcp 192.0.2.1:6443: connect: no route to host"
}

@test "app-status: a repo or manifest error is not a cluster error, and fails at the deadline quoted" {
	apps 1 "$(app hub-apps in-cluster Synced Healthy)" "$(app mesh-b-ossm mesh-b Unknown Healthy "$REPO")"
	run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "Argo CD cannot compare these Applications after 1s (sync Unknown with a ComparisonError), so they never deploy:"
	assert_line "  mesh-b-ossm (destination mesh-b): ${REPO}"
	assert_output --partial "a chart that fails to render"
	refute_output --partial "cannot load state"
	refute_output --partial "all 2 Application(s)"
}

@test "app-status: a manifest error is reported once when first seen; the check still fails only at the deadline" {
	local fail='Failed to load target state: failed to generate manifest for source 1 of 1: rpc error: code = Unknown desc = helm template . --name-template mesh-wiring-verify: execution error at (mesh-wiring-verify/templates/deployment.yaml:2:4): istiodCheck.host was replaced by istiodCheck.service'
	apps 1 "$(app hub-apps in-cluster Synced Healthy)" "$(app mesh-a-gate mesh-a Unknown Healthy "$fail")" "$(app mesh-b-gate mesh-b Unknown Healthy "$fail")"
	APP_STATUS_TIMEOUT_SEC=2 run bash "$SCRIPT"
	assert_failure 1
	[ "$(grep -c '^WARNING: Argo CD cannot compare Application' <<<"$output")" -eq 1 ]
	assert_output --partial "WARNING: Argo CD cannot compare Application mesh-a-gate (destination mesh-a), so it does not deploy: ${fail}. The check fails in"
	[ "$(grep -c ' get applications.argoproj.io -o json' "$STUB_LOG")" -gt 1 ]
	assert_line "  mesh-b-gate (destination mesh-b): ${fail}"
	# The warning comes before the deadline's error.
	[ "$(grep -n '^WARNING: Argo CD cannot compare' <<<"$output" | cut -d: -f1)" -lt "$(grep -n '^error: Argo CD cannot compare' <<<"$output" | cut -d: -f1)" ]
}

@test "app-status: an unreachable cluster is reported once when first seen, with the fix, then fails at the deadline" {
	apps 1 "$(app mesh-b-ossm mesh-b Unknown Unknown "$REFUSED")" "$(app mesh-b-cni mesh-b Unknown Unknown "$REFUSED")"
	APP_STATUS_TIMEOUT_SEC=2 run bash "$SCRIPT"
	assert_failure 1
	[ "$(grep -c '^WARNING: Argo CD cannot load state from cluster mesh-b' <<<"$output")" -eq 1 ]
	assert_output --partial "WARNING: Argo CD cannot load state from cluster mesh-b (Application mesh-b-ossm): ${REFUSED}. The check fails in"
	assert_output --partial "you can stop the apply and fix it now (a URL the hub cannot reach: cluster_api_url_overrides"
	[ "$(grep -c ' get applications.argoproj.io -o json' "$STUB_LOG")" -gt 1 ]
	assert_line "  mesh-b: mesh-b-ossm and 1 more: ${REFUSED}"
}

@test "app-status: a cluster that becomes reachable before the deadline passes" {
	apps 1 "$(app mesh-b-ossm mesh-b Unknown Unknown "$REFUSED")"
	apps 2 "$(app mesh-b-ossm mesh-b Unknown Unknown "$REFUSED")"
	apps 3 "$(app mesh-b-ossm mesh-b Synced Healthy)"
	APP_STATUS_TIMEOUT_SEC=60 run bash "$SCRIPT"
	assert_success
	assert_output --partial "all 1 Application(s) have a sync and health status"
	[ "$(grep -c 'get applications.argoproj.io -o json' "$STUB_LOG")" -eq 3 ]
}

@test "app-status: every poll reads the Applications and the ApplicationSets once, with a request timeout; one refresh request" {
	apps 1 "$(app mesh-b-ossm mesh-b Synced Healthy)"
	EXPECTED_DESTINATIONS=mesh-b run bash "$SCRIPT"
	assert_success
	[ "$(grep -c ' get applications.argoproj.io -o json' "$STUB_LOG")" -eq 1 ]
	[ "$(grep -c ' get applicationsets.argoproj.io -o json' "$STUB_LOG")" -eq 1 ]
	[ "$(grep -c ' annotate ' "$STUB_LOG")" -eq 1 ]
	[ "$(wc -l <"$STUB_LOG" | tr -d ' ')" -eq 3 ]
	grep -q -- '--context=hub --request-timeout=60s -n argocd get applications.argoproj.io -o json' "$STUB_LOG"
	grep -q -- '--context=hub --request-timeout=60s -n argocd get applicationsets.argoproj.io -o json' "$STUB_LOG"
	grep -q -- '--context=hub --request-timeout=60s -n argocd annotate applications.argoproj.io --all argocd.argoproj.io/refresh=normal --overwrite' "$STUB_LOG"
}

@test "app-status: a status from before the check counts only once Argo CD has compared the Application again" {
	# The registration just moved mesh-b to a URL the hub cannot reach; the statuses still
	# say Synced/Healthy (compared at T1) until the refresh compares them again (T2).
	apps 1 "$(app hub-apps in-cluster Synced Healthy '' 2026-01-01T00:00:01Z)" "$(app mesh-b-ossm mesh-b Synced Healthy '' 2026-01-01T00:00:01Z)"
	apps 2 "$(app hub-apps in-cluster Synced Healthy '' 2026-01-01T00:00:02Z)" "$(app mesh-b-ossm mesh-b Synced Healthy '' 2026-01-01T00:00:01Z)"
	apps 3 "$(app hub-apps in-cluster Synced Healthy '' 2026-01-01T00:00:02Z)" "$(app mesh-b-ossm mesh-b Unknown Unknown "$REFUSED" 2026-01-01T00:00:03Z)"
	# Room for three polls before the deadline (bash's SECONDS ticks on whole seconds).
	APP_STATUS_TIMEOUT_SEC=3 run bash "$SCRIPT"
	assert_failure 1
	assert_line "  mesh-b: mesh-b-ossm: ${REFUSED}"
	refute_output --partial "all 2 Application(s)"
	refute_output --partial "has not compared"
	[ "$(grep -c ' annotate ' "$STUB_LOG")" -eq 1 ]
}

@test "app-status: an Application Argo CD never compares again fails at the deadline, named" {
	apps 1 "$(app hub-apps in-cluster Synced Healthy '' 2026-01-01T00:00:01Z)" "$(app mesh-b-ossm mesh-b Synced Healthy '' 2026-01-01T00:00:01Z)"
	apps 2 "$(app hub-apps in-cluster Synced Healthy '' 2026-01-01T00:00:05Z)" "$(app mesh-b-ossm mesh-b Synced Healthy '' 2026-01-01T00:00:01Z)"
	APP_STATUS_TIMEOUT_SEC=2 run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "Argo CD has not compared these Applications again in the 2s since this check started, so their status can predate the apply:"
	assert_line "  mesh-b-ossm (destination mesh-b)"
	refute_line "  hub-apps (destination in-cluster)"
}

@test "app-status: a refused refresh request warns, and the check passes once Argo CD compares on its own" {
	echo 'error: applications.argoproj.io is forbidden' >"${STUB_DIR}/annotate.fail"
	apps 1 "$(app mesh-b-ossm mesh-b Synced Healthy '' 2026-01-01T00:00:01Z)"
	apps 2 "$(app mesh-b-ossm mesh-b Synced Healthy '' 2026-01-01T00:05:01Z)"
	APP_STATUS_TIMEOUT_SEC=60 run bash "$SCRIPT"
	assert_success
	assert_output --partial "WARNING: could not request a refresh of the Applications (error: applications.argoproj.io is forbidden ); waiting for Argo CD's periodic reconciliation instead"
	assert_output --partial "all 1 Application(s) have a sync and health status"
}

@test "app-status: an unreachable cluster and a mesh member without Applications are both named" {
	apps 1 "$(app mesh-b-ossm mesh-b Unknown Unknown "$REFUSED")"
	EXPECTED_DESTINATIONS="mesh-b mesh-c" run bash "$SCRIPT"
	assert_failure 1
	assert_line "  mesh-b: mesh-b-ossm: ${REFUSED}"
	assert_output --partial "no Application targets these destination clusters after 1s; they are mesh members"
	assert_output --partial "kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster --show-labels"
	assert_line "  mesh-c"
}

@test "app-status: a list that cannot be read fails at the deadline with kubectl's error" {
	echo 'Unable to connect to the server: dial tcp 192.0.2.9:6443: i/o timeout' >"${STUB_DIR}/fail.txt"
	run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "could not read the Applications in argocd after 1s: Unable to connect to the server: dial tcp 192.0.2.9:6443: i/o timeout"
	refute_output --partial "no Applications found"
	rm "${STUB_DIR}/fail.txt"
	apps 1 "$(app mesh-b-ossm mesh-b Synced Healthy)"
	echo 'error: the server does not have a resource type "applicationsets"' >"${STUB_DIR}/appsets.fail"
	run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial 'could not read the ApplicationSets in argocd after 1s: error: the server does not have a resource type "applicationsets"'
}

@test "app-status: the root and the gate's Applications alone keep it waiting; at the deadline it names what they list that does not exist" {
	# A greenfield apply at its first poll (kind 2026-10-18, scale reviewer's stub): the
	# app-of-apps has compared and lists its children, none created yet; the gate
	# ApplicationSet (created by Terraform) already has both members' Applications.
	apps 1 \
		"$(lists "$(app hub-gitops-root in-cluster OutOfSync Missing)" Application/spoke-ossm-appset Application/hub-mesh-ca Application/gone/prune Application/elsewhere@other-ns)" \
		"$(member_app m1 mesh-wiring-verify mesh-wiring-verify OutOfSync Missing)" \
		"$(member_app m2 mesh-wiring-verify mesh-wiring-verify OutOfSync Missing)"
	appsets 1 "$(appset mesh-wiring-verify clusters)"
	EXPECTED_DESTINATIONS="m1 m2" APP_STATUS_TIMEOUT_SEC=2 run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "error: Applications list these in their resources, but they still do not exist after 2s:"
	assert_line "  Application spoke-ossm-appset (listed by Application hub-gitops-root)"
	assert_line "  Application hub-mesh-ca (listed by Application hub-gitops-root)"
	assert_output --partial "kubectl -n argocd get applications.argoproj.io <listing Application> -o jsonpath='{.status.operationState.message}'"
	assert_line --regexp '^  waiting \([0-9]+s left\): 2 listed but not created yet$'
	# Neither one to prune nor one in another namespace is waited for.
	refute_output --partial "Application gone "
	refute_output --partial "elsewhere"
	refute_output --partial "all 3 Application(s)"
	[ "$(grep -c ' get applications.argoproj.io -o json' "$STUB_LOG")" -gt 1 ]
}

@test "app-status: a listed ApplicationSet that does not exist yet keeps it waiting until it does" {
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
	assert_output --partial "all 3 Application(s) have a sync and health status, compared since this check started; every Application and ApplicationSet they list exists, and every member ApplicationSet owns an Application for each of the 1 members"
	[ "$(grep -c ' get applicationsets.argoproj.io -o json' "$STUB_LOG")" -eq 2 ]
}

@test "app-status: a member ApplicationSet with 1 of 2 Applications keeps it waiting; hub-side ones are counted, not matched" {
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
}

@test "app-status: a member ApplicationSet still short at the deadline is named with k of N and its ErrorOccurred message" {
	local err='failed to get cluster secrets: secrets is forbidden: User "system:serviceaccount:argocd:argocd-applicationset-controller" cannot list resource "secrets"'
	apps 1 "$(member_app m1 ossm spoke-ossm)" "$(member_app m2 ossm spoke-ossm)" "$(member_app m1 gw spoke-ingress-gateway)"
	appsets 1 "$(appset spoke-ossm clusters)" "$(appset spoke-ingress-gateway clusters ours "$err")" "$(appset spoke-east-west-gateway cdr)"
	EXPECTED_DESTINATIONS="m1 m2" run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "error: these ApplicationSets generate one Application per mesh member, but after 1s own fewer than the 2 members (m1 m2):"
	assert_line "  spoke-ingress-gateway: 1 of 2 Applications; ErrorOccurred: ${err}"
	assert_line "  spoke-east-west-gateway: 0 of 2 Applications; no ErrorOccurred condition"
	assert_output --partial "kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster --show-labels"
	refute_line --partial "  spoke-ossm:"
}

@test "app-status: only this repo's ApplicationSets that select clusters are counted" {
	# A list generator (the hub's own), another team's clusters ApplicationSet, and a
	# clusters generator inside a matrix (counted).
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

@test "app-status: complete (every listed object, every member ApplicationSet at N, fresh statuses) passes at the first poll" {
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
	assert_output --partial "all 9 Application(s) have a sync and health status, compared since this check started; every Application and ApplicationSet they list exists, and every member ApplicationSet owns an Application for each of the 2 members"
	refute_output --partial "waiting"
	[ "$(grep -c ' get applications.argoproj.io -o json' "$STUB_LOG")" -eq 1 ]
}

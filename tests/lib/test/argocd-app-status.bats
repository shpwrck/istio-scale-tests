#!/usr/bin/env bats
# terraform/scripts/argocd-controller-reshard.sh MODE=app-status against a stub kubectl: an
# Application whose sync status is Unknown because Argo CD cannot load state from its
# cluster fails the check at the deadline, one quoted message per cluster, naming
# cluster_api_url_overrides; a repo error is not a cluster error; a cluster that comes back
# before the deadline passes; a status from before the check is not trusted until Argo CD
# has compared the Application again (a refresh is requested once); an unreadable list and
# a missing mesh member are named.

load test_helper

SCRIPT="${ROOT}/terraform/scripts/argocd-controller-reshard.sh"

setup() {
	STUB_DIR="$(mktemp -d)"
	STUB_LOG="${STUB_DIR}/calls.log"
	export STUB_DIR STUB_LOG
	mkdir -p "${STUB_DIR}/bin"
	: >"$STUB_LOG"
	# kubectl: the Applications answer from apps.<n>.json in call order (the last one
	# repeats); with fail.txt every call fails with its text on stderr; the refresh annotation
	# succeeds unless annotate.fail exists (its text on stderr).
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

@test "app-status: a repo or manifest error is not a cluster error" {
	apps 1 "$(app hub-apps in-cluster Synced Healthy)" "$(app mesh-b-ossm mesh-b Unknown Healthy "$REPO")"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "all 2 Application(s) have a sync and health status"
	refute_output --partial "cannot load state"
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

@test "app-status: every poll reads the Applications once, with a request timeout; one refresh request" {
	apps 1 "$(app mesh-b-ossm mesh-b Synced Healthy)"
	EXPECTED_DESTINATIONS=mesh-b run bash "$SCRIPT"
	assert_success
	[ "$(grep -c ' get applications.argoproj.io -o json' "$STUB_LOG")" -eq 1 ]
	[ "$(grep -c ' annotate ' "$STUB_LOG")" -eq 1 ]
	[ "$(wc -l <"$STUB_LOG" | tr -d ' ')" -eq 2 ]
	grep -q -- '--context=hub --request-timeout=60s -n argocd get applications.argoproj.io -o json' "$STUB_LOG"
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
}

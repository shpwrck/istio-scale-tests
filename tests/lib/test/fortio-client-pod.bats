#!/usr/bin/env bats
# The fortio client pod a probe loads, and what it does when that pod is gone
# (tests/lib/fortio.sh), through dataplane 002 and churn-dataplane 002 and 003 (PL33, PL41):
# - fortio_client_pod takes only a Ready pod (Running alone is not enough: its istio-proxy
#   may still wait for its config), and the probe stops when there is none;
# - fortio_load_wait_out skips its wait when the client pod is gone (a `get pod
#   --ignore-not-found` that answers nothing: no load runs), and keeps it when the pod is
#   still there or the API answers an error (fortio-fail.bats: its stub fails that read);
# - fortio_client_stop deletes with --ignore-not-found, so a pod already gone gives no
#   "its load runs on" warning.
# No cluster: kubectl and curl are stubs. The checks are markers and orderings, never
# elapsed seconds (PL44).

bats_require_minimum_version 1.5.0
load test_helper

setup() {
	BIN="${BATS_TEST_TMPDIR}/bin"
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$BIN" "$RES"
	export FX="${ROOT}/tests/lib/test/fixtures/istiod-diag" STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log"
	export LOAD_STARTED="${BATS_TEST_TMPDIR}/load-started" POD_DELETED="${BATS_TEST_TMPDIR}/pod-deleted"
	export ISTIO_VERSION_CHECK=warn ISTIO_VERSION_READY_WAIT_SEC=0 METRICS_READY_TIMEOUT=0
	: > "$STUB_LOG"
	# kubectl: the Istio CR as fake-istio-cr.sh, one istiod pod; the client list prints
	# CLIENTS (name, deletionTimestamp, Ready status per line; default one Ready pod). An
	# exec answers fortio_ok.json; with EXEC=notfound it fails as for a pod that is gone,
	# with EXEC=block it runs until the pod is deleted (LOAD_STARTED once it runs). `get
	# pod <name> --ignore-not-found -o name` answers nothing with GONE=1, else the pod. A
	# delete fails NotFound without --ignore-not-found, as kubectl does for a pod gone.
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*) exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" delete pod "*)
	: > "$POD_DELETED"
	[[ "${GONE:-0}" == 1 && " $* " != *" --ignore-not-found "* ]] && { echo 'Error from server (NotFound): pods not found' >&2; exit 1; }
	exit 0 ;;
*" get pod -l app="*"-client --field-selector=status.phase=Running "*) printf '%b' "${CLIENTS-client-0\t\tTrue\n}" ;;
*" get pod "*" --ignore-not-found -o name "*)
	[[ "${GONE:-0}" == 1 ]] || printf 'pod/client-0\n' ;;
*" exec "*" fortio load "*)
	case "${EXEC:-ok}" in
	notfound) echo 'Error from server (NotFound): pods "client-0" not found' >&2; exit 1 ;;
	block)
		: > "$LOAD_STARTED"
		for ((i = 0; i < 100; i++)); do [[ -e "$POD_DELETED" ]] && exit 137; sleep 0.1; done ;;
	esac
	cat "$FX/../fortio_ok.json" ;;
*" get deploy dataplane-server "*) printf '1/1' ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running "*) printf 'istiod-abc-x1\n' ;;
*" scale "* | *" rollout status "*) : ;;
*" get events "* | *" get deploy,rs "* | *" -o json "*) cat "$FX/empty_list.json" ;;
*) exit 1 ;;
esac
STUB
	cat > "${BIN}/curl" <<'STUB'
#!/usr/bin/env bash
out="" url=""
while (($#)); do
	case "$1" in
	-o) out="$2"; shift 2 ;;
	http://*) url="$1"; shift ;;
	*) shift ;;
	esac
done
case "$url" in
*/metrics) body="$FX/pre_metrics.txt" ;;
*/ready) echo LIVE; exit 0 ;;
*) exit 7 ;;
esac
if [[ -n "$out" ]]; then cp "$body" "$out"; else cat "$body"; fi
STUB
	chmod +x "${BIN}/kubectl" "${BIN}/curl"
}

DP=(dataplane/002-run-latency-probe.sh --source-context ctx-a --settle 0 --reach-requests 0)
CDP2=(churn-dataplane/002-run-baseline-probe.sh --reach-requests 0 --source-context ctx-a --combo-id c1 --settle-sec 0)
CDP3=(churn-dataplane/003-run-churn-probe.sh --churn-rate 1 --source-context ctx-a --combo-id c1 --settle-sec 0)

@test "a probe loads the first Ready client pod, never a Running one that is not Ready (its istio-proxy may still wait for its config); with none Ready it stops before any load, naming why" {
	local p
	# A replacement pod Running but not Ready, listed first, then a Ready one.
	export CLIENTS='new-client\t\tFalse\nold-ready\t\tTrue\n'
	PATH="${BIN}:${PATH}" run --separate-stderr "${ROOT}/tests/${DP[0]}" "${DP[@]:1}" --qps-levels 10 \
		--warmup-duration 0 --output-dir "$RES"
	assert_success
	assert_output --partial "Source: ctx-a (pod: old-ready)"
	grep -q -- " exec old-ready -c fortio -- fortio load " "$STUB_LOG"
	[ "$(grep -c -- ' exec new-client ' "$STUB_LOG")" = 0 ]
	for p in CDP2 CDP3; do
		: > "$STUB_LOG"
		local -n a="$p"
		PATH="${BIN}:${PATH}" run --separate-stderr "${ROOT}/tests/${a[0]}" "${a[@]:1}" --duration 1 --output-dir "$RES"
		assert_success
		grep -q -- " exec old-ready -c fortio -- fortio load " "$STUB_LOG" || { echo "${a[0]}:"; cat "$STUB_LOG"; false; }
		[ "$(grep -c -- ' exec new-client ' "$STUB_LOG")" = 0 ]
		unset -n a
	done
	# Only pods that are not Ready (one with no Ready condition yet): no load, and why.
	export CLIENTS='new-client\t\tFalse\nnewer-client\t\t\n'
	: > "$STUB_LOG"
	PATH="${BIN}:${PATH}" run --separate-stderr "${ROOT}/tests/${DP[0]}" "${DP[@]:1}" --qps-levels 10 \
		--warmup-duration 0 --output-dir "$RES"
	assert_failure
	[[ "$stderr" == *"no Ready dataplane-client pod that is not being deleted on ctx-a (ns=dataplane-test): run 001, or wait until its Deployment's new pod is Ready"* ]]
	[ "$(grep -c -- ' exec ' "$STUB_LOG")" = 0 ]
	for p in CDP2 CDP3; do
		: > "$STUB_LOG"
		local -n a="$p"
		PATH="${BIN}:${PATH}" run --separate-stderr "${ROOT}/tests/${a[0]}" "${a[@]:1}" --duration 1 --output-dir "$RES"
		assert_failure
		[[ "$stderr" == *"no Ready fortio-client pod that is not being deleted on ctx-a (ns=churn-dataplane-test)"* ]] || { echo "${a[0]}: ${stderr}"; false; }
		[ "$(grep -c -- ' exec ' "$STUB_LOG")" = 0 ]
		unset -n a
	done
}

@test "dataplane 002: when the client pod is gone, a failed window's (and the warmup's) load is not waited out: every window runs, FAILED, each after a read that found no pod" {
	export EXEC=notfound GONE=1
	PATH="${BIN}:${PATH}" run --separate-stderr "${ROOT}/tests/${DP[0]}" "${DP[@]:1}" --qps-levels 10,20,50 \
		--duration 30 --warmup-duration 30 --output-dir "$RES"
	assert_success
	[[ "$stderr" != *"waiting "* ]] || { echo "$stderr"; false; }
	# The warmup and three windows: one note each.
	[ "$(grep -c "note: ctx-a: the load's kubectl exec failed and the client pod client-0 is gone (evicted or deleted), so no load of it runs: not waiting" <<<"$stderr")" -eq 4 ] \
		|| { echo "$stderr"; false; }
	[ "$(awk -F'\t' '$14 == "FAILED"' "$RES"/latency-*.tsv | wc -l)" -eq 3 ]
	# Ordering: each exec is followed by its pod read before the next exec.
	[ "$(grep -E ' exec client-0 | get pod client-0 --ignore-not-found -o name' "$STUB_LOG" | sed -E 's/.* (exec|get pod) .*/\1/' | paste -sd,)" = \
		"exec,get pod,exec,get pod,exec,get pod,exec,get pod" ] || { cat "$STUB_LOG"; false; }
	grep -qx -- "--context=ctx-a --request-timeout=5s -n dataplane-test get pod client-0 --ignore-not-found -o name" "$STUB_LOG"
}

@test "churn-dataplane 002 and 003: when the client pod is gone, the FAILED window's load is not waited out" {
	local p
	export EXEC=notfound GONE=1
	for p in CDP2 CDP3; do
		: > "$STUB_LOG"
		local -n a="$p"
		PATH="${BIN}:${PATH}" run --separate-stderr "${ROOT}/tests/${a[0]}" "${a[@]:1}" --duration 30 --output-dir "$RES"
		[ "$status" -eq 0 ] || { echo "${a[0]}: status ${status}: ${stderr}"; false; }
		[[ "$stderr" == *"note: ctx-a: the load's kubectl exec failed and the client pod client-0 is gone (evicted or deleted), so no load of it runs: not waiting"* ]] \
			|| { echo "${a[0]}: ${stderr}"; false; }
		[[ "$stderr" != *"waiting "* ]]
		grep -q $'\tFAILED\t' "$RES"/churn-dataplane-*.tsv
		grep -qx -- "--context=ctx-a --request-timeout=5s -n churn-dataplane-test get pod client-0 --ignore-not-found -o name" "$STUB_LOG"
		rm -f "$RES"/churn-dataplane-*
		unset -n a
	done
}

@test "fortio_load_wait_out: a pod still there, or an API error, keeps the wait; a gone pod skips it; once the load's time has passed, no read at all" {
	source "${ROOT}/tests/lib/timestamp.sh"
	source "${ROOT}/tests/lib/fortio.sh"
	local calls="${BATS_TEST_TMPDIR}/calls" start
	# k <answer>: a kubectl stand-in that logs its call and answers: gone (nothing, 0),
	# there (the pod, 0) or error (1).
	k() {
		local a="$1"
		shift
		printf '%s\n' "$*" >> "$calls"
		case "$a" in
		gone) return 0 ;;
		there) echo pod/p ;;
		*) return 1 ;;
		esac
	}
	# A start 4 s ago with a 0 s load: under a second left to wait.
	for ans in there error; do
		: > "$calls"
		start="$(($(now_ns) - 4000000000))"
		run --separate-stderr fortio_load_wait_out "$start" 0 ctx-a ns-a p k "$ans"
		assert_success
		[[ "$stderr" == "note: the load's kubectl exec failed, but its fortio load may still run in the client pod: waiting "*"s (its -t 0s and 5 s, from its start)"* ]] \
			|| { echo "${ans}: ${stderr}"; false; }
		[ "$(cat "$calls")" = "--context=ctx-a --request-timeout=5s -n ns-a get pod p --ignore-not-found -o name" ]
	done
	: > "$calls"
	run --separate-stderr fortio_load_wait_out "$(now_ns)" 30 ctx-a ns-a p k gone
	assert_success
	[ "$stderr" = "note: ctx-a: the load's kubectl exec failed and the client pod p is gone (evicted or deleted), so no load of it runs: not waiting" ]
	# Its time has passed: no wait, no read.
	: > "$calls"
	run --separate-stderr fortio_load_wait_out "$(($(now_ns) - 60000000000))" 30 ctx-a ns-a p k gone
	assert_success
	[ -z "$stderr" ]
	[ ! -s "$calls" ]
}

@test "dataplane 002: a SIGTERM during a load whose pod is already gone gives no 'could not delete' warning (the delete uses --ignore-not-found)" {
	local p i rc=0
	EXEC=block GONE=1 PATH="${BIN}:${PATH}" "${ROOT}/tests/${DP[0]}" "${DP[@]:1}" --qps-levels 10 --warmup-duration 0 \
		--output-dir "$RES" > "${BATS_TEST_TMPDIR}/out" 2> "${BATS_TEST_TMPDIR}/err" 3>&- &
	p=$!
	for ((i = 0; i < 300; i++)); do [[ -e "$LOAD_STARTED" ]] && break; sleep 0.1; done
	[[ -e "$LOAD_STARTED" ]] || { kill -s KILL "$p"; cat "${BATS_TEST_TMPDIR}/err"; false; }
	kill -s TERM "$p"
	wait "$p" || rc=$?
	[ "$rc" -eq 143 ] || { echo "status ${rc}: $(cat "${BATS_TEST_TMPDIR}/err")"; false; }
	grep -qx -- "--context=ctx-a --request-timeout=5s -n dataplane-test delete pod client-0 --ignore-not-found --wait=false" "$STUB_LOG"
	! grep -q "could not delete the fortio client pod" "${BATS_TEST_TMPDIR}/err" || false
}

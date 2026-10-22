#!/usr/bin/env bats
# tests/lib/fortio.sh, and its callers dataplane 002 and churn-dataplane 002 and 003
# (PL33, PL41):
# - the fortio -json figures (a missing one is N/A, never 0) and the dataplane row status;
# - the client pod a probe loads: the first Ready one not being deleted, none: no load;
# - a load whose `kubectl exec` failed keeps running in the client pod (the load runs
#   there, not in the exec): the probe waits it out (its duration and 5 s from its start)
#   before its next load, unless the pod is gone; the window is a FAILED row;
# - a probe stopped during a load (or that wait) deletes the client pod, so the load cannot
#   run into the next window.
# No cluster: kubectl and curl are stubs. The checks are orderings and markers, never
# elapsed seconds (PL44).

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/fortio.sh"

FXD="${ROOT}/tests/lib/test/fixtures"
DP=(dataplane/002-run-latency-probe.sh --source-context ctx-a --settle 0 --reach-requests 0)
CDP2=(churn-dataplane/002-run-baseline-probe.sh --reach-requests 0 --source-context ctx-a --combo-id c1 --settle-sec 0)
CDP3=(churn-dataplane/003-run-churn-probe.sh --churn-rate 1 --source-context ctx-a --combo-id c1 --settle-sec 0)

setup() {
	OK_JSON="$(cat "${FXD}/fortio_ok.json")"
	SAT_JSON="$(cat "${FXD}/fortio_saturated_200.json")"
	ERR_JSON="$(cat "${FXD}/fortio_errors.json")"
	NOPCT_JSON="$(cat "${FXD}/fortio_no_percentiles.json")"
}

# _probe_stubs: kubectl and curl for a probe run, every kubectl call logged to STUB_LOG.
#   kubectl: the Istio CR as fake-istio-cr.sh, one istiod pod; the client list prints
#   CLIENTS (name, deletionTimestamp, Ready status per line; default one Ready pod,
#   client-0). Every exec is a fortio load that answers fortio_ok.json, except: the first
#   load whose arguments match the glob FAIL_LOAD fails (EXEC_FAILED); the first matching
#   STOP_LOAD writes LOAD_STARTED and runs (at most 10 s) until its pod is deleted; with
#   EXEC=notfound every load fails as for a pod that is gone. `get pod <name>
#   --ignore-not-found` of its phase answers nothing with GONE=1, else PHASE (default
#   Running). A delete writes POD_DELETED.
#   With SLEEP_LOG=1 in a run's PATH (SLEEP_BIN first), sleep logs "sleep <args>" and
#   returns at once.
_probe_stubs() {
	BIN="${BATS_TEST_TMPDIR}/bin"
	SLEEP_BIN="${BATS_TEST_TMPDIR}/sleep-bin"
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$BIN" "$SLEEP_BIN" "$RES"
	export FX="${FXD}/istiod-diag" STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log" REAL_SLEEP
	REAL_SLEEP="$(command -v sleep)"
	export EXEC_FAILED="${BATS_TEST_TMPDIR}/exec-failed" LOAD_STARTED="${BATS_TEST_TMPDIR}/load-started"
	export POD_DELETED="${BATS_TEST_TMPDIR}/pod-deleted"
	export ISTIO_VERSION_CHECK=warn ISTIO_VERSION_READY_WAIT_SEC=0 METRICS_READY_TIMEOUT=0
	: > "$STUB_LOG"
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*) exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" delete pod "*) : > "$POD_DELETED" ;;
*" get pod -l app="*"-client --field-selector=status.phase=Running "*) printf '%b' "${CLIENTS-client-0\t\tTrue\n}" ;;
*" get pod "*" --ignore-not-found -o jsonpath={.status.phase} "*)
	[[ "${GONE:-0}" == 1 ]] || printf '%s' "${PHASE:-Running}" ;;
*" exec "*" fortio load "*)
	# shellcheck disable=SC2254  # FAIL_LOAD and STOP_LOAD are globs
	case " $* " in
	${FAIL_LOAD:-none})
		if [[ ! -e "$EXEC_FAILED" ]]; then : > "$EXEC_FAILED"; exit 1; fi ;;
	${STOP_LOAD:-none})
		if [[ ! -e "$LOAD_STARTED" ]]; then
			: > "$LOAD_STARTED"
			for ((i = 0; i < 100; i++)); do [[ -e "$POD_DELETED" ]] && exit 137; "$REAL_SLEEP" 0.1; done
		fi ;;
	esac
	if [[ "${EXEC:-ok}" == notfound ]]; then echo 'Error from server (NotFound): pods "client-0" not found' >&2; exit 1; fi
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
	printf '#!/bin/sh\nprintf "sleep %%s\\n" "$*" >> "$STUB_LOG"\nexec %s 0.01\n' "$REAL_SLEEP" > "${SLEEP_BIN}/sleep"
	chmod +x "${BIN}/kubectl" "${BIN}/curl" "${SLEEP_BIN}/sleep"
}

# _probe <array name> [args...]: the probe of that array (DP, CDP2 or CDP3) with its
# arguments, the stubs first on PATH (and the logging sleep with SLEEP_LOG=1).
_probe() {
	local -n _p="$1"
	local path="${BIN}:${PATH}"
	shift
	[[ "${SLEEP_LOG:-0}" != 1 ]] || path="${SLEEP_BIN}:${path}"
	PATH="$path" run --separate-stderr "${ROOT}/tests/${_p[0]}" "${_p[@]:1}" "$@"
}

# _waited <duration> <next>: stderr notes the wait-out of a failed load of <duration> s,
# and STUB_LOG has, in this order: the failed exec, its client pod read, the sleep of the
# noted length and, when <next> is 1, the next load.
_waited() {
	local n f r s x
	n="$(sed -n "s/^note: the load's kubectl exec failed, but its fortio load may still run in the client pod: waiting \([0-9]*\)s (its load's duration, ${1}s, and 5 s, from its start).*/\1/p" <<<"$stderr")"
	[[ -n "$n" ]] || { echo "no wait-out note for a ${1}s load: ${stderr}"; return 1; }
	f="$(grep -n ' fortio load ' "$STUB_LOG" | head -1 | cut -d: -f1)"
	r="$(grep -n ' get pod [^ ]* --ignore-not-found -o jsonpath={.status.phase}$' "$STUB_LOG" | head -1 | cut -d: -f1)"
	s="$(grep -nx "sleep ${n}" "$STUB_LOG" | head -1 | cut -d: -f1)"
	x="$(grep -n ' fortio load ' "$STUB_LOG" | sed -n 2p | cut -d: -f1)"
	[[ -n "$f" && -n "$r" && -n "$s" ]] && ((f < r && r < s)) || { echo "exec ${f}, read ${r}, sleep ${s}:"; cat "$STUB_LOG"; return 1; }
	[[ "$2" != 1 ]] || { [[ -n "$x" ]] && ((s < x)); } || { echo "the next load (${x}) did not wait (${s})"; return 1; }
}

# _stop_during_load <glob> <array name> [args...]: run that probe in the background, send it
# SIGTERM once the load matching <glob> runs, and wait for it; its exit status in rc, its
# stderr in $BATS_TEST_TMPDIR/err.
_stop_during_load() {
	local glob="$1" p i
	local -n _a="$2"
	shift 2
	rc=0
	STOP_LOAD="$glob" PATH="${BIN}:${PATH}" "${ROOT}/tests/${_a[0]}" "${_a[@]:1}" "$@" \
		> "${BATS_TEST_TMPDIR}/out" 2> "${BATS_TEST_TMPDIR}/err" 3>&- &
	p=$!
	for ((i = 0; i < 300; i++)); do [[ -e "$LOAD_STARTED" ]] && break; sleep 0.1; done
	if [[ ! -e "$LOAD_STARTED" ]]; then
		kill -s KILL "$p" 2>/dev/null || true
		echo "the load did not start:"
		cat "${BATS_TEST_TMPDIR}/err"
		return 1
	fi
	kill -s TERM "$p"
	wait "$p" || rc=$?
}

@test "fortio_percentile_ms: matches 50 against 50.0 and converts s to ms; a percentile missing, not requested, or invalid JSON is N/A" {
	run fortio_percentile_ms "$OK_JSON" 50
	assert_success
	assert_output "1.82"
	run fortio_percentile_ms "$OK_JSON" 99.9
	assert_output "11.2"
	run fortio_percentile_ms "$NOPCT_JSON" 50
	assert_success
	assert_output "N/A"
	run fortio_percentile_ms "$OK_JSON" 75
	assert_output "N/A"
	run fortio_percentile_ms "not json" 50
	assert_success
	assert_output "N/A"
}

@test "fortio_max_ms, fortio_actual_qps, fortio_pct_200, fortio_n_responses, fortio_ret_codes: the run's figures; missing or invalid is N/A, never a 0 latency or 0 QPS; a real 0 stays 0" {
	run fortio_max_ms "$OK_JSON"
	assert_output "12.5"
	run fortio_actual_qps "$SAT_JSON"
	assert_output "686.2"
	run fortio_actual_qps '{"ActualQPS": 0}'
	assert_output "0"
	run fortio_pct_200 "$OK_JSON"
	assert_output "1"
	run fortio_pct_200 "$ERR_JSON"
	assert_output "0.9223300970873787"
	run fortio_n_responses "$ERR_JSON"
	assert_output "20600"
	run fortio_n_responses '{"RetCodes": {}}'
	assert_output "0"
	# Numeric order, socket errors (-1) first.
	run fortio_ret_codes "$ERR_JSON"
	assert_output "-1=20,200=19000,503=1580"
	local f j
	for f in fortio_max_ms fortio_actual_qps fortio_pct_200 fortio_ret_codes; do
		for j in '{}' '{"RetCodes": {}}' '{"DurationHistogram": {"Count": 0}}' "not json"; do
			[[ "$f" != fortio_pct_200 && "$f" != fortio_ret_codes || "$j" != '{"DurationHistogram": {"Count": 0}}' ]] || continue
			[[ "$f" != fortio_max_ms && "$f" != fortio_actual_qps || "$j" != '{"RetCodes": {}}' ]] || continue
			run "$f" "$j"
			assert_success
			[ "$output" = N/A ] || { echo "${f} ${j}: ${output}"; false; }
		done
	done
}

@test "fortio_row_status: PERCENTILE_MISSING (or invalid JSON) > ERROR_RATE_HIGH (the caller's pct_200 threshold; no response at all) > QPS_SHORTFALL (strictly under ratio x target; no ActualQPS; ratio 0 or a target not a positive number skips it) > OK" {
	local json
	run fortio_row_status "$OK_JSON" 1000 0.95 0.99
	assert_output "OK"
	run fortio_row_status "$NOPCT_JSON" 1000 0.95 0.99
	assert_output "PERCENTILE_MISSING"
	run fortio_row_status "not json" 1000 0.95 0.99
	assert_success
	assert_output "PERCENTILE_MISSING"
	# Errors win over the shortfall; 0.922 passes a 0.9 threshold, then the shortfall applies.
	run fortio_row_status "$ERR_JSON" 1000 0.95 0.99
	assert_output "ERROR_RATE_HIGH"
	run fortio_row_status "$ERR_JSON" 1000 0.95 0.9
	assert_output "QPS_SHORTFALL"
	run fortio_row_status "$ERR_JSON" 700 0.95 0.9
	assert_output "OK"
	json="$(jq -c '.RetCodes = {}' <<<"$OK_JSON")"
	run fortio_row_status "$json" 1000 0.95 0.99
	assert_output "ERROR_RATE_HIGH"
	# All 200s, 686 of 1000 QPS; against a 500 target, 686 >= 475.
	run fortio_row_status "$SAT_JSON" 1000 0.95 0.99
	assert_output "QPS_SHORTFALL"
	run fortio_row_status "$SAT_JSON" 500 0.95 0.99
	assert_output "OK"
	json="$(jq -c '.ActualQPS = 950' <<<"$OK_JSON")"
	run fortio_row_status "$json" 1000 0.95 0.99
	assert_output "OK"
	json="$(jq -c '.ActualQPS = 949.9' <<<"$OK_JSON")"
	run fortio_row_status "$json" 1000 0.95 0.99
	assert_output "QPS_SHORTFALL"
	# A run without ActualQPS cannot show its delivery.
	json="$(jq -c 'del(.ActualQPS)' <<<"$OK_JSON")"
	run fortio_row_status "$json" 1000 0.95 0.99
	assert_output "QPS_SHORTFALL"
	run fortio_row_status "$SAT_JSON" 1000 0 0.99
	assert_output "OK"
	run fortio_row_status "$SAT_JSON" max 0.95 0.99
	assert_output "OK"
	run fortio_row_status "$SAT_JSON" 0 0.95 0.99
	assert_output "OK"
}

@test "fortio_load_wait_out: a pod in a phase other than Failed or Succeeded (Running, Pending), or an API error, keeps the wait, counted from after the read; a gone pod (no answer; Failed, as after an eviction; Succeeded) skips it; once the load's time has passed, no read at all" {
	source "${ROOT}/tests/lib/timestamp.sh"
	local calls="${BATS_TEST_TMPDIR}/calls" clock="${BATS_TEST_TMPDIR}/clock" start ans t0
	# k <answer>: a kubectl stand-in that logs its call and answers: gone (nothing, 0),
	# there (Running, 0), Failed, Succeeded, Pending (that phase, 0) or error (1).
	k() {
		local a="$1"
		shift
		printf '%s\n' "$*" >> "$calls"
		case "$a" in
		gone) return 0 ;;
		there) echo Running ;;
		Failed | Succeeded | Pending) echo "$a" ;;
		*) return 1 ;;
		esac
	}
	# A start 4 s ago with a 0 s load: under a second left to wait (a sleep that returns).
	sleep() { :; }
	for ans in there Pending error; do
		: > "$calls"
		start="$(($(now_ns) - 4000000000))"
		run --separate-stderr fortio_load_wait_out "$start" 0 ctx-a ns-a p k "$ans"
		assert_success
		[[ "$stderr" == "note: the load's kubectl exec failed, but its fortio load may still run in the client pod: waiting "*"s (its load's duration, 0s, and 5 s, from its start)"* ]] \
			|| { echo "${ans}: ${stderr}"; false; }
		[ "$(cat "$calls")" = "--context=ctx-a --request-timeout=5s -n ns-a get pod p --ignore-not-found -o jsonpath={.status.phase}" ]
	done
	for ans in gone Failed Succeeded; do
		: > "$calls"
		run --separate-stderr fortio_load_wait_out "$(now_ns)" 30 ctx-a ns-a p k "$ans"
		assert_success
		if [[ "$ans" == gone ]]; then ans=deleted; else ans="phase ${ans}: its containers ended"; fi
		[ "$stderr" = "note: ctx-a: the load's kubectl exec failed and the client pod p is gone (${ans}), so no load of it runs: not waiting" ] \
			|| { echo "$stderr"; false; }
	done
	# Its time has passed: no wait, no read.
	: > "$calls"
	run --separate-stderr fortio_load_wait_out "$(($(now_ns) - 60000000000))" 30 ctx-a ns-a p k gone
	assert_success
	[ -z "$stderr" ]
	[ ! -s "$calls" ]
	# The wait is counted after the read: a clock (now_ns) that a slow read moves 20 s on,
	# and a sleep that only logs. A 30 s load just started: 35 s, less the read's 20.
	t0="$(now_ns)"
	now_ns() { cat "$clock"; }
	sleep() { printf 'slept %s\n' "$*" >> "$calls"; }
	slow() {
		printf '%s\n' "$((t0 + $1 * 1000000000))" > "$clock"
		echo Running
	}
	echo "$t0" > "$clock"
	: > "$calls"
	run --separate-stderr fortio_load_wait_out "$t0" 30 ctx-a ns-a p slow 20
	assert_success
	[[ "$stderr" == "note: the load's kubectl exec failed, but its fortio load may still run in the client pod: waiting 15s "* ]] \
		|| { echo "$stderr"; false; }
	[ "$(grep -c '^slept 15$' "$calls")" -eq 1 ]
	# A read that ends past the load's end: no wait, no note.
	echo "$t0" > "$clock"
	: > "$calls"
	run --separate-stderr fortio_load_wait_out "$t0" 30 ctx-a ns-a p slow 40
	assert_success
	[ -z "$stderr" ]
	! grep -q '^slept' "$calls" || false
}

@test "fortio_client_stop: a delete that fails warns that the load runs on for up to the probe's --duration (--warmup-duration in dataplane's warmup) and 5 s more, and never fails" {
	k() { return 1; }
	run --separate-stderr fortio_client_stop ctx-a ns-a client-0 k
	assert_success
	[[ "$stderr" == *"warning: ctx-a: could not delete the fortio client pod client-0: its load runs on for up to the probe's --duration (--warmup-duration in dataplane's warmup) from its start, and 5 s more"* ]] \
		|| { echo "$stderr"; false; }
}

@test "dataplane 002, churn-dataplane 002 and 003 load the first Ready client pod not being deleted (never one Running but not Ready, nor one Terminating); with none, each stops before any load, naming why" {
	local p
	_probe_stubs
	# Listed first: a replacement Running but not Ready, then the stopped run's pod,
	# Terminating (deletionTimestamp set); then a Ready one.
	export CLIENTS='new-client\t\tFalse\nold-client\t2030-01-01T00:00:00Z\tTrue\nready-client\t\tTrue\n'
	SLEEP_LOG=1 _probe DP --qps-levels 10 --warmup-duration 0 --output-dir "$RES"
	assert_success
	assert_output --partial "Source: ctx-a (pod: ready-client)"
	for p in CDP2 CDP3; do
		SLEEP_LOG=1 _probe "$p" --duration 1 --output-dir "$RES"
		assert_success
	done
	[ "$(grep -c -- ' exec ready-client -c fortio -- fortio load ' "$STUB_LOG")" -ge 3 ] || { cat "$STUB_LOG"; false; }
	[ "$(grep -cE -- ' exec (new|old)-client ' "$STUB_LOG")" = 0 ]
	# Only pods that are not Ready (one with no Ready condition yet) or Terminating.
	export CLIENTS='new-client\t\tFalse\nold-client\t2030-01-01T00:00:00Z\tTrue\nnewer-client\t\t\n'
	: > "$STUB_LOG"
	SLEEP_LOG=1 _probe DP --qps-levels 10 --warmup-duration 0 --output-dir "$RES"
	assert_failure
	[[ "$stderr" == *"no Ready dataplane-client pod that is not being deleted on ctx-a (ns=dataplane-test): run 001, or wait until its Deployment's new pod is Ready"* ]]
	for p in CDP2 CDP3; do
		SLEEP_LOG=1 _probe "$p" --duration 1 --output-dir "$RES"
		assert_failure
		[[ "$stderr" == *"no Ready fortio-client pod that is not being deleted on ctx-a (ns=churn-dataplane-test)"* ]] || { echo "${p}: ${stderr}"; false; }
	done
	[ "$(grep -c -- ' exec ' "$STUB_LOG")" = 0 ]
}

@test "a window whose exec failed is a FAILED row, and its load is waited out (its duration and 5 s from its start) before the next load: dataplane 002 (a window, the warmup), churn-dataplane 002 and 003 (before they end); not when the client pod is gone, then every window runs" {
	local p
	_probe_stubs
	export SLEEP_LOG=1
	FAIL_LOAD='* -qps 10 * -json - *' _probe DP --qps-levels 10,20 --duration 3 --warmup-duration 0 --output-dir "$RES"
	assert_success
	_waited 3 1
	grep -qx -- "--context=ctx-a --request-timeout=5s -n dataplane-test get pod client-0 --ignore-not-found -o jsonpath={.status.phase}" "$STUB_LOG"
	awk -F'\t' '$5 == 10 && $14 == "FAILED" { f = 1 } $5 == 20 && $14 == "OK" { o = 1 } END { exit !(f && o) }' "$RES"/latency-*.tsv
	[ "$(grep -c ' delete pod ' "$STUB_LOG")" -eq 0 ]
	# The warmup's load (-quiet, no -json): the window waits for it.
	rm -f "$EXEC_FAILED" "$RES"/latency-*
	: > "$STUB_LOG"
	FAIL_LOAD='* -t 3s -quiet *' _probe DP --qps-levels 10 --duration 1 --warmup-duration 3 --output-dir "$RES"
	assert_success
	[[ "$stderr" == *"warn: warmup failed for "* ]]
	_waited 3 1
	for p in CDP2 CDP3; do
		rm -f "$EXEC_FAILED" "$RES"/churn-dataplane-*
		: > "$STUB_LOG"
		FAIL_LOAD='* -json - *' _probe "$p" --duration 4 --output-dir "$RES"
		[ "$status" -eq 0 ] || { echo "${p}: status ${status}: ${stderr}"; false; }
		_waited 4 0
		grep -qx -- "--context=ctx-a --request-timeout=5s -n churn-dataplane-test get pod client-0 --ignore-not-found -o jsonpath={.status.phase}" "$STUB_LOG"
		grep -q $'\tFAILED\t' "$RES"/churn-dataplane-*.tsv
		[ "$(grep -c ' delete pod ' "$STUB_LOG")" -eq 0 ]
	done
	# The client pod is gone: no wait; the warmup and every window ran, each failed load
	# followed by its pod read before the next.
	rm -f "$RES"/latency-*
	: > "$STUB_LOG"
	EXEC=notfound GONE=1 _probe DP --qps-levels 10,20,50 --duration 30 --warmup-duration 30 --output-dir "$RES"
	assert_success
	[[ "$stderr" != *"waiting "* ]] || { echo "$stderr"; false; }
	[ "$(grep -c "note: ctx-a: the load's kubectl exec failed and the client pod client-0 is gone (deleted), so no load of it runs: not waiting" <<<"$stderr")" -eq 4 ]
	[ "$(awk -F'\t' '$14 == "FAILED"' "$RES"/latency-*.tsv | wc -l)" -eq 3 ]
	[ "$(grep -E ' exec client-0 | get pod client-0 --ignore-not-found ' "$STUB_LOG" | sed -E 's/.* (exec|get pod) .*/\1/' | paste -sd,)" = \
		"exec,get pod,exec,get pod,exec,get pod,exec,get pod" ] || { cat "$STUB_LOG"; false; }
}

@test "a SIGTERM during a load deletes the client pod that runs it (the EXIT trap; --ignore-not-found): dataplane 002 (a window, the warmup, the wait-out of a failed load, whose FAILED row is written first), churn-dataplane 002 and 003" {
	local p rc i
	local del="--context=ctx-a --request-timeout=5s -n dataplane-test delete pod client-0 --ignore-not-found --wait=false"
	_probe_stubs
	_stop_during_load '* -json - *' DP --qps-levels 10 --warmup-duration 0 --output-dir "$RES"
	[ "$rc" -eq 143 ] || { echo "status ${rc}: $(cat "${BATS_TEST_TMPDIR}/err")"; false; }
	grep -qx -- "$del" "$STUB_LOG" || { cat "$STUB_LOG"; false; }
	grep -qF "note: ctx-a: deleting the fortio client pod client-0, which still runs a load" "${BATS_TEST_TMPDIR}/err"
	# The warmup's load (-quiet, no -json).
	rm -f "$LOAD_STARTED" "$POD_DELETED"
	: > "$STUB_LOG"
	_stop_during_load '* -quiet *' DP --qps-levels 10 --warmup-duration 1 --output-dir "$RES"
	[ "$rc" -eq 143 ]
	grep -q -- " -t 1s -quiet " "$STUB_LOG"
	grep -qx -- "$del" "$STUB_LOG"
	for p in CDP2 CDP3; do
		rm -f "$LOAD_STARTED" "$POD_DELETED"
		: > "$STUB_LOG"
		_stop_during_load '* -json - *' "$p" --duration 5 --output-dir "$RES"
		[ "$rc" -eq 143 ] || { echo "${p}: status ${rc}: $(cat "${BATS_TEST_TMPDIR}/err")"; false; }
		grep -qx -- "--context=ctx-a --request-timeout=5s -n churn-dataplane-test delete pod client-0 --ignore-not-found --wait=false" "$STUB_LOG" \
			|| { echo "${p}:"; grep -E 'delete|exec' "$STUB_LOG"; false; }
	done
	# A stop while the probe waits out a failed load (the load may still run).
	rm -f "$RES"/latency-* "$POD_DELETED"
	: > "$STUB_LOG"
	rc=0
	FAIL_LOAD='* -json - *' PATH="${BIN}:${PATH}" "${ROOT}/tests/${DP[0]}" "${DP[@]:1}" --qps-levels 10 --duration 6 \
		--warmup-duration 0 --output-dir "$RES" > "${BATS_TEST_TMPDIR}/out" 2> "${BATS_TEST_TMPDIR}/err" 3>&- &
	p=$!
	for ((i = 0; i < 300; i++)); do grep -q "waiting [0-9]*s (its load's duration, 6s" "${BATS_TEST_TMPDIR}/err" && break; sleep 0.1; done
	grep -q "waiting [0-9]*s (its load's duration, 6s" "${BATS_TEST_TMPDIR}/err" || { kill -s KILL "$p"; cat "${BATS_TEST_TMPDIR}/err"; false; }
	kill -s TERM "$p"
	wait "$p" || rc=$?
	[ "$rc" -eq 143 ] || { echo "status ${rc}: $(cat "${BATS_TEST_TMPDIR}/err")"; false; }
	grep -qx -- "$del" "$STUB_LOG"
	awk -F'\t' '$5 == 10 && $14 == "FAILED" { f = 1 } END { exit !f }' "$RES"/latency-*.tsv
}

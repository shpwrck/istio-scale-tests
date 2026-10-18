#!/usr/bin/env bats
# A fortio load whose `kubectl exec` fails part-way keeps running in the client pod (the
# load runs there, not in the exec): the probe waits it out (fortio_load_wait_out,
# tests/lib/fortio.sh) before its next load, through dataplane 002 (a window and the warmup)
# and churn-dataplane 002 and 003 (PL33, PL41); a stop during that wait still deletes the
# pod. The probes' --help say so. No cluster: kubectl and curl are stubs, and the stub's
# failed exec leaves a background "load" that ends its -t seconds after the exec started.
# The checks are orderings (the next load started after that one ended), never elapsed
# seconds (PL44).

bats_require_minimum_version 1.5.0
load test_helper

setup() {
	BIN="${BATS_TEST_TMPDIR}/bin"
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$BIN" "$RES"
	export FX="${ROOT}/tests/lib/test/fixtures/istiod-diag" STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log"
	export EXEC_FAILED="${BATS_TEST_TMPDIR}/exec-failed" LOAD_ENDED="${BATS_TEST_TMPDIR}/load-ended"
	export OVERLAP="${BATS_TEST_TMPDIR}/overlap"
	export ISTIO_VERSION_CHECK=warn ISTIO_VERSION_READY_WAIT_SEC=0 METRICS_READY_TIMEOUT=0
	: > "$STUB_LOG"
	# kubectl: as in fortio-stop.bats. With FAIL_LOAD=<glob>, the first load whose arguments
	# match it starts a background "load" that writes LOAD_ENDED its -t seconds later (the
	# load in the pod), and its exec fails 1 s in (EXEC_FAILED). A load that starts after
	# that while the "load" still runs is logged in OVERLAP.
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*) exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" delete pod "*) : ;;
*" exec "*" fortio load "*)
	# shellcheck disable=SC2254  # FAIL_LOAD is a glob
	case " $* " in
	$FAIL_LOAD)
		if [[ ! -e "$EXEC_FAILED" ]]; then
			t="$(sed -n 's/.* -t \([0-9]*\)s .*/\1/p' <<<" $* ")"
			( sleep "$t"; : > "$LOAD_ENDED" ) < /dev/null > /dev/null 2>&1 3>&- &
			sleep 1
			: > "$EXEC_FAILED"
			exit 1
		fi ;;
	esac
	if [[ -e "$EXEC_FAILED" && ! -e "$LOAD_ENDED" ]]; then printf '%s\n' "$*" >> "$OVERLAP"; fi
	cat "$FX/../fortio_ok.json" ;;
*" get pod -l app=fortio-client "*) printf 'fortio-client-0\t\tTrue' ;;
*" get pod -l app=dataplane-client "*) printf 'dataplane-client-0\t\tTrue' ;;
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

_waited_note() {
	grep -qE "note: the load's kubectl exec failed, but its fortio load may still run in the client pod: waiting [0-9]+s \(its -t $1s and 5 s, from its start\) before going on, so the next load does not run beside it" "$2"
}

@test "dataplane 002: a window whose exec failed is a FAILED row, and its load is waited out before the next window starts; a failed warmup too" {
	FAIL_LOAD='* -qps 10 * -json - *' PATH="${BIN}:${PATH}" run --separate-stderr "${ROOT}/tests/dataplane/002-run-latency-probe.sh" \
		--source-context ctx-a --qps-levels 10,20 --duration 3 --settle 0 --warmup-duration 0 --reach-requests 0 --output-dir "$RES"
	assert_success
	[ -e "$EXEC_FAILED" ]
	[ ! -e "$OVERLAP" ] || { echo "a load ran beside the failed one: $(cat "$OVERLAP")"; false; }
	# The next window ran, after the failed one's load ended.
	[ "$(grep -c ' fortio load -qps 20 ' "$STUB_LOG")" -eq 1 ]
	_waited_note 3 <(printf '%s\n' "$stderr") || { echo "$stderr"; false; }
	awk -F'\t' '$5 == 10 && $14 == "FAILED" { f = 1 } $5 == 20 && $14 == "OK" { o = 1 } END { exit !(f && o) }' "$RES"/latency-*.tsv
	[ "$(grep -c ' delete pod ' "$STUB_LOG")" -eq 0 ]
	# The warmup's load (no -json): the window waits for it.
	rm -f "$EXEC_FAILED" "$LOAD_ENDED" "$OVERLAP" "$RES"/latency-*
	FAIL_LOAD='* -t 3s -quiet *' PATH="${BIN}:${PATH}" run --separate-stderr "${ROOT}/tests/dataplane/002-run-latency-probe.sh" \
		--source-context ctx-a --qps-levels 10 --duration 1 --settle 0 --warmup-duration 3 --reach-requests 0 --output-dir "$RES"
	assert_success
	[ -e "$EXEC_FAILED" ]
	[ ! -e "$OVERLAP" ]
	[[ "$stderr" == *"warn: warmup failed for "* ]]
	_waited_note 3 <(printf '%s\n' "$stderr") || { echo "$stderr"; false; }
}

@test "dataplane 002: a SIGTERM while it waits out a failed load deletes the client pod (the load may still run)" {
	local p rc=0 i
	FAIL_LOAD='* -json - *' PATH="${BIN}:${PATH}" "${ROOT}/tests/dataplane/002-run-latency-probe.sh" --source-context ctx-a \
		--qps-levels 10 --duration 6 --settle 0 --warmup-duration 0 --reach-requests 0 --output-dir "$RES" \
		> "${BATS_TEST_TMPDIR}/out" 2> "${BATS_TEST_TMPDIR}/err" 3>&- &
	p=$!
	for ((i = 0; i < 300; i++)); do _waited_note 6 "${BATS_TEST_TMPDIR}/err" && break; sleep 0.1; done
	_waited_note 6 "${BATS_TEST_TMPDIR}/err" || { kill -s KILL "$p"; cat "${BATS_TEST_TMPDIR}/err"; false; }
	kill -s TERM "$p"
	wait "$p" || rc=$?
	[ "$rc" -eq 143 ] || { echo "status ${rc}: $(cat "${BATS_TEST_TMPDIR}/err")"; false; }
	grep -qx -- "--context=ctx-a --request-timeout=5s -n dataplane-test delete pod dataplane-client-0 --ignore-not-found --wait=false" "$STUB_LOG"
	# The FAILED row was written before the wait.
	awk -F'\t' '$5 == 10 && $14 == "FAILED" { f = 1 } END { exit !f }' "$RES"/latency-*.tsv
}

@test "churn-dataplane 002 and 003: a window whose exec failed is a FAILED row, and the probe ends only after its load did" {
	local p
	for p in "002-run-baseline-probe.sh --reach-requests 0" "003-run-churn-probe.sh --churn-rate 1"; do
		rm -f "$EXEC_FAILED" "$LOAD_ENDED" "$OVERLAP"
		: > "$STUB_LOG"
		# shellcheck disable=SC2086  # p: the probe and its own flags
		FAIL_LOAD='* -json - *' PATH="${BIN}:${PATH}" run --separate-stderr "${ROOT}/tests/churn-dataplane/"${p} \
			--source-context ctx-a --combo-id c1 --duration 4 --settle-sec 0 --output-dir "$RES"
		[ "$status" -eq 0 ] || { echo "${p}: status ${status}: ${stderr}"; false; }
		[ -e "$EXEC_FAILED" ]
		# Its next step (a sweep's churn window, or the next baseline) starts after the load.
		[ -e "$LOAD_ENDED" ] || { echo "${p} ended before the failed exec's load did"; false; }
		_waited_note 4 <(printf '%s\n' "$stderr") || { echo "${p}: ${stderr}"; false; }
		grep -q $'\tFAILED\t' "$RES"/churn-dataplane-*.tsv
		[ "$(grep -c ' delete pod ' "$STUB_LOG")" -eq 0 ]
		rm -f "$RES"/churn-dataplane-*
	done
}

@test "the probes' --help say that a failed exec's load is waited out, that a stop during a load deletes the client pod, and that a probe run by hand loads only a Ready client pod not being deleted" {
	local f h p d
	for f in dataplane/002-run-latency-probe.sh churn-dataplane/002-run-baseline-probe.sh churn-dataplane/003-run-churn-probe.sh; do
		run --separate-stderr "${ROOT}/tests/${f}" --help
		assert_success
		h="$(tr '\n' ' ' <<<"$output" | tr -s ' ')"
		# The wait is named by the probe's own flags, never fortio's -t.
		d="--duration"
		[[ "$f" != dataplane/* ]] || d="--duration (--warmup-duration for the warmup)"
		for p in "The load runs in the fortio client pod, not in the kubectl exec that starts it." \
			"so the probe waits until its ${d} and 5 s more have passed before going on, unless the client pod is gone (then no load runs)." \
			"When the probe ends during a load (a stop, Ctrl-C), it deletes the client pod, so the load ends with it;" \
			"which a sweep started right after waits for (its setup 001 waits until the Deployments are Available)." \
			"Run by hand, the probe loads only a Ready client pod that is not being deleted, and stops when there is none: run 001, or wait until the new pod is Ready."; do
			[[ "$h" == *"$p"* ]] || { echo "${f} --help does not say: ${p}"; false; }
		done
		[[ "$h" != *"its -t "* ]] || { echo "${f} --help names fortio's -t"; false; }
	done
}

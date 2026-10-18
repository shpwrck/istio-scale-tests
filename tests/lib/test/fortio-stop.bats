#!/usr/bin/env bats
# A fortio load still running in the client pod when a probe is stopped (a SIGTERM the
# sweep forwards, Ctrl-C) is stopped too (fortio_client_stop, tests/lib/fortio.sh): the
# probe's EXIT trap deletes the client pod (the fortio image has no shell or kill), so the
# load cannot run into the next window. Through dataplane 002 (a window and the warmup),
# churn-dataplane 002 and 003 (PL33, PL41); a load that ended is left alone. A probe started
# while that pod is still Terminating loads its replacement (fortio_client_pod). No
# cluster: kubectl and curl are stubs.

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
	# kubectl: the Istio CR as fake-istio-cr.sh, one client and one istiod pod, every exec a
	# fortio load that answers fortio_ok.json. With STOP_LOAD=<glob>, the first load whose
	# arguments match it writes LOAD_STARTED and runs (at most 10 s) until its pod is deleted.
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*) exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" delete pod "*) : > "$POD_DELETED" ;;
*" exec "*" fortio load "*)
	# shellcheck disable=SC2254  # STOP_LOAD is a glob
	case " $* " in
	$STOP_LOAD)
		if [[ ! -e "$LOAD_STARTED" ]]; then
			: > "$LOAD_STARTED"
			for ((i = 0; i < 100; i++)); do [[ -e "$POD_DELETED" ]] && exit 137; sleep 0.1; done
		fi ;;
	esac
	cat "$FX/../fortio_ok.json" ;;
*" get pod -l app=fortio-client "*) printf 'fortio-client-0' ;;
*" get pod -l app=dataplane-client "*) printf 'dataplane-client-0' ;;
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

# _stop_during_load <glob> <probe> <args>...: run <probe> in the background, send it SIGTERM
# once the load matching <glob> runs, and wait for it; its exit status in rc, its stderr in
# $BATS_TEST_TMPDIR/err.
_stop_during_load() {
	local glob="$1" p i
	shift
	rc=0
	STOP_LOAD="$glob" PATH="${BIN}:${PATH}" "$@" > "${BATS_TEST_TMPDIR}/out" 2> "${BATS_TEST_TMPDIR}/err" &
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

@test "dataplane 002: a SIGTERM during a window's load deletes the client pod that runs it (its EXIT trap); during the warmup too; a load that ended is left alone" {
	local rc
	_stop_during_load '* -json - *' "${ROOT}/tests/dataplane/002-run-latency-probe.sh" --source-context ctx-a \
		--qps-levels 10 --settle 0 --warmup-duration 0 --reach-requests 0 --output-dir "$RES"
	[ "$rc" -eq 143 ] || { echo "status ${rc}: $(cat "${BATS_TEST_TMPDIR}/err")"; false; }
	grep -qx -- "--context=ctx-a --request-timeout=5s -n dataplane-test delete pod dataplane-client-0 --wait=false" "$STUB_LOG" || { cat "$STUB_LOG"; false; }
	grep -qF "note: ctx-a: deleting the fortio client pod dataplane-client-0, which still runs a load (its Deployment starts a new one)" "${BATS_TEST_TMPDIR}/err"
	# The warmup's load (no -json).
	rm -f "$LOAD_STARTED" "$POD_DELETED"
	: > "$STUB_LOG"
	_stop_during_load '* -quiet *' "${ROOT}/tests/dataplane/002-run-latency-probe.sh" --source-context ctx-a \
		--qps-levels 10 --settle 0 --warmup-duration 1 --reach-requests 0 --output-dir "$RES"
	[ "$rc" -eq 143 ]
	grep -q -- " -t 1s -quiet " "$STUB_LOG"
	grep -qx -- "--context=ctx-a --request-timeout=5s -n dataplane-test delete pod dataplane-client-0 --wait=false" "$STUB_LOG"
	# A run that ends on its own deletes nothing.
	rm -f "$LOAD_STARTED" "$POD_DELETED"
	: > "$STUB_LOG"
	STOP_LOAD=none PATH="${BIN}:${PATH}" run --separate-stderr "${ROOT}/tests/dataplane/002-run-latency-probe.sh" \
		--source-context ctx-a --qps-levels 10 --settle 0 --warmup-duration 1 --reach-requests 0 --output-dir "$RES"
	assert_success
	grep -q " fortio load " "$STUB_LOG"
	! grep -q " delete pod " "$STUB_LOG"
}

@test "churn-dataplane 002 and 003: a SIGTERM during the window's load deletes the client pod that runs it" {
	local rc p
	for p in "002-run-baseline-probe.sh --reach-requests 0" "003-run-churn-probe.sh --churn-rate 1"; do
		rm -f "$LOAD_STARTED" "$POD_DELETED"
		: > "$STUB_LOG"
		# shellcheck disable=SC2086  # p: the probe and its own flags
		_stop_during_load '* -json - *' "${ROOT}/tests/churn-dataplane/"${p} --source-context ctx-a --combo-id c1 \
			--duration 5 --settle-sec 0 --output-dir "$RES"
		[ "$rc" -eq 143 ] || { echo "${p}: status ${rc}: $(cat "${BATS_TEST_TMPDIR}/err")"; false; }
		grep -qx -- "--context=ctx-a --request-timeout=5s -n churn-dataplane-test delete pod fortio-client-0 --wait=false" "$STUB_LOG" \
			|| { echo "${p}:"; grep -E 'delete|exec' "$STUB_LOG"; false; }
		grep -qF "note: ctx-a: deleting the fortio client pod fortio-client-0, which still runs a load" "${BATS_TEST_TMPDIR}/err"
	done
}

@test "a probe started while a stopped run's client pod is still Terminating loads its replacement (a Running pod without a deletionTimestamp): dataplane 002, churn-dataplane 002 and 003; with none, it stops before its window, naming why" {
	local p w="${BATS_TEST_TMPDIR}/wrap"
	mkdir -p "$w"
	# The client list as kubectl prints it for 002/003's jsonpath: the old pod, Terminating
	# (deletionTimestamp set) and listed first, then its replacement; CLIENTS overrides it.
	cat > "${w}/kubectl" <<'STUB'
#!/usr/bin/env bash
case " $* " in
*" get pod -l app="*"-client --field-selector=status.phase=Running "*)
	printf '%s\n' "$*" >> "$STUB_LOG"
	printf '%b' "${CLIENTS-old-client\t2030-01-01T00:00:00Z\nnew-client\t\n}"
	exit 0 ;;
esac
exec "$STUB_BIN/kubectl" "$@"
STUB
	chmod +x "${w}/kubectl"
	export STUB_BIN="$BIN"
	PATH="${w}:${BIN}:${PATH}" run --separate-stderr "${ROOT}/tests/dataplane/002-run-latency-probe.sh" --source-context ctx-a \
		--qps-levels 10 --settle 0 --warmup-duration 0 --reach-requests 0 --output-dir "$RES"
	assert_success
	assert_output --partial "Source: ctx-a (pod: new-client)"
	grep -q -- " exec new-client -c fortio -- fortio load " "$STUB_LOG"
	[ "$(grep -c -- ' exec old-client ' "$STUB_LOG")" = 0 ]
	for p in "002-run-baseline-probe.sh --reach-requests 0" "003-run-churn-probe.sh --churn-rate 1"; do
		: > "$STUB_LOG"
		# shellcheck disable=SC2086  # p: the probe and its own flags
		PATH="${w}:${BIN}:${PATH}" run --separate-stderr "${ROOT}/tests/churn-dataplane/"${p} --source-context ctx-a \
			--combo-id c1 --duration 1 --settle-sec 0 --output-dir "$RES"
		assert_success
		grep -q -- " exec new-client -c fortio -- fortio load " "$STUB_LOG" || { echo "${p}:"; cat "$STUB_LOG"; false; }
		[ "$(grep -c -- ' exec old-client ' "$STUB_LOG")" = 0 ]
	done
	# Only the Terminating pod: no load runs, and the probe says why.
	: > "$STUB_LOG"
	CLIENTS='old-client\t2030-01-01T00:00:00Z\n' PATH="${w}:${BIN}:${PATH}" run --separate-stderr \
		"${ROOT}/tests/dataplane/002-run-latency-probe.sh" --source-context ctx-a --qps-levels 10 --settle 0 \
		--warmup-duration 0 --reach-requests 0 --output-dir "$RES"
	assert_failure
	[[ "$stderr" == *"no Running dataplane-client pod that is not being deleted on ctx-a (ns=dataplane-test): run 001, or wait until its Deployment's new pod is Ready"* ]]
	[ "$(grep -c -- ' exec ' "$STUB_LOG")" = 0 ]
	CLIENTS='old-client\t2030-01-01T00:00:00Z\n' PATH="${w}:${BIN}:${PATH}" run --separate-stderr \
		"${ROOT}/tests/churn-dataplane/003-run-churn-probe.sh" --churn-rate 1 --source-context ctx-a --combo-id c1 \
		--duration 1 --settle-sec 0 --output-dir "$RES"
	assert_failure
	[[ "$stderr" == *"no Running fortio-client pod that is not being deleted on ctx-a (ns=churn-dataplane-test)"* ]]
}

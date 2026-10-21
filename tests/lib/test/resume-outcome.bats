#!/usr/bin/env bats
# Resumes, outcomes and provenance of the sweeps: a cell cut short while its rows were
# written (INCOMPLETE) or by a stop (INTERRUPTED), leftovers a legacy cell would measure
# on, NOT_RUN and INCOMPLETE in the SLA verdict, the content-hash HARNESS_SHA (submodules
# left out), a stopped --resume, resumes.txt and the attempts, the sweep-dir lock, merged
# values in markdown cells, SIGTERM reaching the step (whose EXIT trap still removes its
# temp files), the tuning sweep's Istio CR checkpoints, controlplane 002's config_dump
# samples and scrape skew, and every report's own harness. Through the real scripts where
# a test can reach them (PL33); no cluster: kubectl is a stub.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/preamble.sh"
source "${ROOT}/tests/lib/capacity.sh"
source "${ROOT}/tests/lib/envelope.sh"
source "${ROOT}/tests/lib/config.sh"

CP="${ROOT}/tests/controlplane"
REPORT="${CP}/004-report-results.sh"

setup() {
	# The test's own process (bats runs setup and the test in one): the CP_TERM stub looks for
	# the sweep below it only, never in a shell that started bats.
	export TEST_PID="$BASHPID"
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: > "$EK"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	# The kubectl stub (files in RO_DIR): the Istio CR reads answer as fake-istio-cr.sh;
	# the controlplane-test namespaces are one (controlplane-test-0) while ns-left exists,
	# their delete removes it unless ns-stuck exists (then the delete fails); the plain
	# namespace's delete succeeds. 002's first read (its Running istiod pods) fails, and
	# first: touches stale-seen when the file STALE names exists; under CP_TERM (once) lists
	# TMPDIR into tmp-at-term, records its PID (stub-pid), starts a 30 s sleep (sleep-pid),
	# sends SIGTERM to the topmost *003-run-sweep.sh ancestor below the test's process (the
	# sweep process alone), closes its output and waits for the sleep before it touches
	# stub-slept (a sweep that waited for its step would wait for it). Anything else fails,
	# as against an empty kubeconfig.
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
d="$RO_DIR"
[ -z "${KLOG:-}" ] || printf '%s\n' "$*" >> "$KLOG"
case "$*" in
*"get istios.sailoperator.io default"*|*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" get namespaces -l app.kubernetes.io/instance=controlplane-test -o json"*)
	if [ -f "$d/ns-left" ]; then echo '{"items":[{"metadata":{"name":"controlplane-test-0","labels":{}}}]}'; else echo '{"items":[]}'; fi ;;
*" get namespace -l app.kubernetes.io/instance=controlplane-test -o name"*|*" get ns -l app.kubernetes.io/instance=controlplane-test -o name"*)
	[ ! -f "$d/ns-left" ] || echo namespace/controlplane-test-0 ;;
*" delete namespace -l app.kubernetes.io/instance=controlplane-test "*)
	[ ! -f "$d/ns-stuck" ] || exit 1
	rm -f "$d/ns-left" ;;
*" delete namespace controlplane-test "*) : ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running -o jsonpath="*)
	[ -z "${STALE:-}" ] || [ ! -e "$STALE" ] || : > "$d/stale-seen"
	if [ -n "${CP_TERM:-}" ] && [ ! -e "$d/term-sent" ]; then
		: > "$d/term-sent"
		ls "${TMPDIR:-/tmp}" > "$d/tmp-at-term" 2>/dev/null || :
		# Both PIDs are on file before the signal: the test checks that both are gone.
		echo "$$" > "$d/stub-pid"
		sleep 30 >/dev/null 2>&1 3>&- &
		echo "$!" > "$d/sleep-pid"
		p=$PPID s=""
		while [ "${p:-1}" -gt 1 ] && [ "$p" != "${TEST_PID:?}" ]; do
			case "$(ps -o args= -p "$p" 2>/dev/null)" in *003-run-sweep.sh*) s="$p" ;; esac
			p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
		done
		[ -z "$s" ] || kill -TERM "$s"
		exec >/dev/null 2>&1 3>&-
		wait
		: > "$d/stub-slept"
	fi
	exit 1 ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
	export RO_DIR="$BATS_TEST_TMPDIR"
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0
}

teardown() {
	# The CP_TERM stub's own processes, when a test left them (only PIDs it recorded).
	local f p
	for f in "${BATS_TEST_TMPDIR}/sleep-pid" "${BATS_TEST_TMPDIR}/stub-pid"; do
		[[ -s "$f" ]] || continue
		p="$(<"$f")"
		if [[ "$p" =~ ^[0-9]+$ ]]; then kill "$p" 2>/dev/null || true; fi
	done
}

# cp_sweep <args...>: controlplane 003 with the stub kubectl, its results under res/;
# stdout in $output, stderr in $stderr.
cp_sweep() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" CONTROLPLANE_RESULTS_DIR="${BATS_TEST_TMPDIR}/res" \
		run --separate-stderr bash "$CP/003-run-sweep.sh" "$@"
}

# sweep_dir: the one sweep dir under res/.
sweep_dir() {
	find "${BATS_TEST_TMPDIR}/res" -maxdepth 1 -name 'sweep-*' -type d
}

# cp_row <ts> <ctx> <mesh> <svcs> <mem_mi>: a valid legacy measurement row (66 columns, window
# kind deploy, 3 replicas, 1 namespace, scoping none, traffic none).
cp_row() {
	printf '%s\t%s\t%s\t%s\t3\t1\tnone\t%s\t50\t90\t5\t9\t100\t3.33\t10\t60\t10\t10\t10\t50\t1.67\t20\t2048\t1048576\t1048576\t1048576\t3/3\t30.0\t100\t30\t0\t100\t200\t250\t10\t15\t40\t50\t120\t250\t22\t22\tOK\tnone\t0\t0\t1.00\t0.50\t30\t51200\t20480\t0\tpods\t4\t0\tnone\tdeploy\t%s\t12.5\t45\t120\t200\t3\t210\t180\t0\n' \
		"$1" "$2" "$3" "$4" "$5" "$(($4 * 2))"
}

# incomplete_dir: a first run of mesh 2 (ci-a, ci-b) x svcs 5,6, whose TSV then holds the
# rows a run cut short would leave: svcs=5 measured on both members, svcs=6 on ci-a only
# (INCOMPLETE). Sets D and TSV.
incomplete_dir() {
	cp_sweep --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5,6
	[ "$status" -eq 4 ]
	D="$(sweep_dir)"
	TSV="$(find "$D" -maxdepth 1 -name 'controlplane-*.tsv')"
	# The first run's status rows (svcs=5, svcs=6), for tests that need one.
	awk -F'\t' '$2 == "PROBE_FAILED"' "$TSV" > "${BATS_TEST_TMPDIR}/status.rows"
	# Members on nodes of their own (the stub reads no node provider, and a verdict over an
	# unknown one leaves the node figures out: CAUTION).
	grep -E '^#|^timestamp' "$TSV" \
		| sed 's/^# NODE_PROVIDER_BY_CONTEXT=.*/# NODE_PROVIDER_BY_CONTEXT=ci-a=aws,ci-b=aws/' > "${TSV}.new"
	{
		cp_row 2026-06-01T00:01:00+00:00 ci-a 2 5 1000
		cp_row 2026-06-01T00:01:00+00:00 ci-b 2 5 1000
		cp_row 2026-06-01T00:02:00+00:00 ci-a 2 6 900
	} >> "${TSV}.new"
	mv "${TSV}.new" "$TSV"
}

# ---------------------------------------------------------------------------
# A cell cut short while its member rows were written (INCOMPLETE)

@test "a cell with rows of fewer members than its mesh size is INCOMPLETE: every 004 format warns, it counts as failed, and the verdict is CAUTION, never PASS" {
	incomplete_dir
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format json
	assert_success
	[ "$(jq -r '.metadata.sla.verdict' <<<"$output")" = CAUTION ]
	[[ "$(jq -r '.metadata.sla.headline' <<<"$output")" == "1 cell(s) are INCOMPLETE (rows of fewer members than their mesh size"* ]]
	jq -e '[.metadata.data_warnings[]? | select(test("1 cell\\(s\\) are INCOMPLETE: .*mesh=2 svcs=6 .*\\(rows of 1 of 2 members\\)"))] | length == 1' <<<"$output"
	local fmt
	for fmt in text markdown csv charts; do
		run --separate-stderr bash "$REPORT" --results-dir "$D" --format "$fmt"
		assert_success
		[[ "$output" == *"1 cell(s) are INCOMPLETE: the sweep was cut short while their member rows were written"* ]] || { echo "${fmt}: ${output}"; false; }
		[[ "$output" == *"mesh=2 svcs=6 reps=3 ns=1 scope=none traffic=none (rows of 1 of 2 members)"* ]]
	done
}

@test "a --resume runs an INCOMPLETE cell again as a new attempt; a narrower --resume names it at its start and counts it as failed (INCOMPLETE)" {
	incomplete_dir
	# Narrower: svcs=6 is left out; it says so before its first cell, then counts it.
	cp_sweep --resume "$D" --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"note: --resume: this run's axis flags leave out 1 planned cell(s) not done yet (never ran, failed or INCOMPLETE), which will not run"*"mesh=2 svcs=6 reps=3 ns=1 scope=none traffic=none"* ]]
	[[ "$stderr" == *"mesh=2 svcs=5 reps=3 ns=1 scope=none traffic=none — already has a valid row; skipping (resume)"* ]]
	[[ "$stderr" == *"error: 1 of 2 cells failed: INCOMPLETE x1."* ]]
	# Full: svcs=6 runs again (the stub fails its probe), marked as a new attempt in the TSV
	# and in resumes.txt, whose last column names the TSV.
	cp_sweep --resume "$D" --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5,6
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"[2/2] mesh=2 svcs=6 reps=3 ns=1 scope=none traffic=none — cut short while its rows were written (INCOMPLETE: rows of 1 of its 2 members): running it again; the reports use only this new attempt (resume)"* ]]
	[[ "$stderr" == *"error: 1 of 2 cells failed: PROBE_FAILED x1."* ]]
	[ "$(grep -c '^# RESUMED_AT=[^ ]* TSV_LINES=[0-9]* HARNESS_SHA=' "$TSV")" -eq 2 ]
	head -n 1 "$D/resumes.txt" | grep -qx $'RESUMED_AT\tHARNESS_SHA\tISTIO_NOTREADY_AT_RESUME\tKUBE_VERSIONS\tTSV_LINES\tISTIO_PROXY_VERSIONS\tISTIO_GENERATIONS\tTSV\tHARNESS_CONTENT_KEY'
	[ "$(awk -F'\t' 'NR > 1 { print $8 }' "$D/resumes.txt" | sort -u)" = "${TSV##*/}" ]
	[ "$(awk -F'\t' 'NR > 1 { print $7 }' "$D/resumes.txt" | sort -u)" = "ci-a=2/2,ci-b=2/2" ]
	# The reports use the latest attempt: a PROBE_FAILED cell, no INCOMPLETE warning.
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format text
	[[ "$output" != *"are INCOMPLETE"* ]]
}

@test "a narrower --resume names the planned cells it leaves NOT_RUN at its start, with the flags that planned them; its end says NOT_RUN cells have no row" {
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5,6
	[ "$status" -eq 4 ]
	D="$(sweep_dir)"
	TSV="$(find "$D" -maxdepth 1 -name 'controlplane-*.tsv')"
	# The run died before its second cell: no row of svcs=6.
	awk -F'\t' '!(NF >= 40 && $4 == 6)' "$TSV" > "${TSV}.tmp"
	mv "${TSV}.tmp" "$TSV"
	cp_sweep --resume "$D" --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"note: --resume: this run's axis flags leave out 1 planned cell(s) not done yet (never ran, failed or INCOMPLETE), which will not run and count as failed at its end (NOT_RUN, or their last state): mesh=1 svcs=6 reps=3 ns=1 scope=none traffic=none. No cell has run yet: to run them in this resume, stop it now (Ctrl-C) and --resume with the axis flags that planned them (cells already measured are skipped):"$'\n'"  the first run: --mesh-sizes 1 --service-counts 5,6 --replica-counts 3 --namespace-counts 1 --sidecar-scopings none --traffic-configs none"$'\n'* ]]
	# Before the first cell.
	local before="${stderr%%"[1/2] mesh=1 svcs=5"*}"
	[[ "$before" == *"leave out 1 planned cell(s)"* ]]
	[[ "$stderr" == *"error: 2 of 2 cells failed: NOT_RUN x1, PROBE_FAILED x1. The report includes their status rows as placeholder rows (from each cell's latest attempt, in n_total, not n_valid); NOT_RUN cells have no row (planned-cells.txt lists them)"* ]]
}

# ---------------------------------------------------------------------------
# SIGTERM to the sweep process inside a cell

@test "a SIGTERM to the controlplane sweep's process alone reaches its step's whole tree at once (the kubectl it runs and that command's own child are gone when the sweep returns); the cell in progress gets an INTERRUPTED row, the record says SIGTERM, and a --resume runs that cell again" {
	local p f
	CP_TERM=1 cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 143 ] || { echo "status ${status}: ${stderr}"; false; }
	[ -e "${BATS_TEST_TMPDIR}/term-sent" ]
	# The sweep did not wait for its step's stuck command (the stub's 30 s), and did not
	# leave it running: the stub kubectl and its sleep are gone (or a zombie not reaped yet).
	[ ! -e "${BATS_TEST_TMPDIR}/stub-slept" ]
	for f in stub-pid sleep-pid; do
		p="$(<"${BATS_TEST_TMPDIR}/${f}")"
		[[ "$p" =~ ^[0-9]+$ ]]
		[[ "$(ps -o stat= -p "$p" 2>/dev/null | tr -d ' ')" =~ ^(Z.*)?$ ]] || { echo "${f} ${p} still runs"; ps -o pid=,stat=,args= -p "$p"; false; }
	done
	[[ "$stderr" =~ Stopping\ the\ running\ step\ \(002-collect-resource-metrics\.sh\):\ SIGTERM\ to\ its\ [0-9]+\ process ]] || { echo "$stderr"; false; }
	D="$(sweep_dir)"
	TSV="$(find "$D" -maxdepth 1 -name 'controlplane-*.tsv')"
	[ "$(grep -v '^#' "$TSV" | awk -F'\t' '$1 != "timestamp" { print $2 "/" $4 }' | tail -n 1)" = INTERRUPTED/5 ]
	grep -qx 'EXIT=unfinished' "$D/sweep-outcome.txt"
	grep -qx 'ENDED_SIGNAL=SIGTERM' "$D/sweep-outcome.txt"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format text
	[[ "$output" == *"INTERRUPTED"* ]]
	cp_sweep --resume "$D" --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"Sweep [1/1]: mesh=1 svcs=5"* || "$output" == *"Sweep [1/1]: mesh=1 svcs=5"* ]]
	[[ "$stderr" == *"error: 1 of 1 cells failed: PROBE_FAILED x1."* ]]
}

@test "a SIGTERM the controlplane sweep forwards to 002 runs 002's EXIT trap at once: the temp dir it had made is gone, and the sweep still ends on the signal (143)" {
	export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
	mkdir -p "$TMPDIR"
	CP_TERM=1 cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 143 ] || { echo "status ${status}: ${stderr}"; false; }
	# 002 had made its temp dir when the signal came, and its stuck command did not run on.
	grep -q '^controlplane-002\.' "${BATS_TEST_TMPDIR}/tmp-at-term"
	[ ! -e "${BATS_TEST_TMPDIR}/stub-slept" ]
	run find "$TMPDIR" -maxdepth 1 -name 'controlplane-002.*'
	assert_output ""
	grep -qx 'ENDED_SIGNAL=SIGTERM' "$(sweep_dir)/sweep-outcome.txt"
}

@test "every step a sweep runs through sweep_step removes the temp dirs and files it makes at its top level in an EXIT trap, and traps no TERM, INT or HUP (bash runs that EXIT trap on those signals and still dies of them)" {
	local line f var bad="" n=0
	local -A seen=()
	while IFS= read -r line; do
		f="${line%%:*}"
		f="${f%/*}/${line##*/}"
		f="${f%\"}"
		[[ -z "${seen[$f]+x}" ]] || continue
		seen[$f]=1
		[ -f "$f" ] || { bad+=" ${f}:missing"; continue; }
		n=$((n + 1))
		if grep -qE '^[[:space:]]*trap .*[[:space:]](TERM|INT|HUP)([[:space:]]|$)' "$f"; then bad+=" ${f}:signal-trap"; fi
		while IFS= read -r var; do
			grep -qE '^trap .*EXIT$' "$f" || bad+=" ${f}:no-EXIT-trap"
			grep -qE "rm -r?f \"\\\$\\{?${var}(:-)?\\}?\"" "$f" || bad+=" ${f}:${var}"
		done < <(grep -oE '^[A-Za-z_][A-Za-z_0-9]*="?\$\(mktemp' "$f" | sed 's/=.*//')
	done < <(grep -oE 'sweep_step "\$(SCRIPT_DIR|\{TUNING_DIR\})/[0-9]{3}-[a-z0-9-]+\.sh"' "$ROOT"/tests/*/0*.sh)
	[ "$n" -ge 15 ]
	[ -z "$bad" ] || { echo "not removed on exit or a signal trapped:${bad}"; false; }
}

# ---------------------------------------------------------------------------
# Leftovers a legacy cell would measure on

@test "a legacy sweep deletes the controlplane-test namespaces an earlier run left (005-cleanup.sh) before its first cell; it stops before measuring anything when they remain; a cell's stale state dir is gone before 002 reads it" {
	: > "${BATS_TEST_TMPDIR}/ns-left"
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"note: controlplane-test namespaces are left on the members (ci-a: 1) by a run cut short or a growth series. A cell would measure on top of them, and every cell deletes them at its end anyway, so 005-cleanup.sh deletes them now, before the first cell."* ]]
	[[ "$stderr" != *"still on the members after 005-cleanup.sh"* ]]
	[ ! -e "${BATS_TEST_TMPDIR}/ns-left" ]
	# The note comes before the first cell.
	[[ "${stderr%%Sweep [1/1]*}" == *"005-cleanup.sh deletes them now"* || "$output" == *"Sweep [1/1]"* ]]
	D="$(sweep_dir)"
	TSV="$(find "$D" -maxdepth 1 -name 'controlplane-*.tsv')"
	# A --resume reuses the cell's index: a state dir a run cut short left (its peak samples)
	# is removed before 002 reads it.
	mkdir -p "$D/state-combo-1"
	echo 999999999 > "$D/state-combo-1/peak-mem-0.val"
	STALE="$D/state-combo-1/peak-mem-0.val" cp_sweep --resume "$D" --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	[ ! -e "${BATS_TEST_TMPDIR}/stale-seen" ]
	# Namespaces the cleanup cannot delete stop the run before its first cell: nothing is
	# measured, the reason says what to run.
	: > "${BATS_TEST_TMPDIR}/ns-left"
	: > "${BATS_TEST_TMPDIR}/ns-stuck"
	local before
	before="$(grep -vc '^#' "$TSV")"
	cp "$D/sweep-outcome.txt" "${BATS_TEST_TMPDIR}/rec.before"
	cp_sweep --resume "$D" --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"warn: 005-cleanup.sh reported a failure; counting the namespaces again"* ]]
	[[ "$stderr" == *"controlplane-test namespaces are still on the members after 005-cleanup.sh (ci-a: 1: still Terminating, or the delete failed), and a cell would measure on top of them; nothing was measured. Run "*"/005-cleanup.sh --contexts ci-a until it leaves none, then run this command again."* ]]
	[[ "$stderr" != *"Sweep [1/1]"* && "$output" != *"Sweep [1/1]"* ]]
	[ "$(grep -vc '^#' "$TSV")" -eq "$before" ]
	# A precondition of the run (before its start): the sweep's record stays as it was.
	cmp "${BATS_TEST_TMPDIR}/rec.before" "$D/sweep-outcome.txt"
}

@test "a member whose namespaces cannot be counted only warns" {
	# The stub's namespace list fails (as on an unreachable member): no cleanup, a warning.
	sed -i 's|^\*" get namespaces -l app.kubernetes.io/instance=controlplane-test -o json"\*)$|*" get namespaces -l app.kubernetes.io/instance=controlplane-test -o json"*) exit 1 ;;\n*" get namespaces -l never-matches"*)|' "${BIN}/kubectl"
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"warn: could not count the controlplane-test namespaces on ci-a, so a cell there may run on top of an earlier run's"* ]]
	[[ "$stderr" != *"005-cleanup.sh deletes them now"* ]]
}

# ---------------------------------------------------------------------------
# One run per sweep dir

@test "a sweep dir another live run holds (.sweep.lock with its PID) is refused before anything in it changes; a stale lock is taken over; the lock is gone when the run ends" {
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	D="$(sweep_dir)"
	[ ! -e "$D/.sweep.lock" ]
	cp "$D/sweep-outcome.txt" "${BATS_TEST_TMPDIR}/rec.before"
	ls -la "$D" | awk '{ print $5, $NF }' > "${BATS_TEST_TMPDIR}/ls.before"
	# A live PID (this test's shell) holds it.
	echo "$$" > "$D/.sweep.lock"
	cp_sweep --resume "$D" --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"another run of this sweep (PID $$) still runs in ${D}: wait for it to end, or stop it, before you start or --resume a run there (nothing was changed). If no such run exists (the host restarted and that PID is another process now), remove ${D}/.sweep.lock and run again."* ]]
	cmp "${BATS_TEST_TMPDIR}/rec.before" "$D/sweep-outcome.txt"
	[ ! -e "$D/sweep-outcome.prev.txt" ]
	[ ! -e "$D/resumes.txt" ]
	[ "$(<"$D/.sweep.lock")" = "$$" ]
	# A PID that no longer runs: a stale lock, taken over; the run removes it at its end.
	local dead
	bash -c 'exit 0' &
	dead=$!
	wait "$dead" || true
	echo "$dead" > "$D/.sweep.lock"
	cp_sweep --resume "$D" --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	[ ! -e "$D/.sweep.lock" ]
	[ -s "$D/resumes.txt" ]
}

@test "sweep_lock: a second shell is refused while the first holds the lock; the holder takes it again; _sweep_unlock removes only its own" {
	local d="${BATS_TEST_TMPDIR}/lockdir"
	run bash -c '
		source "$ROOT/tests/lib/common.sh"
		sweep_lock "$1"; sweep_lock "$1"; echo "held=$(cat "$1/.sweep.lock") me=$$"
		( sweep_lock "$1" ) 2>&1 | sed "s/(PID [0-9]*)/(PID n)/"
		echo 12345678 > "$1/.sweep.lock.other"
		_sweep_unlock; [ ! -e "$1/.sweep.lock" ] && echo unlocked' _ "$d"
	assert_success
	[[ "${lines[0]}" =~ ^held=([0-9]+)\ me=([0-9]+)$ && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]]
	assert_line --index 1 --partial "error: another run of this sweep (PID n) still runs in ${d}"
	assert_line --index 2 unlocked
	# A lock someone else wrote after ours is not removed.
	run bash -c '
		source "$ROOT/tests/lib/common.sh"
		sweep_lock "$1"; echo 1 > "$1/.sweep.lock"; _sweep_unlock; cat "$1/.sweep.lock"' _ "$d"
	assert_success
	assert_output 1
}

# ---------------------------------------------------------------------------
# NOT_RUN and INCOMPLETE in the SLA verdict

@test "env_sla_verdict: NOT_RUN (arg 10) and INCOMPLETE (arg 11) turn a PASS into CAUTION and join a CAUTION or FAIL reason" {
	run env_sla_verdict 10 15 40 50 0 4 4 75 90 0 0
	[[ "$output" == PASS\|* ]]
	run env_sla_verdict 10 15 40 50 0 4 4 75 90 2 0
	[[ "$output" == "CAUTION|2 planned cell(s) never ran (NOT_RUN), so the sweep covers only part of its plan; the cells that ran: "* ]]
	run env_sla_verdict 10 15 40 50 0 4 4 75 90 0 1
	[[ "$output" == "CAUTION|1 cell(s) are INCOMPLETE (rows of fewer members than their mesh size, or a member with fewer rows than its window wrote: cut short while they were written), so their figures cover part of the mesh; the figures, these cells included: "* ]]
	run env_sla_verdict 10 15 40 50 0 4 4 75 90 2 1
	[[ "$output" == "CAUTION|2 planned cell(s) never ran (NOT_RUN), "*"; also 1 cell(s) are INCOMPLETE (rows of fewer members than their mesh size, or a member with fewer rows than its window wrote)" ]]
	run env_sla_verdict 80 15 40 50 0 4 4 75 90 1 1
	[[ "$output" == CAUTION\|* && "$output" == *"; also 1 planned cell(s) never ran (NOT_RUN); also 1 cell(s) are INCOMPLETE (rows of fewer members than their mesh size, or a member with fewer rows than its window wrote)" ]]
	run env_sla_verdict 95 15 40 50 0 4 4 75 90 3 0
	[[ "$output" == FAIL\|* && "$output" == *"; also 3 planned cell(s) never ran (NOT_RUN)" ]]
	# Not a count: 0.
	run env_sla_verdict 10 15 40 50 0 4 4 75 90 x y
	[[ "$output" == PASS\|* ]]
}

@test "a planned cell that never ran (NOT_RUN) makes the verdict CAUTION in every 004 format and in the scale envelope" {
	incomplete_dir
	# Drop svcs=6: a planned cell with no row.
	awk -F'\t' '/^#/ || $1 == "timestamp" || $4 != 6' "$TSV" > "${TSV}.new"
	mv "${TSV}.new" "$TSV"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format json
	assert_success
	[ "$(jq -r '.metadata.sla.verdict' <<<"$output")" = CAUTION ]
	[[ "$(jq -r '.metadata.sla.headline' <<<"$output")" == "1 planned cell(s) never ran (NOT_RUN), so the sweep covers only part of its plan"* ]]
	local fmt
	for fmt in text markdown; do
		run --separate-stderr bash "$REPORT" --results-dir "$D" --format "$fmt"
		assert_success
		[[ "$output" == *CAUTION* && "$output" == *"1 planned cell(s) never ran (NOT_RUN), so the sweep covers only part of its plan"* ]] || { echo "${fmt}: ${output}"; false; }
	done
	source "${ROOT}/tests/lib/platform.sh"
	run --separate-stderr render_scale_envelope "$D" "$REPORT" "ci-a,ci-b" false
	assert_success
	assert_output --partial CAUTION
	assert_output --partial "1 planned cell(s) never ran (NOT_RUN)"
	refute_output --partial "PASS"
	# With the cell measured on both members: PASS.
	{
		cp_row 2026-06-01T00:02:00+00:00 ci-a 2 6 900
		cp_row 2026-06-01T00:02:00+00:00 ci-b 2 6 900
	} >> "$TSV"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format json
	[ "$(jq -r '.metadata.sla.verdict' <<<"$output")" = PASS ]
}

# ---------------------------------------------------------------------------
# The attempts in controlplane 004

@test "controlplane 004 names each attempt (its HARNESS_SHA and KUBE_VERSIONS) and REPORT_HARNESS_SHA in every format; a resume's harness joins harness_shas and the provenance warning, and one on other Kubernetes versions warns" {
	local first ra rh c0 c1
	incomplete_dir
	cp_sweep --resume "$D" --contexts ci-a,ci-b --mesh-sizes 2 --service-counts 5,6
	[ "$status" -eq 4 ]
	# The first run read v1.30.0 on both members; the resume ran another harness and read
	# v1.31.0 on ci-a.
	sed -i 's/^# KUBE_VERSIONS=.*/# KUBE_VERSIONS=ci-a=v1.30.0,ci-b=v1.30.0/' "$TSV"
	sed -i 's/^\(# RESUMED_AT=[^ ]* TSV_LINES=[0-9]*\) HARNESS_SHA=.*/\1 HARNESS_SHA=abc1234/' "$TSV"
	awk -F'\t' -v OFS='\t' 'NR > 1 { $2 = "abc1234"; $4 = "ci-a=v1.31.0,ci-b=v1.30.0"; if (NF >= 9) $9 = "000000000000" } { print }' "$D/resumes.txt" > "${BATS_TEST_TMPDIR}/r.txt"
	mv "${BATS_TEST_TMPDIR}/r.txt" "$D/resumes.txt"
	first="$(sed -n 's/^# HARNESS_SHA=//p' "$TSV" | head -n 1)"
	# The attempt labels print its time with Z.
	ra="$(awk -F'\t' 'NR == 2 { t = $1; sub(/\+00:00$/, "Z", t); print t }' "$D/resumes.txt")"
	rh="$(harness_sha)"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format json
	assert_success
	[ "$(jq -c '.metadata.attempts | map([.run, .harness_sha, .kube_versions])' <<<"$output")" = \
		"[[\"first run\",\"${first}\",\"ci-a=v1.30.0,ci-b=v1.30.0\"],[\"--resume at ${ra}\",\"abc1234\",\"ci-a=v1.31.0,ci-b=v1.30.0\"]]" ]
	[ "$(jq -c '.metadata.harness_shas' <<<"$output")" = "[\"${first}\",\"abc1234\"]" ]
	[ "$(jq -r '.metadata.harness_sha' <<<"$output")" = "mixed:${first},abc1234" ]
	[ "$(jq -r '.metadata.report_harness_sha' <<<"$output")" = "$rh" ]
	[[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" == *"ran on different harnesses (HARNESS_SHA ${first},abc1234; a --resume's included, see the attempts)"* ]]
	[[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" == *"A --resume ran on other Kubernetes server versions than the first run (ci-a v1.30.0 in the first run, v1.31.0 at the --resume at ${ra})"* ]]
	[[ "$stderr" == *"WARNING: "*"ran on different harnesses"* ]]
	# Every format but json gives each attempt's rows as json does (rows, rows_kept).
	c0="$(jq -r '.metadata.attempts[0] | "\(.rows) row(s), \(.rows_kept) in the figures"' <<<"$output")"
	c1="$(jq -r '.metadata.attempts[1] | "\(.rows) row(s), \(.rows_kept) in the figures"' <<<"$output")"
	# And the first run's values (the TSV preamble's), as json's attempts[0] has them.
	local v0
	v0="$(jq -r '.metadata.attempts[0] | "HARNESS_SHA=\(.harness_sha) KUBE_VERSIONS=\(.kube_versions)"' <<<"$output")"
	local att="the rows come from more than one run: the first run ${v0} (${c0}), then --resume at ${ra} HARNESS_SHA=abc1234 KUBE_VERSIONS=ci-a=v1.31.0,ci-b=v1.30.0 (${c1})"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format text
	assert_line "# attempts: ${att}"
	assert_output --partial "REPORT_HARNESS_SHA=${rh}"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format csv
	assert_line "# attempts: ${att}"
	assert_output --partial "REPORT_HARNESS_SHA=${rh}"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format markdown
	assert_output --partial "> **Attempts:** ${att}"
	assert_line "report_harness_sha: \"${rh}\""
	assert_line --partial "attempts: [{"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format charts
	assert_line "report_harness_sha: \"${rh}\""
	assert_line --partial "attempts: [{"
}

@test "an attempt boundary is the TSV's own # RESUMED_AT line or a resumes.txt line of this TSV (one naming another TSV does not apply); rows after a status row with no boundary warn that two attempts are pooled" {
	local n
	incomplete_dir
	# svcs=6: ci-a's row, then a status row (it failed partway), then a valid row of each member.
	grep "	6	3	1	none	" "${BATS_TEST_TMPDIR}/status.rows" >> "$TSV"
	n="$(wc -l < "$TSV" | tr -d ' ')"
	cp "$TSV" "${BATS_TEST_TMPDIR}/head.tsv"
	{
		cp_row 2026-06-01T00:05:00+00:00 ci-a 2 6 800
		cp_row 2026-06-01T00:05:00+00:00 ci-b 2 6 800
	} > "${BATS_TEST_TMPDIR}/attempt2.rows"
	cat "${BATS_TEST_TMPDIR}/attempt2.rows" >> "$TSV"
	# No boundary: pooled, with a warning in every format.
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format json
	assert_success
	[ "$(jq -r '.metadata.earlier_attempt_rows_left_out' <<<"$output")" = 0 ]
	jq -e '[.metadata.data_warnings[] | select(startswith("1 cell(s) have rows after a status row of their own with no recorded --resume start between them"))] | length == 1' <<<"$output"
	local fmt
	for fmt in text markdown csv charts; do
		run --separate-stderr bash "$REPORT" --results-dir "$D" --format "$fmt"
		[[ "$output" == *"1 cell(s) have rows after a status row of their own with no recorded --resume start between them"*"mesh=2 svcs=6"* ]] || { echo "${fmt}: ${output}"; false; }
	done
	# A resumes.txt line of another TSV: still no boundary.
	# The resume ran the first run's harness (a mix of harnesses would make the verdict CAUTION).
	printf 'RESUMED_AT\tHARNESS_SHA\tISTIO_NOTREADY_AT_RESUME\tKUBE_VERSIONS\tTSV_LINES\tISTIO_PROXY_VERSIONS\tISTIO_GENERATIONS\tTSV\n2026-06-01T00:04:00+00:00\t%s\tnone\tci-a=unknown\t%s\tunknown\tunknown\tcontrolplane-other.tsv\n' \
		"$(sed -n 's/^# HARNESS_SHA=//p' "$TSV" | head -n 1)" "$n" > "$D/resumes.txt"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format json
	[ "$(jq -r '.metadata.earlier_attempt_rows_left_out' <<<"$output")" = 0 ]
	[ "$(jq -r '.metadata.attempts | length' <<<"$output")" = 1 ]
	jq -e '[.metadata.data_warnings[] | select(startswith("1 cell(s) have rows after a status row"))] | length == 1' <<<"$output"
	# The same line for this TSV: two attempts, the earlier one's rows left out, no warning.
	sed -i "s/controlplane-other.tsv/${TSV##*/}/" "$D/resumes.txt"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format json
	[ "$(jq -c '[.metadata.earlier_attempt_rows_left_out, .metadata.earlier_attempt_cells, (.metadata.attempts | length)]' <<<"$output")" = '[2,1,2]' ]
	jq -e '[.metadata.data_warnings[]? | select(startswith("1 cell(s) have rows after a status row"))] | length == 0' <<<"$output"
	[ "$(jq -r '.metadata.sla.verdict' <<<"$output")" = PASS ]
	# Without resumes.txt, the TSV's own line is that boundary (a copied TSV).
	rm -f "$D/resumes.txt"
	{
		cat "${BATS_TEST_TMPDIR}/head.tsv"
		printf '# RESUMED_AT=2026-06-01T00:04:00+00:00 TSV_LINES=%s HARNESS_SHA=fixture\n' "$n"
		cat "${BATS_TEST_TMPDIR}/attempt2.rows"
	} > "$TSV"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format json
	[ "$(jq -c '[.metadata.earlier_attempt_rows_left_out, .metadata.earlier_attempt_cells, (.metadata.attempts | length), .metadata.attempts[1].kube_versions]' <<<"$output")" = '[2,1,2,"unknown"]' ]
	jq -e '[.metadata.data_warnings[]? | select(startswith("1 cell(s) have rows after a status row"))] | length == 0' <<<"$output"
}

# ---------------------------------------------------------------------------
# Merged values in markdown cells; proxy versions pooled by their set

@test "a merged value whose parts hold commas (mixed:a | b) stays in one markdown table cell in controlplane 004 and the scale envelope" {
	incomplete_dir
	# A second TSV of the same run whose members connected another proxy version.
	sed 's/^# ISTIO_PROXY_VERSIONS=.*/# ISTIO_PROXY_VERSIONS=ci-a=1.31.0:7,ci-b=1.31.0:9/' "$TSV" > "${TSV%.tsv}-b.tsv"
	sed -i 's/^# ISTIO_PROXY_VERSIONS=.*/# ISTIO_PROXY_VERSIONS=ci-a=1.30.5:3,ci-b=1.30.5:4/' "$TSV"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format markdown
	assert_success
	assert_line --regexp '^\| proxy versions at start \(connected to istiod, summed over the members\) \| mixed:ci-a=1\.3[01]\.[05]:[0-9],ci-b=1\.3[01]\.[05]:[0-9] \\\| ci-a=1\.3[01]\.[05]:[0-9],ci-b=1\.3[01]\.[05]:[0-9] \|$'
	source "${ROOT}/tests/lib/platform.sh"
	run --separate-stderr render_scale_envelope "$D" "$REPORT" "ci-a,ci-b" false
	assert_success
	assert_line --regexp '^\| Proxy \(Envoy\) versions at the start \| mixed:ci-a=[^|]* \\\| ci-a=[^|]* \| '
}

@test "pooled ISTIO_PROXY_VERSIONS compare by version set: the same versions with other proxy counts are one value (shown without counts), other versions are mixed" {
	local d="${BATS_TEST_TMPDIR}/pv-pooled"
	mkdir -p "$d"
	printf '# RUN_ID=r1\n# ISTIO_PROXY_VERSIONS=ci-a=1.30.5:30+1.30.4:2,ci-b=1.30.5:34\ntimestamp\tx\n' > "$d/a.tsv"
	printf '# RUN_ID=r1\n# ISTIO_PROXY_VERSIONS=ci-a=1.30.4:1+1.30.5:31,ci-b=1.30.5:34\ntimestamp\tx\n' > "$d/b.tsv"
	printf '# RUN_ID=r1\n# ISTIO_PROXY_VERSIONS=ci-a=1.30.5:30+1.30.4:2,ci-b=1.30.5:34\ntimestamp\tx\n' > "$d/c.tsv"
	printf '# RUN_ID=r1\n# ISTIO_PROXY_VERSIONS=ci-a=1.31.0:30,ci-b=1.30.5:34\ntimestamp\tx\n' > "$d/d.tsv"
	run config_merged_preamble "$d/a.tsv" "$d/b.tsv"
	assert_line "ISTIO_PROXY_VERSIONS=ci-a=1.30.4+1.30.5,ci-b=1.30.5"
	run env_proxy_versions_summary "ci-a=1.30.4+1.30.5,ci-b=1.30.5"
	assert_output "1.30.4, 1.30.5 (2 members; proxy counts differ between the pooled runs)"
	# The same counts: the value as it is.
	run config_merged_preamble "$d/a.tsv" "$d/c.tsv"
	assert_line "ISTIO_PROXY_VERSIONS=ci-a=1.30.5:30+1.30.4:2,ci-b=1.30.5:34"
	# Another version: mixed.
	run config_merged_preamble "$d/a.tsv" "$d/b.tsv" "$d/d.tsv"
	assert_line "ISTIO_PROXY_VERSIONS=mixed:ci-a=1.30.4+1.30.5,ci-b=1.30.5 | ci-a=1.31.0:30,ci-b=1.30.5:34"
	# A member that could not be read stays unknown, not a version.
	run env_proxy_versions_summary "ci-a=1.30.5:120+1.30.4:3,ci-b=1.30.5:5,ci-c=none,ci-d=unknown"
	assert_output "1.30.5: 125, 1.30.4: 3 (4 members; 1 with none; 1 unknown)"
	run env_proxy_versions_summary "ci-a=1.30.5+1.30.4,ci-b=1.30.5,ci-c=unknown"
	assert_output "1.30.5, 1.30.4 (3 members; 1 unknown; proxy counts differ between the pooled runs)"
}

# ---------------------------------------------------------------------------
# HARNESS_SHA from the tree's content

@test "HARNESS_SHA hashes the uncommitted content: git config does not change it, editor and Finder files and a global core.excludesFile's do not count, staged equals unstaged, a sweep's output dir is left out (also for its steps), and a step after a change records the changed tree" {
	local r="${BATS_TEST_TMPDIR}/repo" clean a
	mkdir -p "$r/tests/sub"
	git -C "$r" init -q
	printf 'one\ntwo\nthree\n' > "$r/tests/f"
	cp "${ROOT}/.gitignore" "$r/.gitignore"
	git -C "$r" add tests/f .gitignore
	git -C "$r" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -q -m init
	clean="$(ROOT="$r" harness_sha)"
	[[ "$clean" =~ ^[0-9a-f]{7}$ ]]
	# Editor swap and backup files and Finder metadata: ignored (.gitignore).
	: > "$r/.DS_Store"
	: > "$r/tests/sub/.f.swp"
	: > "$r/tests/f.swo"
	: > "$r/tests/f~"
	[ "$(ROOT="$r" harness_sha)" = "$clean" ]
	printf 'one\nTWO\nthree\n' > "$r/tests/f"
	a="$(ROOT="$r" harness_sha)"
	[[ "$a" =~ ^${clean}-dirty\.[0-9a-f]{8}$ ]]
	# The operator's git config (diff options, abbrev, line endings) does not change it.
	[ "$(GIT_CONFIG_COUNT=4 GIT_CONFIG_KEY_0=diff.context GIT_CONFIG_VALUE_0=0 GIT_CONFIG_KEY_1=core.abbrev GIT_CONFIG_VALUE_1=12 \
		GIT_CONFIG_KEY_2=diff.noprefix GIT_CONFIG_VALUE_2=true GIT_CONFIG_KEY_3=core.autocrlf GIT_CONFIG_VALUE_3=true ROOT="$r" harness_sha)" = "$a" ]
	# An untracked file counts, unless the operator's global core.excludesFile ignores it.
	: > "$r/tests/x.local"
	[ "$(ROOT="$r" harness_sha)" != "$a" ]
	printf '*.local\n' > "${BATS_TEST_TMPDIR}/excludes"
	[ "$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.excludesFile GIT_CONFIG_VALUE_0="${BATS_TEST_TMPDIR}/excludes" ROOT="$r" harness_sha)" = "$a" ]
	rm -f "$r/tests/x.local"
	# Staged or not: one value; the operator's index is not touched.
	git -C "$r" add tests/f
	[ "$(ROOT="$r" harness_sha)" = "$a" ]
	[ "$(git -C "$r" diff --cached --name-only)" = tests/f ]
	# A sweep's output dir under the checkout is left out.
	mkdir -p "$r/tests/out/sweep-x"
	echo row > "$r/tests/out/sweep-x/data.tsv"
	[ "$(ROOT="$r" harness_sha)" != "$a" ]
	[ "$(ROOT="$r" harness_sha --exclude "$r/tests/out")" = "$a" ]
	# harness_sha_for_sweep: the sweep's start value; it exports its output dir, never the
	# value, so a step leaves the sweep's results out and records the live tree: after a
	# file changed during the sweep, the changed one.
	run bash -c '
		source "$2/tests/lib/common.sh"
		ROOT="$1"
		harness_sha_for_sweep "$1/tests/out"
		echo "$HARNESS_SHA"
		echo "$HARNESS_SHA_EXCLUDE"
		ROOT="$1" bash -c "source \"$2/tests/lib/common.sh\"; harness_sha"
		echo changed >> "$1/tests/f"
		ROOT="$1" bash -c "source \"$2/tests/lib/common.sh\"; harness_sha"' _ "$r" "$ROOT"
	assert_success
	assert_line --index 0 "$a"
	assert_line --index 1 "$r/tests/out"
	assert_line --index 2 "$a"
	[[ "${lines[3]}" =~ ^${clean}-dirty\.[0-9a-f]{8}$ && "${lines[3]}" != "$a" ]]
}

# _hs <checkout>: its harness_sha without and with pipefail, which must agree.
_hs() {
	local x y
	x="$(set +o pipefail; ROOT="$1" harness_sha)"
	y="$(set -o pipefail; ROOT="$1" harness_sha)"
	[ "$x" = "$y" ] || { echo "pipefail changes harness_sha: ${x} vs ${y}" >&2; return 1; }
	printf '%s\n' "$x"
}

@test "a submodule never makes HARNESS_SHA dirty (moved, not checked out, its gitdir gone, or copied without its .git), with or without pipefail; a tree that cannot be hashed reads -dirty.unknown only when its tracked files differ" {
	local r="${BATS_TEST_TMPDIR}/repo" s="${BATS_TEST_TMPDIR}/sub" clean a
	git -C "$BATS_TEST_TMPDIR" init -q sub
	git -C "$s" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -q --allow-empty -m one
	git -C "$BATS_TEST_TMPDIR" init -q repo
	mkdir -p "$r/tests"
	echo a > "$r/tests/f"
	git -C "$r" add tests/f
	# A submodule at tests/mods/sub (as the bats checkouts): its gitlink, at the sub repo's commit.
	git -C "$r" update-index --add --cacheinfo "160000,$(git -C "$s" rev-parse HEAD),tests/mods/sub"
	git -C "$r" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -q -m init
	clean="$(_hs "$r")"
	[[ "$clean" =~ ^[0-9a-f]{7}$ ]]
	# Not checked out (no dir), as a fresh clone without submodule init.
	[ ! -e "$r/tests/mods/sub" ]
	[ "$(_hs "$r")" = "$clean" ]
	# Checked out at another commit.
	git clone -q "$s" "$r/tests/mods/sub"
	git -C "$r/tests/mods/sub" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -q --allow-empty -m two
	[ "$(_hs "$r")" = "$clean" ]
	# Its gitdir gone (a worktree whose .git/modules is not there): git describe --dirty
	# fails on such a tree; the harness still reads clean.
	rm -rf "$r/tests/mods/sub"
	mkdir -p "$r/tests/mods/sub"
	echo 'gitdir: ../../../.git/modules/tests/mods/sub' > "$r/tests/mods/sub/.git"
	echo x > "$r/tests/mods/sub/file"
	[ "$(_hs "$r")" = "$clean" ]
	# A tracked edit: dirty, by the same hash whatever state the submodule is in.
	echo b > "$r/tests/f"
	a="$(_hs "$r")"
	[[ "$a" =~ ^${clean}-dirty\.[0-9a-f]{8}$ ]]
	rm -rf "$r/tests/mods/sub"
	mkdir -p "$r/tests/mods/sub"
	echo x > "$r/tests/mods/sub/file"
	[ "$(_hs "$r")" = "$a" ]
	# Content that cannot be hashed (no temp dir): -dirty.unknown while a tracked file
	# differs from HEAD, clean once it does not.
	[ "$(TMPDIR="${BATS_TEST_TMPDIR}/none" _hs "$r")" = "${clean}-dirty.unknown" ]
	echo a > "$r/tests/f"
	[ "$(TMPDIR="${BATS_TEST_TMPDIR}/none" _hs "$r")" = "$clean" ]
}

# ---------------------------------------------------------------------------
# A --resume that stops

@test "a --resume that stops records its reason without local paths and names the sweep dir on the console; every 004 format leads with the stop (STOPPED) and then shows the outcome before it; the charts warn" {
	local rid
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 4 ]
	D="$(sweep_dir)"
	rid="${D##*/sweep-}"
	# Its plan file cannot be written: a stop after the resume's start.
	rm -f "$D/planned-cells.txt"
	mkdir "$D/planned-cells.txt"
	cp_sweep --resume "$D" --contexts ci-a --mesh-sizes 1 --service-counts 5
	[ "$status" -eq 1 ]
	# The console keeps the full path, and names the sweep dir after the stop, then the next
	# step with that path (SWEEP_NEXT_CONSOLE; the record keeps "<sweep dir>"), once.
	[[ "$stderr" == *"error: could not write ${D}/planned-cells.txt, which records the cells this sweep plans; nothing was run."* ]]
	[[ "$stderr" == *"  sweep dir: ${D}"$'\n'"  next: ./tests/controlplane/003-run-sweep.sh --resume ${D} --contexts ci-a --mesh-sizes 1 --service-counts 5 --replica-counts 3 --namespace-counts 1 --sidecar-scopings none --traffic-configs none" ]]
	[[ "$stderr" != *"next: --resume this sweep dir"* ]]
	# The record (shared) does not.
	grep -qxF "NOTE=next: --resume this sweep dir with the flags it ran with (the cells already measured are kept): ./tests/controlplane/003-run-sweep.sh --resume <sweep dir> --contexts ci-a --mesh-sizes 1 --service-counts 5 --replica-counts 3 --namespace-counts 1 --sidecar-scopings none --traffic-configs none (<sweep dir> is this sweep's directory)" "$D/sweep-outcome.txt"
	grep -qx 'STOP_REASON=could not write <sweep dir>/planned-cells.txt, which records the cells this sweep plans; nothing was run.' "$D/sweep-outcome.txt"
	! grep -qF "$BATS_TEST_TMPDIR" "$D/sweep-outcome.txt" || false
	grep -qx 'CUT_SHORT=1' "$D/sweep-outcome.txt"
	grep -q '^RESUMED_AT=' "$D/sweep-outcome.txt"
	grep -qx 'EXIT=4' "$D/sweep-outcome.prev.txt"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format text
	assert_line "# SWEEP OUTCOME (recorded in sweep-outcome.txt by run ${rid}, exit 1): STOPPED"
	assert_line --index "$(( $(printf '%s\n' "${lines[@]}" | grep -n '^# SWEEP OUTCOME (recorded in sweep-outcome.txt' | cut -d: -f1) ))" \
		"#   stopped early: could not write <sweep dir>/planned-cells.txt, which records the cells this sweep plans; nothing was run."
	assert_line "# OUTCOME BEFORE THIS --RESUME (recorded in sweep-outcome.prev.txt by run ${rid}, exit 4):"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format markdown
	assert_output --partial "(recorded in \`sweep-outcome.txt\` by run \`${rid}\`, exit 1): **stopped**"$'\n'"> - stopped early: could not write <sweep dir>/planned-cells.txt"
	assert_output --partial "> **Outcome before this --resume** (recorded in \`sweep-outcome.prev.txt\` by run \`${rid}\`, exit 4):"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format csv
	assert_line "# SWEEP_OUTCOME_EXIT=1"
	assert_line --regexp '^# SWEEP_OUTCOME_RESUMED_AT=.'
	assert_line "# SWEEP_OUTCOME_EARLIER_EXIT=4"
	assert_line "# SWEEP_OUTCOME_EARLIER_FAILED_BY=PROBE_FAILED x1"
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format json
	[ "$(jq -c '.sweep_outcome | [.exit, .stopped, (.resumed_at != null), .earlier.exit, .earlier.failed_by]' <<<"$output")" = '[1,true,true,4,"PROBE_FAILED x1"]' ]
	[[ "$(jq -r '.sweep_outcome.stop_reason' <<<"$output")" == "could not write <sweep dir>/planned-cells.txt"* ]]
	run --separate-stderr bash "$REPORT" --results-dir "$D" --format charts
	assert_output --partial "> **Warning:** this sweep stopped early: could not write <sweep dir>/planned-cells.txt, which records the cells this sweep plans; nothing was run. These charts may show partial results (sweep-outcome.txt); the markdown report says what to do."
}

@test "a stop reason names the home dir as ~ in the record; the console keeps the path" {
	local d="${BATS_TEST_TMPDIR}/home/u/results/sweep-x"
	mkdir -p "$d"
	HOME="${BATS_TEST_TMPDIR}/home/u" run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"
		trap "sweep_outcome_on_exit \$? || true" EXIT
		sweep_outcome_start "$1" rid-1
		die "cannot read ${HOME}/.kube/config for $1/x"' _ "$d"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"error: cannot read ${BATS_TEST_TMPDIR}/home/u/.kube/config for ${d}/x"* ]]
	grep -qx 'STOP_REASON=cannot read ~/.kube/config for <sweep dir>/x' "$d/sweep-outcome.txt"
}

# ---------------------------------------------------------------------------
# Who the operator is, and what bumped a generation

@test "masked kubectl errors name no user, email or home dir; a generation-only change names its likely causes; the console says the errors are masked" {
	run _istio_version_mask 'Error from server (Forbidden): istios.sailoperator.io "default" is forbidden: User "jdoe" cannot get resource'
	assert_output 'Error from server (Forbidden): istios.sailoperator.io "default" is forbidden: User "<user>" cannot get resource'
	run _istio_version_mask 'error: you must be logged in as someone@example.com (/home/jdoe/.kube/config; /Users/jdoe/x)'
	assert_output 'error: you must be logged in as <email> (<home>/.kube/config; <home>/x)'
	run _istio_version_mask 'error: unable to read client-key /tmp/k for kube-admin due to open /tmp/k: no such file'
	assert_output 'error: unable to read client-key /tmp/k for <user> due to open /tmp/k: no such file'
	run istio_generation_causes 1
	assert_output "a version changed and changed back, or a values change (an edit of the Istio CR)"
	run istio_generation_causes 0
	assert_output --partial "an OSSM operator upgrade (installPlanApproval Automatic on its Subscription, charts/spoke-ossm-operator) or a change of the cluster's TLS security profile"
	# Through istio_version_recheck: only the IstioRevision moved.
	run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		export ISTIO_VERSION=v1.30.5 ISTIO_VERSION_READY_WAIT_SEC=0
		istio_version_resolve ci-a 0 "$1" 2>/dev/null
		export STUB_ISTIO_REV_GEN=5
		out=(); istio_version_recheck out "$1"; printf "%s\n" "${out[@]}"' _ "${ROOT}/tests/lib/test/fixtures/fake-istio-cr.sh"
	assert_line --index 1 --partial "(ci-a: its IstioRevision default (generation 2 at the start, 5 at the end); ISTIO_GENERATIONS): only the IstioRevision moved, which is usually Sail rendering it again: an OSSM operator upgrade"
	# istio_generations_diff: what moved, and whether the Istio CR did.
	run istio_generations_diff "ci-a=2/2,ci-b=3/3,ci-c=unknown/unknown" "ci-a=2/2,ci-b=3/4,ci-c=4/4"
	assert_output "$(printf '0\tci-b (IstioRevision generation 3 -> 4)')"
	run istio_generations_diff "ci-a=2/2" "ci-a=3/3"
	assert_output "$(printf '1\tci-a (Istio CR generation 2 -> 3, IstioRevision generation 2 -> 3)')"
	run istio_generations_diff "ci-a=2/2" "ci-a=2/2"
	assert_output ""
	# The start's warning says the errors it quotes are masked, and where the full one is.
	printf '#!/bin/sh\necho "Unable to connect to the server: dial tcp 192.0.2.10:6443: i/o timeout" >&2\nexit 1\n' > "${BIN}/kubectl"
	run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		export ISTIO_VERSION=v1.30.5 ISTIO_VERSION_READY_WAIT_SEC=0 ISTIO_VERSION_CHECK=warn
		istio_version_resolve ci-a 0 "$1"' _ "${BIN}/kubectl"
	[[ "$stderr" == *"dial tcp <ip>: i/o timeout"* ]]
	[[ "$stderr" != *"192.0.2.10"* ]]
	[[ "$stderr" == *$'\n'"  (API hosts, addresses, user names and home dirs are masked above; run a reproduce line for the full error)"$'\n'* ]]
}

# ---------------------------------------------------------------------------
# A signal reaches the sweep's step at once

# _sig_sweep <dir>: a sweep (sweep_outcome_start, its EXIT trap; record in <dir>/rec) whose
# one step runs through sweep_step: a script that writes the signal it gets to step-got,
# else waits 30 s (a long step) and touches step-done. STEP_SELF_INT=1: once started, the
# step sends SIGINT to its process group.
_sig_sweep() {
	local d="$1"
	mkdir -p "$d/rec"
	cat > "$d/step.sh" <<'STEP'
#!/usr/bin/env bash
trap 'echo TERM > "$1/step-got"; kill "$sp" 2>/dev/null; exit 143' TERM
trap 'echo INT > "$1/step-got"; kill "$sp" 2>/dev/null; exit 130' INT
sleep 30 </dev/null >/dev/null 2>&1 &
sp=$!
echo "$sp" > "$1/sleep-pid"
: > "$1/started"
# STEP_SELF_INT: Ctrl-C, as a terminal sends it: SIGINT to the step's process group (the
# sweep's).
[ -z "${STEP_SELF_INT:-}" ] || kill -INT 0
wait "$sp"
: > "$1/step-done"
STEP
	cat > "$d/sweep.sh" <<'SWEEP'
#!/usr/bin/env bash
set -euo pipefail
source "$ROOT/tests/lib/common.sh"
trap 'sweep_outcome_on_exit "$?" || true' EXIT
sweep_outcome_start "$1/rec" t-run --next "run it again"
sweep_step "$1/step.sh" "$1"
: > "$1/sweep-continued"
SWEEP
	chmod +x "$d/step.sh" "$d/sweep.sh"
}

# _wait_file <path>: until it exists (bounded: 300 polls).
_wait_file() {
	local i
	for ((i = 0; i < 300; i++)); do
		[[ -e "$1" ]] && return 0
		sleep 0.1
	done
	return 1
}

@test "sweep_step: SIGTERM sent to the sweep's process alone is forwarded to its step at once; Ctrl-C (SIGINT to the process group) reaches the step; a function is refused (exit 127)" {
	local d="${BATS_TEST_TMPDIR}/sig-term" p rc=0
	_sig_sweep "$d"
	bash "$d/sweep.sh" "$d" 2> "$d/err" &
	p=$!
	_wait_file "$d/started"
	kill -TERM "$p"
	wait "$p" || rc=$?
	[ "$rc" -eq 143 ]
	[ "$(<"$d/step-got")" = TERM ]
	[ ! -e "$d/step-done" ]
	[ ! -e "$d/sweep-continued" ]
	grep -qx 'EXIT=unfinished' "$d/rec/sweep-outcome.txt"
	grep -qx 'ENDED_SIGNAL=SIGTERM' "$d/rec/sweep-outcome.txt"
	grep -qx 'ENDED_EXIT=143' "$d/rec/sweep-outcome.txt"
	[[ "$(<"$d/err")" == *"warning: the sweep was interrupted (SIGTERM, exit 143) before its outcome; sweep-outcome.txt says it has not finished"$'\n'"  sweep dir: ${d}/rec; next: run it again"* ]]
	# Ctrl-C: SIGINT to the sweep's process group.
	[[ "$(bash -c 'trap "echo t" INT; kill -INT $$; echo n' 2>/dev/null)" == t* ]] || skip "SIGINT is ignored here"
	d="${BATS_TEST_TMPDIR}/sig-int"
	_sig_sweep "$d"
	# The sweep in a process group of its own (a job: set -m), as a terminal runs it.
	STEP_SELF_INT=1 run bash -c 'set -m; bash "$1" "$2" 2> "$2/err" & wait "$!"' _ "$d/sweep.sh" "$d"
	[ "$status" -eq 130 ]
	[ "$(<"$d/step-got")" = INT ]
	[ ! -e "$d/sweep-continued" ]
	grep -qx 'ENDED_SIGNAL=SIGINT' "$d/rec/sweep-outcome.txt"
	# A function cannot be exec'd: the step fails (127), so a caller sees it.
	run bash -c 'source "$ROOT/tests/lib/common.sh"; f() { echo ran; }; sweep_step f; echo "rc=$?"'
	assert_line "rc=127"
	refute_line ran
}

@test "propagation 006 records when and how it ended before its cleanup (--mark-end), and its stop record keeps that time" {
	local res="${BATS_TEST_TMPDIR}/prop" bin="${BATS_TEST_TMPDIR}/pbin" d t
	mkdir -p "$bin"
	# Every kubectl call fails; the first makes the sweep's summary path a directory (its
	# write then fails after its start: a stop) and each keeps a copy of the record.
	cat > "${bin}/kubectl" <<'STUB'
#!/bin/sh
for d in "$P_RES"/sweep-*; do
	[ -d "$d" ] || continue
	[ -e "$d/sweep-summary.md" ] || mkdir "$d/sweep-summary.md"
	cp "$d/sweep-outcome.txt" "$P_RES/record-at-last-kubectl.txt" 2>/dev/null || :
done
exit 1
STUB
	chmod +x "${bin}/kubectl"
	cp "${bin}/kubectl" "${bin}/oc"
	P_RES="$res" PROPAGATION_RESULTS_DIR="$res" PROPAGATION_SETTLE_SEC=0 PATH="${bin}:${PATH}" KUBECONFIG="$EK" \
		run --separate-stderr bash "${ROOT}/tests/propagation/006-run-sweep.sh" --contexts ci-a --mesh-sizes 1
	[ "$status" -eq 1 ]
	[[ "$output" == *"--- Final cleanup: all contexts ---"* ]]
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	# The record its cleanup (007) saw: not finished, with when and how it ended.
	grep -qx 'EXIT=unfinished' "${res}/record-at-last-kubectl.txt"
	grep -qx 'ENDED_EXIT=1' "${res}/record-at-last-kubectl.txt"
	t="$(sed -n 's/^ENDED_AT=//p' "${res}/record-at-last-kubectl.txt")"
	[[ "$t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]
	# The stop record after it keeps that time.
	grep -qx 'STOPPED=1' "$d/sweep-outcome.txt"
	grep -qx "ENDED_AT=${t}" "$d/sweep-outcome.txt"
	[ "$(grep -c '^ENDED_AT=' "$d/sweep-outcome.txt")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# The orchestrator-step lint sees a step run through sweep_step

@test "lint: a bare step call through sweep_step in a sweep's loop is flagged; a guarded one passes; every sweep passes" {
	source "${ROOT}/tests/lib/lint-bare-scrape.sh"
	local f="${BATS_TEST_TMPDIR}/foo-run-sweep.sh"
	printf '#!/usr/bin/env bash\nfor ms in 1 2; do\n\tsweep_step "$SCRIPT_DIR/001-setup-test.sh" --contexts "$x"\n\techo next\ndone\n' > "$f"
	run lint_bare_orchestrator_step_file "$f"
	assert_failure
	assert_output --partial 'bare orchestrator-step call "$SCRIPT_DIR/001-setup-test.sh"'
	printf '#!/usr/bin/env bash\nfor ms in 1 2; do\n\tsweep_step "$SCRIPT_DIR/001-setup-test.sh" --contexts "$x" || echo warn\n\techo next\ndone\n' > "$f"
	run lint_bare_orchestrator_step_file "$f"
	assert_success
	local s
	for s in "${ROOT}"/tests/*/*-sweep.sh; do
		run lint_bare_orchestrator_step_file "$s"
		assert_success
	done
}

# ---------------------------------------------------------------------------
# The tuning sweep's own Istio CR edits, and anyone else's

# _tun_stub: a kubectl with a stateful Istio CR (files in TD): cr.json (its spec) and gen
# (its generation, and its IstioRevision's, which Sail raises with it). A merge patch
# applies (RFC 7386) and raises gen; a revert patch (istio-revert-*) also removes the
# applied marker, and under TUN_REVERT_LEAVES leaves a value behind (an incomplete revert).
# TUN_FOREIGN: the first other call while a profile is applied raises gen once (someone
# else edits the Istio CR during the pass). Each istiod pod list logs the
# ISTIO_GENERATIONS and ISTIO_PROXY_VERSIONS its caller was handed (gens-seen). A marker's
# apply, read and delete succeed, and the members hold no tuning profile objects (label
# istio-scale-tests/tuning-profile: an empty list). Any other call fails (the probe then
# fails: PROBE_FAILED).
_tun_stub() {
	export TD="${BATS_TEST_TMPDIR}/tun"
	mkdir -p "$TD"
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
d="$TD"
case "$*" in *" get pods -l app=istiod"*) echo "${ISTIO_GENERATIONS:-none} ${ISTIO_PROXY_VERSIONS:-none}" >> "$d/gens-seen" ;; esac
[ -f "$d/gen" ] || echo 2 > "$d/gen"
[ -f "$d/cr.json" ] || echo '{"spec":{"version":"v1.30-latest","values":{}}}' > "$d/cr.json"
g="$(cat "$d/gen")"
case "$*" in
*"get istios.sailoperator.io default"*|*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	STUB_ISTIO_CR_GEN="$g" STUB_ISTIO_REV_GEN="$g" exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" patch istio.sailoperator.io default --type=merge --patch-file="*)
	args="$*"; f="${args##*--patch-file=}"; f="${f%% *}"
	jq --slurpfile p "$f" 'def mp($q): if ($q | type) == "object" then reduce ($q | keys_unsorted[]) as $k ((if type == "object" then . else {} end); if $q[$k] == null then del(.[$k]) else .[$k] = (.[$k] | mp($q[$k])) end) else $q end; mp($p[0])' "$d/cr.json" > "$d/cr.new" && mv "$d/cr.new" "$d/cr.json"
	case "$f" in
	*istio-revert-*) rm -f "$d/applied"
		[ -z "${TUN_REVERT_LEAVES:-}" ] || { jq '.spec.values.global.leftover = "x"' "$d/cr.json" > "$d/cr.new" && mv "$d/cr.new" "$d/cr.json"; } ;;
	*) : > "$d/applied" ;;
	esac
	echo $((g + 1)) > "$d/gen" ;;
*" get istio.sailoperator.io default -o jsonpath={.metadata.generation}"*) echo "$g $g True default" ;;
*" get istio.sailoperator.io default -o jsonpath={.status.activeRevisionName}"*) echo default ;;
*" get istio.sailoperator.io default -o json")
	jq -c --argjson g "$g" '. + {metadata: {name: "default", generation: $g}}' "$d/cr.json" ;;
*" get istiorevision.sailoperator.io default -o jsonpath="*) echo "$g $g True" ;;
*" rollout status "*) exit 0 ;;
*" -n istio-system get deployment istiod -o json"*)
	jq -c '{spec: {template: {spec: {containers: [{name: "discovery", env: ((.spec.values.pilot.env // {}) | to_entries | map({name: .key, value: (.value | tostring)}))}]}}}}' "$d/cr.json" ;;
*" apply --server-side "*|*" delete --ignore-not-found -f "*|*" get --ignore-not-found -f "*|*" -n istio-system get ConfigMap tuning-profile-"*) exit 0 ;;
*" -l istio-scale-tests/tuning-profile"*) echo '{"kind":"List","items":[]}' ;;
*) [ -z "${TUN_FOREIGN:-}" ] || [ ! -f "$d/applied" ] || [ -f "$d/foreign-done" ] || { echo $((g + 1)) > "$d/gen"; : > "$d/foreign-done"; }
	exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
}

# tun_sweep: tuning 003 over the churn suite on ci-a, baseline and 01-push-throttling (it
# patches the Istio CR), no setup and no Argo CD pause; results under tres/. Sets TDIR.
tun_sweep() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" \
		--suite churn --contexts ci-a --no-gitops-pause --skip-setup --keep-workloads \
		--profiles 01-push-throttling --settle 0 --output-dir "${BATS_TEST_TMPDIR}/tres"
	TDIR="$(find "${BATS_TEST_TMPDIR}/tres" -maxdepth 1 -name 'sweep-*' -type d)"
}

@test "a tuning sweep's own apply and revert of the Istio CR are no problem; each pass's probes get the generations they ran on; the start and end spec are kept" {
	python3 -I -c 'import yaml' 2>/dev/null || skip "python3 with PyYAML is needed (tuning lib)"
	_tun_stub
	tun_sweep
	# The probes fail (the stub has no istiod pod): exit 4 for that reason only.
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"error: 2 of 2 passes failed: PROBE_FAILED x2."* ]]
	[[ "$stderr" != *"Istio CR changed"* && "$stderr" != *"was edited during the sweep"* && "$stderr" != *"incomplete revert"* ]]
	! grep -q '^PROBLEM=' "${TDIR}/sweep-outcome.txt" || false
	# The baseline probe ran on generation 2, the profile's on 3 (after its apply).
	grep -q '^ci-a=2/2 ' "${TD}/gens-seen"
	grep -q '^ci-a=3/3 ' "${TD}/gens-seen"
	[ "$(sed -n 2p "${TD}/gens-seen" | cut -d' ' -f1)" = ci-a=2/2 ]
	# The apply recorded its settled generations; the revert left no edit marker.
	[ "$(<"${TDIR}/01-push-throttling/state/istio-generations-applied")" = ci-a=3/3 ]
	[ ! -e "${TDIR}/01-push-throttling/state/istio-edited-during-pass" ]
	# The spec at the start and after the last revert, kept for the record, are the same.
	cmp "${TDIR}/istio-spec/start-ci-a.json" "${TDIR}/istio-spec/end-ci-a.json"
	# --help says what counts.
	run "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" --help
	assert_output --partial "The sweep's own apply and revert raise the generations too: the sweep reads them"
	assert_output --partial "an OSSM"
}

@test "an Istio CR edited during a pass by someone else is a problem (002 warns, 003 exits 4); a revert that leaves the spec unlike the start is a problem too" {
	python3 -I -c 'import yaml' 2>/dev/null || skip "python3 with PyYAML is needed (tuning lib)"
	_tun_stub
	TUN_FOREIGN=1 tun_sweep
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"WARNING: the Istio CR changed during the pass of 01-push-throttling, after its apply settled and not by this profile: ci-a (Istio CR generation 3 -> 4, IstioRevision generation 3 -> 4). Likely: a version changed and changed back, or a values change (an edit of the Istio CR). The pass's probes may have measured another configuration, and any passes after it (while the edit stays: this revert restores only the profile's keys) may measure another configuration. Reverting anyway."* ]]
	[[ "$stderr" == *"error: the Istio CR changed during pass 01-push-throttling, after its apply settled and not by its profile: ci-a (Istio CR generation 3 -> 4, IstioRevision generation 3 -> 4); likely: "*"; exit 4."* ]]
	grep -q '^PROBLEM=the Istio CR changed during pass 01-push-throttling' "${TDIR}/sweep-outcome.txt"
	[ -s "${TDIR}/01-push-throttling/state/istio-edited-during-pass" ]
	# An incomplete revert.
	rm -rf "$TD" "${BATS_TEST_TMPDIR}/tres"
	_tun_stub
	TUN_REVERT_LEAVES=1 tun_sweep
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"error: ci-a's Istio CR spec after the last revert differs from the sweep's start (an incomplete revert): values.global.leftover; the mesh is not as the sweep found it; exit 4."* ]]
	[[ "$stderr" != *"Istio CR changed during pass"* ]]
	! cmp -s "${TDIR}/istio-spec/start-ci-a.json" "${TDIR}/istio-spec/end-ci-a.json"
}

@test "002 run alone after 001 finds an edit made during the pass, and says when it cannot check" {
	python3 -I -c 'import yaml' 2>/dev/null || skip "python3 with PyYAML is needed (tuning lib)"
	_tun_stub
	local st="${BATS_TEST_TMPDIR}/state"
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/001-apply-profile.sh" \
		--profile "${ROOT}/tests/tuning/profiles/01-push-throttling.yaml" --contexts ci-a --state-dir "$st"
	assert_success
	[ "$(<"$st/istio-generations-applied")" = ci-a=3/3 ]
	# Someone edits the Istio CR during the pass.
	echo 7 > "${TD}/gen"
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/002-revert-profile.sh" --state-dir "$st"
	assert_success
	[[ "$stderr" == *"WARNING: the Istio CR changed during the pass of 01-push-throttling, after its apply settled and not by this profile: ci-a (Istio CR generation 3 -> 7, IstioRevision generation 3 -> 7)."* ]]
	[ "$(cut -f1 "$st/istio-edited-during-pass")" = 1 ]
	# A state dir from before that file: a note, no check.
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/001-apply-profile.sh" \
		--profile "${ROOT}/tests/tuning/profiles/01-push-throttling.yaml" --contexts ci-a --state-dir "$st"
	assert_success
	rm -f "$st/istio-generations-applied"
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/002-revert-profile.sh" --state-dir "$st"
	assert_success
	assert_output --partial "note: no istio-generations-applied in the state dir (001 stopped before its apply settled, could not write it, or an older 001 ran): no check that the Istio CR was left alone during the pass"
	[ ! -e "$st/istio-edited-during-pass" ]
	[ "$(<"$st/istio-generations-unchecked")" = "every member (no istio-generations-applied in the state dir)" ]
}

# ---------------------------------------------------------------------------
# Controlplane 002's config_dump samples and scrape skew

# _cp002_stub: a kubectl for controlplane 002 run alone, logging every call to KLOG: two
# Running istiod pods per context, one Running controlplane-test pod (ns1/sc-1) whose
# /config_dump answers a fixture body, the Istio CR as fake-istio-cr.sh; a curl that
# serves one /metrics body and /ready.
_cp002_stub() {
	export FX="${ROOT}/tests/lib/test/fixtures/istiod-diag" KLOG="${BATS_TEST_TMPDIR}/kubectl.log"
	: > "$KLOG"
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KLOG"
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*)
	exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running "*) printf 'istiod-abc-x1 istiod-abc-x2\n' ;;
*" -l app.kubernetes.io/instance=controlplane-test -o jsonpath="*) printf 'ns1|sc-1\n' ;;
*" exec sc-1 "*) cat "$FX/../fortio_ok.json" ;;
*" -o json "*) cat "$FX/empty_list.json" ;;
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
*/debug/syncz) echo '[]'; exit 0 ;;
*) exit 7 ;;
esac
if [[ -n "$out" ]]; then cp "$body" "$out"; else cat "$body"; fi
STUB
	chmod +x "${BIN}/kubectl" "${BIN}/curl"
}

# _cp002 <args...>: controlplane 002 with the stubs, its TSV under res/.
_cp002() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${CP}/002-collect-resource-metrics.sh" \
		--settle 0 --output-dir "${BATS_TEST_TMPDIR}/res" "$@"
}

# _cp002_col <name>: that column of every row of the one TSV under res/.
_cp002_col() {
	awk -F'\t' -v n="$1" '$1 == "timestamp" { for (i = 1; i <= NF; i++) if ($i == n) c = i; next } !/^#/ && c { print $c }' \
		"$(find "${BATS_TEST_TMPDIR}/res" -maxdepth 1 -name 'controlplane-*.tsv')"
}

@test "the config_dump samples are taken once per context in a window, not once per istiod replica: each replica's row shows the same samples" {
	_cp002_stub
	_cp002 --contexts ci-a --config-dump-samples 1
	assert_success
	# Two istiod replicas, two rows; one pod list and one exec for both.
	[ "$(_cp002_col context | wc -l)" -eq 2 ]
	[ "$(grep -c 'controlplane-test -o jsonpath=' "$KLOG")" -eq 1 ]
	[ "$(grep -c ' exec sc-1 ' "$KLOG")" -eq 1 ]
	[ "$(_cp002_col sidecar_config_bytes_samples | sort -u)" = 1/1 ]
	local avg
	avg="$(_cp002_col sidecar_config_bytes_avg | sort -u)"
	[[ "$avg" =~ ^[1-9][0-9]*$ ]]
}

@test "a --phase final's scrape skew is the spread of the baseline's completion stamps (.tsend), as in a combined run, not of its start stamps" {
	_cp002_stub
	local st="${BATS_TEST_TMPDIR}/state" k
	_cp002 --contexts ci-a,ci-b --phase baseline --state-dir "$st" --config-dump-samples 0
	assert_success
	# Four baseline scrapes (2 contexts x 2 replicas) that started together and finished 3 s apart.
	for k in 0 1 2 3; do
		echo 1000 > "${st}/baseline-${k}.ts"
		echo $(( 1000 + k * 3000 )) > "${st}/baseline-${k}.tsend"
	done
	_cp002 --contexts ci-a,ci-b --phase final --state-dir "$st" --config-dump-samples 0
	assert_success
	[ "$(_cp002_col context | wc -l)" -eq 4 ]
	[ "$(_cp002_col scrape_skew_ms | sort -u)" = 9000 ]
}

# ---------------------------------------------------------------------------
# Every report records the harness it ran

# _has_report_harness <label> <harness>: $output has a REPORT_HARNESS_SHA (any case) line naming <harness>.
_has_report_harness() {
	grep -i 'report_harness_sha' <<<"$output" | grep -qF "$2" || { echo "${1}: no REPORT_HARNESS_SHA line naming ${2}" >&2; return 1; }
}

@test "every suite's report records REPORT_HARNESS_SHA (the harness the report ran) in every format it writes" {
	local rh d f
	rh="$(report_harness_sha)"
	[[ "$rh" =~ ^[0-9a-f]{7} ]]
	d="${BATS_TEST_TMPDIR}/reports"
	mkdir -p "$d/dp" "$d/ch" "$d/cd" "$d/pr" "$d/tu/baseline" "$d/tu/01-x"
	{
		echo "# RUN_ID=r1"
		printf 'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class\n'
		printf 'r1\t2\tci-a\tci-a\t10\t10\t8\t30\t2.0\t2.5\t5.0\t11.0\t12.5\tOK\t1\t0\tlocal\n'
	} > "$d/dp/latency-a.tsv"
	{
		echo "# RUN_ID=r1"
		printf 'run_id\tmesh_size\tchurn_intensity\tbase_replicas\tscale_to\titeration\tt0_epoch_ns\tconvergence_local_ms\tremote_endpoint_reachable_ms\tconvergence_remote_eds_ms\tsource_push_triggers_delta\tremote_push_triggers_delta\tsource_xds_pushes_delta\tremote_xds_pushes_delta\tsource_queue_time_p99_ms\tremote_queue_time_p99_ms\tsource_connected_proxies\tremote_connected_proxies\tsource_push_time_p99_ms\tremote_push_time_p99_ms\tstatus\n'
		printf 'r1\t2\t5\t1\t5\t1\t0\t1000\t2000\t300\t10\t20\t100\t200\t99\tN/A\t50\t60\t10\tN/A\tOK\n'
	} > "$d/ch/churn-a.tsv"
	{
		echo "# RUN_ID=r1"
		printf 'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms\n'
		printf 'r1\tsha\tc1\t2\t0\tbaseline\t60\t50\t50\t2\t3\t5\t6\t7\tN/A\t0\tOK\t10\t10\t100\tN/A\t5\tN/A\tN/A\tN/A\n'
		printf 'r1\tsha\tc1\t2\t1\tchurn\t60\t50\t48\t4\t3\t9\t6\t7\tN/A\t0\tOK\t10\t10\t100\t30\t5\t99\tN/A\tN/A\n'
	} > "$d/cd/churn-dataplane-r1.tsv"
	{
		echo "# RUN_ID=r1"
		printf 'run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms\n'
		printf 'r1\t2\t1\tsrc\trmt\t0\t1000\t500\t3000\tOK\t100\t100\t40/40\t40\t0\t0\t0\t5000\t10\n'
	} > "$d/pr/endpoint-r1.tsv"
	printf '# SUITE=controlplane\n# PASSES=baseline,01-x\n# HARNESS_SHA=0123abc-dirty.89abcdef\n' > "$d/tu/sweep-metadata.txt"
	{
		printf 'timestamp\tistiod_restarted\tistiod_mem_mi\tgo_heap_inuse_mi\tistiod_cpu_m_delta\tconvergence_p99_ms\txds_pushes_delta\tsidecar_config_bytes_avg\tconnected_proxies\n'
		printf 't\t0\t512\t300\t250\t99\t438\t20480\t10\n'
	} > "$d/tu/baseline/controlplane-r1.tsv"
	cp "$d/tu/baseline/controlplane-r1.tsv" "$d/tu/01-x/controlplane-r2.tsv"
	for f in text md json csv charts; do
		run --separate-stderr bash "${ROOT}/tests/dataplane/004-report-results.sh" --results-dir "$d/dp" --format "$f"
		assert_success
		_has_report_harness "dataplane 004 ${f}" "$rh"
		run --separate-stderr bash "${ROOT}/tests/churn-dataplane/005-report-results.sh" --results-dir "$d/cd" --format "$f"
		assert_success
		_has_report_harness "churn-dataplane 005 ${f}" "$rh"
		run --separate-stderr bash "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$d/pr" --format "$f"
		assert_success
		_has_report_harness "propagation 005 ${f}" "$rh"
	done
	for f in text md csv charts; do
		run --separate-stderr bash "${ROOT}/tests/churn/004-report-results.sh" --results-dir "$d/ch" --format "$f"
		assert_success
		_has_report_harness "churn 004 ${f}" "$rh"
	done
	for f in text md; do
		run --separate-stderr bash "${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "$d/tu" --format "$f"
		assert_success
		_has_report_harness "tuning 004 ${f}" "$rh"
		# The two on lines of their own, as the other reports print them.
		local pfx=""
		[[ "$f" != md ]] || pfx="- "
		assert_line "${pfx}HARNESS_SHA=0123abc-dirty.89abcdef (the sweep's)"
		assert_line "${pfx}REPORT_HARNESS_SHA=${rh} (this report's own)"
	done
}

#!/usr/bin/env bats
# A sweep's start, steps, stop and outcome (tests/lib/common.sh: sweep_start, sweep_step,
# sweep_finish, the EXIT and signal traps, sweep_outcome_lines) and the harness it records
# (harness_sha), against stub sweeps and steps in the test's temp dir: no suite runs here.

bats_require_minimum_version 1.5.0
load test_helper
load harness_helper

setup() {
	export T="$BATS_TEST_TMPDIR"
	export D="${T}/res/sweep-x"
	export SWEEP_STOP_GRACE_SEC=10
}

teardown() {
	# What a failed test's stub step left running (only the PIDs it recorded).
	local f p
	for f in "${T}/step.pgid" "${T}/grandchild.pid"; do
		[[ -s "$f" ]] || continue
		p="$(<"$f")"
		[[ "$p" =~ ^[0-9]+$ ]] || continue
		kill -KILL -- "-${p}" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true
	done
}

# step_script: $STEP, a step that records its PID (its process group: sweep_step runs it as
# a job of its own) and that of a child it starts (a grandchild of the sweep), touches
# step.started, then waits for the child; given ignore-term, it ignores SIGTERM.
step_script() {
	STEP="${T}/step.sh"
	cat > "$STEP" <<'STEP'
#!/usr/bin/env bash
[[ "${1:-}" != ignore-term ]] || trap '' TERM
echo "$$" > "$T/step.pgid"
sleep 60 &
echo "$!" > "$T/grandchild.pid"
: > "$T/step.started"
wait
: > "$T/step.done"
STEP
	chmod +x "$STEP"
}

# sweep_script <line>...: $S, a stub sweep as the suites write one (set -euo pipefail, the
# ERR trap, SWEEP_CLEANUP_CMD) that starts a sweep into $D with the cleanup function
# cleanup, then runs the given lines. cleanup logs each run to cleanup.log, and step-alive
# there when the step it ran is still alive.
sweep_script() {
	S="${T}/sweep.sh"
	cat > "$S" <<'HEAD'
#!/usr/bin/env bash
set -euo pipefail
source "$ROOT/tests/lib/common.sh"
trap 'sweep_err_trap "$?" "$LINENO" "$BASH_COMMAND"' ERR
cleanup() {
	echo cleanup >> "$T/cleanup.log"
	if [[ -s "$T/step.pgid" ]] && kill -0 "$(<"$T/step.pgid")" 2>/dev/null; then echo step-alive >> "$T/cleanup.log"; fi
}
SWEEP_CLEANUP_CMD="./005-cleanup.sh --contexts <mesh-a-ctx>"
sweep_start "$D" run-1 --cleanup cleanup
HEAD
	printf '%s\n' "$@" >> "$S"
}

# wait_file <path>: until it exists (at most 10 s).
wait_file() {
	local i
	for ((i = 0; i < 100; i++)); do
		[[ -e "$1" ]] && return 0
		sleep 0.1
	done
	return 1
}

# wait_line <file> <text>: until <file> has a line with <text> (at most 10 s).
wait_line() {
	local i
	for ((i = 0; i < 100; i++)); do
		grep -qF -- "$2" "$1" 2>/dev/null && return 0
		sleep 0.1
	done
	return 1
}

# group_gone <pgid>: until no process of that group runs (at most 5 s). A zombie has ended: an
# orphan's waits for init to reap it, which takes seconds in some containers.
group_gone() {
	local i
	for ((i = 0; i < 50; i++)); do
		[[ -n "$(ps -A -o pgid=,stat= | awk -v g="$1" '$1 == g && $2 !~ /^Z/')" ]] || return 0
		sleep 0.1
	done
	ps -A -o pid=,pgid=,stat=,args= | awk -v g="$1" '$2 == g'
	return 1
}

# rec <dir> <line>...: a sweep record in <dir> (STATUS first, as the sweep writes it).
rec() {
	local d="$1"
	shift
	mkdir -p "$d"
	{
		echo "# Sweep outcome (tests/lib/common.sh): STATUS=running until the sweep ends"
		printf '%s\n' "$@"
	} > "${d}/sweep-outcome.txt"
}

# outcome_all <path>...: sweep_outcome_lines in every format, each output in OUT_<fmt>.
outcome_all() {
	local f
	for f in text md charts json csv verdict; do
		printf -v "OUT_${f}" '%s' "$(sweep_outcome_lines "$f" "$@")"
	done
}

# ---------------------------------------------------------------------------
# sweep_start

@test "sweep_start: a SWEEP_STOP_GRACE_SEC that is no number of seconds dies naming the key; the running record has STATUS, RUN_ID, HARNESS_SHA, STARTED_AT and UNIT" {
	SWEEP_STOP_GRACE_SEC=soon run --separate-stderr bash -c 'source "$ROOT/tests/lib/common.sh"; sweep_start "$1" r1' _ "$D"
	assert_failure 1
	[[ "$stderr" == *"SWEEP_STOP_GRACE_SEC must be a non-negative integer of seconds (got: soon)"* ]]
	[ ! -e "${D}/sweep-outcome.txt" ]
	HARNESS_SHA=abc1234 run --separate-stderr bash -c 'source "$ROOT/tests/lib/common.sh"
		sweep_start "$1" r1 --unit passes; cp "$1/sweep-outcome.txt" "$1/at-start.txt"' _ "$D"
	# It ends before sweep_finish: a stop (exit 1).
	assert_failure 1
	[ "$(grep -v '^#' "${D}/at-start.txt" | cut -d= -f1 | tr '\n' ' ')" = "STATUS RUN_ID HARNESS_SHA STARTED_AT UNIT " ]
	grep -qx 'STATUS=running' "${D}/at-start.txt"
	grep -qx 'RUN_ID=r1' "${D}/at-start.txt"
	grep -qx 'HARNESS_SHA=abc1234' "${D}/at-start.txt"
	grep -qxE 'STARTED_AT=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "${D}/at-start.txt"
	grep -qx 'UNIT=passes' "${D}/at-start.txt"
	grep -qx 'STATUS=stopped' "${D}/sweep-outcome.txt"
}

# ---------------------------------------------------------------------------
# sweep_finish

# finish <sweep_finish args...>: a sweep in $D (harness h1 at both reads) that ends with
# sweep_finish <args>; its exit status is sweep_finish's.
finish() {
	run --separate-stderr bash -c 'source "$ROOT/tests/lib/common.sh"; harness_sha() { echo h1; }
		d="$1"; shift; sweep_start "$d" r1; sweep_finish "$@"' _ "$D" "$@"
}

@test "sweep_finish: every cell ran is exit 0 and a finished record; failed cells are counted by reason (exit 4), skipped ones are not failures; a stop's code (1, or 3 for a reachability gate) wins over 4 with its reason, never claiming every cell ran; a problem fails a sweep whose cells ran, a note does not; a cell count that is no number is unknown" {
	finish 6
	assert_success
	assert_output "All 6 cells ran (their rows' own statuses are in the report)."
	[ -z "$stderr" ]
	grep -qx 'STATUS=finished' "${D}/sweep-outcome.txt"
	grep -qx 'EXIT=0' "${D}/sweep-outcome.txt"
	grep -qx 'TOTAL=6' "${D}/sweep-outcome.txt"
	grep -qx 'FAILED=0' "${D}/sweep-outcome.txt"
	grep -qxE 'ENDED_AT=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "${D}/sweep-outcome.txt"
	finish 6 SETUP_FAILED PROBE_FAILED SETUP_FAILED SKIPPED_MEM_GUARD
	assert_failure 4
	assert_output "1 of 6 cells were skipped on purpose, not failed: SKIPPED_MEM_GUARD x1."
	[ "$stderr" = "error: 3 of 6 cells failed: PROBE_FAILED x1, SETUP_FAILED x2. The report includes them as placeholder rows (in n_total, not n_valid); exit 4." ]
	grep -qx 'EXIT=4' "${D}/sweep-outcome.txt"
	grep -qx 'FAILED=3' "${D}/sweep-outcome.txt"
	grep -qx 'FAILED_BY=PROBE_FAILED x1, SETUP_FAILED x2' "${D}/sweep-outcome.txt"
	grep -qx 'SKIPPED=1' "${D}/sweep-outcome.txt"
	grep -qx 'SKIPPED_BY=SKIPPED_MEM_GUARD x1' "${D}/sweep-outcome.txt"
	finish --where "Each has its marker file in its pass directory" 3 SKIPPED_SERIES_STOPPED
	assert_success
	assert_output "1 of 3 cells were skipped on purpose, not failed: SKIPPED_SERIES_STOPPED x1."
	run --separate-stderr bash -c 'source "$ROOT/tests/lib/common.sh"; harness_sha() { echo h1; }
		sweep_start "$1" r1 --unit passes; sweep_finish --where "Each has its marker file in its pass directory" 3 SETUP_FAILED' _ "$D"
	assert_failure 4
	[ "$stderr" = "error: 1 of 3 passes failed: SETUP_FAILED x1. Each has its marker file in its pass directory; exit 4." ]
	# A stop.
	finish --stopped 3 --stop-reason "the reachability gate found an unreachable remote" 4 PROBE_FAILED
	assert_failure 3
	[ -z "$output" ]
	[ "$stderr" = "error: 1 of 4 cells failed: PROBE_FAILED x1. The report includes them as placeholder rows (in n_total, not n_valid); the sweep also stopped early, so it exits 3, not 4." ]
	grep -qx 'STATUS=stopped' "${D}/sweep-outcome.txt"
	grep -qx 'EXIT=3' "${D}/sweep-outcome.txt"
	grep -qx 'STOP_REASON=the reachability gate found an unreachable remote' "${D}/sweep-outcome.txt"
	finish --stopped 1 --stop-reason "REVERT_FAILED: reverting pass 01-x failed" 2
	assert_failure 1
	[ -z "$output" ]
	grep -qx 'EXIT=1' "${D}/sweep-outcome.txt"
	# Problems and notes.
	finish --problem "the Istio version changed during the sweep (a: v1 at the start, v2 at the end)" --note "something unconfirmed" 2
	assert_failure 4
	assert_output "All 2 cells ran (their rows' own statuses are in the report)."
	[[ "$stderr" == *"error: the Istio version changed during the sweep (a: v1 at the start, v2 at the end); exit 4."* ]]
	[[ "$stderr" == *"note: something unconfirmed."* ]]
	grep -qx 'PROBLEM=the Istio version changed during the sweep (a: v1 at the start, v2 at the end)' "${D}/sweep-outcome.txt"
	grep -qx 'NOTE=something unconfirmed' "${D}/sweep-outcome.txt"
	finish --note "n" 2
	assert_success
	grep -qx 'EXIT=0' "${D}/sweep-outcome.txt"
	# A problem recorded earlier (sweep_problem, before sweep_finish) counts the same.
	run --separate-stderr bash -c 'source "$ROOT/tests/lib/common.sh"; harness_sha() { echo h1; }
		sweep_problem "could not count the cells"; sweep_start "$1" r1; sweep_finish x' _ "$D"
	assert_failure 4
	[ -z "$output" ]
	grep -qx 'TOTAL=unknown' "${D}/sweep-outcome.txt"
	grep -qx 'FAILED=unknown' "${D}/sweep-outcome.txt"
	grep -qx 'PROBLEM=could not count the cells' "${D}/sweep-outcome.txt"
}

@test "sweep_finish reads the harness again: one that changed since sweep_start is a problem (exit 4) naming both reads; the same one is none" {
	echo h1 > "${T}/harness"
	run --separate-stderr bash -c 'source "$ROOT/tests/lib/common.sh"; h="$2"; harness_sha() { cat "$h"; }
		sweep_start "$1" r1; echo h2 > "$h"; sweep_finish 2' _ "$D" "${T}/harness"
	assert_failure 4
	local p="the harness changed during the sweep: h1 at its start, h2 at its end; don't edit or check out files in this checkout while a sweep runs"
	[[ "$stderr" == *"error: ${p}; exit 4."* ]]
	grep -qx 'HARNESS_SHA=h1' "${D}/sweep-outcome.txt"
	grep -qxF "PROBLEM=${p}" "${D}/sweep-outcome.txt"
	echo h1 > "${T}/harness"
	run --separate-stderr bash -c 'source "$ROOT/tests/lib/common.sh"; h="$2"; harness_sha() { cat "$h"; }
		sweep_start "$1" r1; sweep_finish 2' _ "$D" "${T}/harness"
	assert_success
	! grep -q '^PROBLEM=' "${D}/sweep-outcome.txt" || false
}

# ---------------------------------------------------------------------------
# A sweep that ends before its end

@test "a die after sweep_start records stopped with its reason (the sweep dir as <sweep dir>, the home dir as ~; the console keeps them) and runs the cleanup once; an unexpected abort records the ERR trap's script, line and command" {
	export D="${T}/home/u/results/sweep-x"
	sweep_script 'sweep_note "a note so far"' 'die "cannot read ${HOME}/.kube/config for ${D}/x"'
	HOME="${T}/home/u" run --separate-stderr bash "$S"
	assert_failure 1
	[[ "$stderr" == *"error: cannot read ${T}/home/u/.kube/config for ${D}/x"* ]]
	[[ "$stderr" == *"error: the sweep stopped before its end; its results may be partial"*"  sweep dir: ${D}"*"  clean up with: ./005-cleanup.sh --contexts <mesh-a-ctx>"* ]]
	grep -qx 'STATUS=stopped' "${D}/sweep-outcome.txt"
	grep -qx 'EXIT=1' "${D}/sweep-outcome.txt"
	grep -qx 'STOP_REASON=cannot read ~/.kube/config for <sweep dir>/x' "${D}/sweep-outcome.txt"
	grep -qx 'NOTE=a note so far' "${D}/sweep-outcome.txt"
	[ "$(<"${T}/cleanup.log")" = cleanup ]
	rm -f "${T}/cleanup.log"
	sweep_script 'false'
	run --separate-stderr bash "$S"
	assert_failure 1
	[[ "$stderr" == *"FATAL: sweep.sh aborted (exit 1) at line "*": false"* ]]
	grep -qxE 'STOP_REASON=sweep\.sh aborted \(exit 1\) at line [0-9]+: false' "${D}/sweep-outcome.txt"
	[ "$(<"${T}/cleanup.log")" = cleanup ]
}

@test "SIGTERM to the sweep alone during a step: the step's process group (its child too) is stopped first, then the cleanup runs once; the record says interrupted (SIGTERM, exit 143), with no job notice" {
	local p rc=0
	step_script
	sweep_script 'sweep_step "$1"' 'echo continued > "$T/after"'
	bash "$S" "$STEP" > "${T}/out" 2> "${T}/err" &
	p=$!
	wait_file "${T}/step.started"
	kill -TERM "$p"
	wait "$p" || rc=$?
	[ "$rc" -eq 143 ]
	group_gone "$(<"${T}/step.pgid")"
	[ ! -e "${T}/step.done" ]
	[ ! -e "${T}/after" ]
	[ "$(<"${T}/cleanup.log")" = cleanup ]
	grep -qx 'STATUS=interrupted' "${D}/sweep-outcome.txt"
	grep -qx 'SIGNAL=SIGTERM' "${D}/sweep-outcome.txt"
	grep -qx 'EXIT=143' "${D}/sweep-outcome.txt"
	run cat "${T}/err"
	assert_line "Stopping the running step (step.sh): SIGTERM to its process group; SIGKILL to what still runs 10s later (SWEEP_STOP_GRACE_SEC)."
	assert_line "warning: the sweep was interrupted (SIGTERM); its results may be partial"
	assert_line "  sweep dir: ${D}"
	refute_output --regexp '(Terminated|Killed|Done|\[[0-9]+\])'
}

@test "a step that ignores SIGTERM gets SIGKILL after SWEEP_STOP_GRACE_SEC, and a second signal kills it at once: either way it is gone before the cleanup runs" {
	local p rc=0
	step_script
	sweep_script 'sweep_step "$1" ignore-term'
	SWEEP_STOP_GRACE_SEC=1 bash "$S" "$STEP" > "${T}/out" 2> "${T}/err" &
	p=$!
	wait_file "${T}/step.started"
	kill -TERM "$p"
	wait "$p" || rc=$?
	[ "$rc" -eq 143 ]
	[ "$(<"${T}/cleanup.log")" = cleanup ]
	group_gone "$(<"${T}/step.pgid")"
	grep -qx 'STATUS=interrupted' "${D}/sweep-outcome.txt"
	# A grace far longer than the test: the second SIGTERM ends it.
	rm -f "${T}/cleanup.log" "${T}/step.started" "${T}/step.pgid"
	rc=0
	SWEEP_STOP_GRACE_SEC=600 bash "$S" "$STEP" > "${T}/out" 2> "${T}/err" &
	p=$!
	wait_file "${T}/step.started"
	kill -TERM "$p"
	wait_line "${T}/err" "Stopping the running step"
	kill -TERM "$p"
	wait "$p" || rc=$?
	[ "$rc" -eq 143 ]
	[ "$(<"${T}/cleanup.log")" = cleanup ]
	group_gone "$(<"${T}/step.pgid")"
	grep -qx 'SIGNAL=SIGTERM' "${D}/sweep-outcome.txt"
}

# ---------------------------------------------------------------------------
# sweep_outcome_lines: what a report says of the records behind it

@test "sweep_outcome_lines: a running record (the sweep died, or still runs), an interrupted one (with its signal and time) and a stopped one (with its reason) warn in every format; json and csv carry them, verdict names them" {
	rec "$D" STATUS=running RUN_ID=r1 HARNESS_SHA=abc1234 STARTED_AT=2026-10-01T00:00:00Z UNIT=cells
	: > "${D}/controlplane-r1.tsv"
	outcome_all "${D}/controlplane-r1.tsv"
	local w="the sweep has not finished (it died, or it still runs): these results may be partial"
	[ "$OUT_text" = "$(printf '%s\n' "SWEEP OUTCOME (sweep-x): RUNNING" "  warning: ${w}")" ]
	[ "$OUT_md" = "$(printf '%s\n' '> **Sweep outcome** (`sweep-x`): **running**' "> - warning: ${w}")" ]
	[ "$OUT_charts" = "$OUT_md" ]
	[ "$(jq -c '[.[] | [.dir, .status, .exit, .total, .problems, .notes]]' <<<"$OUT_json")" = '[["sweep-x","running",null,null,[],[]]]' ]
	[ "$OUT_csv" = "$(printf '%s\n' '# SWEEP_OUTCOME_DIR=sweep-x' '# SWEEP_OUTCOME_STATUS=running' '# SWEEP_OUTCOME_RUN_ID=r1' \
		'# SWEEP_OUTCOME_HARNESS_SHA=abc1234' '# SWEEP_OUTCOME_STARTED_AT=2026-10-01T00:00:00Z' '# SWEEP_OUTCOME_UNIT=cells')" ]
	[ "$OUT_verdict" = "sweep-x: running" ]
	rec "$D" STATUS=interrupted RUN_ID=r1 UNIT=cells SIGNAL=SIGINT EXIT=130 ENDED_AT=2026-10-01T01:00:00Z "NOTE=istiod was not ready at the start"
	outcome_all "$D"
	w="the sweep was interrupted (SIGINT) at 2026-10-01T01:00:00Z: these results may be partial"
	[ "$OUT_text" = "$(printf '%s\n' "SWEEP OUTCOME (sweep-x): INTERRUPTED, exit 130" "  warning: ${w}" "  warning: istiod was not ready at the start")" ]
	[ "$OUT_md" = "$(printf '%s\n' '> **Sweep outcome** (`sweep-x`): **interrupted**, exit 130' "> - warning: ${w}" "> - warning: istiod was not ready at the start")" ]
	[ "$OUT_charts" = "$OUT_md" ]
	[ "$(jq -c '.[0] | [.status, .exit, .signal, .ended_at, .notes]' <<<"$OUT_json")" = '["interrupted",130,"SIGINT","2026-10-01T01:00:00Z",["istiod was not ready at the start"]]' ]
	[[ "$OUT_csv" == *$'\n# SWEEP_OUTCOME_SIGNAL=SIGINT\n# SWEEP_OUTCOME_EXIT=130\n'* ]]
	[ "$OUT_verdict" = "sweep-x: interrupted" ]
	rec "$D" STATUS=stopped RUN_ID=r1 UNIT=cells EXIT=1 ENDED_AT=2026-10-01T01:00:00Z "STOP_REASON=controlplane-test namespaces are still on the members"
	outcome_all "$D"
	local e="the sweep stopped early: controlplane-test namespaces are still on the members"
	[ "$OUT_text" = "$(printf '%s\n' "SWEEP OUTCOME (sweep-x): STOPPED, exit 1" "  error: ${e}")" ]
	[ "$OUT_md" = "$(printf '%s\n' '> **Sweep outcome** (`sweep-x`): **stopped**, exit 1' "> - error: ${e}")" ]
	[ "$OUT_charts" = "$OUT_md" ]
	[ "$(jq -r '.[0] | "\(.status) \(.exit) \(.stop_reason)"' <<<"$OUT_json")" = "stopped 1 controlplane-test namespaces are still on the members" ]
	[[ "$OUT_csv" == *$'\n# SWEEP_OUTCOME_STOP_REASON=controlplane-test namespaces are still on the members'* ]]
	[ "$OUT_verdict" = "sweep-x: stopped" ]
}

@test "sweep_outcome_lines: failed cells are an error and skipped ones a note in every format, each problem an error that counts in verdict; a record that ran every cell says so, and nothing in charts or verdict; several dirs (pooled inputs) are each read once, in order; no record adds nothing (json [])" {
	rec "$D" STATUS=finished RUN_ID=r1 UNIT=passes EXIT=4 TOTAL=5 FAILED=2 "FAILED_BY=PROBE_FAILED x2" SKIPPED=1 "SKIPPED_BY=SKIPPED_MEM_GUARD x1"
	outcome_all "$D"
	[ "$OUT_text" = "$(printf '%s\n' "SWEEP OUTCOME (sweep-x): FINISHED, exit 4" "  error: 2 of 5 passes failed: PROBE_FAILED x2" \
		"  note: 1 of 5 passes were skipped on purpose, not failed: SKIPPED_MEM_GUARD x1")" ]
	[ "$OUT_md" = "$(printf '%s\n' '> **Sweep outcome** (`sweep-x`): **finished**, exit 4' "> - error: 2 of 5 passes failed: PROBE_FAILED x2" \
		"> - note: 1 of 5 passes were skipped on purpose, not failed: SKIPPED_MEM_GUARD x1")" ]
	[ "$OUT_charts" = "$OUT_md" ]
	[ "$(jq -c '.[0] | [.total, .failed, .failed_by, .skipped, .skipped_by]' <<<"$OUT_json")" = '[5,2,"PROBE_FAILED x2",1,"SKIPPED_MEM_GUARD x1"]' ]
	[[ "$OUT_csv" == *$'\n# SWEEP_OUTCOME_FAILED=2\n# SWEEP_OUTCOME_FAILED_BY=PROBE_FAILED x2\n'* ]]
	[ "$OUT_verdict" = "sweep-x: finished, 2 failed" ]
	rec "$D" STATUS=finished RUN_ID=r1 UNIT=cells EXIT=0 TOTAL=4 FAILED=0 FAILED_BY= SKIPPED=0 SKIPPED_BY= STOP_REASON=
	outcome_all "$D"
	[ "$OUT_text" = "SWEEP OUTCOME (sweep-x): all 4 cells ran" ]
	[ "$OUT_md" = '> **Sweep outcome** (`sweep-x`): all 4 cells ran' ]
	[ -z "$OUT_charts" ]
	[ -z "$OUT_verdict" ]
	[ "$(jq -c '.[0] | [.status, .exit, .failed, .failed_by, .stop_reason]' <<<"$OUT_json")" = '["finished",0,0,null,null]' ]
	local o="${T}/res/sweep-o"
	rec "$D" STATUS=finished RUN_ID=r1 UNIT=cells EXIT=4 TOTAL=2 FAILED=0 "PROBLEM=the harness changed during the sweep: a at its start, b at its end" 'PROBLEM=a "quoted" one'
	rec "$o" STATUS=finished RUN_ID=r2 UNIT=cells EXIT=0 TOTAL=3 FAILED=0
	: > "${D}/a.tsv"
	: > "${D}/b.tsv"
	outcome_all "${D}/a.tsv" "${D}/b.tsv" "$o/x.tsv"
	[ "$OUT_text" = "$(printf '%s\n' "SWEEP OUTCOME (sweep-x): FINISHED, exit 4" "  error: the harness changed during the sweep: a at its start, b at its end" \
		'  error: a "quoted" one' "" "SWEEP OUTCOME (sweep-o): all 3 cells ran")" ]
	[[ "$OUT_md" == *$'\n> - error: the harness changed during the sweep: a at its start, b at its end\n'* ]]
	[[ "$OUT_charts" == *'> - error: a "quoted" one'* && "$OUT_charts" != *sweep-o* ]]
	[ "$(jq -c '[.[] | [.dir, (.problems | length)]]' <<<"$OUT_json")" = '[["sweep-x",2],["sweep-o",0]]' ]
	[ "$(jq -r '.[0].problems[1]' <<<"$OUT_json")" = 'a "quoted" one' ]
	[ "$(grep -c '^# SWEEP_OUTCOME_DIR=' <<<"$OUT_csv")" -eq 2 ]
	[ "$(grep -c '^# SWEEP_OUTCOME_PROBLEM=' <<<"$OUT_csv")" -eq 2 ]
	[ "$OUT_verdict" = "sweep-x: finished, 2 problem(s)" ]
	mkdir -p "${T}/none"
	outcome_all "${T}/none"
	[ "$OUT_json" = "[]" ]
	[ -z "${OUT_text}${OUT_md}${OUT_charts}${OUT_csv}${OUT_verdict}" ]
}

# ---------------------------------------------------------------------------
# harness_sha

@test "harness_sha: the commit (a tag shows), -dirty.<8hex> for a tracked change or an untracked file under tests/, config/, charts/ or terraform/, the hex another for another change and the same under another git config; an ignored file, a change elsewhere and an excluded dir do not count; unknown outside git" {
	local r="${T}/repo" h1 h2
	mkdir -p "$r/tests" "$r/docs"
	printf 'one\n' > "$r/tests/f"
	printf '1\n\n3\n4\n5\n6\n7\n8\n9\n' > "$r/tests/g"
	printf 'd\n' > "$r/docs/d"
	printf '*.log\n' > "$r/.gitignore"
	_commit "$r" init
	[[ "$(ROOT="$r" harness_sha)" =~ ^[0-9a-f]{7}$ ]]
	git -C "$r" -c user.email=ci@example.com -c user.name=ci tag -a v1 -m v1
	[ "$(ROOT="$r" harness_sha)" = v1 ]
	: > "$r/tests/x.log"
	printf 'two\n' > "$r/docs/d"
	printf 'n\n' > "$r/README.md"
	[ "$(ROOT="$r" harness_sha)" = v1 ]
	# Two edits of a tracked file are two harnesses; one read again is the same.
	printf 'two\n' > "$r/tests/f"
	h1="$(ROOT="$r" harness_sha)"
	[[ "$h1" =~ ^v1-dirty\.[0-9a-f]{8}$ ]]
	[ "$(ROOT="$r" harness_sha)" = "$h1" ]
	printf 'three\n' > "$r/tests/f"
	h2="$(ROOT="$r" harness_sha)"
	[[ "$h2" =~ ^v1-dirty\.[0-9a-f]{8}$ ]]
	[ "$h2" != "$h1" ]
	git -C "$r" checkout -q -- tests/f
	[ "$(ROOT="$r" harness_sha)" = v1 ]
	# An edit of two files (two nearby hunks, a blank context line) reads the same under a git
	# config and a user attributes file that print its diff another way.
	printf 'two\n' > "$r/tests/f"
	printf 'x\n\n3\n4\n5\n6\n7\n8\ny\n' > "$r/tests/g"
	h1="$(ROOT="$r" harness_sha)"
	printf 'tests/g diff=x\n' > "${T}/attrs"
	printf 'tests/g\ntests/f\n' > "${T}/order"
	printf '[core]\n\tabbrev = 12\n\tattributesFile = %s\n[diff]\n\tnoprefix = true\n\tcontext = 5\n\tinterHunkContext = 10\n\torderFile = %s\n\tsuppressBlankEmpty = true\n[diff "x"]\n\txfuncname = "^.+$"\n' \
		"${T}/attrs" "${T}/order" > "${T}/gitconfig"
	[ "$(GIT_CONFIG_GLOBAL="${T}/gitconfig" GIT_DIFF_OPTS=-u0 ROOT="$r" harness_sha)" = "$h1" ]
	git -C "$r" checkout -q -- tests/f tests/g
	# So are two contents of an untracked file.
	mkdir -p "$r/config"
	printf 'a\n' > "$r/config/new.env"
	h1="$(ROOT="$r" harness_sha)"
	[[ "$h1" =~ ^v1-dirty\.[0-9a-f]{8}$ ]]
	printf 'b\n' > "$r/config/new.env"
	h2="$(ROOT="$r" harness_sha)"
	[[ "$h2" =~ ^v1-dirty\.[0-9a-f]{8}$ ]]
	[ "$h2" != "$h1" ]
	rm "$r/config/new.env"
	# A run's output dir inside the checkout: --exclude, or the HARNESS_SHA_EXCLUDE a sweep exports.
	mkdir -p "$r/tests/x/results/sweep-1"
	: > "$r/tests/x/results/sweep-1/a.tsv"
	[[ "$(ROOT="$r" harness_sha)" =~ ^v1-dirty\.[0-9a-f]{8}$ ]]
	[ "$(ROOT="$r" harness_sha --exclude "$r/tests/x/results")" = v1 ]
	[ "$(HARNESS_SHA_EXCLUDE="$r/tests/x/results/sweep-1" ROOT="$r" harness_sha)" = v1 ]
	# On a dirty tree too, a file there changes nothing.
	printf 'two\n' > "$r/tests/f"
	h1="$(ROOT="$r" harness_sha --exclude "$r/tests/x/results")"
	[[ "$h1" =~ ^v1-dirty\.[0-9a-f]{8}$ ]]
	printf 'more\n' > "$r/tests/x/results/sweep-1/b.tsv"
	[ "$(ROOT="$r" harness_sha --exclude "$r/tests/x/results")" = "$h1" ]
	[ "$(HARNESS_SHA_EXCLUDE="$r/tests/x/results/sweep-1" ROOT="$r" harness_sha)" = "$h1" ]
	mkdir -p "${T}/plain"
	[ "$(ROOT="${T}/plain" harness_sha)" = unknown ]
}

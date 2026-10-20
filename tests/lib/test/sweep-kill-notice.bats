#!/usr/bin/env bats
# A step whose own process still runs SWEEP_STOP_GRACE_SEC after the sweep's signal gets
# SIGKILL (sweep_step, tests/lib/common.sh): the sweep reaps it quietly, so its console shows
# the warning that names the cleanup, not a bash job notice ("line N: <pid> Killed ...")
# before it. With ps (or /proc) and without. Through a sweep's skeleton; no cluster.

bats_require_minimum_version 1.5.0
load test_helper

# _kill_fixture <dir>: step.sh and sweep.sh in <dir>. `bash sweep.sh <dir>` starts its record
# in <dir>/rec and runs step.sh through sweep_step. The step ignores SIGTERM, writes its PID
# to step-pid, sends SIGTERM to its parent (the sweep) and waits.
_kill_fixture() {
	local d="$1"
	mkdir -p "$d"
	cat > "$d/step.sh" <<'STEP'
#!/usr/bin/env bash
d="$1"
trap '' TERM
echo "$$" > "$d/step-pid"
sleep 0.3
kill -s TERM "$PPID"
for ((n = 0; n < 300; n++)); do sleep 0.1; done
: > "$d/step-done"
STEP
	cat > "$d/sweep.sh" <<'SWEEP'
#!/usr/bin/env bash
set -euo pipefail
source "$ROOT/tests/lib/common.sh"
trap 'sweep_outcome_on_exit "$?" || true' EXIT
sweep_outcome_start "$1/rec" kill-run --next "run it again"
sweep_step "$1/step.sh" "$1"
SWEEP
	chmod +x "$d/step.sh" "$d/sweep.sh"
}

@test "a step that ignores SIGTERM gets SIGKILL after the grace: the warning names the cleanup, and no bash job notice comes before it" {
	local d="${BATS_TEST_TMPDIR}/kill"
	_kill_fixture "$d"
	SWEEP_STOP_GRACE_SEC=1 SWEEP_CLEANUP_CMD="./tests/churn/005-cleanup.sh --contexts ci-a" \
		run --separate-stderr bash "$d/sweep.sh" "$d"
	[ "$status" -eq 143 ] || { echo "status ${status}: ${stderr}"; false; }
	[[ "$stderr" =~ warning:\ [0-9]+\ process\(es\)\ of\ the\ step\ still\ ran\ 1s\ after\ SIGTERM:\ sent\ SIGKILL\ \(their\ own\ cleanup\ did\ not\ run\;\ clean\ up\ with:\ \./tests/churn/005-cleanup\.sh\ --contexts\ ci-a\) ]] \
		|| { echo "$stderr"; false; }
	[[ "$stderr" != *Killed* ]] || { echo "$stderr"; false; }
	[ ! -e "$d/step-done" ]
	run ps -o stat= -p "$(<"$d/step-pid")"
	[[ -z "$output" || "$output" == *Z* ]] || { echo "step still runs: ${output}"; false; }
	grep -qx 'ENDED_SIGNAL=SIGTERM' "$d/rec/sweep-outcome.txt"
}

@test "without a working ps or /proc, the same: the step's SIGKILL leaves no bash job notice" {
	local d="${BATS_TEST_TMPDIR}/kill-nops"
	_kill_fixture "$d"
	# ps: a stub that fails, as on a host with a ps that lacks the needed columns.
	mkdir -p "$d/bin"
	printf '#!/bin/sh\nexit 1\n' > "$d/bin/ps"
	chmod +x "$d/bin/ps"
	PATH="$d/bin:${PATH}" _SWEEP_PROC="$d/no-proc" SWEEP_STOP_GRACE_SEC=1 \
		run --separate-stderr bash "$d/sweep.sh" "$d"
	[ "$status" -eq 143 ] || { echo "status ${status}: ${stderr}"; false; }
	[[ "$stderr" == *"warning: the step still ran 1s after SIGTERM: sent SIGKILL (their own cleanup did not run"* ]] || { echo "$stderr"; false; }
	[[ "$stderr" != *Killed* ]] || { echo "$stderr"; false; }
	[ ! -e "$d/step-done" ]
}

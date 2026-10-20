#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

# _sweep_step_reap: the stop's and sweep_step_kill's wait for the step's process. A step
# that ended as the signal arrived must never leave the sweep waiting on a background
# poller that never ends (bash can still list a gone step as running, and `wait <pid>`
# then waits for any child), and one bash reaped already leaves no job notice.

@test "_sweep_step_reap waits for a step that still runs, and reaps it" {
	run run_timeout 20s bash -c '
		source "$ROOT/tests/lib/common.sh"
		( sleep 1; exit 3 ) &
		p=$!
		_sweep_step_reap "$p"
		echo "rc=$?"
		if kill -0 "$p" 2>/dev/null; then echo "still there"; else echo "reaped"; fi'
	assert_success
	assert_output "rc=0
reaped"
}

@test "_sweep_step_reap: a step bash reaped already (its SIGCHLD handler, before the check) leaves no job notice for a later command" {
	# In a function, as in a sweep's stop: bash prints a pending notice at the next command it
	# waits for (the substitution), or at the script's next top-level command.
	run --separate-stderr run_timeout 20s bash -c '
		source "$ROOT/tests/lib/common.sh"
		t() {
			local p i
			( trap "" TERM; exec sleep 30 ) &
			p=$!
			kill -s KILL "$p"
			# Builtins only: bash waits for no command, so its SIGCHLD handler reaps the step.
			for ((i = 0; i < 1000000; i++)); do kill -0 "$p" 2>/dev/null || break; done
			_sweep_step_reap "$p"
			echo "after: $(echo x)"
		}
		t'
	assert_success
	assert_output "after: x"
	[[ "$stderr" != *Killed* ]] || { echo "$stderr"; false; }
}

@test "a step gone before the stop: _sweep_step_stop and sweep_step_kill return beside a poller that never ends" {
	run run_timeout 20s bash -c '
		source "$ROOT/tests/lib/common.sh"
		sleep 300 &
		poller=$!
		( exit 0 ) &
		_SWEEP_STEP_PID=$! _SWEEP_STEP_OWNER="${BASHPID:-$$}" _SWEEP_STEP_NAME=001-step.sh
		while kill -0 "$_SWEEP_STEP_PID" 2>/dev/null; do sleep 0.1; done
		gone=$_SWEEP_STEP_PID
		_sweep_step_stop TERM
		echo "stop done, pid=${_SWEEP_STEP_PID:-cleared}"
		_SWEEP_STEP_PID=$gone
		sweep_step_kill
		echo "kill done, pid=${_SWEEP_STEP_PID:-cleared}"
		kill "$poller"
		wait "$poller" 2>/dev/null || true'
	assert_success
	assert_line "stop done, pid=cleared"
	assert_line "kill done, pid=cleared"
}

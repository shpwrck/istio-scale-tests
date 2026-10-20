#!/usr/bin/env bats
# A signal a sweep gets while a step runs (sweep_step, tests/lib/common.sh) stops the step's
# whole tree, not the step's PID alone: SIGTERM, SIGINT and SIGHUP sent to the sweep's
# process alone reach every process under the step (its per-context `( ... ) &` workers
# and their commands), a process that ignores the signal gets SIGKILL after
# SWEEP_STOP_GRACE_SEC, the sweep dir's lock is removed only once the tree is gone, and a
# second signal kills what still runs at once. Through a sweep's skeleton (its traps as the
# sweeps install them) and a step shaped like 001 and 005; no cluster.

bats_require_minimum_version 1.5.0
load test_helper

# _sig_fixture <dir>: step.sh and sweep.sh in <dir>. `bash sweep.sh <dir>` starts its record
# and lock in <dir>/rec and runs step.sh through sweep_step. The step: an EXIT trap
# (step-exit), three workers `( sleep 300 & wait ) &` (their PIDs in w1..w3, their sleeps'
# in w1-child..w3-child), with STEP_IGNORER a fourth that ignores TERM, INT and HUP and
# polls the lock (lock-gone-while-alive when it is gone; its PID in ign), with
# STEP_TRAPS INT and HUP traps (step-got); once they all run it touches started and, with
# STEP_KILL=<SIG>, sends <SIG> to its parent (the sweep's process alone), then waits. The
# workers write nothing to the sweep's output: one left running fails the test, it does
# not hang it.
_sig_fixture() {
	local d="$1"
	mkdir -p "$d"
	cat > "$d/step.sh" <<'STEP'
#!/usr/bin/env bash
d="$1"
trap 'echo exit > "$d/step-exit"' EXIT
if [ -n "${STEP_TRAPS:-}" ]; then
	trap 'echo INT >> "$d/step-got"; exit 130' INT
	trap 'echo HUP >> "$d/step-got"; exit 129' HUP
fi
for i in 1 2 3; do
	( sleep 300 & echo "$!" > "$d/w${i}-child.tmp"; mv "$d/w${i}-child.tmp" "$d/w${i}-child"; wait ) >/dev/null 2>&1 &
	echo "$!" > "$d/w${i}"
done
if [ -n "${STEP_IGNORER:-}" ]; then
	( trap '' TERM INT HUP
	echo "$BASHPID" > "$d/ign.tmp"; mv "$d/ign.tmp" "$d/ign"
	while :; do
		[ -e "$d/rec/.sweep.lock" ] || : > "$d/lock-gone-while-alive"
		sleep 0.1
	done ) >/dev/null 2>&1 &
fi
for ((n = 0; n < 300; n++)); do
	[ -e "$d/w1-child" ] && [ -e "$d/w2-child" ] && [ -e "$d/w3-child" ] && { [ -z "${STEP_IGNORER:-}" ] || [ -e "$d/ign" ]; } && break
	sleep 0.1
done
: > "$d/started"
[ -z "${STEP_KILL:-}" ] || kill -s "$STEP_KILL" "$PPID"
wait
: > "$d/step-done"
STEP
	cat > "$d/sweep.sh" <<'SWEEP'
#!/usr/bin/env bash
set -euo pipefail
source "$ROOT/tests/lib/common.sh"
trap 'sweep_outcome_on_exit "$?" || true' EXIT
sweep_outcome_start "$1/rec" sig-run --next "run it again"
sweep_step "$1/step.sh" "$1"
: > "$1/sweep-continued"
SWEEP
	chmod +x "$d/step.sh" "$d/sweep.sh"
}

# _gone <pid>...: each PID is gone (or a zombie not reaped yet).
_gone() {
	local p s
	for p in "$@"; do
		[[ "$p" =~ ^[0-9]+$ ]] || { echo "not a PID: ${p}"; return 1; }
		s="$(ps -o stat= -p "$p" 2>/dev/null | tr -d ' ')"
		[[ -z "$s" || "$s" == Z* ]] || { echo "PID ${p} still runs (${s}): $(ps -o args= -p "$p" 2>/dev/null)"; return 1; }
	done
}

# _tree_pids <dir>: the PIDs the step's processes recorded.
_tree_pids() {
	local f
	for f in w1 w2 w3 w1-child w2-child w3-child ign; do
		[[ ! -s "$1/$f" ]] || cat "$1/$f"
	done
}

# _wait_for <path> [<pattern>]: until <path> exists (and holds <pattern>), at most 30 s.
_wait_for() {
	local i
	for ((i = 0; i < 300; i++)); do
		if [[ -e "$1" ]] && { [[ -z "${2:-}" ]] || grep -q -- "$2" "$1" 2>/dev/null; }; then return 0; fi
		sleep 0.1
	done
	echo "timed out waiting for ${1} ${2:-}" >&2
	return 1
}

teardown() {
	# Only the PIDs the fixtures recorded (a test that failed may leave them).
	local d p
	for d in "$BATS_TEST_TMPDIR"/sig-*; do
		[[ -d "$d" ]] || continue
		for p in $(_tree_pids "$d"); do kill -s KILL "$p" 2>/dev/null || true; done
	done
}

@test "a SIGTERM sent to the sweep's process alone stops its step's whole tree: the step runs its EXIT trap, its workers and their commands are gone when the sweep returns (143), and so is the lock" {
	local d="${BATS_TEST_TMPDIR}/sig-term"
	_sig_fixture "$d"
	STEP_KILL=TERM run --separate-stderr bash "$d/sweep.sh" "$d"
	[ "$status" -eq 143 ] || { echo "status ${status}: ${stderr}"; false; }
	[ -e "$d/started" ]
	[ "$(<"$d/step-exit")" = exit ]
	[ ! -e "$d/step-done" ]
	[ ! -e "$d/sweep-continued" ]
	_gone $(_tree_pids "$d")
	[ "$(_tree_pids "$d" | wc -l)" -eq 6 ]
	[[ "$stderr" =~ Stopping\ the\ running\ step\ \(step\.sh\):\ SIGTERM\ to\ its\ [0-9]+\ process\(es\)\;\ any\ still\ running\ 30s\ later\ get\ SIGKILL\ \(SWEEP_STOP_GRACE_SEC\)\. ]] || { echo "$stderr"; false; }
	[[ "$stderr" != *SIGKILL\ \(their* && "$stderr" != *"sent SIGKILL to its"* ]]
	[ ! -e "$d/rec/.sweep.lock" ]
	grep -qx 'ENDED_SIGNAL=SIGTERM' "$d/rec/sweep-outcome.txt"
}

@test "a SIGINT or SIGHUP sent to the sweep's process alone (a supervisor's kill -INT <pid>) reaches every process of its step's tree as well, which runs its own trap" {
	local d sig st tested=0
	for sig in INT:130 HUP:129; do
		IFS=: read -r sig st <<<"$sig"
		# A shell that ignores the signal (nohup: SIGHUP; some CI runners: SIGINT) passes that
		# on: nothing to test for that one.
		[[ "$(bash -c "trap 'echo t' ${sig}; kill -${sig} \$\$; echo n" 2>/dev/null)" == t* ]] || continue
		tested=$((tested + 1))
		d="${BATS_TEST_TMPDIR}/sig-${sig}"
		_sig_fixture "$d"
		# The sweep as a job of its own (set -m): a background job of a shell without job
		# control ignores SIGINT.
		STEP_TRAPS=1 STEP_KILL="$sig" run bash -c 'set -m; bash "$1" "$2" 2> "$2/err" & wait "$!"' _ "$d/sweep.sh" "$d"
		[ "$status" -eq "$st" ] || { echo "${sig}: status ${status}: $(cat "$d/err")"; false; }
		[ "$(<"$d/step-got")" = "$sig" ]
		[ "$(<"$d/step-exit")" = exit ]
		[ ! -e "$d/sweep-continued" ]
		_gone $(_tree_pids "$d")
		grep -q "Stopping the running step (step.sh): SIG${sig} to its " "$d/err"
		grep -qx "ENDED_SIGNAL=SIG${sig}" "$d/rec/sweep-outcome.txt"
		[ ! -e "$d/rec/.sweep.lock" ]
	done
	((tested)) || skip "SIGINT and SIGHUP are both ignored here"
}

@test "a process of the step that ignores the signal gets SIGKILL after SWEEP_STOP_GRACE_SEC, and the sweep keeps its lock until then" {
	local d="${BATS_TEST_TMPDIR}/sig-ignorer"
	_sig_fixture "$d"
	SWEEP_STOP_GRACE_SEC=1 STEP_IGNORER=1 STEP_KILL=TERM run --separate-stderr bash "$d/sweep.sh" "$d"
	[ "$status" -eq 143 ] || { echo "status ${status}: ${stderr}"; false; }
	[ -s "$d/ign" ]
	_gone $(_tree_pids "$d")
	[[ "$stderr" == *"any still running 1s later get SIGKILL (SWEEP_STOP_GRACE_SEC)."* ]]
	[[ "$stderr" =~ warning:\ [0-9]+\ process\(es\)\ of\ the\ step\ still\ ran\ 1s\ after\ SIGTERM:\ sent\ SIGKILL\ \(their\ own\ cleanup\ did\ not\ run ]] || { echo "$stderr"; false; }
	# It polled the lock until it was killed: the lock was there all along.
	[ ! -e "$d/lock-gone-while-alive" ]
	[ ! -e "$d/rec/.sweep.lock" ]
	grep -qx 'ENDED_SIGNAL=SIGTERM' "$d/rec/sweep-outcome.txt"
}

@test "a second SIGTERM while the sweep waits for its step's processes kills what still runs at once (sweep_step_kill), before the lock is removed" {
	local d="${BATS_TEST_TMPDIR}/sig-twice" p rc=0
	_sig_fixture "$d"
	SWEEP_STOP_GRACE_SEC=300 STEP_IGNORER=1 bash "$d/sweep.sh" "$d" 2> "$d/err" &
	p=$!
	_wait_for "$d/started"
	kill -TERM "$p"
	# The first TERM: the sweep waits up to 300 s for the process that ignores it.
	_wait_for "$d/err" "Stopping the running step"
	kill -TERM "$p"
	wait "$p" || rc=$?
	[ "$rc" -eq 143 ] || { echo "status ${rc}: $(cat "$d/err")"; false; }
	_gone $(_tree_pids "$d")
	grep -qE 'warning: the sweep ended while its step \(step\.sh\) still ran: sent SIGKILL to its [0-9]+ process\(es\)' "$d/err"
	! grep -q 'still ran 300s after' "$d/err" || false
	[ ! -e "$d/lock-gone-while-alive" ]
	[ ! -e "$d/rec/.sweep.lock" ]
	grep -qx 'EXIT=unfinished' "$d/rec/sweep-outcome.txt"
}

@test "sweep_step_kill and the signal handler do nothing in a shell that runs no step, or in a subshell of the one that does" {
	run bash -c 'source "$ROOT/tests/lib/common.sh"; sweep_step_kill; echo "rc=$?"'
	assert_output "rc=0"
	# A subshell of the sweep (not the shell that started the step) leaves the step alone.
	run bash -c '
		source "$ROOT/tests/lib/common.sh"
		sleep 30 &
		sp=$!
		_SWEEP_STEP_PID="$sp" _SWEEP_STEP_OWNER="$$" _SWEEP_STEP_NAME=sleep
		( _sweep_step_stop TERM; sweep_step_kill; echo "sub done" )
		kill -0 "$sp" && echo "step alive"
		kill "$sp"
		wait 2>/dev/null || true'
	assert_line "sub done"
	assert_line "step alive"
	refute_output --partial "Stopping the running step"
}

@test "every sweep's --help says a signal sent to its process alone stops every process under the step (SWEEP_STOP_GRACE_SEC), that a harness change during the sweep is exit 4, and names the lock and the env-only keys; no line is over 100 columns" {
	local f h p
	for f in controlplane/003-run-sweep.sh churn/003-run-sweep.sh dataplane/003-run-sweep.sh \
		churn-dataplane/004-run-sweep.sh propagation/006-run-sweep.sh tuning/003-run-tuning-sweep.sh; do
		run --separate-stderr "${ROOT}/tests/${f}" --help
		assert_success
		h="$(tr '\n' ' ' <<<"$output" | tr -s ' ')"
		for p in "A signal sent to the sweep's process alone" "and every process under it at once" \
			"SWEEP_STOP_GRACE_SEC later get SIGKILL" \
			"the harness (a file under tests/, config/, charts/ or terraform/) changed during the sweep" \
			".sweep.lock" HARNESS_SHA_CHECK_SEC ISTIO_PROXY_READ_PARALLEL; do
			[[ "$h" == *"$p"* ]] || { echo "${f} --help does not say: ${p}"; false; }
		done
		p="$(awk 'length > 100 { print FNR ": " $0 }' <<<"$output")"
		[ -z "$p" ] || { echo "${f} --help, over 100 columns: ${p}"; false; }
	done
}

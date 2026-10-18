#!/usr/bin/env bats
# A sweep's stop where ps does not work (tests/lib/common.sh): on Linux the step's tree is
# read from /proc/<pid>/stat in its place (_sweep_ps_table), so a stop reaches every process
# under the step, and a kill -INT to a sweep in a terminal's foreground skips that group as
# it does with ps; where neither works, the warning comes once per sweep, also on a
# --dry-run, a SIGINT the terminal already sent is not sent again (and the console says so),
# and a second, different signal leaves no watchdog behind. No cluster.

bats_require_minimum_version 1.5.0
load test_helper

# _fixture <dir>: sweep.sh and step.sh in <dir>, a failing ps in <dir>/nops. `bash sweep.sh
# <dir>` runs harness_sha_for_sweep (with SWEEP_HARNESS=1), takes its record and lock in
# <dir>/rec and runs step.sh through sweep_step. The step: an EXIT trap (step-exit), its PID
# in step-pid; with STEP_QUICK it ends at once; with STEP_WORKERS it starts two workers
# `( sleep 300 & wait ) &` (PIDs in w1, w2, their sleeps' in w1-child, w2-child), the second
# in a process group of its own (set -m); with STEP_IGNORE it ignores SIGTERM. It then sends
# STEP_KILL (TERM) to its parent (the sweep's process alone) and polls (at most 30 s).
_fixture() {
	local d="$1"
	mkdir -p "$d/nops"
	printf '#!/bin/sh\necho "sh: ps: not found" >&2\nexit 127\n' > "$d/nops/ps"
	cat > "$d/step.sh" <<'STEP'
#!/usr/bin/env bash
d="$1"
trap 'echo exit > "$d/step-exit"' EXIT
echo "$$" > "$d/step-pid"
[ -z "${STEP_QUICK:-}" ] || exit 0
[ -z "${STEP_IGNORE:-}" ] || trap '' TERM
if [ -n "${STEP_WORKERS:-}" ]; then
	for i in 1 2; do
		[ "$i" != 2 ] || set -m
		( sleep 300 & echo "$!" > "$d/w${i}-child.tmp"; mv "$d/w${i}-child.tmp" "$d/w${i}-child"; wait ) > /dev/null 2>&1 &
		echo "$!" > "$d/w${i}"
		set +m
	done
	for ((n = 0; n < 300; n++)); do
		[ -e "$d/w1-child" ] && [ -e "$d/w2-child" ] && break
		sleep 0.1
	done
fi
sleep 0.3
kill -s "${STEP_KILL:-TERM}" "$PPID"
for ((n = 0; n < 300; n++)); do sleep 0.1; done
: > "$d/step-done"
STEP
	cat > "$d/sweep.sh" <<'SWEEP'
#!/usr/bin/env bash
set -euo pipefail
source "$ROOT/tests/lib/common.sh"
trap 'sweep_outcome_on_exit "$?" || true' EXIT
[ -z "${SWEEP_HARNESS:-}" ] || harness_sha_for_sweep "$1/rec"
sweep_outcome_start "$1/rec" sig-run --next "run it again"
sweep_step "$1/step.sh" "$1"
: > "$1/sweep-continued"
SWEEP
	chmod +x "$d/nops/ps" "$d/step.sh" "$d/sweep.sh"
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

# _pids <dir>: the PIDs the fixture recorded.
_pids() {
	local f
	for f in step-pid w1 w2 w1-child w2-child wd1; do
		[[ ! -s "$1/$f" ]] || cat "$1/$f"
	done
}

# _pty <dir> <out>: run `bash <dir>/sweep.sh <dir>` as the session leader of a new pseudo
# terminal (its stdin, its controlling terminal, and the sweep's group in its foreground),
# stderr to <dir>/err; the exit status (128 + signal) in <out>. python3 drives the terminal.
_pty() {
	python3 - "$1" "$2" <<'PY'
import os, pty, select, signal, sys, time
d, out = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    for s in (signal.SIGINT, signal.SIGHUP, signal.SIGTERM, signal.SIGQUIT, signal.SIGPIPE):
        signal.signal(s, signal.SIG_DFL)
    os.execvp("bash", ["bash", "-c", 'exec bash "$1/sweep.sh" "$1" 2> "$1/err"', "_", d])
deadline, st = time.time() + 60, None
while st is None and time.time() < deadline:
    if select.select([fd], [], [], 0.2)[0]:
        try:
            os.read(fd, 4096)
        except OSError:
            pass
    w, s = os.waitpid(pid, os.WNOHANG)
    if w:
        st = 128 + os.WTERMSIG(s) if os.WIFSIGNALED(s) else os.WEXITSTATUS(s)
if st is None:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    st = "timeout"
with open(out, "w") as f:
    f.write(f"{st}\n")
PY
}

teardown() {
	# Only the PIDs the fixtures recorded (a test that failed may leave them).
	local d p
	for d in "$BATS_TEST_TMPDIR"/sig-*; do
		[[ -d "$d" ]] || continue
		for p in $(_pids "$d"); do kill -s KILL "$p" 2>/dev/null || true; done
	done
}

_need_proc() {
	[[ -r "/proc/$$/stat" ]] || skip "no /proc here (macOS: its ps always works)"
}

@test "_sweep_ps_table reads /proc/<pid>/stat where ps does not work: a command name with spaces and parentheses is read right, and a process that ended since the glob or a short line is skipped" {
	local d="${BATS_TEST_TMPDIR}/fakeproc" rest i
	mkdir -p "$d/nops" "$d/proc/4241" "$d/proc/4242" "$d/proc/4244"
	printf '#!/bin/sh\nexit 127\n' > "$d/nops/ps"
	chmod +x "$d/nops/ps"
	# Fields 3.. of a stat line: state, ppid, pgrp, session, tty, tpgid, then up to starttime
	# (22) and past it.
	rest="S 1 4240 4240 34816 4240"
	for ((i = 9; i <= 52; i++)); do rest+=" $((i == 22 ? 987654 : 0))"; done
	printf '4242 (a b) c) %s\n' "$rest" > "$d/proc/4242/stat"
	# 4241 ended between the glob and the read (its stat a dangling link, listed first); 4244's
	# line is short.
	ln -s "$d/proc/gone/stat" "$d/proc/4241/stat"
	printf '4244 (x) S 1\n' > "$d/proc/4244/stat"
	PATH="$d/nops:${PATH}" _SWEEP_PROC="$d/proc" run --separate-stderr _sweep_ps_table
	assert_success
	assert_output "4242 1 4240 S 4242@987654"
	# This shell is not in that table: a stop could not walk a step's tree from it.
	PATH="$d/nops:${PATH}" _SWEEP_PROC="$d/proc" run _sweep_ps_works
	assert_failure
}

@test "where ps does not work (none, or busybox ps without lstart), a stop reads the step's tree from /proc: no warning at the start, and a SIGTERM reaches every process under the step" {
	_need_proc
	local d kind cnt real
	real="$(command -v ps)"
	for kind in none busybox; do
		d="${BATS_TEST_TMPDIR}/sig-${kind}"
		_fixture "$d"
		[[ "$kind" == none ]] || printf '#!/bin/sh\ncase "$*" in *lstart*) %s -A -o pid=,ppid=,pgid=,stat= ;; *) exec %s "$@" ;; esac\n' "$real" "$real" > "$d/nops/ps"
		PATH="$d/nops:${PATH}" STEP_WORKERS=1 run --separate-stderr bash "$d/sweep.sh" "$d"
		[ "$status" -eq 143 ] || { echo "${kind}: status ${status}: ${stderr}"; false; }
		[[ "$stderr" != *"warning: neither 'ps"* && "$stderr" != *"neither ps nor /proc"* ]] || { echo "${kind}: ${stderr}"; false; }
		cnt="$(grep -o 'Stopping the running step (step.sh): SIGTERM to its [0-9]* process(es)' <<<"$stderr")" || { echo "${kind}: ${stderr}"; false; }
		# The step, its two workers and their sleeps.
		[[ "$cnt" =~ its\ ([0-9]+)\ process ]]
		((BASH_REMATCH[1] >= 5)) || { echo "${kind}: ${cnt}"; false; }
		# shellcheck disable=SC2046  # one PID per word
		_gone $(_pids "$d")
		[ "$(<"$d/step-exit")" = exit ]
		[ ! -e "$d/step-done" ]
		[ ! -e "$d/sweep-continued" ]
		[[ "$stderr" != *"sent SIGKILL"* ]]
		[ ! -e "$d/rec/.sweep.lock" ]
	done
}

@test "a kill -INT to a sweep in a terminal's foreground: with the tree from /proc, the processes of that group are skipped and counted; without ps and /proc, SIGINT is not sent again and the console says why" {
	_need_proc
	command -v python3 >/dev/null 2>&1 || skip "python3 drives the pseudo terminal"
	local d cnt
	d="${BATS_TEST_TMPDIR}/sig-pty"
	_fixture "$d"
	PATH="$d/nops:${PATH}" STEP_WORKERS=1 STEP_KILL=INT SWEEP_STOP_GRACE_SEC=1 _pty "$d" "$d/status"
	[ "$(<"$d/status")" = 130 ] || { echo "status $(<"$d/status"): $(cat "$d/err")"; false; }
	# shellcheck disable=SC2046  # one PID per word
	_gone $(_pids "$d")
	cnt="$(grep -o "Stopping the running step (step.sh): SIGINT to [0-9]* of its [0-9]* process(es); the other [0-9]* are in the terminal's foreground group" "$d/err")" \
		|| { cat "$d/err"; false; }
	[[ "$cnt" =~ to\ ([0-9]+)\ of\ its\ ([0-9]+)\ process.*the\ other\ ([0-9]+)\ are ]]
	# The second worker (a group of its own) was signalled; the step and the first worker, in
	# the sweep's group (the terminal's foreground), were not, and got SIGKILL after the grace.
	((BASH_REMATCH[1] >= 1 && BASH_REMATCH[3] >= 2 && BASH_REMATCH[1] + BASH_REMATCH[3] == BASH_REMATCH[2])) || { echo "$cnt"; false; }
	grep -qE "warning: [0-9]+ process\(es\) of the step still ran 1s after SIGINT: sent SIGKILL" "$d/err"
	[ "$(grep -c "neither" "$d/err")" -eq 0 ]
	# Without ps and /proc: nothing is sent, and the console line says so.
	d="${BATS_TEST_TMPDIR}/sig-pty2"
	_fixture "$d"
	PATH="$d/nops:${PATH}" _SWEEP_PROC="$d/no-proc" STEP_KILL=INT SWEEP_STOP_GRACE_SEC=1 _pty "$d" "$d/status"
	[ "$(<"$d/status")" = 130 ] || { echo "status $(<"$d/status"): $(cat "$d/err")"; false; }
	grep -qF "Stopping the running step (step.sh): neither ps nor /proc works here (see the warning at the sweep's start), and the sweep's stdin is a terminal, so SIGINT is not sent again: a Ctrl-C or a closed terminal reached it (a 'kill -INT <pid>' from elsewhere reaches nothing: stop a sweep from elsewhere with SIGTERM). It gets SIGKILL if it still runs 1s later (SWEEP_STOP_GRACE_SEC)." "$d/err" \
		|| { cat "$d/err"; false; }
	grep -qF "warning: the step still ran 1s after SIGINT: sent SIGKILL" "$d/err"
	[ ! -e "$d/step-exit" ]
	_gone "$(<"$d/step-pid")"
}

@test "without ps and /proc, a second, different signal during the stop's wait stops the first watchdog: none is left when the sweep ends; sweep_step_kill stops one also after the step is gone" {
	local d p rc=0 i wd=""
	d="${BATS_TEST_TMPDIR}/sig-2sig"
	_fixture "$d"
	PATH="$d/nops:${PATH}" _SWEEP_PROC="$d/no-proc" STEP_IGNORE=1 SWEEP_STOP_GRACE_SEC=30 \
		bash "$d/sweep.sh" "$d" < /dev/null > "$d/out" 2> "$d/err" 3>&- &
	p=$!
	# The first stop (the step's SIGTERM, which it ignores) starts the watchdog: the sweep's
	# child that is not the step.
	for ((i = 0; i < 300; i++)); do
		if grep -q "only its own process gets SIGTERM" "$d/err" 2>/dev/null && [[ -s "$d/step-pid" ]]; then
			wd="$(ps -A -o pid=,ppid= | awk -v s="$p" -v st="$(<"$d/step-pid")" '$2 == s && $1 != st { print $1; exit }')"
			[[ -z "$wd" ]] || break
		fi
		sleep 0.1
	done
	[[ -n "$wd" ]] || { kill -s KILL "$p" 2>/dev/null; cat "$d/err"; false; }
	echo "$wd" > "$d/wd1"
	# A SIGHUP (the step does not ignore it) ends the step, and so the sweep.
	kill -s HUP "$p"
	wait "$p" || rc=$?
	[ "$rc" -eq 129 ] || { echo "status ${rc}: $(cat "$d/err")"; false; }
	grep -q "only its own process gets SIGHUP" "$d/err"
	[ "$(<"$d/step-exit")" = exit ]
	_gone "$wd" "$(<"$d/step-pid")"
	[ ! -e "$d/rec/.sweep.lock" ]
	# sweep_step_kill with a watchdog and no step left.
	run bash -c 'source "$ROOT/tests/lib/common.sh"
		sleep 30 > /dev/null 2>&1 &
		_SWEEP_STEP_WD=$! _SWEEP_STEP_OWNER="${BASHPID:-$$}" _SWEEP_STEP_PID=""
		echo "$_SWEEP_STEP_WD"
		sweep_step_kill
		echo "wd=${_SWEEP_STEP_WD}"'
	assert_success
	echo "${lines[0]}" > "$d/wd1"
	assert_line "wd="
	_gone "${lines[0]}"
}

@test "without ps and /proc, every sweep's --dry-run warns once at its start, and a sweep that runs warns once; with /proc in ps's place, none warns" {
	local ek="${BATS_TEST_TMPDIR}/kubeconfig" d="${BATS_TEST_TMPDIR}/sig-dry" s a w
	: > "$ek"
	_fixture "$d"
	w="warning: neither 'ps -A -o pid=,ppid=,pgid=,stat=,lstart=' (no ps, or busybox ps without lstart) nor /proc/<pid>/stat works here"
	for s in "dataplane/003-run-sweep.sh" "churn/003-run-sweep.sh" "churn-dataplane/004-run-sweep.sh" \
		"propagation/006-run-sweep.sh" "controlplane/003-run-sweep.sh --traffic-configs none,vsdr" \
		"tuning/003-run-tuning-sweep.sh --suite churn-dataplane --contexts ci-a,ci-b --gitops-context ci-hub"; do
		a="${s#* }"
		[[ "$a" != "$s" ]] || a=""
		# shellcheck disable=SC2086  # a: the sweep's dry-run arguments
		KUBECONFIG="$ek" PATH="$d/nops:${PATH}" _SWEEP_PROC="$d/no-proc" run --separate-stderr bash "${ROOT}/tests/${s%% *}" --dry-run $a
		assert_success
		[ "$(grep -cF "$w" <<<"$stderr")" -eq 1 ] || { echo "${s}: ${stderr}"; false; }
		if [[ -r "/proc/$$/stat" ]]; then
			# shellcheck disable=SC2086
			KUBECONFIG="$ek" PATH="$d/nops:${PATH}" run --separate-stderr bash "${ROOT}/tests/${s%% *}" --dry-run $a
			assert_success
			[[ "$stderr" != *"$w"* ]] || { echo "${s}: ${stderr}"; false; }
		fi
	done
	# A sweep that runs checks at harness_sha_for_sweep and at sweep_outcome_start: once.
	PATH="$d/nops:${PATH}" _SWEEP_PROC="$d/no-proc" SWEEP_HARNESS=1 STEP_QUICK=1 run --separate-stderr bash "$d/sweep.sh" "$d"
	[ "$(grep -cF "$w" <<<"$stderr")" -eq 1 ] || { echo "$stderr"; false; }
	[ "$(<"$d/step-exit")" = exit ]
}

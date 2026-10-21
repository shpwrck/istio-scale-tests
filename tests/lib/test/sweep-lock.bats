#!/usr/bin/env bats
# One run per sweep dir (sweep_lock, tests/lib/common.sh): a lock whose PID another user
# runs (kill -0: EPERM) is alive, also without a ps where /proc lists it; of several runs
# that find one stale lock at once, exactly one takes it over; a takeover mutex left behind
# stops a run, named; a lock that holds the run's own PID (left before a restart) is taken
# over. No cluster.

bats_require_minimum_version 1.5.0
load test_helper

# _dead_pid: a PID that no process has now (a child that has exited).
_dead_pid() {
	local p
	sh -c 'exit 0' &
	p=$!
	wait "$p" || true
	printf '%s\n' "$p"
}

@test "a lock whose PID kill -0 may not signal (another user's process: EPERM) is alive: the run is refused" {
	local d="${BATS_TEST_TMPDIR}/sweep"
	mkdir -p "$d"
	# A live PID (this test's shell), as if another user ran it: kill -0 fails on it.
	echo "$$" > "$d/.sweep.lock"
	run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"
		kill() { if [[ "$1" == -0 ]]; then return 1; fi; builtin kill "$@"; }
		sweep_lock "$1"
		echo took' _ "$d"
	assert_failure
	refute_output took
	[[ "$stderr" == *"another run of this sweep (PID $$) still runs in ${d}"* ]]
	[ "$(<"$d/.sweep.lock")" = "$$" ]
	# A PID that is gone under the same kill: taken over.
	_dead_pid > "$d/.sweep.lock"
	run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"
		kill() { if [[ "$1" == -0 ]]; then return 1; fi; builtin kill "$@"; }
		sweep_lock "$1"
		echo "took $$"; cat "$1/.sweep.lock"' _ "$d"
	assert_success
	[ "${lines[0]}" = "took ${lines[1]}" ]
	[ ! -e "$d/.sweep.lock.taking" ]
}

@test "without a ps, a lock whose PID kill -0 may not signal is alive while /proc lists it (Linux): the run is refused; a gone PID is taken over" {
	[[ -d /proc/$$ ]] || skip "no /proc here (macOS always has ps)"
	local d="${BATS_TEST_TMPDIR}/sweep"
	mkdir -p "$d"
	echo "$$" > "$d/.sweep.lock"
	# kill -0 fails as on another user's process, and no ps answers: /proc decides.
	run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"
		kill() { if [[ "$1" == -0 ]]; then return 1; fi; builtin kill "$@"; }
		ps() { return 127; }
		sweep_lock "$1"
		echo took' _ "$d"
	assert_failure
	refute_output took
	[[ "$stderr" == *"another run of this sweep (PID $$) still runs in ${d}"* ]]
	[ "$(<"$d/.sweep.lock")" = "$$" ]
	# Without /proc as well (the proc root a missing dir), the same lock reads as stale: what
	# the /proc read prevents.
	run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"
		kill() { if [[ "$1" == -0 ]]; then return 1; fi; builtin kill "$@"; }
		ps() { return 127; }
		_SWEEP_PROC="$2/no-proc"
		sweep_lock "$1"
		echo took' _ "$d" "$BATS_TEST_TMPDIR"
	assert_success
	assert_output took
	# A gone PID with /proc in place: taken over.
	_dead_pid > "$d/.sweep.lock"
	run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"
		kill() { if [[ "$1" == -0 ]]; then return 1; fi; builtin kill "$@"; }
		ps() { return 127; }
		sweep_lock "$1"
		echo took' _ "$d"
	assert_success
	assert_output took
}

@test "of eight runs that find one stale lock at once, exactly one takes it over; the others are refused, naming it" {
	local d="${BATS_TEST_TMPDIR}/sweep" i n
	mkdir -p "$d/out"
	_dead_pid > "$d/.sweep.lock"
	# Each run takes the lock in its own shell (the lock names that shell's PID); the one
	# that holds it waits until the seven others have ended, so none finds it stale again.
	for i in 1 2 3 4 5 6 7 8; do
		{
			bash -c '
				source "$ROOT/tests/lib/common.sh"
				while [[ ! -e "$2/go" ]]; do sleep 0.05; done
				sweep_lock "$1" 2> "$2/err.$3"
				echo "$$" > "$2/held.$3"
				for ((n = 0; n < 600; n++)); do
					[[ "$(find "$2" -name "refused.*" | wc -l)" -lt 7 ]] || break
					sleep 0.05
				done' _ "$d" "$d/out" "$i" || : > "$d/out/refused.${i}"
		} &
	done
	: > "$d/out/go"
	wait
	n="$(find "$d/out" -name 'held.*' | wc -l)"
	[ "$n" -eq 1 ] || { echo "${n} runs hold the lock"; cat "$d"/out/err.*; false; }
	[ "$(find "$d/out" -name 'refused.*' | wc -l)" -eq 7 ]
	[ "$(grep -l 'another run of this sweep (PID [0-9]*) still runs in' "$d"/out/err.* | wc -l)" -eq 7 ]
	# The lock names the one that held it.
	[ "$(<"$d/.sweep.lock")" = "$(cat "$d"/out/held.*)" ]
	[ ! -e "$d/.sweep.lock.taking" ]
}

@test "a takeover mutex left behind (a run died while it took over a stale lock) stops the run, naming it, and changes nothing" {
	local d="${BATS_TEST_TMPDIR}/sweep" dead
	mkdir -p "$d/.sweep.lock.taking"
	dead="$(_dead_pid)"
	echo "$dead" > "$d/.sweep.lock"
	echo "$dead" > "$d/.sweep.lock.taking/pid"
	run --separate-stderr bash -c 'source "$ROOT/tests/lib/common.sh"; sweep_lock "$1"; echo took' _ "$d"
	assert_failure
	refute_output took
	[[ "$stderr" == *"another run (PID ${dead}) is taking over the stale lock of ${d}, or one died doing so: ${d}/.sweep.lock.taking has stayed for 5s (nothing was changed). If no other run is starting there, remove ${d}/.sweep.lock.taking and run again."* ]] || { echo "$stderr"; false; }
	[ "$(<"$d/.sweep.lock")" = "$dead" ]
	[ -d "$d/.sweep.lock.taking" ]
	# Removed as the message says: the next run takes the lock.
	rm -rf "$d/.sweep.lock.taking"
	run --separate-stderr bash -c 'source "$ROOT/tests/lib/common.sh"; sweep_lock "$1"; echo "took $$"; cat "$1/.sweep.lock"' _ "$d"
	assert_success
	[ "${lines[0]}" = "took ${lines[1]}" ]
}

@test "a lock that holds the run's own PID (left before a restart) is taken over; taking it again from the same shell does nothing; the EXIT hook removes only its own lock" {
	local d="${BATS_TEST_TMPDIR}/sweep"
	mkdir -p "$d"
	run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"
		echo "$$" > "$1/.sweep.lock"
		sweep_lock "$1"
		sweep_lock "$1"
		echo "took $$"; cat "$1/.sweep.lock"
		_sweep_unlock
		[[ -e "$1/.sweep.lock" ]] || echo removed' _ "$d"
	assert_success
	[ "${lines[0]}" = "took ${lines[1]}" ]
	assert_line removed
	[ -z "$stderr" ]
	# Another run's lock (its PID now in the file) is left alone by this shell's unlock.
	run --separate-stderr bash -c '
		source "$ROOT/tests/lib/common.sh"
		sweep_lock "$1"
		echo "$PPID" > "$1/.sweep.lock"
		_sweep_unlock
		cat "$1/.sweep.lock"' _ "$d"
	assert_success
	[[ "$output" =~ ^[0-9]+$ ]]
}

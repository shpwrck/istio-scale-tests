#!/usr/bin/env bats
# A sweep's stop without a working ps, in a terminal's foreground, and its console hints
# (tests/lib/common.sh): without ps (or with busybox ps, no lstart) a sweep warns at its
# start with the install hint, and a signal still stops its step's own process, SIGKILL
# after SWEEP_STOP_GRACE_SEC; a kill -INT to a sweep in a terminal's foreground skips the
# processes of that group, and its console line counts the ones it signalled and skipped;
# a SIGKILL names the suite's cleanup (SWEEP_CLEANUP_CMD); a stop prints the sweep's console
# next step (SWEEP_NEXT_CONSOLE). A lock another run has just created and not yet written
# is held (sweep_lock). A bad SWEEP_STOP_GRACE_SEC, HARNESS_SHA_CHECK_SEC or
# ISTIO_PROXY_READ_PARALLEL stops every sweep before any change, named; a probe run alone
# stops on a bad ISTIO_PROXY_READ_PARALLEL. A stopped --resume says how many rows it added.
# No cluster.

bats_require_minimum_version 1.5.0
load test_helper

# _one_fixture <dir>: step.sh and sweep.sh in <dir>. `bash sweep.sh <dir>` starts its record
# and lock in <dir>/rec and runs step.sh through sweep_step. The step: an EXIT trap
# (step-exit), its PID in step-pid; with STEP_IGNORE it ignores SIGTERM; it sends SIGTERM to
# its parent (the sweep's process alone) once its parent waits for it, then polls (at most
# 30 s) until killed.
_one_fixture() {
	local d="$1"
	mkdir -p "$d"
	cat > "$d/step.sh" <<'STEP'
#!/usr/bin/env bash
d="$1"
trap 'echo exit > "$d/step-exit"' EXIT
[ -z "${STEP_IGNORE:-}" ] || trap '' TERM
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
sweep_outcome_start "$1/rec" sig-run --next "run it again"
[ -z "${SWEEP_DIE:-}" ] || die "a stop before the step"
sweep_step "$1/step.sh" "$1"
: > "$1/sweep-continued"
SWEEP
	chmod +x "$d/step.sh" "$d/sweep.sh"
}

# _tree_fixture <dir>: as _one_fixture, but the step starts three workers
# `( sleep 300 & wait ) &` (PIDs in w1..w3, their sleeps' in w1-child..w3-child), the third
# in a process group of its own (set -m), then sends STEP_KILL to its parent and waits.
_tree_fixture() {
	local d="$1"
	_one_fixture "$d"
	cat > "$d/step.sh" <<'STEP'
#!/usr/bin/env bash
d="$1"
trap 'echo exit > "$d/step-exit"' EXIT
for i in 1 2 3; do
	[ "$i" != 3 ] || set -m
	( sleep 300 & echo "$!" > "$d/w${i}-child.tmp"; mv "$d/w${i}-child.tmp" "$d/w${i}-child"; wait ) >/dev/null 2>&1 &
	echo "$!" > "$d/w${i}"
	set +m
done
for ((n = 0; n < 300; n++)); do
	[ -e "$d/w1-child" ] && [ -e "$d/w2-child" ] && [ -e "$d/w3-child" ] && break
	sleep 0.1
done
: > "$d/started"
kill -s "$STEP_KILL" "$PPID"
wait
: > "$d/step-done"
STEP
}

# _ps_stub <bin> <kind>: a ps on <bin>: `none` fails as a missing ps does; `busybox` lists
# pid, ppid, pgid and stat but no lstart; `fg` is the real ps, except that a process's
# tpgid reads as its own process group (a sweep in a terminal's foreground).
_ps_stub() {
	local real
	real="$(command -v ps)"
	mkdir -p "$1"
	case "$2" in
	none) printf '#!/bin/sh\necho "sh: ps: not found" >&2\nexit 127\n' > "$1/ps" ;;
	busybox) printf '#!/bin/sh\ncase "$*" in *lstart*) %s -A -o pid=,ppid=,pgid=,stat= ;; *) exec %s "$@" ;; esac\n' "$real" "$real" > "$1/ps" ;;
	fg) printf '#!/usr/bin/env bash\ncase "$*" in *tpgid=*) exec %s -o pgid= -p "${!#}" ;; esac\nexec %s "$@"\n' "$real" "$real" > "$1/ps" ;;
	esac
	chmod +x "$1/ps"
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

# _pids <dir>: the PIDs the fixtures' steps recorded.
_pids() {
	local f
	for f in step-pid w1 w2 w3 w1-child w2-child w3-child; do
		[[ ! -s "$1/$f" ]] || cat "$1/$f"
	done
}

teardown() {
	# Only the PIDs the fixtures recorded (a test that failed may leave them).
	local d p
	for d in "$BATS_TEST_TMPDIR"/sig-*; do
		[[ -d "$d" ]] || continue
		for p in $(_pids "$d"); do kill -s KILL "$p" 2>/dev/null || true; done
	done
}

@test "without a working ps (none, or busybox ps without lstart) a sweep warns at its start with the install hint; a SIGTERM still stops its step's own process, which runs its EXIT trap, and the sweep ends (143) with its lock gone and its console next step" {
	local d kind
	for kind in none busybox; do
		d="${BATS_TEST_TMPDIR}/sig-${kind}"
		_one_fixture "$d"
		_ps_stub "$d/bin" "$kind"
		PATH="$d/bin:${PATH}" SWEEP_NEXT_CONSOLE="./tests/x/003-run-sweep.sh --resume <dir>" \
			run --separate-stderr bash "$d/sweep.sh" "$d"
		[ "$status" -eq 143 ] || { echo "${kind}: status ${status}: ${stderr}"; false; }
		[[ "$stderr" == *"warning: 'ps -A -o pid=,ppid=,pgid=,stat=,lstart=' does not work here (no ps, or busybox ps without lstart): a signal that stops this sweep reaches only its running step's own process"* ]]
		[[ "$stderr" == *"Install procps: apt-get install procps (Debian, Ubuntu), dnf or microdnf install procps-ng (RHEL, UBI), apk add procps (Alpine)."* ]]
		[[ "$stderr" == *"Stopping the running step (step.sh): ps does not work here (see the warning at the sweep's start), so only its own process gets SIGTERM, not the processes under it; it gets SIGKILL if it still runs 30s later (SWEEP_STOP_GRACE_SEC)."* ]]
		[ "$(<"$d/step-exit")" = exit ]
		[ ! -e "$d/step-done" ] && [ ! -e "$d/sweep-continued" ]
		_gone "$(<"$d/step-pid")"
		[[ "$stderr" != *"sent SIGKILL"* ]]
		[ ! -e "$d/rec/.sweep.lock" ]
		grep -qx 'ENDED_SIGNAL=SIGTERM' "$d/rec/sweep-outcome.txt"
		# The console's next step, in place of the record's.
		[[ "$stderr" == *"  sweep dir: ${d}/rec; next: ./tests/x/003-run-sweep.sh --resume <dir>"* ]]
		grep -qx 'NEXT=run it again' "$d/rec/sweep-outcome.txt"
	done
}

@test "without a working ps, a step that ignores the signal gets SIGKILL after SWEEP_STOP_GRACE_SEC, and the warning names the suite's cleanup command (SWEEP_CLEANUP_CMD)" {
	local d="${BATS_TEST_TMPDIR}/sig-noign"
	_one_fixture "$d"
	_ps_stub "$d/bin" none
	PATH="$d/bin:${PATH}" STEP_IGNORE=1 SWEEP_STOP_GRACE_SEC=1 SWEEP_CLEANUP_CMD="./tests/dataplane/005-cleanup.sh --contexts ci-a" \
		run --separate-stderr bash "$d/sweep.sh" "$d"
	[ "$status" -eq 143 ] || { echo "status ${status}: ${stderr}"; false; }
	[[ "$stderr" == *"warning: the step still ran 1s after SIGTERM: sent SIGKILL (their own cleanup did not run; clean up with: ./tests/dataplane/005-cleanup.sh --contexts ci-a)"* ]] || { echo "$stderr"; false; }
	# SIGKILL: no EXIT trap.
	[ ! -e "$d/step-exit" ] && [ ! -e "$d/step-done" ]
	_gone "$(<"$d/step-pid")"
	[ ! -e "$d/rec/.sweep.lock" ]
}

@test "a kill -INT (or -HUP) to a sweep in a terminal's foreground skips the processes in that group: the console line counts the ones it signalled and the ones it skipped, which get SIGKILL after the grace, named with the cleanup command" {
	local d sig="" st cnt
	if [[ "$(bash -c 'trap "echo t" INT; kill -INT $$; echo n' 2>/dev/null)" == t* ]]; then
		sig=INT st=130
	elif [[ "$(bash -c 'trap "echo t" HUP; kill -HUP $$; echo n' 2>/dev/null)" == t* ]]; then
		sig=HUP st=129
	fi
	[[ -n "$sig" ]] || skip "SIGINT and SIGHUP are both ignored here"
	d="${BATS_TEST_TMPDIR}/sig-fg"
	_tree_fixture "$d"
	_ps_stub "$d/bin" fg
	# The sweep as a job of its own (set -m): a background job of a shell without job
	# control ignores SIGINT.
	PATH="$d/bin:${PATH}" STEP_KILL="$sig" SWEEP_STOP_GRACE_SEC=1 SWEEP_CLEANUP_CMD="./tests/churn/005-cleanup.sh --contexts ci-a" \
		run bash -c 'set -m; bash "$1" "$2" 2> "$2/err" & wait "$!"' _ "$d/sweep.sh" "$d"
	[ "$status" -eq "$st" ] || { echo "status ${status}: $(cat "$d/err")"; false; }
	_gone $(_pids "$d")
	cnt="$(grep -o "Stopping the running step (step.sh): SIG${sig} to [0-9]* of its [0-9]* process(es); the other [0-9]* are in the terminal's foreground group" "$d/err")" \
		|| { cat "$d/err"; false; }
	[[ "$cnt" =~ to\ ([0-9]+)\ of\ its\ ([0-9]+)\ process.*the\ other\ ([0-9]+)\ are ]]
	# The third worker (a group of its own) was signalled; the step and the other workers,
	# in the sweep's group (the terminal's foreground here), were not.
	((BASH_REMATCH[1] >= 1 && BASH_REMATCH[3] >= 1 && BASH_REMATCH[1] + BASH_REMATCH[3] == BASH_REMATCH[2])) || { echo "$cnt"; false; }
	grep -qF "so they are not sent it again (a 'kill -${sig} <pid>' from elsewhere does not reach them: they get SIGKILL; stop a sweep from elsewhere with SIGTERM). Any still running 1s later get SIGKILL (SWEEP_STOP_GRACE_SEC)." "$d/err"
	grep -qE "warning: [0-9]+ process\(es\) of the step still ran 1s after SIG${sig}: sent SIGKILL \(their own cleanup did not run; clean up with: \./tests/churn/005-cleanup\.sh --contexts ci-a\)" "$d/err"
	[ ! -e "$d/step-exit" ]
	[ ! -e "$d/rec/.sweep.lock" ]
}

@test "a sweep that stops (not a signal) prints its console next step after the sweep dir" {
	local d="${BATS_TEST_TMPDIR}/sig-die"
	_one_fixture "$d"
	SWEEP_DIE=1 SWEEP_NEXT_CONSOLE="./tests/x/003-run-sweep.sh --resume <dir>" run --separate-stderr bash "$d/sweep.sh" "$d"
	assert_failure 1
	[[ "$stderr" == *"  sweep dir: ${d}/rec"$'\n'"  next: ./tests/x/003-run-sweep.sh --resume <dir>"* ]] || { echo "$stderr"; false; }
	[ ! -e "$d/step-pid" ]
}

@test "the sweeps that run cleanup steps set SWEEP_CLEANUP_CMD to their suite's cleanup, after the sweep's start" {
	local f
	for f in dataplane/003-run-sweep.sh:dataplane/005-cleanup.sh churn/003-run-sweep.sh:churn/005-cleanup.sh \
		churn-dataplane/004-run-sweep.sh:churn-dataplane/006-cleanup.sh; do
		grep -q "SWEEP_CLEANUP_CMD=\"./tests/${f#*:} --contexts " "${ROOT}/tests/${f%%:*}" || { echo "${f%%:*}"; false; }
	done
	grep -q 'SWEEP_CLEANUP_CMD="./$(show "${CLEANUP_CMD\[@\]}")"' "${ROOT}/tests/tuning/003-run-tuning-sweep.sh"
}

@test "sweep_lock: an empty lock its run fills in 0.5 s later is held (refused, naming that run's PID); one left empty is taken over" {
	local d="${BATS_TEST_TMPDIR}/lk" holder
	mkdir -p "$d"
	sleep 30 &
	holder=$!
	: > "$d/.sweep.lock"
	( sleep 0.5; printf '%s\n' "$holder" > "$d/.sweep.lock" ) &
	run --separate-stderr bash -c 'source "$ROOT/tests/lib/common.sh"; sweep_lock "$1"; echo took' _ "$d"
	kill "$holder" 2>/dev/null || true
	wait "$holder" 2>/dev/null || true
	assert_failure
	refute_output took
	[[ "$stderr" == *"another run of this sweep (PID ${holder}) still runs in ${d}"* ]] || { echo "$stderr"; false; }
	# A lock that stays empty (its run died between creating and writing it): stale.
	: > "$d/.sweep.lock"
	run --separate-stderr bash -c 'source "$ROOT/tests/lib/common.sh"; sweep_lock "$1"; echo "took $$"; cat "$1/.sweep.lock"' _ "$d"
	assert_success
	[ "${lines[0]}" = "took ${lines[1]}" ]
	[ ! -e "$d/.sweep.lock.taking" ]
}

@test "a bad SWEEP_STOP_GRACE_SEC, HARNESS_SHA_CHECK_SEC or ISTIO_PROXY_READ_PARALLEL stops every sweep at its start (also --dry-run), naming the key and its value" {
	local ek="${BATS_TEST_TMPDIR}/kubeconfig" s a kv k
	: > "$ek"
	for s in "dataplane/003-run-sweep.sh" "churn/003-run-sweep.sh" "churn-dataplane/004-run-sweep.sh" \
		"propagation/006-run-sweep.sh" "controlplane/003-run-sweep.sh --traffic-configs none,vsdr" \
		"tuning/003-run-tuning-sweep.sh --suite churn-dataplane --contexts ci-a,ci-b --gitops-context ci-hub"; do
		a="${s#* }"
		[[ "$a" != "$s" ]] || a=""
		for kv in SWEEP_STOP_GRACE_SEC=x HARNESS_SHA_CHECK_SEC=-1 SWEEP_STOP_GRACE_SEC=1.5 ISTIO_PROXY_READ_PARALLEL=0 ISTIO_PROXY_READ_PARALLEL=many; do
			k="${kv%%=*}"
			# shellcheck disable=SC2086  # a: the sweep's dry-run arguments
			KUBECONFIG="$ek" run --separate-stderr env "$kv" bash "${ROOT}/tests/${s%% *}" --dry-run $a
			[ "$status" -eq 1 ] || { echo "${s} ${kv}: status ${status}"; false; }
			[[ "$stderr" == *"error: ${k} must be a "*" integer of "*" (got: ${kv#*=}); see config/options.env"* ]] || { echo "${s} ${kv}: ${stderr}"; false; }
			[[ "$output" != *"Dry run complete"* && "$output" != *"=== Dry"* ]]
		done
	done
	# Zero is a valid grace and check interval.
	KUBECONFIG="$ek" run --separate-stderr env SWEEP_STOP_GRACE_SEC=0 HARNESS_SHA_CHECK_SEC=0 bash "${ROOT}/tests/dataplane/003-run-sweep.sh" --dry-run
	assert_success
}

@test "a probe run alone stops on a bad ISTIO_PROXY_READ_PARALLEL before any change to the cluster, naming it" {
	local bin="${BATS_TEST_TMPDIR}/bin" log="${BATS_TEST_TMPDIR}/kubectl.log"
	mkdir -p "$bin"
	printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\ncase "$*" in *" version "*) echo "{}" ;; esac\nexec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@"\n' "$log" > "$bin/kubectl"
	chmod +x "$bin/kubectl"
	ISTIO_PROXY_READ_PARALLEL=0 PATH="${bin}:${PATH}" run --separate-stderr "${ROOT}/tests/dataplane/002-run-latency-probe.sh" \
		--source-context ci-a --qps-levels 10 --settle 0 --warmup-duration 0 --reach-requests 0 --output-dir "${BATS_TEST_TMPDIR}/res"
	assert_failure 1
	[[ "$stderr" == *"error: ISTIO_PROXY_READ_PARALLEL must be a positive integer of members (got: 0); see config/options.env"* ]] || { echo "$stderr"; false; }
	# Only reads ran (the Kubernetes versions), nothing that changes a member.
	! grep -qE ' (apply|create|delete|patch|scale|label|annotate|exec|rollout) ' "$log"
}

@test "a --resume that stopped says how many rows it added before it stopped: none, or the count, in every format; not known without the TSV's RESUMED_AT line" {
	local d="${BATS_TEST_TMPDIR}/stopres" t=2026-01-02T03:04:05Z
	mkdir -p "$d"
	printf 'RUN_ID=sweep-r1\nEXIT=4\nFAILED=1\nTOTAL=4\nFAILED_BY=PROBE_FAILED x1\n' > "$d/sweep-outcome.prev.txt"
	printf 'RUN_ID=sweep-r1\nEXIT=1\nSTOPPED=1\nSTOP_REASON=could not write the plan\nCUT_SHORT=1\nSTARTED_AT=2026-01-01T00:00:00Z\nRESUMED_AT=%s\nENDED_AT=2026-01-02T03:05:00Z\n' "$t" > "$d/sweep-outcome.txt"
	# The TSV: the first run's rows, then the resume's line (written in the +00:00 form an
	# older resume used) and no row after it.
	printf '# RUN_ID=sweep-r1\nrun_id\tx\nsweep-r1\t1\nsweep-r1\t2\n# RESUMED_AT=2026-01-02T03:04:05+00:00 HARNESS_SHA=v1\n' > "$d/controlplane-sweep-r1.tsv"
	run sweep_outcome_recorded "$d" text
	assert_output --partial "this stop ended a --resume of the sweep (started at ${t}): the outcome before it, from sweep-outcome.prev.txt, follows; that --resume added no rows before it stopped"
	refute_output --partial "uncounted"
	run sweep_outcome_recorded "$d" csv
	assert_line "# WARNING: this stop ended a --resume of the sweep (started at ${t}): the outcome before it, from sweep-outcome.prev.txt, follows; that --resume added no rows before it stopped"
	# Two rows after it (a comment line and a blank line do not count).
	printf 'sweep-r1\t3\n# a note\n\nsweep-r1\t4\n' >> "$d/controlplane-sweep-r1.tsv"
	run sweep_outcome_recorded "$d" md
	assert_output --partial "the 2 row(s) that --resume added before it stopped are in the TSV, uncounted"
	# Without the line (an older resume, or another suite): not known.
	sed -i.bak '/^# RESUMED_AT=/d' "$d/controlplane-sweep-r1.tsv"
	run sweep_outcome_recorded "$d" text
	assert_output --partial "follows; the rows that --resume added before it stopped are in the TSV, uncounted"
	# A RESUMED_AT line of another resume does not count for this one.
	printf '# RESUMED_AT=2025-12-31T00:00:00Z\nsweep-r1\t5\n' >> "$d/controlplane-sweep-r1.tsv"
	run sweep_outcome_recorded "$d" text
	assert_output --partial "follows; the rows that --resume added before it stopped are in the TSV, uncounted"
}

@test "every sweep's --help, the top-level README, the suite READMEs and PL45 say that a kill -INT or -HUP skips a terminal's foreground (stop such a sweep with SIGTERM), that without a ps that lists start times a stop reaches only the step's own process, the 30 s grace, and which of the sweep's own commands finish first" {
	local f h p ps="Stopping the step's tree needs a ps that lists start times (procps, or macOS's): without one, the sweep warns at its start, and a stop reaches only the step's own process."
	for f in controlplane/003-run-sweep.sh churn/003-run-sweep.sh dataplane/003-run-sweep.sh \
		churn-dataplane/004-run-sweep.sh propagation/006-run-sweep.sh tuning/003-run-tuning-sweep.sh; do
		run --separate-stderr "${ROOT}/tests/${f}" --help
		assert_success
		h="$(tr '\n' ' ' <<<"$output" | tr -s ' ')"
		for p in "For a sweep in a terminal's foreground, a kill -INT or -HUP skips the processes in that foreground" \
			"stop such a sweep from elsewhere with SIGTERM" "The sweep's own commands between steps (" "finish first, each bounded" \
			"$ps" "SWEEP_STOP_GRACE_SEC (30): how long a signalled sweep waits"; do
			[[ "$h" == *"$p"* ]] || { echo "${f} --help does not say: ${p}"; false; }
		done
		[[ "$h" != *"Only a settle wait finishes first"* ]]
	done
	for f in README.md tests/tuning/README.md; do
		h="$(tr '\n' ' ' < "${ROOT}/${f}" | tr -s ' ')"
		for p in "skips the processes in that foreground" "stop such a sweep from elsewhere with SIGTERM" \
			"The sweep's own commands between steps finish first, each bounded" \
			"needs a \`ps\` that lists" "without one, the sweep warns at its start, and a stop reaches only the step's own process"; do
			[[ "$h" == *"$p"* ]] || { echo "${f} does not say: ${p}"; false; }
		done
	done
	grep -qF '`SWEEP_STOP_GRACE_SEC` (30) seconds later' "${ROOT}/README.md"
	[[ "$(tr '\n' ' ' < "${ROOT}/tests/tuning/README.md")" == *'`SWEEP_STOP_GRACE_SEC`, 30 s by default, later get SIGKILL'* ]]
	# The suite READMEs' short form (the top-level README has the rest).
	for f in controlplane churn dataplane churn-dataplane propagation; do
		h="$(tr '\n' ' ' < "${ROOT}/tests/${f}/README.md" | tr -s ' ')"
		for p in "\`SWEEP_STOP_GRACE_SEC\` (30 s) before SIGKILL" \
			"a \`kill -INT\` or \`kill -HUP\` skips the processes of a sweep in a terminal's foreground, so stop such a sweep from elsewhere with SIGTERM" \
			"without a \`ps\` that lists start times, only the step's own process is stopped"; do
			[[ "$h" == *"$p"* ]] || { echo "tests/${f}/README.md does not say: ${p}"; false; }
		done
	done
	# PL45 names both: the foreground skip with the SIGTERM advice, and the ps fallback.
	h="$(sed -n '/^## PL45/,/^## PL46/p' "${ROOT}/docs/scale-test-team/process-learnings.md")"
	for p in "to stop a sweep that holds a terminal from elsewhere, send SIGTERM" "Without a working \`ps\`" \
		"a stop signals the step's own PID"; do
		[[ "$h" == *"$p"* ]] || { echo "PL45 does not say: ${p}"; false; }
	done
}

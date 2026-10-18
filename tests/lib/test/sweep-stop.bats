#!/usr/bin/env bats
# A sweep that ends before its outcome: a stop after its start (die, the ERR trap, set -e
# in a function) records why and what to do; Ctrl-C, SIGTERM and SIGHUP leave it not
# finished and interrupted, and it still dies of the signal; the EXIT hook writes nothing
# where it must not; every sweep installs its traps that way. Through a sweep's skeleton
# and the real sweeps (PL33); no cluster: kubectl and curl are stubs, or kubectl fails
# against an empty kubeconfig.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
	EK="${BATS_TEST_TMPDIR}/empty.kubeconfig"
	: > "$EK"
	export TMPDIR="$BATS_TEST_TMPDIR"
}

# _skeleton_sweep: a sweep's skeleton in skeleton.sh, its traps as the six sweeps install them:
# `bash skeleton.sh <dir> <case>` starts its record in <dir> (run skel-run), then ends as <case>.
_skeleton_sweep() {
	cat > "${BATS_TEST_TMPDIR}/skeleton.sh" <<'SH'
set -euo pipefail
source "${ROOT}/tests/lib/common.sh"
trap 'sweep_err_trap "$?" "$LINENO" "$BASH_COMMAND"' ERR
D="$1"
# tun / tun-bare: tuning's on_exit shape, its first echo failing (a terminal that closed),
# called with and without `|| true`.
on_exit_t() {
	local rc=$?
	echo ">>> reverting p before exit" >&9
	: > "${D}/reverted"
	sweep_outcome_on_exit "$rc" || true
}
if [[ "$2" == notes ]]; then
	trap 'sweep_outcome_on_exit "$?" --note "REVERT_FAILED: profile p is still applied" || true' EXIT
elif [[ "$2" == problem-* ]]; then
	# tuning's shape: what its Istio CR generation checks found so far, then its own notes.
	trap 'sweep_outcome_on_exit "$?" --problem "the Istio CR changed while the sweep changed nothing" --note "a member could not be compared" || true' EXIT
elif [[ "$2" == tun ]]; then
	trap 'on_exit_t || true' EXIT
elif [[ "$2" == tun-bare ]]; then
	trap 'on_exit_t' EXIT
else
	trap 'sweep_outcome_on_exit "$?" || true' EXIT
fi
sweep_outcome_start "$D" skel-run --next "if it died, run it again into a new dir"
# $? is 1 from here on, as anywhere in a sweep: an EXIT trap a signal runs sees that, so
# only the signal traps can say a signal came.
[[ -n "" ]] && echo never
case "$2" in
die | notes | tun | tun-bare | problem-die) die "the members went away" ;;
err) false ;;
err4) sh -c 'exit 4' ;;
fn) f() { false; echo never; }; f ;;
fn4) f() { sh -c 'exit 4'; echo never; }; f ;;
int) sh -c 'kill -INT "$PPID"'; sleep 2; echo after ;;
term | problem-term) sh -c 'kill -TERM "$PPID"'; echo after ;;
hup) sh -c 'kill -HUP "$PPID"'; echo after ;;
child) x="$(sh -c 'kill -TERM $$')" ;;
sub)
	(trap 'sweep_outcome_on_exit 1 || true' EXIT; exit 1) || true
	cp "${D}/sweep-outcome.txt" "${D}/after-subshell.txt"
	die "after the subshell" ;;
done) sweep_outcome --run-id skel-run --record "$D" 1; exit 0 ;;
other) sed -i.bak 's/^RUN_ID=.*/RUN_ID=another-run/' "${D}/sweep-outcome.txt"; die "after another run took the dir" ;;
kill) kill -KILL $$ ;;
esac
echo "fell through"
SH
}

# _skeleton_run <case>: skeleton.sh into a fresh dir, its record in $REC.
_skeleton_run() {
	D="${BATS_TEST_TMPDIR}/skel-$1"
	REC="${D}/sweep-outcome.txt"
	ROOT="$ROOT" run --separate-stderr bash "${BATS_TEST_TMPDIR}/skeleton.sh" "$D" "$1"
}

# _stop_stub <dir>: a kubectl (and oc) that fails every call, as against an empty kubeconfig,
# and that first turns the sweep's markdown summary path (SS_MD, RID for the run id) into a
# directory, so the sweep's own write of it fails at the top level, after its start: an
# unexpected abort (the ERR trap). It keeps a copy of the sweep's record as each call saw it
# (record-at-last-kubectl.txt). SS_INT: its first call after the sweep's start, once a TSV
# is written, sends the sweep SIGINT. SS_CR: the Istio CR reads answer as
# fake-istio-cr.sh (a version a --resume can match). STUB_ISTIOD: one istiod pod
# (churn-dataplane's preflight).
_stop_stub() {
	mkdir -p "$1"
	cat > "${1}/kubectl" <<'STUB'
#!/bin/sh
for d in "$SS_RES"/sweep-*; do
	[ -d "$d" ] || continue
	m="$d/$(printf '%s' "${SS_MD:-}" | sed "s/RID/${d##*/sweep-}/")"
	[ -z "${SS_MD:-}" ] || [ -e "$m" ] || mkdir "$m"
	# What the sweep's record said at this call (the last call wins).
	cp "$d/sweep-outcome.txt" "$SS_RES/record-at-last-kubectl.txt" 2>/dev/null || :
	# SS_INT: once the sweep has started and written a TSV, Ctrl-C reaches it (its
	# *run-sweep.sh ancestor).
	if [ -n "${SS_INT:-}" ] && [ -f "$d/sweep-outcome.txt" ] && [ ! -e "$SS_RES/int-sent" ] \
		&& [ -n "$(find "$d" -name '*.tsv' -type f 2>/dev/null | head -n 1)" ]; then
		p=$PPID
		while [ "${p:-1}" -gt 1 ]; do
			case "$(ps -o args= -p "$p" 2>/dev/null)" in *run-sweep.sh*) : > "$SS_RES/int-sent"; kill -INT "$p"; break ;; esac
			p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
		done
	fi
done
case "$*" in
*"get istios.sailoperator.io default"*|*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	[ -n "${SS_CR:-}" ] || exit 1
	exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" get pods "*"-l app=istiod"*) [ -z "${STUB_ISTIOD:-}" ] || echo istiod-0 ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${1}/kubectl"
	cp "${1}/kubectl" "${1}/oc"
}

# _trap_steps_guarded <file>: every step of each of its single-line EXIT traps ends in
# `|| true` or is the `_sweep_rc=$?` assignment (a subshell's pid cleanup trap left out):
# set -e in a trap stops it at a failed step (an echo to a closed terminal) before the
# record.
_trap_steps_guarded() {
	local line step
	local -a steps
	while IFS= read -r line; do
		line="${line#*trap \'}"
		line="${line%\' EXIT}"
		IFS=';' read -r -a steps <<<"$line"
		for step in "${steps[@]}"; do
			step="${step# }"
			[[ "$step" == *"|| true" || "$step" == '_sweep_rc=$?' ]] || { echo "${1}: EXIT trap step not guarded: ${step}"; return 1; }
		done
	done < <(grep -E "^[[:space:]]*trap '.*' EXIT$" "$1" | grep -vF 'pids[@]')
}

@test "a sweep that stops after its start records why (die, the ERR trap, set -e in a function), its notes and what to do, and exits 1 whatever code failed; the reports show a stop, not a run that has not finished; an EXIT trap step that fails stops nothing" {
	_skeleton_sweep
	_skeleton_run die
	assert_failure 1
	[[ "$stderr" == *"error: the members went away"* ]]
	grep -qx 'EXIT=1' "$REC"
	grep -qx 'STOPPED=1' "$REC"
	grep -qx 'STOP_REASON=the members went away' "$REC"
	grep -qx 'TOTAL=unknown' "$REC"
	grep -qx 'FAILED=unknown' "$REC"
	grep -q "^PROBLEM=could not count the sweep's cells: it stopped before its end at [0-9T:-]*Z, so no count vouches for its rows, which may be partial$" "$REC"
	grep -qx 'NOTE=next: run it again into a new dir' "$REC"
	grep -qx 'CUT_SHORT=1' "$REC"
	grep -q '^STARTED_AT=[0-9T:-]*Z$' "$REC"
	grep -q '^ENDED_AT=[0-9T:-]*Z$' "$REC"
	grep -qx 'RUN_ID=skel-run' "$REC"
	! grep -q '^ENDED_SIGNAL=' "$REC"
	sweep_outcome_cut_short "$REC"
	! sweep_outcome_unfinished "$REC"
	run sweep_outcome_recorded "$D" text
	assert_output --partial "SWEEP OUTCOME (recorded in sweep-outcome.txt by run skel-run, exit 1):"
	assert_output --partial "  stopped early: the members went away"
	refute_output --partial "NOT FINISHED"
	run sweep_outcome_recorded "$D" md
	assert_output --partial "the members went away"
	run sweep_outcome_recorded "$D" json
	[ "$(jq -c '[.exit, .unfinished, .stop_reason, (.problems | length), .notes]' <<<"$output")" = '[1,false,"the members went away",1,["next: run it again into a new dir"]]' ]
	# csv says it stopped, as json and text do, with the stop record's times.
	run sweep_outcome_recorded "$D" csv
	assert_line "# SWEEP_OUTCOME_EXIT=1"
	assert_line "# SWEEP_OUTCOME_STOPPED=1"
	assert_line "# SWEEP_OUTCOME_CUT_SHORT=1"
	assert_line --regexp '^# SWEEP_OUTCOME_STARTED_AT=[0-9T:-]+Z$'
	assert_line --regexp '^# SWEEP_OUTCOME_ENDED_AT=[0-9T:-]+Z$'
	assert_line "# SWEEP_OUTCOME_STOP_REASON=the members went away"
	# The ERR trap: the FATAL line names the script, the line and the command, and so does
	# the record.
	_skeleton_run err
	assert_failure 1
	[[ "$stderr" =~ FATAL:\ skeleton\.sh\ aborted\ \(exit\ 1\)\ at\ line\ [0-9]+:\ false ]]
	grep -qE '^STOP_REASON=skeleton\.sh aborted \(exit 1\) at line [0-9]+: false$' "$REC"
	grep -qx 'EXIT=1' "$REC"
	grep -qx 'CUT_SHORT=1' "$REC"
	# set -e in a function runs no ERR trap: the exit it took is the reason.
	_skeleton_run fn
	assert_failure 1
	grep -qx 'STOP_REASON=it exited 1 before its end (an unexpected failure: see its console output)' "$REC"
	grep -qx 'STOPPED=1' "$REC"
	# A note the EXIT trap passes (tuning: a revert that failed on exit) is recorded.
	_skeleton_run notes
	assert_failure 1
	grep -qx 'NOTE=REVERT_FAILED: profile p is still applied' "$REC"
	grep -qx 'NOTE=next: run it again into a new dir' "$REC"
	# A problem the EXIT trap passes (tuning: an Istio CR generation check) stays a problem
	# in the stop record, which counts it; the interrupted record keeps it as a note (a
	# not-finished record counts nothing; the Ctrl-C test below).
	_skeleton_run problem-die
	assert_failure 1
	grep -qx 'STOPPED=1' "$REC"
	grep -qx 'PROBLEM=the Istio CR changed while the sweep changed nothing' "$REC"
	grep -qx 'NOTE=a member could not be compared' "$REC"
	run sweep_outcome_recorded "$D" json
	[ "$(jq -c '[.exit, (.problems | length), (.problems | index("the Istio CR changed while the sweep changed nothing") != null), (.notes | index("a member could not be compared") != null)]' <<<"$output")" = '[1,2,true,true]' ]
	# A stop exits 1 whatever code the failed command had (4 would read as failed cells,
	# 3 as a reachability stop); the record keeps that code in its reason.
	_skeleton_run err4
	assert_failure 1
	grep -qE "^STOP_REASON=skeleton\.sh aborted \(exit 4\) at line [0-9]+: sh -c 'exit 4'$" "$REC"
	grep -qx 'EXIT=1' "$REC"
	_skeleton_run fn4
	assert_failure 1
	grep -qx 'STOP_REASON=it exited 4 before its end (an unexpected failure: see its console output)' "$REC"
	grep -qx 'EXIT=1' "$REC"
	run sweep_outcome_recorded "$D" json
	[ "$(jq -c '[.exit, .unfinished]' <<<"$output")" = '[1,false]' ]
	# Tuning's EXIT trap runs as `on_exit || true`: an echo that fails (a closed terminal)
	# does not stop it before the revert and the record; without the guard it does.
	_skeleton_run tun
	assert_failure 1
	[ -e "${D}/reverted" ]
	grep -qx 'STOPPED=1' "$REC"
	_skeleton_run tun-bare
	[ ! -e "${D}/reverted" ]
	grep -qx 'EXIT=unfinished' "$REC"
}

@test "Ctrl-C, SIGTERM and SIGHUP after a sweep's start leave it not finished, interrupted at a time by that signal (whatever \$? was), and it still dies of the signal; so does a command a signal killed" {
	# A shell that ignores SIGINT or SIGHUP (nohup: SIGHUP; some CI runners: SIGINT) passes
	# that on to the sweep: those cases are left out there (SIGTERM is always checked).
	local c sig st compat ign=""
	[[ "$(bash -c 'trap "echo t" INT; kill -INT $$; echo n' 2>/dev/null)" == t* ]] || ign+=" int"
	[[ "$(bash -c 'trap "echo t" HUP; kill -HUP $$; echo n' 2>/dev/null)" == t* ]] || ign+=" hup"
	_skeleton_sweep
	for compat in "" 51; do
		for c in int:SIGINT:130 hup:SIGHUP:129 term:SIGTERM:143; do
			IFS=: read -r c sig st <<<"$c"
			[[ "$ign " != *" ${c} "* ]] || continue
			BASH_COMPAT="$compat" _skeleton_run "$c"
			[ "$status" -eq "$st" ] || { echo "${c} (compat ${compat}): ${status} ${stderr}"; false; }
			[[ "$output" != *after* ]]
			[[ "$stderr" == *"warning: the sweep was interrupted (${sig}, exit ${st}) before its outcome; sweep-outcome.txt says it has not finished"* ]]
			grep -qx 'EXIT=unfinished' "$REC"
			grep -q '^ENDED_AT=[0-9T:-]*Z$' "$REC"
			grep -qx "ENDED_EXIT=${st}" "$REC"
			grep -qx "ENDED_SIGNAL=${sig}" "$REC"
			! grep -q '^STOP' "$REC"
			sweep_outcome_unfinished "$REC"
		done
	done
	# The last run was SIGTERM; the reports name each signal.
	run sweep_outcome_recorded "$D" text
	assert_output --partial "NOT FINISHED"
	assert_output --regexp "this sweep has not finished: the run that started at [0-9T:-]+Z was interrupted at [0-9T:-]+Z \(SIGTERM\) before it wrote its outcome, so no cell count vouches for these results, which may be partial; next: run it again into a new dir"
	run sweep_outcome_recorded "$D" json
	[ "$(jq -c '[.exit, .unfinished, (.interrupted_at | test("Z$")), .interrupted_by]' <<<"$output")" = '[null,true,true,"SIGTERM"]' ]
	run sweep_outcome_recorded "$D" csv
	assert_line "# SWEEP_OUTCOME_EXIT=unfinished"
	assert_line "# SWEEP_OUTCOME_INTERRUPTED_BY=SIGTERM"
	assert_line --regexp '^# SWEEP_OUTCOME_INTERRUPTED_AT=[0-9T:-]+Z$'
	if [[ "$ign " != *" hup "* ]]; then
		_skeleton_run hup
		run sweep_outcome_recorded "$D" text
		assert_output --partial "(SIGHUP: its terminal closed) before it wrote its outcome"
	fi
	if [[ "$ign " != *" int "* ]]; then
		_skeleton_run int
		run sweep_outcome_recorded "$D" text
		assert_output --partial "(SIGINT: Ctrl-C) before it wrote its outcome"
	fi
	# The problems and notes the EXIT trap passes: one NOTE= line each, no PROBLEM= line.
	_skeleton_run problem-term
	assert_failure 143
	grep -qx 'EXIT=unfinished' "$REC"
	grep -qx 'NOTE=the Istio CR changed while the sweep changed nothing' "$REC"
	grep -qx 'NOTE=a member could not be compared' "$REC"
	! grep -q '^PROBLEM=' "$REC"
	run sweep_outcome_recorded "$D" text
	assert_output --partial "NOT FINISHED"
	assert_output --partial "the Istio CR changed while the sweep changed nothing"
	# A command a signal killed (its exit 143 through the ERR trap): interrupted, no signal named.
	_skeleton_run child
	assert_failure 143
	grep -qx 'EXIT=unfinished' "$REC"
	grep -qx 'ENDED_EXIT=143' "$REC"
	! grep -q '^ENDED_SIGNAL=' "$REC"
	run sweep_outcome_recorded "$D" text
	assert_output --partial "(exit 143, no error recorded) before it wrote its outcome"
}

@test "the EXIT hook writes nothing in a subshell, after the outcome, or over another run's record; a sweep killed outright (SIGKILL) keeps its record as it was: it died, or still runs" {
	_skeleton_sweep
	_skeleton_run sub
	assert_failure 1
	# The subshell's EXIT trap left the record alone; the sweep's own then recorded the die.
	grep -qx 'EXIT=unfinished' "${D}/after-subshell.txt"
	! grep -q '^ENDED_AT=' "${D}/after-subshell.txt"
	grep -qx 'STOP_REASON=after the subshell' "$REC"
	_skeleton_run done
	assert_success
	grep -qx 'EXIT=0' "$REC"
	! grep -q '^CUT_SHORT=\|^ENDED_AT=' "$REC"
	# A finished sweep's csv names no stop.
	run sweep_outcome_recorded "$D" csv
	assert_line "# SWEEP_OUTCOME_EXIT=0"
	refute_output --partial "STOPPED="
	refute_output --partial "CUT_SHORT="
	_skeleton_run other
	assert_failure 1
	grep -qx 'RUN_ID=another-run' "$REC"
	grep -qx 'EXIT=unfinished' "$REC"
	! grep -q '^ENDED_AT=\|^STOP' "$REC"
	_skeleton_run kill
	[ "$status" -eq 137 ]
	grep -qx 'EXIT=unfinished' "$REC"
	! grep -q '^ENDED_AT=\|^STOP\|^CUT_SHORT' "$REC"
	run sweep_outcome_recorded "$D" text
	assert_output --partial "this sweep has not finished (it died, or still runs): the run that started at "
}

@test "through each sweep, an unexpected abort after its start (its markdown summary cannot be written) records a stop naming the script, line and command; propagation runs its cleanup first" {
	local suite script md res d bin="${BATS_TEST_TMPDIR}/stopbin" rep
	local -a more
	_stop_stub "$bin"
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0
	for suite in dataplane churn churn-dataplane propagation controlplane; do
		res="${BATS_TEST_TMPDIR}/stopres-${suite}"
		more=()
		case "$suite" in
		dataplane) script=dataplane/003-run-sweep.sh md='sweep-RID.md' rep=dataplane/004-report-results.sh ;;
		churn) script=churn/003-run-sweep.sh md='sweep-RID.md' rep=churn/004-report-results.sh ;;
		churn-dataplane) script=churn-dataplane/004-run-sweep.sh md='sweep-summary-RID.md' rep=churn-dataplane/005-report-results.sh ;;
		propagation) script=propagation/006-run-sweep.sh md='sweep-summary.md' rep=propagation/005-report-results.sh ;;
		controlplane) script=controlplane/003-run-sweep.sh md='sweep-RID.md' rep=controlplane/004-report-results.sh more=(--service-counts 5) ;;
		esac
		SS_RES="$res" SS_MD="$md" STUB_ISTIOD=1 DATAPLANE_RESULTS_DIR="$res" CHURN_RESULTS_DIR="$res" PROPAGATION_RESULTS_DIR="$res" \
			COEXEC_RESULTS_DIR="$res" CONTROLPLANE_RESULTS_DIR="$res" DATAPLANE_INTER_COMBO_SETTLE_SEC=0 COEXEC_INTER_COMBO_SETTLE_SEC=0 \
			PROPAGATION_SETTLE_SEC=0 PATH="${bin}:${PATH}" KUBECONFIG="$EK" \
			run --separate-stderr bash "${ROOT}/tests/${script}" --contexts ci-a --mesh-sizes 1 ${more[@]+"${more[@]}"}
		[ "$status" -eq 1 ] || { echo "${suite}: exit ${status}: ${stderr}"; false; }
		[[ "$suite" != propagation || "$output" == *"--- Final cleanup: all contexts ---"* ]]
		d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
		[[ "$stderr" =~ FATAL:\ ${script##*/}\ aborted\ \(exit\ 1\)\ at\ line\ [0-9]+: ]] || { echo "${suite}: ${stderr}"; false; }
		grep -qx 'EXIT=1' "$d/sweep-outcome.txt"
		grep -qx 'STOPPED=1' "$d/sweep-outcome.txt"
		grep -qE "^STOP_REASON=${script##*/} aborted \(exit 1\) at line [0-9]+: .*report-results\.sh" "$d/sweep-outcome.txt"
		grep -qx 'CUT_SHORT=1' "$d/sweep-outcome.txt"
		grep -q '^NOTE=next: ' "$d/sweep-outcome.txt"
		grep -qx "RUN_ID=${d##*/sweep-}" "$d/sweep-outcome.txt" || [ "$suite" = propagation ]
		# Its report shows the stop, with the reason and exit 1, not a run that has not finished.
		rmdir "$d/${md/RID/${d##*/sweep-}}"
		run --separate-stderr bash "${ROOT}/tests/${rep}" --results-dir "$d" --format text
		[[ "$output" =~ SWEEP\ OUTCOME\ \(recorded\ in\ sweep-outcome\.txt\ by\ run\ [^,]+,\ exit\ 1\) ]] || { echo "${suite}: ${output}"; false; }
		[[ "$output" == *"stopped early: ${script##*/} aborted (exit 1) at line "* ]]
		[[ "$output" != *"NOT FINISHED"* ]]
		# Its csv says so too: stopped, cut short, when it started and ended.
		run --separate-stderr bash "${ROOT}/tests/${rep}" --results-dir "$d" --format csv
		[[ "$output" == *$'\n# SWEEP_OUTCOME_STOPPED=1\n'* && "$output" == *$'\n# SWEEP_OUTCOME_CUT_SHORT=1\n'* ]] \
			|| { echo "${suite} csv: ${output}"; false; }
		[[ "$output" =~ $'\n'\#\ SWEEP_OUTCOME_ENDED_AT=[0-9T:-]+Z$'\n' ]] || { echo "${suite} csv: ${output}"; false; }
	done
	# propagation: its EXIT trap ran 007-cleanup (kubectl calls) before it wrote the stop
	# record: the last call still saw the not-finished one.
	res="${BATS_TEST_TMPDIR}/stopres-propagation"
	grep -qx 'EXIT=unfinished' "${res}/record-at-last-kubectl.txt"
}

@test "Ctrl-C through a sweep (dataplane after its first mesh size, controlplane while it counts its cells) leaves it not finished, interrupted by SIGINT; a controlplane --resume after a stop record runs, keeps no .prev of it, and replaces it" {
	[[ "$(bash -c 'trap "echo t" INT; kill -INT $$; echo n' 2>/dev/null)" == t* ]] || skip "SIGINT is ignored here"
	local res="${BATS_TEST_TMPDIR}/stopint" d bin="${BATS_TEST_TMPDIR}/stopbin"
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0
	_stop_stub "$bin"
	SS_RES="$res" SS_MD= SS_INT=1 DATAPLANE_RESULTS_DIR="$res" DATAPLANE_INTER_COMBO_SETTLE_SEC=0 PATH="${bin}:${PATH}" KUBECONFIG="$EK" \
		run --separate-stderr bash "${ROOT}/tests/dataplane/003-run-sweep.sh" --contexts ci-a,ci-b --mesh-sizes 1,2
	assert_failure 130
	[ -e "${res}/int-sent" ]
	[[ "$output" != *"Sweep finished"* && "$output" != *"mesh_size=2"* ]]
	[[ "$stderr" == *"warning: the sweep was interrupted (SIGINT, exit 130) before its outcome"* ]]
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	grep -qx 'EXIT=unfinished' "$d/sweep-outcome.txt"
	grep -qx 'ENDED_SIGNAL=SIGINT' "$d/sweep-outcome.txt"
	run --separate-stderr bash "${ROOT}/tests/dataplane/004-report-results.sh" --results-dir "$d" --format text
	assert_output --partial "(SIGINT: Ctrl-C) before it wrote its outcome"
	# controlplane: the cell count's awk (the sweep's own child) is Ctrl-C there.
	local fa="${BATS_TEST_TMPDIR}/fakeawk" cres="${BATS_TEST_TMPDIR}/stopcp"
	mkdir -p "$fa"
	printf '#!/bin/sh\ncase "$*" in *"print \\"TOTAL\\\\t\\" ncell"*) kill -INT "$PPID"; exit 0 ;; esac\nexec %s "$@"\n' "$(command -v awk)" > "${fa}/awk"
	chmod +x "${fa}/awk"
	SS_RES="$cres" SS_MD= SS_CR=1 CONTROLPLANE_RESULTS_DIR="$cres" PATH="${fa}:${bin}:${PATH}" KUBECONFIG="$EK" \
		run --separate-stderr bash "${ROOT}/tests/controlplane/003-run-sweep.sh" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 130
	d="$(find "$cres" -maxdepth 1 -name 'sweep-*' -type d)"
	grep -qx 'EXIT=unfinished' "$d/sweep-outcome.txt"
	grep -qx 'ENDED_SIGNAL=SIGINT' "$d/sweep-outcome.txt"
	# Its --resume, cut short in turn by an unexpected abort (its summary cannot be written):
	# a stop record. A --resume after that runs (the stop is no recorded problem), keeps no
	# sweep-outcome.prev.txt of it (it is no outcome of the sweep), and writes the outcome.
	rm -f "$d/sweep-${d##*/sweep-}.md"
	SS_RES="$cres" SS_MD='sweep-RID.md' SS_CR=1 CONTROLPLANE_RESULTS_DIR="$cres" PATH="${bin}:${PATH}" KUBECONFIG="$EK" \
		run --separate-stderr bash "${ROOT}/tests/controlplane/003-run-sweep.sh" --resume "$d" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 1
	grep -qx 'CUT_SHORT=1' "$d/sweep-outcome.txt"
	[ ! -e "$d/sweep-outcome.prev.txt" ]
	rmdir "$d/sweep-${d##*/sweep-}.md"
	SS_RES="$cres" SS_MD= SS_CR=1 CONTROLPLANE_RESULTS_DIR="$cres" PATH="${bin}:${PATH}" KUBECONFIG="$EK" \
		run --separate-stderr bash "${ROOT}/tests/controlplane/003-run-sweep.sh" --resume "$d" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	[[ "$stderr" != *"records a problem"* ]]
	grep -qx 'EXIT=4' "$d/sweep-outcome.txt"
	! grep -q '^CUT_SHORT=\|^NOTE=next: ' "$d/sweep-outcome.txt"
	[ ! -e "$d/sweep-outcome.prev.txt" ]
}

@test "every sweep sets its EXIT trap (which calls sweep_outcome_on_exit) before sweep_outcome_start, takes its lock earlier only with --release-on-exit, each of its steps guarded, and its ERR trap is sweep_err_trap" {
	local f t st
	# The check fires on the EXIT trap propagation had before this pass.
	printf '%s\n' "trap '_sweep_rc=\$?; sweep_cleanup; sweep_outcome_on_exit \"\$_sweep_rc\" || true' EXIT" > "${BATS_TEST_TMPDIR}/old.sh"
	run _trap_steps_guarded "${BATS_TEST_TMPDIR}/old.sh"
	assert_failure
	assert_output --partial "EXIT trap step not guarded: sweep_cleanup"
	for f in dataplane/003-run-sweep.sh churn/003-run-sweep.sh churn-dataplane/004-run-sweep.sh propagation/006-run-sweep.sh \
		controlplane/003-run-sweep.sh tuning/003-run-tuning-sweep.sh; do
		f="${ROOT}/tests/${f}"
		_trap_steps_guarded "$f"
		# The EXIT trap that records the outcome (tuning's dry run sets another, which runs no sweep).
		t="$(grep -nE "^[[:space:]]*trap '.*on_exit.*' EXIT$" "$f" | head -n 1 | cut -d: -f1)"
		st="$(grep -nE '^[[:space:]]*sweep_outcome_start "' "$f" | head -n 1 | cut -d: -f1)"
		[[ -n "$t" && -n "$st" && "$t" -lt "$st" ]] || { echo "${f}: EXIT trap at ${t:-none}, start at ${st:-none}"; false; }
		# sweep_outcome_start takes the lock after that trap; a sweep that takes it before
		# (controlplane --resume) releases it on a stop before that trap (--release-on-exit).
		! grep -nE '^[[:space:]]*sweep_lock ' "$f" | grep -v -- 'sweep_lock --release-on-exit ' || { echo "${f}: sweep_lock without --release-on-exit"; false; }
		# The EXIT trap calls the hook (tuning: in on_exit).
		grep -qE 'sweep_outcome_on_exit "\$(\?|_sweep_rc|rc)"' "$f" || { echo "${f}: no sweep_outcome_on_exit"; false; }
		grep -qxF "trap 'sweep_err_trap \"\$?\" \"\$LINENO\" \"\$BASH_COMMAND\"' ERR" "$f" || { echo "${f}: ERR trap"; false; }
	done
}

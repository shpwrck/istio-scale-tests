#!/usr/bin/env bash
# Shared utility functions sourced by all test suites.
# Sourced, never executed.
#
# Consumers: churn, churn-dataplane, controlplane, dataplane, propagation, tuning, gateway-api
#
# Exposes:
#   die <msg>                         -> exit 1 with stderr message (and keep <msg> as the
#                                        stop reason sweep_outcome_on_exit records, I5)
#   split_csv <csv> <out_arrayname>   -> trim+split CSV into named array; empty items
#                                        (",", "a,,b", "a, ") are dropped; always returns 0
#   split_contexts <csv> <out_arrayname> <what> [<source_ctx>]
#                                     -> split_csv for a list of mesh members; die naming
#                                        <what> (the flag or variable) when a member is
#                                        listed twice, or equals <source_ctx> when given
#   is_pos_int <val>                  -> return 0 if val is a positive integer
#   is_nonneg_int <val>               -> return 0 if val is a non-negative integer
#   validate_scoping <val>            -> die if val is not none|namespace|explicit|wide
#   resolve_kubectl <out_arrayname>   -> set the named array to (kubectl) or (oc)
#   validate_traffic_config <val>     -> die if val is not none|vsdr
#   vsdr_service_count <svc> <every>  -> services that get a VS+DR (i mod every == 0)
#   validate_workload_mode <val>      -> die if val is not pods|config-only
#   validate_outside_mode <val>       -> die if val is not none|unlabeled|labeled
#   resume_preamble_scalar <tsv> <KEY> <var> <flag> <explicit>
#                                     -> on --resume, set var from the preamble's KEY;
#                                        die if an explicit flag conflicts with it
#   is_ratio <val>                    -> return 0 if val is a decimal in (0, 1]
#   is_dns_label_for <prefix> <ctx>   -> return 0 if ctx is a lowercase DNS-1035 label
#                                        and <prefix><ctx> fits a 63-char Service name
#   timeout_cmd                       -> print the GNU timeout command on PATH (timeout,
#                                        else gtimeout); return 1 when neither exists
#   require_timeout                   -> die with an install hint when timeout_cmd finds
#                                        none; sets TIMEOUT_CMD (live runs, at startup)
#   run_timeout <duration> <cmd...>   -> cmd under timeout/gtimeout (TIMEOUT_CMD when set);
#                                        exit 127 with a message when neither exists
#   SWEEP_FAILED_EXIT (4)             -> a sweep's exit code when it finished and wrote its
#                                        report but one or more cells failed
#   sweep_outcome [--stopped <rc>] <cells> [<reason>...]
#                                     -> print a sweep's closing line ("N of M cells
#                                        failed: REASON xK, ..."), one reason per failed
#                                        cell; return 0 when none failed, else SWEEP_FAILED_EXIT
#                                        (<rc> when the sweep stopped early)
#   sweep_outcome_start <dir> <run_id> [...] -> A3: the sweep's "not finished" record, at its start;
#                                        I5: arms sweep_outcome_on_exit, traps the signals
#   sweep_trap_signals                -> I5: trap HUP, INT, TERM: keep the name
#                                        (_SWEEP_SIGNAL), then die of the signal as before
#   sweep_outcome_unfinished <file>   -> true when <file> is such a record
#   sweep_err_trap <rc> <line> <cmd>  -> I5: a sweep's ERR trap: the FATAL line, kept as the
#                                        stop reason; exits 1 (a signal's 129/130/143 kept)
#   sweep_outcome_on_exit <rc> [--note <msg>...]
#                                     -> I5: from a sweep's EXIT trap: a sweep that ends
#                                        before its outcome records why (stopped: die, the
#                                        ERR trap, another non-zero exit; exit 1) or when
#                                        (interrupted: Ctrl-C or a signal, ENDED_SIGNAL; still
#                                        not finished)
#   sweep_outcome_cut_short <file>    -> true for a not-finished record, or a stop record
#                                        sweep_outcome_on_exit wrote (CUT_SHORT=1)
#   sweep_outcome_recorded [...] <dir> <fmt> [<run_id>]
#                                     -> the recorded outcome, for a re-generated report
#   controlplane_latest_attempts <tsv> <resumes_txt> <out_tsv>
#                                     -> A1: the TSV without each cell's earlier attempts
#   md_cell [-v <var>] <value>        -> I7: the value for a markdown table cell (each | as
#                                        \|, a newline as a space)
#   MD_CELL_AWK                       -> I7: the same as an awk function md_cell(s)
#   file_min_bytes <file> <n>         -> I8: true when <file> holds at least <n> bytes; forks
#                                        nothing when it does
#
# All callers are expected to have run `set -euo pipefail`.
# shellcheck shell=bash

# Every suite needs bash 4.3 or newer (namerefs, `local -n`); macOS ships 3.2, whose errors
# would surface later as confusing syntax or "invalid option" messages.
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
	echo "error: bash 4.3 or newer is required; this is bash ${BASH_VERSION}. On macOS: brew install bash, then put \"\$(brew --prefix)/bin\" first on PATH." >&2
	exit 1
fi

# die <msg>: stop with the message. I5: the message is also the stop reason a sweep records
# when it dies after its start (sweep_outcome_on_exit; _SWEEP_STOP_BY says it came from die).
# shellcheck disable=SC2329
die() { _SWEEP_STOP_WHY="$*" _SWEEP_STOP_BY=die; echo "error: $*" >&2; exit 1; }

# shellcheck disable=SC2329
split_csv() {
	local csv="$1"
	local -n _out="$2"
	_out=()
	local x
	IFS=',' read -ra _raw <<<"$csv"
	for x in "${_raw[@]}"; do
		x="${x#"${x%%[![:space:]]*}"}"
		x="${x%"${x##*[![:space:]]}"}"
		[[ -n "$x" ]] && _out+=("$x")
	done
	# The loop's last test fails when the last item is empty ("a,,", "a, ", ","):
	# return 0 so a stray comma never kills a caller under set -e. A caller that
	# needs at least one item checks the array length itself.
	return 0
}

# split_contexts <csv> <out_arrayname> <what> [<source_ctx>]: split a context list like
# split_csv, then refuse a member listed twice (a duplicate would deploy, scrape and count
# that member twice) and, with <source_ctx>, a remote equal to the source. Call it before
# any cluster change; <what> names the flag or variable the operator fixes.
# shellcheck disable=SC2329
split_contexts() {
	local _sc_csv="$1" _sc_what="$3" _sc_src="${4:-}" _sc_x
	split_csv "$_sc_csv" "$2"
	local -n _sc_out="$2"
	local -A _sc_seen=()
	for _sc_x in ${_sc_out[@]+"${_sc_out[@]}"}; do
		[[ -z "${_sc_seen[$_sc_x]+x}" ]] \
			|| die "${_sc_what} lists ${_sc_x} twice (${_sc_csv}): list each mesh member once"
		[[ -z "$_sc_src" || "$_sc_x" != "$_sc_src" ]] \
			|| die "${_sc_what} lists the source context ${_sc_x}: the remotes are the other mesh members"
		_sc_seen[$_sc_x]=1
	done
	return 0
}

# shellcheck disable=SC2329
is_pos_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

# shellcheck disable=SC2329
is_nonneg_int() { [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]; }

# shellcheck disable=SC2329
validate_scoping() {
	case "$1" in
	none | namespace | wide | explicit) return 0 ;;
	*) die "--sidecar-scoping must be one of [none, namespace, explicit, wide]; got '$1'" ;;
	esac
}

# resolve_kubectl <out_arrayname>: set the named array to (kubectl), or (oc) if
# kubectl is not on PATH. Dies if neither is found. Callers that must work
# without a CLI (dry-run plan paths) should build their own array instead.
# shellcheck disable=SC2329
resolve_kubectl() {
	local -n _kc="$1"
	if command -v kubectl >/dev/null 2>&1; then
		_kc=(kubectl)
	elif command -v oc >/dev/null 2>&1; then
		_kc=(oc)
	else
		die "neither kubectl nor oc found on PATH"
	fi
}

# --- VirtualService/DestinationRule load axis (controlplane) ---

# validate_traffic_config <val>: the controlplane traffic-management mode.
# shellcheck disable=SC2329
validate_traffic_config() {
	case "$1" in
	none | vsdr) return 0 ;;
	*) die "--traffic-config must be one of [none, vsdr]; got '$1'" ;;
	esac
}

# vsdr_service_count <service_count> <every>: how many of services 0..N-1 get a
# VirtualService + DestinationRule, i.e. the i with i mod every == 0: ceil(N / every).
# Mirrors controlplane-test.vsdrFor in tests/controlplane/chart/templates/_helpers.tpl.
# shellcheck disable=SC2329
vsdr_service_count() {
	local sc="$1" every="$2"
	is_nonneg_int "$sc" || die "vsdr_service_count: service count must be a non-negative integer; got '$sc'"
	is_pos_int "$every" || die "vsdr_service_count: every must be a positive integer; got '$every'"
	echo $(( (sc + every - 1) / every ))
}

# --- namespace scaling (controlplane growth mode) ---

# validate_workload_mode <val>: pods (a Deployment per Service) or config-only
# (Services without pods plus a few measurement pods).
# shellcheck disable=SC2329
validate_workload_mode() {
	case "$1" in
	pods | config-only) return 0 ;;
	*) die "--workload-mode must be one of [pods, config-only]; got '$1'" ;;
	esac
}

# validate_outside_mode <val>: namespaces outside the mesh: none, unlabeled (not
# discovered) or labeled (istio-discovery=enabled, discovered but not injected).
# shellcheck disable=SC2329
validate_outside_mode() {
	case "$1" in
	none | unlabeled | labeled) return 0 ;;
	*) die "--outside-mode must be one of [none, unlabeled, labeled]; got '$1'" ;;
	esac
}

# resume_preamble_scalar <tsv> <KEY> <var> <flag> <explicit>: reconcile a sweep-level
# scalar on --resume. Such a scalar is recorded once, as `# KEY=value` in the TSV
# preamble, not in each row, so every row of one TSV must share it. Sets the variable
# named <var> to the recorded value, with a note on stderr when it held another value
# the operator did not pass explicitly (explicit=0). Dies when they passed <flag> with
# another value (explicit=1), or when the preamble has no `# KEY=` line.
# shellcheck disable=SC2329
resume_preamble_scalar() {
	local _rps_tsv="$1" _rps_key="$2" _rps_flag="$4" _rps_explicit="$5" _rps_rec
	local -n _rps_val="$3"
	# Preamble only: stop at the header row.
	_rps_rec="$(awk -v k="# ${_rps_key}=" '/^timestamp\t/ { exit } index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$_rps_tsv")"
	[[ -n "$_rps_rec" ]] || die "--resume: ${_rps_tsv} has no '# ${_rps_key}=' preamble line, so ${_rps_flag} cannot be checked against it. Start a new sweep."
	[[ "$_rps_rec" == "$_rps_val" ]] && return 0
	if [[ "$_rps_explicit" == 1 ]]; then
		die "--resume: ${_rps_flag} ${_rps_val} differs from ${_rps_key}=${_rps_rec} in the resumed sweep's preamble; every row of one TSV shares it. Pass ${_rps_flag} ${_rps_rec} (or leave it out), or start a new sweep."
	fi
	echo "note: --resume: using ${_rps_key}=${_rps_rec} from the resumed sweep's preamble (this run had ${_rps_val})" >&2
	_rps_val="$_rps_rec"
}

# --- dataplane local baseline: ratio flags (--min-qps-ratio, DATAPLANE_MIN_PCT_200) ---

# is_ratio <val>: true for a plain decimal in (0, 1], e.g. 0.95, .5, 1, 1.0.
# shellcheck disable=SC2329
is_ratio() {
	[[ "$1" =~ ^([0-9]+(\.[0-9]+)?|\.[0-9]+)$ ]] || return 1
	awk -v v="$1" 'BEGIN { exit !(v + 0 > 0 && v + 0 <= 1) }'
}

# --- remote reachability: per-cluster Service names (dataplane-server-<ctx>, fortio-server-<ctx>) ---

# is_dns_label_for <prefix> <ctx>: true when <ctx> is a lowercase DNS-1035 label
# (a letter first, then letters, digits and '-', no '-' last) and <prefix><ctx>
# is at most 63 characters, so it can name a per-cluster Service.
# shellcheck disable=SC2329
is_dns_label_for() {
	local prefix="$1" ctx="$2"
	[[ "$ctx" =~ ^[a-z]([-a-z0-9]*[a-z0-9])?$ ]] && (( ${#prefix} + ${#ctx} <= 63 ))
}

# --- bounded exec calls (GNU coreutils timeout; Homebrew installs it as gtimeout) ---

# timeout_cmd: the timeout command to use: timeout, else gtimeout (stock macOS has
# neither; `brew install coreutils` adds gtimeout). Return 1 when neither is on PATH.
# shellcheck disable=SC2329
timeout_cmd() {
	if command -v timeout >/dev/null 2>&1; then
		echo timeout
	elif command -v gtimeout >/dev/null 2>&1; then
		echo gtimeout
	else
		return 1
	fi
}

# require_timeout: a live run that bounds calls with run_timeout calls this at startup.
# The bounded calls discard stderr and read a failure as a missing sample, so without
# the tool every sample would silently read N/A; this dies with the fix instead. Sets
# TIMEOUT_CMD, which run_timeout uses.
# shellcheck disable=SC2329
require_timeout() {
	TIMEOUT_CMD="$(timeout_cmd)" \
		|| die "neither 'timeout' nor 'gtimeout' (GNU coreutils) is on PATH; the bounded config-dump and Envoy-stats reads need it. On macOS: brew install coreutils"
}

# run_timeout <duration> <cmd...>: run cmd bounded by <duration> (timeout syntax: 30s).
# Exit 127 with a message on stderr when no timeout command exists.
# shellcheck disable=SC2329
run_timeout() {
	local t="${TIMEOUT_CMD:-}"
	[[ -n "$t" ]] || t="$(timeout_cmd)" || {
		echo "error: neither 'timeout' nor 'gtimeout' (GNU coreutils) is on PATH; on macOS: brew install coreutils" >&2
		return 127
	}
	"$t" "$@"
}

# --- sweep outcome (R19) ---

# Exit codes every sweep shares: 0 every cell ran; 1 the run stopped (a precondition, an
# unexpected abort, or a suite's own stop such as controlplane's RETIRE_FAILED); 3 a
# reachability gate stopped it (dataplane, churn-dataplane); 4 it finished and wrote its
# report, but at least one cell failed (its setup or probe step exited non-zero, and the
# results name the reason) or the Istio version changed under it. A stop wins: 1 and 3
# are not replaced by 4. A cell a guard skipped on purpose (controlplane's memory guard)
# is reported apart and is not a failure.
# shellcheck disable=SC2034  # read by the sweeps that source this file
SWEEP_FAILED_EXIT=4

# _sweep_outcome_by <reason>...: "A x2, B x1" (sorted by reason).
_sweep_outcome_by() {
	printf '%s\n' "$@" | sort | uniq -c | awk '{ printf "%s%s x%d", (NR > 1 ? ", " : ""), $2, $1 }'
}

# _sweep_outcome_sweep_ids <dir>: the distinct sweep-level ids of the TSVs under <dir>, one
# per line as "<kind><TAB><id>": kind S for a file's SWEEP_RUN_ID preamble line, else R for
# its RUN_ID line (J6). K10: nextfile stops at the header (gawk, mawk 1.3.4, BSD awk); an
# awk without it skips the rows instead.
_sweep_outcome_sweep_ids() {
	find -H "$1" -name '*.tsv' -type f -exec awk '
		FNR == 1 { if (NR > 1) pick(); s = ""; r = ""; pre = 1 }
		function pick() { if (s != "") v = "S\t" s; else if (r != "") v = "R\t" r; else return; if (!(v in seen)) { seen[v] = 1; print v } }
		!pre { next }
		/^# SWEEP_RUN_ID=/ { if (s == "") s = substr($0, 16); next }
		/^# RUN_ID=/ { if (r == "") r = substr($0, 10); next }
		/^#/ { next }
		{ pre = 0; nextfile }
		END { if (NR > 0) pick() }' {} + 2>/dev/null | awk '!seen[$0]++' || true
}

# SWEEP_OUTCOME_PENDING_MARK: ends the line a sweep's own markdown report gets while its
# outcome is not written yet (sweep_outcome_recorded under _SWEEP_OUTCOME_PENDING=1);
# sweep_outcome --md removes that line when it appends the outcome.
# shellcheck disable=SC2034
SWEEP_OUTCOME_PENDING_MARK='<!-- sweep-outcome: pending -->'

# sweep_outcome_unfinished <file>: true when <file> is a sweep's "not finished" record
# (sweep_outcome_start: EXIT=unfinished), not the outcome sweep_outcome writes at its end.
# shellcheck disable=SC2329
sweep_outcome_unfinished() {
	[[ -f "$1" ]] && grep -qx 'EXIT=unfinished' "$1" 2>/dev/null
}

# sweep_outcome_start <dir> <run_id> [--unit <noun>] [--resumed-at <time>] [--next <text>]:
# A3. A sweep calls it at its start, before its first cell (never under --dry-run): it
# writes <dir>/sweep-outcome.txt as the sweep's "not finished" record: RUN_ID, HARNESS_SHA
# (as sweep_outcome --record writes it), EXIT=unfinished, STARTED_AT (UTC), UNIT,
# RESUMED_AT (a controlplane --resume: its start, in the rows' timestamp format) and NEXT
# (what to do if it died; no local path, F1). sweep_outcome --record replaces it at the
# end, so a sweep that dies keeps it, and every report says the sweep has not finished
# (sweep_outcome_recorded) instead of nothing. Creates <dir> when it does not exist yet (a
# sweep may create it only with its first row). Warns, never dies, when it cannot write.
# I5: it also arms sweep_outcome_on_exit for this shell (the record, its run and unit),
# and traps HUP, INT and TERM (sweep_trap_signals), so the record can tell an interrupt
# from a stop. The sweep installs its EXIT trap (which calls sweep_outcome_on_exit) first.
# shellcheck disable=SC2329
sweep_outcome_start() {
	local dir="$1" rid="$2" unit=cells resumed="" next=""
	shift 2
	while (($#)); do
		case "$1" in
		--unit) unit="$2"; shift 2 ;;
		--resumed-at) resumed="$2"; shift 2 ;;
		--next) next="$2"; shift 2 ;;
		*) echo "warning: sweep_outcome_start: unknown argument $1" >&2; shift ;;
		esac
	done
	mkdir -p "$dir" 2>/dev/null || true
	{
		echo "# Sweep outcome (tests/lib/common.sh sweep_outcome_start): this sweep has not finished; sweep_outcome replaces this record at its end"
		echo "# DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "RUN_ID=${rid:-unknown}"
		echo "HARNESS_SHA=${HARNESS_SHA:-$(declare -F harness_sha >/dev/null && harness_sha || echo unknown)}"
		echo "EXIT=unfinished"
		echo "STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "UNIT=${unit}"
		[[ -z "$resumed" ]] || echo "RESUMED_AT=${resumed}"
		[[ -z "$next" ]] || echo "NEXT=${next}"
	} 2>/dev/null > "${dir}/sweep-outcome.txt" \
		|| echo "warning: could not write ${dir}/sweep-outcome.txt (the sweep's not-finished record)" >&2
	_SWEEP_OUTCOME_ARMED_DIR="$dir" _SWEEP_OUTCOME_ARMED_RID="${rid:-unknown}" _SWEEP_OUTCOME_ARMED_UNIT="$unit"
	_SWEEP_OUTCOME_ARMED_PID="${BASHPID:-$$}"
	sweep_trap_signals
	return 0
}

# --- a sweep that ends before its outcome (I5) ---

# sweep_trap_signals: trap HUP, INT and TERM in this shell (sweep_outcome_start calls it).
# The handler keeps the signal's name in _SWEEP_SIGNAL, restores the signal's default and
# sends it to this shell again, which runs its EXIT trap and dies of it as before (a
# calling script sees the signal, so a loop of sweeps stops on Ctrl-C). $? in an EXIT trap
# a signal ran is the status of whatever ran last, not the signal's: this is how
# sweep_outcome_on_exit knows the sweep was interrupted. A sweep sets its EXIT trap before
# this runs: bash catches the terminating signals once an EXIT trap is set, and the
# default restored here is then that catch, which runs the EXIT trap (set after, SIGTERM
# and SIGHUP would end the sweep without it; Ctrl-C would still run it). Like any trap,
# the handler runs once the foreground command returns: Ctrl-C and a closed terminal
# reach that command too, but a SIGTERM sent to the sweep's process alone waits for it
# (signal the process group to stop both now).
# shellcheck disable=SC2329
sweep_trap_signals() {
	trap '_sweep_on_signal HUP' HUP
	trap '_sweep_on_signal INT' INT
	trap '_sweep_on_signal TERM' TERM
}

# shellcheck disable=SC2329  # invoked by the traps sweep_trap_signals sets
_sweep_on_signal() {
	_SWEEP_SIGNAL="$1"
	trap - "$1"
	kill -s "$1" "$$"
}

# sweep_err_trap <rc> <line> <command>: the body of a sweep's ERR trap (set -e is about to
# stop the sweep): the FATAL line on stderr, kept as the stop reason sweep_outcome_on_exit
# records (_SWEEP_STOP_BY=err, _SWEEP_STOP_RC: the failed command's exit). Install it as
#   trap 'sweep_err_trap "$?" "$LINENO" "$BASH_COMMAND"' ERR
# The sweep then exits 1, as every stop: the failed command's own code would read as
# another outcome (3 a reachability stop, 4 failed cells). A command a signal killed keeps
# its code (129, 130, 143: an interrupt). The sweeps run no `set +e` region at their top
# level, so the trap only fires where set -e stops the sweep anyway.
# shellcheck disable=SC2329
sweep_err_trap() {
	_SWEEP_STOP_WHY="${0##*/} aborted (exit ${1:-?}) at line ${2:-?}: ${3:-}"
	_SWEEP_STOP_BY=err _SWEEP_STOP_RC="${1:-}"
	echo "FATAL: ${_SWEEP_STOP_WHY}" >&2 || true
	case "${1:-}" in 129 | 130 | 143) return 0 ;; esac
	exit 1
}

# sweep_outcome_cut_short <file>: true when <file> is a not-finished record
# (sweep_outcome_unfinished), or the stop record sweep_outcome_on_exit wrote for a sweep
# that stopped before its end (CUT_SHORT=1): neither is an outcome of the whole sweep. A
# controlplane --resume reads both as a run that died (it does not move them to .prev).
# shellcheck disable=SC2329
sweep_outcome_cut_short() {
	sweep_outcome_unfinished "$1" || { [[ -f "$1" ]] && grep -qx 'CUT_SHORT=1' "$1" 2>/dev/null; }
}

# sweep_outcome_on_exit <rc> [--note <msg>...]: I5. A sweep's EXIT trap calls it after its
# own cleanup (a tuning profile is reverted first, PL32), as
#   sweep_outcome_on_exit "$rc" ... || true
# with <rc> the $? the trap started with. It does nothing unless sweep_outcome_start armed
# it in this shell (never in a subshell) and <dir>/sweep-outcome.txt is still that start's
# not-finished record: the sweep wrote its outcome at its end, or never started. Else the
# sweep ended before its outcome, and the record says how:
#   - interrupted: a signal sweep_trap_signals caught (Ctrl-C, SIGTERM, a closed terminal:
#     _SWEEP_SIGNAL); the ERR trap for a command a signal killed (its exit 129, 130 or
#     143); or exit 0 with no reason (no exit of this harness before its outcome is 0). The
#     record stays not finished and gets ENDED_AT (UTC), ENDED_EXIT and, when known,
#     ENDED_SIGNAL: the reports say the run was interrupted then, before its outcome (it
#     does not still run).
#   - stopped: die (its message), the ERR trap (sweep_err_trap: the script, line and
#     command), or any other non-zero exit ("it exited <rc> before its end": set -e in a
#     function, which runs no ERR trap). sweep_outcome --stopped 1 --stop-reason <why>
#     --uncounted <...> rewrites the record (EXIT=1, STOPPED=1, STOP_REASON, PROBLEM
#     "could not count the sweep's <unit>: ...", TOTAL=unknown, each --note, and the
#     start's NEXT as "next: ..."), then CUT_SHORT=1, STARTED_AT and ENDED_AT are added.
#     Every report shows it as stopped, with the reason, and exit 1. A stop is exit 1, so
#     another <rc> (4 or 3 would read as another outcome) ends the shell with exit 1 here.
# A sweep killed outright (SIGKILL, out of memory, a lost host) runs no trap: its record
# stays not finished without ENDED_AT ("it died, or still runs"). Never dies otherwise;
# warns when it cannot write.
# shellcheck disable=SC2329
sweep_outcome_on_exit() {
	local rc="${1:-0}" dir="${_SWEEP_OUTCOME_ARMED_DIR:-}" f why="${_SWEEP_STOP_WHY:-}" by="${_SWEEP_STOP_BY:-}"
	local sig="${_SWEEP_SIGNAL:-}" now started next srid
	(($#)) && shift
	[[ -n "$dir" && "${_SWEEP_OUTCOME_ARMED_PID:-}" == "${BASHPID:-$$}" ]] || return 0
	f="${dir}/sweep-outcome.txt"
	sweep_outcome_unfinished "$f" || return 0
	srid="$(sed -n 's/^RUN_ID=//p' "$f" 2>/dev/null | head -n 1)"
	[[ "$srid" == "${_SWEEP_OUTCOME_ARMED_RID:-}" ]] || return 0
	# Once: a second EXIT (a trap that exits again) finds nothing to do.
	_SWEEP_OUTCOME_ARMED_DIR=""
	is_nonneg_int "$rc" || rc=1
	now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	case "$sig" in
	HUP) rc=129 ;;
	INT) rc=130 ;;
	TERM) rc=143 ;;
	esac
	# A command a signal killed is an interrupt, not an error, even when the ERR trap saw
	# it fail (a signal sent to that command alone).
	if [[ -z "$sig" && "$by" == err ]] && [[ "${_SWEEP_STOP_RC:-}" == 129 || "${_SWEEP_STOP_RC:-}" == 130 || "${_SWEEP_STOP_RC:-}" == 143 ]]; then
		why="" rc="$_SWEEP_STOP_RC"
	fi
	if [[ -n "$sig" ]] || { [[ -z "$why" ]] && ((rc == 0 || rc == 129 || rc == 130 || rc == 143)); }; then
		{
			printf 'ENDED_AT=%s\nENDED_EXIT=%s\n' "$now" "$rc"
			[[ -z "$sig" ]] || printf 'ENDED_SIGNAL=SIG%s\n' "$sig"
		} 2>/dev/null >> "$f" || echo "warning: could not add ENDED_AT to ${f}" >&2
		echo "warning: the sweep was interrupted (${sig:+SIG${sig}, }exit ${rc}) before its outcome; sweep-outcome.txt says it has not finished" >&2
		return 0
	fi
	local orc="$rc"
	rc=1
	[[ -n "$why" ]] || why="it exited ${orc} before its end (an unexpected failure: see its console output)"
	started="$(sed -n 's/^STARTED_AT=//p' "$f" 2>/dev/null | head -n 1)"
	next="$(sed -n 's/^NEXT=//p' "$f" 2>/dev/null | head -n 1)"
	next="${next#if it died, }"
	local -a args=(--stopped "$rc" --stop-reason "$why" --unit "${_SWEEP_OUTCOME_ARMED_UNIT:-cells}"
		--uncounted "it stopped before its end at ${now}, so no count vouches for its rows, which may be partial"
		--record "$dir" --run-id "$srid" "$@")
	[[ -z "$next" ]] || args+=(--note "next: ${next}")
	sweep_outcome "${args[@]}" 0 || true
	{
		echo "CUT_SHORT=1"
		[[ -z "$started" ]] || echo "STARTED_AT=${started}"
		echo "ENDED_AT=${now}"
	} 2>/dev/null >> "$f" || echo "warning: could not add CUT_SHORT to ${f}" >&2
	((orc == 1)) || exit 1
	return 0
}

# sweep_outcome_recorded [--sweep-level-run-id] <results_dir> <text|md|json|csv> [<run_id>]:
# what the sweep recorded in <results_dir>/sweep-outcome.txt (sweep_outcome --record), for
# a report re-generated after the sweep (X3). text and md name the record's run and exit,
# then its failed cells (FAILED_BY, Y5) and every PROBLEM, NOTE, INFO (as note:, K6) and
# STOP_REASON line (nothing when the file is absent or records none of them); csv prints
# them as `# SWEEP_OUTCOME_<KEY>=` comment lines (Y9; nothing without the file); json prints
# {"exit":N,"run_id":"...","failed":N,"failed_by":"...","problems":[...],"notes":[...],
# "info":[...],"stop_reason":"...","unfinished":false}, or null without the file.
# A3: a sweep that has not finished (its sweep_outcome_start record: it died, or still
# runs) says so in every format (text and md a warning with its start time and what to do,
# csv `# SWEEP_OUTCOME_EXIT=unfinished`, json "exit":null and "unfinished":true with
# "started_at"); I5: one whose EXIT trap ran (ENDED_AT: Ctrl-C or a signal) says it was
# interrupted at that time, and by which signal when ENDED_SIGNAL names it (csv
# `# SWEEP_OUTCOME_INTERRUPTED_AT=` and `_BY=`, json "interrupted_at" and "interrupted_by",
# also for an unfinished --resume), and a stop record sweep_outcome_on_exit wrote reads as
# any stop. P4: while a --resume has not finished (it moved the record to
# sweep-outcome.prev.txt and has not written its own yet), that record is shown, from
# sweep-outcome.prev.txt, after a warning that says so; A12: its json says
# "unfinished":true and "resume_unfinished":true, with exit, failed, failed_by and
# stop_reason null and empty lists at the top level (this run counted nothing yet), and the
# earlier record's fields under "earlier". The sweep's own reports set
# _SWEEP_OUTCOME_PENDING=1, as theirs is about to be written: md prints one line that ends
# with SWEEP_OUTCOME_PENDING_MARK (sweep_outcome --md replaces it with the outcome; a
# report left with it says the sweep died before its end), the other formats nothing (json
# null). <run_id> is the report's run, compared with the record's RUN_ID (Y9). By default
# (one run, as config_check_multi_run counted it; nothing is compared for a pooled report)
# the record matches when its RUN_ID is the sweep-level id of a TSV under <results_dir>
# (SWEEP_RUN_ID, else RUN_ID: J6, so a renamed sweep dir is still its sweep), else, only
# when no TSV under it carries a sweep-level id (A11), the sweep-* dir's own id, else when
# the dir holds that run's sweep-<RUN_ID>.md (sweeps whose cells mint their own RUN_IDs). A
# TSV's id is sweep-level when it is a SWEEP_RUN_ID, or with --sweep-level-run-id (a suite
# whose TSV RUN_ID is the sweep's: controlplane) its RUN_ID. A record from another run is
# named as such, in every format (json report_run_id) and on stderr.
# shellcheck disable=SC2329
sweep_outcome_recorded() {
	local sweep_level=0
	if [[ "${1:-}" == --sweep-level-run-id ]]; then
		sweep_level=1
		shift
	fi
	local f="${1}/sweep-outcome.txt" fmt="$2" want="${3:-}" rid other="" sids ids dkey="" mode=final
	local -a files=()
	if sweep_outcome_unfinished "$f"; then
		mode=first
		if [[ "${_SWEEP_OUTCOME_PENDING:-0}" == 1 ]]; then
			mode=pending
		elif [[ -f "${1}/sweep-outcome.prev.txt" ]]; then
			# The not-finished record first (its start), then the outcome it shows.
			mode=resume files=("$f") f="${1}/sweep-outcome.prev.txt"
		fi
	elif [[ ! -f "$f" && -f "${1}/sweep-outcome.prev.txt" && "${_SWEEP_OUTCOME_PENDING:-0}" != 1 ]]; then
		mode=resume f="${1}/sweep-outcome.prev.txt"
	fi
	if [[ "$mode" == pending ]]; then
		case "$fmt" in
		json) echo null ;;
		md) printf '%s\n\n' "> **Sweep outcome**: not written yet: this report was made while the sweep ran, and the sweep appends its outcome at its end. A report that still shows this line, with no \"Sweep outcome\" section below, is from a sweep that died before its end. ${SWEEP_OUTCOME_PENDING_MARK}" ;;
		esac
		return 0
	fi
	if [[ ! -f "$f" ]]; then
		[[ "$fmt" != json ]] || echo null
		return 0
	fi
	case "$want" in mixed:* | unknown*) want="" ;; esac
	rid="$(sed -n 's/^RUN_ID=//p' "$f" 2>/dev/null | head -n 1)"
	if [[ -n "$rid" && "$rid" != unknown ]]; then
		if [[ -n "$want" ]]; then
			[[ "$rid" == "$want" ]] || other="$want"
		elif [[ "${MULTI_RUN_N:-0}" == 1 ]]; then
			sids="$(_sweep_outcome_sweep_ids "$1")"
			ids="$(cut -f 2 <<<"$sids")"
			dkey="${MULTI_RUN_IDS:-}"
			dkey="${dkey#sweep-}"
			case "$dkey" in mixed:* | unknown*) dkey="" ;; esac
			# A11: the dir's own id only when no TSV under it names the sweep.
			if grep -q '^S' <<<"$sids" || { ((sweep_level)) && [[ -n "$ids" ]]; }; then dkey=""; fi
			if ! grep -qxF -- "$rid" <<<"$ids" && [[ "$rid" != "$dkey" && ! -f "${1}/sweep-${rid}.md" ]]; then
				# Name the report's run by its TSVs when they agree on one, else by its dir.
				if [[ -n "$ids" && "$ids" != *$'\n'* ]]; then
					other="$ids"
				else
					other="${MULTI_RUN_IDS#sweep-}"
					case "$other" in "" | mixed:* | unknown*) other="its TSVs" ;; esac
				fi
			fi
		fi
	fi
	if [[ -n "$other" ]]; then
		echo "warning: ${f} was recorded by run ${rid}, not by this report's run ${other}; the outcome it repeats may not describe these rows" >&2
	fi
	files+=("$f")
	awk -v fmt="$fmt" -v other="$other" -v mode="$mode" -v src="${f##*/}" -v mk="${files[0]}" -v nfiles="${#files[@]}" '
		function jstr(v) { gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v); gsub(/\t/, "\\t", v); return "\"" v "\"" }
		function jlist(a, n,    i, s) { s = "["; for (i = 1; i <= n; i++) s = s (i > 1 ? "," : "") jstr(a[i]); return s "]" }
		# Of two files, the first is the not-finished record of a --resume (its start), the
		# second the outcome it shows.
		nfiles == 2 && FILENAME == mk {
			if (/^STARTED_AT=/) mstart = substr($0, 12)
			if (/^RESUMED_AT=/) mres = substr($0, 12)
			if (/^ENDED_AT=/) mend = substr($0, 10)
			if (/^ENDED_SIGNAL=/) msig = substr($0, 14)
			if (/^NEXT=/) mnext = substr($0, 6)
			if (/^RUN_ID=/) mrid = substr($0, 8)
			next
		}
		/^EXIT=/ { ex = substr($0, 6) }
		/^RUN_ID=/ { rid = substr($0, 8) }
		/^UNIT=/ { unit = substr($0, 6) }
		/^TOTAL=/ { total = substr($0, 7) }
		/^FAILED=/ { failed = substr($0, 8) }
		/^FAILED_BY=/ { fby = substr($0, 11) }
		/^STOP_REASON=/ { stop = substr($0, 13) }
		/^STARTED_AT=/ { start = substr($0, 12) }
		/^RESUMED_AT=/ { res = substr($0, 12) }
		/^ENDED_AT=/ { ended = substr($0, 10) }
		/^ENDED_EXIT=/ { endex = substr($0, 12) }
		/^ENDED_SIGNAL=/ { endsig = substr($0, 14) }
		/^NEXT=/ { next_ = substr($0, 6) }
		/^PROBLEM=/ { pr[++np] = substr($0, 9) }
		/^NOTE=/ { nt[++nn] = substr($0, 6) }
		/^INFO=/ { inf[++ni] = substr($0, 6) }
		END {
			if (rid == "") rid = "unknown"
			if (unit == "") unit = "cells"
			nf = (failed ~ /^[0-9]+$/) ? failed + 0 : 0
			fl = sprintf("%d of %s %s failed: %s", nf, total, unit, fby)
			ol = "the record is from run " rid ", not from the run this report reads (" other ")"
			if (mode == "first") {
				if (next_ == "") next_ = "if it died, run it again"
				fw = "this sweep has not finished (it died, or still runs): " (res != "" ? "its --resume that started at " res : "the run that started at " start) " has written no outcome yet, so no cell count vouches for these results, which may be partial; " next_
				# I5: its EXIT trap ran: it was interrupted (Ctrl-C or a signal), it does not still run.
				if (ended != "") {
					sub(/^if it died, /, "", next_)
					fw = "this sweep has not finished: " (res != "" ? "its --resume that started at " res : "the run that started at " start) " was interrupted at " ended " (" (endsig == "SIGINT" ? "SIGINT: Ctrl-C" : endsig == "SIGHUP" ? "SIGHUP: its terminal closed" : endsig != "" ? endsig : "exit " endex ", no error recorded") ") before it wrote its outcome, so no cell count vouches for these results, which may be partial; next: " next_
				}
			}
			ul = "the last --resume of this sweep" (mres != "" ? " (started at " mres ")" : "") " has not finished (" (mend != "" ? "it was interrupted at " mend (msig != "" ? " by " msig : "") "; run the same --resume again" : "it died, or still runs; if it died, run the same --resume again") "): this is the outcome before it, from sweep-outcome.prev.txt"
			if (fmt == "json") {
				rec = sprintf("{\"exit\":%s,\"run_id\":%s,\"failed\":%s,\"failed_by\":%s,\"problems\":%s,\"notes\":%s,\"info\":%s,\"stop_reason\":%s,\"unfinished\":false}", (ex ~ /^[0-9]+$/ ? ex : "null"), jstr(rid), (failed ~ /^[0-9]+$/ ? failed : "null"), jstr(fby), jlist(pr, np), jlist(nt, nn), jlist(inf, ni), jstr(stop))
				ro = (other == "" ? "" : ",\"report_run_id\":" jstr(other))
				if (mode == "first")
					printf "{\"exit\":null,\"run_id\":%s,\"failed\":null,\"failed_by\":null,\"problems\":[],\"notes\":[],\"info\":[],\"stop_reason\":null,\"unfinished\":true,\"started_at\":%s%s%s%s}\n", jstr(rid), (start == "" ? "null" : jstr(start)), (res == "" ? "" : ",\"resumed_at\":" jstr(res)), (ended == "" ? "" : ",\"interrupted_at\":" jstr(ended) (endsig == "" ? "" : ",\"interrupted_by\":" jstr(endsig))), ro
				else if (mode == "resume")
					printf "{\"exit\":null,\"run_id\":%s,\"failed\":null,\"failed_by\":null,\"problems\":[],\"notes\":[],\"info\":[],\"stop_reason\":null,\"unfinished\":true,\"resume_unfinished\":true,\"started_at\":%s%s%s,\"earlier\":%s}\n", jstr(mrid != "" ? mrid : rid), (mstart == "" ? "null" : jstr(mstart)), (mend == "" ? "" : ",\"interrupted_at\":" jstr(mend) (msig == "" ? "" : ",\"interrupted_by\":" jstr(msig))), ro, rec
				else
					printf "%s%s}\n", substr(rec, 1, length(rec) - 1), ro
				exit
			}
			if (fmt == "csv") {
				if (mode == "first") {
					printf "# SWEEP_OUTCOME_RUN_ID=%s\n# SWEEP_OUTCOME_EXIT=unfinished\n# SWEEP_OUTCOME_STARTED_AT=%s\n", rid, start
					if (ended != "") printf "# SWEEP_OUTCOME_INTERRUPTED_AT=%s\n", ended
					if (endsig != "") printf "# SWEEP_OUTCOME_INTERRUPTED_BY=%s\n", endsig
					printf "# WARNING: %s\n", fw
					if (other != "") printf "# WARNING: sweep-outcome.txt: %s\n", ol
					exit
				}
				if (mode == "resume") printf "# WARNING: %s\n", ul
				printf "# SWEEP_OUTCOME_RUN_ID=%s\n# SWEEP_OUTCOME_EXIT=%s\n# SWEEP_OUTCOME_FAILED=%s\n", rid, ex, (failed ~ /^[0-9]+$/ || failed == "" ? nf : failed)
				if (fby != "") printf "# SWEEP_OUTCOME_FAILED_BY=%s\n", fby
				for (i = 1; i <= np; i++) printf "# SWEEP_OUTCOME_PROBLEM=%s\n", pr[i]
				for (i = 1; i <= nn; i++) printf "# SWEEP_OUTCOME_NOTE=%s\n", nt[i]
				for (i = 1; i <= ni; i++) printf "# SWEEP_OUTCOME_INFO=%s\n", inf[i]
				if (stop != "") printf "# SWEEP_OUTCOME_STOP_REASON=%s\n", stop
				if (other != "") printf "# WARNING: sweep-outcome.txt: %s\n", ol
				exit
			}
			if (mode == "first") {
				if (fmt == "md") {
					printf "> **Sweep outcome** (recorded in `%s` by run `%s`): **not finished**\n", src, rid
					printf "> - warning: %s\n", fw
					if (other != "") printf "> - warning: %s\n", ol
				} else {
					printf "SWEEP OUTCOME (recorded in %s by run %s): NOT FINISHED\n", src, rid
					printf "  warning: %s\n", fw
					if (other != "") printf "  warning: %s\n", ol
				}
				printf "\n"
				exit
			}
			if (np + nn + ni + nf == 0 && stop == "" && other == "" && mode != "resume") exit
			if (fmt == "md") {
				printf "> **Sweep outcome** (recorded in `%s` by run `%s`, exit %s):\n", src, rid, ex
				if (mode == "resume") printf "> - warning: %s\n", ul
				if (other != "") printf "> - warning: %s\n", ol
				if (nf > 0) printf "> - error: %s\n", fl
				for (i = 1; i <= np; i++) printf "> - error: %s\n", pr[i]
				for (i = 1; i <= nn; i++) printf "> - warning: %s\n", nt[i]
				for (i = 1; i <= ni; i++) printf "> - note: %s\n", inf[i]
				if (stop != "") printf "> - stopped early: %s\n", stop
				printf "\n"
			} else {
				printf "SWEEP OUTCOME (recorded in %s by run %s, exit %s):\n", src, rid, ex
				if (mode == "resume") printf "  warning: %s\n", ul
				if (other != "") printf "  warning: %s\n", ol
				if (nf > 0) printf "  error: %s\n", fl
				for (i = 1; i <= np; i++) printf "  error: %s\n", pr[i]
				for (i = 1; i <= nn; i++) printf "  warning: %s\n", nt[i]
				for (i = 1; i <= ni; i++) printf "  note: %s\n", inf[i]
				if (stop != "") printf "  stopped early: %s\n", stop
				printf "\n"
			}
		}' "${files[@]}"
}

# sweep_outcome [options] <cells> [<reason>...]: the closing lines of a sweep, after its
# reports. One <reason> argument per cell without a measurement: a SKIPPED_* reason (a
# guard skipped the cell, or its series after such a skip) counts as skipped, any other
# as failed. Prints "All <cells> cells ran." (stdout), "<k> of <cells> cells were skipped
# on purpose, not failed: SKIPPED_<X> x<k>" (stdout) and "error: <n> of <cells> cells
# failed: <REASON> x<k>, .... <where>; exit 4." (stderr). Returns SWEEP_FAILED_EXIT when a
# cell failed or a --problem was given, else 0, so a sweep ends with:
# sweep_outcome ... || exit "$SWEEP_FAILED_EXIT".
#   --stopped <rc>   the sweep stopped early and exits <rc> (1 or 3), which outranks 4: the
#                    cells are still counted, "All cells ran" is never printed (they did
#                    not), the lines name <rc>, and it returns <rc>
#   --stop-reason <text>  why it stopped (RETIRE_FAILED, the reach gate, REVERT_FAILED, ...);
#                    named in the record and the markdown
#   --unit <noun>    what a cell is called, plural (default cells; tuning: passes)
#   --where <text>   where a failed one shows in the results (default: the report's
#                    placeholder rows, in n_total, not n_valid)
#   --problem <msg>  the sweep failed although its cells ran (A6: the Istio version changed
#                    under it); printed, recorded and counted like a failed cell
#   --uncounted <why>  N3: the sweep could not count its cells: a problem ("could not count
#                    the sweep's <unit>: <why>"), "All cells ran" is never printed, and the
#                    record says TOTAL=unknown, FAILED=unknown and SKIPPED=unknown (P2)
#   --note <msg>     a caveat; printed and recorded, not a failure
#   --info <msg>     a fact worth keeping that is not a caveat (K6: a --resume whose members
#                    were all ready); printed on stdout as "note: <msg>." and recorded
#   --record <dir>   also write the outcome to <dir>/sweep-outcome.txt (C3), with RUN_ID
#                    (--run-id) and HARNESS_SHA (the sweep's HARNESS_SHA, as its TSVs
#                    record it, else harness_sha when preamble.sh is sourced)
#   --run-id <id>    the sweep's RUN_ID, for the record
#   --md <file>      also append it to that markdown report, as a "Sweep outcome" section;
#                    may be given more than once (the summary and the scale envelope, R1).
#                    A file that does not exist is skipped. A3: the report's "not written
#                    yet" line (SWEEP_OUTCOME_PENDING_MARK) is removed first.
# A report re-generated later shows the record's PROBLEM, NOTE and INFO lines again
# (sweep_outcome_recorded). A3: the record replaces the sweep's sweep_outcome_start record;
# a sweep dir that still holds that one is a sweep that was killed before its end (no trap
# ran), was interrupted (I5: with ENDED_AT), or still runs; one that stopped with an error
# after its start holds the stop record sweep_outcome_on_exit wrote (CUT_SHORT=1); and one
# without sweep-outcome.txt is from a sweep that stopped before its start (a precondition:
# nothing ran), or from an older harness.
# shellcheck disable=SC2329
sweep_outcome() {
	local rc=0 stop_rc="" stop_why="" unit=cells where="" record="" run_id_r="" cells r by_fail="" by_skip="" uncounted=""
	local -a problems=() notes=() infos=() failed_r=() skipped_r=() lines=() mds_r=()
	while (($#)); do
		case "$1" in
		--stopped) stop_rc="$2"; shift 2 ;;
		--stop-reason) stop_why="$2"; shift 2 ;;
		--run-id) run_id_r="$2"; shift 2 ;;
		--unit) unit="$2"; shift 2 ;;
		--where) where="$2"; shift 2 ;;
		--problem) problems+=("$2"); shift 2 ;;
		--uncounted) uncounted="$2"; shift 2 ;;
		--note) notes+=("$2"); shift 2 ;;
		--info) infos+=("$2"); shift 2 ;;
		--record) record="$2"; shift 2 ;;
		--md) mds_r+=("$2"); shift 2 ;;
		*) break ;;
		esac
	done
	cells="$1"
	shift
	[[ -z "$uncounted" ]] || problems=("could not count the sweep's ${unit}: ${uncounted}" ${problems[@]+"${problems[@]}"})
	[[ -n "$where" ]] || where="The report includes them as placeholder rows (in n_total, not n_valid)"
	for r in "$@"; do
		if [[ "$r" == SKIPPED_* ]]; then skipped_r+=("$r"); else failed_r+=("$r"); fi
	done
	((${#failed_r[@]} == 0)) || by_fail="$(_sweep_outcome_by "${failed_r[@]}")"
	((${#skipped_r[@]} == 0)) || by_skip="$(_sweep_outcome_by "${skipped_r[@]}")"
	if ((${#failed_r[@]} || ${#problems[@]})); then rc="$SWEEP_FAILED_EXIT"; fi
	[[ -z "$stop_rc" ]] || rc="$stop_rc"
	# tail: how a failure line ends. lines: "out|", "err|" or "rec|" (the record and the
	# markdown only) plus the text, in the order printed.
	local tail="; exit ${SWEEP_FAILED_EXIT}."
	[[ -z "$stop_rc" ]] || tail="; the sweep also stopped early, so it exits ${stop_rc}, not ${SWEEP_FAILED_EXIT}."
	if [[ -z "$stop_rc" && -z "$uncounted" && ${#failed_r[@]} -eq 0 && ${#skipped_r[@]} -eq 0 ]]; then
		lines+=("out|All ${cells} ${unit} ran (their rows' own statuses are in the report).")
	elif ((${#skipped_r[@]})); then
		lines+=("out|${#skipped_r[@]} of ${cells} ${unit} were skipped on purpose, not failed: ${by_skip}.")
	fi
	if ((${#failed_r[@]})); then
		lines+=("err|error: ${#failed_r[@]} of ${cells} ${unit} failed: ${by_fail}. ${where}${tail}")
	fi
	for r in ${problems[@]+"${problems[@]}"}; do lines+=("err|error: ${r}${tail}"); done
	for r in ${notes[@]+"${notes[@]}"}; do lines+=("err|warning: ${r}."); done
	for r in ${infos[@]+"${infos[@]}"}; do lines+=("out|note: ${r}."); done
	if [[ -n "$stop_rc" && ${#failed_r[@]} -eq 0 && ${#problems[@]} -eq 0 ]]; then
		lines+=("rec|The sweep stopped early${stop_why:+ (${stop_why})}; it exits ${stop_rc}.")
	elif [[ -n "$stop_why" ]]; then
		lines+=("rec|It stopped early: ${stop_why}.")
	fi
	for r in ${lines[@]+"${lines[@]}"}; do
		case "$r" in
		err\|*) echo "${r#err|}" >&2 ;;
		out\|*) echo "${r#out|}" ;;
		esac
	done
	if [[ -n "$record" ]]; then
		{
			echo "# Sweep outcome (tests/lib/common.sh sweep_outcome)"
			echo "# DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			echo "RUN_ID=${run_id_r:-unknown}"
			echo "HARNESS_SHA=${HARNESS_SHA:-$(declare -F harness_sha >/dev/null && harness_sha || echo unknown)}"
			echo "EXIT=${rc}"
			echo "STOPPED=$([[ -n "$stop_rc" ]] && echo 1 || echo 0)"
			echo "STOP_REASON=${stop_why}"
			echo "UNIT=${unit}"
			echo "TOTAL=$([[ -z "$uncounted" ]] && echo "$cells" || echo unknown)"
			echo "FAILED=$([[ -z "$uncounted" ]] && echo "${#failed_r[@]}" || echo unknown)"
			echo "FAILED_BY=${by_fail}"
			echo "SKIPPED=$([[ -z "$uncounted" ]] && echo "${#skipped_r[@]}" || echo unknown)"
			echo "SKIPPED_BY=${by_skip}"
			for r in ${problems[@]+"${problems[@]}"}; do echo "PROBLEM=${r}"; done
			for r in ${notes[@]+"${notes[@]}"}; do echo "NOTE=${r}"; done
			for r in ${infos[@]+"${infos[@]}"}; do echo "INFO=${r}"; done
		} 2>/dev/null > "${record}/sweep-outcome.txt" \
			|| echo "warning: could not write ${record}/sweep-outcome.txt" >&2
	fi
	local md_r md_t
	for md_r in ${mds_r[@]+"${mds_r[@]}"}; do
		[[ -f "$md_r" ]] || continue
		if grep -qF -- "$SWEEP_OUTCOME_PENDING_MARK" "$md_r" 2>/dev/null; then
			md_t="$(awk -v m="$SWEEP_OUTCOME_PENDING_MARK" 'index($0, m) { skip = 1; next } skip && $0 == "" { skip = 0; next } { skip = 0; print }' "$md_r" 2>/dev/null)" \
				&& printf '%s\n' "$md_t" 2>/dev/null > "$md_r" \
				|| echo "warning: could not remove the not-written-yet line from ${md_r}" >&2
		fi
		{
			echo ""
			echo "## Sweep outcome"
			echo ""
			echo "Exit ${rc}. $([[ -n "$record" ]] && echo "Also in \`sweep-outcome.txt\`.")"
			echo ""
			for r in ${lines[@]+"${lines[@]}"}; do echo "- ${r#*|}"; done
		} 2>/dev/null >> "$md_r" || echo "warning: could not append the outcome to ${md_r}" >&2
	done
	return "$rc"
}

# --- controlplane cell attempts (A1) ---

# controlplane_latest_attempts <tsv> <resumes_txt> <out_tsv>: copy a controlplane TSV to
# <out_tsv> without the rows of each cell's earlier attempts, so a report, the cell count
# and the scale envelope never pool two attempts of one cell (PL15). A cell is keyed as
# 003's combo_already_done keys it: columns 3-7, traffic_config and window_kind (by header
# name; none and deploy when absent). An attempt is a run of the sweep: the first run, then
# each --resume that resumes.txt lists, from the row its TSV_LINES column names on (the
# TSV's line count when that resume started), else, in a file a harness before A1 wrote,
# from its RESUMED_AT on (by the row's timestamp, which has the same format). A cell's
# latest attempt is the last run that wrote a row of it; its rows from earlier runs are left
# out. Comment, header and short lines (fewer than 40 columns) are copied as they are. A
# TSV without resumes.txt (pass "" or a missing file: a first run, or a growth series, which
# is never resumed) is copied whole. Prints "<rows left out><TAB><cells they belong to>";
# returns non-zero, printing nothing, when awk fails.
# shellcheck disable=SC2329
controlplane_latest_attempts() {
	local tsv="$1" res="${2:-}" out="$3"
	[[ -n "$res" && -f "$res" ]] || res=/dev/null
	: > "$out" || return 1
	awk -F'\t' -v res="$res" -v out="$out" '
		BEGIN {
			while ((r = (getline line < res)) > 0) {
				n = split(line, f, "\t")
				if (f[1] == "RESUMED_AT") { lc = 0; for (i = 1; i <= n; i++) if (f[i] == "TSV_LINES") lc = i; continue }
				if (n < 2 || f[1] == "") continue
				nb++
				bt[nb] = substr(f[1], 1, 19)
				bl[nb] = (lc && n >= lc && f[lc] ~ /^[0-9]+$/) ? f[lc] + 0 : -1
			}
			if (r < 0) { print "cannot read " res > "/dev/stderr"; bad = 1; exit 2 }
			close(res)
		}
		function seg(    s, i) {
			s = 0
			for (i = 1; i <= nb; i++) if (bl[i] >= 0 ? FNR > bl[i] : substr($1, 1, 19) >= bt[i]) s = i
			return s
		}
		FNR == 1 { pass++ }
		/^timestamp\t/ { tcol = 0; wcol = 0; for (i = 1; i <= NF; i++) { if ($i == "traffic_config") tcol = i; if ($i == "window_kind") wcol = i } }
		{ data = !(/^#/ || /^timestamp\t/ || NF < 40) }
		data { k = $3 SUBSEP $4 SUBSEP $5 SUBSEP $6 SUBSEP $7 SUBSEP ((tcol && NF >= tcol) ? $tcol : "none") SUBSEP ((wcol && NF >= wcol) ? $wcol : "deploy") }
		pass == 1 { if (data) { s = seg(); if (!(k in top) || s > top[k]) top[k] = s }; next }
		data && seg() < top[k] { drop++; if (!(k in dk)) { dk[k] = 1; ndk++ }; next }
		{ print > out }
		END { if (bad) exit 2; close(out); printf "%d\t%d\n", drop, ndk }' "$tsv" "$tsv"
}

# --- markdown table cells (I7) ---

# md_cell [-v <var>] <value>: <value> as the text of a markdown table cell: each | as \|
# (a mixed value joins per-member lists with " | ", which would split the cell) and each
# newline as a space; printed without a newline, or with -v stored in <var> (no subshell).
# A plain loop, no ${v//|/...}: the replacement's backslash reads differently across bash
# 4.3-5.2 (patsub_replacement).
# shellcheck disable=SC2329
md_cell() {
	local _mdc_var=""
	if [[ "${1:-}" == -v ]]; then
		_mdc_var="$2"
		shift 2
	fi
	local _mdc_s="${1-}" _mdc_out=""
	_mdc_s="${_mdc_s//$'\n'/ }"
	while [[ "$_mdc_s" == *'|'* ]]; do
		_mdc_out+="${_mdc_s%%|*}\\|"
		_mdc_s="${_mdc_s#*|}"
	done
	if [[ -n "$_mdc_var" ]]; then
		printf -v "$_mdc_var" '%s' "${_mdc_out}${_mdc_s}"
	else
		printf '%s' "${_mdc_out}${_mdc_s}"
	fi
}

# MD_CELL_AWK: awk function md_cell(s), md_cell's twin for a table an awk program writes:
# each | as \| (built with index, not gsub, whose replacement backslashes differ between
# awks), each newline as a space.
# shellcheck disable=SC2016,SC2034  # awk source, read by the scripts that source this file
MD_CELL_AWK='
function md_cell(s,    out, i) {
	out = ""
	while ((i = index(s, "\n")) > 0) s = substr(s, 1, i - 1) " " substr(s, i + 1)
	while ((i = index(s, "|")) > 0) { out = out substr(s, 1, i - 1) "\\|"; s = substr(s, i + 1) }
	return out s
}
'

# --- file size without a fork (I8) ---

# file_min_bytes <file> <n>: true when <file> is a readable regular file of at least <n>
# bytes. It forks nothing when it is (B6, I8: it runs once per scrape file): the read
# builtin takes the first <n> characters, and as many characters are at least as many
# bytes; fewer characters (a short file, NUL bytes, or multibyte text) are counted in
# bytes with wc. False for a missing, unreadable or empty file, and for <n> not a number.
# shellcheck disable=SC2329
file_min_bytes() {
	local f="$1" n="${2:-}" _fmb_head="" sz
	[[ "$n" =~ ^[0-9]+$ ]] || return 1
	((n > 0)) || { [[ -f "$f" && -r "$f" ]]; return; }
	[[ -s "$f" && -r "$f" ]] || return 1
	IFS= read -r -d '' -N "$n" _fmb_head < "$f" 2>/dev/null || true
	((${#_fmb_head} < n)) || return 0
	sz=$(wc -c < "$f" 2>/dev/null || echo 0)
	sz="${sz//[^0-9]/}"
	((${sz:-0} >= n))
}

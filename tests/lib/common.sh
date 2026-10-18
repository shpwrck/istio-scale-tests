#!/usr/bin/env bash
# Shared utility functions sourced by all test suites.
# Sourced, never executed.
#
# Consumers: churn, churn-dataplane, controlplane, dataplane, propagation, tuning, gateway-api
#
# Exposes:
#   die <msg>                         -> exit 1 with stderr message (and keep <msg> as the
#                                        stop reason sweep_outcome_on_exit records)
#   split_csv <csv> <out_arrayname>   -> trim+split CSV into named array; empty items
#                                        (",", "a,,b", "a, ") are dropped; always returns 0
#   split_contexts <csv> <out_arrayname> <what> [<source_ctx>]
#                                     -> split_csv for a list of mesh members; die naming
#                                        <what> (the flag or variable) when a member is
#                                        listed twice, or equals <source_ctx> when given
#   ctx_file_safe <name> [<max>]      -> the file-name form of a context name (or a run id,
#                                        a tag): each byte outside A-Za-z0-9._- as _ (in
#                                        every locale), at most <max> chars
#                                        (CTX_FILE_NAME_MAX: the cut used inside folder names)
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
#   sweep_outcome_start <dir> <run_id> [...] -> the sweep's "not finished" record, at its start;
#                                        Arms sweep_outcome_on_exit, traps the signals
#   sweep_trap_signals                -> trap HUP, INT, TERM: keep the name
#                                        (_SWEEP_SIGNAL), then die of the signal as before
#   sweep_outcome_unfinished <file>   -> true when <file> is such a record
#   sweep_err_trap <rc> <line> <cmd>  -> a sweep's ERR trap: the FATAL line, kept as the
#                                        stop reason; exits 1 (a signal's 129/130/143 kept)
#   sweep_outcome_on_exit <rc> [--note <msg>...]
#                                     -> from a sweep's EXIT trap: a sweep that ends
#                                        before its outcome records why (stopped: die, the
#                                        ERR trap, another non-zero exit; exit 1) or when
#                                        (interrupted: Ctrl-C or a signal, ENDED_SIGNAL; still
#                                        not finished)
#   sweep_outcome_cut_short <file>    -> true for a not-finished record, or a stop record
#                                        sweep_outcome_on_exit wrote (CUT_SHORT=1)
#   sweep_outcome_recorded [...] <dir> <fmt> [<run_id>]
#                                     -> the recorded outcome, for a re-generated report
#   controlplane_latest_attempts <tsv> <resumes_txt> <out_tsv>
#                                     -> the TSV without each cell's earlier attempts
#   CP_CELL_AWK                       -> awk functions for a controlplane cell's state
#                                        (done, its status, INCOMPLETE) and the planned cells
#   sweep_lock [--release-on-exit] <dir>
#                                     -> one run per sweep dir (.sweep.lock with the PID; a
#                                        stale lock taken over under .sweep.lock.taking);
#                                        --release-on-exit: an EXIT trap releases it
#   sweep_step <cmd...>               -> run a long step so a signal reaches it, and every
#                                        process under it, at once (SWEEP_STOP_GRACE_SEC,
#                                        then SIGKILL)
#   sweep_step_kill                   -> SIGKILL what still runs of that step (EXIT traps)
#   harness_sha [--exclude <dir>]...  -> the harness the run uses: git describe, with
#                                        -dirty.<8hex> naming the uncommitted content of
#                                        HARNESS_PATHS (tests config charts terraform)
#   harness_sha_for_sweep [<dir>]     -> a sweep's harness at its start; exports <dir> as
#                                        HARNESS_SHA_EXCLUDE (never the value)
#   harness_sha_check <step>          -> read it again before a step (HARNESS_SHA_CHECK_SEC);
#                                        a change is a problem in sweep_outcome
#   report_harness_sha [--exclude <dir>]...
#                                     -> the harness a report itself runs (REPORT_HARNESS_SHA)
#   md_cell [-v <var>] <value>        -> the value for a markdown table cell (each | as
#                                        \|, a newline as a space)
#   MD_CELL_AWK                       -> the same as an awk function md_cell(s)
#   yaml_str [-v <var>] [-n] <value>  -> the value as a YAML double-quoted scalar, escaped
#                                        (\ " and control characters), for frontmatter
#   file_min_bytes <file> <n>         -> true when <file> holds at least <n> bytes; forks
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

# die <msg>: stop with the message. The message is also the stop reason a sweep records
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
	for x in ${_raw[@]+"${_raw[@]}"}; do
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

# CTX_FILE_NAME_MAX: the longest a context's file-name form gets inside a folder name
# (istiod-diag evidence folders); redact-results.sh maps that cut form too.
# RUN_ID_FILE_NAME_MAX, TAG_FILE_NAME_MAX: the same for a run id (an istiod-diag-<run id>
# folder) and a capture tag (an evidence folder's name).
# shellcheck disable=SC2034
CTX_FILE_NAME_MAX=40 RUN_ID_FILE_NAME_MAX=64 TAG_FILE_NAME_MAX=48

# ctx_file_safe <name> [<max>]: the one file-name form of a context name (state files,
# evidence folders, redaction), and of any other text that becomes part of a file or folder
# name (istiod-diag also cuts run ids and capture tags with it: RUN_ID_FILE_NAME_MAX,
# TAG_FILE_NAME_MAX). Every byte outside A-Za-z0-9._- becomes _, byte by byte
# in every locale (a 2-byte UTF-8 letter gives __), then at most <max> characters. The
# list is spelled out: a [a-z] range follows the locale's collation before bash 5.0.
# Forks nothing for a name that is already safe.
# shellcheck disable=SC2329
ctx_file_safe() {
	local _cfs_s="${1-}" _cfs_max="${2-}"
	case "$_cfs_s" in
	*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*)
		_cfs_s="$(printf '%s' "$_cfs_s" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
		;;
	esac
	if [[ "$_cfs_max" =~ ^[0-9]+$ ]]; then _cfs_s="${_cfs_s:0:_cfs_max}"; fi
	printf '%s\n' "$_cfs_s"
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

# --- sweep outcome ---

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
# its RUN_ID line. Nextfile stops at the header (gawk, mawk 1.3.4, BSD awk); an
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
# A sweep calls it at its start, before its first cell (never under --dry-run): it
# writes <dir>/sweep-outcome.txt as the sweep's "not finished" record: RUN_ID, HARNESS_SHA
# (as sweep_outcome --record writes it), EXIT=unfinished, STARTED_AT (UTC), UNIT,
# RESUMED_AT (a controlplane --resume: its start, in the rows' timestamp format) and NEXT
# (what to do if it died; no local path). sweep_outcome --record replaces it at the
# end, so a sweep that dies keeps it, and every report says the sweep has not finished
# (sweep_outcome_recorded) instead of nothing. Creates <dir> when it does not exist yet (a
# sweep may create it only with its first row). Warns, never dies, when it cannot write.
# It also arms sweep_outcome_on_exit for this shell (the record, its run and unit),
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
	# One run per sweep dir: refused (die) while another live run holds its lock.
	sweep_lock "$dir"
	{
		echo "# Sweep outcome (tests/lib/common.sh sweep_outcome_start): this sweep has not finished; sweep_outcome replaces this record at its end"
		echo "# DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "RUN_ID=${rid:-unknown}"
		echo "HARNESS_SHA=${HARNESS_SHA:-$(harness_sha)}"
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

# sweep_lock [--release-on-exit] <dir>: one run per sweep dir. Takes <dir>/.sweep.lock (it
# holds this shell's PID); while the lock names a PID that is still alive, dies before
# anything in <dir> changes, naming that PID and how to clear a stale lock, so a --resume
# cannot run beside the run it resumes (two runs would append to one TSV and overwrite each
# other's outcome). A PID that `kill -0` may not signal (another user's process) is alive
# too (`ps -p`). A lock whose PID is gone (that run died) is taken over under
# <dir>/.sweep.lock.taking (a mkdir mutex): the lock is read again under it and written
# only while its PID is still gone, so of two runs that find one stale lock at once, one
# takes it and the other is refused; a mutex left by a run that died while taking over is
# never removed for you (the refusal names it). sweep_outcome_start takes the lock, so
# every sweep does, after it has set its EXIT trap (sweep-stop.bats checks the order).
# controlplane 003 takes it earlier for a --resume, before it reads or moves anything in
# the sweep dir, with --release-on-exit: that sets an EXIT trap that releases it
# (_sweep_unlock, only the lock this shell took), so a run that stops on a precondition
# before its own EXIT trap leaves no lock; the sweep's own EXIT trap replaces it and
# releases the lock too. Taking it again from the same shell does nothing; the sweep's EXIT
# trap removes it (sweep_outcome_on_exit, only the lock this shell took), after the step
# that was running has ended (_sweep_step_stop). Warns and goes on when the lock cannot be
# written (a read-only dir fails later, loudly).
# shellcheck disable=SC2329
sweep_lock() {
	if [[ "${1:-}" == --release-on-exit ]]; then
		shift
		trap '_sweep_unlock 2>/dev/null || true' EXIT
	fi
	local dir="$1" f m me="${BASHPID:-$$}" pid i
	f="${dir}/.sweep.lock" m="${dir}/.sweep.lock.taking"
	[[ "${_SWEEP_LOCK_FILE:-}" != "$f" || "${_SWEEP_LOCK_PID:-}" != "$me" ]] || return 0
	mkdir -p "$dir" 2>/dev/null || true
	if (set -o noclobber; printf '%s\n' "$me" > "$f") 2>/dev/null; then
		_SWEEP_LOCK_FILE="$f" _SWEEP_LOCK_PID="$me"
		return 0
	fi
	pid="$(head -n 1 "$f" 2>/dev/null)" || pid=""
	# A lock with this shell's own PID is stale too (left before a restart).
	if [[ "$pid" != "$me" ]] && _sweep_pid_alive "$pid"; then
		_sweep_lock_refuse "$dir" "$pid"
	fi
	# The lock is stale (or was just removed): take it over under the mutex.
	local got=0 nodir=0
	for ((i = 0; i < 50; i++)); do
		if mkdir "$m" 2>/dev/null; then
			got=1
			break
		fi
		if [[ -d "$m" ]]; then
			nodir=0
			sleep 0.1
			continue
		fi
		nodir=$((nodir + 1))
		((nodir < 3)) || break
	done
	if ((got == 0)) && [[ -d "$m" ]]; then
		pid="$(head -n 1 "${m}/pid" 2>/dev/null)" || pid=""
		die "another run (PID ${pid:-unknown}) is taking over the stale lock of ${dir}, or one died doing so: ${m} has stayed for 5s (nothing was changed). If no other run is starting there, remove ${m} and run again."
	fi
	if ((got == 0)); then
		echo "warning: could not take ${f} (the sweep dir's lock), so another run in this dir would not be refused" >&2
		return 0
	fi
	printf '%s\n' "$me" 2>/dev/null >| "${m}/pid" || true
	_SWEEP_LOCK_TAKING="$m"
	pid="$(head -n 1 "$f" 2>/dev/null)" || pid=""
	if _sweep_pid_alive "$pid" && [[ "$pid" != "$me" ]]; then
		_sweep_lock_release_mutex
		_sweep_lock_refuse "$dir" "$pid"
	fi
	printf '%s\n' "$me" 2>/dev/null >| "$f" || true
	pid="$(head -n 1 "$f" 2>/dev/null)" || pid=""
	_sweep_lock_release_mutex
	if [[ "$pid" == "$me" ]]; then
		_SWEEP_LOCK_FILE="$f" _SWEEP_LOCK_PID="$me"
		return 0
	fi
	echo "warning: could not take ${f} (the sweep dir's lock), so another run in this dir would not be refused" >&2
	return 0
}

# _sweep_lock_refuse <dir> <pid>: sweep_lock's refusal (die) for a lock a live PID holds.
# shellcheck disable=SC2329
_sweep_lock_refuse() {
	die "another run of this sweep (PID ${2}) still runs in ${1}: wait for it to end, or stop it, before you start or --resume a run there (nothing was changed). If no such run exists (the host restarted and that PID is another process now), remove ${1}/.sweep.lock and run again."
}

# _sweep_lock_release_mutex: remove the takeover mutex this shell made (sweep_lock).
# shellcheck disable=SC2329
_sweep_lock_release_mutex() {
	[[ -n "${_SWEEP_LOCK_TAKING:-}" ]] || return 0
	rm -f "${_SWEEP_LOCK_TAKING}/pid" 2>/dev/null || true
	rmdir "$_SWEEP_LOCK_TAKING" 2>/dev/null || true
	_SWEEP_LOCK_TAKING=""
}

# _sweep_pid_alive <pid>: true when <pid> is a positive integer and that process exists:
# `kill -0`, or, when that fails (EPERM: another user's process), `ps -p`.
# shellcheck disable=SC2329
_sweep_pid_alive() {
	[[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || return 1
	kill -0 "$1" 2>/dev/null && return 0
	[[ -n "$(ps -p "$1" -o pid= 2>/dev/null)" ]]
}

# _sweep_unlock: remove the lock sweep_lock took in this shell (sweep_outcome_on_exit),
# and a takeover mutex it still holds.
# shellcheck disable=SC2329
_sweep_unlock() {
	_sweep_lock_release_mutex
	[[ -n "${_SWEEP_LOCK_FILE:-}" && "${_SWEEP_LOCK_PID:-}" == "${BASHPID:-$$}" ]] || return 0
	local pid
	pid="$(head -n 1 "$_SWEEP_LOCK_FILE" 2>/dev/null)" || pid=""
	[[ "$pid" != "$_SWEEP_LOCK_PID" ]] || rm -f "$_SWEEP_LOCK_FILE" 2>/dev/null || true
	_SWEEP_LOCK_FILE=""
}

# --- a sweep that ends before its outcome ---

# sweep_trap_signals: trap HUP, INT and TERM in this shell (sweep_outcome_start calls it).
# The handler keeps the signal's name in _SWEEP_SIGNAL, restores the signal's default and
# sends it to this shell again, which runs its EXIT trap and dies of it as before (a
# calling script sees the signal, so a loop of sweeps stops on Ctrl-C). $? in an EXIT trap
# a signal ran is the status of whatever ran last, not the signal's: this is how
# sweep_outcome_on_exit knows the sweep was interrupted. A sweep sets its EXIT trap before
# this runs: bash catches the terminating signals once an EXIT trap is set, and the
# default restored here is then that catch, which runs the EXIT trap (set after, SIGTERM
# and SIGHUP would end the sweep without it; Ctrl-C would still run it). Like any trap,
# the handler runs once the foreground command returns. A long step that runs through
# sweep_step is not a foreground command: the signal ends the sweep's wait for it at once,
# and the handler stops the step and every process under it first (_sweep_step_stop: the
# same signal, then SIGKILL for what still runs SWEEP_STOP_GRACE_SEC later), then ends the
# sweep; its EXIT trap (and the lock's removal) runs after the step's processes are gone.
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
	[[ -z "${_SWEEP_STEP_PID:-}" ]] || _sweep_step_stop "$1"
	kill -s "$1" "$$"
}

# _sweep_tree_read <root>...: one `ps -A` read: each live or zombie process that is a
# <root> or under one, as "<pid> <pgid> <state> <key>" lines. A <root> is a PID, which
# matches only a child of the shell that ran sweep_step (the step), or a key,
# "<pid>@<start time>", which matches only the process that started then: a PID the
# system gave to a new process after the old one ended is never taken for it. Reads every
# process at once, the same way on Linux and macOS (no pgrep, no /proc).
# shellcheck disable=SC2329
_sweep_tree_read() {
	(($#)) || return 0
	LC_ALL=C ps -A -o pid=,ppid=,pgid=,stat=,lstart= 2>/dev/null | awk -v roots="$*" -v me="${_SWEEP_STEP_OWNER:-$$}" '
		BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) want[r[i]] = 1 }
		NF >= 9 {
			k = $1 "@" $5 "-" $6 "-" $7 "-" $8 "-" $9
			pid[NR] = $1; pg[NR] = $3; st[NR] = $4; key[NR] = k; kids[$2] = kids[$2] " " NR
			if ((($1 in want) && $2 == me) || (k in want)) q[++t] = NR
		}
		END {
			h = 1
			while (h <= t) {
				i = q[h++]
				if (i in done) continue
				done[i] = 1
				print pid[i], pg[i], st[i], key[i]
				m = split(kids[pid[i]], c, " ")
				for (j = 1; j <= m; j++) q[++t] = c[j]
			}
		}' || true
}

# _sweep_tree_freeze <out_var> <root>...: SIGSTOP each live process of the trees under
# <root>... (_sweep_tree_read), reading again until no new one shows up, so none of them
# can start another process before the caller signals them; sets <out_var> (an array) to
# their keys. The caller sends SIGCONT (or SIGKILL).
# shellcheck disable=SC2329
_sweep_tree_freeze() {
	local -n _stf_out="$1"
	shift
	local -a stf_roots=("$@") stf_keys=()
	local stf_frozen=" " stf_new i p g s k
	_stf_out=()
	for ((i = 0; i < 50; i++)); do
		stf_new=0 stf_keys=()
		while read -r p g s k; do
			[[ -n "$k" && "$s" != Z* ]] || continue
			stf_keys+=("$k")
			[[ "$stf_frozen" != *" ${k} "* ]] || continue
			kill -s STOP "$p" 2>/dev/null || true
			stf_frozen+="${k} " stf_new=1
		done < <(_sweep_tree_read ${stf_roots[@]+"${stf_roots[@]}"})
		((${#stf_keys[@]})) || break
		stf_roots=("${stf_keys[@]}")
		((stf_new)) || break
	done
	_stf_out=(${stf_keys[@]+"${stf_keys[@]}"})
}

# _sweep_step_stop <signal>: stop the step sweep_step runs (_SWEEP_STEP_PID) and every
# process under it, for _sweep_on_signal. The whole tree, not the step's PID alone: a
# step's in-flight kubectl, its per-context `( ... ) &` workers and the commands they run
# would otherwise run on after the sweep ends and removes its lock. It freezes the tree
# (_sweep_tree_freeze: a process cannot start another one between the read and the
# signal), sends <signal> to each process, resumes them, and waits until they are gone
# (their EXIT traps clean up), at most SWEEP_STOP_GRACE_SEC seconds (config/options.env);
# a process that still runs then (one that ignores the signal, or a cleanup that hangs)
# gets SIGKILL, so the sweep never hangs on its step. The tree is read with `ps -A`, which
# works on Linux and macOS: a process group (`set -m`) would miss the commands GNU
# `timeout` runs (run_timeout: timeout moves itself to a group of its own) and would take
# the step out of the terminal's foreground, so Ctrl-C would no longer reach it. SIGINT
# and SIGHUP from the terminal (Ctrl-C, a closed terminal) already reached the processes
# in the terminal's foreground group (the sweep's, so the step's too): those are not sent
# the signal twice (that would cut their cleanup short), only the others (the timeout'd
# commands). A SIGINT or SIGHUP sent to the sweep's PID alone (a supervisor's
# `kill -INT <pid>`) reaches every process of the tree, as SIGTERM does. The tree's keys
# stay in _SWEEP_STEP_TREE while it waits, so sweep_step_kill (the EXIT trap, after a
# second signal ended this wait) finds the rest.
# shellcheck disable=SC2329
_sweep_step_stop() {
	local sig="$1" pid="${_SWEEP_STEP_PID:-}" grace="${SWEEP_STOP_GRACE_SEC:-10}" tpg="" deadline p g s k n=0
	local -a sss_tree=() sss_live=()
	[[ -n "$pid" && "${_SWEEP_STEP_OWNER:-}" == "${BASHPID:-$$}" ]] || return 0
	is_nonneg_int "$grace" || grace=10
	if [[ "$sig" != TERM ]]; then
		tpg="$(LC_ALL=C ps -o tpgid= -p "$$" 2>/dev/null)" || tpg=""
		tpg="${tpg//[[:space:]]/}"
		[[ "$tpg" =~ ^[1-9][0-9]*$ ]] || tpg=""
	fi
	_sweep_tree_freeze sss_tree "$pid"
	_SWEEP_STEP_TREE="${sss_tree[*]-}"
	if ((${#sss_tree[@]})); then
		echo "Stopping the running step (${_SWEEP_STEP_NAME:-PID ${pid}}): SIG${sig} to its ${#sss_tree[@]} process(es); any still running ${grace}s later get SIGKILL (SWEEP_STOP_GRACE_SEC)." >&2 || true
	fi
	while read -r p g s k; do
		[[ -n "$k" && "$s" != Z* ]] || continue
		[[ -n "$tpg" && "$g" == "$tpg" ]] || kill -s "$sig" "$p" 2>/dev/null || true
	done < <(_sweep_tree_read ${sss_tree[@]+"${sss_tree[@]}"})
	for k in ${sss_tree[@]+"${sss_tree[@]}"}; do kill -s CONT "${k%%@*}" 2>/dev/null || true; done
	deadline=$((SECONDS + grace))
	while ((${#sss_tree[@]})); do
		sss_live=()
		while read -r p g s k; do
			[[ -n "$k" && "$s" != Z* ]] || continue
			sss_live+=("$k")
		done < <(_sweep_tree_read "${sss_tree[@]}")
		sss_tree=(${sss_live[@]+"${sss_live[@]}"})
		_SWEEP_STEP_TREE="${sss_tree[*]-}"
		((${#sss_tree[@]})) || break
		((SECONDS < deadline)) || break
		sleep 0.2
	done
	if ((${#sss_tree[@]})); then
		_sweep_tree_freeze sss_tree "${sss_tree[@]}"
		for k in ${sss_tree[@]+"${sss_tree[@]}"}; do
			if kill -s KILL "${k%%@*}" 2>/dev/null; then n=$((n + 1)); fi
		done
		((n == 0)) || echo "warning: ${n} process(es) of the step still ran ${grace}s after SIG${sig}: sent SIGKILL (their own cleanup did not run)" >&2 || true
	fi
	wait "$pid" 2>/dev/null || true
	_SWEEP_STEP_PID="" _SWEEP_STEP_TREE=""
}

# sweep_step_kill: SIGKILL what still runs of the step sweep_step started in this shell
# (its tree: _SWEEP_STEP_TREE, else the step's PID), at once. sweep_outcome_on_exit calls
# it first, and a sweep's EXIT trap that runs a step of its own (tuning's revert) calls it
# before that: a second signal ends _sweep_step_stop's wait, and the sweep must not clean
# up, or remove its lock, beside a step that still runs. Does nothing when no step runs.
# shellcheck disable=SC2329
sweep_step_kill() {
	local pid="${_SWEEP_STEP_PID:-}" k
	local -a ssk_tree=()
	[[ -n "$pid" && "${_SWEEP_STEP_OWNER:-}" == "${BASHPID:-$$}" ]] || return 0
	read -r -a ssk_tree <<< "${_SWEEP_STEP_TREE:-$pid}"
	_sweep_tree_freeze ssk_tree ${ssk_tree[@]+"${ssk_tree[@]}"} "$pid"
	for k in ${ssk_tree[@]+"${ssk_tree[@]}"}; do kill -s KILL "${k%%@*}" 2>/dev/null || true; done
	((${#ssk_tree[@]} == 0)) || echo "warning: the sweep ended while its step (${_SWEEP_STEP_NAME:-PID ${pid}}) still ran: sent SIGKILL to its ${#ssk_tree[@]} process(es)" >&2 || true
	wait "$pid" 2>/dev/null || true
	_SWEEP_STEP_PID="" _SWEEP_STEP_TREE=""
}

# sweep_step <command> [<arg>...]: run one long step of a sweep (a setup, a probe, a
# cleanup, a profile apply or revert) so that a signal the sweep gets reaches it at once,
# and return the step's exit status. Call it as the command itself, in the same place:
#   if ! sweep_step "$SCRIPT_DIR/002-..." "${args[@]}"; then ...
#   sweep_step "$SCRIPT_DIR/005-cleanup.sh" --contexts "$csv" || rc=$?
# The step runs as a background job the sweep waits for: a trapped signal ends that wait
# at once (a foreground command would delay the trap until it returned: a SIGTERM sent to
# the sweep's process alone, by `kill <pid>` or a service manager, would wait 30-60 min
# for a step at 10k services), and _sweep_on_signal stops the step and every process under
# it (_sweep_step_stop). The step keeps the sweep's stdout and stderr and gets SIGINT and
# SIGQUIT back (bash ignores them in a background job, so Ctrl-C still reaches it); its
# stdin is /dev/null (no step reads the terminal). The command is exec'd in that job, so
# the signal reaches the step itself (a script that then runs its EXIT trap, as bash does
# on a signal it does not trap, and dies of it, writing no more rows), not a shell around
# it: pass a script or a binary, never a function (exec fails on one, with exit 127) or a
# pipeline (log a step's output with a redirection of the call, such as
# `sweep_step "$probe" "${args[@]}" > >(tee -a "$log") 2>&1`). A settle `sleep` stays a
# foreground command: it delays the signal by at most the settle. Before the step, the
# sweep's harness is read again (harness_sha_check, at most every HARNESS_SHA_CHECK_SEC).
# shellcheck disable=SC2329
sweep_step() {
	local _ss_rc=0
	harness_sha_check "${1##*/}"
	(
		trap - INT QUIT
		exec "$@"
	) &
	_SWEEP_STEP_PID=$! _SWEEP_STEP_OWNER="${BASHPID:-$$}" _SWEEP_STEP_NAME="${1##*/}"
	wait "$_SWEEP_STEP_PID" || _ss_rc=$?
	_SWEEP_STEP_PID=""
	return "$_ss_rc"
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

# sweep_outcome_on_exit <rc> [--note <msg>|--info <msg>...]: A sweep's EXIT trap calls
# it after its own cleanup (a tuning profile is reverted first, PL32), as
#   sweep_outcome_on_exit "$rc" ${RESUME_NOTES[@]+"${RESUME_NOTES[@]}"} || true
# with <rc> the $? the trap started with, and the notes the sweep gathered so far (a
# controlplane --resume's harness, Kubernetes and readiness notes), which its reports
# would otherwise lose. It first kills what still runs of a step (sweep_step_kill: a
# second signal ended the wait for it), then removes the sweep dir's lock this shell took
# (sweep_lock). Then it does nothing unless sweep_outcome_start armed it in this shell
# (never in a subshell) and <dir>/sweep-outcome.txt is still that start's not-finished
# record: the sweep wrote its outcome at its end, or never started. Else the sweep ended
# before its outcome, and the record says how:
#   - interrupted: a signal sweep_trap_signals caught (Ctrl-C, SIGTERM, a closed terminal:
#     _SWEEP_SIGNAL); the ERR trap for a command a signal killed (its exit 129, 130 or
#     143); or exit 0 with no reason (no exit of this harness before its outcome is 0). The
#     record stays not finished and gets ENDED_AT (UTC), ENDED_EXIT, when known
#     ENDED_SIGNAL, and the notes as NOTE= and INFO= lines (also one for a harness that
#     changed during the sweep: _harness_sha_sweep_end): the reports say the run was
#     interrupted then, before its outcome (it does not still run), with those notes.
#   - stopped: die (its message), the ERR trap (sweep_err_trap: the script, line and
#     command), or any other non-zero exit ("it exited <rc> before its end": set -e in a
#     function, which runs no ERR trap). sweep_outcome --stopped 1 --stop-reason <why>
#     --uncounted <...> rewrites the record (EXIT=1, STOPPED=1, STOP_REASON, PROBLEM
#     "could not count the sweep's <unit>: ...", TOTAL=unknown, each note, and the
#     start's NEXT as "next: ..."), then CUT_SHORT=1, STARTED_AT, the start's RESUMED_AT
#     (a --resume that stopped: the reports then show the outcome before it too, from
#     sweep-outcome.prev.txt) and ENDED_AT are added. The reason is recorded with the sweep
#     dir as <sweep dir> and $HOME as ~ (the reports are shared; the console keeps the full
#     text). Every report shows it as stopped, with the reason first, and exit 1. A stop is
#     exit 1, so another <rc> (4 or 3 would read as another outcome) ends the shell with
#     exit 1 here.
# Either way the console (stderr only) then names the sweep dir and the next step (a stop's
# next step is its "next:" note, printed with the outcome just before). A sweep
# killed outright (SIGKILL, out of memory, a lost host) runs no trap: its record stays not
# finished without ENDED_AT ("it died, or still runs"). Never dies otherwise; warns when it
# cannot write.
# An EXIT trap whose cleanup takes long (propagation's 007 over every member) calls
#   sweep_outcome_on_exit --mark-end "$rc"
# first: that adds ENDED_AT, ENDED_EXIT and ENDED_SIGNAL to the not-finished record at
# once (a second Ctrl-C during the cleanup kills the trap, and the record still says when
# and how the sweep ended) and keeps the time; the call after the cleanup then records the
# rest with that time.
# shellcheck disable=SC2329
sweep_outcome_on_exit() {
	local mark=0
	if [[ "${1:-}" == --mark-end ]]; then
		mark=1
		shift
	fi
	local rc="${1:-0}" dir="${_SWEEP_OUTCOME_ARMED_DIR:-}" f why="${_SWEEP_STOP_WHY:-}" by="${_SWEEP_STOP_BY:-}"
	local sig="${_SWEEP_SIGNAL:-}" now started next srid resumed k marked="${_SWEEP_ENDED_AT:-}"
	(($#)) && shift
	# A step a second signal left running is killed before anything else (sweep_step_kill).
	sweep_step_kill
	((mark)) || _sweep_unlock
	[[ -n "$dir" && "${_SWEEP_OUTCOME_ARMED_PID:-}" == "${BASHPID:-$$}" ]] || return 0
	f="${dir}/sweep-outcome.txt"
	sweep_outcome_unfinished "$f" || return 0
	srid="$(sed -n 's/^RUN_ID=//p' "$f" 2>/dev/null | head -n 1)"
	[[ "$srid" == "${_SWEEP_OUTCOME_ARMED_RID:-}" ]] || return 0
	# Once: a second EXIT (a trap that exits again) finds nothing to do.
	((mark)) || _SWEEP_OUTCOME_ARMED_DIR=""
	is_nonneg_int "$rc" || rc=1
	now="${marked:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
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
	if ((mark)); then
		[[ -z "$marked" ]] || return 0
		_SWEEP_ENDED_AT="$now"
		# A stop's exit is 1 (its record, written after the cleanup, replaces these lines).
		if [[ -z "$sig" ]] && { [[ -n "$why" ]] || ((rc != 0 && rc != 129 && rc != 130 && rc != 143)); }; then rc=1; fi
		{
			printf 'ENDED_AT=%s\nENDED_EXIT=%s\n' "$now" "$rc"
			[[ -z "$sig" ]] || printf 'ENDED_SIGNAL=SIG%s\n' "$sig"
		} 2>/dev/null >> "$f" || echo "warning: could not add ENDED_AT to ${f}" >&2
		return 0
	fi
	started="$(sed -n 's/^STARTED_AT=//p' "$f" 2>/dev/null | head -n 1)"
	resumed="$(sed -n 's/^RESUMED_AT=//p' "$f" 2>/dev/null | head -n 1)"
	next="$(sed -n 's/^NEXT=//p' "$f" 2>/dev/null | head -n 1)"
	next="${next#if it died, }"
	if [[ -n "$sig" ]] || { [[ -z "$why" ]] && ((rc == 0 || rc == 129 || rc == 130 || rc == 143)); }; then
		{
			# --mark-end wrote the ENDED_ lines already.
			if [[ -z "$marked" ]]; then
				printf 'ENDED_AT=%s\nENDED_EXIT=%s\n' "$now" "$rc"
				[[ -z "$sig" ]] || printf 'ENDED_SIGNAL=SIG%s\n' "$sig"
			fi
			# The sweep's notes so far (a --resume's): one line each, as sweep_outcome keeps them.
			k=1
			while ((k < $#)); do
				case "${!k}" in
				--note) k=$((k + 1)); printf 'NOTE=%s\n' "${!k//$'\n'/ }" ;;
				--info) k=$((k + 1)); printf 'INFO=%s\n' "${!k//$'\n'/ }" ;;
				esac
				k=$((k + 1))
			done
		} 2>/dev/null >> "$f" || echo "warning: could not add ENDED_AT to ${f}" >&2
		# A harness that changed during the sweep (harness_sha_check, the end check): a note.
		local hs_changed=""
		_harness_sha_sweep_end hs_changed
		if [[ -n "$hs_changed" ]]; then
			printf 'NOTE=%s\n' "$hs_changed" 2>/dev/null >> "$f" || true
			echo "warning: ${hs_changed}." >&2
		fi
		echo "warning: the sweep was interrupted (${sig:+SIG${sig}, }exit ${rc}) before its outcome; sweep-outcome.txt says it has not finished" >&2
		echo "  sweep dir: ${dir}${next:+; next: ${next}}" >&2
		return 0
	fi
	local orc="$rc" tilde='~' absdir
	rc=1
	[[ -n "$why" ]] || why="it exited ${orc} before its end (an unexpected failure: see its console output)"
	# The record (and every report re-generated from it) is shared: no local path in it.
	absdir="$(cd "$dir" 2>/dev/null && pwd)" || absdir=""
	[[ -z "$absdir" ]] || why="${why//"$absdir"/<sweep dir>}"
	why="${why//"$dir"/<sweep dir>}"
	if [[ -n "${HOME:-}" && "$HOME" != / ]]; then why="${why//"$HOME"/"$tilde"}"; fi
	local -a args=(--stopped "$rc" --stop-reason "$why" --unit "${_SWEEP_OUTCOME_ARMED_UNIT:-cells}"
		--uncounted "it stopped before its end at ${now}, so no count vouches for its rows, which may be partial"
		--record "$dir" --run-id "$srid" "$@")
	[[ -z "$next" ]] || args+=(--note "next: ${next}")
	sweep_outcome "${args[@]}" 0 || true
	{
		echo "CUT_SHORT=1"
		[[ -z "$started" ]] || echo "STARTED_AT=${started}"
		[[ -z "$resumed" ]] || echo "RESUMED_AT=${resumed}"
		echo "ENDED_AT=${now}"
	} 2>/dev/null >> "$f" || echo "warning: could not add CUT_SHORT to ${f}" >&2
	# sweep_outcome printed the next step (its "next:" note) just above.
	echo "  sweep dir: ${dir}" >&2
	((orc == 1)) || exit 1
	return 0
}

# sweep_outcome_recorded [--sweep-level-run-id] <results_dir> <text|md|json|csv> [<run_id>]:
# what the sweep recorded in <results_dir>/sweep-outcome.txt (sweep_outcome --record), for
# a report re-generated after the sweep. text and md name the record's run and exit,
# then its failed cells (FAILED_BY) and every PROBLEM, NOTE, INFO (as note:) and
# STOP_REASON line (nothing when the file is absent or records none of them); csv prints
# them as `# SWEEP_OUTCOME_<KEY>=` comment lines (nothing without the file); json prints
# {"exit":N,"run_id":"...","failed":N,"failed_by":"...","problems":[...],"notes":[...],
# "info":[...],"stop_reason":"...","unfinished":false}, or null without the file. A sweep
# that stopped (STOPPED=1: the stop record sweep_outcome_on_exit wrote, or a stop the sweep
# counted, such as REVERT_FAILED) leads with its reason, under a STOPPED header (text
# "...): STOPPED", then "stopped early: <reason>"; md "**stopped**"; json "stopped":true;
# csv `# SWEEP_OUTCOME_STOPPED=1`, then, for a stop record, CUT_SHORT=1, STARTED_AT and
# ENDED_AT; the record before a --resume the same way, as EARLIER_ lines).
# A sweep that has not finished (its sweep_outcome_start record: it died, or still
# runs) says so in every format (text and md a warning with its start time and what to do,
# csv `# SWEEP_OUTCOME_EXIT=unfinished`, json "exit":null and "unfinished":true with
# "started_at", and "resumed_at" for a --resume); one whose EXIT trap ran (ENDED_AT:
# Ctrl-C or a signal) says it was interrupted at that time, and by which signal when
# ENDED_SIGNAL names it (csv `# SWEEP_OUTCOME_INTERRUPTED_AT=` and `_BY=`, json
# "interrupted_at" and "interrupted_by"), with the notes it gathered until then (its NOTE=
# and INFO= lines). While a --resume has not finished (it moved the record to
# sweep-outcome.prev.txt and has not written its own yet), every format says so, then shows
# that record, the outcome before it: text and md after a warning; json "unfinished":true
# and "resume_unfinished":true, with "started_at", "resumed_at", exit, failed, failed_by and
# stop_reason null and no problem (this run counted nothing yet), its own notes so far, and
# the earlier record's fields under "earlier"; csv `# SWEEP_OUTCOME_EXIT=unfinished`,
# `# SWEEP_OUTCOME_RESUME_UNFINISHED=1`, STARTED_AT, RESUMED_AT and INTERRUPTED_AT/_BY as
# this run's, then the earlier record as `# SWEEP_OUTCOME_EARLIER_<KEY>=` lines. A --resume
# that stopped (a stop record, CUT_SHORT=1, with sweep-outcome.prev.txt beside it) shows its
# stop, then the outcome before it the same way (json "resumed_at" and "earlier", csv
# `# SWEEP_OUTCOME_RESUMED_AT=` and the EARLIER_ lines; text and md a second block). The
# sweep's own reports set _SWEEP_OUTCOME_PENDING=1, as theirs is about to be written: md
# prints one line that ends with SWEEP_OUTCOME_PENDING_MARK (sweep_outcome --md replaces it
# with the outcome; a report left with it is from a sweep that did not finish, and its
# sweep-outcome.txt says how it ended), the other formats nothing (json null). <run_id> is
# the report's run, compared with the record's RUN_ID. By default (one run, as
# config_check_multi_run counted it; nothing is compared for a pooled report) the record
# matches when its RUN_ID is the sweep-level id of a TSV under <results_dir> (SWEEP_RUN_ID,
# else RUN_ID, so a renamed sweep dir is still its sweep), else, only when no TSV under
# it carries a sweep-level id, the sweep-* dir's own id, else when the dir holds that
# run's sweep-<RUN_ID>.md (sweeps whose cells mint their own RUN_IDs). A TSV's id is
# sweep-level when it is a SWEEP_RUN_ID, or with --sweep-level-run-id (a suite whose TSV
# RUN_ID is the sweep's: controlplane) its RUN_ID. A record from another run is named as
# such, in every format (json report_run_id) and on stderr.
# shellcheck disable=SC2329
sweep_outcome_recorded() {
	local sweep_level=0
	if [[ "${1:-}" == --sweep-level-run-id ]]; then
		sweep_level=1
		shift
	fi
	local f="${1}/sweep-outcome.txt" prev="${1}/sweep-outcome.prev.txt" fmt="$2" want="${3:-}" rid other="" sids ids dkey=""
	local mode=final rf
	local -a files=()
	if sweep_outcome_unfinished "$f"; then
		mode=first
		if [[ "${_SWEEP_OUTCOME_PENDING:-0}" == 1 ]]; then
			mode=pending
		elif [[ -f "$prev" ]]; then
			mode=resume
		fi
	elif [[ ! -f "$f" && -f "$prev" && "${_SWEEP_OUTCOME_PENDING:-0}" != 1 ]]; then
		mode=resume
	elif [[ -f "$prev" ]] && grep -qx 'CUT_SHORT=1' "$f" 2>/dev/null; then
		# A --resume that stopped: its stop record, then the outcome before it.
		mode=stopres
	fi
	if [[ "$mode" == pending ]]; then
		case "$fmt" in
		json) echo null ;;
		md) printf '%s\n\n' "> **Sweep outcome**: not written yet: this report was made while the sweep ran, and the sweep appends its outcome at its end. A report that still shows this line, with no \"Sweep outcome\" section below, is from a sweep that did not finish (it died, was interrupted or stopped): its sweep-outcome.txt says how it ended, and a report re-generated from the sweep dir shows it. ${SWEEP_OUTCOME_PENDING_MARK}" ;;
		esac
		return 0
	fi
	# rf: the record whose RUN_ID is checked (the outcome a resume shows is the earlier one).
	rf="$f"
	[[ "$mode" != resume ]] || rf="$prev"
	if [[ ! -f "$rf" ]]; then
		[[ "$fmt" != json ]] || echo null
		return 0
	fi
	case "$want" in mixed:* | unknown*) want="" ;; esac
	rid="$(sed -n 's/^RUN_ID=//p' "$rf" 2>/dev/null | head -n 1)"
	if [[ -n "$rid" && "$rid" != unknown ]]; then
		if [[ -n "$want" ]]; then
			[[ "$rid" == "$want" ]] || other="$want"
		elif [[ "${MULTI_RUN_N:-0}" == 1 ]]; then
			sids="$(_sweep_outcome_sweep_ids "$1")"
			ids="$(cut -f 2 <<<"$sids")"
			dkey="${MULTI_RUN_IDS:-}"
			dkey="${dkey#sweep-}"
			case "$dkey" in mixed:* | unknown*) dkey="" ;; esac
			# The dir's own id only when no TSV under it names the sweep.
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
		echo "warning: ${rf} was recorded by run ${rid}, not by this report's run ${other}; the outcome it repeats may not describe these rows" >&2
	fi
	case "$mode" in
	resume) [[ ! -f "$f" ]] || files+=("$f"); files+=("$prev") ;;
	stopres) files=("$f" "$prev") ;;
	*) files=("$f") ;;
	esac
	# Record 1 is sweep-outcome.txt (the current run's), record 2 sweep-outcome.prev.txt (the
	# outcome before a --resume).
	awk -v fmt="$fmt" -v other="$other" -v mode="$mode" -v prevf="$prev" '
		function jstr(v) { gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v); gsub(/\t/, "\\t", v); return "\"" v "\"" }
		function jl(r, k,    i, n, s) {
			n = (k == "p") ? NP[r] : (k == "n") ? NN[r] : NI[r]
			s = "["
			for (i = 1; i <= n; i++) s = s (i > 1 ? "," : "") jstr(k == "p" ? PR[r, i] : (k == "n") ? NT[r, i] : INF[r, i])
			return s "]"
		}
		function num(v) { return v ~ /^[0-9]+$/ }
		function ridr(r) { return RID[r] == "" ? "unknown" : RID[r] }
		function unitr(r) { return UNIT[r] == "" ? "cells" : UNIT[r] }
		function nfail(r) { return num(FAILED[r]) ? FAILED[r] + 0 : 0 }
		function stopped(r) { return STOPPED[r] == "1" || CUT[r] }
		function quiet(r) { return NP[r] + NN[r] + NI[r] + nfail(r) == 0 && STOP[r] == "" && !stopped(r) }
		function rec(r) {
			return sprintf("{\"exit\":%s,\"run_id\":%s,\"failed\":%s,\"failed_by\":%s,\"problems\":%s,\"notes\":%s,\"info\":%s,\"stop_reason\":%s,\"unfinished\":false%s}", (num(EX[r]) ? EX[r] : "null"), jstr(ridr(r)), (num(FAILED[r]) ? FAILED[r] : "null"), jstr(FBY[r]), jl(r, "p"), jl(r, "n"), jl(r, "i"), jstr(STOP[r]), (stopped(r) ? ",\"stopped\":true" : ""))
		}
		function csvrec(r, p,    i) {
			printf "# SWEEP_OUTCOME_%sRUN_ID=%s\n# SWEEP_OUTCOME_%sEXIT=%s\n# SWEEP_OUTCOME_%sFAILED=%s\n", p, ridr(r), p, EX[r], p, (num(FAILED[r]) || FAILED[r] == "" ? nfail(r) : FAILED[r])
			# A stopped record says so (json "stopped":true, text STOPPED), with its times.
			if (stopped(r)) printf "# SWEEP_OUTCOME_%sSTOPPED=1\n", p
			if (CUT[r]) printf "# SWEEP_OUTCOME_%sCUT_SHORT=1\n", p
			if (stopped(r) && START[r] != "") printf "# SWEEP_OUTCOME_%sSTARTED_AT=%s\n", p, START[r]
			if (stopped(r) && ENDED[r] != "") printf "# SWEEP_OUTCOME_%sENDED_AT=%s\n", p, ENDED[r]
			if (FBY[r] != "") printf "# SWEEP_OUTCOME_%sFAILED_BY=%s\n", p, FBY[r]
			for (i = 1; i <= NP[r]; i++) printf "# SWEEP_OUTCOME_%sPROBLEM=%s\n", p, PR[r, i]
			for (i = 1; i <= NN[r]; i++) printf "# SWEEP_OUTCOME_%sNOTE=%s\n", p, NT[r, i]
			for (i = 1; i <= NI[r]; i++) printf "# SWEEP_OUTCOME_%sINFO=%s\n", p, INF[r, i]
			if (STOP[r] != "") printf "# SWEEP_OUTCOME_%sSTOP_REASON=%s\n", p, STOP[r]
		}
		function li(kind, text) {
			if (fmt == "md") printf "> - %s: %s\n", kind, text
			else printf "  %s: %s\n", kind, text
		}
		function title(r, src, label) {
			if (fmt == "md") printf "> **%s** (recorded in `%s` by run `%s`, exit %s):%s\n", label, src, ridr(r), EX[r], (stopped(r) ? " **stopped**" : "")
			else printf "%s (recorded in %s by run %s, exit %s):%s\n", toupper(label), src, ridr(r), EX[r], (stopped(r) ? " STOPPED" : "")
		}
		# body: the lines of record r; a stopped one leads with its reason. The warnings in W[1..nw]
		# (this report adds them) come right after the reason, before the lines of the record.
		function body(r,    i, lead) {
			lead = stopped(r)
			if (lead && STOP[r] != "") li("stopped early", STOP[r])
			for (i = 1; i <= nw; i++) li("warning", W[i])
			nw = 0
			if (nfail(r) > 0) li("error", sprintf("%d of %s %s failed: %s", nfail(r), TOTAL[r], unitr(r), FBY[r]))
			for (i = 1; i <= NP[r]; i++) li("error", PR[r, i])
			for (i = 1; i <= NN[r]; i++) li("warning", NT[r, i])
			for (i = 1; i <= NI[r]; i++) li("note", INF[r, i])
			if (!lead && STOP[r] != "") li("stopped early", STOP[r])
		}
		{ r = (FILENAME == prevf) ? 2 : 1 }
		/^EXIT=/ { EX[r] = substr($0, 6) }
		/^RUN_ID=/ { RID[r] = substr($0, 8) }
		/^UNIT=/ { UNIT[r] = substr($0, 6) }
		/^TOTAL=/ { TOTAL[r] = substr($0, 7) }
		/^FAILED=/ { FAILED[r] = substr($0, 8) }
		/^FAILED_BY=/ { FBY[r] = substr($0, 11) }
		/^STOPPED=/ { STOPPED[r] = substr($0, 9) }
		/^STOP_REASON=/ { STOP[r] = substr($0, 13) }
		/^CUT_SHORT=1$/ { CUT[r] = 1 }
		/^STARTED_AT=/ { START[r] = substr($0, 12) }
		/^RESUMED_AT=/ { RES[r] = substr($0, 12) }
		/^ENDED_AT=/ { ENDED[r] = substr($0, 10) }
		/^ENDED_EXIT=/ { ENDEX[r] = substr($0, 12) }
		/^ENDED_SIGNAL=/ { ENDSIG[r] = substr($0, 14) }
		/^NEXT=/ { NXT[r] = substr($0, 6) }
		/^PROBLEM=/ { PR[r, ++NP[r]] = substr($0, 9) }
		/^NOTE=/ { NT[r, ++NN[r]] = substr($0, 6) }
		/^INFO=/ { INF[r, ++NI[r]] = substr($0, 6) }
		END {
			rr = (mode == "resume") ? 2 : 1
			ol = "the record is from run " ridr(rr) ", not from the run this report reads (" other ")"
			ro = (other == "" ? "" : ",\"report_run_id\":" jstr(other))
			if (mode == "first") {
				nx = NXT[1]
				if (nx == "") nx = "if it died, run it again"
				fw = "this sweep has not finished (it died, or still runs): " (RES[1] != "" ? "its --resume that started at " RES[1] : "the run that started at " START[1]) " has written no outcome yet, so no cell count vouches for these results, which may be partial; " nx
				# Its EXIT trap ran: it was interrupted (Ctrl-C or a signal), it does not still run.
				if (ENDED[1] != "") {
					sub(/^if it died, /, "", nx)
					fw = "this sweep has not finished: " (RES[1] != "" ? "its --resume that started at " RES[1] : "the run that started at " START[1]) " was interrupted at " ENDED[1] " (" (ENDSIG[1] == "SIGINT" ? "SIGINT: Ctrl-C" : ENDSIG[1] == "SIGHUP" ? "SIGHUP: its terminal closed" : ENDSIG[1] != "" ? ENDSIG[1] : "exit " ENDEX[1] ", no error recorded") ") before it wrote its outcome, so no cell count vouches for these results, which may be partial; next: " nx
				}
			}
			# ul: an unfinished --resume, before the outcome it shows; sl: a --resume that stopped.
			ul = "the last --resume of this sweep" (RES[1] != "" ? " (started at " RES[1] ")" : "") " has not finished (" (ENDED[1] != "" ? "it was interrupted at " ENDED[1] (ENDSIG[1] != "" ? " by " ENDSIG[1] : "") "; run the same --resume again" : "it died, or still runs; if it died, run the same --resume again") "): this is the outcome before it, from sweep-outcome.prev.txt"
			sl = "this stop ended a --resume of the sweep" (RES[1] != "" ? " (started at " RES[1] ")" : "") ": the outcome before it, from sweep-outcome.prev.txt, follows; the rows that --resume added before it stopped are in the TSV, uncounted"
			if (fmt == "json") {
				if (mode == "first")
					printf "{\"exit\":null,\"run_id\":%s,\"failed\":null,\"failed_by\":null,\"problems\":[],\"notes\":%s,\"info\":%s,\"stop_reason\":null,\"unfinished\":true,\"started_at\":%s%s%s%s}\n", jstr(ridr(1)), jl(1, "n"), jl(1, "i"), (START[1] == "" ? "null" : jstr(START[1])), (RES[1] == "" ? "" : ",\"resumed_at\":" jstr(RES[1])), (ENDED[1] == "" ? "" : ",\"interrupted_at\":" jstr(ENDED[1]) (ENDSIG[1] == "" ? "" : ",\"interrupted_by\":" jstr(ENDSIG[1]))), ro
				else if (mode == "resume")
					printf "{\"exit\":null,\"run_id\":%s,\"failed\":null,\"failed_by\":null,\"problems\":[],\"notes\":%s,\"info\":%s,\"stop_reason\":null,\"unfinished\":true,\"resume_unfinished\":true,\"started_at\":%s,\"resumed_at\":%s%s%s,\"earlier\":%s}\n", jstr(RID[1] != "" ? RID[1] : ridr(2)), jl(1, "n"), jl(1, "i"), (START[1] == "" ? "null" : jstr(START[1])), (RES[1] == "" ? "null" : jstr(RES[1])), (ENDED[1] == "" ? "" : ",\"interrupted_at\":" jstr(ENDED[1]) (ENDSIG[1] == "" ? "" : ",\"interrupted_by\":" jstr(ENDSIG[1]))), ro, rec(2)
				else if (mode == "stopres") {
					s = rec(1)
					printf "%s,\"resumed_at\":%s%s,\"earlier\":%s}\n", substr(s, 1, length(s) - 1), (RES[1] == "" ? "null" : jstr(RES[1])), ro, rec(2)
				} else {
					s = rec(1)
					printf "%s%s}\n", substr(s, 1, length(s) - 1), ro
				}
				exit
			}
			if (fmt == "csv") {
				if (mode == "first" || mode == "resume") {
					if (mode == "resume") printf "# WARNING: %s\n", ul
					printf "# SWEEP_OUTCOME_RUN_ID=%s\n# SWEEP_OUTCOME_EXIT=unfinished\n", (RID[1] != "" ? RID[1] : ridr(rr))
					if (mode == "resume") printf "# SWEEP_OUTCOME_RESUME_UNFINISHED=1\n"
					if (mode == "first" || START[1] != "") printf "# SWEEP_OUTCOME_STARTED_AT=%s\n", START[1]
					if (RES[1] != "") printf "# SWEEP_OUTCOME_RESUMED_AT=%s\n", RES[1]
					if (ENDED[1] != "") printf "# SWEEP_OUTCOME_INTERRUPTED_AT=%s\n", ENDED[1]
					if (ENDSIG[1] != "") printf "# SWEEP_OUTCOME_INTERRUPTED_BY=%s\n", ENDSIG[1]
					for (i = 1; i <= NN[1]; i++) printf "# SWEEP_OUTCOME_NOTE=%s\n", NT[1, i]
					for (i = 1; i <= NI[1]; i++) printf "# SWEEP_OUTCOME_INFO=%s\n", INF[1, i]
					if (mode == "first") printf "# WARNING: %s\n", fw
					else csvrec(2, "EARLIER_")
					if (other != "") printf "# WARNING: sweep-outcome.txt: %s\n", ol
					exit
				}
				csvrec(1, "")
				if (mode == "stopres") {
					if (RES[1] != "") printf "# SWEEP_OUTCOME_RESUMED_AT=%s\n", RES[1]
					printf "# WARNING: %s\n", sl
					csvrec(2, "EARLIER_")
				}
				if (other != "") printf "# WARNING: sweep-outcome.txt: %s\n", ol
				exit
			}
			if (mode == "first") {
				if (fmt == "md") printf "> **Sweep outcome** (recorded in `sweep-outcome.txt` by run `%s`): **not finished**\n", ridr(1)
				else printf "SWEEP OUTCOME (recorded in sweep-outcome.txt by run %s): NOT FINISHED\n", ridr(1)
				li("warning", fw)
				if (other != "") li("warning", ol)
				for (i = 1; i <= NN[1]; i++) li("warning", NT[1, i])
				for (i = 1; i <= NI[1]; i++) li("note", INF[1, i])
				printf "\n"
				exit
			}
			if (mode == "resume") {
				title(2, "sweep-outcome.prev.txt", "Sweep outcome")
				nw = 0
				W[++nw] = ul
				for (i = 1; i <= NN[1]; i++) W[++nw] = NT[1, i] " (noted by that --resume)"
				for (i = 1; i <= NI[1]; i++) W[++nw] = INF[1, i] " (noted by that --resume)"
				if (other != "") W[++nw] = ol
				body(2)
				printf "\n"
				exit
			}
			if (mode == "final" && quiet(1) && other == "") exit
			title(1, "sweep-outcome.txt", "Sweep outcome")
			nw = 0
			if (mode == "stopres") W[++nw] = sl
			if (other != "") W[++nw] = ol
			body(1)
			printf "\n"
			if (mode == "stopres") {
				title(2, "sweep-outcome.prev.txt", "Outcome before this --resume")
				body(2)
				if (quiet(2)) li("note", sprintf("all %s %s ran; nothing failed or was noted", TOTAL[2], unitr(2)))
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
# In the shell that ran harness_sha_for_sweep it reads the harness again: one that changed
# during the sweep (at its end, or at a harness_sha_check before a step) is a problem too,
# naming both values and when the change was first read (_harness_sha_sweep_end).
#   --stopped <rc>   the sweep stopped early and exits <rc> (1 or 3), which outranks 4: the
#                    cells are still counted, "All cells ran" is never printed (they did
#                    not), the lines name <rc>, and it returns <rc>
#   --stop-reason <text>  why it stopped (RETIRE_FAILED, the reach gate, REVERT_FAILED, ...);
#                    named in the record and the markdown
#   --unit <noun>    what a cell is called, plural (default cells; tuning: passes)
#   --where <text>   where a failed one shows in the results (default: the report's
#                    placeholder rows, in n_total, not n_valid)
#   --problem <msg>  the sweep failed although its cells ran (the Istio version changed
#                    under it, a foreign Istio CR edit); printed, recorded and counted like
#                    a failed cell
#   --uncounted <why>  the sweep could not count its cells: a problem ("could not count
#                    the sweep's <unit>: <why>"), "All cells ran" is never printed, and the
#                    record says TOTAL=unknown, FAILED=unknown and SKIPPED=unknown
#   --note <msg>     a caveat; printed and recorded, not a failure
#   --info <msg>     a fact worth keeping that is not a caveat (a --resume whose members
#                    were all ready); printed on stdout as "note: <msg>." and recorded
#   --record <dir>   also write the outcome to <dir>/sweep-outcome.txt, with RUN_ID
#                    (--run-id) and HARNESS_SHA (the sweep's HARNESS_SHA, as its TSVs
#                    record it, else harness_sha when preamble.sh is sourced)
#   --run-id <id>    the sweep's RUN_ID, for the record
#   --md <file>      also append it to that markdown report, as a "Sweep outcome" section;
#                    may be given more than once (the summary and the scale envelope).
#                    A file that does not exist is skipped. The report's "not written
#                    yet" line (SWEEP_OUTCOME_PENDING_MARK) is removed first.
# A report re-generated later shows the record's PROBLEM, NOTE and INFO lines again
# (sweep_outcome_recorded). The record replaces the sweep's sweep_outcome_start record;
# a sweep dir that still holds that one is a sweep that was killed before its end (no trap
# ran), was interrupted (with ENDED_AT), or still runs; one that stopped with an error
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
	# The sweep's harness at its end (harness_sha_for_sweep's shell only): a change is a problem.
	local so_hs=""
	_harness_sha_sweep_end so_hs
	[[ -z "$so_hs" ]] || problems+=("$so_hs")
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
	# A stop leads the record's lines in the markdown (the reason first, under a
	# "stopped" heading); the console printed it already.
	if [[ -n "$stop_rc" && ${#failed_r[@]} -eq 0 && ${#problems[@]} -eq 0 ]]; then
		lines=("rec|The sweep stopped early${stop_why:+ (${stop_why})}; it exits ${stop_rc}." ${lines[@]+"${lines[@]}"})
	elif [[ -n "$stop_why" ]]; then
		lines=("rec|It stopped early: ${stop_why}." ${lines[@]+"${lines[@]}"})
	fi
	for r in ${lines[@]+"${lines[@]}"}; do
		case "$r" in
		err\|*) echo "${r#err|}" >&2 ;;
		out\|*) echo "${r#out|}" ;;
		esac
	done
	if [[ -n "$record" ]]; then
		local so_stopped=0 so_total=unknown so_failed=unknown so_skipped=unknown
		if [[ -n "$stop_rc" ]]; then so_stopped=1; fi
		if [[ -z "$uncounted" ]]; then
			so_total="$cells" so_failed="${#failed_r[@]}" so_skipped="${#skipped_r[@]}"
		fi
		{
			echo "# Sweep outcome (tests/lib/common.sh sweep_outcome)"
			echo "# DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			echo "RUN_ID=${run_id_r:-unknown}"
			echo "HARNESS_SHA=${HARNESS_SHA:-$(harness_sha)}"
			echo "EXIT=${rc}"
			echo "STOPPED=${so_stopped}"
			echo "STOP_REASON=${stop_why}"
			echo "UNIT=${unit}"
			echo "TOTAL=${so_total}"
			echo "FAILED=${so_failed}"
			echo "FAILED_BY=${by_fail}"
			echo "SKIPPED=${so_skipped}"
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
			echo "## Sweep outcome$([[ -z "$stop_rc" ]] || echo ": stopped")"
			echo ""
			echo "Exit ${rc}. $([[ -n "$record" ]] && echo "Also in \`sweep-outcome.txt\`.")"
			echo ""
			for r in ${lines[@]+"${lines[@]}"}; do echo "- ${r#*|}"; done
		} 2>/dev/null >> "$md_r" || echo "warning: could not append the outcome to ${md_r}" >&2
	done
	return "$rc"
}

# --- the harness a run uses (PL2) ---

# HARNESS_PATHS: the dirs whose content is the harness (harness_sha's -dirty hash); a file
# outside them (docs/, a campaign note, the READMEs at the top) never makes a run dirty.
# shellcheck disable=SC2034
HARNESS_PATHS=(tests config charts terraform)

# harness_sha [--exclude <dir>]...: the harness the run uses (PL2): `git -C "${ROOT:-.}"
# describe --always --abbrev=7`, or unknown when git cannot name it. A harness with
# uncommitted changes under HARNESS_PATHS (tracked files that differ from HEAD, or untracked
# files that are not ignored) gets `-dirty.<8hex>`: `<describe>-dirty.<8hex>`
# (_harness_dirty_hash), so two different uncommitted trees on one commit record two
# different values, and one tree records one value whatever the operator's git config.
# Submodules (the bats checkouts) never count, as `--ignore-submodules`: one moved, copied
# without its .git or with its gitdir gone reads clean. When the content cannot be hashed, a
# harness whose tracked files differ from HEAD reads `-dirty.unknown`. The untracked files
# under each --exclude <dir> (a run's output dir inside the checkout: its own results) do not
# count, and neither do those under HARNESS_SHA_EXCLUDE, the results dir a sweep exports to
# the steps it runs (harness_sha_for_sweep); a tracked file there still does. Every call
# reads the live tree, so a step of a sweep records the harness it runs, also when a file
# changed after the sweep started (harness_sha_check, sweep_outcome).
# shellcheck disable=SC2329
harness_sha() {
	local sha h root="${ROOT:-.}"
	local -a hs_excl=()
	while (($#)); do
		case "$1" in
		--exclude)
			[[ -z "${2:-}" ]] || hs_excl+=("$2")
			shift 2 || shift
			;;
		*) shift ;;
		esac
	done
	[[ -z "${HARNESS_SHA_EXCLUDE:-}" ]] || hs_excl+=("$HARNESS_SHA_EXCLUDE")
	# No --dirty: it fails (exit 128) when a submodule's gitdir is gone, and counts a moved
	# submodule; the content hash below says whether the harness is dirty.
	sha="$(git -C "$root" describe --always --abbrev=7 2>/dev/null || true)"
	[[ -n "$sha" ]] || sha="unknown"
	if [[ "$sha" != unknown ]]; then
		if h="$(_harness_dirty_hash ${hs_excl[@]+"${hs_excl[@]}"})"; then
			[[ -z "$h" ]] || sha+="-dirty.${h}"
		elif ! git -C "$root" diff --quiet --no-ext-diff --no-textconv --ignore-submodules=all HEAD -- \
			"${HARNESS_PATHS[@]/#/:(top,literal)}" 2>/dev/null; then
			# The content could not be hashed, and the tracked files differ from HEAD (or git
			# cannot tell): dirty, by what is unknown.
			sha+="-dirty.unknown"
		fi
	fi
	printf '%s\n' "$sha"
}

# harness_sha_for_sweep [<output_dir>]: a sweep's harness at its start. Sets HARNESS_SHA
# (harness_sha --exclude <output_dir>) and exports <output_dir> (absolute) as
# HARNESS_SHA_EXCLUDE, never the value: each step (a probe, a report) reads the live tree
# minus the sweep's results, so a step that ran on changed code records what it ran. Keeps
# the start's value for harness_sha_check (before each step, through sweep_step) and for
# the end check in sweep_outcome, which records a harness that changed during the sweep as
# a problem. Call it before the first step, as a plain command (not in a subshell).
# shellcheck disable=SC2329
harness_sha_for_sweep() {
	local hsfs_d="${1:-}"
	unset HARNESS_SHA_EXCLUDE
	if [[ -n "$hsfs_d" ]]; then
		[[ "$hsfs_d" == /* ]] || hsfs_d="${PWD%/}/${hsfs_d}"
		HARNESS_SHA="$(harness_sha --exclude "$hsfs_d")"
		export HARNESS_SHA_EXCLUDE="$hsfs_d"
	else
		HARNESS_SHA="$(harness_sha)"
	fi
	_HARNESS_SHA_START="$HARNESS_SHA" _HARNESS_SHA_PID="${BASHPID:-$$}" _HARNESS_SHA_CHECKED="$SECONDS"
	_HARNESS_SHA_OK_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" _HARNESS_SHA_OK_BEFORE="" _HARNESS_SHA_SEEN=""
	_HARNESS_SHA_SEEN_AT="" _HARNESS_SHA_SEEN_BEFORE="" _HARNESS_SHA_END=""
}

# harness_sha_check <step>: in the shell that ran harness_sha_for_sweep, read the harness
# again before <step> (sweep_step names the step's script), at most once every
# HARNESS_SHA_CHECK_SEC seconds (config/options.env; 0: before every step). The first value
# other than the start's is kept, with when and before which step it was read, and printed
# once as a WARNING; the sweep goes on, and sweep_outcome records the change as a problem
# (exit 4). Never dies.
# shellcheck disable=SC2329
harness_sha_check() {
	[[ -n "${_HARNESS_SHA_START:-}" && "${_HARNESS_SHA_PID:-}" == "${BASHPID:-$$}" && -z "${_HARNESS_SHA_SEEN:-}" ]] \
		|| return 0
	local every="${HARNESS_SHA_CHECK_SEC:-60}" v
	is_nonneg_int "$every" || every=60
	((SECONDS - ${_HARNESS_SHA_CHECKED:-0} >= every)) || return 0
	_HARNESS_SHA_CHECKED="$SECONDS"
	v="$(harness_sha)"
	if [[ "$v" == "$_HARNESS_SHA_START" ]]; then
		_HARNESS_SHA_OK_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" _HARNESS_SHA_OK_BEFORE="${1:-a step}"
		return 0
	fi
	_HARNESS_SHA_SEEN="$v" _HARNESS_SHA_SEEN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" _HARNESS_SHA_SEEN_BEFORE="${1:-a step}"
	local hp
	hp="$(printf '%s/, ' "${HARNESS_PATHS[@]}")"
	echo "WARNING: the harness changed during the sweep: HARNESS_SHA=${_HARNESS_SHA_START} at its start, ${v} now (read before ${_HARNESS_SHA_SEEN_BEFORE}): a file under ${hp%, } was edited, or a git checkout or pull ran. The sweep goes on; its outcome records this as a problem (exit 4)." >&2 || true
	return 0
}

# _harness_sha_sweep_end <out_var>: once per sweep, in the shell that ran
# harness_sha_for_sweep: read the harness again (the end check) and set <out_var> to the
# problem sweep_outcome records when it changed during the sweep (a value other than the
# start's at the end, or at a harness_sha_check before a step), naming each value and when
# it was read; empty when it did not. A second call returns the first call's answer.
# shellcheck disable=SC2329
_harness_sha_sweep_end() {
	local -n _hse_out="$1"
	_hse_out=""
	[[ -n "${_HARNESS_SHA_START:-}" && "${_HARNESS_SHA_PID:-}" == "${BASHPID:-$$}" ]] || return 0
	local s="$_HARNESS_SHA_START" e last first
	if [[ -z "${_HARNESS_SHA_END:-}" ]]; then
		_HARNESS_SHA_END="$(harness_sha)"
		_HARNESS_SHA_END_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	fi
	e="$_HARNESS_SHA_END"
	last="at the sweep's start (${_HARNESS_SHA_OK_AT:-})"
	[[ -z "${_HARNESS_SHA_OK_BEFORE:-}" ]] || last="at ${_HARNESS_SHA_OK_AT}, before ${_HARNESS_SHA_OK_BEFORE}"
	if [[ -n "${_HARNESS_SHA_SEEN:-}" ]]; then
		first="${_HARNESS_SHA_SEEN} at ${_HARNESS_SHA_SEEN_AT}, before ${_HARNESS_SHA_SEEN_BEFORE} (the read before that, ${last}, still gave ${s})"
		if [[ "$e" == "$s" ]]; then
			_hse_out="the harness changed during the sweep, and back: HARNESS_SHA=${s} at its start and at its end, but ${first}"
		else
			_hse_out="the harness changed during the sweep: HARNESS_SHA=${s} at its start, ${e} at its end (${_HARNESS_SHA_END_AT}), first read ${first}"
		fi
	elif [[ "$e" != "$s" ]]; then
		_hse_out="the harness changed during the sweep: HARNESS_SHA=${s} at its start, ${e} at its end (${_HARNESS_SHA_END_AT}); the last read that gave ${s} was ${last}"
	else
		return 0
	fi
	_hse_out+=", so the steps after that read may have run other code than ${s} (a probe's TSV records the harness it ran; the sweep's own files record the start's): run the sweep again if the change matters"
	return 0
}

# _harness_dirty_hash [<exclude_dir>...]: 8 hex digits that name the uncommitted content of
# the harness (HARNESS_PATHS) under ROOT, or nothing for a clean one; returns 1 (prints
# nothing) when git cannot hash it. The content, never a diff (a diff's text follows the
# operator's git config: diff.context, diff.orderFile, core.abbrev): the tree object id git
# would write for the working tree, built in a temporary index (GIT_INDEX_FILE, never the
# operator's): `read-tree HEAD`, then every tracked path and every untracked file that is
# not ignored under HARNESS_PATHS (`ls-files --cached`, `ls-files --others
# --exclude-standard`) through `update-index --add --remove --info-only` (hashes each file
# once, writes no object into the repository), then `write-tree --missing-ok`. A clean
# harness is HEAD's own tree. The operator's git config does not change it: core.autocrlf is
# pinned off (line endings count as they are), core.fileMode on (an executable bit counts),
# and core.attributesFile to /dev/null with GIT_ATTR_NOSYSTEM (the global and system
# gitattributes, also the default ~/.config/git/attributes, never filter what is hashed;
# the repository's own .gitattributes do). Ignored files never count: .gitignore (editor and
# Finder files: .DS_Store, *.swp, *.swo, *~; the results/ dirs), .git/info/exclude, and the
# operator's global excludes: core.excludesFile, or git's default ~/.config/git/ignore
# ($XDG_CONFIG_HOME/git/ignore) when that key is unset (a file that only it ignores reads
# clean for that operator). The untracked files under each <exclude_dir> are left out
# (`:(exclude)` pathspec; its tracked files count), and so is each submodule of HEAD (its
# gitlink keeps HEAD's commit). The path list goes through a file, never a pipe, so the
# result is the same with and without pipefail. git only: no sha256sum or shasum.
# shellcheck disable=SC2329
_harness_dirty_hash() {
	local root="${ROOT:-.}" top topp idx tree htree d rel ent
	local -a hdh_spec=("${HARNESS_PATHS[@]/#/:(top,literal)}") hdh_excl=()
	top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || return 1
	htree="$(git -C "$top" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null)" || return 1
	topp="$(cd "$top" 2>/dev/null && pwd -P)" || return 1
	for d in "$@"; do
		d="$(cd "$d" 2>/dev/null && pwd -P)" || continue
		rel="${d#"$topp"/}"
		[[ "$rel" != "$d" && -n "$rel" ]] || continue
		hdh_excl+=(":(exclude,top,literal)${rel}")
	done
	idx="$(mktemp "${TMPDIR:-/tmp}/harness-index.XXXXXX" 2>/dev/null)" || return 1
	# HEAD's submodules (mode 160000 gitlinks): left out, as --ignore-submodules.
	git -C "$top" ls-tree -r -z --full-tree HEAD > "$idx" 2>/dev/null || { rm -f "$idx"; return 1; }
	while IFS= read -r -d '' ent; do
		[[ "$ent" != 160000\ * ]] || hdh_spec+=(":(exclude,top,literal)${ent#*$'\t'}")
	done < "$idx"
	rm -f "$idx"
	tree="$(
		export GIT_INDEX_FILE="$idx" GIT_ATTR_NOSYSTEM=1
		git -C "$top" read-tree HEAD 2>/dev/null || exit 1
		{
			git -C "$top" -c core.quotePath=true ls-files -z --cached -- "${hdh_spec[@]}" || exit 1
			git -C "$top" -c core.quotePath=true ls-files -z --others --exclude-standard -- "${hdh_spec[@]}" \
				${hdh_excl[@]+"${hdh_excl[@]}"} || exit 1
		} > "${idx}.paths" 2>/dev/null
		git -C "$top" -c core.autocrlf=false -c core.safecrlf=false -c core.fileMode=true -c core.attributesFile=/dev/null \
			update-index -z --add --remove --info-only --stdin < "${idx}.paths" 2>/dev/null || exit 1
		git -C "$top" write-tree --missing-ok 2>/dev/null
	)" || tree=""
	rm -f "$idx" "${idx}.paths"
	[[ "$tree" =~ ^[0-9a-f]{40,64}$ ]] || return 1
	# A clean harness: HEAD's own tree.
	[[ "$tree" != "$htree" ]] || return 0
	printf '%s\n' "${tree:0:8}"
}

# report_harness_sha [--exclude <dir>]...: the harness a report itself runs, which every
# report prints in every format as REPORT_HARNESS_SHA next to the HARNESS_SHA its inputs
# recorded: a report re-generated later, or from another checkout, can count rows by other
# rules than the harness that measured them. A report passes the dirs it reads (its inputs,
# or their results dir) as --exclude, so results inside the checkout do not read dirty;
# under a sweep, the sweep's results dir is left out too (HARNESS_SHA_EXCLUDE).
# shellcheck disable=SC2329
report_harness_sha() {
	harness_sha "$@"
}

# --- controlplane cell attempts and states ---

# CP_CELL_AWK: awk functions that read a legacy controlplane cell from the rows of its
# latest attempt (controlplane_latest_attempts), so 003 (which cells a --resume skips or
# runs again, the cell count) and 004 (its data warnings and NOT_RUN count) decide by one
# rule (PL41):
#   cp_header()          call at the TSV header line: finds traffic_config and window_kind.
#   cp_key()             the current row's cell key: columns 3-7, traffic_config and
#                        window_kind (none and deploy when absent), joined by SUBSEP.
#   cp_cell_row(k, st)   feed it each data row of cell k in file order (st: the status-row
#                        regex, 003's CELL_STATUS_RE); returns 1 for a status row.
#   cp_comment()         call it at each comment (#) line: reads the preamble's first
#                        ISTIOD_REPLICAS_BY_CONTEXT (cp_rep[member]) and marks the cell
#                        written last before a "# RESUMED_AT=" line (where a run ended).
#   cp_end()             call it in END, before cp_cell_state: marks the cell written last.
#   cp_cell_state(k)     "" when the cell is done: its last row is a measurement row, and
#                        the measurement rows since its last status row name as many
#                        distinct members as its mesh_size; the status of its last row
#                        when that is a status row; else INCOMPLETE: the run was cut short
#                        while 002 wrote the cell's member rows (cp_nm[k] of its cp_ms[k]
#                        members have one), or, for the cell written last before a run
#                        ended (the end of the TSV, or a "# RESUMED_AT=" line), a member
#                        has fewer rows than its istiod replicas (a row per replica: the
#                        smaller of its ISTIOD_REPLICAS_BY_CONTEXT entry and its most
#                        valid rows in another cell, or the one of them that is known: an
#                        HPA or a rollout changes the replicas during a sweep, so the
#                        two must agree; a member with a degraded row, istiod_restarted
#                        unknown, is not checked) and cp_why[k] says which: a TSV an older
#                        harness wrote row by row can be cut between replicas. Any key
#                        works (a caller may prefix the file).
#   cp_why[k]            set by cp_cell_state for that replica case: "<member> has rows of
#                        <n> of its <r> istiod replicas"; empty otherwise.
#   cp_valid[k]          set when the cell has a valid row (istiod_restarted 0).
#   cp_after[k]          set when a measurement row follows a status row of the cell: two
#                        attempts with no recorded boundary between them, so they pool.
#   cp_plan_load(f, tsv) the cells planned-cells.txt <f> lists into cp_plan[k] (its PLAN
#                        number), in order cp_plan_order[1..n]; returns n, or -1 when <f>
#                        cannot be read. A plan names its TSV ("# TSV=controlplane-<RUN_ID>.tsv",
#                        cp_plan_tsv): when that is not <tsv> (a base name) it loads nothing
#                        and returns 0 (a plan an older harness wrote, without the key,
#                        applies to every TSV beside it).
# shellcheck disable=SC2016,SC2034  # awk source, read by the scripts that source this file
CP_CELL_AWK='
function cp_header(    i) { cp_tcol = 0; cp_wcol = 0; for (i = 1; i <= NF; i++) { if ($i == "traffic_config") cp_tcol = i; if ($i == "window_kind") cp_wcol = i } }
function cp_key() { return $3 SUBSEP $4 SUBSEP $5 SUBSEP $6 SUBSEP $7 SUBSEP ((cp_tcol && NF >= cp_tcol) ? $cp_tcol : "none") SUBSEP ((cp_wcol && NF >= cp_wcol) ? $cp_wcol : "deploy") }
function cp_comment(    n, p, i, e) {
	if (!cp_repread && index($0, "# ISTIOD_REPLICAS_BY_CONTEXT=") == 1) {
		cp_repread = 1
		n = split(substr($0, 30), p, ",")
		for (i = 1; i <= n; i++) { e = p[i]; gsub(/^ +| +$/, "", e); if (match(e, /=[0-9]+$/)) cp_rep[substr(e, 1, RSTART - 1)] = substr(e, RSTART + 1) + 0 }
	}
	if (index($0, "# RESUMED_AT=") == 1 && cp_lastk != "") cp_tail[cp_lastk] = 1
}
function cp_end() { if (cp_lastk != "") cp_tail[cp_lastk] = 1 }
function cp_cell_row(k, st,    mk, ep) {
	cp_ms[k] = $3 + 0
	cp_lastk = k
	if ($2 ~ st) { cp_last[k] = $2; cp_ep[k]++; cp_nm[k] = 0; cp_ml[k] = ""; return 1 }
	if (cp_last[k] != "") cp_after[k] = 1
	cp_last[k] = ""
	if ($31 == "0") cp_valid[k] = 1
	ep = cp_ep[k] + 0
	mk = k SUBSEP ep SUBSEP $2
	if (!(mk in cp_mem)) { cp_mem[mk] = 1; cp_nm[k]++; cp_ml[k] = cp_ml[k] "\t" $2 }
	if ($31 == "unknown") cp_dg[mk] = 1
	if (!(($2, k) in cp_mx)) { cp_mk[$2, ++cp_mn[$2]] = k; cp_mx[$2, k] = 0 }
	cp_mr[mk]++
	if ($31 == "0" && ++cp_mc[mk] > cp_mx[$2, k]) cp_mx[$2, k] = cp_mc[mk]
	return 0
}
# cp_mxo(m, k): the most valid rows (istiod_restarted 0) member m has in an attempt of a cell
# other than k (0: none).
function cp_mxo(m, k,    i, o, x) {
	x = 0
	for (i = 1; i <= cp_mn[m] + 0; i++) { o = cp_mk[m, i]; if (o != k && cp_mx[m, o] > x) x = cp_mx[m, o] }
	return x
}
function cp_cell_state(k,    n, ml, i, m, mk, ex) {
	cp_why[k] = ""
	if (cp_last[k] != "") return cp_last[k]
	if (cp_nm[k] + 0 < cp_ms[k] + 0) return "INCOMPLETE"
	if (!(k in cp_tail)) return ""
	n = split(substr(cp_ml[k], 2), ml, "\t")
	for (i = 1; i <= n; i++) {
		m = ml[i]
		mk = k SUBSEP (cp_ep[k] + 0) SUBSEP m
		if (mk in cp_dg) continue
		# When both are known, both must expect more rows: an HPA or a rollout changes the
		# replicas during a sweep, so neither alone is proof.
		ex = cp_mxo(m, k)
		if ((m in cp_rep) && cp_rep[m] > 0 && (ex == 0 || cp_rep[m] < ex)) ex = cp_rep[m]
		if (cp_mr[mk] + 0 < ex) { cp_why[k] = m " has rows of " (cp_mr[mk] + 0) " of its " ex " istiod replicas"; return "INCOMPLETE" }
	}
	return ""
}
function cp_plan_load(f, tsv,    r, line, p, n, fl, k) {
	p = 0; n = 0; cp_plan_tsv = ""
	while ((r = (getline line < f)) > 0) {
		if (line ~ /^# PLAN=[0-9]+ /) { p = substr(line, 8); sub(/ .*/, "", p); continue }
		if (index(line, "# TSV=") == 1) { cp_plan_tsv = substr(line, 7); continue }
		if (line ~ /^#/ || line ~ /^mesh_size\t/ || line == "") continue
		if (split(line, fl, "\t") < 7) continue
		k = fl[1] SUBSEP fl[2] SUBSEP fl[3] SUBSEP fl[4] SUBSEP fl[5] SUBSEP fl[6] SUBSEP fl[7]
		if (!(k in cp_plan)) { cp_plan[k] = p; cp_plan_order[++n] = k }
	}
	close(f)
	if (r < 0) return -1
	if (tsv != "" && cp_plan_tsv != "" && cp_plan_tsv != tsv) { split("", cp_plan); split("", cp_plan_order); return 0 }
	return n
}
'

# controlplane_latest_attempts <tsv> <resumes_txt> <out_tsv>: copy a controlplane TSV to
# <out_tsv> without the rows of each cell's earlier attempts, so a report, the cell count
# and the scale envelope never pool two attempts of one cell (PL15). A cell is keyed as 003
# keys it (CP_CELL_AWK cp_key). An attempt is a run of the sweep: the first run, then each
# --resume. Where a --resume starts is read from both places 003 records it, so a TSV copied
# without its resumes.txt still keeps its attempts apart: the TSV's own `# RESUMED_AT=<time>
# TSV_LINES=<n> HARNESS_SHA=<sha>` line (the resume's first line in it), and resumes.txt's
# TSV_LINES column (the TSV's line count when that resume started) or, in a resumes.txt a
# harness without that column wrote, its RESUMED_AT (from the first row of that time on).
# A resumes.txt row whose TSV column names another file is not this TSV's (a resumes.txt
# applies only to its TSV); a row without the column applies. Both records of one start
# count once. A cell's latest attempt is the last run that wrote a row of it; its rows from
# earlier runs are left out. Comment, header and short lines (fewer than 40 columns) are
# copied as they are. A TSV without a recorded resume (a first run, or a growth series,
# which is never resumed) is copied whole. Prints "<rows left out><TAB><cells they belong
# to>"; returns non-zero, printing nothing, when awk fails (resumes.txt unreadable).
# shellcheck disable=SC2329
controlplane_latest_attempts() {
	local tsv="$1" res="${2:-}" out="$3"
	[[ -n "$res" && -f "$res" ]] || res=/dev/null
	: > "$out" || return 1
	awk -F'\t' -v res="$res" -v out="$out" -v tname="${tsv##*/}" "${CP_CELL_AWK}"'
		function addb(p) { if (!(p in bp)) { bp[p] = 1; nb++; bs[nb] = p } }
		# seg(x): the attempt line x belongs to (0: the first run): the starts before it.
		function seg(x,    s, i) { s = 0; for (i = 1; i <= nb; i++) if (x > bs[i]) s++; return s }
		BEGIN {
			while ((r = (getline line < res)) > 0) {
				n = split(line, f, "\t")
				if (f[1] == "RESUMED_AT") { lc = 0; tc = 0; for (i = 1; i <= n; i++) { if (f[i] == "TSV_LINES") lc = i; if (f[i] == "TSV") tc = i }; continue }
				if (n < 2 || f[1] == "") continue
				if (tc && n >= tc && f[tc] != "" && f[tc] != tname) continue
				if (lc && n >= lc && f[lc] ~ /^[0-9]+$/) { addb(f[lc] + 0); continue }
				nt++
				bt[nt] = substr(f[1], 1, 19)
			}
			if (r < 0) { print "cannot read " res > "/dev/stderr"; bad = 1; exit 2 }
			close(res)
		}
		FNR == 1 {
			pass++
			# Every start is known after the first pass: each row of it to its attempt.
			if (pass == 2) for (i = 1; i <= nr; i++) { s = seg(rf[i]); if (!(rk[i] in top) || s > top[rk[i]]) top[rk[i]] = s }
		}
		pass == 1 && /^# RESUMED_AT=/ { addb(FNR - 1); next }
		/^timestamp\t/ { cp_header() }
		{ data = !(/^#/ || /^timestamp\t/ || NF < 40) }
		pass == 1 {
			if (data) {
				for (i = 1; i <= nt; i++) if (!(i in tdone) && substr($1, 1, 19) >= bt[i]) { tdone[i] = 1; addb(FNR - 1) }
				nr++
				rf[nr] = FNR
				rk[nr] = cp_key()
			}
			next
		}
		data { k = cp_key(); if (seg(FNR) < top[k]) { drop++; if (!(k in dk)) { dk[k] = 1; ndk++ }; next } }
		{ print > out }
		END { if (bad) exit 2; close(out); printf "%d\t%d\n", drop, ndk }' "$tsv" "$tsv"
}

# controlplane_attempts <tsv> <resumes_txt>: the runs that wrote a controlplane TSV, one line
# each, in the order they started:
#   <run>\t<HARNESS_SHA>\t<KUBE_VERSIONS>\t<rows>\t<ISTIO_NOTREADY>\t<ISTIO_PROXY_VERSIONS>\t<ISTIO_GENERATIONS>\t<at>
# <run> is "first run" (its values from the TSV preamble; ISTIO_NOTREADY is its
# ISTIO_NOTREADY_AT_START) or "--resume at <at>": from its resumes.txt line (a line whose
# TSV column names another file is not this TSV's), else from the TSV's own "# RESUMED_AT="
# line (which records HARNESS_SHA and, from this harness on, KUBE_VERSIONS); a value
# neither records reads unknown. Both records of one start (the same time) are one run.
# <rows> counts the data rows (measurements and status rows) from its start up to the
# next run's, its starts read as controlplane_latest_attempts reads them (TSV_LINES, the
# "# RESUMED_AT=" line, or in an older resumes.txt the first row of its time on): 0 for a
# run that added none (a --resume of a finished sweep, or one that stopped before its
# first cell), so a report can leave it out of the provenance of the rows (PL2, PL15).
# A run that never wrote the TSV's preamble (it died first; a --resume wrote it) still
# reads "first run", with the preamble's values and 0 rows. Returns non-zero when awk fails.
# shellcheck disable=SC2329
controlplane_attempts() {
	local tsv="$1" res="${2:-}"
	[[ -n "$res" && -f "$res" ]] || res=/dev/null
	awk -F'\t' -v res="$res" -v tname="${tsv##*/}" '
		function g(c) { return ((c in col) && n >= col[c] && f[col[c]] != "") ? f[col[c]] : "unknown" }
		function pk(k,    p) { p = "# " k "="; if (!(k in pre) && index($0, p) == 1) pre[k] = substr($0, length(p) + 1) }
		function pv(k) { return ((k in pre) && pre[k] != "") ? pre[k] : "unknown" }
		BEGIN {
			while ((r = (getline line < res)) > 0) {
				n = split(line, f, "\t")
				if (f[1] == "RESUMED_AT") { split("", col); for (i = 1; i <= n; i++) col[f[i]] = i; continue }
				if (n < 2 || f[1] == "") continue
				if (("TSV" in col) && n >= col["TSV"] && f[col["TSV"]] != "" && f[col["TSV"]] != tname) continue
				na++
				at[na] = f[1]; h[na] = g("HARNESS_SHA"); kv[na] = g("KUBE_VERSIONS"); nr[na] = g("ISTIO_NOTREADY_AT_RESUME")
				pxv[na] = g("ISTIO_PROXY_VERSIONS"); gen[na] = g("ISTIO_GENERATIONS")
				pos[na] = (g("TSV_LINES") ~ /^[0-9]+$/) ? g("TSV_LINES") + 0 : -1
			}
			if (r < 0) { print "cannot read " res > "/dev/stderr"; exit 2 }
			close(res)
		}
		/^timestamp\t/ { hdr = 1; next }
		/^#/ {
			if (!hdr) { pk("HARNESS_SHA"); pk("KUBE_VERSIONS"); pk("ISTIO_NOTREADY_AT_START"); pk("ISTIO_PROXY_VERSIONS"); pk("ISTIO_GENERATIONS") }
			if (index($0, "# RESUMED_AT=") != 1) next
			m = split($0, w, " "); t = ""; th = "unknown"; tk = "unknown"
			for (i = 1; i <= m; i++) { if (w[i] ~ /^RESUMED_AT=/) t = substr(w[i], 12); if (w[i] ~ /^HARNESS_SHA=./) th = substr(w[i], 13) }
			if ((p = index($0, " KUBE_VERSIONS=")) && substr($0, p + 15) != "") tk = substr($0, p + 15)
			if (t == "") next
			for (i = 1; i <= na; i++) if (at[i] == t && !(i in byline)) break
			if (i <= na) {
				byline[i] = 1; pos[i] = FNR - 1
				if (h[i] == "unknown") h[i] = th
				if (kv[i] == "unknown") kv[i] = tk
				next
			}
			na++; at[na] = t; h[na] = th; kv[na] = tk; nr[na] = "unknown"; pxv[na] = "unknown"; gen[na] = "unknown"; pos[na] = FNR - 1; byline[na] = 1
			next
		}
		NF >= 40 { nd++; dpos[nd] = FNR; dts[nd] = substr($1, 1, 19) }
		END {
			if (r < 0) exit 2
			last = NR
			# A start that only an older resumes.txt records (its time): before the first row
			# of that time on; none (it added no row): the end of the TSV.
			for (i = 1; i <= na; i++) if (pos[i] < 0) {
				pos[i] = last
				for (j = 1; j <= nd; j++) if (dts[j] >= substr(at[i], 1, 19)) { pos[i] = dpos[j] - 1; break }
			}
			# Run 0, the first: position 0. Then the resumes by position (a stable sort: a
			# tie keeps their order, and the later one gets the rows).
			o[0] = 0; pos[0] = 0
			for (i = 1; i <= na; i++) {
				j = i
				while (j > 1 && pos[o[j - 1]] > pos[i]) { o[j] = o[j - 1]; j-- }
				o[j] = i
			}
			for (a = 0; a <= na; a++) {
				lo = pos[o[a]]; hi = (a < na) ? pos[o[a + 1]] : last
				c = 0
				for (j = 1; j <= nd; j++) if (dpos[j] > lo && dpos[j] <= hi) c++
				if (a == 0) printf "first run\t%s\t%s\t%d\t%s\t%s\t%s\t\n", pv("HARNESS_SHA"), pv("KUBE_VERSIONS"), c, pv("ISTIO_NOTREADY_AT_START"), pv("ISTIO_PROXY_VERSIONS"), pv("ISTIO_GENERATIONS")
				else { i = o[a]; printf "--resume at %s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\n", at[i], h[i], kv[i], c, nr[i], pxv[i], gen[i], at[i] }
			}
		}' "$tsv"
}

# controlplane_resume_cmd <sweep_dir> <contexts_csv> <axis_flags> [<config>]: the command
# that resumes a controlplane sweep, from the repo root:
#   ./tests/controlplane/003-run-sweep.sh --resume <sweep_dir> --contexts <csv> <axis_flags>[ --config <config>]
# <sweep_dir> and <config> are printed as given (a record shared with others passes
# "<sweep dir>", the console a quoted path); <axis_flags> as planned-cells.txt's "# PLAN="
# line (or planned_axis_flags in 003) names them.
# shellcheck disable=SC2329
controlplane_resume_cmd() {
	printf './tests/controlplane/003-run-sweep.sh --resume %s --contexts %s %s%s\n' "$1" "$2" "$3" "${4:+ --config $4}"
}

# --- markdown table cells ---

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

# --- YAML frontmatter values ---

# yaml_str [-v <var>] [-n] <value>: <value> as a YAML double-quoted scalar, for a report's
# frontmatter (PL19): each \ and " escaped, a tab, newline and carriage return as \t, \n
# and \r, any other control character as \xNN (\uNNNN above U+00FF), so a value from a
# hand-edited TSV, a context name or a reason keeps the frontmatter parseable and reads
# back as itself. With -n a plain decimal number (0, 12, 0.5, -3; no leading zero, which
# YAML 1.1 reads as octal) stays bare, a YAML number. Printed without a newline, or with
# -v stored in <var> (no subshell). A plain loop, no ${v//\\/...} (see md_cell).
# shellcheck disable=SC2329
yaml_str() {
	local _ys_var="" _ys_num=0
	if [[ "${1:-}" == -v ]]; then
		_ys_var="$2"
		shift 2
	fi
	if [[ "${1:-}" == -n && $# -gt 1 ]]; then
		_ys_num=1
		shift
	fi
	local _ys_s="${1-}" _ys_out='"' _ys_c _ys_x _ys_i
	if ((_ys_num)) && [[ "$_ys_s" =~ ^-?(0|[1-9][0-9]*)(\.[0-9]+)?$ ]]; then
		_ys_out="$_ys_s"
	elif [[ "$_ys_s" != *[\\\"[:cntrl:]]* ]]; then
		_ys_out="\"${_ys_s}\""
	else
		for ((_ys_i = 0; _ys_i < ${#_ys_s}; _ys_i++)); do
			_ys_c="${_ys_s:_ys_i:1}"
			case "$_ys_c" in
			"\\") _ys_out+="\\\\" ;;
			'"') _ys_out+='\"' ;;
			$'\t') _ys_out+='\t' ;;
			$'\n') _ys_out+='\n' ;;
			$'\r') _ys_out+='\r' ;;
			[[:cntrl:]])
				printf -v _ys_x '%d' "'${_ys_c}"
				if ((_ys_x <= 255)); then
					printf -v _ys_x '\\x%02x' "$_ys_x"
				else
					printf -v _ys_x '\\u%04x' "$_ys_x"
				fi
				_ys_out+="$_ys_x"
				;;
			*) _ys_out+="$_ys_c" ;;
			esac
		done
		_ys_out+='"'
	fi
	if [[ -n "$_ys_var" ]]; then
		printf -v "$_ys_var" '%s' "$_ys_out"
	else
		printf '%s' "$_ys_out"
	fi
}

# --- file size without a fork ---

# file_min_bytes <file> <n>: true when <file> is a readable regular file of at least <n>
# bytes. It forks nothing when it is (it runs once per scrape file): the read
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

#!/usr/bin/env bash
# Shared utility functions sourced by all test suites.
# Sourced, never executed.
#
# Consumers: churn, churn-dataplane, controlplane, dataplane, propagation, tuning, gateway-api
#
# Exposes:
#   die <msg>                         -> exit 1 with stderr message (and keep <msg> as the
#                                        stop reason sweep_outcome_on_exit records)
#   awk_untyped_ok <awk>              -> true when <awk> keeps an unset array element intact
#                                        after passing it to a function (gawk 5.3 does not);
#                                        sourcing runs awk as mawk, or stops, when awk fails it
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
#   run_timeout <duration> <cmd...>   -> cmd under timeout/gtimeout --foreground (TIMEOUT_CMD);
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
#   sweep_outcome_on_exit <rc> [--note|--info|--problem <msg>]...
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
#   controlplane_attempts <tsv> <resumes_txt>
#                                     -> the runs that wrote a controlplane TSV (the first
#                                        and each --resume), one line each, for its reports
#   controlplane_resume_cmd <sweep_dir> <contexts_csv> <axis_flags> [<config>]
#                                     -> the --resume command for that sweep dir
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
#                                        -dirty.<8hex> (the start of its content key) when
#                                        HARNESS_PATHS (tests config charts terraform)
#                                        differ from that commit
#   harness_content_key [--exclude <dir>]...
#                                     -> HARNESS_CONTENT_KEY: 12 hex naming the content of
#                                        HARNESS_PATHS alone (unknown outside a checkout)
#   harness_read <sha_var> <key_var> [--live] [--exclude <dir>]...
#                                     -> both from one git pass
#   sweep_settings_check              -> die on a bad SWEEP_STOP_GRACE_SEC,
#                                        HARNESS_SHA_CHECK_SEC or ISTIO_PROXY_READ_PARALLEL
#   harness_sha_for_sweep [<dir>]     -> a sweep's harness at its start (and its settings
#                                        checked); exports <dir> as HARNESS_SHA_EXCLUDE
#   harness_sha_check <step>          -> read it again before a step (HARNESS_SHA_CHECK_SEC);
#                                        a change is a problem in sweep_outcome
#   report_harness_sha [--exclude <dir>]...
#                                     -> the harness a report itself runs (REPORT_HARNESS_SHA)
#   md_cell [-v <var>] <value>        -> the value for a markdown table cell (each | as
#                                        \|, a newline as a space)
#   MD_CELL_AWK                       -> the same as an awk function md_cell(s)
#   JSON_STR_AWK                      -> awk function js(x): x as a quoted JSON string
#   yaml_str [-v <var>] [-n] <value>  -> the value as a YAML double-quoted scalar, escaped
#                                        (\ " and control characters), for frontmatter
#   file_min_bytes <file> <n>         -> true when <file> holds at least <n> bytes; forks
#                                        nothing when it does
#   file_sha256 <file>                -> the file's hex sha256, or unknown when no tool
#                                        (sha256sum, shasum) works
#   kv_value <key> <tokens>           -> the value of <key>=... among "k=v k=v" tokens, or
#                                        unknown
#   each_bounded <max> <fn> <tmp> <item>...
#                                     -> run <fn> on each item in the background, <max> at a
#                                        time (the platform record's PLATFORM_READ_PARALLEL)
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

# awk_untyped_ok <awk>: true when <awk> keeps an array element that holds no value yet intact
# after passing it to a function. gawk 5.3 (5.3.2 checked) does not: a later comparison of
# the element stops awk with "fixtype: expected Node_val: got Node_var", and a later number
# read of it returns garbage. The reports pass such elements (a count no row filled), so a
# run never uses that awk: when awk on PATH fails this check, tests/lib/awk-mawk (awk run as
# mawk) goes first on PATH if mawk passes it, else the run stops here.
awk_untyped_ok() {
	"$1" 'function f(v) { return v ~ /x/ } BEGIN { f(a[1]); if (a[1] == "" && a[1] + 0 == 0) exit 0; exit 1 }' \
		</dev/null >/dev/null 2>&1
}
if ! awk_untyped_ok awk; then
	if command -v mawk >/dev/null 2>&1 && awk_untyped_ok mawk; then
		PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/awk-mawk:${PATH}"
		export PATH
	else
		die "awk on PATH ($(awk --version 2>/dev/null | head -n 1 || true)) corrupts an array element passed to a function before it holds a value (a gawk 5.3 bug), and the reports do that, so its figures could be wrong. Install mawk (dnf, apt or brew install mawk); the harness then runs awk as mawk on its own."
	fi
fi

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
# any cluster change; <what> names the flag or variable the operator fixes. The refusal
# repeats the list, or says how many items it has when it is over 200 characters (a
# fleet's runs to thousands).
# shellcheck disable=SC2329
split_contexts() {
	local _sc_csv="$1" _sc_what="$3" _sc_src="${4:-}" _sc_x _sc_shown
	split_csv "$_sc_csv" "$2"
	local -n _sc_out="$2"
	local -A _sc_seen=()
	_sc_shown="$_sc_csv"
	((${#_sc_shown} <= 200)) || _sc_shown="${#_sc_out[@]} items"
	for _sc_x in ${_sc_out[@]+"${_sc_out[@]}"}; do
		[[ -z "${_sc_seen[$_sc_x]+x}" ]] \
			|| die "${_sc_what} lists ${_sc_x} twice (${_sc_shown}): list each mesh member once"
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

# tsv_end_line <file>: ends <file>'s last line with a newline when it has none (a write cut
# short: a full disk, a run killed while it appended), so the next append starts a line of
# its own instead of merging onto the cut one. Does nothing for a missing or empty file;
# returns non-zero when it cannot write (the caller dies with what to fix). The cut line
# then has fewer columns than the header, unless the cut fell inside its last field: it then
# keeps the header's column count, and only the status row a run that goes on writes after
# it marks the cell failed (after a hard kill, a --resume reads it as a whole row, its last
# field cut).
# shellcheck disable=SC2329
tsv_end_line() {
	[[ ! -s "$1" || -z "$(tail -c 1 "$1" 2>/dev/null)" ]] || printf '\n' >> "$1"
}

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

# run_timeout <duration> <cmd...>: run cmd bounded by <duration> (timeout syntax: 30s), as
# `timeout --foreground`: timeout then stays in the caller's process group (without it,
# timeout moves to a group of its own), so a Ctrl-C reaches cmd and a sweep that stops its
# step finds them in the step's tree. On expiry only cmd gets the signal, not processes it
# started: pass a command that starts none (the callers run kubectl exec). Exit 127 with a
# message on stderr when no timeout command exists.
# shellcheck disable=SC2329
run_timeout() {
	local t="${TIMEOUT_CMD:-}"
	[[ -n "$t" ]] || t="$(timeout_cmd)" || {
		echo "error: neither 'timeout' nor 'gtimeout' (GNU coreutils) is on PATH; on macOS: brew install coreutils" >&2
		return 127
	}
	"$t" --foreground "$@"
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
# and HARNESS_CONTENT_KEY (as sweep_outcome --record writes them), EXIT=unfinished,
# STARTED_AT (UTC), UNIT, RESUMED_AT (a controlplane --resume: its start, UTC with Z, as
# every time it records) and NEXT (what to do if it died; no local path). sweep_outcome
# --record replaces it at the end, so a sweep that dies keeps it, and every report says
# the sweep has not finished (sweep_outcome_recorded) instead of nothing. Creates <dir> when it does not exist yet (a
# sweep may create it only with its first row). Warns, never dies, when it cannot write.
# It also arms sweep_outcome_on_exit for this shell (the record, its run and unit),
# and traps HUP, INT and TERM (sweep_trap_signals), so the record can tell an interrupt
# from a stop. The sweep installs its EXIT trap (which calls sweep_outcome_on_exit) first.
# In the shell that ran harness_sha_for_sweep it creates the temp file the steps add their
# own harness reads to from now on (HARNESS_SWEEP_LOG, exported: harness_read), which the
# end check reads and removes (_harness_sha_sweep_end).
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
	local sos_v="${HARNESS_SHA:-}" sos_k="${HARNESS_CONTENT_KEY:-}"
	[[ -n "$sos_v" ]] || harness_read sos_v sos_k
	{
		echo "# Sweep outcome (tests/lib/common.sh sweep_outcome_start): this sweep has not finished; sweep_outcome replaces this record at its end"
		echo "# DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "RUN_ID=${rid:-unknown}"
		echo "HARNESS_SHA=${sos_v}"
		echo "HARNESS_CONTENT_KEY=${sos_k:-unknown}"
		echo "EXIT=unfinished"
		echo "STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "UNIT=${unit}"
		[[ -z "$resumed" ]] || echo "RESUMED_AT=${resumed}"
		[[ -z "$next" ]] || echo "NEXT=${next}"
	} 2>/dev/null > "${dir}/sweep-outcome.txt" \
		|| echo "warning: could not write ${dir}/sweep-outcome.txt (the sweep's not-finished record)" >&2
	_SWEEP_OUTCOME_ARMED_DIR="$dir" _SWEEP_OUTCOME_ARMED_RID="${rid:-unknown}" _SWEEP_OUTCOME_ARMED_UNIT="$unit"
	_SWEEP_OUTCOME_ARMED_PID="${BASHPID:-$$}"
	if [[ -n "${_HARNESS_SHA_START:-}" && "${_HARNESS_SHA_PID:-}" == "${BASHPID:-$$}" && -z "${HARNESS_SWEEP_LOG:-}" ]]; then
		if HARNESS_SWEEP_LOG="$(mktemp 2>/dev/null)"; then
			export HARNESS_SWEEP_LOG
		else
			HARNESS_SWEEP_LOG="" _HARNESS_STEP_LOST="the sweep could not create the temp file they are added to (HARNESS_SWEEP_LOG) at its start"
			echo "warning: could not create a temp file for the steps' harness reads: a harness change that only a step reads is not in the sweep's outcome" >&2
		fi
	fi
	sweep_trap_signals
	return 0
}

# sweep_lock [--release-on-exit] <dir>: one run per sweep dir. Takes <dir>/.sweep.lock (it
# holds this shell's PID); while the lock names a PID that is still alive, dies before
# anything in <dir> changes, naming that PID and how to clear a stale lock, so a --resume
# cannot run beside the run it resumes (two runs would append to one TSV and overwrite each
# other's outcome). A PID that `kill -0` may not signal (another user's process) is alive
# too (`ps -p`); an empty lock is read again for about 2s first (_sweep_lock_pid: a run
# that has just created it writes its PID next). A lock whose PID is gone (that run died)
# is taken over under <dir>/.sweep.lock.taking (a mkdir mutex): the lock is read again under
# it and written only while its PID is still gone, so of two runs that find one stale lock
# at once, one takes it and the other is refused; a mutex left by a run that died while
# taking over is never removed for you (the refusal names it). sweep_outcome_start takes the
# lock, so every sweep does, after it has set its EXIT trap (sweep-stop.bats checks the order).
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
	pid="$(_sweep_lock_pid "$f")"
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
	pid="$(_sweep_lock_pid "$f")"
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

# _sweep_lock_pid <lock>: the PID in <lock>, for sweep_lock. A lock that exists but is still
# empty may be one another run has just created and not written yet (sweep_lock creates the
# file, then writes its PID): it is read again for about 2s before it counts as empty (a
# run that died between the two). Prints nothing for an empty or missing lock.
# shellcheck disable=SC2329
_sweep_lock_pid() {
	local p i
	for ((i = 0; i < 20; i++)); do
		p="$(head -n 1 "$1" 2>/dev/null)" || p=""
		[[ -z "$p" && -f "$1" ]] || break
		sleep 0.1
	done
	printf '%s' "$p"
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
# `kill -0`, or, when that fails (EPERM: another user's process), /proc/<pid> (Linux, also
# without ps: _sweep_ps_table's _SWEEP_PROC) or `ps -p`.
# shellcheck disable=SC2329
_sweep_pid_alive() {
	[[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || return 1
	kill -0 "$1" 2>/dev/null && return 0
	[[ ! -d "${_SWEEP_PROC:-/proc}/$1" ]] || return 0
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
# The sweep's own commands between steps (a settle wait, its Istio version and proxy reads,
# the end-of-sweep recheck) are foreground commands: they finish first, each bounded. It
# also checks that a step's tree can be read (_sweep_ps_check: a warning, never a stop;
# once per sweep, which sweep_settings_check runs first, also on a --dry-run).
# shellcheck disable=SC2329
sweep_trap_signals() {
	trap '_sweep_on_signal HUP' HUP
	trap '_sweep_on_signal INT' INT
	trap '_sweep_on_signal TERM' TERM
	_sweep_ps_check
}

# _sweep_ps_table: every process, one "<pid> <ppid> <pgid> <state> <key>" line each, <key>
# "<pid>@<start time>" (a PID the system gives a new process later gets another key): from
# `ps -A -o pid=,ppid=,pgid=,stat=,lstart=` (procps on Linux, the BSD ps of macOS), else,
# where that does not work (no ps: ubi-minimal, distroless; busybox ps has no lstart), from
# /proc/<pid>/stat (Linux: state, ppid and pgrp are its fields 3-5; the start, in clock
# ticks since boot, field 22). Prints nothing when neither works. _SWEEP_PROC: the proc
# root, /proc (a bats test points it at a missing dir).
# shellcheck disable=SC2329
_sweep_ps_table() {
	local spt_out spt_root="${_SWEEP_PROC:-/proc}"
	local -a spt_f
	if spt_out="$(LC_ALL=C ps -A -o pid=,ppid=,pgid=,stat=,lstart= 2>/dev/null \
		| awk 'NF >= 9 { print $1, $2, $3, $4, $1 "@" $5 "-" $6 "-" $7 "-" $8 "-" $9 }')" && [[ -n "$spt_out" ]]; then
		printf '%s\n' "$spt_out"
		return 0
	fi
	spt_f=("$spt_root"/[0-9]*/stat)
	[[ "${spt_f[0]}" != "${spt_root}/[0-9]*/stat" ]] || return 0
	# One read per file (a process that ended since the glob is skipped). The command name,
	# field 2 in parentheses, may hold spaces and ")": cut through its last ") ".
	awk 'BEGIN {
		for (i = 1; i < ARGC; i++) {
			if ((getline l < ARGV[i]) > 0) {
				p = l
				sub(/ .*/, "", p)
				sub(/.*\) /, "", l)
				if (split(l, a, " ") >= 20) print p, a[2], a[3], a[1], p "@" a[20]
			}
			close(ARGV[i])
		}
	}' "${spt_f[@]}"
}

# _sweep_ps_works: true when _sweep_ps_table lists this shell (ps, or /proc on Linux), so
# _sweep_step_stop can walk a step's tree.
# shellcheck disable=SC2329
_sweep_ps_works() {
	_sweep_ps_table | awk -v me="$$" '$1 == me { f = 1 } END { exit !f }'
}

# _sweep_ps_check: once per sweep (sweep_settings_check, sweep_trap_signals), a warning
# when a step's tree cannot be read (_sweep_ps_works): a stop then signals only the step's
# own process (_sweep_step_stop), and the processes under it may outlive the sweep.
# shellcheck disable=SC2329
_sweep_ps_check() {
	[[ -z "${_SWEEP_PS_CHECKED:-}" ]] || return 0
	_SWEEP_PS_CHECKED=1
	_sweep_ps_works && return 0
	echo "warning: neither 'ps -A -o pid=,ppid=,pgid=,stat=,lstart=' (no ps, or busybox ps without lstart) nor /proc/<pid>/stat works here: a signal that stops this sweep reaches only its running step's own process, not the processes under it, which may run on after the sweep ends. Run the sweep where /proc is mounted (Linux), or install a ps that lists start times (procps)." >&2 || true
}

# _sweep_kill_hint: what to do after SIGKILL cut a step's cleanup short: SWEEP_CLEANUP_CMD,
# the suite's cleanup command a sweep sets before its first step (console only), else a
# generic hint.
# shellcheck disable=SC2329
_sweep_kill_hint() {
	if [[ -n "${SWEEP_CLEANUP_CMD:-}" ]]; then
		printf 'their own cleanup did not run; clean up with: %s' "$SWEEP_CLEANUP_CMD"
	else
		printf "their own cleanup did not run: run the suite's cleanup script before the next run"
	fi
}

# shellcheck disable=SC2329  # invoked by the traps sweep_trap_signals sets
_sweep_on_signal() {
	_SWEEP_SIGNAL="$1"
	trap - "$1"
	[[ -z "${_SWEEP_STEP_PID:-}" ]] || _sweep_step_stop "$1"
	kill -s "$1" "$$"
}

# _sweep_tree_read <root>...: one read of every process (_sweep_ps_table: ps -A, or
# /proc): each live or zombie process that is a <root> or under one, as
# "<pid> <pgid> <state> <key>" lines. A <root> is a PID, which matches only a child of the
# shell that ran sweep_step (the step), or a key, "<pid>@<start time>", which matches only
# the process that started then: a PID the system gave to a new process after the old one
# ended is never taken for it.
# shellcheck disable=SC2329
_sweep_tree_read() {
	(($#)) || return 0
	_sweep_ps_table | awk -v roots="$*" -v me="${_SWEEP_STEP_OWNER:-$$}" '
		BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) want[r[i]] = 1 }
		NF >= 5 {
			k = $5
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
# gets SIGKILL, so the sweep never hangs on its step. The tree is read with `ps -A` (Linux,
# macOS), or from /proc where ps does not work (_sweep_ps_table): a process group
# (`set -m`) would take the step out of the terminal's foreground, so Ctrl-C would no
# longer reach it, and would miss a command in a group of its own. SIGINT and SIGHUP from
# the terminal (Ctrl-C, a closed terminal) already reached the processes in the terminal's
# foreground group (the sweep's, so the step's too): those are not sent the signal twice
# (that would cut their cleanup short), only the others (in a group of their own). So a
# SIGINT or SIGHUP sent to the sweep's PID alone (a supervisor's `kill -INT <pid>`)
# reaches every process of the tree only when the sweep is not in a terminal's foreground
# (nohup, a service, a CI job); in one (a terminal, a tmux pane), the foreground group's
# processes are skipped and get SIGKILL after the grace, with no cleanup: stop such a
# sweep from elsewhere with SIGTERM. The console line says how many it signalled and
# skipped. A signal sent to the whole group (Ctrl-C, a `timeout` around the sweep,
# `kill -<sig> -<pgid>`) reaches the step itself too, which may end before its tree is
# read: its children got the signal from the group as well (run_timeout keeps its
# commands in the group: `timeout --foreground`). Where neither ps nor /proc works
# (_sweep_ps_works), only the step's own process is signalled (SIGINT and SIGHUP only when
# the sweep's stdin is no terminal: in one, they are taken for a Ctrl-C's or a closed
# terminal's, which reached the step), and SIGKILL'd after the grace by a watchdog (one at
# a time: a second, different signal stops the first's). The tree's keys stay in
# _SWEEP_STEP_TREE while it waits, so sweep_step_kill (the EXIT trap, after a second
# signal ended this wait) finds the rest.
# shellcheck disable=SC2329
_sweep_step_stop() {
	local sig="$1" pid="${_SWEEP_STEP_PID:-}" grace="${SWEEP_STOP_GRACE_SEC:-30}" tpg="" deadline p g s k n=0
	local nsig=0 nskip=0 i
	local -a sss_tree=() sss_live=()
	[[ -n "$pid" && "${_SWEEP_STEP_OWNER:-}" == "${BASHPID:-$$}" ]] || return 0
	is_nonneg_int "$grace" || grace=30
	if ! _sweep_ps_works; then
		if [[ "$sig" == TERM || ! -t 0 ]]; then
			echo "Stopping the running step (${_SWEEP_STEP_NAME:-PID ${pid}}): neither ps nor /proc works here (see the warning at the sweep's start), so only its own process gets SIG${sig}, not the processes under it; it gets SIGKILL if it still runs ${grace}s later (SWEEP_STOP_GRACE_SEC)." >&2 || true
			kill -s "$sig" "$pid" 2>/dev/null || true
		else
			echo "Stopping the running step (${_SWEEP_STEP_NAME:-PID ${pid}}): neither ps nor /proc works here (see the warning at the sweep's start), and the sweep's stdin is a terminal, so SIG${sig} is not sent again: a Ctrl-C or a closed terminal reached it (a 'kill -${sig} <pid>' from elsewhere reaches nothing: stop a sweep from elsewhere with SIGTERM). It gets SIGKILL if it still runs ${grace}s later (SWEEP_STOP_GRACE_SEC)." >&2 || true
		fi
		# A watchdog (_SWEEP_STEP_WD) bounds the wait, which ends as soon as the step does,
		# and is stopped then (so a PID the system gives another process later is never
		# signalled); sweep_step_kill stops it too, and so does a second, different signal's
		# stop here before it starts its own. Once it sends SIGKILL it ignores SIGTERM, so its
		# warning is never cut short by that stop.
		if [[ -n "${_SWEEP_STEP_WD:-}" ]]; then
			kill "$_SWEEP_STEP_WD" 2>/dev/null || true
			wait "$_SWEEP_STEP_WD" 2>/dev/null || true
		fi
		(
			for ((i = 0; i < grace * 5; i++)); do sleep 0.2; done
			trap '' TERM
			if kill -s KILL "$pid" 2>/dev/null; then
				echo "warning: the step still ran ${grace}s after SIG${sig}: sent SIGKILL ($(_sweep_kill_hint))" >&2 || true
			fi
		) &
		_SWEEP_STEP_WD=$!
		_sweep_step_reap "$pid"
		kill "$_SWEEP_STEP_WD" 2>/dev/null || true
		wait "$_SWEEP_STEP_WD" 2>/dev/null || true
		_SWEEP_STEP_PID="" _SWEEP_STEP_TREE="" _SWEEP_STEP_WD=""
		return 0
	fi
	if [[ "$sig" != TERM ]]; then
		tpg="$(LC_ALL=C ps -o tpgid= -p "$$" 2>/dev/null)" || tpg=""
		tpg="${tpg//[[:space:]]/}"
		# No such ps (the tree came from /proc): field 8 of /proc/<pid>/stat.
		if ! [[ "$tpg" =~ ^-?[0-9]+$ ]]; then
			tpg="$(awk '{ sub(/.*\) /, ""); print $6 }' "${_SWEEP_PROC:-/proc}/$$/stat" 2>/dev/null)" || tpg=""
		fi
		[[ "$tpg" =~ ^[1-9][0-9]*$ ]] || tpg=""
	fi
	_sweep_tree_freeze sss_tree "$pid"
	_SWEEP_STEP_TREE="${sss_tree[*]-}"
	while read -r p g s k; do
		[[ -n "$k" && "$s" != Z* ]] || continue
		if [[ -n "$tpg" && "$g" == "$tpg" ]]; then
			nskip=$((nskip + 1))
		else
			kill -s "$sig" "$p" 2>/dev/null || true
			nsig=$((nsig + 1))
		fi
	done < <(_sweep_tree_read ${sss_tree[@]+"${sss_tree[@]}"})
	if ((nskip)); then
		echo "Stopping the running step (${_SWEEP_STEP_NAME:-PID ${pid}}): SIG${sig} to ${nsig} of its $((nsig + nskip)) process(es); the other ${nskip} are in the terminal's foreground group, which a Ctrl-C or a closed terminal reaches itself, so they are not sent it again (a 'kill -${sig} <pid>' from elsewhere does not reach them: they get SIGKILL; stop a sweep from elsewhere with SIGTERM). Any still running ${grace}s later get SIGKILL (SWEEP_STOP_GRACE_SEC)." >&2 || true
	elif ((nsig)); then
		echo "Stopping the running step (${_SWEEP_STEP_NAME:-PID ${pid}}): SIG${sig} to its ${nsig} process(es); any still running ${grace}s later get SIGKILL (SWEEP_STOP_GRACE_SEC)." >&2 || true
	fi
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
		# The step's own process is reaped here, quietly: bash would print a "Killed" notice
		# for it at the next command it waits for (the hint's substitution below). The wait
		# is short: the step was just sent SIGKILL when it still ran (it is in the tree); one
		# bash reaped already is marked as told (_sweep_step_reap).
		{
			for k in ${sss_tree[@]+"${sss_tree[@]}"}; do
				if kill -s KILL "${k%%@*}"; then n=$((n + 1)); fi
			done
			_sweep_step_reap "$pid"
		} 2>/dev/null || true
		((n == 0)) || echo "warning: ${n} process(es) of the step still ran ${grace}s after SIG${sig}: sent SIGKILL ($(_sweep_kill_hint))" >&2 || true
	fi
	_sweep_step_reap "$pid"
	_SWEEP_STEP_PID="" _SWEEP_STEP_TREE=""
}

# _sweep_step_reap <pid>: wait for the step's process, only while it exists (running, or a
# zombie not reaped yet). A step that ended at the moment the signal ended sweep_step's wait
# can be gone while bash still lists it as running: `wait <pid>` then waits for any child,
# and a sweep's background poller never ends, so the sweep would hang and never write its
# outcome or remove its lock. A step bash reaped already (its SIGCHLD handler runs at any
# time, also between the SIGKILL and the check) keeps its job notice ("line N: <pid> Killed
# ..."), which bash prints at the next command it waits for: `jobs` marks every ended job as
# told, quietly (a later `wait <pid>` still gets its status).
# shellcheck disable=SC2329
_sweep_step_reap() {
	! kill -0 "$1" 2>/dev/null || wait "$1" 2>/dev/null || true
	jobs >/dev/null 2>&1 || true
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
	[[ "${_SWEEP_STEP_OWNER:-}" == "${BASHPID:-$$}" ]] || return 0
	# The watchdog of _sweep_step_stop (neither ps nor /proc works), also once the step is gone.
	if [[ -n "${_SWEEP_STEP_WD:-}" ]]; then
		kill "$_SWEEP_STEP_WD" 2>/dev/null || true
		wait "$_SWEEP_STEP_WD" 2>/dev/null || true
		_SWEEP_STEP_WD=""
	fi
	[[ -n "$pid" ]] || return 0
	read -r -a ssk_tree <<< "${_SWEEP_STEP_TREE:-$pid}"
	_sweep_tree_freeze ssk_tree ${ssk_tree[@]+"${ssk_tree[@]}"} "$pid"
	# Neither ps nor /proc works: the step's own process (still this shell's child).
	if ((${#ssk_tree[@]} == 0)) && kill -0 "$pid" 2>/dev/null && ! _sweep_ps_works; then ssk_tree=("${pid}@"); fi
	for k in ${ssk_tree[@]+"${ssk_tree[@]}"}; do kill -s KILL "${k%%@*}" 2>/dev/null || true; done
	((${#ssk_tree[@]} == 0)) || echo "warning: the sweep ended while its step (${_SWEEP_STEP_NAME:-PID ${pid}}) still ran: sent SIGKILL to its ${#ssk_tree[@]} process(es)" >&2 || true
	_sweep_step_reap "$pid"
	_SWEEP_STEP_PID="" _SWEEP_STEP_TREE="" _SWEEP_STEP_WD=""
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

# sweep_outcome_brief <file>: what a report that pools sweep-* dirs names about one of their
# records, or nothing for a finished outcome without a PROBLEM line (or no file): "has not
# finished (it died, or still runs)", "was interrupted before it wrote its outcome" (a
# not-finished record with ENDED_AT), or "stopped early" (CUT_SHORT=1), then "<n>
# PROBLEM(s)" when the record has any, joined by ", with ". One line, no newline.
# shellcheck disable=SC2329
sweep_outcome_brief() {
	local s="" n
	[[ -f "$1" ]] || return 0
	if sweep_outcome_unfinished "$1"; then
		if grep -q '^ENDED_AT=' "$1" 2>/dev/null; then
			s="was interrupted before it wrote its outcome"
		else
			s="has not finished (it died, or still runs)"
		fi
	elif grep -qx 'CUT_SHORT=1' "$1" 2>/dev/null; then
		s="stopped early"
	fi
	n="$(grep -c '^PROBLEM=' "$1" 2>/dev/null)" || n=0
	is_nonneg_int "$n" || n=0
	if ((n > 0)); then s+="${s:+, with }${n} PROBLEM(s)"; fi
	printf '%s' "$s"
}

# sweep_outcome_pooled <results_dir> <tsv>...: for a report that pools runs, one line per
# sweep-* dir below <results_dir> that holds one of <tsv> and whose sweep-outcome.txt
# sweep_outcome_brief names: "<dir>/sweep-outcome.txt: <brief>", <dir> relative to
# <results_dir>, in the order of <tsv> (paths as `find <results_dir>` prints them). A TSV in
# <results_dir> itself (the report repeats that record) or in a dir not named sweep-* adds
# nothing. The pooled reports of dataplane, churn, churn-dataplane and propagation name
# these records in their pooled note, and so does a report of one run whose results dir has
# no record of its own (its sweep's parent dir).
# shellcheck disable=SC2329
sweep_outcome_pooled() {
	local t="$1" pre f d rel b
	local -A sop_seen=()
	shift
	while [[ "$t" == */ && "$t" != / ]]; do t="${t%/}"; done
	pre="${t%/}/"
	for f in "$@"; do
		[[ "$f" == */* ]] || continue
		d="${f%/*}"
		[[ "$d" != "$t" && "${d##*/}" == sweep-* && -z "${sop_seen[$d]+x}" ]] || continue
		sop_seen[$d]=1
		rel="$d"
		if [[ "$d" == "$pre"* ]]; then
			rel="${d#"$pre"}"
			while [[ "$rel" == /* ]]; do rel="${rel#/}"; done
		fi
		b="$(sweep_outcome_brief "${d}/sweep-outcome.txt")"
		[[ -z "$b" ]] || printf '%s/sweep-outcome.txt: %s\n' "$rel" "$b"
	done
}

# sweep_outcome_on_exit <rc> [--note <msg>|--info <msg>|--problem <msg>...]: A sweep's EXIT
# trap calls it after its own cleanup (a tuning profile is reverted first, PL32), as
#   sweep_outcome_on_exit "$rc" ${RESUME_NOTES[@]+"${RESUME_NOTES[@]}"} || true
# with <rc> the $? the trap started with, and the notes and problems the sweep gathered so
# far (a controlplane --resume's harness, Kubernetes and readiness notes, tuning's Istio
# CR generation checks), which its reports would otherwise lose. It first kills what still
# runs of a step (sweep_step_kill: a second signal ended the wait for it), then removes the
# sweep dir's lock this shell took (sweep_lock). Then it does nothing unless
# sweep_outcome_start armed it in this shell (never in a subshell) and
# <dir>/sweep-outcome.txt is still that start's not-finished record: the sweep wrote its
# outcome at its end, or never started. Else the sweep ended before its outcome, and the
# record says how:
#   - interrupted: a signal sweep_trap_signals caught (Ctrl-C, SIGTERM, a closed terminal:
#     _SWEEP_SIGNAL); the ERR trap for a command a signal killed (its exit 129, 130 or
#     143); or exit 0 with no reason (no exit of this harness before its outcome is 0). The
#     record stays not finished and gets ENDED_AT (UTC), ENDED_EXIT, when known
#     ENDED_SIGNAL, and the notes as NOTE= and INFO= lines, each problem as a NOTE= line too
#     (a not-finished record counts nothing; so is a harness that changed during the
#     sweep, and HEAD that moved with the same harness files is an INFO:
#     _harness_sha_sweep_end): the reports say the run was interrupted then, before its
#     outcome (it does not still run), with those notes.
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
# next step is its "next:" note, printed with the outcome just before; SWEEP_NEXT_CONSOLE,
# when the sweep sets it, is the console's next step, a command with real paths, printed
# after the sweep dir instead, while the record keeps NEXT and the "next:" note, which name
# no local path). A sweep killed outright (SIGKILL, out of memory, a lost host) runs no
# trap: its record stays not finished without ENDED_AT ("it died, or still runs"). Never
# dies otherwise; warns when it cannot write.
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
			# The sweep's notes and problems so far: one line each, as sweep_outcome keeps them;
			# a problem as a NOTE (this record counts nothing).
			k=1
			while ((k < $#)); do
				case "${!k}" in
				--note | --problem) k=$((k + 1)); printf 'NOTE=%s\n' "${!k//$'\n'/ }" ;;
				--info) k=$((k + 1)); printf 'INFO=%s\n' "${!k//$'\n'/ }" ;;
				esac
				k=$((k + 1))
			done
		} 2>/dev/null >> "$f" || echo "warning: could not add ENDED_AT to ${f}" >&2
		# A harness that changed during the sweep (harness_sha_check, the end check): a note;
		# HEAD that moved with the same harness files: an INFO line; the steps' reads that
		# could not be checked: a note.
		local hs_changed="" hs_info="" hs_note=""
		_harness_sha_sweep_end hs_changed hs_info hs_note
		if [[ -n "$hs_changed" ]]; then
			printf 'NOTE=%s\n' "$hs_changed" 2>/dev/null >> "$f" || true
			echo "warning: ${hs_changed}." >&2
		fi
		if [[ -n "$hs_note" ]]; then
			printf 'NOTE=%s\n' "$hs_note" 2>/dev/null >> "$f" || true
			echo "warning: ${hs_note}." >&2
		fi
		if [[ -n "$hs_info" ]]; then
			printf 'INFO=%s\n' "$hs_info" 2>/dev/null >> "$f" || true
			echo "note: ${hs_info}." >&2
		fi
		echo "warning: the sweep was interrupted (${sig:+SIG${sig}, }exit ${rc}) before its outcome; sweep-outcome.txt says it has not finished" >&2
		next="${SWEEP_NEXT_CONSOLE:-$next}"
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
	# The console's own next step (SWEEP_NEXT_CONSOLE, below) replaces the record's there.
	if [[ -n "$next" && -n "${SWEEP_NEXT_CONSOLE:-}" ]]; then
		args+=(--record-note "next: ${next}")
	elif [[ -n "$next" ]]; then
		args+=(--note "next: ${next}")
	fi
	sweep_outcome "${args[@]}" 0 || true
	{
		echo "CUT_SHORT=1"
		[[ -z "$started" ]] || echo "STARTED_AT=${started}"
		[[ -z "$resumed" ]] || echo "RESUMED_AT=${resumed}"
		echo "ENDED_AT=${now}"
	} 2>/dev/null >> "$f" || echo "warning: could not add CUT_SHORT to ${f}" >&2
	# sweep_outcome printed the next step (its "next:" note) just above, unless the console
	# has its own.
	echo "  sweep dir: ${dir}" >&2
	[[ -z "${SWEEP_NEXT_CONSOLE:-}" ]] || echo "  next: ${SWEEP_NEXT_CONSOLE}" >&2
	((orc == 1)) || exit 1
	return 0
}

# _sweep_resume_rows_added <results_dir> <record>: the data rows a --resume added, counted in
# the results dir's TSV after its "# RESUMED_AT=<time> ..." line for the record's RESUMED_AT
# (controlplane 003 writes it where the resume's rows begin; a time with +00:00 matches
# its Z form); nothing when no TSV has that line (not known). Never dies.
# shellcheck disable=SC2329
_sweep_resume_rows_added() {
	local t tsv n sum="" found=0
	t="$(sed -n 's/^RESUMED_AT=//p' "$2" 2>/dev/null | head -n 1)"
	[[ -n "$t" ]] || return 0
	for tsv in "$1"/*.tsv; do
		[[ -f "$tsv" ]] || continue
		n="$(_SRA_T="$t" awk '
			index($0, "# RESUMED_AT=") == 1 {
				v = substr($0, 14); sub(/ .*/, "", v); sub(/\+00:00$/, "Z", v)
				if (v == ENVIRON["_SRA_T"]) { on = 1; c = 0 }
				next
			}
			on && $0 !~ /^#/ && $0 != "" { c++ }
			END { if (on) print c }' "$tsv" 2>/dev/null)" || n=""
		[[ "$n" =~ ^[0-9]+$ ]] || continue
		found=1 sum=$((${sum:-0} + n))
	done
	((found == 0)) || printf '%s\n' "$sum"
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
	local radd=""
	case "$mode" in
	resume) [[ ! -f "$f" ]] || files+=("$f"); files+=("$prev") ;;
	stopres) files=("$f" "$prev"); radd="$(_sweep_resume_rows_added "$1" "$f")" ;;
	*) files=("$f") ;;
	esac
	# Record 1 is sweep-outcome.txt (the current run's), record 2 sweep-outcome.prev.txt (the
	# outcome before a --resume). radd: the rows a --resume that stopped added (empty: not
	# known).
	_SOR_RADD="$radd" awk -v fmt="$fmt" -v other="$other" -v mode="$mode" -v prevf="$prev" "${JSON_STR_AWK}"'
		function jstr(v) { return js(v) }
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
			radd = ENVIRON["_SOR_RADD"]
			sl = "this stop ended a --resume of the sweep" (RES[1] != "" ? " (started at " RES[1] ")" : "") ": the outcome before it, from sweep-outcome.prev.txt, follows; " (radd == "0" ? "that --resume added no rows before it stopped" : radd ~ /^[0-9]+$/ ? "the " radd " row(s) that --resume added before it stopped are in the TSV, uncounted" : "the rows that --resume added before it stopped are in the TSV, uncounted")
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
# In the shell that ran harness_sha_for_sweep it reads the harness again: one whose files
# changed during the sweep (at its end, at a harness_sha_check before a step, or at a step's
# own read) is a problem too, naming both values and when the change was first read; HEAD
# that moved with the same files (a commit or tag that left the harness files as they were)
# is an --info, and steps' reads it could not check (their temp file was gone) a --note
# (_harness_sha_sweep_end).
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
#   --record-note <msg>  a --note that is recorded (and in the markdown) but not printed: the
#                    caller prints its own form of it (sweep_outcome_on_exit's next step)
#   --info <msg>     a fact worth keeping that is not a caveat (a --resume whose members
#                    were all ready); printed on stdout as "note: <msg>." and recorded
#   --record <dir>   also write the outcome to <dir>/sweep-outcome.txt, with RUN_ID
#                    (--run-id), HARNESS_SHA and HARNESS_CONTENT_KEY (the sweep's, as its
#                    TSVs record them, else one harness_read)
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
	local -a problems=() notes=() rnotes=() infos=() failed_r=() skipped_r=() lines=() mds_r=()
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
		--record-note) rnotes+=("$2"); shift 2 ;;
		--info) infos+=("$2"); shift 2 ;;
		--record) record="$2"; shift 2 ;;
		--md) mds_r+=("$2"); shift 2 ;;
		*) break ;;
		esac
	done
	cells="$1"
	shift
	[[ -z "$uncounted" ]] || problems=("could not count the sweep's ${unit}: ${uncounted}" ${problems[@]+"${problems[@]}"})
	# The sweep's harness at its end (harness_sha_for_sweep's shell only): a change of its
	# files is a problem; HEAD that moved with the same files, an INFO; the steps' reads that
	# could not be checked, a note.
	local so_hs="" so_hi="" so_hn=""
	_harness_sha_sweep_end so_hs so_hi so_hn
	[[ -z "$so_hs" ]] || problems+=("$so_hs")
	[[ -z "$so_hi" ]] || infos+=("$so_hi")
	[[ -z "$so_hn" ]] || notes+=("$so_hn")
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
	for r in ${rnotes[@]+"${rnotes[@]}"}; do lines+=("rec|warning: ${r}."); done
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
		local so_stopped=0 so_total=unknown so_failed=unknown so_skipped=unknown so_v="${HARNESS_SHA:-}" so_k="${HARNESS_CONTENT_KEY:-}"
		if [[ -n "$stop_rc" ]]; then so_stopped=1; fi
		[[ -n "$so_v" ]] || harness_read so_v so_k
		if [[ -z "$uncounted" ]]; then
			so_total="$cells" so_failed="${#failed_r[@]}" so_skipped="${#skipped_r[@]}"
		fi
		{
			echo "# Sweep outcome (tests/lib/common.sh sweep_outcome)"
			echo "# DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			echo "RUN_ID=${run_id_r:-unknown}"
			echo "HARNESS_SHA=${so_v}"
			echo "HARNESS_CONTENT_KEY=${so_k:-unknown}"
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
			for r in ${notes[@]+"${notes[@]}"} ${rnotes[@]+"${rnotes[@]}"}; do echo "NOTE=${r}"; done
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

# HARNESS_PATHS: the dirs whose content is the harness (harness_sha's -dirty hash, the
# content key); a file outside them (docs/, a campaign note, the READMEs at the top) never
# makes a run dirty, and a commit that changes only such files leaves the content key.
# shellcheck disable=SC2034
HARNESS_PATHS=(tests config charts terraform)

# harness_sha [--exclude <dir>]...: the harness the run uses (PL2): `git -C "${ROOT:-.}"
# describe --always --abbrev=7`, or unknown when git cannot name it. A harness with
# uncommitted changes under HARNESS_PATHS (tracked files that differ from HEAD, or untracked
# files that are not ignored) gets `-dirty.<8hex>`: `<describe>-dirty.<8hex>`, the first 8
# hex digits of its content key (harness_content_key), so two different uncommitted trees on
# one commit record two different values, and one tree records one value whatever the
# operator's git config. Submodules (the bats checkouts) never count, as
# `--ignore-submodules`: one moved, copied without its .git or with its gitdir gone reads
# clean. When the content cannot be hashed, a harness whose tracked files differ from HEAD
# reads `-dirty.unknown`. The untracked files under each --exclude <dir> (a run's output dir
# inside the checkout: its own results) do not count, and neither do those under
# HARNESS_SHA_EXCLUDE, the results dir a sweep exports to the steps it runs
# (harness_sha_for_sweep); a tracked file there still does. Every call reads the live tree,
# so a step of a sweep records the harness it runs, also when a file changed after the sweep
# started (harness_sha_check, sweep_outcome). While the harness files are still the ones the
# sweep started with (its content key, exported as HARNESS_SWEEP_KEY), a step records the
# sweep's start value (HARNESS_SWEEP_SHA): a commit or tag that left the harness files as
# they were does not give its steps another value. A step that reads other
# files also adds a line to the sweep's HARNESS_SWEEP_LOG (harness_read), so the sweep's
# outcome has the change even when its own reads missed it.
# shellcheck disable=SC2329
harness_sha() {
	# shellcheck disable=SC2034  # harness_read sets both (namerefs)
	local hs_v hs_k
	harness_read hs_v hs_k "$@"
	printf '%s\n' "$hs_v"
}

# harness_content_key [--exclude <dir>]...: the content key of the harness, which a TSV
# preamble records as HARNESS_CONTENT_KEY next to HARNESS_SHA: 12 hex digits that name the
# content of HARNESS_PATHS in the working tree (_harness_keys), never the commit, so a commit
# or tag that left the harness files as they were leaves it; `unknown` when git cannot compute
# it. Runs with one key ran the same harness files. The excludes as harness_sha's.
# shellcheck disable=SC2329
harness_content_key() {
	# shellcheck disable=SC2034  # harness_read sets both (namerefs)
	local hck_v hck_k
	harness_read hck_v hck_k "$@"
	printf '%s\n' "$hck_k"
}

# harness_read <sha_var> <key_var> [--live] [--exclude <dir>]...: one read of the harness:
# sets <sha_var> to harness_sha's value and <key_var> to harness_content_key's, from the
# same read (a probe records both in its preamble). --live: the live value, also when the
# content key is the sweep's start key (harness_sha_check and the end check compare it).
# Without --live, under a sweep (HARNESS_SWEEP_KEY), a read whose files are not the sweep's
# start ones (harness_same) adds "<UTC Z> <script> HARNESS_SHA=<v> HARNESS_CONTENT_KEY=<k>"
# to HARNESS_SWEEP_LOG while that file exists (sweep_outcome_start creates it, the end
# check removes it: _harness_sha_sweep_end), so a change only a step read reaches the
# sweep's outcome. A setup step that renders harness files (a chart, a tuning profile)
# reads the harness right after, for that line alone.
# shellcheck disable=SC2329
harness_read() {
	local -n _hr_v="$1" _hr_k="$2"
	shift 2
	local hr_live=0 hr_root="${ROOT:-.}" hr_keys hr_d
	local -a hr_excl=()
	while (($#)); do
		case "$1" in
		--live) hr_live=1; shift ;;
		--exclude)
			[[ -z "${2:-}" ]] || hr_excl+=("$2")
			shift 2 || shift
			;;
		*) shift ;;
		esac
	done
	[[ -z "${HARNESS_SHA_EXCLUDE:-}" ]] || hr_excl+=("$HARNESS_SHA_EXCLUDE")
	# No --dirty: it fails (exit 128) when a submodule's gitdir is gone, and counts a moved
	# submodule; the content key below says whether the harness is dirty.
	hr_d="$(git -C "$hr_root" describe --always --abbrev=7 2>/dev/null || true)"
	[[ -n "$hr_d" ]] || hr_d="unknown"
	_hr_k=unknown
	if [[ "$hr_d" != unknown ]]; then
		if hr_keys="$(_harness_keys ${hr_excl[@]+"${hr_excl[@]}"})"; then
			_hr_k="${hr_keys%% *}"
			[[ "$_hr_k" == "${hr_keys##* }" ]] || hr_d+="-dirty.${_hr_k:0:8}"
		elif ! git -C "$hr_root" diff --quiet --no-ext-diff --no-textconv --ignore-submodules=all HEAD -- \
			"${HARNESS_PATHS[@]/#/:(top,literal)}" 2>/dev/null; then
			# The content could not be hashed, and the tracked files differ from HEAD (or git
			# cannot tell): dirty, by what is unknown.
			hr_d+="-dirty.unknown"
		fi
	fi
	# Under a sweep, the harness files it started with: its start value; other files: a line
	# in the sweep's log.
	if ((hr_live == 0)) && [[ "$_hr_k" != unknown && "$_hr_k" == "${HARNESS_SWEEP_KEY:-}" && -n "${HARNESS_SWEEP_SHA:-}" ]]; then
		hr_d="$HARNESS_SWEEP_SHA"
	elif ((hr_live == 0)) && [[ -n "${HARNESS_SWEEP_KEY:-}" && -n "${HARNESS_SWEEP_LOG:-}" && -f "$HARNESS_SWEEP_LOG" ]] \
		&& ! harness_same "$hr_d" "$_hr_k" "${HARNESS_SWEEP_SHA:-}" "$HARNESS_SWEEP_KEY"; then
		printf '%s %s HARNESS_SHA=%s HARNESS_CONTENT_KEY=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${0##*/}" "$hr_d" "$_hr_k" \
			2>/dev/null >> "$HARNESS_SWEEP_LOG" || true
	fi
	_hr_v="$hr_d"
}

# sweep_settings_check: die naming the key and its value when SWEEP_STOP_GRACE_SEC or
# HARNESS_SHA_CHECK_SEC is not a non-negative integer, or ISTIO_PROXY_READ_PARALLEL not a
# positive one (config/options.env), so a bad value never falls back to the default
# unseen; then warn when a stop could not read a step's tree (_sweep_ps_check, so a
# --dry-run shows it too). harness_sha_for_sweep calls it at each sweep's start, before any
# cluster change (the probes check ISTIO_PROXY_READ_PARALLEL in istio_version_resolve).
# shellcheck disable=SC2329
sweep_settings_check() {
	local k v
	for k in SWEEP_STOP_GRACE_SEC HARNESS_SHA_CHECK_SEC ISTIO_PROXY_READ_PARALLEL; do
		v="${!k:-}"
		[[ -n "$v" ]] || continue
		if [[ "$k" == ISTIO_PROXY_READ_PARALLEL ]]; then
			is_pos_int "$v" || die "${k} must be a positive integer of members (got: ${v}); see config/options.env"
		else
			is_nonneg_int "$v" || die "${k} must be a non-negative integer of seconds (got: ${v}); see config/options.env"
		fi
	done
	_sweep_ps_check
}

# harness_sha_for_sweep [<output_dir>]: a sweep's harness at its start (sweep_settings_check
# first). Sets HARNESS_SHA and HARNESS_CONTENT_KEY (harness_read --exclude <output_dir>) in
# this shell, and exports <output_dir> (absolute) as HARNESS_SHA_EXCLUDE, and the start's
# value and key as HARNESS_SWEEP_SHA and HARNESS_SWEEP_KEY: each step (a probe, a report)
# reads the live tree minus the sweep's results, so a step that ran on changed harness files
# records what it ran, and one that ran on the start's files records the start's value.
# Keeps the start for harness_sha_check (before each step, through sweep_step) and for the
# end check in sweep_outcome, which compare content keys: a harness that changed during the
# sweep is a problem; HEAD that moved with the same harness files (a commit or tag that left
# the harness files as they were) is a note (INFO). Call it before the first step, as a
# plain command (not in a subshell).
# shellcheck disable=SC2329
harness_sha_for_sweep() {
	local hsfs_d="${1:-}"
	sweep_settings_check
	unset HARNESS_SHA_EXCLUDE
	if [[ -n "$hsfs_d" ]]; then
		[[ "$hsfs_d" == /* ]] || hsfs_d="${PWD%/}/${hsfs_d}"
		harness_read HARNESS_SHA HARNESS_CONTENT_KEY --exclude "$hsfs_d"
		export HARNESS_SHA_EXCLUDE="$hsfs_d"
	else
		harness_read HARNESS_SHA HARNESS_CONTENT_KEY
	fi
	export HARNESS_SWEEP_SHA="$HARNESS_SHA" HARNESS_SWEEP_KEY="$HARNESS_CONTENT_KEY"
	# A parent's step log is not this sweep's (sweep_outcome_start creates its own).
	unset HARNESS_SWEEP_LOG
	_HARNESS_SHA_START="$HARNESS_SHA" _HARNESS_KEY_START="$HARNESS_CONTENT_KEY" _HARNESS_STEP_FIRST="" _HARNESS_STEP_N=0
	_HARNESS_SHA_PID="${BASHPID:-$$}" _HARNESS_SHA_CHECKED="$SECONDS"
	_HARNESS_SHA_OK_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" _HARNESS_SHA_OK_BEFORE="" _HARNESS_SHA_SEEN=""
	_HARNESS_SHA_SEEN_AT="" _HARNESS_SHA_SEEN_BEFORE="" _HARNESS_SHA_END="" _HARNESS_KEY_END=""
	_HARNESS_SHA_MOVED="" _HARNESS_SHA_MOVED_AT="" _HARNESS_SHA_MOVED_BEFORE="" _HARNESS_STEP_LOST=""
}

# harness_same <value> <key> <value2> <key2>: true when two harness reads (harness_read)
# name the same harness files: the same content key when both keys are known, else (either
# is unknown or empty) the same HARNESS_SHA value.
# shellcheck disable=SC2329
harness_same() {
	if [[ -n "$2" && "$2" != unknown && -n "$4" && "$4" != unknown ]]; then
		[[ "$2" == "$4" ]]
	else
		[[ "$1" == "$3" ]]
	fi
}

# _harness_same_files <value> <key>: true when a read (harness_read --live) found the
# sweep's start harness files (harness_same with the start's value and key).
# shellcheck disable=SC2329
_harness_same_files() {
	harness_same "$1" "$2" "${_HARNESS_SHA_START:-}" "${_HARNESS_KEY_START:-unknown}"
}

# harness_sha_check <step>: in the shell that ran harness_sha_for_sweep, read the harness
# again before <step> (sweep_step names the step's script), at most once every
# HARNESS_SHA_CHECK_SEC seconds (config/options.env; 0: before every step). The first read
# whose harness files differ from the start's (another content key) is kept, with its value,
# when and before which step it was read, and printed once as a WARNING; the sweep goes on,
# and sweep_outcome records the change as a problem (exit 4). A read with the start's files
# but another value (HEAD moved: a commit or tag that left the harness files as they were)
# is printed once as a note, and recorded as one (INFO). Nothing once the end check ran
# (_harness_sha_sweep_end: a step after it, such as a report, cannot change its answer).
# Never dies.
# shellcheck disable=SC2329
harness_sha_check() {
	[[ -n "${_HARNESS_SHA_START:-}" && "${_HARNESS_SHA_PID:-}" == "${BASHPID:-$$}" && -z "${_HARNESS_SHA_SEEN:-}" \
		&& -z "${_HARNESS_SHA_END:-}" ]] || return 0
	local every="${HARNESS_SHA_CHECK_SEC:-60}" v k hp
	is_nonneg_int "$every" || every=60
	((SECONDS - ${_HARNESS_SHA_CHECKED:-0} >= every)) || return 0
	_HARNESS_SHA_CHECKED="$SECONDS"
	harness_read v k --live
	hp="$(printf '%s/, ' "${HARNESS_PATHS[@]}")"
	hp="${hp%, }"
	if _harness_same_files "$v" "$k"; then
		_HARNESS_SHA_OK_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" _HARNESS_SHA_OK_BEFORE="${1:-a step}"
		if [[ "$v" != "$_HARNESS_SHA_START" && -z "${_HARNESS_SHA_MOVED:-}" ]]; then
			_HARNESS_SHA_MOVED="$v" _HARNESS_SHA_MOVED_AT="$_HARNESS_SHA_OK_AT" _HARNESS_SHA_MOVED_BEFORE="${1:-a step}"
			echo "note: HEAD moved during the sweep, or a tag appeared: HARNESS_SHA=${_HARNESS_SHA_START} at its start, ${v} now (read before ${_HARNESS_SHA_MOVED_BEFORE}), but the files under ${hp} did not change (a commit or tag that left the harness files as they were): the steps keep recording ${_HARNESS_SHA_START}." >&2 || true
		fi
		return 0
	fi
	_HARNESS_SHA_SEEN="$v" _HARNESS_SHA_SEEN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" _HARNESS_SHA_SEEN_BEFORE="${1:-a step}"
	echo "WARNING: the harness changed during the sweep: HARNESS_SHA=${_HARNESS_SHA_START} at its start, ${v} now (read before ${_HARNESS_SHA_SEEN_BEFORE}): a file under ${hp} was edited, added or removed (an untracked file counts unless git ignores it, such as a run config not named *.local.env), or a git checkout, pull or commit changed one. The sweep goes on; its outcome records this as a problem (exit 4). A commit or tag that left the harness files as they were changes only the commit name and is a note, not this warning." >&2 || true
	return 0
}

# _harness_sha_sweep_end <problem_var> [<info_var> [<note_var>]]: once per sweep, in the shell
# that ran harness_sha_for_sweep: read the harness again (the end check) and set <problem_var>
# to the problem sweep_outcome records when its files changed during the sweep (another
# content key at the end, at a harness_sha_check before a step, or at a step's own read: the
# lines harness_read added to HARNESS_SWEEP_LOG, which it reads and removes), naming each
# value and when it was read, and which steps may have run other code; empty when they did
# not. <info_var>: the note (INFO) when they did not change but HEAD moved (another value
# with the start's files, at a check or at the end); else empty. <note_var>: a NOTE when the
# steps' own reads could not be checked (HARNESS_SWEEP_LOG was set but its file was gone at
# the end check, as a temp-file cleaner leaves it, or sweep_outcome_start could not create
# it); else empty.
# The problem starts with "the harness changed during the sweep" (a controlplane --resume
# reads that prefix), the note with "HEAD moved during the sweep". A second call returns
# the first call's answers.
# shellcheck disable=SC2329
_harness_sha_sweep_end() {
	local -n _hse_out="$1"
	_hse_out=""
	if (($# > 1)); then
		local -n _hse_info="$2"
		_hse_info=""
	fi
	if (($# > 2)); then
		local -n _hse_note="$3"
		_hse_note=""
	fi
	[[ -n "${_HARNESS_SHA_START:-}" && "${_HARNESS_SHA_PID:-}" == "${BASHPID:-$$}" ]] || return 0
	local s="$_HARNESS_SHA_START" e ek last first hp st="" st_t st_l by_step=0
	local -a st_lines=()
	if [[ -z "${_HARNESS_SHA_END:-}" ]]; then
		harness_read _HARNESS_SHA_END _HARNESS_KEY_END --live
		_HARNESS_SHA_END_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		if [[ -n "${HARNESS_SWEEP_LOG:-}" && -f "$HARNESS_SWEEP_LOG" ]]; then
			mapfile -t st_lines 2>/dev/null < "$HARNESS_SWEEP_LOG" || true
			rm -f "$HARNESS_SWEEP_LOG"
			_HARNESS_STEP_N="${#st_lines[@]}" _HARNESS_STEP_FIRST="${st_lines[0]:-}"
		elif [[ -n "${HARNESS_SWEEP_LOG:-}" ]]; then
			_HARNESS_STEP_LOST="the temp file they are added to (HARNESS_SWEEP_LOG) was gone at the end check (removed during the sweep, as a temp-file cleaner does)"
		fi
	fi
	if (($# > 2)) && [[ -n "${_HARNESS_STEP_LOST:-}" ]]; then
		_hse_note="the steps' own harness reads could not be checked: ${_HARNESS_STEP_LOST}, so a harness change that only a step read (undone before the sweep's next read) is not in its outcome"
	fi
	# The first step read of other files: "<UTC Z> <script> HARNESS_SHA=<v> HARNESS_CONTENT_KEY=<k>".
	if [[ -n "${_HARNESS_STEP_FIRST:-}" ]]; then
		st_t="${_HARNESS_STEP_FIRST%% *}" st_l="${_HARNESS_STEP_FIRST#* }"
		st="${st_l%% *} recorded HARNESS_SHA=${st_l#* HARNESS_SHA=}"
		st="${st%% HARNESS_CONTENT_KEY=*} at ${st_t}"
		[[ "${_HARNESS_STEP_N:-1}" == 1 ]] || st+=" (the first of ${_HARNESS_STEP_N} step reads of other files)"
	fi
	e="$_HARNESS_SHA_END" ek="${_HARNESS_KEY_END:-unknown}"
	last="at ${_HARNESS_SHA_OK_AT:-}, the sweep's start"
	[[ -z "${_HARNESS_SHA_OK_BEFORE:-}" ]] || last="at ${_HARNESS_SHA_OK_AT}, before ${_HARNESS_SHA_OK_BEFORE}"
	if [[ -n "${_HARNESS_SHA_SEEN:-}" ]]; then
		first="${_HARNESS_SHA_SEEN} at ${_HARNESS_SHA_SEEN_AT}, before ${_HARNESS_SHA_SEEN_BEFORE}; the read before that (${last}) still gave ${s}"
		# A step that read other files before this sweep read did: it saw the change first.
		if [[ -n "$st" && "$st_t" < "$_HARNESS_SHA_SEEN_AT" ]]; then first+="; a step read other files earlier: ${st}" by_step=1; fi
		if _harness_same_files "$e" "$ek"; then
			_hse_out="the harness changed during the sweep, and back: HARNESS_SHA=${s} at its start and at its end"
			[[ "$e" == "$s" ]] || _hse_out+=" (its files; HEAD moved, so the end read gave ${e})"
			_hse_out+=", but ${first}"
		else
			_hse_out="the harness changed during the sweep: HARNESS_SHA=${s} at its start, ${e} at its end (${_HARNESS_SHA_END_AT}), first read ${first}"
		fi
	elif ! _harness_same_files "$e" "$ek"; then
		_hse_out="the harness changed during the sweep: HARNESS_SHA=${s} at its start, ${e} at its end (${_HARNESS_SHA_END_AT}); the last read that gave ${s} was ${last}"
		if [[ -n "$st" ]]; then _hse_out+="; a step read other files before the end: ${st}" by_step=1; fi
	elif [[ -n "$st" ]]; then
		# Only a step read other files (changed and back between two sweep reads).
		_hse_out="the harness changed during the sweep, and back: HARNESS_SHA=${s} at its start and at its end"
		[[ "$e" == "$s" ]] || _hse_out+=" (its files; HEAD moved, so the end read gave ${e})"
		_hse_out+=", but ${st}" by_step=1
	else
		# The same files throughout: a note when HEAD moved (at a check, or by the end).
		if (($# > 1)) && [[ -n "${_HARNESS_SHA_MOVED:-}" || "$e" != "$s" ]]; then
			hp="$(printf '%s/, ' "${HARNESS_PATHS[@]}")"
			first="${e} at its end (${_HARNESS_SHA_END_AT})"
			[[ -z "${_HARNESS_SHA_MOVED:-}" ]] \
				|| first="${_HARNESS_SHA_MOVED} first read at ${_HARNESS_SHA_MOVED_AT}, before ${_HARNESS_SHA_MOVED_BEFORE}"
			_hse_info="HEAD moved during the sweep, or a tag appeared: HARNESS_SHA=${s} at its start, ${first}; the files under ${hp%, } did not change (HARNESS_CONTENT_KEY=${_HARNESS_KEY_START}), so every step ran the start's harness and recorded HARNESS_SHA=${s}"
		fi
		return 0
	fi
	# Which steps: after a step's read, those run since the change (which came at some time
	# before that read); else those after the last read that still gave the start's value.
	if ((by_step)); then
		_hse_out+=", so the step that read it, and the other steps run after the change, may have run other code than ${s}"
	else
		_hse_out+=", so the steps after the last read that gave ${s} may have run other code than ${s}"
	fi
	_hse_out+=": the rows after the change carry the new value in their TSV (controlplane: a HARNESS_CHANGED_AT line; churn-dataplane: each row's harness_sha), the sweep's own records (TSV preamble, sweep-outcome.txt) keep the start's; run the sweep again if the change matters"
	return 0
}

# _harness_keys [<exclude_dir>...]: "<key> <head_key>": the content key of the harness
# (HARNESS_PATHS) under ROOT in the working tree, and in HEAD (12 hex digits each; equal for
# a clean harness); returns 1 (prints nothing) when git cannot compute them. The content,
# never a diff (a diff's text follows the operator's git config: diff.context,
# diff.orderFile, core.abbrev): the tree object git would write for the working tree, built
# in a temporary index (GIT_INDEX_FILE, never the operator's): `read-tree HEAD`, then every
# tracked path and every untracked file that is not ignored under HARNESS_PATHS
# (`ls-files --cached`, `ls-files --others --exclude-standard`). A regular file is hashed as
# its bytes are on disk (`hash-object --no-filters`: no gitattributes filter it, not the
# repository's, the operator's global or system ones, nor the clone's own
# $GIT_DIR/info/attributes, and core.autocrlf does not either), with mode 100755 when it is
# executable (`-x`) and 100644 else (`update-index --index-info`); a symlink, a path that is
# gone and a nested repository go through `update-index --add --remove --info-only` (the
# link text; removed; its commit). Then `write-tree --missing-ok`. Nothing is written into
# the repository. The key: `hash-object` of that tree's `ls-tree` lines for HARNESS_PATHS
# (each dir's tree id), so a file outside them never changes it, in a clean or a dirty tree.
# Ignored files never count: .gitignore (editor and Finder files: .DS_Store, *.swp, *.swo,
# *~; the results/ dirs), .git/info/exclude, and the operator's global excludes:
# core.excludesFile, or git's default ~/.config/git/ignore ($XDG_CONFIG_HOME/git/ignore)
# when that key is unset (a file that only it ignores reads clean for that operator). The
# untracked files under each <exclude_dir> are left out (`:(exclude)` pathspec; its tracked
# files count), and so is each submodule of HEAD (its gitlink keeps HEAD's commit). The path
# lists go through files, never a pipe, so the result is the same with and without
# pipefail. git only: no sha256sum or shasum.
# shellcheck disable=SC2329
_harness_keys() {
	local root="${ROOT:-.}" top topp idx tree htree d rel ent hk i
	local -a hk_spec=("${HARNESS_PATHS[@]/#/:(top,literal)}") hk_excl=() hk_ids=()
	local -a hk_path=() hk_mode=() hk_q=() hk_other=() hk_info=()
	top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || return 1
	htree="$(git -C "$top" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null)" || return 1
	topp="$(cd "$top" 2>/dev/null && pwd -P)" || return 1
	for d in "$@"; do
		d="$(cd "$d" 2>/dev/null && pwd -P)" || continue
		rel="${d#"$topp"/}"
		[[ "$rel" != "$d" && -n "$rel" ]] || continue
		hk_excl+=(":(exclude,top,literal)${rel}")
	done
	idx="$(mktemp "${TMPDIR:-/tmp}/harness-index.XXXXXX" 2>/dev/null)" || return 1
	# HEAD's submodules (mode 160000 gitlinks): left out, as --ignore-submodules.
	git -C "$top" ls-tree -r -z --full-tree HEAD > "$idx" 2>/dev/null || { rm -f "$idx"; return 1; }
	while IFS= read -r -d '' ent; do
		[[ "$ent" != 160000\ * ]] || hk_spec+=(":(exclude,top,literal)${ent#*$'\t'}")
	done < "$idx"
	rm -f "$idx"
	tree="$(
		export GIT_INDEX_FILE="$idx" GIT_ATTR_NOSYSTEM=1
		git -C "$top" read-tree HEAD 2>/dev/null || exit 1
		{
			git -C "$top" -c core.quotePath=true ls-files -z --cached -- "${hk_spec[@]}" || exit 1
			git -C "$top" -c core.quotePath=true ls-files -z --others --exclude-standard -- "${hk_spec[@]}" \
				${hk_excl[@]+"${hk_excl[@]}"} || exit 1
		} > "${idx}.paths" 2>/dev/null
		# Regular files: hashed as they are on disk, in one hash-object (one path per line: a
		# path that a line would change, with a newline, a trailing CR or a leading quote, is
		# C-quoted); everything else through update-index.
		while IFS= read -r -d '' ent; do
			if [[ ! -L "${top}/${ent}" && -f "${top}/${ent}" ]]; then
				hk_path+=("$ent")
				if [[ -x "${top}/${ent}" ]]; then hk_mode+=(100755); else hk_mode+=(100644); fi
				if [[ "$ent" == \"* || "$ent" == *$'\n'* || "$ent" == *$'\r' ]]; then
					hk="${ent//\\/\\\\}" hk="${hk//\"/\\\"}" hk="${hk//$'\n'/\\n}"
					hk_q+=("\"${hk//$'\r'/\\r}\"")
				else
					hk_q+=("$ent")
				fi
			else
				hk_other+=("$ent")
			fi
		done < "${idx}.paths"
		if ((${#hk_path[@]})); then
			printf '%s\n' "${hk_q[@]}" > "${idx}.hash"
			git -C "$top" hash-object --no-filters --stdin-paths < "${idx}.hash" > "${idx}.ids" 2>/dev/null || exit 1
			mapfile -t hk_ids < "${idx}.ids"
			((${#hk_ids[@]} == ${#hk_path[@]})) || exit 1
			for ((i = 0; i < ${#hk_path[@]}; i++)); do
				hk_info+=("${hk_mode[i]} ${hk_ids[i]}"$'\t'"${hk_path[i]}")
			done
			printf '%s\0' "${hk_info[@]}" > "${idx}.info"
			git -C "$top" update-index -z --index-info < "${idx}.info" 2>/dev/null || exit 1
		fi
		if ((${#hk_other[@]})); then
			printf '%s\0' "${hk_other[@]}" > "${idx}.other"
			git -C "$top" -c core.autocrlf=false -c core.safecrlf=false -c core.fileMode=true -c core.attributesFile=/dev/null \
				update-index -z --add --remove --info-only --stdin < "${idx}.other" 2>/dev/null || exit 1
		fi
		git -C "$top" write-tree --missing-ok 2>/dev/null
	)" || tree=""
	if [[ "$tree" =~ ^[0-9a-f]{40,64}$ ]] \
		&& git -C "$top" ls-tree "$tree" -- "${HARNESS_PATHS[@]}" > "${idx}.w" 2>/dev/null \
		&& git -C "$top" ls-tree "$htree" -- "${HARNESS_PATHS[@]}" > "${idx}.h" 2>/dev/null; then
		mapfile -t hk_ids < <(git -C "$top" hash-object --no-filters -- "${idx}.w" "${idx}.h" 2>/dev/null)
	fi
	rm -f "$idx" "${idx}.paths" "${idx}.hash" "${idx}.ids" "${idx}.info" "${idx}.other" "${idx}.w" "${idx}.h"
	if ((${#hk_ids[@]} != 2)) || [[ ! "${hk_ids[0]}" =~ ^[0-9a-f]{40,64}$ || ! "${hk_ids[1]}" =~ ^[0-9a-f]{40,64}$ ]]; then
		return 1
	fi
	printf '%s %s\n' "${hk_ids[0]:0:12}" "${hk_ids[1]:0:12}"
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
#   cp_header()          call at the TSV header line: finds traffic_config and window_kind,
#                        and keeps its column count (cp_hn).
#   cp_isrow()           true when the current line, not a comment or the header, is a data
#                        row: it has as many columns as its TSV's header names, at least 40
#                        (the oldest schema's). Every row a harness writes has its header's
#                        columns or more (a newer harness appends columns to an older TSV); a
#                        line with fewer was cut while it was written (a kill or a full disk
#                        during the window's write): its last columns, traffic_config and
#                        window_kind among them, are missing, so it would read as a row of
#                        another cell.
#   cp_key()             the current row's cell key: columns 3-7, traffic_config and
#                        window_kind (none and deploy when absent), joined by SUBSEP.
#   cp_cell_row(k, st)   feed it each data row of cell k in file order (st: the status-row
#                        regex, 003's CELL_STATUS_RE); returns 1 for a status row.
#   cp_comment()         call it at each comment (#) line: reads the preamble's first
#                        ISTIOD_REPLICAS_BY_CONTEXT (cp_rep[member]), marks the cell
#                        written last before a "# RESUMED_AT=" line (where a run ended),
#                        and reads a "# WINDOW_ROWS=<member>=<n>[/<spec>],..." line: 002
#                        writes one in the same write as each window's rows, right before
#                        them (from this harness on), and cp_cell_row ties it to the cell
#                        attempt of the row on the next line (when that is a measurement
#                        row). <n>: the rows the window wrote, one per istiod pod; <spec>:
#                        the member's istiod Deployment .spec.replicas at the window's
#                        baseline (absent when not read, or an older harness wrote it).
#                        And a "# ISTIOD_NOT_READY=<member>=<pod>,..." line (002 writes one
#                        when an istiod pod was Running but not Ready at the window's
#                        baseline) and a "# ISTIOD_NOT_READY_AT_END=" line of the same form
#                        (the pods its final phase read as not Ready), in that order, right
#                        before the WINDOW_ROWS line: cp_cell_row ties them to the same
#                        attempt.
#   cp_wl_parse(wl)      the entries of such a line's value wl into cp_wlm[i] (the member),
#                        cp_wln[i] (<n>) and cp_wls[i] (<spec>, "" when absent); returns
#                        their count (an entry of another form is skipped).
#   cp_nr_parse(s)       the entries of an ISTIOD_NOT_READY or ISTIOD_NOT_READY_AT_END
#                        line's value s (or of a cp_notready list) into cp_nrm[i] (the
#                        member) and cp_nrq[i] (the pod); returns their count.
#   cp_wnr, cp_wne       the values of the ISTIOD_NOT_READY and ISTIOD_NOT_READY_AT_END
#                        lines right before the current WINDOW_ROWS line ("" when none).
#   cp_end()             call it in END, before cp_cell_state: marks the cell written last.
#   cp_cell_state(k)     "" when the cell is done: its last row is a measurement row, and
#                        the measurement rows since its last status row name as many
#                        distinct members as its mesh_size; the status of its last row
#                        when that is a status row; else INCOMPLETE: the run was cut short
#                        while 002 wrote the cell's member rows (cp_nm[k] of its cp_ms[k]
#                        members have one), or, when its attempt has WINDOW_ROWS lines, a
#                        member has fewer rows than they name (its window's write was cut);
#                        or, for an attempt without one (an older harness wrote its rows
#                        one by one) that was the cell written last before a run ended
#                        (the end of the TSV, or a "# RESUMED_AT=" line), a member has
#                        fewer rows than its istiod replicas (a row per replica: the
#                        smaller of its ISTIOD_REPLICAS_BY_CONTEXT entry and its most
#                        valid rows in another cell, or the one of them that is known: an
#                        HPA or a rollout changes the replicas during a sweep, so the
#                        two must agree; a member with a degraded row, istiod_restarted
#                        unknown, is not checked). A window this harness wrote is never
#                        held to the replica count: an istiod replica evicted or Pending
#                        at the largest cell gives fewer rows, all of them written. cp_why[k]
#                        says which. Any key works (a caller may prefix the file).
#   cp_why[k]            set by cp_cell_state for those two cases: "<member> has <n> of the
#                        <w> rows its window wrote", or "<member> has rows of <n> of its <r>
#                        istiod replicas"; empty otherwise.
#   cp_short[k]          set by cp_cell_state when the last row is a measurement row and a
#                        window of the attempt ran on fewer istiod pods than its member's
#                        Deployment wants (<n> below <spec>: a replica evicted or Pending; the
#                        rows are valid, so the cell is not INCOMPLETE): "<member> ran <n> of
#                        its <spec> istiod replicas", one per member (the fewest), joined by
#                        ", "; cp_shortw[k] the same for an entry without <spec>, against its
#                        ISTIOD_REPLICAS_BY_CONTEXT entry (read at the sweep's start: an HPA
#                        or a rollout may have changed the replicas since, so only a hint).
#                        cp_specw[k]: "<member> wanted <spec> istiod replicas, <rep> at the
#                        sweep's start", one per member, when a window of the attempt has a
#                        <spec> other than its ISTIOD_REPLICAS_BY_CONTEXT entry (an HPA, or a
#                        changed replicaCount: the cell ran another replica count than the
#                        sweep's start; the first such <spec>).
#                        A member whose rows of the attempt all have istiod_restarted unknown
#                        (no istiod pod Running: 002 writes one degraded N/A row, so its entry
#                        reads <member>=1/<spec>; or none could be read) is in neither: no
#                        figure has its rows, and the verdict already reads CAUTION for them
#                        (n_valid below n_total); nor in cp_specw, cp_notready or cp_notready_end.
#                        cp_notready[k]: "<member>=<pod>", joined by ",", for each pod an
#                        ISTIOD_NOT_READY line of the attempt names (Running but not Ready at
#                        its window's baseline: it took no new proxy connection while not
#                        Ready, and one shutting down drops its own as it exits, so the
#                        per-replica figures may include a replica that carried fewer);
#                        cp_notready_end[k] the same for its ISTIOD_NOT_READY_AT_END lines.
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
function cp_header(    i) { cp_tcol = 0; cp_wcol = 0; cp_hn = NF; for (i = 1; i <= NF; i++) { if ($i == "traffic_config") cp_tcol = i; if ($i == "window_kind") cp_wcol = i } }
function cp_isrow() { return NF >= (cp_hn > 40 ? cp_hn : 40) }
function cp_key() { return $3 SUBSEP $4 SUBSEP $5 SUBSEP $6 SUBSEP $7 SUBSEP ((cp_tcol && NF >= cp_tcol) ? $cp_tcol : "none") SUBSEP ((cp_wcol && NF >= cp_wcol) ? $cp_wcol : "deploy") }
function cp_comment(    n, p, i, e, x) {
	if (!cp_repread && index($0, "# ISTIOD_REPLICAS_BY_CONTEXT=") == 1) {
		cp_repread = 1
		n = split(substr($0, 30), p, ",")
		for (i = 1; i <= n; i++) { e = p[i]; gsub(/^ +| +$/, "", e); if (match(e, /=[0-9]+$/)) cp_rep[substr(e, 1, RSTART - 1)] = substr(e, RSTART + 1) + 0 }
	}
	if (index($0, "# RESUMED_AT=") == 1 && cp_lastk != "") cp_tail[cp_lastk] = 1
	cp_wl = ""
	# The end line, when there is one, sits between the baseline line and WINDOW_ROWS.
	if (index($0, "# WINDOW_ROWS=") == 1) {
		cp_wl = substr($0, 15); cp_wf = FNR
		x = (cp_ef == FNR - 1 && cp_eff == FILENAME)
		cp_wne = x ? cp_el : ""
		cp_wnr = (cp_nf == FNR - 1 - x && cp_nff == FILENAME) ? cp_nl : ""
	}
	if (index($0, "# ISTIOD_NOT_READY=") == 1) { cp_nl = substr($0, 20); cp_nf = FNR; cp_nff = FILENAME }
	if (index($0, "# ISTIOD_NOT_READY_AT_END=") == 1) { cp_el = substr($0, 27); cp_ef = FNR; cp_eff = FILENAME }
}
function cp_end() { if (cp_lastk != "") cp_tail[cp_lastk] = 1 }
function cp_wl_parse(wl,    n, p, i, e, c, v, j) {
	split("", cp_wlm); split("", cp_wln); split("", cp_wls)
	n = split(wl, p, ","); c = 0
	for (i = 1; i <= n; i++) {
		e = p[i]; gsub(/^ +| +$/, "", e)
		if (!match(e, /=[0-9]+(\/[0-9]+)?$/)) continue
		v = substr(e, RSTART + 1); c++
		cp_wlm[c] = substr(e, 1, RSTART - 1); cp_wls[c] = ""
		if ((j = index(v, "/"))) { cp_wls[c] = substr(v, j + 1) + 0; v = substr(v, 1, j - 1) }
		cp_wln[c] = v + 0
	}
	return c
}
function cp_nr_parse(s,    n, p, i, e, c) {
	split("", cp_nrm); split("", cp_nrq)
	n = split(s, p, ","); c = 0
	for (i = 1; i <= n; i++) {
		e = p[i]; gsub(/^ +| +$/, "", e)
		if (!match(e, /=[^=]+$/)) continue
		c++; cp_nrm[c] = substr(e, 1, RSTART - 1); cp_nrq[c] = substr(e, RSTART + 1)
	}
	return c
}
function cp_cell_row(k, st,    mk, ep, n, i, m, wk) {
	cp_ms[k] = $3 + 0
	cp_lastk = k
	if ($2 ~ st) { cp_last[k] = $2; cp_ep[k]++; cp_nm[k] = 0; cp_ml[k] = ""; cp_wl = ""; return 1 }
	if (cp_last[k] != "") cp_after[k] = 1
	cp_last[k] = ""
	if ($31 == "0") cp_valid[k] = 1
	ep = cp_ep[k] + 0
	# The WINDOW_ROWS line right before this row: the rows each member has in this attempt
	# (summed over its windows, as a watch run writes several), and the fewest istiod pods a
	# window of a member ran on below its <spec> (cp_rn, cp_rr), or below its preamble entry
	# when the line has no <spec> (cp_qn, cp_qr).
	if (cp_wl != "" && FNR == cp_wf + 1) {
		cp_wa[k, ep] = 1
		n = cp_wl_parse(cp_wl)
		for (i = 1; i <= n; i++) {
			m = cp_wlm[i]; wk = k SUBSEP ep SUBSEP m
			if (!(wk in cp_wx)) cp_wm[k, ep] = cp_wm[k, ep] "\t" m
			cp_wx[wk] += cp_wln[i]
			if (cp_wls[i] != "") {
				if (cp_wln[i] < cp_wls[i] && (!(wk in cp_rn) || cp_wln[i] < cp_rn[wk])) { cp_rn[wk] = cp_wln[i]; cp_rr[wk] = cp_wls[i] }
				if ((m in cp_rep) && cp_wls[i] != cp_rep[m] && !(wk in cp_sd)) cp_sd[wk] = cp_wls[i]
			}
			else if ((m in cp_rep) && cp_wln[i] < cp_rep[m] && (!(wk in cp_qn) || cp_wln[i] < cp_qn[wk])) { cp_qn[wk] = cp_wln[i]; cp_qr[wk] = cp_rep[m] }
		}
		n = cp_nr_parse(cp_wnr)
		for (i = 1; i <= n; i++) {
			wk = k SUBSEP ep SUBSEP cp_nrm[i]
			if (index(" " cp_nrp[wk] " ", " " cp_nrq[i] " ") == 0) cp_nrp[wk] = cp_nrp[wk] (cp_nrp[wk] == "" ? "" : " ") cp_nrq[i]
		}
		n = cp_nr_parse(cp_wne)
		for (i = 1; i <= n; i++) {
			wk = k SUBSEP ep SUBSEP cp_nrm[i]
			if (index(" " cp_nep[wk] " ", " " cp_nrq[i] " ") == 0) cp_nep[wk] = cp_nep[wk] (cp_nep[wk] == "" ? "" : " ") cp_nrq[i]
		}
	}
	cp_wl = ""
	mk = k SUBSEP ep SUBSEP $2
	if (!(mk in cp_mem)) { cp_mem[mk] = 1; cp_nm[k]++; cp_ml[k] = cp_ml[k] "\t" $2 }
	if ($31 == "unknown") cp_dg[mk] = 1
	else cp_rd[mk] = 1
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
function cp_cell_state(k,    n, ml, i, m, mk, ex, ep, np, pl, j) {
	cp_why[k] = ""; cp_short[k] = ""; cp_shortw[k] = ""; cp_specw[k] = ""; cp_notready[k] = ""; cp_notready_end[k] = ""
	if (cp_last[k] != "") return cp_last[k]
	ep = cp_ep[k] + 0
	n = split(substr(cp_wm[k, ep], 2), ml, "\t")
	for (i = 1; i <= n; i++) {
		mk = k SUBSEP ep SUBSEP ml[i]
		if (!(mk in cp_rd)) continue
		if (mk in cp_sd) cp_specw[k] = cp_specw[k] (cp_specw[k] == "" ? "" : ", ") ml[i] " wanted " cp_sd[mk] " istiod replicas, " cp_rep[ml[i]] " at the sweep'"'"'s start"
		if (mk in cp_rn) cp_short[k] = cp_short[k] (cp_short[k] == "" ? "" : ", ") ml[i] " ran " cp_rn[mk] " of its " cp_rr[mk] " istiod replicas"
		else if (mk in cp_qn) cp_shortw[k] = cp_shortw[k] (cp_shortw[k] == "" ? "" : ", ") ml[i] " ran " cp_qn[mk] " of its " cp_qr[mk] " istiod replicas"
		if (mk in cp_nrp) { np = split(cp_nrp[mk], pl, " "); for (j = 1; j <= np; j++) cp_notready[k] = cp_notready[k] (cp_notready[k] == "" ? "" : ",") ml[i] "=" pl[j] }
		if (mk in cp_nep) { np = split(cp_nep[mk], pl, " "); for (j = 1; j <= np; j++) cp_notready_end[k] = cp_notready_end[k] (cp_notready_end[k] == "" ? "" : ",") ml[i] "=" pl[j] }
	}
	if (cp_nm[k] + 0 < cp_ms[k] + 0) return "INCOMPLETE"
	if ((k, ep) in cp_wa) {
		n = split(substr(cp_wm[k, ep], 2), ml, "\t")
		for (i = 1; i <= n; i++) {
			mk = k SUBSEP ep SUBSEP ml[i]
			if (cp_mr[mk] + 0 < cp_wx[mk]) { cp_why[k] = ml[i] " has " (cp_mr[mk] + 0) " of the " cp_wx[mk] " rows its window wrote"; return "INCOMPLETE" }
		}
		return ""
	}
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
# copied as they are; a line of 40 columns or more, but fewer than the header names (a row
# cut while it was written, CP_CELL_AWK cp_isrow), as a comment, "# CUT_ROW <line>", so no
# reader takes it for a row of another cell. A TSV without a recorded resume (a first run,
# or a growth series, which is never resumed) is otherwise copied whole. Prints "<rows left
# out><TAB><cells they belong to>"; returns non-zero, printing nothing, when awk fails
# (resumes.txt unreadable).
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
		{ data = !(/^#/ || /^timestamp\t/) && cp_isrow(); cut = !data && !/^#/ && !/^timestamp\t/ && NF >= 40 }
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
		cut { print "# CUT_ROW " $0 > out; next }
		{ print > out }
		END { if (bad) exit 2; close(out); printf "%d\t%d\n", drop, ndk }' "$tsv" "$tsv"
}

# controlplane_attempts <tsv> <resumes_txt>: the runs that wrote a controlplane TSV, and the
# harness changes within them, one line each, in the order they started:
#   <run>\t<HARNESS_SHA>\t<KUBE_VERSIONS>\t<rows>\t<ISTIO_NOTREADY>\t<ISTIO_PROXY_VERSIONS>
#     \t<ISTIO_GENERATIONS>\t<at>\t<kept>\t<HARNESS_CONTENT_KEY>\t<started_at>
# <run> is "first run" (its values from the TSV preamble; ISTIO_NOTREADY is its
# ISTIO_NOTREADY_AT_START), "--resume at <t>": from its resumes.txt line (a line whose TSV
# column names another file is not this TSV's), else from the TSV's own "# RESUMED_AT="
# line (both records of one start, the same time, are one run; a value neither records
# reads unknown), or "harness changed at <t> (in the first run)" / "(in the --resume at
# <t>)": a "# HARNESS_CHANGED_AT=" line 002 wrote before the rows of a window that ran
# other harness files than the TSV's last record (its HARNESS_SHA and HARNESS_CONTENT_KEY;
# KUBE_VERSIONS are its run's, the Istio reads n/a: it is no start). <rows> counts the data
# rows (measurements and status rows) from its start up to the next line's, the runs'
# starts read as controlplane_latest_attempts reads them (TSV_LINES, the "# RESUMED_AT="
# line, or in an older resumes.txt the first row of its time on): 0 for a run that added
# none (a --resume of a finished sweep, or one that stopped before its first cell). <kept>:
# those of them that are in their cell's latest attempt (the rows the figures use: a cell's
# rows of a run that a later --resume ran again are left out), so a run whose rows were all
# run again reads 0 too, and a report leaves either out of the provenance of the rows (PL2,
# PL15). <at>: the time as recorded (empty for the first run); <started_at>: the same in UTC
# with Z, the first run's from the preamble's first line (unknown when it has none). Each <t>
# in a <run> label is in that Z form too (the reports print the labels as prose). A first
# run that wrote no row reads "first run" with 0 rows; when it wrote no TSV either (it died
# first, or before the header line: the --resume that wrote the TSV records TSV_LINES 0),
# its values and <started_at> read unknown, as the preamble is that resume's. Returns
# non-zero when awk fails.
# shellcheck disable=SC2329
controlplane_attempts() {
	local tsv="$1" res="${2:-}"
	[[ -n "$res" && -f "$res" ]] || res=/dev/null
	awk -F'\t' -v res="$res" -v tname="${tsv##*/}" "${CP_CELL_AWK}"'
		function g(c) { return ((c in col) && n >= col[c] && f[col[c]] != "") ? f[col[c]] : "unknown" }
		function pk(k,    p) { p = "# " k "="; if (!(k in pre) && index($0, p) == 1) pre[k] = substr($0, length(p) + 1) }
		function pv(k) { return ((k in pre) && pre[k] != "") ? pre[k] : "unknown" }
		# lv(k): key k of this "# RESUMED_AT=" or "# HARNESS_CHANGED_AT=" line, up to the next
		# key it records (KUBE_VERSIONS, its last, to the end of the line); unknown when absent.
		# Its keys: those of the line itself, then the platform record before KUBE_VERSIONS
		# (PLATFORM_KEYS in tests/lib/platform.sh, which platform.bats checks against this list).
		function lv(k,    p, s, i, q, e) {
			if (!(p = index($0, " " k "="))) return "unknown"
			s = substr($0, p + length(k) + 2); e = length(s) + 1
			for (i = 1; i <= nlk; i++) if ((q = index(s, " " lk[i] "=")) && q < e) e = q
			s = substr(s, 1, e - 1)
			return (s == "" ? "unknown" : s)
		}
		function z(t) { sub(/\+00:00$/, "Z", t); return t }
		BEGIN {
			nlk = split("RESUMED_AT TSV_LINES HARNESS_SHA HARNESS_CONTENT_KEY ISTIO_NOTREADY_AT_RESUME ISTIO_GENERATIONS ISTIO_PROXY_VERSIONS PLATFORM TEST_PLATFORM PLATFORM_BY_CONTEXT MESH_OPERATOR_BY_CONTEXT ISTIOD_IMAGE_BY_CONTEXT PROXY_IMAGE_BY_CONTEXT NODE_PROVIDER_BY_CONTEXT ISTIOD_ENV_BY_CONTEXT TUNING_OBJECTS_BY_CONTEXT KUBE_VERSIONS HARNESS_CHANGED_AT", lk, " ")
			while ((r = (getline line < res)) > 0) {
				n = split(line, f, "\t")
				if (f[1] == "RESUMED_AT") { split("", col); for (i = 1; i <= n; i++) col[f[i]] = i; continue }
				if (n < 2 || f[1] == "") continue
				if (("TSV" in col) && n >= col["TSV"] && f[col["TSV"]] != "" && f[col["TSV"]] != tname) continue
				na++
				at[na] = f[1]; h[na] = g("HARNESS_SHA"); kv[na] = g("KUBE_VERSIONS"); nr[na] = g("ISTIO_NOTREADY_AT_RESUME")
				pxv[na] = g("ISTIO_PROXY_VERSIONS"); gen[na] = g("ISTIO_GENERATIONS"); hk[na] = g("HARNESS_CONTENT_KEY")
				pos[na] = (g("TSV_LINES") ~ /^[0-9]+$/) ? g("TSV_LINES") + 0 : -1
			}
			if (r < 0) { print "cannot read " res > "/dev/stderr"; exit 2 }
			close(res)
		}
		/^timestamp\t/ { hdr = 1; cp_header(); next }
		/^#/ {
			if (FNR == 1 && match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]([+-][0-9][0-9]:[0-9][0-9]|Z)$/)) t0 = substr($0, RSTART)
			if (!hdr) { pk("HARNESS_SHA"); pk("HARNESS_CONTENT_KEY"); pk("KUBE_VERSIONS"); pk("ISTIO_NOTREADY_AT_START"); pk("ISTIO_PROXY_VERSIONS"); pk("ISTIO_GENERATIONS") }
			if (index($0, "# HARNESS_CHANGED_AT=") == 1) { nc++; cpos[nc] = FNR; cat[nc] = lv("HARNESS_CHANGED_AT"); ch[nc] = lv("HARNESS_SHA"); ck[nc] = lv("HARNESS_CONTENT_KEY"); next }
			if (index($0, "# RESUMED_AT=") != 1 || (t = lv("RESUMED_AT")) == "unknown") next
			for (i = 1; i <= na; i++) if (at[i] == t && !(i in byline)) break
			if (i > na) { na++; at[na] = t; h[na] = "unknown"; hk[na] = "unknown"; kv[na] = "unknown"; nr[na] = "unknown"; pxv[na] = "unknown"; gen[na] = "unknown" }
			byline[i] = 1; pos[i] = FNR - 1
			# resumes.txt first; the line fills what it does not record.
			if (h[i] == "unknown") h[i] = lv("HARNESS_SHA")
			if (hk[i] == "unknown") hk[i] = lv("HARNESS_CONTENT_KEY")
			if (kv[i] == "unknown") kv[i] = lv("KUBE_VERSIONS")
			if (nr[i] == "unknown") nr[i] = lv("ISTIO_NOTREADY_AT_RESUME")
			if (pxv[i] == "unknown") pxv[i] = lv("ISTIO_PROXY_VERSIONS")
			if (gen[i] == "unknown") gen[i] = lv("ISTIO_GENERATIONS")
			next
		}
		cp_isrow() { nd++; dpos[nd] = FNR; dts[nd] = substr($1, 1, 19); dk[nd] = cp_key() }
		END {
			if (r < 0) exit 2
			last = NR
			# A start that only an older resumes.txt records (its time): before the first row
			# of that time on; none (it added no row): the end of the TSV.
			for (i = 1; i <= na; i++) if (pos[i] < 0) {
				pos[i] = last
				for (j = 1; j <= nd; j++) if (dts[j] >= substr(at[i], 1, 19)) { pos[i] = dpos[j] - 1; break }
			}
			# A resume that started at line 0 wrote the preamble (the TSV held no row): its
			# values and first line are that resume'"'"'s, not the first run'"'"'s.
			for (i = 1; i <= na; i++) if (pos[i] == 0) { split("", pre); t0 = "" }
			# Run 0, the first: position 0. Then the resumes by position (a stable sort: a
			# tie keeps their order, and the later one gets the rows).
			o[0] = 0; pos[0] = 0
			for (i = 1; i <= na; i++) {
				j = i
				while (j > 1 && pos[o[j - 1]] > pos[i]) { o[j] = o[j - 1]; j-- }
				o[j] = i
			}
			# Each row'"'"'s run, and each cell'"'"'s latest run (whose rows the figures keep).
			for (j = 1; j <= nd; j++) {
				a = 0
				for (b = 1; b <= na; b++) if (dpos[j] > pos[o[b]]) a = b
				ow[j] = a
				if (!(dk[j] in top) || a > top[dk[j]]) top[dk[j]] = a
			}
			# The lines: each run, then the harness changes in it (a change on the line just
			# before a resume starts is its run'"'"'s), and each row on the last one before it.
			for (c = 1; c <= nc; c++) { a = 0; for (b = 1; b <= na; b++) if (cpos[c] > pos[o[b]]) a = b; cown[c] = a }
			ne = 0
			for (a = 0; a <= na; a++) {
				et[++ne] = -1; ei[ne] = a; ent[a] = ne
				for (c = 1; c <= nc; c++) if (cown[c] == a) { et[++ne] = c; cent[c] = ne }
			}
			for (j = 1; j <= nd; j++) {
				e = ent[ow[j]]
				for (c = 1; c <= nc; c++) if (cown[c] == ow[j] && cpos[c] < dpos[j] && cent[c] > e) e = cent[c]
				rows[e]++
				if (ow[j] == top[dk[j]]) kept[e]++
			}
			for (e = 1; e <= ne; e++) {
				if (et[e] < 0) {
					a = ei[e]
					if (a == 0) printf "first run\t%s\t%s\t%d\t%s\t%s\t%s\t\t%d\t%s\t%s\n", pv("HARNESS_SHA"), pv("KUBE_VERSIONS"), rows[e], pv("ISTIO_NOTREADY_AT_START"), pv("ISTIO_PROXY_VERSIONS"), pv("ISTIO_GENERATIONS"), kept[e], pv("HARNESS_CONTENT_KEY"), (t0 == "" ? "unknown" : z(t0))
					else { i = o[a]; printf "--resume at %s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%d\t%s\t%s\n", z(at[i]), h[i], kv[i], rows[e], nr[i], pxv[i], gen[i], at[i], kept[e], hk[i], z(at[i]) }
					continue
				}
				c = et[e]; a = cown[c]; i = o[a]
				printf "harness changed at %s (in %s)\t%s\t%s\t%d\tn/a\tn/a\tn/a\t%s\t%d\t%s\t%s\n", z(cat[c]), (a == 0 ? "the first run" : "the --resume at " z(at[i])), ch[c], (a == 0 ? pv("KUBE_VERSIONS") : kv[i]), rows[e], cat[c], kept[e], ck[c], z(cat[c])
			}
		}' "$tsv"
}

# controlplane_resume_cmd <sweep_dir> <contexts_csv> <axis_flags> [<config>]: the command
# that resumes a controlplane sweep, from the repo root:
#   ./tests/controlplane/003-run-sweep.sh --resume <sweep_dir> --contexts <csv> <axis_flags>
#     [ --config <config>]
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

# JSON_STR_AWK: awk function js(x), x as a quoted JSON string (also a YAML double-quoted
# one, for a frontmatter): each \ and " escaped, a tab, carriage return and newline as \t,
# \r and \n, any other control character dropped. The one copy (tests/lib/verify.sh flags
# others): `awk "${JSON_STR_AWK}"'...'`. Pass the values through ENVIRON or stdin, never
# awk -v, which reads their backslashes as escapes (PL19).
# shellcheck disable=SC2016,SC2034  # awk source, read by the scripts that source this file
JSON_STR_AWK='function js(x) { gsub(/\\/, "\\\\", x); gsub(/"/, "\\\"", x); gsub(/\t/, "\\t", x); gsub(/\r/, "\\r", x); gsub(/\n/, "\\n", x); gsub(/[[:cntrl:]]/, "", x); return "\"" x "\"" }'

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

# --- sha256 and key=value tokens ---

# file_sha256 <file>: the file's hex sha256 (a --config file's RUN_CONFIG_SHA256, the platform
# record's istiod env digest, a resume's run config), or unknown when no hashing tool
# (sha256sum, shasum) works.
# shellcheck disable=SC2329
file_sha256() {
	local out=""
	if command -v sha256sum >/dev/null 2>&1; then
		out="$(sha256sum < "$1" 2>/dev/null)" || out=""
	elif command -v shasum >/dev/null 2>&1; then
		out="$(shasum -a 256 < "$1" 2>/dev/null)" || out=""
	fi
	out="${out%% *}"
	if [[ "$out" =~ ^[0-9a-f]{64}$ ]]; then echo "$out"; else echo unknown; fi
}

# each_bounded <max> <fn> <tmp> <item>...: run "<fn> <item> <tmp>/<i>" for each item in the
# background, <max> at a time (a whole number above zero, else 20: 500 members would otherwise
# start 500 reads, and their kubectl processes, at once), with its stdout in <tmp>/<i>.row and its
# stderr in <tmp>/<i>.warn (<i>: the item's index; files by index, since a context name can hold
# a /), and wait for all of them. The pool runs in a subshell of its own, so its waits see only
# its jobs, never one of the caller's. <fn> sees the caller's variables (a local array included).
# shellcheck disable=SC2329
each_bounded() {
	local _eb_max="$1" _eb_fn="$2" _eb_tmp="$3"
	shift 3
	[[ "$_eb_max" =~ ^[1-9][0-9]*$ ]] || _eb_max=20
	(
		local _eb_i _eb_n=0
		local -a _eb_m=("$@")
		for _eb_i in "${!_eb_m[@]}"; do
			if ((_eb_n >= _eb_max)); then
				wait -n || true
				_eb_n=$((_eb_n - 1))
			fi
			mkdir -p "${_eb_tmp}/${_eb_i}"
			("$_eb_fn" "${_eb_m[_eb_i]}" "${_eb_tmp}/${_eb_i}" >"${_eb_tmp}/${_eb_i}.row" 2>"${_eb_tmp}/${_eb_i}.warn") &
			_eb_n=$((_eb_n + 1))
		done
		wait
	)
}

# kv_value <key> <tokens>: the value of <key>=... among whitespace-separated "k=v" tokens (what
# cap_istiod_limits, cap_node_totals, env_collect_infra and the growth probes print), or
# unknown without one. The tokens are split without pathname expansion.
# shellcheck disable=SC2329
kv_value() {
	local _kv_t
	local -a _kv_toks=()
	read -r -d '' -a _kv_toks <<<"$2" || true
	for _kv_t in ${_kv_toks[@]+"${_kv_toks[@]}"}; do
		if [[ "$_kv_t" == "${1}="* ]]; then
			printf '%s\n' "${_kv_t#"${1}="}"
			return 0
		fi
	done
	echo unknown
}

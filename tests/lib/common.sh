#!/usr/bin/env bash
# Shared utility functions sourced by all test suites.
# Sourced, never executed.
#
# Consumers: churn, churn-dataplane, controlplane, dataplane, propagation, tuning, gateway-api
#
# Exposes:
#   die <msg>                         -> exit 1 with stderr message (and keep <msg> as the
#                                        stop reason a sweep's EXIT trap records)
#   awk_untyped_ok <awk>              -> true when <awk> keeps an unset array element intact
#                                        after passing it to a function (gawk 5.2, 5.3 do not);
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
#   validate_scoping <val> [<name>]   -> die if val is not none|namespace|explicit|wide,
#                                        naming <name> (default: --sidecar-scoping)
#   resolve_kubectl <out_arrayname>   -> set the named array to (kubectl) or (oc)
#   validate_traffic_config <val>     -> die if val is not none|vsdr
#   vsdr_service_count <svc> <every>  -> services that get a VS+DR (i mod every == 0)
#   validate_workload_mode <val>      -> die if val is not pods|config-only
#   validate_outside_mode <val>       -> die if val is not none|unlabeled|labeled
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
#                                        report but a cell failed or a problem was recorded
#   sweep_settings_check              -> die on a SWEEP_STOP_GRACE_SEC that is no number of
#                                        seconds (sweep_start's check, for a --dry-run too)
#   sweep_start <dir> <run_id> [--unit <noun>] [--cleanup <fn>]
#                                     -> the record sweep-outcome.txt (STATUS=running), the
#                                        HUP, INT, TERM and EXIT traps
#   sweep_step <cmd...>               -> run a step in its own process group, so a signal
#                                        stops all of it (SWEEP_STOP_GRACE_SEC, then SIGKILL)
#   sweep_problem <msg>, sweep_note <msg>
#                                     -> a PROBLEM= (exit 4) or NOTE= line of the record
#   sweep_finish [--stopped <rc> --stop-reason <why>] [--where <text>] <total> [<reason>...]
#                                     -> the closing lines and the final record, one reason
#                                        per failed or skipped cell; returns the exit code
#   sweep_err_trap <rc> <line> <cmd>  -> a sweep's ERR trap: the FATAL line, kept as the
#                                        stop reason; exits 1 (a signal's 129/130/143 kept)
#   sweep_outcome_lines <fmt> <path>...
#                                     -> what the records of a report's sweeps say (text, md,
#                                        charts, json, csv; verdict: the ones to caution on)
#   harness_sha [--exclude <dir>]...  -> the harness the run uses: git describe, -dirty.<8hex>
#                                        (a hash of the changes) when tests/ config/ charts/
#                                        terraform/ have changes
#   CP_CELL_AWK                       -> awk functions for a controlplane cell's state
#                                        (done, its status, INCOMPLETE)
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
# when it dies after its start (_sweep_on_exit; _SWEEP_STOP_BY says it came from die).
# shellcheck disable=SC2329
die() { _SWEEP_STOP_WHY="$*" _SWEEP_STOP_BY=die; echo "error: $*" >&2; exit 1; }

# awk_untyped_ok <awk>: true when <awk> keeps an array element that holds no value yet intact
# after passing it to a function. gawk 5.2 and 5.3 (5.2.1 and 5.3.2 checked; 5.1 keeps it) do
# not: a later number read of the element returns garbage, and on 5.3 a later comparison of it
# stops awk with "fixtype: expected Node_val: got Node_var". The reports pass such elements (a
# count no row filled), so a run never uses that awk: when awk on PATH fails this check,
# tests/lib/awk-mawk (awk run as mawk) goes first on PATH if mawk passes it, else the run stops
# here.
awk_untyped_ok() {
	"$1" 'function f(v) { return v ~ /x/ } BEGIN { f(a[1]); if (a[1] == "" && a[1] + 0 == 0) exit 0; exit 1 }' \
		</dev/null >/dev/null 2>&1
}
if ! awk_untyped_ok awk; then
	if command -v mawk >/dev/null 2>&1 && awk_untyped_ok mawk; then
		PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/awk-mawk:${PATH}"
		export PATH
	else
		die "awk on PATH ($(awk --version 2>/dev/null | head -n 1 || true)) corrupts an array element passed to a function before it holds a value (a gawk 5.2 and 5.3 bug), and the reports do that, so its figures could be wrong. Install mawk (dnf, apt or brew install mawk); the harness then runs awk as mawk on its own."
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
# it marks the cell failed.
# shellcheck disable=SC2329
tsv_end_line() {
	[[ ! -s "$1" || -z "$(tail -c 1 "$1" 2>/dev/null)" ]] || printf '\n' >> "$1"
}

# shellcheck disable=SC2329
validate_scoping() {
	case "$1" in
	none | namespace | wide | explicit) return 0 ;;
	*) die "${2:---sidecar-scoping} must be one of [none, namespace, explicit, wide]; got '$1'" ;;
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
# step reaches them in the step's process group. On expiry only cmd gets the signal, not processes it
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

# --- sweep start, steps, stop and outcome ---

# Exit codes every sweep shares: 0 every cell ran; 1 the run stopped (a precondition, an
# unexpected abort, or a suite's own stop such as controlplane's RETIRE_FAILED); 3 a
# reachability gate stopped it (dataplane, churn-dataplane); 4 it finished and wrote its
# report, but at least one cell failed (its setup or probe step exited non-zero, and the
# results name the reason) or a problem was recorded (sweep_problem: the Istio version or
# the harness changed under it); 128+n a signal stopped it (129 SIGHUP, 130 Ctrl-C, 143
# SIGTERM). A stop wins: 1 and 3 are not replaced by 4. A cell a guard skipped on purpose
# (controlplane's memory guard) is reported apart and is not a failure.
# shellcheck disable=SC2034  # read by the sweeps that source this file
SWEEP_FAILED_EXIT=4

# The problems and notes a sweep gathers (sweep_problem, sweep_note), also before its start.
_SWEEP_PROBLEMS=() _SWEEP_NOTES=()

# _sweep_outcome_by <reason>...: "A x2, B x1" (sorted by reason).
_sweep_outcome_by() {
	printf '%s\n' "$@" | sort | uniq -c | awk '{ printf "%s%s x%d", (NR > 1 ? ", " : ""), $2, $1 }'
}

# sweep_problem <msg>: the sweep failed although its cells ran (exit 4). sweep_note <msg>: a
# caveat to keep, not a failure. Each is one PROBLEM= or NOTE= line of the sweep's record
# (sweep_finish, or the EXIT trap of a sweep that did not finish) and of every report.
# shellcheck disable=SC2329
sweep_problem() { _SWEEP_PROBLEMS+=("${*//$'\n'/ }"); }
# shellcheck disable=SC2329
sweep_note() { _SWEEP_NOTES+=("${*//$'\n'/ }"); }

# sweep_settings_check: die when SWEEP_STOP_GRACE_SEC is not a non-negative integer of
# seconds. sweep_start checks it; a sweep calls it with its other checks, before its
# --dry-run plan, so a dry run catches it too.
# shellcheck disable=SC2329
sweep_settings_check() {
	is_nonneg_int "${SWEEP_STOP_GRACE_SEC:-30}" \
		|| die "SWEEP_STOP_GRACE_SEC must be a non-negative integer of seconds (got: ${SWEEP_STOP_GRACE_SEC}); see config/options.env"
}

# sweep_start <dir> <run_id> [--unit <noun>] [--cleanup <fn>]: a sweep calls it as a plain
# command before its first step (never under --dry-run). Dies when SWEEP_STOP_GRACE_SEC is
# not a non-negative integer (sweep_settings_check). Then writes
# the record <dir>/sweep-outcome.txt: STATUS=running, RUN_ID, HARNESS_SHA (the sweep's, read
# without <dir> when it is not set), STARTED_AT (UTC) and UNIT (<noun>, plural: cells, or
# tuning's passes), and traps HUP, INT, TERM (_sweep_on_signal) and EXIT (_sweep_on_exit,
# which runs <fn> once when the sweep ends before sweep_finish).
# shellcheck disable=SC2329
sweep_start() {
	local _sw_dir="$1" _sw_rid="$2"
	shift 2
	_SWEEP_UNIT=cells _SWEEP_CLEANUP=""
	while (($#)); do
		case "$1" in
		--unit) _SWEEP_UNIT="$2"; shift 2 ;;
		--cleanup) _SWEEP_CLEANUP="$2"; shift 2 ;;
		*) die "sweep_start: unknown argument: $1" ;;
		esac
	done
	sweep_settings_check
	mkdir -p "$_sw_dir" || die "could not create the sweep dir ${_sw_dir}"
	_SWEEP_DIR="$_sw_dir" _SWEEP_RUN_ID="$_sw_rid" _SWEEP_PID="${BASHPID:-$$}" _SWEEP_STATE=running _SWEEP_SIGNAL=""
	_SWEEP_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	[[ -n "${HARNESS_SHA:-}" ]] || HARNESS_SHA="$(harness_sha --exclude "$_sw_dir")"
	_SWEEP_HARNESS_SHA="$HARNESS_SHA"
	trap '_sweep_on_exit' EXIT
	trap '_sweep_on_signal HUP 1' HUP
	trap '_sweep_on_signal INT 2' INT
	trap '_sweep_on_signal TERM 15' TERM
	_sweep_record running || die "could not write ${_sw_dir}/sweep-outcome.txt"
}

# _sweep_record <status> [<KEY=value>...]: write the sweep's record whole (through a temp
# file, so a report never reads half of it): STATUS, the start's keys, the given lines,
# then one PROBLEM= and NOTE= line each.
# shellcheck disable=SC2329
_sweep_record() {
	local f="${_SWEEP_DIR}/sweep-outcome.txt" l
	{
		echo "# Sweep outcome (tests/lib/common.sh): STATUS=running until the sweep ends"
		echo "STATUS=$1"
		shift
		echo "RUN_ID=${_SWEEP_RUN_ID:-unknown}"
		echo "HARNESS_SHA=${_SWEEP_HARNESS_SHA:-unknown}"
		echo "STARTED_AT=${_SWEEP_STARTED_AT:-}"
		echo "UNIT=${_SWEEP_UNIT:-cells}"
		for l in "$@"; do echo "$l"; done
		for l in ${_SWEEP_PROBLEMS[@]+"${_SWEEP_PROBLEMS[@]}"}; do echo "PROBLEM=${l}"; done
		for l in ${_SWEEP_NOTES[@]+"${_SWEEP_NOTES[@]}"}; do echo "NOTE=${l}"; done
	} 2>/dev/null > "${f}.tmp" && mv -f "${f}.tmp" "$f" 2>/dev/null
}

# _sweep_mask <text>: <text> on one line, with the sweep dir as <sweep dir> and $HOME as ~
# (a record travels with its results).
# shellcheck disable=SC2329
_sweep_mask() {
	local t="${1//$'\n'/ }" abs tilde='~'
	abs="$(cd "${_SWEEP_DIR:-.}" 2>/dev/null && pwd)" || abs=""
	[[ -z "$abs" ]] || t="${t//"$abs"/<sweep dir>}"
	[[ -z "${_SWEEP_DIR:-}" ]] || t="${t//"$_SWEEP_DIR"/<sweep dir>}"
	if [[ -n "${HOME:-}" && "$HOME" != / ]]; then t="${t//"$HOME"/"$tilde"}"; fi
	printf '%s' "$t"
}

# sweep_step <cmd> [<arg>...]: run one step of a sweep (a setup, a probe, a cleanup, a
# profile apply or revert) as a background job in a process group of its own, wait for it
# and return its exit status. A trapped signal ends that wait at once (a foreground command
# would hold the trap until it returned), and _sweep_on_signal stops the step's whole group,
# the processes it started included. Its stdin is /dev/null (no step reads the terminal);
# it keeps the sweep's stdout and stderr, so a call can log them with a redirection:
# `sweep_step "$probe" "${args[@]}" > >(tee -a "$log") 2>&1`. The wait's own stderr goes to
# /dev/null: bash prints a job notice there for a step SIGKILL ended ("... Killed ...").
# shellcheck disable=SC2329
sweep_step() {
	local _sw_src=0
	_SWEEP_STEP_NAME="${1##*/}"
	set -m
	"$@" </dev/null &
	_SWEEP_STEP_PID=$!
	set +m
	wait "$_SWEEP_STEP_PID" 2>/dev/null || _sw_src=$?
	_SWEEP_STEP_PID=""
	return "$_sw_src"
}

# _sweep_step_stop: SIGTERM to the running step's process group, up to SWEEP_STOP_GRACE_SEC
# for all of it to end (the probes' own EXIT traps remove what they created), then
# _sweep_step_kill. A zombie still counts as running until it is reaped.
# shellcheck disable=SC2329
_sweep_step_stop() {
	local _sw_pid="${_SWEEP_STEP_PID:-}" _sw_grace="${SWEEP_STOP_GRACE_SEC:-30}" _sw_i
	[[ -n "$_sw_pid" ]] || return 0
	is_nonneg_int "$_sw_grace" || _sw_grace=30
	echo "Stopping the running step (${_SWEEP_STEP_NAME:-PID ${_sw_pid}}): SIGTERM to its process group; SIGKILL to what still runs ${_sw_grace}s later (SWEEP_STOP_GRACE_SEC)." >&2 || true
	kill -TERM -- "-${_sw_pid}" 2>/dev/null || true
	for ((_sw_i = 0; _sw_i < _sw_grace * 5; _sw_i++)); do
		kill -0 -- "-${_sw_pid}" 2>/dev/null || break
		sleep 0.2
	done
	_sweep_step_kill
}

# _sweep_step_kill: SIGKILL the running step's process group (nothing when no step runs)
# and reap it quietly.
# shellcheck disable=SC2329
_sweep_step_kill() {
	local _sw_pid="${_SWEEP_STEP_PID:-}"
	[[ -n "$_sw_pid" ]] || return 0
	kill -KILL -- "-${_sw_pid}" 2>/dev/null || true
	wait "$_sw_pid" 2>/dev/null || true
	_SWEEP_STEP_PID=""
}

# _sweep_on_signal <name> <number>: the HUP, INT and TERM traps of sweep_start. Like any
# trap, it runs once the foreground command returns (sweep_step's wait returns at once).
# Keeps the signal, stops the running step (_sweep_step_stop) and exits 128+<number>; the
# EXIT trap records the interrupt. A second signal, or one while the EXIT trap runs the
# cleanup, kills the step's group at once and exits. SIGPIPE is ignored from here on: under
# `sweep ... 2>&1 | tee log`, Ctrl-C ends tee too, and the next message would kill the sweep
# before it stops the step.
# shellcheck disable=SC2329
_sweep_on_signal() {
	local _sw_rc=$((128 + $2))
	trap '' PIPE
	if [[ -n "${_SWEEP_SIGNAL:-}" || "${_SWEEP_STATE:-}" == exiting ]]; then
		_sweep_step_kill
		if [[ "${_SWEEP_STATE:-}" == exiting ]]; then
			echo "warning: SIG$1 cut the sweep's cleanup short${SWEEP_CLEANUP_CMD:+; clean up with: ${SWEEP_CLEANUP_CMD}}" >&2 || true
		fi
		exit "$_sw_rc"
	fi
	_SWEEP_SIGNAL="$1"
	_sweep_step_stop
	exit "$_sw_rc"
}

# _sweep_on_exit: the EXIT trap of sweep_start. A step a second signal left running is
# killed first. Once sweep_finish ran, that is all. Else the sweep ended before
# its end, and its record is rewritten at once (a second Ctrl-C during a long cleanup keeps
# it): STATUS=interrupted with SIGNAL (Ctrl-C, SIGTERM, a closed terminal; a command such a
# signal killed counts too: its exit 129, 130 or 143 through sweep_err_trap), else
# STATUS=stopped with STOP_REASON (die's message, sweep_err_trap's script, line and command,
# or "it exited <rc> before its end"; masked by _sweep_mask), with EXIT (128+n, or 1 for a
# stop), ENDED_AT and the problems and notes so far. Then the cleanup sweep_start named runs
# once (what it adds is recorded too), and stderr names the sweep dir and the
# suite's cleanup command (SWEEP_CLEANUP_CMD, which each sweep sets). Never dies. The cleanup
# runs inside it, and inside the signal trap and sweep_step when a signal ended the sweep,
# so their locals are named _sw_*: one named like a sweep's global (controlplane's rc, the
# cell's replica count) would shadow it in the cleanup.
# shellcheck disable=SC2329
_sweep_on_exit() {
	local _sw_rc=$? _sw_sig="${_SWEEP_SIGNAL:-}" _sw_now _sw_np _sw_nn _sw_why
	local -a _sw_rec=()
	[[ "${BASHPID:-$$}" == "${_SWEEP_PID:-}" ]] || return 0
	trap '' PIPE
	_sweep_step_kill
	[[ "${_SWEEP_STATE:-}" == running ]] || return 0
	_SWEEP_STATE=exiting
	if [[ -z "$_sw_sig" && "${_SWEEP_STOP_BY:-}" == err ]]; then
		case "${_SWEEP_STOP_RC:-}" in 129) _sw_sig=HUP ;; 130) _sw_sig=INT ;; 143) _sw_sig=TERM ;; esac
	fi
	_sw_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	if [[ -n "$_sw_sig" ]]; then
		case "$_sw_sig" in HUP) _sw_rc=129 ;; INT) _sw_rc=130 ;; *) _sw_rc=143 ;; esac
		_sw_rec=(interrupted "SIGNAL=SIG${_sw_sig}" "EXIT=${_sw_rc}" "ENDED_AT=${_sw_now}")
		echo "warning: the sweep was interrupted (SIG${_sw_sig}); its results may be partial" >&2 || true
	else
		_sw_why="${_SWEEP_STOP_WHY:-}"
		[[ -n "$_sw_why" ]] || _sw_why="it exited ${_sw_rc} before its end (see its console output)"
		_sw_rc=1
		_sw_rec=(stopped "EXIT=1" "ENDED_AT=${_sw_now}" "STOP_REASON=$(_sweep_mask "$_sw_why")")
		echo "error: the sweep stopped before its end; its results may be partial" >&2 || true
	fi
	_sweep_record "${_sw_rec[@]}" || echo "warning: could not write ${_SWEEP_DIR}/sweep-outcome.txt" >&2 || true
	if [[ -n "${_SWEEP_CLEANUP:-}" ]]; then
		_sw_np=${#_SWEEP_PROBLEMS[@]} _sw_nn=${#_SWEEP_NOTES[@]}
		"$_SWEEP_CLEANUP" || echo "warning: the sweep's cleanup (${_SWEEP_CLEANUP}) failed" >&2 || true
		if ((${#_SWEEP_PROBLEMS[@]} != _sw_np || ${#_SWEEP_NOTES[@]} != _sw_nn)); then
			_sweep_record "${_sw_rec[@]}" || echo "warning: could not write ${_SWEEP_DIR}/sweep-outcome.txt" >&2 || true
		fi
	fi
	_SWEEP_STATE=ended
	{
		echo "  sweep dir: ${_SWEEP_DIR}"
		[[ -z "${SWEEP_CLEANUP_CMD:-}" ]] || echo "  clean up with: ${SWEEP_CLEANUP_CMD}"
	} >&2 2>/dev/null || true
	exit "$_sw_rc"
}

# sweep_err_trap <rc> <line> <command>: the body of a sweep's ERR trap (set -e is about to
# stop the sweep): the FATAL line on stderr, kept as the stop reason the EXIT trap records
# (_SWEEP_STOP_BY=err, _SWEEP_STOP_RC: the failed command's exit). Install it as
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

# sweep_finish [--stopped <rc> --stop-reason <why>] [--where <text>]
#              [--problem <msg>|--note <msg>]... <total> [<reason>...]:
# the end of a sweep: after its last step, its end checks and its cleanup, before its
# reports, which then read the final record. One <reason> per cell without a measurement: a
# SKIPPED_* reason counts as skipped, any other as failed. --problem and --note add one
# (sweep_problem, sweep_note); the harness read again (harness_sha, without the sweep dir)
# is a problem when it is not the start's. Prints "All <total> <unit> ran (...)." or "<k> of <total>
# <unit> were skipped on purpose, not failed: SKIPPED_<X> x<k>." on stdout, and "error: <n>
# of <total> <unit> failed: <REASON> x<k>, .... <where>; exit 4.", each problem as "error:"
# and each note as "note:" on stderr (<where>: where a failed cell shows in the results,
# default the report's placeholder rows). Writes the record: STATUS=finished (stopped with
# --stopped), EXIT, ENDED_AT, TOTAL, FAILED, FAILED_BY, SKIPPED, SKIPPED_BY, STOP_REASON and
# the PROBLEM= and NOTE= lines. Returns <rc> when stopped (1, or 3 for a reachability gate),
# else SWEEP_FAILED_EXIT when a cell failed or a problem was recorded, else 0: the sweep's
# exit code. A <total> that is not a number is recorded as unknown (no "All ... ran"), and
# with no <reason> so are FAILED and SKIPPED (how many cells failed is not known either).
# shellcheck disable=SC2329
sweep_finish() {
	local _sw_stop="" _sw_why="" _sw_where="" _sw_total _sw_r _sw_byf="" _sw_bys="" _sw_rc=0 _sw_tail _sw_hs
	local _sw_unit="${_SWEEP_UNIT:-cells}" _sw_nf _sw_ns
	local -a _sw_failed=() _sw_skipped=()
	while (($#)); do
		case "$1" in
		--stopped) _sw_stop="$2"; shift 2 ;;
		--stop-reason) _sw_why="$2"; shift 2 ;;
		--where) _sw_where="$2"; shift 2 ;;
		--problem) sweep_problem "$2"; shift 2 ;;
		--note) sweep_note "$2"; shift 2 ;;
		*) break ;;
		esac
	done
	_sw_total="${1:-unknown}"
	(($# == 0)) || shift
	is_nonneg_int "$_sw_total" || _sw_total=unknown
	if [[ -n "${_SWEEP_HARNESS_SHA:-}" ]]; then
		_sw_hs="$(harness_sha --exclude "$_SWEEP_DIR")"
		[[ "$_sw_hs" == "$_SWEEP_HARNESS_SHA" ]] \
			|| sweep_problem "the harness changed during the sweep: ${_SWEEP_HARNESS_SHA} at its start, ${_sw_hs} at its end; don't edit or check out files in this checkout while a sweep runs"
	fi
	[[ -n "$_sw_where" ]] || _sw_where="The report includes them as placeholder rows (in n_total, not n_valid)"
	for _sw_r in "$@"; do
		if [[ "$_sw_r" == SKIPPED_* ]]; then _sw_skipped+=("$_sw_r"); else _sw_failed+=("$_sw_r"); fi
	done
	((${#_sw_failed[@]} == 0)) || _sw_byf="$(_sweep_outcome_by "${_sw_failed[@]}")"
	((${#_sw_skipped[@]} == 0)) || _sw_bys="$(_sweep_outcome_by "${_sw_skipped[@]}")"
	if ((${#_sw_failed[@]} || ${#_SWEEP_PROBLEMS[@]})); then _sw_rc="$SWEEP_FAILED_EXIT"; fi
	[[ -z "$_sw_stop" ]] || _sw_rc="$_sw_stop"
	_sw_tail="; exit ${SWEEP_FAILED_EXIT}."
	[[ -z "$_sw_stop" ]] || _sw_tail="; the sweep also stopped early, so it exits ${_sw_stop}, not ${SWEEP_FAILED_EXIT}."
	if [[ -z "$_sw_stop" && "$_sw_total" != unknown && ${#_sw_failed[@]} -eq 0 && ${#_sw_skipped[@]} -eq 0 ]]; then
		echo "All ${_sw_total} ${_sw_unit} ran (their rows' own statuses are in the report)."
	elif ((${#_sw_skipped[@]})); then
		echo "${#_sw_skipped[@]} of ${_sw_total} ${_sw_unit} were skipped on purpose, not failed: ${_sw_bys}."
	fi
	((${#_sw_failed[@]} == 0)) || echo "error: ${#_sw_failed[@]} of ${_sw_total} ${_sw_unit} failed: ${_sw_byf}. ${_sw_where}${_sw_tail}" >&2
	for _sw_r in ${_SWEEP_PROBLEMS[@]+"${_SWEEP_PROBLEMS[@]}"}; do echo "error: ${_sw_r}${_sw_tail}" >&2; done
	for _sw_r in ${_SWEEP_NOTES[@]+"${_SWEEP_NOTES[@]}"}; do echo "note: ${_sw_r}." >&2; done
	_sw_nf=${#_sw_failed[@]} _sw_ns=${#_sw_skipped[@]}
	if [[ "$_sw_total" == unknown ]] && ((_sw_nf + _sw_ns == 0)); then _sw_nf=unknown _sw_ns=unknown; fi
	if [[ -n "${_SWEEP_DIR:-}" ]]; then
		_sweep_record "$([[ -n "$_sw_stop" ]] && echo stopped || echo finished)" "EXIT=${_sw_rc}" \
			"ENDED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)" "TOTAL=${_sw_total}" "FAILED=${_sw_nf}" "FAILED_BY=${_sw_byf}" \
			"SKIPPED=${_sw_ns}" "SKIPPED_BY=${_sw_bys}" "STOP_REASON=$(_sweep_mask "$_sw_why")" \
			|| echo "warning: could not write ${_SWEEP_DIR}/sweep-outcome.txt" >&2
		_SWEEP_STATE=ended
	fi
	return "$_sw_rc"
}

# sweep_outcome_lines <text|md|charts|json|csv|verdict> <path>...: what the records of the
# sweeps behind a report say, for that report. Each <path> is a sweep dir or a file in one
# (a report passes its input TSVs); each dir is read once, in order, and one without a
# sweep-outcome.txt adds nothing (a run that stopped before its start, or a probe run
# alone). Per record, named by its dir's name: running: a warning that the sweep has not
# finished (it died, or it still runs), so the results may be partial; interrupted: a
# warning naming the signal and when; stopped: an error with the reason; failed cells: an
# error "<n> of <total> <unit> failed: ..."; each PROBLEM an error, each NOTE a warning,
# skipped cells a note; a finished record with none of these: "all <total> <unit> ran".
# text and md print a block per record (charts: md, only the records with something to
# say); json one array, the value of a report's sweep_outcomes key, of {dir, status, exit,
# total, failed, failed_by, skipped, skipped_by, stop_reason, signal, ended_at, problems,
# notes} (null when absent; [] without a record); csv a "# SWEEP_OUTCOME_DIR=<dir>" line,
# then each line of the record as "# SWEEP_OUTCOME_<KEY>=<value>". verdict: one line
# naming each record that is not finished, or names a failed cell or a problem ("<dir>:
# <status>[, <n> failed][, <n> problem(s)]", joined by "; "), nothing when none does.
# shellcheck disable=SC2329
sweep_outcome_lines() {
	local fmt="$1" p d
	local -a sol_f=()
	local -A sol_seen=()
	shift
	for p in "$@"; do
		d="$p"
		if [[ ! -d "$d" ]]; then
			d="${p%/*}"
			[[ "$p" == */* ]] || d=.
		fi
		[[ -z "${sol_seen[$d]+x}" ]] || continue
		sol_seen[$d]=1
		[[ ! -f "${d}/sweep-outcome.txt" ]] || sol_f+=("${d}/sweep-outcome.txt")
	done
	if ((${#sol_f[@]} == 0)); then
		[[ "$fmt" != json ]] || echo '[]'
		return 0
	fi
	awk -v fmt="$fmt" "${JSON_STR_AWK}"'
		function num(v) { return v ~ /^[0-9]+$/ }
		function jn(v) { return num(v) ? v : "null" }
		function jsn(v) { return v == "" ? "null" : js(v) }
		function jl(a, r, n,    i, s) { s = "["; for (i = 1; i <= n; i++) s = s (i > 1 ? "," : "") js(a[r, i]); return s "]" }
		function li(kind, text) { if (fmt == "text") printf "  %s: %s\n", kind, text; else printf "> - %s: %s\n", kind, text }
		FNR == 1 {
			n++; d = FILENAME; sub(/\/sweep-outcome\.txt$/, "", d); sub(/.*\//, "", d); DIR[n] = d
			if (fmt == "csv") printf "# SWEEP_OUTCOME_DIR=%s\n", d
		}
		/^#/ || !/^[A-Z_]+=/ { next }
		{
			k = substr($0, 1, index($0, "=") - 1); v = substr($0, index($0, "=") + 1)
			if (fmt == "csv") printf "# SWEEP_OUTCOME_%s=%s\n", k, v
			if (k == "PROBLEM") PR[n, ++NP[n]] = v
			else if (k == "NOTE") NT[n, ++NN[n]] = v
			else V[n, k] = v
		}
		END {
			if (fmt == "csv") exit
			for (r = 1; r <= n; r++) {
				st = V[r, "STATUS"]; if (st == "") st = "unknown"
				unit = V[r, "UNIT"]; if (unit == "") unit = "cells"
				tot = V[r, "TOTAL"]; if (tot == "") tot = "unknown"
				fl = V[r, "FAILED"] + 0; sk = V[r, "SKIPPED"] + 0; np = NP[r] + 0; nn = NN[r] + 0
				if (fmt == "json") {
					out = out (r > 1 ? "," : "") sprintf("{\"dir\":%s,\"status\":%s,\"exit\":%s,\"total\":%s,\"failed\":%s,\"failed_by\":%s,\"skipped\":%s,\"skipped_by\":%s,\"stop_reason\":%s,\"signal\":%s,\"ended_at\":%s,\"problems\":%s,\"notes\":%s}", js(DIR[r]), js(st), jn(V[r, "EXIT"]), jn(V[r, "TOTAL"]), jn(V[r, "FAILED"]), jsn(V[r, "FAILED_BY"]), jn(V[r, "SKIPPED"]), jsn(V[r, "SKIPPED_BY"]), jsn(V[r, "STOP_REASON"]), jsn(V[r, "SIGNAL"]), jsn(V[r, "ENDED_AT"]), jl(PR, r, np), jl(NT, r, nn))
					continue
				}
				if (fmt == "verdict") {
					if (st != "finished" || fl > 0 || np > 0)
						out = out (out == "" ? "" : "; ") DIR[r] ": " st (fl > 0 ? ", " fl " failed" : "") (np > 0 ? ", " np " problem(s)" : "")
					continue
				}
				if (st == "finished" && num(tot) && fl + sk + np + nn == 0) {
					if (fmt == "text") printf "SWEEP OUTCOME (%s): all %s %s ran\n\n", DIR[r], tot, unit
					else if (fmt == "md") printf "> **Sweep outcome** (`%s`): all %s %s ran\n\n", DIR[r], tot, unit
					continue
				}
				ex = V[r, "EXIT"] == "" ? "" : ", exit " V[r, "EXIT"]
				if (fmt == "text") printf "SWEEP OUTCOME (%s): %s%s\n", DIR[r], toupper(st), ex
				else printf "> **Sweep outcome** (`%s`): **%s**%s\n", DIR[r], st, ex
				if (st == "running") li("warning", "the sweep has not finished (it died, or it still runs): these results may be partial")
				else if (st == "interrupted") li("warning", "the sweep was interrupted (" V[r, "SIGNAL"] ") at " V[r, "ENDED_AT"] ": these results may be partial")
				else if (st == "stopped") li("error", "the sweep stopped early: " (V[r, "STOP_REASON"] == "" ? "no reason recorded" : V[r, "STOP_REASON"]))
				if (fl > 0) li("error", fl " of " tot " " unit " failed: " V[r, "FAILED_BY"])
				for (i = 1; i <= np; i++) li("error", PR[r, i])
				for (i = 1; i <= nn; i++) li("warning", NT[r, i])
				if (sk > 0) li("note", sk " of " tot " " unit " were skipped on purpose, not failed: " V[r, "SKIPPED_BY"])
				printf "\n"
			}
			if (fmt == "json") print "[" out "]"
			else if (fmt == "verdict" && out != "") print out
		}' "${sol_f[@]}"
}

# --- the harness a run uses (PL2) ---

# harness_sha [--exclude <dir>]...: the harness the run uses (PL2): `git -C "${ROOT:-.}"
# describe --always --abbrev=7` (an annotated hand-over tag shows), plus -dirty.<8hex> when git
# lists a tracked change, or an untracked file it does not ignore, under tests/, config/,
# charts/ or terraform/ (submodules, the bats checkouts, never count); unknown when git
# cannot answer. The untracked files under each <dir> that exists (a run's output dir
# inside the checkout) do not count, and neither do those under HARNESS_SHA_EXCLUDE, the
# output dir a sweep exports, so its steps leave it out too. The hex: the first 8 of `git
# hash-object` over the diff against HEAD and the counted untracked files' names and
# contents, so two different edits read as two harnesses (and an edit during a sweep
# changes it).
# shellcheck disable=SC2329
harness_sha() {
	local root="${ROOT:-.}" v s h top d rel
	local -a spec=(':(top,literal)tests' ':(top,literal)config' ':(top,literal)charts' ':(top,literal)terraform') dirs=()
	while (($#)); do
		case "$1" in
		--exclude) [[ -z "${2:-}" ]] || dirs+=("$2"); shift 2 || shift ;;
		*) shift ;;
		esac
	done
	[[ -z "${HARNESS_SHA_EXCLUDE:-}" ]] || dirs+=("$HARNESS_SHA_EXCLUDE")
	v="$(git -C "$root" describe --always --abbrev=7 2>/dev/null)" || v=""
	top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || top=""
	if [[ -z "$v" || -z "$top" ]] || ! top="$(cd "$top" 2>/dev/null && pwd -P)"; then
		echo unknown
		return 0
	fi
	for d in ${dirs[@]+"${dirs[@]}"}; do
		d="$(cd "$d" 2>/dev/null && pwd -P)" || continue
		rel="${d#"$top"/}"
		[[ "$rel" == "$d" || -z "$rel" ]] || spec+=(":(exclude,top,literal)${rel}")
	done
	# No optional lock: a read never holds up the operator's own git command.
	s="$(GIT_OPTIONAL_LOCKS=0 git -C "$top" status --porcelain --untracked-files=normal --ignore-submodules=all -- "${spec[@]}" 2>/dev/null)" || {
		echo unknown
		return 0
	}
	if [[ -n "$s" ]]; then
		# The same pathspec: the diff, with what a git config changes in it fixed (prefixes,
		# algorithm, context, hunk joins, file order, full blob names, blank lines, a user's
		# attributes file; no renames, colour or external diff), and, per untracked file, its
		# name, a NUL and its content (a symlink's target).
		h="$(set -o pipefail; cd "$top" && {
			GIT_OPTIONAL_LOCKS=0 git -c diff.suppressBlankEmpty=false -c core.attributesFile=/dev/null \
				diff --binary --full-index --no-color --no-ext-diff --no-textconv --no-renames \
				--diff-algorithm=myers --no-indent-heuristic -U3 --inter-hunk-context=0 -O/dev/null \
				--src-prefix=a/ --dst-prefix=b/ --ignore-submodules=all HEAD -- "${spec[@]}" \
				&& GIT_OPTIONAL_LOCKS=0 git ls-files -z --others --exclude-standard -- "${spec[@]}" \
				| while IFS= read -r -d '' d; do
					printf '%s\0' "$d"
					if [[ -L "$d" ]]; then readlink -- "$d" || :; elif [[ -f "$d" ]]; then cat -- "$d" || :; fi
				done
		} 2>/dev/null | git hash-object --stdin 2>/dev/null)" || h=""
		[[ "$h" =~ ^[0-9a-f]{40} ]] || {
			echo unknown
			return 0
		}
		v+="-dirty.${h:0:8}"
	fi
	printf '%s\n' "$v"
}

# --- controlplane cell states ---

# CP_CELL_AWK: awk functions that read a legacy controlplane cell from its rows, so 003
# (whether the cell in progress was written, the cell count) and 004 (its data warnings)
# decide by one rule (PL41):
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
#                        ISTIOD_REPLICAS_BY_CONTEXT (cp_rep[member]), and reads a
#                        "# WINDOW_ROWS=<member>=<n>[/<spec>],..." line: 002 writes one in
#                        the same write as each window's rows, right before them (from this
#                        harness on), and cp_cell_row ties it to the cell of the row on the
#                        next line (when that is a measurement row). <n>: the rows the
#                        window wrote, one per istiod pod; <spec>: the member's istiod
#                        Deployment .spec.replicas at the window's baseline (absent when not
#                        read, or an older harness wrote it). The "# ISTIOD_NOT_READY=
#                        <member>=<pod>,..." line (an istiod pod Running but not Ready at the
#                        window's baseline) and the "# ISTIOD_NOT_READY_AT_END=" line (the
#                        pods its final phase read as not Ready) right before a WINDOW_ROWS
#                        line, in that order, belong to that window.
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
#                        its measurement rows name as many distinct members as its
#                        mesh_size; the status of its last row when that is a status row;
#                        else INCOMPLETE: the run was cut short while 002 wrote the cell's
#                        member rows (cp_nm[k] of its cp_ms[k] members have one), or, when
#                        the cell has WINDOW_ROWS lines, a member has fewer rows than they
#                        name (its window's write was cut); or, for a cell without one (an
#                        older harness wrote its rows one by one) that was the cell written
#                        last before a run ended (the end of the TSV), a member has fewer
#                        rows than its istiod replicas (a row per replica: the smaller of
#                        its ISTIOD_REPLICAS_BY_CONTEXT entry and its most valid rows in
#                        another cell, or the one of them that is known: an HPA or a rollout
#                        changes the replicas during a sweep, so the two must agree; a
#                        member with a degraded row, istiod_restarted unknown, is not
#                        checked). A window this harness wrote is never held to the replica
#                        count: an istiod replica evicted or Pending at the largest cell
#                        gives fewer rows, all of them written. cp_why[k] says which. Any key
#                        works (a caller may prefix the file).
#   cp_why[k]            set by cp_cell_state for those two cases: "<member> has <n> of the
#                        <w> rows its window wrote", or "<member> has rows of <n> of its <r>
#                        istiod replicas"; empty otherwise.
#   cp_short[k]          set by cp_cell_state when the last row is a measurement row and a
#                        window of the cell ran on fewer istiod pods than its member's
#                        Deployment wants (<n> below <spec>: a replica evicted or Pending; the
#                        rows are valid, so the cell is not INCOMPLETE): "<member> ran <n> of
#                        its <spec> istiod replicas", one per member (the fewest), joined by
#                        ", "; cp_shortw[k] the same for an entry without <spec>, against its
#                        ISTIOD_REPLICAS_BY_CONTEXT entry (read at the sweep's start: an HPA
#                        or a rollout may have changed the replicas since, so only a hint).
#                        A member whose rows all have istiod_restarted unknown (no istiod pod
#                        Running: 002 writes one degraded N/A row, so its entry reads
#                        <member>=1/<spec>; or none could be read) is in neither: no figure
#                        has its rows, and the verdict already reads CAUTION for them (n_valid
#                        below n_total); nor in cp_notready or cp_notready_end.
#                        cp_notready[k]: "<member>=<pod>", joined by ",", for each pod an
#                        ISTIOD_NOT_READY line of the cell names (Running but not Ready at
#                        its window's baseline: it took no new proxy connection while not
#                        Ready, and one shutting down drops its own as it exits, so the
#                        per-replica figures may include a replica that carried fewer);
#                        cp_notready_end[k] the same for its ISTIOD_NOT_READY_AT_END lines.
#   cp_valid[k]          set when the cell has a valid row (istiod_restarted 0).
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
function cp_cell_row(k, st,    mk, n, i, m, wk) {
	cp_ms[k] = $3 + 0
	cp_lastk = k
	if ($2 ~ st) { cp_last[k] = $2; cp_wl = ""; return 1 }
	cp_last[k] = ""
	if ($31 == "0") cp_valid[k] = 1
	# The WINDOW_ROWS line right before this row: the rows each member has in the cell
	# (summed over its windows, as a watch run writes several), and the fewest istiod pods a
	# window of a member ran on below its <spec> (cp_rn, cp_rr), or below its preamble entry
	# when the line has no <spec> (cp_qn, cp_qr); then the pods its not-Ready lines name.
	if (cp_wl != "" && FNR == cp_wf + 1) {
		cp_wa[k] = 1
		n = cp_wl_parse(cp_wl)
		for (i = 1; i <= n; i++) {
			m = cp_wlm[i]; wk = k SUBSEP m
			if (!(wk in cp_wx)) cp_wm[k] = cp_wm[k] "\t" m
			cp_wx[wk] += cp_wln[i]
			if (cp_wls[i] != "") {
				if (cp_wln[i] < cp_wls[i] && (!(wk in cp_rn) || cp_wln[i] < cp_rn[wk])) { cp_rn[wk] = cp_wln[i]; cp_rr[wk] = cp_wls[i] }
			}
			else if ((m in cp_rep) && cp_wln[i] < cp_rep[m] && (!(wk in cp_qn) || cp_wln[i] < cp_qn[wk])) { cp_qn[wk] = cp_wln[i]; cp_qr[wk] = cp_rep[m] }
		}
		n = cp_nr_parse(cp_wnr)
		for (i = 1; i <= n; i++) {
			wk = k SUBSEP cp_nrm[i]
			if (index(" " cp_nrp[wk] " ", " " cp_nrq[i] " ") == 0) cp_nrp[wk] = cp_nrp[wk] (cp_nrp[wk] == "" ? "" : " ") cp_nrq[i]
		}
		n = cp_nr_parse(cp_wne)
		for (i = 1; i <= n; i++) {
			wk = k SUBSEP cp_nrm[i]
			if (index(" " cp_nep[wk] " ", " " cp_nrq[i] " ") == 0) cp_nep[wk] = cp_nep[wk] (cp_nep[wk] == "" ? "" : " ") cp_nrq[i]
		}
	}
	cp_wl = ""
	mk = k SUBSEP $2
	if (!(mk in cp_mem)) { cp_mem[mk] = 1; cp_nm[k]++; cp_ml[k] = cp_ml[k] "\t" $2 }
	if ($31 == "unknown") cp_dg[mk] = 1
	else cp_rd[mk] = 1
	if (!(($2, k) in cp_mx)) { cp_mk[$2, ++cp_mn[$2]] = k; cp_mx[$2, k] = 0 }
	cp_mr[mk]++
	if ($31 == "0") cp_mx[$2, k]++
	return 0
}
# cp_mxo(m, k): the most valid rows (istiod_restarted 0) member m has in a cell other than k
# (0: none).
function cp_mxo(m, k,    i, o, x) {
	x = 0
	for (i = 1; i <= cp_mn[m] + 0; i++) { o = cp_mk[m, i]; if (o != k && cp_mx[m, o] > x) x = cp_mx[m, o] }
	return x
}
function cp_cell_state(k,    n, ml, i, m, mk, ex, np, pl, j) {
	cp_why[k] = ""; cp_short[k] = ""; cp_shortw[k] = ""; cp_notready[k] = ""; cp_notready_end[k] = ""
	if (cp_last[k] != "") return cp_last[k]
	n = split(substr(cp_wm[k], 2), ml, "\t")
	for (i = 1; i <= n; i++) {
		mk = k SUBSEP ml[i]
		if (!(mk in cp_rd)) continue
		if (mk in cp_rn) cp_short[k] = cp_short[k] (cp_short[k] == "" ? "" : ", ") ml[i] " ran " cp_rn[mk] " of its " cp_rr[mk] " istiod replicas"
		else if (mk in cp_qn) cp_shortw[k] = cp_shortw[k] (cp_shortw[k] == "" ? "" : ", ") ml[i] " ran " cp_qn[mk] " of its " cp_qr[mk] " istiod replicas"
		if (mk in cp_nrp) { np = split(cp_nrp[mk], pl, " "); for (j = 1; j <= np; j++) cp_notready[k] = cp_notready[k] (cp_notready[k] == "" ? "" : ",") ml[i] "=" pl[j] }
		if (mk in cp_nep) { np = split(cp_nep[mk], pl, " "); for (j = 1; j <= np; j++) cp_notready_end[k] = cp_notready_end[k] (cp_notready_end[k] == "" ? "" : ",") ml[i] "=" pl[j] }
	}
	if (cp_nm[k] + 0 < cp_ms[k] + 0) return "INCOMPLETE"
	if (k in cp_wa) {
		for (i = 1; i <= n; i++) {
			mk = k SUBSEP ml[i]
			if (cp_mr[mk] + 0 < cp_wx[mk]) { cp_why[k] = ml[i] " has " (cp_mr[mk] + 0) " of the " cp_wx[mk] " rows its window wrote"; return "INCOMPLETE" }
		}
		return ""
	}
	if (!(k in cp_tail)) return ""
	n = split(substr(cp_ml[k], 2), ml, "\t")
	for (i = 1; i <= n; i++) {
		m = ml[i]
		mk = k SUBSEP m
		if (mk in cp_dg) continue
		# When both are known, both must expect more rows: an HPA or a rollout changes the
		# replicas during a sweep, so neither alone is proof.
		ex = cp_mxo(m, k)
		if ((m in cp_rep) && cp_rep[m] > 0 && (ex == 0 || cp_rep[m] < ex)) ex = cp_rep[m]
		if (cp_mr[mk] + 0 < ex) { cp_why[k] = m " has rows of " (cp_mr[mk] + 0) " of its " ex " istiod replicas"; return "INCOMPLETE" }
	}
	return ""
}
'

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
# record's istiod env digest), or unknown when no hashing tool
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

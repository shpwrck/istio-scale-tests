#!/usr/bin/env bash
# Shared utility functions sourced by all test suites.
# Sourced, never executed.
#
# Consumers: churn, churn-dataplane, controlplane, dataplane, propagation, tuning, gateway-api
#
# Exposes:
#   die <msg>                         -> exit 1 with stderr message
#   split_csv <csv> <out_arrayname>   -> trim+split CSV into named array; empty items
#                                        (",", "a,,b", "a, ") are dropped; always returns 0
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
#
# All callers are expected to have run `set -euo pipefail`.
# shellcheck shell=bash

# Every suite needs bash 4.3 or newer (namerefs, `local -n`); macOS ships 3.2, whose errors
# would surface later as confusing syntax or "invalid option" messages.
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
	echo "error: bash 4.3 or newer is required; this is bash ${BASH_VERSION}. On macOS: brew install bash, then put \"\$(brew --prefix)/bin\" first on PATH." >&2
	exit 1
fi

# shellcheck disable=SC2329
die() { echo "error: $*" >&2; exit 1; }

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
#   --unit <noun>    what a cell is called, plural (default cells; tuning: passes)
#   --where <text>   where a failed one shows in the results (default: the report's
#                    placeholder rows, in n_total, not n_valid)
#   --problem <msg>  the sweep failed although its cells ran (A6: the Istio version changed
#                    under it); printed, recorded and counted like a failed cell
#   --note <msg>     a caveat; printed and recorded, not a failure
#   --record <dir>   also write the outcome to <dir>/sweep-outcome.txt (C3)
#   --md <file>      also append it to that markdown report, as a "Sweep outcome" section
# shellcheck disable=SC2329
sweep_outcome() {
	local rc=0 stop_rc="" unit=cells where="" record="" md="" cells r by_fail="" by_skip=""
	local -a problems=() notes=() failed=() skipped=() lines=()
	while (($#)); do
		case "$1" in
		--stopped) stop_rc="$2"; shift 2 ;;
		--unit) unit="$2"; shift 2 ;;
		--where) where="$2"; shift 2 ;;
		--problem) problems+=("$2"); shift 2 ;;
		--note) notes+=("$2"); shift 2 ;;
		--record) record="$2"; shift 2 ;;
		--md) md="$2"; shift 2 ;;
		*) break ;;
		esac
	done
	cells="$1"
	shift
	[[ -n "$where" ]] || where="The report includes them as placeholder rows (in n_total, not n_valid)"
	for r in "$@"; do
		if [[ "$r" == SKIPPED_* ]]; then skipped+=("$r"); else failed+=("$r"); fi
	done
	((${#failed[@]} == 0)) || by_fail="$(_sweep_outcome_by "${failed[@]}")"
	((${#skipped[@]} == 0)) || by_skip="$(_sweep_outcome_by "${skipped[@]}")"
	if ((${#failed[@]} || ${#problems[@]})); then rc="$SWEEP_FAILED_EXIT"; fi
	[[ -z "$stop_rc" ]] || rc="$stop_rc"
	# tail: how a failure line ends. lines: "out|", "err|" or "rec|" (the record and the
	# markdown only) plus the text, in the order printed.
	local tail="; exit ${SWEEP_FAILED_EXIT}."
	[[ -z "$stop_rc" ]] || tail="; the sweep also stopped early, so it exits ${stop_rc}, not ${SWEEP_FAILED_EXIT}."
	if [[ -z "$stop_rc" && ${#failed[@]} -eq 0 && ${#skipped[@]} -eq 0 ]]; then
		lines+=("out|All ${cells} ${unit} ran (their rows' own statuses are in the report).")
	elif ((${#skipped[@]})); then
		lines+=("out|${#skipped[@]} of ${cells} ${unit} were skipped on purpose, not failed: ${by_skip}.")
	fi
	if ((${#failed[@]})); then
		lines+=("err|error: ${#failed[@]} of ${cells} ${unit} failed: ${by_fail}. ${where}${tail}")
	fi
	for r in ${problems[@]+"${problems[@]}"}; do lines+=("err|error: ${r}${tail}"); done
	for r in ${notes[@]+"${notes[@]}"}; do lines+=("err|warning: ${r}."); done
	if [[ -n "$stop_rc" && ${#failed[@]} -eq 0 && ${#problems[@]} -eq 0 ]]; then
		lines+=("rec|The sweep stopped early; it exits ${stop_rc}.")
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
			echo "EXIT=${rc}"
			echo "STOPPED=$([[ -n "$stop_rc" ]] && echo 1 || echo 0)"
			echo "UNIT=${unit}"
			echo "TOTAL=${cells}"
			echo "FAILED=${#failed[@]}"
			echo "FAILED_BY=${by_fail}"
			echo "SKIPPED=${#skipped[@]}"
			echo "SKIPPED_BY=${by_skip}"
			for r in ${problems[@]+"${problems[@]}"}; do echo "PROBLEM=${r}"; done
			for r in ${notes[@]+"${notes[@]}"}; do echo "NOTE=${r}"; done
		} 2>/dev/null > "${record}/sweep-outcome.txt" \
			|| echo "warning: could not write ${record}/sweep-outcome.txt" >&2
	fi
	if [[ -n "$md" && -f "$md" ]]; then
		{
			echo ""
			echo "## Sweep outcome"
			echo ""
			echo "Exit ${rc}. $([[ -n "$record" ]] && echo "Also in \`sweep-outcome.txt\`.")"
			echo ""
			for r in ${lines[@]+"${lines[@]}"}; do echo "- ${r#*|}"; done
		} 2>/dev/null >> "$md" || echo "warning: could not append the outcome to ${md}" >&2
	fi
	return "$rc"
}

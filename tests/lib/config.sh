#!/usr/bin/env bash
# Run-config files (`--config FILE`) for the suite scripts. Sourced, never executed.
#
# Consumers: every numbered script of controlplane, dataplane, churn, churn-dataplane,
# propagation and gateway-api. Tuning (which chains the others) has no key map yet.
#
# A run config is a file of KEY=value lines. Its keys are the suite's knobs from
# config/options.env (the `export NAME=` lines that match the suite's key list) plus
# SETUP_CONTEXTS, so one file can describe a whole run: setup, collection, sweep, report
# and cleanup. Each step ignores the keys it does not use. The file is parsed, never
# sourced or eval'd, so it cannot run code, and a file that parses means the same thing
# when sourced.
#
# Precedence: flag > --config > env > default. A script calls
#   config_preload <suite> "$@"
# before it sources config/versions.env. The preload exports the file's values over the
# environment. options.env (`${X:-default}`) then keeps them and derives its dependent
# defaults from them (CONTROLPLANE_SETUP_NS_WAIT_SEC from CONTROLPLANE_NS_DELETE_TIMEOUT_SEC,
# FANOUT_METRICS_TIMEOUT from METRICS_SCRAPE_TIMEOUT). The script seeds its locals from the
# environment and its flag parser overrides them. An empty value (KEY=) means the built-in
# default, whatever the environment holds.
#
# Accepted syntax, one item per line; any other line rejects the whole file:
#   a blank line, or a comment line starting with #
#   [export ]KEY=VALUE [# comment]
#     KEY    [A-Z][A-Z0-9_]*, no spaces around =, each key at most once
#     VALUE  unquoted, from [A-Za-z0-9_.,:/@%+=-]
#            '...' with no ' inside
#            "..." with no " $ ` \ inside
# CRLF line endings and a missing final newline are accepted.
#
# Not settable from a file (the environment still works): *_TEST_NAMESPACE (cleanup deletes
# that namespace), *_MAX_MATRIX (PL10: the large-matrix acknowledgment stays per
# invocation) and the version pins in config/versions.env.
#
# Exposes:
#   config_suite_prefixes <suite>  -> the suite's key list: prefixes (ending in _) and whole
#                                     key names, then CONFIG_SHARED_PREFIXES (ISTIOD_DIAG_,
#                                     TEST_PLATFORM and PLATFORM_READ_TIMEOUT, taken by every
#                                     suite); die for a suite without a map
#   config_allowed_keys <suite>    -> the keys a config may set, one per line, sorted
#   load_config <file> <suite>     -> validate the whole file, then export its keys and
#                                     RUN_CONFIG, RUN_CONFIG_SHA256, RUN_CONFIG_PATH
#   config_preload <suite> "$@"    -> load_config the FILE of `--config FILE` in the args;
#                                     without --config, keep RUN_CONFIG* inherited from a
#                                     config-driven parent, or set them to none
#   config_preamble_lines          -> the `# RUN_CONFIG=` and `# RUN_CONFIG_SHA256=` lines
#   config_repo_path <path>        -> <path> if absolute, else ${ROOT}/<path>
#   config_snapshot <dir> <run_id> -> a sweep's replay copy <dir>/run-config-<run_id>.env;
#                                     no-op without a config, warns if the copy fails
#   config_report_value [--consequence TEXT] <key> <tsv>...
#                                  -> a report's RUN_CONFIG or RUN_CONFIG_SHA256 (or PLATFORM)
#                                     over all its inputs: one value, mixed:a,b with a warning
#                                     (PL26) naming TEXT, and unknown for a file written before
#                                     the key existed
#   config_warn_multi_run <dir> <tsv>...
#                                  -> warn when a report's inputs come from more than one
#                                     run: a sweep-* dir, or a RUN_ID outside one (PL6)
#
# Provenance, exported so the steps a config-driven sweep runs inherit it:
#   RUN_CONFIG         the file's path relative to the repo root, or its basename outside the
#                      repo (never an absolute or home path); none without --config
#   RUN_CONFIG_SHA256  sha256 of the file (unknown without sha256sum or shasum); none without
#   RUN_CONFIG_PATH    absolute path, only for the sweep's snapshot copy; never written to results
# RUN_CONFIG_LOADED=1 (not exported) when this process loaded the file itself.
#
# Needs die() from common.sh and ROOT (the repo root). Callers run `set -euo pipefail`.
# shellcheck shell=bash

# The suites' key lists. An entry ending in _ is a prefix; any other entry is one key.
# FANOUT_* and METRICS_SCRAPE_TIMEOUT tune the istiod scrapes (tests/lib/fanout.sh), REACH_*
# the reachability check (tests/lib/reach.sh); churn-dataplane also reads the churn
# suite's workload-size keys. Every list ends with CONFIG_SHARED_PREFIXES, the keys of
# libraries that every suite runs.
# shellcheck disable=SC2329
config_suite_prefixes() {
	local own
	case "$1" in
	controlplane) own="CONTROLPLANE_ SCALE_ METRICS_ FANOUT_ CAP_" ;;
	dataplane) own="DATAPLANE_ REACH_ FANOUT_ METRICS_SCRAPE_TIMEOUT" ;;
	churn) own="CHURN_ FANOUT_ METRICS_SCRAPE_TIMEOUT" ;;
	churn-dataplane) own="COEXEC_ REACH_ FANOUT_ METRICS_SCRAPE_TIMEOUT CHURN_DEPLOYMENT_COUNT CHURN_BASE_REPLICAS CHURN_SCALE_TO_REPLICAS" ;;
	propagation) own="PROPAGATION_ FANOUT_ METRICS_SCRAPE_TIMEOUT" ;;
	gateway-api) own="GWAPI_" ;;
	*) die "--config: the '$1' suite has no config key map yet (supported: controlplane, dataplane, churn, churn-dataplane, propagation, gateway-api)" ;;
	esac
	echo "${own} ${CONFIG_SHARED_PREFIXES}"
}

# Keys every suite takes: ISTIOD_DIAG_* tune the istiod restart evidence capture
# (tests/lib/istiod-diag.sh); TEST_PLATFORM picks the members' platform and
# PLATFORM_READ_TIMEOUT bounds each read of the platform record (tests/lib/platform.sh).
# An unknown-key error names them after the suite's own list.
CONFIG_SHARED_PREFIXES="ISTIOD_DIAG_ TEST_PLATFORM PLATFORM_READ_TIMEOUT"

# _config_key_matches <key> <entry>: the key is the entry, or starts with it when the
# entry is a prefix (ends in _).
# shellcheck disable=SC2329
_config_key_matches() {
	case "$2" in
	*_) [[ "$1" == "$2"* ]] ;;
	*) [[ "$1" == "$2" ]] ;;
	esac
}

# _config_env_only_reason <key>: why a key with a suite prefix stays env-only; empty if it
# does not.
# shellcheck disable=SC2329
_config_env_only_reason() {
	case "$1" in
	*_TEST_NAMESPACE) echo "cleanup deletes this namespace, so a typo in a file could delete a real one" ;;
	*_MAX_MATRIX) echo "the large-matrix acknowledgment stays per invocation (PL10)" ;;
	esac
}

# shellcheck disable=SC2329,SC2153  # ROOT is set by the caller
config_allowed_keys() {
	local suite="$1" prefixes p name
	config_suite_prefixes "$suite" >/dev/null
	prefixes="$(config_suite_prefixes "$suite")"
	{
		echo SETUP_CONTEXTS
		while IFS= read -r name; do
			for p in $prefixes; do
				_config_key_matches "$name" "$p" || continue
				[[ -z "$(_config_env_only_reason "$name")" ]] && echo "$name"
				break
			done
		done < <(sed -nE 's/^export ([A-Z][A-Z0-9_]*)=.*/\1/p' "${ROOT}/config/options.env")
	} | LC_ALL=C sort -u
}

# _config_sha256 <file>: hex sha256, or unknown when no hashing tool works.
# shellcheck disable=SC2329
_config_sha256() {
	local out=""
	if command -v sha256sum >/dev/null 2>&1; then
		out="$(sha256sum < "$1" 2>/dev/null)" || out=""
	elif command -v shasum >/dev/null 2>&1; then
		out="$(shasum -a 256 < "$1" 2>/dev/null)" || out=""
	fi
	out="${out%% *}"
	if [[ "$out" =~ ^[0-9a-f]{64}$ ]]; then echo "$out"; else echo unknown; fi
}

# _config_display_path <file>: repo-relative path inside ROOT, else the basename. Characters
# outside [A-Za-z0-9_.,:/@%+=-] become _ so the value is safe in every report format.
# shellcheck disable=SC2329
_config_display_path() {
	local file="$1" dir base repo disp
	base="$(basename "$file")"
	dir="$(cd "$(dirname "$file")" && pwd -P)" || dir=""
	repo="$(cd "$ROOT" && pwd -P)" || repo=""
	if [[ -n "$dir" && -n "$repo" && "${dir}/${base}" == "${repo}/"* ]]; then
		disp="${dir}/${base}"
		disp="${disp#"${repo}/"}"
	else
		disp="$base"
	fi
	printf '%s\n' "$disp" | LC_ALL=C sed 's#[^A-Za-z0-9_.,:/@%+=-]#_#g'
}

# shellcheck disable=SC2329
load_config() {
	local file="$1" suite="$2"
	config_suite_prefixes "$suite" >/dev/null
	[[ -n "$file" ]] || die "--config requires a file"
	[[ -f "$file" && -r "$file" ]] || die "--config: ${file}: not a readable file"

	local prefixes allowed_desc="" shared_desc="" p
	prefixes="$(config_suite_prefixes "$suite")"
	for p in $prefixes; do
		case "$p" in *_) p="${p}*" ;; esac
		if [[ " ${CONFIG_SHARED_PREFIXES} " == *" ${p%\*} "* ]]; then
			shared_desc="${shared_desc:+${shared_desc}, }${p}"
			continue
		fi
		allowed_desc="${allowed_desc:+${allowed_desc}, }${p}"
	done
	local -A cfg_allowed=()
	local k
	while IFS= read -r k; do cfg_allowed[$k]=1; done < <(config_allowed_keys "$suite")

	# A line is: optional indent, optional `export `, KEY=VALUE, optional ` # comment`.
	local re_unq='[A-Za-z0-9_.,:/@%+=-]*'
	local re_sq="'[^']*'"
	# shellcheck disable=SC2016  # literal $ and ` inside the bracket expression
	local re_dq='"[^"$`\]*"'
	local re_lead='^[[:space:]]*(export[[:space:]]+)?'
	local re="${re_lead}([A-Z][A-Z0-9_]*)=(${re_unq}|${re_sq}|${re_dq})([[:space:]]+#.*)?[[:space:]]*\$"
	local re_skip='^[[:space:]]*(#.*)?$'
	# Only for the error message of a line that does not match $re.
	local re_name_eq="${re_lead}[A-Za-z_][A-Za-z0-9_]*="
	local re_upper_eq="${re_lead}[A-Z][A-Z0-9_]*="
	local re_space_eq="${re_lead}[A-Za-z_][A-Za-z0-9_]*[[:space:]]+="
	local re_eq_space='^[^=]*=[[:space:]]'

	local -a cfg_keys=() cfg_vals=() cfg_errors=()
	local -A cfg_seen=()
	local line n=0 key raw val reason env_only
	while IFS= read -r line || [[ -n "$line" ]]; do
		n=$((n + 1))
		line="${line%$'\r'}"
		[[ "$line" =~ $re_skip ]] && continue
		if ! [[ "$line" =~ $re ]]; then
			if [[ "$line" == *'$'* || "$line" == *'`'* ]]; then
				reason='$ and ` are not allowed outside single quotes (no substitution)'
			elif [[ "$line" =~ $re_space_eq || "$line" =~ $re_eq_space ]]; then
				reason="no spaces around '='"
			elif [[ "$line" =~ $re_upper_eq ]]; then
				reason="bad value: an unterminated quote, or a character that needs quoting ('...' or \"...\"); unquoted values allow only [A-Za-z0-9_.,:/@%+=-]"
			elif [[ "$line" =~ $re_name_eq ]]; then
				reason="keys are upper case ([A-Z][A-Z0-9_]*)"
			else
				reason="not a KEY=value line"
			fi
			cfg_errors+=("${file}:${n}: ${reason}")
			continue
		fi
		key="${BASH_REMATCH[2]}"
		raw="${BASH_REMATCH[3]}"
		case "$raw" in
		\'* | \"*) val="${raw:1:${#raw}-2}" ;;
		*) val="$raw" ;;
		esac
		if [[ -n "${cfg_seen[$key]:-}" ]]; then
			cfg_errors+=("${file}:${n}: duplicate key ${key} (also on line ${cfg_seen[$key]})")
			continue
		fi
		cfg_seen[$key]="$n"
		if [[ -z "${cfg_allowed[$key]:-}" ]]; then
			reason="$(_config_env_only_reason "$key")"
			env_only=0
			for p in $prefixes; do
				[[ -n "$reason" ]] && _config_key_matches "$key" "$p" && env_only=1
			done
			if ((env_only)); then
				cfg_errors+=("${file}:${n}: ${key} is not settable from --config (env only: ${reason})")
			elif grep -qE "^export ${key}=" "${ROOT}/config/versions.env" 2>/dev/null; then
				cfg_errors+=("${file}:${n}: ${key} is a version pin (config/versions.env), not settable from --config")
			else
				cfg_errors+=("${file}:${n}: unknown key ${key} for the ${suite} suite (allowed: SETUP_CONTEXTS and the config/options.env keys ${allowed_desc}); every suite also takes ${shared_desc}")
			fi
			continue
		fi
		cfg_keys+=("$key")
		cfg_vals+=("$val")
	done < "$file"

	if ((${#cfg_errors[@]})); then
		local e
		for e in "${cfg_errors[@]}"; do echo "error: ${e}" >&2; done
		die "--config: ${file} rejected (${#cfg_errors[@]} bad line(s)); nothing was applied"
	fi

	# Valid: apply every key, then the provenance.
	local display sha abs i v note
	display="$(_config_display_path "$file")"
	sha="$(_config_sha256 "$file")"
	abs="$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")"
	for i in "${!cfg_keys[@]}"; do
		k="${cfg_keys[i]}"
		v="${cfg_vals[i]}"
		note=""
		if [[ -v "$k" && "${!k}" != "$v" ]]; then
			note=" (overrides env '${!k}')"
		fi
		declare -gx "${k}=${v}"
		echo "[config] ${display} sha256=${sha:0:12}: ${k}=${v}${note}" >&2
	done
	((${#cfg_keys[@]})) || echo "[config] ${display} sha256=${sha:0:12}: no keys" >&2
	declare -gx RUN_CONFIG="$display" RUN_CONFIG_SHA256="$sha" RUN_CONFIG_PATH="$abs"
	# shellcheck disable=SC2034  # read by the scripts (004's multi-RUN_ID warning)
	declare -g RUN_CONFIG_LOADED=1
}

# shellcheck disable=SC2329
config_preload() {
	local suite="$1" file="" found=0
	shift
	config_suite_prefixes "$suite" >/dev/null
	while (($#)); do
		if [[ "$1" == --config ]]; then
			((found)) && die "--config given more than once"
			found=1
			[[ -n "${2:-}" ]] || die "--config requires a value (a KEY=value file)"
			[[ "$2" != -* ]] || die "--config requires a file path (got '$2')"
			file="$2"
			shift 2
			continue
		fi
		shift
	done
	if ((found)); then
		load_config "$file" "$suite"
	else
		declare -gx RUN_CONFIG="${RUN_CONFIG:-none}" RUN_CONFIG_SHA256="${RUN_CONFIG_SHA256:-none}"
		# shellcheck disable=SC2034  # read by the scripts (004's multi-RUN_ID warning)
		declare -g RUN_CONFIG_LOADED=0
	fi
}

# shellcheck disable=SC2329
config_preamble_lines() {
	echo "# RUN_CONFIG=${RUN_CONFIG:-none}"
	echo "# RUN_CONFIG_SHA256=${RUN_CONFIG_SHA256:-none}"
}

# shellcheck disable=SC2329
config_repo_path() {
	case "$1" in
	/*) printf '%s\n' "$1" ;;
	*) printf '%s\n' "${ROOT}/$1" ;;
	esac
}

# config_snapshot <dir> <run_id>: copy the run config next to a sweep's results, as
# <dir>/run-config-<run_id>.env, so the sweep can be replayed. No-op without a config.
# Best effort: the preamble's RUN_CONFIG_SHA256 identifies the config either way.
# shellcheck disable=SC2329
config_snapshot() {
	local dir="$1" run_id="$2" snap
	[[ "${RUN_CONFIG:-none}" != none && -f "${RUN_CONFIG_PATH:-}" ]] || return 0
	snap="${dir}/run-config-${run_id}.env"
	if mkdir -p "$dir" && cp "$RUN_CONFIG_PATH" "$snap"; then
		echo "Run config snapshot: $snap" >&2
	else
		echo "warning: could not write the run-config snapshot $snap" >&2
	fi
	return 0
}

# config_report_value [--consequence TEXT] <key> <tsv>...: the `# <key>=` preamble value
# (RUN_CONFIG or RUN_CONFIG_SHA256, or another sweep-level key: PLATFORM) over every input of a
# report. A file without the line counts as unknown (written before the key existed), so it is
# never credited to a config. One value -> that value; several -> mixed:a,b plus a stderr
# warning (PL26) that ends with TEXT (default: the --config one).
# shellcheck disable=SC2329
config_report_value() {
	local consequence="the report mixes runs made with different --config files"
	if [[ "${1:-}" == --consequence ]]; then
		consequence="$2"
		shift 2
	fi
	local key="$1" f v vals=""
	shift
	for f in "$@"; do
		v="$(grep -m1 "^# ${key}=" "$f" 2>/dev/null || true)"
		if [[ -n "$v" ]]; then v="${v#*=}"; else v=unknown; fi
		case ",${vals}," in *",${v},"*) ;; *) vals="${vals:+${vals},}${v}" ;; esac
	done
	if [[ -z "$vals" ]]; then
		echo unknown
	elif [[ "$vals" == *,* ]]; then
		echo "warning: input TSVs disagree on ${key} (${vals}); ${consequence}" >&2
		echo "mixed:${vals}"
	else
		echo "$vals"
	fi
}

# _config_run_key <tsv>: the run a report input belongs to. A file in a sweep-* dir
# belongs to that sweep (its combos carry their own RUN_IDs); any other file to the
# preamble's SWEEP_RUN_ID (propagation), else its RUN_ID, else the run_id column of its
# first data row; a file with none of these counts as a run of its own.
# shellcheck disable=SC2329
_config_run_key() {
	local f="$1" d=. id
	if [[ "$f" == */* ]]; then
		d="${f%/*}"
		d="${d##*/}"
	fi
	case "$d" in
	sweep-*)
		echo "$d"
		return 0
		;;
	esac
	id="$(awk -F'\t' '
		/^# SWEEP_RUN_ID=/ { if (s == "") s = substr($0, 16); next }
		/^# RUN_ID=/ { if (r == "") r = substr($0, 10); next }
		/^#/ || $1 == "run_id" { next }
		{ c = $1; exit }
		END { print (s != "" ? s : (r != "" ? r : c)) }' "$f" 2>/dev/null || true)"
	if [[ -n "$id" ]]; then echo "$id"; else echo "${f##*/}"; fi
}

# config_warn_multi_run <results_dir> <tsv>...: PL6 for a results dir that came from a
# config (or the default): a base dir aggregates every run under it. Counts one run per
# sweep-* dir and one per distinct RUN_ID among the files outside one (_config_run_key),
# so two standalone probes into the same dir warn too. Callers warn only with --config
# and without --results-dir, so a report without --config prints what it always did.
# shellcheck disable=SC2329
config_warn_multi_run() {
	local dir="$1" runs n list f
	shift
	runs="$(for f in "$@"; do _config_run_key "$f"; done | LC_ALL=C sort -u)"
	n="$(grep -c . <<<"$runs" || true)"
	((n > 1)) || return 0
	list="$(awk 'NR <= 5 { printf "%s%s", (NR > 1 ? "," : ""), $0 } END { if (NR > 5) printf ",..." }' <<<"$runs")"
	echo "warning: ${dir} holds ${n} runs (${list}); this report aggregates all of them. Pass --results-dir <dir>/sweep-<RUN_ID> to report one sweep." >&2
}

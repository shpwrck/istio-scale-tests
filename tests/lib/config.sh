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
#                                     TEST_PLATFORM, PLATFORM_READ_TIMEOUT and
#                                     PLATFORM_READ_PARALLEL, taken by every suite); die for a
#                                     suite without a map
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
#   config_input_value <key> <missing> <tsv>...
#                                  -> a `# <key>=` preamble value over every input of a
#                                     report: one value, or mixed:a,b (PL26); a file without
#                                     the line reads <missing> (empty: adds nothing)
#   config_report_value <key> <tsv>...
#                                  -> a report's RUN_CONFIG or RUN_CONFIG_SHA256 over all its
#                                     inputs: one value, mixed:a,b with a warning (PL26), and
#                                     unknown for a file written before the key existed
#   config_merged_preamble <tsv>...
#                                  -> KEY=value for every preamble key of the inputs, merged
#                                     as config_input_value does (varying keys read mixed:)
#   config_check_multi_run <dir> <allow> <tsv>...
#                                  -> count the runs among a report's inputs (a sweep-* dir,
#                                     or a run id outside one; PL6/PL26); more than one dies
#                                     unless <allow> is 1 (--allow-multi-run). Sets
#                                     MULTI_RUN_N, MULTI_RUN_IDS, MULTI_RUN_HARNESS_SHAS,
#                                     MULTI_RUN_ISTIO_VERSIONS
#   config_multi_run_note          -> the sentence a pooled report prints in every format
#                                     (nothing for one run)
#   config_multi_run_csv           -> `# POOLED_*=` lines for a csv (nothing for one run)
#   config_multi_run_json          -> {"runs":N,"run_ids":[..],"harness_sha":[..],
#                                     "istio_version":[..]} (also for one run)
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
# (tests/lib/istiod-diag.sh); TEST_PLATFORM picks the members' platform, PLATFORM_READ_TIMEOUT
# bounds each read of the platform record and PLATFORM_READ_PARALLEL says how many members are
# read at once (tests/lib/platform.sh). An unknown-key error names them after the suite's own list.
CONFIG_SHARED_PREFIXES="ISTIOD_DIAG_ TEST_PLATFORM PLATFORM_READ_TIMEOUT PLATFORM_READ_PARALLEL"
# Keys every suite reads that no --config sets (_config_env_only_reason says why).
CONFIG_SHARED_ENV_ONLY="ISTIO_VERSION_CHECK ISTIO_VERSION_READY_ SWEEP_STOP_GRACE_SEC"
# CONFIG_MERGED_UNKNOWN_IF_MISSING: preamble keys that config_merged_preamble merges as
# unknown for a file without them (written before the live-version keys: its
# ISTIO_VERSION is the pin, unchecked; or before ISTIO_ACTIVE_REVISIONS or
# ISTIO_GENERATIONS were added). They are sweep-level (PL26): pooled inputs that differ
# read mixed, never one file's value.
# shellcheck disable=SC2034
CONFIG_MERGED_UNKNOWN_IF_MISSING="ISTIO_VERSION_SOURCE ISTIO_VERSION_PIN ISTIO_VERSION_BY_CONTEXT ISTIO_ACTIVE_REVISIONS ISTIO_GENERATIONS"
# CONFIG_MERGED_DROPPED: keys of older TSVs that no run writes any more (the Istio version
# check's proxy-version and readiness records, the platform record's tuning objects, the
# harness's content key); config_merged_preamble leaves them out, so a pooled report never
# shows the older files' value as every input's.
# shellcheck disable=SC2034
CONFIG_MERGED_DROPPED="ISTIO_PROXY_VERSIONS ISTIO_NOTREADY_AT_START ISTIO_READY_WAITED_SEC TUNING_OBJECTS_BY_CONTEXT HARNESS_CONTENT_KEY"

# _config_key_matches <key> <entry>: the key is the entry, or starts with it when the
# entry is a prefix (ends in _).
# shellcheck disable=SC2329
_config_key_matches() {
	case "$2" in
	*_) [[ "$1" == "$2"* ]] ;;
	*) [[ "$1" == "$2" ]] ;;
	esac
}

# _config_env_only_reason <key>: why a key with a suite prefix (or in CONFIG_SHARED_ENV_ONLY)
# stays env-only; empty if it does not.
# shellcheck disable=SC2329
_config_env_only_reason() {
	case "$1" in
	*_TEST_NAMESPACE) echo "cleanup deletes this namespace, so a typo in a file could delete a real one" ;;
	*_MAX_MATRIX) echo "the large-matrix acknowledgment stays per invocation (PL10)" ;;
	ISTIO_VERSION_CHECK) echo "running on a mesh whose Istio version is not the pin is acknowledged per invocation, like the pins themselves" ;;
	ISTIO_VERSION_READY_*) echo "the version check's readiness wait is set per invocation, with ISTIO_VERSION_CHECK" ;;
	SWEEP_STOP_GRACE_SEC) echo "a setting of every sweep (tests/lib/common.sh), not of one suite's run" ;;
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
			for p in $prefixes $CONFIG_SHARED_ENV_ONLY; do
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
	sha="$(file_sha256 "$file")"
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

# _CONFIG_VKEY_AWK: awk function vkey(k, v), the form of value v of preamble key k that
# pooling compares: an ISTIO_VERSION* value without the v in front of a version, so
# v1.30.5 and 1.30.5 (or ctx=v1.30.5 and ctx=1.30.5) are one value, shown in the form seen
# first; any other value as it is.
_CONFIG_VKEY_AWK='
	function vkey(k, v,    o, i, n, c) {
		if (k !~ /^ISTIO_VERSION/) return v
		o = ""
		n = length(v)
		for (i = 1; i <= n; i++) {
			c = substr(v, i, 1)
			if (c == "v" && substr(v, i + 1, 1) ~ /[0-9]/ && (i == 1 || substr(v, i - 1, 1) ~ /[=\/:,]/)) continue
			o = o c
		}
		return o
	}
'

# _config_distinct <key> <missing> <tsv>...: the distinct `# <key>=` values of the files,
# one per line in file order (an empty value as an empty line; an ISTIO_VERSION* value
# once whatever its leading v, _CONFIG_VKEY_AWK). A file without the line reads
# <missing>, or adds nothing when <missing> is empty. <key> is a plain name. One awk for
# every file: it reads them with getline, so a missing, unreadable or empty file
# reads <missing> and a path holding `=` is a path, never an awk assignment.
_config_distinct() {
	local key="$1" missing="$2"
	shift 2
	(($#)) || return 0
	_CD_KEY="$key" _CD_MISSING="$missing" awk "${_CONFIG_VKEY_AWK}"'
		BEGIN {
			k = ENVIRON["_CD_KEY"]; missing = ENVIRON["_CD_MISSING"]
			p = "# " k "="; lp = length(p)
			for (i = 1; i < ARGC; i++) {
				found = 0
				while ((getline line < ARGV[i]) > 0)
					if (substr(line, 1, lp) == p) { v = substr(line, lp + 1); found = 1; break }
				close(ARGV[i])
				if (!found) { if (missing == "") continue; v = missing }
				kv = vkey(k, v)
				if (!(kv in at)) { at[kv] = ++n; out[n] = v }
			}
			for (i = 1; i <= n; i++) print out[i]
			exit
		}' "$@"
}

# _config_join_mixed: stdin's lines (distinct values) as one value: the line itself when
# there is one, else mixed:a,b (joined with " | " when a value holds a comma, as a
# KUBE_VERSIONS list does; an empty value reads (empty)). A value that is itself mixed
# (ISTIO_VERSION=mixed:a/b, a run whose members differed) adds its parts, so each
# distinct value is listed once: mixed:a,b, never mixed:mixed:a/b,a. [<key>]: the
# preamble key, so an ISTIO_VERSION* value counts once whatever its leading v. No
# input, no output.
_config_join_mixed() {
	awk -v key="${1:-}" "${_CONFIG_VKEY_AWK}"'
		{ raw[++r] = $0 }
		END {
			if (r == 0) exit
			if (r == 1) { print raw[1]; exit }
			for (i = 1; i <= r; i++) {
				np = (raw[i] ~ /^mixed:/) ? split(substr(raw[i], 7), part, "/") : 0
				if (!np) { np = 1; part[1] = raw[i] }
				for (q = 1; q <= np; q++) if (!(vkey(key, part[q]) in vseen)) {
					vseen[vkey(key, part[q])] = ++n; v[n] = part[q]
					if (index(part[q], ",")) c = 1
				}
			}
			if (n == 1) { print v[1]; exit }
			out = "mixed:"
			for (i = 1; i <= n; i++) out = out (i > 1 ? (c ? " | " : ",") : "") (v[i] == "" ? "(empty)" : v[i])
			print out
		}'
}

# config_input_value <key> <missing> <tsv>...: a `# <key>=` preamble value over every input
# of a report, never the first or the last file's (PL26): one distinct value -> it, several
# -> mixed:a,b in file order. A file without the line reads <missing>, or adds nothing when
# <missing> is empty. No output when no file contributes.
# shellcheck disable=SC2329
config_input_value() {
	local key="$1" missing="$2"
	shift 2
	_config_distinct "$key" "$missing" "$@" | _config_join_mixed "$key"
}

# config_report_value <key> <tsv>...: the `# <key>=` preamble value (RUN_CONFIG or
# RUN_CONFIG_SHA256) over every input of a report. A file without the line counts as
# unknown (written before the key existed), so it is never credited to a config. One
# value -> that value; several -> mixed:a,b plus a stderr warning (PL26).
# shellcheck disable=SC2329
config_report_value() {
	local key="$1" v
	shift
	v="$(config_input_value "$key" unknown "$@")"
	if [[ -z "$v" ]]; then
		echo unknown
	elif [[ "$v" == mixed:* ]]; then
		echo "warning: input TSVs disagree on ${key} (${v#mixed:}); the report mixes runs made with different --config files" >&2
		echo "$v"
	else
		echo "$v"
	fi
}

# config_merged_preamble <tsv>...: KEY=value for every `# KEY=value` (or KEY[x]=value)
# preamble line of the inputs, the lines before a file's first data or header line. Keys
# come in first-seen order; each value is merged over the files that carry the key as
# _config_join_mixed does (a file without the key adds nothing), so a report that shows
# these never shows one file's value for a key that varies (PL26). Except the keys of
# CONFIG_MERGED_UNKNOWN_IF_MISSING: a file written before they existed counts as unknown
# for them, so a pooled report says mixed, never "live", when some rows were not read live
# (a key no input carries stays out, as any other). The keys of CONFIG_MERGED_DROPPED stay
# out always.
# shellcheck disable=SC2329
config_merged_preamble() {
	(($#)) || return 0
	awk -v must="$CONFIG_MERGED_UNKNOWN_IF_MISSING" -v drop="$CONFIG_MERGED_DROPPED" "${_CONFIG_VKEY_AWK}"'
		function add(k, v,    kv) {
			if (!(k in nv)) { order[++n] = k; nv[k] = 0 }
			kv = vkey(k, v)
			if (!((k, kv) in seen)) {
				seen[k, kv] = nv[k] + 1
				val[k, ++nv[k]] = v
				if (index(v, ",")) comma[k] = 1
			}
		}
		# fin: the keys a file must carry and does not, as unknown.
		function fin(    i) { for (i = 1; i <= nm; i++) if (!((fid, m[i]) in infile)) add(m[i], "unknown") }
		BEGIN { nm = split(must, m, " "); nd = split(drop, dk, " "); for (i = 1; i <= nd; i++) dropped[dk[i]] = 1 }
		FNR == 1 { if (fid) fin(); fid++; inpre = 1 }
		!inpre { next }
		/^# / {
			line = substr($0, 3)
			if (line !~ /^[A-Z][A-Z0-9_]*(\[[^]]+\])?=/) next
			k = line
			sub(/=.*/, "", k)
			if ((k in dropped) || ((fid, k) in infile)) next
			infile[fid, k] = 1
			real[k] = 1
			add(k, substr(line, length(k) + 2))
			next
		}
		/^#/ || /^$/ { next }
		{ inpre = 0 }
		END {
			if (fid) fin()
			for (i = 1; i <= n; i++) {
				k = order[i]
				if (!(k in real)) continue
				if (nv[k] == 1) { print k "=" val[k, 1]; continue }
				# A value that is itself mixed adds its parts, each listed once (as
				# _config_join_mixed does).
				nf = 0
				delete fl
				delete fseen
				for (j = 1; j <= nv[k]; j++) {
					np = (val[k, j] ~ /^mixed:/) ? split(substr(val[k, j], 7), part, "/") : 0
					if (!np) { np = 1; part[1] = val[k, j] }
					for (q = 1; q <= np; q++) {
						if (!(vkey(k, part[q]) in fseen)) { fseen[vkey(k, part[q])] = ++nf; fl[nf] = part[q] }
					}
				}
				if (nf == 1) { print k "=" fl[1]; continue }
				out = ""
				for (j = 1; j <= nf; j++)
					out = out (j > 1 ? ((k in comma) ? " | " : ",") : "") (fl[j] == "" ? "(empty)" : fl[j])
				print k "=mixed:" out
			}
		}' "$@"
}

# _config_run_key <tsv>...: the run each report input outside a sweep-* dir belongs to,
# one line per file in order: the preamble's SWEEP_RUN_ID (propagation), else its RUN_ID,
# else the run_id column of its first data row; a file with none of these (or unreadable)
# counts as a run of its own, named after the file. A file in a sweep-* dir belongs to that
# sweep instead (its combos carry their own RUN_IDs); config_check_multi_run decides that
# from the canonical directory before it calls this. One awk for every file: getline
# reads each, so a path holding `=` is a path, never an awk assignment.
# shellcheck disable=SC2329
_config_run_key() {
	(($#)) || return 0
	awk '
		BEGIN {
			for (i = 1; i < ARGC; i++) {
				f = ARGV[i]; s = ""; r = ""; c = ""
				while ((getline line < f) > 0) {
					if (substr(line, 1, 15) == "# SWEEP_RUN_ID=") { if (s == "") s = substr(line, 16); continue }
					if (substr(line, 1, 9) == "# RUN_ID=") { if (r == "") r = substr(line, 10); continue }
					if (substr(line, 1, 1) == "#") continue
					c = line
					sub(/\t.*/, "", c)
					if (c == "run_id") { c = ""; continue }
					break
				}
				close(f)
				id = (s != "" ? s : (r != "" ? r : c))
				if (id == "") { id = f; sub(/.*\//, "", id) }
				print id
			}
			exit
		}' "$@"
}

# _config_canon_dir <dir>: the directory as `cd` and `pwd` name it (logical: `.` and a
# trailing slash resolve, and a symlink named sweep-Y keeps its sweep key), unless that
# basename is not sweep-* and the physical one (`pwd -P`) is: a symlink such as
# latest -> sweep-X is that sweep. The directory itself when `cd` fails.
_config_canon_dir() {
	local l p
	l="$(CDPATH='' cd -- "$1" 2>/dev/null && pwd)" || { printf '%s\n' "$1"; return 0; }
	case "${l##*/}" in sweep-*) printf '%s\n' "$l"; return 0 ;; esac
	p="$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P)" || p=""
	case "${p##*/}" in sweep-*) printf '%s\n' "$p" ;; *) printf '%s\n' "$l" ;; esac
}

# _config_sq <string>: the string single-quoted for a shell command line.
_config_sq() {
	local q="'\\''"
	printf "'%s'" "${1//\'/$q}"
}

# _config_run_ids <tsv>...: the distinct run ids the files carry (preamble SWEEP_RUN_ID and
# RUN_ID, and the run_id column of every data row), one per line, for the find patterns
# config_check_multi_run prints. An id holding a glob character, a slash or a space is left
# out: it is no safe -name pattern.
# shellcheck disable=SC2329
_config_run_ids() {
	awk -F'\t' '
		function add(v) { if (v != "" && v !~ /[][*?\/ ]/ && !(v in seen)) { seen[v] = 1; print v } }
		/^# SWEEP_RUN_ID=/ { add(substr($0, 16)); next }
		/^# RUN_ID=/ { add(substr($0, 10)); next }
		/^#/ || $1 == "run_id" || NF == 0 { next }
		{ add($1) }' "$@" 2>/dev/null || true
}

# config_check_multi_run <results_dir> <allow 0|1> <tsv>...: a report pools every TSV
# under its results dir (PL6), so count the runs among its inputs, with or without
# --config and --results-dir: one per sweep-* dir and one per distinct sweep-level id
# outside one (each file's directory, then _config_run_key; the per-iteration RUN_IDs of
# one sweep are one run, PL26). The directory is the logical one (`cd` and `pwd`): `.`
# and a trailing slash still resolve, and a symlink named sweep-Y keeps its sweep key; a
# symlink such as latest -> sweep-X takes its target's (_config_canon_dir). Sets
# MULTI_RUN_N, MULTI_RUN_IDS (sorted, comma-separated) and MULTI_RUN_HARNESS_SHAS /
# MULTI_RUN_ISTIO_VERSIONS (distinct preamble values in
# file order; unknown for a file without the line). More than one run with <allow> 0 dies,
# listing the five newest runs (by the timestamp their ids start with) with the commands
# that report each alone. A run outside a sweep-* dir that shares its directory with
# another run first gets commands that move it into a directory of its own, safe to paste
# twice: its input TSVs by path, then every file named after one of its ids
# (_config_run_ids: istiod-diag-<id>/, reach-<id>.tsv, ...). A run alone in its directory
# only gets its report command. With <allow> 1 (--allow-multi-run) it warns, and the
# report says so in every format (config_multi_run_note, _csv, _json).
# shellcheck disable=SC2329,SC2034
config_check_multi_run() {
	local dir="$1" allow="$2" f k d i=0 j=0 n runs new tgt cd_k alone shared id pat
	local -A run_dir=() canon=() run_files=() dkey=()
	local -a mr_keys=() mr_dirs=() rfiles=() fdirs=() cfiles=() ckeys=()
	shift 2
	local -a files=("$@")
	# Each file's canonical directory (one cd per directory); a sweep-* one is the run.
	# The files outside one get their keys from one awk (no subshell per file).
	for f in "$@"; do
		d=.
		[[ "$f" == */* ]] && d="${f%/*}"
		while [[ "$d" == */ && "$d" != / ]]; do d="${d%/}"; done
		[[ -n "$d" ]] || d=/
		if [[ -z "${canon[$d]+x}" ]]; then
			canon[$d]="$(_config_canon_dir "$d")"
			k="${canon[$d]}"
			while [[ "$k" == */ && "$k" != / ]]; do k="${k%/}"; done
			k="${k##*/}"
			case "$k" in sweep-*) dkey[$d]="$k" ;; *) dkey[$d]="" ;; esac
		fi
		fdirs+=("$d")
		[[ -n "${dkey[$d]}" ]] || cfiles+=("$f")
	done
	((${#cfiles[@]} == 0)) || mapfile -t ckeys < <(_config_run_key "${cfiles[@]}")
	for n in "${!fdirs[@]}"; do
		f="${files[n]}"
		d="${fdirs[n]}"
		k="${dkey[$d]}"
		if [[ -z "$k" ]]; then
			k="${ckeys[j]:-}"
			j=$((j + 1))
		fi
		mr_keys+=("$k") mr_dirs+=("${canon[$d]}")
		# Only a run outside a sweep-* dir needs its file list (the commands that move
		# it); appending one per file of a large sweep is quadratic.
		[[ "$k" == sweep-* ]] || run_files[$k]+="${f}"$'\n'
		[[ -z "${run_dir[$k]+x}" ]] || continue
		run_dir[$k]="$d"
	done
	runs="$(printf '%s\n' "${!run_dir[@]}" | LC_ALL=C sort)"
	MULTI_RUN_N="${#run_dir[@]}"
	MULTI_RUN_IDS="$(awk 'NF { printf "%s%s", (n++ ? "," : ""), $0 }' <<<"$runs")"
	MULTI_RUN_HARNESS_SHAS="$(_config_distinct HARNESS_SHA unknown "$@" | awk '{ printf "%s%s", (NR > 1 ? "," : ""), ($0 == "" ? "unknown" : $0) }')"
	MULTI_RUN_ISTIO_VERSIONS="$(_config_distinct ISTIO_VERSION unknown "$@" | awk '{ printf "%s%s", (NR > 1 ? "," : ""), ($0 == "" ? "unknown" : $0) }')"
	((MULTI_RUN_N > 1)) || return 0
	if ((allow)); then
		echo "warning: --allow-multi-run: this report pools ${MULTI_RUN_N} runs from ${dir} (${MULTI_RUN_IDS}); HARNESS_SHA ${MULTI_RUN_HARNESS_SHAS}; ISTIO_VERSION ${MULTI_RUN_ISTIO_VERSIONS}. Every format says so." >&2
		return 0
	fi
	{
		echo "error: ${dir} holds ${MULTI_RUN_N} runs, and a report pools every TSV under its results dir. Report one run (newest first; add your other flags):"
		# Newest first by the UTC timestamp a run id starts with (sweep- stripped), so a
		# sweep and a standalone run sort together; ids without one come last.
		while IFS= read -r k; do
			if ((++i > 5)); then
				echo "  ... and $((MULTI_RUN_N - 5)) more"
				break
			fi
			d="${run_dir[$k]}"
			case "$k" in
			sweep-*)
				echo "  ${k}:"
				echo "    $0 --results-dir $(_config_sq "$d")"
				continue
				;;
			esac
			# Alone: no other run's file sits in its directory or below it.
			cd_k="${canon[$d]}" alone=1 shared="with another run's files"
			for n in "${!mr_keys[@]}"; do
				[[ "${mr_keys[n]}" != "$k" ]] || continue
				if [[ "${mr_dirs[n]}" == "$cd_k" ]]; then
					alone=0 shared="with another run's files"
					break
				elif ((alone)) && [[ "${mr_dirs[n]}" == "${cd_k%/}"/* ]]; then
					alone=0 shared="above another run's directory (${mr_dirs[n]#"${cd_k%/}"/})"
				fi
			done
			if ((alone)); then
				echo "  ${k} (alone in ${d}):"
				echo "    $0 --results-dir $(_config_sq "$d")"
				continue
			fi
			new="run-${k%.tsv}"
			tgt="${d%/}/${new}"
			echo "  ${k} (its files are in ${d}, outside a sweep-* dir, ${shared}; move them into a directory of their own first):"
			mapfile -t rfiles <<<"${run_files[$k]%$'\n'}"
			echo "    mkdir -p $(_config_sq "$tgt")"
			printf '    for f in'
			for f in "${rfiles[@]}"; do printf ' %s' "$(_config_sq "$f")"; done
			# shellcheck disable=SC2016  # $f is the operator's shell variable
			printf '; do if [ -e "$f" ]; then mv "$f" %s; fi; done\n' "$(_config_sq "${tgt}/")"
			# Every file named after one of the run's ids (istiod-diag-<id>/, reach-<id>.tsv,
			# a report .md): never a sweep-* dir, nor the new directory itself.
			pat=""
			while IFS= read -r id; do
				[[ -z "$id" ]] || pat+="${pat:+ -o} -name $(_config_sq "*${id}*")"
			done < <(_config_run_ids "${rfiles[@]}")
			if [[ -n "$pat" ]]; then
				echo "    find $(_config_sq "$d") -mindepth 1 -maxdepth 1 \\(${pat} \\) ! -name 'sweep-*' ! -name $(_config_sq "$new") -exec mv {} $(_config_sq "${tgt}/") \;"
			fi
			echo "    $0 --results-dir $(_config_sq "$tgt")"
		done < <(awk '{ s = $0; sub(/^sweep-/, "", s); print (s ~ /^[0-9]/ ? 1 : 0) "\t" s "\t" $0 }' <<<"$runs" | LC_ALL=C sort -r | cut -f3)
		echo "Or pass --allow-multi-run to pool them on purpose: every format then says it pools ${MULTI_RUN_N} runs and lists their HARNESS_SHA and ISTIO_VERSION values."
	} >&2
	exit 1
}

# config_multi_run_note: the sentence every format of a pooled report carries, after
# config_check_multi_run. Nothing for a report of one run.
# shellcheck disable=SC2329
config_multi_run_note() {
	((${MULTI_RUN_N:-1} > 1)) || return 0
	local differ="" what=""
	[[ "${MULTI_RUN_HARNESS_SHAS}" != *,* ]] || what="harness"
	[[ "${MULTI_RUN_ISTIO_VERSIONS}" != *,* ]] || what="${what:+${what} or }Istio version"
	[[ -z "$what" ]] || differ+=" These differ, so the pooled rows were not all measured with the same ${what}."
	echo "This report pools ${MULTI_RUN_N} runs (--allow-multi-run): ${MULTI_RUN_IDS//,/, }. HARNESS_SHA: ${MULTI_RUN_HARNESS_SHAS//,/, }. ISTIO_VERSION: ${MULTI_RUN_ISTIO_VERSIONS//,/, }.${differ}"
}

# config_multi_run_csv: `# POOLED_*=` comment lines for a csv report. Nothing for one run.
# shellcheck disable=SC2329
config_multi_run_csv() {
	((${MULTI_RUN_N:-1} > 1)) || return 0
	echo "# POOLED_RUNS=${MULTI_RUN_N}"
	echo "# POOLED_RUN_IDS=${MULTI_RUN_IDS}"
	echo "# POOLED_HARNESS_SHAS=${MULTI_RUN_HARNESS_SHAS}"
	echo "# POOLED_ISTIO_VERSIONS=${MULTI_RUN_ISTIO_VERSIONS}"
	echo "# NOTE: $(config_multi_run_note)"
}

# config_multi_run_json: the pooled runs as a JSON object, for one run too. The lists are
# read from the environment (awk -v would unescape a backslash) and each value is a JSON
# string (JSON_STR_AWK, tests/lib/common.sh: \ and " escaped, a tab, carriage return and
# newline as \t, \r and \n, any other control character dropped), so a hand-edited
# HARNESS_SHA or RUN_ID keeps the JSON valid.
# shellcheck disable=SC2329
config_multi_run_json() {
	_CMR_IDS="${MULTI_RUN_IDS:-}" _CMR_SHAS="${MULTI_RUN_HARNESS_SHAS:-}" _CMR_VERS="${MULTI_RUN_ISTIO_VERSIONS:-}" \
		awk -v n="${MULTI_RUN_N:-1}" "${JSON_STR_AWK}"'
		function arr(s,    a, k, i, o) {
			k = split(s, a, ",")
			o = "["
			for (i = 1; i <= k; i++) o = o (i > 1 ? "," : "") js(a[i])
			return o "]"
		}
		BEGIN { printf "{\"runs\":%d,\"run_ids\":%s,\"harness_sha\":%s,\"istio_version\":%s}\n", n, arr(ENVIRON["_CMR_IDS"]), arr(ENVIRON["_CMR_SHAS"]), arr(ENVIRON["_CMR_VERS"]) }'
}

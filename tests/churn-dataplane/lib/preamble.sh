#!/usr/bin/env bash
# Shared helpers for tests/churn-dataplane/ scripts. Sourced, never executed.
#
# Exposes:
#   die <msg>                              -> exit 1 with stderr message
#   split_csv <csv> <out_arrayname>        -> trim+split CSV into named array
#   harness_sha                            -> `git describe --always --dirty --abbrev=7` or "unknown"
#   kube_versions <kubectl_argv...> <ctx>  -> kubectl version --output=json server gitVersion, "unreachable"/"unknown" semantics
#   probe_kube_versions <ctxs_csv> <kubectl_argv...>
#                                          -> CSV of ctx=ver pairs, concurrent with 5s timeout (PL2)
#   istiod_restart_status <port>           -> emit "0" | "1" | "unknown" based on process_start_time_seconds (PL9)
#   write_preamble <tsv> <kv pairs...>     -> write `# key=value` comment lines + RUN_ID/HARNESS_SHA (PL2, PL19)
#
# All callers are expected to have run `set -euo pipefail`.
# shellcheck shell=bash

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
}

# shellcheck disable=SC2329
harness_sha() {
	local sha
	sha="$(git describe --always --dirty --abbrev=7 2>/dev/null || true)"
	[[ -n "$sha" ]] || sha="unknown"
	printf '%s\n' "$sha"
}

# Per-context Kubernetes server version probe. Honors PL2 semantics:
#  - 5s --request-timeout
#  - unreachable cluster -> "unreachable"
#  - parsable JSON missing serverVersion -> "unknown"
# Usage: kube_versions <ctx> <kubectl_argv...>
# shellcheck disable=SC2329
kube_versions() {
	local ctx="$1"
	shift
	local out rc gitv
	out="$("$@" --context="$ctx" --request-timeout=5s version --output=json 2>/dev/null)" && rc=0 || rc=$?
	if ((rc != 0)) || [[ -z "$out" ]]; then
		printf '%s\n' "unreachable"
		return 0
	fi
	gitv="$(printf '%s' "$out" | jq -r '.serverVersion.gitVersion // empty' 2>/dev/null)"
	if [[ -z "$gitv" || "$gitv" == "null" ]]; then
		printf '%s\n' "unknown"
		return 0
	fi
	printf '%s\n' "$gitv"
}

# Concurrent probe of multiple contexts. Returns ctx1=ver1,ctx2=ver2,...
# Usage: probe_kube_versions "$ctxs_csv" <kubectl_argv...>
# shellcheck disable=SC2329
probe_kube_versions() {
	local ctxs_csv="$1"
	shift
	local -a ctxs=()
	split_csv "$ctxs_csv" ctxs
	local tmp
	tmp="$(mktemp -d)"
	local ctx pids=()
	for ctx in "${ctxs[@]}"; do
		(
			v="$(kube_versions "$ctx" "$@")"
			printf '%s=%s\n' "$ctx" "$v" > "${tmp}/${ctx}.kv"
		) &
		pids+=($!)
	done
	local p
	for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
	local first=1 line out=""
	for ctx in "${ctxs[@]}"; do
		if [[ -r "${tmp}/${ctx}.kv" ]]; then
			line="$(<"${tmp}/${ctx}.kv")"
			if ((first)); then out="$line"; first=0; else out+=",${line}"; fi
		fi
	done
	rm -rf "$tmp"
	printf '%s\n' "$out"
}

# Inspect istiod's process_start_time_seconds gauge (the Go process-level
# metric exposed by every Prometheus-instrumented Go binary, including istiod)
# to decide whether the control plane restarted during the measurement window.
# PL9: emit one of "0" / "1" / "unknown".
# Inputs:
#   $1 = pre-window process_start_time_seconds value (epoch float as string)
#   $2 = post-window process_start_time_seconds value (epoch float as string)
# Returns "unknown" if either probe sample is missing/non-numeric.
# shellcheck disable=SC2329
istiod_restart_status() {
	local pre="$1" post="$2"
	if [[ -z "$pre" || -z "$post" || "$pre" == "unknown" || "$post" == "unknown" ]]; then
		printf '%s\n' "unknown"
		return 0
	fi
	# Compare via awk to avoid bash float arithmetic limits.
	awk -v a="$pre" -v b="$post" 'BEGIN {
		if (a+0 == 0 || b+0 == 0) { print "unknown"; exit }
		if (a+0 == b+0)            { print "0"; exit }
		print "1"
	}'
}

# Scrape process_start_time_seconds once. PL21/PL22: single scrape file, single awk pass.
# Usage: istiod_start_time_seconds <port>
# shellcheck disable=SC2329
istiod_start_time_seconds() {
	local port="$1" tmpfile
	tmpfile="$(mktemp)"
	if ! curl -fsS --max-time 5 "http://localhost:${port}/metrics" -o "$tmpfile" 2>/dev/null; then
		rm -f "$tmpfile"
		printf '%s\n' "unknown"
		return 0
	fi
	# Match `process_start_time_seconds` (Go process-level metric exposed by
	# every Prometheus-instrumented Go binary, including istiod). Falls back
	# to "unknown" if the line is absent.
	awk '
	/^process_start_time_seconds[ {]/ && !/^#/ { v=$NF; found=1 }
	END {
		if (found) printf "%s\n", v
		else        printf "unknown\n"
	}' "$tmpfile"
	rm -f "$tmpfile"
}

# Write the TSV preamble required by PL2 + PL19. Every comment line is `# key=value`.
# Usage: write_preamble <tsv_file> <key1=val1> <key2=val2> ...
# shellcheck disable=SC2329
write_preamble() {
	local tsv="$1"
	shift
	local kv
	{
		echo "# churn-dataplane co-exec test"
		echo "# generated_at=$(date -Iseconds)"
		for kv in "$@"; do
			echo "# ${kv}"
		done
	} > "$tsv"
}

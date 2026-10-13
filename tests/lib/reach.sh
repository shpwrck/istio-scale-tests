#!/usr/bin/env bash
# Remote reachability check and coverage report. Sourced, never executed.
#
# Consumers: dataplane (002, 003, 004), churn-dataplane (002, 003, 004, 005)
#
# Before any load, the suite's own fortio client sends REACH_REQUESTS low-QPS
# requests to a single-endpoint per-cluster Service for every target (the source
# itself, then each remote). One row per target goes into reach-<RUN_ID>.tsv, and
# the reports aggregate those rows into a "Remote coverage" section, so a remote
# the mesh cannot reach is named instead of hiding in an n_valid < n_total gap.
# A merged multi-cluster Service would not do: Istio retries a failed request on
# another endpoint, so a dead remote shows up only as extra latency.
#
# Builds on tests/lib/fortio.sh, the one fortio JSON parser (PL41): this file only
# classifies its output and aggregates coverage. Requires common.sh (split_csv,
# is_pos_int, is_nonneg_int), fortio.sh, jq, awk, sed.
# In-process helpers never call die (PL40): a failed exec is an UNKNOWN row, and a
# missing or malformed reach file renders as "no reachability data".
#
# Knobs (config/options.env; read at call time, so a script's flag can override):
#   REACH_REQUESTS (0 = check off), REACH_QPS, REACH_HTTP_TIMEOUT_SEC,
#   REACH_ATTEMPTS, REACH_RETRY_SEC, REACH_ON_UNREACHABLE (warn|fail).
#
# Exposes:
#   REACH_EXIT_CODE                       -> 3: the reachability gate stopped the run
#   reach_validate <policy>               -> print the first bad knob, return 1
#   reach_plan_line <url_tmpl> <src> <remotes_csv> <policy>
#                                         -> one dry-run line describing the check
#   reach_summarize <json>                -> "ok total pct_200 top_code" from fortio JSON
#                                            (pct_200 4 decimals; "0 0 N/A -" with no codes)
#   reach_classify <ok> <total>           -> REACHABLE | UNREACHABLE | DEGRADED | UNKNOWN
#   reach_sanitize <text>                 -> one line, IPv4s/hostnames masked, <= 256 chars
#   reach_body_line <stdout_f> <stderr_f> -> first body line of a `fortio curl` reply
#   reach_write_header <tsv> <K=V...>     -> preamble + header, only when <tsv> is new (PL36)
#   reach_check_target <out> <ctx> <ns> <pod> <url> <kubectl...>
#                                         -> one check from <pod> on <ctx>; one result line
#   reach_check_all <tsv> <run_id> <combo_id> <mesh_size> <ns> <pod> <url_tmpl> <src>
#                   <remotes_csv> <kubectl...>
#                                         -> check every target ({ctx} in url_tmpl),
#                                            re-check the not-REACHABLE ones, append rows
#   reach_result_for <tsv> <run_id> <combo_id> <ctx>
#                                         -> "STATUS PCT_200" ("UNKNOWN N/A" with no row)
#   reach_not_reachable <tsv> <run_id> <combo_id> [remotes_csv]
#                                         -> remotes that are UNREACHABLE or UNKNOWN (one
#                                            per line); a listed remote with no row counts
#   reach_should_stop <policy> <tsv> <run_id> <combo_id> [remotes_csv]
#                                         -> true only for policy fail and a remote above
#   reach_print_summary <tsv> <run_id> <combo_id>
#                                         -> loud per-target block on stderr
#   reach_coverage_rows <dir|file>...     -> per (mesh_size, source, remote) coverage rows
#   reach_coverage_render <fmt> <rows_file>
#                                         -> text | md | csv | json | charts section
#
# reach-<RUN_ID>.tsv columns (REACH_SCHEMA=1):
#   run_id combo_id mesh_size source_ctx target_ctx target_class attempts requests
#   ok pct_200 top_code reach_status detail
# requests is the number of responses fortio counted in the last attempt (socket
# errors included, as code -1); ok is the HTTP 200s among them.
#
# Coverage rows (reach_coverage_rows, tab-separated):
#   mesh_size source_ctx target_ctx checks reachable_checks coverage_status top_code detail
# coverage_status: REACHABLE (every check), FLAPPING (some), DEGRADED (none, some
# 200s), UNREACHABLE (none, no 200s), UNKNOWN (no check could run). top_code and
# detail come from the latest check that was not REACHABLE.
# shellcheck shell=bash

# shellcheck disable=SC2034  # read by the scripts that source this file
REACH_EXIT_CODE=3
REACH_SCHEMA=1

# shellcheck disable=SC2329
reach_validate() {
	local policy="$1"
	case "$policy" in
	warn | fail) ;;
	*) echo "--on-unreachable (or REACH_ON_UNREACHABLE) must be warn or fail; got '${policy}'"; return 1 ;;
	esac
	is_nonneg_int "${REACH_REQUESTS:-10}" || { echo "--reach-requests (or REACH_REQUESTS) must be a non-negative integer; got '${REACH_REQUESTS}'"; return 1; }
	is_pos_int "${REACH_QPS:-10}" || { echo "REACH_QPS must be a positive integer; got '${REACH_QPS}'"; return 1; }
	is_pos_int "${REACH_HTTP_TIMEOUT_SEC:-3}" || { echo "REACH_HTTP_TIMEOUT_SEC must be a positive integer; got '${REACH_HTTP_TIMEOUT_SEC}'"; return 1; }
	is_pos_int "${REACH_ATTEMPTS:-3}" || { echo "REACH_ATTEMPTS must be a positive integer; got '${REACH_ATTEMPTS}'"; return 1; }
	is_nonneg_int "${REACH_RETRY_SEC:-10}" || { echo "REACH_RETRY_SEC must be a non-negative integer; got '${REACH_RETRY_SEC}'"; return 1; }
	return 0
}

# shellcheck disable=SC2329
reach_plan_line() {
	local tmpl="$1" src="$2" remotes_csv="$3" policy="$4"
	if [[ "${REACH_REQUESTS:-10}" == 0 ]]; then
		echo "Reach check: off (--reach-requests 0); --on-unreachable ${policy} has no effect"
		return 0
	fi
	echo "Reach check: ${REACH_REQUESTS:-10} requests at ${REACH_QPS:-10} QPS per target" \
		"(timeout ${REACH_HTTP_TIMEOUT_SEC:-3}s, up to ${REACH_ATTEMPTS:-3} attempts ${REACH_RETRY_SEC:-10}s apart)" \
		"to ${tmpl} for ${src} (local)${remotes_csv:+ and ${remotes_csv}}; on unreachable: ${policy}"
}

# reach_summarize <json>: the HTTP code counts come from fortio_ret_codes (the one
# RetCodes parser); this only adds them up. top_code is the most frequent code
# other than 200 ("-" when every response was a 200).
# shellcheck disable=SC2329
reach_summarize() {
	local codes
	codes="$(fortio_ret_codes "$1")" || codes="N/A"
	awk -v c="$codes" 'BEGIN {
		ok = 0; total = 0; top = "-"; topn = 0
		if (c != "N/A" && c != "") {
			n = split(c, parts, ",")
			for (i = 1; i <= n; i++) {
				eq = index(parts[i], "=")
				if (eq == 0) continue
				code = substr(parts[i], 1, eq - 1); cnt = substr(parts[i], eq + 1) + 0
				total += cnt
				if (code == "200") ok += cnt
				else if (cnt > topn) { topn = cnt; top = code }
			}
		}
		if (total > 0) printf "%d %d %.4f %s\n", ok, total, ok / total, top
		else print "0 0 N/A -"
	}'
}

# shellcheck disable=SC2329
reach_classify() {
	local ok="$1" total="$2"
	if ! [[ "$ok" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || ((total == 0)); then
		echo UNKNOWN
	elif ((ok == total)); then
		echo REACHABLE
	elif ((ok == 0)); then
		echo UNREACHABLE
	else
		echo DEGRADED
	fi
}

# reach_sanitize <text>: the detail column holds Envoy/fortio text, which can name
# pod IPs and hosts. Mask IPv4 addresses and dotted hostnames, collapse tabs and
# newlines, cut to 256 characters (an Envoy TLS failure reply runs about 225).
# Reason tokens such as CERTIFICATE_VERIFY_FAILED have no dots and survive.
# shellcheck disable=SC2329
reach_sanitize() {
	local out
	out="$(printf '%s' "$1" | tr '\t\r\n' '   ' | sed -E \
		-e 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<ip>/g' \
		-e 's/([A-Za-z0-9_-]+\.)+[A-Za-z][A-Za-z0-9-]*/<host>/g' \
		-e 's/ +/ /g' -e 's/^ //' -e 's/ $//' 2>/dev/null)" || out=""
	[[ -n "$out" ]] || out="-"
	printf '%s\n' "${out:0:256}"
}

# reach_body_line <stdout_file> <stderr_file>: `fortio curl` prints the status
# line and headers, a blank line, then the body (an Envoy local reply such as
# "no healthy upstream"). Prints the first body line, else the status line, else
# the last stderr line that is not kubectl's "command terminated ..." (fortio logs
# JSON there; its msg/err fields are used).
# shellcheck disable=SC2329
reach_body_line() {
	local line j
	line="$(awk -v OUTF="$1" '
		{ sub(/\r$/, "") }
		FILENAME == OUTF {
			if (!started) { started = 1; is_http = ($0 ~ /^HTTP\//); if (is_http) { status = $0; next } }
			if (is_http && !blank) { if ($0 == "") blank = 1; next }
			if ($0 != "" && body == "") body = $0
			next
		}
		$0 != "" && $0 !~ /^command terminated with exit code/ { err = $0 }
		END {
			if (body != "") print body
			else if (status != "") print status
			else if (err != "") print err
		}' "$1" "$2" 2>/dev/null)" || line=""
	if [[ "$line" == "{"* ]]; then
		j="$(printf '%s' "$line" | jq -r '[.msg, .err] | map(select(. != null and . != "")) | join(": ")' 2>/dev/null)" || j=""
		[[ -n "$j" ]] && line="$j"
	fi
	printf '%s\n' "$line"
}

# reach_write_header <tsv> <K=V...>: the only writer of a reach TSV's preamble and
# header, and only when the file does not exist yet (PL36). REACH_SCHEMA and the
# REACH_* knobs are always written; callers add RUN_ID, HARNESS_SHA, SUITE,
# NAMESPACE and ON_UNREACHABLE.
# shellcheck disable=SC2329
reach_write_header() {
	local tsv="$1" kv
	shift
	[[ -e "$tsv" ]] && return 0
	{
		echo "# Remote reachability check (tests/lib/reach.sh)"
		echo "# REACH_SCHEMA=${REACH_SCHEMA}"
		for kv in "$@"; do echo "# ${kv}"; done
		echo "# REACH_REQUESTS=${REACH_REQUESTS:-10}"
		echo "# REACH_QPS=${REACH_QPS:-10}"
		echo "# REACH_HTTP_TIMEOUT_SEC=${REACH_HTTP_TIMEOUT_SEC:-3}"
		echo "# REACH_ATTEMPTS=${REACH_ATTEMPTS:-3}"
		echo "# REACH_RETRY_SEC=${REACH_RETRY_SEC:-10}"
		printf 'run_id\tcombo_id\tmesh_size\tsource_ctx\ttarget_ctx\ttarget_class\tattempts\trequests\tok\tpct_200\ttop_code\treach_status\tdetail\n'
	} > "$tsv" 2>/dev/null || return 1
}

# reach_check_target <out_file> <ctx> <ns> <pod> <url> <kubectl...>: one check
# from <pod> (container fortio) on <ctx>. Writes one line to <out_file>:
#   requests ok pct_200 top_code status detail
# A failed kubectl exec gives UNKNOWN "exec failed" (PL9: never REACHABLE). A target
# that is not REACHABLE gets one `fortio curl` for the detail column. fortio load
# exits 0 even when every request fails, so the codes decide, not the exit status;
# fortio curl exits 1 on a non-2xx reply, so its exit status is ignored.
# shellcheck disable=SC2329
reach_check_target() {
	local out="$1" ctx="$2" ns="$3" pod="$4" url="$5"
	shift 5
	local json="" ok=0 total=0 pct="N/A" top="-" status="UNKNOWN" detail="-" d=""
	if json="$("$@" --context="$ctx" -n "$ns" exec "$pod" -c fortio -- \
		fortio load -qps "${REACH_QPS:-10}" -n "${REACH_REQUESTS:-10}" -c 1 \
		-timeout "${REACH_HTTP_TIMEOUT_SEC:-3}s" -allow-initial-errors -json - -quiet "$url" 2>/dev/null)"; then
		read -r ok total pct top <<<"$(reach_summarize "$json")" || true
		status="$(reach_classify "$ok" "$total")"
	else
		detail="exec failed"
	fi
	if [[ "$status" != REACHABLE && "$detail" == "-" ]]; then
		if d="$(mktemp -d 2>/dev/null)"; then
			"$@" --context="$ctx" -n "$ns" exec "$pod" -c fortio -- \
				fortio curl -timeout "${REACH_HTTP_TIMEOUT_SEC:-3}s" "$url" >"${d}/out" 2>"${d}/err" || true
			detail="$(reach_sanitize "$(reach_body_line "${d}/out" "${d}/err")")"
			rm -rf "$d"
		fi
	fi
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$total" "$ok" "$pct" "$top" "$status" "$detail" > "$out" 2>/dev/null || true
}

# reach_check_all: see the header. Targets are checked in parallel (one kubectl
# exec each); a target that is not REACHABLE is re-checked, REACH_RETRY_SEC apart,
# until REACH_ATTEMPTS checks, because cross-cluster endpoints can lag a fresh
# setup. Rows are appended source first, then remotes in the given order. Returns 1
# only when the check could not run at all (no reach TSV header, no temp dir).
# shellcheck disable=SC2329
reach_check_all() {
	local tsv="$1" run_id="$2" combo_id="$3" mesh_size="$4" ns="$5" pod="$6" tmpl="$7" src="$8" remotes_csv="$9"
	shift 9
	local -a targets=("$src") classes=(local) remotes=() att=() todo=() pids=()
	local tmp i r attempt pid url line max retry
	if [[ -n "$remotes_csv" ]]; then split_csv "$remotes_csv" remotes; fi
	for r in "${remotes[@]}"; do targets+=("$r"); classes+=(remote); done
	[[ -e "$tsv" ]] || return 1
	tmp="$(mktemp -d 2>/dev/null)" || return 1
	max="${REACH_ATTEMPTS:-3}"
	retry="${REACH_RETRY_SEC:-10}"
	for i in "${!targets[@]}"; do att[i]=0; done
	for ((attempt = 1; attempt <= max; attempt++)); do
		todo=()
		for i in "${!targets[@]}"; do
			if ((attempt == 1)); then todo+=("$i"); continue; fi
			line=""
			[[ -s "${tmp}/${i}" ]] && line="$(<"${tmp}/${i}")"
			[[ "$(printf '%s' "$line" | cut -f5)" == REACHABLE ]] || todo+=("$i")
		done
		((${#todo[@]})) || break
		if ((attempt > 1 && retry > 0)); then sleep "$retry"; fi
		pids=()
		for i in "${todo[@]}"; do
			att[i]=$attempt
			url="${tmpl//\{ctx\}/${targets[$i]}}"
			reach_check_target "${tmp}/${i}" "$src" "$ns" "$pod" "$url" "$@" &
			pids+=($!)
		done
		for pid in "${pids[@]}"; do wait "$pid" || true; done
	done
	for i in "${!targets[@]}"; do
		line=""
		[[ -s "${tmp}/${i}" ]] && line="$(<"${tmp}/${i}")"
		[[ -n "$line" ]] || line=$'0\t0\tN/A\t-\tUNKNOWN\tno result'
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$run_id" "$combo_id" "$mesh_size" "$src" \
			"${targets[$i]}" "${classes[$i]}" "${att[$i]}" "$line" >> "$tsv" 2>/dev/null || true
	done
	rm -rf "$tmp"
	return 0
}

# shellcheck disable=SC2329
reach_result_for() {
	local tsv="$1" run_id="$2" combo_id="$3" ctx="$4" out=""
	if [[ -f "$tsv" ]]; then
		out="$(awk -F'\t' -v r="$run_id" -v c="$combo_id" -v t="$ctx" '
			!/^#/ && $1 == r && $2 == c && $5 == t && NF >= 13 { res = $12 " " $10 }
			END { if (res != "") print res }' "$tsv" 2>/dev/null)" || out=""
	fi
	printf '%s\n' "${out:-UNKNOWN N/A}"
}

# shellcheck disable=SC2329
reach_not_reachable() {
	local tsv="$1" run_id="$2" combo_id="$3" remotes_csv="${4:-}" f="$1"
	[[ -f "$f" ]] || f=/dev/null
	awk -F'\t' -v r="$run_id" -v c="$combo_id" -v want="$remotes_csv" '
		BEGIN { n = split(want, w, ","); for (i = 1; i <= n; i++) if (w[i] != "" && !(w[i] in listed)) { order[++no] = w[i]; listed[w[i]] = 1 } }
		!/^#/ && $1 == r && $2 == c && $6 == "remote" && NF >= 13 {
			if (!($5 in listed)) { order[++no] = $5; listed[$5] = 1 }
			st[$5] = $12
		}
		END {
			for (i = 1; i <= no; i++) {
				t = order[i]
				if (!(t in st) || st[t] == "UNREACHABLE" || st[t] == "UNKNOWN") print t
			}
		}' "$f" 2>/dev/null || true
}

# shellcheck disable=SC2329
reach_should_stop() {
	local policy="$1"
	shift
	[[ "$policy" == fail ]] || return 1
	[[ -n "$(reach_not_reachable "$@")" ]]
}

# shellcheck disable=SC2329
reach_print_summary() {
	local tsv="$1" run_id="$2" combo_id="$3"
	[[ -f "$tsv" ]] || return 0
	awk -F'\t' -v r="$run_id" -v c="$combo_id" '
		!/^#/ && $1 == r && $2 == c && NF >= 13 {
			src = $4
			line = sprintf("  %-11s %s %s/%s (%s, attempts=%s", $12, $5, $9, $8, $6, $7)
			if ($12 != "REACHABLE") line = line sprintf(", top_code=%s, detail=\"%s\"", $11, $13)
			lines[++n] = line ")"
			if ($6 == "remote") { rem++; if ($12 != "REACHABLE") { bad++; badl = badl (badl == "" ? "" : " ") $5 } }
		}
		END {
			if (n == 0) exit
			printf "=== Remote reachability from %s (HTTP 200s/responses per target) ===\n", src
			for (i = 1; i <= n; i++) print lines[i]
			if (bad > 0) printf "WARNING: %d of %d remotes NOT reachable from %s: %s\n", bad, rem, src, badl
			else if (rem > 0) printf "All %d remotes reachable from %s.\n", rem, src
		}' "$tsv" >&2 2>/dev/null || true
}

# reach_coverage_rows <dir|file>...: every reach-*.tsv under the given directories
# (and every given file), remote rows only, aggregated by (mesh_size, source_ctx,
# target_ctx) in mesh-size order. Files are read in name order (reach-<RUN_ID>
# sorts by time), so "latest" is the last row read.
# shellcheck disable=SC2329
reach_coverage_rows() {
	local p f
	local -a files=()
	for p in "$@"; do
		if [[ -d "$p" ]]; then
			while IFS= read -r f; do files+=("$f"); done < <(find "$p" -name 'reach-*.tsv' -type f 2>/dev/null | sort)
		elif [[ -f "$p" ]]; then
			files+=("$p")
		fi
	done
	((${#files[@]})) || return 0
	awk -F'\t' '
		BEGIN { OFS = "\t" }
		/^#/ || $1 == "run_id" || NF < 13 || $6 != "remote" { next }
		{
			k = $3 SUBSEP $4 SUBSEP $5
			if (!(k in checks)) { keys[++n] = k; ms[n] = $3 }
			checks[k]++
			if ($12 == "REACHABLE") reach[k]++
			else {
				seen[k, $12] = 1
				top[k] = $11; det[k] = $13
			}
		}
		END {
			for (i = 2; i <= n; i++) {
				t = keys[i]; tm = ms[i]; j = i - 1
				while (j >= 1 && ms[j] + 0 > tm + 0) { keys[j + 1] = keys[j]; ms[j + 1] = ms[j]; j-- }
				keys[j + 1] = t; ms[j + 1] = tm
			}
			for (i = 1; i <= n; i++) {
				k = keys[i]; split(k, p, SUBSEP)
				c = checks[k]; r = reach[k] + 0
				if (r == c) cov = "REACHABLE"
				else if (r > 0) cov = "FLAPPING"
				else if ((k, "DEGRADED") in seen) cov = "DEGRADED"
				else if ((k, "UNREACHABLE") in seen) cov = "UNREACHABLE"
				else cov = "UNKNOWN"
				print p[1], p[2], p[3], c, r, cov, ((k in top) ? top[k] : "-"), ((k in det) ? det[k] : "-")
			}
		}' "${files[@]}" 2>/dev/null || true
}

# reach_coverage_render <fmt> <rows_file>: render reach_coverage_rows output.
#   text   "REMOTE COVERAGE mesh_size=N source=S: R/T remotes reachable", then one
#          WARNING line per group with a remote that is not REACHABLE
#   md     "## Remote coverage" with a summary table, a table of the remotes that
#          are not REACHABLE and a "> ⚠" callout per group that has one
#   csv    "# REMOTE_COVERAGE ..." and "# REMOTE_COVERAGE_TARGET ..." comment lines
#   json   {"remote_coverage": {data, not_reachable, groups: [...]}}
#   charts one "> ⚠" line per group with a remote that is not REACHABLE (else nothing)
# Remote counts are reachable/total remotes; per-remote checks are
# reachable_checks/checks (PL17).
# shellcheck disable=SC2329
reach_coverage_render() {
	local fmt="$1" rows=""
	if [[ -n "${2:-}" ]]; then rows="$(cat "$2" 2>/dev/null)" || rows=""; fi
	if [[ -z "$rows" ]]; then
		case "$fmt" in
		text) echo "REMOTE COVERAGE: no reachability data (no reach-*.tsv: the check was off or the run predates it)" ;;
		md)
			# shellcheck disable=SC2016  # literal backticks for markdown code
			printf '## Remote coverage\n\nno reachability data (no `reach-*.tsv`: the check was off or the run predates it).\n'
			;;
		csv) echo "# REMOTE_COVERAGE=no reachability data" ;;
		json) echo '{"remote_coverage":{"data":false,"not_reachable":0,"groups":[]}}' ;;
		esac
		return 0
	fi
	case "$fmt" in
	json)
		printf '%s\n' "$rows" | jq -R -s '
			split("\n") | map(select(length > 0) | split("\t") | select(length >= 8)
				| {mesh_size: (.[0] | tonumber? // .[0]), source_ctx: .[1], target_ctx: .[2],
				   checks: (.[3] | tonumber), reachable_checks: (.[4] | tonumber),
				   coverage_status: .[5], top_code: .[6], detail: .[7]})
			| group_by([.mesh_size, .source_ctx])
			| map({mesh_size: .[0].mesh_size, source_ctx: .[0].source_ctx,
				remotes: length, remotes_reachable: (map(select(.coverage_status == "REACHABLE")) | length),
				not_reachable: map(select(.coverage_status != "REACHABLE")),
				targets: .})
			| {remote_coverage: {data: true,
				not_reachable: (map(.not_reachable | length) | add // 0), groups: .}}
		' 2>/dev/null || echo '{"remote_coverage":{"data":false,"not_reachable":0,"groups":[]}}'
		;;
	*)
		printf '%s\n' "$rows" | awk -F'\t' -v fmt="$fmt" '
			# Escape "|" for markdown tables without gsub (backslashes in a gsub
			# replacement differ between awks).
			function esc(s,    out, i) {
				out = ""
				while ((i = index(s, "|")) > 0) { out = out substr(s, 1, i - 1) "\\|"; s = substr(s, i + 1) }
				return out s
			}
			NF >= 8 {
				g = $1 SUBSEP $2
				if (!(g in tot)) { gs[++ng] = g; gm[ng] = $1; gsrc[ng] = $2 }
				tot[g]++
				if ($6 == "REACHABLE") ok[g]++
				else {
					bad[g] = bad[g] (bad[g] == "" ? "" : ",") $3
					why[g] = why[g] (why[g] == "" ? "" : "; ") sprintf("%s (%s %s/%s, %s, \"%s\")", $3, $6, $5, $4, $7, $8)
				}
				rows[++nr] = $0
			}
			END {
				if (fmt == "text") {
					for (i = 1; i <= ng; i++) {
						g = gs[i]
						printf "REMOTE COVERAGE mesh_size=%s source=%s: %d/%d remotes reachable\n", gm[i], gsrc[i], ok[g] + 0, tot[g]
						if (g in bad) printf "WARNING: remotes NOT reachable at mesh_size=%s from %s: %s\n", gm[i], gsrc[i], why[g]
					}
				} else if (fmt == "csv") {
					for (i = 1; i <= ng; i++) {
						g = gs[i]
						printf "# REMOTE_COVERAGE mesh_size=%s source=%s reachable=%d/%d not_reachable=%s\n", gm[i], gsrc[i], ok[g] + 0, tot[g], ((g in bad) ? bad[g] : "-")
					}
					for (i = 1; i <= nr; i++) {
						split(rows[i], f, "\t")
						printf "# REMOTE_COVERAGE_TARGET mesh_size=%s source=%s target=%s checks=%s/%s status=%s top_code=%s\n", f[1], f[2], f[3], f[5], f[4], f[6], f[7]
					}
				} else if (fmt == "md") {
					print "## Remote coverage"
					print ""
					print "Reachability checked before the load, from each source to every remote (`reach-*.tsv`)."
					print ""
					print "| mesh_size | source | remotes reachable | not reachable |"
					print "|-----------|--------|-------------------|---------------|"
					for (i = 1; i <= ng; i++) {
						g = gs[i]
						printf "| %s | %s | %d/%d | %s |\n", gm[i], gsrc[i], ok[g] + 0, tot[g], ((g in bad) ? bad[g] : "-")
					}
					# Per-remote detail only for remotes that were not REACHABLE on every
					# check, so a 20-cluster sweep does not print ~190 all-clear rows.
					nbad = 0
					for (i = 1; i <= nr; i++) {
						split(rows[i], f, "\t")
						if (f[6] == "REACHABLE") continue
						if (!nbad++) {
							print ""
							print "| mesh_size | source | remote | checks reachable | coverage | top_code | detail |"
							print "|-----------|--------|--------|------------------|----------|----------|--------|"
						}
						printf "| %s | %s | %s | %s/%s | %s | %s | %s |\n", f[1], f[2], f[3], f[5], f[4], f[6], esc(f[7]), esc(f[8])
					}
					for (i = 1; i <= ng; i++) {
						g = gs[i]
						if (g in bad) printf "\n> \342\232\240 Remotes NOT reachable at mesh_size=%s from %s: %s\n", gm[i], gsrc[i], esc(why[g])
					}
				} else if (fmt == "charts") {
					for (i = 1; i <= ng; i++) {
						g = gs[i]
						if (g in bad) printf "> \342\232\240 Remotes NOT reachable at mesh_size=%s from %s: %s (see Remote coverage in the markdown report).\n", gm[i], gsrc[i], bad[g]
					}
				}
			}' 2>/dev/null || true
		;;
	esac
	return 0
}

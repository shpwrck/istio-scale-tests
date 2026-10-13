#!/usr/bin/env bash
# Generate summary statistics from data-plane latency TSV files.
#
# Aggregates by (mesh_size, qps_target, target_class) — so local and remote
# rows are reported separately rather than averaged together.
# Filters poisoned rows (status != OK, istiod_restarted != 0) from numeric
# aggregation but still counts them in count_total and reports the gap.
# Propagates the first TSV's preamble metadata into every output format.
# Every format also carries a "Local baseline" verdict per (mesh_size, qps_target),
# so a same-cluster number that was dropped or never measured is always visible.
# Every format also has a "Remote coverage" section, before the results table: the
# reach-*.tsv checks (tests/lib/reach.sh) per remote, plus the remotes whose latency
# rows are all or partly invalid, so an n_valid < n_total gap names its remotes.
#
# Every format also carries RUN_CONFIG / RUN_CONFIG_SHA256 (the --config behind the
# inputs) over all input TSVs: mixed:a,b with a warning when they differ (PL26).
#
# Usage:
#   ./tests/dataplane/004-report-results.sh [--results-dir DIR] [--format FMT] [--fail-on-unreachable]
#   ./tests/dataplane/004-report-results.sh --config tests/dataplane/configs/smoke.env \
#     --results-dir tests/dataplane/results/smoke/sweep-<RUN_ID> --format markdown
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # config_preload, config_report_value
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
config_preload dataplane "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"  # DATAPLANE_MIN_QPS_RATIO (fallback for TSVs without one)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/reach.sh"  # reach_coverage_rows, reach_coverage_render

RESULTS_DIR="$(config_repo_path "${DATAPLANE_RESULTS_DIR}")"
# 1 when --results-dir is passed (gates the multi-run warning below).
RESULTS_DIR_FROM_FLAG=0
FORMAT="text"
FAIL_ON_UNREACHABLE=0


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE      Run config of KEY=value lines (config/options.env keys; see
                     tests/dataplane/README.md, "Run config"). Precedence: flag >
                     --config > environment > default. Without --results-dir, warns
                     when the results dir holds more than one run.
  --results-dir DIR  Results directory (default: ${DATAPLANE_RESULTS_DIR}).
                     A directory containing latency-*.tsv files; a sweep-*/
                     subdir from 003 also works.
  --format FMT       Output format: text, csv, markdown (or md), json, charts (default: text).
  --fail-on-unreachable
                     After the output, exit 3 when a remote's reach coverage is not
                     REACHABLE (rule=reach_coverage) or a remote has no valid latency
                     row (rule=no_valid_rows); stderr names the rule and the remotes.
  -h, --help         Show this help.

Every format includes a "Remote coverage" section before the results table: per
mesh size and source, how many remotes passed every reach check (reach-*.tsv from
002, statuses REACHABLE, FLAPPING, DEGRADED, UNREACHABLE, UNKNOWN), and the remotes
with no or only some valid latency rows (n_valid/n_total with their statuses). A
TSV recorded before the reach check has no reach file: "no reachability data".

Every format includes a "Local baseline" verdict: OK when every local cell has all
rows valid and none below the QPS ratio, else one line per
dropped/degraded/unchecked/missing cell with the reason (saturated_unflagged,
saturated, errors, percentile_missing, failed, istiod_restarted,
istiod_restart_unknown, or for a mesh size without local rows the lower-cased
placeholder status, e.g. setup_failed). UNCHECKED: every row is status=OK but some
delivered less than the ratio x target; only TSVs without MIN_QPS_RATIO in the
preamble (recorded before the QPS_SHORTFALL check) can produce it.

Sweep placeholder rows (target_class na: SETUP_FAILED, PROBE_FAILED,
STOPPED_UNREACHABLE) form no table cell; every format names them per mesh size
("Placeholder rows", csv "# PLACEHOLDER=<mesh>:<STATUS>:<n>", json
summary.placeholders), also when that mesh size has measured rows.

Environment:
  DATAPLANE_MIN_QPS_RATIO  shortfall ratio for TSVs whose preamble has no MIN_QPS_RATIO.
  DATAPLANE_RESULTS_DIR    --results-dir default (relative to the repo root).

Exit status: 0, 1 on an error, 3 with --fail-on-unreachable when a rule fired.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--config)
		# Loaded by config_preload above.
		[[ -n "${2:-}" ]] || die "--config requires a value"
		shift 2
		;;
	--results-dir)
		[[ -n "${2:-}" ]] || die "--results-dir requires a value"
		RESULTS_DIR="$2"
		RESULTS_DIR_FROM_FLAG=1
		shift 2
		;;
	--format)
		[[ -n "${2:-}" ]] || die "--format requires a value"
		FORMAT="$2"
		shift 2
		;;
	--fail-on-unreachable)
		FAIL_ON_UNREACHABLE=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown option: $1 (try --help)"
		;;
	esac
done

case "$FORMAT" in
md) FORMAT=markdown ;;
text|csv|markdown|json|charts) ;;
*) die "unknown format: $FORMAT (use text, csv, markdown, json, or charts)" ;;
esac

[[ -d "$RESULTS_DIR" ]] || die "results directory not found: $RESULTS_DIR"

TSV_FILES=()
while IFS= read -r f; do
	TSV_FILES+=("$f")
done < <(find "$RESULTS_DIR" -name 'latency-*.tsv' -type f 2>/dev/null | sort)

if [[ ${#TSV_FILES[@]} -eq 0 ]]; then
	die "no TSV result files found in $RESULTS_DIR"
fi

# Collect preamble (# KEY=VALUE lines) from the first TSV. KUBE_VERSION[ctx]
# keys are preserved as-is. Output is captured as an array of "KEY=VALUE"
# strings to make formatting consistent across output formats.
PREAMBLE=()
while IFS= read -r line; do
	PREAMBLE+=("$line")
done < <(awk '
	/^# / && /=/ {
		line = $0
		sub(/^# /, "", line)
		# Accept KEY=VALUE and KEY[ANY]=VALUE; reject pure comments like "# foo bar".
		if (line ~ /^[A-Z][A-Z0-9_]*(\[[^]]+\])?=/) print line
		next
	}
	/^[^#]/ { exit }
' "${TSV_FILES[0]}")

# Which --config produced the inputs (PL2/PL19), over every input rather than the first
# file: `none` without one, `unknown` for files written before the key existed,
# mixed:a,b with a warning when they differ (PL26).
_pre=()
for kv in "${PREAMBLE[@]}"; do
	case "$kv" in RUN_CONFIG=* | RUN_CONFIG_SHA256=*) ;; *) _pre+=("$kv") ;; esac
done
PREAMBLE=("${_pre[@]}"
	"RUN_CONFIG=$(config_report_value RUN_CONFIG "${TSV_FILES[@]}")"
	"RUN_CONFIG_SHA256=$(config_report_value RUN_CONFIG_SHA256 "${TSV_FILES[@]}")")
unset _pre
# PL6: a results dir from --config (or the default) is a base dir that can hold many
# sweeps, and the report aggregates all of them.
if ((RUN_CONFIG_LOADED)) && ! ((RESULTS_DIR_FROM_FLAG)); then
	config_warn_multi_run "$RESULTS_DIR" "${TSV_FILES[@]}"
fi

# AWK aggregation: group by (mesh_size, qps_target, target_class).
# Counts:
#   count_total — any row with NF>=17
#   count_valid — status==OK && istiod_restarted==0
# Numeric aggregations use only valid rows. Sweep placeholder rows (target_class na:
# SETUP_FAILED, PROBE_FAILED, STOPPED_UNREACHABLE) are no measurement cell and stay
# out of the table; the row summary below counts them, PH_ROWS names them per mesh
# size in every format, and the Local baseline also reports a mesh size with no
# local row as MISSING (the placeholder status as reason).
# shellcheck disable=SC2016
AGG_SCRIPT='
BEGIN { OFS="\t" }
/^#/ { next }
/^run_id\t/ { next }
NF < 17 { next }
$17 == "na" { next }
{
	mesh = $2; qps = $5; cls = $17
	status = $14; restart = $16
	key = mesh "\t" qps "\t" cls
	count_total[key]++
	if (status == "OK" && restart == "0") {
		count_valid[key]++
		# Treat "N/A" as missing — skip numeric accumulation for that field only.
		if ($9 != "N/A")  { p50_sum[key] += $9+0;  p50_n[key]++ }
		if ($10 != "N/A") { p90_sum[key] += $10+0; p90_n[key]++ }
		if ($11 != "N/A") { p99_sum[key] += $11+0; p99_n[key]++ }
		if ($12 != "N/A") { p999_sum[key] += $12+0; p999_n[key]++ }
		if ($13 != "N/A") { max_sum[key] += $13+0; max_n[key]++ }
		if ($6  != "N/A") { qps_sum[key] += $6+0;  qps_n[key]++ }
		if ($15 != "N/A") { pct_sum[key] += $15+0; pct_n[key]++ }
	}
}
function favg(s, n) { return n > 0 ? s / n : "N/A" }
END {
	# Stable sort: mesh asc (num), qps asc (num), cls asc (lex).
	i = 0
	for (k in count_total) { keys[++i] = k }
	n = i
	for (i = 1; i <= n; i++) {
		for (j = i+1; j <= n; j++) {
			split(keys[i], a, "\t"); split(keys[j], b, "\t")
			swap = 0
			if ((a[1]+0) > (b[1]+0)) swap = 1
			else if ((a[1]+0) == (b[1]+0)) {
				if ((a[2]+0) > (b[2]+0)) swap = 1
				else if ((a[2]+0) == (b[2]+0) && a[3] > b[3]) swap = 1
			}
			if (swap) { t = keys[i]; keys[i] = keys[j]; keys[j] = t }
		}
	}
	for (i = 1; i <= n; i++) {
		k = keys[i]; split(k, p, "\t")
		ct = count_total[k]; cv = count_valid[k] + 0
		print p[1], p[2], p[3], ct, cv,
			favg(p50_sum[k],  p50_n[k]),
			favg(p90_sum[k],  p90_n[k]),
			favg(p99_sum[k],  p99_n[k]),
			favg(p999_sum[k], p999_n[k]),
			favg(max_sum[k],  max_n[k]),
			favg(qps_sum[k],  qps_n[k]),
			favg(pct_sum[k],  pct_n[k])
	}
}
'

AGG_TSV=$(cat "${TSV_FILES[@]}" | awk -F'\t' "$AGG_SCRIPT")

# Row summary over every data row, placeholders included (PL15): total, valid (the
# AGG predicate), skipped (no load ran because the reach check found the remote
# UNREACHABLE: UNREACHABLE rows and the STOPPED_UNREACHABLE placeholder) and dropped
# (every other row that is not valid: poisoned, failed, or a SETUP_FAILED /
# PROBE_FAILED placeholder). TOTAL_ALL = VALID_ALL + DROPPED_ALL + SKIPPED_ALL.
read -r TOTAL_ALL VALID_ALL SKIPPED_ALL < <(cat "${TSV_FILES[@]}" | awk -F'\t' '
	/^#/ || /^run_id\t/ || NF < 17 { next }
	{
		t++
		if ($14 == "OK" && $16 == "0") v++
		else if ($14 == "UNREACHABLE" || $14 == "STOPPED_UNREACHABLE") s++
	}
	END { print t + 0, v + 0, s + 0 }')
DROPPED_ALL=$(( TOTAL_ALL - VALID_ALL - SKIPPED_ALL ))

# rows_summary: "<T> total / <V> valid rows — <D> dropped (poisoned), <S> skipped
# (remote unreachable)." with only the non-zero parts; text and markdown print it
# when a row is not valid, csv and json carry the same counts.
rows_summary() {
	local parts=""
	((DROPPED_ALL > 0)) && parts="${DROPPED_ALL} dropped (poisoned)"
	((SKIPPED_ALL > 0)) && parts="${parts:+${parts}, }${SKIPPED_ALL} skipped (remote unreachable)"
	printf '%s total / %s valid rows \xe2\x80\x94 %s.\n' "$TOTAL_ALL" "$VALID_ALL" "$parts"
}

# PH_ROWS: the placeholder rows (target_class na) per (mesh_size, status), mesh sizes
# ascending, statuses in file order. They form no cell, so this is the only place a
# placeholder shows when its mesh size also has measured rows (a failed repetition,
# or a probe that died after some QPS levels). Every format names them, and
# n_total = the cells' n_total + N_PLACEHOLDER (PL15). Tab-separated:
#   mesh_size status n_rows
PH_ROWS="$(cat "${TSV_FILES[@]}" | awk -F'\t' '
	BEGIN { OFS = "\t" }
	/^#/ || /^run_id\t/ || NF < 17 || $17 != "na" { next }
	{
		m = $2; st = $14
		if (!(m in seen)) { seen[m] = 1; ms[++n] = m }
		if (!((m, st) in c)) { if (m in sl) sl[m] = sl[m] SUBSEP st; else sl[m] = st }
		c[m, st]++
	}
	END {
		for (i = 2; i <= n; i++) {
			t = ms[i]; j = i - 1
			while (j >= 1 && ms[j] + 0 > t + 0) { ms[j + 1] = ms[j]; j-- }
			ms[j + 1] = t
		}
		for (i = 1; i <= n; i++) {
			k = split(sl[ms[i]], s, SUBSEP)
			for (j = 1; j <= k; j++) print ms[i], s[j], c[ms[i], s[j]]
		}
	}')"
N_PLACEHOLDER="$(awk -F'\t' 'NF >= 3 { n += $3 } END { print n + 0 }' <<<"$PH_ROWS")"

# placeholder_lines: one line per mesh size with placeholder rows, e.g.
# "Placeholder rows (no table cell): mesh_size=2 PROBE_FAILED=1". Nothing when there
# are none. text prints them as-is, markdown as a list, charts as notes.
placeholder_lines() {
	awk -F'\t' '
		NF >= 3 {
			if ($1 in l) l[$1] = l[$1] "," $2 "=" $3
			else { ms[++n] = $1; l[$1] = $2 "=" $3 }
		}
		END { for (i = 1; i <= n; i++) printf "Placeholder rows (no table cell): mesh_size=%s %s\n", ms[i], l[ms[i]] }' <<<"$PH_ROWS"
}

# --- Local baseline verdict --------------------------------------------------
# One pass over the TSV files (not cat'ed, so FNR==1 marks each file and the
# per-file preamble keys SERVER_REPLICAS and MIN_QPS_RATIO apply to that file's
# rows only, PL26). Output lines (tab-separated):
#   ratio   <distinct MIN_QPS_RATIO values of files with local rows>
#   legacy  <files with local rows and no valid MIN_QPS_RATIO line>
#   cell    mesh qps n_total n_valid verdict reason qps_actual qps_ratio server_replicas remote statuses ok_below_ratio remote_unreachable
#   missing mesh reason
# n_valid uses the AGG predicate (status OK, istiod_restarted 0) and is never
# changed here. ok_below_ratio counts valid rows below MIN_QPS_RATIO x target:
# only a TSV recorded before 002 had the QPS_SHORTFALL check (no MIN_QPS_RATIO
# line, ratio = the env fallback) can hold one, and its numbers are in the AGG
# averages. verdict is ok (all valid, none below the ratio), unchecked (all valid,
# some below the ratio), degraded (some valid) or dropped (none). reason, first that
# applies: saturated_unflagged (ok_below_ratio > 0), saturated (QPS_SHORTFALL, or
# any row below MIN_QPS_RATIO x target), errors, percentile_missing, failed,
# istiod_restarted, istiod_restart_unknown, other.
# qps_actual is the worst delivered QPS (FAILED rows skipped). server_replicas is
# the source context's <ready>/<spec> from each file's preamble ("|"-joined if
# files differ). remote is n_valid/n_total of the remote cell at the same
# mesh_size and qps_target, or none. It counts only remote rows that carried load:
# UNREACHABLE rows (the reach check skipped that remote's load) are left out and
# counted in remote_unreachable instead, so remote=n/n still tells a local-server
# limit from a client-sidecar one (PL31). STOPPED_UNREACHABLE is class na.
# A mesh size with rows but no local row is "missing"; its reason is the
# lower-cased status of its placeholder rows (class na), else "missing".
# POSIX awk only: insertion sorts, no asorti or length(array).
LB_DEFAULT_RATIO="${DATAPLANE_MIN_QPS_RATIO:-0.95}"
if ! is_ratio "$LB_DEFAULT_RATIO"; then
	echo "warning: DATAPLANE_MIN_QPS_RATIO='${LB_DEFAULT_RATIO}' is not a decimal in (0,1]; using 0.95" >&2
	LB_DEFAULT_RATIO=0.95
fi
# shellcheck disable=SC2016
LB_SCRIPT='
function sr_lookup(s, ctx,    n, parts, i) {
	if (s == "") return "unknown"
	n = split(s, parts, ",")
	for (i = 1; i <= n; i++) if (index(parts[i], ctx "=") == 1) return substr(parts[i], length(ctx) + 2)
	return "unknown"
}
function addu(list, v) { return (list == "") ? v : list "," v }
BEGIN { OFS = "\t" }
FNR == 1 { sr = ""; fr = def_ratio; has_ratio = 0; file_local = 0 }
/^# SERVER_REPLICAS=/ { sr = substr($0, 19); next }
/^# MIN_QPS_RATIO=/ { v = substr($0, 17); if (v ~ /^([0-9]+(\.[0-9]+)?|\.[0-9]+)$/ && v + 0 > 0) { fr = v; has_ratio = 1 }; next }
/^#/ { next }
$1 == "run_id" { next }
NF < 17 { next }
{
	mesh = $2; qps = $5; cls = $17; st = $14; rs = $16
	if (!(mesh in mesh_seen)) { mesh_seen[mesh] = 1; mesh_order[++n_mesh] = mesh }
	if (cls == "na") {
		r = tolower(st)
		if (!((mesh, r) in ph_seen)) { ph_seen[mesh, r] = 1; ph[mesh] = addu(ph[mesh], r) }
		next
	}
	key = mesh "\t" qps
	if (cls == "remote") {
		if (st == "UNREACHABLE") { ru[key]++; next }
		rt[key]++; if (st == "OK" && rs == "0") rv[key]++
		next
	}
	if (cls != "local") next
	has_local[mesh] = 1
	if (!file_local) { file_local = 1; if (!has_ratio) n_legacy++ }
	if (!(fr in ratio_seen)) { ratio_seen[fr] = 1; ratios = addu(ratios, fr) }
	if (!(key in lt)) keys[++n_keys] = key
	lt[key]++
	if (st == "OK" && rs == "0") lv[key]++
	if (!((key, st) in stc)) stl[key] = addu(stl[key], st)
	stc[key, st]++
	if (st == "QPS_SHORTFALL") sat[key] = 1
	if (st == "ERROR_RATE_HIGH") err[key] = 1
	if (st == "PERCENTILE_MISSING") pm[key] = 1
	if (st == "FAILED") fl[key] = 1
	if (rs == "1") rst[key] = 1
	else if (rs != "0") rsu[key] = 1
	if (st != "FAILED" && $6 ~ /^[0-9]+(\.[0-9]+)?$/ && qps + 0 > 0) {
		if (!(key in worst) || $6 + 0 < worst[key]) worst[key] = $6 + 0
		if ($6 + 0 < fr * qps) { sat[key] = 1; if (st == "OK" && rs == "0") ubr[key]++ }
	}
	v = sr_lookup(sr, $3)
	if (!((key, v) in sr_seen)) { sr_seen[key, v] = 1; srv[key] = (srv[key] == "") ? v : srv[key] "|" v }
}
END {
	print "ratio", (ratios == "" ? def_ratio : ratios)
	print "legacy", n_legacy + 0
	for (i = 2; i <= n_keys; i++) {
		t = keys[i]; split(t, b, "\t"); j = i - 1
		while (j >= 1) {
			split(keys[j], a, "\t")
			if (a[1] + 0 > b[1] + 0 || (a[1] + 0 == b[1] + 0 && a[2] + 0 > b[2] + 0)) { keys[j + 1] = keys[j]; j-- }
			else break
		}
		keys[j + 1] = t
	}
	for (i = 1; i <= n_keys; i++) {
		k = keys[i]; split(k, p, "\t")
		tot = lt[k]; val = lv[k] + 0
		verdict = (val == tot) ? ((k in ubr) ? "unchecked" : "ok") : (val == 0 ? "dropped" : "degraded")
		reason = "-"
		if (verdict != "ok") {
			if (k in ubr) reason = "saturated_unflagged"
			else if (k in sat) reason = "saturated"
			else if (k in err) reason = "errors"
			else if (k in pm) reason = "percentile_missing"
			else if (k in fl) reason = "failed"
			else if (k in rst) reason = "istiod_restarted"
			else if (k in rsu) reason = "istiod_restart_unknown"
			else reason = "other"
		}
		qa = (k in worst) ? worst[k] : "N/A"
		qr = (k in worst) ? sprintf("%.4f", worst[k] / p[2]) : "N/A"
		remote = (k in rt) ? (rv[k] + 0) "/" rt[k] : "none"
		ns = split(stl[k], sl, ","); sts = ""
		for (j = 1; j <= ns; j++) sts = sts (j > 1 ? "," : "") sl[j] "=" stc[k, sl[j]]
		print "cell", p[1], p[2], tot, val, verdict, reason, qa, qr, srv[k], remote, sts, ((k in ubr) ? ubr[k] : 0), ru[k] + 0
	}
	for (i = 2; i <= n_mesh; i++) {
		t = mesh_order[i]; j = i - 1
		while (j >= 1 && mesh_order[j] + 0 > t + 0) { mesh_order[j + 1] = mesh_order[j]; j-- }
		mesh_order[j + 1] = t
	}
	for (i = 1; i <= n_mesh; i++) {
		m = mesh_order[i]
		if (m in has_local) continue
		print "missing", m, ((m in ph) ? ph[m] : "missing")
	}
}
'
LB_RATIO="$LB_DEFAULT_RATIO"
LB_LEGACY_FILES=0  # files with local rows whose preamble has no MIN_QPS_RATIO
LB_CELLS=()    # "cell" lines without the tag
LB_MISSING=()  # "missing" lines without the tag
while IFS= read -r line; do
	case "$line" in
	ratio$'\t'*) LB_RATIO="${line#ratio$'\t'}" ;;
	legacy$'\t'*) LB_LEGACY_FILES="${line#legacy$'\t'}" ;;
	cell$'\t'*) LB_CELLS+=("${line#cell$'\t'}") ;;
	missing$'\t'*) LB_MISSING+=("${line#missing$'\t'}") ;;
	esac
done < <(awk -F'\t' -v def_ratio="$LB_DEFAULT_RATIO" "$LB_SCRIPT" "${TSV_FILES[@]}")

# Overall verdict: the worst cell (ok < degraded < unchecked < missing < dropped);
# missing when there is no local row at all. unchecked ranks above degraded: a
# degraded cell averages only rows that passed every check, an unchecked one
# averages rows that missed the target QPS.
LB_VERDICT="ok"
lb_rank() { case "$1" in ok) echo 0 ;; degraded) echo 1 ;; unchecked) echo 2 ;; missing) echo 3 ;; dropped) echo 4 ;; esac; }
lb_worse() { (( $(lb_rank "$1") > $(lb_rank "$LB_VERDICT") )) && LB_VERDICT="$1"; return 0; }
LB_TOP_QPS=0
for c in "${LB_CELLS[@]}"; do
	IFS=$'\t' read -r _m q _t _v verdict _rest <<<"$c"
	lb_worse "$verdict"
	[[ "$q" =~ ^[0-9]+$ ]] && (( q > LB_TOP_QPS )) && LB_TOP_QPS="$q"
done
((${#LB_MISSING[@]})) && lb_worse missing
((${#LB_CELLS[@]})) || LB_VERDICT="missing"

# local_baseline_lines: the human-readable verdict, one line per bad cell (or one
# OK line). Text prints them as-is, markdown as a list.
local_baseline_lines() {
	local c m q t v verdict reason qa qr srep remote sts nbr unr pct line legacy=""
	if [[ "$LB_VERDICT" == ok ]]; then
		local cells="${#LB_CELLS[@]} cells"
		((${#LB_CELLS[@]} == 1)) && cells="1 cell"
		# A TSV without MIN_QPS_RATIO was never checked at run time; say the report did it.
		if ((LB_LEGACY_FILES > 0)); then
			legacy=", applied by this report to ${LB_LEGACY_FILES} file"
			((LB_LEGACY_FILES == 1)) || legacy+="s"
			legacy+=" without MIN_QPS_RATIO"
		fi
		echo "Local baseline: OK at every QPS level (${cells}, top qps_target=${LB_TOP_QPS}, min_qps_ratio=${LB_RATIO}${legacy})"
		return 0
	fi
	for c in "${LB_CELLS[@]}"; do
		IFS=$'\t' read -r m q t v verdict reason qa qr srep remote sts nbr unr <<<"$c"
		[[ "$verdict" == ok ]] && continue
		pct="N/A"
		[[ "$qr" != "N/A" ]] && pct="$(awk -v r="$qr" 'BEGIN { printf "%.1f%%", r * 100 }')"
		line="Local baseline: ${verdict^^} mesh_size=${m} qps_target=${q} n_valid=${v}/${t} reason=${reason} qps_actual=${qa} (${pct} of target) server_replicas=${srep} remote=${remote}"
		((unr > 0)) && line+=" remote_unreachable=${unr}"
		line+=" statuses=${sts}"
		((nbr > 0)) && line+=" ok_below_ratio=${nbr}"
		echo "$line"
	done
	for c in "${LB_MISSING[@]}"; do
		IFS=$'\t' read -r m reason <<<"$c"
		echo "Local baseline: MISSING mesh_size=${m} reason=${reason} (no local rows)"
	done
}

# Reading aids, one line each: a local cell fell short of its target QPS
# (saturated), or OK rows from a TSV recorded before the shortfall check did
# (saturated_unflagged).
local_baseline_hint() {
	local c sat=0 unflagged=0 unr=0 legacy="" unr_note=""
	for c in "${LB_CELLS[@]}"; do
		[[ "$c" == *$'\tsaturated\t'* ]] && sat=1
		[[ "$c" == *$'\tsaturated_unflagged\t'* ]] && unflagged=1
		[[ "${c##*$'\t'}" =~ ^[1-9] ]] && unr=1
	done
	# UNREACHABLE remote rows carried no load, so remote= leaves them out.
	((unr)) && unr_note=" remote= counts only remote rows that ran: remote_unreachable=N rows were skipped by the reach check (no load), and remote=none means no remote row ran at that cell."
	# In a TSV without MIN_QPS_RATIO a remote OK row may have missed its target too.
	((LB_LEGACY_FILES > 0)) && legacy=" In the ${LB_LEGACY_FILES} TSV(s) without MIN_QPS_RATIO, remote= counts status only: an OK remote row there may have missed its target too."
	if ((sat)); then
		echo "Hint: reason=saturated with every remote row valid (remote=n/n) means the local server ran out of capacity: raise --server-replicas. If remote rows dropped too, the client sidecar is the ceiling: lower --qps-levels.${unr_note} Thresholds: min_qps_ratio=${LB_RATIO}.${legacy}"
	fi
	if ((unflagged)); then
		echo "Note: reason=saturated_unflagged marks status=OK rows that delivered less than min_qps_ratio=${LB_RATIO} x target. Only a TSV recorded without MIN_QPS_RATIO (before the QPS_SHORTFALL check) holds such rows; they still count in n_valid and in the averages above. Compare these cells only at QPS levels that reached the target.${legacy}"
	fi
	return 0
}

# --- Remote coverage ----------------------------------------------------------
# REACH_ROWS: reach_coverage_rows over every reach-*.tsv under RESULTS_DIR (empty
# when there is none, e.g. a TSV recorded before the reach check).
REACH_ROWS="$(reach_coverage_rows "$RESULTS_DIR")"
REACH_NOT_REACHABLE="$(awk -F'\t' 'NF >= 8 && $6 != "REACHABLE" { n++ } END { print n + 0 }' <<<"$REACH_ROWS")"
# RV_ROWS: per remote (mesh_size, source_ctx, target_ctx) the latency rows' n_total,
# n_valid (the AGG predicate: status OK, istiod_restarted 0) and status counts, so
# the global "N dropped" line names the remotes behind it. Tab-separated (an OK row
# with istiod_restarted != 0 counts as "OK(istiod_restarted=<v>)"):
#   mesh_size source_ctx target_ctx n_total n_valid statuses
# shellcheck disable=SC2016
RV_SCRIPT='
BEGIN { OFS = "\t" }
/^#/ || $1 == "run_id" || NF < 17 || $17 != "remote" { next }
{
	k = $2 SUBSEP $3 SUBSEP $4
	if (!(k in tot)) { keys[++n] = k; ms[n] = $2 }
	tot[k]++
	if ($14 == "OK" && $16 == "0") val[k]++
	# An OK row dropped by the restart check says so, e.g. OK(istiod_restarted=1).
	st = ($14 == "OK" && $16 != "0") ? "OK(istiod_restarted=" $16 ")" : $14
	if (!((k, st) in stc)) stl[k] = (stl[k] == "" ? "" : stl[k] ",") st
	stc[k, st]++
}
END {
	for (i = 2; i <= n; i++) {
		t = keys[i]; tm = ms[i]; j = i - 1
		while (j >= 1 && ms[j] + 0 > tm + 0) { keys[j + 1] = keys[j]; ms[j + 1] = ms[j]; j-- }
		keys[j + 1] = t; ms[j + 1] = tm
	}
	for (i = 1; i <= n; i++) {
		k = keys[i]; split(k, p, SUBSEP)
		ns = split(stl[k], sl, ","); sts = ""
		for (j = 1; j <= ns; j++) sts = sts (j > 1 ? "," : "") sl[j] "=" stc[k, sl[j]]
		print p[1], p[2], p[3], tot[k], val[k] + 0, sts
	}
}
'
RV_ROWS="$(awk -F'\t' "$RV_SCRIPT" "${TSV_FILES[@]}")"
RV_NO_VALID="$(awk -F'\t' 'NF >= 6 && $5 == 0 { n++ } END { print n + 0 }' <<<"$RV_ROWS")"

# remote_validity_lines <kind>: one line per (mesh_size, source) listing the remotes
# with no valid latency row (kind none) or only some (kind partial), each as
# "<ctx> (n_valid/n_total; statuses)" (PL17). Nothing when there are none.
remote_validity_lines() {
	local kind="$1"
	awk -F'\t' -v kind="$kind" '
		NF >= 6 {
			if (kind == "none" && $5 != 0) next
			if (kind == "partial" && ($5 == 0 || $5 == $4)) next
			g = $1 SUBSEP $2
			if (!(g in l)) { gs[++ng] = g; gm[ng] = $1; gsrc[ng] = $2 }
			l[g] = l[g] (l[g] == "" ? "" : ", ") sprintf("%s (%s/%s; %s)", $3, $5, $4, $6)
		}
		END {
			label = (kind == "none") ? "Remotes with no valid latency rows" : "Remotes with partial valid latency rows"
			for (i = 1; i <= ng; i++) printf "%s: mesh_size=%s from %s: %s\n", label, gm[i], gsrc[i], l[gs[i]]
		}' <<<"$RV_ROWS"
}

# remote_coverage_section <fmt>: the reach coverage (tests/lib/reach.sh renderer)
# plus the remote validity lines, for text, csv and markdown.
remote_coverage_section() {
	local fmt="$1" line
	reach_coverage_render "$fmt" <(printf '%s' "$REACH_ROWS")
	case "$fmt" in
	text)
		remote_validity_lines none
		remote_validity_lines partial
		;;
	csv)
		while IFS= read -r line; do echo "# REMOTE_NO_VALID_ROWS ${line#*: }"; done < <(remote_validity_lines none)
		while IFS= read -r line; do echo "# REMOTE_PARTIAL_VALID_ROWS ${line#*: }"; done < <(remote_validity_lines partial)
		;;
	md)
		local any=0
		while IFS= read -r line; do
			((any++)) || echo ""
			echo "- ${line}"
		done < <(remote_validity_lines none; remote_validity_lines partial)
		;;
	esac
	return 0
}

fmt_val() { # turn "N/A" or numeric into pretty string
	local v="$1" digits="${2:-2}"
	[[ "$v" == "N/A" ]] && { printf "N/A"; return; }
	awk -v v="$v" -v d="$digits" 'BEGIN { printf "%.*f", d, v }'
}

report_text() {
	for kv in "${PREAMBLE[@]}"; do echo "# $kv"; done
	[[ ${#PREAMBLE[@]} -gt 0 ]] && echo ""
	echo "=== Data-Plane Latency Results ==="
	echo ""
	echo "Files: ${TSV_FILES[*]}"
	echo "Aggregated by (mesh_size, qps_target, target_class). Numeric averages exclude rows with"
	echo "status != OK or istiod_restarted != 0. n_total and n_valid are reported per cell."
	echo ""
	remote_coverage_section text
	echo ""
	printf "  %-4s | %-6s | %-6s | %5s | %5s | %10s | %10s | %10s | %10s | %10s | %7s\n" \
		"Sz" "QPS" "Class" "n_tot" "n_val" "p50 (ms)" "p90 (ms)" "p99 (ms)" "max (ms)" "actual QPS" "pct_200"
	printf "  %-4s-+-%-6s-+-%-6s-+-%5s-+-%5s-+-%10s-+-%10s-+-%10s-+-%10s-+-%10s-+-%7s\n" \
		"----" "------" "------" "-----" "-----" "----------" "----------" "----------" "----------" "----------" "-------"
	while IFS=$'\t' read -r mesh qps cls n_tot n_val p50 p90 p99 _p999 mx qa pct; do
		[[ -n "$mesh" ]] || continue  # no measurement cell (only placeholder rows)
		printf "  %-4s | %-6s | %-6s | %5s | %5s | %10s | %10s | %10s | %10s | %10s | %7s\n" \
			"$mesh" "$qps" "$cls" "$n_tot" "$n_val" \
			"$(fmt_val "$p50")" "$(fmt_val "$p90")" "$(fmt_val "$p99")" \
			"$(fmt_val "$mx")" "$(fmt_val "$qa" 1)" "$(fmt_val "$pct" 4)"
	done <<<"$AGG_TSV"
	echo ""
	if (( DROPPED_ALL + SKIPPED_ALL > 0 )); then
		echo "WARNING: $(rows_summary)"
	fi
	placeholder_lines
	echo ""
	local_baseline_lines
	local_baseline_hint
}

report_csv() {
	for kv in "${PREAMBLE[@]}"; do echo "# $kv"; done
	echo "# LOCAL_BASELINE=${LB_VERDICT}"
	((LB_LEGACY_FILES > 0)) && echo "# LOCAL_BASELINE_FILES_WITHOUT_MIN_QPS_RATIO=${LB_LEGACY_FILES}"
	local c m q _t _v verdict reason _rest
	for c in "${LB_CELLS[@]}"; do
		IFS=$'\t' read -r m q _t _v verdict reason _rest <<<"$c"
		[[ "$verdict" == ok ]] || echo "# LOCAL_BASELINE_CELL=${m}:${q}:${verdict}:${reason}"
	done
	for c in "${LB_MISSING[@]}"; do
		IFS=$'\t' read -r m reason <<<"$c"
		echo "# LOCAL_BASELINE_CELL=${m}:-:missing:${reason}"
	done
	echo "# ROWS n_total=${TOTAL_ALL} n_valid=${VALID_ALL} n_dropped=${DROPPED_ALL} n_skipped_unreachable=${SKIPPED_ALL} n_placeholder=${N_PLACEHOLDER}"
	local pm pst pn
	while IFS=$'\t' read -r pm pst pn; do
		if [[ -n "$pm" ]]; then echo "# PLACEHOLDER=${pm}:${pst}:${pn}"; fi
	done <<<"$PH_ROWS"
	remote_coverage_section csv
	echo "mesh_size,qps_target,target_class,n_total,n_valid,avg_p50_ms,avg_p90_ms,avg_p99_ms,avg_p999_ms,avg_max_ms,avg_actual_qps,avg_pct_200"
	while IFS=$'\t' read -r mesh qps cls n_tot n_val p50 p90 p99 p999 mx qa pct; do
		[[ -n "$mesh" ]] || continue
		printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
			"$mesh" "$qps" "$cls" "$n_tot" "$n_val" \
			"$(fmt_val "$p50")" "$(fmt_val "$p90")" "$(fmt_val "$p99")" \
			"$(fmt_val "$p999")" "$(fmt_val "$mx")" "$(fmt_val "$qa" 1)" "$(fmt_val "$pct" 4)"
	done <<<"$AGG_TSV"
}

# Metric glossary appended to the end of the markdown summary.
glossary_section() {
	cat <<'GLOSSARY'

## Glossary

Definitions for every metric column in the results table above (see also
`tests/dataplane/README.md`). Latency percentiles come from each cell's **Fortio JSON**
(`DurationHistogram.Percentiles` / `.Max`, seconds → ms); numeric averages are over
**valid rows only** — rows with `status != OK` or `istiod_restarted != 0` are excluded
(`n_valid < n_total` means some rows were dropped). The line under the table counts
every row: `dropped (poisoned)` are rows that ran and failed a check (or a
`SETUP_FAILED`/`PROBE_FAILED` placeholder), `skipped (remote unreachable)` are
`UNREACHABLE` rows and the `STOPPED_UNREACHABLE` placeholder, for which no load ran
(JSON `summary`: `n_total = n_valid + n_dropped + n_skipped_unreachable`). Sweep
placeholder rows (`target_class=na`: `SETUP_FAILED`, `PROBE_FAILED`,
`STOPPED_UNREACHABLE`) form no cell; the `Placeholder rows` lines name them per mesh
size, also when that mesh size has measured rows (CSV `# PLACEHOLDER=<mesh>:<STATUS>:<n>`,
JSON `summary.placeholders`), so `n_total` = the cells' `n_total` + `n_placeholder`.

| Column | Units | Source | Definition / caveats |
|--------|-------|--------|----------------------|
| `mesh_size` | clusters | sweep axis | Number of clusters in the mesh (`--mesh-size`). |
| `qps_target` | queries/s | sweep axis | Target offered load for the Fortio run (`--qps-levels`). |
| `target_class` | enum | internal | `local` (the source cluster's own `dataplane-server-<source>` Service, intra-cluster baseline) or `remote` (another cluster's Service, routed via the east-west gateway). |
| `n_total` | rows | internal | All rows for the cell, poisoned and `UNREACHABLE` rows included. Sweep placeholder rows (`target_class=na`) form no cell; the `Placeholder rows` lines under the table name them. |
| `n_valid` | rows | internal | Rows with `status == OK` and `istiod_restarted == 0` used in the averages; `QPS_SHORTFALL`, `ERROR_RATE_HIGH`, `PERCENTILE_MISSING`, `FAILED` and `UNREACHABLE` rows are dropped. |
| `avg_p50_ms` | ms | Fortio JSON `DurationHistogram.Percentiles[50]` | Mean p50 latency over valid rows; `N/A` if the percentile was missing or every row was dropped. |
| `avg_p90_ms` | ms | Fortio JSON `DurationHistogram.Percentiles[90]` | Mean p90 latency over valid rows. |
| `avg_p99_ms` | ms | Fortio JSON `DurationHistogram.Percentiles[99]` | Mean p99 latency over valid rows. |
| `avg_p999_ms` | ms | Fortio JSON `DurationHistogram.Percentiles[99.9]` | Mean p99.9 latency over valid rows. |
| `avg_max_ms` | ms | Fortio JSON `DurationHistogram.Max` | Mean of the per-run maximum observed latency over valid rows. |
| `avg_actual_qps` | queries/s | Fortio JSON `ActualQPS` | Mean achieved QPS over valid rows. A row below `MIN_QPS_RATIO` × `qps_target` (default 0.95) is tagged `QPS_SHORTFALL` and left out, so this stays close to the target. Exception: a TSV without `MIN_QPS_RATIO` in its preamble was recorded before that check, so its short rows are still `OK` and averaged here; the Local baseline names those cells `UNCHECKED` (`saturated_unflagged`). |
| `avg_pct_200` | fraction (0–1) | Fortio JSON `RetCodes` | Mean fraction of HTTP 200 responses (`count(200) / sum(all codes)`); below `MIN_PCT_200` (default 0.99) the run is tagged `ERROR_RATE_HIGH` and excluded from `n_valid`. |

**Local baseline** (section above): one verdict per local `(mesh_size, qps_target)` cell.
`DROPPED` means no valid row, `DEGRADED` some. `UNCHECKED` means every row is valid but
`ok_below_ratio` of them are `status=OK` rows that delivered less than `MIN_QPS_RATIO` ×
target: they come from a TSV recorded without `MIN_QPS_RATIO` (before the
`QPS_SHORTFALL` check) and are in the averages above. `reason` is the first of
`saturated_unflagged` (such rows), `saturated` (the run delivered less than
`MIN_QPS_RATIO` × target), `errors`, `percentile_missing`, `failed`,
`istiod_restarted`, `istiod_restart_unknown`. `server_replicas` is the source
cluster's fortio server `ready/spec` from the TSV preamble (`SERVER_REPLICAS`).
`remote=v/t` is the same cell for the remote targets that carried load: if remote rows
stayed valid, the local server was the bottleneck (raise `--server-replicas`); if they
dropped too, the client sidecar was (lower `--qps-levels`). `UNREACHABLE` remote rows ran
no load, so they are left out of `remote=` and counted as `remote_unreachable=N`.
`MISSING` means a mesh size has no local row at all; its reason is the placeholder status
(`setup_failed`, `probe_failed`, or `stopped_unreachable` when `--on-unreachable fail`
stopped the run before the load).

**Remote coverage** (section above the results): before the load, `002` sends a few
requests from the source's client to every remote's `dataplane-server-<remote>`
Service (`reach-*.tsv`). Per remote, `checks reachable` is how many of its checks
(one per probe run) got only HTTP 200s; `coverage` is `REACHABLE` (all), `FLAPPING`
(some), `DEGRADED` (none, but some 200s), `UNREACHABLE` (no 200 at all) or `UNKNOWN`
(the check could not run). `top_code` and `detail` (the Envoy reply, IPs and hosts
masked) come from the latest failing check. An `UNREACHABLE` remote's load is
skipped: its rows have status `UNREACHABLE`. The lists below it name the remotes
whose latency rows are all (`no valid latency rows`) or partly invalid, as
`n_valid/n_total` with their statuses.
GLOSSARY
}

report_markdown() {
	echo "---"
	for kv in "${PREAMBLE[@]}"; do
		# Split at first '=' only; quote value to keep YAML literal.
		k="${kv%%=*}"
		v="${kv#*=}"
		# Escape backslashes and double quotes in value.
		v_esc=${v//\\/\\\\}
		v_esc=${v_esc//\"/\\\"}
		echo "${k}: \"${v_esc}\""
	done
	echo "---"
	echo ""
	echo "# Data-Plane Latency Results"
	echo ""
	echo "Aggregated by (mesh_size, qps_target, target_class). Rows with status != OK or"
	echo "istiod_restarted != 0 are excluded from numeric averages."
	echo ""
	remote_coverage_section md
	echo ""
	echo "## Results"
	echo ""
	echo "| mesh_size | qps_target | target_class | n_total | n_valid | avg_p50_ms | avg_p90_ms | avg_p99_ms | avg_p999_ms | avg_max_ms | avg_actual_qps | avg_pct_200 |"
	echo "|-----------|------------|--------------|---------|---------|------------|------------|------------|-------------|------------|----------------|-------------|"
	while IFS=$'\t' read -r mesh qps cls n_tot n_val p50 p90 p99 p999 mx qa pct; do
		[[ -n "$mesh" ]] || continue
		printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" \
			"$mesh" "$qps" "$cls" "$n_tot" "$n_val" \
			"$(fmt_val "$p50")" "$(fmt_val "$p90")" "$(fmt_val "$p99")" \
			"$(fmt_val "$p999")" "$(fmt_val "$mx")" "$(fmt_val "$qa" 1)" "$(fmt_val "$pct" 4)"
	done <<<"$AGG_TSV"
	echo ""
	if (( DROPPED_ALL + SKIPPED_ALL > 0 )); then
		printf '> \xe2\x9a\xa0 %s\n' "$(rows_summary)"
	fi
	local line
	if [[ -n "$PH_ROWS" ]]; then
		echo ""
		while IFS= read -r line; do echo "- ${line}"; done < <(placeholder_lines)
	fi
	echo ""
	echo "## Local baseline"
	echo ""
	while IFS= read -r line; do echo "- ${line}"; done < <(local_baseline_lines)
	while IFS= read -r line; do printf '\n%s\n' "$line"; done < <(local_baseline_hint)

	# Metric glossary at the very end of the markdown summary.
	glossary_section
}

report_json() {
	# Build metadata object from PREAMBLE.
	local meta_json
	meta_json=$(printf '%s\n' "${PREAMBLE[@]}" | jq -R -s '
		split("\n")
		| map(select(length > 0))
		| map(capture("^(?<k>[^=]+)=(?<v>.*)$"; "g"))
		| map({(.k): .v})
		| add // {}
	')

	# Build results array from AGG_TSV.
	local results_json
	results_json=$(printf '%s\n' "$AGG_TSV" | jq -R -s '
		split("\n")
		| map(select(length > 0))
		| map(split("\t"))
		| map({
			mesh_size: (.[0] | tonumber? // .[0]),
			qps_target: (.[1] | tonumber? // .[1]),
			target_class: .[2],
			n_total: (.[3] | tonumber),
			n_valid: (.[4] | tonumber),
			avg_p50_ms: (if .[5] == "N/A" then null else (.[5] | tonumber) end),
			avg_p90_ms: (if .[6] == "N/A" then null else (.[6] | tonumber) end),
			avg_p99_ms: (if .[7] == "N/A" then null else (.[7] | tonumber) end),
			avg_p999_ms: (if .[8] == "N/A" then null else (.[8] | tonumber) end),
			avg_max_ms: (if .[9] == "N/A" then null else (.[9] | tonumber) end),
			avg_actual_qps: (if .[10] == "N/A" then null else (.[10] | tonumber) end),
			avg_pct_200: (if .[11] == "N/A" then null else (.[11] | tonumber) end)
		})
	')

	# Local baseline: every local cell (ok ones too), then the missing mesh sizes.
	local lb_json
	local c
	lb_json=$( {
		for c in "${LB_CELLS[@]}"; do printf 'cell\t%s\n' "$c"; done
		for c in "${LB_MISSING[@]}"; do printf 'missing\t%s\n' "$c"; done
	} | jq -R -s \
		--arg verdict "$LB_VERDICT" --arg ratio "$LB_RATIO" --arg legacy "$LB_LEGACY_FILES" '
		def num: if . == "N/A" or . == "" then null else (tonumber? // .) end;
		split("\n") | map(select(length > 0) | split("\t"))
		| map(select(length > 1)
			| if .[0] == "cell" then {
				mesh_size: (.[1] | num), qps_target: (.[2] | num),
				n_total: (.[3] | tonumber), n_valid: (.[4] | tonumber),
				verdict: .[5], reason: (if .[6] == "-" then null else .[6] end),
				qps_actual: (.[7] | num), qps_ratio: (.[8] | num),
				server_replicas: .[9],
				remote_n_valid: (if .[10] == "none" then null else (.[10] | split("/")[0] | tonumber) end),
				remote_n_total: (if .[10] == "none" then null else (.[10] | split("/")[1] | tonumber) end),
				statuses: (.[11] | split(",") | map(split("=") | {(.[0]): (.[1] | tonumber)}) | add // {}),
				ok_below_ratio: (.[12] | tonumber),
				remote_unreachable: ((.[13] // "0") | tonumber)
			} else {
				mesh_size: (.[1] | num), qps_target: null, n_total: 0, n_valid: 0,
				verdict: "missing", reason: .[2], qps_actual: null, qps_ratio: null,
				server_replicas: null, remote_n_valid: null, remote_n_total: null, statuses: {},
				ok_below_ratio: 0, remote_unreachable: null
			} end)
		| {verdict: $verdict, min_qps_ratio: ($ratio | num),
			files_without_min_qps_ratio: ($legacy | tonumber), cells: .}
	')

	# Placeholder rows per (mesh_size, status): no cell in results, so
	# summary.n_total = sum(results[].n_total) + summary.n_placeholder (PL15).
	local ph_json
	ph_json=$(printf '%s\n' "$PH_ROWS" | jq -R -s '
		split("\n") | map(select(length > 0) | split("\t") | select(length >= 3)
			| {mesh_size: (.[0] | tonumber? // .[0]), status: .[1], n_rows: (.[2] | tonumber)})
	')

	# Remote coverage (reach checks) and per-remote latency-row validity.
	local rc_json rv_json
	rc_json="$(reach_coverage_render json <(printf '%s' "$REACH_ROWS"))"
	rv_json=$(printf '%s\n' "$RV_ROWS" | jq -R -s '
		split("\n") | map(select(length > 0) | split("\t") | select(length >= 6)
			| {mesh_size: (.[0] | tonumber? // .[0]), source_ctx: .[1], target_ctx: .[2],
			   n_total: (.[3] | tonumber), n_valid: (.[4] | tonumber),
			   statuses: (.[5] | split(",") | map(capture("^(?<k>.*)=(?<v>[0-9]+)$") | {(.k): (.v | tonumber)}) | add // {})})
	')

	jq -n \
		--argjson metadata "$meta_json" \
		--argjson results "$results_json" \
		--argjson local_baseline "$lb_json" \
		--argjson remote_coverage "$rc_json" \
		--argjson remote_validity "$rv_json" \
		--argjson n_total "$TOTAL_ALL" \
		--argjson n_valid "$VALID_ALL" \
		--argjson n_dropped "$DROPPED_ALL" \
		--argjson n_skipped "$SKIPPED_ALL" \
		--argjson n_placeholder "$N_PLACEHOLDER" \
		--argjson placeholders "$ph_json" \
		--argjson not_reachable "$REACH_NOT_REACHABLE" \
		--argjson no_valid "$RV_NO_VALID" \
		'{metadata: $metadata,
		  summary: {n_total: $n_total, n_valid: $n_valid, n_dropped: $n_dropped,
		            n_skipped_unreachable: $n_skipped,
		            n_placeholder: $n_placeholder, placeholders: $placeholders,
		            remotes_not_reachable: $not_reachable, remotes_without_valid_rows: $no_valid},
		  remote_coverage: $remote_coverage.remote_coverage,
		  remote_validity: $remote_validity,
		  local_baseline: $local_baseline, results: $results}'
}

report_charts() {
	echo "---"
	for kv in "${PREAMBLE[@]}"; do
		k="${kv%%=*}"; v="${kv#*=}"
		v_esc=${v//\\/\\\\}; v_esc=${v_esc//\"/\\\"}
		echo "${k}: \"${v_esc}\""
	done
	echo "generated: \"$(date -u -Iseconds)\""
	echo "---"
	echo ""
	echo "# Data-Plane Latency — Charts"
	echo ""
	# Name every local point that is drawn as 0 because it has no valid sample, and
	# every one that averages OK rows below the QPS ratio (legacy TSVs).
	local c m q _t _v verdict reason _qa _qr _srep _remote _sts nbr _unr lb_notes=0
	for c in "${LB_CELLS[@]}"; do
		IFS=$'\t' read -r m q _t _v verdict reason _qa _qr _srep _remote _sts nbr _unr <<<"$c"
		if [[ "$verdict" == dropped ]]; then
			echo "> Local baseline missing at mesh ${m} / QPS ${q} (${reason}); its point is drawn as 0."
			lb_notes=1
		elif ((nbr > 0)); then
			echo "> Local point at mesh ${m} / QPS ${q} includes ${nbr} OK row(s) below min_qps_ratio x target (${reason}, TSV without MIN_QPS_RATIO)."
			lb_notes=1
		fi
	done
	for c in "${LB_MISSING[@]}"; do
		IFS=$'\t' read -r m reason <<<"$c"
		echo "> Local baseline missing at mesh ${m} (${reason}); its points are drawn as 0."
		lb_notes=1
	done
	while IFS= read -r c; do
		[[ -n "$c" ]] || continue
		echo "> ${c}"
		lb_notes=1
	done < <(placeholder_lines)
	((lb_notes)) && echo ""
	# Remote coverage: one line per source whose remotes were not all reachable, and
	# one per source with remotes that have no valid latency row.
	local cov_notes
	cov_notes="$(reach_coverage_render charts <(printf '%s' "$REACH_ROWS"); remote_validity_lines none | sed 's/^/> /')"
	[[ -n "$cov_notes" ]] && printf '%s\n\n' "$cov_notes"
	# Chart 1: p50 vs mesh size at the top QPS (needs two mesh sizes with remote data).
	# Chart 2: p50 vs QPS at the largest mesh size with remote data.
	# Cells with no valid samples (failed or restart-poisoned) stay off the axes; sweep
	# placeholders (class "na") form no cell. Mermaid has no null point, so a cell that
	# is missing on an axis other cells use is drawn as 0.
	awk -F'\t' '
	NF < 6 { next }
	{
		ms = $1 + 0; qps = $2 + 0; cls = $3; n_valid = $5 + 0; p50 = $6
		cells_total++
		if (n_valid <= 0 || p50 == "N/A") { cells_dropped++; next }
		if (!(ms in ms_seen)) { ms_order[++n_ms] = ms; ms_seen[ms] = 1 }
		if (!(qps in qps_seen)) { qps_order[++n_qps] = qps; qps_seen[qps] = 1 }
		if (qps > max_qps) max_qps = qps
		p50_val[ms, qps, cls] = p50
		has[ms, qps, cls] = 1
	}
	END {
		if (cells_dropped > 0) {
			printf "> %d of %d cells have no valid samples and are left out (a gap in a line is drawn as 0).\n\n", cells_dropped, cells_total
		}
		# Sort mesh sizes numerically.
		for (i = 2; i <= n_ms; i++) {
			tmp = ms_order[i]; j = i - 1
			while (j >= 1 && ms_order[j]+0 > tmp+0) { ms_order[j+1] = ms_order[j]; j-- }
			ms_order[j+1] = tmp
		}
		# Sort QPS numerically.
		for (i = 2; i <= n_qps; i++) {
			tmp = qps_order[i]; j = i - 1
			while (j >= 1 && qps_order[j]+0 > tmp+0) { qps_order[j+1] = qps_order[j]; j-- }
			qps_order[j+1] = tmp
		}
		local_cls = "local"; remote_cls = "remote"

		# Mesh sizes (ascending) with at least one valid remote cell.
		n_remote_ms = 0
		for (i = 1; i <= n_ms; i++) {
			for (q = 1; q <= n_qps; q++) {
				if (has[ms_order[i], qps_order[q], remote_cls]) { remote_ms[++n_remote_ms] = ms_order[i]; break }
			}
		}

		if (n_remote_ms < 1) {
			print "> Charts need remote data (mesh size >= 2)."
			exit
		}
		max_ms = remote_ms[n_remote_ms]

		if (n_remote_ms < 2) {
			printf "> The mesh-size chart needs two mesh sizes with remote data; only the QPS chart is shown.\n\n"
		} else {
			# Chart 1: p50 vs mesh size at top QPS
			printf "```mermaid\n"
			printf "xychart-beta\n"
			printf "    title \"p50 Latency vs Mesh Size (QPS %s)\"\n", max_qps
			printf "    x-axis \"Mesh Size\" ["
			for (i = 1; i <= n_remote_ms; i++) {
				if (i > 1) printf ", "
				printf "%s", remote_ms[i]
			}
			printf "]\n"
			printf "    y-axis \"Latency (ms)\"\n"
			# Local series
			printf "    line ["; sep = ""
			for (i = 1; i <= n_remote_ms; i++) {
				ms = remote_ms[i]
				v = (has[ms, max_qps, local_cls] && p50_val[ms, max_qps, local_cls] != "N/A") ? p50_val[ms, max_qps, local_cls] + 0 : 0
				printf "%s%.2f", sep, v; sep = ", "
			}
			printf "]\n"
			# Remote series
			printf "    line ["; sep = ""
			for (i = 1; i <= n_remote_ms; i++) {
				ms = remote_ms[i]
				v = (has[ms, max_qps, remote_cls] && p50_val[ms, max_qps, remote_cls] != "N/A") ? p50_val[ms, max_qps, remote_cls] + 0 : 0
				printf "%s%.2f", sep, v; sep = ", "
			}
			printf "]\n"
			printf "```\n\n"
			printf "> Series order: **%s**, **%s**. The gap is the cross-cluster overhead.\n\n", local_cls, remote_cls
		}

		# Chart 2: p50 vs QPS at largest mesh size
		printf "```mermaid\n"
		printf "xychart-beta\n"
		printf "    title \"p50 Latency vs QPS (Mesh Size %s)\"\n", max_ms
		printf "    x-axis \"QPS\" ["
		for (i = 1; i <= n_qps; i++) {
			if (i > 1) printf ", "
			printf "%s", qps_order[i]
		}
		printf "]\n"
		printf "    y-axis \"Latency (ms)\"\n"
		# Local series
		printf "    line ["; sep = ""
		for (i = 1; i <= n_qps; i++) {
			qps = qps_order[i]
			v = (has[max_ms, qps, local_cls] && p50_val[max_ms, qps, local_cls] != "N/A") ? p50_val[max_ms, qps, local_cls] + 0 : 0
			printf "%s%.2f", sep, v; sep = ", "
		}
		printf "]\n"
		# Remote series
		printf "    line ["; sep = ""
		for (i = 1; i <= n_qps; i++) {
			qps = qps_order[i]
			v = (has[max_ms, qps, remote_cls] && p50_val[max_ms, qps, remote_cls] != "N/A") ? p50_val[max_ms, qps, remote_cls] + 0 : 0
			printf "%s%.2f", sep, v; sep = ", "
		}
		printf "]\n"
		printf "```\n\n"
		printf "> Series order: **%s**, **%s** at mesh size %s.\n", local_cls, remote_cls, max_ms
	}' <<<"$AGG_TSV"
}

case "$FORMAT" in
text)     report_text ;;
csv)      report_csv ;;
markdown) report_markdown ;;
json)     report_json ;;
charts)   report_charts ;;
esac

# --fail-on-unreachable: after the output, exit 3 and name the rule that fired, so
# a remote that was reachable but only ever QPS_SHORTFALL reads as such.
if ((FAIL_ON_UNREACHABLE)); then
	cov_bad="$(awk -F'\t' 'NF >= 8 && $6 != "REACHABLE" { printf "  rule=reach_coverage mesh_size=%s from %s: %s (%s, %s/%s checks reachable, top_code=%s)\n", $1, $2, $3, $6, $5, $4, $7 }' <<<"$REACH_ROWS")"
	nv_bad="$(awk -F'\t' 'NF >= 6 && $5 == 0 { printf "  rule=no_valid_rows mesh_size=%s from %s: %s (n_valid=%s/%s; %s)\n", $1, $2, $3, $5, $4, $6 }' <<<"$RV_ROWS")"
	if [[ -n "$cov_bad" || -n "$nv_bad" ]]; then
		echo "fail-on-unreachable: exit ${REACH_EXIT_CODE}" >&2
		if [[ -n "$cov_bad" ]]; then printf '%s\n' "$cov_bad" >&2; fi
		if [[ -n "$nv_bad" ]]; then printf '%s\n' "$nv_bad" >&2; fi
		exit "$REACH_EXIT_CODE"
	fi
fi

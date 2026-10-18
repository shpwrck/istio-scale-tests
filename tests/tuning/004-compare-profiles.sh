#!/usr/bin/env bash
# Compare the passes of a tuning sweep (baseline + one directory per profile).
# Reads each pass's suite TSV, finds columns by header name, averages the valid rows
# and shows each profile's change against the baseline, with each metric's n (valid
# samples / rows the pass attempted, PL17) and range, so a profile whose n differs from
# the baseline's (say 7 of 10 iterations timed out) is visible and flagged.
#
# Usage:
#   ./tests/tuning/004-compare-profiles.sh --results-dir DIR [--format text|md] [--output FILE]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"  # sources options.env: FANOUT_MAX_SKEW_MS, as in propagation 005
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/propagation.sh"  # PROP_ROW_AWK: the rows propagation 005 counts
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # config_input_value: a preamble key over every input (PL26)

RESULTS_DIR=""
FORMAT="text"
OUTPUT_FILE=""

usage() {
	cat <<EOF
Usage: $(basename "$0") --results-dir DIR [options]

Compare tuning sweep passes. Values are means over valid rows (status OK, no istiod
restart; a propagation pass counts exactly the rows and samples its 005 report
counts: P1 once per iteration and left out only for a source-side reason, P2 and P3
left out only for the remote's side, so a NOT_DRAINED side is left out like any
other status that is not OK, while a DRAIN_TIMEOUT side counts: it was measured
before that drain). Each profile also shows its change against the baseline. Under
each metric, "n" is got/attempted: the valid samples with a value for it / what the
pass's probe was configured to run, where its TSV records it (propagation:
iterations for P1, iterations x remotes for P2 and P3; churn: iterations), else
every row the pass wrote in that group (failed and timed-out rows included);
"range" is its min to max. A profile whose n differs from the baseline's shows
"(baseline n ...)": its mean is over other iterations, so compare it with care.
Histogram p99 rows (convergence, push time) show the worst bucket a valid row hit,
or "overflow (N rows)", never a mean; propagation's P1 convergence counts iterations,
"overflow (N iterations)": an iteration whose window put a sample in +Inf is left out
of the means (as 005 drops it) but counted here, so a profile that overflowed never
looks better than it was; the P1 local push cell says "(N overflowed)" for the same
iterations, which its mean leaves out ("- (N overflowed)" when every one did). Memory
is in Mi, CPU in millicores (the controlplane's istiod CPU and memory are window
peaks), config sizes in KiB, and a count's mean prints bare when it is whole (438,
not 438.00).
"TSV columns" gives the data rows' column count, per pass when the passes differ:
then a WARNING says their rows were written by different harness versions (for
propagation, filtered by different row rules); "none" when no pass wrote a TSV (or
no TSV has a data row).
The "Istio CR / IstioRevision generations" row gives each pass's ISTIO_GENERATIONS
from its own TSVs: a profile's apply and revert raise them, so each pass ran on its
own (one value for every member prints once, "(every member)"). The header's
ISTIO_GENERATIONS merges the sweep's start and every pass: mixed when they differ.
The "Harness (HARNESS_SHA)" row gives each pass's HARNESS_SHA from its own TSVs (a
churn-dataplane pass also from its rows' harness_sha column: mixed when they record
more than one, or another than the preamble, and the WARNING then names that pass and
the combos whose baseline and churn rows ran different harnesses). When the passes'
values differ, a WARNING says so (a profile's change may come from the harness); when
every pass records one HARNESS_CONTENT_KEY (the harness files' content key; unknown in
a TSV written before it), a note says they differ only in git describe (a commit or
tag that left the harness files as they were) instead. A propagation comparison adds
"Drain timeouts (iterations, counted)" when a pass has an iteration whose drain after
the window timed out (DRAIN_TIMEOUT): its values count, as in 005.
HARNESS_SHA in the header is the sweep's harness (HARNESS_CONTENT_KEY, next to it, is
its files' content key); REPORT_HARNESS_SHA (every format, next to it) is the harness
this report ran on, which can differ: a report made again later, or from another
checkout, may count rows by other rules. The sweep dir it reads does not count as a
change to it.
The markdown starts with a YAML frontmatter of the same keys (lowercase:
istio_generations, harness_sha, harness_content_key, report_harness_sha, tsv_columns
and the others).

Options:
  --results-dir DIR  Sweep directory (tests/tuning/results/sweep-<RUN_ID>) (required).
  --format FMT       text or md (or markdown) (default: text).
  --output FILE      Write to FILE instead of stdout.
  -h, --help         Show this help.

When the sweep dir holds sweep-outcome.txt (003 writes it), the comparison repeats
it, with the run that recorded it: the failed passes by reason, its problems (the
Istio version, the active revision or the generation of the Istio CR or its active
IstioRevision changed under the sweep; the Istio CR changed other than by the
sweep's own apply and revert: during a pass, after its apply settled and not by its
profile, or between two of the sweep's checkpoints while it changed nothing (the
suite setup, between passes, after the last revert); an incomplete revert: a
member's Istio CR spec after the last revert differs from the sweep's start; or the
end-of-sweep check failed) and notes (members not ready at its start or end). The
sweep writes it at its start as "not finished" (EXIT=unfinished) and replaces it at
its end: a record still not finished is a sweep that died or still runs, or one
interrupted, with when and by which signal; one that stopped on an error after its
start shows the stop and its reason.
A sweep dir without the file is from a sweep that stopped before its start (nothing
ran), or from an older harness.

Environment:
  FANOUT_MAX_SKEW_MS  propagation: the scrape-skew ceiling (ms) a row must be within to
                      count, as in propagation 005 (default 1000, set in
                      config/options.env).
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--results-dir | --format | --output)
		[[ -n "${2:-}" ]] || die "$1 requires a value"
		case "$1" in
		--results-dir) RESULTS_DIR="$2" ;;
		--format) FORMAT="$2" ;;
		--output) OUTPUT_FILE="$2" ;;
		esac
		shift 2
		;;
	-h | --help) usage; exit 0 ;;
	*) die "unknown option: $1 (try --help)" ;;
	esac
done

[[ -n "$RESULTS_DIR" ]] || die "--results-dir is required"
[[ -d "$RESULTS_DIR" ]] || die "results directory not found: $RESULTS_DIR"
case "$FORMAT" in
text | markdown) ;;
md) FORMAT=markdown ;;
*) die "--format must be text or md" ;;
esac

META="${RESULTS_DIR}/sweep-metadata.txt"
meta_get() { [[ -f "$META" ]] && sed -n "s/^# $1=//p" "$META" | head -1; return 0; }
# istio_start_kv <key>: a start-of-run readiness key (ISTIO_NOTREADY_AT_START,
# ISTIO_READY_WAITED_SEC) from sweep-metadata.txt; unknown for a sweep from before these keys.
istio_start_kv() {
	local v
	v="$(meta_get "$1")"
	echo "${v:-unknown}"
}

# Passes in sweep order (metadata), else baseline first then the rest.
PASSES=()
passes_csv="$(meta_get PASSES)"
if [[ -n "$passes_csv" ]]; then
	split_csv "$passes_csv" PASSES
else
	[[ -d "${RESULTS_DIR}/baseline" ]] && PASSES+=(baseline)
	for d in "$RESULTS_DIR"/*/; do
		n="$(basename "$d")"
		[[ "$n" == baseline ]] || PASSES+=("$n")
	done
fi
((${#PASSES[@]})) || die "no pass directories in $RESULTS_DIR"

# reach-*.tsv (the dataplane suites' reachability check, tests/lib/reach.sh) has no
# status column and is not probe data, so it is left out.
pass_tsvs() { find -H "${RESULTS_DIR}/$1" -maxdepth 1 -name '*.tsv' ! -name 'reach-*.tsv' -type f 2>/dev/null | sort; }

# Suite from metadata, else from a header column only that suite's TSV has.
SUITE="$(meta_get SUITE)"
if [[ -z "$SUITE" ]]; then
	for p in "${PASSES[@]}"; do
		f="$(pass_tsvs "$p" | head -1)"
		[[ -n "$f" ]] || continue
		hdr="$(grep -v '^#' "$f" | grep -m1 . || true)"
		case $'\t'"$hdr"$'\t' in
		*$'\tistiod_mem_mi\t'*) SUITE=controlplane ;;
		*$'\tchurn_ops_attempted\t'*) SUITE=churn-dataplane ;;
		*$'\tconvergence_local_ms\t'*) SUITE=churn ;;
		*$'\ttarget_class\t'*) SUITE=dataplane ;;
		*$'\tp3_ms\t'*) SUITE=propagation ;;
		esac
		break
	done
fi

# Metrics per suite as "column|label|kind"; GROUP (CSV of columns) splits rows by their
# values. kind sets how a cell prints (fmt_metric): ms (mean, 2 decimals), count (mean,
# a whole number bare, else 1 decimal), mi and m (mean in Mi / millicores, whole), kib
# (a bytes mean shown in KiB, 1 decimal), qps (mean, 1 decimal), hist (a histogram
# p99: never averaged, the worst bucket any valid row hit, or "overflow (N rows)"),
# histi (hist counted per iteration: "overflow (N iterations)"; propagation's P1).
GROUP=""
case "$SUITE" in
controlplane)
	# Rows are per istiod pod: connected_proxies is per replica; cluster_connected_proxies
	# repeats on each pod row of a cluster, so its mean weights clusters by replica
	# count (same replicas everywhere -> the plain per-cluster mean). Absent in older
	# 40-column TSVs, where it is skipped. istiod_mem_mi is the window's peak RSS and
	# istiod_cpu_m_delta the larger of the window average and the polled 5 s peak.
	METRICS=("istiod_mem_mi|istiod memory peak (Mi)|mi" "go_heap_inuse_mi|Go heap in use (Mi)|mi"
		"istiod_cpu_m_delta|istiod CPU peak (m)|m" "convergence_p99_ms|Convergence p99 worst bucket (ms)|hist"
		"xds_pushes_delta|xDS pushes|count" "sidecar_config_bytes_avg|Sidecar config (KiB)|kib"
		"connected_proxies|Connected proxies / istiod replica|count"
		"cluster_connected_proxies|Connected proxies / cluster|count") ;;
propagation)
	METRICS=("p1_ms|P1 local push (ms)|ms" "p2_ms|P2 remote EDS (ms)|ms" "p3_ms|P3 remote sidecar (ms)|ms"
		"p1_conv_p99_ms|P1 convergence p99 worst bucket (ms)|histi") ;;
dataplane)
	GROUP="target_class,qps_target"
	METRICS=("p50_ms|p50 (ms)|ms" "p90_ms|p90 (ms)|ms" "p99_ms|p99 (ms)|ms" "p999_ms|p99.9 (ms)|ms"
		"qps_actual|Actual QPS|qps") ;;
churn)
	METRICS=("convergence_local_ms|Local convergence (ms)|ms" "convergence_remote_eds_ms|Remote EDS (ms)|ms"
		"remote_endpoint_reachable_ms|Remote reachable (ms)|ms" "source_xds_pushes_delta|Source xDS pushes|count"
		"source_push_time_p99_ms|Source push time p99 worst bucket (ms)|hist") ;;
churn-dataplane)
	GROUP="phase"
	METRICS=("p50_ms|p50 (ms)|ms" "p99_ms|p99 (ms)|ms" "p999_ms|p99.9 (ms)|ms" "delta_p99_ms|p99 change vs baseline phase (ms)|ms"
		"qps_actual|Actual QPS|qps" "xds_pushes_delta|xDS pushes|count" "eds_pushes_delta|EDS pushes|count") ;;
*) die "cannot tell the suite (no '# SUITE=' in sweep-metadata.txt and no known TSV header)" ;;
esac

metric_cols=""
for m in "${METRICS[@]}"; do metric_cols+="${m%%|*},"; done

# One pass -> lines "n<TAB>valid<TAB>total", "w<TAB>columns<TAB>rows" (the data rows'
# column counts), "g<TAB>group<TAB>rows" (first-seen order; rows counts every row of the
# group, valid or not) and
# "v<TAB>group<TAB>column<TAB>mean<TAB>max<TAB>n_overflow<TAB>min<TAB>n_numeric" for
# every metric column the TSV has (mean, max and min "-" without a numeric value: a tab
# IFS would merge empty fields). A group is "col=value, col=value", or "-". "overflow"
# (a histogram p99 in +Inf) is counted, not dropped. A propagation pass counts what its
# 005 report counts: P2 and P3 from the rows prop_drop_reason keeps (the remote side
# only), P2 without a dirty sample, and P1 and its convergence p99 once per iteration,
# decided before the row filter from the source side only (prop_p1_first,
# tests/lib/propagation.sh, with 005's skew ceiling FANOUT_MAX_SKEW_MS). An iteration
# left out for a P1 overflow (its source side otherwise clean) is counted into the
# convergence p99's overflow once, and "o<TAB>group<TAB>iterations" gives that count for
# the P1 local push cell's "(N overflowed)". "i<TAB>group<TAB>iterations": a propagation
# pass's distinct (run_id, iteration) per group, what P1 is attempted against when the
# TSV does not record ITERATIONS. "d<TAB>iterations": a propagation pass's distinct
# (run_id, iteration) with DRAIN_TIMEOUT in status, p1_status or remote_status (the
# drain after the window timed out; counted, as 005 counts them). "r<TAB>values<TAB>combos":
# a churn-dataplane pass whose TSV rows record (harness_sha column) more than one harness,
# or another than their file's preamble HARNESS_SHA (the harness changed during the pass):
# every value (preamble's and rows', first seen first, comma-separated) and the combos
# whose baseline and churn rows differ ("-" when none), as churn-dataplane 005 reads them.
summarize() {
	awk -F'\t' -v cols="$metric_cols" -v gcols="$GROUP" -v suite="$SUITE" -v MAXSKEW="${FANOUT_MAX_SKEW_MS:-1000}" "${PROP_ROW_AWK}"'
	# prop_col_sample(c): whether a kept row carries a sample of propagation column c; the
	# P1 columns are taken before the row filter (take_p1), never here.
	function prop_col_sample(c) {
		if (c == "p1_ms" || c == "p1_conv_p99_ms") return 0
		if (c == "p2_ms") return prop_p2_sample()
		if (c == "p3_ms") return prop_p3_sample()
		return 1
	}
	# take(g, c): add the value of column c on this row to group g.
	function take(g, c,    v, k) {
		v = $(idx[c]); k = g SUBSEP c
		if (v == "overflow") { ov[k]++; return }
		if (v ~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) {
			if (!(k in cnt) || v + 0 > mx[k]) mx[k] = v + 0
			if (!(k in cnt) || v + 0 < mn[k]) mn[k] = v + 0
			sum[k] += v; cnt[k]++
		}
	}
	# dt_col(c): the row has column c and it reads DRAIN_TIMEOUT.
	function dt_col(c) { return ((c in idx) && $(idx[c]) == "DRAIN_TIMEOUT") }
	# hadd(v): a harness value, in the order first seen.
	function hadd(v) { if (!(v in hseen)) { hseen[v] = 1; hord[++hn] = v } }
	BEGIN { nm = split(cols, mc, ","); ng = split(gcols, gc, ",") }
	FNR == 1 { hdr = 0; hpre = ""; hnv = 0; delete hfseen }
	/^# HARNESS_SHA=/ { if (hpre == "") { hpre = substr($0, 15); hadd(hpre) } }
	/^#/ || NF == 0 { next }
	!hdr { delete idx; for (i = 1; i <= NF; i++) idx[$i] = i; hdr = 1; next }
	("harness_sha" in idx) {
		v = $(idx["harness_sha"]); hadd(v)
		if (!(v in hfseen)) { hfseen[v] = 1; if (++hnv > 1) hbad = 1 }
		if (hpre != "" && v != hpre) hbad = 1
		if (("combo_id" in idx) && ("phase" in idx)) {
			k = FILENAME SUBSEP $(idx["combo_id"])
			if ($(idx["phase"]) == "baseline") hbl[k] = v
			else if ($(idx["phase"]) == "churn" && !(k in hch)) { hch[k] = v; hco[++hnc] = k; hid[k] = $(idx["combo_id"]) }
		}
	}
	{
		total++
		widths[NF]++
		g = ""
		for (j = 1; j <= ng; j++) if (gc[j] in idx) g = g (g == "" ? "" : ", ") gc[j] "=" $(idx[gc[j]])
		if (g == "") g = "-"
		if (!(g in seen)) { seen[g] = 1; order[++norder] = g }
		grows[g]++
		for (j = 1; j <= nm; j++) if (mc[j] != "" && (mc[j] in idx)) has[g SUBSEP mc[j]] = 1
		if (suite == "propagation") {
			if (!((g, $1, $3) in iter_seen)) { iter_seen[g, $1, $3] = 1; giters[g]++ }
			if (!(($1, $3) in dt_seen) && (dt_col("status") || dt_col("p1_status") || dt_col("remote_status"))) {
				dt_seen[$1, $3] = 1; dt_iters++
			}
			# P1 and its convergence p99: once per iteration, before the row filter, left
			# out only for a source-side reason, as 005 counts them.
			if (prop_p1_first(MAXSKEW)) {
				if (("p1_ms" in idx) && prop_p1_sample(MAXSKEW)) take(g, "p1_ms")
				if ("p1_conv_p99_ms" in idx) take(g, "p1_conv_p99_ms")
			} else if (prop_p1_drop_reason(MAXSKEW) == "p1_overflow" && !((g, $1, $3) in ov_seen)) {
				ov_seen[g, $1, $3] = 1
				p1ov[g]++
				if ("p1_conv_p99_ms" in idx) ov[g SUBSEP "p1_conv_p99_ms"]++
			}
			r = prop_drop_reason(MAXSKEW)
			if (r != "") next
		} else {
			if (("status" in idx) && $(idx["status"]) != "OK") next
			if (("istiod_restarted" in idx) && $(idx["istiod_restarted"]) != "0") next
			if (("restarted" in idx) && $(idx["restarted"]) != "0") next
		}
		valid++
		for (j = 1; j <= nm; j++) {
			c = mc[j]
			if (c == "" || !(c in idx)) continue
			if (suite == "propagation" && !prop_col_sample(c)) continue
			take(g, c)
		}
	}
	END {
		printf "n\t%d\t%d\n", valid, total
		for (w in widths) printf "w\t%s\t%d\n", w, widths[w]
		for (i = 1; i <= norder; i++) printf "g\t%s\t%d\n", order[i], grows[order[i]]
		if (suite == "propagation") for (i = 1; i <= norder; i++) printf "i\t%s\t%d\n", order[i], giters[order[i]]
		if (suite == "propagation") for (i = 1; i <= norder; i++) printf "o\t%s\t%d\n", order[i], p1ov[order[i]] + 0
		if (suite == "propagation") printf "d\t%d\n", dt_iters
		if (hbad) {
			hv = ""; hc = ""
			for (i = 1; i <= hn; i++) hv = hv (i > 1 ? "," : "") hord[i]
			for (i = 1; i <= hnc; i++) if ((hco[i] in hbl) && hbl[hco[i]] != hch[hco[i]])
				hc = hc (hc == "" ? "" : "; ") hid[hco[i]] " (baseline " hbl[hco[i]] ", churn " hch[hco[i]] ")"
			printf "r\t%s\t%s\n", hv, (hc == "" ? "-" : hc)
		}
		for (k in has) {
			split(k, a, SUBSEP)
			if (k in cnt) printf "v\t%s\t%s\t%.6f\t%.6f\t%d\t%.6f\t%d\n", a[1], a[2], sum[k] / cnt[k], mx[k], ov[k] + 0, mn[k], cnt[k]
			else printf "v\t%s\t%s\t-\t-\t%d\t-\t0\n", a[1], a[2], ov[k] + 0
		}
	}' "$@"
}

# fmt_metric <kind> <mean> <max> <n_overflow> [baseline_mean]: one cell (see METRICS; hist
# and histi print alike, but histi counts its overflow in iterations);
# "-" (or empty) for a mean or max means none. The change against the baseline is on
# the unrounded means; hist cells have none.
fmt_metric() {
	awk -v k="$1" -v m="$2" -v mx="$3" -v ov="$4" -v b="${5:-}" '
	function bucket_range(v) {
		if (v + 0 <= 0)     return "N/A"
		if (v + 0 <= 100)   return "0-100"
		if (v + 0 <= 500)   return "100-500"
		if (v + 0 <= 1000)  return "500-1000"
		if (v + 0 <= 3000)  return "1000-3000"
		if (v + 0 <= 5000)  return "3000-5000"
		if (v + 0 <= 10000) return "5000-10000"
		if (v + 0 <= 20000) return "10000-20000"
		if (v + 0 <= 30000) return "20000-30000"
		return ">30000"
	}
	BEGIN {
		if (m == "-") m = ""
		if (mx == "-") mx = ""
		if (b == "-") b = ""
		if (k == "hist" || k == "histi") {
			u = (k == "histi") ? "iteration" : "row"
			if (ov + 0 > 0) printf "overflow (%d %s%s)", ov, u, (ov + 0 == 1 ? "" : "s")
			else printf "%s", (mx == "" ? "-" : bucket_range(mx))
			exit
		}
		if (m == "") { printf "-"; exit }
		v = (k == "kib") ? m / 1024 : m + 0
		if (k == "ms") s = sprintf("%.2f", v)
		else if (k == "kib" || k == "qps") s = sprintf("%.1f", v)
		else if (k == "count") s = (v == int(v)) ? sprintf("%d", v) : sprintf("%.1f", v)
		else s = sprintf("%.0f", v)
		if (b != "" && b + 0 != 0) s = s sprintf(" (%+.1f%%)", (m - b) / b * 100)
		printf "%s", s
	}'
}

# fmt_range <kind> <min> <max> <n_overflow>: "min to max" in the cell format of
# <kind>; a hist metric gives its lowest and worst bucket (overflow when one row's p99
# was in +Inf); "-" without a value.
fmt_range() {
	local kind="$1" mn="$2" mx="$3" ov="$4" lo hi
	if [[ "$kind" == hist || "$kind" == histi ]]; then
		[[ "$mn" == "-" && "$ov" == 0 ]] && { printf -- '-'; return; }
		lo="$(fmt_metric hist "-" "$mn" 0)"
		hi="$(fmt_metric hist "-" "$mx" 0)"
		[[ "$mn" == "-" ]] && lo="overflow"
		(( ov > 0 )) && hi="overflow"
		printf '%s to %s' "$lo" "$hi"
		return
	fi
	[[ "$mn" == "-" ]] && { printf -- '-'; return; }
	printf '%s to %s' "$(fmt_metric "$kind" "$mn" "$mn" 0)" "$(fmt_metric "$kind" "$mx" "$mx" 0)"
}

# cfg_attempted <pass> <tsv>... (PL17): ATT[<pass>|-|<column>] = the samples the
# pass's probes were configured to take, from their TSV preambles: propagation
# ITERATIONS (P1 and its convergence p99: one per iteration) and ITERATIONS x the
# remotes (P2, P3: one per remote and iteration); churn its Iterations (one row each).
# Nothing when a file does not record it: metric_n then counts the rows written.
declare -A ATT=()
cfg_attempted() {
	local p="$1" f it rem n1=0 n2=0 m
	shift
	case "$SUITE" in propagation | churn) ;; *) return 0 ;; esac
	for f in "$@"; do
		if [[ "$SUITE" == propagation ]]; then
			it="$(sed -n 's/^# ITERATIONS=//p' "$f" | head -1)"
			rem="$(sed -n 's/^# REMOTES=//p' "$f" | head -1)"
			[[ "$it" =~ ^[0-9]+$ && -n "$rem" ]] || return 0
			[[ "$rem" != none ]] || rem=""
			n1=$((n1 + it))
			n2=$((n2 + it * $(wc -w <<<"$rem")))
		else
			it="$(sed -n 's/^# Deployments: .* Iterations: \([0-9][0-9]*\)$/\1/p' "$f" | head -1)"
			[[ -n "$it" ]] || return 0
			n1=$((n1 + it))
		fi
	done
	for m in "${METRICS[@]}"; do
		case "${m%%|*}" in
		p2_ms | p3_ms) ATT["$p|-|${m%%|*}"]="$n2" ;;
		*) ATT["$p|-|${m%%|*}"]="$n1" ;;
		esac
	done
}

declare -A VAL VMAX VOV VMIN VCNT VHAS GROWS GITERS P1OV NROWS STATUS GSEEN PWIDTHS PGENS PHS PHCK PDT PROWHS
GROUP_VALUES=()
ALL_TSVS=()
for p in "${PASSES[@]}"; do
	STATUS[$p]="ok"
	for marker in SETUP_FAILED PROBE_FAILED REVERT_FAILED; do
		[[ -f "${RESULTS_DIR}/${p}/${marker}" ]] && { STATUS[$p]="$marker"; break; }
	done
	mapfile -t files < <(pass_tsvs "$p")
	if ((${#files[@]} == 0)); then
		[[ "${STATUS[$p]}" == ok ]] && STATUS[$p]="no data"
		continue
	fi
	cfg_attempted "$p" "${files[@]}"
	ALL_TSVS+=("${files[@]}")
	# The generations this pass ran on, from its own TSVs (each apply and revert raises
	# them); mixed when its TSVs disagree, unknown for a TSV without the key.
	PGENS[$p]="$(config_input_value ISTIO_GENERATIONS unknown "${files[@]}")"
	# The harness this pass ran (its TSVs' HARNESS_SHA) and that harness's content key
	# (HARNESS_CONTENT_KEY; unknown for a TSV without it), likewise.
	PHS[$p]="$(config_input_value HARNESS_SHA unknown "${files[@]}")"
	PHCK[$p]="$(config_input_value HARNESS_CONTENT_KEY unknown "${files[@]}")"
	while IFS=$'\t' read -r kind a b c d e f h; do
		case "$kind" in
		n) NROWS[$p]="${a}/${b}" ;;
		d) PDT[$p]="$a" ;;
		r)
			# Its rows ran on more than one harness: the pass reads mixed, its key adds
			# unknown (a row records none), and HARNESS_WARNING names the pass.
			PHS[$p]="mixed:${a}"
			case ",${PHCK[$p]#mixed:}," in *,unknown,*) ;; *) PHCK[$p]="mixed:${PHCK[$p]#mixed:},unknown" ;; esac
			PROWHS[$p]="pass ${p}'s rows record more than one harness (harness_sha column and preamble: ${a}), so the harness, or only the commit name git describe gives, changed during that pass (rows record no content key to tell the two apart)"
			[[ "$b" == - ]] || PROWHS[$p]+="; combos whose baseline and churn rows ran different harnesses, so their delta_p99 pairs the two: ${b}"
			;;
		w) PWIDTHS[$p]="${PWIDTHS[$p]:+${PWIDTHS[$p]},}${a}" ;;
		g) GROWS["$p|$a"]="$b"; [[ -n "${GSEEN[$a]:-}" ]] || { GSEEN[$a]=1; GROUP_VALUES+=("$a"); } ;;
		i) GITERS["$p|$a"]="$b" ;;
		o) P1OV["$p|$a"]="$b" ;;
		v)
			VHAS["$p|$a|$b"]=1; VMAX["$p|$a|$b"]="$d"; VOV["$p|$a|$b"]="$e"
			VMIN["$p|$a|$b"]="$f"; VCNT["$p|$a|$b"]="$h"
			# VAL only for a metric with a value: a mean, or a hist p99 that overflowed.
			[[ "$c" != "-" || "$e" != 0 ]] && VAL["$p|$a|$b"]="$c"
			;;
		esac
	done < <(summarize "${files[@]}")
done
((${#GROUP_VALUES[@]})) || GROUP_VALUES=("-")

# The TSV widths (data-row column counts) per pass: one value when every pass agrees,
# else each pass's, with a warning: passes written by different harness versions. A
# propagation TSV's width decides its row rules (tests/lib/propagation.sh).
TSV_COLUMNS="" WIDTH_WARNING=""
declare -A _wseen=()
_wlist=() _wper=()
for p in "${PASSES[@]}"; do
	_pw="${PWIDTHS[$p]:-}"
	[[ -n "$_pw" ]] || continue
	# shellcheck disable=SC2086  # a comma list of numbers, split on purpose
	_pw="$(printf '%s\n' ${_pw//,/ } | LC_ALL=C sort -n | awk '{ s = s (NR > 1 ? "," : "") $0 } END { print s }')"
	_wper+=("${p} ${_pw}")
	# shellcheck disable=SC2086
	for _w in ${_pw//,/ }; do
		[[ -n "${_wseen[$_w]+x}" ]] || { _wseen[$_w]=1; _wlist+=("$_w"); }
	done
done
if ((${#_wlist[@]} == 0)); then
	if ((${#ALL_TSVS[@]})); then
		TSV_COLUMNS="none (no pass's TSV has a data row)"
	else
		TSV_COLUMNS="none (no pass wrote a TSV)"
	fi
elif ((${#_wlist[@]} == 1)); then
	TSV_COLUMNS="${_wlist[0]}"
else
	TSV_COLUMNS="$(IFS=';'; echo "${_wper[*]}")"
	TSV_COLUMNS="${TSV_COLUMNS//;/; }"
	if [[ "$SUITE" == propagation ]]; then
		WIDTH_WARNING="the passes' TSVs have different column counts (${TSV_COLUMNS}), so their rows are filtered by different rules (tests/lib/propagation.sh): one without remote_status (under 23 columns) drops a row's P2/P3 for either side's failure, one without p1_status (under 21) takes P1 from its iteration's first OK row, and an 18-column one has no p2_dirty or scrape-skew check. Compare those passes with care."
	else
		WIDTH_WARNING="the passes' TSVs have different column counts (${TSV_COLUMNS}): written by different harness versions, so a metric or filter column one of them lacks reads \"-\" or is not applied there. Compare those passes with care."
	fi
	echo "WARNING: ${WIDTH_WARNING}" >&2
fi

# The harness each pass ran (PHS, from its TSVs). HARNESS_WARNING when the passes' values
# differ (or one pass's TSVs do, or its rows: PROWHS): a profile's change may then come
# from the harness. HARNESS_NOTE instead when every pass records one HARNESS_CONTENT_KEY:
# the values differ only in git describe (a commit or tag that left the harness files as
# they were). A TSV without the key reads unknown, so older passes keep the warning.
HARNESS_WARNING="" HARNESS_NOTE=""
_hs_by=() _hs_vals="" _hk_vals="" _hs_rows=""
for p in "${PASSES[@]}"; do
	[[ -n "${PHS[$p]:-}" ]] || continue
	_hs_by+=("${p} ${PHS[$p]}")
	_hs_vals+="${PHS[$p]}"$'\n'
	_hk_vals+="${PHCK[$p]}"$'\n'
	[[ -z "${PROWHS[$p]:-}" ]] || _hs_rows+=" ${PROWHS[$p]^}."
done
_hs_n="$(printf '%s' "$_hs_vals" | LC_ALL=C sort -u | awk 'END { print NR }')"
if [[ "$_hs_vals" == *mixed:* ]] || ((_hs_n > 1)); then
	_hk="$(printf '%s' "$_hk_vals" | LC_ALL=C sort -u)"
	_hs_by_s="$(IFS=';'; echo "${_hs_by[*]}")"
	_hs_by_s="${_hs_by_s//;/; }"
	if [[ -n "$_hk" && "$_hk" != *$'\n'* && "$_hk" != unknown && "$_hk" != mixed:* ]]; then
		HARNESS_NOTE="the passes' HARNESS_SHA values (${_hs_by_s}) differ only in git describe (a commit or tag that left the harness files as they were): every pass records HARNESS_CONTENT_KEY=${_hk}, the same harness files."
		echo "note: ${HARNESS_NOTE}" >&2
	else
		HARNESS_WARNING="the passes ran on different harnesses (HARNESS_SHA ${_hs_by_s}): a profile's change against the baseline may come from the harness, not the profile.${_hs_rows} Compare those passes with care."
		echo "WARNING: ${HARNESS_WARNING}" >&2
	fi
fi

BASE=""
[[ " ${PASSES[*]} " == *" baseline "* ]] && BASE="baseline"

# istio_merged_kv <key>: each member's active Istio revision
# (ISTIO_ACTIVE_REVISIONS), its Istio CR / IstioRevision generations (ISTIO_GENERATIONS:
# a CR edit between passes reads mixed, also at one version) and the proxy versions
# connected to its istiod (ISTIO_PROXY_VERSIONS), over sweep-metadata.txt and every pass's
# TSVs: one value, or mixed:a | b when they differ (PL26); a file without the key reads
# unknown (so a pass written before the key mixes in as unknown, never as the other
# passes' value); unknown for a sweep from before them.
META_INPUTS=()
[[ -f "$META" ]] && META_INPUTS+=("$META")
META_INPUTS+=(${ALL_TSVS[@]+"${ALL_TSVS[@]}"})
istio_merged_kv() {
	local v=""
	((${#META_INPUTS[@]} == 0)) || v="$(config_input_value "$1" unknown "${META_INPUTS[@]}")"
	echo "${v:-unknown}"
}
ISTIO_ACTIVE_REVISIONS_M="$(istio_merged_kv ISTIO_ACTIVE_REVISIONS)"
ISTIO_GENERATIONS_M="$(istio_merged_kv ISTIO_GENERATIONS)"
ISTIO_PROXY_VERSIONS_M="$(istio_merged_kv ISTIO_PROXY_VERSIONS)"

# Rows: label, then one cell per pass.
ROWS=()
row() { local IFS=$'\t'; ROWS+=("$*"); }
cells=("Pass status")
for p in "${PASSES[@]}"; do cells+=("${STATUS[$p]}"); done
row "${cells[@]}"
cells=("Valid / total rows")
for p in "${PASSES[@]}"; do cells+=("${NROWS[$p]:-0/0}"); done
row "${cells[@]}"
# gens_cell <ISTIO_GENERATIONS>: "<gen> (every member)" when every ctx=<gen> pair has
# one value, else the value as recorded (mixed, unknown, members that differ).
gens_cell() {
	awk -v v="$1" 'BEGIN {
		n = split(v, p, ",")
		if (n == 0 || v ~ /^mixed:/) { print v; exit }
		for (i = 1; i <= n; i++) {
			if (p[i] !~ /^[^=]+=[^=]+$/) { print v; exit }
			sub(/^[^=]+=/, "", p[i])
			if (p[i] != p[1]) { print v; exit }
		}
		print p[1] " (every member)"
	}'
}
cells=("Istio CR / IstioRevision generations")
for p in "${PASSES[@]}"; do
	if [[ -n "${PGENS[$p]:-}" ]]; then cells+=("$(gens_cell "${PGENS[$p]}")"); else cells+=("-"); fi
done
row "${cells[@]}"
cells=("Harness (HARNESS_SHA)")
for p in "${PASSES[@]}"; do cells+=("${PHS[$p]:--}"); done
row "${cells[@]}"
# Propagation: the iterations whose drain after the window timed out (DRAIN_TIMEOUT). They
# count (measured before that drain); the row shows only when a pass has one.
if [[ "$SUITE" == propagation ]]; then
	cells=("Drain timeouts (iterations, counted)")
	_dt_any=0
	for p in "${PASSES[@]}"; do
		cells+=("${PDT[$p]:--}")
		[[ "${PDT[$p]:-0}" == 0 ]] || _dt_any=1
	done
	((_dt_any == 0)) || row "${cells[@]}"
fi
# metric_n <pass> <group> <column>: got/attempted (PL17): valid samples with a value
# (overflow counts) / what the pass was configured to take (cfg_attempted), else every
# row the pass wrote in the group; for propagation's P1 columns, else the iterations
# it wrote (one P1 sample each).
metric_n() {
	local k="$1|$2|$3" att
	att="${GROWS["$1|$2"]:-0}"
	case "$3" in p1_ms | p1_conv_p99_ms) att="${GITERS["$1|$2"]:-$att}" ;; esac
	echo "$(( ${VCNT[$k]:-0} + ${VOV[$k]:-0} ))/${ATT[$k]:-$att}"
}
N_DIFFERS=0
for g in "${GROUP_VALUES[@]}"; do
	for m in "${METRICS[@]}"; do
		col="${m%%|*}" rest="${m#*|}"
		label="${rest%|*}" kind="${rest##*|}"
		[[ "$g" != "-" ]] && label="${label} @ ${g}"
		cells=("$label") ncells=("  n (got/attempted)") rcells=("  range (min to max)")
		any=0
		for p in "${PASSES[@]}"; do
			k="$p|$g|$col"
			# A metric is shown when any pass's TSV has its column, even with no value
			# (every row timed out: n 0/10 says so instead of hiding the metric).
			if [[ -z "${VHAS[$k]:-}" ]]; then cells+=("-"); ncells+=("-"); rcells+=("-"); continue; fi
			any=1
			n="$(metric_n "$p" "$g" "$col")"
			if [[ -n "$BASE" && "$p" != "$BASE" && -n "${VHAS["$BASE|$g|$col"]:-}" ]]; then
				bn="$(metric_n "$BASE" "$g" "$col")"
				[[ "$n" != "$bn" ]] && { n="${n} (baseline n ${bn})"; N_DIFFERS=1; }
			fi
			ncells+=("$n")
			rcells+=("$(fmt_range "$kind" "${VMIN[$k]}" "${VMAX[$k]}" "${VOV[$k]}")")
			if [[ -z "${VAL[$k]:-}" ]]; then
				# No mean: every sample overflowed, or none had a value. The P1 cell still
				# says how many iterations it left out for a +Inf overflow.
				cell="-"
				[[ "$col" != p1_ms || "${P1OV["$p|$g"]:-0}" == 0 ]] || cell+=" (${P1OV["$p|$g"]} overflowed)"
				cells+=("$cell")
				continue
			fi
			b=""
			[[ -n "$BASE" && "$p" != "$BASE" ]] && b="${VAL["$BASE|$g|$col"]:-}"
			cell="$(fmt_metric "$kind" "${VAL[$k]}" "${VMAX[$k]}" "${VOV[$k]}" "$b")"
			# The P1 mean leaves out the iterations that overflowed; the cell says how many.
			[[ "$col" != p1_ms || "${P1OV["$p|$g"]:-0}" == 0 ]] || cell+=" (${P1OV["$p|$g"]} overflowed)"
			cells+=("$cell")
		done
		((any)) && { row "${cells[@]}"; row "${ncells[@]}"; row "${rcells[@]}"; }
	done
done

# This report's own harness; the sweep dir it reads is no change to it.
REPORT_HARNESS_SHA="$(report_harness_sha --exclude "$RESULTS_DIR")"

# frontmatter: the markdown's YAML frontmatter (PL19), every value through yaml_str.
frontmatter() {
	local k v o
	echo "---"
	for k in suite run_id contexts passes istio_version istio_version_source istio_version_pin \
		istio_version_by_context istio_notready_at_start istio_ready_waited_sec; do
		case "$k" in
		suite) v="$SUITE" ;;
		passes) v="$(IFS=,; echo "${PASSES[*]}")" ;;
		istio_notready_at_start | istio_ready_waited_sec) v="$(istio_start_kv "${k^^}")" ;;
		*) v="$(meta_get "${k^^}")"; v="${v:-unknown}" ;;
		esac
		yaml_str -v o "$v"
		echo "${k}: ${o}"
	done
	echo "istio_active_revisions: $(yaml_str "$ISTIO_ACTIVE_REVISIONS_M")"
	echo "istio_generations: $(yaml_str "$ISTIO_GENERATIONS_M")"
	echo "istio_proxy_versions: $(yaml_str "$ISTIO_PROXY_VERSIONS_M")"
	echo "harness_sha: $(yaml_str "$(istio_start_kv HARNESS_SHA)")"
	echo "harness_content_key: $(yaml_str "$(istio_start_kv HARNESS_CONTENT_KEY)")"
	echo "report_harness_sha: $(yaml_str "$REPORT_HARNESS_SHA")"
	echo "tsv_columns: $(yaml_str "$TSV_COLUMNS")"
	echo "---"
	echo ""
}

render() {
	if [[ "$FORMAT" == markdown ]]; then
		frontmatter
		echo "# Tuning sweep comparison"
		echo ""
		echo "- Suite: ${SUITE}"
		[[ -n "$(meta_get RUN_ID)" ]] && echo "- Run: $(meta_get RUN_ID)"
		[[ -n "$(meta_get CONTEXTS)" ]] && echo "- Contexts: $(meta_get CONTEXTS)"
		[[ -n "$(meta_get ISTIO_VERSION)" ]] && echo "- Istio: $(meta_get ISTIO_VERSION) (source $(meta_get ISTIO_VERSION_SOURCE), pin $(meta_get ISTIO_VERSION_PIN); by member $(meta_get ISTIO_VERSION_BY_CONTEXT))"
		[[ -n "$(meta_get ISTIO_VERSION)" ]] && echo "- Start-of-run readiness: ISTIO_NOTREADY_AT_START=$(istio_start_kv ISTIO_NOTREADY_AT_START), ISTIO_READY_WAITED_SEC=$(istio_start_kv ISTIO_READY_WAITED_SEC)"
		# Each on its own line, as every other report prints the two.
		echo "- HARNESS_SHA=$(istio_start_kv HARNESS_SHA) (the sweep's)"
		echo "- HARNESS_CONTENT_KEY=$(istio_start_kv HARNESS_CONTENT_KEY) (the sweep's harness files)"
		echo "- REPORT_HARNESS_SHA=${REPORT_HARNESS_SHA} (this report's own)"
		echo "- Active revisions, Istio CR generations and proxy versions at the start: ISTIO_ACTIVE_REVISIONS=${ISTIO_ACTIVE_REVISIONS_M}; ISTIO_GENERATIONS=${ISTIO_GENERATIONS_M}; ISTIO_PROXY_VERSIONS=${ISTIO_PROXY_VERSIONS_M}"
		echo "- TSV columns: ${TSV_COLUMNS}"
		[[ -z "$WIDTH_WARNING" ]] || echo "- **Warning:** ${WIDTH_WARNING}"
		[[ -z "$HARNESS_WARNING" ]] || echo "- **Warning:** ${HARNESS_WARNING}"
		[[ -z "$HARNESS_NOTE" ]] || echo "- Note: ${HARNESS_NOTE}"
		if [[ "$SUITE" == propagation ]]; then
			echo "- Values are means over the samples the propagation report (005) counts: P1 once per iteration, left out only for a source-side reason (p1_status other than OK or DRAIN_TIMEOUT, a +Inf overflow, a source scrape skew over FANOUT_MAX_SKEW_MS; a remote that timed out or restarted keeps it), P2 and P3 per remote row, left out only for that remote's side (remote_status other than OK or DRAIN_TIMEOUT, its scrape skew over FANOUT_MAX_SKEW_MS; the source's restart, P1 timeout or overflow keeps them); \"(N overflowed)\" in the P1 local push cell counts the iterations its mean leaves out for a +Inf overflow. Profiles show the change against the baseline in brackets."
		else
			echo "- Values are means over valid rows (status OK, no istiod restart). Profiles show the change against the baseline in brackets."
		fi
		echo "- The \"Istio CR / IstioRevision generations\" row gives each pass's ISTIO_GENERATIONS from its own TSVs: a profile's apply and revert raise them, so each pass ran on its own (\"(every member)\" when every member has one value). The \"Harness (HARNESS_SHA)\" row gives the harness each pass's TSVs record."
		[[ "$SUITE" != propagation ]] || echo "- \"Drain timeouts (iterations, counted)\" (shown when a pass has one): iterations whose drain after the window timed out (DRAIN_TIMEOUT). Their values count, as in 005: they were measured before that drain."
		echo "- Under each metric: n is got/attempted (valid samples with a value / what the probe was configured to take where its TSV records it, else every row the pass wrote, failed and timed-out rows included) and range is its min to max."
		((N_DIFFERS)) && echo "- **A profile's n differs from the baseline's** (shown as \"(baseline n ...)\"): its mean is over other iterations, so a better mean can come from fewer, easier samples."
		echo "- Histogram p99 rows (\"worst bucket\") are never averaged: they show the highest bucket range a valid row hit, or \"overflow (N rows)\" when N rows had their p99 in the +Inf bucket (propagation's P1 convergence: \"overflow (N iterations)\" when N iterations put a sample in the +Inf bucket, whatever their p99; counted although 005 leaves those iterations out of its means)."
		echo ""
		sweep_outcome_recorded "$RESULTS_DIR" md "$(meta_get RUN_ID)"
		# Every cell through md_cell: a | in a pass name or a value would break the row.
		local hdr="| Metric |" sep="|---|" r c
		for p in "${PASSES[@]}"; do md_cell -v c "$p"; hdr+=" ${c} |"; sep+="---|"; done
		echo "$hdr"
		echo "$sep"
		for r in "${ROWS[@]}"; do md_cell -v r "$r"; echo "| ${r//$'\t'/ | } |"; done
	else
		echo "Tuning sweep comparison (suite: ${SUITE})"
		[[ -z "$(meta_get ISTIO_VERSION)" ]] || echo "Istio: $(meta_get ISTIO_VERSION) (source $(meta_get ISTIO_VERSION_SOURCE), pin $(meta_get ISTIO_VERSION_PIN); by member $(meta_get ISTIO_VERSION_BY_CONTEXT))"
		[[ -z "$(meta_get ISTIO_VERSION)" ]] || echo "Start-of-run readiness: ISTIO_NOTREADY_AT_START=$(istio_start_kv ISTIO_NOTREADY_AT_START), ISTIO_READY_WAITED_SEC=$(istio_start_kv ISTIO_READY_WAITED_SEC)"
		echo "HARNESS_SHA=$(istio_start_kv HARNESS_SHA) (the sweep's)"
		echo "HARNESS_CONTENT_KEY=$(istio_start_kv HARNESS_CONTENT_KEY) (the sweep's harness files)"
		echo "REPORT_HARNESS_SHA=${REPORT_HARNESS_SHA} (this report's own)"
		echo "Active revisions, Istio CR generations and proxy versions at the start: ISTIO_ACTIVE_REVISIONS=${ISTIO_ACTIVE_REVISIONS_M}; ISTIO_GENERATIONS=${ISTIO_GENERATIONS_M}; ISTIO_PROXY_VERSIONS=${ISTIO_PROXY_VERSIONS_M}"
		echo "TSV columns: ${TSV_COLUMNS}"
		[[ -z "$WIDTH_WARNING" ]] || echo "WARNING: ${WIDTH_WARNING}"
		[[ -z "$HARNESS_WARNING" ]] || echo "WARNING: ${HARNESS_WARNING}"
		[[ -z "$HARNESS_NOTE" ]] || echo "Note: ${HARNESS_NOTE}"
		echo "Means over valid rows; profiles show the change against the baseline."
		echo "Istio CR / IstioRevision generations: each pass's own, from its TSVs (its apply and revert raise them)."
		echo "Harness (HARNESS_SHA): each pass's own, from its TSVs."
		[[ "$SUITE" != propagation ]] || echo "Drain timeouts (iterations, counted; shown when a pass has one): their drain after the window timed out (DRAIN_TIMEOUT); measured before it, so they count."
		echo "n = got/attempted (valid samples with a value / configured samples, else rows written); range = min to max."
		((N_DIFFERS)) && echo "WARNING: a profile's n differs from the baseline's (\"(baseline n ...)\"): its mean is over other iterations."
		echo "Histogram p99 rows show the worst bucket a valid row hit (or overflow), not a mean."
		[[ "$SUITE" != propagation ]] || echo "P1 is once per iteration, left out only for a source-side reason; P2 and P3 only for the remote's side; \"(N overflowed)\" counts the iterations its mean leaves out for a +Inf overflow."
		echo ""
		sweep_outcome_recorded "$RESULTS_DIR" text "$(meta_get RUN_ID)"
		{
			printf 'Metric'
			printf '\t%s' "${PASSES[@]}"
			printf '\n'
			printf '%s\n' "${ROWS[@]}"
		} | awk -F'\t' '
			{ for (i = 1; i <= NF; i++) { cell[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } if (NF > nf) nf = NF }
			END { for (r = 1; r <= NR; r++) { line = ""; for (i = 1; i <= nf; i++) line = line sprintf("%-" w[i] "s  ", cell[r, i]); sub(/ +$/, "", line); print line } }'
	fi
}

if [[ -n "$OUTPUT_FILE" ]]; then
	render >"$OUTPUT_FILE"
	echo "Comparison written to ${OUTPUT_FILE}" >&2
else
	render
fi

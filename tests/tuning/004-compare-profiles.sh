#!/usr/bin/env bash
# Compare the passes of a tuning sweep (baseline + one directory per profile).
# Reads each pass's suite TSV, finds columns by header name, averages the valid rows
# and shows each profile's change against the baseline, with each metric's n (valid
# samples / rows the pass attempted, PL17) and range, so a profile whose n differs from
# the baseline's (say 7 of 10 iterations timed out) is visible and flagged.
# Each pass's platform record (tests/lib/platform.sh: platform, mesh builds, node provider; not
# istiod's settings, which a profile changes and the "istiod env" row shows), its members'
# Kubernetes versions, tuning levers, root Sidecar egress hosts and istiod limits and replica
# counts (where its suite records them), each merged over its TSVs, are compared with the
# reference pass's (the baseline, else the first pass with data) in one "Platform record" row: a
# key that differs is a warning with both values, one not read on a side a note. A build or
# setting that changed during a pass is a problem of the sweep's outcome (003 reads the record
# again after each pass), which the comparison repeats.
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
# platform_validate, platform_report_values, platform_merge_by_context, platform_unread,
# platform_summary, platform_short_digests
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/platform.sh"

RESULTS_DIR=""
FORMAT="text"
OUTPUT_FILE=""

usage() {
	cat <<EOF
Usage: $(basename "$0") --results-dir DIR [options]

Compares the passes of a tuning sweep, the baseline and one directory per profile. Each
metric is a mean over the pass's valid rows (status OK, no istiod restart; a propagation
pass counts what its 005 report counts), and each profile shows its change against the
baseline.

Options:
  --results-dir DIR  Sweep directory (tests/tuning/results/sweep-<RUN_ID>) (required).
  --format FMT       text or md (or markdown) (default: text).
  --output FILE      Write to FILE instead of stdout.
  -h, --help         Show this help.

Rows:
  Pass status        ok, the marker its directory holds (SETUP_FAILED, PROBE_FAILED,
                     REVERT_FAILED), or "no data" (no TSV).
  Valid / total rows The rows that count / every row the pass wrote.
  Platform record    The pass against the reference pass (the baseline, else the first
                     pass with data) on its platform, mesh builds, node provider,
                     Kubernetes versions, tuning levers, root Sidecar egress hosts and
                     istiod limits and replica counts (as its suite's TSVs record them,
                     merged over them): same; "differs (see warnings)", one warning per
                     key with both values; "unknown (see notes)", a key not read or not
                     recorded on a side; baseline or reference for that pass; - no data.
  istiod env         Its digest of istiod's settings (a profile changes them), mixed
                     when its members or TSVs differ.
  Harness            Each pass's HARNESS_SHA, shown when one differs from the sweep's.
  Drain timeouts     Propagation iterations whose drain after the window timed out
                     (counted, as in 005), shown when a pass has one.
Under each metric, n is got/attempted (valid samples with a value / what the probe was
configured to take where its TSV records it, else the rows it wrote) and range its min
to max; "(baseline n ...)" flags a profile whose n differs from the baseline's.
Histogram p99 rows show the worst bucket a valid row hit, or "overflow (N rows)"
(propagation's P1: "overflow (N iterations)"), never a mean; the P1 local push cell
says "(N overflowed)" for the iterations its mean leaves out
("- (N overflowed)" when every one did). Memory is in Mi, CPU in millicores (the
controlplane's are window peaks), config sizes in KiB.
The header gives the sweep's Istio version, HARNESS_SHA, SETTLE_SEC, CHURN_RATE and the
reference pass's platform record, then the sweep's outcome (sweep-outcome.txt). The
markdown starts with a YAML frontmatter: suite, run_id, contexts, passes, the istio_*
keys, harness_sha, and settle_sec and churn_rate when the sweep recorded them.

Environment (config/options.env describes each): FANOUT_MAX_SKEW_MS (propagation: the
scrape-skew ceiling a row must be within to count, as in 005). TEST_PLATFORM,
PLATFORM_READ_TIMEOUT and PLATFORM_READ_PARALLEL are only checked: it reads no cluster.

Exit codes: 0 written; 1 bad arguments, or DIR is not a tuning sweep.

See tests/tuning/README.md.
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

platform_validate
[[ -n "$RESULTS_DIR" ]] || die "--results-dir is required"
[[ -d "$RESULTS_DIR" ]] || die "results directory not found: $RESULTS_DIR"
case "$FORMAT" in
text | markdown) ;;
md) FORMAT=markdown ;;
*) die "--format must be text or md (or markdown), not ${FORMAT}" ;;
esac

META="${RESULTS_DIR}/sweep-metadata.txt"
meta_get() { [[ -f "$META" ]] && sed -n "s/^# $1=//p" "$META" | head -1; return 0; }
# istio_start_kv <key>: a key of sweep-metadata.txt (HARNESS_SHA); unknown for a sweep from
# before it.
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
		# Without a subdirectory the pattern stays as it is.
		[[ -d "$d" ]] || continue
		n="$(basename "$d")"
		[[ "$n" == baseline ]] || PASSES+=("$n")
	done
	# A pass directory, or another suite's sweep, holds its TSVs itself.
	! compgen -G "${RESULTS_DIR}/*.tsv" >/dev/null ||
		die "${RESULTS_DIR} holds TSVs itself (a pass directory, or another suite's sweep): give a tuning sweep directory (tests/tuning/results/sweep-<RUN_ID>), which holds one directory per pass"
	# The directory that holds the sweeps (tests/tuning/results): each of them has its metadata.
	if last="$(compgen -G "${RESULTS_DIR}/*/sweep-metadata.txt" | sort | tail -1)" && [[ -n "$last" ]]; then
		die "${RESULTS_DIR} holds tuning sweeps, not passes: give one of them (the last by name: $(dirname "$last"))"
	fi
fi
((${#PASSES[@]})) || die "no pass directories in ${RESULTS_DIR}: give a tuning sweep directory (tests/tuning/results/sweep-<RUN_ID>), which holds one directory per pass"

# reach-*.tsv (the dataplane suites' reachability check, tests/lib/reach.sh) has no
# status column and is not probe data, so it is left out.
# A pass the metadata lists without its directory has none (no data).
pass_tsvs() { find -H "${RESULTS_DIR}/$1" -maxdepth 1 -name '*.tsv' ! -name 'reach-*.tsv' -type f 2>/dev/null | sort || true; }

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
	# repeats on each pod row of a cluster scrape, so summarize takes it once per scrape
	# (file, timestamp, context), and not from a scrape with a row that is not valid, as
	# the controlplane report does; its n counts scrapes. Absent in older 40-column TSVs,
	# where it is skipped. istiod_mem_mi is the window's peak RSS and
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

# One pass -> lines "n<TAB>valid<TAB>total", "g<TAB>group<TAB>rows" (first-seen order;
# rows counts every row of the group, valid or not), "a<TAB>group<TAB>column<TAB>attempted"
# for a column taken once per cluster scrape (cluster_connected_proxies: its scrapes, valid
# or not) and "v<TAB>group<TAB>column<TAB>mean<TAB>max<TAB>n_overflow<TAB>min<TAB>n_numeric"
# for every metric column the TSV has (mean, max and min "-" without a numeric value: a tab
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
# drain after the window timed out; counted, as 005 counts them).
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
	function take(g, c) { takev(g, c, $(idx[c])) }
	# takev(g, c, v): add value v of column c to group g.
	function takev(g, c, v,    k) {
		k = g SUBSEP c
		if (v == "overflow") { ov[k]++; return }
		if (v ~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) {
			if (!(k in cnt) || v + 0 > mx[k]) mx[k] = v + 0
			if (!(k in cnt) || v + 0 < mn[k]) mn[k] = v + 0
			sum[k] += v; cnt[k]++
		}
	}
	# dt_col(c): the row has column c and it reads DRAIN_TIMEOUT.
	function dt_col(c) { return ((c in idx) && $(idx[c]) == "DRAIN_TIMEOUT") }
	BEGIN { nm = split(cols, mc, ","); ng = split(gcols, gc, ",") }
	FNR == 1 { hdr = 0 }
	/^#/ || NF == 0 { next }
	!hdr { delete idx; for (i = 1; i <= NF; i++) idx[$i] = i; hdr = 1; next }
	{
		total++
		g = ""
		for (j = 1; j <= ng; j++) if (gc[j] in idx) g = g (g == "" ? "" : ", ") gc[j] "=" $(idx[gc[j]])
		if (g == "") g = "-"
		if (!(g in seen)) { seen[g] = 1; order[++norder] = g }
		grows[g]++
		for (j = 1; j <= nm; j++) if (mc[j] != "" && (mc[j] in idx)) has[g SUBSEP mc[j]] = 1
		# cluster_connected_proxies repeats on each istiod pod row of a cluster scrape: one
		# value per scrape (file, timestamp, context), attempted once, and none from a scrape
		# with a row that is not valid, as the controlplane report takes it.
		sk = ""
		if (("cluster_connected_proxies" in idx) && ("timestamp" in idx) && ("context" in idx)) {
			sk = FILENAME SUBSEP $(idx["timestamp"]) SUBSEP $(idx["context"])
			if (!(sk in sgrp)) { sgrp[sk] = g; sord[++ns] = sk; satt[g]++ }
		}
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
			bad = 0
			if (("status" in idx) && $(idx["status"]) != "OK") bad = 1
			if (("istiod_restarted" in idx) && $(idx["istiod_restarted"]) != "0") bad = 1
			if (("restarted" in idx) && $(idx["restarted"]) != "0") bad = 1
			if (bad) { if (sk != "") sbad[sk] = 1; next }
		}
		valid++
		for (j = 1; j <= nm; j++) {
			c = mc[j]
			if (c == "" || !(c in idx)) continue
			if (suite == "propagation" && !prop_col_sample(c)) continue
			if (c == "cluster_connected_proxies" && sk != "") { if (!(sk in sval)) sval[sk] = $(idx[c]); continue }
			take(g, c)
		}
	}
	END {
		for (i = 1; i <= ns; i++) {
			sk = sord[i]
			if (!(sk in sbad) && (sk in sval)) takev(sgrp[sk], "cluster_connected_proxies", sval[sk])
		}
		for (gg in satt) printf "a\t%s\tcluster_connected_proxies\t%d\n", gg, satt[gg]
		printf "n\t%d\t%d\n", valid, total
		for (i = 1; i <= norder; i++) printf "g\t%s\t%d\n", order[i], grows[order[i]]
		if (suite == "propagation") for (i = 1; i <= norder; i++) printf "i\t%s\t%d\n", order[i], giters[order[i]]
		if (suite == "propagation") for (i = 1; i <= norder; i++) printf "o\t%s\t%d\n", order[i], p1ov[order[i]] + 0
		if (suite == "propagation") printf "d\t%d\n", dt_iters
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

# The keys each pass is compared on: the record's but istiod's settings (a profile changes
# them), then what a suite's TSV records at its start (each member's Kubernetes version, the
# tuning levers and root Sidecar egress hosts on the source member, istiod's limits and replica
# counts: whichever its suite writes).
COMPARE_KEYS=()
for k in "${PLATFORM_KEYS[@]}"; do [[ "$k" == ISTIOD_ENV_BY_CONTEXT ]] || COMPARE_KEYS+=("$k"); done
TSV_KEYS=(KUBE_VERSIONS TUNING_BASELINE SIDECAR_EGRESS_HOSTS ISTIOD_LIM_CPU_M ISTIOD_LIM_MEM_MI ISTIOD_REPLICAS
	ISTIOD_REPLICAS_BY_CONTEXT)
COMPARE_KEYS+=("${TSV_KEYS[@]}")
# pass_record <tsv>...: KEY=value of each record key and TSV_KEYS key over a pass's TSVs (their
# merge warnings are left out: the comparison words each case): a list of name=value pairs member
# by member (platform_merge_by_context: <ctx>=mixed:<a>;<b> where its TSVs disagree), any other
# value as config_input_value merges it (mixed:<a>,<b>); a TSV without the key reads unknown, and
# a key that none of them records is left out.
pass_record() {
	local k v
	platform_report_values "$@" 2>/dev/null
	for k in "${TSV_KEYS[@]}"; do
		v="$(config_input_value "$k" "" "$@")"
		[[ -n "$v" ]] || continue
		# The controlplane's ISTIOD_REPLICAS summarizes its ISTIOD_REPLICAS_BY_CONTEXT; propagation
		# and the churn suite record ISTIOD_REPLICAS by member, churn-dataplane as one count.
		[[ "$k" != ISTIOD_REPLICAS || -z "$(config_input_value ISTIOD_REPLICAS_BY_CONTEXT "" "$@")" ]] || continue
		if [[ "$k" == KUBE_VERSIONS || "$k" == TUNING_BASELINE || "$k" == *_BY_CONTEXT || ("$k" == ISTIOD_REPLICAS && "$v" == *=*) ]]; then
			printf '%s=%s\n' "$k" "$(platform_merge_by_context "$k" "$@" 2>/dev/null)"
		else
			printf '%s=%s\n' "$k" "$(config_input_value "$k" unknown "$@")"
		fi
	done
}

declare -A VAL VMAX VOV VMIN VCNT VHAS GROWS GITERS P1OV NROWS STATUS GSEEN PHS PDT
declare -A PLAT  # pass -> its record (pass_record)
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
	# The harness this pass ran (its TSVs' HARNESS_SHA): mixed when its TSVs disagree, unknown
	# for a TSV without the key.
	PHS[$p]="$(config_input_value HARNESS_SHA unknown "${files[@]}")"
	while IFS=$'\t' read -r kind a b c d e f h; do
		case "$kind" in
		n) NROWS[$p]="${a}/${b}" ;;
		d) PDT[$p]="$a" ;;
		g) GROWS["$p|$a"]="$b"; [[ -n "${GSEEN[$a]:-}" ]] || { GSEEN[$a]=1; GROUP_VALUES+=("$a"); } ;;
		i) GITERS["$p|$a"]="$b" ;;
		o) P1OV["$p|$a"]="$b" ;;
		# A column taken once per cluster scrape is attempted once per scrape (metric_n).
		a) ATT["$p|$a|$b"]="$c" ;;
		v)
			VHAS["$p|$a|$b"]=1; VMAX["$p|$a|$b"]="$d"; VOV["$p|$a|$b"]="$e"
			VMIN["$p|$a|$b"]="$f"; VCNT["$p|$a|$b"]="$h"
			# VAL only for a metric with a value: a mean, or a hist p99 that overflowed.
			[[ "$c" != "-" || "$e" != 0 ]] && VAL["$p|$a|$b"]="$c"
			;;
		esac
	done < <(summarize "${files[@]}")
	PLAT[$p]="$(pass_record "${files[@]}")"
done
((${#GROUP_VALUES[@]})) || GROUP_VALUES=("-")

# The harness each pass ran (PHS, from its TSVs): a row when one differs from the sweep's
# (HARNESS_HS, the header's), and HARNESS_WARNING when the passes' values differ, or one pass's
# TSVs do: a profile's change may then come from the harness.
HARNESS_HS="$(istio_start_kv HARNESS_SHA)"
HARNESS_WARNING="" HARNESS_ROW=0
_hs_by=() _hs_vals=""
for p in "${PASSES[@]}"; do
	[[ -n "${PHS[$p]:-}" ]] || continue
	[[ "${PHS[$p]}" == "$HARNESS_HS" ]] || HARNESS_ROW=1
	_hs_by+=("${p} ${PHS[$p]}")
	_hs_vals+="${PHS[$p]}"$'\n'
done
_hs_n="$(printf '%s' "$_hs_vals" | LC_ALL=C sort -u | awk 'END { print NR }')"
if [[ "$_hs_vals" == *mixed:* ]] || ((_hs_n > 1)); then
	_hs_by_s="$(IFS=';'; echo "${_hs_by[*]}")"
	HARNESS_WARNING="the passes ran on different harnesses (HARNESS_SHA ${_hs_by_s//;/; }): a profile's change against the baseline may come from the harness, not the profile. Compare those passes with care."
	echo "WARNING: ${HARNESS_WARNING}" >&2
fi

BASE=""
[[ " ${PASSES[*]} " == *" baseline "* ]] && BASE="baseline"

# istio_merged_kv <key>: each member's active Istio revision (ISTIO_ACTIVE_REVISIONS) and
# its Istio CR / IstioRevision generations (ISTIO_GENERATIONS: a profile's apply raises
# them, so the passes read mixed, also at one version), over sweep-metadata.txt and every
# pass's TSVs: one value, or mixed:a | b when they differ (PL26); a file without the key reads
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

# Rows: label, then one cell per pass.
ROWS=()
row() { local IFS=$'\t'; ROWS+=("$*"); }
cells=("Pass status")
for p in "${PASSES[@]}"; do cells+=("${STATUS[$p]}"); done
row "${cells[@]}"
cells=("Valid / total rows")
for p in "${PASSES[@]}"; do cells+=("${NROWS[$p]:-0/0}"); done
row "${cells[@]}"
# plat_value <pass> <key>: that key's value in the pass's record (empty: its TSVs do not record it).
plat_value() { sed -n "s/^${2}=//p" <<<"${PLAT[$1]:-}" | head -n 1; }
# is_list <value>: return 0 for a list of name=value pairs (a member's, a lever's), with or without
# the mixed:unknown token of TSVs that predate the key (platform_merge_by_context).
is_list() { [[ "$1" == *=* && "$1" != *" | "* && ( "$1" != mixed:* || "$1" == mixed:unknown,* ) ]]; }
# cmp_one <key> <a> <b> [member]: one value of each side: same, differs or unknown. A member's (or
# a lever's) mixed:<a>;<b> is the set of what it ran: two sets read that are not the same differ,
# and a part not read (platform_unread) otherwise leaves it unknown, never another value nor the
# same (PL61). Any other value is one: not read on a side is unknown, else it differs.
cmp_one() {
	local x u=0 sa=";" sb=";"
	local -a pa=() pb=()
	if [[ -z "${4:-}" ]]; then
		if platform_unread "$1" "$2" || platform_unread "$1" "$3"; then
			echo unknown
		elif [[ "$2" == "$3" ]]; then
			echo same
		else
			echo differs
		fi
		return 0
	fi
	IFS=';' read -r -a pa <<<"${2#mixed:}"
	IFS=';' read -r -a pb <<<"${3#mixed:}"
	for x in ${pa[@]+"${pa[@]}"}; do if platform_unread "$1" "$x"; then u=1; else sa+="${x};"; fi; done
	for x in ${pb[@]+"${pb[@]}"}; do if platform_unread "$1" "$x"; then u=1; else sb+="${x};"; fi; done
	if [[ "$sa" != ";" && "$sb" != ";" ]]; then
		IFS=';' read -r -a pa <<<"${sa#;}"
		IFS=';' read -r -a pb <<<"${sb#;}"
		for x in "${pa[@]}"; do [[ "$sb" == *";${x};"* ]] || { echo differs; return 0; }; done
		for x in "${pb[@]}"; do [[ "$sa" == *";${x};"* ]] || { echo differs; return 0; }; done
	fi
	if ((u)); then echo unknown; else echo same; fi
}
# cmp_values <key> <reference value> <value>: same, differs or unknown. Two lists of name=value
# pairs (members, levers) are compared name by name (cmp_one): a name on one side only differs,
# and the mixed:unknown token leaves the result unknown unless a name differs. Any other value is
# compared as one (cmp_one).
cmp_values() {
	local k="$1" pair c r u=0
	local -a pairs=()
	local -A va=() vb=()
	case "$k" in
	PLATFORM | TEST_PLATFORM | SIDECAR_EGRESS_HOSTS | ISTIOD_LIM_*) cmp_one "$k" "$2" "$3"; return 0 ;;
	esac
	if ! is_list "$2" || ! is_list "$3"; then
		cmp_one "$k" "$2" "$3"
		return 0
	fi
	IFS=',' read -r -a pairs <<<"$2"
	for pair in "${pairs[@]}"; do if [[ "$pair" == *=* ]]; then va[${pair%%=*}]="${pair#*=}"; else u=1; fi; done
	IFS=',' read -r -a pairs <<<"$3"
	for pair in "${pairs[@]}"; do if [[ "$pair" == *=* ]]; then vb[${pair%%=*}]="${pair#*=}"; else u=1; fi; done
	for c in "${!va[@]}"; do [[ -n "${vb[$c]+x}" ]] || { echo differs; return 0; }; done
	for c in "${!vb[@]}"; do
		[[ -n "${va[$c]+x}" ]] || { echo differs; return 0; }
		# One value on each side, the same: same, unless it was not read.
		if [[ "${va[$c]}" == "${vb[$c]}" && "${va[$c]}" != mixed:* ]]; then
			! platform_unread "$k" "${va[$c]}" || u=1
			continue
		fi
		r="$(cmp_one "$k" "${va[$c]}" "${vb[$c]}" member)"
		[[ "$r" != differs ]] || { echo differs; return 0; }
		[[ "$r" == same ]] || u=1
	done
	if ((u)); then echo unknown; else echo same; fi
}
# rec_text <key> <value>: a value as a warning shows it: a member list without its members' names
# (platform_summary: each value with its member count, digests shortened; propagation and the churn
# suite record ISTIOD_REPLICAS by member), any other value as it is (digests shortened); cut after
# 200 characters.
rec_text() {
	local v
	case "$1" in
	*_BY_CONTEXT | KUBE_VERSIONS | ISTIOD_REPLICAS) v="$(platform_summary "$2")" ;;
	*) v="$(platform_short_digests "$2")" ;;
	esac
	((${#v} <= 200)) || v="${v:0:197}..."
	printf '%s\n' "$v"
}
# The Platform record row: each pass with data against the reference pass (REF: the baseline, else
# the first pass with data) over COMPARE_KEYS; a key neither records is left out. A key that
# differs warns, in the output and on stderr (PL39), with both values: the pass's change against
# the baseline is then not the profile's alone. A key not read, or not recorded, on a side is a
# note: whether it differs is not known.
REF=""
[[ -z "$BASE" || -z "${PLAT[$BASE]:-}" ]] || REF="$BASE"
if [[ -z "$REF" ]]; then
	for p in "${PASSES[@]}"; do
		[[ -z "${PLAT[$p]:-}" ]] || { REF="$p"; break; }
	done
fi
REF_NAME="baseline" REF_SO="its change against the baseline is not the profile's alone"
if [[ -n "$REF" && "$REF" != "$BASE" ]]; then
	REF_NAME="reference pass (${REF}, the first with data)" REF_SO="its difference from that pass is not the profiles' alone"
fi
PLAT_WARNINGS=() PLAT_NOTES=()
cells=("Platform record")
for p in "${PASSES[@]}"; do
	if [[ -z "${PLAT[$p]:-}" ]]; then cells+=("-"); continue; fi
	if [[ "$p" == "$REF" ]]; then
		if [[ "$REF" == "$BASE" ]]; then cells+=("baseline"); else cells+=("reference"); fi
		continue
	fi
	cell="same"
	for k in "${COMPARE_KEYS[@]}"; do
		a="$(plat_value "$REF" "$k")" b="$(plat_value "$p" "$k")"
		[[ -n "${a}${b}" ]] || continue
		case "$(cmp_values "$k" "${a:-unknown}" "${b:-unknown}")" in
		differs)
			cell="differs (see warnings)"
			PLAT_WARNINGS+=("pass ${p}: ${k} is $(rec_text "$k" "$b"), against $(rec_text "$k" "$a") in the ${REF_NAME}, so ${REF_SO}")
			;;
		unknown)
			[[ "$cell" != same ]] || cell="unknown (see notes)"
			PLAT_NOTES+=("pass ${p}: ${k} is not known to match the ${REF_NAME} (not read, or not recorded, on one side): $(rec_text "$k" "${b:-not recorded}"), against $(rec_text "$k" "${a:-not recorded}") in the ${REF_NAME}")
			;;
		esac
	done
	cells+=("$cell")
done
row "${cells[@]}"
for w in ${PLAT_WARNINGS[@]+"${PLAT_WARNINGS[@]}"}; do echo "warning: ${w}" >&2; done
# env_cell <ISTIOD_ENV_BY_CONTEXT>: the digest every member's istiod ran ("(partly unknown)" after
# it when some were not read), unknown when none was read, else mixed (members, TSVs or istiod pods
# that ran different settings).
env_cell() {
	local pair v one="" u=0
	local -a pairs=()
	IFS=',' read -r -a pairs <<<"$1"
	for pair in ${pairs[@]+"${pairs[@]}"}; do
		v="${pair#*=}"
		if [[ "$v" == unknown || "$pair" == mixed:unknown ]]; then u=1; continue; fi
		[[ "$pair" == *=* && "$v" != mixed:* && ( -z "$one" || "$v" == "$one" ) ]] || { echo mixed; return 0; }
		one="$v"
	done
	if [[ -z "$one" ]]; then echo unknown; elif ((u)); then echo "${one} (partly unknown)"; else echo "$one"; fi
}
cells=("istiod env")
for p in "${PASSES[@]}"; do
	if [[ -z "${PLAT[$p]:-}" ]]; then cells+=("-"); else cells+=("$(env_cell "$(plat_value "$p" ISTIOD_ENV_BY_CONTEXT)")"); fi
done
row "${cells[@]}"
if ((HARNESS_ROW)); then
	cells=("Harness (HARNESS_SHA)")
	for p in "${PASSES[@]}"; do cells+=("${PHS[$p]:--}"); done
	row "${cells[@]}"
fi
# PLAT_LINE: the reference pass's record in one line (rec_text; the TSVs keep its values in full).
PLAT_LINE=""
if [[ -n "$REF" ]]; then
	PLAT_LINE="$(plat_value "$REF" PLATFORM) (TEST_PLATFORM $(plat_value "$REF" TEST_PLATFORM))"
	for k in NODE_PROVIDER_BY_CONTEXT:nodes MESH_OPERATOR_BY_CONTEXT:operator ISTIOD_IMAGE_BY_CONTEXT:istiod \
		"PROXY_IMAGE_BY_CONTEXT:gateway proxy" KUBE_VERSIONS:Kubernetes; do
		PLAT_LINE+="; ${k#*:} $(rec_text "${k%%:*}" "$(plat_value "$REF" "${k%%:*}")")"
	done
fi
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

# frontmatter: the markdown's YAML frontmatter (PL19), every value through yaml_str.
frontmatter() {
	local k v o
	echo "---"
	for k in suite run_id contexts passes istio_version istio_version_source istio_version_pin \
		istio_version_by_context; do
		case "$k" in
		suite) v="$SUITE" ;;
		passes) v="$(IFS=,; echo "${PASSES[*]}")" ;;
		*) v="$(meta_get "${k^^}")"; v="${v:-unknown}" ;;
		esac
		yaml_str -v o "$v"
		echo "${k}: ${o}"
	done
	echo "istio_active_revisions: $(yaml_str "$ISTIO_ACTIVE_REVISIONS_M")"
	echo "istio_generations: $(yaml_str "$ISTIO_GENERATIONS_M")"
	echo "harness_sha: $(yaml_str "$HARNESS_HS")"
	[[ -z "$(meta_get SETTLE_SEC)" ]] || echo "settle_sec: $(yaml_str -n "$(meta_get SETTLE_SEC)")"
	[[ -z "$(meta_get CHURN_RATE)" ]] || echo "churn_rate: $(yaml_str -n "$(meta_get CHURN_RATE)")"
	echo "---"
	echo ""
}

render() {
	local w
	if [[ "$FORMAT" == markdown ]]; then
		frontmatter
		echo "# Tuning sweep comparison"
		echo ""
		echo "- Suite: ${SUITE}"
		[[ -n "$(meta_get RUN_ID)" ]] && echo "- Run: $(meta_get RUN_ID)"
		[[ -n "$(meta_get CONTEXTS)" ]] && echo "- Contexts: $(meta_get CONTEXTS)"
		[[ -n "$(meta_get ISTIO_VERSION)" ]] && echo "- Istio: $(meta_get ISTIO_VERSION) (source $(meta_get ISTIO_VERSION_SOURCE), pin $(meta_get ISTIO_VERSION_PIN); by member $(meta_get ISTIO_VERSION_BY_CONTEXT))"
		echo "- HARNESS_SHA=${HARNESS_HS} (the sweep's)"
		[[ -z "$(meta_get SETTLE_SEC)" ]] || echo "- SETTLE_SEC=$(meta_get SETTLE_SEC) (each pass's wait after its apply, before its probe)"
		[[ -z "$(meta_get CHURN_RATE)" ]] || echo "- CHURN_RATE=$(meta_get CHURN_RATE) (churn operations/s during each pass's probe)"
		echo "- Active revisions and Istio CR generations (the sweep's start and its passes): ISTIO_ACTIVE_REVISIONS=${ISTIO_ACTIVE_REVISIONS_M}; ISTIO_GENERATIONS=${ISTIO_GENERATIONS_M}"
		[[ -z "$PLAT_LINE" ]] || echo "- Platform record of the ${REF_NAME}: ${PLAT_LINE}"
		[[ -z "$HARNESS_WARNING" ]] || echo "- **Warning:** ${HARNESS_WARNING}"
		if [[ "$SUITE" == propagation ]]; then
			echo "- Values are means over the samples the propagation report (005) counts: P1 once per iteration, left out only for a source-side reason (p1_status other than OK or DRAIN_TIMEOUT, a +Inf overflow, a source scrape skew over FANOUT_MAX_SKEW_MS; a remote that timed out or restarted keeps it), P2 and P3 per remote row, left out only for that remote's side (remote_status other than OK or DRAIN_TIMEOUT, its scrape skew over FANOUT_MAX_SKEW_MS; the source's restart, P1 timeout or overflow keeps them); \"(N overflowed)\" in the P1 local push cell counts the iterations its mean leaves out for a +Inf overflow. Profiles show the change against the baseline in brackets."
		else
			echo "- Values are means over valid rows (status OK, no istiod restart). Profiles show the change against the baseline in brackets."
			[[ "$SUITE" != controlplane ]] || echo "- \"Connected proxies / cluster\" is one value per cluster scrape (its n counts scrapes), none from a scrape with an istiod pod row that is not valid, as the controlplane report takes it."
		fi
		echo "- \"Platform record\" compares each pass with the ${REF_NAME:-reference pass} on its platform, builds, node provider, Kubernetes versions, tuning levers, root Sidecar egress hosts and istiod limits and replica counts, as its TSVs record them: a key that differs warns with both values, one not read on a side is a note. \"istiod env\" is each pass's digest of istiod's settings, which a profile changes."
		[[ "$SUITE" != propagation ]] || echo "- \"Drain timeouts (iterations, counted)\" (shown when a pass has one): iterations whose drain after the window timed out (DRAIN_TIMEOUT). Their values count, as in 005: they were measured before that drain."
		echo "- Under each metric: n is got/attempted (valid samples with a value / what the probe was configured to take where its TSV records it, else every row the pass wrote, failed and timed-out rows included) and range is its min to max."
		((N_DIFFERS)) && echo "- **A profile's n differs from the baseline's** (shown as \"(baseline n ...)\"): its mean is over other iterations, so a better mean can come from fewer, easier samples."
		echo "- Histogram p99 rows (\"worst bucket\") are never averaged: they show the highest bucket range a valid row hit, or \"overflow (N rows)\" when N rows had their p99 in the +Inf bucket (propagation's P1 convergence: \"overflow (N iterations)\" when N iterations put a sample in the +Inf bucket, whatever their p99; counted although 005 leaves those iterations out of its means)."
		for w in ${PLAT_WARNINGS[@]+"${PLAT_WARNINGS[@]}"}; do echo "- **Warning:** ${w}"; done
		for w in ${PLAT_NOTES[@]+"${PLAT_NOTES[@]}"}; do echo "- Note: ${w}"; done
		echo ""
		sweep_outcome_lines md "$RESULTS_DIR"
		# Every cell through md_cell: a | in a pass name or a value would break the row.
		local hdr="| Metric |" sep="|---|" r c
		for p in "${PASSES[@]}"; do md_cell -v c "$p"; hdr+=" ${c} |"; sep+="---|"; done
		echo "$hdr"
		echo "$sep"
		for r in "${ROWS[@]}"; do md_cell -v r "$r"; echo "| ${r//$'\t'/ | } |"; done
	else
		echo "Tuning sweep comparison (suite: ${SUITE})"
		[[ -z "$(meta_get ISTIO_VERSION)" ]] || echo "Istio: $(meta_get ISTIO_VERSION) (source $(meta_get ISTIO_VERSION_SOURCE), pin $(meta_get ISTIO_VERSION_PIN); by member $(meta_get ISTIO_VERSION_BY_CONTEXT))"
		echo "HARNESS_SHA=${HARNESS_HS} (the sweep's)"
		[[ -z "$(meta_get SETTLE_SEC)" ]] || echo "SETTLE_SEC=$(meta_get SETTLE_SEC) (each pass's wait after its apply, before its probe)"
		[[ -z "$(meta_get CHURN_RATE)" ]] || echo "CHURN_RATE=$(meta_get CHURN_RATE) (churn operations/s during each pass's probe)"
		echo "Active revisions and Istio CR generations (the sweep's start and its passes): ISTIO_ACTIVE_REVISIONS=${ISTIO_ACTIVE_REVISIONS_M}; ISTIO_GENERATIONS=${ISTIO_GENERATIONS_M}"
		[[ -z "$PLAT_LINE" ]] || echo "Platform record of the ${REF_NAME}: ${PLAT_LINE}"
		[[ -z "$HARNESS_WARNING" ]] || echo "WARNING: ${HARNESS_WARNING}"
		echo "Means over valid rows; profiles show the change against the baseline."
		[[ "$SUITE" != controlplane ]] || echo "Connected proxies / cluster: one value per cluster scrape (n counts scrapes), none from a scrape with an istiod pod row that is not valid."
		echo "Platform record: each pass against the ${REF_NAME:-reference pass} (a key that differs warns, one not read on a side is a note); istiod env: each pass's digest of istiod's settings."
		[[ "$SUITE" != propagation ]] || echo "Drain timeouts (iterations, counted; shown when a pass has one): their drain after the window timed out (DRAIN_TIMEOUT); measured before it, so they count."
		echo "n = got/attempted (valid samples with a value / configured samples, else rows written); range = min to max."
		((N_DIFFERS)) && echo "WARNING: a profile's n differs from the baseline's (\"(baseline n ...)\"): its mean is over other iterations."
		echo "Histogram p99 rows show the worst bucket a valid row hit (or overflow), not a mean."
		[[ "$SUITE" != propagation ]] || echo "P1 is once per iteration, left out only for a source-side reason; P2 and P3 only for the remote's side; \"(N overflowed)\" counts the iterations its mean leaves out for a +Inf overflow."
		for w in ${PLAT_WARNINGS[@]+"${PLAT_WARNINGS[@]}"}; do echo "WARNING: ${w}"; done
		for w in ${PLAT_NOTES[@]+"${PLAT_NOTES[@]}"}; do echo "Note: ${w}"; done
		echo ""
		sweep_outcome_lines text "$RESULTS_DIR"
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
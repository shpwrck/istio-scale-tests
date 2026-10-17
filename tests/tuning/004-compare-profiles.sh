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
source "${ROOT}/config/versions.env"  # sources options.env: FANOUT_MAX_SKEW_MS, as in propagation 005 (C1)
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

Compare tuning sweep passes. Values are means over valid rows (status OK, no
istiod restart; a propagation pass counts exactly the rows and samples its 005
report counts, P1 once per iteration and left out only for a source-side reason, P2
and P3 left out only for the remote's side);
each profile also shows its change against the baseline. Under each metric, "n" is got/attempted: the valid samples with a
value for it / what the pass's probe was configured to run, where its TSV records
it (propagation: iterations for P1, iterations x remotes for P2 and P3; churn:
iterations), else every row the pass wrote in that group (failed and timed-out
rows included); "range" is its min to max. A profile whose n differs from the
baseline's shows "(baseline n ...)": its mean is over other iterations, so compare
it with care.
Histogram p99 rows (convergence, push time) show the worst bucket a valid row hit,
or "overflow (N rows)", never a mean; propagation's P1 convergence counts iterations,
"overflow (N iterations)": an iteration whose window put a sample in +Inf is left out
of the means (as 005 drops it) but counted here, so a profile that overflowed never
looks better than it was; the P1 local push cell says "(N overflowed)" for the same
iterations, which its mean leaves out. Memory is in Mi, CPU in millicores (the
controlplane's istiod CPU and memory are window peaks), config sizes in KiB, and a
count's mean prints bare when it is whole (438, not 438.00).

Options:
  --results-dir DIR  Sweep directory (tests/tuning/results/sweep-<RUN_ID>) (required).
  --format FMT       text or md (or markdown) (default: text).
  --output FILE      Write to FILE instead of stdout.
  -h, --help         Show this help.

When the sweep dir holds sweep-outcome.txt (003 writes it), the
comparison repeats it, with the run that recorded it: the failed passes by reason, its
problems (the Istio version or active revision changed under the sweep) and notes
(members not ready at its start or end). The sweep writes it at its start as "not
finished" (EXIT=unfinished) and replaces it at its end: a record still not finished is
a sweep that died or still runs, or (I5) one interrupted, with when and by which signal;
one that stopped on an error after its start shows the stop and its reason. A sweep dir
without the file is from a sweep that stopped before its start (nothing ran), or from
an older harness.

Environment:
  FANOUT_MAX_SKEW_MS  propagation: the scrape-skew ceiling (ms) a row must be within to
                      count, as in propagation 005 (default 1000, set in config/options.env).
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
# istio_start_kv <key>: an R2 start-of-run readiness key (ISTIO_NOTREADY_AT_START,
# ISTIO_READY_WAITED_SEC) from sweep-metadata.txt; unknown for a sweep from before R2.
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
# histi (hist counted per iteration: "overflow (N iterations)"; propagation's P1, M2).
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

# One pass -> lines "n<TAB>valid<TAB>total", "g<TAB>group<TAB>rows" (first-seen
# order; rows counts every row of the group, valid or not) and
# "v<TAB>group<TAB>column<TAB>mean<TAB>max<TAB>n_overflow<TAB>min<TAB>n_numeric" for
# every metric column the TSV has (mean, max and min "-" without a numeric value: a
# tab IFS would merge empty fields). A group is "col=value, col=value", or "-".
# "overflow" (a histogram p99 in +Inf) is counted, not dropped. A propagation pass
# counts what its 005 report counts (D2): P2 and P3 from the rows prop_drop_reason keeps
# (the remote side only, I6), P2 without a dirty sample, and P1 and its convergence p99 once per iteration, decided before the row
# filter from the source side only (prop_p1_first, B2; tests/lib/propagation.sh, with
# 005's skew ceiling FANOUT_MAX_SKEW_MS). An iteration left out for a P1 overflow (its
# source side otherwise clean) is counted into the convergence p99's overflow once (M2),
# and "o<TAB>group<TAB>iterations" gives that count for the P1 local push cell's
# "(N overflowed)" (B4). "i<TAB>group<TAB>iterations": a propagation pass's distinct
# (run_id, iteration) per group, what P1 is attempted against when the TSV does not
# record ITERATIONS (X2).
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
		if (suite == "propagation") {
			if (!((g, $1, $3) in iter_seen)) { iter_seen[g, $1, $3] = 1; giters[g]++ }
			# P1 and its convergence p99: once per iteration, before the row filter, left
			# out only for a source-side reason (B2), as 005 counts them.
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
		for (i = 1; i <= norder; i++) printf "g\t%s\t%d\n", order[i], grows[order[i]]
		if (suite == "propagation") for (i = 1; i <= norder; i++) printf "i\t%s\t%d\n", order[i], giters[order[i]]
		if (suite == "propagation") for (i = 1; i <= norder; i++) printf "o\t%s\t%d\n", order[i], p1ov[order[i]] + 0
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

# cfg_attempted <pass> <tsv>...: D3 (PL17). ATT[<pass>|-|<column>] = the samples the
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

declare -A VAL VMAX VOV VMIN VCNT VHAS GROWS GITERS P1OV NROWS STATUS GSEEN
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
	while IFS=$'\t' read -r kind a b c d e f h; do
		case "$kind" in
		n) NROWS[$p]="${a}/${b}" ;;
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

BASE=""
[[ " ${PASSES[*]} " == *" baseline "* ]] && BASE="baseline"

# istio_merged_kv <key>: N13/A5/A7, each member's active Istio revision
# (ISTIO_ACTIVE_REVISIONS), its Istio CR / IstioRevision generations (ISTIO_GENERATIONS:
# a CR edit between passes reads mixed, also at one version) and the proxy versions
# connected to its istiod (ISTIO_PROXY_VERSIONS), over sweep-metadata.txt and every pass's
# TSVs: one value, or mixed:a | b when they differ (PL26); a file without the key reads
# unknown (I3: so a pass written before the key mixes in as unknown, never as the other
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
# metric_n <pass> <group> <column>: got/attempted (PL17): valid samples with a value
# (overflow counts) / what the pass was configured to take (cfg_attempted), else every
# row the pass wrote in the group; for propagation's P1 columns, else the iterations
# it wrote (one P1 sample each, X2).
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
			if [[ -z "${VAL[$k]:-}" ]]; then cells+=("-"); continue; fi
			b=""
			[[ -n "$BASE" && "$p" != "$BASE" ]] && b="${VAL["$BASE|$g|$col"]:-}"
			cell="$(fmt_metric "$kind" "${VAL[$k]}" "${VMAX[$k]}" "${VOV[$k]}" "$b")"
			# B4: the P1 mean leaves out the iterations that overflowed; the cell says how many.
			[[ "$col" != p1_ms || "${P1OV["$p|$g"]:-0}" == 0 ]] || cell+=" (${P1OV["$p|$g"]} overflowed)"
			cells+=("$cell")
		done
		((any)) && { row "${cells[@]}"; row "${ncells[@]}"; row "${rcells[@]}"; }
	done
done

render() {
	if [[ "$FORMAT" == markdown ]]; then
		echo "# Tuning sweep comparison"
		echo ""
		echo "- Suite: ${SUITE}"
		[[ -n "$(meta_get RUN_ID)" ]] && echo "- Run: $(meta_get RUN_ID)"
		[[ -n "$(meta_get CONTEXTS)" ]] && echo "- Contexts: $(meta_get CONTEXTS)"
		[[ -n "$(meta_get ISTIO_VERSION)" ]] && echo "- Istio: $(meta_get ISTIO_VERSION) (source $(meta_get ISTIO_VERSION_SOURCE), pin $(meta_get ISTIO_VERSION_PIN); by member $(meta_get ISTIO_VERSION_BY_CONTEXT))"
		[[ -n "$(meta_get ISTIO_VERSION)" ]] && echo "- Start-of-run readiness: ISTIO_NOTREADY_AT_START=$(istio_start_kv ISTIO_NOTREADY_AT_START), ISTIO_READY_WAITED_SEC=$(istio_start_kv ISTIO_READY_WAITED_SEC)"
		echo "- Active revisions, Istio CR generations and proxy versions at the start: ISTIO_ACTIVE_REVISIONS=${ISTIO_ACTIVE_REVISIONS_M}; ISTIO_GENERATIONS=${ISTIO_GENERATIONS_M}; ISTIO_PROXY_VERSIONS=${ISTIO_PROXY_VERSIONS_M}"
		if [[ "$SUITE" == propagation ]]; then
			echo "- Values are means over the samples the propagation report (005) counts: P1 once per iteration, left out only for a source-side reason (p1_status not OK, a +Inf overflow, a source scrape skew over FANOUT_MAX_SKEW_MS; a remote that timed out or restarted keeps it), P2 and P3 per remote row, left out only for that remote's side (remote_status not OK, its scrape skew over FANOUT_MAX_SKEW_MS; the source's restart, P1 timeout or overflow keeps them); \"(N overflowed)\" in the P1 local push cell counts the iterations its mean leaves out for a +Inf overflow. Profiles show the change against the baseline in brackets."
		else
			echo "- Values are means over valid rows (status OK, no istiod restart). Profiles show the change against the baseline in brackets."
		fi
		echo "- Under each metric: n is got/attempted (valid samples with a value / what the probe was configured to take where its TSV records it, else every row the pass wrote, failed and timed-out rows included) and range is its min to max."
		((N_DIFFERS)) && echo "- **A profile's n differs from the baseline's** (shown as \"(baseline n ...)\"): its mean is over other iterations, so a better mean can come from fewer, easier samples."
		echo "- Histogram p99 rows (\"worst bucket\") are never averaged: they show the highest bucket range a valid row hit, or \"overflow (N rows)\" when N rows had their p99 in the +Inf bucket (propagation's P1 convergence: \"overflow (N iterations)\" when N iterations put a sample in the +Inf bucket, whatever their p99; counted although 005 leaves those iterations out of its means)."
		echo ""
		sweep_outcome_recorded "$RESULTS_DIR" md "$(meta_get RUN_ID)"
		local hdr="| Metric |" sep="|---|" r
		for p in "${PASSES[@]}"; do hdr+=" ${p} |"; sep+="---|"; done
		echo "$hdr"
		echo "$sep"
		for r in "${ROWS[@]}"; do echo "| ${r//$'\t'/ | } |"; done
	else
		echo "Tuning sweep comparison (suite: ${SUITE})"
		[[ -z "$(meta_get ISTIO_VERSION)" ]] || echo "Istio: $(meta_get ISTIO_VERSION) (source $(meta_get ISTIO_VERSION_SOURCE), pin $(meta_get ISTIO_VERSION_PIN); by member $(meta_get ISTIO_VERSION_BY_CONTEXT))"
		[[ -z "$(meta_get ISTIO_VERSION)" ]] || echo "Start-of-run readiness: ISTIO_NOTREADY_AT_START=$(istio_start_kv ISTIO_NOTREADY_AT_START), ISTIO_READY_WAITED_SEC=$(istio_start_kv ISTIO_READY_WAITED_SEC)"
		echo "Active revisions, Istio CR generations and proxy versions at the start: ISTIO_ACTIVE_REVISIONS=${ISTIO_ACTIVE_REVISIONS_M}; ISTIO_GENERATIONS=${ISTIO_GENERATIONS_M}; ISTIO_PROXY_VERSIONS=${ISTIO_PROXY_VERSIONS_M}"
		echo "Means over valid rows; profiles show the change against the baseline."
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

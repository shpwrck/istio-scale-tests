#!/usr/bin/env bash
# Compare the passes of a tuning sweep (baseline + one directory per profile).
# Reads each pass's suite TSV, finds columns by header name, averages the valid rows
# and shows each profile's change against the baseline, with each metric's n (valid
# samples / rows the pass attempted, PL17) and range, so a profile whose n differs from
# the baseline's (say 7 of 10 iterations timed out) is visible and flagged.
# Each pass's platform record (PLATFORM, the mesh operator, istiod and gateway proxy builds, the
# node provider, each member's Kubernetes version: tests/lib/platform.sh PLATFORM_PASS_KEYS; not
# istiod's settings, which a profile changes), its tuning levers and root Sidecar egress hosts, and
# each member's istiod limits and replica count where its TSVs record them (platform_lever_values)
# are compared with the baseline's (else the first pass with data's), member by member, in one
# "Platform record" row; its values follow the table once. A pass whose record differs (or cannot
# be compared), is not one value in its TSVs, changed during it, or was not compared at its end
# (its platform-drift.txt: what the read after its probes found changed or could not read again;
# none: that read did not run) warns: its change is then not the profile's alone, or not known to
# be. A lever, the egress hosts, a limit or the replica count that the pass's profile sets (its
# state/objects or state/patch.json) is shown, not warned, unless a member did not run the limit or
# count it sets (not in effect) or its TSVs do not record it on a member (unknown), or the profile
# turns istiod's autoscaling on in a suite that reads the count at the start only or not at all
# (unknown: its HPA sets the count): each of those warns (in the controlplane suite, a note when
# its counts read the same at the pass's end). Two more rows: each pass's istiod settings (one
# digest; a pass whose members differ, whose value changed during it or could not be read on a
# member, whose istiod pods ran different settings at once, or whose settings contradict its
# profile against the baseline's warns) and its tuning profile objects (the baseline must hold
# none, a profile pass all of its own on every member and no other: anything else warns).
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
# platform_report_values, platform_merge_by_context, platform_lever_values, platform_drift_changes,
# platform_drift_unread, platform_compare_values, platform_compare_members, platform_collapse,
# platform_value_against, platform_members_by_value, platform_short_digests,
# platform_tuning_objects_check
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/platform.sh"
# CAP_JQ_QTY (a profile's istiod limits in m and Mi, as cap_istiod_limits reads them)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/capacity.sh"

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
change to it. SETTLE_SEC (each pass's wait after its apply, before its probe) and, for
churn-dataplane, CHURN_RATE follow, as 003 recorded them (a sweep from before them prints
neither).
The markdown starts with a YAML frontmatter of the same keys (lowercase:
istio_generations, harness_sha, harness_content_key, report_harness_sha, settle_sec,
churn_rate, tsv_columns and the others).

The "Pass status" row reads ok, the marker the pass directory holds (SETUP_FAILED,
PROBE_FAILED or REVERT_FAILED), or "no data": a pass without TSVs (the metadata lists
it without its directory, or its probe wrote none).

The "Platform record" row compares each pass with the reference pass (the baseline,
else the first pass with data), member by member:
  - its platform, mesh builds and Kubernetes versions;
  - its tuning levers and root Sidecar egress hosts (TUNING_BASELINE, SIDECAR_EGRESS_HOSTS),
    read on the source member;
  - each member's istiod limits (ISTIOD_CPU_LIMIT_M_BY_CONTEXT in m,
    ISTIOD_MEM_LIMIT_MI_BY_CONTEXT in Mi), which only the controlplane suite's TSVs
    record: the source member's at the pass's start and end, the others' at its end only;
  - each member's istiod replica count at the pass's start (ISTIOD_REPLICAS_BY_CONTEXT):
    the controlplane and propagation suites record every member's, churn and
    churn-dataplane the source member's, dataplane none; the controlplane suite's are
    read again at its end.
A pass reads:
  same
  same (see notes)           only what its profile sets differs (a lever or the egress
                             hosts whose object its state/objects lists; discoverySelectors,
                             a limit or the replica count its state/patch.json sets), or the
                             reference pass ran more than one value and this pass one of
                             them, or (controlplane) its profile turns autoscaling on and
                             its replica counts read the same at its end
  differs (see notes)
  not in effect (see notes)  a member did not run the limit or replica count its
                             state/patch.json sets (not rolled out there, a limit or a
                             controlplane count that changed during the pass, a count its
                             TSVs disagree on or an HPA set, or a Terminating pod still
                             counted as Running after a short --settle: the other suites
                             count Running istiod pods)
  changed (see notes)        the read at its end found a build, a Kubernetes version, a
                             lever, a limit or (controlplane) a replica count changed during
                             it (its platform-drift.txt)
  mixed (see notes)          its TSVs disagree
  unknown (see notes)        a value not read or not recorded in one of them, a limit or
                             replica count its profile sets that its TSVs do not record on
                             a member, a replica count its profile's HPA sets (autoscaling
                             on) that its suite reads at the start only or not at all (all
                             but controlplane), or not compared at its end (not read again
                             then, or no platform-drift.txt: that read did not run)
  baseline, reference        the pass compared with; "(see notes)" after it when it changed,
                             its TSVs disagree, it was not compared at its end, or a member
                             did not run, or is not recorded with, what its profile sets (or
                             its profile's HPA, as above)
  -                          no data
A member that ran the value the reference pass started or ended with there matches it (that
change is the reference pass's warning), and an operator that differs only in its state is
the same build. Nothing records GOMAXPROCS (istiod's env takes it from limits.cpu, so its
digest does not show a CPU limit) or the Istio CR's other values (meshConfig but
discoverySelectors, global.proxy: istiod reloads them without a restart), so keep those fixed
during a sweep but for what the profiles change.

The "istiod env" row shows each pass's digest of istiod's settings (ISTIOD_ENV_BY_CONTEXT,
which a profile changes, so the record row leaves it out): "by member (see notes)" when its
members differ, "mixed (see notes)" when its TSVs or the read at its end disagree, "unknown
(see notes)" when no member's could be read, and "(see notes)" after it when a member's could
not be read, when a member's istiod pods ran different settings at once ("+"-joined: a
rollout caught midway), when it is the baseline's though the profile sets istiod's env, or
another though the profile patches nothing in the Istio CR (state/patch.json). The "Tuning
objects" row (TUNING_OBJECTS_BY_CONTEXT) reads none, own (all of its own profile's objects on
every member, its marker and its resources: state/objects, and no other), other (another
profile's, or any in the baseline: a profile left applied), missing (not all of its own:
undone during the pass or never applied there) or unknown. Each value followed by "(see
notes)" warns, but "same (see notes)", and "reference (see notes)" whose one note is its
profile's HPA (controlplane: the counts it started with held to its end); a pass without
data reads - in all three rows.

After the table: the reference pass's values, digests shortened to 12 hex digits; then for
each pass with notes, the members that differ, then those not read or not recorded on a side,
then those that ran more than one value (five at most, with a count), what changed during it,
what it could not compare at its end, what its profile sets and what it ran where the reference
pass ran more than one value.

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
suite setup, between passes, after the last revert); an incomplete revert, or such
an edit, which no revert undoes (they restore only the profiles' keys): a member's
Istio CR spec after the last revert differs from the sweep's start; or the
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
  TEST_PLATFORM       Checked only (auto, kubernetes or openshift; config/options.env): the
                      comparison reads the platform each pass recorded.
  PLATFORM_READ_TIMEOUT, PLATFORM_READ_PARALLEL
                      Checked only (config/options.env): the comparison reads no cluster.

Requires jq (it reads each profile pass's state/patch.json).
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
command -v jq >/dev/null 2>&1 || die "jq not found on PATH: it reads each profile pass's state/patch.json"

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
# pass_counts_per_member <pass>: return 0 when every TSV of the pass records the istiod replica
# count of each member of its record (ISTIOD_REPLICAS_BY_CONTEXT, as the controlplane suite writes
# it, listing every member its PLATFORM_BY_CONTEXT does): the counts the read at its end compares
# (platform_drift_check), which never compares a bare ISTIOD_REPLICAS or a member the key leaves
# out.
pass_counts_per_member() {
	local f n=0 cnt pair
	local -a pairs=()
	while IFS= read -r f; do
		[[ -n "$f" ]] || continue
		cnt="$(grep -m1 '^# ISTIOD_REPLICAS_BY_CONTEXT=' "$f" || true)"
		cnt="${cnt#*=}"
		[[ "${cnt%%,*}" == *=* ]] || return 1
		IFS=',' read -r -a pairs <<<"$(grep -m1 '^# PLATFORM_BY_CONTEXT=' "$f" | cut -d= -f2- || true)"
		for pair in ${pairs[@]+"${pairs[@]}"}; do
			[[ "$pair" != *=* || ",${cnt}," == *",${pair%%=*}="* ]] || return 1
		done
		n=$((n + 1))
	done < <(pass_tsvs "$1")
	((n > 0))
}

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

# One pass -> lines "n<TAB>valid<TAB>total", "w<TAB>columns<TAB>rows" (the data rows'
# column counts), "g<TAB>group<TAB>rows" (first-seen order; rows counts every row of the
# group, valid or not), "a<TAB>group<TAB>column<TAB>attempted" for a column taken once per
# cluster scrape (cluster_connected_proxies: its scrapes, valid or not) and
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
# pass -> its platform record (KEY=value lines: platform_report_values, then its members'
# Kubernetes versions and platform_lever_values), what the read at its end found changed during
# it ("KEY<TAB>noun<TAB>what" lines: platform_drift_changes; not istiod's settings or the tuning
# objects, which their rows show) and could not compare ("KEY<TAB>members":
# platform_drift_unread), and 1 when that read left no platform-drift.txt
declare -A PLAT DRIFT UNREAD NODRIFT
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
	# The rows below word each case for the pass, so the warnings the library prints for a sweep's
	# report are left out.
	PLAT[$p]="$(platform_report_values "${files[@]}" 2>/dev/null)"
	PLAT[$p]+=$'\n'"KUBE_VERSIONS=$(platform_merge_by_context KUBE_VERSIONS "${files[@]}" 2>/dev/null)"
	# Its tuning levers, root Sidecar egress hosts and, where its suite records them, each member's
	# istiod limits and replica count.
	levers="$(platform_lever_values "${files[@]}")"
	[[ -z "$levers" ]] || PLAT[$p]+=$'\n'"$levers"
	DRIFT[$p]="$(platform_drift_changes "${files[@]}" | awk -F'\t' '$1 != "ISTIOD_ENV_BY_CONTEXT" && $1 != "TUNING_OBJECTS_BY_CONTEXT"')"
	# What the read at its end could not compare; none of it without its drift file (that read did
	# not run: the run stopped during the pass, or predates it).
	UNREAD[$p]="$(platform_drift_unread "${files[@]}")"
	[[ -f "${RESULTS_DIR}/${p}/${PLATFORM_DRIFT_FILE}" ]] || NODRIFT[$p]=1
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
# plat_value <pass> <key>: that key's value in the pass's record.
plat_value() { sed -n "s/^${2}=//p" <<<"${PLAT[$1]:-}" | head -n 1; }
# plat_all_unknown <pass>: return 0 when every value of the pass's platform record is unknown (its
# TSVs predate the record, or nothing could be read: one note says so); its members' Kubernetes
# versions, which TSVs from before the record have too, and its levers, limits and replica
# counts are not part of it.
plat_all_unknown() {
	local kv
	while IFS= read -r kv; do
		[[ -z "$kv" || " ${PLATFORM_KEYS[*]} " != *" ${kv%%=*} "* || "$(platform_collapse "${kv#*=}")" == unknown ]] || return 1
	done <<<"${PLAT[$1]:-}"
	return 0
}
# ref_kv_unread: return 0 when the reference pass's Kubernetes versions were read on no member
# (unknown, or unreachable, on each).
ref_kv_unread() {
	local pair x v
	local -a pairs=() alts=()
	IFS=',' read -r -a pairs <<<"$(plat_value "$REF" KUBE_VERSIONS)"
	for pair in ${pairs[@]+"${pairs[@]}"}; do
		x="${pair#*=}"
		IFS=';' read -r -a alts <<<"${x#mixed:}"
		for v in ${alts[@]+"${alts[@]}"}; do
			[[ "$v" == unknown || "$v" == unreachable ]] || return 1
		done
	done
	return 0
}
# plat_text <key> <value> [members]: a value as the notes show it, digests shortened (the TSVs
# keep them in full): a lever list and the scalar values as they are (mixed:<a>;<b> as "mixed:
# <a> and <b>"); any other value, one that every member shares once, else each value with its
# members, five named (platform_members_by_value), as is one that lists fewer than [members]
# (its record's: the churn suites record istiod's replicas on their source member only).
plat_text() {
	local pair x out=""
	local -a pairs=()
	case "$1" in
	TUNING_BASELINE)
		IFS=',' read -r -a pairs <<<"$2"
		for pair in ${pairs[@]+"${pairs[@]}"}; do
			if [[ "$pair" == *=mixed:* ]]; then x="${pair#*=mixed:}"; pair="${pair%%=*}=mixed: ${x//;/ and }"; fi
			out+="${out:+,}${pair}"
		done
		printf '%s\n' "$out"
		;;
	PLATFORM | TEST_PLATFORM | SIDECAR_EGRESS_HOSTS)
		x="${2#mixed:}"
		if [[ "$2" == mixed:* ]]; then printf 'mixed: %s\n' "${x//,/ and }"; else printf '%s\n' "$2"; fi
		;;
	*)
		x="$(platform_collapse "$2")"
		IFS=',' read -r -a pairs <<<"$2"
		if [[ "$x" == *=* || "$x" == mixed:* ]] || ((${3:-0} > ${#pairs[@]})); then
			platform_members_by_value "$2"
		else
			platform_short_digests "$x"
		fi
		;;
	esac
}
# The platform record: one row, each pass against the reference pass (the baseline, else the
# first pass with data; platform_compare_values: an operator that differs only in its state is
# the same build), and the values once after the table (render). A pass that differs, or cannot
# be compared, warns in the output and on stderr (PL39), and so does one whose record changed
# during it (the read at its end, its platform-drift.txt: also its tuning levers and istiod
# limits), is not one value in its TSVs, or was not compared at its end, whatever it is compared
# with. Every key is compared member by member, so a member that changed or is not one value (on
# either side) matches when one of its values is the other side's: that pass's own warning covers
# the change, a member that ran a value the other side never ran still differs, and where the
# reference pass ran more than one value a pass's notes say which it ran (ref_alts). A lever, the
# egress hosts, a limit or the replica count that the pass's profile sets (profile_sets; and the
# reference pass's, without a baseline) is shown in its notes, not warned; a limit or a replica
# count it sets to one value (profile_fixed) that a member did not run is not in effect there,
# and warns.
REF=""
[[ -z "$BASE" || -z "${PLAT[$BASE]:-}" ]] || REF="$BASE"
if [[ -z "$REF" ]]; then
	for p in "${PASSES[@]}"; do
		[[ -z "${PLAT[$p]:-}" ]] || { REF="$p"; break; }
	done
fi
REF_NAME="baseline"
[[ "$REF" == "$BASE" ]] || REF_NAME="reference pass (${REF}, the first with data)"
# What a pass that differs from REF's record cannot claim (without a baseline, no change column).
REF_EFFECT="its change against the baseline is not the profile's alone"
[[ "$REF" == "$BASE" ]] || REF_EFFECT="its difference from the ${REF_NAME} is not the profiles' alone"
# pass_effect <pass>: what a pass whose record changed during it, or is not one value in its TSVs,
# cannot claim: REF_EFFECT, or for the reference pass what no pass compared with it can.
pass_effect() {
	if [[ "$1" != "$REF" ]]; then
		echo "$REF_EFFECT"
	elif [[ "$REF" == "$BASE" ]]; then
		echo "no profile's change against it is the profile's alone"
	else
		echo "no pass's difference from it is the profiles' alone"
	fi
}
# pass_unknown_effect <pass>: what is not known of a pass that was not compared at its end, nor
# then of any pass compared with the reference pass when that is the one.
pass_unknown_effect() {
	if [[ "$1" != "$REF" && "$REF" == "$BASE" ]]; then
		echo "whether its change against the baseline is the profile's alone"
	elif [[ "$1" != "$REF" ]]; then
		echo "whether its difference from the ${REF_NAME} is the profiles' alone"
	elif [[ "$REF" == "$BASE" ]]; then
		echo "whether any profile's change against it is the profile's alone"
	else
		echo "whether any pass's difference from it is the profiles' alone"
	fi
}
# The keys each pass is compared on: the record's (PLATFORM_PASS_KEYS) and platform_lever_values'.
LEVER_KEYS=(TUNING_BASELINE SIDECAR_EGRESS_HOSTS ISTIOD_CPU_LIMIT_M_BY_CONTEXT ISTIOD_MEM_LIMIT_MI_BY_CONTEXT
	ISTIOD_REPLICAS_BY_CONTEXT)
COMPARE_KEYS=("${PLATFORM_PASS_KEYS[@]}" "${LEVER_KEYS[@]}")
# lever_nouns <KEY[ (what)], ...>: what those lever keys are, in words ("tuning levers and istiod
# limits").
lever_nouns() {
	local k n s="" out i
	local -a ns=()
	for k in "${LEVER_KEYS[@]}"; do
		[[ ", ${1}" == *", ${k}"* ]] || continue
		case "$k" in
		TUNING_BASELINE) n="tuning levers" ;;
		SIDECAR_EGRESS_HOSTS) n="root Sidecar egress hosts" ;;
		ISTIOD_REPLICAS_BY_CONTEXT) n="istiod replica counts" ;;
		*) n="istiod limits" ;;
		esac
		[[ "|${s}|" == *"|${n}|"* ]] || { s+="${s:+|}${n}"; ns+=("$n"); }
	done
	out="${ns[0]-}"
	for ((i = 1; i < ${#ns[@]}; i++)); do
		if ((i == ${#ns[@]} - 1)); then out+=" and ${ns[i]}"; else out+=", ${ns[i]}"; fi
	done
	printf '%s\n' "$out"
}
# profile_sets <pass> [whose]: what its profile sets on purpose among the compared values, "<lever
# or key><TAB>what sets it" lines ("<whose> state/...", "its" by default): a lever, or the root
# Sidecar's egress hosts, whose object its state/objects lists (001 creates one only where the
# charts have none, so the lever reads off without it), discoverySelectors, an istiod limit or
# istiod's replica count (replicaCount, or autoscaling) that its state/patch.json sets (a JSON
# merge patch on the Istio CR: the path, or a value above it that is not an object, which
# replaces it; every such path of a key on its line). Nothing for the baseline, without its
# state, or for a patch.json that does not parse (then each such value is compared).
profile_sets() {
	local st="${RESULTS_DIR}/${1}/state" o who="${2:-its}"
	[[ "$1" != "$BASE" ]] || return 0
	if [[ -s "${st}/objects" ]]; then
		while IFS= read -r o; do
			case "$o" in
			Sidecar/istio-system/default) printf '%s\t%s state/objects lists %s\n' sidecar "$who" "$o" SIDECAR_EGRESS_HOSTS "$who" "$o" ;;
			Telemetry/istio-system/tuning-metrics) printf 'telemetryFiltering\t%s state/objects lists %s\n' "$who" "$o" ;;
			Telemetry/istio-system/tuning-access-log) printf 'accessLogFiltering\t%s state/objects lists %s\n' "$who" "$o" ;;
			esac
		done <"${st}/objects"
	fi
	[[ -s "${st}/patch.json" ]] || return 0
	# shellcheck disable=SC2016  # jq program: $d, $i, $p, $up and $doc are jq variables
	jq -r --arg who "$who" '
		def sets($p): . as $d | first(range(1; ($p | length) + 1) as $i
			| ($d | getpath($p[0:$i - 1])) as $up
			| if ($up | type) != "object" then false
			  elif ($up | has($p[$i - 1]) | not) then false
			  elif $i == ($p | length) or ($up[$p[$i - 1]] | type) != "object" then true
			  else empty end);
		. as $doc
		| [(["discoverySelectors", "spec.values.meshConfig.discoverySelectors"],
		    ["ISTIOD_CPU_LIMIT_M_BY_CONTEXT", "spec.values.pilot.resources.limits.cpu"],
		    ["ISTIOD_MEM_LIMIT_MI_BY_CONTEXT", "spec.values.pilot.resources.limits.memory"],
		    ["ISTIOD_REPLICAS_BY_CONTEXT", "spec.values.pilot.replicaCount"],
		    ["ISTIOD_REPLICAS_BY_CONTEXT", "spec.values.pilot.autoscaleEnabled"],
		    ["ISTIOD_REPLICAS_BY_CONTEXT", "spec.values.pilot.autoscaleMin"],
		    ["ISTIOD_REPLICAS_BY_CONTEXT", "spec.values.pilot.autoscaleMax"])
		   | select(.[1] as $p | $doc | sets($p | split(".")))]
		| group_by(.[0])[]
		| "\(.[0][0])\t\($who) state/patch.json sets \(map(.[1]) | join(", "))"' "${st}/patch.json" 2>/dev/null || true
}
# profile_fixed <pass>: what its state/patch.json sets to one value among the compared values,
# "<key><TAB><value as its TSVs record it><TAB><path>" lines: istiod's CPU and memory limits (m
# and Mi, floored, as cap_istiod_limits reads them: CAP_JQ_QTY) and its replica count, unless the
# patch turns autoscaling on (its HPA then sets the count). Nothing for the baseline, without the
# patch, or for one that does not parse.
profile_fixed() {
	local patch="${RESULTS_DIR}/${1}/state/patch.json"
	[[ "$1" != "$BASE" && -s "$patch" ]] || return 0
	jq -r "${CAP_JQ_QTY}"'
		def at($p): try getpath($p) catch null;
		def qty: type == "string" or type == "number";
		(at(["spec", "values", "pilot", "resources", "limits", "cpu"]) | select(qty)
			| try (cpu_to_m(.) | floor | tostring) catch empty
			| "ISTIOD_CPU_LIMIT_M_BY_CONTEXT\t\(.)\tspec.values.pilot.resources.limits.cpu"),
		(at(["spec", "values", "pilot", "resources", "limits", "memory"]) | select(qty)
			| try (mem_to_mi(.) | floor | tostring) catch empty
			| "ISTIOD_MEM_LIMIT_MI_BY_CONTEXT\t\(.)\tspec.values.pilot.resources.limits.memory"),
		(select(at(["spec", "values", "pilot", "autoscaleEnabled"]) != true)
			| at(["spec", "values", "pilot", "replicaCount"])
			| select(type == "number" and . >= 0 and . == floor) | tostring
			| "ISTIOD_REPLICAS_BY_CONTEXT\t\(.)\tspec.values.pilot.replicaCount")' "$patch" 2>/dev/null || true
}
# profile_autoscales <pass>: return 0 when its state/patch.json turns istiod's autoscaling on (its
# HPA then sets the replica count).
profile_autoscales() {
	local patch="${RESULTS_DIR}/${1}/state/patch.json"
	[[ "$1" != "$BASE" && -s "$patch" ]] || return 1
	jq -e '(try .spec.values.pilot.autoscaleEnabled catch null) == true' "$patch" >/dev/null 2>&1
}
# not_in_effect <pass> <key> <value>: the pass's <key> pairs (a token without a member too) that
# hold a value read and not <value>, ","-joined: the members that did not run it all through the
# pass. Nothing when every member read ran it.
not_in_effect() {
	local pair x a hit=""
	local -a pairs=() alts=()
	IFS=',' read -r -a pairs <<<"$(plat_value "$1" "$2")"
	for pair in ${pairs[@]+"${pairs[@]}"}; do
		x="${pair#*=}"
		IFS=';' read -r -a alts <<<"${x#mixed:}"
		for a in ${alts[@]+"${alts[@]}"}; do
			[[ "$a" == unknown || "$a" == "$3" ]] || { hit+="${hit:+,}${pair}"; break; }
		done
	done
	printf '%s\n' "$hit"
}
# with_unit <pairs> <unit>: each value of <key> pairs (a token without a member too) with <unit>
# after it, each of a mixed: value's too, but unknown.
with_unit() {
	local pair x a v out=""
	local -a pairs=() alts=()
	IFS=',' read -r -a pairs <<<"$1"
	for pair in ${pairs[@]+"${pairs[@]}"}; do
		x="${pair#*=}" v=""
		IFS=';' read -r -a alts <<<"${x#mixed:}"
		for a in ${alts[@]+"${alts[@]}"}; do
			[[ "$a" == unknown ]] || a+="$2"
			v+="${v:+;}${a}"
		done
		[[ "$x" != mixed:* ]] || v="mixed:${v}"
		if [[ "$pair" == *=* ]]; then out+="${out:+,}${pair%%=*}=${v}"; else out+="${out:+,}${v}"; fi
	done
	printf '%s\n' "$out"
}
# unrecorded <pass> <key>: the members of the pass's record (PLATFORM_BY_CONTEXT) that its <key>
# does not list, ","-joined (the churn suites record istiod's replica count on the source member
# only).
unrecorded() {
	local pair out=""
	local -a pairs=()
	local -A have=()
	IFS=',' read -r -a pairs <<<"$(plat_value "$1" "$2")"
	for pair in ${pairs[@]+"${pairs[@]}"}; do [[ "$pair" != *=* ]] || have[${pair%%=*}]=1; done
	IFS=',' read -r -a pairs <<<"$(plat_value "$1" PLATFORM_BY_CONTEXT)"
	for pair in ${pairs[@]+"${pairs[@]}"}; do
		[[ "$pair" != *=* || -n "${have[${pair%%=*}]+x}" ]] || out+="${out:+,}${pair%%=*}"
	done
	printf '%s\n' "$out"
}
# unrecorded_why <key> [members]: why this suite's TSVs do not record <key> (a limit or the replica
# count), or with "members" do not record it on some members.
unrecorded_why() {
	if [[ -n "${2:-}" ]]; then
		case "${1}:${SUITE}" in
		ISTIOD_REPLICAS_BY_CONTEXT:churn | ISTIOD_REPLICAS_BY_CONTEXT:churn-dataplane) echo "the ${SUITE} suite's TSVs record the source member's only" ;;
		*) echo "its TSVs do not list them" ;;
		esac
	elif [[ "$1" == ISTIOD_REPLICAS_BY_CONTEXT && "$SUITE" == dataplane ]]; then
		echo "the dataplane suite's TSVs record none"
	elif [[ "$1" != ISTIOD_REPLICAS_BY_CONTEXT && "$SUITE" != controlplane ]]; then
		echo "only the controlplane suite's TSVs record istiod's limits"
	else
		echo "its TSVs predate the key"
	fi
}
# member_names <name,...>: those members, five named, then how many more.
member_names() {
	local n v=""
	local -a ns=()
	IFS=',' read -r -a ns <<<"$1"
	for n in ${ns[@]+"${ns[@]}"}; do v+="${v:+,}${n}=-"; done
	v="$(platform_members_by_value "$v")"
	printf '%s\n' "${v#- on }"
}
# key_result <pass> <key> <result> <sets>: a key's result against REF once what <sets>
# (profile_sets lines) says a profile sets is left out, "<result><TAB><what>": for
# TUNING_BASELINE, lever by lever (platform_compare_members), differs or unknown with the levers
# that do (a lever not read on a side is unknown, whatever sets it), else set with what sets each
# lever that differs; for another key, set with what sets it, unless it (or a member of it) was
# not read on a side: unknown; else <result>.
key_result() {
	local lever a b r why d="" u="" st=""
	if [[ "$2" == TUNING_BASELINE ]]; then
		while IFS=$'\t' read -r lever a b r; do
			[[ -n "$lever" ]] || continue
			why="$(awk -F'\t' -v k="$lever" '$1 == k { print $2; exit }' <<<"$4")"
			if [[ "$r" == unknown ]]; then
				u+="${u:+, }${lever}"
			elif [[ -n "$why" ]]; then
				st+="${st:+; }${lever}: ${why}"
			else
				d+="${d:+, }${lever}"
			fi
		done < <(platform_compare_members TUNING_BASELINE "$(plat_value "$REF" TUNING_BASELINE)" "$(plat_value "$1" TUNING_BASELINE)")
		if [[ -n "$d" ]]; then
			printf 'differs\t%s\n' "$d"
		elif [[ -n "$u" ]]; then
			printf 'unknown\t%s\n' "$u"
		elif [[ -n "$st" ]]; then
			printf 'set\t%s\n' "$st"
		else
			# Not one lever on a side (its TSVs record TUNING_BASELINE unknown, or not at all).
			printf '%s\t\n' "$3"
		fi
		return 0
	fi
	why="$(awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' <<<"$4")"
	if [[ -z "$why" || "$3" == unknown ]]; then
		printf '%s\t\n' "$3"
	elif [[ "$2" == *_BY_CONTEXT && $'\n'"$(platform_compare_members "$2" "$(plat_value "$REF" "$2")" "$(plat_value "$1" "$2")")"$'\n' == *$'\tunknown\n'* ]]; then
		printf 'unknown\t\n'
	else
		printf 'set\t%s\n' "$why"
	fi
}
# ref_two <key>: where the reference pass ran more than one value of <key> (mixed: it changed
# during that pass, or its TSVs disagree), two of them that differ (not one that was not read, nor
# the same build in another state): its members (levers, for TUNING_BASELINE) ","-joined, or "-"
# for a key without members (PLATFORM, TEST_PLATFORM, SIDECAR_EGRESS_HOSTS) or for a value
# without a member (counts from before the record), first; nothing when it ran one value only.
ref_two() {
	local k="$1" rv pair c x i j n=0 a b r
	local -a pairs=() alts=() order=()
	local -A cnt=() alt=() two=()
	rv="$(plat_value "$REF" "$k")"
	case "$k" in
	PLATFORM | TEST_PLATFORM | SIDECAR_EGRESS_HOSTS)
		[[ "$rv" == mixed:* ]] || return 0
		IFS=',' read -r -a alts <<<"${rv#mixed:}"
		for ((i = 0; i < ${#alts[@]}; i++)); do
			for ((j = i + 1; j < ${#alts[@]}; j++)); do
				if [[ "$(platform_compare_values "${k}=${alts[i]}" "${k}=${alts[j]}" "$k")" == "${k}"$'\t'differs ]]; then
					echo -
					return 0
				fi
			done
		done
		return 0
		;;
	esac
	IFS=',' read -r -a pairs <<<"$rv"
	x=""
	for pair in ${pairs[@]+"${pairs[@]}"}; do
		if [[ "$pair" != *=* && "$pair" == mixed:* && -z "$x" ]]; then
			# A value without a member (counts from before the record): two of its values differ.
			IFS=';' read -r -a alts <<<"${pair#mixed:}"
			for ((i = 0; i < ${#alts[@]}; i++)); do
				[[ -z "$x" ]] || break
				for ((j = i + 1; j < ${#alts[@]}; j++)); do
					if [[ "$(platform_compare_values "${k}=${alts[i]}" "${k}=${alts[j]}" "$k")" == "${k}"$'\t'differs ]]; then
						x=-
						break
					fi
				done
			done
		fi
		[[ "$pair" == *=mixed:* ]] || continue
		c="${pair%%=*}"
		IFS=';' read -r -a alts <<<"${pair#*=mixed:}"
		order+=("$c")
		cnt[$c]=${#alts[@]}
		((${#alts[@]} <= n)) || n=${#alts[@]}
		for i in "${!alts[@]}"; do alt["${c}|${i}"]="${alts[i]}"; done
	done
	# Each pair of its values in one comparison of every member concerned (hundreds of members).
	for ((i = 0; i < n; i++)); do
		for ((j = i + 1; j < n; j++)); do
			a="" b=""
			for c in ${order[@]+"${order[@]}"}; do
				[[ "${cnt[$c]}" -gt "$j" ]] || continue
				a+="${a:+,}${c}=${alt["${c}|${i}"]}"
				b+="${b:+,}${c}=${alt["${c}|${j}"]}"
			done
			[[ -n "$a" ]] || continue
			while IFS=$'\t' read -r c _ _ r; do [[ "$r" != differs ]] || two[$c]=1; done < <(platform_compare_members "$k" "$a" "$b")
		done
	done
	for c in ${order[@]+"${order[@]}"}; do [[ -z "${two[$c]+x}" ]] || x+="${x:+,}${c}"; done
	printf '%s\n' "$x"
}
# ref_alts <pass> <key>: where the reference pass ran more than one value (REF_MIX: ref_two) and
# this pass ran one of them, that value, as its notes show it: the whole value for a scalar key,
# the levers or members concerned for another (platform_members_by_value; a value without a
# member, counts from before the record, first). Nothing elsewhere, nor where this pass ran more
# than one value itself (its own note: its TSVs disagree, or it changed).
ref_alts() {
	local k="$2" rv pv pair rb="" out=""
	local -a pairs=()
	local -A mx=() miss=()
	rv="$(plat_value "$REF" "$k")"
	pv="$(plat_value "$1" "$k")"
	[[ -n "${REF_MIX[$k]:-}" && -n "$pv" ]] || return 0
	case "$k" in
	PLATFORM | TEST_PLATFORM | SIDECAR_EGRESS_HOSTS)
		[[ "$pv" == mixed:* || "$(platform_compare_values "${k}=${rv}" "${k}=${pv}" "$k")" != "${k}"$'\t'same ]] || plat_text "$k" "$pv"
		return 0
		;;
	esac
	IFS=',' read -r -a pairs <<<"${REF_MIX[$k]}"
	for pair in ${pairs[@]+"${pairs[@]}"}; do mx[$pair]=1; done
	while IFS=$'\t' read -r pair _; do [[ -z "$pair" ]] || miss[$pair]=1; done < <(platform_compare_members "$k" "$rv" "$pv")
	# The reference pass's value without a member (counts from before the record).
	IFS=',' read -r -a pairs <<<"$rv"
	for pair in ${pairs[@]+"${pairs[@]}"}; do [[ "$pair" == *=* || -n "$rb" ]] || rb="$pair"; done
	IFS=',' read -r -a pairs <<<"$pv"
	for pair in ${pairs[@]+"${pairs[@]}"}; do
		if [[ "$pair" != *=* ]]; then
			[[ -n "${mx[-]+x}" && -n "$rb" && "$pair" != mixed:* && "$pair" != unknown ]] || continue
			[[ "$(platform_compare_values "${k}=${rb}" "${k}=${pair}" "$k")" == "${k}"$'\t'same ]] || continue
			out="${pair}${out:+,}${out}"
			continue
		fi
		[[ "$pair" != *=mixed:* && -n "${mx[${pair%%=*}]+x}" && -z "${miss[${pair%%=*}]+x}" ]] || continue
		out+="${out:+,}${pair}"
	done
	[[ -n "$out" ]] || return 0
	if [[ "$k" == TUNING_BASELINE ]]; then plat_text "$k" "$out"; else platform_members_by_value "$out"; fi
}
# limits_end_only <pass> <key>: return 0 for an istiod limit key whose only members that cannot be
# compared with REF's are others than the pass's source member (the first of its record) that
# read unknown on a side: nothing but the read at a pass's end gives their limits, and the
# warning of that pass (no platform-drift.txt, or not read at its end) says so. A member that
# differs is not one of those (the pass's profile sets it, or the key differs).
limits_end_only() {
	local c a b r src any=0
	[[ "$2" == ISTIOD_*_LIMIT_*_BY_CONTEXT ]] || return 1
	src="$(plat_value "$1" PLATFORM_BY_CONTEXT)"
	src="${src%%=*}"
	while IFS=$'\t' read -r c a b r; do
		[[ -n "$c" && "$r" == unknown ]] || continue
		[[ "$c" != "$src" && "$a" != - && "$b" != - && ( "$a" == unknown || "$b" == unknown ) ]] || return 1
		any=1
	done < <(platform_compare_members "$2" "$(plat_value "$REF" "$2")" "$(plat_value "$1" "$2")")
	((any))
}
# pass -> the keys it differs on / cannot be compared on against REF's (PLAT_DIFF, PLAT_UNK; with
# the levers, for the warnings: PLAT_DTXT, PLAT_UTXT), what its profile sets that differs
# (PLAT_SET: "KEY<TAB>what sets it" lines), what it ran where REF ran more than one value
# (PLAT_OM: "KEY<TAB>value"), what its profile sets that a member did not run (PLAT_NE:
# "KEY<TAB>the profile's value<TAB>the members that did not") or that its TSVs do not record on a
# member (PLAT_NR: "KEY<TAB>the profile's value<TAB>where and why"), the keys that changed during it
# (PLAT_CHG: its DRIFT keys), that its TSVs disagree on (PLAT_MIX) and that the read at its end
# could not compare (PLAT_NC: its UNREAD keys), why its replica count is not known all through
# it when its profile's HPA sets the count (PLAT_AS), and a controlplane pass whose profile's HPA
# sets the count that its read at the end found unchanged (PLAT_ASN: 1)
declare -A PLAT_DIFF PLAT_UNK PLAT_DTXT PLAT_UTXT PLAT_SET PLAT_OM PLAT_NE PLAT_NR PLAT_CHG PLAT_MIX PLAT_NC PLAT_AS PLAT_ASN
PLAT_WARNINGS=()
# The record's own keys (TSVs from before it still record each member's Kubernetes version).
PLAT_KEYS_ALL=""
for k in "${PLATFORM_PASS_KEYS[@]}"; do [[ "$k" == KUBE_VERSIONS ]] || PLAT_KEYS_ALL+="${PLAT_KEYS_ALL:+, }${k}"; done
# The keys REF ran more than one value of, and where (ref_two, for ref_alts).
declare -A REF_MIX=()
if [[ -n "$REF" ]]; then
	for k in "${COMPARE_KEYS[@]}"; do
		[[ "$(plat_value "$REF" "$k")" == *mixed:* ]] || continue
		x="$(ref_two "$k")"
		[[ -z "$x" ]] || REF_MIX[$k]="$x"
	done
fi
for p in "${PASSES[@]}"; do
	[[ -n "${PLAT[$p]:-}" ]] || continue
	ck="" mk="" nk=""
	while IFS=$'\t' read -r k _; do [[ -z "$k" ]] || ck+="${ck:+, }${k}"; done <<<"${DRIFT[$p]:-}"
	for k in "${COMPARE_KEYS[@]}"; do
		# A key the read at its end found changed is not also mixed (istiod's limits as its TSVs
		# name them).
		x="$k"
		[[ "$k" != ISTIOD_*_LIMIT_*_BY_CONTEXT ]] || x="${k%_BY_CONTEXT}"
		[[ ", ${ck}, " != *", ${x}, "* ]] || continue
		v="$(plat_value "$p" "$k")"
		# Not one value: a member's (a lever's), or two without a member (counts from before the
		# record that disagree). A bare mixed:unknown alone is an input from before the key: not
		# known, as the legend says, not mixed.
		case "$k" in
		PLATFORM | TEST_PLATFORM | SIDECAR_EGRESS_HOSTS) [[ "$v" != mixed:* ]] || mk+="${mk:+, }${k}" ;;
		*) [[ ",${v}" != *"=mixed:"* && ! ",${v}" =~ ,mixed:[^,=]*\; ]] || mk+="${mk:+, }${k}" ;;
		esac
	done
	# The other members' istiod limits by what they are (the internal key names their read).
	while IFS=$'\t' read -r k _; do
		[[ "$k" != ISTIOD_LIMITS_DIFFER_BY_CONTEXT ]] || k="istiod's limits"
		[[ -z "$k" ]] || nk+="${nk:+, }${k}"
	done <<<"${UNREAD[$p]:-}"
	PLAT_CHG[$p]="$ck" PLAT_MIX[$p]="$mk" PLAT_NC[$p]="$nk"
done
NODRIFT_PASSES=()  # the passes without a platform-drift.txt: one warning names them all
# What that read compares (the controlplane suite's TSVs record each member's replica count).
NODRIFT_WHAT="builds, Kubernetes versions, tuning levers or istiod limits"
[[ "$SUITE" != controlplane ]] || NODRIFT_WHAT="builds, Kubernetes versions, tuning levers, istiod limits or replica counts"
NODRIFT_LIM=0 NODRIFT_AT=-1
cells=("Platform record")
for p in "${PASSES[@]}"; do
	if [[ -z "${PLAT[$p]:-}" ]]; then cells+=("-"); continue; fi
	while IFS=$'\t' read -r k noun what; do
		[[ -n "$k" ]] || continue
		if [[ "$k" == ISTIOD_REPLICAS_BY_CONTEXT ]] && profile_autoscales "$p"; then
			PLAT_WARNINGS+=("pass ${p}: ${k} changed during the pass (its ${PLATFORM_DRIFT_FILE}): ${what}; its profile turns autoscaling on (spec.values.pilot.autoscaleEnabled in its state/patch.json), so its HPA moved the count, and its figures may be over more than one istiod replica count")
			continue
		fi
		PLAT_WARNINGS+=("pass ${p}: ${k} changed during the pass (its ${PLATFORM_DRIFT_FILE}): ${what}, so part of it ran with other ${noun}, and $(pass_effect "$p")")
	done <<<"${DRIFT[$p]:-}"
	[[ -z "${PLAT_MIX[$p]:-}" ]] ||
		PLAT_WARNINGS+=("pass ${p}: its TSVs disagree on ${PLAT_MIX[$p]} (or one of them did not read or record a value; the values follow the table), so part of it may have run on another platform, build, Kubernetes version, tuning lever, istiod limit or istiod replica count, and then $(pass_effect "$p")")
	# Not compared at its end (a pass whose whole record is unknown has one note and one warning).
	if ! plat_all_unknown "$p"; then
		if [[ -n "${NODRIFT[$p]:-}" ]]; then
			# Its warning's place: the first such pass's.
			if ((NODRIFT_AT < 0)); then
				NODRIFT_AT=${#PLAT_WARNINGS[@]}
				PLAT_WARNINGS+=("")
			fi
			NODRIFT_PASSES+=("$p")
			[[ "$(plat_value "$p" ISTIOD_CPU_LIMIT_M_BY_CONTEXT)$(plat_value "$p" ISTIOD_MEM_LIMIT_MI_BY_CONTEXT)" != *,* ]] || NODRIFT_LIM=1
		elif [[ -n "${UNREAD[$p]:-}" ]]; then
			w="" wl=""
			while IFS=$'\t' read -r k who; do
				[[ -n "$k" ]] || continue
				if [[ "$k" == ISTIOD_LIMITS_DIFFER_BY_CONTEXT ]]; then
					wl="istiod's limits on ${who} (not read at its end, the only read of them)"
				else
					w+="${w:+; }${k} on ${who}"
				fi
			done <<<"${UNREAD[$p]}"
			[[ -z "$w" ]] || w+=" (not read at its start or end, or read with a digest @unknown: no pod had started)"
			[[ -z "$wl" ]] || w+="${w:+; }${wl}"
			PLAT_WARNINGS+=("pass ${p}: the read again at its end (its ${PLATFORM_DRIFT_FILE}) could not compare ${w}, so whether those values changed during the pass is not known, nor $(pass_unknown_effect "$p")")
		fi
	fi
	# A limit or replica count its profile sets that a member did not run, or that its TSVs do not
	# record on a member: not known there (without a baseline, the reference pass's own too: it is
	# a profile pass).
	ne="" nr=""
	while IFS=$'\t' read -r k x what; do
		[[ -n "$k" ]] || continue
		case "$k" in
		ISTIOD_CPU_LIMIT_M_BY_CONTEXT) noun="istiod's CPU limit" unit=m why="not rolled out there, or changed during it" ;;
		ISTIOD_MEM_LIMIT_MI_BY_CONTEXT) noun="istiod's memory limit" unit=Mi why="not rolled out there, or changed during it" ;;
		*)
			noun="istiod's replica count" unit="" why="not rolled out there, changed during it, or set by an HPA"
			# The other suites count Running istiod pods at the start only.
			[[ "$SUITE" == controlplane ]] ||
				why="not rolled out there, changed between its TSVs, set by an HPA, or a Terminating pod still counted as Running after a short --settle"
			;;
		esac
		if [[ -z "$(plat_value "$p" "$k")" ]]; then
			w="$(unrecorded_why "$k")"
			nr+="${nr:+$'\n'}${k}"$'\t'"${x}${unit}"$'\t'"not recorded (${w})"
			PLAT_WARNINGS+=("pass ${p}: its profile sets ${noun} to ${x}${unit} (${what} in its state/patch.json), which its TSVs do not record (${w}), so whether it was in effect on any member is not known, nor $(pass_unknown_effect "$p")")
			continue
		fi
		w="$(unrecorded "$p" "$k")"
		if [[ -n "$w" ]]; then
			w="$(member_names "$w")"
			c="$(unrecorded_why "$k" members)"
			nr+="${nr:+$'\n'}${k}"$'\t'"${x}${unit}"$'\t'"not recorded on ${w} (${c})"
			PLAT_WARNINGS+=("pass ${p}: its profile sets ${noun} to ${x}${unit} (${what} in its state/patch.json), which its TSVs do not record on ${w} (${c}), so whether it was in effect there is not known, nor $(pass_unknown_effect "$p")")
		fi
		hit="$(not_in_effect "$p" "$k" "$x")"
		[[ -n "$hit" ]] || continue
		w="$(platform_members_by_value "$(with_unit "$hit" "$unit")")"
		ne+="${ne:+$'\n'}${k}"$'\t'"${x}${unit}"$'\t'"${w}"
		PLAT_WARNINGS+=("pass ${p}: its profile sets ${noun} to ${x}${unit} (${what} in its state/patch.json), yet ${k} reads ${w}, so the profile's value was not in effect there all through the pass (${why}), and $(pass_effect "$p")")
	done < <(profile_fixed "$p")
	PLAT_NE[$p]="$ne" PLAT_NR[$p]="$nr"
	# A profile that turns istiod's autoscaling on: its HPA sets each member's count, which the
	# other suites read at the probe's start only, or not at all (the controlplane suite's read at
	# a pass's end compares it: a count the HPA moved by then reads changed, and one it found
	# unchanged has a note, since the HPA may have raised and lowered it in between).
	if [[ "$SUITE" != controlplane ]] && profile_autoscales "$p"; then
		case "$SUITE" in
		dataplane) w="the dataplane suite's TSVs record no count" ;;
		churn | churn-dataplane) w="the ${SUITE} suite's TSVs record the source member's count at the probe's start only" ;;
		*) w="the ${SUITE} suite's TSVs record each member's count at the probe's start only" ;;
		esac
		PLAT_AS[$p]="$w"
		PLAT_WARNINGS+=("pass ${p}: its profile turns istiod's autoscaling on (spec.values.pilot.autoscaleEnabled in its state/patch.json), so its HPA sets each member's istiod replica count, and ${w}, so whether that count held all through the pass is not known, nor $(pass_unknown_effect "$p")")
	elif profile_autoscales "$p" && pass_counts_per_member "$p" && [[ -z "${NODRIFT[$p]:-}" ]] &&
		[[ ", ${PLAT_CHG[$p]:-}, ${PLAT_NC[$p]:-}, " != *", ISTIOD_REPLICAS_BY_CONTEXT, "* ]]; then
		PLAT_ASN[$p]=1
	fi
	if [[ "$p" == "$REF" ]]; then
		if [[ "$REF" == "$BASE" ]]; then cell="baseline"; else cell="reference"; fi
		nd="${NODRIFT[$p]:-}" ru=""
		if plat_all_unknown "$p"; then
			# Every value of its record unknown: one note says so, and one warning, when another
			# pass is compared with it (whose own warning then names only what that leaves).
			nd="" ru=1
			for x in "${PASSES[@]}"; do
				[[ "$x" != "$p" && -n "${PLAT[$x]:-}" ]] || continue
				PLAT_WARNINGS+=("pass ${p}: every value of its platform record is unknown (its TSVs predate the record, or nothing could be read)$(! ref_kv_unread || echo ", and so are its Kubernetes versions"), so whether the other passes ran on its platform and builds is not known, nor $(pass_unknown_effect "$p")")
				break
			done
		fi
		[[ -z "${PLAT_CHG[$p]:-}${PLAT_MIX[$p]:-}${PLAT_NC[$p]:-}${PLAT_AS[$p]:-}${PLAT_ASN[$p]:-}${nd}${ne}${nr}${ru}" ]] || cell+=" (see notes)"
		cells+=("$cell")
		continue
	fi
	# What its profile sets on purpose, and without a baseline the reference pass's.
	sets="$(profile_sets "$p")"
	[[ "$REF" == "$BASE" ]] || sets+="${sets:+$'\n'}$(profile_sets "$REF" "the reference pass's")"
	dk="" uk="" dt="" ut="" st="" ur="" urt="" ul="" om=""
	while IFS=$'\t' read -r k res; do
		# A lever, limit or replica count neither pass's TSVs record (only the controlplane suite's
		# record the limits) is not compared.
		[[ " ${LEVER_KEYS[*]} " != *" ${k} "* || -n "$(plat_value "$REF" "$k")$(plat_value "$p" "$k")" ]] || continue
		what=""
		[[ "$res" == same ]] || IFS=$'\t' read -r res what < <(key_result "$p" "$k" "$res" "$sets")
		case "$res" in
		differs)
			dk+="${dk:+, }${k}"
			dt+="${dt:+, }${k}${what:+ (${what})}"
			;;
		unknown)
			uk+="${uk:+, }${k}"
			ut+="${ut:+, }${k}${what:+ (${what})}"
			if [[ " ${PLATFORM_PASS_KEYS[*]} " == *" ${k} "* ]]; then
				urt+="${urt:+, }${k}"
				[[ "$k" == KUBE_VERSIONS ]] || ur+="${ur:+, }${k}"
			elif ! limits_end_only "$p" "$k"; then
				ul+="${ul:+, }${k}${what:+ (${what})}"
			fi
			;;
		set)
			st+="${st:+$'\n'}${k}"$'\t'"${what}"
			continue
			;;
		esac
		# Where the reference pass ran more than one value: which this pass ran.
		[[ -n "${REF_MIX[$k]+x}" ]] || continue
		x="$(ref_alts "$p" "$k")"
		[[ -z "$x" ]] || om+="${om:+$'\n'}${k}"$'\t'"${x}"
	done < <(platform_compare_values "${PLAT[$REF]}" "${PLAT[$p]}" "${COMPARE_KEYS[@]}")
	PLAT_DIFF[$p]="$dk" PLAT_UNK[$p]="$uk" PLAT_DTXT[$p]="$dt" PLAT_UTXT[$p]="$ut" PLAT_SET[$p]="$st" PLAT_OM[$p]="$om"
	if [[ -n "$dk" ]]; then
		cells+=("differs (see notes)")
		w=""
		[[ "$SUITE" == controlplane || ", ${dk}, " != *", ISTIOD_REPLICAS_BY_CONTEXT, "* ]] ||
			w="; the ${SUITE} suite counts Running istiod pods, which include a Terminating pod after a short --settle"
		PLAT_WARNINGS+=("pass ${p} differs from the ${REF_NAME} on ${dt} (its values follow the table${w}), so ${REF_EFFECT}")
	elif [[ -n "$ne" ]]; then
		cells+=("not in effect (see notes)")
	elif [[ -n "${PLAT_CHG[$p]:-}" ]]; then
		cells+=("changed (see notes)")
	elif [[ -n "${PLAT_MIX[$p]:-}" ]]; then
		cells+=("mixed (see notes)")
	elif [[ -n "${uk}${PLAT_NC[$p]:-}${NODRIFT[$p]:-}${nr}${PLAT_AS[$p]:-}" ]]; then
		cells+=("unknown (see notes)")
	elif [[ -n "${st}${om}${PLAT_ASN[$p]:-}" ]]; then
		cells+=("same (see notes)")
	else
		cells+=("same")
	fi
	# Not one key of the record proper could be compared: a pass from before the record, or a
	# reference pass from before it (whose own warning says so: then only this pass's Kubernetes
	# versions, when the reference pass's were read).
	if [[ -n "$ur" && "$ur" == "$PLAT_KEYS_ALL" ]] && plat_all_unknown "$REF" && ! plat_all_unknown "$p"; then
		[[ "$urt" == "$ur" ]] || ref_kv_unread ||
			PLAT_WARNINGS+=("pass ${p}: KUBE_VERSIONS could not be compared with the ${REF_NAME} (not read, or not recorded, in one of them), so whether it ran on the same Kubernetes versions is not known")
	elif [[ -n "$ur" && "$ur" == "$PLAT_KEYS_ALL" ]]; then
		PLAT_WARNINGS+=("pass ${p}: no key of its platform record can be compared with the ${REF_NAME} (its TSVs predate the record, or nothing could be read)$([[ "$urt" == "$ur" ]] || echo ", nor its Kubernetes versions"), so whether it ran on the same platform and builds is not known")
	elif [[ -n "$urt" ]]; then
		PLAT_WARNINGS+=("pass ${p}: ${urt} could not be compared with the ${REF_NAME} (not read, or not recorded, in one of them), so whether it ran on the same platform, builds and Kubernetes versions is not known")
	fi
	[[ -z "$ul" ]] ||
		PLAT_WARNINGS+=("pass ${p}: ${ul} could not be compared with the ${REF_NAME} (not read, or not recorded, in one of them), so whether it ran with the same $(lever_nouns "$ul") is not known")
done
row "${cells[@]}"
# The passes not read again at their end, in one warning.
if ((${#NODRIFT_PASSES[@]} == 1)); then
	p="${NODRIFT_PASSES[0]}"
	PLAT_WARNINGS[NODRIFT_AT]="pass ${p}: its record was not read again at its end (no ${PLATFORM_DRIFT_FILE} in its directory: the run stopped during the pass, or it predates that read), so whether its ${NODRIFT_WHAT} changed during it is not known$( ((NODRIFT_LIM == 0)) || echo ", nor its other members' istiod limits, which only that read gives"), nor $(pass_unknown_effect "$p")"
elif ((${#NODRIFT_PASSES[@]})); then
	w="${NODRIFT_PASSES[*]}"
	if [[ " ${w} " == *" ${REF} "* && "$REF" == "$BASE" ]]; then
		x="whether any profile's change against the baseline is the profile's alone"
	elif [[ " ${w} " == *" ${REF} "* ]]; then
		x="whether any pass's difference from the ${REF_NAME} is the profiles' alone"
	elif [[ "$REF" == "$BASE" ]]; then
		x="whether their changes against the baseline are their profiles' alone"
	else
		x="whether their differences from the ${REF_NAME} are the profiles' alone"
	fi
	PLAT_WARNINGS[NODRIFT_AT]="passes ${w// /, }: their records were not read again at their end (no ${PLATFORM_DRIFT_FILE} in their directories: the runs stopped during them, or they predate that read), so whether their ${NODRIFT_WHAT} changed during them is not known$( ((NODRIFT_LIM == 0)) || echo ", nor their other members' istiod limits, which only that read gives"), nor ${x}"
fi
# Each pass's istiod settings (ISTIOD_ENV_BY_CONTEXT, which a profile changes on purpose): one
# digest, so the table shows that a profile reached istiod and a re-run's pass can be matched to
# this one's. A pass whose members ran different settings, or whose TSVs (or the read again at its
# end: tuning 003's platform_drift_check) disagree, warns: the profile may have reached some of
# them, or part of the pass, only; so do one whose settings could not be read on a member (not
# known, never other settings), one whose istiod pods ran different settings at once (a rollout
# caught midway), and a profile pass whose settings contradict its profile against the
# baseline's (env_against_base). And its tuning profile objects (platform_tuning_objects_check):
# a profile pass measures with its own, every one on every member (its marker, which 001 puts there
# before any change, and its resources: the pass's state/objects); another profile's, or any in the
# baseline, are a profile left applied (a run stopped before its revert, or objects applied by
# hand), and one of its own missing is a profile undone during the pass or never applied there, so
# the pass did not measure what its name says.
declare -A ENV_NOTE ENVB_NOTE OBJ_NOTE  # pass -> its notes after the table
BASE_ENV=""
[[ -z "$BASE" || -z "${PLAT[$BASE]:-}" ]] || BASE_ENV="$(plat_value "$BASE" ISTIOD_ENV_BY_CONTEXT)"
# env_against_base <pass>: the members whose istiod settings contradict the pass's profile, as
# "<same|other>\t<their ISTIOD_ENV_BY_CONTEXT pairs>": its state/patch.json (001-apply-profile.sh
# writes it) sets spec.values.pilot.env, yet a value they were read with (or one of its istiod
# pods' digests, "+"-joined) is their baseline's (same: the profile's env was not in effect there),
# or it patches nothing in the Istio CR, yet one is not (other: something else changed them; each
# side compared pod by pod). Nothing when none does, for a profile that patches
# other Istio CR values only (some of them reach istiod's env too), for the baseline, without
# one, or when no member was read on both sides. Return 2 when there is something to compare but
# the patch is not there or does not parse.
env_against_base() {
	local patch="${RESULTS_DIR}/${1}/state/patch.json" sets="" pair c x b d hit=""
	local -a pairs=() parts=()
	local -A base=()
	[[ -n "$BASE_ENV" && "$1" != "$BASE" ]] || return 0
	IFS=',' read -r -a pairs <<<"$BASE_ENV"
	for pair in ${pairs[@]+"${pairs[@]}"}; do
		# Each value's digests one by one ("+"-joined when a member's istiod pods differ: a rollout).
		[[ "$pair" != *=* ]] || { x="${pair#*=}"; x="${x#mixed:}"; base[${pair%%=*}]=";${x//+/;};"; }
	done
	IFS=',' read -r -a pairs <<<"$(plat_value "$1" ISTIOD_ENV_BY_CONTEXT)"
	for pair in ${pairs[@]+"${pairs[@]}"}; do
		[[ "$pair" == *=* ]] || continue
		c="${pair%%=*}" x="${pair#*=}"
		b="${base[$c]:-}"
		[[ -n "$b" && "$b" != ";unknown;" ]] || continue
		IFS=';' read -r -a parts <<<"${x#mixed:}"
		for x in ${parts[@]+"${parts[@]}"}; do
			[[ "$x" != unknown ]] || continue
			if [[ -z "$sets" ]]; then
				# A member has values on both sides: what the profile patches decides.
				[[ -f "$patch" ]] || return 2
				sets="$(jq -r 'if ((.spec.values.pilot.env // {}) | length) > 0 then "env" elif . == {} then "none" else "values" end' "$patch" 2>/dev/null)" || return 2
				case "$sets" in
				env | none) ;;
				values) return 0 ;;
				*) return 2 ;;
				esac
			fi
			# One istiod pod on the baseline's settings is enough for same, one on others for other.
			for d in ${x//+/ }; do
				if [[ "$sets" == env && "$b" == *";${d};"* ]] || [[ "$sets" == none && "$b" != *";${d};"* ]]; then
					hit+="${hit:+,}${pair}"
					break 2
				fi
			done
		done
	done
	[[ -n "$hit" ]] || return 0
	printf '%s\t%s\n' "$([[ "$sets" == env ]] && echo same || echo other)" "$hit"
}
UNREC=()  # passes whose TSVs predate TUNING_OBJECTS_BY_CONTEXT: one warning names them all
cells=("istiod env")
cells_o=("Tuning objects")
for p in "${PASSES[@]}"; do
	if [[ -z "${PLAT[$p]:-}" ]]; then
		cells+=("-")
		cells_o+=("-")
		continue
	fi
	v="$(plat_value "$p" ISTIOD_ENV_BY_CONTEXT)"
	# The members its settings were read on: one recorded unknown (its istiod pods not listed in
	# time) did not run other settings, nor did an input without the key (a token without a
	# member); a member whose istiod pods ran different settings at once reads "+"-joined.
	known="" unread="" bare="" plus=""
	IFS=',' read -r -a pairs <<<"${v:-unknown}"
	for pair in ${pairs[@]+"${pairs[@]}"}; do
		case "$pair" in
		*=unknown) unread+="${unread:+,}${pair}" ;;
		*=*) known+="${known:+,}${pair}" ;;
		*) bare=1 ;;
		esac
		[[ "$pair" != *=*+* ]] || plus+="${plus:+,}${pair}"
	done
	c="$(platform_collapse "${known:-unknown}")"
	if [[ -z "$known" ]]; then
		cell="unknown"
	elif [[ ",${known}" == *"=mixed:"* ]]; then
		cell="mixed (see notes)"
		ENV_NOTE[$p]="$(platform_members_by_value "$v")"
		PLAT_WARNINGS+=("pass ${p}: istiod's settings were not one value all through the pass (ISTIOD_ENV_BY_CONTEXT: $(platform_members_by_value "$known")): its TSVs disagree or one could not read them, or the read at its end found them changed (an Argo CD sync, a hand edit, a profile applied or reverted during it), so part of it may have run other settings")
	elif [[ "$c" == *=* ]]; then
		cell="by member (see notes)"
		ENV_NOTE[$p]="$(platform_members_by_value "$v")"
		PLAT_WARNINGS+=("pass ${p}: istiod's settings differ between its members (ISTIOD_ENV_BY_CONTEXT: $(platform_members_by_value "$known")), so they did not all run the same configuration$([[ "$p" == "$BASE" ]] || echo "; the profile may have reached some of them only")")
	else
		cell="$(platform_short_digests "$c")"
	fi
	# Not read is not other settings: its own warning (a pass whose whole record is unknown has one).
	if [[ -n "${unread}${bare}" ]] && ! plat_all_unknown "$p"; then
		[[ "$cell" == *"(see notes)" ]] || cell+=" (see notes)"
		ENV_NOTE[$p]="$(platform_members_by_value "$v")"
		w=""
		if [[ -n "$unread" ]]; then
			w="$(platform_members_by_value "$unread")"
			w="could not be read on ${w#unknown on }"
		fi
		[[ -z "$bare" ]] || w+="${w:+, and }are not recorded in $([[ -n "${known}${unread}" ]] && echo "some of its TSVs" || echo "its TSVs") (they predate the key)"
		if [[ -n "$unread" && -n "$known" ]]; then
			w2="those members"
			[[ "$unread" == *,* ]] || w2="that member"
			if [[ "$p" == "$BASE" ]]; then x="whether ${w2} ran the same settings as the others"; else x="whether its profile reached ${w2}"; fi
		elif [[ "$p" == "$BASE" ]]; then
			x="which settings it ran"
		else
			x="whether its profile was in effect"
		fi
		# The members' values only: the TSVs without the key are said once, above.
		mv=""
		IFS=',' read -r -a mvp <<<"$v"
		for mvx in ${mvp[@]+"${mvp[@]}"}; do [[ "$mvx" != *=* ]] || mv+="${mv:+,}${mvx}"; done
		PLAT_WARNINGS+=("pass ${p}: istiod's settings ${w} (ISTIOD_ENV_BY_CONTEXT$([[ -z "$mv" ]] || echo ": $(platform_members_by_value "$mv")")), so ${x} is not known")
	fi
	if [[ -n "$plus" ]]; then
		[[ "$cell" == *"(see notes)" ]] || cell+=" (see notes)"
		[[ -n "${ENV_NOTE[$p]:-}" ]] || ENV_NOTE[$p]="$(platform_members_by_value "$v")"
		PLAT_WARNINGS+=("pass ${p}: istiod's pods ran different settings at once (ISTIOD_ENV_BY_CONTEXT: $(platform_members_by_value "$plus"), each pod's digest \"+\"-joined): a rollout caught midway (a short --settle), a pod stuck Terminating or a second istiod Deployment, so part of the pass may have run other settings")
	fi
	rc=0
	eb="$(env_against_base "$p")" || rc=$?
	if ((rc == 2)); then
		ENVB_NOTE[$p]="state/patch.json missing or unreadable: not checked against the baseline"
		PLAT_WARNINGS+=("pass ${p}: its state/patch.json (001-apply-profile.sh writes it in the pass's state dir) is not in the sweep directory or does not parse (jq reads it), so whether its profile's istiod settings were in effect is not checked against the baseline")
	elif [[ -n "$eb" ]]; then
		[[ "$cell" == *"(see notes)" ]] || cell+=" (see notes)"
		w="$(platform_members_by_value "${eb#*$'\t'}")"
		if [[ "${eb%%$'\t'*}" == same ]]; then
			ENVB_NOTE[$p]="the baseline's (${w}), though the profile sets spec.values.pilot.env"
			PLAT_WARNINGS+=("pass ${p}: istiod's settings are the baseline's (ISTIOD_ENV_BY_CONTEXT: ${w}), though its profile sets spec.values.pilot.env, so the profile's env was not in effect there all through the pass (an Argo CD sync or a hand edit put it back, or it never rolled out; or the profile sets the values istiod already had), and its change against the baseline is not the profile's")
		else
			ENVB_NOTE[$p]="not the baseline's (${w}), though the profile does not patch the Istio CR"
			PLAT_WARNINGS+=("pass ${p}: istiod's settings are not the baseline's (ISTIOD_ENV_BY_CONTEXT: ${w}), though its profile does not patch the Istio CR, so something else changed them (an Argo CD sync, a hand edit, another profile), and its change against the baseline is not the profile's alone")
		fi
	fi
	cells+=("$cell")
	prof="$p" exp=""
	[[ "$p" != "$BASE" ]] || prof=""
	# The objects the profile put on every member (its marker, then its resources), when 001 wrote
	# them down; else its marker alone.
	if [[ -n "$prof" && -s "${RESULTS_DIR}/${p}/state/objects" ]]; then
		while IFS= read -r o; do [[ -z "$o" ]] || exp+="${exp:++}${o}"; done <"${RESULTS_DIR}/${p}/state/objects"
	fi
	IFS=$'\t' read -r st who what < <(platform_tuning_objects_check "$(plat_value "$p" TUNING_OBJECTS_BY_CONTEXT)" "$prof" ${exp:+"$exp"})
	case "$st" in
	none | own) cells_o+=("$st") ;;
	other)
		cells_o+=("other (see notes)")
		if [[ "$p" == "$BASE" ]]; then
			OBJ_NOTE[$p]="a profile's objects on ${who}: ${what}"
			PLAT_WARNINGS+=("pass ${p} ran with a tuning profile's objects in place on ${who} (TUNING_OBJECTS_BY_CONTEXT: ${what}), so its figures are not those of the charts' configuration and no profile's change against it is the profile's alone; tests/tuning/005-cleanup.sh undoes them")
		else
			OBJ_NOTE[$p]="another profile's objects on ${who}: ${what}"
			w="$(pass_effect "$p")"
			PLAT_WARNINGS+=("pass ${p} ran with another tuning profile's objects in place on ${who} (TUNING_OBJECTS_BY_CONTEXT: ${what}), so it did not measure ${p} alone and ${w}; tests/tuning/005-cleanup.sh undoes them")
		fi
		;;
	missing)
		cells_o+=("missing (see notes)")
		OBJ_NOTE[$p]="its profile's ${what} not on ${who}"
		PLAT_WARNINGS+=("pass ${p}: its profile's objects (${what}) are not on ${who} in its record (TUNING_OBJECTS_BY_CONTEXT), so the profile was not in place there all through the pass: undone during it (002-revert-profile.sh, 005-cleanup.sh or a hand delete), never applied there, or its TSVs predate the profile markers; its figures are not the profile's")
		;;
	*)
		cells_o+=("unknown (see notes)")
		# A pass whose whole record is unknown has one note and one warning already.
		plat_all_unknown "$p" && continue
		OBJ_NOTE[$p]="${who}"
		if [[ "$who" == "are not recorded (the inputs predate the key)" ]]; then
			UNREC+=("$p")
			continue
		fi
		if [[ "$p" == "$BASE" ]]; then w="whether a profile's objects were in place"; else w="whether its profile's objects, and only those, were in place"; fi
		PLAT_WARNINGS+=("pass ${p}: its tuning profile objects (TUNING_OBJECTS_BY_CONTEXT) ${who}, so ${w} is not known")
		;;
	esac
done
if ((${#UNREC[@]} == 1)); then
	PLAT_WARNINGS+=("pass ${UNREC[0]}: its tuning profile objects (TUNING_OBJECTS_BY_CONTEXT) are not recorded (its TSVs predate the key), so whether it held only the objects its name says (none for the baseline) is not known")
elif ((${#UNREC[@]})); then
	w="${UNREC[*]}"
	PLAT_WARNINGS+=("passes ${w// /, }: their tuning profile objects (TUNING_OBJECTS_BY_CONTEXT) are not recorded (their TSVs predate the key), so whether each held only the objects its name says (none for the baseline) is not known")
fi
row "${cells[@]}"
row "${cells_o[@]}"
for w in ${PLAT_WARNINGS[@]+"${PLAT_WARNINGS[@]}"}; do echo "warning: ${w}" >&2; done
# plat_lines <pass> [keys CSV]: "KEY<TAB>value" of a pass's record, levers and limits
# (plat_text): every key (the reference pass's, after the table), or those keys; for another pass
# than the reference, a key that lists each member against REF's, only the members that do not
# match it (platform_value_against), so a record of hundreds of members stays one short line.
plat_lines() {
	local kv k ref v nm
	local -a pairs=()
	# Its record's members: a value that lists fewer names its members (plat_text).
	IFS=',' read -r -a pairs <<<"$(plat_value "$1" PLATFORM_BY_CONTEXT)"
	nm=${#pairs[@]}
	while IFS= read -r kv; do
		[[ -n "$kv" ]] || continue
		k="${kv%%=*}"
		[[ -z "${2:-}" || ", ${2}, " == *", ${k}, "* ]] || continue
		if [[ -n "${2:-}" && "$1" != "$REF" && ( "$k" == *_BY_CONTEXT || "$k" == KUBE_VERSIONS ) ]]; then
			ref="$(plat_value "$REF" "$k")"
			v="$(platform_value_against "$k" "${kv#*=}" "${ref:-unknown}")"
			IFS=',' read -r -a pairs <<<"${kv#*=}"
			[[ "$v" == *=* || "$v" == *" member"* ]] || ((${#pairs[@]} >= nm)) || v="$(platform_members_by_value "${kv#*=}")"
			printf '%s\t%s\n' "$k" "$(platform_short_digests "$v")"
		else
			printf '%s\t%s\n' "$k" "$(plat_text "$k" "${kv#*=}" "$nm")"
		fi
	done <<<"${PLAT[$1]:-}"
}
# drop_keys <list> <key>...: a ", "-joined list of keys (a key's item may add " (<what>)") without
# those keys.
drop_keys() {
	local t=", ${1}, " k
	shift
	for k in "$@"; do t="${t//, ${k}, /, }"; done
	t="${t#, }"
	printf '%s\n' "${t%, }"
}
# rec_unknown <pass>: return 0 for a pass with data whose every value of its platform record is
# unknown (plat_all_unknown): its notes say so in their heading and leave the record's keys out.
rec_unknown() { [[ -n "${PLAT[$1]:-}" ]] && plat_all_unknown "$1"; }
# plat_head <pass> [notes]: the heading of a pass's notes after the table (the keys it differs on,
# whose profile's value was not in effect or is not known to be, whose count its profile's HPA
# sets, that changed during it, that its TSVs disagree on, that cannot be compared, that the read
# at its end could not compare); for a pass whose every value of its platform record is unknown,
# that first, then only what is not its record (nor its Kubernetes versions, when they are not
# known either), or one sentence without [notes].
plat_head() {
	local k nek="" nrk="" ut="${PLAT_UTXT[$1]:-}" nc="${PLAT_NC[$1]:-}" nd="${NODRIFT[$1]:-}" hd="Pass ${1}"
	if rec_unknown "$1"; then
		if [[ -z "${2:-}" ]]; then
			echo "Pass ${1}: every value of its platform record is unknown (its TSVs predate the record, or nothing could be read)."
			return 0
		fi
		hd+=", every value of its platform record unknown (its TSVs predate the record, or nothing could be read)"
		ut="$(drop_keys "$ut" "${PLATFORM_KEYS[@]}" KUBE_VERSIONS)"
		nc="$(drop_keys "$nc" "${PLATFORM_KEYS[@]}")"
		nd=""
	fi
	while IFS=$'\t' read -r k _; do [[ -z "$k" ]] || nek+="${nek:+, }${k}"; done <<<"${PLAT_NE[$1]:-}"
	while IFS=$'\t' read -r k _; do [[ -z "$k" ]] || nrk+="${nrk:+, }${k}"; done <<<"${PLAT_NR[$1]:-}"
	echo "${hd}$([[ -z "${PLAT_DTXT[$1]:-}" ]] || echo ", differs on ${PLAT_DTXT[$1]}")$([[ -z "$nek" ]] || echo ", its profile's value not in effect on ${nek}")$([[ -z "$nrk" ]] || echo ", its profile's value not known to be in effect on ${nrk}")$([[ -z "${PLAT_AS[$1]:-}" ]] || echo ", not known all through the pass on ISTIOD_REPLICAS_BY_CONTEXT (set by its profile's HPA)")$([[ -z "${PLAT_CHG[$1]:-}" ]] || echo ", changed during the pass on ${PLAT_CHG[$1]}")$([[ -z "${PLAT_MIX[$1]:-}" ]] || echo ", its TSVs disagree on ${PLAT_MIX[$1]}")$([[ -z "$ut" ]] || echo ", cannot be compared on ${ut}")$([[ -z "$nc" ]] || echo ", not compared at its end on ${nc}")$([[ -z "$nd" ]] || echo ", not read again at its end"):"
}
# pass_heading <pass> <notes>: the line over a pass's notes after the table; return 1 for a pass
# without notes, unless every value of its platform record is unknown (one line says so).
pass_heading() {
	if rec_unknown "$1"; then
		plat_head "$1" "$2"
	elif [[ -z "$2" ]]; then
		return 1
	elif [[ -n "${PLAT_DIFF[$1]:-}${PLAT_NE[$1]:-}${PLAT_NR[$1]:-}${PLAT_AS[$1]:-}${PLAT_UNK[$1]:-}${PLAT_CHG[$1]:-}${PLAT_MIX[$1]:-}${PLAT_NC[$1]:-}${NODRIFT[$1]:-}" ]]; then
		plat_head "$1"
	else
		echo "Pass ${1}:"
	fi
}
# pass_notes <pass>: its notes after the table, "KEY<TAB>label<TAB>text<TAB>1 when the text is a
# value (markdown quotes it)": the keys it differs on, its TSVs disagree on and it cannot be
# compared on (plat_lines), what its profile sets that differs, what its profile sets that a
# member did not run or that its TSVs do not record on a member, the replica count its profile's
# HPA sets (PLAT_AS, PLAT_ASN), what it ran where the reference pass ran more than one value, what
# changed during it, what the read at its end could not compare, then its istiod settings and
# tuning objects; for a pass whose every value of its platform record is unknown, none of the
# record's keys, nor its Kubernetes versions when they cannot be compared either.
pass_notes() {
	local keys="${PLAT_DIFF[$1]:-}" unk="${PLAT_UNK[$1]:-}" k what who rec=""
	# Every value of its record unknown: its heading says so, so its notes leave those keys out,
	# and its Kubernetes versions when they are not known either (its warning says so).
	if rec_unknown "$1"; then
		rec=" ${PLATFORM_KEYS[*]} "
		unk="$(drop_keys "$unk" "${PLATFORM_KEYS[@]}" KUBE_VERSIONS)"
	fi
	[[ -z "${PLAT_MIX[$1]:-}" ]] || keys+="${keys:+, }${PLAT_MIX[$1]}"
	[[ -z "$unk" ]] || keys+="${keys:+, }${unk}"
	[[ -z "$keys" ]] || plat_lines "$1" "$keys" | awk -F'\t' '{ printf "%s\t\t%s\t1\n", $1, $2 }'
	while IFS=$'\t' read -r k what; do
		[[ -n "$k" ]] || continue
		# Whose profile (profile_sets: "its state/...", or the reference pass's without a baseline).
		case "$what" in
		*"the reference pass's state/"*"its state/"* | *"its state/"*"the reference pass's state/"*) who="its and the reference pass's profiles" ;;
		*"the reference pass's state/"*) who="the reference pass's profile" ;;
		*) who="its profile" ;;
		esac
		printf '%s\tset by %s (%s)\t%s\t1\n' "$k" "$who" "$what" "$(plat_lines "$1" "$k" | cut -f2-)"
	done <<<"${PLAT_SET[$1]:-}"
	while IFS=$'\t' read -r k what who; do
		[[ -z "$k" ]] || printf "%s\tthe profile's %s not in effect\t%s\t1\n" "$k" "$what" "$who"
	done <<<"${PLAT_NE[$1]:-}"
	while IFS=$'\t' read -r k what who; do
		[[ -z "$k" ]] || printf "%s\tthe profile's %s not known to be in effect\t%s\t\n" "$k" "$what" "$who"
	done <<<"${PLAT_NR[$1]:-}"
	[[ -z "${PLAT_AS[$1]:-}" ]] ||
		printf "ISTIOD_REPLICAS_BY_CONTEXT\tset by its profile's HPA (spec.values.pilot.autoscaleEnabled in its state/patch.json)\t%s, so whether that count held all through the pass is not known\t\n" "${PLAT_AS[$1]}"
	[[ -z "${PLAT_ASN[$1]:-}" ]] ||
		printf "ISTIOD_REPLICAS_BY_CONTEXT\tset by its profile's HPA (spec.values.pilot.autoscaleEnabled in its state/patch.json)\tthe read at the pass's end found each member's count it started with, but the HPA may have raised and lowered it in between; each cell's own count of istiod pods is in its istiod_pods_avg (tests/controlplane/004-report-results.sh --results-dir <the pass's directory> --format csv)\t\n"
	while IFS=$'\t' read -r k what; do
		[[ -z "$k" ]] || printf '%s\twhere the %s ran more than one value, one of those\t%s\t1\n' "$k" "$REF_NAME" "$what"
	done <<<"${PLAT_OM[$1]:-}"
	while IFS=$'\t' read -r k _ what; do
		[[ -z "$k" ]] || printf '%s\tchanged during the pass\t%s\t1\n' "$k" "$what"
	done <<<"${DRIFT[$1]:-}"
	while IFS=$'\t' read -r k what; do
		[[ -n "$k" && "$rec" != *" ${k} "* ]] || continue
		if [[ "$k" == ISTIOD_LIMITS_DIFFER_BY_CONTEXT ]]; then
			printf "istiod's limits\tnot read at its end\t%s\t\n" "$what"
		else
			printf '%s\tnot compared at its end\t%s\t\n' "$k" "$what"
		fi
	done <<<"${UNREAD[$1]:-}"
	[[ -z "${NODRIFT[$1]:-}" ]] || plat_all_unknown "$1" ||
		printf '%s\t\t%s\t\n' "$PLATFORM_DRIFT_FILE" "none in its directory: its record was not read again at its end"
	[[ -z "${ENV_NOTE[$1]:-}" ]] || printf 'ISTIOD_ENV_BY_CONTEXT\tby member\t%s\t1\n' "${ENV_NOTE[$1]}"
	[[ -z "${ENVB_NOTE[$1]:-}" ]] || printf 'ISTIOD_ENV_BY_CONTEXT\t\t%s\t\n' "${ENVB_NOTE[$1]}"
	[[ -z "${OBJ_NOTE[$1]:-}" ]] || printf 'TUNING_OBJECTS_BY_CONTEXT\t\t%s\t\n' "${OBJ_NOTE[$1]}"
	return 0
}
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
	[[ -z "$(meta_get SETTLE_SEC)" ]] || echo "settle_sec: $(yaml_str -n "$(meta_get SETTLE_SEC)")"
	[[ -z "$(meta_get CHURN_RATE)" ]] || echo "churn_rate: $(yaml_str -n "$(meta_get CHURN_RATE)")"
	echo "tsv_columns: $(yaml_str "$TSV_COLUMNS")"
	echo "---"
	echo ""
}

render() {
	local notes hd k kw=0
	# The text format's key column: as wide as the longest key it can show.
	for k in "${PLATFORM_KEYS[@]}" KUBE_VERSIONS "${LEVER_KEYS[@]}" "$PLATFORM_DRIFT_FILE"; do ((${#k} <= kw)) || kw=${#k}; done
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
		[[ -z "$(meta_get SETTLE_SEC)" ]] || echo "- SETTLE_SEC=$(meta_get SETTLE_SEC) (each pass's wait after its apply, before its probe)"
		[[ -z "$(meta_get CHURN_RATE)" ]] || echo "- CHURN_RATE=$(meta_get CHURN_RATE) (churn operations/s during each pass's probe)"
		echo "- Active revisions, Istio CR generations and proxy versions at the start: ISTIO_ACTIVE_REVISIONS=${ISTIO_ACTIVE_REVISIONS_M}; ISTIO_GENERATIONS=${ISTIO_GENERATIONS_M}; ISTIO_PROXY_VERSIONS=${ISTIO_PROXY_VERSIONS_M}"
		echo "- TSV columns: ${TSV_COLUMNS}"
		[[ -z "$WIDTH_WARNING" ]] || echo "- **Warning:** ${WIDTH_WARNING}"
		[[ -z "$HARNESS_WARNING" ]] || echo "- **Warning:** ${HARNESS_WARNING}"
		[[ -z "$HARNESS_NOTE" ]] || echo "- Note: ${HARNESS_NOTE}"
		if [[ "$SUITE" == propagation ]]; then
			echo "- Values are means over the samples the propagation report (005) counts: P1 once per iteration, left out only for a source-side reason (p1_status other than OK or DRAIN_TIMEOUT, a +Inf overflow, a source scrape skew over FANOUT_MAX_SKEW_MS; a remote that timed out or restarted keeps it), P2 and P3 per remote row, left out only for that remote's side (remote_status other than OK or DRAIN_TIMEOUT, its scrape skew over FANOUT_MAX_SKEW_MS; the source's restart, P1 timeout or overflow keeps them); \"(N overflowed)\" in the P1 local push cell counts the iterations its mean leaves out for a +Inf overflow. Profiles show the change against the baseline in brackets."
		else
			echo "- Values are means over valid rows (status OK, no istiod restart). Profiles show the change against the baseline in brackets."
			[[ "$SUITE" != controlplane ]] || echo "- \"Connected proxies / cluster\" is one value per cluster scrape (its n counts scrapes), none from a scrape with an istiod pod row that is not valid, as the controlplane report takes it."
		fi
		echo "- The \"Istio CR / IstioRevision generations\" row gives each pass's ISTIO_GENERATIONS from its own TSVs: a profile's apply and revert raise them, so each pass ran on its own (\"(every member)\" when every member has one value). The \"Harness (HARNESS_SHA)\" row gives the harness each pass's TSVs record."
		[[ "$SUITE" != propagation ]] || echo "- \"Drain timeouts (iterations, counted)\" (shown when a pass has one): iterations whose drain after the window timed out (DRAIN_TIMEOUT). Their values count, as in 005: they were measured before that drain."
		echo "- Under each metric: n is got/attempted (valid samples with a value / what the probe was configured to take where its TSV records it, else every row the pass wrote, failed and timed-out rows included) and range is its min to max."
		((N_DIFFERS)) && echo "- **A profile's n differs from the baseline's** (shown as \"(baseline n ...)\"): its mean is over other iterations, so a better mean can come from fewer, easier samples."
		echo "- Histogram p99 rows (\"worst bucket\") are never averaged: they show the highest bucket range a valid row hit, or \"overflow (N rows)\" when N rows had their p99 in the +Inf bucket (propagation's P1 convergence: \"overflow (N iterations)\" when N iterations put a sample in the +Inf bucket, whatever their p99; counted although 005 leaves those iterations out of its means)."
		for w in ${PLAT_WARNINGS[@]+"${PLAT_WARNINGS[@]}"}; do echo "- **Warning:** ${w}"; done
		echo ""
		sweep_outcome_recorded "$RESULTS_DIR" md "$(meta_get RUN_ID)"
		# Every cell through md_cell: a | in a pass name or a value would break the row.
		local hdr="| Metric |" sep="|---|" r c
		for p in "${PASSES[@]}"; do md_cell -v c "$p"; hdr+=" ${c} |"; sep+="---|"; done
		echo "$hdr"
		echo "$sep"
		for r in "${ROWS[@]}"; do md_cell -v r "$r"; echo "| ${r//$'\t'/ | } |"; done
		if [[ -n "$REF" ]]; then
			echo ""
			echo "### Platform record"
			echo ""
			echo "The record of the ${REF_NAME}, digests shortened to 12 hex digits (the TSVs keep them in full):"
			echo ""
			plat_lines "$REF" | awk -F'\t' '{ printf "- %s: `%s`\n", $1, $2 }'
			for p in "${PASSES[@]}"; do
				notes="$(pass_notes "$p")"
				hd="$(pass_heading "$p" "$notes")" || continue
				echo ""
				echo "$hd"
				[[ -n "$notes" ]] || continue
				echo ""
				awk -F'\t' '{ printf "- %s%s: %s\n", $1, ($2 == "" ? "" : ", " $2), ($4 == "1" ? "`" $3 "`" : $3) }' <<<"$notes"
			done
		fi
	else
		echo "Tuning sweep comparison (suite: ${SUITE})"
		[[ -z "$(meta_get ISTIO_VERSION)" ]] || echo "Istio: $(meta_get ISTIO_VERSION) (source $(meta_get ISTIO_VERSION_SOURCE), pin $(meta_get ISTIO_VERSION_PIN); by member $(meta_get ISTIO_VERSION_BY_CONTEXT))"
		[[ -z "$(meta_get ISTIO_VERSION)" ]] || echo "Start-of-run readiness: ISTIO_NOTREADY_AT_START=$(istio_start_kv ISTIO_NOTREADY_AT_START), ISTIO_READY_WAITED_SEC=$(istio_start_kv ISTIO_READY_WAITED_SEC)"
		echo "HARNESS_SHA=$(istio_start_kv HARNESS_SHA) (the sweep's)"
		echo "HARNESS_CONTENT_KEY=$(istio_start_kv HARNESS_CONTENT_KEY) (the sweep's harness files)"
		echo "REPORT_HARNESS_SHA=${REPORT_HARNESS_SHA} (this report's own)"
		[[ -z "$(meta_get SETTLE_SEC)" ]] || echo "SETTLE_SEC=$(meta_get SETTLE_SEC) (each pass's wait after its apply, before its probe)"
		[[ -z "$(meta_get CHURN_RATE)" ]] || echo "CHURN_RATE=$(meta_get CHURN_RATE) (churn operations/s during each pass's probe)"
		echo "Active revisions, Istio CR generations and proxy versions at the start: ISTIO_ACTIVE_REVISIONS=${ISTIO_ACTIVE_REVISIONS_M}; ISTIO_GENERATIONS=${ISTIO_GENERATIONS_M}; ISTIO_PROXY_VERSIONS=${ISTIO_PROXY_VERSIONS_M}"
		echo "TSV columns: ${TSV_COLUMNS}"
		[[ -z "$WIDTH_WARNING" ]] || echo "WARNING: ${WIDTH_WARNING}"
		[[ -z "$HARNESS_WARNING" ]] || echo "WARNING: ${HARNESS_WARNING}"
		[[ -z "$HARNESS_NOTE" ]] || echo "Note: ${HARNESS_NOTE}"
		echo "Means over valid rows; profiles show the change against the baseline."
		[[ "$SUITE" != controlplane ]] || echo "Connected proxies / cluster: one value per cluster scrape (n counts scrapes), none from a scrape with an istiod pod row that is not valid."
		echo "Istio CR / IstioRevision generations: each pass's own, from its TSVs (its apply and revert raise them)."
		echo "Harness (HARNESS_SHA): each pass's own, from its TSVs."
		[[ "$SUITE" != propagation ]] || echo "Drain timeouts (iterations, counted; shown when a pass has one): their drain after the window timed out (DRAIN_TIMEOUT); measured before it, so they count."
		echo "n = got/attempted (valid samples with a value / configured samples, else rows written); range = min to max."
		((N_DIFFERS)) && echo "WARNING: a profile's n differs from the baseline's (\"(baseline n ...)\"): its mean is over other iterations."
		echo "Histogram p99 rows show the worst bucket a valid row hit (or overflow), not a mean."
		[[ "$SUITE" != propagation ]] || echo "P1 is once per iteration, left out only for a source-side reason; P2 and P3 only for the remote's side; \"(N overflowed)\" counts the iterations its mean leaves out for a +Inf overflow."
		for w in ${PLAT_WARNINGS[@]+"${PLAT_WARNINGS[@]}"}; do echo "WARNING: ${w}"; done
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
		if [[ -n "$REF" ]]; then
			echo ""
			echo "Platform record of the ${REF_NAME}, digests shortened to 12 hex digits (the TSVs keep them in full):"
			plat_lines "$REF" | awk -F'\t' -v w="$kw" '{ printf "  %-" w "s %s\n", $1, $2 }'
			for p in "${PASSES[@]}"; do
				notes="$(pass_notes "$p")"
				hd="$(pass_heading "$p" "$notes")" || continue
				echo "$hd"
				[[ -n "$notes" ]] || continue
				awk -F'\t' -v w="$kw" '{ printf "  %-" w "s %s%s\n", $1, ($2 == "" ? "" : $2 ": "), $3 }' <<<"$notes"
			done
		fi
	fi
}

if [[ -n "$OUTPUT_FILE" ]]; then
	render >"$OUTPUT_FILE"
	echo "Comparison written to ${OUTPUT_FILE}" >&2
else
	render
fi

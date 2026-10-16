#!/usr/bin/env bash
# Generate summary statistics from churn convergence TSV files.
#
# Every format carries RUN_CONFIG / RUN_CONFIG_SHA256 (the --config behind the inputs),
# and HARNESS_SHA / ISTIO_VERSION (with ISTIO_VERSION_SOURCE, _PIN and _BY_CONTEXT) as
# 002 recorded them, over all input TSVs: mixed:a,b with a warning when they differ
# (PL26). More than one run under the results dir stops the report unless
# --allow-multi-run, and then every format says so (R3).
# Histogram p99 columns show the worst bucket a valid row hit, and "overflow (N rows)"
# when a row's p99 was in the +Inf bucket; they are never averaged.
#
# Usage:
#   ./tests/churn/004-report-results.sh [--results-dir DIR] [--allow-multi-run] [--format FMT]
#   ./tests/churn/004-report-results.sh --config tests/churn/configs/smoke.env \
#     --results-dir tests/churn/results/smoke/sweep-<RUN_ID> --format md
# ci-dry-run: --allow-multi-run
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # config_preload, config_report_value
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
config_preload churn "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/istiod-diag.sh"  # istiod_diag_report

RESULTS_DIR="$(config_repo_path "${CHURN_RESULTS_DIR}")"
FORMAT="text"
# --allow-multi-run: pool more than one run (else the report refuses, R3). Per invocation
# like --force-large-matrix, so no options.env key.
ALLOW_MULTI_RUN=0
DRY_RUN=0


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE      Run config of KEY=value lines (config/options.env keys; see
                     tests/churn/README.md, "Run config"). Precedence: flag >
                     --config > environment > default.
  --results-dir DIR  Results directory (default: ${CHURN_RESULTS_DIR}). Every
                     churn-*.tsv under it is read; a sweep-*/ dir from 003 is one run.
  --allow-multi-run  Pool more than one run (several sweep-* dirs, or standalone probes
                     with different run ids). Without it the report stops, lists the
                     runs and how to report each alone; with it every format says it
                     pools N runs and lists their HARNESS_SHA and ISTIO_VERSION values.
  --format FMT       Output format: text, csv, md (or markdown), charts (default: text).
  --dry-run          List the TSV files that would be read, then exit.
  -h, --help         Show this help.

Example (one sweep, as 003 runs it; from the repo root):
  tests/churn/$(basename "$0") --results-dir ${CHURN_RESULTS_DIR}/sweep-<RUN_ID> --format md

Row statuses (column 21): only OK rows feed the averages (n_valid); every row counts in
n_total.
  OK                  every measured column has a number
  TIMEOUT_LOCAL       the source watcher did not see the scale-up in --timeout
  TIMEOUT_REMOTE      a remote watcher did not see it in --timeout
  TIMEOUT_REMOTE_EDS  the remote EDS push never came (convergence_remote_eds_ms)
  POISONED_RESTART    an istiod restarted in the window (or its state is unknown)
  SCRAPE_INCOMPLETE   a per-pod istiod scrape failed, so the summed deltas undercount
  MISSING_VALUE       another measured column has no number (a watcher that did not
                      list every churn target, or a push counter in neither scrape)
  SETUP_FAILED        an iteration failed before it measured (002)
  PROBE_FAILED        the probe failed for the whole cell (003 placeholder)
A row an older 002 wrote as OK without a number in a measured column is counted as
TIMEOUT_REMOTE_EDS or MISSING_VALUE, with a warning on stderr.

text and md end with an "istiod restart diagnostics" section: the rows of every
istiod-diag-*/index.tsv under the results dir (what changed, the cause, the evidence
folder) and a tally by cause.

harness_sha and istio_version come from the TSV preambles (what 002 recorded), never
from this checkout: "unknown (not recorded)" for a TSV written before 002 recorded
them; inputs that differ read mixed:<value>,<value> with each distinct value once
(mixed:v1.30.5,v1.29.0, also when one run's own value was mixed:v1.30.5/v1.29.0).
istio_version is each member's active IstioRevision .spec.version as 002 read it
(istio_version_by_context: which member ran which).
When the results dir holds sweep-outcome.txt (003 writes it at the end of a sweep),
text, csv and md repeat it, with the run that recorded it: the failed cells by reason, its
problems (the Istio version or active revision changed under the sweep) and notes
(members not ready at its start or end); a sweep dir without it is a sweep that died
before its end.
Histogram p99 columns (queue time, push time) show the worst bucket any valid row
hit, or "overflow (N rows)" when N rows had their p99 above the highest finite bucket;
csv adds worst_bucket and n_overflow columns.

Environment:
  CHURN_RESULTS_DIR  --results-dir default (relative to the repo root).
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
		shift 2
		;;
	--allow-multi-run)
		ALLOW_MULTI_RUN=1
		shift
		;;
	--format)
		[[ -n "${2:-}" ]] || die "--format requires a value"
		FORMAT="$2"
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
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
text | csv | md | markdown | charts) ;;
*) die "unknown format: $FORMAT (use text, csv, md, or charts)" ;;
esac

if ((DRY_RUN)); then
	DRY_FILES=()
	[[ -d "$RESULTS_DIR" ]] && mapfile -t DRY_FILES < <(find "$RESULTS_DIR" -name 'churn-*.tsv' -type f | sort)
	# The same refusal as the report (R3): a dir with more than one run is not summarized.
	((${#DRY_FILES[@]} == 0)) || config_check_multi_run "$RESULTS_DIR" "$ALLOW_MULTI_RUN" "${DRY_FILES[@]}"
	echo "[dry-run] would summarize ${#DRY_FILES[@]} churn-*.tsv file(s) under $RESULTS_DIR as $FORMAT"
	exit 0
fi

[[ -d "$RESULTS_DIR" ]] || die "results directory not found: $RESULTS_DIR"

TSV_FILES=()
while IFS= read -r f; do
	TSV_FILES+=("$f")
done < <(find "$RESULTS_DIR" -name 'churn-*.tsv' -type f 2>/dev/null | sort)

if [[ ${#TSV_FILES[@]} -eq 0 ]]; then
	die "no TSV result files found in $RESULTS_DIR"
fi

# R3/PL6: the report pools every TSV under the results dir; more than one run stops it
# unless --allow-multi-run, and then every format says so (config_multi_run_note).
config_check_multi_run "$RESULTS_DIR" "$ALLOW_MULTI_RUN" "${TSV_FILES[@]}"
POOLED_NOTE="$(config_multi_run_note)"

# Every format reads the rows through churn_rows, which re-derives the status of a row
# an older 002 wrote as OK with no number in a measured column (before R12), so it
# cannot count in n_valid. 002's rule: with remotes (mesh size > 1), no number in
# convergence_remote_eds_ms is TIMEOUT_REMOTE_EDS; no number in convergence_local_ms,
# the source push deltas, or (with remotes) remote_endpoint_reachable_ms and the
# remote push deltas is MISSING_VALUE. Rows 002 writes today pass through unchanged.
# shellcheck disable=SC2016  # an awk program, not shell expansions
CHURN_ROWS_AWK='
function num(v) { return v ~ /^[0-9]+$/ }
!/^#/ && !/^run_id/ && NF >= 21 && $21 == "OK" {
	rem = ($2 + 0 > 1)
	if (rem && !num($10)) { $21 = "TIMEOUT_REMOTE_EDS"; fixed++ }
	else if (!num($8) || !num($11) || !num($13) || (rem && (!num($9) || !num($12) || !num($14)))) {
		$21 = "MISSING_VALUE"; fixed++
	}
}
count { next }
{ print }
END { if (count) print fixed + 0 }'
churn_rows() { awk -F'\t' -v OFS='\t' -v count=0 "$CHURN_ROWS_AWK" "${TSV_FILES[@]}"; }
_rederived="$(awk -F'\t' -v OFS='\t' -v count=1 "$CHURN_ROWS_AWK" "${TSV_FILES[@]}")"
if (( ${_rederived:-0} > 0 )); then
	echo "warning: ${_rederived} row(s) written as OK by an older 002 have no number in a measured column; counted as TIMEOUT_REMOTE_EDS or MISSING_VALUE (in n_total, not n_valid)" >&2
fi

# A `# KEY=value` preamble value (values queried live at sweep time, e.g.
# TUNING_BASELINE) over every input that has the line: one value, or mixed:a,b when they
# differ, never the first file's (PL26). "unknown" when no input has it.
preamble_get() {
	local v
	v="$(config_input_value "$1" "" "${TSV_FILES[@]}")"
	[[ -n "$v" ]] && echo "$v" || echo "unknown"
}

# run_meta <key>: a `# <key>=` value as 002 (or the 003 placeholder) recorded it, over
# every input TSV, never read from this checkout or environment: the report may run on
# another commit than the probe. A file without the line (written before 002 recorded
# the key) reads "unknown (not recorded)"; inputs that differ give mixed:a,b
# (config_input_value: each distinct value once, X13) plus a stderr warning (PL26).
run_meta() {
	local key="$1" f v n
	v="$(config_input_value "$key" "unknown (not recorded)" "${TSV_FILES[@]}")"
	[[ -n "$v" ]] || v="unknown (not recorded)"
	# How many inputs differ: one file's own mixed:a/b is not a disagreement, nor v1.30.5
	# against 1.30.5 (config_input_value reads them as one, Y11).
	n="$(for f in "${TSV_FILES[@]}"; do grep -m1 "^# ${key}=" "$f" 2>/dev/null || echo; done | sort -u | awk 'END { print NR }')"
	[[ "$v" != mixed:* ]] || ((n < 2)) || echo "warning: input TSVs disagree on ${key} (${v#mixed:}); the report mixes runs" >&2
	echo "$v"
}
HARNESS_SHA_M="$(run_meta HARNESS_SHA)"
ISTIO_VERSION_M="$(run_meta ISTIO_VERSION)"
# R4: where ISTIO_VERSION came from (live: each member's active IstioRevision; pin:
# config only), the configured pin and which member ran which (X4, PL19); files written
# before R4 read "unknown (not recorded)".
ISTIO_VERSION_SOURCE_M="$(run_meta ISTIO_VERSION_SOURCE)"
ISTIO_VERSION_PIN_M="$(run_meta ISTIO_VERSION_PIN)"
ISTIO_VERSION_BY_CONTEXT_M="$(run_meta ISTIO_VERSION_BY_CONTEXT)"
# R2: the members still not ready after the start's readiness wait, and how long it took.
ISTIO_NOTREADY_AT_START_M="$(run_meta ISTIO_NOTREADY_AT_START)"
ISTIO_READY_WAITED_SEC_M="$(run_meta ISTIO_READY_WAITED_SEC)"

# Which --config produced the inputs (PL2/PL19), over every input: `none` without one,
# `unknown` for files written before the key existed, mixed:a,b with a warning (PL26).
RUN_CONFIG_M="$(config_report_value RUN_CONFIG "${TSV_FILES[@]}")"
RUN_CONFIG_SHA256_M="$(config_report_value RUN_CONFIG_SHA256 "${TSV_FILES[@]}")"

# TSV schema (21 columns):
#  $1  run_id
#  $2  mesh_size
#  $3  churn_intensity
#  $4  base_replicas
#  $5  scale_to
#  $6  iteration
#  $7  t0_epoch_ns
#  $8  convergence_local_ms
#  $9  remote_endpoint_reachable_ms   (remote watcher sees a new Ready source pod per deployment)
#  $10 convergence_remote_eds_ms      (first remote EDS push after t0; control plane only)
#  $11 source_push_triggers_delta
#  $12 remote_push_triggers_delta
#  $13 source_xds_pushes_delta
#  $14 remote_xds_pushes_delta
#  $15 source_queue_time_p99_ms
#  $16 remote_queue_time_p99_ms
#  $17 source_connected_proxies
#  $18 remote_connected_proxies
#  $19 source_push_time_p99_ms
#  $20 remote_push_time_p99_ms
#  $21 status

report_text() {
	echo "=== Churn Convergence Results ==="
	echo ""
	[[ -z "$POOLED_NOTE" ]] || printf 'POOLED RUNS: %s\n\n' "$POOLED_NOTE"
	sweep_outcome_recorded "$RESULTS_DIR" text
	echo "# harness_sha (recorded by 002): ${HARNESS_SHA_M}"
	echo "# istio_version (recorded by 002): ${ISTIO_VERSION_M}  source: ${ISTIO_VERSION_SOURCE_M}  pin: ${ISTIO_VERSION_PIN_M}"
	echo "# istio_version_by_context: ${ISTIO_VERSION_BY_CONTEXT_M}"
	echo "# istio_notready_at_start: ${ISTIO_NOTREADY_AT_START_M}  istio_ready_waited_sec: ${ISTIO_READY_WAITED_SEC_M}"
	echo "# tuning_baseline (live mesh): $(preamble_get TUNING_BASELINE)"
	echo "# sidecar egress hosts (live): $(preamble_get SIDECAR_EGRESS_HOSTS)"
	echo "# run_config: ${RUN_CONFIG_M}  run_config_sha256: ${RUN_CONFIG_SHA256_M}"
	echo ""
	echo "Files: ${TSV_FILES[*]}"
	echo ""
	churn_rows | awk -F'\t' '
	# Only OK rows feed numeric aggregation; POISONED_*/TIMEOUT_*/SCRAPE_INCOMPLETE/MISSING_VALUE
	# rows carry N/A or undercounted istiod-side deltas and must NOT leak into
	# column means. Per-column "N/A"!= guards also stop "N/A"+0 -> 0 fabrication.
	!/^#/ && !/^run_id/ && NF>=21 && $21=="OK" {
		key = $2 "\t" $3 "\t" $4 "\t" $5
		seen[key] = 1
		if($8!="TIMEOUT" && $8!="N/A") { cl[key, ++cl_n[key]] = $8+0 }
		if($9!="TIMEOUT" && $9!="N/A") { cr[key, ++cr_n[key]] = $9+0 }
		if($10!="TIMEOUT" && $10!="N/A") { cre[key, ++cre_n[key]] = $10+0 }
		if($11!="N/A") { spt[key, ++spt_n[key]] = $11+0 }
		if($12!="N/A") { rpt[key, ++rpt_n[key]] = $12+0 }
		if($13!="N/A") { sxp[key, ++sxp_n[key]] = $13+0 }
		if($14!="N/A") { rxp[key, ++rxp_n[key]] = $14+0 }
		# Histogram p99s: an overflow (p99 in +Inf) is counted, not dropped.
		if($15=="overflow") sqq_ov[key]++; else if($15!="N/A") { sqq[key, ++sqq_n[key]] = $15+0 }
		if($16=="overflow") rqq_ov[key]++; else if($16!="N/A") { rqq[key, ++rqq_n[key]] = $16+0 }
		if($17!="N/A") { scp[key, ++scp_n[key]] = $17+0 }
		if($18!="N/A") { rcp[key, ++rcp_n[key]] = $18+0 }
		if($19=="overflow") spt2_ov[key]++; else if($19!="N/A") { spt2[key, ++spt2_n[key]] = $19+0 }
		if($20=="overflow") rpt2_ov[key]++; else if($20!="N/A") { rpt2[key, ++rpt2_n[key]] = $20+0 }
		if($11!="N/A" && $11+0 > 0 && $13!="N/A") { amp[key, ++amp_n[key]] = ($13+0 + ($14=="N/A" ? 0 : $14+0)) / $11 }
	}
	# Track totals/valids per cell so we can surface the filter rate.
	!/^#/ && !/^run_id/ && NF>=21 { tot_key = $2 "\t" $3 "\t" $4 "\t" $5; seen[tot_key]=1; n_total[tot_key]++; if($21=="OK") n_valid[tot_key]++ }
	function sort_vals(arr, key, n,    i, j, tmp) {
		for(i=2;i<=n;i++){tmp=arr[key,i];j=i-1;while(j>=1&&arr[key,j]>tmp){arr[key,j+1]=arr[key,j];j--}arr[key,j+1]=tmp}
	}
	function stats(arr, key, n,    i, sum) {
		if(n==0) return "N/A"
		sort_vals(arr, key, n)
		sum=0; for(i=1;i<=n;i++) sum+=arr[key,i]
		return sprintf("n=%d min=%.0f max=%.0f avg=%.0f", n, arr[key,1], arr[key,n], sum/n)
	}
	function stats_ratio(arr, key, n,    i, sum) {
		if(n==0) return "N/A"
		sort_vals(arr, key, n)
		sum=0; for(i=1;i<=n;i++) sum+=arr[key,i]
		return sprintf("n=%d min=%.1f max=%.1f avg=%.1f", n, arr[key,1], arr[key,n], sum/n)
	}
	function bucket_range(upper_ms) {
		if (upper_ms+0 <= 0)     return "N/A"
		if (upper_ms+0 <= 100)   return "0-100"
		if (upper_ms+0 <= 500)   return "100-500"
		if (upper_ms+0 <= 1000)  return "500-1000"
		if (upper_ms+0 <= 3000)  return "1000-3000"
		if (upper_ms+0 <= 5000)  return "3000-5000"
		if (upper_ms+0 <= 10000) return "5000-10000"
		if (upper_ms+0 <= 20000) return "10000-20000"
		if (upper_ms+0 <= 30000) return "20000-30000"
		return ">30000"
	}
	# Histogram p99s: the lowest and the worst (highest) bucket a valid row hit. No
	# average: the mean of interpolated p99s can fall in a bucket no row hit. ov rows
	# had their p99 in the +Inf bucket; then the worst is "overflow (<ov> rows)".
	function stats_hist(arr, key, n, ov,    lo, worst) {
		if(n+ov==0) return "N/A"
		if(n>0) sort_vals(arr, key, n)
		lo = (n>0) ? bucket_range(arr[key,1]) : "overflow"
		worst = (ov>0) ? sprintf("overflow (%d %s)", ov, ov==1 ? "row" : "rows") : bucket_range(arr[key,n])
		return sprintf("n=%d min=%s worst=%s", n+ov, lo, worst)
	}
	function sort_keys(    i, j, tmp, k) {
		n_keys = 0
		for (k in seen) sorted_keys[++n_keys] = k
		for (i = 2; i <= n_keys; i++) {
			tmp = sorted_keys[i]; j = i - 1
			while (j >= 1 && sorted_keys[j] > tmp) { sorted_keys[j+1] = sorted_keys[j]; j-- }
			sorted_keys[j+1] = tmp
		}
	}
	END {
		sort_keys()
		for(k=1; k<=n_keys; k++) {
			key = sorted_keys[k]
			split(key, p, "\t")
			printf "--- mesh_size=%s  churn_intensity=%s  scale=%s->%s ---\n", p[1], p[2], p[3], p[4]
			printf "  Rows (valid/total):            %d/%d\n", n_valid[key]+0, n_total[key]+0
			printf "  Local convergence (ms):        %s\n", stats(cl, key, cl_n[key])
			printf "  Remote endpoint reachable (ms): %s\n", stats(cr, key, cr_n[key])
			printf "  Remote EDS converged (ms):     %s\n", stats(cre, key, cre_n[key])
			printf "  Source push triggers:          %s\n", stats(spt, key, spt_n[key])
			printf "  Remote push triggers:          %s\n", stats(rpt, key, rpt_n[key])
			printf "  Source xDS pushes:             %s\n", stats(sxp, key, sxp_n[key])
			printf "  Remote xDS pushes:             %s\n", stats(rxp, key, rxp_n[key])
			printf "  Source queue time p99 (ms):    %s\n", stats_hist(sqq, key, sqq_n[key], sqq_ov[key]+0)
			printf "  Remote queue time p99 (ms):    %s\n", stats_hist(rqq, key, rqq_n[key], rqq_ov[key]+0)
			printf "  Source connected proxies:      %s\n", stats(scp, key, scp_n[key])
			printf "  Remote connected proxies:      %s\n", stats(rcp, key, rcp_n[key])
			printf "  Source push time p99 (ms):     %s\n", stats_hist(spt2, key, spt2_n[key], spt2_ov[key]+0)
			printf "  Remote push time p99 (ms):     %s\n", stats_hist(rpt2, key, rpt2_n[key], rpt2_ov[key]+0)
			printf "  Push amplification ratio:      %s\n", stats_ratio(amp, key, amp_n[key])
			printf "\n"
		}
	}'
	istiod_diag_report text "$RESULTS_DIR"
}

report_csv() {
	echo "# HARNESS_SHA=${HARNESS_SHA_M}"
	echo "# ISTIO_VERSION=${ISTIO_VERSION_M}"
	echo "# ISTIO_VERSION_SOURCE=${ISTIO_VERSION_SOURCE_M}"
	echo "# ISTIO_VERSION_PIN=${ISTIO_VERSION_PIN_M}"
	echo "# ISTIO_VERSION_BY_CONTEXT=${ISTIO_VERSION_BY_CONTEXT_M}"
	echo "# ISTIO_NOTREADY_AT_START=${ISTIO_NOTREADY_AT_START_M}"
	echo "# ISTIO_READY_WAITED_SEC=${ISTIO_READY_WAITED_SEC_M}"
	echo "# TUNING_BASELINE=$(preamble_get TUNING_BASELINE)"
	echo "# SIDECAR_EGRESS_HOSTS=$(preamble_get SIDECAR_EGRESS_HOSTS)"
	echo "# RUN_CONFIG=${RUN_CONFIG_M}"
	echo "# RUN_CONFIG_SHA256=${RUN_CONFIG_SHA256_M}"
	config_multi_run_csv
	sweep_outcome_recorded "$RESULTS_DIR" csv
	# worst_bucket / n_overflow: histogram p99 metrics only (the highest bucket a valid
	# row hit, "overflow" when a row's p99 was in +Inf; n counts the numeric rows).
	echo "mesh_size,churn_intensity,base_replicas,scale_to,metric,n,min,max,avg,worst_bucket,n_overflow"
	churn_rows | awk -F'\t' '
	# Only OK rows feed numeric aggregation (see report_text for rationale).
	!/^#/ && !/^run_id/ && NF>=21 && $21=="OK" {
		key = $2 "\t" $3 "\t" $4 "\t" $5
		seen[key] = 1
		if($8!="TIMEOUT" && $8!="N/A") { cl[key, ++cl_n[key]] = $8+0 }
		if($9!="TIMEOUT" && $9!="N/A") { cr[key, ++cr_n[key]] = $9+0 }
		if($10!="TIMEOUT" && $10!="N/A") { cre[key, ++cre_n[key]] = $10+0 }
		if($11!="N/A") { spt[key, ++spt_n[key]] = $11+0 }
		if($12!="N/A") { rpt[key, ++rpt_n[key]] = $12+0 }
		if($13!="N/A") { sxp[key, ++sxp_n[key]] = $13+0 }
		if($14!="N/A") { rxp[key, ++rxp_n[key]] = $14+0 }
		if($15=="overflow") sqq_ov[key]++; else if($15!="N/A") { sqq[key, ++sqq_n[key]] = $15+0 }
		if($16=="overflow") rqq_ov[key]++; else if($16!="N/A") { rqq[key, ++rqq_n[key]] = $16+0 }
		if($17!="N/A") { scp[key, ++scp_n[key]] = $17+0 }
		if($18!="N/A") { rcp[key, ++rcp_n[key]] = $18+0 }
		if($19=="overflow") spt2_ov[key]++; else if($19!="N/A") { spt2[key, ++spt2_n[key]] = $19+0 }
		if($20=="overflow") rpt2_ov[key]++; else if($20!="N/A") { rpt2[key, ++rpt2_n[key]] = $20+0 }
		if($11!="N/A" && $11+0 > 0 && $13!="N/A") { amp[key, ++amp_n[key]] = ($13+0 + ($14=="N/A" ? 0 : $14+0)) / $11 }
	}
	!/^#/ && !/^run_id/ && NF>=21 { tot_key = $2 "\t" $3 "\t" $4 "\t" $5; seen[tot_key]=1; n_total[tot_key]++; if($21=="OK") n_valid[tot_key]++ }
	function sort_vals(arr, key, n,    i,j,tmp) {
		for(i=2;i<=n;i++){tmp=arr[key,i];j=i-1;while(j>=1&&arr[key,j]>tmp){arr[key,j+1]=arr[key,j];j--}arr[key,j+1]=tmp}
	}
	function bucket_range(upper_ms) {
		if (upper_ms+0 <= 0)     return "N/A"
		if (upper_ms+0 <= 100)   return "0-100"
		if (upper_ms+0 <= 500)   return "100-500"
		if (upper_ms+0 <= 1000)  return "500-1000"
		if (upper_ms+0 <= 3000)  return "1000-3000"
		if (upper_ms+0 <= 5000)  return "3000-5000"
		if (upper_ms+0 <= 10000) return "5000-10000"
		if (upper_ms+0 <= 20000) return "10000-20000"
		if (upper_ms+0 <= 30000) return "20000-30000"
		return ">30000"
	}
	function csv_stats(ms, ci, br, st, metric, arr, key, n,    i, sum) {
		if(n==0) return
		sort_vals(arr, key, n)
		sum=0; for(i=1;i<=n;i++) sum+=arr[key,i]
		printf "%s,%s,%s,%s,%s,%d,%.0f,%.0f,%.0f,,\n", ms, ci, br, st, metric, n, arr[key,1], arr[key,n], sum/n
	}
	function csv_stats_ratio(ms, ci, br, st, metric, arr, key, n,    i, sum) {
		if(n==0) return
		sort_vals(arr, key, n)
		sum=0; for(i=1;i<=n;i++) sum+=arr[key,i]
		printf "%s,%s,%s,%s,%s,%d,%.1f,%.1f,%.1f,,\n", ms, ci, br, st, metric, n, arr[key,1], arr[key,n], sum/n
	}
	# Histogram p99: min/max/avg over the numeric rows (empty without one), plus the
	# worst bucket and the overflow count. A cell whose only rows overflowed still prints.
	function csv_stats_hist(ms, ci, br, st, metric, arr, key, n, ov,    i, sum) {
		if(n+ov==0) return
		if(n>0) {
			sort_vals(arr, key, n)
			sum=0; for(i=1;i<=n;i++) sum+=arr[key,i]
			printf "%s,%s,%s,%s,%s,%d,%.0f,%.0f,%.0f,", ms, ci, br, st, metric, n, arr[key,1], arr[key,n], sum/n
		} else {
			printf "%s,%s,%s,%s,%s,0,,,,", ms, ci, br, st, metric
		}
		printf "%s,%d\n", (ov>0 ? "overflow" : bucket_range(arr[key,n])), ov
	}
	function sort_keys(    i, j, tmp, k) {
		n_keys = 0
		for (k in seen) sorted_keys[++n_keys] = k
		for (i = 2; i <= n_keys; i++) {
			tmp = sorted_keys[i]; j = i - 1
			while (j >= 1 && sorted_keys[j] > tmp) { sorted_keys[j+1] = sorted_keys[j]; j-- }
			sorted_keys[j+1] = tmp
		}
	}
	END {
		sort_keys()
		for(k=1; k<=n_keys; k++) {
			key = sorted_keys[k]; split(key, p, "\t")
			# Row-validity census: n=n_valid, max=n_total so consumers see both.
			printf "%s,%s,%s,%s,%s,%d,%d,%d,%d,,\n", p[1], p[2], p[3], p[4], "rows_valid_of_total", n_valid[key]+0, n_valid[key]+0, n_total[key]+0, n_valid[key]+0
			csv_stats(p[1], p[2], p[3], p[4], "convergence_local_ms", cl, key, cl_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "remote_endpoint_reachable_ms", cr, key, cr_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "convergence_remote_eds_ms", cre, key, cre_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "source_push_triggers_delta", spt, key, spt_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "remote_push_triggers_delta", rpt, key, rpt_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "source_xds_pushes_delta", sxp, key, sxp_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "remote_xds_pushes_delta", rxp, key, rxp_n[key])
			csv_stats_hist(p[1], p[2], p[3], p[4], "source_queue_time_p99_ms", sqq, key, sqq_n[key], sqq_ov[key]+0)
			csv_stats_hist(p[1], p[2], p[3], p[4], "remote_queue_time_p99_ms", rqq, key, rqq_n[key], rqq_ov[key]+0)
			csv_stats(p[1], p[2], p[3], p[4], "source_connected_proxies", scp, key, scp_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "remote_connected_proxies", rcp, key, rcp_n[key])
			csv_stats_hist(p[1], p[2], p[3], p[4], "source_push_time_p99_ms", spt2, key, spt2_n[key], spt2_ov[key]+0)
			csv_stats_hist(p[1], p[2], p[3], p[4], "remote_push_time_p99_ms", rpt2, key, rpt2_n[key], rpt2_ov[key]+0)
			csv_stats_ratio(p[1], p[2], p[3], p[4], "push_amplification_ratio", amp, key, amp_n[key])
		}
	}'
}

# Metric glossary appended to the markdown summary; keep in sync with tests/churn/README.md.
glossary_section() {
	cat <<'GLOSSARY'

## Glossary

Definitions for every metric column in the results table above. Only the **source**
cluster is scaled; remotes stay at base replicas, so `remote_*` columns measure
cross-cluster propagation. `src_`/`rmt_` prefixes are the source istiod (summed across its
replicas) vs the remote istiod pods (summed/maxed across all remote pods). Averages are over `n_valid` rows only — rows with `status != OK`
(`POISONED_RESTART` / `SCRAPE_INCOMPLETE` / `TIMEOUT_*` / `MISSING_VALUE` / `*_FAILED`) are excluded but still counted in
`n_total`. Histogram p99 columns (`*_queue_p99`, `*_push_p99`) show the **worst** (highest)
bucket range any valid row hit (e.g. `100-500`), not an average: the mean of interpolated
p99s can land in a bucket no row hit. `overflow (N rows)` means N valid rows had their p99
in the `+Inf` bucket (above the histogram's highest finite bucket); `N/A` means no valid row had a
p99. `harness_sha` and `istio_version` in the front matter are what `002` recorded in the
TSVs (`unknown (not recorded)` for a TSV written before it recorded them, `mixed:a,b` when
the inputs differ, each distinct value once), not the commit or pin of the host that ran
this report.

| Column | Units | Source | Definition / caveats |
|--------|-------|--------|----------------------|
| `mesh` | clusters | sweep axis | Mesh size (number of clusters). |
| `churn` | deployments | sweep axis | Churn intensity: churn-target deployments scaled per iteration. |
| `scale` | `base->target` | sweep axis | Replica range applied to each churn target on the source (e.g. `1->5`). |
| `n_total` | rows | internal | All rows for the cell, including poisoned/timed-out rows. |
| `n_valid` | rows | internal | Rows with `status == OK` used in the averages. |
| `local_avg (ms)` | ms | source watcher `/clusters` + source istiod `/debug/syncz` | Time until the source watcher sees at least one new Ready pod per deployment and every source proxy reports SYNCED. **Includes** pod scheduling + sidecar startup. |
| `remote_reach_avg (ms)` | ms | remote watcher Envoy `/clusters` | Time until every churn target on the remote watcher has more healthy endpoint weight than before t0 (at least one new Ready source pod per deployment). **Includes** pod scheduling + sidecar startup. |
| `remote_eds_avg (ms)` | ms | remote `pilot_xds_pushes{type="eds"}` counter delta | Time to the first remote EDS push after t0. Control plane only; **excludes** pod boot. |
| `src_triggers` / `rmt_triggers` | count (delta) | `pilot_push_triggers` counter delta | Push triggers on the source / remote istiod during the churn event. |
| `src_pushes` / `rmt_pushes` | count (delta) | `pilot_xds_pushes` (all types) counter delta | xDS pushes on the source / remote istiod. |
| `src_queue_p99 worst` / `rmt_queue_p99 worst` | ms (bucket range) | `pilot_proxy_queue_time` histogram delta | Worst per-row p99 queue wait on source / remote, as a bucket range; `overflow (N rows)`/`N/A` possible. |
| `src_proxies` / `rmt_proxies` | proxies | `pilot_xds` gauge | Connected proxy count on source / remote istiod at baseline. |
| `src_push_p99 worst` / `rmt_push_p99 worst` | ms (bucket range) | `pilot_xds_push_time` histogram delta | Worst per-row p99 time to compute+send each xDS push, source / remote, as a bucket range; `overflow (N rows)`/`N/A` possible. |
| `amplification` | ratio | derived | `(src_pushes + rmt_pushes) / src_triggers` — mesh-wide push fan-out per source event; only computed when `src_triggers > 0`. `pilot_xds_pushes` counts one push per proxy connection per xDS type, so this scales with connected proxies: compare across mesh sizes, not against 1. |
GLOSSARY
}

report_markdown() {
	# Recorded by 002 at run time (run_meta), never this checkout's HEAD or env.
	local harness_sha="$HARNESS_SHA_M" istio_version="$ISTIO_VERSION_M"

	# Extract sweep axes from TSV data.
	local axes
	axes=$(churn_rows | awk -F'\t' '
	!/^#/ && !/^run_id/ && NF>=21 {
		ms[$2]=1; ci[$3]=1; sc[$4"->"$5]=1
	}
	END {
		s=""; for(k in ms) { s = s (s?",":"") k }; printf "mesh_sizes: %s\n", s
		s=""; for(k in ci) { s = s (s?",":"") k }; printf "churn_intensities: %s\n", s
		s=""; for(k in sc) { s = s (s?",":"") k }; printf "scale: %s\n", s
	}')
	local sweep_mesh sweep_churn sweep_scale
	sweep_mesh=$(echo "$axes" | sed -n 's/^mesh_sizes: //p')
	sweep_churn=$(echo "$axes" | sed -n 's/^churn_intensities: //p')
	sweep_scale=$(echo "$axes" | sed -n 's/^scale: //p')

	echo "---"
	echo "istio_version: \"${istio_version}\""
	echo "istio_version_source: \"${ISTIO_VERSION_SOURCE_M}\""
	echo "istio_version_pin: \"${ISTIO_VERSION_PIN_M}\""
	echo "istio_version_by_context: \"${ISTIO_VERSION_BY_CONTEXT_M}\""
	echo "istio_notready_at_start: \"${ISTIO_NOTREADY_AT_START_M}\""
	echo "istio_ready_waited_sec: \"${ISTIO_READY_WAITED_SEC_M}\""
	echo "harness_sha: \"${harness_sha}\""
	echo "files_consumed: ${#TSV_FILES[@]}"
	echo "tuning_baseline: \"$(preamble_get TUNING_BASELINE)\""
	echo "sidecar_egress_hosts: \"$(preamble_get SIDECAR_EGRESS_HOSTS)\""
	echo "run_config: \"${RUN_CONFIG_M}\""
	echo "run_config_sha256: \"${RUN_CONFIG_SHA256_M}\""
	echo "---"
	echo ""
	echo "# Churn Convergence"
	echo ""
	[[ -z "$POOLED_NOTE" ]] || printf '> **Pooled runs.** %s\n\n' "$POOLED_NOTE"
	sweep_outcome_recorded "$RESULTS_DIR" md
	echo "| Axis | Values |"
	echo "|------|--------|"
	echo "| mesh_sizes | ${sweep_mesh} |"
	echo "| churn_intensities | ${sweep_churn} |"
	echo "| scale | ${sweep_scale} |"
	echo ""
	echo "**Source files:** ${#TSV_FILES[@]} TSV file(s)"
	echo ""
	for f in "${TSV_FILES[@]}"; do
		echo "- \`$(basename "$f")\`"
	done
	echo ""
	echo "| mesh | churn | scale | n_total | n_valid | local_avg (ms) | remote_reach_avg (ms) | remote_eds_avg (ms) | src_triggers | rmt_triggers | src_pushes | rmt_pushes | src_queue_p99 worst (ms) | rmt_queue_p99 worst (ms) | src_proxies | rmt_proxies | src_push_p99 worst (ms) | rmt_push_p99 worst (ms) | amplification |"
	echo "|------|-------|-------|---------|---------|----------------|-----------------------|---------------------|--------------|--------------|------------|------------|--------------------------|--------------------------|-------------|-------------|-------------------------|-------------------------|---------------|"
	churn_rows | awk -F'\t' '
	# The hist_add arrays exist before the first call: some awks will not turn an
	# unused name into an array inside a function.
	BEGIN {
		split("", sqq_max); split("", sqq_n); split("", sqq_ov)
		split("", rqq_max); split("", rqq_n); split("", rqq_ov)
		split("", spt2_max); split("", spt2_n); split("", spt2_ov)
		split("", rpt2_max); split("", rpt2_n); split("", rpt2_ov)
	}
	# n_total counts EVERY row for the cell; numeric aggregation uses ONLY OK rows
	# (POISONED_*/TIMEOUT_*/SCRAPE_INCOMPLETE carry N/A or undercounted deltas).
	!/^#/ && !/^run_id/ && NF>=21 {
		key = $2 "\t" $3 "\t" $4 "\t" $5
		seen[key] = 1
		n_total[key]++
		if($21!="OK") next
		n_valid[key]++
		if($8!="TIMEOUT" && $8!="N/A") { cl_sum[key]+=$8+0; cl_n[key]++ }
		if($9!="TIMEOUT" && $9!="N/A") { cr_sum[key]+=$9+0; cr_n[key]++ }
		if($10!="TIMEOUT" && $10!="N/A") { cre_sum[key]+=$10+0; cre_n[key]++ }
		if($11!="N/A") { spt_sum[key]+=$11+0; spt_n[key]++ }
		if($12!="N/A") { rpt_sum[key]+=$12+0; rpt_n[key]++ }
		if($13!="N/A") { sxp_sum[key]+=$13+0; sxp_n[key]++ }
		if($14!="N/A") { rxp_sum[key]+=$14+0; rxp_n[key]++ }
		# Histogram p99s keep the worst (max) row and count overflows; no average.
		hist_add(sqq_max, sqq_n, sqq_ov, key, $15)
		hist_add(rqq_max, rqq_n, rqq_ov, key, $16)
		if($17!="N/A") { scp_sum[key]+=$17+0; scp_n[key]++ }
		if($18!="N/A") { rcp_sum[key]+=$18+0; rcp_n[key]++ }
		hist_add(spt2_max, spt2_n, spt2_ov, key, $19)
		hist_add(rpt2_max, rpt2_n, rpt2_ov, key, $20)
		if($11!="N/A" && $11+0 > 0 && $13!="N/A") { amp_sum[key]+=($13+0 + ($14=="N/A" ? 0 : $14+0)) / $11; amp_n[key]++ }
	}
	function hist_add(mx, n, ov, key, v) {
		if (v == "overflow") { ov[key]++; return }
		if (v == "N/A" || v == "") return
		if (!(key in n) || v + 0 > mx[key]) mx[key] = v + 0
		n[key]++
	}
	function avg_or_na(s, n) { return n>0 ? sprintf("%.0f", s/n) : "N/A" }
	function avg_ratio(s, n) { return n>0 ? sprintf("%.1f", s/n) : "N/A" }
	function bucket_range(upper_ms) {
		if (upper_ms+0 <= 0)     return "N/A"
		if (upper_ms+0 <= 100)   return "0-100"
		if (upper_ms+0 <= 500)   return "100-500"
		if (upper_ms+0 <= 1000)  return "500-1000"
		if (upper_ms+0 <= 3000)  return "1000-3000"
		if (upper_ms+0 <= 5000)  return "3000-5000"
		if (upper_ms+0 <= 10000) return "5000-10000"
		if (upper_ms+0 <= 20000) return "10000-20000"
		if (upper_ms+0 <= 30000) return "20000-30000"
		return ">30000"
	}
	# Worst bucket over the valid rows; any overflow row makes it "overflow (N rows)".
	function worst_hist(mx, n, ov) {
		if (ov > 0) return sprintf("overflow (%d %s)", ov, ov == 1 ? "row" : "rows")
		return n > 0 ? bucket_range(mx) : "N/A"
	}
	function sort_keys(    i, j, tmp, k) {
		n_keys = 0
		for (k in seen) sorted_keys[++n_keys] = k
		for (i = 2; i <= n_keys; i++) {
			tmp = sorted_keys[i]; j = i - 1
			while (j >= 1 && sorted_keys[j] > tmp) { sorted_keys[j+1] = sorted_keys[j]; j-- }
			sorted_keys[j+1] = tmp
		}
	}
	END {
		sort_keys()
		any_filtered = 0
		for(k=1; k<=n_keys; k++) {
			key = sorted_keys[k]; split(key, p, "\t")
			if ((n_valid[key]+0) < (n_total[key]+0)) any_filtered = 1
			printf "| %s | %s | %s->%s | %d | %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", \
				p[1], p[2], p[3], p[4], n_total[key]+0, n_valid[key]+0, \
				avg_or_na(cl_sum[key], cl_n[key]), \
				avg_or_na(cr_sum[key], cr_n[key]), \
				avg_or_na(cre_sum[key], cre_n[key]), \
				avg_or_na(spt_sum[key], spt_n[key]), \
				avg_or_na(rpt_sum[key], rpt_n[key]), \
				avg_or_na(sxp_sum[key], sxp_n[key]), \
				avg_or_na(rxp_sum[key], rxp_n[key]), \
				worst_hist(sqq_max[key], sqq_n[key]+0, sqq_ov[key]+0), \
				worst_hist(rqq_max[key], rqq_n[key]+0, rqq_ov[key]+0), \
				avg_or_na(scp_sum[key], scp_n[key]), \
				avg_or_na(rcp_sum[key], rcp_n[key]), \
				worst_hist(spt2_max[key], spt2_n[key]+0, spt2_ov[key]+0), \
				worst_hist(rpt2_max[key], rpt2_n[key]+0, rpt2_ov[key]+0), \
				avg_ratio(amp_sum[key], amp_n[key])
		}
		# Note the filter rate when any cell dropped rows.
		if (any_filtered) {
			printf "\n> \\* Some rows were filtered from the averages (`n_valid < n_total`): rows with `status != OK` (POISONED_RESTART / SCRAPE_INCOMPLETE / TIMEOUT_* / MISSING_VALUE / *_FAILED) are excluded from numeric aggregation but still counted in `n_total`.\n"
		}
	}'

	echo ""
	istiod_diag_report md "$RESULTS_DIR"

	glossary_section
}

report_charts() {
	echo "---"
	echo "istio_version: \"${ISTIO_VERSION_M}\""
	echo "istio_version_source: \"${ISTIO_VERSION_SOURCE_M}\""
	echo "istio_version_pin: \"${ISTIO_VERSION_PIN_M}\""
	echo "istio_version_by_context: \"${ISTIO_VERSION_BY_CONTEXT_M}\""
	echo "istio_notready_at_start: \"${ISTIO_NOTREADY_AT_START_M}\""
	echo "istio_ready_waited_sec: \"${ISTIO_READY_WAITED_SEC_M}\""
	echo "harness_sha: \"${HARNESS_SHA_M}\""
	echo "files_consumed: ${#TSV_FILES[@]}"
	echo "run_config: \"${RUN_CONFIG_M}\""
	echo "run_config_sha256: \"${RUN_CONFIG_SHA256_M}\""
	echo "generated: $(date -u -Iseconds)"
	echo "---"
	echo ""
	echo "# Churn Convergence — Charts"
	echo ""
	[[ -z "$POOLED_NOTE" ]] || printf '> **Pooled runs.** %s\n\n' "$POOLED_NOTE"
	churn_rows | awk -F'\t' '
	# Charts average each series per mesh size over valid rows only ($21=="OK").
	# A value of TIMEOUT or N/A is not a sample. Mermaid xychart cannot draw a gap,
	# so a point with no samples is never plotted as 0: each chart keeps only the
	# mesh sizes where every one of its series has samples and names what it left out.
	function add(key, ms, v) { sum[key, ms] += v; cnt[key, ms]++ }
	function chart(title, ytitle, keylist, labellist, fmt,    nk, keys, labels, ax, n_ax, i, j, ms, ok, miss) {
		nk = split(keylist, keys, " "); split(labellist, labels, ",")
		n_ax = 0; miss = ""
		for (i = 1; i <= n_remote; i++) {
			ms = remote_arr[i]; ok = 1
			for (j = 1; j <= nk; j++) {
				if (!((keys[j], ms) in cnt)) {
					ok = 0
					miss = miss (miss == "" ? "" : ", ") labels[j] " @ mesh " ms
				}
			}
			if (ok) ax[++n_ax] = ms
		}
		if (n_ax < 2) {
			printf "\n> Not charted: fewer than two mesh sizes have samples for every series (no samples: %s).\n\n", miss
			return 0
		}
		printf "\n```mermaid\nxychart-beta\n    title \"%s\"\n    x-axis \"Mesh Size\" [", title
		for (i = 1; i <= n_ax; i++) printf "%s%s", (i > 1 ? ", " : ""), ax[i]
		printf "]\n    y-axis \"%s\"\n", ytitle
		for (j = 1; j <= nk; j++) {
			printf "    line ["
			for (i = 1; i <= n_ax; i++) printf "%s" fmt, (i > 1 ? ", " : ""), sum[keys[j], ax[i]] / cnt[keys[j], ax[i]]
			printf "]\n"
		}
		printf "```\n\n"
		if (miss != "") printf "> Mesh sizes with a point that has no samples (e.g. all TIMEOUT) are left out: %s.\n", miss
		return 1
	}
	!/^#/ && !/^run_id/ && NF>=21 {
		rows_total++
		if ($21 != "OK") { rows_dropped++; next }
		ms = $2 + 0
		seen[ms] = 1
		if($8!="TIMEOUT" && $8!="N/A") add("cl", ms, $8+0)
		if($9!="TIMEOUT" && $9!="N/A") add("cr", ms, $9+0)
		if($10!="TIMEOUT" && $10!="N/A") add("cre", ms, $10+0)
		if($13!="N/A") add("sxp", ms, $13+0)
		if($14!="N/A") add("rxp", ms, $14+0)
		if($11!="N/A" && $11+0 > 0 && $13!="N/A") add("amp", ms, ($13+0 + ($14=="N/A" ? 0 : $14+0)) / $11)
	}
	function sort_ms(    i, j, tmp, k) {
		n_ms = 0
		for (k in seen) ms_arr[++n_ms] = k + 0
		for (i = 2; i <= n_ms; i++) {
			tmp = ms_arr[i]; j = i - 1
			while (j >= 1 && ms_arr[j] > tmp) { ms_arr[j+1] = ms_arr[j]; j-- }
			ms_arr[j+1] = tmp
		}
	}
	END {
		if (rows_dropped > 0) {
			printf "> %d of %d rows dropped (no valid samples / restart-poisoned; status != OK) — excluded from the charted averages.\n\n", rows_dropped, rows_total
		}
		sort_ms()
		if (n_ms < 2) {
			print "> Charts require at least two mesh sizes."
			exit
		}
		# Collect mesh sizes >= 2 for remote series.
		n_remote = 0
		for (i = 1; i <= n_ms; i++) {
			if (ms_arr[i] >= 2) remote_arr[++n_remote] = ms_arr[i]
		}
		if (n_remote < 2) {
			print "> Charts require at least two mesh sizes with remote data (mesh >= 2)."
			exit
		}

		printf "%% Chart 1: Convergence latency (ms) vs mesh size\n"
		printf "%% Series order: local avg, remote reach avg, remote EDS avg\n"
		printf "%% x-axis starts at mesh 2 (remote series undefined at mesh 1)\n"
		if (chart("Convergence Latency vs Mesh Size", "Latency (ms)", "cl cr cre", "local avg,remote reach avg,remote EDS avg", "%.0f")) {
			printf "> Series order: **local avg**, **remote reach avg**, **remote EDS avg**.\n"
			printf "> x-axis starts at mesh 2 — remote metrics are undefined at mesh size 1.\n\n"
		}

		printf "%% Chart 2: xDS pushes vs mesh size\n"
		printf "%% Series order: source xDS pushes, remote xDS pushes\n"
		if (chart("xDS Pushes vs Mesh Size", "Push count", "sxp rxp", "source xDS pushes,remote xDS pushes", "%.0f"))
			printf "> Series order: **source xDS pushes**, **remote xDS pushes**.\n\n"

		printf "%% Chart 3: Push amplification ratio vs mesh size\n"
		if (chart("Push Amplification vs Mesh Size", "Amplification ratio", "amp", "push amplification", "%.1f"))
			printf "> Series: **push amplification ratio** (total xDS pushes / source push triggers). Scales with connected proxies x xDS types; compare across mesh sizes, not against 1.\n"
	}'
}

case "$FORMAT" in
text)          report_text ;;
csv)           report_csv ;;
md | markdown) report_markdown ;;
charts)        report_charts ;;
*)             die "unknown format: $FORMAT (use text, csv, md, or charts)" ;;
esac

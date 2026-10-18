#!/usr/bin/env bash
# Aggregate one or more churn-dataplane TSV files into summary reports.
#
# - Drops rows with status != OK or istiod_restarted in {1, unknown}.
# - Reports n_total and n_valid per combination.
# - Δp99_ms is aggregated only over valid baseline/churn pairs sharing a combo_id
#   within one TSV file.
# - Every output format carries the TSV preamble metadata, each key merged over every
#   input (mixed:a,b when it varies, PL26), and RUN_CONFIG / RUN_CONFIG_SHA256 (the
#   --config behind the inputs).
# - More than one run under the results dir stops the report unless
#   --allow-multi-run, and then every format says so.
# - Every output format has a "Remote coverage" section from the reach-*.tsv files
#   that 002's reachability check writes (tests/lib/reach.sh).
#
# Usage:
#   ./tests/churn-dataplane/005-report-results.sh [--results-dir DIR] [--allow-multi-run] [--format FMT] [--fail-on-unreachable]
#   ./tests/churn-dataplane/005-report-results.sh --config tests/churn-dataplane/configs/smoke.env \
#     --results-dir tests/churn-dataplane/results/smoke/sweep-<RUN_ID> --format md
# ci-dry-run: --allow-multi-run
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # config_preload, config_report_value
# --config FILE: export the file's keys before options.env fills in defaults.
config_preload churn-dataplane "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/options.env"  # COEXEC_RESULTS_DIR
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/reach.sh"  # reach_coverage_rows, reach_coverage_render
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/istiod-diag.sh"  # istiod_diag_report

RESULTS_DIR="$(config_repo_path "${COEXEC_RESULTS_DIR}")"
FORMAT="text"
# --allow-multi-run: pool more than one run (else the report refuses). Per invocation
# like --force-large-matrix, so no options.env key.
ALLOW_MULTI_RUN=0
DRY_RUN=0
FAIL_ON_UNREACHABLE=0

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE      Run config of KEY=value lines (config/options.env keys; see
                     tests/churn-dataplane/README.md, "Run config"). Precedence: flag >
                     --config > environment > default.
  --results-dir DIR  Directory searched recursively for churn-dataplane-*.tsv
                     (default: ${COEXEC_RESULTS_DIR}); a sweep-*/ dir from 004
                     is one run.
  --allow-multi-run  Pool more than one run (several sweep-* dirs, or standalone probes
                     with different run ids). Without it the report stops, lists the
                     runs and how to report each alone; with it every format says it
                     pools N runs and lists their HARNESS_SHA and ISTIO_VERSION values.
  --format FMT       Output format: text | csv | json | md (or markdown) | charts
                     (default: text).
  --fail-on-unreachable
                     After the output, exit 3 when a remote's reach coverage is not
                     REACHABLE (stderr names the rule and the remotes).
  --dry-run          List the TSV files that would be read, then exit.
  -h, --help         Show this help.

Example (one sweep, as 004 runs it; from the repo root):
  tests/churn-dataplane/$(basename "$0") \\
    --results-dir ${COEXEC_RESULTS_DIR}/sweep-<RUN_ID> --format md

Every format has a "Remote coverage" section from the reach-*.tsv files next to the
TSVs: per mesh size and source, how many remotes passed every reach check
(REACHABLE, FLAPPING, DEGRADED, UNREACHABLE, UNKNOWN per remote). Without reach
files (the check was off, or the TSV predates it) it says "no reachability data".
Rows with any status but OK are left out of valid_runs, ERROR_RATE_HIGH (HTTP 200
share below MIN_PCT_200) and REMOTE_UNREACHABLE (sweep stopped by the gate) included.
Each average counts only the valid pairs with a number in that column (N/A when none).
churn_convergence_p99 is the worst bucket a valid run hit (labels in ms, no unit
suffix), or "overflow (N runs)"; csv and json split it into
churn_convergence_p99_worst and churn_convergence_overflow_runs. json numbers are
numbers and N/A is null.

REPORT_HARNESS_SHA (every format, next to HARNESS_SHA; json report_harness_sha): the
harness this report ran on, which can differ from HARNESS_SHA, the harness that
measured the rows: a report made again later, or from another checkout, may count
rows by other rules. The results dir it reads does not count as a change to it.
HARNESS_CONTENT_KEY (every format, after HARNESS_SHA; json harness_content_key): the
content key of the harness files the rows ran on, unknown for a TSV written before
it. Inputs whose HARNESS_SHA differs but that share one key differ only in git
describe (a docs commit or a new tag between them), not in the harness.
md and charts start with a YAML frontmatter of the metadata keys, lowercase as in
the json metadata (run_id, harness_sha, harness_content_key, report_harness_sha,
run_config, ...).

text, md and json also carry an "istiod restart diagnostics" section: every
istiod-diag-*/index.tsv under the results dir, one line per restart (run_id, what
changed, the cause, the evidence folder relative to the results dir) and a tally by
cause; restarted_untimed rows (may predate the window) are counted apart (json key
istiod_diag).

When the results dir holds sweep-outcome.txt (004 writes it), every format repeats
it, with the run that recorded it: the failed cells by reason, its problems (the Istio
version, the active revision or the generation of the Istio CR or its active
IstioRevision changed under the sweep, or the end-of-sweep check failed) and notes
(members not ready at its start or end). The sweep writes it at its start as "not
finished" (EXIT=unfinished) and replaces it at its end: a record still not finished
is a sweep that died or still runs, or one interrupted (Ctrl-C, SIGTERM, SIGHUP),
with when and by which signal; one that stopped on an error after its start shows
the stop and its reason. A sweep dir without the file is from a sweep that stopped
before its start (nothing ran), or from an older harness.

Exit status: 0, 1 on an error, 3 with --fail-on-unreachable when the rule fired.

Environment:
  COEXEC_RESULTS_DIR  --results-dir default (relative to the repo root).
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--config)
		# Loaded by config_preload above.
		[[ -n "${2:-}" ]] || die "--config requires a value"
		shift 2 ;;
	--results-dir)
		[[ -n "${2:-}" ]] || die "--results-dir requires a value"
		RESULTS_DIR="$2"; shift 2 ;;
	--allow-multi-run)
		ALLOW_MULTI_RUN=1; shift ;;
	--format)
		[[ -n "${2:-}" ]] || die "--format requires a value"
		FORMAT="$2"; shift 2 ;;
	--fail-on-unreachable)
		FAIL_ON_UNREACHABLE=1; shift ;;
	--dry-run)
		DRY_RUN=1; shift ;;
	-h | --help)
		usage; exit 0 ;;
	*)
		die "unknown option: $1 (try --help)" ;;
	esac
done

case "$FORMAT" in
text | csv | json | md | markdown | charts) ;;
*) die "unknown format: $FORMAT (use text|csv|json|md|charts)" ;;
esac

if ((DRY_RUN)); then
	DRY_FILES=()
	nr=0
	[[ -d "$RESULTS_DIR" ]] && mapfile -t DRY_FILES < <(find -H "$RESULTS_DIR" -name 'churn-dataplane-*.tsv' -type f | sort)
	[[ -d "$RESULTS_DIR" ]] && nr=$(find -H "$RESULTS_DIR" -name 'reach-*.tsv' -type f | wc -l)
	# The same refusal as the report: a dir with more than one run is not summarized.
	((${#DRY_FILES[@]} == 0)) || config_check_multi_run "$RESULTS_DIR" "$ALLOW_MULTI_RUN" "${DRY_FILES[@]}"
	echo "[dry-run] would summarize ${#DRY_FILES[@]} churn-dataplane-*.tsv file(s) and $((nr)) reach-*.tsv file(s) under $RESULTS_DIR as $FORMAT"
	exit 0
fi

[[ -d "$RESULTS_DIR" ]] || die "results directory not found: $RESULTS_DIR"

# Recurse into sweep-* subdirs as well.
TSV_FILES=()
while IFS= read -r f; do TSV_FILES+=("$f"); done < <(find -H "$RESULTS_DIR" -name 'churn-dataplane-*.tsv' -type f 2>/dev/null | sort)
((${#TSV_FILES[@]})) || die "no churn-dataplane-*.tsv files in $RESULTS_DIR"

# PL6: the report pools every TSV under the results dir; more than one run stops it
# unless --allow-multi-run, and then every format says so (config_multi_run_note).
config_check_multi_run "$RESULTS_DIR" "$ALLOW_MULTI_RUN" "${TSV_FILES[@]}"
POOLED_NOTE="$(config_multi_run_note)"

# Preamble metadata over every input (sweeps emit one preamble per file): each key
# merged over the files that carry it, one value or mixed:a,b, never the first file's
# (PL26). extract_preamble_kv <key> prints it (nothing when no file has the key).
declare -A MERGED_PREAMBLE=()
while IFS= read -r _kv; do
	MERGED_PREAMBLE["${_kv%%=*}"]="${_kv#*=}"
done < <(config_merged_preamble "${TSV_FILES[@]}")
extract_preamble_kv() {
	[[ -z "${MERGED_PREAMBLE[$1]+x}" ]] || printf '%s\n' "${MERGED_PREAMBLE[$1]}"
}

# Warn if the TSV files have mismatched preamble configs.
if [[ "$(extract_preamble_kv QPS)" == mixed:* || "$(extract_preamble_kv CHURN_DURATION_SEC)" == mixed:* ]]; then
	echo "warn: TSV files have mismatched preamble (QPS or DURATION); aggregation may conflate different configurations" >&2
fi

RUN_ID="$(extract_preamble_kv RUN_ID)"
HARNESS_SHA="$(extract_preamble_kv HARNESS_SHA)"
# The content key of the harness files the rows ran on, over every input: unknown for a
# TSV written before it (so a pooled report never credits older rows with a key).
HARNESS_CONTENT_KEY_STR="$(config_input_value HARNESS_CONTENT_KEY unknown "${TSV_FILES[@]}")"
ISTIO_VERSION_STR="$(extract_preamble_kv ISTIO_VERSION)"
# Live (each member's active IstioRevision) or pin (config only), the configured pin,
# and which member ran which (PL19).
ISTIO_VERSION_SOURCE_STR="$(extract_preamble_kv ISTIO_VERSION_SOURCE)"
ISTIO_VERSION_PIN_STR="$(extract_preamble_kv ISTIO_VERSION_PIN)"
ISTIO_VERSION_BY_CONTEXT_STR="$(extract_preamble_kv ISTIO_VERSION_BY_CONTEXT)"
# The members still not ready after the start's readiness wait, and how long it took.
ISTIO_NOTREADY_AT_START_STR="$(extract_preamble_kv ISTIO_NOTREADY_AT_START)"
ISTIO_READY_WAITED_SEC_STR="$(extract_preamble_kv ISTIO_READY_WAITED_SEC)"
# Each member's active Istio revision, its Istio CR / active IstioRevision
# generations (an edit of either between pooled runs reads mixed, also at one version)
# and the proxy versions connected to its istiod at the start (ctx=...); unknown for a
# file written before them.
ISTIO_ACTIVE_REVISIONS_STR="$(extract_preamble_kv ISTIO_ACTIVE_REVISIONS)"
ISTIO_GENERATIONS_STR="$(extract_preamble_kv ISTIO_GENERATIONS)"
ISTIO_PROXY_VERSIONS_STR="$(extract_preamble_kv ISTIO_PROXY_VERSIONS)"
KUBE_VERSIONS_STR="$(extract_preamble_kv KUBE_VERSIONS)"
# Tuning levers + sidecar egress hosts queried live when the sweep ran.
TUNING_BASELINE_STR="$(extract_preamble_kv TUNING_BASELINE)"
SIDECAR_EGRESS_HOSTS_STR="$(extract_preamble_kv SIDECAR_EGRESS_HOSTS)"
ISTIOD_REPLICAS_STR="$(extract_preamble_kv ISTIOD_REPLICAS)"
SETTLE_SEC_STR="$(extract_preamble_kv SETTLE_SEC)"
BASELINE_DURATION_STR="$(extract_preamble_kv BASELINE_DURATION_SEC)"
CHURN_DURATION_STR="$(extract_preamble_kv CHURN_DURATION_SEC)"
QPS_STR="$(extract_preamble_kv QPS)"
CONNECTIONS_STR="$(extract_preamble_kv CONNECTIONS)"
NAMESPACE_STR="$(extract_preamble_kv NAMESPACE)"
# Scrape-skew ceiling and per-curl timeout behind any POISONED_SCRAPE drops.
FANOUT_MAX_SKEW_MS_STR="$(extract_preamble_kv FANOUT_MAX_SKEW_MS)"
FANOUT_METRICS_TIMEOUT_STR="$(extract_preamble_kv FANOUT_METRICS_TIMEOUT)"
# Error-rate threshold and reach-check settings (absent before the reach check).
MIN_PCT_200_STR="$(extract_preamble_kv MIN_PCT_200)"
REACH_REQUESTS_STR="$(extract_preamble_kv REACH_REQUESTS)"
REACH_QPS_STR="$(extract_preamble_kv REACH_QPS)"
REACH_HTTP_TIMEOUT_SEC_STR="$(extract_preamble_kv REACH_HTTP_TIMEOUT_SEC)"
REACH_DETAIL_TIMEOUT_SEC_STR="$(extract_preamble_kv REACH_DETAIL_TIMEOUT_SEC)"
REACH_ATTEMPTS_STR="$(extract_preamble_kv REACH_ATTEMPTS)"
REACH_RETRY_SEC_STR="$(extract_preamble_kv REACH_RETRY_SEC)"
ON_UNREACHABLE_STR="$(extract_preamble_kv ON_UNREACHABLE)"
# Which --config produced the inputs (PL2/PL19), over every input: `none` without one,
# `unknown` for files written before the key existed, mixed:a,b with a warning (PL26).
RUN_CONFIG_STR="$(config_report_value RUN_CONFIG "${TSV_FILES[@]}")"
RUN_CONFIG_SHA256_STR="$(config_report_value RUN_CONFIG_SHA256 "${TSV_FILES[@]}")"
# This report's own harness, every format; the results dir it reads is no change to it.
REPORT_HARNESS_SHA_STR="$(report_harness_sha --exclude "$RESULTS_DIR")"

# Remote coverage over every reach-*.tsv under RESULTS_DIR (empty without any).
REACH_ROWS="$(reach_coverage_rows "$RESULTS_DIR")"
REACH_NOT_REACHABLE="$(awk -F'\t' 'NF >= 8 && $6 != "REACHABLE" { n++ } END { print n + 0 }' <<<"$REACH_ROWS")"

# The core aggregation pass: build the joined per-(mesh_size, churn_rate) view
# from baseline+churn pairs that share combo_id. Emit a single TSV stream that
# downstream formatters can render. Column order (Δp99 right after the keys, then
# validity counts, then the underlying numbers):
#   mesh_size  churn_rate  delta_p99_ms  stdev_delta_p99  total_runs  valid_runs
#   baseline_p99_ms  churn_p99_ms  baseline_p50_ms  churn_p50_ms
#   baseline_qps  churn_qps  churn_eds_pushes  churn_convergence_p99_worst
#   churn_convergence_overflow_runs
# Each average is over the valid pairs that have a number in that column (its own
# count), so an N/A p50 or QPS is left out instead of counting as 0; N/A when none
# has. churn_convergence_p99_worst is the highest bucket range (labels without a unit;
# headers say ms) a valid pair's p99 hit, "overflow" when any valid pair's p99 was in
# the +Inf bucket (churn_convergence_overflow_runs counts them). It is never averaged:
# the mean of interpolated p99s can land in a bucket no run hit.
aggregate() {
	awk -F'\t' '
	function is_valid_row(restarted, status) {
		if (status != "OK") return 0
		if (restarted == "1" || restarted == "unknown") return 0
		return 1
	}
	function is_num(x) { return (x != "N/A" && x != "" && x != "overflow" && x != "unknown" && x + 0 == x) }
	function bucket_range(upper_ms) {
		if (upper_ms == "N/A" || upper_ms == "overflow" || upper_ms == "") return upper_ms
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
	function avg_fmt(s, n, fmt) { return (n > 0) ? sprintf(fmt, s / n) : "N/A" }

	!/^#/ && !/^run_id/ && NF >= 17 {
		# Pair rows within one file: combo ids such as "ms1-cr1" repeat across sweeps.
		combo = FILENAME SUBSEP $3; ms = $4; cr = $5; phase = $6
		qps_actual = $9; p50 = $10; p99 = $12; restarted = $16; status = $17

		# istiod-side metrics (columns 20-25, present when NF >= 25).
		xds_pushes = (NF >= 20) ? $20 : "N/A"
		eds_pushes = (NF >= 21) ? $21 : "N/A"
		conv_p99   = (NF >= 23) ? $23 : "N/A"

		valid = is_valid_row(restarted, status)
		if (phase == "baseline") {
			bl_seen[combo] = 1
			bl_status[combo] = (valid ? "ok" : "bad")
			bl_ms[combo] = ms
			if (valid) {
				bl_p50[combo] = is_num(p50) ? p50 + 0 : "N/A"
				bl_p99[combo] = is_num(p99) ? p99 + 0 : "N/A"
				bl_qps[combo] = is_num(qps_actual) ? qps_actual + 0 : "N/A"
			}
		} else if (phase == "churn") {
			ch_seen[combo] = 1
			ch_status[combo] = (valid ? "ok" : "bad")
			ch_ms[combo] = ms
			ch_cr[combo] = cr
			if (valid) {
				ch_p50[combo] = is_num(p50) ? p50 + 0 : "N/A"
				ch_p99[combo] = is_num(p99) ? p99 + 0 : "N/A"
				ch_qps[combo] = is_num(qps_actual) ? qps_actual + 0 : "N/A"
				ch_eds[combo] = is_num(eds_pushes) ? eds_pushes + 0 : "N/A"
				ch_conv[combo] = is_num(conv_p99) ? conv_p99 + 0 : (conv_p99 == "overflow" ? "overflow" : "N/A")
			}
		}
	}
	END {
		for (combo in ch_seen) {
			rk = ch_ms[combo] "\t" ch_cr[combo]
			total[rk]++
		}
		for (combo in bl_seen) {
			if (combo in ch_seen) continue
			rk = bl_ms[combo] "\t0"
			total[rk]++
		}

		for (combo in bl_seen) {
			if (bl_status[combo] != "ok") continue
			if (!(combo in ch_seen) || ch_status[combo] != "ok") continue
			if (bl_p99[combo] == "N/A" || ch_p99[combo] == "N/A") continue
			rk = ch_ms[combo] "\t" ch_cr[combo]
			nv = ++n_valid[rk]

			dp99 = ch_p99[combo] - bl_p99[combo]
			s_dp99[rk] += dp99

			# Welford online variance for delta_p99.
			old_mean = mean_dp99[rk]
			mean_dp99[rk] += (dp99 - old_mean) / nv
			m2_dp99[rk] += (dp99 - old_mean) * (dp99 - mean_dp99[rk])

			# p99s are numeric here (gated above); p50 and QPS may be N/A, so each
			# keeps its own count and an N/A never adds a 0.
			s_bp99[rk] += bl_p99[combo]
			s_cp99[rk] += ch_p99[combo]
			if (bl_p50[combo] != "N/A") { s_bp50[rk] += bl_p50[combo]; n_bp50[rk]++ }
			if (ch_p50[combo] != "N/A") { s_cp50[rk] += ch_p50[combo]; n_cp50[rk]++ }
			if (bl_qps[combo] != "N/A") { s_bqps[rk] += bl_qps[combo]; n_bqps[rk]++ }
			if (ch_qps[combo] != "N/A") { s_cqps[rk] += ch_qps[combo]; n_cqps[rk]++ }

			if (ch_eds[combo] != "N/A") { s_ceds[rk] += ch_eds[combo]; n_ceds[rk]++ }
			if (ch_conv[combo] == "overflow") ov_cconv[rk]++
			else if (ch_conv[combo] != "N/A" && (!(rk in mx_cconv) || ch_conv[combo] > mx_cconv[rk])) mx_cconv[rk] = ch_conv[combo]
		}

		for (rk in total) {
			tot_pairs = total[rk]
			nv = (rk in n_valid) ? n_valid[rk] : 0
			if (nv > 0) {
				stdev = (nv >= 2) ? sprintf("%.2f", sqrt(m2_dp99[rk] / (nv - 1))) : "N/A"
				ch_eds_avg = avg_fmt(s_ceds[rk], n_ceds[rk] + 0, "%.0f")
				ch_conv_worst = (ov_cconv[rk] + 0 > 0) ? "overflow" : ((rk in mx_cconv) ? bucket_range(mx_cconv[rk]) : "N/A")
				printf "%s\t%.2f\t%s\t%d\t%d\t%.2f\t%.2f\t%s\t%s\t%s\t%s\t%s\t%s\t%d\n",
					rk,
					s_dp99[rk]/nv, stdev,
					tot_pairs, nv,
					s_bp99[rk]/nv, s_cp99[rk]/nv,
					avg_fmt(s_bp50[rk], n_bp50[rk] + 0, "%.2f"), avg_fmt(s_cp50[rk], n_cp50[rk] + 0, "%.2f"),
					avg_fmt(s_bqps[rk], n_bqps[rk] + 0, "%.1f"), avg_fmt(s_cqps[rk], n_cqps[rk] + 0, "%.1f"),
					ch_eds_avg, ch_conv_worst, ov_cconv[rk] + 0
			} else {
				printf "%s\tN/A\tN/A\t%d\t0\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t0\n", rk, tot_pairs
			}
		}
	}' "${TSV_FILES[@]}" | sort -k1,1n -k2,2n
}

# conv_cell(worst, overflow_runs), appended to the text and md awk programs: the
# worst convergence bucket, or "overflow (N runs)" when N valid runs overflowed.
# shellcheck disable=SC2016
CONV_CELL_AWK='
function conv_cell(w, ov) {
	if (ov + 0 > 0) return sprintf("overflow (%d %s)", ov, (ov + 0 == 1) ? "run" : "runs")
	return w
}'

# metadata_kv: the run's metadata as KEY=value lines, in the order every format shows them.
metadata_kv() {
	printf '%s\n' \
		"RUN_ID=${RUN_ID:-unknown}" \
		"HARNESS_SHA=${HARNESS_SHA:-unknown}" \
		"HARNESS_CONTENT_KEY=${HARNESS_CONTENT_KEY_STR:-unknown}" \
		"REPORT_HARNESS_SHA=${REPORT_HARNESS_SHA_STR}" \
		"ISTIO_VERSION=${ISTIO_VERSION_STR:-unknown}" \
		"ISTIO_VERSION_SOURCE=${ISTIO_VERSION_SOURCE_STR:-unknown}" \
		"ISTIO_VERSION_PIN=${ISTIO_VERSION_PIN_STR:-unknown}" \
		"ISTIO_VERSION_BY_CONTEXT=${ISTIO_VERSION_BY_CONTEXT_STR:-unknown}" \
		"ISTIO_NOTREADY_AT_START=${ISTIO_NOTREADY_AT_START_STR:-unknown}" \
		"ISTIO_READY_WAITED_SEC=${ISTIO_READY_WAITED_SEC_STR:-unknown}" \
		"ISTIO_ACTIVE_REVISIONS=${ISTIO_ACTIVE_REVISIONS_STR:-unknown}" \
		"ISTIO_GENERATIONS=${ISTIO_GENERATIONS_STR:-unknown}" \
		"ISTIO_PROXY_VERSIONS=${ISTIO_PROXY_VERSIONS_STR:-unknown}" \
		"KUBE_VERSIONS=${KUBE_VERSIONS_STR:-unknown}" \
		"TUNING_BASELINE=${TUNING_BASELINE_STR:-unknown}" \
		"SIDECAR_EGRESS_HOSTS=${SIDECAR_EGRESS_HOSTS_STR:-unknown}" \
		"ISTIOD_REPLICAS=${ISTIOD_REPLICAS_STR:-unknown}" \
		"SETTLE_SEC=${SETTLE_SEC_STR:-unknown}" \
		"BASELINE_DURATION_SEC=${BASELINE_DURATION_STR:-unknown}" \
		"CHURN_DURATION_SEC=${CHURN_DURATION_STR:-unknown}" \
		"QPS=${QPS_STR:-unknown}" \
		"CONNECTIONS=${CONNECTIONS_STR:-unknown}" \
		"NAMESPACE=${NAMESPACE_STR:-unknown}" \
		"FANOUT_MAX_SKEW_MS=${FANOUT_MAX_SKEW_MS_STR:-unknown}" \
		"FANOUT_METRICS_TIMEOUT=${FANOUT_METRICS_TIMEOUT_STR:-unknown}" \
		"MIN_PCT_200=${MIN_PCT_200_STR:-unknown}" \
		"REACH_REQUESTS=${REACH_REQUESTS_STR:-unknown}" \
		"REACH_QPS=${REACH_QPS_STR:-unknown}" \
		"REACH_HTTP_TIMEOUT_SEC=${REACH_HTTP_TIMEOUT_SEC_STR:-unknown}" \
		"REACH_DETAIL_TIMEOUT_SEC=${REACH_DETAIL_TIMEOUT_SEC_STR:-unknown}" \
		"REACH_ATTEMPTS=${REACH_ATTEMPTS_STR:-unknown}" \
		"REACH_RETRY_SEC=${REACH_RETRY_SEC_STR:-unknown}" \
		"ON_UNREACHABLE=${ON_UNREACHABLE_STR:-unknown}" \
		"RUN_CONFIG=${RUN_CONFIG_STR:-unknown}" \
		"RUN_CONFIG_SHA256=${RUN_CONFIG_SHA256_STR:-unknown}"
}

# emit_metadata_lines <prefix>: text and csv: "<prefix> KEY=value" per metadata key.
emit_metadata_lines() {
	local prefix="${1:-#}" kv
	while IFS= read -r kv; do printf '%s %s\n' "$prefix" "$kv"; done < <(metadata_kv)
}

# emit_frontmatter [line]: the YAML frontmatter of md and charts (PL19): every metadata
# key, lowercase as in the json metadata, its value through yaml_str; then [line].
emit_frontmatter() {
	local kv k o
	echo "---"
	while IFS= read -r kv; do
		k="${kv%%=*}"
		yaml_str -v o "${kv#*=}"
		printf '%s: %s\n' "${k,,}" "$o"
	done < <(metadata_kv)
	[[ -z "${1:-}" ]] || echo "$1"
	echo "---"
}

report_text() {
	echo "=== sweep-summary ==="
	[[ -z "$POOLED_NOTE" ]] || printf 'POOLED RUNS: %s\n' "$POOLED_NOTE"
	sweep_outcome_recorded "$RESULTS_DIR" text
	emit_metadata_lines "#"
	echo ""
	reach_coverage_render text <(printf '%s' "$REACH_ROWS")
	echo ""
	printf '  %-9s | %-10s | %14s | %15s | %-10s | %-10s | %15s | %15s | %15s | %15s | %12s | %12s | %18s | %33s\n' \
		"mesh_size" "churn_rate" "delta_p99_ms" "stdev_delta_p99" "total_runs" "valid_runs" \
		"baseline_p99_ms" "churn_p99_ms" "baseline_p50_ms" "churn_p50_ms" "baseline_qps" "churn_qps" \
		"churn_eds_pushes" "churn_convergence_p99 worst (ms)"
	printf '  %-9s-+-%-10s-+-%14s-+-%15s-+-%-10s-+-%-10s-+-%15s-+-%15s-+-%15s-+-%15s-+-%12s-+-%12s-+-%18s-+-%33s\n' \
		"---------" "----------" "--------------" "---------------" "----------" "----------" \
		"---------------" "---------------" "---------------" "---------------" "------------" "------------" \
		"------------------" "---------------------------------"
	aggregate | awk -F'\t' '{
		printf "  %-9s | %-10s | %14s | %15s | %-10s | %-10s | %15s | %15s | %15s | %15s | %12s | %12s | %18s | %33s\n", \
			$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, conv_cell($14, $15)
	}
	'"$CONV_CELL_AWK"
	echo ""
	istiod_diag_report text "$RESULTS_DIR"
}

report_csv() {
	emit_metadata_lines "#"
	config_multi_run_csv
	sweep_outcome_recorded "$RESULTS_DIR" csv
	reach_coverage_render csv <(printf '%s' "$REACH_ROWS")
	echo "mesh_size,churn_rate,delta_p99_ms,stdev_delta_p99,total_runs,valid_runs,baseline_p99_ms,churn_p99_ms,baseline_p50_ms,churn_p50_ms,baseline_qps,churn_qps,churn_eds_pushes,churn_convergence_p99_worst,churn_convergence_overflow_runs"
	aggregate | awk -F'\t' '{ printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15 }'
}

report_json() {
	# Numbers are JSON numbers, N/A is null; the convergence bucket is a label string.
	local rows
	rows="$(aggregate | jq -R -s '
		def num: if . == "N/A" or . == "" then null else (tonumber? // null) end;
		split("\n") | map(select(length > 0) | split("\t") | {
			mesh_size: (.[0] | num), churn_rate: (.[1] | num),
			delta_p99_ms: (.[2] | num), stdev_delta_p99: (.[3] | num),
			total_runs: (.[4] | num), valid_runs: (.[5] | num),
			baseline_p99_ms: (.[6] | num), churn_p99_ms: (.[7] | num),
			baseline_p50_ms: (.[8] | num), churn_p50_ms: (.[9] | num),
			baseline_qps: (.[10] | num), churn_qps: (.[11] | num),
			churn_eds_pushes: (.[12] | num),
			churn_convergence_p99_worst: (if .[13] == "N/A" then null else .[13] end),
			churn_convergence_overflow_runs: (.[14] | num)
		})')"
	jq -n \
		--arg run_id           "${RUN_ID:-unknown}" \
		--arg harness_sha      "${HARNESS_SHA:-unknown}" \
		--arg harness_content_key "${HARNESS_CONTENT_KEY_STR:-unknown}" \
		--arg report_harness_sha "${REPORT_HARNESS_SHA_STR}" \
		--arg istio_version    "${ISTIO_VERSION_STR:-unknown}" \
		--arg istio_version_source "${ISTIO_VERSION_SOURCE_STR:-unknown}" \
		--arg istio_version_pin "${ISTIO_VERSION_PIN_STR:-unknown}" \
		--arg istio_version_by_context "${ISTIO_VERSION_BY_CONTEXT_STR:-unknown}" \
		--arg istio_notready_at_start "${ISTIO_NOTREADY_AT_START_STR:-unknown}" \
		--arg istio_ready_waited_sec "${ISTIO_READY_WAITED_SEC_STR:-unknown}" \
		--arg istio_active_revisions "${ISTIO_ACTIVE_REVISIONS_STR:-unknown}" \
		--arg istio_generations "${ISTIO_GENERATIONS_STR:-unknown}" \
		--arg istio_proxy_versions "${ISTIO_PROXY_VERSIONS_STR:-unknown}" \
		--arg kube_versions    "${KUBE_VERSIONS_STR:-unknown}" \
		--arg tuning_baseline  "${TUNING_BASELINE_STR:-unknown}" \
		--arg sidecar_egress_hosts "${SIDECAR_EGRESS_HOSTS_STR:-unknown}" \
		--arg istiod_replicas  "${ISTIOD_REPLICAS_STR:-unknown}" \
		--arg settle_sec       "${SETTLE_SEC_STR:-unknown}" \
		--arg baseline_dur     "${BASELINE_DURATION_STR:-unknown}" \
		--arg churn_dur        "${CHURN_DURATION_STR:-unknown}" \
		--arg qps              "${QPS_STR:-unknown}" \
		--arg connections      "${CONNECTIONS_STR:-unknown}" \
		--arg namespace        "${NAMESPACE_STR:-unknown}" \
		--arg fanout_max_skew  "${FANOUT_MAX_SKEW_MS_STR:-unknown}" \
		--arg fanout_metrics_timeout "${FANOUT_METRICS_TIMEOUT_STR:-unknown}" \
		--arg min_pct_200      "${MIN_PCT_200_STR:-unknown}" \
		--arg reach_requests   "${REACH_REQUESTS_STR:-unknown}" \
		--arg reach_qps        "${REACH_QPS_STR:-unknown}" \
		--arg reach_http_timeout_sec "${REACH_HTTP_TIMEOUT_SEC_STR:-unknown}" \
		--arg reach_detail_timeout_sec "${REACH_DETAIL_TIMEOUT_SEC_STR:-unknown}" \
		--arg reach_attempts   "${REACH_ATTEMPTS_STR:-unknown}" \
		--arg reach_retry_sec  "${REACH_RETRY_SEC_STR:-unknown}" \
		--arg on_unreachable   "${ON_UNREACHABLE_STR:-unknown}" \
		--arg run_config       "${RUN_CONFIG_STR:-unknown}" \
		--arg run_config_sha256 "${RUN_CONFIG_SHA256_STR:-unknown}" \
		--argjson remote_coverage "$(reach_coverage_render json <(printf '%s' "$REACH_ROWS"))" \
		--argjson not_reachable "$REACH_NOT_REACHABLE" \
		--argjson istiod_diag  "$(istiod_diag_report json "$RESULTS_DIR")" \
		--argjson rows         "$rows" \
		--argjson pooled_runs  "$(config_multi_run_json)" \
		--argjson sweep_outcome "$(sweep_outcome_recorded "$RESULTS_DIR" json)" \
		'{pooled_runs: $pooled_runs, sweep_outcome: $sweep_outcome, metadata: {run_id: $run_id, harness_sha: $harness_sha, harness_content_key: $harness_content_key, report_harness_sha: $report_harness_sha, istio_version: $istio_version, istio_version_source: $istio_version_source, istio_version_pin: $istio_version_pin, istio_version_by_context: $istio_version_by_context, istio_notready_at_start: $istio_notready_at_start, istio_ready_waited_sec: $istio_ready_waited_sec, istio_active_revisions: $istio_active_revisions, istio_generations: $istio_generations, istio_proxy_versions: $istio_proxy_versions, kube_versions: $kube_versions, tuning_baseline: $tuning_baseline, sidecar_egress_hosts: $sidecar_egress_hosts, istiod_replicas: $istiod_replicas, settle_sec: $settle_sec, baseline_duration_sec: $baseline_dur, churn_duration_sec: $churn_dur, qps: $qps, connections: $connections, namespace: $namespace, fanout_max_skew_ms: $fanout_max_skew, fanout_metrics_timeout: $fanout_metrics_timeout, min_pct_200: $min_pct_200, reach_requests: $reach_requests, reach_qps: $reach_qps, reach_http_timeout_sec: $reach_http_timeout_sec, reach_detail_timeout_sec: $reach_detail_timeout_sec, reach_attempts: $reach_attempts, reach_retry_sec: $reach_retry_sec, on_unreachable: $on_unreachable, run_config: $run_config, run_config_sha256: $run_config_sha256}, summary: {remotes_not_reachable: $not_reachable}, remote_coverage: $remote_coverage.remote_coverage, istiod_diag: $istiod_diag, rows: $rows}'
}

# Metric glossary appended to the END of the markdown summary (#17). Definitions are
# pulled from tests/churn-dataplane/README.md; units/source/caveats mirror it, not invented.
glossary_section() {
	cat <<'GLOSSARY'

## Glossary

Definitions for every metric column in the results table above. Sourced from
`tests/churn-dataplane/README.md`. Each row pairs a **baseline** phase (no churn) with a
**churn** phase under concurrent endpoint scaling; `delta_*` = churn − baseline. A row is
**valid** only when BOTH phases are `status == OK` and not restart-poisoned
(`istiod_restarted == 0`); `valid_runs < total_runs` means some pairs were dropped.

| Column | Units | Source | Definition / caveats |
|--------|-------|--------|----------------------|
| `mesh_size` | clusters | sweep axis | Mesh size (number of clusters / deployments). |
| `churn_rate` | scale-ops/s | sweep axis | Endpoint churn rate applied during the churn phase; baseline rows are `0`. |
| `delta_p99_ms` | ms | Fortio JSON, derived | `churn_p99 − baseline_p99` — added tail latency under churn; `N/A` unless a valid baseline+churn pair exists. |
| `stdev_delta_p99` | ms | Welford (internal) | Standard deviation of `delta_p99_ms` across valid repetitions; `N/A` when `valid_runs < 2`. |
| `total_runs` | runs | internal | All baseline+churn pairs for the cell, including poisoned/failed ones and `REMOTE_UNREACHABLE` pairs (no window ran). |
| `valid_runs` | runs | internal | Pairs where both phases are OK and not restart-poisoned; used in every average. |
| `baseline_p99_ms` / `churn_p99_ms` | ms | Fortio JSON `DurationHistogram.Percentiles[99]` | p99 latency in the baseline / churn phase. |
| `baseline_p50_ms` / `churn_p50_ms` | ms | Fortio JSON `DurationHistogram.Percentiles[50]` | p50 latency in the baseline / churn phase; averaged over the valid pairs that have one (`N/A` when none has). |
| `baseline_qps` / `churn_qps` | queries/s | Fortio JSON `ActualQPS` | Achieved QPS in the baseline / churn phase, averaged like p50; churn QPS may drop under control-plane contention. |
| `churn_eds_pushes` | count (delta) | `pilot_xds_pushes{type="eds"}` counter delta | EDS pushes triggered during the churn phase; `N/A` if istiod restarted or the scrape failed. |
| `churn_convergence_p99 worst` | ms (bucket range) | `pilot_proxy_convergence_time` histogram delta | The **worst** (highest) bucket range any valid run's p99 convergence hit during churn (e.g. `500-1000`), not an average: the mean of interpolated p99s can land in a bucket no run hit. `overflow (N runs)` when N valid runs had their p99 in the `+Inf` bucket; `N/A` if no valid run has a p99 (istiod restarted or the scrape failed). CSV/JSON: `churn_convergence_p99_worst` (`overflow` or the range) and `churn_convergence_overflow_runs`. |

**Statuses** that leave a pair out of `valid_runs` include `ERROR_RATE_HIGH` (the
window's HTTP 200 share was below `MIN_PCT_200`, default 0.99; non-200 responses used
to count as latency samples) and `REMOTE_UNREACHABLE` (the sweep's reachability gate
stopped at this combo under `--on-unreachable fail`; no window ran).

**Remote coverage** (section above the results): before each baseline, `002` sends a
few requests from the source's client to every remote's `fortio-server-<remote>`
Service, which selects only that cluster's server (`reach-*.tsv`). The windows use the
merged `fortio-server` Service, where Istio retries a failed request on another
cluster, so a dead remote shows up there only as extra latency. Per remote, `checks
reachable` is how many checks (one per combo) got only HTTP 200s; `coverage` is
`REACHABLE` (all), `FLAPPING` (some), `DEGRADED` (none, but some 200s), `UNREACHABLE`
(no 200) or `UNKNOWN` (the check could not run).
GLOSSARY
}

# _md_kv <field> <value> [plain]: one "| field | value |" row of report_md's run table, the
# value through md_cell, in a code span unless plain.
_md_kv() {
	local _v
	md_cell -v _v "$2"
	if [[ "${3:-}" == plain ]]; then
		printf '| %s | %s |\n' "$1" "$_v"
	else
		# shellcheck disable=SC2016  # a markdown code span, not an expansion
		printf '| %s | `%s` |\n' "$1" "$_v"
	fi
}

report_md() {
	emit_frontmatter
	echo ""
	echo "# sweep-summary"
	echo ""
	[[ -z "$POOLED_NOTE" ]] || printf '> **Pooled runs.** %s\n\n' "$POOLED_NOTE"
	sweep_outcome_recorded "$RESULTS_DIR" md
	echo "| Field | Value |"
	echo "|-------|-------|"
	# Every value escaped (_md_kv): a mixed value joins per-member lists with " | ".
	_md_kv RUN_ID "${RUN_ID:-unknown}"
	_md_kv HARNESS_SHA "${HARNESS_SHA:-unknown}"
	_md_kv HARNESS_CONTENT_KEY "${HARNESS_CONTENT_KEY_STR:-unknown}"
	_md_kv REPORT_HARNESS_SHA "${REPORT_HARNESS_SHA_STR}"
	_md_kv ISTIO_VERSION "${ISTIO_VERSION_STR:-unknown}"
	_md_kv ISTIO_VERSION_SOURCE "${ISTIO_VERSION_SOURCE_STR:-unknown}"
	_md_kv ISTIO_VERSION_PIN "${ISTIO_VERSION_PIN_STR:-unknown}"
	_md_kv ISTIO_VERSION_BY_CONTEXT "${ISTIO_VERSION_BY_CONTEXT_STR:-unknown}"
	_md_kv ISTIO_NOTREADY_AT_START "${ISTIO_NOTREADY_AT_START_STR:-unknown}"
	_md_kv ISTIO_READY_WAITED_SEC "${ISTIO_READY_WAITED_SEC_STR:-unknown}" plain
	_md_kv ISTIO_ACTIVE_REVISIONS "${ISTIO_ACTIVE_REVISIONS_STR:-unknown}"
	_md_kv ISTIO_GENERATIONS "${ISTIO_GENERATIONS_STR:-unknown}"
	_md_kv ISTIO_PROXY_VERSIONS "${ISTIO_PROXY_VERSIONS_STR:-unknown}"
	_md_kv KUBE_VERSIONS "${KUBE_VERSIONS_STR:-unknown}"
	_md_kv TUNING_BASELINE "${TUNING_BASELINE_STR:-unknown}"
	_md_kv SIDECAR_EGRESS_HOSTS "${SIDECAR_EGRESS_HOSTS_STR:-unknown}"
	_md_kv ISTIOD_REPLICAS "${ISTIOD_REPLICAS_STR:-unknown}"
	_md_kv SETTLE_SEC "${SETTLE_SEC_STR:-unknown}" plain
	_md_kv BASELINE_DURATION_SEC "${BASELINE_DURATION_STR:-unknown}" plain
	_md_kv CHURN_DURATION_SEC "${CHURN_DURATION_STR:-unknown}" plain
	_md_kv QPS "${QPS_STR:-unknown}" plain
	_md_kv CONNECTIONS "${CONNECTIONS_STR:-unknown}" plain
	_md_kv NAMESPACE "${NAMESPACE_STR:-unknown}"
	_md_kv FANOUT_MAX_SKEW_MS "${FANOUT_MAX_SKEW_MS_STR:-unknown}" plain
	_md_kv FANOUT_METRICS_TIMEOUT "${FANOUT_METRICS_TIMEOUT_STR:-unknown}" plain
	_md_kv MIN_PCT_200 "${MIN_PCT_200_STR:-unknown}" plain
	_md_kv REACH_REQUESTS "${REACH_REQUESTS_STR:-unknown}" plain
	_md_kv REACH_QPS "${REACH_QPS_STR:-unknown}" plain
	_md_kv REACH_HTTP_TIMEOUT_SEC "${REACH_HTTP_TIMEOUT_SEC_STR:-unknown}" plain
	_md_kv REACH_DETAIL_TIMEOUT_SEC "${REACH_DETAIL_TIMEOUT_SEC_STR:-unknown}" plain
	_md_kv REACH_ATTEMPTS "${REACH_ATTEMPTS_STR:-unknown}" plain
	_md_kv REACH_RETRY_SEC "${REACH_RETRY_SEC_STR:-unknown}" plain
	_md_kv ON_UNREACHABLE "${ON_UNREACHABLE_STR:-unknown}" plain
	_md_kv RUN_CONFIG "${RUN_CONFIG_STR:-unknown}"
	_md_kv RUN_CONFIG_SHA256 "${RUN_CONFIG_SHA256_STR:-unknown}"
	echo ""
	reach_coverage_render md <(printf '%s' "$REACH_ROWS")
	echo ""
	echo "## Results"
	echo ""
	echo "| mesh_size | churn_rate | delta_p99_ms | stdev_delta_p99 | total_runs | valid_runs | baseline_p99_ms | churn_p99_ms | baseline_p50_ms | churn_p50_ms | baseline_qps | churn_qps | churn_eds_pushes | churn_convergence_p99 worst (ms) |"
	echo "|-----------|------------|--------------|-----------------|------------|------------|-----------------|--------------|-----------------|--------------|--------------|-----------|------------------|----------------------------------|"
	# Every cell through md_cell (MD_CELL_AWK, common.sh), as the run table above.
	aggregate | awk -F'\t' '{
		printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", md_cell($1), md_cell($2), md_cell($3), md_cell($4), md_cell($5), md_cell($6), md_cell($7), md_cell($8), md_cell($9), md_cell($10), md_cell($11), md_cell($12), md_cell($13), md_cell(conv_cell($14, $15))
	}
	'"$CONV_CELL_AWK$MD_CELL_AWK"
	echo ""
	istiod_diag_report md "$RESULTS_DIR"

	# #17: metric glossary at the very end of the markdown summary.
	glossary_section
}

report_charts() {
	emit_frontmatter "generated: $(date -u -Iseconds)"
	echo ""
	echo "# Churn x Data-Plane — Charts"
	echo ""
	[[ -z "$POOLED_NOTE" ]] || printf '> **Pooled runs.** %s\n\n' "$POOLED_NOTE"
	local cov_notes
	cov_notes="$(reach_coverage_render charts <(printf '%s' "$REACH_ROWS"))"
	[[ -n "$cov_notes" ]] && printf '%s\n\n' "$cov_notes"
	aggregate | awk -F'\t' '
	# Mermaid xychart cannot draw a gap, so a missing point is never plotted as 0:
	# each chart keeps only the mesh sizes where every churn rate has a value and
	# names the points it left out.
	function chart(n, title, ytitle, key, fmt, expect,    i, c, ms, ok, ax, n_ax, miss) {
		n_ax = 0; miss = ""
		for (i = 1; i <= n_ms; i++) {
			ms = ms_order[i]; ok = 1
			for (c = 1; c <= n_cr; c++) {
				if (!((key, ms, cr_order[c]) in val)) {
					ok = 0
					miss = miss (miss == "" ? "" : ", ") "rate " cr_order[c] " @ mesh " ms
				}
			}
			if (ok) ax[++n_ax] = ms
		}
		printf "%% Chart %d: %s\n\n", n, title
		if (n_ax < 2) {
			printf "> Not charted: fewer than two mesh sizes have data for every churn rate (missing: %s).\n\n", miss
			return 0
		}
		printf "```mermaid\nxychart-beta\n    title \"%s\"\n    x-axis \"Mesh Size\" [", title
		for (i = 1; i <= n_ax; i++) printf "%s%s", (i > 1 ? ", " : ""), ax[i]
		printf "]\n    y-axis \"%s\"\n", ytitle
		for (c = 1; c <= n_cr; c++) {
			printf "    line ["
			for (i = 1; i <= n_ax; i++) printf "%s" fmt, (i > 1 ? ", " : ""), val[key, ax[i], cr_order[c]]
			printf "]\n"
		}
		printf "```\n\n> Series order (by churn rate):"
		for (c = 1; c <= n_cr; c++) printf " **%s**", cr_order[c]
		printf ". Expected: %s\n", expect
		if (miss != "") printf "> Mesh sizes with a missing point are left out (missing: %s).\n", miss
		printf "\n"
		return 1
	}
	{
		ms = $1 + 0; cr = $2 + 0; dp99 = $3; valid = $6 + 0; eds = $13
		# Same gate as report_md: a cell with no valid baseline+churn pairs
		# (valid_runs==0) or whose delta_p99 is N/A is dropped, not charted.
		cells_total++
		if (valid <= 0 || dp99 == "N/A") { cells_dropped++; next }
		if (!(ms in ms_seen)) { ms_order[++n_ms] = ms; ms_seen[ms] = 1 }
		if (!(cr in cr_seen)) { cr_order[++n_cr] = cr; cr_seen[cr] = 1 }
		val["dp99", ms, cr] = dp99 + 0
		if (eds != "N/A") val["eds", ms, cr] = eds + 0
	}
	END {
		if (cells_dropped > 0) {
			printf "> %d of %d cells have no valid samples (failed, restart-poisoned, or skipped on an unreachable remote) — not plotted.\n\n", cells_dropped, cells_total
		}
		# Sort mesh sizes numerically.
		for (i = 2; i <= n_ms; i++) {
			tmp = ms_order[i]; j = i - 1
			while (j >= 1 && ms_order[j]+0 > tmp+0) { ms_order[j+1] = ms_order[j]; j-- }
			ms_order[j+1] = tmp
		}
		# Sort churn rates numerically.
		for (i = 2; i <= n_cr; i++) {
			tmp = cr_order[i]; j = i - 1
			while (j >= 1 && cr_order[j]+0 > tmp+0) { cr_order[j+1] = cr_order[j]; j-- }
			cr_order[j+1] = tmp
		}

		if (n_ms < 2) {
			print "> Charts require at least two mesh sizes."
			exit
		}
		chart(1, "Δp99 Tail Latency vs Mesh Size", "Δp99 (ms)", "dp99", "%.2f", "~flat across mesh size.")
		chart(2, "istiod EDS Pushes vs Mesh Size", "EDS push count", "eds", "%.0f", "scales with churn rate, ~flat across mesh size.")
	}'
}

case "$FORMAT" in
text)          report_text ;;
csv)           report_csv ;;
json)          report_json ;;
md | markdown) report_md ;;
charts)        report_charts ;;
*)             die "unknown format: $FORMAT (use text|csv|json|md|charts)" ;;
esac

# --fail-on-unreachable: after the output, exit 3 and name the rule and remotes.
if ((FAIL_ON_UNREACHABLE)); then
	cov_bad="$(awk -F'\t' 'NF >= 8 && $6 != "REACHABLE" { printf "  rule=reach_coverage mesh_size=%s from %s: %s (%s, %s/%s checks reachable, top_code=%s)\n", $1, $2, $3, $6, $5, $4, $7 }' <<<"$REACH_ROWS")"
	if [[ -n "$cov_bad" ]]; then
		echo "fail-on-unreachable: exit ${REACH_EXIT_CODE}" >&2
		printf '%s\n' "$cov_bad" >&2
		exit "$REACH_EXIT_CODE"
	fi
fi

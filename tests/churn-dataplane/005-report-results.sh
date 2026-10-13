#!/usr/bin/env bash
# Aggregate one or more churn-dataplane TSV files into summary reports.
#
# - Drops rows with status != OK or istiod_restarted in {1, unknown}.
# - Reports n_total and n_valid per combination.
# - Δp99_ms is aggregated only over valid baseline/churn pairs sharing a combo_id
#   within one TSV file.
# - Every output format carries the TSV preamble metadata, and RUN_CONFIG /
#   RUN_CONFIG_SHA256 (the --config behind the inputs) over all input TSVs.
# - Every output format has a "Remote coverage" section from the reach-*.tsv files
#   that 002's reachability check writes (tests/lib/reach.sh).
#
# Usage:
#   ./tests/churn-dataplane/005-report-results.sh [--results-dir DIR] [--format FMT] [--fail-on-unreachable]
#   ./tests/churn-dataplane/005-report-results.sh --config tests/churn-dataplane/configs/smoke.env \
#     --results-dir tests/churn-dataplane/results/smoke/sweep-<RUN_ID> --format md
# ci-dry-run:
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

RESULTS_DIR="$(config_repo_path "${COEXEC_RESULTS_DIR}")"
# 1 when --results-dir is passed (gates the multi-run warning below).
RESULTS_DIR_FROM_FLAG=0
FORMAT="text"
DRY_RUN=0
FAIL_ON_UNREACHABLE=0

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE      Run config of KEY=value lines (config/options.env keys; see
                     tests/churn-dataplane/README.md, "Run config"). Precedence: flag >
                     --config > environment > default. Without --results-dir, warns
                     when the results dir holds more than one run.
  --results-dir DIR  Directory searched recursively for churn-dataplane-*.tsv
                     (default: ${COEXEC_RESULTS_DIR}).
  --format FMT       Output format: text | csv | json | md (or markdown) | charts (default: text).
  --fail-on-unreachable
                     After the output, exit 3 when a remote's reach coverage is not
                     REACHABLE (stderr names the rule and the remotes).
  --dry-run          List the TSV files that would be read, then exit.
  -h, --help         Show this help.

Every format has a "Remote coverage" section from the reach-*.tsv files next to the
TSVs: per mesh size and source, how many remotes passed every reach check
(REACHABLE, FLAPPING, DEGRADED, UNREACHABLE, UNKNOWN per remote). Without reach
files (the check was off, or the TSV predates it) it says "no reachability data".
Rows with any status but OK are left out of valid_runs, ERROR_RATE_HIGH (HTTP 200
share below MIN_PCT_200) and REMOTE_UNREACHABLE (sweep stopped by the gate) included.

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
		RESULTS_DIR="$2"; RESULTS_DIR_FROM_FLAG=1; shift 2 ;;
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
	n=0
	nr=0
	[[ -d "$RESULTS_DIR" ]] && n=$(find "$RESULTS_DIR" -name 'churn-dataplane-*.tsv' -type f | wc -l)
	[[ -d "$RESULTS_DIR" ]] && nr=$(find "$RESULTS_DIR" -name 'reach-*.tsv' -type f | wc -l)
	echo "[dry-run] would summarize $((n)) churn-dataplane-*.tsv file(s) and $((nr)) reach-*.tsv file(s) under $RESULTS_DIR as $FORMAT"
	exit 0
fi

[[ -d "$RESULTS_DIR" ]] || die "results directory not found: $RESULTS_DIR"

# Recurse into sweep-* subdirs as well.
TSV_FILES=()
while IFS= read -r f; do TSV_FILES+=("$f"); done < <(find "$RESULTS_DIR" -name 'churn-dataplane-*.tsv' -type f 2>/dev/null | sort)
((${#TSV_FILES[@]})) || die "no churn-dataplane-*.tsv files in $RESULTS_DIR"

# Extract preamble metadata from the FIRST file (sweeps emit one preamble per file).
extract_preamble_kv() {
	local key="$1" file
	for file in "${TSV_FILES[@]}"; do
		local v
		v="$(awk -v k="$key" -F'=' '
			/^# / && index($0, "# " k "=") == 1 {
				sub(/^# /, "", $0); sub(/^[^=]*=/, "", $0); print; exit
			}' "$file")"
		if [[ -n "$v" ]]; then printf '%s\n' "$v"; return; fi
	done
}

# Warn if multiple TSV files have mismatched preamble configs.
if (( ${#TSV_FILES[@]} > 1 )); then
	_first_qps="$(extract_preamble_kv QPS)"
	_first_dur="$(extract_preamble_kv CHURN_DURATION_SEC)"
	for _tsv in "${TSV_FILES[@]:1}"; do
		_q="$(awk -F'=' '/^# QPS=/ { sub(/^# QPS=/, ""); print; exit }' "$_tsv")"
		_d="$(awk -F'=' '/^# CHURN_DURATION_SEC=/ { sub(/^# CHURN_DURATION_SEC=/, ""); print; exit }' "$_tsv")"
		if [[ -n "$_q" && "$_q" != "$_first_qps" ]] || [[ -n "$_d" && "$_d" != "$_first_dur" ]]; then
			echo "warn: TSV files have mismatched preamble (QPS or DURATION); aggregation may conflate different configurations" >&2
			break
		fi
	done
fi

RUN_ID="$(extract_preamble_kv RUN_ID)"
HARNESS_SHA="$(extract_preamble_kv HARNESS_SHA)"
ISTIO_VERSION_STR="$(extract_preamble_kv ISTIO_VERSION)"
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
# PL6: a results dir from --config (or the default) is a base dir that can hold many
# sweeps, and the report aggregates all of them.
if ((RUN_CONFIG_LOADED)) && ! ((RESULTS_DIR_FROM_FLAG)); then
	config_warn_multi_run "$RESULTS_DIR" "${TSV_FILES[@]}"
fi

# Remote coverage over every reach-*.tsv under RESULTS_DIR (empty without any).
REACH_ROWS="$(reach_coverage_rows "$RESULTS_DIR")"
REACH_NOT_REACHABLE="$(awk -F'\t' 'NF >= 8 && $6 != "REACHABLE" { n++ } END { print n + 0 }' <<<"$REACH_ROWS")"

# The core aggregation pass: build the joined per-(mesh_size, churn_rate) view
# from baseline+churn pairs that share combo_id. Emit a single TSV stream that
# downstream formatters can render. Column order (Δp99 right after the keys, then
# validity counts, then the underlying numbers):
#   mesh_size  churn_rate  delta_p99_ms  stdev_delta_p99  total_runs  valid_runs
#   baseline_p99_ms  churn_p99_ms  baseline_p50_ms  churn_p50_ms
#   baseline_qps  churn_qps  churn_eds_pushes  churn_convergence_p99
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
		if (upper_ms+0 <= 100)   return "0-100ms"
		if (upper_ms+0 <= 500)   return "100-500ms"
		if (upper_ms+0 <= 1000)  return "500-1000ms"
		if (upper_ms+0 <= 3000)  return "1000-3000ms"
		if (upper_ms+0 <= 5000)  return "3000-5000ms"
		if (upper_ms+0 <= 10000) return "5000-10000ms"
		if (upper_ms+0 <= 20000) return "10000-20000ms"
		if (upper_ms+0 <= 30000) return "20000-30000ms"
		return ">30000ms"
	}

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
				ch_conv[combo] = is_num(conv_p99) ? conv_p99 + 0 : "N/A"
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

			s_bp50[rk] += (bl_p50[combo] == "N/A" ? 0 : bl_p50[combo])
			s_bp99[rk] += bl_p99[combo]
			s_cp50[rk] += (ch_p50[combo] == "N/A" ? 0 : ch_p50[combo])
			s_cp99[rk] += ch_p99[combo]
			s_bqps[rk] += (bl_qps[combo] == "N/A" ? 0 : bl_qps[combo])
			s_cqps[rk] += (ch_qps[combo] == "N/A" ? 0 : ch_qps[combo])

			if (ch_eds[combo] != "N/A") { s_ceds[rk] += ch_eds[combo]; n_ceds[rk]++ }
			if (ch_conv[combo] != "N/A") { s_cconv[rk] += ch_conv[combo]; n_cconv[rk]++ }
		}

		for (rk in total) {
			tot_pairs = total[rk]
			nv = (rk in n_valid) ? n_valid[rk] : 0
			if (nv > 0) {
				stdev = (nv >= 2) ? sprintf("%.2f", sqrt(m2_dp99[rk] / (nv - 1))) : "N/A"
				ch_eds_avg = (rk in n_ceds && n_ceds[rk] > 0) ? sprintf("%.0f", s_ceds[rk]/n_ceds[rk]) : "N/A"
				ch_conv_avg = (rk in n_cconv && n_cconv[rk] > 0) ? bucket_range(s_cconv[rk]/n_cconv[rk]) : "N/A"
				printf "%s\t%.2f\t%s\t%d\t%d\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%s\t%s\n",
					rk,
					s_dp99[rk]/nv, stdev,
					tot_pairs, nv,
					s_bp99[rk]/nv, s_cp99[rk]/nv,
					s_bp50[rk]/nv, s_cp50[rk]/nv,
					s_bqps[rk]/nv, s_cqps[rk]/nv,
					ch_eds_avg, ch_conv_avg
			} else {
				printf "%s\tN/A\tN/A\t%d\t0\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\n", rk, tot_pairs
			}
		}
	}' "${TSV_FILES[@]}" | sort -k1,1n -k2,2n
}

emit_metadata_lines() {
	local prefix="${1:-#}"
	printf '%s RUN_ID=%s\n'                "$prefix" "${RUN_ID:-unknown}"
	printf '%s HARNESS_SHA=%s\n'           "$prefix" "${HARNESS_SHA:-unknown}"
	printf '%s ISTIO_VERSION=%s\n'         "$prefix" "${ISTIO_VERSION_STR:-unknown}"
	printf '%s KUBE_VERSIONS=%s\n'         "$prefix" "${KUBE_VERSIONS_STR:-unknown}"
	printf '%s TUNING_BASELINE=%s\n'       "$prefix" "${TUNING_BASELINE_STR:-unknown}"
	printf '%s SIDECAR_EGRESS_HOSTS=%s\n'  "$prefix" "${SIDECAR_EGRESS_HOSTS_STR:-unknown}"
	printf '%s ISTIOD_REPLICAS=%s\n'       "$prefix" "${ISTIOD_REPLICAS_STR:-unknown}"
	printf '%s SETTLE_SEC=%s\n'            "$prefix" "${SETTLE_SEC_STR:-unknown}"
	printf '%s BASELINE_DURATION_SEC=%s\n' "$prefix" "${BASELINE_DURATION_STR:-unknown}"
	printf '%s CHURN_DURATION_SEC=%s\n'    "$prefix" "${CHURN_DURATION_STR:-unknown}"
	printf '%s QPS=%s\n'                   "$prefix" "${QPS_STR:-unknown}"
	printf '%s CONNECTIONS=%s\n'           "$prefix" "${CONNECTIONS_STR:-unknown}"
	printf '%s NAMESPACE=%s\n'             "$prefix" "${NAMESPACE_STR:-unknown}"
	printf '%s FANOUT_MAX_SKEW_MS=%s\n'    "$prefix" "${FANOUT_MAX_SKEW_MS_STR:-unknown}"
	printf '%s FANOUT_METRICS_TIMEOUT=%s\n' "$prefix" "${FANOUT_METRICS_TIMEOUT_STR:-unknown}"
	printf '%s MIN_PCT_200=%s\n'           "$prefix" "${MIN_PCT_200_STR:-unknown}"
	printf '%s REACH_REQUESTS=%s\n'        "$prefix" "${REACH_REQUESTS_STR:-unknown}"
	printf '%s REACH_QPS=%s\n'             "$prefix" "${REACH_QPS_STR:-unknown}"
	printf '%s REACH_HTTP_TIMEOUT_SEC=%s\n' "$prefix" "${REACH_HTTP_TIMEOUT_SEC_STR:-unknown}"
	printf '%s REACH_DETAIL_TIMEOUT_SEC=%s\n' "$prefix" "${REACH_DETAIL_TIMEOUT_SEC_STR:-unknown}"
	printf '%s REACH_ATTEMPTS=%s\n'        "$prefix" "${REACH_ATTEMPTS_STR:-unknown}"
	printf '%s REACH_RETRY_SEC=%s\n'       "$prefix" "${REACH_RETRY_SEC_STR:-unknown}"
	printf '%s ON_UNREACHABLE=%s\n'        "$prefix" "${ON_UNREACHABLE_STR:-unknown}"
	printf '%s RUN_CONFIG=%s\n'            "$prefix" "${RUN_CONFIG_STR:-unknown}"
	printf '%s RUN_CONFIG_SHA256=%s\n'     "$prefix" "${RUN_CONFIG_SHA256_STR:-unknown}"
}

report_text() {
	echo "=== sweep-summary ==="
	emit_metadata_lines "#"
	echo ""
	reach_coverage_render text <(printf '%s' "$REACH_ROWS")
	echo ""
	printf '  %-9s | %-10s | %14s | %15s | %-10s | %-10s | %15s | %15s | %15s | %15s | %12s | %12s | %18s | %22s\n' \
		"mesh_size" "churn_rate" "delta_p99_ms" "stdev_delta_p99" "total_runs" "valid_runs" \
		"baseline_p99_ms" "churn_p99_ms" "baseline_p50_ms" "churn_p50_ms" "baseline_qps" "churn_qps" \
		"churn_eds_pushes" "churn_convergence_p99"
	printf '  %-9s-+-%-10s-+-%14s-+-%15s-+-%-10s-+-%-10s-+-%15s-+-%15s-+-%15s-+-%15s-+-%12s-+-%12s-+-%18s-+-%22s\n' \
		"---------" "----------" "--------------" "---------------" "----------" "----------" \
		"---------------" "---------------" "---------------" "---------------" "------------" "------------" \
		"------------------" "----------------------"
	aggregate | awk -F'\t' '{
		printf "  %-9s | %-10s | %14s | %15s | %-10s | %-10s | %15s | %15s | %15s | %15s | %12s | %12s | %18s | %22s\n", \
			$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14
	}'
}

report_csv() {
	emit_metadata_lines "#"
	reach_coverage_render csv <(printf '%s' "$REACH_ROWS")
	echo "mesh_size,churn_rate,delta_p99_ms,stdev_delta_p99,total_runs,valid_runs,baseline_p99_ms,churn_p99_ms,baseline_p50_ms,churn_p50_ms,baseline_qps,churn_qps,churn_eds_pushes,churn_convergence_p99"
	aggregate | awk -F'\t' '{ printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14 }'
}

report_json() {
	local rows
	rows="$(aggregate | awk -F'\t' '
		BEGIN { first=1; printf "[" }
		{
			if (!first) printf ",";
			first=0
			printf "{\"mesh_size\":%s,\"churn_rate\":%s,\"delta_p99_ms\":\"%s\",\"stdev_delta_p99\":\"%s\",\"total_runs\":%s,\"valid_runs\":%s,\"baseline_p99_ms\":\"%s\",\"churn_p99_ms\":\"%s\",\"baseline_p50_ms\":\"%s\",\"churn_p50_ms\":\"%s\",\"baseline_qps\":\"%s\",\"churn_qps\":\"%s\",\"churn_eds_pushes\":\"%s\",\"churn_convergence_p99\":\"%s\"}",
				$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14
		}
		END { printf "]" }')"
	jq -n \
		--arg run_id           "${RUN_ID:-unknown}" \
		--arg harness_sha      "${HARNESS_SHA:-unknown}" \
		--arg istio_version    "${ISTIO_VERSION_STR:-unknown}" \
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
		--argjson rows         "$rows" \
		'{metadata: {run_id: $run_id, harness_sha: $harness_sha, istio_version: $istio_version, kube_versions: $kube_versions, tuning_baseline: $tuning_baseline, sidecar_egress_hosts: $sidecar_egress_hosts, istiod_replicas: $istiod_replicas, settle_sec: $settle_sec, baseline_duration_sec: $baseline_dur, churn_duration_sec: $churn_dur, qps: $qps, connections: $connections, namespace: $namespace, fanout_max_skew_ms: $fanout_max_skew, fanout_metrics_timeout: $fanout_metrics_timeout, min_pct_200: $min_pct_200, reach_requests: $reach_requests, reach_qps: $reach_qps, reach_http_timeout_sec: $reach_http_timeout_sec, reach_detail_timeout_sec: $reach_detail_timeout_sec, reach_attempts: $reach_attempts, reach_retry_sec: $reach_retry_sec, on_unreachable: $on_unreachable, run_config: $run_config, run_config_sha256: $run_config_sha256}, summary: {remotes_not_reachable: $not_reachable}, remote_coverage: $remote_coverage.remote_coverage, rows: $rows}'
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
| `baseline_p50_ms` / `churn_p50_ms` | ms | Fortio JSON `DurationHistogram.Percentiles[50]` | p50 latency in the baseline / churn phase. |
| `baseline_qps` / `churn_qps` | queries/s | Fortio JSON `ActualQPS` | Achieved QPS in the baseline / churn phase; churn QPS may drop under control-plane contention. |
| `churn_eds_pushes` | count (delta) | `pilot_xds_pushes{type="eds"}` counter delta | EDS pushes triggered during the churn phase; `N/A` if istiod restarted or the scrape failed. |
| `churn_convergence_p99` | ms (bucket range) | `pilot_proxy_convergence_time` histogram delta | p99 convergence during churn, reported as a **bucket range** (e.g. `0-100ms`), not an exact value; `N/A` if istiod restarted or the scrape failed. |

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

report_md() {
	echo "# sweep-summary"
	echo ""
	echo "| Field | Value |"
	echo "|-------|-------|"
	echo "| RUN_ID | \`${RUN_ID:-unknown}\` |"
	echo "| HARNESS_SHA | \`${HARNESS_SHA:-unknown}\` |"
	echo "| ISTIO_VERSION | \`${ISTIO_VERSION_STR:-unknown}\` |"
	echo "| KUBE_VERSIONS | \`${KUBE_VERSIONS_STR:-unknown}\` |"
	echo "| TUNING_BASELINE | \`${TUNING_BASELINE_STR:-unknown}\` |"
	echo "| SIDECAR_EGRESS_HOSTS | \`${SIDECAR_EGRESS_HOSTS_STR:-unknown}\` |"
	echo "| ISTIOD_REPLICAS | \`${ISTIOD_REPLICAS_STR:-unknown}\` |"
	echo "| SETTLE_SEC | ${SETTLE_SEC_STR:-unknown} |"
	echo "| BASELINE_DURATION_SEC | ${BASELINE_DURATION_STR:-unknown} |"
	echo "| CHURN_DURATION_SEC | ${CHURN_DURATION_STR:-unknown} |"
	echo "| QPS | ${QPS_STR:-unknown} |"
	echo "| CONNECTIONS | ${CONNECTIONS_STR:-unknown} |"
	echo "| NAMESPACE | \`${NAMESPACE_STR:-unknown}\` |"
	echo "| FANOUT_MAX_SKEW_MS | ${FANOUT_MAX_SKEW_MS_STR:-unknown} |"
	echo "| FANOUT_METRICS_TIMEOUT | ${FANOUT_METRICS_TIMEOUT_STR:-unknown} |"
	echo "| MIN_PCT_200 | ${MIN_PCT_200_STR:-unknown} |"
	echo "| REACH_REQUESTS | ${REACH_REQUESTS_STR:-unknown} |"
	echo "| REACH_QPS | ${REACH_QPS_STR:-unknown} |"
	echo "| REACH_HTTP_TIMEOUT_SEC | ${REACH_HTTP_TIMEOUT_SEC_STR:-unknown} |"
	echo "| REACH_DETAIL_TIMEOUT_SEC | ${REACH_DETAIL_TIMEOUT_SEC_STR:-unknown} |"
	echo "| REACH_ATTEMPTS | ${REACH_ATTEMPTS_STR:-unknown} |"
	echo "| REACH_RETRY_SEC | ${REACH_RETRY_SEC_STR:-unknown} |"
	echo "| ON_UNREACHABLE | ${ON_UNREACHABLE_STR:-unknown} |"
	echo "| RUN_CONFIG | \`${RUN_CONFIG_STR:-unknown}\` |"
	echo "| RUN_CONFIG_SHA256 | \`${RUN_CONFIG_SHA256_STR:-unknown}\` |"
	echo ""
	reach_coverage_render md <(printf '%s' "$REACH_ROWS")
	echo ""
	echo "## Results"
	echo ""
	echo "| mesh_size | churn_rate | delta_p99_ms | stdev_delta_p99 | total_runs | valid_runs | baseline_p99_ms | churn_p99_ms | baseline_p50_ms | churn_p50_ms | baseline_qps | churn_qps | churn_eds_pushes | churn_convergence_p99 |"
	echo "|-----------|------------|--------------|-----------------|------------|------------|-----------------|--------------|-----------------|--------------|--------------|-----------|------------------|------------------------|"
	aggregate | awk -F'\t' '{
		printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14
	}'

	# #17: metric glossary at the very end of the markdown summary.
	glossary_section
}

report_charts() {
	echo "---"
	emit_metadata_lines "##"
	echo "generated: $(date -u -Iseconds)"
	echo "---"
	echo ""
	echo "# Churn x Data-Plane — Charts"
	echo ""
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

#!/usr/bin/env bash
# Aggregate one or more churn-dataplane TSV files into summary reports.
#
# - Filters rows with status != OK (POISONED_RESTART, CLEANUP_TIMEOUT, etc.)
#   and rows with istiod_restarted in {1, unknown} (PL9, PL15).
# - Reports both n_total and n_valid per combination (PL15).
# - Δp99_ms aggregate is computed only over valid baseline/churn pairs that
#   share a combo_id (PL15, PL20).
# - All preamble metadata (RUN_ID, HARNESS_SHA, ISTIO_VERSION, KUBE_VERSIONS,
#   ISTIOD_REPLICAS, SETTLE_SEC, BASELINE_DURATION_SEC, CHURN_DURATION_SEC, QPS,
#   CONNECTIONS, NAMESPACE) is propagated to all four output formats (PL19).
#
# Usage:
#   ./tests/churn-dataplane/005-report-results.sh [--results-dir DIR]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"

RESULTS_DIR="${ROOT}/tests/churn-dataplane/results"
FORMAT="text"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --results-dir DIR  Directory containing coexec-*.tsv files. Searched recursively,
                     including \`sweep-*\` subdirs. Default: \`tests/churn-dataplane/results\`
                     relative to the repo root (resolved at script start via
                     \$(cd "\$(dirname "\$0")/../.." && pwd)).
  --format FMT       Output format: text | csv | json | md (default: text). PL19: all four
                     propagate the preamble metadata.
  -h, --help         Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--results-dir)
		[[ -n "${2:-}" ]] || die "--results-dir requires a value"
		RESULTS_DIR="$2"; shift 2 ;;
	--format)
		[[ -n "${2:-}" ]] || die "--format requires a value"
		FORMAT="$2"; shift 2 ;;
	-h | --help)
		usage; exit 0 ;;
	*)
		die "unknown option: $1 (try --help)" ;;
	esac
done

[[ -d "$RESULTS_DIR" ]] || die "results directory not found: $RESULTS_DIR"

# Recurse into sweep-* subdirs as well.
TSV_FILES=()
while IFS= read -r f; do TSV_FILES+=("$f"); done < <(find "$RESULTS_DIR" \( -name 'churn-dataplane-*.tsv' -o -name 'coexec-*.tsv' \) -type f 2>/dev/null | sort)
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
ISTIOD_REPLICAS_STR="$(extract_preamble_kv ISTIOD_REPLICAS)"
SETTLE_SEC_STR="$(extract_preamble_kv SETTLE_SEC)"
BASELINE_DURATION_STR="$(extract_preamble_kv BASELINE_DURATION_SEC)"
CHURN_DURATION_STR="$(extract_preamble_kv CHURN_DURATION_SEC)"
QPS_STR="$(extract_preamble_kv QPS)"
CONNECTIONS_STR="$(extract_preamble_kv CONNECTIONS)"
NAMESPACE_STR="$(extract_preamble_kv NAMESPACE)"

# The core aggregation pass: build the joined per-(mesh_size, churn_rate) view
# from baseline+churn pairs that share combo_id. Emit a single TSV stream that
# downstream formatters can render. Column order (A7 — Δp99 immediately after
# the keys, then validity counts, then the underlying numbers):
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
		combo = $3; ms = $4; cr = $5; phase = $6
		qps_actual = $9; p50 = $10; p99 = $12; restarted = $16; status = $17

		# istiod-side metrics (columns 20-25, present when NF >= 25).
		xds_pushes = (NF >= 20) ? $20 : "N/A"
		eds_pushes = (NF >= 21) ? $21 : "N/A"
		conv_p99   = (NF >= 23) ? $23 : "N/A"

		valid = is_valid_row(restarted, status)
		if (phase == "baseline") {
			bl_seen[combo] = 1
			bl_status[combo] = (valid ? "ok" : "bad")
			if (valid) {
				bl_p50[combo] = is_num(p50) ? p50 + 0 : "N/A"
				bl_p99[combo] = is_num(p99) ? p99 + 0 : "N/A"
				bl_qps[combo] = is_num(qps_actual) ? qps_actual + 0 : "N/A"
				bl_ms[combo] = ms
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
	# PL19: every format gets all preamble metadata.
	local prefix="${1:-#}"
	printf '%s RUN_ID=%s\n'                "$prefix" "${RUN_ID:-unknown}"
	printf '%s HARNESS_SHA=%s\n'           "$prefix" "${HARNESS_SHA:-unknown}"
	printf '%s ISTIO_VERSION=%s\n'         "$prefix" "${ISTIO_VERSION_STR:-unknown}"
	printf '%s KUBE_VERSIONS=%s\n'         "$prefix" "${KUBE_VERSIONS_STR:-unknown}"
	printf '%s ISTIOD_REPLICAS=%s\n'       "$prefix" "${ISTIOD_REPLICAS_STR:-unknown}"
	printf '%s SETTLE_SEC=%s\n'            "$prefix" "${SETTLE_SEC_STR:-unknown}"
	printf '%s BASELINE_DURATION_SEC=%s\n' "$prefix" "${BASELINE_DURATION_STR:-unknown}"
	printf '%s CHURN_DURATION_SEC=%s\n'    "$prefix" "${CHURN_DURATION_STR:-unknown}"
	printf '%s QPS=%s\n'                   "$prefix" "${QPS_STR:-unknown}"
	printf '%s CONNECTIONS=%s\n'           "$prefix" "${CONNECTIONS_STR:-unknown}"
	printf '%s NAMESPACE=%s\n'             "$prefix" "${NAMESPACE_STR:-unknown}"
}

report_text() {
	echo "=== sweep-summary ==="
	emit_metadata_lines "#"
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
		--arg istiod_replicas  "${ISTIOD_REPLICAS_STR:-unknown}" \
		--arg settle_sec       "${SETTLE_SEC_STR:-unknown}" \
		--arg baseline_dur     "${BASELINE_DURATION_STR:-unknown}" \
		--arg churn_dur        "${CHURN_DURATION_STR:-unknown}" \
		--arg qps              "${QPS_STR:-unknown}" \
		--arg connections      "${CONNECTIONS_STR:-unknown}" \
		--arg namespace        "${NAMESPACE_STR:-unknown}" \
		--argjson rows         "$rows" \
		'{metadata: {run_id: $run_id, harness_sha: $harness_sha, istio_version: $istio_version, kube_versions: $kube_versions, istiod_replicas: $istiod_replicas, settle_sec: $settle_sec, baseline_duration_sec: $baseline_dur, churn_duration_sec: $churn_dur, qps: $qps, connections: $connections, namespace: $namespace}, rows: $rows}'
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
	echo "| ISTIOD_REPLICAS | \`${ISTIOD_REPLICAS_STR:-unknown}\` |"
	echo "| SETTLE_SEC | ${SETTLE_SEC_STR:-unknown} |"
	echo "| BASELINE_DURATION_SEC | ${BASELINE_DURATION_STR:-unknown} |"
	echo "| CHURN_DURATION_SEC | ${CHURN_DURATION_STR:-unknown} |"
	echo "| QPS | ${QPS_STR:-unknown} |"
	echo "| CONNECTIONS | ${CONNECTIONS_STR:-unknown} |"
	echo "| NAMESPACE | \`${NAMESPACE_STR:-unknown}\` |"
	echo ""
	echo "| mesh_size | churn_rate | delta_p99_ms | stdev_delta_p99 | total_runs | valid_runs | baseline_p99_ms | churn_p99_ms | baseline_p50_ms | churn_p50_ms | baseline_qps | churn_qps | churn_eds_pushes | churn_convergence_p99 |"
	echo "|-----------|------------|--------------|-----------------|------------|------------|-----------------|--------------|-----------------|--------------|--------------|-----------|------------------|------------------------|"
	aggregate | awk -F'\t' '{
		printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14
	}'
}

case "$FORMAT" in
text) report_text ;;
csv)  report_csv ;;
json) report_json ;;
md)   report_md ;;
*)    die "unknown format: $FORMAT (use text|csv|json|md)" ;;
esac

#!/usr/bin/env bash
# Aggregate one or more churn-dataplane TSV files into summary reports.
#
# - Filters rows with status != OK (POISONED_RESTART, CLEANUP_TIMEOUT, etc.)
#   and rows with istiod_restarted in {1, unknown} (PL9, PL15).
# - Reports both n_total and n_valid per combination (PL15).
# - Δp99_ms aggregate is computed only over valid baseline/churn pairs that
#   share a combo_id (PL15, PL20).
# - All preamble metadata (RUN_ID, HARNESS_SHA, ISTIO_VERSION, KUBE_VERSIONS,
#   SETTLE_SEC, BASELINE_DURATION_SEC, CHURN_DURATION_SEC) is propagated to all
#   four output formats (PL19).
#
# Usage:
#   ./tests/churn-dataplane/005-report-results.sh [--results-dir DIR]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

RESULTS_DIR="${ROOT}/tests/churn-dataplane/results"
FORMAT="text"

die() { echo "error: $*" >&2; exit 1; }

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
while IFS= read -r f; do TSV_FILES+=("$f"); done < <(find "$RESULTS_DIR" -name 'coexec-*.tsv' -type f 2>/dev/null | sort)
((${#TSV_FILES[@]})) || die "no coexec-*.tsv files in $RESULTS_DIR"

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

RUN_ID="$(extract_preamble_kv RUN_ID)"
HARNESS_SHA="$(extract_preamble_kv HARNESS_SHA)"
ISTIO_VERSION_STR="$(extract_preamble_kv ISTIO_VERSION)"
KUBE_VERSIONS_STR="$(extract_preamble_kv KUBE_VERSIONS)"
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
#   mesh_size  churn_rate  delta_p99  n_total  n_valid  baseline_p99  churn_p99  baseline_p50  churn_p50  baseline_qps  churn_qps
# A6: schema header is "Δp99_ms (endpoint-churn)" — this suite measures
# endpoint-churn only (deployment scale -> EDS pushes), not CDS/LDS/sidecar
# restarts.
aggregate() {
	awk -F'\t' '
	function is_valid_row(restarted, status,    bad) {
		# PL15: filter restarted=1, restarted=unknown, and any non-OK status.
		# A4 (CHURN_RATE_NOT_MET): driver could not keep up; the latency
		# numbers might be honest but the rate label is a lie, so filter.
		if (status != "OK") return 0
		if (restarted == "1" || restarted == "unknown") return 0
		return 1
	}
	function safe_num(x) { return (x == "N/A" || x == "" ) ? 0 : x + 0 }

	# Header line skipped; comments skipped. NF guard accepts both the
	# legacy 17-col schema and the new 19-col schema (A4 added two columns).
	!/^#/ && !/^run_id/ && NF >= 17 {
		combo = $3; ms = $4; cr = $5; phase = $6
		qps_actual = $9; p50 = $10; p99 = $12; restarted = $16; status = $17

		valid = is_valid_row(restarted, status)
		if (phase == "baseline") {
			bl_seen[combo] = 1
			bl_status[combo] = (valid ? "ok" : "bad")
			if (valid) {
				bl_p50[combo] = safe_num(p50)
				bl_p99[combo] = safe_num(p99)
				bl_qps[combo] = safe_num(qps_actual)
				bl_ms[combo] = ms
			}
		} else if (phase == "churn") {
			ch_seen[combo] = 1
			ch_status[combo] = (valid ? "ok" : "bad")
			# Churn-phase row carries the canonical churn_rate for this combo;
			# baseline is always cr=0 by construction, so we key on the churn row.
			ch_ms[combo] = ms
			ch_cr[combo] = cr
			if (valid) {
				ch_p50[combo] = safe_num(p50)
				ch_p99[combo] = safe_num(p99)
				ch_qps[combo] = safe_num(qps_actual)
			}
		}
		# Ignore other phases (e.g. "cleanup") for percentile aggregation.
	}
	END {
		# Build per-(mesh_size, churn_rate) totals: every combo with at least one
		# of {baseline, churn} rows counts toward n_total for that (ms, cr).
		for (combo in ch_seen) {
			rk = ch_ms[combo] "\t" ch_cr[combo]
			total[rk]++
		}
		# Edge case: baseline-only combos with no churn row still need a slot.
		# Match them to a churn_rate=0 bucket so they are reported but as 0 valid.
		for (combo in bl_seen) {
			if (combo in ch_seen) continue
			rk = bl_ms[combo] "\t0"
			total[rk]++
		}

		# Join on combo_id: both phases must be present AND both valid.
		for (combo in bl_seen) {
			if (bl_status[combo] != "ok") continue
			if (!(combo in ch_seen) || ch_status[combo] != "ok") continue
			rk = ch_ms[combo] "\t" ch_cr[combo]
			n_valid[rk]++
			s_bp50[rk] += bl_p50[combo]
			s_bp99[rk] += bl_p99[combo]
			s_cp50[rk] += ch_p50[combo]
			s_cp99[rk] += ch_p99[combo]
			s_dp99[rk] += (ch_p99[combo] - bl_p99[combo])
			s_bqps[rk] += bl_qps[combo]
			s_cqps[rk] += ch_qps[combo]
		}

		# A7: emit columns with delta_p99 right after the keys.
		# mesh_size  churn_rate  delta_p99  n_total  n_valid
		#   baseline_p99  churn_p99  baseline_p50  churn_p50  baseline_qps  churn_qps
		for (rk in total) {
			tot_pairs = total[rk]
			nv = (rk in n_valid) ? n_valid[rk] : 0
			if (nv > 0) {
				printf "%s\t%.2f\t%d\t%d\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\n",
					rk,
					s_dp99[rk]/nv,
					tot_pairs, nv,
					s_bp99[rk]/nv, s_cp99[rk]/nv,
					s_bp50[rk]/nv, s_cp50[rk]/nv,
					s_bqps[rk]/nv, s_cqps[rk]/nv
			} else {
				printf "%s\tN/A\t%d\t0\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\n", rk, tot_pairs
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
	printf '%s SETTLE_SEC=%s\n'            "$prefix" "${SETTLE_SEC_STR:-unknown}"
	printf '%s BASELINE_DURATION_SEC=%s\n' "$prefix" "${BASELINE_DURATION_STR:-unknown}"
	printf '%s CHURN_DURATION_SEC=%s\n'    "$prefix" "${CHURN_DURATION_STR:-unknown}"
	printf '%s QPS=%s\n'                   "$prefix" "${QPS_STR:-unknown}"
	printf '%s CONNECTIONS=%s\n'           "$prefix" "${CONNECTIONS_STR:-unknown}"
	printf '%s NAMESPACE=%s\n'             "$prefix" "${NAMESPACE_STR:-unknown}"
}

report_text() {
	echo "=== churn-dataplane co-exec summary ==="
	emit_metadata_lines "#"
	echo ""
	# A7: column order is mesh_size, churn_rate, Δp99 (endpoint-churn),
	# n_total, n_valid, baseline_p99, churn_p99, baseline_p50, churn_p50,
	# baseline_qps, churn_qps.
	printf '  %-9s | %-9s | %14s | %-8s | %-8s | %10s | %10s | %10s | %10s | %10s | %10s\n' \
		"mesh_size" "churn_rate" "Δp99_ms (ec)" "n_total" "n_valid" \
		"bl_p99_ms" "ch_p99_ms" "bl_p50_ms" "ch_p50_ms" "bl_qps" "ch_qps"
	printf '  %-9s-+-%-9s-+-%14s-+-%-8s-+-%-8s-+-%10s-+-%10s-+-%10s-+-%10s-+-%10s-+-%10s\n' \
		"---------" "---------" "--------------" "--------" "--------" \
		"----------" "----------" "----------" "----------" "----------" "----------"
	aggregate | awk -F'\t' '{
		printf "  %-9s | %-9s | %14s | %-8s | %-8s | %10s | %10s | %10s | %10s | %10s | %10s\n", \
			$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11
	}'
}

report_csv() {
	emit_metadata_lines "#"
	echo "mesh_size,churn_rate,delta_p99_ms,n_total,n_valid,baseline_p99_ms,churn_p99_ms,baseline_p50_ms,churn_p50_ms,baseline_qps_actual,churn_qps_actual"
	aggregate | awk -F'\t' '{ printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11 }'
}

report_json() {
	# Construct a JSON object with metadata + rows. A7 ordering.
	local rows
	rows="$(aggregate | awk -F'\t' '
		BEGIN { first=1; printf "[" }
		{
			if (!first) printf ",";
			first=0
			printf "{\"mesh_size\":%s,\"churn_rate\":%s,\"delta_p99_ms\":\"%s\",\"n_total\":%s,\"n_valid\":%s,\"baseline_p99_ms\":\"%s\",\"churn_p99_ms\":\"%s\",\"baseline_p50_ms\":\"%s\",\"churn_p50_ms\":\"%s\",\"baseline_qps_actual\":\"%s\",\"churn_qps_actual\":\"%s\"}",
				$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11
		}
		END { printf "]" }')"
	jq -n \
		--arg run_id           "${RUN_ID:-unknown}" \
		--arg harness_sha      "${HARNESS_SHA:-unknown}" \
		--arg istio_version    "${ISTIO_VERSION_STR:-unknown}" \
		--arg kube_versions    "${KUBE_VERSIONS_STR:-unknown}" \
		--arg settle_sec       "${SETTLE_SEC_STR:-unknown}" \
		--arg baseline_dur     "${BASELINE_DURATION_STR:-unknown}" \
		--arg churn_dur        "${CHURN_DURATION_STR:-unknown}" \
		--arg qps              "${QPS_STR:-unknown}" \
		--arg connections      "${CONNECTIONS_STR:-unknown}" \
		--arg namespace        "${NAMESPACE_STR:-unknown}" \
		--argjson rows         "$rows" \
		'{metadata: {run_id: $run_id, harness_sha: $harness_sha, istio_version: $istio_version, kube_versions: $kube_versions, settle_sec: $settle_sec, baseline_duration_sec: $baseline_dur, churn_duration_sec: $churn_dur, qps: $qps, connections: $connections, namespace: $namespace}, rows: $rows}'
}

report_md() {
	echo "# churn-dataplane co-exec summary"
	echo ""
	echo "| Field | Value |"
	echo "|-------|-------|"
	echo "| RUN_ID | \`${RUN_ID:-unknown}\` |"
	echo "| HARNESS_SHA | \`${HARNESS_SHA:-unknown}\` |"
	echo "| ISTIO_VERSION | \`${ISTIO_VERSION_STR:-unknown}\` |"
	echo "| KUBE_VERSIONS | \`${KUBE_VERSIONS_STR:-unknown}\` |"
	echo "| SETTLE_SEC | ${SETTLE_SEC_STR:-unknown} |"
	echo "| BASELINE_DURATION_SEC | ${BASELINE_DURATION_STR:-unknown} |"
	echo "| CHURN_DURATION_SEC | ${CHURN_DURATION_STR:-unknown} |"
	echo "| QPS | ${QPS_STR:-unknown} |"
	echo "| CONNECTIONS | ${CONNECTIONS_STR:-unknown} |"
	echo "| NAMESPACE | \`${NAMESPACE_STR:-unknown}\` |"
	echo ""
	# A7: Δp99 immediately after keys. A6: "(endpoint-churn)" qualifier.
	echo "| mesh_size | churn_rate | Δp99_ms (endpoint-churn) | n_total | n_valid | baseline_p99_ms | churn_p99_ms | baseline_p50_ms | churn_p50_ms | baseline_qps | churn_qps |"
	echo "|-----------|------------|--------------------------|---------|---------|-----------------|--------------|-----------------|--------------|--------------|-----------|"
	aggregate | awk -F'\t' '{
		printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11
	}'
}

case "$FORMAT" in
text) report_text ;;
csv)  report_csv ;;
json) report_json ;;
md)   report_md ;;
*)    die "unknown format: $FORMAT (use text|csv|json|md)" ;;
esac

#!/usr/bin/env bash
# Generate summary statistics from data-plane latency TSV files.
#
# Aggregates by (mesh_size, qps_target, target_class) — so local and remote
# rows are reported separately rather than averaged together.
# Filters poisoned rows (status != OK, istiod_restarted != 0) from numeric
# aggregation but still counts them in count_total and reports the gap.
# Propagates the first TSV's preamble metadata into all four output formats.
#
# Usage:
#   ./tests/dataplane/004-report-results.sh [--results-dir DIR] [--format FMT]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"

RESULTS_DIR="${ROOT}/tests/dataplane/results"
FORMAT="text"


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --results-dir DIR  Results directory (default: tests/dataplane/results).
                     A directory containing latency-*.tsv files; a sweep-*/
                     subdir from 003 also works.
  --format FMT       Output format: text, csv, markdown, json (default: text).
  -h, --help         Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--results-dir)
		[[ -n "${2:-}" ]] || die "--results-dir requires a value"
		RESULTS_DIR="$2"
		shift 2
		;;
	--format)
		[[ -n "${2:-}" ]] || die "--format requires a value"
		FORMAT="$2"
		shift 2
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
text|csv|markdown|json) ;;
*) die "unknown format: $FORMAT (use text, csv, markdown, or json)" ;;
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

# AWK aggregation: group by (mesh_size, qps_target, target_class).
# Counts:
#   count_total — any row with NF>=17
#   count_valid — status==OK && istiod_restarted==0
# Numeric aggregations use only valid rows.
# shellcheck disable=SC2016
AGG_SCRIPT='
BEGIN { OFS="\t" }
/^#/ { next }
/^run_id\t/ { next }
NF < 17 { next }
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

# Compute drop summary: total rows, valid rows.
read -r TOTAL_ALL VALID_ALL < <(awk -F'\t' '
	{
		t += $4 + 0
		v += $5 + 0
	}
	END { print t, v }
' <<<"$AGG_TSV")
DROPPED_ALL=$(( TOTAL_ALL - VALID_ALL ))

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
	printf "  %-4s | %-6s | %-6s | %5s | %5s | %10s | %10s | %10s | %10s | %10s | %7s\n" \
		"Sz" "QPS" "Class" "n_tot" "n_val" "p50 (ms)" "p90 (ms)" "p99 (ms)" "max (ms)" "actual QPS" "pct_200"
	printf "  %-4s-+-%-6s-+-%-6s-+-%5s-+-%5s-+-%10s-+-%10s-+-%10s-+-%10s-+-%10s-+-%7s\n" \
		"----" "------" "------" "-----" "-----" "----------" "----------" "----------" "----------" "----------" "-------"
	while IFS=$'\t' read -r mesh qps cls n_tot n_val p50 p90 p99 _p999 mx qa pct; do
		printf "  %-4s | %-6s | %-6s | %5s | %5s | %10s | %10s | %10s | %10s | %10s | %7s\n" \
			"$mesh" "$qps" "$cls" "$n_tot" "$n_val" \
			"$(fmt_val "$p50")" "$(fmt_val "$p90")" "$(fmt_val "$p99")" \
			"$(fmt_val "$mx")" "$(fmt_val "$qa" 1)" "$(fmt_val "$pct" 4)"
	done <<<"$AGG_TSV"
	echo ""
	if (( DROPPED_ALL > 0 )); then
		echo "WARNING: ${TOTAL_ALL} total / ${VALID_ALL} valid rows — ${DROPPED_ALL} dropped (poisoned)."
	fi
}

report_csv() {
	for kv in "${PREAMBLE[@]}"; do echo "# $kv"; done
	echo "mesh_size,qps_target,target_class,n_total,n_valid,avg_p50_ms,avg_p90_ms,avg_p99_ms,avg_p999_ms,avg_max_ms,avg_actual_qps,avg_pct_200"
	while IFS=$'\t' read -r mesh qps cls n_tot n_val p50 p90 p99 p999 mx qa pct; do
		printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
			"$mesh" "$qps" "$cls" "$n_tot" "$n_val" \
			"$(fmt_val "$p50")" "$(fmt_val "$p90")" "$(fmt_val "$p99")" \
			"$(fmt_val "$p999")" "$(fmt_val "$mx")" "$(fmt_val "$qa" 1)" "$(fmt_val "$pct" 4)"
	done <<<"$AGG_TSV"
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
	echo "| mesh_size | qps_target | target_class | n_total | n_valid | avg_p50_ms | avg_p90_ms | avg_p99_ms | avg_p999_ms | avg_max_ms | avg_actual_qps | avg_pct_200 |"
	echo "|-----------|------------|--------------|---------|---------|------------|------------|------------|-------------|------------|----------------|-------------|"
	while IFS=$'\t' read -r mesh qps cls n_tot n_val p50 p90 p99 p999 mx qa pct; do
		printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" \
			"$mesh" "$qps" "$cls" "$n_tot" "$n_val" \
			"$(fmt_val "$p50")" "$(fmt_val "$p90")" "$(fmt_val "$p99")" \
			"$(fmt_val "$p999")" "$(fmt_val "$mx")" "$(fmt_val "$qa" 1)" "$(fmt_val "$pct" 4)"
	done <<<"$AGG_TSV"
	echo ""
	if (( DROPPED_ALL > 0 )); then
		printf '> \xe2\x9a\xa0 %s total / %s valid rows \xe2\x80\x94 %s dropped (poisoned).\n' \
			"$TOTAL_ALL" "$VALID_ALL" "$DROPPED_ALL"
	fi
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

	jq -n \
		--argjson metadata "$meta_json" \
		--argjson results "$results_json" \
		--argjson n_total "$TOTAL_ALL" \
		--argjson n_valid "$VALID_ALL" \
		--argjson n_dropped "$DROPPED_ALL" \
		'{metadata: $metadata, summary: {n_total: $n_total, n_valid: $n_valid, n_dropped: $n_dropped}, results: $results}'
}

case "$FORMAT" in
text)     report_text ;;
csv)      report_csv ;;
markdown) report_markdown ;;
json)     report_json ;;
esac

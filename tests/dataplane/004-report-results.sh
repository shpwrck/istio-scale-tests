#!/usr/bin/env bash
# Generate summary statistics from data-plane latency TSV files.
#
# Usage:
#   ./tests/dataplane/004-report-results.sh [--results-dir DIR]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

RESULTS_DIR="${ROOT}/tests/dataplane/results"
FORMAT="text"

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --results-dir DIR  Results directory (default: tests/dataplane/results).
  --format FMT       Output format: text, csv (default: text).
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

[[ -d "$RESULTS_DIR" ]] || die "results directory not found: $RESULTS_DIR"

TSV_FILES=()
while IFS= read -r f; do
	TSV_FILES+=("$f")
done < <(find "$RESULTS_DIR" -name 'latency-*.tsv' -type f 2>/dev/null | sort)

if [[ ${#TSV_FILES[@]} -eq 0 ]]; then
	die "no TSV result files found in $RESULTS_DIR"
fi

report_text() {
	echo "=== Data-Plane Latency Results ==="
	echo ""
	echo "Files: ${TSV_FILES[*]}"
	echo ""
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	!/^#/ && !/^run_id/ && NF>=14 && $14=="OK" {
		key = $2 "\t" $5
		p50[key][++p50_n[key]] = $9+0
		p99[key][++p99_n[key]] = $11+0
		max_l[key][++max_n[key]] = $13+0
		qps_a[key][++qps_n[key]] = $6+0
	}
	function sort_arr(arr, n,    i, j, tmp) {
		for(i=2;i<=n;i++){tmp=arr[i];j=i-1;while(j>=1&&arr[j]>tmp){arr[j+1]=arr[j];j--}arr[j+1]=tmp}
	}
	function avg(arr, n) {
		sum=0; for(i=1;i<=n;i++) sum+=arr[i]; return sum/n
	}
	END {
		printf "  %-4s | %-6s | %5s | %10s | %10s | %10s | %10s\n", \
			"Sz", "QPS", "n", "p50 (ms)", "p99 (ms)", "max (ms)", "actual QPS"
		printf "  %-4s-+-%-6s-+-%5s-+-%10s-+-%10s-+-%10s-+-%10s\n", \
			"----", "------", "-----", "----------", "----------", "----------", "----------"
		asorti(p50_n, keys)
		for(k in keys) {
			key = keys[k]
			split(key, parts, "\t")
			n = p50_n[key]
			sort_arr(p50[key], n)
			sort_arr(p99[key], n)
			sort_arr(max_l[key], n)
			printf "  %-4s | %-6s | %5d | %10.2f | %10.2f | %10.2f | %10.1f\n", \
				parts[1], parts[2], n, avg(p50[key],n), avg(p99[key],n), avg(max_l[key],n), avg(qps_a[key],n)
		}
	}'
}

report_csv() {
	echo "mesh_size,qps_target,n,avg_p50_ms,avg_p99_ms,avg_max_ms,avg_actual_qps"
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	!/^#/ && !/^run_id/ && NF>=14 && $14=="OK" {
		key = $2 "\t" $5
		p50[key][++p50_n[key]] = $9+0
		p99[key][++p99_n[key]] = $11+0
		max_l[key][++max_n[key]] = $13+0
		qps_a[key][++qps_n[key]] = $6+0
	}
	function avg(arr, n) { sum=0; for(i=1;i<=n;i++) sum+=arr[i]; return sum/n }
	END {
		asorti(p50_n, keys)
		for(k in keys) {
			key = keys[k]
			split(key, parts, "\t")
			n = p50_n[key]
			printf "%s,%s,%d,%.2f,%.2f,%.2f,%.1f\n", \
				parts[1], parts[2], n, avg(p50[key],n), avg(p99[key],n), avg(max_l[key],n), avg(qps_a[key],n)
		}
	}'
}

case "$FORMAT" in
text) report_text ;;
csv)  report_csv ;;
*)    die "unknown format: $FORMAT (use text or csv)" ;;
esac

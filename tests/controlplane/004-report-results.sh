#!/usr/bin/env bash
# Generate summary statistics from control-plane resource metrics TSV files.
#
# Usage:
#   ./tests/controlplane/004-report-results.sh [--results-dir DIR]
#
# Examples:
#   ./tests/controlplane/004-report-results.sh
#   ./tests/controlplane/004-report-results.sh --format csv
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

RESULTS_DIR="${ROOT}/tests/controlplane/results"
FORMAT="text"

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --results-dir DIR  Results directory (default: tests/controlplane/results).
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
done < <(find "$RESULTS_DIR" -name 'controlplane-*.tsv' -type f 2>/dev/null | sort)

if [[ ${#TSV_FILES[@]} -eq 0 ]]; then
	die "no TSV result files found in $RESULTS_DIR"
fi

report_text() {
	echo "=== Control-Plane Resource Scaling ==="
	echo ""
	echo "Files: ${TSV_FILES[*]}"
	echo ""
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	!/^#/ && !/^timestamp/ && NF>=15 {
		ms=$3
		cpu[ms][++cpu_n[ms]] = $6+0
		mem[ms][++mem_n[ms]] = $7+0
		conv99[ms][++conv99_n[ms]] = $9+0
		queue99[ms][++queue99_n[ms]] = $11+0
		proxies[ms][++proxies_n[ms]] = $14+0
	}
	function sort_arr(arr, n,    i, j, tmp) {
		for(i=2; i<=n; i++) {
			tmp = arr[i]; j = i - 1
			while(j >= 1 && arr[j] > tmp) { arr[j+1] = arr[j]; j-- }
			arr[j+1] = tmp
		}
	}
	function stats(arr, n,    sum) {
		if(n==0) return "N/A"
		sort_arr(arr, n)
		sum=0; for(i=1;i<=n;i++) sum+=arr[i]
		return sprintf("n=%d min=%.0f max=%.0f avg=%.0f", n, arr[1], arr[n], sum/n)
	}
	END {
		asorti(cpu_n, sizes)
		for(s in sizes) {
			m = sizes[s]
			printf "--- mesh_size=%s ---\n", m
			printf "  istiod CPU (m):          %s\n", stats(cpu[m], cpu_n[m])
			printf "  istiod Memory (Mi):      %s\n", stats(mem[m], mem_n[m])
			printf "  Convergence p99 (ms):    %s\n", stats(conv99[m], conv99_n[m])
			printf "  Queue time p99 (ms):     %s\n", stats(queue99[m], queue99_n[m])
			printf "  Connected proxies:       %s\n", stats(proxies[m], proxies_n[m])
			printf "\n"
		}
	}'
}

report_csv() {
	echo "mesh_size,metric,n,min,max,avg"
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	!/^#/ && !/^timestamp/ && NF>=15 {
		ms=$3
		cpu[ms][++cpu_n[ms]] = $6+0
		mem[ms][++mem_n[ms]] = $7+0
		conv99[ms][++conv99_n[ms]] = $9+0
		queue99[ms][++queue99_n[ms]] = $11+0
		proxies[ms][++proxies_n[ms]] = $14+0
	}
	function sort_arr(arr, n,    i, j, tmp) {
		for(i=2;i<=n;i++){tmp=arr[i];j=i-1;while(j>=1&&arr[j]>tmp){arr[j+1]=arr[j];j--}arr[j+1]=tmp}
	}
	function csv_stats(ms, metric, arr, n) {
		if(n==0) return
		sort_arr(arr, n)
		sum=0; for(i=1;i<=n;i++) sum+=arr[i]
		printf "%s,%s,%d,%.0f,%.0f,%.0f\n", ms, metric, n, arr[1], arr[n], sum/n
	}
	END {
		asorti(cpu_n, sizes)
		for(s in sizes) {
			m = sizes[s]
			csv_stats(m, "cpu_m", cpu[m], cpu_n[m])
			csv_stats(m, "mem_mi", mem[m], mem_n[m])
			csv_stats(m, "convergence_p99_ms", conv99[m], conv99_n[m])
			csv_stats(m, "queue_p99_ms", queue99[m], queue99_n[m])
			csv_stats(m, "connected_proxies", proxies[m], proxies_n[m])
		}
	}'
}

case "$FORMAT" in
text) report_text ;;
csv)  report_csv ;;
*)    die "unknown format: $FORMAT (use text or csv)" ;;
esac

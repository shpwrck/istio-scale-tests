#!/usr/bin/env bash
# Generate summary statistics from churn convergence TSV files.
#
# Usage:
#   ./tests/churn/004-report-results.sh [--results-dir DIR]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

RESULTS_DIR="${ROOT}/tests/churn/results"
FORMAT="text"

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --results-dir DIR  Results directory (default: tests/churn/results).
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
done < <(find "$RESULTS_DIR" -name 'churn-*.tsv' -type f 2>/dev/null | sort)

if [[ ${#TSV_FILES[@]} -eq 0 ]]; then
	die "no TSV result files found in $RESULTS_DIR"
fi

report_text() {
	echo "=== Churn Convergence Results ==="
	echo ""
	echo "Files: ${TSV_FILES[*]}"
	echo ""
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	!/^#/ && !/^run_id/ && NF>=11 {
		key = $2 "\t" $3
		if($6!="TIMEOUT" && $6!="N/A") { cl[key][++cl_n[key]] = $6+0 }
		if($7!="TIMEOUT" && $7!="N/A") { cr[key][++cr_n[key]] = $7+0 }
		pt[key][++pt_n[key]] = $8+0
		xp[key][++xp_n[key]] = $9+0
		if($10!="N/A") { qq[key][++qq_n[key]] = $10+0 }
	}
	function sort_arr(arr, n,    i, j, tmp) {
		for(i=2;i<=n;i++){tmp=arr[i];j=i-1;while(j>=1&&arr[j]>tmp){arr[j+1]=arr[j];j--}arr[j+1]=tmp}
	}
	function stats(arr, n) {
		if(n==0) return "N/A"
		sort_arr(arr, n)
		sum=0; for(i=1;i<=n;i++) sum+=arr[i]
		return sprintf("n=%d min=%.0f max=%.0f avg=%.0f", n, arr[1], arr[n], sum/n)
	}
	END {
		asorti(cl_n, keys)
		for(k in keys) {
			key = keys[k]
			split(key, parts, "\t")
			printf "--- mesh_size=%s  churn_intensity=%s ---\n", parts[1], parts[2]
			printf "  Local convergence (ms):   %s\n", stats(cl[key], cl_n[key])
			printf "  Remote convergence (ms):  %s\n", stats(cr[key], cr_n[key])
			printf "  Push triggers delta:      %s\n", stats(pt[key], pt_n[key])
			printf "  xDS pushes delta:         %s\n", stats(xp[key], xp_n[key])
			printf "  Queue time p99 (ms):      %s\n", stats(qq[key], qq_n[key])
			printf "\n"
		}
	}'
}

report_csv() {
	echo "mesh_size,churn_intensity,metric,n,min,max,avg"
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	!/^#/ && !/^run_id/ && NF>=11 {
		key = $2 "\t" $3
		if($6!="TIMEOUT" && $6!="N/A") { cl[key][++cl_n[key]] = $6+0 }
		if($7!="TIMEOUT" && $7!="N/A") { cr[key][++cr_n[key]] = $7+0 }
		pt[key][++pt_n[key]] = $8+0
		xp[key][++xp_n[key]] = $9+0
	}
	function sort_arr(arr, n,    i,j,tmp) {
		for(i=2;i<=n;i++){tmp=arr[i];j=i-1;while(j>=1&&arr[j]>tmp){arr[j+1]=arr[j];j--}arr[j+1]=tmp}
	}
	function csv_stats(ms, ci, metric, arr, n) {
		if(n==0) return
		sort_arr(arr, n)
		sum=0; for(i=1;i<=n;i++) sum+=arr[i]
		printf "%s,%s,%s,%d,%.0f,%.0f,%.0f\n", ms, ci, metric, n, arr[1], arr[n], sum/n
	}
	END {
		asorti(cl_n, keys)
		for(k in keys) {
			key = keys[k]; split(key, p, "\t")
			csv_stats(p[1], p[2], "convergence_local_ms", cl[key], cl_n[key])
			csv_stats(p[1], p[2], "convergence_remote_ms", cr[key], cr_n[key])
			csv_stats(p[1], p[2], "push_triggers_delta", pt[key], pt_n[key])
			csv_stats(p[1], p[2], "xds_pushes_delta", xp[key], xp_n[key])
		}
	}'
}

case "$FORMAT" in
text) report_text ;;
csv)  report_csv ;;
*)    die "unknown format: $FORMAT (use text or csv)" ;;
esac

#!/usr/bin/env bash
# Post-process propagation test TSV files into summary statistics.
# Groups results by mesh_size to compare propagation latency across cluster counts.
#
# Usage:
#   ./propagation-test/005-report-results.sh [--results-dir DIR] [--format text|csv|json]
#
# Examples:
#   # Default text report from all results:
#   ./propagation-test/005-report-results.sh
#
#   # CSV output:
#   ./propagation-test/005-report-results.sh --format csv
#
#   # Specific results directory:
#   ./propagation-test/005-report-results.sh --results-dir propagation-test/results
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

RESULTS_DIR="${ROOT}/propagation-test/results"
FORMAT="text"

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --results-dir DIR  Results directory (default: propagation-test/results).
  --format FMT       Output format: text, csv, json (default: text).
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

ENDPOINT_FILES=()
while IFS= read -r f; do
	ENDPOINT_FILES+=("$f")
done < <(find "$RESULTS_DIR" -name 'endpoint-*.tsv' -type f 2>/dev/null | sort)

if [[ ${#ENDPOINT_FILES[@]} -eq 0 ]]; then
	die "no TSV result files found in $RESULTS_DIR"
fi

report_endpoint_text() {
	echo "=== Endpoint Propagation Latency ==="
	echo ""
	cat "${ENDPOINT_FILES[@]}" | awk -F'\t' '
	!/^#/ && !/^run_id/ && NF>=10 {
		ms=$2
		p1=$7; p2=$8; p3=$9
		if(p1!="TIMEOUT" && p1!="N/A") { p1_vals[ms][++p1_n[ms]]=p1+0 }
		if(p2!="TIMEOUT" && p2!="N/A") { p2_vals[ms][++p2_n[ms]]=p2+0 }
		if(p3!="TIMEOUT" && p3!="N/A") { p3_vals[ms][++p3_n[ms]]=p3+0 }
	}
	function percentile(arr, n, pct,    idx) {
		if(n==0) return "N/A"
		idx = int(n * pct / 100)
		if(idx < 1) idx = 1
		if(idx > n) idx = n
		return arr[idx]
	}
	function sort_arr(arr, n,    i, j, tmp) {
		for(i=2; i<=n; i++) {
			tmp = arr[i]
			j = i - 1
			while(j >= 1 && arr[j] > tmp) {
				arr[j+1] = arr[j]
				j--
			}
			arr[j+1] = tmp
		}
	}
	function stats_line(label, arr, n) {
		if(n==0) return
		sort_arr(arr, n)
		sum=0; for(i=1;i<=n;i++) sum+=arr[i]
		printf "  %-3s | %-22s | %5d | %7d | %7d | %7d | %7s | %7s | %7s\n", \
			ms_cur, label, n, arr[1], arr[n], sum/n, \
			percentile(arr,n,50), percentile(arr,n,95), percentile(arr,n,99)
	}
	END {
		printf "  %-3s | %-22s | %5s | %7s | %7s | %7s | %7s | %7s | %7s\n", \
			"Sz", "Phase", "n", "min", "max", "avg", "p50", "p95", "p99"
		printf "  %-3s-+-%-22s-+-%5s-+-%7s-+-%7s-+-%7s-+-%7s-+-%7s-+-%7s\n", \
			"---", "----------------------", "-----", "-------", "-------", "-------", "-------", "-------", "-------"
		asorti(p1_n, sizes)
		for(s in sizes) {
			ms_cur = sizes[s]
			stats_line("P1 local xDS push", p1_vals[ms_cur], p1_n[ms_cur])
			stats_line("P2 remote istiod disc", p2_vals[ms_cur], p2_n[ms_cur])
			stats_line("P3 remote sidecar", p3_vals[ms_cur], p3_n[ms_cur])
		}
	}'
}

report_endpoint_csv() {
	echo "mesh_size,phase,n,min_ms,max_ms,avg_ms,p50_ms,p95_ms,p99_ms"
	cat "${ENDPOINT_FILES[@]}" | awk -F'\t' '
	!/^#/ && !/^run_id/ && NF>=10 {
		ms=$2; p1=$7; p2=$8; p3=$9
		if(p1!="TIMEOUT" && p1!="N/A") { p1_vals[ms][++p1_n[ms]]=p1+0 }
		if(p2!="TIMEOUT" && p2!="N/A") { p2_vals[ms][++p2_n[ms]]=p2+0 }
		if(p3!="TIMEOUT" && p3!="N/A") { p3_vals[ms][++p3_n[ms]]=p3+0 }
	}
	function percentile(arr, n, pct,    idx) {
		if(n==0) return "N/A"
		idx = int(n * pct / 100); if(idx<1)idx=1; if(idx>n)idx=n
		return arr[idx]
	}
	function sort_arr(arr, n,    i,j,tmp) {
		for(i=2;i<=n;i++){tmp=arr[i];j=i-1;while(j>=1&&arr[j]>tmp){arr[j+1]=arr[j];j--}arr[j+1]=tmp}
	}
	function csv_line(ms, phase, arr, n) {
		if(n==0) return
		sort_arr(arr,n)
		sum=0; for(i=1;i<=n;i++) sum+=arr[i]
		printf "%s,%s,%d,%d,%d,%d,%s,%s,%s\n", ms, phase, n, arr[1], arr[n], sum/n, \
			percentile(arr,n,50), percentile(arr,n,95), percentile(arr,n,99)
	}
	END {
		asorti(p1_n, sizes)
		for(s in sizes) {
			m=sizes[s]
			csv_line(m,"P1_local",p1_vals[m],p1_n[m])
			csv_line(m,"P2_discovery",p2_vals[m],p2_n[m])
			csv_line(m,"P3_dataplane",p3_vals[m],p3_n[m])
		}
	}'
}

report_endpoint_json() {
	cat "${ENDPOINT_FILES[@]}" | awk -F'\t' '
	!/^#/ && !/^run_id/ && NF>=10 {
		ms=$2; p1=$7; p2=$8; p3=$9
		if(p1!="TIMEOUT" && p1!="N/A") { p1_vals[ms][++p1_n[ms]]=p1+0 }
		if(p2!="TIMEOUT" && p2!="N/A") { p2_vals[ms][++p2_n[ms]]=p2+0 }
		if(p3!="TIMEOUT" && p3!="N/A") { p3_vals[ms][++p3_n[ms]]=p3+0 }
	}
	function percentile(arr, n, pct,    idx) {
		if(n==0) return "null"
		idx = int(n * pct / 100); if(idx<1)idx=1; if(idx>n)idx=n
		return arr[idx]
	}
	function sort_arr(arr, n,    i,j,tmp) {
		for(i=2;i<=n;i++){tmp=arr[i];j=i-1;while(j>=1&&arr[j]>tmp){arr[j+1]=arr[j];j--}arr[j+1]=tmp}
	}
	function json_obj(ms, phase, arr, n) {
		if(n==0) return ""
		sort_arr(arr,n)
		sum=0; for(i=1;i<=n;i++) sum+=arr[i]
		return sprintf("{\"mesh_size\":%s,\"phase\":\"%s\",\"n\":%d,\"min_ms\":%d,\"max_ms\":%d,\"avg_ms\":%d,\"p50_ms\":%s,\"p95_ms\":%s,\"p99_ms\":%s}", \
			ms, phase, n, arr[1], arr[n], sum/n, \
			percentile(arr,n,50), percentile(arr,n,95), percentile(arr,n,99))
	}
	END {
		printf "["
		first=1
		asorti(p1_n, sizes)
		for(s in sizes) {
			m=sizes[s]
			phases[1]="P1_local"; phases[2]="P2_discovery"; phases[3]="P3_dataplane"
			arrs[1]=p1_n[m]; arrs[2]=p2_n[m]; arrs[3]=p3_n[m]
			for(p=1;p<=3;p++) {
				if(p==1) n=p1_n[m]; else if(p==2) n=p2_n[m]; else n=p3_n[m]
				if(n==0) continue
				if(p==1) { for(i=1;i<=n;i++) tmp[i]=p1_vals[m][i] }
				else if(p==2) { for(i=1;i<=n;i++) tmp[i]=p2_vals[m][i] }
				else { for(i=1;i<=n;i++) tmp[i]=p3_vals[m][i] }
				obj=json_obj(m, phases[p], tmp, n)
				if(obj!="") { if(!first) printf ","; printf "%s", obj; first=0 }
			}
		}
		printf "]\n"
	}'
}

case "$FORMAT" in
text)
	echo "Files: ${ENDPOINT_FILES[*]}"
	report_endpoint_text
	;;
csv)
	if [[ ${#ENDPOINT_FILES[@]} -gt 0 ]]; then
		report_endpoint_csv
	fi
	;;
json)
	if [[ ${#ENDPOINT_FILES[@]} -gt 0 ]]; then
		report_endpoint_json
	fi
	;;
*)
	die "unknown format: $FORMAT (use text, csv, or json)"
	;;
esac

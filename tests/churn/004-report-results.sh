#!/usr/bin/env bash
# Generate summary statistics from churn convergence TSV files.
#
# Usage:
#   ./tests/churn/004-report-results.sh [--results-dir DIR]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

RESULTS_DIR="${ROOT}/tests/churn/results"
FORMAT="text"

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --results-dir DIR  Results directory (default: tests/churn/results).
  --format FMT       Output format: text, csv, markdown (default: text).
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

# TSV schema (20 columns):
#  $1  run_id
#  $2  mesh_size
#  $3  churn_intensity
#  $4  base_replicas
#  $5  scale_to
#  $6  iteration
#  $7  t0_epoch_ns
#  $8  convergence_local_ms
#  $9  convergence_remote_ms
#  $10 source_push_triggers_delta
#  $11 remote_push_triggers_delta
#  $12 source_xds_pushes_delta
#  $13 remote_xds_pushes_delta
#  $14 source_queue_time_p99_ms
#  $15 remote_queue_time_p99_ms
#  $16 source_connected_proxies
#  $17 remote_connected_proxies
#  $18 source_push_time_p99_ms
#  $19 remote_push_time_p99_ms
#  $20 status

report_text() {
	echo "=== Churn Convergence Results ==="
	echo ""
	echo "Files: ${TSV_FILES[*]}"
	echo ""
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	!/^#/ && !/^run_id/ && NF>=20 {
		key = $2 "\t" $3 "\t" $4 "\t" $5
		seen[key] = 1
		if($8!="TIMEOUT" && $8!="N/A") { cl[key, ++cl_n[key]] = $8+0 }
		if($9!="TIMEOUT" && $9!="N/A") { cr[key, ++cr_n[key]] = $9+0 }
		spt[key, ++spt_n[key]] = $10+0
		if($11!="N/A") { rpt[key, ++rpt_n[key]] = $11+0 }
		sxp[key, ++sxp_n[key]] = $12+0
		if($13!="N/A") { rxp[key, ++rxp_n[key]] = $13+0 }
		if($14!="N/A" && $14!="overflow") { sqq[key, ++sqq_n[key]] = $14+0 }
		if($15!="N/A" && $15!="overflow") { rqq[key, ++rqq_n[key]] = $15+0 }
		scp[key, ++scp_n[key]] = $16+0
		if($17!="N/A") { rcp[key, ++rcp_n[key]] = $17+0 }
		if($18!="N/A" && $18!="overflow") { spt2[key, ++spt2_n[key]] = $18+0 }
		if($19!="N/A" && $19!="overflow") { rpt2[key, ++rpt2_n[key]] = $19+0 }
		if($10+0 > 0) { amp[key, ++amp_n[key]] = ($12+0 + ($13=="N/A" ? 0 : $13+0)) / $10 }
	}
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
	function stats_hist(arr, key, n,    i, sum) {
		if(n==0) return "N/A"
		sort_vals(arr, key, n)
		sum=0; for(i=1;i<=n;i++) sum+=arr[key,i]
		return sprintf("n=%d min=%s max=%s avg=%s", n, bucket_range(arr[key,1]), bucket_range(arr[key,n]), bucket_range(sum/n))
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
			printf "  Local convergence (ms):        %s\n", stats(cl, key, cl_n[key])
			printf "  Remote convergence (ms):       %s\n", stats(cr, key, cr_n[key])
			printf "  Source push triggers:          %s\n", stats(spt, key, spt_n[key])
			printf "  Remote push triggers:          %s\n", stats(rpt, key, rpt_n[key])
			printf "  Source xDS pushes:             %s\n", stats(sxp, key, sxp_n[key])
			printf "  Remote xDS pushes:             %s\n", stats(rxp, key, rxp_n[key])
			printf "  Source queue time p99 (ms):     %s\n", stats_hist(sqq, key, sqq_n[key])
			printf "  Remote queue time p99 (ms):     %s\n", stats_hist(rqq, key, rqq_n[key])
			printf "  Source connected proxies:      %s\n", stats(scp, key, scp_n[key])
			printf "  Remote connected proxies:      %s\n", stats(rcp, key, rcp_n[key])
			printf "  Source push time p99 (ms):      %s\n", stats_hist(spt2, key, spt2_n[key])
			printf "  Remote push time p99 (ms):      %s\n", stats_hist(rpt2, key, rpt2_n[key])
			printf "  Push amplification ratio:      %s\n", stats_ratio(amp, key, amp_n[key])
			printf "\n"
		}
	}'
}

report_csv() {
	echo "mesh_size,churn_intensity,base_replicas,scale_to,metric,n,min,max,avg"
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	!/^#/ && !/^run_id/ && NF>=20 {
		key = $2 "\t" $3 "\t" $4 "\t" $5
		seen[key] = 1
		if($8!="TIMEOUT" && $8!="N/A") { cl[key, ++cl_n[key]] = $8+0 }
		if($9!="TIMEOUT" && $9!="N/A") { cr[key, ++cr_n[key]] = $9+0 }
		spt[key, ++spt_n[key]] = $10+0
		if($11!="N/A") { rpt[key, ++rpt_n[key]] = $11+0 }
		sxp[key, ++sxp_n[key]] = $12+0
		if($13!="N/A") { rxp[key, ++rxp_n[key]] = $13+0 }
		if($14!="N/A" && $14!="overflow") { sqq[key, ++sqq_n[key]] = $14+0 }
		if($15!="N/A" && $15!="overflow") { rqq[key, ++rqq_n[key]] = $15+0 }
		scp[key, ++scp_n[key]] = $16+0
		if($17!="N/A") { rcp[key, ++rcp_n[key]] = $17+0 }
		if($18!="N/A" && $18!="overflow") { spt2[key, ++spt2_n[key]] = $18+0 }
		if($19!="N/A" && $19!="overflow") { rpt2[key, ++rpt2_n[key]] = $19+0 }
		if($10+0 > 0) { amp[key, ++amp_n[key]] = ($12+0 + ($13=="N/A" ? 0 : $13+0)) / $10 }
	}
	function sort_vals(arr, key, n,    i,j,tmp) {
		for(i=2;i<=n;i++){tmp=arr[key,i];j=i-1;while(j>=1&&arr[key,j]>tmp){arr[key,j+1]=arr[key,j];j--}arr[key,j+1]=tmp}
	}
	function csv_stats(ms, ci, br, st, metric, arr, key, n,    i, sum) {
		if(n==0) return
		sort_vals(arr, key, n)
		sum=0; for(i=1;i<=n;i++) sum+=arr[key,i]
		printf "%s,%s,%s,%s,%s,%d,%.0f,%.0f,%.0f\n", ms, ci, br, st, metric, n, arr[key,1], arr[key,n], sum/n
	}
	function csv_stats_ratio(ms, ci, br, st, metric, arr, key, n,    i, sum) {
		if(n==0) return
		sort_vals(arr, key, n)
		sum=0; for(i=1;i<=n;i++) sum+=arr[key,i]
		printf "%s,%s,%s,%s,%s,%d,%.1f,%.1f,%.1f\n", ms, ci, br, st, metric, n, arr[key,1], arr[key,n], sum/n
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
			csv_stats(p[1], p[2], p[3], p[4], "convergence_local_ms", cl, key, cl_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "convergence_remote_ms", cr, key, cr_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "source_push_triggers_delta", spt, key, spt_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "remote_push_triggers_delta", rpt, key, rpt_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "source_xds_pushes_delta", sxp, key, sxp_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "remote_xds_pushes_delta", rxp, key, rxp_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "source_queue_time_p99_ms", sqq, key, sqq_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "remote_queue_time_p99_ms", rqq, key, rqq_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "source_connected_proxies", scp, key, scp_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "remote_connected_proxies", rcp, key, rcp_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "source_push_time_p99_ms", spt2, key, spt2_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "remote_push_time_p99_ms", rpt2, key, rpt2_n[key])
			csv_stats_ratio(p[1], p[2], p[3], p[4], "push_amplification_ratio", amp, key, amp_n[key])
		}
	}'
}

report_markdown() {
	local harness_sha
	harness_sha=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
	if ! git -C "$ROOT" diff --quiet HEAD 2>/dev/null; then harness_sha="${harness_sha}-dirty"; fi
	local istio_version="${ISTIO_VERSION:-unknown}"

	# Extract sweep axes from TSV data.
	local axes
	axes=$(cat "${TSV_FILES[@]}" | awk -F'\t' '
	!/^#/ && !/^run_id/ && NF>=16 {
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
	echo "istio_version: ${istio_version}"
	echo "harness_sha: ${harness_sha}"
	echo "files_consumed: ${#TSV_FILES[@]}"
	echo "---"
	echo ""
	echo "# Churn Convergence"
	echo ""
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
	echo "| mesh | churn | scale | n | local_avg (ms) | remote_avg (ms) | src_triggers | rmt_triggers | src_pushes | rmt_pushes | src_queue_p99 | rmt_queue_p99 | src_proxies | rmt_proxies | src_push_p99 | rmt_push_p99 | amplification |"
	echo "|------|-------|-------|---|----------------|-----------------|--------------|--------------|------------|------------|---------------|---------------|-------------|-------------|--------------|--------------|---------------|"
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	!/^#/ && !/^run_id/ && NF>=20 {
		key = $2 "\t" $3 "\t" $4 "\t" $5
		seen[key] = 1
		n_total[key]++
		if($8!="TIMEOUT" && $8!="N/A") { cl_sum[key]+=$8+0; cl_n[key]++ }
		if($9!="TIMEOUT" && $9!="N/A") { cr_sum[key]+=$9+0; cr_n[key]++ }
		spt_sum[key]+=$10+0; spt_n[key]++
		if($11!="N/A") { rpt_sum[key]+=$11+0; rpt_n[key]++ }
		sxp_sum[key]+=$12+0; sxp_n[key]++
		if($13!="N/A") { rxp_sum[key]+=$13+0; rxp_n[key]++ }
		if($14!="N/A" && $14!="overflow") { sqq_sum[key]+=$14+0; sqq_n[key]++ }
		if($15!="N/A" && $15!="overflow") { rqq_sum[key]+=$15+0; rqq_n[key]++ }
		scp_sum[key]+=$16+0; scp_n[key]++
		if($17!="N/A") { rcp_sum[key]+=$17+0; rcp_n[key]++ }
		if($18!="N/A" && $18!="overflow") { spt2_sum[key]+=$18+0; spt2_n[key]++ }
		if($19!="N/A" && $19!="overflow") { rpt2_sum[key]+=$19+0; rpt2_n[key]++ }
		if($10+0 > 0) { amp_sum[key]+=($12+0 + ($13=="N/A" ? 0 : $13+0)) / $10; amp_n[key]++ }
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
	function avg_hist(s, n) { return n>0 ? bucket_range(s/n) : "N/A" }
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
			printf "| %s | %s | %s->%s | %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", \
				p[1], p[2], p[3], p[4], n_total[key], \
				avg_or_na(cl_sum[key], cl_n[key]), \
				avg_or_na(cr_sum[key], cr_n[key]), \
				avg_or_na(spt_sum[key], spt_n[key]), \
				avg_or_na(rpt_sum[key], rpt_n[key]), \
				avg_or_na(sxp_sum[key], sxp_n[key]), \
				avg_or_na(rxp_sum[key], rxp_n[key]), \
				avg_hist(sqq_sum[key], sqq_n[key]), \
				avg_hist(rqq_sum[key], rqq_n[key]), \
				avg_or_na(scp_sum[key], scp_n[key]), \
				avg_or_na(rcp_sum[key], rcp_n[key]), \
				avg_hist(spt2_sum[key], spt2_n[key]), \
				avg_hist(rpt2_sum[key], rpt2_n[key]), \
				avg_ratio(amp_sum[key], amp_n[key])
		}
	}'
}

case "$FORMAT" in
text)     report_text ;;
csv)      report_csv ;;
markdown) report_markdown ;;
*)        die "unknown format: $FORMAT (use text, csv, or markdown)" ;;
esac

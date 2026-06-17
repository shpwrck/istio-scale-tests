#!/usr/bin/env bash
# Generate summary statistics from churn convergence TSV files.
#
# Usage:
#   ./tests/churn/004-report-results.sh [--results-dir DIR]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

RESULTS_DIR="${ROOT}/tests/churn/results"
FORMAT="text"


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --results-dir DIR  Results directory (default: tests/churn/results).
  --format FMT       Output format: text, csv, markdown, charts (default: text).
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

# Pull a `# KEY=value` provenance line from the first TSV's preamble. Used for
# values that are LIVE-QUERIED at sweep time and therefore NOT reconstructable from
# the environment (unlike istio_version / harness_sha) — notably the tuning-baseline
# levers (TUNING_BASELINE / SIDECAR_EGRESS_HOSTS, PL2). Defaults to "unknown".
preamble_get() {
	local key="$1" v
	v="$(grep -m1 "^# ${key}=" "${TSV_FILES[0]}" 2>/dev/null | head -1)"
	v="${v#*=}"
	[[ -n "$v" ]] && echo "$v" || echo "unknown"
}

# Backwards-compat: warn when a file predates the 21-column schema (the
# convergence_remote_eds_ms split). Such rows are skipped by the NF>=21 awk guards
# below; surface that so a silently-empty aggregation is not mistaken for "no data".
for f in "${TSV_FILES[@]}"; do
	if awk -F'\t' '!/^#/ && !/^run_id/ && NF>0 && NF<21 { legacy=1 } END { exit (legacy ? 0 : 1) }' "$f"; then
		echo "warning: $f has <21 data columns (pre-EDS-split schema); those rows are skipped" >&2
	fi
done

# TSV schema (21 columns):
#  $1  run_id
#  $2  mesh_size
#  $3  churn_intensity
#  $4  base_replicas
#  $5  scale_to
#  $6  iteration
#  $7  t0_epoch_ns
#  $8  convergence_local_ms
#  $9  remote_endpoint_reachable_ms   (data-plane: Envoy health_flags::healthy; incl pod/sidecar lifecycle)
#  $10 convergence_remote_eds_ms      (control-plane only: remote istiod EDS-push crossing; pod-boot-free)
#  $11 source_push_triggers_delta
#  $12 remote_push_triggers_delta
#  $13 source_xds_pushes_delta
#  $14 remote_xds_pushes_delta
#  $15 source_queue_time_p99_ms
#  $16 remote_queue_time_p99_ms
#  $17 source_connected_proxies
#  $18 remote_connected_proxies
#  $19 source_push_time_p99_ms
#  $20 remote_push_time_p99_ms
#  $21 status
#
# Column count was bumped 20 -> 21 when convergence_remote_eds_ms was split out of
# the old convergence_remote_ms (which is now remote_endpoint_reachable_ms, $9).
# Pre-split TSVs (20 cols) are skipped by the NF>=21 guard with a stderr warning.

report_text() {
	echo "=== Churn Convergence Results ==="
	echo ""
	# PL19: live-queried tuning-baseline provenance from the TSV preamble.
	echo "# tuning_baseline (live mesh): $(preamble_get TUNING_BASELINE)"
	echo "# sidecar egress hosts (live): $(preamble_get SIDECAR_EGRESS_HOSTS)"
	echo ""
	echo "Files: ${TSV_FILES[*]}"
	echo ""
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	# Only OK rows feed numeric aggregation; POISONED_*/TIMEOUT_*/SCRAPE_INCOMPLETE
	# rows carry N/A or undercounted istiod-side deltas and must NOT leak into
	# column means. Per-column "N/A"!= guards also stop "N/A"+0 -> 0 fabrication.
	!/^#/ && !/^run_id/ && NF>=21 && $21=="OK" {
		key = $2 "\t" $3 "\t" $4 "\t" $5
		seen[key] = 1
		if($8!="TIMEOUT" && $8!="N/A") { cl[key, ++cl_n[key]] = $8+0 }
		if($9!="TIMEOUT" && $9!="N/A") { cr[key, ++cr_n[key]] = $9+0 }
		if($10!="TIMEOUT" && $10!="N/A") { cre[key, ++cre_n[key]] = $10+0 }
		if($11!="N/A") { spt[key, ++spt_n[key]] = $11+0 }
		if($12!="N/A") { rpt[key, ++rpt_n[key]] = $12+0 }
		if($13!="N/A") { sxp[key, ++sxp_n[key]] = $13+0 }
		if($14!="N/A") { rxp[key, ++rxp_n[key]] = $14+0 }
		if($15!="N/A" && $15!="overflow") { sqq[key, ++sqq_n[key]] = $15+0 }
		if($16!="N/A" && $16!="overflow") { rqq[key, ++rqq_n[key]] = $16+0 }
		if($17!="N/A") { scp[key, ++scp_n[key]] = $17+0 }
		if($18!="N/A") { rcp[key, ++rcp_n[key]] = $18+0 }
		if($19!="N/A" && $19!="overflow") { spt2[key, ++spt2_n[key]] = $19+0 }
		if($20!="N/A" && $20!="overflow") { rpt2[key, ++rpt2_n[key]] = $20+0 }
		if($11!="N/A" && $11+0 > 0 && $13!="N/A") { amp[key, ++amp_n[key]] = ($13+0 + ($14=="N/A" ? 0 : $14+0)) / $11 }
	}
	# Track totals/valids per cell so we can surface the filter rate.
	!/^#/ && !/^run_id/ && NF>=21 { tot_key = $2 "\t" $3 "\t" $4 "\t" $5; seen[tot_key]=1; n_total[tot_key]++; if($21=="OK") n_valid[tot_key]++ }
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
			printf "  Rows (valid/total):            %d/%d\n", n_valid[key]+0, n_total[key]+0
			printf "  Local convergence (ms):        %s\n", stats(cl, key, cl_n[key])
			printf "  Remote endpoint reachable (ms): %s\n", stats(cr, key, cr_n[key])
			printf "  Remote EDS converged (ms):     %s\n", stats(cre, key, cre_n[key])
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
	# PL19: live-queried tuning-baseline provenance as `# KEY=value` comment lines.
	echo "# TUNING_BASELINE=$(preamble_get TUNING_BASELINE)"
	echo "# SIDECAR_EGRESS_HOSTS=$(preamble_get SIDECAR_EGRESS_HOSTS)"
	echo "mesh_size,churn_intensity,base_replicas,scale_to,metric,n,min,max,avg"
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	# Only OK rows feed numeric aggregation (see report_text for rationale).
	!/^#/ && !/^run_id/ && NF>=21 && $21=="OK" {
		key = $2 "\t" $3 "\t" $4 "\t" $5
		seen[key] = 1
		if($8!="TIMEOUT" && $8!="N/A") { cl[key, ++cl_n[key]] = $8+0 }
		if($9!="TIMEOUT" && $9!="N/A") { cr[key, ++cr_n[key]] = $9+0 }
		if($10!="TIMEOUT" && $10!="N/A") { cre[key, ++cre_n[key]] = $10+0 }
		if($11!="N/A") { spt[key, ++spt_n[key]] = $11+0 }
		if($12!="N/A") { rpt[key, ++rpt_n[key]] = $12+0 }
		if($13!="N/A") { sxp[key, ++sxp_n[key]] = $13+0 }
		if($14!="N/A") { rxp[key, ++rxp_n[key]] = $14+0 }
		if($15!="N/A" && $15!="overflow") { sqq[key, ++sqq_n[key]] = $15+0 }
		if($16!="N/A" && $16!="overflow") { rqq[key, ++rqq_n[key]] = $16+0 }
		if($17!="N/A") { scp[key, ++scp_n[key]] = $17+0 }
		if($18!="N/A") { rcp[key, ++rcp_n[key]] = $18+0 }
		if($19!="N/A" && $19!="overflow") { spt2[key, ++spt2_n[key]] = $19+0 }
		if($20!="N/A" && $20!="overflow") { rpt2[key, ++rpt2_n[key]] = $20+0 }
		if($11!="N/A" && $11+0 > 0 && $13!="N/A") { amp[key, ++amp_n[key]] = ($13+0 + ($14=="N/A" ? 0 : $14+0)) / $11 }
	}
	!/^#/ && !/^run_id/ && NF>=21 { tot_key = $2 "\t" $3 "\t" $4 "\t" $5; seen[tot_key]=1; n_total[tot_key]++; if($21=="OK") n_valid[tot_key]++ }
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
			# Row-validity census: n=n_valid, max=n_total so consumers see both.
			printf "%s,%s,%s,%s,%s,%d,%d,%d,%d\n", p[1], p[2], p[3], p[4], "rows_valid_of_total", n_valid[key]+0, n_valid[key]+0, n_total[key]+0, n_valid[key]+0
			csv_stats(p[1], p[2], p[3], p[4], "convergence_local_ms", cl, key, cl_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "remote_endpoint_reachable_ms", cr, key, cr_n[key])
			csv_stats(p[1], p[2], p[3], p[4], "convergence_remote_eds_ms", cre, key, cre_n[key])
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

# Metric glossary appended to the END of the markdown summary (#17). Definitions are
# pulled from tests/churn/README.md; units/source/caveats mirror it, not invented here.
glossary_section() {
	cat <<'GLOSSARY'

## Glossary

Definitions for every metric column in the results table above. Sourced from
`tests/churn/README.md`. `src_`/`rmt_` prefixes are the **source** istiod (where churn is
applied, summed across its replicas) vs the **remote** istiod pods (summed/maxed across all
remote pods). Averages are over `n_valid` rows only — rows with `status != OK`
(`POISONED_RESTART` / `SCRAPE_INCOMPLETE` / `TIMEOUT_*`) are excluded but still counted in
`n_total`. Histogram p99 columns are reported as **bucket ranges** (e.g. `0-100`), not exact
values; `overflow` means the p99 fell in the `+Inf` bucket.

| Column | Units | Source | Definition / caveats |
|--------|-------|--------|----------------------|
| `mesh` | clusters | sweep axis | Mesh size (number of clusters). |
| `churn` | scale-ops | sweep axis | Churn intensity per iteration. |
| `scale` | `base->target` | sweep axis | Endpoint scale range applied to the churn target (e.g. `1->5`). |
| `n_valid` | rows | internal | Rows with `status == OK` used in the averages. |
| `n_total` | rows | internal | All rows for the cell, including poisoned/timed-out rows. |
| `local_avg (ms)` | ms | source istiod `/debug/syncz` poll | Local convergence: time until all source proxies report SYNCED. |
| `remote_reach_avg (ms)` | ms | remote sidecar Envoy `/clusters` | Remote endpoint reachability — **includes** pod scheduling + sidecar startup (data-plane signal, analogous to propagation P3). |
| `remote_eds_avg (ms)` | ms | remote `pilot_xds_pushes{type="eds"}` counter delta | Remote EDS convergence: time to the first remote EDS push after t0 — control-plane-only, **excludes** pod boot (analogous to propagation P2). |
| `src_triggers` / `rmt_triggers` | count (delta) | `pilot_push_triggers` counter delta | Push triggers on the source / remote istiod during the churn event. |
| `src_pushes` / `rmt_pushes` | count (delta) | `pilot_xds_pushes` (all types) counter delta | xDS pushes on the source / remote istiod. |
| `src_queue_p99` / `rmt_queue_p99` | ms (bucket range) | `pilot_proxy_queue_time` histogram delta | p99 queue wait on source / remote; bucket range, `overflow`/`N/A` possible. |
| `src_proxies` / `rmt_proxies` | proxies | `pilot_xds` gauge | Connected proxy count on source / remote istiod at baseline. |
| `src_push_p99` / `rmt_push_p99` | ms (bucket range) | `pilot_xds_push_time` histogram delta | p99 time to compute+send each xDS push, source / remote; bucket range, `overflow`/`N/A` possible. |
| `amplification` | ratio | derived | `(src_pushes + rmt_pushes) / src_triggers` — mesh-wide push fan-out per source event; only computed when `src_triggers > 0`; expected ≤ ~1. |
GLOSSARY
}

report_markdown() {
	local harness_sha
	harness_sha=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
	if ! git -C "$ROOT" diff --quiet HEAD 2>/dev/null; then harness_sha="${harness_sha}-dirty"; fi
	local istio_version="${ISTIO_VERSION:-unknown}"

	# Extract sweep axes from TSV data.
	local axes
	axes=$(cat "${TSV_FILES[@]}" | awk -F'\t' '
	!/^#/ && !/^run_id/ && NF>=21 {
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
	# PL19: live-queried tuning-baseline provenance (from the TSV preamble).
	echo "tuning_baseline: \"$(preamble_get TUNING_BASELINE)\""
	echo "sidecar_egress_hosts: \"$(preamble_get SIDECAR_EGRESS_HOSTS)\""
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
	echo "| mesh | churn | scale | n_valid | n_total | local_avg (ms) | remote_reach_avg (ms) | remote_eds_avg (ms) | src_triggers | rmt_triggers | src_pushes | rmt_pushes | src_queue_p99 | rmt_queue_p99 | src_proxies | rmt_proxies | src_push_p99 | rmt_push_p99 | amplification |"
	echo "|------|-------|-------|---------|---------|----------------|-----------------------|---------------------|--------------|--------------|------------|------------|---------------|---------------|-------------|-------------|--------------|--------------|---------------|"
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	# n_total counts EVERY row for the cell; numeric aggregation uses ONLY OK rows
	# (POISONED_*/TIMEOUT_*/SCRAPE_INCOMPLETE carry N/A or undercounted deltas).
	!/^#/ && !/^run_id/ && NF>=21 {
		key = $2 "\t" $3 "\t" $4 "\t" $5
		seen[key] = 1
		n_total[key]++
		if($21!="OK") next
		n_valid[key]++
		if($8!="TIMEOUT" && $8!="N/A") { cl_sum[key]+=$8+0; cl_n[key]++ }
		if($9!="TIMEOUT" && $9!="N/A") { cr_sum[key]+=$9+0; cr_n[key]++ }
		if($10!="TIMEOUT" && $10!="N/A") { cre_sum[key]+=$10+0; cre_n[key]++ }
		if($11!="N/A") { spt_sum[key]+=$11+0; spt_n[key]++ }
		if($12!="N/A") { rpt_sum[key]+=$12+0; rpt_n[key]++ }
		if($13!="N/A") { sxp_sum[key]+=$13+0; sxp_n[key]++ }
		if($14!="N/A") { rxp_sum[key]+=$14+0; rxp_n[key]++ }
		if($15!="N/A" && $15!="overflow") { sqq_sum[key]+=$15+0; sqq_n[key]++ }
		if($16!="N/A" && $16!="overflow") { rqq_sum[key]+=$16+0; rqq_n[key]++ }
		if($17!="N/A") { scp_sum[key]+=$17+0; scp_n[key]++ }
		if($18!="N/A") { rcp_sum[key]+=$18+0; rcp_n[key]++ }
		if($19!="N/A" && $19!="overflow") { spt2_sum[key]+=$19+0; spt2_n[key]++ }
		if($20!="N/A" && $20!="overflow") { rpt2_sum[key]+=$20+0; rpt2_n[key]++ }
		if($11!="N/A" && $11+0 > 0 && $13!="N/A") { amp_sum[key]+=($13+0 + ($14=="N/A" ? 0 : $14+0)) / $11; amp_n[key]++ }
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
		any_filtered = 0
		for(k=1; k<=n_keys; k++) {
			key = sorted_keys[k]; split(key, p, "\t")
			if ((n_valid[key]+0) < (n_total[key]+0)) any_filtered = 1
			printf "| %s | %s | %s->%s | %d | %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", \
				p[1], p[2], p[3], p[4], n_valid[key]+0, n_total[key]+0, \
				avg_or_na(cl_sum[key], cl_n[key]), \
				avg_or_na(cr_sum[key], cr_n[key]), \
				avg_or_na(cre_sum[key], cre_n[key]), \
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
		# PL15: surface the filter rate when any cell dropped rows.
		if (any_filtered) {
			printf "\n> \\* Some rows were filtered from the averages (`n_valid < n_total`): rows with `status != OK` (POISONED_RESTART / SCRAPE_INCOMPLETE / TIMEOUT_*) are excluded from numeric aggregation but still counted in `n_total`.\n"
		}
	}'

	# #17: metric glossary at the very end of the markdown summary.
	glossary_section
}

report_charts() {
	local harness_sha
	harness_sha=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
	if ! git -C "$ROOT" diff --quiet HEAD 2>/dev/null; then harness_sha="${harness_sha}-dirty"; fi
	local istio_version="${ISTIO_VERSION:-unknown}"

	echo "---"
	echo "istio_version: ${istio_version}"
	echo "harness_sha: ${harness_sha}"
	echo "files_consumed: ${#TSV_FILES[@]}"
	echo "generated: $(date -u -Iseconds)"
	echo "---"
	echo ""
	echo "# Churn Convergence — Charts"
	echo ""
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	# PL13/PL15 gate: charts aggregate per mesh size over VALID rows only ($21=="OK").
	# Count total vs valid rows so a dropped (restart-poisoned / non-OK) row never lands
	# as a 0 data point silently — a per-mesh-size series point with zero valid rows is
	# ABSENT (cl_n[ms]==0 -> not plotted), and the caption mirrors the markdown footnote.
	!/^#/ && !/^run_id/ && NF>=21 {
		rows_total++
		if ($21 != "OK") { rows_dropped++; next }
	}
	!/^#/ && !/^run_id/ && NF>=21 && $21=="OK" {
		ms = $2 + 0
		seen[ms] = 1
		if($8!="TIMEOUT" && $8!="N/A") { cl_sum[ms]+=$8+0; cl_n[ms]++ }
		if($9!="TIMEOUT" && $9!="N/A") { cr_sum[ms]+=$9+0; cr_n[ms]++ }
		if($10!="TIMEOUT" && $10!="N/A") { cre_sum[ms]+=$10+0; cre_n[ms]++ }
		if($13!="N/A") { sxp_sum[ms]+=$13+0; sxp_n[ms]++ }
		if($14!="N/A") { rxp_sum[ms]+=$14+0; rxp_n[ms]++ }
		if($11!="N/A" && $11+0 > 0 && $13!="N/A") {
			amp_sum[ms] += ($13+0 + ($14=="N/A" ? 0 : $14+0)) / $11
			amp_n[ms]++
		}
	}
	function sort_ms(    i, j, tmp, k) {
		n_ms = 0
		for (k in seen) ms_arr[++n_ms] = k + 0
		for (i = 2; i <= n_ms; i++) {
			tmp = ms_arr[i]; j = i - 1
			while (j >= 1 && ms_arr[j] > tmp) { ms_arr[j+1] = ms_arr[j]; j-- }
			ms_arr[j+1] = tmp
		}
	}
	END {
		if (rows_dropped > 0) {
			printf "> %d of %d rows dropped (no valid samples / restart-poisoned; status != OK) — excluded from the charted averages.\n\n", rows_dropped, rows_total
		}
		sort_ms()
		if (n_ms < 2) {
			print "> Charts require at least two mesh sizes."
			exit
		}
		# Collect mesh sizes >= 2 for remote series.
		n_remote = 0
		for (i = 1; i <= n_ms; i++) {
			if (ms_arr[i] >= 2) remote_arr[++n_remote] = ms_arr[i]
		}
		if (n_remote < 2) {
			print "> Charts require at least two mesh sizes with remote data (mesh >= 2)."
			exit
		}

		# Chart 1: Convergence latency vs mesh size
		printf "%% Chart 1: Convergence latency (ms) vs mesh size\n"
		printf "%% Series order: local avg, remote reach avg, remote EDS avg\n"
		printf "%% x-axis starts at mesh 2 (remote series undefined at mesh 1)\n"
		printf "\n```mermaid\n"
		printf "xychart-beta\n"
		printf "    title \"Convergence Latency vs Mesh Size\"\n"
		printf "    x-axis \"Mesh Size\" ["
		for (i = 1; i <= n_remote; i++) {
			if (i > 1) printf ", "
			printf "%s", remote_arr[i]
		}
		printf "]\n"
		printf "    y-axis \"Latency (ms)\"\n"
		printf "    line ["; sep = ""
		for (i = 1; i <= n_remote; i++) {
			ms = remote_arr[i]
			v = (cl_n[ms] > 0) ? cl_sum[ms]/cl_n[ms] : 0
			printf "%s%.0f", sep, v; sep = ", "
		}
		printf "]\n"
		printf "    line ["; sep = ""
		for (i = 1; i <= n_remote; i++) {
			ms = remote_arr[i]
			v = (cr_n[ms] > 0) ? cr_sum[ms]/cr_n[ms] : 0
			printf "%s%.0f", sep, v; sep = ", "
		}
		printf "]\n"
		printf "    line ["; sep = ""
		for (i = 1; i <= n_remote; i++) {
			ms = remote_arr[i]
			v = (cre_n[ms] > 0) ? cre_sum[ms]/cre_n[ms] : 0
			printf "%s%.0f", sep, v; sep = ", "
		}
		printf "]\n"
		printf "```\n\n"
		printf "> Series order: **local avg**, **remote reach avg**, **remote EDS avg**.\n"
		printf "> x-axis starts at mesh 2 — remote metrics are undefined at mesh size 1.\n\n"

		# Chart 2: xDS pushes vs mesh size
		printf "%% Chart 2: xDS pushes vs mesh size\n"
		printf "%% Series order: source xDS pushes, remote xDS pushes\n"
		printf "\n```mermaid\n"
		printf "xychart-beta\n"
		printf "    title \"xDS Pushes vs Mesh Size\"\n"
		printf "    x-axis \"Mesh Size\" ["
		for (i = 1; i <= n_remote; i++) {
			if (i > 1) printf ", "
			printf "%s", remote_arr[i]
		}
		printf "]\n"
		printf "    y-axis \"Push count\"\n"
		printf "    line ["; sep = ""
		for (i = 1; i <= n_remote; i++) {
			ms = remote_arr[i]
			v = (sxp_n[ms] > 0) ? sxp_sum[ms]/sxp_n[ms] : 0
			printf "%s%.0f", sep, v; sep = ", "
		}
		printf "]\n"
		printf "    line ["; sep = ""
		for (i = 1; i <= n_remote; i++) {
			ms = remote_arr[i]
			v = (rxp_n[ms] > 0) ? rxp_sum[ms]/rxp_n[ms] : 0
			printf "%s%.0f", sep, v; sep = ", "
		}
		printf "]\n"
		printf "```\n\n"
		printf "> Series order: **source xDS pushes**, **remote xDS pushes**.\n\n"

		# Chart 3: Push amplification vs mesh size
		printf "%% Chart 3: Push amplification ratio vs mesh size\n"
		printf "\n```mermaid\n"
		printf "xychart-beta\n"
		printf "    title \"Push Amplification vs Mesh Size\"\n"
		printf "    x-axis \"Mesh Size\" ["
		for (i = 1; i <= n_remote; i++) {
			if (i > 1) printf ", "
			printf "%s", remote_arr[i]
		}
		printf "]\n"
		printf "    y-axis \"Amplification ratio\"\n"
		printf "    line ["; sep = ""
		for (i = 1; i <= n_remote; i++) {
			ms = remote_arr[i]
			v = (amp_n[ms] > 0) ? amp_sum[ms]/amp_n[ms] : 0
			printf "%s%.1f", sep, v; sep = ", "
		}
		printf "]\n"
		printf "```\n\n"
		printf "> Series: **push amplification ratio** (total xDS pushes / source push triggers). Expected <= ~1.\n"
	}'
}

case "$FORMAT" in
text)     report_text ;;
csv)      report_csv ;;
markdown) report_markdown ;;
charts)   report_charts ;;
*)        die "unknown format: $FORMAT (use text, csv, markdown, or charts)" ;;
esac

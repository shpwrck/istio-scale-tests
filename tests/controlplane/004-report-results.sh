#!/usr/bin/env bash
# Generate summary statistics from control-plane resource metrics TSV files.
#
# Groups by the four sweep axes — mesh_size, service_count, replicas,
# namespace_count — so the operator can compare any single dimension while
# the other three are held constant.
#
# Usage:
#   ./tests/controlplane/004-report-results.sh [--results-dir DIR]
#
# Examples:
#   ./tests/controlplane/004-report-results.sh
#   ./tests/controlplane/004-report-results.sh --format csv
#   ./tests/controlplane/004-report-results.sh --format json
#   ./tests/controlplane/004-report-results.sh --format markdown
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

RESULTS_DIR="${ROOT}/tests/controlplane/results"
FORMAT="text"

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --results-dir DIR  Results directory (default: tests/controlplane/results).
  --format FMT       Output format: text, csv, json, markdown (default: text).
  -h, --help         Show this help.

Output groups by (mesh_size, service_count, replicas, namespace_count) — every
unique sweep point gets its own row of CPU/memory/convergence/queue stats.
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
text|csv|json|markdown) ;;
*) die "unknown format: $FORMAT (use text, csv, json, or markdown)" ;;
esac

[[ -d "$RESULTS_DIR" ]] || die "results directory not found: $RESULTS_DIR"

TSV_FILES=()
while IFS= read -r f; do
	TSV_FILES+=("$f")
done < <(find "$RESULTS_DIR" -name 'controlplane-*.tsv' -type f 2>/dev/null | sort)

if [[ ${#TSV_FILES[@]} -eq 0 ]]; then
	die "no TSV result files found in $RESULTS_DIR"
fi

# Shared AWK aggregator. Groups by mesh|svc|reps|ns (4-tuple key) and emits
# one record per unique key with min/max/avg for CPU, memory, conv_p99,
# queue_p99, connected_proxies. We assume the new 16-column schema (with
# namespace_count at field 6) — older 15-column TSV files are skipped.
#
# Output: TSV with header
#   mesh_size service_count replicas namespace_count n cpu_min cpu_max cpu_avg
#   mem_min mem_max mem_avg conv99_min conv99_max conv99_avg queue99_min
#   queue99_max queue99_avg proxies_min proxies_max proxies_avg
aggregate() {
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	!/^#/ && !/^timestamp/ && NF>=16 {
		key = $3 "|" $4 "|" $5 "|" $6
		if (!(key in seen)) { keys[++nkey] = key; seen[key] = 1 }
		cpu_sum[key]   += $7;  cpu_min[key]  = (key in cpu_min  && cpu_min[key]  <= $7+0) ? cpu_min[key]  : $7+0;  cpu_max[key]  = (key in cpu_max  && cpu_max[key]  >= $7+0) ? cpu_max[key]  : $7+0
		mem_sum[key]   += $8;  mem_min[key]  = (key in mem_min  && mem_min[key]  <= $8+0) ? mem_min[key]  : $8+0;  mem_max[key]  = (key in mem_max  && mem_max[key]  >= $8+0) ? mem_max[key]  : $8+0
		conv_sum[key]  += $10; conv_min[key] = (key in conv_min && conv_min[key] <= $10+0) ? conv_min[key] : $10+0; conv_max[key] = (key in conv_max && conv_max[key] >= $10+0) ? conv_max[key] : $10+0
		queue_sum[key] += $12; queue_min[key]= (key in queue_min&& queue_min[key]<= $12+0) ? queue_min[key]: $12+0; queue_max[key]= (key in queue_max&& queue_max[key]>= $12+0) ? queue_max[key]: $12+0
		prx_sum[key]   += $15; prx_min[key]  = (key in prx_min  && prx_min[key]  <= $15+0) ? prx_min[key]  : $15+0; prx_max[key]  = (key in prx_max  && prx_max[key]  >= $15+0) ? prx_max[key]  : $15+0
		n[key]++
	}
	END {
		# stable sort by 4-tuple — split key, sort numerically.
		for (i = 1; i <= nkey; i++) order[i] = keys[i]
		for (i = 1; i < nkey; i++) {
			for (j = i + 1; j <= nkey; j++) {
				split(order[i], a, "|"); split(order[j], b, "|")
				swap = 0
				for (k = 1; k <= 4; k++) {
					if (a[k]+0 < b[k]+0) { break }
					if (a[k]+0 > b[k]+0) { swap = 1; break }
				}
				if (swap) { t = order[i]; order[i] = order[j]; order[j] = t }
			}
		}
		printf "mesh_size\tservice_count\treplicas\tnamespace_count\tn\tcpu_min\tcpu_max\tcpu_avg\tmem_min\tmem_max\tmem_avg\tconv99_min\tconv99_max\tconv99_avg\tqueue99_min\tqueue99_max\tqueue99_avg\tproxies_min\tproxies_max\tproxies_avg\n"
		for (i = 1; i <= nkey; i++) {
			k = order[i]
			split(k, p, "|")
			nn = n[k]
			printf "%s\t%s\t%s\t%s\t%d\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\n",
				p[1], p[2], p[3], p[4], nn,
				cpu_min[k],   cpu_max[k],   cpu_sum[k]/nn,
				mem_min[k],   mem_max[k],   mem_sum[k]/nn,
				conv_min[k],  conv_max[k],  conv_sum[k]/nn,
				queue_min[k], queue_max[k], queue_sum[k]/nn,
				prx_min[k],   prx_max[k],   prx_sum[k]/nn
		}
	}'
}

report_text() {
	echo "=== Control-Plane Resource Scaling ==="
	echo ""
	echo "Files: ${TSV_FILES[*]}"
	echo ""
	aggregate | awk -F'\t' '
	NR == 1 { next }
	{
		printf "--- mesh_size=%s service_count=%s replicas=%s namespace_count=%s (n=%s) ---\n", $1, $2, $3, $4, $5
		printf "  istiod CPU (m):          min=%s max=%s avg=%s\n",     $6, $7, $8
		printf "  istiod Memory (Mi):      min=%s max=%s avg=%s\n",     $9, $10, $11
		printf "  Convergence p99 (ms):    min=%s max=%s avg=%s\n",     $12, $13, $14
		printf "  Queue p99 (ms):          min=%s max=%s avg=%s\n",     $15, $16, $17
		printf "  Connected proxies:       min=%s max=%s avg=%s\n",     $18, $19, $20
		printf "\n"
	}'
}

report_csv() {
	aggregate | awk -F'\t' 'BEGIN{OFS=","} { $1=$1; print }'
}

report_markdown() {
	echo "# Control-Plane Resource Scaling"
	echo ""
	echo "Files: ${TSV_FILES[*]}"
	echo ""
	echo "| mesh_size | service_count | replicas | namespace_count | n | cpu_avg (m) | mem_avg (Mi) | conv_p99_avg (ms) | queue_p99_avg (ms) | proxies_avg |"
	echo "|-----------|---------------|----------|-----------------|---|-------------|--------------|-------------------|--------------------|-------------|"
	aggregate | awk -F'\t' '
	NR == 1 { next }
	{ printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $8, $11, $14, $17, $20 }'
}

report_json() {
	aggregate | awk -F'\t' '
	NR == 1 { next }
	{
		if (printed++) printf ",\n"; else printf "[\n"
		printf "  {\"mesh_size\":%s,\"service_count\":%s,\"replicas\":%s,\"namespace_count\":%s,\"n\":%s,",
			$1, $2, $3, $4, $5
		printf "\"cpu_m\":{\"min\":%s,\"max\":%s,\"avg\":%s},",       $6, $7, $8
		printf "\"mem_mi\":{\"min\":%s,\"max\":%s,\"avg\":%s},",      $9, $10, $11
		printf "\"convergence_p99_ms\":{\"min\":%s,\"max\":%s,\"avg\":%s},", $12, $13, $14
		printf "\"queue_p99_ms\":{\"min\":%s,\"max\":%s,\"avg\":%s},",      $15, $16, $17
		printf "\"connected_proxies\":{\"min\":%s,\"max\":%s,\"avg\":%s}}", $18, $19, $20
	}
	END {
		if (printed) printf "\n]\n"; else printf "[]\n"
	}'
}

case "$FORMAT" in
text)     report_text ;;
csv)      report_csv ;;
markdown) report_markdown ;;
json)     report_json ;;
esac

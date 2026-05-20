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

Histogram cells whose target quantile falls in the +Inf overflow bucket are
emitted as the string "overflow" in text/csv/markdown and as null in JSON.
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

ALL_TSV=()
while IFS= read -r f; do
	ALL_TSV+=("$f")
done < <(find "$RESULTS_DIR" -name 'controlplane-*.tsv' -type f 2>/dev/null | sort)

if [[ ${#ALL_TSV[@]} -eq 0 ]]; then
	die "no TSV result files found in $RESULTS_DIR"
fi

# Partition into "new schema" (25 columns) and "legacy" (anything else).
# We do this with a per-file probe of the header line so a partial sweep with
# mixed schemas doesn't poison the aggregation.
TSV_FILES=()
LEGACY_FILES=()
for f in "${ALL_TSV[@]}"; do
	header=$(grep -m1 -v '^#' "$f" 2>/dev/null || true)
	# Count tabs + 1. The new schema has 25 cols (24 tabs).
	tabs=$(awk -F'\t' '{print NF}' <<<"$header")
	if [[ "$tabs" == "25" ]]; then
		TSV_FILES+=("$f")
	else
		LEGACY_FILES+=("$f")
	fi
done

if (( ${#LEGACY_FILES[@]} > 0 )); then
	echo "warning: skipping ${#LEGACY_FILES[@]} legacy TSV file(s) with old schema:" >&2
	for f in "${LEGACY_FILES[@]}"; do
		echo "  $f" >&2
	done
fi

if (( ${#TSV_FILES[@]} == 0 )); then
	die "no TSV files with the current 25-column schema found in $RESULTS_DIR"
fi

# Pluck reproducibility tags from the first new-schema file's preamble.
ISTIO_VERSION_TAG=$(grep -m1 '^# ISTIO_VERSION=' "${TSV_FILES[0]}" 2>/dev/null | sed 's/^# ISTIO_VERSION=//' || echo unknown)
HARNESS_SHA_TAG=$(grep -m1 '^# HARNESS_SHA=' "${TSV_FILES[0]}" 2>/dev/null | sed 's/^# HARNESS_SHA=//' || echo unknown)
FILES_CONSUMED=${#TSV_FILES[@]}
FILES_SKIPPED=${#LEGACY_FILES[@]}

# Shared AWK aggregator. Groups by mesh|svc|reps|ns (4-tuple key) and emits
# one record per unique key with min/max/avg for CPU, memory, conv_p99,
# queue_p99, connected_proxies. Histogram cells that arrive as the string
# "overflow" are tracked separately: a key with *any* overflow sample emits
# the literal "overflow" for that metric and skips it in the numeric min/max
# /avg. Pure-numeric keys behave identically to before.
#
# New 25-column schema (1-indexed):
#  1 timestamp        2 context       3 mesh_size     4 service_count
#  5 replicas         6 namespace_count
#  7 istiod_cpu_m     8 istiod_mem_mi
#  9 convergence_p50_ms  10 convergence_p99_ms
# 11 queue_p50_ms        12 queue_p99_ms
# 13 xds_pushes_delta    14 xds_pushes_rate
# 15..19 xds_pushes_{cds,eds,lds,rds,nds}
# 20 k8s_events_delta    21 k8s_events_rate
# 22 connected_proxies   23 config_size_avg_bytes
# 24 scrape_window_sec   25 scrape_skew_ms
#
# Output (aggregated, tab-separated):
#   mesh_size service_count replicas namespace_count n
#   cpu_min cpu_max cpu_avg
#   mem_min mem_max mem_avg
#   conv99_min conv99_max conv99_avg
#   queue99_min queue99_max queue99_avg
#   proxies_min proxies_max proxies_avg
#
# Any *_min/*_max/*_avg cell where the underlying samples included an
# "overflow" is printed as the literal string "overflow".
aggregate() {
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	function is_num(s) { return s ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	function ingest(metric, val, key,    m) {
		if (val == "overflow") { ov[metric, key] = 1; return }
		if (!is_num(val)) return   # "N/A" or stray strings -> ignore
		if (!((metric, key) in nv)) {
			min[metric, key] = val
			max[metric, key] = val
		} else {
			if (val + 0 < min[metric, key] + 0) min[metric, key] = val
			if (val + 0 > max[metric, key] + 0) max[metric, key] = val
		}
		sum[metric, key] += val
		nv[metric, key] += 1
	}
	function emit3(metric, key,    a, b, c) {
		if ((metric, key) in ov) {
			return "overflow\toverflow\toverflow"
		}
		if (!((metric, key) in nv) || nv[metric, key] == 0) {
			return "0\t0\t0"
		}
		a = min[metric, key]; b = max[metric, key]; c = sum[metric, key] / nv[metric, key]
		return sprintf("%.0f\t%.0f\t%.0f", a+0, b+0, c+0)
	}
	!/^#/ && !/^timestamp/ && NF>=25 {
		key = $3 "|" $4 "|" $5 "|" $6
		if (!(key in seen)) { keys[++nkey] = key; seen[key] = 1 }
		ingest("cpu",   $7,  key)
		ingest("mem",   $8,  key)
		ingest("conv",  $10, key)
		ingest("queue", $12, key)
		ingest("prx",   $22, key)
		n[key]++
	}
	END {
		# Sort by 4-tuple numerically.
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
			printf "%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n",
				p[1], p[2], p[3], p[4], nn,
				emit3("cpu",   k),
				emit3("mem",   k),
				emit3("conv",  k),
				emit3("queue", k),
				emit3("prx",   k)
		}
	}'
}

report_text() {
	echo "=== Control-Plane Resource Scaling ==="
	echo "# ISTIO_VERSION=${ISTIO_VERSION_TAG}  HARNESS_SHA=${HARNESS_SHA_TAG}  files_consumed=${FILES_CONSUMED}  skipped_legacy=${FILES_SKIPPED}"
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
	echo "# ISTIO_VERSION=${ISTIO_VERSION_TAG},HARNESS_SHA=${HARNESS_SHA_TAG},files_consumed=${FILES_CONSUMED},skipped_legacy=${FILES_SKIPPED}"
	aggregate | awk -F'\t' 'BEGIN{OFS=","} { $1=$1; print }'
}

report_markdown() {
	echo "---"
	echo "istio_version: ${ISTIO_VERSION_TAG}"
	echo "harness_sha: ${HARNESS_SHA_TAG}"
	echo "files_consumed: ${FILES_CONSUMED}"
	echo "skipped_legacy: ${FILES_SKIPPED}"
	echo "---"
	echo ""
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

# JSON-encode a single aggregate cell. Numeric strings pass through as-is;
# the literal "overflow" maps to JSON null.
report_json() {
	aggregate | awk -F'\t' -v iv="$ISTIO_VERSION_TAG" -v hs="$HARNESS_SHA_TAG" -v fc="$FILES_CONSUMED" -v fs="$FILES_SKIPPED" '
	function cell(v) {
		if (v == "overflow") return "null"
		return v + 0
	}
	BEGIN { printf "{\n  \"metadata\": {\"istio_version\":\"%s\",\"harness_sha\":\"%s\",\"files_consumed\":%d,\"skipped_legacy\":%d},\n  \"results\": [", iv, hs, fc, fs }
	NR == 1 { next }
	{
		if (printed++) printf ",\n    "; else printf "\n    "
		printf "{\"mesh_size\":%s,\"service_count\":%s,\"replicas\":%s,\"namespace_count\":%s,\"n\":%s,",
			$1, $2, $3, $4, $5
		printf "\"cpu_m\":{\"min\":%s,\"max\":%s,\"avg\":%s},",       cell($6), cell($7), cell($8)
		printf "\"mem_mi\":{\"min\":%s,\"max\":%s,\"avg\":%s},",      cell($9), cell($10), cell($11)
		printf "\"convergence_p99_ms\":{\"min\":%s,\"max\":%s,\"avg\":%s},", cell($12), cell($13), cell($14)
		printf "\"queue_p99_ms\":{\"min\":%s,\"max\":%s,\"avg\":%s},",      cell($15), cell($16), cell($17)
		printf "\"connected_proxies\":{\"min\":%s,\"max\":%s,\"avg\":%s}}", cell($18), cell($19), cell($20)
	}
	END {
		if (printed) printf "\n  ]\n}\n"; else printf "]\n}\n"
	}'
}

case "$FORMAT" in
text)     report_text ;;
csv)      report_csv ;;
markdown) report_markdown ;;
json)     report_json ;;
esac

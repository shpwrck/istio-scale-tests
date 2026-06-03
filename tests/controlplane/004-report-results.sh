#!/usr/bin/env bash
# Generate summary statistics from control-plane resource metrics TSV files.
#
# Groups by the five sweep axes — mesh_size, service_count, replicas,
# namespace_count, sidecar_scoping — so the operator can compare any single
# dimension while the others are held constant.
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
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/config/options.env"  # O9: SCALE_COVERAGE_* knobs (coverage floor)

RESULTS_DIR="${ROOT}/tests/controlplane/results"
FORMAT="text"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --results-dir DIR  Results directory (default: tests/controlplane/results).
  --format FMT       Output format: text, csv, json, markdown (default: text).
  -h, --help         Show this help.

Output groups by (mesh_size, service_count, replicas, namespace_count,
sidecar_scoping) — every unique sweep point gets its own row of
CPU/memory/convergence/queue/config-dump stats.

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

# Partition into "current schema" (40 columns) and "legacy" (anything else).
TSV_FILES=()
LEGACY_FILES=()
for f in "${ALL_TSV[@]}"; do
	header=$(grep -m1 -v '^#' "$f" 2>/dev/null || true)
	tabs=$(awk -F'\t' '{print NF}' <<<"$header")
	if [[ "$tabs" == "40" ]]; then
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
	die "no TSV files with the current 40-column schema found in $RESULTS_DIR"
fi

# Pluck reproducibility tags from the first file's preamble.
ISTIO_VERSION_TAG=$(grep -m1 '^# ISTIO_VERSION=' "${TSV_FILES[0]}" 2>/dev/null | sed 's/^# ISTIO_VERSION=//' || echo unknown)
HARNESS_SHA_TAG=$(grep -m1 '^# HARNESS_SHA=' "${TSV_FILES[0]}" 2>/dev/null | sed 's/^# HARNESS_SHA=//' || echo unknown)
FILES_CONSUMED=${#TSV_FILES[@]}
FILES_SKIPPED=${#LEGACY_FILES[@]}

# Collect SIDECAR_SCOPING across all files; if they all agree, emit scalar.
collect_scopings_meta() {
	local f scoping seen=""
	for f in "${TSV_FILES[@]}"; do
		scoping="$(awk -F'=' '/^# SIDECAR_SCOPING=/{print $2; exit}' "$f")"
		[[ -z "$scoping" ]] && continue
		if [[ -z "$seen" ]]; then
			seen="$scoping"
		elif [[ "$seen" != "$scoping" && "$seen" != "(per-row)" ]]; then
			seen="(per-row)"
		fi
	done
	echo "$seen"
}
SIDECAR_SCOPING_M="$(collect_scopings_meta)"
CONFIG_DUMP_SAMPLES_M=$(grep -m1 '^# CONFIG_DUMP_SAMPLES=' "${TSV_FILES[0]}" 2>/dev/null | sed 's/^# CONFIG_DUMP_SAMPLES=//' || echo "")

# Concatenate KUBE_VERSIONS lines into one readable string.
# 002 writes: # KUBE_VERSIONS=ctx1=v1.29.4, ctx2=v1.29.4  (flat CSV)
collect_kube_versions_meta() {
	local f line all=""
	for f in "${TSV_FILES[@]}"; do
		line=$(grep -m1 '^# KUBE_VERSIONS=' "$f" 2>/dev/null || true)
		[[ -z "$line" ]] && continue
		local val="${line#\# KUBE_VERSIONS=}"
		if [[ -z "$all" ]]; then
			all="$val"
		else
			# Merge entries not already present.
			IFS=',' read -ra entries <<<"$val"
			for entry in "${entries[@]}"; do
				entry="${entry#"${entry%%[![:space:]]*}"}"
				entry="${entry%"${entry##*[![:space:]]}"}"
				[[ -z "$entry" ]] && continue
				[[ "$all" == *"$entry"* ]] || all="${all}, ${entry}"
			done
		fi
	done
	echo "$all"
}
KUBE_VERSIONS_M="$(collect_kube_versions_meta)"

# Extract unique sweep axis values from the TSV data rows.
collect_sweep_axes() {
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	function bsort(arr, n,    i,j,t) {
		for(i=1;i<n;i++) for(j=i+1;j<=n;j++)
			if(arr[i]+0>arr[j]+0||(arr[i]+0==arr[j]+0 && arr[i]>arr[j])){t=arr[i];arr[i]=arr[j];arr[j]=t}
	}
	function collect(src, out,    k,n) {
		n=0; for(k in src) out[++n]=k
		bsort(out,n); return n
	}
	function join(arr, n,    s,i) { s=arr[1]; for(i=2;i<=n;i++) s=s","arr[i]; return s }
	!/^#/ && !/^timestamp/ && NF>=40 {
		mesh[$3]=1; svc[$4]=1; rep[$5]=1; ns[$6]=1; scope[$7]=1
	}
	END {
		n=collect(mesh,a);  printf "mesh_sizes: %s\n", join(a,n)
		n=collect(svc,a);   printf "service_counts: %s\n", join(a,n)
		n=collect(rep,a);   printf "replica_counts: %s\n", join(a,n)
		n=collect(ns,a);    printf "namespace_counts: %s\n", join(a,n)
		n=collect(scope,a); printf "sidecar_scopings: %s\n", join(a,n)
	}'
}
SWEEP_AXES="$(collect_sweep_axes)"
SWEEP_MESH="$(echo "$SWEEP_AXES" | grep '^mesh_sizes:' | cut -d' ' -f2-)"
SWEEP_SVC="$(echo "$SWEEP_AXES" | grep '^service_counts:' | cut -d' ' -f2-)"
SWEEP_REP="$(echo "$SWEEP_AXES" | grep '^replica_counts:' | cut -d' ' -f2-)"
SWEEP_NS="$(echo "$SWEEP_AXES" | grep '^namespace_counts:' | cut -d' ' -f2-)"
SWEEP_SCOPE="$(echo "$SWEEP_AXES" | grep '^sidecar_scopings:' | cut -d' ' -f2-)"

# O9 "Achieved scale" — max of the per-row capacity columns (35-40) and
# connected_proxies (22) across every valid data row. Tolerates N/A: a key with
# no numeric observation reports `unknown`. Emits space-separated key=value pairs
# so the caller can read each. service_count axis (SWEEP_SVC) is the configured
# workload size; we surface it as services_total best-effort (max over rows).
collect_achieved_scale() {
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	function isnum(s) { return s ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	function upd(name, v) {
		if (!isnum(v)) return
		if (!(name in seen) || v+0 > mx[name]+0) { mx[name] = v+0; seen[name] = 1 }
	}
	!/^#/ && !/^timestamp/ && NF>=40 {
		upd("proxies",  $22)
		upd("svc",      $4)
		upd("istiod_cpu_pct", $35)
		upd("istiod_mem_pct", $36)
		upd("node_cpu_pct",   $37)
		upd("node_mem_pct",   $38)
		upd("pods_sched",     $39)
		upd("pods_alloc",     $40)
	}
	END {
		split("proxies svc istiod_cpu_pct istiod_mem_pct node_cpu_pct node_mem_pct pods_sched pods_alloc", ks, " ")
		out = ""
		for (i = 1; i <= 8; i++) {
			k = ks[i]
			v = (k in seen) ? mx[k] : "unknown"
			out = out (out == "" ? "" : " ") k "=" v
		}
		print out
	}'
}
ACHIEVED_SCALE="$(collect_achieved_scale)"
as_get() {
	# Pull one key=value out of ACHIEVED_SCALE; default unknown.
	local key="$1" tok
	for tok in $ACHIEVED_SCALE; do
		[[ "$tok" == "${key}="* ]] && { echo "${tok#"${key}="}"; return; }
	done
	echo "unknown"
}

# O9 coverage floor: achieved pods (pods_scheduled max) vs allocatable; the
# achieved fraction is informational unless SCALE_COVERAGE_ENFORCE=1. We use
# pods_scheduled/pods_allocatable as the achieved-vs-capacity proxy (the per-row
# legibility columns), independent of the Phase-2 sizing math in 001.
COVERAGE_STATUS="N/A"      # OK | UNDER | N/A
COVERAGE_LINE=""
compute_coverage() {
	local sched alloc
	sched="$(as_get pods_sched)"
	alloc="$(as_get pods_alloc)"
	local frac min enforce
	min="${SCALE_COVERAGE_MIN_FRACTION:-0.25}"
	enforce="${SCALE_COVERAGE_ENFORCE:-0}"
	if [[ "$sched" == unknown || "$alloc" == unknown ]]; then
		COVERAGE_STATUS="N/A"
		COVERAGE_LINE="SCALE_COVERAGE: unknown (pods_scheduled or pods_allocatable unavailable)"
		return 0
	fi
	frac="$(awk -v s="$sched" -v a="$alloc" 'BEGIN{ if (a+0<=0){print "0"} else printf "%.3f", s/a }')"
	local under
	under="$(awk -v f="$frac" -v m="$min" 'BEGIN{ print (f+0 < m+0) ? 1 : 0 }')"
	if (( under )); then
		COVERAGE_STATUS="UNDER"
		COVERAGE_LINE="SCALE_COVERAGE: UNDER (achieved ${sched}/${alloc} pods = ${frac} < min ${min}; enforce=${enforce})"
	else
		COVERAGE_STATUS="OK"
		COVERAGE_LINE="SCALE_COVERAGE: OK (achieved ${sched}/${alloc} pods = ${frac} >= min ${min})"
	fi
	return 0
}
compute_coverage

# Shared AWK aggregator. Groups by 5-tuple (mesh|svc|reps|ns|scoping) and
# emits one record per unique key with min/max/avg for core metrics plus
# sidecar config-dump aggregates.
#
# 40-column schema (1-indexed):
#  1 timestamp          2 context            3 mesh_size        4 service_count
#  5 replicas           6 namespace_count    7 sidecar_scoping
#  8 istiod_mem_mi
#  9 convergence_p50_ms  10 convergence_p99_ms
# 11 queue_p50_ms        12 queue_p99_ms
# 13 xds_pushes_delta    14 xds_pushes_rate
# 15..19 xds_pushes_{cds,eds,lds,rds,nds}
# 20 k8s_events_delta    21 k8s_events_rate
# 22 connected_proxies   23 config_size_avg_bytes
# 24 sidecar_config_bytes_avg  25 sidecar_config_bytes_p50
# 26 sidecar_config_bytes_max  27 sidecar_config_bytes_samples
# 28 scrape_window_sec   29 scrape_skew_ms
# 30 settle_sec          31 istiod_restarted
# 32 istiod_cpu_m_delta
# 33 go_heap_alloc_mi    34 go_heap_inuse_mi
# O9 capacity legibility (per-row; surfaced in the achieved-scale block, NOT
# aggregated here — they are point-in-time capacity reads, not windowed metrics):
# 35 istiod_cpu_pct_of_limit  36 istiod_mem_pct_of_limit
# 37 node_cpu_pct             38 node_mem_pct
# 39 pods_scheduled           40 pods_allocatable
#
# Aggregated output (tab-separated, 34 columns):
#   mesh_size service_count replicas namespace_count sidecar_scoping n_total n_valid
#   mem_min mem_max mem_avg
#   conv99_min conv99_max conv99_avg
#   queue99_min queue99_max queue99_avg
#   proxies_min proxies_max proxies_avg
#   restarts unknown_restarts
#   cpu_delta_min cpu_delta_max cpu_delta_avg
#   cfg_dump_avg cfg_dump_max
#   conv99_floor_pinned queue99_floor_pinned
#   heap_alloc_min heap_alloc_max heap_alloc_avg
#   heap_inuse_min heap_inuse_max heap_inuse_avg
aggregate() {
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	function is_num(s) { return s ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	function ingest(metric, val, key,    m) {
		if (val == "overflow") { ov[metric, key] = 1; return }
		if (!is_num(val)) return
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
	!/^#/ && !/^timestamp/ && NF>=40 {
		key = $3 "|" $4 "|" $5 "|" $6 "|" $7
		if (!(key in seen)) { keys[++nkey] = key; seen[key] = 1 }
		# Gauge metrics (mem, proxies, heap) can always be ingested.
		ingest("mem",       $8,  key)
		ingest("prx",       $22, key)
		ingest("heap_alloc", $33, key)
		ingest("heap_inuse", $34, key)
		# Config-dump bytes are independent of istiod counters — always OK.
		if ($24 ~ /^[0-9.]+$/) { cfg_avg_n[key]++; cfg_avg_sum[key] += $24+0 }
		if ($26 ~ /^[0-9.]+$/) {
			if (!(key in cfg_max_val) || $26+0 > cfg_max_val[key]+0) cfg_max_val[key] = $26+0
		}
		if ($31 == "1") restarts[key] += 1
		else if ($31 == "unknown") unknowns[key] += 1
		n_total[key]++
		# Counter/histogram metrics are only valid when istiod did not
		# restart (PL13/PL15). Skip ingestion for restarted/unknown rows.
		if ($31 == "0") {
			ingest("conv",      $10, key)
			ingest("queue",     $12, key)
			ingest("cpu_delta", $32, key)
			n_valid[key]++
		}
	}
	END {
		for (i = 1; i <= nkey; i++) order[i] = keys[i]
		# S9 sort fix: track `decided` flag so the string comparison
		# for sidecar_scoping only fires when no numeric field resolved
		# the ordering.
		for (i = 1; i < nkey; i++) {
			for (j = i + 1; j <= nkey; j++) {
				split(order[i], a, "|"); split(order[j], b, "|")
				swap = 0; decided = 0
				for (k = 1; k <= 4; k++) {
					if (a[k]+0 < b[k]+0) { decided = 1; break }
					if (a[k]+0 > b[k]+0) { swap = 1; decided = 1; break }
				}
				if (!decided && a[5] > b[5]) swap = 1
				if (swap) { t = order[i]; order[i] = order[j]; order[j] = t }
			}
		}
		printf "mesh_size\tservice_count\treplicas\tnamespace_count\tsidecar_scoping\tn_total\tn_valid\tmem_min\tmem_max\tmem_avg\tconv99_min\tconv99_max\tconv99_avg\tqueue99_min\tqueue99_max\tqueue99_avg\tproxies_min\tproxies_max\tproxies_avg\trestarts\tunknown_restarts\tcpu_delta_min\tcpu_delta_max\tcpu_delta_avg\tcfg_dump_avg\tcfg_dump_max\tconv99_floor_pinned\tqueue99_floor_pinned\theap_alloc_min\theap_alloc_max\theap_alloc_avg\theap_inuse_min\theap_inuse_max\theap_inuse_avg\n"
		for (i = 1; i <= nkey; i++) {
			k = order[i]
			split(k, p, "|")
			nt = n_total[k]+0
			nv_count = (k in n_valid) ? n_valid[k] : 0
			rr = (k in restarts) ? restarts[k] : 0
			uu = (k in unknowns) ? unknowns[k] : 0
			ca = (cfg_avg_n[k]+0 > 0) ? sprintf("%.0f", cfg_avg_sum[k] / cfg_avg_n[k]) : "0"
			cm = (k in cfg_max_val) ? sprintf("%.0f", cfg_max_val[k]+0) : "0"
			conv_fp = (nv[("conv"), k]+0 > 0 && max[("conv"), k]+0 == 100) ? 1 : 0
			queue_fp = (nv[("queue"), k]+0 > 0 && max[("queue"), k]+0 == 100) ? 1 : 0
			printf "%s\t%s\t%s\t%s\t%s\t%d\t%d\t%s\t%s\t%s\t%s\t%d\t%d\t%s\t%s\t%s\t%d\t%d\t%s\t%s\n",
				p[1], p[2], p[3], p[4], p[5], nt, nv_count,
				emit3("mem",       k),
				emit3("conv",      k),
				emit3("queue",     k),
				emit3("prx",       k),
				rr, uu,
				emit3("cpu_delta", k),
				ca, cm,
				conv_fp, queue_fp,
				emit3("heap_alloc", k),
				emit3("heap_inuse", k)
		}
	}'
}

report_text() {
	echo "=== Control-Plane Resource Scaling ==="
	echo "# ISTIO_VERSION=${ISTIO_VERSION_TAG}  HARNESS_SHA=${HARNESS_SHA_TAG}  files_consumed=${FILES_CONSUMED}  skipped_legacy=${FILES_SKIPPED}"
	echo ""
	# O9 achieved-scale block (clearly delimited; tolerates unknown). Pulled from
	# the per-row capacity columns (max across rows) + the preamble.
	echo "--- Achieved scale vs capacity (O9) ---"
	echo "  connected_proxies (max):     $(as_get proxies)"
	echo "  services_total (max):        $(as_get svc)"
	echo "  istiod_cpu_pct_of_limit (max): $(as_get istiod_cpu_pct)"
	echo "  istiod_mem_pct_of_limit (max): $(as_get istiod_mem_pct)"
	echo "  node_cpu_pct (max):          $(as_get node_cpu_pct)"
	echo "  node_mem_pct (max):          $(as_get node_mem_pct)"
	echo "  pods_scheduled / allocatable: $(as_get pods_sched) / $(as_get pods_alloc)"
	echo "  ${COVERAGE_LINE}"
	echo ""
	echo "Sweep axes:"
	echo "  mesh_sizes:        ${SWEEP_MESH}"
	echo "  service_counts:    ${SWEEP_SVC}"
	echo "  replica_counts:    ${SWEEP_REP}"
	echo "  namespace_counts:  ${SWEEP_NS}"
	echo "  sidecar_scopings:  ${SWEEP_SCOPE}"
	echo ""
	echo "Files: ${TSV_FILES[*]}"
	echo ""
	aggregate | awk -F'\t' '
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
	NR == 1 { next }
	{
		printf "--- mesh_size=%s service_count=%s replicas=%s namespace_count=%s sidecar_scoping=%s (n_total=%s n_valid=%s) ---\n", $1, $2, $3, $4, $5, $6, $7
		printf "  istiod CPU avg (m):   min=%s max=%s avg=%s   [process_cpu_seconds_total delta over window]\n", $22, $23, $24
		printf "  istiod Memory (Mi):   min=%s max=%s avg=%s   [process_resident_memory_bytes peak]\n", $8, $9, $10
		printf "  Go heap alloc (Mi):   min=%s max=%s avg=%s   [go_memstats_alloc_bytes]\n", $29, $30, $31
		printf "  Go heap inuse (Mi):   min=%s max=%s avg=%s   [go_memstats_heap_inuse_bytes]\n", $32, $33, $34
		printf "  Convergence p99 (ms): %s\n", bucket_range($12)
		printf "  Queue p99 (ms):       %s\n", bucket_range($15)
		printf "  Connected proxies:    min=%s max=%s avg=%s\n",     $17, $18, $19
		if ($25+0 > 0) printf "  Config dump avg (MB): %.1f   max: %.1f\n", $25/1048576, $26/1048576
		else if ($6 > 0) printf "  Config dump avg (MB): N/A\n"
		if ($20+0 > 0) printf "  ! istiod restarts:    %s row(s) had restarts during the scrape window\n", $20
		if ($21+0 > 0) printf "  ? undetectable restart: %s row(s) had unknown restart state (missing process_start_time_seconds)\n", $21
		printf "\n"
	}'
}

report_csv() {
	echo "# ISTIO_VERSION=${ISTIO_VERSION_TAG},HARNESS_SHA=${HARNESS_SHA_TAG},files_consumed=${FILES_CONSUMED},skipped_legacy=${FILES_SKIPPED}"
	echo "# sweep: mesh_sizes=${SWEEP_MESH} service_counts=${SWEEP_SVC} replica_counts=${SWEEP_REP} namespace_counts=${SWEEP_NS} sidecar_scopings=${SWEEP_SCOPE}"
	aggregate | awk -F'\t' 'BEGIN{OFS=","} { $1=$1; print }'
}

report_markdown() {
	local aggregated
	aggregated=$(aggregate)
	local total_restarts total_unknowns
	total_restarts=$(awk -F'\t' 'NR>1 { s += $20+0 } END { printf "%d", s+0 }' <<<"$aggregated")
	total_unknowns=$(awk -F'\t' 'NR>1 { s += $21+0 } END { printf "%d", s+0 }' <<<"$aggregated")

	echo "---"
	echo "istio_version: ${ISTIO_VERSION_TAG}"
	echo "harness_sha: ${HARNESS_SHA_TAG}"
	echo "sidecar_scoping: ${SIDECAR_SCOPING_M:-N/A}"
	echo "config_dump_samples: ${CONFIG_DUMP_SAMPLES_M:-N/A}"
	echo "kube_versions: ${KUBE_VERSIONS_M:-N/A}"
	echo "files_consumed: ${FILES_CONSUMED}"
	echo "skipped_legacy: ${FILES_SKIPPED}"
	echo "---"
	echo ""
	echo "# Control-Plane Resource Scaling"
	echo ""
	# O9 achieved-scale block (clearly delimited; does not inject columns into the
	# aggregate tables, so csv/json row consumers are unaffected).
	echo "## Achieved scale vs capacity (O9)"
	echo ""
	echo "| Metric | Value |"
	echo "|--------|-------|"
	echo "| connected_proxies (max) | $(as_get proxies) |"
	echo "| services_total (max) | $(as_get svc) |"
	echo "| istiod_cpu_pct_of_limit (max) | $(as_get istiod_cpu_pct) |"
	echo "| istiod_mem_pct_of_limit (max) | $(as_get istiod_mem_pct) |"
	echo "| node_cpu_pct (max) | $(as_get node_cpu_pct) |"
	echo "| node_mem_pct (max) | $(as_get node_mem_pct) |"
	echo "| pods_scheduled / allocatable | $(as_get pods_sched) / $(as_get pods_alloc) |"
	echo ""
	echo "> ${COVERAGE_LINE}"
	echo ""
	echo "| Axis | Values |"
	echo "|------|--------|"
	echo "| mesh_sizes | ${SWEEP_MESH} |"
	echo "| service_counts | ${SWEEP_SVC} |"
	echo "| replica_counts | ${SWEEP_REP} |"
	echo "| namespace_counts | ${SWEEP_NS} |"
	echo "| sidecar_scopings | ${SWEEP_SCOPE} |"
	echo ""
	echo "Files: ${TSV_FILES[*]}"
	echo ""
	echo "| mesh_size | svc | reps | ns | scoping | n_total | n_valid | cpu_avg (m) | mem_avg (Mi) | heap_alloc (Mi) | heap_inuse (Mi) | conv_p99 (ms) | queue_p99 (ms) | proxies | cfg_dump_avg (MB) | restarts | unk_restarts |"
	echo "|-----------|-----|------|----|---------|---------|---------|-------------|--------------|-----------------|-----------------|---------------|----------------|---------|-------------------|----------|--------------|"
	awk -F'\t' '
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
	NR == 1 { next }
	{
		cfg_mb = ($25+0 > 0) ? sprintf("%.1f", $25/1048576) : "N/A"
		ha = ($31+0 > 0) ? sprintf("%.0f", $31) : "N/A"
		hi = ($34+0 > 0) ? sprintf("%.0f", $34) : "N/A"
		printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6, $7, $24, $10, ha, hi, bucket_range($12), bucket_range($15), $19, cfg_mb, $20, $21
	}' <<<"$aggregated"
	if (( total_restarts > 0 || total_unknowns > 0 )); then
		echo ""
		local parts=()
		(( total_restarts > 0 )) && parts+=("${total_restarts} row(s) had istiod restarts during the scrape window")
		(( total_unknowns > 0 )) && parts+=("${total_unknowns} row(s) had undetectable restart state during the window")
		local joined="${parts[0]}"
		[[ ${#parts[@]} -gt 1 ]] && joined+="; ${parts[1]}"
		echo "> ${joined} — counters/histograms for those samples may under-report and should be treated as suspect."
	fi

	# Sidecar scoping effect table: compare config sizes across scoping modes
	# for each (mesh_size, service_count, replicas, namespace_count) combo.
	cat <<'EFFECT_HDR'

## Sidecar scoping effect on per-proxy config size

Lower is better. The expected ordering is `none` > `namespace` >= `explicit`.

EFFECT_HDR
	awk -F'\t' '
	NR == 1 { next }
	{
		base = $1 "|" $2 "|" $3 "|" $4
		scope = $5
		cfg = $25 + 0
		val[base, scope] = cfg
		has[base, scope] = 1
		if (!(base in base_seen)) { bases[++nb] = base; base_seen[base] = 1 }
	}
	END {
		if (nb == 0) exit
		any_scoping = 0
		for (i = 1; i <= nb; i++) {
			b = bases[i]
			if (has[b, "namespace"] || has[b, "explicit"]) { any_scoping = 1; break }
		}
		if (!any_scoping) { print "(No sidecar scoping data to compare.)"; exit }
		printf "| mesh | svc | reps | ns | none (MB) | namespace (MB) | explicit (MB) | none->ns | none->explicit |\n"
		printf "|------|-----|------|----|-----------|----------------|---------------|----------|----------------|\n"
		for (i = 1; i <= nb; i++) {
			b = bases[i]
			split(b, p, "|")
			n_v  = has[b,"none"]     ? val[b,"none"]     : -1
			ns_v = has[b,"namespace"]? val[b,"namespace"] : -1
			ex_v = has[b,"explicit"] ? val[b,"explicit"]  : -1
			ns_r = (n_v>0 && ns_v>=0) ? sprintf("%.1f%%", 100*(n_v-ns_v)/n_v) : "N/A"
			ex_r = (n_v>0 && ex_v>=0) ? sprintf("%.1f%%", 100*(n_v-ex_v)/n_v) : "N/A"
			printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", \
				p[1], p[2], p[3], p[4], \
				(n_v<0  ? "N/A" : sprintf("%.1f", n_v/1048576)), \
				(ns_v<0 ? "N/A" : sprintf("%.1f", ns_v/1048576)), \
				(ex_v<0 ? "N/A" : sprintf("%.1f", ex_v/1048576)), \
				ns_r, ex_r
		}
	}' <<<"$aggregated"
}

report_json() {
	aggregate | awk -F'\t' -v iv="$ISTIO_VERSION_TAG" -v hs="$HARNESS_SHA_TAG" -v fc="$FILES_CONSUMED" -v fs="$FILES_SKIPPED" \
		-v sw_mesh="$SWEEP_MESH" -v sw_svc="$SWEEP_SVC" -v sw_rep="$SWEEP_REP" -v sw_ns="$SWEEP_NS" -v sw_scope="$SWEEP_SCOPE" '
	function cell(v) {
		if (v == "overflow") return "null"
		return v + 0
	}
	BEGIN { printf "{\n  \"metadata\": {\"istio_version\":\"%s\",\"harness_sha\":\"%s\",\"files_consumed\":%d,\"skipped_legacy\":%d,\"sweep\":{\"mesh_sizes\":\"%s\",\"service_counts\":\"%s\",\"replica_counts\":\"%s\",\"namespace_counts\":\"%s\",\"sidecar_scopings\":\"%s\"}},\n  \"results\": [", iv, hs, fc, fs, sw_mesh, sw_svc, sw_rep, sw_ns, sw_scope }
	NR == 1 { next }
	{
		if (printed++) printf ",\n    "; else printf "\n    "
		printf "{\"mesh_size\":%s,\"service_count\":%s,\"replicas\":%s,\"namespace_count\":%s,\"sidecar_scoping\":\"%s\",\"n_total\":%s,\"n_valid\":%s,",
			$1, $2, $3, $4, $5, $6, $7
		printf "\"cpu_m_delta\":{\"min\":%s,\"max\":%s,\"avg\":%s},", cell($22), cell($23), cell($24)
		printf "\"mem_mi\":{\"min\":%s,\"max\":%s,\"avg\":%s},",      cell($8), cell($9), cell($10)
		printf "\"convergence_p99_ms\":{\"min\":%s,\"max\":%s,\"avg\":%s},", cell($11), cell($12), cell($13)
		printf "\"queue_p99_ms\":{\"min\":%s,\"max\":%s,\"avg\":%s},",      cell($14), cell($15), cell($16)
		printf "\"connected_proxies\":{\"min\":%s,\"max\":%s,\"avg\":%s},", cell($17), cell($18), cell($19)
		printf "\"istiod_restarted_rows\":%d,\"istiod_restarted_unknown_rows\":%d,", $20+0, $21+0
		printf "\"sidecar_config_bytes_avg\":%s,\"sidecar_config_bytes_max\":%s,", cell($25), cell($26)
		printf "\"go_heap_alloc_mi\":{\"min\":%s,\"max\":%s,\"avg\":%s},", cell($29), cell($30), cell($31)
		printf "\"go_heap_inuse_mi\":{\"min\":%s,\"max\":%s,\"avg\":%s}}", cell($32), cell($33), cell($34)
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

# O9 coverage-floor enforcement (DEFAULT-OFF). Only fails the report when the
# operator opted in via SCALE_COVERAGE_ENFORCE=1 AND achieved scale is under the
# floor. With ENFORCE=0 (default) this is informational only — behaviour unchanged.
if [[ "${SCALE_COVERAGE_ENFORCE:-0}" == "1" && "$COVERAGE_STATUS" == "UNDER" ]]; then
	echo "${COVERAGE_LINE}" >&2
	die "scale coverage under floor (SCALE_COVERAGE_ENFORCE=1)"
fi

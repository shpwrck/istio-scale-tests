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
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/envelope.sh"  # env_sla_verdict (customer SLA headline)

RESULTS_DIR="${ROOT}/tests/controlplane/results"
FORMAT="text"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --results-dir DIR  Results directory (default: tests/controlplane/results).
  --format FMT       Output format: text, csv, json, markdown, charts (default: text).
  -h, --help         Show this help.

Output groups by (mesh_size, service_count, replicas, namespace_count,
sidecar_scoping) — every unique sweep point gets its own row of
CPU/memory/convergence/queue/config-dump stats.

Histogram cells whose target quantile falls in the +Inf overflow bucket are
emitted as the string "overflow" in text/csv/markdown and as null in JSON.

Environment (O9 scale-coverage floor; default-off):
  SCALE_COVERAGE_MIN_FRACTION  Min achieved pods/allocatable fraction for the
                               "Achieved scale" block (default: 0.25).
  SCALE_COVERAGE_ENFORCE        When 1, exit non-zero if achieved scale is under
                               the floor (default: 0 — informational only).
  SCALE_SIZING_MODE             Read from the TSV preamble (env fallback: fixed).
                               The coverage floor only fires (UNDER / enforced
                               failure) when =auto; in fixed mode coverage is
                               reported as informational (no UNDER, no hard-fail).
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
text|csv|json|markdown|charts) ;;
*) die "unknown format: $FORMAT (use text, csv, json, markdown, or charts)" ;;
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

# C2: infra-schema concordance guard (mirrors the data-row width gate above). The
# 40-column data schema is gated by `tabs == 40`, but the additive cluster-infra
# preamble carries its OWN version marker (CONTROLPLANE_INFRA_SCHEMA). A future v2 bump
# could change an infra key's SEMANTICS without changing the 40-col data width, so a
# v1 file and a v2 file would pass the width gate and silently mix. Warn (don't die —
# the data rows are still aggregable) if the consumed files disagree on the infra
# schema, or if some carry it and others don't (a legacy 40-col file predating the
# infra block reads as `unknown`).
infra_schemas=""
for f in "${TSV_FILES[@]}"; do
	# `|| true`: a legacy 40-col file predating the infra block has no match; under
	# `set -o pipefail` the grep|sed pipeline would otherwise fail the assignment.
	v=$(grep -m1 '^# CONTROLPLANE_INFRA_SCHEMA=' "$f" 2>/dev/null | sed 's/^# CONTROLPLANE_INFRA_SCHEMA=//' || true)
	[[ -z "$v" ]] && v="absent"
	case " $infra_schemas " in *" $v "*) ;; *) infra_schemas="${infra_schemas:+$infra_schemas }$v" ;; esac
done
if [[ "$infra_schemas" == *" "* ]]; then
	echo "warning: input TSVs disagree on CONTROLPLANE_INFRA_SCHEMA (${infra_schemas// /, }) — infra-preamble keys may carry mixed semantics; verify the sweep dir holds one coherent run" >&2
fi

# Pluck reproducibility tags from the first file's preamble.
ISTIO_VERSION_TAG=$(grep -m1 '^# ISTIO_VERSION=' "${TSV_FILES[0]}" 2>/dev/null | sed 's/^# ISTIO_VERSION=//' || echo unknown)
HARNESS_SHA_TAG=$(grep -m1 '^# HARNESS_SHA=' "${TSV_FILES[0]}" 2>/dev/null | sed 's/^# HARNESS_SHA=//' || echo unknown)
# RUN_ID from the TSV preamble (PL2/PL19) — so committed campaign artifacts are
# attributable to the sweep that produced them. Emitted in all four formats below.
RUN_ID_TAG=$(grep -m1 '^# RUN_ID=' "${TSV_FILES[0]}" 2>/dev/null | sed 's/^# RUN_ID=//' || echo unknown)
[[ -n "$RUN_ID_TAG" ]] || RUN_ID_TAG=unknown
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
# connected_proxies (22) across every VALID data row (istiod_restarted==0, col 31).
# Mirroring the n_valid gate (PL13/PL15) is essential: a SETUP_FAILED / restarted row
# still carries the CONFIGURED service_count ($4) and a mid-reconnect connected_proxies
# ($22), so ingesting it would report e.g. "200 services achieved" when 0 deployed.
# Tolerates N/A: a key with no numeric observation reports `unknown`. Emits
# space-separated key=value pairs. services_total is the configured service_count of
# valid rows (controlplane has no distinct achieved-services metric) — best-effort, so
# the report surfaces it as `services_total [configured]` to flag it as intent, not a
# measured achieved count (PL35: label a configured axis honestly).
collect_achieved_scale() {
	cat "${TSV_FILES[@]}" | awk -F'\t' '
	function isnum(s) { return s ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	function upd(name, v) {
		if (!isnum(v)) return
		if (!(name in seen) || v+0 > mx[name]+0) { mx[name] = v+0; seen[name] = 1 }
	}
	!/^#/ && !/^timestamp/ && NF>=40 && $31 == "0" {
		upd("proxies",  $22)
		upd("svc",      $4)
		upd("istiod_cpu_pct", $35)
		upd("istiod_mem_pct", $36)
		upd("node_cpu_pct",   $37)
		upd("node_mem_pct",   $38)
		upd("pods_sched",     $39)
		upd("pods_alloc",     $40)
		# P1-4: peak istiod RSS (process_resident_memory_bytes -> col 8, per-replica
		# MiB). Always available from the /metrics scrape (unlike $36, which is the
		# kubectl-top path and N/As during a metrics-API gap), so it gives an OOM
		# headroom signal even when top is down. Per-replica reading; the % is taken
		# against the PER-REPLICA mem limit downstream (clean per-replica/per-replica
		# ratio — PL35), NOT the cross-replica limit.
		upd("istiod_rss_mem_mi", $8)
	}
	END {
		split("proxies svc istiod_cpu_pct istiod_mem_pct node_cpu_pct node_mem_pct pods_sched pods_alloc istiod_rss_mem_mi", ks, " ")
		out = ""
		for (i = 1; i <= 9; i++) {
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
as_pct() {
	# as_get + a trailing % on a numeric value (leaves unknown/N/A bare).
	local v; v="$(as_get "$1")"
	[[ "$v" =~ ^-?[0-9.]+$ ]] && echo "${v}%" || echo "$v"
}
pct_or_bare() {
	# Trailing % on a numeric value (leaves unknown/N/A bare). For pre-computed
	# scalars (not in ACHIEVED_SCALE) like the P1-4 RSS mem pct.
	local v="${1:-unknown}"
	[[ "$v" =~ ^-?[0-9.]+$ ]] && echo "${v}%" || echo "$v"
}
# Pull a `# KEY=value` provenance line from the first TSV preamble (absolute
# allocatable / istiod-limit context for the achieved-scale block); default unknown.
preamble_get() {
	local key="$1" v
	v="$(grep -m1 "^# ${key}=" "${TSV_FILES[0]}" 2>/dev/null | head -1)"
	v="${v#*=}"
	[[ -n "$v" ]] && echo "$v" || echo "unknown"
}

# #44: the four utilization-% maxes (istiod_*_pct_of_limit, node_*_pct) are derived
# from `kubectl top` (the metrics API). When the metrics API is unavailable on the
# target clusters, all four come back N/A while the get-derived denominators
# (allocatable, istiod limit, pod counts) still populate. Detect exactly that case —
# every utilization-% max non-numeric — so an empty utilization headline reads as a
# known environment limitation rather than a harness bug. Returns 0 when unavailable.
METRICS_NOTE="utilization-% columns are N/A — the metrics API (kubectl top / metrics-server) returned no usable data during this sweep; verify metrics-server availability on the target clusters to populate istiod_*_pct_of_limit and node_*_pct. Capacity denominators below come from kubectl get and are unaffected."
metrics_unavailable() {
	local key v
	for key in istiod_cpu_pct istiod_mem_pct node_cpu_pct node_mem_pct; do
		v="$(as_get "$key")"
		[[ "$v" =~ ^-?[0-9.]+$ ]] && return 1   # any numeric max -> metrics present
	done
	return 0
}

# metrics_note_text: METRICS_NOTE plus a clause linking it to the preflight verdict
# (003's recorded `# METRICS_API=`), so the two signals — start-of-sweep gate vs
# end-of-sweep observed N/A — tell one coherent story instead of an apparently
# contradictory "preflight: available" + "NOTE: N/A". Only called when
# metrics_unavailable is already true. Output stays JSON-safe (no quotes/backslashes).
metrics_note_text() {
	local n="$METRICS_NOTE" recorded
	recorded="$(preamble_get METRICS_API)"
	case "$recorded" in
		available)      n="$n (preflight recorded the metrics API available at sweep start, so it degraded mid-sweep.)" ;;
		unavailable:*)  n="$n (preflight already flagged this at sweep start: ${recorded}.)" ;;
	esac
	printf '%s' "$n"
}

# O9 coverage floor: achieved pods (pods_scheduled max) vs allocatable; the
# achieved fraction is informational unless SCALE_COVERAGE_ENFORCE=1. We use
# pods_scheduled/pods_allocatable as the achieved-vs-capacity proxy (the per-row
# legibility columns), independent of the Phase-2 sizing math in 001.
# NOTE: max(pods_scheduled) and max(pods_allocatable) are taken INDEPENDENTLY across
# rows, so on a multi-context sweep they may come from different contexts — the
# fraction is a fleet-level proxy, not a single-cluster paired ratio.
# Count distinct contexts (col 2) among the VALID rows (istiod_restarted==0, NF>=40)
# that feed the achieved-scale maxes. >1 means pods_scheduled/pods_allocatable can be
# maxed from different clusters, so the coverage fraction is a fleet-level proxy rather
# than a single-cluster paired ratio — surfaced via a `(fleet)` suffix.
count_valid_contexts() {
	cat "${TSV_FILES[@]}" | awk -F'\t' '
		!/^#/ && !/^timestamp/ && NF>=40 && $31 == "0" { c[$2] = 1 }
		END { n = 0; for (k in c) n++; print n }'
}
COVERAGE_STATUS="N/A"      # OK | UNDER | INFO (fixed-mode, non-enforcing) | N/A
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
	# Fleet suffix: independent maxes across >1 context are not a single-cluster ratio.
	local n_ctx fleet=""
	n_ctx="$(count_valid_contexts)"
	(( n_ctx > 1 )) && fleet=" (fleet: maxes taken independently across ${n_ctx} contexts)"
	frac="$(awk -v s="$sched" -v a="$alloc" 'BEGIN{ if (a+0<=0){print "0"} else printf "%.3f", s/a }')"
	# #46: the pods/allocatable floor is a yardstick for SCALE_SIZING_MODE=auto, where
	# the harness deliberately fills the cluster toward a target fraction. A fixed-mode
	# sweep pins service/replica/namespace counts and sweeps only mesh_size (it is NOT
	# trying to pack nodes), so applying the floor there reads as a spurious UNDER. Read
	# the mode from the preamble for reproducibility (cf #45), falling back to the env.
	local sizing
	sizing="$(preamble_get SCALE_SIZING_MODE)"
	[[ "$sizing" == unknown ]] && sizing="${SCALE_SIZING_MODE:-fixed}"
	if [[ "$sizing" != auto ]]; then
		COVERAGE_STATUS="INFO"
		COVERAGE_LINE="SCALE_COVERAGE: ${sched}/${alloc} pods = ${frac} (informational; fixed-workload sweep, floor applies only to SCALE_SIZING_MODE=auto)${fleet}"
		return 0
	fi
	local under
	under="$(awk -v f="$frac" -v m="$min" 'BEGIN{ print (f+0 < m+0) ? 1 : 0 }')"
	if (( under )); then
		COVERAGE_STATUS="UNDER"
		COVERAGE_LINE="SCALE_COVERAGE: UNDER (achieved ${sched}/${alloc} pods = ${frac} < min ${min}; enforce=${enforce})${fleet}"
	else
		COVERAGE_STATUS="OK"
		COVERAGE_LINE="SCALE_COVERAGE: OK (achieved ${sched}/${alloc} pods = ${frac} >= min ${min})${fleet}"
	fi
	return 0
}
compute_coverage

# Customer SLA / pass-fail verdict (headline). Computed over the SAME validity-gated
# achieved-scale maxes the rest of the report uses (istiod_*_pct_of_limit, node_*_pct
# are already n_valid-gated in collect_achieved_scale — PL35) plus the restart/sample
# counts from the data rows. Never reads configured axis values. The verdict is a
# sweep-level scalar, surfaced once in every format alongside COVERAGE_LINE.
SLA_VERDICT="UNKNOWN"
SLA_HEADLINE=""
# P1-4: istiod memory headroom from RSS (process_resident_memory_bytes peak,
# always available even when kubectl top is N/A) as % of the PER-REPLICA mem
# limit. In multi-primary each istiod caches the WHOLE mesh (~30k endpoints at
# 10k svc) — an RSS approaching the limit is the OOM-mid-sweep risk the brief
# wants surfaced alongside CPU. unknown if the RSS peak or the limit is missing.
as_istiod_rss_mem_pct() {
	local rss lim
	rss="$(as_get istiod_rss_mem_mi)"
	lim="$(preamble_get ISTIOD_MEM_LIMIT_MI)"
	# Per-replica RSS vs per-replica limit (clean ratio — env_pct_of_limit with
	# replicas=1 so it does NOT scale the denominator by replica count).
	env_pct_of_limit "$rss" "$lim" 1
}
ISTIOD_RSS_MEM_PCT="$(as_istiod_rss_mem_pct)"
compute_sla_verdict() {
	local restarts n_total n_valid
	# Sum restart rows (istiod_restarted==1) and n_total/n_valid across all valid rows.
	read -r restarts n_total n_valid < <(cat "${TSV_FILES[@]}" | awk -F'\t' '
		!/^#/ && !/^timestamp/ && NF>=40 {
			n_total++
			if ($31 == "1") restarts++
			else if ($31 == "0") n_valid++
		}
		END { printf "%d %d %d\n", restarts+0, n_total+0, n_valid+0 }')
	# P1-4: feed the istiod memory signal to the verdict as the MAX of the
	# kubectl-top mem pct ($36-derived) and the RSS-derived pct — whichever memory
	# headroom signal is present and higher drives the OOM verdict, so a metrics-API
	# gap (top N/A) no longer hides an istiod that is near its mem limit by RSS.
	local imem_top imem_eff
	imem_top="$(as_get istiod_mem_pct)"
	imem_eff="$(awk -v a="$imem_top" -v b="$ISTIOD_RSS_MEM_PCT" '
		function isnum(x){ return x ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
		BEGIN {
			ha=isnum(a); hb=isnum(b)
			if (ha && hb) { print (a+0>b+0)?a:b }
			else if (ha) { print a }
			else if (hb) { print b }
			else { print "unknown" }
		}')"
	local raw
	raw="$(env_sla_verdict \
		"$(as_get istiod_cpu_pct)" "$imem_eff" \
		"$(as_get node_cpu_pct)"   "$(as_get node_mem_pct)" \
		"$restarts" "$n_total" "$n_valid")"
	SLA_VERDICT="${raw%%|*}"
	SLA_HEADLINE="${raw#*|}"
}
compute_sla_verdict

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
# Aggregated output (tab-separated, 34 columns). This width is INTENTIONALLY decoupled
# from the 40-column input schema above: the 6 O9 capacity cols (35-40) are point-in-time
# reads surfaced in the achieved-scale block, not aggregated, so the aggregate stays 34.
# (Do not "sync" this to 40 — it is not the input width.)
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
		# Config-dump bytes are proxy-side (read from each proxy config dump,
		# independent of istiod restart state) — always ingested.
		if ($24 ~ /^[0-9.]+$/) { cfg_avg_n[key]++; cfg_avg_sum[key] += $24+0 }
		if ($26 ~ /^[0-9.]+$/) {
			if (!(key in cfg_max_val) || $26+0 > cfg_max_val[key]+0) cfg_max_val[key] = $26+0
		}
		if ($31 == "1") restarts[key] += 1
		else if ($31 == "unknown") unknowns[key] += 1
		n_total[key]++
		# istiod-sourced metrics are only valid when istiod did NOT restart during the
		# window — gauges (mem, proxies, heap) just as much as counters/histograms
		# (conv, queue, cpu_delta). A restarted/unknown row carries a post-restart
		# transient gauge (a mid-reconnect connected_proxies, fresh-low memory) exactly
		# as it carries a reset counter, so gating only the counters leaks e.g. a
		# mid-reconnect proxies value into proxies_min/max/avg. Gate ALL of them on
		# istiod_restarted==0 so every numeric aggregate mirrors n_valid (PL13/PL15/PL35).
		if ($31 == "0") {
			ingest("mem",       $8,  key)
			ingest("prx",       $22, key)
			ingest("heap_alloc", $33, key)
			ingest("heap_inuse", $34, key)
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
			# P1-6: SINGLE-BUCKET-PINNED detection. Now that the histogram p99
			# INTERPOLATES within the matched bucket (P0/FINDING#5), the old
			# max==100 floor test is stale: an interpolated value lands at e.g. 73ms,
			# not exactly 100. The honest signal is that the whole delta mass sits in
			# the FIRST (coarsest, 0-100ms) bucket, so the reported quantile is a
			# uniform-WITHIN-bucket assumption (Prometheus histogram_quantile
			# semantics), NOT a value resolved against a higher bucket boundary. At the
			# report level the available proxy is: the n_valid-gated p99 max resolves at
			# or below the first bucket upper bound (100ms) and is greater than 0, i.e.
			# nothing in this cell ever climbed out of bucket 0. Flag it so the rendered
			# p99 reads as unresolved-below-100ms, mirroring the restart footnote.
			conv_fp = (nv[("conv"), k]+0 > 0 && max[("conv"), k]+0 > 0 && max[("conv"), k]+0 <= 100) ? 1 : 0
			queue_fp = (nv[("queue"), k]+0 > 0 && max[("queue"), k]+0 > 0 && max[("queue"), k]+0 <= 100) ? 1 : 0
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
	echo "# RUN_ID=${RUN_ID_TAG}  ISTIO_VERSION=${ISTIO_VERSION_TAG}  HARNESS_SHA=${HARNESS_SHA_TAG}  files_consumed=${FILES_CONSUMED}  skipped_legacy=${FILES_SKIPPED}"
	echo ""
	# O9 achieved-scale block (clearly delimited; tolerates unknown). Pulled from
	# the per-row capacity columns (max across rows) + the preamble.
	echo "--- Achieved scale vs capacity (O9) ---"
	echo "  node allocatable (cpu_m/mem_mi): $(preamble_get NODE_ALLOC_CPU_M) / $(preamble_get NODE_ALLOC_MEM_MI)"
	echo "  istiod limit (cpu_m/mem_mi):  $(preamble_get ISTIOD_CPU_LIMIT_M) / $(preamble_get ISTIOD_MEM_LIMIT_MI)  [per replica]"
	echo "  istiod request (cpu_m/mem_mi): $(preamble_get ISTIOD_REQ_CPU_M) / $(preamble_get ISTIOD_REQ_MEM_MI)  [per replica]"
	echo "  istiod replicas:             $(preamble_get ISTIOD_REPLICAS)"
	echo "  network topology:            $(preamble_get NETWORK_TOPOLOGY)"
	echo "  metrics API (preflight):     $(preamble_get METRICS_API)"
	echo "  tuning baseline (live mesh): $(preamble_get TUNING_BASELINE)"
	echo "  sidecar egress hosts (live): $(preamble_get SIDECAR_EGRESS_HOSTS)"
	echo "  connected_proxies (max):     $(as_get proxies)"
	echo "  services_total [configured] (max): $(as_get svc)"
	echo "  istiod_cpu_pct_of_limit (max): $(as_pct istiod_cpu_pct)"
	echo "  istiod_mem_pct_of_limit (max): $(as_pct istiod_mem_pct)"
	# P1-4: RSS-derived istiod mem headroom (always available; OOM risk signal).
	echo "  istiod_rss_pct_of_limit (max): $(pct_or_bare "$ISTIOD_RSS_MEM_PCT")  [process_resident_memory_bytes peak / per-replica mem limit; OOM headroom]"
	echo "  node_cpu_pct (max):          $(as_pct node_cpu_pct)"
	echo "  node_mem_pct (max):          $(as_pct node_mem_pct)"
	echo "  pods_scheduled / allocatable: $(as_get pods_sched) / $(as_get pods_alloc)"
	echo "  ${COVERAGE_LINE}"
	metrics_unavailable && echo "  NOTE: $(metrics_note_text)"
	echo ""
	echo "Customer SLA verdict: ${SLA_VERDICT} — ${SLA_HEADLINE}"
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
		conv_pin = ($27+0 == 1) ? "  [SINGLE-BUCKET-PINNED: all delta mass in the 0-100ms bucket; value is a uniform-within-bucket assumption, unresolved below 100ms]" : ""
		queue_pin = ($28+0 == 1) ? "  [SINGLE-BUCKET-PINNED: all delta mass in the 0-100ms bucket; value is a uniform-within-bucket assumption, unresolved below 100ms]" : ""
		printf "--- mesh_size=%s service_count=%s replicas=%s namespace_count=%s sidecar_scoping=%s (n_total=%s n_valid=%s) ---\n", $1, $2, $3, $4, $5, $6, $7
		printf "  istiod CPU avg (m):   min=%s max=%s avg=%s   [process_cpu_seconds_total delta over window]\n", $22, $23, $24
		printf "  istiod Memory (Mi):   min=%s max=%s avg=%s   [process_resident_memory_bytes peak]\n", $8, $9, $10
		printf "  Go heap alloc (Mi):   min=%s max=%s avg=%s   [go_memstats_alloc_bytes]\n", $29, $30, $31
		printf "  Go heap inuse (Mi):   min=%s max=%s avg=%s   [go_memstats_heap_inuse_bytes]\n", $32, $33, $34
		printf "  Convergence p99 (ms): %s%s\n", bucket_range($12), conv_pin
		printf "  Queue p99 (ms):       %s%s\n", bucket_range($15), queue_pin
		printf "  Connected proxies:    min=%s max=%s avg=%s\n",     $17, $18, $19
		if ($25+0 > 0) printf "  Config dump avg (MB): %.1f   max: %.1f\n", $25/1048576, $26/1048576
		else if ($6 > 0) printf "  Config dump avg (MB): N/A\n"
		if ($20+0 > 0) printf "  ! istiod restarts:    %s row(s) had restarts during the scrape window\n", $20
		if ($21+0 > 0) printf "  ? undetectable restart: %s row(s) had unknown restart state (missing process_start_time_seconds)\n", $21
		printf "\n"
	}'
}

report_csv() {
	echo "# RUN_ID=${RUN_ID_TAG},ISTIO_VERSION=${ISTIO_VERSION_TAG},HARNESS_SHA=${HARNESS_SHA_TAG},files_consumed=${FILES_CONSUMED},skipped_legacy=${FILES_SKIPPED}"
	echo "# sweep: mesh_sizes=${SWEEP_MESH} service_counts=${SWEEP_SVC} replica_counts=${SWEEP_REP} namespace_counts=${SWEEP_NS} sidecar_scopings=${SWEEP_SCOPE}"
	# O9 achieved-scale provenance parity with text/markdown. Comment lines only, so the
	# CSV row schema (the aggregate columns below) is byte-identical for row consumers.
	echo "# capacity: node_alloc_cpu_m=$(preamble_get NODE_ALLOC_CPU_M) node_alloc_mem_mi=$(preamble_get NODE_ALLOC_MEM_MI) istiod_cpu_limit_m=$(preamble_get ISTIOD_CPU_LIMIT_M) istiod_mem_limit_mi=$(preamble_get ISTIOD_MEM_LIMIT_MI) scale_target_fraction=$(preamble_get SCALE_TARGET_FRACTION) scale_sizing_mode=$(preamble_get SCALE_SIZING_MODE) metrics_api=$(preamble_get METRICS_API) (istiod limits per replica)"
	echo "# infra: istiod_req_cpu_m=$(preamble_get ISTIOD_REQ_CPU_M) istiod_req_mem_mi=$(preamble_get ISTIOD_REQ_MEM_MI) istiod_lim_cpu_m=$(preamble_get ISTIOD_LIM_CPU_M) istiod_lim_mem_mi=$(preamble_get ISTIOD_LIM_MEM_MI) istiod_replicas=$(preamble_get ISTIOD_REPLICAS) network_topology=$(preamble_get NETWORK_TOPOLOGY)"
	echo "# achieved: connected_proxies_max=$(as_get proxies) services_configured_max=$(as_get svc) istiod_cpu_pct_of_limit_max=$(as_pct istiod_cpu_pct) istiod_mem_pct_of_limit_max=$(as_pct istiod_mem_pct) istiod_rss_pct_of_limit_max=$(pct_or_bare "$ISTIOD_RSS_MEM_PCT") node_cpu_pct_max=$(as_pct node_cpu_pct) node_mem_pct_max=$(as_pct node_mem_pct) pods_scheduled_max=$(as_get pods_sched) pods_allocatable_max=$(as_get pods_alloc)"
	echo "# tuning_baseline: $(preamble_get TUNING_BASELINE) | sidecar_egress_hosts: $(preamble_get SIDECAR_EGRESS_HOSTS)"
	echo "# ${COVERAGE_LINE}"
	echo "# sla_verdict: ${SLA_VERDICT} — ${SLA_HEADLINE}"
	metrics_unavailable && echo "# metrics: $(metrics_note_text)"
	aggregate | awk -F'\t' 'BEGIN{OFS=","} { $1=$1; print }'
}

# Metric glossary appended to the END of the markdown summary (#17). Definitions are
# pulled from tests/controlplane/README.md ("What Gets Measured" + the 40-column schema
# notes); units/source/caveats mirror the README, not invented here.
glossary_section() {
	cat <<'GLOSSARY'

## Glossary

Definitions for every metric column in the results tables above. Sourced from
`tests/controlplane/README.md`. All histogram/counter metrics are **deltas over a
wall-clock scrape window**; istiod-sourced columns are gated on `istiod_restarted==0`
so a restart-poisoned row is excluded from every numeric aggregate (`n_valid` mirrors this).

| Column | Units | Source | Definition / caveats |
|--------|-------|--------|----------------------|
| `mesh_size` | clusters | sweep axis | Number of clusters participating in the mesh. |
| `svc` (service_count) | services | sweep axis | Total dummy services per cluster. |
| `reps` (replicas) | pods/service | sweep axis | Pods per service (drives endpoint/EDS count). |
| `ns` (namespace_count) | namespaces | sweep axis | Namespaces holding the services. |
| `scoping` (sidecar_scoping) | enum | sweep axis | `Sidecar` CR mode: `none` / `namespace` / `explicit`. |
| `n_total` | rows | internal | All rows for the cell, including restart-poisoned/`unknown` and degraded (`SETUP_FAILED`/`PROBE_FAILED`/`ZERO_PODS`) rows. |
| `n_valid` | rows | internal | Rows with `istiod_restarted==0` used in numeric aggregation; `n_valid < n_total` means some rows were dropped as poisoned. |
| `cpu_avg (m)` | millicores (per replica) | `process_cpu_seconds_total` delta ÷ window × 1000 | istiod CPU over the scrape window; `overflow` if it exceeds the histogram top bucket; `N/A` on restart/missing baseline. |
| `mem_avg (Mi)` | MiB (per replica) | `process_resident_memory_bytes` (istiod `/metrics`) | Peak RSS of (baseline, 5 s polled samples, final scrape) over the window. |
| `heap_alloc (Mi)` | MiB | `go_memstats_alloc_bytes` | Go heap allocated — point-in-time at final scrape, not a peak. |
| `heap_inuse (Mi)` | MiB | `go_memstats_heap_inuse_bytes` | Go heap in use — point-in-time at final scrape; steady-state signal independent of RSS (which stays inflated after GC via `MADV_FREE`). |
| `conv_p99 (ms)` | ms (bucket range) | `pilot_proxy_convergence_time` histogram delta | p99 convergence reported as a **bucket range** (e.g. `100-500`), not an exact value — istiod buckets are 100/500/1000/3000/5000/10000/20000/30000 ms. `†` = SINGLE-BUCKET-PINNED (all delta mass in the 0-100 ms bucket; a uniform-within-bucket assumption, unresolved below 100 ms). |
| `queue_p99 (ms)` | ms (bucket range) | `pilot_proxy_queue_time` histogram delta | p99 time pushes waited in istiod's queue; same bucket-range / `†` semantics as `conv_p99`. |
| `proxies` (connected_proxies) | proxies | `pilot_xds` gauge (final scrape) | Connected proxy count; gated on `istiod_restarted==0` (a mid-reconnect transient is excluded). |
| `cfg_dump_avg (MB)` | MB | `pilot-agent request /config_dump?include_eds` → `wc -c` | Real per-proxy config-dump size (EDS included by design — the cost `Sidecar` scoping reduces); proxy-side, so ingested regardless of istiod restart state. |
| `restarts` | rows | `istiod_restarted==1` | Rows where `process_start_time_seconds` moved forward between baseline and final scrape; counters/histograms for those samples may under-report. |
| `unk_restarts` | rows | `istiod_restarted==unknown` | Rows where restart state was undetectable (a pinned pod disappeared / missing `process_start_time_seconds`). |

The "Sidecar scoping effect" table reuses `cfg_dump_avg` (per-proxy `/config_dump` MB)
and renders the reduction percentage of `namespace`/`explicit` relative to `none`
(`none->ns`, `none->explicit`); `N/A` where a scoping mode was not swept for that base combo.
The "Achieved scale vs capacity (O9)" block reports point-in-time capacity reads (node
allocatable, istiod limits/requests per replica, `*_pct_of_limit`/`node_*_pct` utilization
from `kubectl top`, `istiod_rss_pct_of_limit` from peak RSS, pods scheduled/allocatable) —
maxes over `n_valid`-gated rows, not windowed aggregates.
GLOSSARY
}

report_markdown() {
	local aggregated
	aggregated=$(aggregate)
	local total_restarts total_unknowns
	total_restarts=$(awk -F'\t' 'NR>1 { s += $20+0 } END { printf "%d", s+0 }' <<<"$aggregated")
	total_unknowns=$(awk -F'\t' 'NR>1 { s += $21+0 } END { printf "%d", s+0 }' <<<"$aggregated")

	echo "---"
	echo "run_id: ${RUN_ID_TAG}"
	echo "istio_version: ${ISTIO_VERSION_TAG}"
	echo "harness_sha: ${HARNESS_SHA_TAG}"
	echo "sidecar_scoping: ${SIDECAR_SCOPING_M:-N/A}"
	echo "config_dump_samples: ${CONFIG_DUMP_SAMPLES_M:-N/A}"
	echo "kube_versions: ${KUBE_VERSIONS_M:-N/A}"
	echo "scale_sizing_mode: $(preamble_get SCALE_SIZING_MODE)"
	echo "metrics_api: $(preamble_get METRICS_API)"
	echo "istiod_req_cpu_m: $(preamble_get ISTIOD_REQ_CPU_M)"
	echo "istiod_req_mem_mi: $(preamble_get ISTIOD_REQ_MEM_MI)"
	echo "istiod_lim_cpu_m: $(preamble_get ISTIOD_LIM_CPU_M)"
	echo "istiod_lim_mem_mi: $(preamble_get ISTIOD_LIM_MEM_MI)"
	echo "istiod_replicas: $(preamble_get ISTIOD_REPLICAS)"
	echo "network_topology: $(preamble_get NETWORK_TOPOLOGY)"
	echo "tuning_baseline: \"$(preamble_get TUNING_BASELINE)\""
	echo "sidecar_egress_hosts: \"$(preamble_get SIDECAR_EGRESS_HOSTS)\""
	echo "sla_verdict: ${SLA_VERDICT}"
	# F8: also carry the reason string (parity with the json `sla` object) so a
	# frontmatter scraper sees the WHY, not just the enum. Double-quoted YAML scalar
	# (the headline has no embedded double-quote/backslash — env_sla_verdict guarantees it).
	echo "sla_headline: \"${SLA_HEADLINE}\""
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
	echo "| node allocatable (cpu_m/mem_mi) | $(preamble_get NODE_ALLOC_CPU_M) / $(preamble_get NODE_ALLOC_MEM_MI) |"
	echo "| istiod limit (cpu_m/mem_mi, per replica) | $(preamble_get ISTIOD_CPU_LIMIT_M) / $(preamble_get ISTIOD_MEM_LIMIT_MI) |"
	echo "| istiod request (cpu_m/mem_mi, per replica) | $(preamble_get ISTIOD_REQ_CPU_M) / $(preamble_get ISTIOD_REQ_MEM_MI) |"
	echo "| istiod replicas | $(preamble_get ISTIOD_REPLICAS) |"
	echo "| network topology | $(preamble_get NETWORK_TOPOLOGY) |"
	echo "| connected_proxies (max) | $(as_get proxies) |"
	echo "| services_total [configured] (max) | $(as_get svc) |"
	echo "| istiod_cpu_pct_of_limit (max) | $(as_pct istiod_cpu_pct) |"
	echo "| istiod_mem_pct_of_limit (max) | $(as_pct istiod_mem_pct) |"
	echo "| istiod_rss_pct_of_limit (max) | $(pct_or_bare "$ISTIOD_RSS_MEM_PCT") |"
	echo "| node_cpu_pct (max) | $(as_pct node_cpu_pct) |"
	echo "| node_mem_pct (max) | $(as_pct node_mem_pct) |"
	echo "| pods_scheduled / allocatable | $(as_get pods_sched) / $(as_get pods_alloc) |"
	echo ""
	echo "> ${COVERAGE_LINE}"
	metrics_unavailable && { echo ""; echo "> NOTE: $(metrics_note_text)"; }
	echo ""
	echo "**Customer SLA verdict: ${SLA_VERDICT}** — ${SLA_HEADLINE}"
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
		# P1-6: dagger-mark a SINGLE-BUCKET-PINNED conv/queue p99 (cols 27/28).
		cp = bucket_range($12); if ($27+0 == 1) { cp = cp " †"; any_pin = 1 }
		qp = bucket_range($15); if ($28+0 == 1) { qp = qp " †"; any_pin = 1 }
		printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6, $7, $24, $10, ha, hi, cp, qp, $19, cfg_mb, $20, $21
	}
	END { if (any_pin) print "\n> † SINGLE-BUCKET-PINNED: all delta mass for that quantile sits in the coarsest (0-100ms) `pilot_proxy_convergence_time` bucket, so the reported value is a uniform-within-bucket assumption (Prometheus `histogram_quantile` semantics), NOT resolved below 100ms. Real sub-bucket signal only appears once convergence climbs into a higher bucket (e.g. at 10k-service scale)." }' <<<"$aggregated"
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

	# #17: metric glossary at the very end of the markdown summary.
	glossary_section
}

report_json() {
	aggregate | awk -F'\t' -v ri="$RUN_ID_TAG" -v iv="$ISTIO_VERSION_TAG" -v hs="$HARNESS_SHA_TAG" -v fc="$FILES_CONSUMED" -v fs="$FILES_SKIPPED" \
		-v sw_mesh="$SWEEP_MESH" -v sw_svc="$SWEEP_SVC" -v sw_rep="$SWEEP_REP" -v sw_ns="$SWEEP_NS" -v sw_scope="$SWEEP_SCOPE" \
		-v cap_ncpu="$(preamble_get NODE_ALLOC_CPU_M)" -v cap_nmem="$(preamble_get NODE_ALLOC_MEM_MI)" \
		-v cap_icpu="$(preamble_get ISTIOD_CPU_LIMIT_M)" -v cap_imem="$(preamble_get ISTIOD_MEM_LIMIT_MI)" \
		-v cap_tf="$(preamble_get SCALE_TARGET_FRACTION)" -v cap_mode="$(preamble_get SCALE_SIZING_MODE)" -v cap_metrics="$(preamble_get METRICS_API)" \
		-v inf_rcpu="$(preamble_get ISTIOD_REQ_CPU_M)" -v inf_rmem="$(preamble_get ISTIOD_REQ_MEM_MI)" \
		-v inf_lcpu="$(preamble_get ISTIOD_LIM_CPU_M)" -v inf_lmem="$(preamble_get ISTIOD_LIM_MEM_MI)" \
		-v inf_rep="$(preamble_get ISTIOD_REPLICAS)" -v inf_net="$(preamble_get NETWORK_TOPOLOGY)" \
		-v sla_v="$SLA_VERDICT" -v sla_h="$SLA_HEADLINE" \
		-v tb_levers="$(preamble_get TUNING_BASELINE)" -v tb_egress="$(preamble_get SIDECAR_EGRESS_HOSTS)" \
		-v ach_prx="$(as_get proxies)" -v ach_svc="$(as_get svc)" \
		-v ach_icpu="$(as_get istiod_cpu_pct)" -v ach_imem="$(as_get istiod_mem_pct)" \
		-v ach_irss="$ISTIOD_RSS_MEM_PCT" \
		-v ach_ncpu="$(as_get node_cpu_pct)" -v ach_nmem="$(as_get node_mem_pct)" \
		-v ach_psched="$(as_get pods_sched)" -v ach_palloc="$(as_get pods_alloc)" \
		-v cov="$COVERAGE_LINE" -v metrics_note="$(metrics_unavailable && metrics_note_text)" '
	function cell(v) {
		if (v == "overflow") return "null"
		return v + 0
	}
	BEGIN { printf "{\n  \"metadata\": {\"run_id\":\"%s\",\"istio_version\":\"%s\",\"harness_sha\":\"%s\",\"files_consumed\":%d,\"skipped_legacy\":%d,\"sweep\":{\"mesh_sizes\":\"%s\",\"service_counts\":\"%s\",\"replica_counts\":\"%s\",\"namespace_counts\":\"%s\",\"sidecar_scopings\":\"%s\"},\"capacity\":{\"node_alloc_cpu_m\":\"%s\",\"node_alloc_mem_mi\":\"%s\",\"istiod_cpu_limit_m\":\"%s\",\"istiod_mem_limit_mi\":\"%s\",\"scale_target_fraction\":\"%s\",\"scale_sizing_mode\":\"%s\",\"metrics_api\":\"%s\",\"istiod_limits_per_replica\":true},\"infra\":{\"istiod_req_cpu_m\":\"%s\",\"istiod_req_mem_mi\":\"%s\",\"istiod_lim_cpu_m\":\"%s\",\"istiod_lim_mem_mi\":\"%s\",\"istiod_replicas\":\"%s\",\"network_topology\":\"%s\"},\"tuning_baseline\":{\"levers\":\"%s\",\"sidecar_egress_hosts\":\"%s\"},\"achieved_scale\":{\"connected_proxies_max\":\"%s\",\"services_configured_max\":\"%s\",\"istiod_cpu_pct_of_limit_max\":\"%s\",\"istiod_mem_pct_of_limit_max\":\"%s\",\"istiod_rss_pct_of_limit_max\":\"%s\",\"node_cpu_pct_max\":\"%s\",\"node_mem_pct_max\":\"%s\",\"pods_scheduled_max\":\"%s\",\"pods_allocatable_max\":\"%s\"},\"coverage\":\"%s\",\"sla\":{\"verdict\":\"%s\",\"headline\":\"%s\"},\"metrics_note\":\"%s\"},\n  \"results\": [", ri, iv, hs, fc, fs, sw_mesh, sw_svc, sw_rep, sw_ns, sw_scope, cap_ncpu, cap_nmem, cap_icpu, cap_imem, cap_tf, cap_mode, cap_metrics, inf_rcpu, inf_rmem, inf_lcpu, inf_lmem, inf_rep, inf_net, tb_levers, tb_egress, ach_prx, ach_svc, ach_icpu, ach_imem, ach_irss, ach_ncpu, ach_nmem, ach_psched, ach_palloc, cov, sla_v, sla_h, metrics_note }
	NR == 1 { next }
	{
		if (printed++) printf ",\n    "; else printf "\n    "
		printf "{\"mesh_size\":%s,\"service_count\":%s,\"replicas\":%s,\"namespace_count\":%s,\"sidecar_scoping\":\"%s\",\"n_total\":%s,\"n_valid\":%s,",
			$1, $2, $3, $4, $5, $6, $7
		printf "\"cpu_m_delta\":{\"min\":%s,\"max\":%s,\"avg\":%s},", cell($22), cell($23), cell($24)
		printf "\"mem_mi\":{\"min\":%s,\"max\":%s,\"avg\":%s},",      cell($8), cell($9), cell($10)
		printf "\"convergence_p99_ms\":{\"min\":%s,\"max\":%s,\"avg\":%s},", cell($11), cell($12), cell($13)
		printf "\"convergence_p99_single_bucket_pinned\":%s,", ($27+0==1) ? "true" : "false"
		printf "\"queue_p99_ms\":{\"min\":%s,\"max\":%s,\"avg\":%s},",      cell($14), cell($15), cell($16)
		printf "\"queue_p99_single_bucket_pinned\":%s,", ($28+0==1) ? "true" : "false"
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

report_charts() {
	local aggregated
	aggregated=$(aggregate)

	echo "---"
	echo "istio_version: ${ISTIO_VERSION_TAG}"
	echo "harness_sha: ${HARNESS_SHA_TAG}"
	echo "files_consumed: ${FILES_CONSUMED}"
	echo "generated: $(date -u -Iseconds)"
	echo "---"
	echo ""
	echo "# Control-Plane Resource Scaling — Charts"
	echo ""
	# Chart 1: istiod CPU vs mesh size, one series per sidecar scoping.
	# Chart 2: Per-proxy config dump size (MB) by scoping at largest mesh size.
	awk -F'\t' '
	function is_num(s) { return s ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	NR == 1 { next }
	{
		ms = $1 + 0; scoping = $5; n_valid = $7 + 0
		if (!(ms in ms_seen)) { ms_order[++n_ms] = ms; ms_seen[ms] = 1 }
		if (!(scoping in sc_seen)) { sc_order[++n_sc] = scoping; sc_seen[scoping] = 1 }
		# PL13/PL15 + PL8 gate (mirrors the markdown/json n_valid + overflow handling):
		# a cell with no valid samples (every row restart-poisoned/unknown so n_valid==0,
		# where the aggregate emit3 returned a synthetic zero) or whose charted column
		# carries the overflow sentinel (cpu_delta_avg $24 / cfg_dump_avg $25) is ABSENT,
		# not a real 0 data point. Coercing it (awk $24 + 0) would plot a poisoned/overflow
		# cell as the LOWEST CPU point, the inverse of reality. Count it as dropped and
		# leave has[] unset so it is never charted as 0.
		cells_total++
		if (n_valid <= 0 || $24 == "overflow" || $25 == "overflow" || !is_num($24) || !is_num($25)) {
			cells_dropped++
			next
		}
		cpu_val[ms, scoping] = $24 + 0
		cfg_val[ms, scoping] = $25 + 0
		has[ms, scoping] = 1
	}
	END {
		if (cells_dropped > 0) {
			printf "> %d of %d cells dropped (no valid samples / restart-poisoned / overflow) — not plotted.\n\n", cells_dropped, cells_total
		}
		# Sort mesh sizes numerically.
		for (i = 2; i <= n_ms; i++) {
			tmp = ms_order[i]; j = i - 1
			while (j >= 1 && ms_order[j]+0 > tmp+0) { ms_order[j+1] = ms_order[j]; j-- }
			ms_order[j+1] = tmp
		}
		# Sort scopings lexically.
		for (i = 2; i <= n_sc; i++) {
			tmp = sc_order[i]; j = i - 1
			while (j >= 1 && sc_order[j] > tmp) { sc_order[j+1] = sc_order[j]; j-- }
			sc_order[j+1] = tmp
		}

		if (n_ms < 2) {
			print "> Charts require at least two mesh sizes."
			exit
		}

		# Chart 1: istiod CPU vs mesh size by scoping
		printf "%% Chart 1: istiod CPU (m, per replica) vs mesh size, by sidecar scoping\n"
		printf "%% Series order:"
		for (s = 1; s <= n_sc; s++) printf " %s", sc_order[s]
		printf "\n\n```mermaid\n"
		printf "xychart-beta\n"
		printf "    title \"istiod CPU vs Mesh Size by Sidecar Scoping\"\n"
		printf "    x-axis \"Mesh Size\" ["
		for (i = 1; i <= n_ms; i++) {
			if (i > 1) printf ", "
			printf "%s", ms_order[i]
		}
		printf "]\n"
		printf "    y-axis \"CPU (m, per replica)\"\n"
		for (s = 1; s <= n_sc; s++) {
			printf "    line ["; sep = ""
			for (i = 1; i <= n_ms; i++) {
				ms = ms_order[i]; sc = sc_order[s]
				v = has[ms, sc] ? cpu_val[ms, sc] : 0
				printf "%s%.0f", sep, v; sep = ", "
			}
			printf "]\n"
		}
		printf "```\n\n"
		printf "> Series order:"
		for (s = 1; s <= n_sc; s++) printf " **%s**", sc_order[s]
		printf ".\n\n"

		# Chart 2: Config dump size (MB) by scoping at largest mesh size
		max_ms = ms_order[n_ms]
		has_any_cfg = 0
		for (s = 1; s <= n_sc; s++) {
			if (has[max_ms, sc_order[s]] && cfg_val[max_ms, sc_order[s]] > 0) has_any_cfg = 1
		}
		if (!has_any_cfg) {
			printf "> No config dump data available for bar chart.\n"
			exit
		}
		printf "%% Chart 2: Per-proxy config dump size (MB) by scoping at mesh size %s\n", max_ms
		printf "\n```mermaid\n"
		printf "xychart-beta\n"
		printf "    title \"Config Dump Size by Scoping (mesh size %s)\"\n", max_ms
		printf "    x-axis \"Sidecar Scoping\" ["
		for (s = 1; s <= n_sc; s++) {
			if (s > 1) printf ", "
			printf "\"%s\"", sc_order[s]
		}
		printf "]\n"
		printf "    y-axis \"Size (MB)\"\n"
		printf "    bar ["; sep = ""
		for (s = 1; s <= n_sc; s++) {
			sc = sc_order[s]
			v = (has[max_ms, sc] && cfg_val[max_ms, sc] > 0) ? cfg_val[max_ms, sc] / 1048576 : 0
			printf "%s%.1f", sep, v; sep = ", "
		}
		printf "]\n"
		printf "```\n\n"
		printf "> Config dump avg (MB) at the largest mesh size swept (%s).\n", max_ms
	}' <<<"$aggregated"
}

case "$FORMAT" in
text)     report_text ;;
csv)      report_csv ;;
markdown) report_markdown ;;
json)     report_json ;;
charts)   report_charts ;;
esac

# O9 coverage-floor enforcement (DEFAULT-OFF). Only fails the report when the
# operator opted in via SCALE_COVERAGE_ENFORCE=1 AND achieved scale is under the
# floor. With ENFORCE=0 (default) this is informational only — behaviour unchanged.
if [[ "${SCALE_COVERAGE_ENFORCE:-0}" == "1" && "$COVERAGE_STATUS" == "UNDER" ]]; then
	echo "${COVERAGE_LINE}" >&2
	echo "  To fix: add cluster nodes, raise the workload size (SCALE_SIZING_MODE=auto, or a larger --service-count/--replicas), lower SCALE_COVERAGE_MIN_FRACTION, or unset SCALE_COVERAGE_ENFORCE to treat coverage as informational." >&2
	die "scale coverage under floor (SCALE_COVERAGE_ENFORCE=1)"
fi

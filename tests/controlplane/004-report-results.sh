#!/usr/bin/env bash
# Generate summary statistics from control-plane resource metrics TSV files.
#
# Groups by the six sweep axes — mesh_size, service_count, replicas,
# namespace_count, sidecar_scoping, traffic_config — so the operator can compare any
# single dimension while the others are held constant.
#
# Usage:
#   ./tests/controlplane/004-report-results.sh [--results-dir DIR] [--format FMT]
#
# Examples:
#   ./tests/controlplane/004-report-results.sh
#   ./tests/controlplane/004-report-results.sh --format csv
#   ./tests/controlplane/004-report-results.sh --format json
#   ./tests/controlplane/004-report-results.sh --format markdown
#   ./tests/controlplane/004-report-results.sh --config tests/controlplane/configs/smoke.env \
#     --results-dir tests/controlplane/results/smoke/sweep-<RUN_ID>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # config_preload, config_repo_path
# --config FILE: export the file's keys before options.env fills in defaults.
config_preload controlplane "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/options.env"  # O9: SCALE_COVERAGE_* knobs (coverage floor)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/envelope.sh"  # env_sla_verdict (customer SLA headline)

RESULTS_DIR="$(config_repo_path "${CONTROLPLANE_RESULTS_DIR}")"
# 1 when --results-dir is passed (gates the multi-run warning below).
RESULTS_DIR_FROM_FLAG=0
FORMAT="text"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE      Run config of KEY=value lines (config/options.env keys; see
                     tests/controlplane/README.md, "Run config"). Precedence: flag >
                     --config > environment > default. Without --results-dir, warns
                     when the results dir holds more than one run.
  --results-dir DIR  Results directory (default: ${CONTROLPLANE_RESULTS_DIR}).
  --format FMT       Output format: text, csv, json, markdown (or md), charts (default: text).
  -h, --help         Show this help.

Output groups by (mesh_size, service_count, replicas, namespace_count,
sidecar_scoping, traffic_config) — every unique sweep point gets its own row of
CPU/memory/convergence/queue/config-dump stats. When a cell was swept with both
traffic configs (none and vsdr), the markdown adds a "Traffic management (VS/DR)
effect" section that pairs them.

Histogram cells whose target quantile falls in the +Inf overflow bucket are
emitted as the string "overflow" in text/csv/markdown and as null in JSON.
A cell with no valid sample is N/A (null in JSON), never 0.

Connected proxies are shown per istiod replica (each pod row) and per cluster
(summed over a cluster's istiod pods at one scrape). The proxy check compares
the per-cluster count with the cluster's Running sidecar pods; LOW/HIGH prints
a WARNING line but never changes the exit code. Reads 40- and 51-column TSVs;
40-column files add nothing to the per-cluster or traffic-management figures and
their rows count as traffic_config none.

Environment:
  CONTROLPLANE_RESULTS_DIR      --results-dir default (relative to the repo root).

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
	--config)
		# Loaded by config_preload above.
		[[ -n "${2:-}" ]] || die "--config requires a value"
		shift 2
		;;
	--results-dir)
		[[ -n "${2:-}" ]] || die "--results-dir requires a value"
		RESULTS_DIR="$2"
		RESULTS_DIR_FROM_FLAG=1
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
md) FORMAT=markdown ;;
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

# Partition by header width: 51 columns (current, CONTROLPLANE_SCHEMA=51) and 40
# columns (before the per-cluster proxy check, cols 41-43, and the traffic-management
# columns, cols 44-51). A 40-column file feeds every aggregate it always fed, counts
# as traffic_config none, and adds nothing to the per-cluster proxy or traffic
# figures, which read cols 41+ by header name. Any other width is legacy and skipped
# (43 and 48 columns were intermediate layouts that never shipped).
TSV_FILES=()
LEGACY_FILES=()
PRE_CHECK_FILES=0
for f in "${ALL_TSV[@]}"; do
	header=$(grep -m1 -v '^#' "$f" 2>/dev/null || true)
	tabs=$(awk -F'\t' '{print NF}' <<<"$header")
	case "$tabs" in
	51) TSV_FILES+=("$f") ;;
	40) TSV_FILES+=("$f"); PRE_CHECK_FILES=$((PRE_CHECK_FILES + 1)) ;;
	*) LEGACY_FILES+=("$f") ;;
	esac
done

if (( ${#LEGACY_FILES[@]} > 0 )); then
	echo "warning: skipping ${#LEGACY_FILES[@]} legacy TSV file(s) with an unsupported schema (expected 40 or 51 columns):" >&2
	for f in "${LEGACY_FILES[@]}"; do
		echo "  $f" >&2
	done
fi

if (( ${#TSV_FILES[@]} == 0 )); then
	die "no TSV files with a supported schema (40 or 51 columns) found in $RESULTS_DIR"
fi
if (( PRE_CHECK_FILES > 0 )); then
	echo "note: ${PRE_CHECK_FILES} TSV file(s) use the 40-column schema (no per-cluster proxy or traffic-management columns); their rows count as traffic_config none and add nothing to the per-cluster proxy figures, the proxy check or the VS/DR figures" >&2
fi

# Shared awk snippets, prepended to the programs that need them.
# AWK_HEADER_IX: column lookup by header name for the appended columns (41+). The
# index is rebuilt at each file's header line, so rows of a file whose header lacks a
# name (a 40-column file) get col(name) == 0 and colv(name) == "" and contribute
# nothing; traffic() reads such rows as none.
# shellcheck disable=SC2016
AWK_HEADER_IX='/^timestamp\t/ { delete ix; for (i = 1; i <= NF; i++) ix[$i] = i; next }
function col(name) { return (name in ix) ? ix[name] : 0 }
function colv(name,    c) { c = col(name); return (c && NF >= c) ? $c : "" }
function traffic(    v) { v = colv("traffic_config"); return (v == "" ? "none" : v) }'
# AWK_COMBO_KEY: the per-combo grouping key (needs AWK_HEADER_IX for traffic()).
# aggregate() and collect_proxy_check must group identically, so a new sweep axis is
# added here once (collect_sweep_axes reads the same traffic()).
# shellcheck disable=SC2016
AWK_COMBO_KEY='function combo_key() { return $3 "|" $4 "|" $5 "|" $6 "|" $7 "|" traffic() }'

# C2: infra-schema concordance guard (mirrors the data-row width gate above). The
# data schema is gated by header width (40 or 51), but the additive cluster-infra
# preamble carries its OWN version marker (CONTROLPLANE_INFRA_SCHEMA). A bump can
# change an infra key's SEMANTICS without changing the data width (v2: ISTIOD_REPLICAS
# covers every context and reads `1-3` when they differ, plus ISTIOD_REPLICAS_BY_CONTEXT;
# v1 read the first context only), so a v1 file and a v2 file would pass the width
# gate and silently mix. Warn (don't die —
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

# PL6: a results dir from --config (or the default) is a base dir that can hold many
# runs, and the report aggregates all of them. Warn only with --config and without
# --results-dir, so a report without --config prints what it always did.
if ((RUN_CONFIG_LOADED)) && ! ((RESULTS_DIR_FROM_FLAG)); then
	run_ids="$(for f in "${TSV_FILES[@]}"; do grep -m1 '^# RUN_ID=' "$f" 2>/dev/null || echo "# RUN_ID=unknown"; done | sed 's/^# RUN_ID=//' | sort -u)"
	n_runs="$(grep -c . <<<"$run_ids")"
	if ((n_runs > 1)); then
		run_list="$(awk 'NR <= 5 { printf "%s%s", (NR > 1 ? "," : ""), $0 } END { if (NR > 5) printf ",..." }' <<<"$run_ids")"
		echo "warning: ${RESULTS_DIR} holds ${n_runs} runs (RUN_IDs: ${run_list}); this report aggregates all of them. Pass --results-dir <dir>/sweep-<RUN_ID> to report one sweep." >&2
	fi
fi
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
	cat "${TSV_FILES[@]}" | awk -F'\t' "${AWK_HEADER_IX}"'
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
		mesh[$3]=1; svc[$4]=1; rep[$5]=1; ns[$6]=1; scope[$7]=1; tcs[traffic()]=1
	}
	END {
		n=collect(mesh,a);  printf "mesh_sizes: %s\n", join(a,n)
		n=collect(svc,a);   printf "service_counts: %s\n", join(a,n)
		n=collect(rep,a);   printf "replica_counts: %s\n", join(a,n)
		n=collect(ns,a);    printf "namespace_counts: %s\n", join(a,n)
		n=collect(scope,a); printf "sidecar_scopings: %s\n", join(a,n)
		n=collect(tcs,a);   printf "traffic_configs: %s\n", join(a,n)
	}'
}
SWEEP_AXES="$(collect_sweep_axes)"
SWEEP_MESH="$(echo "$SWEEP_AXES" | grep '^mesh_sizes:' | cut -d' ' -f2-)"
SWEEP_SVC="$(echo "$SWEEP_AXES" | grep '^service_counts:' | cut -d' ' -f2-)"
SWEEP_REP="$(echo "$SWEEP_AXES" | grep '^replica_counts:' | cut -d' ' -f2-)"
SWEEP_NS="$(echo "$SWEEP_AXES" | grep '^namespace_counts:' | cut -d' ' -f2-)"
SWEEP_SCOPE="$(echo "$SWEEP_AXES" | grep '^sidecar_scopings:' | cut -d' ' -f2-)"
SWEEP_TRAFFIC="$(echo "$SWEEP_AXES" | grep '^traffic_configs:' | cut -d' ' -f2-)"

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

# istiod_replicas_label: ISTIOD_REPLICAS for people ("3 per cluster", "1-3 per cluster
# (varies by cluster)", "3 (first context only)" for an INFRA_SCHEMA 1 file). The
# csv/json/yaml metadata keep the raw value and ISTIOD_REPLICAS_BY_CONTEXT.
istiod_replicas_label() {
	env_replicas_label "$(preamble_get ISTIOD_REPLICAS)" "$(preamble_get ISTIOD_REPLICAS_BY_CONTEXT)"
}

# preamble_scalar KEY [CONSEQUENCE] [MISSING]: a sweep-level `# KEY=value` read from
# EVERY consumed TSV, for keys that 40-column files lack (so the first file may not
# carry them). An input without the key is skipped, or, when MISSING is given, counts
# as the value MISSING. One value -> that value; several -> `mixed:a,b` plus a stderr
# warning ending in CONSEQUENCE (PL26: a sweep-level key must not silently take the
# last value); none -> unknown.
preamble_scalar() {
	local key="$1" consequence="${2:-values are mixed}" missing="${3:-}" f v vals=""
	for f in "${TSV_FILES[@]}"; do
		v="$(grep -m1 "^# ${key}=" "$f" 2>/dev/null || true)"
		if [[ -n "$v" ]]; then
			v="${v#*=}"
		elif [[ -n "$missing" ]]; then
			v="$missing"
		else
			continue
		fi
		case ",${vals}," in *",${v},"*) ;; *) vals="${vals:+${vals},}${v}" ;; esac
	done
	if [[ -z "$vals" ]]; then
		echo "unknown"
	elif [[ "$vals" == *,* ]]; then
		echo "warning: input TSVs disagree on ${key} (${vals}); ${consequence}" >&2
		echo "mixed:${vals}"
	else
		echo "$vals"
	fi
}
PROXY_CHECK_TOL_M="$(preamble_scalar PROXY_CHECK_TOLERANCE_PCT "the proxy check mixes thresholds")"
PROXY_CHECK_MIN_DIFF_M="$(preamble_scalar PROXY_CHECK_MIN_DIFF "the proxy check mixes thresholds")"
# VS/DR knobs (sweep-level scalars, schema-51 files only). Inputs that disagree make
# vsdr cells non-comparable, so they print as mixed:a,b with a warning.
VSDR_EVERY_M="$(preamble_scalar VSDR_EVERY "vsdr cells mix VS/DR densities")"
VSDR_SUBSETS_M="$(preamble_scalar VSDR_SUBSETS "vsdr cells mix DestinationRule subset counts")"

# Which --config produced the inputs (PL2/PL19): `none` without one, `unknown` for
# files written before the key existed. Every input should share it (PL26). A file
# without the key counts as unknown, so mixing it with a config-driven file prints
# mixed:<file>,unknown instead of crediting its rows to that config.
RUN_CONFIG_M="$(preamble_scalar RUN_CONFIG "the report mixes runs made with different --config files" unknown)"
RUN_CONFIG_SHA256_M="$(preamble_scalar RUN_CONFIG_SHA256 "the report mixes runs made with different --config contents" unknown)"

# Shown next to the traffic_configs axis only when vsdr cells exist.
TRAFFIC_AXIS_NOTE=""
[[ ",${SWEEP_TRAFFIC}," == *",vsdr,"* ]] && TRAFFIC_AXIS_NOTE="  (vsdr: every ${VSDR_EVERY_M}, ${VSDR_SUBSETS_M} subsets)"

# Per-cluster connected proxies + proxy check (TSV cols 41-43, read by header name).
# One "cluster scrape" is the group of rows with the same timestamp ($1, one per
# collection window), context ($2) and combo: every istiod pod row of that context in
# that window, which all carry the same cluster columns. A group counts only when
# EVERY row has istiod_restarted==0 (the n_valid gate, PL35); other groups are
# tallied as `excluded`. proxy_check is a warning, never a filter (PL15). Emits
#   proxies_cluster=<max over counted groups|unknown> pc_ok= pc_low= pc_high= pc_na=
#   pc_excluded= pc_flagged=<ctx@ts:STATUS:connected/sidecars,...|none>
# (at most 10 flagged entries, then `+N_more`).
collect_proxy_check() {
	cat "${TSV_FILES[@]}" | awk -F'\t' "${AWK_COMBO_KEY}
${AWK_HEADER_IX}"'
	function isnum(s) { return s ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	!/^#/ && !/^timestamp/ && NF >= 40 {
		cc = col("cluster_connected_proxies"); cs = col("sidecar_pods"); ck = col("proxy_check")
		if (!cc || !cs || !ck || NF < ck) next
		g = $1 SUBSEP $2 SUBSEP combo_key()
		if (!(g in gseen)) {
			gseen[g] = 1; order[++ng] = g
			gts[g] = $1; gctx[g] = $2; gval[g] = $cc; gsc[g] = $cs; gchk[g] = $ck
		}
		if ($31 != "0") gbad[g] = 1
	}
	END {
		ok = 0; low = 0; high = 0; na = 0; excl = 0; nfl = 0; mx = ""; flagged = ""
		for (i = 1; i <= ng; i++) {
			g = order[i]
			if (g in gbad) { excl++; continue }
			if (isnum(gval[g]) && (mx == "" || gval[g] + 0 > mx + 0)) mx = gval[g] + 0
			s = gchk[g]
			if (s == "OK") ok++
			else if (s == "LOW" || s == "HIGH") {
				if (s == "LOW") low++; else high++
				if (++nfl <= 10) flagged = flagged (flagged == "" ? "" : ",") gctx[g] "@" gts[g] ":" s ":" gval[g] "/" gsc[g]
			}
			else na++
		}
		if (nfl > 10) flagged = flagged ",+" (nfl - 10) "_more"
		if (flagged == "") flagged = "none"
		printf "proxies_cluster=%s pc_ok=%d pc_low=%d pc_high=%d pc_na=%d pc_excluded=%d pc_flagged=%s\n", \
			(mx == "" ? "unknown" : mx), ok, low, high, na, excl, flagged
	}'
}
PROXY_CHECK_SUMMARY="$(collect_proxy_check)"
pc_get() {
	# Pull one key=value out of PROXY_CHECK_SUMMARY; default unknown.
	local key="$1" tok
	for tok in $PROXY_CHECK_SUMMARY; do
		[[ "$tok" == "${key}="* ]] && { echo "${tok#"${key}="}"; return; }
	done
	echo "unknown"
}
# One-line warning text when any counted cluster scrape is LOW or HIGH; empty otherwise.
PROXY_CHECK_WARNING=""
if (( $(pc_get pc_low) + $(pc_get pc_high) > 0 )); then
	PROXY_CHECK_WARNING="connected proxies differ from Running sidecar pods by more than max(${PROXY_CHECK_TOL_M}%, ${PROXY_CHECK_MIN_DIFF_M}) on $(( $(pc_get pc_low) + $(pc_get pc_high) )) cluster scrape(s): $(pc_get pc_flagged)"
fi
PROXY_CHECK_TALLY="ok=$(pc_get pc_ok) low=$(pc_get pc_low) high=$(pc_get pc_high) n/a=$(pc_get pc_na) excluded=$(pc_get pc_excluded)"

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

# Shared AWK aggregator. Groups by 6-tuple (mesh|svc|reps|ns|scoping|traffic) and
# emits one record per unique key with min/max/avg for core metrics plus
# sidecar config-dump aggregates.
#
# 51-column schema (1-indexed; a 40-column file stops at col 40):
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
# Per-cluster proxy check (same value on every row of one context in one window; read
# by header name, never by position, so a 40-column file contributes nothing):
# 41 cluster_connected_proxies  42 sidecar_pods  43 proxy_check
# Traffic management (read by header name; a 40-column row is traffic_config none):
# 44 traffic_config  45 vsdr_services  46 istiod_virt_services
# 47 push_time_avg_ms  48 pushcontext_init_avg_ms
# 49 sidecar_clusters_avg  50 sidecar_cds_bytes_avg  51 sidecar_rds_bytes_avg
#
# Aggregated output (tab-separated, 47 columns). This width is INTENTIONALLY decoupled
# from the input schema above: the 6 O9 capacity cols (35-40) are point-in-time
# reads surfaced in the achieved-scale block, not aggregated, and cols 42-43 feed the
# proxy-check tally (collect_proxy_check). (Do not "sync" this to the input width.)
# cluster_proxies_* take ONE value per cluster scrape (not per pod row), and only
# from scrapes whose rows all have istiod_restarted==0.
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
#   cluster_proxies_min cluster_proxies_max cluster_proxies_avg
#   (38-47) traffic_config vsdr_services
#   virt_services_avg push_time_avg pushctx_init_avg pushes_avg cfg_size_avg
#   clusters_avg cds_bytes_avg rds_bytes_avg
# virt_services/push_time/pushctx_init/pushes/cfg_size are istiod-sourced and gated on
# istiod_restarted==0 like every istiod metric (PL35); clusters/cds/rds come from the
# sampled sidecars' config dumps, so they are always ingested (like cfg_dump_*).
# vsdr_services is the configured count (max over the cell's rows; 0 for none).
aggregate() {
	cat "${TSV_FILES[@]}" | awk -F'\t' "${AWK_COMBO_KEY}
${AWK_HEADER_IX}"'
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
		# No valid sample: N/A, never a synthetic 0 that reads as a measurement.
		if (!((metric, key) in nv) || nv[metric, key] == 0) {
			return "N/A\tN/A\tN/A"
		}
		a = min[metric, key]; b = max[metric, key]; c = sum[metric, key] / nv[metric, key]
		return sprintf("%.0f\t%.0f\t%.0f", a+0, b+0, c+0)
	}
	# emit_avg: the average alone, N/A without a valid sample. fmt "count" prints a
	# whole number bare and anything else with one decimal (replicas that disagree).
	function emit_avg(metric, key, fmt,    v) {
		if (!((metric, key) in nv) || nv[metric, key] == 0) return "N/A"
		v = sum[metric, key] / nv[metric, key]
		if (fmt == "count") return (v == int(v)) ? sprintf("%d", v) : sprintf("%.1f", v)
		return sprintf(fmt, v)
	}
	!/^#/ && !/^timestamp/ && NF>=40 {
		key = combo_key()
		if (!(key in seen)) { keys[++nkey] = key; seen[key] = 1 }
		# Configured VS+DR services (same on every row of the cell, failed rows included).
		vs = colv("vsdr_services")
		if (is_num(vs) && (!(key in vsdr_svcs) || vs + 0 > vsdr_svcs[key] + 0)) vsdr_svcs[key] = vs + 0
		# Sampled sidecar config-dump breakdown: proxy-side, always ingested.
		ingest("clusters", colv("sidecar_clusters_avg"), key)
		ingest("cds", colv("sidecar_cds_bytes_avg"), key)
		ingest("rds", colv("sidecar_rds_bytes_avg"), key)
		# Per-cluster proxies: one value per cluster scrape (timestamp|context|combo),
		# ingested in END only if no row of that scrape is restarted/unknown.
		cc = col("cluster_connected_proxies")
		if (cc && NF >= cc) {
			g = $1 SUBSEP $2 SUBSEP key
			if (!(g in gkey)) { gkey[g] = key; gval[g] = $cc }
			if ($31 != "0") gbad[g] = 1
		}
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
			# Traffic-management istiod columns (cols 13 and 23 have always existed).
			ingest("virt",      colv("istiod_virt_services"), key)
			ingest("push_time", colv("push_time_avg_ms"), key)
			ingest("pushctx",   colv("pushcontext_init_avg_ms"), key)
			ingest("pushes",    $13, key)
			ingest("cfg_size",  $23, key)
			n_valid[key]++
		}
	}
	END {
		for (g in gkey) if (!(g in gbad)) ingest("cprx", gval[g], gkey[g])
		for (i = 1; i <= nkey; i++) order[i] = keys[i]
		# S9 sort fix: track `decided` flag so the string comparisons
		# (sidecar_scoping, then traffic_config) only fire when no numeric field
		# resolved the ordering. none sorts before vsdr.
		for (i = 1; i < nkey; i++) {
			for (j = i + 1; j <= nkey; j++) {
				split(order[i], a, "|"); split(order[j], b, "|")
				swap = 0; decided = 0
				for (k = 1; k <= 4; k++) {
					if (a[k]+0 < b[k]+0) { decided = 1; break }
					if (a[k]+0 > b[k]+0) { swap = 1; decided = 1; break }
				}
				if (!decided && a[5] != b[5]) { decided = 1; if (a[5] > b[5]) swap = 1 }
				if (!decided && a[6] > b[6]) swap = 1
				if (swap) { t = order[i]; order[i] = order[j]; order[j] = t }
			}
		}
		printf "mesh_size\tservice_count\treplicas\tnamespace_count\tsidecar_scoping\tn_total\tn_valid\tmem_min\tmem_max\tmem_avg\tconv99_min\tconv99_max\tconv99_avg\tqueue99_min\tqueue99_max\tqueue99_avg\tproxies_min\tproxies_max\tproxies_avg\trestarts\tunknown_restarts\tcpu_delta_min\tcpu_delta_max\tcpu_delta_avg\tcfg_dump_avg\tcfg_dump_max\tconv99_floor_pinned\tqueue99_floor_pinned\theap_alloc_min\theap_alloc_max\theap_alloc_avg\theap_inuse_min\theap_inuse_max\theap_inuse_avg\tcluster_proxies_min\tcluster_proxies_max\tcluster_proxies_avg\ttraffic_config\tvsdr_services\tvirt_services_avg\tpush_time_avg\tpushctx_init_avg\tpushes_avg\tcfg_size_avg\tclusters_avg\tcds_bytes_avg\trds_bytes_avg\n"
		for (i = 1; i <= nkey; i++) {
			k = order[i]
			split(k, p, "|")
			nt = n_total[k]+0
			nv_count = (k in n_valid) ? n_valid[k] : 0
			rr = (k in restarts) ? restarts[k] : 0
			uu = (k in unknowns) ? unknowns[k] : 0
			# No proxy sampled (failed cell, or --config-dump-samples 0): N/A, not 0.
			ca = (cfg_avg_n[k]+0 > 0) ? sprintf("%.0f", cfg_avg_sum[k] / cfg_avg_n[k]) : "N/A"
			cm = (k in cfg_max_val) ? sprintf("%.0f", cfg_max_val[k]+0) : "N/A"
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
			# A none cell with no vsdr_services column (40-column rows) configured none.
			vsc = (k in vsdr_svcs) ? vsdr_svcs[k] : (p[6] == "none" ? 0 : "N/A")
			printf "%s\t%s\t%s\t%s\t%s\t%d\t%d\t%s\t%s\t%s\t%s\t%d\t%d\t%s\t%s\t%s\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
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
				emit3("heap_inuse", k),
				emit3("cprx",       k),
				p[6], vsc,
				emit_avg("virt", k, "count"),
				emit_avg("push_time", k, "%.2f"),
				emit_avg("pushctx", k, "%.2f"),
				emit_avg("pushes", k, "%.0f"),
				emit_avg("cfg_size", k, "%.0f"),
				emit_avg("clusters", k, "%.0f"),
				emit_avg("cds", k, "%.0f"),
				emit_avg("rds", k, "%.0f")
		}
	}'
}

# vsdr_ingest_short <aggregated>: one `mesh|svc|reps|ns|scoping<TAB>detail` line per
# vsdr cell whose istiod did not ingest every configured VirtualService (PL31: a
# discriminator for "the VS/DR never reached istiod", e.g. a namespace outside
# discoverySelectors). pilot_virt_services counts every VS istiod knows, so when the
# paired none cell has a value the check uses the increase over it (pre-existing VS in
# the mesh would otherwise hide a shortfall); without a pair it uses the absolute
# count. Cells with no valid istiod sample are skipped (nothing to judge).
vsdr_ingest_short() {
	awk -F'\t' '
	function is_num(s) { return s ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	NR == 1 { next }
	{
		base = $1 "|" $2 "|" $3 "|" $4 "|" $5
		if ($38 == "none") none_virt[base] = $40
		else if ($38 == "vsdr") { vb[++n] = base; vv[n] = $40; ve[n] = $39 }
	}
	END {
		for (i = 1; i <= n; i++) {
			b = vb[i]
			if (!is_num(vv[i]) || !is_num(ve[i])) continue
			if ((b in none_virt) && is_num(none_virt[b])) {
				got = vv[i] - none_virt[b]
				if (got < ve[i]) printf "%s\tistiod VirtualServices %s -> %s (+%s) < %s configured\n", b, none_virt[b], vv[i], got, ve[i]
			} else if (vv[i] + 0 < ve[i] + 0) {
				printf "%s\tistiod VirtualServices %s < %s configured\n", b, vv[i], ve[i]
			}
		}
	}' <<<"$1"
}

report_text() {
	local aggregated short
	aggregated=$(aggregate)
	short="$(vsdr_ingest_short "$aggregated")"
	echo "=== Control-Plane Resource Scaling ==="
	echo "# RUN_ID=${RUN_ID_TAG}  ISTIO_VERSION=${ISTIO_VERSION_TAG}  HARNESS_SHA=${HARNESS_SHA_TAG}  files_consumed=${FILES_CONSUMED}  skipped_legacy=${FILES_SKIPPED}  run_config=${RUN_CONFIG_M}  run_config_sha256=${RUN_CONFIG_SHA256_M}"
	echo ""
	# O9 achieved-scale block (clearly delimited; tolerates unknown). Pulled from
	# the per-row capacity columns (max across rows) + the preamble.
	echo "--- Achieved scale vs capacity (O9) ---"
	echo "  node allocatable (cpu_m/mem_mi): $(preamble_get NODE_ALLOC_CPU_M) / $(preamble_get NODE_ALLOC_MEM_MI)"
	echo "  istiod limit (cpu_m/mem_mi):  $(preamble_get ISTIOD_CPU_LIMIT_M) / $(preamble_get ISTIOD_MEM_LIMIT_MI)  [per replica]"
	echo "  istiod request (cpu_m/mem_mi): $(preamble_get ISTIOD_REQ_CPU_M) / $(preamble_get ISTIOD_REQ_MEM_MI)  [per replica]"
	echo "  istiod replicas:             $(istiod_replicas_label)"
	echo "  istiod replicas by context:  $(preamble_get ISTIOD_REPLICAS_BY_CONTEXT)"
	echo "  network topology:            $(preamble_get NETWORK_TOPOLOGY)"
	echo "  metrics API (preflight):     $(preamble_get METRICS_API)"
	echo "  tuning baseline (live mesh): $(preamble_get TUNING_BASELINE)"
	echo "  sidecar egress hosts (live): $(preamble_get SIDECAR_EGRESS_HOSTS)"
	echo "  connected_proxies per istiod replica (max): $(as_get proxies)"
	echo "  connected_proxies per cluster (max): $(pc_get proxies_cluster)  [pilot_xds summed over a cluster's istiod pods at one final scrape]"
	echo "  proxy check vs Running sidecar pods (tolerance ${PROXY_CHECK_TOL_M}%, min diff ${PROXY_CHECK_MIN_DIFF_M}): ${PROXY_CHECK_TALLY}"
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
	[[ -n "$PROXY_CHECK_WARNING" ]] && echo "  WARNING: ${PROXY_CHECK_WARNING}"
	echo ""
	echo "Customer SLA verdict: ${SLA_VERDICT} — ${SLA_HEADLINE}"
	echo ""
	echo "Sweep axes:"
	echo "  mesh_sizes:        ${SWEEP_MESH}"
	echo "  service_counts:    ${SWEEP_SVC}"
	echo "  replica_counts:    ${SWEEP_REP}"
	echo "  namespace_counts:  ${SWEEP_NS}"
	echo "  sidecar_scopings:  ${SWEEP_SCOPE}"
	echo "  traffic_configs:   ${SWEEP_TRAFFIC}${TRAFFIC_AXIS_NOTE}"
	echo ""
	echo "Files: ${TSV_FILES[*]}"
	echo ""
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
		conv_pin = ($27+0 == 1) ? "  [SINGLE-BUCKET-PINNED: all delta mass in the 0-100ms bucket; value is a uniform-within-bucket assumption, unresolved below 100ms]" : ""
		queue_pin = ($28+0 == 1) ? "  [SINGLE-BUCKET-PINNED: all delta mass in the 0-100ms bucket; value is a uniform-within-bucket assumption, unresolved below 100ms]" : ""
		printf "--- mesh_size=%s service_count=%s replicas=%s namespace_count=%s sidecar_scoping=%s traffic_config=%s (n_total=%s n_valid=%s) ---\n", $1, $2, $3, $4, $5, $38, $6, $7
		printf "  istiod CPU avg (m):   min=%s max=%s avg=%s   [process_cpu_seconds_total delta over window]\n", $22, $23, $24
		printf "  istiod Memory (Mi):   min=%s max=%s avg=%s   [process_resident_memory_bytes peak]\n", $8, $9, $10
		printf "  Go heap alloc (Mi):   min=%s max=%s avg=%s   [go_memstats_alloc_bytes]\n", $29, $30, $31
		printf "  Go heap inuse (Mi):   min=%s max=%s avg=%s   [go_memstats_heap_inuse_bytes]\n", $32, $33, $34
		printf "  Convergence p99 (ms): %s%s\n", bucket_range($12), conv_pin
		printf "  Queue p99 (ms):       %s%s\n", bucket_range($15), queue_pin
		printf "  Connected proxies / istiod replica: min=%s max=%s avg=%s\n", $17, $18, $19
		printf "  Connected proxies / cluster:        min=%s max=%s avg=%s   [one value per cluster scrape]\n", $35, $36, $37
		if ($25+0 > 0) printf "  Config dump avg (MB): %.1f   max: %.1f\n", $25/1048576, $26/1048576
		else if ($6 > 0) printf "  Config dump avg (MB): N/A\n"
		printf "  Traffic mgmt:         VS+DR services=%s istiod VirtualServices avg=%s push time avg (ms)=%s PushContext init avg (ms)=%s\n", $39, $40, $41, $42
		printf "  xDS pushes avg=%s   xDS config size avg (bytes)=%s\n", $43, $44
		printf "  Sampled sidecars:     CDS clusters avg=%s CDS bytes avg=%s RDS bytes avg=%s\n", $45, $46, $47
		if ($20+0 > 0) printf "  ! istiod restarts:    %s row(s) had restarts during the scrape window\n", $20
		if ($21+0 > 0) printf "  ? undetectable restart: %s row(s) had unknown restart state (missing process_start_time_seconds)\n", $21
		printf "\n"
	}' <<<"$aggregated"
	if [[ -n "$short" ]]; then
		while IFS=$'\t' read -r cell detail; do
			echo "WARNING: vsdr cell ${cell}: ${detail} — istiod did not ingest every VirtualService (check discoverySelectors and the namespace labels)"
		done <<<"$short"
	fi
}

report_csv() {
	local aggregated short
	aggregated=$(aggregate)
	short="$(vsdr_ingest_short "$aggregated")"
	echo "# RUN_ID=${RUN_ID_TAG},ISTIO_VERSION=${ISTIO_VERSION_TAG},HARNESS_SHA=${HARNESS_SHA_TAG},files_consumed=${FILES_CONSUMED},skipped_legacy=${FILES_SKIPPED}"
	echo "# run_config: run_config=${RUN_CONFIG_M} run_config_sha256=${RUN_CONFIG_SHA256_M}"
	echo "# sweep: mesh_sizes=${SWEEP_MESH} service_counts=${SWEEP_SVC} replica_counts=${SWEEP_REP} namespace_counts=${SWEEP_NS} sidecar_scopings=${SWEEP_SCOPE} traffic_configs=${SWEEP_TRAFFIC}"
	echo "# traffic_management: vsdr_every=${VSDR_EVERY_M} vsdr_subsets=${VSDR_SUBSETS_M}"
	# O9 achieved-scale provenance parity with text/markdown. Comment lines only, so the
	# CSV row schema (the aggregate columns below) is byte-identical for row consumers.
	echo "# capacity: node_alloc_cpu_m=$(preamble_get NODE_ALLOC_CPU_M) node_alloc_mem_mi=$(preamble_get NODE_ALLOC_MEM_MI) istiod_cpu_limit_m=$(preamble_get ISTIOD_CPU_LIMIT_M) istiod_mem_limit_mi=$(preamble_get ISTIOD_MEM_LIMIT_MI) scale_target_fraction=$(preamble_get SCALE_TARGET_FRACTION) scale_sizing_mode=$(preamble_get SCALE_SIZING_MODE) metrics_api=$(preamble_get METRICS_API) (istiod limits per replica)"
	echo "# infra: istiod_req_cpu_m=$(preamble_get ISTIOD_REQ_CPU_M) istiod_req_mem_mi=$(preamble_get ISTIOD_REQ_MEM_MI) istiod_lim_cpu_m=$(preamble_get ISTIOD_LIM_CPU_M) istiod_lim_mem_mi=$(preamble_get ISTIOD_LIM_MEM_MI) istiod_replicas=$(preamble_get ISTIOD_REPLICAS) istiod_replicas_by_context=$(preamble_get ISTIOD_REPLICAS_BY_CONTEXT) network_topology=$(preamble_get NETWORK_TOPOLOGY)"
	echo "# achieved: connected_proxies_max=$(as_get proxies) connected_proxies_cluster_max=$(pc_get proxies_cluster) services_configured_max=$(as_get svc) istiod_cpu_pct_of_limit_max=$(as_pct istiod_cpu_pct) istiod_mem_pct_of_limit_max=$(as_pct istiod_mem_pct) istiod_rss_pct_of_limit_max=$(pct_or_bare "$ISTIOD_RSS_MEM_PCT") node_cpu_pct_max=$(as_pct node_cpu_pct) node_mem_pct_max=$(as_pct node_mem_pct) pods_scheduled_max=$(as_get pods_sched) pods_allocatable_max=$(as_get pods_alloc)"
	echo "# tuning_baseline: $(preamble_get TUNING_BASELINE) | sidecar_egress_hosts: $(preamble_get SIDECAR_EGRESS_HOSTS)"
	echo "# proxy_check: tolerance_pct=${PROXY_CHECK_TOL_M} min_diff=${PROXY_CHECK_MIN_DIFF_M} ok=$(pc_get pc_ok) low=$(pc_get pc_low) high=$(pc_get pc_high) na=$(pc_get pc_na) excluded=$(pc_get pc_excluded) flagged=$(pc_get pc_flagged)"
	[[ -n "$PROXY_CHECK_WARNING" ]] && echo "# WARNING: ${PROXY_CHECK_WARNING}"
	echo "# ${COVERAGE_LINE}"
	echo "# sla_verdict: ${SLA_VERDICT} — ${SLA_HEADLINE}"
	metrics_unavailable && echo "# metrics: $(metrics_note_text)"
	if [[ -n "$short" ]]; then
		while IFS=$'\t' read -r cell detail; do
			echo "# WARNING: vsdr cell ${cell}: ${detail}"
		done <<<"$short"
	fi
	awk -F'\t' 'BEGIN{OFS=","} { $1=$1; print }' <<<"$aggregated"
}

# Metric glossary appended to the END of the markdown summary (#17). Definitions are
# pulled from tests/controlplane/README.md ("What Gets Measured" + the column schema
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
| `n_total` | rows | internal | All rows for the cell, including restart-poisoned/`unknown` and degraded (`SETUP_FAILED`/`PROBE_FAILED`, or a context with zero istiod pods) rows. |
| `n_valid` | rows | internal | Rows with `istiod_restarted==0` used in numeric aggregation; `n_valid < n_total` means some rows were dropped as poisoned. |
| `cpu_avg (m)` | millicores (per replica) | `process_cpu_seconds_total` delta ÷ window × 1000 | istiod CPU over the scrape window; `overflow` if it exceeds the histogram top bucket; `N/A` on restart/missing baseline. |
| `mem_avg (Mi)` | MiB (per replica) | `process_resident_memory_bytes` (istiod `/metrics`) | Peak RSS of (baseline, 5 s polled samples, final scrape) over the window. |
| `heap_alloc (Mi)` | MiB | `go_memstats_alloc_bytes` | Go heap allocated — point-in-time at final scrape, not a peak. |
| `heap_inuse (Mi)` | MiB | `go_memstats_heap_inuse_bytes` | Go heap in use — point-in-time at final scrape; steady-state signal independent of RSS (which stays inflated after GC via `MADV_FREE`). |
| `conv_p99 (ms)` | ms (bucket range) | `pilot_proxy_convergence_time` histogram delta | p99 convergence reported as a **bucket range** (e.g. `100-500`), not an exact value — istiod buckets are 100/500/1000/3000/5000/10000/20000/30000 ms. `†` = SINGLE-BUCKET-PINNED (all delta mass in the 0-100 ms bucket; a uniform-within-bucket assumption, unresolved below 100 ms). |
| `queue_p99 (ms)` | ms (bucket range) | `pilot_proxy_queue_time` histogram delta | p99 time pushes waited in istiod's queue; same bucket-range / `†` semantics as `conv_p99`. |
| `proxies/replica` (connected_proxies) | proxies per istiod pod | `pilot_xds` gauge summed over its series (final scrape) | Proxies connected to ONE istiod replica (each proxy holds one istiod connection, so with R replicas this is roughly 1/R of the cluster). A replica with no connections reads 0. Gated on `istiod_restarted==0` (a mid-reconnect transient is excluded). |
| `proxies/cluster` (cluster_connected_proxies) | proxies per cluster | `pilot_xds` summed over every istiod pod of one cluster, same final scrape batch | One value per cluster scrape (avg over the cell's scrapes here). `N/A` when any pod scrape was empty or short, or the Running istiod pod set changed during the window. Counted only when every pod row of that scrape has `istiod_restarted==0`. |
| `proxy check` (proxy_check) | OK / LOW / HIGH / N/A | `proxies/cluster` vs the cluster's Running, non-terminating pods with the `sidecar.istio.io/status` annotation (gateways included) | `LOW`/`HIGH` when they differ by more than max(`PROXY_CHECK_TOLERANCE_PCT` % of the sidecar pods, `PROXY_CHECK_MIN_DIFF`). A warning, never a filter: flagged scrapes stay in every aggregate. The pod count is read seconds after the scrape, so pods starting or stopping in between can flag a scrape. |
| `cfg_dump_avg (MB)` | MB | `pilot-agent request /config_dump?include_eds` → `wc -c` | Real per-proxy config-dump size (EDS included by design — the cost `Sidecar` scoping reduces); proxy-side, so ingested regardless of istiod restart state. |
| `restarts` | rows | `istiod_restarted==1` | Rows where `process_start_time_seconds` moved forward between baseline and final scrape; counters/histograms for those samples may under-report. |
| `unk_restarts` | rows | `istiod_restarted==unknown` | Rows where restart state was undetectable (a pinned pod disappeared / missing `process_start_time_seconds`). |
| `traffic` (traffic_config) | enum | sweep axis | `none` (no VirtualService/DestinationRule) or `vsdr` (one VirtualService and one DestinationRule per configured service; that service's replicas are split over one Deployment per subset, so the pod count is the same). Rows from 40-column TSVs count as `none`. |
| `VS+DR svcs` (vsdr_services) | services | configured | Services given a VirtualService + DestinationRule (`--vsdr-every`); 0 for `none`. Configured intent, not a measurement. |
| `istiod VS` (istiod_virt_services) | VirtualServices | `pilot_virt_services` gauge (final scrape) | Every VirtualService istiod knows, the test's and any already in the mesh. Same on every replica (never summed). Gated on `istiod_restarted==0`. |
| `push time avg (ms)` | ms per push | `pilot_xds_push_time` Δsum ÷ Δcount, all xDS types | Average time istiod spent generating and sending one push in the window. `N/A` with no push or on a restarted row. |
| `PushContext init avg (ms)` | ms | `pilot_pushcontext_init_seconds` Δsum ÷ Δcount | Average PushContext rebuild time in the window (VS/DR indexing lands here). `N/A` with no rebuild or on a restarted row. |
| `xDS pushes` | pushes per istiod pod | `pilot_xds_pushes` delta | Pushes over the window (TSV `xds_pushes_delta`). |
| `xDS config size avg` | bytes per push | `pilot_xds_config_size_bytes` Δsum ÷ Δcount | Average pushed resource size over all xDS types (TSV `config_size_avg_bytes`). |
| `CDS clusters` | clusters per proxy | sampled `/config_dump` `dynamic_active_clusters` | CDS clusters on the sampled sidecars; each DestinationRule subset adds one per port. Proxy-side, so not restart-gated. |
| `CDS (KB)` / `RDS (KB)` | KB per proxy | compact JSON length of the dump's `ClustersConfigDump` / `RoutesConfigDump` | A size signal for the CDS and RDS config (VirtualService routes land in RDS), not the xDS wire size. |

The "Sidecar scoping effect" table reuses `cfg_dump_avg` (per-proxy `/config_dump` MB)
and renders the reduction percentage of `namespace`/`explicit` relative to `none`
(`none->ns`, `none->explicit`); `N/A` where a scoping mode was not swept for that base combo.
It compares `traffic_config` `none` cells only.
The "Traffic management (VS/DR) effect" tables pair each `vsdr` cell with the `none` cell
of the same mesh, services, replicas, namespaces and scoping, as `none -> vsdr (change)`.
`expected extra clusters` is VS+DR services × subsets: each subset adds one CDS cluster
on every proxy that sees the service (not computed when scoping hides other namespaces).
The "Achieved scale vs capacity (O9)" block reports point-in-time capacity reads (node
allocatable, istiod limits/requests per replica, `*_pct_of_limit`/`node_*_pct` utilization
from `kubectl top`, `istiod_rss_pct_of_limit` from peak RSS, pods scheduled/allocatable) —
maxes over `n_valid`-gated rows, not windowed aggregates. Its `connected_proxies per
cluster (max)` is the peak `proxies/cluster` value, and the proxy-check row counts cluster
scrapes by result (`excluded` = scrapes with a restarted or unknown row).
GLOSSARY
}

report_markdown() {
	local aggregated short
	aggregated=$(aggregate)
	short="$(vsdr_ingest_short "$aggregated")"
	local total_restarts total_unknowns
	total_restarts=$(awk -F'\t' 'NR>1 { s += $20+0 } END { printf "%d", s+0 }' <<<"$aggregated")
	total_unknowns=$(awk -F'\t' 'NR>1 { s += $21+0 } END { printf "%d", s+0 }' <<<"$aggregated")

	echo "---"
	echo "run_id: ${RUN_ID_TAG}"
	echo "istio_version: ${ISTIO_VERSION_TAG}"
	echo "harness_sha: ${HARNESS_SHA_TAG}"
	echo "run_config: \"${RUN_CONFIG_M}\""
	echo "run_config_sha256: \"${RUN_CONFIG_SHA256_M}\""
	echo "sidecar_scoping: ${SIDECAR_SCOPING_M:-N/A}"
	echo "traffic_configs: \"${SWEEP_TRAFFIC}\""
	echo "vsdr_every: \"${VSDR_EVERY_M}\""
	echo "vsdr_subsets: \"${VSDR_SUBSETS_M}\""
	echo "config_dump_samples: ${CONFIG_DUMP_SAMPLES_M:-N/A}"
	echo "kube_versions: ${KUBE_VERSIONS_M:-N/A}"
	echo "scale_sizing_mode: $(preamble_get SCALE_SIZING_MODE)"
	echo "metrics_api: $(preamble_get METRICS_API)"
	echo "istiod_req_cpu_m: $(preamble_get ISTIOD_REQ_CPU_M)"
	echo "istiod_req_mem_mi: $(preamble_get ISTIOD_REQ_MEM_MI)"
	echo "istiod_lim_cpu_m: $(preamble_get ISTIOD_LIM_CPU_M)"
	echo "istiod_lim_mem_mi: $(preamble_get ISTIOD_LIM_MEM_MI)"
	echo "istiod_replicas: $(preamble_get ISTIOD_REPLICAS)"
	echo "istiod_replicas_by_context: \"$(preamble_get ISTIOD_REPLICAS_BY_CONTEXT)\""
	echo "network_topology: $(preamble_get NETWORK_TOPOLOGY)"
	echo "proxy_check_tolerance_pct: \"${PROXY_CHECK_TOL_M}\""
	echo "proxy_check_min_diff: \"${PROXY_CHECK_MIN_DIFF_M}\""
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
	echo "| istiod replicas | $(istiod_replicas_label) |"
	echo "| istiod replicas by context | $(preamble_get ISTIOD_REPLICAS_BY_CONTEXT) |"
	echo "| network topology | $(preamble_get NETWORK_TOPOLOGY) |"
	echo "| connected_proxies per istiod replica (max) | $(as_get proxies) |"
	echo "| connected_proxies per cluster (max) | $(pc_get proxies_cluster) |"
	echo "| proxy check vs Running sidecar pods (tolerance ${PROXY_CHECK_TOL_M}%, min diff ${PROXY_CHECK_MIN_DIFF_M}) | ${PROXY_CHECK_TALLY} |"
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
	[[ -n "$PROXY_CHECK_WARNING" ]] && { echo ""; echo "> **Warning:** ${PROXY_CHECK_WARNING}"; }
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
	echo "| traffic_configs | ${SWEEP_TRAFFIC}${TRAFFIC_AXIS_NOTE} |"
	echo ""
	echo "Files: ${TSV_FILES[*]}"
	echo ""
	echo "| mesh_size | svc | reps | ns | scoping | traffic | n_total | n_valid | cpu_avg (m) | mem_avg (Mi) | heap_alloc (Mi) | heap_inuse (Mi) | conv_p99 (ms) | queue_p99 (ms) | proxies/replica | proxies/cluster | cfg_dump_avg (MB) | restarts | unk_restarts |"
	echo "|-----------|-----|------|----|---------|---------|---------|---------|-------------|--------------|-----------------|-----------------|---------------|----------------|-----------------|-----------------|-------------------|----------|--------------|"
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
		printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $38, $6, $7, $24, $10, ha, hi, cp, qp, $19, $37, cfg_mb, $20, $21
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
Compares `traffic_config` `none` cells only.

EFFECT_HDR
	awk -F'\t' '
	NR == 1 { next }
	# vsdr cells share the base key; they are compared in the traffic-management section.
	$38 != "none" { next }
	{
		base = $1 "|" $2 "|" $3 "|" $4
		scope = $5
		cfg = $25 + 0
		if (!(base in base_seen)) { bases[++nb] = base; base_seen[base] = 1 }
		# No config-dump sample (0) is missing data, not a 100% reduction.
		if (cfg <= 0) next
		val[base, scope] = cfg
		has[base, scope] = 1
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

	# Only when the sweep has vsdr cells; a none-only report is unchanged.
	if awk -F'\t' 'NR > 1 && $38 == "vsdr" { f = 1 } END { exit !f }' <<<"$aggregated"; then
		traffic_effect_section "$aggregated" "$short"
	fi

	# #17: metric glossary at the very end of the markdown summary.
	glossary_section
}

# traffic_effect_section <aggregated> <vsdr_ingest_short output>: markdown tables that
# pair each vsdr cell with the none cell of the same base (mesh|svc|reps|ns|scoping).
traffic_effect_section() {
	local aggregated="$1" short="$2"
	cat <<'TM_HDR'

## Traffic management (VS/DR) effect

Each row pairs the `none` and `vsdr` cells of one base cell as `none -> vsdr (change)`.
Only the traffic config differs: the vsdr cell adds a VirtualService and a DestinationRule
per configured service and splits that service's replicas over one Deployment per subset
(same pod count).

TM_HDR
	awk -F'\t' -v subsets="$VSDR_SUBSETS_M" '
	function is_num(s) { return s ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	# pair <none> <vsdr> <divisor> <fmt>: "n -> v (+x%)"; N/A unless both are numbers.
	function pair(n, v, d, fmt,    s) {
		if (!is_num(n) || !is_num(v)) return "N/A"
		s = sprintf(fmt, n / d) " -> " sprintf(fmt, v / d)
		if (n + 0 != 0) s = s sprintf(" (%+.1f%%)", 100 * (v - n) / n)
		return s
	}
	NR == 1 { next }
	$38 == "none" || $38 == "vsdr" {
		base = $1 "|" $2 "|" $3 "|" $4 "|" $5
		if (!(base in seen)) { seen[base] = 1; order[++nb] = base }
		for (c = 1; c <= NF; c++) cell[base, $38, c] = $c
		has[base, $38] = 1
	}
	END {
		np = 0
		for (i = 1; i <= nb; i++) if (has[order[i], "none"] && has[order[i], "vsdr"]) pb[++np] = order[i]
		if (np == 0) {
			print "(No base cell has both a none and a vsdr cell. Sweep `--traffic-configs none,vsdr` to compare.)"
			exit
		}
		print "### istiod cost"
		print ""
		print "istiod-sourced and n_valid-gated: `N/A` when either cell has no valid sample."
		print ""
		print "| mesh | svc | reps | ns | scoping | n_valid (none/vsdr) | VS+DR svcs | istiod VS | CPU avg (m) | heap inuse (Mi) | RSS (Mi) | xDS pushes | push time avg (ms) | PushContext init avg (ms) | xDS config size avg (KB) |"
		print "|------|-----|------|----|---------|---------------------|------------|-----------|-------------|-----------------|----------|------------|--------------------|---------------------------|--------------------------|"
		for (i = 1; i <= np; i++) {
			b = pb[i]; split(b, p, "|")
			printf "| %s | %s | %s | %s | %s | %s/%s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", \
				p[1], p[2], p[3], p[4], p[5], cell[b, "none", 7], cell[b, "vsdr", 7], cell[b, "vsdr", 39], \
				pair(cell[b, "none", 40], cell[b, "vsdr", 40], 1, "%.0f"), \
				pair(cell[b, "none", 24], cell[b, "vsdr", 24], 1, "%.0f"), \
				pair(cell[b, "none", 34], cell[b, "vsdr", 34], 1, "%.0f"), \
				pair(cell[b, "none", 10], cell[b, "vsdr", 10], 1, "%.0f"), \
				pair(cell[b, "none", 43], cell[b, "vsdr", 43], 1, "%.0f"), \
				pair(cell[b, "none", 41], cell[b, "vsdr", 41], 1, "%.2f"), \
				pair(cell[b, "none", 42], cell[b, "vsdr", 42], 1, "%.2f"), \
				pair(cell[b, "none", 44], cell[b, "vsdr", 44], 1024, "%.1f")
		}
		print ""
		print "### Per-proxy config (sampled sidecars)"
		print ""
		print "Proxy-side (`/config_dump` of the sampled pods), so not restart-gated; `N/A` when no sidecar was sampled."
		print ""
		print "| mesh | svc | reps | ns | scoping | VS+DR svcs | expected extra clusters | CDS clusters | clusters delta | CDS (KB) | RDS (KB) | cfg dump (MB) |"
		print "|------|-----|------|----|---------|------------|-------------------------|--------------|----------------|----------|----------|---------------|"
		for (i = 1; i <= np; i++) {
			b = pb[i]; split(b, p, "|")
			vs = cell[b, "vsdr", 39]
			# Every proxy sees every service only with one namespace or scoping none.
			exp_cl = (is_num(vs) && is_num(subsets) && (p[4] + 0 == 1 || p[5] == "none")) ? vs * subsets : "-"
			cn = cell[b, "none", 45]; cv = cell[b, "vsdr", 45]
			dcl = (is_num(cn) && is_num(cv)) ? sprintf("%+d", cv - cn) : "N/A"
			printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", \
				p[1], p[2], p[3], p[4], p[5], vs, exp_cl, \
				pair(cn, cv, 1, "%.0f"), dcl, \
				pair(cell[b, "none", 46], cell[b, "vsdr", 46], 1024, "%.1f"), \
				pair(cell[b, "none", 47], cell[b, "vsdr", 47], 1024, "%.1f"), \
				pair(cell[b, "none", 25], cell[b, "vsdr", 25], 1048576, "%.2f")
		}
	}' <<<"$aggregated"
	if [[ -n "$short" ]]; then
		echo ""
		while IFS=$'\t' read -r cell detail; do
			echo "> **WARN:** istiod ingested fewer VirtualServices than configured in vsdr cell \`${cell}\`: ${detail}. The vsdr numbers may not include the full VS/DR load; check discoverySelectors and the test namespace labels."
		done <<<"$short"
	fi
	cat <<'TM_NOTES'

> Order bias: each vsdr cell runs right after its none cell, and istiod RSS does not shrink
> after GC (`MADV_FREE`), so vsdr RSS can carry over from the none cell. Compare heap inuse,
> or run a second sweep with `--traffic-configs vsdr,none`. Gateways also get the subset
> clusters, but only workload sidecars are sampled.
TM_NOTES
}

report_json() {
	local aggregated shortkeys
	aggregated=$(aggregate)
	# ";mesh|svc|reps|ns|scoping;..." of the vsdr cells with an ingest shortfall.
	shortkeys="$(vsdr_ingest_short "$aggregated" | awk -F'\t' '{ printf ";%s", $1 } END { print ";" }')"
	awk -F'\t' -v ri="$RUN_ID_TAG" -v iv="$ISTIO_VERSION_TAG" -v hs="$HARNESS_SHA_TAG" -v fc="$FILES_CONSUMED" -v fs="$FILES_SKIPPED" \
		-v rc_path="$RUN_CONFIG_M" -v rc_sha="$RUN_CONFIG_SHA256_M" \
		-v sw_mesh="$SWEEP_MESH" -v sw_svc="$SWEEP_SVC" -v sw_rep="$SWEEP_REP" -v sw_ns="$SWEEP_NS" -v sw_scope="$SWEEP_SCOPE" \
		-v sw_traffic="$SWEEP_TRAFFIC" -v tm_every="$VSDR_EVERY_M" -v tm_subsets="$VSDR_SUBSETS_M" -v shortkeys="$shortkeys" \
		-v cap_ncpu="$(preamble_get NODE_ALLOC_CPU_M)" -v cap_nmem="$(preamble_get NODE_ALLOC_MEM_MI)" \
		-v cap_icpu="$(preamble_get ISTIOD_CPU_LIMIT_M)" -v cap_imem="$(preamble_get ISTIOD_MEM_LIMIT_MI)" \
		-v cap_tf="$(preamble_get SCALE_TARGET_FRACTION)" -v cap_mode="$(preamble_get SCALE_SIZING_MODE)" -v cap_metrics="$(preamble_get METRICS_API)" \
		-v inf_rcpu="$(preamble_get ISTIOD_REQ_CPU_M)" -v inf_rmem="$(preamble_get ISTIOD_REQ_MEM_MI)" \
		-v inf_lcpu="$(preamble_get ISTIOD_LIM_CPU_M)" -v inf_lmem="$(preamble_get ISTIOD_LIM_MEM_MI)" \
		-v inf_rep="$(preamble_get ISTIOD_REPLICAS)" -v inf_rep_by="$(preamble_get ISTIOD_REPLICAS_BY_CONTEXT)" \
		-v inf_net="$(preamble_get NETWORK_TOPOLOGY)" \
		-v sla_v="$SLA_VERDICT" -v sla_h="$SLA_HEADLINE" \
		-v tb_levers="$(preamble_get TUNING_BASELINE)" -v tb_egress="$(preamble_get SIDECAR_EGRESS_HOSTS)" \
		-v ach_prx="$(as_get proxies)" -v ach_cprx="$(pc_get proxies_cluster)" -v ach_svc="$(as_get svc)" \
		-v pc_tol="$PROXY_CHECK_TOL_M" -v pc_min="$PROXY_CHECK_MIN_DIFF_M" \
		-v pc_ok="$(pc_get pc_ok)" -v pc_low="$(pc_get pc_low)" -v pc_high="$(pc_get pc_high)" \
		-v pc_na="$(pc_get pc_na)" -v pc_excl="$(pc_get pc_excluded)" -v pc_flagged="$(pc_get pc_flagged)" \
		-v ach_icpu="$(as_get istiod_cpu_pct)" -v ach_imem="$(as_get istiod_mem_pct)" \
		-v ach_irss="$ISTIOD_RSS_MEM_PCT" \
		-v ach_ncpu="$(as_get node_cpu_pct)" -v ach_nmem="$(as_get node_mem_pct)" \
		-v ach_psched="$(as_get pods_sched)" -v ach_palloc="$(as_get pods_alloc)" \
		-v cov="$COVERAGE_LINE" -v metrics_note="$(metrics_unavailable && metrics_note_text)" '
	function cell(v) {
		if (v !~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/) return "null"  # overflow / N/A
		return v + 0
	}
	BEGIN { printf "{\n  \"metadata\": {\"run_id\":\"%s\",\"istio_version\":\"%s\",\"harness_sha\":\"%s\",\"run_config\":\"%s\",\"run_config_sha256\":\"%s\",\"files_consumed\":%d,\"skipped_legacy\":%d,\"sweep\":{\"mesh_sizes\":\"%s\",\"service_counts\":\"%s\",\"replica_counts\":\"%s\",\"namespace_counts\":\"%s\",\"sidecar_scopings\":\"%s\",\"traffic_configs\":\"%s\"},\"traffic_management\":{\"vsdr_every\":\"%s\",\"vsdr_subsets\":\"%s\"},\"capacity\":{\"node_alloc_cpu_m\":\"%s\",\"node_alloc_mem_mi\":\"%s\",\"istiod_cpu_limit_m\":\"%s\",\"istiod_mem_limit_mi\":\"%s\",\"scale_target_fraction\":\"%s\",\"scale_sizing_mode\":\"%s\",\"metrics_api\":\"%s\",\"istiod_limits_per_replica\":true},\"infra\":{\"istiod_req_cpu_m\":\"%s\",\"istiod_req_mem_mi\":\"%s\",\"istiod_lim_cpu_m\":\"%s\",\"istiod_lim_mem_mi\":\"%s\",\"istiod_replicas\":\"%s\",\"istiod_replicas_by_context\":\"%s\",\"network_topology\":\"%s\"},\"tuning_baseline\":{\"levers\":\"%s\",\"sidecar_egress_hosts\":\"%s\"},\"achieved_scale\":{\"connected_proxies_max\":\"%s\",\"connected_proxies_cluster_max\":\"%s\",\"services_configured_max\":\"%s\",\"istiod_cpu_pct_of_limit_max\":\"%s\",\"istiod_mem_pct_of_limit_max\":\"%s\",\"istiod_rss_pct_of_limit_max\":\"%s\",\"node_cpu_pct_max\":\"%s\",\"node_mem_pct_max\":\"%s\",\"pods_scheduled_max\":\"%s\",\"pods_allocatable_max\":\"%s\"},\"proxy_check\":{\"tolerance_pct\":\"%s\",\"min_diff\":\"%s\",\"ok\":%d,\"low\":%d,\"high\":%d,\"na\":%d,\"excluded\":%d,\"flagged\":\"%s\"},\"coverage\":\"%s\",\"sla\":{\"verdict\":\"%s\",\"headline\":\"%s\"},\"metrics_note\":\"%s\"},\n  \"results\": [", ri, iv, hs, rc_path, rc_sha, fc, fs, sw_mesh, sw_svc, sw_rep, sw_ns, sw_scope, sw_traffic, tm_every, tm_subsets, cap_ncpu, cap_nmem, cap_icpu, cap_imem, cap_tf, cap_mode, cap_metrics, inf_rcpu, inf_rmem, inf_lcpu, inf_lmem, inf_rep, inf_rep_by, inf_net, tb_levers, tb_egress, ach_prx, ach_cprx, ach_svc, ach_icpu, ach_imem, ach_irss, ach_ncpu, ach_nmem, ach_psched, ach_palloc, pc_tol, pc_min, pc_ok, pc_low, pc_high, pc_na, pc_excl, pc_flagged, cov, sla_v, sla_h, metrics_note }
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
		printf "\"go_heap_inuse_mi\":{\"min\":%s,\"max\":%s,\"avg\":%s},", cell($32), cell($33), cell($34)
		printf "\"connected_proxies_cluster\":{\"min\":%s,\"max\":%s,\"avg\":%s},", cell($35), cell($36), cell($37)
		printf "\"traffic_config\":\"%s\",\"vsdr_services\":%s,\"istiod_virt_services_avg\":%s,\"push_time_avg_ms\":%s,\"pushcontext_init_avg_ms\":%s,", $38, cell($39), cell($40), cell($41), cell($42)
		printf "\"xds_pushes_avg\":%s,\"config_size_avg_bytes\":%s,\"sidecar_clusters_avg\":%s,\"sidecar_cds_bytes_avg\":%s,\"sidecar_rds_bytes_avg\":%s,", cell($43), cell($44), cell($45), cell($46), cell($47)
		printf "\"istiod_vs_ingest_short\":%s}", ($38 == "vsdr" && index(shortkeys, ";" $1 "|" $2 "|" $3 "|" $4 "|" $5 ";")) ? "true" : "false"
	}
	END {
		if (printed) printf "\n  ]\n}\n"; else printf "]\n}\n"
	}' <<<"$aggregated"
}

report_charts() {
	local aggregated
	aggregated=$(aggregate)

	echo "---"
	echo "istio_version: ${ISTIO_VERSION_TAG}"
	echo "harness_sha: ${HARNESS_SHA_TAG}"
	echo "run_config: \"${RUN_CONFIG_M}\""
	echo "run_config_sha256: \"${RUN_CONFIG_SHA256_M}\""
	echo "files_consumed: ${FILES_CONSUMED}"
	echo "generated: $(date -u -Iseconds)"
	echo "---"
	echo ""
	echo "# Control-Plane Resource Scaling — Charts"
	echo ""
	# Chart 1: istiod CPU vs mesh size, one series per sidecar scoping.
	# Chart 2: Per-proxy config dump size (MB) by scoping at largest mesh size.
	# Both chart ONE service/replica/namespace workload, so a point never mixes cells
	# from different workload sizes. Only cells with valid CPU data count: the largest
	# combo is the one most likely to fail (SETUP_FAILED/PROBE_FAILED), and picking it
	# blindly would chart nothing. Pick the largest workload (most pods = svc x rep,
	# then namespaces) with valid data at >= 2 mesh sizes; else the largest valid one.
	local max_svc max_rep max_ns pick_note
	read -r max_svc max_rep max_ns pick_note < <(awk -F'\t' '
	function is_num(s) { return s ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	function bigger(a, b,    x, y) {  # is tuple a larger than tuple b?
		if (b == "") return 1
		split(a, x, "|"); split(b, y, "|")
		if (x[1] * x[2] != y[1] * y[2]) return x[1] * x[2] > y[1] * y[2]
		if (x[1] + 0 != y[1] + 0) return x[1] + 0 > y[1] + 0
		return x[3] + 0 > y[3] + 0
	}
	NR > 1 && $7 + 0 > 0 && is_num($24) {
		t = ($2 + 0) "|" ($3 + 0) "|" ($4 + 0)
		if (!((t, $1 + 0) in seen)) { seen[t, $1 + 0] = 1; n_ms[t]++ }
	}
	END {
		best = ""; best2 = ""
		for (t in n_ms) {
			if (bigger(t, best)) best = t
			if (n_ms[t] >= 2 && bigger(t, best2)) best2 = t
		}
		if (best2 != "") { split(best2, p, "|"); note = "largest with valid data at 2+ mesh sizes" }
		else if (best != "") { split(best, p, "|"); note = "largest with valid data" }
		else { print "0 0 0 none"; exit }
		print p[1], p[2], p[3], note
	}' <<<"$aggregated")
	if [[ "$pick_note" == "none" ]]; then
		echo "> No cell has valid samples — nothing to chart."
		return 0
	fi
	echo "> Workload charted: ${max_svc} services x ${max_rep} replicas in ${max_ns} namespace(s) per cluster (${pick_note})."
	echo ""
	awk -F'\t' -v max_svc="$max_svc" -v max_rep="$max_rep" -v max_ns="$max_ns" '
	function is_num(s) { return s ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	NR == 1 { next }
	$2+0 != max_svc || $3+0 != max_rep || $4+0 != max_ns { next }
	{
		# One series per scoping, plus scoping/vsdr for the vsdr cells (otherwise a
		# vsdr cell would overwrite the none cell of the same scoping).
		ms = $1 + 0; scoping = ($38 == "vsdr") ? $5 "/vsdr" : $5; n_valid = $7 + 0
		# PL13/PL15 + PL8 gate (mirrors the markdown/json n_valid + overflow handling):
		# a cell with no valid samples (every row restart-poisoned/unknown so n_valid==0,
		# where the aggregate emit3 returns N/A) or whose cpu_delta_avg ($24) is
		# overflow/N/A is ABSENT, not a real 0 data point. Coercing it (awk $24 + 0) would
		# plot a poisoned/overflow cell as the LOWEST CPU point, the inverse of reality.
		# Count it as dropped and leave has[] unset so it is never charted as 0.
		# Config dump ($25) is gated separately: it is N/A whenever no proxy was sampled
		# (--config-dump-samples 0), which must not drop the cell from the CPU chart.
		cells_total++
		if (n_valid <= 0 || !is_num($24)) {
			cells_dropped++
			next
		}
		if (!(ms in ms_seen)) { ms_order[++n_ms] = ms; ms_seen[ms] = 1 }
		if (!(scoping in sc_seen)) { sc_order[++n_sc] = scoping; sc_seen[scoping] = 1 }
		cpu_val[ms, scoping] = $24 + 0
		if (is_num($25)) cfg_val[ms, scoping] = $25 + 0
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
		printf "```mermaid\n"
		printf "xychart-beta\n"
		printf "    title \"istiod CPU vs Mesh Size by Sidecar Scoping (and traffic config)\"\n"
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
		printf "```mermaid\n"
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

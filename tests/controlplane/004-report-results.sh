#!/usr/bin/env bash
# Generate summary statistics from control-plane resource metrics TSV files.
#
# Groups by the six sweep axes — mesh_size, service_count, replicas,
# namespace_count, sidecar_scoping, traffic_config — so the operator can compare any
# single dimension while the others are held constant.
#
# More than one run under the results dir stops the report unless --allow-multi-run
# (the pods-vs-config-only calibration pools sweeps on purpose), and then every format
# says so (R3).
#
# Usage:
#   ./tests/controlplane/004-report-results.sh [--results-dir DIR] [--allow-multi-run] [--format FMT]
#
# Examples:
#   ./tests/controlplane/004-report-results.sh --results-dir tests/controlplane/results/sweep-<RUN_ID>
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
source "${ROOT}/tests/lib/capacity.sh"  # quantity parsers envelope.sh uses
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/envelope.sh"  # env_sla_verdict (customer SLA headline)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fit.sh"  # FIT_AWK (namespace-scaling fits)

RESULTS_DIR="$(config_repo_path "${CONTROLPLANE_RESULTS_DIR}")"
FORMAT="text"
# --allow-multi-run: pool more than one run (else the report refuses, R3). Per invocation
# like --force-large-matrix, so no options.env key.
ALLOW_MULTI_RUN=0

# Namespace-scaling fit rules (scaling_records; --help prints the floor).
# A window's convergence p99 joins a fit only with at least this many xDS pushes per
# istiod replica (aggregated col 43, the pilot_xds_pushes delta summed over the
# cds/eds/lds/rds/nds types). istiod counts pilot_xds_pushes once per xDS type sent but
# records pilot_proxy_convergence_time once per proxy push event, so a full push adds
# 3-5 pushes (one per watched type) and one convergence sample (a 1.30.5 scrape: 22
# pushes over cds/eds/lds, 14 samples). 120 pushes is about 30 full pushes, at least 24
# samples; below that the p99 is close to the maximum of a handful of samples, which a
# probe window under namespace scoping typically is.
CONV_FIT_MIN_PUSHES=120
# The fit rules as one sentence, repeated by every format (PL19).
CONV_FIT_RULE="conv_p99_ms points come only from windows with at least ${CONV_FIT_MIN_PUSHES} xDS pushes per istiod replica, counted across xDS types (a full push to one proxy adds one push per xDS type it watches, typically 3-5, but one convergence sample), so at least about 24 samples; most probe windows have none. A p99 that stays in istiod's first bucket (0-100 ms) is left out (an interpolation, not a measurement), and every point is only as precise as its histogram bucket."
GROW_FIT_RULE="The first grow window of a series (from 0 namespaces) is left out of every grow-window fit of a window measurement (onboard_*_per_ns, push_time_ms, pushcontext_init_ms, conv_p99_ms): it also creates and waits for the M measurement pods (certificates, initial full pushes, endpoint updates), work no later step repeats (PL30). Its gauges are fitted."
SERIES_FIT_RULE="A growth series is one RUN_ID x mesh size x K x workload (003 runs one series per mesh size and K): its cells, grow ladder (N_prev), fits, M-sweep and discovery rows never pool with another run's, even at the same N, and with more than one series run every label carries run=<RUN_ID>. Only the pods-vs-config-only and fresh-vs-in-place pairings compare cells of different runs (each side comes from its own sweep); they name the run of each side and, where several runs have a candidate cell, take the latest RUN_ID."

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE      Run config of KEY=value lines (config/options.env keys; see
                     tests/controlplane/README.md, "Run config"). Precedence: flag >
                     --config > environment > default.
  --results-dir DIR  Results directory (default: ${CONTROLPLANE_RESULTS_DIR}). Every
                     controlplane-*.tsv under it is read; a sweep-*/ dir from 003 is
                     one run. The report lists each distinct RUN_ID, ISTIO_VERSION and
                     HARNESS_SHA (run_ids, istio_versions, harness_shas) and prints a
                     WARNING when Istio versions or harness commits differ.
  --allow-multi-run  Pool more than one run, as the pods-vs-config-only calibration does
                     (a base dir with a pods sweep and a config-only sweep). Without it
                     a dir with several runs stops the report, which lists them and how
                     to report each alone. With it every format says it pools N runs
                     and lists their HARNESS_SHA and ISTIO_VERSION values; legacy cells
                     pool across runs, while each growth series (RUN_ID x mesh size x K
                     x workload) keeps its own cells and fits, labelled run=<RUN_ID>.
  --format FMT       Output format: text, csv, json, markdown (or md), charts (default: text).
  -h, --help         Show this help.

Example (one sweep, as 003 runs it; from the repo root):
  tests/controlplane/$(basename "$0") --results-dir ${CONTROLPLANE_RESULTS_DIR}/sweep-<RUN_ID> --format markdown

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
a WARNING line but never changes the exit code. Reads 40-, 51-, 63- and 66-column TSVs;
40-column files add nothing to the per-cluster or traffic-management figures and
their rows count as traffic_config none; 40- and 51-column rows count as the legacy
layout (services_per_namespace 0, workload pods, window deploy); rows before 66
columns have no gateway working set or leftover-namespace count (N/A).

Units: memory in Mi (MiB); config and push sizes in KiB / MiB (1024-based); latency
in ms; istiod CPU in millicores: cpu_peak = the larger of the window average and the
busiest 5 s poll, cpu_avg = CPU-seconds over the window / the window. A failed series
retire (RETIRE_FAILED) and leftover test namespaces above LEFTOVER_NS_WARN print a
WARNING in every format.

Namespace scaling (growth cells, services_per_namespace > 0): the grouping key also
holds services_per_namespace, workload_mode, measurement_pods, outside_namespaces,
outside_discovery, window_kind and the series run (the file's RUN_ID: a series is one
RUN_ID x mesh size x K x workload, so two sweeps in one base dir are never pooled or
fitted together; only the pods-vs-config-only and fresh-vs-in-place pairings compare
runs, naming each side's run), and every format adds a "Namespace scaling"
section: linear fits against namespace count (slope per 100 namespaces, intercept,
R², n, log-log exponent) with the raw points, the pods-vs-config-only comparison
(always shown; it says so when a side is missing), the measurement-pod sweep, the
discovery pairing (outside namespaces none/unlabeled/labeled) and fresh-vs-in-place
fidelity. Fits use cells with n_valid > 0 only; the first grow window (from 0
namespaces, it also boots the measurement pods) stays out of the grow fits of window
measurements, and convergence p99 needs ${CONV_FIT_MIN_PUSHES} xDS pushes per replica counted
across xDS types (about 30 full pushes).

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
		shift 2
		;;
	--allow-multi-run)
		ALLOW_MULTI_RUN=1
		shift
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

# Partition by header width: 66 columns (current, CONTROLPLANE_SCHEMA=66: gateway
# physical memory and working set, leftover test namespaces), 63 columns (before
# those), 51 columns (before the namespace-scaling columns 52-63) and 40 columns (before the per-cluster
# proxy check, cols 41-43, and the traffic-management columns, cols 44-51). Older
# files feed every aggregate they always fed: their rows count as traffic_config none
# (40 columns) and as the legacy layout (services_per_namespace 0, workload pods,
# window deploy), and add nothing to figures that read later columns by header name.
# Any other width is legacy and skipped (43 and 48 columns were intermediate layouts
# that never shipped).
TSV_FILES=()
LEGACY_FILES=()
PRE_CHECK_FILES=0
for f in "${ALL_TSV[@]}"; do
	header=$(grep -m1 -v '^#' "$f" 2>/dev/null || true)
	tabs=$(awk -F'\t' '{print NF}' <<<"$header")
	case "$tabs" in
	66 | 63 | 51) TSV_FILES+=("$f") ;;
	40) TSV_FILES+=("$f"); PRE_CHECK_FILES=$((PRE_CHECK_FILES + 1)) ;;
	*) LEGACY_FILES+=("$f") ;;
	esac
done

if (( ${#LEGACY_FILES[@]} > 0 )); then
	echo "warning: skipping ${#LEGACY_FILES[@]} legacy TSV file(s) with an unsupported schema (expected 40, 51, 63 or 66 columns):" >&2
	for f in "${LEGACY_FILES[@]}"; do
		echo "  $f" >&2
	done
fi

if (( ${#TSV_FILES[@]} == 0 )); then
	die "no TSV files with a supported schema (40, 51, 63 or 66 columns) found in $RESULTS_DIR"
fi
if (( PRE_CHECK_FILES > 0 )); then
	echo "note: ${PRE_CHECK_FILES} TSV file(s) use the 40-column schema (no per-cluster proxy or traffic-management columns); their rows count as traffic_config none and add nothing to the per-cluster proxy figures, the proxy check or the VS/DR figures" >&2
fi

# Shared awk snippets, prepended to the programs that need them.
# AWK_HEADER_IX: column lookup by header name for the appended columns (41+). The
# index is rebuilt at each file's header line, so rows of a file whose header lacks a
# name (a 40-column file) get col(name) == 0 and colv(name) == "" and contribute
# nothing; traffic() reads such rows as none.
# The growth helpers (spn, wmode, mpods, outx, odisc, wkind) read the namespace-scaling
# columns 52-57 and default a 40/51-column row to the legacy layout: 0, pods,
# service_count x replicas, 0, none, deploy.
# shellcheck disable=SC2016
AWK_HEADER_IX='/^timestamp\t/ { delete ix; for (i = 1; i <= NF; i++) ix[$i] = i; next }
function col(name) { return (name in ix) ? ix[name] : 0 }
function colv(name,    c) { c = col(name); return (c && NF >= c) ? $c : "" }
function traffic(    v) { v = colv("traffic_config"); return (v == "" ? "none" : v) }
function spn(    v) { v = colv("services_per_namespace"); return (v == "" ? 0 : v) }
function wmode(    v) { v = colv("workload_mode"); return (v == "" ? "pods" : v) }
function mpods(    v) { v = colv("measurement_pods"); return (v == "" ? ($4 * $5) : v) }
function outx(    v) { v = colv("outside_namespaces"); return (v == "" ? 0 : v) }
function odisc(    v) { v = colv("outside_discovery"); return (v == "" ? "none" : v) }
function wkind(    v) { v = colv("window_kind"); return (v == "" ? "deploy" : v) }'
# AWK_SERIES_RUN: rid = the RUN_ID of the file a row comes from (its `# RUN_ID=` line; a
# file without one is its own run, unknown-<file ordinal>). It needs awk to read the
# files as arguments, never through cat (FNR restarts per file), and goes before
# AWK_HEADER_IX, whose header rule ends with `next`.
# shellcheck disable=SC2016
AWK_SERIES_RUN='FNR == 1 { nfile++; rid = "unknown-" nfile }
/^# RUN_ID=./ { rid = substr($0, 10); gsub(/[|" \t\\]/, "_", rid) }'
# AWK_COMBO_KEY: the per-combo grouping key (needs AWK_HEADER_IX for traffic() and the
# growth helpers, and AWK_SERIES_RUN for rid). aggregate() and collect_proxy_check must
# group identically, so a new sweep axis is added here once (collect_sweep_axes reads
# the same traffic()). Parts 1-6 are the legacy axes; parts 7-12 (services_per_namespace,
# workload_mode, measurement_pods, outside_namespaces, outside_discovery, window_kind)
# keep growth cells apart and read as 0|pods|<svc x reps>|0|none|deploy for every legacy
# row. Part 13 is the series run: a growth series is one RUN_ID x mesh size x K x
# workload (003 runs one series per mesh size and K, one workload per sweep), so growth
# rows of different runs never pool into one cell, even at the same N. Legacy rows read
# `-` and pool across runs as before.
# shellcheck disable=SC2016
AWK_COMBO_KEY='function combo_key() { return $3 "|" $4 "|" $5 "|" $6 "|" $7 "|" traffic() "|" spn() "|" wmode() "|" mpods() "|" outx() "|" odisc() "|" wkind() "|" (spn() + 0 > 0 ? rid : "-") }'

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

# Reproducibility tags (PL2/PL19/PL26) from EVERY consumed TSV, so committed campaign
# artifacts are attributable to the runs that produced them. A base-dir report (the
# pods-vs-config-only calibration) pools several sweeps, so each tag also has a list of
# its distinct values in file order (run_ids, istio_versions, harness_shas in all four
# formats). RUN_ID legitimately differs between pooled sweeps: the scalar reads
# `multiple`. ISTIO_VERSION and HARNESS_SHA must not: the scalar reads mixed:<a>,<b> and
# stderr gets a WARNING. One file's own mixed ISTIO_VERSION (members that ran different
# versions) is joined with /, so it stays one list item and one tag (A4).
# tag_values KEY [MISSING]: the distinct `# KEY=` values across TSV_FILES,
# comma-separated, in file order (preamble_scalar shares it). An empty value reads
# unknown; a file without the key counts as MISSING (default unknown), or is skipped
# when MISSING is empty.
tag_values() {
	local key="$1" missing="${2-unknown}" f v vals=""
	for f in "${TSV_FILES[@]}"; do
		v="$(grep -m1 "^# ${key}=" "$f" 2>/dev/null || true)"
		if [[ -n "$v" ]]; then
			v="${v#*=}"
			[[ -n "$v" ]] || v=unknown
		elif [[ -n "$missing" ]]; then
			v="$missing"
		else
			continue
		fi
		case ",${vals}," in *",${v},"*) ;; *) vals="${vals:+${vals},}${v}" ;; esac
	done
	echo "$vals"
}
RUN_IDS_M="$(tag_values RUN_ID)"
ISTIO_VERSIONS_M="$(tag_values ISTIO_VERSION)"
HARNESS_SHAS_M="$(tag_values HARNESS_SHA)"
RUN_ID_TAG="$RUN_IDS_M"
[[ "$RUN_IDS_M" == *,* ]] && RUN_ID_TAG=multiple
ISTIO_VERSION_TAG="$ISTIO_VERSIONS_M"
# Pooled runs: each distinct version once, also when one run's own value was mixed:a/b
# (config_input_value, X13); the list keeps one item per run.
[[ "$ISTIO_VERSIONS_M" == *,* ]] && ISTIO_VERSION_TAG="$(config_input_value ISTIO_VERSION unknown "${TSV_FILES[@]}")"
HARNESS_SHA_TAG="$HARNESS_SHAS_M"
[[ "$HARNESS_SHAS_M" == *,* ]] && HARNESS_SHA_TAG="mixed:${HARNESS_SHAS_M}"
# PROVENANCE_WARNING: what the mixed tags mean, repeated in every format (empty when
# the inputs agree).
PROVENANCE_WARNING=""
# A one-file value mixed:a/b is a sweep whose members ran different versions (R4).
if [[ "$ISTIO_VERSIONS_M" == *,* || "$ISTIO_VERSIONS_M" == mixed:* ]]; then
	PROVENANCE_WARNING="The inputs were measured on different Istio versions (ISTIO_VERSION ${ISTIO_VERSIONS_M}), so fits and pairings across runs mix versions."
fi
if [[ "$HARNESS_SHAS_M" == *,* ]]; then
	PROVENANCE_WARNING="${PROVENANCE_WARNING:+${PROVENANCE_WARNING} }The inputs come from different harness commits (HARNESS_SHA ${HARNESS_SHAS_M}), so their cells may not be measured the same way."
fi
if [[ -n "$PROVENANCE_WARNING" ]]; then
	echo "WARNING: ${PROVENANCE_WARNING} Report one Istio version and one clean harness commit per results dir." >&2
fi

# files_label: the consumed TSVs relative to the results dir. An absolute path would put
# the operator's home directory (a username) into a report that gets committed.
files_label() {
	local f out=""
	for f in "${TSV_FILES[@]}"; do out+="${out:+ }${f#"${RESULTS_DIR%/}"/}"; done
	echo "${out} (in results dir $(basename "$RESULTS_DIR"))"
}
# json_list CSV: a JSON array of strings, which is also a YAML flow sequence (the
# markdown and charts frontmatter use it as one).
json_list() {
	awk -v s="$1" 'BEGIN { n = split(s, a, ","); printf "["; for (i = 1; i <= n; i++) { gsub(/["\\]/, "", a[i]); printf "%s\"%s\"", (i > 1 ? "," : ""), a[i] }; print "]" }'
}

# R3/PL6: a results dir can hold many runs, and the report aggregates all of them. More
# than one run (a sweep-* dir, or a RUN_ID outside one) stops it unless
# --allow-multi-run (the pods-vs-config-only calibration pools a base dir on purpose);
# then every format carries POOLED_NOTE. Growth series stay apart (their labels carry
# run=<RUN_ID>) and each pods-vs-config-only row names its runs.
config_check_multi_run "$RESULTS_DIR" "$ALLOW_MULTI_RUN" "${TSV_FILES[@]}"
POOLED_NOTE="$(config_multi_run_note)"
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
# Over every input, mixed:a,b when they differ (PL26); empty when no input has it.
CONFIG_DUMP_SAMPLES_M="$(config_input_value CONFIG_DUMP_SAMPLES "" "${TSV_FILES[@]}")"

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
		spns[spn()]=1; wms[wmode()]=1; wks[wkind()]=1
	}
	END {
		n=collect(mesh,a);  printf "mesh_sizes: %s\n", join(a,n)
		n=collect(svc,a);   printf "service_counts: %s\n", join(a,n)
		n=collect(rep,a);   printf "replica_counts: %s\n", join(a,n)
		n=collect(ns,a);    printf "namespace_counts: %s\n", join(a,n)
		n=collect(scope,a); printf "sidecar_scopings: %s\n", join(a,n)
		n=collect(tcs,a);   printf "traffic_configs: %s\n", join(a,n)
		n=collect(spns,a);  printf "services_per_namespace: %s\n", join(a,n)
		n=collect(wms,a);   printf "workload_modes: %s\n", join(a,n)
		n=collect(wks,a);   printf "window_kinds: %s\n", join(a,n)
	}'
}
SWEEP_AXES="$(collect_sweep_axes)"
SWEEP_MESH="$(echo "$SWEEP_AXES" | grep '^mesh_sizes:' | cut -d' ' -f2-)"
SWEEP_SVC="$(echo "$SWEEP_AXES" | grep '^service_counts:' | cut -d' ' -f2-)"
SWEEP_REP="$(echo "$SWEEP_AXES" | grep '^replica_counts:' | cut -d' ' -f2-)"
SWEEP_NS="$(echo "$SWEEP_AXES" | grep '^namespace_counts:' | cut -d' ' -f2-)"
SWEEP_SCOPE="$(echo "$SWEEP_AXES" | grep '^sidecar_scopings:' | cut -d' ' -f2-)"
SWEEP_TRAFFIC="$(echo "$SWEEP_AXES" | grep '^traffic_configs:' | cut -d' ' -f2-)"
SWEEP_SPN="$(echo "$SWEEP_AXES" | grep '^services_per_namespace:' | cut -d' ' -f2-)"
SWEEP_WMODE="$(echo "$SWEEP_AXES" | grep '^workload_modes:' | cut -d' ' -f2-)"
SWEEP_WKIND="$(echo "$SWEEP_AXES" | grep '^window_kinds:' | cut -d' ' -f2-)"

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
		# The window peak CPU (col 32: the larger of the window average and the busiest
		# 5 s poll, per replica). $35 is one kubectl-top read at the end of the window and
		# missed every burst on ROSA (0% beside a 2428m peak), so the SLA uses this too.
		upd("istiod_cpu_peak_m", $32)
	}
	END {
		split("proxies svc istiod_cpu_pct istiod_mem_pct node_cpu_pct node_mem_pct pods_sched pods_alloc istiod_rss_mem_mi istiod_cpu_peak_m", ks, " ")
		out = ""
		for (i = 1; i <= 10; i++) {
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
# preamble_get KEY: a `# KEY=value` provenance line (absolute allocatable / istiod-limit
# context for the achieved-scale block) over every input that has it: one value, or
# mixed:a,b when they differ, never the first file's (PL26); unknown when none has it.
# A mixed value is not a number, so a percentage built on it reads unknown.
declare -A MERGED_PREAMBLE=()
while IFS= read -r _kv; do
	MERGED_PREAMBLE["${_kv%%=*}"]="${_kv#*=}"
done < <(config_merged_preamble "${TSV_FILES[@]}")
preamble_get() {
	local v="${MERGED_PREAMBLE[$1]:-}"
	[[ -n "$v" ]] && echo "$v" || echo "unknown"
}
# R4: where ISTIO_VERSION came from (live: each member's running IstioRevision; pin:
# config only) and the configured pin. A file written before R4 has neither key and
# counts as unknown for both (config_merged_preamble), so pooling one with a live file
# reads mixed:live,unknown, never live.
ISTIO_VERSION_PIN_M="$(preamble_get ISTIO_VERSION_PIN)"
ISTIO_VERSION_SOURCE_M="$(preamble_get ISTIO_VERSION_SOURCE)"
# Which member ran which version (ctx=version,...), so a reader of the report alone sees
# which member was unknown or on another version (X4, PL19).
ISTIO_VERSION_BY_CONTEXT_M="$(preamble_get ISTIO_VERSION_BY_CONTEXT)"

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
	local key="$1" consequence="${2:-values are mixed}" vals
	vals="$(tag_values "$key" "${3:-}")"
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
# Namespace-scaling preamble keys (sweep-level scalars; `mixed:` with a warning when
# the inputs disagree, PL26). 40/51-column files have none of them. A report that
# pairs a pods run with a config-only run legitimately mixes WORKLOAD_MODE, so that
# key is reported per cell (workload_mode), not here.
GROWTH_MODE_M="$(preamble_scalar GROWTH_MODE "the report mixes growth modes (fresh and in-place cells are compared in the fidelity table)")"
MEM_STOP_PCT_M="$(preamble_scalar MEM_STOP_PCT "the report mixes memory-guard thresholds")"
PROBE_SETTLE_M="$(preamble_scalar PROBE_SETTLE_SEC "probe windows of different lengths are mixed")"

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
	awk -F'\t' "${AWK_COMBO_KEY}
${AWK_SERIES_RUN}
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
	}' "${TSV_FILES[@]}"
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
# istiod CPU headroom from the window peak (per replica) vs the per-replica CPU limit:
# the CPU signal of the SLA verdict and the envelope ("istiod_cpu_pct_of_limit" is a
# kubectl-top snapshot at the end of the window, kept and labelled as such).
ISTIOD_CPU_PEAK_PCT="$(env_pct_of_limit "$(as_get istiod_cpu_peak_m)" "$(preamble_get ISTIOD_CPU_LIMIT_M)" 1)"

# 003 status rows (context = the status: a cell that never ran or failed). They carry
# istiod_restarted=unknown, so they count in n_total but never in n_valid.
STATUS_RE='^(SETUP_FAILED|PROBE_FAILED|GROW_FAILED|SWITCH_FAILED|SKIPPED_MEM_GUARD|SKIPPED_SERIES_STOPPED|RETIRE_FAILED)$'
# DATA_WARNINGS: conditions that make figures of this report unsafe to quote as they
# are, one per line, printed by every format (and once on stderr):
#   - a RETIRE_FAILED row (BACKLOG 9.3): a series' namespaces stayed discovered, so 003
#     stopped; a later sweep on those members starts on a contaminated baseline;
#   - leftover test namespaces above LEFTOVER_NS_WARN on a growth row (BACKLOG 9.10):
#     they stay in istiod's informers, so its absolute heap and RSS are inflated.
LEFTOVER_NS_WARN_M="$(preamble_get LEFTOVER_NS_WARN)"
[[ "$LEFTOVER_NS_WARN_M" =~ ^[0-9]+$ ]] || LEFTOVER_NS_WARN_M="${CONTROLPLANE_LEFTOVER_NS_WARN:-100}"
DATA_WARNINGS="$(awk -F'\t' -v thr="$LEFTOVER_NS_WARN_M" "${AWK_SERIES_RUN}
${AWK_HEADER_IX}"'
	!/^#/ && NF >= 40 {
		if ($2 == "RETIRE_FAILED") { rf++; rfn = rfn (rfn == "" ? "" : ", ") "N=" $6 " run=" rid }
		v = colv("leftover_test_namespaces")
		if (v ~ /^[0-9]+$/ && v + 0 > thr + 0) { lo++; if (v + 0 > lomax) lomax = v + 0 }
	}
	END {
		if (rf) printf "RETIRE_FAILED (%s): a growth series was not retired (the cleanup failed, or its namespaces stayed discovered), so the sweep stopped there; retire it (005 --series <id> --undiscover --no-delete) before any other sweep on those members, or that sweep starts on a contaminated baseline.\n", rfn
		if (lo) printf "%d growth row(s) were measured with up to %d leftover controlplane-test namespaces from earlier series or runs on their member (warning threshold %d). They stay in istiod'"'"'s informers, so those rows'"'"' absolute istiod heap and RSS are inflated; deltas within a series stay valid. Delete the leftovers between sweeps for absolute numbers.\n", lo, lomax, thr
	}' "${TSV_FILES[@]}")"
LEFTOVER_AT_START_M="$(tag_values LEFTOVER_TEST_NAMESPACES "")"
[[ -n "$LEFTOVER_AT_START_M" ]] || LEFTOVER_AT_START_M="n/a"
# data_warnings_lines <prefix>: each DATA_WARNINGS line behind a prefix (nothing when none).
data_warnings_lines() {
	[[ -n "$DATA_WARNINGS" ]] || return 0
	local w
	while IFS= read -r w; do printf '%s%s\n' "$1" "$w"; done <<<"$DATA_WARNINGS"
}
data_warnings_lines "WARNING: " >&2
# STATUS_ROWS / STATUS_SUMMARY: their count and "SKIPPED_MEM_GUARD 4, GROW_FAILED 1"
# (first-seen order) over every consumed TSV.
read -r STATUS_ROWS STATUS_SUMMARY < <(cat "${TSV_FILES[@]}" | awk -F'\t' -v re="$STATUS_RE" '
	!/^#/ && !/^timestamp/ && NF >= 40 && $2 ~ re {
		if (!($2 in n)) order[++k] = $2
		n[$2]++; t++
	}
	END {
		s = ""
		for (i = 1; i <= k; i++) s = s (i > 1 ? ", " : "") order[i] " " n[order[i]]
		printf "%d %s\n", t + 0, (s == "" ? "-" : s)
	}')
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
	local imem_eff icpu_eff
	# max_known <a> <b>: the larger numeric value, else whichever is numeric, else unknown.
	max_known() {
		awk -v a="$1" -v b="$2" '
		function isnum(x){ return x ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
		BEGIN {
			ha=isnum(a); hb=isnum(b)
			if (ha && hb) { print (a+0>b+0)?a:b }
			else if (ha) { print a }
			else if (hb) { print b }
			else { print "unknown" }
		}'
	}
	imem_eff="$(max_known "$(as_get istiod_mem_pct)" "$ISTIOD_RSS_MEM_PCT")"
	# CPU likewise: the window peak against the limit, or the end-of-window top snapshot.
	icpu_eff="$(max_known "$(as_get istiod_cpu_pct)" "$ISTIOD_CPU_PEAK_PCT")"
	local raw
	raw="$(env_sla_verdict \
		"$icpu_eff" "$imem_eff" \
		"$(as_get node_cpu_pct)"   "$(as_get node_mem_pct)" \
		"$restarts" "$n_total" "$n_valid")"
	SLA_VERDICT="${raw%%|*}"
	SLA_HEADLINE="${raw#*|}"
	# Name the status rows behind a filtered-sample count: a memory-guard stop or a failed
	# step reads differently from istiod instability.
	if ((STATUS_ROWS > 0)); then
		SLA_HEADLINE+=" (${STATUS_ROWS} of the rows are status rows of cells skipped or failed, not restarts: ${STATUS_SUMMARY})"
	fi
}
compute_sla_verdict

# Shared AWK aggregator. Groups by the combo key (AWK_COMBO_KEY: the six legacy axes,
# the growth key parts and, for growth rows, the series run) and emits one record per
# unique key with min/max/avg for core metrics plus sidecar config-dump aggregates.
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
# Aggregated output (tab-separated, 68 columns: 47 below plus the growth columns 48-68).
# This width is INTENTIONALLY decoupled from the input schema above: the 6 O9
# capacity cols (35-40) are point-in-time
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
#   (48-59) services_per_namespace workload_mode measurement_pods outside_namespaces
#   outside_discovery window_kind (the growth key parts) istiod_services_max
#   cpu_s_avg sidecar_mem_avg gateway_clusters_max gateway_mem_max root_cert_cm_max
# istiod_services (pilot_services, mesh-global: max, never summed, PL28) and cpu_s are
# istiod-sourced and gated like the rest; the sampled sidecars' Envoy memory, the
# gateways' Envoy figures and the root-cert ConfigMap count do not come from istiod's
# scrape, so they are always ingested.
#   (60-61) heap_inuse_cluster_avg istiod_pods_avg: heap_inuse summed over a cluster's
#   istiod pods and the pod count, one value per cluster scrape and only from scrapes
#   whose rows all have istiod_restarted==0 and a heap value (like cluster_proxies_*).
#   A per-proxy-namespace cost lives only on the replica its proxy connects to, so a
#   per-replica average under-counts it by the replica count (the M-sweep uses these).
#   (62-63) status_rows statuses: rows whose context is a 003 status (SKIPPED_MEM_GUARD,
#   GROW_FAILED, ...; a cell that never ran or failed) and their names joined by "+"
#   ("-" when none). They carry istiod_restarted=unknown, so they are also counted in
#   unknown_restarts; reports name them instead of calling them restarts.
#   (64) series_run_id: the RUN_ID of a growth cell's series (combo key part 13); `-`
#   for a legacy cell, whose rows pool across runs.
#   (65-67) gateway_physical_max gateway_ws_max leftover_ns_max: the largest gateway
#   Envoy physical heap and container working set, and the most leftover test
#   namespaces on a member (TSV cols 64-66; N/A before CONTROLPLANE_SCHEMA=66). Not from
#   istiod, so always ingested.
#   (68) cpu_window_avg: istiod CPU-seconds over the window x 1000 / the window, the true
#   average (cpu_delta_* is the larger of that and the busiest 5 s poll); gated like
#   cpu_delta; N/A before CONTROLPLANE_SCHEMA=63 (no CPU-seconds column).
aggregate() {
	awk -F'\t' -v status_re="$STATUS_RE" "${AWK_COMBO_KEY}
${AWK_SERIES_RUN}
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
	# emit_max: the largest valid sample, N/A without one.
	function emit_max(metric, key) {
		if (!((metric, key) in nv) || nv[metric, key] == 0) return "N/A"
		return sprintf("%.0f", max[metric, key] + 0)
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
		# Growth columns read outside istiod: sampled sidecars, gateways, ConfigMaps.
		ingest("sc_mem", colv("sidecar_mem_mi_avg"), key)
		ingest("gw_cl", colv("gateway_clusters_max"), key)
		ingest("gw_mem", colv("gateway_mem_mi_max"), key)
		ingest("rootcm", colv("root_cert_configmaps"), key)
		ingest("gw_phy", colv("gateway_physical_mi_max"), key)
		ingest("gw_ws", colv("gateway_ws_mi_max"), key)
		ingest("leftover", colv("leftover_test_namespaces"), key)
		# Per-cluster proxies: one value per cluster scrape (timestamp|context|combo),
		# ingested in END only if no row of that scrape is restarted/unknown.
		g = $1 SUBSEP $2 SUBSEP key
		cc = col("cluster_connected_proxies")
		if (cc && NF >= cc) {
			if (!(g in gkey)) { gkey[g] = key; gval[g] = $cc }
			if ($31 != "0") gbad[g] = 1
		}
		# Per-cluster heap_inuse sum and istiod pod count (cols 60-61), same gating.
		hkey[g] = key
		if ($31 != "0" || !is_num($34)) hbad[g] = 1
		else { hsum[g] += $34; hpods[g]++ }
		# 003 status rows (a cell skipped or failed; context = the status).
		if ($2 ~ status_re) {
			st_rows[key]++
			if (index("+" st_names[key] "+", "+" $2 "+") == 0) st_names[key] = st_names[key] (st_names[key] == "" ? "" : "+") $2
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
			ingest("isvc",      colv("istiod_services"), key)
			ingest("cpu_s",     colv("istiod_cpu_s_delta"), key)
			# The window-average CPU (millicores): CPU-seconds / window. cpu_delta ($32)
			# is the larger of this and the busiest 5 s poll, i.e. a peak.
			cs = colv("istiod_cpu_s_delta")
			if (is_num(cs) && is_num($28) && $28 + 0 > 0) ingest("cpu_win", cs * 1000 / $28, key)
			n_valid[key]++
		}
	}
	END {
		for (g in gkey) if (!(g in gbad)) ingest("cprx", gval[g], gkey[g])
		for (g in hkey) if (!(g in hbad)) { ingest("hsum", sprintf("%.3f", hsum[g]), hkey[g]); ingest("ipods", hpods[g], hkey[g]) }
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
				if (!decided && a[6] != b[6]) { decided = 1; if (a[6] > b[6]) swap = 1 }
				# Growth key parts 7-13: numeric parts numerically, the rest (the series
				# run last) as strings.
				for (k = 7; !decided && k <= 13; k++) {
					if (a[k] == b[k]) continue
					decided = 1
					if (a[k] ~ /^[0-9.]+$/ && b[k] ~ /^[0-9.]+$/) { if (a[k] + 0 > b[k] + 0) swap = 1 }
					else if (a[k] > b[k]) swap = 1
				}
				if (swap) { t = order[i]; order[i] = order[j]; order[j] = t }
			}
		}
		printf "mesh_size\tservice_count\treplicas\tnamespace_count\tsidecar_scoping\tn_total\tn_valid\tmem_min\tmem_max\tmem_avg\tconv99_min\tconv99_max\tconv99_avg\tqueue99_min\tqueue99_max\tqueue99_avg\tproxies_min\tproxies_max\tproxies_avg\trestarts\tunknown_restarts\tcpu_delta_min\tcpu_delta_max\tcpu_delta_avg\tcfg_dump_avg\tcfg_dump_max\tconv99_floor_pinned\tqueue99_floor_pinned\theap_alloc_min\theap_alloc_max\theap_alloc_avg\theap_inuse_min\theap_inuse_max\theap_inuse_avg\tcluster_proxies_min\tcluster_proxies_max\tcluster_proxies_avg\ttraffic_config\tvsdr_services\tvirt_services_avg\tpush_time_avg\tpushctx_init_avg\tpushes_avg\tcfg_size_avg\tclusters_avg\tcds_bytes_avg\trds_bytes_avg\tservices_per_namespace\tworkload_mode\tmeasurement_pods\toutside_namespaces\toutside_discovery\twindow_kind\tistiod_services_max\tcpu_s_avg\tsidecar_mem_avg\tgateway_clusters_max\tgateway_mem_max\troot_cert_cm_max\theap_inuse_cluster_avg\tistiod_pods_avg\tstatus_rows\tstatuses\tseries_run_id\tgateway_physical_max\tgateway_ws_max\tleftover_ns_max\tcpu_window_avg\n"
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
			# INTERPOLATES within the matched bucket (FINDING #5), the old
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
			printf "%s\t%s\t%s\t%s\t%s\t%d\t%d\t%s\t%s\t%s\t%s\t%d\t%d\t%s\t%s\t%s\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n",
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
				emit_avg("rds", k, "%.0f"),
				p[7], p[8], p[9], p[10], p[11], p[12],
				emit_max("isvc", k),
				emit_avg("cpu_s", k, "%.2f"),
				emit_avg("sc_mem", k, "%.0f"),
				emit_max("gw_cl", k),
				emit_max("gw_mem", k),
				emit_max("rootcm", k),
				emit_avg("hsum", k, "%.1f"),
				emit_avg("ipods", k, "count"),
				st_rows[k] + 0, (st_names[k] == "" ? "-" : st_names[k]), p[13],
				emit_max("gw_phy", k),
				emit_max("gw_ws", k),
				emit_max("leftover", k),
				emit_avg("cpu_win", k, "%.0f")
		}
	}' "${TSV_FILES[@]}"
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
	# Legacy-layout cells only (growth cells have no VS/DR): deploy, or traffic (a split
	# VS/DR apply, keyed apart so a split none cell never pairs with a deploy vsdr cell).
	$48 + 0 > 0 || ($53 != "deploy" && $53 != "traffic") { next }
	{
		base = $1 "|" $2 "|" $3 "|" $4 "|" $5 ($53 == "traffic" ? "|traffic" : "")
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

# ---------------------------------------------------------------------------
# Namespace scaling (growth cells: services_per_namespace > 0).
# ---------------------------------------------------------------------------
# CONV_FIT_MIN_PUSHES, CONV_FIT_RULE, GROW_FIT_RULE and SERIES_FIT_RULE are set at the
# top (--help prints the floor).

# has_growth_cells <aggregated>: 0 when the report has a growth cell.
has_growth_cells() {
	awk -F'\t' 'NR > 1 && $48 + 0 > 0 { f = 1 } END { exit !f }' <<<"$1"
}

# growth_run_count <aggregated>: the number of series runs (col 64) among growth cells.
# Above 1, series labels and the per-cell table name the run of each cell.
growth_run_count() {
	awk -F'\t' 'NR > 1 && $48 + 0 > 0 && !($64 in s) { s[$64] = 1; n++ } END { print n + 0 }' <<<"$1"
}

# scaling_records <aggregated>: the namespace-scaling section as tab-separated
# records, rendered by scaling_render in every format (PL19):
#   SKIP series n window scoping m outside statuses rows run   (cells not measured)
#   FIT  series scoping window metric unit per_100ns intercept r2 n exponent points run
#   PODS label metric config_only pods ratio config_only_run pods_run
#        | PODSNOTE message | PODSMISSING message
#   MSWEEP label m heap heap_cluster istiod_pods cpu_s pushes cfg_kib envoy_mi heap_per_pod run
#          | MSWEEPMISSING message
#   DISC label discovery x istiod_services delta expected heap cfg_kib root_cms gw_clusters check run
#   FIDELITY label metric fresh in_place diff_pct fresh_run in_place_run
# Series (SERIES_FIT_RULE): a growth cell belongs to one series run (aggregated col 64,
# the RUN_ID; a series is RUN_ID x mesh size x K x workload), and every grow ladder,
# N_prev, curve, M-sweep and discovery row is keyed by it, so a base-dir report over
# several sweeps never mixes their points. With more than one series run every label
# carries run=<RUN_ID>. Only the pods-vs-config-only and fresh-vs-in-place pairings
# compare cells of different runs (by design: each side comes from its own sweep); each
# such row names the run of each side, and where several runs have a candidate cell the
# latest RUN_ID wins (RUN_IDs start with a UTC timestamp).
# Only cells with n_valid > 0 count (PL35; a SKIPPED_MEM_GUARD, failed or restarted
# cell has n_valid 0). Fits use outside_namespaces 0 and, per N, the cell with the
# fewest measurement pods (the M-sweep cells are compared in their own table). Per
# 100 namespaces = 100 x the least-squares slope against N; the log-log exponent
# separates linear (1) from quadratic (2) growth.
# Window deltas (istiod_cpu_s, xds_pushes, pushes_per_proxy, push_kib) of a grow window
# cover the N - N_prev namespaces it added, so grow windows fit them per namespace added
# (onboard_*), never raw. N_prev is the previous grow step of the curve whatever its
# n_valid: a skipped or failed grow stops the series, so a later valid grow means every
# earlier one was applied. The first grow window (N_prev = 0) stays out of every grow
# fit of a window measurement (WINM: the onboard_* deltas, push time, PushContext init,
# convergence p99; GROW_FIT_RULE says why); its gauges are fitted. conv_p99_ms skips
# windows with fewer than CONV_FIT_MIN_PUSHES xDS pushes across types (CONV_FIT_RULE).
# pushes_per_proxy = pushes per istiod replica (col 43) / proxies per replica (col 19);
# col 37 sums a cluster's replicas, so dividing by it under-counts by the replica count.
scaling_records() {
	local multi_run=0
	(($(growth_run_count "$1") > 1)) && multi_run=1
	awk -F'\t' -v conv_min="$CONV_FIT_MIN_PUSHES" -v multi_run="$multi_run" "${FIT_AWK}"'
	function isnum(s) { return fit_isnum(s) }
	# rtag(r): " run=<RUN_ID>" of cell r when the report has more than one series run.
	function rtag(r) { return multi_run ? " run=" C[r, 64] : "" }
	# later(a, b): cell a is from a later run than cell b (the pairing tie-break; a file
	# without a RUN_ID, unknown-<n>, counts as the earliest).
	function later(a, b,    x, y) {
		x = C[a, 64] ""; y = C[b, 64] ""
		if ((x ~ /^unknown-/) != (y ~ /^unknown-/)) return (y ~ /^unknown-/)
		return x > y
	}
	# Round float noise (1e-16, -0.00) to a plain 0 before formatting.
	function z(v) { return (v + 0 < 1e-9 && v + 0 > -1e-9) ? 0 : v }
	# g: 4 significant digits, never an exponent (16030, not 1.603e+04): values of
	# 1000 or more print as whole numbers.
	function g(v,    a) {
		if (!isnum(v)) return "N/A"
		v = z(v); a = (v < 0) ? -v : v
		if (a >= 1000) return sprintf("%.0f", v)
		if (a >= 100) return sprintf("%.1f", v) + 0
		return sprintf("%.4g", v) + 0
	}
	function f2(v,    s) { s = sprintf("%.2f", z(v)); return (s == "-0.00") ? "0.00" : s }
	function mval(name, r) {
		if (name == "heap_inuse_mi") return C[r, 34]
		if (name == "heap_inuse_cluster_mi") return C[r, 60]
		if (name == "istiod_pods") return C[r, 61]
		if (name == "rss_mi") return C[r, 10]
		if (name == "istiod_services") return C[r, 54]
		if (name == "istiod_cpu_s") return C[r, 55]
		if (name == "proxy_config_kib") return isnum(C[r, 25]) ? C[r, 25] / 1024 : "N/A"
		if (name == "proxy_envoy_mem_mi") return C[r, 56]
		if (name == "gateway_clusters") return C[r, 57]
		if (name == "gateway_mem_mi") return C[r, 58]
		if (name == "gateway_physical_mi") return C[r, 65]
		if (name == "gateway_ws_mi") return C[r, 66]
		if (name == "xds_pushes") return C[r, 43]
		if (name == "pushes_per_proxy") return (isnum(C[r, 43]) && isnum(C[r, 19]) && C[r, 19] > 0) ? C[r, 43] / C[r, 19] : "N/A"
		if (name == "push_kib") return (isnum(C[r, 43]) && isnum(C[r, 44])) ? C[r, 43] * C[r, 44] / 1024 : "N/A"
		if (name == "push_time_ms") return C[r, 41]
		if (name == "pushcontext_init_ms") return C[r, 42]
		if (name == "conv_p99_ms") return C[r, 12]
		if (name == "root_cert_cms") return C[r, 59]
		return "N/A"
	}
	function sortnum(arr, n,    i, j, t) {
		for (i = 2; i <= n; i++) { t = arr[i]; j = i - 1; while (j >= 1 && arr[j] + 0 > t + 0) { arr[j + 1] = arr[j]; j-- }; arr[j + 1] = t }
	}
	# gprev(r): the N of the grow step before grow cell r in its series (0 for the first),
	# from every grow cell of that series run, valid or not (see above).
	function gprev(r,    gk, n, i, k, a, best) {
		gk = C[r, 1] SUBSEP C[r, 48] SUBSEP C[r, 49] SUBSEP C[r, 5] SUBSEP C[r, 64]
		n = C[r, 4] + 0; best = 0
		k = split(substr(gall[gk], 2), a, " ")
		for (i = 1; i <= k; i++) if (a[i] + 0 < n && a[i] + 0 > best) best = a[i] + 0
		return best
	}
	BEGIN {
		nm = split("heap_inuse_mi rss_mi istiod_services istiod_cpu_s proxy_config_kib proxy_envoy_mem_mi gateway_clusters gateway_mem_mi gateway_physical_mi gateway_ws_mi xds_pushes pushes_per_proxy push_kib push_time_ms pushcontext_init_ms conv_p99_ms root_cert_cms", M, " ")
		split("Mi Mi services CPU-s KiB Mi clusters Mi Mi Mi pushes pushes/proxy KiB ms ms ms ConfigMaps", U, " ")
		for (i = 1; i <= nm; i++) UNIT[M[i]] = U[i]
		# Window deltas and their per-namespace-added forms for grow windows.
		nob = split("istiod_cpu_s xds_pushes pushes_per_proxy push_kib", D, " ")
		split("onboard_cpu_s_per_ns onboard_pushes_per_ns onboard_pushes_per_proxy_per_ns onboard_push_kib_per_ns", OB, " ")
		for (i = 1; i <= nob; i++) { DELTA[D[i]] = 1; M[nm + i] = OB[i]; OBASE[OB[i]] = D[i]; UNIT[OB[i]] = UNIT[D[i]] "/ns"; WINM[OB[i]] = 1 }
		# Window measurements besides the deltas: per-push averages and the window p99.
		WINM["push_time_ms"] = 1; WINM["pushcontext_init_ms"] = 1; WINM["conv_p99_ms"] = 1
	}
	NR == 1 { next }
	$48 + 0 <= 0 { next }
	{ nr++; for (c = 1; c <= NF; c++) C[nr, c] = $c }
	END {
		# --- cells not measured (003 status rows) ----------------------------
		for (r = 1; r <= nr; r++) {
			if (C[r, 62] + 0 <= 0) continue
			printf "SKIP\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n", "mesh=" C[r, 1] " K=" C[r, 48] " " C[r, 49] rtag(r), C[r, 4], C[r, 53], C[r, 5], C[r, 50], \
				(C[r, 51] + 0 > 0 ? C[r, 51] "/" C[r, 52] : "-"), C[r, 63], C[r, 62], C[r, 64]
		}
		# Every grow step of a series, valid or not (gprev).
		for (r = 1; r <= nr; r++) {
			if (C[r, 53] != "grow" || C[r, 51] + 0 != 0) continue
			gk = C[r, 1] SUBSEP C[r, 48] SUBSEP C[r, 49] SUBSEP C[r, 5] SUBSEP C[r, 64]
			if (!((gk, C[r, 4] + 0) in gseen)) { gseen[gk, C[r, 4] + 0] = 1; gall[gk] = gall[gk] " " (C[r, 4] + 0) }
		}
		# --- fits: one curve per series run x scoping x window ------------------
		for (r = 1; r <= nr; r++) {
			if (C[r, 7] + 0 <= 0 || C[r, 51] + 0 != 0) continue
			ck = C[r, 1] SUBSEP C[r, 48] SUBSEP C[r, 49] SUBSEP C[r, 5] SUBSEP C[r, 53] SUBSEP C[r, 64]
			n = C[r, 4] + 0
			if (!(ck in cseen)) { cseen[ck] = 1; curves[++ncurves] = ck }
			if (!((ck, n) in pick)) { nlist[ck] = nlist[ck] " " n; pick[ck, n] = r }
			else if (C[r, 50] + 0 < C[pick[ck, n], 50] + 0) pick[ck, n] = r
		}
		for (ci = 1; ci <= ncurves; ci++) {
			ck = curves[ci]
			split(ck, kp, SUBSEP)
			label = "mesh=" kp[1] " K=" kp[2] " " kp[3] (multi_run ? " run=" kp[6] : "")
			kn = split(substr(nlist[ck], 2), ns, " ")
			# One N is no curve (a fresh calibration cell is compared in the pairing tables).
			if (kn < 2) continue
			sortnum(ns, kn)
			for (mi = 1; mi <= nm + nob; mi++) {
				mname = M[mi]
				ob = (mname in OBASE)
				if (ob && kp[5] != "grow") continue
				if (!ob && kp[5] == "grow" && (mname in DELTA)) continue
				k = 0; pts = ""
				split("", xs); split("", ys)
				for (i = 1; i <= kn; i++) {
					r = pick[ck, ns[i]]
					if (mname == "conv_p99_ms" && !(isnum(C[r, 43]) && C[r, 43] + 0 >= conv_min)) continue
					# A p99 pinned in the first bucket (0-100 ms) is an interpolation, not a
					# measurement (the cell tables print it as 0-100 †); keep it out of fits.
					if (mname == "conv_p99_ms" && C[r, 27] + 0 == 1) continue
					if (kp[5] == "grow" && (mname in WINM) && gprev(r) == 0) continue
					if (ob) {
						step = ns[i] - gprev(r)
						v = mval(OBASE[mname], r)
						v = (isnum(v) && step > 0) ? v / step : "N/A"
					} else v = mval(mname, r)
					if (!isnum(v)) continue
					k++; xs[k] = ns[i]; ys[k] = v
					pts = pts (pts == "" ? "" : " ") ns[i] ":" g(v)
				}
				if (k == 0) continue
				fit_exp(xs, ys, k); e = FIT_EXP
				fit_lin(xs, ys, k)
				# Two points fit any line exactly: R² is 1 by construction, so it is N/A
				# below 3 points (the exponent of 2 points is still the slope between them).
				printf "FIT\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\n", label, kp[4], kp[5], mname, UNIT[mname], \
					(FIT_SLOPE == "N/A" ? "N/A" : g(FIT_SLOPE * 100)), \
					(FIT_ICPT == "N/A" ? "N/A" : g(FIT_ICPT)), \
					((FIT_R2 == "N/A" || FIT_N < 3) ? "N/A" : sprintf("%.3f", FIT_R2)), FIT_N, \
					(e == "N/A" ? "N/A" : f2(e)), pts, kp[6]
			}
		}
		# --- pods vs config-only (always reported) ----------------------------
		# Same mesh, K, N and scoping, preferring a pair of one window kind. Window deltas
		# compare only within one kind (and, for grow, the same step); the gauges always.
		# The two sides usually come from different sweeps (the calibration runs one per
		# workload), so this pairing crosses series runs; per side and kind it takes the
		# cell with the fewest measurement pods, then the latest run.
		nconf = 0; npods = 0
		for (r = 1; r <= nr; r++) {
			if (C[r, 7] + 0 <= 0 || C[r, 51] + 0 != 0) continue
			w = C[r, 49]
			if (w == "config-only") nconf++; else npods++
			pk = C[r, 1] SUBSEP C[r, 48] SUBSEP C[r, 4] SUBSEP C[r, 5]
			if (!(pk in pkseen)) { pkseen[pk] = 1; pkeys[++npk] = pk }
			if (!((pk, w, C[r, 53]) in pc)) { pc[pk, w, C[r, 53]] = r; continue }
			o = pc[pk, w, C[r, 53]]
			if (C[r, 50] + 0 < C[o, 50] + 0 || (C[r, 50] + 0 == C[o, 50] + 0 && later(r, o))) pc[pk, w, C[r, 53]] = r
		}
		split("probe deploy grow", KINDS, " ")
		split("heap_inuse_mi istiod_cpu_s xds_pushes pushes_per_proxy proxy_config_kib proxy_envoy_mem_mi istiod_services", PM, " ")
		npaired = 0; nxkind = 0
		for (i = 1; i <= npk; i++) {
			pk = pkeys[i]; rc = ""; rp = ""
			for (j = 1; j <= 3 && rc == ""; j++)
				if (((pk, "config-only", KINDS[j]) in pc) && ((pk, "pods", KINDS[j]) in pc)) { rc = pc[pk, "config-only", KINDS[j]]; rp = pc[pk, "pods", KINDS[j]] }
			for (j = 1; j <= 3 && rc == ""; j++) if ((pk, "config-only", KINDS[j]) in pc) rc = pc[pk, "config-only", KINDS[j]]
			for (j = 1; j <= 3 && rp == ""; j++) if ((pk, "pods", KINDS[j]) in pc) rp = pc[pk, "pods", KINDS[j]]
			if (rc == "" || rp == "") continue
			npaired++
			same = (C[rc, 53] == C[rp, 53]) && (C[rc, 53] != "grow" || gprev(rc) == gprev(rp))
			if (!same) nxkind++
			split(pk, kp, SUBSEP)
			# A report of several series runs names the run of each side in the label (PL2/PL26);
			# the records always carry them (the JSON rows list them).
			rnc = C[rc, 64]; rnp = C[rp, 64]
			label = "mesh=" kp[1] " K=" kp[2] " N=" kp[3] " " kp[4] " (config-only " C[rc, 53] (multi_run ? " run=" rnc : "") ", pods " C[rp, 53] (multi_run ? " run=" rnp : "") ")"
			for (j = 1; j <= 7; j++) {
				if (!same && (PM[j] in DELTA)) { printf "PODS\t%s\t%s\tN/A\tN/A\tN/A\t%s\t%s\n", label, PM[j], rnc, rnp; continue }
				a = mval(PM[j], rc); b = mval(PM[j], rp)
				printf "PODS\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", label, PM[j], g(a), g(b), ((isnum(a) && isnum(b) && a + 0 != 0) ? sprintf("%.2f", b / a) : "N/A"), rnc, rnp
			}
		}
		if (nxkind > 0) printf "PODSNOTE\t%s\n", "istiod_cpu_s, xds_pushes and pushes_per_proxy are N/A where the pair has different window kinds or grow steps (a probe onboards one namespace, a deploy deploys all N); only the gauges compare. For a full row run --growth fresh once config-only and once with --workload-mode pods at the same N, K and scoping (configs/ns-scaling-lab.env shows the commands)."
		if (npaired == 0) {
			if (nconf > 0 && npods == 0) msg = "not measured: every valid growth cell is config-only. Run the calibration: --growth fresh at one small N, K and scoping (with --outside-modes none), once config-only and once with --workload-mode pods, into the same results base, then report that base dir with --allow-multi-run rather than one sweep-<RUN_ID> (configs/ns-scaling-lab.env shows the commands). Config-only leaves out endpoint (EDS) churn and pushes to a proxy in every namespace, so its per-namespace costs are a lower bound until this row is filled."
			else if (npods > 0 && nconf == 0) msg = "not measured: every valid growth cell runs pods. Add a --growth fresh config-only sweep at the same N, K and scoping into the same results base and report that base dir with --allow-multi-run."
			else if (npods > 0 && nconf > 0) msg = "not measured: the pods and config-only cells share no mesh, K, N and scoping. Run both with --growth fresh at the same N, K and scoping (configs/ns-scaling-lab.env shows the commands)."
			else msg = "not measured: no growth cell has a valid sample."
			printf "PODSMISSING\t%s\n", msg
		}
		# --- measurement-pod sweep --------------------------------------------
		# heap per added pod = the change in heap_inuse summed over the istiod replicas of
		# a cluster (col 60) per added measurement pod: a lazily built SidecarScope lives on
		# the one replica its proxy connects to, so a per-replica average reads cost / R.
		# N/A when the istiod pod count changed between the cells.
		# Within one series run (the M-sweep re-probes that series at its largest N).
		for (r = 1; r <= nr; r++) {
			if (C[r, 7] + 0 <= 0 || C[r, 49] != "config-only" || C[r, 53] != "probe") continue
			mk = C[r, 1] SUBSEP C[r, 48] SUBSEP C[r, 4] SUBSEP C[r, 5] SUBSEP C[r, 51] SUBSEP C[r, 52] SUBSEP C[r, 64]
			m = C[r, 50] + 0
			if (!(mk in mkseen)) { mkseen[mk] = 1; mkeys[++nmk] = mk }
			if (!((mk, m) in mcell)) { mcell[mk, m] = r; mlist[mk] = mlist[mk] " " m; mcount[mk]++ }
		}
		nms = 0
		for (i = 1; i <= nmk; i++) {
			mk = mkeys[i]
			if (mcount[mk] < 2) continue
			nms++
			split(mk, kp, SUBSEP)
			label = "mesh=" kp[1] " K=" kp[2] " N=" kp[3] " " kp[4] " outside=" kp[5] "/" kp[6] (multi_run ? " run=" kp[7] : "")
			km = split(substr(mlist[mk], 2), ms, " ")
			sortnum(ms, km)
			r0 = mcell[mk, ms[1]]; h0 = mval("heap_inuse_cluster_mi", r0); p0 = mval("istiod_pods", r0)
			for (j = 1; j <= km; j++) {
				r = mcell[mk, ms[j]]; h = mval("heap_inuse_cluster_mi", r); p = mval("istiod_pods", r)
				if (j == 1) dh = "-"
				else if (isnum(h) && isnum(h0) && isnum(p) && isnum(p0) && p + 0 == p0 + 0) dh = sprintf("%.3g", z((h - h0) / (ms[j] - ms[1])))
				else dh = "N/A"
				printf "MSWEEP\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", label, ms[j], g(mval("heap_inuse_mi", r)), g(h), g(p), \
					g(mval("istiod_cpu_s", r)), g(mval("xds_pushes", r)), g(mval("proxy_config_kib", r)), g(mval("proxy_envoy_mem_mi", r)), dh, kp[7]
			}
		}
		if (nms == 0) printf "MSWEEPMISSING\t%s\n", "not swept: run config-only in place with --measurement-pod-counts 4,16 to see whether istiod heap grows with the number of proxied namespaces. If it does, that per-proxy-namespace cost has to be extrapolated to the customer'"'"'s namespaces with proxies."
		# --- discovery pairing (outside namespaces), within one series run --------
		for (r = 1; r <= nr; r++) {
			if (C[r, 7] + 0 <= 0 || C[r, 53] != "probe") continue
			dk = C[r, 1] SUBSEP C[r, 48] SUBSEP C[r, 49] SUBSEP C[r, 4] SUBSEP C[r, 5] SUBSEP C[r, 50] SUBSEP C[r, 64]
			d = (C[r, 51] + 0 == 0) ? "none" : C[r, 52]
			if (!(dk in dkseen)) { dkseen[dk] = 1; dkeys[++ndk] = dk }
			dcell[dk, d] = r
			if (d != "none") dhas[dk] = 1
		}
		split("none unlabeled labeled", DS, " ")
		for (i = 1; i <= ndk; i++) {
			dk = dkeys[i]
			# Needs outside cells and the baseline without them (M-sweep cells have no
			# baseline at their measurement-pod count; their own table covers them).
			if (!(dk in dhas) || !((dk, "none") in dcell)) continue
			split(dk, kp, SUBSEP)
			label = "mesh=" kp[1] " K=" kp[2] " " kp[3] " N=" kp[4] " " kp[5] (multi_run ? " run=" kp[7] : "")
			rb = ((dk, "none") in dcell) ? dcell[dk, "none"] : ""
			sb = (rb != "") ? C[rb, 54] : "N/A"
			for (j = 1; j <= 3; j++) {
				if (!((dk, DS[j]) in dcell)) continue
				r = dcell[dk, DS[j]]; x = C[r, 51] + 0; s = C[r, 54]
				exp_d = (DS[j] == "labeled") ? x * kp[2] : 0
				if (DS[j] == "none") { delta = "-"; expect = "-"; check = "-" }
				else if (!isnum(s) || !isnum(sb)) { delta = "N/A"; expect = exp_d; check = "no baseline" }
				else {
					delta = s - sb; expect = exp_d
					if (DS[j] == "labeled") check = (delta >= 0.9 * exp_d) ? "OK" : "SHORT"
					else { tol = 0.1 * x * kp[2]; if (tol < 2) tol = 2; check = (delta <= tol) ? "OK" : "EXTRA" }
				}
				printf "DISC\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", label, DS[j], x, g(s), delta, expect, \
					g(mval("heap_inuse_mi", r)), g(mval("proxy_config_kib", r)), g(mval("root_cert_cms", r)), g(mval("gateway_clusters", r)), check, kp[7]
			}
		}
		# --- fresh vs in-place (PL34) -----------------------------------------
		# A fresh (deploy) cell comes from a --growth fresh sweep and an in-place probe from
		# an in-place sweep, so this pairing crosses series runs by design; per kind it
		# takes the latest run.
		for (r = 1; r <= nr; r++) {
			if (C[r, 7] + 0 <= 0 || C[r, 51] + 0 != 0 || (C[r, 53] != "deploy" && C[r, 53] != "probe")) continue
			fk = C[r, 1] SUBSEP C[r, 48] SUBSEP C[r, 49] SUBSEP C[r, 4] SUBSEP C[r, 5] SUBSEP C[r, 50]
			if (!(fk in fkseen)) { fkseen[fk] = 1; fkeys[++nfk] = fk }
			if (!((fk, C[r, 53]) in fcell) || later(r, fcell[fk, C[r, 53]])) fcell[fk, C[r, 53]] = r
		}
		for (i = 1; i <= nfk; i++) {
			fk = fkeys[i]
			if (!((fk, "deploy") in fcell) || !((fk, "probe") in fcell)) continue
			split(fk, kp, SUBSEP)
			rf = fcell[fk, "deploy"]; ri = fcell[fk, "probe"]
			label = "mesh=" kp[1] " K=" kp[2] " " kp[3] " N=" kp[4] " " kp[5] " M=" kp[6] (multi_run ? " (fresh run=" C[rf, 64] ", in-place run=" C[ri, 64] ")" : "")
			split("istiod_services proxy_config_kib heap_inuse_mi", FM, " ")
			for (j = 1; j <= 3; j++) {
				a = mval(FM[j], rf); b = mval(FM[j], ri)
				printf "FIDELITY\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", label, FM[j], g(a), g(b), ((isnum(a) && isnum(b) && a + 0 != 0) ? sprintf("%+.1f%%", 100 * (b - a) / a) : "N/A"), C[rf, 64], C[ri, 64]
			}
		}
	}' <<<"$1"
}

# not_measured_note: what the "Cells not measured" statuses mean (markdown and text).
not_measured_note() {
	echo "These are 003 status rows, not istiod restarts: they carry no metrics and count in \`n_total\` and \`unk_restarts\` only because they have no restart state. \`SKIPPED_MEM_GUARD\`: the memory guard projected istiod heap or a gateway's memory above \`CONTROLPLANE_MEM_STOP_PCT\` of its limit, so the step never ran (a skipped grow ends the series); every guard decision is a row of the sweep dir's \`mem-guard-<RUN_ID>.tsv\`. \`SKIPPED_SERIES_STOPPED\`: an earlier grow failed or was skipped. \`GROW_FAILED\`, \`SWITCH_FAILED\`, \`SETUP_FAILED\`: the 001 apply failed (see \`ns-lifecycle-<RUN_ID>.tsv\` and the sweep log). \`PROBE_FAILED\`: a baseline or final scrape failed."
}

# msweep_note: how to read the M-sweep table, with the istiod replica count (markdown and text).
msweep_note() {
	echo "istiod replicas: $(istiod_replicas_label). Heap per added pod is the change in heap_inuse summed over a cluster's istiod replicas per added measurement pod (N/A when the istiod pod count changed): a namespace's SidecarScope is built on the replica its proxy connects to, so a per-replica average would read cost / replicas. With a proxy in every namespace, every replica serving one of them holds that scope: extrapolate per replica as N x this cost. Heap that grows with the measurement pods is a cost per namespace with proxies, which config-only undercounts for a mesh with a proxy in every namespace."
}

# scaling_render <format> <records>: the namespace-scaling section in one format.
scaling_render() {
	local fmt="$1" records="$2"
	case "$fmt" in
	markdown)
		cat <<'NSS_HDR'

## Namespace scaling

Growth cells only (`--services-per-namespaces K`). `grow` windows add namespaces to a
series (always under `namespace` scoping); `probe` windows onboard one extra namespace
(K Services, its Sidecar, no pods) under each scoping at a fixed N; `deploy` cells are
`--growth fresh`. `per 100 ns` is 100 x the least-squares slope against the namespace
count N, `log-log exp.` the slope of ln(value) on ln(N) (1 = linear, 2 = quadratic).
Only cells with `n_valid > 0` count; cells that never ran or failed are listed under
"Cells not measured". Probe windows measure the cost of one more namespace at N. A grow
window adds N - N_prev namespaces, so its window deltas are fitted per namespace added
(`onboard_*_per_ns`, N_prev = the previous grow step of the same series), never raw; its
gauges are fitted as they are. Each series (one sweep's RUN_ID x mesh size x K x
workload) is fitted on its own; a report of several sweeps labels them `run=<RUN_ID>`.
The fit rules follow the table.
NSS_HDR
		if grep -q '^SKIP' <<<"$records"; then
			echo ""
			echo "### Cells not measured"
			echo ""
			echo "| series | N | window | scoping | M | outside | status | rows |"
			echo "|--------|---|--------|---------|---|---------|--------|------|"
			awk -F'\t' '$1 == "SKIP" { s = $8; gsub(/\+/, ", ", s); printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n", $2, $3, $4, $5, $6, $7, s, $9 }' <<<"$records"
			echo ""
			echo "> $(not_measured_note)"
		fi
		cat <<'NSS_FIT'

### Fits against namespace count

| series | scoping | window | metric | unit | per 100 ns | intercept | R² | n | log-log exp. | points (N: value) |
|--------|---------|--------|--------|------|------------|-----------|----|---|--------------|-------------------|
NSS_FIT
		awk -F'\t' '$1 == "FIT" { f = 1; printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12 }
			END { if (!f) print "| (no fit: every series has fewer than two namespace counts with a valid cell) | | | | | | | | | | |" }' <<<"$records"
		echo ""
		echo "> ${CONV_FIT_RULE}"
		echo ">"
		echo "> ${GROW_FIT_RULE}"
		echo ">"
		echo "> ${SERIES_FIT_RULE}"
		echo ""
		echo "### Pods vs config-only (required)"
		echo ""
		echo "Config-only cells run Services without pods plus a few measurement pods; this row bounds what that leaves out."
		echo ""
		if grep -q '^PODSMISSING' <<<"$records"; then
			awk -F'\t' '$1 == "PODSMISSING" { printf "> **Not measured:** %s\n", $2 }' <<<"$records"
		else
			echo "| cell | metric | config-only | pods | pods / config-only |"
			echo "|------|--------|-------------|------|--------------------|"
			awk -F'\t' '$1 == "PODS" { printf "| %s | %s | %s | %s | %s |\n", $2, $3, $4, $5, $6 }' <<<"$records"
			awk -F'\t' '$1 == "PODSNOTE" { printf "\n> **Note:** %s\n", $2 }' <<<"$records"
		fi
		echo ""
		echo "### Measurement-pod sweep"
		echo ""
		if grep -q '^MSWEEPMISSING' <<<"$records"; then
			awk -F'\t' '$1 == "MSWEEPMISSING" { printf "> %s\n", $2 }' <<<"$records"
		else
			echo "| cell | measurement pods | heap inuse / replica (Mi) | heap inuse / cluster (Mi) | istiod pods / cluster | istiod CPU-s | xDS pushes | proxy config (KiB) | proxy Envoy (Mi) | heap per added pod (Mi) |"
			echo "|------|------------------|---------------------------|---------------------------|-----------------------|--------------|------------|-------------------|------------------|-------------------------|"
			awk -F'\t' '$1 == "MSWEEP" { printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $2, $3, $4, $5, $6, $7, $8, $9, $10, $11 }' <<<"$records"
			echo ""
			echo "> $(msweep_note)"
		fi
		if grep -q '^DISC' <<<"$records"; then
			echo ""
			echo "### Discovery (namespaces outside the mesh)"
			echo ""
			echo "Probe cells at the same N and scoping without outside namespaces (none), with X unlabeled ones and with the same X labeled \`istio-discovery=enabled\`. Expected: labeled adds X x K Services to istiod, unlabeled adds none (PL31: checked against what istiod reports)."
			echo ""
			echo "| cell | outside | X | istiod services | Δ vs none | expected Δ | heap inuse (Mi) | proxy config (KiB) | root-cert CMs | gateway clusters | check |"
			echo "|------|---------|---|-----------------|-----------|------------|-----------------|-------------------|---------------|------------------|-------|"
			awk -F'\t' '$1 == "DISC" { printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12 }' <<<"$records"
		fi
		if grep -q '^FIDELITY' <<<"$records"; then
			echo ""
			echo "### Fresh vs in-place (PL34)"
			echo ""
			echo "The same N, scoping and measurement pods deployed fresh (\`deploy\`) and reached by growing in place (\`probe\`). A large gap means in-place growth is not fidelity-neutral."
			echo ""
			echo "| cell | metric | fresh (deploy) | in-place (probe) | difference |"
			echo "|------|--------|----------------|------------------|------------|"
			awk -F'\t' '$1 == "FIDELITY" { printf "| %s | %s | %s | %s | %s |\n", $2, $3, $4, $5, $6 }' <<<"$records"
		fi
		cat <<'NSS_GLOSSARY'

Growth columns: `istiod_services` = `pilot_services` (max over replicas, never summed);
`istiod_cpu_s` = Δ`process_cpu_seconds_total` over the window; `proxy_config_kib` and
`proxy_envoy_mem_mi` = the sampled measurement pods' `/config_dump` size (KiB) and Envoy
`server.memory_allocated`; `gateway_*` = the largest ingress/east-west gateway's Envoy
`cluster_manager.active_clusters` and `server.memory_allocated` (`gateway_mem_mi`),
`server.memory_physical_size` (`gateway_physical_mi`: the tcmalloc heap with the freed
pages it kept) and the istio-proxy container working set from `kubectl top`
(`gateway_ws_mi`, what the OOM killer acts on; it ran 1.2-2.9x the allocated figure after
config bursts) (gateways keep `*/*`, so scoping does not shrink them, PL38);
`root_cert_cms` = `istio-ca-root-cert` ConfigMaps (one per namespace istiod serves);
`push_kib` = pushes x average push size; `pushes_per_proxy` = pushes per istiod replica
/ proxies connected to that replica; `onboard_*_per_ns` = a grow window's delta / the
namespaces it added. R² is N/A below 3 points (2 points fit exactly); `conv_p99_ms`
points are interpolated within istiod's histogram buckets, so they are only as precise
as the bucket. Sizing a gateway from these fits: use `gateway_ws_mi` (or
`gateway_mem_mi` times a burst factor of 2-3 for the east-west gateway) against its
memory limit.
NSS_GLOSSARY
		;;
	text)
		echo "--- Namespace scaling (growth cells; per 100 ns = 100 x slope against namespace count; exp = log-log exponent) ---"
		if grep -q '^SKIP' <<<"$records"; then
			echo "  Cells not measured:"
			awk -F'\t' '$1 == "SKIP" { printf "    %s N=%s window=%s scoping=%s M=%s outside=%s status=%s rows=%s\n", $2, $3, $4, $5, $6, $7, $8, $9 }' <<<"$records"
			echo "    $(not_measured_note)" | tr -d '`'
		fi
		awk -F'\t' '$1 == "FIT" { f = 1; printf "  %s scoping=%s window=%s %s (%s): per_100ns=%s intercept=%s r2=%s n=%s exp=%s  points: %s\n", $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12 }
			END { if (!f) print "  (no fit: every series has fewer than two namespace counts with a valid cell)" }' <<<"$records"
		echo "  Fit rules: ${CONV_FIT_RULE}"
		echo "  ${GROW_FIT_RULE}"
		echo "  ${SERIES_FIT_RULE}"
		echo "  Pods vs config-only (required):"
		awk -F'\t' '$1 == "PODSMISSING" { printf "    NOT MEASURED: %s\n", $2 } $1 == "PODS" { printf "    %s %s: config-only=%s pods=%s ratio=%s\n", $2, $3, $4, $5, $6 } $1 == "PODSNOTE" { printf "    NOTE: %s\n", $2 }' <<<"$records"
		echo "  Measurement-pod sweep:"
		awk -F'\t' '$1 == "MSWEEPMISSING" { printf "    %s\n", $2 } $1 == "MSWEEP" { printf "    %s M=%s heap_inuse=%s heap_inuse_cluster=%s istiod_pods_per_cluster=%s cpu_s=%s pushes=%s proxy_config_kib=%s proxy_envoy_mi=%s heap_per_added_pod=%s\n", $2, $3, $4, $5, $6, $7, $8, $9, $10, $11 }' <<<"$records"
		if grep -q $'^MSWEEP\t' <<<"$records"; then echo "    $(msweep_note)"; fi
		awk -F'\t' '$1 == "DISC" { if (!h++) print "  Discovery (outside namespaces):"; printf "    %s outside=%s X=%s istiod_services=%s delta=%s expected=%s heap_inuse=%s proxy_config_kib=%s root_cert_cms=%s gateway_clusters=%s check=%s\n", $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12 }' <<<"$records"
		awk -F'\t' '$1 == "FIDELITY" { if (!h++) print "  Fresh vs in-place (PL34):"; printf "    %s %s: fresh=%s in_place=%s diff=%s\n", $2, $3, $4, $5, $6 }' <<<"$records"
		echo ""
		;;
	csv)
		awk -F'\t' -v reps="$(preamble_get ISTIOD_REPLICAS)" -v conv_min="$CONV_FIT_MIN_PUSHES" -v rules="${CONV_FIT_RULE} ${GROW_FIT_RULE} ${SERIES_FIT_RULE}" '
		BEGIN {
			printf "# scaling_fit_rules: conv_p99_min_pushes=%s conv_p99_push_count=xds_pushes_per_replica_across_types grow_deltas=per_namespace_added grow_window_fits=skip_first_step series_key=run_id+mesh_size+services_per_namespace+workload_mode\n", conv_min
			printf "# scaling_fit_rules: %s\n", rules
		}
		$1 == "SKIP" { printf "# scaling_not_measured: series=%s n=%s window=%s scoping=%s measurement_pods=%s outside=%s status=%s rows=%s run_id=%s\n", $2, $3, $4, $5, $6, $7, $8, $9, $10 }
		$1 == "FIT" { printf "# scaling_fit: series=%s scoping=%s window=%s metric=%s unit=%s per_100ns=%s intercept=%s r2=%s n=%s exponent=%s points=%s run_id=%s\n", $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13 }
		$1 == "PODS" { printf "# scaling_pods_vs_config_only: cell=%s metric=%s config_only=%s pods=%s ratio=%s\n", $2, $3, $4, $5, $6 }
		$1 == "PODSNOTE" { printf "# scaling_pods_vs_config_only: NOTE: %s\n", $2 }
		$1 == "PODSMISSING" { printf "# scaling_pods_vs_config_only: NOT MEASURED: %s\n", $2 }
		$1 == "MSWEEP" { if (!h++) printf "# scaling_msweep: istiod_replicas=%s heap_per_added_pod=delta(heap_inuse summed over a cluster replicas)/delta(measurement_pods)\n", reps
			printf "# scaling_msweep: cell=%s measurement_pods=%s heap_inuse_mi=%s heap_inuse_cluster_mi=%s istiod_pods_per_cluster=%s istiod_cpu_s=%s xds_pushes=%s proxy_config_kib=%s proxy_envoy_mem_mi=%s heap_per_added_pod_mi=%s run_id=%s\n", $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12 }
		$1 == "MSWEEPMISSING" { printf "# scaling_msweep: %s\n", $2 }
		$1 == "DISC" { printf "# scaling_discovery: cell=%s outside=%s x=%s istiod_services=%s delta=%s expected=%s heap_inuse_mi=%s proxy_config_kib=%s root_cert_cms=%s gateway_clusters=%s check=%s run_id=%s\n", $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13 }
		$1 == "FIDELITY" { printf "# scaling_fidelity: cell=%s metric=%s fresh=%s in_place=%s diff=%s fresh_run_id=%s in_place_run_id=%s\n", $2, $3, $4, $5, $6, $7, $8 }' <<<"$records"
		;;
	json)
		awk -F'\t' -v reps="$(preamble_get ISTIOD_REPLICAS)" -v conv_min="$CONV_FIT_MIN_PUSHES" -v rules="${CONV_FIT_RULE} ${GROW_FIT_RULE} ${SERIES_FIT_RULE}" '
		function isnum(s) { return s ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/ }
		function num(v) { return isnum(v) ? v + 0 : "null" }
		function str(v) { gsub(/"/, "", v); return "\"" v "\"" }
		function strs(v,    a, n, i, out) {
			n = split(v, a, "+"); out = ""
			for (i = 1; i <= n; i++) if (a[i] != "" && a[i] != "-") out = out (out == "" ? "" : ",") str(a[i])
			return "[" out "]"
		}
		function pts(s,    n, a, i, kv, out) {
			n = split(s, a, " "); out = ""
			for (i = 1; i <= n; i++) { split(a[i], kv, ":"); out = out (i > 1 ? "," : "") "[" num(kv[1]) "," num(kv[2]) "]" }
			return "[" out "]"
		}
		$1 == "SKIP" { skip = skip (skip == "" ? "" : ",") sprintf("{\"series\":%s,\"run_id\":%s,\"n\":%s,\"window\":%s,\"scoping\":%s,\"measurement_pods\":%s,\"outside\":%s,\"statuses\":%s,\"rows\":%s}", str($2), str($10), num($3), str($4), str($5), num($6), str($7), strs($8), num($9)) }
		$1 == "FIT" { fits = fits (fits == "" ? "" : ",") sprintf("{\"series\":%s,\"run_id\":%s,\"scoping\":%s,\"window\":%s,\"metric\":%s,\"unit\":%s,\"per_100ns\":%s,\"intercept\":%s,\"r2\":%s,\"n\":%s,\"exponent\":%s,\"points\":%s}", str($2), str($13), str($3), str($4), str($5), str($6), num($7), num($8), num($9), num($10), num($11), pts($12)) }
		$1 == "PODS" { pods = pods (pods == "" ? "" : ",") sprintf("{\"cell\":%s,\"metric\":%s,\"config_only\":%s,\"pods\":%s,\"ratio\":%s,\"config_only_run_ids\":%s,\"pods_run_ids\":%s}", str($2), str($3), num($4), num($5), num($6), strs($7), strs($8)) }
		$1 == "PODSNOTE" { podsnote = $2 }
		$1 == "PODSMISSING" { podsmiss = $2 }
		$1 == "MSWEEP" { ms = ms (ms == "" ? "" : ",") sprintf("{\"cell\":%s,\"measurement_pods\":%s,\"heap_inuse_mi\":%s,\"heap_inuse_cluster_mi\":%s,\"istiod_pods_per_cluster\":%s,\"istiod_cpu_s\":%s,\"xds_pushes\":%s,\"proxy_config_kib\":%s,\"proxy_envoy_mem_mi\":%s,\"heap_per_added_pod_mi\":%s,\"run_id\":%s}", str($2), num($3), num($4), num($5), num($6), num($7), num($8), num($9), num($10), num($11), str($12)) }
		$1 == "MSWEEPMISSING" { msmiss = $2 }
		$1 == "DISC" { disc = disc (disc == "" ? "" : ",") sprintf("{\"cell\":%s,\"outside\":%s,\"x\":%s,\"istiod_services\":%s,\"delta\":%s,\"expected_delta\":%s,\"heap_inuse_mi\":%s,\"proxy_config_kib\":%s,\"root_cert_cms\":%s,\"gateway_clusters\":%s,\"check\":%s,\"run_id\":%s}", str($2), str($3), num($4), num($5), num($6), num($7), num($8), num($9), num($10), num($11), str($12), str($13)) }
		$1 == "FIDELITY" { fid = fid (fid == "" ? "" : ",") sprintf("{\"cell\":%s,\"metric\":%s,\"fresh\":%s,\"in_place\":%s,\"diff\":%s,\"fresh_run_id\":%s,\"in_place_run_id\":%s}", str($2), str($3), num($4), num($5), str($6), str($7), str($8)) }
		END {
			printf "{\"fit_rules\":{\"conv_p99_min_pushes\":%s,\"conv_p99_push_count\":\"xds_pushes_per_replica_across_types\",\"grow_deltas\":\"per_namespace_added\",\"grow_window_fits\":\"skip_first_step\",\"series_key\":[\"run_id\",\"mesh_size\",\"services_per_namespace\",\"workload_mode\"],\"text\":%s},\"not_measured\":[%s],\"fits\":[%s],\"pods_vs_config_only\":{\"missing\":%s,\"note\":%s,\"rows\":[%s]},\"measurement_pod_sweep\":{\"missing\":%s,\"istiod_replicas\":%s,\"rows\":[%s]},\"discovery\":[%s],\"fresh_vs_in_place\":[%s]}", \
				num(conv_min), str(rules), skip, fits, (podsmiss == "" ? "null" : str(podsmiss)), (podsnote == "" ? "null" : str(podsnote)), pods, \
				(msmiss == "" ? "null" : str(msmiss)), str(reps), ms, disc, fid
		}' <<<"$records"
		;;
	esac
}

# scaling_section <format> <aggregated>: the section, best-effort (PL40): a failure
# warns with its reason and the rest of the report stands. Prints nothing without
# growth cells.
scaling_section() {
	local fmt="$1" aggregated="$2" err out
	has_growth_cells "$aggregated" || return 0
	err="$(mktemp)"
	# Explicit `|| exit 1`: errexit does not apply inside an `if` condition, so a failed
	# records pass must fail the subshell by hand.
	# shellcheck disable=SC2030,SC2031
	if out="$( ( recs="$(scaling_records "$aggregated")" || exit 1; scaling_render "$fmt" "$recs" ) 2>"$err" )"; then
		printf '%s\n' "$out"
	else
		echo "warning: the namespace-scaling section failed (the per-cell figures are complete):" >&2
		sed 's/^/  /' "$err" >&2
		[[ "$fmt" == json ]] && printf '{"error":"namespace-scaling section failed; see stderr"}\n'
	fi
	rm -f "$err"
}

report_text() {
	local aggregated short
	aggregated=$(aggregate)
	short="$(vsdr_ingest_short "$aggregated")"
	echo "=== Control-Plane Resource Scaling ==="
	echo "# RUN_ID=${RUN_ID_TAG}  ISTIO_VERSION=${ISTIO_VERSION_TAG}  HARNESS_SHA=${HARNESS_SHA_TAG}  files_consumed=${FILES_CONSUMED}  skipped_legacy=${FILES_SKIPPED}  run_config=${RUN_CONFIG_M}  run_config_sha256=${RUN_CONFIG_SHA256_M}  ISTIO_VERSION_SOURCE=${ISTIO_VERSION_SOURCE_M}  ISTIO_VERSION_PIN=${ISTIO_VERSION_PIN_M}  ISTIO_VERSION_BY_CONTEXT=${ISTIO_VERSION_BY_CONTEXT_M}"
	echo "# runs: run_ids=${RUN_IDS_M}  istio_versions=${ISTIO_VERSIONS_M}  harness_shas=${HARNESS_SHAS_M}"
	[[ -z "$POOLED_NOTE" ]] || echo "# POOLED RUNS: ${POOLED_NOTE}"
	sweep_outcome_recorded "$RESULTS_DIR" text | sed '/^$/d; s/^/# /'
	[[ -n "$PROVENANCE_WARNING" ]] && echo "# WARNING: ${PROVENANCE_WARNING}"
	data_warnings_lines "# WARNING: "
	if has_growth_cells "$aggregated"; then
		echo "# growth: growth_mode=${GROWTH_MODE_M}  services_per_namespace=${SWEEP_SPN}  workload_modes=${SWEEP_WMODE}  window_kinds=${SWEEP_WKIND}  probe_settle_sec=${PROBE_SETTLE_M}  mem_stop_pct=${MEM_STOP_PCT_M}  leftover_test_namespaces_at_start=${LEFTOVER_AT_START_M}"
	fi
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
	echo "  istiod_cpu_peak_pct_of_limit (max): $(pct_or_bare "$ISTIOD_CPU_PEAK_PCT")  [window peak CPU (cpu_peak) / per-replica CPU limit]"
	echo "  istiod_cpu_pct_of_limit (max): $(as_pct istiod_cpu_pct)  [kubectl top snapshot at the end of each window; misses bursts]"
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
	echo "Files: $(files_label)"
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
		printf "  istiod CPU peak (m):  min=%s max=%s avg=%s   [per row: the larger of the window average and the busiest 5 s poll]\n", $22, $23, $24
		printf "  istiod CPU avg (m):   %s   [process_cpu_seconds_total delta / window, averaged over the rows]\n", ($68 == "" ? "N/A" : $68)
		printf "  istiod RSS peak (Mi): min=%s max=%s avg=%s   [process_resident_memory_bytes peak per row]\n", $8, $9, $10
		printf "  Go heap alloc (Mi):   min=%s max=%s avg=%s   [go_memstats_alloc_bytes]\n", $29, $30, $31
		printf "  Go heap inuse (Mi):   min=%s max=%s avg=%s   [go_memstats_heap_inuse_bytes]\n", $32, $33, $34
		printf "  Convergence p99 (ms): %s%s\n", bucket_range($12), conv_pin
		printf "  Queue p99 (ms):       %s%s\n", bucket_range($15), queue_pin
		printf "  Connected proxies / istiod replica: min=%s max=%s avg=%s\n", $17, $18, $19
		printf "  Connected proxies / cluster:        min=%s max=%s avg=%s   [one value per cluster scrape]\n", $35, $36, $37
		if ($25+0 > 0) printf "  Config dump avg (MiB): %.2f   max: %.2f\n", $25/1048576, $26/1048576
		else if ($6 > 0) printf "  Config dump avg (MiB): N/A\n"
		printf "  Traffic mgmt:         VS+DR services=%s istiod VirtualServices avg=%s push time avg (ms)=%s PushContext init avg (ms)=%s\n", $39, $40, $41, $42
		printf "  xDS pushes avg=%s   xDS config size avg (bytes)=%s\n", $43, $44
		printf "  Sampled sidecars:     CDS clusters avg=%s CDS bytes avg=%s RDS bytes avg=%s\n", $45, $46, $47
		if ($48 + 0 > 0 || $49 != "pods" || $53 != "deploy" || $51 + 0 > 0) \
			printf "  Growth cell:          window=%s services_per_namespace=%s workload=%s measurement_pods=%s outside=%s/%s istiod_services=%s istiod_cpu_s=%s sidecar_envoy_mem_mi=%s gateway_clusters_max=%s gateway_mem_mi_max=%s gateway_physical_mi_max=%s gateway_ws_mi_max=%s root_cert_cms=%s leftover_test_ns_max=%s series_run=%s\n", $53, $48, $49, $50, $51, $52, $54, $55, $56, $57, $58, $65, $66, $59, $67, $64
		if ($20+0 > 0) printf "  ! istiod restarts:    %s row(s) had restarts during the scrape window\n", $20
		if ($21+0 > $62+0) printf "  ? undetectable restart: %s row(s) had unknown restart state (missing process_start_time_seconds)\n", $21 - $62
		if ($62+0 > 0) { st = $63; gsub(/\+/, ", ", st); printf "  - not measured: %s status row(s) %s (the cell was skipped or failed; not a restart)\n", $62, st }
		printf "\n"
	}' <<<"$aggregated"
	if [[ -n "$short" ]]; then
		while IFS=$'\t' read -r cell detail; do
			echo "WARNING: vsdr cell ${cell}: ${detail} — istiod did not ingest every VirtualService (check discoverySelectors and the namespace labels)"
		done <<<"$short"
	fi
	scaling_section text "$aggregated"
}

report_csv() {
	local aggregated short
	aggregated=$(aggregate)
	short="$(vsdr_ingest_short "$aggregated")"
	# One `# KEY=value` line per key (X5): a pooled value such as mixed:live,unknown holds a
	# comma, so one comma-joined line would be ambiguous.
	printf '# %s\n' "RUN_ID=${RUN_ID_TAG}" "ISTIO_VERSION=${ISTIO_VERSION_TAG}" "HARNESS_SHA=${HARNESS_SHA_TAG}" \
		"files_consumed=${FILES_CONSUMED}" "skipped_legacy=${FILES_SKIPPED}" "ISTIO_VERSION_SOURCE=${ISTIO_VERSION_SOURCE_M}" \
		"ISTIO_VERSION_PIN=${ISTIO_VERSION_PIN_M}" "ISTIO_VERSION_BY_CONTEXT=${ISTIO_VERSION_BY_CONTEXT_M}"
	echo "# runs: run_ids=${RUN_IDS_M} istio_versions=${ISTIO_VERSIONS_M} harness_shas=${HARNESS_SHAS_M}"
	config_multi_run_csv
	[[ -n "$PROVENANCE_WARNING" ]] && echo "# WARNING: ${PROVENANCE_WARNING}"
	data_warnings_lines "# WARNING: "
	echo "# run_config: run_config=${RUN_CONFIG_M} run_config_sha256=${RUN_CONFIG_SHA256_M}"
	echo "# sweep: mesh_sizes=${SWEEP_MESH} service_counts=${SWEEP_SVC} replica_counts=${SWEEP_REP} namespace_counts=${SWEEP_NS} sidecar_scopings=${SWEEP_SCOPE} traffic_configs=${SWEEP_TRAFFIC}"
	echo "# traffic_management: vsdr_every=${VSDR_EVERY_M} vsdr_subsets=${VSDR_SUBSETS_M}"
	if has_growth_cells "$aggregated"; then
		echo "# growth: growth_mode=${GROWTH_MODE_M} services_per_namespace=${SWEEP_SPN} workload_modes=${SWEEP_WMODE} window_kinds=${SWEEP_WKIND} probe_settle_sec=${PROBE_SETTLE_M} mem_stop_pct=${MEM_STOP_PCT_M} leftover_test_namespaces_at_start=${LEFTOVER_AT_START_M}"
	fi
	# O9 achieved-scale provenance parity with text/markdown. Comment lines only, so the
	# CSV row schema (the aggregate columns below) is byte-identical for row consumers.
	echo "# capacity: node_alloc_cpu_m=$(preamble_get NODE_ALLOC_CPU_M) node_alloc_mem_mi=$(preamble_get NODE_ALLOC_MEM_MI) istiod_cpu_limit_m=$(preamble_get ISTIOD_CPU_LIMIT_M) istiod_mem_limit_mi=$(preamble_get ISTIOD_MEM_LIMIT_MI) scale_target_fraction=$(preamble_get SCALE_TARGET_FRACTION) scale_sizing_mode=$(preamble_get SCALE_SIZING_MODE) metrics_api=$(preamble_get METRICS_API) (istiod limits per replica)"
	echo "# infra: istiod_req_cpu_m=$(preamble_get ISTIOD_REQ_CPU_M) istiod_req_mem_mi=$(preamble_get ISTIOD_REQ_MEM_MI) istiod_lim_cpu_m=$(preamble_get ISTIOD_LIM_CPU_M) istiod_lim_mem_mi=$(preamble_get ISTIOD_LIM_MEM_MI) istiod_replicas=$(preamble_get ISTIOD_REPLICAS) istiod_replicas_by_context=$(preamble_get ISTIOD_REPLICAS_BY_CONTEXT) network_topology=$(preamble_get NETWORK_TOPOLOGY)"
	echo "# achieved: connected_proxies_max=$(as_get proxies) connected_proxies_cluster_max=$(pc_get proxies_cluster) services_configured_max=$(as_get svc) istiod_cpu_peak_pct_of_limit_max=$(pct_or_bare "$ISTIOD_CPU_PEAK_PCT") istiod_cpu_pct_of_limit_max=$(as_pct istiod_cpu_pct) istiod_mem_pct_of_limit_max=$(as_pct istiod_mem_pct) istiod_rss_pct_of_limit_max=$(pct_or_bare "$ISTIOD_RSS_MEM_PCT") node_cpu_pct_max=$(as_pct node_cpu_pct) node_mem_pct_max=$(as_pct node_mem_pct) pods_scheduled_max=$(as_get pods_sched) pods_allocatable_max=$(as_get pods_alloc)"
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
	# Namespace-scaling fits and pairings as comment lines (the row schema is unchanged).
	scaling_section csv "$aggregated"
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
Units: Mi / MiB = 1024² bytes, KiB = 1024 bytes, GiB = Mi / 1024; m = millicores.

| Column | Units | Source | Definition / caveats |
|--------|-------|--------|----------------------|
| `mesh_size` | clusters | sweep axis | Number of clusters participating in the mesh. |
| `svc` (service_count) | services | sweep axis | Total dummy services per cluster. |
| `reps` (replicas) | pods/service | sweep axis | Pods per service (drives endpoint/EDS count). |
| `ns` (namespace_count) | namespaces | sweep axis | Namespaces holding the services. |
| `scoping` (sidecar_scoping) | enum | sweep axis | `Sidecar` CR mode: `none` / `namespace` / `explicit`. |
| `n_total` | rows | internal | All rows for the cell, including restart-poisoned/`unknown` and degraded (`SETUP_FAILED`/`PROBE_FAILED`, or a context with zero istiod pods) rows. |
| `n_valid` | rows | internal | Rows with `istiod_restarted==0` used in numeric aggregation; `n_valid < n_total` means some rows were dropped as poisoned. |
| `cpu_peak (m)` | millicores (per replica) | `process_cpu_seconds_total` | Per row the larger of the window average and the busiest 5 s poll (a peak, not an average); the cell shows the mean over its rows. `N/A` on restart or a missing baseline. |
| `cpu_avg (m)` | millicores (per replica) | `process_cpu_seconds_total` delta ÷ window × 1000 | The true average over the scrape window (TSV `istiod_cpu_s_delta` / `scrape_window_sec`), mean over the cell's rows; `N/A` for files before CONTROLPLANE_SCHEMA=63. |
| `rss_peak (Mi)` | MiB (per replica) | `process_resident_memory_bytes` (istiod `/metrics`) | Peak RSS of (baseline, 5 s polled samples, final scrape) over the window; the cell shows the mean over its rows. |
| `heap_alloc (Mi)` | MiB | `go_memstats_alloc_bytes` | Go heap allocated — point-in-time at final scrape, not a peak. |
| `heap_inuse (Mi)` | MiB | `go_memstats_heap_inuse_bytes` | Go heap in use — point-in-time at final scrape; steady-state signal independent of RSS (which stays inflated after GC via `MADV_FREE`). |
| `conv_p99 (ms)` | ms (bucket range) | `pilot_proxy_convergence_time` histogram delta | p99 convergence reported as a **bucket range** (e.g. `100-500`), not an exact value — istiod buckets are 100/500/1000/3000/5000/10000/20000/30000 ms. `†` = SINGLE-BUCKET-PINNED (all delta mass in the 0-100 ms bucket; a uniform-within-bucket assumption, unresolved below 100 ms). |
| `queue_p99 (ms)` | ms (bucket range) | `pilot_proxy_queue_time` histogram delta | p99 time pushes waited in istiod's queue; same bucket-range / `†` semantics as `conv_p99`. |
| `proxies/replica` (connected_proxies) | proxies per istiod pod | `pilot_xds` gauge summed over its series (final scrape) | Proxies connected to ONE istiod replica (each proxy holds one istiod connection, so with R replicas this is roughly 1/R of the cluster). A replica with no connections reads 0. Gated on `istiod_restarted==0` (a mid-reconnect transient is excluded). |
| `proxies/cluster` (cluster_connected_proxies) | proxies per cluster | `pilot_xds` summed over every istiod pod of one cluster, same final scrape batch | One value per cluster scrape (avg over the cell's scrapes here). `N/A` when any pod scrape was empty or short, or the Running istiod pod set changed during the window. Counted only when every pod row of that scrape has `istiod_restarted==0`. |
| `proxy check` (proxy_check) | OK / LOW / HIGH / N/A | `proxies/cluster` vs the cluster's Running, non-terminating pods with the `sidecar.istio.io/status` annotation (gateways included) | `LOW`/`HIGH` when they differ by more than max(`PROXY_CHECK_TOLERANCE_PCT` % of the sidecar pods, `PROXY_CHECK_MIN_DIFF`). A warning, never a filter: flagged scrapes stay in every aggregate. The pod count is read seconds after the scrape, so pods starting or stopping in between can flag a scrape. |
| `cfg_dump_avg (MiB)` | MiB (1024 x 1024 bytes) | `pilot-agent request /config_dump?include_eds` → `wc -c` | Real per-proxy config-dump size (EDS included by design — the cost `Sidecar` scoping reduces); proxy-side, so ingested regardless of istiod restart state. |
| `restarts` | rows | `istiod_restarted==1` | Rows where `process_start_time_seconds` moved forward between baseline and final scrape; counters/histograms for those samples may under-report. |
| `unk_restarts` | rows | `istiod_restarted==unknown` | Rows where restart state was undetectable (a pinned pod disappeared / missing `process_start_time_seconds`), plus 003 status rows of a cell that was skipped or failed (`SETUP_FAILED`, `SKIPPED_MEM_GUARD`, ...); the cell names those as `(N status: ...)`. |
| `traffic` (traffic_config) | enum | sweep axis | `none` (no VirtualService/DestinationRule) or `vsdr` (one VirtualService and one DestinationRule per configured service; that service's replicas are split over one Deployment per subset, so the pod count is the same). Rows from 40-column TSVs count as `none`. |
| `VS+DR svcs` (vsdr_services) | services | configured | Services given a VirtualService + DestinationRule (`--vsdr-every`); 0 for `none`. Configured intent, not a measurement. |
| `istiod VS` (istiod_virt_services) | VirtualServices | `pilot_virt_services` gauge (final scrape) | Every VirtualService istiod knows, the test's and any already in the mesh. Same on every replica (never summed). Gated on `istiod_restarted==0`. |
| `push time avg (ms)` | ms per push | `pilot_xds_push_time` Δsum ÷ Δcount, all xDS types | Average time istiod spent generating and sending one push in the window. `N/A` with no push or on a restarted row. |
| `PushContext init avg (ms)` | ms | `pilot_pushcontext_init_seconds` Δsum ÷ Δcount | Average PushContext rebuild time in the window (VS/DR indexing lands here). `N/A` with no rebuild or on a restarted row. |
| `xDS pushes` | pushes per istiod pod | `pilot_xds_pushes` delta | Pushes over the window (TSV `xds_pushes_delta`). |
| `xDS config size avg` | bytes per push (KiB in the VS/DR table) | `pilot_xds_config_size_bytes` Δsum ÷ Δcount | Average pushed resource size over all xDS types (TSV `config_size_avg_bytes`). |
| `CDS clusters` | clusters per proxy | sampled `/config_dump` `dynamic_active_clusters` | CDS clusters on the sampled sidecars; each DestinationRule subset adds one per port. Proxy-side, so not restart-gated. |
| `CDS (KiB)` / `RDS (KiB)` | KiB (1024 bytes) per proxy | compact JSON length of the dump's `ClustersConfigDump` / `RoutesConfigDump` | A size signal for the CDS and RDS config (VirtualService routes land in RDS), not the xDS wire size. |

The "Sidecar scoping effect" table reuses `cfg_dump_avg` (per-proxy `/config_dump` MiB)
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
	local total_restarts total_unknowns total_status
	total_restarts=$(awk -F'\t' 'NR>1 { s += $20+0 } END { printf "%d", s+0 }' <<<"$aggregated")
	total_unknowns=$(awk -F'\t' 'NR>1 { s += $21+0 } END { printf "%d", s+0 }' <<<"$aggregated")
	# Status rows (a cell skipped or failed) carry istiod_restarted=unknown; name them
	# apart from real undetectable restart states.
	total_status=$(awk -F'\t' 'NR>1 { s += $62+0 } END { printf "%d", s+0 }' <<<"$aggregated")

	echo "---"
	echo "run_id: ${RUN_ID_TAG}"
	echo "istio_version: ${ISTIO_VERSION_TAG}"
	echo "istio_version_source: \"${ISTIO_VERSION_SOURCE_M}\""
	echo "istio_version_pin: \"${ISTIO_VERSION_PIN_M}\""
	echo "istio_version_by_context: \"${ISTIO_VERSION_BY_CONTEXT_M}\""
	echo "harness_sha: ${HARNESS_SHA_TAG}"
	echo "run_ids: $(json_list "$RUN_IDS_M")"
	echo "istio_versions: $(json_list "$ISTIO_VERSIONS_M")"
	echo "harness_shas: $(json_list "$HARNESS_SHAS_M")"
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
	echo "growth_mode: \"${GROWTH_MODE_M}\""
	echo "services_per_namespace: \"${SWEEP_SPN}\""
	echo "workload_modes: \"${SWEEP_WMODE}\""
	echo "window_kinds: \"${SWEEP_WKIND}\""
	echo "probe_settle_sec: \"${PROBE_SETTLE_M}\""
	echo "mem_stop_pct: \"${MEM_STOP_PCT_M}\""
	echo "leftover_test_namespaces_at_start: \"${LEFTOVER_AT_START_M}\""
	echo "data_warnings: $(printf '%s' "$DATA_WARNINGS" | awk 'BEGIN { ORS = ""; printf "[" } { gsub(/["\\]/, ""); printf "%s\"%s\"", (NR > 1 ? "," : ""), $0 } END { print "]" }')"
	echo "---"
	echo ""
	echo "# Control-Plane Resource Scaling"
	echo ""
	[[ -z "$POOLED_NOTE" ]] || printf '> **Pooled runs.** %s\n\n' "$POOLED_NOTE"
	sweep_outcome_recorded "$RESULTS_DIR" md
	[[ -n "$PROVENANCE_WARNING" ]] && { echo "> **Warning:** ${PROVENANCE_WARNING}"; echo ""; }
	if [[ -n "$DATA_WARNINGS" ]]; then data_warnings_lines "> **Warning:** "; echo ""; fi
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
	echo "| istiod_cpu_peak_pct_of_limit (max; window peak / per-replica limit) | $(pct_or_bare "$ISTIOD_CPU_PEAK_PCT") |"
	echo "| istiod_cpu_pct_of_limit (max; kubectl top snapshot at window end) | $(as_pct istiod_cpu_pct) |"
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
	local growth=0
	has_growth_cells "$aggregated" && growth=1
	if ((growth)); then
		echo "| services_per_namespace | ${SWEEP_SPN} |"
		echo "| workload_modes | ${SWEEP_WMODE} |"
		echo "| window_kinds | ${SWEEP_WKIND} |"
	fi
	echo ""
	echo "Files: $(files_label)"
	echo ""
	# Growth cells add their key columns (window, K, workload, measurement pods, outside),
	# and the series run when growth cells come from more than one run.
	local gh="" gs="" gruns=0
	if ((growth)); then
		gh=" window | K | workload | M | outside |"
		gs="--------|---|----------|---|---------|"
		if (($(growth_run_count "$aggregated") > 1)); then
			gruns=1
			gh+=" run |"
			gs+="-----|"
		fi
	fi
	echo "| mesh_size | svc | reps | ns | scoping | traffic | n_total | n_valid | cpu_peak (m) | cpu_avg (m) | rss_peak (Mi) | heap_alloc (Mi) | heap_inuse (Mi) | conv_p99 (ms) | queue_p99 (ms) | proxies/replica | proxies/cluster | cfg_dump_avg (MiB) | restarts | unk_restarts |${gh}"
	echo "|-----------|-----|------|----|---------|---------|---------|---------|--------------|-------------|---------------|-----------------|-----------------|---------------|----------------|-----------------|-----------------|--------------------|----------|--------------|${gs}"
	awk -F'\t' -v growth="$growth" -v gruns="$gruns" '
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
		cfg_mb = ($25+0 > 0) ? sprintf("%.2f", $25/1048576) : "N/A"
		ha = ($31+0 > 0) ? sprintf("%.0f", $31) : "N/A"
		hi = ($34+0 > 0) ? sprintf("%.0f", $34) : "N/A"
		# P1-6: dagger-mark a SINGLE-BUCKET-PINNED conv/queue p99 (cols 27/28).
		cp = bucket_range($12); if ($27+0 == 1) { cp = cp " †"; any_pin = 1 }
		qp = bucket_range($15); if ($28+0 == 1) { qp = qp " †"; any_pin = 1 }
		gcols = growth ? sprintf(" %s | %s | %s | %s | %s |", $53, $48, $49, $50, ($51 + 0 > 0 ? $51 "/" $52 : "-")) : ""
		if (gruns) gcols = gcols " " $64 " |"
		# Status rows count in unk_restarts; say so in the cell.
		unk = $21
		if ($62 + 0 > 0) { st = $63; gsub(/\+/, ", ", st); unk = unk " (" $62 " status: " st ")" }
		printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |%s\n", $1, $2, $3, $4, $5, $38, $6, $7, $24, ($68 == "" ? "N/A" : $68), $10, ha, hi, cp, qp, $19, $37, cfg_mb, $20, unk, gcols
	}
	END { if (any_pin) print "\n> † SINGLE-BUCKET-PINNED: all delta mass for that quantile sits in the coarsest (0-100ms) `pilot_proxy_convergence_time` bucket, so the reported value is a uniform-within-bucket assumption (Prometheus `histogram_quantile` semantics), NOT resolved below 100ms. Real sub-bucket signal only appears once convergence climbs into a higher bucket (e.g. at 10k-service scale)." }' <<<"$aggregated"
	local real_unknowns=$(( total_unknowns - total_status ))
	(( real_unknowns < 0 )) && real_unknowns=0
	if (( total_restarts > 0 || real_unknowns > 0 )); then
		echo ""
		local parts=()
		(( total_restarts > 0 )) && parts+=("${total_restarts} row(s) had istiod restarts during the scrape window")
		(( real_unknowns > 0 )) && parts+=("${real_unknowns} row(s) had undetectable restart state during the window")
		local joined="${parts[0]}"
		[[ ${#parts[@]} -gt 1 ]] && joined+="; ${parts[1]}"
		echo "> ${joined} — counters/histograms for those samples may under-report and should be treated as suspect."
	fi
	if (( total_status > 0 )); then
		echo ""
		echo "> ${total_status} row(s) are status rows of cells that were skipped or failed (${STATUS_SUMMARY}), not restarts: they carry no metrics and count in \`n_total\` and \`unk_restarts\` only.$( ((growth)) && echo ' The growth cells among them are listed under "Cells not measured" in the Namespace scaling section.')"
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
	# Legacy-layout deploy cells only; the namespace-scaling section compares growth cells.
	$48 + 0 > 0 || $53 != "deploy" { next }
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
		if (nb == 0) { print "(No legacy-layout cell with traffic none to compare; growth cells are compared in the Namespace scaling section.)"; exit }
		any_scoping = 0; any_wide = 0
		for (i = 1; i <= nb; i++) {
			b = bases[i]
			if (has[b, "namespace"] || has[b, "explicit"] || has[b, "wide"]) any_scoping = 1
			if (has[b, "wide"]) any_wide = 1
		}
		if (!any_scoping) { print "(No sidecar scoping data to compare.)"; exit }
		# The wide columns (a per-namespace */* Sidecar) appear only when wide was swept.
		printf "| mesh | svc | reps | ns | none (MiB) | namespace (MiB) | explicit (MiB) | none->ns | none->explicit |%s\n", (any_wide ? " wide (MiB) | none->wide |" : "")
		printf "|------|-----|------|----|-----------|----------------|---------------|----------|----------------|%s\n", (any_wide ? "-----------|------------|" : "")
		for (i = 1; i <= nb; i++) {
			b = bases[i]
			split(b, p, "|")
			n_v  = has[b,"none"]     ? val[b,"none"]     : -1
			ns_v = has[b,"namespace"]? val[b,"namespace"] : -1
			ex_v = has[b,"explicit"] ? val[b,"explicit"]  : -1
			wd_v = has[b,"wide"]     ? val[b,"wide"]      : -1
			ns_r = (n_v>0 && ns_v>=0) ? sprintf("%.1f%%", 100*(n_v-ns_v)/n_v) : "N/A"
			ex_r = (n_v>0 && ex_v>=0) ? sprintf("%.1f%%", 100*(n_v-ex_v)/n_v) : "N/A"
			wd_r = (n_v>0 && wd_v>=0) ? sprintf("%.1f%%", 100*(n_v-wd_v)/n_v) : "N/A"
			wide_cols = any_wide ? sprintf(" %s | %s |", (wd_v<0 ? "N/A" : sprintf("%.2f", wd_v/1048576)), wd_r) : ""
			printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |%s\n", \
				p[1], p[2], p[3], p[4], \
				(n_v<0  ? "N/A" : sprintf("%.2f", n_v/1048576)), \
				(ns_v<0 ? "N/A" : sprintf("%.2f", ns_v/1048576)), \
				(ex_v<0 ? "N/A" : sprintf("%.2f", ex_v/1048576)), \
				ns_r, ex_r, wide_cols
		}
	}' <<<"$aggregated"

	# Only when the sweep has vsdr cells; a none-only report is unchanged.
	if awk -F'\t' 'NR > 1 && $38 == "vsdr" && $48 + 0 == 0 { f = 1 } END { exit !f }' <<<"$aggregated"; then
		traffic_effect_section "$aggregated" "$short"
	fi

	# Only with growth cells (services_per_namespace > 0).
	scaling_section markdown "$aggregated"

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
	# Legacy-layout cells only (growth cells have no VS/DR): deploy, and traffic (a split
	# VS/DR apply: the window covers the VS/DR apply alone), paired within their kind.
	$48 + 0 > 0 || ($53 != "deploy" && $53 != "traffic") { next }
	$38 == "none" || $38 == "vsdr" {
		base = $1 "|" $2 "|" $3 "|" $4 "|" $5 ($53 == "traffic" ? " (split apply)" : "")
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
		print "| mesh | svc | reps | ns | scoping | n_valid (none/vsdr) | VS+DR svcs | istiod VS | CPU peak (m) | heap inuse (Mi) | RSS peak (Mi) | xDS pushes | push time avg (ms) | PushContext init avg (ms) | xDS config size avg (KiB) |"
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
		print "| mesh | svc | reps | ns | scoping | VS+DR svcs | expected extra clusters | CDS clusters | clusters delta | CDS (KiB) | RDS (KiB) | cfg dump (MiB) |"
		print "|------|-----|------|----|---------|------------|-------------------------|--------------|----------------|----------|----------|---------------|"
		for (i = 1; i <= np; i++) {
			b = pb[i]; split(b, p, "|")
			vs = cell[b, "vsdr", 39]
			# Every proxy sees every service only with one namespace or scoping none.
			exp_cl = (is_num(vs) && is_num(subsets) && (p[4] + 0 == 1 || p[5] ~ /^none( |$)/)) ? vs * subsets : "-"
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
	local ns_scaling_json
	ns_scaling_json="$(scaling_section json "$aggregated")"
	# The recorded outcome goes through the environment: awk -v would unescape its \" (X3).
	SWEEP_OUTCOME_JSON="$(sweep_outcome_recorded "$RESULTS_DIR" json)" \
	NS_SCALING_JSON="$ns_scaling_json" awk -F'\t' -v ri="$RUN_ID_TAG" -v iv="$ISTIO_VERSION_TAG" -v iv_src="$ISTIO_VERSION_SOURCE_M" -v iv_pin="$ISTIO_VERSION_PIN_M" -v iv_by="$ISTIO_VERSION_BY_CONTEXT_M" -v hs="$HARNESS_SHA_TAG" -v fc="$FILES_CONSUMED" -v fs="$FILES_SKIPPED" \
		-v ri_list="$(json_list "$RUN_IDS_M")" -v iv_list="$(json_list "$ISTIO_VERSIONS_M")" -v hs_list="$(json_list "$HARNESS_SHAS_M")" -v prov_warn="${PROVENANCE_WARNING//[\"\\]/}" -v pooled="$(config_multi_run_json)" \
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
		-v ach_icpu="$(as_get istiod_cpu_pct)" -v ach_imem="$(as_get istiod_mem_pct)" -v ach_icpu_peak="$ISTIOD_CPU_PEAK_PCT" \
		-v data_warn="$(printf '%s' "$DATA_WARNINGS" | awk 'BEGIN { ORS = "" } { gsub(/["\\]/, ""); printf "%s\"%s\"", (NR > 1 ? "," : ""), $0 }')" -v leftover_start="$LEFTOVER_AT_START_M" \
		-v ach_irss="$ISTIOD_RSS_MEM_PCT" \
		-v ach_ncpu="$(as_get node_cpu_pct)" -v ach_nmem="$(as_get node_mem_pct)" \
		-v ach_psched="$(as_get pods_sched)" -v ach_palloc="$(as_get pods_alloc)" \
		-v gr_mode="$GROWTH_MODE_M" -v gr_stop="$MEM_STOP_PCT_M" -v gr_settle="$PROBE_SETTLE_M" -v gr_spn="$SWEEP_SPN" -v gr_wm="$SWEEP_WMODE" -v gr_wk="$SWEEP_WKIND" \
		-v cov="$COVERAGE_LINE" -v metrics_note="$(metrics_unavailable && metrics_note_text)" '
	function cell(v) {
		if (v !~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/) return "null"  # overflow / N/A
		return v + 0
	}
	BEGIN { outcome = ENVIRON["SWEEP_OUTCOME_JSON"]; printf "{\n  \"metadata\": {\"run_id\":\"%s\",\"istio_version\":\"%s\",\"istio_version_source\":\"%s\",\"istio_version_pin\":\"%s\",\"istio_version_by_context\":\"%s\",\"harness_sha\":\"%s\",\"run_ids\":%s,\"istio_versions\":%s,\"harness_shas\":%s,\"provenance_warning\":%s,\"run_config\":\"%s\",\"run_config_sha256\":\"%s\",\"files_consumed\":%d,\"skipped_legacy\":%d,\"sweep\":{\"mesh_sizes\":\"%s\",\"service_counts\":\"%s\",\"replica_counts\":\"%s\",\"namespace_counts\":\"%s\",\"sidecar_scopings\":\"%s\",\"traffic_configs\":\"%s\"},\"traffic_management\":{\"vsdr_every\":\"%s\",\"vsdr_subsets\":\"%s\"},\"capacity\":{\"node_alloc_cpu_m\":\"%s\",\"node_alloc_mem_mi\":\"%s\",\"istiod_cpu_limit_m\":\"%s\",\"istiod_mem_limit_mi\":\"%s\",\"scale_target_fraction\":\"%s\",\"scale_sizing_mode\":\"%s\",\"metrics_api\":\"%s\",\"istiod_limits_per_replica\":true},\"infra\":{\"istiod_req_cpu_m\":\"%s\",\"istiod_req_mem_mi\":\"%s\",\"istiod_lim_cpu_m\":\"%s\",\"istiod_lim_mem_mi\":\"%s\",\"istiod_replicas\":\"%s\",\"istiod_replicas_by_context\":\"%s\",\"network_topology\":\"%s\"},\"tuning_baseline\":{\"levers\":\"%s\",\"sidecar_egress_hosts\":\"%s\"},\"achieved_scale\":{\"connected_proxies_max\":\"%s\",\"connected_proxies_cluster_max\":\"%s\",\"services_configured_max\":\"%s\",\"istiod_cpu_peak_pct_of_limit_max\":\"%s\",\"istiod_cpu_pct_of_limit_max\":\"%s\",\"istiod_mem_pct_of_limit_max\":\"%s\",\"istiod_rss_pct_of_limit_max\":\"%s\",\"node_cpu_pct_max\":\"%s\",\"node_mem_pct_max\":\"%s\",\"pods_scheduled_max\":\"%s\",\"pods_allocatable_max\":\"%s\"},\"proxy_check\":{\"tolerance_pct\":\"%s\",\"min_diff\":\"%s\",\"ok\":%d,\"low\":%d,\"high\":%d,\"na\":%d,\"excluded\":%d,\"flagged\":\"%s\"},\"coverage\":\"%s\",\"sla\":{\"verdict\":\"%s\",\"headline\":\"%s\"},\"metrics_note\":\"%s\",\"growth\":{\"growth_mode\":\"%s\",\"mem_stop_pct\":\"%s\",\"probe_settle_sec\":\"%s\",\"services_per_namespace\":\"%s\",\"workload_modes\":\"%s\",\"window_kinds\":\"%s\",\"leftover_test_namespaces_at_start\":\"%s\"},\"data_warnings\":[%s]},\n  \"pooled_runs\": %s,\n  \"sweep_outcome\": %s,\n  \"results\": [", ri, iv, iv_src, iv_pin, iv_by, hs, ri_list, iv_list, hs_list, (prov_warn == "" ? "null" : "\"" prov_warn "\""), rc_path, rc_sha, fc, fs, sw_mesh, sw_svc, sw_rep, sw_ns, sw_scope, sw_traffic, tm_every, tm_subsets, cap_ncpu, cap_nmem, cap_icpu, cap_imem, cap_tf, cap_mode, cap_metrics, inf_rcpu, inf_rmem, inf_lcpu, inf_lmem, inf_rep, inf_rep_by, inf_net, tb_levers, tb_egress, ach_prx, ach_cprx, ach_svc, ach_icpu_peak, ach_icpu, ach_imem, ach_irss, ach_ncpu, ach_nmem, ach_psched, ach_palloc, pc_tol, pc_min, pc_ok, pc_low, pc_high, pc_na, pc_excl, pc_flagged, cov, sla_v, sla_h, metrics_note, gr_mode, gr_stop, gr_settle, gr_spn, gr_wm, gr_wk, leftover_start, data_warn, pooled, outcome }
	NR == 1 { next }
	{
		if (printed++) printf ",\n    "; else printf "\n    "
		printf "{\"mesh_size\":%s,\"service_count\":%s,\"replicas\":%s,\"namespace_count\":%s,\"sidecar_scoping\":\"%s\",\"n_total\":%s,\"n_valid\":%s,",
			$1, $2, $3, $4, $5, $6, $7
		printf "\"istiod_cpu_peak_m\":{\"min\":%s,\"max\":%s,\"avg\":%s},\"istiod_cpu_avg_m\":%s,", cell($22), cell($23), cell($24), cell($68)
		printf "\"istiod_rss_peak_mi\":{\"min\":%s,\"max\":%s,\"avg\":%s},",      cell($8), cell($9), cell($10)
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
		printf "\"services_per_namespace\":%s,\"workload_mode\":\"%s\",\"measurement_pods\":%s,\"outside_namespaces\":%s,\"outside_discovery\":\"%s\",\"window_kind\":\"%s\",", cell($48), $49, cell($50), cell($51), $52, $53
		printf "\"istiod_services_max\":%s,\"istiod_cpu_s_avg\":%s,\"sidecar_envoy_mem_mi_avg\":%s,\"gateway_clusters_max\":%s,\"gateway_mem_mi_max\":%s,\"gateway_physical_mi_max\":%s,\"gateway_ws_mi_max\":%s,\"root_cert_configmaps_max\":%s,\"leftover_test_namespaces_max\":%s,", cell($54), cell($55), cell($56), cell($57), cell($58), cell($65), cell($66), cell($59), cell($67)
		sts = $63
		if (sts == "-" || sts == "") sts = "[]"
		else { gsub(/\+/, "\",\"", sts); sts = "[\"" sts "\"]" }
		printf "\"go_heap_inuse_cluster_mi_avg\":%s,\"istiod_pods_per_cluster_avg\":%s,\"status_rows\":%d,\"statuses\":%s,", cell($60), cell($61), $62 + 0, sts
		printf "\"series_run_id\":%s,\"istiod_vs_ingest_short\":%s}", ($64 == "-" || $64 == "" ? "null" : "\"" $64 "\""), ($38 == "vsdr" && $48 + 0 == 0 && index(shortkeys, ";" $1 "|" $2 "|" $3 "|" $4 "|" $5 ($53 == "traffic" ? "|traffic" : "") ";")) ? "true" : "false"
	}
	END {
		# The namespace-scaling section (growth cells only), from ENVIRON so awk -v
		# escape processing cannot touch it.
		ns = ENVIRON["NS_SCALING_JSON"]
		tail = (ns != "") ? ",\n  \"namespace_scaling\": " ns "\n}\n" : "\n}\n"
		if (printed) printf "\n  ]%s", tail; else printf "]%s", tail
	}' <<<"$aggregated"
}

report_charts() {
	local aggregated
	aggregated=$(aggregate)

	echo "---"
	echo "istio_version: ${ISTIO_VERSION_TAG}"
	echo "istio_version_source: \"${ISTIO_VERSION_SOURCE_M}\""
	echo "istio_version_pin: \"${ISTIO_VERSION_PIN_M}\""
	echo "istio_version_by_context: \"${ISTIO_VERSION_BY_CONTEXT_M}\""
	echo "harness_sha: ${HARNESS_SHA_TAG}"
	echo "run_ids: $(json_list "$RUN_IDS_M")"
	echo "istio_versions: $(json_list "$ISTIO_VERSIONS_M")"
	echo "harness_shas: $(json_list "$HARNESS_SHAS_M")"
	echo "run_config: \"${RUN_CONFIG_M}\""
	echo "run_config_sha256: \"${RUN_CONFIG_SHA256_M}\""
	echo "files_consumed: ${FILES_CONSUMED}"
	echo "generated: $(date -u -Iseconds)"
	echo "---"
	echo ""
	echo "# Control-Plane Resource Scaling — Charts"
	echo ""
	[[ -z "$POOLED_NOTE" ]] || printf '> **Pooled runs.** %s\n\n' "$POOLED_NOTE"
	if [[ -n "$DATA_WARNINGS" ]]; then data_warnings_lines "> **Warning:** "; echo ""; fi
	# Chart 1: istiod CPU vs mesh size, one series per sidecar scoping.
	# Chart 2: Per-proxy config dump size (MiB) by scoping at largest mesh size.
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
	NR > 1 && $7 + 0 > 0 && is_num($24) && $48 + 0 == 0 && $53 == "deploy" {
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
		if has_growth_cells "$aggregated"; then
			echo "> Charts cover the legacy layout only; growth cells (namespace scaling) are in the markdown report's Namespace scaling section."
		else
			echo "> No cell has valid samples — nothing to chart."
		fi
		return 0
	fi
	echo "> Workload charted: ${max_svc} services x ${max_rep} replicas in ${max_ns} namespace(s) per cluster (${pick_note})."
	echo ""
	awk -F'\t' -v max_svc="$max_svc" -v max_rep="$max_rep" -v max_ns="$max_ns" '
	function is_num(s) { return s ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)$/ }
	NR == 1 { next }
	# Legacy-layout deploy cells only; growth cells are in the namespace-scaling section.
	$48 + 0 > 0 || $53 != "deploy" { next }
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
			printf "> %d of %d cells dropped (no valid samples / restart-poisoned / overflow); a dropped cell is drawn as 0 below (mermaid has no gap), which is not a measurement.\n\n", cells_dropped, cells_total
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
		printf "    title \"istiod CPU peak vs Mesh Size by Sidecar Scoping (and traffic config)\"\n"
		printf "    x-axis \"Mesh Size\" ["
		for (i = 1; i <= n_ms; i++) {
			if (i > 1) printf ", "
			printf "%s", ms_order[i]
		}
		printf "]\n"
		printf "    y-axis \"istiod CPU peak (m, per replica)\"\n"
		for (s = 1; s <= n_sc; s++) {
			printf "    line ["; sep = ""
			for (i = 1; i <= n_ms; i++) {
				ms = ms_order[i]; sc = sc_order[s]
				v = has[ms, sc] ? cpu_val[ms, sc] : 0
				if (!has[ms, sc]) zero_drawn = 1
				printf "%s%.0f", sep, v; sep = ", "
			}
			printf "]\n"
		}
		printf "```\n\n"
		if (zero_drawn) printf "> A 0 on a line is a missing cell (dropped, or that scoping was not swept at that mesh size), not a measured 0.\n\n"
		printf "> Series order:"
		for (s = 1; s <= n_sc; s++) printf " **%s**", sc_order[s]
		printf ".\n\n"

		# Chart 2: Config dump size (MiB) by scoping at largest mesh size
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
		printf "    y-axis \"Size (MiB)\"\n"
		printf "    bar ["; sep = ""
		for (s = 1; s <= n_sc; s++) {
			sc = sc_order[s]
			v = (has[max_ms, sc] && cfg_val[max_ms, sc] > 0) ? cfg_val[max_ms, sc] / 1048576 : 0
			printf "%s%.1f", sep, v; sep = ", "
		}
		printf "]\n"
		printf "```\n\n"
		printf "> Config dump avg (MiB) at the largest mesh size swept (%s).\n", max_ms
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
	echo "  To fix: add cluster nodes, raise the workload size (larger --service-counts/--replica-counts; SCALE_SIZING_MODE=auto applies to a standalone 001 only), lower SCALE_COVERAGE_MIN_FRACTION, or unset SCALE_COVERAGE_ENFORCE to treat coverage as informational." >&2
	die "scale coverage under floor (SCALE_COVERAGE_ENFORCE=1)"
fi

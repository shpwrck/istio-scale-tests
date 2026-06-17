#!/usr/bin/env bash
# Orchestrate control-plane resource collection across the cross-product of
# five sweep axes: mesh size × service count × replicas × namespace count
# × sidecar scoping.
#
# For every combination, deploys dummy workloads, settles, scrapes istiod, and
# cleans up before moving on. Uses split-phase metrics so the deploy-time
# istiod push storm lands inside the measurement window.
#
# Usage:
#   ./tests/controlplane/003-run-sweep.sh [options]
#
# Examples:
#   # Default sweep — mesh sizes 1..N with default (10 svc × 3 replicas × 1 ns):
#   ./tests/controlplane/003-run-sweep.sh --contexts cluster-001,cluster-002,cluster-003
#
#   # Two-axis sweep: service count × namespace count, fixed mesh size of 3:
#   ./tests/controlplane/003-run-sweep.sh \
#     --contexts cluster-001,cluster-002,cluster-003 \
#     --mesh-sizes 3 --service-counts 10,100,500 --namespace-counts 1,5,25
#
#   # Cross-product mesh size with Sidecar scoping:
#   ./tests/controlplane/003-run-sweep.sh \
#     --contexts cluster-001,cluster-002,cluster-003 \
#     --mesh-sizes 1,2,3 --sidecar-scopings none,namespace,explicit
#
#   # Dry-run to see the planned matrix:
#   ./tests/controlplane/003-run-sweep.sh --dry-run \
#     --contexts a,b,c --service-counts 10,100 --sidecar-scopings none,namespace
# ci-dry-run:
set -euo pipefail
# P3: loud ERR trap so an unexpected abort self-reports the failing line. Coexists
# with the EXIT/cleanup trap installed later (separate signal). Per-combo probe and
# cleanup failures are caught explicitly below and degraded to a row status — they
# do NOT fire this trap.
trap 'rc=$?; echo "FATAL: ${0##*/} aborted (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/config/options.env"  # #45/#46: re-source for legibility (versions.env already pulls it in) — SCALE_* preamble keys
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"  # B4: harness_sha / probe_kube_versions for the pre-created preamble
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/capacity.sh"  # #45: cap_node_totals / cap_istiod_limits for the capacity provenance lines
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/envelope.sh"  # cluster-infra preamble (env_collect_infra) + campaign-end scale envelope

CONTEXTS_CSV=""
MESH_SIZES_CSV=""
SERVICE_COUNTS_CSV="${CONTROLPLANE_SERVICE_COUNT:-10}"
REPLICA_COUNTS_CSV="${CONTROLPLANE_REPLICAS_PER_SERVICE:-3}"
NAMESPACE_COUNTS_CSV="${CONTROLPLANE_NAMESPACE_COUNT:-1}"
SIDECAR_SCOPINGS_CSV="${CONTROLPLANE_SIDECAR_SCOPING:-none}"
CONFIG_DUMP_SAMPLES="${CONTROLPLANE_CONFIG_DUMP_SAMPLES:-3}"
OUTPUT_DIR_BASE="${ROOT}/tests/controlplane/results"
SETTLE_SEC=60
DRY_RUN=0
METRICS_API_STATUS="unknown"  # #44: set by metrics_preflight; recorded in the preamble
FORCE_LARGE_MATRIX=0
MAX_MATRIX="${CONTROLPLANE_MAX_MATRIX:-64}"

NS="${CONTROLPLANE_TEST_NAMESPACE:-controlplane-test}"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Sweep dimensions (cross-product):
  --contexts CSV              All available cluster contexts (default: \$SETUP_CONTEXTS).
  --mesh-sizes CSV            Cluster counts (default: "1,2,...,len(contexts)").
  --service-counts CSV        Dummy services per cluster (default: $SERVICE_COUNTS_CSV).
  --replica-counts CSV        Replicas per service (default: $REPLICA_COUNTS_CSV).
  --namespace-counts CSV      Namespaces to spread services across (default: $NAMESPACE_COUNTS_CSV).
  --sidecar-scopings CSV      Sidecar CR scoping modes: none,namespace,explicit
                              (default: \$CONTROLPLANE_SIDECAR_SCOPING or "none").

Singular aliases (one CSV value each):
  --service-count N           Alias for --service-counts N.
  --replicas N                Alias for --replica-counts N.
  --replicas-counts CSV       Deprecated alias for --replica-counts.
  --namespace-count N         Alias for --namespace-counts N.
  --sidecar-scoping VALUE     Alias for --sidecar-scopings VALUE.

Other:
  --config-dump-samples N     Random pods per cluster to exec /config_dump on
                              (default: $CONFIG_DUMP_SAMPLES; 0 disables).
  --settle SEC                Seconds for the delta-window between baseline
                              and final scrape (default: $SETTLE_SEC).
  --output-dir DIR            Results base directory; each sweep gets a
                              sweep-<RUN_ID>/ subdir under it
                              (default: tests/controlplane/results).
  --force-large-matrix        Allow matrix > $MAX_MATRIX combinations (default: refuse).
  --dry-run                   Print plan and matrix, then exit.
  -h, --help                  Show this help.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_SERVICE_COUNT, CONTROLPLANE_REPLICAS_PER_SERVICE,
  CONTROLPLANE_NAMESPACE_COUNT, CONTROLPLANE_SIDECAR_SCOPING,
  CONTROLPLANE_CONFIG_DUMP_SAMPLES, CONTROLPLANE_MAX_MATRIX.
  SCALE_SIZING_MODE, SCALE_TARGET_FRACTION (from config/options.env) are recorded
  in the TSV preamble for the report's coverage calibration + capacity block.
  METRICS_READY_TIMEOUT (default 120; 0 disables), METRICS_READY_INTERVAL (10):
  pre-sweep metrics-API readiness gate — polls 'kubectl top nodes' per context,
  records # METRICS_API= in the preamble, WARNs (never aborts) if unavailable.
  CAP_TOP_TIMEOUT (default 15): request timeout for the slower kubectl top reads
  (vs 5s for etcd get) — the primary #44 fix for top timing out under sweep load.
  CAP_TOP_ATTEMPTS (2), CAP_TOP_BACKOFF_S (2): per-read retry for transient blips.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"
		shift 2
		;;
	--mesh-sizes)
		[[ -n "${2:-}" ]] || die "--mesh-sizes requires a value"
		MESH_SIZES_CSV="$2"
		shift 2
		;;
	--service-counts)
		[[ -n "${2:-}" ]] || die "--service-counts requires a value"
		SERVICE_COUNTS_CSV="$2"
		shift 2
		;;
	--service-count)
		[[ -n "${2:-}" ]] || die "--service-count requires a value"
		echo "warning: --service-count is deprecated; use --service-counts" >&2
		SERVICE_COUNTS_CSV="$2"
		shift 2
		;;
	--replica-counts)
		[[ -n "${2:-}" ]] || die "--replica-counts requires a value"
		REPLICA_COUNTS_CSV="$2"
		shift 2
		;;
	--replicas-counts)
		[[ -n "${2:-}" ]] || die "--replicas-counts requires a value"
		echo "warning: --replicas-counts is deprecated; use --replica-counts" >&2
		REPLICA_COUNTS_CSV="$2"
		shift 2
		;;
	--replicas)
		[[ -n "${2:-}" ]] || die "--replicas requires a value"
		echo "warning: --replicas is deprecated; use --replica-counts" >&2
		REPLICA_COUNTS_CSV="$2"
		shift 2
		;;
	--namespace-counts)
		[[ -n "${2:-}" ]] || die "--namespace-counts requires a value"
		NAMESPACE_COUNTS_CSV="$2"
		shift 2
		;;
	--namespace-count)
		[[ -n "${2:-}" ]] || die "--namespace-count requires a value"
		echo "warning: --namespace-count is deprecated; use --namespace-counts" >&2
		NAMESPACE_COUNTS_CSV="$2"
		shift 2
		;;
	--sidecar-scopings)
		[[ -n "${2:-}" ]] || die "--sidecar-scopings requires a value"
		SIDECAR_SCOPINGS_CSV="$2"
		shift 2
		;;
	--sidecar-scoping)
		[[ -n "${2:-}" ]] || die "--sidecar-scoping requires a value"
		echo "warning: --sidecar-scoping is deprecated; use --sidecar-scopings" >&2
		SIDECAR_SCOPINGS_CSV="$2"
		shift 2
		;;
	--config-dump-samples)
		[[ -n "${2:-}" ]] || die "--config-dump-samples requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--config-dump-samples must be a non-negative integer; got '$2'"
		CONFIG_DUMP_SAMPLES="$2"
		shift 2
		;;
	--settle)
		[[ -n "${2:-}" ]] || die "--settle requires a value"
		SETTLE_SEC="$2"
		shift 2
		;;
	--output-dir)
		[[ -n "${2:-}" ]] || die "--output-dir requires a value"
		OUTPUT_DIR_BASE="$2"
		shift 2
		;;
	--force-large-matrix)
		FORCE_LARGE_MATRIX=1
		shift
		;;
	--dry-run)
		DRY_RUN=1
		shift
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

is_nonneg_int "$SETTLE_SEC" || die "--settle must be a non-negative integer (got: $SETTLE_SEC)"
is_pos_int "$MAX_MATRIX" || die "CONTROLPLANE_MAX_MATRIX must be a positive integer (got: $MAX_MATRIX)"

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_csv "$CONTEXTS_CSV" CONTEXTS
else
	split_csv "$SETUP_CONTEXTS" CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

MESH_SIZES=()
if [[ -n "$MESH_SIZES_CSV" ]]; then
	split_csv "$MESH_SIZES_CSV" MESH_SIZES
else
	for ((i = 1; i <= ${#CONTEXTS[@]}; i++)); do
		MESH_SIZES+=("$i")
	done
fi
((${#MESH_SIZES[@]})) || die "no mesh sizes resolved"

SERVICE_COUNTS=()
split_csv "$SERVICE_COUNTS_CSV" SERVICE_COUNTS
((${#SERVICE_COUNTS[@]})) || die "--service-counts produced an empty list"

REPLICA_COUNTS=()
split_csv "$REPLICA_COUNTS_CSV" REPLICA_COUNTS
((${#REPLICA_COUNTS[@]})) || die "--replica-counts produced an empty list"

NAMESPACE_COUNTS=()
split_csv "$NAMESPACE_COUNTS_CSV" NAMESPACE_COUNTS
((${#NAMESPACE_COUNTS[@]})) || die "--namespace-counts produced an empty list"

SCOPINGS=()
split_csv "$SIDECAR_SCOPINGS_CSV" SCOPINGS
((${#SCOPINGS[@]})) || die "--sidecar-scopings produced an empty list"

for ms in "${MESH_SIZES[@]}"; do
	is_pos_int "$ms" || die "mesh-size '$ms' is not a positive integer"
	((ms >= 1 && ms <= ${#CONTEXTS[@]})) || die "mesh-size $ms out of range (have ${#CONTEXTS[@]} contexts)"
done
for sc in "${SERVICE_COUNTS[@]}"; do
	is_pos_int "$sc" || die "service-count '$sc' is not a positive integer"
done
for rc in "${REPLICA_COUNTS[@]}"; do
	is_pos_int "$rc" || die "replica-count '$rc' is not a positive integer"
done
for nc in "${NAMESPACE_COUNTS[@]}"; do
	is_pos_int "$nc" || die "namespace-count '$nc' is not a positive integer"
done
for sc in "${SERVICE_COUNTS[@]}"; do
	for nc in "${NAMESPACE_COUNTS[@]}"; do
		(( nc <= sc )) || die "namespace-count $nc > service-count $sc; some namespaces would be empty. Reduce --namespace-counts to at most --service-counts."
	done
done
for scp in "${SCOPINGS[@]}"; do
	validate_scoping "$scp"
done

MATRIX_SIZE=$(( ${#MESH_SIZES[@]} * ${#SERVICE_COUNTS[@]} * ${#REPLICA_COUNTS[@]} * ${#NAMESPACE_COUNTS[@]} * ${#SCOPINGS[@]} ))

SCRIPT_DIR="${ROOT}/tests/controlplane"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OUTPUT_DIR="${OUTPUT_DIR_BASE}/sweep-${RUN_ID}"

# The 40-column TSV schema header (kept in one place so the pre-create + 002 agree).
CONTROLPLANE_TSV_HEADER="timestamp\tcontext\tmesh_size\tservice_count\treplicas\tnamespace_count\tsidecar_scoping\tistiod_mem_mi\tconvergence_p50_ms\tconvergence_p99_ms\tqueue_p50_ms\tqueue_p99_ms\txds_pushes_delta\txds_pushes_rate\txds_pushes_cds\txds_pushes_eds\txds_pushes_lds\txds_pushes_rds\txds_pushes_nds\tk8s_events_delta\tk8s_events_rate\tconnected_proxies\tconfig_size_avg_bytes\tsidecar_config_bytes_avg\tsidecar_config_bytes_p50\tsidecar_config_bytes_max\tsidecar_config_bytes_samples\tscrape_window_sec\tscrape_skew_ms\tsettle_sec\tistiod_restarted\tistiod_cpu_m_delta\tgo_heap_alloc_mi\tgo_heap_inuse_mi\tistiod_cpu_pct_of_limit\tistiod_mem_pct_of_limit\tnode_cpu_pct\tnode_mem_pct\tpods_scheduled\tpods_allocatable"

# B4 (reproducibility): pre-create controlplane-${RUN_ID}.tsv with the FULL preamble
# BEFORE the first combo, mirroring how churn-dataplane's orchestrator writes the
# header first. Without this, a baseline failure on the first combo would have the
# fallback create a degenerate 3-line preamble (ISTIO_VERSION/HARNESS_SHA/KUBE_VERSIONS
# missing); because 002 guards its real preamble on `! -f`, a later successful final
# would NOT backfill it, and 004 would report ISTIO_VERSION=unknown for the whole
# sweep (PL2/PL19/PL26 loss). With the file pre-created, both 002 and the failed-row
# emitter just APPEND. Sweep-level scalars are correct; per-combo varying keys
# (SIDECAR_SCOPING/SERVICE_COUNT/...) are recorded as the sweep CSV (004 collects
# SIDECAR_SCOPING across all files anyway).
precreate_tsv_preamble() {
	local tsv="${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv"
	[[ -f "$tsv" ]] && grep -q '^timestamp' "$tsv" 2>/dev/null && return 0
	mkdir -p "$OUTPUT_DIR"
	local harness kver
	harness="$(harness_sha)"
	kver="$(probe_kube_versions "$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}")"
	# #45: capacity provenance. 003 now owns the preamble, so it must write the same
	# capacity-legibility lines 002 used to (002 skips its block once the file exists).
	# Read-only, source-context only; cap_*.sh tolerates failure -> `unknown`. These
	# are the report's denominators for the "Achieved scale vs capacity" block and they
	# read fine via get nodes / get deploy (independent of the metrics API; cf #44).
	local src_ctx="${CONTEXTS[0]}"
	local node_alloc_cpu_m="unknown" node_alloc_mem_mi="unknown"
	local istiod_cpu_limit_m="unknown" istiod_mem_limit_mi="unknown"
	local kv
	# shellcheck disable=SC2207
	local -a nt_kv=($(cap_node_totals "$src_ctx" "${KUBECTL[@]}"))
	for kv in "${nt_kv[@]}"; do
		case "$kv" in
			cpu_m=*) node_alloc_cpu_m="${kv#cpu_m=}" ;;
			mem_mi=*) node_alloc_mem_mi="${kv#mem_mi=}" ;;
		esac
	done
	# shellcheck disable=SC2207
	local -a il_kv=($(cap_istiod_limits "$src_ctx" "${KUBECTL[@]}"))
	for kv in "${il_kv[@]}"; do
		case "$kv" in
			cpu_m=*) istiod_cpu_limit_m="${kv#cpu_m=}" ;;
			mem_mi=*) istiod_mem_limit_mi="${kv#mem_mi=}" ;;
		esac
	done
	# Cluster-infra block (additive): node allocatable, istiod req/lim/replicas,
	# network topology. Collected read-only across --contexts; emitted via the ONE
	# shared infra_preamble_lines emitter so 002's `! -f`-guarded collector writes
	# the identical key set (PL36). 002 reads INFRA_KV the same way (env_collect_infra).
	local infra_kv
	infra_kv="$(env_collect_infra "$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}")"
	# Resolved tuning-baseline state, queried from the LIVE source cluster (NOT
	# chart defaults — a live/Argo override can diverge). PL2: sweep-wide scalar
	# (the baseline is constant across all combos of one sweep), so it joins the
	# capacity provenance block as a per-sweep scalar (PL26 classification).
	# tuning_baseline_state emits two `KEY=VALUE` lines; degrades to `unknown`.
	local tb_line="TUNING_BASELINE=unknown" eh_line="SIDECAR_EGRESS_HOSTS=unknown"
	local tb_kv
	while IFS= read -r tb_kv; do
		case "$tb_kv" in
			TUNING_BASELINE=*) tb_line="$tb_kv" ;;
			SIDECAR_EGRESS_HOSTS=*) eh_line="$tb_kv" ;;
		esac
	done < <(tuning_baseline_state "$src_ctx" "${KUBECTL[@]}")
	{
		echo "# Control-plane resource metrics — $(date -u -Iseconds)"
		echo "# CONTROLPLANE_SCHEMA=40"
		echo "# CONTROLPLANE_INFRA_SCHEMA=1"
		echo "# ISTIO_VERSION=${ISTIO_VERSION:-unknown}"
		echo "# HARNESS_SHA=${harness}"
		echo "# KUBE_VERSIONS=${kver}"
		echo "# SETTLE_SEC=${SETTLE_SEC}"
		echo "# RUN_ID=${RUN_ID}"
		echo "# PHASE=sweep"
		echo "# SIDECAR_SCOPING=${SIDECAR_SCOPINGS_CSV}"
		echo "# CONFIG_DUMP_SAMPLES=${CONFIG_DUMP_SAMPLES}"
		echo "# NODE_ALLOC_CPU_M=${node_alloc_cpu_m}"
		echo "# NODE_ALLOC_MEM_MI=${node_alloc_mem_mi}"
		echo "# ISTIOD_CPU_LIMIT_M=${istiod_cpu_limit_m}"
		echo "# ISTIOD_MEM_LIMIT_MI=${istiod_mem_limit_mi}"
		echo "# SCALE_TARGET_FRACTION=${SCALE_TARGET_FRACTION:-unknown}"
		echo "# SCALE_SIZING_MODE=${SCALE_SIZING_MODE:-unknown}"
		echo "# ${tb_line}"
		echo "# ${eh_line}"
		echo "# METRICS_API=${METRICS_API_STATUS:-unknown}"
		# shellcheck disable=SC2086
		infra_preamble_lines $infra_kv
		echo "# NOTE=preamble pre-created by 003-run-sweep.sh so provenance survives a first-combo setup/baseline failure"
		echo "# Contexts: ${CONTEXTS[*]}  Mesh sizes: ${MESH_SIZES[*]}  Services: ${SERVICE_COUNTS_CSV}  Replicas: ${REPLICA_COUNTS_CSV}  Namespaces: ${NAMESPACE_COUNTS_CSV}  Scopings: ${SIDECAR_SCOPINGS_CSV}"
	} > "$tsv"
	echo -e "$CONTROLPLANE_TSV_HEADER" >> "$tsv"
}

# P0-h: pre-run capacity WARN (FINDING #3 arithmetic as a runtime guard). For the
# LARGEST planned combo, estimate the per-cluster sidecar-CPU request and compare it
# to free node CPU (node allocatable − istiod baseline). The dominant data-plane
# capacity driver is the per-proxy sidecar CPU request × workload count, NOT istiod;
# at the fixed-3-node rig this caps at ~40-46 services/cluster. This is a WARN only
# (the existing per-context preflight in 001 is the hard gate); it surfaces the
# ceiling at plan time so an operator can hand-cap --service-counts before burning a
# multi-hour sweep. Uses SCALE_PER_POD_CPU_M (config/options.env) — never hardcoded.
#
# Dry-run NEVER contacts a cluster (AGENTS --dry-run rule): it prints only the
# REQUESTED cores (which need no cluster). The free-capacity comparison + services-
# that-fit estimate run only on the real plan path, reading the same cap_node_totals
# / cap_istiod_limits the preamble uses (source context, read-only).
capacity_plan_warn() {
	local per_pod_cpu_m="${SCALE_PER_POD_CPU_M:-200}"
	# Largest combo: max service_count × max replica_count.
	local max_sc=0 max_rc=0 v
	for v in "${SERVICE_COUNTS[@]}"; do (( v > max_sc )) && max_sc="$v"; done
	for v in "${REPLICA_COUNTS[@]}"; do (( v > max_rc )) && max_rc="$v"; done
	local needed_pods=$(( max_sc * max_rc ))
	local needed_cpu_m=$(( needed_pods * per_pod_cpu_m ))
	echo "--- Capacity plan check (largest combo: ${max_sc} svc × ${max_rc} rep) ---" >&2
	echo "  requested: ${needed_pods} sidecar-pods × ${per_pod_cpu_m}m = ~$(( needed_cpu_m / 1000 )) cores/cluster (SCALE_PER_POD_CPU_M=${per_pod_cpu_m})" >&2

	if ((DRY_RUN)); then
		echo "  WARN: dry-run does not contact clusters; free-capacity comparison skipped. Run without --dry-run for the services-that-fit estimate." >&2
		echo "" >&2
		return 0
	fi
	(( ${#KUBECTL[@]} )) || { echo "  WARN: no oc/kubectl; cannot read node capacity for the fit estimate." >&2; echo "" >&2; return 0; }

	local src_ctx="${CONTEXTS[0]}" alloc_cpu_m="" istiod_cpu_m="" istiod_rep="" kv
	# shellcheck disable=SC2207
	local -a nt=($(cap_node_totals "$src_ctx" "${KUBECTL[@]}"))
	for kv in "${nt[@]}"; do case "$kv" in cpu_m=*) alloc_cpu_m="${kv#cpu_m=}" ;; esac; done
	# shellcheck disable=SC2207
	local -a il=($(cap_istiod_limits "$src_ctx" "${KUBECTL[@]}"))
	for kv in "${il[@]}"; do
		case "$kv" in
			cpu_m=*) istiod_cpu_m="${kv#cpu_m=}" ;;
			replicas=*) istiod_rep="${kv#replicas=}" ;;
		esac
	done
	if ! [[ "$alloc_cpu_m" =~ ^[0-9]+$ ]]; then
		echo "  WARN: node allocatable CPU unreadable on $src_ctx; cannot estimate services-that-fit." >&2
		echo "" >&2
		return 0
	fi
	# istiod baseline = per-replica istiod CPU limit × replicas (the aggregate control-
	# plane reservation on the cluster). Unknown istiod limit -> baseline 0 (conservative
	# overstate of free CPU; still flags the gross over-provision case).
	local istiod_baseline_m=0
	if [[ "$istiod_cpu_m" =~ ^[0-9]+$ && "$istiod_rep" =~ ^[0-9]+$ ]]; then
		istiod_baseline_m=$(( istiod_cpu_m * istiod_rep ))
	fi
	local free_cpu_m=$(( alloc_cpu_m - istiod_baseline_m ))
	(( free_cpu_m < 0 )) && free_cpu_m=0
	local max_services=0
	if (( max_rc > 0 && per_pod_cpu_m > 0 )); then
		max_services=$(( free_cpu_m / (max_rc * per_pod_cpu_m) ))
	fi
	echo "  node alloc CPU: ~$(( alloc_cpu_m / 1000 )) cores; istiod baseline: ~$(( istiod_baseline_m / 1000 )) cores (${istiod_cpu_m:-unknown}m × ${istiod_rep:-unknown} rep) -> ~$(( free_cpu_m / 1000 )) cores free" >&2
	if (( needed_cpu_m > free_cpu_m )); then
		echo "  WARN: combo needs ~$(( needed_cpu_m / 1000 )) cores/cluster, ~$(( free_cpu_m / 1000 )) free -> ~${max_services} services max (at ${max_rc} replicas). Reduce --service-counts to <= ${max_services}, add nodes, or expect FailedScheduling/SETUP_FAILED on the largest combo." >&2
	else
		echo "  OK: largest combo fits (~$(( needed_cpu_m / 1000 )) needed <= ~$(( free_cpu_m / 1000 )) free; ~${max_services} services would fit at ${max_rc} replicas)." >&2
	fi
	echo "" >&2
}

# #44 prevention: metrics-API readiness gate. The O9 utilization-% columns are
# sourced from `kubectl top` (metrics API), a path independent of the istiod
# /metrics the sweep measures; a transient metrics-server outage (e.g. still
# stabilizing right after a cluster/operator restart) silently N/As them for the
# whole run. Before the loop, poll every context until `top nodes` serves data,
# bounded by METRICS_READY_TIMEOUT. Records the verdict in METRICS_API_STATUS (which
# precreate_tsv_preamble writes as `# METRICS_API=`) and WARNs — NEVER aborts
# (utilization is observability, not the core measurement). METRICS_READY_TIMEOUT=0
# disables the gate (status stays `unknown`, behaviour as before this change).
metrics_preflight() {
	local timeout="${METRICS_READY_TIMEOUT:-120}" interval="${METRICS_READY_INTERVAL:-10}"
	if (( timeout <= 0 )); then
		echo "Metrics-API preflight: disabled (METRICS_READY_TIMEOUT=0)." >&2
		METRICS_API_STATUS="unknown"
		return 0
	fi
	local deadline=$(( SECONDS + timeout ))
	local -a pending=("${CONTEXTS[@]}")
	echo "Metrics-API preflight: probing 'kubectl top nodes' on ${#pending[@]} context(s) (timeout ${timeout}s)..." >&2
	while :; do
		local -a still=()
		local ctx
		for ctx in "${pending[@]}"; do
			[[ "$(cap_metrics_ready "$ctx" "${KUBECTL[@]}")" == ready ]] || still+=("$ctx")
		done
		pending=("${still[@]}")
		(( ${#pending[@]} == 0 )) && break
		(( SECONDS >= deadline )) && break
		echo "  metrics not ready on ${#pending[@]} context(s): ${pending[*]}; retrying in ${interval}s..." >&2
		sleep "$interval"
	done
	if (( ${#pending[@]} == 0 )); then
		METRICS_API_STATUS="available"
		echo "  metrics API available on all contexts." >&2
	else
		local csv; csv=$(IFS=,; echo "${pending[*]}")
		METRICS_API_STATUS="unavailable:${csv}"
		echo "  WARN: metrics API unavailable on ${csv} after ${timeout}s." >&2
		echo "  WARN: utilization-% columns (istiod_*_pct_of_limit, node_*_pct) will be N/A for combos on those contexts;" >&2
		echo "  WARN: the run PROCEEDS (utilization is observability) — verify metrics-server and re-run if you need utilization-%." >&2
	fi
}

# P0/PL15: a per-combo setup OR probe failure must be RECORDED (counted in the
# report's n_total) and the sweep must CONTINUE — never abort the multi-hour run. The
# control-plane report (004) counts every NF>=40 row in n_total and only admits a
# row to n_valid when istiod_restarted ($31) == "0", so a degraded row with
# $31=unknown and N/A numerics is counted-but-excluded (PL13/PL15). The TSV is
# pre-created with the full preamble (see precreate_tsv_preamble), so this only
# appends. <status> is PROBE_FAILED or SETUP_FAILED.
emit_failed_row() {
	local status="$1" ms="$2" sc="$3" rc="$4" nc="$5" scp="$6"
	local tsv="${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv"
	# Defensive: ensure header exists (pre-create runs before the loop, but keep this
	# idempotent guard so a row is never written into a header-less file).
	if ! grep -q '^timestamp' "$tsv" 2>/dev/null; then
		precreate_tsv_preamble
	fi
	# Degraded row: 40 cols, key cols populated, context column carries the status
	# sentinel, restarted=unknown (column 31) so the report excludes it from n_valid;
	# every numeric column N/A per PL13 (including push-by-type, config samples, and the
	# O9 capacity cols 35-40 — nothing was measured, so 0/0/0 would be a misleading
	# literal).
	echo -e "$(date -u -Iseconds)\t${status}\t${ms}\t${sc}\t${rc}\t${nc}\t${scp}\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t${SETTLE_SEC}\tunknown\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A" >> "$tsv"
}

{
	echo "=========================================="
	echo "  Control-Plane Resource Sweep"
	echo "=========================================="
	echo "Contexts:          ${CONTEXTS[*]}"
	echo "Mesh sizes:        ${MESH_SIZES[*]}"
	echo "Service counts:    ${SERVICE_COUNTS[*]}"
	echo "Replica counts:    ${REPLICA_COUNTS[*]}"
	echo "Namespace counts:  ${NAMESPACE_COUNTS[*]}"
	echo "Sidecar scopings:  ${SCOPINGS[*]}"
	echo "Config-dump samples: ${CONFIG_DUMP_SAMPLES}"
	echo "Settle time:       ${SETTLE_SEC}s"
	echo "Run ID:            ${RUN_ID}"
	echo "Output:            ${OUTPUT_DIR}"
	echo ""
	echo "Planned matrix:    ${MATRIX_SIZE} = ${#MESH_SIZES[@]}×${#SERVICE_COUNTS[@]}×${#REPLICA_COUNTS[@]}×${#NAMESPACE_COUNTS[@]}×${#SCOPINGS[@]} (mesh × svc × rep × ns × scope)"
	echo ""
} >&2

if ((MATRIX_SIZE > MAX_MATRIX)) && ! ((FORCE_LARGE_MATRIX)); then
	die "matrix size $MATRIX_SIZE = ${#MESH_SIZES[@]}×${#SERVICE_COUNTS[@]}×${#REPLICA_COUNTS[@]}×${#NAMESPACE_COUNTS[@]}×${#SCOPINGS[@]} exceeds safety limit $MAX_MATRIX; re-run with --force-large-matrix to proceed"
fi

if command -v oc >/dev/null 2>&1; then
	KUBECTL=(oc)
elif command -v kubectl >/dev/null 2>&1; then
	KUBECTL=(kubectl)
else
	KUBECTL=()
fi

# P0-h capacity gate: print the plan-time capacity WARN (dry-run-safe: no cluster
# contact in dry-run). Placed after KUBECTL resolution so the live read path works.
capacity_plan_warn

if ((DRY_RUN)); then
	echo "--- Combinations (dry-run) ---" >&2
fi

fmt_ns_pattern() {
	local nc="$1"
	if (( nc <= 1 )); then
		printf '%s\n' "$NS"
	else
		printf '%s-0..%s-%d\n' "$NS" "$NS" "$(( nc - 1 ))"
	fi
}

ensure_output_dir() {
	[[ -d "$OUTPUT_DIR" ]] && return 0
	mkdir -p "$OUTPUT_DIR"
	echo "Output directory: $OUTPUT_DIR" >&2
}

# ---------------------------------------------------------------------------
# Background peak-memory poller for split-phase mode.
# ---------------------------------------------------------------------------
# Runs between the baseline and final 002 invocations, using the same port
# range (15014+k). Safe because 002-baseline has exited and freed its ports.
PEAK_POLLER_PID=""
PEAK_PF_PIDS=()
BASE_PF_PORT=15014
POLL_INTERVAL=5

start_peak_metrics_poller() {
	local state_dir="$1"
	local manifest="${state_dir}/pods.tsv"
	[[ -f "$manifest" ]] || return 0
	(( ${#KUBECTL[@]} )) || return 0

	local -a pod_ctxs=() pod_names=()
	while IFS=$'\t' read -r _idx ctx pod; do
		pod_ctxs+=("$ctx")
		pod_names+=("$pod")
	done < "$manifest"
	(( ${#pod_ctxs[@]} )) || return 0

	PEAK_PF_PIDS=()
	for k in "${!pod_ctxs[@]}"; do
		local port=$(( BASE_PF_PORT + k ))
		"${KUBECTL[@]}" --context="${pod_ctxs[k]}" -n istio-system \
			port-forward "pod/${pod_names[k]}" "$port":15014 >/dev/null 2>&1 &
		PEAK_PF_PIDS+=($!)
	done
	sleep 2

	(
		trap 'exit 0' TERM
		while true; do
			for k in "${!pod_ctxs[@]}"; do
				local port=$(( BASE_PF_PORT + k ))
				local body
				body=$(curl -s --max-time 3 "http://localhost:${port}/metrics" 2>/dev/null) || continue

				# Peak memory.
				local mem_val
				mem_val=$(echo "$body" | awk '/^process_resident_memory_bytes[{ ]/ && !/^#/ { print $NF+0 }')
				if [[ -n "$mem_val" && "$mem_val" != "0" ]]; then
					local prev_mem=0
					[[ -s "${state_dir}/peak-mem-${k}.val" ]] && prev_mem=$(<"${state_dir}/peak-mem-${k}.val")
					if awk -v a="$mem_val" -v b="$prev_mem" 'BEGIN{ exit !(a+0 > b+0) }'; then
						printf '%s' "$mem_val" > "${state_dir}/peak-mem-${k}.val"
					fi
				fi

				# Peak CPU rate (millicores over this interval).
				local cpu_val
				cpu_val=$(echo "$body" | awk '/^process_cpu_seconds_total[{ ]/ && !/^#/ { print $NF+0 }')
				if [[ -n "$cpu_val" && "$cpu_val" != "0" ]]; then
					local prev_cpu_file="${state_dir}/prev-cpu-${k}.val"
					if [[ -s "$prev_cpu_file" ]]; then
						local prev_cpu
						prev_cpu=$(<"$prev_cpu_file")
						local rate_m
						rate_m=$(awk -v c="$cpu_val" -v p="$prev_cpu" -v iv="$POLL_INTERVAL" \
							'BEGIN{ d=(c-p)*1000/iv; if(d<0) d=0; printf "%.0f", d }')
						local prev_peak=0
						[[ -s "${state_dir}/peak-cpu-${k}.val" ]] && prev_peak=$(<"${state_dir}/peak-cpu-${k}.val")
						if awk -v a="$rate_m" -v b="$prev_peak" 'BEGIN{ exit !(a+0 > b+0) }'; then
							printf '%s' "$rate_m" > "${state_dir}/peak-cpu-${k}.val"
						fi
					fi
					printf '%s' "$cpu_val" > "$prev_cpu_file"
				fi
			done
			sleep "$POLL_INTERVAL"
		done
	) &
	PEAK_POLLER_PID=$!
}

stop_peak_metrics_poller() {
	if [[ -n "$PEAK_POLLER_PID" ]]; then
		kill "$PEAK_POLLER_PID" 2>/dev/null || true
		wait "$PEAK_POLLER_PID" 2>/dev/null || true
		PEAK_POLLER_PID=""
	fi
	for pid in "${PEAK_PF_PIDS[@]}"; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	PEAK_PF_PIDS=()
}

trap 'stop_peak_metrics_poller 2>/dev/null || true' EXIT

# B4: pre-create the TSV with the full preamble before any combo runs (skipped in
# dry-run — probe_kube_versions would touch clusters). Guarantees provenance even if
# the very first combo's setup/baseline fails.
if ((! DRY_RUN)); then
	metrics_preflight
	precreate_tsv_preamble
fi

combo_idx=0
for ms in "${MESH_SIZES[@]}"; do
	active_ctxs=("${CONTEXTS[@]:0:$ms}")
	active_csv=$(IFS=,; echo "${active_ctxs[*]}")
	for sc in "${SERVICE_COUNTS[@]}"; do
		for rc in "${REPLICA_COUNTS[@]}"; do
			for nc in "${NAMESPACE_COUNTS[@]}"; do
				for scp in "${SCOPINGS[@]}"; do
					combo_idx=$((combo_idx + 1))
					label="mesh=$ms svcs=$sc reps=$rc ns=$nc scope=$scp"
					ns_pattern=$(fmt_ns_pattern "$nc")

					if ((DRY_RUN)); then
						printf "  [%2d/%2d] %s  (clusters: %s)  Namespaces: %s\n" \
							"$combo_idx" "$MATRIX_SIZE" "$label" "${active_ctxs[*]}" "$ns_pattern" >&2
						continue
					fi

					ensure_output_dir

					echo "=========================================="
					printf "  Sweep [%d/%d]: %s\n" "$combo_idx" "$MATRIX_SIZE" "$label"
					echo "  Clusters:   ${active_ctxs[*]}"
					echo "  Namespaces: ${ns_pattern}"
					echo "=========================================="
					echo ""

					STATE_DIR_COMBO="${OUTPUT_DIR}/state-combo-${combo_idx}"
					mkdir -p "$STATE_DIR_COMBO"

					echo "--- Baseline metrics scrape (phase 1/3) ---"
					if ! "$SCRIPT_DIR/002-collect-resource-metrics.sh" \
						--phase baseline \
						--state-dir "$STATE_DIR_COMBO" \
						--contexts "$active_csv" \
						--mesh-size "$ms" \
						--service-count "$sc" \
						--replicas "$rc" \
						--namespace-count "$nc" \
						--sidecar-scoping "$scp" \
						--settle "$SETTLE_SEC"; then
						# P0: baseline probe failed — record a degraded combo and move on
						# (never abort the sweep). The final phase is skipped (its state-dir
						# baseline is missing/partial). Best-effort cleanup before continue.
						echo "warn: [$combo_idx/$MATRIX_SIZE] baseline probe failed for '$label'; recording PROBE_FAILED row and continuing" >&2
						emit_failed_row PROBE_FAILED "$ms" "$sc" "$rc" "$nc" "$scp"
						"$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
							echo "warn: cleanup after baseline failure also reported failure for '$label'" >&2
						rm -rf "$STATE_DIR_COMBO"
						if (( SETTLE_SEC > 0 )); then sleep "$SETTLE_SEC"; fi
						continue
					fi
					echo ""

					start_peak_metrics_poller "$STATE_DIR_COMBO"

					echo "--- Deploying workloads (phase 2/3, scoping=$scp) ---"
					# B1: setup is the MOST probable per-combo failure at scale (helm
					# template|apply + label-selector waits across ~50 PFs). Bare under
					# set -e it would abort the whole sweep AND leak the background peak
					# poller started just above. So: stop the poller, record a SETUP_FAILED
					# row (n_total++, excluded from n_valid), clean up, settle, continue.
					if ! "$SCRIPT_DIR/001-setup-controlplane-test.sh" \
						--contexts "$active_csv" \
						--service-count "$sc" \
						--replicas "$rc" \
						--namespace-count "$nc" \
						--sidecar-scoping "$scp"; then
						echo "warn: [$combo_idx/$MATRIX_SIZE] setup failed for '$label'; recording SETUP_FAILED row and continuing" >&2
						stop_peak_metrics_poller   # MUST stop before continue — poller runs in background
						emit_failed_row SETUP_FAILED "$ms" "$sc" "$rc" "$nc" "$scp"
						"$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
							echo "warn: cleanup after setup failure also reported failure for '$label'" >&2
						rm -rf "$STATE_DIR_COMBO"
						if (( SETTLE_SEC > 0 )); then sleep "$SETTLE_SEC"; fi
						continue
					fi
					echo ""

					if (( SETTLE_SEC > 0 )); then
						echo "--- Settling ${SETTLE_SEC}s for steady-state before final scrape ---"
						sleep "$SETTLE_SEC"
						echo ""
					fi

					stop_peak_metrics_poller

					echo "--- Final metrics scrape + emit (phase 3/3) — window covers baseline → deploy → settle ---"
					if ! "$SCRIPT_DIR/002-collect-resource-metrics.sh" \
						--phase final \
						--state-dir "$STATE_DIR_COMBO" \
						--contexts "$active_csv" \
						--mesh-size "$ms" \
						--service-count "$sc" \
						--replicas "$rc" \
						--namespace-count "$nc" \
						--sidecar-scoping "$scp" \
						--config-dump-samples "$CONFIG_DUMP_SAMPLES" \
						--settle "$SETTLE_SEC" \
						--output-dir "$OUTPUT_DIR" \
						--run-id "$RUN_ID"; then
						# P0: final probe failed AFTER the deploy storm — the window is lost
						# for this combo, but the workload exists, so still record + clean up
						# + continue. (The probe may have emitted partial per-pod rows before
						# failing; this fallback guarantees at least one combo row in n_total.)
						echo "warn: [$combo_idx/$MATRIX_SIZE] final probe failed for '$label'; recording PROBE_FAILED row and continuing" >&2
						emit_failed_row PROBE_FAILED "$ms" "$sc" "$rc" "$nc" "$scp"
					fi
					rm -rf "$STATE_DIR_COMBO"
					echo ""

					echo "--- Cleaning up ---"
					# P0/PL23: a cleanup hiccup must not abort the sweep — the next combo's
					# setup also cleans the namespace, and the await-delete loop below is
					# already non-fatal. Warn and continue past the combo.
					"$SCRIPT_DIR/005-cleanup.sh" --contexts "$active_csv" || \
						echo "warn: [$combo_idx/$MATRIX_SIZE] cleanup reported failure for '$label'; next combo's setup will re-clean" >&2

					if (( ${#KUBECTL[@]} )); then
						wait_pids=()
						for ctx in "${active_ctxs[@]}"; do
							"${KUBECTL[@]}" --context="$ctx" wait --for=delete \
								namespace -l app.kubernetes.io/instance=controlplane-test \
								--timeout=300s >/dev/null 2>&1 &
							wait_pids+=($!)
						done
						for pid in "${wait_pids[@]}"; do
							wait "$pid" 2>/dev/null || true
						done
					fi

					# Post-cleanup settle: when 005 deletes the test namespace,
					# istiod re-pushes a broader (no-Sidecar) config to remaining
					# proxies. Without this sleep, the next combo's baseline scrape
					# lands inside that push storm.
					if (( SETTLE_SEC > 0 )); then
						echo "--- Post-cleanup settle (${SETTLE_SEC}s) ---" >&2
						sleep "$SETTLE_SEC"
					fi
					echo ""
				done
			done
		done
	done
done

if ((DRY_RUN)); then
	echo "" >&2
	echo "Dry-run complete. $combo_idx combinations enumerated; no clusters touched." >&2
	exit 0
fi

echo "=========================================="
echo "  Sweep complete ($combo_idx combinations)"
echo "=========================================="
echo ""
echo "Generating report..."
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$OUTPUT_DIR"

MD_FILE="${OUTPUT_DIR}/sweep-${RUN_ID}.md"
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$OUTPUT_DIR" --format markdown > "$MD_FILE"
echo "Markdown summary written to $MD_FILE"

CHARTS_FILE="${OUTPUT_DIR}/sweep-charts-${RUN_ID}.md"
"$SCRIPT_DIR/004-report-results.sh" --results-dir "$OUTPUT_DIR" --format charts > "$CHARTS_FILE"
echo "Charts written to $CHARTS_FILE"

# Campaign scale envelope (read-only addition; never touches the measurement path).
# Generated, not hand-transcribed (docs/campaigns/TEMPLATE.md). Best-effort: a render
# failure (e.g. report produced no JSON) must NOT fail the sweep — the data is already
# safely written above. Reads the per-sweep dir only (PL6).
ENVELOPE_FILE="${OUTPUT_DIR}/scale-envelope-${RUN_ID}.md"
# B1: capture the render's stderr so its SPECIFIC die reason (results dir missing /
# report produced no JSON / report not executable) survives onto the warning path —
# this is the headline customer artifact, so swallowing the cause with a blanket
# 2>/dev/null and asserting a possibly-wrong reason is exactly the wrong place to be terse.
ENVELOPE_ERR="$(mktemp)"
# Run in a SUBSHELL: render_scale_envelope's preconditions use die() (exit 1), which
# in a direct call would abort THIS script — defeating the best-effort intent. The
# subshell contains the exit so a render failure becomes a non-zero `if` branch (warn +
# preserve the sweep data) instead of killing the sweep at the very end.
if ( render_scale_envelope "$OUTPUT_DIR" "$SCRIPT_DIR/004-report-results.sh" \
		"$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}" ) > "$ENVELOPE_FILE" 2>"$ENVELOPE_ERR"; then
	echo "Scale envelope written to $ENVELOPE_FILE"
else
	rm -f "$ENVELOPE_FILE"
	echo "warning: scale-envelope generation failed (sweep data is safe above):" >&2
	sed 's/^/  /' "$ENVELOPE_ERR" >&2
fi
rm -f "$ENVELOPE_ERR"

#!/usr/bin/env bash
# Measure intra-cluster (sidecar-to-sidecar) and cross-cluster data-plane
# latency and throughput using fortio.
#
# Local baseline target:    http://dataplane-server-${source_ctx}.${NS}.svc.cluster.local
# Cross-cluster targets:    http://dataplane-server-${remote_ctx}.${NS}.svc.cluster.local
# Each per-cluster Service selects only that cluster's server pod, so the local
# target stays in-cluster and remote targets cross the east-west gateway.
#
# Each cell is a single sample. Rerun the sweep to get multiple samples.
# The local baseline is NOT a no-mesh baseline: both endpoints have sidecars.
# A run that does not deliver its target QPS is tagged QPS_SHORTFALL, not OK, so
# a saturated server cannot pass for a valid low-latency sample.
#
# Before the load, a remote reachability check (tests/lib/reach.sh) sends a few
# requests to every target and writes reach-<RUN_ID>.tsv. A remote with no HTTP
# 200 at all is UNREACHABLE: its load is skipped and its rows say so. Under
# --on-unreachable fail, an UNREACHABLE or UNKNOWN remote stops the run before any
# load (exit 3).
#
# Usage:
#   ./tests/dataplane/002-run-latency-probe.sh --source-context CTX [options]
#
# Examples:
#   # Baseline + cross-cluster latency:
#   ./tests/dataplane/002-run-latency-probe.sh --source-context <mesh-a-ctx> --remote-contexts <mesh-b-ctx>
#
#   # Custom QPS levels and duration:
#   ./tests/dataplane/002-run-latency-probe.sh --source-context <mesh-a-ctx> \
#     --remote-contexts <mesh-b-ctx> --qps-levels 10,100,1000 --duration 60
#
#   # QPS levels, durations, thresholds and results dir from a run config:
#   ./tests/dataplane/002-run-latency-probe.sh --config tests/dataplane/configs/smoke.env \
#     --source-context <mesh-a-ctx> --remote-contexts <mesh-b-ctx>
# ci-dry-run: --source-context ci-dummy
set -euo pipefail
# Loud ERR trap for unexpected aborts.
trap 'rc=$?; echo "FATAL: ${0##*/} aborted (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # config_preload, config_preamble_lines
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
config_preload dataplane "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/timestamp.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/platform.sh"  # platform_probe, platform_preamble_lines (the platform record)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/metrics.sh"  # extract_gauge (used by fanout_restart_status)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fanout.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fortio.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/reach.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/istiod-diag.sh"  # istiod_diag_capture (restart evidence)

SOURCE_CTX=""
REMOTE_CONTEXTS_CSV=""
MESH_SIZE=""
QPS_LEVELS="${DATAPLANE_QPS_LEVELS:-10,100,500,1000}"
DURATION="${DATAPLANE_DURATION_SEC:-30}"
CONNECTIONS="${DATAPLANE_NUM_CONNECTIONS:-8}"
SETTLE_SEC="${DATAPLANE_SETTLE_SEC:-30}"
WARMUP_DURATION="${DATAPLANE_WARMUP_DURATION_SEC:-5}"
MIN_QPS_RATIO="${DATAPLANE_MIN_QPS_RATIO:-0.95}"
MIN_PCT_200="${DATAPLANE_MIN_PCT_200:-0.99}"
ON_UNREACHABLE="${REACH_ON_UNREACHABLE:-warn}"
REACH_REQUESTS="${REACH_REQUESTS:-10}"
OUTPUT_DIR="$(config_repo_path "${DATAPLANE_RESULTS_DIR}")"
DRY_RUN=0
# Live tuning-baseline provenance; 003 passes it in, standalone runs record "unknown".
TUNING_BASELINE="unknown"
SIDECAR_EGRESS_HOSTS="unknown"
NS="${DATAPLANE_TEST_NAMESPACE:-dataplane-test}"
FORTIO_TAG="$FORTIO_VERSION"
FORTIO_IMAGE_REPO="fortio/fortio"


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE            Run config of KEY=value lines (config/options.env keys; see
                           tests/dataplane/README.md, "Run config").
                           Precedence: flag > --config > environment > default.
  --source-context CTX     Kube context for the fortio client (required).
  --remote-contexts CSV    Remote cluster contexts (comma-separated).
  --mesh-size N            Metadata tag for TSV (default: 1 + remotes).
  --qps-levels CSV         QPS levels to test (default: $QPS_LEVELS).
  --duration SEC           Duration per QPS level (default: $DURATION).
  --connections N          Concurrent connections (default: $CONNECTIONS).
  --settle SEC             Seconds to sleep before probing (default: $SETTLE_SEC).
  --warmup-duration SEC    Envoy upstream warmup duration, 0 to disable (default: $WARMUP_DURATION).
  --min-qps-ratio R        Tag a row QPS_SHORTFALL when actual QPS < R x target QPS;
                           a decimal in (0,1] (default: $MIN_QPS_RATIO).
  --on-unreachable POLICY  warn: record a remote the reach check cannot reach and go
                           on; fail: stop before any load when a remote is
                           UNREACHABLE or UNKNOWN, exit 3 (default: $ON_UNREACHABLE).
  --reach-requests N       Requests per target in the reach check; 0 turns it off
                           (default: $REACH_REQUESTS).
  --output-dir DIR         Results directory (default: ${DATAPLANE_RESULTS_DIR}).
  --tuning-baseline STR    Live tuning-baseline levers for the TSV preamble
                           (default: unknown; the sweep queries + threads this).
  --sidecar-egress-hosts STR  Live root-Sidecar egress hosts for the TSV preamble
                           (default: unknown; the sweep queries + threads this).
  --dry-run                Show plan without executing.
  -h, --help               Show this help.

Reach check: after the settle and before the warmup, the client sends
--reach-requests requests to every target and writes reach-<RUN_ID>.tsv
(reach_status REACHABLE, DEGRADED, UNREACHABLE or UNKNOWN per target, re-checked
up to REACH_ATTEMPTS times). An UNREACHABLE remote skips its warmup and load.

istiod restarts are detected on every context by port-forwarding each Running
istiod pod before and after the load runs (process_start_time_seconds or a
changed pod set -> istiod_restarted=1 on every row).

Row status (TSV column 'status'), first match wins:
  UNREACHABLE         the reach check got no HTTP 200 from this remote; no load ran
  FAILED              the fortio exec failed
  PERCENTILE_MISSING  p50/p90/p99/p99.9 missing from the fortio JSON
  ERROR_RATE_HIGH     share of HTTP 200s below DATAPLANE_MIN_PCT_200 (default: $MIN_PCT_200),
                      or no responses at all
  QPS_SHORTFALL       actual QPS below --min-qps-ratio x target QPS (target not delivered)
  OK
The report counts only OK rows with istiod_restarted=0 as valid. The console line
of each row also shows ret_codes (HTTP code=count; -1 is a socket error).
Under --on-unreachable fail a stopped run also writes one STOPPED_UNREACHABLE row
(target_class=na), so the report says why the local baseline is missing.

The load runs in the fortio client pod, not in the kubectl exec that starts it. A load
whose exec failed (a FAILED row, or a failed warmup) may run on there, so the probe
waits until its --duration (--warmup-duration for the warmup) and 5 s more have passed
before going on, unless the client pod is gone (deleted, or evicted and Failed: then no
load runs). When the probe ends during a load (a stop, Ctrl-C), it deletes the client
pod, so the load ends with it; the pod's Deployment starts a new one, which a sweep
started right after waits for (its setup 001 waits until the Deployments are Available).
Run by hand, the probe loads only a Ready client pod that is not being deleted, and
stops when there is none: run 001, or wait until the new pod is Ready.

Exit status: 0, 1 on an error, 3 when --on-unreachable fail stopped the run.

Environment:
  ISTIO_VERSION_CHECK (fail, the default, or warn): before any change, every member's
  Istio version (its active IstioRevision's) is read; one unknown, members that differ, a
  version other than ISTIO_VERSION, or a member still not ready stops the run, or under
  warn is warned about and recorded. ISTIO_VERSION_READY_WAIT_SEC (60): how long the one
  wait for members not ready may take.
  DATAPLANE_TEST_NAMESPACE, DATAPLANE_QPS_LEVELS, DATAPLANE_DURATION_SEC,
  DATAPLANE_NUM_CONNECTIONS, DATAPLANE_SETTLE_SEC, DATAPLANE_WARMUP_DURATION_SEC,
  DATAPLANE_MIN_QPS_RATIO, DATAPLANE_MIN_PCT_200,
  REACH_REQUESTS, REACH_QPS, REACH_HTTP_TIMEOUT_SEC, REACH_DETAIL_TIMEOUT_SEC,
  REACH_ATTEMPTS, REACH_RETRY_SEC,
  REACH_ON_UNREACHABLE,
  FORTIO_VERSION, METRICS_SCRAPE_TIMEOUT (istiod /metrics curl timeout, default 30),
  DATAPLANE_RESULTS_DIR (--output-dir; relative to the repo root).
EOF
}


while [[ $# -gt 0 ]]; do
	case "$1" in
	--config)
		# Loaded by config_preload above.
		[[ -n "${2:-}" ]] || die "--config requires a value"
		shift 2
		;;
	--source-context)
		[[ -n "${2:-}" ]] || die "--source-context requires a value"
		SOURCE_CTX="$2"
		shift 2
		;;
	--remote-contexts)
		[[ -n "${2:-}" ]] || die "--remote-contexts requires a value"
		REMOTE_CONTEXTS_CSV="$2"
		shift 2
		;;
	--mesh-size)
		[[ -n "${2:-}" ]] || die "--mesh-size requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--mesh-size must be a non-negative integer"
		MESH_SIZE="$2"
		shift 2
		;;
	--qps-levels)
		[[ -n "${2:-}" ]] || die "--qps-levels requires a value"
		QPS_LEVELS="$2"
		shift 2
		;;
	--duration)
		[[ -n "${2:-}" ]] || die "--duration requires a value"
		DURATION="$2"
		shift 2
		;;
	--connections)
		[[ -n "${2:-}" ]] || die "--connections requires a value"
		CONNECTIONS="$2"
		shift 2
		;;
	--settle)
		[[ -n "${2:-}" ]] || die "--settle requires a value"
		SETTLE_SEC="$2"
		shift 2
		;;
	--warmup-duration)
		[[ -n "${2:-}" ]] || die "--warmup-duration requires a value"
		WARMUP_DURATION="$2"
		shift 2
		;;
	--min-qps-ratio)
		[[ -n "${2:-}" ]] || die "--min-qps-ratio requires a value"
		MIN_QPS_RATIO="$2"
		shift 2
		;;
	--on-unreachable)
		[[ -n "${2:-}" ]] || die "--on-unreachable requires a value"
		ON_UNREACHABLE="$2"
		shift 2
		;;
	--reach-requests)
		[[ -n "${2:-}" ]] || die "--reach-requests requires a value"
		REACH_REQUESTS="$2"
		shift 2
		;;
	--output-dir)
		[[ -n "${2:-}" ]] || die "--output-dir requires a value"
		OUTPUT_DIR="$2"
		shift 2
		;;
	--tuning-baseline)
		[[ -n "${2:-}" ]] || die "--tuning-baseline requires a value"
		TUNING_BASELINE="$2"
		shift 2
		;;
	--sidecar-egress-hosts)
		[[ -n "${2:-}" ]] || die "--sidecar-egress-hosts requires a value"
		SIDECAR_EGRESS_HOSTS="$2"
		shift 2
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

platform_validate
[[ -n "$SOURCE_CTX" ]] || die "--source-context is required"
# The flag or its default (the environment, --config): checked once, before any cluster read.
is_pos_int "$DURATION" || die "--duration (or DATAPLANE_DURATION_SEC) must be a positive integer; got '$DURATION'"
is_nonneg_int "$WARMUP_DURATION" || die "--warmup-duration (or DATAPLANE_WARMUP_DURATION_SEC) must be a non-negative integer; got '$WARMUP_DURATION'"
is_pos_int "$CONNECTIONS" || die "--connections (or DATAPLANE_NUM_CONNECTIONS) must be a positive integer; got '$CONNECTIONS'"
is_nonneg_int "$SETTLE_SEC" || die "--settle (or DATAPLANE_SETTLE_SEC) must be a non-negative integer; got '$SETTLE_SEC'"
is_ratio "$MIN_QPS_RATIO" || die "--min-qps-ratio (or DATAPLANE_MIN_QPS_RATIO) must be a decimal in (0,1]; got '$MIN_QPS_RATIO'"
is_ratio "$MIN_PCT_200" || die "DATAPLANE_MIN_PCT_200 must be a decimal in (0,1]; got '$MIN_PCT_200'"
reach_msg="$(reach_validate "$ON_UNREACHABLE")" || die "$reach_msg"

KUBECTL=()
resolve_kubectl KUBECTL
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
command -v curl >/dev/null 2>&1 || die "curl not found on PATH"

REMOTES=()
if [[ -n "$REMOTE_CONTEXTS_CSV" ]]; then
	split_contexts "$REMOTE_CONTEXTS_CSV" REMOTES --remote-contexts "$SOURCE_CTX"
fi
# The source and its remotes, each under a name of its own in the platform record
# (platform_members_check): refused here, before any cluster call, in a --dry-run too.
platform_members_check "$SOURCE_CTX" ${REMOTES[@]+"${REMOTES[@]}"}

QPS_ARR=()
split_csv "$QPS_LEVELS" QPS_ARR
((${#QPS_ARR[@]})) || die "--qps-levels resolved to empty list"
for q in "${QPS_ARR[@]}"; do
	[[ "$q" =~ ^[0-9]+$ ]] || die "qps level must be a positive integer: $q"
	(( q > 0 )) || die "qps level must be > 0: $q"
done

[[ -z "$MESH_SIZE" ]] && MESH_SIZE=$(( 1 + ${#REMOTES[@]} ))

ALL_CTXS=("$SOURCE_CTX" ${REMOTES[@]+"${REMOTES[@]}"})
# {ctx} is the per-cluster Service's context; reach.sh and the loops below fill it in.
URL_TEMPLATE="http://dataplane-server-{ctx}.${NS}.svc.cluster.local:8080/echo"
LOCAL_URL="${URL_TEMPLATE//\{ctx\}/${SOURCE_CTX}}"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
TSV_FILE="${OUTPUT_DIR}/latency-${RUN_ID}.tsv"
REACH_TSV="${OUTPUT_DIR}/reach-${RUN_ID}.tsv"

# Resolve metadata for preamble.
# harness_sha (tests/lib/common.sh): a harness with uncommitted changes reads
# <describe>-dirty; this probe's own results do not count.
HARNESS_SHA="$(harness_sha --exclude "$OUTPUT_DIR")"
FORTIO_IMAGE="${FORTIO_IMAGE_REPO}:${FORTIO_TAG}"

if ((DRY_RUN)); then
	echo "=== Dry-run: data-plane latency probe ==="
	echo "Source: $SOURCE_CTX | Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
	echo "QPS levels: ${QPS_ARR[*]} | Duration: ${DURATION}s | Connections: $CONNECTIONS | Settle: ${SETTLE_SEC}s"
	echo "Min QPS ratio: ${MIN_QPS_RATIO} | Min pct_200: ${MIN_PCT_200}"
	echo "Server replicas: queried live on: ${ALL_CTXS[*]}"
	echo "Local target:        ${LOCAL_URL}"
	for rc in ${REMOTES[@]+"${REMOTES[@]}"}; do
		echo "Cross-cluster target ($rc): http://dataplane-server-${rc}.${NS}.svc.cluster.local:8080/echo"
	done
	echo "istiod restart check: port-forward every Running istiod pod on: ${ALL_CTXS[*]}"
	reach_plan_line "$URL_TEMPLATE" "$SOURCE_CTX" "$REMOTE_CONTEXTS_CSV" "$ON_UNREACHABLE"
	exit 0
fi

mkdir -p "$OUTPUT_DIR"
KUBE_VERSIONS_CSV="$(probe_kube_versions "$(IFS=,; echo "${ALL_CTXS[*]}")" "${KUBECTL[@]}")"
# The Istio version the members run, before any load (inherited when 003 runs this
# probe; read here when it runs alone). ISTIO_VERSION_CHECK=fail stops on a mismatch.
istio_version_resolve "$(IFS=,; echo "${ALL_CTXS[*]}")" 0 "${KUBECTL[@]}"
# The platform record (tests/lib/platform.sh), before any load: inherited from 003, else read here.
platform_probe "$(IFS=,; echo "${ALL_CTXS[*]}")"

# server_replicas_csv: "<ctx>=<ready>/<spec>,..." for the dataplane-server
# Deployment on every context, read live and concurrently (PL39) before any load.
# A failed read gives "<ctx>=unknown"; readyReplicas is omitted while 0 pods are Ready.
server_replicas_csv() {
	local tmp i v out=""
	local -a pids=()
	tmp="$(mktemp -d)"
	for i in "${!ALL_CTXS[@]}"; do
		(
			v="$("${KUBECTL[@]}" --context="${ALL_CTXS[$i]}" -n "$NS" get deploy dataplane-server \
				--request-timeout=10s -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null)" || v=""
			[[ "$v" == /* ]] && v="0${v}"
			[[ "$v" =~ ^[0-9]+/[0-9]+$ ]] || v="unknown"
			printf '%s' "$v" > "${tmp}/${i}"
		) &
		pids+=($!)
	done
	for i in ${pids[@]+"${pids[@]}"}; do wait "$i" || true; done
	for i in "${!ALL_CTXS[@]}"; do
		v="unknown"
		[[ -s "${tmp}/${i}" ]] && v="$(<"${tmp}/${i}")"
		out+="${out:+,}${ALL_CTXS[$i]}=${v}"
	done
	rm -rf "$tmp"
	printf '%s\n' "$out"
}
SERVER_REPLICAS_CSV="$(server_replicas_csv)"
IFS=',' read -ra _sr_pairs <<<"$SERVER_REPLICAS_CSV"
for _sr in ${_sr_pairs[@]+"${_sr_pairs[@]}"}; do
	_v="${_sr##*=}"
	if [[ "$_v" == unknown ]]; then
		echo "warning: could not read dataplane-server replicas on ${_sr%=*} (SERVER_REPLICAS records unknown)" >&2
	elif [[ "${_v%/*}" != "${_v#*/}" ]]; then
		echo "warning: dataplane-server on ${_sr%=*} has only ${_v} replicas Ready; its rows run on less server capacity" >&2
	fi
done

PF_PIDS=()
ISTIOD_DIR="$(mktemp -d)"
tmp_tsv=""
# LOAD_POD: the client pod while a `fortio load` runs in it (the warmup, a window).
LOAD_POD=""
# Also on a SIGTERM the sweep forwards (sweep_step): bash runs the EXIT trap on a fatal
# signal it does not trap and still dies of it (143). tmp_tsv sits next to the TSV. A load
# still running in the client pod is stopped (fortio_client_stop).
cleanup_all() {
	local pid
	[[ -z "${LOAD_POD:-}" ]] || fortio_client_stop "$SOURCE_CTX" "$NS" "$LOAD_POD" "${KUBECTL[@]}"
	for pid in ${PF_PIDS[@]+"${PF_PIDS[@]}"}; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	rm -rf "$ISTIOD_DIR"
	rm -f "${tmp_tsv:-}"
}
trap cleanup_all EXIT

# Write TSV preamble.
{
	echo "# RUN_ID=${RUN_ID}"
	echo "# DATE=$(date -u -Iseconds)"
	echo "# HARNESS_SHA=${HARNESS_SHA}"
	istio_version_kv | sed 's/^/# /'
	echo "# KUBE_VERSIONS=${KUBE_VERSIONS_CSV}"
	echo "# FORTIO_IMAGE=${FORTIO_IMAGE}"
	echo "# SETTLE_SEC=${SETTLE_SEC}"
	echo "# WARMUP_DURATION_SEC=${WARMUP_DURATION}"
	echo "# QPS_LEVELS=${QPS_LEVELS}"
	echo "# DURATION_SEC=${DURATION}"
	echo "# CONNECTIONS=${CONNECTIONS}"
	echo "# SOURCE_CTX=${SOURCE_CTX}"
	echo "# REMOTE_CONTEXTS=${REMOTE_CONTEXTS_CSV}"
	echo "# MESH_SIZE=${MESH_SIZE}"
	echo "# NAMESPACE=${NS}"
	echo "# TUNING_BASELINE=${TUNING_BASELINE}"
	echo "# SIDECAR_EGRESS_HOSTS=${SIDECAR_EGRESS_HOSTS}"
	echo "# SERVER_REPLICAS=${SERVER_REPLICAS_CSV}"
	echo "# MIN_QPS_RATIO=${MIN_QPS_RATIO}"
	echo "# MIN_PCT_200=${MIN_PCT_200}"
	echo "# REACH_REQUESTS=${REACH_REQUESTS}"
	echo "# REACH_QPS=${REACH_QPS:-10}"
	echo "# REACH_HTTP_TIMEOUT_SEC=${REACH_HTTP_TIMEOUT_SEC:-3}"
	echo "# REACH_DETAIL_TIMEOUT_SEC=${REACH_DETAIL_TIMEOUT_SEC:-35}"
	echo "# REACH_ATTEMPTS=${REACH_ATTEMPTS:-3}"
	echo "# REACH_RETRY_SEC=${REACH_RETRY_SEC:-10}"
	echo "# ON_UNREACHABLE=${ON_UNREACHABLE}"
	config_preamble_lines
	platform_preamble_lines "$(IFS=,; echo "${ALL_CTXS[*]}")"
} > "$TSV_FILE"
# New TSV columns appended at the end of the old schema:
#   pct_200, istiod_restarted, target_class
printf 'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class\n' >> "$TSV_FILE"

CLIENT_POD="$(fortio_client_pod "$SOURCE_CTX" "$NS" dataplane-client "${KUBECTL[@]}")" \
	|| die "no Ready dataplane-client pod that is not being deleted on $SOURCE_CTX (ns=$NS): run 001, or wait until its Deployment's new pod is Ready"

echo "=== Data-plane latency probe ==="
echo "Source: $SOURCE_CTX (pod: $CLIENT_POD)"
echo "Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
echo "QPS levels: ${QPS_ARR[*]} | Duration: ${DURATION}s | Connections: $CONNECTIONS"
echo "Settle: ${SETTLE_SEC}s | Fortio image: ${FORTIO_IMAGE}"
echo "Server replicas (ready/spec): ${SERVER_REPLICAS_CSV} | Min QPS ratio: ${MIN_QPS_RATIO} | Min pct_200: ${MIN_PCT_200}"
echo ""

# istiod restart detection on every context: one port-forward per Running istiod
# pod (tests/lib/fanout.sh). fanout_open dies if no pod on a context serves
# /metrics; a context with no Running istiod pod leaves the result "unknown".
declare -A CTX_PORTS=() CTX_PODS=()
for i in "${!ALL_CTXS[@]}"; do
	ctx="${ALL_CTXS[$i]}"
	if [[ -z "$(fanout_list_istiod_pods "$ctx" "${KUBECTL[@]}")" ]]; then
		echo "warning: no Running istiod pod on $ctx; istiod_restarted will be unknown" >&2
		continue
	fi
	# Out-array names must not collide with fanout_open's own locals (ports/pods).
	fo_ports=(); fo_pods=()
	fanout_open "$ctx" "$i" PF_PIDS fo_ports fo_pods "${KUBECTL[@]}"
	CTX_PORTS["$i"]="${fo_ports[*]}"
	CTX_PODS["$i"]="${fo_pods[*]}"
done

# snapshot_istiod <pre|post>: record each context's pod set and scrape every pod.
# The pre pod set is the scraped pods; post is every Running pod, so a replaced
# or added pod shows up as a pod-set change.
snapshot_istiod() {
	local phase="$1" i
	local -a snap_ports=() snap_pods=()
	for i in "${!ALL_CTXS[@]}"; do
		[[ -n "${CTX_PORTS[$i]:-}" ]] || continue
		read -ra snap_ports <<<"${CTX_PORTS[$i]}"
		read -ra snap_pods <<<"${CTX_PODS[$i]}"
		if [[ "$phase" == pre ]]; then
			printf '%s\n' ${snap_pods[@]+"${snap_pods[@]}"} > "${ISTIOD_DIR}/${phase}-c${i}.podset"
		else
			fanout_record_podset "${ALL_CTXS[$i]}" "${ISTIOD_DIR}/${phase}-c${i}.podset" "${KUBECTL[@]}"
		fi
		fanout_scrape_all "$ISTIOD_DIR" "${phase}-c${i}" ${snap_ports[@]+"${snap_ports[@]}"} >/dev/null || true
	done
}

# ctx_metrics_csv <ctx_index> <pre|post>: the context's per-pod scrape files, comma-joined,
# in pod-set order.
ctx_metrics_csv() {
	local i="$1" phase="$2" j csv=""
	local -a st_pods=()
	read -ra st_pods <<<"${CTX_PODS[$i]:-}"
	for j in "${!st_pods[@]}"; do
		csv+="${csv:+,}${ISTIOD_DIR}/${phase}-c${i}-${j}.metrics"
	done
	echo "$csv"
}

# ctx_restart_status <ctx_index>: 0 | 1 | unknown for one context.
ctx_restart_status() {
	local i="$1"
	[[ -n "${CTX_PODS[$i]:-}" ]] || { echo unknown; return 0; }
	fanout_restart_status "${ISTIOD_DIR}/pre-c${i}.podset" "${ISTIOD_DIR}/post-c${i}.podset" \
		"$(ctx_metrics_csv "$i" pre)" "$(ctx_metrics_csv "$i" post)"
}

if ((SETTLE_SEC > 0)); then
	echo "Settling for ${SETTLE_SEC}s to allow xDS endpoint propagation..."
	sleep "$SETTLE_SEC"
fi

# Remote reachability check (tests/lib/reach.sh): after the settle, before the
# warmup and outside the istiod window. REACH_STATUS[ctx] is REACHABLE, DEGRADED,
# UNREACHABLE or UNKNOWN; with the check off every target is UNCHECKED.
declare -A REACH_STATUS=() REACH_PCT=()
for rctx in "${ALL_CTXS[@]}"; do REACH_STATUS["$rctx"]=UNCHECKED; REACH_PCT["$rctx"]=N/A; done
if ((REACH_REQUESTS > 0)); then
	echo "Checking reachability of every target (${REACH_REQUESTS} requests each; details on stderr)..."
	if reach_write_header "$REACH_TSV" "RUN_ID=${RUN_ID}" "HARNESS_SHA=${HARNESS_SHA}" \
		"SUITE=dataplane" \
		"NAMESPACE=${NS}" "ON_UNREACHABLE=${ON_UNREACHABLE}" \
		&& reach_check_all "$REACH_TSV" "$RUN_ID" "$RUN_ID" "$MESH_SIZE" "$NS" "$CLIENT_POD" \
			"$URL_TEMPLATE" "$SOURCE_CTX" "$REMOTE_CONTEXTS_CSV" "${KUBECTL[@]}"; then
		reach_print_summary "$REACH_TSV" "$RUN_ID" "$RUN_ID"
		for rctx in "${ALL_CTXS[@]}"; do
			read -r REACH_STATUS["$rctx"] REACH_PCT["$rctx"] <<<"$(reach_result_for "$REACH_TSV" "$RUN_ID" "$RUN_ID" "$rctx")"
		done
	else
		echo "warning: the reachability check could not run (${REACH_TSV} not writable?); every remote is UNKNOWN" >&2
		for rctx in "${ALL_CTXS[@]}"; do REACH_STATUS["$rctx"]=UNKNOWN; done
	fi
	echo ""
elif [[ "$ON_UNREACHABLE" == fail ]]; then
	echo "warning: --on-unreachable fail has no effect with --reach-requests 0" >&2
fi

# emit_unreachable_rows <remote_ctx>: one UNREACHABLE row per QPS level for a remote
# whose load was skipped (qps_actual and latency N/A: nothing was measured; pct_200
# from the reach check).
emit_unreachable_rows() {
	local ctx="$1" qps
	for qps in "${QPS_ARR[@]}"; do
		printf '%s\t%s\t%s\t%s\t%s\tN/A\t%s\t%s\tN/A\tN/A\tN/A\tN/A\tN/A\tUNREACHABLE\t%s\t%s\tremote\n' \
			"$RUN_ID" "$MESH_SIZE" "$SOURCE_CTX" "$ctx" "$qps" "$CONNECTIONS" "$DURATION" \
			"${REACH_PCT[$ctx]:-N/A}" "${ISTIOD_RESTARTED_TAG:-unknown}" >> "$TSV_FILE"
	done
}

# write_run_md: the per-run markdown summary next to the TSV.
write_run_md() {
	MD_FILE="${OUTPUT_DIR}/latency-${RUN_ID}.md"
	local reach_rows
	reach_rows="$(reach_coverage_rows "$REACH_TSV")"
	{
		echo "# Data-Plane Latency Results"
		echo ""
		echo "| Field | Value |"
		echo "|-------|-------|"
		echo "| Run ID | \`${RUN_ID}\` |"
		echo "| Date | $(date -u -Iseconds) |"
		echo "| Harness SHA | \`${HARNESS_SHA}\` |"
		echo "| Run config | \`${RUN_CONFIG:-none}\` (sha256 \`${RUN_CONFIG_SHA256:-none}\`) |"
		platform_md_row "$(IFS=,; echo "${ALL_CTXS[*]}")"
		echo "| Istio version | $(istio_version_label) |"
		echo "| Fortio image | \`${FORTIO_IMAGE}\` |"
		echo "| Source | ${SOURCE_CTX} |"
		echo "| Remotes | ${REMOTES[*]:-none} |"
		echo "| Mesh size | ${MESH_SIZE} |"
		echo "| QPS levels | ${QPS_ARR[*]} |"
		echo "| Duration | ${DURATION}s |"
		echo "| Connections | ${CONNECTIONS} |"
		echo "| Settle | ${SETTLE_SEC}s |"
		echo "| Warmup | ${WARMUP_DURATION}s |"
		echo "| Server replicas (ready/spec) | ${SERVER_REPLICAS_CSV} |"
		echo "| Min QPS ratio | ${MIN_QPS_RATIO} |"
		echo "| Min HTTP 200 share | $(awk -v r="$MIN_PCT_200" 'BEGIN { printf "%.2f%%", r * 100 }') (DATAPLANE_MIN_PCT_200=${MIN_PCT_200}) |"
		echo "| Reach check | ${REACH_REQUESTS} requests per target, on unreachable: ${ON_UNREACHABLE} |"
		echo "| istiod_restarted | ${ISTIOD_RESTARTED} |"
		echo ""
		echo "Note: the local baseline is intra-cluster (sidecar-to-sidecar), NOT a no-mesh baseline."
		echo ""
		reach_coverage_render md <(printf '%s' "$reach_rows")
		echo ""
		echo "## Summary"
		echo ""
		echo "| Target | Class | QPS Target | QPS Actual | p50 (ms) | p90 (ms) | p99 (ms) | p99.9 (ms) | Max (ms) | HTTP 200 (%) | Status |"
		echo "|--------|-------|------------|------------|----------|----------|----------|------------|----------|--------------|--------|"
		# Latencies %.2f ms, QPS %.1f, the HTTP 200 share as a percentage; anything not
		# a number (N/A) as-is. A placeholder row (class na) has no QPS target.
		awk -F'\t' '
		function isnum(v) { return v ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/ }
		function f(v, fmt) { return isnum(v) ? sprintf(fmt, v) : v }
		function pct(v) { return isnum(v) ? sprintf("%.2f%%", v * 100) : v }
		!/^#/ && !/^run_id/ && NF>=17 {
			printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $4, $17, ($17 == "na" ? "N/A" : $5), f($6, "%.1f"),
				f($9, "%.2f"), f($10, "%.2f"), f($11, "%.2f"), f($12, "%.2f"), f($13, "%.2f"), pct($15), $14
		}' "$TSV_FILE"
		echo ""
		echo "## Raw Data"
		echo ""
		echo "TSV: [\`$(basename "$TSV_FILE")\`]($(basename "$TSV_FILE"))"
		[[ -f "$REACH_TSV" ]] && echo "Reach check: [\`$(basename "$REACH_TSV")\`]($(basename "$REACH_TSV"))"
	} > "$MD_FILE"
	echo "Summary written to $MD_FILE"
}

# --on-unreachable fail: stop before any load. The UNREACHABLE remotes get the rows
# a warn run would have written; a STOPPED_UNREACHABLE placeholder (class na) makes
# the report say why this mesh size has no local baseline.
if ((REACH_REQUESTS > 0)) && reach_should_stop "$ON_UNREACHABLE" "$REACH_TSV" "$RUN_ID" "$RUN_ID" "$REMOTE_CONTEXTS_CSV"; then
	mapfile -t STOP_REMOTES < <(reach_not_reachable "$REACH_TSV" "$RUN_ID" "$RUN_ID" "$REMOTE_CONTEXTS_CSV")
	ISTIOD_RESTARTED="unknown"
	ISTIOD_RESTARTED_TAG="unknown"
	for rctx in ${STOP_REMOTES[@]+"${STOP_REMOTES[@]}"}; do
		if [[ "${REACH_STATUS[$rctx]:-UNKNOWN}" == UNREACHABLE ]]; then emit_unreachable_rows "$rctx"; fi
	done
	printf '%s\t%s\t%s\tN/A\t0\tN/A\t%s\t%s\tN/A\tN/A\tN/A\tN/A\tN/A\tSTOPPED_UNREACHABLE\tN/A\tunknown\tna\n' \
		"$RUN_ID" "$MESH_SIZE" "$SOURCE_CTX" "$CONNECTIONS" "$DURATION" >> "$TSV_FILE"
	echo "STOPPED: --on-unreachable fail and ${#STOP_REMOTES[@]} remote(s) UNREACHABLE or UNKNOWN from ${SOURCE_CTX}: ${STOP_REMOTES[*]}; no load ran (exit ${REACH_EXIT_CODE})" >&2
	echo "Results written to $TSV_FILE"
	write_run_md
	exit "$REACH_EXIT_CODE"
fi

if ((WARMUP_DURATION > 0)); then
	echo "Warming Envoy upstream connection pools (${WARMUP_DURATION}s at QPS=10)..."
	WARMUP_URLS=("$LOCAL_URL")
	for rc in ${REMOTES[@]+"${REMOTES[@]}"}; do
		[[ "${REACH_STATUS[$rc]}" == UNREACHABLE ]] && continue
		WARMUP_URLS+=("${URL_TEMPLATE//\{ctx\}/${rc}}")
	done
	for wurl in ${WARMUP_URLS[@]+"${WARMUP_URLS[@]}"}; do
		echo "  warmup -> $wurl"
		LOAD_POD="$CLIENT_POD"
		load_start_ns="$(now_ns)"
		if ! "${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" exec "$CLIENT_POD" -c fortio -- \
			fortio load -qps 10 -c "$CONNECTIONS" -t "${WARMUP_DURATION}s" -quiet "$wurl" >/dev/null 2>&1; then
			echo "  warn: warmup failed for $wurl" >&2
			fortio_load_wait_out "$load_start_ns" "$WARMUP_DURATION" "$SOURCE_CTX" "$NS" "$CLIENT_POD" "${KUBECTL[@]}"
		fi
		LOAD_POD=""
	done
	echo ""
fi

snapshot_istiod pre

run_fortio() {
	local target_ctx="$1" target_url="$2" target_class="$3"
	for qps in "${QPS_ARR[@]}"; do
		echo "  QPS=$qps -> $target_url"
		local json_output load_start_ns
		LOAD_POD="$CLIENT_POD"
		load_start_ns="$(now_ns)"
		json_output=$("${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" exec "$CLIENT_POD" -c fortio -- \
			fortio load -qps "$qps" -c "$CONNECTIONS" -t "${DURATION}s" -p '50,90,99,99.9' \
			-json - -quiet "$target_url" 2>/dev/null) || {
			echo "    FAILED"
			# Nothing was measured: qps_actual and every latency are N/A, never 0.
			printf '%s\t%s\t%s\t%s\t%s\tN/A\t%s\t%s\tN/A\tN/A\tN/A\tN/A\tN/A\tFAILED\tN/A\t%s\t%s\n' \
				"$RUN_ID" "$MESH_SIZE" "$SOURCE_CTX" "$target_ctx" "$qps" \
				"$CONNECTIONS" "$DURATION" "${ISTIOD_RESTARTED_TAG:-unknown}" "$target_class" >> "$TSV_FILE"
			# The load can outlive its failed exec in the pod: wait it out before the next one.
			fortio_load_wait_out "$load_start_ns" "$DURATION" "$SOURCE_CTX" "$NS" "$CLIENT_POD" "${KUBECTL[@]}"
			LOAD_POD=""
			continue
		}
		LOAD_POD=""

		# Parsing and the row status live in tests/lib/fortio.sh.
		local qps_actual p50 p90 p99 p999 max_lat pct_200 ret_codes status
		qps_actual=$(fortio_actual_qps "$json_output")
		p50=$(fortio_percentile_ms "$json_output" 50)
		p90=$(fortio_percentile_ms "$json_output" 90)
		p99=$(fortio_percentile_ms "$json_output" 99)
		p999=$(fortio_percentile_ms "$json_output" 99.9)
		max_lat=$(fortio_max_ms "$json_output")
		pct_200=$(fortio_pct_200 "$json_output")
		ret_codes=$(fortio_ret_codes "$json_output")
		status=$(fortio_row_status "$json_output" "$qps" "$MIN_QPS_RATIO" "$MIN_PCT_200")

		# Pretty print (numeric values may be "N/A"; tolerate that).
		printf "    actual_qps=%s p50=%sms p99=%sms max=%sms pct_200=%s ret_codes=%s status=%s\n" \
			"$qps_actual" "$p50" "$p99" "$max_lat" "$pct_200" "$ret_codes" "$status"
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$RUN_ID" "$MESH_SIZE" "$SOURCE_CTX" "$target_ctx" "$qps" "$qps_actual" \
			"$CONNECTIONS" "$DURATION" "$p50" "$p90" "$p99" "$p999" "$max_lat" \
			"$status" "$pct_200" "${ISTIOD_RESTARTED_TAG:-unknown}" "$target_class" >> "$TSV_FILE"
	done
}

# We can't know the final ISTIOD_RESTARTED until after both probes finish.
# Placeholder during execution; we rewrite all rows in one pass at the end.
ISTIOD_RESTARTED_TAG="pending"

echo "--- Local baseline (intra-cluster, sidecar-to-sidecar) ---"
run_fortio "$SOURCE_CTX" "$LOCAL_URL" "local"

for remote_ctx in ${REMOTES[@]+"${REMOTES[@]}"}; do
	echo ""
	echo "--- Cross-cluster: $SOURCE_CTX -> $remote_ctx ---"
	# An UNREACHABLE remote (no HTTP 200 on any reach check) skips its load; DEGRADED
	# and UNKNOWN remotes run, and their rows carry their own status.
	if [[ "${REACH_STATUS[$remote_ctx]}" == UNREACHABLE ]]; then
		echo "  skipped: reach check UNREACHABLE (see ${REACH_TSV##*/}); writing UNREACHABLE rows"
		emit_unreachable_rows "$remote_ctx"
		continue
	fi
	run_fortio "$remote_ctx" "${URL_TEMPLATE//\{ctx\}/${remote_ctx}}" "remote"
done

snapshot_istiod post

# istiod_restarted for the run: 1 if any context restarted, else unknown if any
# context could not be measured, else 0.
ISTIOD_RESTARTED="0"
declare -A CTX_RESTARTED=()
for i in "${!ALL_CTXS[@]}"; do
	CTX_RESTARTED["$i"]="$(ctx_restart_status "$i")"
	case "${CTX_RESTARTED[$i]}" in
	1) ISTIOD_RESTARTED="1"; echo "warning: istiod restarted on ${ALL_CTXS[$i]} during probe" >&2 ;;
	unknown) [[ "$ISTIOD_RESTARTED" == "1" ]] || ISTIOD_RESTARTED="unknown" ;;
	esac
done

# istiod restart evidence (tests/lib/istiod-diag.sh) for every context whose status is not
# 0, into istiod-diag-<RUN_ID>/ next to the TSV, before the EXIT trap removes ISTIOD_DIR.
# Best-effort: it never changes a row or the exit status. A context that had no Running
# istiod pod at the start has no pre-window pod set (trigger no_running_pods).
DIAG_DIR="$(istiod_diag_dir "$TSV_FILE" "$RUN_ID")"
for i in "${!ALL_CTXS[@]}"; do
	[[ "${CTX_RESTARTED[$i]}" == 0 ]] && continue
	if [[ -n "${CTX_PODS[$i]:-}" ]]; then
		istiod_diag_capture "$DIAG_DIR" "m${MESH_SIZE}" "${ALL_CTXS[$i]}" "${CTX_RESTARTED[$i]}" \
			"${ISTIOD_DIR}/pre-c${i}.podset" "$(ctx_metrics_csv "$i" pre)" "${KUBECTL[@]}"
	else
		istiod_diag_capture "$DIAG_DIR" "m${MESH_SIZE}" "${ALL_CTXS[$i]}" no_running_pods "" "" "${KUBECTL[@]}"
	fi
done

# Rewrite the istiod_restarted column (penultimate) for all data rows.
tmp_tsv=$(mktemp "${TSV_FILE}.XXXXXX")
awk -F'\t' -v OFS='\t' -v r="$ISTIOD_RESTARTED" '
	/^#/ { print; next }
	/^run_id\t/ { print; next }
	NF >= 17 { $16 = r; print; next }
	{ print }
' "$TSV_FILE" > "$tmp_tsv"
mv "$tmp_tsv" "$TSV_FILE"
tmp_tsv=""

echo ""
for i in "${!ALL_CTXS[@]}"; do
	echo "istiod_restarted[${ALL_CTXS[$i]}]: ${CTX_RESTARTED[$i]}"
done
echo "istiod_restarted (aggregate): ${ISTIOD_RESTARTED}"
echo "Results written to $TSV_FILE"

write_run_md

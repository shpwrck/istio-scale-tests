#!/usr/bin/env bash
# Phase 1 of the co-exec test: run fortio against a steady mesh with NO churn,
# emitting a single baseline TSV row that captures p50/p99/p999/max latency and
# actual QPS for later comparison against the churn phase.
#
# Before the window (and before the istiod port-forwards), a remote reachability
# check (tests/lib/reach.sh) sends a few requests to each cluster's own
# fortio-server-<ctx> Service and appends to reach-<RUN_ID>.tsv next to the output
# TSV. The window itself targets the merged fortio-server Service, where Istio
# retries a failed request on another endpoint, so it cannot name a dead remote.
# Under --on-unreachable fail an UNREACHABLE or UNKNOWN remote stops the probe
# before the window, with no row written (exit 3).
# A window whose HTTP 200 share is below COEXEC_MIN_PCT_200 is ERROR_RATE_HIGH
# (tests/lib/fortio.sh fortio_row_status, QPS-shortfall check off).
#
# Usage:
#   ./tests/churn-dataplane/002-run-baseline-probe.sh \
#       --source-context CTX [options]
#   ./tests/churn-dataplane/002-run-baseline-probe.sh --config tests/churn-dataplane/configs/smoke.env \
#       --source-context <mesh-a-ctx> --remote-contexts <mesh-b-ctx>
# ci-dry-run: --source-context ci-dummy
set -euo pipefail
# A loud ERR trap (separate signal from the EXIT cleanup trap installed later, so
# both run). Self-reports an UNEXPECTED abort.
# shellcheck disable=SC2154  # rc is assigned at the head of the trap body
trap 'rc=$?; echo "FATAL: ${0##*/} aborted (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # config_preload, config_preamble_lines
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
config_preload churn-dataplane "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/timestamp.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/platform.sh"  # platform_probe, platform_preamble_lines (the platform record)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/metrics.sh"
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
COMBO_ID=""
RUN_ID_OPT=""
DURATION="${COEXEC_BASELINE_DURATION_SEC:-60}"
QPS="${COEXEC_QPS:-200}"
CONNECTIONS="${COEXEC_NUM_CONNECTIONS:-8}"
SETTLE_SEC="${COEXEC_SETTLE_SEC:-10}"
NS="${COEXEC_TEST_NAMESPACE:-churn-dataplane-test}"
MIN_PCT_200="${COEXEC_MIN_PCT_200:-0.99}"
ON_UNREACHABLE="${REACH_ON_UNREACHABLE:-warn}"
REACH_REQUESTS="${REACH_REQUESTS:-10}"
OUTPUT_FILE=""
OUTPUT_DIR="$(config_repo_path "${COEXEC_RESULTS_DIR}")"
APPEND=0
DRY_RUN=0
# Live tuning levers + sidecar egress hosts for the TSV preamble. The sweep queries
# them once and passes them in; standalone runs record "unknown".
TUNING_BASELINE="unknown"
SIDECAR_EGRESS_HOSTS="unknown"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Checks that every fortio server answers (reach-<RUN_ID>.tsv), then runs one fortio load
from the source's client pod with no churn: the baseline row of a combo (status OK, FAILED,
PERCENTILE_MISSING, ERROR_RATE_HIGH, POISONED_RESTART or POISONED_SCRAPE).

  --config FILE            Run config of KEY=value lines (config/options.env keys).
                           Precedence: flag > --config > environment > default.
  --source-context CTX     Context where fortio-client runs (required).
  --remote-contexts CSV    Other contexts in the mesh, reach-checked before the window.
  --mesh-size N            Mesh-size tag (default: 1 + remotes).
  --combo-id ID            Stable id linking baseline+churn rows in 004 (default: \$RUN_ID).
  --run-id ID              Reuse a prior run_id (default: fresh timestamp).
  --duration SEC           Fortio duration (default: $DURATION).
  --qps N                  Target QPS (default: $QPS).
  --connections N          Concurrent connections (default: $CONNECTIONS).
  --settle-sec N           Settle delay before measurement starts (default: $SETTLE_SEC).
  --output-file FILE       TSV file to write/append to
                           (default: ${COEXEC_RESULTS_DIR}/churn-dataplane-\$RUN_ID.tsv).
  --output-dir DIR         Default results dir if --output-file not given.
  --tuning-baseline STR    Tuning levers for the preamble (default: unknown; a sweep sets it).
  --sidecar-egress-hosts STR  Root Sidecar egress hosts for the preamble (default: unknown;
                           a sweep sets it).
  --on-unreachable POLICY  warn, or fail: stop before the window, exit 3 (default: $ON_UNREACHABLE).
  --reach-requests N       Requests per target in the reach check; 0 = off (default: $REACH_REQUESTS).
  --append                 Append to --output-file without rewriting preamble/header.
  --dry-run                Print plan only.
  -h, --help               Show this help.

Environment (config/options.env describes each): the flags' COEXEC_* keys,
COEXEC_MIN_PCT_200 (ERROR_RATE_HIGH below it; default $MIN_PCT_200, 0 = off),
COEXEC_TEST_NAMESPACE, COEXEC_SERVICE_PORT, COEXEC_ISTIOD_REPLICAS, COEXEC_RESULTS_DIR
(relative to the repo root), REACH_REQUESTS, REACH_QPS, REACH_HTTP_TIMEOUT_SEC,
REACH_DETAIL_TIMEOUT_SEC, REACH_ATTEMPTS, REACH_RETRY_SEC, REACH_ON_UNREACHABLE, FANOUT_*
(FANOUT_MAX_SKEW_MS: POISONED_SCRAPE above it), METRICS_SCRAPE_TIMEOUT, ISTIOD_DIAG_*,
TEST_PLATFORM, PLATFORM_READ_TIMEOUT, PLATFORM_READ_PARALLEL. Environment only:
ISTIO_VERSION_CHECK, ISTIO_VERSION_READY_WAIT_SEC.

Exit codes: 0 the row was written (or the plan shown); 1 an error; 3 --on-unreachable fail
stopped the probe.

See tests/churn-dataplane/README.md.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--config)
		# Loaded by config_preload above.
		[[ -n "${2:-}" ]] || die "--config requires a value"
		shift 2 ;;
	--source-context)
		[[ -n "${2:-}" ]] || die "--source-context requires a value"
		SOURCE_CTX="$2"; shift 2 ;;
	--remote-contexts)
		[[ -n "${2:-}" ]] || die "--remote-contexts requires a value"
		REMOTE_CONTEXTS_CSV="$2"; shift 2 ;;
	--mesh-size)
		[[ -n "${2:-}" ]] || die "--mesh-size requires a value"
		MESH_SIZE="$2"; shift 2 ;;
	--combo-id)
		[[ -n "${2:-}" ]] || die "--combo-id requires a value"
		COMBO_ID="$2"; shift 2 ;;
	--run-id)
		[[ -n "${2:-}" ]] || die "--run-id requires a value"
		RUN_ID_OPT="$2"; shift 2 ;;
	--duration)
		[[ -n "${2:-}" ]] || die "--duration requires a value"
		DURATION="$2"; shift 2 ;;
	--qps)
		[[ -n "${2:-}" ]] || die "--qps requires a value"
		QPS="$2"; shift 2 ;;
	--connections)
		[[ -n "${2:-}" ]] || die "--connections requires a value"
		CONNECTIONS="$2"; shift 2 ;;
	--settle-sec)
		[[ -n "${2:-}" ]] || die "--settle-sec requires a value"
		SETTLE_SEC="$2"; shift 2 ;;
	--output-file)
		[[ -n "${2:-}" ]] || die "--output-file requires a value"
		OUTPUT_FILE="$2"; shift 2 ;;
	--output-dir)
		[[ -n "${2:-}" ]] || die "--output-dir requires a value"
		OUTPUT_DIR="$2"; shift 2 ;;
	--tuning-baseline)
		[[ -n "${2:-}" ]] || die "--tuning-baseline requires a value"
		TUNING_BASELINE="$2"; shift 2 ;;
	--sidecar-egress-hosts)
		[[ -n "${2:-}" ]] || die "--sidecar-egress-hosts requires a value"
		SIDECAR_EGRESS_HOSTS="$2"; shift 2 ;;
	--on-unreachable)
		[[ -n "${2:-}" ]] || die "--on-unreachable requires a value"
		ON_UNREACHABLE="$2"; shift 2 ;;
	--reach-requests)
		[[ -n "${2:-}" ]] || die "--reach-requests requires a value"
		REACH_REQUESTS="$2"; shift 2 ;;
	--append)
		APPEND=1; shift ;;
	--dry-run)
		DRY_RUN=1; shift ;;
	-h | --help)
		usage; exit 0 ;;
	*)
		die "unknown option: $1 (try --help)" ;;
	esac
done

platform_validate
[[ -n "$SOURCE_CTX" ]] || die "--source-context is required"
# fortio gets -t "${DURATION}s": `5m` would be a 5 ms window, not an error.
is_pos_int "$DURATION" || die "--duration (or COEXEC_BASELINE_DURATION_SEC) must be a positive integer; got '$DURATION'"
is_pos_int "$QPS" || die "--qps (or COEXEC_QPS) must be a positive integer; got '$QPS'"
is_pos_int "$CONNECTIONS" || die "--connections (or COEXEC_NUM_CONNECTIONS) must be a positive integer; got '$CONNECTIONS'"
is_nonneg_int "$SETTLE_SEC" || die "--settle-sec (or COEXEC_SETTLE_SEC) must be a non-negative integer; got '$SETTLE_SEC'"
is_ratio "$MIN_PCT_200" || [[ "$MIN_PCT_200" =~ ^0(\.0+)?$ ]] \
	|| die "COEXEC_MIN_PCT_200 must be 0 (rule off) or a decimal in (0,1]; got '$MIN_PCT_200'"
reach_msg="$(reach_validate "$ON_UNREACHABLE")" || die "$reach_msg"

KUBECTL=()
resolve_kubectl KUBECTL
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
command -v curl >/dev/null 2>&1 || die "curl not found on PATH"

REMOTES=()
[[ -n "$REMOTE_CONTEXTS_CSV" ]] && split_contexts "$REMOTE_CONTEXTS_CSV" REMOTES --remote-contexts "$SOURCE_CTX"
# The source and its remotes, each under a name of its own in the platform record
# (platform_members_check): refused here, before any cluster call, in a --dry-run too.
platform_members_check "$SOURCE_CTX" ${REMOTES[@]+"${REMOTES[@]}"}
[[ -z "$MESH_SIZE" ]] && MESH_SIZE=$(( 1 + ${#REMOTES[@]} ))

RUN_ID="${RUN_ID_OPT:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
[[ -z "$COMBO_ID" ]] && COMBO_ID="$RUN_ID"

[[ -z "$OUTPUT_FILE" ]] && OUTPUT_FILE="${OUTPUT_DIR}/churn-dataplane-${RUN_ID}.tsv"
# One reach file per RUN_ID: a sweep passes its RUN_ID, so every combo appends to
# the same file (combo_id tells them apart) and 005 finds it next to the TSV.
REACH_TSV="$(dirname "$OUTPUT_FILE")/reach-${RUN_ID}.tsv"
REACH_URL_TEMPLATE="http://fortio-server-{ctx}.${NS}.svc.cluster.local:${COEXEC_SERVICE_PORT:-8080}/echo"

HARNESS_SHA="$(harness_sha --exclude "$(dirname "$OUTPUT_FILE")")"
ALL_CTXS_CSV="$SOURCE_CTX"
for r in ${REMOTES[@]+"${REMOTES[@]}"}; do ALL_CTXS_CSV+=",$r"; done

if ((DRY_RUN)); then
	echo "=== Dry-run: baseline probe ==="
	echo "Source: $SOURCE_CTX | Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
	echo "Duration: ${DURATION}s | QPS: $QPS | Connections: $CONNECTIONS | Settle: ${SETTLE_SEC}s"
	echo "Output: $OUTPUT_FILE (append=$APPEND)"
	echo "RUN_ID=$RUN_ID  COMBO_ID=$COMBO_ID  HARNESS_SHA=$HARNESS_SHA"
	echo "Min pct_200: $MIN_PCT_200 (ERROR_RATE_HIGH below it; 0 = off)"
	reach_plan_line "$REACH_URL_TEMPLATE" "$SOURCE_CTX" "$REMOTE_CONTEXTS_CSV" "$ON_UNREACHABLE"
	echo "Reach TSV: $REACH_TSV"
	exit 0
fi
mkdir -p "$(dirname "$OUTPUT_FILE")"

# PL2: probe kube versions concurrently with 5s --request-timeout.
KUBE_VERSIONS_CSV="$(probe_kube_versions "$ALL_CTXS_CSV" "${KUBECTL[@]}")"
# The Istio version the members run, before any load (inherited when 004 runs this
# probe; read here when it runs alone). ISTIO_VERSION_CHECK=fail stops on a mismatch.
istio_version_resolve "$ALL_CTXS_CSV" 0 "${KUBECTL[@]}"
mapfile -t IV_KV < <(istio_version_kv)
# The platform record (tests/lib/platform.sh), before any window: inherited from 004, else read here.
platform_probe "$ALL_CTXS_CSV"

# Preflight + record the source istiod replica count for the TSV preamble (PL2).
# The fanout (tests/lib/fanout.sh) scrapes EVERY Running istiod pod, so multi-
# replica istiod is supported; we just need >= 1 pod and provenance. Warn (do
# not die) if the count differs from the expected pin COEXEC_ISTIOD_REPLICAS.
SOURCE_REPLICAS="$(fanout_preflight_istiod "$SOURCE_CTX" "${KUBECTL[@]}")"
if [[ -n "${COEXEC_ISTIOD_REPLICAS:-}" && "$SOURCE_REPLICAS" != "$COEXEC_ISTIOD_REPLICAS" ]]; then
	echo "warn: context $SOURCE_CTX has $SOURCE_REPLICAS Running istiod pods, expected pin COEXEC_ISTIOD_REPLICAS=$COEXEC_ISTIOD_REPLICAS" >&2
fi

if [[ ! -f "$OUTPUT_FILE" || "$APPEND" -eq 0 ]]; then
	write_preamble "churn-dataplane co-exec test" "$OUTPUT_FILE" \
		"RUN_ID=$RUN_ID" \
		"HARNESS_SHA=$HARNESS_SHA" \
		"${IV_KV[@]}" \
		"KUBE_VERSIONS=$KUBE_VERSIONS_CSV" \
		"TUNING_BASELINE=$TUNING_BASELINE" \
		"SIDECAR_EGRESS_HOSTS=$SIDECAR_EGRESS_HOSTS" \
		"ISTIOD_REPLICAS=$SOURCE_REPLICAS" \
		"SETTLE_SEC=$SETTLE_SEC" \
		"BASELINE_DURATION_SEC=$DURATION" \
		"CHURN_DURATION_SEC=${COEXEC_CHURN_DURATION_SEC:-$DURATION}" \
		"QPS=$QPS" \
		"CONNECTIONS=$CONNECTIONS" \
		"NAMESPACE=$NS" \
		"FANOUT_MAX_SKEW_MS=$FANOUT_MAX_SKEW_MS" \
		"FANOUT_METRICS_TIMEOUT=$FANOUT_METRICS_TIMEOUT" \
		"MIN_PCT_200=$MIN_PCT_200" \
		"REACH_REQUESTS=$REACH_REQUESTS" \
		"REACH_QPS=${REACH_QPS:-10}" \
		"REACH_HTTP_TIMEOUT_SEC=${REACH_HTTP_TIMEOUT_SEC:-3}" \
		"REACH_DETAIL_TIMEOUT_SEC=${REACH_DETAIL_TIMEOUT_SEC:-35}" \
		"REACH_ATTEMPTS=${REACH_ATTEMPTS:-3}" \
		"REACH_RETRY_SEC=${REACH_RETRY_SEC:-10}" \
		"ON_UNREACHABLE=$ON_UNREACHABLE"
	{ config_preamble_lines; platform_preamble_lines "$ALL_CTXS_CSV"; } >> "$OUTPUT_FILE"
	printf 'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms\n' >> "$OUTPUT_FILE"
fi

CLIENT_POD="$(fortio_client_pod "$SOURCE_CTX" "$NS" fortio-client "${KUBECTL[@]}")" \
	|| die "no Ready fortio-client pod that is not being deleted on $SOURCE_CTX (ns=$NS): run 001, or wait until its Deployment's new pod is Ready"

# Remote reachability check (tests/lib/reach.sh), before the istiod port-forwards
# and the window, through each cluster's fortio-server-<ctx> Service.
if ((REACH_REQUESTS > 0)); then
	echo "Checking reachability of every cluster's fortio-server-<ctx> (${REACH_REQUESTS} requests each; details on stderr)..."
	# A sweep's 002s share one reach file (its RUN_ID): its header records every member the
	# sweep covers (the inherited record), not the first mesh size's.
	if reach_write_header "$REACH_TSV" --contexts "$(platform_recorded_contexts)" "RUN_ID=${RUN_ID}" \
		"HARNESS_SHA=${HARNESS_SHA}" "SUITE=churn-dataplane" \
		"NAMESPACE=${NS}" "ON_UNREACHABLE=${ON_UNREACHABLE}" \
		&& reach_check_all "$REACH_TSV" "$RUN_ID" "$COMBO_ID" "$MESH_SIZE" "$NS" "$CLIENT_POD" \
			"$REACH_URL_TEMPLATE" "$SOURCE_CTX" "$REMOTE_CONTEXTS_CSV" "${KUBECTL[@]}"; then
		reach_print_summary "$REACH_TSV" "$RUN_ID" "$COMBO_ID"
		if reach_should_stop "$ON_UNREACHABLE" "$REACH_TSV" "$RUN_ID" "$COMBO_ID" "$REMOTE_CONTEXTS_CSV"; then
			mapfile -t STOP_REMOTES < <(reach_not_reachable "$REACH_TSV" "$RUN_ID" "$COMBO_ID" "$REMOTE_CONTEXTS_CSV")
			echo "STOPPED: --on-unreachable fail and ${#STOP_REMOTES[@]} remote(s) UNREACHABLE or UNKNOWN from ${SOURCE_CTX}: ${STOP_REMOTES[*]}; no baseline window ran (exit ${REACH_EXIT_CODE})" >&2
			exit "$REACH_EXIT_CODE"
		fi
	else
		echo "warning: the reachability check could not run (${REACH_TSV} not writable?)" >&2
		if [[ "$ON_UNREACHABLE" == fail ]]; then
			echo "STOPPED: --on-unreachable fail and the reachability check could not run (every remote UNKNOWN); no baseline window ran (exit ${REACH_EXIT_CODE})" >&2
			exit "$REACH_EXIT_CODE"
		fi
	fi
elif [[ "$ON_UNREACHABLE" == fail ]]; then
	echo "warning: --on-unreachable fail has no effect with --reach-requests 0" >&2
fi

# Port-forward every Running istiod pod on the source context (tests/lib/fanout.sh)
# for restart detection and istiod-side xDS metrics.
PF_PIDS=()
ISTIOD_PORTS=()
ISTIOD_PODS=()
ISTIOD_DIR="$(mktemp -d)"
PF_OK=0
# LOAD_POD: the client pod while the window's `fortio load` runs in it; the EXIT trap stops
# a load still running there (fortio_client_stop).
LOAD_POD=""
cleanup_pf() {
	[[ -z "${LOAD_POD:-}" ]] || fortio_client_stop "$SOURCE_CTX" "$NS" "$LOAD_POD" "${KUBECTL[@]}"
	for pid in ${PF_PIDS[@]+"${PF_PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
	PF_PIDS=()
	rm -rf "${ISTIOD_DIR:-}"
}
trap cleanup_pf EXIT

# fanout_open dies if no istiod pod's /metrics becomes reachable; the istiod-side
# restart detection and xDS deltas depend on it, so a hard failure here is more
# honest than silently emitting restarted=unknown for the whole run.
fanout_open "$SOURCE_CTX" 0 PF_PIDS ISTIOD_PORTS ISTIOD_PODS "${KUBECTL[@]}"
PF_OK=1

# PL9 / PL21 / PL22: pre-window scrape of every pod (concurrent) for restart
# detection and istiod-side xDS metrics. Record the pod set for restart-by-podset.
PRE_PODSET="${ISTIOD_DIR}/pre.podset"
PRE_SKEW_MS=0
SCRAPE_INCOMPLETE=0
if ((PF_OK)); then
	# Pre podset = the pods fanout_open reached, in scrape-file order, so
	# fanout_restart_status pairs each pod with its own scrape. The post podset
	# lists every Running pod, so a replaced or added istiod shows as a change.
	printf '%s\n' ${ISTIOD_PODS[@]+"${ISTIOD_PODS[@]}"} > "$PRE_PODSET"
	PRE_SKEW_MS="$(fanout_scrape_all "$ISTIOD_DIR" "pre" ${ISTIOD_PORTS[@]+"${ISTIOD_PORTS[@]}"})"
	(( $(fanout_scrape_failed_count "$ISTIOD_DIR" "pre") > 0 )) && SCRAPE_INCOMPLETE=1
fi
# CSV of the per-pod pre-scrape files in podset order for fanout_restart_status.
pre_metrics_csv() {
	local i out=""
	for i in "${!ISTIOD_PODS[@]}"; do
		[[ -n "$out" ]] && out+=","
		out+="${ISTIOD_DIR}/pre-${i}.metrics"
	done
	echo "$out"
}

echo "=== Baseline phase ==="
echo "Source: $SOURCE_CTX (pod: $CLIENT_POD)"
echo "QPS=$QPS  Duration=${DURATION}s  Connections=$CONNECTIONS  Settle=${SETTLE_SEC}s"

# PL3: settle gap distinct from measurement window.
echo "Settling for ${SETTLE_SEC}s..."
sleep "$SETTLE_SEC"

TARGET_URL="http://fortio-server.${NS}.svc.cluster.local:${COEXEC_SERVICE_PORT:-8080}/echo"
WINDOW_START_NS="$(now_ns)"

JSON_OUT=""
STATUS="OK"
LOAD_POD="$CLIENT_POD"
if ! JSON_OUT="$("${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" exec "$CLIENT_POD" -c fortio -- \
	fortio load -qps "$QPS" -c "$CONNECTIONS" -t "${DURATION}s" -json - -quiet "$TARGET_URL" 2>/dev/null)"; then
	STATUS="FAILED"
	JSON_OUT=""
fi
WINDOW_END_NS="$(now_ns)"
# The load can outlive its failed exec in the pod: wait it out, so the churn window (003)
# that a sweep runs next does not run beside it.
if [[ "$STATUS" == FAILED ]]; then
	fortio_load_wait_out "$WINDOW_START_NS" "$DURATION" "$SOURCE_CTX" "$NS" "$CLIENT_POD" "${KUBECTL[@]}"
fi
LOAD_POD=""

# Post-window scrape of every istiod pod (concurrent) + pod set.
POST_PODSET="${ISTIOD_DIR}/post.podset"
POST_SKEW_MS=0
if ((PF_OK)); then
	fanout_record_podset "$SOURCE_CTX" "$POST_PODSET" "${KUBECTL[@]}"
	POST_SKEW_MS="$(fanout_scrape_all "$ISTIOD_DIR" "post" ${ISTIOD_PORTS[@]+"${ISTIOD_PORTS[@]}"})"
	(( $(fanout_scrape_failed_count "$ISTIOD_DIR" "post") > 0 )) && SCRAPE_INCOMPLETE=1
fi
# PL8: per-window scrape skew now spans pods (the max of the pre/post batches).
SCRAPE_SKEW_MS="$PRE_SKEW_MS"
(( POST_SKEW_MS > SCRAPE_SKEW_MS )) && SCRAPE_SKEW_MS="$POST_SKEW_MS"
# O3 (symmetry with propagation): a wide scrape skew means the pre/post per-pod
# bodies were read seconds apart, so the istiod-side counter/histogram deltas are
# computed across an incoherent snapshot. Fold it into SCRAPE_INCOMPLETE so the
# row is tagged POISONED_SCRAPE; the raw skew is still emitted in the marker line.
if (( SCRAPE_SKEW_MS > FANOUT_MAX_SKEW_MS )); then
	SCRAPE_INCOMPLETE=1
	echo "Warning: scrape_skew=${SCRAPE_SKEW_MS}ms exceeds FANOUT_MAX_SKEW_MS=${FANOUT_MAX_SKEW_MS}ms — row will be tagged POISONED_SCRAPE" >&2
fi
post_metrics_csv() {
	local i out=""
	for i in "${!ISTIOD_PODS[@]}"; do
		[[ -n "$out" ]] && out+=","
		out+="${ISTIOD_DIR}/post-${i}.metrics"
	done
	echo "$out"
}

# PL9 (widened): restart on per-pod start-time advance OR pod-set change.
RESTARTED="unknown"
PRE_FILES=(); POST_FILES=()
if ((PF_OK)); then
	for i in "${!ISTIOD_PODS[@]}"; do
		PRE_FILES+=("${ISTIOD_DIR}/pre-${i}.metrics")
		POST_FILES+=("${ISTIOD_DIR}/post-${i}.metrics")
	done
	RESTARTED="$(fanout_restart_status "$PRE_PODSET" "$POST_PODSET" \
		"$(pre_metrics_csv)" "$(post_metrics_csv)")"
fi

# Extract istiod-side xDS metrics by SUMMING counters across pods (each event is
# emitted by exactly one replica) and MERGING histogram buckets across pods
# (PL11) before the delta/quantile. pilot_services would be replica-invariant
# (not summed) but is not used here.
# An incomplete scrape (a pod's /metrics unreachable) undercounts the summed
# counters / merged histograms, so the istiod-side deltas are not trustworthy.
XDS_PUSHES_DELTA="N/A"; EDS_PUSHES_DELTA="N/A"; PUSH_TRIGGERS_DELTA="N/A"
CONVERGENCE_P99="N/A"; QUEUE_TIME_P99="N/A"; PUSH_TIME_P99="N/A"
if [[ "$RESTARTED" == "0" && ${#PRE_FILES[@]} -gt 0 && "$SCRAPE_INCOMPLETE" == "0" ]]; then
	# counter_delta (metrics.sh): N/A with a warning when a counter is in neither
	# scrape (renamed, never 0) or went backwards; one registered in the window counts from 0.
	XDS_PUSHES_DELTA=$(counter_delta "$(fanout_counter_sum pilot_xds_pushes ${PRE_FILES[@]+"${PRE_FILES[@]}"})" \
		"$(fanout_counter_sum pilot_xds_pushes ${POST_FILES[@]+"${POST_FILES[@]}"})" "pilot_xds_pushes on ${SOURCE_CTX}")
	EDS_PUSHES_DELTA=$(counter_delta "$(fanout_counter_by_label_sum pilot_xds_pushes type eds ${PRE_FILES[@]+"${PRE_FILES[@]}"})" \
		"$(fanout_counter_by_label_sum pilot_xds_pushes type eds ${POST_FILES[@]+"${POST_FILES[@]}"})" "pilot_xds_pushes{type=eds} on ${SOURCE_CTX}")
	PUSH_TRIGGERS_DELTA=$(counter_delta "$(fanout_counter_sum pilot_push_triggers ${PRE_FILES[@]+"${PRE_FILES[@]}"})" \
		"$(fanout_counter_sum pilot_push_triggers ${POST_FILES[@]+"${POST_FILES[@]}"})" "pilot_push_triggers on ${SOURCE_CTX}")

	for h in pilot_proxy_convergence_time pilot_proxy_queue_time pilot_xds_push_time; do
		fanout_merge_histogram "$h" "${ISTIOD_DIR}/pre-${h}.merged" ${PRE_FILES[@]+"${PRE_FILES[@]}"}
		fanout_merge_histogram "$h" "${ISTIOD_DIR}/post-${h}.merged" ${POST_FILES[@]+"${POST_FILES[@]}"}
	done
	CONVERGENCE_P99=$(delta_histogram_p99 "${ISTIOD_DIR}/pre-pilot_proxy_convergence_time.merged" "${ISTIOD_DIR}/post-pilot_proxy_convergence_time.merged" pilot_proxy_convergence_time)
	QUEUE_TIME_P99=$(delta_histogram_p99 "${ISTIOD_DIR}/pre-pilot_proxy_queue_time.merged" "${ISTIOD_DIR}/post-pilot_proxy_queue_time.merged" pilot_proxy_queue_time)
	PUSH_TIME_P99=$(delta_histogram_p99 "${ISTIOD_DIR}/pre-pilot_xds_push_time.merged" "${ISTIOD_DIR}/post-pilot_xds_push_time.merged" pilot_xds_push_time)
fi

QPS_ACTUAL="N/A"; P50="N/A"; P90="N/A"; P99="N/A"; P999="N/A"; MAX_LAT="N/A"
if [[ "$STATUS" == "OK" && -n "$JSON_OUT" ]]; then
	QPS_ACTUAL="$(printf '%s' "$JSON_OUT" | jq -r '.ActualQPS // empty' 2>/dev/null)"
	[[ -z "$QPS_ACTUAL" ]] && QPS_ACTUAL="N/A"
	P50="$(printf '%s' "$JSON_OUT"  | jq -r '(.DurationHistogram.Percentiles[]? | select(.Percentile == 50)   | .Value * 1000) // empty' 2>/dev/null)"
	[[ -z "$P50" ]] && P50="N/A"
	P90="$(printf '%s' "$JSON_OUT"  | jq -r '(.DurationHistogram.Percentiles[]? | select(.Percentile == 90)   | .Value * 1000) // empty' 2>/dev/null)"
	[[ -z "$P90" ]] && P90="N/A"
	P99="$(printf '%s' "$JSON_OUT"  | jq -r '(.DurationHistogram.Percentiles[]? | select(.Percentile == 99)   | .Value * 1000) // empty' 2>/dev/null)"
	[[ -z "$P99" ]] && P99="N/A"
	P999="$(printf '%s' "$JSON_OUT" | jq -r '(.DurationHistogram.Percentiles[]? | select(.Percentile == 99.9) | .Value * 1000) // empty' 2>/dev/null)"
	[[ -z "$P999" ]] && P999="N/A"
	MAX_LAT="$(printf '%s' "$JSON_OUT" | jq -r '(.DurationHistogram.Max // empty) * 1000' 2>/dev/null)"
	[[ -z "$MAX_LAT" ]] && MAX_LAT="N/A"
	# Error rate (tests/lib/fortio.sh; QPS-shortfall check off): non-200 responses
	# used to count as latency samples of an OK row.
	if ! [[ "$MIN_PCT_200" =~ ^0(\.0+)?$ ]]; then
		FORTIO_STATUS="$(fortio_row_status "$JSON_OUT" "$QPS" 0 "$MIN_PCT_200")"
		[[ "$FORTIO_STATUS" == OK ]] || STATUS="$FORTIO_STATUS"
	fi
fi
# pct_200 / top_code for the marker comment ("N/A" / "-" without a fortio result).
read -r _ok _total PCT_200 TOP_CODE <<<"$(reach_summarize "$JSON_OUT")"

# PL13/PL14: if istiod restarted (or unknown), poison the latency-derived
# quantiles in this row so 005 will filter it.
if [[ "$RESTARTED" != "0" ]]; then
	P50="N/A"; P90="N/A"; P99="N/A"; P999="N/A"; MAX_LAT="N/A"
	XDS_PUSHES_DELTA="N/A"; EDS_PUSHES_DELTA="N/A"; PUSH_TRIGGERS_DELTA="N/A"
	CONVERGENCE_P99="N/A"; QUEUE_TIME_P99="N/A"; PUSH_TIME_P99="N/A"
	[[ "$STATUS" == "OK" ]] && STATUS="POISONED_RESTART"
fi
# A pod's /metrics was unreachable -> the istiod-side aggregation is undercounted.
# Tag the row so 005 filters it (a non-OK status the aggregator drops).
if [[ "$SCRAPE_INCOMPLETE" == "1" && "$STATUS" == "OK" ]]; then
	STATUS="POISONED_SCRAPE"
fi

printf "Result: phase=baseline qps_actual=%s p50=%s p99=%s max=%s pct_200=%s top_code=%s restarted=%s status=%s\n" \
	"$QPS_ACTUAL" "$P50" "$P99" "$MAX_LAT" "$PCT_200" "$TOP_CODE" "$RESTARTED" "$STATUS"
printf "  istiod: xds_pushes=%s eds_pushes=%s triggers=%s conv_p99=%s queue_p99=%s push_time_p99=%s\n" \
	"$XDS_PUSHES_DELTA" "$EDS_PUSHES_DELTA" "$PUSH_TRIGGERS_DELTA" "$CONVERGENCE_P99" "$QUEUE_TIME_P99" "$PUSH_TIME_P99"

# PL3: emit wall-clock window in nanoseconds as a comment for downstream tooling.
# PL8: scrape_skew_ms spans the fanned-out per-pod istiod scrapes (max of the
# pre/post batch skews); recorded as a comment since the TSV schema is unchanged.
printf '# combo=%s phase=baseline window_start_ns=%s window_end_ns=%s istiod_replicas=%s scrape_skew_ms=%s pct_200=%s top_code=%s\n' \
	"$COMBO_ID" "$WINDOW_START_NS" "$WINDOW_END_NS" "${SOURCE_REPLICAS:-unknown}" "$SCRAPE_SKEW_MS" "$PCT_200" "$TOP_CODE" >> "$OUTPUT_FILE"

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
	"$RUN_ID" "$HARNESS_SHA" "$COMBO_ID" "$MESH_SIZE" "0" "baseline" \
	"$DURATION" "$QPS" "$QPS_ACTUAL" \
	"$P50" "$P90" "$P99" "$P999" "$MAX_LAT" \
	"N/A" "$RESTARTED" "$STATUS" \
	"N/A" "N/A" \
	"$XDS_PUSHES_DELTA" "$EDS_PUSHES_DELTA" "$PUSH_TRIGGERS_DELTA" \
	"$CONVERGENCE_P99" "$QUEUE_TIME_P99" "$PUSH_TIME_P99" >> "$OUTPUT_FILE"

echo "Wrote baseline row to $OUTPUT_FILE"

# istiod restart evidence (tests/lib/istiod-diag.sh) after the row is written, into
# istiod-diag-<RUN_ID>/ next to the output TSV. Best-effort: never changes the row or the
# exit status. Source context only, like the restart detection above.
if [[ "$RESTARTED" != "0" ]]; then
	istiod_diag_capture "$(istiod_diag_dir "$OUTPUT_FILE" "$RUN_ID")" "${COMBO_ID}-baseline" "$SOURCE_CTX" \
		"$RESTARTED" "$PRE_PODSET" "$(pre_metrics_csv)" "${KUBECTL[@]}"
fi

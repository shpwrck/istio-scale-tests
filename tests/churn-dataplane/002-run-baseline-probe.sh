#!/usr/bin/env bash
# Phase 1 of the co-exec test: run fortio against a steady mesh with NO churn,
# emitting a single baseline TSV row that captures p50/p99/p999/max latency and
# actual QPS for later comparison against the churn phase.
#
# Usage:
#   ./tests/churn-dataplane/002-run-baseline-probe.sh \
#       --source-context CTX [options]
# ci-dry-run: --source-context ci-dummy
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/timestamp.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/metrics.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fanout.sh"

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
# istiod is reached via tests/lib/fanout.sh, which allocates its own per-pod port
# block from FANOUT_PF_BASE (default 21014); COEXEC_ISTIOD_PF_PORT is no longer used.
OUTPUT_FILE=""
OUTPUT_DIR="${ROOT}/tests/churn-dataplane/results"
APPEND=0
DRY_RUN=0

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --source-context CTX     Context where fortio-client runs (required).
  --remote-contexts CSV    Other contexts in the mesh (metadata only here).
  --mesh-size N            Mesh-size tag (default: 1 + remotes).
  --combo-id ID            Stable id linking baseline+churn rows in 004 (default: \$RUN_ID).
  --run-id ID              Reuse a prior run_id (default: fresh timestamp).
  --duration SEC           Fortio duration (default: $DURATION).
  --qps N                  Target QPS (default: $QPS).
  --connections N          Concurrent connections (default: $CONNECTIONS).
  --settle-sec N           Settle delay before measurement starts (default: $SETTLE_SEC).
  --output-file FILE       TSV file to write/append to (default: tests/churn-dataplane/results/coexec-\$RUN_ID.tsv).
  --output-dir DIR         Default results dir if --output-file not given.
  --append                 Append to --output-file without rewriting preamble/header.
  --dry-run                Print plan only.
  -h, --help               Show this help.

Environment:
  COEXEC_BASELINE_DURATION_SEC, COEXEC_QPS, COEXEC_NUM_CONNECTIONS, COEXEC_SETTLE_SEC,
  COEXEC_TEST_NAMESPACE, COEXEC_ISTIOD_REPLICAS (expected pin; warns on mismatch),
  FANOUT_PF_BASE (per-pod istiod port-forward block base; default 21014).
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
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

[[ -n "$SOURCE_CTX" ]] || die "--source-context is required"

if command -v oc >/dev/null 2>&1; then
	KUBECTL=(oc)
elif command -v kubectl >/dev/null 2>&1; then
	KUBECTL=(kubectl)
else
	die "neither oc nor kubectl found on PATH"
fi
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
command -v curl >/dev/null 2>&1 || die "curl not found on PATH"

REMOTES=()
[[ -n "$REMOTE_CONTEXTS_CSV" ]] && split_csv "$REMOTE_CONTEXTS_CSV" REMOTES
[[ -z "$MESH_SIZE" ]] && MESH_SIZE=$(( 1 + ${#REMOTES[@]} ))

RUN_ID="${RUN_ID_OPT:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
[[ -z "$COMBO_ID" ]] && COMBO_ID="$RUN_ID"

mkdir -p "$OUTPUT_DIR"
[[ -z "$OUTPUT_FILE" ]] && OUTPUT_FILE="${OUTPUT_DIR}/churn-dataplane-${RUN_ID}.tsv"

HARNESS_SHA="$(harness_sha)"
ALL_CTXS_CSV="$SOURCE_CTX"
for r in "${REMOTES[@]}"; do ALL_CTXS_CSV+=",$r"; done

if ((DRY_RUN)); then
	echo "=== Dry-run: baseline probe ==="
	echo "Source: $SOURCE_CTX | Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
	echo "Duration: ${DURATION}s | QPS: $QPS | Connections: $CONNECTIONS | Settle: ${SETTLE_SEC}s"
	echo "Output: $OUTPUT_FILE (append=$APPEND)"
	echo "RUN_ID=$RUN_ID  COMBO_ID=$COMBO_ID  HARNESS_SHA=$HARNESS_SHA"
	exit 0
fi

# PL2: probe kube versions concurrently with 5s --request-timeout.
KUBE_VERSIONS_CSV="$(probe_kube_versions "$ALL_CTXS_CSV" "${KUBECTL[@]}")"

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
		"ISTIO_VERSION=${ISTIO_VERSION:-unknown}" \
		"KUBE_VERSIONS=$KUBE_VERSIONS_CSV" \
		"ISTIOD_REPLICAS=$SOURCE_REPLICAS" \
		"SETTLE_SEC=$SETTLE_SEC" \
		"BASELINE_DURATION_SEC=$DURATION" \
		"CHURN_DURATION_SEC=${COEXEC_CHURN_DURATION_SEC:-$DURATION}" \
		"QPS=$QPS" \
		"CONNECTIONS=$CONNECTIONS" \
		"NAMESPACE=$NS"
	printf 'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms\n' >> "$OUTPUT_FILE"
fi

CLIENT_POD="$("${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" get pod -l app=fortio-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$CLIENT_POD" ]] || die "no fortio-client pod found on $SOURCE_CTX (ns=$NS)"

# Fan out a port-forward to EVERY Running istiod pod on the source context
# (tests/lib/fanout.sh) for restart-detection and istiod-side xDS metrics.
# ISTIOD_PF_PORT is no longer used directly — fanout allocates a collision-free
# per-pod port block (source context = ctx_index 0).
PF_PIDS=()
ISTIOD_PORTS=()
ISTIOD_PODS=()
ISTIOD_DIR="$(mktemp -d)"
PF_OK=0
cleanup_pf() {
	for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
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
	fanout_record_podset "$SOURCE_CTX" "$PRE_PODSET" "${KUBECTL[@]}"
	PRE_SKEW_MS="$(fanout_scrape_all "$ISTIOD_DIR" "pre" "${ISTIOD_PORTS[@]}")"
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
if ! JSON_OUT="$("${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" exec "$CLIENT_POD" -c fortio -- \
	fortio load -qps "$QPS" -c "$CONNECTIONS" -t "${DURATION}s" -json - -quiet "$TARGET_URL" 2>/dev/null)"; then
	STATUS="FAILED"
	JSON_OUT=""
fi
WINDOW_END_NS="$(now_ns)"

# Post-window scrape of every istiod pod (concurrent) + pod set.
POST_PODSET="${ISTIOD_DIR}/post.podset"
POST_SKEW_MS=0
if ((PF_OK)); then
	fanout_record_podset "$SOURCE_CTX" "$POST_PODSET" "${KUBECTL[@]}"
	POST_SKEW_MS="$(fanout_scrape_all "$ISTIOD_DIR" "post" "${ISTIOD_PORTS[@]}")"
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
	pre_pushes=$(fanout_counter_sum pilot_xds_pushes "${PRE_FILES[@]}")
	post_pushes=$(fanout_counter_sum pilot_xds_pushes "${POST_FILES[@]}")
	XDS_PUSHES_DELTA=$(( post_pushes - pre_pushes ))
	(( XDS_PUSHES_DELTA < 0 )) && XDS_PUSHES_DELTA="N/A"

	pre_eds=$(fanout_counter_by_label_sum pilot_xds_pushes type eds "${PRE_FILES[@]}")
	post_eds=$(fanout_counter_by_label_sum pilot_xds_pushes type eds "${POST_FILES[@]}")
	EDS_PUSHES_DELTA=$(( post_eds - pre_eds ))
	(( EDS_PUSHES_DELTA < 0 )) && EDS_PUSHES_DELTA="N/A"

	pre_triggers=$(fanout_counter_sum pilot_push_triggers "${PRE_FILES[@]}")
	post_triggers=$(fanout_counter_sum pilot_push_triggers "${POST_FILES[@]}")
	PUSH_TRIGGERS_DELTA=$(( post_triggers - pre_triggers ))
	(( PUSH_TRIGGERS_DELTA < 0 )) && PUSH_TRIGGERS_DELTA="N/A"

	for h in pilot_proxy_convergence_time pilot_proxy_queue_time pilot_xds_push_time; do
		fanout_merge_histogram "$h" "${ISTIOD_DIR}/pre-${h}.merged" "${PRE_FILES[@]}"
		fanout_merge_histogram "$h" "${ISTIOD_DIR}/post-${h}.merged" "${POST_FILES[@]}"
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
fi

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

printf "Result: phase=baseline qps_actual=%s p50=%s p99=%s max=%s restarted=%s status=%s\n" \
	"$QPS_ACTUAL" "$P50" "$P99" "$MAX_LAT" "$RESTARTED" "$STATUS"
printf "  istiod: xds_pushes=%s eds_pushes=%s triggers=%s conv_p99=%s queue_p99=%s push_time_p99=%s\n" \
	"$XDS_PUSHES_DELTA" "$EDS_PUSHES_DELTA" "$PUSH_TRIGGERS_DELTA" "$CONVERGENCE_P99" "$QUEUE_TIME_P99" "$PUSH_TIME_P99"

# PL3: emit wall-clock window in nanoseconds as a comment for downstream tooling.
# PL8: scrape_skew_ms spans the fanned-out per-pod istiod scrapes (max of the
# pre/post batch skews); recorded as a comment since the TSV schema is unchanged.
printf '# combo=%s phase=baseline window_start_ns=%s window_end_ns=%s istiod_replicas=%s scrape_skew_ms=%s\n' \
	"$COMBO_ID" "$WINDOW_START_NS" "$WINDOW_END_NS" "${SOURCE_REPLICAS:-unknown}" "$SCRAPE_SKEW_MS" >> "$OUTPUT_FILE"

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
	"$RUN_ID" "$HARNESS_SHA" "$COMBO_ID" "$MESH_SIZE" "0" "baseline" \
	"$DURATION" "$QPS" "$QPS_ACTUAL" \
	"$P50" "$P90" "$P99" "$P999" "$MAX_LAT" \
	"N/A" "$RESTARTED" "$STATUS" \
	"N/A" "N/A" \
	"$XDS_PUSHES_DELTA" "$EDS_PUSHES_DELTA" "$PUSH_TRIGGERS_DELTA" \
	"$CONVERGENCE_P99" "$QUEUE_TIME_P99" "$PUSH_TIME_P99" >> "$OUTPUT_FILE"

echo "Wrote baseline row to $OUTPUT_FILE"

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
source "${ROOT}/tests/churn-dataplane/lib/preamble.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/churn-dataplane/lib/metrics.sh"

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
ISTIOD_PF_PORT="${COEXEC_ISTIOD_PF_PORT:-15014}"
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
  COEXEC_TEST_NAMESPACE, COEXEC_ISTIOD_PF_PORT.
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

if [[ ! -f "$OUTPUT_FILE" || "$APPEND" -eq 0 ]]; then
	write_preamble "$OUTPUT_FILE" \
		"RUN_ID=$RUN_ID" \
		"HARNESS_SHA=$HARNESS_SHA" \
		"ISTIO_VERSION=${ISTIO_VERSION:-unknown}" \
		"KUBE_VERSIONS=$KUBE_VERSIONS_CSV" \
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

# Start istiod port-forward for restart-detection and metric scrapes.
PF_PID=""
PRE_SCRAPE=""; POST_SCRAPE=""
cleanup_pf() {
	if [[ -n "$PF_PID" ]]; then kill "$PF_PID" 2>/dev/null || true; wait "$PF_PID" 2>/dev/null || true; fi
	rm -f "${PRE_SCRAPE:-}" "${POST_SCRAPE:-}"
}
trap cleanup_pf EXIT

start_istiod_pf() {
	"${KUBECTL[@]}" --context="$SOURCE_CTX" -n istio-system port-forward svc/istiod "${ISTIOD_PF_PORT}":15014 >/dev/null 2>&1 &
	PF_PID=$!
	local attempts=0
	while ! curl -fsS --max-time 2 "http://localhost:${ISTIOD_PF_PORT}/metrics" -o /dev/null 2>/dev/null; do
		attempts=$((attempts + 1))
		((attempts > 30)) && { echo "warn: istiod port-forward did not come up; istiod_restarted will be 'unknown'" >&2; return 1; }
		sleep 0.5
	done
	return 0
}
ISTIOD_PF_OK=0
if start_istiod_pf; then ISTIOD_PF_OK=1; fi

# PL9 / PL21 / PL22: single pre-window scrape to temp file for restart detection
# and istiod-side xDS metrics.
PRE_SCRAPE="$(mktemp)"
if ((ISTIOD_PF_OK)); then
	scrape_istiod_metrics "$ISTIOD_PF_PORT" "$PRE_SCRAPE" || ISTIOD_PF_OK=0
fi
PRE_START="unknown"
if ((ISTIOD_PF_OK)) && [[ -s "$PRE_SCRAPE" ]]; then
	PRE_START="$(extract_gauge "$PRE_SCRAPE" process_start_time_seconds)"
fi

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

POST_SCRAPE="$(mktemp)"
if ((ISTIOD_PF_OK)); then
	scrape_istiod_metrics "$ISTIOD_PF_PORT" "$POST_SCRAPE" || true
fi
POST_START="unknown"
if ((ISTIOD_PF_OK)) && [[ -s "$POST_SCRAPE" ]]; then
	POST_START="$(extract_gauge "$POST_SCRAPE" process_start_time_seconds)"
fi
RESTARTED="$(istiod_restart_status "$PRE_START" "$POST_START")"

# Extract istiod-side xDS metrics from pre/post scrape files.
XDS_PUSHES_DELTA="N/A"; EDS_PUSHES_DELTA="N/A"; PUSH_TRIGGERS_DELTA="N/A"
CONVERGENCE_P99="N/A"; QUEUE_TIME_P99="N/A"; PUSH_TIME_P99="N/A"
if [[ "$RESTARTED" == "0" && -s "$PRE_SCRAPE" && -s "$POST_SCRAPE" ]]; then
	pre_pushes=$(extract_counter_sum "$PRE_SCRAPE" pilot_xds_pushes)
	post_pushes=$(extract_counter_sum "$POST_SCRAPE" pilot_xds_pushes)
	XDS_PUSHES_DELTA=$(( post_pushes - pre_pushes ))
	(( XDS_PUSHES_DELTA < 0 )) && XDS_PUSHES_DELTA="N/A"

	pre_eds=$(extract_counter_by_label "$PRE_SCRAPE" pilot_xds_pushes type eds)
	post_eds=$(extract_counter_by_label "$POST_SCRAPE" pilot_xds_pushes type eds)
	EDS_PUSHES_DELTA=$(( post_eds - pre_eds ))
	(( EDS_PUSHES_DELTA < 0 )) && EDS_PUSHES_DELTA="N/A"

	pre_triggers=$(extract_counter_sum "$PRE_SCRAPE" pilot_push_triggers)
	post_triggers=$(extract_counter_sum "$POST_SCRAPE" pilot_push_triggers)
	PUSH_TRIGGERS_DELTA=$(( post_triggers - pre_triggers ))
	(( PUSH_TRIGGERS_DELTA < 0 )) && PUSH_TRIGGERS_DELTA="N/A"

	CONVERGENCE_P99=$(delta_histogram_p99 "$PRE_SCRAPE" "$POST_SCRAPE" pilot_proxy_convergence_time)
	QUEUE_TIME_P99=$(delta_histogram_p99 "$PRE_SCRAPE" "$POST_SCRAPE" pilot_proxy_queue_time)
	PUSH_TIME_P99=$(delta_histogram_p99 "$PRE_SCRAPE" "$POST_SCRAPE" pilot_xds_push_time)
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

printf "Result: phase=baseline qps_actual=%s p50=%s p99=%s max=%s restarted=%s status=%s\n" \
	"$QPS_ACTUAL" "$P50" "$P99" "$MAX_LAT" "$RESTARTED" "$STATUS"
printf "  istiod: xds_pushes=%s eds_pushes=%s triggers=%s conv_p99=%s queue_p99=%s push_time_p99=%s\n" \
	"$XDS_PUSHES_DELTA" "$EDS_PUSHES_DELTA" "$PUSH_TRIGGERS_DELTA" "$CONVERGENCE_P99" "$QUEUE_TIME_P99" "$PUSH_TIME_P99"

# PL3: emit wall-clock window in nanoseconds as a comment for downstream tooling.
printf '# combo=%s phase=baseline window_start_ns=%s window_end_ns=%s\n' \
	"$COMBO_ID" "$WINDOW_START_NS" "$WINDOW_END_NS" >> "$OUTPUT_FILE"

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
	"$RUN_ID" "$HARNESS_SHA" "$COMBO_ID" "$MESH_SIZE" "0" "baseline" \
	"$DURATION" "$QPS" "$QPS_ACTUAL" \
	"$P50" "$P90" "$P99" "$P999" "$MAX_LAT" \
	"N/A" "$RESTARTED" "$STATUS" \
	"N/A" "N/A" \
	"$XDS_PUSHES_DELTA" "$EDS_PUSHES_DELTA" "$PUSH_TRIGGERS_DELTA" \
	"$CONVERGENCE_P99" "$QUEUE_TIME_P99" "$PUSH_TIME_P99" >> "$OUTPUT_FILE"

echo "Wrote baseline row to $OUTPUT_FILE"

#!/usr/bin/env bash
# Phase 2 of the co-exec test: run fortio identically to the baseline phase,
# while a deterministic churn driver scales churn-target Deployments at a
# configurable rate. Emits a churn-phase TSV row, and if --baseline-file points
# at a TSV containing a matching baseline row, also computes Δp99_ms.
#
# Usage:
#   ./tests/churn-dataplane/003-run-churn-probe.sh \
#       --source-context CTX --churn-rate 5 [options]
# ci-dry-run: --source-context ci-dummy --churn-rate 5
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
CHURN_RATE=""
DURATION="${COEXEC_CHURN_DURATION_SEC:-60}"
QPS="${COEXEC_QPS:-200}"
CONNECTIONS="${COEXEC_NUM_CONNECTIONS:-8}"
SETTLE_SEC="${COEXEC_SETTLE_SEC:-10}"
CHURN_DEPLOYMENT_COUNT_OPT="${CHURN_DEPLOYMENT_COUNT:-10}"
CHURN_BASE_REPLICAS_OPT="${CHURN_BASE_REPLICAS:-1}"
CHURN_SCALE_TO_OPT="${CHURN_SCALE_TO_REPLICAS:-3}"
CHURN_SEED="${COEXEC_CHURN_SEED:-42}"
NS="${COEXEC_TEST_NAMESPACE:-churn-dataplane-test}"
# istiod is reached via tests/lib/fanout.sh, which allocates its own per-pod port
# block from FANOUT_PF_BASE (default 21014); COEXEC_ISTIOD_PF_PORT is no longer used.
OUTPUT_FILE=""
OUTPUT_DIR="${ROOT}/tests/churn-dataplane/results"
BASELINE_FILE=""
DRY_RUN=0

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --source-context CTX     Context where fortio-client runs (required).
  --remote-contexts CSV    Other contexts in the mesh (churn applies to ALL).
  --mesh-size N            Mesh-size tag (default: 1 + remotes).
  --combo-id ID            Stable id linking baseline+churn rows (default: \$RUN_ID).
  --run-id ID              Reuse a prior run_id (default: fresh timestamp).
  --churn-rate N           Deployment scale operations per second (required).
  --duration SEC           Fortio + churn duration (default: $DURATION).
  --qps N                  Target QPS (default: $QPS).
  --connections N          Concurrent connections (default: $CONNECTIONS).
  --settle-sec N           Settle delay before measurement starts (default: $SETTLE_SEC).
  --deployment-count N     Churn-target Deployments to operate on (default: $CHURN_DEPLOYMENT_COUNT_OPT).
  --base-replicas N        Replicas value for "scale-down" operations (default: $CHURN_BASE_REPLICAS_OPT).
  --scale-to N             Replicas value for "scale-up" operations (default: $CHURN_SCALE_TO_OPT).
  --seed N                 Seed for the deterministic churn order (default: $CHURN_SEED).
  --output-file FILE       TSV file to append to (must already have header).
  --output-dir DIR         Default results dir if --output-file not given.
  --baseline-file FILE     Optional baseline TSV used to compute Δp99 vs same combo_id.
  --dry-run                Print plan only.
  -h, --help               Show this help.

Environment:
  COEXEC_CHURN_DURATION_SEC, COEXEC_QPS, COEXEC_NUM_CONNECTIONS, COEXEC_SETTLE_SEC,
  COEXEC_TEST_NAMESPACE, COEXEC_CHURN_SEED, COEXEC_ISTIOD_REPLICAS (expected pin;
  warns on mismatch), FANOUT_PF_BASE (per-pod istiod PF block base; default 21014),
  FANOUT_MAX_SKEW_MS (per-window scrape_skew ceiling in ms; default 1000 — a row
  whose pre/post fanout scrape skew exceeds this is tagged POISONED_SCRAPE because
  the istiod-side deltas are computed across an incoherent snapshot).

Churn-rate semantics:
  "Deployment scale operations per second". At rate=N for D seconds, exactly N*D
  scale operations are issued. Each operation alternates the replica count of the
  chosen churn-target Deployment between --base-replicas and --scale-to. The
  order of target indices is a deterministic seeded shuffle (PL16) so two
  identical configurations produce the same churn timeline.
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
	--churn-rate)
		[[ -n "${2:-}" ]] || die "--churn-rate requires a value"
		CHURN_RATE="$2"; shift 2 ;;
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
	--deployment-count)
		[[ -n "${2:-}" ]] || die "--deployment-count requires a value"
		CHURN_DEPLOYMENT_COUNT_OPT="$2"; shift 2 ;;
	--base-replicas)
		[[ -n "${2:-}" ]] || die "--base-replicas requires a value"
		CHURN_BASE_REPLICAS_OPT="$2"; shift 2 ;;
	--scale-to)
		[[ -n "${2:-}" ]] || die "--scale-to requires a value"
		CHURN_SCALE_TO_OPT="$2"; shift 2 ;;
	--seed)
		[[ -n "${2:-}" ]] || die "--seed requires a value"
		CHURN_SEED="$2"; shift 2 ;;
	--output-file)
		[[ -n "${2:-}" ]] || die "--output-file requires a value"
		OUTPUT_FILE="$2"; shift 2 ;;
	--output-dir)
		[[ -n "${2:-}" ]] || die "--output-dir requires a value"
		OUTPUT_DIR="$2"; shift 2 ;;
	--baseline-file)
		[[ -n "${2:-}" ]] || die "--baseline-file requires a value"
		BASELINE_FILE="$2"; shift 2 ;;
	--dry-run)
		DRY_RUN=1; shift ;;
	-h | --help)
		usage; exit 0 ;;
	*)
		die "unknown option: $1 (try --help)" ;;
	esac
done

[[ -n "$SOURCE_CTX" ]] || die "--source-context is required"
[[ -n "$CHURN_RATE" ]] || die "--churn-rate is required"
[[ "$CHURN_RATE" =~ ^[0-9]+$ ]] || die "--churn-rate must be a non-negative integer"

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
ALL_CTXS=("$SOURCE_CTX" "${REMOTES[@]}")

if ((DRY_RUN)); then
	echo "=== Dry-run: churn probe ==="
	echo "Source: $SOURCE_CTX | Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
	echo "Churn rate: ${CHURN_RATE}/s | Duration: ${DURATION}s | Deployments: $CHURN_DEPLOYMENT_COUNT_OPT"
	echo "Replicas: ${CHURN_BASE_REPLICAS_OPT} <-> ${CHURN_SCALE_TO_OPT} | Seed: $CHURN_SEED"
	echo "Output: $OUTPUT_FILE  Baseline: ${BASELINE_FILE:-none}"
	echo "RUN_ID=$RUN_ID  COMBO_ID=$COMBO_ID  HARNESS_SHA=$HARNESS_SHA"
	exit 0
fi

# Preflight + record the source istiod replica count (PL2). The fanout
# (tests/lib/fanout.sh) scrapes EVERY Running istiod pod, so multi-replica
# istiod is supported; we just require >= 1 pod and record provenance. Warn (do
# not die) if the count differs from the expected pin COEXEC_ISTIOD_REPLICAS.
SOURCE_REPLICAS="$(fanout_preflight_istiod "$SOURCE_CTX" "${KUBECTL[@]}")"
if [[ -n "${COEXEC_ISTIOD_REPLICAS:-}" && "$SOURCE_REPLICAS" != "$COEXEC_ISTIOD_REPLICAS" ]]; then
	echo "warn: context $SOURCE_CTX has $SOURCE_REPLICAS Running istiod pods, expected pin COEXEC_ISTIOD_REPLICAS=$COEXEC_ISTIOD_REPLICAS" >&2
fi

# Bootstrap output file if missing.
if [[ ! -f "$OUTPUT_FILE" ]]; then
	ALL_CTXS_CSV="$SOURCE_CTX"
	for r in "${REMOTES[@]}"; do ALL_CTXS_CSV+=",$r"; done
	KUBE_VERSIONS_CSV="$(probe_kube_versions "$ALL_CTXS_CSV" "${KUBECTL[@]}")"
	write_preamble "churn-dataplane co-exec test" "$OUTPUT_FILE" \
		"RUN_ID=$RUN_ID" \
		"HARNESS_SHA=$HARNESS_SHA" \
		"ISTIO_VERSION=${ISTIO_VERSION:-unknown}" \
		"KUBE_VERSIONS=$KUBE_VERSIONS_CSV" \
		"ISTIOD_REPLICAS=$SOURCE_REPLICAS" \
		"SETTLE_SEC=$SETTLE_SEC" \
		"BASELINE_DURATION_SEC=${COEXEC_BASELINE_DURATION_SEC:-$DURATION}" \
		"CHURN_DURATION_SEC=$DURATION" \
		"QPS=$QPS" \
		"CONNECTIONS=$CONNECTIONS" \
		"NAMESPACE=$NS" \
		"FANOUT_MAX_SKEW_MS=$FANOUT_MAX_SKEW_MS" \
		"FANOUT_METRICS_TIMEOUT=$FANOUT_METRICS_TIMEOUT"
	printf 'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms\n' >> "$OUTPUT_FILE"
fi

CLIENT_POD="$("${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" get pod -l app=fortio-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$CLIENT_POD" ]] || die "no fortio-client pod found on $SOURCE_CTX (ns=$NS)"

# PL16: deterministic seeded shuffle of churn-target indices [0, N).
# Implemented in awk with a linear congruential generator so we don't depend on
# `shuf` (which honors LC_ALL inconsistently and isn't always installed).
seeded_shuffle() {
	local n="$1" seed="$2"
	awk -v n="$n" -v seed="$seed" 'BEGIN {
		for (i = 0; i < n; i++) a[i] = i
		state = (seed * 1103515245 + 12345) % 2147483648
		for (i = n - 1; i > 0; i--) {
			state = (state * 1103515245 + 12345) % 2147483648
			j = state % (i + 1)
			tmp = a[i]; a[i] = a[j]; a[j] = tmp
		}
		for (i = 0; i < n; i++) printf "%d\n", a[i]
	}'
}

mapfile -t SHUFFLED_INDICES < <(seeded_shuffle "$CHURN_DEPLOYMENT_COUNT_OPT" "$CHURN_SEED")

# Per-index parity tracker (0=base, 1=scaled-up). Initial state: all at base.
declare -a PARITY=()
for ((i = 0; i < CHURN_DEPLOYMENT_COUNT_OPT; i++)); do PARITY[i]=0; done

# Fan out a port-forward to EVERY Running istiod pod on the source context
# (tests/lib/fanout.sh) for restart-detection scrapes; source context = ctx 0.
PF_PIDS=()
DRIVER_PID=""
ISTIOD_PORTS=()
ISTIOD_PODS=()
ISTIOD_DIR="$(mktemp -d)"
PF_OK=0
cleanup_all() {
	if [[ -n "$DRIVER_PID" ]]; then kill "$DRIVER_PID" 2>/dev/null || true; wait "$DRIVER_PID" 2>/dev/null || true; fi
	for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
	PF_PIDS=()
	rm -rf "${ISTIOD_DIR:-}"
}
trap cleanup_all EXIT

# fanout_open dies if no istiod pod's /metrics becomes reachable; the istiod-side
# restart detection and xDS deltas depend on it.
fanout_open "$SOURCE_CTX" 0 PF_PIDS ISTIOD_PORTS ISTIOD_PODS "${KUBECTL[@]}"
PF_OK=1

PRE_PODSET="${ISTIOD_DIR}/pre.podset"
PRE_SKEW_MS=0
SCRAPE_INCOMPLETE=0
if ((PF_OK)); then
	fanout_record_podset "$SOURCE_CTX" "$PRE_PODSET" "${KUBECTL[@]}"
	PRE_SKEW_MS="$(fanout_scrape_all "$ISTIOD_DIR" "pre" "${ISTIOD_PORTS[@]}")"
	(( $(fanout_scrape_failed_count "$ISTIOD_DIR" "pre") > 0 )) && SCRAPE_INCOMPLETE=1
fi
pre_metrics_csv() {
	local i out=""
	for i in "${!ISTIOD_PODS[@]}"; do
		[[ -n "$out" ]] && out+=","
		out+="${ISTIOD_DIR}/pre-${i}.metrics"
	done
	echo "$out"
}

echo "=== Churn phase ==="
echo "Source: $SOURCE_CTX (pod: $CLIENT_POD) | Remotes: ${REMOTES[*]:-none}"
echo "QPS=$QPS  Duration=${DURATION}s  Connections=$CONNECTIONS"
echo "Churn rate: ${CHURN_RATE}/s  Deployments: $CHURN_DEPLOYMENT_COUNT_OPT  Replicas: ${CHURN_BASE_REPLICAS_OPT}<->${CHURN_SCALE_TO_OPT}"

# PL3: settle gap distinct from measurement window.
echo "Settling for ${SETTLE_SEC}s..."
sleep "$SETTLE_SEC"

# Churn driver: in the background, issue exactly CHURN_RATE * DURATION scale
# operations spaced 1/CHURN_RATE seconds apart. Toggles each chosen index
# between base and scale-to replica counts on all contexts in parallel.
#
# Per-op log line format (tab-separated):
#   <dispatch_unix_ns>\t<exit_status>\t<deployment_index>
# where:
#   - <dispatch_unix_ns> is the wall-clock at the moment the parallel
#     `kubectl scale` fan-out is dispatched (BEFORE `wait`), not at op
#     completion. This is what downstream consumers (and 005) must use to
#     validate the achieved rate, otherwise apiserver/scheduler latency
#     would conflate with scheduling drift.
#   - <exit_status> is 0 on success, non-zero if any of the parallel kubectl
#     scale invocations for this op returned non-zero (e.g. 429 from
#     kube-apiserver). 005 uses this to compute churn_ops_succeeded.
CHURN_LOG="$(mktemp)"
run_churn_driver() {
	local pos=0
	local total_ops=$(( CHURN_RATE * DURATION ))
	if ((CHURN_RATE <= 0)); then
		# Avoid divide-by-zero when CHURN_RATE=0 (steady-mesh-but-still-in-churn-phase).
		total_ops=0
	fi
	# Drift-compensated scheduling: rather than sleeping a fixed slice per op
	# (which lets the kubectl scale + subshell-fork overhead silently bleed
	# the effective rate below the target at high rates), we compute the
	# absolute target wall-clock for each op against the loop start and sleep
	# the residual. This keeps the long-run rate honest.
	local period_ns=0
	if ((CHURN_RATE > 0)); then
		period_ns=$(( 1000000000 / CHURN_RATE ))
	fi
	local start_ns
	start_ns="$(now_ns)"
	local op idx replicas ctx exit_status pid rc dispatch_ns
	local -a scale_pids
	for ((op = 0; op < total_ops; op++)); do
		idx="${SHUFFLED_INDICES[pos % ${#SHUFFLED_INDICES[@]}]}"
		pos=$((pos + 1))
		if (( PARITY[idx] == 0 )); then
			replicas="$CHURN_SCALE_TO_OPT"
			PARITY[idx]=1
		else
			replicas="$CHURN_BASE_REPLICAS_OPT"
			PARITY[idx]=0
		fi
		# Capture dispatch wall-clock BEFORE the kubectl scale fan-out so the
		# per-op timestamp reflects when the op was issued, not when its
		# apiserver ACKs all completed. See header comment for rationale.
		dispatch_ns="$(now_ns)"
		scale_pids=()
		for ctx in "${ALL_CTXS[@]}"; do
			"${KUBECTL[@]}" --context="$ctx" -n "$NS" scale "deployment/churn-target-${idx}" \
				--replicas="$replicas" >/dev/null 2>&1 &
			scale_pids+=($!)
		done
		# Capture exit status for accounting (A4): non-zero on any kube-apiserver
		# 429 / connection error / not-found / etc. Without this the TSV reports
		# wc -l of the log and overstates actual churn at high rates.
		exit_status=0
		for pid in "${scale_pids[@]}"; do
			if wait "$pid"; then rc=0; else rc=$?; fi
			(( rc != 0 )) && exit_status="$rc"
		done
		printf '%s\t%s\t%s\n' "$dispatch_ns" "$exit_status" "$idx" >> "$CHURN_LOG"
		# Drift compensation: sleep until start_ns + (op+1) * period_ns.
		if ((period_ns > 0)); then
			local target_ns now_ns delta_ns
			target_ns=$(( start_ns + (op + 1) * period_ns ))
			now_ns="$(now_ns)"
			delta_ns=$(( target_ns - now_ns ))
			if (( delta_ns > 0 )); then
				sleep "$(awk -v n="$delta_ns" 'BEGIN{printf "%.9f", n/1e9}')"
			fi
		fi
	done
}
if ((CHURN_RATE > 100)); then
	echo "warn: churn-rate ${CHURN_RATE} exceeds the practical ceiling (~100 ops/s); per-op subshell overhead may cause the driver to fall behind" >&2
fi
run_churn_driver &
DRIVER_PID=$!

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

# Stop the churn driver. Only SIGTERM if fortio exited EARLY (before DURATION
# elapsed); otherwise the driver has finished its CHURN_RATE * DURATION ops
# and is about to return on its own — `wait` lets it flush its final per-op
# accounting write to $CHURN_LOG. Killing mid-`wait` on the scale fan-out
# could otherwise bias churn_ops_attempted/succeeded low by up to one op (R2).
ELAPSED_NS=$(( WINDOW_END_NS - WINDOW_START_NS ))
DURATION_NS=$(( DURATION * 1000000000 ))
if [[ "$STATUS" == "FAILED" ]] || (( ELAPSED_NS < DURATION_NS )); then
	kill "$DRIVER_PID" 2>/dev/null || true
fi
wait "$DRIVER_PID" 2>/dev/null || true
DRIVER_PID=""

POST_PODSET="${ISTIOD_DIR}/post.podset"
POST_SKEW_MS=0
if ((PF_OK)); then
	fanout_record_podset "$SOURCE_CTX" "$POST_PODSET" "${KUBECTL[@]}"
	POST_SKEW_MS="$(fanout_scrape_all "$ISTIOD_DIR" "post" "${ISTIOD_PORTS[@]}")"
	(( $(fanout_scrape_failed_count "$ISTIOD_DIR" "post") > 0 )) && SCRAPE_INCOMPLETE=1
fi
# PL8: per-window scrape skew now spans pods (max of pre/post batches).
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

# A4: churn-ops accounting. The driver log has one line per attempted op,
# each tab-prefixed with the exit status of the kubectl scale fan-out.
CHURN_OPS_ATTEMPTED="$(wc -l < "$CHURN_LOG" 2>/dev/null || echo 0)"
CHURN_OPS_ATTEMPTED="${CHURN_OPS_ATTEMPTED// /}"
CHURN_OPS_SUCCEEDED="$(awk -F'\t' '$2 == "0" { c++ } END { print c + 0 }' "$CHURN_LOG" 2>/dev/null || echo 0)"
rm -f "$CHURN_LOG"

# Extract istiod-side xDS metrics by SUMMING counters across pods (each event is
# emitted by exactly one replica) and MERGING histogram buckets across pods (PL11)
# before the delta/quantile.
XDS_PUSHES_DELTA="N/A"; EDS_PUSHES_DELTA="N/A"; PUSH_TRIGGERS_DELTA="N/A"
CONVERGENCE_P99="N/A"; QUEUE_TIME_P99="N/A"; PUSH_TIME_P99="N/A"
# An incomplete scrape (a pod's /metrics unreachable) undercounts the summed
# counters / merged histograms, so the istiod-side deltas are not trustworthy.
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

# PL13: istiod restarted (or unknown) -> emit N/A for derived quantiles
# and istiod counter/histogram deltas.
if [[ "$RESTARTED" != "0" ]]; then
	P50="N/A"; P90="N/A"; P99="N/A"; P999="N/A"; MAX_LAT="N/A"
	XDS_PUSHES_DELTA="N/A"; EDS_PUSHES_DELTA="N/A"; PUSH_TRIGGERS_DELTA="N/A"
	CONVERGENCE_P99="N/A"; QUEUE_TIME_P99="N/A"; PUSH_TIME_P99="N/A"
	[[ "$STATUS" == "OK" ]] && STATUS="POISONED_RESTART"
fi
# A pod's /metrics was unreachable -> istiod-side aggregation undercounted; tag
# the row so 005 filters it (a non-OK status the aggregator drops).
if [[ "$SCRAPE_INCOMPLETE" == "1" && "$STATUS" == "OK" ]]; then
	STATUS="POISONED_SCRAPE"
fi

# A4: if the driver could not keep up (e.g. apiserver 429s), mark the row so
# 005 filters it from numeric aggregation. Threshold matches the spec (<90%).
# Skip this check when CHURN_RATE=0 (no ops are expected).
if (( CHURN_RATE > 0 )) && (( CHURN_OPS_ATTEMPTED > 0 )); then
	if awk -v s="$CHURN_OPS_SUCCEEDED" -v a="$CHURN_OPS_ATTEMPTED" \
		'BEGIN { exit !(s/a < 0.9) }'; then
		# Don't overwrite POISONED_RESTART or FAILED — those signal a worse problem.
		[[ "$STATUS" == "OK" ]] && STATUS="CHURN_RATE_NOT_MET"
	fi
fi

# Δp99: look up the matching baseline row in --baseline-file, by combo_id.
# A3: gate on baseline status == "OK" (column 17). A baseline that ended in
# POISONED_RESTART / FAILED has malformed (or N/A) p99 and the resulting
# delta would be nonsense even if NF >= 17 and $12 != "N/A".
DELTA_P99="N/A"
if [[ -n "$BASELINE_FILE" && -f "$BASELINE_FILE" && "$P99" != "N/A" ]]; then
	BASELINE_P99="$(awk -F'\t' -v combo="$COMBO_ID" '
		!/^#/ && !/^run_id/ && NF >= 17 && $3 == combo && $6 == "baseline" && $17 == "OK" && $12 != "N/A" {
			print $12; exit
		}' "$BASELINE_FILE")"
	if [[ -n "$BASELINE_P99" ]]; then
		DELTA_P99="$(awk -v a="$P99" -v b="$BASELINE_P99" 'BEGIN { printf "%.2f\n", a - b }')"
	fi
fi

printf "Result: phase=churn rate=%s/s ops_attempted=%s ops_succeeded=%s qps_actual=%s p50=%s p99=%s max=%s Δp99=%s restarted=%s status=%s\n" \
	"$CHURN_RATE" "$CHURN_OPS_ATTEMPTED" "$CHURN_OPS_SUCCEEDED" "$QPS_ACTUAL" "$P50" "$P99" "$MAX_LAT" "$DELTA_P99" "$RESTARTED" "$STATUS"
printf "  istiod: xds_pushes=%s eds_pushes=%s triggers=%s conv_p99=%s queue_p99=%s push_time_p99=%s\n" \
	"$XDS_PUSHES_DELTA" "$EDS_PUSHES_DELTA" "$PUSH_TRIGGERS_DELTA" "$CONVERGENCE_P99" "$QUEUE_TIME_P99" "$PUSH_TIME_P99"

# PL8: scrape_skew_ms spans the fanned-out per-pod istiod scrapes (max of the
# pre/post batch skews); recorded as a comment since the TSV schema is unchanged.
printf '# combo=%s phase=churn window_start_ns=%s window_end_ns=%s churn_ops_attempted=%s churn_ops_succeeded=%s istiod_replicas=%s scrape_skew_ms=%s\n' \
	"$COMBO_ID" "$WINDOW_START_NS" "$WINDOW_END_NS" "$CHURN_OPS_ATTEMPTED" "$CHURN_OPS_SUCCEEDED" "${SOURCE_REPLICAS:-unknown}" "$SCRAPE_SKEW_MS" >> "$OUTPUT_FILE"

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
	"$RUN_ID" "$HARNESS_SHA" "$COMBO_ID" "$MESH_SIZE" "$CHURN_RATE" "churn" \
	"$DURATION" "$QPS" "$QPS_ACTUAL" \
	"$P50" "$P90" "$P99" "$P999" "$MAX_LAT" \
	"$DELTA_P99" "$RESTARTED" "$STATUS" \
	"$CHURN_OPS_ATTEMPTED" "$CHURN_OPS_SUCCEEDED" \
	"$XDS_PUSHES_DELTA" "$EDS_PUSHES_DELTA" "$PUSH_TRIGGERS_DELTA" \
	"$CONVERGENCE_P99" "$QUEUE_TIME_P99" "$PUSH_TIME_P99" >> "$OUTPUT_FILE"

echo "Wrote churn row to $OUTPUT_FILE"

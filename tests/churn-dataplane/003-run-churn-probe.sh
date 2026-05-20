#!/usr/bin/env bash
# Phase 2 of the co-exec test: run fortio identically to the baseline phase,
# while a deterministic churn driver scales churn-target Deployments at a
# configurable rate. Emits a churn-phase TSV row, and if --baseline-file points
# at a TSV containing a matching baseline row, also computes Δp99_ms.
#
# Usage:
#   ./tests/churn-dataplane/003-run-churn-probe.sh \
#       --source-context CTX --churn-rate 5 [options]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/churn-dataplane/lib/preamble.sh"

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
ISTIOD_PF_PORT="${COEXEC_ISTIOD_PF_PORT:-15014}"
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
  COEXEC_TEST_NAMESPACE, COEXEC_ISTIOD_PF_PORT, COEXEC_CHURN_SEED.

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

RUN_ID="${RUN_ID_OPT:-$(date +%Y%m%dT%H%M%S)-$$}"
[[ -z "$COMBO_ID" ]] && COMBO_ID="$RUN_ID"

mkdir -p "$OUTPUT_DIR"
[[ -z "$OUTPUT_FILE" ]] && OUTPUT_FILE="${OUTPUT_DIR}/coexec-${RUN_ID}.tsv"

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

# Bootstrap output file if missing.
if [[ ! -f "$OUTPUT_FILE" ]]; then
	ALL_CTXS_CSV="$SOURCE_CTX"
	for r in "${REMOTES[@]}"; do ALL_CTXS_CSV+=",$r"; done
	KUBE_VERSIONS_CSV="$(probe_kube_versions "$ALL_CTXS_CSV" "${KUBECTL[@]}")"
	write_preamble "$OUTPUT_FILE" \
		"RUN_ID=$RUN_ID" \
		"HARNESS_SHA=$HARNESS_SHA" \
		"ISTIO_VERSION=${ISTIO_VERSION:-unknown}" \
		"KUBE_VERSIONS=$KUBE_VERSIONS_CSV" \
		"SETTLE_SEC=$SETTLE_SEC" \
		"BASELINE_DURATION_SEC=${COEXEC_BASELINE_DURATION_SEC:-$DURATION}" \
		"CHURN_DURATION_SEC=$DURATION" \
		"QPS=$QPS" \
		"CONNECTIONS=$CONNECTIONS" \
		"NAMESPACE=$NS"
	printf 'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\n' >> "$OUTPUT_FILE"
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

# Start istiod port-forward for restart-detection scrapes.
PF_PID=""
DRIVER_PID=""
cleanup_all() {
	if [[ -n "$DRIVER_PID" ]]; then kill "$DRIVER_PID" 2>/dev/null || true; wait "$DRIVER_PID" 2>/dev/null || true; fi
	if [[ -n "$PF_PID" ]]; then kill "$PF_PID" 2>/dev/null || true; wait "$PF_PID" 2>/dev/null || true; fi
}
trap cleanup_all EXIT

start_istiod_pf() {
	"${KUBECTL[@]}" --context="$SOURCE_CTX" -n istio-system port-forward svc/istiod "${ISTIOD_PF_PORT}":15014 >/dev/null 2>&1 &
	PF_PID=$!
	local attempts=0
	while ! curl -fsS --max-time 2 "http://localhost:${ISTIOD_PF_PORT}/metrics" -o /dev/null 2>/dev/null; do
		attempts=$((attempts + 1))
		((attempts > 30)) && { echo "warn: istiod port-forward did not come up" >&2; return 1; }
		sleep 0.5
	done
	return 0
}
ISTIOD_PF_OK=0
if start_istiod_pf; then ISTIOD_PF_OK=1; fi

PRE_START="$(istiod_start_time_seconds "$ISTIOD_PF_PORT" 2>/dev/null || echo "unknown")"
((ISTIOD_PF_OK)) || PRE_START="unknown"

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
	start_ns="$(date +%s%N)"
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
		dispatch_ns="$(date +%s%N)"
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
			now_ns="$(date +%s%N)"
			delta_ns=$(( target_ns - now_ns ))
			if (( delta_ns > 0 )); then
				sleep "$(awk -v n="$delta_ns" 'BEGIN{printf "%.9f", n/1e9}')"
			fi
		fi
	done
}
run_churn_driver &
DRIVER_PID=$!

TARGET_URL="http://fortio-server.${NS}.svc.cluster.local:${COEXEC_SERVICE_PORT:-8080}/echo"
WINDOW_START_NS="$(date +%s%N)"
JSON_OUT=""
STATUS="OK"
if ! JSON_OUT="$("${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" exec "$CLIENT_POD" -c fortio -- \
	fortio load -qps "$QPS" -c "$CONNECTIONS" -t "${DURATION}s" -json - -quiet "$TARGET_URL" 2>/dev/null)"; then
	STATUS="FAILED"
	JSON_OUT=""
fi
WINDOW_END_NS="$(date +%s%N)"

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

POST_START="$(istiod_start_time_seconds "$ISTIOD_PF_PORT" 2>/dev/null || echo "unknown")"
((ISTIOD_PF_OK)) || POST_START="unknown"
RESTARTED="$(istiod_restart_status "$PRE_START" "$POST_START")"

# A4: churn-ops accounting. The driver log has one line per attempted op,
# each tab-prefixed with the exit status of the kubectl scale fan-out.
CHURN_OPS_ATTEMPTED="$(wc -l < "$CHURN_LOG" 2>/dev/null || echo 0)"
CHURN_OPS_ATTEMPTED="${CHURN_OPS_ATTEMPTED// /}"
CHURN_OPS_SUCCEEDED="$(awk -F'\t' '$2 == "0" { c++ } END { print c + 0 }' "$CHURN_LOG" 2>/dev/null || echo 0)"
rm -f "$CHURN_LOG"

QPS_ACTUAL=0; P50=0; P90=0; P99=0; P999=0; MAX_LAT=0
if [[ "$STATUS" == "OK" && -n "$JSON_OUT" ]]; then
	QPS_ACTUAL="$(printf '%s' "$JSON_OUT" | jq -r '.ActualQPS // 0' 2>/dev/null || echo 0)"
	P50="$(printf '%s' "$JSON_OUT"  | jq -r '((.DurationHistogram.Percentiles[]? | select(.Percentile == 50)   | .Value) // 0) * 1000' 2>/dev/null || echo 0)"
	P90="$(printf '%s' "$JSON_OUT"  | jq -r '((.DurationHistogram.Percentiles[]? | select(.Percentile == 90)   | .Value) // 0) * 1000' 2>/dev/null || echo 0)"
	P99="$(printf '%s' "$JSON_OUT"  | jq -r '((.DurationHistogram.Percentiles[]? | select(.Percentile == 99)   | .Value) // 0) * 1000' 2>/dev/null || echo 0)"
	P999="$(printf '%s' "$JSON_OUT" | jq -r '((.DurationHistogram.Percentiles[]? | select(.Percentile == 99.9) | .Value) // 0) * 1000' 2>/dev/null || echo 0)"
	MAX_LAT="$(printf '%s' "$JSON_OUT" | jq -r '(.DurationHistogram.Max // 0) * 1000' 2>/dev/null || echo 0)"
fi

# PL13: istiod restarted (or unknown) -> emit N/A for derived quantiles.
if [[ "$RESTARTED" != "0" ]]; then
	P50="N/A"; P90="N/A"; P99="N/A"; P999="N/A"; MAX_LAT="N/A"
	[[ "$STATUS" == "OK" ]] && STATUS="POISONED_RESTART"
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

printf '# combo=%s phase=churn window_start_ns=%s window_end_ns=%s churn_ops_attempted=%s churn_ops_succeeded=%s\n' \
	"$COMBO_ID" "$WINDOW_START_NS" "$WINDOW_END_NS" "$CHURN_OPS_ATTEMPTED" "$CHURN_OPS_SUCCEEDED" >> "$OUTPUT_FILE"

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
	"$RUN_ID" "$HARNESS_SHA" "$COMBO_ID" "$MESH_SIZE" "$CHURN_RATE" "churn" \
	"$DURATION" "$QPS" "$QPS_ACTUAL" \
	"$P50" "$P90" "$P99" "$P999" "$MAX_LAT" \
	"$DELTA_P99" "$RESTARTED" "$STATUS" \
	"$CHURN_OPS_ATTEMPTED" "$CHURN_OPS_SUCCEEDED" >> "$OUTPUT_FILE"

echo "Wrote churn row to $OUTPUT_FILE"

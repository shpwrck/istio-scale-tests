#!/usr/bin/env bash
# Measure control-plane convergence time under endpoint churn.
# Simultaneously scales deployments on all clusters, then polls istiod and
# sidecar admin endpoints to measure how long until the mesh converges.
#
# Usage:
#   ./tests/churn/002-run-churn-probe.sh --source-context CTX [options]
#
# Examples:
#   # 2-cluster churn test:
#   ./tests/churn/002-run-churn-probe.sh --source-context cluster-001 --remote-contexts cluster-002
#
#   # Scale 10 deployments from 1 to 10 replicas:
#   ./tests/churn/002-run-churn-probe.sh --source-context cluster-001 \
#     --deployment-count 10 --scale-to 10 --iterations 3
# ci-dry-run: --source-context ci-dummy
set -euo pipefail

# Loud-fail diagnostics: a bare command failing under `set -e` otherwise aborts
# silently (see the churn size-8 scrape abort: a bare `scrape_ctx` propagated
# `fanout_scrape_all`'s by-design non-zero on an incomplete scrape). Surface the
# line + command so any future abort is diagnosable instead of a truncated log.
# shellcheck disable=SC2154  # rc is assigned at the head of the trap body
trap 'rc=$?; echo "FATAL: ${0##*/} aborted (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/timestamp.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/metrics.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fanout.sh"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

SOURCE_CTX=""
REMOTE_CONTEXTS_CSV=""
MESH_SIZE=""
DEPLOYMENT_COUNT="${CHURN_DEPLOYMENT_COUNT:-5}"
BASE_REPLICAS="${CHURN_BASE_REPLICAS:-1}"
SCALE_TO="${CHURN_SCALE_TO_REPLICAS:-5}"
ITERATIONS="${CHURN_ITERATIONS:-5}"
TIMEOUT_SEC="${CHURN_TIMEOUT_SEC:-120}"
SETTLE_SEC="${CHURN_SETTLE_SEC:-3}"
POLL_INTERVAL_S="0.$(printf '%03d' "${CHURN_POLL_INTERVAL_MS:-250}")"
OUTPUT_DIR="${ROOT}/tests/churn/results"
DRY_RUN=0
NS="${CHURN_TEST_NAMESPACE:-churn-test}"
# istiod is reached via tests/lib/fanout.sh (per-pod port block from FANOUT_PF_BASE,
# default 21014). The envoy watcher PF block is unchanged.
BASE_ENVOY_PF_PORT=15100

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --source-context CTX     Kube context for the source cluster (required).
  --remote-contexts CSV    Remote cluster contexts (comma-separated).
  --mesh-size N            Metadata tag (default: 1 + remotes).
  --deployment-count N     Churn target deployments (default: $DEPLOYMENT_COUNT).
  --scale-to N             Scale targets to N replicas (default: $SCALE_TO).
  --iterations N           Number of churn iterations (default: $ITERATIONS).
  --timeout SEC            Timeout per iteration (default: $TIMEOUT_SEC).
  --settle SEC             Settle time after scale-down convergence (default: $SETTLE_SEC).
  --output-dir DIR         Results directory (default: tests/churn/results).
  --dry-run                Show plan without executing.
  -h, --help               Show this help.

Output:
  Three remote convergence signals per iteration:
    convergence_local_ms          local syncz all-SYNCED time.
    remote_endpoint_reachable_ms  data-plane reachability (Envoy health_flags,
                                  includes pod scheduling + sidecar start).
    convergence_remote_eds_ms     control-plane only — time to the FIRST remote
                                  EDS push after t0 (pilot_xds_pushes{type=eds}
                                  delta >= 1, pod-boot-free).

Environment:
  SETUP_CONTEXTS               Default comma-separated contexts (see config/versions.env).
  CHURN_TEST_NAMESPACE         Namespace for churn-target/watcher workloads (default churn-test).
  CHURN_DEPLOYMENT_COUNT       Default --deployment-count.
  CHURN_BASE_REPLICAS          Replica count targets scale back down to.
  CHURN_SCALE_TO_REPLICAS      Default --scale-to.
  CHURN_ITERATIONS             Default --iterations.
  CHURN_TIMEOUT_SEC            Default --timeout.
  CHURN_SETTLE_SEC             Default --settle.
  CHURN_POLL_INTERVAL_MS       syncz / endpoint poll interval in ms.
  FANOUT_PF_BASE               Per-pod istiod port-forward block base (default 21014).
  FANOUT_CTX_STRIDE            Per-context port stride (default 20).
EOF
}


while [[ $# -gt 0 ]]; do
	case "$1" in
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
		MESH_SIZE="$2"
		shift 2
		;;
	--deployment-count)
		[[ -n "${2:-}" ]] || die "--deployment-count requires a value"
		DEPLOYMENT_COUNT="$2"
		shift 2
		;;
	--scale-to)
		[[ -n "${2:-}" ]] || die "--scale-to requires a value"
		SCALE_TO="$2"
		shift 2
		;;
	--iterations)
		[[ -n "${2:-}" ]] || die "--iterations requires a value"
		ITERATIONS="$2"
		shift 2
		;;
	--timeout)
		[[ -n "${2:-}" ]] || die "--timeout requires a value"
		TIMEOUT_SEC="$2"
		shift 2
		;;
	--settle)
		[[ -n "${2:-}" ]] || die "--settle requires a value"
		SETTLE_SEC="$2"
		shift 2
		;;
	--output-dir)
		[[ -n "${2:-}" ]] || die "--output-dir requires a value"
		OUTPUT_DIR="$2"
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

[[ -n "$SOURCE_CTX" ]] || die "--source-context is required"

if command -v oc >/dev/null 2>&1; then
	KUBECTL=(oc)
elif command -v kubectl >/dev/null 2>&1; then
	KUBECTL=(kubectl)
else
	die "neither oc nor kubectl found on PATH"
fi

command -v curl >/dev/null 2>&1 || die "curl not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

REMOTES=()
if [[ -n "$REMOTE_CONTEXTS_CSV" ]]; then
	split_csv "$REMOTE_CONTEXTS_CSV" REMOTES
fi

[[ -z "$MESH_SIZE" ]] && MESH_SIZE=$(( 1 + ${#REMOTES[@]} ))
ALL_CTXS=("$SOURCE_CTX" "${REMOTES[@]}")

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$OUTPUT_DIR"
TSV_FILE="${OUTPUT_DIR}/churn-${RUN_ID}.tsv"

if ((DRY_RUN)); then
	echo "=== Dry-run: churn probe ==="
	echo "Source: $SOURCE_CTX | Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
	echo "Deployments: $DEPLOYMENT_COUNT | Scale: $BASE_REPLICAS -> $SCALE_TO | Iterations: $ITERATIONS"
	exit 0
fi

# Preflight every context: require >= 1 Running istiod pod. Multi-replica istiod
# is supported via the per-pod fanout (tests/lib/fanout.sh); record the source
# replica count for the TSV preamble (PL2).
echo "Preflighting istiod replicas..."
SOURCE_REPLICAS="$(fanout_preflight_istiod "$SOURCE_CTX" "${KUBECTL[@]}")"
echo "  [$SOURCE_CTX] Running istiod replicas: $SOURCE_REPLICAS"
for ctx in "${REMOTES[@]}"; do
	r="$(fanout_preflight_istiod "$ctx" "${KUBECTL[@]}")"
	echo "  [$ctx] Running istiod replicas: $r"
done

cat > "$TSV_FILE" <<EOF
# Churn convergence test — $(date -Iseconds)
# Source: $SOURCE_CTX  Remotes: ${REMOTES[*]:-none}  Mesh size: $MESH_SIZE
# Deployments: $DEPLOYMENT_COUNT  Scale: $BASE_REPLICAS -> $SCALE_TO  Iterations: $ITERATIONS
# ISTIOD_REPLICAS=$SOURCE_REPLICAS
EOF
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
	run_id mesh_size churn_intensity base_replicas scale_to iteration t0_epoch_ns \
	convergence_local_ms remote_endpoint_reachable_ms convergence_remote_eds_ms \
	source_push_triggers_delta remote_push_triggers_delta \
	source_xds_pushes_delta remote_xds_pushes_delta \
	source_queue_time_p99_ms remote_queue_time_p99_ms \
	source_connected_proxies remote_connected_proxies \
	source_push_time_p99_ms remote_push_time_p99_ms \
	status >> "$TSV_FILE"

PF_PIDS=()
POLL_PIDS=()

cleanup() {
	for pid in "${POLL_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
	POLL_PIDS=()
	for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
	PF_PIDS=()
}
trap cleanup EXIT

start_envoy_port_forward() {
	local ctx="$1" local_port="$2"
	"${KUBECTL[@]}" --context="$ctx" -n "$NS" port-forward deploy/churn-watcher "$local_port":15000 >/dev/null 2>&1 &
	PF_PIDS+=($!)
	local attempts=0
	while ! curl -s -o /dev/null "http://localhost:$local_port/clusters" 2>/dev/null; do
		attempts=$((attempts + 1))
		((attempts > 30)) && die "port-forward to watcher envoy on $ctx (port $local_port) failed"
		sleep 0.5
	done
}

# --- per-context istiod fanout scrape + aggregation ------------------------
# Each context's Running istiod pods are port-forwarded once via fanout_open
# (tests/lib/fanout.sh). A "scrape" writes every pod's /metrics to files in a
# per-context dir; the aggregators below then SUM counters / pilot_xds, and
# MERGE histogram buckets across pods before delta/quantile.
#
# Per-context state is keyed by a context tag (the array index, e.g. "src",
# "rmt0"). CTX_PORTS_<tag> is a newline list of that context's pod ports.

# Scrape all of a context's pods into <dir> with prefix <prefix> (concurrent).
# Echoes the scrape skew ms (PL8, spans pods).
scrape_ctx() {
	local dir="$1" prefix="$2"
	shift 2
	local -a ports=("$@")
	fanout_scrape_all "$dir" "$prefix" "${ports[@]}"
}

# List the per-pod metrics files for a scrape (dir/prefix-*.metrics) in order.
ctx_metric_files() {
	local dir="$1" prefix="$2" nports="$3"
	local i
	for ((i = 0; i < nports; i++)); do
		echo "${dir}/${prefix}-${i}.metrics"
	done
}

# Convert an integer-or-marker p99 (delta_histogram_p99 output) for bash (( )).
_round_p99() {
	case "$1" in
	N/A | overflow) echo "$1" ;;
	*)              printf '%.0f\n' "$1" ;;
	esac
}

bucket_range() {
	local v="${1:-0}"
	[[ "$v" == "N/A" ]]      && { echo "N/A"; return; }
	[[ "$v" == "overflow" ]]  && { echo ">30000"; return; }
	(( v <= 0 ))     && { echo "N/A"; return; }
	(( v <= 100 ))   && { echo "0-100"; return; }
	(( v <= 500 ))   && { echo "100-500"; return; }
	(( v <= 1000 ))  && { echo "500-1000"; return; }
	(( v <= 3000 ))  && { echo "1000-3000"; return; }
	(( v <= 5000 ))  && { echo "3000-5000"; return; }
	(( v <= 10000 )) && { echo "5000-10000"; return; }
	(( v <= 20000 )) && { echo "10000-20000"; return; }
	(( v <= 30000 )) && { echo "20000-30000"; return; }
	echo ">30000"
}

# Count stale (non-SYNCED) proxies on ONE istiod pod's /debug/syncz.
# Echoes the stale count, or "ERR" on curl/jq failure (each istiod replica only
# knows its OWN connected proxies, so we must query every source pod).
_syncz_stale_count() {
	local port="$1" syncz stale
	syncz=$(curl -s "http://localhost:$port/debug/syncz" 2>/dev/null) || { echo "ERR"; return; }
	stale=$(echo "$syncz" | jq -r '[.[] | select(.proxy_status != null) | select(.proxy_status | to_entries | map(select(.value != "SYNCED")) | length > 0)] | length' 2>/dev/null) || { echo "ERR"; return; }
	echo "$stale"
}

# Sum stale proxies across ALL source istiod pods. Converged only when every pod
# reports 0 stale (a replica with a backlog must not be hidden by a synced peer).
# Echoes total stale, or "ERR" if any pod scrape failed (treated as not-yet).
_syncz_stale_total() {
	local total=0 s
	local port
	for port in "$@"; do
		s="$(_syncz_stale_count "$port")"
		[[ "$s" == "ERR" ]] && { echo "ERR"; return; }
		total=$(( total + s ))
	done
	echo "$total"
}

# Poll syncz across all source pods until total stale == 0 (or timeout).
poll_syncz_converged() {
	local t0="$1" result_file="$2"
	shift 2
	local -a ports=("$@")
	local deadline=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	while true; do
		local now_ms
		now_ms=$(( $(now_ns) / 1000000 ))
		((now_ms > deadline)) && { echo "TIMEOUT" > "$result_file"; return; }
		local total
		total="$(_syncz_stale_total "${ports[@]}")"
		if [[ "$total" == "0" ]]; then
			now_ns > "$result_file"
			return
		fi
		sleep "$POLL_INTERVAL_S"
	done
}

# Wait for syncz to show all-SYNCED across all source pods (used for settle).
wait_syncz_synced() {
	local timeout_sec="$1"
	shift
	local -a ports=("$@")
	local deadline=$(( $(date +%s) + timeout_sec ))
	while (( $(date +%s) <= deadline )); do
		local total
		total="$(_syncz_stale_total "${ports[@]}")"
		[[ "$total" == "0" ]] && return 0
		sleep "$POLL_INTERVAL_S"
	done
	return 1
}

# Wait for expected endpoint count (full convergence, not just first endpoint).
# This is the DATA-PLANE reachability signal: the remote Envoy reports the new
# endpoints as health_flags::healthy, which requires the source pods to be Ready
# (scheduled + sidecar started). It therefore measures end-to-end churn
# reachability (control-plane propagation + pod/sidecar lifecycle), NOT the
# control plane in isolation — see poll_remote_eds_converged for that.
poll_endpoint_count_converged() {
	local envoy_port="$1" t0="$2" expected_count="$3" result_file="$4"
	local deadline=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	while true; do
		local now_ms
		now_ms=$(( $(now_ns) / 1000000 ))
		((now_ms > deadline)) && { echo "TIMEOUT" > "$result_file"; return; }
		local clusters count
		clusters=$(curl -s "http://localhost:$envoy_port/clusters" 2>/dev/null) || { sleep "$POLL_INTERVAL_S"; continue; }
		count=$(echo "$clusters" | grep -c "churn-target.*health_flags::healthy" || true)
		if ((count >= expected_count)); then
			now_ns > "$result_file"
			return
		fi
		sleep "$POLL_INTERVAL_S"
	done
}

# CONTROL-PLANE-only convergence signal (the P2 analogue from the propagation
# suite, tests/propagation/002-run-endpoint-probe.sh:poll_p2_remote_eds_push).
# Times the FIRST cross-cluster EDS push after t0 on a remote istiod, using the
# existing pilot_xds_pushes{type="eds"} counter (fanned out + summed across the
# remote's istiod pods via fanout_counter_by_label_sum). This is pod-boot-free:
# it answers "how fast does the remote control plane learn the churn and push
# EDS", independent of source-pod Ready time. Contrast with
# poll_endpoint_count_converged, which gates on the new endpoints becoming
# health_flags::healthy (and so includes pod scheduling + sidecar start).
#
# Threshold: Sigma eds_delta >= 1 (R2-2/PL20). istiod debounces/coalesces, so
# scaling N deployments concurrently commonly produces FEWER than N {type=eds}
# pushes — a per-deployment threshold (>= DEPLOYMENT_COUNT) would spuriously
# TIMEOUT on a fully-converged mesh. We therefore time the FIRST remote EDS push
# after t0 (the control-plane scaling signal), NOT per-deployment fan-in. The
# counter is mesh-wide, so this does NOT disambiguate a concurrent unrelated EDS
# push; in a churn run the scale event is the dominant in-window activity, so
# that is acceptable. NOTE: churn scales replicas of EXISTING deployments — no
# Service is created/deleted — so pilot_services is invariant and there is NO
# clean registry-delta cross-check available (unlike propagation P2, where t0
# CREATES a Service); the dirty cross-check was removed (R2-1/PL31: a
# zero-information always-dirty flag). NOTE: there is no in-poller restart guard
# (unlike propagation P2's proc_start_sig check); this poller relies on the
# post-hoc POISONED_RESTART poisoning in the main loop (a remote restart resets
# the counter and N/As convergence_remote_eds_ms there).
# Result file: crossing ns (compute_delta_ms), or TIMEOUT / INCOMPLETE.
poll_remote_eds_converged() {
	local polldir="$1" t0="$2" baseline_eds="$3" eds_delta_target="$4" \
		result_file="$5"
	shift 5
	local -a ports=("$@")
	local deadline=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	local ever_complete=0
	mkdir -p "$polldir"
	while true; do
		local now_ms
		now_ms=$(( $(now_ns) / 1000000 ))
		if ((now_ms > deadline)); then
			if ((ever_complete)); then echo "TIMEOUT" > "$result_file"; else echo "INCOMPLETE" > "$result_file"; fi
			return
		fi
		# One fanned-out scrape per tick. A FIXED prefix ("tick") means each tick
		# OVERWRITES the prior tick's per-pod /metrics bodies, so disk stays bounded
		# at one tick's worth of files regardless of how many ticks elapse (R2-3) —
		# the EDS/gauge values are consumed immediately below, no tick body needs to
		# survive. The .failed/.skew sidecars are likewise overwritten in place.
		fanout_scrape_all "$polldir" "tick" "${ports[@]}" >/dev/null
		if (( $(fanout_scrape_failed_count "$polldir" "tick") > 0 )); then
			# Skip the detection test on an incomplete scrape (a missing pod
			# undercounts the summed eds delta, PL29).
			sleep "$POLL_INTERVAL_S"
			continue
		fi
		ever_complete=1
		local -a tick_files=()
		mapfile -t tick_files < <(ctx_metric_files "$polldir" "tick" "${#ports[@]}")
		local cur_eds
		cur_eds=$(fanout_counter_by_label_sum pilot_xds_pushes type eds "${tick_files[@]}")
		[[ -z "$cur_eds" || ! "$cur_eds" =~ ^[0-9]+$ ]] && cur_eds=0
		# Counter can appear to "decrease" mid restart/deploy; treat as not-yet.
		if (( cur_eds - baseline_eds >= eds_delta_target )); then
			now_ns > "$result_file"
			return
		fi
		sleep "$POLL_INTERVAL_S"
	done
}

compute_delta_ms() {
	local result_file="$1" t0="$2"
	local ts
	ts=$(<"$result_file")
	if [[ "$ts" == "TIMEOUT" ]]; then echo "TIMEOUT"; return; fi
	echo $(( (ts - t0) / 1000000 ))
}

echo "=== Churn convergence probe ==="
echo "Source: $SOURCE_CTX | Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
echo "Deployments: $DEPLOYMENT_COUNT | Scale: $BASE_REPLICAS -> $SCALE_TO"
echo "Iterations: $ITERATIONS | Timeout: ${TIMEOUT_SEC}s | Settle: ${SETTLE_SEC}s"
echo ""

TMPDIR_RUN=$(mktemp -d)
trap 'cleanup; rm -rf "$TMPDIR_RUN"' EXIT

# Per-remote istiod pod-port arrays, stored as newline strings keyed by remote idx
# (bash has no array-of-arrays); split back with split_csv-style read when used.
declare -A RMT_PORTS_STR=()
SRC_ISTIOD_PORTS=()

# (Re)open one istiod port-forward per Running pod, per context. The source
# context is ctx_index 0; remote i is ctx_index i+1 (collision-free blocks).
# Re-listing pods on reopen picks up a pod-set change. Envoy watcher PFs are
# opened once (open_envoy_fanouts) — they are not re-opened here.
open_istiod_fanouts() {
	# pods array is a required out-arg of fanout_open; not read directly here
	# (restart detection uses the recorded .podset file).
	# shellcheck disable=SC2034
	local pods=()
	SRC_ISTIOD_PORTS=()
	fanout_open "$SOURCE_CTX" 0 PF_PIDS SRC_ISTIOD_PORTS pods "${KUBECTL[@]}"
	local i rp rpods
	for i in "${!REMOTES[@]}"; do
		rp=()
		# shellcheck disable=SC2034  # required out-arg of fanout_open; podset recorded per-scrape
		rpods=()
		fanout_open "${REMOTES[i]}" $(( i + 1 )) PF_PIDS rp rpods "${KUBECTL[@]}"
		RMT_PORTS_STR["$i"]="$(IFS=$'\n'; echo "${rp[*]}")"
	done
}

echo "Starting port-forwards..."
open_istiod_fanouts
for i in "${!REMOTES[@]}"; do
	start_envoy_port_forward "${REMOTES[i]}" $(( BASE_ENVOY_PF_PORT + i ))
done
echo "Port-forwards ready."

# Helper: load a remote's istiod ports into a named array.
load_rmt_ports() {
	local idx="$1"
	local -n _arr="$2"
	_arr=()
	local p
	while IFS= read -r p; do [[ -n "$p" ]] && _arr+=("$p"); done <<<"${RMT_PORTS_STR[$idx]}"
}

# Per-iteration PF liveness check: if ANY istiod pod-port across any context is
# unresponsive, kill the whole istiod PF set and re-open every context's block
# (re-listing pods, so a pod-set change is picked up). Mirrors propagation's
# fanout_reopen_if_dead. Envoy watcher PFs are left intact.
reopen_istiod_fanouts_if_dead() {
	local alive=1 port
	for port in "${SRC_ISTIOD_PORTS[@]}"; do
		curl -s -o /dev/null --max-time 2 "http://localhost:$port/metrics" 2>/dev/null || { alive=0; break; }
	done
	if ((alive)); then
		local j _rp2=()
		for j in "${!REMOTES[@]}"; do
			load_rmt_ports "$j" _rp2
			for port in "${_rp2[@]}"; do
				curl -s -o /dev/null --max-time 2 "http://localhost:$port/metrics" 2>/dev/null || { alive=0; break 2; }
			done
		done
	fi
	((alive)) && return 0
	echo "  istiod port-forward(s) unresponsive — re-opening fanout blocks..." >&2
	local pid
	# Kill only the istiod PFs we can't selectively map, so re-open the lot; the
	# envoy watcher PFs share PF_PIDS, so re-open those too to keep them alive.
	for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
	PF_PIDS=()
	open_istiod_fanouts
	local k
	for k in "${!REMOTES[@]}"; do
		start_envoy_port_forward "${REMOTES[k]}" $(( BASE_ENVOY_PF_PORT + k ))
	done
}

# Reachability threshold: at least 1 new health_flags::healthy endpoint per
# deployment visible in the remote sidecar's /clusters. health_flags::healthy
# requires the source pod to be Ready (scheduled + sidecar started), so this is
# the end-to-end reachability signal (remote_endpoint_reachable_ms). The
# control-plane-only signal (convergence_remote_eds_ms) is measured separately by
# poll_remote_eds_converged off the istiod EDS push counter.
ENDPOINT_THRESHOLD_DELTA=$DEPLOYMENT_COUNT
# EDS-push convergence threshold (R2-2/PL20): the FIRST remote EDS push after t0,
# i.e. Sigma pilot_xds_pushes{type=eds} delta >= 1. NOT per-deployment fan-in —
# istiod coalesces concurrent scales into FEWER than DEPLOYMENT_COUNT pushes, so
# a per-deployment threshold would spuriously TIMEOUT a converged mesh.
EDS_THRESHOLD_DELTA=1

for ((iter = 1; iter <= ITERATIONS; iter++)); do
	echo ""
	echo "--- Iteration $iter/$ITERATIONS ---"

	ITER_DIR="$TMPDIR_RUN/iter-${iter}"
	mkdir -p "$ITER_DIR"

	# Per-iteration PF liveness check (re-opens dead blocks, picks up pod churn)
	# before the baseline scrape, so a PF that died between iterations does not
	# silently undercount this iteration's deltas.
	reopen_istiod_fanouts_if_dead
	SRC_NPORTS="${#SRC_ISTIOD_PORTS[@]}"
	# Track whether any per-pod scrape this iteration came back empty/incomplete.
	ITER_SCRAPE_INCOMPLETE=0

	# Pre-churn: gauges + endpoint baselines first (order-insensitive), then a
	# full per-pod baseline scrape of every source istiod immediately before
	# scale-up so the delta window starts at the scale-up. pilot_xds (connected
	# proxies) SUMS across replicas; histograms/counters aggregate per pod below.
	# `|| true`: scrape_ctx returns non-zero on an incomplete scrape (by design);
	# incompleteness is captured on the next line, so it must not trip `set -e`.
	scrape_ctx "$ITER_DIR" "src-pre" "${SRC_ISTIOD_PORTS[@]}" >/dev/null || true
	(( $(fanout_scrape_failed_count "$ITER_DIR" "src-pre") > 0 )) && ITER_SCRAPE_INCOMPLETE=1
	mapfile -t SRC_PRE_FILES < <(ctx_metric_files "$ITER_DIR" "src-pre" "$SRC_NPORTS")
	fanout_record_podset "$SOURCE_CTX" "$ITER_DIR/src-pre.podset" "${KUBECTL[@]}"
	src_connected_proxies=$(fanout_gauge_sum pilot_xds "${SRC_PRE_FILES[@]}")

	rmt_connected_proxies=0
	declare -A RMT_PRE_FILES_STR=()
	# Per-remote EDS-push baseline for the control-plane-only signal
	# (convergence_remote_eds_ms). Read from the SAME pre-scrape blob as the other
	# baselines (PL21: no extra HTTP round-trip), summed across the remote's istiod
	# pods. (No pilot_services baseline: churn has no clean registry-delta
	# cross-check — see poll_remote_eds_converged, R2-1/PL31.)
	declare -A RMT_PRE_EDS=()
	for i in "${!REMOTES[@]}"; do
		_rports=()  # populated by load_rmt_ports via nameref
		load_rmt_ports "$i" _rports
		scrape_ctx "$ITER_DIR" "rmt${i}-pre" "${_rports[@]}" >/dev/null || true
		(( $(fanout_scrape_failed_count "$ITER_DIR" "rmt${i}-pre") > 0 )) && ITER_SCRAPE_INCOMPLETE=1
		mapfile -t _rfiles < <(ctx_metric_files "$ITER_DIR" "rmt${i}-pre" "${#_rports[@]}")
		RMT_PRE_FILES_STR["$i"]="$(IFS=$'\n'; echo "${_rfiles[*]}")"
		fanout_record_podset "${REMOTES[i]}" "$ITER_DIR/rmt${i}-pre.podset" "${KUBECTL[@]}"
		rmt_connected_proxies=$(( rmt_connected_proxies + $(fanout_gauge_sum pilot_xds "${_rfiles[@]}") ))
		RMT_PRE_EDS["$i"]=$(fanout_counter_by_label_sum pilot_xds_pushes type eds "${_rfiles[@]}")
	done

	BASELINE_COUNTS=()
	for i in "${!REMOTES[@]}"; do
		envoy_port=$(( BASE_ENVOY_PF_PORT + i ))
		bc=$(curl -s "http://localhost:$envoy_port/clusters" 2>/dev/null | grep -c "churn-target.*health_flags::healthy" || echo 0)
		BASELINE_COUNTS+=("$bc")
	done

	# Counter baselines summed across source pods.
	src_pre_triggers=$(fanout_counter_sum pilot_push_triggers "${SRC_PRE_FILES[@]}")
	src_pre_pushes=$(fanout_counter_sum pilot_xds_pushes "${SRC_PRE_FILES[@]}")

	T0=$(now_ns)
	echo "  Scaling $DEPLOYMENT_COUNT deployments to $SCALE_TO replicas on all clusters..."
	SCALE_PIDS=()
	for ctx in "${ALL_CTXS[@]}"; do
		for ((d = 0; d < DEPLOYMENT_COUNT; d++)); do
			"${KUBECTL[@]}" --context="$ctx" -n "$NS" scale deployment/churn-target-${d} --replicas="$SCALE_TO" >/dev/null 2>&1 &
			SCALE_PIDS+=($!)
		done
	done
	for pid in "${SCALE_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done

	LOCAL_FILE="$TMPDIR_RUN/local_conv"
	echo "" > "$LOCAL_FILE"
	# syncz fanned out across ALL source istiod pods: each replica only knows its
	# own connected proxies, so convergence requires every pod to report 0 stale.
	poll_syncz_converged "$T0" "$LOCAL_FILE" "${SRC_ISTIOD_PORTS[@]}" &
	POLL_PIDS=($!)

	REMOTE_FILES=()
	REMOTE_EDS_FILES=()
	for i in "${!REMOTES[@]}"; do
		rf="$TMPDIR_RUN/remote_${i}"
		echo "" > "$rf"
		REMOTE_FILES+=("$rf")
		expected=$(( BASELINE_COUNTS[i] + ENDPOINT_THRESHOLD_DELTA ))
		poll_endpoint_count_converged $(( BASE_ENVOY_PF_PORT + i )) "$T0" "$expected" "$rf" &
		POLL_PIDS+=($!)

		# Control-plane-only EDS-push convergence (the P2 analogue), fanned out over
		# this remote's already-open istiod ports.
		edsf="$TMPDIR_RUN/remote_eds_${i}"
		echo "" > "$edsf"
		REMOTE_EDS_FILES+=("$edsf")
		_rports=()  # populated by load_rmt_ports via nameref
		load_rmt_ports "$i" _rports
		poll_remote_eds_converged "$ITER_DIR/eds-poll-${i}" "$T0" \
			"${RMT_PRE_EDS[$i]}" "$EDS_THRESHOLD_DELTA" \
			"$edsf" "${_rports[@]}" &
		POLL_PIDS+=($!)
	done

	for pid in "${POLL_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
	POLL_PIDS=()

	conv_local=$(compute_delta_ms "$LOCAL_FILE" "$T0")
	echo "  Convergence (local syncz): ${conv_local}ms"

	conv_remote="N/A"
	if [[ ${#REMOTES[@]} -gt 0 ]]; then
		max_remote=0
		all_ok=1
		for i in "${!REMOTES[@]}"; do
			r=$(compute_delta_ms "${REMOTE_FILES[i]}" "$T0")
			echo "  Convergence (remote ${REMOTES[i]}): ${r}ms"
			if [[ "$r" == "TIMEOUT" ]]; then
				all_ok=0
			elif ((r > max_remote)); then
				max_remote="$r"
			fi
		done
		if ((all_ok)); then conv_remote="$max_remote"; else conv_remote="TIMEOUT"; fi
	fi

	# Control-plane-only EDS-push convergence (max across remotes; mirrors the
	# conv_remote aggregation). A poller that never completed a clean scrape emits
	# INCOMPLETE (treated as TIMEOUT). No dirty cross-check: churn has no clean
	# registry-delta denominator (R2-1/PL31).
	conv_remote_eds="N/A"
	if [[ ${#REMOTES[@]} -gt 0 ]]; then
		max_eds=0
		eds_ok=1
		for i in "${!REMOTES[@]}"; do
			ev=$(<"${REMOTE_EDS_FILES[i]}")
			if [[ "$ev" == "TIMEOUT" || "$ev" == "INCOMPLETE" || -z "${ev// }" ]]; then
				e="TIMEOUT"
			else
				e=$(( (ev - T0) / 1000000 ))
			fi
			echo "  Convergence (remote ${REMOTES[i]}, EDS push): ${e}ms"
			if [[ "$e" == "TIMEOUT" ]]; then
				eds_ok=0
			elif ((e > max_eds)); then
				max_eds="$e"
			fi
		done
		if ((eds_ok)); then conv_remote_eds="$max_eds"; else conv_remote_eds="TIMEOUT"; fi
	fi

	# Post-churn: full per-pod scrape of every istiod (concurrent), summed/merged.
	scrape_ctx "$ITER_DIR" "src-post" "${SRC_ISTIOD_PORTS[@]}" >/dev/null || true
	(( $(fanout_scrape_failed_count "$ITER_DIR" "src-post") > 0 )) && ITER_SCRAPE_INCOMPLETE=1
	mapfile -t SRC_POST_FILES < <(ctx_metric_files "$ITER_DIR" "src-post" "$SRC_NPORTS")
	fanout_record_podset "$SOURCE_CTX" "$ITER_DIR/src-post.podset" "${KUBECTL[@]}"

	# PL9 (widened): per-pod start-time advance OR pod-set change -> restart.
	src_pre_csv="$(IFS=,; echo "${SRC_PRE_FILES[*]}")"
	src_post_csv="$(IFS=,; echo "${SRC_POST_FILES[*]}")"
	restarted_local="$(fanout_restart_status \
		"$ITER_DIR/src-pre.podset" "$ITER_DIR/src-post.podset" \
		"$src_pre_csv" "$src_post_csv")"

	src_post_triggers=$(fanout_counter_sum pilot_push_triggers "${SRC_POST_FILES[@]}")
	src_post_pushes=$(fanout_counter_sum pilot_xds_pushes "${SRC_POST_FILES[@]}")
	src_triggers_delta=$((src_post_triggers - src_pre_triggers))
	src_pushes_delta=$((src_post_pushes - src_pre_pushes))

	# PL11: merge buckets across source pods, then delta -> quantile.
	fanout_merge_histogram pilot_proxy_queue_time "$ITER_DIR/src-pre-q.merged" "${SRC_PRE_FILES[@]}"
	fanout_merge_histogram pilot_proxy_queue_time "$ITER_DIR/src-post-q.merged" "${SRC_POST_FILES[@]}"
	fanout_merge_histogram pilot_xds_push_time "$ITER_DIR/src-pre-pt.merged" "${SRC_PRE_FILES[@]}"
	fanout_merge_histogram pilot_xds_push_time "$ITER_DIR/src-post-pt.merged" "${SRC_POST_FILES[@]}"
	src_queue_p99=$(_round_p99 "$(delta_histogram_p99 "$ITER_DIR/src-pre-q.merged" "$ITER_DIR/src-post-q.merged" pilot_proxy_queue_time)")
	src_push_time_p99=$(_round_p99 "$(delta_histogram_p99 "$ITER_DIR/src-pre-pt.merged" "$ITER_DIR/src-post-pt.merged" pilot_xds_push_time)")

	rmt_triggers_delta=0
	rmt_pushes_delta=0
	rmt_queue_p99="N/A"
	rmt_push_time_p99="N/A"
	restarted_remote="0"
	if [[ ${#REMOTES[@]} -gt 0 ]]; then
		max_rmt_q=0
		has_rmt_q=0
		max_rmt_pt=0
		has_rmt_pt=0
		for i in "${!REMOTES[@]}"; do
			_rports=()  # populated by load_rmt_ports via nameref
			load_rmt_ports "$i" _rports
			scrape_ctx "$ITER_DIR" "rmt${i}-post" "${_rports[@]}" >/dev/null || true
			(( $(fanout_scrape_failed_count "$ITER_DIR" "rmt${i}-post") > 0 )) && ITER_SCRAPE_INCOMPLETE=1
			mapfile -t _rpost_files < <(ctx_metric_files "$ITER_DIR" "rmt${i}-post" "${#_rports[@]}")
			fanout_record_podset "${REMOTES[i]}" "$ITER_DIR/rmt${i}-post.podset" "${KUBECTL[@]}"
			mapfile -t _rpre_files <<<"${RMT_PRE_FILES_STR[$i]}"

			# Restart on any remote -> mark remote poisoned (do not mutate local).
			rpre_csv="$(IFS=,; echo "${_rpre_files[*]}")"
			rpost_csv="$(IFS=,; echo "${_rpost_files[*]}")"
			r_restart="$(fanout_restart_status \
				"$ITER_DIR/rmt${i}-pre.podset" "$ITER_DIR/rmt${i}-post.podset" \
				"$rpre_csv" "$rpost_csv")"
			[[ "$r_restart" != "0" ]] && restarted_remote="$r_restart"

			rmt_post_t=$(fanout_counter_sum pilot_push_triggers "${_rpost_files[@]}")
			rmt_post_p=$(fanout_counter_sum pilot_xds_pushes "${_rpost_files[@]}")
			rmt_pre_t=$(fanout_counter_sum pilot_push_triggers "${_rpre_files[@]}")
			rmt_pre_p=$(fanout_counter_sum pilot_xds_pushes "${_rpre_files[@]}")
			rmt_triggers_delta=$(( rmt_triggers_delta + rmt_post_t - rmt_pre_t ))
			rmt_pushes_delta=$(( rmt_pushes_delta + rmt_post_p - rmt_pre_p ))

			fanout_merge_histogram pilot_proxy_queue_time "$ITER_DIR/rmt${i}-pre-q.merged" "${_rpre_files[@]}"
			fanout_merge_histogram pilot_proxy_queue_time "$ITER_DIR/rmt${i}-post-q.merged" "${_rpost_files[@]}"
			rmt_q=$(_round_p99 "$(delta_histogram_p99 "$ITER_DIR/rmt${i}-pre-q.merged" "$ITER_DIR/rmt${i}-post-q.merged" pilot_proxy_queue_time)")
			if [[ "$rmt_q" != "N/A" && "$rmt_q" != "overflow" ]]; then
				has_rmt_q=1
				((rmt_q > max_rmt_q)) && max_rmt_q="$rmt_q"
			elif [[ "$rmt_q" == "overflow" ]]; then
				rmt_queue_p99="overflow"
			fi

			fanout_merge_histogram pilot_xds_push_time "$ITER_DIR/rmt${i}-pre-pt.merged" "${_rpre_files[@]}"
			fanout_merge_histogram pilot_xds_push_time "$ITER_DIR/rmt${i}-post-pt.merged" "${_rpost_files[@]}"
			rmt_pt=$(_round_p99 "$(delta_histogram_p99 "$ITER_DIR/rmt${i}-pre-pt.merged" "$ITER_DIR/rmt${i}-post-pt.merged" pilot_xds_push_time)")
			if [[ "$rmt_pt" != "N/A" && "$rmt_pt" != "overflow" ]]; then
				has_rmt_pt=1
				((rmt_pt > max_rmt_pt)) && max_rmt_pt="$rmt_pt"
			elif [[ "$rmt_pt" == "overflow" ]]; then
				rmt_push_time_p99="overflow"
			fi
		done
		if [[ "$rmt_queue_p99" != "overflow" ]] && ((has_rmt_q)); then
			rmt_queue_p99="$max_rmt_q"
		fi
		if [[ "$rmt_push_time_p99" != "overflow" ]] && ((has_rmt_pt)); then
			rmt_push_time_p99="$max_rmt_pt"
		fi
	fi

	# PL13: poison this row's istiod-side deltas/quantiles if any istiod restarted
	# (local or remote), restart status is unknown, OR a per-pod scrape was
	# incomplete (a missing pod undercounts the summed counters / merged buckets).
	if [[ "$restarted_local" != "0" || "$restarted_remote" != "0" || "$ITER_SCRAPE_INCOMPLETE" == "1" ]]; then
		src_triggers_delta="N/A"; rmt_triggers_delta="N/A"
		src_pushes_delta="N/A"; rmt_pushes_delta="N/A"
		src_queue_p99="N/A"; rmt_queue_p99="N/A"
		src_push_time_p99="N/A"; rmt_push_time_p99="N/A"
		# convergence_remote_eds_ms is derived from the remote EDS-push counter, so a
		# remote restart (counter reset) or incomplete scrape poisons it too. The
		# reachability signal (conv_remote) is an Envoy wall-clock observation and is
		# NOT poisoned here — only its TIMEOUT is meaningful.
		conv_remote_eds="N/A"
	fi

	# Amplification only when both deltas are numeric (restart poisons them to N/A).
	if [[ "$src_pushes_delta" =~ ^-?[0-9]+$ && "$rmt_pushes_delta" =~ ^-?[0-9]+$ ]]; then
		total_pushes=$(( src_pushes_delta + rmt_pushes_delta ))
	else
		total_pushes="N/A"
	fi
	if [[ "$src_triggers_delta" =~ ^[0-9]+$ ]] && ((src_triggers_delta > 0)) && [[ "$total_pushes" != "N/A" ]]; then
		amplification=$(awk "BEGIN { printf \"%.1f\", $total_pushes / $src_triggers_delta }")
	else
		amplification="N/A"
	fi

	echo "  Source — triggers: $src_triggers_delta  pushes: $src_pushes_delta  queue p99: $(bucket_range "$src_queue_p99")ms  push_time p99: $(bucket_range "$src_push_time_p99")ms  proxies: $src_connected_proxies"
	if [[ ${#REMOTES[@]} -gt 0 ]]; then
		echo "  Remote — triggers: $rmt_triggers_delta  pushes: $rmt_pushes_delta  queue p99: $(bucket_range "$rmt_queue_p99")ms  push_time p99: $(bucket_range "$rmt_push_time_p99")ms  proxies: $rmt_connected_proxies"
	fi
	echo "  Push amplification: ${amplification}x  (${total_pushes} total pushes / ${src_triggers_delta} source triggers)"

	status="OK"
	[[ "$conv_local" == "TIMEOUT" ]] && status="TIMEOUT_LOCAL"
	[[ "$conv_remote" == "TIMEOUT" ]] && status="TIMEOUT_REMOTE"
	# PL13: a mid-window istiod restart (local or remote) poisons the istiod-side
	# deltas; flag the row so the aggregator filters it. Does not override a
	# convergence TIMEOUT, which signals a worse/different problem.
	if [[ "$status" == "OK" && ( "$restarted_local" != "0" || "$restarted_remote" != "0" ) ]]; then
		status="POISONED_RESTART"
	fi
	# An incomplete per-pod scrape undercounts the summed istiod-side deltas; tag
	# the row so the report (004) filters it from numeric aggregation.
	if [[ "$status" == "OK" && "$ITER_SCRAPE_INCOMPLETE" == "1" ]]; then
		status="SCRAPE_INCOMPLETE"
	fi

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$RUN_ID" "$MESH_SIZE" "$DEPLOYMENT_COUNT" "$BASE_REPLICAS" "$SCALE_TO" \
		"$iter" "$T0" "$conv_local" "$conv_remote" "$conv_remote_eds" \
		"$src_triggers_delta" "$rmt_triggers_delta" \
		"$src_pushes_delta" "$rmt_pushes_delta" \
		"$src_queue_p99" "$rmt_queue_p99" \
		"$src_connected_proxies" "$rmt_connected_proxies" \
		"$src_push_time_p99" "$rmt_push_time_p99" \
		"$status" >> "$TSV_FILE"

	echo "  Scaling back to $BASE_REPLICAS replicas..."
	SCALE_PIDS=()
	for ctx in "${ALL_CTXS[@]}"; do
		for ((d = 0; d < DEPLOYMENT_COUNT; d++)); do
			"${KUBECTL[@]}" --context="$ctx" -n "$NS" scale deployment/churn-target-${d} --replicas="$BASE_REPLICAS" >/dev/null 2>&1 &
			SCALE_PIDS+=($!)
		done
	done
	for pid in "${SCALE_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done

	if ((iter < ITERATIONS)); then
		echo "  Waiting for scale-down convergence..."
		if ! wait_syncz_synced "$TIMEOUT_SEC" "${SRC_ISTIOD_PORTS[@]}"; then
			echo "  Warning: scale-down convergence timed out after ${TIMEOUT_SEC}s"
		fi
		echo "  Settling for ${SETTLE_SEC}s..."
		sleep "$SETTLE_SEC"
	fi
done

echo ""
echo "Results written to $TSV_FILE"

MD_FILE="${OUTPUT_DIR}/churn-${RUN_ID}.md"
{
	echo "# Churn Convergence Results"
	echo ""
	echo "| Field | Value |"
	echo "|-------|-------|"
	echo "| Run ID | \`${RUN_ID}\` |"
	echo "| Date | $(date -Iseconds) |"
	echo "| Source | ${SOURCE_CTX} |"
	echo "| Remotes | ${REMOTES[*]:-none} |"
	echo "| Mesh size | ${MESH_SIZE} |"
	echo "| Deployments | ${DEPLOYMENT_COUNT} |"
	echo "| Scale range | ${BASE_REPLICAS} -> ${SCALE_TO} |"
	echo "| Iterations | ${ITERATIONS} |"
	echo "| Timeout | ${TIMEOUT_SEC}s |"
	echo ""
	echo "## Summary"
	echo ""
	echo "| Iter | Local (ms) | Remote reach (ms) | Remote EDS (ms) | Src Triggers | Rmt Triggers | Src Pushes | Rmt Pushes | Src Queue p99 | Rmt Queue p99 | Status |"
	echo "|------|------------|-------------------|-----------------|--------------|--------------|------------|------------|---------------|---------------|--------|"
	awk -F'\t' '
	function bucket_range(v) {
		if (v == "N/A" || v == "")     return "N/A"
		if (v == "overflow")           return ">30000"
		if (v+0 <= 0)     return "N/A"
		if (v+0 <= 100)   return "0-100"
		if (v+0 <= 500)   return "100-500"
		if (v+0 <= 1000)  return "500-1000"
		if (v+0 <= 3000)  return "1000-3000"
		if (v+0 <= 5000)  return "3000-5000"
		if (v+0 <= 10000) return "5000-10000"
		if (v+0 <= 20000) return "10000-20000"
		if (v+0 <= 30000) return "20000-30000"
		return ">30000"
	}
	!/^#/ && !/^run_id/ && NF>=21 {
		printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", \
			$6, $8, $9, $10, $11, $12, $13, $14, bucket_range($15), bucket_range($16), $21
	}' "$TSV_FILE"
	echo ""
	echo "## Raw Data"
	echo ""
	echo "TSV: [\`$(basename "$TSV_FILE")\`]($(basename "$TSV_FILE"))"
} > "$MD_FILE"
echo "Summary written to $MD_FILE"

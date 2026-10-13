#!/usr/bin/env bash
# Measure control-plane convergence under endpoint churn.
# Scales the churn-target deployments on the source cluster only (remotes stay at
# base), then times when the source watcher sees the new pods and every source
# proxy is SYNCED, and how fast each remote sees the change: its first EDS push
# and its watcher's view of the new endpoints.
#
# Usage:
#   ./tests/churn/002-run-churn-probe.sh --source-context CTX [options]
#
# Examples:
#   ./tests/churn/002-run-churn-probe.sh --source-context <mesh-a-ctx> --remote-contexts <mesh-b-ctx>
#   ./tests/churn/002-run-churn-probe.sh --source-context <mesh-a-ctx> \
#     --deployment-count 10 --scale-to 10 --iterations 3
#   ./tests/churn/002-run-churn-probe.sh --config tests/churn/configs/smoke.env \
#     --source-context <mesh-a-ctx> --remote-contexts <mesh-b-ctx>
# ci-dry-run: --source-context ci-dummy
set -euo pipefail

# Report the failing line if an unguarded command aborts the probe under set -e.
# shellcheck disable=SC2154  # rc is assigned at the head of the trap body
trap 'rc=$?; echo "FATAL: ${0##*/} aborted (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # config_preload, config_preamble_lines
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
config_preload churn "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/timestamp.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/metrics.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fanout.sh"

SOURCE_CTX=""
REMOTE_CONTEXTS_CSV=""
MESH_SIZE=""
DEPLOYMENT_COUNT="${CHURN_DEPLOYMENT_COUNT:-5}"
BASE_REPLICAS="${CHURN_BASE_REPLICAS:-1}"
SCALE_TO="${CHURN_SCALE_TO_REPLICAS:-5}"
ITERATIONS="${CHURN_ITERATIONS:-5}"
TIMEOUT_SEC="${CHURN_TIMEOUT_SEC:-120}"
SETTLE_SEC="${CHURN_SETTLE_SEC:-3}"
POLL_INTERVAL_MS="${CHURN_POLL_INTERVAL_MS:-250}"
OUTPUT_DIR="$(config_repo_path "${CHURN_RESULTS_DIR}")"
DRY_RUN=0
# Live tuning levers + sidecar egress hosts for the TSV preamble. The sweep queries
# them once and passes them in; standalone runs record "unknown".
TUNING_BASELINE="unknown"
SIDECAR_EGRESS_HOSTS="unknown"
NS="${CHURN_TEST_NAMESPACE:-churn-test}"
# istiod pods are port-forwarded by tests/lib/fanout.sh (FANOUT_PF_BASE). The
# source watcher Envoy uses SRC_ENVOY_PF_PORT; remote i uses RMT_ENVOY_PF_BASE + i.
SRC_ENVOY_PF_PORT=15100
RMT_ENVOY_PF_BASE=15101

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE            Run config of KEY=value lines (config/options.env keys; see
                           tests/churn/README.md, "Run config").
                           Precedence: flag > --config > environment > default.
  --source-context CTX     Kube context for the source cluster (required).
  --remote-contexts CSV    Remote cluster contexts (comma-separated).
  --mesh-size N            Metadata tag (default: 1 + remotes).
  --deployment-count N     Churn target deployments (default: $DEPLOYMENT_COUNT).
  --scale-to N             Scale targets to N replicas (default: $SCALE_TO).
  --iterations N           Number of churn iterations (default: $ITERATIONS).
  --timeout SEC            Timeout per iteration (default: $TIMEOUT_SEC).
  --settle SEC             Settle time after scale-down convergence (default: $SETTLE_SEC).
  --output-dir DIR         Results directory (default: ${CHURN_RESULTS_DIR}).
  --tuning-baseline STR    Live tuning-baseline levers for the TSV preamble
                           (default: unknown; the sweep queries + threads this).
  --sidecar-egress-hosts STR  Live root-Sidecar egress hosts for the TSV preamble
                           (default: unknown; the sweep queries + threads this).
  --dry-run                Show plan without executing.
  -h, --help               Show this help.

Only the source context is scaled; remotes stay at base replicas, so the remote
columns measure cross-cluster propagation. Per iteration:
  convergence_local_ms          the source watcher sees at least one new Ready pod
                                per deployment and the source istiod reports every
                                proxy SYNCED (includes pod scheduling and sidecar start).
  remote_endpoint_reachable_ms  every churn target on the remote watcher has more
                                healthy endpoint weight than before t0 (at least one
                                new Ready source pod per deployment; includes pod
                                scheduling and sidecar start).
  convergence_remote_eds_ms     first remote EDS push after t0 (control plane only).

Environment:
  CHURN_TEST_NAMESPACE         Namespace for churn-target/watcher workloads (default churn-test).
  CHURN_DEPLOYMENT_COUNT       Default --deployment-count.
  CHURN_BASE_REPLICAS          Replicas before scale-up and after scale-down (must be < --scale-to).
  CHURN_SCALE_TO_REPLICAS      Default --scale-to.
  CHURN_ITERATIONS             Default --iterations.
  CHURN_TIMEOUT_SEC            Default --timeout.
  CHURN_SETTLE_SEC             Default --settle.
  CHURN_POLL_INTERVAL_MS       syncz / endpoint poll interval in ms.
  CHURN_RESULTS_DIR            Default --output-dir (relative to the repo root).
  FANOUT_PF_BASE               Per-pod istiod port-forward block base (default 21014).
  FANOUT_CTX_STRIDE            Per-context port stride (default 20).
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

[[ -n "$SOURCE_CTX" ]] || die "--source-context is required"
is_pos_int "$DEPLOYMENT_COUNT" || die "--deployment-count must be a positive integer"
is_nonneg_int "$BASE_REPLICAS" || die "CHURN_BASE_REPLICAS must be a non-negative integer"
is_pos_int "$SCALE_TO" || die "--scale-to must be a positive integer"
((SCALE_TO > BASE_REPLICAS)) || die "--scale-to ($SCALE_TO) must be greater than CHURN_BASE_REPLICAS ($BASE_REPLICAS)"
is_pos_int "$ITERATIONS" || die "--iterations must be a positive integer"
is_pos_int "$TIMEOUT_SEC" || die "--timeout must be a positive integer"
is_nonneg_int "$SETTLE_SEC" || die "--settle must be a non-negative integer"
is_pos_int "$POLL_INTERVAL_MS" || die "CHURN_POLL_INTERVAL_MS must be a positive integer"
POLL_INTERVAL_S="$(awk -v ms="$POLL_INTERVAL_MS" 'BEGIN { printf "%.3f", ms / 1000 }')"

KUBECTL=()
resolve_kubectl KUBECTL

command -v curl >/dev/null 2>&1 || die "curl not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

REMOTES=()
if [[ -n "$REMOTE_CONTEXTS_CSV" ]]; then
	split_csv "$REMOTE_CONTEXTS_CSV" REMOTES
fi

[[ -z "$MESH_SIZE" ]] && MESH_SIZE=$(( 1 + ${#REMOTES[@]} ))

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
TSV_FILE="${OUTPUT_DIR}/churn-${RUN_ID}.tsv"

if ((DRY_RUN)); then
	echo "=== Dry-run: churn probe ==="
	echo "Source: $SOURCE_CTX | Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
	echo "Deployments: $DEPLOYMENT_COUNT | Scale (source only): $BASE_REPLICAS -> $SCALE_TO | Iterations: $ITERATIONS"
	echo "Output: $TSV_FILE"
	exit 0
fi
mkdir -p "$OUTPUT_DIR"

# Preflight every context: require >= 1 Running istiod pod (all pods are scraped
# via tests/lib/fanout.sh). The source replica count goes into the preamble.
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
# CHURN_SCALE_SCOPE=source
# TUNING_BASELINE=$TUNING_BASELINE
# SIDECAR_EGRESS_HOSTS=$SIDECAR_EGRESS_HOSTS
EOF
config_preamble_lines >> "$TSV_FILE"
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
	# P4: --max-time bounds the readiness probe so a stuck/half-open watcher PF can't
	# block ~30s/attempt at scale (same shape as the istiod /metrics readiness curls).
	while ! curl -s -o /dev/null --max-time 2 "http://localhost:$local_port/clusters" 2>/dev/null; do
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

# Emit a SETUP_FAILED placeholder row (21 cols, all-N/A metrics) for an iteration
# that failed before it could produce a valid measurement. Mirrors the schema of
# the main row printf and the SETUP_FAILED status that 003/004 already recognise:
# 004 counts it in n_total but excludes it from n_valid (status != OK). Keeps a
# transient failure to ONE lost row instead of aborting the whole sweep.
emit_setup_failed_row() {
	local iter="$1" t0="$2"
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$RUN_ID" "$MESH_SIZE" "$DEPLOYMENT_COUNT" "$BASE_REPLICAS" "$SCALE_TO" \
		"$iter" "$t0" "N/A" "N/A" "N/A" \
		"N/A" "N/A" \
		"N/A" "N/A" \
		"N/A" "N/A" \
		"N/A" "N/A" \
		"N/A" "N/A" \
		"SETUP_FAILED" >> "$TSV_FILE"
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
	syncz=$(curl -s --max-time 5 "http://localhost:$port/debug/syncz" 2>/dev/null) || { echo "ERR"; return; }  # P4: bound a stuck PF
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

# convergence_local_ms: poll until the source watcher has more healthy weight
# than at baseline on every churn target (the source istiod has pushed at least
# one new Ready pod per deployment), then until every source istiod pod reports
# 0 stale proxies. Without the watcher gate, syncz is already all-SYNCED before
# the new pods exist, so the column would only time the scale call.
poll_syncz_converged() {
	local t0="$1" result_file="$2" envoy_port="$3" baseline_file="$4"
	shift 4
	local -a ports=("$@")
	local cur_file="${baseline_file}.cur" body seen=0 now_ms total
	local deadline=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	while true; do
		now_ms=$(( $(now_ns) / 1000000 ))
		((now_ms > deadline)) && { echo "TIMEOUT" > "$result_file"; return; }
		if ((!seen)) && body=$(curl -s --max-time 2 "http://localhost:$envoy_port/clusters" 2>/dev/null); then
			printf '%s\n' "$body" | churn_target_weights > "$cur_file"
			(( $(count_grown_clusters "$baseline_file" "$cur_file") >= DEPLOYMENT_COUNT )) && seen=1
		fi
		if ((seen)); then
			total="$(_syncz_stale_total "${ports[@]}")"
			if [[ "$total" == "0" ]]; then
				now_ns > "$result_file"
				return
			fi
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

# Print "<cluster> <weight>" for every outbound churn-target cluster in an Envoy
# admin /clusters text dump (stdin): the summed weight of its healthy hosts.
# istiod only sends Ready endpoints. On a multi-network mesh it replaces another
# network's endpoints with east-west gateway hosts whose weight grows with that
# network's Ready endpoint count, so a weight sum (not a host count) tracks new
# source endpoints on both flat and multi-network meshes.
churn_target_weights() {
	awk -F'::' -v ns="$NS" '
	NF == 4 && index($1, "outbound|") == 1 && $1 ~ ("[|][|]churn-target-[0-9]+[.]" ns "[.]svc[.]") {
		c = $1
		if (!(c in sum)) sum[c] = 0
		k = c "::" $2
		if ($3 == "health_flags") hf[k] = $4
		else if ($3 == "weight") wt[k] = $4
		else next
		if ((k in hf) && (k in wt)) {
			if (hf[k] == "healthy") sum[c] += wt[k]
			delete hf[k]; delete wt[k]
		}
	}
	END { for (c in sum) print c, sum[c] }' | sort
}

# Count clusters in <current> whose weight is above <baseline> (churn_target_weights files).
count_grown_clusters() {
	awk 'FILENAME == ARGV[1] { base[$1] = $2; next }
		($1 in base) && $2 + 0 > base[$1] + 0 { n++ }
		END { print n + 0 }' "$1" "$2"
}

# Write a remote watcher's churn-target weights to <out>. Retries until all
# DEPLOYMENT_COUNT clusters are listed; returns 1 if they never are.
capture_target_weights() {
	local envoy_port="$1" out="$2" attempt body n
	for attempt in 1 2 3 4 5; do
		if body=$(curl -s --max-time 2 "http://localhost:$envoy_port/clusters" 2>/dev/null); then
			printf '%s\n' "$body" | churn_target_weights > "$out"
			n=$(wc -l < "$out")
			if ((n >= DEPLOYMENT_COUNT)); then return 0; fi
		fi
		if ((attempt < 5)); then sleep "$POLL_INTERVAL_S"; fi
	done
	return 1
}

# remote_endpoint_reachable_ms: poll a remote watcher until every churn-target
# cluster has more healthy weight than at baseline, i.e. at least one new Ready
# source pod per deployment is reachable from the remote. Includes pod scheduling
# and sidecar start; poll_remote_eds_converged is the control-plane-only signal.
poll_target_weights_grown() {
	local envoy_port="$1" t0="$2" baseline_file="$3" result_file="$4"
	local cur_file="${baseline_file}.cur" body now_ms grown
	local deadline=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	while true; do
		now_ms=$(( $(now_ns) / 1000000 ))
		((now_ms > deadline)) && { echo "TIMEOUT" > "$result_file"; return; }
		if body=$(curl -s --max-time 2 "http://localhost:$envoy_port/clusters" 2>/dev/null); then
			printf '%s\n' "$body" | churn_target_weights > "$cur_file"
			grown=$(count_grown_clusters "$baseline_file" "$cur_file")
			if ((grown >= DEPLOYMENT_COUNT)); then
				now_ns > "$result_file"
				return
			fi
		fi
		sleep "$POLL_INTERVAL_S"
	done
}

# After scale-down: wait until no churn-target cluster on the remote watcher is
# above its pre-t0 baseline, so the next iteration starts from a quiet remote.
wait_target_weights_settled() {
	local envoy_port="$1" baseline_file="$2" timeout_sec="$3"
	local cur_file="${baseline_file}.settle" body
	local deadline=$(( $(date +%s) + timeout_sec ))
	while (( $(date +%s) <= deadline )); do
		if body=$(curl -s --max-time 2 "http://localhost:$envoy_port/clusters" 2>/dev/null); then
			printf '%s\n' "$body" | churn_target_weights > "$cur_file"
			if (( $(count_grown_clusters "$baseline_file" "$cur_file") == 0 )); then return 0; fi
		fi
		sleep "$POLL_INTERVAL_S"
	done
	return 1
}

# After scale-down: wait until the source has no terminating churn-target pods, so
# the next iteration's baseline (connected proxies, push counters) is quiet.
wait_source_pods_settled() {
	local timeout_sec="$1" want n
	want=$(( DEPLOYMENT_COUNT * BASE_REPLICAS ))
	local deadline=$(( $(date +%s) + timeout_sec ))
	while (( $(date +%s) <= deadline )); do
		if n=$("${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" get pods -l churn-target=true \
			--no-headers 2>/dev/null | wc -l); then
			((n <= want)) && return 0
		fi
		sleep 1
	done
	return 1
}

# Scale every churn target on the source context only. Remotes stay at base, so
# the remote columns move only on cross-cluster propagation.
scale_source() {
	local replicas="$1" d pid
	local -a pids=()
	for ((d = 0; d < DEPLOYMENT_COUNT; d++)); do
		"${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" scale "deployment/churn-target-${d}" --replicas="$replicas" >/dev/null 2>&1 &
		pids+=($!)
	done
	for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
}

# convergence_remote_eds_ms: time to the first EDS push after t0 on a remote
# istiod (pilot_xds_pushes{type="eds"} summed across its pods). Pod-boot-free,
# and with only the source scaled the push can only come from cross-cluster
# endpoint discovery. The counter is istiod-wide, so an unrelated EDS push in the
# window would also count. Churn adds no Service, so there is no registry-delta
# cross-check. A remote istiod restart is caught after the fact (POISONED_RESTART
# N/As this column). Result file: crossing ns, or TIMEOUT / INCOMPLETE.
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
		# `|| true`: fanout_scrape_all returns non-zero BY DESIGN on an incomplete
		# scrape (PL29); under set -e a bare call here would abort the probe before the
		# .failed sidecar check below (the #31 incident class — caught by the new
		# verify.sh bare-scrape lint). The .failed count is the authoritative gate.
		fanout_scrape_all "$polldir" "tick" "${ports[@]}" >/dev/null || true
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
	if [[ "$ts" == "N/A" ]]; then echo "N/A"; return; fi
	if [[ ! "$ts" =~ ^[0-9]+$ ]]; then echo "TIMEOUT"; return; fi
	echo $(( (ts - t0) / 1000000 ))
}

echo "=== Churn convergence probe ==="
echo "Source: $SOURCE_CTX | Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
echo "Deployments: $DEPLOYMENT_COUNT | Scale: $BASE_REPLICAS -> $SCALE_TO"
echo "Iterations: $ITERATIONS | Timeout: ${TIMEOUT_SEC}s | Settle: ${SETTLE_SEC}s"
echo ""

TMPDIR_RUN=$(mktemp -d)
trap 'cleanup; rm -rf "$TMPDIR_RUN"' EXIT

# Per-remote istiod ports and pods (the ones fanout_open reached, same order),
# stored as newline strings keyed by remote idx (bash has no array-of-arrays).
declare -A RMT_PORTS_STR=() RMT_PODS_STR=()
SRC_ISTIOD_PORTS=()
SRC_ISTIOD_PODS=()

# (Re)open one istiod port-forward per Running pod, per context. The source
# context is ctx_index 0; remote i is ctx_index i+1 (collision-free blocks).
# The pods lists line up with the ports (and so with the scrape files): they
# become each iteration's pre podset for fanout_restart_status.
open_istiod_fanouts() {
	SRC_ISTIOD_PORTS=()
	SRC_ISTIOD_PODS=()
	fanout_open "$SOURCE_CTX" 0 PF_PIDS SRC_ISTIOD_PORTS SRC_ISTIOD_PODS "${KUBECTL[@]}"
	local i
	local -a rp rpods
	for i in "${!REMOTES[@]}"; do
		rp=()
		rpods=()
		fanout_open "${REMOTES[i]}" $(( i + 1 )) PF_PIDS rp rpods "${KUBECTL[@]}"
		RMT_PORTS_STR["$i"]="$(IFS=$'\n'; echo "${rp[*]}")"
		RMT_PODS_STR["$i"]="$(IFS=$'\n'; echo "${rpods[*]}")"
	done
}

# True when a context's Running istiod pods differ from the opened (newline-joined)
# list, e.g. a replica was added or replaced. An empty listing (API hiccup) is
# not a change.
istiod_podset_changed() {
	local ctx="$1" opened="$2" now
	now="$(fanout_list_istiod_pods "$ctx" "${KUBECTL[@]}")"
	[[ -n "$now" && "$now" != "$opened" ]]
}

# Port-forward every watcher Envoy: the source one gates convergence_local_ms,
# the remote ones drive remote_endpoint_reachable_ms.
open_envoy_port_forwards() {
	local k
	start_envoy_port_forward "$SOURCE_CTX" "$SRC_ENVOY_PF_PORT"
	for k in "${!REMOTES[@]}"; do
		start_envoy_port_forward "${REMOTES[k]}" $(( RMT_ENVOY_PF_BASE + k ))
	done
}

echo "Starting port-forwards..."
open_istiod_fanouts
open_envoy_port_forwards
echo "Port-forwards ready."

# Helper: load a remote's istiod ports into a named array.
load_rmt_ports() {
	local idx="$1"
	local -n _arr="$2"
	_arr=()
	local p
	while IFS= read -r p; do [[ -n "$p" ]] && _arr+=("$p"); done <<<"${RMT_PORTS_STR[$idx]}"
}

# Per-iteration PF check: if any istiod or watcher port-forward is unresponsive,
# or a context's Running istiod pods changed since the open, kill every
# port-forward and re-open them all (re-listing istiod pods).
reopen_istiod_fanouts_if_dead() {
	local alive=1 port j
	local -a _rp2=()
	for port in "${SRC_ISTIOD_PORTS[@]}"; do
		curl -s -o /dev/null --max-time 2 "http://localhost:$port/metrics" 2>/dev/null || { alive=0; break; }
	done
	if ((alive)); then
		for j in "${!REMOTES[@]}"; do
			load_rmt_ports "$j" _rp2
			for port in "${_rp2[@]}"; do
				curl -s -o /dev/null --max-time 2 "http://localhost:$port/metrics" 2>/dev/null || { alive=0; break 2; }
			done
		done
	fi
	if ((alive)); then
		curl -s -o /dev/null --max-time 2 "http://localhost:$SRC_ENVOY_PF_PORT/ready" 2>/dev/null || alive=0
		for j in "${!REMOTES[@]}"; do
			curl -s -o /dev/null --max-time 2 "http://localhost:$(( RMT_ENVOY_PF_BASE + j ))/ready" 2>/dev/null || { alive=0; break; }
		done
	fi
	if ((alive)); then
		if istiod_podset_changed "$SOURCE_CTX" "$(IFS=$'\n'; echo "${SRC_ISTIOD_PODS[*]}")"; then
			alive=0
		else
			for j in "${!REMOTES[@]}"; do
				istiod_podset_changed "${REMOTES[j]}" "${RMT_PODS_STR[$j]}" && { alive=0; break; }
			done
		fi
	fi
	((alive)) && return 0
	echo "  port-forward(s) unresponsive or istiod pods changed — re-opening all port-forwards..." >&2
	local pid
	for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
	PF_PIDS=()
	open_istiod_fanouts
	open_envoy_port_forwards
}

# convergence_remote_eds_ms fires on the FIRST remote EDS push after t0. istiod
# coalesces concurrent scales into fewer pushes than deployments, so a
# per-deployment threshold would time out on a converged mesh.
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
	# Pre podset = the scraped pods (lines up with SRC_PRE_FILES); post podset =
	# every Running pod, so a replaced or added istiod shows up as a change.
	printf '%s\n' "${SRC_ISTIOD_PODS[@]}" > "$ITER_DIR/src-pre.podset"
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
		printf '%s\n' "${RMT_PODS_STR[$i]}" > "$ITER_DIR/rmt${i}-pre.podset"
		rmt_connected_proxies=$(( rmt_connected_proxies + $(fanout_gauge_sum pilot_xds "${_rfiles[@]}") ))
		RMT_PRE_EDS["$i"]=$(fanout_counter_by_label_sum pilot_xds_pushes type eds "${_rfiles[@]}")
	done
	((${#REMOTES[@]})) || rmt_connected_proxies="N/A"

	# Churn-target weight baselines on every watcher. A watcher that does not list
	# every churn target makes its column N/A (source: convergence_local_ms).
	SRC_WEIGHTS_OK=1
	if ! capture_target_weights "$SRC_ENVOY_PF_PORT" "$ITER_DIR/src-weights.base"; then
		echo "  Warning: $SOURCE_CTX watcher does not list all $DEPLOYMENT_COUNT churn-target clusters; convergence_local_ms will be N/A" >&2
		SRC_WEIGHTS_OK=0
	fi
	RMT_WEIGHTS_OK=()
	for i in "${!REMOTES[@]}"; do
		if capture_target_weights $(( RMT_ENVOY_PF_BASE + i )) "$ITER_DIR/rmt${i}-weights.base"; then
			RMT_WEIGHTS_OK+=(1)
		else
			echo "  Warning: ${REMOTES[i]} watcher does not list all $DEPLOYMENT_COUNT churn-target clusters; remote_endpoint_reachable_ms will be N/A" >&2
			RMT_WEIGHTS_OK+=(0)
		fi
	done

	# Counter baselines summed across source pods.
	src_pre_triggers=$(fanout_counter_sum pilot_push_triggers "${SRC_PRE_FILES[@]}")
	src_pre_pushes=$(fanout_counter_sum pilot_xds_pushes "${SRC_PRE_FILES[@]}")

	T0=$(now_ns)
	# Run the scale-up + measurement + row-emit as a guarded subshell so a genuine
	# mid-iteration failure costs ONE row, not the whole sweep. `set -e` is RE-armed
	# inside (a subshell on the left of an `if`/`||` would otherwise have it
	# disabled), preserving every `|| true` / poisoning guard; on success the row is
	# appended in-subshell. We capture $? out-of-condition (set +e around the call)
	# so the parent survives the failure, records a SETUP_FAILED placeholder, and
	# still scales back down. The ERR trap keeps the failing line visible — failures
	# are surfaced, not swallowed.
	iter_rc=0
	set +e
	(
		set -e
	echo "  Scaling $DEPLOYMENT_COUNT deployments to $SCALE_TO replicas on $SOURCE_CTX..."
	scale_source "$SCALE_TO"

	LOCAL_FILE="$TMPDIR_RUN/local_conv"
	echo "" > "$LOCAL_FILE"
	POLL_PIDS=()
	# syncz fanned out across ALL source istiod pods: each replica only knows its
	# own connected proxies, so convergence requires every pod to report 0 stale.
	if ((SRC_WEIGHTS_OK)); then
		poll_syncz_converged "$T0" "$LOCAL_FILE" "$SRC_ENVOY_PF_PORT" \
			"$ITER_DIR/src-weights.base" "${SRC_ISTIOD_PORTS[@]}" &
		POLL_PIDS+=($!)
	else
		echo "N/A" > "$LOCAL_FILE"
	fi

	REMOTE_FILES=()
	REMOTE_EDS_FILES=()
	for i in "${!REMOTES[@]}"; do
		rf="$TMPDIR_RUN/remote_${i}"
		echo "" > "$rf"
		REMOTE_FILES+=("$rf")
		if (( RMT_WEIGHTS_OK[i] )); then
			poll_target_weights_grown $(( RMT_ENVOY_PF_BASE + i )) "$T0" \
				"$ITER_DIR/rmt${i}-weights.base" "$rf" &
			POLL_PIDS+=($!)
		else
			echo "N/A" > "$rf"
		fi

		# Control-plane-only EDS-push convergence over this remote's istiod ports.
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

	# Max across remotes; any TIMEOUT wins, then any N/A (incomplete baseline).
	conv_remote="N/A"
	if [[ ${#REMOTES[@]} -gt 0 ]]; then
		max_remote=0
		any_timeout=0
		any_na=0
		for i in "${!REMOTES[@]}"; do
			r=$(compute_delta_ms "${REMOTE_FILES[i]}" "$T0")
			echo "  Reachable (remote ${REMOTES[i]}): ${r}ms"
			if [[ "$r" == "TIMEOUT" ]]; then
				any_timeout=1
			elif [[ "$r" == "N/A" ]]; then
				any_na=1
			elif ((r > max_remote)); then
				max_remote="$r"
			fi
		done
		if ((any_timeout)); then
			conv_remote="TIMEOUT"
		elif ((any_na)); then
			conv_remote="N/A"
		else
			conv_remote="$max_remote"
		fi
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
			# Treat TIMEOUT/INCOMPLETE/empty AND any non-integer crossing-ns (a
			# truncated/garbled result file) as TIMEOUT, so the arithmetic below can
			# never raise a syntax error that aborts the probe under `set -e`.
			if [[ "$ev" == "TIMEOUT" || "$ev" == "INCOMPLETE" || ! "$ev" =~ ^[0-9]+$ ]]; then
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
	# No remotes (mesh size 1): remote counters are N/A, not 0.
	if [[ ${#REMOTES[@]} -eq 0 ]]; then
		rmt_triggers_delta="N/A"; rmt_pushes_delta="N/A"
	fi

	# Amplification only when the deltas are numeric (restart poisons them to N/A).
	if [[ "$src_pushes_delta" =~ ^-?[0-9]+$ && "$rmt_pushes_delta" =~ ^-?[0-9]+$ ]]; then
		total_pushes=$(( src_pushes_delta + rmt_pushes_delta ))
	elif [[ "$src_pushes_delta" =~ ^-?[0-9]+$ && ${#REMOTES[@]} -eq 0 ]]; then
		total_pushes="$src_pushes_delta"
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
	)
	iter_rc=$?
	set -e
	if (( iter_rc != 0 )); then
		echo "  Warning: iteration $iter failed (rc=$iter_rc) before producing a valid row; recording SETUP_FAILED and continuing." >&2
		emit_setup_failed_row "$iter" "$T0"
	fi

	echo "  Scaling back to $BASE_REPLICAS replicas on $SOURCE_CTX..."
	scale_source "$BASE_REPLICAS"

	if ((iter < ITERATIONS)); then
		echo "  Waiting for scale-down convergence..."
		if ! wait_source_pods_settled "$TIMEOUT_SEC"; then
			echo "  Warning: $SOURCE_CTX still has terminating churn-target pods after ${TIMEOUT_SEC}s"
		fi
		if ! wait_syncz_synced "$TIMEOUT_SEC" "${SRC_ISTIOD_PORTS[@]}"; then
			echo "  Warning: scale-down convergence timed out after ${TIMEOUT_SEC}s"
		fi
		if ((SRC_WEIGHTS_OK)) && ! wait_target_weights_settled "$SRC_ENVOY_PF_PORT" \
			"$ITER_DIR/src-weights.base" "$TIMEOUT_SEC"; then
			echo "  Warning: $SOURCE_CTX watcher still above its pre-t0 endpoint weight after ${TIMEOUT_SEC}s"
		fi
		for i in "${!REMOTES[@]}"; do
			(( RMT_WEIGHTS_OK[i] )) || continue
			if ! wait_target_weights_settled $(( RMT_ENVOY_PF_BASE + i )) \
				"$ITER_DIR/rmt${i}-weights.base" "$TIMEOUT_SEC"; then
				echo "  Warning: ${REMOTES[i]} watcher still above its pre-t0 endpoint weight after ${TIMEOUT_SEC}s"
			fi
		done
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
	echo "| Scale range | ${BASE_REPLICAS} -> ${SCALE_TO} (source only; remotes stay at base) |"
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

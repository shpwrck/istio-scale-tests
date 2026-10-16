#!/usr/bin/env bash
# Measure endpoint propagation latency across a multi-cluster Istio mesh.
#
# At t0 the probe labels the pre-warmed backer pod (created by 001) so the canary
# Service gains an endpoint, then times three phases:
#
#   P1 - source istiod pushes to every connected proxy: delta of the
#        pilot_proxy_convergence_time histogram _count reaches the connected
#        proxy count (pilot_xds). Also reports delta-window p50/p99.
#   P2 - each remote istiod discovers the endpoint: first increase of
#        pilot_xds_pushes{type="eds"}.
#   P3 - each remote watcher sidecar reports the canary endpoint healthy
#        (Envoy admin /clusters).
#
# Every Running istiod pod is port-forwarded and scraped (tests/lib/fanout.sh).
# Removing the label drains the endpoint; the backer stays warm between iterations.
#
# Usage:
#   ./tests/propagation/002-run-endpoint-probe.sh --source-context CTX [--remote-contexts CSV] [options]
#
# Examples:
#   # Two-cluster propagation, 10 iterations:
#   ./tests/propagation/002-run-endpoint-probe.sh --source-context <mesh-a-ctx> --remote-contexts <mesh-b-ctx> --tsv
#
#   # Single-cluster baseline (P1 only):
#   ./tests/propagation/002-run-endpoint-probe.sh --source-context <mesh-a-ctx> --tsv
#
#   # Iterations, timeouts and results dir from a run config:
#   ./tests/propagation/002-run-endpoint-probe.sh --config tests/propagation/configs/smoke.env \
#     --source-context <mesh-a-ctx> --remote-contexts <mesh-b-ctx> --tsv
# ci-dry-run: --source-context ci-dummy
set -euo pipefail
# Loud ERR trap for unexpected aborts (per-iteration faults become row statuses).
# shellcheck disable=SC2154  # rc is assigned at the head of the trap body
trap 'rc=$?; echo "FATAL: ${0##*/} aborted (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # config_preload, config_preamble_lines
# --config FILE: export the file's keys before fanout.sh and versions.env/options.env
# fill in defaults.
config_preload propagation "$@"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/timestamp.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fanout.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/reach.sh"  # reach_sanitize (used by istiod-diag.sh)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/istiod-diag.sh"  # istiod_diag_capture (restart evidence)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/propagation.sh"  # PROP_ROW_AWK: the summary counts the rows 005 counts
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

SOURCE_CTX=""
REMOTE_CONTEXTS_CSV=""
MESH_SIZE=""
SWEEP_RUN_ID=""
# Live tuning-baseline provenance; 006 passes it in, standalone runs record "unknown".
TUNING_BASELINE="unknown"
SIDECAR_EGRESS_HOSTS="unknown"
ITERATIONS="${PROPAGATION_ITERATIONS}"
TIMEOUT_SEC="${PROPAGATION_TIMEOUT_SEC}"
POLL_INTERVAL_MS="${PROPAGATION_POLL_INTERVAL_MS}"
SETTLE_SEC="${PROPAGATION_SETTLE_SEC}"
# Inter-iteration drain is cleanup, not a measurement: keep it short and flag a
# missed drain (DRAIN_TIMEOUT) instead of waiting out TIMEOUT_SEC.
DRAIN_TIMEOUT_SEC="${PROPAGATION_DRAIN_TIMEOUT_SEC:-20}"
METRICS_TIMEOUT="${PROPAGATION_METRICS_TIMEOUT}"
OUTPUT_DIR="$(config_repo_path "${PROPAGATION_RESULTS_DIR}")"
DRY_RUN=0
WRITE_TSV=0
NS="${PROPAGATION_TEST_NAMESPACE}"
# istiod is reached via tests/lib/fanout.sh (per-pod port block from FANOUT_PF_BASE,
# default 21014). The watcher Envoy PF block (P3, data-plane side) is unchanged.
BASE_ENVOY_PF_PORT=15100
CHART_DIR="${ROOT}/tests/propagation/chart"

# Label stamped onto the backer pod at t0; must match chart/templates/_helpers.tpl
# (canary.activeLabelKey). The canary Service selects on it.
CANARY_ACTIVE_LABEL_KEY="propagation-active"

# Backer image recorded in the TSV preamble (same pin 001 deploys).
BACKER_IMAGE="hashicorp/http-echo:${HTTP_ECHO_VERSION}"


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE             Run config of KEY=value lines (config/options.env keys; see
                            tests/propagation/README.md, "Run config").
                            Precedence: flag > --config > environment > default.
  --source-context CTX      Kube context for the source cluster (required).
  --remote-contexts CSV     Remote cluster contexts (comma-separated). Omit for single-cluster baseline.
  --mesh-size N             Metadata tag for TSV output (default: 1 + number of remotes).
  --sweep-run-id ID         Outer sweep RUN_ID to record in TSV preamble (default: empty;
                            set by 006-run-sweep.sh — omit when running probe standalone).
  --iterations N            Number of probe iterations (default: \$PROPAGATION_ITERATIONS=$ITERATIONS).
  --timeout SEC             Timeout per iteration (default: \$PROPAGATION_TIMEOUT_SEC=$TIMEOUT_SEC).
  --poll-interval-ms MS     Poll interval in ms (default: \$PROPAGATION_POLL_INTERVAL_MS=$POLL_INTERVAL_MS).
  --settle-sec SEC          Settle gap between iterations after drain (default: \$PROPAGATION_SETTLE_SEC=$SETTLE_SEC).
  --output-dir DIR          Results directory (default: ${PROPAGATION_RESULTS_DIR}).
  --tuning-baseline STR     Live tuning-baseline levers for the TSV preamble
                            (default: unknown; the sweep queries + threads this).
  --sidecar-egress-hosts STR  Live root-Sidecar egress hosts for the TSV preamble
                            (default: unknown; the sweep queries + threads this).
  --tsv                     Also write per-iteration rows to a TSV file.
  --dry-run                 Print the t0 label flip + drain commands and render the
                            backer Deployment / canary Service without touching a
                            cluster.
  -h, --help                Show this help.

Phases (all timed from the same t0 label flip):
  P1  source istiod: convergence-histogram delta _count >= connected proxies.
      p1_conv_p50/p99 need >= 10 / >= 30 samples, else N/A.
  P2  remote istiod: first pilot_xds_pushes{type="eds"} increase. p2_dirty=1 when
      EDS bumped but P3 did not succeed on that remote (bump not attributable).
  P3  remote watcher Envoy /clusters shows the canary endpoint healthy (polled at
      most once per second).

Row status: OK, TIMEOUT_P1/P2/P3/ALL, RESTART (istiod restarted mid-iteration),
DRAIN_TIMEOUT (endpoint did not drain before the next iteration), or
SCRAPE_INCOMPLETE (a pod's /metrics was unreachable, or baseline scrape skew
exceeded FANOUT_MAX_SKEW_MS).

Summary (stdout and endpoint-<RUN_ID>.md): averages over the rows 005 counts
(status OK, restarted=0, no +Inf overflow), as n_valid/n_total, with the other
rows tallied by reason. One definition decides for both: tests/lib/propagation.sh.

Environment:
  ISTIO_VERSION_CHECK (fail, the default, or warn): stop before any change, or warn and
  record what the mesh runs, when the members' Istio CR version is not ISTIO_VERSION.
  SETUP_CONTEXTS, PROPAGATION_TEST_NAMESPACE, PROPAGATION_POLL_INTERVAL_MS,
  PROPAGATION_TIMEOUT_SEC, PROPAGATION_ITERATIONS, PROPAGATION_SETTLE_SEC,
  PROPAGATION_DRAIN_TIMEOUT_SEC (drain wait per iteration, default 20s),
  PROPAGATION_METRICS_TIMEOUT (curl --max-time for /metrics, default 30s),
  FANOUT_PF_BASE (istiod port-forward block base, default 21014),
  FANOUT_CTX_STRIDE (ports per context, default 20),
  FANOUT_MAX_SKEW_MS (baseline scrape-skew ceiling, default 1000),
  PROPAGATION_RESULTS_DIR (--output-dir; relative to the repo root).
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
	--sweep-run-id)
		[[ -n "${2:-}" ]] || die "--sweep-run-id requires a value"
		SWEEP_RUN_ID="$2"
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
	--poll-interval-ms)
		[[ -n "${2:-}" ]] || die "--poll-interval-ms requires a value"
		POLL_INTERVAL_MS="$2"
		shift 2
		;;
	--settle-sec)
		[[ -n "${2:-}" ]] || die "--settle-sec requires a value"
		SETTLE_SEC="$2"
		shift 2
		;;
	--output-dir)
		[[ -n "${2:-}" ]] || die "--output-dir requires a value"
		OUTPUT_DIR="$2"
		shift 2
		;;
	--tsv)
		WRITE_TSV=1
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

[[ -n "$SOURCE_CTX" ]] || die "--source-context is required"
is_pos_int "$POLL_INTERVAL_MS" || die "--poll-interval-ms must be a positive integer (got: $POLL_INTERVAL_MS)"
is_pos_int "$ITERATIONS" || die "--iterations must be a positive integer (got: $ITERATIONS)"
is_pos_int "$TIMEOUT_SEC" || die "--timeout must be a positive integer (got: $TIMEOUT_SEC)"
is_nonneg_int "$SETTLE_SEC" || die "--settle-sec must be a non-negative integer (got: $SETTLE_SEC)"
POLL_INTERVAL_S="$(awk -v ms="$POLL_INTERVAL_MS" 'BEGIN { printf "%.3f", ms / 1000 }')"

KUBECTL=()
resolve_kubectl KUBECTL

command -v helm >/dev/null 2>&1 || die "helm not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
command -v curl >/dev/null 2>&1 || die "curl not found on PATH"
command -v awk >/dev/null 2>&1 || die "awk not found on PATH"

REMOTES=()
if [[ -n "$REMOTE_CONTEXTS_CSV" ]]; then
	split_csv "$REMOTE_CONTEXTS_CSV" REMOTES
fi

if [[ -z "$MESH_SIZE" ]]; then
	MESH_SIZE=$(( 1 + ${#REMOTES[@]} ))
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
HARNESS_SHA="$(git -C "$ROOT" describe --always --dirty --abbrev=7 2>/dev/null || echo unknown)"
TSV_FILE="${OUTPUT_DIR}/endpoint-${RUN_ID}.tsv"

if ((DRY_RUN)); then
	echo "=== Dry-run: endpoint propagation probe on source context $SOURCE_CTX ==="
	echo "Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE | Iterations: $ITERATIONS | Poll: ${POLL_INTERVAL_S}s"
	echo ""
	echo "001 creates the backer and canary Service; at t0 this probe only labels the"
	echo "backer pod. No cluster is contacted in --dry-run."
	echo ""
	echo "--- Backer Deployment (created by 001, shown for reference) ---"
	helm template propagation-test "$CHART_DIR" \
		--set clusterName="$SOURCE_CTX" \
		--set namespace="$NS" \
		--set backer.enabled=true \
		--set backer.active=false \
		--set backer.image.tag="$HTTP_ECHO_VERSION" \
		--show-only templates/canary-deployment.yaml
	echo ""
	echo "--- Canary Service (selects on active label; here rendered ACTIVE) ---"
	helm template propagation-test "$CHART_DIR" \
		--set clusterName="$SOURCE_CTX" \
		--set namespace="$NS" \
		--set backer.enabled=true \
		--set backer.active=true \
		--show-only templates/canary-service.yaml
	echo ""
	echo "--- t0 mutation (T0 is captured immediately before this command) ---"
	echo "${KUBECTL[*]} --context=${SOURCE_CTX} -n ${NS} label pod <backer-pod> ${CANARY_ACTIVE_LABEL_KEY}=true --overwrite"
	echo ""
	echo "--- drain (removes the label) ---"
	echo "${KUBECTL[*]} --context=${SOURCE_CTX} -n ${NS} label pod <backer-pod> ${CANARY_ACTIVE_LABEL_KEY}- --overwrite"
	exit 0
fi

mkdir -p "$OUTPUT_DIR"

ALL_CTXS=("$SOURCE_CTX" "${REMOTES[@]}")
KUBE_VERSIONS_CSV="$(probe_kube_versions "$(IFS=,; echo "${ALL_CTXS[*]}")" "${KUBECTL[@]}")"
# R4: the Istio version the members run, before the first mutation (inherited when 006
# runs this probe; read here when it runs alone). ISTIO_VERSION_CHECK=fail stops on a
# mismatch.
istio_version_resolve "$(IFS=,; echo "${ALL_CTXS[*]}")" 0 "${KUBECTL[@]}"

# Preflight every context (tests/lib/fanout.sh): require >= 1 Running istiod pod.
# Multi-replica istiod is supported via the per-pod fanout below. Record the
# per-context replica counts (CSV) for the TSV preamble (PL2); the source count
# is the headline ISTIOD_REPLICAS.
ISTIOD_REPLICAS_CSV=""
SOURCE_REPLICAS=""
for ctx in "${ALL_CTXS[@]}"; do
	r="$(fanout_preflight_istiod "$ctx" "${KUBECTL[@]}")"
	[[ -z "$SOURCE_REPLICAS" ]] && SOURCE_REPLICAS="$r"
	[[ -n "$ISTIOD_REPLICAS_CSV" ]] && ISTIOD_REPLICAS_CSV+=","
	ISTIOD_REPLICAS_CSV+="${ctx}=${r}"
done

if ((WRITE_TSV)); then
	{
		echo "# Endpoint propagation latency test"
		# SWEEP_RUN_ID is only emitted when running under 006-run-sweep.sh; standalone
		# probe invocations omit it so the preamble doesn't carry a misleading "" value.
		[[ -n "$SWEEP_RUN_ID" ]] && echo "# SWEEP_RUN_ID=${SWEEP_RUN_ID}"
		echo "# RUN_ID=${RUN_ID}"
		echo "# HARNESS_SHA=${HARNESS_SHA}"
		istio_version_kv | sed 's/^/# /'
		echo "# KUBE_VERSIONS=${KUBE_VERSIONS_CSV}"
		echo "# ISTIOD_REPLICAS=${ISTIOD_REPLICAS_CSV}"
		echo "# SOURCE_CTX=${SOURCE_CTX}"
		echo "# REMOTES=${REMOTES[*]:-none}"
		echo "# MESH_SIZE=${MESH_SIZE}"
		echo "# ITERATIONS=${ITERATIONS}"
		echo "# POLL_INTERVAL_S=${POLL_INTERVAL_S}"
		echo "# TIMEOUT_SEC=${TIMEOUT_SEC}"
		echo "# DRAIN_TIMEOUT_SEC=${DRAIN_TIMEOUT_SEC}"
		echo "# SETTLE_SEC=${SETTLE_SEC}"
		# Tuning-baseline provenance (PL2): live mesh levers + sidecar egress graph,
		# threaded in from the sweep (queried once via tuning_baseline_state); "unknown"
		# on a standalone run.
		echo "# TUNING_BASELINE=${TUNING_BASELINE}"
		echo "# SIDECAR_EGRESS_HOSTS=${SIDECAR_EGRESS_HOSTS}"
		# PL2 (R2-4): both are result-affecting. FANOUT_MAX_SKEW_MS decides which
		# rows are tagged SCRAPE_INCOMPLETE (dropped by 005); METRICS_TIMEOUT bounds
		# the per-curl wait and therefore the worst-case skew the gate can measure.
		echo "# FANOUT_MAX_SKEW_MS=${FANOUT_MAX_SKEW_MS}"
		echo "# FANOUT_METRICS_TIMEOUT=${METRICS_TIMEOUT}"
		echo "# BACKER_IMAGE=${BACKER_IMAGE}"
		config_preamble_lines
		echo "# DATE=$(date -u -Iseconds)"
	} > "$TSV_FILE"
	# Columns (tab-separated). Old p1/p2/p3 cols preserved for back-compat with
	# pre-branch readers. New columns are appended. p2_dirty is a 0/1 flag set to 1
	# (R3-1) when the EDS push bumped but the canary did NOT become health_flags::
	# healthy on this remote's watcher within the window (P3 did not succeed) — i.e.
	# the EDS bump could not be attributed to our canary (likely unrelated endpoint
	# churn). restarted is 0/1/unknown.
	echo -e "run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms" >> "$TSV_FILE"
fi

PF_PIDS=()
POLL_PIDS=()
TMPDIR_RUN=$(mktemp -d)
# Every row, with or without --tsv: the summary below is computed from it (R6).
ROWS_FILE="${TMPDIR_RUN}/rows.tsv"
: > "$ROWS_FILE"

# Per-context istiod pod-port blocks (tests/lib/fanout.sh). The source context is
# fanout ctx_index 0; remote i is ctx_index i+1 (collision-free port blocks).
# Remote port lists are stored as newline strings keyed by remote index (bash
# has no array-of-arrays); load_rmt_istiod_ports re-expands them.
SRC_ISTIOD_PORTS=()
declare -A RMT_ISTIOD_PORTS_STR=()
# The pods behind those ports (same order): each iteration's pre-window pod set for the
# istiod restart evidence (tests/lib/istiod-diag.sh).
SRC_ISTIOD_PODS=()
declare -A RMT_ISTIOD_PODS_STR=()

cleanup() {
	for pid in "${POLL_PIDS[@]}"; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	POLL_PIDS=()
	for pid in "${PF_PIDS[@]}"; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	PF_PIDS=()
	rm -rf "$TMPDIR_RUN"
}

trap cleanup EXIT

# Load a remote's istiod pod-ports into a named array.
load_rmt_istiod_ports() {
	local idx="$1"
	local -n _arr="$2"
	_arr=()
	local p
	while IFS= read -r p; do [[ -n "$p" ]] && _arr+=("$p"); done <<<"${RMT_ISTIOD_PORTS_STR[$idx]}"
}

# H1: per-iteration liveness check on a context's istiod PF block. If ANY pod
# port's /metrics is unresponsive, kill that context's PFs and re-open the block.
# Note: re-opening re-lists Running pods, so a pod-set change is picked up here.
fanout_reopen_if_dead() {
	local ctx="$1"
	local -n _ports="$2"
	local port alive=1
	for port in "${_ports[@]}"; do
		if ! curl -s -o /dev/null --max-time "$METRICS_TIMEOUT" "http://localhost:$port/metrics" 2>/dev/null; then
			alive=0; break
		fi
	done
	((alive)) && return 0
	echo "  istiod port-forward(s) on $ctx unresponsive — re-opening fanout block..." >&2
	# Kill the whole PF set and re-open every context (cheapest correct option:
	# the PF_PIDS array is shared; we cannot selectively map pids to a context
	# without more bookkeeping, and a re-list is needed anyway on pod churn).
	local pid old_src i
	local -A old_rmt=()
	old_src="$(IFS=$'\n'; echo "${SRC_ISTIOD_PODS[*]}")"
	for i in "${!RMT_ISTIOD_PODS_STR[@]}"; do old_rmt[$i]="${RMT_ISTIOD_PODS_STR[$i]}"; done
	for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
	PF_PIDS=()
	open_all_istiod_fanouts
	# A replaced istiod pod kills its port-forward, so its iteration's row reads as a
	# timeout or SCRAPE_INCOMPLETE, not RESTART. The re-open's listing shows the
	# replacement: capture it against the previous iteration's baseline.
	if ((iter > 1)); then
		diag_podset_changed "$SOURCE_CTX" "$old_src" "$(IFS=$'\n'; echo "${SRC_ISTIOD_PODS[*]}")" source
		for i in "${!REMOTES[@]}"; do
			diag_podset_changed "${REMOTES[i]}" "${old_rmt[$i]:-}" "${RMT_ISTIOD_PODS_STR[$i]:-}" "remote-${i}"
		done
	fi
}

# diag_podset_changed <ctx> <old_pods> <new_pods> <prefix>: capture istiod restart evidence
# (tests/lib/istiod-diag.sh, trigger podset_changed) when the context's istiod pods differ
# from those of the previous iteration's baseline (<prefix>.podset and <prefix>-<j>.metrics
# in its baseline dir). Uses the listing the re-open already made: no API call when the
# pods match. Always returns 0.
diag_podset_changed() {
	local ctx="$1" old="$2" new="$3" prefix="$4" prev
	[[ -n "$old" && "$old" != "$new" ]] || return 0
	prev="${TMPDIR_RUN}/baseline-$((iter - 1))"
	[[ -s "${prev}/${prefix}.podset" ]] || return 0
	istiod_diag_capture "$DIAG_DIR" "iter$((iter - 1))" "$ctx" podset_changed \
		"${prev}/${prefix}.podset" "$(podset_metrics_csv "$prev" "$prefix")" "${KUBECTL[@]}"
	return 0
}

# podset_metrics_csv <dir> <prefix>: the per-pod scrapes <dir>/<prefix>-<j>.metrics, lined
# up with <dir>/<prefix>.podset, comma-joined (empty without the pod set).
podset_metrics_csv() {
	local dir="$1" prefix="$2" csv="" n=0 p
	[[ -f "${dir}/${prefix}.podset" ]] || return 0
	while IFS= read -r p; do
		[[ -n "$p" ]] || continue
		csv+="${csv:+,}${dir}/${prefix}-${n}.metrics"
		n=$((n + 1))
	done < "${dir}/${prefix}.podset"
	echo "$csv"
}

start_envoy_port_forward() {
	local ctx="$1" local_port="$2"
	"${KUBECTL[@]}" --context="$ctx" -n "$NS" port-forward deploy/propagation-watcher "$local_port":15000 >/dev/null 2>&1 &
	PF_PIDS+=($!)
	local attempts=0
	# P4: --max-time bounds the readiness probe so a stuck/half-open watcher PF can't
	# block ~30s/attempt at scale (matches the istiod /metrics readiness curl at :444;
	# the data-path /clusters curls at :944/:1029 already use --max-time "$METRICS_TIMEOUT").
	while ! curl -s -o /dev/null --max-time 2 "http://localhost:$local_port/clusters" 2>/dev/null; do
		attempts=$((attempts + 1))
		((attempts > 30)) && die "port-forward to watcher envoy on $ctx (port $local_port) failed to connect"
		sleep 0.5
	done
}

# --- metric helpers ----------------------------------------------------------
# istiod /metrics is scraped per-pod by tests/lib/fanout.sh; honor the suite's
# configurable curl timeout (PROPAGATION_METRICS_TIMEOUT) for large meshes.
export FANOUT_METRICS_TIMEOUT="$METRICS_TIMEOUT"

# --- one-pass file-based extractors ----------------------------------------
# D1: at scrape sizes of multiple MB, calling `echo "$metrics" | awk` 4x per
# tick burns CPU on the harness host and competes with the work we measure.
# Everything below reads the metrics text from a file (written once per tick
# by scrape_metrics_to_file) and a single awk pass emits all derived fields.
#
# extract_all_from_file METRICS_FILE NAME OUT_HIST OUT_KV
#   - METRICS_FILE: path to /metrics text dumped by scrape_metrics_to_file.
#   - NAME: histogram metric name (e.g. pilot_proxy_convergence_time).
#   - OUT_HIST: bucket file (one "<le>\t<count>" row per bucket, then "_sum\t…"
#     and "_count\t…"). Buckets are emitted in numeric ascending order with
#     +Inf last (A4).
#   - OUT_KV: simple key=value file with fields:
#         pilot_xds            (gauge sum across label permutations, "N/A" if absent)
#         pilot_services       (gauge sum, "0" if absent)
#         eds_count            (sum of pilot_xds_pushes{type="eds"})
#         pushes_total         (sum of pilot_xds_pushes across all label permutations)
#         process_start        (integer seconds, or "unknown")
#     eds_count is 0 when the series is absent, unlike metrics.sh's counters (R10,
#     `unknown`). That is deliberate: it is never reported as a delta, only polled for
#     its first increase over the baseline (P2). A series registered in the window
#     counts from 0, and one absent all along never increases, so P2 ends TIMEOUT,
#     never a 0 ms or 0-push result. Incomplete ticks are skipped (PL29).
extract_all_from_file() {
	local infile="$1" name="$2" out_hist="$3" out_kv="$4"
	awk -v name="$name" -v HIST_OUT="$out_hist" -v KV_OUT="$out_kv" '
		BEGIN {
			n_bk = 0
			sum = ""; cnt = ""
			pilot_xds = "N/A"; pilot_xds_seen = 0
			pilot_services = 0; pilot_services_seen = 0
			eds_count = 0
			pushes_total = 0
			process_start = "unknown"
			hist_bucket_prefix = name "_bucket{"
			hist_sum_prefix    = name "_sum"
			hist_cnt_prefix    = name "_count"
			hist_sum_prefix_l  = name "_sum{"
			hist_cnt_prefix_l  = name "_count{"
		}
		/^#/ { next }
		{
			line = $0
			val = $NF + 0
			# Histogram buckets.
			if (index(line, hist_bucket_prefix) == 1) {
				le_line = line
				sub(/.*le="/, "", le_line)
				sub(/".*/, "", le_line)
				le = le_line
				bucket_counts[le] += val
				if (!(le in seen_le)) {
					seen_le[le] = 1
					bucket_order[++n_bk] = le
				}
				next
			}
			# _sum / _count (scalar or labeled).
			if (index(line, hist_sum_prefix_l) == 1) {
				sum_total += val; sum_seen = 1; next
			}
			if (index(line, hist_cnt_prefix_l) == 1) {
				cnt_total += val; cnt_seen = 1; next
			}
			if (index(line, hist_sum_prefix) == 1) {
				if (substr(line, length(hist_sum_prefix)+1, 1) != "{") { sum = $NF; next }
			}
			if (index(line, hist_cnt_prefix) == 1) {
				if (substr(line, length(hist_cnt_prefix)+1, 1) != "{") { cnt = $NF; next }
			}
			# pilot_xds gauge (sum across label permutations).
			if (line ~ /^pilot_xds[{ ]/) {
				if (!pilot_xds_seen) { pilot_xds = 0; pilot_xds_seen = 1 }
				pilot_xds += val
				next
			}
			# pilot_services gauge.
			if (line ~ /^pilot_services[{ ]/) {
				if (!pilot_services_seen) { pilot_services = 0; pilot_services_seen = 1 }
				pilot_services += val
				next
			}
			# pilot_xds_pushes counters (filter eds via label substring).
			if (line ~ /^pilot_xds_pushes[{ ]/) {
				pushes_total += val
				if (index(line, "type=\"eds\"") > 0) eds_count += val
				next
			}
			# process start time.
			if (line ~ /^process_start_time_seconds/) {
				process_start_val = $NF + 0
				if (process_start_val > 0) {
					process_start = sprintf("%d", process_start_val)
				}
				next
			}
		}
		END {
			# Compose final _sum / _count from labeled-aggregate if present.
			if (sum_seen) sum = sum_total
			if (cnt_seen) cnt = cnt_total
			if (sum == "") sum = 0
			if (cnt == "") cnt = 0
			# Sort buckets ascending by numeric le; +Inf goes last (A4).
			# Build sortable key by mapping +Inf to a huge sentinel.
			n_sorted = 0
			for (i = 1; i <= n_bk; i++) {
				le = bucket_order[i]
				sorted_le[++n_sorted] = le
				if (le == "+Inf") {
					sorted_key[n_sorted] = 1e308
				} else {
					sorted_key[n_sorted] = le + 0
				}
			}
			# Insertion sort by sorted_key.
			for (i = 2; i <= n_sorted; i++) {
				k = sorted_key[i]; v = sorted_le[i]; j = i - 1
				while (j >= 1 && sorted_key[j] > k) {
					sorted_key[j+1] = sorted_key[j]
					sorted_le[j+1]  = sorted_le[j]
					j--
				}
				sorted_key[j+1] = k
				sorted_le[j+1]  = v
			}
			for (i = 1; i <= n_sorted; i++) {
				le = sorted_le[i]
				printf "%s\t%d\n", le, bucket_counts[le] > HIST_OUT
			}
			printf "_sum\t%s\n_count\t%s\n", sum, cnt > HIST_OUT
			close(HIST_OUT)
			# Key-value sidecar.
			printf "pilot_xds=%s\n", (pilot_xds_seen ? sprintf("%.0f", pilot_xds) : "N/A") > KV_OUT
			printf "pilot_services=%.0f\n", pilot_services > KV_OUT
			printf "eds_count=%.0f\n", eds_count > KV_OUT
			printf "pushes_total=%.0f\n", pushes_total > KV_OUT
			printf "process_start=%s\n", process_start > KV_OUT
			close(KV_OUT)
		}
	' "$infile"
}

# kv_get FILE KEY  -> value (empty if missing)
kv_get() {
	awk -F'=' -v k="$2" '$1 == k { print $2; exit }' "$1"
}

# --- per-pod fanout scrape + aggregate -------------------------------------
# The mesh runs a FIXED multi-replica istiod (svc/istiod load-balances to ONE
# pod, so a single scrape sees ~1/replicas of the proxies/pushes). We scrape
# EVERY Running istiod pod per context (ports allocated by tests/lib/fanout.sh)
# and aggregate per the metric class:
#   pilot_xds (connected proxies)  -> SUM across pods (each proxy = one conn)
#   pilot_services (mesh registry) -> INVARIANT: MAX across pods, NOT sum
#   eds_count / pushes_total       -> SUM across pods (one replica emits each)
#   histogram buckets/_sum/_count  -> SUM each bucket across pods (PL11)
#   process_start                  -> per-pod signature (sorted join); any pod
#                                     start-time advance OR pod-set change flips it
#
# fanout_scrape_aggregate <out_dir> <prefix> <hist_metric> <port>...
#   Writes (compatible with the existing delta_histogram / kv_get consumers):
#     <out_dir>/<prefix>-hist : "<le>\t<count>" rows (summed), then _sum/_count
#     <out_dir>/<prefix>-kv   : pilot_xds, pilot_services, eds_count,
#                               pushes_total, process_start (legacy: max pod's),
#                               proc_start_sig (sorted per-pod start join)
#   Echoes the per-batch scrape skew ms (PL8, spans pods).
fanout_scrape_aggregate() {
	local out_dir="$1" prefix="$2" hist_metric="$3"
	shift 3
	local -a ports=("$@")
	mkdir -p "$out_dir"
	local skew
	skew="$(fanout_scrape_all "$out_dir" "$prefix" "${ports[@]}")"

	# Per-pod single-pass extraction (PL21/PL22) into per-pod hist+kv files.
	local i pod_hist pod_kv
	local -a hist_files=() kv_files=()
	for i in "${!ports[@]}"; do
		pod_hist="${out_dir}/${prefix}-${i}.podhist"
		pod_kv="${out_dir}/${prefix}-${i}.podkv"
		if [[ -s "${out_dir}/${prefix}-${i}.metrics" ]]; then
			extract_all_from_file "${out_dir}/${prefix}-${i}.metrics" "$hist_metric" "$pod_hist" "$pod_kv"
		else
			: > "$pod_hist"
			printf 'pilot_xds=N/A\npilot_services=0\neds_count=0\npushes_total=0\nprocess_start=unknown\n' > "$pod_kv"
		fi
		hist_files+=("$pod_hist")
		kv_files+=("$pod_kv")
	done

	# Merge histogram: SUM each bucket count + _sum/_count across pods.
	awk '
		FNR == 1 { }
		{
			split($0, a, "\t")
			if (a[1] == "_sum") { sum += a[2] + 0; sum_seen = 1; next }
			if (a[1] == "_count") { cnt += a[2] + 0; cnt_seen = 1; next }
			val[a[1]] += a[2] + 0
			if (!(a[1] in seen)) { seen[a[1]] = 1; order[++n] = a[1] }
		}
		END {
			for (i = 1; i <= n; i++) printf "%s\t%d\n", order[i], val[order[i]]
			printf "_sum\t%s\n", (sum_seen ? sum : 0)
			printf "_count\t%s\n", (cnt_seen ? cnt : 0)
		}
	' "${hist_files[@]}" > "${out_dir}/${prefix}-hist"

	# Aggregate KV with per-field reducers.
	#   pilot_xds: SUM (skip "N/A"/missing)        pilot_services: MAX (invariant)
	#   eds_count/pushes_total: SUM                process_start: max pod (legacy
	#     scalar) + proc_start_sig (sorted join of per-pod starts; restart signal)
	awk '
		{ split($0, a, "="); k = a[1]; v = a[2] }
		k == "pilot_xds"      { if (v != "N/A" && v != "") { xds += v + 0; xds_seen = 1 } }
		k == "pilot_services" { if (v != "" && (v + 0) > svc) svc = v + 0; svc_seen = (svc_seen || v != "") }
		k == "eds_count"      { eds += v + 0 }
		k == "pushes_total"   { pushes += v + 0 }
		k == "process_start"  {
			if (v != "" && v != "unknown") {
				starts[++ns] = v
				if ((v + 0) > maxstart) maxstart = v + 0
				start_seen = 1
			} else {
				# a missing per-pod start makes the whole signature unknown
				missing = 1
			}
		}
		END {
			printf "pilot_xds=%s\n", (xds_seen ? sprintf("%.0f", xds) : "N/A")
			printf "pilot_services=%s\n", (svc_seen ? sprintf("%.0f", svc) : "0")
			printf "eds_count=%.0f\n", eds
			printf "pushes_total=%.0f\n", pushes
			printf "process_start=%s\n", (start_seen ? sprintf("%d", maxstart) : "unknown")
			# Deterministic signature: sort the per-pod start values then join.
			if (missing || !start_seen) {
				printf "proc_start_sig=unknown\n"
			} else {
				# insertion sort starts[1..ns]
				for (i = 2; i <= ns; i++) {
					key = starts[i]; j = i - 1
					while (j >= 1 && (starts[j] + 0) > (key + 0)) { starts[j+1] = starts[j]; j-- }
					starts[j+1] = key
				}
				sig = ""
				for (i = 1; i <= ns; i++) sig = sig (i > 1 ? "," : "") sprintf("%d", starts[i] + 0)
				printf "proc_start_sig=%s\n", sig
			}
		}
	' "${kv_files[@]}" > "${out_dir}/${prefix}-kv"

	echo "$skew"
}

# delta_histogram BASELINE_FILE CURRENT_FILE OUTFILE
#   Computes per-bucket delta of two histogram snapshots.
#   - Sets first line of OUTFILE to "_count\tDELTA"
#   - Sets second line "_sum\tDELTA"
#   - Sets third line "_overflow\t0|1" — 1 if the +Inf bucket gained samples
#     beyond the finite buckets (i.e. some samples landed in the overflow bin).
#   - Then per finite bucket: "<le>\t<delta_count>"
#   - Returns 1 (exit) on negative bucket delta; OUTFILE marker line "_neg\t1" written.
delta_histogram() {
	local baseline="$1" current="$2" outfile="$3"
	awk -v BASE="$baseline" '
		BEGIN {
			while ((getline line < BASE) > 0) {
				split(line, a, "\t")
				base[a[1]] = a[2]
				if (a[1] != "_sum" && a[1] != "_count") {
					if (!(a[1] in seen)) { seen[a[1]] = 1; order[++n] = a[1] }
				}
			}
			close(BASE)
		}
		{
			split($0, a, "\t")
			cur[a[1]] = a[2]
			if (a[1] != "_sum" && a[1] != "_count") {
				if (!(a[1] in seen)) { seen[a[1]] = 1; order[++n] = a[1] }
			}
		}
		END {
			d_count = (cur["_count"] + 0) - (base["_count"] + 0)
			d_sum   = (cur["_sum"]   + 0) - (base["_sum"]   + 0)
			# Histogram counts cannot decrease except via restart.
			if (d_count < 0) {
				print "_neg\t1"
				exit 0
			}
			# Per-bucket deltas; if any individual bucket goes negative we mark _neg.
			for (i = 1; i <= n; i++) {
				le = order[i]
				bd = (cur[le] + 0) - (base[le] + 0)
				if (bd < 0) {
					print "_neg\t1"
					exit 0
				}
				delta[le] = bd
			}
			printf "_count\t%d\n", d_count
			printf "_sum\t%.6f\n", d_sum
			# Compute overflow flag: did the +Inf bucket exceed the largest finite?
			inf = delta["+Inf"] + 0
			max_finite = 0
			for (i = 1; i <= n; i++) {
				le = order[i]
				if (le != "+Inf" && delta[le] > max_finite) max_finite = delta[le]
			}
			overflow = (inf > max_finite) ? 1 : 0
			printf "_overflow\t%d\n", overflow
			for (i = 1; i <= n; i++) {
				le = order[i]
				printf "%s\t%d\n", le, delta[le]
			}
		}
	' "$current" > "$outfile"
}

# histogram_quantile DELTA_FILE Q  -> millisecond value (or N/A)
#   Operates on a delta-histogram file (output of delta_histogram).
#   A5: returns "N/A" when sample count is too small for the requested
#   quantile to be meaningful. Thresholds:
#     p99 (Q >= 0.95): require total >= 30
#     p50 (else):      require total >= 10
#   Documented in the README's TSV schema section.
histogram_quantile() {
	local file="$1" q="$2"
	awk -v Q="$q" '
		BEGIN { total = 0; n = 0; neg = 0 }
		$1 == "_neg" { neg = 1; next }
		$1 == "_count" { total = $2 + 0; next }
		$1 == "_sum" { next }
		$1 == "_overflow" { next }
		{
			n++
			le[n] = $1
			c[n] = $2 + 0
		}
		END {
			if (neg) { print "N/A"; exit }
			if (total == 0 || n == 0) { print "N/A"; exit }
			# A5: min-sample guard.
			min_samples = (Q + 0 >= 0.95) ? 30 : 10
			if (total < min_samples) { print "N/A"; exit }
			target = total * Q
			for (i = 1; i <= n; i++) {
				if (c[i] + 0 >= target) {
					if (le[i] == "+Inf") { print "overflow"; exit }
					# Bucket "le" values are in seconds for pilot histograms.
					printf "%.0f\n", le[i] * 1000.0
					exit
				}
			}
			print "N/A"
		}
	' "$file"
}

bucket_range() {
	local v="${1:-0}"
	[[ "$v" == "N/A" ]] && { echo "N/A"; return; }
	# histogram_quantile's +Inf answer; bash arithmetic would read the word as 0 (N/A).
	[[ "$v" == "overflow" ]] && { echo "overflow"; return; }
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

# A2: proxy count is parsed from the SAME baseline scrape, not a separate HTTP
# round-trip. This eliminates a race where a proxy connects/disconnects between
# baseline and the threshold computation, leaving the histogram-_count target
# misaligned with the actual number of proxies that received the resulting push.
# The baseline subshell writes the pilot_xds value into the kv file directly.
normalize_proxy_count() {
	local n="$1"
	if [[ "$n" == "N/A" || -z "$n" || ! "$n" =~ ^[0-9]+$ || "$n" -lt 1 ]]; then
		echo "1"
	else
		echo "$n"
	fi
}

# --- P2 polling: EDS push counter delta on a remote istiod -----------------
# B1 (O1 label-flip topology): a nonzero EDS delta alone is ambiguous — unrelated
# endpoint churn from other workloads on the remote cluster also bumps the counter.
# We need a companion signal that says "this EDS bump is OUR canary, not churn".
#
# The pre-O1 probe required a pilot_services gauge delta >= 1 (t0 CREATED a new
# canary Service, so the remote registry gained a Service). Under O1 the canary
# Service is created ONCE in 001-setup and PERSISTS across iterations; at t0 the
# label flip adds only an ENDPOINT to the existing Service, so pilot_services does
# NOT change — svc_delta is 0 every iteration and the old check flagged p2_dirty=1
# unconditionally, structurally always-dropping p2_ms in 005.
#
# Round-2 reconciled cleanliness against an instantaneous health_flags::healthy
# /clusters read AT THE EDS-BUMP INSTANT — but that is causally too early: istiod
# increments pilot_xds_pushes{type=eds} when it ISSUES the push, and the sidecar
# only reports health_flags::healthy after it APPLIES it (that lag IS the P3-P2 gap,
# necessarily > 0). So a legitimately-clean iteration read "not healthy yet ->
# dirty=1", re-collapsing the P2 column. R3-1 FIX: this poll loop no longer makes
# the dirty decision at all — it only stamps the P2 LATENCY timestamp at the first
# EDS bump. p2_dirty is reconciled by the CALLER against the SAME remote's P3
# OUTCOME (clean iff the canary became health_flags::healthy within the window, i.e.
# P3 succeeded; dirty iff EDS bumped but P3 timed out / never went healthy). P3's
# own retrying poll already waits for that signal, so there is no second /clusters
# consumer racing the P3 poller here.
# Fanned out across the remote's istiod pods: eds_count + pushes_total SUM across
# pods, restart via proc_start_sig.
poll_p2_remote_eds_push() {
	local polldir="$1" t0="$2" baseline_eds="$3" result_file="$4" restart_baseline="$5"
	shift 5
	local -a ports=("$@")
	local deadline_ms=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	local ever_complete=0
	mkdir -p "$polldir"
	while true; do
		local now_ms
		now_ms=$(now_ms)
		if ((now_ms > deadline_ms)); then
			if (( ever_complete )); then echo "TIMEOUT" > "$result_file"; else echo "INCOMPLETE" > "$result_file"; fi
			return
		fi
		# One fanned-out scrape+aggregate per tick (eds_count summed across pods).
		# Skip the detection test on an incomplete scrape (a missing pod undercounts
		# the summed eds_count delta). `|| true`: the aggregate wraps an inherently
		# by-design-non-zero fanout_scrape_all; the .failed sidecar below is the gate
		# (PL29). Bare under set -e would risk an abort (the #31 incident class).
		fanout_scrape_aggregate "$polldir" "tick" pilot_proxy_convergence_time "${ports[@]}" >/dev/null || true
		if (( $(fanout_scrape_failed_count "$polldir" "tick") > 0 )); then
			sleep "$POLL_INTERVAL_S"
			continue
		fi
		ever_complete=1
		local now_start
		now_start=$(kv_get "$polldir/tick-kv" proc_start_sig)
		if [[ "$restart_baseline" != "unknown" && "$now_start" != "unknown" && "$now_start" != "$restart_baseline" ]]; then
			echo "RESTART" > "$result_file"
			return
		fi
		local cur_eds
		cur_eds=$(kv_get "$polldir/tick-kv" eds_count)
		[[ -z "$cur_eds" ]] && cur_eds=0
		# Counter could appear to "decrease" mid restart/deploy; treat as not-yet.
		if (( cur_eds > baseline_eds )); then
			# R3-1: stamp the P2 latency timestamp at the FIRST EDS bump only. The
			# cleanliness (p2_dirty) decision is made by the caller against P3's
			# outcome for this remote — see the per-remote loop below.
			now_ns > "$result_file"
			return
		fi
		sleep "$POLL_INTERVAL_S"
	done
}

# --- P3 polling: watcher Envoy /clusters, rate-limited ---------------------
# Kept on /clusters because there is no equivalent prometheus-formatted metric
# emitted by Envoy admin without an extra stats sink config. Rate-limited to
# >= 1 Hz (or POLL_INTERVAL_S, whichever is larger) to bound load.
poll_p3_sidecar_endpoints() {
	local envoy_port="$1" t0="$2" result_file="$3"
	local deadline_ms=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	# Effective interval >= 1.0s for /clusters.
	local interval="$POLL_INTERVAL_S"
	if awk -v p="$POLL_INTERVAL_S" 'BEGIN { exit !(p + 0 < 1.0) }'; then
		interval="1.0"
	fi
	while true; do
		local now_ms
		now_ms=$(now_ms)
		((now_ms > deadline_ms)) && { echo "TIMEOUT" > "$result_file"; return; }
		local clusters
		clusters=$(curl -fsS --max-time "$METRICS_TIMEOUT" "http://localhost:$envoy_port/clusters" 2>/dev/null) || { sleep "$interval"; continue; }
		# R2-6: anchor health_flags::healthy on a trailing non-identifier boundary so
		# a hypothetical degraded substring (e.g. health_flags::healthy_pending or a
		# future flag that embeds "healthy") cannot match the fully-healthy state and
		# burn the whole TIMEOUT_SEC per remote x iteration on a false negative.
		if echo "$clusters" | grep -Eq "propagation-canary[^[:space:]]*health_flags::healthy([^a-zA-Z_]|$)"; then
			now_ns > "$result_file"
			return
		fi
		sleep "$interval"
	done
}

# --- P1 polling: histogram convergence on the source istiod (fanned out) ----
# PL20 (mesh-wide): converge when Σ delta _count across ALL source pods >=
# Σ pilot_xds across ALL source pods. fanout_scrape_aggregate sums the
# convergence-histogram buckets/_count AND pilot_xds across pods, so delta_count
# of the merged histogram is exactly "Σ delta _count" and proxy_count (passed in)
# is exactly "Σ pilot_xds" — the existing threshold is the mesh-wide rule.
poll_p1_local_sync_histogram() {
	local polldir="$1" t0="$2" baseline_hist="$3" \
		result_file="$4" proxy_count="$5" restart_baseline="$6" final_snapshot_file="$7"
	shift 7
	local -a ports=("$@")
	local deadline_ms=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	mkdir -p "$polldir"
	local delta_file ever_complete=0
	delta_file=$(mktemp "$TMPDIR_RUN/tmp.XXXXXX")
	while true; do
		local now_ms
		now_ms=$(now_ms)
		if ((now_ms > deadline_ms)); then
			# If we never once got a complete fanned-out scrape, the window is
			# untrustworthy — report INCOMPLETE rather than a plain TIMEOUT.
			if (( ever_complete )); then echo "TIMEOUT" > "$result_file"; else echo "INCOMPLETE" > "$result_file"; fi
			rm -f "$delta_file"
			return
		fi
		# One fanned-out scrape+aggregate per tick -> merged hist + kv. Skip the
		# convergence test on an incomplete scrape (a missing pod undercounts the
		# merged _count and would let P1 "converge" against a partial mesh). `|| true`:
		# the aggregate wraps an inherently by-design-non-zero fanout_scrape_all; the
		# .failed sidecar below is the gate (PL29). Bare under set -e risks an abort.
		fanout_scrape_aggregate "$polldir" "tick" pilot_proxy_convergence_time "${ports[@]}" >/dev/null || true
		if (( $(fanout_scrape_failed_count "$polldir" "tick") > 0 )); then
			sleep "$POLL_INTERVAL_S"
			continue
		fi
		ever_complete=1
		local now_start
		now_start=$(kv_get "$polldir/tick-kv" proc_start_sig)
		if [[ "$restart_baseline" != "unknown" && "$now_start" != "unknown" && "$now_start" != "$restart_baseline" ]]; then
			echo "RESTART" > "$result_file"
			rm -f "$delta_file"
			return
		fi
		delta_histogram "$baseline_hist" "$polldir/tick-hist" "$delta_file"
		local d_count
		d_count=$(awk -F'\t' '$1=="_count" {print $2; exit}' "$delta_file")
		[[ -z "$d_count" ]] && d_count=0
		if (( d_count >= proxy_count )); then
			now_ns > "$result_file"
			cp "$polldir/tick-hist" "$final_snapshot_file"
			rm -f "$delta_file"
			return
		fi
		sleep "$POLL_INTERVAL_S"
	done
}

compute_delta_ms() {
	local result_file="$1" t0="$2"
	local ts
	ts=$(<"$result_file")
	case "$ts" in
		TIMEOUT)    echo "TIMEOUT"; return ;;
		RESTART)    echo "N/A"; return ;;
		INCOMPLETE) echo "N/A"; return ;;
		"")         echo "N/A"; return ;;
	esac
	echo $(( (ts - t0) / 1000000 ))
}

wait_sidecar_endpoint_removed() {
	local port="$1"
	local timeout_s="${2:-$TIMEOUT_SEC}"
	local deadline=$(( $(date +%s) + timeout_s ))
	while (($(date +%s) <= deadline)); do
		local data
		data=$(curl -fsS --max-time "$METRICS_TIMEOUT" "http://localhost:$port/clusters" 2>/dev/null) || { sleep "$POLL_INTERVAL_S"; continue; }
		# O1: the canary Service persists across iterations (we flip a label, not
		# delete the Service), so the propagation-canary CLUSTER entry stays in
		# /clusters even after drain. Drained == no HEALTHY endpoint for it (the
		# exact inverse of P3's poll_p3_sidecar_endpoints detection), not the
		# cluster name disappearing. R2-6: same anchored match as P3 detect so the
		# inverse is exact (a degraded "healthy"-substring flag can't make this loop
		# believe the endpoint is still healthy and never-return for the full timeout).
		echo "$data" | grep -Eq "propagation-canary[^[:space:]]*health_flags::healthy([^a-zA-Z_]|$)" || return 0
		sleep "$POLL_INTERVAL_S"
	done
	return 1
}

echo "=== Endpoint propagation probe ==="
echo "Run: $RUN_ID  Harness: $HARNESS_SHA  Istio: $(istio_version_label)"
echo "Source: $SOURCE_CTX | Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
echo "Iterations: $ITERATIONS | Timeout: ${TIMEOUT_SEC}s | Poll: ${POLL_INTERVAL_S}s | Settle: ${SETTLE_SEC}s"
echo ""

# A3 (fixed): the mesh runs a FIXED multi-replica istiod. We fan out a
# port-forward to EVERY Running istiod pod per context and aggregate per-pod
# scrapes (pilot_xds summed, pilot_services invariant=max, histograms
# bucket-summed) so the convergence threshold is computed mesh-wide rather than
# against one random replica's slice. Preflight already ran above (>= 1 Running
# pod per context required; no longer dies on > 1).
echo "istiod replicas per context: ${ISTIOD_REPLICAS_CSV}"

# Open every context's per-pod istiod fanout block. Idempotent re-open is used
# by fanout_reopen_if_dead (rebuilds all blocks after a PF death / pod churn).
open_all_istiod_fanouts() {
	# The pod lists line up with the ports (and so with the scrape files); they become
	# each iteration's pre-window pod set for the istiod restart evidence.
	SRC_ISTIOD_PORTS=()
	SRC_ISTIOD_PODS=()
	fanout_open "$SOURCE_CTX" 0 PF_PIDS SRC_ISTIOD_PORTS SRC_ISTIOD_PODS "${KUBECTL[@]}"
	local i
	local -a rp rpods
	for i in "${!REMOTES[@]}"; do
		rp=()
		rpods=()
		fanout_open "${REMOTES[i]}" $(( i + 1 )) PF_PIDS rp rpods "${KUBECTL[@]}"
		RMT_ISTIOD_PORTS_STR["$i"]="$(IFS=$'\n'; echo "${rp[*]}")"
		RMT_ISTIOD_PODS_STR["$i"]="$(IFS=$'\n'; echo "${rpods[*]}")"
	done
}

echo "Starting port-forwards..."
open_all_istiod_fanouts
SOURCE_ENVOY_PF_PORT=$(( BASE_ENVOY_PF_PORT + ${#REMOTES[@]} ))
start_envoy_port_forward "$SOURCE_CTX" "$SOURCE_ENVOY_PF_PORT"
for i in "${!REMOTES[@]}"; do
	start_envoy_port_forward "${REMOTES[i]}" $(( BASE_ENVOY_PF_PORT + i ))
done
echo "Port-forwards ready."

# R2-2 / R6: the summary at the end averages only the rows 005 counts (the shared
# prop_drop_reason, tests/lib/propagation.sh) and tallies the rest by reason, so a
# mass drop (say SCRAPE_INCOMPLETE from the FANOUT_MAX_SKEW_MS gate at 10x3) shows
# at the probe. Here only the skew attribution is kept: a SCRAPE_INCOMPLETE row of
# an iteration whose baseline skew was high (vs an unreachable pod).
ROWS_DROPPED_SKEW=0
tally_row() {  # <status>
	[[ "$1" == "SCRAPE_INCOMPLETE" && "$SCRAPE_SKEW_HIGH" == "1" ]] && ROWS_DROPPED_SKEW=$((ROWS_DROPPED_SKEW + 1))
	return 0
}
# emit_row <row>: one endpoint row to the summary's rows file and, with --tsv, the TSV.
emit_row() {
	printf '%s\n' "$1" >> "$ROWS_FILE"
	if ((WRITE_TSV)); then printf '%s\n' "$1" >> "$TSV_FILE"; fi
	return 0
}

# istiod restart evidence goes to istiod-diag-<RUN_ID>/ in the output dir (tests/lib/istiod-diag.sh).
DIAG_DIR="$(istiod_diag_dir "$TSV_FILE" "$RUN_ID")"

for ((iter = 1; iter <= ITERATIONS; iter++)); do
	echo ""
	echo "--- Iteration $iter/$ITERATIONS ---"
	RMT_OWN_RESTART=()

	# H1: per-iteration PF liveness check across each context's fanout block. PFs
	# can die silently between iterations (kubectl PF closes idle conns,
	# networking blips); re-opening now avoids attributing a hiccup to istiod and
	# picks up any pod-set change.
	fanout_reopen_if_dead "$SOURCE_CTX" SRC_ISTIOD_PORTS
	for i in "${!REMOTES[@]}"; do
		_rip=()  # populated by load_rmt_istiod_ports via nameref
		load_rmt_istiod_ports "$i" _rip
		fanout_reopen_if_dead "${REMOTES[i]}" _rip
	done

	# Concurrent baseline scrape across all istiods — now fanned out per-pod and
	# aggregated (pilot_xds summed, pilot_services invariant, histograms
	# bucket-summed). scrape_skew spans pods x contexts (PL8).
	echo "  Scraping baselines..."
	BASELINE_DIR="$TMPDIR_RUN/baseline-${iter}"
	mkdir -p "$BASELINE_DIR"
	# Pre-window pod sets, lined up with the per-pod scrape files (istiod restart evidence).
	printf '%s\n' "${SRC_ISTIOD_PODS[@]}" > "$BASELINE_DIR/source.podset"
	for i in "${!REMOTES[@]}"; do
		printf '%s\n' "${RMT_ISTIOD_PODS_STR[$i]:-}" > "$BASELINE_DIR/remote-${i}.podset"
	done
	BASELINE_INCOMPLETE=0
	src_skew="$(fanout_scrape_aggregate "$BASELINE_DIR" "source" pilot_proxy_convergence_time "${SRC_ISTIOD_PORTS[@]}")"
	(( $(fanout_scrape_failed_count "$BASELINE_DIR" "source") > 0 )) && BASELINE_INCOMPLETE=1
	MAX_SKEW="$src_skew"
	for i in "${!REMOTES[@]}"; do
		_rip=()  # populated by load_rmt_istiod_ports via nameref
		load_rmt_istiod_ports "$i" _rip
		r_skew="$(fanout_scrape_aggregate "$BASELINE_DIR" "remote-${i}" pilot_proxy_convergence_time "${_rip[@]}")"
		(( $(fanout_scrape_failed_count "$BASELINE_DIR" "remote-${i}") > 0 )) && BASELINE_INCOMPLETE=1
		(( r_skew > MAX_SKEW )) && MAX_SKEW="$r_skew"
	done
	SCRAPE_SKEW_MS="$MAX_SKEW"
	[[ -z "$SCRAPE_SKEW_MS" ]] && SCRAPE_SKEW_MS=0
	(( BASELINE_INCOMPLETE )) && echo "  Warning: baseline scrape incomplete (a pod's /metrics was unreachable) — row will be tagged SCRAPE_INCOMPLETE" >&2

	# O3: a wide baseline scrape skew means the per-pod/per-context bodies were
	# read seconds apart (e.g. a curl queued behind many port-forward proxies near
	# FANOUT_METRICS_TIMEOUT). The snapshot is then incoherent and the convergence
	# denominator / counter deltas computed across it are untrustworthy. Tag the
	# row via the existing SCRAPE_INCOMPLETE plumbing (the report drops non-OK);
	# field 19 (scrape_skew_ms) is still recorded verbatim for provenance.
	# R2-5: route through the unit-tested fanout_skew_high_value (strict ">"
	# semantics) so the production gate IS the tested gate. SCRAPE_SKEW_MS here is
	# the MAX across the source+remote baseline batches (not tied to one .skew
	# sidecar), so the value-based variant is used rather than fanout_scrape_skew_high.
	SCRAPE_SKEW_HIGH=0
	if [[ "$(fanout_skew_high_value "$SCRAPE_SKEW_MS")" == "1" ]]; then
		SCRAPE_SKEW_HIGH=1
		echo "  Warning: baseline scrape_skew=${SCRAPE_SKEW_MS}ms exceeds FANOUT_MAX_SKEW_MS=${FANOUT_MAX_SKEW_MS}ms — row will be tagged SCRAPE_INCOMPLETE" >&2
	fi

	# A2: parse SOURCE_PROXY_COUNT and SOURCE_START from the same baseline scrape.
	# SOURCE_START is now the per-pod start signature (sorted join) so any pod's
	# restart OR a pod-set change flips it.
	SOURCE_START=$(kv_get "$BASELINE_DIR/source-kv" proc_start_sig)
	SOURCE_PROXY_COUNT=$(normalize_proxy_count "$(kv_get "$BASELINE_DIR/source-kv" pilot_xds)")
	echo "  Source connected proxies (summed across replicas): $SOURCE_PROXY_COUNT (scrape_skew=${SCRAPE_SKEW_MS}ms)"

	# O1: resolve the pre-warmed backer pod BEFORE t0 so its boot (scheduling,
	# image pull, sidecar start) is entirely outside the measured window. The pod
	# was made Ready by 001-setup and persists across iterations.
	# R2-7: during a rolling restart of the backer Deployment two Running pods can
	# coexist (old Terminating-but-still-Running + new). items[0] could pick the
	# terminating one (about to vanish, endpoint already removed), re-introducing the
	# flip-onto-a-dying-pod race O1 removes. Sort by creationTimestamp and take the
	# NEWEST Running pod so a just-rolled replacement wins over a lingering
	# terminating one; the explicit Ready wait below then guarantees readiness before t0.
	BACKER_POD="$("${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" get pods \
		-l app=propagation-canary --field-selector=status.phase=Running \
		--sort-by=.metadata.creationTimestamp \
		-o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
		| tail -n 1 || true)"
	[[ -n "$BACKER_POD" ]] || die "no Running pre-warmed backer pod on $SOURCE_CTX (run 001-setup first)"
	# Guard: the backer must be Ready before t0 (a label flip onto a not-yet-Ready
	# pod would re-introduce boot latency into P3).
	"${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" wait "pod/${BACKER_POD}" \
		--for=condition=Ready --timeout="${TIMEOUT_SEC}s" >/dev/null 2>&1 \
		|| die "backer pod $BACKER_POD on $SOURCE_CTX not Ready before t0"

	T0=$(now_ns)
	echo "  Flipping backer active label on $SOURCE_CTX (pod $BACKER_POD)..."
	# Config-only mutation at t0: label the running backer pod. The canary Service
	# selects on this label, so its endpoint appears with no pod boot; P1/P2/P3
	# share this T0.
	"${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" \
		label "pod/${BACKER_POD}" "${CANARY_ACTIVE_LABEL_KEY}=true" --overwrite >/dev/null

	P1_FILE="$TMPDIR_RUN/p1-${iter}"
	P1_FINAL_SNAPSHOT="$TMPDIR_RUN/p1-final-${iter}"
	: > "$P1_FILE"
	poll_p1_local_sync_histogram \
		"$TMPDIR_RUN/p1poll-${iter}" "$T0" \
		"$BASELINE_DIR/source-hist" "$P1_FILE" \
		"$SOURCE_PROXY_COUNT" "$SOURCE_START" "$P1_FINAL_SNAPSHOT" \
		"${SRC_ISTIOD_PORTS[@]}" &
	POLL_PIDS=($!)

	P2_FILES=()
	P3_FILES=()
	for i in "${!REMOTES[@]}"; do
		p2f="$TMPDIR_RUN/p2_${iter}_${i}"
		p3f="$TMPDIR_RUN/p3_${iter}_${i}"
		: > "$p2f"
		: > "$p3f"
		P2_FILES+=("$p2f")
		P3_FILES+=("$p3f")
		baseline_eds=$(kv_get "$BASELINE_DIR/remote-${i}-kv" eds_count)
		remote_start=$(kv_get "$BASELINE_DIR/remote-${i}-kv" proc_start_sig)
		[[ -z "$baseline_eds" ]] && baseline_eds=0
		_rip=()  # populated by load_rmt_istiod_ports via nameref
		load_rmt_istiod_ports "$i" _rip
		# R3-1: P2 poll only stamps the EDS-bump latency timestamp; p2_dirty is
		# reconciled against P3's outcome at row-write time (below), not here.
		poll_p2_remote_eds_push "$TMPDIR_RUN/p2poll-${iter}-${i}" "$T0" \
			"$baseline_eds" "$p2f" "$remote_start" \
			"${_rip[@]}" &
		POLL_PIDS+=($!)
		poll_p3_sidecar_endpoints $(( BASE_ENVOY_PF_PORT + i )) "$T0" "$p3f" &
		POLL_PIDS+=($!)
	done

	for pid in "${POLL_PIDS[@]}"; do
		wait "$pid" 2>/dev/null || true
	done
	POLL_PIDS=()

	T1=$(now_ns)
	WINDOW_MS=$(( (T1 - T0) / 1000000 ))

	# Compute p1 wall-clock + delta-window quantiles.
	p1_ms=$(compute_delta_ms "$P1_FILE" "$T0")

	# Final post-convergence delta vs baseline for quantiles.
	p1_conv_p50="N/A"
	p1_conv_p99="N/A"
	p1_sample_count="0"
	p1_overflow="0"
	# C2: restarted may be 0, 1, or "unknown". "unknown" means we couldn't
	# determine because baseline OR current process_start_time was missing.
	# We propagate "unknown" rather than silently emitting 0.
	restarted="0"
	if [[ "$SOURCE_START" == "unknown" ]]; then
		restarted="unknown"
	fi
	if [[ -s "$P1_FINAL_SNAPSHOT" ]]; then
		FINAL_DELTA="$TMPDIR_RUN/p1-delta-${iter}"
		delta_histogram "$BASELINE_DIR/source-hist" "$P1_FINAL_SNAPSHOT" "$FINAL_DELTA"
		if grep -q '^_neg' "$FINAL_DELTA"; then
			restarted="1"
		else
			p1_sample_count=$(awk -F'\t' '$1=="_count"{print $2; exit}' "$FINAL_DELTA")
			p1_overflow=$(awk -F'\t' '$1=="_overflow"{print $2; exit}' "$FINAL_DELTA")
			p1_conv_p50=$(histogram_quantile "$FINAL_DELTA" 0.5)
			p1_conv_p99=$(histogram_quantile "$FINAL_DELTA" 0.99)
		fi
	fi

	# Restart detection on the P1 result file overrides.
	p1_raw=$(<"$P1_FILE")
	if [[ "$p1_raw" == "RESTART" ]]; then
		restarted="1"
		p1_conv_p50="N/A"
		p1_conv_p99="N/A"
	fi

	# PL13: when restarted or unknown, quantiles are N/A.
	if [[ "$restarted" == "1" || "$restarted" == "unknown" ]]; then
		p1_conv_p50="N/A"
		p1_conv_p99="N/A"
	fi

	echo "  P1 (local xDS push):   wall=${p1_ms}ms  conv_p50=$(bucket_range "$p1_conv_p50")ms  conv_p99=$(bucket_range "$p1_conv_p99")ms  samples=${p1_sample_count}/${SOURCE_PROXY_COUNT}  overflow=${p1_overflow}  restarted=${restarted}"

	# O1: drain BEFORE the drain-wait so we can report DRAIN_TIMEOUT correctly.
	# Flip the active label OFF (config-only) — the backer pod stays Ready and
	# warm for the next iteration; only the Service endpoint goes away. The
	# Deployment + Service persist across iterations (created by 001-setup).
	echo "  Removing backer active label on $SOURCE_CTX (pod $BACKER_POD)..."
	"${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" \
		label "pod/${BACKER_POD}" "${CANARY_ACTIVE_LABEL_KEY}-" --overwrite >/dev/null 2>&1 || true

	# E1: track per-iteration drain timeout so we can flag the row with
	# status=DRAIN_TIMEOUT. Without this, the next iteration's baseline
	# includes an un-drained canary endpoint, contaminating the data silently.
	drain_timeout="0"
	if ((iter < ITERATIONS)); then
		echo "  Waiting for canary endpoints to drain..."
		# Bounded + PARALLEL drain: this is inter-iteration CLEANUP, not a measured
		# quantity, so each wait uses the short DRAIN_TIMEOUT_SEC (NOT the 120s
		# measurement TIMEOUT_SEC) and all ~N clusters drain concurrently. Each call
		# curls a DIFFERENT localhost port (its own port-forward), so parallel is
		# safe. (Was serial x TIMEOUT_SEC/cluster -> ~11 x 120s per iteration.)
		src_pid=""; remote_pids=()
		wait_sidecar_endpoint_removed "$SOURCE_ENVOY_PF_PORT" "$DRAIN_TIMEOUT_SEC" & src_pid=$!
		for i in "${!REMOTES[@]}"; do
			wait_sidecar_endpoint_removed $(( BASE_ENVOY_PF_PORT + i )) "$DRAIN_TIMEOUT_SEC" & remote_pids[i]=$!
		done
		if ! wait "$src_pid"; then
			echo "  Warning: timeout waiting for $SOURCE_CTX sidecar endpoint removal"
			drain_timeout="1"
		fi
		for i in "${!REMOTES[@]}"; do
			if ! wait "${remote_pids[i]}"; then
				echo "  Warning: timeout waiting for ${REMOTES[i]} sidecar endpoint removal"
				drain_timeout="1"
			fi
		done
		echo "  Canary endpoints drained. Settling for ${SETTLE_SEC}s..."
		sleep "$SETTLE_SEC"
	fi

	# Helper to compute final status. Honors restart, timeouts, drain timeout.
	status_for_row() {
		local p1="$1" p2="$2" p3="$3" rst="$4" drain="$5" incomplete="${6:-0}"
		local s="OK"
		[[ "$p1" == "TIMEOUT" ]] && s="TIMEOUT_P1"
		[[ "$p2" == "TIMEOUT" ]] && s="TIMEOUT_P2"
		[[ "$p3" == "TIMEOUT" ]] && s="TIMEOUT_P3"
		[[ "$p1" == "TIMEOUT" && "$p2" == "TIMEOUT" && "$p3" == "TIMEOUT" ]] && s="TIMEOUT_ALL"
		[[ "$rst" == "1" ]] && s="RESTART"
		# DRAIN_TIMEOUT supersedes only OK (data is suspect for downstream filtering).
		if [[ "$drain" == "1" && "$s" == "OK" ]]; then
			s="DRAIN_TIMEOUT"
		fi
		# SCRAPE_INCOMPLETE: a pod's /metrics was unreachable during baseline or
		# the convergence poll, so the summed pilot_xds / merged histogram /
		# convergence denominator is undercounted. The row is suspect — flag it
		# (the report filters non-OK). Supersedes OK/DRAIN_TIMEOUT but not a
		# RESTART/TIMEOUT which are stronger signals.
		if [[ "$incomplete" == "1" && ( "$s" == "OK" || "$s" == "DRAIN_TIMEOUT" ) ]]; then
			s="SCRAPE_INCOMPLETE"
		fi
		echo "$s"
	}

	# A poll-loop scrape that never completed cleanly also taints the row.
	# O3: a high-skew baseline (incoherent snapshot) taints it the same way.
	row_incomplete="$BASELINE_INCOMPLETE"
	(( SCRAPE_SKEW_HIGH )) && row_incomplete=1
	[[ -s "$P1_FILE" && "$(<"$P1_FILE")" == "INCOMPLETE" ]] && row_incomplete=1

	if [[ ${#REMOTES[@]} -eq 0 ]]; then
		status=$(status_for_row "$p1_ms" "N/A" "N/A" "$restarted" "$drain_timeout" "$row_incomplete")
		tally_row "$status"
		# F1: p1_sample_count is "got/attempted" (delta-_count first, proxy_count second).
		emit_row "$(echo -e "${RUN_ID}\t${MESH_SIZE}\t${iter}\t${SOURCE_CTX}\tN/A\t${T0}\t${p1_ms}\tN/A\tN/A\t${status}\t${p1_conv_p50}\t${p1_conv_p99}\t${p1_sample_count}/${SOURCE_PROXY_COUNT}\t${SOURCE_PROXY_COUNT}\t${p1_overflow}\t${restarted}\t0\t${WINDOW_MS}\t${SCRAPE_SKEW_MS}")"
	else
		for i in "${!REMOTES[@]}"; do
			p2_ms=$(compute_delta_ms "${P2_FILES[i]}" "$T0")
			p3_ms=$(compute_delta_ms "${P3_FILES[i]}" "$T0")
			# C1: per-remote restart flag. Do NOT mutate the outer-scope
			# `restarted` from inside this loop — a single remote restart
			# would leak into every subsequent remote row.
			p2_restarted="$restarted"
			p2_raw=$(<"${P2_FILES[i]}")
			if [[ "$p2_raw" == "RESTART" ]]; then
				p2_restarted="1"
			fi
			# C2: if the baseline per-pod start signature was unknown (a pod's
			# process_start_time was missing) AND there is no explicit RESTART
			# signal, propagate "unknown" instead of "0".
			remote_start=$(kv_get "$BASELINE_DIR/remote-${i}-kv" proc_start_sig)
			if [[ "$p2_restarted" == "0" && "$remote_start" == "unknown" ]]; then
				p2_restarted="unknown"
			fi
			# This remote's own istiod status (p2_restarted also carries the source's), for
			# the restart evidence after the rows.
			RMT_OWN_RESTART[i]=0
			[[ "$remote_start" == "unknown" ]] && RMT_OWN_RESTART[i]=unknown
			[[ "$p2_raw" == "RESTART" ]] && RMT_OWN_RESTART[i]=1
			# R3-1: p2_dirty is reconciled against THIS remote's P3 outcome, not an
			# instantaneous health read at the EDS bump (which is causally too early —
			# the sidecar only goes health_flags::healthy AFTER it applies the push the
			# EDS counter already counted, so the P3-P2 gap would falsely read dirty).
			# An EDS bump is "clean" iff the canary actually became healthy on this
			# remote's watcher within the window (P3 succeeded -> p3_ms numeric), and
			# "dirty" iff EDS bumped but P3 timed out / never went healthy (the bump
			# could not be attributed to our canary => likely unrelated endpoint churn).
			# When EDS never bumped (p2_ms non-numeric) there is no bump to attribute,
			# so p2_dirty stays 0 (the non-numeric p2_ms is excluded from aggregation
			# regardless). P3's own retrying poll is the single /clusters consumer.
			p2_dirty="0"
			if [[ "$p2_ms" =~ ^[0-9]+$ ]] && ! [[ "$p3_ms" =~ ^[0-9]+$ ]]; then
				p2_dirty="1"
			fi

			echo "  P2 (remote istiod ${REMOTES[i]}, EDS push): ${p2_ms}ms  dirty=${p2_dirty} (P3-reconciled)"
			echo "  P3 (remote sidecar ${REMOTES[i]}):          ${p3_ms}ms"

			# A P2 poll scrape that never completed cleanly also taints the remote row.
			p2_incomplete="$row_incomplete"
			[[ -s "${P2_FILES[i]}" && "$(<"${P2_FILES[i]}")" == "INCOMPLETE" ]] && p2_incomplete=1
			status=$(status_for_row "$p1_ms" "$p2_ms" "$p3_ms" "$p2_restarted" "$drain_timeout" "$p2_incomplete")
			tally_row "$status"

			# PL13: counter deltas are N/A on restart or unknown.
			p2_out="$p2_ms"
			if [[ "$p2_restarted" == "1" || "$p2_restarted" == "unknown" ]]; then
				p2_out="N/A"
			fi

			# Trailing columns: p1_conv_p50, p1_conv_p99, p1_sample_count (got/attempted),
			# p1_proxy_count, p1_overflow, restarted, p2_dirty, window_ms, scrape_skew_ms.
			emit_row "$(echo -e "${RUN_ID}\t${MESH_SIZE}\t${iter}\t${SOURCE_CTX}\t${REMOTES[i]}\t${T0}\t${p1_ms}\t${p2_out}\t${p3_ms}\t${status}\t${p1_conv_p50}\t${p1_conv_p99}\t${p1_sample_count}/${SOURCE_PROXY_COUNT}\t${SOURCE_PROXY_COUNT}\t${p1_overflow}\t${p2_restarted}\t${p2_dirty}\t${WINDOW_MS}\t${SCRAPE_SKEW_MS}")"
		done
	fi

	# istiod restart evidence (tests/lib/istiod-diag.sh) for the source and each remote
	# whose own status is not 0, after this iteration's rows; best-effort, never changes a
	# row. A replaced pod usually reads as a timeout here; the re-open check at the next
	# iteration's start catches it (diag_podset_changed).
	if [[ "$restarted" != "0" ]]; then
		istiod_diag_capture "$DIAG_DIR" "iter${iter}" "$SOURCE_CTX" "$restarted" \
			"$BASELINE_DIR/source.podset" "$(podset_metrics_csv "$BASELINE_DIR" source)" "${KUBECTL[@]}"
	fi
	for i in "${!REMOTES[@]}"; do
		[[ "${RMT_OWN_RESTART[i]:-0}" != "0" ]] || continue
		istiod_diag_capture "$DIAG_DIR" "iter${iter}" "${REMOTES[i]}" "${RMT_OWN_RESTART[i]}" \
			"$BASELINE_DIR/remote-${i}.podset" "$(podset_metrics_csv "$BASELINE_DIR" "remote-${i}")" "${KUBECTL[@]}"
	done
done

echo ""
if ((WRITE_TSV)); then
	echo "=== Results written to $TSV_FILE ==="
fi
echo ""
# R6: average exactly the rows 005 counts (prop_drop_reason, tests/lib/propagation.sh:
# status OK, istiod not restarted or unknown, no +Inf overflow, skew within
# FANOUT_MAX_SKEW_MS), per row like 005, and tally the others by reason. Output lines:
# "T total valid dropped", "S phase n min max avg" (min/max/avg "-" without a sample)
# and "D reason count".
SUMMARY_KV="$(awk -F'\t' -v MAXSKEW="${FANOUT_MAX_SKEW_MS:-1000}" "${PROP_ROW_AWK}"'
	function acc(ph, v) {
		n[ph]++; sum[ph] += v
		if (!(ph in mn) || v < mn[ph]) mn[ph] = v
		if (!(ph in mx) || v > mx[ph]) mx[ph] = v
	}
	{
		total++
		r = prop_drop_reason(MAXSKEW)
		if (r != "") { dropped++; drop[r]++; next }
		valid++
		if (prop_p1_sample()) acc("P1", $7 + 0)
		if (prop_p2_sample()) acc("P2", $8 + 0)
		if (prop_p3_sample()) acc("P3", $9 + 0)
	}
	END {
		printf "T\t%d\t%d\t%d\n", total, valid, dropped
		split("P1 P2 P3", ph, " ")
		for (i = 1; i <= 3; i++) {
			p = ph[i]
			if (n[p]) printf "S\t%s\t%d\t%d\t%d\t%.0f\n", p, n[p], mn[p], mx[p], sum[p] / n[p]
			else printf "S\t%s\t0\t-\t-\t-\n", p
		}
		for (r in drop) printf "D\t%s\t%d\n", r, drop[r]
	}' "$ROWS_FILE" | sort)"
ROWS_TOTAL=0 ROWS_VALID=0 DROPPED_TOTAL=0
declare -A PH_N=() PH_MIN=() PH_MAX=() PH_AVG=()
DROP_REASONS=()
while IFS=$'\t' read -r kind a b c d e; do
	case "$kind" in
	T) ROWS_TOTAL="$a" ROWS_VALID="$b" DROPPED_TOTAL="$c" ;;
	S) PH_N[$a]="$b" PH_MIN[$a]="$c" PH_MAX[$a]="$d" PH_AVG[$a]="$e" ;;
	D) DROP_REASONS+=("${a}"$'\t'"${b}") ;;
	esac
done <<<"$SUMMARY_KV"
# Phases with data: P1 always, P2/P3 only with remotes (a single-cluster run has none).
SUMMARY_PHASES=(P1)
((${#REMOTES[@]})) && SUMMARY_PHASES+=(P2 P3)
declare -A PH_LABEL=([P1]="P1 local xDS push" [P2]="P2 remote istiod EDS push" [P3]="P3 remote sidecar")

echo "Summary (${ROWS_VALID} of ${ROWS_TOTAL} rows count, as in 005; n = n_valid samples / n_total rows):"
for ph in "${SUMMARY_PHASES[@]}"; do
	if (( ${PH_N[$ph]:-0} > 0 )); then
		printf "  %-27s n=%d/%d min=%dms max=%dms avg=%dms\n" "${PH_LABEL[$ph]}:" "${PH_N[$ph]}" "$ROWS_TOTAL" \
			"${PH_MIN[$ph]}" "${PH_MAX[$ph]}" "${PH_AVG[$ph]}"
	else
		printf "  %-27s n=0/%d (no valid sample)\n" "${PH_LABEL[$ph]}:" "$ROWS_TOTAL"
	fi
done

echo ""
echo "Row-drop tally (rows left out of the averages above and by 005):"
printf "  rows_dropped_total=%d/%d\n" "$DROPPED_TOTAL" "$ROWS_TOTAL"
for r in "${DROP_REASONS[@]}"; do
	printf "    %-24s %s\n" "${r%%$'\t'*}" "${r#*$'\t'}"
done
printf "  rows_dropped_skew=%d/%d (scrape_skew_ms > FANOUT_MAX_SKEW_MS=%s)\n" \
	"$ROWS_DROPPED_SKEW" "$ROWS_TOTAL" "$FANOUT_MAX_SKEW_MS"

MD_FILE="${OUTPUT_DIR}/endpoint-${RUN_ID}.md"
{
	echo "# Endpoint Propagation Latency"
	echo ""
	echo "| Field | Value |"
	echo "|-------|-------|"
	echo "| Run ID | \`${RUN_ID}\` |"
	echo "| Harness SHA | \`${HARNESS_SHA}\` |"
	echo "| Run config | \`${RUN_CONFIG:-none}\` (sha256 \`${RUN_CONFIG_SHA256:-none}\`) |"
	echo "| Istio version | $(istio_version_label) |"
	echo "| Kube versions | \`${KUBE_VERSIONS_CSV}\` |"
	echo "| istiod replicas | \`${ISTIOD_REPLICAS_CSV}\` |"
	echo "| Date | $(date -u -Iseconds) |"
	echo "| Source | ${SOURCE_CTX} |"
	echo "| Remotes | ${REMOTES[*]:-none} |"
	echo "| Mesh size | ${MESH_SIZE} |"
	echo "| Iterations | ${ITERATIONS} |"
	echo "| Timeout | ${TIMEOUT_SEC}s |"
	echo "| Poll interval | ${POLL_INTERVAL_S}s |"
	echo "| Settle | ${SETTLE_SEC}s |"
	echo ""
	echo "## Methodology"
	echo ""
	echo "- **P1** (local xDS push): \`pilot_proxy_convergence_time\` histogram delta on source istiod."
	echo "  Converged when delta \`_count\` >= \`proxy_count\`. Reports wall-clock"
	echo "  time-to-converged-count plus delta-window p50/p99 of the histogram itself."
	echo "- **P2** (remote discovery): \`pilot_xds_pushes{type=\"eds\"}\` counter delta on each remote"
	echo "  istiod; \`p2_ms\` stamped at the first EDS bump. \`p2_dirty=1\` when the EDS bumped"
	echo "  but our canary did NOT become \`health_flags::healthy\` on that remote's watcher within"
	echo "  the window (P3 did not succeed) — i.e. the bump could not be attributed to our canary."
	echo "  Reconciled against P3's outcome, not an instantaneous health read at the bump (which"
	echo "  would falsely flag the necessary P3-after-P2 apply lag)."
	echo "- **P3** (remote sidecar): watcher Envoy \`/clusters\` polled at >= 1 Hz for a"
	echo "  healthy canary endpoint. t0 is a config-only active-label flip onto a"
	echo "  pre-warmed backer pod, so P3 excludes pod boot / image pull / sidecar startup."
	echo ""
	echo "## Summary"
	echo ""
	echo "Averages over the rows the report (005) counts: status OK, \`restarted=0\` (not 1 or"
	echo "unknown), no +Inf overflow, scrape skew within FANOUT_MAX_SKEW_MS=${FANOUT_MAX_SKEW_MS};"
	echo "P2 also leaves out a dirty sample (\`p2_dirty=1\`). n is n_valid samples / n_total rows."
	echo ""
	echo "| Phase | n_valid / n_total | min (ms) | max (ms) | avg (ms) |"
	echo "|-------|-------------------|----------|----------|----------|"
	for ph in "${SUMMARY_PHASES[@]}"; do
		echo "| ${PH_LABEL[$ph]} | ${PH_N[$ph]:-0}/${ROWS_TOTAL} | ${PH_MIN[$ph]:--} | ${PH_MAX[$ph]:--} | ${PH_AVG[$ph]:--} |"
	done
	echo ""
	if (( DROPPED_TOTAL > 0 )); then
		echo "**${DROPPED_TOTAL} of ${ROWS_TOTAL} rows left out of the averages**, by reason:"
		echo ""
		echo "| Reason | Rows |"
		echo "|--------|------|"
		for r in "${DROP_REASONS[@]}"; do
			echo "| \`${r%%$'\t'*}\` | ${r#*$'\t'} |"
		done
	else
		echo "No rows left out (0 of ${ROWS_TOTAL})."
	fi
	if ((WRITE_TSV)); then
		echo ""
		echo "## Raw Data"
		echo ""
		echo "TSV: [\`$(basename "$TSV_FILE")\`]($(basename "$TSV_FILE"))"
	fi
} > "$MD_FILE"
echo "Summary written to $MD_FILE"

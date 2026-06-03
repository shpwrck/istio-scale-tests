#!/usr/bin/env bash
# Measure endpoint propagation latency across a multi-cluster Istio mesh.
#
# Deploys a canary service on a source cluster, then measures three propagation
# phases on the source and remote clusters:
#
#   P1 — local xDS push convergence on the source istiod
#        Measured via delta of the pilot_proxy_convergence_time histogram
#        (the same metric istiod-monitor's PrometheusRule reads). We snapshot
#        _bucket / _sum / _count BEFORE the canary apply, then poll /metrics
#        until the delta _count >= proxy_count (= every connected proxy
#        has received at least one push triggered by the canary).
#        This avoids self-noise from polling /debug/syncz, which serializes the
#        full push context per request and competes with the work being measured.
#        Reports both the wall-clock time-to-converged-count (p1_ms) and the
#        delta-window p50/p99 of pilot_proxy_convergence_time itself
#        (p1_conv_p50_ms / p1_conv_p99_ms).
#
#   P2 — remote endpoint discovery on each remote istiod
#        Measured via pilot_xds_pushes{type="eds"} counter delta. A single
#        EDS push delta > 0 indicates the remote istiod observed the new
#        endpoint (via remote secret / cross-cluster discovery) and issued
#        an EDS push to its proxies. Cheaper and more deterministic than
#        polling /debug/endpointz (which serializes the endpoint catalogue
#        on each request).
#
#   P3 — remote sidecar endpoint reception on each watcher
#        Measured via the watcher pod's Envoy admin /clusters endpoint, since
#        that is the only data-plane-side signal available without a custom
#        xDS client. Poll is rate-limited and uses a lightweight string match.
#
#   O1: t0 is a config-only mutation. 001-setup pre-warms a Ready backer pod
#   (image pulled, sidecar up, readinessProbe) NOT yet selected by the canary
#   Service. At t0 the probe stamps an active-flip label onto the backer pod so
#   the Service's endpoint appears instantly. All three phases share one T0 (just
#   before the label patch), so P3 measures xDS/EDS propagation for an existing,
#   healthy endpoint — never pod scheduling / image pull / sidecar startup. Drain
#   removes the label; the backer stays warm for the next iteration.
#
# Usage:
#   ./tests/propagation/002-run-endpoint-probe.sh --source-context CTX [--remote-contexts CSV] [options]
#
# Examples:
#   # Measure 2-cluster propagation, 10 iterations:
#   ./tests/propagation/002-run-endpoint-probe.sh --source-context cluster-001 --remote-contexts cluster-002
#
#   # Measure single-cluster baseline (local xDS push only):
#   ./tests/propagation/002-run-endpoint-probe.sh --source-context cluster-001 --mesh-size 1
#
#   # 3-cluster sweep, 5 iterations:
#   ./tests/propagation/002-run-endpoint-probe.sh --source-context cluster-001 \
#     --remote-contexts cluster-002,cluster-003 --mesh-size 3 --iterations 5
# ci-dry-run: --source-context ci-dummy
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/timestamp.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fanout.sh"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

SOURCE_CTX=""
REMOTE_CONTEXTS_CSV=""
MESH_SIZE=""
SWEEP_RUN_ID=""
ITERATIONS="${PROPAGATION_ITERATIONS}"
TIMEOUT_SEC="${PROPAGATION_TIMEOUT_SEC}"
POLL_INTERVAL_MS="${PROPAGATION_POLL_INTERVAL_MS}"
POLL_INTERVAL_S="0.$(printf '%03d' "${POLL_INTERVAL_MS}")"
SETTLE_SEC="${PROPAGATION_SETTLE_SEC}"
METRICS_TIMEOUT="${PROPAGATION_METRICS_TIMEOUT}"
OUTPUT_DIR="${ROOT}/tests/propagation/results"
DRY_RUN=0
WRITE_TSV=0
NS="${PROPAGATION_TEST_NAMESPACE}"
# istiod is reached via tests/lib/fanout.sh (per-pod port block from FANOUT_PF_BASE,
# default 21014). The watcher Envoy PF block (P3, data-plane side) is unchanged.
BASE_ENVOY_PF_PORT=15100
CHART_DIR="${ROOT}/tests/propagation/chart"

# O1: the active-flip label the probe stamps onto the pre-warmed backer pod at t0.
# Must match templates/_helpers.tpl (canary.activeLabelKey / activeSelectorLabels):
# the canary Service selects on app=propagation-canary AND this label, so stamping
# it adds the (already-Ready) backer to the Service endpoints, and removing it
# drains the endpoint — a config-only mutation with no pod boot.
CANARY_ACTIVE_LABEL_KEY="propagation-active"


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --source-context CTX      Kube context for the source cluster (required).
  --remote-contexts CSV     Remote cluster contexts (comma-separated). Omit for single-cluster baseline.
  --mesh-size N             Metadata tag for TSV output (default: 1 + number of remotes).
  --sweep-run-id ID         Outer sweep RUN_ID to record in TSV preamble (default: empty;
                            set by 006-run-sweep.sh — omit when running probe standalone).
  --iterations N            Number of probe iterations (default: \$PROPAGATION_ITERATIONS=$ITERATIONS).
  --timeout SEC             Timeout per iteration (default: \$PROPAGATION_TIMEOUT_SEC=$TIMEOUT_SEC).
  --poll-interval-ms MS     Poll interval in ms (default: \$PROPAGATION_POLL_INTERVAL_MS=$POLL_INTERVAL_MS).
  --settle-sec SEC          Settle gap between iterations after drain (default: \$PROPAGATION_SETTLE_SEC=$SETTLE_SEC).
  --output-dir DIR          Results directory (default: tests/propagation/results).
  --tsv                     Also write per-iteration rows to a TSV file.
  --dry-run                 Render and print canary manifests without applying.
  -h, --help                Show this help.

Measurement methodology:
  P1 (local xDS push)  — pilot_proxy_convergence_time histogram delta on source istiod.
                         Converged when delta _count >= proxy_count (each
                         connected proxy received at least one push).
                         Emits p1_ms (wall-clock to converged-count) plus
                         delta-window p50/p99 (p1_conv_p50_ms / p1_conv_p99_ms).
                         Min-sample guard: p50 N/A if total < 10; p99 N/A if total < 30.
  P2 (remote discovery) — pilot_xds_pushes{type="eds"} counter delta AND
                          pilot_services gauge delta. EDS-only bump (with no
                          services delta) is flagged via p2_dirty=1 because it
                          could be unrelated endpoint churn.
  P3 (remote sidecar)   — watcher Envoy /clusters, rate-limited; the only
                          available data-plane-side signal without a custom
                          xDS client.

Robustness:
  - Multi-replica istiod is supported via per-pod fanout: every Running istiod
    pod per context is port-forwarded (tests/lib/fanout.sh) and the per-pod
    scrapes are aggregated (pilot_xds summed, pilot_services invariant=max,
    convergence histogram buckets summed). The probe dies only when a context
    has ZERO Running istiod pods; it tolerates one replica's PF failing if
    others serve, and tags the row SCRAPE_INCOMPLETE if a pod's /metrics was
    unreachable during baseline or the convergence poll.
  - istiod restart detection via a per-pod process_start_time_seconds signature
    (any pod's start advancing OR a pod-set change -> restarted=1). When restart
    detected mid-iteration, counter deltas and histogram quantiles emit N/A.
    If a pod's process_start_time_seconds is missing, restarted=unknown.
  - Negative histogram bucket deltas emit N/A.
  - +Inf bucket delta is tracked as "overflow" (sample landed above bucket range).
  - Drain-wait timeouts after canary cleanup tag the row with status=DRAIN_TIMEOUT.
  - Server-side apply (--server-side --force-conflicts) on the canary.
  - Concurrent multi-context scrapes; per-iteration scrape_skew_ms is
    max(ts)-min(ts) across context scrape timestamps. A baseline scrape_skew
    exceeding FANOUT_MAX_SKEW_MS (default 1000) tags the row SCRAPE_INCOMPLETE
    (incoherent snapshot) while still recording the raw skew in field 19.

Environment:
  SETUP_CONTEXTS, PROPAGATION_TEST_NAMESPACE, PROPAGATION_POLL_INTERVAL_MS,
  PROPAGATION_TIMEOUT_SEC, PROPAGATION_ITERATIONS, PROPAGATION_SETTLE_SEC,
  PROPAGATION_METRICS_TIMEOUT (curl --max-time for /metrics; default 5s — bump
  for large meshes where /metrics may take longer to render),
  FANOUT_PF_BASE (per-pod istiod port-forward block base; default 21014),
  FANOUT_CTX_STRIDE (per-context port stride; default 20),
  FANOUT_MAX_SKEW_MS (baseline scrape_skew ceiling in ms; default 1000 — a row
  whose max per-context/per-pod baseline skew exceeds this is tagged
  SCRAPE_INCOMPLETE because the snapshot is incoherent; field 19 still records
  the raw skew for provenance).
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
	--sweep-run-id)
		[[ -n "${2:-}" ]] || die "--sweep-run-id requires a value"
		SWEEP_RUN_ID="$2"
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
		POLL_INTERVAL_S="0.$(printf '%03d' "$2")"
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

if command -v oc >/dev/null 2>&1; then
	KUBECTL=(oc)
elif command -v kubectl >/dev/null 2>&1; then
	KUBECTL=(kubectl)
else
	die "neither oc nor kubectl found on PATH"
fi

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

mkdir -p "$OUTPUT_DIR"
TSV_FILE="${OUTPUT_DIR}/endpoint-${RUN_ID}.tsv"

if ((DRY_RUN)); then
	echo "=== Dry-run: O1 label-flip propagation on source context $SOURCE_CTX ==="
	echo ""
	echo "The pre-warmed backer + canary Service are created by 001-setup; this probe"
	echo "does NOT create a workload at t0. It captures the backer pod, sets T0, then"
	echo "stamps the active label (config-only, server-side) so the Service endpoint"
	echo "appears. Drain removes the label. No cluster is contacted in --dry-run."
	echo ""
	echo "--- Backer Deployment (rendered by 001-setup, here for reference) ---"
	# PL27: scope each render to only the template being shown.
	helm template propagation-test "$CHART_DIR" \
		--set clusterName="$SOURCE_CTX" \
		--set namespace="$NS" \
		--set backer.enabled=true \
		--set backer.active=false \
		--set backer.runId="$RUN_ID" \
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
	echo "--- t0 mutation (config-only, server-side apply via kubectl label) ---"
	echo "# T0 is captured immediately BEFORE this patch:"
	echo "${KUBECTL[*]:-oc} --context=${SOURCE_CTX} -n ${NS} label pod <backer-pod> ${CANARY_ACTIVE_LABEL_KEY}=true --overwrite"
	echo ""
	echo "--- drain (config-only, removes the label) ---"
	echo "${KUBECTL[*]:-oc} --context=${SOURCE_CTX} -n ${NS} label pod <backer-pod> ${CANARY_ACTIVE_LABEL_KEY}- --overwrite"
	exit 0
fi

# --- kube-version probe ------------------------------------------------------
# Returns the server's kube version per context concurrently with a short
# request timeout, emitting "unreachable" on connect failure and "unknown" on
# parse failure. Used in the TSV preamble.
probe_kube_versions() {
	local -n _out_csv="$1"
	shift
	local -a ctxs=("$@")
	local tmpdir
	tmpdir=$(mktemp -d)
	local i
	for i in "${!ctxs[@]}"; do
		(
			local ctx="${ctxs[i]}"
			local v
			if ! v=$("${KUBECTL[@]}" --context="$ctx" --request-timeout=5s version -o json 2>/dev/null); then
				echo "${ctx}=unreachable" > "${tmpdir}/${i}"
				exit 0
			fi
			local parsed
			parsed=$(echo "$v" | jq -r '.serverVersion.gitVersion // empty' 2>/dev/null)
			if [[ -z "$parsed" ]]; then
				echo "${ctx}=unknown" > "${tmpdir}/${i}"
			else
				echo "${ctx}=${parsed}" > "${tmpdir}/${i}"
			fi
		) &
	done
	wait
	local csv=""
	for i in "${!ctxs[@]}"; do
		[[ -n "$csv" ]] && csv+=","
		csv+="$(cat "${tmpdir}/${i}")"
	done
	_out_csv="$csv"
	rm -rf "$tmpdir"
}

ALL_CTXS=("$SOURCE_CTX" "${REMOTES[@]}")
KUBE_VERSIONS_CSV=""
probe_kube_versions KUBE_VERSIONS_CSV "${ALL_CTXS[@]}"

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
		echo "# ISTIO_VERSION=${ISTIO_VERSION}"
		echo "# KUBE_VERSIONS=${KUBE_VERSIONS_CSV}"
		echo "# ISTIOD_REPLICAS=${ISTIOD_REPLICAS_CSV}"
		echo "# SOURCE_CTX=${SOURCE_CTX}"
		echo "# REMOTES=${REMOTES[*]:-none}"
		echo "# MESH_SIZE=${MESH_SIZE}"
		echo "# ITERATIONS=${ITERATIONS}"
		echo "# POLL_INTERVAL_S=${POLL_INTERVAL_S}"
		echo "# TIMEOUT_SEC=${TIMEOUT_SEC}"
		echo "# SETTLE_SEC=${SETTLE_SEC}"
		echo "# DATE=$(date -u -Iseconds)"
	} > "$TSV_FILE"
	# Columns (tab-separated). Old p1/p2/p3 cols preserved for back-compat with
	# pre-branch readers. New columns are appended. p2_dirty (B1) is a 0/1 flag
	# indicating the EDS push delta was not matched by a pilot_services delta
	# (i.e. EDS bumped from unrelated endpoint churn). restarted is 0/1/unknown.
	echo -e "run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms" >> "$TSV_FILE"
fi

PF_PIDS=()
POLL_PIDS=()
TMPDIR_RUN=$(mktemp -d)

# Per-context istiod pod-port blocks (tests/lib/fanout.sh). The source context is
# fanout ctx_index 0; remote i is ctx_index i+1 (collision-free port blocks).
# Remote port lists are stored as newline strings keyed by remote index (bash
# has no array-of-arrays); load_rmt_istiod_ports re-expands them.
SRC_ISTIOD_PORTS=()
declare -A RMT_ISTIOD_PORTS_STR=()

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
	local pid
	for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
	PF_PIDS=()
	open_all_istiod_fanouts
}

start_envoy_port_forward() {
	local ctx="$1" local_port="$2"
	"${KUBECTL[@]}" --context="$ctx" -n "$NS" port-forward deploy/propagation-watcher "$local_port":15000 >/dev/null 2>&1 &
	PF_PIDS+=($!)
	local attempts=0
	while ! curl -s -o /dev/null "http://localhost:$local_port/clusters" 2>/dev/null; do
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
# B1: a nonzero EDS delta alone is ambiguous — unrelated endpoint churn from
# other workloads on the remote cluster also bumps the counter. We additionally
# require pilot_services to have increased by >= 1 to call P2 "clean".
# When EDS bumped but services did NOT increase, we still record the timestamp
# (so legacy p2_ms remains comparable) but flag the iteration via a separate
# result line "DIRTY" so the caller can set p2_dirty=1 in the TSV.
# Fanned out across the remote's istiod pods: eds_count + pushes_total SUM across
# pods, pilot_services is replica-INVARIANT (max), restart via proc_start_sig.
poll_p2_remote_eds_push() {
	local polldir="$1" t0="$2" baseline_eds="$3" result_file="$4" restart_baseline="$5"
	local baseline_services="$6" dirty_file="$7"
	shift 7
	local -a ports=("$@")
	local deadline_ms=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	local ever_complete=0
	mkdir -p "$polldir"
	# Initialize dirty file to "0" (clean) until we see a dirty hit.
	echo "0" > "$dirty_file"
	while true; do
		local now_ms=$(now_ms)
		if ((now_ms > deadline_ms)); then
			if (( ever_complete )); then echo "TIMEOUT" > "$result_file"; else echo "INCOMPLETE" > "$result_file"; fi
			return
		fi
		# One fanned-out scrape+aggregate per tick (pilot_xds/eds summed across
		# pods, pilot_services invariant). Returns the kv/hist aggregate files.
		# Skip the detection test on an incomplete scrape (a missing pod undercounts
		# the summed eds_count / pilot_services delta).
		fanout_scrape_aggregate "$polldir" "tick" pilot_proxy_convergence_time "${ports[@]}" >/dev/null
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
		local cur_eds cur_svc
		cur_eds=$(kv_get "$polldir/tick-kv" eds_count)
		cur_svc=$(kv_get "$polldir/tick-kv" pilot_services)
		[[ -z "$cur_eds" ]] && cur_eds=0
		[[ -z "$cur_svc" ]] && cur_svc=0
		# Counter could appear to "decrease" mid restart/deploy; treat as not-yet.
		if (( cur_eds > baseline_eds )); then
			# B1: services-gauge delta must be >=1 to call this clean. pilot_services
			# is mesh-global (invariant across replicas), so the delta is mesh-wide.
			local svc_delta=$(( cur_svc - baseline_services ))
			if (( svc_delta < 1 )); then
				echo "1" > "$dirty_file"
			fi
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
		local now_ms=$(now_ms)
		((now_ms > deadline_ms)) && { echo "TIMEOUT" > "$result_file"; return; }
		local clusters
		clusters=$(curl -fsS --max-time "$METRICS_TIMEOUT" "http://localhost:$envoy_port/clusters" 2>/dev/null) || { sleep "$interval"; continue; }
		if echo "$clusters" | grep -q "propagation-canary.*health_flags::healthy"; then
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
		local now_ms=$(now_ms)
		if ((now_ms > deadline_ms)); then
			# If we never once got a complete fanned-out scrape, the window is
			# untrustworthy — report INCOMPLETE rather than a plain TIMEOUT.
			if (( ever_complete )); then echo "TIMEOUT" > "$result_file"; else echo "INCOMPLETE" > "$result_file"; fi
			rm -f "$delta_file"
			return
		fi
		# One fanned-out scrape+aggregate per tick -> merged hist + kv. Skip the
		# convergence test on an incomplete scrape (a missing pod undercounts the
		# merged _count and would let P1 "converge" against a partial mesh).
		fanout_scrape_aggregate "$polldir" "tick" pilot_proxy_convergence_time "${ports[@]}" >/dev/null
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
	local deadline=$(( $(date +%s) + TIMEOUT_SEC ))
	while (($(date +%s) <= deadline)); do
		local data
		data=$(curl -fsS --max-time "$METRICS_TIMEOUT" "http://localhost:$port/clusters" 2>/dev/null) || { sleep "$POLL_INTERVAL_S"; continue; }
		# O1: the canary Service persists across iterations (we flip a label, not
		# delete the Service), so the propagation-canary CLUSTER entry stays in
		# /clusters even after drain. Drained == no HEALTHY endpoint for it (the
		# exact inverse of P3's poll_p3_sidecar_endpoints detection), not the
		# cluster name disappearing.
		echo "$data" | grep -q "propagation-canary.*health_flags::healthy" || return 0
		sleep "$POLL_INTERVAL_S"
	done
	return 1
}

echo "=== Endpoint propagation probe ==="
echo "Run: $RUN_ID  Harness: $HARNESS_SHA  Istio: $ISTIO_VERSION"
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
	# pods/rpods are required out-array args of fanout_open; we only consume the
	# port arrays here (the podset is recorded per-scrape), so mark them used.
	# shellcheck disable=SC2034
	local pods=()
	SRC_ISTIOD_PORTS=()
	fanout_open "$SOURCE_CTX" 0 PF_PIDS SRC_ISTIOD_PORTS pods "${KUBECTL[@]}"
	local i rp
	# shellcheck disable=SC2034
	local rpods
	for i in "${!REMOTES[@]}"; do
		rp=()
		# shellcheck disable=SC2034  # required out-arg of fanout_open; podset recorded per-scrape
		rpods=()
		fanout_open "${REMOTES[i]}" $(( i + 1 )) PF_PIDS rp rpods "${KUBECTL[@]}"
		RMT_ISTIOD_PORTS_STR["$i"]="$(IFS=$'\n'; echo "${rp[*]}")"
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

P1_SUM=0; P1_COUNT=0; P1_MIN=""; P1_MAX=""
P2_SUM=0; P2_COUNT=0; P2_MIN=""; P2_MAX=""
P3_SUM=0; P3_COUNT=0; P3_MIN=""; P3_MAX=""

for ((iter = 1; iter <= ITERATIONS; iter++)); do
	echo ""
	echo "--- Iteration $iter/$ITERATIONS ---"

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
	SCRAPE_SKEW_HIGH=0
	if (( SCRAPE_SKEW_MS > FANOUT_MAX_SKEW_MS )); then
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
	BACKER_POD="$("${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" get pods \
		-l app=propagation-canary --field-selector=status.phase=Running \
		-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
	[[ -n "$BACKER_POD" ]] || die "no Running pre-warmed backer pod on $SOURCE_CTX (run 001-setup first)"
	# Guard: the backer must be Ready before t0 (a label flip onto a not-yet-Ready
	# pod would re-introduce boot latency into P3).
	"${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" wait "pod/${BACKER_POD}" \
		--for=condition=Ready --timeout="${TIMEOUT_SEC}s" >/dev/null 2>&1 \
		|| die "backer pod $BACKER_POD on $SOURCE_CTX not Ready before t0"

	T0=$(now_ns)
	echo "  Flipping backer active label on $SOURCE_CTX (pod $BACKER_POD)..."
	# O1: config-only mutation at t0 — stamp the active-flip label onto the running
	# backer pod (PL5 server-side apply via kubectl label). The canary Service
	# already selects on this label, so its endpoint appears immediately; P1/P2/P3
	# now share a single T0 measuring pure xDS/EDS propagation, not pod boot.
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
	P2_DIRTY_FILES=()
	for i in "${!REMOTES[@]}"; do
		p2f="$TMPDIR_RUN/p2_${iter}_${i}"
		p3f="$TMPDIR_RUN/p3_${iter}_${i}"
		p2dirtyf="$TMPDIR_RUN/p2dirty_${iter}_${i}"
		: > "$p2f"
		: > "$p3f"
		: > "$p2dirtyf"
		P2_FILES+=("$p2f")
		P3_FILES+=("$p3f")
		P2_DIRTY_FILES+=("$p2dirtyf")
		baseline_eds=$(kv_get "$BASELINE_DIR/remote-${i}-kv" eds_count)
		baseline_svc=$(kv_get "$BASELINE_DIR/remote-${i}-kv" pilot_services)
		remote_start=$(kv_get "$BASELINE_DIR/remote-${i}-kv" proc_start_sig)
		[[ -z "$baseline_eds" ]] && baseline_eds=0
		[[ -z "$baseline_svc" ]] && baseline_svc=0
		_rip=()  # populated by load_rmt_istiod_ports via nameref
		load_rmt_istiod_ports "$i" _rip
		poll_p2_remote_eds_push "$TMPDIR_RUN/p2poll-${iter}-${i}" "$T0" \
			"$baseline_eds" "$p2f" "$remote_start" \
			"$baseline_svc" "$p2dirtyf" \
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

	if [[ "$p1_ms" =~ ^[0-9]+$ ]]; then
		P1_SUM=$((P1_SUM + p1_ms))
		P1_COUNT=$((P1_COUNT + 1))
		[[ -z "$P1_MIN" || "$p1_ms" -lt "$P1_MIN" ]] && P1_MIN="$p1_ms"
		[[ -z "$P1_MAX" || "$p1_ms" -gt "$P1_MAX" ]] && P1_MAX="$p1_ms"
	fi

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
		if ! wait_sidecar_endpoint_removed "$SOURCE_ENVOY_PF_PORT"; then
			echo "  Warning: timeout waiting for $SOURCE_CTX sidecar endpoint removal"
			drain_timeout="1"
		fi
		for i in "${!REMOTES[@]}"; do
			if ! wait_sidecar_endpoint_removed $(( BASE_ENVOY_PF_PORT + i )); then
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
		if ((WRITE_TSV)); then
			# F1: p1_sample_count is "got/attempted" (delta-_count first, proxy_count second).
			echo -e "${RUN_ID}\t${MESH_SIZE}\t${iter}\t${SOURCE_CTX}\tN/A\t${T0}\t${p1_ms}\tN/A\tN/A\t${status}\t${p1_conv_p50}\t${p1_conv_p99}\t${p1_sample_count}/${SOURCE_PROXY_COUNT}\t${SOURCE_PROXY_COUNT}\t${p1_overflow}\t${restarted}\t0\t${WINDOW_MS}\t${SCRAPE_SKEW_MS}" >> "$TSV_FILE"
		fi
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
			p2_dirty="0"
			[[ -s "${P2_DIRTY_FILES[i]}" ]] && p2_dirty=$(<"${P2_DIRTY_FILES[i]}")
			[[ -z "$p2_dirty" ]] && p2_dirty="0"

			echo "  P2 (remote istiod ${REMOTES[i]}, EDS push): ${p2_ms}ms  dirty=${p2_dirty}"
			echo "  P3 (remote sidecar ${REMOTES[i]}):          ${p3_ms}ms"

			if [[ "$p2_ms" =~ ^[0-9]+$ ]]; then
				P2_SUM=$((P2_SUM + p2_ms))
				P2_COUNT=$((P2_COUNT + 1))
				[[ -z "$P2_MIN" || "$p2_ms" -lt "$P2_MIN" ]] && P2_MIN="$p2_ms"
				[[ -z "$P2_MAX" || "$p2_ms" -gt "$P2_MAX" ]] && P2_MAX="$p2_ms"
			fi
			if [[ "$p3_ms" =~ ^[0-9]+$ ]]; then
				P3_SUM=$((P3_SUM + p3_ms))
				P3_COUNT=$((P3_COUNT + 1))
				[[ -z "$P3_MIN" || "$p3_ms" -lt "$P3_MIN" ]] && P3_MIN="$p3_ms"
				[[ -z "$P3_MAX" || "$p3_ms" -gt "$P3_MAX" ]] && P3_MAX="$p3_ms"
			fi

			# A P2 poll scrape that never completed cleanly also taints the remote row.
			p2_incomplete="$row_incomplete"
			[[ -s "${P2_FILES[i]}" && "$(<"${P2_FILES[i]}")" == "INCOMPLETE" ]] && p2_incomplete=1
			status=$(status_for_row "$p1_ms" "$p2_ms" "$p3_ms" "$p2_restarted" "$drain_timeout" "$p2_incomplete")

			# PL13: counter deltas are N/A on restart or unknown.
			p2_out="$p2_ms"
			if [[ "$p2_restarted" == "1" || "$p2_restarted" == "unknown" ]]; then
				p2_out="N/A"
			fi

			if ((WRITE_TSV)); then
				# Trailing columns: p1_conv_p50, p1_conv_p99, p1_sample_count (got/attempted),
				# p1_proxy_count, p1_overflow, restarted, p2_dirty, window_ms, scrape_skew_ms.
				echo -e "${RUN_ID}\t${MESH_SIZE}\t${iter}\t${SOURCE_CTX}\t${REMOTES[i]}\t${T0}\t${p1_ms}\t${p2_out}\t${p3_ms}\t${status}\t${p1_conv_p50}\t${p1_conv_p99}\t${p1_sample_count}/${SOURCE_PROXY_COUNT}\t${SOURCE_PROXY_COUNT}\t${p1_overflow}\t${p2_restarted}\t${p2_dirty}\t${WINDOW_MS}\t${SCRAPE_SKEW_MS}" >> "$TSV_FILE"
			fi
		done
	fi
done

echo ""
if ((WRITE_TSV)); then
	echo "=== Results written to $TSV_FILE ==="
fi
echo ""
echo "Summary:"
if ((P1_COUNT > 0)); then
	printf "  P1 local xDS push:     n=%d min=%dms max=%dms avg=%dms\n" "$P1_COUNT" "$P1_MIN" "$P1_MAX" "$((P1_SUM / P1_COUNT))"
fi
if ((P2_COUNT > 0)); then
	printf "  P2 remote istiod EDS:  n=%d min=%dms max=%dms avg=%dms\n" "$P2_COUNT" "$P2_MIN" "$P2_MAX" "$((P2_SUM / P2_COUNT))"
fi
if ((P3_COUNT > 0)); then
	printf "  P3 remote sidecar:     n=%d min=%dms max=%dms avg=%dms\n" "$P3_COUNT" "$P3_MIN" "$P3_MAX" "$((P3_SUM / P3_COUNT))"
fi
if ((P1_COUNT == 0)); then
	echo "  No successful measurements."
fi

MD_FILE="${OUTPUT_DIR}/endpoint-${RUN_ID}.md"
{
	echo "# Endpoint Propagation Latency"
	echo ""
	echo "| Field | Value |"
	echo "|-------|-------|"
	echo "| Run ID | \`${RUN_ID}\` |"
	echo "| Harness SHA | \`${HARNESS_SHA}\` |"
	echo "| Istio version | ${ISTIO_VERSION} |"
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
	echo "- **P2** (remote discovery): \`pilot_xds_pushes{type=\"eds\"}\` counter delta on each remote istiod;"
	echo "  flagged as \`p2_dirty=1\` if not accompanied by a \`pilot_services\` gauge delta."
	echo "- **P3** (remote sidecar): watcher Envoy \`/clusters\` polled at >= 1 Hz for a"
	echo "  healthy canary endpoint. t0 is a config-only active-label flip onto a"
	echo "  pre-warmed backer pod, so P3 excludes pod boot / image pull / sidecar startup."
	echo ""
	echo "## Summary"
	echo ""
	if ((P1_COUNT > 0 || P2_COUNT > 0 || P3_COUNT > 0)); then
		echo "| Phase | n | min (ms) | max (ms) | avg (ms) |"
		echo "|-------|---|----------|----------|----------|"
		if ((P1_COUNT > 0)); then
			echo "| P1 local xDS push | ${P1_COUNT} | ${P1_MIN} | ${P1_MAX} | $((P1_SUM / P1_COUNT)) |"
		fi
		if ((P2_COUNT > 0)); then
			echo "| P2 remote istiod EDS push | ${P2_COUNT} | ${P2_MIN} | ${P2_MAX} | $((P2_SUM / P2_COUNT)) |"
		fi
		if ((P3_COUNT > 0)); then
			echo "| P3 remote sidecar | ${P3_COUNT} | ${P3_MIN} | ${P3_MAX} | $((P3_SUM / P3_COUNT)) |"
		fi
	else
		echo "No successful measurements."
	fi
	if ((WRITE_TSV)); then
		echo ""
		echo "## Raw Data"
		echo ""
		echo "TSV: [\`$(basename "$TSV_FILE")\`]($(basename "$TSV_FILE"))"
	fi
} > "$MD_FILE"
echo "Summary written to $MD_FILE"

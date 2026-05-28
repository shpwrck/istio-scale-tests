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
# Usage:
#   ./tests/propagation/002-run-endpoint-probe.sh --source-context CTX [--remote-contexts CSV] [options]
#
# Examples:
#   # Measure 2-cluster propagation, 10 iterations:
#   ./tests/propagation/002-run-endpoint-probe.sh --source-context rosa-001 --remote-contexts rosa-002
#
#   # Measure single-cluster baseline (local xDS push only):
#   ./tests/propagation/002-run-endpoint-probe.sh --source-context rosa-001 --mesh-size 1
#
#   # 3-cluster sweep, 5 iterations:
#   ./tests/propagation/002-run-endpoint-probe.sh --source-context rosa-001 \
#     --remote-contexts rosa-002,rosa-003 --mesh-size 3 --iterations 5
# ci-dry-run: --source-context ci-dummy
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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
BASE_PF_PORT=15014
BASE_ENVOY_PF_PORT=15100
CHART_DIR="${ROOT}/tests/propagation/chart"

die() { echo "error: $*" >&2; exit 1; }

# Portable nanosecond / millisecond timestamps. macOS BSD `date` does not
# support `%N`, so we detect the best available source once and cache it.
NOW_NS_IMPL=""
_detect_now_ns() {
	[[ -n "$NOW_NS_IMPL" ]] && return
	if [[ "$(date -u +%s%N 2>/dev/null)" =~ ^[0-9]+$ ]]; then
		NOW_NS_IMPL="date"
	elif command -v gdate >/dev/null 2>&1 \
		&& [[ "$(gdate -u +%s%N 2>/dev/null)" =~ ^[0-9]+$ ]]; then
		NOW_NS_IMPL="gdate"
	elif command -v python3 >/dev/null 2>&1; then
		NOW_NS_IMPL="python3"
	elif command -v perl >/dev/null 2>&1; then
		NOW_NS_IMPL="perl"
	else
		die "no nanosecond-resolution time source: install GNU coreutils (gdate), python3, or perl"
	fi
}
now_ns() {
	_detect_now_ns
	case "$NOW_NS_IMPL" in
	date)    date -u +%s%N ;;
	gdate)   gdate -u +%s%N ;;
	python3) python3 -c 'import time; print(int(time.time()*1e9))' ;;
	perl)    perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time()*1e9' ;;
	esac
}
now_ms() {
	_detect_now_ns
	case "$NOW_NS_IMPL" in
	date)    echo $(( $(date -u +%s%N) / 1000000 )) ;;
	gdate)   gdate -u +%s%3N ;;
	python3) python3 -c 'import time; print(int(time.time()*1000))' ;;
	perl)    perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time()*1000' ;;
	esac
}

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
  - istiod must be a single replica per cluster (probe dies otherwise — svc/istiod
    port-forwards load-balance, so multi-replica gauges desync between snapshots).
  - istiod restart detection (process_start_time_seconds). When restart
    detected mid-iteration, counter deltas and histogram quantiles emit N/A.
    If process_start_time_seconds is missing, restarted=unknown (treated as
    suspect by 005).
  - Negative histogram bucket deltas emit N/A.
  - +Inf bucket delta is tracked as "overflow" (sample landed above bucket range).
  - Drain-wait timeouts after canary cleanup tag the row with status=DRAIN_TIMEOUT.
  - Server-side apply (--server-side --force-conflicts) on the canary.
  - Concurrent multi-context scrapes; per-iteration scrape_skew_ms is
    max(ts)-min(ts) across context scrape timestamps.

Environment:
  SETUP_CONTEXTS, PROPAGATION_TEST_NAMESPACE, PROPAGATION_POLL_INTERVAL_MS,
  PROPAGATION_TIMEOUT_SEC, PROPAGATION_ITERATIONS, PROPAGATION_SETTLE_SEC,
  PROPAGATION_METRICS_TIMEOUT (curl --max-time for /metrics; default 5s — bump
  for large meshes where /metrics may take longer to render).
EOF
}

split_csv() {
	local csv="$1"
	local -n _out="$2"
	_out=()
	local x
	IFS=',' read -ra _raw <<<"$csv"
	for x in "${_raw[@]}"; do
		x="${x#"${x%%[![:space:]]*}"}"
		x="${x%"${x##*[![:space:]]}"}"
		[[ -n "$x" ]] && _out+=("$x")
	done
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
	echo "=== Dry-run: canary manifests for source context $SOURCE_CTX ==="
	helm template propagation-test "$CHART_DIR" \
		--set clusterName="$SOURCE_CTX" \
		--set namespace="$NS" \
		--set canary.enabled=true \
		--set canary.runId="$RUN_ID" \
		--show-only templates/canary-deployment.yaml \
		--show-only templates/canary-service.yaml
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
declare -A PF_PORT_PID=()
POLL_PIDS=()
TMPDIR_RUN=$(mktemp -d)

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

start_port_forward() {
	local ctx="$1" local_port="$2"
	"${KUBECTL[@]}" --context="$ctx" -n istio-system port-forward svc/istiod "$local_port":15014 >/dev/null 2>&1 &
	PF_PIDS+=($!)
	PF_PORT_PID["$local_port"]=$!
	local attempts=0
	while ! curl -s -o /dev/null --max-time "$METRICS_TIMEOUT" "http://localhost:$local_port/metrics" 2>/dev/null; do
		attempts=$((attempts + 1))
		((attempts > 30)) && die "port-forward to istiod on $ctx (port $local_port) failed to connect"
		sleep 0.5
	done
}

# H1: per-iteration liveness check on a port-forward. If the metrics endpoint
# isn't responsive, kill the existing PF and restart it.
restart_port_forward_if_dead() {
	local ctx="$1" local_port="$2"
	if curl -s -o /dev/null --max-time "$METRICS_TIMEOUT" "http://localhost:$local_port/metrics" 2>/dev/null; then
		return 0
	fi
	echo "  Port-forward to istiod on $ctx (port $local_port) unresponsive — restarting..." >&2
	local old_pid="${PF_PORT_PID[$local_port]:-}"
	if [[ -n "$old_pid" ]]; then
		kill "$old_pid" 2>/dev/null || true
		wait "$old_pid" 2>/dev/null || true
	fi
	start_port_forward "$ctx" "$local_port"
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
#
# scrape_metrics PORT VAR
#   Curls http://localhost:PORT/metrics and stores text in VAR.
#   Timeout is controlled by $METRICS_TIMEOUT (env PROPAGATION_METRICS_TIMEOUT).
scrape_metrics() {
	local port="$1"
	local __varname="$2"
	local __tmp
	if ! __tmp=$(curl -fsS --max-time "$METRICS_TIMEOUT" "http://localhost:$port/metrics" 2>/dev/null); then
		printf -v "$__varname" '%s' ""
		return 1
	fi
	printf -v "$__varname" '%s' "$__tmp"
	return 0
}

# scrape_metrics_to_file PORT FILE
#   Like scrape_metrics, but streams to FILE so subsequent extractors can read
#   it via file reads instead of repeatedly re-piping a multi-MB string through
#   subshells (D1: removes harness self-noise at 100k-service scale).
scrape_metrics_to_file() {
	local port="$1" outfile="$2"
	if ! curl -fsS --max-time "$METRICS_TIMEOUT" -o "$outfile" "http://localhost:$port/metrics" 2>/dev/null; then
		: > "$outfile"
		return 1
	fi
	return 0
}

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
poll_p2_remote_eds_push() {
	local port="$1" t0="$2" baseline_eds="$3" result_file="$4" restart_baseline="$5"
	local baseline_services="$6" dirty_file="$7"
	local deadline_ms=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	local tmp_scrape tmp_hist tmp_kv
	tmp_scrape=$(mktemp "$TMPDIR_RUN/tmp.XXXXXX")
	tmp_hist=$(mktemp "$TMPDIR_RUN/tmp.XXXXXX")
	tmp_kv=$(mktemp "$TMPDIR_RUN/tmp.XXXXXX")
	# Initialize dirty file to "0" (clean) until we see a dirty hit.
	echo "0" > "$dirty_file"
	while true; do
		local now_ms=$(now_ms)
		if ((now_ms > deadline_ms)); then
			echo "TIMEOUT" > "$result_file"
			rm -f "$tmp_scrape" "$tmp_hist" "$tmp_kv"
			return
		fi
		if ! scrape_metrics_to_file "$port" "$tmp_scrape"; then
			sleep "$POLL_INTERVAL_S"
			continue
		fi
		# One awk pass: extract everything from this scrape.
		extract_all_from_file "$tmp_scrape" "pilot_proxy_convergence_time" "$tmp_hist" "$tmp_kv"
		local now_start
		now_start=$(kv_get "$tmp_kv" process_start)
		if [[ "$restart_baseline" != "unknown" && "$now_start" != "unknown" && "$now_start" != "$restart_baseline" ]]; then
			echo "RESTART" > "$result_file"
			rm -f "$tmp_scrape" "$tmp_hist" "$tmp_kv"
			return
		fi
		local cur_eds cur_svc
		cur_eds=$(kv_get "$tmp_kv" eds_count)
		cur_svc=$(kv_get "$tmp_kv" pilot_services)
		[[ -z "$cur_eds" ]] && cur_eds=0
		[[ -z "$cur_svc" ]] && cur_svc=0
		# Counter could appear to "decrease" mid restart/deploy; treat as not-yet.
		if (( cur_eds > baseline_eds )); then
			# B1: services-gauge delta must be exactly >=1 to call this clean.
			local svc_delta=$(( cur_svc - baseline_services ))
			if (( svc_delta < 1 )); then
				echo "1" > "$dirty_file"
			fi
			now_ns > "$result_file"
			rm -f "$tmp_scrape" "$tmp_hist" "$tmp_kv"
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

# --- P1 polling: histogram convergence on source istiod --------------------
# Converge when delta _count >= proxy_count (each connected proxy has
# received at least one push).
poll_p1_local_sync_histogram() {
	local port="$1" t0="$2" baseline_hist="$3" \
		result_file="$4" proxy_count="$5" restart_baseline="$6" final_snapshot_file="$7"
	local deadline_ms=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	local tmp_scrape cur_snapshot tmp_kv delta_file
	tmp_scrape=$(mktemp "$TMPDIR_RUN/tmp.XXXXXX")
	cur_snapshot=$(mktemp "$TMPDIR_RUN/tmp.XXXXXX")
	tmp_kv=$(mktemp "$TMPDIR_RUN/tmp.XXXXXX")
	delta_file=$(mktemp "$TMPDIR_RUN/tmp.XXXXXX")
	while true; do
		local now_ms=$(now_ms)
		if ((now_ms > deadline_ms)); then
			echo "TIMEOUT" > "$result_file"
			rm -f "$tmp_scrape" "$cur_snapshot" "$tmp_kv" "$delta_file"
			return
		fi
		if ! scrape_metrics_to_file "$port" "$tmp_scrape"; then
			sleep "$POLL_INTERVAL_S"
			continue
		fi
		extract_all_from_file "$tmp_scrape" "pilot_proxy_convergence_time" "$cur_snapshot" "$tmp_kv"
		local now_start
		now_start=$(kv_get "$tmp_kv" process_start)
		if [[ "$restart_baseline" != "unknown" && "$now_start" != "unknown" && "$now_start" != "$restart_baseline" ]]; then
			echo "RESTART" > "$result_file"
			rm -f "$tmp_scrape" "$cur_snapshot" "$tmp_kv" "$delta_file"
			return
		fi
		delta_histogram "$baseline_hist" "$cur_snapshot" "$delta_file"
		local d_count
		d_count=$(awk -F'\t' '$1=="_count" {print $2; exit}' "$delta_file")
		[[ -z "$d_count" ]] && d_count=0
		if (( d_count >= proxy_count )); then
			now_ns > "$result_file"
			cp "$cur_snapshot" "$final_snapshot_file"
			rm -f "$tmp_scrape" "$cur_snapshot" "$tmp_kv" "$delta_file"
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
		TIMEOUT) echo "TIMEOUT"; return ;;
		RESTART) echo "N/A"; return ;;
		"")      echo "N/A"; return ;;
	esac
	echo $(( (ts - t0) / 1000000 ))
}

wait_sidecar_endpoint_removed() {
	local port="$1"
	local deadline=$(( $(date +%s) + TIMEOUT_SEC ))
	while (($(date +%s) <= deadline)); do
		local data
		data=$(curl -fsS --max-time "$METRICS_TIMEOUT" "http://localhost:$port/clusters" 2>/dev/null) || { sleep "$POLL_INTERVAL_S"; continue; }
		echo "$data" | grep -q "propagation-canary" || return 0
		sleep "$POLL_INTERVAL_S"
	done
	return 1
}

echo "=== Endpoint propagation probe ==="
echo "Run: $RUN_ID  Harness: $HARNESS_SHA  Istio: $ISTIO_VERSION"
echo "Source: $SOURCE_CTX | Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
echo "Iterations: $ITERATIONS | Timeout: ${TIMEOUT_SEC}s | Poll: ${POLL_INTERVAL_S}s | Settle: ${SETTLE_SEC}s"
echo ""

# A3: precondition — istiod must be a single replica per cluster. Scraping
# svc/istiod load-balances to one random replica; baseline + current snapshots
# may land on different replicas, in which case the pilot_xds gauge and the
# histogram counts represent only the proxies/pushes seen by that one replica.
# At multi-replica scale the threshold computation passes at ~50% real
# convergence. The cheap escape hatch is to require exactly one istiod pod and
# die early if not. A per-pod port-forward fanout is the correct fix; pursue it
# in a future change if multi-replica istiod is required.
check_single_replica_istiod() {
	local ctx
	for ctx in "$SOURCE_CTX" "${REMOTES[@]}"; do
		local replicas
		replicas=$("${KUBECTL[@]}" --context="$ctx" -n istio-system get pods -l app=istiod \
			-o name --no-headers 2>/dev/null | wc -l | tr -d ' ')
		if [[ -z "$replicas" || "$replicas" == "0" ]]; then
			die "context $ctx: no istiod pods found (expected exactly 1 in istio-system)"
		fi
		if (( replicas != 1 )); then
			die "context $ctx: found $replicas istiod replicas; this probe currently requires exactly 1 \
(svc/istiod port-forwards load-balance, so per-replica gauges desync). \
See A3 in tests/propagation/README.md."
		fi
	done
}
check_single_replica_istiod
echo "istiod single-replica precondition OK."

echo "Starting port-forwards..."
start_port_forward "$SOURCE_CTX" "$BASE_PF_PORT"
SOURCE_ENVOY_PF_PORT=$(( BASE_ENVOY_PF_PORT + ${#REMOTES[@]} ))
start_envoy_port_forward "$SOURCE_CTX" "$SOURCE_ENVOY_PF_PORT"
for i in "${!REMOTES[@]}"; do
	start_port_forward "${REMOTES[i]}" $(( BASE_PF_PORT + i + 1 ))
	start_envoy_port_forward "${REMOTES[i]}" $(( BASE_ENVOY_PF_PORT + i ))
done
echo "Port-forwards ready."

P1_SUM=0; P1_COUNT=0; P1_MIN=""; P1_MAX=""
P2_SUM=0; P2_COUNT=0; P2_MIN=""; P2_MAX=""
P3_SUM=0; P3_COUNT=0; P3_MIN=""; P3_MAX=""

for ((iter = 1; iter <= ITERATIONS; iter++)); do
	echo ""
	echo "--- Iteration $iter/$ITERATIONS ---"

	ITER_RUN_ID="${RUN_ID}-${iter}"

	# H1: port-forward liveness check before each iteration. PFs can die
	# silently between iterations (kubectl PF closes idle conns, networking
	# blips); kicking them now avoids attributing a network hiccup to istiod.
	restart_port_forward_if_dead "$SOURCE_CTX" "$BASE_PF_PORT"
	for i in "${!REMOTES[@]}"; do
		restart_port_forward_if_dead "${REMOTES[i]}" $(( BASE_PF_PORT + i + 1 ))
	done

	# Concurrent baseline scrape across all istiods. Records per-context skew.
	echo "  Scraping baselines..."
	BASELINE_DIR="$TMPDIR_RUN/baseline-${iter}"
	mkdir -p "$BASELINE_DIR"
	BASELINE_PIDS=()
	(
		if scrape_metrics_to_file "$BASE_PF_PORT" "$BASELINE_DIR/source-scrape"; then
			extract_all_from_file \
				"$BASELINE_DIR/source-scrape" "pilot_proxy_convergence_time" \
				"$BASELINE_DIR/source-hist" "$BASELINE_DIR/source-kv"
		else
			: > "$BASELINE_DIR/source-hist"
			printf 'pilot_xds=N/A\npilot_services=0\neds_count=0\npushes_total=0\nprocess_start=unknown\n' \
				> "$BASELINE_DIR/source-kv"
		fi
		now_ns > "$BASELINE_DIR/source-ts"
	) &
	BASELINE_PIDS+=($!)
	for i in "${!REMOTES[@]}"; do
		port=$(( BASE_PF_PORT + i + 1 ))
		idx="$i"
		(
			if scrape_metrics_to_file "$port" "$BASELINE_DIR/remote-${idx}-scrape"; then
				extract_all_from_file \
					"$BASELINE_DIR/remote-${idx}-scrape" "pilot_proxy_convergence_time" \
					"$BASELINE_DIR/remote-${idx}-hist" "$BASELINE_DIR/remote-${idx}-kv"
			else
				: > "$BASELINE_DIR/remote-${idx}-hist"
				printf 'pilot_xds=N/A\npilot_services=0\neds_count=0\npushes_total=0\nprocess_start=unknown\n' \
					> "$BASELINE_DIR/remote-${idx}-kv"
			fi
			now_ns > "$BASELINE_DIR/remote-${idx}-ts"
		) &
		BASELINE_PIDS+=($!)
	done
	for pid in "${BASELINE_PIDS[@]}"; do
		wait "$pid" 2>/dev/null || true
	done
	# H3: scrape_skew_ms is max(ts)-min(ts) across the per-context timestamps,
	# not total batch duration (which includes scheduling overhead).
	skew_files=("$BASELINE_DIR/source-ts")
	for f in "$BASELINE_DIR"/remote-*-ts; do
		[[ -e "$f" ]] && skew_files+=("$f")
	done
	SCRAPE_SKEW_MS=$(awk '
		BEGIN { min = ""; max = "" }
		{ v = $1 + 0; if (min == "" || v < min) min = v; if (max == "" || v > max) max = v }
		END { if (min == "") print 0; else printf "%d\n", (max - min) / 1000000 }
	' "${skew_files[@]}" 2>/dev/null)
	[[ -z "$SCRAPE_SKEW_MS" ]] && SCRAPE_SKEW_MS=0

	# A2: parse SOURCE_PROXY_COUNT and SOURCE_START from the same baseline scrape.
	SOURCE_START=$(kv_get "$BASELINE_DIR/source-kv" process_start)
	SOURCE_PROXY_COUNT=$(normalize_proxy_count "$(kv_get "$BASELINE_DIR/source-kv" pilot_xds)")
	echo "  Source connected proxies: $SOURCE_PROXY_COUNT (scrape_skew=${SCRAPE_SKEW_MS}ms)"

	T0=$(now_ns)
	echo "  Deploying canary on $SOURCE_CTX..."
	helm template propagation-test "$CHART_DIR" \
		--set clusterName="$SOURCE_CTX" \
		--set namespace="$NS" \
		--set canary.enabled=true \
		--set canary.runId="$ITER_RUN_ID" \
		--show-only templates/canary-deployment.yaml \
		--show-only templates/canary-service.yaml \
		| "${KUBECTL[@]}" apply --context="$SOURCE_CTX" --server-side --force-conflicts -f - >/dev/null

	P1_FILE="$TMPDIR_RUN/p1-${iter}"
	P1_FINAL_SNAPSHOT="$TMPDIR_RUN/p1-final-${iter}"
	: > "$P1_FILE"
	poll_p1_local_sync_histogram \
		"$BASE_PF_PORT" "$T0" \
		"$BASELINE_DIR/source-hist" "$P1_FILE" \
		"$SOURCE_PROXY_COUNT" "$SOURCE_START" "$P1_FINAL_SNAPSHOT" &
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
		remote_start=$(kv_get "$BASELINE_DIR/remote-${i}-kv" process_start)
		[[ -z "$baseline_eds" ]] && baseline_eds=0
		[[ -z "$baseline_svc" ]] && baseline_svc=0
		poll_p2_remote_eds_push $(( BASE_PF_PORT + i + 1 )) "$T0" \
			"$baseline_eds" "$p2f" "$remote_start" \
			"$baseline_svc" "$p2dirtyf" &
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

	# Cleanup canary BEFORE drain-wait so we can report DRAIN_TIMEOUT correctly.
	echo "  Cleaning up canary..."
	"${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" delete deploy/propagation-canary svc/propagation-canary --ignore-not-found=true --wait=true >/dev/null

	# E1: track per-iteration drain timeout so we can flag the row with
	# status=DRAIN_TIMEOUT. Without this, the next iteration's baseline
	# includes an un-drained canary, contaminating the data silently.
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
		local p1="$1" p2="$2" p3="$3" rst="$4" drain="$5"
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
		echo "$s"
	}

	if [[ ${#REMOTES[@]} -eq 0 ]]; then
		status=$(status_for_row "$p1_ms" "N/A" "N/A" "$restarted" "$drain_timeout")
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
			# C2: if baseline or current process_start was missing AND we have
			# no explicit RESTART signal, propagate "unknown" instead of "0".
			remote_start=$(kv_get "$BASELINE_DIR/remote-${i}-kv" process_start)
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

			status=$(status_for_row "$p1_ms" "$p2_ms" "$p3_ms" "$p2_restarted" "$drain_timeout")

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
	echo "- **P3** (remote sidecar): watcher Envoy \`/clusters\` polled at >= 1 Hz."
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

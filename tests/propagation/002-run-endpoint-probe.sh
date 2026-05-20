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
#        until the delta _count meets the source-cluster proxy count (= every
#        connected proxy ACKed the resulting push). This avoids self-noise from
#        polling /debug/syncz, which serializes the full push context per
#        request and competes with the work being measured.
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
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

SOURCE_CTX=""
REMOTE_CONTEXTS_CSV=""
MESH_SIZE=""
ITERATIONS="${PROPAGATION_ITERATIONS}"
TIMEOUT_SEC="${PROPAGATION_TIMEOUT_SEC}"
POLL_INTERVAL_MS="${PROPAGATION_POLL_INTERVAL_MS}"
POLL_INTERVAL_S="0.$(printf '%03d' "${POLL_INTERVAL_MS}")"
SETTLE_SEC="${PROPAGATION_SETTLE_SEC:-5}"
OUTPUT_DIR="${ROOT}/tests/propagation/results"
DRY_RUN=0
WRITE_TSV=0
NS="${PROPAGATION_TEST_NAMESPACE}"
BASE_PF_PORT=15014
BASE_ENVOY_PF_PORT=15100
CHART_DIR="${ROOT}/tests/propagation/chart"

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --source-context CTX      Kube context for the source cluster (required).
  --remote-contexts CSV     Remote cluster contexts (comma-separated). Omit for single-cluster baseline.
  --mesh-size N             Metadata tag for TSV output (default: 1 + number of remotes).
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
                         Converged when delta _count >= connected proxy count.
                         Emits p1_ms (wall-clock to converged-count) plus
                         delta-window p50/p99 (p1_conv_p50_ms / p1_conv_p99_ms).
  P2 (remote discovery) — pilot_xds_pushes{type="eds"} counter delta on each
                          remote istiod. First nonzero delta = remote learned
                          the new endpoint and pushed EDS to its proxies.
  P3 (remote sidecar)   — watcher Envoy /clusters, rate-limited; the only
                          available data-plane-side signal without a custom
                          xDS client.

Robustness:
  - istiod restart detection (process_start_time_seconds). When restart
    detected mid-iteration, counter deltas and histogram quantiles emit N/A.
  - Negative histogram bucket deltas emit N/A.
  - +Inf bucket delta is tracked as "overflow" (sample landed above bucket range).
  - Server-side apply (--server-side --force-conflicts) on the canary.
  - Concurrent multi-context scrapes; per-iteration scrape_skew_ms is recorded.

Environment:
  SETUP_CONTEXTS, PROPAGATION_TEST_NAMESPACE, PROPAGATION_POLL_INTERVAL_MS,
  PROPAGATION_TIMEOUT_SEC, PROPAGATION_ITERATIONS, PROPAGATION_SETTLE_SEC.
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

RUN_ID="$(date +%Y%m%dT%H%M%S)-$$"
HARNESS_SHA="$(git -C "$ROOT" describe --always --dirty --abbrev=7 2>/dev/null || echo unknown)"

mkdir -p "$OUTPUT_DIR"
TSV_FILE="${OUTPUT_DIR}/endpoint-${RUN_ID}.tsv"

if ((DRY_RUN)); then
	echo "=== Dry-run: canary manifests for source context $SOURCE_CTX ==="
	helm template propagation-test "$CHART_DIR" \
		--set clusterName="$SOURCE_CTX" \
		--set namespace="$NS" \
		--set canary.enabled=true \
		--set canary.runId="$RUN_ID"
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
		echo "# DATE=$(date -Iseconds)"
	} > "$TSV_FILE"
	# Columns (tab-separated). Old p1/p2/p3 cols preserved for back-compat with
	# pre-branch readers. New columns are appended.
	echo -e "run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\twindow_ms\tscrape_skew_ms" >> "$TSV_FILE"
fi

PF_PIDS=()
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
	local attempts=0
	while ! curl -s -o /dev/null "http://localhost:$local_port/metrics" 2>/dev/null; do
		attempts=$((attempts + 1))
		((attempts > 30)) && die "port-forward to istiod on $ctx (port $local_port) failed to connect"
		sleep 0.5
	done
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
scrape_metrics() {
	local port="$1"
	local __varname="$2"
	local __tmp
	if ! __tmp=$(curl -fsS --max-time 5 "http://localhost:$port/metrics" 2>/dev/null); then
		printf -v "$__varname" '%s' ""
		return 1
	fi
	printf -v "$__varname" '%s' "$__tmp"
	return 0
}

# extract_gauge METRICS NAME
#   Sums values for every label permutation of NAME (PL12).
extract_gauge() {
	local metrics="$1" name="$2"
	echo "$metrics" | awk -v name="^${name}([{ ])" '
		!/^#/ && $0 ~ name {
			val = $NF + 0
			sum += val
		}
		END { if (NR==0) print "N/A"; else printf "%.0f\n", sum }
	'
}

# extract_counter METRICS NAME LABEL_FILTER
#   Sums every series matching NAME, optionally filtered by a substring
#   that must appear in the labels (e.g. 'type="eds"'). Echoes 0 if absent.
extract_counter() {
	local metrics="$1" name="$2" label_filter="${3:-}"
	echo "$metrics" | awk -v name="^${name}([{ ])" -v filt="$label_filter" '
		!/^#/ && $0 ~ name {
			if (filt == "" || index($0, filt) > 0) {
				sum += $NF + 0
			}
		}
		END { printf "%.0f\n", sum }
	'
}

# extract_process_start METRICS
#   Reads process_start_time_seconds and emits a deterministic value, or "unknown".
extract_process_start() {
	local metrics="$1"
	echo "$metrics" | awk '
		!/^#/ && /^process_start_time_seconds/ {
			printf "%.0f\n", $NF + 0
			found = 1
			exit
		}
		END { if (!found) print "unknown" }
	'
}

# extract_histogram_snapshot METRICS NAME OUTFILE
#   Captures pilot_proxy_convergence_time histogram into a sorted file with
#   one row per "le" bucket: "<le>\t<cumulative_count>" plus two trailing
#   lines "_sum\t<sum>" and "_count\t<count>". +Inf is the final bucket.
extract_histogram_snapshot() {
	local metrics="$1" name="$2" outfile="$3"
	echo "$metrics" | awk -v name="$name" '
		BEGIN { sum = ""; cnt = "" }
		!/^#/ {
			if (index($0, name "_bucket{") == 1) {
				line = $0
				sub(/.*le="/, "", line)
				sub(/".*/, "", line)
				le = line
				count = $NF + 0
				# Sum across permutations (label combinations) at the same le.
				bucket_counts[le] += count
				if (!(le in seen)) {
					seen[le] = 1
					bucket_order[++n_bk] = le
				}
			} else if (index($0, name "_sum") == 1 && /^[^{]/ ) {
				sum = $NF
			} else if (index($0, name "_count") == 1 && /^[^{]/ ) {
				cnt = $NF
			} else if (index($0, name "_sum{") == 1) {
				sum_total += $NF + 0
				sum_seen = 1
			} else if (index($0, name "_count{") == 1) {
				cnt_total += $NF + 0
				cnt_seen = 1
			}
		}
		END {
			# Prefer labeled aggregates if available, else scalar forms.
			if (sum_seen) sum = sum_total
			if (cnt_seen) cnt = cnt_total
			# Emit buckets in numeric order, +Inf last.
			# (We sort by treating +Inf as a sentinel.)
			for (i = 1; i <= n_bk; i++) {
				le = bucket_order[i]
				printf "%s\t%d\n", le, bucket_counts[le]
			}
			if (sum == "") sum = 0
			if (cnt == "") cnt = 0
			printf "_sum\t%s\n_count\t%s\n", sum, cnt
		}
	' > "$outfile"
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

# --- proxy count probe -------------------------------------------------------
# We use pilot_xds{} (connected proxies) summed across permutations. This is
# also the basis for P1's detection threshold: a single push to N proxies
# yields N samples in pilot_proxy_convergence_time.
get_source_proxy_count() {
	local port="$1"
	local m
	scrape_metrics "$port" m || { echo "1"; return; }
	# pilot_xds metric is the gauge of connected proxies in v1.28+.
	local n
	n=$(extract_gauge "$m" "pilot_xds")
	if [[ "$n" == "N/A" || -z "$n" || "$n" -lt 1 ]]; then
		echo "1"
	else
		echo "$n"
	fi
}

# --- P2 polling: EDS push counter delta on a remote istiod -----------------
poll_p2_remote_eds_push() {
	local port="$1" t0="$2" baseline_count="$3" result_file="$4" restart_baseline="$5"
	local deadline_ms=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	while true; do
		local now_ms=$(( $(date +%s%N) / 1000000 ))
		((now_ms > deadline_ms)) && { echo "TIMEOUT" > "$result_file"; return; }
		local m
		if ! scrape_metrics "$port" m; then
			sleep "$POLL_INTERVAL_S"
			continue
		fi
		# Restart check: if process_start_time_seconds changed, signal restart.
		local now_start
		now_start=$(extract_process_start "$m")
		if [[ "$restart_baseline" != "unknown" && "$now_start" != "unknown" && "$now_start" != "$restart_baseline" ]]; then
			echo "RESTART" > "$result_file"
			return
		fi
		local cur
		cur=$(extract_counter "$m" "pilot_xds_pushes" 'type="eds"')
		# When deployment / restart in progress, cur may be 0 < baseline.
		# Treat that as not-yet (do not consider it a negative event here).
		if (( cur > baseline_count )); then
			date +%s%N > "$result_file"
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
		local now_ms=$(( $(date +%s%N) / 1000000 ))
		((now_ms > deadline_ms)) && { echo "TIMEOUT" > "$result_file"; return; }
		local clusters
		clusters=$(curl -fsS --max-time 5 "http://localhost:$envoy_port/clusters" 2>/dev/null) || { sleep "$interval"; continue; }
		if echo "$clusters" | grep -q "propagation-canary.*health_flags::healthy"; then
			date +%s%N > "$result_file"
			return
		fi
		sleep "$interval"
	done
}

# --- P1 polling: histogram convergence on source istiod --------------------
poll_p1_local_sync_histogram() {
	local port="$1" t0="$2" baseline_file="$3" result_file="$4" proxy_count="$5" restart_baseline="$6" final_snapshot_file="$7"
	local deadline_ms=$(( t0 / 1000000 + TIMEOUT_SEC * 1000 ))
	local cur_snapshot delta_file
	cur_snapshot=$(mktemp -p "$TMPDIR_RUN")
	delta_file=$(mktemp -p "$TMPDIR_RUN")
	while true; do
		local now_ms=$(( $(date +%s%N) / 1000000 ))
		((now_ms > deadline_ms)) && { echo "TIMEOUT" > "$result_file"; rm -f "$cur_snapshot" "$delta_file"; return; }
		local m
		if ! scrape_metrics "$port" m; then
			sleep "$POLL_INTERVAL_S"
			continue
		fi
		local now_start
		now_start=$(extract_process_start "$m")
		if [[ "$restart_baseline" != "unknown" && "$now_start" != "unknown" && "$now_start" != "$restart_baseline" ]]; then
			echo "RESTART" > "$result_file"
			rm -f "$cur_snapshot" "$delta_file"
			return
		fi
		extract_histogram_snapshot "$m" "pilot_proxy_convergence_time" "$cur_snapshot"
		delta_histogram "$baseline_file" "$cur_snapshot" "$delta_file"
		local d_count
		d_count=$(awk -F'\t' '$1=="_count" {print $2; exit}' "$delta_file")
		[[ -z "$d_count" ]] && d_count=0
		if (( d_count >= proxy_count )); then
			date +%s%N > "$result_file"
			cp "$cur_snapshot" "$final_snapshot_file"
			rm -f "$cur_snapshot" "$delta_file"
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
		data=$(curl -fsS --max-time 5 "http://localhost:$port/clusters" 2>/dev/null) || { sleep "$POLL_INTERVAL_S"; continue; }
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

	# Concurrent baseline scrape across all istiods. Records per-context skew.
	echo "  Scraping baselines..."
	BASELINE_DIR="$TMPDIR_RUN/baseline-${iter}"
	mkdir -p "$BASELINE_DIR"
	BASELINE_PIDS=()
	BASELINE_TS_START=$(date +%s%N)
	(
		m=""
		if scrape_metrics "$BASE_PF_PORT" m; then
			extract_histogram_snapshot "$m" "pilot_proxy_convergence_time" "$BASELINE_DIR/source-hist"
			extract_process_start "$m" > "$BASELINE_DIR/source-start"
		else
			echo "unknown" > "$BASELINE_DIR/source-start"
			: > "$BASELINE_DIR/source-hist"
		fi
		date +%s%N > "$BASELINE_DIR/source-ts"
	) &
	BASELINE_PIDS+=($!)
	for i in "${!REMOTES[@]}"; do
		port=$(( BASE_PF_PORT + i + 1 ))
		(
			m=""
			if scrape_metrics "$port" m; then
				extract_counter "$m" "pilot_xds_pushes" 'type="eds"' > "$BASELINE_DIR/remote-${i}-eds"
				extract_process_start "$m" > "$BASELINE_DIR/remote-${i}-start"
			else
				echo "0" > "$BASELINE_DIR/remote-${i}-eds"
				echo "unknown" > "$BASELINE_DIR/remote-${i}-start"
			fi
			date +%s%N > "$BASELINE_DIR/remote-${i}-ts"
		) &
		BASELINE_PIDS+=($!)
	done
	for pid in "${BASELINE_PIDS[@]}"; do
		wait "$pid" 2>/dev/null || true
	done
	BASELINE_TS_END=$(date +%s%N)
	SCRAPE_SKEW_MS=$(( (BASELINE_TS_END - BASELINE_TS_START) / 1000000 ))

	SOURCE_START=$(<"$BASELINE_DIR/source-start")
	SOURCE_PROXY_COUNT=$(get_source_proxy_count "$BASE_PF_PORT")
	echo "  Source connected proxies: $SOURCE_PROXY_COUNT (scrape_skew=${SCRAPE_SKEW_MS}ms)"

	T0=$(date +%s%N)
	echo "  Deploying canary on $SOURCE_CTX..."
	helm template propagation-test "$CHART_DIR" \
		--set clusterName="$SOURCE_CTX" \
		--set namespace="$NS" \
		--set canary.enabled=true \
		--set canary.runId="$ITER_RUN_ID" \
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
	for i in "${!REMOTES[@]}"; do
		p2f="$TMPDIR_RUN/p2_${iter}_${i}"
		p3f="$TMPDIR_RUN/p3_${iter}_${i}"
		: > "$p2f"
		: > "$p3f"
		P2_FILES+=("$p2f")
		P3_FILES+=("$p3f")
		baseline_eds=$(<"$BASELINE_DIR/remote-${i}-eds")
		remote_start=$(<"$BASELINE_DIR/remote-${i}-start")
		poll_p2_remote_eds_push $(( BASE_PF_PORT + i + 1 )) "$T0" "$baseline_eds" "$p2f" "$remote_start" &
		POLL_PIDS+=($!)
		poll_p3_sidecar_endpoints $(( BASE_ENVOY_PF_PORT + i )) "$T0" "$p3f" &
		POLL_PIDS+=($!)
	done

	for pid in "${POLL_PIDS[@]}"; do
		wait "$pid" 2>/dev/null || true
	done
	POLL_PIDS=()

	T1=$(date +%s%N)
	WINDOW_MS=$(( (T1 - T0) / 1000000 ))

	# Compute p1 wall-clock + delta-window quantiles.
	p1_ms=$(compute_delta_ms "$P1_FILE" "$T0")

	# Final post-convergence delta vs baseline for quantiles.
	p1_conv_p50="N/A"
	p1_conv_p99="N/A"
	p1_sample_count="0"
	p1_overflow="0"
	restarted="0"
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

	# PL13: when restarted, quantiles are N/A.
	if [[ "$restarted" == "1" ]]; then
		p1_conv_p50="N/A"
		p1_conv_p99="N/A"
	fi

	echo "  P1 (local xDS push):   wall=${p1_ms}ms  conv_p50=${p1_conv_p50}ms  conv_p99=${p1_conv_p99}ms  samples=${p1_sample_count}/${SOURCE_PROXY_COUNT}  overflow=${p1_overflow}  restarted=${restarted}"

	if [[ "$p1_ms" =~ ^[0-9]+$ ]]; then
		P1_SUM=$((P1_SUM + p1_ms))
		P1_COUNT=$((P1_COUNT + 1))
		[[ -z "$P1_MIN" || "$p1_ms" -lt "$P1_MIN" ]] && P1_MIN="$p1_ms"
		[[ -z "$P1_MAX" || "$p1_ms" -gt "$P1_MAX" ]] && P1_MAX="$p1_ms"
	fi

	if [[ ${#REMOTES[@]} -eq 0 ]]; then
		status="OK"
		[[ "$p1_ms" == "TIMEOUT" ]] && status="TIMEOUT_P1"
		[[ "$restarted" == "1" ]] && status="RESTART"
		if ((WRITE_TSV)); then
			echo -e "${RUN_ID}\t${MESH_SIZE}\t${iter}\t${SOURCE_CTX}\tN/A\t${T0}\t${p1_ms}\tN/A\tN/A\t${status}\t${p1_conv_p50}\t${p1_conv_p99}\t${p1_sample_count}/${SOURCE_PROXY_COUNT}\t${SOURCE_PROXY_COUNT}\t${p1_overflow}\t${restarted}\t${WINDOW_MS}\t${SCRAPE_SKEW_MS}" >> "$TSV_FILE"
		fi
	else
		for i in "${!REMOTES[@]}"; do
			p2_ms=$(compute_delta_ms "${P2_FILES[i]}" "$T0")
			p3_ms=$(compute_delta_ms "${P3_FILES[i]}" "$T0")
			p2_raw=$(<"${P2_FILES[i]}")
			[[ "$p2_raw" == "RESTART" ]] && restarted="1"
			echo "  P2 (remote istiod ${REMOTES[i]}, EDS push): ${p2_ms}ms"
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

			status="OK"
			[[ "$p1_ms" == "TIMEOUT" ]] && status="TIMEOUT_P1"
			[[ "$p2_ms" == "TIMEOUT" ]] && status="TIMEOUT_P2"
			[[ "$p3_ms" == "TIMEOUT" ]] && status="TIMEOUT_P3"
			[[ "$p1_ms" == "TIMEOUT" && "$p2_ms" == "TIMEOUT" && "$p3_ms" == "TIMEOUT" ]] && status="TIMEOUT_ALL"
			[[ "$restarted" == "1" ]] && status="RESTART"

			# PL13: counter deltas / quantiles are N/A on restart.
			p2_out="$p2_ms"
			if [[ "$restarted" == "1" ]]; then
				p2_out="N/A"
			fi

			if ((WRITE_TSV)); then
				echo -e "${RUN_ID}\t${MESH_SIZE}\t${iter}\t${SOURCE_CTX}\t${REMOTES[i]}\t${T0}\t${p1_ms}\t${p2_out}\t${p3_ms}\t${status}\t${p1_conv_p50}\t${p1_conv_p99}\t${p1_sample_count}/${SOURCE_PROXY_COUNT}\t${SOURCE_PROXY_COUNT}\t${p1_overflow}\t${restarted}\t${WINDOW_MS}\t${SCRAPE_SKEW_MS}" >> "$TSV_FILE"
			fi
		done
	fi

	echo "  Cleaning up canary..."
	"${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" delete deploy/propagation-canary svc/propagation-canary --ignore-not-found=true --wait=true >/dev/null

	if ((iter < ITERATIONS)); then
		echo "  Waiting for canary endpoints to drain..."
		wait_sidecar_endpoint_removed "$SOURCE_ENVOY_PF_PORT" || echo "  Warning: timeout waiting for $SOURCE_CTX sidecar endpoint removal"
		for i in "${!REMOTES[@]}"; do
			wait_sidecar_endpoint_removed $(( BASE_ENVOY_PF_PORT + i )) || echo "  Warning: timeout waiting for ${REMOTES[i]} sidecar endpoint removal"
		done
		echo "  Canary endpoints drained. Settling for ${SETTLE_SEC}s..."
		sleep "$SETTLE_SEC"
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
	echo "| Date | $(date -Iseconds) |"
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
	echo "  Converged when delta \`_count\` >= connected proxy count. Reports wall-clock"
	echo "  time-to-converged-count plus delta-window p50/p99 of the histogram itself."
	echo "- **P2** (remote discovery): \`pilot_xds_pushes{type=\"eds\"}\` counter delta on each remote istiod."
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

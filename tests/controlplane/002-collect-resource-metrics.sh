#!/usr/bin/env bash
# Collect istiod resource usage and Prometheus metrics for control-plane analysis.
# Scrapes kubectl top and istiod /metrics, computes delta-window stats for the
# histograms and counters that are cumulative since istiod start, and writes a
# TSV row per cluster.
#
# Delta-window approach (chosen because Prometheus UWM is not guaranteed to be
# reachable from where this script runs): we take a *baseline* scrape on entry,
# wait `--settle SEC` (passed through by 003), take a *final* scrape, and
# compute deltas per histogram bucket / counter. p50 and p99 are derived from
# the windowed cumulative buckets via the standard linear-interp algorithm.
#
# Usage:
#   ./tests/controlplane/002-collect-resource-metrics.sh [--contexts CSV] [options]
#
# Examples:
#   # One-shot collection from all clusters (60-second window):
#   ./tests/controlplane/002-collect-resource-metrics.sh --mesh-size 3 \
#     --service-count 10 --settle 60
#
#   # Watch mode during load test (per-tick deltas at the interval cadence):
#   ./tests/controlplane/002-collect-resource-metrics.sh --watch --interval 15
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
OUTPUT_DIR="${ROOT}/tests/controlplane/results"
MESH_SIZE=""
SERVICE_COUNT="${CONTROLPLANE_SERVICE_COUNT:-10}"
REPLICAS="${CONTROLPLANE_REPLICAS_PER_SERVICE:-3}"
NAMESPACE_COUNT="${CONTROLPLANE_NAMESPACE_COUNT:-1}"
SETTLE_SEC=60
WATCH=0
INTERVAL=15
DRY_RUN=0
BASE_PF_PORT=15014

die() { echo "error: $*" >&2; exit 1; }

is_pos_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
is_nonneg_int() { [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV       Kube contexts to scrape (default: \$SETUP_CONTEXTS).
  --mesh-size N        Metadata tag for TSV output.
  --service-count N    Metadata tag for TSV output (default: $SERVICE_COUNT).
  --replicas N         Metadata tag for TSV output (default: $REPLICAS).
  --namespace-count N  Metadata tag for TSV output (default: $NAMESPACE_COUNT).
  --settle SEC         Delta-window length (seconds) between baseline and
                       final scrape (default: $SETTLE_SEC). Must match the
                       settle time used by the calling orchestrator.
  --output-dir DIR     Results directory (default: tests/controlplane/results).
  --watch              Loop continuously (delta window = --interval).
  --interval SEC       Seconds between scrapes in watch mode (default: 15).
  --dry-run            Show what would be scraped without connecting.
  -h, --help           Show this help.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_SERVICE_COUNT, CONTROLPLANE_REPLICAS_PER_SERVICE,
  CONTROLPLANE_NAMESPACE_COUNT.
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
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"
		shift 2
		;;
	--mesh-size)
		[[ -n "${2:-}" ]] || die "--mesh-size requires a value"
		MESH_SIZE="$2"
		shift 2
		;;
	--service-count)
		[[ -n "${2:-}" ]] || die "--service-count requires a value"
		SERVICE_COUNT="$2"
		shift 2
		;;
	--replicas)
		[[ -n "${2:-}" ]] || die "--replicas requires a value"
		REPLICAS="$2"
		shift 2
		;;
	--namespace-count)
		[[ -n "${2:-}" ]] || die "--namespace-count requires a value"
		NAMESPACE_COUNT="$2"
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
	--watch)
		WATCH=1
		shift
		;;
	--interval)
		[[ -n "${2:-}" ]] || die "--interval requires a value"
		INTERVAL="$2"
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

is_pos_int "$SERVICE_COUNT" || die "--service-count must be a positive integer (got: $SERVICE_COUNT)"
is_pos_int "$REPLICAS" || die "--replicas must be a positive integer (got: $REPLICAS)"
is_pos_int "$NAMESPACE_COUNT" || die "--namespace-count must be a positive integer (got: $NAMESPACE_COUNT)"
is_nonneg_int "$SETTLE_SEC" || die "--settle must be a non-negative integer (got: $SETTLE_SEC)"
is_pos_int "$INTERVAL" || die "--interval must be a positive integer (got: $INTERVAL)"

if command -v oc >/dev/null 2>&1; then
	KUBECTL=(oc)
elif command -v kubectl >/dev/null 2>&1; then
	KUBECTL=(kubectl)
else
	die "neither oc nor kubectl found on PATH"
fi

command -v curl >/dev/null 2>&1 || die "curl not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_csv "$CONTEXTS_CSV" CONTEXTS
else
	split_csv "$SETUP_CONTEXTS" CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

[[ -z "$MESH_SIZE" ]] && MESH_SIZE="${#CONTEXTS[@]}"
is_pos_int "$MESH_SIZE" || die "--mesh-size must be a positive integer (got: $MESH_SIZE)"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
# `git describe --always --dirty` falls back to a short-hash when there are
# no tags (this repo today) and appends `-dirty` if the working tree is
# modified — so operators can tell at a glance whether a TSV came from a
# clean checkout or a hacked-up branch.
HARNESS_SHA="$(git -C "$ROOT" describe --always --dirty --abbrev=7 2>/dev/null || echo unknown)"

# Reproducibility echo (visible even in normal/non-dry-run path).
echo "[002] RUN_ID=$RUN_ID  SETTLE_SEC=$SETTLE_SEC  HARNESS_SHA=$HARNESS_SHA"
echo "[002] Contexts: ${CONTEXTS[*]}  Mesh: $MESH_SIZE  Services: $SERVICE_COUNT  Replicas: $REPLICAS  Namespaces: $NAMESPACE_COUNT"

if ((DRY_RUN)); then
	echo "Would scrape istiod metrics from: ${CONTEXTS[*]}"
	exit 0
fi

mkdir -p "$OUTPUT_DIR"

ISTIO_VERSION_TAG="${ISTIO_VERSION:-unknown}"

# Probe kube server versions per context concurrently (best-effort).
# Each probe gets a 5s API timeout so unreachable contexts can't stall the
# whole sweep at startup; unreachable contexts are recorded as `unreachable`
# (distinct from `unknown`, which is for a reachable cluster that didn't
# return a parseable serverVersion).
KUBE_PROBE_DIR="$(mktemp -d -t controlplane-002-kubever.XXXXXX)"
KV_PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	(
		out=$("${KUBECTL[@]}" --context="$ctx" version -o json --request-timeout=5s 2>/dev/null) \
			&& v=$(printf '%s' "$out" | jq -r '.serverVersion.gitVersion // "unknown"' 2>/dev/null || echo unknown) \
			|| v=unreachable
		[[ -z "$v" ]] && v=unknown
		printf '%s' "$v" > "${KUBE_PROBE_DIR}/${ctx}"
	) &
	KV_PIDS+=($!)
done
for pid in "${KV_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
KUBE_VERSIONS_CSV=""
for ctx in "${CONTEXTS[@]}"; do
	if [[ -s "${KUBE_PROBE_DIR}/${ctx}" ]]; then
		v=$(<"${KUBE_PROBE_DIR}/${ctx}")
	else
		v=unreachable
	fi
	[[ -n "$KUBE_VERSIONS_CSV" ]] && KUBE_VERSIONS_CSV+=", "
	KUBE_VERSIONS_CSV+="${ctx}=${v}"
done
rm -rf "$KUBE_PROBE_DIR"

TSV_FILE="${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv"
{
	echo "# Control-plane resource metrics — $(date -u -Iseconds)"
	echo "# ISTIO_VERSION=${ISTIO_VERSION_TAG}"
	echo "# HARNESS_SHA=${HARNESS_SHA}"
	echo "# KUBE_VERSIONS=${KUBE_VERSIONS_CSV}"
	echo "# SETTLE_SEC=${SETTLE_SEC}"
	echo "# RUN_ID=${RUN_ID}"
	echo "# Contexts: ${CONTEXTS[*]}  Mesh size: $MESH_SIZE  Services: $SERVICE_COUNT  Replicas: $REPLICAS  Namespaces: $NAMESPACE_COUNT"
} > "$TSV_FILE"

# Schema (TSV header):
#   timestamp context mesh_size service_count replicas namespace_count
#   istiod_cpu_m istiod_mem_mi
#   convergence_p50_ms convergence_p99_ms queue_p50_ms queue_p99_ms
#   xds_pushes_delta xds_pushes_rate
#   xds_pushes_cds xds_pushes_eds xds_pushes_lds xds_pushes_rds xds_pushes_nds
#   k8s_events_delta k8s_events_rate
#   connected_proxies config_size_avg_bytes
#   scrape_window_sec scrape_skew_ms settle_sec istiod_restarted
#
# NOTE: `scrape_window_sec` is the actual wall-clock seconds between the
# (latest) baseline scrape and the (earliest) final scrape — used as the
# denominator for `*_rate`. `settle_sec` records the operator-supplied
# `--settle` value so intent vs. actual elapsed window are both visible.
# `istiod_restarted` is 1 if istiod's `process_start_time_seconds` moved
# forward between baseline and final (counters/histograms would underflow,
# so the report should treat that row as suspect).
echo -e "timestamp\tcontext\tmesh_size\tservice_count\treplicas\tnamespace_count\tistiod_cpu_m\tistiod_mem_mi\tconvergence_p50_ms\tconvergence_p99_ms\tqueue_p50_ms\tqueue_p99_ms\txds_pushes_delta\txds_pushes_rate\txds_pushes_cds\txds_pushes_eds\txds_pushes_lds\txds_pushes_rds\txds_pushes_nds\tk8s_events_delta\tk8s_events_rate\tconnected_proxies\tconfig_size_avg_bytes\tscrape_window_sec\tscrape_skew_ms\tsettle_sec\tistiod_restarted" >> "$TSV_FILE"

PF_PIDS=()
TMP_DIR="$(mktemp -d -t controlplane-002.XXXXXX)"

cleanup() {
	for pid in "${PF_PIDS[@]}"; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	PF_PIDS=()
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT

echo "Starting port-forwards to istiod..."
for i in "${!CONTEXTS[@]}"; do
	ctx="${CONTEXTS[i]}"
	port=$(( BASE_PF_PORT + i ))
	"${KUBECTL[@]}" --context="$ctx" -n istio-system port-forward svc/istiod "$port":15014 >/dev/null 2>&1 &
	PF_PIDS+=($!)
done

sleep 3

for i in "${!CONTEXTS[@]}"; do
	port=$(( BASE_PF_PORT + i ))
	attempts=0
	while ! curl -s -o /dev/null "http://localhost:$port/metrics" 2>/dev/null; do
		attempts=$((attempts + 1))
		((attempts > 20)) && die "port-forward to istiod on ${CONTEXTS[i]} (port $port) failed"
		sleep 0.5
	done
done
echo "Port-forwards ready."

# Extract a quantile (p50/p99/...) from a histogram with cumulative buckets.
# Reads `name_bucket{le="..."} v` lines from $1; emits ms value rounded to int,
# `overflow` if the target quantile falls in the +Inf bucket, or `N/A` if no
# samples are present.
extract_histogram_quantile() {
	local metrics="$1" name="$2" quantile="$3"
	echo "$metrics" | awk -v name="${name}_bucket" -v q="$quantile" '
	$0 ~ name && /le="/ {
		line = $0
		sub(/.*le="/, "", line); sub(/".*/, "", line)
		le = line
		count = $NF + 0
		buckets[++n] = le " " count
	}
	END {
		if(n==0) { print "N/A"; exit }
		# Total = the +Inf (last) bucket count, since buckets are cumulative.
		split(buckets[n], lastp, " ")
		total = lastp[2] + 0
		if (total <= 0) { print "N/A"; exit }
		target = total * q
		for(i=1;i<=n;i++) {
			split(buckets[i], parts, " ")
			if(parts[2]+0 >= target) {
				le_val = parts[1]
				if(le_val == "+Inf") { print "overflow"; exit }
				printf "%.0f\n", le_val * 1000
				exit
			}
		}
		print "N/A"
	}'
}

# Extract a single gauge value (last sample) by exact name match. Works for
# both `name N` and `name{labels} N`. Anchor with `^name(\\{| )` so that
# `pilot_xds` does NOT swallow `pilot_xds_pushes`.
#
# Inline test cases (read top-to-bottom by hand):
#   "pilot_xds 12"         -> match, prints 12
#   "pilot_xds{foo=\"a\"} 8" -> match, prints 8
#   "pilot_xds_pushes 99"  -> NO match (anchored regex prevents prefix bleed)
extract_gauge_exact() {
	local metrics="$1" name="$2"
	echo "$metrics" | awk -v name="$name" '
	BEGIN { pat = "^" name "(\\{| )" }
	!/^#/ && $0 ~ pat { val = $NF+0 }
	END { if (val == "") print "N/A"; else print val }
	'
}

# Sum all samples of a counter (across labels) into a single scalar.
extract_counter_sum() {
	local metrics="$1" name="$2"
	echo "$metrics" | awk -v name="$name" '
	BEGIN { pat = "^" name "(\\{| )" }
	!/^#/ && $0 ~ pat { sum += $NF }
	END { printf "%.0f\n", sum+0 }
	'
}

# Extract counter sum, broken out by a specific label value. e.g.
# extract_counter_by_label "$metrics" pilot_xds_pushes type eds.
extract_counter_by_label() {
	local metrics="$1" name="$2" label="$3" value="$4"
	echo "$metrics" | awk -v name="$name" -v lbl="$label" -v val="$value" '
	BEGIN { pat = "^" name "\\{" }
	!/^#/ && $0 ~ pat {
		labels = $0
		sub(/^[^{]*\{/, "", labels); sub(/\}.*$/, "", labels)
		# split label set into kv pairs
		nkv = split(labels, kvs, ",")
		hit = 0
		for (k = 1; k <= nkv; k++) {
			kv = kvs[k]
			gsub(/^[ \t]+|[ \t]+$/, "", kv)
			if (match(kv, "^" lbl "=\"") > 0) {
				v = kv
				sub("^" lbl "=\"", "", v)
				sub(/".*$/, "", v)
				if (v == val) { hit = 1; break }
			}
		}
		if (hit) sum += $NF
	}
	END { printf "%.0f\n", sum+0 }
	'
}

# Histogram _sum and _count sum-across-labels (single scalar each).
extract_hist_sum() {
	local metrics="$1" name="$2"
	echo "$metrics" | awk -v name="${name}_sum" '
	BEGIN { pat = "^" name "(\\{| )" }
	!/^#/ && $0 ~ pat { s += $NF+0 }
	END { printf "%.6f\n", s+0 }
	'
}
extract_hist_count() {
	local metrics="$1" name="$2"
	echo "$metrics" | awk -v name="${name}_count" '
	BEGIN { pat = "^" name "(\\{| )" }
	!/^#/ && $0 ~ pat { c += $NF+0 }
	END { printf "%.0f\n", c+0 }
	'
}

# Compute final - baseline for each histogram bucket; output in the same
# `name_bucket{le="X"} v` text form so extract_histogram_quantile can consume
# the delta directly.
#
# IMPORTANT: This helper aggregates by `le=` ONLY — it sums every row sharing
# the same `le=` value and emits each `le=` exactly once, in ascending `le`
# order with `+Inf` placed last. Callers in this script feed it the unlabelled
# `pilot_proxy_convergence_time` / `pilot_proxy_queue_time` / `…_config_size_bytes`
# histograms where `le=` is the only label. Histograms with additional labelsets
# (e.g. a future per-resource-type histogram) MUST be filtered or grouped
# upstream before being passed here — this function intentionally collapses
# label combinations together.
delta_histogram() {
	local baseline="$1" final="$2" name="$3"
	awk -v name="${name}_bucket" '
	function leval(line) {
		s = line; sub(/.*le="/, "", s); sub(/".*/, "", s); return s
	}
	function le_key(le,    k) {
		# Sort key: +Inf goes last (1e308 is way past any real bucket bound).
		if (le == "+Inf") return 1e308
		k = le + 0
		return k
	}
	NR==FNR {
		if ($0 ~ name && /le="/) base[leval($0)] += $NF+0
		next
	}
	$0 ~ name && /le="/ {
		le = leval($0)
		final_v[le] += $NF+0
		if (!(le in seen)) { seen[le] = 1; les[++n] = le }
	}
	END {
		# Emit each `le=` once, ascending by numeric bound (+Inf last).
		for (i = 1; i <= n; i++) sortable[i] = les[i]
		# Tiny insertion sort — n is bounded by histogram bucket count (~20).
		for (i = 2; i <= n; i++) {
			j = i
			while (j > 1 && le_key(sortable[j-1]) > le_key(sortable[j])) {
				t = sortable[j-1]; sortable[j-1] = sortable[j]; sortable[j] = t
				j--
			}
		}
		mname = name; sub(/_bucket$/, "", mname)
		for (i = 1; i <= n; i++) {
			le = sortable[i]
			delta = final_v[le] - (le in base ? base[le] : 0)
			if (delta < 0) delta = 0
			printf "%s_bucket{le=\"%s\"} %d\n", mname, le, delta
		}
	}
	' <(echo "$baseline") <(echo "$final")
}

# scrape_one_context $ctx $port $outfile $ts_start_file $ts_end_file
# Writes /metrics body to $outfile; writes the pre-request epoch_ms to
# $ts_start_file and the post-response epoch_ms to $ts_end_file. Both
# timestamps are needed by the parent so the wall-clock window can be
# computed as `min(final.start) - max(baseline.end)` — i.e. the conservative
# interval where every counter saw the same elapsed time.
scrape_one_context() {
	local ctx="$1" port="$2" out="$3" ts_start="$4" ts_end="$5"
	local body t_start t_end
	t_start=$(date -u +%s%3N)
	body=$(curl -s "http://localhost:${port}/metrics" 2>/dev/null) || return 1
	t_end=$(date -u +%s%3N)
	printf '%s' "$body" > "$out"
	printf '%s' "$t_start" > "$ts_start"
	printf '%s' "$t_end" > "$ts_end"
}

# Run all per-context scrapes in parallel. Populates per-context metrics +
# start/end timestamp files at `${out_prefix}-${i}.metrics`,
# `${out_prefix}-${i}.ts`, `${out_prefix}-${i}.tsend`. Emits the max-min
# scrape skew in milliseconds on stdout (skew uses request-start timestamps,
# as before, since that's what "did all clusters see the same wall-clock
# moment" measures).
scrape_all_parallel() {
	local out_prefix="$1" # path prefix, e.g. baseline or final
	local -a pids=()
	local -a ts_files=()
	local i ctx port
	for i in "${!CONTEXTS[@]}"; do
		ctx="${CONTEXTS[i]}"
		port=$(( BASE_PF_PORT + i ))
		local m_out="${out_prefix}-${i}.metrics"
		local t_out="${out_prefix}-${i}.ts"
		local te_out="${out_prefix}-${i}.tsend"
		(
			scrape_one_context "$ctx" "$port" "$m_out" "$t_out" "$te_out" || exit 1
		) &
		pids+=($!)
		ts_files+=("$t_out")
	done
	local rc=0
	for pid in "${pids[@]}"; do
		wait "$pid" || rc=$((rc + 1))
	done
	[[ $rc -eq 0 ]] || echo "warning: $rc scrape(s) failed for $out_prefix" >&2

	# Compute scrape skew (max - min) across the request-start timestamps.
	local min="" max="" t
	for t_out in "${ts_files[@]}"; do
		[[ -s "$t_out" ]] || continue
		t=$(<"$t_out")
		[[ -z "$min" || "$t" -lt "$min" ]] && min="$t"
		[[ -z "$max" || "$t" -gt "$max" ]] && max="$t"
	done
	if [[ -n "$min" && -n "$max" ]]; then
		echo $(( max - min ))
	else
		echo 0
	fi
}

# Take baseline + final scrape, compute deltas, emit one TSV row per context.
# `settle_input_sec` is the operator-supplied --settle value; the actual rate
# denominator (`scrape_window_sec`) is computed from wall-clock as
# `min(final_start_ts) - max(baseline_start_ts)`, recorded with one decimal
# of precision. This is conservative: the largest plausible elapsed window
# across all contexts, so per-context rates never overstate.
scrape_window() {
	local settle_input_sec="$1"
	local baseline_skew_ms final_skew_ms
	echo "  Baseline scrape..."
	baseline_skew_ms=$(scrape_all_parallel "${TMP_DIR}/baseline")
	if (( settle_input_sec > 0 )); then
		echo "  Settling for ${settle_input_sec}s..."
		sleep "$settle_input_sec"
	fi
	echo "  Final scrape..."
	final_skew_ms=$(scrape_all_parallel "${TMP_DIR}/final")
	local total_skew_ms=$(( baseline_skew_ms > final_skew_ms ? baseline_skew_ms : final_skew_ms ))

	# Wall-clock window: max(baseline.start) → min(final.start) in ms.
	# Falls back to settle_input_sec * 1000 if any timestamp is missing.
	local b_max_ms="" f_min_ms="" ts_val
	for i in "${!CONTEXTS[@]}"; do
		local bt="${TMP_DIR}/baseline-${i}.ts"
		local ft="${TMP_DIR}/final-${i}.ts"
		if [[ -s "$bt" ]]; then
			ts_val=$(<"$bt")
			[[ -z "$b_max_ms" || "$ts_val" -gt "$b_max_ms" ]] && b_max_ms="$ts_val"
		fi
		if [[ -s "$ft" ]]; then
			ts_val=$(<"$ft")
			[[ -z "$f_min_ms" || "$ts_val" -lt "$f_min_ms" ]] && f_min_ms="$ts_val"
		fi
	done
	local window_sec window_positive
	if [[ -n "$b_max_ms" && -n "$f_min_ms" ]] && (( f_min_ms > b_max_ms )); then
		window_sec=$(awk -v ms=$(( f_min_ms - b_max_ms )) 'BEGIN{ printf "%.1f", ms/1000 }')
	else
		# All-scrapes-failed or clock issue: degrade gracefully to settle.
		window_sec=$(awk -v s="$settle_input_sec" 'BEGIN{ printf "%.1f", s+0 }')
	fi
	# window_sec is a float ("60.3"); `(( > 0 ))` would parse it as int. Use
	# this string flag instead in the per-context loop below.
	window_positive=$(awk -v w="$window_sec" 'BEGIN{ print (w+0 > 0) ? 1 : 0 }')

	local ts
	ts=$(date -u -Iseconds)

	for i in "${!CONTEXTS[@]}"; do
		ctx="${CONTEXTS[i]}"

		local cpu_m="N/A" mem_mi="N/A"
		local top_output
		top_output=$("${KUBECTL[@]}" --context="$ctx" -n istio-system top pod -l app=istiod --no-headers 2>/dev/null) || true
		if [[ -n "$top_output" ]]; then
			cpu_m=$(echo "$top_output" | awk '{gsub(/m/,"",$2); sum+=$2} END{printf "%.0f", sum}')
			mem_mi=$(echo "$top_output" | awk '{gsub(/Mi/,"",$3); sum+=$3} END{printf "%.0f", sum}')
		fi

		local b_file="${TMP_DIR}/baseline-${i}.metrics"
		local f_file="${TMP_DIR}/final-${i}.metrics"
		if [[ ! -s "$f_file" ]]; then
			echo "warning: no final scrape for $ctx; emitting N/A row" >&2
			# Restart flag is 0 (unknown — we couldn't read the final metric).
			echo -e "${ts}\t${ctx}\t${MESH_SIZE}\t${SERVICE_COUNT}\t${REPLICAS}\t${NAMESPACE_COUNT}\t${cpu_m}\t${mem_mi}\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t0\t0\t0\t0\t0\tN/A\tN/A\tN/A\tN/A\t${window_sec}\t${total_skew_ms}\t${settle_input_sec}\t0" >> "$TSV_FILE"
			continue
		fi
		local baseline final
		baseline=$([[ -s "$b_file" ]] && cat "$b_file" || echo "")
		final=$(cat "$f_file")

		# Delta-window histograms.
		local conv_delta_text queue_delta_text
		conv_delta_text=$(delta_histogram "$baseline" "$final" "pilot_proxy_convergence_time")
		queue_delta_text=$(delta_histogram "$baseline" "$final" "pilot_proxy_queue_time")
		local conv_p50 conv_p99 queue_p50 queue_p99
		conv_p50=$(extract_histogram_quantile "$conv_delta_text" "pilot_proxy_convergence_time" "0.5")
		conv_p99=$(extract_histogram_quantile "$conv_delta_text" "pilot_proxy_convergence_time" "0.99")
		queue_p50=$(extract_histogram_quantile "$queue_delta_text" "pilot_proxy_queue_time" "0.5")
		queue_p99=$(extract_histogram_quantile "$queue_delta_text" "pilot_proxy_queue_time" "0.99")

		# Counter deltas (xds pushes + k8s events).
		local b_pushes f_pushes pushes_delta pushes_rate
		b_pushes=$([[ -n "$baseline" ]] && extract_counter_sum "$baseline" pilot_xds_pushes || echo 0)
		f_pushes=$(extract_counter_sum "$final" pilot_xds_pushes)
		pushes_delta=$(( f_pushes - b_pushes ))
		(( pushes_delta < 0 )) && pushes_delta=0
		if (( window_positive )); then
			pushes_rate=$(awk -v d="$pushes_delta" -v w="$window_sec" 'BEGIN{ printf "%.2f", d/w }')
		else
			pushes_rate="N/A"
		fi

		local b_evts f_evts evts_delta evts_rate
		b_evts=$([[ -n "$baseline" ]] && extract_counter_sum "$baseline" pilot_k8s_cfg_events || echo 0)
		f_evts=$(extract_counter_sum "$final" pilot_k8s_cfg_events)
		evts_delta=$(( f_evts - b_evts ))
		(( evts_delta < 0 )) && evts_delta=0
		if (( window_positive )); then
			evts_rate=$(awk -v d="$evts_delta" -v w="$window_sec" 'BEGIN{ printf "%.2f", d/w }')
		else
			evts_rate="N/A"
		fi

		# Per-type xds_pushes deltas.
		local types=(cds eds lds rds nds)
		local push_by_type=()
		for t in "${types[@]}"; do
			local b_t f_t d_t
			b_t=$([[ -n "$baseline" ]] && extract_counter_by_label "$baseline" pilot_xds_pushes type "$t" || echo 0)
			f_t=$(extract_counter_by_label "$final" pilot_xds_pushes type "$t")
			d_t=$(( f_t - b_t ))
			(( d_t < 0 )) && d_t=0
			push_by_type+=("$d_t")
		done

		# Connected proxies (gauge — read from final scrape).
		local connected_proxies
		connected_proxies=$(extract_gauge_exact "$final" pilot_xds)

		# istiod restart detection: process_start_time_seconds is a standard
		# Prom metric (seconds-since-epoch of process start). If the final
		# value is strictly greater than the baseline value, istiod restarted
		# during the scrape window — counters/histograms reset to 0 mid-window,
		# which makes deltas under-report.
		local b_pst f_pst istiod_restarted
		b_pst=$([[ -n "$baseline" ]] && extract_gauge_exact "$baseline" process_start_time_seconds || echo N/A)
		f_pst=$(extract_gauge_exact "$final" process_start_time_seconds)
		istiod_restarted=$(awk -v b="$b_pst" -v f="$f_pst" '
			BEGIN {
				if (b == "N/A" || f == "N/A") { print 0; exit }
				print (f+0 > b+0) ? 1 : 0
			}')
		if (( istiod_restarted )); then
			echo "warning: istiod restart detected during scrape window on ${ctx} (process_start_time_seconds ${b_pst} -> ${f_pst})" >&2
		fi

		# config_size: histogram, avg = (sum_delta / count_delta) bytes.
		local b_sum f_sum b_cnt f_cnt
		b_sum=$([[ -n "$baseline" ]] && extract_hist_sum "$baseline" pilot_xds_config_size_bytes || echo 0)
		f_sum=$(extract_hist_sum "$final" pilot_xds_config_size_bytes)
		b_cnt=$([[ -n "$baseline" ]] && extract_hist_count "$baseline" pilot_xds_config_size_bytes || echo 0)
		f_cnt=$(extract_hist_count "$final" pilot_xds_config_size_bytes)
		local cs_avg
		cs_avg=$(awk -v bs="$b_sum" -v fs="$f_sum" -v bc="$b_cnt" -v fc="$f_cnt" '
			BEGIN {
				ds = fs - bs; dc = fc - bc
				if (ds < 0) ds = 0
				if (dc <= 0) { print "N/A"; exit }
				printf "%.0f", ds/dc
			}')

		echo -e "${ts}\t${ctx}\t${MESH_SIZE}\t${SERVICE_COUNT}\t${REPLICAS}\t${NAMESPACE_COUNT}\t${cpu_m}\t${mem_mi}\t${conv_p50}\t${conv_p99}\t${queue_p50}\t${queue_p99}\t${pushes_delta}\t${pushes_rate}\t${push_by_type[0]}\t${push_by_type[1]}\t${push_by_type[2]}\t${push_by_type[3]}\t${push_by_type[4]}\t${evts_delta}\t${evts_rate}\t${connected_proxies}\t${cs_avg}\t${window_sec}\t${total_skew_ms}\t${settle_input_sec}\t${istiod_restarted}" >> "$TSV_FILE"
		echo "  Scraped $ctx: cpu=${cpu_m}m mem=${mem_mi}Mi proxies=${connected_proxies} pushes_delta=${pushes_delta} (eds=${push_by_type[1]} cds=${push_by_type[0]})"
	done
}

if ((WATCH)); then
	echo "Watch mode: ${INTERVAL}s window between baseline and final scrapes (Ctrl-C to stop)"
	while true; do
		echo ""
		echo "=== Window at $(date -u -Iseconds) ==="
		scrape_window "$INTERVAL"
	done
else
	echo ""
	echo "=== Scraping control-plane metrics (window=${SETTLE_SEC}s) ==="
	scrape_window "$SETTLE_SEC"
	echo ""
	echo "Results appended to $TSV_FILE"

	MD_FILE="${OUTPUT_DIR}/controlplane-${RUN_ID}.md"
	{
		echo "# Control-Plane Resource Metrics"
		echo ""
		echo "| Field | Value |"
		echo "|-------|-------|"
		echo "| Run ID | \`${RUN_ID}\` |"
		echo "| Date | $(date -u -Iseconds) |"
		echo "| Istio version | ${ISTIO_VERSION_TAG} |"
		echo "| Harness SHA | ${HARNESS_SHA} |"
		echo "| Kube versions | ${KUBE_VERSIONS_CSV} |"
		echo "| Contexts | ${CONTEXTS[*]} |"
		echo "| Mesh size | ${MESH_SIZE} |"
		echo "| Service count | ${SERVICE_COUNT} |"
		echo "| Replicas | ${REPLICAS} |"
		echo "| Namespace count | ${NAMESPACE_COUNT} |"
		echo "| Settle (s) | ${SETTLE_SEC} |"
		echo ""
		echo "## Summary"
		echo ""
		echo "| Context | CPU (m) | Mem (Mi) | Conv p99 (ms) | Queue p99 (ms) | Proxies | Pushes Δ | EDS Δ | CDS Δ |"
		echo "|---------|---------|----------|---------------|----------------|---------|----------|-------|-------|"
		awk -F'\t' '!/^#/ && !/^timestamp/ && NF>=25 {
			printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $2, $7, $8, $10, $12, $22, $13, $16, $15
		}' "$TSV_FILE"
		echo ""
		echo "## Raw Data"
		echo ""
		echo "TSV: [\`$(basename "$TSV_FILE")\`]($(basename "$TSV_FILE"))"
	} > "$MD_FILE"
	echo "Summary written to $MD_FILE"
fi

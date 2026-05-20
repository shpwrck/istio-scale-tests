#!/usr/bin/env bash
# Collect istiod resource usage and Prometheus metrics for control-plane analysis.
#
# Implements delta-window scraping: baseline and final snapshots are taken, then
# per-bucket / per-counter deltas are computed. Per-sidecar config-dump sampling
# captures Envoy /config_dump size per scoping mode.
#
# Usage:
#   ./tests/controlplane/002-collect-resource-metrics.sh [--contexts CSV] [options]
#
# Examples:
#   # One-shot collection from all clusters:
#   ./tests/controlplane/002-collect-resource-metrics.sh --mesh-size 3 --service-count 10
#
#   # With sidecar scoping metadata + 5 config-dump samples per cluster:
#   ./tests/controlplane/002-collect-resource-metrics.sh \
#     --sidecar-scoping namespace --config-dump-samples 5
#
#   # Watch mode during load test:
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
SIDECAR_SCOPING="${CONTROLPLANE_SIDECAR_SCOPING:-none}"
CONFIG_DUMP_SAMPLES="${CONTROLPLANE_CONFIG_DUMP_SAMPLES:-3}"
# NS is kept for forward-compat with multi-namespace deployments; currently
# the chart writes to a single namespace and config_dump sampling walks all of
# them via label selectors.
NS="${CONTROLPLANE_TEST_NAMESPACE:-controlplane-test}"
export NS  # silence SC2034: consumed implicitly when sourced by callers
WATCH=0
INTERVAL=15
SETTLE_SEC=30
RUN_ID_OVERRIDE=""
DRY_RUN=0
BASE_PF_PORT=15014

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV             Kube contexts to scrape (default: \$SETUP_CONTEXTS).
  --mesh-size N              Metadata tag for TSV output.
  --service-count N          Metadata tag for TSV output (default: $SERVICE_COUNT).
  --replicas N               Metadata tag for TSV output (default: $REPLICAS).
  --sidecar-scoping MODE     Metadata: none|namespace|explicit (default: $SIDECAR_SCOPING).
  --config-dump-samples N    Random pods per cluster to exec /config_dump on (default: $CONFIG_DUMP_SAMPLES; 0 disables).
  --settle SEC               Operator intent; recorded as settle_sec (default: $SETTLE_SEC).
  --output-dir DIR           Results directory (default: tests/controlplane/results).
  --run-id ID                Reuse a sweep RUN_ID (writes into sweep-<ID>/).
  --watch                    Loop continuously (single-snapshot mode; no delta).
  --interval SEC             Seconds between scrapes in watch mode (default: 15).
  --dry-run                  Show what would be scraped without connecting.
  -h, --help                 Show this help.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_TEST_NAMESPACE, CONTROLPLANE_SIDECAR_SCOPING,
  CONTROLPLANE_CONFIG_DUMP_SAMPLES.
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

validate_scoping() {
	case "$1" in
	none | namespace | explicit) return 0 ;;
	*) die "--sidecar-scoping must be one of [none, namespace, explicit]; got '$1'" ;;
	esac
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

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
	--sidecar-scoping)
		[[ -n "${2:-}" ]] || die "--sidecar-scoping requires a value"
		SIDECAR_SCOPING="$2"
		shift 2
		;;
	--config-dump-samples)
		[[ -n "${2:-}" ]] || die "--config-dump-samples requires a value"
		is_uint "$2" || die "--config-dump-samples must be a non-negative integer; got '$2'"
		CONFIG_DUMP_SAMPLES="$2"
		shift 2
		;;
	--settle)
		[[ -n "${2:-}" ]] || die "--settle requires a value"
		is_uint "$2" || die "--settle must be a non-negative integer; got '$2'"
		SETTLE_SEC="$2"
		shift 2
		;;
	--output-dir)
		[[ -n "${2:-}" ]] || die "--output-dir requires a value"
		OUTPUT_DIR="$2"
		shift 2
		;;
	--run-id)
		[[ -n "${2:-}" ]] || die "--run-id requires a value"
		RUN_ID_OVERRIDE="$2"
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

validate_scoping "$SIDECAR_SCOPING"

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

if ((DRY_RUN)); then
	echo "Would scrape istiod metrics from: ${CONTEXTS[*]}"
	echo "Mesh size: $MESH_SIZE  Services: $SERVICE_COUNT  Replicas: $REPLICAS"
	echo "Sidecar scoping: $SIDECAR_SCOPING  config-dump samples: $CONFIG_DUMP_SAMPLES"
	exit 0
fi

# PL6: per-sweep subdirectory.
RUN_ID="${RUN_ID_OVERRIDE:-$(date +%Y%m%dT%H%M%S)-$$}"
if [[ -n "$RUN_ID_OVERRIDE" ]]; then
	OUTPUT_DIR="${OUTPUT_DIR}/sweep-${RUN_ID_OVERRIDE}"
fi
mkdir -p "$OUTPUT_DIR"

HARNESS_SHA="$(git -C "$ROOT" describe --always --dirty --abbrev=7 2>/dev/null || echo unknown)"

# PL2: probe kube versions concurrently with short timeouts.
declare -A KUBE_VERS
KV_TMPDIR="$(mktemp -d)"
probe_kube_version_to_file() {
	local ctx="$1" out file
	file="${KV_TMPDIR}/${ctx//\//_}.ver"
	if ! "${KUBECTL[@]}" --context="$ctx" version --request-timeout=5s -o json >"${file}.raw" 2>/dev/null; then
		echo "unreachable" >"$file"
		return
	fi
	out="$(jq -r '.serverVersion.gitVersion // ""' <"${file}.raw" 2>/dev/null || true)"
	if [[ -z "$out" || "$out" == "null" ]]; then
		echo "unknown" >"$file"
	else
		echo "$out" >"$file"
	fi
}
for ctx in "${CONTEXTS[@]}"; do
	probe_kube_version_to_file "$ctx" &
done
wait
for ctx in "${CONTEXTS[@]}"; do
	f="${KV_TMPDIR}/${ctx//\//_}.ver"
	if [[ -f "$f" ]]; then
		KUBE_VERS[$ctx]="$(cat "$f")"
	else
		KUBE_VERS[$ctx]="unknown"
	fi
done
rm -rf "$KV_TMPDIR"

TSV_FILE="${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv"

# PL2: TSV preamble with all run metadata.
{
	echo "# Control-plane resource metrics — $(date -Iseconds)"
	echo "# RUN_ID=${RUN_ID}"
	echo "# HARNESS_SHA=${HARNESS_SHA}"
	echo "# ISTIO_VERSION=${ISTIO_VERSION:-unknown}"
	echo "# CONTEXTS=${CONTEXTS[*]}"
	for ctx in "${CONTEXTS[@]}"; do
		echo "# KUBE_VERSION[${ctx}]=${KUBE_VERS[$ctx]}"
	done
	echo "# MESH_SIZE=${MESH_SIZE}"
	echo "# SERVICE_COUNT=${SERVICE_COUNT}"
	echo "# REPLICAS=${REPLICAS}"
	echo "# SIDECAR_SCOPING=${SIDECAR_SCOPING}"
	echo "# CONFIG_DUMP_SAMPLES=${CONFIG_DUMP_SAMPLES}"
	echo "# SETTLE_SEC=${SETTLE_SEC}"
} >"$TSV_FILE"

# A1: dropped `config_size_bytes` (pilot_xds_config_size_bytes is a histogram,
# not a counter — the per-proxy /config_dump byte sample is the correct
# per-proxy signal).
# C2: `sidecar_config_bytes_samples` is now `attempted/got` (e.g. "3/1") to
# distinguish "ran 3, 2 failed" from "ran 1, succeeded".
echo -e "timestamp\tcontext\tmesh_size\tservice_count\treplicas\tsidecar_scoping\tistiod_cpu_m\tistiod_mem_mi\tconvergence_p50_ms\tconvergence_p99_ms\tqueue_p50_ms\tqueue_p99_ms\txds_pushes\tk8s_events\tconnected_proxies\tsidecar_config_bytes_avg\tsidecar_config_bytes_p50\tsidecar_config_bytes_max\tsidecar_config_bytes_samples\tscrape_window_sec\tscrape_skew_ms\tistiod_restarted\tsettle_sec" >>"$TSV_FILE"

PF_PIDS=()

cleanup() {
	for pid in "${PF_PIDS[@]}"; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	PF_PIDS=()
}

trap cleanup EXIT

echo "Starting port-forwards to istiod..."
for i in "${!CONTEXTS[@]}"; do
	ctx="${CONTEXTS[i]}"
	port=$((BASE_PF_PORT + i))
	"${KUBECTL[@]}" --context="$ctx" -n istio-system port-forward svc/istiod "$port":15014 >/dev/null 2>&1 &
	PF_PIDS+=($!)
done

sleep 3

for i in "${!CONTEXTS[@]}"; do
	port=$((BASE_PF_PORT + i))
	attempts=0
	while ! curl -s -o /dev/null "http://localhost:$port/metrics" 2>/dev/null; do
		attempts=$((attempts + 1))
		((attempts > 20)) && die "port-forward to istiod on ${CONTEXTS[i]} (port $port) failed"
		sleep 0.5
	done
done
echo "Port-forwards ready."

# ---------------------------------------------------------------------------
# Metric extraction helpers.
# ---------------------------------------------------------------------------

# Extract histogram cumulative buckets as "le<TAB>count" lines.
extract_histogram_buckets() {
	local metrics="$1" name="$2"
	echo "$metrics" | awk -v name="${name}_bucket{" '
	index($0, name) && !/^#/ {
		line=$0
		sub(/.*le="/, "", line); sub(/".*/, "", line)
		le=line
		count=$NF+0
		# Sum across label sets at same le.
		bucket[le]+=count
	}
	END {
		for(k in bucket) printf "%s\t%.0f\n", k, bucket[k]
	}'
}

# Extract histogram quantile from a buckets blob ("le<TAB>count" lines).
# A4: when any bucket delta is negative (rotation/skew between scrapes), emit
# "N/A" rather than walking a non-monotone CDF. Quantile walks delta values
# directly (no extra cumulative rebuild — Prometheus buckets are already
# cumulative-by-le).
histogram_quantile_from_buckets() {
	local buckets="$1" quantile="$2"
	echo "$buckets" | awk -v q="$quantile" '
	{
		le=$1; count=$2+0
		if (count < 0) { negative=1 }
		# +Inf last.
		if(le=="+Inf") { has_inf=1; inf_count=count; next }
		les[++n]=le; counts[le]=count
	}
	END {
		if (negative) { print "N/A"; exit }
		# Sort le numerically.
		for(i=1;i<=n;i++) for(j=i+1;j<=n;j++) if(les[i]+0>les[j]+0){t=les[i];les[i]=les[j];les[j]=t}
		total = has_inf ? inf_count : (n>0 ? counts[les[n]] : 0)
		if(total<=0){print "N/A"; exit}
		target=total*q
		for(i=1;i<=n;i++) {
			if(counts[les[i]]>=target){printf "%.0f\n", les[i]*1000; exit}
		}
		# Target fell in +Inf bucket — overflow signal.
		print "overflow"
	}'
}

# Subtract baseline counts (per le) from final counts; emit "le<TAB>delta".
diff_histogram_buckets() {
	local base="$1" final="$2"
	awk -v base="$base" -v final="$final" '
	BEGIN {
		n=split(base, blines, "\n")
		for(i=1;i<=n;i++) if(blines[i]!=""){split(blines[i],a,"\t"); b[a[1]]=a[2]+0}
		m=split(final, flines, "\n")
		for(i=1;i<=m;i++) if(flines[i]!=""){split(flines[i],a,"\t"); printf "%s\t%.0f\n", a[1], (a[2]+0)-(b[a[1]]+0)}
	}'
}

# A2: sum the gauge across every label permutation. pilot_xds, for example,
# is labelled and emitting only the first match under-reports connected
# proxies. Drop the early-exit and accumulate.
extract_gauge() {
	local metrics="$1" name="$2"
	echo "$metrics" | awk -v name="$name" '
	$0 !~ /^#/ {
		# Match "name " or "name{...} ".
		if (index($0, name "{") == 1 || index($0, name " ") == 1) {
			sum += $NF
			seen = 1
		}
	}
	END { if (seen) printf "%.0f\n", sum+0 }'
}

# Sum all label combinations of a counter into a single scalar.
extract_counter_sum() {
	local metrics="$1" name="$2"
	echo "$metrics" | awk -v name="$name" '
	$0 !~ /^#/ {
		if (index($0, name "{") == 1 || index($0, name " ") == 1) {
			sum+=$NF
		}
	}
	END { printf "%.0f\n", sum+0 }'
}

# PL9: read process_start_time_seconds. Output value or "unknown".
extract_process_start_time() {
	local metrics="$1"
	local v
	v="$(echo "$metrics" | awk '/^process_start_time_seconds /{print $NF; exit}')"
	if [[ -z "$v" ]]; then echo "unknown"; else echo "$v"; fi
}

# Scrape a single context's istiod /metrics; return contents or empty on failure.
scrape_metrics() {
	local port="$1"
	curl -s --max-time 10 "http://localhost:${port}/metrics" 2>/dev/null || true
}

# C1: deterministic, awk-only shuffle. Removes the `shuf` dependency (not on
# AGENTS.md tools list) and makes pod selection reproducible across reruns.
# We do NOT use awk's srand()/rand() — mawk reseeds rand() across processes
# in a non-deterministic way, so two runs with the same srand seed return
# different sequences. Instead, hash each line with the seed appended and
# sort by hash. Same seed → same ordering on any awk implementation.
deterministic_pick() {
	local n="$1" seed="$2"
	awk -v n="$n" -v seed="$seed" '
	function ord(c) { return index("\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !\"#$%&\x27()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~", c) }
	function hash(s,   i, h) {
		h=5381
		# Two passes (forward + reverse) so adjacent inputs do not produce
		# adjacent hashes — small mod-prime arithmetic only, portable across
		# mawk/gawk.
		for(i=1; i<=length(s); i++) h = (h*131 + ord(substr(s,i,1))) % 2147483647
		for(i=length(s); i>=1; i--) h = (h*131 + ord(substr(s,i,1))) % 2147483647
		return h
	}
	NF { lines[++idx]=$0; keys[idx]=hash($0 "|" seed) }
	END {
		# Bubble sort by hash key (stable for our small N).
		for(i=1;i<=idx;i++) for(j=i+1;j<=idx;j++) if (keys[i] > keys[j]) {
			t=keys[i]; keys[i]=keys[j]; keys[j]=t
			t=lines[i]; lines[i]=lines[j]; lines[j]=t
		}
		k = (n < idx ? n : idx)
		for(i=1;i<=k;i++) print lines[i]
	}'
}

# PL10: sample N random pods across the test namespaces and get config_dump
# byte size. B1: ?include_eds is critical — Envoy's default /config_dump
# omits EndpointsConfigDump, but EDS is the dominant per-proxy size driver
# and the metric scoping is designed to reduce.
collect_config_dump_samples() {
	local ctx="$1" samples="$2"
	local out_csv="" got=0 attempted=0
	if (( samples == 0 )); then
		echo ""
		return 0
	fi
	local pod_lines
	pod_lines="$("${KUBECTL[@]}" --context="$ctx" get pods -A \
		-l app.kubernetes.io/instance=controlplane-test \
		-o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.namespace}{"|"}{.metadata.name}{"\n"}{end}' \
		2>/dev/null || true)"
	# C1: deterministic shuffle seeded by RUN_ID + ctx so reruns are reproducible.
	local seed="${RUN_ID}-${ctx}"
	local picked
	picked="$(echo "$pod_lines" | grep -v '^$' | deterministic_pick "$samples" "$seed" 2>/dev/null || true)"
	[[ -z "$picked" ]] && { echo ""; return 0; }
	while IFS='|' read -r ns pod; do
		[[ -z "$pod" ]] && continue
		attempted=$((attempted + 1))
		local bytes
		bytes="$("${KUBECTL[@]}" --context="$ctx" -n "$ns" exec "$pod" -c istio-proxy -- \
			sh -c 'curl -s --max-time 10 "http://localhost:15000/config_dump?include_eds" | wc -c' 2>/dev/null || true)"
		bytes="$(echo "$bytes" | tr -d '[:space:]')"
		if [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]]; then
			got=$((got + 1))
			out_csv+="${bytes},"
		else
			out_csv+="N/A,"
		fi
	done <<<"$picked"
	# Trim trailing comma. attempted/got recorded by caller.
	out_csv="${out_csv%,}"
	echo "${out_csv}|attempted=${attempted}|got=${got}"
}

aggregate_sample_bytes() {
	# Args: csv-of-bytes-or-NA  -> "avg|p50|max"
	local csv="$1"
	[[ -z "$csv" ]] && { echo "N/A|N/A|N/A"; return; }
	echo "$csv" | awk -F',' '
	{
		n=0
		for(i=1;i<=NF;i++) {
			if($i ~ /^[0-9]+$/) vals[++n]=$i+0
		}
		if(n==0){print "N/A|N/A|N/A"; exit}
		for(i=1;i<=n;i++) for(j=i+1;j<=n;j++) if(vals[i]>vals[j]){t=vals[i];vals[i]=vals[j];vals[j]=t}
		sum=0; for(i=1;i<=n;i++) sum+=vals[i]
		avg=sum/n
		p50=vals[int((n+1)/2)]
		max=vals[n]
		printf "%.0f|%.0f|%.0f\n", avg, p50, max
	}'
}

# ---------------------------------------------------------------------------
# Baseline + Final delta-window scrape (PL1).
# ---------------------------------------------------------------------------

scrape_baseline_then_final() {
	local i ctx port
	declare -A BASE_METRICS BASE_TS FINAL_METRICS FINAL_TS BASE_PST FINAL_PST

	# Baseline scrape (concurrent, PL8).
	local base_tmpdir
	base_tmpdir="$(mktemp -d)"
	for i in "${!CONTEXTS[@]}"; do
		ctx="${CONTEXTS[i]}"
		port=$((BASE_PF_PORT + i))
		(
			ts_ms=$(date +%s%3N)
			m=$(scrape_metrics "$port")
			printf '%s\n' "$ts_ms" >"${base_tmpdir}/${ctx}.ts"
			printf '%s' "$m" >"${base_tmpdir}/${ctx}.metrics"
		) &
	done
	wait
	for ctx in "${CONTEXTS[@]}"; do
		BASE_TS[$ctx]="$(cat "${base_tmpdir}/${ctx}.ts" 2>/dev/null || echo 0)"
		BASE_METRICS[$ctx]="$(cat "${base_tmpdir}/${ctx}.metrics" 2>/dev/null || echo "")"
		BASE_PST[$ctx]="$(extract_process_start_time "${BASE_METRICS[$ctx]}")"
	done

	echo "Baseline scraped; settling ${SETTLE_SEC}s for delta window..."
	sleep "$SETTLE_SEC"

	# Final scrape (concurrent).
	local final_tmpdir
	final_tmpdir="$(mktemp -d)"
	for i in "${!CONTEXTS[@]}"; do
		ctx="${CONTEXTS[i]}"
		port=$((BASE_PF_PORT + i))
		(
			ts_ms=$(date +%s%3N)
			m=$(scrape_metrics "$port")
			printf '%s\n' "$ts_ms" >"${final_tmpdir}/${ctx}.ts"
			printf '%s' "$m" >"${final_tmpdir}/${ctx}.metrics"
		) &
	done
	wait
	for ctx in "${CONTEXTS[@]}"; do
		FINAL_TS[$ctx]="$(cat "${final_tmpdir}/${ctx}.ts" 2>/dev/null || echo 0)"
		FINAL_METRICS[$ctx]="$(cat "${final_tmpdir}/${ctx}.metrics" 2>/dev/null || echo "")"
		FINAL_PST[$ctx]="$(extract_process_start_time "${FINAL_METRICS[$ctx]}")"
	done

	# Compute scrape_window_sec (wall-clock, PL3) and scrape_skew_ms (PL8).
	local min_final max_base min_base max_final
	min_final=""
	max_base=""
	min_base=""
	max_final=""
	for ctx in "${CONTEXTS[@]}"; do
		[[ -z "$min_final" || "${FINAL_TS[$ctx]}" -lt "$min_final" ]] && min_final="${FINAL_TS[$ctx]}"
		[[ -z "$max_base"  || "${BASE_TS[$ctx]}"  -gt "$max_base"  ]] && max_base="${BASE_TS[$ctx]}"
		[[ -z "$min_base"  || "${BASE_TS[$ctx]}"  -lt "$min_base"  ]] && min_base="${BASE_TS[$ctx]}"
		[[ -z "$max_final" || "${FINAL_TS[$ctx]}" -gt "$max_final" ]] && max_final="${FINAL_TS[$ctx]}"
	done
	local window_sec skew_base_ms skew_final_ms skew_ms
	window_sec=$(awk -v a="$min_final" -v b="$max_base" 'BEGIN{printf "%.3f", (a-b)/1000.0}')
	skew_base_ms=$((max_base - min_base))
	skew_final_ms=$((max_final - min_final))
	# Report the larger skew across the two snapshots.
	if (( skew_base_ms > skew_final_ms )); then skew_ms=$skew_base_ms; else skew_ms=$skew_final_ms; fi

	local ts
	ts=$(date -Iseconds)
	for i in "${!CONTEXTS[@]}"; do
		ctx="${CONTEXTS[i]}"

		local base_m="${BASE_METRICS[$ctx]}" final_m="${FINAL_METRICS[$ctx]}"

		if [[ -z "$final_m" ]]; then
			echo "warning: empty final metrics for $ctx" >&2
			continue
		fi

		# PL9: restart detection. unknown if either side missing.
		local restarted="unknown"
		if [[ "${BASE_PST[$ctx]}" != "unknown" && "${FINAL_PST[$ctx]}" != "unknown" ]]; then
			if awk -v a="${BASE_PST[$ctx]}" -v b="${FINAL_PST[$ctx]}" 'BEGIN{exit !(a==b)}'; then
				restarted=0
			else
				restarted=1
			fi
		fi

		# CPU / mem via kubectl top.
		local cpu_m="N/A" mem_mi="N/A"
		local top_output
		top_output=$("${KUBECTL[@]}" --context="$ctx" -n istio-system top pod -l app=istiod --no-headers 2>/dev/null) || true
		if [[ -n "$top_output" ]]; then
			cpu_m=$(echo "$top_output" | awk '{gsub(/m/,"",$2); sum+=$2} END{printf "%.0f", sum}')
			mem_mi=$(echo "$top_output" | awk '{gsub(/Mi/,"",$3); sum+=$3} END{printf "%.0f", sum}')
		fi

		# PL1 / A3: histogram quantiles computed over the delta window.
		# When istiod restarted across the window, cumulative counts reset so
		# the delta is meaningless — emit N/A.
		local conv_base conv_final conv_delta queue_base queue_final queue_delta
		conv_base=$(extract_histogram_buckets "$base_m"  "pilot_proxy_convergence_time")
		conv_final=$(extract_histogram_buckets "$final_m" "pilot_proxy_convergence_time")
		conv_delta=$(diff_histogram_buckets "$conv_base" "$conv_final")
		queue_base=$(extract_histogram_buckets "$base_m"  "pilot_proxy_queue_time")
		queue_final=$(extract_histogram_buckets "$final_m" "pilot_proxy_queue_time")
		queue_delta=$(diff_histogram_buckets "$queue_base" "$queue_final")

		local conv_p50 conv_p99 queue_p50 queue_p99
		if [[ "$restarted" != "0" ]]; then
			# A3: restarted=1 OR unknown invalidates the delta window.
			conv_p50="N/A"; conv_p99="N/A"; queue_p50="N/A"; queue_p99="N/A"
		else
			conv_p50=$(histogram_quantile_from_buckets "$conv_delta" "0.5")
			conv_p99=$(histogram_quantile_from_buckets "$conv_delta" "0.99")
			queue_p50=$(histogram_quantile_from_buckets "$queue_delta" "0.5")
			queue_p99=$(histogram_quantile_from_buckets "$queue_delta" "0.99")
		fi

		# PL1 / A1 / A3: counters as deltas. pilot_xds_config_size_bytes
		# dropped (it is a histogram). When restarted (or unknown), the delta
		# is invalid.
		local xds_delta kev_delta
		if [[ "$restarted" != "0" ]]; then
			xds_delta="N/A"
			kev_delta="N/A"
		else
			local xds_b xds_f kev_b kev_f
			xds_b=$(extract_counter_sum "$base_m"  "pilot_xds_pushes")
			xds_f=$(extract_counter_sum "$final_m" "pilot_xds_pushes")
			kev_b=$(extract_counter_sum "$base_m"  "pilot_k8s_cfg_events")
			kev_f=$(extract_counter_sum "$final_m" "pilot_k8s_cfg_events")
			xds_delta=$((xds_f - xds_b))
			kev_delta=$((kev_f - kev_b))
		fi

		# Gauge taken from final (instantaneous). A2: now summed across labels.
		local connected
		connected=$(extract_gauge "$final_m" "pilot_xds")
		[[ -z "$connected" ]] && connected="N/A"

		# PL10 / C2: per-sidecar config dump samples. Emit attempted/got.
		local cd_out cd_csv cd_meta agg avg p50 max
		cd_out="$(collect_config_dump_samples "$ctx" "$CONFIG_DUMP_SAMPLES" || true)"
		cd_csv="${cd_out%%|*}"
		cd_meta="${cd_out#*|}"
		local attempted=0 got=0
		[[ "$cd_meta" =~ attempted=([0-9]+) ]] && attempted="${BASH_REMATCH[1]}"
		[[ "$cd_meta" =~ got=([0-9]+) ]] && got="${BASH_REMATCH[1]}"
		agg="$(aggregate_sample_bytes "$cd_csv")"
		avg="${agg%%|*}"
		p50="$(echo "$agg" | awk -F'|' '{print $2}')"
		max="$(echo "$agg" | awk -F'|' '{print $3}')"

		echo -e "${ts}\t${ctx}\t${MESH_SIZE}\t${SERVICE_COUNT}\t${REPLICAS}\t${SIDECAR_SCOPING}\t${cpu_m}\t${mem_mi}\t${conv_p50}\t${conv_p99}\t${queue_p50}\t${queue_p99}\t${xds_delta}\t${kev_delta}\t${connected}\t${avg}\t${p50}\t${max}\t${attempted}/${got}\t${window_sec}\t${skew_ms}\t${restarted}\t${SETTLE_SEC}" >>"$TSV_FILE"
		echo "  Scraped $ctx: cpu=${cpu_m}m mem=${mem_mi}Mi proxies=${connected} pushes_delta=${xds_delta} cfg_bytes_avg=${avg} samples=${attempted}/${got} restarted=${restarted}"
	done

	rm -rf "$base_tmpdir" "$final_tmpdir"
}

# Watch mode: lightweight single-snapshot loop (no delta).
scrape_single_snapshot() {
	local ts i ctx port
	ts=$(date -Iseconds)
	for i in "${!CONTEXTS[@]}"; do
		ctx="${CONTEXTS[i]}"
		port=$((BASE_PF_PORT + i))
		local m
		m=$(scrape_metrics "$port")
		[[ -z "$m" ]] && { echo "warning: failed to scrape $ctx" >&2; continue; }

		local cpu_m="N/A" mem_mi="N/A" top_output
		top_output=$("${KUBECTL[@]}" --context="$ctx" -n istio-system top pod -l app=istiod --no-headers 2>/dev/null) || true
		if [[ -n "$top_output" ]]; then
			cpu_m=$(echo "$top_output" | awk '{gsub(/m/,"",$2); sum+=$2} END{printf "%.0f", sum}')
			mem_mi=$(echo "$top_output" | awk '{gsub(/Mi/,"",$3); sum+=$3} END{printf "%.0f", sum}')
		fi

		local buckets conv_p50 conv_p99 q_p50 q_p99
		buckets=$(extract_histogram_buckets "$m" "pilot_proxy_convergence_time")
		conv_p50=$(histogram_quantile_from_buckets "$buckets" "0.5")
		conv_p99=$(histogram_quantile_from_buckets "$buckets" "0.99")
		buckets=$(extract_histogram_buckets "$m" "pilot_proxy_queue_time")
		q_p50=$(histogram_quantile_from_buckets "$buckets" "0.5")
		q_p99=$(histogram_quantile_from_buckets "$buckets" "0.99")

		local xds kev conn
		xds=$(extract_counter_sum "$m" "pilot_xds_pushes")
		kev=$(extract_counter_sum "$m" "pilot_k8s_cfg_events")
		conn=$(extract_gauge "$m" "pilot_xds")
		[[ -z "$conn" ]] && conn="N/A"

		# A1: config_size_bytes column dropped; per-pod sample columns are N/A
		# in watch mode (no /config_dump sampling for low overhead).
		# C2: samples slot is attempted/got = 0/0 in watch mode.
		echo -e "${ts}\t${ctx}\t${MESH_SIZE}\t${SERVICE_COUNT}\t${REPLICAS}\t${SIDECAR_SCOPING}\t${cpu_m}\t${mem_mi}\t${conv_p50}\t${conv_p99}\t${q_p50}\t${q_p99}\t${xds}\t${kev}\t${conn}\tN/A\tN/A\tN/A\t0/0\t0\t0\tunknown\t${SETTLE_SEC}" >>"$TSV_FILE"
		echo "  Scraped $ctx: cpu=${cpu_m}m mem=${mem_mi}Mi proxies=${conn} pushes=${xds}"
	done
}

if ((WATCH)); then
	echo "Watch mode: scraping every ${INTERVAL}s (Ctrl-C to stop). Note: watch mode reports raw cumulative values; use one-shot mode for delta-window metrics."
	while true; do
		echo ""
		echo "=== Scrape at $(date -Iseconds) ==="
		scrape_single_snapshot
		sleep "$INTERVAL"
	done
else
	echo ""
	echo "=== Scraping control-plane metrics (delta window=${SETTLE_SEC}s) ==="
	scrape_baseline_then_final
	echo ""
	echo "Results appended to $TSV_FILE"

	MD_FILE="${OUTPUT_DIR}/controlplane-${RUN_ID}.md"
	{
		echo "# Control-Plane Resource Metrics"
		echo ""
		echo "| Field | Value |"
		echo "|-------|-------|"
		echo "| Run ID | \`${RUN_ID}\` |"
		echo "| Harness SHA | \`${HARNESS_SHA}\` |"
		echo "| Istio version | ${ISTIO_VERSION:-unknown} |"
		echo "| Date | $(date -Iseconds) |"
		echo "| Contexts | ${CONTEXTS[*]} |"
		echo "| Mesh size | ${MESH_SIZE} |"
		echo "| Service count | ${SERVICE_COUNT} |"
		echo "| Replicas | ${REPLICAS} |"
		echo "| Sidecar scoping | ${SIDECAR_SCOPING} |"
		echo "| Config-dump samples | ${CONFIG_DUMP_SAMPLES} |"
		echo "| Settle | ${SETTLE_SEC}s |"
		echo ""
		echo "## Summary"
		echo ""
		echo "| Context | CPU (m) | Memory (Mi) | Conv p50 (ms) | Conv p99 (ms) | Queue p99 (ms) | Proxies | Pushes Δ | Cfg bytes avg | Samples | Restarted |"
		echo "|---------|---------|-------------|---------------|---------------|----------------|---------|----------|---------------|---------|-----------|"
		# Column count is 23 after A1 dropped config_size_bytes.
		awk -F'\t' '!/^#/ && !/^timestamp/ && NF>=23 {
			printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $2, $7, $8, $9, $10, $12, $15, $13, $16, $19, $22
		}' "$TSV_FILE"
		echo ""
		echo "## Raw Data"
		echo ""
		echo "TSV: [\`$(basename "$TSV_FILE")\`]($(basename "$TSV_FILE"))"
	} >"$MD_FILE"
	echo "Summary written to $MD_FILE"
fi

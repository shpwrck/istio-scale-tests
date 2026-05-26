#!/usr/bin/env bash
# Collect istiod resource usage and Prometheus metrics for control-plane analysis.
# Scrapes istiod /metrics, computes delta-window stats for the histograms and
# counters that are cumulative since istiod start, and writes a TSV row per
# cluster. Optionally samples per-sidecar /config_dump byte size for Sidecar CR
# scoping analysis.
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
# ci-dry-run: --contexts ci-dummy
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
PRIMARY_NS="${CONTROLPLANE_TEST_NAMESPACE:-controlplane-test}"
SIDECAR_SCOPING="${CONTROLPLANE_SIDECAR_SCOPING:-none}"
CONFIG_DUMP_SAMPLES="${CONTROLPLANE_CONFIG_DUMP_SAMPLES:-3}"
SETTLE_SEC=60
WATCH=0
INTERVAL=15
DRY_RUN=0
BASE_PF_PORT=15014
PHASE=combined
STATE_DIR=""
RUN_ID_OVERRIDE=""

die() { echo "error: $*" >&2; exit 1; }

is_pos_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
is_nonneg_int() { [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]; }

# Portable millisecond-resolution Unix timestamp. macOS BSD `date` does not
# expand `%N`, so `date +%s%3N` yields "<seconds>3N" and breaks arithmetic.
# Detect the best available implementation once and cache it.
NOW_MS_IMPL=""
_detect_now_ms() {
	[[ -n "$NOW_MS_IMPL" ]] && return
	if [[ "$(date -u +%s%3N 2>/dev/null)" =~ ^[0-9]+$ ]]; then
		NOW_MS_IMPL=date
	elif command -v gdate >/dev/null 2>&1 \
		&& [[ "$(gdate -u +%s%3N 2>/dev/null)" =~ ^[0-9]+$ ]]; then
		NOW_MS_IMPL=gdate
	elif command -v python3 >/dev/null 2>&1; then
		NOW_MS_IMPL=python3
	elif command -v perl >/dev/null 2>&1; then
		NOW_MS_IMPL=perl
	else
		die "no millisecond-resolution time source: install GNU coreutils (gdate), python3, or perl"
	fi
}
now_ms() {
	_detect_now_ms
	case "$NOW_MS_IMPL" in
	date)    date -u +%s%3N ;;
	gdate)   gdate -u +%s%3N ;;
	python3) python3 -c 'import time; print(int(time.time()*1000))' ;;
	perl)    perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time()*1000' ;;
	esac
}

validate_scoping() {
	case "$1" in
	none | namespace | explicit) return 0 ;;
	*) die "--sidecar-scoping must be one of [none, namespace, explicit]; got '$1'" ;;
	esac
}

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV       Kube contexts to scrape (default: \$SETUP_CONTEXTS).
  --mesh-size N        Metadata tag for TSV output.
  --service-count N    Metadata tag for TSV output (default: $SERVICE_COUNT).
  --replicas N         Metadata tag for TSV output (default: $REPLICAS).
  --namespace-count N  Metadata tag for TSV output (default: $NAMESPACE_COUNT).
  --sidecar-scoping M  Metadata tag: none|namespace|explicit (default: $SIDECAR_SCOPING).
  --config-dump-samples N  Random pods per cluster to exec /config_dump on
                       (default: $CONFIG_DUMP_SAMPLES; 0 disables).
  --settle SEC         Delta-window length (seconds) between baseline and
                       final scrape (default: $SETTLE_SEC). Must match the
                       settle time used by the calling orchestrator.
  --output-dir DIR     Results directory (default: tests/controlplane/results).
  --run-id ID          Reuse an existing sweep RUN_ID (writes into sweep-<ID>/).
  --watch              Loop continuously (delta window = --interval).
  --interval SEC       Seconds between scrapes in watch mode (default: 15).
  --phase PHASE        Orchestration phase, one of:
                         combined  baseline + settle + final + emit (default,
                                   for standalone use)
                         baseline  scrape baseline metrics only, write to
                                   --state-dir, exit without emitting a row.
                                   No settle; caller (003) should invoke 001
                                   AFTER this so the deploy storm lands inside
                                   the scrape window.
                         final     scrape final metrics, read baseline from
                                   --state-dir, compute deltas, emit one row.
  --state-dir DIR      Required for --phase baseline (must be empty/writable)
                       and --phase final (must contain a prior baseline's
                       output). Used to ferry baseline metrics across the
                       deploy step in split-phase mode. Ignored for combined.
  --dry-run            Show what would be scraped without connecting.
  -h, --help           Show this help.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_SERVICE_COUNT, CONTROLPLANE_REPLICAS_PER_SERVICE,
  CONTROLPLANE_NAMESPACE_COUNT, CONTROLPLANE_SIDECAR_SCOPING,
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
	--sidecar-scoping)
		[[ -n "${2:-}" ]] || die "--sidecar-scoping requires a value"
		SIDECAR_SCOPING="$2"
		shift 2
		;;
	--config-dump-samples)
		[[ -n "${2:-}" ]] || die "--config-dump-samples requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--config-dump-samples must be a non-negative integer; got '$2'"
		CONFIG_DUMP_SAMPLES="$2"
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
	--phase)
		[[ -n "${2:-}" ]] || die "--phase requires a value"
		PHASE="$2"
		shift 2
		;;
	--state-dir)
		[[ -n "${2:-}" ]] || die "--state-dir requires a value"
		STATE_DIR="$2"
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
is_nonneg_int "$CONFIG_DUMP_SAMPLES" || die "--config-dump-samples must be a non-negative integer (got: $CONFIG_DUMP_SAMPLES)"
validate_scoping "$SIDECAR_SCOPING"
case "$PHASE" in
combined|baseline|final) ;;
*) die "--phase must be one of: combined, baseline, final (got: $PHASE)";;
esac
if [[ "$PHASE" != combined ]]; then
	[[ -n "$STATE_DIR" ]] || die "--phase $PHASE requires --state-dir"
fi
if ((WATCH)) && [[ "$PHASE" != combined ]]; then
	die "--watch is only valid with --phase combined"
fi
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

if [[ -n "$RUN_ID_OVERRIDE" ]]; then
	RUN_ID="$RUN_ID_OVERRIDE"
else
	RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
HARNESS_SHA="$(git -C "$ROOT" describe --always --dirty --abbrev=7 2>/dev/null || echo unknown)"

echo "[002] RUN_ID=$RUN_ID  SETTLE_SEC=$SETTLE_SEC  HARNESS_SHA=$HARNESS_SHA"
echo "[002] Contexts: ${CONTEXTS[*]}  Mesh: $MESH_SIZE  Services: $SERVICE_COUNT  Replicas: $REPLICAS  Namespaces: $NAMESPACE_COUNT  Scoping: $SIDECAR_SCOPING  ConfigDumpSamples: $CONFIG_DUMP_SAMPLES"

if ((DRY_RUN)); then
	echo "Would scrape istiod metrics from: ${CONTEXTS[*]}"
	exit 0
fi

if [[ "$PHASE" != baseline ]]; then
	mkdir -p "$OUTPUT_DIR"
fi
if [[ "$PHASE" != combined ]]; then
	mkdir -p "$STATE_DIR"
fi

ISTIO_VERSION_TAG="${ISTIO_VERSION:-unknown}"

# Probe kube server versions per context concurrently (best-effort).
# Use the array index (not the context name) as the per-probe filename —
# OpenShift's auto-generated context names contain `/` (e.g.
# `default/api-foo:443/user`) which would otherwise be interpreted as path
# separators and fail with "No such file or directory".
KUBE_PROBE_DIR="$(mktemp -d -t controlplane-002-kubever.XXXXXX)"
KV_PIDS=()
for i in "${!CONTEXTS[@]}"; do
	ctx="${CONTEXTS[i]}"
	(
		out=$("${KUBECTL[@]}" --context="$ctx" version -o json --request-timeout=5s 2>/dev/null) \
			&& v=$(printf '%s' "$out" | jq -r '.serverVersion.gitVersion // "unknown"' 2>/dev/null || echo unknown) \
			|| v=unreachable
		[[ -z "$v" ]] && v=unknown
		printf '%s' "$v" > "${KUBE_PROBE_DIR}/${i}"
	) &
	KV_PIDS+=($!)
done
for pid in "${KV_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
KUBE_VERSIONS_CSV=""
for i in "${!CONTEXTS[@]}"; do
	ctx="${CONTEXTS[i]}"
	if [[ -s "${KUBE_PROBE_DIR}/${i}" ]]; then
		v=$(<"${KUBE_PROBE_DIR}/${i}")
	else
		v=unreachable
	fi
	[[ -n "$KUBE_VERSIONS_CSV" ]] && KUBE_VERSIONS_CSV+=", "
	KUBE_VERSIONS_CSV+="${ctx}=${v}"
done
rm -rf "$KUBE_PROBE_DIR"

TSV_FILE="${OUTPUT_DIR}/controlplane-${RUN_ID}.tsv"
if [[ "$PHASE" != baseline && ! -f "$TSV_FILE" ]]; then
	{
		echo "# Control-plane resource metrics — $(date -u -Iseconds)"
		echo "# ISTIO_VERSION=${ISTIO_VERSION_TAG}"
		echo "# HARNESS_SHA=${HARNESS_SHA}"
		echo "# KUBE_VERSIONS=${KUBE_VERSIONS_CSV}"
		echo "# SETTLE_SEC=${SETTLE_SEC}"
		echo "# RUN_ID=${RUN_ID}"
		echo "# PHASE=${PHASE}"
		echo "# SIDECAR_SCOPING=${SIDECAR_SCOPING}"
		echo "# CONFIG_DUMP_SAMPLES=${CONFIG_DUMP_SAMPLES}"
		echo "# Contexts: ${CONTEXTS[*]}  Mesh size: $MESH_SIZE  Services: $SERVICE_COUNT  Replicas: $REPLICAS  Namespaces: $NAMESPACE_COUNT  Scoping: $SIDECAR_SCOPING"
	} > "$TSV_FILE"
fi

# Schema (TSV header — 32 columns):
#   timestamp context mesh_size service_count replicas namespace_count sidecar_scoping
#   istiod_mem_mi
#   convergence_p50_ms convergence_p99_ms queue_p50_ms queue_p99_ms
#   xds_pushes_delta xds_pushes_rate
#   xds_pushes_cds xds_pushes_eds xds_pushes_lds xds_pushes_rds xds_pushes_nds
#   k8s_events_delta k8s_events_rate
#   connected_proxies config_size_avg_bytes
#   sidecar_config_bytes_avg sidecar_config_bytes_p50 sidecar_config_bytes_max sidecar_config_bytes_samples
#   scrape_window_sec scrape_skew_ms settle_sec istiod_restarted
#   istiod_cpu_m_delta
if [[ "$PHASE" != baseline ]] && ! grep -q '^timestamp' "$TSV_FILE" 2>/dev/null; then
	echo -e "timestamp\tcontext\tmesh_size\tservice_count\treplicas\tnamespace_count\tsidecar_scoping\tistiod_mem_mi\tconvergence_p50_ms\tconvergence_p99_ms\tqueue_p50_ms\tqueue_p99_ms\txds_pushes_delta\txds_pushes_rate\txds_pushes_cds\txds_pushes_eds\txds_pushes_lds\txds_pushes_rds\txds_pushes_nds\tk8s_events_delta\tk8s_events_rate\tconnected_proxies\tconfig_size_avg_bytes\tsidecar_config_bytes_avg\tsidecar_config_bytes_p50\tsidecar_config_bytes_max\tsidecar_config_bytes_samples\tscrape_window_sec\tscrape_skew_ms\tsettle_sec\tistiod_restarted\tistiod_cpu_m_delta" >> "$TSV_FILE"
fi

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

# ---------------------------------------------------------------------------
# Metric extraction helpers.
# ---------------------------------------------------------------------------

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

extract_gauge_exact() {
	local metrics="$1" name="$2"
	echo "$metrics" | awk -v name="$name" '
	BEGIN { pat = "^" name "(\\{| )" }
	!/^#/ && $0 ~ pat { val = $NF+0 }
	END { if (val == "") print "N/A"; else print val }
	'
}

extract_counter_sum() {
	local metrics="$1" name="$2"
	echo "$metrics" | awk -v name="$name" '
	BEGIN { pat = "^" name "(\\{| )" }
	!/^#/ && $0 ~ pat { sum += $NF }
	END { printf "%.0f\n", sum+0 }
	'
}

extract_counter_by_label() {
	local metrics="$1" name="$2" label="$3" value="$4"
	echo "$metrics" | awk -v name="$name" -v lbl="$label" -v val="$value" '
	BEGIN { pat = "^" name "\\{" }
	!/^#/ && $0 ~ pat {
		labels = $0
		sub(/^[^{]*\{/, "", labels); sub(/\}.*$/, "", labels)
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

delta_histogram() {
	local baseline="$1" final="$2" name="$3"
	awk -v name="${name}_bucket" '
	function leval(line) {
		s = line; sub(/.*le="/, "", s); sub(/".*/, "", s); return s
	}
	function le_key(le,    k) {
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
		for (i = 1; i <= n; i++) sortable[i] = les[i]
		for (i = 2; i <= n; i++) {
			j = i
			while (j > 1 && le_key(sortable[j-1]) > le_key(sortable[j])) {
				t = sortable[j-1]; sortable[j-1] = sortable[j]; sortable[j] = t
				j--
			}
		}
		# PL14: if ANY per-bucket delta is negative, the histogram is
		# corrupt (counter rotation / label drift / undetected restart).
		# Emit nothing so the caller produces N/A for all quantiles.
		mname = name; sub(/_bucket$/, "", mname)
		bad = 0
		for (i = 1; i <= n; i++) {
			le = sortable[i]
			delta = final_v[le] - (le in base ? base[le] : 0)
			if (delta < 0) { bad = 1; break }
		}
		if (bad) exit
		for (i = 1; i <= n; i++) {
			le = sortable[i]
			delta = final_v[le] - (le in base ? base[le] : 0)
			printf "%s_bucket{le=\"%s\"} %d\n", mname, le, delta
		}
	}
	' <(echo "$baseline") <(echo "$final")
}

# ---------------------------------------------------------------------------
# Per-sidecar /config_dump sampling.
# ---------------------------------------------------------------------------

deterministic_pick() {
	local n="$1" seed="$2"
	awk -v n="$n" -v seed="$seed" '
	function ord(c) { return index("\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !\"#$%&\x27()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~", c) }
	function hash(s,   i, h) {
		h=5381
		for(i=1; i<=length(s); i++) h = (h*131 + ord(substr(s,i,1))) % 2147483647
		for(i=length(s); i>=1; i--) h = (h*131 + ord(substr(s,i,1))) % 2147483647
		return h
	}
	NF { lines[++idx]=$0; keys[idx]=hash($0 "|" seed) }
	END {
		for(i=1;i<=idx;i++) for(j=i+1;j<=idx;j++) if (keys[i] > keys[j]) {
			t=keys[i]; keys[i]=keys[j]; keys[j]=t
			t=lines[i]; lines[i]=lines[j]; lines[j]=t
		}
		k = (n < idx ? n : idx)
		for(i=1;i<=k;i++) print lines[i]
	}'
}

collect_config_dump_samples() {
	local ctx="$1" samples="$2"
	local out_csv="" got=0 attempted=0
	if (( samples == 0 )); then
		echo ""
		return 0
	fi
	# Sample pods only from the primary namespace. When namespaceCount > 1,
	# Sidecar CRs are only emitted there, so mixing scoped and unscoped
	# pods would contaminate the measurement.
	local pod_lines
	pod_lines="$("${KUBECTL[@]}" --context="$ctx" -n "$PRIMARY_NS" get pods \
		-l app.kubernetes.io/instance=controlplane-test \
		-o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.namespace}{"|"}{.metadata.name}{"\n"}{end}' \
		2>/dev/null || true)"
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
	out_csv="${out_csv%,}"
	echo "${out_csv}|attempted=${attempted}|got=${got}"
}

aggregate_sample_bytes() {
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
# Scrape infrastructure.
# ---------------------------------------------------------------------------

scrape_one_context() {
	local ctx="$1" port="$2" out="$3" ts_start="$4" ts_end="$5"
	local body t_start t_end
	t_start=$(now_ms)
	body=$(curl -s "http://localhost:${port}/metrics" 2>/dev/null) || return 1
	t_end=$(now_ms)
	printf '%s' "$body" > "$out"
	printf '%s' "$t_start" > "$ts_start"
	printf '%s' "$t_end" > "$ts_end"
}

scrape_all_parallel() {
	local out_prefix="$1"
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

compute_skew_ms() {
	local prefix="$1"
	local min="" max="" t i
	for i in "${!CONTEXTS[@]}"; do
		local t_file="${prefix}-${i}.ts"
		[[ -s "$t_file" ]] || continue
		t=$(<"$t_file")
		[[ -z "$min" || "$t" -lt "$min" ]] && min="$t"
		[[ -z "$max" || "$t" -gt "$max" ]] && max="$t"
	done
	if [[ -n "$min" && -n "$max" ]]; then
		echo $(( max - min ))
	else
		echo 0
	fi
}

# ---------------------------------------------------------------------------
# Main scrape_window: baseline + final + deltas + emit TSV rows.
# ---------------------------------------------------------------------------

scrape_window() {
	local sleep_sec="$1"
	local skip_baseline="${2:-0}"
	local settle_input_sec="${3:-$sleep_sec}"
	local baseline_skew_ms final_skew_ms
	if (( skip_baseline )); then
		echo "  Baseline scrape: skipped (using pre-populated baseline from state-dir)."
		baseline_skew_ms=$(compute_skew_ms "${TMP_DIR}/baseline")
	else
		echo "  Baseline scrape..."
		baseline_skew_ms=$(scrape_all_parallel "${TMP_DIR}/baseline")
	fi
	if (( sleep_sec > 0 )); then
		echo "  Settling for ${sleep_sec}s..."
		sleep "$sleep_sec"
	fi
	echo "  Final scrape..."
	final_skew_ms=$(scrape_all_parallel "${TMP_DIR}/final")
	local total_skew_ms=$(( baseline_skew_ms > final_skew_ms ? baseline_skew_ms : final_skew_ms ))

	local b_max_ms="" f_min_ms="" ts_val
	for i in "${!CONTEXTS[@]}"; do
		local bt="${TMP_DIR}/baseline-${i}.tsend"
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
		window_sec=$(awk -v s="$settle_input_sec" 'BEGIN{ printf "%.1f", s+0 }')
	fi
	window_positive=$(awk -v w="$window_sec" 'BEGIN{ print (w+0 > 0) ? 1 : 0 }')

	local ts
	ts=$(date -u -Iseconds)

	for i in "${!CONTEXTS[@]}"; do
		ctx="${CONTEXTS[i]}"

		local b_file="${TMP_DIR}/baseline-${i}.metrics"
		local f_file="${TMP_DIR}/final-${i}.metrics"
		if [[ ! -s "$f_file" ]]; then
			echo "warning: no final scrape for $ctx; emitting N/A row" >&2
			echo -e "${ts}\t${ctx}\t${MESH_SIZE}\t${SERVICE_COUNT}\t${REPLICAS}\t${NAMESPACE_COUNT}\t${SIDECAR_SCOPING}\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t0\t0\t0\t0\t0\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t0/0\t${window_sec}\t${total_skew_ms}\t${settle_input_sec}\tunknown\tN/A" >> "$TSV_FILE"
			continue
		fi
		local baseline final
		baseline=$([[ -s "$b_file" ]] && cat "$b_file" || echo "")
		final=$(cat "$f_file")

		# Memory from process_resident_memory_bytes (gauge, bytes → MiB).
		local mem_mi
		mem_mi=$(extract_gauge_exact "$final" process_resident_memory_bytes)
		if [[ "$mem_mi" != "N/A" ]]; then
			mem_mi=$(awk -v b="$mem_mi" 'BEGIN{ printf "%.0f", b / 1048576 }')
		fi

		# Connected proxies (gauge — read from final scrape).
		local connected_proxies
		connected_proxies=$(extract_gauge_exact "$final" pilot_xds)

		# Restart detection (must run before delta computations so the
		# restart guard can protect counter/histogram columns — PL9/PL13).
		local b_pst f_pst istiod_restarted
		b_pst=$([[ -n "$baseline" ]] && extract_gauge_exact "$baseline" process_start_time_seconds || echo N/A)
		f_pst=$(extract_gauge_exact "$final" process_start_time_seconds)
		istiod_restarted=$(awk -v b="$b_pst" -v f="$f_pst" '
			BEGIN {
				if (b == "N/A" || f == "N/A") { print "unknown"; exit }
				print (f+0 > b+0) ? 1 : 0
			}')
		if [[ "$istiod_restarted" == "1" ]]; then
			echo "warning: istiod restart detected during scrape window on ${ctx} (process_start_time_seconds ${b_pst} -> ${f_pst})" >&2
		fi

		# Restart guard: when istiod restarted (or state is unknown), all
		# counter deltas, histogram quantiles, and derived rates are invalid
		# because the counters reset to zero mid-window (PL13).
		local restarted_or_unknown=0
		if [[ "$istiod_restarted" == "1" || "$istiod_restarted" == "unknown" ]]; then
			restarted_or_unknown=1
		fi

		# Delta-window histograms.
		local conv_p50 conv_p99 queue_p50 queue_p99
		if (( restarted_or_unknown )); then
			conv_p50="N/A"; conv_p99="N/A"; queue_p50="N/A"; queue_p99="N/A"
		else
			local conv_delta_text queue_delta_text
			conv_delta_text=$(delta_histogram "$baseline" "$final" "pilot_proxy_convergence_time")
			queue_delta_text=$(delta_histogram "$baseline" "$final" "pilot_proxy_queue_time")
			conv_p50=$(extract_histogram_quantile "$conv_delta_text" "pilot_proxy_convergence_time" "0.5")
			conv_p99=$(extract_histogram_quantile "$conv_delta_text" "pilot_proxy_convergence_time" "0.99")
			queue_p50=$(extract_histogram_quantile "$queue_delta_text" "pilot_proxy_queue_time" "0.5")
			queue_p99=$(extract_histogram_quantile "$queue_delta_text" "pilot_proxy_queue_time" "0.99")
		fi

		# Counter deltas (xds pushes + k8s events).
		local pushes_delta pushes_rate evts_delta evts_rate
		if (( restarted_or_unknown )); then
			pushes_delta="N/A"; pushes_rate="N/A"
			evts_delta="N/A"; evts_rate="N/A"
		else
			local b_pushes f_pushes
			b_pushes=$([[ -n "$baseline" ]] && extract_counter_sum "$baseline" pilot_xds_pushes || echo 0)
			f_pushes=$(extract_counter_sum "$final" pilot_xds_pushes)
			pushes_delta=$(( f_pushes - b_pushes ))
			(( pushes_delta < 0 )) && pushes_delta=0
			if (( window_positive )); then
				pushes_rate=$(awk -v d="$pushes_delta" -v w="$window_sec" 'BEGIN{ printf "%.2f", d/w }')
			else
				pushes_rate="N/A"
			fi

			local b_evts f_evts
			b_evts=$([[ -n "$baseline" ]] && extract_counter_sum "$baseline" pilot_k8s_cfg_events || echo 0)
			f_evts=$(extract_counter_sum "$final" pilot_k8s_cfg_events)
			evts_delta=$(( f_evts - b_evts ))
			(( evts_delta < 0 )) && evts_delta=0
			if (( window_positive )); then
				evts_rate=$(awk -v d="$evts_delta" -v w="$window_sec" 'BEGIN{ printf "%.2f", d/w }')
			else
				evts_rate="N/A"
			fi
		fi

		# Per-type xds_pushes deltas.
		local types=(cds eds lds rds nds)
		local push_by_type=()
		if (( restarted_or_unknown )); then
			push_by_type=("N/A" "N/A" "N/A" "N/A" "N/A")
		else
			for t in "${types[@]}"; do
				local b_t f_t d_t
				b_t=$([[ -n "$baseline" ]] && extract_counter_by_label "$baseline" pilot_xds_pushes type "$t" || echo 0)
				f_t=$(extract_counter_by_label "$final" pilot_xds_pushes type "$t")
				d_t=$(( f_t - b_t ))
				(( d_t < 0 )) && d_t=0
				push_by_type+=("$d_t")
			done
		fi

		# CPU delta (average millicores over window).
		local cpu_m_delta
		if (( restarted_or_unknown )); then
			cpu_m_delta="N/A"
		else
			local b_cpu_s f_cpu_s
			b_cpu_s=$([[ -n "$baseline" ]] && extract_gauge_exact "$baseline" process_cpu_seconds_total || echo N/A)
			f_cpu_s=$(extract_gauge_exact "$final" process_cpu_seconds_total)
			cpu_m_delta=$(awk -v b="$b_cpu_s" -v f="$f_cpu_s" -v w="$window_sec" '
				BEGIN {
					if (b == "N/A" || f == "N/A" || w+0 <= 0) { print "N/A"; exit }
					d = (f - b) * 1000 / w
					if (d < 0) { print "N/A"; exit }
					printf "%.0f", d
				}')
		fi

		# config_size: histogram, avg = (sum_delta / count_delta) bytes.
		local cs_avg
		if (( restarted_or_unknown )); then
			cs_avg="N/A"
		else
			local b_sum f_sum b_cnt f_cnt
			b_sum=$([[ -n "$baseline" ]] && extract_hist_sum "$baseline" pilot_xds_config_size_bytes || echo 0)
			f_sum=$(extract_hist_sum "$final" pilot_xds_config_size_bytes)
			b_cnt=$([[ -n "$baseline" ]] && extract_hist_count "$baseline" pilot_xds_config_size_bytes || echo 0)
			f_cnt=$(extract_hist_count "$final" pilot_xds_config_size_bytes)
			cs_avg=$(awk -v bs="$b_sum" -v fs="$f_sum" -v bc="$b_cnt" -v fc="$f_cnt" '
				BEGIN {
					ds = fs - bs; dc = fc - bc
					if (ds < 0) ds = 0
					if (dc <= 0) { print "N/A"; exit }
					printf "%.0f", ds/dc
				}')
		fi

		# Per-sidecar /config_dump sampling (only in final/combined phase).
		local cd_avg="N/A" cd_p50="N/A" cd_max="N/A" cd_samples="0/0"
		if (( CONFIG_DUMP_SAMPLES > 0 )); then
			local cd_out cd_csv cd_meta
			cd_out="$(collect_config_dump_samples "$ctx" "$CONFIG_DUMP_SAMPLES" || true)"
			cd_csv="${cd_out%%|*}"
			cd_meta="${cd_out#*|}"
			local attempted=0 got=0
			[[ "$cd_meta" =~ attempted=([0-9]+) ]] && attempted="${BASH_REMATCH[1]}"
			[[ "$cd_meta" =~ got=([0-9]+) ]] && got="${BASH_REMATCH[1]}"
			local agg
			agg="$(aggregate_sample_bytes "$cd_csv")"
			cd_avg="${agg%%|*}"
			cd_p50="$(echo "$agg" | awk -F'|' '{print $2}')"
			cd_max="$(echo "$agg" | awk -F'|' '{print $3}')"
			cd_samples="${got}/${attempted}"
		fi

		echo -e "${ts}\t${ctx}\t${MESH_SIZE}\t${SERVICE_COUNT}\t${REPLICAS}\t${NAMESPACE_COUNT}\t${SIDECAR_SCOPING}\t${mem_mi}\t${conv_p50}\t${conv_p99}\t${queue_p50}\t${queue_p99}\t${pushes_delta}\t${pushes_rate}\t${push_by_type[0]}\t${push_by_type[1]}\t${push_by_type[2]}\t${push_by_type[3]}\t${push_by_type[4]}\t${evts_delta}\t${evts_rate}\t${connected_proxies}\t${cs_avg}\t${cd_avg}\t${cd_p50}\t${cd_max}\t${cd_samples}\t${window_sec}\t${total_skew_ms}\t${settle_input_sec}\t${istiod_restarted}\t${cpu_m_delta}" >> "$TSV_FILE"
		echo "  Scraped $ctx: cpu_delta=${cpu_m_delta}m mem=${mem_mi}Mi proxies=${connected_proxies} pushes_delta=${pushes_delta} (eds=${push_by_type[1]} cds=${push_by_type[0]}) cfg_dump_avg=${cd_avg}"
	done
}

if ((WATCH)); then
	echo "Watch mode: ${INTERVAL}s window between baseline and final scrapes (Ctrl-C to stop)"
	while true; do
		echo ""
		echo "=== Window at $(date -u -Iseconds) ==="
		scrape_window "$INTERVAL"
	done
elif [[ "$PHASE" == baseline ]]; then
	echo ""
	echo "=== Baseline scrape only (phase=baseline) ==="
	echo "  Writing baseline metrics to $STATE_DIR"
	scrape_all_parallel "${STATE_DIR}/baseline" >/dev/null
	echo "  Baseline complete. Caller should now deploy workloads, settle, and"
	echo "  invoke this script again with --phase final --state-dir $STATE_DIR"
elif [[ "$PHASE" == final ]]; then
	echo ""
	echo "=== Final scrape + emit (phase=final) ==="
	echo "  Reading baseline from $STATE_DIR"
	for f in "${STATE_DIR}/baseline-"*; do
		[[ -e "$f" ]] || die "no baseline files in $STATE_DIR — run --phase baseline first"
		cp "$f" "${TMP_DIR}/$(basename "$f")"
	done
	scrape_window 0 1 "$SETTLE_SEC"
	echo ""
	echo "Results appended to $TSV_FILE"
else
	echo ""
	echo "=== Scraping control-plane metrics (phase=combined, window=${SETTLE_SEC}s) ==="
	scrape_window "$SETTLE_SEC"
	echo ""
	echo "Results appended to $TSV_FILE"
fi

# Generate per-run MD summary.
if [[ "$PHASE" == combined || "$PHASE" == final ]]; then
	MD_FILE="${OUTPUT_DIR}/controlplane-${RUN_ID}.md"
	{
		echo "# Control-Plane Resource Metrics"
		echo ""
		echo "| Field | Value |"
		echo "|-------|-------|"
		echo "| Run ID | \`${RUN_ID}\` |"
		echo "| Date | $(date -u -Iseconds) |"
		echo "| Phase | ${PHASE} |"
		echo "| Istio version | ${ISTIO_VERSION_TAG} |"
		echo "| Harness SHA | ${HARNESS_SHA} |"
		echo "| Kube versions | ${KUBE_VERSIONS_CSV} |"
		echo "| Contexts | ${CONTEXTS[*]} |"
		echo "| Mesh size | ${MESH_SIZE} |"
		echo "| Service count | ${SERVICE_COUNT} |"
		echo "| Replicas | ${REPLICAS} |"
		echo "| Namespace count | ${NAMESPACE_COUNT} |"
		echo "| Sidecar scoping | ${SIDECAR_SCOPING} |"
		echo "| Config-dump samples | ${CONFIG_DUMP_SAMPLES} |"
		echo "| Settle (s) | ${SETTLE_SEC} |"
		echo ""
		echo "## Summary"
		echo ""
		echo "| Context | mesh | svc | reps | ns | scoping | CPU avg (m) | Mem (Mi) | Conv p99 (ms) | Queue p99 (ms) | Proxies | Pushes Δ | EDS Δ | CDS Δ | Cfg dump avg |"
		echo "|---------|------|-----|------|----|---------|-------------|----------|---------------|----------------|---------|----------|-------|-------|--------------|"
		awk -F'\t' '!/^#/ && !/^timestamp/ && NF>=32 {
			printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $2, $3, $4, $5, $6, $7, $32, $8, $10, $12, $22, $13, $16, $15, $24
		}' "$TSV_FILE"
		echo ""
		echo "## Raw Data"
		echo ""
		echo "TSV: [\`$(basename "$TSV_FILE")\`]($(basename "$TSV_FILE"))"
	} > "$MD_FILE"
	echo "Summary written to $MD_FILE"
fi

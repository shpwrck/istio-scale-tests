#!/usr/bin/env bash
# Measure intra-cluster (sidecar-to-sidecar) and cross-cluster data-plane
# latency and throughput using fortio.
#
# Local baseline target:    http://dataplane-server-${source_ctx}.${NS}.svc.cluster.local
# Cross-cluster targets:    http://dataplane-server-${remote_ctx}.${NS}.svc.cluster.local
# Each per-cluster Service selects only that cluster's server pod, so the local
# target stays in-cluster and remote targets cross the east-west gateway.
#
# Each cell is a single sample. Rerun the sweep to get multiple samples.
# The local baseline is NOT a no-mesh baseline: both endpoints have sidecars.
#
# Usage:
#   ./tests/dataplane/002-run-latency-probe.sh --source-context CTX [options]
#
# Examples:
#   # Baseline + cross-cluster latency:
#   ./tests/dataplane/002-run-latency-probe.sh --source-context <mesh-a-ctx> --remote-contexts <mesh-b-ctx>
#
#   # Custom QPS levels and duration:
#   ./tests/dataplane/002-run-latency-probe.sh --source-context <mesh-a-ctx> \
#     --remote-contexts <mesh-b-ctx> --qps-levels 10,100,1000 --duration 60
# ci-dry-run: --source-context ci-dummy
set -euo pipefail
# Loud ERR trap for unexpected aborts.
trap 'rc=$?; echo "FATAL: ${0##*/} aborted (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/timestamp.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/metrics.sh"  # extract_gauge (used by fanout_restart_status)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fanout.sh"

SOURCE_CTX=""
REMOTE_CONTEXTS_CSV=""
MESH_SIZE=""
QPS_LEVELS="${DATAPLANE_QPS_LEVELS:-10,100,500,1000}"
DURATION="${DATAPLANE_DURATION_SEC:-30}"
CONNECTIONS="${DATAPLANE_NUM_CONNECTIONS:-8}"
SETTLE_SEC="${DATAPLANE_SETTLE_SEC:-30}"
WARMUP_DURATION="${DATAPLANE_WARMUP_DURATION_SEC:-5}"
OUTPUT_DIR="${ROOT}/tests/dataplane/results"
DRY_RUN=0
# Live tuning-baseline provenance; 003 passes it in, standalone runs record "unknown".
TUNING_BASELINE="unknown"
SIDECAR_EGRESS_HOSTS="unknown"
NS="${DATAPLANE_TEST_NAMESPACE:-dataplane-test}"
FORTIO_TAG="$FORTIO_VERSION"
FORTIO_IMAGE_REPO="fortio/fortio"


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --source-context CTX     Kube context for the fortio client (required).
  --remote-contexts CSV    Remote cluster contexts (comma-separated).
  --mesh-size N            Metadata tag for TSV (default: 1 + remotes).
  --qps-levels CSV         QPS levels to test (default: $QPS_LEVELS).
  --duration SEC           Duration per QPS level (default: $DURATION).
  --connections N          Concurrent connections (default: $CONNECTIONS).
  --settle SEC             Seconds to sleep before probing (default: $SETTLE_SEC).
  --warmup-duration SEC    Envoy upstream warmup duration, 0 to disable (default: $WARMUP_DURATION).
  --output-dir DIR         Results directory (default: tests/dataplane/results).
  --tuning-baseline STR    Live tuning-baseline levers for the TSV preamble
                           (default: unknown; the sweep queries + threads this).
  --sidecar-egress-hosts STR  Live root-Sidecar egress hosts for the TSV preamble
                           (default: unknown; the sweep queries + threads this).
  --dry-run                Show plan without executing.
  -h, --help               Show this help.

istiod restarts are detected on every context by port-forwarding each Running
istiod pod before and after the load runs (process_start_time_seconds or a
changed pod set -> istiod_restarted=1 on every row).

Environment:
  DATAPLANE_TEST_NAMESPACE, DATAPLANE_QPS_LEVELS, DATAPLANE_DURATION_SEC,
  DATAPLANE_NUM_CONNECTIONS, DATAPLANE_SETTLE_SEC, DATAPLANE_WARMUP_DURATION_SEC,
  FORTIO_VERSION, METRICS_SCRAPE_TIMEOUT (istiod /metrics curl timeout, default 30).
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
		[[ "$2" =~ ^[0-9]+$ ]] || die "--mesh-size must be a non-negative integer"
		MESH_SIZE="$2"
		shift 2
		;;
	--qps-levels)
		[[ -n "${2:-}" ]] || die "--qps-levels requires a value"
		QPS_LEVELS="$2"
		shift 2
		;;
	--duration)
		[[ -n "${2:-}" ]] || die "--duration requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--duration must be a positive integer"
		(( $2 > 0 )) || die "--duration must be > 0"
		DURATION="$2"
		shift 2
		;;
	--connections)
		[[ -n "${2:-}" ]] || die "--connections requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--connections must be a positive integer"
		(( $2 > 0 )) || die "--connections must be > 0"
		CONNECTIONS="$2"
		shift 2
		;;
	--settle)
		[[ -n "${2:-}" ]] || die "--settle requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--settle must be a non-negative integer"
		SETTLE_SEC="$2"
		shift 2
		;;
	--warmup-duration)
		[[ -n "${2:-}" ]] || die "--warmup-duration requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--warmup-duration must be a non-negative integer"
		WARMUP_DURATION="$2"
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

KUBECTL=()
resolve_kubectl KUBECTL
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
command -v curl >/dev/null 2>&1 || die "curl not found on PATH"

REMOTES=()
if [[ -n "$REMOTE_CONTEXTS_CSV" ]]; then
	split_csv "$REMOTE_CONTEXTS_CSV" REMOTES
fi

QPS_ARR=()
split_csv "$QPS_LEVELS" QPS_ARR
((${#QPS_ARR[@]})) || die "--qps-levels resolved to empty list"
for q in "${QPS_ARR[@]}"; do
	[[ "$q" =~ ^[0-9]+$ ]] || die "qps level must be a positive integer: $q"
	(( q > 0 )) || die "qps level must be > 0: $q"
done

[[ -z "$MESH_SIZE" ]] && MESH_SIZE=$(( 1 + ${#REMOTES[@]} ))

ALL_CTXS=("$SOURCE_CTX" "${REMOTES[@]}")
LOCAL_URL="http://dataplane-server-${SOURCE_CTX}.${NS}.svc.cluster.local:8080/echo"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
TSV_FILE="${OUTPUT_DIR}/latency-${RUN_ID}.tsv"

# Resolve metadata for preamble.
HARNESS_SHA=$(git -C "$ROOT" describe --always --dirty --abbrev=7 2>/dev/null || echo "unknown")
ISTIO_VER="${ISTIO_VERSION:-unknown}"
FORTIO_IMAGE="${FORTIO_IMAGE_REPO}:${FORTIO_TAG}"

if ((DRY_RUN)); then
	echo "=== Dry-run: data-plane latency probe ==="
	echo "Source: $SOURCE_CTX | Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
	echo "QPS levels: ${QPS_ARR[*]} | Duration: ${DURATION}s | Connections: $CONNECTIONS | Settle: ${SETTLE_SEC}s"
	echo "Local target:        ${LOCAL_URL}"
	for rc in "${REMOTES[@]}"; do
		echo "Cross-cluster target ($rc): http://dataplane-server-${rc}.${NS}.svc.cluster.local:8080/echo"
	done
	echo "istiod restart check: port-forward every Running istiod pod on: ${ALL_CTXS[*]}"
	exit 0
fi

mkdir -p "$OUTPUT_DIR"
KUBE_VERSIONS_CSV="$(probe_kube_versions "$(IFS=,; echo "${ALL_CTXS[*]}")" "${KUBECTL[@]}")"

PF_PIDS=()
ISTIOD_DIR="$(mktemp -d)"
cleanup_all() {
	local pid
	for pid in "${PF_PIDS[@]}"; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	rm -rf "$ISTIOD_DIR"
}
trap cleanup_all EXIT

# Write TSV preamble.
{
	echo "# RUN_ID=${RUN_ID}"
	echo "# DATE=$(date -u -Iseconds)"
	echo "# HARNESS_SHA=${HARNESS_SHA}"
	echo "# ISTIO_VERSION=${ISTIO_VER}"
	echo "# KUBE_VERSIONS=${KUBE_VERSIONS_CSV}"
	echo "# FORTIO_IMAGE=${FORTIO_IMAGE}"
	echo "# SETTLE_SEC=${SETTLE_SEC}"
	echo "# WARMUP_DURATION_SEC=${WARMUP_DURATION}"
	echo "# QPS_LEVELS=${QPS_LEVELS}"
	echo "# DURATION_SEC=${DURATION}"
	echo "# CONNECTIONS=${CONNECTIONS}"
	echo "# SOURCE_CTX=${SOURCE_CTX}"
	echo "# REMOTE_CONTEXTS=${REMOTE_CONTEXTS_CSV}"
	echo "# MESH_SIZE=${MESH_SIZE}"
	echo "# NAMESPACE=${NS}"
	echo "# TUNING_BASELINE=${TUNING_BASELINE}"
	echo "# SIDECAR_EGRESS_HOSTS=${SIDECAR_EGRESS_HOSTS}"
} > "$TSV_FILE"
# New TSV columns appended at the end of the old schema:
#   pct_200, istiod_restarted, target_class
printf 'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class\n' >> "$TSV_FILE"

CLIENT_POD=$("${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" get pod -l app=dataplane-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) \
	|| die "no client pod found on $SOURCE_CTX"

echo "=== Data-plane latency probe ==="
echo "Source: $SOURCE_CTX (pod: $CLIENT_POD)"
echo "Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
echo "QPS levels: ${QPS_ARR[*]} | Duration: ${DURATION}s | Connections: $CONNECTIONS"
echo "Settle: ${SETTLE_SEC}s | Fortio image: ${FORTIO_IMAGE}"
echo ""

# istiod restart detection on every context: one port-forward per Running istiod
# pod (tests/lib/fanout.sh). fanout_open dies if no pod on a context serves
# /metrics; a context with no Running istiod pod leaves the result "unknown".
declare -A CTX_PORTS=() CTX_PODS=()
for i in "${!ALL_CTXS[@]}"; do
	ctx="${ALL_CTXS[$i]}"
	if [[ -z "$(fanout_list_istiod_pods "$ctx" "${KUBECTL[@]}")" ]]; then
		echo "warning: no Running istiod pod on $ctx; istiod_restarted will be unknown" >&2
		continue
	fi
	# Out-array names must not collide with fanout_open's own locals (ports/pods).
	fo_ports=(); fo_pods=()
	fanout_open "$ctx" "$i" PF_PIDS fo_ports fo_pods "${KUBECTL[@]}"
	CTX_PORTS["$i"]="${fo_ports[*]}"
	CTX_PODS["$i"]="${fo_pods[*]}"
done

# snapshot_istiod <pre|post>: record each context's pod set and scrape every pod.
# The pre pod set is the scraped pods; post is every Running pod, so a replaced
# or added pod shows up as a pod-set change.
snapshot_istiod() {
	local phase="$1" i
	local -a snap_ports=() snap_pods=()
	for i in "${!ALL_CTXS[@]}"; do
		[[ -n "${CTX_PORTS[$i]:-}" ]] || continue
		read -ra snap_ports <<<"${CTX_PORTS[$i]}"
		read -ra snap_pods <<<"${CTX_PODS[$i]}"
		if [[ "$phase" == pre ]]; then
			printf '%s\n' "${snap_pods[@]}" > "${ISTIOD_DIR}/${phase}-c${i}.podset"
		else
			fanout_record_podset "${ALL_CTXS[$i]}" "${ISTIOD_DIR}/${phase}-c${i}.podset" "${KUBECTL[@]}"
		fi
		fanout_scrape_all "$ISTIOD_DIR" "${phase}-c${i}" "${snap_ports[@]}" >/dev/null || true
	done
}

# ctx_restart_status <ctx_index>: 0 | 1 | unknown for one context.
ctx_restart_status() {
	local i="$1" j pre_csv="" post_csv=""
	local -a st_pods=()
	[[ -n "${CTX_PODS[$i]:-}" ]] || { echo unknown; return 0; }
	read -ra st_pods <<<"${CTX_PODS[$i]}"
	for j in "${!st_pods[@]}"; do
		pre_csv+="${pre_csv:+,}${ISTIOD_DIR}/pre-c${i}-${j}.metrics"
		post_csv+="${post_csv:+,}${ISTIOD_DIR}/post-c${i}-${j}.metrics"
	done
	fanout_restart_status "${ISTIOD_DIR}/pre-c${i}.podset" "${ISTIOD_DIR}/post-c${i}.podset" \
		"$pre_csv" "$post_csv"
}

if ((SETTLE_SEC > 0)); then
	echo "Settling for ${SETTLE_SEC}s to allow xDS endpoint propagation..."
	sleep "$SETTLE_SEC"
fi

if ((WARMUP_DURATION > 0)); then
	echo "Warming Envoy upstream connection pools (${WARMUP_DURATION}s at QPS=10)..."
	WARMUP_URLS=("$LOCAL_URL")
	for rc in "${REMOTES[@]}"; do
		WARMUP_URLS+=("http://dataplane-server-${rc}.${NS}.svc.cluster.local:8080/echo")
	done
	for wurl in "${WARMUP_URLS[@]}"; do
		echo "  warmup -> $wurl"
		"${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" exec "$CLIENT_POD" -c fortio -- \
			fortio load -qps 10 -c "$CONNECTIONS" -t "${WARMUP_DURATION}s" -quiet "$wurl" \
			>/dev/null 2>&1 || echo "  warn: warmup failed for $wurl" >&2
	done
	echo ""
fi

snapshot_istiod pre

# Extract a percentile latency in ms from fortio JSON, tolerating floating-point
# representations of the percentile target (e.g. 50 vs 50.0). Emits "N/A" if no
# entry within tolerance is found.
extract_percentile_ms() {
	local json="$1" pct="$2"
	echo "$json" | jq -r --argjson p "$pct" '
		.DurationHistogram.Percentiles
		| (map(select((.Percentile - $p) | fabs < 0.01)) | .[0])
		| if . == null then "N/A" else (.Value * 1000 | tostring) end
	' 2>/dev/null || echo "N/A"
}

run_fortio() {
	local target_ctx="$1" target_url="$2" target_class="$3"
	for qps in "${QPS_ARR[@]}"; do
		echo "  QPS=$qps -> $target_url"
		local json_output
		json_output=$("${KUBECTL[@]}" --context="$SOURCE_CTX" -n "$NS" exec "$CLIENT_POD" -c fortio -- \
			fortio load -qps "$qps" -c "$CONNECTIONS" -t "${DURATION}s" -p '50,90,99,99.9' \
			-json - -quiet "$target_url" 2>/dev/null) || {
			echo "    FAILED"
			printf '%s\t%s\t%s\t%s\t%s\t0\t%s\t%s\t0\t0\t0\t0\t0\tFAILED\tN/A\t%s\t%s\n' \
				"$RUN_ID" "$MESH_SIZE" "$SOURCE_CTX" "$target_ctx" "$qps" \
				"$CONNECTIONS" "$DURATION" "${ISTIOD_RESTARTED_TAG:-unknown}" "$target_class" >> "$TSV_FILE"
			continue
		}

		local qps_actual p50 p90 p99 p999 max_lat pct_200 total_ok status
		qps_actual=$(echo "$json_output" | jq -r '.ActualQPS // 0' 2>/dev/null || echo 0)
		p50=$(extract_percentile_ms "$json_output" 50)
		p90=$(extract_percentile_ms "$json_output" 90)
		p99=$(extract_percentile_ms "$json_output" 99)
		p999=$(extract_percentile_ms "$json_output" 99.9)
		max_lat=$(echo "$json_output" | jq -r '(.DurationHistogram.Max // 0) * 1000' 2>/dev/null || echo 0)

		# Compute fraction of HTTP 200 responses from RetCodes.
		# RetCodes is an object like {"200": 1234, "503": 5}.
		pct_200=$(echo "$json_output" | jq -r '
			(.RetCodes // {})
			| (to_entries | map(.value) | add) as $total
			| (.["200"] // 0) as $ok
			| if ($total // 0) == 0 then "N/A"
			  else ($ok / $total * 1.0 | tostring) end
		' 2>/dev/null || echo "N/A")

		# Track total responses for sanity.
		total_ok=$(echo "$json_output" | jq -r '(.RetCodes // {}) | (to_entries | map(.value) | add) // 0' 2>/dev/null || echo 0)

		# Determine status.
		status="OK"
		if [[ "$p50" == "N/A" || "$p90" == "N/A" || "$p99" == "N/A" || "$p999" == "N/A" ]]; then
			status="PERCENTILE_MISSING"
		elif [[ "$pct_200" != "N/A" ]] && awk "BEGIN { exit !($pct_200 < 0.99) }"; then
			status="ERROR_RATE_HIGH"
		elif [[ "$total_ok" == "0" ]]; then
			status="ERROR_RATE_HIGH"
		fi

		# Pretty print (numeric values may be "N/A"; tolerate that).
		printf "    actual_qps=%s p50=%sms p99=%sms max=%sms pct_200=%s status=%s\n" \
			"$qps_actual" "$p50" "$p99" "$max_lat" "$pct_200" "$status"
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$RUN_ID" "$MESH_SIZE" "$SOURCE_CTX" "$target_ctx" "$qps" "$qps_actual" \
			"$CONNECTIONS" "$DURATION" "$p50" "$p90" "$p99" "$p999" "$max_lat" \
			"$status" "$pct_200" "${ISTIOD_RESTARTED_TAG:-unknown}" "$target_class" >> "$TSV_FILE"
	done
}

# We can't know the final ISTIOD_RESTARTED until after both probes finish.
# Placeholder during execution; we rewrite all rows in one pass at the end.
ISTIOD_RESTARTED_TAG="pending"

echo "--- Local baseline (intra-cluster, sidecar-to-sidecar) ---"
run_fortio "$SOURCE_CTX" "$LOCAL_URL" "local"

for remote_ctx in "${REMOTES[@]}"; do
	echo ""
	echo "--- Cross-cluster: $SOURCE_CTX -> $remote_ctx ---"
	run_fortio "$remote_ctx" "http://dataplane-server-${remote_ctx}.${NS}.svc.cluster.local:8080/echo" "remote"
done

snapshot_istiod post

# istiod_restarted for the run: 1 if any context restarted, else unknown if any
# context could not be measured, else 0.
ISTIOD_RESTARTED="0"
declare -A CTX_RESTARTED=()
for i in "${!ALL_CTXS[@]}"; do
	CTX_RESTARTED["$i"]="$(ctx_restart_status "$i")"
	case "${CTX_RESTARTED[$i]}" in
	1) ISTIOD_RESTARTED="1"; echo "warning: istiod restarted on ${ALL_CTXS[$i]} during probe" >&2 ;;
	unknown) [[ "$ISTIOD_RESTARTED" == "1" ]] || ISTIOD_RESTARTED="unknown" ;;
	esac
done

# Rewrite the istiod_restarted column (penultimate) for all data rows.
tmp_tsv=$(mktemp "${TSV_FILE}.XXXXXX")
awk -F'\t' -v OFS='\t' -v r="$ISTIOD_RESTARTED" '
	/^#/ { print; next }
	/^run_id\t/ { print; next }
	NF >= 17 { $16 = r; print; next }
	{ print }
' "$TSV_FILE" > "$tmp_tsv"
mv "$tmp_tsv" "$TSV_FILE"

echo ""
for i in "${!ALL_CTXS[@]}"; do
	echo "istiod_restarted[${ALL_CTXS[$i]}]: ${CTX_RESTARTED[$i]}"
done
echo "istiod_restarted (aggregate): ${ISTIOD_RESTARTED}"
echo "Results written to $TSV_FILE"

MD_FILE="${OUTPUT_DIR}/latency-${RUN_ID}.md"
{
	echo "# Data-Plane Latency Results"
	echo ""
	echo "| Field | Value |"
	echo "|-------|-------|"
	echo "| Run ID | \`${RUN_ID}\` |"
	echo "| Date | $(date -u -Iseconds) |"
	echo "| Harness SHA | \`${HARNESS_SHA}\` |"
	echo "| Istio version | ${ISTIO_VER} |"
	echo "| Fortio image | \`${FORTIO_IMAGE}\` |"
	echo "| Source | ${SOURCE_CTX} |"
	echo "| Remotes | ${REMOTES[*]:-none} |"
	echo "| Mesh size | ${MESH_SIZE} |"
	echo "| QPS levels | ${QPS_ARR[*]} |"
	echo "| Duration | ${DURATION}s |"
	echo "| Connections | ${CONNECTIONS} |"
	echo "| Settle | ${SETTLE_SEC}s |"
	echo "| Warmup | ${WARMUP_DURATION}s |"
	echo "| istiod_restarted | ${ISTIOD_RESTARTED} |"
	echo ""
	echo "Note: the local baseline is intra-cluster (sidecar-to-sidecar), NOT a no-mesh baseline."
	echo ""
	echo "## Summary"
	echo ""
	echo "| Target | Class | QPS Target | QPS Actual | p50 (ms) | p90 (ms) | p99 (ms) | p99.9 (ms) | Max (ms) | pct_200 | Status |"
	echo "|--------|-------|------------|------------|----------|----------|----------|------------|----------|---------|--------|"
	awk -F'\t' '!/^#/ && !/^run_id/ && NF>=17 {
		printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $4, $17, $5, $6, $9, $10, $11, $12, $13, $15, $14
	}' "$TSV_FILE"
	echo ""
	echo "## Raw Data"
	echo ""
	echo "TSV: [\`$(basename "$TSV_FILE")\`]($(basename "$TSV_FILE"))"
} > "$MD_FILE"
echo "Summary written to $MD_FILE"

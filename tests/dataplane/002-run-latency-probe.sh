#!/usr/bin/env bash
# Measure intra-cluster (sidecar-to-sidecar) and cross-cluster data-plane
# latency and throughput using fortio.
#
# Local baseline targets:   http://dataplane-server.${NS}.svc.cluster.local
# Cross-cluster targets:    http://dataplane-server-${remote_ctx}.${NS}.svc.cluster.local
# The per-cluster Service forces traffic through the east-west gateway because
# the source cluster has no local endpoint matching that selector.
#
# Each cell is a single sample. Rerun the sweep to get multiple samples.
# The local baseline is NOT a no-mesh baseline — both endpoints have sidecars.
#
# Usage:
#   ./tests/dataplane/002-run-latency-probe.sh --source-context CTX [options]
#
# Examples:
#   # Baseline + cross-cluster latency:
#   ./tests/dataplane/002-run-latency-probe.sh --source-context rosa-001 --remote-contexts rosa-002
#
#   # Custom QPS levels and duration:
#   ./tests/dataplane/002-run-latency-probe.sh --source-context rosa-001 \
#     --remote-contexts rosa-002 --qps-levels 10,100,1000 --duration 60
# ci-dry-run: --source-context ci-dummy
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

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
NS="${DATAPLANE_TEST_NAMESPACE:-dataplane-test}"
FORTIO_TAG="${FORTIO_VERSION:-stable}"
FORTIO_IMAGE_REPO="fortio/fortio"

die() { echo "error: $*" >&2; exit 1; }

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
  --dry-run                Show plan without executing.
  -h, --help               Show this help.

Environment:
  DATAPLANE_TEST_NAMESPACE, DATAPLANE_QPS_LEVELS, DATAPLANE_DURATION_SEC,
  DATAPLANE_NUM_CONNECTIONS, DATAPLANE_SETTLE_SEC, DATAPLANE_WARMUP_DURATION_SEC,
  FORTIO_VERSION.
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

command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

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

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$OUTPUT_DIR"
TSV_FILE="${OUTPUT_DIR}/latency-${RUN_ID}.tsv"

# Resolve metadata for preamble.
HARNESS_SHA=$(git -C "$ROOT" describe --always --dirty --abbrev=7 2>/dev/null || echo "unknown")
ISTIO_VER="${ISTIO_VERSION:-unknown}"
FORTIO_IMAGE="${FORTIO_IMAGE_REPO}:${FORTIO_TAG}"

if ((DRY_RUN)); then
	echo "=== Dry-run: data-plane latency probe ==="
	echo "Source: $SOURCE_CTX | Remotes: ${REMOTES[*]:-none} | Mesh size: $MESH_SIZE"
	echo "QPS levels: ${QPS_ARR[*]} | Duration: ${DURATION}s | Connections: $CONNECTIONS | Settle: ${SETTLE_SEC}s"
	echo "Local target:        http://dataplane-server.${NS}.svc.cluster.local:8080/echo"
	for rc in "${REMOTES[@]}"; do
		echo "Cross-cluster target ($rc): http://dataplane-server-${rc}.${NS}.svc.cluster.local:8080/echo"
	done
	exit 0
fi

# Resolve per-context server Kubernetes version concurrently (~5s budget each).
declare -A KUBE_VERSIONS
ISTIOD_PF_BASE_PORT="${DATAPLANE_ISTIOD_PF_PORT:-15014}"
declare -A PF_PIDS
declare -A ISTIOD_PF_PORTS
KV_TMPDIR=$(mktemp -d)
cleanup_all() {
	for pid in "${PF_PIDS[@]}"; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	rm -rf "$KV_TMPDIR"
}
trap cleanup_all EXIT
for ctx in "${ALL_CTXS[@]}"; do
	(
		v=$("${KUBECTL[@]}" --context="$ctx" version --request-timeout=5s -o json 2>/dev/null \
			| jq -r '.serverVersion.gitVersion // empty' 2>/dev/null) || v=""
		[[ -z "$v" ]] && v="unreachable"
		# shellcheck disable=SC2154
		printf '%s\n' "$v" > "${KV_TMPDIR}/${ctx}.kv"
	) &
done
wait
for ctx in "${ALL_CTXS[@]}"; do
	KUBE_VERSIONS["$ctx"]="$(cat "${KV_TMPDIR}/${ctx}.kv" 2>/dev/null || echo unreachable)"
done

# Write TSV preamble.
{
	echo "# RUN_ID=${RUN_ID}"
	echo "# DATE=$(date -u -Iseconds)"
	echo "# HARNESS_SHA=${HARNESS_SHA}"
	echo "# ISTIO_VERSION=${ISTIO_VER}"
	for ctx in "${ALL_CTXS[@]}"; do
		echo "# KUBE_VERSION[${ctx}]=${KUBE_VERSIONS[$ctx]}"
	done
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

# Start istiod port-forwards for restart-detection scrapes (all clusters).
declare -A ISTIOD_PF_OK
start_istiod_pf() {
	local ctx="$1" port="$2"
	"${KUBECTL[@]}" --context="$ctx" -n istio-system port-forward svc/istiod "${port}":15014 >/dev/null 2>&1 &
	PF_PIDS["$ctx"]=$!
	ISTIOD_PF_PORTS["$ctx"]="$port"
	local attempts=0
	while ! curl -fsS --max-time 2 "http://localhost:${port}/metrics" -o /dev/null 2>/dev/null; do
		attempts=$((attempts + 1))
		if ((attempts > 30)); then
			echo "warn: istiod port-forward for $ctx did not come up" >&2
			return 1
		fi
		sleep 0.5
	done
	return 0
}
for i in "${!ALL_CTXS[@]}"; do
	ctx="${ALL_CTXS[$i]}"
	port=$((ISTIOD_PF_BASE_PORT + i))
	if start_istiod_pf "$ctx" "$port"; then
		ISTIOD_PF_OK["$ctx"]=1
	else
		ISTIOD_PF_OK["$ctx"]=0
	fi
done

sample_istiod_start_for() {
	local ctx="$1"
	(( ${ISTIOD_PF_OK[$ctx]:-0} )) || { echo ""; return; }
	local port="${ISTIOD_PF_PORTS[$ctx]}"
	curl -sf --max-time 5 "http://localhost:${port}/metrics" 2>/dev/null \
		| awk '/^process_start_time_seconds[[:space:]{]/ && !/^#/ { print $NF; exit }'
}

if ((SETTLE_SEC > 0)); then
	echo "Settling for ${SETTLE_SEC}s to allow xDS endpoint propagation..."
	sleep "$SETTLE_SEC"
fi

if ((WARMUP_DURATION > 0)); then
	echo "Warming Envoy upstream connection pools (${WARMUP_DURATION}s at QPS=10)..."
	WARMUP_URLS=("http://dataplane-server.${NS}.svc.cluster.local:8080/echo")
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

declare -A ISTIOD_START_BEFORE
for ctx in "${ALL_CTXS[@]}"; do
	ISTIOD_START_BEFORE["$ctx"]=$(sample_istiod_start_for "$ctx" || true)
	[[ -z "${ISTIOD_START_BEFORE[$ctx]}" ]] && echo "warning: could not sample istiod process_start_time_seconds (pre-probe) on $ctx" >&2
done

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
run_fortio "$SOURCE_CTX" "http://dataplane-server.${NS}.svc.cluster.local:8080/echo" "local"

for remote_ctx in "${REMOTES[@]}"; do
	echo ""
	echo "--- Cross-cluster: $SOURCE_CTX -> $remote_ctx ---"
	run_fortio "$remote_ctx" "http://dataplane-server-${remote_ctx}.${NS}.svc.cluster.local:8080/echo" "remote"
done

declare -A ISTIOD_START_AFTER
for ctx in "${ALL_CTXS[@]}"; do
	ISTIOD_START_AFTER["$ctx"]=$(sample_istiod_start_for "$ctx" || true)
	[[ -z "${ISTIOD_START_AFTER[$ctx]}" ]] && echo "warning: could not sample istiod process_start_time_seconds (post-probe) on $ctx" >&2
done

# Compute istiod_restarted: "1" if any cluster's start time advanced; "0" if all
# are equal; "unknown" if any sample is missing.
ISTIOD_RESTARTED="0"
for ctx in "${ALL_CTXS[@]}"; do
	before="${ISTIOD_START_BEFORE[$ctx]:-}"
	after="${ISTIOD_START_AFTER[$ctx]:-}"
	if [[ -z "$before" || -z "$after" ]]; then
		ISTIOD_RESTARTED="unknown"
		break
	elif awk "BEGIN { exit !(($after) > ($before)) }"; then
		ISTIOD_RESTARTED="1"
		echo "warning: istiod restarted on $ctx during probe" >&2
		break
	fi
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
for ctx in "${ALL_CTXS[@]}"; do
	echo "istiod_restarted[$ctx]: start_before=${ISTIOD_START_BEFORE[$ctx]:-N/A} start_after=${ISTIOD_START_AFTER[$ctx]:-N/A}"
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
	echo "At mesh_size > 1, the local baseline includes istiod overhead from managing the full multi-cluster mesh."
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

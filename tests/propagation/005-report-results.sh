#!/usr/bin/env bash
# Post-process propagation test TSV files into summary statistics.
# Groups results by mesh_size to compare propagation latency across cluster counts.
#
# Filters out rows where restarted=1 or p1_overflow=1 (those rows are statistically
# unsafe). Reports both n_total (rows considered) and n_valid (rows used).
#
# Carries forward TSV preamble metadata (RUN_ID, HARNESS_SHA, ISTIO_VERSION,
# KUBE_VERSIONS, SETTLE_SEC, POLL_INTERVAL_S, TIMEOUT_SEC, ITERATIONS) into all
# report formats.
#
# Usage:
#   ./tests/propagation/005-report-results.sh [--results-dir DIR] [--format text|csv|json|markdown]
#
# Examples:
#   # Default text report from all results:
#   ./tests/propagation/005-report-results.sh
#
#   # CSV output:
#   ./tests/propagation/005-report-results.sh --format csv
#
#   # Specific results directory:
#   ./tests/propagation/005-report-results.sh --results-dir tests/propagation/results
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

RESULTS_DIR="${ROOT}/tests/propagation/results"
FORMAT="text"

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --results-dir DIR  Results directory (default: tests/propagation/results).
  --format FMT       Output format: text, csv, json, markdown (default: text).
  -h, --help         Show this help.

Columns emitted:
  P1: includes wall-clock p1_ms plus delta-window p1_conv_p50_ms / p1_conv_p99_ms.
  P2: pilot_xds_pushes{type="eds"} counter-delta detection (ms).
  P3: watcher Envoy /clusters detection (ms).
  n_total / n_valid: rows considered vs rows used after filtering restarted=1 and overflow=1.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--results-dir)
		[[ -n "${2:-}" ]] || die "--results-dir requires a value"
		RESULTS_DIR="$2"
		shift 2
		;;
	--format)
		[[ -n "${2:-}" ]] || die "--format requires a value"
		FORMAT="$2"
		shift 2
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

[[ -d "$RESULTS_DIR" ]] || die "results directory not found: $RESULTS_DIR"

ENDPOINT_FILES=()
while IFS= read -r f; do
	ENDPOINT_FILES+=("$f")
done < <(find "$RESULTS_DIR" -name 'endpoint-*.tsv' -type f 2>/dev/null | sort)

if [[ ${#ENDPOINT_FILES[@]} -eq 0 ]]; then
	die "no TSV result files found in $RESULTS_DIR"
fi

# ---- preamble metadata: collect across all files (last value wins per key) ----
declare -A PREAMBLE=()
PREAMBLE_KEYS=(RUN_ID HARNESS_SHA ISTIO_VERSION KUBE_VERSIONS SOURCE_CTX REMOTES MESH_SIZE ITERATIONS POLL_INTERVAL_S TIMEOUT_SEC SETTLE_SEC DATE)
for f in "${ENDPOINT_FILES[@]}"; do
	while IFS= read -r line; do
		case "$line" in
			'# '*)
				kv="${line#\# }"
				key="${kv%%=*}"
				val="${kv#*=}"
				[[ "$key" == "$kv" ]] && continue
				PREAMBLE["$key"]="$val"
				;;
			*) ;;
		esac
	done < <(grep -E '^# [A-Z_]+=' "$f" || true)
done

format_preamble_text() {
	local k
	for k in "${PREAMBLE_KEYS[@]}"; do
		[[ -n "${PREAMBLE[$k]:-}" ]] && printf "  %s: %s\n" "$k" "${PREAMBLE[$k]}"
	done
}
format_preamble_md() {
	echo "| Field | Value |"
	echo "|-------|-------|"
	local k
	for k in "${PREAMBLE_KEYS[@]}"; do
		[[ -n "${PREAMBLE[$k]:-}" ]] && printf "| %s | \`%s\` |\n" "$k" "${PREAMBLE[$k]}"
	done
}
format_preamble_csv_header() {
	local k first=1
	for k in "${PREAMBLE_KEYS[@]}"; do
		((first)) || printf ","
		printf "%s" "$k"
		first=0
	done
	printf "\n"
	first=1
	for k in "${PREAMBLE_KEYS[@]}"; do
		((first)) || printf ","
		# CSV-escape: quote if value contains comma or quote.
		local v="${PREAMBLE[$k]:-}"
		if [[ "$v" == *","* || "$v" == *'"'* ]]; then
			v="\"${v//\"/\"\"}\""
		fi
		printf "%s" "$v"
		first=0
	done
	printf "\n"
}
format_preamble_json() {
	local k first=1
	printf '{'
	for k in "${PREAMBLE_KEYS[@]}"; do
		[[ -z "${PREAMBLE[$k]:-}" ]] && continue
		((first)) || printf ","
		# Conservative JSON escape.
		local v="${PREAMBLE[$k]}"
		v="${v//\\/\\\\}"
		v="${v//\"/\\\"}"
		printf '"%s":"%s"' "$k" "$v"
		first=0
	done
	printf '}'
}

# Schema reminder: tab columns are
#   1 run_id  2 mesh_size  3 iter  4 src  5 remote
#   6 t0      7 p1_ms      8 p2_ms 9 p3_ms 10 status
#  11 p1_conv_p50_ms  12 p1_conv_p99_ms  13 p1_sample_count
#  14 p1_proxy_count  15 p1_overflow     16 restarted
#  17 window_ms       18 scrape_skew_ms

# Shared awk aggregation block. Uses SUBSEP-keyed single-dim arrays so it works
# in mawk (no gawk multi-dim required). The $-style dollars are awk fields, not bash.
# shellcheck disable=SC2016
AWK_AGG='
BEGIN { FS = "\t"; SUBSEP = "\034" }
/^#/ { next }
/^run_id/ { next }
NF < 10 { next }
{
	ms = $2
	p1 = $7; p2 = $8; p3 = $9
	cp50 = ($11 == "") ? "N/A" : $11
	cp99 = ($12 == "") ? "N/A" : $12
	overflow = ($15 == "") ? "0" : $15
	restarted = ($16 == "") ? "0" : $16

	n_total[ms]++
	seen[ms] = 1

	# Filter out restarted=1 and overflow=1 rows.
	if (restarted == "1" || overflow == "1") next

	n_valid[ms]++

	if (p1 != "TIMEOUT" && p1 != "N/A" && p1 ~ /^[0-9]+$/) {
		p1_n[ms]++; p1_vals[ms, p1_n[ms]] = p1 + 0
	}
	if (p2 != "TIMEOUT" && p2 != "N/A" && p2 ~ /^[0-9]+$/) {
		p2_n[ms]++; p2_vals[ms, p2_n[ms]] = p2 + 0
	}
	if (p3 != "TIMEOUT" && p3 != "N/A" && p3 ~ /^[0-9]+$/) {
		p3_n[ms]++; p3_vals[ms, p3_n[ms]] = p3 + 0
	}
	if (cp50 != "N/A" && cp50 != "overflow" && cp50 ~ /^[0-9]+$/) {
		cp50_n[ms]++; cp50_vals[ms, cp50_n[ms]] = cp50 + 0
	}
	if (cp99 != "N/A" && cp99 != "overflow" && cp99 ~ /^[0-9]+$/) {
		cp99_n[ms]++; cp99_vals[ms, cp99_n[ms]] = cp99 + 0
	}
}
function load(into, src, ms, n,    i) {
	for (i = 1; i <= n; i++) into[i] = src[ms, i]
}
function sort_arr(arr, n,    i, j, tmp) {
	for (i = 2; i <= n; i++) {
		tmp = arr[i]
		j = i - 1
		while (j >= 1 && arr[j] > tmp) { arr[j+1] = arr[j]; j-- }
		arr[j+1] = tmp
	}
}
function percentile(arr, n, pct,    idx) {
	if (n == 0) return "N/A"
	idx = int(n * pct / 100)
	if (idx < 1) idx = 1
	if (idx > n) idx = n
	return arr[idx]
}
function asorti_seen(    i, k) {
	# mawk lacks asorti — emit sorted keys from seen[] manually.
	delete __sorted
	__n = 0
	for (k in seen) { __sorted[++__n] = k }
	# insertion sort
	for (i = 2; i <= __n; i++) {
		__tmp = __sorted[i]; j = i - 1
		while (j >= 1 && __sorted[j] > __tmp) { __sorted[j+1] = __sorted[j]; j-- }
		__sorted[j+1] = __tmp
	}
}
'

report_endpoint_text() {
	echo "=== Endpoint Propagation Latency ==="
	echo ""
	echo "Run metadata:"
	format_preamble_text
	echo ""
	cat "${ENDPOINT_FILES[@]}" | awk "$AWK_AGG"'
	function stats_line(label, src, ms, n,    arr, sum, i) {
		if (n == 0) {
			printf "  %-3s | %-26s | %5d | %5s | %7s | %7s | %7s | %7s | %7s | %7s\n",
				ms, label, n_total[ms], "-", "-", "-", "-", "-", "-", "-"
			return
		}
		load(arr, src, ms, n)
		sort_arr(arr, n)
		sum = 0; for (i = 1; i <= n; i++) sum += arr[i]
		printf "  %-3s | %-26s | %5d | %5d | %7d | %7d | %7d | %7s | %7s | %7s\n",
			ms, label, n_total[ms], n, arr[1], arr[n], sum/n,
			percentile(arr, n, 50), percentile(arr, n, 95), percentile(arr, n, 99)
	}
	END {
		printf "  %-3s | %-26s | %5s | %5s | %7s | %7s | %7s | %7s | %7s | %7s\n",
			"Sz", "Phase", "n_tot", "n_val", "min", "max", "avg", "p50", "p95", "p99"
		printf "  %-3s-+-%-26s-+-%5s-+-%5s-+-%7s-+-%7s-+-%7s-+-%7s-+-%7s-+-%7s\n",
			"---", "--------------------------", "-----", "-----", "-------", "-------", "-------", "-------", "-------", "-------"
		asorti_seen()
		for (s = 1; s <= __n; s++) {
			ms_cur = __sorted[s]
			stats_line("P1 local xDS (wall)",    p1_vals,   ms_cur, p1_n[ms_cur])
			stats_line("P1 conv_p50 (hist)",     cp50_vals, ms_cur, cp50_n[ms_cur])
			stats_line("P1 conv_p99 (hist)",     cp99_vals, ms_cur, cp99_n[ms_cur])
			stats_line("P2 remote istiod EDS",   p2_vals,   ms_cur, p2_n[ms_cur])
			stats_line("P3 remote sidecar",      p3_vals,   ms_cur, p3_n[ms_cur])
		}
	}'
}

report_endpoint_csv() {
	format_preamble_csv_header
	echo ""
	echo "mesh_size,phase,n_total,n_valid,min_ms,max_ms,avg_ms,p50_ms,p95_ms,p99_ms"
	cat "${ENDPOINT_FILES[@]}" | awk "$AWK_AGG"'
	function csv_line(ms, phase, src, n,    arr, sum, i) {
		if (n == 0) {
			printf "%s,%s,%d,%d,,,,,,\n", ms, phase, n_total[ms], 0
			return
		}
		load(arr, src, ms, n)
		sort_arr(arr, n)
		sum = 0; for (i = 1; i <= n; i++) sum += arr[i]
		printf "%s,%s,%d,%d,%d,%d,%d,%s,%s,%s\n",
			ms, phase, n_total[ms], n, arr[1], arr[n], sum/n,
			percentile(arr, n, 50), percentile(arr, n, 95), percentile(arr, n, 99)
	}
	END {
		asorti_seen()
		for (s = 1; s <= __n; s++) {
			m = __sorted[s]
			csv_line(m, "P1_local_wall",   p1_vals,   p1_n[m])
			csv_line(m, "P1_conv_p50",     cp50_vals, cp50_n[m])
			csv_line(m, "P1_conv_p99",     cp99_vals, cp99_n[m])
			csv_line(m, "P2_discovery",    p2_vals,   p2_n[m])
			csv_line(m, "P3_dataplane",    p3_vals,   p3_n[m])
		}
	}'
}

report_endpoint_markdown() {
	echo "# Endpoint Propagation Latency"
	echo ""
	echo "Generated: $(date -Iseconds)"
	echo ""
	echo "## Run Metadata"
	echo ""
	format_preamble_md
	echo ""
	echo "**Source files:** ${#ENDPOINT_FILES[@]} TSV file(s)"
	echo ""
	for f in "${ENDPOINT_FILES[@]}"; do
		echo "- \`$(basename "$f")\`"
	done
	echo ""
	cat "${ENDPOINT_FILES[@]}" | awk "$AWK_AGG"'
	function md_row(phase, src, ms, n,    arr, sum, i) {
		if (n == 0) {
			printf "| %s | %d | %d | - | - | - | - | - | - |\n", phase, n_total[ms], 0
			return
		}
		load(arr, src, ms, n)
		sort_arr(arr, n)
		sum = 0; for (i = 1; i <= n; i++) sum += arr[i]
		printf "| %s | %d | %d | %d | %d | %d | %s | %s | %s |\n",
			phase, n_total[ms], n, arr[1], arr[n], sum/n,
			percentile(arr, n, 50), percentile(arr, n, 95), percentile(arr, n, 99)
	}
	END {
		asorti_seen()
		for (s = 1; s <= __n; s++) {
			ms_cur = __sorted[s]
			printf "## Mesh size: %s\n\n", ms_cur
			printf "| Phase | n_total | n_valid | min (ms) | max (ms) | avg (ms) | p50 (ms) | p95 (ms) | p99 (ms) |\n"
			printf "|-------|---------|---------|----------|----------|----------|----------|----------|----------|\n"
			md_row("P1 local xDS (wall)",  p1_vals,   ms_cur, p1_n[ms_cur])
			md_row("P1 conv_p50 (hist)",   cp50_vals, ms_cur, cp50_n[ms_cur])
			md_row("P1 conv_p99 (hist)",   cp99_vals, ms_cur, cp99_n[ms_cur])
			md_row("P2 remote istiod EDS", p2_vals,   ms_cur, p2_n[ms_cur])
			md_row("P3 remote sidecar",    p3_vals,   ms_cur, p3_n[ms_cur])
			printf "\n"
		}
	}'
}

report_endpoint_json() {
	# Emit a single object: { metadata: {...}, rows: [...] }.
	printf '{"metadata":'
	format_preamble_json
	printf ',"rows":'
	cat "${ENDPOINT_FILES[@]}" | awk "$AWK_AGG"'
	function json_obj(ms, phase, src, n,    arr, sum, i) {
		if (n == 0) {
			return sprintf("{\"mesh_size\":\"%s\",\"phase\":\"%s\",\"n_total\":%d,\"n_valid\":0}", ms, phase, n_total[ms])
		}
		load(arr, src, ms, n)
		sort_arr(arr, n)
		sum = 0; for (i = 1; i <= n; i++) sum += arr[i]
		return sprintf("{\"mesh_size\":\"%s\",\"phase\":\"%s\",\"n_total\":%d,\"n_valid\":%d,\"min_ms\":%d,\"max_ms\":%d,\"avg_ms\":%d,\"p50_ms\":%s,\"p95_ms\":%s,\"p99_ms\":%s}",
			ms, phase, n_total[ms], n, arr[1], arr[n], sum/n,
			percentile(arr, n, 50), percentile(arr, n, 95), percentile(arr, n, 99))
	}
	END {
		printf "["
		first = 1
		asorti_seen()
		for (s = 1; s <= __n; s++) {
			m = __sorted[s]
			if (!first) printf ","; printf "%s", json_obj(m, "P1_local_wall", p1_vals,   p1_n[m]);   first = 0
			printf ",";             printf "%s", json_obj(m, "P1_conv_p50",   cp50_vals, cp50_n[m])
			printf ",";             printf "%s", json_obj(m, "P1_conv_p99",   cp99_vals, cp99_n[m])
			printf ",";             printf "%s", json_obj(m, "P2_discovery",  p2_vals,   p2_n[m])
			printf ",";             printf "%s", json_obj(m, "P3_dataplane",  p3_vals,   p3_n[m])
		}
		printf "]"
	}'
	printf '}\n'
}

case "$FORMAT" in
text)
	echo "Files: ${ENDPOINT_FILES[*]}"
	report_endpoint_text
	;;
csv)
	report_endpoint_csv
	;;
json)
	report_endpoint_json
	;;
markdown|md)
	echo "Files: ${ENDPOINT_FILES[*]}" >&2
	report_endpoint_markdown
	;;
*)
	die "unknown format: $FORMAT (use text, csv, json, or markdown)"
	;;
esac

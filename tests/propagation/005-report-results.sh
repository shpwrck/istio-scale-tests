#!/usr/bin/env bash
# Post-process propagation test TSV files into summary statistics.
# Groups results by mesh_size to compare propagation latency across cluster counts.
#
# Filtering policy (rows excluded from numeric aggregation):
#   - restarted == 1            (istiod restart mid-iteration; counters reset)
#   - restarted == unknown      (process_start_time_seconds missing — can't tell)
#   - p1_overflow == 1          (samples landed in +Inf bucket; quantiles unsafe)
#   - status != OK              (TIMEOUT_* or DRAIN_TIMEOUT — drain leak)
# p2_ms values are also excluded when p2_dirty == 1 (EDS counter delta wasn't
# matched by a pilot_services delta; could be unrelated endpoint churn).
# Reports both n_total (rows considered) and n_valid (rows used).
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

TSV columns consumed (positions are stable; new columns appended):
  1  run_id            2  mesh_size       3  iteration       4  source_ctx
  5  remote_ctx        6  t0_epoch_ns     7  p1_ms           8  p2_ms
  9  p3_ms            10  status         11  p1_conv_p50_ms 12  p1_conv_p99_ms
 13  p1_sample_count  14  p1_proxy_count 15  p1_overflow    16  restarted
 17  p2_dirty         18  window_ms      19  scrape_skew_ms

Phases emitted in the report:
  P1_local_wall  wall-clock ms (p1_ms) from canary apply until histogram delta
                 _count reached proxy_count.
  P1_conv_p50    p50 of delta-window pilot_proxy_convergence_time (ms).
  P1_conv_p99    p99 of delta-window pilot_proxy_convergence_time (ms).
  P2_discovery   pilot_xds_pushes{type="eds"} counter-delta detection (ms).
  P3_dataplane   watcher Envoy /clusters detection (ms).

Filtering policy (rows excluded from numeric aggregation):
  restarted == 1 or unknown
  p1_overflow == 1
  status != OK   (TIMEOUT_*, DRAIN_TIMEOUT, RESTART)
P2 values are additionally suppressed when p2_dirty == 1.

n_total / n_valid: rows considered vs rows used after the above filtering.
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

# ---- preamble metadata: collect across all files ----------------------------
# Two partitions (PL19 — preamble propagation must survive into all 4 formats):
#
# SWEEP_LEVEL_KEYS — scalar, identical across all input TSVs in a sweep. Emitted
#   once at the top of the metadata block.
#     SWEEP_RUN_ID is first so the outer→inner ordering reads correctly when
#     a sweep ran. For standalone probe TSVs SWEEP_RUN_ID is absent (002 omits
#     the line when --sweep-run-id is empty), and the report just drops it.
#
# PER_ITER_KEYS — vary per iteration; emitted as a sequence (one entry per input
#   TSV). A single-input run (or a sweep with one mesh size and one probe) is
#   still rendered as a one-element sequence so the schema is uniform.
#
# Implementation: for each input file we collect a row of key=value pairs into
# PER_FILE_<KEY>[i]. Scalars are looked up via the first row (homogeneous by
# definition); sequences iterate the rows in input order.
SWEEP_LEVEL_KEYS=(SWEEP_RUN_ID HARNESS_SHA ISTIO_VERSION SOURCE_CTX ITERATIONS POLL_INTERVAL_S TIMEOUT_SEC SETTLE_SEC)
PER_ITER_KEYS=(RUN_ID DATE MESH_SIZE REMOTES KUBE_VERSIONS)
# Legacy combined order used by report_endpoint_*'s "first valid value" lookup
# (preserved so any scalar key, even one we have not classified, still appears).
# shellcheck disable=SC2034
PREAMBLE_KEYS=("${SWEEP_LEVEL_KEYS[@]}" "${PER_ITER_KEYS[@]}")

declare -A PREAMBLE=()         # last-value-wins scalar map (sweep-level keys)
declare -A PER_FILE_VALS=()    # KEY|idx -> value (per-iteration values)
declare -a PER_FILE_INDICES=() # 0..N-1 indices for input files, in collection order
N_FILES=0
for f in "${ENDPOINT_FILES[@]}"; do
	idx="$N_FILES"
	PER_FILE_INDICES+=("$idx")
	while IFS= read -r line; do
		case "$line" in
			'# '*)
				kv="${line#\# }"
				key="${kv%%=*}"
				val="${kv#*=}"
				[[ "$key" == "$kv" ]] && continue
				PREAMBLE["$key"]="$val"
				PER_FILE_VALS["${key}|${idx}"]="$val"
				;;
			*) ;;
		esac
	done < <(grep -E '^# [A-Z_]+=' "$f" || true)
	N_FILES=$((N_FILES + 1))
done

# Helper: does any per-file row carry this key?
preamble_has() {
	local k="$1" i
	for i in "${PER_FILE_INDICES[@]}"; do
		[[ -n "${PER_FILE_VALS[${k}|${i}]:-}" ]] && return 0
	done
	[[ -n "${PREAMBLE[$k]:-}" ]] && return 0
	return 1
}

# JSON-escape a single value (backslash + quote only; values are ASCII run metadata).
json_escape() {
	local v="$1"
	v="${v//\\/\\\\}"
	v="${v//\"/\\\"}"
	printf '%s' "$v"
}

# CSV-escape (RFC4180 — quote if comma/quote/newline; double internal quotes).
csv_escape() {
	local v="$1"
	if [[ "$v" == *","* || "$v" == *'"'* || "$v" == *$'\n'* ]]; then
		printf '"%s"' "${v//\"/\"\"}"
	else
		printf '%s' "$v"
	fi
}

format_preamble_text() {
	local k i v
	for k in "${SWEEP_LEVEL_KEYS[@]}"; do
		preamble_has "$k" || continue
		printf "  %s: %s\n" "$k" "${PREAMBLE[$k]:-}"
	done
	# Per-iteration block: one section per input file, indented under "iterations:".
	local any_iter=0
	for k in "${PER_ITER_KEYS[@]}"; do
		preamble_has "$k" && { any_iter=1; break; }
	done
	((any_iter)) || return 0
	printf "  iterations:\n"
	for i in "${PER_FILE_INDICES[@]}"; do
		printf "    -\n"
		for k in "${PER_ITER_KEYS[@]}"; do
			v="${PER_FILE_VALS[${k}|${i}]:-}"
			[[ -n "$v" ]] && printf "      %s: %s\n" "$k" "$v"
		done
	done
	return 0
}

format_preamble_md() {
	# YAML frontmatter: scalars first, then iterations as a YAML sequence so
	# downstream tools (and human readers) can recover per-iteration provenance.
	local k i v
	for k in "${SWEEP_LEVEL_KEYS[@]}"; do
		preamble_has "$k" || continue
		printf "%s: \"%s\"\n" "$k" "${PREAMBLE[$k]:-}"
	done
	local any_iter=0
	for k in "${PER_ITER_KEYS[@]}"; do
		preamble_has "$k" && { any_iter=1; break; }
	done
	((any_iter)) || return 0
	printf "iterations:\n"
	for i in "${PER_FILE_INDICES[@]}"; do
		# Sequence marker on its own line so each per-iteration mapping is a
		# proper YAML block — easier to read than inline flow form for sweeps
		# with many iterations.
		printf "  -\n"
		for k in "${PER_ITER_KEYS[@]}"; do
			v="${PER_FILE_VALS[${k}|${i}]:-}"
			[[ -n "$v" ]] && printf "    %s: \"%s\"\n" "$k" "$v"
		done
	done
	return 0
}

format_preamble_csv_header() {
	# Sweep-level scalars rendered as "# KEY=VALUE" comment lines above the
	# data table (uniform with text format) so the CSV remains a single tabular
	# stream readable by spreadsheet tools that skip leading comments.
	# Per-iteration block is a small CSV blob after the scalars.
	local k i v
	for k in "${SWEEP_LEVEL_KEYS[@]}"; do
		preamble_has "$k" || continue
		printf "# %s=%s\n" "$k" "${PREAMBLE[$k]:-}"
	done
	local any_iter=0
	for k in "${PER_ITER_KEYS[@]}"; do
		preamble_has "$k" && { any_iter=1; break; }
	done
	if ((any_iter)); then
		printf "# iterations:\n"
		# Header row for the per-iteration block.
		local first=1
		printf "# "
		for k in "${PER_ITER_KEYS[@]}"; do
			preamble_has "$k" || continue
			((first)) || printf ","
			printf "%s" "$k"
			first=0
		done
		printf "\n"
		for i in "${PER_FILE_INDICES[@]}"; do
			first=1
			printf "# "
			for k in "${PER_ITER_KEYS[@]}"; do
				preamble_has "$k" || continue
				((first)) || printf ","
				v="${PER_FILE_VALS[${k}|${i}]:-}"
				csv_escape "$v"
				first=0
			done
			printf "\n"
		done
	fi
}

format_preamble_json() {
	# Sweep-level scalars become top-level metadata fields; per-iteration values
	# go into an "iterations" array of objects so downstream JSON consumers can
	# recover every iteration's RUN_ID/DATE/MESH_SIZE without re-reading TSVs.
	local k i v first=1
	printf '{'
	for k in "${SWEEP_LEVEL_KEYS[@]}"; do
		preamble_has "$k" || continue
		((first)) || printf ","
		printf '"%s":"%s"' "$k" "$(json_escape "${PREAMBLE[$k]:-}")"
		first=0
	done
	local any_iter=0
	for k in "${PER_ITER_KEYS[@]}"; do
		preamble_has "$k" && { any_iter=1; break; }
	done
	if ((any_iter)); then
		((first)) || printf ","
		printf '"iterations":['
		local row_first=1 kv_first
		for i in "${PER_FILE_INDICES[@]}"; do
			((row_first)) || printf ","
			printf '{'
			kv_first=1
			for k in "${PER_ITER_KEYS[@]}"; do
				v="${PER_FILE_VALS[${k}|${i}]:-}"
				[[ -z "$v" ]] && continue
				((kv_first)) || printf ","
				printf '"%s":"%s"' "$k" "$(json_escape "$v")"
				kv_first=0
			done
			printf '}'
			row_first=0
		done
		printf ']'
	fi
	printf '}'
}

# Schema reminder: tab columns are
#   1 run_id  2 mesh_size  3 iter  4 src  5 remote
#   6 t0      7 p1_ms      8 p2_ms 9 p3_ms 10 status
#  11 p1_conv_p50_ms  12 p1_conv_p99_ms  13 p1_sample_count
#  14 p1_proxy_count  15 p1_overflow     16 restarted
#  17 p2_dirty (new)  18 window_ms       19 scrape_skew_ms
#
# Pre-branch TSVs have NF=18 (no p2_dirty column); the missing column is
# default-filled to "0" (clean), which keeps legacy reports identical.

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
	status = $10
	p1 = $7; p2 = $8; p3 = $9
	cp50 = ($11 == "") ? "N/A" : $11
	cp99 = ($12 == "") ? "N/A" : $12
	overflow = ($15 == "") ? "0" : $15
	restarted = ($16 == "") ? "0" : $16
	# p2_dirty introduced mid-branch; pre-branch TSVs (NF=18) lack it.
	if (NF >= 19) {
		p2_dirty = ($17 == "") ? "0" : $17
	} else {
		p2_dirty = "0"
	}

	n_total[ms]++
	seen[ms] = 1

	# Filter: restarted=1 or unknown, overflow=1, or any non-OK status.
	if (restarted == "1" || restarted == "unknown") next
	if (overflow == "1") next
	if (status != "" && status != "OK") next

	n_valid[ms]++

	if (p1 != "TIMEOUT" && p1 != "N/A" && p1 ~ /^[0-9]+$/) {
		p1_n[ms]++; p1_vals[ms, p1_n[ms]] = p1 + 0
	}
	# Skip p2 sample if dirty (EDS bumped without a matching pilot_services delta).
	if (p2_dirty != "1" && p2 != "TIMEOUT" && p2 != "N/A" && p2 ~ /^[0-9]+$/) {
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
function bucket_range(upper_ms) {
	if (upper_ms+0 <= 0)     return "N/A"
	if (upper_ms+0 <= 100)   return "0-100"
	if (upper_ms+0 <= 500)   return "100-500"
	if (upper_ms+0 <= 1000)  return "500-1000"
	if (upper_ms+0 <= 3000)  return "1000-3000"
	if (upper_ms+0 <= 5000)  return "3000-5000"
	if (upper_ms+0 <= 10000) return "5000-10000"
	if (upper_ms+0 <= 20000) return "10000-20000"
	if (upper_ms+0 <= 30000) return "20000-30000"
	return ">30000"
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
			printf "  %-3s | %-26s | %5d | %5s | %11s | %11s | %11s | %11s | %11s | %11s\n",
				ms, label, n_total[ms], "-", "-", "-", "-", "-", "-", "-"
			return
		}
		load(arr, src, ms, n)
		sort_arr(arr, n)
		sum = 0; for (i = 1; i <= n; i++) sum += arr[i]
		printf "  %-3s | %-26s | %5d | %5d | %11d | %11d | %11d | %11s | %11s | %11s\n",
			ms, label, n_total[ms], n, arr[1], arr[n], sum/n,
			percentile(arr, n, 50), percentile(arr, n, 95), percentile(arr, n, 99)
	}
	function stats_line_hist(label, src, ms, n,    arr, sum, i) {
		if (n == 0) {
			printf "  %-3s | %-26s | %5d | %5s | %11s | %11s | %11s | %11s | %11s | %11s\n",
				ms, label, n_total[ms], "-", "-", "-", "-", "-", "-", "-"
			return
		}
		load(arr, src, ms, n)
		sort_arr(arr, n)
		sum = 0; for (i = 1; i <= n; i++) sum += arr[i]
		printf "  %-3s | %-26s | %5d | %5d | %11s | %11s | %11s | %11s | %11s | %11s\n",
			ms, label, n_total[ms], n,
			bucket_range(arr[1]), bucket_range(arr[n]), bucket_range(sum/n),
			bucket_range(percentile(arr, n, 50)),
			bucket_range(percentile(arr, n, 95)),
			bucket_range(percentile(arr, n, 99))
	}
	END {
		printf "  %-3s | %-26s | %5s | %5s | %11s | %11s | %11s | %11s | %11s | %11s\n",
			"Sz", "Phase", "n_tot", "n_val", "min", "max", "avg", "p50", "p95", "p99"
		printf "  %-3s-+-%-26s-+-%5s-+-%5s-+-%11s-+-%11s-+-%11s-+-%11s-+-%11s-+-%11s\n",
			"---", "--------------------------", "-----", "-----", "-----------", "-----------", "-----------", "-----------", "-----------", "-----------"
		asorti_seen()
		for (s = 1; s <= __n; s++) {
			ms_cur = __sorted[s]
			stats_line("P1 local xDS (wall)",    p1_vals,   ms_cur, p1_n[ms_cur])
			stats_line_hist("P1 conv_p50 (hist)", cp50_vals, ms_cur, cp50_n[ms_cur])
			stats_line_hist("P1 conv_p99 (hist)", cp99_vals, ms_cur, cp99_n[ms_cur])
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
	echo "---"
	format_preamble_md
	echo "generated: $(date -u -Iseconds)"
	echo "---"
	echo ""
	echo "# Endpoint Propagation Latency"
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
	function md_row_hist(phase, src, ms, n,    arr, sum, i) {
		if (n == 0) {
			printf "| %s | %d | %d | - | - | - | - | - | - |\n", phase, n_total[ms], 0
			return
		}
		load(arr, src, ms, n)
		sort_arr(arr, n)
		sum = 0; for (i = 1; i <= n; i++) sum += arr[i]
		printf "| %s | %d | %d | %s | %s | %s | %s | %s | %s |\n",
			phase, n_total[ms], n,
			bucket_range(arr[1]), bucket_range(arr[n]), bucket_range(sum/n),
			bucket_range(percentile(arr, n, 50)),
			bucket_range(percentile(arr, n, 95)),
			bucket_range(percentile(arr, n, 99))
	}
	function cmp_avg(src, ms, n,    arr, sum, i) {
		if (n == 0) return "-- (0)"
		load(arr, src, ms, n)
		sum = 0; for (i = 1; i <= n; i++) sum += arr[i]
		return sprintf("%d (%d)", sum/n, n)
	}
	function cmp_avg_hist(src, ms, n,    arr, sum, i) {
		if (n == 0) return "-- (0)"
		load(arr, src, ms, n)
		sum = 0; for (i = 1; i <= n; i++) sum += arr[i]
		return sprintf("%s (%d)", bucket_range(sum/n), n)
	}
	END {
		asorti_seen()
		for (s = 1; s <= __n; s++) {
			ms_cur = __sorted[s]
			printf "## Mesh size: %s\n\n", ms_cur
			printf "| Phase | n_total | n_valid | min (ms) | max (ms) | avg (ms) | p50 (ms) | p95 (ms) | p99 (ms) |\n"
			printf "|-------|---------|---------|----------|----------|----------|----------|----------|----------|\n"
			md_row("P1 local xDS (wall)",  p1_vals,   ms_cur, p1_n[ms_cur])
			md_row_hist("P1 conv_p50 (hist)",   cp50_vals, ms_cur, cp50_n[ms_cur])
			md_row_hist("P1 conv_p99 (hist)",   cp99_vals, ms_cur, cp99_n[ms_cur])
			md_row("P2 remote istiod EDS", p2_vals,   ms_cur, p2_n[ms_cur])
			md_row("P3 remote sidecar",    p3_vals,   ms_cur, p3_n[ms_cur])
			printf "\n"
		}
		# Cross-mesh-size comparison (only meaningful when >1 mesh size was swept).
		if (__n > 1) {
			printf "## Comparison across mesh sizes\n\n"
			printf "Averages over rows surviving the report filter (restarted in {1, unknown}, "
			printf "p1_overflow=1, and status != OK are dropped; P2 also drops p2_dirty=1 rows). "
			printf "Cells show `avg (n_valid)`; per-mesh-size tables above carry the full breakdown.\n\n"
			printf "| Mesh Size | P1 wall avg (ms) | P1 conv_p99 avg (ms) | P2 EDS avg (ms) | P3 sidecar avg (ms) |\n"
			printf "|-----------|------------------|----------------------|-----------------|---------------------|\n"
			for (s = 1; s <= __n; s++) {
				ms_cur = __sorted[s]
				printf "| %s | %s | %s | %s | %s |\n",
					ms_cur,
					cmp_avg(p1_vals,   ms_cur, p1_n[ms_cur]),
					cmp_avg_hist(cp99_vals, ms_cur, cp99_n[ms_cur]),
					cmp_avg(p2_vals,   ms_cur, p2_n[ms_cur]),
					cmp_avg(p3_vals,   ms_cur, p3_n[ms_cur])
			}
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

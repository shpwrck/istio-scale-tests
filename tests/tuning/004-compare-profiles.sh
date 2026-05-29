#!/usr/bin/env bash
# Compare tuning profile results from a sweep run.
#
# Reads TSV files from each profile-tagged subdirectory under a sweep results
# directory and produces a side-by-side comparison showing deltas vs baseline.
#
# Usage:
#   ./tests/tuning/004-compare-profiles.sh [--results-dir DIR] [--format FMT]
#
# Examples:
#   ./tests/tuning/004-compare-profiles.sh --results-dir results/sweep-20260528T120000Z-12345
#   ./tests/tuning/004-compare-profiles.sh --results-dir results/sweep-20260528T120000Z-12345 --format markdown
set -euo pipefail

RESULTS_DIR=""
FORMAT="text"
OUTPUT_FILE=""

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Compare tuning profile results from a sweep run, showing deltas vs baseline.

Options:
  --results-dir DIR  Sweep results directory (e.g. results/sweep-<RUN_ID>).
                     Must contain subdirectories named after profiles, each
                     containing TSV files from the probe run.
  --format FMT       Output format: text, markdown (default: text).
  --output FILE      Write output to FILE instead of stdout.
  -h, --help         Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--results-dir) RESULTS_DIR="$2"; shift 2 ;;
	--format) FORMAT="$2"; shift 2 ;;
	--output) OUTPUT_FILE="$2"; shift 2 ;;
	-h | --help) usage; exit 0 ;;
	*) die "Unknown option: $1" ;;
	esac
done

[[ -n "$RESULTS_DIR" ]] || die "--results-dir is required"
[[ -d "$RESULTS_DIR" ]] || die "Results directory not found: $RESULTS_DIR"

case "$FORMAT" in
text | markdown) ;;
*) die "Unknown format: $FORMAT (use text or markdown)" ;;
esac

PROFILE_DIRS=()
PROFILE_NAMES=()

for d in "$RESULTS_DIR"/*/; do
	[[ -d "$d" ]] || continue
	name="$(basename "$d")"
	tsvs="$(find "$d" -maxdepth 1 -name '*.tsv' -type f 2>/dev/null | head -1)"
	[[ -n "$tsvs" ]] || continue
	PROFILE_DIRS+=("$d")
	PROFILE_NAMES+=("$name")
done

[[ ${#PROFILE_NAMES[@]} -gt 0 ]] || die "No profile subdirectories with TSV files found"

extract_metric_avg() {
	local tsv="$1"
	local col_idx="$2"
	awk -F'\t' -v col="$col_idx" '
	!/^#/ && !/^timestamp/ && NF >= col {
		v = $col
		if (v != "" && v != "N/A" && v != "overflow" && v != "unknown" && v+0 == v) {
			sum += v; n++
		}
	}
	END {
		if (n > 0) printf "%.2f", sum/n
		else printf "N/A"
	}' "$tsv"
}

detect_suite() {
	local dir="$1"
	local tsv
	tsv="$(find "$dir" -maxdepth 1 -name '*.tsv' -type f 2>/dev/null | head -1)"
	[[ -n "$tsv" ]] || { echo "unknown"; return; }
	local basename_f
	basename_f="$(basename "$tsv")"
	case "$basename_f" in
	controlplane-*) echo "controlplane" ;;
	propagation-*) echo "propagation" ;;
	dataplane-*) echo "dataplane" ;;
	churn-*dataplane*) echo "churn-dataplane" ;;
	churn-*) echo "churn" ;;
	*) echo "unknown" ;;
	esac
}

SUITE="$(detect_suite "${PROFILE_DIRS[0]}")"

output() {
	if [[ -n "$OUTPUT_FILE" ]]; then
		cat >> "$OUTPUT_FILE"
	else
		cat
	fi
}

[[ -n "$OUTPUT_FILE" ]] && : > "$OUTPUT_FILE"

METADATA_FILE="${RESULTS_DIR}/sweep-metadata.txt"

if [[ "$FORMAT" == "markdown" ]]; then
	{
		echo "# Tuning Profile Comparison"
		echo ""
		if [[ -f "$METADATA_FILE" ]]; then
			echo '```'
			cat "$METADATA_FILE"
			echo '```'
			echo ""
		fi
		echo "## Suite: ${SUITE}"
		echo ""
		echo "| Metric | $(printf '%s | ' "${PROFILE_NAMES[@]}")"
		echo "|--------|$(for _ in "${PROFILE_NAMES[@]}"; do printf -- '--------|'; done)"
	} | output

	case "$SUITE" in
	controlplane)
		metrics=("istiod_mem_mi:8:Memory (MiB)"
		         "istiod_cpu_m_delta:31:CPU (millicores)"
		         "convergence_p99_ms:10:Convergence P99"
		         "xds_pushes_delta:13:xDS Pushes"
		         "connected_proxies:22:Connected Proxies")
		;;
	propagation)
		metrics=("p1_ms:4:P1 Local (ms)"
		         "p2_ms:5:P2 Remote (ms)"
		         "p3_ms:6:P3 E2E (ms)")
		;;
	dataplane)
		metrics=("p50_ms:10:P50 Latency (ms)"
		         "p99_ms:12:P99 Latency (ms)"
		         "p999_ms:13:P99.9 Latency (ms)"
		         "qps_actual:9:Actual QPS")
		;;
	*)
		metrics=()
		echo "| (raw TSV comparison — suite-specific metrics not configured) | |" | output
		;;
	esac

	for m in "${metrics[@]}"; do
		IFS=':' read -r _field col_idx label <<<"$m"
		row="| ${label} |"
		for dir in "${PROFILE_DIRS[@]}"; do
			tsv="$(find "$dir" -maxdepth 1 -name '*.tsv' -type f 2>/dev/null | head -1)"
			if [[ -n "$tsv" ]]; then
				val="$(extract_metric_avg "$tsv" "$col_idx")"
				row+=" ${val} |"
			else
				row+=" — |"
			fi
		done
		echo "$row" | output
	done

	has_baseline=0
	baseline_dir=""
	for i in "${!PROFILE_NAMES[@]}"; do
		if [[ "${PROFILE_NAMES[$i]}" == "baseline" ]]; then
			has_baseline=1
			baseline_dir="${PROFILE_DIRS[$i]}"
			break
		fi
	done

	if ((has_baseline)) && [[ ${#PROFILE_NAMES[@]} -gt 1 ]]; then
		{
			echo ""
			echo "## Delta vs Baseline"
			echo ""
			non_baseline=()
			for n in "${PROFILE_NAMES[@]}"; do
				[[ "$n" != "baseline" ]] && non_baseline+=("$n")
			done
			echo "| Metric | $(printf '%s | ' "${non_baseline[@]}")"
			echo "|--------|$(for _ in "${non_baseline[@]}"; do printf -- '--------|'; done)"
		} | output

		for m in "${metrics[@]}"; do
			IFS=':' read -r _field col_idx label <<<"$m"
			baseline_tsv="$(find "$baseline_dir" -maxdepth 1 -name '*.tsv' -type f 2>/dev/null | head -1)"
			baseline_val=""
			[[ -n "$baseline_tsv" ]] && baseline_val="$(extract_metric_avg "$baseline_tsv" "$col_idx")"

			row="| ${label} |"
			for i in "${!PROFILE_NAMES[@]}"; do
				[[ "${PROFILE_NAMES[$i]}" == "baseline" ]] && continue
				dir="${PROFILE_DIRS[$i]}"
				tsv="$(find "$dir" -maxdepth 1 -name '*.tsv' -type f 2>/dev/null | head -1)"
				if [[ -n "$tsv" ]] && [[ -n "$baseline_val" ]] && [[ "$baseline_val" != "N/A" ]]; then
					val="$(extract_metric_avg "$tsv" "$col_idx")"
					if [[ "$val" != "N/A" ]]; then
						delta="$(awk -v a="$val" -v b="$baseline_val" 'BEGIN {
							if (b+0 == 0) { printf "N/A"; exit }
							d = ((a - b) / b) * 100
							if (d >= 0) printf "+%.1f%%", d
							else printf "%.1f%%", d
						}')"
						row+=" ${delta} |"
					else
						row+=" N/A |"
					fi
				else
					row+=" — |"
				fi
			done
			echo "$row" | output
		done
	fi

	echo "" | output

elif [[ "$FORMAT" == "text" ]]; then
	{
		echo "Tuning Profile Comparison"
		echo "========================="
		echo ""
		if [[ -f "$METADATA_FILE" ]]; then
			cat "$METADATA_FILE"
			echo ""
		fi
		echo "Suite: ${SUITE}"
		echo "Profiles: ${PROFILE_NAMES[*]}"
		echo ""

		echo "Raw TSV files per profile:"
		for i in "${!PROFILE_NAMES[@]}"; do
			tsv="$(find "${PROFILE_DIRS[$i]}" -maxdepth 1 -name '*.tsv' -type f 2>/dev/null | head -1)"
			echo "  ${PROFILE_NAMES[$i]}: ${tsv:-none}"
		done
		echo ""
		echo "Use --format markdown for tabular comparison."
	} | output
fi

echo ""
echo "=== Comparison complete ==="
[[ -n "$OUTPUT_FILE" ]] && echo "    Written to: ${OUTPUT_FILE}"

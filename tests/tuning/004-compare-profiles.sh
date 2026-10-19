#!/usr/bin/env bash
# Compare the passes of a tuning sweep (baseline + one directory per profile).
# Reads each pass's suite TSV, finds columns by header name, averages the valid rows
# and shows each profile's change against the baseline. Each pass's platform record
# (PLATFORM, the mesh operator, istiod and gateway proxy builds, the node provider:
# tests/lib/platform.sh PLATFORM_PASS_KEYS; not istiod's settings, which a profile changes) is
# compared with the baseline's (else the first pass with data's) in one "Platform record" row,
# its values follow the table once, and a pass whose record differs (or cannot be compared)
# warns: its change is then not the profile's alone.
#
# Usage:
#   ./tests/tuning/004-compare-profiles.sh --results-dir DIR [--format text|md] [--output FILE]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/platform.sh"  # platform_report_values, platform_compare_values, platform_collapse, platform_value_against

RESULTS_DIR=""
FORMAT="text"
OUTPUT_FILE=""

usage() {
	cat <<EOF
Usage: $(basename "$0") --results-dir DIR [options]

Compare tuning sweep passes. Values are means over valid rows (status OK, no
istiod restart); each profile also shows its change against the baseline.
Histogram p99 rows (convergence, push time) show the worst bucket a valid row hit,
or "overflow (N rows)", never a mean. Memory is in Mi, CPU in millicores (the
controlplane's istiod CPU and memory are window peaks), config sizes in KiB, and a
count's mean prints bare when it is whole (438, not 438.00). The "Platform record" row
compares each pass's platform and mesh builds with the reference pass's (the baseline,
else the first pass with data): same, differs (see notes), unknown (see notes: not read
or not recorded in one of them), baseline or reference (the pass compared with) or -
(no data). An operator that differs only in its state is the same build; istiod's
settings (ISTIOD_ENV_BY_CONTEXT) and a profile's objects (TUNING_OBJECTS_BY_CONTEXT) are
not compared, since a profile changes them. The values follow the table, digests
shortened to 12 hex digits: the reference pass's, then for each pass that differs or
cannot be compared only the members that do not match (five at most, with a count).

Options:
  --results-dir DIR  Sweep directory (tests/tuning/results/sweep-<RUN_ID>) (required).
  --format FMT       text or md (or markdown) (default: text).
  --output FILE      Write to FILE instead of stdout.
  -h, --help         Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--results-dir | --format | --output)
		[[ -n "${2:-}" ]] || die "$1 requires a value"
		case "$1" in
		--results-dir) RESULTS_DIR="$2" ;;
		--format) FORMAT="$2" ;;
		--output) OUTPUT_FILE="$2" ;;
		esac
		shift 2
		;;
	-h | --help) usage; exit 0 ;;
	*) die "unknown option: $1 (try --help)" ;;
	esac
done

platform_validate
[[ -n "$RESULTS_DIR" ]] || die "--results-dir is required"
[[ -d "$RESULTS_DIR" ]] || die "results directory not found: $RESULTS_DIR"
case "$FORMAT" in
text | markdown) ;;
md) FORMAT=markdown ;;
*) die "--format must be text or md" ;;
esac

META="${RESULTS_DIR}/sweep-metadata.txt"
meta_get() { [[ -f "$META" ]] && sed -n "s/^# $1=//p" "$META" | head -1; return 0; }

# Passes in sweep order (metadata), else baseline first then the rest.
PASSES=()
passes_csv="$(meta_get PASSES)"
if [[ -n "$passes_csv" ]]; then
	split_csv "$passes_csv" PASSES
else
	[[ -d "${RESULTS_DIR}/baseline" ]] && PASSES+=(baseline)
	for d in "$RESULTS_DIR"/*/; do
		n="$(basename "$d")"
		[[ "$n" == baseline ]] || PASSES+=("$n")
	done
fi
((${#PASSES[@]})) || die "no pass directories in $RESULTS_DIR"

# reach-*.tsv (the dataplane suites' reachability check, tests/lib/reach.sh) has no
# status column and is not probe data, so it is left out.
pass_tsvs() { find "${RESULTS_DIR}/$1" -maxdepth 1 -name '*.tsv' ! -name 'reach-*.tsv' -type f 2>/dev/null | sort; }

# Suite from metadata, else from a header column only that suite's TSV has.
SUITE="$(meta_get SUITE)"
if [[ -z "$SUITE" ]]; then
	for p in "${PASSES[@]}"; do
		f="$(pass_tsvs "$p" | head -1)"
		[[ -n "$f" ]] || continue
		hdr="$(grep -v '^#' "$f" | grep -m1 . || true)"
		case $'\t'"$hdr"$'\t' in
		*$'\tistiod_mem_mi\t'*) SUITE=controlplane ;;
		*$'\tchurn_ops_attempted\t'*) SUITE=churn-dataplane ;;
		*$'\tconvergence_local_ms\t'*) SUITE=churn ;;
		*$'\ttarget_class\t'*) SUITE=dataplane ;;
		*$'\tp3_ms\t'*) SUITE=propagation ;;
		esac
		break
	done
fi

# Metrics per suite as "column|label|kind"; GROUP (CSV of columns) splits rows by their
# values. kind sets how a cell prints (fmt_metric): ms (mean, 2 decimals), count (mean,
# a whole number bare, else 1 decimal), mi and m (mean in Mi / millicores, whole), kib
# (a bytes mean shown in KiB, 1 decimal), qps (mean, 1 decimal), hist (a histogram
# p99: never averaged, the worst bucket any valid row hit, or "overflow (N rows)").
GROUP=""
case "$SUITE" in
controlplane)
	# Rows are per istiod pod: connected_proxies is per replica; cluster_connected_proxies
	# repeats on each pod row of a cluster, so its mean weights clusters by replica
	# count (same replicas everywhere -> the plain per-cluster mean). Absent in older
	# 40-column TSVs, where it is skipped. istiod_mem_mi is the window's peak RSS and
	# istiod_cpu_m_delta the larger of the window average and the polled 5 s peak.
	METRICS=("istiod_mem_mi|istiod memory peak (Mi)|mi" "go_heap_inuse_mi|Go heap in use (Mi)|mi"
		"istiod_cpu_m_delta|istiod CPU peak (m)|m" "convergence_p99_ms|Convergence p99 worst bucket (ms)|hist"
		"xds_pushes_delta|xDS pushes|count" "sidecar_config_bytes_avg|Sidecar config (KiB)|kib"
		"connected_proxies|Connected proxies / istiod replica|count"
		"cluster_connected_proxies|Connected proxies / cluster|count") ;;
propagation)
	METRICS=("p1_ms|P1 local push (ms)|ms" "p2_ms|P2 remote EDS (ms)|ms" "p3_ms|P3 remote sidecar (ms)|ms"
		"p1_conv_p99_ms|P1 convergence p99 worst bucket (ms)|hist") ;;
dataplane)
	GROUP="target_class,qps_target"
	METRICS=("p50_ms|p50 (ms)|ms" "p90_ms|p90 (ms)|ms" "p99_ms|p99 (ms)|ms" "p999_ms|p99.9 (ms)|ms"
		"qps_actual|Actual QPS|qps") ;;
churn)
	METRICS=("convergence_local_ms|Local convergence (ms)|ms" "convergence_remote_eds_ms|Remote EDS (ms)|ms"
		"remote_endpoint_reachable_ms|Remote reachable (ms)|ms" "source_xds_pushes_delta|Source xDS pushes|count"
		"source_push_time_p99_ms|Source push time p99 worst bucket (ms)|hist") ;;
churn-dataplane)
	GROUP="phase"
	METRICS=("p50_ms|p50 (ms)|ms" "p99_ms|p99 (ms)|ms" "p999_ms|p99.9 (ms)|ms" "delta_p99_ms|p99 change vs baseline phase (ms)|ms"
		"qps_actual|Actual QPS|qps" "xds_pushes_delta|xDS pushes|count" "eds_pushes_delta|EDS pushes|count") ;;
*) die "cannot tell the suite (no '# SUITE=' in sweep-metadata.txt and no known TSV header)" ;;
esac

metric_cols=""
for m in "${METRICS[@]}"; do metric_cols+="${m%%|*},"; done

# One pass -> lines "n<TAB>valid<TAB>total", "g<TAB>group" (first-seen order) and
# "v<TAB>group<TAB>column<TAB>mean<TAB>max<TAB>n_overflow" (mean and max "-" without
# a numeric value: a tab IFS would merge empty fields). A group is "col=value,
# col=value", or "-". "overflow" (a histogram p99 in +Inf) is counted, not dropped.
summarize() {
	awk -F'\t' -v cols="$metric_cols" -v gcols="$GROUP" '
	BEGIN { nm = split(cols, mc, ","); ng = split(gcols, gc, ",") }
	FNR == 1 { hdr = 0 }
	/^#/ || NF == 0 { next }
	!hdr { delete idx; for (i = 1; i <= NF; i++) idx[$i] = i; hdr = 1; next }
	{
		total++
		if (("status" in idx) && $(idx["status"]) != "OK") next
		if (("istiod_restarted" in idx) && $(idx["istiod_restarted"]) != "0") next
		if (("restarted" in idx) && $(idx["restarted"]) != "0") next
		valid++
		g = ""
		for (j = 1; j <= ng; j++) if (gc[j] in idx) g = g (g == "" ? "" : ", ") gc[j] "=" $(idx[gc[j]])
		if (g == "") g = "-"
		if (!(g in seen)) { seen[g] = 1; order[++norder] = g }
		for (j = 1; j <= nm; j++) {
			c = mc[j]
			if (c == "" || !(c in idx)) continue
			v = $(idx[c]); k = g SUBSEP c
			if (v == "overflow") { ov[k]++; has[k] = 1; continue }
			if (v ~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) {
				if (!(k in cnt) || v + 0 > mx[k]) mx[k] = v + 0
				sum[k] += v; cnt[k]++; has[k] = 1
			}
		}
	}
	END {
		printf "n\t%d\t%d\n", valid, total
		for (i = 1; i <= norder; i++) printf "g\t%s\n", order[i]
		for (k in has) {
			split(k, a, SUBSEP)
			if (k in cnt) printf "v\t%s\t%s\t%.6f\t%.6f\t%d\n", a[1], a[2], sum[k] / cnt[k], mx[k], ov[k] + 0
			else printf "v\t%s\t%s\t-\t-\t%d\n", a[1], a[2], ov[k] + 0
		}
	}' "$@"
}

# fmt_metric <kind> <mean> <max> <n_overflow> [baseline_mean]: one cell (see METRICS);
# "-" (or empty) for a mean or max means none. The change against the baseline is on
# the unrounded means; hist cells have none.
fmt_metric() {
	awk -v k="$1" -v m="$2" -v mx="$3" -v ov="$4" -v b="${5:-}" '
	function bucket_range(v) {
		if (v + 0 <= 0)     return "N/A"
		if (v + 0 <= 100)   return "0-100"
		if (v + 0 <= 500)   return "100-500"
		if (v + 0 <= 1000)  return "500-1000"
		if (v + 0 <= 3000)  return "1000-3000"
		if (v + 0 <= 5000)  return "3000-5000"
		if (v + 0 <= 10000) return "5000-10000"
		if (v + 0 <= 20000) return "10000-20000"
		if (v + 0 <= 30000) return "20000-30000"
		return ">30000"
	}
	BEGIN {
		if (m == "-") m = ""
		if (mx == "-") mx = ""
		if (b == "-") b = ""
		if (k == "hist") {
			if (ov + 0 > 0) printf "overflow (%d %s)", ov, (ov + 0 == 1 ? "row" : "rows")
			else printf "%s", (mx == "" ? "-" : bucket_range(mx))
			exit
		}
		if (m == "") { printf "-"; exit }
		v = (k == "kib") ? m / 1024 : m + 0
		if (k == "ms") s = sprintf("%.2f", v)
		else if (k == "kib" || k == "qps") s = sprintf("%.1f", v)
		else if (k == "count") s = (v == int(v)) ? sprintf("%d", v) : sprintf("%.1f", v)
		else s = sprintf("%.0f", v)
		if (b != "" && b + 0 != 0) s = s sprintf(" (%+.1f%%)", (m - b) / b * 100)
		printf "%s", s
	}'
}

declare -A VAL VMAX VOV NROWS STATUS GSEEN
declare -A PLAT  # pass -> its platform record (KEY=value lines, platform_report_values)
GROUP_VALUES=()
for p in "${PASSES[@]}"; do
	STATUS[$p]="ok"
	for marker in SETUP_FAILED PROBE_FAILED REVERT_FAILED; do
		[[ -f "${RESULTS_DIR}/${p}/${marker}" ]] && { STATUS[$p]="$marker"; break; }
	done
	mapfile -t files < <(pass_tsvs "$p")
	if ((${#files[@]} == 0)); then
		[[ "${STATUS[$p]}" == ok ]] && STATUS[$p]="no data"
		continue
	fi
	while IFS=$'\t' read -r kind a b c d e; do
		case "$kind" in
		n) NROWS[$p]="${a}/${b}" ;;
		g) [[ -n "${GSEEN[$a]:-}" ]] || { GSEEN[$a]=1; GROUP_VALUES+=("$a"); } ;;
		v) VAL["$p|$a|$b"]="$c"; VMAX["$p|$a|$b"]="$d"; VOV["$p|$a|$b"]="$e" ;;
		esac
	done < <(summarize "${files[@]}")
	PLAT[$p]="$(platform_report_values "${files[@]}")"
done
((${#GROUP_VALUES[@]})) || GROUP_VALUES=("-")

BASE=""
[[ " ${PASSES[*]} " == *" baseline "* ]] && BASE="baseline"

# Rows: label, then one cell per pass.
ROWS=()
row() { local IFS=$'\t'; ROWS+=("$*"); }
cells=("Pass status")
for p in "${PASSES[@]}"; do cells+=("${STATUS[$p]}"); done
row "${cells[@]}"
cells=("Valid / total rows")
for p in "${PASSES[@]}"; do cells+=("${NROWS[$p]:-0/0}"); done
row "${cells[@]}"
# The platform record: one row, each pass against the reference pass (the baseline, else the
# first pass with data; platform_compare_values: an operator that differs only in its state is
# the same build), and the values once after the table (render). A pass that differs, or cannot
# be compared, warns in the output and on stderr (PL39).
REF=""
[[ -z "$BASE" || -z "${PLAT[$BASE]:-}" ]] || REF="$BASE"
if [[ -z "$REF" ]]; then
	for p in "${PASSES[@]}"; do
		[[ -z "${PLAT[$p]:-}" ]] || { REF="$p"; break; }
	done
fi
REF_NAME="baseline"
[[ "$REF" == "$BASE" ]] || REF_NAME="reference pass (${REF}, the first with data)"
# What a pass that differs from REF's record cannot claim (without a baseline, no change column).
REF_EFFECT="its change against the baseline is not the profile's alone"
[[ "$REF" == "$BASE" ]] || REF_EFFECT="its difference from the ${REF_NAME} is not the profiles' alone"
declare -A PLAT_DIFF PLAT_UNK  # pass -> the record keys that differ from / cannot be compared with REF's
PLAT_WARNINGS=()
PLAT_KEYS_ALL="$(IFS=,; echo "${PLATFORM_PASS_KEYS[*]}")"
PLAT_KEYS_ALL="${PLAT_KEYS_ALL//,/, }"
cells=("Platform record")
for p in "${PASSES[@]}"; do
	if [[ -z "${PLAT[$p]:-}" ]]; then cells+=("-"); continue; fi
	if [[ "$p" == "$REF" ]]; then
		if [[ "$REF" == "$BASE" ]]; then cells+=("baseline"); else cells+=("reference"); fi
		continue
	fi
	dk="" uk=""
	while IFS=$'\t' read -r k res; do
		case "$res" in
		differs) dk+="${dk:+, }${k}" ;;
		unknown) uk+="${uk:+, }${k}" ;;
		esac
	done < <(platform_compare_values "${PLAT[$REF]}" "${PLAT[$p]}" "${PLATFORM_PASS_KEYS[@]}")
	PLAT_DIFF[$p]="$dk" PLAT_UNK[$p]="$uk"
	if [[ -n "$dk" ]]; then
		cells+=("differs (see notes)")
		PLAT_WARNINGS+=("pass ${p} differs from the ${REF_NAME} on ${dk} (its values follow the table), so ${REF_EFFECT}")
	elif [[ -n "$uk" ]]; then
		cells+=("unknown (see notes)")
	else
		cells+=("same")
	fi
	if [[ "$uk" == "$PLAT_KEYS_ALL" ]]; then
		PLAT_WARNINGS+=("pass ${p}: no key of its platform record can be compared with the ${REF_NAME} (its TSVs predate the record, or nothing could be read), so whether it ran on the same platform and builds is not known")
	elif [[ -n "$uk" ]]; then
		PLAT_WARNINGS+=("pass ${p}: ${uk} could not be compared with the ${REF_NAME} (not read, or not recorded, in one of them), so whether it ran on the same platform and builds is not known")
	fi
done
row "${cells[@]}"
for w in ${PLAT_WARNINGS[@]+"${PLAT_WARNINGS[@]}"}; do echo "warning: ${w}" >&2; done
# plat_lines <pass> [keys CSV]: "KEY<TAB>value" of a pass's record, digests shortened (the TSVs
# keep them in full): every key, a value every member shares once (the reference pass); or
# those keys against REF's, only the members that do not match it (platform_value_against), so
# a record of hundreds of members stays one short line.
plat_lines() {
	local kv ref
	while IFS= read -r kv; do
		[[ -n "$kv" ]] || continue
		if [[ -z "${2:-}" ]]; then
			printf '%s\t%s\n' "${kv%%=*}" "$(platform_short_digests "$(platform_collapse "${kv#*=}")")"
			continue
		fi
		[[ ", ${2}, " == *", ${kv%%=*}, "* ]] || continue
		ref="$(sed -n "s/^${kv%%=*}=//p" <<<"${PLAT[$REF]:-}" | head -n 1)"
		printf '%s\t%s\n' "${kv%%=*}" "$(platform_short_digests "$(platform_value_against "${kv%%=*}" "${kv#*=}" "${ref:-unknown}")")"
	done <<<"${PLAT[$1]:-}"
}
# plat_head <pass>: the heading of a pass's note after the table (the keys it differs on or
# cannot be compared on); return 1, with one line instead, when every value it has is unknown.
plat_head() {
	local kv known=0
	while IFS= read -r kv; do
		[[ -z "$kv" || "$(platform_collapse "${kv#*=}")" == unknown ]] || known=1
	done <<<"${PLAT[$1]:-}"
	if ((known == 0)) && [[ -z "${PLAT_DIFF[$1]:-}" ]]; then
		echo "Pass ${1}: every value of its platform record is unknown (its TSVs predate the record, or nothing could be read)."
		return 1
	fi
	echo "Pass ${1}$([[ -z "${PLAT_DIFF[$1]:-}" ]] || echo ", differs on ${PLAT_DIFF[$1]}")$([[ -z "${PLAT_UNK[$1]:-}" ]] || echo ", cannot be compared on ${PLAT_UNK[$1]}"):"
}
for g in "${GROUP_VALUES[@]}"; do
	for m in "${METRICS[@]}"; do
		col="${m%%|*}" rest="${m#*|}"
		label="${rest%|*}" kind="${rest##*|}"
		[[ "$g" != "-" ]] && label="${label} @ ${g}"
		cells=("$label")
		any=0
		for p in "${PASSES[@]}"; do
			k="$p|$g|$col"
			if [[ -z "${VAL[$k]:-}" ]]; then cells+=("-"); continue; fi
			any=1
			b=""
			[[ -n "$BASE" && "$p" != "$BASE" ]] && b="${VAL["$BASE|$g|$col"]:-}"
			cells+=("$(fmt_metric "$kind" "${VAL[$k]}" "${VMAX[$k]}" "${VOV[$k]}" "$b")")
		done
		((any)) && row "${cells[@]}"
	done
done

render() {
	if [[ "$FORMAT" == markdown ]]; then
		echo "# Tuning sweep comparison"
		echo ""
		echo "- Suite: ${SUITE}"
		[[ -n "$(meta_get RUN_ID)" ]] && echo "- Run: $(meta_get RUN_ID)"
		[[ -n "$(meta_get CONTEXTS)" ]] && echo "- Contexts: $(meta_get CONTEXTS)"
		echo "- Values are means over valid rows (status OK, no istiod restart). Profiles show the change against the baseline in brackets."
		echo "- Histogram p99 rows (\"worst bucket\") are never averaged: they show the highest bucket range a valid row hit, or \"overflow (N rows)\" when N rows had their p99 in the +Inf bucket."
		for w in ${PLAT_WARNINGS[@]+"${PLAT_WARNINGS[@]}"}; do echo "- **Warning:** ${w}"; done
		echo ""
		local hdr="| Metric |" sep="|---|" r
		for p in "${PASSES[@]}"; do hdr+=" ${p} |"; sep+="---|"; done
		echo "$hdr"
		echo "$sep"
		for r in "${ROWS[@]}"; do echo "| ${r//$'\t'/ | } |"; done
		if [[ -n "$REF" ]]; then
			echo ""
			echo "### Platform record"
			echo ""
			echo "The record of the ${REF_NAME}, digests shortened to 12 hex digits (the TSVs keep them in full):"
			echo ""
			plat_lines "$REF" | awk -F'\t' '{ printf "- %s: `%s`\n", $1, $2 }'
			for p in "${PASSES[@]}"; do
				[[ -n "${PLAT_DIFF[$p]:-}${PLAT_UNK[$p]:-}" ]] || continue
				echo ""
				plat_head "$p" || continue
				echo ""
				plat_lines "$p" "${PLAT_DIFF[$p]:-}${PLAT_DIFF[$p]:+${PLAT_UNK[$p]:+, }}${PLAT_UNK[$p]:-}" | awk -F'\t' '{ printf "- %s: `%s`\n", $1, $2 }'
			done
		fi
	else
		echo "Tuning sweep comparison (suite: ${SUITE})"
		echo "Means over valid rows; profiles show the change against the baseline."
		echo "Histogram p99 rows show the worst bucket a valid row hit (or overflow), not a mean."
		for w in ${PLAT_WARNINGS[@]+"${PLAT_WARNINGS[@]}"}; do echo "WARNING: ${w}"; done
		echo ""
		{
			printf 'Metric'
			printf '\t%s' "${PASSES[@]}"
			printf '\n'
			printf '%s\n' "${ROWS[@]}"
		} | awk -F'\t' '
			{ for (i = 1; i <= NF; i++) { cell[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } if (NF > nf) nf = NF }
			END { for (r = 1; r <= NR; r++) { line = ""; for (i = 1; i <= nf; i++) line = line sprintf("%-" w[i] "s  ", cell[r, i]); sub(/ +$/, "", line); print line } }'
		if [[ -n "$REF" ]]; then
			echo ""
			echo "Platform record of the ${REF_NAME}, digests shortened to 12 hex digits (the TSVs keep them in full):"
			plat_lines "$REF" | awk -F'\t' '{ printf "  %-25s %s\n", $1, $2 }'
			for p in "${PASSES[@]}"; do
				[[ -n "${PLAT_DIFF[$p]:-}${PLAT_UNK[$p]:-}" ]] || continue
				plat_head "$p" || continue
				plat_lines "$p" "${PLAT_DIFF[$p]:-}${PLAT_DIFF[$p]:+${PLAT_UNK[$p]:+, }}${PLAT_UNK[$p]:-}" | awk -F'\t' '{ printf "  %-25s %s\n", $1, $2 }'
			done
		fi
	fi
}

if [[ -n "$OUTPUT_FILE" ]]; then
	render >"$OUTPUT_FILE"
	echo "Comparison written to ${OUTPUT_FILE}" >&2
else
	render
fi

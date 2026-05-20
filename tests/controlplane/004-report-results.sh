#!/usr/bin/env bash
# Generate summary statistics from control-plane resource metrics TSV files.
#
# Groups by (mesh_size, sidecar_scoping) and emits text/csv/markdown/json with
# a metadata preamble per PL2.
#
# Usage:
#   ./tests/controlplane/004-report-results.sh [--results-dir DIR] [--format FMT]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

RESULTS_DIR="${ROOT}/tests/controlplane/results"
FORMAT="text"

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --results-dir DIR  Results directory (default: tests/controlplane/results).
  --format FMT       Output format: text, csv, markdown, json (default: text).
  -h, --help         Show this help.
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

case "$FORMAT" in
text | csv | markdown | json) ;;
*) die "unknown format: $FORMAT (use text, csv, markdown, json)" ;;
esac

[[ -d "$RESULTS_DIR" ]] || die "results directory not found: $RESULTS_DIR"

TSV_FILES=()
while IFS= read -r f; do
	TSV_FILES+=("$f")
done < <(find "$RESULTS_DIR" -name 'controlplane-*.tsv' -type f 2>/dev/null | sort)

if [[ ${#TSV_FILES[@]} -eq 0 ]]; then
	die "no TSV result files found in $RESULTS_DIR"
fi

# Extract preamble metadata (PL2) from the first TSV file.
PREAMBLE_FILE="${TSV_FILES[0]}"
preamble_meta() {
	local key="$1"
	awk -v k="$key" 'BEGIN{FS="="} /^#/ && index($0, k"=") {sub(/^#[[:space:]]*/,"",$0); sub("^"k"=","",$0); print; exit}' "$PREAMBLE_FILE"
}

RUN_ID="$(preamble_meta RUN_ID)"
HARNESS_SHA="$(preamble_meta HARNESS_SHA)"
ISTIO_VER="$(preamble_meta ISTIO_VERSION)"
SETTLE_M="$(preamble_meta SETTLE_SEC)"

# C3: extract more preamble fields and concatenate kube versions across rows.
CONFIG_DUMP_SAMPLES_M="$(preamble_meta CONFIG_DUMP_SAMPLES)"

# SIDECAR_SCOPING is per-combo on the data rows; the preamble only records
# the value used at scrape time. If every TSV in this RUN_ID agrees, emit
# that scalar; otherwise emit "(per-row)".
collect_scopings_meta() {
	local f scoping seen=""
	for f in "${TSV_FILES[@]}"; do
		scoping="$(awk -F'=' '/^# SIDECAR_SCOPING=/{print $2; exit}' "$f")"
		[[ -z "$scoping" ]] && continue
		if [[ -z "$seen" ]]; then
			seen="$scoping"
		elif [[ "$seen" != "$scoping" && "$seen" != "(per-row)" ]]; then
			seen="(per-row)"
		fi
	done
	echo "$seen"
}
SIDECAR_SCOPING_M="$(collect_scopings_meta)"

# Concatenate all observed KUBE_VERSION lines into a single readable string.
collect_kube_versions_meta() {
	local f line all=""
	for f in "${TSV_FILES[@]}"; do
		while IFS= read -r line; do
			[[ "$line" =~ ^#\ KUBE_VERSION\[(.+)\]=(.*)$ ]] || continue
			local entry="${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
			# Avoid duplicates.
			if [[ -z "$all" ]]; then
				all="$entry"
			elif [[ "$all" != *"$entry"* ]]; then
				all="${all}, ${entry}"
			fi
		done < <(grep -E '^# KUBE_VERSION\[' "$f" 2>/dev/null || true)
	done
	echo "$all"
}
KUBE_VERSIONS_M="$(collect_kube_versions_meta)"

# Shared awk that aggregates TSV records by (mesh_size, scoping).
# SC2016: awk fields ($1, etc.) intentionally not shell-expanded.
#
# TSV schema after A1 (config_size_bytes dropped) — 23 columns:
#   1 ts          2 ctx          3 mesh_size    4 service_count  5 replicas
#   6 scoping     7 cpu_m        8 mem_mi       9 conv_p50      10 conv_p99
#  11 queue_p50  12 queue_p99   13 xds_pushes  14 k8s_events    15 proxies
#  16 cfg_avg    17 cfg_p50     18 cfg_max     19 samples       20 window_sec
#  21 skew_ms    22 restarted   23 settle_sec
#
# A5: rows with restarted=1 are excluded from numeric aggregation; rows with
# overflow on conv/queue quantiles are also excluded for those columns only.
# `n_total` counts every data row in the (ms, scope) cell; `n_valid` is the
# number of restart-clean rows that contributed to averages.
# shellcheck disable=SC2016
AWK_AGG='
BEGIN { FS="\t" }
!/^#/ && !/^timestamp/ && NF>=23 {
	ms=$3; scope=$6
	key=ms "|" scope
	keys[key]=1
	count_total[key]++

	# A5: skip the entire row from numeric aggregation when istiod restarted
	# OR any quantile column overflowed (target landed in +Inf bucket).
	# n_valid records how many rows survived this filter.
	if ($22 == "1") { any_restarted[key]=1; next }
	if ($22 == "unknown") any_restart_unknown[key]=1
	if ($9=="overflow" || $10=="overflow" || $11=="overflow" || $12=="overflow") {
		any_overflow[key]=1; next
	}

	count_valid[key]++

	if ($7  ~ /^[0-9.]+$/) { cpu_n[key]++;    cpu_v[key,cpu_n[key]]=$7+0 }
	if ($8  ~ /^[0-9.]+$/) { mem_n[key]++;    mem_v[key,mem_n[key]]=$8+0 }
	if ($9  ~ /^[0-9.]+$/) { c50_n[key]++;    c50_v[key,c50_n[key]]=$9+0 }
	if ($10 ~ /^[0-9.]+$/) { c99_n[key]++;    c99_v[key,c99_n[key]]=$10+0 }
	if ($12 ~ /^[0-9.]+$/) { q99_n[key]++;    q99_v[key,q99_n[key]]=$12+0 }
	if ($13 ~ /^[0-9.]+$/) { xds_n[key]++;    xds_v[key,xds_n[key]]=$13+0 }
	if ($15 ~ /^[0-9.]+$/) { prx_n[key]++;    prx_v[key,prx_n[key]]=$15+0 }
	# cfg_avg/max now at $16/$18 (was $17/$19).
	if ($16 ~ /^[0-9.]+$/) { avg_n[key]++;    avg_v[key,avg_n[key]]=$16+0 }
	if ($18 ~ /^[0-9.]+$/) { if($18+0 > max_max[key]+0) max_max[key]=$18+0 }
}
END {
	# Build text rows: mesh_size, scope, n_total, n_valid, cpu, mem, c50, c99, q99, xds, prx, avg_cfg, max_cfg, overflow, restarted
	nkeys=0
	for (kk in keys) sorted[++nkeys]=kk
	for (i=1;i<=nkeys;i++) for (j=i+1;j<=nkeys;j++) {
		split(sorted[i], pi, "|"); split(sorted[j], pj, "|")
		swap=0
		if (pi[1]+0 > pj[1]+0) swap=1
		else if (pi[1]+0 == pj[1]+0 && pi[2] > pj[2]) swap=1
		if (swap) { t=sorted[i]; sorted[i]=sorted[j]; sorted[j]=t }
	}
	for (i=1; i<=nkeys; i++) {
		k = sorted[i]
		split(k, parts, "|")
		ms    = parts[1]
		scope = parts[2]
		n_total = count_total[k]
		n_valid = count_valid[k] + 0
		cpu = (cpu_n[k] ? sum_arr("cpu_v", k, cpu_n[k]) / cpu_n[k] : 0)
		mem = (mem_n[k] ? sum_arr("mem_v", k, mem_n[k]) / mem_n[k] : 0)
		c50 = (c50_n[k] ? sum_arr("c50_v", k, c50_n[k]) / c50_n[k] : 0)
		c99 = (c99_n[k] ? sum_arr("c99_v", k, c99_n[k]) / c99_n[k] : 0)
		q99 = (q99_n[k] ? sum_arr("q99_v", k, q99_n[k]) / q99_n[k] : 0)
		xds = (xds_n[k] ? sum_arr("xds_v", k, xds_n[k]) / xds_n[k] : 0)
		prx = (prx_n[k] ? sum_arr("prx_v", k, prx_n[k]) / prx_n[k] : 0)
		acfg= (avg_n[k] ? sum_arr("avg_v", k, avg_n[k]) / avg_n[k] : 0)
		over= (any_overflow[k] ? "overflow" : "ok")
		rest= (any_restarted[k] ? "1" : (any_restart_unknown[k] ? "unknown" : "0"))
		printf "%s\t%s\t%d\t%d\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%s\t%s\n", \
			ms, scope, n_total, n_valid, cpu, mem, c50, c99, q99, xds, prx, acfg, max_max[k]+0, over, rest
	}
}
function sum_arr(name, k, n,    i, s) {
	s=0
	if (name=="cpu_v") for(i=1;i<=n;i++) s += cpu_v[k,i]
	if (name=="mem_v") for(i=1;i<=n;i++) s += mem_v[k,i]
	if (name=="c50_v") for(i=1;i<=n;i++) s += c50_v[k,i]
	if (name=="c99_v") for(i=1;i<=n;i++) s += c99_v[k,i]
	if (name=="q99_v") for(i=1;i<=n;i++) s += q99_v[k,i]
	if (name=="xds_v") for(i=1;i<=n;i++) s += xds_v[k,i]
	if (name=="prx_v") for(i=1;i<=n;i++) s += prx_v[k,i]
	if (name=="avg_v") for(i=1;i<=n;i++) s += avg_v[k,i]
	return s
}'

# Run aggregation once into a temp file.
TMP_AGG="$(mktemp)"
trap 'rm -f "$TMP_AGG"' EXIT
cat "${TSV_FILES[@]}" | awk "$AWK_AGG" >"$TMP_AGG"

emit_preamble_text() {
	cat <<EOF
=== Control-Plane Resource Scaling Report ===
RUN_ID:             ${RUN_ID:-N/A}
Harness SHA:        ${HARNESS_SHA:-N/A}
Istio version:      ${ISTIO_VER:-N/A}
Sidecar scoping:    ${SIDECAR_SCOPING_M:-N/A}
Config-dump samples:${CONFIG_DUMP_SAMPLES_M:-N/A}
Settle (sec):       ${SETTLE_M:-N/A}
Kube versions:      ${KUBE_VERSIONS_M:-N/A}
Files:              ${#TSV_FILES[@]}

EOF
}

report_text() {
	emit_preamble_text
	# A5: row layout now has n_total + n_valid; n_valid distinguishes
	# rows that contributed averages from rows skipped for restart.
	awk -F'\t' '
	BEGIN {
		printf "%-10s %-10s %5s %5s %8s %8s %7s %7s %7s %10s %7s %12s %12s %-9s %-8s\n", \
			"mesh_size", "scoping", "n_tot", "n_val", "cpu_m", "mem_mi", "c50_ms", "c99_ms", "q99_ms", \
			"xds_push", "proxy", "cfg_bytes", "cfg_max_b", "histo", "restart"
		printf "%-10s %-10s %5s %5s %8s %8s %7s %7s %7s %10s %7s %12s %12s %-9s %-8s\n", \
			"---------", "-------", "-----", "-----", "------", "------", "------", "------", "------", \
			"--------", "-----", "----------", "----------", "-----", "-------"
	}
	{
		printf "%-10s %-10s %5d %5d %8d %8d %7d %7d %7d %10d %7d %12d %12d %-9s %-8s\n", \
			$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15
	}' "$TMP_AGG"
	printf "\nNote: n_val < n_tot indicates rows skipped due to istiod restart or histogram quantile overflow in the scrape window.\n"
}

report_csv() {
	echo "# RUN_ID=${RUN_ID:-}"
	echo "# HARNESS_SHA=${HARNESS_SHA:-}"
	echo "# ISTIO_VERSION=${ISTIO_VER:-}"
	echo "# SIDECAR_SCOPING=${SIDECAR_SCOPING_M:-}"
	echo "# CONFIG_DUMP_SAMPLES=${CONFIG_DUMP_SAMPLES_M:-}"
	echo "# SETTLE_SEC=${SETTLE_M:-}"
	echo "# KUBE_VERSIONS=${KUBE_VERSIONS_M:-}"
	echo "mesh_size,sidecar_scoping,n_total,n_valid,cpu_m,mem_mi,conv_p50_ms,conv_p99_ms,queue_p99_ms,xds_pushes,connected_proxies,sidecar_config_bytes_avg,sidecar_config_bytes_max,histogram_overflow,istiod_restarted"
	awk -F'\t' '{ for(i=1;i<=NF;i++){printf "%s%s", $i, (i==NF?"\n":",")} }' "$TMP_AGG"
}

report_markdown() {
	cat <<EOF
---
run_id: "${RUN_ID:-}"
harness_sha: "${HARNESS_SHA:-}"
istio_version: "${ISTIO_VER:-}"
sidecar_scoping: "${SIDECAR_SCOPING_M:-}"
config_dump_samples: "${CONFIG_DUMP_SAMPLES_M:-}"
settle_sec: "${SETTLE_M:-}"
kube_versions: "${KUBE_VERSIONS_M:-}"
---

# Control-Plane Resource Scaling Report

| Field | Value |
|-------|-------|
| RUN_ID | \`${RUN_ID:-N/A}\` |
| Harness SHA | \`${HARNESS_SHA:-N/A}\` |
| Istio version | ${ISTIO_VER:-N/A} |
| Sidecar scoping | ${SIDECAR_SCOPING_M:-N/A} |
| Config-dump samples | ${CONFIG_DUMP_SAMPLES_M:-N/A} |
| Settle (sec) | ${SETTLE_M:-N/A} |
| Kube versions | ${KUBE_VERSIONS_M:-N/A} |
| Source TSV files | ${#TSV_FILES[@]} |

## Aggregated metrics by (mesh_size, sidecar_scoping)

\`n_total\` is every data row in the cell; \`n_valid\` is the subset that
contributed to averages (rows where istiod restarted within the scrape
window are excluded — see footnote).

| mesh_size | scoping | n_total / n_valid | cpu_m | mem_mi | c50_ms | c99_ms | q99_ms | xds_pushes | proxies | cfg_bytes_avg | cfg_bytes_max | histogram | restart |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|:--|:--|
EOF
	awk -F'\t' '
	{
		printf "| %s | %s | %s / %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", \
			$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15
	}' "$TMP_AGG"

	# A5: footnote about row drops.
	cat <<'EOF'

> Footnote: rows where `istiod_restarted=1` OR any histogram quantile
> column equals `overflow` are excluded from numeric averages.
> `n_total / n_valid` shows the split per cell so the reader can see how
> many rows were dropped.

## Sidecar scoping effect on per-proxy config size

Lower is better. The expected ordering is `none` > `namespace` >= `explicit`.

EOF
	awk -F'\t' '
	{
		# cfg_avg is at column 12 in the aggregated rows.
		ms=$1; scope=$2; cfg=$12+0
		bym_val[ms,scope]=cfg
		bym_has[ms,scope]=1
		ms_seen[ms]=1
	}
	END {
		printf "| mesh_size | none (bytes) | namespace (bytes) | explicit (bytes) | none→namespace | none→explicit |\n"
		printf "|---:|---:|---:|---:|---:|---:|\n"
		nkeys=0
		for (k in ms_seen) sorted[++nkeys]=k
		for(i=1;i<=nkeys;i++) for(j=i+1;j<=nkeys;j++) if (sorted[i]+0 > sorted[j]+0) { t=sorted[i]; sorted[i]=sorted[j]; sorted[j]=t }
		for(i=1;i<=nkeys;i++) {
			ms=sorted[i]
			n_val = (bym_has[ms,"none"] ? bym_val[ms,"none"] : -1)
			ns_val= (bym_has[ms,"namespace"] ? bym_val[ms,"namespace"] : -1)
			ex_val= (bym_has[ms,"explicit"] ? bym_val[ms,"explicit"] : -1)
			ns_red= (n_val>0 && ns_val>=0 ? sprintf("%.1f%%", 100*(n_val-ns_val)/n_val) : "N/A")
			ex_red= (n_val>0 && ex_val>=0 ? sprintf("%.1f%%", 100*(n_val-ex_val)/n_val) : "N/A")
			printf "| %s | %s | %s | %s | %s | %s |\n", ms, \
				(n_val<0?"N/A":n_val), (ns_val<0?"N/A":ns_val), (ex_val<0?"N/A":ex_val), \
				ns_red, ex_red
		}
	}' "$TMP_AGG"
}

report_json() {
	# C3: metadata object includes scoping / config-dump samples / kube
	# versions in addition to the original fields.
	{
		echo "{"
		echo "  \"metadata\": {"
		echo "    \"run_id\": \"${RUN_ID:-}\","
		echo "    \"harness_sha\": \"${HARNESS_SHA:-}\","
		echo "    \"istio_version\": \"${ISTIO_VER:-}\","
		echo "    \"sidecar_scoping\": \"${SIDECAR_SCOPING_M:-}\","
		echo "    \"config_dump_samples\": \"${CONFIG_DUMP_SAMPLES_M:-}\","
		echo "    \"settle_sec\": \"${SETTLE_M:-}\","
		echo "    \"kube_versions\": \"${KUBE_VERSIONS_M:-}\""
		echo "  },"
		echo "  \"rows\": ["
		awk -F'\t' '
		{
			rows[NR]=sprintf("    {\"mesh_size\": %s, \"sidecar_scoping\": \"%s\", \"n_total\": %s, \"n_valid\": %s, \"cpu_m\": %s, \"mem_mi\": %s, \"conv_p50_ms\": %s, \"conv_p99_ms\": %s, \"queue_p99_ms\": %s, \"xds_pushes\": %s, \"connected_proxies\": %s, \"sidecar_config_bytes_avg\": %s, \"sidecar_config_bytes_max\": %s, \"histogram\": \"%s\", \"istiod_restarted\": \"%s\"}", \
				$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
		}
		END {
			for(i=1;i<=NR;i++) printf "%s%s\n", rows[i], (i<NR?",":"")
		}' "$TMP_AGG"
		echo "  ]"
		echo "}"
	}
}

case "$FORMAT" in
text)     report_text ;;
csv)      report_csv ;;
markdown) report_markdown ;;
json)     report_json ;;
esac

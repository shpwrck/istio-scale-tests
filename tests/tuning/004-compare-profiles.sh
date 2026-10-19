#!/usr/bin/env bash
# Compare the passes of a tuning sweep (baseline + one directory per profile).
# Reads each pass's suite TSV, finds columns by header name, averages the valid rows
# and shows each profile's change against the baseline. Each pass's platform record
# (PLATFORM, the mesh operator, istiod and gateway proxy builds, the node provider, each
# member's Kubernetes version: tests/lib/platform.sh PLATFORM_PASS_KEYS; not istiod's settings,
# which a profile changes), its tuning levers and root Sidecar egress hosts, and each member's
# istiod limits where its TSVs record them (platform_lever_values) are compared with the
# baseline's (else the first pass with data's), member by member, in one "Platform record" row;
# its values follow the table once. A pass whose record differs (or cannot be compared), is not
# one value in its TSVs, changed during it, or was not compared at its end (its
# platform-drift.txt: what the read after its probes found changed or could not read again;
# none: that read did not run) warns: its change is then not the profile's alone, or not known
# to be. A lever, the egress hosts or a limit that the pass's profile sets (its state/objects or
# state/patch.json) is shown, not warned. Two more rows: each pass's istiod settings (one
# digest; a pass whose members differ, whose value changed during it or could not be read on a
# member, whose istiod pods ran different settings at once, or whose settings contradict its
# profile against the baseline's warns) and its tuning profile objects (the baseline must hold
# none, a profile pass all of its own on every member and no other: anything else warns).
#
# Usage:
#   ./tests/tuning/004-compare-profiles.sh --results-dir DIR [--format text|md] [--output FILE]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# platform_report_values, platform_merge_by_context, platform_lever_values, platform_drift_changes,
# platform_drift_unread, platform_compare_values, platform_compare_members, platform_collapse,
# platform_value_against, platform_members_by_value, platform_short_digests,
# platform_tuning_objects_check
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/platform.sh"

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
compares each pass's platform, mesh builds, Kubernetes versions, tuning levers, root
Sidecar egress hosts and istiod limits (each member's; only the controlplane suite's TSVs
record them, so another suite's comparison cannot see a limit, nor the CPU limit's
GOMAXPROCS, which istiod's env takes from limits.cpu and its digest does not show) with
the reference pass's (the baseline, else the first pass with data), member by member:
same; same (see notes: only what its profile sets differs, a lever or the egress hosts
whose object its state/objects lists, or discoverySelectors or a limit its
state/patch.json sets); differs (see notes); changed (see notes: the read at its end
found a build, a Kubernetes version, a tuning lever or an istiod limit changed during it,
its platform-drift.txt); mixed (see notes: its TSVs disagree); unknown (see notes: not
read or not recorded in one of them, or not compared at its end: not read again then, or
no platform-drift.txt, the read did not run); baseline or reference (the pass compared
with, "(see notes)" after it when it changed, its TSVs disagree or it was not compared at
its end); or - (no data). A member that ran the value the reference pass started or ended
with there matches it (that change is the reference pass's warning), and an operator
that differs only in its state is the same build. istiod's settings
(ISTIOD_ENV_BY_CONTEXT) and a profile's objects (TUNING_OBJECTS_BY_CONTEXT) are not
compared, since a profile changes them: the "istiod env" row shows each pass's digest (by
member (see notes) when its members differ, mixed (see notes) when its TSVs or the read
at its end disagree, unknown (see notes) when no member's could be read, and "(see
notes)" after it when a member's could not be read, when a member's istiod pods ran
different settings at once ("+"-joined: a rollout caught midway), when it is the
baseline's though the profile sets istiod's env, or another though the profile patches
nothing in the Istio CR: state/patch.json), and the "Tuning objects" row whether a pass
held none, all of its own profile's on every member and no other (own: its marker and
its resources, state/objects), another profile's (other, or any in the baseline: a
profile left applied), not all of its own (missing: the profile undone during the pass
or never applied there) or could not be told (unknown); anything but none, own and the
digests warns. A pass without data reads - in both. The values follow the table,
digests shortened to 12 hex digits: the reference pass's, then for each pass that
differs, changed, is mixed, cannot be compared or has what its profile sets, only the
members that do not match (five at most, with a count), what changed during it, what it
could not compare at its end, and what its profile sets.

Options:
  --results-dir DIR  Sweep directory (tests/tuning/results/sweep-<RUN_ID>) (required).
  --format FMT       text or md (or markdown) (default: text).
  --output FILE      Write to FILE instead of stdout.
  -h, --help         Show this help.

Requires jq (it reads each profile pass's state/patch.json).
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
command -v jq >/dev/null 2>&1 || die "jq not found on PATH: it reads each profile pass's state/patch.json"

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
# pass -> its platform record (KEY=value lines: platform_report_values, then its members'
# Kubernetes versions and platform_lever_values), what the read at its end found changed during
# it ("KEY<TAB>noun<TAB>what" lines: platform_drift_changes; not istiod's settings or the tuning
# objects, which their rows show) and could not compare ("KEY<TAB>members":
# platform_drift_unread), and 1 when that read left no platform-drift.txt
declare -A PLAT DRIFT UNREAD NODRIFT
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
	# The rows below word each case for the pass, so the warnings the library prints for a sweep's
	# report are left out.
	PLAT[$p]="$(platform_report_values "${files[@]}" 2>/dev/null)"
	PLAT[$p]+=$'\n'"KUBE_VERSIONS=$(platform_merge_by_context KUBE_VERSIONS "${files[@]}" 2>/dev/null)"
	# Its tuning levers, root Sidecar egress hosts and (controlplane) each member's istiod limits.
	levers="$(platform_lever_values "${files[@]}")"
	[[ -z "$levers" ]] || PLAT[$p]+=$'\n'"$levers"
	DRIFT[$p]="$(platform_drift_changes "${files[@]}" | awk -F'\t' '$1 != "ISTIOD_ENV_BY_CONTEXT" && $1 != "TUNING_OBJECTS_BY_CONTEXT"')"
	# What the read at its end could not compare; none of it without its drift file (that read did
	# not run: the run stopped during the pass, or predates it).
	UNREAD[$p]="$(platform_drift_unread "${files[@]}")"
	[[ -f "${RESULTS_DIR}/${p}/${PLATFORM_DRIFT_FILE}" ]] || NODRIFT[$p]=1
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
# plat_value <pass> <key>: that key's value in the pass's record.
plat_value() { sed -n "s/^${2}=//p" <<<"${PLAT[$1]:-}" | head -n 1; }
# plat_all_unknown <pass>: return 0 when every value of the pass's platform record is unknown (its
# TSVs predate the record, or nothing could be read: one note says so); its members' Kubernetes
# versions, which TSVs from before the record have too, and its levers and limits are not part
# of it.
plat_all_unknown() {
	local kv
	while IFS= read -r kv; do
		[[ -z "$kv" || " ${PLATFORM_KEYS[*]} " != *" ${kv%%=*} "* || "$(platform_collapse "${kv#*=}")" == unknown ]] || return 1
	done <<<"${PLAT[$1]:-}"
	return 0
}
# The platform record: one row, each pass against the reference pass (the baseline, else the
# first pass with data; platform_compare_values: an operator that differs only in its state is
# the same build), and the values once after the table (render). A pass that differs, or cannot
# be compared, warns in the output and on stderr (PL39), and so does one whose record changed
# during it (the read at its end, its platform-drift.txt: also its tuning levers and istiod
# limits), is not one value in its TSVs, or was not compared at its end, whatever it is compared
# with. Every key is compared member by member, so a member that changed or is not one value (on
# either side) matches when one of its values is the other side's: that pass's own warning covers
# the change, and a member that ran a value the other side never ran still differs. A lever, the
# egress hosts or a limit the pass's profile sets (profile_sets; and the reference pass's, without
# a baseline) is shown in its notes, not warned.
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
# pass_effect <pass>: what a pass whose record changed during it, or is not one value in its TSVs,
# cannot claim: REF_EFFECT, or for the reference pass what no pass compared with it can.
pass_effect() {
	if [[ "$1" != "$REF" ]]; then
		echo "$REF_EFFECT"
	elif [[ "$REF" == "$BASE" ]]; then
		echo "no profile's change against it is the profile's alone"
	else
		echo "no pass's difference from it is the profiles' alone"
	fi
}
# The keys each pass is compared on: the record's (PLATFORM_PASS_KEYS) and the levers' and limits'.
LEVER_KEYS=(TUNING_BASELINE SIDECAR_EGRESS_HOSTS ISTIOD_CPU_LIMIT_M_BY_CONTEXT ISTIOD_MEM_LIMIT_MI_BY_CONTEXT)
COMPARE_KEYS=("${PLATFORM_PASS_KEYS[@]}" "${LEVER_KEYS[@]}")
# profile_sets <pass> [whose]: what its profile sets on purpose among the compared values, "<lever
# or key><TAB>what sets it" lines ("<whose> state/...", "its" by default): a lever, or the root
# Sidecar's egress hosts, whose object its state/objects lists (001 creates one only where the
# charts have none, so the lever reads off without it), discoverySelectors or an istiod limit its
# state/patch.json sets (a JSON merge patch on the Istio CR: the path, or a value above it that
# is not an object, which replaces it). Nothing for the baseline, without its state, or for a
# patch.json that does not parse (then each such value is compared).
profile_sets() {
	local st="${RESULTS_DIR}/${1}/state" o who="${2:-its}"
	[[ "$1" != "$BASE" ]] || return 0
	if [[ -s "${st}/objects" ]]; then
		while IFS= read -r o; do
			case "$o" in
			Sidecar/istio-system/default) printf '%s\t%s state/objects lists %s\n' sidecar "$who" "$o" SIDECAR_EGRESS_HOSTS "$who" "$o" ;;
			Telemetry/istio-system/tuning-metrics) printf 'telemetryFiltering\t%s state/objects lists %s\n' "$who" "$o" ;;
			Telemetry/istio-system/tuning-access-log) printf 'accessLogFiltering\t%s state/objects lists %s\n' "$who" "$o" ;;
			esac
		done <"${st}/objects"
	fi
	[[ -s "${st}/patch.json" ]] || return 0
	# shellcheck disable=SC2016  # jq program: $d, $i, $p, $up and $doc are jq variables
	jq -r --arg who "$who" '
		def sets($p): . as $d | first(range(1; ($p | length) + 1) as $i
			| ($d | getpath($p[0:$i - 1])) as $up
			| if ($up | type) != "object" then false
			  elif ($up | has($p[$i - 1]) | not) then false
			  elif $i == ($p | length) or ($up[$p[$i - 1]] | type) != "object" then true
			  else empty end);
		. as $doc
		| (["discoverySelectors", "spec.values.meshConfig.discoverySelectors"],
		   ["ISTIOD_CPU_LIMIT_M_BY_CONTEXT", "spec.values.pilot.resources.limits.cpu"],
		   ["ISTIOD_MEM_LIMIT_MI_BY_CONTEXT", "spec.values.pilot.resources.limits.memory"])
		| select(.[1] as $p | $doc | sets($p | split(".")))
		| "\(.[0])\t\($who) state/patch.json sets \(.[1])"' "${st}/patch.json" 2>/dev/null || true
}
# key_result <pass> <key> <result> <sets>: a key's result against REF once what <sets>
# (profile_sets lines) says a profile sets is left out, "<result><TAB><what>": for
# TUNING_BASELINE, lever by lever (platform_compare_members), differs or unknown with the levers
# that do, else set with what sets each lever that differs; for another key, set with what sets
# it, else <result>.
key_result() {
	local lever a b r why d="" u="" st=""
	if [[ "$2" == TUNING_BASELINE ]]; then
		while IFS=$'\t' read -r lever a b r; do
			[[ -n "$lever" ]] || continue
			why="$(awk -F'\t' -v k="$lever" '$1 == k { print $2; exit }' <<<"$4")"
			if [[ -n "$why" ]]; then
				st+="${st:+; }${lever}: ${why}"
			elif [[ "$r" == differs ]]; then
				d+="${d:+, }${lever}"
			else
				u+="${u:+, }${lever}"
			fi
		done < <(platform_compare_members TUNING_BASELINE "$(plat_value "$REF" TUNING_BASELINE)" "$(plat_value "$1" TUNING_BASELINE)")
		if [[ -n "$d" ]]; then
			printf 'differs\t%s\n' "$d"
		elif [[ -n "$u" ]]; then
			printf 'unknown\t%s\n' "$u"
		elif [[ -n "$st" ]]; then
			printf 'set\t%s\n' "$st"
		else
			# Not one lever on a side (its TSVs record TUNING_BASELINE unknown, or not at all).
			printf '%s\t\n' "$3"
		fi
		return 0
	fi
	why="$(awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' <<<"$4")"
	if [[ -n "$why" ]]; then printf 'set\t%s\n' "$why"; else printf '%s\t\n' "$3"; fi
}
# pass -> the keys it differs on / cannot be compared on against REF's (PLAT_DIFF, PLAT_UNK; with
# the levers, for the warnings: PLAT_DTXT, PLAT_UTXT), what its profile sets that differs
# (PLAT_SET: "KEY<TAB>what sets it" lines), the keys that changed during it (PLAT_CHG: its DRIFT
# keys), that its TSVs disagree on (PLAT_MIX) and that the read at its end could not compare
# (PLAT_NC: its UNREAD keys)
declare -A PLAT_DIFF PLAT_UNK PLAT_DTXT PLAT_UTXT PLAT_SET PLAT_CHG PLAT_MIX PLAT_NC
PLAT_WARNINGS=()
# The record's own keys (TSVs from before it still record each member's Kubernetes version).
PLAT_KEYS_ALL=""
for k in "${PLATFORM_PASS_KEYS[@]}"; do [[ "$k" == KUBE_VERSIONS ]] || PLAT_KEYS_ALL+="${PLAT_KEYS_ALL:+, }${k}"; done
for p in "${PASSES[@]}"; do
	[[ -n "${PLAT[$p]:-}" ]] || continue
	ck="" mk="" nk=""
	while IFS=$'\t' read -r k _; do [[ -z "$k" ]] || ck+="${ck:+, }${k}"; done <<<"${DRIFT[$p]:-}"
	for k in "${COMPARE_KEYS[@]}"; do
		# A key the read at its end found changed is not also mixed (istiod's limits as its TSVs
		# name them).
		x="$k"
		[[ "$k" != ISTIOD_*_LIMIT_*_BY_CONTEXT ]] || x="${k%_BY_CONTEXT}"
		[[ ", ${ck}, " != *", ${x}, "* ]] || continue
		v="$(plat_value "$p" "$k")"
		case "$k" in
		PLATFORM | TEST_PLATFORM | SIDECAR_EGRESS_HOSTS) [[ "$v" != mixed:* ]] || mk+="${mk:+, }${k}" ;;
		*) [[ ",${v}" != *"=mixed:"* ]] || mk+="${mk:+, }${k}" ;;
		esac
	done
	while IFS=$'\t' read -r k _; do [[ -z "$k" ]] || nk+="${nk:+, }${k}"; done <<<"${UNREAD[$p]:-}"
	PLAT_CHG[$p]="$ck" PLAT_MIX[$p]="$mk" PLAT_NC[$p]="$nk"
done
cells=("Platform record")
for p in "${PASSES[@]}"; do
	if [[ -z "${PLAT[$p]:-}" ]]; then cells+=("-"); continue; fi
	while IFS=$'\t' read -r k noun what; do
		[[ -z "$k" ]] || PLAT_WARNINGS+=("pass ${p}: ${k} changed during the pass (its ${PLATFORM_DRIFT_FILE}): ${what}, so part of it ran with other ${noun}, and $(pass_effect "$p")")
	done <<<"${DRIFT[$p]:-}"
	[[ -z "${PLAT_MIX[$p]:-}" ]] ||
		PLAT_WARNINGS+=("pass ${p}: its TSVs disagree on ${PLAT_MIX[$p]} (or one of them did not read or record a value; the values follow the table), so part of it may have run on another platform, build, Kubernetes version, tuning lever or istiod limit, and then $(pass_effect "$p")")
	# Not compared at its end (a pass whose whole record is unknown has one note and one warning).
	if ! plat_all_unknown "$p"; then
		if [[ -n "${NODRIFT[$p]:-}" ]]; then
			PLAT_WARNINGS+=("pass ${p}: its record was not read again at its end (no ${PLATFORM_DRIFT_FILE} in its directory: the run stopped during the pass, or it predates that read), so whether its builds, Kubernetes versions, tuning levers or istiod limits changed during it is not known")
		elif [[ -n "${UNREAD[$p]:-}" ]]; then
			w=""
			while IFS=$'\t' read -r k who; do [[ -z "$k" ]] || w+="${w:+; }${k} on ${who}"; done <<<"${UNREAD[$p]}"
			PLAT_WARNINGS+=("pass ${p}: the read again at its end could not compare ${w} (not read at its start or end, or read with a digest @unknown: no pod had started; its ${PLATFORM_DRIFT_FILE}), so whether those values changed during the pass is not known")
		fi
	fi
	if [[ "$p" == "$REF" ]]; then
		if [[ "$REF" == "$BASE" ]]; then cell="baseline"; else cell="reference"; fi
		[[ -z "${PLAT_CHG[$p]:-}${PLAT_MIX[$p]:-}${PLAT_NC[$p]:-}${NODRIFT[$p]:-}" ]] || cell+=" (see notes)"
		cells+=("$cell")
		continue
	fi
	# What its profile sets on purpose, and without a baseline the reference pass's.
	sets="$(profile_sets "$p")"
	[[ "$REF" == "$BASE" ]] || sets+="${sets:+$'\n'}$(profile_sets "$REF" "the reference pass's")"
	dk="" uk="" dt="" ut="" st="" ur="" urt="" ul=""
	while IFS=$'\t' read -r k res; do
		[[ "$res" != same ]] || continue
		# A lever or limit neither pass's TSVs record (only the controlplane suite's record the
		# limits) is not compared.
		[[ " ${LEVER_KEYS[*]} " != *" ${k} "* || -n "$(plat_value "$REF" "$k")$(plat_value "$p" "$k")" ]] || continue
		IFS=$'\t' read -r res what < <(key_result "$p" "$k" "$res" "$sets")
		case "$res" in
		differs)
			dk+="${dk:+, }${k}"
			dt+="${dt:+, }${k}${what:+ (${what})}"
			;;
		unknown)
			uk+="${uk:+, }${k}"
			ut+="${ut:+, }${k}${what:+ (${what})}"
			if [[ " ${PLATFORM_PASS_KEYS[*]} " == *" ${k} "* ]]; then
				urt+="${urt:+, }${k}"
				[[ "$k" == KUBE_VERSIONS ]] || ur+="${ur:+, }${k}"
			else
				ul+="${ul:+, }${k}${what:+ (${what})}"
			fi
			;;
		set) st+="${st:+$'\n'}${k}"$'\t'"${what}" ;;
		esac
	done < <(platform_compare_values "${PLAT[$REF]}" "${PLAT[$p]}" "${COMPARE_KEYS[@]}")
	PLAT_DIFF[$p]="$dk" PLAT_UNK[$p]="$uk" PLAT_DTXT[$p]="$dt" PLAT_UTXT[$p]="$ut" PLAT_SET[$p]="$st"
	if [[ -n "$dk" ]]; then
		cells+=("differs (see notes)")
		PLAT_WARNINGS+=("pass ${p} differs from the ${REF_NAME} on ${dt} (its values follow the table), so ${REF_EFFECT}")
	elif [[ -n "${PLAT_CHG[$p]:-}" ]]; then
		cells+=("changed (see notes)")
	elif [[ -n "${PLAT_MIX[$p]:-}" ]]; then
		cells+=("mixed (see notes)")
	elif [[ -n "${uk}${PLAT_NC[$p]:-}${NODRIFT[$p]:-}" ]]; then
		cells+=("unknown (see notes)")
	elif [[ -n "$st" ]]; then
		cells+=("same (see notes)")
	else
		cells+=("same")
	fi
	# Not one key of the record proper could be compared: a pass from before the record.
	if [[ -n "$ur" && "$ur" == "$PLAT_KEYS_ALL" ]]; then
		PLAT_WARNINGS+=("pass ${p}: no key of its platform record can be compared with the ${REF_NAME} (its TSVs predate the record, or nothing could be read)$([[ "$urt" == "$ur" ]] || echo ", nor its Kubernetes versions"), so whether it ran on the same platform and builds is not known")
	elif [[ -n "$urt" ]]; then
		PLAT_WARNINGS+=("pass ${p}: ${urt} could not be compared with the ${REF_NAME} (not read, or not recorded, in one of them), so whether it ran on the same platform, builds and Kubernetes versions is not known")
	fi
	[[ -z "$ul" ]] ||
		PLAT_WARNINGS+=("pass ${p}: ${ul} could not be compared with the ${REF_NAME} (not read, or not recorded, in one of them), so whether it ran with the same tuning levers, root Sidecar egress hosts and istiod limits is not known")
done
row "${cells[@]}"
# Each pass's istiod settings (ISTIOD_ENV_BY_CONTEXT, which a profile changes on purpose): one
# digest, so the table shows that a profile reached istiod and a re-run's pass can be matched to
# this one's. A pass whose members ran different settings, or whose TSVs (or the read again at its
# end: tuning 003's platform_drift_check) disagree, warns: the profile may have reached some of them,
# or part of the pass, only; so do one whose settings could not be read on a member (not known,
# never other settings), one whose istiod pods ran different settings at once (a rollout caught
# midway), and a profile pass whose settings contradict its profile against the baseline's
# (env_against_base). And its tuning profile objects (platform_tuning_objects_check):
# a profile pass measures with its own, every one on every member (its marker, which 001 puts there
# before any change, and its resources: the pass's state/objects); another profile's, or any in the
# baseline, are a profile left applied (a run stopped before its revert, or objects applied by
# hand), and one of its own missing is a profile undone during the pass or never applied there, so
# the pass did not measure what its name says.
declare -A ENV_NOTE ENVB_NOTE OBJ_NOTE  # pass -> its notes after the table
BASE_ENV=""
[[ -z "$BASE" || -z "${PLAT[$BASE]:-}" ]] || BASE_ENV="$(plat_value "$BASE" ISTIOD_ENV_BY_CONTEXT)"
# env_against_base <pass>: the members whose istiod settings contradict the pass's profile, as
# "<same|other>\t<their ISTIOD_ENV_BY_CONTEXT pairs>": its state/patch.json (001-apply-profile.sh
# writes it) sets spec.values.pilot.env, yet a value they were read with (or one of its istiod
# pods' digests, "+"-joined) is their baseline's (same: the profile's env was not in effect there),
# or it patches nothing in the Istio CR, yet one is not (other: something else changed them; each
# side compared pod by pod). Nothing when none does, for a profile that patches
# other Istio CR values only (some of them reach istiod's env too), for the baseline, without
# one, or when no member was read on both sides. Return 2 when there is something to compare but
# the patch is not there or does not parse.
env_against_base() {
	local patch="${RESULTS_DIR}/${1}/state/patch.json" sets="" pair c x b d hit=""
	local -a pairs=() parts=()
	local -A base=()
	[[ -n "$BASE_ENV" && "$1" != "$BASE" ]] || return 0
	IFS=',' read -r -a pairs <<<"$BASE_ENV"
	for pair in ${pairs[@]+"${pairs[@]}"}; do
		# Each value's digests one by one ("+"-joined when a member's istiod pods differ: a rollout).
		[[ "$pair" != *=* ]] || { x="${pair#*=}"; x="${x#mixed:}"; base[${pair%%=*}]=";${x//+/;};"; }
	done
	IFS=',' read -r -a pairs <<<"$(plat_value "$1" ISTIOD_ENV_BY_CONTEXT)"
	for pair in ${pairs[@]+"${pairs[@]}"}; do
		[[ "$pair" == *=* ]] || continue
		c="${pair%%=*}" x="${pair#*=}"
		b="${base[$c]:-}"
		[[ -n "$b" && "$b" != ";unknown;" ]] || continue
		IFS=';' read -r -a parts <<<"${x#mixed:}"
		for x in ${parts[@]+"${parts[@]}"}; do
			[[ "$x" != unknown ]] || continue
			if [[ -z "$sets" ]]; then
				# A member has values on both sides: what the profile patches decides.
				[[ -f "$patch" ]] || return 2
				sets="$(jq -r 'if ((.spec.values.pilot.env // {}) | length) > 0 then "env" elif . == {} then "none" else "values" end' "$patch" 2>/dev/null)" || return 2
				case "$sets" in
				env | none) ;;
				values) return 0 ;;
				*) return 2 ;;
				esac
			fi
			# One istiod pod on the baseline's settings is enough for same, one on others for other.
			for d in ${x//+/ }; do
				if [[ "$sets" == env && "$b" == *";${d};"* ]] || [[ "$sets" == none && "$b" != *";${d};"* ]]; then
					hit+="${hit:+,}${pair}"
					break 2
				fi
			done
		done
	done
	[[ -n "$hit" ]] || return 0
	printf '%s\t%s\n' "$([[ "$sets" == env ]] && echo same || echo other)" "$hit"
}
UNREC=()  # passes whose TSVs predate TUNING_OBJECTS_BY_CONTEXT: one warning names them all
cells=("istiod env")
cells_o=("Tuning objects")
for p in "${PASSES[@]}"; do
	if [[ -z "${PLAT[$p]:-}" ]]; then
		cells+=("-")
		cells_o+=("-")
		continue
	fi
	v="$(plat_value "$p" ISTIOD_ENV_BY_CONTEXT)"
	# The members its settings were read on: one recorded unknown (its istiod pods not listed in
	# time) did not run other settings, nor did an input without the key (a token without a
	# member); a member whose istiod pods ran different settings at once reads "+"-joined.
	known="" unread="" bare="" plus=""
	IFS=',' read -r -a pairs <<<"${v:-unknown}"
	for pair in ${pairs[@]+"${pairs[@]}"}; do
		case "$pair" in
		*=unknown) unread+="${unread:+,}${pair}" ;;
		*=*) known+="${known:+,}${pair}" ;;
		*) bare=1 ;;
		esac
		[[ "$pair" != *=*+* ]] || plus+="${plus:+,}${pair}"
	done
	c="$(platform_collapse "${known:-unknown}")"
	if [[ -z "$known" ]]; then
		cell="unknown"
	elif [[ ",${known}" == *"=mixed:"* ]]; then
		cell="mixed (see notes)"
		ENV_NOTE[$p]="$(platform_members_by_value "$v")"
		PLAT_WARNINGS+=("pass ${p}: istiod's settings were not one value all through the pass (ISTIOD_ENV_BY_CONTEXT: $(platform_members_by_value "$known")): its TSVs disagree or one could not read them, or the read at its end found them changed (an Argo CD sync, a hand edit, a profile applied or reverted during it), so part of it may have run other settings")
	elif [[ "$c" == *=* ]]; then
		cell="by member (see notes)"
		ENV_NOTE[$p]="$(platform_members_by_value "$v")"
		PLAT_WARNINGS+=("pass ${p}: istiod's settings differ between its members (ISTIOD_ENV_BY_CONTEXT: $(platform_members_by_value "$known")), so they did not all run the same configuration$([[ "$p" == "$BASE" ]] || echo "; the profile may have reached some of them only")")
	else
		cell="$(platform_short_digests "$c")"
	fi
	# Not read is not other settings: its own warning (a pass whose whole record is unknown has one).
	if [[ -n "${unread}${bare}" ]] && ! plat_all_unknown "$p"; then
		[[ "$cell" == *"(see notes)" ]] || cell+=" (see notes)"
		ENV_NOTE[$p]="$(platform_members_by_value "$v")"
		w=""
		if [[ -n "$unread" ]]; then
			w="$(platform_members_by_value "$unread")"
			w="could not be read on ${w#unknown on }"
		fi
		[[ -z "$bare" ]] || w+="${w:+, and }are not recorded in $([[ -n "${known}${unread}" ]] && echo "one of its TSVs (it predates the key)" || echo "its TSVs (they predate the key)")"
		if [[ -n "$unread" && -n "$known" ]]; then
			w2="those members"
			[[ "$unread" == *,* ]] || w2="that member"
			if [[ "$p" == "$BASE" ]]; then x="whether ${w2} ran the same settings as the others"; else x="whether its profile reached ${w2}"; fi
		elif [[ "$p" == "$BASE" ]]; then
			x="which settings it ran"
		else
			x="whether its profile was in effect"
		fi
		PLAT_WARNINGS+=("pass ${p}: istiod's settings ${w} (ISTIOD_ENV_BY_CONTEXT: ${ENV_NOTE[$p]}), so ${x} is not known")
	fi
	if [[ -n "$plus" ]]; then
		[[ "$cell" == *"(see notes)" ]] || cell+=" (see notes)"
		[[ -n "${ENV_NOTE[$p]:-}" ]] || ENV_NOTE[$p]="$(platform_members_by_value "$v")"
		PLAT_WARNINGS+=("pass ${p}: istiod's pods ran different settings at once (ISTIOD_ENV_BY_CONTEXT: $(platform_members_by_value "$plus"), each pod's digest \"+\"-joined): a rollout caught midway (a short --settle), a pod stuck Terminating or a second istiod Deployment, so part of the pass may have run other settings")
	fi
	rc=0
	eb="$(env_against_base "$p")" || rc=$?
	if ((rc == 2)); then
		ENVB_NOTE[$p]="state/patch.json missing or unreadable: not checked against the baseline"
		PLAT_WARNINGS+=("pass ${p}: its state/patch.json (001-apply-profile.sh writes it in the pass's state dir) is not in the sweep directory or does not parse (jq reads it), so whether its profile's istiod settings were in effect is not checked against the baseline")
	elif [[ -n "$eb" ]]; then
		[[ "$cell" == *"(see notes)" ]] || cell+=" (see notes)"
		w="$(platform_members_by_value "${eb#*$'\t'}")"
		if [[ "${eb%%$'\t'*}" == same ]]; then
			ENVB_NOTE[$p]="the baseline's (${w}), though the profile sets spec.values.pilot.env"
			PLAT_WARNINGS+=("pass ${p}: istiod's settings are the baseline's (ISTIOD_ENV_BY_CONTEXT: ${w}), though its profile sets spec.values.pilot.env, so the profile's env was not in effect there all through the pass (an Argo CD sync or a hand edit put it back, or it never rolled out; or the profile sets the values istiod already had), and its change against the baseline is not the profile's")
		else
			ENVB_NOTE[$p]="not the baseline's (${w}), though the profile does not patch the Istio CR"
			PLAT_WARNINGS+=("pass ${p}: istiod's settings are not the baseline's (ISTIOD_ENV_BY_CONTEXT: ${w}), though its profile does not patch the Istio CR, so something else changed them (an Argo CD sync, a hand edit, another profile), and its change against the baseline is not the profile's alone")
		fi
	fi
	cells+=("$cell")
	prof="$p" exp=""
	[[ "$p" != "$BASE" ]] || prof=""
	# The objects the profile put on every member (its marker, then its resources), when 001 wrote
	# them down; else its marker alone.
	if [[ -n "$prof" && -s "${RESULTS_DIR}/${p}/state/objects" ]]; then
		while IFS= read -r o; do [[ -z "$o" ]] || exp+="${exp:++}${o}"; done <"${RESULTS_DIR}/${p}/state/objects"
	fi
	IFS=$'\t' read -r st who what < <(platform_tuning_objects_check "$(plat_value "$p" TUNING_OBJECTS_BY_CONTEXT)" "$prof" ${exp:+"$exp"})
	case "$st" in
	none | own) cells_o+=("$st") ;;
	other)
		cells_o+=("other (see notes)")
		if [[ "$p" == "$BASE" ]]; then
			OBJ_NOTE[$p]="a profile's objects on ${who}: ${what}"
			PLAT_WARNINGS+=("pass ${p} ran with a tuning profile's objects in place on ${who} (TUNING_OBJECTS_BY_CONTEXT: ${what}), so its figures are not those of the charts' configuration and no profile's change against it is the profile's alone; tests/tuning/005-cleanup.sh undoes them")
		else
			OBJ_NOTE[$p]="another profile's objects on ${who}: ${what}"
			w="$(pass_effect "$p")"
			PLAT_WARNINGS+=("pass ${p} ran with another tuning profile's objects in place on ${who} (TUNING_OBJECTS_BY_CONTEXT: ${what}), so it did not measure ${p} alone and ${w}; tests/tuning/005-cleanup.sh undoes them")
		fi
		;;
	missing)
		cells_o+=("missing (see notes)")
		OBJ_NOTE[$p]="its profile's ${what} not on ${who}"
		PLAT_WARNINGS+=("pass ${p}: its profile's objects (${what}) are not on ${who} in its record (TUNING_OBJECTS_BY_CONTEXT), so the profile was not in place there all through the pass: undone during it (002-revert-profile.sh, 005-cleanup.sh or a hand delete), never applied there, or its TSVs predate the profile markers; its figures are not the profile's")
		;;
	*)
		cells_o+=("unknown (see notes)")
		# A pass whose whole record is unknown has one note and one warning already.
		plat_all_unknown "$p" && continue
		OBJ_NOTE[$p]="${who}"
		if [[ "$who" == "are not recorded (the inputs predate the key)" ]]; then
			UNREC+=("$p")
			continue
		fi
		if [[ "$p" == "$BASE" ]]; then w="whether a profile's objects were in place"; else w="whether its profile's objects, and only those, were in place"; fi
		PLAT_WARNINGS+=("pass ${p}: its tuning profile objects (TUNING_OBJECTS_BY_CONTEXT) ${who}, so ${w} is not known")
		;;
	esac
done
if ((${#UNREC[@]} == 1)); then
	PLAT_WARNINGS+=("pass ${UNREC[0]}: its tuning profile objects (TUNING_OBJECTS_BY_CONTEXT) are not recorded (its TSVs predate the key), so whether it held only the objects its name says (none for the baseline) is not known")
elif ((${#UNREC[@]})); then
	w="${UNREC[*]}"
	PLAT_WARNINGS+=("passes ${w// /, }: their tuning profile objects (TUNING_OBJECTS_BY_CONTEXT) are not recorded (their TSVs predate the key), so whether each held only the objects its name says (none for the baseline) is not known")
fi
row "${cells[@]}"
row "${cells_o[@]}"
for w in ${PLAT_WARNINGS[@]+"${PLAT_WARNINGS[@]}"}; do echo "warning: ${w}" >&2; done
# plat_text <key> <value>: a value as the notes show it, digests shortened (the TSVs keep them in
# full): a lever list and the scalar values as they are (mixed:<a>;<b> as "mixed: <a> and <b>");
# any other value, one that every member shares once, else each value with its members, five
# named (platform_members_by_value).
plat_text() {
	local pair x out=""
	local -a pairs=()
	case "$1" in
	TUNING_BASELINE)
		IFS=',' read -r -a pairs <<<"$2"
		for pair in ${pairs[@]+"${pairs[@]}"}; do
			if [[ "$pair" == *=mixed:* ]]; then x="${pair#*=mixed:}"; pair="${pair%%=*}=mixed: ${x//;/ and }"; fi
			out+="${out:+,}${pair}"
		done
		printf '%s\n' "$out"
		;;
	PLATFORM | TEST_PLATFORM | SIDECAR_EGRESS_HOSTS)
		x="${2#mixed:}"
		if [[ "$2" == mixed:* ]]; then printf 'mixed: %s\n' "${x//,/ and }"; else printf '%s\n' "$2"; fi
		;;
	*)
		x="$(platform_collapse "$2")"
		if [[ "$x" == *=* || "$x" == mixed:* ]]; then platform_members_by_value "$2"; else platform_short_digests "$x"; fi
		;;
	esac
}
# plat_lines <pass> [keys CSV]: "KEY<TAB>value" of a pass's record, levers and limits
# (plat_text): every key (the reference pass's, after the table), or those keys; for another pass
# than the reference, a key that lists each member against REF's, only the members that do not
# match it (platform_value_against), so a record of hundreds of members stays one short line.
plat_lines() {
	local kv k ref
	while IFS= read -r kv; do
		[[ -n "$kv" ]] || continue
		k="${kv%%=*}"
		[[ -z "${2:-}" || ", ${2}, " == *", ${k}, "* ]] || continue
		if [[ -n "${2:-}" && "$1" != "$REF" && ( "$k" == *_BY_CONTEXT || "$k" == KUBE_VERSIONS ) ]]; then
			ref="$(plat_value "$REF" "$k")"
			printf '%s\t%s\n' "$k" "$(platform_short_digests "$(platform_value_against "$k" "${kv#*=}" "${ref:-unknown}")")"
		else
			printf '%s\t%s\n' "$k" "$(plat_text "$k" "${kv#*=}")"
		fi
	done <<<"${PLAT[$1]:-}"
}
# plat_head <pass>: the heading of a pass's note after the table (the keys it differs on, that
# changed during it, that its TSVs disagree on, that cannot be compared, that the read at its end
# could not compare); return 1, with one line instead, when every value of its platform record
# is unknown.
plat_head() {
	if plat_all_unknown "$1" && [[ -z "${PLAT_DIFF[$1]:-}" ]]; then
		echo "Pass ${1}: every value of its platform record is unknown (its TSVs predate the record, or nothing could be read)."
		return 1
	fi
	echo "Pass ${1}$([[ -z "${PLAT_DTXT[$1]:-}" ]] || echo ", differs on ${PLAT_DTXT[$1]}")$([[ -z "${PLAT_CHG[$1]:-}" ]] || echo ", changed during the pass on ${PLAT_CHG[$1]}")$([[ -z "${PLAT_MIX[$1]:-}" ]] || echo ", its TSVs disagree on ${PLAT_MIX[$1]}")$([[ -z "${PLAT_UTXT[$1]:-}" ]] || echo ", cannot be compared on ${PLAT_UTXT[$1]}")$([[ -z "${PLAT_NC[$1]:-}" ]] || echo ", not compared at its end on ${PLAT_NC[$1]}")$([[ -z "${NODRIFT[$1]:-}" ]] || echo ", not read again at its end"):"
}
# pass_notes <pass>: its notes after the table, "KEY<TAB>label<TAB>text<TAB>1 when the text is a
# value (markdown quotes it)": the keys it differs on, its TSVs disagree on and it cannot be
# compared on (plat_lines), what its profile sets that differs, what changed during it, what the
# read at its end could not compare, then its istiod settings and tuning objects.
pass_notes() {
	local keys="${PLAT_DIFF[$1]:-}" k what who
	[[ -z "${PLAT_MIX[$1]:-}" ]] || keys+="${keys:+, }${PLAT_MIX[$1]}"
	[[ -z "${PLAT_UNK[$1]:-}" ]] || keys+="${keys:+, }${PLAT_UNK[$1]}"
	[[ -z "$keys" ]] || plat_lines "$1" "$keys" | awk -F'\t' '{ printf "%s\t\t%s\t1\n", $1, $2 }'
	while IFS=$'\t' read -r k what; do
		[[ -n "$k" ]] || continue
		# Whose profile (profile_sets: "its state/...", or the reference pass's without a baseline).
		case "$what" in
		*"the reference pass's state/"*"its state/"* | *"its state/"*"the reference pass's state/"*) who="its and the reference pass's profiles" ;;
		*"the reference pass's state/"*) who="the reference pass's profile" ;;
		*) who="its profile" ;;
		esac
		printf '%s\tset by %s (%s)\t%s\t1\n' "$k" "$who" "$what" "$(plat_lines "$1" "$k" | cut -f2-)"
	done <<<"${PLAT_SET[$1]:-}"
	while IFS=$'\t' read -r k _ what; do
		[[ -z "$k" ]] || printf '%s\tchanged during the pass\t%s\t1\n' "$k" "$what"
	done <<<"${DRIFT[$1]:-}"
	while IFS=$'\t' read -r k what; do
		[[ -z "$k" ]] || printf '%s\tnot compared at its end\t%s\t\n' "$k" "$what"
	done <<<"${UNREAD[$1]:-}"
	[[ -z "${NODRIFT[$1]:-}" ]] || plat_all_unknown "$1" ||
		printf '%s\t\t%s\t\n' "$PLATFORM_DRIFT_FILE" "none in its directory: its record was not read again at its end"
	[[ -z "${ENV_NOTE[$1]:-}" ]] || printf 'ISTIOD_ENV_BY_CONTEXT\tby member\t%s\t1\n' "${ENV_NOTE[$1]}"
	[[ -z "${ENVB_NOTE[$1]:-}" ]] || printf 'ISTIOD_ENV_BY_CONTEXT\t\t%s\t\n' "${ENVB_NOTE[$1]}"
	[[ -z "${OBJ_NOTE[$1]:-}" ]] || printf 'TUNING_OBJECTS_BY_CONTEXT\t\t%s\t\n' "${OBJ_NOTE[$1]}"
	return 0
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
	local notes
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
				notes="$(pass_notes "$p")"
				[[ -n "$notes" ]] || continue
				echo ""
				if [[ -n "${PLAT_DIFF[$p]:-}${PLAT_UNK[$p]:-}${PLAT_CHG[$p]:-}${PLAT_MIX[$p]:-}${PLAT_NC[$p]:-}${NODRIFT[$p]:-}" ]]; then
					plat_head "$p" || continue
				else
					echo "Pass ${p}:"
				fi
				echo ""
				awk -F'\t' '{ printf "- %s%s: %s\n", $1, ($2 == "" ? "" : ", " $2), ($4 == "1" ? "`" $3 "`" : $3) }' <<<"$notes"
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
				notes="$(pass_notes "$p")"
				[[ -n "$notes" ]] || continue
				if [[ -n "${PLAT_DIFF[$p]:-}${PLAT_UNK[$p]:-}${PLAT_CHG[$p]:-}${PLAT_MIX[$p]:-}${PLAT_NC[$p]:-}${NODRIFT[$p]:-}" ]]; then
					plat_head "$p" || continue
				else
					echo "Pass ${p}:"
				fi
				awk -F'\t' '{ printf "  %-25s %s%s\n", $1, ($2 == "" ? "" : $2 ": "), $3 }' <<<"$notes"
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

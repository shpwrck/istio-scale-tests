#!/usr/bin/env bash
# Per-pod istiod metric fanout helpers. Sourced, never executed.
#
# Consumers: propagation, churn, churn-dataplane
#
# The mesh runs a FIXED, multi-replica istiod (HPA disabled, e.g. replicaCount=5).
# Port-forwarding `svc/istiod` load-balances to ONE random replica per connection,
# so a single scrape sees only ~1/replicas of the connected proxies, pushes, and
# convergence samples — and baseline/final snapshots can land on different pods.
# These helpers port-forward EVERY Running istiod pod per context and aggregate
# the per-pod scrapes with the correct semantics per metric class:
#
#   counters   (pilot_xds_pushes, {type=eds}, pilot_push_triggers, k8s events)
#              -> SUM(after) - SUM(before) across pods  (each event from one replica)
#   pilot_xds  (connected_proxies gauge)
#              -> SUM across replicas (each proxy = exactly one istiod connection)
#   pilot_services (gauge)
#              -> INVARIANT across replicas: max/any, NOT sum (mesh-global registry,
#                 identical on every replica; summing 5x's it). See PL12 note below.
#   histograms (pilot_proxy_convergence_time, *_queue_time, *_push_time)
#              -> SUM each bucket across pods -> THEN delta -> THEN quantile.
#                 Never average per-pod quantiles.
#   process_start_time_seconds
#              -> restart on ANY pod start-time advance OR pod-set change.
#
# PL12 note (TWO summation axes): a gauge with multiple label permutations whose
# TOTAL is meaningful is summed on TWO axes.
#   - axis 1 (labels WITHIN one pod): metrics.sh:extract_gauge_sum accumulates
#     $NF across every name-anchored permutation in one scrape. (Plain
#     extract_gauge returns only the LAST line — use extract_gauge_sum here.)
#   - axis 2 (across pods): the fanout reducers below.
#   pilot_xds sums on BOTH axes (extract_gauge_sum per pod, then sum across pods).
#   pilot_services sums on labels WITHIN a pod (extract_gauge_sum) but is
#     INVARIANT across pods, so the cross-pod reducer is max(), not sum().
#
# Dependency contract:
#   - The PORT/SCRAPE primitives (fanout_ctx_port_base, fanout_list_istiod_pods,
#     fanout_preflight_istiod, fanout_open, fanout_scrape_all, fanout_record_podset)
#     depend ONLY on common.sh (die) + timestamp.sh (now_ns) + curl/awk/kubectl.
#   - The AGGREGATION wrappers (fanout_counter_sum, fanout_counter_by_label_sum,
#     fanout_gauge_sum, fanout_gauge_invariant, fanout_restart_status) call the
#     metrics.sh extractors, so a consumer using them MUST source tests/lib/metrics.sh
#     BEFORE tests/lib/fanout.sh. (Propagation uses only the primitives + its own
#     extract_all_from_file, so it does not need metrics.sh.)
#
# All functions take file paths / ports rather than string variables — istiod
# /metrics output is typically 10-50KB (MB-class at scale) and piping through
# bash variables invites quoting problems. Mirrors tests/lib/metrics.sh.
#
# Requires: curl, awk, kubectl/oc. Callers must have sourced tests/lib/common.sh
# (for die(), split_csv()) and tests/lib/timestamp.sh (for now_ns()); see the
# dependency contract above for which functions also need tests/lib/metrics.sh.
# All callers are expected to have run `set -euo pipefail`.
# shellcheck shell=bash

# Per-context port block allocation. Collision-free across pods x contexts:
#   local_port = FANOUT_PF_BASE + ctx_index * FANOUT_CTX_STRIDE + pod_index
# FANOUT_PF_BASE sits above the existing 15014 (istiod) / 15100 (envoy) blocks.
# FANOUT_CTX_STRIDE leaves headroom above the 5-replica pin for restart churn;
# 10 contexts (indices 0-9) x up to 5 pods -> ports 21014..21198 (ctx 9 base
# 21194 + pod 4). Per-context blocks keep ports stable across a single context's
# own pod restarts (the block is indexed by context, not by the global pod ordinal).
: "${FANOUT_PF_BASE:=21014}"
: "${FANOUT_CTX_STRIDE:=20}"
# Defaults from the shared METRICS_SCRAPE_TIMEOUT base (config/options.env) so all
# /metrics scrape timeouts tune from one place; override FANOUT_METRICS_TIMEOUT to
# tune only the hot-path fanout scrape.
: "${FANOUT_METRICS_TIMEOUT:=${METRICS_SCRAPE_TIMEOUT:-30}}"
# Per-pod /metrics readiness loop length (x 0.5s) when opening a port-forward.
: "${FANOUT_PF_READY_ATTEMPTS:=30}"
# A scrape shorter than this many bytes is treated as failed/incomplete (an istiod
# /metrics payload is many KB; an empty or truncated body indicates a PF death or
# a timed-out scrape, NOT a control plane legitimately reporting 0 for a metric).
: "${FANOUT_MIN_SCRAPE_BYTES:=512}"
# Per-batch scrape-skew ceiling (ms). A fanned-out batch whose skew exceeds this
# is tagged HIGH so the caller can poison the row (same tag-and-filter pattern as
# the .failed / SCRAPE_INCOMPLETE plumbing). The skew is the spread of per-pod
# scrape COMPLETION timestamps (PL8): a wide spread means some bodies were read
# seconds apart from others (e.g. one curl queued behind dozens of port-forward
# proxies near FANOUT_METRICS_TIMEOUT), so the snapshot is not coherent and the
# counter/histogram deltas computed across it are untrustworthy. Default 1000ms:
# above the ~100-350ms normal spread and well below the multi-second outlier seen
# at ~50 concurrent port-forwards, but above the ~2s P1/P2 signal so it does not
# clip legitimate slow convergence.
#
# R2-2 (PROVISIONAL — post-merge live-validation item): the 1000ms ceiling is
# extrapolated from a SINGLE 4043ms outlier, not from a measured .skew distribution
# at the campaign's 10x3 topology (~50 concurrent port-forwards). At that scale the
# typical within-batch completion spread may routinely exceed 1000ms, which would
# mass-drop rows at the most interesting data point. Do NOT finalize this value here:
# validate against real `.skew` sidecars from a 10x3 run after the node-resize, then
# re-derive. Until then the probes emit a loud rows_dropped_skew tally so a silent
# mass-drop is visible. See docs/scale-test-team/process-learnings.md PL8.
: "${FANOUT_MAX_SKEW_MS:=1000}"

# Compute the base local port for a context's per-pod port-forward block.
# Usage: fanout_ctx_port_base <ctx_index>
# shellcheck disable=SC2329
fanout_ctx_port_base() {
	local ctx_index="$1"
	echo $(( FANOUT_PF_BASE + ctx_index * FANOUT_CTX_STRIDE ))
}

# Enumerate Running istiod pods for a context, sorted (deterministic).
# Emits bare pod names, one per line. Empty output => no Running pods.
# Usage: fanout_list_istiod_pods <ctx> <kubectl_argv...>
# shellcheck disable=SC2329
fanout_list_istiod_pods() {
	local ctx="$1"
	shift
	"$@" --context="$ctx" -n istio-system get pods \
		-l app=istiod --field-selector=status.phase=Running \
		-o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
		| LC_ALL=C sort
}

# Preflight: require >= 1 Running istiod pod on a context; record the count.
# Replaces the old check_single_replica_istiod() "die on != 1" — does NOT die
# on > 1. Dies only when there are zero Running pods. Echoes the pod count to
# stdout so callers can record it (e.g. in the TSV preamble) and warn on drift
# from an expected pin.
# Usage: count=$(fanout_preflight_istiod <ctx> <kubectl_argv...>)
# shellcheck disable=SC2329
fanout_preflight_istiod() {
	local ctx="$1"
	shift
	local -a pods=()
	mapfile -t pods < <(fanout_list_istiod_pods "$ctx" "$@")
	local n="${#pods[@]}"
	if (( n < 1 )); then
		die "no Running istiod pod on context $ctx (ns=istio-system, label app=istiod)"
	fi
	echo "$n"
}

# Open one port-forward per Running istiod pod for a context.
# Each pod gets a stable local port from the context's block (see fanout_ctx_port_base).
# Waits for /metrics readiness (FANOUT_PF_READY_ATTEMPTS x 0.5s) per pod.
# Pushes pid/port/pod into the caller's namerefs (mirrors split_csv's nameref idiom).
# The caller keeps its own PF_PIDS array + EXIT trap; pids are appended there too
# via the out_pids nameref so existing cleanup logic kills them.
#
# Tolerate-one: a pod whose /metrics never becomes reachable within the readiness
# window (e.g. a Running-but-not-Ready pod mid-rollout, or a flaky PF) is SKIPPED
# (its PF pid is still tracked for cleanup, but it is not added to the out arrays).
# Dies only when ZERO pods on the context become reachable — then there is nothing
# to aggregate. The port index is keyed by the pod's position in the sorted list,
# so a skipped pod leaves a gap rather than renumbering later pods' ports.
#
# Usage:
#   fanout_open <ctx> <ctx_index> <out_pids_arr> <out_ports_arr> <out_pods_arr> <kubectl_argv...>
# shellcheck disable=SC2329
fanout_open() {
	local ctx="$1" ctx_index="$2"
	local -n _out_pids="$3"
	local -n _out_ports="$4"
	local -n _out_pods="$5"
	shift 5
	local -a kubectl_argv=("$@")

	local -a pods=()
	mapfile -t pods < <(fanout_list_istiod_pods "$ctx" "${kubectl_argv[@]}")
	(( ${#pods[@]} >= 1 )) || die "fanout_open: no Running istiod pods on context $ctx"

	local base port pod i attempts ready ok=0
	base="$(fanout_ctx_port_base "$ctx_index")"
	for i in "${!pods[@]}"; do
		pod="${pods[i]}"
		port=$(( base + i ))
		"${kubectl_argv[@]}" --context="$ctx" -n istio-system \
			port-forward "pod/${pod}" "${port}":15014 >/dev/null 2>&1 &
		_out_pids+=($!)
		attempts=0
		ready=0
		while ! curl -s -o /dev/null --max-time "$FANOUT_METRICS_TIMEOUT" \
			"http://localhost:${port}/metrics" 2>/dev/null; do
			attempts=$((attempts + 1))
			(( attempts > FANOUT_PF_READY_ATTEMPTS )) && break
			sleep 0.5
		done
		if curl -s -o /dev/null --max-time "$FANOUT_METRICS_TIMEOUT" \
			"http://localhost:${port}/metrics" 2>/dev/null; then
			ready=1
		fi
		if (( ready )); then
			_out_ports+=("$port")
			_out_pods+=("$pod")
			ok=$((ok + 1))
		else
			echo "warn: istiod pod $pod on $ctx (port $port) /metrics not reachable; skipping this replica for the scrape" >&2
		fi
	done
	(( ok >= 1 )) || die "fanout_open: no istiod pod on context $ctx served /metrics (all ${#pods[@]} replica PF(s) failed)"
}

# Scrape one pod's /metrics to a file. Returns 0 only if the body is at least
# FANOUT_MIN_SCRAPE_BYTES (an empty/truncated scrape is a failure, NOT a legit 0).
# shellcheck disable=SC2329
_fanout_scrape_one() {
	local port="$1" outfile="$2"
	if ! curl -fsS --max-time "$FANOUT_METRICS_TIMEOUT" \
		"http://localhost:${port}/metrics" -o "$outfile" 2>/dev/null; then
		: > "$outfile"
		return 1
	fi
	local sz
	sz=$(wc -c < "$outfile" 2>/dev/null || echo 0)
	sz="${sz//[^0-9]/}"
	(( ${sz:-0} >= FANOUT_MIN_SCRAPE_BYTES ))
}

# Concurrently scrape /metrics from every pod-port in a context's block.
# Writes <out_dir>/<prefix>-<i>.metrics (the scrape) and <out_dir>/<prefix>-<i>.ts
# (now_ns at scrape completion) for each port index i.
#
# Empty/short-scrape handling: a pod whose body is empty or shorter than
# FANOUT_MIN_SCRAPE_BYTES is retried ONCE in-tick (a transient /metrics timeout
# usually clears on retry). Pods still failing after the retry are counted; the
# count is written to <out_dir>/<prefix>.failed and the function RETURNS NON-ZERO
# so the caller can tag the row (e.g. SCRAPE_INCOMPLETE / PF_DEGRADED) and the
# report can filter it. An empty scrape is thus distinguishable from a pod
# legitimately reporting 0 (which yields a full, multi-KB body).
#
# Echoes the per-batch scrape skew in ms = max(ts)-min(ts) (PL8), spanning pods
# (and, when the caller loops contexts into one out_dir, pods x contexts). The
# skew is ALSO persisted to <out_dir>/<prefix>.skew so a caller that discards the
# stdout (e.g. a poll tick that only cares about the failed count) can still read
# it back via fanout_scrape_skew_high without re-deriving it.
#
# Usage:
#   skew_ms=$(fanout_scrape_all <out_dir> <prefix> <port>...) || handle incompleteness
# shellcheck disable=SC2329
fanout_scrape_all() {
	local out_dir="$1" prefix="$2"
	shift 2
	local -a ports=("$@")
	mkdir -p "$out_dir"
	local -a pids=()
	local i port
	for i in "${!ports[@]}"; do
		port="${ports[i]}"
		(
			_fanout_scrape_one "$port" "${out_dir}/${prefix}-${i}.metrics" || true
			now_ns > "${out_dir}/${prefix}-${i}.ts"
		) &
		pids+=($!)
	done
	local p
	for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done

	# Retry any empty/short scrape ONCE in-tick (transient timeout), then count
	# pods still failing.
	local failed=0 mf
	for i in "${!ports[@]}"; do
		mf="${out_dir}/${prefix}-${i}.metrics"
		if [[ ! -s "$mf" ]] || (( $(wc -c < "$mf" 2>/dev/null || echo 0) < FANOUT_MIN_SCRAPE_BYTES )); then
			if ! _fanout_scrape_one "${ports[i]}" "$mf"; then
				failed=$((failed + 1))
			fi
		fi
	done
	echo "$failed" > "${out_dir}/${prefix}.failed"

	# PL8: scrape_skew_ms = max(ts) - min(ts) across the per-pod timestamps.
	local -a ts_files=()
	for i in "${!ports[@]}"; do
		[[ -e "${out_dir}/${prefix}-${i}.ts" ]] && ts_files+=("${out_dir}/${prefix}-${i}.ts")
	done
	local skew=0
	if (( ${#ts_files[@]} > 0 )); then
		skew=$(awk '
			BEGIN { min = ""; max = "" }
			{ v = $1 + 0; if (min == "" || v < min) min = v; if (max == "" || v > max) max = v }
			END { if (min == "") print 0; else printf "%d\n", (max - min) / 1000000 }
		' "${ts_files[@]}" 2>/dev/null)
	fi
	[[ -z "$skew" ]] && skew=0
	echo "$skew" > "${out_dir}/${prefix}.skew"
	echo "$skew"
	(( failed == 0 ))
}

# Read the failed-pod count recorded by the most recent fanout_scrape_all for a
# given <out_dir>/<prefix>. Echoes 0 if no record exists.
# Usage: fanout_scrape_failed_count <out_dir> <prefix>
# shellcheck disable=SC2329
fanout_scrape_failed_count() {
	local f="${1}/${2}.failed"
	if [[ -s "$f" ]]; then cat "$f"; else echo 0; fi
}

# Read the per-batch scrape skew (ms) recorded by the most recent fanout_scrape_all
# for a given <out_dir>/<prefix>. Echoes 0 if no record exists.
# Usage: fanout_scrape_skew_ms <out_dir> <prefix>
# shellcheck disable=SC2329
fanout_scrape_skew_ms() {
	local f="${1}/${2}.skew"
	if [[ -s "$f" ]]; then cat "$f"; else echo 0; fi
}

# Report whether a raw skew value (ms) exceeds FANOUT_MAX_SKEW_MS. Echoes 1 (high
# — incoherent snapshot, caller should poison the row) or 0, using strict ">" so a
# batch exactly at the ceiling is NOT high. A non-numeric / empty value is treated
# as 0 (not high). This is the single comparison primitive both the sidecar-based
# fanout_scrape_skew_high and callers holding an already-computed skew (e.g. the
# propagation probe's MAX across the source+remote baseline batches) route through,
# so the production gate and the unit-tested gate are the same code path.
# Usage: fanout_skew_high_value <skew_ms>
# shellcheck disable=SC2329
fanout_skew_high_value() {
	local skew="${1:-0}"
	skew="${skew//[^0-9]/}"
	if (( ${skew:-0} > FANOUT_MAX_SKEW_MS )); then echo 1; else echo 0; fi
}

# Report whether the most recent fanout_scrape_all batch for <out_dir>/<prefix>
# exceeded FANOUT_MAX_SKEW_MS. Echoes 1 (high — incoherent snapshot, caller should
# poison the row) or 0. A 0-skew or absent record is treated as 0 (not high), so a
# single-pod context (skew is trivially 0) is never flagged. Mirrors
# fanout_scrape_failed_count's tag-and-filter contract.
# Usage: fanout_scrape_skew_high <out_dir> <prefix>
# shellcheck disable=SC2329
fanout_scrape_skew_high() {
	fanout_skew_high_value "$(fanout_scrape_skew_ms "$1" "$2")"
}

# Record the sorted pod-name set for a context to a file (for restart detection).
# Usage: fanout_record_podset <ctx> <out_file> <kubectl_argv...>
# shellcheck disable=SC2329
fanout_record_podset() {
	local ctx="$1" out_file="$2"
	shift 2
	fanout_list_istiod_pods "$ctx" "$@" > "$out_file"
}

# --- aggregation wrappers over the per-pod scrape files --------------------
# Each takes a list of per-pod metrics files (the .metrics outputs of
# fanout_scrape_all) plus the metric name and reuses the single-file extractors
# from tests/lib/metrics.sh. Skips empty files (a failed scrape).

# SUM a counter across pods (delta is computed by the caller as after-before).
# Usage: fanout_counter_sum <counter_name> <metrics_file>...
# shellcheck disable=SC2329
fanout_counter_sum() {
	local name="$1"
	shift
	local f total=0 v
	for f in "$@"; do
		[[ -s "$f" ]] || continue
		v="$(extract_counter_sum "$f" "$name")"
		total=$(( total + v ))
	done
	echo "$total"
}

# SUM a counter filtered by label across pods.
# Usage: fanout_counter_by_label_sum <counter_name> <label> <value> <metrics_file>...
# shellcheck disable=SC2329
fanout_counter_by_label_sum() {
	local name="$1" label="$2" value="$3"
	shift 3
	local f total=0 v
	for f in "$@"; do
		[[ -s "$f" ]] || continue
		v="$(extract_counter_by_label "$f" "$name" "$label" "$value")"
		total=$(( total + v ))
	done
	echo "$total"
}

# SUM a gauge across pods (pilot_xds: each proxy is one istiod connection).
# PL12: extract_gauge_sum sums the gauge across its label permutations WITHIN a
# pod (axis 1); this loop adds the cross-pod axis (axis 2). A pod that does not
# report the gauge yields "unknown" and is skipped (does not contribute, vs. a
# pod legitimately reporting 0 which contributes 0).
# Usage: fanout_gauge_sum <gauge_name> <metrics_file>...
# shellcheck disable=SC2329
fanout_gauge_sum() {
	local name="$1"
	shift
	local f total=0 v
	for f in "$@"; do
		[[ -s "$f" ]] || continue
		v="$(extract_gauge_sum "$f" "$name")"
		[[ "$v" == "unknown" ]] && continue
		total=$(awk -v a="$total" -v b="$v" 'BEGIN { printf "%.0f", a + b }')
	done
	echo "$total"
}

# Replica-INVARIANT gauge across pods (pilot_services: mesh-global registry,
# identical on every replica). Take each pod's within-pod TOTAL (extract_gauge_sum,
# PL12 axis 1) then reduce with MAX across pods, NOT sum — summing would 5x a
# 5-replica mesh and (in propagation P2) break the "services delta >= 1" check.
# Returns "unknown" only if NO pod reported the gauge.
# Usage: fanout_gauge_invariant <gauge_name> <metrics_file>...
# shellcheck disable=SC2329
fanout_gauge_invariant() {
	local name="$1"
	shift
	local f best="unknown" v
	for f in "$@"; do
		[[ -s "$f" ]] || continue
		v="$(extract_gauge_sum "$f" "$name")"
		[[ "$v" == "unknown" ]] && continue
		if [[ "$best" == "unknown" ]]; then
			best="$v"
		else
			best=$(awk -v a="$best" -v b="$v" 'BEGIN { print (b + 0 > a + 0) ? b : a }')
		fi
	done
	echo "$best"
}

# Merge a histogram across pods by SUMMING each bucket's count (and _sum/_count)
# across the per-pod scrapes, emitting plain Prometheus text to <out_file>. The
# output is consumable by delta_histogram_p99 (tests/lib/metrics.sh) and by the
# propagation probe's extract_all_from_file. Bucket lines are handled as buckets
# (PL11), never summed as counters; the negative-delta guard (PL14) is preserved
# downstream because delta_histogram_p99 still does per-bucket delta on the merge.
# Usage: fanout_merge_histogram <histogram_name> <out_file> <metrics_file>...
# shellcheck disable=SC2329
fanout_merge_histogram() {
	local name="$1" out_file="$2"
	shift 2
	awk -v name="$name" '
		BEGIN {
			bucket_prefix = name "_bucket{"
			sum_scalar    = name "_sum"
			cnt_scalar    = name "_count"
			sum_labeled   = name "_sum{"
			cnt_labeled   = name "_count{"
			n_le = 0
			sum_total = 0; sum_seen = 0
			cnt_total = 0; cnt_seen = 0
		}
		/^#/ { next }
		{
			val = $NF + 0
			if (index($0, bucket_prefix) == 1) {
				le_line = $0
				sub(/.*le="/, "", le_line); sub(/".*/, "", le_line)
				le = le_line
				bucket[le] += val
				if (!(le in seen)) { seen[le] = 1; order[++n_le] = le }
				next
			}
			if (index($0, sum_labeled) == 1) { sum_total += val; sum_seen = 1; next }
			if (index($0, cnt_labeled) == 1) { cnt_total += val; cnt_seen = 1; next }
			if (index($0, sum_scalar) == 1 && substr($0, length(sum_scalar)+1, 1) != "{") {
				sum_total += val; sum_seen = 1; next
			}
			if (index($0, cnt_scalar) == 1 && substr($0, length(cnt_scalar)+1, 1) != "{") {
				cnt_total += val; cnt_seen = 1; next
			}
		}
		END {
			# Emit bucket lines summed across pods. delta_histogram_p99 sorts
			# internally, so input order here does not matter.
			for (i = 1; i <= n_le; i++) {
				le = order[i]
				printf "%s_bucket{le=\"%s\"} %d\n", name, le, bucket[le]
			}
			if (sum_seen) printf "%s_sum %s\n", name, sum_total
			if (cnt_seen) printf "%s_count %d\n", name, cnt_total
		}
	' "$@" > "$out_file"
}

# Restart detection across the fanned-out pod set: 0 | 1 | unknown (PL9, widened).
# Compares the sorted pod-name set (pod-set change -> 1) AND per-pod
# process_start_time_seconds (any pod's start advanced -> 1). Missing either side
# -> unknown (don't claim "no restart" when you could not measure).
#
# Inputs are the .podset files (sorted pod names) and the per-pod .metrics files
# for pre and post windows. Per-pod start times are keyed by pod NAME (read from
# the podset order) so a reordering between scrapes does not masquerade as a
# restart and a pod-set change is detected directly.
#
# Usage:
#   fanout_restart_status <pre_podset> <post_podset> \
#       <pre_metrics_csv> <post_metrics_csv>
# where the *_metrics_csv args are comma-joined lists of per-pod .metrics files
# in the SAME order as the corresponding podset file lines.
# shellcheck disable=SC2329
fanout_restart_status() {
	local pre_podset="$1" post_podset="$2" pre_csv="$3" post_csv="$4"

	# Pod-set change -> restart (a pod was replaced / rescheduled).
	if [[ ! -s "$pre_podset" || ! -s "$post_podset" ]]; then
		echo "unknown"; return 0
	fi
	if ! diff -q "$pre_podset" "$post_podset" >/dev/null 2>&1; then
		echo "1"; return 0
	fi

	local -a pre_files=() post_files=() pre_pods=() post_pods=()
	IFS=',' read -ra pre_files <<<"$pre_csv"
	IFS=',' read -ra post_files <<<"$post_csv"
	mapfile -t pre_pods < "$pre_podset"
	mapfile -t post_pods < "$post_podset"

	# Per-pod start-time map by pod name.
	local i pod pre_start post_start
	for i in "${!pre_pods[@]}"; do
		pod="${pre_pods[i]}"
		local pf="${pre_files[i]:-}" qf=""
		# Find the post file at the same name index (sets are identical here).
		local j
		for j in "${!post_pods[@]}"; do
			if [[ "${post_pods[j]}" == "$pod" ]]; then qf="${post_files[j]:-}"; break; fi
		done
		[[ -n "$pf" && -s "$pf" && -n "$qf" && -s "$qf" ]] || { echo "unknown"; return 0; }
		pre_start="$(extract_gauge "$pf" process_start_time_seconds)"
		post_start="$(extract_gauge "$qf" process_start_time_seconds)"
		if [[ "$pre_start" == "unknown" || "$post_start" == "unknown" ]]; then
			echo "unknown"; return 0
		fi
		if awk -v a="$pre_start" -v b="$post_start" 'BEGIN { exit !(a + 0 == 0 || b + 0 == 0) }'; then
			echo "unknown"; return 0
		fi
		if awk -v a="$pre_start" -v b="$post_start" 'BEGIN { exit !(b + 0 > a + 0) }'; then
			echo "1"; return 0
		fi
	done
	echo "0"
}

#!/usr/bin/env bash
# Per-pod istiod metric fanout helpers. Sourced, never executed.
#
# Consumers: propagation, churn, churn-dataplane, controlplane (fanout_list_istiod_pods,
# fanout_gauge_sum_strict for the per-cluster connected-proxy total, fanout_counter_in_batch
# and fanout_replica_counter for the per-replica push counters)
#
# The mesh runs a FIXED, multi-replica istiod (HPA disabled, e.g. replicaCount=5).
# Port-forwarding `svc/istiod` load-balances to ONE random replica per connection,
# so a single scrape sees only ~1/replicas of the connected proxies, pushes, and
# convergence samples — and baseline/final snapshots can land on different pods.
# These helpers port-forward EVERY Running istiod pod per context and aggregate
# the per-pod scrapes with the correct semantics per metric class:
#
#   counters   (pilot_xds_pushes, {type=eds}, pilot_push_triggers, k8s events)
#              -> SUM(after) - SUM(before) across pods  (each event from one replica),
#                 via counter_delta; `unknown` (never 0) when no scrape has the counter,
#                 `unscraped` when any pod's scrape is incomplete (PL29)
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
#     fanout_counter_in_batch, fanout_replica_counter, fanout_gauge_sum,
#     fanout_gauge_sum_strict, fanout_restart_status) call the
#     metrics.sh extractors, so a consumer using them MUST source tests/lib/metrics.sh
#     BEFORE tests/lib/fanout.sh. (Propagation uses only the primitives + its own
#     extract_all_from_file, so it does not need metrics.sh.)
#
# All functions take file paths / ports rather than string variables — istiod
# /metrics output is typically 10-50KB (MB-class at scale) and piping through
# bash variables invites quoting problems. Mirrors tests/lib/metrics.sh.
#
# Requires: curl, awk, kubectl/oc. Callers must have sourced tests/lib/common.sh
# (for die(), split_csv(), file_min_bytes()) and tests/lib/timestamp.sh (for now_ns()); see the
# dependency contract above for which functions also need tests/lib/metrics.sh.
# All callers are expected to have run `set -euo pipefail`.
# shellcheck shell=bash

# Per-context port block allocation. Collision-free across pods x contexts:
#   local_port = FANOUT_PF_BASE + ctx_index * FANOUT_CTX_STRIDE + pod_index
# FANOUT_PF_BASE sits above the existing 15014 (istiod) / 15100 (envoy) blocks.
# FANOUT_CTX_STRIDE (20) leaves headroom above the 5-replica pin for restart churn.
# Dimensioned for the 20-cluster/10k campaign: 20 contexts (indices 0-19) x up to
# 5 pods -> ports 21014..21398 (ctx 19 base 21394 + pod 4), all in the unprivileged
# ephemeral range and clear of the 15014/15100 blocks. (At the old 10-context scale
# it was 21014..21198.) Per-context blocks keep ports stable across a single
# context's own pod restarts (the block is indexed by context, not the global pod
# ordinal). To go beyond 20 contexts, raise FANOUT_PF_BASE/STRIDE so ctx_index *
# STRIDE + 4 stays below the ephemeral ceiling.
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
# R2-2 (PROVISIONAL — pre-GO live-validation item, env-overridable knob): the
# 1000ms ceiling is extrapolated from a SINGLE 4043ms outlier, NOT from a measured
# .skew distribution at a high-context topology. For the 20-cluster/10k campaign a
# scrape batch fans out across ~100 concurrent port-forwards (20 contexts x up to 5
# istiod replicas), where the typical within-batch completion spread may routinely
# exceed 1000ms and would mass-drop rows at the most interesting data point. This
# value MUST be re-derived from real `.skew` sidecars off a high-context (~100-PF)
# run BEFORE the 20c/10k GO — do NOT invent a replacement here. Until then the
# probes emit a loud rows_dropped_skew tally so a silent mass-drop is visible, and
# the ceiling stays overridable via FANOUT_MAX_SKEW_MS. See PL8 in
# docs/scale-test-team/process-learnings.md.
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

	# _fo_ prefix: a local named like the caller's out-array (e.g. "pods") would
	# shadow it, and the nameref would write into the local instead.
	local -a _fo_pods=()
	mapfile -t _fo_pods < <(fanout_list_istiod_pods "$ctx" "${kubectl_argv[@]}")
	(( ${#_fo_pods[@]} >= 1 )) || die "fanout_open: no Running istiod pods on context $ctx"

	# Open every pod's port-forward FIRST, then probe all of them concurrently.
	# A serial open-then-block-on-readiness made the whole open O(sum of per-pod
	# readiness waits); at 20 contexts x up to 5 replicas (~100 port-forwards) the
	# per-replica wait (up to FANOUT_PF_READY_ATTEMPTS x 0.5s) compounded into
	# minutes per context. Backgrounding the readiness polls makes it O(slowest pod).
	local base port pod i ok=0
	base="$(fanout_ctx_port_base "$ctx_index")"
	local -a _fo_ports=() probe_pids=() ready_dir
	ready_dir="$(mktemp -d "${TMPDIR:-/tmp}/fanout-ready.XXXXXX")"
	for i in "${!_fo_pods[@]}"; do
		pod="${_fo_pods[i]}"
		port=$(( base + i ))
		_fo_ports[i]="$port"
		"${kubectl_argv[@]}" --context="$ctx" -n istio-system \
			port-forward "pod/${pod}" "${port}":15014 >/dev/null 2>&1 &
		_out_pids+=($!)
		# Background a bounded readiness poll per pod; touch a marker on success.
		(
			a=0
			while ! curl -s -o /dev/null --max-time "$FANOUT_METRICS_TIMEOUT" \
				"http://localhost:${port}/metrics" 2>/dev/null; do
				a=$((a + 1))
				(( a > FANOUT_PF_READY_ATTEMPTS )) && exit 0
				sleep 0.5
			done
			: > "${ready_dir}/${i}.ready"
		) &
		probe_pids+=($!)
	done
	# Join ONLY the readiness probes (the port-forwards run indefinitely, so a bare
	# `wait` would block forever). O(slowest pod) instead of O(sum of waits).
	for i in "${probe_pids[@]}"; do wait "$i" 2>/dev/null || true; done
	# Collect ready pods in sorted-index order so port = base+i stays stable and a
	# skipped pod leaves a gap rather than renumbering later pods' ports.
	for i in "${!_fo_pods[@]}"; do
		pod="${_fo_pods[i]}"
		port="${_fo_ports[i]}"
		if [[ -f "${ready_dir}/${i}.ready" ]]; then
			_out_ports+=("$port")
			_out_pods+=("$pod")
			ok=$((ok + 1))
		else
			echo "warn: istiod pod $pod on $ctx (port $port) /metrics not reachable; skipping this replica for the scrape" >&2
		fi
	done
	rm -rf "$ready_dir"
	(( ok >= 1 )) || die "fanout_open: no istiod pod on context $ctx served /metrics (all ${#_fo_pods[@]} replica PF(s) failed)"
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
	fanout_body_complete "$outfile"
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
# it back without re-deriving it.
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
		if ! fanout_body_complete "$mf"; then
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

# Report whether a raw skew value (ms) exceeds FANOUT_MAX_SKEW_MS. Echoes 1 (high
# — incoherent snapshot, caller should poison the row) or 0, using strict ">" so a
# batch exactly at the ceiling is NOT high. A non-numeric / empty value is treated
# as 0 (not high). Callers pass the skew echoed by fanout_scrape_all (or, in the
# propagation probe, the MAX across the source+remote baseline batches).
# Usage: fanout_skew_high_value <skew_ms>
# shellcheck disable=SC2329
fanout_skew_high_value() {
	local skew="${1:-0}"
	skew="${skew//[^0-9]/}"
	if (( ${skew:-0} > FANOUT_MAX_SKEW_MS )); then echo 1; else echo 0; fi
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
# from tests/lib/metrics.sh.

# fanout_body_complete <metrics_file>: true when the file is a complete scrape, i.e.
# readable and at least FANOUT_MIN_SCRAPE_BYTES (fanout_scrape_all's rule; a failed
# scrape leaves an empty or short file, PL29). It runs for every replica's file on every
# scrape and extraction, so it forks nothing for a complete body (B6): file_min_bytes
# (common.sh, I8) reads the first FANOUT_MIN_SCRAPE_BYTES characters with the read
# builtin, and counts bytes with wc only for a shorter one.
# shellcheck disable=SC2329
fanout_body_complete() {
	[[ -s "$1" && -r "$1" ]] || return 1
	file_min_bytes "$1" "$FANOUT_MIN_SCRAPE_BYTES"
}

# SUM a counter across pods; the caller takes the window delta with counter_delta
# (metrics.sh). A pod whose scrape lacks the counter adds 0 (istiod registers it at
# its first increment); `unknown` when no scrape has it at all (R10: renamed), so a
# missing metric never reads as 0. `unscraped` when no file is given or any pod's
# scrape is incomplete (fanout_body_complete): skipping it would undercount the sum,
# and a short baseline would turn its share of the counter into window pushes (PL29).
# Usage: fanout_counter_sum <counter_name> <metrics_file>...
# shellcheck disable=SC2329
fanout_counter_sum() {
	local name="$1"
	shift
	(( $# )) || { echo unscraped; return 0; }
	local f total=0 v seen=0
	for f in "$@"; do
		fanout_body_complete "$f" || { echo unscraped; return 0; }
		v="$(extract_counter_sum "$f" "$name")"
		[[ "$v" == unscraped ]] && { echo unscraped; return 0; }
		[[ "$v" =~ ^[0-9]+$ ]] || continue
		seen=1
		total=$(( total + v ))
	done
	if ((seen)); then echo "$total"; else echo unknown; fi
}

# SUM a counter filtered by label across pods; `unknown` and `unscraped` as
# fanout_counter_sum.
# Usage: fanout_counter_by_label_sum <counter_name> <label> <value> <metrics_file>...
# shellcheck disable=SC2329
fanout_counter_by_label_sum() {
	local name="$1" label="$2" value="$3"
	shift 3
	(( $# )) || { echo unscraped; return 0; }
	local f total=0 v seen=0
	for f in "$@"; do
		fanout_body_complete "$f" || { echo unscraped; return 0; }
		v="$(extract_counter_by_label "$f" "$name" "$label" "$value")"
		[[ "$v" == unscraped ]] && { echo unscraped; return 0; }
		[[ "$v" =~ ^[0-9]+$ ]] || continue
		seen=1
		total=$(( total + v ))
	done
	if ((seen)); then echo "$total"; else echo unknown; fi
}

# Per-replica counters (one istiod replica's own delta, not the cross-pod sum).
# istiod creates a counter series at its first increment and writes no `# TYPE` line
# before that, so a replica that never served a proxy has no pilot_xds_pushes at all.
# Whether a counter missing from one replica is renamed or just idle is decided once
# per scrape batch: fanout_counter_in_batch over every baseline and final body of the
# batch, then fanout_replica_counter for each replica's file with that answer.

# fanout_counter_in_batch <counter_name> <metrics_file>...: 1 when any complete body
# among the files has the counter (a sample or a `# TYPE` line), else 0.
# shellcheck disable=SC2329
fanout_counter_in_batch() {
	local name="$1" f
	shift
	for f in "$@"; do
		fanout_body_complete "$f" || continue
		[[ "$(extract_counter_sum "$f" "$name")" =~ ^[0-9]+$ ]] && { echo 1; return 0; }
	done
	echo 0
}

# fanout_replica_counter <in_batch> <metrics_file> <counter_name> [<label> <value>]:
# one replica's counter (summed over its series, or only those with <label>=<value>):
# a number; `unscraped` when the body is incomplete; and for a complete body without
# the counter, 0 when <in_batch> is 1 (another replica has it: this one is idle),
# `unknown` when it is 0 (no replica has it: renamed, counter_delta warns).
# shellcheck disable=SC2329
fanout_replica_counter() {
	local in_batch="$1" f="$2" name="$3" v
	fanout_body_complete "$f" || { echo unscraped; return 0; }
	if (( $# >= 5 )); then
		v="$(extract_counter_by_label "$f" "$name" "$4" "$5")"
	else
		v="$(extract_counter_sum "$f" "$name")"
	fi
	[[ "$v" == unknown && "$in_batch" == 1 ]] && v=0
	echo "$v"
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

# STRICT cross-pod gauge sum (PL29): echoes `unknown` unless EVERY pod scrape is
# complete. fanout_gauge_sum above skips an empty file, so one failed pod scrape
# silently drops that pod's share of the total; that is wrong for a total that must
# be complete, e.g. a cluster's connected proxies compared against its sidecar pods.
# Echoes `unknown` when no file is given, or any file is missing, empty, or shorter
# than FANOUT_MIN_SCRAPE_BYTES. In a complete body an absent series counts as 0: a
# replica with no connected proxies emits no pilot_xds series at all. With one file
# it is the per-pod value under the same completeness rule. Always returns 0.
# Usage: fanout_gauge_sum_strict <gauge_name> <metrics_file>...
# shellcheck disable=SC2329
fanout_gauge_sum_strict() {
	local name="$1"
	shift
	if (( $# == 0 )); then echo "unknown"; return 0; fi
	local f total=0 v
	for f in "$@"; do
		fanout_body_complete "$f" || { echo "unknown"; return 0; }
		v="$(extract_gauge_sum "$f" "$name")"
		[[ "$v" == "unknown" ]] && v=0
		total=$(awk -v a="$total" -v b="$v" 'BEGIN { printf "%.0f", a + b }')
	done
	echo "$total"
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

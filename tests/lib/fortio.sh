#!/usr/bin/env bash
# Parse `fortio load -json` output and classify a load run. Sourced, never executed.
#
# Consumers: dataplane (002); churn-dataplane (002, 003: fortio_row_status with the
# shortfall check off, for ERROR_RATE_HIGH); tests/lib/reach.sh (fortio_ret_codes).
# churn-dataplane still has its own percentile/QPS parsing and no shortfall check;
# moving those here is a follow-up (PL41).
#
# Exposes (every function takes the fortio JSON as a string; jq and awk only):
#   fortio_percentile_ms <json> <pct>  -> latency at percentile <pct> in ms
#                                         (50 matches 50.0; "N/A" when absent)
#   fortio_max_ms <json>               -> DurationHistogram.Max in ms ("N/A" when absent
#                                         or the JSON is invalid, never a 0 latency)
#   fortio_actual_qps <json>           -> ActualQPS ("N/A" when absent or invalid)
#   fortio_pct_200 <json>              -> HTTP 200s / all responses, "N/A" with no responses
#   fortio_n_responses <json>          -> sum of RetCodes, 0 when there are none
#   fortio_ret_codes <json>            -> "code=count,..." sorted numerically (-1 first),
#                                         "N/A" when there are none
#   fortio_row_status <json> <qps_target> <min_qps_ratio> <min_pct_200>
#       -> the first that applies, in this order:
#          PERCENTILE_MISSING  any of p50/p90/p99/p99.9 is missing
#          ERROR_RATE_HIGH     pct_200 < min_pct_200, or zero responses
#          QPS_SHORTFALL       ActualQPS < min_qps_ratio * qps_target, or ActualQPS
#                              missing (delivery cannot be shown)
#          OK
#       min_qps_ratio 0 disables the shortfall check (for callers that run at a
#       fixed low QPS); a non-numeric or zero qps_target also skips it.
#   fortio_client_pod <ctx> <ns> <app> <kubectl_argv...>
#       -> the name of a Running client pod (label app=<app>) that is not being deleted;
#          returns 1, printing nothing, when there is none
#   fortio_client_stop <ctx> <ns> <pod> <kubectl_argv...>
#       -> for a probe's EXIT trap during an in-pod `fortio load`: delete the client pod,
#          so the load stops (a note on stderr; never dies)
#   fortio_load_wait_out <start_ns> <duration_s>
#       -> after a load whose `kubectl exec` failed: sleep until the load it started may
#          have ended (start + duration + 5 s), so the next load does not run beside it
#          (a note on stderr; never dies)
#
# Requires: jq, awk (fortio_client_pod, fortio_client_stop: kubectl or oc;
# fortio_load_wait_out: now_ns, tests/lib/timestamp.sh).
# shellcheck shell=bash

# shellcheck disable=SC2329
fortio_percentile_ms() {
	local json="$1" pct="$2"
	printf '%s' "$json" | jq -r --argjson p "$pct" '
		.DurationHistogram.Percentiles
		| (map(select((.Percentile - $p) | fabs < 0.01)) | .[0])
		| if . == null then "N/A" else (.Value * 1000 | tostring) end
	' 2>/dev/null || echo "N/A"
}

# A missing value is "N/A", never 0: a 0 ms max or 0 QPS would read as a measurement.
# shellcheck disable=SC2329
fortio_max_ms() {
	local out
	out="$(printf '%s' "$1" | jq -r '.DurationHistogram.Max // null | if . == null then "N/A" else . * 1000 end' 2>/dev/null)" || out=""
	printf '%s\n' "${out:-N/A}"
}

# shellcheck disable=SC2329
fortio_actual_qps() {
	local out
	out="$(printf '%s' "$1" | jq -r '.ActualQPS // null | if . == null then "N/A" else . end' 2>/dev/null)" || out=""
	printf '%s\n' "${out:-N/A}"
}

# RetCodes is an object like {"200": 1234, "503": 5, "-1": 2} (-1 = socket error).
# shellcheck disable=SC2329
fortio_pct_200() {
	printf '%s' "$1" | jq -r '
		(.RetCodes // {})
		| (to_entries | map(.value) | add) as $total
		| (.["200"] // 0) as $ok
		| if ($total // 0) == 0 then "N/A"
		  else ($ok / $total * 1.0 | tostring) end
	' 2>/dev/null || echo "N/A"
}

# shellcheck disable=SC2329
fortio_n_responses() {
	printf '%s' "$1" | jq -r '(.RetCodes // {}) | (to_entries | map(.value) | add) // 0' 2>/dev/null || echo 0
}

# shellcheck disable=SC2329
fortio_ret_codes() {
	local out
	out="$(printf '%s' "$1" | jq -r '
		(.RetCodes // {}) | to_entries
		| sort_by(.key | tonumber? // 1e9)
		| map("\(.key)=\(.value)") | join(",")
	' 2>/dev/null)" || out=""
	[[ -n "$out" ]] || out="N/A"
	printf '%s\n' "$out"
}

# shellcheck disable=SC2329
fortio_row_status() {
	local json="$1" qps_target="$2" min_ratio="$3" min_pct="$4"
	local p pct n actual
	for p in 50 90 99 99.9; do
		if [[ "$(fortio_percentile_ms "$json" "$p")" == "N/A" ]]; then
			echo PERCENTILE_MISSING
			return 0
		fi
	done
	pct="$(fortio_pct_200 "$json")"
	n="$(fortio_n_responses "$json")"
	if [[ "$n" == "0" ]] \
		|| { [[ "$pct" != "N/A" ]] && awk -v v="$pct" -v m="$min_pct" 'BEGIN { exit !(v + 0 < m + 0) }'; }; then
		echo ERROR_RATE_HIGH
		return 0
	fi
	actual="$(fortio_actual_qps "$json")"
	if awk -v a="$actual" -v t="$qps_target" -v r="$min_ratio" '
		BEGIN { exit !(t ~ /^[0-9]+(\.[0-9]+)?$/ && t + 0 > 0 && r + 0 > 0 && a + 0 < (r + 0) * (t + 0)) }'; then
		echo QPS_SHORTFALL
		return 0
	fi
	echo OK
}

# fortio_client_stop <ctx> <ns> <pod> <kubectl_argv...>: for a probe's EXIT trap when it
# ends (a stop, Ctrl-C, an error) while a `fortio load` runs in the client pod. That load
# runs inside the pod, not in the `kubectl exec` that started it: ending kubectl leaves it
# loading the servers for the rest of its -t, into the next run's first window. The client
# image has no shell or kill, so delete the pod: its container, and the load, end at once,
# and its Deployment starts a new pod, which a setup's Available wait (001, which a sweep
# runs first) waits for. Bounded: --wait=false, and 5 s per request (a delete with a cold
# discovery cache makes up to three: 15 s, inside SWEEP_STOP_GRACE_SEC's 30); a warning
# when the delete fails. Never dies.
fortio_client_stop() {
	local ctx="$1" ns="$2" pod="$3"
	shift 3
	[[ -n "$pod" ]] || return 0
	echo "note: ${ctx}: deleting the fortio client pod ${pod}, which still runs a load (its Deployment starts a new one)" >&2 || true
	if ! "$@" --context="$ctx" --request-timeout=5s -n "$ns" delete pod "$pod" --wait=false >/dev/null 2>&1; then
		echo "warning: ${ctx}: could not delete the fortio client pod ${pod}: its load runs on for up to its -t seconds; wait that long before the next run" >&2 || true
	fi
	return 0
}

# fortio_client_pod <ctx> <ns> <app> <kubectl_argv...>: the client pod a probe execs its loads
# in: a Running pod labelled app=<app> without a deletionTimestamp, the first listed. After a
# probe's stop deleted the pod (fortio_client_stop), the old one is Terminating while its
# Deployment's new one starts: a load exec'd into the old one would fail. Prints nothing and
# returns 1 when there is none (or the list fails).
# shellcheck disable=SC2329
fortio_client_pod() {
	local ctx="$1" ns="$2" app="$3" fcp_out
	shift 3
	fcp_out="$("$@" --context="$ctx" -n "$ns" get pod -l "app=${app}" --field-selector=status.phase=Running \
		-o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null)" || return 1
	fcp_out="$(awk -F'\t' '$1 != "" && $2 == "" { print $1; exit }' <<<"$fcp_out")"
	[[ -n "$fcp_out" ]] || return 1
	printf '%s\n' "$fcp_out"
}

# fortio_load_wait_out <start_ns> <duration_s>: for a probe whose `kubectl exec ... fortio
# load -t <duration_s>s` failed; <start_ns> is now_ns just before that exec. The load runs
# in the client pod, not in the exec (fortio_client_stop): an exec stream that broke
# part-way (an API server or kubelet hiccup) leaves it loading the servers for the rest of
# its -t, so the probe's next load would run beside it. Sleep until <start_ns> +
# <duration_s> + 5 s (the exec's start-up and fortio's last requests), with a note; not at
# all once that has passed. The caller keeps its EXIT trap's pod (LOAD_POD) set meanwhile,
# so a stop during the wait still deletes the pod. Never dies.
fortio_load_wait_out() {
	local start_ns="$1" dur="$2" now left
	if ! [[ "$start_ns" =~ ^[0-9]+$ && "$dur" =~ ^[0-9]+$ ]]; then
		echo "warning: fortio_load_wait_out: bad start (${start_ns}) or duration (${dur}): not waiting for the failed load to end" >&2 || true
		return 0
	fi
	now="$(now_ns)" || now=""
	[[ "$now" =~ ^[0-9]+$ ]] || now="$start_ns"
	left=$(((start_ns + (dur + 5) * 1000000000 - now + 999999999) / 1000000000))
	((left > 0)) || return 0
	echo "note: the load's kubectl exec failed, but its fortio load may still run in the client pod: waiting ${left}s (its -t ${dur}s and 5 s, from its start) before going on, so the next load does not run beside it" >&2 || true
	sleep "$left" || true
	return 0
}

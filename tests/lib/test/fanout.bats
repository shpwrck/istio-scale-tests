#!/usr/bin/env bats

load test_helper
source "${ROOT}/tests/lib/timestamp.sh"
source "${ROOT}/tests/lib/metrics.sh"
source "${ROOT}/tests/lib/fanout.sh"

FIXTURES="${ROOT}/tests/lib/test/fixtures"
POD0="${FIXTURES}/istiod_pod0.txt"
POD1="${FIXTURES}/istiod_pod1.txt"
ZERO="${FIXTURES}/istiod_zero_baseline.txt"

# --- counter aggregation ---------------------------------------------------

@test "fanout_counter_sum: sums a counter across pods" {
	# pilot_xds_pushes pod0 = 100+200+100=400, pod1 = 50+120+50=220 -> 620
	result=$(fanout_counter_sum pilot_xds_pushes "$POD0" "$POD1")
	[ "$result" = "620" ]
}

@test "fanout_counter_sum: skips an empty (failed-scrape) pod file" {
	empty=$(mktemp); : > "$empty"
	result=$(fanout_counter_sum pilot_xds_pushes "$POD0" "$empty")
	rm -f "$empty"
	[ "$result" = "400" ]
}

@test "fanout_counter_by_label_sum: sums eds across pods" {
	# eds: pod0=200, pod1=120 -> 320
	result=$(fanout_counter_by_label_sum pilot_xds_pushes type eds "$POD0" "$POD1")
	[ "$result" = "320" ]
}

# --- gauge SUM vs INVARIANT (the load-bearing distinction) ------------------

@test "fanout_gauge_sum: pilot_xds connected-proxies SUM across replicas (5+7=12)" {
	result=$(fanout_gauge_sum pilot_xds "$POD0" "$POD1")
	[ "$result" = "12" ]
}

@test "fanout_gauge_invariant: pilot_services returns the value, NOT 2x" {
	# Both pods report 42; INVARIANT must return 42, never the sum 84.
	result=$(fanout_gauge_invariant pilot_services "$POD0" "$POD1")
	[ "$result" = "42" ]
}

@test "fanout_gauge_invariant: returns MAX on a lagging replica (40 vs 42 -> 42)" {
	result=$(fanout_gauge_invariant pilot_services "${FIXTURES}/istiod_pod1_lagging.txt" "$POD0")
	[ "$result" = "42" ]
}

@test "fanout_gauge_invariant: unknown when no pod reports the gauge" {
	result=$(fanout_gauge_invariant pilot_services "$ZERO")
	[ "$result" = "unknown" ]
}

# --- histogram bucket-sum -> delta_histogram_p99 ---------------------------

@test "fanout_merge_histogram + delta_histogram_p99: merged buckets land p99 on the expected bucket" {
	# Merged convergence buckets (pod0+pod1) against a zero baseline:
	#   le=0.5:40  le=1:90  le=3:120  +Inf:120 ; count=120
	# target = 120 * 0.99 = 118.8 -> first cumulative bucket >= target is le=3
	#   -> 3 * 1000 = 3000.00
	merged=$(mktemp)
	fanout_merge_histogram pilot_proxy_convergence_time "$merged" "$POD0" "$POD1"
	result=$(delta_histogram_p99 "$ZERO" "$merged" pilot_proxy_convergence_time)
	rm -f "$merged"
	[ "$result" = "3000.00" ]
}

@test "fanout_merge_histogram: merged _count equals the sum of per-pod counts" {
	merged=$(mktemp)
	fanout_merge_histogram pilot_proxy_convergence_time "$merged" "$POD0" "$POD1"
	# pod0 count 50 + pod1 count 70 = 120
	cnt=$(awk '/_count /{print $2}' "$merged")
	rm -f "$merged"
	[ "$cnt" = "120" ]
}

@test "fanout_merge_histogram: a single pod merges to itself (identity for one replica)" {
	merged=$(mktemp)
	fanout_merge_histogram pilot_proxy_convergence_time "$merged" "$POD0"
	result=$(delta_histogram_p99 "$ZERO" "$merged" pilot_proxy_convergence_time)
	rm -f "$merged"
	# pod0 alone: count 50, target 49.5; cumulative le=0.5:30 le=1:50>=49.5 -> 1*1000
	[ "$result" = "1000.00" ]
}

# --- restart detection (pod-set change + per-pod start-time advance) --------

_mk_podset() { # <file> <podname>...
	local f="$1"; shift
	printf '%s\n' "$@" > "$f"
}

@test "fanout_restart_status: identical pod set + start times -> 0" {
	pre=$(mktemp); post=$(mktemp)
	_mk_podset "$pre" istiod-aaa istiod-bbb
	_mk_podset "$post" istiod-aaa istiod-bbb
	result=$(fanout_restart_status "$pre" "$post" "$POD0,$POD1" "$POD0,$POD1")
	rm -f "$pre" "$post"
	[ "$result" = "0" ]
}

@test "fanout_restart_status: pod-set change -> 1" {
	pre=$(mktemp); post=$(mktemp)
	_mk_podset "$pre" istiod-aaa istiod-bbb
	_mk_podset "$post" istiod-aaa istiod-ccc
	result=$(fanout_restart_status "$pre" "$post" "$POD0,$POD1" "$POD0,$POD1")
	rm -f "$pre" "$post"
	[ "$result" = "1" ]
}

@test "fanout_restart_status: per-pod start-time advance -> 1" {
	pre=$(mktemp); post=$(mktemp)
	_mk_podset "$pre" istiod-aaa istiod-bbb
	_mk_podset "$post" istiod-aaa istiod-bbb
	# Same pod set, but istiod-bbb's process_start_time advanced (restarted file).
	result=$(fanout_restart_status "$pre" "$post" \
		"$POD0,$POD1" "$POD0,${FIXTURES}/istiod_pod1_restarted.txt")
	rm -f "$pre" "$post"
	[ "$result" = "1" ]
}

@test "fanout_restart_status: missing start time on a pod -> unknown" {
	pre=$(mktemp); post=$(mktemp); nostart=$(mktemp)
	printf 'pilot_xds{type="grpc"} 7\npilot_services 42\n' > "$nostart"
	_mk_podset "$pre" istiod-aaa istiod-bbb
	_mk_podset "$post" istiod-aaa istiod-bbb
	result=$(fanout_restart_status "$pre" "$post" "$POD0,$POD1" "$POD0,$nostart")
	rm -f "$pre" "$post" "$nostart"
	[ "$result" = "unknown" ]
}

@test "fanout_restart_status: missing podset file -> unknown" {
	pre=$(mktemp); post=$(mktemp)
	: > "$pre"  # empty
	_mk_podset "$post" istiod-aaa
	result=$(fanout_restart_status "$pre" "$post" "$POD0" "$POD0")
	rm -f "$pre" "$post"
	[ "$result" = "unknown" ]
}

# --- port allocation (collision-free for 5 pods x 10 contexts) -------------

@test "fanout port allocation: 5 pods x 10 contexts produce no overlapping ports" {
	# local_port = FANOUT_PF_BASE + ctx*FANOUT_CTX_STRIDE + pod
	declare -A seen=()
	collisions=0
	for ((ctx = 0; ctx < 10; ctx++)); do
		base=$(fanout_ctx_port_base "$ctx")
		for ((pod = 0; pod < 5; pod++)); do
			port=$(( base + pod ))
			if [[ -n "${seen[$port]:-}" ]]; then collisions=$((collisions + 1)); fi
			seen[$port]=1
		done
	done
	[ "$collisions" -eq 0 ]
	# 50 distinct ports, all >= 21014 (above the 15014/15100 blocks).
	[ "${#seen[@]}" -eq 50 ]
	[ "$(fanout_ctx_port_base 0)" -eq 21014 ]
	[ "$(fanout_ctx_port_base 9)" -eq 21194 ]
}

@test "fanout_ctx_port_base: stride leaves headroom for 5-replica pin + restart" {
	# Adjacent context blocks must not overlap even at the 5-replica ceiling.
	b0=$(fanout_ctx_port_base 0)
	b1=$(fanout_ctx_port_base 1)
	[ $(( b1 - b0 )) -ge 5 ]
}

#!/usr/bin/env bats

load test_helper
source "${ROOT}/tests/lib/metrics.sh"

FIXTURES="${ROOT}/tests/lib/test/fixtures"

# --- extract_counter_sum ---

@test "extract_counter_sum: sums all instances of a counter" {
	result=$(extract_counter_sum "$FIXTURES/prometheus_counters.txt" "pilot_xds_pushes")
	[[ "$result" == "770" ]]
}

@test "extract_counter_sum: missing counter returns 0" {
	result=$(extract_counter_sum "$FIXTURES/prometheus_counters.txt" "nonexistent_counter")
	[[ "$result" == "0" ]]
}

@test "extract_counter_sum: ignores comment lines" {
	result=$(extract_counter_sum "$FIXTURES/prometheus_counters.txt" "HELP")
	[[ "$result" == "0" ]]
}

@test "extract_counter_sum: handles counters with and without labels" {
	result=$(extract_counter_sum "$FIXTURES/prometheus_counters.txt" "pilot_push_triggers")
	[[ "$result" == "100" ]]
}

# --- extract_counter_by_label ---

@test "extract_counter_by_label: filters by label value" {
	result=$(extract_counter_by_label "$FIXTURES/prometheus_counters.txt" "pilot_xds_pushes" "type" "cds")
	[[ "$result" == "150" ]]
}

@test "extract_counter_by_label: eds label" {
	result=$(extract_counter_by_label "$FIXTURES/prometheus_counters.txt" "pilot_xds_pushes" "type" "eds")
	[[ "$result" == "320" ]]
}

@test "extract_counter_by_label: no matching label returns 0" {
	result=$(extract_counter_by_label "$FIXTURES/prometheus_counters.txt" "pilot_xds_pushes" "type" "nds")
	[[ "$result" == "0" ]]
}

# --- extract_gauge ---

@test "extract_gauge: extracts gauge value" {
	result=$(extract_gauge "$FIXTURES/prometheus_gauges.txt" "process_start_time_seconds")
	[[ "$result" == "1716940800" ]]
}

@test "extract_gauge: missing gauge returns unknown" {
	result=$(extract_gauge "$FIXTURES/prometheus_gauges.txt" "nonexistent_gauge")
	[[ "$result" == "unknown" ]]
}

# --- delta_histogram_p99 ---

@test "delta_histogram_p99: normal case with known distribution" {
	result=$(delta_histogram_p99 "$FIXTURES/histogram_pre.txt" "$FIXTURES/histogram_post.txt" "pilot_proxy_queue_time")
	# 200 new observations (cumulative delta): 10 <=0.01, 100 <=0.1, 200 <=0.5 (flat above)
	# p99 of 200 = 198th observation, 98% of the way into the [0.1,0.5] bucket.
	# Prometheus linear interpolation: 0.1 + (0.5-0.1)*(198-100)/(200-100) = 0.492s -> 492.00ms
	# (was 500.00 when this emitted the bucket ceiling; FINDING #5 interpolation fix)
	[[ "$result" == "492.00" ]]
}

@test "delta_histogram_p99: missing histogram returns N/A" {
	result=$(delta_histogram_p99 "$FIXTURES/histogram_pre.txt" "$FIXTURES/histogram_post.txt" "nonexistent_histogram")
	[[ "$result" == "N/A" ]]
}

@test "delta_histogram_p99: negative delta (counter reset) returns N/A" {
	# Create a post file with lower values than pre (simulating counter reset)
	local tmppost
	tmppost=$(mktemp)
	cat > "$tmppost" <<'EOF'
pilot_proxy_queue_time_bucket{le="0.01"} 5
pilot_proxy_queue_time_bucket{le="0.1"} 10
pilot_proxy_queue_time_bucket{le="0.5"} 15
pilot_proxy_queue_time_bucket{le="1"} 18
pilot_proxy_queue_time_bucket{le="5"} 19
pilot_proxy_queue_time_bucket{le="+Inf"} 20
EOF
	result=$(delta_histogram_p99 "$FIXTURES/histogram_pre.txt" "$tmppost" "pilot_proxy_queue_time")
	rm -f "$tmppost"
	[[ "$result" == "N/A" ]]
}

@test "delta_histogram_p99: all traffic in one bucket" {
	local tmppre tmppost
	tmppre=$(mktemp)
	tmppost=$(mktemp)
	cat > "$tmppre" <<'EOF'
pilot_proxy_queue_time_bucket{le="0.1"} 0
pilot_proxy_queue_time_bucket{le="0.5"} 0
pilot_proxy_queue_time_bucket{le="+Inf"} 0
EOF
	cat > "$tmppost" <<'EOF'
pilot_proxy_queue_time_bucket{le="0.1"} 100
pilot_proxy_queue_time_bucket{le="0.5"} 100
pilot_proxy_queue_time_bucket{le="+Inf"} 100
EOF
	result=$(delta_histogram_p99 "$tmppre" "$tmppost" "pilot_proxy_queue_time")
	rm -f "$tmppre" "$tmppost"
	# All 100 obs in the [0,0.1] bucket; interpolated p99 = 0.1*0.99 = 0.099s -> 99.00ms
	# (was 100.00 when this emitted the bucket ceiling; FINDING #5 interpolation fix)
	[[ "$result" == "99.00" ]]
}

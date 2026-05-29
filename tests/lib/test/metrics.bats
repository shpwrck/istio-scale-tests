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
	# 200 new observations: 10 in <=0.01, 90 in <=0.1, 100 in <=0.5, 10 in <=1, 5 in <=5
	# p99 of 200 = 198th observation, which falls in the 0.5 bucket
	# Output is bucket boundary * 1000 = 500.00
	[[ "$result" == "500.00" ]]
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
	[[ "$result" == "100.00" ]]
}

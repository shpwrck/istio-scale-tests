#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr
source "${ROOT}/tests/lib/metrics.sh"

FIXTURES="${ROOT}/tests/lib/test/fixtures"

# --- extract_counter_sum ---

@test "extract_counter_sum: sums all instances of a counter" {
	result=$(extract_counter_sum "$FIXTURES/prometheus_counters.txt" "pilot_xds_pushes")
	[[ "$result" == "770" ]]
}

@test "extract_counter_sum: missing counter returns unknown, not 0" {
	result=$(extract_counter_sum "$FIXTURES/prometheus_counters.txt" "nonexistent_counter")
	[[ "$result" == "unknown" ]]
}

@test "extract_counter_sum: ignores comment lines" {
	result=$(extract_counter_sum "$FIXTURES/prometheus_counters.txt" "HELP")
	[[ "$result" == "unknown" ]]
}

@test "extract_counter_sum: a declared counter with no sample yet is a real 0" {
	f=$(mktemp)
	printf '# HELP pilot_k8s_cfg_events Events\n# TYPE pilot_k8s_cfg_events counter\nother_metric 5\n' > "$f"
	result=$(extract_counter_sum "$f" pilot_k8s_cfg_events)
	rm -f "$f"
	[[ "$result" == "0" ]]
}

@test "extract_counter_sum: empty or missing scrape file is unscraped, never 0 or unknown (PL29)" {
	f=$(mktemp)
	result=$(extract_counter_sum "$f" pilot_xds_pushes)
	rm -f "$f"
	[[ "$result" == "unscraped" ]]
	result=$(extract_counter_sum "${BATS_TEST_TMPDIR}/no-such-file" pilot_xds_pushes)
	[[ "$result" == "unscraped" ]]
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
	# pilot_xds_pushes is in the scrape; istiod registers type=nds at its first push.
	result=$(extract_counter_by_label "$FIXTURES/prometheus_counters.txt" "pilot_xds_pushes" "type" "nds")
	[[ "$result" == "0" ]]
}

@test "extract_counter_by_label: counter absent from the scrape returns unknown" {
	result=$(extract_counter_by_label "$FIXTURES/prometheus_counters.txt" "pilot_xds_pushes_renamed" "type" "eds")
	[[ "$result" == "unknown" ]]
	f=$(mktemp)
	result=$(extract_counter_by_label "$f" "pilot_xds_pushes" "type" "eds")
	rm -f "$f"
	[[ "$result" == "unscraped" ]]
}

# --- counter_delta ---

@test "counter_delta: after - before when both are numbers" {
	run counter_delta 100 250 x
	assert_success
	assert_output "150"
}

@test "counter_delta: absent at the baseline, present at the end = lazily registered, from 0" {
	run counter_delta unknown 7 x
	assert_success
	assert_output "7"
}

@test "counter_delta: absent in both scrapes is N/A with a warning, not 0" {
	run --separate-stderr counter_delta unknown unknown pilot_xds_pushes
	assert_success
	assert_output "N/A"
	[[ "$stderr" == *"pilot_xds_pushes"*"neither scrape"* ]]
}

@test "counter_delta: a negative delta (reset) is N/A with a warning, never clamped to 0" {
	run --separate-stderr counter_delta 500 20 pilot_xds_pushes
	assert_success
	assert_output "N/A"
	[[ "$stderr" == *"went from 500 to 20"* ]]
}

@test "counter_delta: present at the baseline, gone at the end is N/A" {
	run --separate-stderr counter_delta 500 unknown x
	assert_success
	assert_output "N/A"
	[[ "$stderr" == *"missing from the final scrape"* ]]
}

@test "counter_delta: a failed (unscraped) baseline or final is N/A, never a lifetime total (PL29)" {
	empty="${BATS_TEST_TMPDIR}/empty.metrics"; : > "$empty"
	run --separate-stderr counter_delta "$(extract_counter_sum "$empty" pilot_xds_pushes)" \
		"$(extract_counter_sum "$FIXTURES/prometheus_counters.txt" pilot_xds_pushes)" pilot_xds_pushes
	assert_success
	assert_output "N/A"
	[[ "$stderr" == *"pilot_xds_pushes: the baseline scrape is empty, short or unreadable"* ]]
	run --separate-stderr counter_delta 500 unscraped x
	assert_output "N/A"
	[[ "$stderr" == *"the final scrape is empty"* ]]
	run --separate-stderr counter_delta unscraped unscraped x
	assert_output "N/A"
	[[ "$stderr" == *"the baseline and final scrape is empty"* ]]
}

@test "counter_delta: N/A is safe under set -e and never reaches \$(( ))" {
	run bash -c 'set -euo pipefail; source "$1/tests/lib/common.sh"; source "$1/tests/lib/metrics.sh"; d=$(counter_delta unknown unknown x 2>/dev/null); echo "d=$d"' _ "$ROOT"
	assert_success
	assert_output "d=N/A"
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

# --- config_dump_breakdown (VirtualService/DestinationRule load axis) ---

@test "config_dump_breakdown: counts dynamic clusters and sizes the CDS and RDS sections" {
	result=$(config_dump_breakdown "$FIXTURES/config_dump_small.json")
	# 3 dynamic clusters (the plain one plus subsets v1/v2); the static one is not counted.
	[[ "$result" =~ ^clusters=3\ cds_bytes=([0-9]+)\ rds_bytes=([0-9]+)$ ]]
	# Byte counts equal the compact JSON of each section.
	cds=$(jq -c '.configs[] | select(."@type" | endswith(".ClustersConfigDump"))' "$FIXTURES/config_dump_small.json" | tr -d '\n' | wc -c | tr -d ' ')
	rds=$(jq -c '.configs[] | select(."@type" | endswith(".RoutesConfigDump"))' "$FIXTURES/config_dump_small.json" | tr -d '\n' | wc -c | tr -d ' ')
	[[ "${BASH_REMATCH[1]}" == "$cds" ]]
	[[ "${BASH_REMATCH[2]}" == "$rds" ]]
}

@test "config_dump_breakdown: non-JSON (a truncated dump) is unknown, not zero" {
	f="${BATS_TEST_TMPDIR}/bad.json"
	head -c 120 "$FIXTURES/config_dump_small.json" > "$f"
	[[ "$(config_dump_breakdown "$f")" == "unknown" ]]
}

@test "config_dump_breakdown: empty or missing file is unknown" {
	: > "${BATS_TEST_TMPDIR}/empty.json"
	[[ "$(config_dump_breakdown "${BATS_TEST_TMPDIR}/empty.json")" == "unknown" ]]
	[[ "$(config_dump_breakdown "${BATS_TEST_TMPDIR}/missing.json")" == "unknown" ]]
}

@test "config_dump_breakdown: a dump without ClustersConfigDump is unknown" {
	f="${BATS_TEST_TMPDIR}/noclusters.json"
	jq -c '.configs |= map(select(."@type" | endswith(".ClustersConfigDump") | not))' "$FIXTURES/config_dump_small.json" > "$f"
	[[ "$(config_dump_breakdown "$f")" == "unknown" ]]
}

@test "config_dump_breakdown: a dump without RoutesConfigDump keeps clusters, rds unknown" {
	f="${BATS_TEST_TMPDIR}/noroutes.json"
	jq -c '.configs |= map(select(."@type" | endswith(".RoutesConfigDump") | not))' "$FIXTURES/config_dump_small.json" > "$f"
	[[ "$(config_dump_breakdown "$f")" =~ ^clusters=3\ cds_bytes=[0-9]+\ rds_bytes=unknown$ ]]
}

#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr
source "${ROOT}/tests/lib/metrics.sh"

FIXTURES="${ROOT}/tests/lib/test/fixtures"

@test "extract_counter_sum, extract_counter_by_label, extract_gauge: every instance summed, with or without labels (comment lines never count); a declared counter with no sample, or a label value not seen yet, is a real 0; a counter or gauge not in the scrape is unknown; an empty or missing scrape is unscraped, never 0 or unknown (PL29)" {
	local p="$FIXTURES/prometheus_counters.txt" f="${BATS_TEST_TMPDIR}/declared"
	[ "$(extract_counter_sum "$p" pilot_xds_pushes)" = 770 ]
	[ "$(extract_counter_sum "$p" pilot_push_triggers)" = 100 ]
	[ "$(extract_counter_sum "$p" nonexistent_counter)" = unknown ]
	[ "$(extract_counter_sum "$p" HELP)" = unknown ]
	printf '# HELP pilot_k8s_cfg_events Events\n# TYPE pilot_k8s_cfg_events counter\nother_metric 5\n' > "$f"
	[ "$(extract_counter_sum "$f" pilot_k8s_cfg_events)" = 0 ]
	: > "${BATS_TEST_TMPDIR}/empty"
	[ "$(extract_counter_sum "${BATS_TEST_TMPDIR}/empty" pilot_xds_pushes)" = unscraped ]
	[ "$(extract_counter_sum "${BATS_TEST_TMPDIR}/no-such-file" pilot_xds_pushes)" = unscraped ]
	[ "$(extract_counter_by_label "$p" pilot_xds_pushes type cds)" = 150 ]
	[ "$(extract_counter_by_label "$p" pilot_xds_pushes type eds)" = 320 ]
	# pilot_xds_pushes is in the scrape; istiod registers type=nds at its first push.
	[ "$(extract_counter_by_label "$p" pilot_xds_pushes type nds)" = 0 ]
	[ "$(extract_counter_by_label "$p" pilot_xds_pushes_renamed type eds)" = unknown ]
	[ "$(extract_counter_by_label "${BATS_TEST_TMPDIR}/empty" pilot_xds_pushes type eds)" = unscraped ]
	[ "$(extract_gauge "$FIXTURES/prometheus_gauges.txt" process_start_time_seconds)" = 1716940800 ]
	[ "$(extract_gauge "$FIXTURES/prometheus_gauges.txt" nonexistent_gauge)" = unknown ]
}

@test "counter_delta: after - before; absent at the baseline and present at the end counts from 0 (lazily registered); absent in both, a reset (never clamped to 0), gone at the end or a failed scrape (never a lifetime total) is N/A with a warning, safe under set -e" {
	run counter_delta 100 250 x
	assert_success
	assert_output "150"
	run counter_delta unknown 7 x
	assert_output "7"
	run --separate-stderr counter_delta unknown unknown pilot_xds_pushes
	assert_success
	assert_output "N/A"
	[[ "$stderr" == *"pilot_xds_pushes"*"neither scrape"* ]]
	run --separate-stderr counter_delta 500 20 pilot_xds_pushes
	assert_output "N/A"
	[[ "$stderr" == *"went from 500 to 20"* ]]
	run --separate-stderr counter_delta 500 unknown x
	assert_output "N/A"
	[[ "$stderr" == *"missing from the final scrape"* ]]
	empty="${BATS_TEST_TMPDIR}/empty.metrics"; : > "$empty"
	run --separate-stderr counter_delta "$(extract_counter_sum "$empty" pilot_xds_pushes)" \
		"$(extract_counter_sum "$FIXTURES/prometheus_counters.txt" pilot_xds_pushes)" pilot_xds_pushes
	assert_output "N/A"
	[[ "$stderr" == *"pilot_xds_pushes: the baseline scrape is empty, short or unreadable"* ]]
	run --separate-stderr counter_delta 500 unscraped x
	assert_output "N/A"
	[[ "$stderr" == *"the final scrape is empty"* ]]
	run --separate-stderr counter_delta unscraped unscraped x
	assert_output "N/A"
	[[ "$stderr" == *"the baseline and final scrape is empty"* ]]
	run bash -c 'set -euo pipefail; source "$1/tests/lib/common.sh"; source "$1/tests/lib/metrics.sh"; d=$(counter_delta unknown unknown x 2>/dev/null); echo "d=$d"' _ "$ROOT"
	assert_success
	assert_output "d=N/A"
}

@test "delta_histogram_p99: the window's p99, interpolated in its bucket (all traffic in one bucket too); a histogram not in the scrape or a reset is N/A" {
	# 200 new observations (cumulative delta): 10 <=0.01, 100 <=0.1, 200 <=0.5 (flat above).
	# p99 of 200 = 198th observation: 0.1 + (0.5-0.1)*(198-100)/(200-100) = 0.492s -> 492.00ms
	[ "$(delta_histogram_p99 "$FIXTURES/histogram_pre.txt" "$FIXTURES/histogram_post.txt" pilot_proxy_queue_time)" = 492.00 ]
	[ "$(delta_histogram_p99 "$FIXTURES/histogram_pre.txt" "$FIXTURES/histogram_post.txt" nonexistent_histogram)" = N/A ]
	local pre="${BATS_TEST_TMPDIR}/pre" post="${BATS_TEST_TMPDIR}/post"
	# A post scrape with lower values than the pre one (a counter reset).
	cat > "$post" <<'EOF'
pilot_proxy_queue_time_bucket{le="0.01"} 5
pilot_proxy_queue_time_bucket{le="0.1"} 10
pilot_proxy_queue_time_bucket{le="0.5"} 15
pilot_proxy_queue_time_bucket{le="1"} 18
pilot_proxy_queue_time_bucket{le="5"} 19
pilot_proxy_queue_time_bucket{le="+Inf"} 20
EOF
	[ "$(delta_histogram_p99 "$FIXTURES/histogram_pre.txt" "$post" pilot_proxy_queue_time)" = N/A ]
	cat > "$pre" <<'EOF'
pilot_proxy_queue_time_bucket{le="0.1"} 0
pilot_proxy_queue_time_bucket{le="0.5"} 0
pilot_proxy_queue_time_bucket{le="+Inf"} 0
EOF
	cat > "$post" <<'EOF'
pilot_proxy_queue_time_bucket{le="0.1"} 100
pilot_proxy_queue_time_bucket{le="0.5"} 100
pilot_proxy_queue_time_bucket{le="+Inf"} 100
EOF
	# All 100 observations in the [0,0.1] bucket: 0.1*0.99 = 0.099s -> 99.00ms
	[ "$(delta_histogram_p99 "$pre" "$post" pilot_proxy_queue_time)" = 99.00 ]
}

@test "config_dump_breakdown: the dynamic clusters and the CDS and RDS sections' compact JSON bytes; a truncated, empty or missing dump, or one without ClustersConfigDump, is unknown, never 0; without RoutesConfigDump rds is unknown" {
	local d="$FIXTURES/config_dump_small.json" f
	run config_dump_breakdown "$d"
	# 3 dynamic clusters (the plain one plus subsets v1/v2); the static one is not counted.
	[[ "$output" =~ ^clusters=3\ cds_bytes=([0-9]+)\ rds_bytes=([0-9]+)$ ]]
	cds=$(jq -c '.configs[] | select(."@type" | endswith(".ClustersConfigDump"))' "$d" | tr -d '\n' | wc -c | tr -d ' ')
	rds=$(jq -c '.configs[] | select(."@type" | endswith(".RoutesConfigDump"))' "$d" | tr -d '\n' | wc -c | tr -d ' ')
	[[ "${BASH_REMATCH[1]}" == "$cds" ]]
	[[ "${BASH_REMATCH[2]}" == "$rds" ]]
	f="${BATS_TEST_TMPDIR}/bad.json"
	head -c 120 "$d" > "$f"
	[ "$(config_dump_breakdown "$f")" = unknown ]
	: > "${BATS_TEST_TMPDIR}/empty.json"
	[ "$(config_dump_breakdown "${BATS_TEST_TMPDIR}/empty.json")" = unknown ]
	[ "$(config_dump_breakdown "${BATS_TEST_TMPDIR}/missing.json")" = unknown ]
	f="${BATS_TEST_TMPDIR}/noclusters.json"
	jq -c '.configs |= map(select(."@type" | endswith(".ClustersConfigDump") | not))' "$d" > "$f"
	[ "$(config_dump_breakdown "$f")" = unknown ]
	f="${BATS_TEST_TMPDIR}/noroutes.json"
	jq -c '.configs |= map(select(."@type" | endswith(".RoutesConfigDump") | not))' "$d" > "$f"
	[[ "$(config_dump_breakdown "$f")" =~ ^clusters=3\ cds_bytes=[0-9]+\ rds_bytes=unknown$ ]]
}

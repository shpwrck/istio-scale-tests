#!/usr/bin/env bats
# propagation 005 through its real entrypoint: averages are rounded (not truncated),
# the convergence histogram rows never bucket an average (max is the worst bucket),
# csv/json carry worst_bucket, and json mesh_size is a number.

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr

REPORT="${ROOT}/tests/propagation/005-report-results.sh"
HDR=$'run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms'

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
}

# prow <mesh> <iter> <p1_ms> <p1_conv_p99_ms>: an OK row; p2 500 ms, p3 3000 ms.
prow() {
	printf 'r1\t%s\t%s\tsrc\trmt\t0\t%s\t500\t3000\tOK\t100\t%s\t40/40\t40\t0\t0\t0\t5000\t10\n' "$@"
}

# Mesh sizes 2 and 3, three rows each: p1 1000/1001/1001 (mean 1000.67), conv p99
# 100/100/1000 (mean 400, in the 100-500 bucket no row hit).
fixture() {
	{
		echo "# RUN_ID=r1"
		[[ -n "${NO_PLATFORM:-}" ]] || platform_fixture_lines src,rmt
		echo "$HDR"
		for m in 2 3; do
			prow "$m" 1 1000 100
			prow "$m" 2 1001 100
			prow "$m" 3 1001 1000
		done
	} > "${RES}/endpoint-r1.tsv"
}

@test "005: averages are rounded to the nearest ms, not truncated" {
	fixture
	run "$REPORT" --results-dir "$RES" --format csv
	assert_success
	assert_line "2,P1_local_wall,3,3,1000,1001,1001,1001,N/A,N/A,"
	run "$REPORT" --results-dir "$RES" --format markdown
	assert_output --partial "| P1 local xDS (wall) | 3 | 3 | 1000 | 1001 | 1001 |"
	assert_output --partial "| 2 | 1001 (3) |"
	run "$REPORT" --results-dir "$RES"
	assert_output --regexp 'P1 local xDS \(wall\) +\| +3 \| +3 \| +1000 \| +1001 \| +1001 \|'
	run "$REPORT" --results-dir "$RES" --format json
	[ "$(jq '.rows[0] | .avg_ms == 1001 and .phase == "P1_local_wall"' <<<"$output")" = true ]
}

@test "005: histogram rows show the worst bucket and no averaged bucket" {
	fixture
	run "$REPORT" --results-dir "$RES" --format markdown
	assert_success
	assert_output --partial "| P1 conv_p99 (hist) | 3 | 3 | 0-100 | 500-1000 | - | 0-100 | N/A | N/A |"
	assert_output --partial "| Mesh Size | P1 wall avg (ms) | P1 conv_p99 worst (ms) |"
	assert_output --partial "| 2 | 1001 (3) | 500-1000 (3) |"
	refute_output --partial "| 100-500"
	run "$REPORT" --results-dir "$RES"
	assert_output --regexp 'P1 conv_p99 \(hist\) +\| +3 \| +3 \| +0-100 \| +500-1000 \| +- \|'
	refute_output --partial "100-500"
}

@test "005: csv and json keep the numbers and add worst_bucket; json mesh_size is a number" {
	fixture
	run "$REPORT" --results-dir "$RES" --format csv
	assert_success
	assert_line "mesh_size,phase,n_total,n_valid,min_ms,max_ms,avg_ms,p50_ms,p95_ms,p99_ms,worst_bucket"
	assert_line "2,P1_conv_p99,3,3,100,1000,400,100,N/A,N/A,500-1000"
	run "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -c '[.rows[] | select(.mesh_size == 2) | {(.phase): .worst_bucket}] | add' <<<"$output")" = \
		'{"P1_local_wall":null,"P1_conv_p50":"0-100","P1_conv_p99":"500-1000","P2_discovery":null,"P3_dataplane":null}' ]
	[ "$(jq -r '[.rows[].mesh_size | type] | unique | join(",")' <<<"$output")" = number ]
}

@test "005: a phase with no valid sample is null in json, with the same keys" {
	{
		platform_fixture_lines src,rmt
		echo "$HDR"
		printf 'r1\t2\t1\tsrc\trmt\t0\tTIMEOUT\tN/A\tN/A\tTIMEOUT_ALL\tN/A\tN/A\t0/40\t40\t0\t0\t0\t5000\t10\n'
	} > "${RES}/endpoint-r1.tsv"
	run "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -c '.rows[0] | [.mesh_size, .n_total, .n_valid, .avg_ms, .worst_bucket]' <<<"$output")" = '[2,1,0,null,null]' ]
}

@test "005: the platform record reaches every format; an input from before it reads unknown, with a warning (PL19)" {
	fixture
	run --separate-stderr "$REPORT" --results-dir "$RES"
	assert_success
	assert_line "  PLATFORM: kubernetes"
	assert_line "  NODE_PROVIDER_BY_CONTEXT: src=kind,rmt=kind"
	[[ "$stderr" != *"no PLATFORM line"* ]]
	run --separate-stderr "$REPORT" --results-dir "$RES" --format markdown
	assert_line 'MESH_OPERATOR_BY_CONTEXT: "src=sail-operator:1.31.1/Available,rmt=sail-operator:1.31.1/Available"'
	run --separate-stderr "$REPORT" --results-dir "$RES" --format csv
	assert_line "# ISTIOD_IMAGE_BY_CONTEXT=src=pilot:1.30.5,rmt=pilot:1.30.5"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	[ "$(jq -r '.metadata | "\(.PLATFORM) \(.TEST_PLATFORM) \(.PROXY_IMAGE_BY_CONTEXT)"' <<<"$output")" = "kubernetes auto src=proxyv2:1.30.5,rmt=proxyv2:1.30.5" ]
	rm "${RES}"/*.tsv
	NO_PLATFORM=1 fixture
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -r '.metadata | "\(.PLATFORM) \(.MESH_OPERATOR_BY_CONTEXT)"' <<<"$output")" = "unknown unknown" ]
	[[ "$stderr" == *"1 of 1 input TSV(s) have no PLATFORM line"* ]]
}

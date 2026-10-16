#!/usr/bin/env bats
# churn-dataplane 005 through its real entrypoint: each average has its own count (an
# N/A p50 or QPS is not a 0), JSON numbers are numbers (null for N/A), and the
# convergence p99 is the worst bucket (bare range labels, "(ms)" in the header) with
# an overflow count instead of the bucket of a mean.

load test_helper

REPORT="${ROOT}/tests/churn-dataplane/005-report-results.sh"
HDR=$'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms'

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
}

# crow <combo> <churn_rate> <phase> <qps_actual> <p50> <p99> <status> <eds> <conv_p99>
# A mesh_size=2 row; p90/p999/max and the other counters are fixed.
crow() {
	printf 'r1\tsha\t%s\t2\t%s\t%s\t60\t50\t%s\t%s\t3\t%s\t6\t7\tN/A\t0\t%s\t10\t10\t100\t%s\t5\t%s\tN/A\tN/A\n' "$@"
}

# write_tsv <file>; rows come on stdin.
write_tsv() {
	{
		echo "# RUN_ID=r1"
		echo "$HDR"
		cat
	} > "$1"
}

# Two valid pairs at churn rate 1: c2's baseline p50 and QPS and its churn p50 are N/A.
two_pairs() {
	write_tsv "${RES}/churn-dataplane-r1.tsv" <<-EOF
	$(crow c1 0 baseline 50 2 5 OK N/A N/A)
	$(crow c1 1 churn 48 4 9 OK 30 99)
	$(crow c2 0 baseline N/A N/A 5 OK N/A N/A)
	$(crow c2 1 churn 46 N/A 11 OK 50 600)
	EOF
}

@test "005: an N/A p50 or QPS is left out of its own average, not averaged as 0" {
	two_pairs
	run "$REPORT" --results-dir "$RES" --format csv
	assert_success
	# delta 5.00 | stdev | total | valid | bl p99 | ch p99 | bl p50 2 (not 1) | ch p50 4 (not 2)
	# | bl qps 50 (not 25) | ch qps 47 | eds | worst conv | overflow runs
	assert_line "2,1,5.00,1.41,2,2,5.00,10.00,2.00,4.00,50.0,47.0,40,500-1000,0"
	run "$REPORT" --results-dir "$RES" --format md
	assert_output --partial "| 2 | 1 | 5.00 | 1.41 | 2 | 2 | 5.00 | 10.00 | 2.00 | 4.00 | 50.0 | 47.0 | 40 | 500-1000 |"
}

@test "005: p50 and QPS are N/A when no valid pair has one" {
	write_tsv "${RES}/churn-dataplane-r1.tsv" <<-EOF
	$(crow c1 0 baseline N/A N/A 5 OK N/A N/A)
	$(crow c1 1 churn N/A N/A 9 OK N/A N/A)
	EOF
	run "$REPORT" --results-dir "$RES" --format csv
	assert_success
	assert_line "2,1,4.00,N/A,1,1,5.00,9.00,N/A,N/A,N/A,N/A,N/A,N/A,0"
}

@test "005: the convergence p99 is the worst bucket, with bare labels and (ms) in the header" {
	two_pairs
	run "$REPORT" --results-dir "$RES" --format md
	assert_success
	assert_output --partial "| churn_eds_pushes | churn_convergence_p99 worst (ms) |"
	# 99 and 600 average to ~350 ("100-500"), a bucket no run hit.
	refute_output --partial "| 100-500 |"
	refute_output --regexp '[0-9]ms \|'
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "churn_convergence_p99 worst (ms)"
	assert_output --regexp '\| +500-1000'
	run "$REPORT" --results-dir "$RES" --format csv
	assert_line --partial ",churn_eds_pushes,churn_convergence_p99_worst,churn_convergence_overflow_runs"
}

@test "005: an overflowed convergence p99 prints overflow with a count" {
	write_tsv "${RES}/churn-dataplane-r1.tsv" <<-EOF
	$(crow c1 0 baseline 50 2 5 OK N/A N/A)
	$(crow c1 1 churn 48 4 9 OK 30 99)
	$(crow c2 0 baseline 50 2 5 OK N/A N/A)
	$(crow c2 1 churn 48 4 9 OK 30 overflow)
	EOF
	run "$REPORT" --results-dir "$RES" --format md
	assert_success
	assert_output --partial "| 30 | overflow (1 run) |"
	run "$REPORT" --results-dir "$RES" --format csv
	assert_line --partial ",30,overflow,1"
	run "$REPORT" --results-dir "$RES" --format json
	[ "$(jq -c '.rows[0] | [.churn_convergence_p99_worst, .churn_convergence_overflow_runs]' <<<"$output")" = '["overflow",1]' ]
}

@test "005: json row values are numbers, N/A is null" {
	two_pairs
	# A churn rate whose only pair failed: every average is N/A.
	crow c3 0 baseline 50 2 5 OK N/A N/A >> "${RES}/churn-dataplane-r1.tsv"
	crow c3 5 churn N/A N/A N/A FAILED N/A N/A >> "${RES}/churn-dataplane-r1.tsv"
	run "$REPORT" --results-dir "$RES" --format json
	assert_success
	# Compared as numbers: jq versions print 5.00 as 5 or 5.00.
	[ "$(jq '.rows[0] | .delta_p99_ms == 5 and .stdev_delta_p99 == 1.41 and .baseline_p50_ms == 2 and .baseline_qps == 50 and .churn_eds_pushes == 40' <<<"$output")" = true ]
	[ "$(jq -r '[.rows[0][] | type] | unique | join(",")' <<<"$output")" = "number,string" ]
	[ "$(jq -r '.rows[0].churn_convergence_p99_worst' <<<"$output")" = "500-1000" ]
	[ "$(jq -c '.rows[1] | [.churn_rate, .valid_runs, .delta_p99_ms, .baseline_p50_ms, .churn_qps, .churn_convergence_p99_worst, .churn_convergence_overflow_runs]' <<<"$output")" = '[5,0,null,null,null,null,0]' ]
	# No average is a string any more.
	[ "$(jq '[.rows[] | to_entries[] | select(.key != "churn_convergence_p99_worst") | .value | strings] | length' <<<"$output")" = 0 ]
}

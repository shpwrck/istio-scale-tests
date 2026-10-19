#!/usr/bin/env bats
# churn-dataplane 005 through its real entrypoint: each average has its own count (an
# N/A p50 or QPS is not a 0), JSON numbers are numbers (null for N/A), and the
# convergence p99 is the worst bucket (bare range labels, "(ms)" in the header) with
# an overflow count instead of the bucket of a mean.

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr

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

# write_tsv <file>; rows come on stdin. NO_PLATFORM=1: a legacy file, without the platform
# record every writer adds now.
write_tsv() {
	{
		echo "# RUN_ID=r1"
		[[ -n "${NO_PLATFORM:-}" ]] || platform_fixture_lines
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
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	[ "$(jq -c '.rows[0] | [.churn_convergence_p99_worst, .churn_convergence_overflow_runs]' <<<"$output")" = '["overflow",1]' ]
}

@test "005: json row values are numbers, N/A is null" {
	two_pairs
	# A churn rate whose only pair failed: every average is N/A.
	crow c3 0 baseline 50 2 5 OK N/A N/A >> "${RES}/churn-dataplane-r1.tsv"
	crow c3 5 churn N/A N/A N/A FAILED N/A N/A >> "${RES}/churn-dataplane-r1.tsv"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	# Compared as numbers: jq versions print 5.00 as 5 or 5.00.
	[ "$(jq '.rows[0] | .delta_p99_ms == 5 and .stdev_delta_p99 == 1.41 and .baseline_p50_ms == 2 and .baseline_qps == 50 and .churn_eds_pushes == 40' <<<"$output")" = true ]
	[ "$(jq -r '[.rows[0][] | type] | unique | join(",")' <<<"$output")" = "number,string" ]
	[ "$(jq -r '.rows[0].churn_convergence_p99_worst' <<<"$output")" = "500-1000" ]
	[ "$(jq -c '.rows[1] | [.churn_rate, .valid_runs, .delta_p99_ms, .baseline_p50_ms, .churn_qps, .churn_convergence_p99_worst, .churn_convergence_overflow_runs]' <<<"$output")" = '[5,0,null,null,null,null,0]' ]
	# No average is a string any more.
	[ "$(jq '[.rows[] | to_entries[] | select(.key != "churn_convergence_p99_worst") | .value | strings] | length' <<<"$output")" = 0 ]
}

@test "005: the platform record reaches every format; an input from before it reads unknown, with a warning (PL19)" {
	two_pairs
	run --separate-stderr "$REPORT" --results-dir "$RES"
	assert_success
	assert_line "# PLATFORM=kubernetes"
	assert_line "# NODE_PROVIDER_BY_CONTEXT=ctx-a=kind,ctx-b=kind"
	# The fixture's members are on kind: the cross-cluster path's warning is the only one (H11).
	[[ "$stderr" == "WARNING: Nodes on kind (NODE_PROVIDER_BY_CONTEXT): the cross-cluster path runs through cloud-provider-kind's userspace Envoy"* ]]
	[ "$(grep -c . <<<"$stderr")" -eq 1 ]
	run --separate-stderr "$REPORT" --results-dir "$RES" --format csv
	assert_line "# MESH_OPERATOR_BY_CONTEXT=ctx-a=sail-operator:1.31.1/Available,ctx-b=sail-operator:1.31.1/Available"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format md
	assert_line '| ISTIOD_IMAGE_BY_CONTEXT | `ctx-a=pilot:1.30.5,ctx-b=pilot:1.30.5` |'
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	[ "$(jq -r '.metadata | "\(.platform) \(.test_platform) \(.proxy_image_by_context)"' <<<"$output")" = "kubernetes auto ctx-a=proxyv2:1.30.5,ctx-b=proxyv2:1.30.5" ]
	rm "${RES}"/*.tsv
	NO_PLATFORM=1 two_pairs
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -r '.metadata | "\(.platform) \(.mesh_operator_by_context)"' <<<"$output")" = "unknown unknown" ]
	[[ "$stderr" == *"1 of 1 input TSV(s) have no PLATFORM line"* ]]
}

# --- the platform record's warnings in the report's body (H10, H11) ---

@test "005 (H10, H11): inputs that disagree and kind nodes warn in every format's body; cloud nodes that agree warn in none" {
	# One sweep's dir (its steps' TSVs and platform-drift.txt): one run, whatever their RUN_IDs.
	RES="${BATS_TEST_TMPDIR}/sweep-h10"
	mkdir -p "$RES"
	two_pairs
	# A second sweep's TSV in the same base dir, on another mesh operator build for ctx-b.
	{
		echo "# RUN_ID=r2"
		platform_fixture_lines | sed 's/ctx-b=sail-operator:1.31.1/ctx-b=sail-operator:1.31.2/'
		echo "$HDR"
		crow c9 0 baseline 50 2 5 OK N/A N/A
		crow c9 1 churn 48 4 9 OK 30 99
	} > "${RES}/churn-dataplane-r2.tsv"
	local dis="input TSVs disagree on MESH_OPERATOR_BY_CONTEXT for ctx-b (sail-operator:1.31.1/Available;sail-operator:1.31.2/Available): the report mixes runs on different mesh operator builds; compare like with like"
	local kind="Nodes on kind (NODE_PROVIDER_BY_CONTEXT): the cross-cluster path runs through cloud-provider-kind's userspace Envoy (the east-west gateway's LoadBalancer, ipMode: Proxy) on the host all kind clusters share, so at mesh sizes above 1"
	local fmt top first
	for fmt in md charts; do
		run --separate-stderr "$REPORT" --results-dir "$RES" --format "$fmt"
		assert_success
		assert_output --partial "> **Warning:** ${dis}"
		assert_output --partial "> **Warning:** ${kind}"
		# Under the title (charts: after its "## KEY=value" front matter), before the first
		# table, section, chart or note.
		top="$(grep -n '^> \*\*Warning:\*\* input TSVs disagree' <<<"$output" | cut -d: -f1)"
		first="$(awk 'seen && /^(\| |## |```mermaid|% Chart|> [^*])/ { print NR; exit } /^# / { seen = 1 }' <<<"$output")"
		((top < first)) || { echo "${fmt}: warning at ${top}, first table, section or note at ${first}"; false; }
	done
	run --separate-stderr "$REPORT" --results-dir "$RES"
	assert_line "WARNING: ${dis}"
	assert_output --partial "WARNING: ${kind}"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format csv
	assert_line "# WARNING: ${dis}"
	assert_output --partial "# WARNING: ${kind}"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq '.warnings | length' <<<"$output")" = 2 ]
	[ "$(jq -r '.warnings[0]' <<<"$output")" = "$dis" ]
	[[ "$(jq -r '.warnings[1]' <<<"$output")" == "${kind}"* ]]
	[[ "$stderr" == *"warning: ${dis}"* ]]
	[[ "$stderr" == *"WARNING: ${kind}"* ]]
	# Cloud nodes, one build (an operator state aside): no warning in any format.
	local t
	for t in r1 r2; do
		sed 's/=kind/=aws/g; s#ctx-b=sail-operator:1.31.2/Available#ctx-b=sail-operator:1.31.1/Unavailable#' \
			"${RES}/churn-dataplane-${t}.tsv" > "${RES}/${t}.tmp"
		mv "${RES}/${t}.tmp" "${RES}/churn-dataplane-${t}.tsv"
	done
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -c '.warnings' <<<"$output")" = '[]' ]
	[ -z "$stderr" ] || { echo "$stderr"; false; }
	for fmt in md charts; do
		run --separate-stderr "$REPORT" --results-dir "$RES" --format "$fmt"
		refute_output --partial "**Warning:**"
	done
	run --separate-stderr "$REPORT" --results-dir "$RES"
	refute_output --partial "WARNING:"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format csv
	refute_output --partial "WARNING:"
}

@test "005 (S-B2): a record of 500 members goes through every format; json lists them all" {
	PLATFORM_FIXTURE_CTXS="$(wide_ctxs 500 ctx-a ctx-b)" two_pairs
	wide_record_report "$REPORT" "$RES" text csv json md charts
}

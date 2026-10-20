#!/usr/bin/env bats
# A report's json keeps every string it reads from a TSV preamble as itself: a quote, a
# backslash, a tab or a carriage return (a hand-edited TSV, a --config path, a file saved
# with CRLF) must neither break the JSON nor change the value. Through the real entrypoints
# (PL33); jq parses each output. No cluster.

bats_require_minimum_version 1.5.0
load test_helper

CP_FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"
CP_REPORT="${ROOT}/tests/controlplane/004-report-results.sh"
PROP_REPORT="${ROOT}/tests/propagation/005-report-results.sh"
PROP_HDR=$'run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms'

@test "controlplane 004 json: a run-config path, a mixed harness and a leftover count with \" and \\ read back as themselves" {
	local d="${BATS_TEST_TMPDIR}/r" n
	mkdir -p "$d"
	# Two attempts of one run, each with its own harness (h1"q\x, h2"q\x): the json names
	# both, and the mixed value. \t and \x stay two characters each (awk -v would read \t as
	# a tab).
	for n in 1 2; do
		awk -v n="$n" '
			NR == 1 { print; print "# RUN_CONFIG=configs/r\"c\\td.env"; print "# LEFTOVER_TEST_NAMESPACES=2 (\"a\\b\")"; next }
			/^# HARNESS_SHA=/ { print "# HARNESS_SHA=h" n "\"q\\x"; next }
			{ print }' "$CP_FIXTURE" > "${d}/controlplane-fixture-t2-${n}.tsv"
	done
	grep -qxF '# RUN_CONFIG=configs/r"c\td.env' "${d}/controlplane-fixture-t2-1.tsv"
	run --separate-stderr "$CP_REPORT" --results-dir "$d" --format json
	assert_success
	jq -e . <<<"$output" > /dev/null
	[ "$(jq -r '.metadata.run_config' <<<"$output")" = 'configs/r"c\td.env' ]
	[ "$(jq -r '.metadata.harness_sha' <<<"$output")" = 'mixed:h1"q\x,h2"q\x' ]
	[ "$(jq -c '.metadata.harness_shas' <<<"$output")" = '["h1\"q\\x","h2\"q\\x"]' ]
	[ "$(jq -c '[.metadata.attempts[].harness_sha]' <<<"$output")" = '["h1\"q\\x","h2\"q\\x"]' ]
	[ "$(jq -c '.pooled_runs.harness_sha' <<<"$output")" = '["h1\"q\\x","h2\"q\\x"]' ]
	[ "$(jq -r '.metadata.growth.leftover_test_namespaces_at_start' <<<"$output")" = '2 ("a\b")' ]
	[[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" == *'(HARNESS_SHA h1"q\x,h2"q\x)'* ]]
}

@test "propagation 005 json: a run-config path with \", \\ and a tab, and a harness line saved with CRLF, read back as themselves" {
	local d="${BATS_TEST_TMPDIR}/r"
	mkdir -p "$d"
	{
		echo "# RUN_ID=r1"
		printf '# RUN_CONFIG=configs/r"c\\d\te.env\n'
		printf '# HARNESS_SHA=h"1\\x\r\n'
		echo "$PROP_HDR"
		printf 'r1\t2\t1\tsrc\trmt\t0\t1000\t500\t3000\tOK\t100\t100\t40/40\t40\t0\t0\t0\t5000\t10\n'
	} > "${d}/endpoint-r1.tsv"
	run --separate-stderr "$PROP_REPORT" --results-dir "$d" --format json
	assert_success
	jq -e . <<<"$output" > /dev/null
	[ "$(jq -r '.metadata.RUN_CONFIG' <<<"$output")" = $'configs/r"c\\d\te.env' ]
	[ "$(jq -r '.metadata.HARNESS_SHA' <<<"$output")" = $'h"1\\x\r' ]
	[ "$(jq -c '.pooled_runs.harness_sha' <<<"$output")" = '["h\"1\\x\r"]' ]
}

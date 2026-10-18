#!/usr/bin/env bats
# The rows' own harness in a churn-dataplane TSV, through the real reports (PL33), no
# cluster: a sweep appends every probe to one TSV whose preamble keeps the sweep's start,
# while each row's harness_sha column records the harness its probe ran. Rows that record
# more than one, or another than the preamble, make churn-dataplane 005's HARNESS_SHA read
# mixed and its HARNESS_CONTENT_KEY add unknown, with a warning in every format that names
# the combos whose baseline and churn rows differ; tuning 004 shows that pass's Harness row
# mixed and names it in its WARNING. Harness values are made up.

bats_require_minimum_version 1.5.0
load test_helper

REPORT="${ROOT}/tests/churn-dataplane/005-report-results.sh"
COMPARE="${ROOT}/tests/tuning/004-compare-profiles.sh"
KEY=0123456789ab
HDR=$'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms'

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
}

# row <harness_sha> <combo> <churn_rate> <phase> <p99>: one valid mesh_size=2 row.
row() {
	printf 'r1\t%s\t%s\t2\t%s\t%s\t60\t50\t50\t2\t3\t%s\t6\t7\tN/A\t0\tOK\t10\t10\t100\tN/A\t5\tN/A\tN/A\tN/A\n' "$@"
}

# cdp_tsv <file> <preamble HARNESS_SHA>; rows on stdin.
cdp_tsv() {
	mkdir -p "$(dirname "$1")"
	{
		printf '# RUN_ID=r1\n# HARNESS_SHA=%s\n# HARNESS_CONTENT_KEY=%s\n' "$2" "$KEY"
		echo "$HDR"
		cat
	} > "$1"
}

@test "churn-dataplane 005: a row with another harness than the preamble reads mixed, adds unknown to the key and warns in every format, naming the combo whose baseline and churn rows differ" {
	local warn f
	cdp_tsv "${RES}/churn-dataplane-r1.tsv" abc1234 <<-EOF
	$(row abc1234 ms2-cr10 0 baseline 5)
	$(row abc1234-dirty.ffffffff ms2-cr10 10 churn 9)
	$(row abc1234 ms2-cr20 0 baseline 5)
	$(row abc1234 ms2-cr20 20 churn 8)
	EOF
	warn="the rows' harness_sha column (abc1234 3 rows, abc1234-dirty.ffffffff 1 row) differs from the TSV preamble's HARNESS_SHA (abc1234), the run's start: the harness changed during the run (HARNESS_CONTENT_KEY adds unknown: a row records none). Combos whose baseline and churn rows ran different harnesses, so their delta_p99 pairs the two: ms2-cr10 (mesh_size 2, churn_rate 10: baseline abc1234, churn abc1234-dirty.ffffffff)."
	run --separate-stderr "$REPORT" --results-dir "$RES" --format text
	assert_success
	assert_line "WARNING: ${warn}"
	assert_line "# HARNESS_SHA=mixed:abc1234,abc1234-dirty.ffffffff"
	assert_line "# HARNESS_CONTENT_KEY=mixed:${KEY},unknown"
	[[ "$stderr" == *"WARNING: ${warn}"* ]]
	run --separate-stderr "$REPORT" --results-dir "$RES" --format csv
	assert_success
	assert_line "# WARNING: ${warn}"
	assert_line "# HARNESS_SHA=mixed:abc1234,abc1234-dirty.ffffffff"
	for f in md charts; do
		run --separate-stderr "$REPORT" --results-dir "$RES" --format "$f"
		assert_success
		assert_line "> **Warning:** ${warn}"
		assert_line 'harness_sha: "mixed:abc1234,abc1234-dirty.ffffffff"'
		assert_line "harness_content_key: \"mixed:${KEY},unknown\""
	done
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -r '.data_warnings | length' <<<"$output")" = 1 ]
	[ "$(jq -r '.data_warnings[0]' <<<"$output")" = "$warn" ]
	[ "$(jq -r '.metadata.harness_sha' <<<"$output")" = "mixed:abc1234,abc1234-dirty.ffffffff" ]
	[ "$(jq -r '.metadata.harness_content_key' <<<"$output")" = "mixed:${KEY},unknown" ]
}

@test "churn-dataplane 005: rows on the preamble's harness give no warning (json data_warnings []); rows that all moved, or combos on different harnesses, say which" {
	cdp_tsv "${RES}/churn-dataplane-r1.tsv" abc1234 <<-EOF
	$(row abc1234 ms2-cr10 0 baseline 5)
	$(row abc1234 ms2-cr10 10 churn 9)
	EOF
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -c '.data_warnings' <<<"$output")" = "[]" ]
	[ "$(jq -r '.metadata.harness_sha' <<<"$output")" = abc1234 ]
	[ "$(jq -r '.metadata.harness_content_key' <<<"$output")" = "$KEY" ]
	[[ "$stderr" != *WARNING* ]]
	# Every row on one harness that is not the preamble's: no combo pairs two harnesses.
	cdp_tsv "${RES}/churn-dataplane-r1.tsv" abc1234 <<-EOF
	$(row def5678 ms2-cr10 0 baseline 5)
	$(row def5678 ms2-cr10 10 churn 9)
	EOF
	run --separate-stderr "$REPORT" --results-dir "$RES" --format text
	assert_success
	assert_line "WARNING: the rows' harness_sha column (def5678 2 rows) differs from the TSV preamble's HARNESS_SHA (abc1234), the run's start: the harness changed during the run (HARNESS_CONTENT_KEY adds unknown: a row records none)."
	# Each combo on one harness, the combos on two.
	cdp_tsv "${RES}/churn-dataplane-r1.tsv" abc1234 <<-EOF
	$(row abc1234 ms2-cr10 0 baseline 5)
	$(row abc1234 ms2-cr10 10 churn 9)
	$(row def5678 ms2-cr20 0 baseline 5)
	$(row def5678 ms2-cr20 20 churn 8)
	EOF
	run --separate-stderr "$REPORT" --results-dir "$RES" --format csv
	assert_success
	assert_line --partial "# WARNING: the rows' harness_sha column (abc1234 2 rows, def5678 2 rows) differs from"
	assert_line --partial "Each combo's baseline and churn rows ran one harness, but not every combo the same one: compare the combos with care."
	refute_line --partial "Combos whose baseline and churn rows ran different harnesses"
}

@test "tuning 004: a churn-dataplane pass whose rows ran another harness reads mixed in its Harness row, and the WARNING names that pass and the combo" {
	local s="${BATS_TEST_TMPDIR}/sweep" p
	mkdir -p "$s"
	printf '# SUITE=churn-dataplane\n# PASSES=baseline,p1\n# RUN_ID=t1\n# HARNESS_SHA=abc1234\n# HARNESS_CONTENT_KEY=%s\n' "$KEY" > "${s}/sweep-metadata.txt"
	cdp_tsv "${s}/baseline/churn-dataplane-b.tsv" abc1234 <<-EOF
	$(row abc1234 ms2-cr10 0 baseline 5)
	$(row abc1234-dirty.ffffffff ms2-cr10 10 churn 9)
	EOF
	cdp_tsv "${s}/p1/churn-dataplane-p.tsv" abc1234 <<-EOF
	$(row abc1234 ms2-cr10 0 baseline 5)
	$(row abc1234 ms2-cr10 10 churn 8)
	EOF
	for p in text md; do
		run --separate-stderr "$COMPARE" --results-dir "$s" --format "$p"
		assert_success
		assert_output --regexp "Harness \(HARNESS_SHA\) +\|? *mixed:abc1234,abc1234-dirty\.ffffffff +\|? *abc1234"
		assert_output --partial "Pass baseline's rows record more than one harness (harness_sha column and preamble: abc1234,abc1234-dirty.ffffffff), so the harness changed during that pass; combos whose baseline and churn rows ran different harnesses, so their delta_p99 pairs the two: ms2-cr10 (baseline abc1234, churn abc1234-dirty.ffffffff)."
		refute_output --partial "differ only in git describe"
	done
	# Rows on their preamble's harness: one value per pass, no warning.
	cdp_tsv "${s}/baseline/churn-dataplane-b.tsv" abc1234 <<-EOF
	$(row abc1234 ms2-cr10 0 baseline 5)
	$(row abc1234 ms2-cr10 10 churn 9)
	EOF
	run --separate-stderr "$COMPARE" --results-dir "$s"
	assert_success
	assert_output --regexp "Harness \(HARNESS_SHA\) +abc1234 +abc1234"
	refute_output --partial "different harnesses"
}

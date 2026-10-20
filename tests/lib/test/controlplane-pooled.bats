#!/usr/bin/env bats
# Controlplane 004 over sweep records below its results dir, through its entrypoint (PL33;
# fixture TSVs, no cluster): a pooled sweep whose record has not finished, was interrupted
# or stopped early gets a data warning in every format (its record is repeated nowhere
# else), and the pooled note says what the report repeats; the verdict names several
# records as "the sweep outcomes record"; each cell a warning lists names its TSV when the
# report reads more than one; and a results dir given with trailing slashes counts each
# record once and names it relative to the results dir.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/envelope.sh"

REPORT="${ROOT}/tests/controlplane/004-report-results.sh"
FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"
NOTE="This report repeats only the results dir's own sweep-outcome.txt, when it has one, never that of a sweep-* dir below it: it counts their PROBLEMs in the verdict and names each one that has not finished or was cut short in a data warning; report each sweep alone to see its failed cells, problems and notes."

setup() {
	BASE="${BATS_TEST_TMPDIR}/base"
	local s
	# Two sweeps of one cell each (mesh-a and mesh-b, 3 valid rows each).
	for s in a b; do
		mkdir -p "${BASE}/sweep-${s}"
		awk -F'\t' -v OFS='\t' -v r="run-${s}" -v w="${WR:-mesh-a=3/3,mesh-b=3/3}" '
			function row(m,    i) { for (i = 1; i <= 3; i++) { $0 = t; $2 = m; $31 = 0; print } }
			index($0, "# RUN_ID=") == 1 { print "# RUN_ID=" r; next }
			/^#/ { print; if (index($0, "# ISTIOD_REPLICAS=") == 1) print "# ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=3,mesh-b=3"; next }
			$1 == "timestamp" { print; next }
			t == "" { t = $0 }
			END { print "# WINDOW_ROWS=" w; row("mesh-a"); row("mesh-b") }' "$FIXTURE" > "${BASE}/sweep-${s}/controlplane-run-${s}.tsv"
	done
}

# report <format> <dir> [flag...]: 004 over <dir>, its stderr apart.
report() {
	local fmt="$1" dir="$2"
	shift 2
	run --separate-stderr "$REPORT" --results-dir "$dir" --format "$fmt" "$@"
	assert_success
}

headline() { jq -r '.metadata.sla.headline' <<<"$output"; }

@test "a pooled sweep record that has not finished, was interrupted or stopped early is a data warning in every format, and the pooled note says what the report repeats; a finished one with a PROBLEM is named only in the verdict" {
	local w
	printf 'RUN_ID=run-a\nEXIT=4\nPROBLEM=the Istio version changed during the sweep (bats)\n' > "${BASE}/sweep-a/sweep-outcome.txt"
	printf 'RUN_ID=run-b\nEXIT=unfinished\nSTARTED_AT=2026-06-01T01:00:00Z\nUNIT=cells\n' > "${BASE}/sweep-b/sweep-outcome.txt"
	w="The record of a sweep below the results dir, sweep-b/sweep-outcome.txt, has not finished (it died, or still runs): that sweep's rows may be partial, and this report repeats only the results dir's own sweep-outcome.txt (report that sweep alone to see its failed cells, problems and notes)."
	report json "$BASE" --allow-multi-run
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = "$(jq -cn --arg w "$w" '[$w]')" ]
	[[ "$(headline)" == "the sweep outcome records 1 PROBLEM(s) (sweep-a/sweep-outcome.txt), so the figures"* ]]
	[[ "$stderr" == *"WARNING: ${w}"* ]]
	report text "$BASE" --allow-multi-run
	assert_line "# WARNING: ${w}"
	assert_output --partial "# POOLED RUNS: This report pools 2 runs (--allow-multi-run): sweep-a, sweep-b."
	assert_output --partial " ${NOTE}"
	report csv "$BASE" --allow-multi-run
	assert_line "# WARNING: ${w}"
	assert_line "# NOTE: ${NOTE}"
	report markdown "$BASE" --allow-multi-run
	assert_line "> **Warning:** ${w}"
	assert_output --partial "> **Pooled runs.** This report pools 2 runs"
	assert_output --partial " ${NOTE}"
	report charts "$BASE" --allow-multi-run
	assert_line "> **Warning:** ${w}"
	# Interrupted, and stopped early with a PROBLEM: the record's own words.
	printf 'RUN_ID=run-b\nEXIT=unfinished\nUNIT=cells\nENDED_AT=2026-06-01T01:05:00Z\nENDED_SIGNAL=SIGTERM\n' > "${BASE}/sweep-b/sweep-outcome.txt"
	report json "$BASE" --allow-multi-run
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == "The record of a sweep below the results dir, sweep-b/sweep-outcome.txt, was interrupted before it wrote its outcome: that sweep's rows"* ]]
	printf 'RUN_ID=run-b\nEXIT=1\nCUT_SHORT=1\nSTOPPED=1\nPROBLEM=istiod restarted (bats)\n' > "${BASE}/sweep-b/sweep-outcome.txt"
	report json "$BASE" --allow-multi-run
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == "The record of a sweep below the results dir, sweep-b/sweep-outcome.txt, stopped early, with 1 PROBLEM(s): that sweep's rows"* ]]
	# Both finished: no data warning.
	printf 'RUN_ID=run-b\nEXIT=0\nUNIT=cells\n' > "${BASE}/sweep-b/sweep-outcome.txt"
	report json "$BASE" --allow-multi-run
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = '[]' ]
}

@test "one sweep's report repeats its own record (no data warning for it), and one sweep below the results dir that has not finished is named as a pooled one is, and one with a PROBLEM in the verdict" {
	printf 'RUN_ID=run-b\nEXIT=unfinished\nUNIT=cells\n' > "${BASE}/sweep-b/sweep-outcome.txt"
	report json "${BASE}/sweep-b"
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = '[]' ]
	[ "$(jq -r '.sweep_outcome.unfinished' <<<"$output")" = true ]
	report text "${BASE}/sweep-b"
	refute_output --partial "$NOTE"
	# The base dir with that sweep alone: one run, its record below the results dir.
	rm -rf "${BASE}/sweep-a"
	report json "$BASE"
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == "The record of a sweep below the results dir, sweep-b/sweep-outcome.txt, has not finished (it died, or still runs): "* ]]
	report text "$BASE"
	refute_output --partial "$NOTE"
	# That sweep finished with a PROBLEM: no data warning, and the verdict names its record.
	printf 'RUN_ID=run-b\nEXIT=4\nPROBLEM=istiod restarted (bats)\n' > "${BASE}/sweep-b/sweep-outcome.txt"
	report json "$BASE"
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = '[]' ]
	[[ "$(headline)" == "the sweep outcome records 1 PROBLEM(s) (sweep-b/sweep-outcome.txt), so the figures"* ]]
}

@test "several records in the verdict read 'the sweep outcomes record'; one reads 'the sweep outcome records' (env_sla_verdict and the pooled report)" {
	run env_sla_verdict 10 10 10 10 0 6 6 "" "" 0 0 2 "sweep-a/sweep-outcome.txt: 1; sweep-b/sweep-outcome.txt: 1"
	assert_output "CAUTION|the sweep outcomes record 2 PROBLEM(s) (sweep-a/sweep-outcome.txt: 1; sweep-b/sweep-outcome.txt: 1), so the figures may not measure what they seem to; the figures: peak utilization 10% < 75% across istiod + nodes, no restarts, all 6 samples valid"
	run env_sla_verdict 10 10 10 10 1 6 5 "" "" 0 0 2 "sweep-a/sweep-outcome.txt: 1; sweep-b/sweep-outcome.txt: 1"
	assert_output --regexp '^FAIL\|.*; also the sweep outcomes record 2 PROBLEM\(s\) \(sweep-a/sweep-outcome.txt: 1; sweep-b/sweep-outcome.txt: 1\)$'
	run env_sla_verdict 10 10 10 10 0 6 6 "" "" 0 0 2 "sweep-outcome.txt, and .prev.txt before it"
	assert_output --regexp '^CAUTION\|the sweep outcome records 2 PROBLEM\(s\) \(sweep-outcome.txt, and .prev.txt before it\), so'
	printf 'RUN_ID=run-a\nEXIT=4\nPROBLEM=a (bats)\n' > "${BASE}/sweep-a/sweep-outcome.txt"
	printf 'RUN_ID=run-b\nEXIT=4\nPROBLEM=b (bats)\n' > "${BASE}/sweep-b/sweep-outcome.txt"
	report json "$BASE" --allow-multi-run
	[[ "$(headline)" == "the sweep outcomes record 2 PROBLEM(s) (sweep-a/sweep-outcome.txt: 1; sweep-b/sweep-outcome.txt: 1), so the figures"* ]]
}

@test "a pooled report names each cell of a warning behind its TSV, so one cell of two sweeps reads as two; a one-TSV report names the cell alone" {
	local c="mesh=2 svcs=15 reps=2 ns=1 scope=none traffic=none (mesh-b ran 2 of its 3 istiod replicas)"
	WR="mesh-a=3/3,mesh-b=2/3" setup
	report json "$BASE" --allow-multi-run
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == "2 cell(s) ran on fewer istiod pods than their member's istiod Deployment wants "*": sweep-a/controlplane-run-a.tsv: ${c}; sweep-b/controlplane-run-b.tsv: ${c}." ]]
	report json "${BASE}/sweep-a"
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == "1 cell(s) ran on fewer istiod pods than their member's istiod Deployment wants "*": ${c}." ]]
}

@test "a results dir given with trailing slashes counts each record once and names it relative to the results dir" {
	local d="${BATS_TEST_TMPDIR}/one" h
	mkdir -p "$d"
	cp "${BASE}/sweep-a/controlplane-run-a.tsv" "$d/"
	# A --resume that has not finished, and the outcome before it, with one PROBLEM.
	printf 'RUN_ID=run-a\nEXIT=unfinished\nUNIT=cells\n' > "${d}/sweep-outcome.txt"
	printf 'RUN_ID=run-a\nEXIT=4\nPROBLEM=a (bats)\n' > "${d}/sweep-outcome.prev.txt"
	report json "$d"
	h="$(headline)"
	[[ "$h" == "the sweep outcome records 1 PROBLEM(s) (sweep-outcome.txt, and .prev.txt before it), so the figures"* ]]
	report json "${d}//"
	[ "$(headline)" = "$h" ]
	report json "${d}/"
	[ "$(headline)" = "$h" ]
	report markdown "${d}///"
	refute_output --partial "$BATS_TEST_TMPDIR"
	# A pooled base dir: each sweep's record once.
	printf 'RUN_ID=run-a\nEXIT=4\nPROBLEM=a (bats)\n' > "${BASE}/sweep-a/sweep-outcome.txt"
	report json "${BASE}//" --allow-multi-run
	[[ "$(headline)" == "the sweep outcome records 1 PROBLEM(s) (sweep-a/sweep-outcome.txt), so the figures"* ]]
}

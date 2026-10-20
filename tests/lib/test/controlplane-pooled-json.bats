#!/usr/bin/env bats
# Controlplane 004 over sweep records and TSVs below its results dir, through its entrypoint
# (PL33; fixture TSVs, no cluster): json has a top-level pooled_sweep_outcomes array next to
# pooled_runs, as the other suites' reports do ([] when none), and keeps the data warnings;
# a report of several TSVs names each attempt after its TSV, without an "each file's first
# run:" prefix.

bats_require_minimum_version 1.5.0
load test_helper

REPORT="${ROOT}/tests/controlplane/004-report-results.sh"
FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"

setup() {
	BASE="${BATS_TEST_TMPDIR}/base"
	local s
	# Two sweeps of one cell each (mesh-a and mesh-b, 3 valid rows each).
	for s in a b; do
		mkdir -p "${BASE}/sweep-${s}"
		awk -F'\t' -v OFS='\t' -v r="run-${s}" '
			function row(m,    i) { for (i = 1; i <= 3; i++) { $0 = t; $2 = m; $31 = 0; print } }
			index($0, "# RUN_ID=") == 1 { print "# RUN_ID=" r; next }
			/^#/ { print; if (index($0, "# ISTIOD_REPLICAS=") == 1) print "# ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=3,mesh-b=3"; next }
			$1 == "timestamp" { print; next }
			t == "" { t = $0 }
			END { print "# WINDOW_ROWS=mesh-a=3/3,mesh-b=3/3"; row("mesh-a"); row("mesh-b") }' "$FIXTURE" > "${BASE}/sweep-${s}/controlplane-run-${s}.tsv"
	done
}

# report <format> <dir> [flag...]: 004 over <dir>, its stderr apart.
report() {
	local fmt="$1" dir="$2"
	shift 2
	run --separate-stderr "$REPORT" --results-dir "$dir" --format "$fmt" "$@"
	assert_success
}

@test "json pooled_sweep_outcomes lists each record below the results dir that did not end cleanly or holds a PROBLEM, next to pooled_runs; [] when none; the data warning stays" {
	local w
	report json "$BASE" --allow-multi-run
	[ "$(jq -c '.pooled_sweep_outcomes' <<<"$output")" = '[]' ]
	[ "$(jq -c 'keys_unsorted' <<<"$output")" = '["metadata","pooled_runs","pooled_sweep_outcomes","sweep_outcome","results"]' ]
	printf 'RUN_ID=run-a\nEXIT=4\nPROBLEM=the Istio version changed during the sweep (bats)\n' > "${BASE}/sweep-a/sweep-outcome.txt"
	printf 'RUN_ID=run-b\nEXIT=unfinished\nSTARTED_AT=2026-06-01T01:00:00Z\nUNIT=cells\n' > "${BASE}/sweep-b/sweep-outcome.txt"
	report json "$BASE" --allow-multi-run
	[ "$(jq -c '.pooled_sweep_outcomes' <<<"$output")" = '["sweep-a/sweep-outcome.txt: 1 PROBLEM(s)","sweep-b/sweep-outcome.txt: has not finished (it died, or still runs)"]' ]
	w="The record of a sweep below the results dir, sweep-b/sweep-outcome.txt, has not finished (it died, or still runs): that sweep's rows may be partial, and this report repeats only the results dir's own sweep-outcome.txt (report that sweep alone to see its failed cells, problems and notes)."
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = "$(jq -cn --arg w "$w" '[$w]')" ]
	# One sweep reported from its own dir repeats its record: none listed. From its parent
	# dir, alone: listed.
	report json "${BASE}/sweep-b"
	[ "$(jq -c '.pooled_sweep_outcomes' <<<"$output")" = '[]' ]
	rm -rf "${BASE}/sweep-a"
	report json "$BASE"
	[ "$(jq -c '.pooled_sweep_outcomes' <<<"$output")" = '["sweep-b/sweep-outcome.txt: has not finished (it died, or still runs)"]' ]
}

@test "a report of several TSVs names each attempt after its TSV, with no 'each file's first run:' prefix" {
	local t="${BASE}/sweep-b/controlplane-run-b.tsv" n rows att
	# sweep-b's --resume ran the 30-service cell.
	n="$(wc -l < "$t" | tr -d ' ')"
	rows="$(tail -n 6 "$t" | awk -F'\t' -v OFS='\t' '{ $1 = "2026-06-01T00:05:00+00:00"; $4 = 30; print }')"
	printf '# RESUMED_AT=2026-06-01T00:05:00+00:00 TSV_LINES=%s HARNESS_SHA=res2 KUBE_VERSIONS=mesh-a=v1.35.0\n# WINDOW_ROWS=mesh-a=3/3,mesh-b=3/3\n%s\n' "$n" "$rows" >> "$t"
	att="the rows come from more than one run: sweep-a/controlplane-run-a.tsv: the first run HARNESS_SHA=fixture KUBE_VERSIONS=mesh-a=v1.34.8,mesh-b=v1.34.8 (6 row(s), 6 in the figures); sweep-b/controlplane-run-b.tsv: the first run HARNESS_SHA=fixture KUBE_VERSIONS=mesh-a=v1.34.8,mesh-b=v1.34.8 (6 row(s), 6 in the figures), then sweep-b/controlplane-run-b.tsv: --resume at 2026-06-01T00:05:00Z HARNESS_SHA=res2 KUBE_VERSIONS=mesh-a=v1.35.0 (6 row(s), 6 in the figures)"
	report text "$BASE" --allow-multi-run
	assert_output --partial "# attempts: ${att}"
	refute_output --partial "each file's first run"
	report csv "$BASE" --allow-multi-run
	assert_output --partial "# attempts: ${att}"
	report markdown "$BASE" --allow-multi-run
	assert_output --partial "> **Attempts:** ${att}"
}

@test "--help names json pooled_sweep_outcomes and how a warning names a cell of several TSVs, within 100 columns" {
	local h
	run --separate-stderr "$REPORT" --help
	assert_success
	[ -z "$(awk 'length($0) > 100' <<<"$output")" ] || { awk 'length($0) > 100' <<<"$output"; false; }
	h="$(tr '\n' ' ' <<<"$output" | tr -s ' ')"
	[[ "$h" == *"json pooled_sweep_outcomes lists each one that did not end cleanly or holds a PROBLEM ([] when none"* ]]
	[[ "$h" == *"In a report of several TSVs a warning names each cell after its TSV's path (relative to the results dir)."* ]]
}

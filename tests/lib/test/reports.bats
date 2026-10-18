#!/usr/bin/env bats
# Reports through their real entrypoints (PL33): propagation 005's n_attempted, the TSV
# widths that it and tuning 004 list and warn about, tuning 004's P1 cell when every
# iteration overflowed, and every sweep's and report's help naming each cause of a sweep's
# exit 4.

bats_require_minimum_version 1.5.0
load test_helper

PR="${ROOT}/tests/propagation"
TUNING_CMP="${ROOT}/tests/tuning/004-compare-profiles.sh"

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
	EK="${BATS_TEST_TMPDIR}/empty.kubeconfig"
	: > "$EK"
	export TMPDIR="$BATS_TEST_TMPDIR"
}

# _md_tables_even: every markdown table on stdin has as many unescaped | per row as its
# header (a | inside a cell, unescaped, would add a column).
_md_tables_even() {
	awk '
		function bars(s,    n, i, c, p) { n = 0; p = ""; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "|" && p != "\\") n++; p = c }; return n }
		/^\|/ { b = bars($0); if (!intab) { want = b; intab = 1 } else if (b != want) { print "uneven row (" b " vs " want "): " $0; bad = 1 }; next }
		{ intab = 0 }
		END { exit bad }'
}

# prow23 <iteration> <remote> <status> <p1_overflow> <restarted> <p1_status> <p1_skew> <remote_status> <remote_skew>:
# a 23-column row of run RID (r1), mesh size 3, p1 100 ms, P2 50 ms and P3 60 ms when
# remote_status is OK (else N/A).
prow23() {
	local p2=50 p3=60
	[[ "$8" == OK ]] || { p2=N/A p3=N/A; }
	printf '%s\t3\t%s\tsrc\t%s\t0\t100\t%s\t%s\t%s\t99\t99\t10/10\t10\t%s\t%s\t0\t5000\t10\t%s\t%s\t%s\t%s\n' \
		"${RID:-r1}" "$1" "$2" "$p2" "$p3" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}

@test "propagation 005: n_attempted is what the probes were configured to run (ITERATIONS x remotes), a shortfall warns in every format and on stderr; a placeholder counts what its mesh size would have run" {
	source "${ROOT}/tests/lib/propagation.sh"
	local i
	# Mesh size 3: 4 iterations on 2 remotes configured, 2 written.
	{
		printf '# RUN_ID=r1\n# SWEEP_RUN_ID=s1\n# REMOTES=ci-b ci-c\n# MESH_SIZE=3\n# ITERATIONS=4\n'
		echo "$PROP_TSV_HEADER"
		for i in 1 2; do prow23 "$i" ci-b OK 0 0 OK 5 OK 5; prow23 "$i" ci-c OK 0 0 OK 5 OK 5; done
	} > "${RES}/endpoint-r1.tsv"
	# Mesh size 5: its setup failed (006's placeholder): 4 iterations x 4 remotes, none ran.
	{
		printf '# SWEEP_RUN_ID=s1\n# RUN_ID=s1-failms5\n# MESH_SIZE=5\n# ITERATIONS=4\n'
		echo "$PROP_TSV_HEADER"
		prop_placeholder_row s1-failms5 5 ci-a SETUP_FAILED
	} > "${RES}/endpoint-zzfail-ms5-s1.tsv"
	local w3='mesh size 3: 2 of 4 iteration(s) and 4 of 8 row(s) were measured'
	local w5='mesh size 5: 0 of 4 iteration(s) and 0 of 16 row(s) were measured'
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format csv
	assert_success
	[[ "$stderr" == *"WARNING: ${w3}"*"WARNING: ${w5}"* ]]
	assert_line --partial "# WARNING: ${w3}"
	assert_line "mesh_size,phase,n_total,n_valid,min_ms,max_ms,avg_ms,p50_ms,p95_ms,p99_ms,worst_bucket,n_attempted"
	assert_line "3,P1_local_wall,2,2,100,100,100,100,N/A,N/A,,4"
	assert_line "3,P2_discovery,4,4,50,50,50,50,N/A,N/A,,8"
	assert_line "5,P1_local_wall,1,0,,,,,,,,4"
	assert_line "5,P3_dataplane,1,0,,,,,,,,16"
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format json
	[ "$(jq -c '[.rows[] | select(.phase == "P1_local_wall" or .phase == "P2_discovery") | [.mesh_size, .phase, .n_total, .n_attempted]]' <<<"$output")" = \
		'[[3,"P1_local_wall",2,4],[3,"P2_discovery",4,8],[5,"P1_local_wall",1,4],[5,"P2_discovery",1,16]]' ]
	jq -e --arg w3 "$w3" '(.data_warnings | length) == 2 and (.data_warnings[0] | startswith($w3))' <<<"$output"
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format md
	assert_line --partial "> **Warning:** ${w3}"
	# n_attempted follows n_total and n_valid in markdown and text (csv keeps it last).
	assert_line "| P2 remote istiod EDS | 4 | 4 | 8 | 50 | 50 | 50 | 50 | N/A | N/A |"
	_md_tables_even <<<"$output"
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES"
	assert_line --partial "WARNING: ${w5}"
	assert_output --regexp 'P2 remote istiod EDS +\| +4 \| +4 \| +8 \| +50 \|'
	# n_valid 0 reads 0 in text too, as in markdown, csv and json (never "-").
	assert_output --regexp 'P1 local xDS \(wall\) +\| +1 \| +0 \| +4 \| +- \|'
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format charts
	assert_output --partial "${w3}"
	# A probe that ran every iteration warns nothing; a TSV without ITERATIONS reads -.
	rm -f "${RES}/endpoint-zzfail-ms5-s1.tsv"
	sed -i.bak 's/^# ITERATIONS=4$/# ITERATIONS=2/' "${RES}/endpoint-r1.tsv"
	rm -f "${RES}"/*.bak
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format json
	[ -z "$stderr" ]
	jq -e '.data_warnings == [] and ([.rows[].n_attempted] | unique) == [2, 4]' <<<"$output"
	sed -i.bak '/^# ITERATIONS=/d' "${RES}/endpoint-r1.tsv"
	rm -f "${RES}"/*.bak
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format json
	jq -e '([.rows[].n_attempted] | unique) == [null]' <<<"$output"
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format csv
	assert_line "3,P2_discovery,4,4,50,50,50,50,N/A,N/A,,"
}

@test "propagation 005 and tuning 004: inputs of different widths (19 and 23 columns) list them (tsv_columns) and warn in every format; one width warns nothing" {
	source "${ROOT}/tests/lib/propagation.sh"
	local i
	{ echo "# RUN_ID=r1"; echo "$PROP_TSV_HEADER"; for i in 1 2 3; do prow23 "$i" ci-b OK 0 0 OK 5 OK 5; done; } > "${RES}/endpoint-r1.tsv"
	{ echo "# RUN_ID=r2"; cut -f1-19 <<<"$PROP_TSV_HEADER"; for i in 1 2 3; do RID=r2 prow23 "$i" ci-b OK 0 0 OK 5 OK 5 | cut -f1-19; done; } > "${RES}/endpoint-r2.tsv"
	local w='the input TSVs have different column counts (19 in 1 file(s), 23 in 1 file(s)), so their rows are filtered by different rules'
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --allow-multi-run --format json
	assert_success
	[[ "$stderr" == *"WARNING: ${w}"* ]]
	jq -e --arg w "$w" '.tsv_columns == [19, 23] and (.data_warnings | length) == 1 and (.data_warnings[0] | startswith($w))' <<<"$output"
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --allow-multi-run --format csv
	assert_line "# TSV_COLUMNS=19,23"
	assert_line --partial "# WARNING: ${w}"
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --allow-multi-run --format md
	assert_line "tsv_columns: [19, 23]"
	assert_line --partial "> **Warning:** ${w}"
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --allow-multi-run
	assert_line "  TSV_COLUMNS: 19,23"
	assert_line --partial "WARNING: ${w}"
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --allow-multi-run --format charts
	assert_output --partial "tsv_columns: [19, 23]"
	assert_output --partial "${w}"
	# tuning 004: the baseline pass written by an older harness (19), the profile by this one.
	local P="${BATS_TEST_TMPDIR}/psweep"
	mkdir -p "${P}/baseline" "${P}/01-x"
	printf '# SUITE=propagation\n# PASSES=baseline,01-x\n' > "${P}/sweep-metadata.txt"
	cp "${RES}/endpoint-r2.tsv" "${P}/baseline/"
	cp "${RES}/endpoint-r1.tsv" "${P}/01-x/"
	run --separate-stderr "$TUNING_CMP" --results-dir "$P" --format md
	assert_success
	assert_line "- TSV columns: baseline 19; 01-x 23"
	assert_line --partial "- **Warning:** the passes' TSVs have different column counts (baseline 19; 01-x 23), so their rows are filtered by different rules"
	[[ "$stderr" == *"WARNING: the passes' TSVs have different column counts"* ]]
	run --separate-stderr "$TUNING_CMP" --results-dir "$P"
	assert_line "TSV columns: baseline 19; 01-x 23"
	assert_line --partial "WARNING: the passes' TSVs have different column counts"
	# One width: listed once, no warning.
	cp "${RES}/endpoint-r1.tsv" "${P}/baseline/endpoint-r2.tsv"
	run --separate-stderr "$TUNING_CMP" --results-dir "$P" --format md
	assert_line "- TSV columns: 23"
	refute_output --partial "Warning"
	rm -f "${RES}/endpoint-r2.tsv"
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format json
	[ -z "$stderr" ]
	jq -e '.tsv_columns == [23] and .data_warnings == []' <<<"$output"
}

@test "tuning 004: a P1 cell whose every iteration overflowed reads - (N overflowed), in md and text" {
	source "${ROOT}/tests/lib/propagation.sh"
	local P="${BATS_TEST_TMPDIR}/psweep" i
	mkdir -p "${P}/baseline" "${P}/01-x"
	printf '# SUITE=propagation\n# PASSES=baseline,01-x\n' > "${P}/sweep-metadata.txt"
	{ printf '# RUN_ID=r1\n# ITERATIONS=3\n# REMOTES=ci-b\n'; echo "$PROP_TSV_HEADER"; for i in 1 2 3; do prow23 "$i" ci-b OK 0 0 OK 5 OK 5; done; } > "${P}/baseline/endpoint-r1.tsv"
	# The profile: every iteration's P1 window put a sample in +Inf.
	{ printf '# RUN_ID=r2\n# ITERATIONS=3\n# REMOTES=ci-b\n'; echo "$PROP_TSV_HEADER"; for i in 1 2 3; do RID=r2 prow23 "$i" ci-b OK 1 0 OK 5 OK 5; done; } > "${P}/01-x/endpoint-r2.tsv"
	run --separate-stderr "$TUNING_CMP" --results-dir "$P" --format md
	assert_success
	assert_line "| P1 local push (ms) | 100.00 | - (3 overflowed) |"
	assert_line "|   n (got/attempted) | 3/3 | 0/3 (baseline n 3/3) |"
	# P2/P3 keep their samples: an overflow is the source side's.
	assert_line "| P2 remote EDS (ms) | 50.00 | 50.00 (+0.0%) |"
	run --separate-stderr "$TUNING_CMP" --results-dir "$P"
	assert_output --regexp 'P1 local push \(ms\) +100\.00 +- \(3 overflowed\)'
	run "$TUNING_CMP" --help
	assert_output --partial '("- (N overflowed)" when every one did)'
}

@test "help: every sweep's exit 4 and every report's outcome paragraph name the generation change and a failed end-of-sweep check, with no internal tags" {
	local s out flat
	# flat: the help on one line (its text is wrapped).
	for s in dataplane/003-run-sweep.sh churn/003-run-sweep.sh propagation/006-run-sweep.sh churn-dataplane/004-run-sweep.sh; do
		out="$("${ROOT}/tests/${s}" --help)"
		flat="$(tr -s ' \n' '  ' <<<"$out")"
		[[ "$flat" == *"generation of the Istio CR or its active IstioRevision changed"* && "$flat" == *"end-of-sweep check failed"* ]] \
			|| { echo "${s}: ${out}"; false; }
	done
	for s in dataplane/004-report-results.sh churn/004-report-results.sh churn-dataplane/005-report-results.sh propagation/005-report-results.sh tuning/004-compare-profiles.sh; do
		out="$("${ROOT}/tests/${s}" --help)"
		flat="$(tr -s ' \n' '  ' <<<"$out")"
		[[ "$flat" == *"generation of the Istio CR or its active IstioRevision"* && "$flat" == *"end-of-sweep check failed"* ]] \
			|| { echo "${s}: ${out}"; false; }
		# No review tag (PL17 ...) and no line over 100 columns.
		! grep -E '\((I|B|A)[0-9]+\)|\bPL[0-9]+\b' <<<"$out" || { echo "${s}: a tag"; false; }
		! awk 'length > 100 { print; bad = 1 } END { exit !bad }' <<<"$out" || { echo "${s}: a long line"; false; }
	done
}

#!/usr/bin/env bats
# Controlplane 004's verdict and provenance, through the entrypoint (PL33; fixture TSVs, no
# cluster): a window that ran on fewer istiod pods than its member's Deployment wants
# (WINDOW_ROWS <n>/<spec>) turns a PASS into CAUTION, while a line without /<spec> below the
# preamble's replicas is a warning only; a cell cut short while its member rows were written
# (INCOMPLETE: rows of fewer members than its mesh size, or in a TSV without WINDOW_ROWS a
# member with fewer rows than its istiod replicas) turns a PASS into CAUTION, but never in
# a standalone 002 run; a sweep outcome that is not clean, in any input dir, turns a PASS
# into CAUTION; the scaling json escapes a quote and a backslash; a row cut short is no row
# (its cell INCOMPLETE); and inputs of several Istio versions turn a PASS into CAUTION,
# while several harnesses only warn.

bats_require_minimum_version 1.5.0
load test_helper

REPORT="${ROOT}/tests/controlplane/004-report-results.sh"
FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"
GROWTH="${ROOT}/tests/lib/test/fixtures/controlplane_ns_growth.tsv"

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
	TSV="${RES}/controlplane-fixture-t2.tsv"
}

# cp_tsv <file> <second WINDOW_ROWS> <mesh-b rows in it>: the fixture's preamble (plus
# ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=3,mesh-b=3) and two cells (15 and 30 services) of valid
# rows, each member 3 rows a window (mesh-b <n> in the second).
cp_tsv() {
	awk -F'\t' -v OFS='\t' -v w2="$2" -v nb="$3" '
	function row(at, s, m, n,    i) { for (i = 1; i <= n; i++) { $0 = t; $1 = "2026-06-01T" at ":00+00:00"; $2 = m; $4 = s; $31 = 0; print } }
	/^#/ {
		print
		if (index($0, "# ISTIOD_REPLICAS=") == 1) print "# ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=3,mesh-b=3"
		next
	}
	$1 == "timestamp" { print; next }
	t == "" { t = $0 }
	END {
		print "# WINDOW_ROWS=mesh-a=3/3,mesh-b=3/3"; row("00:00", 15, "mesh-a", 3); row("00:00", 15, "mesh-b", 3)
		print "# WINDOW_ROWS=" w2; row("00:10", 30, "mesh-a", 3); row("00:10", 30, "mesh-b", nb)
	}' "$FIXTURE" > "$1"
}

# no_window_rows <file>: <file> without its WINDOW_ROWS lines (an older harness).
no_window_rows() {
	sed '/^# WINDOW_ROWS=/d' "$1" > "${1}.new"
	mv "${1}.new" "$1"
}

# pooled <base>: two sweep dirs under <base>, run-a and run-b, each a cp_tsv of valid rows.
pooled() {
	local s
	for s in a b; do
		mkdir -p "${1}/sweep-${s}"
		cp_tsv "${1}/sweep-${s}/controlplane-run-${s}.tsv" "mesh-a=3/3,mesh-b=3/3" 3
		sed "s/^# RUN_ID=.*/# RUN_ID=run-${s}/" "${1}/sweep-${s}/controlplane-run-${s}.tsv" > "${1}/sweep-${s}/x"
		mv "${1}/sweep-${s}/x" "${1}/sweep-${s}/controlplane-run-${s}.tsv"
	done
}

# set_key <file> <KEY> <value>: the preamble's "# KEY=" line set to <value>.
set_key() {
	sed "s|^# ${2}=.*|# ${2}=${3}|" "$1" > "${1}.new"
	mv "${1}.new" "$1"
}

# report <format> [dir] [flag...]: 004 over res/ (or dir), its stderr apart.
report() {
	local fmt="$1" dir="${2:-$RES}"
	(($# < 2)) || shift
	shift
	run --separate-stderr "$REPORT" --results-dir "$dir" --format "$fmt" "$@"
	assert_success
}

verdict() { jq -r '.metadata.sla.verdict' <<<"$output"; }
headline() { jq -r '.metadata.sla.headline' <<<"$output"; }

@test "a window that ran on fewer istiod pods than its member's Deployment wants (<n>/<spec>) is valid but turns PASS into CAUTION, with a data warning in every format; <n> at <spec> is PASS; fewer rows than <n> stays INCOMPLETE" {
	local w h
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=2/3" 2
	report json
	[ "$(verdict)" = CAUTION ]
	h="1 cell(s) ran on fewer istiod pods than their member's istiod Deployment wants (a replica evicted or Pending), so their per-replica figures are not comparable with the other cells; the figures: peak utilization"
	[[ "$(headline)" == "${h}"* ]]
	w="1 cell(s) ran on fewer istiod pods than their member's istiod Deployment wants (its .spec.replicas at the window's baseline: a replica evicted, or Pending), so their per-replica figures are not comparable with the other cells; the rows are valid measurements of the pods that ran: mesh=2 svcs=30 reps=2 ns=1 scope=none traffic=none (mesh-b ran 2 of its 3 istiod replicas)."
	# The only data warning: the cell is not INCOMPLETE.
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = "$(jq -cn --arg w "$w" '[$w]')" ]
	[[ "$stderr" == *"WARNING: ${w}"* ]]
	report text
	assert_output --partial "# WARNING: ${w}"
	assert_output --partial "Customer SLA verdict: CAUTION — ${h}"
	report csv
	assert_output --partial "# WARNING: ${w}"
	assert_output --partial "# sla_verdict: CAUTION — ${h}"
	report markdown
	assert_output --partial "> **Warning:** ${w}"
	assert_output --partial "**Customer SLA verdict: CAUTION** — ${h}"
	# The Deployment wanted 2 at that window's baseline: the window ran what it wanted.
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=2/2" 2
	report json
	[ "$(verdict)" = PASS ]
	# The window wrote 3 rows for mesh-b and the TSV holds 2: cut short, as before /<spec>.
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=3/3" 2
	report json
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "1 cell(s) are INCOMPLETE "* ]]
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == *"(mesh-b has 2 of the 3 rows its window wrote)"* ]]
	[ "$(jq -r '.metadata.data_warnings | length' <<<"$output")" = 1 ]
}

@test "a WINDOW_ROWS line without /<spec> (an older harness) below the member's ISTIOD_REPLICAS_BY_CONTEXT is a data warning only; a growth window's own line is read too" {
	local g="${BATS_TEST_TMPDIR}/grow"
	cp_tsv "$TSV" "mesh-a=3,mesh-b=2" 2
	report json
	[ "$(verdict)" = PASS ]
	[ "$(jq -r '.metadata.data_warnings | length' <<<"$output")" = 1 ]
	[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" = "1 cell(s) have fewer rows for a member than its istiod replicas at the sweep's start (ISTIOD_REPLICAS_BY_CONTEXT): mesh=2 svcs=30 reps=2 ns=1 scope=none traffic=none (mesh-b ran 2 of its 3 istiod replicas). Their WINDOW_ROWS lines do not record the replicas the Deployment wanted then (an older harness, or 002 could not read the Deployment), so this is a replica evicted or Pending, or an HPA or a rollout that changed the replicas during the sweep; it does not change the verdict." ]
	# A growth series' first window ran 1 of the 2 istiod pods its Deployment wanted.
	mkdir -p "$g"
	awk '!/^#/ && $1 != "timestamp" && !d++ { print "# WINDOW_ROWS=mesh-a=1/2" } { print }' "$GROWTH" > "${g}/controlplane-fixture-ns.tsv"
	report json "$g"
	[[ "$(jq -r '.metadata.data_warnings[]' <<<"$output")" == *"the rows are valid measurements of the pods that ran: mesh=1 svcs=200 reps=1 ns=100 scope=namespace traffic=none window=grow (mesh-a ran 1 of its 2 istiod replicas)."* ]]
	# The fixture's verdict is FAIL (a restart): the cell adds itself to the headline.
	[ "$(verdict)" = FAIL ]
	[[ "$(headline)" == *"; also 1 cell(s) ran on fewer istiod pods than their member's istiod Deployment wants"* ]]
	cp "$GROWTH" "${g}/controlplane-fixture-ns.tsv"
	report json "$g"
	[[ "$(jq -r '.metadata.data_warnings[]' <<<"$output")" != *"fewer istiod pods"* ]]
}

@test "a cell cut short while its member rows were written is INCOMPLETE (rows of fewer members than its mesh size; in a TSV without WINDOW_ROWS, a member with fewer rows than its istiod replicas in the cell written last): a data warning in every format, CAUTION; a standalone 002 run is never INCOMPLETE" {
	local fmt s2="${BATS_TEST_TMPDIR}/standalone"
	# The second cell has rows of mesh-a only (an older harness: no WINDOW_ROWS lines).
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=3/3" 0
	no_window_rows "$TSV"
	report json
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "1 cell(s) are INCOMPLETE (rows of fewer members than their mesh size"* ]]
	[ "$(jq -r '.metadata.data_warnings | length' <<<"$output")" = 1 ]
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == "1 cell(s) are INCOMPLETE: the sweep was cut short while their member rows were written "*": mesh=2 svcs=30 reps=2 ns=1 scope=none traffic=none (rows of 1 of 2 members)."* ]]
	for fmt in text markdown csv charts; do
		report "$fmt"
		[[ "$output" == *"1 cell(s) are INCOMPLETE: the sweep was cut short while their member rows were written"*"traffic=none (rows of 1 of 2 members)"* ]] || { echo "${fmt}: ${output}"; false; }
	done
	# mesh-b wrote 2 rows in the cell written last, 3 (its istiod replicas) in the first.
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=3/3" 2
	no_window_rows "$TSV"
	report json
	[ "$(verdict)" = CAUTION ]
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == *": mesh=2 svcs=30 reps=2 ns=1 scope=none traffic=none (mesh-b has rows of 2 of its 3 istiod replicas)."* ]]
	# The same rows from a standalone 002 run (PHASE is not sweep) are no sweep's cells.
	mkdir -p "$s2"
	cp "$TSV" "${s2}/${TSV##*/}"
	set_key "${s2}/${TSV##*/}" PHASE final
	report json "$s2"
	[ "$(verdict)" = PASS ]
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = '[]' ]
}

@test "a sweep outcome that is not clean turns PASS into CAUTION, one rule named in the headline: a record still running, interrupted or stopped, a failed cell, a PROBLEM; a NOTE stays PASS; a pooled report names each record" {
	local base="${BATS_TEST_TMPDIR}/base" h="the sweep outcome is not clean (" st
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=3/3" 3
	for st in running interrupted stopped; do
		printf 'STATUS=%s\nRUN_ID=fixture-t2\n' "$st" > "${RES}/sweep-outcome.txt"
		report json
		[ "$(verdict)" = CAUTION ]
		[[ "$(headline)" == "${h}res: ${st}: see sweep-outcome.txt), so the figures may not cover or measure what they seem to; the figures: "* ]]
	done
	printf 'STATUS=finished\nTOTAL=2\nFAILED=1\nFAILED_BY=INCOMPLETE x1\n' > "${RES}/sweep-outcome.txt"
	report json
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "${h}res: finished, 1 failed: see sweep-outcome.txt)"* ]]
	printf 'STATUS=finished\nTOTAL=2\nFAILED=0\nPROBLEM=istiod restarted during the sweep (bats)\n' > "${RES}/sweep-outcome.txt"
	report json
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "${h}res: finished, 1 problem(s): see sweep-outcome.txt)"* ]]
	report text
	assert_output --partial "Customer SLA verdict: CAUTION — ${h}res: finished, 1 problem(s): see sweep-outcome.txt)"
	# A note is a caveat, not a failure.
	printf 'STATUS=finished\nTOTAL=2\nFAILED=0\nNOTE=a member was not ready at the start (bats)\n' > "${RES}/sweep-outcome.txt"
	report json
	[ "$(verdict)" = PASS ]
	# Pooled sweeps: the headline names each record that is not clean.
	pooled "$base"
	printf 'STATUS=finished\nTOTAL=2\nFAILED=0\nPROBLEM=a (bats)\n' > "${base}/sweep-a/sweep-outcome.txt"
	printf 'STATUS=running\n' > "${base}/sweep-b/sweep-outcome.txt"
	report json "$base" --allow-multi-run
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "${h}sweep-a: finished, 1 problem(s); sweep-b: running: see sweep-outcome.txt)"* ]]
	[ "$(jq -c '[.sweep_outcomes[] | [.dir, .status]]' <<<"$output")" = '[["sweep-a","finished"],["sweep-b","running"]]' ]
}

@test "the namespace-scaling json escapes a quote and a backslash in a cell's scoping (JSON_STR_AWK js)" {
	awk -F'\t' -v OFS='\t' '!/^#/ && $1 != "timestamp" { $7 = "ex\"pl\\icit" } { print }' "$GROWTH" > "${RES}/controlplane-fixture-ns.tsv"
	report json
	[ "$(jq -r '.namespace_scaling.fits[0].scoping' <<<"$output")" = 'ex"pl\icit' ]
	[ "$(jq -r '.namespace_scaling.not_measured[0].scoping' <<<"$output")" = 'ex"pl\icit' ]
	[[ "$stderr" != *"namespace-scaling section failed"* ]]
}

@test "a row cut short (fewer columns than the header, at least 40) is not a row: its cell is INCOMPLETE, its columns read as no figure" {
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=3/3" 3
	awk -F'\t' -v OFS='\t' -v last="$(wc -l < "$TSV")" 'NR == last { NF = 42 } { print }' "$TSV" > "${TSV}.cut"
	mv "${TSV}.cut" "$TSV"
	[ "$(awk -F'\t' 'END { print NF }' "$TSV")" = 42 ]
	report json
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "1 cell(s) are INCOMPLETE "* ]]
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == *"svcs=30 "*"(mesh-b has 2 of the 3 rows its window wrote)"* ]]
	[ "$(jq -r '.metadata.data_warnings | length' <<<"$output")" = 1 ]
}

@test "inputs of different Istio versions turn PASS into CAUTION and name the versions; different harnesses alone warn in every format, without a verdict change" {
	local base="${BATS_TEST_TMPDIR}/base" w
	pooled "$base"
	set_key "${base}/sweep-a/controlplane-run-a.tsv" ISTIO_VERSION 1.30.5
	set_key "${base}/sweep-b/controlplane-run-b.tsv" ISTIO_VERSION 1.30.6
	report json "$base" --allow-multi-run
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "the inputs were measured on different Istio versions (ISTIO_VERSION 1.30.5,1.30.6; see the provenance warning), so their cells may not be comparable; the figures: "* ]]
	[[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" == "The inputs were measured on different Istio versions (ISTIO_VERSION 1.30.5,1.30.6)"* ]]
	set_key "${base}/sweep-b/controlplane-run-b.tsv" ISTIO_VERSION 1.30.5
	report json "$base" --allow-multi-run
	[ "$(verdict)" = PASS ]
	[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" = null ]
	# One Istio version, two harnesses: a warning, still PASS.
	set_key "${base}/sweep-b/controlplane-run-b.tsv" HARNESS_SHA abc1234-dirty
	w="The inputs ran on different harnesses (HARNESS_SHA fixture,abc1234-dirty), so their cells may not be measured the same way."
	report json "$base" --allow-multi-run
	[ "$(verdict)" = PASS ]
	[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" = "$w" ]
	[ "$(jq -r '.metadata.harness_sha' <<<"$output")" = "mixed:fixture,abc1234-dirty" ]
	[[ "$stderr" == *"WARNING: ${w}"* ]]
	report text "$base" --allow-multi-run
	assert_line "# WARNING: ${w}"
	report csv "$base" --allow-multi-run
	assert_line "# WARNING: ${w}"
	report markdown "$base" --allow-multi-run
	assert_line "> **Warning:** ${w}"
}

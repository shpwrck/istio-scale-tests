#!/usr/bin/env bats
# Controlplane 004's verdict and provenance, through the entrypoint (PL33; fixture TSVs, no
# cluster): rows in the figures from more than one harness turn a PASS into CAUTION
# whatever the sweep outcome records; so does a window that ran on fewer istiod pods than
# its member's Deployment wants (WINDOW_ROWS <n>/<spec>), while a line without /<spec>
# below the preamble's replicas is a warning only; the "could not count the sweep's cells"
# PROBLEM is not counted; a pooled report counts each pooled sweep's outcome and names it;
# HARNESS_CONTENT_KEY in every format and the envelope; each attempt's rows in text, csv
# and markdown, its time in Z form; the scaling json escapes a quote and a backslash; a row
# cut short is no row (its cell INCOMPLETE); and inputs of several Istio versions, or rows
# of a run that recorded no harness, turn a PASS into CAUTION.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/envelope.sh"

REPORT="${ROOT}/tests/controlplane/004-report-results.sh"
FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"
GROWTH="${ROOT}/tests/lib/test/fixtures/controlplane_ns_growth.tsv"

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
	TSV="${RES}/controlplane-fixture-t2.tsv"
}

# cp_tsv <file> <second WINDOW_ROWS> <mesh-b rows in it> [line before it]: the fixture's
# preamble (plus HARNESS_CONTENT_KEY=111111111111 and ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=3,
# mesh-b=3) and two cells (15 and 30 services) of valid rows, each member 3 rows a window
# (mesh-b <n> in the second). "TSV_LINES=@" in the line reads the TSV's lines before it.
cp_tsv() {
	awk -F'\t' -v OFS='\t' -v w2="$2" -v nb="$3" -v x="${4:-}" '
	function row(at, s, m, n,    i) { for (i = 1; i <= n; i++) { $0 = t; $1 = "2026-06-01T" at ":00+00:00"; $2 = m; $4 = s; $31 = 0; print } }
	/^#/ {
		print
		if (index($0, "# HARNESS_SHA=") == 1) print "# HARNESS_CONTENT_KEY=111111111111"
		if (index($0, "# ISTIOD_REPLICAS=") == 1) print "# ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=3,mesh-b=3"
		next
	}
	$1 == "timestamp" { print; next }
	t == "" { t = $0 }
	END {
		print "# WINDOW_ROWS=mesh-a=3/3,mesh-b=3/3"; row("00:00", 15, "mesh-a", 3); row("00:00", 15, "mesh-b", 3)
		if (x != "") print x
		print "# WINDOW_ROWS=" w2; row("00:10", 30, "mesh-a", 3); row("00:10", 30, "mesh-b", nb)
	}' "$FIXTURE" | awk '{ sub(/TSV_LINES=@/, "TSV_LINES=" (NR - 1)); print }' > "$1"
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
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = '[]' ]
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
	[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" = "1 cell(s) have fewer rows for a member than its istiod replicas at the sweep's start (ISTIOD_REPLICAS_BY_CONTEXT): mesh=2 svcs=30 reps=2 ns=1 scope=none traffic=none (mesh-b ran 2 of its 3 istiod replicas). Their WINDOW_ROWS lines do not record the replicas the Deployment wanted then (an older harness), so this is a replica evicted or Pending, or an HPA or a rollout that changed the replicas during the sweep; it does not change the verdict." ]
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

@test "rows in the figures from two harnesses turn PASS into CAUTION with no outcome record, a finished one without the PROBLEM and an interrupted one (a NOTE); a change of git describe alone stays PASS" {
	local h
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=3/3" 3 "# HARNESS_CHANGED_AT=2026-06-01T00:05:00Z HARNESS_SHA=other99 HARNESS_CONTENT_KEY=222222222222"
	h="the rows in the figures ran on more than one harness (HARNESS_SHA fixture,other99; see the provenance warning), so their cells may not be measured the same way; the figures: peak utilization"
	# A copied TSV: no outcome record.
	report json
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "${h}"* ]]
	[[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" == "The inputs ran on different harnesses (HARNESS_SHA fixture,other99; the harness changed during a run (HARNESS_CHANGED_AT), see the attempts)"* ]]
	# A finished sweep whose own reads missed the change (no PROBLEM).
	printf 'RUN_ID=fixture-t2\nEXIT=0\nUNIT=cells\nTOTAL=2\n' > "${RES}/sweep-outcome.txt"
	report json
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "${h}"* ]]
	# An interrupted sweep: its exit trap records the change as a NOTE.
	printf 'RUN_ID=fixture-t2\nEXIT=unfinished\nUNIT=cells\nNOTE=the harness changed during the sweep (bats)\n' > "${RES}/sweep-outcome.txt"
	report json
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "${h}"* ]]
	# The PROBLEM as well: the headline names both.
	printf 'RUN_ID=fixture-t2\nEXIT=4\nUNIT=cells\nTOTAL=2\nPROBLEM=the harness changed during the sweep (bats)\n' > "${RES}/sweep-outcome.txt"
	report json
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "the sweep outcome records 1 PROBLEM(s) (sweep-outcome.txt), so the figures may not measure what they seem to; the figures: "*"; also the rows in the figures ran on more than one harness (HARNESS_SHA fixture,other99; see the provenance warning), so their cells may not be measured the same way" ]]
	# Another git describe of the same harness files: one harness.
	rm -f "${RES}/sweep-outcome.txt"
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=3/3" 3 "# HARNESS_CHANGED_AT=2026-06-01T00:05:00Z HARNESS_SHA=v9.9.9-tag HARNESS_CONTENT_KEY=111111111111"
	report json
	[ "$(verdict)" = PASS ]
	[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" = null ]
}

@test "a 'could not count the sweep's cells' PROBLEM is not counted (the report counts the cells itself, as the sweep's own pages do); another PROBLEM is" {
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=3/3" 3
	printf "RUN_ID=fixture-t2\nEXIT=4\nUNIT=cells\nTOTAL=unknown\nPROBLEM=could not count the sweep's cells: no TSV (bats)\n" > "${RES}/sweep-outcome.txt"
	report json
	[ "$(verdict)" = PASS ]
	printf 'PROBLEM=istiod restarted during the sweep (bats)\n' >> "${RES}/sweep-outcome.txt"
	report json
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "the sweep outcome records 1 PROBLEM(s) (sweep-outcome.txt), so the figures"* ]]
}

@test "a pooled report counts the PROBLEMs of each pooled sweep's outcome and names each record; one dir names the record before an unfinished one" {
	local base="${BATS_TEST_TMPDIR}/base" s
	for s in a b; do
		mkdir -p "${base}/sweep-${s}"
		cp_tsv "${base}/sweep-${s}/controlplane-run-${s}.tsv" "mesh-a=3/3,mesh-b=3/3" 3
		sed -i.bak "s/^# RUN_ID=.*/# RUN_ID=run-${s}/" "${base}/sweep-${s}/controlplane-run-${s}.tsv"
		rm -f "${base}/sweep-${s}/controlplane-run-${s}.tsv.bak"
	done
	report json "$base" --allow-multi-run
	[ "$(verdict)" = PASS ]
	printf 'RUN_ID=run-a\nEXIT=4\nPROBLEM=a\n' > "${base}/sweep-a/sweep-outcome.txt"
	# sweep-b: a --resume running (unfinished), the outcome before it ended with two.
	printf 'RUN_ID=run-b\nEXIT=unfinished\nPROBLEM=b\n' > "${base}/sweep-b/sweep-outcome.txt"
	printf "RUN_ID=run-b\nEXIT=4\nPROBLEM=c\nPROBLEM=could not count the sweep's cells: (bats)\n" > "${base}/sweep-b/sweep-outcome.prev.txt"
	report json "$base" --allow-multi-run
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "the sweep outcome records 3 PROBLEM(s) (sweep-a/sweep-outcome.txt: 1; sweep-b/sweep-outcome.txt, and .prev.txt before it: 2), so the figures"* ]]
	# One sweep alone: its record, and the one before it.
	report json "${base}/sweep-b"
	[[ "$(headline)" == "the sweep outcome records 2 PROBLEM(s) (sweep-outcome.txt, and .prev.txt before it), so the figures"* ]]
	report json "${base}/sweep-a"
	[[ "$(headline)" == "the sweep outcome records 1 PROBLEM(s) (sweep-outcome.txt), so the figures"* ]]
}

@test "HARNESS_CONTENT_KEY in every format and the envelope (mixed:<list> for several); each attempt's rows in text, csv and markdown; a --resume's time in Z form" {
	local att mixed="mixed:111111111111,222222222222"
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=3/3" 3 "# RESUMED_AT=2026-06-01T00:05:00+00:00 TSV_LINES=@ HARNESS_SHA=fixture HARNESS_CONTENT_KEY=111111111111 ISTIO_NOTREADY_AT_RESUME=none ISTIO_GENERATIONS=mesh-a=1/1 ISTIO_PROXY_VERSIONS=mesh-a=1.30.5 KUBE_VERSIONS=mesh-a=v1.34.8"
	report json
	[ "$(jq -c '.metadata | [.harness_content_key, .harness_content_keys]' <<<"$output")" = '["111111111111",["111111111111"]]' ]
	[ "$(jq -c '[.metadata.attempts[] | [.run, .rows, .rows_kept, .started_at]]' <<<"$output")" = '[["first run",6,6,"unknown"],["--resume at 2026-06-01T00:05:00Z",6,6,"2026-06-01T00:05:00Z"]]' ]
	att="the rows come from more than one run: the first run (the HARNESS_SHA and KUBE_VERSIONS of the TSV preamble) (6 row(s), 6 in the figures), then --resume at 2026-06-01T00:05:00Z HARNESS_SHA=fixture KUBE_VERSIONS=mesh-a=v1.34.8 (6 row(s), 6 in the figures)"
	report text
	assert_output --partial "  HARNESS_SHA=fixture  HARNESS_CONTENT_KEY=111111111111  "
	assert_output --partial "  harness_shas=fixture  harness_content_keys=111111111111  "
	assert_output --partial "# attempts: ${att}"
	report csv
	assert_line "# HARNESS_CONTENT_KEY=111111111111"
	assert_output --partial "# attempts: ${att}"
	report markdown
	assert_line 'harness_content_key: "111111111111"'
	assert_line 'harness_content_keys: ["111111111111"]'
	assert_output --partial "> **Attempts:** ${att}"
	report charts
	assert_line 'harness_content_key: "111111111111"'
	run render_scale_envelope "$RES" "$REPORT" mesh-a,mesh-b false
	assert_success
	assert_output --partial "(harness \`fixture\`, HARNESS_CONTENT_KEY \`111111111111\`; report harness "
	assert_output --partial "> **Attempts:** first run HARNESS_SHA=fixture (6 row(s), 6 in the figures); --resume at 2026-06-01T00:05:00Z HARNESS_SHA=fixture (6 row(s), 6 in the figures)"
	# Rows of two harnesses: mixed.
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=3/3" 3 "# HARNESS_CHANGED_AT=2026-06-01T00:05:00Z HARNESS_SHA=other99 HARNESS_CONTENT_KEY=222222222222"
	report json
	[ "$(jq -c '.metadata | [.harness_content_key, .harness_content_keys]' <<<"$output")" = "[\"${mixed}\",[\"111111111111\",\"222222222222\"]]" ]
	report text
	assert_output --partial "  HARNESS_CONTENT_KEY=${mixed}  "
	report csv
	assert_line "# HARNESS_CONTENT_KEY=${mixed}"
	report markdown
	assert_line "harness_content_key: \"${mixed}\""
	run render_scale_envelope "$RES" "$REPORT" mesh-a,mesh-b false
	assert_success
	assert_output --partial "HARNESS_CONTENT_KEY \`${mixed}\`"
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

@test "a report whose inputs ran different Istio versions turns PASS into CAUTION and names the versions; one version stays PASS" {
	local base="${BATS_TEST_TMPDIR}/base" s v
	for s in a b; do
		v=1.30.5
		[ "$s" = a ] || v=1.30.6
		mkdir -p "${base}/sweep-${s}"
		cp_tsv "${base}/sweep-${s}/controlplane-run-${s}.tsv" "mesh-a=3/3,mesh-b=3/3" 3
		sed -i.bak -e "s/^# RUN_ID=.*/# RUN_ID=run-${s}/" -e "s/^# ISTIO_VERSION=.*/# ISTIO_VERSION=${v}/" "${base}/sweep-${s}/controlplane-run-${s}.tsv"
		rm -f "${base}/sweep-${s}/controlplane-run-${s}.tsv.bak"
	done
	report json "$base" --allow-multi-run
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "the inputs were measured on different Istio versions (ISTIO_VERSION 1.30.5,1.30.6; see the provenance warning), so their cells may not be comparable; the figures: "* ]]
	[[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" == "The inputs were measured on different Istio versions (ISTIO_VERSION 1.30.5,1.30.6)"* ]]
	sed -i.bak 's/^# ISTIO_VERSION=.*/# ISTIO_VERSION=1.30.5/' "${base}/sweep-b/controlplane-run-b.tsv"
	report json "$base" --allow-multi-run
	[ "$(verdict)" = PASS ]
}

@test "rows in the figures from a run that recorded neither HARNESS_SHA nor HARNESS_CONTENT_KEY turn PASS into CAUTION: they cannot be shown to come from one harness (003's rule for a carried harness PROBLEM)" {
	local h="a run whose rows are in the figures recorded neither HARNESS_SHA nor HARNESS_CONTENT_KEY (git could not name its harness, or an older harness did not record it), so the rows cannot be shown to come from one harness; the figures: "
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=3/3" 3
	sed -i.bak -e 's/^# HARNESS_SHA=.*/# HARNESS_SHA=unknown/' -e '/^# HARNESS_CONTENT_KEY=/d' "$TSV"
	report json
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "${h}"* ]]
	# No harness line at all (an older harness): the same.
	sed -i.bak '/^# HARNESS_SHA=/d' "$TSV"
	report json
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "${h}"* ]]
	# A known content key alone names the harness: PASS.
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=3/3" 3
	sed -i.bak 's/^# HARNESS_SHA=.*/# HARNESS_SHA=unknown/' "$TSV"
	report json
	[ "$(verdict)" = PASS ]
}

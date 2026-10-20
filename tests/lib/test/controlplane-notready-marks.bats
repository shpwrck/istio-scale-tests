#!/usr/bin/env bats
# Controlplane 004 on istiod pods that were not Ready, through its entrypoint (PL33; fixture
# TSVs, no cluster): a "# ISTIOD_NOT_READY_AT_END=" line (002 writes it after the
# baseline's "# ISTIOD_NOT_READY=" line, both right before the window's WINDOW_ROWS line)
# gives a data warning of its own, read from the cell's latest attempt only; a legacy cell
# with either line is marked where its figures are shown (a text block line, ¶ on the
# markdown cells table's n_total with one capped footnote, json istiod_not_ready and
# istiod_not_ready_at_end); a growth window gets the data warning only. Names are
# placeholders.

bats_require_minimum_version 1.5.0
load test_helper

REPORT="${ROOT}/tests/controlplane/004-report-results.sh"
FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"
GROWTH="${ROOT}/tests/lib/test/fixtures/controlplane_ns_growth.tsv"
NR_TAIL="A pod that is not Ready takes no new proxy connection, and one shutting down also drops its own as it exits (their reconnects to the other replicas add to the cell's push, convergence and CPU figures), so these cells' per-replica figures may include a replica that carried fewer proxies than the others, or none (its row's connected_proxies shows what it held at the window's end; a restarted replica's row is left out); it does not change the verdict."
END_HEAD="have an istiod pod that was not Ready at the window's end (a readiness probe failing under load, or a replica shutting down):"
END_TAIL="While not Ready it took no new proxy connection (one shutting down also drops its own as it exits, and their reconnects to the other replicas add to the cell's push, convergence and CPU figures), so these cells' per-replica figures may include a replica that carried fewer proxies than the others (a restarted replica's row is left out); it does not change the verdict."
FOOT="> ¶ istiod pod not Ready: an istiod pod of these cells was not Ready at a window's baseline or end, and took no new proxy connection while not Ready, so their per-replica figures may include a replica that carried fewer proxies than the others (see the data warnings):"

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
}

# cp_cells <file> <n> [<cell>=<lines>...]: the fixture's preamble (plus
# ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=3,mesh-b=3) and <n> cells (10, 20, ... services) of
# valid rows, each member 3 rows a window; the lines (\n-separated) given for cell <cell>
# (1-based) go right before its WINDOW_ROWS line.
cp_cells() {
	local f="$1" n="$2"
	shift 2
	awk -F'\t' -v OFS='\t' -v n="$n" -v xs="$(printf '%s\034' "$@")" '
	function row(s, m,    i) { for (i = 1; i <= 3; i++) { $0 = t; $2 = m; $4 = s; $31 = 0; print } }
	BEGIN { k = split(xs, a, "\034"); for (i = 1; i < k; i++) { j = index(a[i], "="); x[substr(a[i], 1, j - 1)] = substr(a[i], j + 1) } }
	/^#/ { print; if (index($0, "# ISTIOD_REPLICAS=") == 1) print "# ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=3,mesh-b=3"; next }
	$1 == "timestamp" { print; next }
	t == "" { t = $0 }
	END {
		for (c = 1; c <= n; c++) {
			if (c in x) print x[c]
			print "# WINDOW_ROWS=mesh-a=3/3,mesh-b=3/3"; row(10 * c, "mesh-a"); row(10 * c, "mesh-b")
		}
	}' "$FIXTURE" > "$f"
}

# report <format> <dir>: 004 over <dir>, its stderr apart.
report() {
	run --separate-stderr "$REPORT" --results-dir "$2" --format "$1"
	assert_success
}

# cell <svcs>: a cell's label.
cell() { printf 'mesh=2 svcs=%s reps=2 ns=1 scope=none traffic=none' "$1"; }

@test "004 reads the window-end line after the baseline line, and alone, right before WINDOW_ROWS: a data warning for each kind in every format; the verdict does not change" {
	local nw ew v
	cp_cells "${RES}/controlplane-fixture-t2.tsv" 3
	report json "$RES"
	v="$(jq -c '.metadata.sla' <<<"$output")"
	[ "$(jq -r '.metadata.sla.verdict' <<<"$output")" = PASS ]
	cp_cells "${RES}/controlplane-fixture-t2.tsv" 3 \
		"2=# ISTIOD_NOT_READY=mesh-b=istiod-x"$'\n'"# ISTIOD_NOT_READY_AT_END=mesh-b=istiod-y" \
		"3=# ISTIOD_NOT_READY_AT_END=mesh-a=istiod-z,mesh-b=istiod-y"
	nw="1 cell(s) have an istiod pod that was Running but not Ready at the window's baseline: $(cell 20) (istiod-x on mesh-b). ${NR_TAIL}"
	ew="2 cell(s) ${END_HEAD} $(cell 20) (istiod-y on mesh-b); $(cell 30) (istiod-z on mesh-a, istiod-y on mesh-b). ${END_TAIL}"
	report json "$RES"
	[ "$(jq -c '.metadata.sla' <<<"$output")" = "$v" ]
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = "$(jq -cn --arg a "$nw" --arg b "$ew" '[$a, $b]')" ]
	[[ "$stderr" == *"WARNING: ${ew}"* ]]
	report text "$RES"
	assert_line "# WARNING: ${nw}"
	assert_line "# WARNING: ${ew}"
	report csv "$RES"
	assert_line "# WARNING: ${ew}"
	report markdown "$RES"
	assert_line "> **Warning:** ${nw}"
	assert_line "> **Warning:** ${ew}"
}

@test "a legacy cell with a pod not Ready is marked where its figures are shown: text block lines, ¶ with one footnote, json per result; a cell without, nowhere" {
	cp_cells "${RES}/controlplane-fixture-t2.tsv" 3 \
		"2=# ISTIOD_NOT_READY=mesh-b=istiod-x"$'\n'"# ISTIOD_NOT_READY_AT_END=mesh-b=istiod-y" \
		"3=# ISTIOD_NOT_READY_AT_END=mesh-a=istiod-z,mesh-b=istiod-y"
	report text "$RES"
	assert_line "  ! NOT READY AT BASELINE: istiod-x on mesh-b (Running but not Ready: it took no new proxy connection while not Ready), so these per-replica figures may include a replica that carried fewer proxies than the others"
	assert_line "  ! NOT READY AT WINDOW END: istiod-y on mesh-b (a readiness probe failing under load, or a replica shutting down), so these per-replica figures may include a replica that carried fewer proxies than the others"
	assert_line "  ! NOT READY AT WINDOW END: istiod-z on mesh-a, istiod-y on mesh-b (a readiness probe failing under load, or a replica shutting down), so these per-replica figures may include a replica that carried fewer proxies than the others"
	# Each line sits in its own cell's block.
	[ "$(awk '/^--- / { s = $3 } /! NOT READY AT/ { print s ":" $5 }' <<<"$output" | tr '\n' ' ')" = "service_count=20:BASELINE: service_count=20:WINDOW service_count=30:WINDOW " ]
	report markdown "$RES"
	[ "$(grep -c '^| 2 | 10 | 2 | 1 | none | none | 6 |' <<<"$output")" -eq 1 ]
	[ "$(grep -c '^| 2 | [23]0 | 2 | 1 | none | none | 6 ¶ |' <<<"$output")" -eq 2 ]
	assert_line "${FOOT} $(cell 20) (at the baseline: istiod-x on mesh-b; at the window's end: istiod-y on mesh-b); $(cell 30) (at the window's end: istiod-z on mesh-a, istiod-y on mesh-b)."
	report json "$RES"
	[ "$(jq -c '[.results[] | [.service_count, .istiod_not_ready, .istiod_not_ready_at_end]]' <<<"$output")" = '[[10,[],[]],[20,["mesh-b=istiod-x"],["mesh-b=istiod-y"]],[30,[],["mesh-a=istiod-z","mesh-b=istiod-y"]]]' ]
}

@test "the ¶ footnote names up to five cells (then 'and N more'); every cell is marked" {
	local s="" i
	cp_cells "${RES}/controlplane-fixture-t2.tsv" 7 1="# ISTIOD_NOT_READY_AT_END=mesh-a=istiod-e" 2="# ISTIOD_NOT_READY_AT_END=mesh-a=istiod-e" \
		3="# ISTIOD_NOT_READY_AT_END=mesh-a=istiod-e" 4="# ISTIOD_NOT_READY_AT_END=mesh-a=istiod-e" 5="# ISTIOD_NOT_READY_AT_END=mesh-a=istiod-e" \
		6="# ISTIOD_NOT_READY_AT_END=mesh-a=istiod-e" 7="# ISTIOD_NOT_READY_AT_END=mesh-a=istiod-e"
	report markdown "$RES"
	[ "$(grep -c '^| 2 | [0-9]* | 2 | 1 | none | none | 6 ¶ |' <<<"$output")" -eq 7 ]
	for i in 1 2 3 4 5; do s+="${s:+; }$(cell $((10 * i))) (at the window's end: istiod-e on mesh-a)"; done
	assert_line "${FOOT} ${s}; and 2 more."
	report text "$RES"
	[ "$(grep -c '^  ! NOT READY AT WINDOW END: istiod-e on mesh-a ' <<<"$output")" -eq 7 ]
}

@test "only lines right before a WINDOW_ROWS line of the cell's latest attempt count; a growth window's end line gives the data warning, its json null" {
	local d="${BATS_TEST_TMPDIR}/r" g="${BATS_TEST_TMPDIR}/g" n rows
	mkdir -p "$d" "$g"
	# A baseline line with another line between it and the end line names nothing; the end
	# line still counts.
	cp_cells "${d}/controlplane-fixture-t2.tsv" 2 \
		"2=# ISTIOD_NOT_READY=mesh-b=istiod-x"$'\n'"# NOTE=bats"$'\n'"# ISTIOD_NOT_READY_AT_END=mesh-b=istiod-y"
	report json "$d"
	[ "$(jq -r '.metadata.data_warnings | length' <<<"$output")" -eq 1 ]
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == "1 cell(s) ${END_HEAD} $(cell 20) (istiod-y on mesh-b). "* ]]
	[ "$(jq -c '[.results[] | .istiod_not_ready]' <<<"$output")" = '[[],[]]' ]
	# An end line not right before the WINDOW_ROWS line names nothing either.
	cp_cells "${d}/controlplane-fixture-t2.tsv" 2 "2=# ISTIOD_NOT_READY_AT_END=mesh-b=istiod-y"$'\n'"# NOTE=bats"
	report json "$d"
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = '[]' ]
	[ "$(jq -c '[.results[] | .istiod_not_ready_at_end]' <<<"$output")" = '[[],[]]' ]
	# The 20-service cell's first attempt had both lines; a --resume ran it again.
	cp_cells "${d}/controlplane-fixture-t2.tsv" 2 \
		"2=# ISTIOD_NOT_READY=mesh-b=istiod-x"$'\n'"# ISTIOD_NOT_READY_AT_END=mesh-b=istiod-y"
	n="$(wc -l < "${d}/controlplane-fixture-t2.tsv" | tr -d ' ')"
	rows="$(tail -n 6 "${d}/controlplane-fixture-t2.tsv")"
	{
		printf '# RESUMED_AT=2026-06-01T00:20:00+00:00 TSV_LINES=%s HARNESS_SHA=fixture KUBE_VERSIONS=mesh-a=v1.34.8,mesh-b=v1.34.8\n' "$n"
		printf '# WINDOW_ROWS=mesh-a=3/3,mesh-b=3/3\n%s\n' "$rows"
	} >> "${d}/controlplane-fixture-t2.tsv"
	report json "$d"
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = '[]' ]
	[ "$(jq -c '[.results[] | [.istiod_not_ready, .istiod_not_ready_at_end]]' <<<"$output")" = '[[[],[]],[[],[]]]' ]
	# A growth series' first window: the data warning names it; json has no per-cell list.
	awk '!/^#/ && $1 != "timestamp" && !d++ { print "# ISTIOD_NOT_READY_AT_END=mesh-a=istiod-g"; print "# WINDOW_ROWS=mesh-a=1/1" } { print }' "$GROWTH" > "${g}/controlplane-fixture-ns.tsv"
	report json "$g"
	[[ "$(jq -r '.metadata.data_warnings[]' <<<"$output")" == *"1 cell(s) ${END_HEAD} mesh=1 svcs=200 reps=1 ns=100 scope=namespace traffic=none window=grow (istiod-g on mesh-a). ${END_TAIL}"* ]]
	[ "$(jq -c '[.results[] | [.istiod_not_ready, .istiod_not_ready_at_end]] | unique' <<<"$output")" = '[[null,null]]' ]
}

@test "--help: both lines and what a pod not Ready does to the figures, the marks, 'up to five cells' and pooled_sweep_outcomes as each record is; within 100 columns" {
	local h
	run --separate-stderr "$REPORT" --help
	assert_success
	[ -z "$(awk 'length($0) > 100' <<<"$output")" ] || { awk 'length($0) > 100' <<<"$output"; false; }
	h="$(tr '\n' ' ' <<<"$output" | tr -s ' ')"
	[[ "$h" == *"an istiod pod that was Running but not Ready at a window's baseline (its \"# ISTIOD_NOT_READY=<member>=<pod>,...\" line), and one not Ready at the window's end (its \"# ISTIOD_NOT_READY_AT_END=\" line): a pod that is not Ready takes no new proxy connection, and one shutting down also drops its own as it exits (their reconnects to the other replicas add to the cell's push, convergence and CPU figures), so the per-replica figures may include a replica that carried fewer proxies than the others, or none (its row's connected_proxies shows what it held at the window's end; a restarted replica's row is left out)."* ]]
	[[ "$h" == *"a legacy cell with a pod not Ready in its text block (\"! NOT READY AT BASELINE: <pod> on <member>\", \"! NOT READY AT WINDOW END: ...\"), its n_total in the markdown cells table (¶, one footnote for both) and the json results' istiod_not_ready and istiod_not_ready_at_end (\"<member>=<pod>\" entries; [] when none, or the TSV's harness wrote no such line; null for a growth cell, whose windows only the data warning names). Each footnote names up to five cells (then \"and N more\")."* ]]
	[[ "$h" == *"each record as it is: the PROBLEMs of the sweep-outcome.prev.txt behind one that has not finished count in the verdict only."* ]]
}

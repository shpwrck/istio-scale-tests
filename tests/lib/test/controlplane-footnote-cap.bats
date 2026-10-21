#!/usr/bin/env bats
# Controlplane 004's markdown through its entrypoint (PL33; a fixture TSV, no cluster): the
# § (fewer istiod pods) and ‡ (INCOMPLETE) footnotes of the cells table name five cells,
# then "and N more", as the data warnings do (cell_list), while the table marks every cell.

bats_require_minimum_version 1.5.0
load test_helper

REPORT="${ROOT}/tests/controlplane/004-report-results.sh"
FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
}

# cp_cells <file> <n> <kind>: the fixture's preamble (plus
# ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=3,mesh-b=3) and <n> cells (10, 20, ... services), each
# a window of 3 mesh-a rows and 2 mesh-b rows: short (mesh-b ran 2 of its 3 istiod
# replicas, WINDOW_ROWS mesh-b=2/3) or cut (its window wrote 3 mesh-b rows: INCOMPLETE).
cp_cells() {
	awk -F'\t' -v OFS='\t' -v n="$2" -v kind="$3" '
	function row(s, m, k,    i) { for (i = 1; i <= k; i++) { $0 = t; $2 = m; $4 = s; $31 = 0; print } }
	/^#/ { print; if (index($0, "# ISTIOD_REPLICAS=") == 1) print "# ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=3,mesh-b=3"; next }
	$1 == "timestamp" { print; next }
	t == "" { t = $0 }
	END {
		for (c = 1; c <= n; c++) {
			print "# WINDOW_ROWS=mesh-a=3/3,mesh-b=" (kind == "short" ? "2/3" : "3/3")
			row(10 * c, "mesh-a", 3); row(10 * c, "mesh-b", 2)
		}
	}' "$FIXTURE" > "$1"
}

# cell <svcs>: a cell's label.
cell() { printf 'mesh=2 svcs=%s reps=2 ns=1 scope=none traffic=none' "$1"; }

@test "the § footnote names five cells, then 'and N more'; every cell is marked in the table; five or fewer, all of them" {
	local why="(mesh-b ran 2 of its 3 istiod replicas)" s=""
	cp_cells "${RES}/controlplane-fixture-t2.tsv" 7 short
	run --separate-stderr "$REPORT" --results-dir "$RES" --format markdown
	assert_success
	[ "$(grep -c '^| 2 | [0-9]* | 2 | 1 | none | none | 5 § |' <<<"$output")" -eq 7 ]
	for i in 1 2 3 4 5; do s+="${s:+; }$(cell $((10 * i))) ${why}"; done
	assert_line "> § Fewer istiod pods: these cells ran on fewer istiod pods than their member's istiod Deployment wanted (a replica evicted or Pending), so their per-replica figures are not comparable with the other cells; the rows are valid: ${s}; and 2 more."
	cp_cells "${RES}/controlplane-fixture-t2.tsv" 5 short
	run --separate-stderr "$REPORT" --results-dir "$RES" --format markdown
	assert_success
	assert_line "> § Fewer istiod pods: these cells ran on fewer istiod pods than their member's istiod Deployment wanted (a replica evicted or Pending), so their per-replica figures are not comparable with the other cells; the rows are valid: ${s}."
}

@test "the ‡ footnote names five INCOMPLETE cells, then 'and N more'; every cell is marked in the table" {
	local why="(mesh-b has 2 of the 3 rows its window wrote)" s=""
	cp_cells "${RES}/controlplane-fixture-t2.tsv" 6 cut
	run --separate-stderr "$REPORT" --results-dir "$RES" --format markdown
	assert_success
	[ "$(grep -c '^| 2 | [0-9]* | 2 | 1 | none | none | 5 ‡ |' <<<"$output")" -eq 6 ]
	for i in 1 2 3 4 5; do s+="${s:+; }$(cell $((10 * i))) ${why}"; done
	assert_line "> ‡ INCOMPLETE: the sweep was cut short while these cells' member rows were written, so their figures cover only the rows written (the sweep counts these cells as failed): ${s}; and 1 more."
}

@test "--help says each footnote names up to five cells (then 'and N more')" {
	run --separate-stderr "$REPORT" --help
	assert_success
	[[ "$(tr '\n' ' ' <<<"$output" | tr -s ' ')" == *"markdown cells table (§, with a footnote);"*" Each footnote names up to five cells (then \"and N more\")."* ]]
}

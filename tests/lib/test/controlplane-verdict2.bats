#!/usr/bin/env bats
# Controlplane 004 through its entrypoint (PL33; fixture TSVs, no cluster): a legacy cell
# that ran on fewer istiod pods than wanted is marked where its figures are shown (§ in the
# markdown cells table, its text block); a window whose istiod Deployment wanted another
# replica count than at the sweep's start is a data warning without a verdict change (a
# growth window's own line too); an entry without /<spec> names both causes; and --help
# names every provenance reason that turns a PASS into CAUTION.

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

# report <format> [dir]: 004 over res/ (or dir), its stderr apart.
report() {
	run --separate-stderr "$REPORT" --results-dir "${2:-$RES}" --format "$1"
	assert_success
}

verdict() { jq -r '.metadata.sla.verdict' <<<"$output"; }

@test "a legacy cell that ran on fewer istiod pods than wanted is marked in the markdown cells table (§, with a footnote) and in its text block; a cell that ran them all is not" {
	local cell="mesh=2 svcs=30 reps=2 ns=1 scope=none traffic=none"
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=2/3" 2
	report markdown
	assert_line --regexp '^\| 2 \| 30 \| 2 \| 1 \| none \| none \| 5 § \| 5 \|'
	assert_line --regexp '^\| 2 \| 15 \| 2 \| 1 \| none \| none \| 6 \| 6 \|'
	assert_line "> § Fewer istiod pods: these cells ran on fewer istiod pods than their member's istiod Deployment wanted (a replica evicted or Pending), so their per-replica figures are not comparable with the other cells; the rows are valid: ${cell} (mesh-b ran 2 of its 3 istiod replicas)."
	report text
	assert_line --partial "service_count=30 replicas=2 namespace_count=1 sidecar_scoping=none traffic_config=none (n_total=5 n_valid=5; FEWER ISTIOD PODS: mesh-b ran 2 of its 3 istiod replicas) ---"
	assert_line "  ! FEWER ISTIOD PODS: mesh-b ran 2 of its 3 istiod replicas (its istiod Deployment's .spec.replicas: a replica evicted or Pending), so these per-replica figures are not comparable with the other cells; the rows are valid"
	assert_line --partial "service_count=15 replicas=2 namespace_count=1 sidecar_scoping=none traffic_config=none (n_total=6 n_valid=6) ---"
	# Every pod it wanted ran: no mark, no footnote.
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=3/3" 3
	report markdown
	refute_output --partial "§"
	report text
	refute_output --partial "FEWER ISTIOD PODS"
}

@test "a window whose istiod Deployment wanted another replica count than at the sweep's start is a data warning in every format, without a verdict change; the start's count is none; a growth window's own line too" {
	local w g="${BATS_TEST_TMPDIR}/grow"
	w="1 cell(s) have a window whose member's istiod Deployment wanted another replica count than at the sweep's start (ISTIOD_REPLICAS_BY_CONTEXT): mesh=2 svcs=30 reps=2 ns=1 scope=none traffic=none (mesh-b wanted 2 istiod replicas, 3 at the sweep's start). An HPA, or a changed replicaCount: their per-replica figures are not comparable with the cells run at the start's count; it does not change the verdict."
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=2/2" 2
	report json
	[ "$(verdict)" = PASS ]
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = "$(jq -cn --arg w "$w" '[$w]')" ]
	[[ "$stderr" == *"WARNING: ${w}"* ]]
	report text
	assert_line "# WARNING: ${w}"
	report csv
	assert_line "# WARNING: ${w}"
	report markdown
	assert_line "> **Warning:** ${w}"
	# It did not run fewer pods than it wanted: no mark.
	refute_output --partial "§"
	# More than at the start is another count too.
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=4/4" 4
	report json
	[ "$(verdict)" = PASS ]
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == *"(mesh-b wanted 4 istiod replicas, 3 at the sweep's start)."* ]]
	# The start's count: nothing to say.
	cp_tsv "$TSV" "mesh-a=3/3,mesh-b=3/3" 3
	report json
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = '[]' ]
	# A growth series' first window wanted 2 istiod pods, 1 at the sweep's start, and ran both.
	mkdir -p "$g"
	awk '!/^#/ && $1 != "timestamp" && !d++ { print "# WINDOW_ROWS=mesh-a=2/2" } { print }' "$GROWTH" > "${g}/controlplane-fixture-ns.tsv"
	report json "$g"
	[[ "$(jq -r '.metadata.data_warnings[]' <<<"$output")" == *"(ISTIOD_REPLICAS_BY_CONTEXT): mesh=1 svcs=200 reps=1 ns=100 scope=namespace traffic=none window=grow (mesh-a wanted 2 istiod replicas, 1 at the sweep's start)."* ]]
	[[ "$(jq -r '.metadata.data_warnings[]' <<<"$output")" != *"fewer istiod pods"* ]]
	# The fixture's verdict (FAIL: a restart) does not name it.
	[ "$(verdict)" = FAIL ]
	[[ "$(jq -r '.metadata.sla.headline' <<<"$output")" != *"replica count"* ]]
}

@test "--help names every provenance reason that turns a PASS into CAUTION (a harness or Istio version mix, rows of a run that recorded no harness) and both causes of a WINDOW_ROWS entry without /<spec>, within 100 columns" {
	local h
	run --separate-stderr "$REPORT" --help
	assert_success
	[ -z "$(awk 'length($0) > 100' <<<"$output")" ] || { awk 'length($0) > 100' <<<"$output"; false; }
	h="$(tr '\n' ' ' <<<"$output" | tr -s ' ')"
	[[ "$h" == *"when Istio versions or harnesses differ it prints a WARNING, and a PASS verdict reads CAUTION"* ]]
	[[ "$h" == *"A mix of harnesses or of Istio versions prints a provenance warning and turns a PASS verdict into CAUTION, as do rows in the figures from a run that recorded neither HARNESS_SHA nor HARNESS_CONTENT_KEY (no git: run from a git checkout);"* ]]
	[[ "$h" == *"An entry without /<spec> (an older harness, or 002 could not read the Deployment)"* ]]
	[[ "$h" == *"So is a <spec> other than that start value (an HPA, or a changed replicaCount"* ]]
	[[ "$h" == *"its n_total in the markdown cells table (§, with a footnote)"* ]]
}

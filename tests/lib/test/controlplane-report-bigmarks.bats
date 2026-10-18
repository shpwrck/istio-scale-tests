#!/usr/bin/env bats
# Controlplane 004 through its entrypoint (PL33; fixture TSVs, no cluster) when its per-cell
# lists are large: Linux holds one environment string or argument (awk -v) to 128 KiB, so a
# list of marked cells, or of vsdr cells with an ingest shortfall, passed that way stops awk
# from starting (exit 126) and the report, and the sweep that runs it, with it. A 20-member
# sweep of 64 cells with long context names and a replica short on every member gets there.
# 004 reads them from files: every format exits 0 and marks every cell. Names are
# placeholders.

bats_require_minimum_version 1.5.0
load test_helper

REPORT="${ROOT}/tests/controlplane/004-report-results.sh"
FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"
VSDR="${ROOT}/tests/lib/test/fixtures/controlplane_vsdr.tsv"

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
	# One member with a 100-character context name.
	M="ci-a-$(printf 'x%.0s' {1..95})"
}

@test "marked-cell lists past 128 KiB (1,200 cells of a 100-character member, a replica short and not Ready at both ends): every format exits 0 and marks every cell" {
	local f
	awk -F'\t' -v OFS='\t' -v m="$M" '
	/^#/ { if (index($0, "# ISTIOD_REPLICAS=") == 1) { print "# ISTIOD_REPLICAS=2"; print "# ISTIOD_REPLICAS_BY_CONTEXT=" m "=2" } else print; next }
	$1 == "timestamp" { print; next }
	t == "" { t = $0 }
	END {
		for (c = 1; c <= 1200; c++) {
			print "# ISTIOD_NOT_READY=" m "=istiod-b"
			print "# ISTIOD_NOT_READY_AT_END=" m "=istiod-b"
			print "# WINDOW_ROWS=" m "=1/2"
			$0 = t; $2 = m; $3 = 1; $4 = c; $31 = 0; print
		}
	}' "$FIXTURE" > "${RES}/controlplane-fixture-t2.tsv"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format markdown
	assert_success
	[ "$(grep -c '^| 1 | [0-9]* | 2 | 1 | none | none | 1 § ¶ |' <<<"$output")" -eq 1200 ]
	assert_line --regexp '^> § Fewer istiod pods: .*; and 1195 more\.$'
	assert_line --regexp '^> ¶ istiod pod not Ready: .*; and 1195 more\.$'
	run --separate-stderr "$REPORT" --results-dir "$RES" --format text
	assert_success
	[ "$(grep -c "; FEWER ISTIOD PODS: ${M} ran 1 of its 2 istiod replicas) ---\$" <<<"$output")" -eq 1200 ]
	[ "$(grep -c "^  ! NOT READY AT BASELINE: istiod-b on ${M} " <<<"$output")" -eq 1200 ]
	[ "$(grep -c "^  ! NOT READY AT WINDOW END: istiod-b on ${M} " <<<"$output")" -eq 1200 ]
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -c --arg e "${M}=istiod-b" '[.results[] | select(.istiod_not_ready == [$e] and .istiod_not_ready_at_end == [$e])] | length' <<<"$output")" -eq 1200 ]
	for f in csv charts; do
		run --separate-stderr "$REPORT" --results-dir "$RES" --format "$f"
		assert_success
	done
}

@test "json reads the vsdr cells with an ingest shortfall from a file: past 128 KiB of their keys, each is flagged" {
	# 140 vsdr cells of one member (1-140 services), each with fewer istiod VirtualServices
	# (6) than it configured (10), keyed "mesh|svc|reps|ns|scoping": a 1,009-character
	# scoping value stands in for the ~7,700 cells of a forced matrix that reach 128 KiB of
	# keys with real values (the list's size is what counts, and 004 does not check it).
	awk -F'\t' -v OFS='\t' '
	/^#/ { print; next }
	$1 == "timestamp" { print; next }
	t == "" && $44 == "vsdr" { t = $0 }
	END { for (c = 1; c <= 140; c++) { $0 = t; $2 = "ci-a"; $3 = 1; $4 = c; $7 = "explicit-" sprintf("%01000d", 0); $45 = 10; $46 = 6; $31 = 0; print } }' \
		"$VSDR" > "${RES}/controlplane-vsdr.tsv"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq '[.results[] | select(.istiod_vs_ingest_short)] | length' <<<"$output")" -eq 140 ]
}

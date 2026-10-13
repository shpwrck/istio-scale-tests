#!/usr/bin/env bats
# End-to-end tests of tests/controlplane/004-report-results.sh (PL33: through the real
# entrypoint) against fixtures/controlplane_cluster_proxies.tsv.
#
# Fixture (one combo: mesh 2, 15 svc, 2 reps, 1 ns, scoping none; tolerance 10 %, min diff 2):
#   window 1  mesh-a 2 istiod pods 15+15 = 30, 30 sidecar pods -> OK
#             mesh-b 3 istiod pods 12+10+12 = 34, 34 sidecar pods -> OK
#   window 2  mesh-a 16+14 = 30, 40 sidecar pods -> LOW (|30-40| = 10 > max(4, 2))
#             mesh-b 10+17+9 = 36, 36 -> OK, but the 17 row has istiod_restarted=1, so the
#             whole cluster scrape is excluded (and the 17 row from the per-replica stats).
# The numbers are chosen so each rule changes a result if it breaks:
#   per-replica max 16 (17 if the restarted row leaks)
#   per-cluster max 34 (36 if the excluded scrape leaks)
#   per-cluster avg 31 = (30+34+30)/3, once per scrape (32 if ingested once per pod row)

bats_require_minimum_version 1.5.0
load test_helper

FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"
REPORT="${ROOT}/tests/controlplane/004-report-results.sh"

setup() {
	RES="${BATS_TEST_TMPDIR}/r"
	mkdir -p "$RES"
	cp "$FIXTURE" "${RES}/controlplane-fixture-t2.tsv"
}

# legacy40 <out>: the fixture as an older file would be: schema 40, no proxy-check keys,
# cols 1-40 only.
legacy40() {
	grep -v '^# PROXY_CHECK_' "$FIXTURE" \
		| sed 's/^# CONTROLPLANE_SCHEMA=43$/# CONTROLPLANE_SCHEMA=40/' \
		| cut -f1-40 > "$1"
}

@test "report json: per-replica vs per-cluster peaks and the proxy-check tally" {
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -r '.metadata.achieved_scale.connected_proxies_max' <<<"$output")" = "16" ]
	[ "$(jq -r '.metadata.achieved_scale.connected_proxies_cluster_max' <<<"$output")" = "34" ]
	[ "$(jq -c '.metadata.proxy_check | {tolerance_pct, min_diff, ok, low, high, na, excluded}' <<<"$output")" = \
		'{"tolerance_pct":"10","min_diff":"2","ok":2,"low":1,"high":0,"na":0,"excluded":1}' ]
	[ "$(jq -r '.metadata.proxy_check.flagged' <<<"$output")" = "mesh-a@2026-06-01T00:10:00+00:00:LOW:30/40" ]
	[ "$(jq -c '.results[0].connected_proxies_cluster' <<<"$output")" = '{"min":30,"max":34,"avg":31}' ]
	[ "$(jq -c '.results[0].connected_proxies' <<<"$output")" = '{"min":9,"max":16,"avg":13}' ]
	[ "$(jq -c '[.results[0].n_total, .results[0].n_valid]' <<<"$output")" = '[10,9]' ]
}

@test "report text: per-cluster peak, tally and a WARNING naming the cluster scrape" {
	run --separate-stderr "$REPORT" --results-dir "$RES" --format text
	assert_success
	assert_output --partial "connected_proxies per istiod replica (max): 16"
	assert_output --partial "connected_proxies per cluster (max): 34"
	assert_output --partial "(tolerance 10%, min diff 2): ok=2 low=1 high=0 n/a=0 excluded=1"
	assert_output --partial "WARNING: connected proxies differ from Running sidecar pods"
	assert_output --partial "mesh-a@2026-06-01T00:10:00+00:00:LOW:30/40"
	assert_output --partial "Connected proxies / cluster:        min=30 max=34 avg=31"
}

@test "report: no WARNING when every counted cluster scrape is OK; exit code unaffected" {
	f="${RES}/controlplane-fixture-t2.tsv"
	awk 'BEGIN { FS = OFS = "\t" } !/^#/ && $43 == "LOW" { $43 = "OK" } { print }' "$f" > "${f}.tmp"
	mv "${f}.tmp" "$f"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format text
	assert_success
	refute_output --partial "WARNING:"
	assert_output --partial "ok=3 low=0 high=0"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format markdown
	assert_success
	refute_output --partial "**Warning:**"
}

@test "report csv: rows gain cluster_proxies_* (37 columns) and a proxy_check comment" {
	run --separate-stderr "$REPORT" --results-dir "$RES" --format csv
	assert_success
	hdr=$(grep -v '^#' <<<"$output" | sed -n 1p)
	row=$(grep -v '^#' <<<"$output" | sed -n 2p)
	[ "$(awk -F, '{ print NF }' <<<"$hdr")" -eq 37 ]
	[[ "$hdr" == *",cluster_proxies_min,cluster_proxies_max,cluster_proxies_avg" ]]
	[[ "$row" == *",30,34,31" ]]
	assert_output --partial "# proxy_check: tolerance_pct=10 min_diff=2 ok=2 low=1 high=0 na=0 excluded=1"
	assert_output --partial "connected_proxies_cluster_max=34"
	assert_output --partial "# WARNING: connected proxies differ"
}

@test "report markdown: proxies/cluster column, achieved rows and a Warning note" {
	run --separate-stderr "$REPORT" --results-dir "$RES" --format markdown
	assert_success
	assert_output --partial "| proxies/replica | proxies/cluster |"
	assert_output --partial "| connected_proxies per cluster (max) | 34 |"
	assert_output --partial "> **Warning:** connected proxies differ"
	assert_output --partial 'proxy_check_tolerance_pct: "10"'
}

@test "envelope: per-cluster peak, per-replica peak and proxy check from the report JSON" {
	source "${ROOT}/tests/lib/capacity.sh"
	source "${ROOT}/tests/lib/envelope.sh"
	# `false` as the kubectl argv: the live reads degrade to unknown; only the
	# report-sourced rows are asserted.
	run --separate-stderr render_scale_envelope "$RES" "$REPORT" "mesh-a,mesh-b" false
	assert_success
	assert_output --partial "| **Connected proxies per cluster (measured peak)** | 34 |"
	assert_output --partial "| Connected proxies per istiod replica (peak) | 16 |"
	# n/a and excluded are shown, so the fixture's excluded scrape is not hidden.
	assert_output --partial "| Proxy check vs Running sidecar pods | ok=2 low=1 high=0 n/a=0 excluded=1 (tolerance 10%, min diff 2) |"
}

@test "report charts: still renders after the aggregate width change" {
	run --separate-stderr "$REPORT" --results-dir "$RES" --format charts
	assert_success
}

@test "report: a 40-column TSV feeds the old columns and adds nothing to the new keys" {
	# Named to sort FIRST, so the tolerance must not come from the first file only.
	legacy40 "${RES}/controlplane-a-legacy40.tsv"
	[ "$(grep -m1 '^timestamp' "${RES}/controlplane-a-legacy40.tsv" | awk -F'\t' '{ print NF }')" -eq 40 ]
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[[ "$stderr" == *"1 TSV file(s) use the 40-column schema"* ]]
	[ "$(jq -c '[.metadata.files_consumed, .metadata.skipped_legacy]' <<<"$output")" = '[2,0]' ]
	# Old columns: both files' rows are aggregated (n_total doubles).
	[ "$(jq -r '.results[0].n_total' <<<"$output")" = "20" ]
	# New keys: unchanged; the 40-column rows contribute nothing.
	[ "$(jq -r '.metadata.achieved_scale.connected_proxies_cluster_max' <<<"$output")" = "34" ]
	[ "$(jq -c '.metadata.proxy_check | {tolerance_pct, ok, low, high, na, excluded}' <<<"$output")" = \
		'{"tolerance_pct":"10","ok":2,"low":1,"high":0,"na":0,"excluded":1}' ]
	[ "$(jq -c '.results[0].connected_proxies_cluster' <<<"$output")" = '{"min":30,"max":34,"avg":31}' ]
}

@test "report: only 40-column files -> per-cluster keys unknown/null and no WARNING" {
	legacy40 "${RES}/controlplane-a-legacy40.tsv"
	rm -f "${RES}/controlplane-fixture-t2.tsv"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -r '.metadata.achieved_scale.connected_proxies_cluster_max' <<<"$output")" = "unknown" ]
	[ "$(jq -r '.metadata.proxy_check.tolerance_pct' <<<"$output")" = "unknown" ]
	[ "$(jq -c '.results[0].connected_proxies_cluster' <<<"$output")" = '{"min":null,"max":null,"avg":null}' ]
	run --separate-stderr "$REPORT" --results-dir "$RES" --format text
	assert_success
	refute_output --partial "WARNING:"
}

@test "report: a TSV of another width is skipped as legacy, with a warning" {
	cut -f1-34 "$FIXTURE" > "${RES}/controlplane-old34.tsv"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[[ "$stderr" == *"skipping 1 legacy TSV file(s)"* ]]
	[ "$(jq -r '.metadata.files_consumed' <<<"$output")" = "1" ]
}

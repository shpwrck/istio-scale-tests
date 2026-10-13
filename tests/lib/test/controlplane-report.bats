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
#
# VS/DR fixture fixtures/controlplane_vsdr.tsv (mesh 2, 10 svc, 2 reps, 1 ns; VSDR_EVERY 1,
# VSDR_SUBSETS 2), two base cells, each swept with traffic none and vsdr:
#   scoping none:     none VS 0, 30 clusters, 1 MiB dumps; vsdr VS 10, 50 clusters (+20 =
#                     10 svc x 2 subsets), plus a restarted vsdr row (mem 999, VS 3) that
#                     must stay out of the istiod aggregates (else VS avg 7.7 -> WARN).
#   scoping explicit: none 0.5 MiB dumps; vsdr VS 6 of 10 -> ingest WARN, and 1 MiB dumps
#                     that must stay out of the scoping-effect table (none->explicit 50.0%).
# Both fixtures are generated at 51 columns (CONTROLPLANE_SCHEMA=51).

bats_require_minimum_version 1.5.0
load test_helper

FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"
VSDR_FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_vsdr.tsv"
REPORT="${ROOT}/tests/controlplane/004-report-results.sh"

setup() {
	RES="${BATS_TEST_TMPDIR}/r"
	mkdir -p "$RES"
	cp "$FIXTURE" "${RES}/controlplane-fixture-t2.tsv"
}

# legacy40 <out>: the fixture as an older file would be: schema 40, no proxy-check or
# traffic keys, cols 1-40 only.
legacy40() {
	grep -vE '^# (PROXY_CHECK_|TRAFFIC_CONFIG=|VSDR_)' "$FIXTURE" \
		| sed 's/^# CONTROLPLANE_SCHEMA=51$/# CONTROLPLANE_SCHEMA=40/' \
		| cut -f1-40 > "$1"
}

# vsdr_dir: a results dir holding only the VS/DR fixture.
vsdr_dir() {
	VRES="${BATS_TEST_TMPDIR}/v"
	mkdir -p "$VRES"
	cp "$VSDR_FIXTURE" "${VRES}/controlplane-fixture-t6.tsv"
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

@test "report csv: rows gain cluster_proxies_* and the traffic columns (47) and a proxy_check comment" {
	run --separate-stderr "$REPORT" --results-dir "$RES" --format csv
	assert_success
	hdr=$(grep -v '^#' <<<"$output" | sed -n 1p)
	row=$(grep -v '^#' <<<"$output" | sed -n 2p)
	[ "$(awk -F, '{ print NF }' <<<"$hdr")" -eq 47 ]
	[[ "$hdr" == *",cluster_proxies_min,cluster_proxies_max,cluster_proxies_avg,traffic_config,vsdr_services,"* ]]
	[[ "$row" == *",30,34,31,none,0,"* ]]
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
	# Old columns: both files' rows are aggregated (n_total doubles), and the 40-column
	# rows join the traffic none cell.
	[ "$(jq -r '.results | length' <<<"$output")" = "1" ]
	[ "$(jq -r '.results[0].n_total' <<<"$output")" = "20" ]
	[ "$(jq -c '[.results[0].traffic_config, .results[0].vsdr_services]' <<<"$output")" = '["none",0]' ]
	[ "$(jq -r '.metadata.sweep.traffic_configs' <<<"$output")" = "none" ]
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
	[[ "$stderr" == *"expected 40 or 51 columns"* ]]
	[ "$(jq -r '.metadata.files_consumed' <<<"$output")" = "1" ]
}

@test "report: a 43-column TSV (an intermediate layout that never shipped) is skipped as legacy" {
	cut -f1-43 "$FIXTURE" > "${RES}/controlplane-mid43.tsv"
	[ "$(grep -m1 '^timestamp' "${RES}/controlplane-mid43.tsv" | awk -F'\t' '{ print NF }')" -eq 43 ]
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[[ "$stderr" == *"skipping 1 legacy TSV file(s)"* ]]
	[ "$(jq -r '.metadata.files_consumed' <<<"$output")" = "1" ]
}

# --- VirtualService/DestinationRule traffic axis -------------------------------

@test "vsdr report json: traffic axis, VS/DR knobs and per-cell traffic fields" {
	vsdr_dir
	run --separate-stderr "$REPORT" --results-dir "$VRES" --format json
	assert_success
	[ "$(jq -r '.metadata.sweep.traffic_configs' <<<"$output")" = "none,vsdr" ]
	[ "$(jq -c '.metadata.traffic_management' <<<"$output")" = '{"vsdr_every":"1","vsdr_subsets":"2"}' ]
	# Four cells: the traffic config is part of the grouping key (none sorts first).
	[ "$(jq -c '[.results[] | "\(.sidecar_scoping)/\(.traffic_config)"]' <<<"$output")" = \
		'["explicit/none","explicit/vsdr","none/none","none/vsdr"]' ]
	[ "$(jq -c '.results[3] | [.vsdr_services, .istiod_virt_services_avg, .push_time_avg_ms, .pushcontext_init_avg_ms, .xds_pushes_avg, .config_size_avg_bytes]' <<<"$output")" = \
		'[10,10,1.5,0.75,150,3072]' ]
	[ "$(jq -c '.results[3] | [.sidecar_clusters_avg, .sidecar_cds_bytes_avg, .sidecar_rds_bytes_avg]' <<<"$output")" = '[50,102400,40960]' ]
	[ "$(jq -c '[.results[] | .istiod_vs_ingest_short]' <<<"$output")" = '[false,true,false,false]' ]
}

@test "vsdr report: a restarted vsdr row stays out of the istiod aggregates but counts in n_total" {
	vsdr_dir
	run --separate-stderr "$REPORT" --results-dir "$VRES" --format json
	assert_success
	# mem 999 and VS 3 come only from the restarted row.
	[ "$(jq -c '.results[3] | [.n_total, .n_valid, .mem_mi.max, .istiod_virt_services_avg]' <<<"$output")" = '[3,2,520,10]' ]
}

@test "vsdr report markdown: traffic-effect section pairs none and vsdr with expected clusters" {
	vsdr_dir
	run --separate-stderr "$REPORT" --results-dir "$VRES" --format markdown
	assert_success
	assert_output --partial 'traffic_configs: "none,vsdr"'
	assert_output --partial 'vsdr_subsets: "2"'
	assert_output --partial "| traffic_configs | none,vsdr  (vsdr: every 1, 2 subsets) |"
	assert_output --partial "| 2 | 10 | 2 | 1 | none | vsdr | 3 | 2 | 120 |"
	[ "$(grep -c '^## Traffic management (VS/DR) effect$' <<<"$output")" -eq 1 ]
	assert_output --partial "| 2 | 10 | 2 | 1 | none | 2/2 | 10 | 0 -> 10 | 100 -> 120 (+20.0%) | 250 -> 260 (+4.0%) | 500 -> 520 (+4.0%) | 100 -> 150 (+50.0%) | 1.00 -> 1.50 (+50.0%) | 0.50 -> 0.75 (+50.0%) | 2.0 -> 3.0 (+50.0%) |"
	assert_output --partial "| 2 | 10 | 2 | 1 | none | 10 | 20 | 30 -> 50 (+66.7%) | +20 | 50.0 -> 100.0 (+100.0%) | 20.0 -> 40.0 (+100.0%) | 1.00 -> 1.50 (+50.0%) |"
	assert_output --partial "Order bias:"
}

@test "vsdr report: ingest WARN fires for the cell whose istiod saw 6 of 10 VirtualServices only" {
	vsdr_dir
	run --separate-stderr "$REPORT" --results-dir "$VRES" --format markdown
	assert_success
	[ "$(grep -c 'WARN:\*\* istiod ingested fewer VirtualServices' <<<"$output")" -eq 1 ]
	assert_output --partial 'vsdr cell `2|10|2|1|explicit`: istiod VirtualServices 0 -> 6 (+6) < 10 configured'
	run --separate-stderr "$REPORT" --results-dir "$VRES" --format text
	assert_success
	assert_output --partial "WARNING: vsdr cell 2|10|2|1|explicit: istiod VirtualServices 0 -> 6 (+6) < 10 configured"
	run --separate-stderr "$REPORT" --results-dir "$VRES" --format csv
	assert_success
	assert_output --partial "# WARNING: vsdr cell 2|10|2|1|explicit:"
	refute_output --partial "vsdr cell 2|10|2|1|none:"
}

@test "vsdr report markdown: the scoping-effect table compares none cells only" {
	vsdr_dir
	run --separate-stderr "$REPORT" --results-dir "$VRES" --format markdown
	assert_success
	# With the vsdr cells leaking in (last one wins) this row would read 1.5 / 1.0 / 33.3%.
	assert_output --partial "| 2 | 10 | 2 | 1 | 1.0 | N/A | 0.5 | N/A | 50.0% |"
}

@test "report: a none-only sweep has no traffic-effect section and no vsdr note" {
	run --separate-stderr "$REPORT" --results-dir "$RES" --format markdown
	assert_success
	refute_output --partial "## Traffic management (VS/DR) effect"
	assert_output --partial "| traffic_configs | none |"
}

@test "vsdr report charts: vsdr cells get their own series instead of overwriting none" {
	vsdr_dir
	# A second mesh size (1) so the CPU chart renders.
	awk 'BEGIN { FS = OFS = "\t" } !/^#/ && $1 != "timestamp" { $3 = 1 } !/^#/ && $1 != "timestamp" { print }' \
		"$VSDR_FIXTURE" >> "${VRES}/controlplane-fixture-t6.tsv"
	run --separate-stderr "$REPORT" --results-dir "$VRES" --format charts
	assert_success
	assert_output --partial "> Series order: **explicit** **explicit/vsdr** **none** **none/vsdr**."
}

@test "envelope: traffic row prefers the none cell at the peak mesh size, else shows vsdr" {
	source "${ROOT}/tests/lib/capacity.sh"
	source "${ROOT}/tests/lib/envelope.sh"
	vsdr_dir
	run --separate-stderr render_scale_envelope "$VRES" "$REPORT" "mesh-a,mesh-b" false
	assert_success
	assert_output --partial "| Traffic management | none |"
	# Only vsdr cells left: the peak is a vsdr cell and says so.
	awk -F'\t' '/^#/ || $1 == "timestamp" || $44 == "vsdr"' "$VSDR_FIXTURE" > "${VRES}/controlplane-fixture-t6.tsv"
	run --separate-stderr render_scale_envelope "$VRES" "$REPORT" "mesh-a,mesh-b" false
	assert_success
	assert_output --partial "| Traffic management | vsdr |"
}

# fleet_replicas <out>: the fixture as an INFRA_SCHEMA 2 file whose members run 1 and 3
# istiod replicas.
fleet_replicas() {
	awk '
		$0 == "# CONTROLPLANE_INFRA_SCHEMA=1" { print "# CONTROLPLANE_INFRA_SCHEMA=2"; next }
		$0 == "# ISTIOD_REPLICAS=3" { print "# ISTIOD_REPLICAS=1-3"; print "# ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=1,mesh-b=3"; next }
		{ print }' "$FIXTURE" > "$1"
}

@test "report: istiod replicas that differ by member read 1-3 per cluster in every format" {
	rm -f "${RES}"/*.tsv
	fleet_replicas "${RES}/controlplane-fleet.tsv"
	run --separate-stderr "$REPORT" --results-dir "$RES"
	assert_success
	assert_output --partial "istiod replicas:             1-3 per cluster (varies by cluster)"
	assert_output --partial "istiod replicas by context:  mesh-a=1,mesh-b=3"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format markdown
	assert_output --partial "| istiod replicas | 1-3 per cluster (varies by cluster) |"
	assert_output --partial 'istiod_replicas_by_context: "mesh-a=1,mesh-b=3"'
	run --separate-stderr "$REPORT" --results-dir "$RES" --format csv
	assert_output --partial "istiod_replicas=1-3 istiod_replicas_by_context=mesh-a=1,mesh-b=3 "
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	[ "$(jq -c '.metadata.infra | [.istiod_replicas, .istiod_replicas_by_context]' <<<"$output")" = '["1-3","mesh-a=1,mesh-b=3"]' ]
}

@test "report: an INFRA_SCHEMA 1 file says its replica count is the first context's" {
	run --separate-stderr "$REPORT" --results-dir "$RES"
	assert_success
	assert_output --partial "istiod replicas:             3 (first context only)"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	[ "$(jq -r '.metadata.infra.istiod_replicas_by_context' <<<"$output")" = unknown ]
}

@test "envelope: istiod replicas probed on every context, no context names in the table" {
	source "${ROOT}/tests/lib/capacity.sh"
	source "${ROOT}/tests/lib/envelope.sh"
	_rep_kubectl() {
		local ctx="" a
		for a in "$@"; do [[ "$a" == --context=* ]] && ctx="${a#--context=}"; done
		[[ "$*" == *"get deploy istiod"* ]] || return 1
		case "$ctx" in
		mesh-a) echo '{"spec":{"replicas":1,"template":{"spec":{"containers":[{"name":"discovery"}]}}}}' ;;
		mesh-b) echo '{"spec":{"replicas":3,"template":{"spec":{"containers":[{"name":"discovery"}]}}}}' ;;
		esac
	}
	run --separate-stderr render_scale_envelope "$RES" "$REPORT" "mesh-a,mesh-b" _rep_kubectl
	assert_success
	assert_output --partial "| istiod replicas | 1-3 per cluster (varies by cluster) | — | live \`deploy/istiod\` on every context |"
	assert_output --partial "per-replica limit x that cluster's istiod replicas"
	refute_output --partial "mesh-b=3"
}

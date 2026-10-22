#!/usr/bin/env bats
# End-to-end tests of tests/controlplane/004-report-results.sh (PL33: through the real
# entrypoint) against fixture TSVs (no cluster). A figure, a label or a warning that more
# than one format prints from one value is checked in every format once (the metadata
# test), and its rules in json.
#
# Fixture fixtures/controlplane_cluster_proxies.tsv (one combo: mesh 2, 15 svc, 2 reps, 1 ns,
# scoping none; tolerance 10 %, min diff 2):
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
GROWTH="${ROOT}/tests/lib/test/fixtures/controlplane_ns_growth.tsv"
REPORT="${ROOT}/tests/controlplane/004-report-results.sh"

setup() {
	RES="${BATS_TEST_TMPDIR}/r"
	mkdir -p "$RES"
	cp "$FIXTURE" "${RES}/controlplane-fixture-t2.tsv"
}

# report <format> [dir] [flag...]: 004 over res/ (or dir), its stderr apart; it must succeed.
report() {
	local fmt="$1" dir="${2:-$RES}"
	(($# < 2)) || shift
	shift
	run --separate-stderr "$REPORT" --results-dir "$dir" --format "$fmt" "$@"
	assert_success
}

verdict() { jq -r '.metadata.sla.verdict' <<<"$output"; }
headline() { jq -r '.metadata.sla.headline' <<<"$output"; }

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

# with_platform <sed program>: the fixture with the platform record a current 003 writes
# (members mesh-a and mesh-b on kind nodes), edited by <sed program>.
with_platform() {
	{
		head -1 "$FIXTURE"
		platform_fixture_lines mesh-a,mesh-b | sed "$1"
		tail -n +2 "$FIXTURE"
	} > "${RES}/controlplane-fixture-t2.tsv"
}

# second_input <sed program>: controlplane-fixture-t3.tsv, the fixture again with the record
# edited by <sed program>: a second input of the same report.
second_input() {
	{
		head -1 "$FIXTURE"
		platform_fixture_lines mesh-a,mesh-b | sed "$1"
		tail -n +2 "$FIXTURE"
	} > "${RES}/controlplane-fixture-t3.tsv"
}

# set_key <file> <KEY> <value>: the preamble's "# KEY=" line set to <value>.
set_key() {
	sed "s|^# ${2}=.*|# ${2}=${3}|" "$1" > "${1}.new"
	mv "${1}.new" "$1"
}

# cp_tsv <file> <second WINDOW_ROWS> <mesh-b rows in it> [lines before the first
# WINDOW_ROWS] [lines before the second]: the fixture's preamble (plus
# ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=3,mesh-b=3) and two cells (15 and 30 services) of valid
# rows, each member 3 rows a window (mesh-b <n> in the second).
cp_tsv() {
	awk -F'\t' -v OFS='\t' -v w2="$2" -v nb="$3" -v x1="${4:-}" -v x2="${5:-}" '
	function row(at, s, m, n,    i) { for (i = 1; i <= n; i++) { $0 = t; $1 = "2026-06-01T" at ":00+00:00"; $2 = m; $4 = s; $31 = 0; print } }
	/^#/ {
		print
		if (index($0, "# ISTIOD_REPLICAS=") == 1) print "# ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=3,mesh-b=3"
		next
	}
	$1 == "timestamp" { print; next }
	t == "" { t = $0 }
	END {
		if (x1 != "") print x1
		print "# WINDOW_ROWS=mesh-a=3/3,mesh-b=3/3"; row("00:00", 15, "mesh-a", 3); row("00:00", 15, "mesh-b", 3)
		if (x2 != "") print x2
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
		set_key "${1}/sweep-${s}/controlplane-run-${s}.tsv" RUN_ID "run-${s}"
	done
}

# ---------------------------------------------------------------------------
# The cluster-proxies fixture: its figures in each format

@test "report json: per-replica vs per-cluster peaks, the proxy-check tally and n valid of n total; every valid row has a push count" {
	report json
	[ "$(jq -r '.metadata.achieved_scale.connected_proxies_max' <<<"$output")" = "16" ]
	[ "$(jq -r '.metadata.achieved_scale.connected_proxies_cluster_max' <<<"$output")" = "34" ]
	[ "$(jq -c '.metadata.proxy_check | {tolerance_pct, min_diff, ok, low, high, na, excluded}' <<<"$output")" = \
		'{"tolerance_pct":"10","min_diff":"2","ok":2,"low":1,"high":0,"na":0,"excluded":1}' ]
	[ "$(jq -r '.metadata.proxy_check.flagged' <<<"$output")" = "mesh-a@2026-06-01T00:10:00+00:00:LOW:30/40" ]
	[ "$(jq -c '.results[0].connected_proxies_cluster' <<<"$output")" = '{"min":30,"max":34,"avg":31}' ]
	[ "$(jq -c '.results[0].connected_proxies' <<<"$output")" = '{"min":9,"max":16,"avg":13}' ]
	[ "$(jq -c '[.results[0].n_total, .results[0].n_valid, .results[0].xds_pushes_n]' <<<"$output")" = '[10,9,9]' ]
	[[ "$stderr" != *"no xDS push count"* ]]
}

@test "report text: per-cluster peak, tally and a WARNING naming the cluster scrape" {
	report text
	assert_output --partial "connected_proxies per istiod replica (max): 16"
	assert_output --partial "connected_proxies per cluster (max): 34"
	assert_output --partial "(tolerance 10%, min diff 2): ok=2 low=1 high=0 n/a=0 excluded=1"
	assert_output --partial "WARNING: connected proxies differ from Running sidecar pods"
	assert_output --partial "mesh-a@2026-06-01T00:10:00+00:00:LOW:30/40"
	assert_output --partial "Connected proxies / cluster:        min=30 max=34 avg=31"
}

@test "report csv: rows gain cluster_proxies_*, the traffic and the growth columns (69) and a proxy_check comment" {
	local hdr row
	report csv
	hdr=$(grep -v '^#' <<<"$output" | sed -n 1p)
	row=$(grep -v '^#' <<<"$output" | sed -n 2p)
	[ "$(awk -F, '{ print NF }' <<<"$hdr")" -eq 69 ]
	# heap_inuse summed per cluster scrape (500, 750, 500; the restarted mesh-b scrape is
	# out) and the istiod pods per scrape (2, 3, 2); no status rows; a legacy cell has no
	# series run (-).
	[[ "$hdr" == *",heap_inuse_cluster_avg,istiod_pods_avg,status_rows,statuses,series_run_id,gateway_physical_max,gateway_ws_max,leftover_ns_max,cpu_window_avg,pushes_n" ]]
	# A 51-column file has no gateway physical/working-set, leftover or CPU-seconds column:
	# N/A; all 9 valid rows have a push count (pushes_n).
	[[ "$row" == *",583.3,2.3,0,-,-,N/A,N/A,N/A,N/A,9" ]]
	[[ "$hdr" == *",cluster_proxies_min,cluster_proxies_max,cluster_proxies_avg,traffic_config,vsdr_services,"* ]]
	[[ "$row" == *",30,34,31,none,0,"* ]]
	# A 51-column file reads as the legacy layout: K 0, pods, 15 svc x 2 reps, no outside, deploy.
	[[ "$hdr" == *",services_per_namespace,workload_mode,measurement_pods,outside_namespaces,outside_discovery,window_kind,istiod_services_max,"* ]]
	[[ "$row" == *",0,pods,30,0,none,deploy,N/A,"* ]]
	assert_output --partial "# proxy_check: tolerance_pct=10 min_diff=2 ok=2 low=1 high=0 na=0 excluded=1"
	assert_output --partial "connected_proxies_cluster_max=34"
	assert_output --partial "# WARNING: connected proxies differ"
}

@test "report markdown: proxies/cluster column, achieved rows and a Warning note; a none-only sweep has no traffic-effect section" {
	report markdown
	assert_output --partial "| proxies/replica | proxies/cluster |"
	assert_output --partial "| connected_proxies per cluster (max) | 34 |"
	assert_output --partial "> **Warning:** connected proxies differ"
	assert_output --partial 'proxy_check_tolerance_pct: "10"'
	refute_output --partial "## Traffic management (VS/DR) effect"
	assert_output --partial "| traffic_configs | none |"
}

@test "envelope from the report JSON: per-cluster and per-replica peaks and the proxy check; istiod replicas probed on every context, no context names in the table" {
	source "${ROOT}/tests/lib/capacity.sh"
	source "${ROOT}/tests/lib/envelope.sh"
	source "${ROOT}/tests/lib/platform.sh"  # platform_summary (the Platform / mesh build row)
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
	assert_output --partial "| **Connected proxies per cluster (measured peak)** | 34 |"
	assert_output --partial "| Connected proxies per istiod replica (peak) | 16 |"
	# n/a and excluded are shown, so the fixture's excluded scrape is not hidden.
	assert_output --partial "| Proxy check vs Running sidecar pods | ok=2 low=1 high=0 n/a=0 excluded=1 (tolerance 10%, min diff 2) |"
	assert_output --partial "| istiod replicas | 1-3 per cluster (varies by cluster) | — | live \`deploy/istiod\` on every context |"
	refute_output --partial "mesh-b=3"
}

@test "report: a 40-column TSV feeds the old columns only: next to a 51-column file it adds nothing to the new keys; alone, they read unknown" {
	# Named to sort FIRST, so the tolerance must not come from the first file only.
	legacy40 "${RES}/controlplane-a-legacy40.tsv"
	[ "$(grep -m1 '^timestamp' "${RES}/controlplane-a-legacy40.tsv" | awk -F'\t' '{ print NF }')" -eq 40 ]
	report json
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
	# Alone.
	rm -f "${RES}/controlplane-fixture-t2.tsv"
	report json
	[ "$(jq -r '.metadata.achieved_scale.connected_proxies_cluster_max' <<<"$output")" = "unknown" ]
	[ "$(jq -r '.metadata.proxy_check.tolerance_pct' <<<"$output")" = "unknown" ]
	[ "$(jq -c '.results[0].connected_proxies_cluster' <<<"$output")" = '{"min":null,"max":null,"avg":null}' ]
}

@test "report: a TSV of another width is skipped as legacy, with a warning" {
	cut -f1-34 "$FIXTURE" > "${RES}/controlplane-old34.tsv"
	report json
	[[ "$stderr" == *"skipping 1 legacy TSV file(s)"* ]]
	[[ "$stderr" == *"expected 40, 51, 63 or 66 columns"* ]]
	[ "$(jq -r '.metadata.files_consumed' <<<"$output")" = "1" ]
}

# ---------------------------------------------------------------------------
# What the report merges from its inputs: the platform record, provenance, the record

@test "every format carries what the report merged from its inputs (PL19): the platform record (mixed where inputs differ), the pooled runs and their provenance warning, the sweep's record, the verdict and the data warnings" {
	local v h fmt p="istiod restarted during the sweep (bats)" t3="${RES}/controlplane-fixture-t3.tsv"
	local dis="input TSVs disagree on PROXY_IMAGE_BY_CONTEXT for 2 of 2 members: the report mixes runs with different values of it; compare like with like"
	local kv="mesh-a=v1.34.8,mesh-b=mixed:v1.34.8;v1.35.0" pi="mesh-a=mixed:proxyv2:1.30.5;proxyv2:1.30.6,mesh-b=mixed:proxyv2:1.30.5;proxyv2:1.30.6"
	# Two runs: mesh-b on kind nodes; the second on another proxy build, another Kubernetes
	# version on mesh-b and another Istio version. The first's sweep record has a problem.
	# The verdict is the fixture's own (FAIL: a restart in a window), the rest in its headline.
	with_platform 's/mesh-a=kind/mesh-a=aws/'
	second_input 's/mesh-a=kind/mesh-a=aws/; s/proxyv2:1.30.5/proxyv2:1.30.6/g'
	set_key "$t3" RUN_ID fixture-t3
	set_key "$t3" ISTIO_VERSION 1.30.6
	set_key "$t3" KUBE_VERSIONS mesh-a=v1.34.8,mesh-b=v1.35.0
	printf '%s\n' STATUS=finished RUN_ID=fixture-t2 TOTAL=1 FAILED=0 "PROBLEM=${p}" > "${RES}/sweep-outcome.txt"
	report json "$RES" --allow-multi-run
	v="$(verdict)"
	h="$(headline)"
	[ "$v" = FAIL ]
	[[ "$h" == *"; also the sweep outcome is not clean"*"; also the inputs were measured on different Istio versions"*"; also node figures left out"* ]]
	[ "$(jq -r '.metadata | "\(.proxy_image_by_context) \(.kube_versions) \(.node_provider_by_context)"' <<<"$output")" = "${pi} ${kv} mesh-a=aws,mesh-b=kind" ]
	jq -e --arg d "$dis" '.metadata.data_warnings | index($d) != null and any(.[]; startswith("Nodes on kind (NODE_PROVIDER_BY_CONTEXT)")) and any(.[]; startswith("input TSVs disagree on KUBE_VERSIONS for 1 of 2 members"))' <<<"$output"
	[[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" == "The inputs were measured on different Istio versions (ISTIO_VERSION 1.30.5,1.30.6)"* ]]
	[ "$(jq -c '[.pooled_runs.runs, .sweep_outcomes[0].problems[0]]' <<<"$output")" = "$(jq -cn --arg p "$p" '[2, $p]')" ]
	# stderr names the members.
	[[ "$stderr" == *"warning: input TSVs disagree on PROXY_IMAGE_BY_CONTEXT for mesh-a (proxyv2:1.30.5 or proxyv2:1.30.6), mesh-b (proxyv2:1.30.5 or proxyv2:1.30.6)"* ]]
	for fmt in text csv; do
		report "$fmt" "$RES" --allow-multi-run
		[[ "$(grep '^# platform: ' <<<"$output")" == *"PROXY_IMAGE_BY_CONTEXT=${pi}"*"KUBE_VERSIONS=${kv}"* ]] || { echo "${fmt}: $(grep '^# platform: ' <<<"$output")"; false; }
		assert_line "# WARNING: ${dis}"
		assert_output --partial "# WARNING: Nodes on kind (NODE_PROVIDER_BY_CONTEXT)"
		assert_output --partial "# WARNING: The inputs were measured on different Istio versions (ISTIO_VERSION 1.30.5,1.30.6)"
		assert_output --partial "$p"
		assert_output --partial "${v} — ${h}"
	done
	assert_line "# POOLED_RUNS=2"
	for fmt in markdown charts; do
		report "$fmt" "$RES" --allow-multi-run
		assert_line "proxy_image_by_context: \"${pi}\""
		assert_line "kube_versions: \"${kv}\""
		assert_line "> **Warning:** ${dis}"
		assert_output --partial "> **Warning:** Nodes on kind (NODE_PROVIDER_BY_CONTEXT)"
		# charts tells the version mix in its pooled-runs note only.
		assert_output --partial "> **Pooled runs.** This report pools 2 runs (--allow-multi-run): fixture-t2, fixture-t3. HARNESS_SHA: fixture. ISTIO_VERSION: 1.30.5, 1.30.6. These differ"
		assert_output --partial "$p"
		[[ "$fmt" == markdown ]] || continue
		assert_output --partial "> **Warning:** The inputs were measured on different Istio versions (ISTIO_VERSION 1.30.5,1.30.6)"
		assert_line "sla_verdict: \"${v}\""
		assert_output --partial "**Customer SLA verdict: ${v}** — ${h}"
	done
}

@test "node figures: kind nodes warn that capacity is the shared host's, a member whose node provider was not read warns too, and either leaves the node figures out of the verdict; a file from before the record warns of neither" {
	local w="Node provider not read on 1 member(s) (NODE_PROVIDER_BY_CONTEXT unknown): if their nodes are kind's, every node reports the whole host's CPU and memory"
	with_platform 's/mesh-a=kind/mesh-a=aws/; s/mesh-b=kind/mesh-b=unknown/'
	report json
	[ "$(jq --arg w "$w" '[.metadata.data_warnings[] | select(startswith($w))] | length' <<<"$output")" = 1 ]
	[ "$(jq '[.metadata.data_warnings[] | select(startswith("Nodes on kind"))] | length' <<<"$output")" = 0 ]
	[ "$(verdict)" != PASS ]
	[[ "$(headline)" == *"node figures left out: node provider not read on 1 member(s) (NODE_PROVIDER_BY_CONTEXT unknown), so node_cpu_pct and node_mem_pct may measure a host several clusters share, as on kind"* ]]
	# With a member on kind as well, the kind warning (and its reason) covers it.
	with_platform 's/mesh-b=kind/mesh-b=unknown/'
	report json
	[ "$(jq '[.metadata.data_warnings[] | select(startswith("Node provider not read"))] | length' <<<"$output")" = 0 ]
	[ "$(jq '[.metadata.data_warnings[] | select(startswith("Nodes on kind (NODE_PROVIDER_BY_CONTEXT): every node reports the whole host'"'"'s CPU and memory"))] | length' <<<"$output")" = 1 ]
	[[ "$(headline)" == *"node figures left out: the nodes are kind's"* ]]
	# A file from before the record (it does not know its nodes): no warning, no guess.
	cp "$FIXTURE" "${RES}/controlplane-fixture-t2.tsv"
	report json
	[ "$(jq '[(.metadata.data_warnings // [])[] | select(test("kind|Node provider not read"))] | length' <<<"$output")" = 0 ]
	[[ "$(headline)" != *"node figures left out"* ]]
}

@test "report (H10): an input whose platform value was not read, next to one that was, warns counting members (stderr names them); the merged value marks it" {
	with_platform 's/=kind/=aws/g; s/mesh-b=pilot:1.30.5/mesh-b=unknown/'
	second_input 's/=kind/=aws/g'
	report json
	[ "$(jq --arg u "ISTIOD_IMAGE_BY_CONTEXT is unknown in some input TSVs (not read for 1 of 2 members), while others have a value: the report cannot tell whether those runs had the same one" '[.metadata.data_warnings[] | select(. == $u)] | length' <<<"$output")" = 1 ]
	[[ "$stderr" == *"warning: ISTIOD_IMAGE_BY_CONTEXT is unknown in some input TSVs (not read for mesh-b)"* ]]
	[[ "$(jq -r '.metadata.istiod_image_by_context' <<<"$output")" == "mesh-a=pilot:1.30.5,mesh-b="*unknown* ]]
}

# ---------------------------------------------------------------------------
# The verdict and the data warnings of a window's rows

@test "a window that ran on fewer istiod pods than its member's Deployment wants (<n>/<spec>) is valid but turns PASS into CAUTION with a data warning; <n> at <spec> is PASS; fewer rows than <n> stays INCOMPLETE; a member with no istiod pod Running (one N/A row, 1/<spec>) is no shortfall" {
	local w tsv="${RES}/controlplane-fixture-t2.tsv" dg
	cp_tsv "$tsv" "mesh-a=3/3,mesh-b=2/3" 2
	report json
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "1 cell(s) ran on fewer istiod pods than their member's istiod Deployment wants (a replica evicted or Pending), so their per-replica figures are not comparable with the other cells; the figures: peak utilization"* ]]
	w="1 cell(s) ran on fewer istiod pods than their member's istiod Deployment wants (its .spec.replicas at the window's baseline: a replica evicted, or Pending), so their per-replica figures are not comparable with the other cells; the rows are valid measurements of the pods that ran: mesh=2 svcs=30 reps=2 ns=1 scope=none traffic=none (mesh-b ran 2 of its 3 istiod replicas)."
	# The only data warning: the cell is not INCOMPLETE.
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = "$(jq -cn --arg w "$w" '[$w]')" ]
	# The Deployment wanted 2 at that window's baseline: the window ran what it wanted.
	cp_tsv "$tsv" "mesh-a=3/3,mesh-b=2/2" 2
	report json
	[ "$(verdict)" = PASS ]
	# The window wrote 3 rows for mesh-b and the TSV holds 2: cut short, as before /<spec>.
	cp_tsv "$tsv" "mesh-a=3/3,mesh-b=3/3" 2
	report json
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "1 cell(s) are INCOMPLETE "* ]]
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == *"(mesh-b has 2 of the 3 rows its window wrote)"* ]]
	[ "$(jq -r '.metadata.data_warnings | length' <<<"$output")" = 1 ]
	# mesh-b had no istiod pod Running: one degraded N/A row (istiod_restarted unknown) and
	# the entry mesh-b=1/3. Not "ran 1 of its 3": its row is in no figure, and the verdict
	# already reads CAUTION for it (n_valid below n_total).
	cp_tsv "$tsv" "mesh-a=3/3,mesh-b=1/3" 0
	dg="$(grep -v '^#' "$tsv" | sed -n 2p | awk -F'\t' -v OFS='\t' '{ $1 = "2026-06-01T00:10:00+00:00"; $2 = "mesh-b"; $4 = 30; for (i = 8; i <= 27; i++) $i = "N/A"; $31 = "unknown"; print }')"
	printf '%s\n' "$dg" >> "$tsv"
	report json
	[ "$(jq -r '.metadata.data_warnings[]' <<<"$output" | grep -c 'istiod replicas')" = 0 ]
	[ "$(verdict)" != PASS ]
}

@test "a WINDOW_ROWS line without /<spec> (an older harness) below the member's ISTIOD_REPLICAS_BY_CONTEXT is a data warning only; a growth window's own line is read too" {
	local g="${BATS_TEST_TMPDIR}/grow"
	cp_tsv "${RES}/controlplane-fixture-t2.tsv" "mesh-a=3,mesh-b=2" 2
	report json
	[ "$(verdict)" = PASS ]
	[ "$(jq -r '.metadata.data_warnings | length' <<<"$output")" = 1 ]
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == "1 cell(s) have fewer rows for a member than its istiod replicas at the sweep's start (ISTIOD_REPLICAS_BY_CONTEXT): mesh=2 svcs=30 reps=2 ns=1 scope=none traffic=none (mesh-b ran 2 of its 3 istiod replicas). "*"it does not change the verdict." ]]
	# A growth series' first window ran 1 of the 2 istiod pods its Deployment wanted.
	mkdir -p "$g"
	awk '!/^#/ && $1 != "timestamp" && !d++ { print "# WINDOW_ROWS=mesh-a=1/2" } { print }' "$GROWTH" > "${g}/controlplane-fixture-ns.tsv"
	report json "$g"
	[[ "$(jq -r '.metadata.data_warnings[]' <<<"$output")" == *"the rows are valid measurements of the pods that ran: mesh=1 svcs=200 reps=1 ns=100 scope=namespace traffic=none window=grow (mesh-a ran 1 of its 2 istiod replicas)."* ]]
	# The fixture's verdict is FAIL (a restart): the cell adds itself to the headline.
	[ "$(verdict)" = FAIL ]
	[[ "$(headline)" == *"; also 1 cell(s) ran on fewer istiod pods than their member's istiod Deployment wants"* ]]
}

@test "a cell cut short while its member rows were written is INCOMPLETE (rows of fewer members than its mesh size; in a TSV without WINDOW_ROWS, a member with fewer rows than its istiod replicas in the cell written last): a data warning, CAUTION; a standalone 002 run is never INCOMPLETE" {
	local tsv="${RES}/controlplane-fixture-t2.tsv" s2="${BATS_TEST_TMPDIR}/standalone"
	# The second cell has rows of mesh-a only (an older harness: no WINDOW_ROWS lines).
	cp_tsv "$tsv" "mesh-a=3/3,mesh-b=3/3" 0
	no_window_rows "$tsv"
	report json
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "1 cell(s) are INCOMPLETE (rows of fewer members than their mesh size"* ]]
	[ "$(jq -r '.metadata.data_warnings | length' <<<"$output")" = 1 ]
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == "1 cell(s) are INCOMPLETE: "*": mesh=2 svcs=30 reps=2 ns=1 scope=none traffic=none (rows of 1 of 2 members)."* ]]
	# mesh-b wrote 2 rows in the cell written last, 3 (its istiod replicas) in the first.
	cp_tsv "$tsv" "mesh-a=3/3,mesh-b=3/3" 2
	no_window_rows "$tsv"
	report json
	[ "$(verdict)" = CAUTION ]
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == *": mesh=2 svcs=30 reps=2 ns=1 scope=none traffic=none (mesh-b has rows of 2 of its 3 istiod replicas)."* ]]
	# The same rows from a standalone 002 run (PHASE is not sweep) are no sweep's cells.
	mkdir -p "$s2"
	cp "$tsv" "${s2}/${tsv##*/}"
	set_key "${s2}/${tsv##*/}" PHASE final
	report json "$s2"
	[ "$(verdict)" = PASS ]
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = '[]' ]
}

@test "a row cut short (fewer columns than the header, at least 40) is not a row: its cell is INCOMPLETE, its columns read as no figure" {
	local tsv="${RES}/controlplane-fixture-t2.tsv"
	cp_tsv "$tsv" "mesh-a=3/3,mesh-b=3/3" 3
	awk -F'\t' -v OFS='\t' -v last="$(wc -l < "$tsv")" 'NR == last { NF = 42 } { print }' "$tsv" > "${tsv}.cut"
	mv "${tsv}.cut" "$tsv"
	[ "$(awk -F'\t' 'END { print NF }' "$tsv")" = 42 ]
	report json
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "1 cell(s) are INCOMPLETE "* ]]
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == *"svcs=30 "*"(mesh-b has 2 of the 3 rows its window wrote)"* ]]
	[ "$(jq -r '.metadata.data_warnings | length' <<<"$output")" = 1 ]
}

@test "a cell whose window had a Running istiod pod not Ready at its baseline, or one not Ready at its end, is named in a data warning of each kind, and the verdict does not change; a line read only right before a WINDOW_ROWS line (the end line right after the baseline line); a growth window's own lines count" {
	local tsv="${RES}/controlplane-fixture-t2.tsv" g="${BATS_TEST_TMPDIR}/g" v
	cp_tsv "$tsv" "mesh-a=3/3,mesh-b=3/3" 3
	report json
	v="$(jq -c '.metadata.sla' <<<"$output")"
	[ "$(verdict)" = PASS ]
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = '[]' ]
	cp_tsv "$tsv" "mesh-a=3/3,mesh-b=3/3" 3 "" "# ISTIOD_NOT_READY=mesh-b=istiod-x,mesh-b=istiod-y"$'\n'"# ISTIOD_NOT_READY_AT_END=mesh-a=istiod-z,mesh-b=istiod-y"
	report json
	[ "$(jq -c '.metadata.sla' <<<"$output")" = "$v" ]
	[ "$(jq -r '.metadata.data_warnings | length' <<<"$output")" = 2 ]
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == "1 cell(s) have an istiod pod that was Running but not Ready at the window's baseline: mesh=2 svcs=30 reps=2 ns=1 scope=none traffic=none (istiod-x on mesh-b, istiod-y on mesh-b). "*"it does not change the verdict." ]]
	[[ "$(jq -r '.metadata.data_warnings[1]' <<<"$output")" == "1 cell(s) have an istiod pod that was not Ready at the window's end "*"mesh=2 svcs=30 reps=2 ns=1 scope=none traffic=none (istiod-z on mesh-a, istiod-y on mesh-b). "*"it does not change the verdict." ]]
	# First window: a baseline line with another line between it and the end line names
	# nothing, the end line still counts. Second: an end line not right before WINDOW_ROWS.
	cp_tsv "$tsv" "mesh-a=3/3,mesh-b=3/3" 3 "# ISTIOD_NOT_READY=mesh-b=istiod-x"$'\n'"# NOTE=bats"$'\n'"# ISTIOD_NOT_READY_AT_END=mesh-b=istiod-y" "# ISTIOD_NOT_READY_AT_END=mesh-b=istiod-w"$'\n'"# NOTE=bats"
	report json
	[ "$(jq -r '.metadata.data_warnings | length' <<<"$output")" = 1 ]
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == "1 cell(s) have an istiod pod that was not Ready at the window's end "*"mesh=2 svcs=15 reps=2 ns=1 scope=none traffic=none (istiod-y on mesh-b). "* ]]
	# A growth series' first window.
	mkdir -p "$g"
	awk '!/^#/ && $1 != "timestamp" && !d++ { print "# ISTIOD_NOT_READY=mesh-a=istiod-g"; print "# ISTIOD_NOT_READY_AT_END=mesh-a=istiod-h"; print "# WINDOW_ROWS=mesh-a=1/1" } { print }' "$GROWTH" > "${g}/controlplane-fixture-ns.tsv"
	report json "$g"
	[[ "$(jq -r '.metadata.data_warnings[]' <<<"$output")" == *"1 cell(s) have an istiod pod that was Running but not Ready at the window's baseline: mesh=1 svcs=200 reps=1 ns=100 scope=namespace traffic=none window=grow (istiod-g on mesh-a)."* ]]
	[[ "$(jq -r '.metadata.data_warnings[]' <<<"$output")" == *"not Ready at the window's end "*"mesh=1 svcs=200 reps=1 ns=100 scope=namespace traffic=none window=grow (istiod-h on mesh-a)."* ]]
}

@test "a sweep outcome that is not clean turns PASS into CAUTION, its rule named in the headline: a PROBLEM (the record found through a symlink to the dir), a failed cell, a sweep still running, each record of a pooled report; a NOTE stays PASS" {
	local base="${BATS_TEST_TMPDIR}/base" h="the sweep outcome is not clean ("
	cp_tsv "${RES}/controlplane-fixture-t2.tsv" "mesh-a=3/3,mesh-b=3/3" 3
	printf 'STATUS=finished\nRUN_ID=fixture-t2\nTOTAL=2\nFAILED=0\nPROBLEM=istiod restarted during the sweep (bats)\n' > "${RES}/sweep-outcome.txt"
	# Through a symlink to the results dir (no trailing slash).
	ln -s "$RES" "${BATS_TEST_TMPDIR}/latest"
	report json "${BATS_TEST_TMPDIR}/latest"
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "${h}"*": finished, 1 problem(s): see sweep-outcome.txt), so the figures may not cover or measure what they seem to; the figures: "* ]]
	[ "$(jq -r '.sweep_outcomes[0].problems[0]' <<<"$output")" = "istiod restarted during the sweep (bats)" ]
	# A note is a caveat, not a failure.
	printf 'STATUS=finished\nTOTAL=2\nFAILED=0\nNOTE=a member was not ready at the start (bats)\n' > "${RES}/sweep-outcome.txt"
	report json
	[ "$(verdict)" = PASS ]
	# Pooled sweeps: the headline names each record that is not clean.
	pooled "$base"
	printf 'STATUS=finished\nTOTAL=2\nFAILED=1\nFAILED_BY=INCOMPLETE x1\n' > "${base}/sweep-a/sweep-outcome.txt"
	printf 'STATUS=running\n' > "${base}/sweep-b/sweep-outcome.txt"
	report json "$base" --allow-multi-run
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "${h}sweep-a: finished, 1 failed; sweep-b: running: see sweep-outcome.txt)"* ]]
	[ "$(jq -c '[.sweep_outcomes[] | [.dir, .status]]' <<<"$output")" = '[["sweep-a","finished"],["sweep-b","running"]]' ]
}

@test "inputs of different Istio versions turn PASS into CAUTION and name the versions; a sweep whose members ran different versions keeps its mixed:a/b value one item in every list and tag; different harnesses alone warn, without a verdict change" {
	local base="${BATS_TEST_TMPDIR}/base" d="${BATS_TEST_TMPDIR}/mixed"
	pooled "$base"
	set_key "${base}/sweep-a/controlplane-run-a.tsv" ISTIO_VERSION 1.30.5
	set_key "${base}/sweep-b/controlplane-run-b.tsv" ISTIO_VERSION 1.30.6
	report json "$base" --allow-multi-run
	[ "$(verdict)" = CAUTION ]
	[[ "$(headline)" == "the inputs were measured on different Istio versions (ISTIO_VERSION 1.30.5,1.30.6; see the provenance warning), so their cells may not be comparable; the figures: "* ]]
	# One Istio version, two harnesses: a warning, still PASS.
	set_key "${base}/sweep-b/controlplane-run-b.tsv" ISTIO_VERSION 1.30.5
	set_key "${base}/sweep-b/controlplane-run-b.tsv" HARNESS_SHA abc1234-dirty
	report json "$base" --allow-multi-run
	[ "$(verdict)" = PASS ]
	[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" = "The inputs ran on different harnesses, or one did not record its harness (HARNESS_SHA fixture,abc1234-dirty), so their cells may not be measured the same way." ]
	[ "$(jq -r '.metadata.harness_sha' <<<"$output")" = "mixed:fixture,abc1234-dirty" ]
	# One sweep whose members ran 1.30.5 and 1.29.0.
	mkdir -p "$d"
	sed 's|^# ISTIO_VERSION=.*|# ISTIO_VERSION=mixed:v1.30.5/v1.29.0|' "$FIXTURE" > "${d}/controlplane-mixed.tsv"
	report json "$d"
	[ "$(jq -c '[.metadata.istio_version, .metadata.istio_versions, .pooled_runs.istio_version]' <<<"$output")" = \
		'["mixed:v1.30.5/v1.29.0",["mixed:v1.30.5/v1.29.0"],["mixed:v1.30.5/v1.29.0"]]' ]
	[[ "$stderr" == *"WARNING: The inputs were measured on different Istio versions (ISTIO_VERSION mixed:v1.30.5/v1.29.0)"* ]]
	# Pooled with a run on one of those versions (1.30.5, without the v): each distinct
	# version once, one `# KEY=value` line.
	sed 's|^# RUN_ID=.*|# RUN_ID=other|' "$FIXTURE" > "${d}/controlplane-other.tsv"
	report csv "$d" --allow-multi-run
	assert_line "# ISTIO_VERSION=mixed:v1.30.5,v1.29.0"
	refute_output --partial "mixed:mixed:"
}

# ---------------------------------------------------------------------------
# VirtualService/DestinationRule traffic axis

@test "vsdr report json: traffic axis, VS/DR knobs and per-cell traffic fields; a restarted vsdr row stays out of the istiod aggregates but counts in n_total" {
	vsdr_dir
	report json "$VRES"
	[ "$(jq -r '.metadata.sweep.traffic_configs' <<<"$output")" = "none,vsdr" ]
	[ "$(jq -c '.metadata.traffic_management' <<<"$output")" = '{"vsdr_every":"1","vsdr_subsets":"2"}' ]
	# Four cells: the traffic config is part of the grouping key (none sorts first).
	[ "$(jq -c '[.results[] | "\(.sidecar_scoping)/\(.traffic_config)"]' <<<"$output")" = \
		'["explicit/none","explicit/vsdr","none/none","none/vsdr"]' ]
	[ "$(jq -c '.results[3] | [.vsdr_services, .istiod_virt_services_avg, .push_time_avg_ms, .pushcontext_init_avg_ms, .xds_pushes_avg, .config_size_avg_bytes]' <<<"$output")" = \
		'[10,10,1.5,0.75,150,3072]' ]
	[ "$(jq -c '.results[3] | [.sidecar_clusters_avg, .sidecar_cds_bytes_avg, .sidecar_rds_bytes_avg]' <<<"$output")" = '[50,102400,40960]' ]
	[ "$(jq -c '[.results[] | .istiod_vs_ingest_short]' <<<"$output")" = '[false,true,false,false]' ]
	# mem 999 and VS 3 come only from the restarted row.
	[ "$(jq -c '.results[3] | [.n_total, .n_valid, .istiod_rss_peak_mi.max, .istiod_virt_services_avg]' <<<"$output")" = '[3,2,520,10]' ]
}

@test "vsdr report markdown: the traffic-effect section pairs none and vsdr with expected clusters; the scoping-effect table compares none cells only" {
	vsdr_dir
	report markdown "$VRES"
	assert_output --partial 'traffic_configs: "none,vsdr"'
	assert_output --partial "| traffic_configs | none,vsdr  (vsdr: every 1, 2 subsets) |"
	assert_output --partial "| 2 | 10 | 2 | 1 | none | vsdr | 3 | 2 | 120 |"
	[ "$(grep -c '^## Traffic management (VS/DR) effect$' <<<"$output")" -eq 1 ]
	assert_output --partial "| 2 | 10 | 2 | 1 | none | 2/2 | 10 | 0 -> 10 | 100 -> 120 (+20.0%) | 250 -> 260 (+4.0%) | 500 -> 520 (+4.0%) | 100 -> 150 (+50.0%) | 1.00 -> 1.50 (+50.0%) | 0.50 -> 0.75 (+50.0%) | 2.0 -> 3.0 (+50.0%) |"
	assert_output --partial "| 2 | 10 | 2 | 1 | none | 10 | 20 | 30 -> 50 (+66.7%) | +20 | 50.0 -> 100.0 (+100.0%) | 20.0 -> 40.0 (+100.0%) | 1.00 -> 1.50 (+50.0%) |"
	# With the vsdr cells leaking in (last one wins) this row would read 1.5 / 1.0 / 33.3%.
	assert_output --partial "| 2 | 10 | 2 | 1 | 1.00 | N/A | 0.50 | N/A | 50.0% |"
}

@test "vsdr report: the ingest WARN fires for the cell whose istiod saw 6 of 10 VirtualServices only, in markdown, text and csv" {
	vsdr_dir
	report markdown "$VRES"
	[ "$(grep -c 'WARN:\*\* istiod ingested fewer VirtualServices' <<<"$output")" -eq 1 ]
	assert_output --partial 'vsdr cell `2|10|2|1|explicit`: istiod VirtualServices 0 -> 6 (+6) < 10 configured'
	report text "$VRES"
	assert_output --partial "WARNING: vsdr cell 2|10|2|1|explicit: istiod VirtualServices 0 -> 6 (+6) < 10 configured"
	report csv "$VRES"
	assert_output --partial "# WARNING: vsdr cell 2|10|2|1|explicit:"
	refute_output --partial "vsdr cell 2|10|2|1|none:"
}

@test "vsdr report charts: vsdr cells get their own series instead of overwriting none" {
	vsdr_dir
	# A second mesh size (1) so the CPU chart renders.
	awk 'BEGIN { FS = OFS = "\t" } !/^#/ && $1 != "timestamp" { $3 = 1 } !/^#/ && $1 != "timestamp" { print }' \
		"$VSDR_FIXTURE" >> "${VRES}/controlplane-fixture-t6.tsv"
	report charts "$VRES"
	assert_output --partial "> Series order: **explicit** **explicit/vsdr** **none** **none/vsdr**."
}

@test "envelope: traffic row prefers the none cell at the peak mesh size, else shows vsdr" {
	source "${ROOT}/tests/lib/capacity.sh"
	source "${ROOT}/tests/lib/envelope.sh"
	source "${ROOT}/tests/lib/platform.sh"  # platform_summary (the Platform / mesh build row)
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

# ---------------------------------------------------------------------------
# istiod replicas

@test "report: istiod replicas that differ by member read 1-3 per cluster; an INFRA_SCHEMA 1 file says its count is the first context's" {
	rm -f "${RES}"/*.tsv
	awk '
		$0 == "# CONTROLPLANE_INFRA_SCHEMA=1" { print "# CONTROLPLANE_INFRA_SCHEMA=2"; next }
		$0 == "# ISTIOD_REPLICAS=3" { print "# ISTIOD_REPLICAS=1-3"; print "# ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=1,mesh-b=3"; next }
		{ print }' "$FIXTURE" > "${RES}/controlplane-fleet.tsv"
	report text
	assert_output --partial "istiod replicas:             1-3 per cluster (varies by cluster)"
	assert_output --partial "istiod replicas by context:  mesh-a=1,mesh-b=3"
	cp "$FIXTURE" "${RES}/controlplane-fleet.tsv"
	report text
	assert_output --partial "istiod replicas:             3 (first context only)"
}

# ---------------------------------------------------------------------------
# Namespace scaling (growth cells)
# fixtures/controlplane_ns_growth.tsv (63 columns; mesh 1, K=2, config-only, M=4):
#   grow (namespace)  N=100,200,400: heap 150/200/300, istiod services 2N+10, CPU-s 2/2/4
#                     (0.02 CPU-s per added namespace)
#   probe none/namespace N=100,200,400: heap 100+N/2, services 2N+12, flat proxy config
#   probe wide        N=100,200,400: heap 0.004 N^2 (exponent 2), proxy config N KB (exponent 1)
#   a restarted copy of the namespace probe at N=400 (heap/services 9999) that no fit may see
#   N=800: SKIPPED_MEM_GUARD rows (grow + 3 probes) that no fit may see
#   outside 50 namespaces at N=400: unlabeled (+0 services), labeled (+100 = 50 x 2)
#   M-sweep at N=400 (outside labeled): 16 measurement pods, wide heap 660 -> 708 (+4 Mi per pod)
#   fresh deploy N=100 namespace: config-only (heap 152, services 210) and pods (heap 260)
#   xDS pushes (per replica, across xDS types): grow 400, probe 10 (120 for wide), so only
#   grow and wide probe windows pass the conv_p99 floor (CONV_FIT_MIN_PUSHES=120)
#   grow window fits of window measurements (onboard_*, push time, PushContext init,
#   conv_p99) leave out the first grow window (N=100, from 0 namespaces)
# Regenerate with care: the numbers below are hand-checked against these rules.
# Column positions used by the variants below: 2 context, 6 namespace_count,
# 7 sidecar_scoping, 22 connected_proxies, 31 istiod_restarted, 34 go_heap_inuse_mi,
# 53 workload_mode, 54 measurement_pods, 57 window_kind.

# growth_variant <awk program>: growth_dir, then rewrite its data rows with the program
# (comment and header lines pass through untouched).
growth_variant() {
	local f
	growth_dir
	f="${GRES}/controlplane-fixture-ns.tsv"
	awk -F'\t' 'BEGIN { OFS = "\t" } /^#/ || $1 == "timestamp" { print; next } '"$1" "$f" > "${f}.tmp"
	mv "${f}.tmp" "$f"
}

growth_dir() {
	GRES="${BATS_TEST_TMPDIR}/g"
	mkdir -p "$GRES"
	cp "$GROWTH" "${GRES}/controlplane-fixture-ns.tsv"
}

# fit_of <json> <scoping> <window> <metric>: [per_100ns, r2, n, exponent, points].
fit_of() {
	jq -c --arg s "$2" --arg w "$3" --arg m "$4" \
		'[.namespace_scaling.fits[] | select(.scoping == $s and .window == $w and .metric == $m)][0] | [.per_100ns, .r2, .n, .exponent, .points]' <<<"$1"
}

@test "growth report json: fits, exponents and points (restarted and skipped rows stay out), the pairings, and the cells not measured named apart from restarts" {
	growth_dir
	report json "$GRES"
	[ "$(fit_of "$output" wide probe heap_inuse_mi)" = '[205.7,0.98,3,2,[[100,40],[200,160],[400,640]]]' ]
	[ "$(fit_of "$output" wide probe proxy_config_kib)" = '[100,1,3,1,[[100,100],[200,200],[400,400]]]' ]
	# The restarted N=400 copy (heap 9999) and the N=800 guard rows never reach a fit.
	[ "$(fit_of "$output" namespace probe heap_inuse_mi)" = '[50,1,3,0.5,[[100,150],[200,200],[400,300]]]' ]
	[ "$(fit_of "$output" namespace probe istiod_services)" = '[200,1,3,0.97,[[100,212],[200,412],[400,812]]]' ]
	[ "$(fit_of "$output" namespace grow onboard_cpu_s_per_ns)" = '[0,null,2,0,[[200,0.02],[400,0.02]]]' ]
	# A single-N curve (the fresh cells) is not fitted.
	[ "$(jq '[.namespace_scaling.fits[] | select(.window == "deploy")] | length' <<<"$output")" = 0 ]
	# Per-cell growth keys; the guard rows count in n_total, not n_valid.
	[ "$(jq -c '[.results[] | select(.namespace_count == 800)] | map([.window_kind, .n_total, .n_valid]) | unique' <<<"$output")" = '[["grow",1,0],["probe",1,0]]' ]
	[ "$(jq -c '.metadata.growth | [.growth_mode, .services_per_namespace, .workload_modes]' <<<"$output")" = '["in-place","2","config-only,pods"]' ]
	# Pairings.
	[ "$(jq -c '.namespace_scaling.pods_vs_config_only | [.missing, .note, (.rows[] | select(.metric == "heap_inuse_mi" or .metric == "istiod_cpu_s") | [.config_only, .pods, .ratio])]' <<<"$output")" = '[null,null,[152,260,1.71],[2.5,6,2.4]]' ]
	[ "$(jq -c '[.namespace_scaling.measurement_pod_sweep.rows[] | select(.cell | test("wide")) | [.measurement_pods, .heap_inuse_mi, .heap_per_added_pod_mi]]' <<<"$output")" = '[[4,660,null],[16,708,4]]' ]
	# PL31: labeled adds X x K = 100 Services, unlabeled adds none; no baseline-less row.
	[ "$(jq -c '[.namespace_scaling.discovery[] | select(.cell | test("namespace")) | [.outside, .delta, .expected_delta, .check]]' <<<"$output")" = '[["none",null,null,"-"],["unlabeled",0,0,"OK"],["labeled",100,100,"OK"]]' ]
	[ "$(jq -c '[.namespace_scaling.fresh_vs_in_place[] | select(.metric == "istiod_services") | [.fresh, .in_place, .diff]]' <<<"$output")" = '[[210,212,"+1.0%"]]' ]
	# Cells not measured: the guard's status rows, not restarts.
	[ "$(jq -c '[.namespace_scaling.not_measured[] | [.n, .window, .scoping, .statuses]] | unique' <<<"$output")" = '[[800,"grow","namespace",["SKIPPED_MEM_GUARD"]],[800,"probe","namespace",["SKIPPED_MEM_GUARD"]],[800,"probe","none",["SKIPPED_MEM_GUARD"]],[800,"probe","wide",["SKIPPED_MEM_GUARD"]]]' ]
	[ "$(jq -c '[.results[] | select(.namespace_count == 800)] | map([.status_rows, .statuses]) | unique' <<<"$output")" = '[[1,["SKIPPED_MEM_GUARD"]]]' ]
	[[ "$(headline)" == *". Of the rows, 4 are status rows of cells skipped or failed, not restarts: SKIPPED_MEM_GUARD 4" ]]
}

@test "growth report: the scaling section, its cells not measured (apart from restarts) and its fit note reach markdown, text and csv" {
	local note="the conv_p99_ms push gate (at least 120 xDS pushes per istiod replica) read pushes_avg from only some of the valid rows of 1 fitted point(s)"
	# p99 at 300 ms (fitted), plus a second valid wide-probe row at N=400 without a push count.
	growth_variant '$10 == 90 { $10 = 300 } $7 == "wide" && $57 == "probe" && $6 == 400 && $31 == "0" && !d++ { print; $13 = "N/A" } { print }'
	report json "$GRES"
	[[ "$(jq -r '.namespace_scaling.fit_note' <<<"$output")" == "${note}, the others having no push count: "*"N=400 (1/2 rows)" ]]
	report markdown "$GRES"
	assert_output --partial "| mesh=1 K=2 config-only | wide | probe | heap_inuse_mi | Mi | 205.7 | -200 | 0.980 | 3 | 2.00 | 100:40 200:160 400:640 |"
	assert_output --partial "| mesh=1 K=2 N=100 namespace (config-only deploy, pods deploy) | heap_inuse_mi | 152 | 260 | 1.71 |"
	assert_output --partial "| mesh=1 K=2 config-only N=400 namespace | labeled | 50 | 912 | 100 | 100 |"
	assert_output --partial "| mesh=1 K=2 config-only | 800 | grow | namespace | 4 | - | SKIPPED_MEM_GUARD | 1 |"
	assert_output --partial "| 0 | 1 (1 status: SKIPPED_MEM_GUARD) | grow |"
	# The restart footnote counts only the restarted row; the status rows get their own line.
	assert_output --partial "> 1 row(s) had istiod restarts during the scrape window"
	assert_output --partial "> 4 row(s) are status rows of cells that were skipped or failed (SKIPPED_MEM_GUARD 4), not restarts"
	assert_output --partial "> **Note:** ${note}"
	report text "$GRES"
	assert_output --partial "mesh=1 K=2 config-only scoping=wide window=probe heap_inuse_mi (Mi): per_100ns=205.7"
	assert_output --partial "mesh=1 K=2 config-only N=800 window=grow scoping=namespace M=4 outside=- status=SKIPPED_MEM_GUARD rows=1"
	assert_output --partial "  NOTE: ${note}"
	report csv "$GRES"
	assert_output --partial "# scaling_fit: series=mesh=1 K=2 config-only scoping=wide window=probe metric=heap_inuse_mi unit=Mi per_100ns=205.7"
	assert_output --partial "# scaling_pods_vs_config_only: cell=mesh=1 K=2 N=100 namespace"
	assert_output --partial "# scaling_not_measured: series=mesh=1 K=2 config-only n=800 window=grow scoping=namespace measurement_pods=4 outside=- status=SKIPPED_MEM_GUARD rows=1"
	assert_output --partial "# scaling_fit: NOTE: ${note}"
}

@test "growth report: the pods-vs-config-only pairing says not measured without a pods cell" {
	growth_variant '$53 != "pods"'
	report json "$GRES"
	[[ "$(jq -r '.namespace_scaling.pods_vs_config_only.missing' <<<"$output")" == "not measured: every valid growth cell is config-only."* ]]
	[ "$(jq -r '.namespace_scaling.measurement_pod_sweep.missing' <<<"$output")" = null ]
}

@test "growth report: a legacy-only report has no scaling section; next to growth cells, the legacy cell keeps its own" {
	report json
	[ "$(jq 'has("namespace_scaling")' <<<"$output")" = false ]
	growth_dir
	cp "$FIXTURE" "${GRES}/controlplane-fixture-t2.tsv"
	# Two runs (two RUN_IDs) in one dir: pooled on purpose.
	report json "$GRES" --allow-multi-run
	# The 51-column file keeps its own cell (legacy defaults) next to the growth cells.
	[ "$(jq -c '[.results[] | select(.services_per_namespace == 0)] | map([.n_total, .window_kind, .workload_mode])' <<<"$output")" = '[[10,"deploy","pods"]]' ]
	[ "$(jq '.namespace_scaling.fits | length > 0' <<<"$output")" = true ]
}

@test "growth report: grow windows fit window deltas per namespace added, from the previous grow step even when it is invalid" {
	growth_dir
	report json "$GRES"
	# No raw window delta is fitted against N for grow windows (each adds N - N_prev).
	[ "$(jq '[.namespace_scaling.fits[] | select(.window == "grow" and (.metric == "istiod_cpu_s" or .metric == "xds_pushes" or .metric == "pushes_per_proxy" or .metric == "push_kb"))] | length' <<<"$output")" = 0 ]
	[ "$(fit_of "$output" namespace grow onboard_pushes_per_ns)" = '[-1,null,2,-1,[[200,4],[400,2]]]' ]
	# Probe windows keep the raw deltas (one namespace each).
	[ "$(fit_of "$output" namespace probe istiod_cpu_s)" = '[0,1,3,0,[[100,0.5],[200,0.5],[400,0.5]]]' ]
	# The N=200 grow restarted: N=400 still divides by 400 - 200 (0.02), not by 400 - 100
	# (0.0133); the first grow window stays out, so one point is left and no slope.
	growth_variant '$6 == 200 && $57 == "grow" { $31 = 1 } { print }'
	report json "$GRES"
	[ "$(fit_of "$output" namespace grow onboard_cpu_s_per_ns)" = '[null,null,1,null,[[400,0.02]]]' ]
}

@test "growth report: the first grow window (it also boots the measurement pods) stays out of grow window-measurement fits" {
	# PL30: the N=100 grow window starts from 0 namespaces, so it also creates and waits for
	# the M measurement pods. Inflate it with that boot work (0.5 CPU-s, 20 pushes, slower
	# pushes and convergence): the per-namespace fits must not move.
	# Convergence p99 of the later windows sits at 300 ms (bucket 100-500, not pinned in the
	# first bucket, so it is fitted).
	growth_variant '$10 == 90 { $10 = 300 } $6 == 100 && $57 == "grow" { $59 += 0.5; $13 += 20; $47 = 9; $48 = 9; $10 = 9000 } { print }'
	report json "$GRES"
	[ "$(fit_of "$output" namespace grow onboard_cpu_s_per_ns)" = '[0,null,2,0,[[200,0.02],[400,0.02]]]' ]
	[ "$(fit_of "$output" namespace grow onboard_pushes_per_ns)" = '[-1,null,2,-1,[[200,4],[400,2]]]' ]
	[ "$(jq -c '[.namespace_scaling.fits[] | select(.window == "grow" and (.metric == "push_time_ms" or .metric == "pushcontext_init_ms" or .metric == "conv_p99_ms")) | [.metric, .points]]' <<<"$output")" = '[["push_time_ms",[[200,1],[400,1]]],["pushcontext_init_ms",[[200,0.5],[400,0.5]]],["conv_p99_ms",[[200,300],[400,300]]]]' ]
	# Gauges keep the first grow window.
	[ "$(fit_of "$output" namespace grow heap_inuse_mi)" = '[50,1,3,0.5,[[100,150],[200,200],[400,300]]]' ]
	[ "$(jq -r '.namespace_scaling.fit_rules.grow_window_fits' <<<"$output")" = skip_first_step ]
}

@test "growth report: conv_p99 fits skip windows below the push floor" {
	growth_dir
	report json "$GRES"
	# The fixture's p99 is 90 ms everywhere: pinned in istiod's first bucket (0-100 ms), an
	# interpolation, so no conv_p99 fit at all.
	[ "$(jq '[.namespace_scaling.fits[] | select(.metric == "conv_p99_ms")] | length' <<<"$output")" = 0 ]
	# At 300 ms (bucket 100-500): namespace/none probes have 10 pushes, so no conv_p99 fit;
	# wide probes (120) and grow (400) keep it (grow without its first window).
	growth_variant '$10 == 90 { $10 = 300 } { print }'
	report json "$GRES"
	[ "$(jq '[.namespace_scaling.fits[] | select(.metric == "conv_p99_ms" and .window == "probe" and .scoping != "wide")] | length' <<<"$output")" = 0 ]
	[ "$(fit_of "$output" wide probe conv_p99_ms)" = '[0,1,3,0,[[100,300],[200,300],[400,300]]]' ]
	[ "$(fit_of "$output" namespace grow conv_p99_ms)" = '[0,null,2,0,[[200,300],[400,300]]]' ]
	[ "$(jq '.namespace_scaling.fit_rules.conv_p99_min_pushes' <<<"$output")" = 120 ]
	[ "$(jq -r '.namespace_scaling.fit_rules.conv_p99_push_count' <<<"$output")" = xds_pushes_per_replica_across_types ]
	# 119 pushes (about 24-30 full pushes short of the floor) is not enough.
	growth_variant '$10 == 90 { $10 = 300 } $7 == "wide" && $57 == "probe" && $13 == 120 { $13 = 119 } { print }'
	report json "$GRES"
	[ "$(jq '[.namespace_scaling.fits[] | select(.metric == "conv_p99_ms" and .window == "probe")] | length' <<<"$output")" = 0 ]
}

@test "growth report: pods vs config-only compares window deltas only within one window kind" {
	# Without the config-only deploy cell, the config-only probe pairs with the pods deploy.
	growth_variant '!($53 == "config-only" && $57 == "deploy")'
	report json "$GRES"
	[ "$(jq -c '[.namespace_scaling.pods_vs_config_only.rows[] | [.metric, .config_only, .pods, .ratio]]' <<<"$output")" = '[["heap_inuse_mi",150,260,1.73],["istiod_cpu_s",null,null,null],["xds_pushes",null,null,null],["pushes_per_proxy",null,null,null],["proxy_config_kib",50,52,1.04],["proxy_envoy_mem_mi",5,8,1.6],["istiod_services",212,210,0.99]]' ]
	# The label names each side's window kind.
	[ "$(jq -r '[.namespace_scaling.pods_vs_config_only.rows[].cell] | unique[]' <<<"$output")" = "mesh=1 K=2 N=100 namespace (config-only probe, pods deploy)" ]
}

@test "growth report: with two istiod replicas, per-replica pushes per proxy and the M-sweep from per-cluster heap" {
	# Every data row becomes two istiod replicas, each serving half the proxies; at M=16 the
	# new measurement pods' scopes land on one replica only (the other keeps its M=4 heap).
	growth_variant '$2 != "mesh-a" { print; next } { $22 = $22 / 2; print; if ($54 == 16 && $7 == "wide") $34 = 660; else if ($54 == 16 && $7 == "namespace") $34 = 320; print }'
	report json "$GRES"
	# 10 pushes per replica / 3 proxies per replica (the cluster has 6).
	[ "$(fit_of "$output" namespace probe pushes_per_proxy)" = '[0,1,3,0,[[100,3.333],[200,3.333],[400,3.333]]]' ]
	# Per replica the heap grows 2 Mi per pod (cost / 2); per cluster 4 Mi, the scope cost.
	[ "$(jq -c '[.namespace_scaling.measurement_pod_sweep.rows[] | select(.cell | test("wide")) | [.measurement_pods, .heap_inuse_mi, .heap_inuse_cluster_mi, .istiod_pods_per_cluster, .heap_per_added_pod_mi]]' <<<"$output")" = '[[4,660,1320,2,null],[16,684,1368,2,4]]' ]
	[ "$(jq -r '.namespace_scaling.measurement_pod_sweep.istiod_replicas' <<<"$output")" = 1 ]
}

@test "growth report: a base dir of two sweeps is refused without --allow-multi-run, naming each with the command that reports it alone; pooled, it lists every run and names the runs behind each pods-vs-config-only side" {
	local base a b
	base="${BATS_TEST_TMPDIR}/base"
	a="${base}/sweep-20261013T100000Z-111"
	b="${base}/sweep-20261013T110000Z-222"
	mkdir -p "$a" "$b"
	# Sweep 1 holds the config-only cells; sweep 2 the pods calibration cell, measured on
	# another Istio version from a dirty tree (PL2: both must surface).
	awk -F'\t' '/^# RUN_ID=/ { print "# RUN_ID=20261013T100000Z-111"; next }
		/^#/ || $1 == "timestamp" || $53 != "pods"' "$GROWTH" > "${a}/controlplane-20261013T100000Z-111.tsv"
	awk -F'\t' '/^# RUN_ID=/ { print "# RUN_ID=20261013T110000Z-222"; next }
		/^# ISTIO_VERSION=/ { print "# ISTIO_VERSION=1.31.0"; next }
		/^# HARNESS_SHA=/ { print "# HARNESS_SHA=abc1234-dirty"; next }
		/^#/ || $1 == "timestamp" || $53 == "pods"' "$GROWTH" > "${b}/controlplane-20261013T110000Z-222.tsv"
	run --separate-stderr "$REPORT" --results-dir "$base" --format json
	assert_failure 1
	[ -z "$output" ]
	[[ "$stderr" == *"error: ${base} holds 2 runs"* ]]
	# Newest first, each with the command that reports it alone.
	[[ "$stderr" == *"sweep-20261013T110000Z-222:"$'\n'"    ${REPORT} --results-dir '${b}'"$'\n'"  sweep-20261013T100000Z-111:"$'\n'"    ${REPORT} --results-dir '${a}'"* ]]
	report json "$base" --allow-multi-run
	[ "$(jq -c '.pooled_runs' <<<"$output")" = \
		'{"runs":2,"run_ids":["sweep-20261013T100000Z-111","sweep-20261013T110000Z-222"],"harness_sha":["fixture","abc1234-dirty"],"istio_version":["1.30.5","1.31.0"]}' ]
	[ "$(jq -c '.metadata | [.run_id, .run_ids, .istio_version, .istio_versions, .harness_sha, .harness_shas, .files_consumed]' <<<"$output")" = \
		'["multiple",["20261013T100000Z-111","20261013T110000Z-222"],"mixed:1.30.5,1.31.0",["1.30.5","1.31.0"],"mixed:fixture,abc1234-dirty",["fixture","abc1234-dirty"],2]' ]
	[ "$(jq -c '[.namespace_scaling.pods_vs_config_only.rows[] | select(.metric == "heap_inuse_mi") | [.config_only_run_ids, .pods_run_ids, .ratio]]' <<<"$output")" = \
		'[[["20261013T100000Z-111"],["20261013T110000Z-222"],1.71]]' ]
	# The opt-in still warns.
	[[ "$stderr" == *"warning: --allow-multi-run: this report pools 2 runs from ${base} (sweep-20261013T100000Z-111,sweep-20261013T110000Z-222)"* ]]
	[ "$(jq -r '[.namespace_scaling.pods_vs_config_only.rows[].cell] | unique[]' <<<"$output")" = "mesh=1 K=2 N=100 namespace (config-only deploy run=20261013T100000Z-111, pods deploy run=20261013T110000Z-222)" ]
	# One sweep: plain scalars, one-element lists, no warning.
	report json "$a"
	[ "$(jq -c '.metadata | [.run_id, .run_ids, .istio_version, .harness_shas, .provenance_warning]' <<<"$output")" = \
		'["20261013T100000Z-111",["20261013T100000Z-111"],"1.30.5",["fixture"],null]' ]
	[[ "$stderr" != *"pools"* && "$stderr" != *"WARNING"* ]]
}

# series_sweep <base> <run_id> <awk program>: base/sweep-<run_id>/controlplane-<run_id>.tsv
# from the growth fixture, its RUN_ID replaced and its data rows rewritten by the program
# (comment and header lines pass through).
series_sweep() {
	local d="$1/sweep-$2"
	mkdir -p "$d"
	awk -F'\t' -v rid="$2" 'BEGIN { OFS = "\t" } /^# RUN_ID=/ { print "# RUN_ID=" rid; next }
		/^#/ || $1 == "timestamp" { print; next } '"$3" "$GROWTH" > "${d}/controlplane-$2.tsv"
}

# grow_fits <json> <metric>: [run_id, n, points] of every namespace-scoping grow fit of the metric.
grow_fits() {
	jq -c --arg m "$2" '[.namespace_scaling.fits[] | select(.scoping == "namespace" and .window == "grow" and .metric == $m) | [.run_id, .n, .points]]' <<<"$1"
}

@test "growth report: a base dir with a smoke and a main series fits each series on its own, and labels each series' figures with its run" {
	# Smoke series (N=10,20: the fixture's N=100,200 grow and probe cells scaled down) and
	# the main series (the fixture, N=100,200,400) in one results base. Pooled, the main
	# series' first grow (N=100) would get N_prev=20 from the smoke ladder and enter the
	# onboarding fit as 2 CPU-s / 80 namespaces, and both ladders would share one curve.
	local base="${BATS_TEST_TMPDIR}/series" smoke=20261013T090000Z-101 main=20261013T110000Z-222
	series_sweep "$base" "$smoke" '$2 == "mesh-a" && $31 == 0 && $55 == 0 && $54 == 4 && ($57 == "grow" || $57 == "probe") && ($6 == 100 || $6 == 200) { $6 = $6 / 10; $4 = $4 / 10; print }'
	series_sweep "$base" "$main" '{ print }'
	report json "$base" --allow-multi-run
	# Each grow ladder starts at its own first step: the smoke N=20 grow added 10 namespaces
	# (2 CPU-s / 10), the main series keeps its single-run fit (2 / 100, 4 / 200).
	[ "$(grow_fits "$output" onboard_cpu_s_per_ns)" = "[[\"${smoke}\",1,[[20,0.2]]],[\"${main}\",2,[[200,0.02],[400,0.02]]]]" ]
	[ "$(grow_fits "$output" onboard_pushes_per_ns)" = "[[\"${smoke}\",1,[[20,40]]],[\"${main}\",2,[[200,4],[400,2]]]]" ]
	# Gauges: one curve per series, never one curve over N=10..400.
	[ "$(grow_fits "$output" heap_inuse_mi)" = "[[\"${smoke}\",2,[[10,150],[20,200]]],[\"${main}\",3,[[100,150],[200,200],[400,300]]]]" ]
	[ "$(jq -c --arg r "$main" '[.namespace_scaling.fits[] | select(.run_id == $r and .scoping == "wide" and .metric == "heap_inuse_mi")][0] | [.series, .per_100ns, .points]' <<<"$output")" = \
		"[\"mesh=1 K=2 config-only run=${main}\",205.7,[[100,40],[200,160],[400,640]]]" ]
	# No fit mixes the two ladders.
	[ "$(jq '[.namespace_scaling.fits[] | select(([.points[][0]] | min) < 100 and ([.points[][0]] | max) >= 100)] | length' <<<"$output")" = 0 ]
	# Cells carry their series run; the main series' pairings and skipped cells keep theirs.
	[ "$(jq -c '[.results[] | select(.window_kind == "grow" and .services_per_namespace == 2) | [.namespace_count, .series_run_id]] | sort' <<<"$output")" = \
		"[[10,\"${smoke}\"],[20,\"${smoke}\"],[100,\"${main}\"],[200,\"${main}\"],[400,\"${main}\"],[800,\"${main}\"]]" ]
	[ "$(jq -c '[.namespace_scaling.not_measured[] | .run_id] | unique' <<<"$output")" = "[\"${main}\"]" ]
	[ "$(jq -c '[.namespace_scaling.measurement_pod_sweep.rows[] | .run_id] | unique' <<<"$output")" = "[\"${main}\"]" ]
	[ "$(jq -c '[.namespace_scaling.discovery[] | .run_id] | unique' <<<"$output")" = "[\"${main}\"]" ]
	# Every format prints these labels.
	[ "$(jq -c '[.namespace_scaling.fits[] | select(.scoping == "namespace" and .window == "grow" and .metric == "heap_inuse_mi") | .series]' <<<"$output")" = \
		"[\"mesh=1 K=2 config-only run=${smoke}\",\"mesh=1 K=2 config-only run=${main}\"]" ]
	[ "$(jq -c '[.namespace_scaling.not_measured[] | .series] | unique' <<<"$output")" = "[\"mesh=1 K=2 config-only run=${main}\"]" ]
}

@test "growth report: two series that share an N keep separate cells and ladders" {
	# Series A grows 50 -> 100 (the fixture's grow cells at N=100,200 halved); series B is
	# the fixture (100 -> 200 -> 400). At N=100 A's grow added 50 namespaces after N=50, B's
	# is its first step: pooled into one cell, both would read N_prev=50 and average.
	local base="${BATS_TEST_TMPDIR}/shared" a=20261013T090000Z-101 b=20261013T110000Z-222
	series_sweep "$base" "$a" '$2 == "mesh-a" && $31 == 0 && $55 == 0 && $57 == "grow" && ($6 == 100 || $6 == 200) { $6 = $6 / 2; $4 = $4 / 2; print }'
	series_sweep "$base" "$b" '{ print }'
	report json "$base" --allow-multi-run
	[ "$(jq -c '[.results[] | select(.window_kind == "grow" and .namespace_count == 100) | [.series_run_id, .n_total, .go_heap_inuse_mi.avg]]' <<<"$output")" = \
		"[[\"${a}\",1,200],[\"${b}\",1,150]]" ]
	[ "$(grow_fits "$output" onboard_cpu_s_per_ns)" = "[[\"${a}\",1,[[100,0.04]]],[\"${b}\",2,[[200,0.02],[400,0.02]]]]" ]
	[ "$(grow_fits "$output" heap_inuse_mi)" = "[[\"${a}\",2,[[50,150],[100,200]]],[\"${b}\",3,[[100,150],[200,200],[400,300]]]]" ]
}

# ---------------------------------------------------------------------------
# Schema 66: gateway memory, leftover namespaces, CPU window figures

# growth66 [leftover]: the growth fixture widened to CONTROLPLANE_SCHEMA=66: gateway
# physical heap 2 x and working set 3 x the allocated figure, gateway clusters x 8 (so a
# point passes 1000), and <leftover> (default 0) leftover test namespaces per row.
growth66() {
	local f
	growth_dir
	f="${GRES}/controlplane-fixture-ns.tsv"
	awk -F'\t' -v lo="${1:-0}" 'BEGIN { OFS = "\t" }
		/^# CONTROLPLANE_SCHEMA=/ { print "# CONTROLPLANE_SCHEMA=66"; next }
		/^#/ { print; next }
		$1 == "timestamp" { print $0, "gateway_physical_mi_max", "gateway_ws_mi_max", "leftover_test_namespaces"; next }
		{ g = $62; if (g ~ /^[0-9]+$/) { p = 2 * g; w = 3 * g } else { p = "N/A"; w = "N/A" }
		  if ($61 ~ /^[0-9]+$/) $61 = $61 * 8
		  print $0, p, w, ($2 ~ /^[A-Z_]+$/ ? "N/A" : lo) }' "$f" > "${f}.tmp"
	mv "${f}.tmp" "$f"
}

@test "report: a 66-column file adds gateway physical / working set and leftover namespaces" {
	local r
	growth66 7
	report json "$GRES"
	r="$(jq -c '[.results[] | select(.window_kind == "probe" and .namespace_count == 400 and .sidecar_scoping == "wide" and .n_valid > 0)][0]' <<<"$output")"
	[ "$(jq -c '[.gateway_mem_mi_max, .gateway_physical_mi_max, .gateway_ws_mi_max, .leftover_test_namespaces_max]' <<<"$r")" != '[null,null,null,null]' ]
	[ "$(jq '.gateway_ws_mi_max / .gateway_mem_mi_max' <<<"$r")" = 3 ]
	[ "$(jq '.leftover_test_namespaces_max' <<<"$r")" = 7 ]
	# Both new gateway figures are fitted; JSON points never carry an exponent string.
	[ "$(jq '[.namespace_scaling.fits[] | select(.metric == "gateway_ws_mi" or .metric == "gateway_physical_mi")] | length > 0' <<<"$output")" = true ]
	# 7 leftover namespaces is under the default threshold (100): no warning.
	[[ "$(jq -r '.metadata.data_warnings | join(" ")' <<<"$output")" != *"leftover controlplane-test namespaces"* ]]
	report markdown "$GRES"
	refute_output --regexp '[0-9]e\+0[0-9]'
}

@test "report: leftover test namespaces above LEFTOVER_NS_WARN are a data warning" {
	growth66 2500
	report json "$GRES"
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == *"up to 2500 leftover controlplane-test namespaces"* ]]
}

@test "report: a RETIRE_FAILED row is listed as not measured and is a data warning" {
	growth_variant '{ print } $2 == "SKIPPED_MEM_GUARD" && !done { done = 1; $1 = "2026-10-13T12:20:00+00:00"; $2 = "RETIRE_FAILED"; $6 = 400; $57 = "retire"; print }'
	report json "$GRES"
	[ "$(jq '[.namespace_scaling.not_measured[] | select(.statuses == ["RETIRE_FAILED"])] | length' <<<"$output")" = 1 ]
	[[ "$(jq -r '.metadata.data_warnings[0]' <<<"$output")" == "RETIRE_FAILED (N=400"* ]]
}

@test "report: CPU peak and the window average are labelled apart; sizes in MiB; files relative" {
	growth66
	report markdown "$GRES"
	assert_output --partial "| cpu_peak (m) | cpu_avg (m) | rss_peak (Mi) |"
	assert_output --partial "| cfg_dump_avg (MiB) |"
	refute_output --partial "cpu_avg (m) | mem_avg (Mi)"
	refute_output --partial "(MB)"
	refute_output --partial "(KB)"
	assert_output --partial "Files: controlplane-fixture-ns.tsv (in results dir g)"
	refute_output --partial "$BATS_TEST_TMPDIR"
	report json "$GRES"
	# cpu_avg = istiod_cpu_s_delta x 1000 / scrape_window_sec, never the peak column.
	[ "$(jq '[.results[] | select(.istiod_cpu_avg_m != null)] | length > 0' <<<"$output")" = true ]
	[ "$(jq '[.results[] | select(.istiod_cpu_avg_m != null and .istiod_cpu_avg_m > .istiod_cpu_peak_m.avg)] | length' <<<"$output")" = 0 ]
	# Two-point fits print no R² (2 points fit any line exactly).
	[ "$(jq '[.namespace_scaling.fits[] | select(.n == 2 and .r2 != null)] | length' <<<"$output")" = 0 ]
}

@test "report: the SLA verdict reads istiod CPU from the window peak (cpu_peak), not only the end-of-window top snapshot" {
	local tsv="${RES}/controlplane-fixture-t2.tsv"
	cp_tsv "$tsv" "mesh-a=3/3,mesh-b=3/3" 3
	# One row's window peak at 1900m of its 2000m limit; every top snapshot stays at 10 %.
	awk -F'\t' -v OFS='\t' -v last="$(wc -l < "$tsv")" 'NR == last { $32 = 1900 } { print }' "$tsv" > "${tsv}.new"
	mv "${tsv}.new" "$tsv"
	report json
	[ "$(jq -c '.metadata.achieved_scale | [.istiod_cpu_peak_pct_of_limit_max, .istiod_cpu_pct_of_limit_max]' <<<"$output")" = '["95","10"]' ]
	[ "$(verdict)" = FAIL ]
	[[ "$(headline)" == "peak utilization 95% >= 90%"* ]]
}

@test "envelope: config-only growth cells have no endpoints; CPU from the window peak" {
	growth66
	source "${ROOT}/tests/lib/capacity.sh"
	source "${ROOT}/tests/lib/envelope.sh"
	source "${ROOT}/tests/lib/platform.sh"  # platform_summary (the Platform / mesh build row)
	run --separate-stderr render_scale_envelope "$GRES" "$REPORT" "mesh-a" false
	assert_success
	assert_output --partial "| **Total endpoints in mesh** | N/A (config-only: Services without pods;"
	assert_output --partial "| Workload replicas / service | N/A (config-only) |"
	assert_output --partial "| **istiod CPU (window peak)** |"
	assert_output --partial "| istiod CPU (kubectl top at window end) |"
}

@test "a valid row without a push count: a data warning, and pushes_avg with got of n_valid in json, text and csv" {
	local r="${BATS_TEST_TMPDIR}/sweep-nopush"
	mkdir -p "$r"
	# The first valid row's xds_pushes_delta (column 13) is N/A.
	awk -F'\t' -v OFS='\t' '!/^#/ && $1 != "timestamp" && !n++ { $13 = "N/A" } { print }' "$FIXTURE" > "${r}/controlplane-fixture-t2.tsv"
	report json "$r"
	[ "$(jq -c '[.results[0].n_valid, .results[0].xds_pushes_n, .results[0].xds_pushes_avg]' <<<"$output")" = '[9,8,100]' ]
	[[ "$(jq -r '.metadata.data_warnings | join(" ")' <<<"$output")" == *"1 valid row(s) of 1 cell(s) have no xDS push count"* ]]
	report text "$r"
	assert_output --partial "xDS pushes avg=100 (from 8/9 valid rows: the others have no push count)"
	report csv "$r"
	[ "$(grep -v '^#' <<<"$output" | sed -n 2p | awk -F, '{ print $NF }')" = 8 ]
}

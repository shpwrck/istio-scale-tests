#!/usr/bin/env bats
# Dataplane suite through its real entrypoints: the 004 "Local baseline" verdict (computed once,
# rendered by each format's own code), its placeholders and units, the platform record's wiring
# into every format; the 002 row status (QPS_SHORTFALL, ERROR_RATE_HIGH, N/A where nothing was
# measured) against a stub kubectl that serves fortio JSON fixtures; 003's placeholder; and the
# 001/002/003 flags. The platform record's merge and warnings are platform.bats'.

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr

REPORT="${ROOT}/tests/dataplane/004-report-results.sh"
PROBE="${ROOT}/tests/dataplane/002-run-latency-probe.sh"
SWEEP="${ROOT}/tests/dataplane/003-run-sweep.sh"
SETUP="${ROOT}/tests/dataplane/001-setup-dataplane-test.sh"
FX="${ROOT}/tests/lib/test/fixtures"
HDR=$'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class'

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
	# A kubectl stub that logs every call: dry-runs must not reach a cluster.
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log"
	: > "$STUB_LOG"
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case " $* " in
*" exec "*)
	url="${*: -1}"
	case "$url" in
	*"dataplane-server-${STUB_SOURCE:-ctx-a}."*) cat "$STUB_LOCAL_JSON" ;;
	*) cat "$STUB_REMOTE_JSON" ;;
	esac
	;;
*" get deploy dataplane-server "*) printf '%s' "${STUB_SERVER_REPLICAS-1/1}" ;;
*" get pod -l app=dataplane-client "*) printf 'dataplane-client-0\t\tTrue' ;;
*" get pod dataplane-client-0 "*) : ;;  # after a failed exec: the client pod is gone, so no wait
*" get pods "*) : ;;  # no Running istiod pod
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*) exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;  # the pin
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
}

# row <mesh> <src> <tgt> <qps> <qps_actual> <status> <pct_200> <restarted> <class>
row() {
	printf 'r1\t%s\t%s\t%s\t%s\t%s\t8\t30\t2.0\t2.5\t5.0\t11.0\t12.5\t%s\t%s\t%s\t%s\n' "$@"
}

# tsv <file> <preamble lines...>; rows come on stdin. NO_PLATFORM=1: a legacy file, without
# the platform record every writer adds now.
tsv() {
	local f="$1" l
	shift
	{
		for l in "$@"; do echo "# $l"; done
		[[ -n "${NO_PLATFORM:-}" ]] || platform_fixture_lines
		echo "$HDR"
		cat
	} > "$f"
}

# fresh: an empty results dir.
fresh() { rm -rf "$RES" && mkdir -p "$RES"; }

# --- 004: Local baseline verdict ---

@test "004 Local baseline: a cell's verdict is its local rows' (DROPPED, DEGRADED n_valid=1/2, OK), its reason why (saturated, istiod_restarted, istiod_restart_unknown), each file read with its own server_replicas and MIN_QPS_RATIO (PL26); a dropped remote leaves the local verdict alone and still warns" {
	# 20c-shaped: ERROR_RATE_HIGH at 686/1000 is the local server's saturation.
	tsv "${RES}/latency-a.tsv" "RUN_ID=r1" "SERVER_REPLICAS=ctx-a=1/1,ctx-b=1/1" <<-EOF
	$(row 2 ctx-a ctx-a 10 10 OK 1 0 local)
	$(row 2 ctx-a ctx-a 1000 686.2 ERROR_RATE_HIGH 0.93 0 local)
	$(row 2 ctx-a ctx-b 1000 999.8 OK 1 0 remote)
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_success
	assert_output --partial "Local baseline: DROPPED mesh_size=2 qps_target=1000 n_valid=0/1 reason=saturated qps_actual=686.2 (68.6% of target) server_replicas=1/1 remote=1/1 statuses=ERROR_RATE_HIGH=1"
	refute_output --partial "qps_target=10 "
	# Two probes of one sweep (its sweep-* dir is one run, whatever their RUN_IDs): one valid
	# and one QPS_SHORTFALL repetition.
	fresh
	mkdir -p "${RES}/sweep-t"
	tsv "${RES}/sweep-t/latency-e1.tsv" "RUN_ID=r1" "SERVER_REPLICAS=ctx-a=2/2" "MIN_QPS_RATIO=0.95" <<-EOF
	$(row 1 ctx-a ctx-a 1000 999.0 OK 1 0 local)
	EOF
	tsv "${RES}/sweep-t/latency-e2.tsv" "RUN_ID=r2" "SERVER_REPLICAS=ctx-a=2/2" "MIN_QPS_RATIO=0.95" <<-EOF
	$(row 1 ctx-a ctx-a 1000 900.0 QPS_SHORTFALL 1 0 local)
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "Local baseline: DEGRADED mesh_size=1 qps_target=1000 n_valid=1/2 reason=saturated qps_actual=900 (90.0% of target) server_replicas=2/2 remote=none statuses=OK=1,QPS_SHORTFALL=1"
	# Per file, not from the first TSV: ratio 0.5 makes 700/1000 no shortfall, so the reason is
	# the restart; a restart that could not be checked is named apart from one.
	fresh
	mkdir -p "${RES}/sweep-t"
	tsv "${RES}/sweep-t/latency-g1.tsv" "RUN_ID=r1" "SERVER_REPLICAS=ctx-a=1/1" "MIN_QPS_RATIO=0.95" <<-EOF
	$(row 1 ctx-a ctx-a 1000 700 QPS_SHORTFALL 1 0 local)
	EOF
	tsv "${RES}/sweep-t/latency-g2.tsv" "RUN_ID=r2" "SERVER_REPLICAS=ctx-a=2/2,ctx-b=2/2" "MIN_QPS_RATIO=0.5" <<-EOF
	$(row 2 ctx-a ctx-a 1000 700 OK 1 1 local)
	EOF
	tsv "${RES}/sweep-t/latency-g3.tsv" "RUN_ID=r3" "SERVER_REPLICAS=ctx-a=2/2" "MIN_QPS_RATIO=0.95" <<-EOF
	$(row 3 ctx-a ctx-a 100 100 OK 1 unknown local)
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "mesh_size=1 qps_target=1000 n_valid=0/1 reason=saturated qps_actual=700 (70.0% of target) server_replicas=1/1 "
	assert_output --partial "mesh_size=2 qps_target=1000 n_valid=0/1 reason=istiod_restarted qps_actual=700 (70.0% of target) server_replicas=2/2 "
	assert_output --partial "Local baseline: DROPPED mesh_size=3 qps_target=100 n_valid=0/1 reason=istiod_restart_unknown"
	# A remote that failed: the local cell is OK, and the global warning names the dropped row.
	fresh
	tsv "${RES}/latency-f.tsv" "RUN_ID=r1" "SERVER_REPLICAS=ctx-a=2/2,ctx-b=2/2" "MIN_QPS_RATIO=0.95" <<-EOF
	$(row 2 ctx-a ctx-a 1000 999.0 OK 1 0 local)
	$(row 2 ctx-a ctx-b 1000 0 FAILED N/A 0 remote)
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "Local baseline: OK at every QPS level (1 cell, top qps_target=1000"
	assert_output --partial "WARNING: 2 total / 1 valid rows"
	refute_output --partial "DROPPED"
}

@test "004 Local baseline in every format: a dropped cell (QPS_SHORTFALL with all 200s) in json, csv and charts; OK at every QPS level in all five" {
	tsv "${RES}/latency-b.tsv" "RUN_ID=r1" "SERVER_REPLICAS=ctx-a=1/1,ctx-b=1/1" "MIN_QPS_RATIO=0.95" <<-EOF
	$(row 2 ctx-a ctx-a 1000 686.2 QPS_SHORTFALL 1 0 local)
	$(row 2 ctx-a ctx-b 1000 999.8 OK 1 0 remote)
	EOF
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -c '.local_baseline | [.verdict, .min_qps_ratio, (.cells[0] | .reason, .qps_ratio < 0.95, .remote_n_valid, .statuses.QPS_SHORTFALL)]' <<<"$output")" = \
		'["dropped",0.95,"saturated",true,1,1]' ]
	run "$REPORT" --results-dir "$RES" --format csv
	assert_output --partial "# LOCAL_BASELINE=dropped"
	assert_output --partial "# LOCAL_BASELINE_CELL=2:1000:dropped:saturated"
	run "$REPORT" --results-dir "$RES" --format charts
	assert_output --partial "> Local baseline missing at mesh 2 / QPS 1000 (saturated); its point is drawn as 0."
	fresh
	{
		for q in 10 100 500 1000; do
			row 2 ctx-a ctx-a "$q" "$q" OK 1 0 local
			row 2 ctx-a ctx-b "$q" "$q" OK 1 0 remote
		done
	} | tsv "${RES}/latency-c.tsv" "RUN_ID=r1" "SERVER_REPLICAS=ctx-a=2/2,ctx-b=2/2" "MIN_QPS_RATIO=0.95"
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "Local baseline: OK at every QPS level (4 cells, top qps_target=1000, min_qps_ratio=0.95)"
	refute_output --partial "DROPPED"
	run "$REPORT" --results-dir "$RES" --format md
	assert_output --partial "- Local baseline: OK at every QPS level (4 cells, top qps_target=1000"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	[ "$(jq -c '.local_baseline | [.verdict, (.cells | length), .cells[3].server_replicas]' <<<"$output")" = '["ok",4,"2/2"]' ]
	run "$REPORT" --results-dir "$RES" --format csv
	assert_output --partial "# LOCAL_BASELINE=ok"
	refute_output --partial "LOCAL_BASELINE_CELL"
	run "$REPORT" --results-dir "$RES" --format charts
	refute_output --partial "Local baseline missing"
}

@test "004: a placeholder beside measured rows of the same mesh size is named in every format, and counts in the summary total (PL15); with none, none is named" {
	# REPETITIONS>1 with one failed rep, or a probe that died after some QPS levels:
	# mesh 2 has valid local and remote rows AND a PROBE_FAILED placeholder, so the
	# Local baseline is OK and only the placeholder lines can name the failure.
	tsv "${RES}/latency-a.tsv" "RUN_ID=r1" "SERVER_REPLICAS=ctx-a=2/2,ctx-b=2/2" "MIN_QPS_RATIO=0.95" <<-EOF
	$(row 2 ctx-a ctx-a 10 10 OK 1 0 local)
	$(row 2 ctx-a ctx-b 10 10 OK 1 0 remote)
	EOF
	tsv "${RES}/latency-zzfail-ms2.tsv" "SERVER_REPLICAS=unknown" "MIN_QPS_RATIO=0.95" <<-EOF
	$(printf 'r1\t2\tctx-a\tN/A\t0\tN/A\t8\t30\tN/A\tN/A\tN/A\tN/A\tN/A\tPROBE_FAILED\tN/A\tunknown\tna')
	$(printf 'r1\t3\tctx-a\tN/A\t0\tN/A\t8\t30\tN/A\tN/A\tN/A\tN/A\tN/A\tSETUP_FAILED\tN/A\tunknown\tna')
	$(printf 'r1\t3\tctx-a\tN/A\t0\tN/A\t8\t30\tN/A\tN/A\tN/A\tN/A\tN/A\tPROBE_FAILED\tN/A\tunknown\tna')
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_success
	assert_output --partial "WARNING: 5 total / 2 valid rows — 3 dropped (poisoned)."
	assert_line "Placeholder rows (no table cell): mesh_size=2 PROBE_FAILED=1"
	assert_line "Placeholder rows (no table cell): mesh_size=3 SETUP_FAILED=1,PROBE_FAILED=1"
	assert_output --partial "Local baseline: MISSING mesh_size=3 reason=setup_failed,probe_failed (no local rows)"
	refute_output --partial "MISSING mesh_size=2"
	run "$REPORT" --results-dir "$RES" --format md
	assert_line "- Placeholder rows (no table cell): mesh_size=2 PROBE_FAILED=1"
	refute_output --partial "| na |"
	run "$REPORT" --results-dir "$RES" --format csv
	assert_line "# PLACEHOLDER=2:PROBE_FAILED:1"
	assert_line "# PLACEHOLDER=3:SETUP_FAILED:1"
	assert_line "# PLACEHOLDER=3:PROBE_FAILED:1"
	assert_line "# ROWS n_total=5 n_valid=2 n_dropped=3 n_skipped_unreachable=0 n_placeholder=3"
	refute_output --partial ",na,"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	[ "$(jq -c '.summary.placeholders' <<<"$output")" = '[{"mesh_size":2,"status":"PROBE_FAILED","n_rows":1},{"mesh_size":3,"status":"SETUP_FAILED","n_rows":1},{"mesh_size":3,"status":"PROBE_FAILED","n_rows":1}]' ]
	# The cells plus the placeholders add up to the summary total.
	[ "$(jq '([.results[].n_total] | add) + .summary.n_placeholder == .summary.n_total' <<<"$output")" = true ]
	run "$REPORT" --results-dir "$RES" --format charts
	assert_output --partial "> Placeholder rows (no table cell): mesh_size=2 PROBE_FAILED=1"
	rm "${RES}/latency-zzfail-ms2.tsv"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	[ "$(jq -c '.summary | [.n_placeholder, .placeholders]' <<<"$output")" = '[0,[]]' ]
}

@test "004: saturated local + one OK and one UNREACHABLE remote -> remote=1/1, not 1/2 (PL31)" {
	# ctx-c got no load (reach check UNREACHABLE), so it must not count as a remote
	# that dropped: the one remote that ran hit its target, so the local server is
	# the bottleneck. Row shapes as 002 writes them (emit_unreachable_rows).
	tsv "${RES}/latency-u.tsv" "RUN_ID=r1" "SERVER_REPLICAS=ctx-a=2/2,ctx-b=2/2,ctx-c=2/2" "MIN_QPS_RATIO=0.95" <<-EOF
	$(row 3 ctx-a ctx-a 1000 800.0 QPS_SHORTFALL 1 0 local)
	$(row 3 ctx-a ctx-b 1000 999.0 OK 1 0 remote)
	$(printf 'r1\t3\tctx-a\tctx-c\t1000\t0\t8\t30\tN/A\tN/A\tN/A\tN/A\tN/A\tUNREACHABLE\t0\t0\tremote')
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_success
	assert_output --partial "Local baseline: DROPPED mesh_size=3 qps_target=1000 n_valid=0/1 reason=saturated qps_actual=800 (80.0% of target) server_replicas=2/2 remote=1/1 remote_unreachable=1 statuses=QPS_SHORTFALL=1"
	refute_output --partial "remote=1/2"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	[ "$(jq -r '.local_baseline.cells[0] | "\(.remote_n_valid)/\(.remote_n_total) \(.remote_unreachable)"' <<<"$output")" = "1/1 1" ]
	# Only the unreachable remote at that cell: remote=none, still named.
	tsv "${RES}/latency-u.tsv" "RUN_ID=r1" "SERVER_REPLICAS=ctx-a=2/2" "MIN_QPS_RATIO=0.95" <<-EOF
	$(row 2 ctx-a ctx-a 1000 800.0 QPS_SHORTFALL 1 0 local)
	$(printf 'r1\t2\tctx-a\tctx-c\t1000\t0\t8\t30\tN/A\tN/A\tN/A\tN/A\tN/A\tUNREACHABLE\t0\t0\tremote')
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "server_replicas=2/2 remote=none remote_unreachable=1 statuses=QPS_SHORTFALL=1"
}

@test "004: a TSV from before MIN_QPS_RATIO: an OK row below the ratio is UNCHECKED (never 'OK at every QPS level') or DEGRADED saturated_unflagged, still counted; rows at the target are OK, saying the report applied the ratio (DATAPLANE_MIN_QPS_RATIO, else 0.95); server_replicas unknown" {
	# The June failure mode: a saturated local run that returned only 200s was OK.
	tsv "${RES}/latency-l.tsv" "RUN_ID=r1" <<-EOF
	$(row 2 ctx-a ctx-a 10 10 OK 1 0 local)
	$(row 2 ctx-a ctx-a 1000 686.2 OK 1 0 local)
	$(row 2 ctx-a ctx-b 1000 999.8 OK 1 0 remote)
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_success
	refute_output --partial "OK at every QPS level"
	assert_output --partial "Local baseline: UNCHECKED mesh_size=2 qps_target=1000 n_valid=1/1 reason=saturated_unflagged qps_actual=686.2 (68.6% of target) server_replicas=unknown remote=1/1 statuses=OK=1 ok_below_ratio=1"
	refute_output --partial "qps_target=10 "
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	[ "$(jq -c '.local_baseline | [.verdict, .files_without_min_qps_ratio, .cells[1].reason, .cells[1].ok_below_ratio, .cells[0].verdict]' <<<"$output")" = \
		'["unchecked",1,"saturated_unflagged",1,"ok"]' ]
	# n_valid is unchanged: the row still counts and is averaged.
	[ "$(jq -r '.results[] | select(.target_class == "local" and .qps_target == 1000) | "\(.n_valid) \(.avg_actual_qps)"' <<<"$output")" = "1 686.2" ]
	[ "$(jq -r '.summary.n_valid' <<<"$output")" = 3 ]
	run "$REPORT" --results-dir "$RES" --format csv
	assert_output --partial "# LOCAL_BASELINE=unchecked"
	assert_output --partial "# LOCAL_BASELINE_FILES_WITHOUT_MIN_QPS_RATIO=1"
	assert_output --partial "# LOCAL_BASELINE_CELL=2:1000:unchecked:saturated_unflagged"
	run "$REPORT" --results-dir "$RES" --format charts
	assert_output --partial "> Local point at mesh 2 / QPS 1000 includes 1 OK row(s) below min_qps_ratio x target (saturated_unflagged, TSV without MIN_QPS_RATIO)."
	# A short OK row beside a dropped one: DEGRADED.
	fresh
	tsv "${RES}/latency-m.tsv" "RUN_ID=r1" <<-EOF
	$(row 1 ctx-a ctx-a 1000 600 OK 1 0 local)
	$(row 1 ctx-a ctx-a 1000 686.2 ERROR_RATE_HIGH 0.93 0 local)
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "Local baseline: DEGRADED mesh_size=1 qps_target=1000 n_valid=1/2 reason=saturated_unflagged qps_actual=600 (60.0% of target)"
	# The ratio the report applies: 0.5 from the environment makes 686/1000 errors, not saturation.
	fresh
	tsv "${RES}/latency-h.tsv" "RUN_ID=r1" <<-EOF
	$(row 2 ctx-a ctx-a 1000 686.2 ERROR_RATE_HIGH 0.93 0 local)
	EOF
	DATAPLANE_MIN_QPS_RATIO=0.5 run "$REPORT" --results-dir "$RES"
	assert_output --partial "reason=errors qps_actual=686.2 (68.6% of target) server_replicas=unknown remote=none"
	# Rows at the target: OK, and the line says the report applied the ratio.
	fresh
	tsv "${RES}/latency-n.tsv" "RUN_ID=r1" <<-EOF
	$(row 2 ctx-a ctx-a 1000 999.0 OK 1 0 local)
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "Local baseline: OK at every QPS level (1 cell, top qps_target=1000, min_qps_ratio=0.95, applied by this report to 1 file without MIN_QPS_RATIO)"
}

@test "004: the HTTP 200 share is a percentage in text and markdown, a 0-1 ratio in csv and json" {
	tsv "${RES}/latency-p.tsv" "RUN_ID=r1" "MIN_QPS_RATIO=0.95" <<-EOF
	$(row 1 ctx-a ctx-a 10 10 OK 1 0 local)
	$(row 1 ctx-a ctx-a 100 100 OK 0.995 0 local)
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_success
	assert_output --partial "| HTTP 200 (%)"
	assert_output --regexp '\| +100\.00%'
	assert_output --regexp '\| +99\.50%'
	refute_output --partial "1.0000"
	run "$REPORT" --results-dir "$RES" --format md
	assert_output --partial "| avg_actual_qps | avg_http_200 (%) |"
	assert_output --partial "| 10.0 | 100.00% |"
	assert_output --partial "| 100.0 | 99.50% |"
	refute_output --partial "| 1.0000 |"
	run "$REPORT" --results-dir "$RES" --format csv
	assert_line "mesh_size,qps_target,target_class,n_total,n_valid,avg_p50_ms,avg_p90_ms,avg_p99_ms,avg_p999_ms,avg_max_ms,avg_actual_qps,avg_pct_200,avg_http_200_ratio"
	assert_line "1,10,local,1,1,2.00,2.50,5.00,11.00,12.50,10.0,1.0000,1.0000"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	[ "$(jq '.results[0] | .avg_pct_200 == 1 and .avg_http_200_ratio == 1' <<<"$output")" = true ]
	[ "$(jq '.results[1].avg_http_200_ratio' <<<"$output")" = 0.995 ]
}

@test "004: the platform record and its warnings reach every format's body: a member the inputs disagree on is mixed, with a warning, and kind nodes warn (PL19, PL26); inputs that agree on cloud nodes warn in none" {
	# One sweep's dir (its steps' TSVs): one run, whatever their RUN_IDs.
	RES="${BATS_TEST_TMPDIR}/sweep-h10"
	mkdir -p "$RES"
	tsv "${RES}/latency-a.tsv" "RUN_ID=r1" <<-EOF
	$(row 2 ctx-a ctx-a 10 10 OK 1 0 local)
	$(row 2 ctx-a ctx-b 10 10 OK 1 0 remote)
	EOF
	local -a plat=()
	mapfile -t plat < <(platform_fixture_lines | sed 's/^# //; s/pilot:1.30.5/pilot:1.30.6/g')
	NO_PLATFORM=1 tsv "${RES}/latency-b.tsv" "RUN_ID=r2" "${plat[@]}" <<-EOF
	$(row 2 ctx-a ctx-a 10 10 OK 1 0 local)
	EOF
	local dis="input TSVs disagree on ISTIOD_IMAGE_BY_CONTEXT for ctx-a (pilot:1.30.5 or pilot:1.30.6), ctx-b (pilot:1.30.5 or pilot:1.30.6)"
	local kind="Nodes on kind (NODE_PROVIDER_BY_CONTEXT)"
	local fmt
	for fmt in markdown charts; do
		run --separate-stderr "$REPORT" --results-dir "$RES" --format "$fmt"
		assert_success
		assert_output --partial "> **Warning:** ${dis}"
		assert_output --partial "> **Warning:** ${kind}"
		assert_line 'ISTIOD_IMAGE_BY_CONTEXT: "ctx-a=mixed:pilot:1.30.5;pilot:1.30.6,ctx-b=mixed:pilot:1.30.5;pilot:1.30.6"'
		assert_line 'MESH_OPERATOR_BY_CONTEXT: "ctx-a=sail-operator:1.31.1,ctx-b=sail-operator:1.31.1"'
	done
	run --separate-stderr "$REPORT" --results-dir "$RES"
	assert_line "# PLATFORM=kubernetes"
	assert_line "# ISTIOD_IMAGE_BY_CONTEXT=ctx-a=mixed:pilot:1.30.5;pilot:1.30.6,ctx-b=mixed:pilot:1.30.5;pilot:1.30.6"
	assert_output --partial "WARNING: ${dis}"
	assert_output --partial "WARNING: ${kind}"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format csv
	assert_line "# NODE_PROVIDER_BY_CONTEXT=ctx-a=kind,ctx-b=kind"
	assert_output --partial "# WARNING: ${dis}"
	assert_output --partial "# WARNING: ${kind}"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq '.warnings | length' <<<"$output")" = 2 ]
	[[ "$(jq -r '.warnings[0]' <<<"$output")" == "${dis}"* ]]
	[[ "$(jq -r '.warnings[1]' <<<"$output")" == "${kind}"* ]]
	[ "$(jq -r '.metadata | "\(.PLATFORM) \(.TEST_PLATFORM)"' <<<"$output")" = "kubernetes auto" ]
	# stderr: each merge warning once (named members), and the kind one.
	[ "$(grep -c 'disagree on ISTIOD_IMAGE_BY_CONTEXT' <<<"$stderr")" -eq 1 ]
	[[ "$stderr" == *"WARNING: ${kind}"* ]]
	# Inputs that agree, on cloud nodes: no warning.
	mapfile -t plat < <(platform_fixture_lines | sed 's/^# //; s/=kind/=aws/g')
	NO_PLATFORM=1 tsv "${RES}/latency-a.tsv" "RUN_ID=r1" "${plat[@]}" <<-EOF
	$(row 2 ctx-a ctx-a 10 10 OK 1 0 local)
	$(row 2 ctx-a ctx-b 10 10 OK 1 0 remote)
	EOF
	NO_PLATFORM=1 tsv "${RES}/latency-b.tsv" "RUN_ID=r2" "${plat[@]}" <<-EOF
	$(row 2 ctx-a ctx-a 10 10 OK 1 0 local)
	EOF
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -c '.warnings' <<<"$output")" = '[]' ]
	[ -z "$stderr" ] || { echo "$stderr"; false; }
}

@test "004: a TSV written before the live-version keys pooled with a live one reads mixed for them, never live" {
	mkdir -p "${RES}/sweep-old" "${RES}/sweep-new"
	tsv "${RES}/sweep-old/latency-o.tsv" "RUN_ID=ro" "ISTIO_VERSION=v1.30.5" <<-EOF
	$(row 1 ctx-a ctx-a 100 100 OK 1 0 local)
	EOF
	tsv "${RES}/sweep-new/latency-n.tsv" "RUN_ID=rn" "ISTIO_VERSION=v1.30.5" "ISTIO_VERSION_PIN=v1.30.5" \
		"ISTIO_VERSION_SOURCE=live" "ISTIO_VERSION_BY_CONTEXT=ctx-a=v1.30.5" <<-EOF
	$(row 1 ctx-a ctx-a 100 100 OK 1 0 local)
	EOF
	run --separate-stderr "$REPORT" --results-dir "$RES" --allow-multi-run --format json
	assert_success
	[ "$(jq -c '.metadata | [.ISTIO_VERSION, .ISTIO_VERSION_SOURCE, .ISTIO_VERSION_PIN, .ISTIO_VERSION_BY_CONTEXT]' <<<"$output")" = \
		'["v1.30.5","mixed:live,unknown","mixed:v1.30.5,unknown","mixed:ctx-a=v1.30.5,unknown"]' ]
	run --separate-stderr "$REPORT" --results-dir "${RES}/sweep-new" --format json
	[ "$(jq -r '.metadata.ISTIO_VERSION_SOURCE' <<<"$output")" = live ]
}

# --- 002: row status through the real probe, against a stub kubectl ---

@test "002: a run with nothing measured is N/A, never 0: a remote whose exec failed (FAILED; 004 leaves it out of every average) or that the reach check found UNREACHABLE (no load ran); the per-run md shows the 200 share as %" {
	REACH_RETRY_SEC=0 PATH="${BIN}:${PATH}" STUB_LOCAL_JSON="${FX}/fortio_float_noise.json" \
		STUB_REMOTE_JSON="${BATS_TEST_TMPDIR}/missing.json" \
		run "$PROBE" --source-context ctx-a --remote-contexts ctx-b --qps-levels 10 \
		--settle 0 --warmup-duration 0 --reach-requests 0 --output-dir "$RES"
	assert_success
	f="$(ls "$RES"/latency-*.tsv)"
	# The remote exec failed: nothing was measured.
	[ "$(awk -F'\t' '$17 == "remote" { print $6, $9, $10, $11, $12, $13, $14 }' "$f")" = "N/A N/A N/A N/A N/A N/A FAILED" ]
	md="$(ls "$RES"/latency-*.md)"
	grep -qxF '| ctx-a | local | 10 | 10.0 | 3.72 | 3.90 | 4.10 | 4.50 | 4.56 | 100.00% | OK |' "$md"
	grep -qxF '| ctx-b | remote | 10 | N/A | N/A | N/A | N/A | N/A | N/A | N/A | FAILED |' "$md"
	# The stub answers no platform read: the record says unknown, never a guess (PL39).
	grep -qx '# PLATFORM_BY_CONTEXT=ctx-a=unknown,ctx-b=unknown' "$f"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	[ "$(jq -c '[.results[] | select(.target_class == "remote") | .n_valid, .avg_max_ms, .avg_actual_qps]' <<<"$output")" = '[0,null,null]' ]
	fresh
	printf '{"RetCodes":{"503":10}}' > "${BATS_TEST_TMPDIR}/dead.json"
	REACH_RETRY_SEC=0 PATH="${BIN}:${PATH}" STUB_LOCAL_JSON="${FX}/fortio_ok.json" \
		STUB_REMOTE_JSON="${BATS_TEST_TMPDIR}/dead.json" \
		run "$PROBE" --source-context ctx-a --remote-contexts ctx-b --qps-levels 1000 \
		--settle 0 --warmup-duration 0 --output-dir "$RES"
	assert_success
	f="$(ls "$RES"/latency-*.tsv)"
	[ "$(awk -F'\t' '$17 == "remote" { print $6, $9, $13, $14 }' "$f")" = "N/A N/A N/A UNREACHABLE" ]
	grep -qF '| ctx-b | remote | 1000 | N/A | N/A |' "$RES"/latency-*.md
}

_probe() {
	REACH_RETRY_SEC=0 PATH="${BIN}:${PATH}" STUB_LOCAL_JSON="$1" STUB_REMOTE_JSON="${FX}/fortio_ok.json" \
		run "$PROBE" --source-context ctx-a --remote-contexts ctx-b --qps-levels 1000 \
		--settle 0 --warmup-duration 0 --output-dir "$RES"
}

@test "002 row status: a saturated local run with all 200s is QPS_SHORTFALL end to end, and 004 names it; errors are ERROR_RATE_HIGH below DATAPLANE_MIN_PCT_200, which is recorded" {
	_probe "${FX}/fortio_saturated_200.json"
	assert_success
	assert_output --partial "status=QPS_SHORTFALL"
	f="$(ls "$RES"/latency-*.tsv)"
	grep -qx '# SERVER_REPLICAS=ctx-a=1/1,ctx-b=1/1' "$f"
	grep -qx '# MIN_QPS_RATIO=0.95' "$f"
	grep -qx '# MIN_PCT_200=0.99' "$f"
	[ "$(awk -F'\t' '$17 == "local" { print $14 }' "$f")" = QPS_SHORTFALL ]
	[ "$(awk -F'\t' '$17 == "remote" { print $14 }' "$f")" = OK ]
	[ "$(awk -F'\t' '$17 == "local" { print NF }' "$f")" = 17 ]
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "Local baseline: DROPPED mesh_size=2 qps_target=1000 n_valid=0/1 reason=saturated qps_actual=686.2 (68.6% of target) server_replicas=1/1"
	fresh
	_probe "${FX}/fortio_errors.json"
	assert_success
	assert_output --partial "ret_codes=-1=20,200=19000,503=1580 status=ERROR_RATE_HIGH"
	fresh
	DATAPLANE_MIN_PCT_200=0.9 _probe "${FX}/fortio_errors.json"
	assert_success
	assert_output --partial "status=QPS_SHORTFALL"
	grep -qx '# MIN_PCT_200=0.9' "$RES"/latency-*.tsv
}

@test "002 records each server's Ready replicas as read: 0/<spec> with a warning when none is Ready, unknown when the Deployment cannot be read" {
	STUB_SERVER_REPLICAS="/2" _probe "${FX}/fortio_ok.json"
	assert_success
	assert_output --partial "has only 0/2 replicas Ready"
	grep -qx '# SERVER_REPLICAS=ctx-a=0/2,ctx-b=0/2' "$RES"/latency-*.tsv
	fresh
	STUB_SERVER_REPLICAS="" _probe "${FX}/fortio_ok.json"
	assert_success
	grep -qx '# SERVER_REPLICAS=ctx-a=unknown,ctx-b=unknown' "$RES"/latency-*.tsv
}

@test "003: a mesh size whose setup failed is a placeholder carrying the local-baseline keys 002 writes (PL36), so 004 reads it MISSING reason=setup_failed in every format, never as a file from before MIN_QPS_RATIO" {
	local d
	: > "${BATS_TEST_TMPDIR}/kubeconfig"
	# Every kubectl call but the stub's few fails: 001 cannot set up.
	ISTIO_VERSION_CHECK=warn ISTIO_VERSION_READY_WAIT_SEC=0 KUBECONFIG="${BATS_TEST_TMPDIR}/kubeconfig" PATH="${BIN}:${PATH}" \
		run --separate-stderr "$SWEEP" --contexts ci-a,ci-b --mesh-sizes 2 --output-dir "$RES"
	[ "$status" -eq 4 ] || { echo "$stderr"; false; }
	d="$(find "$RES" -maxdepth 1 -name 'sweep-*' -type d)"
	f="$(ls "$d"/latency-zzfail-ms2-*.tsv)"
	grep -qx '# SERVER_REPLICAS=unknown' "$f"
	grep -qx '# MIN_QPS_RATIO=0.95' "$f"
	grep -qx '# MIN_PCT_200=0.99' "$f"
	[ "$(awk -F'\t' '$1 !~ /^#/ && $1 != "run_id" { print $2, $14 }' "$f")" = "2 SETUP_FAILED" ]
	# The sweep's own report (markdown) and charts.
	grep -qF -- "- Local baseline: MISSING mesh_size=2 reason=setup_failed (no local rows)" "${d}/${d##*/}.md"
	grep -qF -- "> Local baseline missing at mesh 2 (setup_failed); its points are drawn as 0." "$d"/sweep-charts-*.md
	run --separate-stderr "$REPORT" --results-dir "$d" --format json
	assert_success
	[ "$(jq -c '.local_baseline | [.verdict, .files_without_min_qps_ratio, .cells[0].reason, .cells[0].qps_target]' <<<"$output")" = '["missing",0,"setup_failed",null]' ]
	run "$REPORT" --results-dir "$d" --format csv
	assert_line "# LOCAL_BASELINE_CELL=2:-:missing:setup_failed"
	refute_output --partial "FILES_WITHOUT_MIN_QPS_RATIO"
}

# --- flags and dry-runs ---

@test "the dataplane flags: a bad --min-qps-ratio, --server-replicas or DATAPLANE_MIN_PCT_200 is refused before any cluster call; a good one reaches the step that uses it, in --dry-run, and DATAPLANE_SERVER_REPLICAS defaults --server-replicas" {
	local v
	for v in 1.5 0 abc; do
		PATH="${BIN}:${PATH}" run "$PROBE" --dry-run --source-context ci-dummy --min-qps-ratio "$v"
		assert_failure
		assert_output --partial "--min-qps-ratio"
	done
	DATAPLANE_MIN_PCT_200=2 PATH="${BIN}:${PATH}" run "$PROBE" --dry-run --source-context ci-dummy
	assert_failure
	assert_output --partial "DATAPLANE_MIN_PCT_200"
	PATH="${BIN}:${PATH}" run "$SWEEP" --dry-run --contexts a --server-replicas 0
	assert_failure
	assert_output --partial "--server-replicas"
	PATH="${BIN}:${PATH}" run "$SWEEP" --dry-run --contexts a --min-qps-ratio 1.2
	assert_failure
	assert_output --partial "--min-qps-ratio"
	PATH="${BIN}:${PATH}" run "$SETUP" --source-context a --server-replicas 0 --dry-run
	assert_failure
	assert_output --partial "--server-replicas"
	[ ! -s "$STUB_LOG" ]
	PATH="${BIN}:${PATH}" run "$PROBE" --dry-run --source-context ci-dummy --min-qps-ratio 0.9
	assert_success
	assert_output --partial "Min QPS ratio: 0.9"
	KUBECONFIG=/dev/null PATH="${BIN}:${PATH}" run "$SWEEP" --dry-run --contexts a,b --mesh-sizes 2 \
		--server-replicas 3 --min-qps-ratio 0.9
	assert_success
	assert_output --partial "001-setup-dataplane-test.sh --source-context a --remote-contexts b --server-replicas 3"
	assert_output --partial "--min-qps-ratio 0.9"
	[ ! -s "$STUB_LOG" ]
	DATAPLANE_SERVER_REPLICAS=4 KUBECONFIG=/dev/null run "$SWEEP" --dry-run --contexts a --mesh-sizes 1
	assert_success
	assert_output --partial "001-setup-dataplane-test.sh --source-context a --server-replicas 4"
}

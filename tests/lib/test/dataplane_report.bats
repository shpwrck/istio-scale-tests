#!/usr/bin/env bats
# Dataplane suite through its real entrypoints: the 004 "Local baseline" verdict
# in every format, the 002 row status (QPS_SHORTFALL) against a stub kubectl that
# serves fortio JSON fixtures, and the 001/002/003 flags, help and dry-runs.

load test_helper

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
*" get pod -l app=dataplane-client "*) printf 'dataplane-client-0' ;;
*" get pods "*) : ;;  # no Running istiod pod
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
}

# row <mesh> <src> <tgt> <qps> <qps_actual> <status> <pct_200> <restarted> <class>
row() {
	printf 'r1\t%s\t%s\t%s\t%s\t%s\t8\t30\t2.0\t2.5\t5.0\t11.0\t12.5\t%s\t%s\t%s\t%s\n' "$@"
}

# tsv <file> <preamble lines...>; rows come on stdin.
tsv() {
	local f="$1" l
	shift
	{
		for l in "$@"; do echo "# $l"; done
		echo "$HDR"
		cat
	} > "$f"
}

# --- 004: Local baseline verdict ---

@test "004: 20c-shaped run (ERROR_RATE_HIGH at 686/1000) -> DROPPED reason=saturated" {
	tsv "${RES}/latency-a.tsv" "RUN_ID=r1" "SERVER_REPLICAS=ctx-a=1/1,ctx-b=1/1" <<-EOF
	$(row 2 ctx-a ctx-a 10 10 OK 1 0 local)
	$(row 2 ctx-a ctx-a 1000 686.2 ERROR_RATE_HIGH 0.93 0 local)
	$(row 2 ctx-a ctx-b 1000 999.8 OK 1 0 remote)
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_success
	assert_output --partial "Local baseline: DROPPED mesh_size=2 qps_target=1000 n_valid=0/1 reason=saturated qps_actual=686.2 (68.6% of target) server_replicas=1/1 remote=1/1 statuses=ERROR_RATE_HIGH=1"
	assert_output --partial "Hint: reason=saturated"
	refute_output --partial "qps_target=10 "
}

@test "004: QPS_SHORTFALL with all 200s -> dropped/saturated in json, csv and charts" {
	tsv "${RES}/latency-b.tsv" "RUN_ID=r1" "SERVER_REPLICAS=ctx-a=1/1,ctx-b=1/1" "MIN_QPS_RATIO=0.95" <<-EOF
	$(row 2 ctx-a ctx-a 1000 686.2 QPS_SHORTFALL 1 0 local)
	$(row 2 ctx-a ctx-b 1000 999.8 OK 1 0 remote)
	EOF
	run "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -r '.local_baseline.verdict' <<<"$output")" = dropped ]
	[ "$(jq -r '.local_baseline.cells[0].reason' <<<"$output")" = saturated ]
	[ "$(jq -r '.local_baseline.cells[0].qps_ratio < 0.95' <<<"$output")" = true ]
	[ "$(jq -r '.local_baseline.cells[0].remote_n_valid' <<<"$output")" = 1 ]
	[ "$(jq -r '.local_baseline.cells[0].statuses.QPS_SHORTFALL' <<<"$output")" = 1 ]
	[ "$(jq -r '.local_baseline.min_qps_ratio' <<<"$output")" = 0.95 ]
	run "$REPORT" --results-dir "$RES" --format csv
	assert_output --partial "# LOCAL_BASELINE=dropped"
	assert_output --partial "# LOCAL_BASELINE_CELL=2:1000:dropped:saturated"
	run "$REPORT" --results-dir "$RES" --format charts
	assert_output --partial "> Local baseline missing at mesh 2 / QPS 1000 (saturated); its point is drawn as 0."
}

@test "004: all local cells valid -> one OK line in every format" {
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
	assert_output --partial "## Local baseline"
	assert_output --partial "- Local baseline: OK at every QPS level (4 cells, top qps_target=1000"
	run "$REPORT" --results-dir "$RES" --format json
	[ "$(jq -r '.local_baseline.verdict' <<<"$output")" = ok ]
	[ "$(jq -r '.local_baseline.cells | length' <<<"$output")" = 4 ]
	[ "$(jq -r '.local_baseline.cells[3].server_replicas' <<<"$output")" = 2/2 ]
	run "$REPORT" --results-dir "$RES" --format csv
	assert_output --partial "# LOCAL_BASELINE=ok"
	refute_output --partial "LOCAL_BASELINE_CELL"
	run "$REPORT" --results-dir "$RES" --format charts
	refute_output --partial "Local baseline missing"
}

@test "004: placeholder-only mesh size -> MISSING with the placeholder status as reason" {
	tsv "${RES}/latency-zzfail-ms2-r1.tsv" "SERVER_REPLICAS=unknown" "MIN_QPS_RATIO=0.95" <<-EOF
	$(printf 'r1\t2\tctx-a\tN/A\t0\tN/A\t8\t30\tN/A\tN/A\tN/A\tN/A\tN/A\tSETUP_FAILED\tN/A\tunknown\tna')
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_success
	assert_output --partial "Local baseline: MISSING mesh_size=2 reason=setup_failed (no local rows)"
	run "$REPORT" --results-dir "$RES" --format json
	[ "$(jq -r '.local_baseline.verdict' <<<"$output")" = missing ]
	[ "$(jq -r '.local_baseline.cells[0].reason' <<<"$output")" = setup_failed ]
	[ "$(jq -r '.local_baseline.cells[0].qps_target' <<<"$output")" = null ]
	run "$REPORT" --results-dir "$RES" --format csv
	assert_output --partial "# LOCAL_BASELINE_CELL=2:-:missing:setup_failed"
}

@test "004: a STOPPED_UNREACHABLE placeholder gives reason=stopped_unreachable" {
	tsv "${RES}/latency-zzfail-ms3-r1.tsv" "SERVER_REPLICAS=unknown" <<-EOF
	$(printf 'r1\t3\tctx-a\tN/A\t0\tN/A\t8\t30\tN/A\tN/A\tN/A\tN/A\tN/A\tSTOPPED_UNREACHABLE\tN/A\tunknown\tna')
	EOF
	run "$REPORT" --results-dir "$RES" --format charts
	assert_output --partial "> Local baseline missing at mesh 3 (stopped_unreachable); its points are drawn as 0."
}

@test "004: one valid and one QPS_SHORTFALL repetition -> DEGRADED n_valid=1/2" {
	tsv "${RES}/latency-e1.tsv" "RUN_ID=r1" "SERVER_REPLICAS=ctx-a=2/2" "MIN_QPS_RATIO=0.95" <<-EOF
	$(row 1 ctx-a ctx-a 1000 999.0 OK 1 0 local)
	EOF
	tsv "${RES}/latency-e2.tsv" "RUN_ID=r2" "SERVER_REPLICAS=ctx-a=2/2" "MIN_QPS_RATIO=0.95" <<-EOF
	$(row 1 ctx-a ctx-a 1000 900.0 QPS_SHORTFALL 1 0 local)
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "Local baseline: DEGRADED mesh_size=1 qps_target=1000 n_valid=1/2 reason=saturated qps_actual=900 (90.0% of target) server_replicas=2/2 remote=none statuses=OK=1,QPS_SHORTFALL=1"
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
	assert_output --partial "remote_unreachable=N rows were skipped by the reach check"
	run "$REPORT" --results-dir "$RES" --format json
	[ "$(jq -r '.local_baseline.cells[0] | "\(.remote_n_valid)/\(.remote_n_total) \(.remote_unreachable)"' <<<"$output")" = "1/1 1" ]
	run "$REPORT" --results-dir "$RES" --format md
	assert_output --partial "remote=1/1 remote_unreachable=1"
	# Only the unreachable remote at that cell: remote=none, still named.
	tsv "${RES}/latency-u.tsv" "RUN_ID=r1" "SERVER_REPLICAS=ctx-a=2/2" "MIN_QPS_RATIO=0.95" <<-EOF
	$(row 2 ctx-a ctx-a 1000 800.0 QPS_SHORTFALL 1 0 local)
	$(printf 'r1\t2\tctx-a\tctx-c\t1000\t0\t8\t30\tN/A\tN/A\tN/A\tN/A\tN/A\tUNREACHABLE\t0\t0\tremote')
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "server_replicas=2/2 remote=none remote_unreachable=1 statuses=QPS_SHORTFALL=1"
	# No unreachable row: the field and the hint sentence stay out.
	tsv "${RES}/latency-u.tsv" "RUN_ID=r1" "SERVER_REPLICAS=ctx-a=2/2" "MIN_QPS_RATIO=0.95" <<-EOF
	$(row 2 ctx-a ctx-a 1000 800.0 QPS_SHORTFALL 1 0 local)
	EOF
	run "$REPORT" --results-dir "$RES"
	refute_output --partial "remote_unreachable"
	run "$REPORT" --results-dir "$RES" --format json
	[ "$(jq -r '.local_baseline.cells[0].remote_unreachable' <<<"$output")" = 0 ]
}

@test "004: remote dropped but local valid -> local OK, global WARNING still printed" {
	tsv "${RES}/latency-f.tsv" "RUN_ID=r1" "SERVER_REPLICAS=ctx-a=2/2,ctx-b=2/2" "MIN_QPS_RATIO=0.95" <<-EOF
	$(row 2 ctx-a ctx-a 1000 999.0 OK 1 0 local)
	$(row 2 ctx-a ctx-b 1000 0 FAILED N/A 0 remote)
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "Local baseline: OK at every QPS level (1 cell, top qps_target=1000"
	assert_output --partial "WARNING: 2 total / 1 valid rows"
	refute_output --partial "DROPPED"
}

@test "004: server_replicas and MIN_QPS_RATIO are read per file, not from the first TSV (PL26)" {
	tsv "${RES}/latency-g1.tsv" "RUN_ID=r1" "SERVER_REPLICAS=ctx-a=1/1" "MIN_QPS_RATIO=0.95" <<-EOF
	$(row 1 ctx-a ctx-a 1000 700 QPS_SHORTFALL 1 0 local)
	EOF
	# ratio 0.5: 700/1000 is not a shortfall here, so the reason is the restart.
	tsv "${RES}/latency-g2.tsv" "RUN_ID=r2" "SERVER_REPLICAS=ctx-a=2/2,ctx-b=2/2" "MIN_QPS_RATIO=0.5" <<-EOF
	$(row 2 ctx-a ctx-a 1000 700 OK 1 1 local)
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "mesh_size=1 qps_target=1000 n_valid=0/1 reason=saturated qps_actual=700 (70.0% of target) server_replicas=1/1 "
	assert_output --partial "mesh_size=2 qps_target=1000 n_valid=0/1 reason=istiod_restarted qps_actual=700 (70.0% of target) server_replicas=2/2 "
}

@test "004: a restart that could not be checked is named apart from a real restart" {
	tsv "${RES}/latency-r.tsv" "RUN_ID=r1" "SERVER_REPLICAS=ctx-a=2/2" "MIN_QPS_RATIO=0.95" <<-EOF
	$(row 1 ctx-a ctx-a 100 100 OK 1 unknown local)
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "Local baseline: DROPPED mesh_size=1 qps_target=100 n_valid=0/1 reason=istiod_restart_unknown"
}

@test "004: legacy TSV without the new keys -> server_replicas=unknown, env ratio fallback" {
	tsv "${RES}/latency-h.tsv" "RUN_ID=r1" <<-EOF
	$(row 2 ctx-a ctx-a 1000 686.2 ERROR_RATE_HIGH 0.93 0 local)
	EOF
	DATAPLANE_MIN_QPS_RATIO=0.5 run "$REPORT" --results-dir "$RES"
	assert_output --partial "reason=errors qps_actual=686.2 (68.6% of target) server_replicas=unknown remote=none"
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "reason=saturated"
}

@test "004: legacy OK row below the ratio -> UNCHECKED, never 'OK at every QPS level'" {
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
	assert_output --partial "Note: reason=saturated_unflagged"
	refute_output --partial "qps_target=10 "
	run "$REPORT" --results-dir "$RES" --format json
	[ "$(jq -r '.local_baseline.verdict' <<<"$output")" = unchecked ]
	[ "$(jq -r '.local_baseline.files_without_min_qps_ratio' <<<"$output")" = 1 ]
	[ "$(jq -r '.local_baseline.cells[1].reason' <<<"$output")" = saturated_unflagged ]
	[ "$(jq -r '.local_baseline.cells[1].ok_below_ratio' <<<"$output")" = 1 ]
	[ "$(jq -r '.local_baseline.cells[0].verdict' <<<"$output")" = ok ]
	# n_valid is unchanged: the row still counts and is averaged.
	[ "$(jq -r '.results[] | select(.target_class == "local" and .qps_target == 1000) | "\(.n_valid) \(.avg_actual_qps)"' <<<"$output")" = "1 686.2" ]
	[ "$(jq -r '.summary.n_valid' <<<"$output")" = 3 ]
	run "$REPORT" --results-dir "$RES" --format csv
	assert_output --partial "# LOCAL_BASELINE=unchecked"
	assert_output --partial "# LOCAL_BASELINE_FILES_WITHOUT_MIN_QPS_RATIO=1"
	assert_output --partial "# LOCAL_BASELINE_CELL=2:1000:unchecked:saturated_unflagged"
	run "$REPORT" --results-dir "$RES" --format md
	assert_output --partial "- Local baseline: UNCHECKED mesh_size=2 qps_target=1000"
	run "$REPORT" --results-dir "$RES" --format charts
	assert_output --partial "> Local point at mesh 2 / QPS 1000 includes 1 OK row(s) below min_qps_ratio x target (saturated_unflagged, TSV without MIN_QPS_RATIO)."
}

@test "004: legacy short OK row beside a dropped one -> DEGRADED reason=saturated_unflagged" {
	tsv "${RES}/latency-m.tsv" "RUN_ID=r1" <<-EOF
	$(row 1 ctx-a ctx-a 1000 600 OK 1 0 local)
	$(row 1 ctx-a ctx-a 1000 686.2 ERROR_RATE_HIGH 0.93 0 local)
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "Local baseline: DEGRADED mesh_size=1 qps_target=1000 n_valid=1/2 reason=saturated_unflagged qps_actual=600 (60.0% of target)"
	assert_output --partial "ok_below_ratio=1"
}

@test "004: legacy OK rows at the target -> OK, and the line says the report applied the ratio" {
	tsv "${RES}/latency-n.tsv" "RUN_ID=r1" <<-EOF
	$(row 2 ctx-a ctx-a 1000 999.0 OK 1 0 local)
	EOF
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "Local baseline: OK at every QPS level (1 cell, top qps_target=1000, min_qps_ratio=0.95, applied by this report to 1 file without MIN_QPS_RATIO)"
	# The env fallback sets the ratio the report applies to legacy rows.
	tsv "${RES}/latency-n.tsv" "RUN_ID=r1" <<-EOF
	$(row 2 ctx-a ctx-a 1000 686.2 OK 1 0 local)
	EOF
	DATAPLANE_MIN_QPS_RATIO=0.5 run "$REPORT" --results-dir "$RES"
	assert_output --partial "min_qps_ratio=0.5, applied by this report to 1 file without MIN_QPS_RATIO)"
	run "$REPORT" --results-dir "$RES" --format csv
	assert_output --partial "# LOCAL_BASELINE=unchecked"
}

# --- 002: row status through the real probe, against a stub kubectl ---

_probe() {
	REACH_RETRY_SEC=0 PATH="${BIN}:${PATH}" STUB_LOCAL_JSON="$1" STUB_REMOTE_JSON="${FX}/fortio_ok.json" \
		run "$PROBE" --source-context ctx-a --remote-contexts ctx-b --qps-levels 1000 \
		--settle 0 --warmup-duration 0 --output-dir "$RES"
}

@test "002: a saturated local run is QPS_SHORTFALL end to end, and 004 names it" {
	_probe "${FX}/fortio_saturated_200.json"
	assert_success
	assert_output --partial "ret_codes=200=20586 status=QPS_SHORTFALL"
	f="$(ls "$RES"/latency-*.tsv)"
	grep -qx '# SERVER_REPLICAS=ctx-a=1/1,ctx-b=1/1' "$f"
	grep -qx '# MIN_QPS_RATIO=0.95' "$f"
	grep -qx '# MIN_PCT_200=0.99' "$f"
	[ "$(awk -F'\t' '$17 == "local" { print $14 }' "$f")" = QPS_SHORTFALL ]
	[ "$(awk -F'\t' '$17 == "remote" { print $14 }' "$f")" = OK ]
	[ "$(awk -F'\t' '$17 == "local" { print NF }' "$f")" = 17 ]
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "Local baseline: DROPPED mesh_size=2 qps_target=1000 n_valid=0/1 reason=saturated qps_actual=686.2 (68.6% of target) server_replicas=1/1"
}

@test "002: errors are ERROR_RATE_HIGH, with the code breakdown on the console" {
	_probe "${FX}/fortio_errors.json"
	assert_success
	assert_output --partial "ret_codes=-1=20,200=19000,503=1580 status=ERROR_RATE_HIGH"
}

@test "002: DATAPLANE_MIN_PCT_200 sets the error threshold and is recorded" {
	DATAPLANE_MIN_PCT_200=0.9 _probe "${FX}/fortio_errors.json"
	assert_success
	assert_output --partial "status=QPS_SHORTFALL"
	grep -qx '# MIN_PCT_200=0.9' "$RES"/latency-*.tsv
}

@test "002: no Ready server pod is recorded as 0/<spec> with a warning" {
	STUB_SERVER_REPLICAS="/2" _probe "${FX}/fortio_ok.json"
	assert_success
	assert_output --partial "has only 0/2 replicas Ready"
	grep -qx '# SERVER_REPLICAS=ctx-a=0/2,ctx-b=0/2' "$RES"/latency-*.tsv
}

@test "002: an unreadable server Deployment is recorded as unknown" {
	STUB_SERVER_REPLICAS="" _probe "${FX}/fortio_ok.json"
	assert_success
	grep -qx '# SERVER_REPLICAS=ctx-a=unknown,ctx-b=unknown' "$RES"/latency-*.tsv
}

# --- flags, help and dry-runs ---

@test "002 --dry-run prints the thresholds and never calls kubectl" {
	PATH="${BIN}:${PATH}" run "$PROBE" --dry-run --source-context ci-dummy --min-qps-ratio 0.9
	assert_success
	assert_output --partial "Min QPS ratio: 0.9 | Min pct_200: 0.99"
	assert_output --partial "Server replicas: queried live on: ci-dummy"
	[ ! -s "$STUB_LOG" ]
}

@test "002 rejects a bad --min-qps-ratio or DATAPLANE_MIN_PCT_200" {
	for v in 1.5 0 abc; do
		PATH="${BIN}:${PATH}" run "$PROBE" --dry-run --source-context ci-dummy --min-qps-ratio "$v"
		assert_failure
		assert_output --partial "--min-qps-ratio"
	done
	DATAPLANE_MIN_PCT_200=2 PATH="${BIN}:${PATH}" run "$PROBE" --dry-run --source-context ci-dummy
	assert_failure
	assert_output --partial "DATAPLANE_MIN_PCT_200"
}

@test "003 --dry-run passes --server-replicas to 001 and --min-qps-ratio to 002" {
	KUBECONFIG=/dev/null PATH="${BIN}:${PATH}" run "$SWEEP" --dry-run --contexts a,b --mesh-sizes 2 \
		--server-replicas 3 --min-qps-ratio 0.9
	assert_success
	assert_output --partial "001-setup-dataplane-test.sh --source-context a --remote-contexts b --server-replicas 3"
	assert_output --partial "--min-qps-ratio 0.9"
	assert_output --partial "Server replicas: 3 per cluster | Min QPS ratio: 0.9"
	[ ! -s "$STUB_LOG" ]
}

@test "003 defaults --server-replicas from DATAPLANE_SERVER_REPLICAS" {
	DATAPLANE_SERVER_REPLICAS=4 KUBECONFIG=/dev/null run "$SWEEP" --dry-run --contexts a --mesh-sizes 1
	assert_success
	assert_output --partial "001-setup-dataplane-test.sh --source-context a --server-replicas 4"
}

@test "003 rejects bad --server-replicas and --min-qps-ratio" {
	run "$SWEEP" --dry-run --contexts a --server-replicas 0
	assert_failure
	assert_output --partial "--server-replicas"
	run "$SWEEP" --dry-run --contexts a --min-qps-ratio 1.2
	assert_failure
	assert_output --partial "--min-qps-ratio"
}

@test "001 rejects a bad --server-replicas before touching a cluster" {
	PATH="${BIN}:${PATH}" run "$SETUP" --source-context a --server-replicas 0 --dry-run
	assert_failure
	assert_output --partial "--server-replicas"
	[ ! -s "$STUB_LOG" ]
}

@test "--help lists the new flags and environment variables" {
	run "$SETUP" --help
	assert_success
	assert_output --partial "--server-replicas N"
	assert_output --partial "DATAPLANE_SERVER_REPLICAS"
	run "$PROBE" --help
	assert_success
	assert_output --partial "--min-qps-ratio R"
	assert_output --partial "QPS_SHORTFALL"
	assert_output --partial "DATAPLANE_MIN_PCT_200"
	run "$SWEEP" --help
	assert_success
	assert_output --partial "--server-replicas N"
	assert_output --partial "--min-qps-ratio R"
	run "$REPORT" --help
	assert_success
	assert_output --partial "Local baseline"
}

@test "PL36: 002 and the 003 placeholder both write the local-baseline preamble keys" {
	for k in SERVER_REPLICAS MIN_QPS_RATIO MIN_PCT_200; do
		grep -q "echo \"# ${k}=" "$PROBE"
		grep -q "echo \"# ${k}=" "$SWEEP"
	done
}

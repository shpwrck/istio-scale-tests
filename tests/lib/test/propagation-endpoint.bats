#!/usr/bin/env bats
# The propagation endpoint TSV, one schema for every writer, and which side's failure
# leaves out which phase: 006's SETUP_FAILED placeholder in 002's 23-column schema;
# through 002, an istiod restart on the source or on the remote; P2 and P3 left out only
# for the remote's side and P1 only for the source's (005 in every format, tuning 004);
# older 19- and 21-column TSVs. Stub kubectl and curl, no cluster (PL33).

bats_require_minimum_version 1.5.0
load test_helper

FX="${ROOT}/tests/lib/test/fixtures/istiod-diag"
PR="${ROOT}/tests/propagation"
TUNING_CMP="${ROOT}/tests/tuning/004-compare-profiles.sh"

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
	EK="${BATS_TEST_TMPDIR}/empty.kubeconfig"
	: > "$EK"
	export TMPDIR="$BATS_TEST_TMPDIR"
}

# _prop_stub: kubectl that answers the propagation probe's reads, and a curl that serves
# istiod /metrics from STUB_PRE_BODY before the t0 label flip (STUB_MARK) and after it
# from STUB_SRC_POST on the source's port-forward block (ctx index 0: 21014-21033) or
# STUB_RMT_POST on the remote's (21034 on); the remote watcher's /clusters (port 15100)
# shows the canary healthy after the flip, so its P3 succeeds.
_prop_stub() {
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log" STUB_MARK="${BATS_TEST_TMPDIR}/post.mark" FX
	: > "$STUB_LOG"
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*) exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" label pod/"*"=true "*) : > "$STUB_MARK" ;;
*" label pod/"*) : ;;
*" wait pod/"*) : ;;
*" get pods -l app=propagation-canary "*) printf 'canary-backer-0\n' ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running "*) printf 'istiod-abc-x1\n' ;;
*" -n istio-system get pods -l app=istiod -o json "*) cat "$FX/pods_oom.json" ;;
*" get events "* | *" get deploy,rs "*) cat "$FX/empty_list.json" ;;
*" get node "*) cat "$FX/node_ready.json" ;;
*" logs "*) echo "istiod log line" ;;
*" -o json "*) cat "$FX/empty_list.json" ;;
*) exit 1 ;;
esac
STUB
	cat > "${BIN}/curl" <<'STUB'
#!/usr/bin/env bash
out="" url=""
while (($#)); do
	case "$1" in
	-o) out="$2"; shift 2 ;;
	http://*) url="$1"; shift ;;
	*) shift ;;
	esac
done
port="${url#http://localhost:}"
port="${port%%/*}"
case "$url" in
*/metrics)
	body="$STUB_PRE_BODY"
	if [[ -f "$STUB_MARK" ]]; then
		if ((port >= 21034)); then body="$STUB_RMT_POST"; else body="$STUB_SRC_POST"; fi
	fi ;;
*/clusters)
	if [[ -f "$STUB_MARK" && "$port" == 15100 ]]; then
		echo "outbound|80||propagation-canary.ns.svc.cluster.local::192.0.2.10:8080::health_flags::healthy"
		exit 0
	fi
	body="$FX/../fortio_ok.json" ;;
*/ready) echo LIVE; exit 0 ;;
*/debug/syncz) echo '[]'; exit 0 ;;
*) exit 7 ;;
esac
if [[ -n "$out" ]]; then cp "$body" "$out"; else cat "$body"; fi
STUB
	chmod +x "${BIN}/kubectl" "${BIN}/curl"
	# hist <count> <sum>: the P1 convergence histogram, all samples under 100 ms.
	hist() { printf 'pilot_proxy_convergence_time_bucket{le="0.1"} %s\npilot_proxy_convergence_time_bucket{le="+Inf"} %s\npilot_proxy_convergence_time_sum %s\npilot_proxy_convergence_time_count %s\n' "$1" "$1" "$2" "$1"; }
	export STUB_PRE_BODY="${BATS_TEST_TMPDIR}/pre.txt"
	{ cat "${FX}/pre_metrics.txt"; hist 0 0; } > "$STUB_PRE_BODY"
	# After the flip: P1 converges (10 samples for 5 proxies) and the EDS counter bumps.
	CLEAN_POST="${BATS_TEST_TMPDIR}/post.txt"
	{ sed 's/^pilot_xds_pushes{type="eds"} .*/pilot_xds_pushes{type="eds"} 300/' "${FX}/pre_metrics.txt"; hist 10 0.5; } > "$CLEAN_POST"
	# The same, from an istiod that restarted (a later process_start_time_seconds).
	RESTARTED_POST="${BATS_TEST_TMPDIR}/post-restarted.txt"
	sed 's/^process_start_time_seconds .*/process_start_time_seconds 1.7169414e+09/' "$CLEAN_POST" > "$RESTARTED_POST"
	export STUB_SRC_POST="$CLEAN_POST" STUB_RMT_POST="$CLEAN_POST"
}

_prop_run() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${PR}/002-run-endpoint-probe.sh" \
		--source-context ctx-a --remote-contexts ctx-b --timeout 3 --poll-interval-ms 100 --settle-sec 0 --tsv \
		--output-dir "$RES" --iterations 1
}

# _row <cols>: the given columns of the endpoint TSV's data rows, slash-joined.
_row() {
	awk -F'\t' -v c="$1" 'BEGIN { n = split(c, k, ",") } !/^#/ && $1 != "run_id" {
		s = ""; for (i = 1; i <= n; i++) s = s (i > 1 ? "/" : "") $(k[i]); print s }' "$RES"/endpoint-*.tsv
}

# prow23 <iteration> <remote> <status> <p1_overflow> <restarted> <p1_status> <p1_skew> <remote_status> <remote_skew>:
# a 23-column row, p1 100 ms, P2 50 ms and P3 60 ms when remote_status is OK (else N/A).
prow23() {
	local p2=50 p3=60
	[[ "$8" == OK ]] || { p2=N/A p3=N/A; }
	printf 'r1\t3\t%s\tsrc\t%s\t0\t100\t%s\t%s\t%s\t99\t99\t10/10\t10\t%s\t%s\t0\t5000\t10\t%s\t%s\t%s\t%s\n' \
		"$1" "$2" "$p2" "$p3" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}

@test "006's SETUP_FAILED placeholder is written in 002's 23-column schema; 005 and tuning 004 count it in n_total only" {
	local d
	PROPAGATION_RESULTS_DIR="$RES" PROPAGATION_SETTLE_SEC=0 ISTIO_VERSION_CHECK=warn ISTIO_VERSION_READY_WAIT_SEC=0 \
		KUBECONFIG="$EK" run --separate-stderr bash "${PR}/006-run-sweep.sh" --contexts ci-a --mesh-sizes 1
	assert_failure 4
	d="$(find "$RES" -maxdepth 1 -name 'sweep-*' -type d)"
	f="$(ls "$d"/endpoint-*.tsv)"
	source "${ROOT}/tests/lib/propagation.sh"
	grep -qxF "$PROP_TSV_HEADER" "$f"
	[ "$(awk -F'\t' '!/^#/ { print NF }' "$f" | sort -u)" = 23 ]
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $10 "/" $16 "/" $20 "/" $22 }' "$f")" = SETUP_FAILED/unknown/SETUP_FAILED/SETUP_FAILED ]
	run "${PR}/005-report-results.sh" --results-dir "$d" --format csv
	assert_success
	# n_attempted (the last column): the placeholder's ITERATIONS (10), one row each at mesh size 1.
	assert_line "1,P1_local_wall,1,0,,,,,,,,10"
	assert_line "1,P2_discovery,1,0,,,,,,,,10"
	assert_line "1,P3_dataplane,1,0,,,,,,,,10"
	# stderr warns that 0 of 10 iterations were measured; json goes to stdout alone.
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$d" --format json
	[ "$(jq -c '[.rows[] | [.phase, .n_total, .n_valid]]' <<<"$output")" = \
		'[["P1_local_wall",1,0],["P1_conv_p50",1,0],["P1_conv_p99",1,0],["P2_discovery",1,0],["P3_dataplane",1,0]]' ]
	# tuning 004 reads it as a propagation pass (header name lookup) and counts nothing valid.
	local P="${BATS_TEST_TMPDIR}/psweep"
	mkdir -p "${P}/baseline"
	printf '# SUITE=propagation\n# PASSES=baseline\n' > "${P}/sweep-metadata.txt"
	cp "$f" "${P}/baseline/"
	run "$TUNING_CMP" --results-dir "$P" --format md
	assert_success
	assert_output --partial "|   n (got/attempted) | 0/1 |"
}

@test "through 002: the source istiod restarted, the remote was clean: P2 and P3 count (summary, 005 every format), P1 is left out" {
	_prop_stub
	STUB_SRC_POST="$RESTARTED_POST" _prop_run
	assert_success
	# status (10) and restarted (16) are the row's, over both sides; p1_status (20) is the
	# source's, remote_status (22) the remote's alone; p2_ms (8) is a number: the remote
	# istiod's counters did not reset.
	[ "$(_row 10,16,20,22)" = RESTART/1/RESTART/OK ]
	[[ "$(_row 8)" =~ ^[0-9]+$ && "$(_row 9)" =~ ^[0-9]+$ ]]
	assert_output --partial "P1 local xDS push:          n=0/1 (no valid sample)"
	assert_output --regexp 'P2 remote istiod EDS push: +n=1/1 min=[0-9]+ms'
	assert_output --regexp 'P3 remote sidecar: +n=1/1 min=[0-9]+ms'
	assert_output --partial "rows_dropped_total=0/1"
	assert_output --regexp 'P1 iterations left out .*'$'\n''    RESTART +1'
	grep -qE '^\| P2 remote istiod EDS push \| 1/1 \| [0-9]+ \|' "$RES"/endpoint-*.md
	grep -qxF '| P1 local xDS push | 0/1 | - | - | - |' "$RES"/endpoint-*.md
	run "${PR}/005-report-results.sh" --results-dir "$RES" --format json
	[ "$(jq -c '[.rows[] | [.phase, .n_total, .n_valid]]' <<<"$output")" = \
		'[["P1_local_wall",1,0],["P1_conv_p50",1,0],["P1_conv_p99",1,0],["P2_discovery",1,1],["P3_dataplane",1,1]]' ]
	run "${PR}/005-report-results.sh" --results-dir "$RES" --format csv
	assert_line --regexp '^2,P2_discovery,1,1,[0-9]+,'
	assert_line --regexp '^2,P3_dataplane,1,1,[0-9]+,'
	run "${PR}/005-report-results.sh" --results-dir "$RES" --format md
	assert_line --regexp '^\| P2 remote istiod EDS \| 1 \| 1 \| [0-9]+ \|'
	run "${PR}/005-report-results.sh" --results-dir "$RES"
	assert_output --regexp 'P3 remote sidecar +\| +1 \| +1 \|'
}

@test "through 002: the remote istiod restarted, the source was clean: its P2 and P3 are dropped (RESTART), P1 counts" {
	_prop_stub
	STUB_RMT_POST="$RESTARTED_POST" _prop_run
	assert_success
	# p1_conv_p99 needs 30 samples (it has 10): N/A, so its n_valid is 0 either way.
	[ "$(_row 8,16,20,22)" = N/A/1/OK/RESTART ]
	assert_output --regexp 'P1 local xDS push: +n=1/1 min=[0-9]+ms'
	assert_output --partial "P2 remote istiod EDS push:  n=0/1 (no valid sample)"
	assert_output --partial "rows_dropped_total=1/1"
	assert_output --regexp '    RESTART +1'
	grep -qxF '| `RESTART` | 1 |' "$RES"/endpoint-*.md
	run "${PR}/005-report-results.sh" --results-dir "$RES" --format json
	[ "$(jq -c '[.rows[] | [.phase, .n_total, .n_valid]]' <<<"$output")" = \
		'[["P1_local_wall",1,1],["P1_conv_p50",1,1],["P1_conv_p99",1,0],["P2_discovery",1,0],["P3_dataplane",1,0]]' ]
}

@test "P2/P3 are dropped only for the remote's side, P1 only for the source's: 005 (every format) and tuning 004 on 23-column rows" {
	source "${ROOT}/tests/lib/propagation.sh"
	{
		echo "# RUN_ID=r1"
		echo "$PROP_TSV_HEADER"
		# 1: the source istiod restarted: P1 dropped, both remotes' P2/P3 count.
		prow23 1 b RESTART 0 1 RESTART 5 OK 5
		prow23 1 c RESTART 0 1 RESTART 5 OK 5
		# 2: P1 overflowed: P1 dropped, P2/P3 count.
		prow23 2 b OK 1 0 OK 5 OK 5
		prow23 2 c OK 1 0 OK 5 OK 5
		# 3: the source was clean; remote b restarted, c timed out: P1 counts, no P2/P3.
		prow23 3 b RESTART 0 1 OK 5 RESTART 5
		prow23 3 c TIMEOUT_P3 0 0 OK 5 TIMEOUT_P3 5
		# 4: remote b's scrape skewed past FANOUT_MAX_SKEW_MS: b dropped, c counts.
		prow23 4 b SCRAPE_INCOMPLETE 0 0 OK 5 OK 5000
		prow23 4 c SCRAPE_INCOMPLETE 0 0 OK 5 OK 5
	} > "${RES}/endpoint-r1.tsv"
	run "${PR}/005-report-results.sh" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -c '[.rows[] | [.phase, .n_total, .n_valid]]' <<<"$output")" = \
		'[["P1_local_wall",4,2],["P1_conv_p50",4,2],["P1_conv_p99",4,2],["P2_discovery",8,5],["P3_dataplane",8,5]]' ]
	run "${PR}/005-report-results.sh" --results-dir "$RES" --format csv
	assert_line "3,P1_local_wall,4,2,100,100,100,100,N/A,N/A,,"
	assert_line "3,P2_discovery,8,5,50,50,50,50,N/A,N/A,,"
	assert_line "3,P3_dataplane,8,5,60,60,60,60,N/A,N/A,,"
	run "${PR}/005-report-results.sh" --results-dir "$RES" --format md
	assert_output --partial "| P1 local xDS (wall) | 4 | 2 |"
	assert_output --partial "| P2 remote istiod EDS | 8 | 5 |"
	assert_output --partial "| P3 remote sidecar | 8 | 5 |"
	run "${PR}/005-report-results.sh" --results-dir "$RES"
	assert_output --regexp 'P2 remote istiod EDS +\| +8 \| +5 \|'
	# The drop reasons, row by row (prop_drop_reason), as 002's summary tallies them.
	run awk -F'\t' "${PROP_ROW_AWK}"'/^#/ || $1 == "run_id" { next } { print $3 $5 ":" prop_drop_reason(1000) ":" prop_p1_drop_reason(1000) }' "${RES}/endpoint-r1.tsv"
	assert_output "$(printf '%s\n' 1b::RESTART 1c::RESTART 2b::p1_overflow 2c::p1_overflow 3b:RESTART: 3c:TIMEOUT_P3: '4b:remote_scrape_skew>1000:' 4c::)"
	# tuning 004: the same rows (one shared definition).
	local P="${BATS_TEST_TMPDIR}/psweep"
	mkdir -p "${P}/baseline"
	printf '# SUITE=propagation\n# PASSES=baseline\n' > "${P}/sweep-metadata.txt"
	cp "${RES}/endpoint-r1.tsv" "${P}/baseline/"
	run "$TUNING_CMP" --results-dir "$P" --format md
	assert_success
	[[ "$output" == *"| P1 local push (ms) | 100.00 (1 overflowed) |"$'\n'"|   n (got/attempted) | 2/4 |"* ]]
	[[ "$output" == *"| P2 remote EDS (ms) | 50.00 |"$'\n'"|   n (got/attempted) | 5/8 |"* ]]
	[[ "$output" == *"| P3 remote sidecar (ms) | 60.00 |"$'\n'"|   n (got/attempted) | 5/8 |"* ]]
}

@test "older TSVs (19 and 21 columns) still report; their P2/P3 keep the row rule but never drop for p1_overflow" {
	local w
	source "${ROOT}/tests/lib/propagation.sh"
	for w in 19 21; do
		rm -rf "$RES"; mkdir -p "$RES"
		{
			echo "# RUN_ID=r1"
			cut -f1-"$w" <<<"$PROP_TSV_HEADER"
			# 1: P1 overflowed on an otherwise clean row: P1 dropped, P2/P3 count.
			prow23 1 b OK 1 0 OK 5 OK 5 | cut -f1-"$w"
			# 2: a restart on the row (either side, not split before field 22): all dropped
			# from P2/P3; P1 only where the TSV cannot tell (19 columns).
			prow23 2 b RESTART 0 1 OK 5 RESTART 5 | cut -f1-"$w"
			# 3: clean.
			prow23 3 b OK 0 0 OK 5 OK 5 | cut -f1-"$w"
		} > "${RES}/endpoint-r1.tsv"
		run "${PR}/005-report-results.sh" --results-dir "$RES" --format json
		assert_success
		# P2/P3: row 1 (overflow only) and row 3 count, row 2 (RESTART) does not.
		if ((w == 19)); then
			[ "$(jq -c '[.rows[] | [.phase, .n_total, .n_valid]]' <<<"$output")" = \
				'[["P1_local_wall",3,1],["P1_conv_p50",3,1],["P1_conv_p99",3,1],["P2_discovery",3,2],["P3_dataplane",3,2]]' ]
		else
			# 21 columns: p1_status (OK on row 2) keeps the iteration's P1.
			[ "$(jq -c '[.rows[] | [.phase, .n_total, .n_valid]]' <<<"$output")" = \
				'[["P1_local_wall",3,2],["P1_conv_p50",3,2],["P1_conv_p99",3,2],["P2_discovery",3,2],["P3_dataplane",3,2]]' ]
		fi
	done
}

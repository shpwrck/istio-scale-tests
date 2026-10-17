#!/usr/bin/env bats
# Carry-over integration pass (I1-I10): harness provenance from harness_sha everywhere (I1),
# one propagation TSV schema for every writer (I2), the sweep-level Istio keys in every
# multi-input report (I3), controlplane --resume and a recorded duplicate member (I4), a
# sweep that stops after its start records why (I5), P2/P3 dropped only for the remote's
# side (I6), escaped markdown cells (I7), no fork per file (I8) and redact-results (I9).
# Through the real scripts where a test can reach them (PL33); no cluster: kubectl and curl
# are stubs, or kubectl fails against an empty kubeconfig.

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

# --- I1: harness provenance ------------------------------------------------------

@test "I1 (PL41): harness_sha is the only place that runs git describe; no script records a bare -dirty" {
	# Every script that could record provenance (the suites, the libs, the Terraform helpers).
	local -a files=()
	local hits
	mapfile -t files < <(find "${ROOT}/tests" "${ROOT}/terraform" -name '*.sh' -not -path '*/bats-*' -not -path '*/tests/lib/test/*')
	[ "${#files[@]}" -gt 20 ]
	# A command substitution that runs it, outside harness_sha (tests/lib/preamble.sh).
	hits="$(grep -nE '\$\(git[^)]*describe' "${files[@]}" | grep -v '/tests/lib/preamble\.sh:' || true)"
	[ -z "$hits" ] || { echo "$hits"; false; }
	hits="$(grep -nE 'HARNESS(_SHA)?="?\$\(git' "${files[@]}" || true)"
	[ -z "$hits" ] || { echo "$hits"; false; }
	# The check fires on a script that does it (the line I1 replaced).
	printf '%s\n' 'HARNESS_SHA="$(git -C "$ROOT" describe --always --dirty --abbrev=7 2>/dev/null || echo unknown)"' > "${BATS_TEST_TMPDIR}/old.sh"
	grep -qE '\$\(git[^)]*describe' "${BATS_TEST_TMPDIR}/old.sh"
	grep -qE 'HARNESS(_SHA)?="?\$\(git' "${BATS_TEST_TMPDIR}/old.sh"
}

# --- I2 / I6: the propagation endpoint TSV ----------------------------------------

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

@test "I2 (PL36): 006's SETUP_FAILED placeholder is written in 002's 23-column schema; 005 and tuning 004 count it in n_total only" {
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
	assert_line "1,P1_local_wall,1,0,,,,,,,"
	assert_line "1,P2_discovery,1,0,,,,,,,"
	assert_line "1,P3_dataplane,1,0,,,,,,,"
	run "${PR}/005-report-results.sh" --results-dir "$d" --format json
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

@test "I6 (PL33): through 002: the source istiod restarted, the remote was clean: P2 and P3 count (summary, 005 every format), P1 is left out" {
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

@test "I6 (PL33): through 002: the remote istiod restarted, the source was clean: its P2 and P3 are dropped (RESTART), P1 counts" {
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

# prow23 <iteration> <remote> <status> <p1_overflow> <restarted> <p1_status> <p1_skew> <remote_status> <remote_skew>:
# a 23-column row, p1 100 ms, P2 50 ms and P3 60 ms when remote_status is OK (else N/A).
prow23() {
	local p2=50 p3=60
	[[ "$8" == OK ]] || { p2=N/A p3=N/A; }
	printf 'r1\t3\t%s\tsrc\t%s\t0\t100\t%s\t%s\t%s\t99\t99\t10/10\t10\t%s\t%s\t0\t5000\t10\t%s\t%s\t%s\t%s\n' \
		"$1" "$2" "$p2" "$p3" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}

@test "I6: P2/P3 are dropped only for the remote's side, P1 only for the source's: 005 (every format) and tuning 004 on 23-column rows" {
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
	assert_line "3,P1_local_wall,4,2,100,100,100,100,N/A,N/A,"
	assert_line "3,P2_discovery,8,5,50,50,50,50,N/A,N/A,"
	assert_line "3,P3_dataplane,8,5,60,60,60,60,N/A,N/A,"
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

@test "I2/I6: older TSVs (19 and 21 columns) still report; their P2/P3 keep the row rule but never drop for p1_overflow" {
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
			# 21 columns: p1_status (OK on row 2) keeps the iteration's P1 (B2).
			[ "$(jq -c '[.rows[] | [.phase, .n_total, .n_valid]]' <<<"$output")" = \
				'[["P1_local_wall",3,2],["P1_conv_p50",3,2],["P1_conv_p99",3,2],["P2_discovery",3,2],["P3_dataplane",3,2]]' ]
		fi
	done
}

# --- I3: the sweep-level Istio keys in every multi-input report --------------------

DP_HDR=$'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class'
CHURN_HDR=$'run_id\tmesh_size\tchurn_intensity\tbase_replicas\tscale_to\titeration\tt0_epoch_ns\tconvergence_local_ms\tremote_endpoint_reachable_ms\tconvergence_remote_eds_ms\tsource_push_triggers_delta\tremote_push_triggers_delta\tsource_xds_pushes_delta\tremote_xds_pushes_delta\tsource_queue_time_p99_ms\tremote_queue_time_p99_ms\tsource_connected_proxies\tremote_connected_proxies\tsource_push_time_p99_ms\tremote_push_time_p99_ms\tstatus'
CD_HDR=$'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms'
GEN_A="ci-a=2/2,ci-b=3/2"
GEN_B="ci-a=4/2,ci-b=3/2"

# _gen_tsv <suite> <dir> <run_id> <generations|->: one input of the suite's report, with
# `# ISTIO_GENERATIONS=` (none for -).
_gen_tsv() {
	local s="$1" d="$2" id="$3" g="$4" gl=""
	mkdir -p "$d"
	[[ "$g" == - ]] || gl="# ISTIO_GENERATIONS=${g}"
	case "$s" in
	propagation)
		source "${ROOT}/tests/lib/propagation.sh"
		{ echo "# RUN_ID=${id}"; [[ -z "$gl" ]] || echo "$gl"; echo "$PROP_TSV_HEADER"; prop_placeholder_row "$id" 2 ci-a SETUP_FAILED; } > "${d}/endpoint-${id}.tsv" ;;
	dataplane)
		{ echo "# RUN_ID=${id}"; [[ -z "$gl" ]] || echo "$gl"; echo "$DP_HDR"; printf '%s\t2\tci-a\tci-b\t100\t100\t8\t30\t2.0\t2.5\t5.0\t11.0\t12.5\tOK\t100\t0\tremote\n' "$id"; } > "${d}/latency-${id}.tsv" ;;
	churn)
		{ echo "# RUN_ID=${id}"; [[ -z "$gl" ]] || echo "$gl"; echo "$CHURN_HDR"; printf '%s\t2\t5\t1\t5\t1\t0\t1000\t2000\t300\t10\t20\t100\t200\t99\t99\t50\t60\t10\t10\tOK\n' "$id"; } > "${d}/churn-${id}.tsv" ;;
	churn-dataplane)
		{
			echo "# RUN_ID=${id}"; [[ -z "$gl" ]] || echo "$gl"; echo "$CD_HDR"
			printf '%s\tsha\tc1\t2\t%s\t%s\t60\t50\t48\t4\t3\t9\t6\t7\tN/A\t0\tOK\t10\t10\t100\t30\t5\t99\tN/A\tN/A\n' "$id" 0 baseline "$id" 1 churn
		} > "${d}/churn-dataplane-${id}.tsv" ;;
	controlplane)
		G="$gl" ID="$id" awk '/^# HARNESS_SHA=/ && ENVIRON["G"] != "" { print ENVIRON["G"] } /^# RUN_ID=/ { print "# RUN_ID=" ENVIRON["ID"]; next } { print }' \
			"${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv" > "${d}/controlplane-${id}.tsv" ;;
	esac
}

@test "I3 (PL26): ISTIO_GENERATIONS is sweep-level in every multi-input report: inputs that differ read mixed, an input without it reads unknown" {
	local s rep fmt mixed half
	for s in propagation dataplane churn churn-dataplane controlplane; do
		case "$s" in propagation | churn-dataplane) rep="${ROOT}/tests/${s}/005-report-results.sh" ;; *) rep="${ROOT}/tests/${s}/004-report-results.sh" ;; esac
		_gen_tsv "$s" "${RES}/${s}/two" r1 "$GEN_A"
		_gen_tsv "$s" "${RES}/${s}/two" r2 "$GEN_B"
		_gen_tsv "$s" "${RES}/${s}/half" r1 "$GEN_A"
		_gen_tsv "$s" "${RES}/${s}/half" r2 -
		_gen_tsv "$s" "${RES}/${s}/none" r1 -
		# churn records a missing key as "unknown (not recorded)".
		half="unknown"
		[[ "$s" != churn ]] || half="unknown (not recorded)"
		for fmt in text md; do
			run --separate-stderr "$rep" --results-dir "${RES}/${s}/two" --allow-multi-run --format "$fmt"
			assert_success
			[[ "$output" =~ [Ii][Ss][Tt][Ii][Oo]_[Gg][Ee][Nn][Ee][Rr][Aa][Tt][Ii][Oo][Nn][Ss][^$'\n']*"mixed:${GEN_A} "('|'|'\|')" ${GEN_B}" ]] \
				|| { echo "${s} ${fmt} (two): ${output}"; false; }
			run --separate-stderr "$rep" --results-dir "${RES}/${s}/half" --allow-multi-run --format "$fmt"
			[[ "$output" =~ [Ii][Ss][Tt][Ii][Oo]_[Gg][Ee][Nn][Ee][Rr][Aa][Tt][Ii][Oo][Nn][Ss][^$'\n']*"mixed:${GEN_A} "('|'|'\|')" ${half}" ]] \
				|| { echo "${s} ${fmt} (half): ${output}"; false; }
			run --separate-stderr "$rep" --results-dir "${RES}/${s}/none" --format "$fmt"
			[[ "$output" =~ [Ii][Ss][Tt][Ii][Oo]_[Gg][Ee][Nn][Ee][Rr][Aa][Tt][Ii][Oo][Nn][Ss]('='|': '|': "'|' | `')"${half}" ]] \
				|| { echo "${s} ${fmt} (none): ${output}"; false; }
		done
	done
	# tuning 004: over sweep-metadata.txt and every pass's TSVs.
	local P="${BATS_TEST_TMPDIR}/psweep"
	mkdir -p "${P}/baseline" "${P}/01-x"
	{ printf '# SUITE=propagation\n# PASSES=baseline,01-x\n'; echo "# ISTIO_GENERATIONS=${GEN_A}"; } > "${P}/sweep-metadata.txt"
	_gen_tsv propagation "${P}/baseline" r1 "$GEN_A"
	_gen_tsv propagation "${P}/01-x" r2 "$GEN_B"
	run "$TUNING_CMP" --results-dir "$P" --format md
	assert_success
	assert_output --partial "ISTIO_GENERATIONS=mixed:${GEN_A} | ${GEN_B};"
	_gen_tsv propagation "${P}/01-x" r2 -
	run "$TUNING_CMP" --results-dir "$P"
	assert_output --partial "ISTIO_GENERATIONS=mixed:${GEN_A} | unknown;"
}

# --- I4: a --resume of a sweep whose preamble lists a member twice ------------------

@test "I4: 003 --resume refuses a sweep an older harness started with a member twice, whatever --contexts says: start a new sweep" {
	local res="${BATS_TEST_TMPDIR}/res" d tsv bin="${BATS_TEST_TMPDIR}/bin" before cs
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0
	CONTROLPLANE_RESULTS_DIR="$res" KUBECONFIG="$EK" run bash "${ROOT}/tests/controlplane/003-run-sweep.sh" --contexts ci-a,ci-b --mesh-sizes 1 --service-counts 5
	assert_failure 4
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	tsv="$(find "$d" -maxdepth 1 -name 'controlplane-*.tsv')"
	# What a harness before B8 recorded for --contexts ci-a,ci-a,ci-b.
	sed -i.bak -e 's/^# ISTIO_VERSION=.*/# ISTIO_VERSION=v1.30.5/' -e 's/^# ISTIO_ACTIVE_REVISIONS=.*/# ISTIO_ACTIVE_REVISIONS=ci-a=,ci-a=,ci-b=/' "$tsv" && rm -f "${tsv}.bak"
	mkdir -p "$bin"
	printf '#!/bin/sh\nexit 1\n' > "${bin}/kubectl"
	chmod +x "${bin}/kubectl"
	before="$(cat "$tsv")"
	for cs in ci-a,ci-b ci-a ci-b,ci-a ci-a,ci-c; do
		PATH="${bin}:${PATH}" KUBECONFIG="$EK" run bash "${ROOT}/tests/controlplane/003-run-sweep.sh" --resume "$d" --contexts "$cs" --mesh-sizes 1 --service-counts 5
		assert_failure 1
		assert_output --partial "error: --resume: this sweep's TSV preamble lists ci-a twice in ISTIO_ACTIVE_REVISIONS (ci-a=,ci-a=,ci-b=): an older harness took that member twice, so its mesh sizes counted it twice and no --contexts can repeat them (each member is now listed once). Start a new sweep with each mesh member listed once."
		refute_output --partial "Resume with --contexts"
		refute_output --partial "Istio version:"
	done
	# The same through ISTIO_VERSION_BY_CONTEXT, when ISTIO_ACTIVE_REVISIONS is absent.
	sed -i.bak -e '/^# ISTIO_ACTIVE_REVISIONS=/d' -e 's/^# ISTIO_VERSION_BY_CONTEXT=.*/# ISTIO_VERSION_BY_CONTEXT=ci-b=v1.30.5,ci-a=v1.30.5,ci-b=v1.30.5/' "$tsv" && rm -f "${tsv}.bak"
	before="$(cat "$tsv")"
	PATH="${bin}:${PATH}" KUBECONFIG="$EK" run bash "${ROOT}/tests/controlplane/003-run-sweep.sh" --resume "$d" --contexts ci-b,ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 1
	assert_output --partial "lists ci-b twice in ISTIO_VERSION_BY_CONTEXT (ci-b=v1.30.5,ci-a=v1.30.5,ci-b=v1.30.5)"
	# Nothing written: the TSV as it was, no resumes.txt.
	[ "$(cat "$tsv")" = "$before" ]
	[ ! -e "$d/resumes.txt" ]
	# A member given twice now is refused when parsed, before any of this (B8).
	PATH="${bin}:${PATH}" KUBECONFIG="$EK" run bash "${ROOT}/tests/controlplane/003-run-sweep.sh" --resume "$d" --contexts ci-a,ci-b,ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 1
	assert_output --partial "--contexts lists ci-a twice (ci-a,ci-b,ci-a): list each mesh member once"
	refute_output --partial "preamble lists"
}

# --- I5: a sweep that ends before its outcome ----------------------------------------

# _i5_sweep: a sweep's skeleton in i5.sh, its traps as the six sweeps install them:
# `bash i5.sh <dir> <case>` starts its record in <dir> (run i5-run), then ends as <case>.
_i5_sweep() {
	cat > "${BATS_TEST_TMPDIR}/i5.sh" <<'SH'
set -euo pipefail
source "${ROOT}/tests/lib/common.sh"
trap 'sweep_err_trap "$?" "$LINENO" "$BASH_COMMAND"' ERR
D="$1"
# tun / tun-bare: tuning's on_exit shape, its first echo failing (a terminal that closed),
# called with and without `|| true`.
on_exit_t() {
	local rc=$?
	echo ">>> reverting p before exit" >&9
	: > "${D}/reverted"
	sweep_outcome_on_exit "$rc" || true
}
if [[ "$2" == notes ]]; then
	trap 'sweep_outcome_on_exit "$?" --note "REVERT_FAILED: profile p is still applied" || true' EXIT
elif [[ "$2" == tun ]]; then
	trap 'on_exit_t || true' EXIT
elif [[ "$2" == tun-bare ]]; then
	trap 'on_exit_t' EXIT
else
	trap 'sweep_outcome_on_exit "$?" || true' EXIT
fi
sweep_outcome_start "$D" i5-run --next "if it died, run it again into a new dir"
# $? is 1 from here on, as anywhere in a sweep: an EXIT trap a signal runs sees that, so
# only the signal traps can say a signal came.
[[ -n "" ]] && echo never
case "$2" in
die | notes | tun | tun-bare) die "the members went away" ;;
err) false ;;
err4) sh -c 'exit 4' ;;
fn) f() { false; echo never; }; f ;;
fn4) f() { sh -c 'exit 4'; echo never; }; f ;;
int) sh -c 'kill -INT "$PPID"'; sleep 2; echo after ;;
term) sh -c 'kill -TERM "$PPID"'; echo after ;;
hup) sh -c 'kill -HUP "$PPID"'; echo after ;;
child) x="$(sh -c 'kill -TERM $$')" ;;
sub)
	(trap 'sweep_outcome_on_exit 1 || true' EXIT; exit 1) || true
	cp "${D}/sweep-outcome.txt" "${D}/after-subshell.txt"
	die "after the subshell" ;;
done) sweep_outcome --run-id i5-run --record "$D" 1; exit 0 ;;
other) sed -i.bak 's/^RUN_ID=.*/RUN_ID=another-run/' "${D}/sweep-outcome.txt"; die "after another run took the dir" ;;
kill) kill -KILL $$ ;;
esac
echo "fell through"
SH
}

# _i5_run <case>: i5.sh into a fresh dir, its record in $REC.
_i5_run() {
	D="${BATS_TEST_TMPDIR}/i5-$1"
	REC="${D}/sweep-outcome.txt"
	ROOT="$ROOT" run --separate-stderr bash "${BATS_TEST_TMPDIR}/i5.sh" "$D" "$1"
}

@test "I5: a sweep that stops after its start records why (die, the ERR trap, set -e in a function), its notes and what to do, and exits 1 whatever code failed; the reports show a stop, not a run that has not finished; an EXIT trap step that fails stops nothing" {
	_i5_sweep
	_i5_run die
	assert_failure 1
	[[ "$stderr" == *"error: the members went away"* ]]
	grep -qx 'EXIT=1' "$REC"
	grep -qx 'STOPPED=1' "$REC"
	grep -qx 'STOP_REASON=the members went away' "$REC"
	grep -qx 'TOTAL=unknown' "$REC"
	grep -qx 'FAILED=unknown' "$REC"
	grep -q "^PROBLEM=could not count the sweep's cells: it stopped before its end at [0-9T:-]*Z, so no count vouches for its rows, which may be partial$" "$REC"
	grep -qx 'NOTE=next: run it again into a new dir' "$REC"
	grep -qx 'CUT_SHORT=1' "$REC"
	grep -q '^STARTED_AT=[0-9T:-]*Z$' "$REC"
	grep -q '^ENDED_AT=[0-9T:-]*Z$' "$REC"
	grep -qx 'RUN_ID=i5-run' "$REC"
	! grep -q '^ENDED_SIGNAL=' "$REC"
	sweep_outcome_cut_short "$REC"
	! sweep_outcome_unfinished "$REC"
	run sweep_outcome_recorded "$D" text
	assert_output --partial "SWEEP OUTCOME (recorded in sweep-outcome.txt by run i5-run, exit 1):"
	assert_output --partial "  stopped early: the members went away"
	refute_output --partial "NOT FINISHED"
	run sweep_outcome_recorded "$D" md
	assert_output --partial "the members went away"
	run sweep_outcome_recorded "$D" json
	[ "$(jq -c '[.exit, .unfinished, .stop_reason, (.problems | length), .notes]' <<<"$output")" = '[1,false,"the members went away",1,["next: run it again into a new dir"]]' ]
	run sweep_outcome_recorded "$D" csv
	assert_line "# SWEEP_OUTCOME_EXIT=1"
	# The ERR trap: the FATAL line names the script, the line and the command, and so does
	# the record.
	_i5_run err
	assert_failure 1
	[[ "$stderr" =~ FATAL:\ i5\.sh\ aborted\ \(exit\ 1\)\ at\ line\ [0-9]+:\ false ]]
	grep -qE '^STOP_REASON=i5\.sh aborted \(exit 1\) at line [0-9]+: false$' "$REC"
	grep -qx 'EXIT=1' "$REC"
	grep -qx 'CUT_SHORT=1' "$REC"
	# set -e in a function runs no ERR trap: the exit it took is the reason.
	_i5_run fn
	assert_failure 1
	grep -qx 'STOP_REASON=it exited 1 before its end (an unexpected failure: see its console output)' "$REC"
	grep -qx 'STOPPED=1' "$REC"
	# A note the EXIT trap passes (tuning: a revert that failed on exit) is recorded.
	_i5_run notes
	assert_failure 1
	grep -qx 'NOTE=REVERT_FAILED: profile p is still applied' "$REC"
	grep -qx 'NOTE=next: run it again into a new dir' "$REC"
	# A stop exits 1 whatever code the failed command had (4 would read as failed cells,
	# 3 as a reachability stop); the record keeps that code in its reason.
	_i5_run err4
	assert_failure 1
	grep -qE "^STOP_REASON=i5\.sh aborted \(exit 4\) at line [0-9]+: sh -c 'exit 4'$" "$REC"
	grep -qx 'EXIT=1' "$REC"
	_i5_run fn4
	assert_failure 1
	grep -qx 'STOP_REASON=it exited 4 before its end (an unexpected failure: see its console output)' "$REC"
	grep -qx 'EXIT=1' "$REC"
	run sweep_outcome_recorded "$D" json
	[ "$(jq -c '[.exit, .unfinished]' <<<"$output")" = '[1,false]' ]
	# Tuning's EXIT trap runs as `on_exit || true`: an echo that fails (a closed terminal)
	# does not stop it before the revert and the record; without the guard it does.
	_i5_run tun
	assert_failure 1
	[ -e "${D}/reverted" ]
	grep -qx 'STOPPED=1' "$REC"
	_i5_run tun-bare
	[ ! -e "${D}/reverted" ]
	grep -qx 'EXIT=unfinished' "$REC"
}

@test "I5: Ctrl-C, SIGTERM and SIGHUP after a sweep's start leave it not finished, interrupted at a time by that signal (whatever \$? was), and it still dies of the signal; so does a command a signal killed" {
	# The signal traps need a shell that does not ignore SIGINT.
	[[ "$(bash -c 'trap "echo t" INT; kill -INT $$; echo n' 2>/dev/null)" == t* ]] || skip "SIGINT is ignored here"
	local c sig st compat
	_i5_sweep
	for compat in "" 51; do
		for c in int:SIGINT:130 term:SIGTERM:143 hup:SIGHUP:129; do
			IFS=: read -r c sig st <<<"$c"
			BASH_COMPAT="$compat" _i5_run "$c"
			[ "$status" -eq "$st" ] || { echo "${c} (compat ${compat}): ${status} ${stderr}"; false; }
			[[ "$output" != *after* ]]
			[[ "$stderr" == *"warning: the sweep was interrupted (${sig}, exit ${st}) before its outcome; sweep-outcome.txt says it has not finished"* ]]
			grep -qx 'EXIT=unfinished' "$REC"
			grep -q '^ENDED_AT=[0-9T:-]*Z$' "$REC"
			grep -qx "ENDED_EXIT=${st}" "$REC"
			grep -qx "ENDED_SIGNAL=${sig}" "$REC"
			! grep -q '^STOP' "$REC"
			sweep_outcome_unfinished "$REC"
		done
	done
	run sweep_outcome_recorded "$D" text
	assert_output --partial "NOT FINISHED"
	assert_output --regexp "this sweep has not finished: the run that started at [0-9T:-]+Z was interrupted at [0-9T:-]+Z \(SIGHUP: its terminal closed\) before it wrote its outcome, so no cell count vouches for these results, which may be partial; next: run it again into a new dir"
	run sweep_outcome_recorded "$D" json
	[ "$(jq -c '[.exit, .unfinished, (.interrupted_at | test("Z$")), .interrupted_by]' <<<"$output")" = '[null,true,true,"SIGHUP"]' ]
	run sweep_outcome_recorded "$D" csv
	assert_line "# SWEEP_OUTCOME_EXIT=unfinished"
	assert_line "# SWEEP_OUTCOME_INTERRUPTED_BY=SIGHUP"
	assert_line --regexp '^# SWEEP_OUTCOME_INTERRUPTED_AT=[0-9T:-]+Z$'
	_i5_run int
	run sweep_outcome_recorded "$D" text
	assert_output --partial "(SIGINT: Ctrl-C) before it wrote its outcome"
	# A command a signal killed (its exit 143 through the ERR trap): interrupted, no signal named.
	_i5_run child
	assert_failure 143
	grep -qx 'EXIT=unfinished' "$REC"
	grep -qx 'ENDED_EXIT=143' "$REC"
	! grep -q '^ENDED_SIGNAL=' "$REC"
	run sweep_outcome_recorded "$D" text
	assert_output --partial "(exit 143, no error recorded) before it wrote its outcome"
}

@test "I5: the EXIT hook writes nothing in a subshell, after the outcome, or over another run's record; a sweep killed outright (SIGKILL) keeps its record as it was: it died, or still runs" {
	_i5_sweep
	_i5_run sub
	assert_failure 1
	# The subshell's EXIT trap left the record alone; the sweep's own then recorded the die.
	grep -qx 'EXIT=unfinished' "${D}/after-subshell.txt"
	! grep -q '^ENDED_AT=' "${D}/after-subshell.txt"
	grep -qx 'STOP_REASON=after the subshell' "$REC"
	_i5_run done
	assert_success
	grep -qx 'EXIT=0' "$REC"
	! grep -q '^CUT_SHORT=\|^ENDED_AT=' "$REC"
	_i5_run other
	assert_failure 1
	grep -qx 'RUN_ID=another-run' "$REC"
	grep -qx 'EXIT=unfinished' "$REC"
	! grep -q '^ENDED_AT=\|^STOP' "$REC"
	_i5_run kill
	[ "$status" -eq 137 ]
	grep -qx 'EXIT=unfinished' "$REC"
	! grep -q '^ENDED_AT=\|^STOP\|^CUT_SHORT' "$REC"
	run sweep_outcome_recorded "$D" text
	assert_output --partial "this sweep has not finished (it died, or still runs): the run that started at "
}

# _i5_stub <dir>: a kubectl (and oc) that fails every call, as against an empty kubeconfig,
# and that first turns the sweep's markdown summary path (I5_MD, RID for the run id) into a
# directory, so the sweep's own write of it fails at the top level, after its start: an
# unexpected abort (the ERR trap). It keeps a copy of the sweep's record as each call saw it
# (record-at-last-kubectl.txt). I5_INT: its first call after the sweep's start, once a TSV
# is written, sends the sweep SIGINT. I5_CR: the Istio CR reads answer as
# fake-istio-cr.sh (a version a --resume can match). STUB_ISTIOD: one istiod pod
# (churn-dataplane's preflight).
_i5_stub() {
	mkdir -p "$1"
	cat > "${1}/kubectl" <<'STUB'
#!/bin/sh
for d in "$I5_RES"/sweep-*; do
	[ -d "$d" ] || continue
	m="$d/$(printf '%s' "${I5_MD:-}" | sed "s/RID/${d##*/sweep-}/")"
	[ -z "${I5_MD:-}" ] || [ -e "$m" ] || mkdir "$m"
	# What the sweep's record said at this call (the last call wins).
	cp "$d/sweep-outcome.txt" "$I5_RES/record-at-last-kubectl.txt" 2>/dev/null || :
	# I5_INT: once the sweep has started and written a TSV, Ctrl-C reaches it (its
	# *run-sweep.sh ancestor).
	if [ -n "${I5_INT:-}" ] && [ -f "$d/sweep-outcome.txt" ] && [ ! -e "$I5_RES/int-sent" ] \
		&& [ -n "$(find "$d" -name '*.tsv' -type f 2>/dev/null | head -n 1)" ]; then
		p=$PPID
		while [ "${p:-1}" -gt 1 ]; do
			case "$(ps -o args= -p "$p" 2>/dev/null)" in *run-sweep.sh*) : > "$I5_RES/int-sent"; kill -INT "$p"; break ;; esac
			p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
		done
	fi
done
case "$*" in
*"get istios.sailoperator.io default"*|*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	[ -n "${I5_CR:-}" ] || exit 1
	exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" get pods "*"-l app=istiod"*) [ -z "${STUB_ISTIOD:-}" ] || echo istiod-0 ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${1}/kubectl"
	cp "${1}/kubectl" "${1}/oc"
}

@test "I5 (PL33): through each sweep, an unexpected abort after its start (its markdown summary cannot be written) records a stop naming the script, line and command; propagation runs its cleanup first" {
	local suite script md res d bin="${BATS_TEST_TMPDIR}/i5bin" rep
	local -a more
	_i5_stub "$bin"
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0
	for suite in dataplane churn churn-dataplane propagation controlplane; do
		res="${BATS_TEST_TMPDIR}/i5res-${suite}"
		more=()
		case "$suite" in
		dataplane) script=dataplane/003-run-sweep.sh md='sweep-RID.md' rep=dataplane/004-report-results.sh ;;
		churn) script=churn/003-run-sweep.sh md='sweep-RID.md' rep=churn/004-report-results.sh ;;
		churn-dataplane) script=churn-dataplane/004-run-sweep.sh md='sweep-summary-RID.md' rep=churn-dataplane/005-report-results.sh ;;
		propagation) script=propagation/006-run-sweep.sh md='sweep-summary.md' rep=propagation/005-report-results.sh ;;
		controlplane) script=controlplane/003-run-sweep.sh md='sweep-RID.md' rep=controlplane/004-report-results.sh more=(--service-counts 5) ;;
		esac
		I5_RES="$res" I5_MD="$md" STUB_ISTIOD=1 DATAPLANE_RESULTS_DIR="$res" CHURN_RESULTS_DIR="$res" PROPAGATION_RESULTS_DIR="$res" \
			COEXEC_RESULTS_DIR="$res" CONTROLPLANE_RESULTS_DIR="$res" DATAPLANE_INTER_COMBO_SETTLE_SEC=0 COEXEC_INTER_COMBO_SETTLE_SEC=0 \
			PROPAGATION_SETTLE_SEC=0 PATH="${bin}:${PATH}" KUBECONFIG="$EK" \
			run --separate-stderr bash "${ROOT}/tests/${script}" --contexts ci-a --mesh-sizes 1 ${more[@]+"${more[@]}"}
		[ "$status" -eq 1 ] || { echo "${suite}: exit ${status}: ${stderr}"; false; }
		[[ "$suite" != propagation || "$output" == *"--- Final cleanup: all contexts ---"* ]]
		d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
		[[ "$stderr" =~ FATAL:\ ${script##*/}\ aborted\ \(exit\ 1\)\ at\ line\ [0-9]+: ]] || { echo "${suite}: ${stderr}"; false; }
		grep -qx 'EXIT=1' "$d/sweep-outcome.txt"
		grep -qx 'STOPPED=1' "$d/sweep-outcome.txt"
		grep -qE "^STOP_REASON=${script##*/} aborted \(exit 1\) at line [0-9]+: .*report-results\.sh" "$d/sweep-outcome.txt"
		grep -qx 'CUT_SHORT=1' "$d/sweep-outcome.txt"
		grep -q '^NOTE=next: ' "$d/sweep-outcome.txt"
		grep -qx "RUN_ID=${d##*/sweep-}" "$d/sweep-outcome.txt" || [ "$suite" = propagation ]
		# Its report shows the stop, with the reason and exit 1, not a run that has not finished.
		rmdir "$d/${md/RID/${d##*/sweep-}}"
		run --separate-stderr bash "${ROOT}/tests/${rep}" --results-dir "$d" --format text
		[[ "$output" =~ SWEEP\ OUTCOME\ \(recorded\ in\ sweep-outcome\.txt\ by\ run\ [^,]+,\ exit\ 1\) ]] || { echo "${suite}: ${output}"; false; }
		[[ "$output" == *"stopped early: ${script##*/} aborted (exit 1) at line "* ]]
		[[ "$output" != *"NOT FINISHED"* ]]
	done
	# propagation: its EXIT trap ran 007-cleanup (kubectl calls) before it wrote the stop
	# record: the last call still saw the not-finished one.
	res="${BATS_TEST_TMPDIR}/i5res-propagation"
	grep -qx 'EXIT=unfinished' "${res}/record-at-last-kubectl.txt"
}

@test "I5 (PL33): Ctrl-C through a sweep (dataplane after its first mesh size, controlplane while it counts its cells) leaves it not finished, interrupted by SIGINT; a controlplane --resume after a stop record runs, keeps no .prev of it, and replaces it" {
	[[ "$(bash -c 'trap "echo t" INT; kill -INT $$; echo n' 2>/dev/null)" == t* ]] || skip "SIGINT is ignored here"
	local res="${BATS_TEST_TMPDIR}/i5int" d bin="${BATS_TEST_TMPDIR}/i5bin"
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0
	_i5_stub "$bin"
	I5_RES="$res" I5_MD= I5_INT=1 DATAPLANE_RESULTS_DIR="$res" DATAPLANE_INTER_COMBO_SETTLE_SEC=0 PATH="${bin}:${PATH}" KUBECONFIG="$EK" \
		run --separate-stderr bash "${ROOT}/tests/dataplane/003-run-sweep.sh" --contexts ci-a,ci-b --mesh-sizes 1,2
	assert_failure 130
	[ -e "${res}/int-sent" ]
	[[ "$output" != *"Sweep finished"* && "$output" != *"mesh_size=2"* ]]
	[[ "$stderr" == *"warning: the sweep was interrupted (SIGINT, exit 130) before its outcome"* ]]
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	grep -qx 'EXIT=unfinished' "$d/sweep-outcome.txt"
	grep -qx 'ENDED_SIGNAL=SIGINT' "$d/sweep-outcome.txt"
	run --separate-stderr bash "${ROOT}/tests/dataplane/004-report-results.sh" --results-dir "$d" --format text
	assert_output --partial "(SIGINT: Ctrl-C) before it wrote its outcome"
	# controlplane: the cell count's awk (the sweep's own child) is Ctrl-C there.
	local fa="${BATS_TEST_TMPDIR}/fakeawk" cres="${BATS_TEST_TMPDIR}/i5cp"
	mkdir -p "$fa"
	printf '#!/bin/sh\ncase "$*" in *"print \\"TOTAL\\\\t\\" ncell"*) kill -INT "$PPID"; exit 0 ;; esac\nexec %s "$@"\n' "$(command -v awk)" > "${fa}/awk"
	chmod +x "${fa}/awk"
	I5_RES="$cres" I5_MD= I5_CR=1 CONTROLPLANE_RESULTS_DIR="$cres" PATH="${fa}:${bin}:${PATH}" KUBECONFIG="$EK" \
		run --separate-stderr bash "${ROOT}/tests/controlplane/003-run-sweep.sh" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 130
	d="$(find "$cres" -maxdepth 1 -name 'sweep-*' -type d)"
	grep -qx 'EXIT=unfinished' "$d/sweep-outcome.txt"
	grep -qx 'ENDED_SIGNAL=SIGINT' "$d/sweep-outcome.txt"
	# Its --resume, cut short in turn by an unexpected abort (its summary cannot be written):
	# a stop record. A --resume after that runs (the stop is no recorded problem), keeps no
	# sweep-outcome.prev.txt of it (it is no outcome of the sweep), and writes the outcome.
	rm -f "$d/sweep-${d##*/sweep-}.md"
	I5_RES="$cres" I5_MD='sweep-RID.md' I5_CR=1 CONTROLPLANE_RESULTS_DIR="$cres" PATH="${bin}:${PATH}" KUBECONFIG="$EK" \
		run --separate-stderr bash "${ROOT}/tests/controlplane/003-run-sweep.sh" --resume "$d" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 1
	grep -qx 'CUT_SHORT=1' "$d/sweep-outcome.txt"
	[ ! -e "$d/sweep-outcome.prev.txt" ]
	rmdir "$d/sweep-${d##*/sweep-}.md"
	I5_RES="$cres" I5_MD= I5_CR=1 CONTROLPLANE_RESULTS_DIR="$cres" PATH="${bin}:${PATH}" KUBECONFIG="$EK" \
		run --separate-stderr bash "${ROOT}/tests/controlplane/003-run-sweep.sh" --resume "$d" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	[[ "$stderr" != *"records a problem"* ]]
	grep -qx 'EXIT=4' "$d/sweep-outcome.txt"
	! grep -q '^CUT_SHORT=\|^NOTE=next: ' "$d/sweep-outcome.txt"
	[ ! -e "$d/sweep-outcome.prev.txt" ]
}

# _i5_trap_steps_guarded <file>: every step of each of its single-line EXIT traps ends in
# `|| true` or is the `_sweep_rc=$?` assignment (a subshell's pid cleanup trap left out):
# set -e in a trap stops it at a failed step (an echo to a closed terminal) before the
# record.
_i5_trap_steps_guarded() {
	local line step
	local -a steps
	while IFS= read -r line; do
		line="${line#*trap \'}"
		line="${line%\' EXIT}"
		IFS=';' read -r -a steps <<<"$line"
		for step in "${steps[@]}"; do
			step="${step# }"
			[[ "$step" == *"|| true" || "$step" == '_sweep_rc=$?' ]] || { echo "${1}: EXIT trap step not guarded: ${step}"; return 1; }
		done
	done < <(grep -E "^[[:space:]]*trap '.*' EXIT$" "$1" | grep -vF 'pids[@]')
}

@test "I5: every sweep sets its EXIT trap (which calls sweep_outcome_on_exit) before sweep_outcome_start, each of its steps guarded, and its ERR trap is sweep_err_trap" {
	local f t st
	# The check fires on the EXIT trap propagation had before this pass.
	printf '%s\n' "trap '_sweep_rc=\$?; sweep_cleanup; sweep_outcome_on_exit \"\$_sweep_rc\" || true' EXIT" > "${BATS_TEST_TMPDIR}/old.sh"
	run _i5_trap_steps_guarded "${BATS_TEST_TMPDIR}/old.sh"
	assert_failure
	assert_output --partial "EXIT trap step not guarded: sweep_cleanup"
	for f in dataplane/003-run-sweep.sh churn/003-run-sweep.sh churn-dataplane/004-run-sweep.sh propagation/006-run-sweep.sh \
		controlplane/003-run-sweep.sh tuning/003-run-tuning-sweep.sh; do
		f="${ROOT}/tests/${f}"
		_i5_trap_steps_guarded "$f"
		t="$(grep -nE "^[[:space:]]*trap .* EXIT$" "$f" | head -n 1 | cut -d: -f1)"
		st="$(grep -nE '^[[:space:]]*sweep_outcome_start "' "$f" | head -n 1 | cut -d: -f1)"
		[[ -n "$t" && -n "$st" && "$t" -lt "$st" ]] || { echo "${f}: EXIT trap at ${t:-none}, start at ${st:-none}"; false; }
		# The EXIT trap calls the hook (tuning: in on_exit).
		grep -qE 'sweep_outcome_on_exit "\$(\?|_sweep_rc|rc)"' "$f" || { echo "${f}: no sweep_outcome_on_exit"; false; }
		grep -qxF "trap 'sweep_err_trap \"\$?\" \"\$LINENO\" \"\$BASH_COMMAND\"' ERR" "$f" || { echo "${f}: ERR trap"; false; }
	done
}

# --- I7: markdown table cells ---------------------------------------------------------

# _md_tables_even: every markdown table on stdin has as many unescaped | per row as its
# header (a | inside a cell, unescaped, would add a column).
_md_tables_even() {
	awk '
		function bars(s,    n, i, c, p) { n = 0; p = ""; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "|" && p != "\\") n++; p = c }; return n }
		/^\|/ { b = bars($0); if (!intab) { want = b; intab = 1 } else if (b != want) { print "uneven row (" b " vs " want "): " $0; bad = 1 }; next }
		{ intab = 0 }
		END { exit bad }'
}

@test "I7: md_cell and MD_CELL_AWK escape | and turn a newline into a space, as -v or printed, on bash 5.1 rules too" {
	local v
	md_cell -v v $'mixed:a=1,b=2 | a=3,b=2\nnext'
	[ "$v" = 'mixed:a=1,b=2 \| a=3,b=2 next' ]
	[ "$(md_cell 'a|b|c')" = 'a\|b\|c' ]
	[ "$(md_cell 'no pipe \ here')" = 'no pipe \ here' ]
	[ "$(md_cell '')" = '' ]
	[ "$(md_cell '|')" = '\|' ]
	run env BASH_COMPAT=51 bash -c 'source "$1/tests/lib/common.sh"; md_cell -v v "x|y"; printf "%s\n" "$v"; md_cell "|a|"' _ "$ROOT"
	assert_output $'x\\|y\n\\|a\\|'
	run awk "${MD_CELL_AWK}"' BEGIN { print md_cell("a|b|c"); print md_cell("x\ny"); print md_cell("plain") }'
	assert_output $'a\\|b\\|c\nx y\nplain'
}

@test "I7: churn-dataplane 005 markdown escapes | in its run table (a mixed value) and its results cells; every table keeps its columns" {
	local d="${RES}/cd"
	_gen_tsv churn-dataplane "$d" r1 "$GEN_A"
	_gen_tsv churn-dataplane "$d" r2 "$GEN_B"
	# A key with a | in it (a hand-edited TSV): its cell is escaped too.
	awk -F'\t' 'BEGIN { OFS = "\t" } !/^#/ && $1 != "run_id" { $5 = "x|y" } 1' "${d}/churn-dataplane-r2.tsv" > "${d}/x" && mv "${d}/x" "${d}/churn-dataplane-r2.tsv"
	run --separate-stderr "${ROOT}/tests/churn-dataplane/005-report-results.sh" --results-dir "$d" --allow-multi-run --format md
	assert_success
	assert_line "| ISTIO_GENERATIONS | \`mixed:${GEN_A} \\| ${GEN_B}\` |"
	assert_line --regexp '^\| 2 \| x\\\|y \| '
	_md_tables_even <<<"$output"
}

@test "I7: reach_coverage_render md escapes | in a remote's name and error, in its tables and its callout" {
	source "${ROOT}/tests/lib/reach.sh"
	printf '3\ts\tok\t2\t2\tREACHABLE\t-\t-\n3\ts\tde|ad\t2\t0\tUNREACHABLE\t503\tupstream|reset\n' > "${RES}/rows"
	run reach_coverage_render md "${RES}/rows"
	assert_success
	assert_output --partial '| 3 | s | de\|ad | 0/2 | UNREACHABLE | 503 | upstream\|reset |'
	assert_output --partial '| 3 | s | 1/2 | de\|ad |'
	assert_output --partial '> ⚠ Remotes NOT reachable at mesh_size=3 from s: de\|ad (UNREACHABLE 0/2, 503, "upstream\|reset")'
	refute_output --partial 'de|ad'
	_md_tables_even <<<"$output"
}

# --- I8: no fork per file -------------------------------------------------------------

@test "I8: file_min_bytes: at least n bytes, at the boundary, in multibyte text and with NUL bytes; a complete file needs no wc (nothing forked); false for short, empty, missing, a directory or a bad n" {
	local d="${BATS_TEST_TMPDIR}/fmb" i
	mkdir -p "$d/dir"
	printf '%0512d' 0 > "$d/512"
	head -c 511 "$d/512" > "$d/511"
	printf '%0513d' 0 > "$d/513"
	: > "$d/empty"
	# 200 two-byte characters: 400 bytes; 300 of them: 600 bytes.
	for ((i = 0; i < 200; i++)); do printf '\303\251'; done > "$d/mb400"
	for ((i = 0; i < 300; i++)); do printf '\303\251'; done > "$d/mb600"
	# 520 bytes, 10 of them NUL (the read builtin drops them: the wc fallback counts them).
	{ head -c 300 "$d/512"; printf '\0\0\0\0\0\0\0\0\0\0'; head -c 210 "$d/512"; } > "$d/nul520"
	{ head -c 300 "$d/512"; printf '\0\0\0\0\0\0\0\0\0\0'; head -c 100 "$d/512"; } > "$d/nul410"
	for loc in C C.UTF-8; do
		LC_ALL="$loc" file_min_bytes "$d/512" 512
		LC_ALL="$loc" file_min_bytes "$d/513" 512
		! LC_ALL="$loc" file_min_bytes "$d/511" 512
		LC_ALL="$loc" file_min_bytes "$d/511" 511
		! LC_ALL="$loc" file_min_bytes "$d/mb400" 512
		LC_ALL="$loc" file_min_bytes "$d/mb600" 512
		LC_ALL="$loc" file_min_bytes "$d/nul520" 512
		! LC_ALL="$loc" file_min_bytes "$d/nul410" 512
	done
	! file_min_bytes "$d/empty" 512
	! file_min_bytes "$d/missing" 512
	! file_min_bytes "$d/dir" 512
	! file_min_bytes "$d/512" abc
	! file_min_bytes "$d/512" ""
	# n = 0: any readable regular file, empty included.
	file_min_bytes "$d/empty" 0
	! file_min_bytes "$d/dir" 0
	# A complete file is decided by the read builtin alone: no wc on PATH, still true; a
	# short one needs wc, so without it reads as short.
	(PATH="${BATS_TEST_TMPDIR}/no-such-dir"; file_min_bytes "$d/513" 512)
	(PATH="${BATS_TEST_TMPDIR}/no-such-dir"; ! file_min_bytes "$d/nul520" 512)
}

@test "I8: churn 004 reads each input's preamble key once in one awk, as grep -m1 did: a key that differs warns, v1.30.5 and 1.30.5 do not, a missing key reads unknown (not recorded), the first of two lines counts" {
	local d="${RES}/rm"
	_gen_tsv churn "$d" r1 -
	_gen_tsv churn "$d" r2 -
	_gen_tsv churn "$d" r3 -
	sed -i.bak '1a\
# ISTIO_VERSION=v1.30.5\
# ISTIO_ACTIVE_REVISIONS=ci-a=rev-a' "${d}/churn-r1.tsv"
	sed -i.bak '1a\
# ISTIO_VERSION=1.30.5\
# ISTIO_ACTIVE_REVISIONS=ci-a=rev-a\
# ISTIO_ACTIVE_REVISIONS=ci-a=rev-b' "${d}/churn-r2.tsv"
	sed -i.bak '1a\
# ISTIO_VERSION=v1.30.5\
# ISTIO_ACTIVE_REVISIONS=ci-a=rev-b' "${d}/churn-r3.tsv"
	rm -f "$d"/*.bak
	run --separate-stderr "${ROOT}/tests/churn/004-report-results.sh" --results-dir "$d" --allow-multi-run --format csv
	assert_success
	# v1.30.5 and 1.30.5 are one version: no warning.
	assert_line '# ISTIO_VERSION=v1.30.5'
	[[ "$stderr" != *"disagree on ISTIO_VERSION "* ]]
	# r2's first ISTIO_ACTIVE_REVISIONS line counts (as grep -m1): r1 and r2 agree, r3 differs.
	assert_line '# ISTIO_ACTIVE_REVISIONS=mixed:ci-a=rev-a,ci-a=rev-b'
	[[ "$stderr" == *"warning: input TSVs disagree on ISTIO_ACTIVE_REVISIONS (ci-a=rev-a,ci-a=rev-b); the report mixes runs"* ]]
	# A key no input records reads unknown (not recorded), without a warning.
	assert_line '# ISTIO_PROXY_VERSIONS=unknown (not recorded)'
	[[ "$stderr" != *"disagree on ISTIO_PROXY_VERSIONS"* ]]
	# r3 on rev-a too: every first line reads rev-a (r2's second line is not read).
	sed -i.bak 's/^# ISTIO_ACTIVE_REVISIONS=ci-a=rev-b$/# ISTIO_ACTIVE_REVISIONS=ci-a=rev-a/' "${d}/churn-r3.tsv" && rm -f "${d}/churn-r3.tsv.bak"
	run --separate-stderr "${ROOT}/tests/churn/004-report-results.sh" --results-dir "$d" --allow-multi-run --format csv
	assert_line '# ISTIO_ACTIVE_REVISIONS=ci-a=rev-a'
	[[ "$stderr" != *"disagree on ISTIO_ACTIVE_REVISIONS"* ]]
	# One input without a key the others record: mixed with unknown, and a warning.
	sed -i.bak '/^# ISTIO_ACTIVE_REVISIONS=/d' "${d}/churn-r3.tsv" && rm -f "${d}/churn-r3.tsv.bak"
	run --separate-stderr "${ROOT}/tests/churn/004-report-results.sh" --results-dir "$d" --allow-multi-run --format csv
	assert_line '# ISTIO_ACTIVE_REVISIONS=mixed:ci-a=rev-a,unknown (not recorded)'
	[[ "$stderr" == *"warning: input TSVs disagree on ISTIO_ACTIVE_REVISIONS (ci-a=rev-a,unknown (not recorded))"* ]]
}

# --- I9: redact-results: AWS resource ids, file and dir names -----------------------

REDACT="${ROOT}/tests/lib/redact-results.sh"

# _i9_fixture <dir>: a sweep dir whose TSV names ci-a and ci-b and holds AWS resource ids,
# with files and dirs named after a context (a tuning pass and its revert state, a note),
# and raw istiod-diag evidence named after one.
_i9_fixture() {
	local d="$1/sweep-r9"
	mkdir -p "${d}/pass-1-ci-a/state" "${d}/istiod-diag-r9/001-restart-ci-b"
	cat > "${d}/run-r9.tsv" <<'TSV'
# CONTEXTS=ci-a,ci-b
run_id	context	detail
r9	ci-a	vpc-0123abcd subnet-0123456789abcdef0 sg-deadbeef,i-0123456789abcdef0 eni-12345678 vol-0a1b2c3d igw-00000000 nat-ffffffff rtb-a1b2c3d4 (vpc-0123abcd) "subnet-0123abcd"
r9	ci-b	stays: sg-0123abcd0123 my-sg-0123abcd sg-0123abcdx i-0123ABCD vpc-0123abc i-0123456789abcdef01 vpce-0123abcd
TSV
	echo '{"ok":true}' > "${d}/pass-1-ci-a/state/istio-revert-ci-a.json"
	echo 'on ci-b' > "${d}/notes-ci-b.md"
	echo 'raw' > "${d}/istiod-diag-r9/001-restart-ci-b/istiod.log.txt"
}

@test "I9: redact-results masks AWS resource ids with 8 or 17 hex digits, as its own word; a 12-digit suffix, a longer one, upper case or a longer name stays" {
	_i9_fixture "$RES"
	local out="${BATS_TEST_TMPDIR}/copy"
	run --separate-stderr "$REDACT" --out "$out" "${RES}/sweep-r9"
	assert_success
	run cat "${out}/sweep-r9/run-r9.tsv"
	assert_line $'r9\t<mesh-a-ctx>\t<vpc-id> <subnet-id> <sg-id>,<instance-id> <eni-id> <volume-id> <igw-id> <nat-id> <rtb-id> (<vpc-id>) "<subnet-id>"'
	assert_line $'r9\t<mesh-b-ctx>\tstays: sg-0123abcd0123 my-sg-0123abcd sg-0123abcdx i-0123ABCD vpc-0123abc i-0123456789abcdef01 vpce-0123abcd'
	# The dry run counts them as their own kind.
	run "$REDACT" --dry-run "${RES}/sweep-r9"
	assert_success
	assert_line --regexp '^  would change  .*/sweep-r9/run-r9\.tsv \(3 line\(s\): context [0-9]+, aws-id 11\)$'
}

@test "I9: --out renames a file or dir whose name holds a context (no angle brackets), lists each rename on stderr only, and the copy names no context in a path" {
	_i9_fixture "$RES"
	local out="${BATS_TEST_TMPDIR}/copy" before after
	before="$(cd "$RES" && find . | LC_ALL=C sort)"
	run --separate-stderr "$REDACT" --out "$out" "${RES}/sweep-r9"
	assert_success
	assert_output --partial "3 of 3 file(s) written under ${out}, 0 refused, 2 renamed"
	refute_output --partial "ci-a"
	refute_output --partial "ci-b"
	[[ "$stderr" == *"renamed in the copy (stderr only):"* ]]
	[[ "$stderr" == *"sweep-r9/pass-1-ci-a/state/istio-revert-ci-a.json -> sweep-r9/pass-1-mesh-a-ctx/state/istio-revert-mesh-a-ctx.json"* ]]
	[[ "$stderr" == *"sweep-r9/notes-ci-b.md -> sweep-r9/notes-mesh-b-ctx.md"* ]]
	[ -f "${out}/sweep-r9/pass-1-mesh-a-ctx/state/istio-revert-mesh-a-ctx.json" ]
	grep -qx 'on <mesh-b-ctx>' "${out}/sweep-r9/notes-mesh-b-ctx.md"
	# No path in the copy names a context; the input is untouched.
	run find "$out" -name '*ci-[ab]*'
	assert_output ""
	after="$(cd "$RES" && find . | LC_ALL=C sort)"
	[ "$before" = "$after" ]
	# A dir given by a context's name is renamed in the copy too.
	mv "${RES}/sweep-r9" "${RES}/ci-a"
	run --separate-stderr "$REDACT" --out "${BATS_TEST_TMPDIR}/copy2" "${RES}/ci-a"
	assert_success
	[ -f "${BATS_TEST_TMPDIR}/copy2/mesh-a-ctx/run-r9.tsv" ]
	[ ! -e "${BATS_TEST_TMPDIR}/copy2/ci-a" ]
	# The file-name form of a name (other characters as _) maps to the same placeholder.
	mkdir -p "${RES}/s2"
	printf '# CONTEXTS=ns/api-c1:6443/admin,ci-b\n' > "${RES}/s2/run.tsv"
	echo '{}' > "${RES}/s2/istio-revert-ns_api-c1_6443_admin.json"
	run --separate-stderr "$REDACT" --out "${BATS_TEST_TMPDIR}/copy3" "${RES}/s2"
	assert_success
	[ -f "${BATS_TEST_TMPDIR}/copy3/s2/istio-revert-mesh-b-ctx.json" ]
	grep -qx '# CONTEXTS=<mesh-b-ctx>,<mesh-a-ctx>' "${BATS_TEST_TMPDIR}/copy3/s2/run.tsv"
}

@test "I9: --in-place renames below the given dir and a given file, removes the emptied old dirs, and lists what still names a context (skipped files); a dry run renames nothing" {
	_i9_fixture "$RES"
	local d="${RES}/sweep-r9"
	run --separate-stderr "$REDACT" --dry-run --in-place "$d"
	assert_success
	assert_output --partial "3 file(s), 2 would change, 0 refused, 2 would be renamed"
	[[ "$stderr" == *"file and dir names it would rename (stderr only):"* ]]
	[ -f "${d}/notes-ci-b.md" ]
	run --separate-stderr "$REDACT" --in-place "$d"
	assert_success
	assert_output --partial "3 file(s), 2 rewritten in place, 0 refused, 2 renamed"
	[ -f "${d}/pass-1-mesh-a-ctx/state/istio-revert-mesh-a-ctx.json" ]
	[ -f "${d}/notes-mesh-b-ctx.md" ]
	[ ! -e "${d}/pass-1-ci-a" ]
	[ ! -e "${d}/notes-ci-b.md" ]
	# The raw evidence is skipped, so it keeps its name: listed once, by its topmost path.
	[ -f "${d}/istiod-diag-r9/001-restart-ci-b/istiod.log.txt" ]
	[[ "$stderr" == *"still named after a context, neither redacted nor renamed"* ]]
	grep -qxF "  ${d}/istiod-diag-r9/001-restart-ci-b" <<<"$stderr"
	! grep -qxF "  ${d}/istiod-diag-r9/001-restart-ci-b/istiod.log.txt" <<<"$stderr"
	# A second run finds nothing more to rename.
	run --separate-stderr "$REDACT" --in-place "$d"
	assert_success
	assert_output --partial "0 refused, 0 renamed"
	# A given file is renamed where it is.
	printf 'on ci-c\n' > "${RES}/note-ci-c.md"
	run --separate-stderr "$REDACT" --in-place --context ci-c "${RES}/note-ci-c.md"
	assert_success
	grep -qx 'on <mesh-a-ctx>' "${RES}/note-mesh-a-ctx.md"
	[ ! -e "${RES}/note-ci-c.md" ]
}

@test "I9: --in-place refuses, before it writes anything, a given dir named after a context, a rename onto a path that exists, and two files that land at one name" {
	_i9_fixture "$RES"
	local before
	_i9_tree() { (cd "$RES" && find . -print && find . -type f -exec cksum {} +) | LC_ALL=C sort; }
	mv "${RES}/sweep-r9" "${RES}/ci-a"
	before="$(_i9_tree)"
	run --separate-stderr "$REDACT" --in-place "${RES}/ci-a"
	assert_failure
	[[ "$stderr" == *"holds a context name in its own name, and --in-place renames only what is below it"* ]]
	[ "$before" = "$(_i9_tree)" ]
	# The new name is taken by a path the run does not list (a dir): mv would move the
	# file into it.
	mkdir -p "${RES}/x/a-mesh-a-ctx.md"
	printf '# CONTEXTS=ci-b\n' > "${RES}/x/run.tsv"
	printf 'on ci-b\n' > "${RES}/x/a-ci-b.md"
	before="$(_i9_tree)"
	run --separate-stderr "$REDACT" --in-place "${RES}/x"
	assert_failure
	[[ "$stderr" == *"x/a-ci-b.md would be renamed to ${RES}/x/a-mesh-a-ctx.md, which exists"* ]]
	[ "$before" = "$(_i9_tree)" ]
	# Two listed files that land at one name.
	rmdir "${RES}/x/a-mesh-a-ctx.md"
	printf 'other\n' > "${RES}/x/a-mesh-a-ctx.md"
	run --separate-stderr "$REDACT" --in-place "${RES}/x"
	assert_failure
	[[ "$stderr" == *"two files land at x/a-mesh-a-ctx.md once their names are redacted"* ]]
	grep -qx 'on ci-b' "${RES}/x/a-ci-b.md"
	grep -qx '# CONTEXTS=ci-b' "${RES}/x/run.tsv"
	# --out refuses it the same way.
	run --separate-stderr "$REDACT" --out "${BATS_TEST_TMPDIR}/copy" "${RES}/x"
	assert_failure
	[[ "$stderr" == *"two files land at x/a-mesh-a-ctx.md"* ]]
	[ ! -e "${BATS_TEST_TMPDIR}/copy" ]
	# A renamed dir whose new name is a file (one the run skips): mv cannot go below it.
	rm "${RES}/x/a-mesh-a-ctx.md"
	mkdir -p "${RES}/x/d-ci-b" && printf 'on ci-b\n' > "${RES}/x/d-ci-b/n.md" && printf 'x' > "${RES}/x/d-mesh-a-ctx"
	before="$(_i9_tree)"
	run --separate-stderr "$REDACT" --in-place "${RES}/x"
	assert_failure
	[[ "$stderr" == *"x/d-ci-b/n.md would move below ${RES}/x/d-mesh-a-ctx, which is not a dir"* ]]
	[ "$before" = "$(_i9_tree)" ]
}

#!/usr/bin/env bats
# Which samples a probe keeps and its report counts, through the real scripts (PL33) on
# stub kubectl, oc and curl: controlplane 002 --watch windows (a failed final scrape is an
# N/A row), the P1 that propagation keeps when only the remotes failed (002, 005, tuning
# 004), churn 002's remote EDS poller that never completed a scrape, and tuning 004's P1
# cell naming its overflowed iterations. Names are placeholders (ci-a, ctx-a), addresses
# come from 192.0.2.0/24.

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr
source "${ROOT}/tests/lib/timestamp.sh"
source "${ROOT}/tests/lib/metrics.sh"
source "${ROOT}/tests/lib/fanout.sh"
source "${ROOT}/tests/lib/config.sh"

FX="${ROOT}/tests/lib/test/fixtures/istiod-diag"
PROP_HDR=$'run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms'

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
	KC="${BATS_TEST_TMPDIR}/empty.kubeconfig"
	: > "$KC"
	export TMPDIR="$BATS_TEST_TMPDIR"
}

# _stub_bin: kubectl, oc and helm that log every call, and a curl that serves /metrics
# from STUB_PRE_BODY before the probe's change (STUB_MARK) and STUB_POST_BODY after.
# STUB_COUNT switches /metrics to a numbered body per call; STUB_EDS_FAIL fails the
# churn EDS poller's scrapes.
_stub_bin() {
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log" STUB_MARK="${BATS_TEST_TMPDIR}/post.mark" FX
	: > "$STUB_LOG"
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*) exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" fortio load "*" -json - "*) : > "$STUB_MARK"; cat "$FX/../fortio_ok.json" ;;
*" get pod -l app=fortio-client "*) printf 'fortio-client-0\t\tTrue' ;;
*" exec "*) cat "$FX/../fortio_ok.json" ;;
*" scale "*" --replicas=1 "*) : ;;
*" scale "*) : > "$STUB_MARK" ;;
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
	printf '#!/usr/bin/env bash\nprintf "oc %%s\\n" "$*" >> "$STUB_LOG"\nexit 1\n' > "${BIN}/oc"
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
if [[ -n "${STUB_EDS_FAIL:-}" && "$out" == */eds-poll-* ]]; then exit 7; fi
case "$url" in
*/metrics)
	if [[ -n "${STUB_COUNT:-}" ]]; then
		[[ "$out" == /dev/null ]] && exit 0
		n=$(( $(cat "$STUB_COUNT" 2>/dev/null || echo 0) + 1 ))
		echo "$n" > "$STUB_COUNT"
		[[ " ${STUB_FAIL_CALLS:-} " != *" $n "* ]] || exit 7
		mem=3.145728e+08
		[[ " ${STUB_BIG_CALLS:-} " != *" $n "* ]] || mem=4.294967296e+09
		body="$(sed -e "s/^process_resident_memory_bytes .*/process_resident_memory_bytes $mem/" \
			-e "s/^pilot_xds_pushes{type=\"eds\"} .*/pilot_xds_pushes{type=\"eds\"} $((n * 100))/" "$FX/pre_metrics.txt")"
		if [[ -n "$out" ]]; then printf '%s\n' "$body" > "$out"; else printf '%s\n' "$body"; fi
		exit 0
	fi
	body="$STUB_PRE_BODY"; [[ -f "$STUB_MARK" ]] && body="$STUB_POST_BODY" ;;
*/clusters) body="$FX/../fortio_ok.json" ;;
*/ready) echo LIVE; exit 0 ;;
*/debug/syncz) echo '[]'; exit 0 ;;
*) exit 7 ;;
esac
if [[ -n "$out" ]]; then cp "$body" "$out"; else cat "$body"; fi
STUB
	chmod +x "${BIN}/kubectl" "${BIN}/oc" "${BIN}/curl"
	export STUB_PRE_BODY="${FX}/pre_metrics.txt" STUB_POST_BODY="${FX}/pre_metrics.txt"
}

_prop_run() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$KC" run --separate-stderr "${ROOT}/tests/propagation/002-run-endpoint-probe.sh" \
		--source-context ctx-a --timeout 2 --poll-interval-ms 100 --settle-sec 0 --tsv \
		--output-dir "$RES" "$@"
}

# prow21 <iteration> <remote> <p1_ms> <status> <p1_overflow> <restarted> <p1_status> <p1_scrape_skew_ms>
prow21() {
	local p2=50 p3=60
	[[ "$4" == OK ]] || { p2=N/A p3=N/A; }
	printf 'r1\t3\t%s\tsrc\t%s\t0\t%s\t%s\t%s\t%s\t99\t99\t10/10\t10\t%s\t%s\t0\t5000\t10\t%s\t%s\n' \
		"$1" "$2" "$3" "$p2" "$p3" "$4" "$5" "$6" "$7" "$8"
}

@test "controlplane 002 --watch: a failed final scrape is an N/A row, never the last window's gauges; peaks are per window" {
	_stub_bin
	# A short sleep (the script polls every 5 s and waits 3 s for its port-forwards).
	printf '#!/bin/sh\nexec %s 0.05\n' "$(command -v sleep)" > "${BIN}/sleep"
	chmod +x "${BIN}/sleep"
	# Body calls per window: baseline, one peak poll, final. Call 2 (window 1's poll) reads
	# 4 GiB; call 6 (window 2's final) fails. Each body's eds counter is 100 x its number.
	export STUB_COUNT="${BATS_TEST_TMPDIR}/count" STUB_FAIL_CALLS=6 STUB_BIG_CALLS=2
	PATH="${BIN}:${PATH}" KUBECONFIG="$KC" "${ROOT}/tests/controlplane/002-collect-resource-metrics.sh" \
		--contexts ctx-a --config-dump-samples 0 --output-dir "$RES" --watch --interval 1 \
		> "${BATS_TEST_TMPDIR}/out" 2> "${BATS_TEST_TMPDIR}/err" 3>&- &
	local pid=$! i f="" rows=0
	for ((i = 0; i < 600; i++)); do
		f="$(ls "$RES"/controlplane-*.tsv 2>/dev/null | head -1)"
		if [[ -n "$f" ]]; then
			rows="$(awk -F'\t' '!/^#/ && $1 != "timestamp"' "$f" | wc -l | tr -d ' ')"
			((rows >= 3)) && break
		fi
		sleep 0.1
	done
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	[ "$rows" -ge 3 ]
	# context, istiod_mem_mi, istiod_restarted, xds_pushes_delta of the first three rows.
	run awk -F'\t' '$1 == "timestamp" { for (i = 1; i <= NF; i++) ix[$i] = i; next }
		!/^#/ && n++ < 3 { print $(ix["context"]), $(ix["istiod_mem_mi"]), $(ix["istiod_restarted"]), $(ix["xds_pushes_delta"]) }' "$f"
	assert_line --index 0 "ctx-a 4096 0 200"
	# Window 2: its final scrape failed. An older probe reused window 1's final body
	# (memory 4096, restarted 0) and read the counter's drop from 400 to 300 as a reset.
	assert_line --index 1 "ctx-a N/A unknown N/A"
	# Window 3: its own peak (300 Mi), not window 1's 4 GiB.
	assert_line --index 2 "ctx-a 300 0 200"
	grep -q "no final scrape for ctx-a/istiod-abc-x1; emitting N/A row" "${BATS_TEST_TMPDIR}/err"
	run grep -c "counter went from" "${BATS_TEST_TMPDIR}/err"
	assert_output 0
	# The harness provenance comes from harness_sha (-dirty.<8hex> on a dirty tree).
	grep -qxF "# HARNESS_SHA=$(source "${ROOT}/tests/lib/preamble.sh"; harness_sha)" "$f"
	[ "$(grep -cE '^# HARNESS_SHA=.*-dirty$' "$f" || true)" = 0 ]
}

@test "propagation 002 + 005: every remote timed out, the source was clean: P1 is n=1/1 in the summary and every 005 format" {
	_stub_bin
	hist() { printf 'pilot_proxy_convergence_time_bucket{le="0.1"} %s\npilot_proxy_convergence_time_bucket{le="+Inf"} %s\npilot_proxy_convergence_time_sum %s\npilot_proxy_convergence_time_count %s\n' "$1" "$1" "$2" "$1"; }
	{ cat "${FX}/pre_metrics.txt"; hist 0 0; } > "${BATS_TEST_TMPDIR}/pre.txt"
	{ cat "${FX}/pre_metrics.txt"; hist 10 0.5; } > "${BATS_TEST_TMPDIR}/post.txt"
	STUB_PRE_BODY="${BATS_TEST_TMPDIR}/pre.txt" STUB_POST_BODY="${BATS_TEST_TMPDIR}/post.txt" \
		_prop_run --remote-contexts ctx-b --iterations 1
	assert_success
	f="$(ls "$RES"/endpoint-*.tsv)"
	# The remote's P2/P3 timed out (the stub never shows the canary there); P1 is clean.
	# remote_status (22) is the remote's own verdict, remote_scrape_skew_ms (23) its skew.
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $10 "/" $20 "/" $21 "/" $22 "/" $23 }' "$f")" = "TIMEOUT_P3/OK/0/TIMEOUT_P3/0" ]
	# One schema for every writer (PL36): the shared header, 23 fields on every line.
	source "${ROOT}/tests/lib/propagation.sh"
	grep -qxF "$PROP_TSV_HEADER" "$f"
	[ "$(awk -F'\t' '!/^#/ { print NF }' "$f" | sort -u)" = 23 ]
	# The harness provenance comes from harness_sha (-dirty.<8hex> on a dirty tree,
	# never a bare -dirty that names no content).
	grep -qxF "# HARNESS_SHA=$(source "${ROOT}/tests/lib/preamble.sh"; harness_sha)" "$f"
	[ "$(grep -cE '^# HARNESS_SHA=.*-dirty$' "$f" || true)" = 0 ]
	# An older summary read n=0/1: the iteration's only row was dropped for a remote reason.
	assert_output --regexp 'P1 local xDS push: +n=1/1 min=[0-9]+ms'
	assert_output --regexp 'P3 remote sidecar: +n=0/1 \(no valid sample\)'
	grep -qE '^\| P1 local xDS push \| 1/1 \| [0-9]+ \|' "$RES"/endpoint-*.md
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$RES" --format csv
	assert_line --regexp '^2,P1_local_wall,1,1,[0-9]+,'
	assert_line --regexp '^2,P3_dataplane,1,0,'
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$RES" --format md
	assert_line --regexp '^\| P1 local xDS \(wall\) \| 1 \| 1 \| [0-9]+ \|'
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$RES"
	assert_output --regexp 'P1 local xDS \(wall\) +\| +1 \| +1 \|'
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$RES" --format json
	[ "$(jq -c '[.rows[] | select(.phase == "P1_local_wall" or .phase == "P3_dataplane") | [.phase, .n_total, .n_valid]]' <<<"$output")" = \
		'[["P1_local_wall",1,1],["P3_dataplane",1,0]]' ]
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$RES" --format charts
	assert_success
}

@test "005 and tuning 004 on 21-column rows: remote failures keep P1; a source restart, overflow or skew drops it" {
	{
		echo "# RUN_ID=r1"
		platform_fixture_lines src,b,c
		printf '%s\tp1_status\tp1_scrape_skew_ms\n' "$PROP_HDR"
		# 1: both remotes timed out, the source was clean: P1 counts.
		prow21 1 b 100 TIMEOUT_P3 0 0 OK 5
		prow21 1 c 100 TIMEOUT_P2 0 0 OK 5
		# 2: a remote restarted (restarted=1 on its row), the source was clean: P1 counts.
		prow21 2 b 200 RESTART 0 1 OK 5
		prow21 2 c 200 OK 0 0 OK 5
		# 3: the source istiod restarted: P1 is dropped, whatever the remotes did.
		prow21 3 b 900 OK 0 0 RESTART 5
		prow21 3 c 900 OK 0 0 RESTART 5
		# 4: P1 overflowed: dropped.
		prow21 4 b 900 OK 1 0 OK 5
		prow21 4 c 900 OK 1 0 OK 5
		# 5: the source scrape skewed past FANOUT_MAX_SKEW_MS: dropped.
		prow21 5 b 900 OK 0 0 OK 5000
		prow21 5 c 900 OK 0 0 OK 5000
	} > "${RES}/endpoint-r1.tsv"
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -c '[.rows[] | select(.phase == "P1_local_wall") | [.n_total, .n_valid, .avg_ms]]' <<<"$output")" = '[[5,2,150]]' ]
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$RES" --format csv
	assert_line "3,P1_local_wall,5,2,100,200,150,100,N/A,N/A,,"
	# The same rules in tuning 004 (one shared definition).
	P="${BATS_TEST_TMPDIR}/psweep"
	mkdir -p "${P}/baseline"
	printf '# SUITE=propagation\n# PASSES=baseline\n' > "${P}/sweep-metadata.txt"
	cp "${RES}/endpoint-r1.tsv" "${P}/baseline/"
	run "${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "$P" --format md
	assert_success
	[[ "$output" == *"| P1 local push (ms) | 150.00 (1 overflowed) |"$'\n'"|   n (got/attempted) | 2/5 |"* ]]
	# A legacy 19-column file keeps the old rule: an iteration with no valid row has no P1.
	{
		echo "# RUN_ID=r2"
		echo "$PROP_HDR"
		prow21 1 b 100 TIMEOUT_P3 0 0 OK 5 | cut -f1-19
		prow21 2 b 200 OK 0 0 OK 5 | cut -f1-19
	} > "${BATS_TEST_TMPDIR}/legacy.tsv"
	mkdir -p "${BATS_TEST_TMPDIR}/legacy"
	mv "${BATS_TEST_TMPDIR}/legacy.tsv" "${BATS_TEST_TMPDIR}/legacy/endpoint-r2.tsv"
	# (It predates the platform record too: a warning on stderr.)
	run --separate-stderr "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "${BATS_TEST_TMPDIR}/legacy" --format json
	[ "$(jq -c '[.rows[] | select(.phase == "P1_local_wall") | [.n_total, .n_valid]]' <<<"$output")" = '[[2,1]]' ]
}

@test "churn 002: no complete scrape of the remote istiod is SCRAPE_INCOMPLETE_REMOTE_EDS, not TIMEOUT_REMOTE_EDS; 004 counts it in n_total only" {
	_stub_bin
	export CHURN_POLL_INTERVAL_MS=50
	_churn() {
		PATH="${BIN}:${PATH}" KUBECONFIG="$KC" run --separate-stderr "${ROOT}/tests/churn/002-run-churn-probe.sh" \
			--source-context ctx-a --remote-contexts ctx-b --iterations 1 --timeout 2 --settle 0 \
			--deployment-count 1 --output-dir "$1"
	}
	_col() { awk -F'\t' -v c="$1" '$1 == "run_id" { for (i = 1; i <= NF; i++) ix[$i] = i; next } !/^#/ { print $(ix[c]) }' "$2"; }
	# Clean scrapes, no EDS push in the window: a real timeout.
	_churn "${RES}/clean"
	assert_success
	[ "$(_col status "$(ls "$RES"/clean/churn-*.tsv)")" = TIMEOUT_REMOTE_EDS ]
	# Every poller scrape fails: nothing was measured.
	rm -f "$STUB_MARK"
	STUB_EDS_FAIL=1 _churn "${RES}/inc"
	assert_success
	assert_output --partial "Convergence (remote ctx-b, EDS push): not measured (no complete scrape of its istiod)"
	f="$(ls "$RES"/inc/churn-*.tsv)"
	[ "$(_col convergence_remote_eds_ms "$f")" = N/A ]
	[ "$(_col status "$f")" = SCRAPE_INCOMPLETE_REMOTE_EDS ]
	run "${ROOT}/tests/churn/004-report-results.sh" --results-dir "${RES}/inc" --format md
	assert_success
	assert_output --regexp '\| 2 \| 1 \| 1->5 \| 1 \| 0 \|'
	run "${ROOT}/tests/churn/004-report-results.sh" --results-dir "${RES}/inc" --format csv
	assert_line "2,1,1,5,rows_valid_of_total,0,0,1,0,,"
	run "${ROOT}/tests/churn/004-report-results.sh" --results-dir "${RES}/inc"
	assert_output --regexp 'Rows \(valid/total\): +0/1'
	run "${ROOT}/tests/churn/004-report-results.sh" --help
	assert_output --partial "SCRAPE_INCOMPLETE_REMOTE_EDS"
	grep -q 'SCRAPE_INCOMPLETE_REMOTE_EDS' "${ROOT}/tests/churn/README.md"
}

@test "tuning 004: the P1 local push cell says how many overflowed iterations its mean leaves out, in md and text" {
	P="${BATS_TEST_TMPDIR}/psweep"
	mkdir -p "${P}/baseline" "${P}/01-x"
	printf '# SUITE=propagation\n# PASSES=baseline,01-x\n' > "${P}/sweep-metadata.txt"
	prow() { printf 'r1\t2\t%s\tsrc\t%s\t0\t%s\t50\t60\tOK\t99\t99\t10/10\t10\t0\t0\t0\t5000\t10\n' "$1" "$2" "$3"; }
	local i r
	{
		echo "# RUN_ID=r1"
		echo "$PROP_HDR"
		for i in 1 2 3 4 5; do for r in b c; do prow "$i" "$r" 100; done; done
	} > "${P}/baseline/endpoint-r1.tsv"
	# Iterations 2-4 overflowed (every row carries p1_overflow=1); iteration 5 also
	# restarted, which drops it for the restart, so it is not counted as overflowed.
	{
		echo "# RUN_ID=r2"
		echo "$PROP_HDR"
		for i in 1 2 3 4 5; do for r in b c; do prow "$i" "$r" "$((100 * i))"; done; done \
			| awk -F'\t' 'BEGIN { OFS = "\t" } $3 >= 2 && $3 <= 4 { $15 = 1 } $3 == 5 { $15 = 1; $16 = 1 } 1'
	} > "${P}/01-x/endpoint-r2.tsv"
	run "${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "$P" --format md
	assert_success
	[[ "$output" == *"| P1 local push (ms) | 100.00 | 100.00 (+0.0%) (3 overflowed) |"$'\n'"|   n (got/attempted) | 5/5 | 1/5 (baseline n 5/5) |"* ]]
	assert_output --partial '"(N overflowed)" in the P1 local push cell'
	run "${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "$P"
	assert_success
	assert_output --regexp 'P1 local push \(ms\) +100\.00 +100\.00 \(\+0\.0%\) \(3 overflowed\)'
	# The baseline had none: its cell has no note.
	refute_output --regexp 'P1 local push \(ms\) +100\.00 \([0-9]+ overflowed\)'
}

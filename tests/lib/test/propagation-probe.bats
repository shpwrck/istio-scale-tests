#!/usr/bin/env bats
# The propagation probe (002), its sweep's placeholder (006) and snapshot (004), through the
# real scripts (PL33) with a stub kubectl and curl, no cluster: which side's failure leaves
# out which phase, the drain check and the t0 check (NOT_DRAINED), a drain that timed out
# (DRAIN_TIMEOUT), the label removal when a run is cut short, and the order of the steps
# around t0; then 005 and tuning 004 on 23-column rows and on older 19- and 21-column ones.
# 005's other figures have their own tests (propagation-report.bats). Event order and
# counts, never elapsed seconds (PL44). Names are placeholders (ctx-a, ctx-b, ci-a),
# addresses come from 192.0.2.0/24.

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

# _stub: kubectl and curl that log every call, in order, to STUB_LOG ("kubectl <args>",
# "curl <url> > <out>").
#   The t0 label flip (label ...=true) creates STUB_MARK: istiod /metrics then serve
#   STUB_SRC_POST on the source's port-forward block (21014-21033) and STUB_RMT_POST on the
#   remote's (21034 on), both CLEAN_POST unless a test sets them (P1 converges, the EDS
#   counter bumps; RESTARTED_POST is the same from a restarted istiod), and the remote's
#   watcher (port 15100) shows the canary endpoint healthy, unless STUB_NO_CANARY=1.
#   The label removal clears STUB_MARK; with STUB_DRAIN_LATE=1 only at the next
#   iteration's port-forward liveness read (curl -o /dev/null of /metrics, after the drain
#   wait), so the drain times out and the next drain check reads clean; with
#   STUB_UNLABEL_FAIL=1 it fails. With STUB_TERM_AT_FLIP=1 the flip sends SIGTERM to the
#   probe (its parent).
#   Before the flip, on the watcher port STUB_PRE_PORT (15100 the remote, 15101 the
#   source), a data read (curl -f; the port-forward's readiness probe is not one) numbered
#   n shows the canary endpoint healthy when STUB_PRE_FROM <= n <= STUB_PRE_UNTIL, or
#   fails with STUB_PRE_MODE=unreadable.
_stub() {
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export STUB_LOG="${BATS_TEST_TMPDIR}/calls.log" STUB_MARK="${BATS_TEST_TMPDIR}/post.mark"
	export STUB_LATE="${BATS_TEST_TMPDIR}/late.mark" STUB_PRE_COUNT="${BATS_TEST_TMPDIR}/pre.count" FX
	: > "$STUB_LOG"
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "$STUB_LOG"
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*) exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" label pod/"*"=true "*)
	: > "$STUB_MARK"
	if [[ -n "${STUB_TERM_AT_FLIP:-}" ]]; then kill -TERM "$PPID"; fi ;;
*" label pod/"*)
	if [[ -n "${STUB_UNLABEL_FAIL:-}" ]]; then exit 1; fi
	if [[ -n "${STUB_DRAIN_LATE:-}" ]]; then : > "$STUB_LATE"; else rm -f "$STUB_MARK"; fi ;;
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
out="" url="" fail=0
while (($#)); do
	case "$1" in
	-o) out="$2"; shift 2 ;;
	-f*) fail=1; shift ;;
	http://*) url="$1"; shift ;;
	*) shift ;;
	esac
done
printf 'curl %s > %s\n' "$url" "${out:--}" >> "$STUB_LOG"
port="${url#http://localhost:}"
port="${port%%/*}"
healthy="outbound|80||propagation-canary.ns.svc.cluster.local::192.0.2.10:8080::health_flags::healthy"
case "$url" in
*/metrics)
	if [[ "$out" == /dev/null && -f "$STUB_LATE" ]]; then rm -f "$STUB_MARK" "$STUB_LATE"; fi
	body="$STUB_PRE_BODY"
	if [[ -f "$STUB_MARK" ]]; then
		if ((port >= 21034)); then body="$STUB_RMT_POST"; else body="$STUB_SRC_POST"; fi
	fi ;;
*/clusters)
	if [[ -f "$STUB_MARK" && "$port" == 15100 && -z "${STUB_NO_CANARY:-}" ]]; then echo "$healthy"; exit 0; fi
	if [[ ! -f "$STUB_MARK" && "$port" == "${STUB_PRE_PORT:-none}" && "$fail" == 1 ]]; then
		n=0
		if [[ -s "$STUB_PRE_COUNT" ]]; then n="$(<"$STUB_PRE_COUNT")"; fi
		n=$((n + 1))
		echo "$n" > "$STUB_PRE_COUNT"
		if [[ "${STUB_PRE_MODE:-}" == unreadable ]]; then exit 22; fi
		if ((n >= ${STUB_PRE_FROM:-1} && n <= ${STUB_PRE_UNTIL:-1000000})); then echo "$healthy"; exit 0; fi
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

# _fresh: a new results dir and call log, the stub's marks cleared, for the next run.
_fresh() {
	rm -rf "$RES" "$STUB_PRE_COUNT" "$STUB_MARK" "$STUB_LATE"
	mkdir -p "$RES"
	: > "$STUB_LOG"
}

# _run <iterations>: the real 002, ctx-a the source, ctx-b the one remote; a drain waits
# at most 1s, P2/P3 at most RUN_TIMEOUT (3) s.
_run() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" PROPAGATION_DRAIN_TIMEOUT_SEC=1 run --separate-stderr \
		"${PR}/002-run-endpoint-probe.sh" --source-context ctx-a --remote-contexts ctx-b --timeout "${RUN_TIMEOUT:-3}" \
		--poll-interval-ms 100 --settle-sec 0 --tsv --output-dir "$RES" --iterations "$1"
}

# _row <cols>: the given columns of the endpoint TSV's data rows, slash-joined.
_row() {
	awk -F'\t' -v c="$1" 'BEGIN { n = split(c, k, ",") } !/^#/ && $1 != "run_id" {
		s = ""; for (i = 1; i <= n; i++) s = s (i > 1 ? "/" : "") $(k[i]); print s }' "$RES"/endpoint-*.tsv
}

# _line <regex> [first|last]: the line number in STUB_LOG of the first (or last) call
# matching an extended regex; 0 when none does.
_line() {
	awk -v re="$1" -v w="${2:-first}" '$0 ~ re { n = NR; if (w == "first") { print n; found = 1; exit } }
		END { if (!found) print n + 0 }' "$STUB_LOG"
}

# _md_tables_even: every markdown table on stdin has as many unescaped | per row as its
# header (a | inside a cell, unescaped, would add a column).
_md_tables_even() {
	awk '
		function bars(s,    n, i, c, p) { n = 0; p = ""; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "|" && p != "\\") n++; p = c }; return n }
		/^\|/ { b = bars($0); if (!intab) { want = b; intab = 1 } else if (b != want) { print "uneven row (" b " vs " want "): " $0; bad = 1 }; next }
		{ intab = 0 }
		END { exit bad }'
}

# _tuning <tsv>: a one-pass tuning sweep over <tsv>, compared by tuning 004 (md).
_tuning() {
	local P="${BATS_TEST_TMPDIR}/psweep"
	rm -rf "$P"
	mkdir -p "${P}/baseline"
	printf '# SUITE=propagation\n# PASSES=baseline\n' > "${P}/sweep-metadata.txt"
	cp "$1" "${P}/baseline/"
	run --separate-stderr "$TUNING_CMP" --results-dir "$P" --format md
	assert_success
}

# prow23 <iteration> <remote> <status> <p1_overflow> <restarted> <p1_status> <p1_skew> <remote_status> <remote_skew>:
# a 23-column row, p1 100 ms, P2 50 ms and P3 60 ms when remote_status is OK or
# DRAIN_TIMEOUT (measured; else N/A).
prow23() {
	local p2=50 p3=60
	[[ "$8" == OK || "$8" == DRAIN_TIMEOUT ]] || { p2=N/A p3=N/A; }
	printf 'r1\t3\t%s\tsrc\t%s\t0\t100\t%s\t%s\t%s\t99\t99\t10/10\t10\t%s\t%s\t0\t5000\t10\t%s\t%s\t%s\t%s\n' \
		"$1" "$2" "$p2" "$p3" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}

# _phases: [phase, n_total, n_valid] of each row of 005's json output.
_phases() { jq -c '[.rows[] | [.phase, .n_total, .n_valid]]' <<<"$output"; }

@test "002: a failure on one side leaves out that side's phases only: the source istiod restarted (P1 out, P2/P3 count), the remote's restarted (P2/P3 out, P1 counts), every remote timed out (P1 counts); 002 writes the one 23-column schema, which 005 reads" {
	local f
	_stub
	STUB_SRC_POST="$RESTARTED_POST" _run 1
	assert_success
	# status (10) and restarted (16) are the row's, over both sides; p1_status (20) is the
	# source's, remote_status (22) the remote's alone; p2_ms (8) and p3_ms (9) are numbers:
	# the remote istiod's counters did not reset.
	[ "$(_row 10,16,20,22)" = RESTART/1/RESTART/OK ]
	[[ "$(_row 8)" =~ ^[0-9]+$ && "$(_row 9)" =~ ^[0-9]+$ ]]
	assert_output --partial "P1 local xDS push:          n=0/1 (no valid sample)"
	assert_output --regexp 'P2 remote istiod EDS push: +n=1/1 min=[0-9]+ms'
	assert_output --regexp 'P3 remote sidecar: +n=1/1 min=[0-9]+ms'
	assert_output --partial "rows_dropped_total=0/1"
	assert_output --regexp 'P1 iterations left out .*'$'\n''    RESTART +1'
	grep -qE '^\| P2 remote istiod EDS push \| 1/1 \| [0-9]+ \|' "$RES"/endpoint-*.md
	grep -qxF '| P1 local xDS push | 0/1 | - | - | - |' "$RES"/endpoint-*.md
	# One schema for every writer (PL36): the shared header, 23 fields on every line; the
	# harness that measured the rows.
	f="$(ls "$RES"/endpoint-*.tsv)"
	source "${ROOT}/tests/lib/propagation.sh"
	grep -qxF "$PROP_TSV_HEADER" "$f"
	[ "$(awk -F'\t' '!/^#/ { print NF }' "$f" | sort -u)" = 23 ]
	[ "$(sed -n 's/^# HARNESS_SHA=//p' "$f")" = "$(harness_sha)" ]
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format json
	assert_success
	[ "$(_phases)" = '[["P1_local_wall",1,0],["P1_conv_p50",1,0],["P1_conv_p99",1,0],["P2_discovery",1,1],["P3_dataplane",1,1]]' ]
	# The remote's istiod restarted. (p1_conv_p99 needs 30 samples, it has 10: N/A.)
	_fresh
	STUB_RMT_POST="$RESTARTED_POST" _run 1
	assert_success
	[ "$(_row 8,16,20,22)" = N/A/1/OK/RESTART ]
	assert_output --regexp 'P1 local xDS push: +n=1/1 min=[0-9]+ms'
	assert_output --partial "P2 remote istiod EDS push:  n=0/1 (no valid sample)"
	assert_output --partial "rows_dropped_total=1/1"
	assert_output --regexp '    RESTART +1'
	grep -qxF '| `RESTART` | 1 |' "$RES"/endpoint-*.md
	# Every remote timed out (its watcher never shows the canary). An older summary read
	# P1 n=0/1: the iteration's only row was dropped for a remote reason.
	_fresh
	STUB_NO_CANARY=1 RUN_TIMEOUT=1 _run 1
	assert_success
	# remote_scrape_skew_ms (23) is the remote's skew.
	[ "$(_row 10,20,21,22,23)" = TIMEOUT_P3/OK/0/TIMEOUT_P3/0 ]
	assert_output --regexp 'P1 local xDS push: +n=1/1 min=[0-9]+ms'
	assert_output --regexp 'P3 remote sidecar: +n=0/1 \(no valid sample\)'
	grep -qE '^\| P1 local xDS push \| 1/1 \| [0-9]+ \|' "$RES"/endpoint-*.md
}

@test "002: a side whose canary endpoint is not confirmed gone before t0 is NOT_DRAINED: still healthy on its watcher after the drain wait (the remote's P2/P3, or the source's P1, left out), a /clusters that cannot be read (not waited for), healthy again at the t0 check; one that drains within the wait settles and counts" {
	_stub
	STUB_PRE_PORT=15100 _run 1
	assert_success
	[ "$(_row 10,20,22)" = NOT_DRAINED/OK/NOT_DRAINED ]
	# The warning names the iteration, the member, the state and the knob.
	[[ "$stderr" == *"Warning: iteration 1/1: ctx-b: a canary endpoint from an earlier iteration or run is still healthy on its watcher after PROPAGATION_DRAIN_TIMEOUT_SEC=1s"*": this iteration's P2/P3 for it are NOT_DRAINED"* ]]
	assert_output --regexp 'P1 local xDS push: +n=1/1 min=[0-9]+ms'
	assert_output --partial "P2 remote istiod EDS push:  n=0/1 (no valid sample)"
	assert_output --partial "P3 remote sidecar:          n=0/1 (no valid sample)"
	assert_output --regexp '    NOT_DRAINED +1'
	grep -qxF '| `NOT_DRAINED` | 1 |' "$RES"/endpoint-*.md
	_md_tables_even < "$(ls "$RES"/endpoint-*.md)"
	# On the source's watcher: P1 is NOT_DRAINED, the remote's P2/P3 count.
	_fresh
	STUB_PRE_PORT=15101 _run 1
	assert_success
	[ "$(_row 10,20,22)" = NOT_DRAINED/NOT_DRAINED/OK ]
	[[ "$stderr" == *"Warning: iteration 1/1: ctx-a: a canary endpoint from an earlier iteration or run is still healthy"*"P1 is NOT_DRAINED"* ]]
	assert_output --partial "P1 local xDS push:          n=0/1 (no valid sample)"
	assert_output --regexp 'P2 remote istiod EDS push: +n=1/1 min=[0-9]+ms'
	# The remote's /clusters cannot be read before t0: the drain cannot be confirmed. The
	# warning says so (not "still healthy"), and the check does not wait for it: its three
	# tries are the only reads before t0 (a wait would read again until the drain timeout).
	_fresh
	STUB_PRE_PORT=15100 STUB_PRE_MODE=unreadable _run 1
	assert_success
	[ "$(_row 10,20,22)" = NOT_DRAINED/OK/NOT_DRAINED ]
	[[ "$stderr" == *"Warning: iteration 1/1: ctx-b: its watcher's /clusters could not be read (the port-forward to deploy/propagation-watcher on localhost:15100), so its drain cannot be checked: this iteration's P2/P3 for it are NOT_DRAINED"* ]]
	[[ "$stderr" != *"still healthy"* ]]
	[ "$(cat "$STUB_PRE_COUNT")" = 3 ]
	# Read 1 (the drain check) is clean, read 2 (the t0 check) shows it healthy.
	_fresh
	STUB_PRE_PORT=15100 STUB_PRE_FROM=2 _run 1
	assert_success
	[ "$(_row 10,20,22)" = NOT_DRAINED/OK/NOT_DRAINED ]
	[[ "$stderr" == *"Warning: iteration 1/1: ctx-b: the canary endpoint is already healthy on its watcher before t0"* ]]
	# Healthy on reads 1 and 2 (the drain check waits), gone on read 3: drained, settled,
	# clean at t0: every status OK, nothing left out.
	_fresh
	STUB_PRE_PORT=15100 STUB_PRE_UNTIL=2 _run 1
	assert_success
	[ "$(_row 10,20,22)" = OK/OK/OK ]
	assert_output --partial "drained just now. Settling for 0s before the baseline"
	[[ "$stderr" != *"NOT_DRAINED"* ]]
	assert_output --partial "rows_dropped_total=0/1"
}

@test "002: an iteration whose drain timed out (DRAIN_TIMEOUT) counts, a flag, not a drop, and the next drain check settles before its baseline even when it reads clean; 002, 005 and tuning 004 each say how many drained late" {
	local it2 settle base2 note="The drain after 1 of 2 iteration(s) timed out (DRAIN_TIMEOUT"
	_stub
	STUB_DRAIN_LATE=1 _run 2
	assert_success
	[ "$(_row 3,10,20,22 | tr '\n' ' ')" = "1/DRAIN_TIMEOUT/OK/DRAIN_TIMEOUT 2/OK/OK/OK " ]
	[[ "$stderr" != *"NOT_DRAINED"* ]]
	assert_output --partial "P2 remote istiod EDS push:  n=2/2 "
	assert_output --partial "P3 remote sidecar:          n=2/2 "
	assert_output --partial "rows_dropped_total=0/2"
	assert_output --partial "$note"
	grep -qF "$note" "$RES"/endpoint-*.md
	grep -qF '| P2 remote istiod EDS push | 2/2 |' "$RES"/endpoint-*.md
	# Iteration 2 settles between its start and its baseline scrape, once in the run.
	it2="$(grep -n -- '--- Iteration 2/2 ---' <<<"$output" | cut -d: -f1)"
	settle="$(grep -n "The previous iteration's drain timed out: its removal may still be pushing. Settling for 0s before the baseline" <<<"$output" | cut -d: -f1)"
	base2="$(grep -n 'Scraping baselines' <<<"$output" | sed -n 2p | cut -d: -f1)"
	[[ -n "$it2" && -n "$settle" && -n "$base2" ]]
	((it2 < settle && settle < base2))
	[ "$(grep -c "The previous iteration's drain timed out" <<<"$output")" -eq 1 ]
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format json
	assert_success
	[[ "$(jq -r '.data_warnings[0]' <<<"$output")" == "mesh size 2: the drain after 1 iteration(s) timed out (DRAIN_TIMEOUT"* ]]
	[[ "$stderr" == *"WARNING: mesh size 2: the drain after 1 iteration(s) timed out (DRAIN_TIMEOUT"* ]]
	[ "$(jq -c '[.rows[] | select(.phase == "P2_discovery" or .phase == "P3_dataplane") | .n_valid]' <<<"$output")" = '[2,2]' ]
	_tuning "$(ls "$RES"/endpoint-*.tsv)"
	assert_line "| Drain timeouts (iterations, counted) | 1 |"
	[ "$(grep -A1 '^| P2 remote EDS (ms) |' <<<"$output" | tail -1)" = "|   n (got/attempted) | 2/2 |" ]
}

@test "002: a run ended by SIGTERM right after its t0 label flip removes the label on exit, each request bounded at 5s, inside SWEEP_STOP_GRACE_SEC; a removal that fails says how to remove it by hand; a run that drains itself removes it once, in the iteration (10s)" {
	local flip unlabel rto grace
	_stub
	STUB_TERM_AT_FLIP=1 _run 1
	[ "$status" -eq 143 ]
	flip="$(_line ' label pod/canary-backer-0 propagation-active=true ')"
	unlabel="$(_line ' label pod/canary-backer-0 propagation-active- ')"
	((flip > 0 && unlabel > flip))
	[[ "$stderr" == *"The run ended before its drain: removed the propagation-active label from pod canary-backer-0 on ctx-a."* ]]
	rto="$(sed -n 's/^kubectl .* --request-timeout=\([0-9]*\)s label pod\/canary-backer-0 propagation-active- .*/\1/p' "$STUB_LOG")"
	[ "$rto" = 5 ]
	# The label call makes two requests (read, then patch): both fit in the default grace
	# a stopping sweep gives the probe before SIGKILL.
	grace="$(env -u SWEEP_STOP_GRACE_SEC bash -c 'source "$1/config/options.env" && echo "$SWEEP_STOP_GRACE_SEC"' _ "$ROOT")"
	((2 * rto <= grace))
	# The removal fails: the warning gives the command, and the run still ends.
	_fresh
	STUB_TERM_AT_FLIP=1 STUB_UNLABEL_FAIL=1 _run 1
	[ "$status" -eq 143 ]
	[[ "$stderr" == *"warning: could not remove the propagation-active label from pod canary-backer-0 on ctx-a"*"Remove it: kubectl --context=ctx-a -n propagation-test label pod/canary-backer-0 propagation-active-"* ]]
	# A run that drains itself: the iteration's own removal (10s per request), none on exit.
	_fresh
	_run 1
	assert_success
	[ "$(grep -c ' label pod/canary-backer-0 propagation-active- ' "$STUB_LOG")" -eq 1 ]
	[ "$(grep -c -- '--request-timeout=10s label pod/canary-backer-0 propagation-active- ' "$STUB_LOG")" -eq 1 ]
	[[ "$stderr" != *"The run ended before its drain"* ]]
}

@test "002: the backer resolve, its Ready wait and then the t0 check run before the baseline scrape; nothing runs between that scrape and the t0 flip" {
	local resolve ready base_first base_last flip between
	_stub
	_run 1
	assert_success
	resolve="$(_line '^kubectl .* get pods -l app=propagation-canary ')"
	ready="$(_line '^kubectl .* wait pod/canary-backer-0 ')"
	base_first="$(_line '/baseline-1/' first)"
	base_last="$(_line '/baseline-1/' last)"
	flip="$(_line ' label pod/canary-backer-0 propagation-active=true ')"
	((resolve > 0 && ready > resolve && base_first > ready && flip > base_last))
	# The t0 check, between the Ready wait and the baseline scrape: one watcher /clusters
	# read per side and nothing else. The flip comes right after the last baseline scrape.
	between="$(awk -v a="$ready" -v b="$base_first" 'NR > a && NR < b' "$STUB_LOG")"
	[ "$(grep -vc '^curl http://localhost:151[0-9][0-9]/clusters > -$' <<<"$between")" -eq 0 ]
	[ "$(grep -c '/clusters' <<<"$between")" -eq 2 ]
	((flip == base_last + 1))
}

@test "005 (every format) and tuning 004 on 23-column rows: P2/P3 are left out only for the remote's side (restart, timeout, skew, NOT_DRAINED), P1 only for the source's (restart, overflow, NOT_DRAINED); DRAIN_TIMEOUT counts; tuning 004 names the overflowed iterations its P1 mean leaves out" {
	source "${ROOT}/tests/lib/propagation.sh"
	{
		echo "# RUN_ID=r1"
		platform_fixture_lines src,b,c
		echo "$PROP_TSV_HEADER"
		# 1: the source istiod restarted (P1 also overflowed: left out for the restart, not
		# counted as overflowed): P1 dropped, both remotes' P2/P3 count.
		prow23 1 b RESTART 1 1 RESTART 5 OK 5
		prow23 1 c RESTART 1 1 RESTART 5 OK 5
		# 2: P1 overflowed: P1 dropped, P2/P3 count.
		prow23 2 b OK 1 0 OK 5 OK 5
		prow23 2 c OK 1 0 OK 5 OK 5
		# 3: the source was clean; remote b restarted, c timed out: P1 counts, no P2/P3.
		prow23 3 b RESTART 0 1 OK 5 RESTART 5
		prow23 3 c TIMEOUT_P3 0 0 OK 5 TIMEOUT_P3 5
		# 4: remote b's scrape skewed past FANOUT_MAX_SKEW_MS: b dropped, c counts.
		prow23 4 b SCRAPE_INCOMPLETE 0 0 OK 5 OK 5000
		prow23 4 c SCRAPE_INCOMPLETE 0 0 OK 5 OK 5
		# 5: remote b was not drained before t0: b dropped, c and P1 count.
		prow23 5 b NOT_DRAINED 0 0 OK 5 NOT_DRAINED 5
		prow23 5 c OK 0 0 OK 5 OK 5
		# 6: the source was not drained before t0: P1 dropped, P2/P3 count.
		prow23 6 b NOT_DRAINED 0 0 NOT_DRAINED 5 OK 5
		prow23 6 c NOT_DRAINED 0 0 NOT_DRAINED 5 OK 5
		# 7: remote b's drain timed out after the window: everything counts.
		prow23 7 b DRAIN_TIMEOUT 0 0 OK 5 DRAIN_TIMEOUT 5
		prow23 7 c OK 0 0 OK 5 OK 5
	} > "${RES}/endpoint-r1.tsv"
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format json
	assert_success
	[ "$(_phases)" = '[["P1_local_wall",7,4],["P1_conv_p50",7,4],["P1_conv_p99",7,4],["P2_discovery",14,10],["P3_dataplane",14,10]]' ]
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format csv
	assert_line "3,P1_local_wall,7,4,100,100,100,100,N/A,N/A,,"
	assert_line "3,P2_discovery,14,10,50,50,50,50,N/A,N/A,,"
	assert_line "3,P3_dataplane,14,10,60,60,60,60,N/A,N/A,,"
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format md
	assert_output --partial "| P1 local xDS (wall) | 7 | 4 |"
	assert_output --partial "| P2 remote istiod EDS | 14 | 10 |"
	assert_output --partial "| P3 remote sidecar | 14 | 10 |"
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES"
	assert_output --regexp 'P1 local xDS \(wall\) +\| +7 \| +4 \|'
	assert_output --regexp 'P2 remote istiod EDS +\| +14 \| +10 \|'
	# The drop reasons, row by row (prop_drop_reason, prop_p1_drop_reason), as 002's summary
	# tallies them.
	run awk -F'\t' "${PROP_ROW_AWK}"'/^#/ || $1 == "run_id" { next } { print $3 $5 ":" prop_drop_reason(1000) ":" prop_p1_drop_reason(1000) }' "${RES}/endpoint-r1.tsv"
	assert_output "$(printf '%s\n' 1b::RESTART 1c::RESTART 2b::p1_overflow 2c::p1_overflow 3b:RESTART: 3c:TIMEOUT_P3: '4b:remote_scrape_skew>1000:' 4c:: 5b:NOT_DRAINED: 5c:: 6b::NOT_DRAINED 6c::NOT_DRAINED 7b:: 7c::)"
	# tuning 004: the same rows (one shared definition).
	_tuning "${RES}/endpoint-r1.tsv"
	[[ "$output" == *"| P1 local push (ms) | 100.00 (1 overflowed) |"$'\n'"|   n (got/attempted) | 4/7 |"* ]]
	[[ "$output" == *"| P2 remote EDS (ms) | 50.00 |"$'\n'"|   n (got/attempted) | 10/14 |"* ]]
	[[ "$output" == *"| P3 remote sidecar (ms) | 60.00 |"$'\n'"|   n (got/attempted) | 10/14 |"* ]]
	assert_line "| Drain timeouts (iterations, counted) | 1 |"
}

@test "005 on older TSVs (19 and 21 columns): P2/P3 keep the row rule (any status but OK or DRAIN_TIMEOUT, a restart, drops the row) and never drop for p1_overflow; P1 reads p1_status and p1_scrape_skew_ms where the TSV has them, and in 19 columns has no sample for an iteration without a counting row" {
	local w
	source "${ROOT}/tests/lib/propagation.sh"
	for w in 19 21; do
		rm -rf "$RES"
		mkdir -p "$RES"
		{
			echo "# RUN_ID=r1"
			cut -f1-"$w" <<<"$PROP_TSV_HEADER"
			# 1: P1 overflowed on an otherwise clean row: P1 dropped, P2/P3 count.
			prow23 1 b OK 1 0 OK 5 OK 5 | cut -f1-"$w"
			# 2: a restart on the row (either side, not split before field 22): P2/P3 dropped;
			# P1 too where the TSV cannot tell which side restarted (19 columns).
			prow23 2 b RESTART 0 1 OK 5 RESTART 5 | cut -f1-"$w"
			# 3: clean.
			prow23 3 b OK 0 0 OK 5 OK 5 | cut -f1-"$w"
			# 4: the remote timed out, the source was clean.
			prow23 4 b TIMEOUT_P3 0 0 OK 5 TIMEOUT_P3 5 | cut -f1-"$w"
			# 5: its drain timed out after the window: counts, with the warning.
			prow23 5 b DRAIN_TIMEOUT 0 0 OK 5 DRAIN_TIMEOUT 5 | cut -f1-"$w"
			# 6: not drained before t0.
			prow23 6 b NOT_DRAINED 0 0 OK 5 NOT_DRAINED 5 | cut -f1-"$w"
			# 7: the source scrape skewed past FANOUT_MAX_SKEW_MS (p1_scrape_skew_ms, field 21).
			prow23 7 b OK 0 0 OK 5000 OK 5 | cut -f1-"$w"
		} > "${RES}/endpoint-r1.tsv"
		# (They predate the platform record too: its keys read unknown.)
		run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format json
		assert_success
		[[ "$(jq -r '.data_warnings[]' <<<"$output")" == *"mesh size 3: the drain after 1 iteration(s) timed out (DRAIN_TIMEOUT"* ]]
		if ((w == 19)); then
			# P1: iterations 3, 5 and 7 (no skew column); P2/P3: rows 1, 3, 5 and 7.
			[ "$(_phases)" = '[["P1_local_wall",7,3],["P1_conv_p50",7,3],["P1_conv_p99",7,3],["P2_discovery",7,4],["P3_dataplane",7,4]]' ]
		else
			# P1: p1_status keeps iterations 2, 4 and 6 too; the skew drops 7.
			[ "$(_phases)" = '[["P1_local_wall",7,5],["P1_conv_p50",7,5],["P1_conv_p99",7,5],["P2_discovery",7,4],["P3_dataplane",7,4]]' ]
		fi
	done
}

@test "006's SETUP_FAILED placeholder is written in 002's 23-column schema, with the sweep start's harness; 005 counts it in n_total and n_attempted only" {
	local d f
	PROPAGATION_RESULTS_DIR="$RES" PROPAGATION_SETTLE_SEC=0 ISTIO_VERSION_CHECK=warn ISTIO_VERSION_READY_WAIT_SEC=0 \
		KUBECONFIG="$EK" run --separate-stderr bash "${PR}/006-run-sweep.sh" --contexts ci-a --mesh-sizes 1
	assert_failure 4
	d="$(find "$RES" -maxdepth 1 -name 'sweep-*' -type d)"
	f="$(ls "$d"/endpoint-*.tsv)"
	source "${ROOT}/tests/lib/propagation.sh"
	grep -qxF "$PROP_TSV_HEADER" "$f"
	[ "$(awk -F'\t' '!/^#/ { print NF }' "$f" | sort -u)" = 23 ]
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $10 "/" $16 "/" $20 "/" $22 }' "$f")" = SETUP_FAILED/unknown/SETUP_FAILED/SETUP_FAILED ]
	[ "$(sed -n 's/^# HARNESS_SHA=//p' "$f")" = "$(harness_sha)" ]
	# n_attempted: the placeholder's ITERATIONS (10), one row each at mesh size 1.
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$d" --format json
	assert_success
	[ "$(jq -c '[.rows[] | [.phase, .n_total, .n_valid, .n_attempted]]' <<<"$output")" = \
		'[["P1_local_wall",1,0,10],["P1_conv_p50",1,0,10],["P1_conv_p99",1,0,10],["P2_discovery",1,0,10],["P3_dataplane",1,0,10]]' ]
}

@test "004: a snapshot file is named by ctx_file_safe (the file-name form redact-results.sh maps), byte for byte in a UTF-8 locale; only pilot_* lines are kept" {
	local ctx=$'ci-\xc3\xa9' out="${BATS_TEST_TMPDIR}/out"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export FX
	# kubectl: one Running istiod pod per context; a port-forward waits to be killed.
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
case " $* " in
*" get pods -l app=istiod --field-selector=status.phase=Running "*) printf 'istiod-x1\n' ;;
*" port-forward "*) exec sleep 30 ;;
*) exit 1 ;;
esac
STUB
	# curl: every /metrics read serves the fixture (to -o FILE, or discarded).
	cat > "${BIN}/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while (($#)); do
	case "$1" in
	-o) out="$2"; shift 2 ;;
	*) shift ;;
	esac
done
if [[ -n "$out" && "$out" != /dev/null ]]; then cp "$FX/pre_metrics.txt" "$out"; fi
exit 0
STUB
	chmod +x "${BIN}/kubectl" "${BIN}/curl"
	# Two bytes, two underscores: a character class in a UTF-8 locale would write one.
	[ "$(ctx_file_safe "$ctx")" = "ci-__" ]
	LC_ALL=C.UTF-8 PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr \
		"${PR}/004-collect-pilot-metrics.sh" --contexts "$ctx" --output-dir "$out"
	assert_success
	run find "$out" -name '*.prom'
	assert_output --regexp "/ci-__-istiod-x1-[0-9]{8}T[0-9]{6}Z\.prom$"
	[ "$(grep -vc '^pilot_' "$out"/ci-__-istiod-x1-*.prom)" -eq 0 ]
}

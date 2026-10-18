#!/usr/bin/env bats
# propagation 002's drain check: a canary endpoint still healthy on a watcher after the
# drain wait, or healthy again just before t0, makes that side NOT_DRAINED, and 005 and
# tuning 004 leave it out; one that drains within the wait settles. Stub kubectl and curl,
# no cluster (PL33); no exact elapsed seconds (PL44). Names are placeholders (ci-a),
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

# _md_tables_even: every markdown table on stdin has as many unescaped | per row as its
# header (a | inside a cell, unescaped, would add a column).
_md_tables_even() {
	awk '
		function bars(s,    n, i, c, p) { n = 0; p = ""; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "|" && p != "\\") n++; p = c }; return n }
		/^\|/ { b = bars($0); if (!intab) { want = b; intab = 1 } else if (b != want) { print "uneven row (" b " vs " want "): " $0; bad = 1 }; next }
		{ intab = 0 }
		END { exit bad }'
}

# _prop_stub: kubectl that answers the propagation probe's reads, and a curl that serves
# istiod /metrics (STUB_PRE_BODY before the t0 label flip, STUB_MARK; CLEAN_POST after)
# and the watchers' /clusters: after the flip the remote's (port 15100) shows the canary
# endpoint healthy, so its P3 succeeds. Before the flip, on the watcher port
# STUB_PRE_PORT (15100 the remote, 15101 the source), a data read (curl -f; the
# port-forward's readiness probe is not one) numbered n shows the canary endpoint
# healthy when STUB_PRE_FROM <= n <= STUB_PRE_UNTIL, or fails with
# STUB_PRE_MODE=unreadable.
_prop_stub() {
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log" STUB_MARK="${BATS_TEST_TMPDIR}/post.mark" FX
	export STUB_PRE_COUNT="${BATS_TEST_TMPDIR}/pre.count"
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
out="" url="" fail=0
while (($#)); do
	case "$1" in
	-o) out="$2"; shift 2 ;;
	-f*) fail=1; shift ;;
	http://*) url="$1"; shift ;;
	*) shift ;;
	esac
done
port="${url#http://localhost:}"
port="${port%%/*}"
healthy="outbound|80||propagation-canary.ns.svc.cluster.local::192.0.2.10:8080::health_flags::healthy"
case "$url" in
*/metrics)
	body="$STUB_PRE_BODY"
	if [[ -f "$STUB_MARK" ]]; then body="$STUB_POST"; fi ;;
*/clusters)
	if [[ -f "$STUB_MARK" && "$port" == 15100 ]]; then echo "$healthy"; exit 0; fi
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
	export STUB_PRE_BODY="${BATS_TEST_TMPDIR}/pre.txt" STUB_POST="${BATS_TEST_TMPDIR}/post.txt"
	{ cat "${FX}/pre_metrics.txt"; hist 0 0; } > "$STUB_PRE_BODY"
	# After the flip: P1 converges (10 samples for 5 proxies) and the EDS counter bumps.
	{ sed 's/^pilot_xds_pushes{type="eds"} .*/pilot_xds_pushes{type="eds"} 300/' "${FX}/pre_metrics.txt"; hist 10 0.5; } > "$STUB_POST"
}

# _prop_run: one iteration of the real 002, ctx-a the source, ctx-b the one remote; the
# drain check waits at most 1s for a canary endpoint to go.
_prop_run() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" PROPAGATION_DRAIN_TIMEOUT_SEC=1 run --separate-stderr \
		"${PR}/002-run-endpoint-probe.sh" --source-context ctx-a --remote-contexts ctx-b --timeout 3 \
		--poll-interval-ms 100 --settle-sec 0 --tsv --output-dir "$RES" --iterations 1
}

# _row <cols>: the given columns of the endpoint TSV's data rows, slash-joined.
_row() {
	awk -F'\t' -v c="$1" 'BEGIN { n = split(c, k, ",") } !/^#/ && $1 != "run_id" {
		s = ""; for (i = 1; i <= n; i++) s = s (i > 1 ? "/" : "") $(k[i]); print s }' "$RES"/endpoint-*.tsv
}

# _prop_tuning <tsv>: a one-pass tuning sweep over <tsv>, compared by tuning 004 (md).
_prop_tuning() {
	local P="${BATS_TEST_TMPDIR}/psweep"
	rm -rf "$P"
	mkdir -p "${P}/baseline"
	printf '# SUITE=propagation\n# PASSES=baseline\n' > "${P}/sweep-metadata.txt"
	cp "$1" "${P}/baseline/"
	run "$TUNING_CMP" --results-dir "$P" --format md
}

@test "propagation 002: a canary endpoint still healthy on the remote's watcher after the drain wait makes that remote NOT_DRAINED: its P2/P3 are left out (summary, 005, tuning 004), P1 counts" {
	_prop_stub
	STUB_PRE_PORT=15100 _prop_run
	assert_success
	# status (10) is the row's over both sides, p1_status (20) the source's, remote_status
	# (22) the remote's: P3 measured a number, but the iteration started with the old
	# endpoint healthy, so it is not a valid sample.
	[ "$(_row 10,20,22)" = NOT_DRAINED/OK/NOT_DRAINED ]
	# The warning names the iteration, the state (still healthy, not unreadable) and the knob.
	[[ "$stderr" == *"Warning: iteration 1/1: ctx-b: a canary endpoint from an earlier iteration or run is still healthy on its watcher after PROPAGATION_DRAIN_TIMEOUT_SEC=1s (raise it if its drains take longer): this iteration's P2/P3 for it are NOT_DRAINED"* ]]
	assert_output --regexp 'P1 local xDS push: +n=1/1 min=[0-9]+ms'
	assert_output --partial "P2 remote istiod EDS push:  n=0/1 (no valid sample)"
	assert_output --partial "P3 remote sidecar:          n=0/1 (no valid sample)"
	assert_output --regexp '    NOT_DRAINED +1'
	grep -qxF '| `NOT_DRAINED` | 1 |' "$RES"/endpoint-*.md
	_md_tables_even < "$(ls "$RES"/endpoint-*.md)"
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -c '[.rows[] | [.phase, .n_total, .n_valid, .n_attempted]]' <<<"$output")" = \
		'[["P1_local_wall",1,1,1],["P1_conv_p50",1,1,1],["P1_conv_p99",1,0,1],["P2_discovery",1,0,1],["P3_dataplane",1,0,1]]' ]
	_prop_tuning "$(ls "$RES"/endpoint-*.tsv)"
	assert_success
	[[ "$output" == *"| P2 remote EDS (ms) | - |"$'\n'"|   n (got/attempted) | 0/1 |"* ]]
	[[ "$output" == *"| P3 remote sidecar (ms) | - |"$'\n'"|   n (got/attempted) | 0/1 |"* ]]
	[[ "$output" == *"| P1 local push (ms) | "[0-9]*$'\n'"|   n (got/attempted) | 1/1 |"* ]]
}

@test "propagation 002: on the source's watcher the same makes P1 NOT_DRAINED (left out) while the remote's P2/P3 count; a /clusters that cannot be read counts as not drained" {
	_prop_stub
	STUB_PRE_PORT=15101 _prop_run
	assert_success
	[ "$(_row 10,20,22)" = NOT_DRAINED/NOT_DRAINED/OK ]
	[[ "$stderr" == *"Warning: iteration 1/1: ctx-a: a canary endpoint from an earlier iteration or run is still healthy on its watcher after PROPAGATION_DRAIN_TIMEOUT_SEC=1s"*"P1 is NOT_DRAINED"* ]]
	assert_output --partial "P1 local xDS push:          n=0/1 (no valid sample)"
	assert_output --regexp 'P2 remote istiod EDS push: +n=1/1 min=[0-9]+ms'
	assert_output --regexp 'P1 iterations left out .*'$'\n''    NOT_DRAINED +1'
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format json
	[ "$(jq -c '[.rows[] | [.phase, .n_total, .n_valid]]' <<<"$output")" = \
		'[["P1_local_wall",1,0],["P1_conv_p50",1,0],["P1_conv_p99",1,0],["P2_discovery",1,1],["P3_dataplane",1,1]]' ]
	# The remote's /clusters cannot be read before t0: the drain cannot be confirmed. The
	# warning says so (not "still healthy"), and the check does not wait for it: its three
	# tries are the only reads before t0 (a wait would read again until the drain timeout).
	rm -rf "$RES" "$STUB_PRE_COUNT" "$STUB_MARK"
	mkdir -p "$RES"
	STUB_PRE_PORT=15100 STUB_PRE_MODE=unreadable _prop_run
	assert_success
	[ "$(_row 10,20,22)" = NOT_DRAINED/OK/NOT_DRAINED ]
	[[ "$stderr" == *"Warning: iteration 1/1: ctx-b: its watcher's /clusters could not be read (the port-forward to deploy/propagation-watcher on localhost:15100), so its drain cannot be checked: this iteration's P2/P3 for it are NOT_DRAINED"* ]]
	[[ "$stderr" != *"still healthy"* ]]
	[ "$(cat "$STUB_PRE_COUNT")" = 3 ]
}

@test "propagation 002: a canary endpoint healthy again just before t0 (after a clean drain check) is NOT_DRAINED; one that drains within the wait settles and the iteration counts" {
	_prop_stub
	# Read 1 (the drain check) is clean, read 2 (just before t0) shows it healthy.
	STUB_PRE_PORT=15100 STUB_PRE_FROM=2 _prop_run
	assert_success
	[ "$(_row 10,20,22)" = NOT_DRAINED/OK/NOT_DRAINED ]
	[[ "$stderr" == *"Warning: iteration 1/1: ctx-b: the canary endpoint is already healthy on its watcher before t0"* ]]
	# Healthy on reads 1 and 2 (the drain check waits), gone on read 3: drained, settled,
	# clean at t0: every status OK, nothing left out.
	rm -rf "$RES" "$STUB_PRE_COUNT" "$STUB_MARK"
	mkdir -p "$RES"
	STUB_PRE_PORT=15100 STUB_PRE_UNTIL=2 _prop_run
	assert_success
	[ "$(_row 10,20,22)" = OK/OK/OK ]
	assert_output --partial "drained just now. Settling for 0s before the baseline"
	[[ "$stderr" != *"NOT_DRAINED"* ]]
	assert_output --partial "rows_dropped_total=0/1"
	# The dry run describes the check.
	run "${PR}/002-run-endpoint-probe.sh" --source-context ci-a --remote-contexts ci-b --dry-run
	assert_success
	assert_output --partial "--- drain check (reads only; before each baseline, and again just before t0) ---"
	run "${PR}/002-run-endpoint-probe.sh" --help
	assert_output --partial "NOT_DRAINED"
}

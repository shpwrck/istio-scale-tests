#!/usr/bin/env bats
# propagation 002 around t0 and the drain, through the real probe (PL33) with a stub
# kubectl and curl, no cluster: a run cut short after its t0 label flip removes the label
# on exit; after an iteration whose drain timed out, the next one settles before its
# baseline even when its drain check reads clean; between the baseline scrape and t0 only
# the t0 check runs. Event order, never elapsed seconds (PL44). Names are placeholders
# (ctx-a, ctx-b), addresses come from 192.0.2.0/24.

bats_require_minimum_version 1.5.0
load test_helper

FX="${ROOT}/tests/lib/test/fixtures/istiod-diag"
PR="${ROOT}/tests/propagation"

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
	EK="${BATS_TEST_TMPDIR}/empty.kubeconfig"
	: > "$EK"
	export TMPDIR="$BATS_TEST_TMPDIR"
}

# _stub: kubectl and curl that log every call, in order, to STUB_LOG ("kubectl <args>",
# "curl <url> > <out>"). The t0 label flip (label ...=true) creates STUB_MARK: istiod
# /metrics then serve STUB_POST (P1 converges, the EDS counter bumps) and the remote's
# watcher (port 15100) shows the canary endpoint healthy. The label removal clears
# STUB_MARK, or with STUB_DRAIN_LATE=1 only at the next iteration's port-forward liveness
# read (curl -o /dev/null of /metrics, after the drain wait), so the drain times out and
# the next drain check reads clean; with STUB_UNLABEL_FAIL=1 it fails. With
# STUB_TERM_AT_FLIP=1 the flip sends SIGTERM to the probe (its parent).
_stub() {
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export STUB_LOG="${BATS_TEST_TMPDIR}/calls.log" STUB_MARK="${BATS_TEST_TMPDIR}/post.mark"
	export STUB_LATE="${BATS_TEST_TMPDIR}/late.mark" FX
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
out="" url=""
while (($#)); do
	case "$1" in
	-o) out="$2"; shift 2 ;;
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
	if [[ -f "$STUB_MARK" ]]; then body="$STUB_POST"; fi ;;
*/clusters)
	if [[ -f "$STUB_MARK" && "$port" == 15100 ]]; then echo "$healthy"; exit 0; fi
	body="$FX/../fortio_ok.json" ;;
*) exit 7 ;;
esac
if [[ -n "$out" ]]; then cp "$body" "$out"; else cat "$body"; fi
STUB
	chmod +x "${BIN}/kubectl" "${BIN}/curl"
	# hist <count> <sum>: the P1 convergence histogram, all samples under 100 ms.
	hist() { printf 'pilot_proxy_convergence_time_bucket{le="0.1"} %s\npilot_proxy_convergence_time_bucket{le="+Inf"} %s\npilot_proxy_convergence_time_sum %s\npilot_proxy_convergence_time_count %s\n' "$1" "$1" "$2" "$1"; }
	export STUB_PRE_BODY="${BATS_TEST_TMPDIR}/pre.txt" STUB_POST="${BATS_TEST_TMPDIR}/post.txt"
	{ cat "${FX}/pre_metrics.txt"; hist 0 0; } > "$STUB_PRE_BODY"
	{ sed 's/^pilot_xds_pushes{type="eds"} .*/pilot_xds_pushes{type="eds"} 300/' "${FX}/pre_metrics.txt"; hist 10 0.5; } > "$STUB_POST"
}

# _run <iterations>: the real 002, ctx-a the source, ctx-b the one remote; a drain waits
# at most 1s.
_run() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" PROPAGATION_DRAIN_TIMEOUT_SEC=1 run --separate-stderr \
		"${PR}/002-run-endpoint-probe.sh" --source-context ctx-a --remote-contexts ctx-b --timeout 3 \
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

@test "propagation 002: a run ended by SIGTERM right after its t0 label flip removes the label on exit; a removal that fails says how to remove it by hand" {
	_stub
	STUB_TERM_AT_FLIP=1 _run 1
	[ "$status" -eq 143 ]
	local flip unlabel
	flip="$(_line ' label pod/canary-backer-0 propagation-active=true ')"
	unlabel="$(_line ' label pod/canary-backer-0 propagation-active- ')"
	((flip > 0 && unlabel > flip))
	[[ "$stderr" == *"The run ended before its drain: removed the propagation-active label from pod canary-backer-0 on ctx-a."* ]]
	# The removal fails: the warning gives the command, and the run still ends.
	rm -f "$STUB_MARK"
	STUB_TERM_AT_FLIP=1 STUB_UNLABEL_FAIL=1 _run 1
	[ "$status" -eq 143 ]
	[[ "$stderr" == *"warning: could not remove the propagation-active label from pod canary-backer-0 on ctx-a: the canary endpoint stays up, and the next run's first iteration reads NOT_DRAINED. Remove it: kubectl --context=ctx-a -n propagation-test label pod/canary-backer-0 propagation-active-"* ]]
}

@test "propagation 002: a run that drains its last label itself removes nothing on exit" {
	_stub
	_run 1
	assert_success
	# One removal: the iteration's own; cleanup has none left to remove.
	[ "$(grep -c ' label pod/canary-backer-0 propagation-active- ' "$STUB_LOG")" -eq 1 ]
	[[ "$stderr" != *"The run ended before its drain"* ]]
}

@test "propagation 002: after an iteration whose drain timed out, the next drain check that reads clean still settles before the baseline" {
	_stub
	STUB_DRAIN_LATE=1 _run 2
	assert_success
	# Iteration 1's remote side timed out its drain; iteration 2 counts.
	[ "$(_row 3,22 | tr '\n' ' ')" = "1/DRAIN_TIMEOUT 2/OK " ]
	[[ "$stderr" != *"NOT_DRAINED"* ]]
	local it2 settle base2
	it2="$(grep -n -- '--- Iteration 2/2 ---' <<<"$output" | cut -d: -f1)"
	settle="$(grep -n "The previous iteration's drain timed out: its removal may still be pushing. Settling for 0s before the baseline" <<<"$output" | cut -d: -f1)"
	base2="$(grep -n 'Scraping baselines' <<<"$output" | sed -n 2p | cut -d: -f1)"
	[ -n "$it2" ] && [ -n "$settle" ] && [ -n "$base2" ]
	((it2 < settle && settle < base2))
	# Without a timed-out drain before it, a clean check does not settle.
	[ "$(grep -c "The previous iteration's drain timed out" <<<"$output")" -eq 1 ]
}

@test "propagation 002: the backer resolve and its Ready wait run before the baseline scrape; between that scrape and the t0 flip only the t0 check reads /clusters" {
	_stub
	_run 1
	assert_success
	local resolve ready base_first base_last flip
	resolve="$(_line '^kubectl .* get pods -l app=propagation-canary ')"
	ready="$(_line '^kubectl .* wait pod/canary-backer-0 ')"
	base_first="$(_line '/baseline-1/' first)"
	base_last="$(_line '/baseline-1/' last)"
	flip="$(_line ' label pod/canary-backer-0 propagation-active=true ')"
	((resolve > 0 && ready > resolve && base_first > ready && flip > base_last))
	# Every call between the last baseline scrape and the flip is a watcher /clusters read.
	[ "$(sed -n "$((base_last + 1)),$((flip - 1))p" "$STUB_LOG" | grep -vc '^curl http://localhost:151[0-9][0-9]/clusters > -$')" -eq 0 ]
	[ "$(sed -n "$((base_last + 1)),$((flip - 1))p" "$STUB_LOG" | grep -c '/clusters')" -eq 2 ]
}

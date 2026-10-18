#!/usr/bin/env bats
# propagation 002 around t0 and the drain, through the real probe and reports (PL33) with a
# stub kubectl and curl, no cluster: the exit-time label removal is bounded inside
# SWEEP_STOP_GRACE_SEC; an iteration whose drain timed out (DRAIN_TIMEOUT) counts in 002's
# summary, every 005 format and tuning 004, each saying how many drained late; 002's
# preamble and 006's placeholder record HARNESS_CONTENT_KEY next to HARNESS_SHA, the two
# from one read of the harness (an edit while the probe starts never splits them).
# Event order and counts, never elapsed seconds (PL44). Names are placeholders (ctx-a,
# ctx-b, ci-a), addresses come from 192.0.2.0/24.

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

@test "propagation 002: the exit-time label removal bounds each request at 5s, inside SWEEP_STOP_GRACE_SEC; the iteration's own removal keeps 10s" {
	_stub
	STUB_TERM_AT_FLIP=1 _run 1
	[ "$status" -eq 143 ]
	local rto grace
	rto="$(sed -n 's/^kubectl .* --request-timeout=\([0-9]*\)s label pod\/canary-backer-0 propagation-active- .*/\1/p' "$STUB_LOG")"
	[ "$rto" = 5 ]
	# The label call makes two requests (read, then patch): both fit in the default grace
	# a stopping sweep gives the probe before SIGKILL.
	grace="$(env -u SWEEP_STOP_GRACE_SEC bash -c 'source "$1/config/options.env" && echo "$SWEEP_STOP_GRACE_SEC"' _ "$ROOT")"
	((2 * rto <= grace))
	[[ "$stderr" == *"The run ended before its drain: removed the propagation-active label"* ]]
	# A run that drains itself removes the label in the iteration, at 10s per request.
	rm -f "$STUB_MARK"
	: > "$STUB_LOG"
	_run 1
	assert_success
	[ "$(grep -c -- '--request-timeout=10s label pod/canary-backer-0 propagation-active- ' "$STUB_LOG")" -eq 1 ]
	[ "$(grep -c -- '--request-timeout=5s label ' "$STUB_LOG")" -eq 0 ]
}

@test "propagation 002, 005 and tuning 004: an iteration whose drain timed out counts (a flag, not a drop), and each says how many drained late" {
	_stub
	STUB_DRAIN_LATE=1 _run 2
	assert_success
	[ "$(_row 3,10,20,22 | tr '\n' ' ')" = "1/DRAIN_TIMEOUT/OK/DRAIN_TIMEOUT 2/OK/OK/OK " ]
	# 002's summary: both iterations count; one note gives the late drains.
	assert_output --partial "P2 remote istiod EDS push:  n=2/2 "
	assert_output --partial "P3 remote sidecar:          n=2/2 "
	assert_output --partial "rows_dropped_total=0/2"
	local note="The drain after 1 of 2 iteration(s) timed out (DRAIN_TIMEOUT"
	assert_output --partial "$note"
	grep -qF "$note" "$RES"/endpoint-*.md
	grep -qF '| P2 remote istiod EDS push | 2/2 |' "$RES"/endpoint-*.md
	# 005, every format: the rows count, and a warning per mesh size gives the number.
	local warn="mesh size 2: the drain after 1 iteration(s) timed out (DRAIN_TIMEOUT"
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format csv
	assert_success
	assert_line --regexp '^2,P2_discovery,2,2,'
	assert_line --regexp '^2,P3_dataplane,2,2,'
	assert_line --partial "# WARNING: ${warn}"
	[[ "$stderr" == *"WARNING: ${warn}"* ]]
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format text
	assert_success
	assert_output --partial "WARNING: ${warn}"
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format md
	assert_success
	assert_output --partial "> **Warning:** ${warn}"
	assert_output --partial '`DRAIN_TIMEOUT` in any status column'
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$RES" --format json
	assert_success
	[[ "$(jq -r '.data_warnings[0]' <<<"$output")" == "${warn}"* ]]
	[ "$(jq -c '[.rows[] | select(.phase == "P2_discovery" or .phase == "P3_dataplane") | .n_valid]' <<<"$output")" = '[2,2]' ]
	# tuning 004 counts them too, and adds a row with the number.
	local P="${BATS_TEST_TMPDIR}/psweep"
	mkdir -p "${P}/baseline"
	cp "$RES"/endpoint-*.tsv "${P}/baseline/"
	printf '# SUITE=propagation\n# PASSES=baseline\n' > "${P}/sweep-metadata.txt"
	run --separate-stderr "${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "$P" --format md
	assert_success
	assert_line "| Drain timeouts (iterations, counted) | 1 |"
	[ "$(grep -A1 '^| P2 remote EDS (ms) |' <<<"$output" | tail -1)" = "|   n (got/attempted) | 2/2 |" ]
}

@test "propagation 005: a TSV written before remote_status (19 columns) counts a DRAIN_TIMEOUT row too, with the warning" {
	local d="${BATS_TEST_TMPDIR}/legacy"
	mkdir -p "$d"
	{
		echo "# RUN_ID=r1"
		printf 'run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms\n'
		printf 'r1\t2\t1\tci-a\tci-b\t0\t1000\t500\t3000\tDRAIN_TIMEOUT\t100\t100\t40/40\t40\t0\t0\t0\t5000\t10\n'
		printf 'r1\t2\t2\tci-a\tci-b\t0\t1000\t500\t3000\tOK\t100\t100\t40/40\t40\t0\t0\t0\t5000\t10\n'
		printf 'r1\t2\t3\tci-a\tci-b\t0\t1000\t500\t3000\tNOT_DRAINED\t100\t100\t40/40\t40\t0\t0\t0\t5000\t10\n'
	} > "${d}/endpoint-r1.tsv"
	run --separate-stderr "${PR}/005-report-results.sh" --results-dir "$d" --format csv
	assert_success
	# NOT_DRAINED still drops its row; DRAIN_TIMEOUT counts like OK.
	assert_line --regexp '^2,P2_discovery,3,2,'
	assert_line --partial "# WARNING: mesh size 2: the drain after 1 iteration(s) timed out (DRAIN_TIMEOUT"
}

@test "propagation 002's preamble and 006's placeholder record HARNESS_CONTENT_KEY right after HARNESS_SHA" {
	_stub
	_run 1
	assert_success
	local f key='^# HARNESS_CONTENT_KEY=([0-9a-f]{12}|unknown)$'
	f="$(ls "$RES"/endpoint-*.tsv)"
	grep -A1 '^# HARNESS_SHA=' "$f" | tail -1 | grep -Eq "$key"
	# 006: a mesh size whose setup fails leaves a placeholder with the sweep start's key.
	rm -rf "$RES"
	mkdir -p "$RES"
	PROPAGATION_RESULTS_DIR="$RES" PROPAGATION_SETTLE_SEC=0 ISTIO_VERSION_CHECK=warn ISTIO_VERSION_READY_WAIT_SEC=0 \
		KUBECONFIG="$EK" run --separate-stderr bash "${PR}/006-run-sweep.sh" --contexts ci-a --mesh-sizes 1
	assert_failure 4
	f="$(ls "$RES"/sweep-*/endpoint-*.tsv)"
	grep -A1 '^# HARNESS_SHA=' "$f" | tail -1 | grep -Eq "$key"
}

@test "propagation 002 reads HARNESS_SHA and HARNESS_CONTENT_KEY once: an edit while it starts leaves its preamble one tree's pair (the -dirty.<8hex> is the key's start)" {
	_stub
	# A copy of the harness in a git checkout of its own, dirty at the start (an untracked
	# tests/ file), so the probe's HARNESS_SHA carries -dirty.<8hex>.
	local r="${BATS_TEST_TMPDIR}/repo" f sha key want_key
	mkdir -p "$r/tests/lib/test"
	cp -R "${ROOT}/config" "$r/config"
	cp "${ROOT}"/tests/lib/*.sh "$r/tests/lib/"
	cp -R "${ROOT}/tests/lib/test/fixtures" "$r/tests/lib/test/fixtures"
	(cd "${ROOT}/tests" && tar -cf - --exclude=results --exclude='*.local.env' propagation) | (cd "$r/tests" && tar -xf -)
	cp "${ROOT}/.gitignore" "$r/.gitignore"
	git -C "$r" init -q
	git -C "$r" add -A
	git -C "$r" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -q -m init
	echo before > "$r/tests/zz-before.txt"
	want_key="$(ROOT="$r" harness_content_key)"
	[[ "$want_key" =~ ^[0-9a-f]{12}$ ]]
	# The probe's first Istio CR read (istio_version_resolve, after its harness read) adds
	# another untracked tests/ file: an operator's edit while the probe starts.
	mv "${BIN}/kubectl" "${BIN}/kubectl.real"
	cat > "${BIN}/kubectl" <<'W'
#!/usr/bin/env bash
case " $* " in *" get istios.sailoperator.io default "*) [[ -e "$ROOT/tests/zz-mid-edit.txt" ]] || echo edit > "$ROOT/tests/zz-mid-edit.txt" ;; esac
exec "${0}.real" "$@"
W
	chmod +x "${BIN}/kubectl"
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" PROPAGATION_DRAIN_TIMEOUT_SEC=1 run --separate-stderr \
		"$r/tests/propagation/002-run-endpoint-probe.sh" --source-context ctx-a --remote-contexts ctx-b --timeout 3 \
		--poll-interval-ms 100 --settle-sec 0 --tsv --output-dir "$RES" --iterations 1
	assert_success
	[ -e "$r/tests/zz-mid-edit.txt" ]
	[ "$(ROOT="$r" harness_content_key)" != "$want_key" ]
	f="$(ls "$RES"/endpoint-*.tsv)"
	sha="$(sed -n 's/^# HARNESS_SHA=//p' "$f")"
	key="$(sed -n 's/^# HARNESS_CONTENT_KEY=//p' "$f")"
	# The read before the edit: its key, and the -dirty suffix is that key's first 8 hex.
	[ "$key" = "$want_key" ] || { echo "key ${key}, want ${want_key}"; false; }
	[[ "$sha" == *-dirty."${key:0:8}" ]] || { echo "HARNESS_SHA ${sha}, HARNESS_CONTENT_KEY ${key}"; false; }
}

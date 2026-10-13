#!/usr/bin/env bats
# tests/lib/reach.sh (remote reachability check and coverage), and the dataplane and
# churn-dataplane entrypoints that use it: 002 skip/stop, 004/005 Remote coverage and
# --fail-on-unreachable, flags, dry-runs. Fixtures are hand-written RetCodes objects:
# raw fortio JSON carries the client hostname and IPs and must never be committed.

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr
source "${ROOT}/tests/lib/fortio.sh"
source "${ROOT}/tests/lib/reach.sh"

DP_PROBE="${ROOT}/tests/dataplane/002-run-latency-probe.sh"
DP_SWEEP="${ROOT}/tests/dataplane/003-run-sweep.sh"
DP_REPORT="${ROOT}/tests/dataplane/004-report-results.sh"
CD_PROBE="${ROOT}/tests/churn-dataplane/002-run-baseline-probe.sh"
CD_CHURN="${ROOT}/tests/churn-dataplane/003-run-churn-probe.sh"
CD_SWEEP="${ROOT}/tests/churn-dataplane/004-run-sweep.sh"
CD_REPORT="${ROOT}/tests/churn-dataplane/005-report-results.sh"
FX="${ROOT}/tests/lib/test/fixtures"
LAT_HDR=$'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class'
REACH_HDR=$'run_id\tcombo_id\tmesh_size\tsource_ctx\ttarget_ctx\ttarget_class\tattempts\trequests\tok\tpct_200\ttop_code\treach_status\tdetail'

# Fake kubectl for the lib: the URL (last arg) picks the answer.
#   ok-*: all 200; bad-*: all 503, and `fortio curl` gets an Envoy reply;
#   err-*: kubectl exec fails; flaky-*: 503 on the first load, 200 after.
_fake_kubectl() {
	local url="${*: -1}" n
	case " $* " in
	*" fortio curl "*)
		printf 'HTTP/1.1 503 Service Unavailable\r\ncontent-length: 19\r\ncontent-type: text/plain\r\n\r\nno healthy upstream\n'
		return 1
		;;
	esac
	case "$url" in
	*err-*) return 1 ;;
	*bad-*) echo '{"RetCodes":{"503":10}}' ;;
	*flaky-*)
		n="$(cat "${BATS_TEST_TMPDIR}/flaky.count" 2>/dev/null || echo 0)"
		echo $((n + 1)) > "${BATS_TEST_TMPDIR}/flaky.count"
		if ((n == 0)); then echo '{"RetCodes":{"503":10}}'; else echo '{"RetCodes":{"200":10}}'; fi
		;;
	*) echo '{"RetCodes":{"200":10}}' ;;
	esac
}

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
	export REACH_RETRY_SEC=0
	# Stub kubectl for the entrypoints; logs every call so dry-runs can prove they
	# never reach a cluster.
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log"
	: > "$STUB_LOG"
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case " $* " in
*" fortio curl "*) printf 'HTTP/1.1 503 Service Unavailable\r\n\r\nno healthy upstream\n'; exit 1 ;;
*" exec "*)
	url="${*: -1}"
	case "$url" in
	*"dataplane-server-${STUB_DEAD:-none}."*) echo '{"RetCodes":{"503":10}}' ;;
	*) cat "$STUB_JSON" ;;
	esac
	;;
*" get deploy dataplane-server "*) printf '1/1' ;;
*" get pod -l app=dataplane-client "*) printf 'dataplane-client-0' ;;
*" get pods "*) : ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
	export STUB_JSON="${FX}/fortio_ok.json"
}

# reach_tsv <file> <rows...>: a reach TSV with the lib's own header writer.
reach_tsv() {
	local f="$1" r
	shift
	reach_write_header "$f" RUN_ID=x
	for r in "$@"; do printf '%s\n' "$r" >> "$f"; done
}

# rrow <run> <combo> <mesh> <src> <tgt> <class> <ok> <status> [top] [detail]
rrow() {
	printf '%s\t%s\t%s\t%s\t%s\t%s\t1\t10\t%s\tN/A\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${9:--}" "$8" "${10:--}"
}

# --- reach_summarize / reach_classify ---

@test "reach_summarize: ok total pct_200 top_code from RetCodes" {
	run reach_summarize '{"RetCodes":{"200":10}}'
	assert_output "10 10 1.0000 -"
	run reach_summarize '{"RetCodes":{"503":10}}'
	assert_output "0 10 0.0000 503"
	run reach_summarize '{"RetCodes":{"200":15,"503":5}}'
	assert_output "15 20 0.7500 503"
	run reach_summarize '{"RetCodes":{"-1":5}}'
	assert_output "0 5 0.0000 -1"
}

@test "reach_summarize: no codes, garbage or empty input -> 0 0 N/A -" {
	for j in '{}' 'garbage' ''; do
		run reach_summarize "$j"
		assert_success
		assert_output "0 0 N/A -"
	done
}

@test "reach_classify: REACHABLE, UNREACHABLE, DEGRADED, UNKNOWN" {
	run reach_classify 10 10; assert_output REACHABLE
	run reach_classify 0 10; assert_output UNREACHABLE
	run reach_classify 7 10; assert_output DEGRADED
	run reach_classify 0 0; assert_output UNKNOWN
	run reach_classify "" ""; assert_output UNKNOWN
}

# --- reach_sanitize / reach_body_line ---

@test "reach_sanitize: one line, IPs and hosts masked, Envoy TLS reason kept, <= 256 chars" {
	tls='upstream connect error or disconnect/reset before headers. retried and the latest reset reason: remote connection failure, transport failure reason: TLS_error:|268435581:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED:TLS_error_end'
	run reach_sanitize "$tls"
	assert_output --partial "CERTIFICATE_VERIFY_FAILED"
	run reach_sanitize $'dial tcp 192.0.2.7:8080\tvia\ndataplane-server-b.dataplane-test.svc.cluster.local'
	assert_output "dial tcp <ip>:8080 via <host>"
	run reach_sanitize "$(printf 'x%.0s' {1..400})"
	[ "${#output}" -eq 256 ]
	run reach_sanitize ""
	# Not assert_output "-": bats-assert reads "-" as "expected output on stdin".
	[ "$output" = "-" ]
}

@test "reach_body_line: skips the fortio curl headers; falls back to the fortio log" {
	printf 'HTTP/1.1 503 Service Unavailable\r\ncontent-length: 19\r\n\r\nno healthy upstream\n' > "${BATS_TEST_TMPDIR}/o"
	: > "${BATS_TEST_TMPDIR}/e"
	run reach_body_line "${BATS_TEST_TMPDIR}/o" "${BATS_TEST_TMPDIR}/e"
	assert_output "no healthy upstream"
	: > "${BATS_TEST_TMPDIR}/o"
	printf '{"level":"err","msg":"Unable to connect","err":"connect: connection refused"}\ncommand terminated with exit code 1\n' > "${BATS_TEST_TMPDIR}/e"
	run reach_body_line "${BATS_TEST_TMPDIR}/o" "${BATS_TEST_TMPDIR}/e"
	assert_output "Unable to connect: connect: connection refused"
}

# --- reach_check_target / reach_check_all ---

@test "reach_check_all: source first, then remotes; statuses, attempts and detail" {
	f="${RES}/reach-x.tsv"
	reach_write_header "$f" RUN_ID=x SUITE=t
	run reach_check_all "$f" x c1 4 ns pod "http://s-{ctx}.ns:8080/echo" ok-src "ok-b,bad-c,err-d" _fake_kubectl
	assert_success
	run awk -F'\t' '!/^#/ && $1 == "x" { print $5, $6, $7, $8 "/" $9, $11, $12, $13 }' "$f"
	assert_line --index 0 "ok-src local 1 10/10 - REACHABLE -"
	assert_line --index 1 "ok-b remote 1 10/10 - REACHABLE -"
	assert_line --index 2 "bad-c remote 3 10/0 503 UNREACHABLE no healthy upstream"
	assert_line --index 3 "err-d remote 3 0/0 - UNKNOWN exec failed"
}

@test "reach_check_all: a target that recovers on retry is REACHABLE with attempts=2" {
	f="${RES}/reach-x.tsv"
	reach_write_header "$f" RUN_ID=x
	reach_check_all "$f" x c1 2 ns pod "http://s-{ctx}/echo" ok-src "flaky-b" _fake_kubectl
	run awk -F'\t' '$5 == "flaky-b" { print $7, $12 }' "$f"
	assert_output "2 REACHABLE"
}

@test "reach_check_all: one header for two calls on the same file (PL36); no header -> return 1" {
	f="${RES}/reach-x.tsv"
	reach_write_header "$f" RUN_ID=x
	reach_check_all "$f" x c1 2 ns pod "http://s-{ctx}/echo" ok-src ok-b _fake_kubectl
	reach_write_header "$f" RUN_ID=y
	reach_check_all "$f" x c2 2 ns pod "http://s-{ctx}/echo" ok-src ok-b _fake_kubectl
	[ "$(grep -c '^run_id' "$f")" -eq 1 ]
	[ "$(grep -c '^# REACH_SCHEMA=1$' "$f")" -eq 1 ]
	grep -qx '# RUN_ID=x' "$f"
	[ "$(grep -vc '^#\|^run_id' "$f")" -eq 4 ]
	run reach_check_all "${RES}/missing.tsv" x c1 2 ns pod "u{ctx}" ok-src ok-b _fake_kubectl
	assert_failure
}

@test "reach_result_for / reach_not_reachable: listed remotes without a row count as UNKNOWN" {
	f="${RES}/reach-x.tsv"
	reach_tsv "$f" "$(rrow x c1 3 s s local 10 REACHABLE)" "$(rrow x c1 3 s b remote 0 UNREACHABLE)" \
		"$(rrow x c1 3 s c remote 7 DEGRADED)" "$(rrow x c1 3 s d remote 0 UNKNOWN)"
	run reach_result_for "$f" x c1 b
	assert_output "UNREACHABLE N/A"
	run reach_result_for "$f" x c1 zz
	assert_output "UNKNOWN N/A"
	run reach_not_reachable "$f" x c1 "b,c,d,e"
	assert_output $'b\nd\ne'
}

@test "reach_should_stop: only fail with an UNREACHABLE or UNKNOWN remote stops" {
	f="${RES}/reach-x.tsv"
	reach_tsv "$f" "$(rrow x u 2 s s local 10 REACHABLE)" "$(rrow x u 2 s b remote 0 UNREACHABLE)" \
		"$(rrow x k 2 s s local 10 REACHABLE)" "$(rrow x k 2 s b remote 0 UNKNOWN)" \
		"$(rrow x d 2 s s local 10 REACHABLE)" "$(rrow x d 2 s b remote 7 DEGRADED)" \
		"$(rrow x l 2 s s local 0 UNREACHABLE)" "$(rrow x l 2 s b remote 10 REACHABLE)"
	run reach_should_stop warn "$f" x u; assert_failure
	run reach_should_stop fail "$f" x u; assert_success
	run reach_should_stop fail "$f" x k; assert_success
	run reach_should_stop fail "$f" x d; assert_failure
	# Only remotes count: an unreachable local target does not stop.
	run reach_should_stop fail "$f" x l; assert_failure
}

@test "reach_validate: rejects a bad policy and bad knobs" {
	run reach_validate warn; assert_success
	run reach_validate fail; assert_success
	run reach_validate maybe; assert_failure; assert_output --partial "--on-unreachable"
	REACH_REQUESTS=-1 run reach_validate warn; assert_failure; assert_output --partial "--reach-requests"
	REACH_ATTEMPTS=0 run reach_validate warn; assert_failure; assert_output --partial "REACH_ATTEMPTS"
}

# --- reach_coverage_rows / reach_coverage_render ---

_coverage_fixture() {
	reach_tsv "${RES}/reach-1.tsv" \
		"$(rrow r1 c1 3 s s local 0 UNREACHABLE)" \
		"$(rrow r1 c1 3 s ok remote 10 REACHABLE)" \
		"$(rrow r1 c1 3 s dead remote 0 UNREACHABLE 503 'no healthy upstream')" \
		"$(rrow r1 c1 3 s flap remote 10 REACHABLE)" \
		"$(rrow r1 c1 3 s deg remote 7 DEGRADED 503)" \
		"$(rrow r1 c1 2 s ok remote 10 REACHABLE)"
	reach_tsv "${RES}/reach-2.tsv" \
		"$(rrow r2 c2 3 s ok remote 10 REACHABLE)" \
		"$(rrow r2 c2 3 s dead remote 0 UNREACHABLE -1 'connection refused')" \
		"$(rrow r2 c2 3 s flap remote 0 UNREACHABLE 503)" \
		"$(rrow r2 c2 3 s deg remote 0 UNREACHABLE 503)"
}

@test "reach_coverage_rows: REACHABLE, UNREACHABLE, FLAPPING, DEGRADED; mesh sizes apart; local excluded" {
	_coverage_fixture
	run reach_coverage_rows "$RES"
	assert_success
	assert_line --index 0 $'2\ts\tok\t1\t1\tREACHABLE\t-\t-'
	assert_line --index 1 $'3\ts\tok\t2\t2\tREACHABLE\t-\t-'
	assert_line --index 2 $'3\ts\tdead\t2\t0\tUNREACHABLE\t-1\tconnection refused'
	assert_line --index 3 $'3\ts\tflap\t2\t1\tFLAPPING\t503\t-'
	assert_line --index 4 $'3\ts\tdeg\t2\t0\tDEGRADED\t503\t-'
	refute_output --partial $'\ts\ts\t'
}

@test "reach_coverage_render: text, md, csv, json, charts and no data" {
	_coverage_fixture
	reach_coverage_rows "$RES" > "${RES}/rows"
	run reach_coverage_render text "${RES}/rows"
	assert_line "REMOTE COVERAGE mesh_size=2 source=s: 1/1 remotes reachable"
	assert_line "REMOTE COVERAGE mesh_size=3 source=s: 1/4 remotes reachable"
	assert_output --partial 'WARNING: remotes NOT reachable at mesh_size=3 from s: dead (UNREACHABLE 0/2, -1, "connection refused")'
	run reach_coverage_render md "${RES}/rows"
	assert_output --partial "## Remote coverage"
	assert_output --partial "| 3 | s | 1/4 | dead,flap,deg |"
	assert_output --partial "| 3 | s | dead | 0/2 | UNREACHABLE | -1 | connection refused |"
	refute_output --partial "| 3 | s | ok |"
	run reach_coverage_render csv "${RES}/rows"
	assert_line "# REMOTE_COVERAGE mesh_size=3 source=s reachable=1/4 not_reachable=dead,flap,deg"
	[ "$(printf '%s\n' "$output" | grep -vc '^# REMOTE_COVERAGE')" -eq 0 ]
	run reach_coverage_render json "${RES}/rows"
	[ "$(jq -r '.remote_coverage.groups[1].not_reachable[0].target_ctx' <<<"$output")" = dead ]
	[ "$(jq -r '.remote_coverage.not_reachable' <<<"$output")" = 3 ]
	[ "$(jq -r '.remote_coverage.groups[0].remotes_reachable' <<<"$output")" = 1 ]
	run reach_coverage_render charts "${RES}/rows"
	assert_output --partial "Remotes NOT reachable at mesh_size=3 from s: dead,flap,deg"
	: > "${RES}/empty"
	for fmt in text md csv; do
		run reach_coverage_render "$fmt" "${RES}/empty"
		assert_output --partial "no reachability data"
	done
	run reach_coverage_render json "${RES}/empty"
	[ "$(jq -r '.remote_coverage.data' <<<"$output")" = false ]
}

@test "reach_coverage_render md: a '|' in the detail is escaped" {
	reach_tsv "${RES}/reach-1.tsv" "$(rrow r1 c1 2 s b remote 0 UNREACHABLE 503 'TLS_error:|268435581:CERTIFICATE_VERIFY_FAILED')"
	reach_coverage_rows "$RES" > "${RES}/rows"
	run reach_coverage_render md "${RES}/rows"
	assert_output --partial 'TLS_error:\|268435581:CERTIFICATE_VERIFY_FAILED |'
}

# --- dataplane 004 (report) ---

# lrow <mesh> <tgt> <qps> <status> <class>
lrow() {
	printf 'r1\t%s\ts\t%s\t%s\t%s\t8\t30\t2.0\t2.5\t5.0\t11.0\t12.5\t%s\t1\t0\t%s\n' "$1" "$2" "$3" "$3" "$4" "$5"
}

_dp_fixture() {
	{
		echo "# RUN_ID=r1"
		echo "$LAT_HDR"
		lrow 3 s 10 OK local
		lrow 3 r1 10 OK remote
		lrow 3 r2 10 UNREACHABLE remote
		lrow 3 r2 100 UNREACHABLE remote
	} > "${RES}/latency-x.tsv"
	reach_tsv "${RES}/reach-x.tsv" "$(rrow r1 r1 3 s s local 10 REACHABLE)" \
		"$(rrow r1 r1 3 s r1 remote 10 REACHABLE)" "$(rrow r1 r1 3 s r2 remote 0 UNREACHABLE 503 'no healthy upstream')"
}

@test "004: Remote coverage names the unreachable remote in md, text and json" {
	_dp_fixture
	run "$DP_REPORT" --results-dir "$RES" --format md
	assert_success
	assert_output --partial "## Remote coverage"
	assert_output --partial "Remotes NOT reachable at mesh_size=3 from s: r2"
	assert_output --partial "- Remotes with no valid latency rows: mesh_size=3 from s: r2 (0/2; UNREACHABLE=2)"
	# The section comes before the results table.
	[ "$(printf '%s\n' "$output" | grep -n '## Remote coverage' | cut -d: -f1)" -lt "$(printf '%s\n' "$output" | grep -n '^| mesh_size | qps_target' | cut -d: -f1)" ]
	run "$DP_REPORT" --results-dir "$RES"
	assert_output --partial "REMOTE COVERAGE mesh_size=3 source=s: 1/2 remotes reachable"
	run "$DP_REPORT" --results-dir "$RES" --format json
	[ "$(jq -r '.summary.remotes_not_reachable' <<<"$output")" = 1 ]
	[ "$(jq -r '.summary.remotes_without_valid_rows' <<<"$output")" = 1 ]
	[ "$(jq -r '.remote_validity[] | select(.target_ctx == "r2") | .statuses.UNREACHABLE' <<<"$output")" = 2 ]
	run "$DP_REPORT" --results-dir "$RES" --format csv
	assert_output --partial "# REMOTE_COVERAGE mesh_size=3 source=s reachable=1/2 not_reachable=r2"
	assert_output --partial "# REMOTE_NO_VALID_ROWS mesh_size=3 from s: r2 (0/2; UNREACHABLE=2)"
	run "$DP_REPORT" --results-dir "$RES" --format charts
	assert_output --partial "Remotes NOT reachable at mesh_size=3 from s: r2"
}

@test "004 --fail-on-unreachable: exit 3 naming the rules; 0 when every remote is fine" {
	_dp_fixture
	run --separate-stderr "$DP_REPORT" --results-dir "$RES" --fail-on-unreachable
	[ "$status" -eq 3 ]
	assert_output --partial "REMOTE COVERAGE"
	[[ "$stderr" == *"rule=reach_coverage mesh_size=3 from s: r2 (UNREACHABLE"* ]]
	[[ "$stderr" == *"rule=no_valid_rows mesh_size=3 from s: r2 (n_valid=0/2; UNREACHABLE=2)"* ]]
	# All reachable, all valid.
	ok="${BATS_TEST_TMPDIR}/ok"
	mkdir -p "$ok"
	{
		echo "$LAT_HDR"
		lrow 2 s 10 OK local
		lrow 2 r1 10 OK remote
	} > "${ok}/latency-x.tsv"
	reach_tsv "${ok}/reach-x.tsv" "$(rrow r1 r1 2 s s local 10 REACHABLE)" "$(rrow r1 r1 2 s r1 remote 10 REACHABLE)"
	run "$DP_REPORT" --results-dir "$ok" --fail-on-unreachable
	assert_success
	assert_output --partial "REMOTE COVERAGE mesh_size=2 source=s: 1/1 remotes reachable"
}

@test "004: legacy TSV without a reach file -> no reachability data, remote listed by n_valid, exit 3" {
	{
		echo "$LAT_HDR"
		lrow 2 s 10 OK local
		for q in 10 100; do lrow 2 r2 "$q" ERROR_RATE_HIGH remote; done
	} > "${RES}/latency-old.tsv"
	run --separate-stderr "$DP_REPORT" --results-dir "$RES" --fail-on-unreachable
	[ "$status" -eq 3 ]
	assert_output --partial "REMOTE COVERAGE: no reachability data"
	assert_output --partial "Remotes with no valid latency rows: mesh_size=2 from s: r2 (0/2; ERROR_RATE_HIGH=2)"
	[[ "$stderr" == *"rule=no_valid_rows"* ]]
	[[ "$stderr" != *"rule=reach_coverage"* ]]
}

# --- dataplane 002 / 003 (entrypoints, stub kubectl) ---

_dp_probe() {
	PATH="${BIN}:${PATH}" STUB_DEAD=ctx-b run --separate-stderr "$DP_PROBE" --source-context ctx-a \
		--remote-contexts ctx-b,ctx-c --qps-levels 10,100 --settle 0 --warmup-duration 0 --output-dir "$RES" "$@"
}

@test "002 warn: an unreachable remote skips its load and gets UNREACHABLE rows" {
	_dp_probe
	assert_success
	[[ "$stderr" == *"UNREACHABLE ctx-b 0/10"* ]]
	[[ "$stderr" == *"WARNING: 1 of 2 remotes NOT reachable from ctx-a: ctx-b"* ]]
	f="$(ls "$RES"/latency-*.tsv)"
	[ "$(awk -F'\t' '$4 == "ctx-b" { print $14 }' "$f" | sort -u)" = UNREACHABLE ]
	[ "$(awk -F'\t' '$4 == "ctx-b"' "$f" | wc -l)" -eq 2 ]
	[ "$(awk -F'\t' '$4 == "ctx-c" { print $14 }' "$f" | sort -u)" = OK ]
	grep -qx '# ON_UNREACHABLE=warn' "$f"
	grep -qx '# REACH_REQUESTS=10' "$f"
	grep -qx '# REACH_ATTEMPTS=3' "$f"
	# The knobs that decide UNREACHABLE are in the latency preamble too (PL2), and
	# the report copies them.
	grep -qx '# REACH_QPS=10' "$f"
	grep -qx '# REACH_HTTP_TIMEOUT_SEC=3' "$f"
	grep -qx '# REACH_RETRY_SEC=0' "$f"
	run "$DP_REPORT" --results-dir "$RES" --format json
	[ "$(jq -r '.metadata | "\(.REACH_QPS) \(.REACH_HTTP_TIMEOUT_SEC) \(.REACH_RETRY_SEC)"' <<<"$output")" = "10 3 0" ]
	# No load was sent to ctx-b: only the reach check and its curl.
	run grep -q 'fortio load -qps 10 -c 8 .*dataplane-server-ctx-b' "$STUB_LOG"
	assert_failure
	run grep -q 'fortio load -qps 10 -c 8 .*dataplane-server-ctx-c' "$STUB_LOG"
	assert_success
	ls "$RES"/reach-*.tsv
	grep -q '## Remote coverage' "$RES"/latency-*.md
}

@test "002 fail: stops before any load, exit 3, STOPPED_UNREACHABLE placeholder" {
	_dp_probe --on-unreachable fail
	[ "$status" -eq 3 ]
	[[ "$stderr" == *"STOPPED: --on-unreachable fail"* ]]
	f="$(ls "$RES"/latency-*.tsv)"
	[ "$(awk -F'\t' '$17 == "na" { print $14 }' "$f")" = STOPPED_UNREACHABLE ]
	[ "$(awk -F'\t' '$17 == "local"' "$f" | wc -l)" -eq 0 ]
	run grep -q 'fortio load -qps 10 -c 8' "$STUB_LOG"
	assert_failure
	run "$DP_REPORT" --results-dir "$RES"
	assert_output --partial "Local baseline: MISSING mesh_size=3 reason=stopped_unreachable (no local rows)"
}

@test "002 --reach-requests 0: no check, no reach file, nothing skipped" {
	_dp_probe --reach-requests 0
	assert_success
	[ -z "$(ls "$RES"/reach-*.tsv 2>/dev/null)" ]
	# The stub's 503 answer has no histogram: the load ran and fortio.sh classified it.
	[ "$(awk -F'\t' '$4 == "ctx-b" { print $14 }' "$(ls "$RES"/latency-*.tsv)" | sort -u)" = PERCENTILE_MISSING ]
}

@test "002 --dry-run prints the reach plan and never calls kubectl; bad policy is rejected" {
	PATH="${BIN}:${PATH}" run "$DP_PROBE" --dry-run --source-context ci-dummy --remote-contexts ci-two --on-unreachable fail
	assert_success
	assert_output --partial "Reach check: 10 requests at 10 QPS per target"
	assert_output --partial "on unreachable: fail"
	[ ! -s "$STUB_LOG" ]
	PATH="${BIN}:${PATH}" run "$DP_PROBE" --dry-run --source-context ci-dummy --on-unreachable maybe
	assert_failure
	assert_output --partial "--on-unreachable"
}

@test "003 --dry-run passes --on-unreachable and --reach-requests to 002" {
	KUBECONFIG=/dev/null PATH="${BIN}:${PATH}" run "$DP_SWEEP" --dry-run --contexts a,b --mesh-sizes 2 --on-unreachable fail
	assert_success
	assert_output --partial "--on-unreachable fail --reach-requests 10"
	[ ! -s "$STUB_LOG" ]
}

# --- churn-dataplane 005 (report) and entrypoints ---

# crow <combo> <phase> <cr> <p99> <status>
crow() {
	printf 'r1\tsha\t%s\t2\t%s\t%s\t60\t200\t200\t2\t3\t%s\t6\t7\tN/A\t0\t%s\tN/A\tN/A\t1\t1\t1\tN/A\tN/A\tN/A\n' "$1" "$3" "$2" "$4" "$5"
}

@test "005: ERROR_RATE_HIGH baseline is not valid; coverage names the remote; --fail-on-unreachable exits 3" {
	{
		echo "# RUN_ID=r1"
		echo "# MIN_PCT_200=0.99"
		echo "# REACH_QPS=20"
		echo "# REACH_HTTP_TIMEOUT_SEC=1"
		echo "# REACH_RETRY_SEC=5"
		printf 'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms\n'
		crow ms2-cr1 baseline 0 5 ERROR_RATE_HIGH
		crow ms2-cr1 churn 1 9 OK
		crow ms2-cr5 baseline 0 5 OK
		crow ms2-cr5 churn 5 9 OK
	} > "${RES}/churn-dataplane-r1.tsv"
	reach_tsv "${RES}/reach-r1.tsv" "$(rrow r1 ms2-cr1 2 a a local 10 REACHABLE)" "$(rrow r1 ms2-cr1 2 a b remote 0 UNREACHABLE 503 'no healthy upstream')"
	run "$CD_REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -r '.rows[] | select(.churn_rate == 1) | "\(.valid_runs)/\(.total_runs)"' <<<"$output")" = 0/1 ]
	[ "$(jq -r '.rows[] | select(.churn_rate == 5) | .valid_runs' <<<"$output")" = 1 ]
	[ "$(jq -r '.summary.remotes_not_reachable' <<<"$output")" = 1 ]
	[ "$(jq -r '.metadata.min_pct_200' <<<"$output")" = 0.99 ]
	[ "$(jq -r '.metadata | "\(.reach_qps) \(.reach_http_timeout_sec) \(.reach_retry_sec)"' <<<"$output")" = "20 1 5" ]
	run "$CD_REPORT" --results-dir "$RES" --format md
	assert_output --partial "## Remote coverage"
	assert_output --partial "| 2 | a | 0/1 |"
	assert_output --partial "| MIN_PCT_200 | 0.99 |"
	assert_output --partial "| REACH_HTTP_TIMEOUT_SEC | 1 |"
	run "$CD_REPORT" --results-dir "$RES" --format csv
	assert_output --partial "# REACH_QPS=20"
	assert_output --partial "# REACH_RETRY_SEC=5"
	run "$CD_REPORT" --results-dir "$RES"
	assert_output --partial "REMOTE COVERAGE mesh_size=2 source=a: 0/1 remotes reachable"
	run --separate-stderr "$CD_REPORT" --results-dir "$RES" --fail-on-unreachable
	[ "$status" -eq 3 ]
	[[ "$stderr" == *"rule=reach_coverage mesh_size=2 from a: b (UNREACHABLE"* ]]
}

@test "churn-dataplane 002/004 --dry-run show the reach plan and thread the flags" {
	PATH="${BIN}:${PATH}" run "$CD_PROBE" --dry-run --source-context ci-dummy --remote-contexts ci-two --on-unreachable fail
	assert_success
	assert_output --partial "Reach check: 10 requests"
	assert_output --partial "fortio-server-{ctx}"
	assert_output --partial "Min pct_200: 0.99"
	KUBECONFIG=/dev/null PATH="${BIN}:${PATH}" run "$CD_SWEEP" --dry-run --contexts a,b --mesh-sizes 2 --churn-rates 1 --on-unreachable fail --reach-requests 5
	assert_success
	assert_output --partial "--on-unreachable fail --reach-requests 5"
	[ ! -s "$STUB_LOG" ]
	COEXEC_MIN_PCT_200=2 PATH="${BIN}:${PATH}" run "$CD_PROBE" --dry-run --source-context ci-dummy
	assert_failure
	assert_output --partial "COEXEC_MIN_PCT_200"
}

@test "--help lists the reach flags and environment variables" {
	for s in "$DP_PROBE" "$DP_SWEEP" "$CD_PROBE" "$CD_SWEEP"; do
		run "$s" --help
		assert_success
		assert_output --partial "--on-unreachable"
		assert_output --partial "--reach-requests"
		assert_output --partial "REACH_"
	done
	for s in "$DP_REPORT" "$CD_REPORT"; do
		run "$s" --help
		assert_success
		assert_output --partial "--fail-on-unreachable"
	done
	run "$CD_PROBE" --help
	assert_output --partial "COEXEC_MIN_PCT_200"
	run "$CD_CHURN" --help
	assert_output --partial "COEXEC_MIN_PCT_200"
}

@test "PL36: dataplane 002 and the 003 placeholder both write the reach preamble keys" {
	for k in REACH_REQUESTS REACH_QPS REACH_HTTP_TIMEOUT_SEC REACH_ATTEMPTS REACH_RETRY_SEC \
		ON_UNREACHABLE; do
		grep -q "echo \"# ${k}=" "$DP_PROBE"
		grep -q "echo \"# ${k}=" "$DP_SWEEP"
	done
}

@test "tuning 004-compare-profiles ignores reach-*.tsv in a pass directory (PL41)" {
	d="${BATS_TEST_TMPDIR}/tune/baseline"
	mkdir -p "$d"
	{
		echo "$LAT_HDR"
		lrow 2 s 10 OK local
		lrow 2 r1 10 OK remote
	} > "${d}/latency-x.tsv"
	run "${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "${BATS_TEST_TMPDIR}/tune"
	assert_success
	before="$output"
	reach_tsv "${d}/reach-x.tsv" "$(rrow x x 2 s s local 10 REACHABLE)" "$(rrow x x 2 s r1 remote 10 REACHABLE)"
	run "${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "${BATS_TEST_TMPDIR}/tune"
	assert_success
	[ "$output" = "$before" ]
}

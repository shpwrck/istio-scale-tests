#!/usr/bin/env bats
# Churn suite reporting through its real entrypoints: 004 reads HARNESS_SHA and
# ISTIO_VERSION from the TSVs (never the report host's checkout), shows the worst
# histogram p99 bucket with an overflow count, and orders n_total before n_valid;
# 002 writes those preamble keys and a UTC date (against a stub kubectl/curl).

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr
source "${ROOT}/config/versions.env"  # ISTIO_VERSION, as 002 reads it

REPORT="${ROOT}/tests/churn/004-report-results.sh"
PROBE="${ROOT}/tests/churn/002-run-churn-probe.sh"
SWEEP="${ROOT}/tests/churn/003-run-sweep.sh"
FX="${ROOT}/tests/lib/test/fixtures"
HDR=$'run_id\tmesh_size\tchurn_intensity\tbase_replicas\tscale_to\titeration\tt0_epoch_ns\tconvergence_local_ms\tremote_endpoint_reachable_ms\tconvergence_remote_eds_ms\tsource_push_triggers_delta\tremote_push_triggers_delta\tsource_xds_pushes_delta\tremote_xds_pushes_delta\tsource_queue_time_p99_ms\tremote_queue_time_p99_ms\tsource_connected_proxies\tremote_connected_proxies\tsource_push_time_p99_ms\tremote_push_time_p99_ms\tstatus'

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
}

# crow <iter> <src_queue_p99> <rmt_queue_p99> <src_push_p99> <rmt_push_p99> <status>
# One mesh=2 churn=5 scale 1->5 row; the latencies and counters are fixed.
crow() {
	printf 'r1\t2\t5\t1\t5\t%s\t0\t1000\t2000\t300\t10\t20\t100\t200\t%s\t%s\t50\t60\t%s\t%s\t%s\n' "$@"
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

# --- 004: run provenance -------------------------------------------------------

@test "004: harness_sha and istio_version come from the TSV preamble, in every format" {
	tsv "${RES}/churn-a.tsv" "HARNESS_SHA=feed123-test" "ISTIO_VERSION=1.99.0" <<-EOF
	$(crow 1 99 N/A 10 N/A OK)
	EOF
	run --separate-stderr "$REPORT" --results-dir "$RES" --format md
	assert_success
	assert_output --partial 'harness_sha: "feed123-test"'
	assert_output --partial 'istio_version: "1.99.0"'
	run --separate-stderr "$REPORT" --results-dir "$RES" --format charts
	assert_output --partial 'harness_sha: "feed123-test"'
	assert_output --partial 'istio_version: "1.99.0"'
	run --separate-stderr "$REPORT" --results-dir "$RES" --format csv
	assert_line "# HARNESS_SHA=feed123-test"
	assert_line "# ISTIO_VERSION=1.99.0"
	run --separate-stderr "$REPORT" --results-dir "$RES"
	assert_output --partial "# harness_sha (recorded by 002): feed123-test"
	assert_output --partial "# istio_version (recorded by 002): 1.99.0"
	[ -z "$stderr" ]
}

@test "004: a TSV without the keys reads 'unknown (not recorded)', never this checkout's HEAD" {
	tsv "${RES}/churn-old.tsv" "TUNING_BASELINE=unknown" <<-EOF
	$(crow 1 99 N/A 10 N/A OK)
	EOF
	head="$(git -C "$ROOT" rev-parse --short HEAD)"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format md
	assert_success
	assert_output --partial 'harness_sha: "unknown (not recorded)"'
	assert_output --partial 'istio_version: "unknown (not recorded)"'
	refute_output --partial "$head"
	refute_output --partial "istio_version: \"${ISTIO_VERSION}\""
	# Beside a TSV that recorded them: mixed, with a warning naming the key.
	tsv "${RES}/churn-new.tsv" "HARNESS_SHA=feed123-test" "ISTIO_VERSION=1.99.0" <<-EOF
	$(crow 1 99 N/A 10 N/A OK)
	EOF
	run --separate-stderr "$REPORT" --results-dir "$RES" --format md
	assert_success
	assert_output --partial 'harness_sha: "mixed:feed123-test,unknown (not recorded)"'
	[[ "$stderr" == *"input TSVs disagree on HARNESS_SHA (feed123-test,unknown (not recorded))"* ]]
	[[ "$stderr" == *"input TSVs disagree on ISTIO_VERSION"* ]]
}

# --- 004: histogram p99 columns ------------------------------------------------

@test "004: histogram p99 is the worst bucket a row hit, never the bucket of the mean" {
	# 99 and 600 average to ~350 ("100-500"), a bucket neither row hit.
	tsv "${RES}/churn-a.tsv" "HARNESS_SHA=x" "ISTIO_VERSION=y" <<-EOF
	$(crow 1 99 N/A 10 N/A OK)
	$(crow 2 600 N/A 900 N/A OK)
	EOF
	run "$REPORT" --results-dir "$RES" --format md
	assert_success
	assert_output --partial "| src_queue_p99 worst (ms) | rmt_queue_p99 worst (ms) |"
	# mesh | churn | scale | n_total | n_valid | local | reach | eds | 4 counters | queue p99s | proxies | push p99s | amp
	assert_output --partial "| 2 | 5 | 1->5 | 2 | 2 | 1000 | 2000 | 300 | 10 | 20 | 100 | 200 | 500-1000 | N/A | 50 | 60 | 500-1000 | N/A | 30.0 |"
	refute_output --partial "| 100-500 |"
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "Source queue time p99 (ms):    n=2 min=0-100 worst=500-1000"
	assert_output --partial "Remote queue time p99 (ms):    N/A"
	refute_output --partial "avg=100-500"
	run "$REPORT" --results-dir "$RES" --format csv
	assert_line "mesh_size,churn_intensity,base_replicas,scale_to,metric,n,min,max,avg,worst_bucket,n_overflow"
	assert_line "2,5,1,5,source_queue_time_p99_ms,2,99,600,350,500-1000,0"
	assert_line "2,5,1,5,convergence_local_ms,2,1000,1000,1000,,"
}

@test "004: an overflow p99 prints 'overflow (N rows)' instead of vanishing" {
	tsv "${RES}/churn-a.tsv" "HARNESS_SHA=x" "ISTIO_VERSION=y" <<-EOF
	$(crow 1 99 overflow 10 N/A OK)
	$(crow 2 overflow overflow 20 N/A OK)
	$(crow 3 overflow N/A 30 N/A POISONED_RESTART)
	EOF
	run "$REPORT" --results-dir "$RES" --format md
	assert_success
	assert_output --partial "| 3 | 2 | 1000 | 2000 | 300 | 10 | 20 | 100 | 200 | overflow (1 row) | overflow (2 rows) | 50 | 60 | 0-100 | N/A |"
	assert_output --partial '`overflow (N rows)` means N valid rows had their p99'
	run "$REPORT" --results-dir "$RES"
	assert_output --partial "Source queue time p99 (ms):    n=2 min=0-100 worst=overflow (1 row)"
	assert_output --partial "Remote queue time p99 (ms):    n=2 min=overflow worst=overflow (2 rows)"
	run "$REPORT" --results-dir "$RES" --format csv
	assert_line "2,5,1,5,source_queue_time_p99_ms,1,99,99,99,overflow,1"
	# Every valid row overflowed: still a row, n=0 numeric samples.
	assert_line "2,5,1,5,remote_queue_time_p99_ms,0,,,,overflow,2"
}

@test "004: md puts n_total before n_valid (as controlplane and dataplane)" {
	tsv "${RES}/churn-a.tsv" "HARNESS_SHA=x" "ISTIO_VERSION=y" <<-EOF
	$(crow 1 99 N/A 10 N/A OK)
	$(crow 2 99 N/A 10 N/A TIMEOUT_REMOTE)
	$(crow 3 99 N/A 10 N/A POISONED_RESTART)
	EOF
	run "$REPORT" --results-dir "$RES" --format md
	assert_success
	assert_output --partial "| mesh | churn | scale | n_total | n_valid |"
	assert_output --partial "| 2 | 5 | 1->5 | 3 | 1 |"
}

# --- 002 / 003: the writers ----------------------------------------------------

# Stub kubectl and curl for the churn probe: one istiod pod whose /metrics never
# changes, a watcher that lists no churn target (so the latencies are N/A).
_stub_bin() {
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export FX
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
case " $* " in
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running "*) printf 'istiod-abc-x1\n' ;;
*" scale "*) : ;;
*" get pods "*) : ;;
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
case "$url" in
*/metrics) body="$FX/istiod-diag/pre_metrics.txt" ;;
*/clusters) body="$FX/fortio_ok.json" ;;
*/ready) echo LIVE; exit 0 ;;
*/debug/syncz) echo '[]'; exit 0 ;;
*) exit 7 ;;
esac
if [[ -n "$out" ]]; then cp "$body" "$out"; else cat "$body"; fi
STUB
	chmod +x "${BIN}/kubectl" "${BIN}/curl"
}

@test "002 records HARNESS_SHA and ISTIO_VERSION in the preamble and dates the run in UTC" {
	_stub_bin
	# A non-UTC zone: a local-time stamp would end in -05:00.
	TZ=EST5 CHURN_POLL_INTERVAL_MS=50 PATH="${BIN}:${PATH}" run --separate-stderr "$PROBE" \
		--source-context ctx-a --iterations 1 --timeout 2 --settle 0 --deployment-count 1 \
		--output-dir "$RES"
	assert_success
	f="$(ls "$RES"/churn-*.tsv)"
	grep -qx "# HARNESS_SHA=$(git -C "$ROOT" describe --always --dirty --abbrev=7)" "$f"
	grep -qx "# ISTIO_VERSION=${ISTIO_VERSION}" "$f"
	head -1 "$f" | grep -Eq '(\+00:00|Z)$'
	grep -Eq '^\| Date \(UTC\) \| .*(\+00:00|Z) \|$' "$RES"/churn-*.md
	grep -q '^| Harness SHA | ' "$RES"/churn-*.md
	# 004 reports what the probe recorded.
	run "$REPORT" --results-dir "$RES" --format md
	assert_output --partial "istio_version: \"${ISTIO_VERSION}\""
}

@test "PL36: 002 and the 003 placeholder both write HARNESS_SHA and ISTIO_VERSION" {
	for k in HARNESS_SHA ISTIO_VERSION; do
		grep -q "^# ${k}=" "$PROBE"
		grep -q "echo \"# ${k}=" "$SWEEP"
	done
	# Every timestamp the probe writes is UTC.
	run grep -nE 'date -I' "$PROBE"
	refute_output --regexp 'date -I[a-z]'
}

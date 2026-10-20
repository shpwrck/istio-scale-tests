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

# tsv <file> <preamble lines...>; rows come on stdin. NO_PLATFORM=1: a legacy file, without
# the platform record every writer adds now.
tsv() {
	local f="$1" l
	shift
	{
		for l in "$@"; do echo "# $l"; done
		[[ -n "${NO_PLATFORM:-}" ]] || platform_fixture_lines
		echo "$HDR"
		cat
	} > "$f"
}

# --- 004: run provenance -------------------------------------------------------

@test "004: harness_sha, istio_version, the start-of-run readiness keys and the platform record come from the TSV preamble, in every format" {
	tsv "${RES}/churn-a.tsv" "HARNESS_SHA=feed123-test" "ISTIO_VERSION=1.99.0" \
		"ISTIO_NOTREADY_AT_START=ctx-b=IstiodNotReady" "ISTIO_READY_WAITED_SEC=60" "KUBE_VERSIONS=ctx-a=v1.34.1,ctx-b=v1.34.1" <<-EOF
	$(crow 1 99 N/A 10 N/A OK)
	EOF
	run --separate-stderr "$REPORT" --results-dir "$RES" --format md
	assert_success
	assert_output --partial 'harness_sha: "feed123-test"'
	assert_output --partial 'istio_version: "1.99.0"'
	assert_line 'platform: "kubernetes"'
	assert_line 'node_provider_by_context: "ctx-a=kind,ctx-b=kind"'
	assert_line 'kube_versions: "ctx-a=v1.34.1,ctx-b=v1.34.1"'
	assert_output --partial 'istio_notready_at_start: "ctx-b=IstiodNotReady"'
	run --separate-stderr "$REPORT" --results-dir "$RES" --format charts
	assert_output --partial 'harness_sha: "feed123-test"'
	assert_output --partial 'istio_version: "1.99.0"'
	assert_line 'mesh_operator_by_context: "ctx-a=sail-operator:1.31.1/Available,ctx-b=sail-operator:1.31.1/Available"'
	assert_output --partial 'istio_ready_waited_sec: "60"'
	run --separate-stderr "$REPORT" --results-dir "$RES" --format csv
	assert_line "# HARNESS_SHA=feed123-test"
	assert_line "# ISTIO_VERSION=1.99.0"
	assert_line "# ISTIOD_IMAGE_BY_CONTEXT=ctx-a=pilot:1.30.5,ctx-b=pilot:1.30.5"
	assert_line "# KUBE_VERSIONS=ctx-a=v1.34.1,ctx-b=v1.34.1"
	assert_line "# ISTIO_NOTREADY_AT_START=ctx-b=IstiodNotReady"
	run --separate-stderr "$REPORT" --results-dir "$RES"
	assert_output --partial "# harness_sha (recorded by 002): feed123-test"
	assert_output --partial "# istio_version (recorded by 002): 1.99.0"
	assert_line "# platform: kubernetes"
	assert_line "# proxy_image_by_context: ctx-a=proxyv2:1.30.5,ctx-b=proxyv2:1.30.5"
	assert_output --partial "# istio_notready_at_start: ctx-b=IstiodNotReady  istio_ready_waited_sec: 60"
	[ -z "$stderr" ]
}

@test "004 (S-B2): a record of 500 members goes through every format" {
	PLATFORM_FIXTURE_CTXS="$(wide_ctxs 500 ctx-a ctx-b)" tsv "${RES}/churn-a.tsv" <<-EOF
	$(crow 1 99 N/A 10 N/A OK)
	EOF
	wide_record_report "$REPORT" "$RES" text csv md charts
}

@test "004: a TSV without the keys reads 'unknown (not recorded)', never this checkout's HEAD" {
	NO_PLATFORM=1 tsv "${RES}/churn-old.tsv" "TUNING_BASELINE=unknown" <<-EOF
	$(crow 1 99 N/A 10 N/A OK)
	EOF
	head="$(git -C "$ROOT" rev-parse --short HEAD)"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format md
	assert_success
	assert_output --partial 'harness_sha: "unknown (not recorded)"'
	assert_output --partial 'istio_version: "unknown (not recorded)"'
	# Only the report's own harness (report_harness_sha) may name this checkout.
	[[ "$(grep -v '^report_harness_sha: ' <<<"$output")" != *"$head"* ]]
	refute_output --partial "istio_version: \"${ISTIO_VERSION}\""
	# From before the platform record: unknown, with one warning, never this host's platform.
	assert_line 'platform: "unknown"'
	assert_line 'mesh_operator_by_context: "unknown"'
	assert_line 'kube_versions: "unknown"'
	[[ "$stderr" == *"1 of 1 input TSV(s) have no PLATFORM line"* ]]
	# Beside a TSV that recorded them: mixed, with a warning naming the key.
	tsv "${RES}/churn-new.tsv" "HARNESS_SHA=feed123-test" "ISTIO_VERSION=1.99.0" <<-EOF
	$(crow 1 99 N/A 10 N/A OK)
	EOF
	run --separate-stderr "$REPORT" --results-dir "$RES" --format md
	assert_success
	assert_output --partial 'harness_sha: "mixed:feed123-test,unknown (not recorded)"'
	assert_line 'platform: "mixed:kubernetes,unknown"'
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

# --- 004: the platform record's warnings in the report's body (H10, H2) --------

# warned_in_body: the warnings of $1.. (one per line) in text, csv, md and charts; md and
# charts carry them under the title, before the first table, section or note.
warned_in_body() {
	local w fmt top first
	run --separate-stderr "$REPORT" --results-dir "$RES"
	assert_success
	for w in "$@"; do assert_line "WARNING: ${w}"; done
	run --separate-stderr "$REPORT" --results-dir "$RES" --format csv
	for w in "$@"; do assert_line "# WARNING: ${w}"; done
	for fmt in md charts; do
		run --separate-stderr "$REPORT" --results-dir "$RES" --format "$fmt"
		assert_success
		for w in "$@"; do assert_line "> **Warning:** ${w}"; done
		top="$(grep -n '^> \*\*Warning:\*\*' <<<"$output" | tail -1 | cut -d: -f1)"
		first="$(awk 'seen && /^(\| |## |```mermaid|> [^*])/ { print NR; exit } /^# / { seen = 1 }' <<<"$output")"
		((top < first)) || { echo "${fmt}: last warning at ${top}, first table, section or note at ${first}"; false; }
	done
	# stderr: each once.
	for w in "$@"; do
		[ "$(grep -cF "warning: ${w}" <<<"$stderr")" -eq 1 ] || { echo "$stderr"; false; }
	done
}

@test "004 (H10, H2): a build that changed during the sweep, a value not read and other Kubernetes versions warn in every format's body" {
	tsv "${RES}/churn-a.tsv" "KUBE_VERSIONS=ctx-a=v1.34.1,ctx-b=v1.34.1" <<-EOF
	$(crow 1 99 N/A 10 N/A OK)
	EOF
	local -a plat=()
	mapfile -t plat < <(platform_fixture_lines | sed 's/^# //; s/ctx-b=proxyv2:1.30.5/ctx-b=unknown/')
	NO_PLATFORM=1 tsv "${RES}/churn-b.tsv" "KUBE_VERSIONS=ctx-a=v1.34.2,ctx-b=unreachable" "${plat[@]}" <<-EOF
	$(crow 2 99 N/A 10 N/A OK)
	EOF
	# The sweep's drift check (platform_drift_check) found istiod on ctx-a on another build.
	printf '%s\n' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' '# ISTIOD_IMAGE_BY_CONTEXT=ctx-a=pilot:1.30.6' > "${RES}/platform-drift.txt"
	warned_in_body \
		"ISTIOD_IMAGE_BY_CONTEXT changed during the sweep (platform-drift.txt in res): ctx-a from pilot:1.30.5 to pilot:1.30.6; the TSVs record the value at the sweep's start, but rows measured after the change ran on other istiod builds, and the report cannot tell which rows those are; the usual cause is an Argo CD sync of a new revision or an operator upgrade; for publishable figures, run the sweep again on one build" \
		"PROXY_IMAGE_BY_CONTEXT could not be read for ctx-b in 1 of 2 input TSV(s) (recorded unknown), while other inputs have a value: the report cannot tell whether those runs had the same gateway proxy builds as the others" \
		"input TSVs disagree on KUBE_VERSIONS for ctx-a (v1.34.1;v1.34.2): the report mixes runs on different Kubernetes versions; compare like with like" \
		"KUBE_VERSIONS could not be read for ctx-b in 1 of 2 input TSV(s) (recorded unknown or unreachable), while other inputs have a value: the report cannot tell whether those runs had the same Kubernetes versions as the others"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format md
	assert_line 'istiod_image_by_context: "ctx-a=mixed:pilot:1.30.5;pilot:1.30.6,ctx-b=pilot:1.30.5"'
	assert_line 'proxy_image_by_context: "ctx-a=proxyv2:1.30.5,ctx-b=mixed:proxyv2:1.30.5;unknown"'
	# kind nodes: churn measures the control plane, so no kind data-path warning (H11 is
	# dataplane's and churn-dataplane's).
	refute_output --partial "cloud-provider-kind"
}

@test "004 (H10): inputs that agree, an operator state aside, warn in no format" {
	tsv "${RES}/churn-a.tsv" "KUBE_VERSIONS=ctx-a=v1.34.1,ctx-b=v1.34.1" <<-EOF
	$(crow 1 99 N/A 10 N/A OK)
	EOF
	local -a plat=()
	mapfile -t plat < <(platform_fixture_lines | sed 's/^# //; s#/Available#/Unavailable#g')
	NO_PLATFORM=1 tsv "${RES}/churn-b.tsv" "KUBE_VERSIONS=ctx-a=v1.34.1,ctx-b=v1.34.1" "${plat[@]}" <<-EOF
	$(crow 2 99 N/A 10 N/A OK)
	EOF
	local fmt
	for fmt in text csv md charts; do
		run --separate-stderr "$REPORT" --results-dir "$RES" --format "$fmt"
		assert_success
		refute_output --partial "WARNING"
		refute_output --partial "**Warning:**"
		refute_output --regexp '(=|"|: )mixed:'
		[ -z "$stderr" ] || { echo "$stderr"; false; }
	done
	run --separate-stderr "$REPORT" --results-dir "$RES" --format md
	assert_line 'mesh_operator_by_context: "ctx-a=sail-operator:1.31.1/Available;sail-operator:1.31.1/Unavailable,ctx-b=sail-operator:1.31.1/Available;sail-operator:1.31.1/Unavailable"'
}

@test "004: an OK row an older 002 wrote with no number in a measured column is re-derived, in every format" {
	# Iteration 1 is a real OK row. 2: the remote EDS push never came (TIMEOUT) but the
	# old 002 wrote OK. 3: a counter in neither scrape (N/A), also written OK.
	tsv "${RES}/churn-a.tsv" "HARNESS_SHA=x" "ISTIO_VERSION=y" <<-EOF
	$(crow 1 99 N/A 10 N/A OK)
	$(crow 2 99 N/A 10 N/A OK | awk -F'\t' -v OFS='\t' '{ $10 = "TIMEOUT"; print }')
	$(crow 3 99 N/A 10 N/A OK | awk -F'\t' -v OFS='\t' '{ $11 = "N/A"; print }')
	EOF
	# A mesh of 1 has no remote columns to gate: its N/A remote values stay OK.
	printf 'r1\t1\t5\t1\t5\t1\t0\t1000\tN/A\tN/A\t10\tN/A\t100\tN/A\t99\tN/A\t50\tN/A\t10\tN/A\tOK\n' >> "${RES}/churn-a.tsv"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format md
	assert_success
	assert_output --partial "| 2 | 5 | 1->5 | 3 | 1 |"
	assert_output --partial "| 1 | 5 | 1->5 | 1 | 1 |"
	[[ "$stderr" == *"warning: 2 row(s) written as OK by an older 002"* ]]
	[ "$(grep -c 'written as OK' <<<"$stderr")" = 1 ]
	run --separate-stderr "$REPORT" --results-dir "$RES"
	assert_success
	assert_output --partial "Rows (valid/total):            1/3"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format csv
	assert_success
	assert_line "2,5,1,5,rows_valid_of_total,1,1,3,1,,"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format charts
	assert_success
	assert_output --partial "2 of 4 rows dropped"
}

# --- 002 / 003: the writers ----------------------------------------------------

# Stub kubectl and curl for the churn probe: one istiod pod whose /metrics never
# changes, a watcher that lists no churn target (so the latencies are N/A). The Istio CR
# answers the pin, or STUB_ISTIO_VERSION (unreadable when it is "fail"); every call is
# logged to STUB_LOG.
_stub_bin() {
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export FX STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log"
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*)
	exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
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
*/metrics) body="${STUB_METRICS:-$FX/istiod-diag/pre_metrics.txt}" ;;
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
	# harness_sha (a dirty tree adds .<8hex> to -dirty).
	grep -qx "# HARNESS_SHA=$(source "${ROOT}/tests/lib/common.sh"; source "${ROOT}/tests/lib/preamble.sh"; harness_sha)" "$f"
	grep -qx "# ISTIO_VERSION=${ISTIO_VERSION}" "$f"
	grep -qx "# ISTIO_VERSION_PIN=${ISTIO_VERSION}" "$f"
	grep -qx "# ISTIO_VERSION_SOURCE=live" "$f"
	# Every member was ready at the start (the stub answers Healthy).
	grep -qx "# ISTIO_NOTREADY_AT_START=none" "$f"
	grep -qx "# ISTIO_READY_WAITED_SEC=0" "$f"
	head -1 "$f" | grep -Eq '(\+00:00|Z)$'
	grep -Eq '^\| Date \(UTC\) \| .*(\+00:00|Z) \|$' "$RES"/churn-*.md
	grep -q '^| Harness SHA | ' "$RES"/churn-*.md
	# The stub answers neither the version nor the platform reads: unknown, never a guess.
	grep -qx '# KUBE_VERSIONS=ctx-a=unreachable' "$f"
	grep -qx '# PLATFORM=unknown' "$f"
	grep -qx '# PLATFORM_BY_CONTEXT=ctx-a=unknown' "$f"
	grep -q '^| Platform | unknown (TEST_PLATFORM auto); ' "$RES"/churn-*.md
	# 004 reports what the probe recorded.
	run "$REPORT" --results-dir "$RES" --format md
	assert_output --partial "istio_version: \"${ISTIO_VERSION}\""
}

@test "002: a remote EDS push that never came makes the row TIMEOUT_REMOTE_EDS; 004 counts it in n_total only" {
	_stub_bin
	# The stub istiod's eds counter never moves, so the remote EDS poll times out.
	CHURN_POLL_INTERVAL_MS=50 PATH="${BIN}:${PATH}" run --separate-stderr "$PROBE" \
		--source-context ctx-a --remote-contexts ctx-b --iterations 1 --timeout 2 --settle 0 \
		--deployment-count 1 --output-dir "$RES"
	assert_success
	f="$(ls "$RES"/churn-*.tsv)"
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $10 "/" $21 }' "$f")" = TIMEOUT/TIMEOUT_REMOTE_EDS ]
	run "$REPORT" --results-dir "$RES" --format md
	assert_success
	assert_output --partial "| 2 | 1 | 1->5 | 1 | 0 |"
}

@test "002: a push counter in neither scrape is N/A with a warning, and the row is MISSING_VALUE" {
	_stub_bin
	# A scrape without pilot_push_triggers (as if renamed): never a 0 delta.
	STUB_METRICS="${BATS_TEST_TMPDIR}/no-triggers.txt"
	grep -v 'pilot_push_triggers' "${FX}/istiod-diag/pre_metrics.txt" > "$STUB_METRICS"
	export STUB_METRICS
	CHURN_POLL_INTERVAL_MS=50 PATH="${BIN}:${PATH}" run --separate-stderr "$PROBE" \
		--source-context ctx-a --iterations 1 --timeout 2 --settle 0 --deployment-count 1 \
		--output-dir "$RES"
	assert_success
	f="$(ls "$RES"/churn-*.tsv)"
	[ "$(awk -F'\t' '!/^#/ && $1 != "run_id" { print $11 "/" $13 "/" $21 }' "$f")" = N/A/0/MISSING_VALUE ]
	[[ "$stderr" == *"pilot_push_triggers on ctx-a: counter is in neither scrape"* ]]
	[[ "$stderr" == *"source_push_triggers_delta=N/A"* ]]
	run "$REPORT" --results-dir "$RES" --format md
	assert_output --partial "| 1 | 1 | 1->5 | 1 | 0 |"
}

@test "PL36: 002 and the 003 placeholder both write HARNESS_SHA, the Istio version keys and KUBE_VERSIONS" {
	for k in HARNESS_SHA KUBE_VERSIONS; do
		grep -q "^# ${k}=" "$PROBE"
		grep -q "echo \"# ${k}=" "$SWEEP"
	done
	grep -q 'istio_version_kv | sed' "$PROBE"
	grep -q 'istio_version_kv | sed' "$SWEEP"
	# The platform record has one emitter (tests/lib/platform.sh), called by both.
	grep -q 'platform_preamble_lines "\$ALL_CTXS_CSV"' "$PROBE"
	grep -q 'platform_preamble_lines "\$(IFS=,; echo "\${CONTEXTS\[\*\]:0:\$ms}")"' "$SWEEP"
	# Every timestamp the probe writes is UTC.
	run grep -nE 'date -I' "$PROBE"
	refute_output --regexp 'date -I[a-z]'
}

@test "002: a mesh that runs another Istio version stops the probe before any change; warn records the live version" {
	_stub_bin
	export STUB_ISTIO_VERSION=v1.29.0
	CHURN_POLL_INTERVAL_MS=50 PATH="${BIN}:${PATH}" run --separate-stderr "$PROBE" \
		--source-context ctx-a --remote-contexts ctx-b --iterations 1 --timeout 2 --settle 0 \
		--deployment-count 1 --output-dir "$RES"
	assert_failure 1
	[[ "$stderr" == *"the mesh runs Istio v1.29.0 (ctx-a=v1.29.0,ctx-b=v1.29.0), but ISTIO_VERSION is ${ISTIO_VERSION}"* ]]
	[[ "$stderr" == *"Nothing was changed"* ]]
	run grep -c ' scale ' "$STUB_LOG"
	assert_output 0
	[ -z "$(ls "$RES"/churn-*.tsv 2>/dev/null)" ]
	# A member whose Istio CR cannot be read stops it too.
	STUB_ISTIO_VERSION=fail CHURN_POLL_INTERVAL_MS=50 PATH="${BIN}:${PATH}" run --separate-stderr "$PROBE" \
		--source-context ctx-a --iterations 1 --timeout 2 --settle 0 --deployment-count 1 --output-dir "$RES"
	assert_failure 1
	[[ "$stderr" == *"cannot read the running Istio version on 1 of 1 members:"*"ctx-a: error: You must be logged in to the server (Unauthorized)"*"reproduce: "*"--context ctx-a get istios.sailoperator.io default -o yaml"* ]]
	# warn: the run goes on and records what the mesh runs, next to the pin.
	ISTIO_VERSION_CHECK=warn CHURN_POLL_INTERVAL_MS=50 PATH="${BIN}:${PATH}" run --separate-stderr "$PROBE" \
		--source-context ctx-a --iterations 1 --timeout 2 --settle 0 --deployment-count 1 --output-dir "$RES"
	assert_success
	[[ "$stderr" == *"warning: the mesh runs Istio v1.29.0"*"Going on (ISTIO_VERSION_CHECK=warn): the results record ISTIO_VERSION=v1.29.0 (ISTIO_VERSION_PIN=${ISTIO_VERSION})"* ]]
	f="$(ls "$RES"/churn-*.tsv)"
	grep -qx "# ISTIO_VERSION=v1.29.0" "$f"
	grep -qx "# ISTIO_VERSION_PIN=${ISTIO_VERSION}" "$f"
	grep -qx "# ISTIO_VERSION_SOURCE=live" "$f"
	grep -q "^| Istio version | v1.29.0 (read live on every member; pin ${ISTIO_VERSION}) |" "$RES"/churn-*.md
	run "$REPORT" --results-dir "$RES" --format md
	assert_output --partial 'istio_version: "v1.29.0"'
	assert_output --partial 'istio_version_source: "live"'
	assert_output --partial "istio_version_pin: \"${ISTIO_VERSION}\""
	# A bad policy value is refused, not read as fail or warn.
	ISTIO_VERSION_CHECK=yes PATH="${BIN}:${PATH}" run --separate-stderr "$PROBE" \
		--source-context ctx-a --iterations 1 --timeout 2 --settle 0 --deployment-count 1 --output-dir "$RES"
	assert_failure 1
	[[ "$stderr" == *"ISTIO_VERSION_CHECK must be fail or warn (got: yes)"* ]]
}

@test "004: two sweeps in one dir stop the report; --allow-multi-run says so in every format and shows a varying key as mixed" {
	mkdir -p "${RES}/sweep-a" "${RES}/sweep-b"
	tsv "${RES}/sweep-a/churn-a.tsv" "RUN_ID=a" "HARNESS_SHA=h1" "ISTIO_VERSION=1.30.5" "SIDECAR_EGRESS_HOSTS=none" <<-EOF
	$(crow 1 99 N/A 10 N/A OK)
	EOF
	tsv "${RES}/sweep-b/churn-b.tsv" "RUN_ID=b" "HARNESS_SHA=h2" "ISTIO_VERSION=1.30.5" "SIDECAR_EGRESS_HOSTS=./*" <<-EOF
	$(crow 1 99 N/A 10 N/A OK)
	EOF
	local fmt
	for fmt in text csv md charts; do
		run --separate-stderr "$REPORT" --results-dir "$RES" --format "$fmt"
		assert_failure 1
		[ -z "$output" ]
		[[ "$stderr" == *"error: ${RES} holds 2 runs"* ]]
		[[ "$stderr" == *"  sweep-a:"$'\n'"    ${REPORT} --results-dir '${RES}/sweep-a'"* ]]
		run --separate-stderr "$REPORT" --results-dir "$RES" --allow-multi-run --format "$fmt"
		assert_success
		assert_output --partial "This report pools 2 runs (--allow-multi-run): sweep-a, sweep-b. HARNESS_SHA: h1, h2. ISTIO_VERSION: 1.30.5. These differ"
		# charts has no SIDECAR_EGRESS_HOSTS line; the others never show one file's value.
		[[ "$fmt" == charts ]] || assert_output --partial "mixed:none,./*"
		[[ "$fmt" != csv ]] || assert_line "# POOLED_RUNS=2"
	done
	# --dry-run refuses the same way, and counts the files once allowed.
	run --separate-stderr "$REPORT" --results-dir "$RES" --dry-run
	assert_failure 1
	[[ "$stderr" == *"error: ${RES} holds 2 runs"* ]]
	refute_output --partial "would summarize"
	run --separate-stderr "$REPORT" --results-dir "$RES" --dry-run --allow-multi-run
	assert_success
	assert_output "[dry-run] would summarize 2 churn-*.tsv file(s) under ${RES} as text"
	# One sweep reports alone, with its own value.
	run --separate-stderr "$REPORT" --results-dir "${RES}/sweep-b" --format csv
	assert_success
	assert_line "# SIDECAR_EGRESS_HOSTS=./*"
	refute_output --partial "pools"
	# --help lists the flag.
	run "$REPORT" --help
	assert_output --partial "--allow-multi-run"
}

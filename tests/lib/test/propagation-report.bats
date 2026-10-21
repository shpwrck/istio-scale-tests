#!/usr/bin/env bats
# propagation 005 through its real entrypoint: averages are rounded (not truncated),
# the convergence histogram rows never bucket an average (max is the worst bucket),
# csv/json carry worst_bucket, and json mesh_size is a number.

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr

REPORT="${ROOT}/tests/propagation/005-report-results.sh"
HDR=$'run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms'

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
}

# prow <mesh> <iter> <p1_ms> <p1_conv_p99_ms>: an OK row; p2 500 ms, p3 3000 ms.
prow() {
	printf 'r1\t%s\t%s\tsrc\trmt\t0\t%s\t500\t3000\tOK\t100\t%s\t40/40\t40\t0\t0\t0\t5000\t10\n' "$@"
}

# Mesh sizes 2 and 3, three rows each: p1 1000/1001/1001 (mean 1000.67), conv p99
# 100/100/1000 (mean 400, in the 100-500 bucket no row hit).
fixture() {
	{
		echo "# RUN_ID=r1"
		[[ -n "${NO_PLATFORM:-}" ]] || platform_fixture_lines src,rmt
		echo "$HDR"
		for m in 2 3; do
			prow "$m" 1 1000 100
			prow "$m" 2 1001 100
			prow "$m" 3 1001 1000
		done
	} > "${RES}/endpoint-r1.tsv"
}

@test "005: averages are rounded to the nearest ms, not truncated" {
	fixture
	run "$REPORT" --results-dir "$RES" --format csv
	assert_success
	# The last column, n_attempted, is empty: the fixture records no ITERATIONS or REMOTES.
	assert_line "2,P1_local_wall,3,3,1000,1001,1001,1001,N/A,N/A,,"
	run "$REPORT" --results-dir "$RES" --format markdown
	# n_attempted follows n_valid ("-": the fixture records no ITERATIONS or REMOTES).
	assert_output --partial "| P1 local xDS (wall) | 3 | 3 | - | 1000 | 1001 | 1001 |"
	assert_output --partial "| 2 | 1001 (3) |"
	run "$REPORT" --results-dir "$RES"
	assert_output --regexp 'P1 local xDS \(wall\) +\| +3 \| +3 \| +- \| +1000 \| +1001 \| +1001 \|'
	run "$REPORT" --results-dir "$RES" --format json
	[ "$(jq '.rows[0] | .avg_ms == 1001 and .phase == "P1_local_wall"' <<<"$output")" = true ]
}

@test "005: histogram rows show the worst bucket and no averaged bucket" {
	fixture
	run "$REPORT" --results-dir "$RES" --format markdown
	assert_success
	assert_output --partial "| P1 conv_p99 (hist) | 3 | 3 | - | 0-100 | 500-1000 | - | 0-100 | N/A | N/A |"
	assert_output --partial "| Mesh Size | P1 wall avg (ms) | P1 conv_p99 worst (ms) |"
	assert_output --partial "| 2 | 1001 (3) | 500-1000 (3) |"
	refute_output --partial "| 100-500"
	run "$REPORT" --results-dir "$RES"
	assert_output --regexp 'P1 conv_p99 \(hist\) +\| +3 \| +3 \| +- \| +0-100 \| +500-1000 \| +- \|'
	refute_output --partial "100-500"
}

@test "005: csv and json keep the numbers and add worst_bucket; json mesh_size is a number" {
	fixture
	run "$REPORT" --results-dir "$RES" --format csv
	assert_success
	assert_line "mesh_size,phase,n_total,n_valid,min_ms,max_ms,avg_ms,p50_ms,p95_ms,p99_ms,worst_bucket,n_attempted"
	assert_line "2,P1_conv_p99,3,3,100,1000,400,100,N/A,N/A,500-1000,"
	run "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -c '[.rows[] | select(.mesh_size == 2) | {(.phase): .worst_bucket}] | add' <<<"$output")" = \
		'{"P1_local_wall":null,"P1_conv_p50":"0-100","P1_conv_p99":"500-1000","P2_discovery":null,"P3_dataplane":null}' ]
	[ "$(jq -r '[.rows[].mesh_size | type] | unique | join(",")' <<<"$output")" = number ]
}

@test "005: a phase with no valid sample is null in json, with the same keys" {
	{
		platform_fixture_lines src,rmt
		echo "$HDR"
		printf 'r1\t2\t1\tsrc\trmt\t0\tTIMEOUT\tN/A\tN/A\tTIMEOUT_ALL\tN/A\tN/A\t0/40\t40\t0\t0\t0\t5000\t10\n'
	} > "${RES}/endpoint-r1.tsv"
	run "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -c '.rows[0] | [.mesh_size, .n_total, .n_valid, .avg_ms, .worst_bucket]' <<<"$output")" = '[2,1,0,null,null]' ]
}

@test "005: the platform record reaches every format; an input from before it reads unknown, with a warning (PL19)" {
	fixture
	run --separate-stderr "$REPORT" --results-dir "$RES"
	assert_success
	assert_line "  PLATFORM: kubernetes"
	assert_line "  NODE_PROVIDER_BY_CONTEXT: src=kind,rmt=kind"
	[[ "$stderr" != *"no PLATFORM line"* ]]
	run --separate-stderr "$REPORT" --results-dir "$RES" --format markdown
	assert_line 'MESH_OPERATOR_BY_CONTEXT: "src=sail-operator:1.31.1/Available,rmt=sail-operator:1.31.1/Available"'
	run --separate-stderr "$REPORT" --results-dir "$RES" --format csv
	assert_line "# ISTIOD_IMAGE_BY_CONTEXT=src=pilot:1.30.5,rmt=pilot:1.30.5"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	[ "$(jq -r '.metadata | "\(.PLATFORM) \(.TEST_PLATFORM) \(.PROXY_IMAGE_BY_CONTEXT)"' <<<"$output")" = "kubernetes auto src=proxyv2:1.30.5,rmt=proxyv2:1.30.5" ]
	rm "${RES}"/*.tsv
	NO_PLATFORM=1 fixture
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -r '.metadata | "\(.PLATFORM) \(.MESH_OPERATOR_BY_CONTEXT)"' <<<"$output")" = "unknown unknown" ]
	[[ "$stderr" == *"1 of 1 input TSV(s) have no PLATFORM line"* ]]
}

@test "005 (S-B2): a record of 500 members goes through every format; json lists them all" {
	{
		echo "# RUN_ID=r1"
		platform_fixture_lines "$(wide_ctxs 500 src rmt)"
		echo "$HDR"
		prow 2 1 1000 100
	} > "${RES}/endpoint-r1.tsv"
	wide_record_report "$REPORT" "$RES" text csv json markdown charts
}

# --- 005: the platform record's warnings in the report's body (H10, H2) ---

# second_sweep <sed>: endpoint-r2.tsv, a mesh=4 row, with the record edited by <sed>.
second_sweep() {
	{
		echo "# RUN_ID=r2"
		platform_fixture_lines src,rmt | sed "$1"
		echo "$HDR"
		prow 4 1 1000 100
	} > "${RES}/endpoint-r2.tsv"
}

@test "005 (H10, H2): inputs that disagree and a build that changed during the sweep warn in every format's body" {
	# One sweep's dir (its steps' TSVs and platform-drift.txt): one run, whatever their RUN_IDs.
	RES="${BATS_TEST_TMPDIR}/sweep-h10"
	mkdir -p "$RES"
	fixture
	second_sweep 's/rmt=sail-operator:1.31.1/rmt=sail-operator:1.31.2/'
	# The sweep's drift check (platform_drift_check) found istiod on src on another build.
	printf '%s\n' '# DRIFT_READ_AT=2026-01-01T00:00:00Z' '# ISTIOD_IMAGE_BY_CONTEXT=src=pilot:1.30.6' > "${RES}/platform-drift.txt"
	local dis="input TSVs disagree on MESH_OPERATOR_BY_CONTEXT for rmt (sail-operator:1.31.1/Available;sail-operator:1.31.2/Available): the report mixes runs on different mesh operator builds; compare like with like"
	local drift="ISTIOD_IMAGE_BY_CONTEXT changed during the sweep (platform-drift.txt in sweep-h10): src from pilot:1.30.5 to pilot:1.30.6; the TSVs record the value at the sweep's start, but rows measured after the change ran on other istiod builds, and the report cannot tell which rows those are; the usual cause is an Argo CD sync of a new revision or an operator upgrade; for publishable figures, run the sweep again on one build"
	local fmt w top first
	run --separate-stderr "$REPORT" --results-dir "$RES"
	assert_success
	assert_line "WARNING: ${dis}"
	assert_line "WARNING: ${drift}"
	assert_line "  ISTIOD_IMAGE_BY_CONTEXT: src=mixed:pilot:1.30.5;pilot:1.30.6,rmt=pilot:1.30.5"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format csv
	assert_line "# WARNING: ${dis}"
	assert_line "# WARNING: ${drift}"
	for fmt in markdown charts; do
		run --separate-stderr "$REPORT" --results-dir "$RES" --format "$fmt"
		assert_success
		for w in "$dis" "$drift"; do assert_line "> **Warning:** ${w}"; done
		# Under the title, before the file list, the first section and the first chart.
		top="$(grep -n '^> \*\*Warning:\*\*' <<<"$output" | tail -1 | cut -d: -f1)"
		first="$(awk 'seen && /^(\| |## |```mermaid|> [^*]|\*\*Source files)/ { print NR; exit } /^# / { seen = 1 }' <<<"$output")"
		((top < first)) || { echo "${fmt}: last warning at ${top}, first table, section or note at ${first}"; false; }
	done
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -c '.warnings' <<<"$output")" = "$(jq -nc --arg a "$dis" --arg b "$drift" '[$a, $b]')" ]
	[ "$(grep -c '^warning: ' <<<"$stderr")" -eq 2 ]
}

@test "005 (H10): inputs that agree, an operator state aside, warn in no format" {
	# One sweep's dir (its steps' TSVs and platform-drift.txt): one run, whatever their RUN_IDs.
	RES="${BATS_TEST_TMPDIR}/sweep-h10"
	mkdir -p "$RES"
	fixture
	second_sweep 's#/Available#/Unavailable#g'
	local fmt
	for fmt in text csv markdown charts; do
		run --separate-stderr "$REPORT" --results-dir "$RES" --format "$fmt"
		assert_success
		refute_output --partial "WARNING"
		refute_output --partial "**Warning:**"
		refute_output --regexp '(=|"|: )mixed:'
		[[ "$stderr" != *warning* ]] || { echo "$stderr"; false; }
	done
	run --separate-stderr "$REPORT" --results-dir "$RES" --format json
	assert_success
	[ "$(jq -c '.warnings' <<<"$output")" = '[]' ]
	[ "$(jq -r '.metadata.MESH_OPERATOR_BY_CONTEXT' <<<"$output")" = "src=sail-operator:1.31.1/Available;sail-operator:1.31.1/Unavailable,rmt=sail-operator:1.31.1/Available;sail-operator:1.31.1/Unavailable" ]
	[ -z "$stderr" ]
}

@test "005: two sweeps in one dir stop the report; --allow-multi-run says so in every format; a sweep-level key that varies reads mixed (PL26)" {
	local d fmt
	for d in a b; do
		mkdir -p "${RES}/sweep-${d}"
		{
			echo "# SWEEP_RUN_ID=s${d}"
			echo "# RUN_ID=r${d}"
			echo "# HARNESS_SHA=h${d}"
			echo "# ISTIO_VERSION=1.30.5"
			echo "# ITERATIONS=$(if [[ $d == a ]]; then echo 3; else echo 5; fi)"
			platform_fixture_lines src,rmt
			echo "$HDR"
			prow 2 1 1000 100
		} > "${RES}/sweep-${d}/endpoint-r${d}.tsv"
	done
	for fmt in text csv markdown json charts; do
		run --separate-stderr "$REPORT" --results-dir "$RES" --format "$fmt"
		assert_failure 1
		[ -z "$output" ]
		[[ "$stderr" == *"error: ${RES} holds 2 runs"* ]]
		[[ "$stderr" == *"  sweep-b:"$'\n'"    ${REPORT} --results-dir '${RES}/sweep-b'"* ]]
		run --separate-stderr "$REPORT" --results-dir "$RES" --allow-multi-run --format "$fmt"
		assert_success
		# The last file's ITERATIONS is not the report's (it was last-wins).
		assert_output --partial "mixed:3,5"
		[[ "$stderr" == *"input TSVs disagree on sweep-level ITERATIONS (3,5)"* ]]
		if [[ "$fmt" == json ]]; then
			[ "$(jq -c '.pooled_runs' <<<"$output")" = '{"runs":2,"run_ids":["sweep-a","sweep-b"],"harness_sha":["ha","hb"],"istio_version":["1.30.5"]}' ]
		else
			assert_output --partial "This report pools 2 runs (--allow-multi-run): sweep-a, sweep-b. HARNESS_SHA: ha, hb. ISTIO_VERSION: 1.30.5."
		fi
	done
	run --separate-stderr "$REPORT" --results-dir "${RES}/sweep-a" --format json
	assert_success
	[ "$(jq -r '.metadata.ITERATIONS + " " + (.pooled_runs.runs | tostring)' <<<"$output")" = "3 1" ]
	[ -z "$stderr" ]
}

@test "005: a TSV written before the live-version keys pooled with a live one reads mixed for them, never live; an older TSV's readiness keys are not shown" {
	local fmt
	mkdir -p "${RES}/sweep-old" "${RES}/sweep-new"
	{
		echo "# SWEEP_RUN_ID=sold"
		echo "# RUN_ID=rold"
		echo "# ISTIO_VERSION=v1.30.5"
		echo "# ISTIO_NOTREADY_AT_START=rmt=IstiodNotReady"
		echo "# ISTIO_READY_WAITED_SEC=60"
		echo "$HDR"
		prow 2 1 1000 100
	} > "${RES}/sweep-old/endpoint-rold.tsv"
	{
		echo "# SWEEP_RUN_ID=snew"
		echo "# RUN_ID=rnew"
		echo "# ISTIO_VERSION=v1.30.5"
		echo "# ISTIO_VERSION_PIN=v1.30.5"
		echo "# ISTIO_VERSION_SOURCE=live"
		echo "# ISTIO_VERSION_BY_CONTEXT=src=v1.30.5,rmt=v1.30.5"
		echo "$HDR"
		prow 2 1 1000 100
	} > "${RES}/sweep-new/endpoint-rnew.tsv"
	run --separate-stderr "$REPORT" --results-dir "$RES" --allow-multi-run --format json
	assert_success
	[ "$(jq -r '.metadata.ISTIO_VERSION_SOURCE' <<<"$output")" = "mixed:live,unknown" ]
	[ "$(jq -r '.metadata.ISTIO_VERSION_PIN' <<<"$output")" = "mixed:v1.30.5,unknown" ]
	[[ "$stderr" == *"input TSVs disagree on sweep-level ISTIO_VERSION_SOURCE (live,unknown)"* ]]
	run --separate-stderr "$REPORT" --results-dir "$RES" --allow-multi-run --format markdown
	assert_output --partial "mixed:live,unknown"
	for fmt in text csv markdown charts json; do
		run --separate-stderr "$REPORT" --results-dir "$RES" --allow-multi-run --format "$fmt"
		refute_output --regexp '[Nn][Oo][Tt][Rr][Ee][Aa][Dd][Yy]|[Rr][Ee][Aa][Dd][Yy]_[Ww][Aa][Ii][Tt][Ee][Dd]'
	done
	# The new run alone reads live; the old one, never checked, unknown.
	run --separate-stderr "$REPORT" --results-dir "${RES}/sweep-new" --format json
	[ "$(jq -r '.metadata.ISTIO_VERSION_SOURCE' <<<"$output")" = "live" ]
	run --separate-stderr "$REPORT" --results-dir "${RES}/sweep-old" --format json
	[ "$(jq -r '.metadata.ISTIO_VERSION_SOURCE' <<<"$output")" = "unknown" ]
	# --results-dir through a symlink (results/latest -> sweep-new), no trailing slash.
	ln -s "${RES}/sweep-new" "${BATS_TEST_TMPDIR}/latest"
	run --separate-stderr "$REPORT" --results-dir "${BATS_TEST_TMPDIR}/latest" --format json
	assert_success
	[ "$(jq -r '.metadata.ISTIO_VERSION_SOURCE' <<<"$output")" = "live" ]
}

# p1rows <run_id> <mesh> <iterations> <remotes...>: an OK row per (iteration, remote); P1
# (p1_ms 1000 + iteration, conv p99 500) is the source's, the same on every remote's row.
p1rows() {
	local run="$1" ms="$2" n="$3" i r
	shift 3
	for ((i = 1; i <= n; i++)); do
		for r in "$@"; do
			printf '%s\t%s\t%s\tsrc\t%s\t0\t%s\t500\t3000\tOK\t100\t500\t40/40\t40\t0\t0\t0\t5000\t10\n' "$run" "$ms" "$i" "$r" "$((1000 + i))"
		done
	done
}

@test "PROP_ROW_AWK: P1 is one sample per (run_id, iteration), from its first counting row; P2 and P3 one per row" {
	source "${ROOT}/tests/lib/propagation.sh"
	{ echo "$HDR"; p1rows r1 4 10 b c d; p1rows r2 4 2 b c d; } > "${RES}/rows.tsv"
	run awk -F'\t' "${PROP_ROW_AWK}"'
		NR == 1 { next }
		prop_drop_reason(1000) == "" {
			p1 += prop_p1_sample(); p2 += prop_p2_sample(); p3 += prop_p3_sample()
			# Asking twice about one row does not move the state.
			if (prop_p1_first() != prop_p1_first()) bad++
		}
		END { print p1, p2, p3, bad + 0 }' "${RES}/rows.tsv"
	assert_output "12 36 36 0"
	# A dropped first row: the iteration counts from its next counting row.
	{ echo "$HDR"; p1rows r1 4 1 b c d; } | awk -F'\t' 'BEGIN { OFS = "\t" } NR == 2 { $10 = "TIMEOUT_P2" } 1' > "${RES}/rows2.tsv"
	run awk -F'\t' "${PROP_ROW_AWK}"'NR > 1 && prop_drop_reason(1000) == "" { p1 += prop_p1_sample() } END { print p1 }' "${RES}/rows2.tsv"
	assert_output 1
}

@test "005: 10 iterations x 3 remotes: P1's n is 10/10 in every format, so its p99 stays under the percentile floor" {
	{ echo "# RUN_ID=r1"; platform_fixture_lines src,b,c,d; echo "$HDR"; p1rows r1 4 10 b c d; } > "${RES}/endpoint-r1.tsv"
	run "$REPORT" --results-dir "$RES" --format json
	assert_success
	# P1 is one sample per iteration, so its n_total counts iterations too.
	[ "$(jq -c '[.rows[] | select(.mesh_size == 4) | {(.phase): [.n_total, .n_valid, .p99_ms]}] | add' <<<"$output")" = \
		'{"P1_local_wall":[10,10,null],"P1_conv_p50":[10,10,null],"P1_conv_p99":[10,10,null],"P2_discovery":[30,30,500],"P3_dataplane":[30,30,3000]}' ]
	# The P1 mean is over the 10 iterations (1001..1010).
	[ "$(jq -r '.rows[] | select(.phase == "P1_local_wall") | .avg_ms' <<<"$output")" = 1006 ]
	run "$REPORT" --results-dir "$RES" --format csv
	assert_line --regexp '^4,P1_local_wall,10,10,1001,1010,1006,'
	assert_line --regexp '^4,P1_conv_p99,10,10,'
	assert_line --regexp '^4,P2_discovery,30,30,'
	run "$REPORT" --results-dir "$RES" --format markdown
	assert_success
	assert_output --partial "| P1 local xDS (wall) | 10 | 10 |"
	assert_output --partial "| P2 remote istiod EDS | 30 | 30 |"
	run "$REPORT" --results-dir "$RES"
	assert_output --regexp 'P1 local xDS \(wall\) +\| +10 \| +10 \|'
	assert_output --regexp 'P1 conv_p99 \(hist\) +\| +10 \| +10 \|'
	run "$REPORT" --results-dir "$RES" --format charts
	assert_success
}

@test "005: 3 of 10 iterations overflowed: P1 reads 10 total, 7 valid, as 002's summary counts them" {
	source "${ROOT}/tests/lib/propagation.sh"
	# Every remote row of iterations 2, 5 and 9 carries p1_overflow=1 (P1 is source-side).
	{ echo "# RUN_ID=r1"; platform_fixture_lines src,b,c,d; echo "$HDR"; p1rows r1 4 10 b c d \
		| awk -F'\t' 'BEGIN { OFS = "\t" } $3 == 2 || $3 == 5 || $3 == 9 { $15 = 1 } 1'; } > "${RES}/endpoint-r1.tsv"
	run "$REPORT" --results-dir "$RES" --format json
	assert_success
	# A source overflow is a P1 histogram: it never drops the remote's P2/P3, even in
	# this 19-column TSV, whose rows cannot otherwise be split by side.
	[ "$(jq -c '[.rows[] | select(.mesh_size == 4) | {(.phase): [.n_total, .n_valid]}] | add' <<<"$output")" = \
		'{"P1_local_wall":[10,7],"P1_conv_p50":[10,7],"P1_conv_p99":[10,7],"P2_discovery":[30,30],"P3_dataplane":[30,30]}' ]
	run "$REPORT" --results-dir "$RES" --format csv
	assert_line --regexp '^4,P1_local_wall,10,7,'
	run "$REPORT" --results-dir "$RES" --format markdown
	assert_output --partial "| P1 local xDS (wall) | 10 | 7 |"
	assert_output --partial "| P1 conv_p99 (hist) | 10 | 7 |"
	run "$REPORT" --results-dir "$RES"
	assert_output --regexp 'P1 local xDS \(wall\) +\| +10 \| +7 \|'
	# 002's summary over the same rows (its SUMMARY_KV program: P1 n = prop_p1_sample over
	# every row, before the row filter, of the distinct (run_id, iteration)): n=7/10; P2
	# from the rows prop_drop_reason keeps: 30.
	run awk -F'\t' "${PROP_ROW_AWK}"'
		/^#/ || $1 == "run_id" { next }
		{
			if (!(($1 SUBSEP $3) in seen)) { seen[$1 SUBSEP $3] = 1; iters++ }
			if (prop_p1_sample(1000)) p1++
			if (prop_drop_reason(1000) != "") next
			if (prop_p2_sample()) p2++
		}
		END { print p1 "/" iters " " p2 }' "${RES}/endpoint-r1.tsv"
	assert_output "7/10 30"
}

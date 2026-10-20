#!/usr/bin/env bats
# HARNESS_CONTENT_KEY in the reports, through each real entrypoint (PL33), no cluster:
# HARNESS_SHA values that differ only in git describe (every input records one content
# key) give a note, not the "different harness" warning, in propagation 005, churn 004
# and tuning 004's per-pass Harness row; a key that differs, or an input without one,
# keeps the warning. churn-dataplane 005 and dataplane 004 carry the key in every
# format. propagation 005's json escapes preamble values with JSON_STR_AWK. Contexts are
# placeholders (ci-a, ci-b); the harness values are made up.

bats_require_minimum_version 1.5.0
load test_helper

KEY=0123456789ab
OTHER_KEY=ba9876543210
PROP_HDR=$'run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms'
CHURN_HDR=$'run_id\tmesh_size\tchurn_intensity\tbase_replicas\tscale_to\titeration\tt0_epoch_ns\tconvergence_local_ms\tremote_endpoint_reachable_ms\tconvergence_remote_eds_ms\tsource_push_triggers_delta\tremote_push_triggers_delta\tsource_xds_pushes_delta\tremote_xds_pushes_delta\tsource_queue_time_p99_ms\tremote_queue_time_p99_ms\tsource_connected_proxies\tremote_connected_proxies\tsource_push_time_p99_ms\tremote_push_time_p99_ms\tstatus'
CP_HDR=$'timestamp\tistiod_restarted\tistiod_mem_mi\tgo_heap_inuse_mi\tistiod_cpu_m_delta\tconvergence_p99_ms\txds_pushes_delta\tsidecar_config_bytes_avg\tconnected_proxies'

# _tsv <file> <n> <key or -> <header> <row>: a TSV of run r<n> whose HARNESS_SHA is a
# describe of commit n (v1.0-<n>-g<n x7>), with HARNESS_CONTENT_KEY <key> unless -.
_tsv() {
	local f="$1" n="$2" key="$3"
	mkdir -p "$(dirname "$f")"
	{
		echo "# RUN_ID=r${n}"
		echo "# HARNESS_SHA=v1.0-${n}-g$(printf '%07d' 0 | tr 0 "$n")"
		[[ "$key" == - ]] || echo "# HARNESS_CONTENT_KEY=${key}"
		echo "$4"
		printf '%s\n' "$5"
	} > "$f"
}

# _prop <dir> <key 1> <key 2>, _churn likewise: two runs' TSVs.
_prop() {
	local n k
	for n in 1 2; do
		if ((n == 1)); then k="$2"; else k="$3"; fi
		_tsv "$1/endpoint-r${n}.tsv" "$n" "$k" "$PROP_HDR" $'r'"${n}"$'\t2\t1\tci-a\tci-b\t0\t1000\t500\t3000\tOK\t100\t100\t40/40\t40\t0\t0\t0\t5000\t10'
	done
}
_churn() {
	local n k
	for n in 1 2; do
		if ((n == 1)); then k="$2"; else k="$3"; fi
		_tsv "$1/churn-r${n}.tsv" "$n" "$k" "$CHURN_HDR" $'r'"${n}"$'\t2\t5\t1\t5\t1\t0\t1000\t2000\t300\t10\t20\t100\t200\t99\tN/A\t50\t60\t10\tN/A\tOK'
	done
}

NOTE="HARNESS_SHA values (v1.0-1-g1111111,v1.0-2-g2222222) differ only in git describe (a commit or tag that left the harness files as they were): every input records HARNESS_CONTENT_KEY=${KEY}"

@test "propagation 005: HARNESS_SHA values that differ only in git describe give a note; a different key, or a TSV without one, keeps the warning" {
	local d="${BATS_TEST_TMPDIR}/p"
	_prop "$d" "$KEY" "$KEY"
	run --separate-stderr "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$d" --allow-multi-run --format md
	assert_success
	[[ "$stderr" == *"note: the input TSVs' ${NOTE}"* ]]
	[[ "$stderr" != *"disagree on sweep-level HARNESS_SHA"* ]]
	assert_line "HARNESS_CONTENT_KEY: \"${KEY}\""
	_prop "$d" "$KEY" "$OTHER_KEY"
	run --separate-stderr "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$d" --allow-multi-run --format md
	assert_success
	[[ "$stderr" == *"warning: input TSVs disagree on sweep-level HARNESS_SHA"* ]]
	[[ "$stderr" != *"differ only in git describe"* ]]
	_prop "$d" "$KEY" -
	run --separate-stderr "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$d" --allow-multi-run --format md
	assert_success
	[[ "$stderr" == *"warning: input TSVs disagree on sweep-level HARNESS_SHA"* ]]
	[[ "$stderr" != *"differ only in git describe"* ]]
}

@test "churn 004: HARNESS_SHA values that differ only in git describe give a note; a different key, or a TSV without one, keeps the warning; every format prints the key" {
	local d="${BATS_TEST_TMPDIR}/c" f
	_churn "$d" "$KEY" "$KEY"
	run --separate-stderr "${ROOT}/tests/churn/004-report-results.sh" --results-dir "$d" --allow-multi-run --format md
	assert_success
	[[ "$stderr" == *"note: the input TSVs' ${NOTE}"* ]]
	[[ "$stderr" != *"disagree on HARNESS_SHA"* ]]
	assert_line "harness_content_key: \"${KEY}\""
	for f in text csv charts; do
		run --separate-stderr "${ROOT}/tests/churn/004-report-results.sh" --results-dir "$d" --allow-multi-run --format "$f"
		assert_success
		assert_output --partial "$KEY"
	done
	_churn "$d" "$KEY" "$OTHER_KEY"
	run --separate-stderr "${ROOT}/tests/churn/004-report-results.sh" --results-dir "$d" --allow-multi-run --format text
	assert_success
	[[ "$stderr" == *"warning: input TSVs disagree on HARNESS_SHA"* ]]
	[[ "$stderr" != *"differ only in git describe"* ]]
	_churn "$d" "$KEY" -
	run --separate-stderr "${ROOT}/tests/churn/004-report-results.sh" --results-dir "$d" --allow-multi-run --format text
	assert_success
	[[ "$stderr" == *"warning: input TSVs disagree on HARNESS_SHA"* ]]
	[[ "$stderr" != *"differ only in git describe"* ]]
}

@test "tuning 004: a per-pass Harness row; passes on different harnesses warn, unless every pass records one content key (a note); a pass without a key keeps the warning" {
	local S="${BATS_TEST_TMPDIR}/sweep" p n k
	mkdir -p "$S"
	printf '# SUITE=controlplane\n# PASSES=baseline,01-x\n# HARNESS_SHA=v1.0-1-g1111111\n# HARNESS_CONTENT_KEY=%s\n' "$KEY" > "${S}/sweep-metadata.txt"
	# _passes <key of 01-x>: baseline on commit 1, 01-x on commit 2, both with KEY unless
	# 01-x's is given.
	_passes() {
		for p in baseline 01-x; do
			if [[ "$p" == baseline ]]; then n=1 k="$KEY"; else n=2 k="$1"; fi
			_tsv "${S}/${p}/controlplane-${p}.tsv" "$n" "$k" "$CP_HDR" $'t\t0\t512\t300\t250\t99\t438\t20480\t10'
		done
	}
	_passes "$KEY"
	run --separate-stderr "${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "$S" --format md
	assert_success
	assert_line "| Harness (HARNESS_SHA) | v1.0-1-g1111111 | v1.0-2-g2222222 |"
	assert_line "harness_content_key: \"${KEY}\""
	assert_line "- Note: the passes' HARNESS_SHA values (baseline v1.0-1-g1111111; 01-x v1.0-2-g2222222) differ only in git describe (a commit or tag that left the harness files as they were): every pass records HARNESS_CONTENT_KEY=${KEY}, the same harness files."
	refute_output --partial "**Warning:** the passes ran on different harnesses"
	[[ "$stderr" == *"note: the passes' HARNESS_SHA values (baseline v1.0-1-g1111111; 01-x v1.0-2-g2222222) differ only in git describe (a commit or tag that left the harness files as they were): every pass records HARNESS_CONTENT_KEY=${KEY}, the same harness files."* ]]
	[[ "$stderr" != *"WARNING"* ]]
	_passes "$OTHER_KEY"
	run --separate-stderr "${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "$S"
	assert_success
	assert_output --regexp $'\nHarness \\(HARNESS_SHA\\) +v1\\.0-1-g1111111 +v1\\.0-2-g2222222\n'
	assert_line "WARNING: the passes ran on different harnesses (HARNESS_SHA baseline v1.0-1-g1111111; 01-x v1.0-2-g2222222): a profile's change against the baseline may come from the harness, not the profile. Compare those passes with care."
	[[ "$stderr" == *"WARNING: the passes ran on different harnesses"* ]]
	_passes -
	run --separate-stderr "${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "$S" --format md
	assert_success
	assert_line --partial "- **Warning:** the passes ran on different harnesses"
	refute_output --partial "differ only in git describe"
	# One harness for every pass: neither.
	for p in baseline 01-x; do _tsv "${S}/${p}/controlplane-${p}.tsv" 1 "$KEY" "$CP_HDR" $'t\t0\t512\t300\t250\t99\t438\t20480\t10'; done
	run --separate-stderr "${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "$S" --format md
	assert_success
	assert_line "| Harness (HARNESS_SHA) | v1.0-1-g1111111 | v1.0-1-g1111111 |"
	refute_output --partial "different harnesses"
	refute_output --partial "differ only in git describe"
}

@test "churn-dataplane 005 and dataplane 004 carry HARNESS_CONTENT_KEY in every format" {
	local d="${BATS_TEST_TMPDIR}/cdp" f
	_tsv "${d}/churn-dataplane-r1.tsv" 1 "$KEY" \
		$'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms' \
		$'r1\tv1.0-1-g1111111\tc1\t2\t0\tbaseline\t60\t50\t50\t2\t3\t5\t6\t7\tN/A\t0\tOK\t10\t10\t100\tN/A\t5\tN/A\tN/A\tN/A\nr1\tv1.0-1-g1111111\tc1\t2\t1\tchurn\t60\t50\t48\t4\t3\t9\t6\t7\tN/A\t0\tOK\t10\t10\t100\t30\t5\t99\tN/A\tN/A'
	run --separate-stderr "${ROOT}/tests/churn-dataplane/005-report-results.sh" --results-dir "$d" --format json
	assert_success
	[ "$(jq -r '.metadata.harness_content_key' <<<"$output")" = "$KEY" ]
	run --separate-stderr "${ROOT}/tests/churn-dataplane/005-report-results.sh" --results-dir "$d" --format md
	assert_success
	assert_line "harness_content_key: \"${KEY}\""
	for f in text csv; do
		run --separate-stderr "${ROOT}/tests/churn-dataplane/005-report-results.sh" --results-dir "$d" --format "$f"
		assert_success
		assert_line "# HARNESS_CONTENT_KEY=${KEY}"
	done
	d="${BATS_TEST_TMPDIR}/dp"
	_tsv "${d}/latency-r1.tsv" 1 "$KEY" \
		$'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class' \
		$'r1\t2\tci-a\tci-a\t10\t10\t8\t30\t2.0\t2.5\t5.0\t11.0\t12.5\tOK\t1\t0\tlocal'
	run --separate-stderr "${ROOT}/tests/dataplane/004-report-results.sh" --results-dir "$d" --format json
	assert_success
	[ "$(jq -r '.metadata.HARNESS_CONTENT_KEY' <<<"$output")" = "$KEY" ]
	for f in text csv; do
		run --separate-stderr "${ROOT}/tests/dataplane/004-report-results.sh" --results-dir "$d" --format "$f"
		assert_success
		assert_line "# HARNESS_CONTENT_KEY=${KEY}"
	done
}

@test "dataplane 004 and churn-dataplane 005 pooled (--allow-multi-run): HARNESS_SHA values that differ only in git describe give the same note as every report; another key keeps 'These differ'" {
	local d f note k2
	note="The HARNESS_SHA values differ only in git describe: every run records HARNESS_CONTENT_KEY=${KEY}, the same harness files (a commit or tag that left the harness files as they were)."
	for k2 in "$KEY" "$OTHER_KEY"; do
		d="${BATS_TEST_TMPDIR}/dp-${k2}"
		for f in 1 2; do
			_tsv "${d}/sweep-r${f}/latency-r${f}.tsv" "$f" "$([[ "$f" == 1 ]] && echo "$KEY" || echo "$k2")" \
				$'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class' \
				"r${f}"$'\t2\tci-a\tci-a\t10\t10\t8\t30\t2.0\t2.5\t5.0\t11.0\t12.5\tOK\t1\t0\tlocal'
		done
		run --separate-stderr "${ROOT}/tests/dataplane/004-report-results.sh" --results-dir "$d" --allow-multi-run --format csv
		assert_success
		if [[ "$k2" == "$KEY" ]]; then
			assert_line "# NOTE: This report pools 2 runs (--allow-multi-run): sweep-r1, sweep-r2. HARNESS_SHA: v1.0-1-g1111111, v1.0-2-g2222222. ISTIO_VERSION: unknown. ${note}"
			refute_output --partial "These differ"
		else
			assert_line "# NOTE: This report pools 2 runs (--allow-multi-run): sweep-r1, sweep-r2. HARNESS_SHA: v1.0-1-g1111111, v1.0-2-g2222222. ISTIO_VERSION: unknown. These differ, so the pooled rows were not all measured with the same harness."
			refute_output --partial "differ only in git describe"
		fi
	done
	d="${BATS_TEST_TMPDIR}/cdp-pool"
	for f in 1 2; do
		_tsv "${d}/sweep-r${f}/churn-dataplane-r${f}.tsv" "$f" "$KEY" \
			$'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms' \
			"r${f}"$'\tv1.0-'"${f}"'-g'"$(printf '%07d' 0 | tr 0 "$f")"$'\tc1\t2\t0\tbaseline\t60\t50\t50\t2\t3\t5\t6\t7\tN/A\t0\tOK\t10\t10\t100\tN/A\t5\tN/A\tN/A\tN/A'
	done
	run --separate-stderr "${ROOT}/tests/churn-dataplane/005-report-results.sh" --results-dir "$d" --allow-multi-run --format csv
	assert_success
	assert_output --partial "$note"
}

@test "propagation 005 json: preamble values and data warnings go through JSON_STR_AWK; control characters are dropped, quotes, backslashes and tabs kept" {
	local d="${BATS_TEST_TMPDIR}/j"
	mkdir -p "$d"
	{
		echo "# RUN_ID=r1"
		printf '# HARNESS_SHA=h"1\\x\tz\001\n'
		printf '# HARNESS_CONTENT_KEY=%s\n' "$KEY"
		echo "$PROP_HDR"
		printf 'r1\t2\t1\tci-a\tci-b\t0\t1000\t500\t3000\tDRAIN_TIMEOUT\t100\t100\t40/40\t40\t0\t0\t0\t5000\t10\n'
	} > "${d}/endpoint-r1.tsv"
	run --separate-stderr "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "$d" --format json
	assert_success
	jq -e . <<<"$output" > /dev/null
	[ "$(jq -r '.metadata.HARNESS_SHA' <<<"$output")" = $'h"1\\x\tz' ]
	[ "$(jq -r '.metadata.HARNESS_CONTENT_KEY' <<<"$output")" = "$KEY" ]
	[ "$(jq -r '.metadata.iterations[0].RUN_ID' <<<"$output")" = r1 ]
	[[ "$(jq -r '.data_warnings[0]' <<<"$output")" == "mesh size 2: the drain after 1 iteration(s) timed out (DRAIN_TIMEOUT: "* ]]
	# 005 keeps no escaper of its own: it uses common.sh's JSON_STR_AWK.
	run ! grep -q 'json_escape()' "${ROOT}/tests/propagation/005-report-results.sh"
	grep -q 'JSON_STR_AWK' "${ROOT}/tests/propagation/005-report-results.sh"
}

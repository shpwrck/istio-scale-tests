#!/usr/bin/env bats
# Reads that fork nothing per file give the results of the commands they replaced:
# fanout_body_complete, _config_distinct and config_check_multi_run, file_min_bytes, and
# churn 004's one awk pass over each input's preamble keys. Names are placeholders (ci-a).

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr
source "${ROOT}/tests/lib/timestamp.sh"
source "${ROOT}/tests/lib/metrics.sh"
source "${ROOT}/tests/lib/fanout.sh"
source "${ROOT}/tests/lib/config.sh"

CHURN_HDR=$'run_id\tmesh_size\tchurn_intensity\tbase_replicas\tscale_to\titeration\tt0_epoch_ns\tconvergence_local_ms\tremote_endpoint_reachable_ms\tconvergence_remote_eds_ms\tsource_push_triggers_delta\tremote_push_triggers_delta\tsource_xds_pushes_delta\tremote_xds_pushes_delta\tsource_queue_time_p99_ms\tremote_queue_time_p99_ms\tsource_connected_proxies\tremote_connected_proxies\tsource_push_time_p99_ms\tremote_push_time_p99_ms\tstatus'
CD_HDR=$'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms'

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
	KC="${BATS_TEST_TMPDIR}/empty.kubeconfig"
	: > "$KC"
	export TMPDIR="$BATS_TEST_TMPDIR"
}

DP_HDR=$'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class'

# _gen_tsv <suite> <dir> <run_id> <generations|->: one input of the suite's report, with
# `# ISTIO_GENERATIONS=` (none for -).
_gen_tsv() {
	local s="$1" d="$2" id="$3" g="$4" gl=""
	mkdir -p "$d"
	[[ "$g" == - ]] || gl="# ISTIO_GENERATIONS=${g}"
	case "$s" in
	propagation)
		source "${ROOT}/tests/lib/propagation.sh"
		{ echo "# RUN_ID=${id}"; [[ -z "$gl" ]] || echo "$gl"; echo "$PROP_TSV_HEADER"; prop_placeholder_row "$id" 2 ci-a SETUP_FAILED; } > "${d}/endpoint-${id}.tsv" ;;
	dataplane)
		{ echo "# RUN_ID=${id}"; [[ -z "$gl" ]] || echo "$gl"; echo "$DP_HDR"; printf '%s\t2\tci-a\tci-b\t100\t100\t8\t30\t2.0\t2.5\t5.0\t11.0\t12.5\tOK\t100\t0\tremote\n' "$id"; } > "${d}/latency-${id}.tsv" ;;
	churn)
		{ echo "# RUN_ID=${id}"; [[ -z "$gl" ]] || echo "$gl"; echo "$CHURN_HDR"; printf '%s\t2\t5\t1\t5\t1\t0\t1000\t2000\t300\t10\t20\t100\t200\t99\t99\t50\t60\t10\t10\tOK\n' "$id"; } > "${d}/churn-${id}.tsv" ;;
	churn-dataplane)
		{
			echo "# RUN_ID=${id}"; [[ -z "$gl" ]] || echo "$gl"; echo "$CD_HDR"
			printf '%s\tsha\tc1\t2\t%s\t%s\t60\t50\t48\t4\t3\t9\t6\t7\tN/A\t0\tOK\t10\t10\t100\t30\t5\t99\tN/A\tN/A\n' "$id" 0 baseline "$id" 1 churn
		} > "${d}/churn-dataplane-${id}.tsv" ;;
	controlplane)
		G="$gl" ID="$id" awk '/^# HARNESS_SHA=/ && ENVIRON["G"] != "" { print ENVIRON["G"] } /^# RUN_ID=/ { print "# RUN_ID=" ENVIRON["ID"]; next } { print }' \
			"${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv" > "${d}/controlplane-${id}.tsv" ;;
	esac
}

@test "fanout_body_complete: complete at FANOUT_MIN_SCRAPE_BYTES bytes, never for an empty, short or missing file" {
	local d="$BATS_TEST_TMPDIR"
	head -c 511 /dev/zero | tr '\0' x > "${d}/b511"
	head -c 512 /dev/zero | tr '\0' x > "${d}/b512"
	: > "${d}/empty"
	# 300 two-byte characters: 600 bytes, fewer than 512 characters (counted in bytes).
	printf '%300s' '' | sed 's/ /é/g' > "${d}/multi"
	[ "$(wc -c < "${d}/multi" | tr -d ' ')" -eq 600 ]
	run fanout_body_complete "${d}/b511"; assert_failure
	run fanout_body_complete "${d}/b512"; assert_success
	run fanout_body_complete "${d}/empty"; assert_failure
	run fanout_body_complete "${d}/missing"; assert_failure
	LC_ALL=C.UTF-8 run fanout_body_complete "${d}/multi"; assert_success
	run fanout_body_complete "${d}/multi"; assert_success
	FANOUT_MIN_SCRAPE_BYTES=601 run fanout_body_complete "${d}/multi"; assert_failure
	# A complete body costs no fork: a wc that fails cannot change the answer.
	mkdir -p "${d}/nowc"
	printf '#!/bin/sh\nexit 1\n' > "${d}/nowc/wc"
	chmod +x "${d}/nowc/wc"
	PATH="${d}/nowc:${PATH}" run fanout_body_complete "${d}/b512"
	assert_success
	PATH="${d}/nowc:${PATH}" run fanout_body_complete "${d}/missing"
	assert_failure
}

@test "_config_distinct and config_check_multi_run read a=b names, empty, missing and sweep files as before" {
	local d="${BATS_TEST_TMPDIR}/mr"
	mkdir -p "${d}/sweep-s1"
	printf '# SWEEP_RUN_ID=sweep-s1\n# RUN_ID=s1-a\n# HARNESS_SHA=aaa\n# ISTIO_VERSION=v1.30.5\nrun_id\tx\ns1-a\t1\n' > "${d}/sweep-s1/a.tsv"
	printf '# RUN_ID=s1-b\n# HARNESS_SHA=aaa\nrun_id\tx\ns1-b\t1\n' > "${d}/sweep-s1/b.tsv"
	printf '# RUN_ID=r9\n# HARNESS_SHA=bbb\n# ISTIO_VERSION=1.30.4\nrun_id\tx\nr9\t1\n' > "${d}/a=b.tsv"
	: > "${d}/empty.tsv"
	printf 'run_id\tx\nr7\t1\n' > "${d}/norunid.tsv"
	local -a F=("${d}/sweep-s1/a.tsv" "${d}/sweep-s1/b.tsv" "${d}/a=b.tsv" "${d}/empty.tsv" "${d}/norunid.tsv" "${d}/missing.tsv")
	[ "$(_config_distinct HARNESS_SHA unknown "${F[@]}" | paste -sd'|' -)" = "aaa|bbb|unknown" ]
	[ "$(_config_distinct HARNESS_SHA '' "${F[@]}" | paste -sd'|' -)" = "aaa|bbb" ]
	[ "$(_config_distinct ISTIO_VERSION unknown "${F[@]}" | paste -sd'|' -)" = "v1.30.5|unknown|1.30.4" ]
	[ -z "$(_config_distinct HARNESS_SHA unknown)" ]
	# The run key: the sweep-* dir, else SWEEP_RUN_ID, RUN_ID, the first row's run id, the name.
	[ "$(_config_run_key "${d}/a=b.tsv" "${d}/norunid.tsv" "${d}/empty.tsv" | paste -sd'|' -)" = "r9|r7|empty.tsv" ]
	config_check_multi_run "$d" 1 "${F[@]}" 2>/dev/null
	[ "$MULTI_RUN_N" = 5 ]
	[ "$MULTI_RUN_IDS" = "empty.tsv,missing.tsv,r7,r9,sweep-s1" ]
	[ "$MULTI_RUN_HARNESS_SHAS" = "aaa,bbb,unknown" ]
	[ "$MULTI_RUN_ISTIO_VERSIONS" = "v1.30.5,unknown,1.30.4" ]
	run config_check_multi_run "$d" 0 "${F[@]}"
	assert_failure
	assert_output --partial "holds 5 runs"
	assert_output --partial "  sweep-s1:"
	assert_output --partial "for f in '${d}/a=b.tsv'; do"
	# One sweep alone: one run, nothing printed.
	run config_check_multi_run "${d}/sweep-s1" 0 "${d}/sweep-s1/a.tsv" "${d}/sweep-s1/b.tsv"
	assert_success
	assert_output ""
}

@test "file_min_bytes: at least n bytes, at the boundary, in multibyte text and with NUL bytes; a complete file needs no wc (nothing forked); false for short, empty, missing, a directory or a bad n" {
	local d="${BATS_TEST_TMPDIR}/fmb" i
	mkdir -p "$d/dir"
	printf '%0512d' 0 > "$d/512"
	head -c 511 "$d/512" > "$d/511"
	printf '%0513d' 0 > "$d/513"
	: > "$d/empty"
	# 200 two-byte characters: 400 bytes; 300 of them: 600 bytes.
	for ((i = 0; i < 200; i++)); do printf '\303\251'; done > "$d/mb400"
	for ((i = 0; i < 300; i++)); do printf '\303\251'; done > "$d/mb600"
	# 520 bytes, 10 of them NUL (the read builtin drops them: the wc fallback counts them).
	{ head -c 300 "$d/512"; printf '\0\0\0\0\0\0\0\0\0\0'; head -c 210 "$d/512"; } > "$d/nul520"
	{ head -c 300 "$d/512"; printf '\0\0\0\0\0\0\0\0\0\0'; head -c 100 "$d/512"; } > "$d/nul410"
	for loc in C C.UTF-8; do
		LC_ALL="$loc" file_min_bytes "$d/512" 512
		LC_ALL="$loc" file_min_bytes "$d/513" 512
		! LC_ALL="$loc" file_min_bytes "$d/511" 512
		LC_ALL="$loc" file_min_bytes "$d/511" 511
		! LC_ALL="$loc" file_min_bytes "$d/mb400" 512
		LC_ALL="$loc" file_min_bytes "$d/mb600" 512
		LC_ALL="$loc" file_min_bytes "$d/nul520" 512
		! LC_ALL="$loc" file_min_bytes "$d/nul410" 512
	done
	! file_min_bytes "$d/empty" 512
	! file_min_bytes "$d/missing" 512
	! file_min_bytes "$d/dir" 512
	! file_min_bytes "$d/512" abc
	! file_min_bytes "$d/512" ""
	# n = 0: any readable regular file, empty included.
	file_min_bytes "$d/empty" 0
	! file_min_bytes "$d/dir" 0
	# A complete file is decided by the read builtin alone: no wc on PATH, still true; a
	# short one needs wc, so without it reads as short.
	(PATH="${BATS_TEST_TMPDIR}/no-such-dir"; file_min_bytes "$d/513" 512)
	(PATH="${BATS_TEST_TMPDIR}/no-such-dir"; ! file_min_bytes "$d/nul520" 512)
}

@test "churn 004 reads each input's preamble key once in one awk, as grep -m1 did: a key that differs warns, v1.30.5 and 1.30.5 do not, a missing key reads unknown (not recorded), the first of two lines counts" {
	local d="${RES}/rm"
	_gen_tsv churn "$d" r1 -
	_gen_tsv churn "$d" r2 -
	_gen_tsv churn "$d" r3 -
	sed -i.bak '1a\
# ISTIO_VERSION=v1.30.5\
# ISTIO_ACTIVE_REVISIONS=ci-a=rev-a' "${d}/churn-r1.tsv"
	sed -i.bak '1a\
# ISTIO_VERSION=1.30.5\
# ISTIO_ACTIVE_REVISIONS=ci-a=rev-a\
# ISTIO_ACTIVE_REVISIONS=ci-a=rev-b' "${d}/churn-r2.tsv"
	sed -i.bak '1a\
# ISTIO_VERSION=v1.30.5\
# ISTIO_ACTIVE_REVISIONS=ci-a=rev-b' "${d}/churn-r3.tsv"
	rm -f "$d"/*.bak
	run --separate-stderr "${ROOT}/tests/churn/004-report-results.sh" --results-dir "$d" --allow-multi-run --format csv
	assert_success
	# v1.30.5 and 1.30.5 are one version: no warning.
	assert_line '# ISTIO_VERSION=v1.30.5'
	[[ "$stderr" != *"disagree on ISTIO_VERSION "* ]]
	# r2's first ISTIO_ACTIVE_REVISIONS line counts (as grep -m1): r1 and r2 agree, r3 differs.
	assert_line '# ISTIO_ACTIVE_REVISIONS=mixed:ci-a=rev-a,ci-a=rev-b'
	[[ "$stderr" == *"warning: input TSVs disagree on ISTIO_ACTIVE_REVISIONS (ci-a=rev-a,ci-a=rev-b); the report mixes runs"* ]]
	# A key no input records reads unknown (not recorded), without a warning.
	assert_line '# ISTIO_PROXY_VERSIONS=unknown (not recorded)'
	[[ "$stderr" != *"disagree on ISTIO_PROXY_VERSIONS"* ]]
	# r3 on rev-a too: every first line reads rev-a (r2's second line is not read).
	sed -i.bak 's/^# ISTIO_ACTIVE_REVISIONS=ci-a=rev-b$/# ISTIO_ACTIVE_REVISIONS=ci-a=rev-a/' "${d}/churn-r3.tsv" && rm -f "${d}/churn-r3.tsv.bak"
	run --separate-stderr "${ROOT}/tests/churn/004-report-results.sh" --results-dir "$d" --allow-multi-run --format csv
	assert_line '# ISTIO_ACTIVE_REVISIONS=ci-a=rev-a'
	[[ "$stderr" != *"disagree on ISTIO_ACTIVE_REVISIONS"* ]]
	# One input without a key the others record: mixed with unknown, and a warning.
	sed -i.bak '/^# ISTIO_ACTIVE_REVISIONS=/d' "${d}/churn-r3.tsv" && rm -f "${d}/churn-r3.tsv.bak"
	run --separate-stderr "${ROOT}/tests/churn/004-report-results.sh" --results-dir "$d" --allow-multi-run --format csv
	assert_line '# ISTIO_ACTIVE_REVISIONS=mixed:ci-a=rev-a,unknown (not recorded)'
	[[ "$stderr" == *"warning: input TSVs disagree on ISTIO_ACTIVE_REVISIONS (ci-a=rev-a,unknown (not recorded))"* ]]
}

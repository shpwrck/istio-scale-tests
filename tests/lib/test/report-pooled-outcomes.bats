#!/usr/bin/env bats
# A pooled report (--allow-multi-run over a base dir of sweep-* dirs) repeats only its
# results dir's own sweep-outcome.txt, never a pooled sweep's: dataplane 004, churn 004,
# churn-dataplane 005 and propagation 005, through their real entrypoints (PL33), say so in
# the pooled note (text, md, csv), and their --help names the pooled HARNESS_CONTENT_KEY
# values and that. A report of one sweep says nothing of it. Harness values are made up.

bats_require_minimum_version 1.5.0
load test_helper

NOTE="This report repeats only the results dir's own sweep-outcome.txt, when it has one, never that of a sweep-* dir below it: report each sweep alone to see its failed cells, problems and notes."
DP_HDR=$'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class'
CHURN_HDR=$'run_id\tmesh_size\tchurn_intensity\tbase_replicas\tscale_to\titeration\tt0_epoch_ns\tconvergence_local_ms\tremote_endpoint_reachable_ms\tconvergence_remote_eds_ms\tsource_push_triggers_delta\tremote_push_triggers_delta\tsource_xds_pushes_delta\tremote_xds_pushes_delta\tsource_queue_time_p99_ms\tremote_queue_time_p99_ms\tsource_connected_proxies\tremote_connected_proxies\tsource_push_time_p99_ms\tremote_push_time_p99_ms\tstatus'
CDP_HDR=$'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms'
PROP_HDR=$'run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms'

# _base <suite> <dir>: a base dir with sweep-r1/ and sweep-r2/, one TSV each of <suite>;
# sweep-r1 also holds its finished outcome with a PROBLEM. Prints the report's path.
_base() {
	local suite="$1" d="$2" n f hdr rowv rep
	for n in 1 2; do
		mkdir -p "${d}/sweep-r${n}"
		case "$suite" in
		dataplane) f="latency-r${n}.tsv" hdr="$DP_HDR" rowv=$'\t2\tci-a\tci-a\t10\t10\t8\t30\t2.0\t2.5\t5.0\t11.0\t12.5\tOK\t1\t0\tlocal' ;;
		churn) f="churn-r${n}.tsv" hdr="$CHURN_HDR" rowv=$'\t2\t5\t1\t5\t1\t0\t1000\t2000\t300\t10\t20\t100\t200\t99\tN/A\t50\t60\t10\tN/A\tOK' ;;
		churn-dataplane) f="churn-dataplane-r${n}.tsv" hdr="$CDP_HDR" rowv=$'\th'"${n}"$'\tc1\t2\t0\tbaseline\t60\t50\t50\t2\t3\t5\t6\t7\tN/A\t0\tOK\t10\t10\t100\tN/A\t5\tN/A\tN/A\tN/A' ;;
		propagation) f="endpoint-r${n}.tsv" hdr="$PROP_HDR" rowv=$'\t2\t1\tci-a\tci-b\t0\t1000\t500\t3000\tOK\t100\t100\t40/40\t40\t0\t0\t0\t5000\t10' ;;
		esac
		printf '# RUN_ID=r%s\n# HARNESS_SHA=h%s\n%s\nr%s%s\n' "$n" "$n" "$hdr" "$n" "$rowv" > "${d}/sweep-r${n}/${f}"
	done
	printf 'RUN_ID=r1\nEXIT=4\nFAILED=0\nPROBLEM=the harness changed during the sweep\n' > "${d}/sweep-r1/sweep-outcome.txt"
	case "$suite" in
	dataplane | churn) rep=004-report-results.sh ;;
	*) rep=005-report-results.sh ;;
	esac
	echo "${ROOT}/tests/${suite}/${rep}"
}

@test "a pooled report over sweep-* dirs says in its pooled note (text, md, csv) that it repeats no pooled sweep's own outcome; one sweep's report does not" {
	local suite d rep
	for suite in dataplane churn churn-dataplane propagation; do
		d="${BATS_TEST_TMPDIR}/${suite}"
		rep="$(_base "$suite" "$d")"
		run --separate-stderr "$rep" --results-dir "$d" --allow-multi-run --format text
		assert_success
		[[ "$output" == *"POOLED RUNS: This report pools 2 runs"*" ${NOTE}"* ]] || { echo "$suite: $output"; false; }
		run --separate-stderr "$rep" --results-dir "$d" --allow-multi-run --format md
		assert_success
		assert_output --partial "> **Pooled runs.** This report pools 2 runs"
		assert_output --partial " ${NOTE}"
		run --separate-stderr "$rep" --results-dir "$d" --allow-multi-run --format csv
		assert_success
		assert_line "# NOTE: ${NOTE}"
		# One sweep: its own outcome is repeated, and nothing is said of pooled ones.
		run --separate-stderr "$rep" --results-dir "${d}/sweep-r1" --format text
		assert_success
		refute_output --partial "$NOTE"
		assert_output --partial "the harness changed during the sweep"
	done
}

@test "every pooling report's --help names the pooled HARNESS_CONTENT_KEY values and that a sweep-* dir's own outcome is not read" {
	local f h
	for f in dataplane/004-report-results.sh churn/004-report-results.sh churn-dataplane/005-report-results.sh \
		propagation/005-report-results.sh; do
		run --separate-stderr "${ROOT}/tests/${f}" --help
		assert_success
		# The flag's paragraph, its lines joined.
		h="$(awk '/^  --allow-multi-run/ { on = 1 } on && /^  --format/ { exit } on { sub(/^ +/, ""); printf "%s ", $0 }' <<<"$output")"
		[[ "$h" == *"(csv # POOLED_HARNESS_CONTENT_KEYS="*"also their HARNESS_CONTENT_KEY values); its note says when the HARNESS_SHA values differ only in git describe (every run records one key). It does not read the sweep-outcome.txt of a sweep-* dir below the results dir: report each sweep alone to see it."* ]] \
			|| { echo "${f}: ${h}"; false; }
	done
}

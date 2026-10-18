#!/usr/bin/env bats
# The pooled sweep records a report names in its pooled note (report-pooled-briefs.bats)
# are on stderr too, in one warning, so a report written to a file still shows them:
# dataplane 004, churn 004, churn-dataplane 005 and propagation 005, through their real
# entrypoints (PL33), pooled (--allow-multi-run) and of one sweep from its parent dir. No
# warning when every record ended cleanly. Harness values are made up.

bats_require_minimum_version 1.5.0
load test_helper

DP_HDR=$'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class'
CHURN_HDR=$'run_id\tmesh_size\tchurn_intensity\tbase_replicas\tscale_to\titeration\tt0_epoch_ns\tconvergence_local_ms\tremote_endpoint_reachable_ms\tconvergence_remote_eds_ms\tsource_push_triggers_delta\tremote_push_triggers_delta\tsource_xds_pushes_delta\tremote_xds_pushes_delta\tsource_queue_time_p99_ms\tremote_queue_time_p99_ms\tsource_connected_proxies\tremote_connected_proxies\tsource_push_time_p99_ms\tremote_push_time_p99_ms\tstatus'
CDP_HDR=$'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms'
PROP_HDR=$'run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms'

# _base <suite> <dir>: a base dir with sweep-r1 .. sweep-r3, one TSV each of <suite>, and
# their records: r1 finished clean, r2 not finished, r3 finished with a PROBLEM. Prints the
# report's path.
_base() {
	local suite="$1" d="$2" n f hdr rowv rep
	for n in 1 2 3; do
		mkdir -p "${d}/sweep-r${n}"
		case "$suite" in
		dataplane) f="latency-r${n}.tsv" hdr="$DP_HDR" rowv=$'\t2\tci-a\tci-a\t10\t10\t8\t30\t2.0\t2.5\t5.0\t11.0\t12.5\tOK\t1\t0\tlocal' ;;
		churn) f="churn-r${n}.tsv" hdr="$CHURN_HDR" rowv=$'\t2\t5\t1\t5\t1\t0\t1000\t2000\t300\t10\t20\t100\t200\t99\tN/A\t50\t60\t10\tN/A\tOK' ;;
		churn-dataplane) f="churn-dataplane-r${n}.tsv" hdr="$CDP_HDR" rowv=$'\th1\tc1\t2\t0\tbaseline\t60\t50\t50\t2\t3\t5\t6\t7\tN/A\t0\tOK\t10\t10\t100\tN/A\t5\tN/A\tN/A\tN/A' ;;
		propagation) f="endpoint-r${n}.tsv" hdr="$PROP_HDR" rowv=$'\t2\t1\tci-a\tci-b\t0\t1000\t500\t3000\tOK\t100\t100\t40/40\t40\t0\t0\t0\t5000\t10' ;;
		esac
		printf '# RUN_ID=r%s\n# HARNESS_SHA=h1\n%s\nr%s%s\n' "$n" "$hdr" "$n" "$rowv" > "${d}/sweep-r${n}/${f}"
	done
	printf 'RUN_ID=r1\nEXIT=0\nFAILED=0\n' > "${d}/sweep-r1/sweep-outcome.txt"
	printf 'RUN_ID=r2\nEXIT=unfinished\nSTARTED_AT=2026-01-01T00:00:00Z\n' > "${d}/sweep-r2/sweep-outcome.txt"
	printf 'RUN_ID=r3\nEXIT=4\nFAILED=0\nPROBLEM=one\n' > "${d}/sweep-r3/sweep-outcome.txt"
	case "$suite" in
	dataplane | churn) rep=004-report-results.sh ;;
	*) rep=005-report-results.sh ;;
	esac
	echo "${ROOT}/tests/${suite}/${rep}"
}

@test "a pooled report, or one of a sweep from its parent dir, warns on stderr once, naming each sweep record below the results dir that did not end cleanly; none when they all did" {
	local suite d rep fmt w="warning: sweep records below "
	local both="sweep-r2/sweep-outcome.txt: has not finished (it died, or still runs); sweep-r3/sweep-outcome.txt: 1 PROBLEM(s)"
	for suite in dataplane churn churn-dataplane propagation; do
		d="${BATS_TEST_TMPDIR}/${suite}"
		rep="$(_base "$suite" "$d")"
		for fmt in text csv; do
			run --separate-stderr "$rep" --results-dir "$d" --allow-multi-run --format "$fmt"
			assert_success
			[ "$(grep -c "^${w}" <<<"$stderr")" -eq 1 ] || { echo "${suite} ${fmt}: ${stderr}"; false; }
			grep -qxF "${w}${d} that did not end cleanly: ${both}; report each sweep dir alone to see its outcome" <<<"$stderr" \
				|| { echo "${suite} ${fmt}: ${stderr}"; false; }
		done
		# One sweep reported from its parent dir.
		rm -rf "${d}/sweep-r1" "${d}/sweep-r3"
		run --separate-stderr "$rep" --results-dir "$d" --format text
		assert_success
		grep -qxF "${w}${d} that did not end cleanly: sweep-r2/sweep-outcome.txt: has not finished (it died, or still runs); report each sweep dir alone to see its outcome" <<<"$stderr" \
			|| { echo "${suite}: ${stderr}"; false; }
		# It ended cleanly: no warning.
		printf 'RUN_ID=r2\nEXIT=0\nFAILED=0\n' > "${d}/sweep-r2/sweep-outcome.txt"
		run --separate-stderr "$rep" --results-dir "$d" --format text
		assert_success
		[[ "$stderr" != *"$w"* ]] || { echo "${suite}: ${stderr}"; false; }
	done
}

#!/usr/bin/env bats
# A pooled report (--allow-multi-run over a base dir of sweep-* dirs) names each pooled
# sweep whose sweep-outcome.txt has not finished, was interrupted, stopped early or records
# a PROBLEM (sweep_outcome_pooled over sweep_outcome_brief, tests/lib/common.sh), in its
# pooled note (text, md, charts, csv) and in json pooled_sweep_outcomes, and keeps the
# advice to report each sweep alone: dataplane 004, churn 004 (no json), churn-dataplane
# 005 and propagation 005, through their real entrypoints (PL33). A clean sweep is not
# named; nor is the results dir's own record, which the report repeats itself. A report of
# one sweep from its parent dir (no record of its own) names that sweep's record the same
# way. Harness values are made up.

bats_require_minimum_version 1.5.0
load test_helper

ADVICE="never that of a sweep-* dir below it: report each sweep alone to see its failed cells, problems and notes."
DP_HDR=$'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class'
CHURN_HDR=$'run_id\tmesh_size\tchurn_intensity\tbase_replicas\tscale_to\titeration\tt0_epoch_ns\tconvergence_local_ms\tremote_endpoint_reachable_ms\tconvergence_remote_eds_ms\tsource_push_triggers_delta\tremote_push_triggers_delta\tsource_xds_pushes_delta\tremote_xds_pushes_delta\tsource_queue_time_p99_ms\tremote_queue_time_p99_ms\tsource_connected_proxies\tremote_connected_proxies\tsource_push_time_p99_ms\tremote_push_time_p99_ms\tstatus'
CDP_HDR=$'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms'
PROP_HDR=$'run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms'
# The names each format must carry, joined as the pooled note joins them.
LIST="sweep-r2/sweep-outcome.txt: has not finished (it died, or still runs); sweep-r3/sweep-outcome.txt: was interrupted before it wrote its outcome, with 1 PROBLEM(s); sweep-r4/sweep-outcome.txt: stopped early; sweep-r5/sweep-outcome.txt: 2 PROBLEM(s)"

# _base <suite> <dir>: a base dir with sweep-r1 .. sweep-r5, one TSV each of <suite>, and
# their records: r1 finished clean, r2 not finished, r3 interrupted with a PROBLEM, r4
# stopped early, r5 finished with two PROBLEMs. Prints the report's path.
_base() {
	local suite="$1" d="$2" n f hdr rowv rep
	for n in 1 2 3 4 5; do
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
	printf 'RUN_ID=r3\nEXIT=unfinished\nSTARTED_AT=2026-01-01T00:00:00Z\nENDED_AT=2026-01-01T01:00:00Z\nPROBLEM=a problem\n' > "${d}/sweep-r3/sweep-outcome.txt"
	printf 'RUN_ID=r4\nEXIT=1\nFAILED=0\nSTOPPED=1\nCUT_SHORT=1\n' > "${d}/sweep-r4/sweep-outcome.txt"
	printf 'RUN_ID=r5\nEXIT=4\nFAILED=0\nPROBLEM=one\nPROBLEM=two\n' > "${d}/sweep-r5/sweep-outcome.txt"
	case "$suite" in
	dataplane | churn) rep=004-report-results.sh ;;
	*) rep=005-report-results.sh ;;
	esac
	echo "${ROOT}/tests/${suite}/${rep}"
}

@test "a pooled report names each pooled sweep record that did not end cleanly, in every format its pooled note is in, and json pooled_sweep_outcomes" {
	local suite d rep fmt
	for suite in dataplane churn churn-dataplane propagation; do
		d="${BATS_TEST_TMPDIR}/${suite}"
		rep="$(_base "$suite" "$d")"
		for fmt in text md charts; do
			run --separate-stderr "$rep" --results-dir "$d" --allow-multi-run --format "$fmt"
			assert_success
			[[ "$output" == *"${ADVICE} Pooled sweep records that did not end cleanly: ${LIST}."* ]] \
				|| { echo "${suite} ${fmt}: ${output}"; false; }
			refute_output --partial "sweep-r1/sweep-outcome.txt"
		done
		run --separate-stderr "$rep" --results-dir "$d" --allow-multi-run --format csv
		assert_success
		assert_line "# NOTE: This report repeats only the results dir's own sweep-outcome.txt, when it has one, ${ADVICE} Pooled sweep records that did not end cleanly: ${LIST}."
		[[ "$suite" != churn ]] || continue
		run --separate-stderr "$rep" --results-dir "$d" --allow-multi-run --format json
		assert_success
		[ "$(jq -r '.pooled_sweep_outcomes | join("; ")' <<<"$output")" = "$LIST" ] || { echo "${suite}: ${output}"; false; }
		[ "$(jq -r '.pooled_runs.runs' <<<"$output")" = 5 ]
	done
}

@test "a pooled report whose sweeps all ended cleanly names none, and its json pooled_sweep_outcomes is []; a report of one run has [] too" {
	local suite d rep
	for suite in dataplane churn-dataplane propagation; do
		d="${BATS_TEST_TMPDIR}/${suite}"
		rep="$(_base "$suite" "$d")"
		rm -rf "${d}/sweep-r2" "${d}/sweep-r3" "${d}/sweep-r4" "${d}/sweep-r5/sweep-outcome.txt"
		run --separate-stderr "$rep" --results-dir "$d" --allow-multi-run --format text
		assert_success
		assert_output --partial "$ADVICE"
		refute_output --partial "Pooled sweep records that did not end cleanly"
		run --separate-stderr "$rep" --results-dir "$d" --allow-multi-run --format json
		assert_success
		[ "$(jq -c '.pooled_sweep_outcomes' <<<"$output")" = '[]' ]
		run --separate-stderr "$rep" --results-dir "${d}/sweep-r1" --format json
		assert_success
		[ "$(jq -c '[.pooled_runs.runs, .pooled_sweep_outcomes]' <<<"$output")" = '[1,[]]' ]
	done
}

@test "a report on the parent dir of one sweep (no sweep-outcome.txt of its own) names that sweep's record when it did not end cleanly, in every format, with the advice to report the sweep dir; not when the results dir has its own record or the sweep ended cleanly" {
	local suite d rep fmt
	local one="This report repeats only the results dir's own sweep-outcome.txt, and it has none: report the sweep-* dir below it to see its failed cells, problems and notes. Sweep records below the results dir that did not end cleanly: sweep-r2/sweep-outcome.txt: has not finished (it died, or still runs)."
	for suite in dataplane churn churn-dataplane propagation; do
		d="${BATS_TEST_TMPDIR}/${suite}"
		rep="$(_base "$suite" "$d")"
		rm -rf "${d}/sweep-r1" "${d}/sweep-r3" "${d}/sweep-r4" "${d}/sweep-r5"
		for fmt in text md charts; do
			run --separate-stderr "$rep" --results-dir "$d" --format "$fmt"
			assert_success
			assert_output --partial "$one"
			refute_output --partial "This report pools"
		done
		run --separate-stderr "$rep" --results-dir "$d" --format csv
		assert_success
		assert_line "# NOTE: ${one}"
		if [[ "$suite" != churn ]]; then
			run --separate-stderr "$rep" --results-dir "$d" --format json
			assert_success
			[ "$(jq -c '[.pooled_runs.runs, .pooled_sweep_outcomes]' <<<"$output")" = '[1,["sweep-r2/sweep-outcome.txt: has not finished (it died, or still runs)"]]' ] \
				|| { echo "${suite}: ${output}"; false; }
		fi
		# A record of its own: the report repeats that one, and names none below it.
		printf 'RUN_ID=r2\nEXIT=0\nFAILED=0\n' > "${d}/sweep-outcome.txt"
		run --separate-stderr "$rep" --results-dir "$d" --format text
		assert_success
		refute_output --partial "Sweep records below the results dir"
		rm "${d}/sweep-outcome.txt"
		# The sweep ended cleanly: nothing to name.
		printf 'RUN_ID=r2\nEXIT=0\nFAILED=0\n' > "${d}/sweep-r2/sweep-outcome.txt"
		run --separate-stderr "$rep" --results-dir "$d" --format text
		assert_success
		refute_output --partial "Sweep records below the results dir"
	done
}

@test "sweep_outcome_pooled: paths relative to the results dir however it is spelled (trailing slashes, ./), each dir once, the results dir's own record and non-sweep dirs left out" {
	local d="${BATS_TEST_TMPDIR}/base" top out
	local -a files
	source "${ROOT}/tests/lib/common.sh"
	mkdir -p "${d}/sweep-a" "${d}/sweep-b" "${d}/other" "${d}/sweep-a/sub"
	printf 'EXIT=unfinished\n' > "${d}/sweep-a/sweep-outcome.txt"
	printf 'EXIT=0\nPROBLEM=x\n' > "${d}/sweep-b/sweep-outcome.txt"
	printf 'EXIT=unfinished\n' > "${d}/other/sweep-outcome.txt"
	printf 'EXIT=unfinished\n' > "${d}/sweep-outcome.txt"
	touch "${d}/sweep-a/x.tsv" "${d}/sweep-a/y.tsv" "${d}/sweep-b/z.tsv" "${d}/other/o.tsv" "${d}/top.tsv" "${d}/sweep-a/sub/s.tsv"
	for top in "$d" "${d}/" "${d}//"; do
		mapfile -t files < <(find -H "$top" -name '*.tsv' -type f | sort)
		out="$(sweep_outcome_pooled "$top" "${files[@]}")"
		[ "$out" = $'sweep-a/sweep-outcome.txt: has not finished (it died, or still runs)\nsweep-b/sweep-outcome.txt: 1 PROBLEM(s)' ] \
			|| { echo "${top}: ${out}"; false; }
	done
	cd "$d"
	mapfile -t files < <(find -H . -name '*.tsv' -type f | sort)
	[ "$(sweep_outcome_pooled . "${files[@]}" | cut -d: -f1 | paste -sd,)" = "sweep-a/sweep-outcome.txt,sweep-b/sweep-outcome.txt" ]
	# The results dir itself a sweep-* dir: its own record is the report's to repeat.
	[ -z "$(sweep_outcome_pooled "${d}/sweep-a" "${d}/sweep-a/x.tsv")" ]
	[ -z "$(sweep_outcome_pooled "${d}/sweep-a/" "${d}/sweep-a/x.tsv")" ]
}

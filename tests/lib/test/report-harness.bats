#!/usr/bin/env bats
# REPORT_HARNESS_SHA of the controlplane, dataplane, churn, churn-dataplane, propagation and
# tuning reports, through each real entrypoint (PL33) in a scratch git checkout: a results dir
# inside the checkout (untracked, not ignored) is the report's own input, so it never
# reads as a harness change; any other untracked file still does. Contexts are
# placeholders (ci-a, ci-b).

bats_require_minimum_version 1.5.0
load test_helper

# _checkout: a git checkout at C of this harness's config/ and tests/ scripts, one commit,
# no .gitignore (so nothing under tests/ is ignored). Git reads no global or system config.
_checkout() {
	C="${BATS_TEST_TMPDIR}/co"
	local s
	mkdir -p "$C/config" "$C/tests/lib"
	cp "$ROOT"/config/*.env "$C/config/"
	cp "$ROOT"/tests/lib/*.sh "$C/tests/lib/"
	for s in controlplane dataplane churn churn-dataplane propagation tuning; do
		mkdir -p "$C/tests/$s"
		cp "$ROOT/tests/$s/"*.sh "$C/tests/$s/"
	done
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
	git -C "$C" init -q
	git -C "$C" add -A
	git -C "$C" -c user.name=ci -c user.email=ci@example.com commit -q -m base
	SHA="$(git -C "$C" describe --always --abbrev=7)"
}

# _fixture <suite>: that report's input under tests/<suite>/campaign/ in the checkout
# (one suite at a time: another suite's results would be a change to this report's harness).
_fixture() {
	local d="$C/tests" prop_hdr prop_row
	prop_hdr='run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms\n'
	prop_row='r1\t2\t1\tci-a\tci-b\t0\t1000\t500\t3000\tOK\t100\t100\t40/40\t40\t0\t0\t0\t5000\t10\n'
	case "$1" in
	controlplane)
		mkdir -p "$d/controlplane/campaign/r1"
		cp "$ROOT/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv" "$d/controlplane/campaign/r1/controlplane-r1.tsv"
		;;
	dataplane)
		mkdir -p "$d/dataplane/campaign/r1"
		{
			echo "# RUN_ID=r1"
			printf 'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class\n'
			printf 'r1\t2\tci-a\tci-a\t10\t10\t8\t30\t2.0\t2.5\t5.0\t11.0\t12.5\tOK\t1\t0\tlocal\n'
		} > "$d/dataplane/campaign/r1/latency-a.tsv"
		;;
	churn)
		mkdir -p "$d/churn/campaign/r1"
		{
			echo "# RUN_ID=r1"
			printf 'run_id\tmesh_size\tchurn_intensity\tbase_replicas\tscale_to\titeration\tt0_epoch_ns\tconvergence_local_ms\tremote_endpoint_reachable_ms\tconvergence_remote_eds_ms\tsource_push_triggers_delta\tremote_push_triggers_delta\tsource_xds_pushes_delta\tremote_xds_pushes_delta\tsource_queue_time_p99_ms\tremote_queue_time_p99_ms\tsource_connected_proxies\tremote_connected_proxies\tsource_push_time_p99_ms\tremote_push_time_p99_ms\tstatus\n'
			printf 'r1\t2\t5\t1\t5\t1\t0\t1000\t2000\t300\t10\t20\t100\t200\t99\tN/A\t50\t60\t10\tN/A\tOK\n'
		} > "$d/churn/campaign/r1/churn-a.tsv"
		;;
	churn-dataplane)
		mkdir -p "$d/churn-dataplane/campaign/r1"
		{
			echo "# RUN_ID=r1"
			printf 'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms\n'
			printf 'r1\tsha\tc1\t2\t0\tbaseline\t60\t50\t50\t2\t3\t5\t6\t7\tN/A\t0\tOK\t10\t10\t100\tN/A\t5\tN/A\tN/A\tN/A\n'
			printf 'r1\tsha\tc1\t2\t1\tchurn\t60\t50\t48\t4\t3\t9\t6\t7\tN/A\t0\tOK\t10\t10\t100\t30\t5\t99\tN/A\tN/A\n'
		} > "$d/churn-dataplane/campaign/r1/churn-dataplane-r1.tsv"
		;;
	propagation)
		mkdir -p "$d/propagation/campaign/r1"
		# shellcheck disable=SC2059  # the format strings are the fixture rows
		{ echo "# RUN_ID=r1"; printf "$prop_hdr"; printf "$prop_row"; } > "$d/propagation/campaign/r1/endpoint-r1.tsv"
		;;
	tuning)
		mkdir -p "$d/tuning/campaign/r1/baseline"
		printf '# SUITE=propagation\n# PASSES=baseline\n# HARNESS_SHA=abc1234\n' > "$d/tuning/campaign/r1/sweep-metadata.txt"
		# shellcheck disable=SC2059
		{ echo "# RUN_ID=r1"; printf "$prop_hdr"; printf "$prop_row"; } > "$d/tuning/campaign/r1/baseline/endpoint-r1.tsv"
		;;
	esac
}

# _report_sha <script> <results dir> [cwd]: GOT = the report_harness_sha (or
# REPORT_HARNESS_SHA) of its markdown frontmatter, run from cwd (default: the test's).
_report_sha() {
	local cwd="${3:-$PWD}"
	run --separate-stderr bash -c 'cd "$1" && shift && exec bash "$@"' _ "$cwd" "$C/tests/$1" --results-dir "$2" --format md
	assert_success
	GOT="$(awk 'NR == 1 && /^---$/ { f = 1; next } f && /^---$/ { exit }
		f && tolower($1) == "report_harness_sha:" { v = $2; gsub(/"/, "", v); print v }' <<<"$output")"
}

REPORTS=(controlplane/004-report-results.sh dataplane/004-report-results.sh churn/004-report-results.sh
	churn-dataplane/005-report-results.sh propagation/005-report-results.sh tuning/004-compare-profiles.sh)

@test "every report's REPORT_HARNESS_SHA leaves out the results dir it reads inside the checkout, and still sees any other change" {
	_checkout
	local script suite got
	for script in "${REPORTS[@]}"; do
		suite="${script%%/*}"
		_fixture "$suite"
		# The results are untracked and not ignored: without an exclude they dirty the harness.
		got="$(cd "$C" && ROOT="$C" bash -c 'source tests/lib/common.sh; harness_sha')"
		[[ "$got" == "${SHA}-dirty."* ]] || { echo "${suite}: the fixture does not dirty the checkout (${got})"; false; }
		_report_sha "$script" "$C/tests/${suite}/campaign/r1"
		[ "$GOT" = "$SHA" ] || { echo "${script}: REPORT_HARNESS_SHA ${GOT}, not ${SHA}"; false; }
		# A relative --results-dir, as typed from the repo root, is the same dir.
		_report_sha "$script" "tests/${suite}/campaign/r1" "$C"
		[ "$GOT" = "$SHA" ] || { echo "${script} (relative dir): REPORT_HARNESS_SHA ${GOT}, not ${SHA}"; false; }
		# Any other untracked file is a harness change.
		printf 'x\n' > "$C/tests/lib/new-helper.sh"
		_report_sha "$script" "$C/tests/${suite}/campaign/r1"
		[[ "$GOT" == "${SHA}-dirty."* ]] || { echo "${script}: REPORT_HARNESS_SHA ${GOT} misses the change"; false; }
		rm -rf "$C/tests/lib/new-helper.sh" "$C/tests/${suite}/campaign"
	done
}

@test "the six reports' --help say what REPORT_HARNESS_SHA is and that the results dir does not count" {
	local s flat
	for s in "${REPORTS[@]}"; do
		run "${ROOT}/tests/${s}" --help
		assert_success
		flat="$(tr '\n' ' ' <<<"$output" | tr -s ' ')"
		[[ "$flat" == *"REPORT_HARNESS_SHA"*"harness this report ran on"* || "$flat" == *"report_harness_sha"*"harness this report ran on"* ]] \
			|| { echo "${s}: --help does not explain REPORT_HARNESS_SHA"; false; }
		[[ "$flat" == *"may count rows by other rules"* ]] || { echo "${s}: no reason given"; false; }
		[[ "$flat" == *"does not count as a change to it"* ]] || { echo "${s}: says nothing about the results dir"; false; }
	done
}

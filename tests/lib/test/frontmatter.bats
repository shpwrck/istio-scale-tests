#!/usr/bin/env bats
# The YAML frontmatter of the reports (PL19): yaml_str (tests/lib/common.sh), and through
# each report's real entrypoint (PL33) the markdown and charts frontmatter of churn 004,
# churn-dataplane 005, controlplane 004, dataplane 004 and propagation 005, with a value
# that holds a double quote and a backslash, parsed by python3 + PyYAML. gateway-api 001's
# summary is checked in gateway-api.bats (it runs on that file's stubs).

bats_require_minimum_version 1.5.0
load test_helper

# A value with a quote and a backslash, and what a plain YAML scalar would misread (": "
# and " #").
WEIRD='team "a"\b: #1.env'

# need_yaml: skip without python3 + PyYAML.
need_yaml() {
	python3 -I -c 'import yaml' 2>/dev/null || skip "python3 with PyYAML is needed"
}

# fm <file>: the file's frontmatter (between its first two --- lines) as JSON, parsed by
# PyYAML; fails when the file has none or it does not parse.
fm() {
	python3 -I -c '
import json, sys, yaml
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
if lines[0] != "---":
    sys.exit("no frontmatter")
end = lines.index("---", 1)
print(json.dumps(yaml.safe_load("\n".join(lines[1:end])), default=str))
' "$1"
}

@test "yaml_str: a quote and a backslash are escaped, control characters too; -n keeps a plain number bare; -v sets the variable" {
	run yaml_str 'a"b\c'
	assert_output '"a\"b\\c"'
	run yaml_str $'t\tn\nr\r\x01\x7f'
	assert_output '"t\tn\nr\r\x01\x7f"'
	run yaml_str ''
	assert_output '""'
	run yaml_str -n 12
	assert_output '12'
	run yaml_str -n 007
	assert_output '"007"'
	run yaml_str -n unknown
	assert_output '"unknown"'
	run yaml_str -n
	assert_output '"-n"'
	local v
	yaml_str -v v 'x"y'
	[ "$v" = '"x\"y"' ]
}

@test "yaml_str: every value reads back as itself through PyYAML, in the C and a UTF-8 locale" {
	need_yaml
	local loc out="${BATS_TEST_TMPDIR}/fm.md" vals="${BATS_TEST_TMPDIR}/vals"
	for loc in C C.UTF-8; do
		LC_ALL="$loc" bash -c '
			set -euo pipefail
			source "$1/tests/lib/common.sh"
			vals=("plain" "a\"b\\c" "$2" $'"'"'t\tn\nr\r'"'"' $'"'"'x\x01\x7fy'"'"' "ctx-é1" "" "-n" "# not a comment" ": x" "007")
			{
				echo "---"
				for i in "${!vals[@]}"; do yaml_str -v o "${vals[$i]}"; echo "k${i}: ${o}"; done
				echo "n: $(yaml_str -n 12)"
				echo "---"
			} > "$3"
			printf "%s\0" "${vals[@]}" > "$4"
		' _ "$ROOT" "$WEIRD" "$out" "$vals"
		python3 -I -c '
import sys, yaml
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
d = yaml.safe_load("\n".join(lines[1:lines.index("---", 1)]))
want = [v.decode("utf-8") for v in open(sys.argv[2], "rb").read().split(b"\0")[:-1]]
for i, v in enumerate(want):
    if d["k%d" % i] != v:
        sys.exit("%s: k%d reads %r, not %r" % (sys.argv[3], i, d["k%d" % i], v))
if d["n"] != 12:
    sys.exit("%s: n reads %r" % (sys.argv[3], d["n"]))
' "$out" "$vals" "$loc"
	done
}

@test "every report's markdown and charts frontmatter parses as YAML with a value that holds a quote and a backslash, and reads it back as written" {
	need_yaml
	local d="${BATS_TEST_TMPDIR}/r" r script sub key fmts f got
	mkdir -p "$d/dp" "$d/ch" "$d/cd" "$d/pr" "$d/cp"
	{
		echo "# RUN_ID=r1"
		printf '# RUN_CONFIG=%s\n' "$WEIRD"
		printf 'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class\n'
		printf 'r1\t2\tci-a\tci-a\t10\t10\t8\t30\t2.0\t2.5\t5.0\t11.0\t12.5\tOK\t1\t0\tlocal\n'
	} > "$d/dp/latency-a.tsv"
	{
		echo "# RUN_ID=r1"
		printf '# RUN_CONFIG=%s\n' "$WEIRD"
		printf 'run_id\tmesh_size\tchurn_intensity\tbase_replicas\tscale_to\titeration\tt0_epoch_ns\tconvergence_local_ms\tremote_endpoint_reachable_ms\tconvergence_remote_eds_ms\tsource_push_triggers_delta\tremote_push_triggers_delta\tsource_xds_pushes_delta\tremote_xds_pushes_delta\tsource_queue_time_p99_ms\tremote_queue_time_p99_ms\tsource_connected_proxies\tremote_connected_proxies\tsource_push_time_p99_ms\tremote_push_time_p99_ms\tstatus\n'
		printf 'r1\t2\t5\t1\t5\t1\t0\t1000\t2000\t300\t10\t20\t100\t200\t99\tN/A\t50\t60\t10\tN/A\tOK\n'
	} > "$d/ch/churn-a.tsv"
	{
		echo "# RUN_ID=r1"
		printf '# RUN_CONFIG=%s\n' "$WEIRD"
		printf 'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms\n'
		printf 'r1\tsha\tc1\t2\t0\tbaseline\t60\t50\t50\t2\t3\t5\t6\t7\tN/A\t0\tOK\t10\t10\t100\tN/A\t5\tN/A\tN/A\tN/A\n'
		printf 'r1\tsha\tc1\t2\t1\tchurn\t60\t50\t48\t4\t3\t9\t6\t7\tN/A\t0\tOK\t10\t10\t100\t30\t5\t99\tN/A\tN/A\n'
	} > "$d/cd/churn-dataplane-r1.tsv"
	{
		echo "# RUN_ID=r1"
		printf '# RUN_CONFIG=%s\n' "$WEIRD"
		printf 'run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms\n'
		printf 'r1\t2\t1\tsrc\trmt\t0\t1000\t500\t3000\tOK\t100\t100\t40/40\t40\t0\t0\t0\t5000\t10\n'
	} > "$d/pr/endpoint-r1.tsv"
	W="$WEIRD" awk 'NR == 2 { print "# RUN_CONFIG=" ENVIRON["W"] } { print }' \
		"${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv" > "$d/cp/controlplane-fixture-t2.tsv"
	# <script> <dir> <key that holds RUN_CONFIG, or - when the frontmatter keeps it in a
	# comment> <formats>: churn-dataplane's markdown has no frontmatter, its charts keep the
	# preamble as ## comments.
	for r in "dataplane/004-report-results.sh dp RUN_CONFIG md,charts" \
		"churn/004-report-results.sh ch run_config md,charts" \
		"propagation/005-report-results.sh pr RUN_CONFIG md,charts" \
		"controlplane/004-report-results.sh cp run_config md,charts" \
		"churn-dataplane/005-report-results.sh cd - charts"; do
		read -r script sub key fmts <<<"$r"
		for f in ${fmts//,/ }; do
			run --separate-stderr bash "${ROOT}/tests/${script}" --results-dir "$d/$sub" --format "$f"
			assert_success
			printf '%s\n' "$output" > "$d/out.md"
			got="$(fm "$d/out.md")" || { echo "${script} --format ${f}: the frontmatter does not parse"; false; }
			[[ "$key" == - ]] || [ "$(jq -r --arg k "$key" '.[$k]' <<<"$got")" = "$WEIRD" ] || {
				echo "${script} --format ${f}: ${key} reads $(jq -c --arg k "$key" '.[$k]' <<<"$got")"
				false
			}
		done
	done
}

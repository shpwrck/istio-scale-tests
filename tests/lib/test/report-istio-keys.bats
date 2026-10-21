#!/usr/bin/env bats
# The sweep-level Istio keys in the multi-input reports (PL26): ISTIO_ACTIVE_REVISIONS and
# ISTIO_PROXY_VERSIONS in propagation 005, churn 004, churn-dataplane 005 and tuning 004,
# and ISTIO_GENERATIONS in every report: inputs that differ read mixed, an input without
# the key reads unknown. Names are placeholders (ci-a).

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr
source "${ROOT}/tests/lib/timestamp.sh"
source "${ROOT}/tests/lib/metrics.sh"
source "${ROOT}/tests/lib/fanout.sh"
source "${ROOT}/tests/lib/config.sh"

PROP_HDR=$'run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms'
CHURN_HDR=$'run_id\tmesh_size\tchurn_intensity\tbase_replicas\tscale_to\titeration\tt0_epoch_ns\tconvergence_local_ms\tremote_endpoint_reachable_ms\tconvergence_remote_eds_ms\tsource_push_triggers_delta\tremote_push_triggers_delta\tsource_xds_pushes_delta\tremote_xds_pushes_delta\tsource_queue_time_p99_ms\tremote_queue_time_p99_ms\tsource_connected_proxies\tremote_connected_proxies\tsource_push_time_p99_ms\tremote_push_time_p99_ms\tstatus'
CD_HDR=$'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms'

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
	KC="${BATS_TEST_TMPDIR}/empty.kubeconfig"
	: > "$KC"
	export TMPDIR="$BATS_TEST_TMPDIR"
}

REV_A="ci-a=default,ci-b=default"
REV_B="ci-a=canary,ci-b=default"
PV_A="ci-a=1.30.5:12,ci-b=1.30.5:10"
PV_B="ci-a=1.30.4:12,ci-b=1.30.5:10"

# keys <revisions> <proxy versions>: the two preamble lines.
keys() { printf '# ISTIO_ACTIVE_REVISIONS=%s\n# ISTIO_PROXY_VERSIONS=%s\n' "$1" "$2"; }

TUNING_CMP="${ROOT}/tests/tuning/004-compare-profiles.sh"
DP_HDR=$'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class'
GEN_A="ci-a=2/2,ci-b=3/2"
GEN_B="ci-a=4/2,ci-b=3/2"

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

@test "propagation 005 prints both keys in every format; differing inputs read mixed; an older TSV reads unknown" {
	prow() { printf '%s\t2\t1\tsrc\trmt\t0\t100\t500\t3000\tOK\t100\t100\t40/40\t40\t0\t0\t0\t5000\t10\n' "$1"; }
	mkdir -p "${RES}/one" "${RES}/two" "${RES}/old"
	{ echo "# RUN_ID=r1"; keys "$REV_A" "$PV_A"; platform_fixture_lines src,rmt; echo "$PROP_HDR"; prow r1; } > "${RES}/one/endpoint-r1.tsv"
	cp "${RES}/one/endpoint-r1.tsv" "${RES}/two/"
	{ echo "# RUN_ID=r2"; keys "$REV_B" "$PV_B"; platform_fixture_lines src,rmt; echo "$PROP_HDR"; prow r2; } > "${RES}/two/endpoint-r2.tsv"
	{ echo "# RUN_ID=r3"; echo "$PROP_HDR"; prow r3; } > "${RES}/old/endpoint-r3.tsv"
	local R="${ROOT}/tests/propagation/005-report-results.sh"
	run "$R" --results-dir "${RES}/one"
	assert_line "  ISTIO_ACTIVE_REVISIONS: ${REV_A}"
	assert_line "  ISTIO_PROXY_VERSIONS: ${PV_A}"
	run "$R" --results-dir "${RES}/one" --format csv
	assert_line "# ISTIO_ACTIVE_REVISIONS=${REV_A}"
	assert_line "# ISTIO_PROXY_VERSIONS=${PV_A}"
	run "$R" --results-dir "${RES}/one" --format md
	assert_line "ISTIO_PROXY_VERSIONS: \"${PV_A}\""
	run "$R" --results-dir "${RES}/one" --format charts
	assert_line "ISTIO_ACTIVE_REVISIONS: \"${REV_A}\""
	run "$R" --results-dir "${RES}/one" --format json
	[ "$(jq -r '.metadata.ISTIO_ACTIVE_REVISIONS + " " + .metadata.ISTIO_PROXY_VERSIONS' <<<"$output")" = "${REV_A} ${PV_A}" ]
	run --separate-stderr "$R" --results-dir "${RES}/two" --allow-multi-run --format json
	[ "$(jq -r '.metadata.ISTIO_PROXY_VERSIONS' <<<"$output")" = "mixed:${PV_A} | ${PV_B}" ]
	[[ "$stderr" == *"disagree on sweep-level ISTIO_ACTIVE_REVISIONS"* ]]
	run "$R" --results-dir "${RES}/two" --allow-multi-run --format md
	assert_line "ISTIO_ACTIVE_REVISIONS: \"mixed:${REV_A} | ${REV_B}\""
	run "$R" --results-dir "${RES}/old" --format csv
	assert_line "# ISTIO_ACTIVE_REVISIONS=unknown"
	assert_line "# ISTIO_PROXY_VERSIONS=unknown"
	run "$R" --results-dir "${RES}/old"
	assert_line "  ISTIO_PROXY_VERSIONS: unknown"
}

@test "churn 004 prints both keys in text, csv, md and charts; mixed and unknown as well" {
	crow() { printf '%s\t2\t5\t1\t5\t1\t0\t1000\t2000\t300\t10\t20\t100\t200\t99\t99\t50\t60\t10\t10\tOK\n' "$1"; }
	mkdir -p "${RES}/two" "${RES}/old"
	{ echo "# RUN_ID=r1"; keys "$REV_A" "$PV_A"; echo "$CHURN_HDR"; crow r1; } > "${RES}/two/churn-r1.tsv"
	{ echo "# RUN_ID=r2"; keys "$REV_B" "$PV_B"; echo "$CHURN_HDR"; crow r2; } > "${RES}/two/churn-r2.tsv"
	{ echo "# RUN_ID=r3"; echo "$CHURN_HDR"; crow r3; } > "${RES}/old/churn-r3.tsv"
	local R="${ROOT}/tests/churn/004-report-results.sh"
	run "$R" --results-dir "${RES}/two" --allow-multi-run
	assert_line "# istio_active_revisions: mixed:${REV_A} | ${REV_B}"
	assert_line "# istio_proxy_versions: mixed:${PV_A} | ${PV_B}"
	run "$R" --results-dir "${RES}/two" --allow-multi-run --format csv
	assert_line "# ISTIO_PROXY_VERSIONS=mixed:${PV_A} | ${PV_B}"
	run "$R" --results-dir "${RES}/two" --allow-multi-run --format md
	assert_line "istio_active_revisions: \"mixed:${REV_A} | ${REV_B}\""
	run "$R" --results-dir "${RES}/two" --allow-multi-run --format charts
	assert_line "istio_proxy_versions: \"mixed:${PV_A} | ${PV_B}\""
	run "$R" --results-dir "${RES}/old" --format csv
	assert_line "# ISTIO_ACTIVE_REVISIONS=unknown (not recorded)"
	assert_line "# ISTIO_PROXY_VERSIONS=unknown (not recorded)"
	run "$R" --results-dir "${RES}/old" --format md
	assert_line "istio_proxy_versions: \"unknown (not recorded)\""
}

@test "churn-dataplane 005 prints both keys in every format, md cells escaped; mixed and unknown as well" {
	drow() { printf '%s\tsha\tc1\t2\t%s\t%s\t60\t50\t48\t4\t3\t9\t6\t7\tN/A\t0\tOK\t10\t10\t100\t30\t5\t99\tN/A\tN/A\n' "$1" "$2" "$3"; }
	mkdir -p "${RES}/two" "${RES}/old"
	{ echo "# RUN_ID=r1"; keys "$REV_A" "$PV_A"; platform_fixture_lines; echo "$CD_HDR"; drow r1 0 baseline; drow r1 1 churn; } > "${RES}/two/churn-dataplane-r1.tsv"
	{ echo "# RUN_ID=r2"; keys "$REV_B" "$PV_B"; platform_fixture_lines; echo "$CD_HDR"; drow r2 0 baseline; drow r2 1 churn; } > "${RES}/two/churn-dataplane-r2.tsv"
	{ echo "# RUN_ID=r3"; echo "$CD_HDR"; drow r3 0 baseline; drow r3 1 churn; } > "${RES}/old/churn-dataplane-r3.tsv"
	local R="${ROOT}/tests/churn-dataplane/005-report-results.sh" fmt
	for fmt in text csv; do
		run "$R" --results-dir "${RES}/two" --allow-multi-run --format "$fmt"
		assert_output --partial "ISTIO_ACTIVE_REVISIONS=mixed:${REV_A} | ${REV_B}"
		assert_output --partial "ISTIO_PROXY_VERSIONS=mixed:${PV_A} | ${PV_B}"
		run "$R" --results-dir "${RES}/old" --format "$fmt"
		assert_output --partial "ISTIO_ACTIVE_REVISIONS=unknown"
		assert_output --partial "ISTIO_PROXY_VERSIONS=unknown"
	done
	# charts (and md): YAML frontmatter keys, lowercase as in the json metadata.
	run "$R" --results-dir "${RES}/two" --allow-multi-run --format charts
	assert_line "istio_active_revisions: \"mixed:${REV_A} | ${REV_B}\""
	assert_line "istio_proxy_versions: \"mixed:${PV_A} | ${PV_B}\""
	run "$R" --results-dir "${RES}/old" --format charts
	assert_line 'istio_active_revisions: "unknown"'
	assert_line 'istio_proxy_versions: "unknown"'
	run "$R" --results-dir "${RES}/two" --allow-multi-run --format md
	assert_line "| ISTIO_PROXY_VERSIONS | \`mixed:${PV_A} \\| ${PV_B}\` |"
	run --separate-stderr "$R" --results-dir "${RES}/two" --allow-multi-run --format json
	[ "$(jq -r '.metadata.istio_active_revisions' <<<"$output")" = "mixed:${REV_A} | ${REV_B}" ]
	# (It predates the platform record too: a warning on stderr.)
	run --separate-stderr "$R" --results-dir "${RES}/old" --format json
	[ "$(jq -r '.metadata.istio_proxy_versions' <<<"$output")" = unknown ]
}

@test "tuning 004 prints both keys over every pass, in md and text; mixed and unknown as well" {
	P="${BATS_TEST_TMPDIR}/psweep"
	mkdir -p "${P}/baseline" "${P}/01-x"
	# sweep-metadata.txt records the keys at the sweep's start, as 003 writes it.
	{ printf '# SUITE=propagation\n# PASSES=baseline,01-x\n'; keys "$REV_A" "$PV_A"; } > "${P}/sweep-metadata.txt"
	prow() { printf '%s\t2\t1\tsrc\tb\t0\t100\t50\t60\tOK\t99\t99\t10/10\t10\t0\t0\t0\t5000\t10\n' "$1"; }
	{ echo "# RUN_ID=r1"; keys "$REV_A" "$PV_A"; echo "$PROP_HDR"; prow r1; } > "${P}/baseline/endpoint-r1.tsv"
	{ echo "# RUN_ID=r2"; keys "$REV_A" "$PV_B"; echo "$PROP_HDR"; prow r2; } > "${P}/01-x/endpoint-r2.tsv"
	local R="${ROOT}/tests/tuning/004-compare-profiles.sh"
	run "$R" --results-dir "$P" --format md
	# ISTIO_GENERATIONS: no input records it here, so unknown.
	assert_line "- Active revisions, Istio CR generations and proxy versions at the start: ISTIO_ACTIVE_REVISIONS=${REV_A}; ISTIO_GENERATIONS=unknown; ISTIO_PROXY_VERSIONS=mixed:${PV_A} | ${PV_B}"
	run "$R" --results-dir "$P"
	assert_line "Active revisions, Istio CR generations and proxy versions at the start: ISTIO_ACTIVE_REVISIONS=${REV_A}; ISTIO_GENERATIONS=unknown; ISTIO_PROXY_VERSIONS=mixed:${PV_A} | ${PV_B}"
	sed -i.bak '/^# ISTIO_ACTIVE_REVISIONS=/d; /^# ISTIO_PROXY_VERSIONS=/d' "${P}/sweep-metadata.txt" "${P}/baseline/endpoint-r1.tsv" "${P}/01-x/endpoint-r2.tsv"
	run "$R" --results-dir "$P" --format md
	assert_line "- Active revisions, Istio CR generations and proxy versions at the start: ISTIO_ACTIVE_REVISIONS=unknown; ISTIO_GENERATIONS=unknown; ISTIO_PROXY_VERSIONS=unknown"
}

@test "ISTIO_GENERATIONS is sweep-level in every multi-input report: inputs that differ read mixed, an input without it reads unknown" {
	local s rep fmt mixed half
	for s in propagation dataplane churn churn-dataplane controlplane; do
		case "$s" in propagation | churn-dataplane) rep="${ROOT}/tests/${s}/005-report-results.sh" ;; *) rep="${ROOT}/tests/${s}/004-report-results.sh" ;; esac
		_gen_tsv "$s" "${RES}/${s}/two" r1 "$GEN_A"
		_gen_tsv "$s" "${RES}/${s}/two" r2 "$GEN_B"
		_gen_tsv "$s" "${RES}/${s}/half" r1 "$GEN_A"
		_gen_tsv "$s" "${RES}/${s}/half" r2 -
		_gen_tsv "$s" "${RES}/${s}/none" r1 -
		# churn records a missing key as "unknown (not recorded)".
		half="unknown"
		[[ "$s" != churn ]] || half="unknown (not recorded)"
		for fmt in text md; do
			run --separate-stderr "$rep" --results-dir "${RES}/${s}/two" --allow-multi-run --format "$fmt"
			assert_success
			[[ "$output" =~ [Ii][Ss][Tt][Ii][Oo]_[Gg][Ee][Nn][Ee][Rr][Aa][Tt][Ii][Oo][Nn][Ss][^$'\n']*"mixed:${GEN_A} "('|'|'\|')" ${GEN_B}" ]] \
				|| { echo "${s} ${fmt} (two): ${output}"; false; }
			run --separate-stderr "$rep" --results-dir "${RES}/${s}/half" --allow-multi-run --format "$fmt"
			[[ "$output" =~ [Ii][Ss][Tt][Ii][Oo]_[Gg][Ee][Nn][Ee][Rr][Aa][Tt][Ii][Oo][Nn][Ss][^$'\n']*"mixed:${GEN_A} "('|'|'\|')" ${half}" ]] \
				|| { echo "${s} ${fmt} (half): ${output}"; false; }
			run --separate-stderr "$rep" --results-dir "${RES}/${s}/none" --format "$fmt"
			[[ "$output" =~ [Ii][Ss][Tt][Ii][Oo]_[Gg][Ee][Nn][Ee][Rr][Aa][Tt][Ii][Oo][Nn][Ss]('='|': '|': "'|' | `')"${half}" ]] \
				|| { echo "${s} ${fmt} (none): ${output}"; false; }
		done
	done
	# tuning 004: over sweep-metadata.txt and every pass's TSVs.
	local P="${BATS_TEST_TMPDIR}/psweep"
	mkdir -p "${P}/baseline" "${P}/01-x"
	{ printf '# SUITE=propagation\n# PASSES=baseline,01-x\n'; echo "# ISTIO_GENERATIONS=${GEN_A}"; } > "${P}/sweep-metadata.txt"
	_gen_tsv propagation "${P}/baseline" r1 "$GEN_A"
	_gen_tsv propagation "${P}/01-x" r2 "$GEN_B"
	run "$TUNING_CMP" --results-dir "$P" --format md
	assert_success
	assert_output --partial "ISTIO_GENERATIONS=mixed:${GEN_A} | ${GEN_B};"
	_gen_tsv propagation "${P}/01-x" r2 -
	run "$TUNING_CMP" --results-dir "$P"
	assert_output --partial "ISTIO_GENERATIONS=mixed:${GEN_A} | unknown;"
}

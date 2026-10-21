#!/usr/bin/env bats
# The per-member Istio keys every report carries (PL26): ISTIO_ACTIVE_REVISIONS and
# ISTIO_GENERATIONS are sweep-level, so inputs that differ read mixed and an input without
# them (written before them) mixes in as unknown, never as the other inputs' value. Names
# are placeholders (ci-a).

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr

CHURN_HDR=$'run_id\tmesh_size\tchurn_intensity\tbase_replicas\tscale_to\titeration\tt0_epoch_ns\tconvergence_local_ms\tremote_endpoint_reachable_ms\tconvergence_remote_eds_ms\tsource_push_triggers_delta\tremote_push_triggers_delta\tsource_xds_pushes_delta\tremote_xds_pushes_delta\tsource_queue_time_p99_ms\tremote_queue_time_p99_ms\tsource_connected_proxies\tremote_connected_proxies\tsource_push_time_p99_ms\tremote_push_time_p99_ms\tstatus'
CD_HDR=$'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms'
DP_HDR=$'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class'
REV_A="ci-a=default,ci-b=default"
REV_B="ci-a=canary,ci-b=default"
GEN_A="ci-a=2/2,ci-b=3/2"
GEN_B="ci-a=4/2,ci-b=3/2"

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
	export TMPDIR="$BATS_TEST_TMPDIR"
}

# _tsv <suite> <dir> <run_id> <revisions|-> <generations|->: one input of the suite's
# report, with `# ISTIO_ACTIVE_REVISIONS=` and `# ISTIO_GENERATIONS=` (none for -).
_tsv() {
	local s="$1" d="$2" id="$3" kv=""
	mkdir -p "$d"
	[[ "$4" == - ]] || kv+="# ISTIO_ACTIVE_REVISIONS=${4}"$'\n'
	[[ "$5" == - ]] || kv+="# ISTIO_GENERATIONS=${5}"$'\n'
	case "$s" in
	propagation)
		source "${ROOT}/tests/lib/propagation.sh"
		{ echo "# RUN_ID=${id}"; printf '%s' "$kv"; echo "$PROP_TSV_HEADER"; prop_placeholder_row "$id" 2 ci-a SETUP_FAILED; } > "${d}/endpoint-${id}.tsv" ;;
	dataplane)
		{ echo "# RUN_ID=${id}"; printf '%s' "$kv"; echo "$DP_HDR"; printf '%s\t2\tci-a\tci-b\t100\t100\t8\t30\t2.0\t2.5\t5.0\t11.0\t12.5\tOK\t100\t0\tremote\n' "$id"; } > "${d}/latency-${id}.tsv" ;;
	churn)
		{ echo "# RUN_ID=${id}"; printf '%s' "$kv"; echo "$CHURN_HDR"; printf '%s\t2\t5\t1\t5\t1\t0\t1000\t2000\t300\t10\t20\t100\t200\t99\t99\t50\t60\t10\t10\tOK\n' "$id"; } > "${d}/churn-${id}.tsv" ;;
	churn-dataplane)
		{
			echo "# RUN_ID=${id}"; printf '%s' "$kv"; echo "$CD_HDR"
			printf '%s\tsha\tc1\t2\t%s\t%s\t60\t50\t48\t4\t3\t9\t6\t7\tN/A\t0\tOK\t10\t10\t100\t30\t5\t99\tN/A\tN/A\n' "$id" 0 baseline "$id" 1 churn
		} > "${d}/churn-dataplane-${id}.tsv" ;;
	controlplane)
		KV="$kv" ID="$id" awk '/^# HARNESS_SHA=/ { printf "%s", ENVIRON["KV"] } /^# RUN_ID=/ { print "# RUN_ID=" ENVIRON["ID"]; next } { print }' \
			"${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv" > "${d}/controlplane-${id}.tsv" ;;
	esac
}

# _ci <text>: a regex that matches <text> in any case.
_ci() {
	local i c out=""
	for ((i = 0; i < ${#1}; i++)); do c="${1:i:1}"; out+="[${c^^}${c,,}]"; done
	printf '%s' "$out"
}

# mixed <key> <a> <b>: the output names <key> (in any case) with mixed:<a> | <b> on its line
# (the | escaped in markdown).
mixed() {
	local k
	k="$(_ci "$1")"
	[[ "$output" =~ ${k}[^$'\n']*"mixed:${2} "('|'|'\|')" ${3}" ]]
}


@test "ISTIO_ACTIVE_REVISIONS and ISTIO_GENERATIONS are sweep-level in every format of every report: inputs that differ read mixed, an input without them mixes in as unknown" {
	local s rep fmt fmts old
	for s in propagation dataplane churn churn-dataplane controlplane; do
		case "$s" in propagation | churn-dataplane) rep="${ROOT}/tests/${s}/005-report-results.sh" ;; *) rep="${ROOT}/tests/${s}/004-report-results.sh" ;; esac
		_tsv "$s" "${RES}/${s}/two" r1 "$REV_A" "$GEN_A"
		_tsv "$s" "${RES}/${s}/two" r2 "$REV_B" "$GEN_B"
		_tsv "$s" "${RES}/${s}/half" r1 "$REV_A" "$GEN_A"
		_tsv "$s" "${RES}/${s}/half" r2 - -
		# churn has no json, and records a missing key as "unknown (not recorded)".
		fmts="text md csv json charts" old=unknown
		[[ "$s" != churn ]] || fmts="text md csv charts" old="unknown (not recorded)"
		for fmt in $fmts; do
			run --separate-stderr "$rep" --results-dir "${RES}/${s}/two" --allow-multi-run --format "$fmt"
			assert_success
			{ mixed ISTIO_ACTIVE_REVISIONS "$REV_A" "$REV_B" && mixed ISTIO_GENERATIONS "$GEN_A" "$GEN_B"; } \
				|| { echo "${s} ${fmt} (two): ${output}"; false; }
		done
		for fmt in text md; do
			run --separate-stderr "$rep" --results-dir "${RES}/${s}/half" --allow-multi-run --format "$fmt"
			{ mixed ISTIO_ACTIVE_REVISIONS "$REV_A" "$old" && mixed ISTIO_GENERATIONS "$GEN_A" "$old"; } \
				|| { echo "${s} ${fmt} (half): ${output}"; false; }
		done
	done
}

@test "tuning 004 merges both keys over sweep-metadata.txt and every pass's TSVs, in md and text" {
	local P="${BATS_TEST_TMPDIR}/psweep" R="${ROOT}/tests/tuning/004-compare-profiles.sh"
	mkdir -p "${P}/baseline" "${P}/01-x"
	# sweep-metadata.txt records the keys at the sweep's start, as 003 writes it.
	printf '# SUITE=propagation\n# PASSES=baseline,01-x\n# ISTIO_ACTIVE_REVISIONS=%s\n# ISTIO_GENERATIONS=%s\n' "$REV_A" "$GEN_A" > "${P}/sweep-metadata.txt"
	_tsv propagation "${P}/baseline" r1 "$REV_A" "$GEN_A"
	_tsv propagation "${P}/01-x" r2 "$REV_A" "$GEN_B"
	run --separate-stderr "$R" --results-dir "$P" --format md
	assert_success
	assert_line "- Active revisions and Istio CR generations (the sweep's start and its passes): ISTIO_ACTIVE_REVISIONS=${REV_A}; ISTIO_GENERATIONS=mixed:${GEN_A} | ${GEN_B}"
	_tsv propagation "${P}/01-x" r2 - -
	run --separate-stderr "$R" --results-dir "$P"
	assert_line "Active revisions and Istio CR generations (the sweep's start and its passes): ISTIO_ACTIVE_REVISIONS=mixed:${REV_A} | unknown; ISTIO_GENERATIONS=mixed:${GEN_A} | unknown"
}

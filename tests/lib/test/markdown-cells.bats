#!/usr/bin/env bats
# Markdown table cells: md_cell and MD_CELL_AWK escape | and turn a newline into a space;
# churn-dataplane 005, reach_coverage_render, dataplane 004, churn 004, propagation 005
# and tuning 004 keep every table's columns with a mixed value or a | in a cell, and
# controlplane 004 and the scale envelope keep a merged value in one cell. Names are
# placeholders (ci-a).

bats_require_minimum_version 1.5.0
load test_helper

PR="${ROOT}/tests/propagation"
TUNING_CMP="${ROOT}/tests/tuning/004-compare-profiles.sh"

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
	EK="${BATS_TEST_TMPDIR}/empty.kubeconfig"
	: > "$EK"
	export TMPDIR="$BATS_TEST_TMPDIR"
}

DP_HDR=$'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class'
CHURN_HDR=$'run_id\tmesh_size\tchurn_intensity\tbase_replicas\tscale_to\titeration\tt0_epoch_ns\tconvergence_local_ms\tremote_endpoint_reachable_ms\tconvergence_remote_eds_ms\tsource_push_triggers_delta\tremote_push_triggers_delta\tsource_xds_pushes_delta\tremote_xds_pushes_delta\tsource_queue_time_p99_ms\tremote_queue_time_p99_ms\tsource_connected_proxies\tremote_connected_proxies\tsource_push_time_p99_ms\tremote_push_time_p99_ms\tstatus'
CD_HDR=$'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms'
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

# _md_tables_even: every markdown table on stdin has as many unescaped | per row as its
# header (a | inside a cell, unescaped, would add a column).
_md_tables_even() {
	awk '
		function bars(s,    n, i, c, p) { n = 0; p = ""; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "|" && p != "\\") n++; p = c }; return n }
		/^\|/ { b = bars($0); if (!intab) { want = b; intab = 1 } else if (b != want) { print "uneven row (" b " vs " want "): " $0; bad = 1 }; next }
		{ intab = 0 }
		END { exit bad }'
}

# prow23 <iteration> <remote> <status> <p1_overflow> <restarted> <p1_status> <p1_skew> <remote_status> <remote_skew>:
# a 23-column row of run RID (r1), mesh size 3, p1 100 ms, P2 50 ms and P3 60 ms when
# remote_status is OK (else N/A).
prow23() {
	local p2=50 p3=60
	[[ "$8" == OK ]] || { p2=N/A p3=N/A; }
	printf '%s\t3\t%s\tsrc\t%s\t0\t100\t%s\t%s\t%s\t99\t99\t10/10\t10\t%s\t%s\t0\t5000\t10\t%s\t%s\t%s\t%s\n' \
		"${RID:-r1}" "$1" "$2" "$p2" "$p3" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}

# _mixed_tsv <suite> <dir> <run_id> <generations> <cell>: one input of the suite's
# report with `# ISTIO_GENERATIONS=` and `# ISTIOD_REPLICAS_BY_CONTEXT=` (the run's own,
# so two inputs pool to a mixed value), <cell> in a key column (dataplane: target_class,
# churn: churn_intensity).
_mixed_tsv() {
	local s="$1" d="$2" id="$3" g="$4" c="$5"
	mkdir -p "$d"
	case "$s" in
	dataplane)
		{ echo "# RUN_ID=${id}"; echo "# ISTIO_GENERATIONS=${g}"; echo "# ISTIOD_REPLICAS_BY_CONTEXT=ci-a=${id: -1},ci-b=2"; echo "$DP_HDR"
			printf '%s\t2\tci-a\tci-b\t100\t100\t8\t30\t2.0\t2.5\t5.0\t11.0\t12.5\tOK\t100\t0\t%s\n' "$id" "$c"; } > "${d}/latency-${id}.tsv" ;;
	churn)
		{ echo "# RUN_ID=${id}"; echo "# ISTIO_GENERATIONS=${g}"; echo "# ISTIOD_REPLICAS_BY_CONTEXT=ci-a=${id: -1},ci-b=2"; echo "$CHURN_HDR"
			printf '%s\t2\t%s\t1\t5\t1\t0\t1000\t2000\t300\t10\t20\t100\t200\t99\t99\t50\t60\t10\t10\tOK\n' "$id" "$c"; } > "${d}/churn-${id}.tsv" ;;
	propagation)
		source "${ROOT}/tests/lib/propagation.sh"
		{ echo "# RUN_ID=${id}"; echo "# ISTIO_GENERATIONS=${g}"; echo "# ISTIOD_REPLICAS_BY_CONTEXT=ci-a=${id: -1},ci-b=2"; echo "$PROP_TSV_HEADER"
			RID="$id" prow23 1 ci-b OK 0 0 OK 5 OK 5; } > "${d}/endpoint-${id}.tsv" ;;
	esac
}

@test "md_cell and MD_CELL_AWK escape | and turn a newline into a space, as -v or printed, on bash 5.1 rules too" {
	local v
	md_cell -v v $'mixed:a=1,b=2 | a=3,b=2\nnext'
	[ "$v" = 'mixed:a=1,b=2 \| a=3,b=2 next' ]
	[ "$(md_cell 'a|b|c')" = 'a\|b\|c' ]
	[ "$(md_cell 'no pipe \ here')" = 'no pipe \ here' ]
	[ "$(md_cell '')" = '' ]
	[ "$(md_cell '|')" = '\|' ]
	run env BASH_COMPAT=51 bash -c 'source "$1/tests/lib/common.sh"; md_cell -v v "x|y"; printf "%s\n" "$v"; md_cell "|a|"' _ "$ROOT"
	assert_output $'x\\|y\n\\|a\\|'
	run awk "${MD_CELL_AWK}"' BEGIN { print md_cell("a|b|c"); print md_cell("x\ny"); print md_cell("plain") }'
	assert_output $'a\\|b\\|c\nx y\nplain'
}

@test "churn-dataplane 005 markdown escapes | in its run table (a mixed value) and its results cells; every table keeps its columns" {
	local d="${RES}/cd"
	_gen_tsv churn-dataplane "$d" r1 "$GEN_A"
	_gen_tsv churn-dataplane "$d" r2 "$GEN_B"
	# A key with a | in it (a hand-edited TSV): its cell is escaped too.
	awk -F'\t' 'BEGIN { OFS = "\t" } !/^#/ && $1 != "run_id" { $5 = "x|y" } 1' "${d}/churn-dataplane-r2.tsv" > "${d}/x" && mv "${d}/x" "${d}/churn-dataplane-r2.tsv"
	run --separate-stderr "${ROOT}/tests/churn-dataplane/005-report-results.sh" --results-dir "$d" --allow-multi-run --format md
	assert_success
	assert_line "| ISTIO_GENERATIONS | \`mixed:${GEN_A} \\| ${GEN_B}\` |"
	assert_line --regexp '^\| 2 \| x\\\|y \| '
	_md_tables_even <<<"$output"
}

@test "reach_coverage_render md escapes | in a remote's name and error, in its tables and its callout" {
	source "${ROOT}/tests/lib/reach.sh"
	printf '3\ts\tok\t2\t2\tREACHABLE\t-\t-\n3\ts\tde|ad\t2\t0\tUNREACHABLE\t503\tupstream|reset\n' > "${RES}/rows"
	run reach_coverage_render md "${RES}/rows"
	assert_success
	assert_output --partial '| 3 | s | de\|ad | 0/2 | UNREACHABLE | 503 | upstream\|reset |'
	assert_output --partial '| 3 | s | 1/2 | de\|ad |'
	assert_output --partial '> ⚠ Remotes NOT reachable at mesh_size=3 from s: de\|ad (UNREACHABLE 0/2, 503, "upstream\|reset")'
	refute_output --partial 'de|ad'
	_md_tables_even <<<"$output"
}

@test "markdown: dataplane 004, churn 004, propagation 005 and tuning 004 keep every table even with pooled inputs whose keys differ (mixed values) and a | in a cell" {
	local s rep
	for s in dataplane churn propagation; do
		case "$s" in propagation) rep="${PR}/005-report-results.sh" ;; *) rep="${ROOT}/tests/${s}/004-report-results.sh" ;; esac
		_mixed_tsv "$s" "${RES}/${s}" r1 "$GEN_A" 'x|y'
		_mixed_tsv "$s" "${RES}/${s}" r2 "$GEN_B" 'x|y'
		run --separate-stderr "$rep" --results-dir "${RES}/${s}" --allow-multi-run --format md
		assert_success
		[[ "$output" == *"mixed:${GEN_A} "*" ${GEN_B}"* ]] || { echo "${s}: no mixed value: ${output}"; false; }
		_md_tables_even <<<"$output" || { echo "${s}: ${output}"; false; }
	done
	# The | in a key cell is escaped where the report prints it in a table.
	run --separate-stderr "${ROOT}/tests/dataplane/004-report-results.sh" --results-dir "${RES}/dataplane" --allow-multi-run --format md
	assert_line --regexp '^\| 2 \| 100 \| x\\\|y \| 2 \| 2 \|'
	run --separate-stderr "${ROOT}/tests/churn/004-report-results.sh" --results-dir "${RES}/churn" --allow-multi-run --format md
	assert_line --regexp '^\| 2 \| x\\\|y \| 1->5 \| 2 \| 2 \|'
	# tuning 004: a pass named with a |, and a mixed key over the passes.
	local P="${BATS_TEST_TMPDIR}/psweep"
	mkdir -p "${P}/baseline" "${P}/01-a|b"
	printf '# SUITE=propagation\n# PASSES=baseline,01-a|b\n' > "${P}/sweep-metadata.txt"
	_mixed_tsv propagation "${P}/baseline" r1 "$GEN_A" -
	_mixed_tsv propagation "${P}/01-a|b" r2 "$GEN_B" -
	run --separate-stderr "$TUNING_CMP" --results-dir "$P" --format md
	assert_success
	assert_line '| Metric | baseline | 01-a\|b |'
	_md_tables_even <<<"$output"
}

@test "a merged value whose parts hold commas (mixed:a | b) stays in one markdown table cell in controlplane 004 and the scale envelope" {
	local f="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv" rep="${ROOT}/tests/controlplane/004-report-results.sh"
	# Two TSVs of one run whose members connected other proxy versions.
	awk '{ print } /^# ISTIO_VERSION=/ { print "# ISTIO_PROXY_VERSIONS=mesh-a=1.30.5:3,mesh-b=1.30.5:4" }' "$f" > "${RES}/controlplane-fixture-t2.tsv"
	awk '{ print } /^# ISTIO_VERSION=/ { print "# ISTIO_PROXY_VERSIONS=mesh-a=1.31.0:7,mesh-b=1.31.0:9" }' "$f" > "${RES}/controlplane-fixture-t2-b.tsv"
	run --separate-stderr "$rep" --results-dir "$RES" --format markdown
	assert_success
	assert_line --regexp '^\| proxy versions at start \(connected to istiod, summed over the members\) \| mixed:mesh-a=1\.3[01]\.[05]:[0-9],mesh-b=1\.3[01]\.[05]:[0-9] \\\| mesh-a=1\.3[01]\.[05]:[0-9],mesh-b=1\.3[01]\.[05]:[0-9] \|$'
	source "${ROOT}/tests/lib/envelope.sh"
	source "${ROOT}/tests/lib/platform.sh"
	run --separate-stderr render_scale_envelope "$RES" "$rep" mesh-a,mesh-b false
	assert_success
	assert_line --regexp '^\| Proxy \(Envoy\) versions at the start \| mixed:mesh-a=[^|]* \\\| mesh-a=[^|]* \| '
}

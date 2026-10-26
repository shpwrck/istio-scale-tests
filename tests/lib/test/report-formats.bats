#!/usr/bin/env bats
# Every format of every report, through the real entrypoints (PL33), on pooled inputs:
# churn 004, churn-dataplane 005, controlplane 004, dataplane 004, propagation 005 and tuning
# 004. The run-level keys merge over all inputs (PL19, PL26), a value with a quote and a
# backslash reads back as written (json through jq, the md and charts frontmatter through
# python3 + PyYAML), and every markdown table keeps its columns with a | in a cell; with the
# escapers they rely on (yaml_str, md_cell). Each report runs once per format, in
# setup_file, since each format prints these with its own code. gateway-api 001's summary is
# gateway-api.bats's. Names are placeholders (ci-a).

bats_require_minimum_version 1.5.0
load test_helper

CHURN_HDR=$'run_id\tmesh_size\tchurn_intensity\tbase_replicas\tscale_to\titeration\tt0_epoch_ns\tconvergence_local_ms\tremote_endpoint_reachable_ms\tconvergence_remote_eds_ms\tsource_push_triggers_delta\tremote_push_triggers_delta\tsource_xds_pushes_delta\tremote_xds_pushes_delta\tsource_queue_time_p99_ms\tremote_queue_time_p99_ms\tsource_connected_proxies\tremote_connected_proxies\tsource_push_time_p99_ms\tremote_push_time_p99_ms\tstatus'
CD_HDR=$'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms'
DP_HDR=$'run_id\tmesh_size\tsource_ctx\ttarget_ctx\tqps_target\tqps_actual\tconnections\tduration_s\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tstatus\tpct_200\tistiod_restarted\ttarget_class'
SUITES="propagation dataplane churn churn-dataplane controlplane"
REV_A="ci-a=default,ci-b=default"
REV_B="ci-a=canary,ci-b=default"
GEN_A="ci-a=2/2,ci-b=3/2"
GEN_B="ci-a=4/2,ci-b=3/2"
# A value with a quote and a backslash, and what a plain YAML scalar would misread (": "
# and " #").
WEIRD='team "a"\b: #1.env'

# _report <suite>: its report script.
_report() {
	case "$1" in
	propagation | churn-dataplane) echo "${ROOT}/tests/$1/005-report-results.sh" ;;
	*) echo "${ROOT}/tests/$1/004-report-results.sh" ;;
	esac
}

# _formats <suite>: its formats (churn has no json).
_formats() {
	if [[ "$1" == churn ]]; then echo "text md csv charts"; else echo "text md csv json charts"; fi
}

# prow23 <iteration> <remote>: a 23-column propagation row of run RID, mesh size 3, every
# phase measured.
prow23() {
	printf '%s\t3\t%s\tsrc\t%s\t0\t100\t50\t60\tOK\t99\t99\t10/10\t10\t0\t0\t0\t5000\t10\tOK\t5\tOK\t5\n' "${RID:-r1}" "$1" "$2"
}

# _tsv <suite> <dir> <run_id> <config|-> <revisions|-> <generations|-> <key cell|-|>: one
# input of the suite's report, with `# RUN_CONFIG=`, `# ISTIO_ACTIVE_REVISIONS=` and
# `# ISTIO_GENERATIONS=` (none for -), and <key cell> in a key column (dataplane:
# target_class, churn: churn_intensity, churn-dataplane: churn_rate; empty or - for the
# usual value). propagation writes a measured row, or a SETUP_FAILED placeholder for -.
_tsv() {
	local s="$1" d="$2" id="$3" kv="" c="$7"
	mkdir -p "$d"
	[[ "$4" == - ]] || kv+="# RUN_CONFIG=${4}"$'\n'
	[[ "$5" == - ]] || kv+="# ISTIO_ACTIVE_REVISIONS=${5}"$'\n'
	[[ "$6" == - ]] || kv+="# ISTIO_GENERATIONS=${6}"$'\n'
	case "$s" in
	propagation)
		source "${ROOT}/tests/lib/propagation.sh"
		{
			echo "# RUN_ID=${id}"; printf '%s' "$kv"; echo "$PROP_TSV_HEADER"
			if [[ "$c" == - ]]; then prop_placeholder_row "$id" 2 ci-a SETUP_FAILED; else RID="$id" prow23 1 ci-b; fi
		} > "${d}/endpoint-${id}.tsv" ;;
	dataplane)
		[[ -n "$c" && "$c" != - ]] || c=remote
		{ echo "# RUN_ID=${id}"; printf '%s' "$kv"; echo "$DP_HDR"; printf '%s\t2\tci-a\tci-b\t100\t100\t8\t30\t2.0\t2.5\t5.0\t11.0\t12.5\tOK\t100\t0\t%s\n' "$id" "$c"; } > "${d}/latency-${id}.tsv" ;;
	churn)
		[[ -n "$c" && "$c" != - ]] || c=5
		{ echo "# RUN_ID=${id}"; printf '%s' "$kv"; echo "$CHURN_HDR"; printf '%s\t2\t%s\t1\t5\t1\t0\t1000\t2000\t300\t10\t20\t100\t200\t99\t99\t50\t60\t10\t10\tOK\n' "$id" "$c"; } > "${d}/churn-${id}.tsv" ;;
	churn-dataplane)
		[[ -n "$c" && "$c" != - ]] || c=1
		{
			echo "# RUN_ID=${id}"; printf '%s' "$kv"; echo "$CD_HDR"
			printf '%s\tsha\tc1\t2\t%s\t%s\t60\t50\t48\t4\t3\t9\t6\t7\tN/A\t0\tOK\t10\t10\t100\t30\t5\t99\tN/A\tN/A\n' "$id" 0 baseline "$id" "$c" churn
		} > "${d}/churn-dataplane-${id}.tsv" ;;
	controlplane)
		KV="$kv" ID="$id" awk '/^# HARNESS_SHA=/ { printf "%s", ENVIRON["KV"] } /^# RUN_ID=/ { print "# RUN_ID=" ENVIRON["ID"]; next } { print }' \
			"${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv" > "${d}/controlplane-${id}.tsv" ;;
	esac
}

# Three pooled inputs per report: r1 (the WEIRD config, REV_A, GEN_A), r2 (b.env, REV_B,
# GEN_B, a | in a key cell) and r3 (written before the keys: none of them); and a tuning
# sweep whose start (sweep-metadata.txt), baseline pass and "01-a|b" pass record the Istio keys
# differently, the last not at all. Every report, every format, once; out/<name>{,.err,.rc}.
setup_file() {
	export TMPDIR="$BATS_FILE_TMPDIR"
	local s fmt rc d="${BATS_FILE_TMPDIR}/in" out="${BATS_FILE_TMPDIR}/out" P="${BATS_FILE_TMPDIR}/in/tuning"
	mkdir -p "$out" "$P/baseline" "$P/01-a|b"
	for s in $SUITES; do
		_tsv "$s" "${d}/${s}" r1 "$WEIRD" "$REV_A" "$GEN_A" ""
		_tsv "$s" "${d}/${s}" r2 b.env "$REV_B" "$GEN_B" 'x|y'
		_tsv "$s" "${d}/${s}" r3 - - - -
		for fmt in $(_formats "$s"); do
			rc=0
			"$(_report "$s")" --results-dir "${d}/${s}" --allow-multi-run --format "$fmt" > "${out}/${s}.${fmt}" 2> "${out}/${s}.${fmt}.err" || rc=$?
			echo "$rc" > "${out}/${s}.${fmt}.rc"
		done
	done
	printf '# SUITE=propagation\n# PASSES=baseline,01-a|b\n# HARNESS_SHA=abc1234\n# CONTEXTS=%s\n# ISTIO_ACTIVE_REVISIONS=%s\n# ISTIO_GENERATIONS=%s\n' \
		"$WEIRD" "$REV_A" "$GEN_A" > "${P}/sweep-metadata.txt"
	_tsv propagation "${P}/baseline" r1 - "$REV_A" "$GEN_B" ""
	_tsv propagation "${P}/01-a|b" r2 - - - ""
	for fmt in md text; do
		rc=0
		"${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "$P" --format "$fmt" > "${out}/tuning.${fmt}" 2> "${out}/tuning.${fmt}.err" || rc=$?
		echo "$rc" > "${out}/tuning.${fmt}.rc"
	done
}

setup() {
	export TMPDIR="$BATS_TEST_TMPDIR"
}

# _out <name>: the saved run as output, lines and status.
_out() {
	output="$(cat "${BATS_FILE_TMPDIR}/out/$1")"
	mapfile -t lines <<<"$output"
	status="$(cat "${BATS_FILE_TMPDIR}/out/$1.rc")"
}

# need_yaml: skip without python3 + PyYAML.
need_yaml() {
	python3 -I -c 'import yaml' 2>/dev/null || skip "python3 with PyYAML is needed"
}

# fm <file>: the file's frontmatter (between its first two --- lines) as JSON, parsed by
# PyYAML; fails when the file has none, it does not parse or a key appears twice (PyYAML
# would keep the last one, and a stricter reader refuses the file).
fm() {
	python3 -I -c '
import json, sys, yaml
class Loader(yaml.SafeLoader):
    pass
def mapping(loader, node):
    keys = [loader.construct_object(k) for k, _ in node.value]
    dup = sorted({str(k) for k in keys if keys.count(k) > 1})
    if dup:
        sys.exit("the frontmatter repeats key(s): " + ", ".join(dup))
    return loader.construct_mapping(node, deep=True)
Loader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
if lines[0] != "---":
    sys.exit("no frontmatter")
end = lines.index("---", 1)
print(json.dumps(yaml.load("\n".join(lines[1:end]), Loader=Loader), default=str))
' "$1"
}

# _ci <text>: a regex that matches <text> in any case.
_ci() {
	local i c out=""
	for ((i = 0; i < ${#1}; i++)); do c="${1:i:1}"; out+="[${c^^}${c,,}]"; done
	printf '%s' "$out"
}

# mixed <key> <a> <b> <c>: the output names <key> (in any case) with mixed:<a> | <b> | <c> on
# its line (the | escaped in markdown).
mixed() {
	local k
	k="$(_ci "$1")"
	[[ "$output" =~ ${k}[^$'\n']*"mixed:${2} "('|'|'\|')" ${3} "('|'|'\|')" ${4}" ]]
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

@test "yaml_str escapes a quote, a backslash and control characters, keeps a plain number bare under -n, sets the variable under -v; every value reads back as itself through PyYAML, in the C and a UTF-8 locale" {
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
	local v loc out="${BATS_TEST_TMPDIR}/fm.md" vals="${BATS_TEST_TMPDIR}/vals"
	yaml_str -v v 'x"y'
	[ "$v" = '"x\"y"' ]
	need_yaml
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

@test "pooled inputs: every format of every report says it pools them and merges RUN_CONFIG, ISTIO_ACTIVE_REVISIONS and ISTIO_GENERATIONS over all of them, differing values mixed and a missing one unknown, never another input's (PL19, PL26)" {
	local s fmt old rc_re e
	rc_re="$(_ci run_config)"
	yaml_str -v e "mixed:${WEIRD},b.env,unknown"
	for s in $SUITES; do
		# churn records a missing Istio key as "unknown (not recorded)".
		old=unknown
		[[ "$s" != churn ]] || old="unknown (not recorded)"
		for fmt in $(_formats "$s"); do
			_out "${s}.${fmt}"
			[ "$status" -eq 0 ] || { echo "${s} ${fmt}: exit ${status}: $(cat "${BATS_FILE_TMPDIR}/out/${s}.${fmt}.err")"; false; }
			if [[ "$fmt" == json ]]; then
				[ "$(jq -r '.pooled_runs.runs' <<<"$output")" = 3 ] || { echo "${s} json: pooled_runs: ${output}"; false; }
				# Each string as jq reads it, after its key.
				output="$(jq -r 'paths(strings) as $p | "\($p[-1]): \(getpath($p))"' <<<"$output")"
			else
				[[ "$output" == *"This report pools 3 runs (--allow-multi-run): r1, r2, r3."* ]] || { echo "${s} ${fmt}: no pooled-runs note"; false; }
			fi
			{ mixed ISTIO_ACTIVE_REVISIONS "$REV_A" "$REV_B" "$old" && mixed ISTIO_GENERATIONS "$GEN_A" "$GEN_B" "$old"; } \
				|| { echo "${s} ${fmt}: ${output}"; false; }
			# RUN_CONFIG holds a quote and a backslash: as is in text, csv and json (as jq reads
			# it), as yaml_str writes it in the md and charts frontmatter.
			case "$fmt" in
			md | charts) [[ "$output" =~ ${rc_re}": ${e}" ]] ;;
			*) [[ "$output" =~ ${rc_re}[^$'\n']*"mixed:${WEIRD},b.env,unknown" ]] ;;
			esac || { echo "${s} ${fmt}: RUN_CONFIG not mixed: ${output}"; false; }
		done
	done
	# tuning 004 merges both Istio keys over the sweep's start and every pass, in md and text.
	for fmt in md text; do
		_out "tuning.${fmt}"
		[ "$status" -eq 0 ]
		[[ "$output" == *"Active revisions and Istio CR generations (the sweep's start and its passes): ISTIO_ACTIVE_REVISIONS=mixed:${REV_A} | unknown; ISTIO_GENERATIONS=mixed:${GEN_A} | ${GEN_B} | unknown"* ]] \
			|| { echo "tuning ${fmt}: ${output}"; false; }
	done
}

@test "a value with a quote, a backslash, ': ' and ' #' (and a tab or a CR) reads back as written: from every report's json through jq, from every md and charts frontmatter through YAML, each key once" {
	local s fmt got md key d="${BATS_TEST_TMPDIR}/j" n
	for s in $SUITES; do
		[[ "$s" != churn ]] || continue
		_out "${s}.json"
		[ "$(jq -r '[paths(strings) as $p | select(($p[-1] | type) == "string" and ($p[-1] | ascii_downcase) == "run_config") | getpath($p)] | unique | .[]' <<<"$output")" = "mixed:${WEIRD},b.env,unknown" ] \
			|| { echo "${s} json: ${output}"; false; }
	done
	# controlplane 004: two TSVs of one run, each with its own harness (h1"q\x, h2"q\x), the
	# json names both and the mixed value, and a leftover count with a quote; \t and \x stay two
	# characters each (awk -v would read \t as a tab).
	mkdir -p "${d}/cp" "${d}/pr"
	for n in 1 2; do
		awk -v n="$n" '
			NR == 1 { print; print "# RUN_CONFIG=configs/r\"c\\td.env"; print "# LEFTOVER_TEST_NAMESPACES=2 (\"a\\b\")"; next }
			/^# HARNESS_SHA=/ { print "# HARNESS_SHA=h" n "\"q\\x"; next }
			{ print }' "${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv" > "${d}/cp/controlplane-fixture-t2-${n}.tsv"
	done
	run --separate-stderr "$(_report controlplane)" --results-dir "${d}/cp" --format json
	assert_success
	[ "$(jq -r '.metadata.run_config' <<<"$output")" = 'configs/r"c\td.env' ]
	[ "$(jq -r '.metadata.harness_sha' <<<"$output")" = 'mixed:h1"q\x,h2"q\x' ]
	[ "$(jq -c '.metadata.harness_shas' <<<"$output")" = '["h1\"q\\x","h2\"q\\x"]' ]
	[ "$(jq -c '.pooled_runs.harness_sha' <<<"$output")" = '["h1\"q\\x","h2\"q\\x"]' ]
	[ "$(jq -r '.metadata.growth.leftover_test_namespaces_at_start' <<<"$output")" = '2 ("a\b")' ]
	[[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" == *'(HARNESS_SHA h1"q\x,h2"q\x)'* ]]
	# propagation 005: a run-config path with a tab, and a harness line saved with CRLF.
	source "${ROOT}/tests/lib/propagation.sh"
	{
		echo "# RUN_ID=r1"
		printf '# RUN_CONFIG=configs/r"c\\d\te.env\n'
		printf '# HARNESS_SHA=h"1\\x\r\n'
		echo "$PROP_TSV_HEADER"
		RID=r1 prow23 1 ci-b
	} > "${d}/pr/endpoint-r1.tsv"
	run --separate-stderr "$(_report propagation)" --results-dir "${d}/pr" --format json
	assert_success
	[ "$(jq -r '.metadata.RUN_CONFIG' <<<"$output")" = $'configs/r"c\\d\te.env' ]
	[ "$(jq -r '.metadata.HARNESS_SHA' <<<"$output")" = $'h"1\\x\r' ]
	[ "$(jq -c '.pooled_runs.harness_sha' <<<"$output")" = '["h\"1\\x\r"]' ]
	# The md and charts frontmatter, through PyYAML.
	need_yaml
	for s in $SUITES; do
		for fmt in md charts; do
			got="$(fm "${BATS_FILE_TMPDIR}/out/${s}.${fmt}")" || { echo "${s} ${fmt}: the frontmatter does not parse"; false; }
			key="$(jq -r 'keys[] | select(ascii_downcase == "run_config")' <<<"$got")"
			[ "$(jq -r --arg k "$key" '.[$k]' <<<"$got")" = "mixed:${WEIRD},b.env,unknown" ] || {
				echo "${s} ${fmt}: ${key} reads $(jq -c --arg k "$key" '.[$k]' <<<"$got")"
				false
			}
		done
	done
	# churn's and controlplane's charts frontmatter carry the tuning keys as their md does.
	for s in churn controlplane; do
		got="$(fm "${BATS_FILE_TMPDIR}/out/${s}.charts")"
		md="$(fm "${BATS_FILE_TMPDIR}/out/${s}.md")"
		for key in tuning_baseline sidecar_egress_hosts; do
			[ "$(jq -r --arg k "$key" 'has($k)' <<<"$got")" = true ] || { echo "${s} charts: no ${key}"; false; }
			[ "$(jq -c --arg k "$key" '.[$k]' <<<"$got")" = "$(jq -c --arg k "$key" '.[$k]' <<<"$md")" ] \
				|| { echo "${s}: ${key} is not the md's in charts"; false; }
		done
	done
	got="$(fm "${BATS_FILE_TMPDIR}/out/tuning.md")" || { echo "tuning md: the frontmatter does not parse"; false; }
	[ "$(jq -r '"\(.contexts)|\(.suite)|\(.passes)|\(.harness_sha)"' <<<"$got")" = "${WEIRD}|propagation|baseline,01-a|b|abc1234" ]
	for key in istio_version istio_active_revisions istio_generations; do
		[ "$(jq -r --arg k "$key" 'has($k)' <<<"$got")" = true ] || { echo "tuning md: no ${key}"; false; }
	done
}

@test "markdown: a | in a cell or a mixed value is escaped and every table keeps its columns, in every report's md and charts, the reach coverage and tuning 004 (a pass named with a |); a merged value whose parts hold commas stays in one cell in controlplane 004 and the scale envelope" {
	local s fmt f
	for s in $SUITES; do
		for fmt in md charts; do
			_md_tables_even < "${BATS_FILE_TMPDIR}/out/${s}.${fmt}" || { echo "${s} ${fmt}"; false; }
			! grep -qF 'x|y' "${BATS_FILE_TMPDIR}/out/${s}.${fmt}" || { echo "${s} ${fmt}: an unescaped x|y"; false; }
		done
	done
	# The | in a key cell is escaped where the report prints it in a table.
	_out dataplane.md
	assert_line --regexp '^\| 2 \| 100 \| x\\\|y \| 1 \| 1 \|'
	_out churn.md
	assert_line --regexp '^\| 2 \| x\\\|y \| 1->5 \| 1 \| 1 \|'
	_out churn-dataplane.md
	assert_line --regexp '^\| 2 \| x\\\|y \| '
	assert_line "| ISTIO_GENERATIONS | \`mixed:${GEN_A} \\| ${GEN_B} \\| unknown\` |"
	_out tuning.md
	assert_line '| Metric | baseline | 01-a\|b |'
	_md_tables_even <<<"$output"
	# reach_coverage_render: a | in a remote's name and its error, in its tables and its callout.
	source "${ROOT}/tests/lib/reach.sh"
	printf '3\ts\tok\t2\t2\tREACHABLE\t-\t-\n3\ts\tde|ad\t2\t0\tUNREACHABLE\t503\tupstream|reset\n' > "${BATS_TEST_TMPDIR}/rows"
	run reach_coverage_render md "${BATS_TEST_TMPDIR}/rows"
	assert_success
	assert_output --partial '| 3 | s | de\|ad | 0/2 | UNREACHABLE | 503 | upstream\|reset |'
	assert_output --partial '| 3 | s | 1/2 | de\|ad |'
	assert_output --partial '> ⚠ Remotes NOT reachable at mesh_size=3 from s: de\|ad (UNREACHABLE 0/2, 503, "upstream\|reset")'
	refute_output --partial 'de|ad'
	_md_tables_even <<<"$output"
	# controlplane 004 and the scale envelope: two TSVs of one run whose members ran other
	# istiod replica counts and Istio versions.
	f="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"
	mkdir -p "${BATS_TEST_TMPDIR}/cp"
	awk '{ print } /^# ISTIO_VERSION=/ { print "# ISTIO_VERSION_BY_CONTEXT=mesh-a=1.30.5,mesh-b=1.30.5"; print "# ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=3,mesh-b=3" }' "$f" > "${BATS_TEST_TMPDIR}/cp/controlplane-fixture-t2.tsv"
	awk '{ print } /^# ISTIO_VERSION=/ { print "# ISTIO_VERSION_BY_CONTEXT=mesh-a=1.31.0,mesh-b=1.31.0"; print "# ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=2,mesh-b=3" }' "$f" > "${BATS_TEST_TMPDIR}/cp/controlplane-fixture-t2-b.tsv"
	run --separate-stderr "$(_report controlplane)" --results-dir "${BATS_TEST_TMPDIR}/cp" --format markdown
	assert_success
	assert_line --regexp '^\| istiod replicas by context \| mixed:mesh-a=[23],mesh-b=3 \\\| mesh-a=[23],mesh-b=3 \|$'
	source "${ROOT}/tests/lib/envelope.sh"
	source "${ROOT}/tests/lib/platform.sh"
	run --separate-stderr render_scale_envelope "${BATS_TEST_TMPDIR}/cp" "$(_report controlplane)" mesh-a,mesh-b false
	assert_success
	assert_line --regexp '^\| Istio version \| .*by member mixed:mesh-a=[^|]* \\\| mesh-a=[^|]*\) \| '
}

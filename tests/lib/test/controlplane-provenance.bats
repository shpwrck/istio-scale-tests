#!/usr/bin/env bats
# Controlplane row provenance, through the entrypoints (PL33; no cluster: kubectl and curl
# are stubs): 002 records a harness change inside a run (HARNESS_CHANGED_AT, also across
# split phases) and each window's rows per member (WINDOW_ROWS); 004 says which runs and
# harness files the rows in its figures come from (kept rows only; a change of git
# describe alone is no harness change) and in what order a resume's line records its keys;
# a PROBLEM in the sweep outcome turns a PASS into CAUTION; and the markdown front matter's
# data warnings stay valid JSON.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/preamble.sh"
source "${ROOT}/tests/lib/capacity.sh"
source "${ROOT}/tests/lib/envelope.sh"

CP="${ROOT}/tests/controlplane"
REPORT="${CP}/004-report-results.sh"
FX="${ROOT}/tests/lib/test/fixtures/istiod-diag"
FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log" FX
	: > "$STUB_LOG"
	# 002's reads of one member with one Running istiod (as in istiod-diag.bats): the Istio
	# CR reads answer as fake-istio-cr.sh, other lists are empty, /metrics is the fixture.
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*) exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running "*) printf 'istiod-abc-x1\n' ;;
*" -o json "*) cat "$FX/empty_list.json" ;;
*) exit 1 ;;
esac
STUB
	cat > "${BIN}/curl" <<'STUB'
#!/usr/bin/env bash
out="" url=""
while (($#)); do
	case "$1" in
	-o) out="$2"; shift 2 ;;
	http://*) url="$1"; shift ;;
	*) shift ;;
	esac
done
case "$url" in
*/metrics) body="$FX/pre_metrics.txt" ;;
*/ready) echo LIVE; exit 0 ;;
*/debug/syncz) echo '[]'; exit 0 ;;
*) exit 7 ;;
esac
if [[ -n "$out" ]]; then cp "$body" "$out"; else cat "$body"; fi
STUB
	chmod +x "${BIN}/kubectl" "${BIN}/curl"
	TSV="${RES}/controlplane-R1.tsv"
}

# cp_window [args...]: one 002 window of ctx-a into res/controlplane-R1.tsv.
cp_window() {
	PATH="${BIN}:${PATH}" run --separate-stderr "${CP}/002-collect-resource-metrics.sh" \
		--contexts ctx-a --config-dump-samples 0 --settle 0 --output-dir "$RES" --run-id R1 "$@"
}

# report_json [dir]: 004's json of res/ (or dir).
report_json() {
	run --separate-stderr "$REPORT" --results-dir "${1:-$RES}" --format json
	assert_success
}

# preamble_set <key> <value>: rewrite the TSV preamble's "# <key>=" line.
preamble_set() {
	sed -i.bak "s/^# $1=.*/# $1=$2/" "$TSV" && rm -f "${TSV}.bak"
}

# resume_rows <sha> <key> [awk program]: append what a --resume of the TSV writes (its
# RESUMED_AT line, a WINDOW_ROWS line, then its rows): a copy of the TSV's last row, at a
# later time, changed by the awk program.
resume_rows() {
	local n row
	n="$(wc -l < "$TSV" | tr -d ' ')"
	row="$(awk -F'\t' -v OFS='\t' '!/^#/ && $1 != "timestamp" { r = $0 } END { $0 = r; $1 = "2030-01-02T00:00:00+00:00"; '"${3:-}"'; print }' "$TSV")"
	printf '# RESUMED_AT=2030-01-02T00:00:00+00:00 TSV_LINES=%s HARNESS_SHA=%s HARNESS_CONTENT_KEY=%s ISTIO_NOTREADY_AT_RESUME=none ISTIO_GENERATIONS=ctx-a=3/3 ISTIO_PROXY_VERSIONS=ctx-a=1.30.5 KUBE_VERSIONS=ctx-a=v1.31.0\n# WINDOW_ROWS=ctx-a=1\n%s\n' \
		"$n" "$1" "$2" "$row" >> "$TSV"
}

@test "002 records each window's rows per member, and a harness that changed inside a run as a HARNESS_CHANGED_AT line once; 004 names that span" {
	local live key
	cp_window
	assert_success
	key="$(sed -n 's/^# HARNESS_CONTENT_KEY=//p' "$TSV")"
	[[ "$key" =~ ^[0-9a-f]{12}$ ]]
	# The line before the window's row: its member and row count; no harness change.
	[ "$(awk '!/^#/ && $1 != "timestamp" { print prev; exit } { prev = $0 }' "$TSV")" = "# WINDOW_ROWS=ctx-a=1" ]
	[ "$(grep -c '^# HARNESS_CHANGED_AT=' "$TSV")" = 0 ]
	[[ "$stderr" != *"other harness files"* ]]
	# The TSV records other harness files than the next window runs.
	live="$(sed -n 's/^# HARNESS_SHA=//p' "$TSV")"
	preamble_set HARNESS_SHA old1234
	preamble_set HARNESS_CONTENT_KEY 000000000000
	cp_window
	assert_success
	[[ "$stderr" == *"warning: [002] these rows ran other harness files than controlplane-R1.tsv records (HARNESS_SHA=old1234, HARNESS_CONTENT_KEY=000000000000; now HARNESS_SHA=${live}): a HARNESS_CHANGED_AT line before them records it"* ]]
	run grep -E '^# (HARNESS_CHANGED_AT|WINDOW_ROWS)=' "$TSV"
	assert_line --index 0 "# WINDOW_ROWS=ctx-a=1"
	assert_line --index 1 --regexp "^# HARNESS_CHANGED_AT=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z HARNESS_SHA=${live} HARNESS_CONTENT_KEY=${key}\$"
	assert_line --index 2 "# WINDOW_ROWS=ctx-a=1"
	# The next window runs what the line records: no second line.
	cp_window
	assert_success
	[[ "$stderr" != *"other harness files"* ]]
	[ "$(grep -c '^# HARNESS_CHANGED_AT=' "$TSV")" = 1 ]
	report_json
	[ "$(jq -c '[.metadata.attempts[] | [.run, .harness_sha, .harness_content_key, .rows, .rows_kept]]' <<<"$output" | sed 's/at [0-9TZ:-]* (in/at T (in/')" = "[[\"first run\",\"old1234\",\"000000000000\",1,1],[\"harness changed at T (in the first run)\",\"${live}\",\"${key}\",2,2]]" ]
	[ "$(jq -c '.metadata.harness_shas' <<<"$output")" = "[\"old1234\",\"${live}\"]" ]
	[[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" == *"; the harness changed during a run (HARNESS_CHANGED_AT), see the attempts)"* ]]
	run --separate-stderr "$REPORT" --results-dir "$RES" --format text
	assert_output --partial "# attempts: the rows come from more than one run or harness: the first run (the HARNESS_SHA and KUBE_VERSIONS of the TSV preamble), then harness changed at "
	assert_output --partial "(in the first run) HARNESS_SHA=${live}"
}

@test "002 split phases: a baseline that ran other harness files than its final credits the window's rows to the baseline's" {
	local sd="${BATS_TEST_TMPDIR}/state"
	mkdir -p "$sd"
	cp_window
	assert_success
	cp_window --phase baseline --state-dir "$sd"
	assert_success
	[ "$(awk -F'\t' '{ print NF }' "${sd}/harness")" = 3 ]
	# A checkout between the phases: the baseline's read differs from the final's.
	printf 'base999\t111111111111\t2030-01-01T00:00:00Z\n' > "${sd}/harness"
	cp_window --phase final --state-dir "$sd"
	assert_success
	[[ "$stderr" == *"warning: [002] this window's baseline ran other harness files (HARNESS_SHA=base999) than its final scrape (HARNESS_SHA="*"): a harness file was edited, or a checkout ran, during the window"* ]]
	grep -qx '# HARNESS_CHANGED_AT=2030-01-01T00:00:00Z HARNESS_SHA=base999 HARNESS_CONTENT_KEY=111111111111' "$TSV"
}

@test "004 attempts: an earlier run whose rows were all run again later adds no harness or warning of its own; its kept-row count and start say so" {
	local live
	cp_window
	assert_success
	live="$(sed -n 's/^# HARNESS_SHA=//p' "$TSV")"
	# A --resume ran the same cell again with other harness files.
	resume_rows h2res 222222222222
	report_json
	[ "$(jq -c '[.metadata.attempts[] | [.harness_sha, .rows, .rows_kept]]' <<<"$output")" = "[[\"${live}\",1,0],[\"h2res\",1,1]]" ]
	[ "$(jq -c '.metadata.attempts[1] | [.started_at, .istio_notready, .istio_generations, .istio_proxy_versions, .kube_versions]' <<<"$output")" = '["2030-01-02T00:00:00Z","none","ctx-a=3/3","ctx-a=1.30.5","ctx-a=v1.31.0"]' ]
	[[ "$(jq -r '.metadata.attempts[0].started_at' <<<"$output")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]
	[ "$(jq -c '.metadata.harness_shas' <<<"$output")" = '["h2res"]' ]
	[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" = null ]
	run --separate-stderr "$REPORT" --results-dir "$RES" --format text
	assert_output --partial "# attempts: the rows come from one run (no other run's rows are in the figures): the first run (the HARNESS_SHA and KUBE_VERSIONS of the TSV preamble) (its rows were all run again later), then --resume at 2030-01-02T00:00:00+00:00 HARNESS_SHA=h2res KUBE_VERSIONS=ctx-a=v1.31.0"
	refute_output --partial "ran on different harnesses"
	[[ "$stderr" != *"ran on different harnesses"* ]]
}

@test "004 attempts: HARNESS_SHA values that differ only in git describe (the same HARNESS_CONTENT_KEY) are one harness; another key is not" {
	local key live note
	cp_window
	assert_success
	key="$(sed -n 's/^# HARNESS_CONTENT_KEY=//p' "$TSV")"
	live="$(sed -n 's/^# HARNESS_SHA=//p' "$TSV")"
	# Another cell (one more service), so both runs keep their rows.
	resume_rows v9.9.9-tag "$key" '$4 = $4 + 1'
	report_json
	[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" = null ]
	[ "$(jq -c '[.metadata.attempts[].rows_kept]' <<<"$output")" = '[1,1]' ]
	# The wording every report gives a describe-only difference (propagation 005, churn
	# 004, tuning 004, config_multi_run_note).
	note="HARNESS_SHA values (${live},v9.9.9-tag) differ only in git describe: every run records HARNESS_CONTENT_KEY=${key}, the same harness files (a commit or a tag outside them moved the describe)"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format text
	assert_output --partial "; their ${note}"
	[[ "$stderr" == *"note: the inputs' ${note}"* ]]
	refute_output --partial "ran on different harnesses"
	[[ "$stderr" != *"WARNING"* ]]
	# The same --resume with other harness files: the warning.
	sed -i.bak 's/^\(# RESUMED_AT=.* HARNESS_CONTENT_KEY=\)[0-9a-f]*/\1333333333333/' "$TSV" && rm -f "${TSV}.bak"
	report_json
	[[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" == *"The inputs ran on different harnesses (HARNESS_SHA ${live},v9.9.9-tag; a --resume's included, see the attempts)"* ]]
	run --separate-stderr "$REPORT" --results-dir "$RES" --format text
	refute_output --partial "differ only in git describe"
	[[ "$stderr" != *"differ only in git describe"* ]]
	[[ "$stderr" == *"WARNING: The inputs ran on different harnesses"* ]]
}

# cp_sweep <args...>: controlplane 003 with a kubectl stub whose istiod pod list fails (each
# cell PROBE_FAILED), its results under sweep-res/.
cp_sweep() {
	local ek="${BATS_TEST_TMPDIR}/kubeconfig" sb="${BATS_TEST_TMPDIR}/sbin"
	: > "$ek"
	mkdir -p "$sb"
	cat > "${sb}/kubectl" <<'STUB'
#!/bin/sh
case "$*" in
*"get istios.sailoperator.io default"*|*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${sb}/kubectl"
	PATH="${sb}:${PATH}" KUBECONFIG="$ek" CONTROLPLANE_RESULTS_DIR="${BATS_TEST_TMPDIR}/sweep-res" \
		ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0 \
		run bash "${CP}/003-run-sweep.sh" "$@"
}

@test "003 --resume: its RESUMED_AT line records each key in one order; 004 reads a copied TSV's attempts from it alone, and the envelope lists them" {
	local d tsv sha
	cp_sweep --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	d="$(find "${BATS_TEST_TMPDIR}/sweep-res" -mindepth 1 -maxdepth 1 -name 'sweep-*' -type d)"
	tsv="$(find "$d" -maxdepth 1 -name 'controlplane-*.tsv')"
	cp_sweep --resume "$d" --contexts ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 4
	sha="$(sed -n 's/^# HARNESS_SHA=//p' "$tsv")"
	run grep '^# RESUMED_AT=' "$tsv"
	assert_output --regexp "^# RESUMED_AT=[0-9T:+-]+ TSV_LINES=[0-9]+ HARNESS_SHA=[^ ]+ HARNESS_CONTENT_KEY=[0-9a-f]{12} ISTIO_NOTREADY_AT_RESUME=[^ ]+ ISTIO_GENERATIONS=ci-a=2/2 ISTIO_PROXY_VERSIONS=[^ ]+ KUBE_VERSIONS=[^ ]+\$"
	# The TSV alone (no resumes.txt): the line gives the resume's start and Istio state.
	mkdir -p "${BATS_TEST_TMPDIR}/alone"
	cp "$tsv" "${BATS_TEST_TMPDIR}/alone/"
	report_json "${BATS_TEST_TMPDIR}/alone"
	[ "$(jq -r '.metadata.attempts | length' <<<"$output")" = 2 ]
	[ "$(jq -c '.metadata.attempts[1] | [.istio_generations, .rows, .rows_kept]' <<<"$output")" = '["ci-a=2/2",1,1]' ]
	[[ "$(jq -r '.metadata.attempts[1].started_at' <<<"$output")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]
	run render_scale_envelope "$d" "$REPORT" ci-a false
	assert_success
	assert_output --regexp "> \*\*Attempts:\*\* first run HARNESS_SHA=${sha} \(1 row\(s\), 0 of them in the figures\); --resume at [^ ]+ HARNESS_SHA=[^ ]+ \(1 row\(s\), 1 of them in the figures\)"
}

# outcome_dir: a sweep dir of the fixture's cell, run again valid by a --resume (TSV_LINES):
# its verdict is PASS.
outcome_dir() {
	OD="${BATS_TEST_TMPDIR}/sweep-od"
	mkdir -p "$OD"
	local f="${OD}/controlplane-fixture-t2.tsv"
	cp "$FIXTURE" "$f"
	printf 'RESUMED_AT\tHARNESS_SHA\tISTIO_NOTREADY_AT_RESUME\tKUBE_VERSIONS\tTSV_LINES\n2026-06-01T00:20:00+00:00\tfixture\tnone\tmesh-a=v1.34.8\t%s\n' \
		"$(wc -l < "$f" | tr -d ' ')" > "${OD}/resumes.txt"
	awk -F'\t' -v OFS='\t' '!/^#/ && $1 != "timestamp" && !seen[$2]++ { $1 = "2026-06-01T00:30:00+00:00"; $8 = 800; print }' "$FIXTURE" >> "$f"
}

@test "a PROBLEM in the sweep outcome turns a PASS verdict into CAUTION: a finished record, an unfinished one with the outcome before it, and a sweep's own pending count" {
	outcome_dir
	report_json "$OD"
	[ "$(jq -r '.metadata.sla.verdict' <<<"$output")" = PASS ]
	printf 'RUN_ID=fixture-t2\nEXIT=0\nTOTAL=1\nPROBLEM=the harness changed during the sweep (bats)\n' > "${OD}/sweep-outcome.txt"
	report_json "$OD"
	[ "$(jq -r '.metadata.sla.verdict' <<<"$output")" = CAUTION ]
	[[ "$(jq -r '.metadata.sla.headline' <<<"$output")" == *"the sweep outcome records 1 PROBLEM(s) (sweep-outcome.txt), so the figures may not measure what they seem to"* ]]
	# Not finished (a --resume running, or killed): the outcome before it counts too.
	printf 'RUN_ID=fixture-t2\nEXIT=unfinished\nPROBLEM=a\n' > "${OD}/sweep-outcome.txt"
	printf 'RUN_ID=fixture-t2\nEXIT=4\nPROBLEM=b\nPROBLEM=c\n' > "${OD}/sweep-outcome.prev.txt"
	report_json "$OD"
	[[ "$(jq -r '.metadata.sla.headline' <<<"$output")" == *"the sweep outcome records 3 PROBLEM(s)"* ]]
	# A sweep's own report, before its outcome: the count it passes.
	_SWEEP_OUTCOME_PENDING=1 _SWEEP_OUTCOME_PROBLEMS=0 report_json "$OD"
	[ "$(jq -r '.metadata.sla.verdict' <<<"$output")" = PASS ]
	_SWEEP_OUTCOME_PENDING=1 _SWEEP_OUTCOME_PROBLEMS=2 report_json "$OD"
	[[ "$(jq -r '.metadata.sla.headline' <<<"$output")" == *"the sweep outcome records 2 PROBLEM(s)"* ]]
	# env_sla_verdict alone: arg 12 on a PASS, and on a FAIL.
	run env_sla_verdict 10 10 10 10 0 2 2 "" "" 0 0 1
	assert_output --regexp '^CAUTION\|the sweep outcome records 1 PROBLEM\(s\) \(sweep-outcome.txt\)'
	run env_sla_verdict 10 10 10 10 1 2 1 "" "" 0 0 1
	assert_output --regexp '^FAIL\|.*; also the sweep outcome records 1 PROBLEM\(s\) \(sweep-outcome.txt\)$'
	run env_sla_verdict 10 10 10 10 0 2 2
	assert_output --regexp '^PASS\|'
}

@test "004 md front matter: a data warning with a quote and a backslash stays one valid JSON array" {
	outcome_dir
	printf '# Planned cells (bats)\n# TSV=controlplane-fixture-t2.tsv\nmesh_size\tservice_count\treplicas\tnamespace_count\tsidecar_scoping\ttraffic_config\twindow_kind\n# PLAN=1 the first run: --traffic-configs q"x\\y\n2\t15\t2\t1\tnone\tq"x\\y\tdeploy\n' > "${OD}/planned-cells.txt"
	run --separate-stderr "$REPORT" --results-dir "$OD" --format md
	assert_success
	run jq -r '.[]' < <(sed -n 's/^data_warnings: //p' <<<"$output")
	assert_success
	assert_output --partial 'traffic=q"x\y'
}

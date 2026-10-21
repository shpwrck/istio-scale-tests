#!/usr/bin/env bats
# Controlplane row provenance, through the entrypoints (PL33; no cluster: kubectl and curl
# are stubs): 002 records a harness change inside a run (HARNESS_CHANGED_AT, also across
# split phases) and each window's rows per member (WINDOW_ROWS); 004 says which harness
# files the rows in its figures ran (a change of git describe alone is no harness change);
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

# changed_rows <sha> <key> [awk program]: append what 002 writes after a harness change
# inside the run (its HARNESS_CHANGED_AT line, a WINDOW_ROWS line, then its rows): a copy of
# the TSV's last row, at a later time, changed by the awk program.
changed_rows() {
	local row
	row="$(awk -F'\t' -v OFS='\t' '!/^#/ && $1 != "timestamp" { r = $0 } END { $0 = r; $1 = "2030-01-02T00:00:00+00:00"; '"${3:-}"'; print }' "$TSV")"
	printf '# HARNESS_CHANGED_AT=2030-01-02T00:00:00Z HARNESS_SHA=%s HARNESS_CONTENT_KEY=%s\n# WINDOW_ROWS=ctx-a=1\n%s\n' "$1" "$2" "$row" >> "$TSV"
}

@test "002 records each window's rows per member, and a harness that changed inside a run as a HARNESS_CHANGED_AT line once; 004 names both harnesses and the change" {
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
	[[ "$stderr" == *"warning: [002] these rows ran other harness files than controlplane-R1.tsv records (HARNESS_SHA=old1234, HARNESS_CONTENT_KEY=000000000000; now HARNESS_SHA=${live}, HARNESS_CONTENT_KEY=${key}): a HARNESS_CHANGED_AT line before them records it"* ]]
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
	[ "$(jq -c '.metadata.harness_shas' <<<"$output")" = "[\"old1234\",\"${live}\"]" ]
	[[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" == *"The inputs ran on different harnesses (HARNESS_SHA old1234,${live}; the harness changed during a run (HARNESS_CHANGED_AT))"* ]]
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

@test "004: HARNESS_SHA values that differ only in git describe (the same HARNESS_CONTENT_KEY) are one harness; another key is not" {
	local key live note
	cp_window
	assert_success
	key="$(sed -n 's/^# HARNESS_CONTENT_KEY=//p' "$TSV")"
	live="$(sed -n 's/^# HARNESS_SHA=//p' "$TSV")"
	# A harness change inside the run whose describe alone differs, before another cell's
	# row (one more service).
	changed_rows v9.9.9-tag "$key" '$4 = $4 + 1'
	report_json
	[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" = null ]
	[ "$(jq -c '.metadata.harness_shas' <<<"$output")" = "[\"${live}\",\"v9.9.9-tag\"]" ]
	# The wording every report gives a describe-only difference (propagation 005, churn
	# 004, tuning 004, config_multi_run_note).
	note="HARNESS_SHA values (${live},v9.9.9-tag) differ only in git describe: every run records HARNESS_CONTENT_KEY=${key}, the same harness files (a commit or tag that left the harness files as they were)"
	run --separate-stderr "$REPORT" --results-dir "$RES" --format text
	[[ "$stderr" == *"note: the inputs' ${note}"* ]]
	refute_output --partial "ran on different harnesses"
	# No harness warning (the stub's member has no node provider on record: the platform
	# record's warning says so).
	[[ "$stderr" != *"ran on different harnesses"* ]]
	# The same change with other harness files: the warning.
	sed -i.bak 's/^\(# HARNESS_CHANGED_AT=.* HARNESS_CONTENT_KEY=\)[0-9a-f]*/\1333333333333/' "$TSV" && rm -f "${TSV}.bak"
	report_json
	[[ "$(jq -r '.metadata.provenance_warning' <<<"$output")" == *"The inputs ran on different harnesses (HARNESS_SHA ${live},v9.9.9-tag; the harness changed during a run (HARNESS_CHANGED_AT))"* ]]
	run --separate-stderr "$REPORT" --results-dir "$RES" --format text
	refute_output --partial "differ only in git describe"
	[[ "$stderr" != *"differ only in git describe"* ]]
	[[ "$stderr" == *"WARNING: The inputs ran on different harnesses"* ]]
}

# outcome_dir: a sweep dir of the fixture's cell with every row valid (no istiod restart):
# its verdict is PASS.
outcome_dir() {
	OD="${BATS_TEST_TMPDIR}/sweep-od"
	mkdir -p "$OD"
	awk -F'\t' -v OFS='\t' '!/^#/ && $1 != "timestamp" { $31 = 0 } { print }' "$FIXTURE" > "${OD}/controlplane-fixture-t2.tsv"
}

@test "a PROBLEM in the sweep outcome turns a PASS verdict into CAUTION: a finished record, an unfinished one, and a sweep's own pending count" {
	outcome_dir
	report_json "$OD"
	[ "$(jq -r '.metadata.sla.verdict' <<<"$output")" = PASS ]
	printf 'RUN_ID=fixture-t2\nEXIT=0\nTOTAL=1\nPROBLEM=the harness changed during the sweep (bats)\n' > "${OD}/sweep-outcome.txt"
	report_json "$OD"
	[ "$(jq -r '.metadata.sla.verdict' <<<"$output")" = CAUTION ]
	[[ "$(jq -r '.metadata.sla.headline' <<<"$output")" == *"the sweep outcome records 1 PROBLEM(s) (sweep-outcome.txt), so the figures may not measure what they seem to"* ]]
	# Not finished (it died, or still runs): its PROBLEM counts too.
	printf 'RUN_ID=fixture-t2\nEXIT=unfinished\nPROBLEM=a\n' > "${OD}/sweep-outcome.txt"
	report_json "$OD"
	[[ "$(jq -r '.metadata.sla.headline' <<<"$output")" == *"the sweep outcome records 1 PROBLEM(s)"* ]]
	# A sweep's own report, before its outcome: the count it passes.
	_SWEEP_OUTCOME_PENDING=1 _SWEEP_OUTCOME_PROBLEMS=0 report_json "$OD"
	[ "$(jq -r '.metadata.sla.verdict' <<<"$output")" = PASS ]
	_SWEEP_OUTCOME_PENDING=1 _SWEEP_OUTCOME_PROBLEMS=2 report_json "$OD"
	[[ "$(jq -r '.metadata.sla.headline' <<<"$output")" == *"the sweep outcome records 2 PROBLEM(s)"* ]]
	# env_sla_verdict alone: arg 11 on a PASS, and on a FAIL.
	run env_sla_verdict 10 10 10 10 0 2 2 "" "" 0 1
	assert_output --regexp '^CAUTION\|the sweep outcome records 1 PROBLEM\(s\) \(sweep-outcome.txt\)'
	run env_sla_verdict 10 10 10 10 1 2 1 "" "" 0 1
	assert_output --regexp '^FAIL\|.*; also the sweep outcome records 1 PROBLEM\(s\) \(sweep-outcome.txt\)$'
	run env_sla_verdict 10 10 10 10 0 2 2
	assert_output --regexp '^PASS\|'
}

@test "004 md front matter: a data warning with a quote and a backslash stays one valid JSON array" {
	outcome_dir
	# A cell of one member's rows (INCOMPLETE) whose traffic config holds a quote and a
	# backslash.
	awk -F'\t' -v OFS='\t' '!/^#/ && $1 != "timestamp" && $2 == "mesh-a" && !d++ { $4 = 16; $44 = "q\"x\\y"; print }' "$FIXTURE" >> "${OD}/controlplane-fixture-t2.tsv"
	run --separate-stderr "$REPORT" --results-dir "$OD" --format md
	assert_success
	run jq -r '.[]' < <(sed -n 's/^data_warnings: //p' <<<"$output")
	assert_success
	assert_output --partial 'traffic=q"x\y'
}

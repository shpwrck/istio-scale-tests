#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

# --- die() ---

@test "die outputs message to stderr and exits 1" {
	run die "something broke"
	assert_failure 1
	assert_output "error: something broke"
}

@test "die preserves multi-word messages" {
	run die "multiple words in message"
	assert_failure 1
	assert_output "error: multiple words in message"
}

# --- split_csv() ---

@test "split_csv: empty string produces empty array" {
	local -a result=()
	split_csv "" result
	[[ ${#result[@]} -eq 0 ]]
}

@test "split_csv: single value" {
	local -a result=()
	split_csv "alpha" result
	[[ ${#result[@]} -eq 1 ]]
	[[ "${result[0]}" == "alpha" ]]
}

@test "split_csv: multiple values" {
	local -a result=()
	split_csv "a,b,c" result
	[[ ${#result[@]} -eq 3 ]]
	[[ "${result[0]}" == "a" ]]
	[[ "${result[1]}" == "b" ]]
	[[ "${result[2]}" == "c" ]]
}

@test "split_csv: trims whitespace around values" {
	local -a result=()
	split_csv "a, b , c" result
	[[ ${#result[@]} -eq 3 ]]
	[[ "${result[0]}" == "a" ]]
	[[ "${result[1]}" == "b" ]]
	[[ "${result[2]}" == "c" ]]
}

@test "split_csv: trailing comma produces no empty element" {
	local -a result=()
	split_csv "a,b," result
	[[ ${#result[@]} -eq 2 ]]
	[[ "${result[0]}" == "a" ]]
	[[ "${result[1]}" == "b" ]]
}

@test "split_csv: whitespace-only element is dropped" {
	local -a result=()
	split_csv "a, ,b" result
	[[ ${#result[@]} -eq 2 ]]
	[[ "${result[0]}" == "a" ]]
	[[ "${result[1]}" == "b" ]]
}

@test "split_csv: an empty last item returns 0 under set -e (no ERR-trap abort)" {
	# The loop's last test used to fail on an empty last item, so `X=2,,` or `,` killed
	# a sweep under set -e with a FATAL line instead of its own message.
	run bash -c 'set -euo pipefail; source "$1/tests/lib/common.sh"
		for csv in "2,," "2, " "," " " ""; do
			split_csv "$csv" out
			printf "[%s]=%s\n" "$csv" "${#out[@]}"
		done' _ "$ROOT"
	assert_success
	assert_output $'[2,,]=1\n[2, ]=1\n[,]=0\n[ ]=0\n[]=0'
}

@test "split_csv: a sweep axis that splits to nothing names its flag" {
	run env KUBECONFIG=/dev/null "${ROOT}/tests/churn/003-run-sweep.sh" --dry-run --contexts a,b --churn-intensities ,
	assert_failure
	assert_output --partial "error: --churn-intensities produced an empty list (got ',')"
	refute_output --partial "FATAL"
	run env KUBECONFIG=/dev/null "${ROOT}/tests/dataplane/003-run-sweep.sh" --dry-run --contexts a,b --mesh-sizes ,
	assert_failure
	assert_output --partial "error: --mesh-sizes produced an empty list (got ',')"
	# A trailing comma is still fine.
	run env KUBECONFIG=/dev/null "${ROOT}/tests/churn/003-run-sweep.sh" --dry-run --contexts a,b --churn-intensities 2,,
	assert_success
}

# --- is_pos_int() ---

@test "is_pos_int: accepts positive integers" {
	run is_pos_int "5"
	assert_success
	run is_pos_int "123"
	assert_success
}

@test "is_pos_int: rejects zero" {
	run is_pos_int "0"
	assert_failure
}

@test "is_pos_int: rejects negative numbers" {
	run is_pos_int "-1"
	assert_failure
}

@test "is_pos_int: rejects non-numeric strings" {
	run is_pos_int "abc"
	assert_failure
	run is_pos_int ""
	assert_failure
	run is_pos_int "1.5"
	assert_failure
}

@test "is_pos_int: rejects leading zeros" {
	run is_pos_int "01"
	assert_failure
}

# --- is_nonneg_int() ---

@test "is_nonneg_int: accepts zero" {
	run is_nonneg_int "0"
	assert_success
}

@test "is_nonneg_int: accepts positive integers" {
	run is_nonneg_int "5"
	assert_success
	run is_nonneg_int "100"
	assert_success
}

@test "is_nonneg_int: rejects negative numbers" {
	run is_nonneg_int "-1"
	assert_failure
}

@test "is_nonneg_int: rejects non-numeric" {
	run is_nonneg_int "abc"
	assert_failure
}

# --- validate_scoping() ---

@test "validate_scoping: accepts valid values" {
	run validate_scoping "none"
	assert_success
	run validate_scoping "namespace"
	assert_success
	run validate_scoping "explicit"
	assert_success
}

@test "validate_scoping: rejects invalid value with die" {
	run validate_scoping "invalid"
	assert_failure 1
	assert_output --partial "error:"
	assert_output --partial "none, namespace, explicit"
}

# --- resolve_kubectl() ---

_stub_cli() {
	local dir="$1" name="$2"
	mkdir -p "$dir"
	printf '#!/bin/sh\nexit 0\n' > "${dir}/${name}"
	chmod +x "${dir}/${name}"
}

@test "resolve_kubectl: prefers kubectl when both CLIs exist" {
	_stub_cli "$BATS_TEST_TMPDIR/bin" kubectl
	_stub_cli "$BATS_TEST_TMPDIR/bin" oc
	local -a kc=()
	PATH="$BATS_TEST_TMPDIR/bin" resolve_kubectl kc
	[[ "${kc[*]}" == "kubectl" ]]
}

@test "resolve_kubectl: falls back to oc and adds no extra flags" {
	_stub_cli "$BATS_TEST_TMPDIR/bin" oc
	local -a kc=()
	PATH="$BATS_TEST_TMPDIR/bin" resolve_kubectl kc
	[[ ${#kc[@]} -eq 1 && "${kc[0]}" == "oc" ]]
}

@test "resolve_kubectl: dies when neither CLI is on PATH" {
	mkdir -p "$BATS_TEST_TMPDIR/empty"
	local -a kc=()
	PATH="$BATS_TEST_TMPDIR/empty" run resolve_kubectl kc
	assert_failure 1
	assert_output "error: neither kubectl nor oc found on PATH"
}

# --- VirtualService/DestinationRule load axis: validate_traffic_config() / vsdr_service_count() ---

@test "validate_traffic_config: accepts none and vsdr" {
	run validate_traffic_config none
	assert_success
	run validate_traffic_config vsdr
	assert_success
}

@test "validate_traffic_config: rejects VSDR, empty and bogus with die" {
	for v in VSDR "" bogus; do
		run validate_traffic_config "$v"
		assert_failure 1
		assert_output --partial "--traffic-config must be one of [none, vsdr]"
	done
}

@test "vsdr_service_count: ceil(services / every), matching the chart's i mod every == 0" {
	[[ "$(vsdr_service_count 10 1)" == 10 ]]
	[[ "$(vsdr_service_count 10 3)" == 4 ]]
	[[ "$(vsdr_service_count 9 3)" == 3 ]]
	[[ "$(vsdr_service_count 1 5)" == 1 ]]
	[[ "$(vsdr_service_count 0 2)" == 0 ]]
}

@test "vsdr_service_count: rejects every < 1 and a non-integer count" {
	run vsdr_service_count 10 0
	assert_failure 1
	run vsdr_service_count x 2
	assert_failure 1
}

@test "resume_preamble_scalar: adopts the recorded value when the flag was not passed" {
	f="${BATS_TEST_TMPDIR}/resume.tsv"
	printf '# VSDR_SUBSETS=3\ntimestamp\tcontext\n' > "$f"
	local subsets=2
	resume_preamble_scalar "$f" VSDR_SUBSETS subsets --vsdr-subsets 0 2> "${BATS_TEST_TMPDIR}/err"
	[[ "$subsets" == 3 ]]
	grep -q 'using VSDR_SUBSETS=3 from the resumed sweep' "${BATS_TEST_TMPDIR}/err"
}

@test "resume_preamble_scalar: silent no-op when the value already matches" {
	f="${BATS_TEST_TMPDIR}/resume.tsv"
	printf '# VSDR_EVERY=2\ntimestamp\tcontext\n' > "$f"
	local every=2
	resume_preamble_scalar "$f" VSDR_EVERY every --vsdr-every 1 2> "${BATS_TEST_TMPDIR}/err"
	[[ "$every" == 2 ]]
	[[ ! -s "${BATS_TEST_TMPDIR}/err" ]]
}

@test "resume_preamble_scalar: dies when an explicit flag conflicts with the preamble" {
	f="${BATS_TEST_TMPDIR}/resume.tsv"
	printf '# VSDR_SUBSETS=3\ntimestamp\tcontext\n' > "$f"
	subsets=2
	run resume_preamble_scalar "$f" VSDR_SUBSETS subsets --vsdr-subsets 1
	assert_failure 1
	assert_output --partial "--vsdr-subsets 2 differs from VSDR_SUBSETS=3"
}

@test "resume_preamble_scalar: dies when the key is missing, and reads the preamble only" {
	f="${BATS_TEST_TMPDIR}/resume.tsv"
	# A matching line after the header is not preamble.
	printf '# VSDR_EVERY=1\ntimestamp\tcontext\n# VSDR_SUBSETS=3\n' > "$f"
	subsets=2
	run resume_preamble_scalar "$f" VSDR_SUBSETS subsets --vsdr-subsets 0
	assert_failure 1
	assert_output --partial "has no '# VSDR_SUBSETS=' preamble line"
}

# --- is_ratio() (dataplane --min-qps-ratio, DATAPLANE_MIN_PCT_200) ---

@test "is_ratio: accepts decimals in (0, 1]" {
	for v in 0.95 1 1.0 .5 0.01; do
		run is_ratio "$v"
		assert_success
	done
}

@test "is_ratio: rejects 0, > 1, negatives and non-numbers" {
	for v in 0 0.0 1.01 2 -0.5 abc 0.9x "" " 0.5" 1. ; do
		run is_ratio "$v"
		assert_failure
	done
}

# --- is_dns_label_for() (per-cluster Service names) ---

@test "is_dns_label_for: a lowercase DNS label that fits the prefix" {
	run is_dns_label_for dataplane-server- mesh-a
	assert_success
	# 46 chars + the 17-char prefix = 63, the limit.
	run is_dns_label_for dataplane-server- "a$(printf 'b%.0s' {1..45})"
	assert_success
}

@test "is_dns_label_for: uppercase, too long, leading digit, trailing '-', '/' all fail" {
	for ctx in Mesh-A "a$(printf 'b%.0s' {1..49})" 1mesh mesh- "default/api:6443/admin" ""; do
		run is_dns_label_for dataplane-server- "$ctx"
		assert_failure
	done
	# A 49-char context fits the shorter fortio-server- prefix (14 + 49 = 63); 50 does not.
	run is_dns_label_for fortio-server- "a$(printf 'b%.0s' {1..48})"
	assert_success
	run is_dns_label_for fortio-server- "a$(printf 'b%.0s' {1..49})"
	assert_failure
}

# --- timeout_cmd / run_timeout (R17) ---

# _in_path <dir> <fn> [args...]: run a common.sh function with PATH set to <dir> alone.
_in_path() {
	local d="$1"
	shift
	bash -c 'source "$ROOT/tests/lib/common.sh"; PATH="$1"; shift; "$@"' _ "$d" "$@"
}

@test "timeout_cmd / run_timeout: timeout, else gtimeout (macOS coreutils), else exit 127 with the install hint (R17)" {
	local d="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$d"
	printf '#!/bin/sh\necho "gtimeout $*"\n' > "${d}/gtimeout"
	chmod +x "${d}/gtimeout"
	run _in_path "$d" timeout_cmd
	assert_success
	assert_output gtimeout
	run _in_path "$d" run_timeout 5s echo hi
	assert_success
	assert_output "gtimeout 5s echo hi"
	printf '#!/bin/sh\necho "timeout $*"\n' > "${d}/timeout"
	chmod +x "${d}/timeout"
	run _in_path "$d" timeout_cmd
	assert_output timeout
	rm "${d}/timeout" "${d}/gtimeout"
	run _in_path "$d" timeout_cmd
	assert_failure 1
	run -127 --separate-stderr _in_path "$d" run_timeout 5s true
	[[ "$stderr" == *"neither 'timeout' nor 'gtimeout' (GNU coreutils) is on PATH; on macOS: brew install coreutils"* ]]
	run --separate-stderr _in_path "$d" require_timeout
	assert_failure 1
	[[ "$stderr" == *"On macOS: brew install coreutils"* ]]
}

# --- sweep_outcome (R19) ---

@test "sweep_outcome: all ran is exit 0 on stdout; failed cells are counted by reason on stderr, exit 4" {
	run --separate-stderr sweep_outcome 6
	assert_success
	assert_output "All 6 cells ran (their rows' own statuses are in the report)."
	[ -z "$stderr" ]
	run --separate-stderr sweep_outcome 6 SETUP_FAILED PROBE_FAILED SETUP_FAILED
	assert_failure 4
	[ -z "$output" ]
	[ "$stderr" = "error: 3 of 6 cells failed: PROBE_FAILED x1, SETUP_FAILED x2. The report includes them as placeholder rows (in n_total, not n_valid); exit 4." ]
}

@test "sweep_outcome --stopped: a stop's code outranks 4, the line names it, and 'All cells ran' is never claimed" {
	run --separate-stderr sweep_outcome --stopped 3 4 PROBE_FAILED
	assert_failure 3
	[ "$stderr" = "error: 1 of 4 cells failed: PROBE_FAILED x1. The report includes them as placeholder rows (in n_total, not n_valid); the sweep also stopped early, so it exits 3, not 4." ]
	run --separate-stderr sweep_outcome --stopped 1 4
	assert_failure 1
	[ -z "$output" ]
	[ -z "$stderr" ]
}

@test "sweep_outcome: SKIPPED_* cells are skipped on purpose, not failures; --unit and --where name the caller's own (C2, C4)" {
	run --separate-stderr sweep_outcome 6 SKIPPED_MEM_GUARD SKIPPED_SERIES_STOPPED SKIPPED_SERIES_STOPPED
	assert_success
	assert_output "3 of 6 cells were skipped on purpose, not failed: SKIPPED_MEM_GUARD x1, SKIPPED_SERIES_STOPPED x2."
	[ -z "$stderr" ]
	run --separate-stderr sweep_outcome 6 SKIPPED_MEM_GUARD PROBE_FAILED
	assert_failure 4
	assert_output "1 of 6 cells were skipped on purpose, not failed: SKIPPED_MEM_GUARD x1."
	[[ "$stderr" == "error: 1 of 6 cells failed: PROBE_FAILED x1. "* ]]
	run --separate-stderr sweep_outcome --unit passes --where "Each has its marker file in its pass directory" 3 SETUP_FAILED
	assert_failure 4
	[ "$stderr" = "error: 1 of 3 passes failed: SETUP_FAILED x1. Each has its marker file in its pass directory; exit 4." ]
	run --separate-stderr sweep_outcome --unit passes 3
	assert_output "All 3 passes ran (their rows' own statuses are in the report)."
}

@test "sweep_outcome: --problem fails a sweep whose cells ran, --note does not; --record and --md keep the outcome with the results (A6, C3)" {
	local d="${BATS_TEST_TMPDIR}/sweep" md
	mkdir -p "$d"
	md="${d}/sweep-x.md"
	echo "# report" > "$md"
	run --separate-stderr sweep_outcome --record "$d" --md "$md" --problem "the Istio version changed during the sweep (a: v1 at the start, v2 at the end)" \
		--note "something unconfirmed" 2
	assert_failure 4
	assert_output "All 2 cells ran (their rows' own statuses are in the report)."
	[[ "$stderr" == *"error: the Istio version changed during the sweep (a: v1 at the start, v2 at the end); exit 4."* ]]
	[[ "$stderr" == *"warning: something unconfirmed."* ]]
	grep -qx 'EXIT=4' "${d}/sweep-outcome.txt"
	grep -qx 'FAILED=0' "${d}/sweep-outcome.txt"
	grep -qx 'PROBLEM=the Istio version changed during the sweep (a: v1 at the start, v2 at the end)' "${d}/sweep-outcome.txt"
	grep -qx 'NOTE=something unconfirmed' "${d}/sweep-outcome.txt"
	grep -qx '## Sweep outcome' "$md"
	grep -q '^- error: the Istio version changed during the sweep' "$md"
	# A note alone: exit 0. A stop: its code, recorded, nothing extra on the terminal.
	run --separate-stderr sweep_outcome --note "n" 2
	assert_success
	run --separate-stderr sweep_outcome --stopped 1 --record "$d" --md "$md" 2 SKIPPED_MEM_GUARD
	assert_failure 1
	[ -z "$stderr" ]
	grep -qx 'EXIT=1' "${d}/sweep-outcome.txt"
	grep -qx 'SKIPPED_BY=SKIPPED_MEM_GUARD x1' "${d}/sweep-outcome.txt"
	grep -qx -- '- The sweep stopped early; it exits 1.' "$md"
}

@test "sweep_outcome under set -euo pipefail: FAILED, SKIPPED and their tallies, and with every list empty (X1)" {
	local d="${BATS_TEST_TMPDIR}/setu"
	mkdir -p "$d"
	run --separate-stderr bash -c 'set -euo pipefail; ROOT="$1"; source "$1/tests/lib/common.sh"
		sweep_outcome --record "$2" 5 PROBE_FAILED SETUP_FAILED SKIPPED_MEM_GUARD' _ "$ROOT" "$d"
	assert_failure 4
	assert_output "1 of 5 cells were skipped on purpose, not failed: SKIPPED_MEM_GUARD x1."
	[[ "$stderr" == "error: 2 of 5 cells failed: PROBE_FAILED x1, SETUP_FAILED x1. "* ]]
	grep -qx 'FAILED=2' "${d}/sweep-outcome.txt"
	grep -qx 'FAILED_BY=PROBE_FAILED x1, SETUP_FAILED x1' "${d}/sweep-outcome.txt"
	grep -qx 'SKIPPED=1' "${d}/sweep-outcome.txt"
	grep -qx 'SKIPPED_BY=SKIPPED_MEM_GUARD x1' "${d}/sweep-outcome.txt"
	run --separate-stderr bash -c 'set -euo pipefail; ROOT="$1"; source "$1/tests/lib/common.sh"
		sweep_outcome --record "$2" --md "$2/none.md" 5' _ "$ROOT" "$d"
	assert_success
	[ -z "$stderr" ]
	grep -qx 'FAILED=0' "${d}/sweep-outcome.txt"
	grep -qx 'SKIPPED=0' "${d}/sweep-outcome.txt"
}

@test "sweep_outcome --md more than once: every existing file gets the outcome, a missing one is skipped (R1)" {
	local d="${BATS_TEST_TMPDIR}/mds" f
	mkdir -p "$d"
	echo "# summary" > "${d}/sweep-x.md"
	echo "# envelope" > "${d}/scale-envelope-x.md"
	run --separate-stderr sweep_outcome --md "${d}/sweep-x.md" --md "${d}/missing.md" --md "${d}/scale-envelope-x.md" \
		--problem "the Istio version changed during the sweep (a: v1 at the start, v2 at the end)" 3
	assert_failure 4
	for f in "${d}/sweep-x.md" "${d}/scale-envelope-x.md"; do
		grep -qx '## Sweep outcome' "$f"
		grep -q '^- error: the Istio version changed during the sweep (a: v1 at the start, v2 at the end); exit 4\.$' "$f"
	done
	[ ! -e "${d}/missing.md" ]
	# The scale envelope's Istio row points at that section.
	grep -q 'the end-of-sweep read is under "Sweep outcome" below' "${ROOT}/tests/lib/envelope.sh"
	grep -q -- '--md "$MD_FILE" --md "$ENVELOPE_FILE"' "${ROOT}/tests/controlplane/003-run-sweep.sh"
}

@test "sweep_outcome record: RUN_ID, HARNESS_SHA and why it stopped; sweep_outcome_recorded repeats it for a re-generated report (X3)" {
	local d="${BATS_TEST_TMPDIR}/rec"
	mkdir -p "$d"
	harness_sha() { echo abc1234; }
	run --separate-stderr sweep_outcome --stopped 3 --stop-reason "the reachability gate found an unreachable remote" \
		--run-id 20261016T100000Z-1 --record "$d" --md "${d}/none.md" \
		--note "istiod/CNI not ready at the end of the sweep, same Istio version (a: its state is IstioCNINotHealthy)" 4
	assert_failure 3
	grep -qx 'RUN_ID=20261016T100000Z-1' "${d}/sweep-outcome.txt"
	grep -qx 'HARNESS_SHA=abc1234' "${d}/sweep-outcome.txt"
	grep -qx 'STOP_REASON=the reachability gate found an unreachable remote' "${d}/sweep-outcome.txt"
	echo 'PROBLEM=the Istio version changed during the sweep (a: v1 at the start, v2 at the end) "quoted"' >> "${d}/sweep-outcome.txt"
	run sweep_outcome_recorded "$d" text
	assert_line "SWEEP OUTCOME (recorded in sweep-outcome.txt by run 20261016T100000Z-1, exit 3):"
	assert_line '  error: the Istio version changed during the sweep (a: v1 at the start, v2 at the end) "quoted"'
	assert_line "  warning: istiod/CNI not ready at the end of the sweep, same Istio version (a: its state is IstioCNINotHealthy)"
	assert_line "  stopped early: the reachability gate found an unreachable remote"
	run sweep_outcome_recorded "$d" md
	assert_line '> **Sweep outcome** (recorded in `sweep-outcome.txt` by run `20261016T100000Z-1`, exit 3):'
	assert_line '> - error: the Istio version changed during the sweep (a: v1 at the start, v2 at the end) "quoted"'
	run sweep_outcome_recorded "$d" json
	[ "$(jq -c '[.exit, .run_id, .problems[0], (.notes | length), .stop_reason]' <<<"$output")" = \
		'[3,"20261016T100000Z-1","the Istio version changed during the sweep (a: v1 at the start, v2 at the end) \"quoted\"",1,"the reachability gate found an unreachable remote"]' ]
	# A stop with only its reason: the markdown line names it.
	echo "# r" > "${d}/r.md"
	run sweep_outcome --stopped 1 --stop-reason "REVERT_FAILED: reverting pass 01-x failed" --md "${d}/r.md" 2
	grep -qx -- '- The sweep stopped early (REVERT_FAILED: reverting pass 01-x failed); it exits 1.' "${d}/r.md"
	# No record: nothing in text or md, null in json; a clean record prints nothing either.
	run sweep_outcome_recorded "${d}/none" text
	assert_output ""
	run sweep_outcome_recorded "${d}/none" json
	assert_output null
	sweep_outcome --record "$d" 2 >/dev/null
	run sweep_outcome_recorded "$d" md
	assert_output ""
}

@test "sweep_outcome_recorded (Y5, Y9): failed cells, the record's run (warned when another), csv comment lines; the record's HARNESS_SHA is the sweep's" {
	local d="${BATS_TEST_TMPDIR}/sweep-20261016T100000Z-2"
	mkdir -p "$d"
	harness_sha() { echo live-tree; }
	# Y9: the record carries the HARNESS_SHA the sweep's TSVs record, not a fresh read.
	HARNESS_SHA=abc1234 run --separate-stderr sweep_outcome --run-id 20261016T100000Z-2 --record "$d" \
		--note "istiod or IstioCNI was not ready at the end of the sweep" 5 PROBE_FAILED SETUP_FAILED PROBE_FAILED
	assert_failure 4
	grep -qx 'HARNESS_SHA=abc1234' "${d}/sweep-outcome.txt"
	# Y5: exit 4 is shown with the cells that failed, not only the note under it.
	run --separate-stderr sweep_outcome_recorded "$d" text
	assert_line --index 0 "SWEEP OUTCOME (recorded in sweep-outcome.txt by run 20261016T100000Z-2, exit 4):"
	assert_line --index 1 "  error: 3 of 5 cells failed: PROBE_FAILED x2, SETUP_FAILED x1"
	assert_line --index 2 "  warning: istiod or IstioCNI was not ready at the end of the sweep"
	[ -z "$stderr" ]
	run sweep_outcome_recorded "$d" md
	assert_line '> - error: 3 of 5 cells failed: PROBE_FAILED x2, SETUP_FAILED x1'
	run sweep_outcome_recorded "$d" json
	[ "$(jq -c '[.exit, .failed, .failed_by]' <<<"$output")" = '[4,3,"PROBE_FAILED x2, SETUP_FAILED x1"]' ]
	run sweep_outcome_recorded "$d" csv
	assert_output "$(printf '%s\n' '# SWEEP_OUTCOME_RUN_ID=20261016T100000Z-2' '# SWEEP_OUTCOME_EXIT=4' '# SWEEP_OUTCOME_FAILED=3' \
		'# SWEEP_OUTCOME_FAILED_BY=PROBE_FAILED x2, SETUP_FAILED x1' '# SWEEP_OUTCOME_NOTE=istiod or IstioCNI was not ready at the end of the sweep')"
	# The report's run (config_check_multi_run's one sweep-* dir, or the argument): the same
	# run is silent; another run is named in every format and on stderr.
	MULTI_RUN_N=1 MULTI_RUN_IDS=sweep-20261016T100000Z-2 run --separate-stderr sweep_outcome_recorded "$d" text
	[ -z "$stderr" ]
	refute_output --partial "not from the run"
	MULTI_RUN_N=1 MULTI_RUN_IDS=sweep-20261016T100000Z-9 run --separate-stderr sweep_outcome_recorded "$d" text
	assert_line --index 1 "  warning: the record is from run 20261016T100000Z-2, not from the run this report reads (20261016T100000Z-9)"
	[[ "$stderr" == "warning: ${d}/sweep-outcome.txt was recorded by run 20261016T100000Z-2, not by this report's run 20261016T100000Z-9"* ]]
	run --separate-stderr sweep_outcome_recorded "$d" csv other-run
	assert_line "# WARNING: sweep-outcome.txt: the record is from run 20261016T100000Z-2, not from the run this report reads (other-run)"
	run --separate-stderr sweep_outcome_recorded "$d" json other-run
	[ "$(jq -r '.other_run' <<<"$output")" = other-run ]
	# A pooled report (several runs) compares nothing.
	MULTI_RUN_N=2 MULTI_RUN_IDS=sweep-a,sweep-b run --separate-stderr sweep_outcome_recorded "$d" text
	[ -z "$stderr" ]
	# No record: no csv lines either.
	run sweep_outcome_recorded "${d}/none" csv
	assert_output ""
}

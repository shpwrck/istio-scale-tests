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

#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

@test "die prints error: <message> to stderr and exits 1" {
	run --separate-stderr die "multiple words in message"
	assert_failure 1
	[ "$stderr" = "error: multiple words in message" ]
	[ -z "$output" ]
}

# --- split_csv() ---

@test "split_csv: values trimmed, an empty or whitespace-only item dropped (a trailing comma too), and an empty last item returns 0 under set -e" {
	local -a result=()
	split_csv "" result
	[[ ${#result[@]} -eq 0 ]]
	split_csv "alpha" result
	[[ "${result[*]}" == "alpha" ]]
	split_csv "a, b , c" result
	[[ ${#result[@]} -eq 3 && "${result[0]}" == a && "${result[1]}" == b && "${result[2]}" == c ]]
	split_csv "a, ,b," result
	[[ ${#result[@]} -eq 2 && "${result[0]}" == a && "${result[1]}" == b ]]
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

# --- the value checks ---

@test "is_pos_int, is_nonneg_int, is_ratio: whole numbers without a leading zero (0 only for nonneg), ratios in (0, 1]" {
	local v
	for v in 5 123; do is_pos_int "$v"; is_nonneg_int "$v"; done
	is_nonneg_int 0
	for v in 0 -1 abc "" 1.5 01; do
		run is_pos_int "$v"
		assert_failure
	done
	for v in -1 abc; do
		run is_nonneg_int "$v"
		assert_failure
	done
	for v in 0.95 1 1.0 .5 0.01; do is_ratio "$v"; done
	for v in 0 0.0 1.01 2 -0.5 abc 0.9x "" " 0.5" 1.; do
		run is_ratio "$v"
		assert_failure
	done
}

@test "validate_scoping and validate_traffic_config: a value outside the list is refused, naming the values it takes" {
	local v
	for v in none namespace explicit; do validate_scoping "$v"; done
	run validate_scoping "invalid"
	assert_failure 1
	assert_output --partial "none, namespace, explicit"
	for v in none vsdr; do validate_traffic_config "$v"; done
	for v in VSDR "" bogus; do
		run validate_traffic_config "$v"
		assert_failure 1
		assert_output --partial "--traffic-config must be one of [none, vsdr]"
	done
}

@test "vsdr_service_count: ceil(services / every), matching the chart's i mod every == 0; every < 1 or a non-integer count fails" {
	[[ "$(vsdr_service_count 10 1)" == 10 ]]
	[[ "$(vsdr_service_count 10 3)" == 4 ]]
	[[ "$(vsdr_service_count 9 3)" == 3 ]]
	[[ "$(vsdr_service_count 1 5)" == 1 ]]
	[[ "$(vsdr_service_count 0 2)" == 0 ]]
	run vsdr_service_count 10 0
	assert_failure 1
	run vsdr_service_count x 2
	assert_failure 1
}

@test "is_dns_label_for: a lowercase DNS label that fits the prefix in 63 characters; uppercase, too long, a leading digit, a trailing '-' or a '/' fails" {
	local ctx
	run is_dns_label_for dataplane-server- mesh-a
	assert_success
	# 46 chars + the 17-char prefix = 63, the limit.
	run is_dns_label_for dataplane-server- "a$(printf 'b%.0s' {1..45})"
	assert_success
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

# --- resolve_kubectl / timeout_cmd / run_timeout ---

# _in_path <dir> <fn> [args...]: run a common.sh function with PATH set to <dir> alone.
_in_path() {
	local d="$1"
	shift
	bash -c 'source "$ROOT/tests/lib/common.sh"; PATH="$1"; shift; "$@"' _ "$d" "$@"
}

@test "resolve_kubectl: kubectl when both CLIs exist, else oc with no extra flag, else it stops naming both" {
	local d="${BATS_TEST_TMPDIR}/bin" c
	mkdir -p "$d" "${BATS_TEST_TMPDIR}/empty"
	for c in kubectl oc; do
		printf '#!/bin/sh\nexit 0\n' > "${d}/${c}"
		chmod +x "${d}/${c}"
	done
	local -a kc=()
	PATH="$d" resolve_kubectl kc
	[[ "${kc[*]}" == "kubectl" ]]
	rm "${d}/kubectl"
	PATH="$d" resolve_kubectl kc
	[[ ${#kc[@]} -eq 1 && "${kc[0]}" == "oc" ]]
	PATH="${BATS_TEST_TMPDIR}/empty" run resolve_kubectl kc
	assert_failure 1
	assert_output "error: neither kubectl nor oc found on PATH"
}

@test "timeout_cmd / run_timeout: timeout, else gtimeout (macOS coreutils), else exit 127 with the install hint" {
	local d="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$d"
	printf '#!/bin/sh\necho "gtimeout $*"\n' > "${d}/gtimeout"
	chmod +x "${d}/gtimeout"
	run _in_path "$d" timeout_cmd
	assert_success
	assert_output gtimeout
	run _in_path "$d" run_timeout 5s echo hi
	assert_success
	assert_output "gtimeout --foreground 5s echo hi"
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

# --- each_bounded / kv_value / file_sha256 ---

@test "each_bounded: every item runs, at most <max> at a time, its stdout and stderr in files by its index (an item with a / too); a <max> that is no whole number above zero still runs them all" {
	_eb_one() {
		mkdir "${BATS_TEST_TMPDIR}/running/${2##*/}"
		find "${BATS_TEST_TMPDIR}/running" -mindepth 1 -maxdepth 1 | wc -l >> "${BATS_TEST_TMPDIR}/counts"
		sleep 0.1
		rmdir "${BATS_TEST_TMPDIR}/running/${2##*/}"
		echo "row of $1"
		echo "warn of $1" >&2
	}
	local t="${BATS_TEST_TMPDIR}/t" i
	local -a items=(a b/c d e f)
	mkdir -p "${BATS_TEST_TMPDIR}/running" "$t"
	each_bounded 2 _eb_one "$t" "${items[@]}"
	for i in "${!items[@]}"; do
		[ "$(cat "${t}/${i}.row")" = "row of ${items[i]}" ]
		[ "$(cat "${t}/${i}.warn")" = "warn of ${items[i]}" ]
	done
	[ "$(wc -l < "${BATS_TEST_TMPDIR}/counts")" -eq 5 ]
	[ "$(sort -n "${BATS_TEST_TMPDIR}/counts" | tail -n 1 | tr -d ' ')" -le 2 ]
	t="${BATS_TEST_TMPDIR}/t2"
	mkdir -p "$t"
	each_bounded x _eb_one "$t" a b c
	[ "$(cat "${t}"/*.row)" = $'row of a\nrow of b\nrow of c' ]
}

@test "kv_value: a key's value among k=v tokens (spaces, tabs or newlines), unknown without it, never a glob's match; file_sha256: the hex sum, unknown without a tool" {
	run kv_value mem_mi "cpu_m=100 mem_mi=2048"
	assert_output 2048
	run kv_value cpu_m $'mem_mi=1\ncpu_m=250\tx=y'
	assert_output 250
	# Another key that starts with it is not it; a value keeps its own =.
	run kv_value cpu "cpu_m=1 cpu=a=b"
	assert_output "a=b"
	run kv_value replicas "cpu_m=1"
	assert_output unknown
	run kv_value total ""
	assert_output unknown
	# A * token stays a token: a file named a=x in the working directory is no value of a.
	cd "$BATS_TEST_TMPDIR"
	: > "a=x"
	run kv_value a "*"
	assert_output unknown
	printf 'abc' > "${BATS_TEST_TMPDIR}/f"
	run file_sha256 "${BATS_TEST_TMPDIR}/f"
	assert_output ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
	mkdir -p "${BATS_TEST_TMPDIR}/empty"
	run _in_path "${BATS_TEST_TMPDIR}/empty" file_sha256 "${BATS_TEST_TMPDIR}/f"
	assert_output unknown
}

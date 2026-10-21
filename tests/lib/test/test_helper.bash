#!/usr/bin/env bash
# Shared test helper for bats-core tests of tests/lib/ functions.
# Sourced by every .bats file via: load test_helper

_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${_TEST_DIR}/../../.." && pwd)"
export ROOT

load "${_TEST_DIR}/bats-support/load.bash"
load "${_TEST_DIR}/bats-assert/load.bash"

source "${ROOT}/tests/lib/common.sh"

# platform_fixture_lines [ctxs_csv]: the platform record (tests/lib/platform.sh) a writer puts in
# a TSV preamble, as "# KEY=value" lines: Kubernetes members on kind running the Sail operator,
# with one istiod env digest and no tuning profile objects (members ctx-a,ctx-b unless named,
# or PLATFORM_FIXTURE_CTXS). Report fixtures add it so a report reads a current file; a legacy
# file (from before the record) leaves it out.
platform_fixture_lines() {
	local ctx p="" o="" i="" x="" n="" e="" j=""
	local -a ctxs=()
	split_csv "${1:-${PLATFORM_FIXTURE_CTXS:-ctx-a,ctx-b}}" ctxs
	for ctx in "${ctxs[@]}"; do
		p+="${p:+,}${ctx}=kubernetes"
		o+="${o:+,}${ctx}=sail-operator:1.31.1/Available"
		i+="${i:+,}${ctx}=pilot:1.30.5"
		x+="${x:+,}${ctx}=proxyv2:1.30.5"
		n+="${n:+,}${ctx}=kind"
		e+="${e:+,}${ctx}=0123456789ab"
		j+="${j:+,}${ctx}=none"
	done
	printf '# %s\n' PLATFORM=kubernetes TEST_PLATFORM=auto "PLATFORM_BY_CONTEXT=${p}" \
		"MESH_OPERATOR_BY_CONTEXT=${o}" "ISTIOD_IMAGE_BY_CONTEXT=${i}" "PROXY_IMAGE_BY_CONTEXT=${x}" \
		"NODE_PROVIDER_BY_CONTEXT=${n}" "ISTIOD_ENV_BY_CONTEXT=${e}" "TUNING_OBJECTS_BY_CONTEXT=${j}"
}

# wide_ctxs <n> [name...]: a CSV of n member names, the names given first, then campaign-like
# long ones; with PLATFORM_FIXTURE_CTXS it makes a record as wide as a fleet's (500 members: a
# record of about 220 KB, over Linux's 128 KiB limit on one argument or environment string).
wide_ctxs() {
	local n="$1" i m out=""
	shift
	for m in "$@"; do out+="${out:+,}${m}"; done
	for ((i = $# + 1; i <= n; i++)); do
		printf -v m 'scale-campaign-region-a-member-%03d.example.invalid' "$i"
		out+="${out:+,}${m}"
	done
	printf '%s\n' "$out"
}

# wide_record_report <report> <results dir> <format>...: the report on inputs whose record names
# 500 members (wide_ctxs; S-B2): every format succeeds and names the last member, and json lists
# all 500. Needs bats_require_minimum_version 1.5.0 (run --separate-stderr).
wide_record_report() {
	local report="$1" res="$2" fmt
	shift 2
	for fmt in "$@"; do
		run --separate-stderr "$report" --results-dir "$res" --format "$fmt"
		assert_success
		[[ "$stderr" != *"Argument list too long"* ]] || { echo "${fmt}: ${stderr}"; false; }
		assert_output --partial "scale-campaign-region-a-member-500.example.invalid"
		[[ "$fmt" != json ]] || [ "$(jq '.metadata | (.platform_by_context // .PLATFORM_BY_CONTEXT) | split(",") | length' <<<"$output")" = 500 ]
	done
}

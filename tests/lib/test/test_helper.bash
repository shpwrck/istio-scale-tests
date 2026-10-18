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
# a TSV preamble, as "# KEY=value" lines: Kubernetes members on kind running the Sail operator
# (members ctx-a,ctx-b unless named). Report fixtures add it so a report reads a current file; a
# legacy file (from before the record) leaves it out.
platform_fixture_lines() {
	local ctx p="" o="" i="" x="" n=""
	local -a ctxs=()
	split_csv "${1:-ctx-a,ctx-b}" ctxs
	for ctx in "${ctxs[@]}"; do
		p+="${p:+,}${ctx}=kubernetes"
		o+="${o:+,}${ctx}=sail-operator:1.31.1/Available"
		i+="${i:+,}${ctx}=pilot:1.30.5"
		x+="${x:+,}${ctx}=proxyv2:1.30.5"
		n+="${n:+,}${ctx}=kind"
	done
	printf '# %s\n' PLATFORM=kubernetes TEST_PLATFORM=auto "PLATFORM_BY_CONTEXT=${p}" \
		"MESH_OPERATOR_BY_CONTEXT=${o}" "ISTIOD_IMAGE_BY_CONTEXT=${i}" "PROXY_IMAGE_BY_CONTEXT=${x}" \
		"NODE_PROVIDER_BY_CONTEXT=${n}"
}

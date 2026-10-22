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
# with one istiod env digest (members ctx-a,ctx-b unless named, or PLATFORM_FIXTURE_CTXS). Report
# fixtures add it so a report reads a current file; a file from before the record leaves it out.
platform_fixture_lines() {
	local ctx p="" o="" i="" x="" n="" e=""
	local -a ctxs=()
	split_csv "${1:-${PLATFORM_FIXTURE_CTXS:-ctx-a,ctx-b}}" ctxs
	for ctx in "${ctxs[@]}"; do
		p+="${p:+,}${ctx}=kubernetes"
		o+="${o:+,}${ctx}=sail-operator:1.31.1"
		i+="${i:+,}${ctx}=pilot:1.30.5"
		x+="${x:+,}${ctx}=proxyv2:1.30.5"
		n+="${n:+,}${ctx}=kind"
		e+="${e:+,}${ctx}=0123456789ab"
	done
	printf '# %s\n' PLATFORM=kubernetes TEST_PLATFORM=auto "PLATFORM_BY_CONTEXT=${p}" \
		"MESH_OPERATOR_BY_CONTEXT=${o}" "ISTIOD_IMAGE_BY_CONTEXT=${i}" "PROXY_IMAGE_BY_CONTEXT=${x}" \
		"NODE_PROVIDER_BY_CONTEXT=${n}" "ISTIOD_ENV_BY_CONTEXT=${e}"
}

# help_shows_default <value> <name>...: the --help in $output shows the number <value> as the
# default of the flag or key <name> (any of the names given), whatever the layout: an entry that
# starts with the name (a line, with the lines it wraps onto) holds "default" (any case) and
# then <value> as a whole number.
help_shows_default() {
	local value="$1"
	shift
	printf '%s\n' "$output" | awk -v v="$value" -v names="$*" '
		BEGIN { k = split(names, want, " ") }
		function flush(   e, i, n, p, rest) {
			e = entry
			sub(/^ +/, "", e)
			sub(/^-[A-Za-z], */, "", e)
			for (i = 1; i <= k; i++) {
				n = want[i]
				if (substr(e, 1, length(n)) != n || substr(e, length(n) + 1, 1) ~ /[A-Za-z0-9_-]/) continue
				p = index(tolower(e), "default")
				if (!p) continue
				rest = substr(e, p + 7)
				sub(/^[^0-9]*/, "", rest)
				if (index(rest, v) == 1 && substr(rest, length(v) + 1, 1) !~ /[0-9]/) found = 1
			}
		}
		/^$/ || /^[^ ]/ || /^ *-/ || /^ *[A-Z][A-Z0-9_]+([ =:,]|$)/ { flush(); entry = $0; next }
		{ sub(/^ +/, " "); entry = entry $0 }
		END { flush(); exit !found }' ||
		{ echo "the help does not show ${value} as the default of $*"; return 1; }
}

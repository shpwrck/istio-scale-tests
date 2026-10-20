#!/usr/bin/env bats
# tests/lib/redact-results.sh through its real entrypoint (PL33) on the lines a controlplane
# sweep adds to its TSV: an INTERRUPTED cell row (the one status of 003's CELL_STATUS_RE
# without an underscore) passes the final scan of the context column, and a WINDOW_ROWS
# line keeps each entry's /<replicas> suffix while its member names map, a member named
# only there included. Names are placeholders (ci-a, ci-b, ci-c).

bats_require_minimum_version 1.5.0
load test_helper

REDACT="${ROOT}/tests/lib/redact-results.sh"

setup() {
	export TMPDIR="$BATS_TEST_TMPDIR"
	D="${BATS_TEST_TMPDIR}/sweep-r1"
	mkdir -p "$D"
	{
		printf '# RUN_ID=r1\n# ISTIO_VERSION_BY_CONTEXT=ci-a=v1.30.5,ci-b=v1.30.5\n'
		printf '# Contexts: ci-a ci-b  Mesh sizes: 2\n'
		printf 'timestamp\tcontext\tmesh_size\tservice_count\tistiod_mem_mi\n'
		printf '2026-10-18T05:12:33+00:00\tPROBE_FAILED\t2\t5\tN/A\n'
		printf '2026-10-18T05:12:37+00:00\tINTERRUPTED\t2\t5\tN/A\n'
		printf '2026-10-18T05:13:37+00:00\tci-a\t2\t5\t120\n'
		printf '2026-10-18T05:13:37+00:00\tci-b\t2\t5\t118\n'
		printf '# WINDOW_ROWS=ci-a=3/3,ci-b=2/3,ci-c=1\n'
		printf '# WINDOW_ROWS=ci-a=3,ci-b=3\n'
	} > "${D}/controlplane-r1.tsv"
}

@test "redact-results: a controlplane TSV with an INTERRUPTED row is written, the status kept" {
	run --separate-stderr "$REDACT" --out "${BATS_TEST_TMPDIR}/out" "$D"
	assert_success
	assert_output --partial "1 of 1 file(s) written under ${BATS_TEST_TMPDIR}/out, 0 refused"
	local c="${BATS_TEST_TMPDIR}/out/sweep-r1/controlplane-r1.tsv"
	[ "$(awk -F'\t' '$1 ~ /^2026/ { print $2 }' "$c" | paste -sd, -)" = "PROBE_FAILED,INTERRUPTED,<mesh-a-ctx>,<mesh-b-ctx>" ]
}

@test "redact-results: WINDOW_ROWS keeps each /<replicas> suffix, and a member it alone names is mapped too" {
	run --separate-stderr "$REDACT" --out "${BATS_TEST_TMPDIR}/out" "$D"
	assert_success
	[[ "$stderr" == *"<mesh-c-ctx>     ci-c"* ]] || { echo "$stderr"; false; }
	local c="${BATS_TEST_TMPDIR}/out/sweep-r1/controlplane-r1.tsv"
	[ "$(grep '^# WINDOW_ROWS=' "$c" | paste -sd'|' -)" = "# WINDOW_ROWS=<mesh-a-ctx>=3/3,<mesh-b-ctx>=2/3,<mesh-c-ctx>=1|# WINDOW_ROWS=<mesh-a-ctx>=3,<mesh-b-ctx>=3" ]
	run grep -cE '(^|[^A-Za-z0-9_<])ci-[abc]([^A-Za-z0-9_]|$)' "$c"
	assert_output 0
}

#!/usr/bin/env bats
# The scale envelope (render_scale_envelope in tests/lib/envelope.sh, which controlplane 003
# renders at a sweep's end) repeats each of 004's data warnings as one "> **Data warning:**"
# line in its header block, a warning's newlines flattened: here a cell on fewer istiod pods
# than wanted and one whose window had an istiod pod not Ready at its baseline; none without
# a warning. redact-results.sh maps the members they name. No cluster: fixture TSVs, and
# `false` for kubectl. Names are placeholders.

bats_require_minimum_version 1.5.0
load test_helper

REPORT="${ROOT}/tests/controlplane/004-report-results.sh"
FIXTURE="${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv"

setup() {
	source "${ROOT}/tests/lib/capacity.sh"
	source "${ROOT}/tests/lib/envelope.sh"
	source "${ROOT}/tests/lib/platform.sh"
}

@test "the scale envelope has one Data warning line per data warning of 004's json, after its header lines, and none without one; a redacted copy maps the members they name" {
	local a="${BATS_TEST_TMPDIR}/sweep-a" b="${BATS_TEST_TMPDIR}/sweep-b" w n
	mkdir -p "$a" "$b"
	# The fixture's first window: mesh-a ran 2 of its 3 istiod replicas, and mesh-b's
	# istiod-x was not Ready at its baseline.
	awk '!/^#/ && $1 != "timestamp" && !d++ { print "# ISTIOD_NOT_READY=mesh-b=istiod-x"; print "# WINDOW_ROWS=mesh-a=2/3,mesh-b=3/3" } { print }' \
		"$FIXTURE" > "${a}/controlplane-fixture-t2.tsv"
	cp "$FIXTURE" "${b}/controlplane-fixture-t2.tsv"
	run --separate-stderr "$REPORT" --results-dir "$a" --format json
	assert_success
	w="$(jq -r '.metadata.data_warnings[]' <<<"$output")"
	[ "$(grep -c . <<<"$w")" -eq 2 ] || { echo "$w"; false; }
	[[ "$w" == *"istiod-x on mesh-b"* && "$w" == *"not Ready at the window's baseline"* && "$w" == *"mesh-a ran 2 of its 3 istiod replicas"* ]]
	run --separate-stderr render_scale_envelope "$a" "$REPORT" "mesh-a,mesh-b" false
	assert_success
	printf '%s\n' "$output" > "${a}/scale-envelope-t2.md"
	# Each warning, in the order of the json, right after the header's second line.
	[ "$(grep -c '^> \*\*Data warning:\*\* ' <<<"$output")" -eq 2 ]
	n="$(grep -n '^> Measured columns are ' <<<"$output" | cut -d: -f1)"
	[ "$(sed -n "$((n + 1)),$((n + 2))p" <<<"$output")" = "$(sed 's/^/> **Data warning:** /' <<<"$w")" ] \
		|| { sed -n "1,$((n + 3))p" <<<"$output"; false; }
	# No data warning: no line.
	run --separate-stderr "$REPORT" --results-dir "$b" --format json
	assert_success
	[ "$(jq -c '.metadata.data_warnings' <<<"$output")" = '[]' ]
	run --separate-stderr render_scale_envelope "$b" "$REPORT" "mesh-a,mesh-b" false
	assert_success
	[[ "$output" == *"## Scale envelope"* && "$output" != *"Data warning"* ]]
	# The redacted copy names the members by placeholder only.
	export TMPDIR="$BATS_TEST_TMPDIR"
	run --separate-stderr "${ROOT}/tests/lib/redact-results.sh" --out "${BATS_TEST_TMPDIR}/red" "$a"
	assert_success
	w="$(grep '^> \*\*Data warning:\*\* ' "${BATS_TEST_TMPDIR}/red/sweep-a/scale-envelope-t2.md")"
	[[ "$w" == *"istiod-x on <mesh-b-ctx>"* && "$w" == *"<mesh-a-ctx> ran 2 of its 3 istiod replicas"* ]] || { echo "$w"; false; }
	run grep -cE '(^|[^A-Za-z0-9_<])mesh-[ab]([^A-Za-z0-9_]|$)' <<<"$w"
	assert_output 0
}

@test "the scale envelope flattens a data warning that holds a newline into its one line" {
	local d="${BATS_TEST_TMPDIR}/sweep-n" rep="${BATS_TEST_TMPDIR}/report.sh"
	mkdir -p "$d"
	# A report stand-in whose json holds one two-line data warning.
	jq -n '{metadata: {data_warnings: ["first part\nsecond part"]}, results: []}' > "${d}.json"
	printf '#!/bin/sh\ncat "%s"\n' "${d}.json" > "$rep"
	chmod +x "$rep"
	run --separate-stderr render_scale_envelope "$d" "$rep" "mesh-a" false
	assert_success
	assert_line "> **Data warning:** first part second part"
	[ "$(grep -c 'Data warning' <<<"$output")" -eq 1 ]
}

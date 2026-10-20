#!/usr/bin/env bats
# tests/lib/lint-bats-negation.sh: it flags a `! cmd` that is not a bats test's last command
# (bash exempts a negated pipeline from set -e and the ERR trap, so it never fails the test),
# passes `! cmd || false`, `|| fail` (bats-support), a trailing `! cmd` and `run ! cmd`, and
# the tree is clean; `|| flunk` (defined nowhere: exit 127) and a `! ` line inside a
# multi-line quoted script are flagged.

load test_helper
bats_require_minimum_version 1.5.0  # run !

@test "the lint flags a mid-test, in-loop or mid-helper ! cmd, || flunk and a line of a quoted script; passes || false, || fail, a trailing ! and run !; the tree is clean" {
	source "${ROOT}/tests/lib/lint-bats-negation.sh"
	local f="${BATS_TEST_TMPDIR}/bad.bats" g="${BATS_TEST_TMPDIR}/good.bats"
	cat > "$f" <<'EOF'
@test "mid-test" {
	! true
	true
}

@test "in a loop: only the last pass counts" {
	for x in a b; do
		! [ "$x" = a ]
	done
}

@test "in an if body: the if exempts it too" {
	if true; then
		! true
	fi
	true
}

_helper() {
	! grep -q x "$1"
	echo done
}

@test "continued, with only a comment after it" {
	! grep -q x \
		"$f"
	# a comment is not a command
	echo after
}

@test "an opening line with a comment" { # why
	! true
	true
}

@test "flunk is defined nowhere" {
	! true || flunk "no"
	true
}

@test "a quoted multi-line script is read as test lines" {
	run bash -c '
		! true
		echo after'
}
EOF
	run lint_bats_negation_file "$f"
	assert_failure
	[ "${#lines[@]}" -eq 8 ]
	assert_line --partial "bad.bats:2: a negated command that is not the test's last never fails it"
	assert_line --partial "bad.bats:8: "
	assert_line --partial "bad.bats:14: "
	assert_line --partial "bad.bats:20: "
	assert_line --partial "bad.bats:25: "
	assert_line --partial "bad.bats:32: "
	assert_line --partial "bad.bats:37: "
	assert_line --partial "bad.bats:43: "
	cat > "$g" <<'EOF'
@test "handed on, or last" {
	! true || false
	! true || fail "true"
	! grep -q x f || { echo "${f}: x"; false; }
	! grep -q x f || return 1
	run ! true
	[[ ! -e f ]]
	if ! true; then :; fi
	# ! true in a comment
	cat > stub <<'STUB'
! true
true
STUB
	cat > stub2 <<-EOS
	! true
	EOS
	! true
}

_helper() {
	true
	! grep -q x "$1"
}

@test "last, with a comment and a blank line before the close" {
	! true

	# trailing comment
}
EOF
	run lint_bats_negation_file "$g"
	assert_success
	assert_output ""
	run lint_bats_negation_paths "${ROOT}/tests"
	assert_success
	assert_output ""
}

@test "the lint's premise: bats does not fail a mid-test ! true, and does fail the three forms it passes" {
	local t="${BATS_TEST_TMPDIR}/premise.bats"
	cat > "$t" <<'EOF'
bats_require_minimum_version 1.5.0
@test "mid" {
	! true
	true
}
@test "or-false" {
	! true || false
	true
}
@test "run-bang" {
	run ! true
	true
}
@test "trailing" {
	! true
}
EOF
	run "${ROOT}/tests/lib/test/bats-core/bin/bats" --tap "$t"
	assert_failure
	assert_line "ok 1 mid"
	assert_line "not ok 2 or-false"
	assert_line "not ok 3 run-bang"
	assert_line "not ok 4 trailing"
}

#!/usr/bin/env bats
# Test stubs run as /bin/sh, which is dash on Debian and Ubuntu but bash on Fedora and macOS.
# POSIX leaves a pattern removal on $* or $@ unspecified: dash strips the joined string, bash
# strips each argument, so a stub that reads `${*##*--patch-file=}` finds its file under dash
# only. Join the arguments into a variable first.

bats_require_minimum_version 1.5.0
load test_helper

@test "test stubs never strip a pattern from \$* or \$@" {
	cd "$ROOT"
	run git grep -n -E '\$\{[*@][#%]' -- 'tests/lib/test/*.bats' 'tests/lib/test/*.bash' \
		'tests/lib/test/fixtures/*' ':!tests/lib/test/stub-sh-expansions.bats'
	assert_failure 1
	assert_output ""
}

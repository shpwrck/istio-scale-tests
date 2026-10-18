#!/usr/bin/env bash
# Fixture builders for the bats that run a suite's real scripts in a git checkout copied
# from this one (PL33). Loaded after test_helper (ROOT): load harness_helper

# _commit <dir> <message>: <dir> as a new git repository, everything in it committed.
_commit() {
	git -C "$1" init -q
	git -C "$1" add -A
	git -C "$1" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -q -m "$2"
}

# _suite_copy <dir> <suite>: a git checkout holding a copy of this one's config/,
# tests/lib/*.sh, tests/lib/test/fixtures/ and tests/<suite>/ (no results), committed.
_suite_copy() {
	local r="$1" s="$2"
	mkdir -p "$r/tests/lib/test"
	cp -R "${ROOT}/config" "$r/config"
	cp "${ROOT}"/tests/lib/*.sh "$r/tests/lib/"
	cp -R "${ROOT}/tests/lib/test/fixtures" "$r/tests/lib/test/fixtures"
	(cd "${ROOT}/tests" && tar -cf - --exclude=results --exclude='*.local.env' "$s") | (cd "$r/tests" && tar -xf -)
	cp "${ROOT}/.gitignore" "$r/.gitignore"
	_commit "$r" init
}

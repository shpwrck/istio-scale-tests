#!/usr/bin/env bash
# Fixture builders for the bats that need a git checkout of their own (sweep.bats:
# harness_sha). Loaded after test_helper: load harness_helper

# _commit <dir> <message>: <dir> as a new git repository, everything in it committed.
_commit() {
	git -C "$1" init -q
	git -C "$1" add -A
	git -C "$1" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -q -m "$2"
}

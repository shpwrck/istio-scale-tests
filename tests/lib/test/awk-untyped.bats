#!/usr/bin/env bats
# common.sh's awk check: gawk 5.2 and 5.3 corrupt an array element passed to a function before it
# holds a value (a later number read of it returns garbage; on 5.3 a later comparison stops awk),
# and the reports pass such elements. Sourcing common.sh with such an awk first on PATH runs awk as
# mawk when mawk passes the check, and stops otherwise. Stubs stand in for both awks, so the tests
# run the same on every host.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
	STUBS="${BATS_TEST_TMPDIR}/stubs"
	mkdir -p "$STUBS"
	# The awk a stub runs for anything but the check. Never the awk-mawk shim, which this file's
	# own sourcing of common.sh (test_helper) puts first on PATH when the host's awk fails the
	# check (gawk 5.2 on the Ubuntu CI runner): the shim runs mawk, a stub in two tests, and the
	# stub and the shim would run each other forever.
	REAL_AWK="$(command -v awk)"
	if [[ "$REAL_AWK" == */tests/lib/awk-mawk/awk ]]; then REAL_AWK="$(command -v mawk)"; fi
	export STUBS REAL_AWK
}

# stub <name> <probe exit>: <name> answers common.sh's check (the program that passes a[1] to a
# function) with <probe exit> (2 and gawk 5.3's message for a failing one), prints a gawk
# --version line, and runs the host's awk for anything else.
stub() {
	cat >"${STUBS}/$1" <<EOF
#!/bin/sh
case "\$1" in
*'f(a[1])'*) [ "$2" = 0 ] || echo 'gawk: fatal: internal error: file awk.h, line 2064: fixtype: expected Node_val: got Node_var' >&2; exit $2 ;;
--version) echo 'GNU Awk 5.3.2, API 4.0'; exit 0 ;;
esac
exec "${REAL_AWK}" "\$@"
EOF
	chmod +x "${STUBS}/$1"
}

@test "an awk that corrupts unset elements is replaced by mawk, for this shell and its children" {
	stub awk 2
	stub mawk 0
	run env PATH="${STUBS}:${PATH}" bash -c '
		source "$ROOT/tests/lib/common.sh"
		echo "awk=$(command -v awk)"
		bash -c "awk \"BEGIN { print \\\"child ok\\\" }\""'
	assert_success
	assert_line "awk=${ROOT}/tests/lib/awk-mawk/awk"
	assert_line "child ok"
}

@test "an awk that corrupts unset elements and no mawk that works: sourcing common.sh stops with the fix" {
	stub awk 2
	stub mawk 1
	run env PATH="${STUBS}:${PATH}" bash -c 'source "$ROOT/tests/lib/common.sh"; echo "not reached"'
	assert_failure 1
	assert_output --partial "error: awk on PATH (GNU Awk 5.3.2, API 4.0) corrupts an array element passed to a function before it holds a value (a gawk 5.2 and 5.3 bug)"
	assert_output --partial "Install mawk (dnf, apt or brew install mawk)"
	refute_output --partial "not reached"
}

@test "an awk that keeps unset elements intact is left first on PATH" {
	stub awk 0
	run env PATH="${STUBS}:${PATH}" bash -c 'source "$ROOT/tests/lib/common.sh"; command -v awk'
	assert_success
	assert_output "${STUBS}/awk"
}

@test "the host's awk and the mawk shim pass the check" {
	awk_untyped_ok awk
	if command -v mawk >/dev/null 2>&1; then awk_untyped_ok "$ROOT/tests/lib/awk-mawk/awk"; fi
}

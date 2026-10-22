#!/usr/bin/env bats
# tests/lib/lint-keyed-arith.sh, which verify.sh step 6 runs on the tree: it flags an array key
# that bash 4.3-5.1 expand twice ((( )), $(( )), let, [[ -gt ]] and -v on name[$k] and name["$k"]).

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr

@test "the lint flags (( )), \$(( )), let, [[ -gt ]] and -v on name[\$k] and name[\"\$k\"]; the safe forms pass; verify.sh's entrypoint reaches a .sh in a subdirectory (PL33)" {
	source "${ROOT}/tests/lib/lint-keyed-arith.sh"
	local f="${BATS_TEST_TMPDIR}/bad.sh" g="${BATS_TEST_TMPDIR}/good.sh"
	cat > "$f" <<'EOF'
(( count[$k] += 1 ))
n=$(( total["$k"] + 1 ))
let seen[$k]++
if [[ hits[$k] -gt 0 ]]; then :; fi
if [[ 0 -lt hits["$k"] ]]; then :; fi
[[ -v seen[$k] ]] && echo yes
test -v "seen[$k]"
while (( n < max[$k] )); do :; done
EOF
	run lint_keyed_arith_file "$f"
	assert_failure
	[ "${#lines[@]}" -eq 8 ]
	assert_line --partial "bad.sh:1: arithmetic (( ))"
	assert_line --partial "bad.sh:2: arithmetic (( ))"
	assert_line --partial "bad.sh:3: let"
	assert_line --partial "bad.sh:4: [[ -eq/-lt/... ]]"
	assert_line --partial "bad.sh:5: [[ -eq/-lt/... ]]"
	assert_line --partial "bad.sh:6: -v test"
	assert_line --partial "bad.sh:7: -v test"
	assert_line --partial "bad.sh:8: arithmetic (( ))"
	cat > "$g" <<'EOF'
# (( count[$k] += 1 )) in a comment
n="${count[$k]}"; count[$k]=$((n + 1))
(( ${#arr[@]} > 0 ))
(( i < ${#x[$k]} ))
[[ -n "${seen[$k]+x}" ]]
[[ "${hits[$k]}" -gt 0 ]]
(( arr[3] + i ))
let n++
EOF
	run lint_keyed_arith_file "$g"
	assert_success
	assert_output ""
	# What verify.sh step 6 runs: the files under a directory, a subdirectory's too.
	mkdir -p "${BATS_TEST_TMPDIR}/tree/suite"
	mv "$f" "$g" "${BATS_TEST_TMPDIR}/tree/suite/"
	run lint_keyed_arith_paths "${BATS_TEST_TMPDIR}/tree"
	assert_failure
	[ "${#lines[@]}" -eq 8 ]
	assert_line --partial "suite/bad.sh:8: arithmetic (( ))"
}

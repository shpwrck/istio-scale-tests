#!/usr/bin/env bats

load test_helper

setup() {
	source "${ROOT}/tests/lib/lint-bare-scrape.sh"
	FIX="$(mktemp -d)"
}

teardown() {
	rm -rf "$FIX"
}

# --- bare statement-position calls are FLAGGED ---

@test "lint flags a bare scrape_ctx call followed by an if" {
	cat > "$FIX/bad.sh" <<'EOF'
#!/usr/bin/env bash
scrape_ctx "$dir" "tick" "${ports[@]}" >/dev/null
if (( $(failed_count) > 0 )); then echo no; fi
EOF
	run lint_bare_scrape_file "$FIX/bad.sh"
	assert_failure
	assert_output --partial "bare call to scrape_ctx"
}

@test "lint flags a bare fanout_scrape_all call" {
	cat > "$FIX/bad.sh" <<'EOF'
#!/usr/bin/env bash
fanout_scrape_all "$polldir" "tick" "${ports[@]}" >/dev/null
echo next
EOF
	run lint_bare_scrape_file "$FIX/bad.sh"
	assert_failure
	assert_output --partial "bare call to fanout_scrape_all"
}

@test "lint flags a bare fanout_scrape_aggregate call" {
	cat > "$FIX/bad.sh" <<'EOF'
#!/usr/bin/env bash
fanout_scrape_aggregate "$polldir" "tick" hist "${ports[@]}" >/dev/null
echo next
EOF
	run lint_bare_scrape_file "$FIX/bad.sh"
	assert_failure
	assert_output --partial "bare call to fanout_scrape_aggregate"
}

# --- guarded / captured / condition / tail calls PASS ---

@test "lint passes a guarded scrape_ctx call (|| true)" {
	cat > "$FIX/good.sh" <<'EOF'
#!/usr/bin/env bash
scrape_ctx "$dir" "tick" "${ports[@]}" >/dev/null || true
if (( $(failed_count) > 0 )); then echo no; fi
EOF
	run lint_bare_scrape_file "$FIX/good.sh"
	assert_success
	[[ -z "$output" ]]
}

@test "lint passes a captured fanout_scrape_all call" {
	cat > "$FIX/good.sh" <<'EOF'
#!/usr/bin/env bash
skew="$(fanout_scrape_all "$dir" "pre" "${ports[@]}")"
echo "$skew"
EOF
	run lint_bare_scrape_file "$FIX/good.sh"
	assert_success
	[[ -z "$output" ]]
}

@test "lint passes a fanout_scrape_all used as an if condition" {
	cat > "$FIX/good.sh" <<'EOF'
#!/usr/bin/env bash
if ! fanout_scrape_all "$dir" "pre" "${ports[@]}"; then echo failed; fi
EOF
	run lint_bare_scrape_file "$FIX/good.sh"
	assert_success
	[[ -z "$output" ]]
}

@test "lint passes a function-tail fanout_scrape_all (return propagation)" {
	cat > "$FIX/good.sh" <<'EOF'
#!/usr/bin/env bash
scrape_ctx() {
	local dir="$1" prefix="$2"
	shift 2
	fanout_scrape_all "$dir" "$prefix" "$@"
}
EOF
	run lint_bare_scrape_file "$FIX/good.sh"
	assert_success
	[[ -z "$output" ]]
}

@test "lint ignores the function definition line itself" {
	cat > "$FIX/good.sh" <<'EOF'
#!/usr/bin/env bash
scrape_ctx() {
	echo hi
}
EOF
	run lint_bare_scrape_file "$FIX/good.sh"
	assert_success
}

@test "lint ignores comments mentioning a watched function" {
	cat > "$FIX/good.sh" <<'EOF'
#!/usr/bin/env bash
# fanout_scrape_all returns non-zero by design; capture it.
echo ok
EOF
	run lint_bare_scrape_file "$FIX/good.sh"
	assert_success
}

# --- the real repo tree must stay clean ---

@test "lint passes on the live tests/ tree" {
	run lint_bare_scrape_paths "${ROOT}/tests"
	assert_success
}

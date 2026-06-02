#!/usr/bin/env bats

load test_helper
source "${ROOT}/tests/lib/timestamp.sh"

# --- _detect_now_ns() ---

@test "_detect_now_ns: sets NOW_NS_IMPL to a known backend" {
	NOW_NS_IMPL=""
	_detect_now_ns
	[[ "$NOW_NS_IMPL" =~ ^(date|gdate|python3|perl)$ ]]
}

@test "_detect_now_ns: caches result on second call" {
	NOW_NS_IMPL=""
	_detect_now_ns
	local first="$NOW_NS_IMPL"
	_detect_now_ns
	[[ "$NOW_NS_IMPL" == "$first" ]]
}

# --- now_ns() ---

@test "now_ns: output is numeric" {
	local result
	result=$(now_ns)
	[[ "$result" =~ ^[0-9]+$ ]]
}

@test "now_ns: output is plausible epoch nanoseconds" {
	local result
	result=$(now_ns)
	# Should be at least 1e18 (year ~2001) and less than 2e18 (year ~2033)
	(( result > 1000000000000000000 ))
	(( result < 2000000000000000000 ))
}

# --- now_ms() ---

@test "now_ms: output is numeric" {
	local result
	result=$(now_ms)
	[[ "$result" =~ ^[0-9]+$ ]]
}

@test "now_ms: output is 13 digits (millisecond epoch)" {
	local result
	result=$(now_ms)
	[[ ${#result} -eq 13 ]]
}

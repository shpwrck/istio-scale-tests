#!/usr/bin/env bats

load test_helper
source "${ROOT}/tests/lib/timestamp.sh"

@test "now_ns is epoch nanoseconds and now_ms epoch milliseconds, from a backend _detect_now_ns finds" {
	NOW_NS_IMPL=""
	_detect_now_ns
	[[ "$NOW_NS_IMPL" =~ ^(date|gdate|python3|perl)$ ]]
	local ns ms
	ns=$(now_ns)
	ms=$(now_ms)
	[[ "$ns" =~ ^[0-9]+$ && "$ms" =~ ^[0-9]+$ ]]
	# At least 1e18 (year ~2001) and less than 2e18 (year ~2033); 13 digits of milliseconds.
	(( ns > 1000000000000000000 && ns < 2000000000000000000 ))
	[[ ${#ms} -eq 13 ]]
}

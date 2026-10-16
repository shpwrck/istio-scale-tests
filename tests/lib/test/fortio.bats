#!/usr/bin/env bats
# tests/lib/fortio.sh: fortio -json parsing and the dataplane row status.

load test_helper
source "${ROOT}/tests/lib/fortio.sh"

FX="${ROOT}/tests/lib/test/fixtures"

setup() {
	OK_JSON="$(cat "${FX}/fortio_ok.json")"
	SAT_JSON="$(cat "${FX}/fortio_saturated_200.json")"
	ERR_JSON="$(cat "${FX}/fortio_errors.json")"
	NOPCT_JSON="$(cat "${FX}/fortio_no_percentiles.json")"
}

# --- fortio_percentile_ms ---

@test "fortio_percentile_ms: matches 50 against 50.0 and converts s -> ms" {
	run fortio_percentile_ms "$OK_JSON" 50
	assert_success
	assert_output "1.82"
}

@test "fortio_percentile_ms: 99.9 is found" {
	run fortio_percentile_ms "$OK_JSON" 99.9
	assert_output "11.2"
}

@test "fortio_percentile_ms: missing percentile list -> N/A" {
	run fortio_percentile_ms "$NOPCT_JSON" 50
	assert_success
	assert_output "N/A"
}

@test "fortio_percentile_ms: unrequested percentile -> N/A" {
	run fortio_percentile_ms "$OK_JSON" 75
	assert_output "N/A"
}

@test "fortio_percentile_ms: invalid JSON -> N/A" {
	run fortio_percentile_ms "not json" 50
	assert_success
	assert_output "N/A"
}

# --- fortio_max_ms / fortio_actual_qps ---

@test "fortio_max_ms: Max in ms; missing or invalid -> N/A, never a 0 latency" {
	run fortio_max_ms "$OK_JSON"
	assert_output "12.5"
	run fortio_max_ms '{}'
	assert_output "N/A"
	run fortio_max_ms '{"DurationHistogram": {"Count": 0}}'
	assert_output "N/A"
	run fortio_max_ms "not json"
	assert_success
	assert_output "N/A"
}

@test "fortio_actual_qps: ActualQPS; missing or invalid -> N/A, never 0 QPS" {
	run fortio_actual_qps "$SAT_JSON"
	assert_output "686.2"
	run fortio_actual_qps '{}'
	assert_output "N/A"
	run fortio_actual_qps "not json"
	assert_success
	assert_output "N/A"
	# A real 0 stays 0.
	run fortio_actual_qps '{"ActualQPS": 0}'
	assert_output "0"
}

@test "fortio_row_status: a run without ActualQPS cannot show delivery -> QPS_SHORTFALL" {
	json="$(jq -c 'del(.ActualQPS)' <<<"$OK_JSON")"
	run fortio_row_status "$json" 1000 0.95 0.99
	assert_output "QPS_SHORTFALL"
}

# --- fortio_pct_200 / fortio_n_responses / fortio_ret_codes ---

@test "fortio_pct_200: all 200s -> 1" {
	run fortio_pct_200 "$OK_JSON"
	assert_output "1"
}

@test "fortio_pct_200: 19000 of 20600 -> 0.9223..." {
	run fortio_pct_200 "$ERR_JSON"
	assert_output "0.9223300970873787"
}

@test "fortio_pct_200: no RetCodes -> N/A" {
	run fortio_pct_200 '{"RetCodes": {}}'
	assert_output "N/A"
	run fortio_pct_200 '{}'
	assert_output "N/A"
}

@test "fortio_n_responses: sums every code; none -> 0" {
	run fortio_n_responses "$ERR_JSON"
	assert_output "20600"
	run fortio_n_responses '{"RetCodes": {}}'
	assert_output "0"
}

@test "fortio_ret_codes: numeric order, socket errors (-1) first" {
	run fortio_ret_codes "$ERR_JSON"
	assert_output "-1=20,200=19000,503=1580"
}

@test "fortio_ret_codes: none -> N/A; invalid JSON -> N/A" {
	run fortio_ret_codes '{"RetCodes": {}}'
	assert_output "N/A"
	run fortio_ret_codes "not json"
	assert_success
	assert_output "N/A"
}

# --- fortio_row_status: precedence PERCENTILE_MISSING > ERROR_RATE_HIGH > QPS_SHORTFALL > OK ---

@test "fortio_row_status: delivered target with all 200s -> OK" {
	run fortio_row_status "$OK_JSON" 1000 0.95 0.99
	assert_output "OK"
}

@test "fortio_row_status: all 200s but 686/1000 QPS -> QPS_SHORTFALL" {
	run fortio_row_status "$SAT_JSON" 1000 0.95 0.99
	assert_output "QPS_SHORTFALL"
}

@test "fortio_row_status: same run against a 500 target is OK (686 >= 475)" {
	run fortio_row_status "$SAT_JSON" 500 0.95 0.99
	assert_output "OK"
}

@test "fortio_row_status: errors win over shortfall" {
	run fortio_row_status "$ERR_JSON" 1000 0.95 0.99
	assert_output "ERROR_RATE_HIGH"
}

@test "fortio_row_status: the pct_200 threshold is the caller's" {
	# 0.922 passes a 0.9 threshold, then the shortfall check applies.
	run fortio_row_status "$ERR_JSON" 1000 0.95 0.9
	assert_output "QPS_SHORTFALL"
	run fortio_row_status "$ERR_JSON" 700 0.95 0.9
	assert_output "OK"
}

@test "fortio_row_status: missing percentiles win over everything" {
	run fortio_row_status "$NOPCT_JSON" 1000 0.95 0.99
	assert_output "PERCENTILE_MISSING"
}

@test "fortio_row_status: zero responses -> ERROR_RATE_HIGH" {
	json="$(jq -c '.RetCodes = {}' <<<"$OK_JSON")"
	run fortio_row_status "$json" 1000 0.95 0.99
	assert_output "ERROR_RATE_HIGH"
}

@test "fortio_row_status: exactly ratio x target is OK (strict <)" {
	json="$(jq -c '.ActualQPS = 950' <<<"$OK_JSON")"
	run fortio_row_status "$json" 1000 0.95 0.99
	assert_output "OK"
	json="$(jq -c '.ActualQPS = 949.9' <<<"$OK_JSON")"
	run fortio_row_status "$json" 1000 0.95 0.99
	assert_output "QPS_SHORTFALL"
}

@test "fortio_row_status: ratio 0 disables the shortfall check" {
	run fortio_row_status "$SAT_JSON" 1000 0 0.99
	assert_output "OK"
}

@test "fortio_row_status: non-numeric or zero target skips the shortfall check" {
	run fortio_row_status "$SAT_JSON" max 0.95 0.99
	assert_output "OK"
	run fortio_row_status "$SAT_JSON" 0 0.95 0.99
	assert_output "OK"
}

@test "fortio_row_status: invalid JSON -> PERCENTILE_MISSING" {
	run fortio_row_status "not json" 1000 0.95 0.99
	assert_success
	assert_output "PERCENTILE_MISSING"
}

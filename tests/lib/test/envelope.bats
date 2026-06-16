#!/usr/bin/env bats

load test_helper
source "${ROOT}/tests/lib/capacity.sh"
source "${ROOT}/tests/lib/envelope.sh"

# ---------------------------------------------------------------------------
# env_parse_istiod_resources — req AND lim kept distinct (cap_parse_istiod_limits
# collapses them; the envelope needs both).
# ---------------------------------------------------------------------------

@test "env_parse_istiod_resources: req and lim distinct, cores+Gi convert" {
	run env_parse_istiod_resources <<'JSON'
{"spec":{"replicas":5,"template":{"spec":{"containers":[
  {"name":"discovery","resources":{
     "requests":{"cpu":"1","memory":"2Gi"},
     "limits":{"cpu":"4","memory":"8Gi"}}}
]}}}}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "req_cpu_m=1000 req_mem_mi=2048 lim_cpu_m=4000 lim_mem_mi=8192 replicas=5" ]]
}

@test "env_parse_istiod_resources: missing limits -> lim unknown, req still read" {
	run env_parse_istiod_resources <<'JSON'
{"spec":{"replicas":1,"template":{"spec":{"containers":[
  {"name":"discovery","resources":{"requests":{"cpu":"500m","memory":"512Mi"}}}
]}}}}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "req_cpu_m=500 req_mem_mi=512 lim_cpu_m=unknown lim_mem_mi=unknown replicas=1" ]]
}

@test "env_parse_istiod_resources: no istiod container -> all unknown" {
	run env_parse_istiod_resources <<<'{"spec":{"template":{"spec":{"containers":[{"name":"other"}]}}}}'
	[ "$status" -eq 0 ]
	[[ "$output" == "req_cpu_m=unknown req_mem_mi=unknown lim_cpu_m=unknown lim_mem_mi=unknown replicas=unknown" ]]
}

@test "env_parse_istiod_resources: empty stdin -> all unknown (no crash)" {
	run env_parse_istiod_resources <<<''
	[ "$status" -eq 0 ]
	[[ "$output" == "req_cpu_m=unknown req_mem_mi=unknown lim_cpu_m=unknown lim_mem_mi=unknown replicas=unknown" ]]
}

# ---------------------------------------------------------------------------
# env_parse_network — ISTIO_META_NETWORK / NETWORK_ID env injection.
# ---------------------------------------------------------------------------

@test "env_parse_network: reads ISTIO_META_NETWORK" {
	run env_parse_network <<'JSON'
{"spec":{"template":{"spec":{"containers":[
  {"name":"discovery","env":[{"name":"ISTIO_META_NETWORK","value":"cluster-a-network"}]}
]}}}}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "network=cluster-a-network" ]]
}

@test "env_parse_network: no network env -> unknown" {
	run env_parse_network <<<'{"spec":{"template":{"spec":{"containers":[{"name":"discovery","env":[]}]}}}}'
	[ "$status" -eq 0 ]
	[[ "$output" == "network=unknown" ]]
}

# ---------------------------------------------------------------------------
# env_pct_of_limit — PL35 cross-replica scope. The R>1 path is the regression:
# a single-replica fixture hides the per-replica-vs-cross-replica bug.
# ---------------------------------------------------------------------------

@test "env_pct_of_limit: R=1 (per-replica == cross-replica)" {
	# used=400m, limit=8000m/replica, 1 replica -> 5%
	run env_pct_of_limit 400 8000 1
	[ "$status" -eq 0 ]
	[[ "$output" == "5" ]]
}

@test "env_pct_of_limit: R=5 cross-replica denominator (PL35 regression)" {
	# used=2000m (sum across 5 replicas), per-replica limit=8000m, 5 replicas.
	# CORRECT: 2000 / (8000*5) = 5%. The bug (per-replica denom) would read 25%.
	run env_pct_of_limit 2000 8000 5
	[ "$status" -eq 0 ]
	[[ "$output" == "5" ]]
}

@test "env_pct_of_limit: idle 5-replica plane does not read ~R*100%" {
	# Idle: used ~= 5*50m = 250m total, per-replica limit 2000m, 5 replicas.
	# 250 / 10000 = 2.5% -> rounds to 3 (NOT ~125% the per-replica bug produces).
	run env_pct_of_limit 250 2000 5
	[ "$status" -eq 0 ]
	[ "$output" -lt 10 ]
}

@test "env_pct_of_limit: unknown input -> unknown" {
	run env_pct_of_limit unknown 8000 5
	[[ "$output" == "unknown" ]]
	run env_pct_of_limit 400 8000 0
	[[ "$output" == "unknown" ]]
}

# ---------------------------------------------------------------------------
# env_sla_verdict — PASS / CAUTION / FAIL.
# args: icpu imem ncpu nmem restarts n_total n_valid
# ---------------------------------------------------------------------------

@test "env_sla_verdict: PASS when all utilization < 75 and clean" {
	run env_sla_verdict 10 20 30 40 0 12 12
	[ "$status" -eq 0 ]
	[[ "$output" == PASS\|* ]]
}

@test "env_sla_verdict: CAUTION at 75-90 utilization" {
	run env_sla_verdict 80 20 30 40 0 12 12
	[[ "$output" == CAUTION\|* ]]
}

@test "env_sla_verdict: FAIL at >=90 utilization" {
	run env_sla_verdict 95 20 30 40 0 12 12
	[[ "$output" == FAIL\|* ]]
}

@test "env_sla_verdict: FAIL on an in-window restart (dominates utilization PASS)" {
	run env_sla_verdict 10 20 30 40 2 12 10
	[[ "$output" == FAIL\|* ]]
	[[ "$output" == *restart* ]]
}

@test "env_sla_verdict: FAIL when no valid samples survived" {
	run env_sla_verdict unknown unknown unknown unknown 0 6 0
	[[ "$output" == FAIL\|* ]]
}

@test "env_sla_verdict: CAUTION when a utilization signal is unknown (metrics gap)" {
	run env_sla_verdict 10 unknown 30 40 0 12 12
	[[ "$output" == CAUTION\|* ]]
}

@test "env_sla_verdict: CAUTION when some samples filtered (n_valid < n_total)" {
	run env_sla_verdict 10 20 30 40 0 12 9
	[[ "$output" == CAUTION\|* ]]
}

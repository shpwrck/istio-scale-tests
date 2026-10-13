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

# env_network: Istio 1.2x+ sets the network only as the istio-system namespace
# label, so the wrapper falls back to it when the istiod env has none.
_net_kubectl() {
	case "$*" in
		*"get deploy istiod"*) echo '{"spec":{"template":{"spec":{"containers":[{"name":"discovery","env":[]}]}}}}' ;;
		*"get namespace istio-system"*) printf '%s' "${NET_LABEL:-}" ;;
	esac
}

@test "env_network: falls back to the istio-system network label" {
	NET_LABEL=net-a run env_network ctx-a _net_kubectl
	[ "$status" -eq 0 ]
	[[ "$output" == "network=net-a" ]]
}

@test "env_network: no env and no label -> unknown" {
	NET_LABEL="" run env_network ctx-a _net_kubectl
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

# F1: bands default from SCALE_SLA_CAUTION_PCT / SCALE_SLA_FAIL_PCT (env), overridable
# as args 8/9 so the function stays pure / unit-testable.

@test "env_sla_verdict: bands read from env (SCALE_SLA_*_PCT)" {
	# 60% utilization: PASS at default 75, but CAUTION if the env caution band drops to 50.
	SCALE_SLA_CAUTION_PCT=50 SCALE_SLA_FAIL_PCT=90 run env_sla_verdict 60 20 30 40 0 12 12
	[[ "$output" == CAUTION\|* ]]
	SCALE_SLA_CAUTION_PCT=75 SCALE_SLA_FAIL_PCT=90 run env_sla_verdict 60 20 30 40 0 12 12
	[[ "$output" == PASS\|* ]]
}

@test "env_sla_verdict: explicit threshold args 8/9 override env" {
	# 60% utilization, args force fail band to 55 -> FAIL regardless of env.
	SCALE_SLA_CAUTION_PCT=75 SCALE_SLA_FAIL_PCT=90 run env_sla_verdict 60 20 30 40 0 12 12 40 55
	[[ "$output" == FAIL\|* ]]
}

@test "env_sla_verdict: default bands resolve to 75/90 when env unset" {
	run env_sla_verdict 80 20 30 40 0 12 12
	[[ "$output" == CAUTION\|* ]]
	[[ "$output" == *"[75,90)"* ]]
}

# ---------------------------------------------------------------------------
# istiod replicas over every context. Members can run different replica counts,
# and the per-replica proxy figure is about 1/R of the cluster figure, so R must
# not come from the first context alone.
# ---------------------------------------------------------------------------

@test "env_replicas_summary: one number when uniform, min-max when not, unknown when none read" {
	run env_replicas_summary 3 3 3
	assert_output "3"
	run env_replicas_summary 3 1 2
	assert_output "1-3"
	# A failed read is left out of the range (ISTIOD_REPLICAS_BY_CONTEXT names it).
	run env_replicas_summary 3 unknown
	assert_output "3"
	run env_replicas_summary unknown unknown
	assert_output "unknown"
	run env_replicas_summary
	assert_output "unknown"
	run env_replicas_summary 10 9
	assert_output "9-10"
}

@test "env_replicas_label: per cluster, varies by cluster, first context only, not read" {
	run env_replicas_label 3 "a=3,b=3"
	assert_output "3 per cluster"
	run env_replicas_label 1-3 "a=1,b=3"
	assert_output "1-3 per cluster (varies by cluster)"
	# An INFRA_SCHEMA 1 TSV: one number, no ISTIOD_REPLICAS_BY_CONTEXT.
	run env_replicas_label 3 unknown
	assert_output "3 (first context only)"
	run env_replicas_label 3
	assert_output "3 (first context only)"
	run env_replicas_label 3 "a=3,b=unknown"
	assert_output "3 per cluster; not read on 1 of 2 contexts"
	run env_replicas_label unknown "a=unknown"
	assert_output "unknown"
}

# Fake kubectl for the per-context scan: mesh-a runs 1 istiod replica with its own
# requests/limits, mesh-b 3, mesh-c cannot be read.
_rep_kubectl() {
	local ctx="" a
	for a in "$@"; do [[ "$a" == --context=* ]] && ctx="${a#--context=}"; done
	case "$ctx" in
	mesh-a) echo '{"spec":{"replicas":1,"template":{"spec":{"containers":[{"name":"discovery","resources":{"requests":{"cpu":"500m","memory":"2Gi"},"limits":{"cpu":"2","memory":"4Gi"}}}]}}}}' ;;
	mesh-b) echo '{"spec":{"replicas":3,"template":{"spec":{"containers":[{"name":"discovery","resources":{"requests":{"cpu":"1","memory":"1Gi"},"limits":{"cpu":"4","memory":"8Gi"}}}]}}}}' ;;
	*) return 1 ;;
	esac
}

@test "env_istiod_scan: req/lim from the first context, replicas from every context" {
	run env_istiod_scan "mesh-a,mesh-b,mesh-c" _rep_kubectl
	assert_success
	assert_output "req_cpu_m=500 req_mem_mi=2048 lim_cpu_m=2000 lim_mem_mi=4096 replicas=1-3 replicas_by_context=mesh-a=1,mesh-b=3,mesh-c=unknown"
	run env_istiod_scan "mesh-b,mesh-b" _rep_kubectl
	assert_output --partial "replicas=3 replicas_by_context=mesh-b=3,mesh-b=3"
	run env_istiod_scan "" _rep_kubectl
	assert_output "req_cpu_m=unknown req_mem_mi=unknown lim_cpu_m=unknown lim_mem_mi=unknown replicas=unknown replicas_by_context=unknown"
}

@test "env_collect_infra: ISTIOD_REPLICAS is the range over every context, with the per-context list" {
	run env_collect_infra "mesh-a,mesh-b" _rep_kubectl
	assert_success
	assert_output --partial "ISTIOD_REPLICAS=1-3 ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=1,mesh-b=3 "
	assert_output --partial "ISTIOD_LIM_CPU_M=2000"
	# Fed to the shared emitter, both keys reach the preamble (PL36).
	source "${ROOT}/tests/lib/preamble.sh"
	# shellcheck disable=SC2086
	run infra_preamble_lines $output
	assert_line "# ISTIOD_REPLICAS=1-3"
	assert_line "# ISTIOD_REPLICAS_BY_CONTEXT=mesh-a=1,mesh-b=3"
}

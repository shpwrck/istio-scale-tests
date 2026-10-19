#!/usr/bin/env bats

bats_require_minimum_version 1.5.0  # run --separate-stderr
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

# H4: kind nodes report the shared host, so the verdict leaves their figures out.
@test "env_sla_verdict --nodes-excluded: CAUTION with the reason even when every figure is low" {
	run env_sla_verdict --nodes-excluded "the nodes are kind's" 10 20 30 40 0 12 12
	assert_success
	assert_output "CAUTION|node figures left out: the nodes are kind's; the figures: peak utilization 20% < 75% across istiod, no restarts, all 12 samples valid"
	# Node figures that would fail, or are unknown, do not count; istiod's still do.
	run env_sla_verdict --nodes-excluded kind 10 20 95 99 0 12 12
	assert_output "CAUTION|node figures left out: kind; the figures: peak utilization 20% < 75% across istiod, no restarts, all 12 samples valid"
	run env_sla_verdict --nodes-excluded kind 10 20 unknown unknown 0 12 12
	[[ "$output" == "CAUTION|node figures left out: kind; the figures: peak utilization 20%"* ]]
	run env_sla_verdict --nodes-excluded kind 95 20 30 40 0 12 12
	assert_output "FAIL|peak utilization 95% >= 90% — at/over a resource limit; also node figures left out: kind"
	run env_sla_verdict --nodes-excluded kind 10 20 30 40 2 12 10
	[[ "$output" == FAIL\|*"restart"*"; also node figures left out: kind" ]]
	# The bands still come from args 8/9 after the option.
	run env_sla_verdict --nodes-excluded kind 60 20 30 40 0 12 12 40 55
	[[ "$output" == FAIL\|* ]]
}

@test "env_sla_verdict without --nodes-excluded: node figures count as before" {
	run env_sla_verdict 10 20 30 40 0 12 12
	assert_output "PASS|peak utilization 40% < 75% across istiod + nodes, no restarts, all 12 samples valid"
	run env_sla_verdict 10 20 95 40 0 12 12
	[[ "$output" == FAIL\|* ]]
	run env_sla_verdict 10 20 30 unknown 0 12 12
	[[ "$output" == CAUTION\|*"metrics API gap"* ]]
}

# fake_cp_report <file> <warnings JSON array>: a controlplane report stand-in whose JSON carries
# the platform record of two kind members (one on another istiod build) and those warnings.
fake_cp_report() {
	local da db dc
	da="sha256:$(printf 'a%.0s' {1..64})" db="sha256:$(printf 'b%.0s' {1..64})" dc="sha256:$(printf 'c%.0s' {1..64})"
	cat > "$1" <<SH
#!/usr/bin/env bash
cat <<'JSON'
{"metadata":{"run_id":"r","istio_version":"v1.30.5","harness_sha":"abc","platform":"kubernetes","test_platform":"auto",
"node_provider_by_context":"mesh-a=kind,mesh-b=kind",
"mesh_operator_by_context":"mesh-a=sail-operator:1.31.1@${da}/Available,mesh-b=sail-operator:1.31.1@${da}/Available",
"istiod_image_by_context":"mesh-a=pilot:1.30.5@${db},mesh-b=mixed:pilot:1.30.5@${db};pilot:1.30.6@${dc}",
"proxy_image_by_context":"mesh-a=proxyv2:1.30.5@${dc},mesh-b=proxyv2:1.30.5@${dc}",
"istiod_env_by_context":"mesh-a=0123456789ab,mesh-b=0123456789ab",
"capacity":{"node_alloc_cpu_m":"4000","node_alloc_mem_mi":"16093"},
"achieved_scale":{"connected_proxies_max":"10","connected_proxies_cluster_max":"10","istiod_cpu_peak_pct_of_limit_max":"20","istiod_cpu_pct_of_limit_max":"10","istiod_mem_pct_of_limit_max":"30","istiod_rss_pct_of_limit_max":"30","node_cpu_pct_max":"28","node_mem_pct_max":"35"},
"sla":{"verdict":"CAUTION","headline":"node figures left out: the nodes are kind's"},
"data_warnings":${2}},
"results":[{"mesh_size":2,"service_count":10,"replicas":1,"namespace_count":1,"sidecar_scoping":"none","n_valid":1}]}
JSON
SH
	chmod +x "$1"
}

@test "render_scale_envelope (H4): every data warning above the tables and the verdict; a Platform / mesh build row without member names" {
	source "${ROOT}/tests/lib/platform.sh"
	local d="${BATS_TEST_TMPDIR}/sweep-r" rep="${BATS_TEST_TMPDIR}/fake-report.sh" w1 w2 t1 v
	mkdir -p "$d"
	fake_cp_report "$rep" '["Nodes on kind (NODE_PROVIDER_BY_CONTEXT): every node reports the whole host'"'"'s CPU and memory","input TSVs disagree on ISTIOD_IMAGE_BY_CONTEXT for 1 of 2 members: the report mixes runs on different istiod builds; compare like with like"]'
	run --separate-stderr render_scale_envelope "$d" "$rep" "mesh-a,mesh-b" false
	assert_success
	assert_output --partial "> **Warning:** Nodes on kind (NODE_PROVIDER_BY_CONTEXT): every node reports the whole host's CPU and memory"
	assert_output --partial "> **Warning:** input TSVs disagree on ISTIOD_IMAGE_BY_CONTEXT for 1 of 2 members"
	w1="$(grep -n '^> \*\*Warning:\*\* Nodes on kind' <<<"$output" | cut -d: -f1)"
	w2="$(grep -n '^> \*\*Warning:\*\* input TSVs disagree' <<<"$output" | cut -d: -f1)"
	t1="$(grep -n '^### 1\. Mesh topology' <<<"$output" | cut -d: -f1)"
	v="$(grep -n '^> \*\*CAUTION\*\*' <<<"$output" | cut -d: -f1)"
	((w1 < w2 && w2 < t1 && t1 < v)) || { echo "warnings at ${w1} and ${w2}, topology at ${t1}, verdict at ${v}"; false; }
	# H17: ", " between the groups, " and " between a mixed member's builds, "; " between fields.
	assert_output --partial "| Platform / mesh build | kubernetes (TEST_PLATFORM auto); nodes kind; operator sail-operator:1.31.1@sha256:aaaaaaaaaaaa/Available; istiod pilot:1.30.5@sha256:bbbbbbbbbbbb (1 member), mixed: pilot:1.30.5@sha256:bbbbbbbbbbbb and pilot:1.30.6@sha256:cccccccccccc (1 member); gateway proxy proxyv2:1.30.5@sha256:cccccccccccc; istiod env 0123456789ab |"
	# The envelope is pasted into campaign docs: no member names, no full digests.
	refute_output --partial "mesh-a="
	refute_output --partial "mesh-b="
	refute_output --partial "$(printf 'b%.0s' {1..64})"
	# No warnings: none printed.
	fake_cp_report "$rep" '[]'
	run --separate-stderr render_scale_envelope "$d" "$rep" "mesh-a,mesh-b" false
	assert_success
	refute_output --partial "**Warning:**"
}

@test "env_limit_drift_warning (H6): a warning only when a limit read now differs from the recorded one" {
	run env_limit_drift_warning 2000 4096 2000 4096
	assert_success
	assert_output ""
	run env_limit_drift_warning 1000 4096 2000 4096
	assert_output "istiod's limit per replica differs from the one the sweep recorded at its start (CPU 1000m recorded, 2000m now): the % of limit figures below use the recorded one, the Provisioned column the one read now; the limit changed during or after the sweep (an Argo CD sync, a tuning profile or a hand edit)"
	run env_limit_drift_warning 1000 4096 2000 8192
	assert_output --partial "(CPU 1000m recorded, 2000m now; memory 4096Mi recorded, 8192Mi now)"
	# Not read on a side: nothing to compare.
	run env_limit_drift_warning unknown 4096 2000 unknown
	assert_output ""
}

# _lim_kubectl: istiod's Deployment with limits of 2 CPUs and 4Gi; every other read fails.
_lim_kubectl() {
	case " $* " in
	*" get deploy istiod "*) echo '{"spec":{"replicas":1,"template":{"spec":{"containers":[{"name":"discovery","resources":{"requests":{"cpu":"500m","memory":"2Gi"},"limits":{"cpu":"2","memory":"4Gi"}}}]}}}}' ;;
	*) return 1 ;;
	esac
}

@test "render_scale_envelope (H6): the % of limit names the recorded limit; a live limit that differs warns above the tables" {
	source "${ROOT}/tests/lib/platform.sh"
	local d="${BATS_TEST_TMPDIR}/sweep-r" rep="${BATS_TEST_TMPDIR}/fake-report.sh"
	mkdir -p "$d"
	fake_cp_report "$rep" '[]'
	# The sweep recorded 1 CPU per replica (its % figures divide by it); istiod has 2 now.
	sed -i 's/"node_alloc_mem_mi":"16093"/"node_alloc_mem_mi":"16093","istiod_cpu_limit_m":"1000","istiod_mem_limit_mi":"4096"/' "$rep"
	run --separate-stderr render_scale_envelope "$d" "$rep" "mesh-a" _lim_kubectl
	assert_success
	assert_output --partial "> **Warning:** istiod's limit per replica differs from the one the sweep recorded at its start (CPU 1000m recorded, 2000m now)"
	assert_output --partial "| **istiod CPU (window peak)** | 500m / 2000m | 20% of 1000m |"
	assert_output --partial "| **istiod memory (RSS — OOM headroom)** | 2048Mi / 4096Mi | 30% of 4096Mi |"
	[ "$(grep -n '^> \*\*Warning:\*\* istiod' <<<"$output" | cut -d: -f1)" -lt "$(grep -n '^### 1\. Mesh topology' <<<"$output" | cut -d: -f1)" ]
	# The same limit: no warning.
	sed -i 's/"istiod_cpu_limit_m":"1000"/"istiod_cpu_limit_m":"2000"/' "$rep"
	run --separate-stderr render_scale_envelope "$d" "$rep" "mesh-a" _lim_kubectl
	refute_output --partial "**Warning:**"
	assert_output --partial "| 20% of 2000m |"
}

@test "render_scale_envelope: it needs platform.sh (platform_summary)" {
	local d="${BATS_TEST_TMPDIR}/sweep-r" rep="${BATS_TEST_TMPDIR}/fake-report.sh"
	mkdir -p "$d"
	fake_cp_report "$rep" '[]'
	run render_scale_envelope "$d" "$rep" "mesh-a,mesh-b" false
	assert_failure
	assert_output --partial "render_scale_envelope needs platform_summary (source tests/lib/platform.sh)"
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

#!/usr/bin/env bats

bats_require_minimum_version 1.5.0  # run --separate-stderr
load test_helper
source "${ROOT}/tests/lib/capacity.sh"
source "${ROOT}/tests/lib/envelope.sh"

@test "env_parse_istiod_resources: requests and limits apart, cores and Gi converted; a missing limit, no istiod container or no input is unknown, never 0" {
	run env_parse_istiod_resources <<'JSON'
{"spec":{"replicas":5,"template":{"spec":{"containers":[
  {"name":"discovery","resources":{
     "requests":{"cpu":"1","memory":"2Gi"},
     "limits":{"cpu":"4","memory":"8Gi"}}}
]}}}}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "req_cpu_m=1000 req_mem_mi=2048 lim_cpu_m=4000 lim_mem_mi=8192 replicas=5" ]]
	run env_parse_istiod_resources <<'JSON'
{"spec":{"replicas":1,"template":{"spec":{"containers":[
  {"name":"discovery","resources":{"requests":{"cpu":"500m","memory":"512Mi"}}}
]}}}}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "req_cpu_m=500 req_mem_mi=512 lim_cpu_m=unknown lim_mem_mi=unknown replicas=1" ]]
	run env_parse_istiod_resources <<<'{"spec":{"template":{"spec":{"containers":[{"name":"other"}]}}}}'
	[ "$status" -eq 0 ]
	[[ "$output" == "req_cpu_m=unknown req_mem_mi=unknown lim_cpu_m=unknown lim_mem_mi=unknown replicas=unknown" ]]
	run env_parse_istiod_resources <<<''
	[ "$status" -eq 0 ]
	[[ "$output" == "req_cpu_m=unknown req_mem_mi=unknown lim_cpu_m=unknown lim_mem_mi=unknown replicas=unknown" ]]
}

# env_network: Istio 1.2x+ sets the network only as the istio-system namespace
# label, so the wrapper falls back to it when the istiod env has none.
_net_kubectl() {
	case "$*" in
		*"get deploy istiod"*) echo '{"spec":{"template":{"spec":{"containers":[{"name":"discovery","env":[]}]}}}}' ;;
		*"get namespace istio-system"*) printf '%s' "${NET_LABEL:-}" ;;
	esac
}

@test "env_parse_network and env_network: istiod's ISTIO_META_NETWORK, else the istio-system network label (Istio 1.2x+ sets only that), else unknown" {
	run env_parse_network <<'JSON'
{"spec":{"template":{"spec":{"containers":[
  {"name":"discovery","env":[{"name":"ISTIO_META_NETWORK","value":"cluster-a-network"}]}
]}}}}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "network=cluster-a-network" ]]
	run env_parse_network <<<'{"spec":{"template":{"spec":{"containers":[{"name":"discovery","env":[]}]}}}}'
	[ "$status" -eq 0 ]
	[[ "$output" == "network=unknown" ]]
	NET_LABEL=net-a run env_network ctx-a _net_kubectl
	[ "$status" -eq 0 ]
	[[ "$output" == "network=net-a" ]]
	NET_LABEL="" run env_network ctx-a _net_kubectl
	[ "$status" -eq 0 ]
	[[ "$output" == "network=unknown" ]]
}

# env_pct_of_limit: PL35 cross-replica scope. The R>1 path is the regression: a single-replica
# fixture hides the per-replica-vs-cross-replica bug.
@test "env_pct_of_limit: the use summed over R replicas divides by R x the per-replica limit (an idle 5-replica plane never reads ~R x 100%); unknown input or no replica is unknown" {
	# used=400m, limit=8000m/replica, 1 replica -> 5%
	run env_pct_of_limit 400 8000 1
	[ "$status" -eq 0 ]
	[[ "$output" == "5" ]]
	# used=2000m (sum across 5 replicas), per-replica limit=8000m, 5 replicas.
	# CORRECT: 2000 / (8000*5) = 5%. The bug (per-replica denom) would read 25%.
	run env_pct_of_limit 2000 8000 5
	[ "$status" -eq 0 ]
	[[ "$output" == "5" ]]
	# Idle: used ~= 5*50m = 250m total, per-replica limit 2000m, 5 replicas.
	# 250 / 10000 = 2.5% -> rounds to 3 (NOT ~125% the per-replica bug produces).
	run env_pct_of_limit 250 2000 5
	[ "$status" -eq 0 ]
	[ "$output" -lt 10 ]
	run env_pct_of_limit unknown 8000 5
	[[ "$output" == "unknown" ]]
	run env_pct_of_limit 400 8000 0
	[[ "$output" == "unknown" ]]
}

# env_sla_verdict: PASS / CAUTION / FAIL. Args: icpu imem ncpu nmem restarts n_total n_valid,
# then the bands (8, 9: else SCALE_SLA_CAUTION_PCT / SCALE_SLA_FAIL_PCT, else 75 / 90) and the
# INCOMPLETE cell count (10).
@test "env_sla_verdict: PASS below the caution band, CAUTION in it, FAIL at the fail band; FAIL on an in-window restart or no valid sample; CAUTION on a utilization not read, filtered samples or an INCOMPLETE cell; bands from args 8/9, else the environment, else 75/90" {
	run env_sla_verdict 10 20 30 40 0 12 12
	[ "$status" -eq 0 ]
	[[ "$output" == PASS\|* ]]
	run env_sla_verdict 80 20 30 40 0 12 12
	[[ "$output" == CAUTION\|* ]]
	run env_sla_verdict 95 20 30 40 0 12 12
	[[ "$output" == FAIL\|* ]]
	run env_sla_verdict 10 20 30 40 2 12 10
	[[ "$output" == FAIL\|* ]]
	[[ "$output" == *restart* ]]
	run env_sla_verdict unknown unknown unknown unknown 0 6 0
	[[ "$output" == FAIL\|* ]]
	run env_sla_verdict 10 unknown 30 40 0 12 12
	[[ "$output" == CAUTION\|* ]]
	run env_sla_verdict 10 20 30 40 0 12 9
	[[ "$output" == CAUTION\|* ]]
	# 60% utilization: PASS at default 75, but CAUTION if the env caution band drops to 50.
	SCALE_SLA_CAUTION_PCT=50 SCALE_SLA_FAIL_PCT=90 run env_sla_verdict 60 20 30 40 0 12 12
	[[ "$output" == CAUTION\|* ]]
	SCALE_SLA_CAUTION_PCT=75 SCALE_SLA_FAIL_PCT=90 run env_sla_verdict 60 20 30 40 0 12 12
	[[ "$output" == PASS\|* ]]
	# 60% utilization, args force fail band to 55 -> FAIL regardless of env.
	SCALE_SLA_CAUTION_PCT=75 SCALE_SLA_FAIL_PCT=90 run env_sla_verdict 60 20 30 40 0 12 12 40 55
	[[ "$output" == FAIL\|* ]]
	run env_sla_verdict 80 20 30 40 0 12 12
	[[ "$output" == CAUTION\|* ]]
	[[ "$output" == *"[75,90)"* ]]
	run env_sla_verdict 10 20 30 40 0 12 12
	assert_output --partial "peak utilization 40% < 75% across istiod + nodes"
	run env_sla_verdict 10 20 95 40 0 12 12
	[[ "$output" == FAIL\|* ]]
	run env_sla_verdict 10 20 30 unknown 0 12 12
	[[ "$output" == CAUTION\|*"metrics API gap"* ]]
	# INCOMPLETE cells (arg 10) turn a PASS into CAUTION and join a CAUTION or FAIL reason.
	run env_sla_verdict 10 15 40 50 0 4 4 75 90 0
	[[ "$output" == PASS\|* ]]
	run env_sla_verdict 10 15 40 50 0 4 4 75 90 1
	[[ "$output" == CAUTION\|*"1 cell(s) are INCOMPLETE"* ]]
	run env_sla_verdict 80 15 40 50 0 4 4 75 90 1
	[[ "$output" == CAUTION\|*"; also 1 cell(s) are INCOMPLETE"* ]]
	run env_sla_verdict 95 15 40 50 0 4 4 75 90 3
	[[ "$output" == FAIL\|*"; also 3 cell(s) are INCOMPLETE"* ]]
	# Not a count: 0.
	run env_sla_verdict 10 15 40 50 0 4 4 75 90 y
	[[ "$output" == PASS\|* ]]
}

# --nodes-excluded (H4): kind nodes report the shared host, so the verdict leaves their figures out.
@test "env_sla_verdict --nodes-excluded: CAUTION with the reason even when every figure is low; node figures that would fail, or are unknown, do not count, istiod's still do" {
	run env_sla_verdict --nodes-excluded "the nodes are kind's" 10 20 30 40 0 12 12
	assert_success
	[[ "$output" == "CAUTION|node figures left out: the nodes are kind's"*"peak utilization 20% < 75% across istiod,"* ]]
	# Node figures that would fail, or are unknown, do not count; istiod's still do.
	run env_sla_verdict --nodes-excluded kind 10 20 95 99 0 12 12
	[[ "$output" == "CAUTION|node figures left out: kind"*"peak utilization 20% < 75% across istiod,"* ]]
	run env_sla_verdict --nodes-excluded kind 10 20 unknown unknown 0 12 12
	[[ "$output" == "CAUTION|node figures left out: kind; the figures: peak utilization 20%"* ]]
	run env_sla_verdict --nodes-excluded kind 95 20 30 40 0 12 12
	[[ "$output" == "FAIL|peak utilization 95% >= 90%"*"; also node figures left out: kind" ]]
	run env_sla_verdict --nodes-excluded kind 10 20 30 40 2 12 10
	[[ "$output" == FAIL\|*"restart"*"; also node figures left out: kind" ]]
	# The bands still come from args 8/9 after the option.
	run env_sla_verdict --nodes-excluded kind 60 20 30 40 0 12 12 40 55
	[[ "$output" == FAIL\|* ]]
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
"mesh_operator_by_context":"mesh-a=sail-operator:1.31.1@${da},mesh-b=sail-operator:1.31.1@${da}",
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

@test "render_scale_envelope (H4): every data warning above the tables and the verdict, one line each, none without one; a Platform / mesh build row without member names or full digests; without platform.sh it refuses" {
	source "${ROOT}/tests/lib/platform.sh"
	local d="${BATS_TEST_TMPDIR}/sweep-r" rep="${BATS_TEST_TMPDIR}/fake-report.sh" w1 w2 t1 v
	mkdir -p "$d"
	fake_cp_report "$rep" '["Nodes on kind (NODE_PROVIDER_BY_CONTEXT): every node reports the whole host'"'"'s CPU and memory","input TSVs disagree on ISTIOD_IMAGE_BY_CONTEXT for 1 of 2 members: the report mixes runs with different values of it; compare like with like"]'
	run --separate-stderr render_scale_envelope "$d" "$rep" "mesh-a,mesh-b" false
	assert_success
	assert_output --partial "> **Data warning:** Nodes on kind (NODE_PROVIDER_BY_CONTEXT): every node reports the whole host's CPU and memory"
	assert_output --partial "> **Data warning:** input TSVs disagree on ISTIOD_IMAGE_BY_CONTEXT for 1 of 2 members"
	w1="$(grep -n '^> \*\*Data warning:\*\* Nodes on kind' <<<"$output" | cut -d: -f1)"
	w2="$(grep -n '^> \*\*Data warning:\*\* input TSVs disagree' <<<"$output" | cut -d: -f1)"
	t1="$(grep -n '^### 1\. Mesh topology' <<<"$output" | cut -d: -f1)"
	v="$(grep -n '^> \*\*CAUTION\*\*' <<<"$output" | cut -d: -f1)"
	((w1 < w2 && w2 < t1 && t1 < v)) || { echo "warnings at ${w1} and ${w2}, topology at ${t1}, verdict at ${v}"; false; }
	# H17: ", " between the groups, " and " between a mixed member's builds, "; " between fields.
	assert_output --partial "| Platform / mesh build | kubernetes (TEST_PLATFORM auto); nodes kind; operator sail-operator:1.31.1@sha256:aaaaaaaaaaaa; istiod pilot:1.30.5@sha256:bbbbbbbbbbbb (1 member), mixed: pilot:1.30.5@sha256:bbbbbbbbbbbb and pilot:1.30.6@sha256:cccccccccccc (1 member); gateway proxy proxyv2:1.30.5@sha256:cccccccccccc; istiod env 0123456789ab |"
	# The envelope is pasted into campaign docs: no member names, no full digests.
	refute_output --partial "mesh-a="
	refute_output --partial "mesh-b="
	refute_output --partial "$(printf 'b%.0s' {1..64})"
	# No warnings: none printed.
	fake_cp_report "$rep" '[]'
	run --separate-stderr render_scale_envelope "$d" "$rep" "mesh-a,mesh-b" false
	assert_success
	refute_output --partial "**Data warning:**"
	# A warning that holds a newline is one line.
	jq -n '{metadata: {data_warnings: ["first part\nsecond part"]}, results: []}' > "${BATS_TEST_TMPDIR}/n.json"
	printf '#!/bin/sh\ncat "%s"\n' "${BATS_TEST_TMPDIR}/n.json" > "$rep"
	run --separate-stderr render_scale_envelope "$d" "$rep" "mesh-a" false
	assert_success
	assert_line "> **Data warning:** first part second part"
	[ "$(grep -c 'Data warning' <<<"$output")" -eq 1 ]
	# Without platform.sh (platform_summary) it renders nothing.
	fake_cp_report "$rep" '[]'
	run bash -c 'source "$1/tests/lib/common.sh"; source "$1/tests/lib/capacity.sh"; source "$1/tests/lib/envelope.sh"
		render_scale_envelope "$2" "$3" mesh-a false' _ "$ROOT" "$d" "$rep"
	assert_failure
	assert_output --partial "render_scale_envelope needs platform_summary (source tests/lib/platform.sh)"
}

@test "render_scale_envelope through controlplane 004: the data warnings of 004's json (an istiod pod not Ready at a window's baseline, a cell on fewer istiod replicas than wanted) are its Data warning lines" {
	local a="${BATS_TEST_TMPDIR}/sweep-a" w
	source "${ROOT}/tests/lib/platform.sh"
	mkdir -p "$a"
	# The fixture's first window: mesh-a ran 2 of its 3 istiod replicas, and mesh-b's
	# istiod-x was not Ready at its baseline.
	awk '!/^#/ && $1 != "timestamp" && !d++ { print "# ISTIOD_NOT_READY=mesh-b=istiod-x"; print "# WINDOW_ROWS=mesh-a=2/3,mesh-b=3/3" } { print }' \
		"${ROOT}/tests/lib/test/fixtures/controlplane_cluster_proxies.tsv" > "${a}/controlplane-fixture-t2.tsv"
	run --separate-stderr render_scale_envelope "$a" "${ROOT}/tests/controlplane/004-report-results.sh" "mesh-a,mesh-b" false
	assert_success
	w="$(grep '^> \*\*Data warning:\*\* ' <<<"$output")"
	[ "$(grep -c . <<<"$w")" -eq 2 ] || { echo "$w"; false; }
	[[ "$w" == *"istiod-x on mesh-b"*"not Ready at the window's baseline"* || "$w" == *"not Ready at the window's baseline"*"istiod-x on mesh-b"* ]]
	[[ "$w" == *"mesh-a ran 2 of its 3 istiod replicas"* ]]
}

# _lim_kubectl: istiod's Deployment with limits of 2 CPUs and 4Gi; every other read fails.
_lim_kubectl() {
	case " $* " in
	*" get deploy istiod "*) echo '{"spec":{"replicas":1,"template":{"spec":{"containers":[{"name":"discovery","resources":{"requests":{"cpu":"500m","memory":"2Gi"},"limits":{"cpu":"2","memory":"4Gi"}}}]}}}}' ;;
	*) return 1 ;;
	esac
}

@test "H6: the % of limit cells name the recorded limit, the kubectl top ones each row's own; a live limit that differs from the recorded one warns above the tables (env_limit_drift_warning: only when both sides were read)" {
	run env_limit_drift_warning 2000 4096 2000 4096
	assert_success
	assert_output ""
	run env_limit_drift_warning 1000 4096 2000 4096
	assert_output --partial "istiod's limit per replica differs from the one the sweep recorded at its start (CPU 1000m recorded, 2000m now)"
	run env_limit_drift_warning 1000 4096 2000 8192
	assert_output --partial "(CPU 1000m recorded, 2000m now; memory 4096Mi recorded, 8192Mi now)"
	# Not read on a side: nothing to compare.
	run env_limit_drift_warning unknown 4096 2000 unknown
	assert_output ""
	source "${ROOT}/tests/lib/platform.sh"
	local d="${BATS_TEST_TMPDIR}/sweep-r" rep="${BATS_TEST_TMPDIR}/fake-report.sh"
	mkdir -p "$d"
	fake_cp_report "$rep" '[]'
	# The sweep recorded 1 CPU per replica (its % figures divide by it); istiod has 2 now.
	sed -i 's/"node_alloc_mem_mi":"16093"/"node_alloc_mem_mi":"16093","istiod_cpu_limit_m":"1000","istiod_mem_limit_mi":"4096"/' "$rep"
	run --separate-stderr render_scale_envelope "$d" "$rep" "mesh-a" _lim_kubectl
	assert_success
	assert_output --partial "> **Data warning:** istiod's limit per replica differs from the one the sweep recorded at its start (CPU 1000m recorded, 2000m now)"
	assert_output --partial "| **istiod CPU (window peak)** | 500m / 2000m | 20% of 1000m |"
	assert_output --partial "| **istiod memory (RSS — OOM headroom)** | 2048Mi / 4096Mi | 30% of 4096Mi |"
	# The kubectl top figures divide by each row's own limit (002, read with the row), not by the
	# recorded one: no "of 1000m" there.
	assert_output --partial "| istiod CPU (kubectl top at window end) | 500m / 2000m | 10% of each row's limit |"
	assert_output --partial "| istiod memory (kubectl top) | 2048Mi / 4096Mi | 30% of each row's limit |"
	[ "$(grep -n '^> \*\*Data warning:\*\* istiod' <<<"$output" | cut -d: -f1)" -lt "$(grep -n '^### 1\. Mesh topology' <<<"$output" | cut -d: -f1)" ]
	# The same limit: no warning.
	sed -i 's/"istiod_cpu_limit_m":"1000"/"istiod_cpu_limit_m":"2000"/' "$rep"
	run --separate-stderr render_scale_envelope "$d" "$rep" "mesh-a" _lim_kubectl
	refute_output --partial "**Data warning:**"
	assert_output --partial "| 20% of 2000m |"
}

@test "env_pct_cell: a % of limit cell names its limit only when both are numbers, a value not read stays bare; with kubectl top down the envelope's cells read unknown, never unknown% of a limit" {
	run env_pct_cell 20 1000 m
	assert_output "20% of 1000m"
	run env_pct_cell 12.5 4096 Mi
	assert_output "12.5% of 4096Mi"
	run env_pct_cell 10 row
	assert_output "10% of each row's limit"
	# No numeric limit: the % alone; no numeric %: the value as it is, never "unknown%".
	run env_pct_cell 20 unknown m
	assert_output "20%"
	run env_pct_cell 28
	assert_output "28%"
	run env_pct_cell unknown 2000 m
	assert_output "unknown"
	run env_pct_cell N/A row
	assert_output "N/A"
	run env_pct_cell ""
	assert_output "unknown"
	source "${ROOT}/tests/lib/platform.sh"
	local d="${BATS_TEST_TMPDIR}/sweep-r" rep="${BATS_TEST_TMPDIR}/fake-report.sh"
	mkdir -p "$d"
	fake_cp_report "$rep" '[]'
	sed -i 's/"node_alloc_mem_mi":"16093"/"node_alloc_mem_mi":"16093","istiod_cpu_limit_m":"2000","istiod_mem_limit_mi":"4096"/; s/"istiod_cpu_pct_of_limit_max":"10","istiod_mem_pct_of_limit_max":"30"/"istiod_cpu_pct_of_limit_max":"unknown","istiod_mem_pct_of_limit_max":"unknown"/; s/"node_cpu_pct_max":"28","node_mem_pct_max":"35"/"node_cpu_pct_max":"unknown","node_mem_pct_max":"unknown"/' "$rep"
	run --separate-stderr render_scale_envelope "$d" "$rep" "mesh-a" _lim_kubectl
	assert_success
	assert_output --partial "| istiod CPU (kubectl top at window end) | 500m / 2000m | unknown |"
	assert_output --partial "| istiod memory (kubectl top) | 2048Mi / 4096Mi | unknown |"
	assert_output --partial "| Worker-node CPU | — | unknown |"
	assert_output --partial "| Worker-node memory | — | unknown |"
	# The figures from the /metrics scrape still name the recorded limit.
	assert_output --partial "| **istiod CPU (window peak)** | 500m / 2000m | 20% of 2000m |"
	refute_output --partial "unknown%"
}

# istiod replicas over every context. Members can run different replica counts, and the
# per-replica proxy figure is about 1/R of the cluster figure, so R must not come from the first
# context alone.
@test "env_replicas_summary and env_replicas_label: one number when uniform, min-max when not, a read that failed left out and named; first context only for an old TSV; unknown when none read" {
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

@test "env_istiod_scan and env_collect_infra: requests and limits from the first context, replicas from every context in order (one not read is unknown); ISTIOD_REPLICAS is their range, with the per-context list, through the shared emitter" {
	run env_istiod_scan "mesh-a,mesh-b,mesh-c" _rep_kubectl
	assert_success
	assert_output "req_cpu_m=500 req_mem_mi=2048 lim_cpu_m=2000 lim_mem_mi=4096 replicas=1-3 replicas_by_context=mesh-a=1,mesh-b=3,mesh-c=unknown"
	run env_istiod_scan "mesh-b,mesh-b" _rep_kubectl
	assert_output --partial "replicas=3 replicas_by_context=mesh-b=3,mesh-b=3"
	run env_istiod_scan "" _rep_kubectl
	assert_output "req_cpu_m=unknown req_mem_mi=unknown lim_cpu_m=unknown lim_mem_mi=unknown replicas=unknown replicas_by_context=unknown"
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

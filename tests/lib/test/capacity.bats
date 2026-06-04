#!/usr/bin/env bats

load test_helper
source "${ROOT}/tests/lib/capacity.sh"

# ---------------------------------------------------------------------------
# cap_parse_node_totals (worker nodes only; cores vs `m`; Ki/Mi/Gi)
# ---------------------------------------------------------------------------

@test "cap_parse_node_totals: sums worker allocatable, excludes control-plane" {
	run cap_parse_node_totals <<'JSON'
{"items":[
  {"metadata":{"name":"cp-0","labels":{"node-role.kubernetes.io/control-plane":""}},
   "status":{"allocatable":{"cpu":"8","memory":"16Gi","pods":"250"}}},
  {"metadata":{"name":"w-0","labels":{}},
   "status":{"allocatable":{"cpu":"8","memory":"16Gi","pods":"250"}}},
  {"metadata":{"name":"w-1","labels":{}},
   "status":{"allocatable":{"cpu":"7900m","memory":"16Gi","pods":"250"}}}
]}
JSON
	[ "$status" -eq 0 ]
	# 8000 + 7900 = 15900 cpu_m; 16Gi*2 = 32768 mem_mi; 500 pods; 2 nodes
	[[ "$output" == "cpu_m=15900 mem_mi=32768 pods=500 nodes=2 names=w-0,w-1" ]]
}

@test "cap_parse_node_totals: Ki and Mi memory units floor correctly" {
	run cap_parse_node_totals <<'JSON'
{"items":[
  {"metadata":{"name":"w-0","labels":{}},
   "status":{"allocatable":{"cpu":"1","memory":"1048576Ki","pods":"110"}}},
  {"metadata":{"name":"w-1","labels":{}},
   "status":{"allocatable":{"cpu":"500m","memory":"512Mi","pods":"110"}}}
]}
JSON
	[ "$status" -eq 0 ]
	# 1048576Ki = 1024Mi; +512Mi = 1536Mi; cpu 1000+500=1500; pods 220
	[[ "$output" == "cpu_m=1500 mem_mi=1536 pods=220 nodes=2 names=w-0,w-1" ]]
}

@test "cap_parse_node_totals: excludes master and infra labels too" {
	run cap_parse_node_totals <<'JSON'
{"items":[
  {"metadata":{"name":"m-0","labels":{"node-role.kubernetes.io/master":""}},
   "status":{"allocatable":{"cpu":"8","memory":"16Gi","pods":"250"}}},
  {"metadata":{"name":"i-0","labels":{"node-role.kubernetes.io/infra":""}},
   "status":{"allocatable":{"cpu":"8","memory":"16Gi","pods":"250"}}},
  {"metadata":{"name":"w-0","labels":{}},
   "status":{"allocatable":{"cpu":"4","memory":"8Gi","pods":"110"}}}
]}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=4000 mem_mi=8192 pods=110 nodes=1 names=w-0" ]]
}

@test "cap_parse_node_totals: zero worker nodes -> unknown" {
	run cap_parse_node_totals <<'JSON'
{"items":[
  {"metadata":{"name":"cp-0","labels":{"node-role.kubernetes.io/control-plane":""}},
   "status":{"allocatable":{"cpu":"8","memory":"16Gi","pods":"250"}}}
]}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=unknown mem_mi=unknown pods=unknown nodes=0 names=" ]]
}

@test "cap_parse_node_totals: unparseable input -> unknown" {
	run cap_parse_node_totals <<<'not json'
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=unknown mem_mi=unknown pods=unknown nodes=0 names=" ]]
}

# ---------------------------------------------------------------------------
# cap_parse_top_nodes (worker filtering; `m`/cores; empty -> unknown)
# ---------------------------------------------------------------------------

@test "cap_parse_top_nodes: sums only named worker rows" {
	run cap_parse_top_nodes "w-0,w-1" <<'TOP'
cp-0   200m   2%   900Mi   5%
w-0    1500m  18%  4096Mi  25%
w-1    1      12%  2Gi     12%
TOP
	[ "$status" -eq 0 ]
	# cpu: 1500 + 1000 = 2500; mem: 4096 + 2048 = 6144
	[[ "$output" == "cpu_m=2500 mem_mi=6144" ]]
}

@test "cap_parse_top_nodes: empty stdin (metrics-server absent) -> unknown" {
	run cap_parse_top_nodes "w-0,w-1" <<<''
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=unknown mem_mi=unknown" ]]
}

@test "cap_parse_top_nodes: no worker rows match -> unknown" {
	run cap_parse_top_nodes "w-9" <<'TOP'
w-0    1500m  18%  4096Mi  25%
TOP
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=unknown mem_mi=unknown" ]]
}

# ---------------------------------------------------------------------------
# cap_parse_istiod_limits (limits; only requests; missing -> unknown)
# ---------------------------------------------------------------------------

@test "cap_parse_istiod_limits: reads discovery container limits + replicas" {
	run cap_parse_istiod_limits <<'JSON'
{"spec":{"replicas":2,"template":{"spec":{"containers":[
  {"name":"discovery","resources":{"limits":{"cpu":"2","memory":"8Gi"},
   "requests":{"cpu":"500m","memory":"2Gi"}}}
]}}}}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=2000 mem_mi=8192 replicas=2" ]]
}

@test "cap_parse_istiod_limits: falls back to requests when no limits" {
	run cap_parse_istiod_limits <<'JSON'
{"spec":{"replicas":1,"template":{"spec":{"containers":[
  {"name":"discovery","resources":{"requests":{"cpu":"250m","memory":"1Gi"}}}
]}}}}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=250 mem_mi=1024 replicas=1" ]]
}

@test "cap_parse_istiod_limits: missing istiod container -> unknown" {
	run cap_parse_istiod_limits <<'JSON'
{"spec":{"replicas":1,"template":{"spec":{"containers":[
  {"name":"other","resources":{"limits":{"cpu":"1","memory":"1Gi"}}}
]}}}}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=unknown mem_mi=unknown replicas=unknown" ]]
}

@test "cap_parse_istiod_limits: empty/unparseable -> unknown" {
	run cap_parse_istiod_limits <<<'not json'
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=unknown mem_mi=unknown replicas=unknown" ]]
}

# ---------------------------------------------------------------------------
# cap_parse_pod_count
# ---------------------------------------------------------------------------

@test "cap_parse_pod_count: counts Running/Pending pods on worker nodes" {
	run cap_parse_pod_count "w-0,w-1" <<'JSON'
{"items":[
  {"spec":{"nodeName":"w-0"},"status":{"phase":"Running"}},
  {"spec":{"nodeName":"w-1"},"status":{"phase":"Pending"}},
  {"spec":{"nodeName":"cp-0"},"status":{"phase":"Running"}},
  {"spec":{"nodeName":"w-0"},"status":{"phase":"Succeeded"}}
]}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "scheduled=2" ]]
}

@test "cap_parse_pod_count: unparseable -> unknown" {
	run cap_parse_pod_count "w-0" <<<'not json'
	[ "$status" -eq 0 ]
	[[ "$output" == "scheduled=unknown" ]]
}

# ---------------------------------------------------------------------------
# cap_pct
# ---------------------------------------------------------------------------

@test "cap_pct: normal rounding" {
	[[ "$(cap_pct 1500 8000)" == "19" ]]
	[[ "$(cap_pct 5 10)" == "50" ]]
}

@test "cap_pct: zero total -> unknown" {
	[[ "$(cap_pct 5 0)" == "unknown" ]]
}

@test "cap_pct: unknown input -> unknown" {
	[[ "$(cap_pct unknown 100)" == "unknown" ]]
	[[ "$(cap_pct 5 unknown)" == "unknown" ]]
	[[ "$(cap_pct N/A 100)" == "unknown" ]]
}

# ---------------------------------------------------------------------------
# cap_max_pods (cpu-bound, mem-bound, pods-bound; unknown propagation)
# ---------------------------------------------------------------------------

@test "cap_max_pods: cpu-bound" {
	# alloc 16000m/64000Mi/500 pods; istiod 2000m*1rep; per-pod 200m/256Mi
	# target_cpu=(16000-2000)*0.85*0.7=8330 -> /200 = 41.65
	# target_mem=(64000-1024)*0.85*0.7=37470 -> /256 = 146.4
	# pods cap=500*0.7=350 ; min=41 (cpu-bound)
	run cap_max_pods 16000 64000 500 2000 1024 1 200 256 0.7 0.15
	[ "$status" -eq 0 ]
	[[ "$output" == "41" ]]
}

@test "cap_max_pods: mem-bound" {
	# per-pod mem high: 200m/2048Mi
	# target_mem=(64000-1024)*0.595=37470 -> /2048 = 18.29 ; cpu 41 ; pods 350 -> min 18
	run cap_max_pods 16000 64000 500 2000 1024 1 200 2048 0.7 0.15
	[ "$status" -eq 0 ]
	[[ "$output" == "18" ]]
}

@test "cap_max_pods: pods-bound" {
	# tiny alloc pods cap dominates: alloc_pods=10 -> 10*0.7=7
	run cap_max_pods 16000 64000 10 2000 1024 1 200 256 0.7 0.15
	[ "$status" -eq 0 ]
	[[ "$output" == "7" ]]
}

@test "cap_max_pods: floor of >=1" {
	run cap_max_pods 2100 64000 500 2000 1024 1 200 256 0.7 0.15
	[ "$status" -eq 0 ]
	[[ "$output" == "1" ]]
}

@test "cap_max_pods: unknown input propagates" {
	[[ "$(cap_max_pods unknown 64000 500 2000 1024 1 200 256 0.7 0.15)" == "unknown" ]]
	[[ "$(cap_max_pods 16000 64000 500 2000 unknown 1 200 256 0.7 0.15)" == "unknown" ]]
}

@test "cap_max_pods: zero per-pod cost -> unknown" {
	[[ "$(cap_max_pods 16000 64000 500 2000 1024 1 0 256 0.7 0.15)" == "unknown" ]]
}

# ---------------------------------------------------------------------------
# _cap_retry_nonempty (transient-blip retry for the kubectl top reads, #44)
# ---------------------------------------------------------------------------

@test "_cap_retry_nonempty: returns first non-empty without retrying" {
	CAP_TOP_ATTEMPTS=3 CAP_TOP_BACKOFF_S=0 run _cap_retry_nonempty echo "hi"
	[ "$status" -eq 0 ]
	[[ "$output" == "hi" ]]
}

@test "_cap_retry_nonempty: retries empty results then returns the non-empty one" {
	cnt="${BATS_TEST_TMPDIR}/cnt"; echo 0 > "$cnt"
	_stub() {
		local n; n=$(<"$cnt"); n=$((n + 1)); echo "$n" > "$cnt"
		(( n < 3 )) && return 0   # first two calls emit nothing
		echo "data"
	}
	CAP_TOP_ATTEMPTS=3 CAP_TOP_BACKOFF_S=0 run _cap_retry_nonempty _stub
	[ "$status" -eq 0 ]
	[[ "$output" == "data" ]]
	[[ "$(<"$cnt")" == "3" ]]   # exactly 3 attempts consumed
}

@test "_cap_retry_nonempty: exhausts attempts -> empty output, still exit 0 (never fails the pipe)" {
	CAP_TOP_ATTEMPTS=2 CAP_TOP_BACKOFF_S=0 run _cap_retry_nonempty true
	[ "$status" -eq 0 ]
	[[ -z "$output" ]]
}

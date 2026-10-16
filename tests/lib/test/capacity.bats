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

@test "cap_parse_node_totals: single-node / compact nodes (control-plane + worker) count" {
	run cap_parse_node_totals <<'JSON'
{"items":[
  {"metadata":{"name":"sno-0","labels":{"node-role.kubernetes.io/control-plane":"","node-role.kubernetes.io/master":"","node-role.kubernetes.io/worker":""}},
   "status":{"allocatable":{"cpu":"7500m","memory":"30Gi","pods":"250"}}},
  {"metadata":{"name":"i-0","labels":{"node-role.kubernetes.io/infra":"","node-role.kubernetes.io/worker":""}},
   "status":{"allocatable":{"cpu":"8","memory":"16Gi","pods":"250"}}}
]}
JSON
	[ "$status" -eq 0 ]
	# The infra node stays excluded even with a worker label.
	[[ "$output" == "cpu_m=7500 mem_mi=30720 pods=250 nodes=1 names=sno-0" ]]
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
	[[ "$output" == "scheduled=2 sidecars=0" ]]
}

@test "cap_parse_pod_count: sidecars = Running, not terminating, injected, on any node" {
	run cap_parse_pod_count "w-0,w-1" <<'JSON'
{"items":[
  {"metadata":{"annotations":{"sidecar.istio.io/status":"{}"}},"spec":{"nodeName":"w-0"},"status":{"phase":"Running"}},
  {"metadata":{"annotations":{"sidecar.istio.io/status":"{}"}},"spec":{"nodeName":"cp-0"},"status":{"phase":"Running"}},
  {"metadata":{"annotations":{"sidecar.istio.io/status":"{}"}},"spec":{"nodeName":"w-1"},"status":{"phase":"Pending"}},
  {"metadata":{"deletionTimestamp":"2026-06-01T00:00:00Z","annotations":{"sidecar.istio.io/status":"{}"}},"spec":{"nodeName":"w-0"},"status":{"phase":"Running"}},
  {"metadata":{"labels":{"security.istio.io/tlsMode":"istio"}},"spec":{"nodeName":"w-1"},"status":{"phase":"Running"}}
]}
JSON
	[ "$status" -eq 0 ]
	# scheduled: w-0 Running x2 (one terminating), w-1 Pending, w-1 Running = 4 (cp-0 not a worker).
	# sidecars: the w-0 and cp-0 Running injected pods; not the Pending, terminating or
	# label-only (no annotation) ones.
	[[ "$output" == "scheduled=4 sidecars=2" ]]
}

@test "cap_parse_pod_count: empty worker list -> scheduled unknown (not 0), sidecars still counted" {
	run cap_parse_pod_count "" <<'JSON'
{"items":[{"metadata":{"annotations":{"sidecar.istio.io/status":"{}"}},"spec":{"nodeName":"cp-0"},"status":{"phase":"Running"}}]}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "scheduled=unknown sidecars=1" ]]
}

@test "cap_parse_pod_count: unparseable or empty input -> both unknown" {
	run cap_parse_pod_count "w-0" <<<'not json'
	[ "$status" -eq 0 ]
	[[ "$output" == "scheduled=unknown sidecars=unknown" ]]
	run cap_parse_pod_count "w-0" < /dev/null
	[ "$status" -eq 0 ]
	[[ "$output" == "scheduled=unknown sidecars=unknown" ]]
}

# ---------------------------------------------------------------------------
# cap_parse_requested (CPU/memory the scheduler has already handed out)
# ---------------------------------------------------------------------------

@test "cap_parse_requested: sums requests on workers with the scheduler's init and sidecar rules" {
	run cap_parse_requested "w-0,w-1" <<'JSON'
{"items":[
  {"spec":{"nodeName":"w-0","containers":[{"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}},{"resources":{}}],
           "initContainers":[{"resources":{"requests":{"cpu":"500m","memory":"64Mi"}}}]},"status":{"phase":"Running"}},
  {"spec":{"nodeName":"w-1","containers":[{"resources":{}}],
           "initContainers":[{"restartPolicy":"Always","resources":{"requests":{"cpu":"100m","memory":"128Mi"}}},
                             {"resources":{"requests":{"cpu":"50m","memory":"10Mi"}}}]},"status":{"phase":"Pending"}},
  {"spec":{"nodeName":"w-1","containers":[{"resources":{"requests":{"cpu":"1","memory":"1Gi"}}}],"overhead":{"cpu":"250m","memory":"120Mi"}},
   "metadata":{"deletionTimestamp":"2026-10-16T00:00:00Z"},"status":{"phase":"Running"}},
  {"spec":{"nodeName":"cp-0","containers":[{"resources":{"requests":{"cpu":"4"}}}]},"status":{"phase":"Running"}},
  {"spec":{"nodeName":"w-0","containers":[{"resources":{"requests":{"cpu":"2"}}}]},"status":{"phase":"Succeeded"}},
  {"spec":{"containers":[{"resources":{"requests":{"cpu":"3"}}}]},"status":{"phase":"Pending"}}
]}
JSON
	[ "$status" -eq 0 ]
	# Pod 1: max(100 app, 500 init) = 500m; memory max(128, 64) = 128.
	# Pod 2: native sidecar 100m runs through the 50m init (150m) and with the app (100m) = 150m;
	#        memory max(128 + 10, 128) = 138.
	# Pod 3: terminating still holds its requests: 1000 + 250 overhead = 1250m; 1024 + 120 Mi.
	# Not counted: a control-plane node, a Succeeded pod, an unscheduled Pending pod.
	[[ "$output" == "cpu_m=1900 mem_mi=1410 pods=3" ]]
}

@test "cap_parse_requested: the exclude label leaves the test's own pods out" {
	run cap_parse_requested "w-0" "app.kubernetes.io/instance=controlplane-test" <<'JSON'
{"items":[
  {"metadata":{"labels":{"app.kubernetes.io/instance":"controlplane-test"}},"spec":{"nodeName":"w-0","containers":[{"resources":{"requests":{"cpu":"100m"}}}]},"status":{"phase":"Running"}},
  {"metadata":{"labels":{"app.kubernetes.io/instance":"other"}},"spec":{"nodeName":"w-0","containers":[{"resources":{"requests":{"cpu":"300m"}}}]},"status":{"phase":"Running"}},
  {"spec":{"nodeName":"w-0","containers":[{"resources":{"requests":{"cpu":"7900m","memory":"8G"}}}]},"status":{"phase":"Running"}}
]}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=8200 mem_mi=7629 pods=2" ]]
}

@test "cap_parse_requested: no workers, unparseable or empty input -> unknown" {
	run cap_parse_requested "" <<<'{"items":[]}'
	[[ "$output" == "cpu_m=unknown mem_mi=unknown pods=unknown" ]]
	run cap_parse_requested "w-0" <<<'not json'
	[[ "$output" == "cpu_m=unknown mem_mi=unknown pods=unknown" ]]
	run cap_parse_requested "w-0" < /dev/null
	[[ "$output" == "cpu_m=unknown mem_mi=unknown pods=unknown" ]]
	run cap_parse_requested "w-0" <<<'{"items":[]}'
	[[ "$output" == "cpu_m=0 mem_mi=0 pods=0" ]]
}

@test "cap_requested: pages the non-terminal pod list of the context and parses it" {
	fake_kubectl() {
		printf '%s\n' "$*" >"${BATS_TEST_TMPDIR}/args"
		echo '{"items":[{"metadata":{"labels":{"app.kubernetes.io/instance":"controlplane-test"}},"spec":{"nodeName":"w-0","containers":[{"resources":{"requests":{"cpu":"100m"}}}]},"status":{"phase":"Running"}},{"spec":{"nodeName":"w-0","containers":[{"resources":{"requests":{"cpu":"2"}}}]},"status":{"phase":"Running"}}]}'
	}
	run cap_requested ctx-a "w-0" "app.kubernetes.io/instance=controlplane-test" fake_kubectl
	[[ "$output" == "cpu_m=2000 mem_mi=0 pods=1" ]]
	grep -q -- '--context=ctx-a' "${BATS_TEST_TMPDIR}/args"
	grep -q -- '--field-selector=status.phase!=Succeeded,status.phase!=Failed' "${BATS_TEST_TMPDIR}/args"
	grep -q -- '--chunk-size=' "${BATS_TEST_TMPDIR}/args"
	# A failed read is unknown and exit 0: `arr=($(cap_requested ...))` must not end a
	# `set -e -o pipefail` caller (nor may the other wrappers).
	run bash -c 'set -euo pipefail; source "$1"; a=($(cap_requested c w-0 "" false)); b=($(cap_node_totals c false)); c=($(cap_istiod_limits c false)); echo "${a[*]} | survived"' _ "${ROOT}/tests/lib/capacity.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=unknown mem_mi=unknown pods=unknown | survived" ]]
}

# ---------------------------------------------------------------------------
# cap_proxy_check (connected proxies vs Running sidecar pods)
# ---------------------------------------------------------------------------

@test "cap_proxy_check: within tolerance -> OK; the campaign's ~1/3 reading -> LOW; more -> HIGH" {
	[[ "$(cap_proxy_check 32 32 10 2)" == "OK" ]]
	[[ "$(cap_proxy_check 35 32 10 2)" == "OK" ]]     # 9.4% apart
	[[ "$(cap_proxy_check 11 32 10 2)" == "LOW" ]]    # one replica's share of three
	[[ "$(cap_proxy_check 40 32 10 2)" == "HIGH" ]]
}

@test "cap_proxy_check: exactly at the tolerance is OK (strict >)" {
	[[ "$(cap_proxy_check 44 40 10 0)" == "OK" ]]
	[[ "$(cap_proxy_check 36 40 10 0)" == "OK" ]]
	[[ "$(cap_proxy_check 45 40 10 0)" == "HIGH" ]]
}

@test "cap_proxy_check: min_diff keeps small clusters from flagging a one-proxy gap" {
	[[ "$(cap_proxy_check 31 32 0 0)" == "LOW" ]]   # tolerance 0, no floor: any gap flags
	[[ "$(cap_proxy_check 31 32 0 2)" == "OK" ]]
	[[ "$(cap_proxy_check 3 5 10 2)" == "OK" ]]     # 40% apart but only 2 proxies
	[[ "$(cap_proxy_check 2 5 10 2)" == "LOW" ]]
	[[ "$(cap_proxy_check 31 32 0)" == "LOW" ]]     # min_diff defaults to 0
}

@test "cap_proxy_check: zero expected" {
	[[ "$(cap_proxy_check 0 0 10 0)" == "OK" ]]
	[[ "$(cap_proxy_check 3 0 10 0)" == "HIGH" ]]
	[[ "$(cap_proxy_check 2 0 10 2)" == "OK" ]]
}

@test "cap_proxy_check: a non-numeric input -> N/A" {
	[[ "$(cap_proxy_check N/A 32 10 2)" == "N/A" ]]
	[[ "$(cap_proxy_check 32 unknown 10 2)" == "N/A" ]]
	[[ "$(cap_proxy_check 32 32 x 2)" == "N/A" ]]
	[[ "$(cap_proxy_check 32 32 10 -1)" == "N/A" ]]
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

# ---------------------------------------------------------------------------
# Shared quantity parsers (decimal suffixes), sidecar requests (BACKLOG 9.7)
# ---------------------------------------------------------------------------

@test "quantities: decimal and binary suffixes parse the same way in jq and awk" {
	run cap_parse_istiod_limits <<'JSON'
{"spec":{"replicas":1,"template":{"spec":{"containers":[{"name":"discovery","resources":{"limits":{"cpu":"4","memory":"8G"}}}]}}}}
JSON
	# 8G = 8e9 bytes = 7629.39 Mi (floored); before the shared parser this was all unknown.
	assert_output "cpu_m=4000 mem_mi=7629 replicas=1"
	run cap_parse_node_totals <<'JSON'
{"items":[{"metadata":{"name":"w-0","labels":{}},"status":{"allocatable":{"cpu":"2500000n","memory":"1000M","pods":"10"}}}]}
JSON
	assert_output "cpu_m=2 mem_mi=953 pods=10 nodes=1 names=w-0"
	run awk "${CAP_AWK_QTY}"'BEGIN { printf "%d %d %d %d %d\n", mem_to_mi("512M"), mem_to_mi("2Gi"), mem_to_mi("1048576"), cpu_to_m("250m"), mem_to_mi("3x") }'
	assert_output "488 2048 1 250 -1"
}

@test "cap_parse_proxy_requests: the Istio CR's sidecar requests, Istio's defaults, unreadable" {
	run cap_parse_proxy_requests <<<'{"items":[{"metadata":{"name":"default"},"spec":{"values":{"global":{"proxy":{"resources":{"requests":{"cpu":"20m","memory":"64Mi"}}}}}}}]}'
	assert_output "cpu_m=20 mem_mi=64 source=istio-cr"
	run cap_parse_proxy_requests <<<'{"items":[{"metadata":{"name":"default"},"spec":{"values":{"global":{"proxy":{"resources":{"requests":{"cpu":"0.25"}}}}}}}]}'
	assert_output "cpu_m=250 mem_mi=128 source=istio-cr"
	run cap_parse_proxy_requests <<<'{"items":[{"metadata":{"name":"default"},"spec":{"values":{}}}]}'
	assert_output "cpu_m=100 mem_mi=128 source=istio-default"
	run cap_parse_proxy_requests <<<'{"items":[]}'
	assert_output "cpu_m=unknown mem_mi=unknown source=unreadable"
	run cap_parse_proxy_requests <<<''
	assert_output "cpu_m=unknown mem_mi=unknown source=unreadable"
}

@test "cap_per_pod_requests: an explicit value wins, else the live CR, else Istio's defaults" {
	kubectl_stub() { echo '{"items":[{"metadata":{"name":"default"},"spec":{"values":{"global":{"proxy":{"resources":{"requests":{"cpu":"20m","memory":"64Mi"}}}}}}}]}'; }
	run cap_per_pod_requests mesh-a "" "" kubectl_stub
	assert_output "cpu_m=20 mem_mi=64 cpu_src=istio-cr_on_mesh-a mem_src=istio-cr_on_mesh-a live=20/64"
	run cap_per_pod_requests mesh-a 200 "" kubectl_stub
	assert_output "cpu_m=200 mem_mi=64 cpu_src=SCALE_PER_POD_CPU_M mem_src=istio-cr_on_mesh-a live=20/64"
	# No context (a dry run): Istio's defaults, said so.
	run cap_per_pod_requests "" "" ""
	assert_output "cpu_m=100 mem_mi=128 cpu_src=istio_default_(no_live_read) mem_src=istio_default_(no_live_read) live=none"
}
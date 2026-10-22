#!/usr/bin/env bats

load test_helper
source "${ROOT}/tests/lib/capacity.sh"

@test "cap_parse_node_totals: the allocatable of the nodes ordinary pods land on: a control-plane or master node only untainted or PreferNoSchedule (kind, kubeadm, k3s, a compact node), never an infra node; none of them, or input that does not parse, is unknown" {
	run cap_parse_node_totals <<'JSON'
{"items":[
  {"metadata":{"name":"cp-0","labels":{"node-role.kubernetes.io/control-plane":""}},
   "spec":{"taints":[{"key":"node-role.kubernetes.io/control-plane","effect":"NoSchedule"}]},
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
	run cap_parse_node_totals <<'JSON'
{"items":[
  {"metadata":{"name":"m-0","labels":{"node-role.kubernetes.io/master":""}},
   "spec":{"taints":[{"key":"node-role.kubernetes.io/master","effect":"NoSchedule"}]},
   "status":{"allocatable":{"cpu":"8","memory":"16Gi","pods":"250"}}},
  {"metadata":{"name":"i-0","labels":{"node-role.kubernetes.io/infra":""}},
   "status":{"allocatable":{"cpu":"8","memory":"16Gi","pods":"250"}}},
  {"metadata":{"name":"w-0","labels":{}},
   "status":{"allocatable":{"cpu":"4","memory":"8Gi","pods":"110"}}}
]}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=4000 mem_mi=8192 pods=110 nodes=1 names=w-0" ]]
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
	run cap_parse_node_totals <<'JSON'
{"items":[
  {"metadata":{"name":"cp-0","labels":{"node-role.kubernetes.io/control-plane":""}},
   "spec":{"taints":[{"key":"node-role.kubernetes.io/control-plane","effect":"NoSchedule"}]},
   "status":{"allocatable":{"cpu":"8","memory":"16Gi","pods":"250"}}}
]}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=unknown mem_mi=unknown pods=unknown nodes=0 names=" ]]
	run cap_parse_node_totals <<'JSON'
{"items":[
  {"metadata":{"name":"kind-0","labels":{"node-role.kubernetes.io/control-plane":""}},
   "spec":{"providerID":"kind://docker/x/kind-0"},
   "status":{"allocatable":{"cpu":"4","memory":"16Gi","pods":"110"}}}
]}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=4000 mem_mi=16384 pods=110 nodes=1 names=kind-0" ]]
	# NoSchedule and NoExecute keep ordinary pods off, PreferNoSchedule does not; an
	# untainted infra node stays out, with or without a control-plane label.
	run cap_parse_node_totals <<'JSON'
{"items":[
  {"metadata":{"name":"cp-ns","labels":{"node-role.kubernetes.io/control-plane":""}},
   "spec":{"taints":[{"key":"dedicated","value":"x","effect":"NoSchedule"}]},
   "status":{"allocatable":{"cpu":"8","memory":"16Gi","pods":"250"}}},
  {"metadata":{"name":"m-ne","labels":{"node-role.kubernetes.io/master":""}},
   "spec":{"taints":[{"key":"node.kubernetes.io/not-ready","effect":"NoExecute"}]},
   "status":{"allocatable":{"cpu":"8","memory":"16Gi","pods":"250"}}},
  {"metadata":{"name":"cp-pref","labels":{"node-role.kubernetes.io/control-plane":""}},
   "spec":{"taints":[{"key":"node-role.kubernetes.io/control-plane","effect":"PreferNoSchedule"}]},
   "status":{"allocatable":{"cpu":"2","memory":"4Gi","pods":"110"}}},
  {"metadata":{"name":"m-0","labels":{"node-role.kubernetes.io/master":""}},
   "status":{"allocatable":{"cpu":"1","memory":"2Gi","pods":"110"}}},
  {"metadata":{"name":"cp-inf","labels":{"node-role.kubernetes.io/control-plane":"","node-role.kubernetes.io/infra":""}},
   "status":{"allocatable":{"cpu":"8","memory":"16Gi","pods":"250"}}}
]}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=3000 mem_mi=6144 pods=220 nodes=2 names=cp-pref,m-0" ]]
	run cap_parse_node_totals <<<'not json'
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=unknown mem_mi=unknown pods=unknown nodes=0 names=" ]]
	run cap_parse_node_totals < /dev/null
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=unknown mem_mi=unknown pods=unknown nodes=0 names=" ]]
}

@test "cap_parse_top_nodes: the named worker rows' kubectl top figures summed; none named, or no output (metrics-server absent), is unknown" {
	run cap_parse_top_nodes "w-0,w-1" <<'TOP'
cp-0   200m   2%   900Mi   5%
w-0    1500m  18%  4096Mi  25%
w-1    1      12%  2Gi     12%
TOP
	[ "$status" -eq 0 ]
	# cpu: 1500 + 1000 = 2500; mem: 4096 + 2048 = 6144
	[[ "$output" == "cpu_m=2500 mem_mi=6144" ]]
	run cap_parse_top_nodes "w-0,w-1" <<<''
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=unknown mem_mi=unknown" ]]
	run cap_parse_top_nodes "w-9" <<'TOP'
w-0    1500m  18%  4096Mi  25%
TOP
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=unknown mem_mi=unknown" ]]
}

@test "cap_parse_istiod_limits: the discovery container's limits (its requests without limits) and replicas; no istiod container or input that does not parse is unknown" {
	run cap_parse_istiod_limits <<'JSON'
{"spec":{"replicas":2,"template":{"spec":{"containers":[
  {"name":"discovery","resources":{"limits":{"cpu":"2","memory":"8Gi"},
   "requests":{"cpu":"500m","memory":"2Gi"}}}
]}}}}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=2000 mem_mi=8192 replicas=2" ]]
	run cap_parse_istiod_limits <<'JSON'
{"spec":{"replicas":1,"template":{"spec":{"containers":[
  {"name":"discovery","resources":{"requests":{"cpu":"250m","memory":"1Gi"}}}
]}}}}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=250 mem_mi=1024 replicas=1" ]]
	run cap_parse_istiod_limits <<'JSON'
{"spec":{"replicas":1,"template":{"spec":{"containers":[
  {"name":"other","resources":{"limits":{"cpu":"1","memory":"1Gi"}}}
]}}}}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=unknown mem_mi=unknown replicas=unknown" ]]
	run cap_parse_istiod_limits <<<'not json'
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=unknown mem_mi=unknown replicas=unknown" ]]
	run cap_parse_istiod_limits < /dev/null
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=unknown mem_mi=unknown replicas=unknown" ]]
}

@test "cap_parse_pod_count: Running and Pending pods on the workers; sidecars are Running, not terminating, injected pods on any node; no worker list is scheduled unknown (never 0), input that does not parse both unknown" {
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
	run cap_parse_pod_count "" <<'JSON'
{"items":[{"metadata":{"annotations":{"sidecar.istio.io/status":"{}"}},"spec":{"nodeName":"cp-0"},"status":{"phase":"Running"}}]}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "scheduled=unknown sidecars=1" ]]
	run cap_parse_pod_count "w-0" <<<'not json'
	[ "$status" -eq 0 ]
	[[ "$output" == "scheduled=unknown sidecars=unknown" ]]
	run cap_parse_pod_count "w-0" < /dev/null
	[ "$status" -eq 0 ]
	[[ "$output" == "scheduled=unknown sidecars=unknown" ]]
}

@test "cap_parse_requested: the requests on the workers with the scheduler's init, sidecar and overhead rules, a terminating pod's included, the test's own pods left out by label; no worker or input that does not parse is unknown, an empty list 0" {
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
	run cap_parse_requested "w-0" "app.kubernetes.io/instance=controlplane-test" <<'JSON'
{"items":[
  {"metadata":{"labels":{"app.kubernetes.io/instance":"controlplane-test"}},"spec":{"nodeName":"w-0","containers":[{"resources":{"requests":{"cpu":"100m"}}}]},"status":{"phase":"Running"}},
  {"metadata":{"labels":{"app.kubernetes.io/instance":"other"}},"spec":{"nodeName":"w-0","containers":[{"resources":{"requests":{"cpu":"300m"}}}]},"status":{"phase":"Running"}},
  {"spec":{"nodeName":"w-0","containers":[{"resources":{"requests":{"cpu":"7900m","memory":"8G"}}}]},"status":{"phase":"Running"}}
]}
JSON
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=8200 mem_mi=7629 pods=2" ]]
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
	# `set -e -o pipefail` caller (nor may the other wrappers), and each prints its parser's
	# all-unknown line.
	run bash -c 'set -euo pipefail; source "$1"; a=($(cap_requested c w-0 "" false)); b=($(cap_node_totals c false)); c=($(cap_istiod_limits c false)); echo "${a[*]} | ${b[*]} | ${c[*]} | survived"' _ "${ROOT}/tests/lib/capacity.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == "cpu_m=unknown mem_mi=unknown pods=unknown | cpu_m=unknown mem_mi=unknown pods=unknown nodes=0 names= | cpu_m=unknown mem_mi=unknown replicas=unknown | survived" ]]
}

@test "cap_proxy_check: connected proxies within the tolerance of the Running sidecar pods (strict >) or within min_diff are OK, fewer LOW (the campaign's ~1/3 reading), more HIGH; a non-numeric input is N/A" {
	[[ "$(cap_proxy_check 32 32 10 2)" == "OK" ]]
	[[ "$(cap_proxy_check 35 32 10 2)" == "OK" ]]     # 9.4% apart
	[[ "$(cap_proxy_check 11 32 10 2)" == "LOW" ]]    # one replica's share of three
	[[ "$(cap_proxy_check 40 32 10 2)" == "HIGH" ]]
	[[ "$(cap_proxy_check 44 40 10 0)" == "OK" ]]
	[[ "$(cap_proxy_check 36 40 10 0)" == "OK" ]]
	[[ "$(cap_proxy_check 45 40 10 0)" == "HIGH" ]]
	[[ "$(cap_proxy_check 31 32 0 0)" == "LOW" ]]   # tolerance 0, no floor: any gap flags
	[[ "$(cap_proxy_check 31 32 0 2)" == "OK" ]]
	[[ "$(cap_proxy_check 3 5 10 2)" == "OK" ]]     # 40% apart but only 2 proxies
	[[ "$(cap_proxy_check 2 5 10 2)" == "LOW" ]]
	[[ "$(cap_proxy_check 31 32 0)" == "LOW" ]]     # min_diff defaults to 0
	[[ "$(cap_proxy_check 0 0 10 0)" == "OK" ]]
	[[ "$(cap_proxy_check 3 0 10 0)" == "HIGH" ]]
	[[ "$(cap_proxy_check 2 0 10 2)" == "OK" ]]
	[[ "$(cap_proxy_check N/A 32 10 2)" == "N/A" ]]
	[[ "$(cap_proxy_check 32 unknown 10 2)" == "N/A" ]]
	[[ "$(cap_proxy_check 32 32 x 2)" == "N/A" ]]
	[[ "$(cap_proxy_check 32 32 10 -1)" == "N/A" ]]
}

@test "cap_pct and cap_max_pods: a rounded %, unknown for a zero total or an input not read; the pods that fit, bound by CPU, memory or the pod count after istiod and the headroom, at least 1, unknown for an input not read or no per-pod cost" {
	[[ "$(cap_pct 1500 8000)" == "19" ]]
	[[ "$(cap_pct 5 10)" == "50" ]]
	[[ "$(cap_pct 5 0)" == "unknown" ]]
	[[ "$(cap_pct unknown 100)" == "unknown" ]]
	[[ "$(cap_pct 5 unknown)" == "unknown" ]]
	[[ "$(cap_pct N/A 100)" == "unknown" ]]
	# alloc 16000m/64000Mi/500 pods; istiod 2000m*1rep; per-pod 200m/256Mi:
	# CPU (16000-2000)*0.85*0.7 = 8330 -> 41; memory (64000-1024)*0.595 = 37470 -> 146; pods 350.
	[[ "$(cap_max_pods 16000 64000 500 2000 1024 1 200 256 0.7 0.15)" == 41 ]]
	# Per-pod memory 2048Mi: 37470 / 2048 -> 18; 10 allocatable pods: 7; no room: 1.
	[[ "$(cap_max_pods 16000 64000 500 2000 1024 1 200 2048 0.7 0.15)" == 18 ]]
	[[ "$(cap_max_pods 16000 64000 10 2000 1024 1 200 256 0.7 0.15)" == 7 ]]
	[[ "$(cap_max_pods 2100 64000 500 2000 1024 1 200 256 0.7 0.15)" == 1 ]]
	[[ "$(cap_max_pods unknown 64000 500 2000 1024 1 200 256 0.7 0.15)" == "unknown" ]]
	[[ "$(cap_max_pods 16000 64000 500 2000 unknown 1 200 256 0.7 0.15)" == "unknown" ]]
	[[ "$(cap_max_pods 16000 64000 500 2000 1024 1 0 256 0.7 0.15)" == "unknown" ]]
}

@test "_cap_retry_nonempty: the first non-empty result, retried after empty ones up to CAP_TOP_ATTEMPTS; none is empty output and exit 0 (never fails the pipe)" {
	CAP_TOP_ATTEMPTS=3 CAP_TOP_BACKOFF_S=0 run _cap_retry_nonempty echo "hi"
	[ "$status" -eq 0 ]
	[[ "$output" == "hi" ]]
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
	CAP_TOP_ATTEMPTS=2 CAP_TOP_BACKOFF_S=0 run _cap_retry_nonempty true
	[ "$status" -eq 0 ]
	[[ -z "$output" ]]
}

@test "quantities: Ki, Mi, decimal and binary suffixes parse the same way in jq and awk, floored to whole Mi" {
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

@test "cap_parse_proxy_requests and cap_per_pod_requests: an explicit value wins, else the Istio CR's sidecar requests, else Istio's defaults, each with its source; unreadable is unknown" {
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
	kubectl_stub() { echo '{"items":[{"metadata":{"name":"default"},"spec":{"values":{"global":{"proxy":{"resources":{"requests":{"cpu":"20m","memory":"64Mi"}}}}}}}]}'; }
	run cap_per_pod_requests mesh-a "" "" kubectl_stub
	assert_output "cpu_m=20 mem_mi=64 cpu_src=istio-cr_on_mesh-a mem_src=istio-cr_on_mesh-a live=20/64"
	run cap_per_pod_requests mesh-a 200 "" kubectl_stub
	assert_output "cpu_m=200 mem_mi=64 cpu_src=SCALE_PER_POD_CPU_M mem_src=istio-cr_on_mesh-a live=20/64"
	# No context (a dry run): Istio's defaults, said so.
	run cap_per_pod_requests "" "" ""
	assert_output "cpu_m=100 mem_mi=128 cpu_src=istio_default_(no_live_read) mem_src=istio_default_(no_live_read) live=none"
}

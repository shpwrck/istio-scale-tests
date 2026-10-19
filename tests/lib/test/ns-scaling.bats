#!/usr/bin/env bats
# Namespace scaling (controlplane growth mode): tests/lib/fit.sh, tests/lib/growth.sh,
# the growth validators and preamble emitters, the chart's block layout, and the
# growth paths of 001, 003 and 005 through their real entrypoints in --dry-run (PL33;
# CI's ci-dry-run smoke runs only one argument set per script).

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/fit.sh"
source "${ROOT}/tests/lib/growth.sh"
source "${ROOT}/tests/lib/preamble.sh"

CP="${ROOT}/tests/controlplane"
CHART="${CP}/chart"

# ---------------------------------------------------------------------------
# fit.sh
# ---------------------------------------------------------------------------

@test "fit_linear: y = 2x + 3 -> slope 2, intercept 3, R2 1" {
	run fit_linear <<<$'1 5\n2 7\n4 11\n8 19'
	assert_success
	assert_output "2 3 1.0000 4"
}

@test "fit_linear: fewer than 2 distinct x, or non-numeric points, give N/A" {
	run fit_linear <<<$'5 10'
	assert_output "N/A N/A N/A 1"
	run fit_linear <<<$'5 10\n5 12'
	assert_output "N/A N/A N/A 2"
	# N/A and overflow are skipped, never read as 0.
	run fit_linear <<<$'1 2\n2 N/A\n3 6\n4 overflow'
	assert_output "2 0 1.0000 2"
}

@test "fit_loglog: y = x^2 -> 2.00, y = 3x -> 1.00, non-positive points dropped" {
	run fit_loglog <<<$'100 10000\n200 40000\n400 160000\n800 640000'
	assert_output "2.00"
	run fit_loglog <<<$'100 300\n200 600\n0 0\n400 1200'
	assert_output "1.00"
	run fit_loglog <<<$'100 -1\n200 5'
	assert_output "N/A"
}

@test "mem_guard_project: base + (cur - base) x ratio^power, never below cur" {
	# The design's example: 1000 Mi at N=500, next N=1000, empty-mesh base 200 Mi.
	[ "$(mem_guard_project 1000 200 2 1)" = 1800 ]
	[ "$(mem_guard_project 1000 200 2 2)" = 3400 ]
	# The first step (ratio 1) is current usage only.
	[ "$(mem_guard_project 1000 200 1 1)" = 1000 ]
	# Usage below the base projects as the base (conservative).
	[ "$(mem_guard_project 150 200 4 2)" = 200 ]
	[ "$(mem_guard_project N/A 200 2 1)" = unknown ]
}

@test "mem_guard_verdict: stop above pct of the limit, unknown without a limit" {
	# 70% of 3072 Mi = 2150.4 Mi: linear 1800 runs, wide 3400 stops, 300 runs.
	[ "$(mem_guard_verdict 1800 3072 70)" = ok ]
	[ "$(mem_guard_verdict 3400 3072 70)" = stop ]
	[ "$(mem_guard_verdict 300 3072 70)" = ok ]
	# The L2b proof setting (5%) stops even the first step at current usage.
	[ "$(mem_guard_verdict 300 3072 5)" = stop ]
	[ "$(mem_guard_verdict 300 unknown 70)" = unknown ]
	[ "$(mem_guard_verdict 300 0 70)" = unknown ]
}

# ---------------------------------------------------------------------------
# common.sh validators, preamble.sh emitters, growth.sh parsers
# ---------------------------------------------------------------------------

@test "validators: wide scoping, workload and outside modes" {
	run validate_scoping wide
	assert_success
	run validate_workload_mode config-only
	assert_success
	run validate_workload_mode configonly
	assert_failure
	assert_output --partial "[pods, config-only]"
	run validate_outside_mode labeled
	assert_success
	run validate_outside_mode outside
	assert_failure
	assert_output --partial "[none, unlabeled, labeled]"
}

@test "growth_preamble_lines: every key, unknown when omitted, values overlaid" {
	run growth_preamble_lines SERVICES_PER_NAMESPACE=2 GROWTH_MODE=in-place BOGUS=1
	assert_success
	[ "$(grep -c '^# [A-Z_]*=' <<<"$output")" -eq 14 ]
	assert_output --partial "# SERVICES_PER_NAMESPACE=2"
	assert_output --partial "# GROWTH_MODE=in-place"
	assert_output --partial "# MEM_GUARD_CONTEXTS=unknown"
	refute_output --partial "BOGUS"
}

@test "ns_lifecycle_init/row: one preamble and header, rates from the duration" {
	source "${ROOT}/tests/lib/config.sh"    # config_preamble_lines
	source "${ROOT}/tests/lib/platform.sh"  # platform_preamble_lines
	f="${BATS_TEST_TMPDIR}/lc/ns-lifecycle.tsv"
	PLATFORM_PROBE_ROWS=$'mesh-a\tkubernetes\tsail-operator:1.31.1/Available\tpilot:1.30.5\tproxyv2:1.30.5\tkind\n'
	PLATFORM_PROBE_LAST=mesh-a
	ns_lifecycle_init "$f" run-1
	ns_lifecycle_init "$f" run-2
	[ "$(grep -c '^# RUN_ID=' "$f")" -eq 1 ]
	grep -q '^# RUN_ID=run-1$' "$f"
	grep -q '^# NS_LIFECYCLE_SCHEMA=2$' "$f"
	# The run config and the platform record (H12): its objects/s figures are quoted in campaigns.
	grep -qx '# RUN_CONFIG=none' "$f"
	grep -qx '# PLATFORM=kubernetes' "$f"
	grep -qx '# ISTIOD_IMAGE_BY_CONTEXT=mesh-a=pilot:1.30.5' "$f"
	grep -qx '# NODE_PROVIDER_BY_CONTEXT=mesh-a=kind' "$f"
	# Before the header.
	[ "$(grep -n '^# PLATFORM=' "$f" | cut -d: -f1)" -lt "$(grep -n '^timestamp' "$f" | cut -d: -f1)" ]
	ns_lifecycle_row "$f" mesh-a s1 100 grow 100 500 10.0 2 1 7 OK
	ns_lifecycle_row "$f" mesh-a s1 100 ready N/A 4 0 N/A N/A N/A OK
	run awk -F'\t' '!/^#/ { print NF }' "$f"
	assert_output $'14\n14\n14'
	[ "$(awk -F'\t' '$1 == "timestamp" { print $11, $12, $13 }' "$f")" = "api_429_retried api_429_exhausted client_throttle_waits" ]
	[ "$(awk -F'\t' '$5 == "grow" { print $9, $10, $11, $12, $13, $14 }' "$f")" = "50.00 10.000 2 1 7 OK" ]
	[ "$(awk -F'\t' '$5 == "ready" { print $9, $10, $11 }' "$f")" = "N/A N/A N/A" ]
	# No file: a no-op (a step run standalone).
	run ns_lifecycle_row "" mesh-a s1 1 grow 1 1 1 0 0 0 OK
	assert_success
}

@test "ns_lifecycle_init: without a platform_probe in the shell the record reads unknown; without config.sh or platform.sh it refuses" {
	# (A standalone 001 or 005 probes before it creates the file: platform.bats, H3.)
	source "${ROOT}/tests/lib/config.sh"
	source "${ROOT}/tests/lib/platform.sh"
	f="${BATS_TEST_TMPDIR}/lc/standalone.tsv"
	(unset PLATFORM_PROBE_ROWS PLATFORM_PROBE_LAST; ns_lifecycle_init "$f" standalone-001)
	grep -qx '# PLATFORM=unknown' "$f"
	grep -qx '# PLATFORM_BY_CONTEXT=unknown' "$f"
	run bash -c 'source "$1/tests/lib/common.sh"; source "$1/tests/lib/preamble.sh"; ns_lifecycle_init "$2" r' _ "$ROOT" "${BATS_TEST_TMPDIR}/lc/x.tsv"
	assert_failure
	assert_output --partial "ns_lifecycle_init needs config_preamble_lines (source tests/lib/config.sh)"
	run bash -c 'source "$1/tests/lib/common.sh"; source "$1/tests/lib/config.sh"; source "$1/tests/lib/preamble.sh"; ns_lifecycle_init "$2" r' _ "$ROOT" "${BATS_TEST_TMPDIR}/lc/y.tsv"
	assert_failure
	assert_output --partial "ns_lifecycle_init needs platform_preamble_lines (source tests/lib/platform.sh)"
	[ ! -e "${BATS_TEST_TMPDIR}/lc/x.tsv" ]
	[ ! -e "${BATS_TEST_TMPDIR}/lc/y.tsv" ]
}

@test "ns_lifecycle_api_counts: retried and exhausted 429s from kubectl -v=4, never a 429 in a name, URL or timestamp" {
	# Lines in the form kubectl v1.34 prints at -v=4 against a server that answers 429 +
	# Retry-After (client-go retries it silently at the default verbosity). The klog
	# timestamps, PIDs, namespace names and series id all contain "429".
	e="${BATS_TEST_TMPDIR}/err"
	cat > "$e" <<'ERR'
I1013 14:29:08.959429 2060429 envvar.go:172] "Feature gate default state" feature="WatchListClient" enabled=false
I1013 14:29:09.963327 2060429 with_retry.go:234] "Got a Retry-After response" delay="1s" attempt=1 url="https://<api-host>/api/v1/namespaces/cp-s1013142900-1-429?fieldManager=kubectl&force=true"
I1013 14:29:11.066820 2060429 with_retry.go:234] "Got a Retry-After response" delay="1s" attempt=2 url="https://<api-host>/api/v1/namespaces/cp-s1013142900-1-429?fieldManager=kubectl&force=true"
I1013 14:29:12.167233 2060429 request.go:752] "Waited before sending request" delay="1.2s" reason="client-side throttling, not priority and fairness" verb="PATCH" URL="https://<api-host>/api/v1/namespaces/cp-s1013142900-1-4290"
I1013 14:29:41.435498 2060429 helpers.go:246] server response object: %s[{
  "kind": "Status",
  "reason": "TooManyRequests",
  "code": 429
}]
Error from server (TooManyRequests): Too many requests, please try again later.
error: namespace cp-s1013142900-1-1429 is invalid
ERR
	run ns_lifecycle_api_counts "$e"
	assert_output "2 1 1"
	# Without -v=4 a retried 429 leaves nothing; only an exhausted one shows.
	printf 'Error from server (TooManyRequests): the server has received too many requests\n' > "$e"
	run ns_lifecycle_api_counts "$e"
	assert_output "0 1 0"
	run ns_lifecycle_api_counts "${BATS_TEST_TMPDIR}/missing"
	assert_output "0 0 0"
}

@test "growth_parse_envoy_stats / growth_istiod_heap_mi / growth_parse_gateway_pods" {
	run growth_parse_envoy_stats <<<$'cluster_manager.active_clusters: 123\nserver.memory_allocated: 52428800'
	assert_output "mem_mi=50 clusters=123 physical_mi=unknown"
	run growth_parse_envoy_stats <<<""
	assert_output "mem_mi=unknown clusters=unknown physical_mi=unknown"
	printf 'go_memstats_heap_inuse_bytes 104857600\n' > "${BATS_TEST_TMPDIR}/m"
	[ "$(growth_istiod_heap_mi "${BATS_TEST_TMPDIR}/m")" = 100 ]
	[ "$(growth_istiod_heap_mi "${BATS_TEST_TMPDIR}/missing")" = unknown ]
	run growth_parse_gateway_pods <<<'{"items":[
		{"metadata":{"name":"gw-a"},"status":{"phase":"Running"},"spec":{"containers":[{"name":"istio-proxy","resources":{"limits":{"memory":"1Gi"}}}]}},
		{"metadata":{"name":"gw-b"},"status":{"phase":"Pending"},"spec":{"containers":[{"name":"istio-proxy"}]}},
		{"metadata":{"name":"gw-c"},"status":{"phase":"Running"},"spec":{"containers":[{"name":"istio-proxy"}]}}]}'
	assert_output $'gw-a\t1024\tunknown\ngw-c\tunknown\tunknown'
}

@test "config: the growth keys, plural CSV ones included (PL7), are run-config keys" {
	source "${ROOT}/tests/lib/config.sh"
	run config_allowed_keys controlplane
	for k in CONTROLPLANE_SERVICES_PER_NAMESPACE CONTROLPLANE_SERVICES_PER_NAMESPACES CONTROLPLANE_GROWTH_MODE \
		CONTROLPLANE_WORKLOAD_MODE CONTROLPLANE_MEASUREMENT_PODS CONTROLPLANE_MEASUREMENT_POD_COUNTS \
		CONTROLPLANE_OUTSIDE_NAMESPACES CONTROLPLANE_OUTSIDE_MODE CONTROLPLANE_OUTSIDE_MODES \
		CONTROLPLANE_PROBE_SETTLE_SEC CONTROLPLANE_MEM_STOP_PCT CONTROLPLANE_MEM_GUARD_CONTEXTS \
		CONTROLPLANE_SERIES_RETIRE CONTROLPLANE_NS_DELETE_SEC_PER_NS; do
		grep -qx "$k" <<<"$output" || { echo "missing key $k"; false; }
	done
}

@test "configs: the namespace-scaling examples load and keep SETUP_CONTEXTS commented out" {
	source "${ROOT}/tests/lib/config.sh"
	for f in ns-scaling-lab.env ns-scaling-rosa.env; do
		run load_config "${CP}/configs/$f" controlplane
		assert_success
		! grep -q '^SETUP_CONTEXTS=' "${CP}/configs/$f"
	done
}

# ---------------------------------------------------------------------------
# Chart: block layout renders (helm template, no cluster)
# ---------------------------------------------------------------------------

# kinds <helm args...>: "<count> <kind>" lines of a render, sorted by kind.
kinds() {
	helm template controlplane-test "$CHART" "$@" | awk '/^kind:/ { n[$2]++ } END { for (k in n) print n[k], k }' | sort -k2
}

# no_blank: drop empty lines. The golden is a helm 4 render, which keeps the blank line a
# template ends with; helm 3 drops it. Both are supported, and YAML ignores those lines.
no_blank() { grep -v '^$' || true; }

@test "chart: the legacy layout renders the pre-growth golden line for line" {
	command -v helm >/dev/null || skip "helm not installed"
	run --separate-stderr helm template controlplane-test "$CHART" --set namespaceCount=2 --set serviceCount=4 \
		--set replicasPerService=1 --set sidecarScoping=namespace --set clusterName=ci --set image.tag=1.37.0
	assert_success
	diff <(printf '%s\n' "$output" | no_blank) <(no_blank <"${ROOT}/tests/lib/test/fixtures/controlplane_chart_legacy.yaml")
}

@test "chart: the OpenShift overlay renders the legacy golden minus its runAsUser lines" {
	# The golden is the Kubernetes render; without its runAsUser: 65534 lines it is the render
	# from before the Kubernetes default, so OpenShift members keep that render line for line.
	command -v helm >/dev/null || skip "helm not installed"
	run --separate-stderr helm template controlplane-test "$CHART" -f "${CHART}/values-openshift.yaml" --set namespaceCount=2 \
		--set serviceCount=4 --set replicasPerService=1 --set sidecarScoping=namespace --set clusterName=ci --set image.tag=1.37.0
	assert_success
	grep -q '^ *runAsUser: 65534$' "${ROOT}/tests/lib/test/fixtures/controlplane_chart_legacy.yaml"
	diff <(printf '%s\n' "$output" | no_blank) <(grep -v '^ *runAsUser: 65534$' "${ROOT}/tests/lib/test/fixtures/controlplane_chart_legacy.yaml" | no_blank)
}

@test "chart: N=50 K=2 config-only M=4 per-kind counts for none, namespace and wide" {
	command -v helm >/dev/null || skip "helm not installed"
	base=(--set servicesPerNamespace=2 --set namespaceCount=50 --set workload.mode=config-only --set series=s1)
	[ "$(kinds "${base[@]}")" = $'4 Deployment\n50 Namespace\n100 Service' ]
	[ "$(kinds "${base[@]}" --set sidecarScoping=namespace)" = $'4 Deployment\n50 Namespace\n100 Service\n50 Sidecar' ]
	run helm template controlplane-test "$CHART" "${base[@]}" --set sidecarScoping=wide --show-only templates/sidecar.yaml
	[ "$(grep -c '^        - "\*/\*"$' <<<"$output")" -eq 50 ]
	[ "$(grep -c 'controlplane-test.scope: wide' <<<"$output")" -eq 50 ]
	# Block layout: namespace n holds dummy-svc-0..K-1; names carry the series.
	run helm template controlplane-test "$CHART" "${base[@]}" --show-only templates/dummy-service.yaml
	[ "$(grep -c 'namespace: controlplane-test-s1-49$' <<<"$output")" -eq 2 ]
	[ "$(grep -c 'controlplane-test.series: "s1"' <<<"$output")" -eq 100 ]
}

@test "chart: namespaceStart renders only the new namespaces; measurement pods only below M" {
	command -v helm >/dev/null || skip "helm not installed"
	[ "$(kinds --set servicesPerNamespace=2 --set namespaceCount=50 --set namespaceStart=25 --set workload.mode=config-only --set sidecarScoping=namespace)" = \
		$'25 Namespace\n50 Service\n25 Sidecar' ]
	[ "$(kinds --set servicesPerNamespace=2 --set namespaceCount=50 --set namespaceStart=2 --set workload.mode=config-only)" = \
		$'2 Deployment\n48 Namespace\n96 Service' ]
	run helm template controlplane-test "$CHART" --set servicesPerNamespace=2 --set namespaceCount=50 \
		--set workload.mode=config-only --show-only templates/dummy-deployment.yaml
	assert_output --partial 'sidecar.istio.io/proxyMemoryLimit: "2Gi"'
	assert_output --partial 'controlplane-test.measurement: "true"'
	[ "$(kinds --set servicesPerNamespace=3 --set namespaceCount=4 --set replicasPerService=2)" = $'12 Deployment\n4 Namespace\n12 Service' ]
}

@test "chart: outside namespaces carry istio-discovery only when labeled, never istio.io/rev" {
	command -v helm >/dev/null || skip "helm not installed"
	o=(--set servicesPerNamespace=2 --set namespaceCount=5 --set outside.count=10 --set series=s1 --show-only templates/outside.yaml)
	run helm template controlplane-test "$CHART" "${o[@]}" --set outside.mode=labeled
	[ "$(grep -c '^kind: Namespace' <<<"$output")" -eq 10 ]
	[ "$(grep -c '^kind: Service' <<<"$output")" -eq 20 ]
	[ "$(grep -c 'istio-discovery: enabled' <<<"$output")" -eq 10 ]
	assert_output --partial "name: controlplane-test-s1-out-9"
	refute_output --partial "istio.io/rev"
	run helm template controlplane-test "$CHART" "${o[@]}" --set outside.mode=unlabeled
	refute_output --partial "istio-discovery"
	[ "$(grep -c 'app.kubernetes.io/instance: controlplane-test' <<<"$output")" -eq 30 ]
}

@test "chart: probe namespace = K Services + the scoping's Sidecar, no pods" {
	command -v helm >/dev/null || skip "helm not installed"
	p=(--set servicesPerNamespace=3 --set namespaceCount=5 --set probe.name=controlplane-test-s1-p1 --show-only templates/probe.yaml)
	run helm template controlplane-test "$CHART" "${p[@]}" --set sidecarScoping=wide
	[ "$(grep -c '^kind:' <<<"$output")" -eq 5 ]
	assert_output --partial 'controlplane-test.probe: "true"'
	assert_output --partial '- "*/*"'
	run helm template controlplane-test "$CHART" "${p[@]}"
	[ "$(grep -c '^kind: Sidecar' <<<"$output")" -eq 0 ]
	[ "$(grep -c '^kind: Deployment' <<<"$output")" -eq 0 ]
}

@test "chart: growth refuses explicit, vsdr and a namespaceStart past N; legacy refuses growth values" {
	command -v helm >/dev/null || skip "helm not installed"
	run helm template controlplane-test "$CHART" --set servicesPerNamespace=2 --set namespaceCount=5 --set sidecarScoping=explicit
	assert_failure
	assert_output --partial "sidecarScoping explicit is not supported with servicesPerNamespace > 0"
	run helm template controlplane-test "$CHART" --set servicesPerNamespace=2 --set namespaceCount=5 --set trafficConfig.mode=vsdr
	assert_failure
	run helm template controlplane-test "$CHART" --set servicesPerNamespace=2 --set namespaceCount=5 --set namespaceStart=5
	assert_failure
	run helm template controlplane-test "$CHART" --set workload.mode=config-only
	assert_failure
	assert_output --partial "need the block layout"
}

# ---------------------------------------------------------------------------
# 001 --dry-run: renders, splits into batches, prints the plan; no cluster contact.
# ---------------------------------------------------------------------------

@test "001 --dry-run growth: a grow step, a scoping switch, outside, probe and measurement parts" {
	command -v helm >/dev/null || skip "helm not installed"
	g=(--dry-run --contexts ci-dummy --services-per-namespace 2 --series s1 --workload-mode config-only)
	KUBECONFIG=/dev/null run "${CP}/001-setup-controlplane-test.sh" "${g[@]}" --namespace-count 50 --namespace-start 25 --sidecar-scoping namespace
	assert_success
	assert_output --partial "render: 25 Namespace, 50 Service, 25 Sidecar (1 namespace batch(es), 1 object batch(es) of up to 200)"
	# -v=4 so client-go's silent 429 retries are logged and counted (ns-lifecycle TSV).
	assert_output --partial "apply --server-side --force-conflicts -v=4 --context=ci-dummy"
	KUBECONFIG=/dev/null run "${CP}/001-setup-controlplane-test.sh" "${g[@]}" --namespace-count 50 --sidecar-scoping wide --parts sidecars
	assert_success
	assert_output --partial "render: 50 Sidecar"
	KUBECONFIG=/dev/null run "${CP}/001-setup-controlplane-test.sh" "${g[@]}" --namespace-count 50 --sidecar-scoping none --parts sidecars
	assert_success
	assert_output --partial "delete sidecars.networking.istio.io -A -l 'app.kubernetes.io/instance=controlplane-test,controlplane-test.series=s1,!controlplane-test.probe'"
	assert_output --partial "--wait=true --timeout=300s -v=4"
	KUBECONFIG=/dev/null run "${CP}/001-setup-controlplane-test.sh" "${g[@]}" --namespace-count 50 --outside-namespaces 10 --outside-mode labeled --parts outside
	assert_success
	assert_output --partial "render: 10 Namespace, 20 Service"
	KUBECONFIG=/dev/null run "${CP}/001-setup-controlplane-test.sh" "${g[@]}" --namespace-count 50 --sidecar-scoping wide --parts probe --probe controlplane-test-s1-p1
	assert_success
	assert_output --partial "render: 1 Namespace, 2 Service, 1 Sidecar"
	KUBECONFIG=/dev/null run "${CP}/001-setup-controlplane-test.sh" "${g[@]}" --namespace-count 50 --measurement-pods 16 --parts measurement
	assert_success
	assert_output --partial "render: 16 Deployment"
}

@test "001 --dry-run: Namespace docs are chunked too (500 namespaces -> 3 namespace batches)" {
	command -v helm >/dev/null || skip "helm not installed"
	KUBECONFIG=/dev/null run "${CP}/001-setup-controlplane-test.sh" --dry-run --contexts ci-dummy \
		--services-per-namespace 1 --namespace-count 500 --workload-mode config-only --series s1 --sidecar-scoping namespace
	assert_success
	assert_output --partial "render: 4 Deployment, 500 Namespace, 500 Service, 500 Sidecar (3 namespace batch(es), 6 object batch(es) of up to 200)"
}

@test "001: growth refusals name the conflict" {
	KUBECONFIG=/dev/null run "${CP}/001-setup-controlplane-test.sh" --dry-run --contexts ci-dummy --services-per-namespace 2 --namespace-count 5 --sidecar-scoping explicit
	assert_failure
	assert_output --partial "explicit is not supported with --services-per-namespace"
	KUBECONFIG=/dev/null run "${CP}/001-setup-controlplane-test.sh" --dry-run --contexts ci-dummy --parts sidecars
	assert_failure
	assert_output --partial "--parts sidecars needs --services-per-namespace > 0"
	KUBECONFIG=/dev/null run "${CP}/001-setup-controlplane-test.sh" --dry-run --contexts ci-dummy --services-per-namespace 2 --namespace-count 5 --parts probe
	assert_failure
	assert_output --partial "--parts probe requires --probe NAME"
	KUBECONFIG=/dev/null run "${CP}/001-setup-controlplane-test.sh" --dry-run --contexts ci-dummy --services-per-namespace 2 --namespace-count 5 --namespace-start 5
	assert_failure
	assert_output --partial "--namespace-start (5) must be below --namespace-count (5)"
}

@test "001 --help lists every growth flag" {
	run "${CP}/001-setup-controlplane-test.sh" --help
	assert_success
	for f in --services-per-namespace --namespace-start --series --workload-mode --measurement-pods \
		--outside-namespaces --outside-mode --parts --probe --lifecycle-file wide; do
		assert_output --partial -- "$f"
	done
}

# ---------------------------------------------------------------------------
# 003 --dry-run: the growth plan; refusals; the matrix cap counts growth cells.
# ---------------------------------------------------------------------------

@test "003 --dry-run growth plan: ascending steps, cells, outside, M-sweep, deletion estimate" {
	KUBECONFIG=/dev/null run "${CP}/003-run-sweep.sh" --dry-run --contexts mesh-a --mesh-sizes 1 \
		--services-per-namespaces 2 --namespace-counts 50,25 --sidecar-scopings none,namespace,wide \
		--workload-mode config-only --measurement-pod-counts 4,16 --outside-namespaces 200 --outside-modes unlabeled,labeled
	assert_success
	assert_output --partial "note: growth series run --namespace-counts ascending without repeats: 25,50"
	assert_output --partial "Planned matrix:    19 cells = 1 mesh × 1 K × (2 steps × (1 grow + 3 probes) + 2 outside × (1 + 3) + 1 M-sweep × 3)"
	assert_output --partial "step N=25: +25 namespaces, +50 Services, +25 Sidecars; cells: grow (namespace), probe none namespace wide"
	assert_output --partial "step N=50: +25 namespaces, +50 Services"
	assert_output --partial "outside at N=50: 200 namespaces outside the mesh (+400 Services), phases unlabeled labeled"
	assert_output --partial "M-sweep at N=50: measurement pods 16"
	assert_output --partial "peak on the measured member(s): 251 namespaces, 502 Services, up to 51 Sidecars, 16 measurement pod(s)"
	assert_output --partial "namespaces left to delete afterwards: ~250"
	assert_output --partial "Memory guard:      stop at 70% of the istiod / gateway memory limit"
	refute_output --partial "Combinations (dry-run)"
}

@test "003 --dry-run growth fresh and the singular-flag aliases (PL7)" {
	KUBECONFIG=/dev/null run "${CP}/003-run-sweep.sh" --dry-run --contexts mesh-a --mesh-sizes 1 \
		--services-per-namespace 2 --namespace-counts 30 --sidecar-scopings namespace --growth fresh \
		--workload-mode pods --replica-counts 1 --measurement-pods 4 --outside-mode none
	assert_success
	assert_output --partial "note: --services-per-namespace is an alias; the sweep flag is --services-per-namespaces CSV"
	assert_output --partial "note: --measurement-pods is an alias"
	assert_output --partial "note: --outside-mode is an alias"
	assert_output --partial "N=30: one deploy cell per scoping (namespace): 30 namespaces, 60 Services each"
	assert_output --partial "Planned matrix:    1 cells"
}

@test "003 growth refusals: --service-counts, explicit, vsdr, --resume, descending M, mixed K, repeated K or mesh size" {
	s=(--dry-run --contexts a --mesh-sizes 1)
	KUBECONFIG=/dev/null run "${CP}/003-run-sweep.sh" "${s[@]}" --services-per-namespaces 2 --service-counts 10
	assert_failure
	assert_output --partial "--service-counts conflicts with --services-per-namespaces"
	KUBECONFIG=/dev/null run "${CP}/003-run-sweep.sh" "${s[@]}" --services-per-namespaces 2 --sidecar-scopings explicit
	assert_failure
	assert_output --partial "do not support --sidecar-scopings explicit"
	KUBECONFIG=/dev/null run "${CP}/003-run-sweep.sh" "${s[@]}" --services-per-namespaces 2 --traffic-configs vsdr --replica-counts 2
	assert_failure
	assert_output --partial "do not support --traffic-configs vsdr"
	KUBECONFIG=/dev/null run "${CP}/003-run-sweep.sh" --resume "${BATS_TEST_TMPDIR}" --contexts a --mesh-sizes 1 --services-per-namespaces 2
	assert_failure
	assert_output --partial "--resume is not supported for growth series"
	KUBECONFIG=/dev/null run "${CP}/003-run-sweep.sh" "${s[@]}" --services-per-namespaces 2 --workload-mode config-only --measurement-pod-counts 16,4
	assert_failure
	assert_output --partial "must be strictly ascending"
	KUBECONFIG=/dev/null run "${CP}/003-run-sweep.sh" "${s[@]}" --services-per-namespaces 2,0
	assert_failure
	assert_output --partial "mixes 0 (the legacy sweep) with growth series"
	KUBECONFIG=/dev/null run "${CP}/003-run-sweep.sh" "${s[@]}" --services-per-namespaces 2 --mem-stop-pct 101
	assert_failure
	# A series is RUN_ID x mesh size x K in the report: a repeated K or mesh size is refused.
	KUBECONFIG=/dev/null run "${CP}/003-run-sweep.sh" "${s[@]}" --services-per-namespaces 2,2
	assert_failure
	assert_output --partial "--services-per-namespaces repeats a value (2,2): each K is one growth series"
	KUBECONFIG=/dev/null run "${CP}/003-run-sweep.sh" --dry-run --contexts a --mesh-sizes 1,1 --services-per-namespaces 2
	assert_failure
	assert_output --partial "--mesh-sizes repeats a value (1,1)"
}

@test "003 growth: the matrix cap counts growth cells (PL10)" {
	KUBECONFIG=/dev/null run "${CP}/003-run-sweep.sh" --dry-run --contexts a --mesh-sizes 1 \
		--services-per-namespaces 1,2,4 --namespace-counts 100,200,400,800 --sidecar-scopings none,namespace,wide \
		--workload-mode config-only --outside-namespaces 10 --outside-modes unlabeled,labeled
	assert_failure
	assert_output --partial "growth plan has 72 cells = 1 mesh × 3 K × (4 steps × (1 grow + 3 probes) + 2 outside × (1 + 3) + 0 M-sweep × 3), above the safety limit 64"
}

@test "003 --help lists every growth flag" {
	run "${CP}/003-run-sweep.sh" --help
	assert_success
	for f in --services-per-namespaces --growth --workload-mode --measurement-pod-counts --outside-namespaces \
		--outside-modes --probe-settle --mem-stop-pct --mem-guard-contexts --series-retire; do
		assert_output --partial -- "$f"
	done
}

# ---------------------------------------------------------------------------
# 005 --dry-run: undiscover, no-delete, no-wait, probe teardown.
# ---------------------------------------------------------------------------

@test "005 --dry-run --series --undiscover --no-delete: labels removed, no namespace delete queued" {
	KUBECONFIG=/dev/null run "${CP}/005-cleanup.sh" --dry-run --contexts ci-dummy --series s1 --undiscover --no-delete
	assert_success
	assert_output --partial "delete deployments -A -l app.kubernetes.io/instance=controlplane-test,controlplane-test.series=s1 --wait=false"
	assert_output --partial "delete pods -A -l app.kubernetes.io/instance=controlplane-test,controlplane-test.series=s1 --grace-period=5 --wait=false"
	assert_output --partial "delete sidecars.networking.istio.io -A -l app.kubernetes.io/instance=controlplane-test,controlplane-test.series=s1 --wait=false"
	assert_output --partial "label namespace -l app.kubernetes.io/instance=controlplane-test,controlplane-test.series=s1 istio-discovery- istio.io/rev-"
	assert_output --partial "keep the namespaces (--no-delete)"
	refute_output --partial "delete namespace -l"
	refute_output --partial "delete namespace controlplane-test "
}

@test "005 --dry-run --undiscover --no-wait --timeout: undiscover, then queue the deletes" {
	KUBECONFIG=/dev/null run "${CP}/005-cleanup.sh" --dry-run --contexts ci-dummy --series s1 --undiscover --no-wait --timeout 900
	assert_success
	assert_output --partial "istio-discovery- istio.io/rev-"
	assert_output --partial "delete namespace -l app.kubernetes.io/instance=controlplane-test,controlplane-test.series=s1 --wait=false"
	assert_output --partial "do not wait for the namespaces to disappear (--no-wait)"
	assert_output --partial "Timeout:         900s"
}

@test "005 --dry-run --probe: delete its Services and Sidecar, drop the labels, then the namespace" {
	KUBECONFIG=/dev/null run "${CP}/005-cleanup.sh" --dry-run --contexts ci-dummy --probe controlplane-test-s1-p3
	assert_success
	assert_output --partial "-n controlplane-test-s1-p3 delete services,sidecars.networking.istio.io -l app.kubernetes.io/instance=controlplane-test --wait=true"
	assert_output --partial "label namespace controlplane-test-s1-p3 istio-discovery- istio.io/rev-"
	assert_output --partial "delete namespace controlplane-test-s1-p3 --ignore-not-found=true --wait=false"
}

@test "005: --no-delete needs --undiscover; --probe stands alone; the default still deletes the plain namespace" {
	KUBECONFIG=/dev/null run "${CP}/005-cleanup.sh" --dry-run --contexts ci-dummy --no-delete
	assert_failure
	assert_output --partial "--no-delete needs --undiscover"
	KUBECONFIG=/dev/null run "${CP}/005-cleanup.sh" --dry-run --contexts ci-dummy --probe p1 --series s1
	assert_failure
	KUBECONFIG=/dev/null run "${CP}/005-cleanup.sh" --dry-run --contexts ci-dummy
	assert_success
	assert_output --partial "delete namespace controlplane-test --ignore-not-found=true --wait=false"
	assert_output --partial "wait up to 300s for those namespaces to disappear"
}

# ---------------------------------------------------------------------------
# ROSA window fixes (BACKLOG 9.3-9.6, 9.10, 9.11)
# ---------------------------------------------------------------------------

@test "mem_guard_project_abs: (intercept + per-1000 x Services) x burst factor" {
	# 4000 Services on an east-west gateway: (10 + 145 x 4) x 2.0 = 1180 Mi, above 70% of 1Gi
	# (the X1 first step that the relative projection, ratio 1, let through).
	[ "$(mem_guard_project_abs 4000 145 10 2.0)" = 1180 ]
	[ "$(mem_guard_verdict 1180 1024 70)" = stop ]
	[ "$(mem_guard_project_abs 6000 91 10 1.2)" = 667 ]
	[ "$(mem_guard_project_abs N/A 145 10 2)" = unknown ]
	[ "$(mem_guard_project_abs 100 145 10 x)" = unknown ]
}

@test "growth_parse_envoy_stats: physical heap; growth_parse_top_containers: istio-proxy working set" {
	run growth_parse_envoy_stats <<<$'server.memory_allocated: 629145600\nserver.memory_physical_size: 1153433600\ncluster_manager.active_clusters: 8035'
	assert_output "mem_mi=600 clusters=8035 physical_mi=1100"
	run growth_parse_top_containers <<<$'gw-a   istio-proxy   12m   1075Mi\ngw-a   other   1m   5Mi\ngw-b   istio-proxy   3m   1Gi\ngw-c   istio-proxy   1m   weird'
	assert_output $'gw-a\t1075\ngw-b\t1024'
	run growth_parse_gateway_pods <<<'{"items":[{"metadata":{"name":"ew-1","labels":{"istio":"eastwestgateway"}},"status":{"phase":"Running"},"spec":{"containers":[{"name":"istio-proxy","resources":{"limits":{"memory":"3Gi"}}}]}}]}'
	assert_output $'ew-1\t3072\teastwestgateway'
}

@test "growth_parse_remote_secrets / growth_mesh_members: members from the Istio remote secrets" {
	rs_json='{"items":[
		{"metadata":{"name":"istio-remote-secret-mesh-b","labels":{"istio/multiCluster":"true"},"annotations":{"networking.istio.io/cluster":"mesh-b"}}},
		{"metadata":{"name":"istio-remote-secret-mesh-c","labels":{"istio/multiCluster":"true"}}},
		{"metadata":{"name":"cacerts","labels":{}}}]}'
	run growth_parse_remote_secrets <<<"$rs_json"
	assert_output $'mesh-b\nmesh-c'
	kubectl_stub() { printf '%s\n' "$rs_json"; }
	run growth_mesh_members mesh-a kubectl_stub
	assert_output $'mesh-a\nmesh-b\nmesh-c'
	failing_stub() { return 1; }
	run growth_mesh_members mesh-a failing_stub
	assert_failure
}

@test "growth_test_ns_counts: every controlplane-test namespace and the discovered ones" {
	kubectl_stub() { echo '{"items":[{"metadata":{"labels":{"istio-discovery":"enabled"}}},{"metadata":{"labels":{}}},{"metadata":{}}]}'; }
	run growth_test_ns_counts mesh-a kubectl_stub
	assert_output "total=3 discovered=1"
	failing_stub() { return 1; }
	run growth_test_ns_counts mesh-a failing_stub
	assert_output "total=N/A discovered=N/A"
}

@test "growth_retire_verified: retries, then fails while a namespace of the series stays discovered" {
	export STATE="${BATS_TEST_TMPDIR}/retire"
	mkdir -p "$STATE"
	echo 0 >"${STATE}/calls"
	# kubectl stub: namespaces are discovered until the cleanup has run <fixed_after> times.
	kubectl_stub() {
		local fixed_after; fixed_after="$(cat "${STATE}/fixed_after")"
		(( $(cat "${STATE}/calls") >= fixed_after )) && return 0
		echo "namespace/cp-s1-0"
	}
	cleanup() { echo $(( $(cat "${STATE}/calls") + 1 )) >"${STATE}/calls"; return "${CLEANUP_RC:-0}"; }
	KC=(kubectl_stub)
	echo 2 >"${STATE}/fixed_after"
	run growth_retire_verified KC mesh-a,mesh-b "app.kubernetes.io/instance=controlplane-test,controlplane-test.series=s1" 3 0 -- cleanup
	assert_success
	assert_output --partial "attempt 1/3: mesh-a: 1 namespace(s) still discovered"
	[ "$(cat "${STATE}/calls")" -eq 2 ]
	echo 0 >"${STATE}/calls"; echo 9 >"${STATE}/fixed_after"
	run growth_retire_verified KC mesh-a "sel" 2 0 -- cleanup
	assert_failure
	assert_output --partial "error: series retire failed after 2 attempt(s): mesh-a: 1 namespace(s) still discovered, e.g. namespace/cp-s1-0"
	# A failing cleanup command fails the attempt even when nothing is listed.
	echo 0 >"${STATE}/calls"; echo 0 >"${STATE}/fixed_after"
	CLEANUP_RC=1 run growth_retire_verified KC mesh-a "sel" 1 0 -- cleanup
	assert_failure
	assert_output --partial "the cleanup command failed"
}

@test "003 live growth run against an empty kubeconfig: RETIRE_FAILED row, exit 1 (BACKLOG 9.3)" {
	command -v helm >/dev/null || skip "helm not installed"
	out="${BATS_TEST_TMPDIR}/res"
	CONTROLPLANE_RETIRE_ATTEMPTS=1 CONTROLPLANE_RETIRE_BACKOFF_S=0 METRICS_READY_TIMEOUT=0 KUBECONFIG=/dev/null \
		run timeout 300 "${CP}/003-run-sweep.sh" --contexts ci-a --mesh-sizes 1 --services-per-namespaces 1 \
		--namespace-counts 2 --sidecar-scopings namespace --workload-mode config-only --settle 0 --probe-settle 0 \
		--output-dir "$out"
	assert_failure 1
	assert_output --partial "ERROR: the sweep stopped early: series"
	tsv="$(find "$out" -name 'controlplane-*.tsv')"
	[ "$(awk -F'\t' '$2 == "RETIRE_FAILED" { print $57 }' "$tsv")" = retire ]
	# Every row has the schema's width.
	[ "$(awk -F'\t' '!/^#/ { print NF }' "$tsv" | sort -u)" = 66 ]
}

@test "003: --series-retire keep with more than one series, and --vsdr-apply checks" {
	KUBECONFIG=/dev/null run "${CP}/003-run-sweep.sh" --dry-run --contexts a --mesh-sizes 1 --services-per-namespaces 1,2 --series-retire keep
	assert_failure
	assert_output --partial "--series-retire keep leaves a series discovered"
	KUBECONFIG=/dev/null run "${CP}/003-run-sweep.sh" --dry-run --contexts a --mesh-sizes 1 --services-per-namespaces 1 --series-retire keep
	assert_success
	KUBECONFIG=/dev/null run "${CP}/003-run-sweep.sh" --dry-run --contexts a --mesh-sizes 1 --vsdr-apply sometimes
	assert_failure
	assert_output --partial "--vsdr-apply must be together or split"
	KUBECONFIG=/dev/null run "${CP}/003-run-sweep.sh" --dry-run --contexts a --mesh-sizes 1 --services-per-namespaces 1 --vsdr-apply split
	assert_failure
	assert_output --partial "--vsdr-apply split is for the legacy sweep"
	KUBECONFIG=/dev/null run "${CP}/003-run-sweep.sh" --dry-run --contexts a --mesh-sizes 1 --service-counts 4 --replica-counts 2 \
		--traffic-configs none,vsdr --vsdr-apply split
	assert_success
	assert_output --partial "apply split: workloads before the baseline"
	run "${CP}/003-run-sweep.sh" --help
	assert_output --partial "--vsdr-apply MODE"
	assert_output --partial "CONTROLPLANE_RETIRE_ATTEMPTS"
}

@test "001 capacity preflight: refuses pods whose CPU requests exceed what other pods leave free" {
	command -v helm >/dev/null || skip "helm not installed"
	local sd="${BATS_TEST_TMPDIR}/stub"
	mkdir -p "$sd"
	# One 2-core worker; running pods already request 1.5 cores and hold 3 of 250 slots.
	cat >"$sd/kubectl" <<'EOF'
#!/usr/bin/env bash
case " $* " in
*" get nodes -o json "*) echo '{"items":[{"metadata":{"name":"w-0","labels":{"node-role.kubernetes.io/worker":""}},"status":{"allocatable":{"cpu":"2","memory":"8Gi","pods":"250"}}}]}' ;;
*" get pods --all-namespaces -o name "*) printf 'pod/a\npod/b\npod/c\n' ;;
*" get pods -A -o json "*) echo '{"items":[{"spec":{"nodeName":"w-0","containers":[{"resources":{"requests":{"cpu":"1500m"}}}]},"status":{"phase":"Running"}}]}' ;;
*" get istios.sailoperator.io "*) echo '{"items":[]}' ;;
*) exit 1 ;;
esac
EOF
	chmod +x "$sd/kubectl"
	a=(--contexts ci-a --service-count 10 --replicas 2)
	PATH="$sd:$PATH" KUBECONFIG=/dev/null run "${CP}/001-setup-controlplane-test.sh" "${a[@]}"
	assert_failure
	assert_output --partial "ci-a: 247 pod slots available (20 needed) — OK"
	assert_output --partial "context ci-a: ~0.5 cores of CPU requests free on the workers (2.0 allocatable − 1.5 requested), ~2.0 needed (20 pods × 100m, istio default (no live read)); about 5 pods fit."
	# Warn-only mode (a node autoscaler) lets the setup go on to the apply.
	PATH="$sd:$PATH" KUBECONFIG=/dev/null SCALE_CPU_PREFLIGHT_ENFORCE=0 run "${CP}/001-setup-controlplane-test.sh" "${a[@]}"
	assert_output --partial "WARN: ci-a: ~0.5 cores of CPU requests free"
	refute_output --partial "about 5 pods fit. Reduce"
	# 5 pods fit: OK.
	PATH="$sd:$PATH" KUBECONFIG=/dev/null run "${CP}/001-setup-controlplane-test.sh" --contexts ci-a --service-count 5 --replicas 1
	assert_output --partial "ci-a: ~0.5 cores of CPU requests free on the workers (2.0 allocatable − 1.5 requested), ~0.5 needed (5 pods × 100m, istio default (no live read)) — OK"
}

@test "001 --dry-run --parts workloads / traffic: the two halves of a vsdr apply (BACKLOG 9.11)" {
	command -v helm >/dev/null || skip "helm not installed"
	a=(--dry-run --contexts ci-dummy --service-count 4 --replicas 2 --traffic-config vsdr)
	KUBECONFIG=/dev/null run "${CP}/001-setup-controlplane-test.sh" "${a[@]}" --parts workloads
	assert_success
	assert_output --partial "render: 8 Deployment, 1 Namespace, 4 Service ("
	refute_output --partial "VirtualService"
	KUBECONFIG=/dev/null run "${CP}/001-setup-controlplane-test.sh" "${a[@]}" --parts traffic
	assert_success
	assert_output --partial "render: 4 DestinationRule, 4 VirtualService (0 namespace batch(es)"
	KUBECONFIG=/dev/null run "${CP}/001-setup-controlplane-test.sh" --dry-run --contexts ci-dummy --service-count 4 --replicas 2 --parts traffic
	assert_failure
	assert_output --partial "--parts traffic applies the VirtualServices and DestinationRules, so it needs --traffic-config vsdr"
	KUBECONFIG=/dev/null run "${CP}/001-setup-controlplane-test.sh" --dry-run --contexts ci-dummy --services-per-namespace 2 --namespace-count 5 --parts workloads
	assert_failure
	assert_output --partial "--parts workloads is for the legacy layout"
}
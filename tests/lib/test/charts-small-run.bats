#!/usr/bin/env bats
# The charts a small run can draw (2 members, one mesh size with remote data, namespace
# scaling at one mesh size), from the redacted results of the 2026-10-27 lab run
# committed under docs/campaigns: churn by churn intensity, propagation's P1 over mesh
# size and its phases at the remote mesh size, controlplane's namespace-scaling charts.

bats_require_minimum_version 1.5.0
load test_helper

REC="${ROOT}/docs/campaigns/2026-10-27-openshift-homelab/results"

@test "churn charts: with one mesh size that has remote data, convergence by churn intensity at that mesh size" {
	run --separate-stderr "${ROOT}/tests/churn/004-report-results.sh" --results-dir "${REC}/churn" --format charts
	assert_success
	assert_output --partial 'title "Convergence Latency vs Churn Intensity (Mesh Size 2)"'
	assert_output --partial 'x-axis "Churn intensity (deployments)" [2, 5]'
	assert_output --partial '    line [5600, 6566]'
	assert_output --partial 'Series order: **local avg**, **remote reach avg**, **remote EDS avg**'
	refute_output --partial 'Convergence Latency vs Mesh Size'
}

@test "propagation charts: P1 over every mesh size and the three phases at the one remote mesh size" {
	run --separate-stderr "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "${REC}/propagation" --format charts
	assert_success
	assert_output --partial 'title "P1 Local xDS Latency vs Mesh Size"'
	assert_output --partial $'x-axis "Mesh Size" [1, 2]\n    y-axis "Latency (ms)"\n    line [737, 1173]'
	assert_output --partial 'title "Propagation Phases at Mesh Size 2"'
	assert_output --partial '    bar [1173, 1172, 1864]'
}

@test "controlplane charts: namespace scaling from the probe-window fits, a line per scoping, one line for the gateway" {
	run --separate-stderr "${ROOT}/tests/controlplane/004-report-results.sh" --results-dir "${REC}/controlplane" --format charts
	assert_success
	assert_output --partial '## Namespace scaling'
	assert_output --partial $'title "istiod heap in use (MiB) vs namespaces (mesh=1 K=2 config-only)"\n    x-axis "Namespaces (N)" [100, 200, 400]'
	assert_output --partial $'    line [102, 141, 169]\n    line [107, 122, 140]\n    line [129, 153, 181]'
	assert_output --partial 'Series order: **namespace**, **none**, **wide**.'
	assert_output --partial $'y-axis "Gateway clusters"\n    line [431, 831, 1631]\n```'
	refute_output --partial 'legacy layout only'
}

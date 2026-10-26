#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/preamble.sh"

@test "infra_preamble_lines: the seven infra keys always, an omitted one as unknown; an unrecognized key is dropped, NODE_ALLOC_* too (the capacity block holds them)" {
	run infra_preamble_lines
	assert_success
	[ "$(printf '%s\n' "$output" | grep -c '^# [A-Z_]*=unknown$')" -eq 7 ]
	assert_line "# ISTIOD_REPLICAS_BY_CONTEXT=unknown"
	run infra_preamble_lines ISTIOD_REPLICAS=5 ISTIOD_LIM_MEM_MI=8192 BOGUS_KEY=123 NODE_ALLOC_CPU_M=16000 \
		NETWORK_TOPOLOGY=multi-primary,multi-network:5
	assert_success
	assert_line "# ISTIOD_REPLICAS=5"
	assert_line "# ISTIOD_LIM_MEM_MI=8192"
	assert_line "# NETWORK_TOPOLOGY=multi-primary,multi-network:5"
	assert_line "# ISTIOD_REQ_CPU_M=unknown"
	assert_line "# ISTIOD_LIM_CPU_M=unknown"
	refute_output --partial BOGUS_KEY
	refute_output --partial NODE_ALLOC
}

# The controlplane TSV header is a literal in 002 (the standalone writer) and 003 (the
# pre-create, whose file 002 then appends its rows to): a column one adds and the other does
# not shifts every later column's label.
@test "controlplane header: the 002 and 003 literals match, 66 fields, and both writers stamp CONTROLPLANE_SCHEMA=66" {
	collector="${ROOT}/tests/controlplane/002-collect-resource-metrics.sh"
	precreate="${ROOT}/tests/controlplane/003-run-sweep.sh"
	h002=$(grep -m1 'echo -e "timestamp\\t' "$collector" | sed 's/.*echo -e "//; s/" >>.*//')
	h003=$(grep -m1 '^CONTROLPLANE_TSV_HEADER="' "$precreate" | sed 's/^CONTROLPLANE_TSV_HEADER="//; s/"$//')
	[ -n "$h002" ]
	[ "$h002" = "$h003" ]
	n=$(printf '%s' "$h003" | awk -F'\\\\t' '{ print NF }')
	[ "$n" -eq 66 ]
	grep -q 'echo "# CONTROLPLANE_SCHEMA=66"' "$collector"
	grep -q 'echo "# CONTROLPLANE_SCHEMA=66"' "$precreate"
}

# _fake_kubectl: prints a version JSON that echoes the --context value; context bad fails.
_fake_kubectl() {
	local ctx="" a
	for a in "$@"; do [[ "$a" == --context=* ]] && ctx="${a#--context=}"; done
	[[ "$ctx" != bad ]] || return 1
	printf '{"serverVersion":{"gitVersion":"v1.34.0-%s"}}\n' "${ctx//\//_}"
}

@test "probe_kube_versions: each context's server version in the given order, a context with a '/' too; one that does not answer is unreachable" {
	run probe_kube_versions "plain,bad,default/api-x:6443/admin" _fake_kubectl
	assert_success
	assert_output "plain=v1.34.0-plain,bad=unreachable,default/api-x:6443/admin=v1.34.0-default_api-x:6443_admin"
}

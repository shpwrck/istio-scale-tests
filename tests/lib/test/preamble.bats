#!/usr/bin/env bats

load test_helper
source "${ROOT}/tests/lib/preamble.sh"

# ---------------------------------------------------------------------------
# infra_preamble_lines — the ONE shared cluster-infra emitter (PL36). Every
# expected key is ALWAYS emitted (defaulting to `unknown`), and caller-supplied
# values overlay. This is what guarantees the 003 pre-creator and the 002
# `! -f`-guarded collector write the identical infra key set.
# ---------------------------------------------------------------------------

@test "infra_preamble_lines: emits all keys, defaulting omitted ones to unknown" {
	run infra_preamble_lines ISTIOD_REPLICAS=5 ISTIOD_LIM_MEM_MI=8192
	[ "$status" -eq 0 ]
	[[ "$output" == *"# ISTIOD_REPLICAS=5"* ]]
	[[ "$output" == *"# ISTIOD_LIM_MEM_MI=8192"* ]]
	# Omitted keys still present as unknown (PL36: missing-but-expected, not absent).
	[[ "$output" == *"# ISTIOD_REQ_CPU_M=unknown"* ]]
	[[ "$output" == *"# ISTIOD_LIM_CPU_M=unknown"* ]]
	[[ "$output" == *"# NETWORK_TOPOLOGY=unknown"* ]]
}

@test "infra_preamble_lines: no args -> all seven keys emitted as unknown" {
	run infra_preamble_lines
	[ "$status" -eq 0 ]
	# Exactly the canonical key set, all unknown. F4: NODE_ALLOC_* dropped (single-source
	# in the O9 capacity block); ISTIOD_REPLICAS_BY_CONTEXT added with INFRA_SCHEMA 2.
	n=$(printf '%s\n' "$output" | grep -c '^# [A-Z_]*=unknown$')
	[ "$n" -eq 7 ]
	[[ "$output" == *"# ISTIOD_REPLICAS_BY_CONTEXT=unknown"* ]]
}

@test "infra_preamble_lines: F4 — NODE_ALLOC_* are NOT emitted (single-source)" {
	run infra_preamble_lines ISTIOD_REPLICAS=5
	[ "$status" -eq 0 ]
	[[ "$output" != *"NODE_ALLOC_CPU_M"* ]]
	[[ "$output" != *"NODE_ALLOC_MEM_MI"* ]]
}

@test "infra_preamble_lines: unrecognized key is ignored (not echoed verbatim)" {
	# NODE_ALLOC_CPU_M is now unrecognized by the infra emitter (F4), so it too is dropped.
	run infra_preamble_lines BOGUS_KEY=123 NODE_ALLOC_CPU_M=16000 NETWORK_TOPOLOGY=multi-primary,multi-network:5
	[ "$status" -eq 0 ]
	[[ "$output" != *"BOGUS_KEY"* ]]
	[[ "$output" != *"NODE_ALLOC_CPU_M"* ]]
	[[ "$output" == *"# NETWORK_TOPOLOGY=multi-primary,multi-network:5"* ]]
}

# ---------------------------------------------------------------------------
# PL36 two-writer key-set symmetry. The 003 pre-creator and the 002 collector
# both build the controlplane TSV preamble; if one writes a `# KEY=` line the
# other omits, the `! -f` guard silently drops it downstream. Both now route the
# infra block through infra_preamble_lines, so the infra key set is identical by
# construction — but assert the FULL `# KEY=value` literal sets agree too, so a
# future hand-added line to one writer can't drift unnoticed.
# ---------------------------------------------------------------------------

@test "PL36: 002 and 003 emit the same controlplane preamble key set" {
	collector="${ROOT}/tests/controlplane/002-collect-resource-metrics.sh"
	precreate="${ROOT}/tests/controlplane/003-run-sweep.sh"
	# Pull the literal `echo "# KEY=..."` keys each writer emits inline.
	keys_002=$(grep -oE 'echo "# [A-Z_]+=' "$collector" | sed -E 's/echo "# ([A-Z_]+)=/\1/' | sort -u)
	keys_003=$(grep -oE 'echo "# [A-Z_]+=' "$precreate" | sed -E 's/echo "# ([A-Z_]+)=/\1/' | sort -u)
	# Both call infra_preamble_lines for the infra block, so the infra keys are not
	# inline echoes in either — symmetry there is guaranteed by the shared emitter.
	# Here we assert the INLINE-echoed key sets match modulo the known, intentional
	# 003-only provenance keys (METRICS_API, NOTE) and the shared-title comment.
	only_003=$(comm -13 <(printf '%s\n' "$keys_002") <(printf '%s\n' "$keys_003"))
	only_002=$(comm -23 <(printf '%s\n' "$keys_002") <(printf '%s\n' "$keys_003"))
	# 002 must not emit any key 003 lacks (that would vanish in an orchestrated run).
	[ -z "$only_002" ]
	# 003-only keys must be exactly the documented orchestrator-provenance extras.
	for k in $only_003; do
		case "$k" in
			METRICS_API|NOTE) : ;;
			*) echo "unexpected 003-only key: $k"; false ;;
		esac
	done
}

@test "PL36: both controlplane writers route the infra block through infra_preamble_lines" {
	grep -q 'infra_preamble_lines' "${ROOT}/tests/controlplane/002-collect-resource-metrics.sh"
	grep -q 'infra_preamble_lines' "${ROOT}/tests/controlplane/003-run-sweep.sh"
}

@test "PL36: both controlplane writers emit RUN_CONFIG* through config_preamble_lines; 004 reads them" {
	# Inside the preamble block: after the VSDR_SUBSETS echo, before the header row.
	for f in 002-collect-resource-metrics.sh 003-run-sweep.sh; do
		awk '/echo "# VSDR_SUBSETS=/ { on = 1 } on && /^[[:space:]]*config_preamble_lines$/ { found = 1 }
			/^[[:space:]]*\} > "\$(TSV_FILE|tsv)"/ { on = 0 } END { exit !found }' \
			"${ROOT}/tests/controlplane/$f" || { echo "$f: no config_preamble_lines in the preamble block"; false; }
	done
	grep -q 'preamble_scalar RUN_CONFIG ' "${ROOT}/tests/controlplane/004-report-results.sh"
	grep -q 'preamble_scalar RUN_CONFIG_SHA256 ' "${ROOT}/tests/controlplane/004-report-results.sh"
}

@test "C2: both controlplane writers emit CONTROLPLANE_INFRA_SCHEMA (read by 004's concordance guard)" {
	grep -q 'echo "# CONTROLPLANE_INFRA_SCHEMA=' "${ROOT}/tests/controlplane/002-collect-resource-metrics.sh"
	grep -q 'echo "# CONTROLPLANE_INFRA_SCHEMA=' "${ROOT}/tests/controlplane/003-run-sweep.sh"
	# And the report reads it (the mixed-version concordance warning).
	grep -q 'CONTROLPLANE_INFRA_SCHEMA' "${ROOT}/tests/controlplane/004-report-results.sh"
}

# ---------------------------------------------------------------------------
# Controlplane TSV header: the literal is duplicated in 002 (standalone writer) and
# 003 (pre-create). Both must be identical, have the schema's width, and both writers
# must stamp the same CONTROLPLANE_SCHEMA. Extend the expected tail when appending.
# ---------------------------------------------------------------------------

@test "controlplane header: 002 and 003 literals match, 51 fields, schema 51" {
	collector="${ROOT}/tests/controlplane/002-collect-resource-metrics.sh"
	precreate="${ROOT}/tests/controlplane/003-run-sweep.sh"
	h002=$(grep -m1 'echo -e "timestamp\\t' "$collector" | sed 's/.*echo -e "//; s/" >>.*//')
	h003=$(grep -m1 '^CONTROLPLANE_TSV_HEADER="' "$precreate" | sed 's/^CONTROLPLANE_TSV_HEADER="//; s/"$//')
	[ -n "$h002" ]
	[ "$h002" = "$h003" ]
	n=$(printf '%s' "$h003" | awk -F'\\\\t' '{ print NF }')
	[ "$n" -eq 51 ]
	[[ "$h003" == *'\tpods_allocatable\tcluster_connected_proxies\tsidecar_pods\tproxy_check\ttraffic_config\tvsdr_services\tistiod_virt_services\tpush_time_avg_ms\tpushcontext_init_avg_ms\tsidecar_clusters_avg\tsidecar_cds_bytes_avg\tsidecar_rds_bytes_avg' ]]
	grep -q 'echo "# CONTROLPLANE_SCHEMA=51"' "$collector"
	grep -q 'echo "# CONTROLPLANE_SCHEMA=51"' "$precreate"
	# The proxy-check and traffic-management knobs are inline echoes in both writers
	# (the PL36 key-set test above then covers their parity).
	for k in PROXY_CHECK_TOLERANCE_PCT PROXY_CHECK_MIN_DIFF TRAFFIC_CONFIG VSDR_EVERY VSDR_SUBSETS; do
		grep -q "echo \"# ${k}=" "$collector"
		grep -q "echo \"# ${k}=" "$precreate"
	done
}

# ---------------------------------------------------------------------------
# 003 --resume: the sweep-level scalars recorded only in the preamble (VSDR_EVERY,
# VSDR_SUBSETS, PROXY_CHECK_*) must be the same for every row of the resumed TSV.
# Each case stops before any cluster contact (a die, or the matrix-size guard).
# ---------------------------------------------------------------------------

_resume_dir() {
	local subsets="$1" d="${BATS_TEST_TMPDIR}/sweep-fixture-t6"
	mkdir -p "$d"
	sed "s/^# VSDR_SUBSETS=.*/# VSDR_SUBSETS=${subsets}/" \
		"${ROOT}/tests/lib/test/fixtures/controlplane_vsdr.tsv" > "${d}/controlplane-fixture-t6.tsv"
	printf '%s' "$d"
}

@test "003 --resume: refuses an explicit --vsdr-subsets that differs from the preamble" {
	d="$(_resume_dir 2)"
	KUBECONFIG=/dev/null run "${ROOT}/tests/controlplane/003-run-sweep.sh" --resume "$d" \
		--contexts a,b --mesh-sizes 1 --replica-counts 3 --traffic-configs none,vsdr --vsdr-subsets 3
	assert_failure 1
	assert_output --partial "--vsdr-subsets 3 differs from VSDR_SUBSETS=2"
}

@test "003 --resume: adopts the recorded --vsdr-subsets, then validates it against replicas" {
	d="$(_resume_dir 3)"
	KUBECONFIG=/dev/null run "${ROOT}/tests/controlplane/003-run-sweep.sh" --resume "$d" \
		--contexts a,b --mesh-sizes 1 --replica-counts 2 --traffic-configs none,vsdr
	assert_failure 1
	assert_output --partial "using VSDR_SUBSETS=3 from the resumed sweep's preamble (this run had 2)"
	assert_output --partial "--vsdr-subsets 3 > replica-count 2"
}

@test "003 --resume: adopts PROXY_CHECK_*; leaves the VS/DR pair alone without vsdr cells" {
	d="$(_resume_dir 3)"
	CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT=25 CONTROLPLANE_MAX_MATRIX=1 KUBECONFIG=/dev/null \
		run "${ROOT}/tests/controlplane/003-run-sweep.sh" --resume "$d" \
		--contexts a,b --mesh-sizes 1,2 --replica-counts 2 --traffic-configs none
	assert_failure 1
	assert_output --partial "using PROXY_CHECK_TOLERANCE_PCT=10 from the resumed sweep's preamble (this run had 25)"
	refute_output --partial "VSDR_SUBSETS"
	# Stopped by the matrix guard, i.e. after the resume checks and before any cluster call.
	assert_output --partial "exceeds safety limit 1"
}

# ---------------------------------------------------------------------------
# PL36 for churn-dataplane: three writers build the same TSV preamble (004's
# pre-create, then 002 and 003 when they bootstrap the file). Each key one writer
# adds and another omits is lost whenever the other writer created the file.
# ---------------------------------------------------------------------------

# _cd_preamble_keys <script>: the KEY= args of its write_preamble call.
_cd_preamble_keys() {
	awk '/write_preamble "churn-dataplane/ { on = 1; next } on && /printf .run_id/ { exit } on' "$1" \
		| grep -oE '"[A-Z][A-Z0-9_]*=' | tr -d '"=' | sort -u
}

@test "PL36: churn-dataplane 002, 003 and 004 write the same preamble key set" {
	d="${ROOT}/tests/churn-dataplane"
	k2="$(_cd_preamble_keys "$d/002-run-baseline-probe.sh")"
	k3="$(_cd_preamble_keys "$d/003-run-churn-probe.sh")"
	k4="$(_cd_preamble_keys "$d/004-run-sweep.sh")"
	[ -n "$k2" ]
	[ "$k2" = "$k3" ]
	# 004 writes every 002 key, plus only the documented sweep-level extras.
	[ -z "$(comm -23 <(printf '%s\n' "$k2") <(printf '%s\n' "$k4"))" ]
	for k in $(comm -13 <(printf '%s\n' "$k2") <(printf '%s\n' "$k4")); do
		case "$k" in
			MATRIX_SIZE|REPETITIONS|SETUP_NS_WAIT_SEC|CLEANUP_GRACE_SEC|NS_DELETE_TIMEOUT_SEC) : ;;
			*) echo "unexpected 004-only key: $k"; false ;;
		esac
	done
	for k in MIN_PCT_200 REACH_REQUESTS REACH_QPS REACH_HTTP_TIMEOUT_SEC REACH_DETAIL_TIMEOUT_SEC REACH_ATTEMPTS \
		REACH_RETRY_SEC ON_UNREACHABLE; do
		grep -qx "$k" <<<"$k2"
	done
}

# ---------------------------------------------------------------------------
# probe_kube_versions — concurrent per-context server version probe.
# ---------------------------------------------------------------------------

# Fake kubectl: prints a version JSON that echoes the --context value.
_fake_kubectl() {
	local ctx=""
	for a in "$@"; do [[ "$a" == --context=* ]] && ctx="${a#--context=}"; done
	printf '{"serverVersion":{"gitVersion":"v1.34.0-%s"}}\n' "${ctx//\//_}"
}

@test "probe_kube_versions: keeps input order and handles contexts containing '/'" {
	run probe_kube_versions "plain,default/api-x:6443/admin" _fake_kubectl
	assert_success
	assert_output "plain=v1.34.0-plain,default/api-x:6443/admin=v1.34.0-default_api-x:6443_admin"
}

@test "probe_kube_versions: unreachable context reports 'unreachable'" {
	_fail_kubectl() { return 1; }
	run probe_kube_versions "a,b" _fail_kubectl
	assert_success
	assert_output "a=unreachable,b=unreachable"
}

# ---------------------------------------------------------------------------
# harness_sha — describes the harness repo at $ROOT, not the caller's cwd.
# ---------------------------------------------------------------------------

@test "harness_sha: describes \$ROOT even when called from another directory" {
	expected="$(git -C "$ROOT" describe --always --dirty --abbrev=7)"
	cd "$BATS_TEST_TMPDIR"
	run harness_sha
	[ "$status" -eq 0 ]
	[ "$output" = "$expected" ]
}

@test "harness_sha: non-repo ROOT -> unknown" {
	ROOT="$BATS_TEST_TMPDIR" run harness_sha
	[ "$status" -eq 0 ]
	[ "$output" = "unknown" ]
}

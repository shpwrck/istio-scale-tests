#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
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

@test "controlplane header: 002 and 003 literals match, 66 fields, schema 66" {
	collector="${ROOT}/tests/controlplane/002-collect-resource-metrics.sh"
	precreate="${ROOT}/tests/controlplane/003-run-sweep.sh"
	h002=$(grep -m1 'echo -e "timestamp\\t' "$collector" | sed 's/.*echo -e "//; s/" >>.*//')
	h003=$(grep -m1 '^CONTROLPLANE_TSV_HEADER="' "$precreate" | sed 's/^CONTROLPLANE_TSV_HEADER="//; s/"$//')
	[ -n "$h002" ]
	[ "$h002" = "$h003" ]
	n=$(printf '%s' "$h003" | awk -F'\\\\t' '{ print NF }')
	[ "$n" -eq 66 ]
	[[ "$h003" == *'\tpods_allocatable\tcluster_connected_proxies\tsidecar_pods\tproxy_check\ttraffic_config\tvsdr_services\tistiod_virt_services\tpush_time_avg_ms\tpushcontext_init_avg_ms\tsidecar_clusters_avg\tsidecar_cds_bytes_avg\tsidecar_rds_bytes_avg\tservices_per_namespace\tworkload_mode\tmeasurement_pods\toutside_namespaces\toutside_discovery\twindow_kind\tistiod_services\tistiod_cpu_s_delta\tsidecar_mem_mi_avg\tgateway_clusters_max\tgateway_mem_mi_max\troot_cert_configmaps\tgateway_physical_mi_max\tgateway_ws_mi_max\tleftover_test_namespaces' ]]
	grep -q 'echo "# CONTROLPLANE_SCHEMA=66"' "$collector"
	grep -q 'echo "# CONTROLPLANE_SCHEMA=66"' "$precreate"
	# The namespace-scaling keys come from the one shared emitter in both writers (PL36).
	grep -q '^[[:space:]]*growth_preamble_lines ' "$collector"
	grep -q '^[[:space:]]*growth_preamble_lines ' "$precreate"
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

# _resume_dir <subsets>: the VS/DR fixture widened to this harness's 66 columns (the
# legacy-layout growth columns), so --resume accepts its width.
_resume_dir() {
	local subsets="$1" d="${BATS_TEST_TMPDIR}/sweep-fixture-t6"
	mkdir -p "$d"
	sed "s/^# VSDR_SUBSETS=.*/# VSDR_SUBSETS=${subsets}/" \
		"${ROOT}/tests/lib/test/fixtures/controlplane_vsdr.tsv" \
		| awk 'BEGIN { FS = OFS = "\t" }
			/^#/ { print; next }
			$1 == "timestamp" { print $0, "services_per_namespace", "workload_mode", "measurement_pods", "outside_namespaces", "outside_discovery", "window_kind", "istiod_services", "istiod_cpu_s_delta", "sidecar_mem_mi_avg", "gateway_clusters_max", "gateway_mem_mi_max", "root_cert_configmaps", "gateway_physical_mi_max", "gateway_ws_mi_max", "leftover_test_namespaces"; next }
			{ print $0, 0, "pods", $4 * $5, 0, "none", "deploy", "N/A", "N/A", "N/A", "N/A", "N/A", "N/A", "N/A", "N/A", "N/A" }' \
		> "${d}/controlplane-fixture-t6.tsv"
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

# ---------------------------------------------------------------------------
# istio_version_resolve (R4): the results record the Istio version the mesh RUNS (the
# active IstioRevision's .spec.version), read once per run before any change; the
# config/versions.env pin is kept next to it.
# ---------------------------------------------------------------------------

# _iv_kubectl: a fake kubectl for the two reads of istio_live_version, per context <c>:
#   IV_<c>       the version IstioRevision <rev> answers (unset: both reads fail, with an
#                Unauthorized line on stderr)
#   IVREV_<c>    .status.activeRevisionName (default `default`; `none` leaves it out)
#   IVSTATE_<c>  .status.state (default Healthy); IVOGEN_<c> .status.observedGeneration
#                (default 3, the generation); IVINUSE_<c> .status.revisions.inUse (default 1)
#   IVRECON_<c>  the Reconciled condition's status (default True)
#   IVSTATESEQ_<c> "S1 S2 ...": the state of each successive Istio CR read (the last repeats)
#   IVFLAKY_<c>  1: the first Istio CR read fails, the next ones answer
# Its .spec.version is the alias v1.30-latest, which must never be recorded. Logs each call.
_iv_kubectl() {
	local ctx="" a v rev state ogen inuse flaky recon seq st n
	for a in "$@"; do [[ "$a" == --context=* ]] && ctx="${a#--context=}"; done
	echo "$*" >> "$IV_LOG"
	v="IV_${ctx}" rev="IVREV_${ctx}" state="IVSTATE_${ctx}" ogen="IVOGEN_${ctx}" inuse="IVINUSE_${ctx}" flaky="IVFLAKY_${ctx}"
	recon="IVRECON_${ctx}" seq="IVSTATESEQ_${ctx}"
	if [[ -z "${!v:-}" ]]; then
		echo "error: You must be logged in to the server (Unauthorized)" >&2
		return 1
	fi
	case " $* " in
	*" get istios.sailoperator.io default -o json "*)
		if [[ -n "${!flaky:-}" && ! -e "${BATS_TEST_TMPDIR}/flaked-${ctx}" ]]; then
			: > "${BATS_TEST_TMPDIR}/flaked-${ctx}"
			echo "Unable to connect to the server: net/http: TLS handshake timeout" >&2
			return 1
		fi
		st="${!state:-Healthy}"
		if [[ -n "${!seq:-}" ]]; then
			n="$(cat "${BATS_TEST_TMPDIR}/seq-${ctx}" 2>/dev/null || echo 0)"
			echo $((n + 1)) > "${BATS_TEST_TMPDIR}/seq-${ctx}"
			read -r -a a <<<"${!seq}"
			((n < ${#a[@]})) || n=$((${#a[@]} - 1))
			st="${a[n]}"
		fi
		jq -nc --arg rev "${!rev:-default}" --arg state "$st" --arg recon "${!recon:-True}" \
			--argjson ogen "${!ogen:-3}" --argjson inuse "${!inuse:-1}" \
			'{metadata: {name: "default", generation: 3}, spec: {version: "v1.30-latest"},
			  status: ({state: $state, observedGeneration: $ogen, revisions: {total: $inuse, ready: $inuse, inUse: $inuse},
			            conditions: [{type: "Reconciled", status: $recon}, {type: "Ready", status: (if $state == "Healthy" then "True" else "False" end)}]}
			  + (if $rev == "none" then {} else {activeRevisionName: $rev} end))}' ;;
	*" get istiorevisions.sailoperator.io ${!rev:-default} "*) printf '%s' "${!v}" ;;
	*)
		echo "Error from server (NotFound): not found" >&2
		return 1 ;;
	esac
}

# _iv_run <ctxs_csv> <dry 0|1> [--no-stop]: resolve in a subshell with pin ISTIO_VERSION
# (default v1.30.5), then print what it exported.
_iv_run() {
	(
		unset ISTIO_VERSION_SOURCE ISTIO_VERSION_PIN ISTIO_VERSION_BY_CONTEXT _ISTIO_VERSION_RESOLVED
		export ISTIO_VERSION="${PIN-v1.30.5}"
		if [[ "${3:-}" == --no-stop ]]; then
			istio_version_resolve --no-stop "$1" "$2" _iv_kubectl
		else
			istio_version_resolve "$1" "$2" _iv_kubectl
		fi
		echo "V=${ISTIO_VERSION} PIN=${ISTIO_VERSION_PIN} SRC=${ISTIO_VERSION_SOURCE} BY=${ISTIO_VERSION_BY_CONTEXT}"
	)
}

setup() {
	export IV_LOG="${BATS_TEST_TMPDIR}/iv.log"
	: > "$IV_LOG"
	unset ISTIO_VERSION_CHECK
}

@test "istio_live_version: InPlace and RevisionBased read the active IstioRevision, never the CR's alias" {
	IV_a=v1.30.5 run istio_live_version a _iv_kubectl
	assert_success
	assert_output "$(printf 'v1.30.5\nok\n\ndefault')"
	# Two bounded reads: the Istio CR, then the revision it names.
	run cat "$IV_LOG"
	assert_line "--context=a --request-timeout=5s get istios.sailoperator.io default -o json"
	assert_line "--context=a --request-timeout=5s get istiorevisions.sailoperator.io default -o jsonpath={.spec.version}"
	: > "$IV_LOG"
	IV_a=1.30.5 IVREV_a=default-v1-30-5 run istio_live_version a _iv_kubectl
	assert_output "$(printf '1.30.5\nok\n\ndefault-v1-30-5')"
	run grep -c 'get istiorevisions.sailoperator.io default-v1-30-5 ' "$IV_LOG"
	assert_output 1
	# The revision answers an alias (or anything but N.N.N): unknown, never the alias.
	IV_a=v1.30-latest run istio_live_version a _iv_kubectl
	assert_output "$(printf 'unknown\nvalue\nIstioRevision default .spec.version is v1.30-latest, not an exact version\ndefault')"
}

@test "istio_live_version: an Istio CR that is not settled reads unknown, with what is off" {
	IV_a=v1.30.5 IVSTATE_a=ReconcileError IVRECON_a=False run istio_live_version a _iv_kubectl
	assert_output "$(printf 'unknown\nstate\nthe Istio CR default is not settled: its state is ReconcileError, not Healthy, and its Reconciled condition is False\ndefault')"
	IV_a=v1.30.5 IVOGEN_a=2 run istio_live_version a _iv_kubectl
	assert_output "$(printf 'unknown\nstate\nthe Istio CR default is not settled: generation 3 is not reconciled yet (observedGeneration 2)\ndefault')"
	IV_a=v1.30.5 IVINUSE_a=2 IVSTATE_a=IstiodNotReady run istio_live_version a _iv_kubectl
	assert_output "$(printf 'unknown\nmigrating\nthe Istio CR default is not settled: its state is IstiodNotReady, not Healthy; 2 revisions are in use (a revision migration in progress)\ndefault')"
	IV_a=v1.30.5 IVREV_a=none run istio_live_version a _iv_kubectl
	assert_output "$(printf 'unknown\nstate\nthe Istio CR default is not settled: it names no activeRevisionName')"
	# None of these reads a revision.
	run grep -c istiorevisions "$IV_LOG"
	assert_output 0
	# A failed read keeps the first line of kubectl's stderr.
	run istio_live_version a _iv_kubectl
	assert_output "$(printf 'unknown\nread\nerror: You must be logged in to the server (Unauthorized)')"
}

@test "istio_live_version: readiness alone off (I1) still reads the version, as notready with the state" {
	# Reconciled True, generation reconciled, one revision in use: only istiod or CNI readiness.
	IV_a=v1.30.5 IVSTATE_a=IstioCNINotHealthy run istio_live_version a _iv_kubectl
	assert_success
	assert_output "$(printf 'v1.30.5\nnotready\nits state is IstioCNINotHealthy, not Healthy (istiod or IstioCNI not ready)\ndefault')"
	run grep -c 'get istiorevisions.sailoperator.io default ' "$IV_LOG"
	assert_output 1
}

@test "istio_version_resolve (I1): readiness off for the first reads, then Healthy: waits, records, no warning" {
	IV_a=v1.30.5 IV_b=v1.30.5 IVSTATESEQ_b="IstiodNotReady IstiodNotReady Healthy" \
		ISTIO_VERSION_READY_WAIT_SEC=10 ISTIO_VERSION_READY_POLL_SEC=1 run --separate-stderr _iv_run a,b 0
	assert_success
	assert_output "V=v1.30.5 PIN=v1.30.5 SRC=live BY=a=v1.30.5,b=v1.30.5"
	[[ "$stderr" == *"istiod or IstioCNI is not ready on 1 of 2 members; reading them again every 1s for up to 10s"* ]]
	[[ "$stderr" != *WARNING* ]]
	# Only b is read again (a was ready), until it is.
	[ "$(grep -c -- '--context=a .*get istios.sailoperator.io default' "$IV_LOG")" -eq 1 ]
	[ "$(grep -c -- '--context=b .*get istios.sailoperator.io default' "$IV_LOG")" -eq 3 ]
}

@test "istio_version_resolve (I1): readiness still off after the wait records the version and warns, under fail too" {
	IV_a=v1.30.5 IVSTATE_a=IstioCNINotHealthy ISTIO_VERSION_READY_WAIT_SEC=2 ISTIO_VERSION_READY_POLL_SEC=1 \
		run --separate-stderr _iv_run a 0
	assert_success
	# The version that was read, never unknown or mixed.
	assert_output "V=v1.30.5 PIN=v1.30.5 SRC=live BY=a=v1.30.5"
	[[ "$stderr" == *"WARNING: istiod or IstioCNI is still not ready on 1 of 1 members after 2s:"*"  a: its state is IstioCNINotHealthy, not Healthy (istiod or IstioCNI not ready)"*"check: _iv_kubectl --context a get istios.sailoperator.io default -o yaml"*"The run goes on: their version was read (ISTIO_VERSION=v1.30.5)"* ]]
	[ "$(grep -c 'get istios.sailoperator.io default' "$IV_LOG")" -eq 3 ]
	# A wait of 0 reads once and warns at once.
	: > "$IV_LOG"
	IV_a=v1.30.5 IVSTATE_a=IstiodNotReady ISTIO_VERSION_READY_WAIT_SEC=0 run --separate-stderr _iv_run a 0
	assert_success
	assert_output "V=v1.30.5 PIN=v1.30.5 SRC=live BY=a=v1.30.5"
	[[ "$stderr" == *"after 0s"* ]]
	[ "$(grep -c 'get istios.sailoperator.io default' "$IV_LOG")" -eq 1 ]
	# A bad wait value is refused before anything is read.
	ISTIO_VERSION_READY_WAIT_SEC=1m IV_a=v1.30.5 run --separate-stderr _iv_run a 0
	assert_failure 1
	[[ "$stderr" == *"ISTIO_VERSION_READY_WAIT_SEC must be a non-negative integer (got: 1m)"* ]]
}

@test "istio_version_resolve: every member at the pin records the live value, a leading v aside" {
	IV_a=v1.30.5 IV_b=v1.30.5 PIN=1.30.5 run --separate-stderr _iv_run a,b 0
	assert_success
	assert_output "V=v1.30.5 PIN=1.30.5 SRC=live BY=a=v1.30.5,b=v1.30.5"
	[ -z "$stderr" ]
	# One bounded read of each kind per member.
	[ "$(grep -c -- '--request-timeout=5s get istios.sailoperator.io default -o json' "$IV_LOG")" -eq 2 ]
	[ "$(grep -c -- '--request-timeout=5s get istiorevisions.sailoperator.io default ' "$IV_LOG")" -eq 2 ]
}

@test "istio_version_resolve: another version than the pin dies under fail (the default) with the fixes, is recorded under warn" {
	# The pin is config/versions.env's: bump it (or run with the live value).
	IV_a=v1.29.0 run --separate-stderr _iv_run a 0
	assert_failure 1
	[[ "$stderr" == *"the mesh runs Istio v1.29.0 (a=v1.29.0), but ISTIO_VERSION is v1.30.5 (config/versions.env)"* ]]
	[[ "$stderr" == *"Fix: bump ISTIO_VERSION in config/versions.env with charts/spoke-ossm istioVersion"*"or run with ISTIO_VERSION=v1.29.0 for this run only."* ]]
	[[ "$stderr" == *"Nothing was changed. To go on anyway and record ISTIO_VERSION=v1.29.0, set ISTIO_VERSION_CHECK=warn." ]]
	# A pin exported in the shell (not versions.env's): unset it first.
	IV_a=v1.30.5 PIN=1.24.0 run --separate-stderr _iv_run a 0
	assert_failure 1
	[[ "$stderr" == *"but ISTIO_VERSION is 1.24.0, exported in this shell (config/versions.env pins v1.30.5)"* ]]
	[[ "$stderr" == *"Fix: unset ISTIO_VERSION (a value left in the shell, for example by Istio's download script), or run with ISTIO_VERSION=v1.30.5"* ]]
	ISTIO_VERSION_CHECK=warn IV_a=v1.29.0 run --separate-stderr _iv_run a 0
	assert_success
	assert_output "V=v1.29.0 PIN=v1.30.5 SRC=live BY=a=v1.29.0"
	[[ "$stderr" == "warning: the mesh runs Istio v1.29.0"*"Going on (ISTIO_VERSION_CHECK=warn): the results record ISTIO_VERSION=v1.29.0 (ISTIO_VERSION_PIN=v1.30.5)." ]]
	# --no-stop (gateway-api) warns under fail too.
	IV_a=v1.29.0 run --separate-stderr _iv_run a 0 --no-stop
	assert_success
	assert_output "V=v1.29.0 PIN=v1.30.5 SRC=live BY=a=v1.29.0"
	[[ "$stderr" == *"Going on (a read-only check never stops on this)"* ]]
}

@test "istio_version_resolve: members that differ, or one that cannot be read, never record one member's value" {
	IV_a=v1.30.5 IV_b=v1.29.0 run --separate-stderr _iv_run a,b 0
	assert_failure 1
	[[ "$stderr" == *"the mesh members run different Istio versions (a=v1.30.5,b=v1.29.0)"* ]]
	ISTIO_VERSION_CHECK=warn IV_a=v1.30.5 IV_b=v1.29.0 run --separate-stderr _iv_run a,b 0
	assert_success
	# Joined with /, so no report splits the value at a comma (A4).
	assert_output "V=mixed:v1.30.5/v1.29.0 PIN=v1.30.5 SRC=live BY=a=v1.30.5,b=v1.29.0"
	IV_a=v1.30.5 run --separate-stderr _iv_run a,b 0
	assert_failure 1
	# Why, how to see it, and what to fix (access, not the pin).
	[[ "$stderr" == *"cannot read the running Istio version on 1 of 2 members:"* ]]
	[[ "$stderr" == *"  b: error: You must be logged in to the server (Unauthorized)"* ]]
	[[ "$stderr" == *"    reproduce: _iv_kubectl --context b get istios.sailoperator.io default -o yaml"* ]]
	[[ "$stderr" == *"Fix access to those members (kubeconfig, login, network), or wait until their Istio CR is settled; the pin is not the problem."* ]]
	ISTIO_VERSION_CHECK=warn IV_a=v1.30.5 run --separate-stderr _iv_run a,b 0
	assert_success
	assert_output "V=mixed:v1.30.5/unknown PIN=v1.30.5 SRC=live BY=a=v1.30.5,b=unknown"
	# An alias is never recorded; the reproduce command shows the revisions.
	ISTIO_VERSION_CHECK=warn IV_a=v1.30-latest run --separate-stderr _iv_run a 0
	assert_output "V=unknown PIN=v1.30.5 SRC=live BY=a=unknown"
	[[ "$stderr" == *"  a: IstioRevision default .spec.version is v1.30-latest, not an exact version"*"reproduce: _iv_kubectl --context a get istiorevisions.sailoperator.io -o yaml"* ]]
	# A context name with shell characters is quoted in the reproduce command.
	ISTIO_VERSION_CHECK=warn run --separate-stderr _iv_run 'default/api-x:6443/me' 0
	[[ "$stderr" == *"reproduce: _iv_kubectl --context default/api-x:6443/me get istios.sailoperator.io default -o yaml"* ]]
}

@test "istio_version_resolve: a failed read is retried once; a CR that is not settled is not" {
	IV_a=v1.30.5 IVFLAKY_a=1 run --separate-stderr _iv_run a 0
	assert_success
	assert_output "V=v1.30.5 PIN=v1.30.5 SRC=live BY=a=v1.30.5"
	[ -z "$stderr" ]
	[ "$(grep -c 'get istios.sailoperator.io default' "$IV_LOG")" -eq 2 ]
	: > "$IV_LOG"
	ISTIO_VERSION_CHECK=warn IV_a=v1.30.5 IVSTATE_a=ReconcileError IVRECON_a=False run --separate-stderr _iv_run a 0
	assert_output "V=unknown PIN=v1.30.5 SRC=live BY=a=unknown"
	[[ "$stderr" == *"  a: the Istio CR default is not settled: its state is ReconcileError, not Healthy, and its Reconciled condition is False"* ]]
	[ "$(grep -c 'get istios.sailoperator.io default' "$IV_LOG")" -eq 1 ]
	# Neither kubectl nor oc: say so, not "cannot read".
	run --separate-stderr bash -c 'source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		unset _ISTIO_VERSION_RESOLVED; istio_version_resolve a 0 no-such-kubectl-here'
	assert_failure 1
	[[ "$stderr" == "error: neither kubectl nor oc found on PATH, so the live Istio version cannot be read" ]]
}

@test "istio_version_resolve: --dry-run reads nothing; a step inherits only its sweep's marked result (A7)" {
	run --separate-stderr _iv_run a,b 1
	assert_success
	assert_output "V=v1.30.5 PIN=v1.30.5 SRC=pin BY=unchecked"
	[ ! -s "$IV_LOG" ]
	# A step under a sweep that resolved already: no second read, nothing changes.
	run bash -c 'source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		_iv_kubectl() { echo "$*" >> "$IV_LOG"; return 1; }
		export ISTIO_VERSION=mixed:a/b ISTIO_VERSION_PIN=v1.30.5 ISTIO_VERSION_SOURCE=live ISTIO_VERSION_BY_CONTEXT=x=a,y=b
		export _ISTIO_VERSION_RESOLVED="live|v1.30.5|mixed:a/b|x=a,y=b"
		istio_version_resolve a 0 _iv_kubectl
		istio_version_kv; istio_version_label'
	assert_success
	assert_output "$(printf '%s\n' ISTIO_VERSION=mixed:a/b ISTIO_VERSION_PIN=v1.30.5 ISTIO_VERSION_SOURCE=live ISTIO_VERSION_BY_CONTEXT=x=a,y=b 'mixed:a/b (the members differ or were not all read; pin v1.30.5)')"
	[ ! -s "$IV_LOG" ]
	# The same values in the shell without the marker (left by an earlier run, say) are
	# not a resolution: the member is read.
	run --separate-stderr bash -c 'source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		_iv_kubectl() { echo "$*" >> "$IV_LOG"; return 1; }
		export ISTIO_VERSION=v1.30.5 ISTIO_VERSION_PIN=v1.30.5 ISTIO_VERSION_SOURCE=live ISTIO_VERSION_BY_CONTEXT=a=v1.30.5
		unset _ISTIO_VERSION_RESOLVED
		ISTIO_VERSION_CHECK=warn istio_version_resolve a 0 _iv_kubectl
		istio_version_kv; istio_version_label'
	assert_success
	assert_output "$(printf '%s\n' ISTIO_VERSION=unknown ISTIO_VERSION_PIN=v1.30.5 ISTIO_VERSION_SOURCE=live ISTIO_VERSION_BY_CONTEXT=a=unknown 'unknown (not read on every member; pin v1.30.5)')"
	[ -s "$IV_LOG" ]
	# Nothing resolved (a report host, say): the pin, labelled as such.
	run bash -c 'source "$ROOT/tests/lib/preamble.sh"; unset ISTIO_VERSION_SOURCE ISTIO_VERSION_PIN ISTIO_VERSION_BY_CONTEXT
		ISTIO_VERSION=v1.30.5; istio_version_kv; istio_version_label'
	assert_output "$(printf '%s\n' ISTIO_VERSION=v1.30.5 ISTIO_VERSION_PIN=v1.30.5 ISTIO_VERSION_SOURCE=pin ISTIO_VERSION_BY_CONTEXT=unchecked 'v1.30.5 (the pin; not read live)')"
	run bash -c 'source "$ROOT/tests/lib/preamble.sh"; ISTIO_VERSION=v1.30.5 ISTIO_VERSION_PIN=1.30.5 ISTIO_VERSION_SOURCE=live; istio_version_label'
	assert_output "v1.30.5 (read live on every member; pin 1.30.5)"
}

@test "istio_version_resolve: a policy other than fail or warn is refused" {
	ISTIO_VERSION_CHECK=off IV_a=v1.30.5 run --separate-stderr _iv_run a 0
	assert_failure 1
	[[ "$stderr" == *"ISTIO_VERSION_CHECK must be fail or warn (got: off)"* ]]
	[ ! -s "$IV_LOG" ]
}

# _iv_recheck: resolve (members per IV_*), then apply the END_* overrides and recheck;
# print the sweep_outcome arguments it returned, one per line.
_iv_recheck() {
	(
		unset ISTIO_VERSION_SOURCE ISTIO_VERSION_PIN ISTIO_VERSION_BY_CONTEXT _ISTIO_VERSION_RESOLVED
		export ISTIO_VERSION=v1.30.5
		istio_version_resolve "$1" "${2:-0}" _iv_kubectl 2>/dev/null
		local kv
		for kv in ${END-}; do export "${kv?}"; done
		local -a out=()
		istio_version_recheck out _iv_kubectl
		printf '%s\n' ${out[@]+"${out[@]}"}
	)
}

@test "istio_version_recheck: the end-of-sweep read flags a version change, notes what it cannot confirm (A6)" {
	# Unchanged: nothing.
	IV_a=v1.30.5 IV_b=v1.30.5 run --separate-stderr _iv_recheck a,b
	assert_success
	assert_output ""
	[ -z "$stderr" ]
	# b runs another version at the end: a problem (the sweep fails). sweep_outcome prints
	# it, once; the recheck itself prints nothing.
	IV_a=v1.30.5 IV_b=v1.30.5 END="IV_b=v1.31.0" run --separate-stderr _iv_recheck a,b
	assert_success
	assert_line --index 0 -- "--problem"
	assert_line --index 1 "the Istio version changed during the sweep (b: v1.30.5 at the start, v1.31.0 at the end); its rows are not all from ISTIO_VERSION=v1.30.5"
	[ -z "$stderr" ]
	# A revision migration under way at the end is a change too, with why.
	IV_a=v1.30.5 END="IVINUSE_a=2" run --separate-stderr _iv_recheck a
	assert_line --index 0 -- "--problem"
	assert_line --index 1 --partial "a: v1.30.5 at the start, unknown at the end (the Istio CR default is not settled: 2 revisions are in use"
	# The same version under another active revision (InPlace to RevisionBased): a problem.
	IV_a=v1.30.5 END="IVREV_a=default-v1-30-5" run --separate-stderr _iv_recheck a
	assert_line --index 0 -- "--problem"
	assert_line --index 1 "the Istio active revision changed during the sweep (a: activeRevisionName default at the start, default-v1-30-5 at the end (both v1.30.5)); its rows are not all from ISTIO_VERSION=v1.30.5"
	# Not readable at the end (after one retry): a note, not a failure.
	IV_a=v1.30.5 END="IV_a=" run --separate-stderr _iv_recheck a
	assert_line --index 0 -- "--note"
	assert_line --index 1 "the Istio version at the end of the sweep is unconfirmed: a could not be read again (v1.30.5 at the start)"
	# A spec change not reconciled yet at the end: unconfirmed, a note.
	IV_a=v1.30.5 END="IVOGEN_a=2" run --separate-stderr _iv_recheck a
	assert_line --index 0 -- "--note"
	assert_line --index 1 --partial "unconfirmed: a ran v1.30.5 at the start, and at the end the Istio CR default is not settled: generation 3"
	# Nothing read live (--dry-run): nothing to compare, nothing read.
	: > "$IV_LOG"
	IV_a=v1.30.5 run --separate-stderr _iv_recheck a 1
	assert_output ""
	[ ! -s "$IV_LOG" ]
}

@test "istio_version_recheck (I1): the same version with istiod/CNI not ready at the end is a note, never a version change; the sweep does not exit 4" {
	IV_a=v1.30.5 IV_b=v1.30.5 END="IVSTATE_a=IstioCNINotHealthy" run --separate-stderr _iv_recheck a,b
	assert_success
	assert_line --index 0 -- "--note"
	assert_line --index 1 "istiod/CNI not ready at the end of the sweep, same Istio version (a: its state is IstioCNINotHealthy, not Healthy (istiod or IstioCNI not ready))"
	refute_output --partial -- "--problem"
	refute_output --partial "changed"
	# Through sweep_outcome: a warning, exit 0.
	local -a args=()
	mapfile -t args < <(IV_a=v1.30.5 END="IVSTATE_a=IstioCNINotHealthy" _iv_recheck a 2>/dev/null)
	run --separate-stderr sweep_outcome "${args[@]}" 3
	assert_success
	assert_output "All 3 cells ran (their rows' own statuses are in the report)."
	[[ "$stderr" == "warning: istiod/CNI not ready at the end of the sweep, same Istio version (a: its state is IstioCNINotHealthy"* ]]
	# Another version while not ready is still a change.
	IV_a=v1.30.5 END="IV_a=v1.31.0 IVSTATE_a=IstiodNotReady" run --separate-stderr _iv_recheck a
	assert_line --index 0 -- "--problem"
	assert_line --index 1 --partial "a: v1.30.5 at the start, v1.31.0 at the end"
}

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
	# Exactly the canonical key set, all unknown. NODE_ALLOC_* dropped (single-source
	# in the O9 capacity block); ISTIOD_REPLICAS_BY_CONTEXT added with INFRA_SCHEMA 2.
	n=$(printf '%s\n' "$output" | grep -c '^# [A-Z_]*=unknown$')
	[ "$n" -eq 7 ]
	[[ "$output" == *"# ISTIOD_REPLICAS_BY_CONTEXT=unknown"* ]]
}

@test "infra_preamble_lines: NODE_ALLOC_* are NOT emitted (single-source)" {
	run infra_preamble_lines ISTIOD_REPLICAS=5
	[ "$status" -eq 0 ]
	[[ "$output" != *"NODE_ALLOC_CPU_M"* ]]
	[[ "$output" != *"NODE_ALLOC_MEM_MI"* ]]
}

@test "infra_preamble_lines: unrecognized key is ignored (not echoed verbatim)" {
	# NODE_ALLOC_CPU_M is now unrecognized by the infra emitter, so it too is dropped.
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

@test "both controlplane writers emit CONTROLPLANE_INFRA_SCHEMA (read by 004's concordance guard)" {
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
	expected="$(git -C "$ROOT" describe --always --abbrev=7)"
	cd "$BATS_TEST_TMPDIR"
	run harness_sha
	[ "$status" -eq 0 ]
	# A tree with uncommitted changes adds -dirty.<8hex> (tests/lib/test/common.bats).
	[[ "$output" == "$expected" || "$output" =~ ^"${expected}"-dirty\.[0-9a-f]{8}$ ]]
}

@test "harness_sha: non-repo ROOT -> unknown" {
	ROOT="$BATS_TEST_TMPDIR" run harness_sha
	[ "$status" -eq 0 ]
	[ "$output" = "unknown" ]
}

# ---------------------------------------------------------------------------
# istio_version_resolve: the results record the Istio version the mesh RUNS (the
# active IstioRevision's .spec.version), read once per run before any change; the
# config/versions.env pin is kept next to it.
# ---------------------------------------------------------------------------

# _iv_kubectl: a fake kubectl for the reads of istio_live_version, per context <c>:
#   IV_<c>       the version IstioRevision <rev> answers (unset: every read fails, with an
#                Unauthorized line on stderr)
#   IVREV_<c>    .status.activeRevisionName (default `default`; `none` leaves it out)
#   IVSTATE_<c>  .status.state (default Healthy), with the conditions Sail derives it from
#                (IstiodNotReady: Ready False; IstioCNINotHealthy: Ready True and
#                DependenciesHealthy False); IVOGEN_<c> .status.observedGeneration
#                (default 3, the generation); IVINUSE_<c> .status.revisions.inUse (default 1)
#   IVRECON_<c>  the Reconciled condition's status (default True; False when the state is
#                ReconcileError, as Sail sets it)
#   IVSTATESEQ_<c> "S1 S2 ...": the state of each successive Istio CR read (the last repeats)
#   IVFLAKY_<c>  1: the first Istio CR read fails, the next ones answer
#   IVFAILFROM_<c> N: the Nth Istio CR read and every later one fail
#   IVROGEN_<c>  the IstioRevision's .status.observedGeneration (default 2, its generation)
#   IVRFAIL_<c>  N: the next N IstioRevision reads fail (counted from when it is set);
#                IVRFAILFROM_<c> N: the Nth IstioRevision read and every later one fail
#   IVDEP_<c>    "generation observedGeneration replicas updatedReplicas [terminating]" (or
#                g:o:r:u[:t]) of the istiod Deployment (default "4 4 2 2": rolled out, no
#                .status.terminatingReplicas; fail: Forbidden);
#                IVDEPSEQ_<c> "g:o:r:u ...": one per successive Deployment read (the last
#                repeats)
# The Deployment answers only under the name Sail gives it (istiodDeploymentKey: istiod
# for InPlace, whose values.revision is empty; istiod-<values.revision> otherwise) in
# istio-system. The CR's .spec.version is the alias v1.30-latest, which must never be
# recorded. Logs each call.
_iv_kubectl() {
	local ctx="" a v rev state ogen inuse flaky recon seq st n failfrom rogen dep depseq vrev depname d g o r u tr rfail rfrom
	for a in "$@"; do [[ "$a" == --context=* ]] && ctx="${a#--context=}"; done
	echo "$*" >> "$IV_LOG"
	v="IV_${ctx}" rev="IVREV_${ctx}" state="IVSTATE_${ctx}" ogen="IVOGEN_${ctx}" inuse="IVINUSE_${ctx}" flaky="IVFLAKY_${ctx}"
	recon="IVRECON_${ctx}" seq="IVSTATESEQ_${ctx}" failfrom="IVFAILFROM_${ctx}" rogen="IVROGEN_${ctx}"
	dep="IVDEP_${ctx}" depseq="IVDEPSEQ_${ctx}" rfail="IVRFAIL_${ctx}" rfrom="IVRFAILFROM_${ctx}"
	if [[ -z "${!v:-}" ]]; then
		echo "error: You must be logged in to the server (Unauthorized)" >&2
		return 1
	fi
	vrev=""
	[[ "${!rev:-default}" == default ]] || vrev="${!rev}"
	depname="istiod${vrev:+-${vrev}}"
	case " $* " in
	*" get istios.sailoperator.io default -o json "*)
		n="$(cat "${BATS_TEST_TMPDIR}/n-${ctx}" 2>/dev/null || echo 0)"
		echo $((n + 1)) > "${BATS_TEST_TMPDIR}/n-${ctx}"
		if [[ -n "${!flaky:-}" ]] && ((n == 0)); then
			echo "Unable to connect to the server: net/http: TLS handshake timeout" >&2
			return 1
		fi
		if [[ -n "${!failfrom:-}" ]] && ((n + 1 >= ${!failfrom})); then
			echo "Unable to connect to the server: dial tcp <api-host>: i/o timeout" >&2
			return 1
		fi
		st="${!state:-Healthy}"
		if [[ -n "${!seq:-}" ]]; then
			read -r -a a <<<"${!seq}"
			((n < ${#a[@]})) || n=$((${#a[@]} - 1))
			st="${a[n]}"
		fi
		jq -nc --arg rev "${!rev:-default}" --arg state "$st" --arg recon "${!recon:-True}" \
			--argjson ogen "${!ogen:-3}" --argjson inuse "${!inuse:-1}" \
			'{metadata: {name: "default", generation: 3}, spec: {version: "v1.30-latest"},
			  status: ({state: $state, observedGeneration: $ogen, revisions: {total: $inuse, ready: $inuse, inUse: $inuse},
			            conditions: [{type: "Reconciled", status: (if $state == "ReconcileError" then "False" else $recon end)},
			                         {type: "Ready", status: (if $state == "IstiodNotReady" then "False" else "True" end)},
			                         {type: "DependenciesHealthy", status: (if $state == "IstioCNINotHealthy" then "False" else "True" end)}]}
			  + (if $rev == "none" then {} else {activeRevisionName: $rev} end))}' ;;
	*" get istiorevisions.sailoperator.io ${!rev:-default} -o json "*)
		if [[ -n "${!rfail:-}" ]]; then
			n="$(cat "${BATS_TEST_TMPDIR}/rn-${ctx}" 2>/dev/null || echo 0)"
			echo $((n + 1)) > "${BATS_TEST_TMPDIR}/rn-${ctx}"
			if ((n < ${!rfail})); then
				echo "Unable to connect to the server: net/http: TLS handshake timeout" >&2
				return 1
			fi
		fi
		if [[ -n "${!rfrom:-}" ]]; then
			n="$(cat "${BATS_TEST_TMPDIR}/rf-${ctx}" 2>/dev/null || echo 0)"
			echo $((n + 1)) > "${BATS_TEST_TMPDIR}/rf-${ctx}"
			if ((n + 1 >= ${!rfrom})); then
				echo "Unable to connect to the server: net/http: TLS handshake timeout" >&2
				return 1
			fi
		fi
		jq -nc --arg v "${!v}" --arg vrev "$vrev" --argjson rogen "${!rogen:-2}" \
			'{metadata: {generation: 2}, spec: {version: $v, namespace: "istio-system", values: {revision: $vrev}},
			  status: {observedGeneration: $rogen}}' ;;
	*" -n istio-system get deployments.apps ${depname} -o json "*)
		d="${!dep:-4 4 2 2}"
		if [[ -n "${!depseq:-}" ]]; then
			n="$(cat "${BATS_TEST_TMPDIR}/dn-${ctx}" 2>/dev/null || echo 0)"
			echo $((n + 1)) > "${BATS_TEST_TMPDIR}/dn-${ctx}"
			read -r -a a <<<"${!depseq}"
			((n < ${#a[@]})) || n=$((${#a[@]} - 1))
			d="${a[n]//:/ }"
		fi
		d="${d//:/ }"
		if [[ "$d" == fail ]]; then
			echo 'Error from server (Forbidden): deployments.apps "istiod" is forbidden' >&2
			return 1
		fi
		read -r g o r u tr <<<"$d"
		jq -nc --argjson g "$g" --argjson o "$o" --argjson r "$r" --argjson u "$u" --arg t "${tr:-}" \
			'{metadata: {generation: $g}, status: ({observedGeneration: $o, replicas: $r, updatedReplicas: $u, readyReplicas: $r}
			  + (if $t == "" then {} else {terminatingReplicas: ($t | tonumber)} end))}' ;;
	*)
		echo "Error from server (NotFound): not found" >&2
		return 1 ;;
	esac
}

# _iv_run <ctxs_csv> <dry 0|1> [--no-stop]: resolve in a subshell with pin ISTIO_VERSION
# (default v1.30.5), then print what it exported (IV_SHOW_NR=1: also the readiness keys).
_iv_run() {
	(
		unset ISTIO_VERSION_SOURCE ISTIO_VERSION_PIN ISTIO_VERSION_BY_CONTEXT _ISTIO_VERSION_RESOLVED
		unset ISTIO_NOTREADY_AT_START ISTIO_READY_WAITED_SEC
		export ISTIO_VERSION="${PIN-v1.30.5}"
		if [[ "${3:-}" == --no-stop ]]; then
			istio_version_resolve --no-stop "$1" "$2" _iv_kubectl
		elif [[ "${3:-}" == --resumed-at ]]; then
			istio_version_resolve --resumed-at "$4" "$1" "$2" _iv_kubectl
		else
			istio_version_resolve "$1" "$2" _iv_kubectl
		fi
		echo "V=${ISTIO_VERSION} PIN=${ISTIO_VERSION_PIN} SRC=${ISTIO_VERSION_SOURCE} BY=${ISTIO_VERSION_BY_CONTEXT}"
		[[ -z "${IV_SHOW_NR:-}" ]] || echo "NR=${ISTIO_NOTREADY_AT_START} WAITED=${ISTIO_READY_WAITED_SEC}"
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
	assert_output "$(printf 'v1.30.5\nok\n\ndefault\nv1.30.5\nHealthy')"
	# Three bounded reads: the Istio CR, the revision it names (-o json), and (Healthy
	# too) the istiod Deployment of that revision.
	run cat "$IV_LOG"
	assert_line "--context=a --request-timeout=5s get istios.sailoperator.io default -o json"
	assert_line "--context=a --request-timeout=5s get istiorevisions.sailoperator.io default -o json"
	assert_line "--context=a --request-timeout=5s -n istio-system get deployments.apps istiod -o json"
	: > "$IV_LOG"
	IV_a=1.30.5 IVREV_a=default-v1-30-5 run istio_live_version a _iv_kubectl
	assert_output "$(printf '1.30.5\nok\n\ndefault-v1-30-5\n1.30.5\nHealthy')"
	run grep -c 'get istiorevisions.sailoperator.io default-v1-30-5 ' "$IV_LOG"
	assert_output 1
	# The revision answers an alias (or anything but N.N.N): unknown, never the alias.
	IV_a=v1.30-latest run istio_live_version a _iv_kubectl
	assert_output "$(printf 'unknown\nvalue\nIstioRevision default .spec.version is v1.30-latest, not an exact version\ndefault\n\nHealthy')"
}

@test "istio_live_version: an Istio CR or IstioRevision that is not settled reads unknown, with what is off and the revision's version" {
	IV_a=v1.30.5 IVSTATE_a=ReconcileError IVRECON_a=False run istio_live_version a _iv_kubectl
	assert_output "$(printf 'unknown\nstate\nthe Istio CR default is not settled: its state is ReconcileError, not Healthy, and its Reconciled condition is False\ndefault\nv1.30.5\nReconcileError')"
	IV_a=v1.30.5 IVOGEN_a=2 run istio_live_version a _iv_kubectl
	assert_output "$(printf 'unknown\nstate\nthe Istio CR default is not settled: generation 3 is not reconciled yet (observedGeneration 2)\ndefault\nv1.30.5\nHealthy')"
	IV_a=v1.30.5 IVINUSE_a=2 IVSTATE_a=IstiodNotReady run istio_live_version a _iv_kubectl
	assert_output "$(printf 'unknown\nmigrating\nthe Istio CR default is not settled: its state is IstiodNotReady, not Healthy; 2 revisions are in use (a revision migration in progress)\ndefault\nv1.30.5\nIstiodNotReady')"
	IV_a=v1.30.5 IVREV_a=none run istio_live_version a _iv_kubectl
	assert_output "$(printf 'unknown\nstate\nthe Istio CR default is not settled: it names no activeRevisionName\n\n\nHealthy')"
	# The three that name a revision read it (its version, for the end-of-sweep compare);
	# none reads the istiod Deployment.
	run grep -c istiorevisions "$IV_LOG"
	assert_output 3
	run grep -c deployments "$IV_LOG"
	assert_output 0
	# An IstioRevision whose generation is not reconciled yet (its Helm upgrade has
	# not run; the CR may already read Healthy): unsettled, kind state.
	IV_a=v1.30.6 IVROGEN_a=1 run istio_live_version a _iv_kubectl
	assert_output "$(printf 'unknown\nstate\nthe IstioRevision default is not settled: generation 2 is not reconciled yet (observedGeneration 1)\ndefault\nv1.30.6\nHealthy')"
	# A failed read keeps the first line of kubectl's stderr.
	run istio_live_version a _iv_kubectl
	assert_output "$(printf 'unknown\nread\nerror: You must be logged in to the server (Unauthorized)')"
}

@test "istio_live_version: readiness alone off reads the version as notready; an istiod rollout in progress is rolling" {
	# Reconciled True, generation reconciled, one revision in use, istiod rolled out: only
	# istiod or CNI readiness (a pod restart, an HPA scale-up, IstioCNI not healthy).
	IV_a=v1.30.5 IVSTATE_a=IstioCNINotHealthy run istio_live_version a _iv_kubectl
	assert_success
	assert_output "$(printf 'v1.30.5\nnotready\nits state is IstioCNINotHealthy, not Healthy\ndefault\nv1.30.5\nIstioCNINotHealthy')"
	run grep -c 'get istiorevisions.sailoperator.io default ' "$IV_LOG"
	assert_output 1
	run grep -c -- '--request-timeout=5s -n istio-system get deployments.apps istiod -o json' "$IV_LOG"
	assert_output 1
	# An InPlace upgrade whose surge pods are not ready yet: updatedReplicas < replicas.
	IV_a=v1.30.6 IVSTATE_a=IstiodNotReady IVDEP_a="5 5 3 1" run istio_live_version a _iv_kubectl
	assert_output "$(printf 'v1.30.6\nrolling\nistiod is rolling out v1.30.6 (Deployment istio-system/istiod: 1 of 3 pods updated); its state is IstiodNotReady\ndefault\nv1.30.6\nIstiodNotReady')"
	# A new Deployment generation the controller has not observed yet.
	IV_a=v1.30.6 IVSTATE_a=IstiodNotReady IVDEP_a="6 5 2 2" run istio_live_version a _iv_kubectl
	assert_line --index 1 rolling
	assert_line --index 2 "istiod is rolling out v1.30.6 (Deployment istio-system/istiod: 2 of 2 pods updated, generation 6 not observed yet); its state is IstiodNotReady"
	# RevisionBased: the Deployment is istiod-<values.revision>.
	: > "$IV_LOG"
	IV_a=v1.30.6 IVREV_a=default-v1-30-6 IVSTATE_a=IstiodNotReady IVDEP_a="5 5 3 1" run istio_live_version a _iv_kubectl
	assert_line --index 1 rolling
	run grep -c -- '-n istio-system get deployments.apps istiod-default-v1-30-6 -o json' "$IV_LOG"
	assert_output 1
	# The Deployment cannot be read: kind read (retried, then unknown), never a guess; the
	# revision's version is kept for the end-of-sweep compare.
	IV_a=v1.30.5 IVSTATE_a=IstiodNotReady IVDEP_a=fail run istio_live_version a _iv_kubectl
	assert_output "$(printf 'unknown\nread\nistiod Deployment istio-system/istiod: Error from server (Forbidden): deployments.apps "istiod" is forbidden\ndefault\nv1.30.5\nIstiodNotReady')"
	# Healthy is not "rolled out": right after the upgrade, before the Deployment
	# controller observed it, and with every pod ready but the old ReplicaSet not scaled
	# down yet, old istiod pods still serve.
	IV_a=v1.30.6 IVDEP_a="6 5 2 2" run istio_live_version a _iv_kubectl
	assert_output "$(printf 'v1.30.6\nrolling\nistiod is rolling out v1.30.6 (Deployment istio-system/istiod: 2 of 2 pods updated, generation 6 not observed yet); its state is Healthy\ndefault\nv1.30.6\nHealthy')"
	IV_a=v1.30.6 IVDEP_a="5 5 3 2" run istio_live_version a _iv_kubectl
	assert_line --index 1 rolling
	assert_line --index 2 "istiod is rolling out v1.30.6 (Deployment istio-system/istiod: 2 of 3 pods updated); its state is Healthy"
	IV_a=v1.30.5 IVDEP_a=fail run istio_live_version a _iv_kubectl
	assert_output "$(printf 'unknown\nread\nistiod Deployment istio-system/istiod: Error from server (Forbidden): deployments.apps "istiod" is forbidden\ndefault\nv1.30.5\nHealthy')"
}

@test "istio_version_resolve: readiness off for the first reads, then Healthy: waits, records, no warning" {
	IV_a=v1.30.5 IV_b=v1.30.5 IVSTATESEQ_b="IstiodNotReady IstiodNotReady Healthy" IV_SHOW_NR=1 \
		ISTIO_VERSION_READY_WAIT_SEC=10 ISTIO_VERSION_READY_POLL_SEC=1 run --separate-stderr _iv_run a,b 0
	assert_success
	assert_line --index 0 "V=v1.30.5 PIN=v1.30.5 SRC=live BY=a=v1.30.5,b=v1.30.5"
	# Nobody is left not ready; the wait is recorded.
	assert_line --index 1 --regexp '^NR=none WAITED=[1-4]$'
	[[ "$stderr" == *"istiod or IstioCNI is not ready (or istiod is rolling out) on 1 of 2 members; reading them again every 1s for up to 10s (plus one poll)..."* ]]
	[[ "$stderr" != *WARNING* ]]
	# Only b is read again (a was ready), until it is.
	[ "$(grep -c -- '--context=a .*get istios.sailoperator.io default' "$IV_LOG")" -eq 1 ]
	[ "$(grep -c -- '--context=b .*get istios.sailoperator.io default' "$IV_LOG")" -eq 3 ]
}

@test "istio_version_resolve: readiness still off after the wait records the version and warns, under fail too" {
	IV_a=v1.30.5 IVSTATE_a=IstioCNINotHealthy ISTIO_VERSION_READY_WAIT_SEC=2 ISTIO_VERSION_READY_POLL_SEC=1 IV_SHOW_NR=1 \
		run --separate-stderr _iv_run a 0
	assert_success
	# The version that was read, never unknown or mixed; ISTIO_NOTREADY_AT_START records the state.
	assert_line --index 0 "V=v1.30.5 PIN=v1.30.5 SRC=live BY=a=v1.30.5"
	assert_line --index 1 --regexp '^NR=a=IstioCNINotHealthy WAITED=[2-4]$'
	# A SECONDS deadline; the warning prints the time it really took.
	local re='WARNING: istiod or IstioCNI is still not ready on 1 of 1 members after [2-4]s:'
	[[ "$stderr" =~ $re ]]
	[[ "$stderr" == *"  IstioCNINotHealthy on 1 member (a)"$'\n'"    check: _iv_kubectl --context a get istios.sailoperator.io default -o yaml"$'\n'"The run goes on"* ]]
	[[ "$stderr" == *"The run goes on: their version was read (ISTIO_VERSION=v1.30.5)"* ]]
	[[ "$stderr" != *"(istiod or IstioCNI not ready)"* ]]
	n="$(grep -c 'get istios.sailoperator.io default' "$IV_LOG")"
	((n >= 2 && n <= 3))
	# A wait of 0 reads once and warns at once.
	: > "$IV_LOG"
	IV_a=v1.30.5 IVSTATE_a=IstiodNotReady ISTIO_VERSION_READY_WAIT_SEC=0 IV_SHOW_NR=1 run --separate-stderr _iv_run a 0
	assert_success
	assert_output "$(printf '%s\n' "V=v1.30.5 PIN=v1.30.5 SRC=live BY=a=v1.30.5" "NR=a=IstiodNotReady WAITED=0")"
	[[ "$stderr" == *"after 0s"* ]]
	[ "$(grep -c 'get istios.sailoperator.io default' "$IV_LOG")" -eq 1 ]
	# A bad wait value is refused before anything is read.
	ISTIO_VERSION_READY_WAIT_SEC=1m IV_a=v1.30.5 run --separate-stderr _iv_run a 0
	assert_failure 1
	[[ "$stderr" == *"ISTIO_VERSION_READY_WAIT_SEC must be a non-negative integer (got: 1m)"* ]]
}

@test "istio_version_resolve: an istiod rollout still in progress after the wait is unknown: fail dies before any change, warn records unknown" {
	# The surge pods are not ready: the new version is not the one every pod serves yet.
	IV_a=v1.30.6 PIN=v1.30.6 IVSTATE_a=IstiodNotReady IVDEP_a="5 5 3 1" \
		ISTIO_VERSION_READY_WAIT_SEC=1 ISTIO_VERSION_READY_POLL_SEC=1 run --separate-stderr _iv_run a 0
	assert_failure 1
	[[ "$stderr" == *"istiod or IstioCNI is not ready (or istiod is rolling out) on 1 of 1 members; reading them again"* ]]
	[[ "$stderr" == *"cannot confirm the running Istio version on 1 of 1 members:"$'\n'"  a: istiod is rolling out v1.30.6 (Deployment istio-system/istiod: 1 of 3 pods updated); its state is IstiodNotReady; still rolling out after "* ]]
	# The rollout's command is a check, naming the Deployment that was read.
	[[ "$stderr" == *"    check: _iv_kubectl --context a -n istio-system get deployments.apps istiod -o yaml"* ]]
	# Only the fix that can help (nothing to fix about access or the pin).
	[[ "$stderr" == *$'\n'"Wait until their istiod rollout is complete (or raise ISTIO_VERSION_READY_WAIT_SEC); the pin is not the problem."$'\n'* ]]
	[[ "$stderr" != *"Fix access"* ]]
	[[ "$stderr" == *"Nothing was changed. To go on anyway and record ISTIO_VERSION=unknown, set ISTIO_VERSION_CHECK=warn." ]]
	# Polled (the Deployment re-read each time), never recorded as the new version.
	[ "$(grep -c 'get deployments.apps istiod ' "$IV_LOG")" -ge 2 ]
	ISTIO_VERSION_CHECK=warn IV_a=v1.30.6 PIN=v1.30.6 IVSTATE_a=IstiodNotReady IVDEP_a="5 5 3 1" IV_SHOW_NR=1 \
		ISTIO_VERSION_READY_WAIT_SEC=0 run --separate-stderr _iv_run a 0
	assert_success
	assert_output "$(printf '%s\n' "V=unknown PIN=v1.30.6 SRC=live BY=a=unknown" "NR=a=rolling WAITED=0")"
	# The rollout completes during the wait (the CR Healthy, the Deployment rolled out):
	# recorded, no warning, after one more read (old pods may still be draining).
	rm -f "${BATS_TEST_TMPDIR}"/n-* "${BATS_TEST_TMPDIR}"/dn-*
	: > "$IV_LOG"
	IV_a=v1.30.6 PIN=v1.30.6 IVSTATESEQ_a="IstiodNotReady Healthy" IVDEPSEQ_a="5:5:3:1 5:5:3:3" IV_SHOW_NR=1 \
		ISTIO_VERSION_READY_WAIT_SEC=10 ISTIO_VERSION_READY_POLL_SEC=1 run --separate-stderr _iv_run a 0
	assert_success
	assert_line --index 0 "V=v1.30.6 PIN=v1.30.6 SRC=live BY=a=v1.30.6"
	assert_line --index 1 --regexp '^NR=none WAITED=[1-4]$'
	[[ "$stderr" != *WARNING* && "$stderr" != *warning* ]]
	[ "$(grep -c 'get istios.sailoperator.io default' "$IV_LOG")" -eq 3 ]
	# The CR Healthy while the Deployment still rolls out is rolling, never the version.
	rm -f "${BATS_TEST_TMPDIR}"/n-* "${BATS_TEST_TMPDIR}"/dn-*
	ISTIO_VERSION_CHECK=warn IV_a=v1.30.6 PIN=v1.30.6 IVDEP_a="5 5 3 2" IV_SHOW_NR=1 \
		ISTIO_VERSION_READY_WAIT_SEC=0 run --separate-stderr _iv_run a 0
	assert_output "$(printf '%s\n' "V=unknown PIN=v1.30.6 SRC=live BY=a=unknown" "NR=a=rolling WAITED=0")"
}

@test "istio_version_resolve: IstiodNotReady with the rollout complete records the version and warns" {
	# A pod restart or an HPA scale-up: updatedReplicas == replicas, the Deployment observed.
	IV_a=v1.30.5 IVSTATE_a=IstiodNotReady IVDEP_a="4 4 3 3" IV_SHOW_NR=1 \
		ISTIO_VERSION_READY_WAIT_SEC=1 ISTIO_VERSION_READY_POLL_SEC=1 run --separate-stderr _iv_run a 0
	assert_success
	assert_line --index 0 "V=v1.30.5 PIN=v1.30.5 SRC=live BY=a=v1.30.5"
	assert_line --index 1 --regexp '^NR=a=IstiodNotReady WAITED=[1-3]$'
	[[ "$stderr" == *"WARNING: istiod or IstioCNI is still not ready on 1 of 1 members after"*"  IstiodNotReady on 1 member (a)"* ]]
}

@test "istio_version_resolve: a failed re-read keeps the previous answer; under fail, nobody is waited for when the run stops anyway" {
	# The first read answers notready, every re-read fails: still notready (its version
	# recorded, a warning), not unknown; one read per poll (no retry inside the wait).
	IV_a=v1.30.5 IVSTATE_a=IstioCNINotHealthy IVFAILFROM_a=2 IV_SHOW_NR=1 \
		ISTIO_VERSION_READY_WAIT_SEC=2 ISTIO_VERSION_READY_POLL_SEC=1 run --separate-stderr _iv_run a 0
	assert_success
	assert_line --index 0 "V=v1.30.5 PIN=v1.30.5 SRC=live BY=a=v1.30.5"
	assert_line --index 1 --regexp '^NR=a=IstioCNINotHealthy WAITED=[2-4]$'
	[[ "$stderr" == *"WARNING: istiod or IstioCNI is still not ready on 1 of 1 members"* ]]
	n="$(grep -c 'get istios.sailoperator.io default' "$IV_LOG")"
	((n >= 2 && n <= 3))
	# C cannot be read, so fail stops the run whatever b's readiness does: no wait.
	: > "$IV_LOG"
	IV_a=v1.30.5 IV_b=v1.30.5 IVSTATE_b=IstioCNINotHealthy ISTIO_VERSION_READY_WAIT_SEC=30 ISTIO_VERSION_READY_POLL_SEC=1 \
		run --separate-stderr _iv_run a,b,c 0
	assert_failure 1
	[[ "$stderr" == *"not waiting for istiod or IstioCNI on 1 of 3 members: the version of c is unknown, which stops the run under ISTIO_VERSION_CHECK=fail anyway"* ]]
	[[ "$stderr" == *"cannot read the running Istio version on 1 of 3 members:"* ]]
	[ "$(grep -c -- '--context=b .*get istios.sailoperator.io default' "$IV_LOG")" -eq 1 ]
	# Another version on a member that is ready: the same.
	: > "$IV_LOG"
	IV_a=v1.29.0 IV_b=v1.30.5 IVSTATE_b=IstioCNINotHealthy ISTIO_VERSION_READY_WAIT_SEC=30 ISTIO_VERSION_READY_POLL_SEC=1 \
		run --separate-stderr _iv_run a,b 0
	assert_failure 1
	[[ "$stderr" == *"not waiting for istiod or IstioCNI on 1 of 2 members: the members run different Istio versions"* ]]
	[ "$(grep -c -- '--context=b .*get istios.sailoperator.io default' "$IV_LOG")" -eq 1 ]
	# Under warn the run goes on, so the wait is worth it.
	: > "$IV_LOG"
	ISTIO_VERSION_CHECK=warn IV_a=v1.29.0 IV_b=v1.30.5 IVSTATE_b=IstioCNINotHealthy ISTIO_VERSION_READY_WAIT_SEC=1 \
		ISTIO_VERSION_READY_POLL_SEC=1 run --separate-stderr _iv_run a,b 0
	assert_success
	[[ "$stderr" != *"not waiting"* ]]
	[ "$(grep -c -- '--context=b .*get istios.sailoperator.io default' "$IV_LOG")" -ge 2 ]
}

@test "istio_version_resolve: a member in the wait that reads unsettled for a while stays in the wait; its answer at the deadline counts" {
	# Not ready, then a ReconcileError for two reads, then Healthy: recorded, under fail.
	IV_a=v1.30.5 IVSTATESEQ_a="IstiodNotReady ReconcileError ReconcileError Healthy" IV_SHOW_NR=1 \
		ISTIO_VERSION_READY_WAIT_SEC=20 ISTIO_VERSION_READY_POLL_SEC=1 run --separate-stderr _iv_run a 0
	assert_success
	assert_line --index 0 "V=v1.30.5 PIN=v1.30.5 SRC=live BY=a=v1.30.5"
	assert_line --index 1 --regexp '^NR=none WAITED=[2-7]$'
	[ "$(grep -c 'get istios.sailoperator.io default' "$IV_LOG")" -eq 4 ]
	# Still not settled at the deadline: that answer counts (unknown, so fail stops the run).
	rm -f "${BATS_TEST_TMPDIR}"/n-* "${BATS_TEST_TMPDIR}"/dn-*
	: > "$IV_LOG"
	IV_a=v1.30.5 IVSTATESEQ_a="IstiodNotReady ReconcileError" ISTIO_VERSION_READY_WAIT_SEC=2 ISTIO_VERSION_READY_POLL_SEC=1 \
		run --separate-stderr _iv_run a 0
	assert_failure 1
	[[ "$stderr" == *"  a: the Istio CR default is not settled: its state is ReconcileError, not Healthy, and its Reconciled condition is False"* ]]
	[[ "$stderr" != *"not waiting"* ]]
	[ "$(grep -c 'get istios.sailoperator.io default' "$IV_LOG")" -ge 2 ]
}

@test "istio_version_resolve: a rollout to another version than the pin is not waited for, and only the advice that can help is given" {
	IV_a=v1.30.6 IVSTATE_a=IstiodNotReady IVDEP_a="5 5 3 1" ISTIO_VERSION_READY_WAIT_SEC=30 ISTIO_VERSION_READY_POLL_SEC=1 \
		run --separate-stderr _iv_run a 0
	assert_failure 1
	[[ "$stderr" == *"not waiting for istiod or IstioCNI on 1 of 1 members: the mesh runs Istio v1.30.6, not the pin v1.30.5, which stops the run under ISTIO_VERSION_CHECK=fail anyway"* ]]
	[[ "$stderr" == *"  a: istiod is rolling out v1.30.6 (Deployment istio-system/istiod: 1 of 3 pods updated); its state is IstiodNotReady; not waited for"$'\n'* ]]
	[[ "$stderr" == *$'\n'"Wait until their istiod rollout is complete. Also, a is rolling out v1.30.6, not the pin v1.30.5: bump ISTIO_VERSION in config/versions.env with charts/spoke-ossm istioVersion when the mesh is upgraded on purpose."$'\n'* ]]
	[[ "$stderr" != *"after 0s"* ]]
	[[ "$stderr" != *"raise ISTIO_VERSION_READY_WAIT_SEC"* ]]
	[[ "$stderr" != *"the pin is not the problem"* ]]
	[[ "$stderr" != *"Fix access"* ]]
	[ "$(grep -c 'get istios.sailoperator.io default' "$IV_LOG")" -eq 1 ]
}

@test "istio_version_resolve: the start warning is grouped by state; a failed re-read is named; a rollout seen only at the first read is unreachable, not still rolling out" {
	ISTIO_VERSION_CHECK=warn IV_a=v1.30.5 IVSTATE_a=IstiodNotReady IVDEP_a="5 5 3 1" IVFAILFROM_a=2 \
		IV_b=v1.30.5 IVSTATE_b=IstioCNINotHealthy IV_c=v1.30.5 IVSTATE_c=IstioCNINotHealthy \
		IV_d=v1.30.5 IVSTATE_d=IstiodNotReady IVFAILFROM_d=2 IV_SHOW_NR=1 \
		ISTIO_VERSION_READY_WAIT_SEC=2 ISTIO_VERSION_READY_POLL_SEC=1 run --separate-stderr _iv_run a,b,c,d 0
	assert_success
	assert_line --index 0 "V=mixed:unknown/v1.30.5 PIN=v1.30.5 SRC=live BY=a=unknown,b=v1.30.5,c=v1.30.5,d=v1.30.5"
	assert_line --index 1 --regexp '^NR=a=unreadable,b=IstioCNINotHealthy,c=IstioCNINotHealthy,d=IstiodNotReady WAITED=[2-4]$'
	[[ "$stderr" == *"cannot read the running Istio version on 1 of 4 members:"$'\n'"  a: every re-read during the wait failed (Unable to connect to the server: dial tcp <api-host>: i/o timeout); the first read saw: istiod is rolling out v1.30.5 (Deployment istio-system/istiod: 1 of 3 pods updated); its state is IstiodNotReady"$'\n'"    reproduce: _iv_kubectl --context a get istios.sailoperator.io default -o yaml"$'\n'"  (API hosts, addresses, user names and home dirs are masked above; run a reproduce line for the full error)"$'\n'"Fix access to those members"* ]]
	[[ "$stderr" != *"still rolling out"* ]]
	[[ "$stderr" == *"WARNING: istiod or IstioCNI is still not ready on 3 of 4 members after "*$'\n'"  IstioCNINotHealthy on 2 members (b, c)"$'\n'"    check (shown for b): _iv_kubectl --context b get istios.sailoperator.io default -o yaml"$'\n'"  IstiodNotReady on 1 member (d)"$'\n'"    check: _iv_kubectl --context d get istios.sailoperator.io default -o yaml"$'\n'"  every re-read during the wait failed on d: the state above is what the first read saw"$'\n'"The run goes on"* ]]
}

@test "istio_version_resolve: every member at the pin records the live value, a leading v aside" {
	IV_a=v1.30.5 IV_b=v1.30.5 PIN=1.30.5 IV_SHOW_NR=1 run --separate-stderr _iv_run a,b 0
	assert_success
	assert_output "$(printf '%s\n' "V=v1.30.5 PIN=1.30.5 SRC=live BY=a=v1.30.5,b=v1.30.5" "NR=none WAITED=0")"
	[ -z "$stderr" ]
	# One bounded read of each kind per member: the Istio CR, its revision, and the
	# istiod Deployment.
	[ "$(grep -c -- '--request-timeout=5s get istios.sailoperator.io default -o json' "$IV_LOG")" -eq 2 ]
	[ "$(grep -c -- '--request-timeout=5s get istiorevisions.sailoperator.io default -o json' "$IV_LOG")" -eq 2 ]
	[ "$(grep -c -- '--request-timeout=5s -n istio-system get deployments.apps istiod -o json' "$IV_LOG")" -eq 2 ]
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
	# Joined with /, so no report splits the value at a comma.
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

@test "istio_version_resolve: --dry-run reads nothing; a step inherits only its sweep's marked result" {
	IV_SHOW_NR=1 run --separate-stderr _iv_run a,b 1
	assert_success
	assert_output "$(printf '%s\n' "V=v1.30.5 PIN=v1.30.5 SRC=pin BY=unchecked" "NR=unchecked WAITED=unchecked")"
	[ ! -s "$IV_LOG" ]
	# A step under a sweep that resolved already: no second read, nothing changes.
	run bash -c 'source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		_iv_kubectl() { echo "$*" >> "$IV_LOG"; return 1; }
		export ISTIO_VERSION=mixed:a/b ISTIO_VERSION_PIN=v1.30.5 ISTIO_VERSION_SOURCE=live ISTIO_VERSION_BY_CONTEXT=x=a,y=b
		export ISTIO_NOTREADY_AT_START=y=IstiodNotReady ISTIO_READY_WAITED_SEC=60 _ISTIO_VERSION_REVS=x=default,y=default-v1-30-5
		export _ISTIO_VERSION_RESOLVED="live|v1.30.5|mixed:a/b|x=a,y=b|y=IstiodNotReady|60||"
		istio_version_resolve a 0 _iv_kubectl
		istio_version_kv; istio_version_label'
	assert_success
	# The active revisions the sweep read go into every preamble too.
	assert_output "$(printf '%s\n' ISTIO_VERSION=mixed:a/b ISTIO_VERSION_PIN=v1.30.5 ISTIO_VERSION_SOURCE=live ISTIO_VERSION_BY_CONTEXT=x=a,y=b \
		ISTIO_NOTREADY_AT_START=y=IstiodNotReady ISTIO_READY_WAITED_SEC=60 ISTIO_ACTIVE_REVISIONS=x=default,y=default-v1-30-5 \
		ISTIO_GENERATIONS=unknown ISTIO_PROXY_VERSIONS=unknown 'mixed:a/b (the members differ or were not all read; pin v1.30.5)')"
	[ ! -s "$IV_LOG" ]
	# The same values in the shell without the marker (left by an earlier run, say) are
	# not a resolution: the member is read.
	run --separate-stderr bash -c 'source "$ROOT/tests/lib/common.sh"; source "$ROOT/tests/lib/preamble.sh"
		_iv_kubectl() { echo "$*" >> "$IV_LOG"; return 1; }
		export ISTIO_VERSION=v1.30.5 ISTIO_VERSION_PIN=v1.30.5 ISTIO_VERSION_SOURCE=live ISTIO_VERSION_BY_CONTEXT=a=v1.30.5
		export ISTIO_NOTREADY_AT_START=a=IstiodNotReady ISTIO_READY_WAITED_SEC=60
		unset _ISTIO_VERSION_RESOLVED
		ISTIO_VERSION_CHECK=warn istio_version_resolve a 0 _iv_kubectl
		istio_version_kv; istio_version_label'
	assert_success
	assert_output "$(printf '%s\n' ISTIO_VERSION=unknown ISTIO_VERSION_PIN=v1.30.5 ISTIO_VERSION_SOURCE=live ISTIO_VERSION_BY_CONTEXT=a=unknown \
		ISTIO_NOTREADY_AT_START=none ISTIO_READY_WAITED_SEC=0 ISTIO_ACTIVE_REVISIONS=a= ISTIO_GENERATIONS=a=unknown/unknown \
		ISTIO_PROXY_VERSIONS=a=unknown 'unknown (not read on every member; pin v1.30.5)')"
	[ -s "$IV_LOG" ]
	# Nothing resolved (a report host, say): the pin, labelled as such.
	run bash -c 'source "$ROOT/tests/lib/preamble.sh"; unset ISTIO_VERSION_SOURCE ISTIO_VERSION_PIN ISTIO_VERSION_BY_CONTEXT
		unset ISTIO_NOTREADY_AT_START ISTIO_READY_WAITED_SEC
		ISTIO_VERSION=v1.30.5; istio_version_kv; istio_version_label'
	assert_output "$(printf '%s\n' ISTIO_VERSION=v1.30.5 ISTIO_VERSION_PIN=v1.30.5 ISTIO_VERSION_SOURCE=pin ISTIO_VERSION_BY_CONTEXT=unchecked \
		ISTIO_NOTREADY_AT_START=unchecked ISTIO_READY_WAITED_SEC=unchecked ISTIO_ACTIVE_REVISIONS=unchecked ISTIO_GENERATIONS=unchecked \
		ISTIO_PROXY_VERSIONS=unchecked 'v1.30.5 (the pin; not read live)')"
	run bash -c 'source "$ROOT/tests/lib/preamble.sh"; ISTIO_VERSION=v1.30.5 ISTIO_VERSION_PIN=1.30.5 ISTIO_VERSION_SOURCE=live; istio_version_label'
	assert_output "v1.30.5 (read live on every member; pin 1.30.5)"
}

@test "istio_version_resolve: a policy other than fail or warn is refused" {
	ISTIO_VERSION_CHECK=off IV_a=v1.30.5 run --separate-stderr _iv_run a 0
	assert_failure 1
	[[ "$stderr" == *"ISTIO_VERSION_CHECK must be fail or warn (got: off)"* ]]
	[ ! -s "$IV_LOG" ]
}

# _iv_recheck: resolve (members per IV_*; no readiness wait), then apply the END_*
# overrides and recheck; print the sweep_outcome arguments it returned, one per line.
_iv_recheck() {
	(
		unset ISTIO_VERSION_SOURCE ISTIO_VERSION_PIN ISTIO_VERSION_BY_CONTEXT _ISTIO_VERSION_RESOLVED
		unset ISTIO_NOTREADY_AT_START ISTIO_READY_WAITED_SEC
		export ISTIO_VERSION=v1.30.5
		ISTIO_VERSION_READY_WAIT_SEC=0 istio_version_resolve "$1" "${2:-0}" _iv_kubectl 2>/dev/null
		local kv
		for kv in ${END-}; do export "${kv?}"; done
		local -a out=()
		istio_version_recheck out _iv_kubectl
		printf '%s\n' ${out[@]+"${out[@]}"}
	)
}

@test "istio_version_recheck: the end-of-sweep read flags a version change, notes what it cannot confirm" {
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
	# A spec change not reconciled yet at the end, on the same version: unconfirmed, a note.
	IV_a=v1.30.5 END="IVOGEN_a=2" run --separate-stderr _iv_recheck a
	assert_line --index 0 -- "--note"
	assert_line --index 1 --partial "unconfirmed: a ran v1.30.5 at the start, and at the end the Istio CR default is not settled: generation 3"
	# Nothing read live (--dry-run): nothing to compare, nothing read.
	: > "$IV_LOG"
	IV_a=v1.30.5 run --separate-stderr _iv_recheck a 1
	assert_output ""
	[ ! -s "$IV_LOG" ]
}

@test "istio_version_recheck: a CR or revision not settled at the end still compares the active revision's version" {
	# A version bump whose Helm upgrade failed partway: ReconcileError on revision v1.30.6.
	IV_a=v1.30.5 END="IV_a=v1.30.6 IVSTATE_a=ReconcileError IVRECON_a=False" run --separate-stderr _iv_recheck a
	assert_success
	assert_line --index 0 -- "--problem"
	assert_line --index 1 "the Istio version changed during the sweep (a: v1.30.5 at the start, v1.30.6 at the end, its active revision's version (the Istio CR default is not settled: its state is ReconcileError, not Healthy, and its Reconciled condition is False)); its rows are not all from ISTIO_VERSION=v1.30.5"
	refute_output --partial unconfirmed
	# The same version under a ReconcileError: unconfirmed, a note (API pressure, say).
	IV_a=v1.30.5 END="IVSTATE_a=ReconcileError IVRECON_a=False" run --separate-stderr _iv_recheck a
	assert_line --index 0 -- "--note"
	assert_line --index 1 --partial "unconfirmed: a ran v1.30.5 at the start, and at the end the Istio CR default is not settled: its state is ReconcileError"
	# A revision whose generation lags (its upgrade not run yet) on another version: a change.
	IV_a=v1.30.5 END="IV_a=v1.30.6 IVROGEN_a=1" run --separate-stderr _iv_recheck a
	assert_line --index 0 -- "--problem"
	assert_line --index 1 --partial "a: v1.30.5 at the start, v1.30.6 at the end, its active revision's version (the IstioRevision default is not settled: generation 2 is not reconciled yet (observedGeneration 1))"
}

@test "istio_version_recheck: an istiod Deployment that cannot be read at the end still compares the active revision's version" {
	# A mid-sweep upgrade still rolling out, whose Deployment cannot be read: a change, exit 4.
	IV_a=v1.30.5 END="IV_a=v1.30.6 IVSTATE_a=IstiodNotReady IVDEP_a=fail" run --separate-stderr _iv_recheck a
	assert_success
	assert_line --index 0 -- "--problem"
	assert_line --index 1 "the Istio version changed during the sweep (a: v1.30.5 at the start, v1.30.6 at the end, its active revision's version (istiod Deployment istio-system/istiod: Error from server (Forbidden): deployments.apps \"istiod\" is forbidden)); its rows are not all from ISTIO_VERSION=v1.30.5"
	refute_output --partial unconfirmed
	local -a args=()
	mapfile -t args < <(IV_a=v1.30.5 END="IV_a=v1.30.6 IVSTATE_a=IstiodNotReady IVDEP_a=fail" _iv_recheck a 2>/dev/null)
	run --separate-stderr sweep_outcome "${args[@]}" 3
	assert_failure 4
	# The same version: unconfirmed, a note; the sweep does not fail.
	IV_a=v1.30.5 END="IVSTATE_a=IstiodNotReady IVDEP_a=fail" run --separate-stderr _iv_recheck a
	assert_output "$(printf '%s\n' --note "the Istio version at the end of the sweep is unconfirmed: a ran v1.30.5 at the start, and its active revision reads v1.30.5 at the end, but istiod Deployment istio-system/istiod: Error from server (Forbidden): deployments.apps \"istiod\" is forbidden")"
	# At the end: Healthy, but the same version still rolling out (old pods serving).
	IV_a=v1.30.5 END="IVDEP_a=5:5:3:2" run --separate-stderr _iv_recheck a
	assert_line --index 3 "not ready at the end: rolling (an istiod rollout in progress, or old istiod pods still terminating) on 1 member (a)"
	refute_output --partial -- "--problem"
}

@test "istio_version_recheck: the same version with istiod/CNI not ready at the end is a note grouped by state, never a version change; the sweep does not exit 4" {
	IV_a=v1.30.5 IV_b=v1.30.5 END="IVSTATE_a=IstioCNINotHealthy" run --separate-stderr _iv_recheck a,b
	assert_success
	assert_line --index 0 -- "--note"
	assert_line --index 1 "istiod or IstioCNI was not ready at the end of the sweep, on the same Istio version: the last cells may have run on a control plane that was not ready; check their status and, where the suite records it, istiod_restarted"
	assert_line --index 2 -- "--note"
	assert_line --index 3 "not ready at the end: IstioCNINotHealthy on 1 member (a)"
	refute_output --partial -- "--problem"
	refute_output --partial "changed"
	refute_output --partial "(istiod or IstioCNI not ready)"
	# One line per state; a rollout of the same version is rolling.
	IV_a=v1.30.5 IV_b=v1.30.5 IV_c=v1.30.5 IV_d=v1.30.5 \
		END="IVSTATE_a=IstioCNINotHealthy IVSTATE_b=IstiodNotReady IVSTATE_c=IstioCNINotHealthy IVSTATE_d=IstiodNotReady IVDEP_d=5:5:3:1" \
		run --separate-stderr _iv_recheck a,b,c,d
	assert_success
	assert_line --index 3 "not ready at the end: IstioCNINotHealthy on 2 members (a, c)"
	assert_line --index 5 "not ready at the end: IstiodNotReady on 1 member (b)"
	assert_line --index 7 "not ready at the end: rolling (an istiod rollout in progress, or old istiod pods still terminating) on 1 member (d)"
	refute_output --partial -- "--problem"
	# Through sweep_outcome: warnings, exit 0.
	local -a args=()
	mapfile -t args < <(IV_a=v1.30.5 END="IVSTATE_a=IstioCNINotHealthy" _iv_recheck a 2>/dev/null)
	run --separate-stderr sweep_outcome "${args[@]}" 3
	assert_success
	assert_output "All 3 cells ran (their rows' own statuses are in the report)."
	[[ "$stderr" == "warning: istiod or IstioCNI was not ready at the end of the sweep, on the same Istio version: "*$'\n'"warning: not ready at the end: IstioCNINotHealthy on 1 member (a)." ]]
	# Another version while not ready, or rolling out another version, is still a change.
	IV_a=v1.30.5 END="IV_a=v1.31.0 IVSTATE_a=IstiodNotReady" run --separate-stderr _iv_recheck a
	assert_line --index 0 -- "--problem"
	assert_line --index 1 --partial "a: v1.30.5 at the start, v1.31.0 at the end"
	IV_a=v1.30.5 END="IV_a=v1.31.0 IVSTATE_a=IstiodNotReady IVDEP_a=5:5:3:1" run --separate-stderr _iv_recheck a
	assert_line --index 0 -- "--problem"
	assert_line --index 1 --partial "a: v1.30.5 at the start, v1.31.0 at the end"
}

@test "a member still not ready after the start's wait is in every preamble (istio_version_kv) and a NOTE in the sweep outcome; a healthy start records none" {
	local d="${BATS_TEST_TMPDIR}/r2"
	mkdir -p "$d"
	# b is not ready at the start (no wait, so it stays that way), and ready at the end.
	(
		unset ISTIO_VERSION_SOURCE ISTIO_VERSION_PIN ISTIO_VERSION_BY_CONTEXT _ISTIO_VERSION_RESOLVED
		unset ISTIO_NOTREADY_AT_START ISTIO_READY_WAITED_SEC
		export ISTIO_VERSION=v1.30.5 IV_a=v1.30.5 IV_b=v1.30.5 IVSTATESEQ_b="IstioCNINotHealthy Healthy" ISTIO_VERSION_READY_WAIT_SEC=0
		istio_version_resolve a,b 0 _iv_kubectl 2>/dev/null
		mapfile -t kv < <(istio_version_kv)
		write_preamble "probe" "${d}/run.tsv" "${kv[@]}"
		local -a out=()
		istio_version_recheck out _iv_kubectl
		sweep_outcome "${out[@]}" --run-id r2-run --record "$d" 2 2>/dev/null
	)
	run grep -x '# ISTIO_NOTREADY_AT_START=b=IstioCNINotHealthy' "${d}/run.tsv"
	assert_success
	run grep -x '# ISTIO_READY_WAITED_SEC=0' "${d}/run.tsv"
	assert_success
	run grep -x '# ISTIO_ACTIVE_REVISIONS=a=default,b=default' "${d}/run.tsv"
	assert_success
	run grep '^NOTE=' "${d}/sweep-outcome.txt"
	assert_line --index 0 "NOTE=istiod or IstioCNI was still not ready at the start of the sweep, after waiting 0s (ISTIO_NOTREADY_AT_START): the first cells may have run on a control plane that was not ready; check their status and, where the suite records it, istiod_restarted"
	assert_line --index 1 "NOTE=not ready at the start: IstioCNINotHealthy on 1 member (b)"
	# b was ready at the end: no end note; the sweep did not fail.
	refute_output --partial "at the end"
	run grep -x 'EXIT=0' "${d}/sweep-outcome.txt"
	assert_success
	# A healthy start: none, and no NOTE.
	rm -f "${d}/run.tsv" "${d}/sweep-outcome.txt"
	(
		unset ISTIO_VERSION_SOURCE ISTIO_VERSION_PIN ISTIO_VERSION_BY_CONTEXT _ISTIO_VERSION_RESOLVED
		unset ISTIO_NOTREADY_AT_START ISTIO_READY_WAITED_SEC
		export ISTIO_VERSION=v1.30.5 IV_a=v1.30.5 IV_b=v1.30.5
		istio_version_resolve a,b 0 _iv_kubectl 2>/dev/null
		mapfile -t kv < <(istio_version_kv)
		write_preamble "probe" "${d}/run.tsv" "${kv[@]}"
		local -a out=()
		istio_version_recheck out _iv_kubectl
		sweep_outcome ${out[@]+"${out[@]}"} --run-id r2-run --record "$d" 2 >/dev/null
	)
	run grep -x '# ISTIO_NOTREADY_AT_START=none' "${d}/run.tsv"
	assert_success
	run grep -c '^NOTE=' "${d}/sweep-outcome.txt"
	assert_output 0
}

# _iv_resume <ctxs_csv> [<dry 0|1>]: resolve as a --resume started at a fixed time (no
# readiness wait), then recheck; print the sweep_outcome arguments it returned.
_iv_resume() {
	(
		unset ISTIO_VERSION_SOURCE ISTIO_VERSION_PIN ISTIO_VERSION_BY_CONTEXT _ISTIO_VERSION_RESOLVED
		unset ISTIO_NOTREADY_AT_START ISTIO_READY_WAITED_SEC
		export ISTIO_VERSION=v1.30.5
		ISTIO_VERSION_READY_WAIT_SEC=0 istio_version_resolve --resumed-at 2026-10-17T10:00:00+00:00 "$1" "${2:-0}" _iv_kubectl
		local -a out=()
		istio_version_recheck out _iv_kubectl
		printf '%s\n' ${out[@]+"${out[@]}"}
	)
}

@test "a --resume records its own start condition and its start time in the sweep outcome, none included" {
	IV_a=v1.30.5 IV_b=v1.30.5 run --separate-stderr _iv_resume a,b
	assert_success
	# An all-clear is an info line (note: on stdout, INFO= in the record), not a warning.
	assert_output "$(printf '%s\n' --info "this --resume started at 2026-10-17T10:00:00+00:00 with every member ready (ISTIO_NOTREADY_AT_RESUME=none, ISTIO_READY_WAITED_SEC=0); the TSV preamble's ISTIO_NOTREADY_AT_START is the first run's (a resume's, when the first run wrote no TSV)")"
	local -a args=()
	mapfile -t args < <(IV_a=v1.30.5 IV_b=v1.30.5 _iv_resume a,b 2>/dev/null)
	run --separate-stderr sweep_outcome "${args[@]}" --record "$BATS_TEST_TMPDIR" 3
	assert_success
	assert_line --index 1 "note: this --resume started at 2026-10-17T10:00:00+00:00 with every member ready (ISTIO_NOTREADY_AT_RESUME=none, ISTIO_READY_WAITED_SEC=0); the TSV preamble's ISTIO_NOTREADY_AT_START is the first run's (a resume's, when the first run wrote no TSV)."
	[ -z "$stderr" ]
	grep -q '^INFO=this --resume started at 2026-10-17T10:00:00+00:00 with every member ready' "${BATS_TEST_TMPDIR}/sweep-outcome.txt"
	[ "$(grep -c '^NOTE=' "${BATS_TEST_TMPDIR}/sweep-outcome.txt" || true)" = 0 ]
	# b not ready when the resume starts, ready at its end: the resume's own rows, by time.
	rm -f "${BATS_TEST_TMPDIR}"/n-* "${BATS_TEST_TMPDIR}"/dn-*
	IV_a=v1.30.5 IV_b=v1.30.5 IVSTATESEQ_b="IstioCNINotHealthy Healthy" run --separate-stderr _iv_resume a,b
	assert_success
	assert_line --index 0 -- "--note"
	assert_line --index 1 "istiod or IstioCNI was still not ready when this --resume started at 2026-10-17T10:00:00+00:00, after waiting 0s (ISTIO_NOTREADY_AT_RESUME=b=IstioCNINotHealthy; the TSV preamble's ISTIO_NOTREADY_AT_START is the first run's (a resume's, when the first run wrote no TSV)): the first cells the resume ran (rows from 2026-10-17T10:00:00+00:00 on) may have run on a control plane that was not ready; check their status and, where the suite records it, istiod_restarted"
	assert_line --index 3 "not ready at the resume: IstioCNINotHealthy on 1 member (b)"
	refute_output --partial "at the start of the sweep"
	# Its warning says where the condition is recorded on a resume.
	[[ "$stderr" == *"This --resume records them in sweep-outcome.txt as ISTIO_NOTREADY_AT_RESUME, with its start time (2026-10-17T10:00:00+00:00); the TSV preamble keeps the first run's ISTIO_NOTREADY_AT_START."* ]]
	[[ "$stderr" != *"the preambles record"* ]]
	# --dry-run reads nothing and notes nothing.
	: > "$IV_LOG"
	IV_a=v1.30.5 run --separate-stderr _iv_resume a 1
	assert_output ""
	[ ! -s "$IV_LOG" ]
}

@test "an Istio CR not settled whose IstioRevision read fails is a failed read naming the revision: retried, then an honest note" {
	IV_a=v1.30.5 IVSTATE_a=ReconcileError IVRFAIL_a=1 run istio_live_version a _iv_kubectl
	assert_output "$(printf 'unknown\nread\nthe Istio CR default is not settled: its state is ReconcileError, not Healthy, and its Reconciled condition is False; IstioRevision default: Unable to connect to the server: net/http: TLS handshake timeout\ndefault\n\nReconcileError')"
	# A migration stays migrating (a problem whatever the revision reads), and says so too.
	rm -f "${BATS_TEST_TMPDIR}"/rn-*
	IV_a=v1.30.5 IVINUSE_a=2 IVRFAIL_a=1 run istio_live_version a _iv_kubectl
	assert_line --index 1 migrating
	assert_line --index 2 --partial "2 revisions are in use (a revision migration in progress); IstioRevision default: Unable to connect"
	# At the start the failed read is retried once, like any failed read.
	rm -f "${BATS_TEST_TMPDIR}"/rn-*
	: > "$IV_LOG"
	ISTIO_VERSION_CHECK=warn IV_a=v1.30.5 IVSTATE_a=ReconcileError IVRFAIL_a=1 run --separate-stderr _iv_run a 0
	assert_output "V=unknown PIN=v1.30.5 SRC=live BY=a=unknown"
	[ "$(grep -c 'get istiorevisions.sailoperator.io default' "$IV_LOG")" -eq 2 ]
	[[ "$stderr" == *"  a: the Istio CR default is not settled: its state is ReconcileError, not Healthy, and its Reconciled condition is False"$'\n'"    reproduce: _iv_kubectl --context a get istios.sailoperator.io default -o yaml"$'\n'* ]]
	# Failing twice, its command reproduces the read that failed, the IstioRevision's.
	rm -f "${BATS_TEST_TMPDIR}"/rn-*
	ISTIO_VERSION_CHECK=warn IV_a=v1.30.5 IVSTATE_a=ReconcileError IVRFAIL_a=2 run --separate-stderr _iv_run a 0
	[[ "$stderr" == *"  a: the Istio CR default is not settled: its state is ReconcileError, not Healthy, and its Reconciled condition is False; IstioRevision default: Unable to connect to the server: net/http: TLS handshake timeout"$'\n'"    reproduce: _iv_kubectl --context a get istiorevisions.sailoperator.io default -o yaml"$'\n'* ]]
	# End of a sweep: an upgrade to v1.30.6 that failed partway (ReconcileError), its
	# revision read failing once: retried, so the version change is a problem (exit 4).
	rm -f "${BATS_TEST_TMPDIR}"/rn-*
	IV_a=v1.30.5 END="IV_a=v1.30.6 IVSTATE_a=ReconcileError IVRFAIL_a=1" run --separate-stderr _iv_recheck a
	assert_line --index 0 -- "--problem"
	assert_line --index 1 --partial "(a: v1.30.5 at the start, v1.30.6 at the end, its active revision's version (the Istio CR default is not settled"
	# Failing twice: unconfirmed, and the note says the revision was not read.
	rm -f "${BATS_TEST_TMPDIR}"/rn-*
	IV_a=v1.30.5 END="IV_a=v1.30.6 IVSTATE_a=ReconcileError IVRFAIL_a=2" run --separate-stderr _iv_recheck a
	assert_output "$(printf '%s\n' --note "the Istio version at the end of the sweep is unconfirmed: a could not be read again (v1.30.5 at the start): the Istio CR default is not settled: its state is ReconcileError, not Healthy, and its Reconciled condition is False; IstioRevision default: Unable to connect to the server: net/http: TLS handshake timeout")"
	# In the start's wait, a CR that answers "not settled" is an answer, also when its
	# revision read then fails: unknown at the deadline (fail stops), never the not-ready
	# member's earlier version.
	rm -f "${BATS_TEST_TMPDIR}"/n-* "${BATS_TEST_TMPDIR}"/dn-* "${BATS_TEST_TMPDIR}"/rf-*
	IV_a=v1.30.5 IVSTATESEQ_a="IstiodNotReady ReconcileError" IVRFAILFROM_a=2 \
		ISTIO_VERSION_READY_WAIT_SEC=2 ISTIO_VERSION_READY_POLL_SEC=1 run --separate-stderr _iv_run a 0
	assert_failure 1
	[[ "$stderr" == *"  a: the Istio CR default is not settled: its state is ReconcileError, not Healthy, and its Reconciled condition is False; IstioRevision default: Unable to connect to the server: net/http: TLS handshake timeout"$'\n'* ]]
	[[ "$stderr" != *"WARNING: istiod or IstioCNI is still not ready"* ]]
}

@test "a rollout that ends on the last read before the deadline gets its extra read, one poll past the deadline" {
	# POLL = WAIT: the first poll is before the deadline, the second at it, whatever the clock.
	IV_a=v1.30.5 IVDEPSEQ_a="5:5:3:2 5:5:2:2" IV_SHOW_NR=1 \
		ISTIO_VERSION_READY_WAIT_SEC=2 ISTIO_VERSION_READY_POLL_SEC=2 run --separate-stderr _iv_run a 0
	assert_success
	assert_line --index 0 "V=v1.30.5 PIN=v1.30.5 SRC=live BY=a=v1.30.5"
	assert_line --index 1 --regexp '^NR=none WAITED=[3-8]$'
	[ "$(grep -c 'get deployments.apps istiod ' "$IV_LOG")" -eq 3 ]
	# The extra read sees a new rollout: rolling (unknown), not the version.
	rm -f "${BATS_TEST_TMPDIR}"/n-* "${BATS_TEST_TMPDIR}"/dn-*
	: > "$IV_LOG"
	ISTIO_VERSION_CHECK=warn IV_a=v1.30.5 IVDEPSEQ_a="5:5:3:2 5:5:2:2 6:5:2:2" IV_SHOW_NR=1 \
		ISTIO_VERSION_READY_WAIT_SEC=2 ISTIO_VERSION_READY_POLL_SEC=2 run --separate-stderr _iv_run a 0
	assert_line --index 0 "V=unknown PIN=v1.30.5 SRC=live BY=a=unknown"
	assert_line --index 1 --regexp '^NR=a=rolling WAITED=[3-8]$'
	[ "$(grep -c 'get deployments.apps istiod ' "$IV_LOG")" -eq 3 ]
}

@test "a member off an ISTIO_VERSION exported in the shell, next to an unknown one: unset it, not bump versions.env" {
	PIN=1.24.0 IV_a=v1.30.5 run --separate-stderr _iv_run a,b 0
	assert_failure 1
	[[ "$stderr" == *"Also, a runs v1.30.5, not ISTIO_VERSION=1.24.0, which is exported in this shell (config/versions.env pins v1.30.5): unset ISTIO_VERSION (a value left in the shell, for example by Istio's download script)."* ]]
	[[ "$stderr" != *"bump ISTIO_VERSION in config/versions.env"* ]]
}

@test "rolling members are grouped by Deployment and version at the start; at the end, members whose Deployment alone cannot be read are grouped by why" {
	ISTIO_VERSION_CHECK=warn PIN=v1.30.6 IV_a=v1.30.6 IV_b=v1.30.6 IV_c=v1.30.6 IV_d=v1.30.6 IVREV_d=default-v1-30-6 \
		IVDEP_a="5 5 3 1" IVDEP_b="5 5 3 2" IVDEP_c="6 5 2 2" IVDEP_d="5 5 3 1" IV_SHOW_NR=1 \
		ISTIO_VERSION_READY_WAIT_SEC=0 run --separate-stderr _iv_run a,b,c,d 0
	assert_success
	assert_line --index 1 "NR=a=rolling,b=rolling,c=rolling,d=rolling WAITED=0"
	[[ "$stderr" == *"cannot confirm the running Istio version on 4 of 4 members:"$'\n'"  istiod is rolling out v1.30.6 on 3 members (Deployment istio-system/istiod; still rolling out after 0s): a, b, c"$'\n'"    check (shown for a): _iv_kubectl --context a -n istio-system get deployments.apps istiod -o yaml"$'\n'"  d: istiod is rolling out v1.30.6 (Deployment istio-system/istiod-default-v1-30-6: 1 of 3 pods updated); its state is Healthy; still rolling out after 0s"$'\n'"    check: _iv_kubectl --context d -n istio-system get deployments.apps istiod-default-v1-30-6 -o yaml"$'\n'"Wait until"* ]]
	# A rollout seen at the first read, then no answer, is recorded as unreadable.
	local -a o=()
	_istio_notready_notes o start "a=unreadable,b=IstioCNINotHealthy" 2
	[ "${o[3]}" = "not ready at the start: unreadable (an istiod rollout at the first read, then every re-read failed) on 1 member (a)" ]
	# End: every Deployment read fails (RBAC, say) on the same version: one entry.
	IV_a=v1.30.5 IV_b=v1.30.5 IV_c=v1.30.5 END="IVDEP_a=fail IVDEP_b=fail IVDEP_c=fail" run --separate-stderr _iv_recheck a,b,c
	assert_output "$(printf '%s\n' --note "the Istio version at the end of the sweep is unconfirmed: a, b, c ran v1.30.5 at the start, and their active revisions read v1.30.5 at the end, but istiod Deployment istio-system/istiod: Error from server (Forbidden): deployments.apps \"istiod\" is forbidden")"
}

@test "istiod pods still terminating (.status.terminatingReplicas, where the server has it) are a rollout in progress" {
	IV_a=v1.30.6 IVDEP_a="5 5 2 2 1" run istio_live_version a _iv_kubectl
	assert_output "$(printf 'v1.30.6\nrolling\nistiod pods still terminating after the rollout to v1.30.6 (Deployment istio-system/istiod: 2 of 2 pods updated, 1 terminating); its state is Healthy\ndefault\nv1.30.6\nHealthy')"
	IV_a=v1.30.6 IVDEP_a="5 5 2 2 0" run istio_live_version a _iv_kubectl
	assert_line --index 1 ok
	IV_a=v1.30.6 IVDEP_a="5 5 3 2 1" run istio_live_version a _iv_kubectl
	assert_line --index 2 "istiod is rolling out v1.30.6 (Deployment istio-system/istiod: 2 of 3 pods updated, 1 terminating); its state is Healthy"
	# At the start, old pods still terminating are named so, checked through the istiod
	# pods, and are not a rollout to wait out; the member runs that version (the Also clause).
	ISTIO_VERSION_CHECK=warn IV_a=v1.30.6 IVDEP_a="5 5 2 2 1" ISTIO_VERSION_READY_WAIT_SEC=0 run --separate-stderr _iv_run a 0
	[[ "$stderr" == *"cannot confirm the running Istio version on 1 of 1 members:"$'\n'"  a: istiod pods still terminating after the rollout to v1.30.6 (Deployment istio-system/istiod: 2 of 2 pods updated, 1 terminating); its state is Healthy; still terminating after 0s"$'\n'"    check: _iv_kubectl --context a -n istio-system get pods -l app=istiod,istio.io/rev=default"$'\n'"Wait until their old istiod pods are gone (a pod stuck in Terminating, on a lost node say, needs a force delete) (or raise ISTIO_VERSION_READY_WAIT_SEC). Also, a runs v1.30.6, not the pin v1.30.5: "* ]]
	[[ "$stderr" != *"rolling out"* ]]
	# With a member still rolling out, both are said, each in its own group.
	ISTIO_VERSION_CHECK=warn IV_a=v1.30.6 IVDEP_a="5 5 2 2 1" IV_b=v1.30.6 IVDEP_b="5 5 3 1" IV_c=v1.30.6 IVDEP_c="5 5 2 2 1" \
		ISTIO_VERSION_READY_WAIT_SEC=0 run --separate-stderr _iv_run a,b,c 0
	[[ "$stderr" == *$'\n'"  istiod pods still terminating after the rollout to v1.30.6 on 2 members (Deployment istio-system/istiod; still terminating after 0s): a, c"$'\n'"    check (shown for a): _iv_kubectl --context a -n istio-system get pods -l app=istiod,istio.io/rev=default"$'\n'* ]]
	[[ "$stderr" == *$'\n'"  b: istiod is rolling out v1.30.6 (Deployment istio-system/istiod: 1 of 3 pods updated); its state is Healthy; still rolling out after 0s"$'\n'* ]]
	[[ "$stderr" == *$'\n'"Wait until their istiod rollout is complete and their old istiod pods are gone (or raise ISTIO_VERSION_READY_WAIT_SEC). Also, a, c run v1.30.6; b is rolling out v1.30.6, not the pin v1.30.5: "* ]]
	# A revision-based Deployment (istiod-<rev>): its pods carry istio.io/rev=<rev>.
	ISTIO_VERSION_CHECK=warn IV_a=v1.30.6 IVREV_a=default-v1-30-6 IVDEP_a="5 5 2 2 1" ISTIO_VERSION_READY_WAIT_SEC=0 run --separate-stderr _iv_run a 0
	[[ "$stderr" == *$'\n'"    check: _iv_kubectl --context a -n istio-system get pods -l app=istiod,istio.io/rev=default-v1-30-6"$'\n'* ]]
	# At the end, rolling also covers old pods still terminating.
	IV_a=v1.30.5 END="IVDEP_a=5:5:2:2:1" run --separate-stderr _iv_recheck a
	assert_line --index 3 "not ready at the end: rolling (an istiod rollout in progress, or old istiod pods still terminating) on 1 member (a)"
}

@test "a settled Istio CR whose IstioRevision read fails names that read, once, and reproduces it" {
	IV_a=v1.30.5 IVRFAIL_a=1 run istio_live_version a _iv_kubectl
	assert_output "$(printf 'unknown\nread\nIstioRevision default: Unable to connect to the server: net/http: TLS handshake timeout\ndefault\n\nHealthy')"
	rm -f "${BATS_TEST_TMPDIR}"/rn-*
	ISTIO_VERSION_CHECK=warn IV_a=v1.30.5 IVRFAIL_a=2 run --separate-stderr _iv_run a 0
	[[ "$stderr" == *$'\n'"  a: IstioRevision default: Unable to connect to the server: net/http: TLS handshake timeout"$'\n'"    reproduce: _iv_kubectl --context a get istiorevisions.sailoperator.io default -o yaml"$'\n'* ]]
	# The CR is settled, so there is nothing to wait for: the fix is access.
	[[ "$stderr" == *$'\n'"Fix access to those members (kubeconfig, login, network) and to their IstioRevision (their Istio CR is settled); the pin is not the problem."$'\n'* ]]
	[[ "$stderr" != *"wait until their Istio CR is settled"* ]]
	# A CR that is not settled still gets the wait.
	rm -f "${BATS_TEST_TMPDIR}"/rn-*
	ISTIO_VERSION_CHECK=warn IV_a=v1.30.5 IVRFAIL_a=2 IV_b=v1.30.5 IVSTATE_b=ReconcileError run --separate-stderr _iv_run a,b 0
	[[ "$stderr" == *$'\n'"Fix access to those members (kubeconfig, login, network), or wait until their Istio CR is settled; the pin is not the problem."$'\n'* ]]
	# An answer that is not JSON: the revision is named once, settled or not.
	_iv_nojson() { case " $* " in *" get istiorevisions.sailoperator.io "*) echo "<html>" ;; *) _iv_kubectl "$@" ;; esac; }
	IV_a=v1.30.5 run istio_live_version a _iv_nojson
	assert_line --index 2 "IstioRevision default: the read did not return JSON"
	IV_a=v1.30.5 IVSTATE_a=ReconcileError run istio_live_version a _iv_nojson
	assert_line --index 2 "the Istio CR default is not settled: its state is ReconcileError, not Healthy, and its Reconciled condition is False; IstioRevision default: the read did not return JSON"
}

@test "at 20 members, the start's failed reads, the end's notes and the off-pin clause are one entry per why or version" {
	local c ctxs=""
	for c in $(seq 1 20); do
		ctxs+="${ctxs:+,}c${c}"
		export "IV_c${c}=v1.30.5" "IVSTATE_c${c}=ReconcileError" "IVRFAIL_c${c}=9"
	done
	ISTIO_VERSION_CHECK=warn run --separate-stderr _iv_run "$ctxs" 0
	[[ "$stderr" == *"cannot read the running Istio version on 20 of 20 members:"$'\n'"  c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15, c16, c17, c18, c19, c20 (20 members): the Istio CR default is not settled: its state is ReconcileError, not Healthy, and its Reconciled condition is False; IstioRevision default: Unable to connect to the server: net/http: TLS handshake timeout"$'\n'"    reproduce (shown for c1): _iv_kubectl --context c1 get istiorevisions.sailoperator.io default -o yaml"$'\n'"Fix access"* ]]
	[ "$(grep -c '' <<<"$stderr")" -eq 5 ]
	# End: every member not settled, their revision reads failing, then only not settled.
	local -a o=()
	_ivl6_end() {
		export ISTIO_VERSION_SOURCE=live ISTIO_VERSION=v1.30.5 _ISTIO_VERSION_REVS="" ISTIO_NOTREADY_AT_START=none
		ISTIO_VERSION_BY_CONTEXT="$(sed 's/\(c[0-9]*\)/\1=v1.30.5/g' <<<"$ctxs")"
		export ISTIO_VERSION_BY_CONTEXT
		istio_version_recheck o _iv_kubectl
	}
	rm -f "${BATS_TEST_TMPDIR}"/rn-*
	_ivl6_end
	[ "${#o[@]}" -eq 2 ]
	[ "${o[1]}" = "the Istio version at the end of the sweep is unconfirmed: c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15, c16, c17, c18, c19, c20 could not be read again (v1.30.5 at the start): the Istio CR default is not settled: its state is ReconcileError, not Healthy, and its Reconciled condition is False; IstioRevision default: Unable to connect to the server: net/http: TLS handshake timeout" ]
	for c in $(seq 1 20); do unset "IVRFAIL_c${c}"; done
	_ivl6_end
	[ "${o[1]}" = "the Istio version at the end of the sweep is unconfirmed: c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15, c16, c17, c18, c19, c20 ran v1.30.5 at the start, and at the end the Istio CR default is not settled: its state is ReconcileError, not Healthy, and its Reconciled condition is False" ]
	# Two whys: two entries, in the order the members are listed.
	export IVSTATE_c3=Healthy IVROGEN_c3=1 IVSTATE_c4=Healthy IVROGEN_c4=1
	_ivl6_end
	[[ "${o[1]}" == *": c1, c2, c5, "*" ran v1.30.5 at the start, and at the end the Istio CR default is not settled: its state is ReconcileError, not Healthy, and its Reconciled condition is False; c3, c4 ran v1.30.5 at the start, and at the end the IstioRevision default is not settled: generation 2 is not reconciled yet (observedGeneration 1)" ]]
}

@test "members off the pin are grouped by version in the Also clause" {
	ISTIO_VERSION_CHECK=warn IV_a=v1.30.6 IVDEP_a="5 5 3 1" IV_b=v1.30.6 IVDEP_b="5 5 3 1" IV_c=v1.30.6 IV_d=v1.30.7 IV_e=v1.30.6 \
		ISTIO_VERSION_READY_WAIT_SEC=0 run --separate-stderr _iv_run a,b,c,d,e 0
	[[ "$stderr" == *"Also, a, b are rolling out v1.30.6; c, e run v1.30.6; d runs v1.30.7, not the pin v1.30.5: bump ISTIO_VERSION"* ]]
}

# _iv_compat51: true when `BASH_COMPAT=51 bash` expands an associative array's subscript a
# second time in arithmetic, as bash 4.3 to 5.1 do: a 5.2+ bash that emulates it, or
# an older bash.
_iv_compat51() {
	! BASH_COMPAT=51 bash -c 'declare -A a=(); k="x'"'"'y"; a[$k]=1; : $((a[$k] + 1))' 2>/dev/null
}

# _iv_m1_stub: a kubectl in BATS_TEST_TMPDIR. Members in STUB_FAIL fail every read with the
# first stderr line kubectl prints there: a, a klog line (unreachable); b, a member without
# the Sail CRDs. Every other member answers through fake-istio-cr.sh (v1.30.5, settled).
_iv_m1_stub() {
	cat > "${BATS_TEST_TMPDIR}/kubectl" <<'STUB'
#!/usr/bin/env bash
ctx=""
for a in "$@"; do case "$a" in --context=*) ctx="${a#--context=}" ;; esac; done
case ",${STUB_FAIL:-}," in
*",${ctx},"*)
	case "$ctx" in
	a) echo 'E1017 10:00:00.000000   12345 memcache.go:265] couldn'"'"'t get current server API group list: Get "https://<api-host>:6443/api?timeout=5s": dial tcp: i/o timeout' >&2 ;;
	*) echo 'error: the server doesn'"'"'t have a resource type "istios"' >&2 ;;
	esac
	exit 1
	;;
esac
exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@"
STUB
	chmod +x "${BATS_TEST_TMPDIR}/kubectl"
	cat > "${BATS_TEST_TMPDIR}/drive.sh" <<'DRIVE'
set -euo pipefail
source "$ROOT/tests/lib/common.sh"
source "$ROOT/tests/lib/preamble.sh"
export ISTIO_VERSION=v1.30.5 ISTIO_VERSION_READY_WAIT_SEC=0
STUB_FAIL="${START_FAIL:-}" istio_version_resolve "$1" 0 "${BATS_TEST_TMPDIR}/kubectl"
echo "V=${ISTIO_VERSION} BY=${ISTIO_VERSION_BY_CONTEXT}"
IV=()
STUB_FAIL="${END_FAIL:-}" istio_version_recheck IV "${BATS_TEST_TMPDIR}/kubectl"
printf 'END %s\n' ${IV[@]+"${IV[@]}"}
DRIVE
}

@test "kubectl stderr with a quote or a klog ] never aborts the version check under bash 5.1 subscripts, at the start or the end" {
	_iv_compat51 || skip "this bash cannot emulate bash 5.1's second expansion of array subscripts (BASH_COMPAT=51)"
	_iv_m1_stub
	# Start, fail: both members are listed (grouped apart: their whys differ; no klog
	# prefix), and the run stops; never the pin with exit 0.
	START_FAIL=a,b BASH_COMPAT=51 run --separate-stderr bash "${BATS_TEST_TMPDIR}/drive.sh" a,b,c
	assert_failure 1
	assert_output ""
	[[ "$stderr" == *"cannot read the running Istio version on 2 of 3 members:"$'\n'"  a: couldn't get current server API group list: Get \"https://<api-host>:6443/api?timeout=5s\": dial tcp: i/o timeout"$'\n'* ]]
	[[ "$stderr" == *$'\n'"  b: error: the server doesn't have a resource type \"istios\""$'\n'* ]]
	[[ "$stderr" != *"bad array subscript"* && "$stderr" != *"syntax error"* ]]
	# Start, warn: recorded as read (unknown for a and b), and the end goes on.
	ISTIO_VERSION_CHECK=warn START_FAIL=a,b BASH_COMPAT=51 run --separate-stderr bash "${BATS_TEST_TMPDIR}/drive.sh" a,b,c
	assert_success
	assert_line --index 0 "V=mixed:unknown/v1.30.5 BY=a=unknown,b=unknown,c=v1.30.5"
	[[ "$stderr" != *"bad array subscript"* && "$stderr" != *"syntax error"* ]]
	# End: every member read at the start, a and b fail at the end: one note, never silence.
	END_FAIL=a,b BASH_COMPAT=51 run --separate-stderr bash "${BATS_TEST_TMPDIR}/drive.sh" a,b,c
	assert_success
	assert_line --index 0 "V=v1.30.5 BY=a=v1.30.5,b=v1.30.5,c=v1.30.5"
	assert_line --index 1 "END --note"
	assert_line --index 2 "END the Istio version at the end of the sweep is unconfirmed: a, b could not be read again (v1.30.5 at the start)"
	[[ "$stderr" != *"bad array subscript"* && "$stderr" != *"syntax error"* ]]
}

@test "a version check that stops unexpectedly fails closed: under fail the run stops, under warn it records unknown, at the end a problem" {
	# Stands for any error that ends the check early (an unexpected exit, or bash aborting
	# on a bad array subscript).
	_istio_version_read_all() { exit 3; }
	IV_a=v1.30.5 run --separate-stderr _iv_run a,b 0
	assert_failure 1
	assert_output ""
	[[ "$stderr" == *"error: the Istio version check stopped unexpectedly (exit 3; the error is above), so the version the members run is not known."$'\n'"Nothing was changed. To go on anyway and record ISTIO_VERSION=unknown, set ISTIO_VERSION_CHECK=warn."* ]]
	ISTIO_VERSION_CHECK=warn IV_a=v1.30.5 IV_SHOW_NR=1 run --separate-stderr _iv_run a,b 0
	assert_success
	assert_line --index 0 "V=unknown PIN=v1.30.5 SRC=live BY=a=unknown,b=unknown"
	assert_line --index 1 "NR=unchecked WAITED=unchecked"
	[[ "$stderr" == *"Going on (ISTIO_VERSION_CHECK=warn): the results record ISTIO_VERSION=unknown (ISTIO_VERSION_PIN=v1.30.5)."* ]]
	IV_a=v1.30.5 run --separate-stderr _iv_run a 0 --no-stop
	assert_success
	[[ "$stderr" == *"Going on (a read-only check never stops on this)"* ]]
	# A stop the check decides (fail, a member unreadable) is its own message, not this one.
	source "$ROOT/tests/lib/preamble.sh"
	run --separate-stderr _iv_run b 0
	assert_failure 1
	[[ "$stderr" == *"cannot read the running Istio version on 1 of 1 members:"* ]]
	[[ "$stderr" != *"stopped unexpectedly"* ]]
	# End: the recheck stops unexpectedly.
	_istio_version_recheck_live() { exit 3; }
	IV_a=v1.30.5 run --separate-stderr _iv_recheck a
	assert_success
	assert_output "$(printf '%s\n' --problem "the end-of-sweep Istio version check failed: it stopped unexpectedly (exit 3; its error is in the sweep's stderr), so whether the Istio version or the active revision changed during the sweep is not known; check each member by hand: kubectl --context <ctx> get istios.sailoperator.io default -o jsonpath='{.status.activeRevisionName}', then kubectl --context <ctx> get istiorevisions.sailoperator.io <that revision> -o jsonpath='{.spec.version}'")"
}

# _iv_hostdep: _iv_kubectl, except that with HOSTDEP set, each member's istiod Deployment
# read fails on its own API host (a DNS failure names it).
_iv_hostdep() {
	local a ctx=""
	for a in "$@"; do [[ "$a" == --context=* ]] && ctx="${a#--context=}"; done
	if [[ -n "${HOSTDEP:-}" && " $* " == *" get deployments.apps "* ]]; then
		case "$HOSTDEP" in
		refused) echo "The connection to the server api.${ctx}.example:6443 was refused - did you specify the right host or port?" >&2 ;;
		ip6) echo "Unable to connect to the server: dial tcp [2001:db8::${#ctx}]:6443: connect: connection refused" >&2 ;;
		ctx) echo "error: context \"${ctx}\" does not exist" >&2 ;;
		ctx2) echo "Error in configuration: context was not found for specified context: ${ctx}" >&2 ;;
		long) printf 'E1017 10:00:00.000000   %d memcache.go:265] "Unhandled Error" err="Get \\"https://api.%s.example:6443/api?timeout=32s\\": dial tcp: lookup api.%s.example on 192.0.2.53:53: no such host" logger="UnhandledError" %s\n' \
			"$$" "$ctx" "$ctx" "$(printf 'tail%.0s' {1..40})" >&2 ;;
		*) echo "Unable to connect to the server: dial tcp: lookup api.${ctx}.example: no such host" >&2 ;;
		esac
		return 1
	fi
	_iv_kubectl "$@"
}

@test "members failing alike on their own API hosts are one entry, at the start and the end; a settled CR whose istiod Deployment read fails is not waited for" {
	if (
		unset ISTIO_VERSION_SOURCE ISTIO_VERSION_PIN ISTIO_VERSION_BY_CONTEXT _ISTIO_VERSION_RESOLVED
		export ISTIO_VERSION=v1.30.5 IV_a=v1.30.5 IV_b=v1.30.5 IV_c=v1.30.5 HOSTDEP=1
		istio_version_resolve a,b,c 0 _iv_hostdep
	) 2> "${BATS_TEST_TMPDIR}/start.err"; then
		echo "expected the version check to stop the run" >&2
		false
	fi
	run cat "${BATS_TEST_TMPDIR}/start.err"
	# The why is recorded masked, so members on their own API hosts read alike.
	assert_output --partial "cannot read the running Istio version on 3 of 3 members:"$'\n'"  a, b, c (3 members): istiod Deployment istio-system/istiod: Unable to connect to the server: dial tcp: lookup <api-host>: no such host"$'\n'"    reproduce (shown for a): _iv_hostdep --context a -n istio-system get deployments.apps istiod -o yaml"
	assert_output --partial $'\n'"Fix access to those members (kubeconfig, login, network) and to their istiod Deployment (their Istio CR is settled); the pin is not the problem."
	refute_output --partial "wait until their Istio CR is settled"
	# The same why on every member keeps the plain form.
	if (
		unset ISTIO_VERSION_SOURCE ISTIO_VERSION_PIN ISTIO_VERSION_BY_CONTEXT _ISTIO_VERSION_RESOLVED
		export ISTIO_VERSION=v1.30.5 IV_a=v1.30.5 IV_b=v1.30.5 IVDEP_a=fail IVDEP_b=fail
		istio_version_resolve a,b 0 _iv_kubectl
	) 2> "${BATS_TEST_TMPDIR}/start2.err"; then
		echo "expected the version check to stop the run" >&2
		false
	fi
	run cat "${BATS_TEST_TMPDIR}/start2.err"
	assert_output --partial $'\n'"  a, b (2 members): istiod Deployment istio-system/istiod: Error from server (Forbidden): deployments.apps \"istiod\" is forbidden"$'\n'
	# End: read at the start, then each member's Deployment read fails on its own host.
	_n4_end() {
		unset ISTIO_VERSION_SOURCE ISTIO_VERSION_PIN ISTIO_VERSION_BY_CONTEXT _ISTIO_VERSION_RESOLVED
		export ISTIO_VERSION=v1.30.5 IV_a=v1.30.5 IV_b=v1.30.5 IV_c=v1.30.5
		istio_version_resolve a,b,c 0 _iv_hostdep 2>/dev/null
		export HOSTDEP=1
		local -a out=()
		istio_version_recheck out _iv_hostdep
		printf '%s\n' "${out[@]}"
	}
	run --separate-stderr _n4_end
	assert_success
	assert_output "$(printf '%s\n' --note "the Istio version at the end of the sweep is unconfirmed: a, b, c ran v1.30.5 at the start, and their active revisions read v1.30.5 at the end, but istiod Deployment istio-system/istiod: Unable to connect to the server: dial tcp: lookup <api-host>: no such host")"
}

@test "members unknown at the start are grouped by the version they read at the end" {
	_n5_end() {
		unset ISTIO_VERSION_SOURCE ISTIO_VERSION_PIN ISTIO_VERSION_BY_CONTEXT _ISTIO_VERSION_RESOLVED
		export ISTIO_VERSION=v1.30.5 IV_d=v1.30.5 ISTIO_VERSION_CHECK=warn
		istio_version_resolve a,b,c,d 0 _iv_kubectl 2>/dev/null
		export IV_a=v1.30.5 IV_b=v1.30.6 IV_c=v1.30.5
		local -a out=()
		istio_version_recheck out _iv_kubectl
		printf '%s\n' "${out[@]}"
	}
	run --separate-stderr _n5_end
	assert_success
	assert_output "$(printf '%s\n' --note "the Istio version at the end of the sweep is unconfirmed: a, c were unknown at the start and read v1.30.5 at the end; b was unknown at the start and reads v1.30.6 at the end")"
}

@test "refused, IPv6, missing-context and long klog errors group across members whose names differ in length" {
	local mode
	for mode in refused ip6 ctx ctx2 long; do
		if (
			unset ISTIO_VERSION_SOURCE ISTIO_VERSION_PIN ISTIO_VERSION_BY_CONTEXT _ISTIO_VERSION_RESOLVED
			export ISTIO_VERSION=v1.30.5 IV_a=v1.30.5 IV_bbbb=v1.30.5 IV_cccccccccccccccc=v1.30.5 HOSTDEP="$mode"
			istio_version_resolve a,bbbb,cccccccccccccccc 0 _iv_hostdep
		) 2> "${BATS_TEST_TMPDIR}/${mode}.err"; then
			echo "expected the version check to stop the run" >&2
			false
		fi
		run cat "${BATS_TEST_TMPDIR}/${mode}.err"
		# Hosts are masked in the why itself; only a context name still differs.
		case "$mode" in
		ctx | ctx2) assert_output --partial $'\n'"  a, bbbb, cccccccccccccccc (3 members; shown for a, the others name their own contexts): istiod Deployment istio-system/istiod: " ;;
		*) assert_output --partial $'\n'"  a, bbbb, cccccccccccccccc (3 members): istiod Deployment istio-system/istiod: " ;;
		esac
		refute_output --partial "  bbbb: "
		refute_output --partial "  cccccccccccccccc: "
		refute_output --partial ".example"
	done
	# The long line is recorded masked, then cut.
	run cat "${BATS_TEST_TMPDIR}/long.err"
	assert_output --partial '"Unhandled Error" err="Get \"https://<api-host>:6443/api?timeout=32s\": dial tcp: lookup <api-host> on <ip>: no such host" logger="UnhandledError" tailtail'
}

@test "a --resume is never told to set warn, nor that it goes on, for an unknown version; a check that stops partway leaves no temp files" {
	local tmpd="${BATS_TEST_TMPDIR}/tmpd"
	mkdir -p "$tmpd"
	# A member that cannot be read, under fail, at a --resume: warn would not help.
	IV_a=v1.30.5 run --separate-stderr _iv_run a,b 0 --resumed-at 2026-01-01T00:00:00+00:00
	assert_failure 1
	[[ "$stderr" == *$'\n'"Nothing was changed. A --resume never goes on with an unknown version (ISTIO_VERSION_CHECK=warn would not help): once every member can be read, run the same --resume again."* ]]
	[[ "$stderr" != *"set ISTIO_VERSION_CHECK=warn"* ]]
	# A version off the pin at a --resume keeps the advice: a sweep that recorded that
	# version resumes under warn.
	IV_a=v1.30.6 run --separate-stderr _iv_run a 0 --resumed-at 2026-01-01T00:00:00+00:00
	assert_failure 1
	[[ "$stderr" == *"To go on anyway and record ISTIO_VERSION=v1.30.6, set ISTIO_VERSION_CHECK=warn."* ]]
	# Under warn, a --resume with an unknown version is not told "Going on" just before
	# 003 refuses it; a new run still is.
	ISTIO_VERSION_CHECK=warn IV_a=v1.30.5 run --separate-stderr _iv_run a,b 0 --resumed-at 2026-01-01T00:00:00+00:00
	assert_success
	[[ "$stderr" == *"warning: cannot read the running Istio version on 1 of 2 members:"* ]]
	[[ "$stderr" != *"Going on"* ]]
	ISTIO_VERSION_CHECK=warn IV_a=v1.30.5 run --separate-stderr _iv_run a,b 0
	assert_success
	[[ "$stderr" == *"Going on (ISTIO_VERSION_CHECK=warn): the results record ISTIO_VERSION=mixed:"* ]]
	# The check stops unexpectedly, at the start and at the end: under fail at a --resume,
	# no warn advice; and nothing is left in TMPDIR either way.
	_istio_version_read_all() { exit 3; }
	TMPDIR="$tmpd" IV_a=v1.30.5 run --separate-stderr _iv_run a,b 0 --resumed-at 2026-01-01T00:00:00+00:00
	assert_failure 1
	[[ "$stderr" == *"stopped unexpectedly (exit 3; the error is above), so the version the members run is not known."$'\n'"Nothing was changed. A --resume never goes on with an unknown version (ISTIO_VERSION_CHECK=warn would not help): fix what the error above shows, then run the same --resume again."* ]]
	[ -z "$(find "$tmpd" -mindepth 1 -print -quit)" ]
	TMPDIR="$tmpd" ISTIO_VERSION_CHECK=warn IV_a=v1.30.5 run --separate-stderr _iv_run a,b 0 --resumed-at 2026-01-01T00:00:00+00:00
	assert_success
	[[ "$stderr" == *"warning: the Istio version check stopped unexpectedly (exit 3; the error is above), so the version the members run is not known."* ]]
	[[ "$stderr" != *"Going on"* ]]
	TMPDIR="$tmpd" ISTIO_VERSION_CHECK=warn IV_a=v1.30.5 run --separate-stderr _iv_recheck a,b
	assert_success
	assert_line --index 0 -- "--problem"
	[ -z "$(find "$tmpd" -mindepth 1 -print -quit)" ]
}

#!/usr/bin/env bats
# A member listed twice, or a remote equal to the source, is refused before any cluster
# call: every --contexts and --remote-contexts entrypoint, SETUP_CONTEXTS, no suite
# splitting a member list with split_csv, and a --resume of a sweep an older harness
# started with a member twice. Through the real entrypoints (PL33), with an empty
# kubeconfig and kubectl and oc stubs that log every call.

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr
source "${ROOT}/tests/lib/timestamp.sh"
source "${ROOT}/tests/lib/metrics.sh"
source "${ROOT}/tests/lib/fanout.sh"
source "${ROOT}/tests/lib/config.sh"

FX="${ROOT}/tests/lib/test/fixtures/istiod-diag"

setup() {
	RES="${BATS_TEST_TMPDIR}/res"
	mkdir -p "$RES"
	KC="${BATS_TEST_TMPDIR}/empty.kubeconfig"
	: > "$KC"
	export TMPDIR="$BATS_TEST_TMPDIR"
}

# _stub_bin: kubectl, oc and helm that log every call, and a curl that serves /metrics
# from STUB_PRE_BODY before the probe's change (STUB_MARK) and STUB_POST_BODY after.
# STUB_COUNT switches /metrics to a numbered body per call; STUB_EDS_FAIL fails the
# churn EDS poller's scrapes.
_stub_bin() {
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log" STUB_MARK="${BATS_TEST_TMPDIR}/post.mark" FX
	: > "$STUB_LOG"
	cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*) exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" fortio load "*" -json - "*) : > "$STUB_MARK"; cat "$FX/../fortio_ok.json" ;;
*" get pod -l app=fortio-client "*) printf 'fortio-client-0\t\tTrue' ;;
*" exec "*) cat "$FX/../fortio_ok.json" ;;
*" scale "*" --replicas=1 "*) : ;;
*" scale "*) : > "$STUB_MARK" ;;
*" label pod/"*"=true "*) : > "$STUB_MARK" ;;
*" label pod/"*) : ;;
*" wait pod/"*) : ;;
*" get pods -l app=propagation-canary "*) printf 'canary-backer-0\n' ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running "*) printf 'istiod-abc-x1\n' ;;
*" -n istio-system get pods -l app=istiod -o json "*) cat "$FX/pods_oom.json" ;;
*" get events "* | *" get deploy,rs "*) cat "$FX/empty_list.json" ;;
*" get node "*) cat "$FX/node_ready.json" ;;
*" logs "*) echo "istiod log line" ;;
*" -o json "*) cat "$FX/empty_list.json" ;;
*) exit 1 ;;
esac
STUB
	printf '#!/usr/bin/env bash\nprintf "oc %%s\\n" "$*" >> "$STUB_LOG"\nexit 1\n' > "${BIN}/oc"
	cat > "${BIN}/curl" <<'STUB'
#!/usr/bin/env bash
out="" url=""
while (($#)); do
	case "$1" in
	-o) out="$2"; shift 2 ;;
	http://*) url="$1"; shift ;;
	*) shift ;;
	esac
done
if [[ -n "${STUB_EDS_FAIL:-}" && "$out" == */eds-poll-* ]]; then exit 7; fi
case "$url" in
*/metrics)
	if [[ -n "${STUB_COUNT:-}" ]]; then
		[[ "$out" == /dev/null ]] && exit 0
		n=$(( $(cat "$STUB_COUNT" 2>/dev/null || echo 0) + 1 ))
		echo "$n" > "$STUB_COUNT"
		[[ " ${STUB_FAIL_CALLS:-} " != *" $n "* ]] || exit 7
		mem=3.145728e+08
		[[ " ${STUB_BIG_CALLS:-} " != *" $n "* ]] || mem=4.294967296e+09
		body="$(sed -e "s/^process_resident_memory_bytes .*/process_resident_memory_bytes $mem/" \
			-e "s/^pilot_xds_pushes{type=\"eds\"} .*/pilot_xds_pushes{type=\"eds\"} $((n * 100))/" "$FX/pre_metrics.txt")"
		if [[ -n "$out" ]]; then printf '%s\n' "$body" > "$out"; else printf '%s\n' "$body"; fi
		exit 0
	fi
	body="$STUB_PRE_BODY"; [[ -f "$STUB_MARK" ]] && body="$STUB_POST_BODY" ;;
*/clusters) body="$FX/../fortio_ok.json" ;;
*/ready) echo LIVE; exit 0 ;;
*/debug/syncz) echo '[]'; exit 0 ;;
*) exit 7 ;;
esac
if [[ -n "$out" ]]; then cp "$body" "$out"; else cat "$body"; fi
STUB
	chmod +x "${BIN}/kubectl" "${BIN}/oc" "${BIN}/curl"
	export STUB_PRE_BODY="${FX}/pre_metrics.txt" STUB_POST_BODY="${FX}/pre_metrics.txt"
}

# _refuses <suite/script> <stderr fragment> <args...>: --dry-run with an empty kubeconfig
# exits non-zero with the fragment on stderr, before any kubectl or oc call.
_refuses() {
	local s="$1" want="$2"
	shift 2
	: > "$STUB_LOG"
	PATH="${BIN}:${PATH}" KUBECONFIG="$KC" run --separate-stderr "${ROOT}/tests/${s}.sh" --dry-run "$@"
	if [[ "$status" -eq 0 || "$stderr" != *"$want"* ]]; then
		echo "${s} $*: exit ${status}, stderr: ${stderr}" >&2
		return 1
	fi
	if [[ -s "$STUB_LOG" ]]; then
		echo "${s}: a cluster call before the refusal: $(cat "$STUB_LOG")" >&2
		return 1
	fi
}

@test "every --contexts entrypoint refuses a member listed twice under --dry-run, naming it and the flag" {
	_stub_bin
	local s extra
	for s in churn-dataplane/004-run-sweep churn-dataplane/006-cleanup churn/001-setup-churn-test churn/003-run-sweep \
		churn/005-cleanup controlplane/001-setup-controlplane-test controlplane/002-collect-resource-metrics \
		controlplane/003-run-sweep controlplane/005-cleanup dataplane/003-run-sweep dataplane/005-cleanup \
		propagation/001-setup-propagation-test propagation/004-collect-pilot-metrics propagation/006-run-sweep \
		propagation/007-cleanup; do
		_refuses "$s" "--contexts lists ci-a twice (ci-a,ci-b,ci-a): list each mesh member once" --contexts ci-a,ci-b,ci-a
	done
	_refuses gateway-api/001-run-ingress-check "--contexts (or SETUP_CONTEXTS) lists ci-a twice" \
		--contexts ci-a,ci-b,ci-a --workload-context ci-b
	_refuses tuning/003-run-tuning-sweep "--contexts (or SETUP_CONTEXTS) lists ci-a twice" \
		--suite churn-dataplane --contexts ci-a,ci-b,ci-a --gitops-context ci-hub
	_refuses tuning/005-cleanup "--contexts (or SETUP_CONTEXTS) lists ci-a twice" --contexts ci-a,ci-b,ci-a
	_refuses tuning/001-apply-profile "--contexts (or SETUP_CONTEXTS) lists ci-a twice (ci-a,ci-a)" \
		--profile 01-push-throttling --contexts ci-a,ci-a
	mkdir -p "${BATS_TEST_TMPDIR}/state"
	_refuses tuning/002-revert-profile "lists ci-a twice (ci-a,ci-a)" --state-dir "${BATS_TEST_TMPDIR}/state" --contexts ci-a,ci-a
	_refuses controlplane/003-run-sweep \
		"--mem-guard-contexts (or CONTROLPLANE_MEM_GUARD_CONTEXTS) lists ci-c twice (ci-a,ci-c,ci-c)" \
		--contexts ci-a,ci-b --services-per-namespace 5 --mem-guard-contexts ci-a,ci-c,ci-c
	# The same list once each runs on (a dry run passes the split).
	PATH="${BIN}:${PATH}" KUBECONFIG="$KC" run --separate-stderr "${ROOT}/tests/churn/005-cleanup.sh" --dry-run --contexts ci-a,ci-b
	assert_success
}

@test "SETUP_CONTEXTS with a member twice is refused, named as SETUP_CONTEXTS" {
	_stub_bin
	local s
	for s in churn/003-run-sweep controlplane/002-collect-resource-metrics dataplane/005-cleanup propagation/006-run-sweep; do
		SETUP_CONTEXTS=ci-a,ci-b,ci-b _refuses "$s" "SETUP_CONTEXTS lists ci-b twice (ci-a,ci-b,ci-b): list each mesh member once"
	done
	SETUP_CONTEXTS=ci-a,ci-b,ci-b _refuses tuning/005-cleanup "--contexts (or SETUP_CONTEXTS) lists ci-b twice"
}

@test "every --remote-contexts entrypoint refuses a remote listed twice or equal to the source" {
	_stub_bin
	local s extra
	for s in propagation/002-run-endpoint-probe churn/002-run-churn-probe dataplane/001-setup-dataplane-test \
		dataplane/002-run-latency-probe churn-dataplane/001-setup-coexec-test churn-dataplane/002-run-baseline-probe \
		churn-dataplane/003-run-churn-probe; do
		extra=()
		[[ "$s" != churn-dataplane/003-run-churn-probe ]] || extra=(--churn-rate 5)
		_refuses "$s" "--remote-contexts lists the source context ci-a: the remotes are the other mesh members" \
			--source-context ci-a --remote-contexts ci-b,ci-a ${extra[@]+"${extra[@]}"}
		_refuses "$s" "--remote-contexts lists ci-b twice (ci-b,ci-c,ci-b): list each mesh member once" \
			--source-context ci-a --remote-contexts ci-b,ci-c,ci-b ${extra[@]+"${extra[@]}"}
	done
}

@test "no suite script splits a member list with split_csv any more (split_contexts does)" {
	run grep -nE 'split_csv[[:space:]]+"\$\{?(CONTEXTS_CSV|REMOTE_CONTEXTS_CSV|MEM_GUARD_CONTEXTS_CSV|SETUP_CONTEXTS)' \
		"$ROOT"/tests/*/[0-9]*.sh
	# The one left: controlplane 003's guard list, the union of --contexts and SETUP_CONTEXTS
	# (a member in both is expected there and deduplicated).
	assert_output --regexp '^[^ ]*controlplane/003-run-sweep\.sh:[0-9]+:[[:space:]]+split_csv "\$\{SETUP_CONTEXTS:-\}" _setup_ctxs$'
	[ "${#lines[@]}" -eq 1 ]
	# split_contexts itself: split_csv's split, then the checks.
	run split_contexts "a,b" OUT --contexts
	assert_success
	split_contexts " a , b ,," OUT --contexts
	[ "${OUT[*]}" = "a b" ]
	run split_contexts "a,b,a" OUT --contexts
	assert_failure
	assert_output "error: --contexts lists a twice (a,b,a): list each mesh member once"
	run split_contexts "b,a" OUT --remote-contexts a
	assert_output "error: --remote-contexts lists the source context a: the remotes are the other mesh members"
	# A key holding a quote or a bracket is still one key (no arithmetic on it).
	run split_contexts "x\"y],x\"y]" OUT --contexts
	assert_output --partial 'lists x"y] twice'
}

@test "003 --resume refuses a sweep an older harness started with a member twice, whatever --contexts says: start a new sweep" {
	local res="${BATS_TEST_TMPDIR}/res" d tsv bin="${BATS_TEST_TMPDIR}/bin" before cs
	export ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 ISTIO_VERSION_READY_WAIT_SEC=0
	CONTROLPLANE_RESULTS_DIR="$res" KUBECONFIG="$KC" run bash "${ROOT}/tests/controlplane/003-run-sweep.sh" --contexts ci-a,ci-b --mesh-sizes 1 --service-counts 5
	assert_failure 4
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	tsv="$(find "$d" -maxdepth 1 -name 'controlplane-*.tsv')"
	# What an older harness, which took a member twice, recorded for --contexts ci-a,ci-a,ci-b.
	sed -i.bak -e 's/^# ISTIO_VERSION=.*/# ISTIO_VERSION=v1.30.5/' -e 's/^# ISTIO_ACTIVE_REVISIONS=.*/# ISTIO_ACTIVE_REVISIONS=ci-a=,ci-a=,ci-b=/' "$tsv" && rm -f "${tsv}.bak"
	mkdir -p "$bin"
	printf '#!/bin/sh\nexit 1\n' > "${bin}/kubectl"
	chmod +x "${bin}/kubectl"
	before="$(cat "$tsv")"
	for cs in ci-a,ci-b ci-a ci-b,ci-a ci-a,ci-c; do
		PATH="${bin}:${PATH}" KUBECONFIG="$KC" run bash "${ROOT}/tests/controlplane/003-run-sweep.sh" --resume "$d" --contexts "$cs" --mesh-sizes 1 --service-counts 5
		assert_failure 1
		assert_output --partial "error: --resume: this sweep's TSV preamble lists ci-a twice in ISTIO_ACTIVE_REVISIONS (ci-a=,ci-a=,ci-b=): an older harness took that member twice, so its mesh sizes counted it twice and no --contexts can repeat them (each member is now listed once). Start a new sweep with each mesh member listed once."
		refute_output --partial "Resume with --contexts"
		refute_output --partial "Istio version:"
	done
	# The same through ISTIO_VERSION_BY_CONTEXT, when ISTIO_ACTIVE_REVISIONS is absent.
	sed -i.bak -e '/^# ISTIO_ACTIVE_REVISIONS=/d' -e 's/^# ISTIO_VERSION_BY_CONTEXT=.*/# ISTIO_VERSION_BY_CONTEXT=ci-b=v1.30.5,ci-a=v1.30.5,ci-b=v1.30.5/' "$tsv" && rm -f "${tsv}.bak"
	before="$(cat "$tsv")"
	PATH="${bin}:${PATH}" KUBECONFIG="$KC" run bash "${ROOT}/tests/controlplane/003-run-sweep.sh" --resume "$d" --contexts ci-b,ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 1
	assert_output --partial "lists ci-b twice in ISTIO_VERSION_BY_CONTEXT (ci-b=v1.30.5,ci-a=v1.30.5,ci-b=v1.30.5)"
	# Nothing written: the TSV as it was, no resumes.txt.
	[ "$(cat "$tsv")" = "$before" ]
	[ ! -e "$d/resumes.txt" ]
	# A member given twice now is refused when parsed, before any of this.
	PATH="${bin}:${PATH}" KUBECONFIG="$KC" run bash "${ROOT}/tests/controlplane/003-run-sweep.sh" --resume "$d" --contexts ci-a,ci-b,ci-a --mesh-sizes 1 --service-counts 5
	assert_failure 1
	assert_output --partial "--contexts lists ci-a twice (ci-a,ci-b,ci-a): list each mesh member once"
	refute_output --partial "preamble lists"
}

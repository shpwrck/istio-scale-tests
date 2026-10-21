#!/usr/bin/env bats
# The tuning sweep's check that nothing but a profile edited the Istio CR during its pass
# (tests/tuning/001-003): 001 records the generations once its apply settled, 002 compares
# them before its revert (a move: a WARNING and istio-edited-during-pass), and 003 makes each
# such finding one problem naming the pass; the profiles' own patches are none. Through the
# real scripts (PL33); no cluster: kubectl is a stub.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
	python3 -I -c 'import yaml' 2>/dev/null || skip "python3 with PyYAML is needed (tuning lib)"
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: > "$EK"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export ISTIO_VERSION_CHECK=warn ISTIO_VERSION_READY_WAIT_SEC=0 METRICS_READY_TIMEOUT=0
	export TD="${BATS_TEST_TMPDIR}/tun" ST="${BATS_TEST_TMPDIR}/state"
	mkdir -p "$TD"
	# kubectl: a stateful Istio CR (files in TD): cr.json (its spec) and gen (its generation,
	# and its IstioRevision's; 2 at first). A merge patch applies (RFC 7386) and raises gen
	# by 1; a profile's patch marks it applied, its revert patch (istio-revert-*) unmarks
	# it. Each istiod pod list logs the ISTIO_GENERATIONS its caller was handed to
	# gens-seen; with TUN_EDIT set, the first one while a profile is applied is an edit by
	# someone else (gen + 1; TUN_EDIT=spec also sets a key no profile sets). TUN_GEN_FAIL:
	# the Istio version reader's reads fail. A profile's resources apply and delete; the
	# members hold no other tuning profile objects. Any other call fails (the probes then
	# fail: PROBE_FAILED).
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
d="$TD"
[ -f "$d/gen" ] || echo 2 > "$d/gen"
[ -f "$d/cr.json" ] || echo '{"spec":{"version":"v1.30-latest","values":{}}}' > "$d/cr.json"
case "$*" in *" get pods -l app=istiod"*)
	echo "${ISTIO_GENERATIONS:-none}" >> "$d/gens-seen"
	if [ -n "${TUN_EDIT:-}" ] && [ -f "$d/applied" ] && [ ! -f "$d/edited" ]; then
		: > "$d/edited"
		echo $(( $(cat "$d/gen") + 1 )) > "$d/gen"
		[ "$TUN_EDIT" != spec ] || { jq -c '.spec.values.global.logging.level = "default:debug"' "$d/cr.json" > "$d/cr.new" && mv "$d/cr.new" "$d/cr.json"; }
	fi ;;
esac
g="$(cat "$d/gen")"
case "$*" in
*"get istios.sailoperator.io default"*|*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	[ -z "${TUN_GEN_FAIL:-}" ] || { echo 'error: the server is currently unable to handle the request' >&2; exit 1; }
	STUB_ISTIO_CR_GEN="$g" STUB_ISTIO_REV_GEN="$g" exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" patch istio.sailoperator.io default --type=merge --patch-file="*)
	args="$*"; f="${args##*--patch-file=}"; f="${f%% *}"
	jq --slurpfile p "$f" 'def mp($q): if ($q | type) == "object" then reduce ($q | keys_unsorted[]) as $k ((if type == "object" then . else {} end); if $q[$k] == null then del(.[$k]) else .[$k] = (.[$k] | mp($q[$k])) end) else $q end; mp($p[0])' "$d/cr.json" > "$d/cr.new" && mv "$d/cr.new" "$d/cr.json"
	case "$f" in *istio-revert-*) rm -f "$d/applied" ;; *) : > "$d/applied" ;; esac
	echo $((g + 1)) > "$d/gen" ;;
*" get istio.sailoperator.io default -o jsonpath={.metadata.generation}"*) echo "$g $g True default" ;;
*" get istio.sailoperator.io default -o jsonpath={.status.activeRevisionName}"*) echo default ;;
*" get istio.sailoperator.io default -o json") jq -c --argjson g "$g" '. + {metadata: {name: "default", generation: $g}}' "$d/cr.json" ;;
*" get istiorevision.sailoperator.io default -o jsonpath="*) echo "$g $g True" ;;
*" rollout status "*) exit 0 ;;
*" -n istio-system get deployment istiod -o json"*)
	jq -c '{spec: {template: {spec: {containers: [{name: "discovery", env: ((.spec.values.pilot.env // {}) | to_entries | map({name: .key, value: (.value | tostring)}))}]}}}}' "$d/cr.json" ;;
*" apply --server-side "*) : > "$d/res" ;;
*" delete --ignore-not-found -f "*) rm -f "$d/res" ;;
*" get --ignore-not-found -f "*) : ;;
*" tuning-connection-pool -o name"*|*" -n istio-system get ConfigMap tuning-profile-"*) [ -f "$d/res" ] ;;
*" -l istio-scale-tests/tuning-profile"*) echo '{"kind":"List","items":[]}' ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
}

# step <script> <args...>: a tuning step (001 or 002) on ci-a with the stub.
step() {
	local s="$1"
	shift
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/${s}" "$@"
}

# apply: 001 with 01-push-throttling into ST. revert: 002 on ST.
apply() { step 001-apply-profile.sh --profile "${ROOT}/tests/tuning/profiles/01-push-throttling.yaml" --contexts ci-a --state-dir "$ST"; }
revert() { step 002-revert-profile.sh --state-dir "$ST"; }

# sweep: tuning 003 over the churn suite on ci-a: the baseline, 01-push-throttling and
# 02-xds-cache-off, no setup and no Argo CD pause. Sets TDIR and OUT (its outcome).
sweep() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" \
		--suite churn --contexts ci-a --no-gitops-pause --skip-setup --keep-workloads \
		--profiles 01-push-throttling,02-xds-cache-off --settle 0 --output-dir "${BATS_TEST_TMPDIR}/tres"
	TDIR="$(find "${BATS_TEST_TMPDIR}/tres" -maxdepth 1 -name 'sweep-*' -type d)"
	OUT="${TDIR}/sweep-outcome.txt"
}

@test "001 records each member's generations once its apply settled; a member it cannot read is one warning, and recorded as unknown" {
	apply
	assert_success
	[ "$(<"$ST/istio-generations-applied")" = ci-a=3/3 ]
	[[ "$stderr" != *"could not record"* ]]
	rm -rf "$ST" "$TD"
	mkdir -p "$TD"
	TUN_GEN_FAIL=1 apply
	assert_success
	[ "$(<"$ST/istio-generations-applied")" = ci-a=unknown/unknown ]
	[ "$(grep -c "^warn: could not record every member's Istio CR generations after the apply settled (ci-a=unknown/unknown)" <<<"$stderr")" -eq 1 ]
}

@test "002 warns when the generations moved since 001's record and writes istio-edited-during-pass; a re-run after a revert that started checks nothing and keeps that finding; the next apply clears it" {
	apply
	revert
	assert_success
	[[ "$stderr" != *"WARNING"* ]]
	[ ! -e "$ST/istio-edited-during-pass" ]
	apply
	echo 9 > "${TD}/gen"
	revert
	assert_success
	[[ "$stderr" == *"WARNING: the Istio CR changed during the pass of 01-push-throttling, not by the profile: ci-a (5/5 -> 9/9)"* ]]
	[ "$(<"$ST/istio-edited-during-pass")" = "ci-a (5/5 -> 9/9)" ]
	# As if that revert had stopped after its patch: run again, its own patch is no edit.
	echo 01-push-throttling > "$ST/active-profile"
	revert
	assert_success
	[[ "$output" == *"note: a revert of this apply started before ("*") and may have patched the Istio CR already: no new check"* ]]
	[[ "$stderr" != *"WARNING"* ]]
	[ "$(<"$ST/istio-edited-during-pass")" = "ci-a (5/5 -> 9/9)" ]
	apply
	[ ! -e "$ST/istio-edited-during-pass" ]
	[ ! -e "$ST/revert-started" ]
}

@test "the sweep: its profiles' own patches are no problem and each pass's probes record the generations it ran on; an edit during a pass is one problem naming the pass, and one that stays to the end the spec problem (exit 4)" {
	sweep
	# The probes fail (the stub has no istiod pod): exit 4 for that reason only.
	[ "$status" -eq 4 ] || { echo "$stderr"; false; }
	! grep -q '^PROBLEM=' "$OUT" || { cat "$OUT"; false; }
	grep -qx 'ci-a=2/2' "${TD}/gens-seen"
	grep -qx 'ci-a=3/3' "${TD}/gens-seen"
	grep -qx 'ci-a=5/5' "${TD}/gens-seen"
	cmp "${TDIR}/istio-spec/start-ci-a.json" "${TDIR}/istio-spec/end-ci-a.json"
	rm -rf "$TD" "${BATS_TEST_TMPDIR}/tres"
	mkdir -p "$TD"
	TUN_EDIT=spec sweep
	[ "$status" -eq 4 ]
	[ "$(grep -c '^PROBLEM=' "$OUT")" -eq 2 ] || { cat "$OUT"; false; }
	grep -qxF "PROBLEM=pass 01-push-throttling: the Istio CR changed during the pass, after its apply settled and not by its profile: ci-a (3/3 -> 4/4); its probes may have measured another configuration (002-revert-profile.sh, istio-edited-during-pass in its state dir)" "$OUT" \
		|| { cat "$OUT"; false; }
	grep -q "^PROBLEM=ci-a's Istio CR spec after the last revert differs from the sweep's start (an incomplete revert, or an edit by something else that no revert undid: they restore only the profiles' keys): values.global.logging.level; " "$OUT"
}

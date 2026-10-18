#!/usr/bin/env bats
# An edit of the Istio CR by something else that 002-revert-profile.sh finds (its
# istio-edited-during-pass) stays after that revert, which restores only the profile's
# keys, and no later check of the sweep reports it again: the sweep's PROBLEM names the
# pass that runs next and the ones after it (none when that pass is the last), and 002's
# warning says any passes after it may measure another configuration; after a failed
# apply, that its probes did not run. An edit that stays to the end makes the end check's
# spec difference "an incomplete revert, or an edit by something else that no revert
# undid", the second half only when a check found such an edit. Through the real tuning
# sweep (PL33); no cluster: kubectl is a stub.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: > "$EK"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export ISTIO_VERSION_CHECK=warn ISTIO_VERSION_READY_WAIT_SEC=0 METRICS_READY_TIMEOUT=0
	python3 -I -c 'import yaml' 2>/dev/null || skip "python3 with PyYAML is needed (tuning lib)"
	# kubectl: as tuning-generations2.bats's member stub, for one member. The Istio CR is
	# cr.json (its spec) and gen (its generation, and its IstioRevision's; 2 at first); a
	# merge patch applies to it and raises its generation by 1. TUN_CRBUMP_ON=<text>: at the
	# TUN_CRBUMP_NTH-th call (default 1) containing it, someone else edits the Istio CR (its
	# generation + 1; with TUN_CRBUMP_SPEC, it also sets values.global.logging.level, a key
	# no profile sets). TUN_VERIFY_FAIL: 001's istiod Deployment read fails (its apply
	# fails). Any other call fails (the probes then fail: PROBE_FAILED).
	export TD="${BATS_TEST_TMPDIR}/tun"
	mkdir -p "$TD"
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
d="$TD"
[ -f "$d/gen" ] || echo 2 > "$d/gen"
[ -f "$d/cr.json" ] || echo '{"spec":{"version":"v1.30-latest","values":{}}}' > "$d/cr.json"
if [ -n "${TUN_CRBUMP_ON:-}" ] && [ ! -f "$d/bump-done" ]; then
	case "$*" in *"$TUN_CRBUMP_ON"*)
		n=$(( $(cat "$d/bump-n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$d/bump-n"
		if [ "$n" -ge "${TUN_CRBUMP_NTH:-1}" ]; then
			: > "$d/bump-done"
			echo $(( $(cat "$d/gen") + 1 )) > "$d/gen"
			[ -z "${TUN_CRBUMP_SPEC:-}" ] || { jq -c '.spec.values.global.logging.level = "default:debug"' "$d/cr.json" > "$d/cr.new" && mv "$d/cr.new" "$d/cr.json"; }
		fi ;;
	esac
fi
g="$(cat "$d/gen")"
case "$*" in
*"get istios.sailoperator.io default"*|*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	STUB_ISTIO_CR_GEN="$g" STUB_ISTIO_REV_GEN="$g" exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" patch istio.sailoperator.io default --type=merge --patch-file="*)
	f="${*##*--patch-file=}"; f="${f%% *}"
	jq --slurpfile p "$f" 'def mp($q): if ($q | type) == "object" then reduce ($q | keys_unsorted[]) as $k ((if type == "object" then . else {} end); if $q[$k] == null then del(.[$k]) else .[$k] = (.[$k] | mp($q[$k])) end) else $q end; mp($p[0])' "$d/cr.json" > "$d/cr.new" && mv "$d/cr.new" "$d/cr.json"
	echo $((g + 1)) > "$d/gen" ;;
*" get istio.sailoperator.io default -o jsonpath={.metadata.generation}"*) echo "$g $g True default" ;;
*" get istio.sailoperator.io default -o jsonpath={.status.activeRevisionName}"*) echo default ;;
*" get istio.sailoperator.io default -o json") jq -c --argjson g "$g" '. + {metadata: {name: "default", generation: $g}}' "$d/cr.json" ;;
*" get istiorevision.sailoperator.io default -o jsonpath="*) echo "$g $g True" ;;
*" rollout status "*) exit 0 ;;
*" -n istio-system get deployment istiod -o json"*)
	[ -z "${TUN_VERIFY_FAIL:-}" ] || exit 1
	jq -c '{spec: {template: {spec: {containers: [{name: "discovery", env: ((.spec.values.pilot.env // {}) | to_entries | map({name: .key, value: (.value | tostring)}))}]}}}}' "$d/cr.json" ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
}

# two_sweep: tuning 003 over the churn suite on ci-a with the baseline, 01-push-throttling
# and 02-xds-cache-off, no setup and no Argo CD pause. Sets TDIR and OUT.
two_sweep() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" \
		--suite churn --contexts ci-a --no-gitops-pause --skip-setup --keep-workloads \
		--profiles 01-push-throttling,02-xds-cache-off --settle 0 --output-dir "${BATS_TEST_TMPDIR}/tres"
	TDIR="$(find "${BATS_TEST_TMPDIR}/tres" -maxdepth 1 -name 'sweep-*' -type d)"
	OUT="${TDIR}/sweep-outcome.txt"
}

STAYS="any passes after it (while the edit stays: this revert restores only the profile's keys) may measure another configuration"

@test "an edit during pass 01's probes that 002 finds: one PROBLEM naming pass 01 and pass 02, the last (no passes after it); 002's warning says any passes after it may measure another configuration" {
	# Someone edits the Istio CR at the second istiod pod list: pass 01's probe, after the
	# sweep's read once its apply settled.
	TUN_CRBUMP_ON='-o jsonpath={range .items[*]}{.metadata.name}' TUN_CRBUMP_NTH=2 two_sweep
	[ "$status" -eq 4 ]
	[ "$(grep -c '^PROBLEM=' "$OUT")" -eq 1 ] || { cat "$OUT"; false; }
	grep -qxF "PROBLEM=the Istio CR changed during pass 01-push-throttling, after its apply settled and not by its profile: ci-a (Istio CR generation 3 -> 4, IstioRevision generation 3 -> 4); likely: a version changed and changed back, or a values change (an edit of the Istio CR); its probes may have measured another configuration, and pass 02-xds-cache-off may measure another configuration than its profile's (002-revert-profile.sh, istio-edited-during-pass in its state dir)" "$OUT" \
		|| { cat "$OUT"; false; }
	[[ "$stderr" == *"The pass's probes may have measured another configuration, and ${STAYS}. Reverting anyway."* ]] \
		|| { echo "$stderr"; false; }
}

@test "a failed apply of pass 01 with an edit before its revert that 002 finds: the PROBLEM says its probes did not run, and names pass 02 (the last); 002's warning names any passes after it" {
	# Every apply fails (001's verification read fails); someone edits the Istio CR at the
	# fifth IstioRevision read, 002's own (the sweep's two before the apply, 001's record,
	# the sweep's after the failed apply).
	TUN_VERIFY_FAIL=1 TUN_CRBUMP_ON='get istiorevisions.sailoperator.io' TUN_CRBUMP_NTH=5 two_sweep
	[ "$status" -eq 4 ]
	[ -e "${TDIR}/01-push-throttling/SETUP_FAILED" ]
	grep -qF "PROBLEM=the Istio CR changed between the failed apply of pass 01-push-throttling and its revert, not by its profile: ci-a " "$OUT" \
		|| { cat "$OUT"; false; }
	grep -qF "; its probes did not run, and pass 02-xds-cache-off may measure another configuration than its profile's (002-revert-profile.sh, istio-edited-during-pass in its state dir)" "$OUT" \
		|| { cat "$OUT"; false; }
	[[ "$stderr" == *"Its probes did not run, but ${STAYS}. Reverting anyway."* ]] || { echo "$stderr"; false; }
}

# SPEC_EDIT: the end check's PROBLEM for the key the edit set, when a check found the edit.
SPEC_EDIT="PROBLEM=ci-a's Istio CR spec after the last revert differs from the sweep's start (an incomplete revert, or an edit by something else that no revert undid: they restore only the profiles' keys): values.global.logging.level; the mesh is not as the sweep found it"

@test "an edit of a key no profile sets during pass 01's probes stays to the end: the end check calls the spec difference an incomplete revert, or an edit by something else that no revert undid" {
	TUN_CRBUMP_SPEC=1 TUN_CRBUMP_ON='-o jsonpath={range .items[*]}{.metadata.name}' TUN_CRBUMP_NTH=2 two_sweep
	[ "$status" -eq 4 ]
	[ "$(grep -c '^PROBLEM=' "$OUT")" -eq 2 ] || { cat "$OUT"; false; }
	grep -qF "PROBLEM=the Istio CR changed during pass 01-push-throttling, after its apply settled and not by its profile: ci-a " "$OUT"
	grep -qxF "$SPEC_EDIT" "$OUT" || { cat "$OUT"; false; }
}

@test "an edit of a key no profile sets during the baseline pass: the PROBLEM names pass 01 and the passes after it (02 runs after it); the end check's spec difference names such an edit too" {
	TUN_CRBUMP_SPEC=1 TUN_CRBUMP_ON='-o jsonpath={range .items[*]}{.metadata.name}' TUN_CRBUMP_NTH=1 two_sweep
	[ "$status" -eq 4 ]
	[ "$(grep -c '^PROBLEM=' "$OUT")" -eq 2 ] || { cat "$OUT"; false; }
	grep -qxF "PROBLEM=the Istio CR changed while the sweep changed nothing, between its read at the sweep's start and its read before the apply of pass 01-push-throttling: ci-a (Istio CR generation 2 -> 3, IstioRevision generation 2 -> 3); likely: a version changed and changed back, or a values change (an edit of the Istio CR); the passes run since that first read (baseline) may have measured another configuration, and pass 01-push-throttling (and the passes after it, while the edit stays) may measure another configuration than its profile's" "$OUT" \
		|| { cat "$OUT"; false; }
	grep -qxF "$SPEC_EDIT" "$OUT" || { cat "$OUT"; false; }
}

#!/usr/bin/env bats
# The tuning sweep's Istio CR generation checks with members whose generations differ
# (tests/tuning/001-003): the record 002 compares from is kept member by member (the sweep's
# read where it read the member, 001's where it did not), so an edit after 001's record is
# reported once; a problem names the pass an edit may change, not the passes before it; 002
# after a failed apply names its span as 003 does. Through the real scripts (PL33); no
# cluster: kubectl is a stub. tuning-generations.bats covers the rest with one member.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
	EK="${BATS_TEST_TMPDIR}/kubeconfig"
	: > "$EK"
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	export ISTIO_VERSION_CHECK=warn ISTIO_VERSION_READY_WAIT_SEC=0 METRICS_READY_TIMEOUT=0
}

# _need_yaml: the tuning lib needs python3 with PyYAML.
_need_yaml() {
	python3 -I -c 'import yaml' 2>/dev/null || skip "python3 with PyYAML is needed (tuning lib)"
}

# _member_stub: a kubectl whose members (--context=<ctx>) each have their own Istio CR (files
# in TD): cr.<ctx>.json (its spec) and gen.<ctx> (its generation, and its IstioRevision's;
# 2 at first). A merge patch applies to that member's and raises its generation by 1.
# TUN_CRBUMP_ON=<text>: at the first call containing it, someone else edits the Istio CR of
# that call's member (its generation + 1); with TUN_FAILCTX=<ctx>, that member's next two
# Istio CR reads then fail (a read and its retry). TUN_VERIFY_FAIL: 001's istiod Deployment
# read fails (its verification fails). TUN_ROLLOUT_FAIL_ONCE: the first rollout wait fails.
# Any other call fails (the probes then fail: PROBE_FAILED).
_member_stub() {
	export TD="${BATS_TEST_TMPDIR}/tun"
	mkdir -p "$TD"
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
d="$TD" c=none
case "$*" in *--context=*) args="$*"; c="${args#*--context=}"; c="${c%% *}" ;; esac
[ -f "$d/gen.$c" ] || echo 2 > "$d/gen.$c"
[ -f "$d/cr.$c.json" ] || echo '{"spec":{"version":"v1.30-latest","values":{}}}' > "$d/cr.$c.json"
if [ -n "${TUN_CRBUMP_ON:-}" ] && [ ! -f "$d/bump-done" ]; then
	case "$*" in *"$TUN_CRBUMP_ON"*)
		: > "$d/bump-done"
		echo $(( $(cat "$d/gen.$c") + 1 )) > "$d/gen.$c"
		[ -z "${TUN_FAILCTX:-}" ] || echo 2 > "$d/fail.$TUN_FAILCTX" ;;
	esac
fi
g="$(cat "$d/gen.$c")"
case "$*" in
*"get istios.sailoperator.io default"*)
	k="$(cat "$d/fail.$c" 2>/dev/null || echo 0)"
	if [ "$k" -gt 0 ]; then
		echo $((k - 1)) > "$d/fail.$c"
		echo 'error: the server is currently unable to handle the request' >&2; exit 1
	fi
	STUB_ISTIO_CR_GEN="$g" STUB_ISTIO_REV_GEN="$g" exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	STUB_ISTIO_CR_GEN="$g" STUB_ISTIO_REV_GEN="$g" exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" patch istio.sailoperator.io default --type=merge --patch-file="*)
	args="$*"; f="${args##*--patch-file=}"; f="${f%% *}"
	jq --slurpfile p "$f" 'def mp($q): if ($q | type) == "object" then reduce ($q | keys_unsorted[]) as $k ((if type == "object" then . else {} end); if $q[$k] == null then del(.[$k]) else .[$k] = (.[$k] | mp($q[$k])) end) else $q end; mp($p[0])' "$d/cr.$c.json" > "$d/cr.$c.new" && mv "$d/cr.$c.new" "$d/cr.$c.json"
	echo $((g + 1)) > "$d/gen.$c" ;;
*" get istio.sailoperator.io default -o jsonpath={.metadata.generation}"*) echo "$g $g True default" ;;
*" get istio.sailoperator.io default -o jsonpath={.status.activeRevisionName}"*) echo default ;;
*" get istio.sailoperator.io default -o json") jq -c --argjson g "$g" '. + {metadata: {name: "default", generation: $g}}' "$d/cr.$c.json" ;;
*" get istiorevision.sailoperator.io default -o jsonpath="*) echo "$g $g True" ;;
*" rollout status "*)
	if [ -n "${TUN_ROLLOUT_FAIL_ONCE:-}" ] && [ ! -f "$d/rollout-failed" ]; then : > "$d/rollout-failed"; exit 1; fi
	exit 0 ;;
*" -n istio-system get deployment istiod -o json"*)
	[ -z "${TUN_VERIFY_FAIL:-}" ] || exit 1
	jq -c '{spec: {template: {spec: {containers: [{name: "discovery", env: ((.spec.values.pilot.env // {}) | to_entries | map({name: .key, value: (.value | tostring)}))}]}}}}' "$d/cr.$c.json" ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
}

# member_sweep [<sweep args>...]: tuning 003 over the churn suite on CTXS (default ci-a) with
# 01-push-throttling, no setup and no Argo CD pause; results under tres/. Sets TDIR and OUT.
member_sweep() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" \
		--suite churn --contexts "${CTXS:-ci-a}" --no-gitops-pause --skip-setup --keep-workloads \
		--profiles 01-push-throttling --settle 0 --output-dir "${BATS_TEST_TMPDIR}/tres" "$@"
	TDIR="$(find "${BATS_TEST_TMPDIR}/tres" -maxdepth 1 -name 'sweep-*' -type d)"
	OUT="${TDIR}/sweep-outcome.txt"
}

@test "an edit after 001's record while the sweep's read misses another member: one problem naming the edited member; the record keeps the sweep's read where it has one and 001's for the member it missed, which 002 compares from" {
	_need_yaml
	_member_stub
	local p=01-push-throttling
	# Someone edits ci-a's Istio CR during 001's verification (after its record); the
	# sweep's read after the apply then fails for ci-b.
	CTXS=ci-a,ci-b TUN_FAILCTX=ci-b TUN_CRBUMP_ON="--context=ci-a -n istio-system get deployment istiod -o json" member_sweep
	[ "$status" -eq 4 ]
	[ "$(grep -c '^PROBLEM=' "$OUT")" -eq 1 ] || { cat "$OUT"; false; }
	grep -qxF "PROBLEM=the Istio CR changed while the sweep changed nothing, between its read once the apply of pass ${p} settled (001's istio-generations-applied) and its read after the apply of pass ${p}: ci-a (Istio CR generation 3 -> 4, IstioRevision generation 3 -> 4); likely: a version changed and changed back, or a values change (an edit of the Istio CR); pass ${p} may measure another configuration than its profile's" "$OUT" \
		|| { cat "$OUT"; false; }
	grep -qxF "NOTE=the Istio CR generations of a member could not be compared between the sweep's read once the apply of pass ${p} settled (001's istio-generations-applied) and its read after the apply of pass ${p} (a read failed): ci-b (3/3 -> unknown/unknown); 002 compares it from 001's record up to its revert, which covers this span" "$OUT" \
		|| { cat "$OUT"; false; }
	[ "$(<"${TDIR}/${p}/state/istio-generations-applied")" = "ci-a=4/4,ci-b=3/3" ]
	[ ! -e "${TDIR}/${p}/state/istio-edited-during-pass" ]
	[ ! -e "${TDIR}/${p}/state/istio-generations-unchecked" ]
}

@test "an edit before the first apply with no pass run since the sweep's read: the problem names that pass and the ones after it, not passes that ran" {
	_need_yaml
	_member_stub
	local p=01-push-throttling
	# The sweep reads its baseline state (the Sidecar first) after its first read.
	TUN_CRBUMP_ON="get sidecar.networking.istio.io default" member_sweep --no-baseline
	[ "$status" -eq 4 ]
	[ "$(grep -c '^PROBLEM=' "$OUT")" -eq 1 ] || { cat "$OUT"; false; }
	grep -qxF "PROBLEM=the Istio CR changed while the sweep changed nothing, between its read at the sweep's start and its read before the apply of pass ${p}: ci-a (Istio CR generation 2 -> 3, IstioRevision generation 2 -> 3); likely: a version changed and changed back, or a values change (an edit of the Istio CR); pass ${p} may measure another configuration than its profile's" "$OUT" \
		|| { cat "$OUT"; false; }
}

@test "002 after a failed apply (SETUP_FAILED next to its state dir) names the span from that apply to its revert, as 003 does, in its warning, its unchecked warning and its notes (a re-run after the revert finished too)" {
	_need_yaml
	_member_stub
	local p=01-push-throttling st span="between the failed apply of pass 01-push-throttling and its revert"
	_failed_apply() {
		st="${BATS_TEST_TMPDIR}/$1/${p}/state"
		TUN_VERIFY_FAIL=1 PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/001-apply-profile.sh" \
			--profile "${ROOT}/tests/tuning/profiles/${p}.yaml" --contexts ci-a --state-dir "$st"
		assert_failure
		[ -s "${st}/istio-generations-applied" ]
		echo "SETUP_FAILED 2026-01-01T00:00:00Z" > "${st}/../SETUP_FAILED"
	}
	_revert() {
		PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/002-revert-profile.sh" --state-dir "$st"
		assert_success
		[[ "$output$stderr" != *"during the pass"* ]] || { echo "$output$stderr"; false; }
	}
	# Someone else edits the Istio CR twice after the failed apply's record.
	_failed_apply edited
	echo $(( $(<"${TD}/gen.ci-a") + 2 )) > "${TD}/gen.ci-a"
	_revert
	[[ "$stderr" == *"WARNING: the Istio CR changed ${span}, not by this profile: ci-a (Istio CR generation 3 -> 5, IstioRevision generation 3 -> 5). Likely: "*". Its probes did not run, but any passes after it (while the edit stays: this revert restores only the profile's keys) may measure another configuration. Reverting anyway."* ]] \
		|| { echo "$stderr"; false; }
	[ -s "${st}/istio-edited-during-pass" ]
	# Run again after that revert finished (no active-profile left): the pass is named from
	# the state dir's parent, not as "unknown".
	_revert
	[[ "$output" == *"no check that it was left alone ${span} (that run's finding, if any, stays in istio-edited-during-pass)"* ]] \
		|| { echo "$output"; false; }
	[[ "$output$stderr" != *"pass unknown"* ]] || { echo "$output$stderr"; false; }
	# A revert that started before (and stopped before it finished) is not compared again.
	_failed_apply restarted
	date -u +%Y-%m-%dT%H:%M:%SZ > "${st}/revert-started"
	_revert
	[[ "$output" == *"no check that it was left alone ${span} (that run's finding, if any, stays in istio-edited-during-pass)"* ]] \
		|| { echo "$output"; false; }
	# 001's record missed the member.
	_failed_apply unread
	echo "ci-a=unknown/unknown" > "${st}/istio-generations-applied"
	_revert
	[[ "$stderr" == *"An edit of its Istio CR ${span} is not ruled out (istio-generations-unchecked in the state dir). Reverting anyway."* ]] \
		|| { echo "$stderr"; false; }
	# No record at all.
	_failed_apply unrecorded
	rm "${st}/istio-generations-applied"
	_revert
	[[ "$output" == *"no check that the Istio CR was left alone ${span}"* ]] || { echo "$output"; false; }
}

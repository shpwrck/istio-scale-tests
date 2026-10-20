#!/usr/bin/env bats
# The tuning sweep's Istio CR generation checks when a read fails or an edit lands in the
# sweep's own step (tests/tuning/001-003, istio_generations_diff in tests/lib/preamble.sh):
# a member whose generations could not be read is never left out silently (a note naming
# it and both reads; 002 writes istio-generations-unchecked, which 003 notes; 001 warns);
# an Istio CR generation that rose by more than 1 (or fell) across the sweep's own apply or
# revert is a problem; an edit between 001's after-apply record and 003's own read is
# reported once. Through the real scripts (PL33); no cluster: kubectl is a stub.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/preamble.sh"

setup() {
	# The test's own process (bats runs setup and the test in one): the TUN_TERM_ON stub looks
	# for the sweep below it only, never in a shell that started bats.
	export TEST_PID="$BASHPID"
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

# _gen_stub: a kubectl with a stateful Istio CR (files in TD): cr.json (its spec) and gen
# (its generation, and its IstioRevision's). A merge patch applies and raises gen by 1;
# with TUN_PATCH_EXTRA the first one raises it by 2 (another edit landed during the
# apply). Each istiod pod list appends ISTIO_GENERATIONS to gens-seen. TUN_FOREIGN_AT=<n>:
# at the n-th istiod pod list someone else edits the Istio CR (gen + 1), and with
# TUN_FAIL_READS=<k> the next k Istio CR reads then fail (a read and its retry);
# TUN_FAIL_AFTER_PATCH=<k>: the k reads after the first patch fail. TUN_FOREIGN_ON=<glob>:
# someone else edits the Istio CR at the first call matching it while a profile's resources
# are applied. TUN_BUMP_ON=<glob>: at the first call matching it (the TUN_BUMP_AT-th with
# that set), someone else edits the Istio CR (gen + 1), or with TUN_BUMP_REV Sail renders
# its IstioRevision again (that generation + 1 from then on). TUN_VERIFY_FAIL: 001's istiod
# Deployment read fails (its verification fails, exit 2). TUN_ROLLOUT_FAIL_ONCE: the first
# rollout wait fails. TUN_CRJSON_FAIL_AT=<n>: the n-th full Istio CR read (the sweep's spec
# read is the first, 001's read before its first patch the second) fails, and someone else
# edits the Istio CR then. TUN_TERM_ON=<glob>: at the first call matching it, SIGTERM to
# the sweep (the topmost ancestor running 003-run-tuning-sweep.sh below the test's process,
# TEST_PID), and that call fails.
# Any other call fails (the probes then fail: PROBE_FAILED).
_gen_stub() {
	export TD="${BATS_TEST_TMPDIR}/tun"
	mkdir -p "$TD"
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
d="$TD"
case "$*" in *" get pods -l app=istiod"*) echo "${ISTIO_GENERATIONS:-none}" >> "$d/gens-seen"
	if [ -n "${TUN_FOREIGN_AT:-}" ] && [ "$(wc -l < "$d/gens-seen")" -eq "$TUN_FOREIGN_AT" ]; then
		echo $(( $(cat "$d/gen" 2>/dev/null || echo 2) + 1 )) > "$d/gen"
		[ -z "${TUN_FAIL_READS:-}" ] || echo "$TUN_FAIL_READS" > "$d/failreads"
	fi ;;
esac
[ -f "$d/gen" ] || echo 2 > "$d/gen"
if [ -n "${TUN_TERM_ON:-}" ] && [ ! -e "$d/term-sent" ]; then
	case "$*" in $TUN_TERM_ON)
		: > "$d/term-sent"
		p=$PPID s=""
		while [ "${p:-1}" -gt 1 ] && [ "$p" != "${TEST_PID:?}" ]; do
			case "$(ps -o args= -p "$p" 2>/dev/null)" in *003-run-tuning-sweep.sh*) s="$p" ;; esac
			p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
		done
		[ -z "$s" ] || kill -TERM "$s"
		exit 1 ;;
	esac
fi
if [ -n "${TUN_FOREIGN_ON:-}" ] && [ ! -f "$d/foreign-on-done" ] && [ -f "$d/applied" ]; then
	case "$*" in $TUN_FOREIGN_ON) echo $(( $(cat "$d/gen") + 1 )) > "$d/gen"; : > "$d/foreign-on-done" ;; esac
fi
if [ -n "${TUN_BUMP_ON:-}" ] && [ ! -f "$d/bump-done" ]; then
	case "$*" in $TUN_BUMP_ON)
		k=$(( $(cat "$d/bump-n" 2>/dev/null || echo 0) + 1 )); echo "$k" > "$d/bump-n"
		if [ "$k" -ge "${TUN_BUMP_AT:-1}" ]; then
			: > "$d/bump-done"
			if [ -n "${TUN_BUMP_REV:-}" ]; then echo 1 > "$d/revoff"; else echo $(( $(cat "$d/gen") + 1 )) > "$d/gen"; fi
		fi ;;
	esac
fi
[ -f "$d/cr.json" ] || echo '{"spec":{"version":"v1.30-latest","values":{}}}' > "$d/cr.json"
g="$(cat "$d/gen")"
rg=$(( g + $(cat "$d/revoff" 2>/dev/null || echo 0) ))
case "$*" in
*"get istios.sailoperator.io default"*)
	if [ -s "$d/failreads" ] && [ "$(cat "$d/failreads")" -gt 0 ]; then
		echo $(( $(cat "$d/failreads") - 1 )) > "$d/failreads"
		echo 'error: the server is currently unable to handle the request' >&2; exit 1
	fi
	STUB_ISTIO_CR_GEN="$g" STUB_ISTIO_REV_GEN="$rg" exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	STUB_ISTIO_CR_GEN="$g" STUB_ISTIO_REV_GEN="$rg" exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*" patch istio.sailoperator.io default --type=merge --patch-file="*)
	args="$*"; f="${args##*--patch-file=}"; f="${f%% *}"
	jq --slurpfile p "$f" 'def mp($q): if ($q | type) == "object" then reduce ($q | keys_unsorted[]) as $k ((if type == "object" then . else {} end); if $q[$k] == null then del(.[$k]) else .[$k] = (.[$k] | mp($q[$k])) end) else $q end; mp($p[0])' "$d/cr.json" > "$d/cr.new" && mv "$d/cr.new" "$d/cr.json"
	n=1
	if [ ! -f "$d/patched" ]; then
		: > "$d/patched"
		[ -z "${TUN_PATCH_EXTRA:-}" ] || n=2
		[ -z "${TUN_FAIL_AFTER_PATCH:-}" ] || echo "$TUN_FAIL_AFTER_PATCH" > "$d/failreads"
	fi
	echo $((g + n)) > "$d/gen" ;;
*" get istio.sailoperator.io default -o jsonpath={.metadata.generation}"*) echo "$g $g True default" ;;
*" get istio.sailoperator.io default -o jsonpath={.status.activeRevisionName}"*) echo default ;;
*" get istio.sailoperator.io default -o json")
	n=$(( $(cat "$d/crjson" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$d/crjson"
	if [ "$n" = "${TUN_CRJSON_FAIL_AT:-0}" ]; then echo $((g + 1)) > "$d/gen"; exit 1; fi
	jq -c --argjson g "$g" '. + {metadata: {name: "default", generation: $g}}' "$d/cr.json" ;;
*" get istiorevision.sailoperator.io default -o jsonpath="*) echo "$g $g True" ;;
*" rollout status "*)
	if [ -n "${TUN_ROLLOUT_FAIL_ONCE:-}" ] && [ ! -f "$d/rollout-failed" ]; then : > "$d/rollout-failed"; exit 1; fi
	exit 0 ;;
*" apply --server-side "*) : > "$d/applied"; exit 0 ;;
*" delete --ignore-not-found -f "*) rm -f "$d/applied"; exit 0 ;;
*" get --ignore-not-found -f "*) exit 0 ;;
*" -n istio-system get DestinationRule "*|*" -n istio-system get destinationrule"*) [ -f "$d/applied" ] && { echo x; exit 0; }; exit 1 ;;
*" -n istio-system get deployment istiod -o json"*)
	[ -z "${TUN_VERIFY_FAIL:-}" ] || exit 1
	jq -c '{spec: {template: {spec: {containers: [{name: "discovery", env: ((.spec.values.pilot.env // {}) | to_entries | map({name: .key, value: (.value | tostring)}))}]}}}}' "$d/cr.json" ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
}

# gen_sweep [<profile>]: tuning 003 over the churn suite on ci-a, baseline and <profile>
# (default 01-push-throttling, which patches the Istio CR), no setup and no Argo CD pause;
# results under tres/. Sets TDIR.
gen_sweep() {
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" \
		--suite churn --contexts ci-a --no-gitops-pause --skip-setup --keep-workloads \
		--profiles "${1:-01-push-throttling}" --settle 0 --output-dir "${BATS_TEST_TMPDIR}/tres"
	TDIR="$(find "${BATS_TEST_TMPDIR}/tres" -maxdepth 1 -name 'sweep-*' -type d)"
}

@test "istio_generations_diff: any move by default; --cr-over <n> only a rise of more than n, or a fall, of the Istio CR's own; --unchecked the members it could not compare" {
	run istio_generations_diff "ci-a=2/2,ci-b=3/3" "ci-a=2/2,ci-b=4/4"
	assert_output $'1\tci-b (Istio CR generation 3 -> 4, IstioRevision generation 3 -> 4)'
	run istio_generations_diff "ci-a=2/2" "ci-a=2/3"
	assert_output $'0\tci-a (IstioRevision generation 2 -> 3)'
	run istio_generations_diff "ci-a=5/5" "ci-a=1/1"
	assert_output $'1\tci-a (Istio CR generation 5 -> 1, IstioRevision generation 5 -> 1)'
	# One merge patch: a rise of 1 is the sweep's own; the IstioRevision's is left out.
	run istio_generations_diff --cr-over 1 "ci-a=2/2" "ci-a=3/5"
	assert_output ""
	run istio_generations_diff --cr-over 1 "ci-a=2/2" "ci-a=2/2"
	assert_output ""
	run istio_generations_diff --cr-over 1 "ci-a=2/2,ci-b=2/2" "ci-a=3/3,ci-b=4/4"
	assert_output $'1\tci-b (Istio CR generation 2 -> 4)'
	run istio_generations_diff --cr-over 1 "ci-a=5/5" "ci-a=2/2"
	assert_output $'1\tci-a (Istio CR generation 5 -> 2)'
	# A side it could not read is not compared, in any mode; --unchecked names it.
	run istio_generations_diff "ci-a=unknown/unknown,ci-b=2/2" "ci-a=3/3,ci-b=2/2"
	assert_output ""
	run istio_generations_diff --cr-over 1 "ci-a=2/2" "ci-a=unknown/unknown"
	assert_output ""
	run istio_generations_diff --unchecked "ci-a=unknown/unknown,ci-b=2/2" "ci-a=3/3,ci-b=2/unknown"
	assert_output "ci-a (unknown/unknown -> 3/3), ci-b (2/2 -> 2/unknown)"
	run istio_generations_diff --unchecked "ci-a=2/2,ci-b=2/2" "ci-a=2/2,ci-c=1/1"
	assert_output "ci-c (unknown -> 1/1), ci-b (2/2 -> unknown)"
	run istio_generations_diff --unchecked "ci-a=2/2" "ci-a=3/3"
	assert_output ""
	run istio_generations_diff --unchecked "" "ci-a=3/3"
	assert_output "ci-a (unknown -> 3/3)"
}

@test "an edit during the baseline whose read before the apply failed is not left out silently: the sweep notes the member and both reads, on the console and in its outcome" {
	_need_yaml
	_gen_stub
	TUN_FOREIGN_AT=2 TUN_FAIL_READS=2 gen_sweep
	# The probes fail (the stub has no istiod pod): exit 4 for that reason.
	[ "$status" -eq 4 ] || { echo "$stderr"; false; }
	[[ "$stderr" == *"warning: the Istio CR generations of a member could not be compared between the sweep's read at the sweep's start and its read before the apply of pass 01-push-throttling (a read failed): ci-a (2/2 -> unknown/unknown); an edit of its Istio CR in that span by something other than the sweep is not ruled out"* ]] || { echo "$stderr"; false; }
	grep -qx "NOTE=the Istio CR generations of a member could not be compared between the sweep's read at the sweep's start and its read before the apply of pass 01-push-throttling (a read failed): ci-a (2/2 -> unknown/unknown); an edit of its Istio CR in that span by something other than the sweep is not ruled out" "${TDIR}/sweep-outcome.txt"
	grep -qx "NOTE=the Istio CR generations of a member could not be compared between the sweep's read before the apply of pass 01-push-throttling and its read once the apply of pass 01-push-throttling settled (001's istio-generations-applied) (a read failed): ci-a (unknown/unknown -> 4/4); an edit of its Istio CR in that span by something other than the sweep is not ruled out" "${TDIR}/sweep-outcome.txt"
	# The report repeats the notes.
	run --separate-stderr "${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "$TDIR" --format markdown
	assert_output --partial "could not be compared between the sweep's read at the sweep's start and its read before the apply of pass 01-push-throttling"
}

@test "an edit during a pass whose 002 comparison read failed: 002 warns and writes istio-generations-unchecked, which the sweep notes; the revert's own check still finds the rise beyond its merge patch (exit 4)" {
	_need_yaml
	_gen_stub
	TUN_FOREIGN_AT=4 TUN_FAIL_READS=2 gen_sweep
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"warning: the Istio CR generations of a member could not be compared with the ones recorded once the apply of 01-push-throttling settled (a read failed): ci-a (3/3 -> unknown/unknown). An edit of its Istio CR during the pass is not ruled out (istio-generations-unchecked in the state dir). Reverting anyway."* ]] || { echo "$stderr"; false; }
	[ "$(<"${TDIR}/01-push-throttling/state/istio-generations-unchecked")" = "ci-a (3/3 -> unknown/unknown)" ]
	grep -qx "NOTE=the Istio CR generations of a member could not be compared during pass 01-push-throttling (002-revert-profile.sh, istio-generations-unchecked in its state dir): ci-a (3/3 -> unknown/unknown); an edit of its Istio CR during the pass by something other than its profile is not ruled out" "${TDIR}/sweep-outcome.txt"
	grep -q "^PROBLEM=the Istio CR changed beyond the sweep's own edit, between its read after the apply of pass 01-push-throttling and its read after the revert of pass 01-push-throttling: ci-a (Istio CR generation 3 -> 5), not the rise of at most 1 its merge patch accounts for; likely: " "${TDIR}/sweep-outcome.txt"
	[[ "$stderr" == *"error: the Istio CR changed beyond the sweep's own edit"*"; exit 4."* ]]
}

@test "an Istio CR generation that rose by more than 1 across the sweep's own apply is a problem (exit 4): a merge patch raises it by exactly 1" {
	_need_yaml
	_gen_stub
	TUN_PATCH_EXTRA=1 gen_sweep
	[ "$status" -eq 4 ]
	[ "$(grep -c '^PROBLEM=the Istio CR changed' "${TDIR}/sweep-outcome.txt")" -eq 1 ]
	grep -q "^PROBLEM=the Istio CR changed beyond the sweep's own edit, between its read before the apply of pass 01-push-throttling and its read once the apply of pass 01-push-throttling settled (001's istio-generations-applied): ci-a (Istio CR generation 2 -> 4), not the rise of at most 1 its merge patch accounts for; likely: " "${TDIR}/sweep-outcome.txt"
	! grep -q '^NOTE=the Istio CR generations of a member could not be compared' "${TDIR}/sweep-outcome.txt"
}

@test "a profile that leaves the Istio CR alone ({}): an edit between 001's after-apply record and the sweep's own read is one problem, not two (the sweep's read is what 002 compares from)" {
	_need_yaml
	_gen_stub
	TUN_FOREIGN_ON="*get DestinationRule*" gen_sweep 04-connection-pools
	[ "$status" -eq 4 ]
	[ -e "${TD}/foreign-on-done" ]
	[ "$(grep -c '^PROBLEM=the Istio CR changed' "${TDIR}/sweep-outcome.txt")" -eq 1 ] || { cat "${TDIR}/sweep-outcome.txt"; false; }
	grep -q "^PROBLEM=the Istio CR changed while the sweep changed nothing, between its read before the apply of pass 04-connection-pools and its read after the apply of pass 04-connection-pools: ci-a (Istio CR generation 2 -> 3, IstioRevision generation 2 -> 3)" "${TDIR}/sweep-outcome.txt"
	[ "$(<"${TDIR}/04-connection-pools/state/istio-generations-applied")" = ci-a=3/3 ]
	[ ! -e "${TDIR}/04-connection-pools/state/istio-edited-during-pass" ]
	[ ! -e "${TDIR}/04-connection-pools/state/istio-generations-unchecked" ]
}

@test "001 run alone whose read after the apply failed warns that 002 cannot check that member; 002 then warns and writes istio-generations-unchecked; the next apply clears it" {
	_need_yaml
	_gen_stub
	local st="${BATS_TEST_TMPDIR}/state"
	TUN_FAIL_AFTER_PATCH=2 PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/001-apply-profile.sh" \
		--profile "${ROOT}/tests/tuning/profiles/01-push-throttling.yaml" --contexts ci-a --state-dir "$st"
	assert_success
	[[ "$stderr" == *"warn: the Istio CR generations of a member could not be read after the apply settled (ci-a=unknown/unknown): 002 cannot check that member for an edit during the pass, and says so (istio-generations-unchecked)"* ]] || { echo "$stderr"; false; }
	[ "$(<"$st/istio-generations-applied")" = ci-a=unknown/unknown ]
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/002-revert-profile.sh" --state-dir "$st"
	assert_success
	[[ "$stderr" == *"warning: the Istio CR generations of a member could not be compared with the ones recorded once the apply of 01-push-throttling settled (a read failed): ci-a (unknown/unknown -> 3/3)."* ]] || { echo "$stderr"; false; }
	[ "$(<"$st/istio-generations-unchecked")" = "ci-a (unknown/unknown -> 3/3)" ]
	[ ! -e "$st/istio-edited-during-pass" ]
	# A new apply clears it (and the revert's other markers).
	PATH="${BIN}:${PATH}" KUBECONFIG="$EK" run --separate-stderr "${ROOT}/tests/tuning/001-apply-profile.sh" \
		--profile "${ROOT}/tests/tuning/profiles/01-push-throttling.yaml" --contexts ci-a --state-dir "$st"
	assert_success
	[ ! -e "$st/istio-generations-unchecked" ]
	[ ! -e "$st/revert-started" ]
	[ "$(<"$st/istio-generations-applied")" = ci-a=5/5 ]
}

@test "a sweep interrupted after a generation check found a problem, or could not compare a member, keeps it in its not-finished record as a note, and the comparison repeats it (a stop record keeps a problem as one: sweep-stop.bats)" {
	_need_yaml
	_gen_stub
	local want="the Istio CR changed while the sweep changed nothing, between its read at the sweep's start and its read before the apply of pass 01-push-throttling: ci-a (Istio CR generation 2 -> 3, IstioRevision generation 2 -> 3); likely: a version changed and changed back, or a values change (an edit of the Istio CR); the passes run since that first read (baseline) may have measured another configuration, and pass 01-push-throttling may measure another configuration than its profile's"
	# An edit during the baseline pass (found at the read before the apply of 01), then a
	# SIGTERM to the sweep during that apply's merge patch.
	TUN_FOREIGN_AT=2 TUN_TERM_ON="* patch istio.sailoperator.io default --type=merge *" gen_sweep
	[ -e "${TD}/term-sent" ]
	[ "$status" -eq 143 ] || { echo "$stderr"; false; }
	grep -qx 'EXIT=unfinished' "${TDIR}/sweep-outcome.txt"
	grep -qx 'ENDED_SIGNAL=SIGTERM' "${TDIR}/sweep-outcome.txt"
	grep -qxF "NOTE=${want}" "${TDIR}/sweep-outcome.txt" || { cat "${TDIR}/sweep-outcome.txt"; false; }
	! grep -q '^PROBLEM=' "${TDIR}/sweep-outcome.txt" || false
	run --separate-stderr "${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "$TDIR" --format markdown
	assert_output --partial "> - warning: ${want}"
	run --separate-stderr "${ROOT}/tests/tuning/004-compare-profiles.sh" --results-dir "$TDIR" --format text
	assert_output --partial "  warning: ${want}"
	# A member it could not compare (its read before the apply failed): the note.
	rm -rf "$TD" "${BATS_TEST_TMPDIR}/tres"
	_gen_stub
	TUN_FOREIGN_AT=2 TUN_FAIL_READS=2 TUN_TERM_ON="* patch istio.sailoperator.io default --type=merge *" gen_sweep
	[ "$status" -eq 143 ] || { echo "$stderr"; false; }
	grep -qx 'ENDED_SIGNAL=SIGTERM' "${TDIR}/sweep-outcome.txt"
	grep -qx "NOTE=the Istio CR generations of a member could not be compared between the sweep's read at the sweep's start and its read before the apply of pass 01-push-throttling (a read failed): ci-a (2/2 -> unknown/unknown); an edit of its Istio CR in that span by something other than the sweep is not ruled out" "${TDIR}/sweep-outcome.txt"
}

@test "with --cr-over, --unchecked counts only the Istio CR part: a member whose IstioRevision alone was not read is compared (either flag order)" {
	run istio_generations_diff --cr-over 1 --unchecked "ci-a=2/2" "ci-a=3/unknown"
	assert_output ""
	run istio_generations_diff --unchecked --cr-over 1 "ci-a=2/unknown" "ci-a=3/3"
	assert_output ""
	run istio_generations_diff --cr-over 1 --unchecked "ci-a=2/2" "ci-a=unknown/3"
	assert_output "ci-a (2/2 -> unknown/3)"
	run istio_generations_diff --unchecked "ci-a=2/2" "ci-a=3/unknown"
	assert_output "ci-a (2/2 -> 3/unknown)"
}

@test "an IstioRevision rendered again, or an Istio CR edit, after 001 recorded the generations once a profile's apply settled and before the sweep's own read is one problem: the span is split at 001's record and compared in full after it" {
	_need_yaml
	_gen_stub
	local p=01-push-throttling
	# 001's verification reads the istiod Deployment after its record: Sail renders the
	# IstioRevision again then (an OSSM operator upgrade, a TLS profile change).
	TUN_BUMP_ON="*-n istio-system get deployment istiod -o json*" TUN_BUMP_REV=1 gen_sweep "$p"
	[ "$status" -eq 4 ]
	[ -e "${TD}/bump-done" ]
	[ "$(grep -c '^PROBLEM=' "${TDIR}/sweep-outcome.txt")" -eq 1 ] || { cat "${TDIR}/sweep-outcome.txt"; false; }
	grep -qF "PROBLEM=the Istio CR changed while the sweep changed nothing, between its read once the apply of pass ${p} settled (001's istio-generations-applied) and its read after the apply of pass ${p}: ci-a (IstioRevision generation 3 -> 4); likely: only the IstioRevision moved" "${TDIR}/sweep-outcome.txt" \
		|| { cat "${TDIR}/sweep-outcome.txt"; false; }
	# 002 compares from the sweep's read, so it does not report it again.
	[ "$(<"${TDIR}/${p}/state/istio-generations-applied")" = ci-a=3/4 ]
	[ ! -e "${TDIR}/${p}/state/istio-edited-during-pass" ]
	# An edit of the Istio CR there (a total rise of 2 across the apply: not absorbed).
	rm -rf "$TD" "${BATS_TEST_TMPDIR}/tres"
	_gen_stub
	TUN_BUMP_ON="*-n istio-system get deployment istiod -o json*" gen_sweep "$p"
	[ "$status" -eq 4 ]
	[ "$(grep -c '^PROBLEM=' "${TDIR}/sweep-outcome.txt")" -eq 1 ] || { cat "${TDIR}/sweep-outcome.txt"; false; }
	grep -qF "PROBLEM=the Istio CR changed while the sweep changed nothing, between its read once the apply of pass ${p} settled (001's istio-generations-applied) and its read after the apply of pass ${p}: ci-a (Istio CR generation 3 -> 4, IstioRevision generation 3 -> 4); likely: " "${TDIR}/sweep-outcome.txt" \
		|| { cat "${TDIR}/sweep-outcome.txt"; false; }
	[ "$(<"${TDIR}/${p}/state/istio-generations-applied")" = ci-a=4/4 ]
}

@test "an apply that failed after 001's record (its verification) gets the same split; one that failed before its first patch counts no patch of its own; one that failed before its record leaves none, and its unchecked span is named up to its revert" {
	_need_yaml
	_gen_stub
	local p=01-push-throttling
	# Verification fails (exit 2) after 001's record; the Istio CR is edited at that read.
	TUN_VERIFY_FAIL=1 TUN_BUMP_ON="*-n istio-system get deployment istiod -o json*" gen_sweep "$p"
	[ "$status" -eq 4 ]
	[ -e "${TDIR}/${p}/SETUP_FAILED" ]
	[ "$(grep -c '^PROBLEM=' "${TDIR}/sweep-outcome.txt")" -eq 1 ] || { cat "${TDIR}/sweep-outcome.txt"; false; }
	grep -qF "PROBLEM=the Istio CR changed while the sweep changed nothing, between its read once the apply of pass ${p} settled (001's istio-generations-applied) and its read after the failed apply of pass ${p}: ci-a (Istio CR generation 3 -> 4, IstioRevision generation 3 -> 4)" "${TDIR}/sweep-outcome.txt" \
		|| { cat "${TDIR}/sweep-outcome.txt"; false; }
	[ "$(<"${TDIR}/${p}/state/istio-generations-applied")" = ci-a=4/4 ]
	# 001 stops before its first patch (it cannot read the Istio CR, and someone else edits
	# it then): no active-profile, so the sweep's read compares it in full.
	rm -rf "$TD" "${BATS_TEST_TMPDIR}/tres"
	_gen_stub
	TUN_CRJSON_FAIL_AT=2 gen_sweep "$p"
	[ "$status" -eq 4 ]
	[ ! -e "${TDIR}/${p}/state/active-profile" ]
	[ "$(grep -c '^PROBLEM=' "${TDIR}/sweep-outcome.txt")" -eq 1 ] || { cat "${TDIR}/sweep-outcome.txt"; false; }
	grep -qF "PROBLEM=the Istio CR changed while the sweep changed nothing, between its read before the apply of pass ${p} and its read after the failed apply of pass ${p}: ci-a (Istio CR generation 2 -> 3, IstioRevision generation 2 -> 3)" "${TDIR}/sweep-outcome.txt" \
		|| { cat "${TDIR}/sweep-outcome.txt"; false; }
	# Its rollout wait fails after the patch: no record, and the sweep writes none (Sail may
	# still render); the note names the span from the failed apply to its revert.
	rm -rf "$TD" "${BATS_TEST_TMPDIR}/tres"
	_gen_stub
	TUN_ROLLOUT_FAIL_ONCE=1 gen_sweep "$p"
	[ "$status" -eq 4 ]
	[ -e "${TDIR}/${p}/SETUP_FAILED" ]
	[ ! -e "${TDIR}/${p}/state/istio-generations-applied" ]
	grep -qxF "NOTE=the Istio CR generations of a member could not be compared between the failed apply of pass ${p} and its revert (002-revert-profile.sh, istio-generations-unchecked in its state dir): every member (no istio-generations-applied in the state dir); an edit of its Istio CR in that span by something other than its profile is not ruled out" "${TDIR}/sweep-outcome.txt" \
		|| { cat "${TDIR}/sweep-outcome.txt"; false; }
	! grep -q "during pass ${p}" "${TDIR}/sweep-outcome.txt" || false
	! grep -q '^PROBLEM=' "${TDIR}/sweep-outcome.txt"
}

@test "an apply that failed after 001's record: an edit before its revert is 002's problem, named for that span (no probe ran)" {
	_need_yaml
	_gen_stub
	local p=01-push-throttling
	# The fifth IstioRevision read is 002's comparison read (two by the sweep before the
	# apply, 001's record, the sweep's after the failed apply): Sail renders it again then.
	TUN_VERIFY_FAIL=1 TUN_BUMP_ON="*get istiorevisions.sailoperator.io*" TUN_BUMP_AT=5 gen_sweep "$p"
	[ "$status" -eq 4 ]
	[ -e "${TDIR}/${p}/SETUP_FAILED" ]
	[ "$(grep -c '^PROBLEM=' "${TDIR}/sweep-outcome.txt")" -eq 1 ] || { cat "${TDIR}/sweep-outcome.txt"; false; }
	grep -qF "PROBLEM=the Istio CR changed between the failed apply of pass ${p} and its revert, not by its profile: ci-a (IstioRevision generation 3 -> 4); likely: only the IstioRevision moved" "${TDIR}/sweep-outcome.txt" \
		|| { cat "${TDIR}/sweep-outcome.txt"; false; }
	grep -qF "; its probes did not run, and no pass runs after it (002-revert-profile.sh, istio-edited-during-pass in its state dir)" "${TDIR}/sweep-outcome.txt"
}

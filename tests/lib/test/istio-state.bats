#!/usr/bin/env bats
# The Istio version the members run (tests/lib/preamble.sh, PL39): what istio_live_version
# reads, what istio_version_resolve records and when it stops a run, what
# istio_version_recheck finds changed at a sweep's end, and both through controlplane 003
# (PL33). No cluster: kubectl is a stub over fixtures/fake-istio-cr.sh.

bats_require_minimum_version 1.5.0
load test_helper
source "${ROOT}/tests/lib/preamble.sh"

FAKE_CR="${ROOT}/tests/lib/test/fixtures/fake-istio-cr.sh"

setup() {
	export KLOG="${BATS_TEST_TMPDIR}/kubectl.log" ISTIO_VERSION=v1.30.5 ISTIO_VERSION_READY_WAIT_SEC=0
	: > "$KLOG"
	unset ISTIO_VERSION_CHECK ISTIO_VERSION_PIN ISTIO_VERSION_SOURCE _ISTIO_VERSION_RESOLVED
}

# _ivk <kubectl args...>: fake-istio-cr.sh per member <c> (its --context): V_<c> the version
# it runs (unset: every read fails), R_<c> its active revision, D_<c> its istiod
# Deployment's status, the file state-<c> its Istio CR's state (default Healthy); `wait` (the
# readiness wait) sets that file to W_<c> (default Healthy). Logs each call to KLOG.
_ivk() {
	local a c="" v r d w
	for a in "$@"; do [[ "$a" != --context=* ]] || c="${a#--context=}"; done
	echo "$*" >> "$KLOG"
	v="V_${c}" r="R_${c}" d="D_${c}" w="W_${c}"
	if [[ " $* " == *" wait "* ]]; then
		echo "${!w:-Healthy}" > "${BATS_TEST_TMPDIR}/state-${c}"
		return 0
	fi
	STUB_ISTIO_VERSION="${!v:-fail}" STUB_ISTIO_REV="${!r:-default}" STUB_ISTIOD_STATUS="${!d:-}" \
		STUB_ISTIO_STATE="$(cat "${BATS_TEST_TMPDIR}/state-${c}" 2>/dev/null || echo Healthy)" "$FAKE_CR" "$@"
}

# _conc_ivk: _ivk, counting the reads in flight (dirs under running/) as each starts, in counts.
_conc_ivk() {
	local a c=""
	for a in "$@"; do [[ "$a" != --context=* ]] || c="${a#--context=}"; done
	mkdir -p "${BATS_TEST_TMPDIR}/running/${c}"
	find "${BATS_TEST_TMPDIR}/running" -mindepth 1 -maxdepth 1 -type d | wc -l >> "${BATS_TEST_TMPDIR}/counts"
	sleep 0.1
	rmdir "${BATS_TEST_TMPDIR}/running/${c}"
	_ivk "$@"
}

# state <ctx> <state>: the Istio CR state of <ctx> from now on.
state() { echo "$2" > "${BATS_TEST_TMPDIR}/state-$1"; }

# resolve_kv <args...>: istio_version_resolve <args...> with the stub (IVK, default _ivk),
# then the keys it records and the sweep notes it left.
resolve_kv() {
	istio_version_resolve "$@" "${IVK:-_ivk}" || return
	istio_version_kv
	printf 'NOTE=%s\n' ${_SWEEP_NOTES[@]+"${_SWEEP_NOTES[@]}"}
}

# recheck <args...>: resolve every member in V_* (a,b), apply the END_* settings, recheck,
# and print the sweep's problems and notes.
recheck() {
	istio_version_resolve a,b 0 _ivk 2>/dev/null
	eval "${END_SET:-:}"
	istio_version_recheck "$@" _ivk 2>/dev/null
	printf 'PROBLEM=%s\n' ${_SWEEP_PROBLEMS[@]+"${_SWEEP_PROBLEMS[@]}"}
	printf 'NOTE=%s\n' ${_SWEEP_NOTES[@]+"${_SWEEP_NOTES[@]}"}
}

@test "istio_live_version reads the active IstioRevision's exact version (InPlace or RevisionBased) in bounded reads, never the Istio CR's alias" {
	V_a=v1.30.5 run --separate-stderr istio_live_version a _ivk
	assert_output "v1.30.5|default|2|2|yes|"
	run cat "$KLOG"
	assert_line "--context=a --request-timeout=5s get istios.sailoperator.io default -o json"
	assert_line "--context=a --request-timeout=5s get istiorevisions.sailoperator.io default -o json"
	assert_line "--context=a --request-timeout=5s -n istio-system get deployments.apps istiod -o json"
	V_a=1.30.5 R_a=default-v1-30-5 run --separate-stderr istio_live_version a _ivk
	assert_output "1.30.5|default-v1-30-5|2|2|yes|"
	grep -q -- '-n istio-system get deployments.apps istiod-default-v1-30-5 -o json' "$KLOG"
	V_a=v1.30-latest run --separate-stderr istio_live_version a _ivk
	assert_output "unknown|default|2|2|yes|the IstioRevision default names no exact version (v1.30-latest)"
}

@test "a member not ready still reads its version, with why it is not ready (its Istio CR's state, an istiod rollout)" {
	state a IstiodNotReady
	V_a=v1.30.5 run istio_live_version a _ivk
	assert_output "v1.30.5|default|2|2|no|Istio CR state is IstiodNotReady"
	state a Healthy
	V_a=v1.30.5 D_a='{"replicas":2,"updatedReplicas":1}' run istio_live_version a _ivk
	assert_output "v1.30.5|default|2|2|no|istiod is rolling out (1 of 2 pods updated)"
	# Sail's Healthy counts ready pods only: an old pod still terminating can serve.
	V_a=v1.30.5 D_a='{"replicas":2,"updatedReplicas":2,"terminatingReplicas":1}' run istio_live_version a _ivk
	assert_output "v1.30.5|default|2|2|no|istiod is rolling out (2 of 2 pods updated, 1 terminating)"
}

@test "a read that fails is unknown and not ready; kubectl's error goes to the console only, never into the line the results record" {
	run --separate-stderr istio_live_version a _ivk
	assert_success
	assert_output "unknown|unknown|unknown|unknown|no|the Istio CR could not be read (kubectl exit 1)"
	[ "$stderr" = "warning: a: kubectl get istios.sailoperator.io default failed (exit 1): error: You must be logged in to the server (Unauthorized)" ]
}

@test "istio_version_resolve records the version every member runs, at the pin (a leading v aside), with each member's version, active revision and generations" {
	V_a=v1.30.5 V_b=v1.30.5 R_b=default-v1-30-5 ISTIO_VERSION=1.30.5 run --separate-stderr resolve_kv a,b 0
	assert_success
	[ -z "$stderr" ]
	assert_output "$(printf '%s\n' ISTIO_VERSION=v1.30.5 ISTIO_VERSION_PIN=1.30.5 ISTIO_VERSION_SOURCE=live \
		ISTIO_VERSION_BY_CONTEXT=a=v1.30.5,b=v1.30.5 ISTIO_ACTIVE_REVISIONS=a=default,b=default-v1-30-5 \
		ISTIO_GENERATIONS=a=2/2,b=2/2 NOTE=)"
}

@test "a version other than the pin stops the run before any change under fail (the default); warn records the live version, warns and notes it" {
	V_a=v1.29.0 run --separate-stderr resolve_kv a 0
	assert_failure 1
	[[ "$stderr" == *"the members run Istio v1.29.0, not the pin ISTIO_VERSION=v1.30.5"* ]]
	[[ "$stderr" == *"Nothing was changed."* ]]
	ISTIO_VERSION_CHECK=warn V_a=v1.29.0 run --separate-stderr resolve_kv a 0
	assert_success
	assert_line ISTIO_VERSION=v1.29.0
	assert_line ISTIO_VERSION_PIN=v1.30.5
	assert_line --partial "NOTE=Istio version check at the start: the members run Istio v1.29.0, not the pin"
	[[ "$stderr" == *"Going on (ISTIO_VERSION_CHECK=warn): the results record ISTIO_VERSION=v1.29.0 (pin v1.30.5)."* ]]
}

@test "members that differ, or one whose version cannot be read, never record one member's value" {
	V_a=v1.30.5 V_b=v1.29.0 run --separate-stderr resolve_kv a,b 0
	assert_failure 1
	[[ "$stderr" == *"the members run different Istio versions (a=v1.30.5,b=v1.29.0)"* ]]
	ISTIO_VERSION_CHECK=warn V_a=v1.30.5 V_b=v1.29.0 run --separate-stderr resolve_kv a,b 0
	assert_line ISTIO_VERSION=mixed:v1.30.5/v1.29.0
	ISTIO_VERSION_CHECK=warn V_a=v1.30.5 run --separate-stderr resolve_kv a,b 0
	assert_success
	assert_line ISTIO_VERSION=mixed:v1.30.5/unknown
	assert_line ISTIO_VERSION_BY_CONTEXT=a=v1.30.5,b=unknown
	assert_line "NOTE=Istio version check at the start: b: the version it runs is unknown: the Istio CR could not be read (kubectl exit 1)"
}

@test "a member not ready gets one wait for its Istio CR's Ready condition and one more read: ready then, the run goes on; still not ready, it stops (warn records and notes it)" {
	export ISTIO_VERSION_READY_WAIT_SEC=5
	state b IstiodNotReady
	V_a=v1.30.5 V_b=v1.30.5 run --separate-stderr resolve_kv a,b 0
	assert_success
	assert_line ISTIO_VERSION=v1.30.5
	[ "$(grep -c ' wait --for=condition=Ready istios.sailoperator.io/default ' "$KLOG")" -eq 1 ]
	grep -qE -- '--context=b wait --for=condition=Ready istios.sailoperator.io/default --timeout=[0-5]s' "$KLOG"
	[ "$(grep -c -- '--context=b --request-timeout=5s get istios.sailoperator.io default' "$KLOG")" -eq 2 ]
	[ "$(grep -c -- '--context=a --request-timeout=5s get istios.sailoperator.io default' "$KLOG")" -eq 1 ]
	state b IstiodNotReady
	V_a=v1.30.5 V_b=v1.30.5 W_b=IstiodNotReady run --separate-stderr resolve_kv a,b 0
	assert_failure 1
	[[ "$stderr" == *"b: not ready (Istio CR state is IstiodNotReady) after a wait of up to 5s"* ]]
	ISTIO_VERSION_CHECK=warn V_a=v1.30.5 V_b=v1.30.5 W_b=IstiodNotReady run --separate-stderr resolve_kv a,b 0
	assert_success
	assert_line ISTIO_VERSION=v1.30.5
	assert_line "NOTE=Istio version check at the start: b: not ready (Istio CR state is IstiodNotReady) after a wait of up to 5s"
}

@test "--no-stop (a read-only check) warns and goes on under fail" {
	V_a=v1.29.0 run --separate-stderr resolve_kv --no-stop a 0
	assert_success
	assert_line ISTIO_VERSION=v1.29.0
	[[ "$stderr" == *"Going on (a read-only check never stops on this)"* ]]
}

@test "--dry-run reads nothing and records the pin; a step under its sweep reuses the sweep's read" {
	V_a=v1.29.0 run --separate-stderr resolve_kv a 1
	assert_success
	assert_output "$(printf '%s\n' ISTIO_VERSION=v1.30.5 ISTIO_VERSION_PIN=v1.30.5 ISTIO_VERSION_SOURCE=pin \
		ISTIO_VERSION_BY_CONTEXT=unchecked ISTIO_ACTIVE_REVISIONS=unchecked ISTIO_GENERATIONS=unchecked NOTE=)"
	[ ! -s "$KLOG" ]
	export _ISTIO_VERSION_RESOLVED=1 ISTIO_VERSION_SOURCE=live ISTIO_VERSION=v1.29.0 ISTIO_VERSION_PIN=v1.30.5 \
		ISTIO_VERSION_BY_CONTEXT=a=v1.29.0 ISTIO_ACTIVE_REVISIONS=a=default ISTIO_GENERATIONS=a=4/4
	V_a=v1.30.5 run --separate-stderr resolve_kv a 0
	assert_success
	assert_line ISTIO_VERSION=v1.29.0
	assert_line ISTIO_GENERATIONS=a=4/4
	[ ! -s "$KLOG" ]
}

@test "an ISTIO_VERSION_CHECK other than fail or warn, or a wait that is not whole seconds, is refused" {
	ISTIO_VERSION_CHECK=off V_a=v1.30.5 run --separate-stderr resolve_kv a 0
	assert_failure 1
	[[ "$stderr" == *"ISTIO_VERSION_CHECK must be fail or warn (got: off)"* ]]
	ISTIO_VERSION_READY_WAIT_SEC=1m V_a=v1.30.5 run --separate-stderr resolve_kv a 0
	assert_failure 1
	[[ "$stderr" == *"ISTIO_VERSION_READY_WAIT_SEC must be a non-negative integer"* ]]
	[ ! -s "$KLOG" ]
}

@test "the members are read PLATFORM_READ_PARALLEL at a time" {
	export V_m0=v1.30.5 V_m1=v1.30.5 V_m2=v1.30.5 V_m3=v1.30.5
	PLATFORM_READ_PARALLEL=2 IVK=_conc_ivk run --separate-stderr resolve_kv m0,m1,m2,m3 0
	assert_success
	assert_line ISTIO_VERSION_BY_CONTEXT=m0=v1.30.5,m1=v1.30.5,m2=v1.30.5,m3=v1.30.5
	[ "$(wc -l < "${BATS_TEST_TMPDIR}/counts")" -eq 12 ]
	[ "$(sort -n "${BATS_TEST_TMPDIR}/counts" | tail -n 1 | tr -d ' ')" -le 2 ]
}

@test "istio_version_recheck: another version or active revision at the end is a problem; a member it cannot confirm is a note" {
	export V_a=v1.30.5 V_b=v1.30.5
	run recheck
	assert_output "$(printf '%s\n' PROBLEM= NOTE=)"
	END_SET='V_b=v1.31.0 R_b=default-v1-31-0' run recheck
	assert_line "PROBLEM=b ran v1.30.5 (revision default) at the start and v1.31.0 (revision default-v1-31-0) at the end: its rows are not all from one Istio version"
	END_SET='unset V_b' run recheck
	assert_output "$(printf '%s\n' PROBLEM= "NOTE=could not confirm that b ran one Istio version during the sweep: the Istio CR could not be read (kubectl exit 1)")"
	# Unknown at the start (warn went on): a note at the end, never a change.
	ISTIO_VERSION_CHECK=warn END_SET='V_b=v1.30.5' V_b= run recheck
	assert_line "NOTE=could not confirm that b ran one Istio version during the sweep: it was unknown at the start"
	refute_line --partial "PROBLEM=b"
}

@test "istio_version_recheck: generations that moved at the same version are a problem (an edit of the Istio CR), not with --no-generations; not ready at the end is a note" {
	export V_a=v1.30.5 V_b=v1.30.5
	END_SET='export STUB_ISTIO_CR_GEN=3' run recheck
	assert_line "PROBLEM=the Istio CR or its active IstioRevision on a changed during the sweep (generations 2/2 -> 3/2): an edit of the Istio CR or Sail rendering it again; rows after it may measure another configuration"
	[ "$(grep -c '^PROBLEM=.' <<<"$output")" -eq 2 ]
	END_SET='export STUB_ISTIO_CR_GEN=3' run recheck --no-generations
	assert_output "$(printf '%s\n' PROBLEM= NOTE=)"
	END_SET='state b IstiodNotReady' run recheck
	assert_output "$(printf '%s\n' PROBLEM= "NOTE=b was not ready at the end of the sweep: Istio CR state is IstiodNotReady")"
}

@test "istio_generations_read and istio_generations_diff: each member's ctx=<Istio CR>/<IstioRevision> generations, and those that moved (a side not read is not compared)" {
	V_a=v1.30.5 STUB_ISTIO_REV_GEN=5 run --separate-stderr istio_generations_read a,b _ivk
	assert_output "a=2/5,b=unknown/unknown"
	run istio_generations_diff "a=2/2,b=3/3,c=unknown/unknown" "a=2/2,b=3/4,c=4/4"
	assert_output "b (3/3 -> 3/4)"
	run istio_generations_diff "a=2/2,b=3/3" "a=3/3,b=4/3"
	assert_output "a (2/2 -> 3/3), b (3/3 -> 4/3)"
	run istio_generations_diff "a=2/2" "a=2/2"
	assert_output ""
}

# cp_stub: a kubectl for controlplane 003 on PATH: the Istio CR reads as fake-istio-cr.sh, the
# Istio CR's generation from crgen (default 2), which bump (when it exists) replaces right after
# the first read; CP_FAIL_LINE: every Istio CR read fails with that stderr line. Any other call
# fails, as against an empty kubeconfig.
cp_stub() {
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	cat > "${BIN}/kubectl" <<'STUB'
#!/bin/sh
d="$CP_DIR"
case "$*" in
*"get istios.sailoperator.io default"*|*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	[ -z "${CP_FAIL_LINE:-}" ] || { echo "$CP_FAIL_LINE" >&2; exit 1; }
	STUB_ISTIO_CR_GEN="$(cat "$d/crgen" 2>/dev/null || echo 2)"
	export STUB_ISTIO_CR_GEN
	case "$*" in *"get istios.sailoperator.io default"*) [ ! -f "$d/bump" ] || mv "$d/bump" "$d/crgen" ;; esac
	exec "$ROOT/tests/lib/test/fixtures/fake-istio-cr.sh" "$@" ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${BIN}/kubectl"
	: > "${BATS_TEST_TMPDIR}/kubeconfig"
	export CP_DIR="$BATS_TEST_TMPDIR"
}

# cp_sweep: controlplane 003 on ci-a with the stub, ISTIO_VERSION_CHECK=warn, its results
# under res/; output and stderr together. Sets D (the sweep dir).
cp_sweep() {
	PATH="${BIN}:${PATH}" KUBECONFIG="${BATS_TEST_TMPDIR}/kubeconfig" CONTROLPLANE_RESULTS_DIR="${BATS_TEST_TMPDIR}/res" \
		ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 \
		run bash "${ROOT}/tests/controlplane/003-run-sweep.sh" --contexts ci-a --mesh-sizes 1 --service-counts 5
	D="$(find "${BATS_TEST_TMPDIR}/res" -maxdepth 1 -name 'sweep-*' -type d)"
}

@test "through controlplane 003, an Istio CR edited during the sweep is a problem of its outcome (exit 4), and its TSV records the generations it started on" {
	cp_stub
	echo 3 > "${BATS_TEST_TMPDIR}/bump"
	cp_sweep
	assert_failure 4
	grep -qx '# ISTIO_GENERATIONS=ci-a=2/2' "$(find "$D" -maxdepth 1 -name 'controlplane-*.tsv')"
	grep -qxF "PROBLEM=the Istio CR or its active IstioRevision on ci-a changed during the sweep (generations 2/2 -> 3/2): an edit of the Istio CR or Sail rendering it again; rows after it may measure another configuration" "$D/sweep-outcome.txt"
}

@test "through controlplane 003, the error of a read that fails is on the console only: the sweep dir names no API host or address" {
	cp_stub
	CP_FAIL_LINE='Unable to connect to the server: dial tcp: lookup api.ci-a.example on 192.0.2.53:53: no such host' cp_sweep
	assert_failure 4
	assert_output --partial "lookup api.ci-a.example on 192.0.2.53:53: no such host"
	grep -qx 'NOTE=Istio version check at the start: ci-a: the version it runs is unknown: the Istio CR could not be read (kubectl exit 1)' "$D/sweep-outcome.txt"
	! grep -rqF -e "api.ci-a.example" -e "192.0.2.53" "$D" || false
}

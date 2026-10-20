#!/usr/bin/env bats
# A harness file a setup step renders (its suite's chart) or reads (a tuning profile),
# changed for that step and undone before the sweep's next read, reaches the sweep's
# outcome: each setup step reads the harness right after (tests/lib/common.sh harness_read
# under a sweep: HARNESS_SWEEP_LOG). A sweep whose step log is gone at its end check (a
# temp-file cleaner), or could not be made at its start, says so in a note. Through the
# real controlplane sweep and every real setup step in a copy of the checkout (PL33); no
# cluster: kubectl is a stub. harness-steps.bats covers the probes' reads.

bats_require_minimum_version 1.5.0
load test_helper
load harness_helper

setup() {
	export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
	mkdir -p "$TMPDIR"
}

# _problem <record> <clean> <step>: the record's PROBLEM names <step>'s read of a dirty
# harness (<clean>-dirty.<8 hex>) between the sweep's start and end reads, which gave <clean>.
_problem() {
	grep -qE "^PROBLEM=the harness changed during the sweep, and back: HARNESS_SHA=${2} at its start and at its end, but ${3//./\\.} recorded HARNESS_SHA=${2}-dirty\.[0-9a-f]{8} at [0-9T:-]+Z, so the step that read it, and the other steps run after the change, may have run other code than ${2}: " "$1" \
		|| { cat "$1"; false; }
}

@test "repro through the controlplane sweep: a chart file its setup step adds and removes, read by that step only (no sweep read between), is a PROBLEM naming 001-setup-controlplane-test.sh (exit 4)" {
	local r="${BATS_TEST_TMPDIR}/cp" bin="${BATS_TEST_TMPDIR}/bin" ek="${BATS_TEST_TMPDIR}/kubeconfig" res="${BATS_TEST_TMPDIR}/res" clean d
	_suite_copy "$r" controlplane
	# 001 stand-in: the chart edit is there while it renders (and reads the harness, as the
	# real one does after its render), gone when it ends; 005 stand-in: nothing to remove.
	cat > "$r/tests/controlplane/001-setup-controlplane-test.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${ROOT}/tests/lib/common.sh"
printf 'x\n' > "${ROOT}/tests/controlplane/chart/zz-edit.yaml"
harness_read _hs _hk
rm -f "${ROOT}/tests/controlplane/chart/zz-edit.yaml"
EOF
	printf '#!/bin/sh\nexit 0\n' > "$r/tests/controlplane/005-cleanup.sh"
	git -C "$r" add -A
	git -C "$r" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -q -m stand-ins
	clean="$(ROOT="$r" harness_sha)"
	: > "$ek"
	mkdir -p "$bin"
	# The Istio CR reads answer as fake-istio-cr.sh, one istiod pod whose metrics are a fixture.
	cat > "${bin}/kubectl" <<'STUB'
#!/bin/sh
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*) exec "$HS_FAKE_CR" "$@" ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running "*) printf 'istiod-abc-x1\n' ;;
*" -o json "*) cat "$HS_FX/empty_list.json" ;;
*) exit 1 ;;
esac
STUB
	cat > "${bin}/curl" <<'STUB'
#!/bin/sh
out="" url=""
while [ $# -gt 0 ]; do
	case "$1" in
	-o) out="$2"; shift 2 ;;
	http://*) url="$1"; shift ;;
	*) shift ;;
	esac
done
case "$url" in
*/metrics) body="$HS_FX/pre_metrics.txt" ;;
*/ready) echo LIVE; exit 0 ;;
*/debug/syncz) echo '[]'; exit 0 ;;
*) exit 7 ;;
esac
if [ -n "$out" ]; then cp "$body" "$out"; else cat "$body"; fi
STUB
	chmod +x "${bin}/kubectl" "${bin}/curl"
	HS_FAKE_CR="${ROOT}/tests/lib/test/fixtures/fake-istio-cr.sh" HS_FX="${ROOT}/tests/lib/test/fixtures/istiod-diag" \
		HARNESS_SHA_CHECK_SEC=3600 ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 \
		ISTIO_VERSION_READY_WAIT_SEC=0 PATH="${bin}:${PATH}" KUBECONFIG="$ek" CONTROLPLANE_RESULTS_DIR="$res" \
		run --separate-stderr bash "$r/tests/controlplane/003-run-sweep.sh" --contexts ci-a --mesh-sizes 1 --service-counts 5 --config-dump-samples 0
	[ "$status" -eq 4 ] || { echo "status ${status}: ${stderr}"; false; }
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	[ -z "$(git -C "$r" status --porcelain)" ]
	grep -qx 'EXIT=4' "$d/sweep-outcome.txt"
	_problem "$d/sweep-outcome.txt" "$clean" 001-setup-controlplane-test.sh
	[ -z "$(ls -A "$TMPDIR")" ]
}

# _setup_step <suite> <step> <edit> [<args>...]: the real setup step tests/<suite>/<step>
# (--dry-run <args>) in a sweep's shell, in a copy of the checkout where a file in
# tests/<suite>/<edit>/ is present only while the step renders its chart (reads a profile):
# the record's PROBLEM names <step>. kubectl: a client-side dry-run apply takes the render;
# any other call fails (no context in the kubeconfig). helm and python3: the edit appears
# when a chart is rendered (a profile is read), then the real tool runs.
_setup_step() {
	local suite="$1" step="$2" edit="$3" bin="${BATS_TEST_TMPDIR}/bin" ek="${BATS_TEST_TMPDIR}/kubeconfig" r clean
	shift 3
	if [[ ! -e "${bin}/kubectl" ]]; then
		: > "$ek"
		mkdir -p "$bin"
		printf '#!/bin/sh\ncase " $* " in *" apply --dry-run=client "*) cat >/dev/null; exit 0 ;; esac\nexit 1\n' > "${bin}/kubectl"
		printf '#!/bin/sh\n[ "$1" != template ] || printf "x\\n" > "$HS_EDIT"\nexec %q "$@"\n' "$(command -v helm)" > "${bin}/helm"
		printf '#!/bin/sh\ncase " $* " in *" load "*) printf "x\\n" > "$HS_EDIT" ;; esac\nexec %q "$@"\n' "$(command -v python3)" > "${bin}/python3"
		chmod +x "${bin}/kubectl" "${bin}/helm" "${bin}/python3"
	fi
	r="${BATS_TEST_TMPDIR}/${suite}"
	_suite_copy "$r" "$suite"
	clean="$(ROOT="$r" harness_sha)"
	# A sweep's shell: its start read, the step (dry run), the edit undone, its end.
	HS_EDIT="$r/tests/${suite}/${edit}/zz-edit.yaml" HARNESS_SHA_CHECK_SEC=3600 PATH="${bin}:${PATH}" KUBECONFIG="$ek" \
		run --separate-stderr bash -c '
		source "$1/tests/lib/common.sh"
		ROOT="$1"
		harness_sha_for_sweep "$1/tests/out"
		sweep_outcome_start "$1/tests/out/rec" st-run
		"$1/tests/$2" --dry-run "${@:3}" || { echo "step failed: $?" >&2; exit 9; }
		rm -f "$HS_EDIT"
		sweep_outcome --run-id st-run --record "$1/tests/out/rec" 1' _ "$r" "${suite}/${step}" "$@"
	[ "$status" -eq 4 ] || { echo "${suite}: status ${status}: ${stderr}"; false; }
	# The edit is undone: only the sweep's own output is new.
	[ "$(git -C "$r" status --porcelain)" = "?? tests/out/" ] || { git -C "$r" status --porcelain; false; }
	_problem "$r/tests/out/rec/sweep-outcome.txt" "$clean" "$step"
}

@test "every real setup step that renders a chart (controlplane, dataplane, churn, churn-dataplane, propagation) reads the harness after its render: a chart file present only while it rendered is a PROBLEM naming it" {
	command -v helm >/dev/null 2>&1 || skip "helm is needed (the setup steps render their charts)"
	local s suite step edit args
	local -a steps=(
		"controlplane 001-setup-controlplane-test.sh chart --contexts ci-a"
		"dataplane 001-setup-dataplane-test.sh chart --source-context ci-a --remote-contexts ci-b"
		"churn 001-setup-churn-test.sh chart --contexts ci-a"
		"churn-dataplane 001-setup-coexec-test.sh chart --source-context ci-a"
		"propagation 001-setup-propagation-test.sh chart --contexts ci-a"
	)
	for s in "${steps[@]}"; do
		read -r suite step edit args <<<"$s"
		# shellcheck disable=SC2086  # args: the step's flags
		_setup_step "$suite" "$step" "$edit" $args
	done
}

@test "the tuning setup step (001-apply-profile.sh) reads the harness after it reads its profile: a profile file present only while it was read is a PROBLEM naming it" {
	python3 -I -c 'import yaml' 2>/dev/null || skip "python3 with PyYAML is needed (the tuning lib reads the profile)"
	_setup_step tuning 001-apply-profile.sh profiles --profile 01-push-throttling --contexts ci-a
}

@test "a step log a temp-file cleaner removed during the sweep, or that its start could not create, is a NOTE (and a warning) in the finished and in the interrupted record" {
	local r="${BATS_TEST_TMPDIR}/repo" rec note
	mkdir -p "$r/tests"
	printf 'one\n' > "$r/tests/f"
	cp "${ROOT}/.gitignore" "$r/.gitignore"
	_commit "$r" init
	rec="$r/tests/out/rec/sweep-outcome.txt"
	note="the steps' own harness reads could not be checked: the temp file they are added to (HARNESS_SWEEP_LOG) was gone at the end check (removed during the sweep, as a temp-file cleaner does), so a harness change that only a step read (undone before the sweep's next read) is not in its outcome"
	# Finished: a note, not a problem (exit 0).
	run --separate-stderr bash -c '
		source "$2/tests/lib/common.sh"
		ROOT="$1"
		harness_sha_for_sweep "$1/tests/out"
		sweep_outcome_start "$1/tests/out/rec" st-run
		rm -f "$HARNESS_SWEEP_LOG"
		sweep_outcome --run-id st-run --record "$1/tests/out/rec" 1' _ "$r" "$ROOT"
	assert_success
	grep -qxF "NOTE=${note}" "$rec" || { cat "$rec"; false; }
	! grep -q '^PROBLEM=' "$rec" || false
	[[ "$stderr" == *"warning: ${note}."* ]] || { echo "$stderr"; false; }
	# Interrupted: the not-finished record's note.
	rm -rf "$r/tests/out"
	run --separate-stderr bash -c '
		source "$2/tests/lib/common.sh"
		ROOT="$1"
		trap '\''sweep_outcome_on_exit "$?" || true'\'' EXIT
		harness_sha_for_sweep "$1/tests/out"
		sweep_outcome_start "$1/tests/out/rec" st-run
		rm -f "$HARNESS_SWEEP_LOG"
		kill -TERM $$
		echo after' _ "$r" "$ROOT"
	[ "$status" -eq 143 ]
	grep -qx 'EXIT=unfinished' "$rec"
	grep -qxF "NOTE=${note}" "$rec" || { cat "$rec"; false; }
	[[ "$stderr" == *"warning: ${note}."* ]] || { echo "$stderr"; false; }
	# Its start could not create it (no TMPDIR): the warning then, and the note at the end.
	rm -rf "$r/tests/out"
	run --separate-stderr bash -c '
		source "$2/tests/lib/common.sh"
		ROOT="$1"
		harness_sha_for_sweep "$1/tests/out"
		TMPDIR="$1/no-such-dir" sweep_outcome_start "$1/tests/out/rec" st-run
		sweep_outcome --run-id st-run --record "$1/tests/out/rec" 1' _ "$r" "$ROOT"
	assert_success
	[[ "$stderr" == *"warning: could not create a temp file for the steps' harness reads"* ]] || { echo "$stderr"; false; }
	grep -qxF "NOTE=the steps' own harness reads could not be checked: the sweep could not create the temp file they are added to (HARNESS_SWEEP_LOG) at its start, so a harness change that only a step read (undone before the sweep's next read) is not in its outcome" "$rec" \
		|| { cat "$rec"; false; }
	# A sweep whose log was there to the end: no such note.
	rm -rf "$r/tests/out"
	run --separate-stderr bash -c '
		source "$2/tests/lib/common.sh"
		ROOT="$1"
		harness_sha_for_sweep "$1/tests/out"
		sweep_outcome_start "$1/tests/out/rec" st-run
		sweep_outcome --run-id st-run --record "$1/tests/out/rec" 1' _ "$r" "$ROOT"
	assert_success
	! grep -q '^NOTE=' "$rec" || false
}

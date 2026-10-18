#!/usr/bin/env bats
# A harness change that only a step read (tests/lib/common.sh harness_read under a sweep:
# HARNESS_SWEEP_LOG, from sweep_outcome_start to the end check). A sweep reads the harness
# before its steps at most once every HARNESS_SHA_CHECK_SEC and at its end; a file changed
# and changed back between two of those reads is still in its outcome when a step read it
# (a problem, exit 4; a note when it was interrupted), naming the step, the value it recorded
# and when. The temp file is gone after the end check and never made by a dry run. Through
# the lib, then the real controlplane and dataplane sweeps in a copy of the checkout (PL33);
# no cluster: kubectl is a stub.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
	export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
	mkdir -p "$TMPDIR"
}

# _repo <dir>: a git checkout with tests/f and this repository's .gitignore, committed.
_repo() {
	local r="$1"
	mkdir -p "$r/tests"
	git -C "$r" init -q
	printf 'one\n' > "$r/tests/f"
	cp "${ROOT}/.gitignore" "$r/.gitignore"
	git -C "$r" add -A
	git -C "$r" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -q -m init
}

# _step: ${BATS_TEST_TMPDIR}/002-probe.sh, a step that reads the harness of the checkout in
# its first argument (harness_sha, as a probe's preamble does) and prints it.
_step() {
	printf '#!/usr/bin/env bash\nsource %q\nROOT="$1"\nharness_sha\n' "${ROOT}/tests/lib/common.sh" > "${BATS_TEST_TMPDIR}/002-probe.sh"
	chmod +x "${BATS_TEST_TMPDIR}/002-probe.sh"
}

# _st_sweep <repo> <script>: a sweep's shell (common.sh, harness_sha_for_sweep
# "<repo>/tests/out", sweep_outcome_start "<repo>/tests/out/rec") that then runs <script>;
# STEP is the step. HARNESS_SHA_CHECK_SEC=${CHECK_SEC:-3600}: by default the sweep's own
# check reads nothing before the end.
_st_sweep() {
	HARNESS_SHA_CHECK_SEC="${CHECK_SEC:-3600}" STEP="${BATS_TEST_TMPDIR}/002-probe.sh" run --separate-stderr bash -c '
		source "$2/tests/lib/common.sh"
		ROOT="$1"
		harness_sha_for_sweep "$1/tests/out"
		sweep_outcome_start "$1/tests/out/rec" st-run
		eval "$3"' _ "$1" "$ROOT" "$2"
}

# _values <repo>: sets clean and dirty: the repo's HARNESS_SHA, and with "two" added to tests/f.
_values() {
	clean="$(ROOT="$1" harness_sha --exclude "$1/tests/out")"
	echo two >> "$1/tests/f"
	dirty="$(ROOT="$1" harness_sha --exclude "$1/tests/out")"
	git -C "$1" checkout -q -- tests/f
	[[ "$clean" =~ ^[0-9a-f]{7}$ && "$dirty" =~ ^${clean}-dirty\.[0-9a-f]{8}$ ]]
}

@test "a harness change only a step read (undone before the sweep's next read) is a problem (exit 4) naming the step, its value and when; a step that read the start's files adds nothing; the temp file is the sweep's own and gone after its end" {
	local r="${BATS_TEST_TMPDIR}/repo" clean dirty key rec
	_repo "$r"
	_step
	_values "$r"
	key="$(ROOT="$r" harness_content_key --exclude "$r/tests/out")"
	rec="$r/tests/out/rec/sweep-outcome.txt"
	# The step reads the start's files: no problem. A parent's log (an inherited
	# HARNESS_SWEEP_LOG) is not this sweep's: left alone.
	: > "${BATS_TEST_TMPDIR}/parent.log"
	HARNESS_SWEEP_LOG="${BATS_TEST_TMPDIR}/parent.log" _st_sweep "$r" '
		[[ "$HARNESS_SWEEP_LOG" == "$TMPDIR"/* && -f "$HARNESS_SWEEP_LOG" ]] && echo "log in TMPDIR"
		"$STEP" "$ROOT"
		sweep_outcome --run-id st-run --record "$1/tests/out/rec" 1'
	assert_success
	assert_line "log in TMPDIR"
	assert_line "$clean"
	! grep -q '^PROBLEM=' "$rec" || false
	[ -e "${BATS_TEST_TMPDIR}/parent.log" ]
	[ ! -s "${BATS_TEST_TMPDIR}/parent.log" ]
	[ -z "$(ls -A "$TMPDIR")" ]
	# The step reads a change that is undone before the end: a problem.
	rm -rf "$r/tests/out"
	_st_sweep "$r" '
		echo two >> "$ROOT/tests/f"
		"$STEP" "$ROOT"
		git -C "$ROOT" checkout -q -- tests/f
		sweep_outcome --run-id st-run --record "$1/tests/out/rec" 1; rc=$?
		# A step after the end check (a report) adds nothing.
		echo two >> "$ROOT/tests/f"
		"$STEP" "$ROOT"
		git -C "$ROOT" checkout -q -- tests/f
		exit "$rc"'
	[ "$status" -eq 4 ] || { echo "$stderr"; false; }
	assert_line "$dirty"
	grep -qx 'EXIT=4' "$rec"
	[ "$(grep -c '^PROBLEM=' "$rec")" -eq 1 ]
	grep -qE "^PROBLEM=the harness changed during the sweep, and back: HARNESS_SHA=${clean} at its start and at its end, but 002-probe\.sh recorded HARNESS_SHA=${dirty//./\\.} at [0-9T:-]+Z, so the steps after that read may have run other code than ${clean}: " "$rec" \
		|| { cat "$rec"; false; }
	# The record names the sweep's harness: HARNESS_CONTENT_KEY right after HARNESS_SHA.
	[ "$(grep -A1 -x "HARNESS_SHA=${clean}" "$rec")" = "HARNESS_SHA=${clean}"$'\n'"HARNESS_CONTENT_KEY=${key}" ]
	[ -z "$(ls -A "$TMPDIR")" ]
}

@test "several step reads name the first and their count; a sweep check that saw the change after a step did names the step's read too; a change still there at the end names the step read before it" {
	local r="${BATS_TEST_TMPDIR}/repo" clean dirty rec
	_repo "$r"
	_step
	_values "$r"
	rec="$r/tests/out/rec/sweep-outcome.txt"
	# Two step reads, then (in a later second) the sweep's own check before 003, then undone.
	CHECK_SEC=0 _st_sweep "$r" '
		echo two >> "$ROOT/tests/f"
		"$STEP" "$ROOT" >/dev/null
		"$STEP" "$ROOT" >/dev/null
		sleep 1
		harness_sha_check 003-cleanup.sh
		git -C "$ROOT" checkout -q -- tests/f
		sweep_outcome --run-id st-run --record "$1/tests/out/rec" 1'
	[ "$status" -eq 4 ]
	[ "$(grep -c '^WARNING: the harness changed during the sweep' <<<"$stderr")" -eq 1 ]
	grep -qE "^PROBLEM=the harness changed during the sweep, and back: HARNESS_SHA=${clean} at its start and at its end, but ${dirty//./\\.} at [0-9T:-]+Z, before 003-cleanup\.sh; the read before that \(at [0-9T:-]+Z, the sweep's start\) still gave ${clean}; a step read other files earlier: 002-probe\.sh recorded HARNESS_SHA=${dirty//./\\.} at [0-9T:-]+Z \(the first of 2 step reads of other files\), so the steps after that read" "$rec" \
		|| { cat "$rec"; false; }
	# Still changed at the end.
	rm -rf "$r/tests/out"
	_st_sweep "$r" '
		echo two >> "$ROOT/tests/f"
		"$STEP" "$ROOT" >/dev/null
		sweep_outcome --run-id st-run --record "$1/tests/out/rec" 1'
	[ "$status" -eq 4 ]
	grep -qE "^PROBLEM=the harness changed during the sweep: HARNESS_SHA=${clean} at its start, ${dirty//./\\.} at its end \([0-9T:-]+Z\); the last read that gave ${clean} was at [0-9T:-]+Z, the sweep's start; a step read other files before the end: 002-probe\.sh recorded HARNESS_SHA=${dirty//./\\.} at [0-9T:-]+Z, so the steps after that read" "$rec" \
		|| { cat "$rec"; false; }
	[ -z "$(ls -A "$TMPDIR")" ]
}

@test "an interrupted sweep after a change only a step read: a note in its not-finished record (which names HARNESS_CONTENT_KEY), and the temp file is gone" {
	local r="${BATS_TEST_TMPDIR}/repo" clean dirty key rec
	_repo "$r"
	_step
	_values "$r"
	key="$(ROOT="$r" harness_content_key --exclude "$r/tests/out")"
	rec="$r/tests/out/rec/sweep-outcome.txt"
	HARNESS_SHA_CHECK_SEC=3600 STEP="${BATS_TEST_TMPDIR}/002-probe.sh" run --separate-stderr bash -c '
		source "$2/tests/lib/common.sh"
		ROOT="$1"
		trap '\''sweep_outcome_on_exit "$?" || true'\'' EXIT
		harness_sha_for_sweep "$1/tests/out"
		sweep_outcome_start "$1/tests/out/rec" st-run --next "run it again"
		echo two >> "$ROOT/tests/f"
		"$STEP" "$ROOT" >/dev/null
		git -C "$ROOT" checkout -q -- tests/f
		kill -TERM $$
		echo after' _ "$r" "$ROOT"
	[ "$status" -eq 143 ]
	refute_output --partial after
	grep -qx 'EXIT=unfinished' "$rec"
	[ "$(grep -A1 -x "HARNESS_SHA=${clean}" "$rec")" = "HARNESS_SHA=${clean}"$'\n'"HARNESS_CONTENT_KEY=${key}" ]
	grep -qE "^NOTE=the harness changed during the sweep, and back: HARNESS_SHA=${clean} at its start and at its end, but 002-probe\.sh recorded HARNESS_SHA=${dirty//./\\.} at [0-9T:-]+Z, so" "$rec" \
		|| { cat "$rec"; false; }
	[[ "$stderr" == *"warning: the harness changed during the sweep, and back: HARNESS_SHA=${clean} at its start and at its end, but 002-probe.sh recorded HARNESS_SHA=${dirty} at "* ]]
	[ -z "$(ls -A "$TMPDIR")" ]
}

# _suite_copy <dir> <suite> <setup>: a git checkout holding a copy of this one's config/,
# tests/lib/*.sh, tests/lib/test/fixtures/ and tests/<suite>/ (no results), whose <setup>
# step (a stand-in) adds tests/<suite>/zz-edit.txt and whose 005-cleanup.sh (a stand-in)
# removes it, committed: a harness change from the first step to the last, which a probe
# between them reads.
_suite_copy() {
	local r="$1" s="$2"
	mkdir -p "$r/tests/lib/test"
	cp -R "${ROOT}/config" "$r/config"
	cp "${ROOT}"/tests/lib/*.sh "$r/tests/lib/"
	cp -R "${ROOT}/tests/lib/test/fixtures" "$r/tests/lib/test/fixtures"
	(cd "${ROOT}/tests" && tar -cf - --exclude=results --exclude='*.local.env' "$s") | (cd "$r/tests" && tar -xf -)
	cp "${ROOT}/.gitignore" "$r/.gitignore"
	printf '#!/bin/sh\nprintf "x\\n" > "$(dirname "$0")/zz-edit.txt"\nexit 0\n' > "$r/tests/${s}/$3"
	printf '#!/bin/sh\nrm -f "$(dirname "$0")/zz-edit.txt"\nexit 0\n' > "$r/tests/${s}/005-cleanup.sh"
	git -C "$r" init -q
	git -C "$r" add -A
	git -C "$r" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -q -m init
}

@test "through the controlplane sweep: a harness file its setup step adds and its cleanup removes, read only by its probe (no check between: HARNESS_SHA_CHECK_SEC=3600), is a PROBLEM naming the probe and the value its TSV's HARNESS_CHANGED_AT line records (exit 4)" {
	local r="${BATS_TEST_TMPDIR}/cp" bin="${BATS_TEST_TMPDIR}/bin" ek="${BATS_TEST_TMPDIR}/kubeconfig" res="${BATS_TEST_TMPDIR}/res" clean d v
	_suite_copy "$r" controlplane 001-setup-controlplane-test.sh
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
	# The change is undone: the copy is clean again.
	[ -z "$(git -C "$r" status --porcelain)" ]
	v="$(sed -n 's/^# HARNESS_CHANGED_AT=[^ ]* HARNESS_SHA=\([^ ]*\) .*/\1/p' "$d"/controlplane-*.tsv)"
	[[ "$v" =~ ^${clean}-dirty\.[0-9a-f]{8}$ ]] || { cat "$d"/controlplane-*.tsv; false; }
	grep -qx 'EXIT=4' "$d/sweep-outcome.txt"
	grep -qE "^PROBLEM=the harness changed during the sweep, and back: HARNESS_SHA=${clean} at its start and at its end, but 002-collect-resource-metrics\.sh recorded HARNESS_SHA=${v//./\\.} at [0-9T:-]+Z, so" "$d/sweep-outcome.txt" \
		|| { cat "$d/sweep-outcome.txt"; false; }
	grep -qx "HARNESS_SHA=${clean}" "$d/sweep-outcome.txt"
	[ -z "$(ls -A "$TMPDIR")" ]
}

@test "through the dataplane sweep: the same change, read only by its latency probe, is a PROBLEM naming the probe and the value its TSV preamble records; a dry run makes no temp file" {
	local r="${BATS_TEST_TMPDIR}/dp" bin="${BATS_TEST_TMPDIR}/bin" ek="${BATS_TEST_TMPDIR}/kubeconfig" res="${BATS_TEST_TMPDIR}/res" clean d v
	_suite_copy "$r" dataplane 001-setup-dataplane-test.sh
	clean="$(ROOT="$r" harness_sha)"
	: > "$ek"
	mkdir -p "$bin"
	# The Istio CR reads answer as fake-istio-cr.sh; everything else fails (the probe finds
	# no client pod, after its preamble read the harness).
	cat > "${bin}/kubectl" <<'STUB'
#!/bin/sh
case " $* " in
*" get istios.sailoperator.io default "* | *" get istiorevisions.sailoperator.io "* | *" get deployments.apps istiod -o json "*) exec "$HS_FAKE_CR" "$@" ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${bin}/kubectl"
	HS_FAKE_CR="${ROOT}/tests/lib/test/fixtures/fake-istio-cr.sh" HARNESS_SHA_CHECK_SEC=3600 ISTIO_VERSION_CHECK=warn \
		ISTIO_VERSION_READY_WAIT_SEC=0 DATAPLANE_INTER_COMBO_SETTLE_SEC=0 PATH="${bin}:${PATH}" KUBECONFIG="$ek" \
		DATAPLANE_RESULTS_DIR="$res" run --separate-stderr bash "$r/tests/dataplane/003-run-sweep.sh" --contexts ci-a --mesh-sizes 1
	[ "$status" -eq 4 ] || { echo "status ${status}: ${stderr}"; false; }
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	[ -z "$(git -C "$r" status --porcelain)" ]
	v="$(grep -h '^# HARNESS_SHA=' "$d"/*.tsv | grep -vx "# HARNESS_SHA=${clean}" | sed 's/^# HARNESS_SHA=//')"
	[[ "$v" =~ ^${clean}-dirty\.[0-9a-f]{8}$ ]] || { grep -h '^# HARNESS' "$d"/*.tsv; false; }
	grep -qE "^PROBLEM=the harness changed during the sweep, and back: HARNESS_SHA=${clean} at its start and at its end, but 002-run-latency-probe\.sh recorded HARNESS_SHA=${v//./\\.} at [0-9T:-]+Z, so" "$d/sweep-outcome.txt" \
		|| { cat "$d/sweep-outcome.txt"; false; }
	[ -z "$(ls -A "$TMPDIR")" ]
	# --dry-run: no temp file (nor a sweep dir).
	rm -rf "$res"
	PATH="${bin}:${PATH}" KUBECONFIG="$ek" DATAPLANE_RESULTS_DIR="$res" \
		run --separate-stderr bash "$r/tests/dataplane/003-run-sweep.sh" --dry-run --contexts ci-a --mesh-sizes 1
	assert_success
	[ -z "$(ls -A "$TMPDIR")" ]
}

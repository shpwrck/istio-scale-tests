#!/usr/bin/env bats
# HARNESS_SHA, the harness a run measured with (tests/lib/common.sh harness_sha): only the
# harness paths count (tests/, config/, charts/, terraform/), the operator's git settings
# (core.fileMode, core.attributesFile, the default ~/.config/git/attributes) never change
# it, a tracked file under an excluded results dir still counts; a sweep reads it again
# before its steps (harness_sha_check) and at its end, and a change during the sweep is a
# problem in its outcome (exit 4), or a note when it was interrupted. Through the real
# controlplane sweep in a copy of the checkout (PL33); no cluster: kubectl is a stub.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
	export TMPDIR="$BATS_TEST_TMPDIR"
}

# _repo <dir>: a git checkout with tests/f, tests/out/keep.txt (a tracked file under a
# results dir), docs/d.md and this repository's .gitignore, committed.
_repo() {
	local r="$1"
	mkdir -p "$r/tests/out" "$r/docs"
	git -C "$r" init -q
	printf 'one\n' > "$r/tests/f"
	printf 'keep\n' > "$r/tests/out/keep.txt"
	printf 'doc\n' > "$r/docs/d.md"
	cp "${ROOT}/.gitignore" "$r/.gitignore"
	git -C "$r" add -A
	git -C "$r" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -q -m init
}

@test "HARNESS_SHA counts only the harness paths: an untracked note under docs/ or at the top, or a tracked doc edited, reads clean; an untracked file under tests/ does not" {
	local r="${BATS_TEST_TMPDIR}/repo" clean
	_repo "$r"
	clean="$(ROOT="$r" harness_sha)"
	[[ "$clean" =~ ^[0-9a-f]{7}$ ]]
	printf 'campaign note\n' > "$r/docs/notes-run-3.md"
	printf 'scratch\n' > "$r/NOTES.txt"
	printf 'edited\n' >> "$r/docs/d.md"
	[ "$(ROOT="$r" harness_sha)" = "$clean" ]
	# Each harness path counts.
	local p v
	for p in tests config charts terraform; do
		mkdir -p "$r/$p"
		printf 'x\n' > "$r/$p/new-file"
		v="$(ROOT="$r" harness_sha)"
		[[ "$v" =~ ^${clean}-dirty\.[0-9a-f]{8}$ ]] || { echo "${p}: ${v}"; false; }
		rm -f "$r/$p/new-file"
	done
	[ "$(ROOT="$r" harness_sha)" = "$clean" ]
}

@test "HARNESS_SHA ignores the operator's core.fileMode (an executable bit counts) and gitattributes (core.attributesFile, the default ~/.config/git/attributes)" {
	local r="${BATS_TEST_TMPDIR}/repo" clean x crlf a
	_repo "$r"
	clean="$(ROOT="$r" harness_sha)"
	# core.fileMode=false (as on a checkout from a filesystem without modes): a chmod still counts.
	chmod +x "$r/tests/f"
	x="$(ROOT="$r" harness_sha)"
	[[ "$x" =~ ^${clean}-dirty\.[0-9a-f]{8}$ ]]
	git -C "$r" config core.fileMode false
	[ "$(ROOT="$r" harness_sha)" = "$x" ]
	git -C "$r" config core.fileMode true
	[ "$(ROOT="$r" harness_sha)" = "$x" ]
	chmod -x "$r/tests/f"
	[ "$(ROOT="$r" harness_sha)" = "$clean" ]
	# A file with CRLF line endings: hashed as it is, whatever gitattributes the operator has
	# (`* text` would normalise it to LF and give another value).
	printf 'one\r\ntwo\r\n' > "$r/tests/f"
	crlf="$(ROOT="$r" harness_sha)"
	[[ "$crlf" =~ ^${clean}-dirty\.[0-9a-f]{8}$ ]]
	printf '* text\n' > "${BATS_TEST_TMPDIR}/attributes"
	[ "$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.attributesFile GIT_CONFIG_VALUE_0="${BATS_TEST_TMPDIR}/attributes" ROOT="$r" harness_sha)" = "$crlf" ]
	mkdir -p "${BATS_TEST_TMPDIR}/xdg/git" "${BATS_TEST_TMPDIR}/home/.config/git"
	printf '* text\n' > "${BATS_TEST_TMPDIR}/xdg/git/attributes"
	printf '* text\n' > "${BATS_TEST_TMPDIR}/home/.config/git/attributes"
	[ "$(XDG_CONFIG_HOME="${BATS_TEST_TMPDIR}/xdg" ROOT="$r" harness_sha)" = "$crlf" ]
	[ "$(env -u XDG_CONFIG_HOME HOME="${BATS_TEST_TMPDIR}/home" ROOT="$r" bash -c 'source "$1/tests/lib/common.sh"; ROOT="$2" harness_sha' _ "$ROOT" "$r")" = "$crlf" ]
	# The check is real: git itself does normalise the file under those attributes.
	a="$(cd "$r" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.attributesFile GIT_CONFIG_VALUE_0="${BATS_TEST_TMPDIR}/attributes" git check-attr text -- tests/f)"
	[ "$a" = "tests/f: text: set" ]
}

@test "HARNESS_SHA: an excluded results dir leaves out its untracked files, never its tracked ones" {
	local r="${BATS_TEST_TMPDIR}/repo" clean v
	_repo "$r"
	clean="$(ROOT="$r" harness_sha)"
	printf 'row\n' > "$r/tests/out/data.tsv"
	[ "$(ROOT="$r" harness_sha)" != "$clean" ]
	[ "$(ROOT="$r" harness_sha --exclude "$r/tests/out")" = "$clean" ]
	# A tracked file under it, edited: dirty, with or without the exclude.
	printf 'edited\n' >> "$r/tests/out/keep.txt"
	v="$(ROOT="$r" harness_sha --exclude "$r/tests/out")"
	[[ "$v" =~ ^${clean}-dirty\.[0-9a-f]{8}$ ]]
	rm -f "$r/tests/out/data.tsv"
	[ "$(ROOT="$r" harness_sha)" = "$v" ]
	# report_harness_sha passes its --exclude through.
	printf 'row\n' > "$r/tests/out/data.tsv"
	[ "$(ROOT="$r" report_harness_sha --exclude "$r/tests/out")" = "$v" ]
}

# _hs_sweep <repo> <script>: run <script> (bash, after common.sh and harness_sha_for_sweep
# "$1/tests/out" with ROOT=<repo>) and print its output; HARNESS_SHA_CHECK_SEC=0.
_hs_sweep() {
	HARNESS_SHA_CHECK_SEC=0 run --separate-stderr bash -c '
		source "$2/tests/lib/common.sh"
		ROOT="$1"
		harness_sha_for_sweep "$1/tests/out"
		eval "$3"' _ "$1" "$ROOT" "$2"
}

@test "harness_sha_check warns once, naming both values and the step it read before; the end check names the first changed read and the last unchanged one, and a change that went back" {
	local r="${BATS_TEST_TMPDIR}/repo" clean
	_repo "$r"
	clean="$(ROOT="$r" harness_sha --exclude "$r/tests/out")"
	# No change: no warning, no problem.
	_hs_sweep "$r" 'harness_sha_check 001-setup.sh; _harness_sha_sweep_end p; printf "[%s]\n" "$p"'
	assert_success
	assert_output "[]"
	[ -z "$stderr" ]
	# A change before the second step: one warning; the end names the read before 002 as the
	# first changed one and the read before 001 as the last that gave the start's value.
	_hs_sweep "$r" '
		harness_sha_check 001-setup.sh
		echo two >> "$ROOT/tests/f"
		harness_sha_check 002-probe.sh
		harness_sha_check 003-cleanup.sh
		_harness_sha_sweep_end p
		_harness_sha_sweep_end q
		[[ "$p" == "$q" ]] || echo "second call differs"
		printf "%s\n" "$p"'
	assert_success
	[ "$(grep -c '^WARNING: the harness changed during the sweep' <<<"$stderr")" -eq 1 ]
	[[ "$stderr" =~ WARNING:\ the\ harness\ changed\ during\ the\ sweep:\ HARNESS_SHA=${clean}\ at\ its\ start,\ ${clean}-dirty\.[0-9a-f]{8}\ now\ \(read\ before\ 002-probe\.sh\):\ a\ file\ under\ tests/,\ config/,\ charts/,\ terraform/\ was\ edited,\ or\ a\ git\ checkout\ or\ pull\ ran\.\ The\ sweep\ goes\ on\;\ its\ outcome\ records\ this\ as\ a\ problem\ \(exit\ 4\)\. ]] || { echo "$stderr"; false; }
	refute_output --partial "second call differs"
	assert_output --regexp "^the harness changed during the sweep: HARNESS_SHA=${clean} at its start, ${clean}-dirty\.[0-9a-f]{8} at its end \([0-9T:-]+Z\), first read ${clean}-dirty\.[0-9a-f]{8} at [0-9T:-]+Z, before 002-probe\.sh \(the read before that, at [0-9T:-]+Z, before 001-setup\.sh, still gave ${clean}\), so the steps after that read may have run other code than ${clean} \(a probe's TSV records the harness it ran; the sweep's own files record the start's\): run the sweep again if the change matters$"
	git -C "$r" checkout -q -- tests/f
	# Changed and back before the end.
	_hs_sweep "$r" '
		echo two >> "$ROOT/tests/f"
		harness_sha_check 002-probe.sh
		git -C "$ROOT" checkout -q -- tests/f
		_harness_sha_sweep_end p
		printf "%s\n" "$p"'
	assert_success
	assert_output --regexp "^the harness changed during the sweep, and back: HARNESS_SHA=${clean} at its start and at its end, but ${clean}-dirty\.[0-9a-f]{8} at [0-9T:-]+Z, before 002-probe\.sh \(the read before that, at the sweep's start \([0-9T:-]+Z\), still gave ${clean}\)"
	# Changed after the last step: only the end check sees it.
	_hs_sweep "$r" '
		harness_sha_check 002-probe.sh
		echo two >> "$ROOT/tests/f"
		_harness_sha_sweep_end p
		printf "%s\n" "$p"'
	assert_success
	assert_output --regexp "^the harness changed during the sweep: HARNESS_SHA=${clean} at its start, ${clean}-dirty\.[0-9a-f]{8} at its end \([0-9T:-]+Z\); the last read that gave ${clean} was at [0-9T:-]+Z, before 002-probe\.sh, so the steps after"
	git -C "$r" checkout -q -- tests/f
	# HARNESS_SHA_CHECK_SEC throttles the reads: none within the period after the start.
	HARNESS_SHA_CHECK_SEC=3600 run --separate-stderr bash -c '
		source "$2/tests/lib/common.sh"
		ROOT="$1"
		harness_sha_for_sweep "$1/tests/out"
		echo two >> "$ROOT/tests/f"
		harness_sha_check 002-probe.sh
		echo "seen=[${_HARNESS_SHA_SEEN}]"' _ "$r" "$ROOT"
	assert_output "seen=[]"
	[ -z "$stderr" ]
	# A subshell or a step (another process) never checks: only the sweep's own shell.
	_hs_sweep "$r" 'echo two >> "$ROOT/tests/f"; ( harness_sha_check 002-probe.sh; echo "sub=[${_HARNESS_SHA_SEEN}]" )'
	assert_output "sub=[]"
	[ -z "$stderr" ]
}

@test "a harness change during a sweep is a problem in its outcome (exit 4); one during an interrupted sweep is a note in its record" {
	local r="${BATS_TEST_TMPDIR}/repo" clean
	_repo "$r"
	clean="$(ROOT="$r" harness_sha --exclude "$r/tests/out")"
	HARNESS_SHA_CHECK_SEC=0 run --separate-stderr bash -c '
		source "$2/tests/lib/common.sh"
		ROOT="$1"
		harness_sha_for_sweep "$1/tests/out"
		sweep_outcome_start "$1/tests/out/rec" hs-run --next "run it again"
		echo two >> "$ROOT/tests/f"
		harness_sha_check 002-probe.sh
		sweep_outcome --run-id hs-run --record "$1/tests/out/rec" 1' _ "$r" "$ROOT"
	[ "$status" -eq 4 ]
	grep -qx 'EXIT=4' "$r/tests/out/rec/sweep-outcome.txt"
	grep -qE "^PROBLEM=the harness changed during the sweep: HARNESS_SHA=${clean} at its start, ${clean}-dirty\.[0-9a-f]{8} at its end" "$r/tests/out/rec/sweep-outcome.txt"
	run sweep_outcome_recorded "$r/tests/out/rec" text
	assert_output --partial "error: the harness changed during the sweep: HARNESS_SHA=${clean} at its start"
	# Interrupted (SIGTERM) after the change: the record stays not finished, with a note.
	git -C "$r" checkout -q -- tests/f
	rm -rf "$r/tests/out/rec"
	HARNESS_SHA_CHECK_SEC=0 run --separate-stderr bash -c '
		source "$2/tests/lib/common.sh"
		ROOT="$1"
		trap '\''sweep_outcome_on_exit "$?" || true'\'' EXIT
		harness_sha_for_sweep "$1/tests/out"
		sweep_outcome_start "$1/tests/out/rec" hs-run --next "run it again"
		echo two >> "$ROOT/tests/f"
		kill -TERM $$
		echo after' _ "$r" "$ROOT"
	[ "$status" -eq 143 ]
	refute_output --partial after
	grep -qx 'EXIT=unfinished' "$r/tests/out/rec/sweep-outcome.txt"
	grep -qE "^NOTE=the harness changed during the sweep: HARNESS_SHA=${clean} at its start, ${clean}-dirty\.[0-9a-f]{8} at its end" "$r/tests/out/rec/sweep-outcome.txt"
	[[ "$stderr" == *"warning: the harness changed during the sweep: HARNESS_SHA=${clean} at its start"* ]]
}

# _cp_copy <dir>: a git checkout holding a copy of this one's config/, tests/lib/*.sh,
# tests/lib/test/fixtures/ and tests/controlplane/ (no results), and tests/marker.txt,
# committed.
_cp_copy() {
	local r="$1"
	mkdir -p "$r/tests/lib/test"
	cp -R "${ROOT}/config" "$r/config"
	cp "${ROOT}"/tests/lib/*.sh "$r/tests/lib/"
	cp -R "${ROOT}/tests/lib/test/fixtures" "$r/tests/lib/test/fixtures"
	(cd "${ROOT}/tests" && tar -cf - --exclude=results --exclude='*.local.env' controlplane) | (cd "$r/tests" && tar -xf -)
	cp "${ROOT}/.gitignore" "$r/.gitignore"
	printf 'one\n' > "$r/tests/marker.txt"
	git -C "$r" init -q
	git -C "$r" add -A
	git -C "$r" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -q -m init
}

@test "through the controlplane sweep: a tracked file edited while it runs (by its first cell's probe) is a WARNING before the next step, a PROBLEM naming both values in its outcome (exit 4), and the next cell's probe records the changed harness" {
	local r="${BATS_TEST_TMPDIR}/cp" bin="${BATS_TEST_TMPDIR}/bin" ek="${BATS_TEST_TMPDIR}/kubeconfig" res="${BATS_TEST_TMPDIR}/res" clean d
	_cp_copy "$r"
	clean="$(ROOT="$r" harness_sha)"
	[[ "$clean" =~ ^[0-9a-f]{7}$ ]]
	: > "$ek"
	mkdir -p "$bin"
	# The Istio CR reads answer as fake-istio-cr.sh; 002's first istiod read edits the
	# copy's tests/marker.txt (once) and fails, as everything else does.
	cat > "${bin}/kubectl" <<'STUB'
#!/bin/sh
case "$*" in
*"get istios.sailoperator.io default"*|*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	exec "$HP_FAKE_CR" "$@" ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running -o jsonpath="*)
	[ -e "$HP_DIR/edited" ] || { echo two >> "$HP_REPO/tests/marker.txt"; : > "$HP_DIR/edited"; }
	exit 1 ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${bin}/kubectl"
	HP_FAKE_CR="${ROOT}/tests/lib/test/fixtures/fake-istio-cr.sh" HP_REPO="$r" HP_DIR="$BATS_TEST_TMPDIR" \
		HARNESS_SHA_CHECK_SEC=0 ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 \
		ISTIO_VERSION_READY_WAIT_SEC=0 PATH="${bin}:${PATH}" KUBECONFIG="$ek" CONTROLPLANE_RESULTS_DIR="$res" \
		run --separate-stderr bash "$r/tests/controlplane/003-run-sweep.sh" --contexts ci-a --mesh-sizes 1 --service-counts 5,6
	[ "$status" -eq 4 ] || { echo "status ${status}: ${stderr}"; false; }
	[ -e "${BATS_TEST_TMPDIR}/edited" ]
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	# The console: one WARNING, before a step of the second cell.
	[ "$(grep -c '^WARNING: the harness changed during the sweep' <<<"$stderr")" -eq 1 ]
	[[ "$stderr" =~ WARNING:\ the\ harness\ changed\ during\ the\ sweep:\ HARNESS_SHA=${clean}\ at\ its\ start,\ ${clean}-dirty\.[0-9a-f]{8}\ now\ \(read\ before\ 00[0-9]-[a-z-]+\.sh\) ]] || { echo "$stderr"; false; }
	# The outcome: a problem naming both values.
	grep -qE "^PROBLEM=the harness changed during the sweep: HARNESS_SHA=${clean} at its start, ${clean}-dirty\.[0-9a-f]{8} at its end \([0-9T:-]+Z\), first read ${clean}-dirty\.[0-9a-f]{8} at [0-9T:-]+Z, before 00[0-9]-" "$d/sweep-outcome.txt"
	grep -qx 'EXIT=4' "$d/sweep-outcome.txt"
	# The first cell's probe ran on the start's harness, the second's on the changed one.
	[ "$(grep -oE "^\[002\] RUN_ID=.*HARNESS_SHA=[^ ]+$" <<<"$output" | sed 's/.*HARNESS_SHA=//' | head -n 1)" = "$clean" ]
	[[ "$(grep -oE "^\[002\] RUN_ID=.*HARNESS_SHA=[^ ]+$" <<<"$output" | sed 's/.*HARNESS_SHA=//' | sed -n 2p)" =~ ^${clean}-dirty\.[0-9a-f]{8}$ ]] || { echo "$output"; false; }
	# The sweep's own files keep the start's value.
	grep -qx "HARNESS_SHA=${clean}" "$d/sweep-outcome.txt"
}

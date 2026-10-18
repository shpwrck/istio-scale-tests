#!/usr/bin/env bats
# The harness content key (tests/lib/common.sh harness_content_key, HARNESS_CONTENT_KEY): a
# sweep decides "did the harness change" by the content of its files, never by the
# `git describe` text, so a docs-only commit or a fetched tag during a sweep is a note
# (INFO, exit 0), not a problem, and the steps keep recording the start's HARNESS_SHA; an
# edit under tests/ is still a problem (exit 4). The -dirty hash covers only the harness
# paths, and the clone's own $GIT_DIR/info/attributes never changes it. istiod-diag's index
# leaves out the probe's output dir. Through the real controlplane sweep too (PL33); no
# cluster: kubectl is a stub.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
	export TMPDIR="$BATS_TEST_TMPDIR"
	unset HARNESS_SWEEP_KEY HARNESS_SWEEP_SHA HARNESS_SHA_EXCLUDE
}

_git() { git -C "$1" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false "${@:2}"; }

# _repo <dir>: a git checkout with tests/f, docs/d.md and this repository's .gitignore,
# committed.
_repo() {
	local r="$1"
	mkdir -p "$r/tests" "$r/docs"
	git -C "$r" init -q
	printf 'one\n' > "$r/tests/f"
	printf 'doc\n' > "$r/docs/d.md"
	cp "${ROOT}/.gitignore" "$r/.gitignore"
	git -C "$r" add -A
	_git "$r" commit -q -m init
}

# _sweep <repo> <script>: run <script> after common.sh and harness_sha_for_sweep
# "<repo>/tests/out" (ROOT=<repo>, HARNESS_SHA_CHECK_SEC=0), stdout and stderr apart.
_sweep() {
	HARNESS_SHA_CHECK_SEC=0 run --separate-stderr bash -c '
		source "$2/tests/lib/common.sh"
		ROOT="$1"
		harness_sha_for_sweep "$1/tests/out"
		eval "$3"' _ "$1" "$ROOT" "$2"
}

@test "a docs-only commit during a sweep: the content key stays, a step records the start's HARNESS_SHA, the check prints a note, and the outcome is exit 0 with an INFO; an edit under tests/ after it is still exit 4" {
	local r="${BATS_TEST_TMPDIR}/repo" clean key
	_repo "$r"
	clean="$(ROOT="$r" harness_sha)"
	key="$(ROOT="$r" harness_content_key)"
	[[ "$key" =~ ^[0-9a-f]{12}$ ]]
	_sweep "$r" '
		mkdir -p "$ROOT/tests/out/rec"
		printf "x\n" > "$ROOT/docs/campaign.md"
		git -C "$ROOT" add docs/campaign.md
		git -C "$ROOT" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -q -m docs
		echo "head=$(git -C "$ROOT" describe --always --abbrev=7)"
		echo "key=$(harness_content_key)"
		echo "step=$(bash -c "source \"\$1/tests/lib/common.sh\"; ROOT=\"\$2\" harness_sha" _ "$2" "$ROOT")"
		harness_sha_check 002-probe.sh
		harness_sha_check 003-cleanup.sh
		rc=0
		sweep_outcome --run-id hs-run --record "$ROOT/tests/out/rec" 1 || rc=$?
		echo "rc=${rc}"'
	assert_success
	local head
	head="$(sed -n 's/^head=//p' <<<"$output")"
	[ -n "$head" ] && [ "$head" != "$clean" ]
	assert_line "key=${key}"
	assert_line "step=${clean}"
	assert_line "rc=0"
	refute_output --partial "error:"
	# One note at the check, none of the warning.
	[ "$(grep -c '^note: HEAD moved during the sweep, or a tag appeared' <<<"$stderr")" -eq 1 ]
	[[ "$stderr" != *WARNING* ]] || { echo "$stderr"; false; }
	[[ "$stderr" == *"HARNESS_SHA=${clean} at its start, ${head} now (read before 002-probe.sh), but the files under tests/, config/, charts/, terraform/ did not change"* ]] || { echo "$stderr"; false; }
	# The record: exit 0, the INFO, no PROBLEM.
	grep -qx 'EXIT=0' "$r/tests/out/rec/sweep-outcome.txt"
	! grep -q '^PROBLEM=' "$r/tests/out/rec/sweep-outcome.txt"
	grep -qx "INFO=HEAD moved during the sweep, or a tag appeared: HARNESS_SHA=${clean} at its start, ${head} first read at [0-9T:-]*Z, before 002-probe.sh; the files under tests/, config/, charts/, terraform/ did not change (HARNESS_CONTENT_KEY=${key}), so every step ran the start's harness and recorded HARNESS_SHA=${clean}" "$r/tests/out/rec/sweep-outcome.txt"
	# An edit under tests/ after the commit: still a problem, exit 4.
	_sweep "$r" '
		printf "y\n" > "$ROOT/docs/more.md"
		git -C "$ROOT" add docs/more.md
		git -C "$ROOT" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -q -m docs2
		echo two >> "$ROOT/tests/f"
		harness_sha_check 002-probe.sh
		sweep_outcome --run-id hs-run --record "$ROOT/tests/out/rec" 1'
	[ "$status" -eq 4 ]
	grep -qE '^PROBLEM=the harness changed during the sweep: HARNESS_SHA=[0-9a-f]{7} at its start, [0-9a-f]{7}-dirty\.[0-9a-f]{8} at its end' "$r/tests/out/rec/sweep-outcome.txt"
	! grep -q '^INFO=' "$r/tests/out/rec/sweep-outcome.txt"
	[ "$(grep -c '^WARNING: the harness changed during the sweep' <<<"$stderr")" -eq 1 ]
}

@test "a fetched tag during a sweep is a note, at its end too (no check before it), and an interrupted sweep records it as INFO" {
	local r="${BATS_TEST_TMPDIR}/repo" clean
	_repo "$r"
	clean="$(ROOT="$r" harness_sha)"
	# A tag that appears after the last check: only the end check sees it.
	_sweep "$r" '
		mkdir -p "$ROOT/tests/out/rec"
		harness_sha_check 002-probe.sh
		git -C "$ROOT" -c user.email=ci@example.com -c user.name=ci tag -a campaign-1 -m rel
		sweep_outcome --run-id hs-run --record "$ROOT/tests/out/rec" 1'
	assert_success
	grep -qx 'EXIT=0' "$r/tests/out/rec/sweep-outcome.txt"
	grep -qE "^INFO=HEAD moved during the sweep, or a tag appeared: HARNESS_SHA=${clean} at its start, campaign-1 at its end \([0-9T:-]+Z\); the files under" "$r/tests/out/rec/sweep-outcome.txt"
	assert_output --partial "note: HEAD moved during the sweep, or a tag appeared"
	# Interrupted (SIGTERM) after a tag: the record stays not finished, with the INFO.
	git -C "$r" tag -d campaign-1 >/dev/null
	rm -rf "$r/tests/out/rec"
	HARNESS_SHA_CHECK_SEC=0 run --separate-stderr bash -c '
		source "$2/tests/lib/common.sh"
		ROOT="$1"
		trap '\''sweep_outcome_on_exit "$?" || true'\'' EXIT
		harness_sha_for_sweep "$1/tests/out"
		sweep_outcome_start "$1/tests/out/rec" hs-run --next "run it again"
		git -C "$ROOT" -c user.email=ci@example.com -c user.name=ci tag -a campaign-2 -m rel
		kill -TERM $$
		echo after' _ "$r" "$ROOT"
	[ "$status" -eq 143 ]
	grep -qx 'EXIT=unfinished' "$r/tests/out/rec/sweep-outcome.txt"
	grep -qE "^INFO=HEAD moved during the sweep, or a tag appeared: HARNESS_SHA=${clean} at its start, campaign-2 at its end" "$r/tests/out/rec/sweep-outcome.txt"
	! grep -q '^NOTE=the harness changed' "$r/tests/out/rec/sweep-outcome.txt"
}

@test "the -dirty hash names only the harness paths (a docs commit leaves a dirty tree's value) and is the content key's first 8 hex; the clone's own info/attributes and a filter driver never change it" {
	local r="${BATS_TEST_TMPDIR}/repo" clean v key
	_repo "$r"
	clean="$(ROOT="$r" harness_sha)"
	printf 'one\r\ntwo\r\n' > "$r/tests/crlf.txt"
	git -C "$r" add tests/crlf.txt
	_git "$r" commit -q -m crlf
	clean="$(ROOT="$r" harness_sha)"
	printf 'scratch\n' > "$r/tests/untracked.txt"
	v="$(ROOT="$r" harness_sha)"
	key="$(ROOT="$r" harness_content_key)"
	[[ "$v" =~ ^${clean}-dirty\.[0-9a-f]{8}$ ]]
	[ "${v##*.}" = "${key:0:8}" ]
	# A clean tree has a key too: HEAD's harness files.
	[ "$(ROOT="$r" harness_content_key --exclude "$r/tests")" != "$key" ]
	# A commit under docs/ moves HEAD: the same dirty hash and key, after the new describe.
	printf 'x\n' > "$r/docs/new.md"
	git -C "$r" add docs/new.md
	_git "$r" commit -q -m docs
	[ "$(ROOT="$r" harness_content_key)" = "$key" ]
	[ "$(ROOT="$r" harness_sha)" = "$(git -C "$r" describe --always --abbrev=7)-dirty.${key:0:8}" ]
	v="$(ROOT="$r" harness_sha)"
	# $GIT_DIR/info/attributes (per clone): eol and text normalisation, and a clean filter
	# that rewrites every file, change nothing: the files are hashed as they are on disk.
	mkdir -p "$r/.git/info"
	printf '* text=auto eol=lf\n' > "$r/.git/info/attributes"
	[ "$(ROOT="$r" harness_sha)" = "$v" ]
	printf '* filter=up\n' > "$r/.git/info/attributes"
	git -C "$r" config filter.up.clean "tr a-z A-Z"
	[ "$(ROOT="$r" harness_sha)" = "$v" ]
	# The check is real: git itself does filter under that attribute.
	[ "$(git -C "$r" check-attr filter -- tests/f)" = "tests/f: filter: up" ]
	rm -f "$r/.git/info/attributes"
	# An executable bit still counts; a removed tracked file too.
	chmod +x "$r/tests/f"
	[ "$(ROOT="$r" harness_sha)" != "$v" ]
	chmod -x "$r/tests/f"
	rm -f "$r/tests/f"
	[ "$(ROOT="$r" harness_sha)" != "$v" ]
	git -C "$r" checkout -q -- tests/f
	[ "$(ROOT="$r" harness_sha)" = "$v" ]
	# A path a line would change (a newline, a leading quote) is hashed as it is.
	printf 'n\n' > "$r/tests/new"$'\n'"line"
	printf 'q\n' > "$r/tests/\"quoted"
	[[ "$(ROOT="$r" harness_sha)" =~ ^[0-9a-f]{7}-dirty\.[0-9a-f]{8}$ ]]
	[ "$(ROOT="$r" harness_sha)" != "$v" ]
	rm -f "$r/tests/new"$'\n'"line" "$r/tests/\"quoted"
	[ "$(ROOT="$r" harness_sha)" = "$v" ]
	# Not a checkout: unknown.
	mkdir -p "${BATS_TEST_TMPDIR}/plain"
	[ "$(ROOT="${BATS_TEST_TMPDIR}/plain" harness_content_key)" = unknown ]
}

@test "istiod-diag's index.tsv leaves out the probe's output dir it is in: its HARNESS_SHA and HARNESS_CONTENT_KEY are the probe's" {
	local r="${BATS_TEST_TMPDIR}/repo" clean
	_repo "$r"
	clean="$(ROOT="$r" harness_sha)"
	mkdir -p "$r/tests/out"
	printf 'row\n' > "$r/tests/out/latency-x.tsv"
	[ "$(ROOT="$r" harness_sha)" != "$clean" ]
	run bash -c '
		source "$2/tests/lib/common.sh"
		source "$2/tests/lib/config.sh"
		source "$2/tests/lib/reach.sh"
		source "$2/tests/lib/istiod-diag.sh"
		ROOT="$1"
		_istiod_diag_settings
		_istiod_diag_init "$1/tests/out/istiod-diag-RUN1"' _ "$r" "$ROOT"
	assert_success
	grep -qx "# HARNESS_SHA=${clean}" "$r/tests/out/istiod-diag-RUN1/index.tsv"
	grep -qx "# HARNESS_CONTENT_KEY=$(ROOT="$r" harness_content_key --exclude "$r/tests/out")" "$r/tests/out/istiod-diag-RUN1/index.tsv"
}

@test "through the controlplane sweep: a docs-only commit while it runs is an INFO in its outcome, no WARNING or harness PROBLEM, and the next cell's probe records the start's HARNESS_SHA" {
	local r="${BATS_TEST_TMPDIR}/cp" bin="${BATS_TEST_TMPDIR}/bin" ek="${BATS_TEST_TMPDIR}/kubeconfig" res="${BATS_TEST_TMPDIR}/res" clean d
	mkdir -p "$r/tests/lib/test" "$r/docs"
	cp -R "${ROOT}/config" "$r/config"
	cp "${ROOT}"/tests/lib/*.sh "$r/tests/lib/"
	cp -R "${ROOT}/tests/lib/test/fixtures" "$r/tests/lib/test/fixtures"
	(cd "${ROOT}/tests" && tar -cf - --exclude=results --exclude='*.local.env' controlplane) | (cd "$r/tests" && tar -xf -)
	cp "${ROOT}/.gitignore" "$r/.gitignore"
	printf 'doc\n' > "$r/docs/d.md"
	git -C "$r" init -q
	git -C "$r" add -A
	_git "$r" commit -q -m init
	clean="$(ROOT="$r" harness_sha)"
	: > "$ek"
	mkdir -p "$bin"
	# 002's first istiod read commits a docs change in the copy (once) and fails, as
	# everything else does.
	cat > "${bin}/kubectl" <<'STUB'
#!/bin/sh
case "$*" in
*"get istios.sailoperator.io default"*|*"get istiorevisions.sailoperator.io"*|*"get deployments.apps istiod -o json"*)
	exec "$HP_FAKE_CR" "$@" ;;
*" -n istio-system get pods -l app=istiod --field-selector=status.phase=Running -o jsonpath="*)
	if [ ! -e "$HP_DIR/committed" ]; then
		echo note >> "$HP_REPO/docs/d.md"
		git -C "$HP_REPO" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -q -am "docs: note" >/dev/null 2>&1
		: > "$HP_DIR/committed"
	fi
	exit 1 ;;
*) exit 1 ;;
esac
STUB
	chmod +x "${bin}/kubectl"
	HP_FAKE_CR="${ROOT}/tests/lib/test/fixtures/fake-istio-cr.sh" HP_REPO="$r" HP_DIR="$BATS_TEST_TMPDIR" \
		HARNESS_SHA_CHECK_SEC=0 ISTIO_VERSION_CHECK=warn CONTROLPLANE_SETTLE_SEC=0 METRICS_READY_TIMEOUT=0 \
		ISTIO_VERSION_READY_WAIT_SEC=0 PATH="${bin}:${PATH}" KUBECONFIG="$ek" CONTROLPLANE_RESULTS_DIR="$res" \
		run --separate-stderr bash "$r/tests/controlplane/003-run-sweep.sh" --contexts ci-a --mesh-sizes 1 --service-counts 5,6
	[ -e "${BATS_TEST_TMPDIR}/committed" ]
	[ "$(git -C "$r" describe --always --abbrev=7)" != "$clean" ]
	d="$(find "$res" -maxdepth 1 -name 'sweep-*' -type d)"
	[[ "$stderr" != *"WARNING: the harness changed"* ]] || { echo "$stderr"; false; }
	! grep -q '^PROBLEM=the harness changed' "$d/sweep-outcome.txt"
	grep -qE "^INFO=HEAD moved during the sweep, or a tag appeared: HARNESS_SHA=${clean} at its start" "$d/sweep-outcome.txt"
	# Both cells' probes recorded the start's value, though HEAD moved in the first.
	[ "$(grep -cE '^\[002\] RUN_ID=.*HARNESS_SHA=' <<<"$output")" -ge 2 ] || { echo "$output"; false; }
	[ "$(grep -E '^\[002\] RUN_ID=.*HARNESS_SHA=' <<<"$output" | grep -cv "HARNESS_SHA=${clean}$")" -eq 0 ] || { echo "$output"; false; }
	grep -qx "HARNESS_SHA=${clean}" "$d/sweep-outcome.txt"
}

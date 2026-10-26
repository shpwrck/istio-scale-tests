#!/usr/bin/env bats
# --help of every numbered script (tests/*/ and terraform/*/scripts/) and of tests/lib's two
# tools (redact-results.sh, verify.sh): it exits 0 without a cluster call, and names every --flag
# its own argument parser accepts (its case arms), so a flag the parser takes is never missing
# from its help. One --help per script, no run.

bats_require_minimum_version 1.5.0
load test_helper

# _parser_flags <script>: the long flags of the script's case arms (`--flag)`, `--flag=*)`,
# `-x|--flag)`, `--a | --b)`), one per line, sorted. An arm that only dies (a removed flag the
# parser rejects) is left out, and so is --help itself (its exit 0 shows it).
_parser_flags() {
	grep -E '^[[:space:]]*-{1,2}[A-Za-z0-9][A-Za-z0-9-]*(=\*)?([[:space:]]*\|[[:space:]]*-{1,2}[A-Za-z0-9][A-Za-z0-9-]*(=\*)?)*\)' "$1" |
		grep -vE '\)[[:space:]]*die[[:space:]]' |
		sed -E 's/\).*//' | tr '|' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/=\*$//' |
		grep -E '^--[a-z0-9][a-z0-9-]*$' | grep -vx -- '--help' | LC_ALL=C sort -u
}

@test "every numbered script's --help, and redact-results.sh's and verify.sh's, exits 0 without a cluster call and names every flag its parser accepts" {
	local bin="${BATS_TEST_TMPDIR}/bin" kc="${BATS_TEST_TMPDIR}/empty.kubeconfig" f fl out rc n=0 bad=0
	mkdir -p "$bin"
	export STUB_LOG="${BATS_TEST_TMPDIR}/calls.log"
	printf '#!/bin/sh\necho "kubectl $*" >> "$STUB_LOG"\nexit 1\n' > "${bin}/kubectl"
	printf '#!/bin/sh\necho "oc $*" >> "$STUB_LOG"\nexit 1\n' > "${bin}/oc"
	chmod +x "${bin}/kubectl" "${bin}/oc"
	: > "$kc"
	: > "$STUB_LOG"
	for f in "$ROOT"/tests/*/[0-9]*.sh "$ROOT"/terraform/*/scripts/[0-9]*.sh "$ROOT"/tests/lib/redact-results.sh "$ROOT"/tests/lib/verify.sh; do
		n=$((n + 1))
		rc=0
		out="$(PATH="${bin}:${PATH}" KUBECONFIG="$kc" bash "$f" --help 2>&1)" || rc=$?
		if ((rc != 0)); then
			echo "${f#"$ROOT"/} --help: exit ${rc}"
			bad=1
			continue
		fi
		while IFS= read -r fl; do
			[[ -n "$fl" ]] || continue
			grep -qE -- "(^|[^a-z0-9-])${fl}([^a-z0-9-]|$)" <<<"$out" || { echo "${f#"$ROOT"/} --help: no ${fl}"; bad=1; }
		done < <(_parser_flags "$f")
	done
	((bad == 0))
	# Every suite's scripts and the Terraform helpers were found.
	((n >= 30))
	[ ! -s "$STUB_LOG" ] || { cat "$STUB_LOG"; false; }
}

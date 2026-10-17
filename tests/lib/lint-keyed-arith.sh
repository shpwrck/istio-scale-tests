#!/usr/bin/env bash
# Lint: flag an array element read by a variable key inside shell arithmetic.
#
# Why: bash 4.3 to 5.1 expand such a key twice. With a key holding a quote, a `$` or
# `]` (a kube context name, a file name), `(( count[$k] + 1 ))` stops with "bad array
# subscript" and `[[ -v seen[$k] ]]` reads false for a key that is set. bash 5.2 expands
# once, so the bug only shows on older hosts (RHEL 9 ships 5.1). Read the element into
# a scalar first (n="${count[$k]}"; count[$k]=$((n + 1))), test it with
# [[ -n "${seen[$k]+x}" ]], or compare the expanded value ([[ "${x[$k]}" -gt 0 ]]).
#
# Forms flagged (bare name[$k] or name["$k"], not ${name[$k]}):
#   (( ... name[$k] ... ))  and  $(( ... name[$k] ... ))
#   let ... name[$k] ...
#   [[ name[$k] -gt N ]]  and  [[ N -lt name[$k] ]]   (-eq -ne -lt -le -gt -ge)
#   [[ -v name[$k] ]]  and  test -v "name[$k]"
# Full-line comments are skipped. Deterministic awk, no gawk extensions (macOS awk too).
#
# Usage:
#   source tests/lib/lint-keyed-arith.sh
#   lint_keyed_arith_file <file>        # prints offenders; returns 1 if any
#   lint_keyed_arith_paths <path>...    # every *.sh under the paths (bats-* skipped)

# lint_keyed_arith_file <file>
#   Prints "<file>:<lineno>: <form>: <line>" per offender; returns 0 if clean, 1 if not.
lint_keyed_arith_file() {
	local file="$1"
	[[ -f "$file" ]] || return 0
	awk -v FILE="$file" '
		BEGIN { bad = 0 }
		{
			t = $0
			sub(/^[ \t]+/, "", t)
			if (t == "" || t ~ /^#/) next
			form = ""
			# Bare element: a name not preceded by { # ! $ or a name character, then
			# [ and an optional quote before the $ of the key.
			el = "(^|[^{#!$A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*\\[\"?\\$"
			if (match(t, /\(\(/)) {
				# The text after each (( up to the next ), as the old M1 grep read it.
				s = t
				while (match(s, /\(\(/)) {
					s = substr(s, RSTART + 2)
					seg = s
					sub(/\).*$/, "", seg)
					if (seg ~ el) { form = "arithmetic (( ))"; break }
				}
			}
			if (form == "" && match(t, /(^|[;&|({ \t])let[ \t]/)) {
				seg = substr(t, RSTART + RLENGTH)
				if (seg ~ el) form = "let"
			}
			if (form == "" && t ~ /\[\[/) {
				if (t ~ ("(^|[ \t(!])[A-Za-z_][A-Za-z0-9_]*\\[\"?\\$[^]]*\\][ \t]+-(eq|ne|lt|le|gt|ge)[ \t]") \
					|| t ~ ("[ \t]-(eq|ne|lt|le|gt|ge)[ \t]+[A-Za-z_][A-Za-z0-9_]*\\[\"?\\$"))
					form = "[[ -eq/-lt/... ]]"
			}
			if (form == "" && t ~ /(^|[ \t;&|(!])-v[ \t]+"?[A-Za-z_][A-Za-z0-9_]*\["?\$/) form = "-v test"
			if (form != "") { printf "%s:%d: %s reads an array element by a variable key: %s\n", FILE, FNR, form, t; bad++ }
		}
		END { exit (bad > 0 ? 1 : 0) }
	' "$file"
}

# lint_keyed_arith_paths <path>...
#   Lints every *.sh under each directory (or each file given); skips the bats-* submodules.
lint_keyed_arith_paths() {
	local rc=0 f p
	for p in "$@"; do
		if [[ -f "$p" ]]; then
			lint_keyed_arith_file "$p" || rc=1
			continue
		fi
		[[ -d "$p" ]] || continue
		while IFS= read -r f; do
			lint_keyed_arith_file "$f" || rc=1
		done < <(find "$p" -name 'bats-*' -prune -o -type f -name '*.sh' -print | LC_ALL=C sort)
	done
	return "$rc"
}

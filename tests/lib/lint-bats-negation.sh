#!/usr/bin/env bash
# Lint: flag a `! cmd` assertion in a bats test that is not the test's last command.
#
# Why: bats runs a test under `set -e` plus an ERR trap, and bash exempts a pipeline
# negated with `!` from both, so `! grep -q x "$f"` in the middle of a test never fails
# it, whatever grep finds: only the test's last command sets its status. The same holds
# in a loop (only the last pass counts), an `if` body and a `{ }` group. Write
# `! cmd || false` (keeps $output and $status) or `run ! cmd` (bats 1.5+; overwrites
# them). bats-assert's refute, refute_output and refute_line fail properly.
#
# Flagged: a line that starts with `! ` inside a top-level block of a .bats file (an
# @test, setup/teardown or a helper: a column-0 line ending in `{` or `{ # ...`, up to
# the column-0 `}`) when it is not the block's last command and does not hand the
# failure on with `|| false`, `|| return`, `|| exit`, `|| fail` (bats-support) or
# `|| { ...; false; }`.
# Heredoc bodies (stub scripts) and comments are skipped; `\` continuations are joined.
# A multi-line quoted script (`bash -c '...'`) is read as test lines: end such a line with
# `|| false` too, or write the script as a heredoc.
# A `!` after `;` or `&&` on a line is not read. Deterministic awk, no gawk extensions
# (macOS awk too).
#
# Usage:
#   source tests/lib/lint-bats-negation.sh
#   lint_bats_negation_file <file>        # prints offenders; returns 1 if any
#   lint_bats_negation_paths <path>...    # every *.bats under the paths (bats-* skipped)

# lint_bats_negation_file <file>
#   Prints "<file>:<lineno>: ...: <line>" per offender; returns 0 if clean, 1 if not.
lint_bats_negation_file() {
	local file="$1"
	[[ -f "$file" ]] || return 0
	awk -v FILE="$file" '
		function flag() {
			printf "%s:%d: a negated command that is not the test'"'"'s last never fails it (add || false, or use run !): %s\n", FILE, pn, pt
			bad++
			pn = 0
		}
		BEGIN { bad = 0; inb = 0; hd = ""; pn = 0; acc = ""; an = 0 }
		{
			# A heredoc body (a stub script the test writes) is data: skip to its delimiter.
			if (hd != "") {
				t = $0
				if (hdtab) sub(/^\t+/, "", t)
				if (t == hd) hd = ""
				next
			}
			# One logical line per \ continuation, numbered by its first line.
			if (an == 0) an = FNR
			if ($0 ~ /\\$/) { acc = acc substr($0, 1, length($0) - 1) " "; next }
			line = acc $0; n = an; acc = ""; an = 0
			if (!inb) {
				if (line ~ /^[^ \t#}].*[{][ \t]*(#.*)?$/) inb = 1
			} else if (line ~ /^}/) {
				pn = 0  # the negation was the block'"'"'s last command: its status is the block'"'"'s
				inb = 0
			} else {
				t = line
				sub(/^[ \t]+/, "", t)
				if (t != "" && t !~ /^#/) {
					if (pn) flag()
					if (t ~ /^![ \t]/ && t !~ /[|][|][ \t]*([{].*[;{ \t])?(false|return|exit|fail)([ \t;}]|$)/) {
						pn = n
						pt = t
					}
				}
			}
			# A heredoc starts on the next line: <<EOF, <<-'"'"'EOF'"'"', << "EOF" (not <<<).
			if (match(line, /(^|[^<])<<-?[ \t]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*/)) {
				h = substr(line, RSTART, RLENGTH)
				sub(/^[^<]*<</, "", h)
				hdtab = (h ~ /^-/)
				sub(/^-?[ \t]*["'"'"']?/, "", h)
				hd = h
			}
		}
		END { if (pn) flag(); exit (bad > 0 ? 1 : 0) }
	' "$file"
}

# lint_bats_negation_paths <path>...
#   Lints every *.bats under each directory (or each file given); skips the bats-* submodules.
lint_bats_negation_paths() {
	local rc=0 f p
	for p in "$@"; do
		if [[ -f "$p" ]]; then
			lint_bats_negation_file "$p" || rc=1
			continue
		fi
		[[ -d "$p" ]] || continue
		while IFS= read -r f; do
			lint_bats_negation_file "$f" || rc=1
		done < <(find "$p" -name 'bats-*' -prune -o -type f -name '*.bats' -print | LC_ALL=C sort)
	done
	return "$rc"
}

#!/usr/bin/env bash
# Lint: flag bare statement-position calls to by-design-non-zero scrape functions.
#
# Why: functions like fanout_scrape_all / fanout_scrape_aggregate / scrape_ctx return
# NON-ZERO BY DESIGN on an incomplete/empty fanned-out scrape (PL29). Under
# `set -euo pipefail`, a BARE call in statement position aborts the whole script before
# the next line can inspect the .failed sidecar and tag the row — this is exactly the
# overnight "churn size-8 scrape abort" incident (#31). Such a call MUST be either:
#   - captured:   X="$(fanout_scrape_all ...)"           (statement no longer bare)
#   - guarded:    fanout_scrape_all ... || true          (|| / && absorbs the non-zero)
#   - a condition: if ! fanout_scrape_all ...; then ...   (the line starts with if/while)
#   - a function tail: the call is the LAST statement of a wrapper function, so its
#                      non-zero becomes the function's return (legitimate propagation;
#                      e.g. scrape_ctx() { ...; fanout_scrape_all ...; })
#
# This linter is deterministic and awk-based (no shuf/randomness; PL16-spirit). It is
# wired into tests/lib/verify.sh as a numbered check and covered by bats fixtures.
#
# Usage:
#   source tests/lib/lint-bare-scrape.sh
#   lint_bare_scrape_file <file>          # prints offenders to stdout; returns 1 if any
#   lint_bare_scrape_paths <path>...      # lints each *.sh under the given paths/files

# The set of functions whose non-zero exit is by-design and therefore must never be
# left bare in statement position. Extend this list as new such helpers are added.
LINT_BARE_SCRAPE_FUNCS="${LINT_BARE_SCRAPE_FUNCS:-fanout_scrape_all fanout_scrape_aggregate scrape_ctx}"

# lint_bare_scrape_file <file>
#   Emits one "<file>:<lineno>: bare call to <fn> ..." line per offender on stdout.
#   Returns 0 if clean, 1 if any offender found.
lint_bare_scrape_file() {
	local file="$1"
	[[ -f "$file" ]] || return 0
	awk -v FNAMES="$LINT_BARE_SCRAPE_FUNCS" -v FILE="$file" '
		BEGIN {
			nf = split(FNAMES, fa, /[ \t]+/)
			for (i = 1; i <= nf; i++) watch[fa[i]] = 1
			offenders = 0
		}
		# Slurp every line so we can look AHEAD for a function-closing brace.
		{ lines[NR] = $0 }
		END {
			for (n = 1; n <= NR; n++) {
				line = lines[n]
				# Trim leading whitespace.
				t = line
				sub(/^[ \t]+/, "", t)
				# Skip comments and blank lines.
				if (t ~ /^#/ || t == "") continue
				# First token = up to first whitespace, "(", or quote.
				tok = t
				sub(/[ \t("'"'"'`].*$/, "", tok)
				if (!(tok in watch)) continue
				# A definition line "fn() {" or "fn ()" is not a call.
				if (t ~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/) continue
				# Guarded by || or && anywhere on the line -> OK.
				if (t ~ /\|\|/ || t ~ /&&/) continue
				# Function-tail return propagation: the next non-blank, non-comment
				# line is a closing brace "}" -> the call IS the function return -> OK.
				is_tail = 0
				for (m = n + 1; m <= NR; m++) {
					nx = lines[m]
					sub(/^[ \t]+/, "", nx)
					if (nx == "" || nx ~ /^#/) continue
					if (nx == "}" || nx ~ /^}[ \t]*(#.*)?$/) is_tail = 1
					break
				}
				if (is_tail) continue
				# Otherwise: bare statement-position call to a by-design-non-zero fn.
				printf "%s:%d: bare call to %s (capture in $(...), guard with || true, or use as an if/while condition)\n", FILE, n, tok
				offenders++
			}
			exit (offenders > 0 ? 1 : 0)
		}
	' "$file"
}

# B7: flag bare per-combo orchestrator-step calls.
#
# Why: a sweep orchestrator's per-combo step `"$SCRIPT_DIR/00N-*.sh" …` (setup / probe
# / cleanup) returns non-zero on a per-combo failure; bare in statement position it
# aborts the entire multi-hour sweep under `set -e`, discarding every completed combo
# (this is the B1 regression class). Such a call must be captured, `|| …`'d, or used
# as an `if`/`while` condition so the failure becomes a recorded row + continue.
#
# Scope/exemptions (deterministic — no fragile loop-depth tracking):
#   - Only `*-run-sweep.sh` files are checked.
#   - Only statement-position calls (the trimmed line STARTS with the
#     "$SCRIPT_DIR/0NN-...sh" token — so captures `X="$(…)"` and `if !/while`
#     conditions, which start with other tokens, are inherently excluded).
#   - REPORT/aggregation steps are exempted by name: a post-loop report failure is
#     acceptable (the sweep already produced its TSVs), and report scripts are
#     conventionally the last call. Exempted suffixes: -report-results.sh,
#     -collect-pilot-metrics.sh, -compare-profiles.sh.
#   - Guarded (`|| …` / `&& …`) or function-tail calls pass.
#
# lint_bare_orchestrator_step_file <file>
#   Only meaningful for *-run-sweep.sh; emits offenders, returns 1 if any.
lint_bare_orchestrator_step_file() {
	local file="$1"
	[[ -f "$file" ]] || return 0
	awk -v FILE="$file" '
		BEGIN { offenders = 0 }
		{ lines[NR] = $0 }
		END {
			for (n = 1; n <= NR; n++) {
				line = lines[n]
				t = line
				sub(/^[ \t]+/, "", t)
				if (t ~ /^#/ || t == "") continue
				# Statement-position "$SCRIPT_DIR/0NN-...sh" call?
				if (t !~ /^"\$SCRIPT_DIR(\/|")[^"]*0[0-9][0-9]-[^"]*\.sh"/) continue
				# Exempt report/aggregation steps (post-loop; failure acceptable).
				if (t ~ /-report-results\.sh"/ || t ~ /-collect-pilot-metrics\.sh"/ || t ~ /-compare-profiles\.sh"/) continue
				# Guarded by || or && anywhere on the line -> OK.
				if (t ~ /\|\|/ || t ~ /&&/) continue
				# Function-tail (next non-blank, non-comment line is "}") -> OK.
				is_tail = 0
				for (m = n + 1; m <= NR; m++) {
					nx = lines[m]; sub(/^[ \t]+/, "", nx)
					if (nx == "" || nx ~ /^#/) continue
					if (nx == "}" || nx ~ /^}[ \t]*(#.*)?$/) is_tail = 1
					break
				}
				if (is_tail) continue
				step = t; sub(/[ \t].*$/, "", step)
				printf "%s:%d: bare orchestrator-step call %s (wrap with `if ! …; then warn; record; continue; fi` or `|| { … }`)\n", FILE, n, step
				offenders++
			}
			exit (offenders > 0 ? 1 : 0)
		}
	' "$file"
}

# lint_bare_scrape_paths <path>...
#   Recurses into directories for *.sh files; lints individual files directly.
#   Runs the scrape-call lint on every *.sh, and the orchestrator-step lint on
#   *-run-sweep.sh. Returns 0 if all clean, 1 if any offender found.
lint_bare_scrape_paths() {
	local rc=0 p f
	for p in "$@"; do
		if [[ -d "$p" ]]; then
			while IFS= read -r f; do
				lint_bare_scrape_file "$f" || rc=1
				case "$f" in
					*-run-sweep.sh) lint_bare_orchestrator_step_file "$f" || rc=1 ;;
				esac
			done < <(find "$p" -name '*.sh' -type f 2>/dev/null | sort)
		elif [[ -f "$p" ]]; then
			lint_bare_scrape_file "$p" || rc=1
			case "$p" in
				*-run-sweep.sh) lint_bare_orchestrator_step_file "$p" || rc=1 ;;
			esac
		fi
	done
	return "$rc"
}

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

# B7 / R3-2: flag bare per-combo / per-profile orchestrator-step calls.
#
# Why: a sweep orchestrator's per-iteration step — e.g. `"$SCRIPT_DIR/00N-*.sh" …` or
# `"${TUNING_DIR}/00N-*.sh" …` (setup / probe / cleanup / apply / revert) — returns
# non-zero on a per-iteration failure; bare in statement position it aborts the entire
# multi-hour sweep under `set -e`, discarding every completed iteration (the B1
# regression class). Such a call must be captured, `|| …`'d, or used as an `if`/`while`
# condition so the failure becomes a recorded marker/row + continue.
#
# Scope/exemptions (deterministic — no fragile loop-depth tracking):
#   - Checked for every sweep orchestrator: files matching `*-sweep.sh` (R4-1 — the
#     dispatch glob in lint_bare_scrape_paths; this includes the 5 `00N-run-sweep.sh`
#     AND tuning's `003-run-tuning-sweep.sh`, which `*-run-sweep.sh` silently missed).
#   - Anchor (R3-2): the LOGICAL line STARTS with a `"${VAR}/…/0NN-name.sh"` token —
#     ANY `$VAR`/`${VAR}`-prefixed path to an `0NN-`-numbered script, not just the
#     literal `$SCRIPT_DIR` (the original anchor silently missed tuning's
#     `${TUNING_DIR}/001-apply-profile.sh`). Statement-position only, so captures
#     `X="$(…)"` and `if !/while` conditions (which start with other tokens) are
#     inherently excluded.
#   - REPORT/aggregation steps are exempted by name: a post-loop report failure is
#     acceptable (the sweep already produced its TSVs), and report scripts are
#     conventionally the last call. Exempted suffixes: -report-results.sh,
#     -collect-pilot-metrics.sh, -compare-profiles.sh.
#   - Guarded (`|| …` / `&& …`) or function-tail calls pass.
#
# Multi-line robustness (R4-2): a step call is commonly written across several
# physical lines via trailing `\` continuations, with the `|| …`/`&& …` guard on a
# LATER continuation line. We therefore JOIN `\`-continued physical lines into one
# LOGICAL line BEFORE testing the guard/anchor exemptions; inspecting only the first
# physical line would mis-flag a legitimately-guarded multi-line revert as bare.
#
# lint_bare_orchestrator_step_file <file>
#   Only meaningful for sweep orchestrators (*-sweep.sh); emits offenders, returns 1.
lint_bare_orchestrator_step_file() {
	local file="$1"
	[[ -f "$file" ]] || return 0
	awk -v FILE="$file" '
		BEGIN { offenders = 0; nl = 0 }
		{
			# Build LOGICAL lines by joining trailing-backslash continuations. Record
			# the starting physical line number of each logical line for reporting.
			cur = $0
			if (building) {
				logical[nl] = logical[nl] " " cur
			} else {
				nl++
				logical[nl] = cur
				startline[nl] = NR
			}
			# Continue if THIS physical line ends with an unescaped trailing backslash.
			if (cur ~ /\\[ \t]*$/) {
				# Strip the trailing backslash from the accumulated logical line so the
				# joined text reads as a single command (the next piece appends after it).
				sub(/\\[ \t]*$/, "", logical[nl])
				building = 1
			} else {
				building = 0
			}
		}
		END {
			for (n = 1; n <= nl; n++) {
				t = logical[n]
				sub(/^[ \t]+/, "", t)
				if (t ~ /^#/ || t == "") continue
				# Statement-position "${VAR}/.../0NN-name.sh" call (any ${VAR}/ or $VAR/
				# prefix; R3-2)? Tested on the JOINED logical line (R4-2).
				if (t !~ /^"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?\/[^"]*0[0-9][0-9]-[^"]*\.sh"/) continue
				# Exempt report/aggregation steps (post-loop; failure acceptable).
				if (t ~ /-report-results\.sh"/ || t ~ /-collect-pilot-metrics\.sh"/ || t ~ /-compare-profiles\.sh"/) continue
				# Guarded by || or && ANYWHERE in the logical line (incl. continuations) -> OK.
				if (t ~ /\|\|/ || t ~ /&&/) continue
				# Function-tail (next non-blank, non-comment LOGICAL line is "}") -> OK.
				is_tail = 0
				for (m = n + 1; m <= nl; m++) {
					nx = logical[m]; sub(/^[ \t]+/, "", nx)
					if (nx == "" || nx ~ /^#/) continue
					if (nx == "}" || nx ~ /^}[ \t]*(#.*)?$/) is_tail = 1
					break
				}
				if (is_tail) continue
				step = t; sub(/[ \t].*$/, "", step)
				printf "%s:%d: bare orchestrator-step call %s (wrap with `if ! …; then warn; record; continue; fi` or `|| { … }`)\n", FILE, startline[n], step
				offenders++
			}
			exit (offenders > 0 ? 1 : 0)
		}
	' "$file"
}

# lint_bare_scrape_paths <path>...
#   Recurses into directories for *.sh files; lints individual files directly.
#   Runs the scrape-call lint on every *.sh, and the orchestrator-step lint on every
#   sweep orchestrator. R4-1: dispatch glob is `*-sweep.sh` (NOT `*-run-sweep.sh`),
#   so tuning's `003-run-tuning-sweep.sh` is also routed through verify — it ends
#   `-run-tuning-sweep.sh` and would otherwise escape the orchestrator-step lint
#   entirely. `*-sweep.sh` matches exactly the 6 orchestrators and no other file.
#   Returns 0 if all clean, 1 if any offender found.
lint_bare_scrape_paths() {
	local rc=0 p f
	for p in "$@"; do
		if [[ -d "$p" ]]; then
			while IFS= read -r f; do
				lint_bare_scrape_file "$f" || rc=1
				case "$f" in
					*-sweep.sh) lint_bare_orchestrator_step_file "$f" || rc=1 ;;
				esac
			done < <(find "$p" -name '*.sh' -type f 2>/dev/null | sort)
		elif [[ -f "$p" ]]; then
			lint_bare_scrape_file "$p" || rc=1
			case "$p" in
				*-sweep.sh) lint_bare_orchestrator_step_file "$p" || rc=1 ;;
			esac
		fi
	done
	return "$rc"
}

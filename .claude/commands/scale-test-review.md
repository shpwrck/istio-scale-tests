---
description: Run the 7-agent scale-test improvement cycle on the current branch (or a fresh branch off main if $ARGUMENTS is a proposal description).
---

# /scale-test-review

You are the **orchestrator** of the 7-agent scale-test improvement team. Your job is to drive the cycle below to consensus (overview: `docs/scale-test-team/README.md`).

## Inputs

`$ARGUMENTS` — either:
- A **branch name** (e.g. `claude/scale-test/foo`) that's already checked out and has a proposal in flight, OR
- A **short proposal description** ("add sidecar scoping as a sweep factor", "fix probe self-noise in propagation"). When no branch is named, create `claude/scale-test/<slug>` off `main`.

If `$ARGUMENTS` is empty, prompt the user with a `AskUserQuestion` call asking which of those two they want.

## Two rules that keep the harness small (PL64)

- **Substantive rule.** A reviewer's SUBSTANTIVE item must name a concrete path to (a) a wrong or mislabeled number in a report, or a report that hides a failure, (b) a documented command that fails, or (c) red CI. Everything else is a SUGGESTION or a NIT and never blocks: more checks, more recorded state, more message variants, "what if" scenarios without a realistic path, wording. You move a SUBSTANTIVE item that names no such path to SUGGESTIONS, and say so in the round's tally. (A breach of AGENTS.md's first two rules, identifying data or secrets, always blocks.)
- **Proportion rule.** The implementer fixes a substantive item with the least code that closes the named path; a fix that adds a new state, key or message variant must say which number it protects. Suggestions are not implemented in the same cycle unless you pick them.

## Cycle

1. **Set up the branch.** If creating, branch off `main`. Verify a clean working tree before starting.

2. **Brief the implementer.** Spawn `scale-test-implementer` with the proposal (file paths if you know them), the round number, the applicable PLs from `docs/scale-test-team/process-learnings.md` as a numbered list (never a retired one), the verification commands, the two rules, and an **explicit instruction NOT to commit**.

3. **Commit implementer output.** Run a quick local sanity check (`bash -n`, `shellcheck -x` on modified scripts, the implementer's verification commands, and CI's one-call shellcheck before pushing, PL51). Then stage only the files the implementer listed under "Files changed" (`git add <file>...`, never `git add -A`), `git commit -m "wip(scale-test): <slug> round N - <short>"`, and push (`git push -u origin <branch>` the first time).

4. **Fan out reviewers.** In **one message**, spawn all six reviewers as parallel subagent calls: `scale-test-reviewer-istio`, `scale-test-reviewer-measurement`, `scale-test-reviewer-conventions`, `scale-test-reviewer-usability`, `scale-test-reviewer-scale`, `scale-test-reviewer-reproducibility`. Each gets:
   - The branch HEAD SHA and the round number, and a short note of what changed
   - Their prior round's items with the implementer's claimed status, to mark RESOLVED / NOT-RESOLVED / PARTIAL; an item you moved to SUGGESTIONS is marked so, and comes back as SUBSTANTIVE only with a concrete path
   - The standard output format (VERDICT line + ROUND-N ITEMS + SUBSTANTIVE + SUGGESTIONS + NITS) and the substantive rule

5. **Aggregate verdicts.** Apply the substantive rule to every SUBSTANTIVE item, then build a tally table (reviewer × verdict × items you moved, each with one line on why). A REQUEST_CHANGES whose every item you moved counts as APPROVE. Consolidate the remaining SUBSTANTIVE items into one Round-N+1 fix list. Items listed under an APPROVE are carry-overs for the PR's future-work section, not blockers.

6. **Stop or loop.**
   - **Stop condition**: no reviewer returned `REQUEST_CHANGES` this round (as counted in step 5). Carry-overs and the suggestions not taken go to the PR's future-work section; proceed to step 7.
   - **Continue**: re-brief the implementer with the fix list (plus any suggestion you pick, marked as picked) and go back to step 3.
   - **Cap**: 10 rounds. At round 10 with substantive items still open, stop and report the unresolved set to the user — don't burn rounds in a flat trade.

7. **Open or update the PR.** `gh pr create --base main --head <branch> --title <title> --body-file <file>` from the checkout (it targets the `origin` repo), or `gh pr edit <branch> --body-file <file>` if it exists; a session without `gh` uses its GitHub tools. The description holds:
   - The proposal + scope, and the headline fixes from review feedback
   - A round-by-round table (verdicts, new substantive count, items moved to suggestions)
   - Test plan (mostly inherited from the implementer's verifications)
   - Known limitations punted with reviewer attribution, and the suggestions not taken
   - Branch-off-main conflict notes (which other in-flight branches share files)

8. **Capture process learnings.** If this branch surfaced a *new* failure mode that met the substantive rule and that the PL catalog didn't cover, append it to `docs/scale-test-team/process-learnings.md` as PL(N+1) in the same commit: the lesson and the least code that applies it, never this branch's machinery as a rule for every later change. Never renumber or delete a PL; retire one whose subject is gone (heading kept, one-line body).

## Follow-up

After opening the PR, give the user its URL. If this session has a PR-activity subscription tool, ask via `AskUserQuestion` whether to subscribe for follow-up review comments.

## What you should NOT do

- Don't review the code yourself — delegate to the six reviewers. Your job is briefing, applying the two rules, aggregating, and committing.
- Don't push to `main`, merge the PR (the user does that), or open a second PR for the same branch. If conflicts emerge with another in-flight PR, document them in the PR description and let the user decide merge order.
- Don't relitigate process learnings during a cycle — if a reviewer flags a PL violation that meets the substantive rule, fix the violation, not the PL.

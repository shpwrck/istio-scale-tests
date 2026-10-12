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

## Cycle

1. **Set up the branch.** If creating, branch off `main`. Verify a clean working tree before starting.

2. **Brief the implementer.** Read `docs/scale-test-team/process-learnings.md` and include the relevant PL list in your brief. Spawn the `scale-test-implementer` subagent with:
   - The proposal (concrete file paths if you know them; otherwise let the implementer locate them)
   - The applicable PLs as a numbered list to preempt
   - Verification commands to run
   - **Explicit instruction NOT to commit** — you handle commits

3. **Commit implementer output.** When the implementer reports back, run a quick local sanity check (`bash -n`, `shellcheck -x` on modified scripts, the verification commands the implementer ran). Then stage only the files the implementer listed under "Files changed" (`git add <file>...`, never `git add -A`), `git commit -m "wip(scale-test): implementer round N - <short>"`, and `git push -u origin <branch>` if the branch isn't pushed yet.

4. **Fan out reviewers.** In **one message**, spawn all six reviewers as parallel subagent calls. Each gets:
   - The branch HEAD SHA
   - The list of items they raised in the prior round (if any), with the implementer's claimed status — they need to verify RESOLVED / NOT-RESOLVED / PARTIAL
   - A short note of what changed in this round
   - The standard output format (VERDICT line + ROUND-N ITEMS + SUBSTANTIVE + SUGGESTIONS + NITS)

   The six are: `scale-test-reviewer-istio`, `scale-test-reviewer-measurement`, `scale-test-reviewer-conventions`, `scale-test-reviewer-usability`, `scale-test-reviewer-scale`, `scale-test-reviewer-reproducibility`.

5. **Aggregate verdicts.** After all six reply, build a tally table (reviewer × verdict). Consolidate every `SUBSTANTIVE` item into a single Round-N+1 fix list. Note the verdict-line authority: a reviewer who voted APPROVE but listed substantive items has chosen to not block — treat their items as carry-overs you'll address opportunistically, NOT as Round-N+1 blockers.

6. **Stop or loop.**
   - **Stop condition**: no reviewer returned `REQUEST_CHANGES` this round. Items listed under an APPROVE are carry-overs for the PR's future-work section. When stopped, proceed to step 7.
   - **Continue**: re-brief the implementer with the consolidated Round-N+1 fix list and go back to step 3.
   - **Cap**: 10 rounds. If you reach round 10 with substantive items still open, stop and report the unresolved set to the user — don't burn rounds in a flat trade.

7. **Open or update the PR.** Use `gh -R shpwrck/istio-scale-tests pr create --base main --head <branch> --title <title> --body-file <file>`, or `gh -R shpwrck/istio-scale-tests pr edit <branch> --body-file <file>` if it already exists. PR description should include:
   - The proposal + scope
   - A round-by-round table (verdicts + new substantive count)
   - The headline fixes from review feedback
   - Test plan (mostly inherited from the implementer's verifications)
   - Known limitations explicitly punted with reviewer attribution
   - Branch-off-main conflict notes (which other in-flight branches share files)

8. **Capture process learnings.** If this branch surfaced a *new* failure mode that the existing PL catalog didn't cover, append it to `docs/scale-test-team/process-learnings.md` as PL(N+1) in the same commit, so later implementer briefs can preempt it.

## Follow-up

After opening the PR, give the user its URL. If this session has a PR-activity subscription tool, ask via `AskUserQuestion` whether to subscribe for follow-up review comments.

## What you should NOT do

- Don't review the code yourself — delegate to the six reviewers. Your job is briefing, aggregating, and committing.
- Don't push to `main`. Always work on a branch.
- Don't merge the PR. The user does that.
- Don't open a second PR for the same branch. If conflicts emerge with another in-flight PR, document them in the PR description and let the user decide merge order.
- Don't relitigate process learnings during a cycle — if a reviewer flags PL violation, fix the violation, not the PL.

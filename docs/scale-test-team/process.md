# Scale-Test Improvement Cycle — Protocol

This is the operational protocol the `/scale-test-review` slash command runs. Read with `README.md` (overview) and `process-learnings.md` (carry-forward catalog).

## Cycle structure

```
                    ┌────────────────────────────────────────────┐
                    │  Implementer pass                          │
                    │    - reads brief + relevant PLs            │
                    │    - edits code, runs verifications        │
                    │    - reports back (no commit)              │
                    └─────────────────────┬──────────────────────┘
                                          │
                  ┌───────────────────────▼──────────────────────┐
                  │  Orchestrator                                │
                  │    - git add -A && git commit (wip)          │
                  │    - git push -u origin <branch>             │
                  │    - fan out 6 reviewers in parallel         │
                  └───────────────────────┬──────────────────────┘
                                          │
        ┌─────────┬─────────┬─────────────┴─┬─────────┬─────────┐
        ▼         ▼         ▼               ▼         ▼         ▼
     Istio   Measurement Conventions    Usability   Scale   Reproducibility
        │         │         │               │         │         │
        └─────────┴─────────┴───────┬───────┴─────────┴─────────┘
                                    │
                    ┌───────────────▼────────────────┐
                    │  Aggregate                     │
                    │    - tally verdicts            │
                    │    - consolidate SUBSTANTIVE   │
                    │    - decide stop or loop       │
                    └──────────┬───────────┬─────────┘
                               │           │
                  any SUBSTANTIVE?  no SUBSTANTIVE?
                               │           │
                    ┌──────────▼┐      ┌───▼──────────┐
                    │ loop      │      │  Open/update │
                    │ (≤10 rds) │      │  PR; capture │
                    └───────────┘      │  any new PL  │
                                       └──────────────┘
```

## Briefing the Implementer

Every brief MUST include:

1. **The proposal** — what scope. Be concrete: file paths if you know them, a one-paragraph why-this-matters.
2. **Round number** — round-1 brief is the proposal as-is; round-N brief (N≥2) is the consolidated `SUBSTANTIVE` list from round N-1.
3. **PL preemption list** — every PL from `process-learnings.md` that plausibly applies to the proposal, numbered. The implementer's report must state APPLIED / N/A (with reason) for each.
4. **Verification commands** — what to run before reporting back (typically `bash -n`, `shellcheck -x`, `--dry-run` of the orchestrator, helm-template if a chart changed, synthetic input through the aggregator).
5. **Constraints** — explicit "no commit", "no new dependencies beyond X", "schema may bump but legacy files must be skipped with a warning".
6. **Punts** — items the orchestrator is explicitly telling the implementer NOT to do. Documented in the PR's known-limitations section.
7. **Report format** — link to `.claude/agents/scale-test-implementer.md` or include inline.

Round-2+ briefs are usually 60% smaller than round-1 — they're a delta on a known codebase, not a fresh design. Reviewers will catch missed items.

## Briefing each Reviewer

Every reviewer brief MUST include:

1. **Branch + HEAD SHA** they're reviewing.
2. **Round number** — round-1 is "fresh review"; round-N (N≥2) is "verify your round N-1 items + flag NEW substantive only".
3. **Their prior items** (round-N only) — one bullet per item the reviewer raised last round, with the implementer's claimed status. The reviewer must verify and emit `RESOLVED | NOT-RESOLVED | PARTIAL` for each.
4. **Files of interest** — short reading list; reviewers read the diff plus the specific files the implementer touched in their lens.
5. **Lens scope reminder** — one sentence; the agent system prompt has the full lens, but a brief reminder helps focus.
6. **Strict output format** — `VERDICT: APPROVE | REQUEST_CHANGES`, then `ROUND-N ITEMS`, then `SUBSTANTIVE`, `SUGGESTIONS`, `NITS`. This is mechanically aggregatable.

Round-1 brief target: 250-400 words. Round-N (N≥2) brief target: 100-200 words.

## Consensus criterion

A round produces consensus iff **every reviewer's `SUBSTANTIVE` block is empty in that round**.

- `VERDICT: APPROVE` with non-empty `SUBSTANTIVE` is a self-contradiction the reviewers sometimes emit. Treat the `VERDICT` line as authoritative (the reviewer chose to not block) and the items as carry-overs.
- `VERDICT: REQUEST_CHANGES` blocks the round regardless of how many or how few items.
- Items that the reviewer marks as `RESOLVED` from their prior round count toward closure, not toward this round's substantive count.

## Round cap

**10 rounds**. If the team hits round 10 with unresolved substantive items:

1. Stop the loop.
2. Open/update the PR with the unresolved set called out in the description (cite reviewer attribution).
3. Hand off to the user — they decide whether to merge as-is, push harder, or scope-down.

In practice the team has never hit the cap. PR #2 took 4 rounds (the no-PL-preempted case); subsequent PRs took 2-3. If you ever need round 6+, something is off — usually the implementer is misreading a recurring reviewer item.

## Commits, pushes, PRs

- **Commit between every implementer pass** with a `wip(scale-test): <branch-slug> round N - <short>` message. The hook-driven stop-on-uncommitted-changes machinery in this repo expects a clean working tree at idle.
- **Push at least once per round** so the branch HEAD on the remote matches what the reviewers see.
- **One PR per branch.** If you find yourself wanting a second PR for the same branch, you're doing too much in one branch.
- **PR description updates** every time consensus shifts. The final PR description carries the round-by-round table.

## Carry-forward learnings

After every cycle, the orchestrator MUST either:

- Confirm in the wrap-up that no new failure mode was discovered, OR
- Append a new PL to `process-learnings.md` with: a one-line catalog entry, a longer explanation in the body, and at least one "how to preempt" guidance line that future implementer briefs can paraphrase.

This is the team's institutional memory. Skipping it is how the next branch's Round-1 grows from 5 items to 28.

## Subscribing to PR events

After the PR is open, ask the user whether to `subscribe_pr_activity`. If yes, treat further reviewer comments as round-N+1 substantive items and re-run the cycle on that PR's branch (which is now likely off-main and tracked).

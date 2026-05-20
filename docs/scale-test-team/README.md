# Scale-Test Improvement Team

A 7-agent team that iterates a proposal for `tests/` or `charts/` to consensus, then opens a PR. The team is a recurring pattern for this repo, not a one-off — every new scale-test scope (a new sweep axis, a probe correctness fix, a new suite) goes through it.

## Cast

| Role | File | Lens |
|------|------|------|
| **Implementer** | `.claude/agents/scale-test-implementer.md` | Writes the code; preempts the carry-forward process learnings; reports back without committing |
| **Reviewer — Istio domain** | `.claude/agents/scale-test-reviewer-istio.md` | Mesh correctness, push semantics, multi-cluster routing |
| **Reviewer — Measurement validity** | `.claude/agents/scale-test-reviewer-measurement.md` | Statistical / methodological soundness of the numbers in the report |
| **Reviewer — Repo conventions** | `.claude/agents/scale-test-reviewer-conventions.md` | AGENTS.md compliance |
| **Reviewer — Usability** | `.claude/agents/scale-test-reviewer-usability.md` | Operator experience at the terminal |
| **Reviewer — Scale pragmatist** | `.claude/agents/scale-test-reviewer-scale.md` | Will this complete at ≥1000 services / ≥10 clusters? |
| **Reviewer — Reproducibility** | `.claude/agents/scale-test-reviewer-reproducibility.md` | Can a re-run be compared to the original? |

The orchestrator is **not** a separate agent — it's the Claude session that types `/scale-test-review`. It briefs the implementer, fans out the reviewers, commits between rounds, opens the PR.

## How to invoke

```
/scale-test-review <proposal description or existing branch name>
```

See `.claude/commands/scale-test-review.md` for the full procedure. Brief version:

1. Implementer makes a pass against the proposal + the carry-forward PL list. No commits.
2. Orchestrator commits the pass, pushes the branch.
3. All six reviewers fan out **in parallel**, each producing a strict `VERDICT: APPROVE | REQUEST_CHANGES` plus structured findings.
4. If any reviewer's verdict is `REQUEST_CHANGES`, orchestrator consolidates and re-briefs the implementer. Otherwise → step 5.
5. PR opens (or its description updates) with the round-by-round table.

Stop criterion: a full round in which **no reviewer's `SUBSTANTIVE` block has any items**. A reviewer who voted `APPROVE` while listing items has chosen carry-over status — those items don't block consensus but do show up in the PR's "future work" section.

Cap: **10 rounds**. If you hit the cap with unresolved blockers, the orchestrator stops and reports the unresolved set rather than burning more rounds in a flat trade.

## Why this works

- **Lens specialization** — each reviewer has one job and can be brief. The Istio expert doesn't second-guess the bash style; the conventions auditor doesn't second-guess the histogram math.
- **Carry-forward learnings** — every cycle ends by appending any *new* failure mode to `process-learnings.md`. Future implementer briefs preempt the catalog, so each branch's Round-1 has fewer surprises than the last. Empirically, Branch 1 took 4 rounds; Branches 2 and 3 took 2 each after 10 and 19 PLs respectively were preempted upfront.
- **Strict output formats** — reviewers' `VERDICT` line is load-bearing, structured items are mechanically aggregatable. The orchestrator never has to interpret prose.
- **Branch off main, sequentially** — each PR is independent and mergeable in any order. Conflicts get resolved at merge time, not during review.

## Files in this directory

- [`process.md`](process.md) — full cycle protocol (briefing format, consensus criterion, escalation paths)
- [`process-learnings.md`](process-learnings.md) — the carry-forward catalog (PL1..PLN). Living document; new PLs appended after each cycle.

## Provenance

This pattern was developed across PRs #2-#6 against this repository in May 2026:

- PR #2 (sweep axes): 4 rounds (16 → 5 → 3 → 0)
- PR #3 (sidecar scoping): 2 rounds (13 → 0)
- PR #4 (convergence histogram probe): 2 rounds (19 → 0)
- PR #5 (churn × dataplane co-execution): 3 rounds (14 → 4 → 0)
- PR #6 (dataplane review + fixes): 3 rounds (28 → 2 → 0)

Convergence got faster as the PL catalog grew. The catalog is the team's institutional memory.

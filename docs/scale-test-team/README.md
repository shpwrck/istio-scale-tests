# Scale-test improvement team

A 7-agent review loop for changes to `tests/` or `charts/`: one implementer and six reviewers iterate on a proposal until no reviewer blocks it, then the orchestrator opens a PR. Use it for every new sweep axis, probe fix, or suite.

## Cast

| Role | Agent file | Lens |
|------|------------|------|
| Implementer | `.claude/agents/scale-test-implementer.md` | Writes the code, preempts the relevant PLs, reports back without committing |
| Istio domain | `.claude/agents/scale-test-reviewer-istio.md` | Mesh correctness, push semantics, multi-cluster routing |
| Measurement validity | `.claude/agents/scale-test-reviewer-measurement.md` | Statistical and methodological soundness of the reported numbers |
| Repo conventions | `.claude/agents/scale-test-reviewer-conventions.md` | `AGENTS.md` compliance |
| Usability | `.claude/agents/scale-test-reviewer-usability.md` | Operator experience at the terminal |
| Scale pragmatist | `.claude/agents/scale-test-reviewer-scale.md` | Will it complete at ≥1000 services / ≥10 clusters? |
| Reproducibility | `.claude/agents/scale-test-reviewer-reproducibility.md` | Can a re-run be compared to the original? |

The orchestrator is the session that runs the command. It briefs the implementer, fans out the reviewers, commits between rounds, and opens the PR.

## Run it

```
/scale-test-review <proposal description or existing branch name>
```

The step-by-step procedure is [`.claude/commands/scale-test-review.md`](../../.claude/commands/scale-test-review.md). The rules that matter:

- **Implementer brief:** the proposal, the round number, the applicable PLs from [`process-learnings.md`](process-learnings.md) (the report marks each APPLIED or N/A with a reason), the verification commands, and explicit punts.
- **Reviewer brief:** branch + HEAD SHA, round number, and in round 2+ the reviewer's prior items, each to be marked `RESOLVED`, `NOT-RESOLVED` or `PARTIAL`. Output is strict: `VERDICT: APPROVE | REQUEST_CHANGES`, then `ROUND-N ITEMS`, `SUBSTANTIVE`, `SUGGESTIONS`, `NITS`.
- **Stop rule:** stop when no reviewer returns `REQUEST_CHANGES`. Items listed under an `APPROVE` are carry-overs for the PR's future-work section.
- **Cap:** 10 rounds. At the cap, stop and report the unresolved items in the PR for the user to decide.
- **Commits:** commit after every implementer pass (`wip(scale-test): <slug> round N - <short>`) and push each round, so reviewers see a fixed SHA. One PR per branch.

## Process learnings

After every cycle, either confirm no new failure mode turned up or append a PL to [`process-learnings.md`](process-learnings.md): a one-line catalog entry, the why, and a how-to-preempt line future briefs can reuse. Code comments cite PL numbers and the O1–O11 observation labels defined there, so keep existing entries intact.

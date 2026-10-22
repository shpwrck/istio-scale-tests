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
| Scale pragmatist | `.claude/agents/scale-test-reviewer-scale.md` | Will it complete at the campaign's 20 clusters and ≥1000 services? |
| Reproducibility | `.claude/agents/scale-test-reviewer-reproducibility.md` | Can a re-run be compared to the original? |

The orchestrator is the session that runs the command. It briefs the implementer, fans out the reviewers, commits between rounds, and opens the PR.

## Run it

```
/scale-test-review <proposal description or existing branch name>
```

The step-by-step procedure is [`.claude/commands/scale-test-review.md`](../../.claude/commands/scale-test-review.md). The rules that matter:

- **Substantive rule:** a reviewer's `SUBSTANTIVE` item must name a concrete path to (a) a wrong or mislabeled number in a report, or a report that hides a failure, (b) a documented command that fails, or (c) red CI. Everything else is a `SUGGESTION` or a `NIT` and never blocks: more checks, more recorded state, more message variants, "what if" scenarios without a realistic path, wording. The orchestrator moves a `SUBSTANTIVE` item that names no such path to `SUGGESTIONS` and says so in the round's tally. (A breach of `AGENTS.md`'s first two rules, identifying data or secrets, always blocks.)
- **Proportion rule:** the implementer fixes a substantive item with the least code that closes the named path; a fix that adds a new state, key or message variant must say which number it protects. Suggestions are not implemented in the same cycle unless the orchestrator picks them.
- **Briefs:** the implementer gets the proposal, the round number, the applicable PLs from [`process-learnings.md`](process-learnings.md) (its report marks each APPLIED or N/A), the verification commands and explicit punts; each reviewer gets the branch, HEAD SHA, round number and, in round 2+, its prior items to mark `RESOLVED`, `NOT-RESOLVED` or `PARTIAL`. Reviewer output is strict: `VERDICT: APPROVE | REQUEST_CHANGES`, then `ROUND-N ITEMS`, `SUBSTANTIVE`, `SUGGESTIONS`, `NITS`.
- **Stop rule and cap:** stop when no reviewer returns `REQUEST_CHANGES` (one whose every item was moved counts as `APPROVE`); items under an `APPROVE` and the suggestions not taken go to the PR's future-work section. At 10 rounds, stop and report the unresolved items in the PR for the user to decide.
- **Commits:** commit after every implementer pass (`wip(scale-test): <slug> round N - <short>`) and push each round, so reviewers see a fixed SHA. One PR per branch.

## Process learnings

After every cycle, either confirm no new failure mode turned up or append a PL to [`process-learnings.md`](process-learnings.md): a one-line catalog entry, the why, and a how-to-preempt line that names the least code applying the lesson (PL64). Code comments cite PL numbers and the O1–O11 observation labels defined there, so never renumber or delete an entry: one whose subject is gone is retired, its heading kept and its body one line.

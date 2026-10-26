# Scale-test review lenses

Six lenses to review a change to `tests/` or `charts/` against, the rules for what blocks a
change, and the catalog of process learnings (PLs) that code comments cite. Until 2026-10-26 the
repo ran these lenses as an agent review loop; the agent definitions are gone, and the lenses and
rules stand on their own.

## Lenses

| Lens | Asks |
|------|------|
| Istio domain | Mesh correctness, push semantics, multi-cluster routing |
| Measurement validity | Statistical and methodological soundness of the reported numbers |
| Repo conventions | `AGENTS.md` compliance |
| Usability | Operator experience at the terminal |
| Scale pragmatist | Will it complete at the campaign's 20 clusters and ≥1000 services? |
| Reproducibility | Can a re-run be compared to the original? |

## What blocks a change

- **Substantive rule:** a review item blocks only when it names a concrete path to (a) a wrong or
  mislabeled number in a report, or a report that hides a failure, (b) a documented command that
  fails, or (c) red CI. Everything else is a suggestion and never blocks: more checks, more
  recorded state, more message variants, "what if" scenarios without a realistic path, wording.
  (A breach of `AGENTS.md`'s first two rules, identifying data or secrets, always blocks.)
- **Proportion rule:** fix a blocking item with the least code that closes the named path; a fix
  that adds a new state, key or message variant says which number it protects.
- Before writing a change, read the PLs in [`process-learnings.md`](process-learnings.md) that
  apply to it.

## Process learnings

When a review or a run turns up a new failure mode, append a PL to
[`process-learnings.md`](process-learnings.md): a one-line catalog entry, the why, and a
how-to-preempt line that names the least code applying the lesson (PL64). Code comments cite PL
numbers and the O1–O11 observation labels defined there, so never renumber or delete an entry:
one whose subject is gone is retired, its heading kept and its body one line.

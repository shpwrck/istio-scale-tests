# Next steps — the one list

_Plan: harden everything TODAY, run a clean autonomous campaign TOMORROW._
_Detailed proposals in `~/.claude/plans/`; full log in [`2026-06-02-workaround-pass-status.md`](2026-06-02-workaround-pass-status.md)._

## ⏳ Right now
Campaign is finishing autonomously (churn-dataplane, last suite). Nothing needed from you. I'll post the final summary when done.

## 🛠 TODAY — harden everything (in this order; I drive build/review, you merge)
Branches overlap (fanout.sh, churn/002, propagation/002, reports), so order matters — I handle the rebases.

1. [ ] **Merge PR #31** (churn `set -e` fix) — ready now, small.
2. [ ] **Merge PR #32** (controlplane PF fix) — ready now, small.
3. [ ] **O1+O3** (`worktree-agent-a723a19…`): rebase on main → `/scale-test-review` → merge. _P3 pre-warm + scrape-skew guard. Built; needs review + 1 live-validation._
4. [ ] **O4** (`worktree-agent-a7246af…`): rebase on #31 (both touch churn/002) → `/scale-test-review` → merge. _Churn metric split._
5. [ ] **O6 + O7** — the fault-tolerance hardening, built as ONE `/scale-test-review` pass on the merged base (so it's written against final code, not a moving target). _Record-and-continue on probe failure + partial-coverage metrics. The big one._
6. [ ] **O5 + resize** — one-line istiod CPU request 1→~250m PR + your cluster resize.

## 🌙 TONIGHT (while you sleep) — clean autonomous campaign
7. [ ] Full-workload run on the hardened harness + resized cluster (controlplane 10×3, churn-dataplane 5×5, all suites). I drive it autonomously like last night, now with fault-tolerant probes. **Requires: steps 1–6 all merged + cluster resized before you turn in.**

## Notes
- O2 = just `--watcher-replicas` higher; no work.
- This run's data = workaround pass (controlplane 10×2, churn split). Tomorrow's = the clean numbers.

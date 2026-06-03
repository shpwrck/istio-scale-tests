# Campaign records

Per-run records of full scale-test campaigns. Each campaign is a serial run of the
suites under `tests/` against a real multi-cluster mesh; the raw sweep data lives
locally under each suite's `results/` dir (gitignored), so these markdown records are
the durable, shareable artifact.

## 2026-06-02 — workaround pass

The first end-to-end campaign, run with the *workaround* configuration (istiod pinned
to 5 replicas, controlplane reduced to 10×2, churn-dataplane 3×5) on an under-scaled
cluster. Trust the scaling **shapes** and cross-cluster **overheads**, not the absolute
magnitudes. A hardened full-scale re-run is planned.

- [`2026-06-02-workaround-pass-results.md`](2026-06-02-workaround-pass-results.md) — results summary: which metrics are trustworthy vs. discard, and the bottom-line findings.
- [`2026-06-02-workaround-pass-status.md`](2026-06-02-workaround-pass-status.md) — running execution log (stages A–C, per-suite status, the autonomous overnight run).
- [`2026-06-02-workaround-pass-next-steps.md`](2026-06-02-workaround-pass-next-steps.md) — the hardening + clean re-run plan that followed.

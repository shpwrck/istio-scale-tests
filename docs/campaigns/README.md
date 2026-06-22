# Campaign records

Per-run records of full scale-test campaigns. Each campaign is a serial run of the
suites under `tests/` against a real multi-cluster mesh; the raw sweep data lives
locally under each suite's `results/` dir (gitignored), so these markdown records are
the durable, shareable artifact.

## Writing a summary

Start from [`TEMPLATE.md`](TEMPLATE.md). **Every summary must lead with the Scale
envelope** — total proxies / endpoints / per-proxy config bytes and the control-plane
resource headroom (istiod % of limit, node CPU), not just "mesh size 1→N". A cluster
count is not a scale; the reader has to know how big the mesh really was and whether
anything was near a limit, from screen one. The template lists the exact sweep-report
field or command that feeds each cell.

## 2026-06-22 — planned 20c/10k/10k peak campaign

Budgeted execution plan for a 20-spoke, 10,000-Service, 10,000-endpoint peak-only
campaign. The plan uses a 3-node spoke mesh-verification phase, scales spokes to
fixed 8-node worker pools only after Istio is proven healthy, disables Terraform quota
management, and carries a $1,500 incremental spend cap.

- [`2026-06-22-20c-10k-10k-campaign-plan.md`](2026-06-22-20c-10k-10k-campaign-plan.md) — execution plan, budget guard, stop thresholds, staged scale-up, suite matrix, and artifact rules.

## 2026-06-04 — clean pass

The hardened full-workload re-run the workaround pass planned. istiod pinned to **3**
replicas at **250m** CPU request (the O5 fix that freed node headroom), controlplane at
full **10×3**, churn-dataplane at full **5×5**. All five suites complete and clean. Still
under-scaled relative to the infra (istiod ~4% of mem limit) — trust shapes + overheads,
not magnitudes — but a fuller, cleaner baseline than the workaround pass.

- [`2026-06-04-clean-pass-results.md`](2026-06-04-clean-pass-results.md) — results summary: **Scale envelope** first, then per-suite trustworthy-vs-discard and the morning follow-ups (merge PR #50; land the 250m istiod default; O11 slow-teardown).
- [`2026-06-04-clean-pass-status.md`](2026-06-04-clean-pass-status.md) — running execution log (preflight + O5 de-risk, the host-reboot recovery mid-controlplane, the O10 churn-dataplane cleanup-cascade + PR #50 fix + clean re-run).

## 2026-06-02 — workaround pass

The first end-to-end campaign, run with the *workaround* configuration (istiod pinned
to 5 replicas, controlplane reduced to 10×2, churn-dataplane 3×5) on an under-scaled
cluster. Trust the scaling **shapes** and cross-cluster **overheads**, not the absolute
magnitudes. The [2026-06-04 clean pass](#2026-06-04--clean-pass) is the hardened re-run.

- [`2026-06-02-workaround-pass-results.md`](2026-06-02-workaround-pass-results.md) — results summary: leads with a backfilled **Scale envelope** (topology, control-plane headroom, throughput axis), then which metrics are trustworthy vs. discard and the bottom-line findings.
- [`2026-06-02-workaround-pass-status.md`](2026-06-02-workaround-pass-status.md) — running execution log (stages A–C, per-suite status, the autonomous overnight run).
- [`2026-06-02-workaround-pass-next-steps.md`](2026-06-02-workaround-pass-next-steps.md) — the hardening + clean re-run plan that followed.

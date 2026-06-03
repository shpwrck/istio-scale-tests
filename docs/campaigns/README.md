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

## 2026-06-02 — workaround pass

The first end-to-end campaign, run with the *workaround* configuration (istiod pinned
to 5 replicas, controlplane reduced to 10×2, churn-dataplane 3×5) on an under-scaled
cluster. Trust the scaling **shapes** and cross-cluster **overheads**, not the absolute
magnitudes. A hardened full-scale re-run is planned.

- [`2026-06-02-workaround-pass-results.md`](2026-06-02-workaround-pass-results.md) — results summary: leads with a backfilled **Scale envelope** (topology, control-plane headroom, throughput axis), then which metrics are trustworthy vs. discard and the bottom-line findings.
- [`2026-06-02-workaround-pass-status.md`](2026-06-02-workaround-pass-status.md) — running execution log (stages A–C, per-suite status, the autonomous overnight run).
- [`2026-06-02-workaround-pass-next-steps.md`](2026-06-02-workaround-pass-next-steps.md) — the hardening + clean re-run plan that followed.

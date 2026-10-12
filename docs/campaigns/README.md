# Campaign records

Results of full scale-test campaigns: serial runs of the suites under `tests/` against a real
multi-cluster mesh. Raw sweep data stays in each suite's gitignored `results/` dir, so these
files are the durable record.

## Writing a summary

Start from [`TEMPLATE.md`](TEMPLATE.md) and lead with the **Scale envelope**: total proxies,
endpoints, per-proxy config size, and control-plane headroom (istiod % of limit, node CPU). A
cluster count alone is not a scale. The controlplane sweep generates the envelope block for you.

## Records

| Date | Run | Files |
|---|---|---|
| 2026-06-22 | 20 clusters / 10k Services / 10k endpoints — **PASS** | [results](2026-06-22-20c-10k-10k-results.md) |
| 2026-06-17 | 4-cluster stress shakeout (1 hub + 3 spokes); defines BLOCKER/FINDING labels | [findings log](2026-06-17-stress-shakeout-status.md) |
| 2026-06-04 | 10-spoke clean pass, all five suites | [results](2026-06-04-clean-pass-results.md), [sweep tables](2026-06-04-clean-pass-sweep-detail.md), [charts](charts/) |
| 2026-06-02 | 10-spoke workaround pass (reduced workload) | [results](2026-06-02-workaround-pass-results.md) |

The 10-spoke passes ran far below the infra's limits: trust their scaling shapes and
cross-cluster overheads, not their absolute magnitudes.

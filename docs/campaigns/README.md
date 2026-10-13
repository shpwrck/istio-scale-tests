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
| 2026-10-13 | Lab validation of backlog tasks 2, 3, 5, 6 (2 single-node members); CA-race root cause confirmed | [results](2026-10-13-lab-backlog-validation.md) |
| 2026-06-22 | 20 clusters / 10k Services / 10k endpoints — **PASS** | [results](2026-06-22-20c-10k-10k-results.md) |
| 2026-06-04 | 10-spoke clean pass, all five suites | [results](2026-06-04-clean-pass-results.md), [sweep tables](2026-06-04-clean-pass-sweep-detail.md), [charts](charts/) |

The 10-spoke pass ran far below the infra's limits: trust its scaling shapes and
cross-cluster overheads, not its absolute magnitudes.

The data-plane numbers above ran one fortio server pod per cluster, and a run that missed
its target QPS with only HTTP 200s still counted as valid. Later dataplane runs default to
2 server pods (`SERVER_REPLICAS` in the TSV preamble) and tag such rows `QPS_SHORTFALL`;
see [`tests/dataplane/README.md`](../../tests/dataplane/README.md#comparing-with-earlier-runs).

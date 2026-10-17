# Campaign records

Results of full scale-test campaigns: serial runs of the suites under `tests/` against a real
multi-cluster mesh. Raw sweep data stays in each suite's gitignored `results/` dir, so these
files are the durable record.

## Writing a summary

Start from [`TEMPLATE.md`](TEMPLATE.md) and lead with the **Scale envelope**: total proxies,
endpoints, per-proxy config size, and control-plane headroom (istiod % of limit, node CPU). A
cluster count alone is not a scale. The controlplane sweep generates the envelope block for you.

Redact before you paste: the envelope, `sweep-outcome.txt` and the reports can name your kube
contexts, and a note about a member that could not be read quotes kubectl's error, which can
name its API host. Replace them with placeholders (`<mesh-a-ctx>`, `<api-host>`), as
[AGENTS.md](../../AGENTS.md) requires for anything committed.

## Records

| Date | Run | Files |
|---|---|---|
| 2026-10-14 | ROSA validation window (hub + 3 members, Tier C): tasks 3 and 4 validated, task 6 at 60-250 Services, task 1 to 4000 namespaces / 8000 Services; the east-west gateway is the binding resource; 17 issues → BACKLOG 9 | [results](2026-10-14-rosa-validation.md) |
| 2026-10-14 | Lab run of the Gateway API multicluster ingress check (backlog task 8): no Service needed for traffic; namespace needed with `kind: Service`; 22/22 predictions matched | [results](2026-10-14-gateway-api-multicluster-lab.md) |
| 2026-10-13 | Lab validation of backlog tasks 2, 3, 5, 6 (2 single-node members); CA-race root cause confirmed | [results](2026-10-13-lab-backlog-validation.md) |
| 2026-06-22 | 20 clusters / 10k Services / 10k endpoints — **PASS** | [results](2026-06-22-20c-10k-10k-results.md) |
| 2026-06-04 | 10-spoke clean pass, all five suites | [results](2026-06-04-clean-pass-results.md), [sweep tables](2026-06-04-clean-pass-sweep-detail.md), [charts](charts/) |

The 10-spoke pass ran far below the infra's limits: trust its scaling shapes and
cross-cluster overheads, not its absolute magnitudes.

**Errata (2026-10-16).** Both June records predate the report fixes of PR 106 and carry an erratum
box at the top. The 2026-06-22 verdict (GO, "comfortable headroom") is unconfirmed: its istiod CPU
is an end-of-window snapshot, east-west gateway memory was not measured (BACKLOG 9.9 puts 10k
Services at about 1.4 GiB against a 1Gi limit), and its data-plane root cause is contradicted by
the 2026-10-14 window. In the 2026-06-04 records `cpu_avg` is a per-window peak and "MB" is MiB.

The data-plane numbers above ran one fortio server pod per cluster, and a run that missed
its target QPS with only HTTP 200s still counted as valid. Later dataplane runs default to
2 server pods (`SERVER_REPLICAS` in the TSV preamble) and tag such rows `QPS_SHORTFALL`;
see [`tests/dataplane/README.md`](../../tests/dataplane/README.md#comparing-with-earlier-runs).

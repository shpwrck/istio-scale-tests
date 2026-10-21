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
[AGENTS.md](../../AGENTS.md) requires for anything committed:

```bash
tests/lib/redact-results.sh --dry-run tests/<suite>/results/sweep-<RUN_ID>   # what would change
tests/lib/redact-results.sh --out /tmp/redacted tests/<suite>/results/sweep-<RUN_ID>
```

Paste from the copy under `/tmp/redacted`. It maps each context the TSV preambles name to
`<mesh-a-ctx>`, `<mesh-b-ctx>`, ... (the mapping is printed on stderr only) and masks URLs, API and
cluster host names, IPs, emails (`<email>`), home dirs (`/home/<name>` and `/Users/<name>` as
`<home>`), AWS account ids and AWS resource ids (`vpc-`, `subnet-`, `sg-`, `i-`, `eni-`, `vol-`,
`igw-`, `nat-`, `rtb-` with 8 or 17 hex digits). A file or dir whose name holds a context is renamed
in the copy the same way, without the angle brackets (`istio-revert-mesh-a-ctx.json`); the renames
are listed on stderr. It refuses (exit 1, file named) a file that still holds a context it was not
told about; pass that one with `--context NAME`, and the hub with `--hub-context NAME`. Redact the
whole sweep dir rather than one report, so the TSVs name every member: a lone report (the scale
envelope, a summary) can name members in prose only, so when the files' metadata names no member and
no `--context` gives one, it refuses the whole run (exit 1, nothing written; `--no-contexts` runs
anyway, for files that name no kube context: nothing checks that, so read the copy for member
names). It never copies the raw `istiod-diag-*/NNN-*/` evidence, a tuning sweep's raw copies of the
Istio CR (`istio-spec/`, `state/istio-before-*.json`: they hold the cluster's own name) or a sweep's
`.sweep.lock`; each is named on stderr.

A person reads the copy, file names included, before it is committed. The script has no
pattern for:

- a context, cluster or node name that no metadata key names and no `--context` gives (in
  prose, a log line or a file name);
- host names and domains outside the suffixes it knows (`api.*`, `*.apps.*`,
  `*.openshiftapps.com`, `*.amazonaws.com`, ...);
- other AWS ids (`ami-`, `snap-`, `vpce-`, other lengths), the resource part of an ARN (only
  its account id is masked), region and zone names;
- user names outside `/home/<name>` and `/Users/<name>`;
- tokens, passwords or other secrets that a log or an error message quotes.

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

Every record above ran on OpenShift (ROSA or single-node OpenShift) with OSSM 3.x builds,
before the suites recorded the platform: their TSVs have no `PLATFORM` line, and a report reads
those values as `unknown`. A run on upstream Istio (the Sail operator) or on kind measures other
builds and infrastructure; record its platform and mesh builds (`TEMPLATE.md`, "Platform / mesh
build") and compare it with these only as such.

The data-plane numbers above ran one fortio server pod per cluster, and a run that missed
its target QPS with only HTTP 200s still counted as valid. Later dataplane runs default to
2 server pods (`SERVER_REPLICAS` in the TSV preamble) and tag such rows `QPS_SHORTFALL`;
see [`tests/dataplane/README.md`](../../tests/dataplane/README.md#comparing-with-earlier-runs).

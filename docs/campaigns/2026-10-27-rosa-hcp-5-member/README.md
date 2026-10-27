# 2026-10-27: rosa campaign profile on ROSA HCP, 1 to 5 members

The first run of the campaign runner's `rosa` profile, and the first ROSA run with more than 3
mesh members: a hub plus 5 members on ROSA HCP in us-east-2, built from nothing by
`terraform/rosa-hcp` and `terraform/platform` ([runbook](../../runbooks/rosa-validation/README.md)).
Every sweep grows the mesh from 1 to 5 members.

**Outcome: every suite OK.** Dataplane ran twice: the first run lost 36 of 120 rows to an API
blip (issue 1, fixed in PR 117), the rerun on the fix had 120 of 120. Controlplane's verdict:
**PASS**, peak utilization 13% (node memory), no istiod restart, 18 of 18 cells valid.
Wall clock from the first apply to the end of the last suite: 7 h 28 min (12:16 to 19:44 UTC).

```bash
tests/campaign/001-run-profile.sh --profile rosa \
  --contexts <mesh-a-ctx>,<mesh-b-ctx>,<mesh-c-ctx>,<mesh-d-ctx>,<mesh-e-ctx> --hub-context <hub-a-ctx>
```

| Run | Value |
| --- | --- |
| Run IDs | part 1 `20261027T132301Z-1960407` (dataplane, first run); part 2 `20261027T143848Z-2378322` (propagation, churn, churn-dataplane, tuning); part 3 `20261027T165012Z-3942070` (dataplane rerun, controlplane) |
| Harness | `d21a197` (parts 1 and 2); `bf258af` (part 3: main after PR 117, with the dataplane fix) |
| Clusters | 6 ROSA HCP 4.21.11 clusters: hub on 2x m5.2xlarge; `<mesh-a-ctx>` on 3x r7i.2xlarge; `<mesh-b-ctx>` to `<mesh-e-ctx>` on 3x m7i.xlarge; fixed worker pools |
| Mesh | OSSM 3.4.3 (`servicemeshoperator3`), Istio v1.30.5 read live on every member; multi-primary, multi-network (5 networks); 1 istiod per member (2 CPU / 8 GiB request, 4 CPU / 16 GiB limit); Kubernetes v1.34.6 |
| Provisioning | rosa-hcp apply 366 resources (5 clusters, then a sixth); platform apply 53 resources; Argo CD had all 58 Applications Synced/Healthy 9 minutes after the platform apply, with no manual step; the wiring gate was Ready with `ca=shared` on all 5 members and preflight passed with the echo check |
| Cost | about $11.50/h for the 6 clusters; roughly $120 to $130 for the run including teardown, an estimate until Cost Explorer posts it |

Why three parts: the run was stopped twice between suites, on purpose. Part 1 ran with the
profile's 600-minute deadline, which could have cut controlplane short with 5 members, so the
rest restarted with no deadline (part 2). After tuning, part 2 was stopped again so dataplane
could rerun on the fix before controlplane, whose thousands of namespaces would skew it (part 3).
Only part 3 reached its end, so only it has a campaign report.

Files: [`results/`](results/) is the redacted run: each suite's sweep dir with its reports and
TSVs, the first dataplane run in [`results/dataplane-first-run/`](results/dataplane-first-run/),
and part 3's campaign report
[`campaign-20261027T165012Z-3942070.md`](results/campaign-20261027T165012Z-3942070.md).
[`charts/`](charts/) holds each suite's charts. Tuning has no chart generator. Console and
preflight logs, the raw istiod-diag evidence and tuning's raw copies of the Istio CR are not
included (`tests/lib/redact-results.sh` does not copy them).

## Scale envelope

From the controlplane sweep's
[scale envelope](results/controlplane/sweep-20261027T180552Z-4034321/scale-envelope-20261027T180552Z-4034321.md),
at its peak (one measured member, `<mesh-a-ctx>`, in a 5-member mesh):

| Dimension | Value |
| --- | --- |
| Clusters measured | 1 (namespace scaling runs at mesh size 1 on `<mesh-a-ctx>`; the memory guard watched all 5) |
| Namespaces / Services on the measured member | 4,000 mesh namespaces with 4,000 Services, plus 2,000 outside namespaces |
| Workload | config-only: Services without pods, plus 8 measurement pods |
| Connected proxies per cluster (peak) | 10 |
| Per-proxy config | 351 KiB with namespace scoping; 23.2 MiB with `wide` scoping at 4,000 namespaces, 34.1 MiB once the 2,000 outside namespaces are labeled |
| Gateway clusters | 8,029 at 4,000 namespaces; 12,029 with the outside namespaces labeled |
| istiod CPU (window peak) | 7% of 4000m |
| istiod memory (RSS) | 8% of 16384Mi (peak 1,271 MiB) |
| Node CPU / memory | 4% / 13% |

## Suites

| Suite | Status | Minutes | Headline | Report |
| --- | --- | --- | --- | --- |
| dataplane (rerun, part 3) | OK | 75 | 120 of 120 rows valid; at 1000 QPS local p50 1.7 ms / p99 3.0 ms at every mesh size, cross-cluster p50 2.6 to 2.7 ms / p99 4.8 to 7.0 ms for 2 to 5 members; 100% HTTP 200, QPS targets met | [sweep](results/dataplane/sweep-20261027T165037Z-3944357/sweep-20261027T165037Z-3944357.md), [charts](charts/dataplane.md) |
| dataplane (first run, part 1) | OK | 74 | 84 of 120 rows valid: 36 dropped as "istiod restart unknown", 3 cells lost to failed `kubectl exec` (issue 1) | [sweep](results/dataplane-first-run/sweep-20261027T132405Z-1966097/sweep-20261027T132405Z-1966097.md), [charts](charts/dataplane-first-run.md) |
| propagation | OK | 10 | 150 of 150 samples valid; P1 local xDS avg 635 to 678 ms; P2 remote EDS and P3 remote sidecar p50 595 to 670 ms, flat from 2 to 5 members; worst p99 981 ms (P2, 4 members) | [summary](results/propagation/sweep-20261027T143912Z-2380553/sweep-summary.md), [charts](charts/propagation.md) |
| churn | OK | 24 | 49 of 50 rows valid; scale 1 to 5 seen locally in 5.0 to 5.3 s (intensity 2) and 5.7 to 5.9 s (intensity 5), both including pod boot; remote EDS 0.1 to 0.3 s sooner; push and queue p99 under 100 ms; flat from 1 to 5 members | [sweep](results/churn/sweep-20261027T144859Z-2427025/sweep-20261027T144859Z-2427025.md), [charts](charts/churn.md) |
| churn-dataplane | OK | 79 | 15 of 15 combos OK at 200 QPS, 100% HTTP 200; churn adds 3 to 9 ms to p99 on 1 member and 10 to 25 ms from 2 members on (table below) | [summary](results/churn-dataplane/sweep-20261027T151327Z-3162743/sweep-summary-20261027T151327Z-3162743.md), [charts](charts/churn-dataplane.md) |
| tuning (on propagation) | OK | 18 | 5 of 5 passes, 40 of 40 rows each; push throttling slows every phase by 64 to 202%, the other profiles stay within noise | [comparison](results/tuning/sweep-20261027T163213Z-3869675/sweep-comparison.md) |
| controlplane (namespace scaling) | OK | 97 | 18 of 18 cells, 250 to 4,000 namespaces plus 2,000 outside; discovery checks OK; PASS at 13% peak utilization | [sweep](results/controlplane/sweep-20261027T180552Z-4034321/sweep-20261027T180552Z-4034321.md), [charts](charts/controlplane.md) |

### Dataplane: a remote hop costs about 1 ms, whatever the mesh size

| Mesh size | local p50 / p99 (1000 QPS) | remote p50 / p99 (1000 QPS) | remote p50 / p99 (10 QPS) |
| --- | --- | --- | --- |
| 1 | 1.70 / 2.97 ms | - | - |
| 2 | 1.72 / 2.97 ms | 2.57 / 4.77 ms | 3.68 / 5.52 ms |
| 3 | 1.73 / 2.97 ms | 2.65 / 7.01 ms | 3.94 / 5.94 ms |
| 4 | 1.74 / 2.98 ms | 2.60 / 6.01 ms | 3.87 / 12.36 ms |
| 5 | 1.72 / 2.97 ms | 2.71 / 4.89 ms | 4.03 / 10.10 ms |

From the rerun. Remote rows pool every remote member (2 per remote member per mesh size). The
first run's valid rows agree with these.

### Churn-dataplane: the cost is in the first remote member

Added p99 (churn window minus baseline) at 200 QPS, by churn rate:

| Mesh size | 1 op/s | 5 ops/s | 10 ops/s |
| --- | --- | --- | --- |
| 1 | +3.0 ms | +9.0 ms | +7.8 ms |
| 2 | +10.5 ms | +20.1 ms | +21.1 ms |
| 3 | +12.3 ms | +17.8 ms | +24.5 ms |
| 4 | +10.1 ms | +20.5 ms | +21.4 ms |
| 5 | +10.8 ms | +20.7 ms | +21.7 ms |

Going from 1 to 2 members roughly doubles to triples the added p99; more members add little.
One churn operation of 600 failed at 10 ops/s on 1 member; the row stays valid.

### Tuning: push throttling is the only profile that moves propagation

| Metric (mean) | baseline | 01-push-throttling | 02-xds-cache-off | 03-gateway-cluster-filter | 04-connection-pools |
| --- | --- | --- | --- | --- | --- |
| P1 local push (ms) | 618 | 1,118 (+81.0%) | 663 (+7.3%) | 630 (+1.9%) | 655 (+6.1%) |
| P2 remote EDS (ms) | 658 | 1,081 (+64.4%) | 654 (-0.6%) | 613 (-6.8%) | 619 (-5.9%) |
| P3 remote sidecar (ms) | 640 | 1,934 (+202.0%) | 678 (+5.9%) | 652 (+1.9%) | 793 (+23.8%) |

Push throttling's longer debounce is the point of that profile. Connection pools' P3 mean is
pulled up by one 1,981 ms sample; its other samples sit near the baseline. Each profile's
resources were removed and checked between passes.

### Controlplane: what grows with namespaces

| Scoping | istiod heap in use at 250 / 1,000 / 2,000 / 4,000 namespaces (probe) | Fit per 100 namespaces | Push time per 100 namespaces |
| --- | --- | --- | --- |
| namespace | 122 / 192 / 311 / 505 MiB | +10.3 MiB | +0.15 ms |
| wide | 149 / 217 / 388 / 597 MiB | +12.2 MiB | +0.78 ms |

- Per-proxy config is flat (351 KiB) with namespace scoping and grows to 23.2 MiB at 4,000
  namespaces with `wide`.
- Gateway clusters grow 200 per 100 namespaces (527 at 250, 8,027 at 4,000).
- Discovery selectors: 2,000 unlabeled outside namespaces add 0 Services to istiod (expected 0);
  labeling them adds exactly 2,000 (expected 2,000), and pushes `wide` per-proxy config from
  23.2 to 34.1 MiB.
- Not measured by this profile (the report says so): the pods vs config-only calibration and
  the measurement-pod sweep.

## Reading these numbers

- **Propagation's convergence histogram is empty.** P1 conv_p50 and conv_p99 are N/A in every
  row: each iteration produced 5 samples, below the probe's floor (10 for p50, 30 for p99). That
  is the floor working, not a fault; `PROPAGATION_WATCHER_REPLICAS` adds samples if a later run
  wants the histogram. The wall-clock P1, P2 and P3 times are the measurement.
- **Two harness commits.** Parts 1 and 2 ran `d21a197`, part 3 `bf258af`; the difference that
  touches a suite here is the dataplane fix (issue 1), and the rerun reproduces the first run's
  valid rows.
- **One member is larger.** `<mesh-a-ctx>` (the source of every sweep and the measured member of
  namespace scaling) runs on r7i.2xlarge nodes, the others on m7i.xlarge.

## Issues found

1. **Dataplane dropped every row of a window after an API blip** (fixed in PR 117). A short
   API-server stall on ROSA HCP broke the istiod port-forwards and the fortio `kubectl exec`
   streams together. The post-window istiod scrape failed, so the window's restart status was
   unknown and all its rows were dropped as poisoned, although istiod-diag found no restart
   (`no_restart_found` on all 6 captures). An exec that exited 0 with no output was recorded as
   `ERROR_RATE_HIGH`. Now a failed istiod scrape retries through the API server's pod proxy
   (`fanout_scrape_via_api`), and an empty load output is `FAILED`. The rerun had no blip, so
   the retry path is covered by bats but not yet exercised live.
2. **One churn row has no remote reach time** (left as is). At mesh size 5, intensity 2,
   iteration 3, the baseline read of `<mesh-b-ctx>`'s watcher Envoy `/clusters` failed (5 tries
   within about a second), so `remote_endpoint_reachable_ms` is N/A and the row is
   `MISSING_VALUE`. The mesh was fine in that iteration (remote EDS converged in 4.7 s). Within
   the error budget.
3. **The operator host's istioctl is 1.28.5**, not v1.30.5. Diagnostics only; preflight warned.

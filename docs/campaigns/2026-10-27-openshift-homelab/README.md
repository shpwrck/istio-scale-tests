# 2026-10-27: openshift campaign profile on a two-member lab

The first full run of the campaign runner (`tests/campaign/001-run-profile.sh`, PR 115) with the
`openshift` profile, on the existing-cluster lab
([runbook](../../runbooks/existing-cluster-lab/README.md)): two single-node OpenShift members of
about 20 CPU each, the small-istiod override, a separate ACM / Argo CD hub.

**Outcome: all 6 suites OK, campaign exit 0, 110 minutes** (12:19 to 14:09 UTC; the profile's
estimate was 4 to 5 hours). Controlplane's verdict: **PASS**, peak utilization 35% (node memory),
no istiod restart, 20 of 20 cells valid.

```bash
tests/campaign/001-run-profile.sh --profile openshift --contexts <mesh-a-ctx>,<mesh-b-ctx> --hub-context <hub-a-ctx>
```

| Run | Value |
| --- | --- |
| Run ID | `20261027T121857Z-1652653` |
| Harness | `d21a197` (main after PR 115) |
| Members | 2 (`<mesh-a-ctx>` is the source and the measured member of namespace scaling) |
| Platform | OpenShift, Kubernetes v1.34.8, single-node members (19.5 CPU / 93 GiB allocatable) |
| Mesh | OSSM 3.4.3 (`servicemeshoperator3`), Istio v1.30.5 read live on both members; multi-primary, multi-network; 1 istiod per member (1 CPU / 3 GiB request, 2 CPU / 3 GiB limit) |
| Before the run | All three clusters had rebooted together at about 12:07 UTC; the mesh was Synced/Healthy again within about 5 minutes, and preflight passed with the echo check. |

Files: [`results/`](results/) is the redacted run (the campaign report
[`campaign-20261027T121857Z-1652653.md`](results/campaign-20261027T121857Z-1652653.md), and
each suite's sweep dir with its reports and TSVs); [`charts/`](charts/) holds each suite's
charts. The sample was too small for most generated charts: churn, propagation and
controlplane have none and dataplane only its QPS chart (each file says why);
churn-dataplane has both of its charts, and tuning has no chart generator. Console and preflight logs, and tuning's raw copies of
the Istio CR, are not included (`tests/lib/redact-results.sh` does not copy them).

## Scale envelope

From the controlplane sweep's
[scale envelope](results/controlplane/sweep-20261027T131315Z-1934118/scale-envelope-20261027T131315Z-1934118.md),
at its peak (one member, `wide` scoping):

| Dimension | Value |
| --- | --- |
| Clusters measured | 1 (namespace scaling runs at mesh size 1; the other suites grow from 1 to 2 members) |
| Namespaces / Services on the measured member | 400 mesh namespaces with 800 Services, plus 200 outside namespaces (400 Services) |
| Workload | config-only: Services without pods, plus 4 measurement pods |
| Connected proxies per cluster (peak) | 6 |
| Per-proxy config | 357 KiB with namespace or no scoping; 5.0 MiB with `wide` scoping, 7.4 MiB once the outside namespaces are labeled |
| Gateway clusters | 1,631 at 400 namespaces; 2,431 with the outside namespaces labeled |
| istiod CPU (window peak) | 7% of 2000m |
| istiod memory (RSS) | 12% of 3072Mi |
| Node CPU / memory | 10% / 35% |

This is a small lab: trust the shapes (what grows with namespaces, what scoping changes), not
the absolute sizes.

## Suites

| Suite | Status | Minutes | Headline | Report |
| --- | --- | --- | --- | --- |
| dataplane | OK | 13 | Local sidecar-to-sidecar p99 3.6 to 9.5 ms at 10, 100 and 500 QPS; 100% HTTP 200; QPS targets met | [sweep](results/dataplane/sweep-20261027T121916Z-1653682/sweep-20261027T121916Z-1653682.md), [charts](charts/dataplane.md) |
| propagation | OK | 4 | P1 local xDS avg 737 ms (1 member), 1,173 ms (2); P2 remote EDS avg 1,172 ms; P3 remote sidecar avg 1,864 ms; 20 of 20 iterations valid | [summary](results/propagation/sweep-20261027T123230Z-1688793/sweep-summary.md), [charts](charts/propagation.md) |
| churn | OK | 9 | 20 of 20 rows valid; local 5.5 to 6.6 s and remote reach 5.6 to 6.5 s (both include pod boot); remote EDS 5.3 to 5.7 s; push and queue p99 under 100 ms | [sweep](results/churn/sweep-20261027T123613Z-1711540/sweep-20261027T123613Z-1711540.md), [charts](charts/churn.md) |
| churn-dataplane | OK | 14 | Churn adds 4.4 to 5.3 ms to p99 at 200 QPS (baseline p99 3.7 to 4.9 ms); no QPS loss | [summary](results/churn-dataplane/sweep-20261027T124520Z-1791026/sweep-summary-20261027T124520Z-1791026.md), [charts](charts/churn-dataplane.md) |
| tuning (on propagation) | OK | 14 | 5 of 5 passes, 50 of 50 rows; every profile within -1.6% to +2.9% of the baseline, inside its own range | [comparison](results/tuning/sweep-20261027T125934Z-1889293/sweep-comparison.md) |
| controlplane (namespace scaling) | OK | 56 | 20 of 20 cells, 100 to 400 namespaces plus 200 outside; discovery checks OK | [sweep](results/controlplane/sweep-20261027T131315Z-1934118/sweep-20261027T131315Z-1934118.md), [charts](charts/controlplane.md) |

### Tuning: no profile moves propagation at this size

| Metric (mean of 10) | baseline | 01-push-throttling | 02-xds-cache-off | 03-gateway-cluster-filter | 04-connection-pools |
| --- | --- | --- | --- | --- | --- |
| P1 local push (ms) | 647 | 637 (-1.6%) | 638 (-1.5%) | 664 (+2.5%) | 643 (-0.8%) |
| P2 remote EDS (ms) | 642 | 634 (-1.2%) | 635 (-1.0%) | 660 (+2.9%) | 642 (0.0%) |
| P3 remote sidecar (ms) | 1,336 | 1,333 (-0.2%) | 1,334 (-0.1%) | 1,355 (+1.4%) | 1,338 (+0.1%) |

The baseline's P1 ranges from 604 to 732 ms, so every change is noise. With 4 to 8 proxies per
member there is little for push throttling or the xDS cache to act on.

### Controlplane: what grows with namespaces

| Scoping | istiod heap in use at 100 / 200 / 400 namespaces | Fit per 100 namespaces | Push time per 100 namespaces |
| --- | --- | --- | --- |
| none | 107 / 122 / 140 MiB | +10.7 MiB | +0.35 ms |
| namespace | 102 / 141 / 169 MiB | +21.1 MiB | +0.32 ms |
| wide | 129 / 153 / 181 MiB | +16.9 MiB | +0.56 ms |

- Per-proxy config is flat (357 KiB) with namespace or no scoping, and grows 1,169 KiB per 100
  namespaces with `wide`.
- The ingress gateway keeps `*/*`: its clusters grow 400 per 100 namespaces (431, 831, 1,631),
  its memory about 28 MiB per 100 namespaces.
- Discovery selectors: 200 unlabeled outside namespaces add 0 Services to istiod (expected 0);
  labeling them adds exactly 400 (expected 400).
- Not measured by this profile (the report says so): the pods vs config-only calibration and
  the measurement-pod sweep.
- The 600 namespaces were deleted afterwards with `tests/controlplane/005-cleanup.sh --series`
  in 333 s (1.8 namespaces/s).

## Reading these numbers

- **Propagation's convergence histogram is empty.** P1 conv_p50 and conv_p99 are N/A in every
  row: each iteration produced 5 samples, below the probe's floor (10 for p50, 30 for p99). That
  is the floor working at lab size, not a fault. Most controlplane probe windows likewise have
  too few pushes for a conv_p99 fit.
- **`nodes none`** in the platform record: the field reads a cloud instance-type label, which
  these nodes do not have.
- **`<mesh-c-ctx>`, `<mesh-d-ctx>`** in the controlplane TSVs' `MEM_GUARD_CONTEXTS`: the
  `config/versions.env` default contexts, which the memory guard sampled by mistake (issue 2
  below). They are not members of this mesh, and the guard warned and skipped them.

## Issues found

Fixed in the PR that adds this record:

1. **Preflight misread istioctl 1.30's version.** `istioctl version --short` prints
   `client version: 1.30.5` since 1.30, so preflight warned that istioctl 1.30.5 was not
   v1.30.5. A warning only.
2. **Controlplane's memory guard sampled `config/versions.env`'s default contexts.** With
   `--contexts` given and `SETUP_CONTEXTS` unset, the guard added the default
   (`cluster-002,cluster-003`), could not read either and warned. It now adds `SETUP_CONTEXTS`
   only when the caller set it.
3. **`redact-results.sh` learned prose as context names.** The propagation report's glossary
   reads "`REMOTES`: iterations for the P1 phases ...", which it took for a member list, so
   every "the", "rows" and "P1" in the copy became a placeholder. A key in a code span followed
   by a colon is now prose.

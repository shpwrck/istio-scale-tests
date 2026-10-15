# 2026-10-14 ROSA validation window (backlog tasks 1, 3, 4, 6)

One cost-capped window on ROSA HCP, run from the plan in
[`docs/runbooks/rosa-validation/window-plan.md`](../runbooks/rosa-validation/window-plan.md) with
no cuts and three owner-approved extensions. It gave tasks 1 and 4 their first live runs, closed
task 3's AWS load-balancer questions, and put first at-scale numbers on task 6. It also found 17
issues; the fixes are queued in [`BACKLOG.md`](../../BACKLOG.md) (section 9). Raw data is not in
git; where it lives is under [Raw data](#raw-data).

Contexts are placeholders: `<acm-hub-ctx>` is the ACM hub, `<mesh-a-ctx>`, `<mesh-b-ctx>` and
`<mesh-c-ctx>` are the three mesh members (`cluster-002` to `cluster-004` in the generated
kubeconfig). No hostnames, addresses or account data are quoted. Memory is in Mi (MiB) as the tools
print it; GiB = Mi / 1024.

## Rig

| Item | Value |
| --- | --- |
| Platform | ROSA HCP 4.21.11, us-east-2, single AZ; Tier C |
| Hub | `<acm-hub-ctx>`: 2× m5.2xlarge, ACM + OpenShift GitOps (not a mesh member) |
| Members | `<mesh-a-ctx>`: 3× r7i.2xlarge; `<mesh-b-ctx>`, `<mesh-c-ctx>`: 3× m7i.xlarge; fixed pools |
| Mesh | OSSM 3.4 (Istio v1.30.5), multi-primary, multi-network, shared root CA; window commit `8150d4b` |
| istiod (override) | 1 replica per member, request 2 CPU / 8Gi, limit 4 CPU / 16Gi |
| Sidecars (override) | request 20m / 64Mi (scheduling only; limits unchanged) |
| Gateways | Classic LBs (`externalTrafficPolicy: Cluster`); memory limit 1Gi, raised to 3Gi at 19:38 UTC for the extensions |
| Clock | T0 12:42 UTC; teardown started 21:37, clusters gone 21:54, audit `CLEAN` 22:01 |
| Cost | about $82 (estimate: 9.2 billed hours × $8.25/h + about $6 variable); Cost Explorer pending at T+1/T+2 |

## Scale envelope (peak of the window)

| Dimension | Peak | Where |
| --- | --- | --- |
| Discovered Services on `<mesh-a-ctx>` | 8007 (K=4 × 2000 namespaces, plus the probe namespace) | extension X1 |
| Discovered namespaces | 6000 (4000 + 2000 labeled outside) | extension X2 |
| Connected proxies per cluster (pods mode) | 502 | task 6, P4a |
| Per-proxy config | 351 KB (`namespace` scoping, flat) to 47 MB (`wide` at 8000 Services) | R1, X1 |
| istiod on `<mesh-a-ctx>` | RSS peak 2924 Mi: 18% of the 16Gi limit (X1: 2702 Mi, 16%) | X2 |
| istiod on `<mesh-b-ctx>`, `<mesh-c-ctx>` (remote ingestion) | at most about 1844 Mi, under the 8Gi request | X2 |
| East-west gateway (each member) | working set 2252-2514 Mi (2.20-2.46 GiB): **73-82% of the 3Gi limit** | X2 |
| Worker nodes on `<mesh-a-ctx>` | CPU 12% (X2), memory 46% (P4a) | sweep envelopes |

**Scale verdict:** istiod never came near a limit; the **east-west gateways are the binding
resource** for a mesh with thousands of Services. The original 1Gi gateway limit caps the mesh near
5000 discovered Services, and an onboarding burst of 4000 Services left a working set above 1Gi.

## Results

| Task | Result | Headline |
| --- | --- | --- |
| 3 AWS load balancers | **Validated** | Every east-west LB replacement or delay recovers by itself in about 2-3 min with no restart; the failure is partial and directional (only paths into the bad member fail), as in June |
| 4 istiod restart diagnostics | **Validated live** | Smoke GO; no false capture all day; a real restart captured with complete evidence; the new istiod was Ready 12 s after the delete (11 s after creation) at 6000 discovered Services |
| 6 VS/DR load | **First at-scale numbers** | At 150-250 Services × 2: +2 clusters per Service, CDS about 3.5×, RDS about 2.3×, push time 3-4×; istiod heap in use -13% to +37% |
| 1 Namespace scaling | **Validated, customer numbers** | Gateway and proxy cost is per Service; istiod heap about +100 Mi per 1000 namespaces (K=1); `wide` scoping costs every proxy about +117 Mi per 1000 Services |
| Baseline | AWS dataplane | Remote p50 2.5-3.8 ms, p99 4.0-5.3 ms; full QPS, 100% HTTP 200 |
| Platform | 17 issues | Argo CD shard, ingress on Classic LBs, OAuth exec plugin, guard gaps, gateway sizing: see [Issues found](#issues-found) |

## Timeline (UTC)

| Phase | Time | Note |
| --- | --- | --- |
| P1 provision | 12:42-13:18 | rosa-hcp 224 resources (24 min), platform 37 resources |
| P1 stall | 13:18-14:00 | `<mesh-b-ctx>` never got an Argo CD controller shard; controllers restarted 13:54, all 40 Applications Synced/Healthy 14:00 |
| P2 verify, A0 | 14:00-14:10 | 3 gates `Ready ... ca=shared`; istiod 1 pod 8Gi/16Gi, 0 restarts; every istiod started after its `cacerts`, also on `<mesh-b-ctx>` after the 40-min stall (`cacerts` 13:58:40, istiod 13:59:26); 645 free pod slots on `<mesh-a-ctx>` |
| P3 baseline + task 4 smoke | 14:11-14:22 | GO |
| P4 task 6 | 14:20-15:06 | 6 cells |
| P5 task 3 | 15:06-15:48 | A1-A4 and the recovery gate; ingress check to 15:58 |
| P6 task 1 | 15:49-19:36 | R0, S1 (GO), R3, R1, R1b (added), R2 |
| Extensions | 19:38-21:31 | gateway limit 3Gi; calibration; X1; X2 |
| P7 task 4 | 21:32-21:36 | pass |
| P8, P9 | 21:37-22:01 | evidence archived; `003-auto-teardown.sh --now`, audit clean |

The owner chose a no-cut run at 14:23 and approved spend above $100 at 19:33; the auto-teardown
timer was re-armed four times (final: T0+11:15) and never fired.

## Baseline (P3): AWS cross-cluster dataplane

Three members, source `<mesh-a-ctx>`, 30 s per level, 2 server replicas. Both remotes REACHABLE
10/10; local baseline OK at every level; no `istiod-diag` capture.

| QPS | Local p50 / p99 (ms) | Remote p50 / p99 (ms) | Achieved QPS | HTTP 200 |
| --- | --- | --- | --- | --- |
| 10 | 2.35 / 3.72 | 3.80 / 5.27 | 10.0 | 100% |
| 100 | 1.54 / 2.89 | 3.53 / 5.16 | 100.0 | 100% |
| 500 | 1.50 / 2.73 | 3.23 / 4.36 | 499.9-500.0 | 100% |
| 1000 | 1.47 / 2.00 | 2.54 / 3.96 | 999.9 | 100% |

## Task 3: AWS load balancers (P5)

Fault injection on `<mesh-c-ctx>`'s east-west gateway only: A1 relied on Argo CD self-heal, A2-A4
ran under one GitOps pause. A fortio client on every member probed all 6 directions about every
11-13 s; the poller also recorded the Service, the LB hostname, DNS, CLB instance health and each
peer istiod's `networkz`.

| Case | Outage | Recovery (from the fix) | Restarts |
| --- | --- | --- | --- |
| A1 Service deleted, Argo CD recreates it (CLB) | a→c, b→c only (9 of 17 rounds after the delete); c→a, c→b, a↔b never (0/18) | 120 s | none |
| A2 LB provisioned late (bogus subnet, `SyncLoadBalancerFailed`), held 4.5 min | a→c, b→c 22/22 rounds of the hold; c→a, c→b, a↔b 0/22 | 103 s after the annotation was removed | none |
| A3 rollout restart, scale 1→3→1 behind the live CLB | **none** (0/14) | — | — |
| A4 Service recreated as an NLB | a→c, b→c only | 167-188 s | none |
| A4 rollout restart, scale 1→3→1 behind the NLB | **none** (0/9; 12/12 targets healthy) | — | — |

Recovery order (A1, seconds after the delete): peers drop c's gateway from `networkz` and x→c fails
+17; new hostname +27; 3/3 instances InService +74; DNS resolves +97; both peers' `networkz` show
the new address +111; a→c and b→c recover +120. A2 after the fix: hostname +11, InService +59, DNS
+81, `networkz` +95, traffic +103. NLB (A4): hostname +14, DNS +152 (NLB activation dominates),
traffic +167 (b→c) and +188 (a→c).

- The official probe agreed: during A2, from `<mesh-a-ctx>` the bad member was UNREACHABLE 0/10
  (`connection timeout`); from `<mesh-c-ctx>` both others were REACHABLE 10/10.
- The chart's east-west gateway has no HPA (`autoscaling.enabled: false`), so A3 scaled the
  Deployment directly under the pause.
- Recovery gate: pause resumed, Argo CD recreated the chart-spec CLB Service, every source
  REACHABLE 10/10, `ca=shared` on all gates, exactly 2 gateway CLBs (+ the router NLB) per member;
  the A4 NLB was deleted, nothing orphaned.

**Conclusion for task 3:** on AWS the load-balancer lifecycle (recreate, late provisioning, NLB)
produces the June signature (partial, directional) but always heals itself within about 3 minutes
without a restart, and gateway churn behind a live LB causes no failure at all. It does not explain
members that stayed broken; the lab's CA race does, and its guard held on ROSA even with a 40-min
sync delay. A second candidate for June is new: at 10k Services the east-west gateways need more
than their 1Gi limit (see task 1), so they may have been OOM-killed (hypothesis H1 in the backlog).

### Ingress on Classic LBs drops HTTP (finding 7)

mesh-verify through the **ingress** gateways failed intermittently all day: requests reached the
gateway (logged `DC downstream_remote_disconnect`, 0 ms) but no response ever came back, from the
operator laptop or from inside AWS. The failing members changed between tries (14:02 a and c; 14:53
b; 15:06-15:18 a 0/41, c 0/41, b 17/41). Isolation:

- Status port 15021 answered through all 6 gateway CLBs; the NodePort answered 200 from every node
  in-cluster; a port-forward to the gateway pod answered 200 with answers from all 3 members.
- Security-group rules were identical on every member and cover the whole NodePort range.
- A packet capture on `<mesh-c-ctx>`'s gateway node showed the 81-byte request followed by a
  **FIN 0.01 ms later**; Envoy then aborts the proxied request. A raw socket that never
  half-closes, and curl from a node's host network, both failed the same way.
- **Same gateway, same routes, as an NLB: 36/36 OK** (avg 0.19 s), while `<mesh-a-ctx>`'s CLB
  ingress failed 36/36 over the same 5 minutes (15:52-15:57).

East-west traffic (mTLS passthrough between Envoys) was unaffected on CLBs all day. Fix candidate:
an NLB for the ingress Service on AWS (owner decision, backlog 9.8).

## Task 6: VS/DR load in pods mode (P4)

P4a on `<mesh-a-ctx>` (mesh size 1), P4b on `<mesh-a-ctx>` + `<mesh-b-ctx>` (mesh size 2); one
VirtualService + DestinationRule (2 subsets) per Service. Every cell `proxy_check=OK`, no restart.

| Cell | CDS clusters / proxy | CDS bytes | RDS bytes | Config dump | istiod heap in use | xDS pushes | Push time avg |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 150 svc × 2, none → vsdr | 165 → 465 (+300) | 414 → 1435 KB (+246%) | 147 → 331 KB (+125%) | 1.40 → 3.60 MB | 392 → 342 Mi (-13%) | +30% | 4.4 → 13.9 ms |
| 250 svc × 2, none → vsdr | 265 → 765 (+500) | 668 → 2370 KB (+255%) | 239 → 546 KB (+128%) | 2.11 → 5.78 MB | 456 → 626 Mi (+37%) | +23% | 7.6 → 29.1 ms |
| 60 svc × 2 per member, mesh 2 | 75 → 195 (+120) | 186 → 594 KB (+220%) | 64 → 138 KB (+114%) | 0.83 → 1.84 MB | 232 → 210 Mi (-10%) | +32% | 0.72 → 1.52 ms |

istiod RSS rose +56% (654 → 1018 Mi) and +78% (828 → 1478 Mi) in P4a, but the report flags it as
order-biased: each vsdr cell runs right after its none cell and RSS does not shrink after GC, so
compare heap in use.

Open: in both P4a vsdr cells the convergence p99 bucket (and the push queue-time p99) jumped from
100-1000 ms to 10-20 s; at 60 Services (P4b) convergence rose only from 0-100 ms to 100-500 ms.
Real cost or an artifact of the per-subset Deployments is not yet known (backlog 9.11).

## Task 1: namespace scaling (P6 and the extensions)

Growth mode on `<mesh-a-ctx>`: config-only workloads (Services without pods, 8 measurement pods),
istiods on b and c ingest everything through remote discovery. All slopes below are linear fits
from the 004 report (per 100 or per 1000 namespaces, R², raw points in the sweep reports).

**S1 smoke: GO** (all six criteria): 12/12 rows OK, no restart; header 63 fields (=
`CONTROLPLANE_SCHEMA=63`; the plan's "62" was stale); the Namespace scaling section with fits and
raw points; apply 10-13 objects/s (R1's 16,000 objects about 21 min); 0 API 429s; the memory guard
projected istiod and both gateways on all three members.

### Scaling factors

| Component | Metric | Per 1000 | Points | Fit |
| --- | --- | --- | --- | --- |
| istiod (`<mesh-a-ctx>`) | heap in use | **+100 Mi per 1000 namespaces** (K=1) | 146 / 192 / 387 / 518 Mi at 250 / 1000 / 2000 / 4000 | R² 0.95-1.00, log-log 0.47 |
| istiod | RSS | +200-220 Mi per 1000 namespaces (K=1) | 300 → 1096 Mi | R² 0.84-0.87 (GC noise) |
| istiod | PushContext init | +2.2-3.4 ms per 1000 Services | 13.5 ms at 4000; 17.4 ms at 8000 | R² 1.00 |
| East-west gateway | clusters | **+2000 per 1000 Services** (exact) | 8029 at 4000; 16,035 at 8000 | — |
| Ingress gateway | clusters | +1000 per 1000 Services | 4020 at 4000; 6017 at 6000 | — |
| East-west gateway | memory (Envoy allocated) | **+143-144 Mi per 1000 Services** (K=1 and K=4 alike) | 582 Mi at 4000; 1156 Mi at 8000 | R² 1.00 |
| Ingress gateway | memory (Envoy allocated) | about +91 Mi per 1000 Services | 371 / 551 / 734 Mi at 4000 / 6000 / 8000 | linear, 3 points (guard TSVs) |
| Sidecar, `namespace` scoping | config / Envoy memory | flat: 351-369 KB / +1 Mi | 14-18 Mi at 4000-8000 | — |
| Sidecar, **`wide`** scoping (`*/*` per namespace) | config per proxy | **+5.85 MB per 1000 Services** | 23.8 MB at 4000; 47.2 MB at 8000 | R² 1.00 |
| Sidecar, **`wide`** scoping | Envoy memory per proxy | **+117 Mi per 1000 Services** | 480 Mi at 4000; 936 Mi at 8000 | R² 1.00 |
| istiod on b/c | RSS (remote ingestion) | rough | 174-646 Mi during R1's cells (821 Mi during the undiscover); about 1.45 GiB at 8000 Services | from `oc adm top` |

K=4 (R2, X1) gives the same per-Service slopes as K=1 for gateways and `wide` proxies: those costs
follow Services, not namespaces. The istiod heap split into a per-namespace and a per-Service part
could not be measured cleanly: R1b and later runs had thousands of undiscovered leftover namespaces
in istiod's informer cache (finding 13), which inflates their absolute heap.

### Gateway memory: the limit that matters

| State | Clusters | Allocated | Working set (`oc adm top`) |
| --- | --- | --- | --- |
| 4000 Services, grown 250 → 1000 → 2000 → 4000 (R1) | 8027 | 582 Mi | not sampled |
| 4000 Services, grown 0 → 4000 in one step (X1) | 8035 | 581-633 Mi | **1075-1119 Mi** (tcmalloc heap about 1056 Mi) |
| 8000 Services (X1) | 16,035 | 1156 Mi | 1419-1577 Mi |
| 6000 Services after 4000 + 2000 bursts (X2) | 12,029 | 862-938 Mi | **2252-2514 Mi** (tcmalloc heap about 3050 Mi, at the limit) |
| Ingress gateway at 6000 Services | 6017 | 550 Mi | about 640 Mi (tracks live data) |
| Fresh east-west gateway, initial load at 6000 | 12,029 | — | 1062-1083 Mi |

- Under the original **1Gi** limit, R1's labeled-outside cells and R2's 8000-Service step were
  correctly skipped by the guard (`SKIPPED_MEM_GUARD`: projected 868 Mi and 1156 Mi > 70%), but X1's
  first step (0 → 4000 Services) left a working set of 1075-1119 Mi, above 1Gi: the guard cannot
  project a series' first step (findings 4, 15).
- After config bursts the east-west gateway keeps freed memory (cluster + SNI listener churn); the
  ingress gateway does not. The working set ran 1.2-2.9× the allocated figure the harness records
  (1.7-1.9× after X1's burst, 2.6-2.9× after X2's), so sizing must use the working set
  (findings 14, 16, 17).
- Envoy also kept about 500 Mi after a series was undiscovered; the run reset the gateways (a
  rollout restart on all members, nothing measuring) before the later series and before P7.

### Discovery (`discoverySelectors`)

| Cell | Outside namespaces | istiod Services | Gateway clusters | Root-cert ConfigMaps | istiod heap |
| --- | --- | --- | --- | --- | --- |
| N=4000, `namespace` (R1) | 2000 **unlabeled** | +0 | +0 | +0 | +176 Mi |
| N=4000, `wide` (R1) | 2000 unlabeled | +0 | +0 | +0 | +214 Mi |
| N=1000 (R1b) | 1000 unlabeled | +0 | +0 | +0 | +17 Mi |
| N=1000 (R1b) | 1000 **labeled** | +1000 | +2000 | +1000 | +54 Mi |
| N=4000 (X2) | 2000 labeled | +2000 | +4000 | +2000 | +511 Mi |

`discoverySelectors` keeps excluded namespaces out of xDS entirely (Services, gateway clusters,
root-cert ConfigMaps), but istiod's informers still cache their objects, so part of the heap cost
remains. The heap deltas are single samples and noisy.

### Other task 1 results

- **Measurement-pod sweep** (X1, 8000 Services, M 8 → 16): istiod heap +2.75 Mi per added
  measurement pod under `namespace` scoping (1161 → 1183 Mi), +28.5 Mi per pod under `wide` (1603
  → 1831 Mi). The approved M=4 point was dropped to keep M=8 as the base (see Deviations).
- **Pods vs config-only** (R3 pods at 40 and 250 namespaces vs a config-only calibration at the same
  N, pooled base-dir report): per-proxy config 1.00×, Envoy memory 0.9×, istiod Services 1.00×,
  pushes per proxy 1.2-1.5×; total xDS pushes 5× (40) and 38× (250) higher with one proxy per pod.
  Config-only measures per-Service state, not push fan-out. The heap ratio is confounded (finding 13).
- **Lifecycle:** 0 API 429s all day; apply 10-20 objects/s; undiscover 6000 namespaces in 448 s;
  delete 0.6-2.0 namespaces/s (fresh cells).
- **SLA verdict** (R1): CAUTION, only because 3 rows are guard skips.
- **b/c ceiling:** the istiods on b and c stayed far under their 8Gi request (at most about 1.8 GiB).

## Task 4: istiod restart diagnostics (P3, P7)

- **P3 smoke, GO:** `quiet` one `no_change` row; `forced` two rows (`replaced_gone` + `new_pod`, one
  evidence folder with every expected file, no `*.unavailable`); no failed or exhausted rows;
  redaction checks clean; startup log 166 KB (bound 256 KB), 96 KB in total. The forced pair reads
  `cause=rollout` because the synthetic absent pod has no ReplicaSet to compare.
- **Passive capture all day:** the only `istiod-diag-*` directory of the window is P7's; P3-P6 and
  the extensions produced no false capture.
- **P7, pass:** churn from `<mesh-a-ctx>`, istiod on `<mesh-b-ctx>` deleted at iteration 2's
  scaling step, 6000 namespaces discovered. Iteration 2 `POISONED_RESTART` (remote endpoint
  reachable after 15.3 s vs 5.7-6.6 s in the clean iterations); the capture has
  `replaced_gone`/`deleted` and `new_pod`/`replacement`, evidence 80 KB, redaction clean; iteration
  3 re-detected the changed pod set as `already_captured`. The new istiod was created 1 s after the
  delete and **Ready 11 s later** (12 s after the delete) while ingesting 6000 remote Services. No
  gateway restarted.
- Still lab-only: the node-reboot read-only capture, a forced OOM, a forced failed capture, and an
  istiod pod delete during a dataplane and a controlplane run (ROSA covered churn only).

## Issues found

| # | Issue | Backlog |
| --- | --- | --- |
| 1 | Argo CD never assigned `<mesh-b-ctx>` a controller shard (consistent-hashing, 2 replicas): its 6 Applications had no status for 35 min | 9.1 (fix decided) |
| 2 | Kubeconfig exec plugin logs in through OAuth on every `oc` call: 3843 OAuthAccessTokens on `<mesh-a-ctx>` at 19:37 UTC; intermittent `failed to obtain OAuth token` | 9.2 |
| 3 | A failed series retire only warns and the sweep exits 0 (R1b): the next series (R2) started with R1b's 2000 namespaces still discovered and was stopped before its first cell | 9.3 |
| 4 | Memory guard projects from the series-start memory, which leftover Envoy memory inflates | 9.4 |
| 5 | Without `--config`, the guard samples `--contexts` + the `SETUP_CONTEXTS` default (2 members) and misses the third | 9.6 |
| 6 | The capacity planner assumes 200m per pod, ignoring the real requests: false warnings | 9.7 |
| 7 | Classic LBs break HTTP through the ingress gateway; NLB works | 9.8 (decision) |
| 8 | The 1Gi gateway memory limit caps the mesh near 5000 discovered Services | 9.9 (decision) |
| 9 | window-plan expected a 62-field header (63) | 9.12, fixed in the window-plan |
| 10 | window-plan assumed an HPA on the east-west gateway (none) | 9.12, fixed in the window-plan |
| 11 | README "Verify" through the ingress fails on AWS (7) | 9.8 |
| 12 | VS/DR convergence p99 10-20 s at 150-250 Services | 9.11 (analysis) |
| 13 | Leftover undiscovered namespaces inflate later series (istiod informers, remote watches) | 9.10 |
| 14 | An onboarding burst leaves the east-west gateway working set well above its allocated memory (1075-1119 Mi vs 581-633 Mi at 4000 Services) | 9.9 |
| 15 | The guard cannot protect a series' first step | 9.4 |
| 16 | Guard and fits use Envoy allocated / Go heap, not the working set the OOM killer uses | 9.5 |
| 17 | East-west gateway heap grows to the container limit after bursts (allocator retention) | 9.9 |

## Deviations from the plan

- No cuts (owner, 14:23); three extensions (owner, 19:33): gateway memory limit 3Gi through a second
  `-var-file` (`gitops_app_overrides` for both gateway ApplicationSets; `rosa.tfvars` untouched),
  the pods-vs-config-only calibration, and X1/X2 with the M-sweep folded into X1. The M-sweep ran
  M 8 → 16 only; the approved M=4 point was dropped so the base stayed M=8 like R1 and R2.
- Added R1b (labeled vs unlabeled outside at N=1000) to recover R1's guard-skipped cells.
- Gateway resets (rollout restart on all members, between runs only) before R1b, R2, X2 and P7;
  the 3Gi apply at 19:38 also rolled them before the calibration and X1. A mutation on
  `<mesh-a-ctx>` and `<mesh-b-ctx>`, outside the plan's "mutations on c only".
- Every P6 command passed `--mem-guard-contexts` with all three members (finding 5).
- R2 was stopped seconds after its first start (R1b's series still discovered) and rerun after a
  manual undiscover; R2's series was retired by the sweep, so P7 ran on X2's kept series (6000
  namespaces) instead.
- Teardown went straight to `003-auto-teardown.sh --now` (24.5 min, `CLEAN`) instead of the planned
  platform destroy first.

## Raw data

Not in git (gitignored results, and raw logs hold context names and LB hostnames). On the
operator host only; an off-laptop copy is pending the owner's choice of destination:

- Window worktree `<repo>/.claude/worktrees/rosa-window` (detached at `8150d4b`):
  `tests/dataplane/results/rosa-baseline/` (P3), `tests/churn/results/rosa-diag-smoke/` (P3 smoke),
  `tests/controlplane/results/rosa-task6/` (P4a, P4b),
  `tests/dataplane/results/rosa-lb/` (P5: `timeline/` per case, `a0/` incl.
  `ingress-clb-finding/`, `ingress-probe/`, `ingress-nlb/`),
  `tests/controlplane/results/rosa-task1-smoke/` (S1), `tests/controlplane/results/sweep-*`
  (R3 `20261014T1630*`, R1 `20261014T164421Z-*`, R2 `20261014T184721Z-*`, calibration
  `20261014T1939*`; the pooled pods-vs-config-only report reads this base dir),
  `tests/controlplane/results/rosa-task1-discovery/` (R1b), `rosa-task1-x1/`, `rosa-task1-x2/`,
  `tests/churn/results/` (P7 and its `istiod-diag-*`).
- Operator files `~/.rosa-window/`: `status.md` (the chronological log), phase logs `p*.log` and
  `x*.log`, `teardown.log`, `p9-audit.txt`, `x-runs.sh` (extension commands),
  `gw-extension.tfvars`, and the archive `results-20261014-rosa-window.tar.gz` (all results).

## Reproduce

Window worktree at `8150d4b`, inputs as in the runbook's Template map, then the phases in
[`window-plan.md`](../runbooks/rosa-validation/window-plan.md) with the corrections listed at its
top. Commands for the runs the plan did not have, all with `--contexts <mesh-a-ctx> --mesh-sizes 1`
and `--mem-guard-contexts <mesh-a-ctx>,<mesh-b-ctx>,<mesh-c-ctx>`:

- R1b: `003 --services-per-namespace 1 --namespace-counts 1000 --sidecar-scopings namespace
  --workload-mode config-only --measurement-pods 8 --config-dump-samples 4 --outside-namespaces
  1000 --outside-modes unlabeled,labeled --settle 45 --probe-settle 45
  --output-dir tests/controlplane/results/rosa-task1-discovery`
- Calibration: `003 --growth fresh --services-per-namespace 1 --namespace-counts 40,250
  --sidecar-scopings namespace --workload-mode config-only --measurement-pods 8 --outside-modes none`
  into the default results dir (where R3 wrote), then `004 --results-dir tests/controlplane/results`
  for the pooled pods-vs-config-only row.
- X1: `003 --services-per-namespace 4 --namespace-counts 1000,2000 --sidecar-scopings
  namespace,wide --workload-mode config-only --measurement-pod-counts 8,16 --outside-modes none`.
- X2: `003 --services-per-namespace 1 --namespace-counts 4000 --sidecar-scopings namespace,wide
  --workload-mode config-only --measurement-pods 8 --outside-namespaces 2000 --outside-modes labeled
  --series-retire keep`.
- X1 and X2 with `CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S=180`, `--settle 45 --probe-settle 45`,
  `--config-dump-samples 4`, after raising both gateway limits to 3Gi through
  `gitops_app_overrides`.

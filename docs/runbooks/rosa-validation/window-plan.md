# ROSA validation window plan

The test plan for one cost-capped window on ROSA HCP: what it answers, what it costs, the run order
with checkpoints and a cut list, and the teardown. How to operate the clusters (state, access,
apply, verify, recover) is in [README.md](README.md). Prices were checked on 2026-10-13 for
us-east-2. Context names are placeholders: `<acm-hub-ctx>` is `cluster-001`, and `<mesh-a-ctx>`,
`<mesh-b-ctx>`, `<mesh-c-ctx>` are `cluster-002` to `cluster-004` in the generated kubeconfig.

## Corrections from the 2026-10-14 window

This plan ran on 2026-10-14
([record](../../campaigns/2026-10-14-rosa-validation.md)). Read the plan below with these
corrections; the fixes behind them are queued in [`BACKLOG.md`](../../../BACKLOG.md), section 9.

**Since 2026-10-16 the harness and platform do most of this themselves** (BACKLOG 9.1-9.11):
the platform apply restarts the Argo CD controller after the cluster secrets and fails if an
Application has no status; the kubeconfig exec plugin caches its OAuth token; a failed series
retire stops the sweep (`RETIRE_FAILED`, exit 1); the memory guard adds the members it finds
in the remote secrets, guards the first step with a per-Service model and compares working
set, not allocated memory; the gateways default to 5Gi (east-west; 4Gi in the 2026-10-16
window) and 2Gi (ingress) limits; the ingress gets an NLB in rosa mode; the header has 66 fields
(`CONTROLPLANE_SCHEMA=66`). The bullets below still say what to check by eye; the 2026-10-16
window confirmed each fix (BACKLOG section 9, "Validated on ROSA").

- **After the platform apply, check every Application has a sync and health status.** One member
  never got an Argo CD controller shard; restarting the
  `openshift-gitops-application-controller` pods fixed it (9.1). Budget 30-40 min for this in P1.
- **S1 and every P6 command take `--mem-guard-contexts <mesh-a-ctx>,<mesh-b-ctx>,<mesh-c-ctx>`.**
  Without `--config`, the guard samples only `--contexts` and the `SETUP_CONTEXTS` default (9.6).
- **S1's header check is 63 fields** (`CONTROLPLANE_SCHEMA=63`), not 62.
- **After every growth series, check that it was retired:** `oc get ns -l istio-discovery` on the
  measured member must be empty (or show only a series kept on purpose). A failed retire only warns
  (9.3), and the kubeconfig's exec plugin fails intermittently under the harness's load (9.2).
- **Reset the gateways before each growth series and before P7** (rollout restart of both
  gateways on every member, nothing measuring): Envoy keeps memory after a series, which skews the
  next series and the guard (9.4).
- **The gateway memory limit (1Gi) caps task 1** near 5000 discovered Services, and a one-step
  burst of 4000 Services exceeds it (9.9): R1's labeled-outside cells and R2's 2000 step become
  `SKIPPED_MEM_GUARD` rows; set a higher limit in `gitops_app_overrides` before apply to measure
  further.
- **P5: the east-west gateway has no HPA** (`autoscaling.enabled: false`); A3 scales the
  Deployment directly under the pause.
- **Ingress checks through Classic LBs fail intermittently** (9.8); verify the mesh through the
  east-west path (a fortio client per member) or an NLB ingress.
- **The M-sweep needs M ascending with the base first:** `--measurement-pod-counts 8,16` keeps the
  base at M=8 (as R1, R2); an M=4 point needs its own series.
- **R2's series is retired by the sweep** (default `--series-retire undiscover`); pass
  `--series-retire keep` on the last series if P7 should run at scale.
- **Pace:** P4 ran in 45 min (P4a cells about 8 min), P5 in 42 min, S1 in 28 min, R1 in 93 min;
  the teardown with `003-auto-teardown.sh --now` took 24.5 min to `CLEAN`.

## Owner decisions (settled 2026-10-13)

These are binding for the window. Worker types and mesh-wide values cannot change once the clusters exist.

- **Tier C is the plan of record.** The hub runs on 2× m5.2xlarge, `<mesh-a-ctx>` on 3× r7i.2xlarge,
  and `<mesh-b-ctx>` and `<mesh-c-ctx>` on 3× m7i.xlarge, all at a fixed size. It costs $8.25/h; the
  core run is about 7.25 h and $65 ([Tiers](#3-tiers)). Tier C was chosen for the memory headroom it
  gives task 1's wide cells, and because task 6 can run in pods mode at 150-250 services × 2 on
  mesh-a, all within the cap. The lab shape check that could have shown 8Gi to be enough could not
  run (the lab was powered off on 2026-10-13), so the window pays for the headroom instead.
- **Spend cap: $100, hard, for the window.** Nothing else bills in the account, so the AWS Budget
  `rosa-window-monthly` has a $100 limit, with ACTUAL alerts at 50%, 80% and 100% and a FORECASTED
  alert at 100% ([section 7](#7-spend-guardrails-checkpoints-cut-list)).
- **Timers are sized to the cap.** The teardown starts by T0+7:45, `rosa-warn` fires at T0+7:15, and
  the auto-teardown fires at T0+8:15. The worst case is about $81, which leaves $19 under the cap
  (arithmetic in [Tiers](#3-tiers)).
- **A failed or unfired auto-teardown must reach the operator.** Two alerts cover it, both free and
  both required:
  - an SNS topic with a confirmed email subscription, passed to `003-auto-teardown.sh --arm` (which
    refuses to arm without one);
  - an off-host phone alarm at T0+9:15. It also covers a dead operator host, where the timer never
    runs and so sends nothing.
  - Either one leaves time to act: a manual `003 --now` started by T0+10:30 still ends billing under
    the cap ([If the T0+9:15 alarm rings](#if-the-t0915-alarm-rings)).
- **istiod on every member:** 1 replica, request 2 CPU / 8Gi, limit 4 CPU / 16Gi. The limit lets
  istiod grow on mesh-a's 64 GiB nodes. On b and c it is nominal; see
  [b and c under the 16Gi limit](#b-and-c-under-the-16gi-limit).
- **Sidecar proxy requests:** 20m CPU / 64Mi memory, limits unchanged. This changes scheduling
  only, and the campaign doc records it.
- **Region:** us-east-2.
- **Tasks 1 and 4 were never lab-validated,** because the lab was powered off. Their first runs on
  ROSA are their first live runs. Each starts with a smoke step and a go/no-go before anything
  expensive depends on it: P3 for task 4, S1 in P6 for task 1. A no-go ends that task's part of the
  window, not the window.
- **Fallbacks:**
  - Tier B if us-east-2 does not offer r7i.2xlarge, or if the 64-vCPU quota is not granted by the
    end of P0.
  - Tier A only if 52 vCPUs are not available either ([Fallback tiers](#fallback-tiers-b-and-a)).
  - Never the m7i.4xlarge variant of C: on these timers its worst case is about $98.

## 1. What the window answers

| Task | Question | Phase |
| --- | --- | --- |
| 3, east-west via AWS LBs | Does traffic recover, without a gateway restart, when the east-west LB is recreated (new hostname, DNS, target registration) or provisioned late? With 3 members, is the failure partial (a↔b fine, x→c broken) and directional (c→a and c→b still fine, because they leave through a's and b's healthy gateways)? CLB vs NLB? | P5 |
| 6, VS/DR load | istiod and per-proxy deltas, `none` vs `vsdr`, in pods mode. Two sizes: 150 and 250 services × 2 replicas on mesh-a (up to 500 sidecars), and 60 × 2 per member across a and b (mesh size 2) | P4 |
| 1, namespace scaling (only if its PR is in the pinned commit) | First live run: smoke S1, then go/no-go. R1: K=1 service per namespace up to 4000 namespaces plus 2000 outside namespaces, including the wide cells at 2000-4000 that an 8Gi istiod could not hold. R2: K=4 up to 2000. R3: pods-mode points at 40 and 250 namespaces for the required pods-vs-config-only comparison | P6 |
| 4, istiod restart diagnostics (only if its PR is in the pinned commit) | First live run: does the capture work on HCP without a restart (P3 smoke, read-only), and with one (P7)? How long does recovery from an istiod pod delete take while task 1's objects are still discovered? | P3, P7 |
| Baseline | AWS cross-cluster latency with 3 members | P3 |

It cannot answer:

- Task 4's root cause. Proxies per istiod, the 19 remote watches and push fan-out all differ from
  the June restart.
- Anything that needs 19 remotes or campaign-scale proxy counts, or task 2 at campaign scale.
- Task 6 above about 250 services × 2 replicas (bounded by mesh-a's pods per node), or at hundreds
  of services on b and c (16 GiB nodes). Config-only mode was not built for `vsdr`.
- Task 1 cells that would push istiod on b or c past its 8Gi request, or mesh-a's istiod past the
  guard (70% of 16Gi).

## 2. Prices

Checked 2026-10-13, us-east-2, on-demand Linux. The date after each source is the page's own
"updated" or "published" date.

| Item | Price | Source |
| --- | --- | --- |
| ROSA HCP cluster fee | $0.25 per cluster-hour | <https://aws.amazon.com/rosa/pricing/> (2026-10-08) |
| ROSA worker fee | $0.171 per 4 vCPU-hour ($0.04275 per vCPU-hour), the same in every standard region | same page |
| m7i.xlarge (4 vCPU / 16 GiB) | $0.2016/h | EC2 price feed behind <https://aws.amazon.com/ec2/pricing/on-demand/>: <https://b0.p.awsstatic.com/pricing/2.0/meteredUnitMaps/ec2/USD/current/ec2-ondemand-without-sec-sel/US%20East%20(Ohio)/Linux/index.json> (2026-10-12) |
| m7i.2xlarge / m7i.4xlarge | $0.4032/h / $0.8064/h | same feed |
| m5.2xlarge (8 / 32) / m5.4xlarge | $0.384/h / $0.768/h | same feed |
| r7i.2xlarge (8 / 64) | $0.5292/h | same feed |
| m6a.xlarge / m6a.2xlarge | $0.1728/h / $0.3456/h | same feed |
| Classic LB | $0.025 per LB-hour "(or partial hour)" + $0.008/GB | <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSELB/current/us-east-2/index.json> (2026-09-11) |
| NLB / ALB | $0.0225/h + $0.006 per NLCU-hour / + $0.008 per LCU-hour | same file |
| Public IPv4 address, in use or idle | $0.005/h each (the NAT gateway's EIP, every internet-facing LB address) | <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonVPC/current/us-east-2/index.json> (2026-09-17) |
| Interface VPC endpoint (ROSA's private-router endpoint) | $0.01/h + $0.01/GB | same file |
| VPC peering | no hourly charge | same file |
| NAT gateway | $0.045/h + $0.045/GB processed | <https://aws.amazon.com/vpc/pricing/> (2026-10-08). Uncertain: the page showed its default region, not Ohio. The two have historically matched (Ohio and N. Virginia); confirm in calculator.aws |
| EBS gp3 | $0.08/GB-month: a 300 GiB root volume is $0.0329 per node-hour, the 100 GiB monitoring volume $0.011 per cluster-hour | <https://aws.amazon.com/ebs/pricing/> (US East (Ohio)) |
| Data transfer | cross-AZ or via a public IPv4 address $0.01/GB each way; same-AZ over peering free; internet egress $0.09/GB (first 100 GB a month free) | <https://aws.amazon.com/ec2/pricing/on-demand/>, read through a page-summarizer extract: indicative |
| AWS Budgets | first two action-enabled budgets free each month, then $0.10/day each; data refreshes up to 3 times a day, 8-12 h apart | <https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/>, <https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html> |
| AWS Budgets forecast alerts | need "approximately 5 weeks of usage data"; until then a FORECASTED alert does not trigger. ACTUAL alerts are sent once per budget per period | <https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-best-practices.html> (checked 2026-10-13) |
| Cost Explorer API | $0.01 per request | <https://aws.amazon.com/aws-cost-management/aws-cost-explorer/pricing/> (2026-10-08) |
| Route 53 hosted zone | $0.50 per month; a zone deleted within 12 h of creation is not charged (queries to public zones still are) | <https://aws.amazon.com/route53/pricing/> (2026-10-08) |
| SNS email notifications (the required teardown alert) | first 1,000 a month free, then $2.00 per 100,000 | <https://aws.amazon.com/sns/pricing/> (2026-10-08) |

Unit costs derived from the table:

- Worker node, including the ROSA fee and its 300 GiB root volume:
  - m7i.xlarge: $0.4055/h ($0.2016 + $0.171 + $0.0329)
  - m5.2xlarge: $0.7589/h ($0.384 + $0.342 + $0.0329)
  - r7i.2xlarge: $0.9041/h ($0.5292 + $0.342 + $0.0329)
  - m7i.4xlarge: $1.5233/h ($0.8064 + $0.684 + $0.0329)
- Fixed per cluster, about $0.351/h:
  - cluster fee $0.25
  - NAT gateway $0.045 and its EIP $0.005
  - the interface endpoint $0.01
  - the default router LB with its address, about $0.03
  - monitoring EBS $0.011
- Per mesh member: 2 gateway LBs (ingress and east-west) at about $0.03/h each, so $0.06/h.
- Variable spend: NAT processing of image pulls, cross-cluster watches and xDS, and config-dump
  egress.
  - About $3-5 per window on Tier B.
  - Budgeted at $5 (core) and $6 (extended and worst case) on C, which runs longer and boots up to
    500 sidecars on mesh-a.
  - The east-west gateways are internet-facing LBs, so cross-cluster traffic bills as NAT
    processing ($0.045/GB) plus $0.01/GB, not as peering.

Uncertain or not metered here:

- CLB vs NLB for the gateways (±$0.0025/h either way; A0 records which).
- Whether ROSA fees round partial hours up. CLBs and NAT gateways do, so every recreated CLB costs
  at least about $0.03.
- ROSA charges arrive through AWS Marketplace metering and can post late.
- ACM, OSSM and GitOps subscriptions are not on the AWS bill.
- Route 53, Secrets Manager and S3 OIDC leftovers cost pennies, but the audit checks them.

Corrections to earlier figures:

- The 2026-10-12 sizing (hub 2× m5.2xlarge, members 2× m7i.xlarge, 3 clusters) costs $4.31/h
  all-in, not "about $3.5/hour".
- A 21-cluster run costs about $26.3/h only with 2× m7i.xlarge members. The June campaign's 8×
  m5.4xlarge spokes would cost about $248/h at these prices.

## 3. Tiers

All tiers run in a single AZ with the hub `cluster-001` on 2× m5.2xlarge, fixed worker counts
(`worker_autoscale_min = worker_autoscale_max`) and vendor-default LBs. Tier C is the plan of
record; B and A are the [fallbacks](#fallback-tiers-b-and-a).

| Tier | Topology | vCPU quota | $/h | Window | Total |
| --- | --- | --- | --- | --- | --- |
| **C, plan of record** | hub + 3 members: `<mesh-a-ctx>` on 3× r7i.2xlarge, b and c on 3× m7i.xlarge (istiod request 8Gi / limit 16Gi) | 64 | $8.25 | about 7.25 h core, at most 8.6 h extended; teardown starts by T0+7:45, auto-teardown at T0+8:15 | about $65 core, at most $77 extended, about $81 worst case |
| B, fallback | hub + 3 members on 3× m7i.xlarge (istiod limit 8Gi) | 52 | $6.75 | about 6.6 h core; teardown starts by T0+6:45, auto-teardown at T0+7:15 | about $48 core, at most $57 extended, about $60 worst case |
| A, fallback | hub + 2 members on 3× m7i.xlarge (istiod limit 8Gi) | 40 | $5.12 | about 5.7 h core (no partial-mesh phase); auto-teardown at T0+5:45 | about $33 core, at most about $38 |
| D, reference only | hub + 20 members: 2× m7i.xlarge, or 8× m5.4xlarge as in June | 176 / about 2600 | $26.3 / about $248 | 6-8 h | about $160-210 / $1.5-2k |

Tier C per hour, in $ (sums to $8.2471; the docs round it to $8.25):

| Item | hub `cluster-001` | `<mesh-a-ctx>` | `<mesh-b-ctx>` | `<mesh-c-ctx>` | Total |
| --- | --- | --- | --- | --- | --- |
| Workers | 2× m5.2xlarge (16 vCPU) | 3× r7i.2xlarge (24 vCPU) | 3× m7i.xlarge (12 vCPU) | 3× m7i.xlarge (12 vCPU) | 11 nodes, 64 vCPU |
| Cluster fee | 0.2500 | 0.2500 | 0.2500 | 0.2500 | 1.0000 |
| EC2 | 0.7680 | 1.5876 | 0.6048 | 0.6048 | 3.5652 |
| ROSA worker fee ($0.04275 per vCPU-hour) | 0.6840 | 1.0260 | 0.5130 | 0.5130 | 2.7360 |
| EBS (300 GiB root per node, 100 GiB monitoring) | 0.0768 | 0.1097 | 0.1097 | 0.1097 | 0.4059 |
| Network (NAT, its EIP, endpoint, router LB; on members also 2 gateway LBs) | 0.0900 | 0.1500 | 0.1500 | 0.1500 | 0.5400 |
| **Total** | 1.8688 | 3.1233 | 1.6275 | 1.6275 | **8.2471** |

Tier C totals:

- **Core:** 7.25 h × $8.2471 = $59.79, plus $5 variable, about **$65**. The core teardown starts at
  T0+6:20 and ends at T0+7:15.
- **Extended:** every optional block runs (A4 20 min, R3's 250 cell 20 min, R2 42 min; +82 min, so
  the teardown starts by T0+7:42). That is 8.62 h × $8.2471 = $71.06, plus $6, at most about
  **$77**. The checkpoints usually admit only two of the three (+62 min): 8.28 h, about $74.
- **Worst case:** the auto-teardown fires at T0+8:15 and billing ends about 45 min later. That is
  9.0 h × $8.2471 = $74.22, plus $6 variable and $1 of small items (partial hours, Route 53, `ce`
  calls), about **$81**.
  - Headroom to the $100 cap is $18.78, about 2 h 15 min at the full rate. If the auto-teardown
    fails, or never fires, billing must end by about T0+11:15: (100 − 7) / 8.2471 = 11.28 h.
  - The SNS email and the off-host phone alarm at T0+9:15 catch it. A manual `003 --now` takes
    about 45 min, so T0+10:30 is the last start: 11.25 h × $8.2471 = $92.78, plus $7, is $99.78.
    At the alarm itself the meter reads about $83 (9.25 h × $8.2471 = $76.29, plus $7).
  - The plan's first Tier C estimate (about 7 h, $63) came before the two smoke steps, which add
    25 min (P3's 10, S1's 15).

Members b and c need 3 workers, not 2: istiod's 2 CPU / 8Gi request plus about 5 vCPU of ROSA,
monitoring and ACM add-on pods leave only about 2 vCPU free on 2 nodes.

mesh-a needs 3 nodes because of pods, not CPU. P4a's 500 sidecars at 20m request 10 vCPU of its
24, but they need more than the 2 × 250 pods that OpenShift's default per-node limit allows on two
nodes. P2 reads the real figure.

- **C covers:**
  - task 3 A0-A4 with the 3-member partial-mesh pattern: `<mesh-c-ctx>` is the broken cluster and
    a↔b the control pair;
  - the directional prediction;
  - the task 4 smoke with 2 remotes;
  - task 6 in pods mode at 150 and 250 services × 2 on mesh-a, plus 60 × 2 on a and b;
  - task 1 R1 with its wide cells at 2000-4000 namespaces (istiod up to 16Gi on mesh-a), R2, and
    R3 at 40 and 250 namespaces;
  - a clean split: mutations only on c, measurements on a and b.
- **B** keeps all of that except mesh-a's headroom. Task 6 stays at 25 and 60 services × 2 on a and
  b, R1's wide cells at 2000-4000 become SKIPPED_MEM_GUARD rows, and R3 is only the 40-namespace
  cell.
- **A** cannot produce the 3-member partial-mesh pattern: with 2 members, every cross-cluster pair
  includes the broken cluster, so there is no healthy control pair.
- **D** is the only way to see task 3 at the original 19-remote scale, or to retry task 4 with 19
  remote watches. It is out of budget for a spend-capped owner run.

### b and c under the 16Gi limit

The istiod override is one mesh-wide value (`spoke-ossm-appset`), so b and c also get the 16Gi limit, on 16 GiB m7i.xlarge nodes. There the limit is nominal:

- istiod sets `GOMEMLIMIT` to 90% of `limits.memory` (`charts/spoke-ossm/values.yaml`). That is
  14.4 GiB, more than a 16 GiB node can give once the system reserve and the other pods are
  counted. Go's soft memory limit therefore never makes the GC work harder before the node runs
  short.
- With requests below limits, istiod is a Burstable pod. Above its 8Gi request, it is the first pod
  the kubelet evicts under node memory pressure, or the kernel OOM-kills it, well before 16Gi. Either
  shows up as an istiod restart: evidence for task 4, a lost cell for task 1.
- Task 1's memory guard projects against 70% of the container limit (its design's
  `CONTROLPLANE_MEM_STOP_PCT=70`): 11.2Gi here, on every member. That is right for mesh-a and too
  high for b and c.

So on b and c, the 8Gi request is the ceiling, enforced by hand during P6 (see P6). On b and c the
istiods only ingest mesh-a's Services through remote discovery and serve no test proxies, so their
memory is expected to grow far more slowly than mesh-a's.

### Fallback tiers B and A

Decide before `terraform apply`: worker types cannot change mid-window. Everything not listed
below is the same as in Tier C. The checkpoint offsets for B follow from its shorter P4 and its
optional R3.

| | C (plan) | B (fallback) | A (fallback) |
| --- | --- | --- | --- |
| When | — | r7i.2xlarge not offered, or the 64-vCPU quota not granted by the end of P0 | 52 vCPUs not available either |
| `terraform.tfvars` | `cluster_count = 4`, `cluster-002` override 3× r7i.2xlarge | `cluster_count = 4`, no `cluster-002` override | `cluster_count = 3`, no `cluster-002` override |
| istiod limit in `rosa.tfvars` | 4 CPU / 16Gi | 4 CPU / 8Gi | 4 CPU / 8Gi |
| vCPU quota (below 100, `rosa verify quota` flags it: [P0](#4-prerequisites-p0-the-day-before-no-cluster-spend)) | 64 (request at most 72) | 52 (at most 60) | 40 (at most 48) |
| `003-auto-teardown.sh --arm --fire-after` | `8h15m` (the default) | `7h15m` | `5h45m` |
| `rosa-warn` offset from T0 | 26100 s (T0+7:15) | 22500 s (T0+6:15) | 17100 s (T0+4:45) |
| Teardown starts by; phone alarms | T0+7:45; T0+7:15 and T0+7:45 | T0+6:45; T0+6:15 and T0+6:45 | T0+5:15; T0+4:45 and T0+5:15 |
| Off-host phone alarm (teardown check) | T0+9:15 | T0+8:15 | T0+6:45 |
| Last manual `003 --now` start under $100 | T0+10:30: (100 − 7) / 8.2471 = 11.28 h, less 45 min | T0+13:10: (100 − 6) / 6.7513 = 13.92 h, less 45 min | T0+17:45: (100 − 5) / 5.1238 = 18.54 h, less 45 min |
| Spend meter `rate` | 8.25 | 6.75 | 5.12 |
| P4 task 6 | P4a (a: 150, 250) then P4b (a+b: 60) | a+b at 25 and 60 (4 cells, 45 min) | a+b at 25 and 60 |
| P5 task 3 | partial mesh, mutations on c | same | A1-A4 on 2 members; mutations on b; no control pair |
| P6 task 1 | S1, R3 at 40 (core) and 250, R1, R2 | S1, R3 at 40 only (optional), R1 (wide 2000-4000 skipped by the guard), R2 | S1 and R1; R3 at 40 only if A4 is skipped; R2 does not fit |
| P7 task 4 | 2 remotes | 2 remotes | 1 remote (`--remote-contexts <mesh-b-ctx>`) |
| Core / extended / worst | $65 / $77 / $81 | $48 / $57 / $60 | $33 / $36 / $38 |

B's numbers with both smoke steps:

- Core:
  - Timeline: P3 ends 1:25, P4 runs 1:25-2:10, P5 2:10-3:25, P6 3:25-5:15 (R0 1 + S1 15 + R1 90
    + report 4 = 110 min), P7 to 5:30, P8 to 5:40, P9 to 6:35.
  - Cost: 6.58 h × $6.7513 = $44.45, plus $4, about $48.
- Extended: capped by the T0+6:45 teardown start, so billing ends by 7:40. That is 7.67 h ×
  $6.7513 = $51.76, plus $5, about $57.
- Worst case: 8.0 h × $6.7513 = $54.01, plus $5 and $1, about $60.

B's checkpoints:

| By | Check | If missed |
| --- | --- | --- |
| T0+1:15 | mesh verified | fix until T0+1:45, then tear down |
| T0+1:25 | P3 task 4 smoke | no-go: diagnostics off |
| T0+2:20 | task 6 done | cut the 60-service cells |
| T0+3:10 | A1-A3 done | skip A4 |
| T0+3:30 | P6 started | skip R3 |
| T0+3:40 | recovery gate passed | abort P5 into the gate |
| T0+5:25 | R1 report done | skip R2 |
| T0+6:00 | P7 started | skip P7 |
| T0+6:45 | teardown started | auto-teardown at T0+7:15 |
| T0+8:15 | off-host phone alarm: teardown confirmed done | as [If the T0+9:15 alarm rings](#if-the-t0915-alarm-rings); last manual start T0+13:10 |

A's numbers: 5.72 h × $5.1238 = $29.31, plus $4, about $33. That is round 2's 5.3 h plus the
25 min of smoke steps. Extended: one 15-20 min block fits (A4 or R3 at 40), with the teardown
started by 5:15 and billing ending by 6:10. That is 6.17 h × $5.1238 = $31.60, plus $4,
about $36. Worst case: 6.5 h × $5.1238 = $33.30, plus $4 and $1, about $38.

## 4. Prerequisites (P0, the day before, no cluster spend)

- [ ] **Fallback conditions checked** (owner decisions above):
  - `rosa list instance-types --region us-east-2` offers r7i.2xlarge, m7i.xlarge and m5.2xlarge;
  - the vCPU quota reads at least 64.
  - If either fails by the end of P0, switch to Tier B
    ([Fallback tiers](#fallback-tiers-b-and-a)) and change the tfvars, timers and meter rate with it.
- [ ] **One pinned commit** containing the task 1 and task 4 PRs, with `tests/lib/verify.sh` green.
  - Run both PRs' own bats and dry runs in the window worktree. Neither was lab-validated, so P3 and
    S1 are their first live runs.
  - Without task 1, drop P6. That saves about 125 min, $17: the existing fresh mode cannot reach
    thousands of namespaces in time.
  - Without task 4, skip P3's smoke and P7 (about 25 min, $3), and capture by hand if istiod
    restarts.
- [ ] **Window worktree** at that commit, never a detached main checkout (README, Re-run). Its
      `terraform/platform` holds no lab state, so nothing there can touch the lab.
- [ ] `helm lint` / `helm template` on the touched charts; `terraform fmt -check -recursive` and
      `terraform validate` in both roots.
- [ ] `rosa list versions --hosted-cp` offers 4.21.11.
- [ ] **Quotas, requested a day early.** Increases can sit pending for hours.
  - On-Demand Standard vCPUs (`L-1216C47A`), which covers the R family: at least 64.
    - Check with `aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A`.
    - When raising it, ask for 64-72. The quota then caps a runaway at the need plus 8 vCPUs.
    - A quota already far above that caps nothing and cannot be lowered; the fixed worker pools
      are the real cap.
    - **A quota capped below 100 fails one check on purpose.** `001-preflight.sh` runs
      `rosa verify quota`, which wants 100 vCPUs (sized for five multi-AZ classic clusters), and
      exits 1 with "request an increase". Do not request one. Read the other lines instead: go
      ahead only if the vCPU line (`quota code L-1216C47A`) is the only one flagged. This filter
      drops exactly that line and its two `ERR:` headers, so it prints nothing then, and prints any
      other flagged quota, error or login problem:

      ```bash
      rosa verify quota --region us-east-2 2>&1 |
        grep -vE '^(INFO|WARN): |L-1216C47A|Insufficient AWS quotas|following service quota codes'
      ```

      Its other thresholds are the AWS defaults (Classic LBs 20; EIPs, VPCs and internet gateways
      5), so an account at its defaults or above passes them.
  - Classic LBs per region: at least 10.
    `aws service-quotas list-service-quotas --service-code elasticloadbalancing --query "Quotas[?contains(QuotaName, 'Classic')]"`.
  - VPCs and internet gateways per region: default 5, and the default VPC counts; C needs 4.
  - Elastic IPs: default 5; C's 4 NAT gateways take 4.
  - NAT gateways per AZ, gateway endpoints and IAM roles.
  - `service_quotas.tf` requests `cluster_count + 2` for the network and IAM quotas. Apply only
    those resources now:
    `terraform -chdir=terraform/rosa-hcp apply -target=aws_servicequotas_service_quota.vpc -target=aws_servicequotas_service_quota.internet_gateway -target=aws_servicequotas_service_quota.eip -target=aws_servicequotas_service_quota.nat_per_az -target=aws_servicequotas_service_quota.gateway_vpc_endpoint -target=aws_servicequotas_service_quota.iam_roles`.
    Then check `aws service-quotas list-requested-service-quota-change-history --service-code vpc`
    (and `--service-code ec2`).
- [ ] `terraform/rosa-hcp/terraform.tfvars`:
  - `cluster_count = 4`;
  - `cluster_defaults = { compute_machine_type = "m7i.xlarge", replicas = 3, worker_autoscale_min = 3, worker_autoscale_max = 3 }`;
  - `cluster_overrides = { "cluster-001" = { compute_machine_type = "m5.2xlarge", replicas = 2, worker_autoscale_min = 2, worker_autoscale_max = 2 }, "cluster-002" = { compute_machine_type = "r7i.2xlarge", replicas = 3, worker_autoscale_min = 3, worker_autoscale_max = 3 } }`;
  - `common_tags = { environment = "scale-test", purpose = "rosa-window", expires = "<window-date>" }`.
  - The worker pools always have autoscaling enabled with min = max. Confirm in the plan output that
    OCM accepts it, and that `cluster-002` gets r7i.2xlarge for both the cluster and its pool.
- [ ] `terraform/platform/rosa.tfvars`:
  - `cluster_provider = "rosa"`;
  - `gitops_app_repo_revision = "<window-sha>"`;
  - the small-hub `argocd_config_values` from the example;
  - in `gitops_app_overrides`, under `"spoke-ossm-appset"` → `values.template.source.helm.valuesObject`:
    `pilot = { replicaCount = 1, resources = { requests = { cpu = "2", memory = "8Gi" }, limits = { cpu = "4", memory = "16Gi" } } }`
    and `proxy = { resources = { requests = { cpu = "20m", memory = "64Mi" } } }`.
- [ ] Gitignored run configs `tests/{controlplane,dataplane,churn}/configs/rosa-*.local.env`.
  - Copy them from each suite's `smoke.env`; task 1's `rosa-ns-scaling.local.env` comes from its
    `ns-scaling-*.env` example.
  - Fill `SETUP_CONTEXTS` after apply.
  - Task 1's config lists all three members, because its memory guard samples every member's
    istiod and gateways.
  - Keep `ISTIOD_DIAG_ENABLED=1` (the default) until P3's go/no-go.
- [ ] **SNS alert topic (required).** It carries the auto-teardown's result to the phone, and
      `003-auto-teardown.sh --arm` refuses to arm without a confirmed subscription:

      ```bash
      aws sns create-topic --name rosa-window --region us-east-2     # prints the <arn>
      aws sns subscribe --topic-arn <arn> --protocol email --notification-endpoint <owner-email>
      # click the link in the confirmation email (on the phone), then:
      aws sns get-topic-attributes --topic-arn <arn> --query Attributes.SubscriptionsConfirmed   # "1"
      ```

      Keep the `<arn>` (later in `~/.rosa-window/status.md`): the dry run below and T0's `--arm`
      take it.
- [ ] **Dry runs** that need no cluster:
  - task 1 R0 (P6);
  - the P3, P4a and P4b commands with `--dry-run`;
  - the churn 001/002 commands with `--dry-run`;
  - `terraform/rosa-hcp/scripts/003-auto-teardown.sh --dry-run --sns-topic-arn <arn>` (tools on
    PATH, AWS credentials, `rosa token --refresh`, tfvars, the confirmed SNS subscription).
  - P3's library load for the task 4 smoke, which prints both function names. Without
    `reach.sh` the capture writes nothing at all, and the smoke would pass on no evidence. If the
    merged lib's "Requires" line names more libs, add them here and in P3.

    ```bash
    ( set -euo pipefail; source config/versions.env; source tests/lib/common.sh
      source tests/lib/preamble.sh; source tests/lib/reach.sh; source tests/lib/istiod-diag.sh
      declare -F reach_sanitize istiod_diag_capture )
    ```

- [ ] **Budgets** ([section 7](#7-spend-guardrails-checkpoints-cut-list)).
- [ ] **Operator host:**
  - WSL with systemd enabled and `loginctl enable-linger`;
  - the laptop plugged in with sleep disabled;
  - Windows Update paused for the day (a reboot drops the transient timers);
  - phone alarms set for T0+7:15 and T0+7:45, and a third one at T0+9:15: the off-host check that
    the auto-teardown worked ([If the T0+9:15 alarm rings](#if-the-t0915-alarm-rings)). Set them on
    the phone, not the laptop: the T0+9:15 one must ring even if the operator host is dead;
  - `rosa whoami` works.
- [ ] **WSL keeps running without a terminal.** systemd units do not keep a WSL distro alive: it
      stops about 15 s after the last `wsl.exe` session closes (linger does not help), and the
      timers stop with it, silently. Close the terminal by accident and the $81 worst case no longer
      holds. Put this in `%UserProfile%\.wslconfig`, then run `wsl --shutdown` from Windows and
      reopen:

      ```ini
      [general]
      instanceIdleTimeout=-1
      [wsl2]
      vmIdleTimeout=-1
      ```

      Check that it took effect: close every terminal, wait a minute, reopen, and run
      `ps -o etimes= -p 1` (seconds since the distro's systemd started). It must be above 60.
      `003-auto-teardown.sh --dry-run` and `--arm` check the `[general]` key on WSL and fail
      without it.
- [ ] `~/.rosa-window/` created, with `status.md` started. Write into it the expected month totals
      for the budget alerts ([section 7](#7-spend-guardrails-checkpoints-cut-list)).

## 5. Run order (Tier C)

| Phase | Offset | Min | Clusters | Suite | Mutation | Expected | Skip or abort |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P1 provision | 0:00 | 45 | all | terraform | creates | 4 clusters ready, platform applied | not fixable by 1:45 → teardown |
| P2 verify, A0 | 0:45 | 15 | all | checks | none | 3 gates `Ready ... ca=shared`; istiod 1 pod at 8Gi/16Gi; at least 520 free pod slots on mesh-a; LB inventory saved | mesh not verified by 1:15 → fix until 1:45, else teardown (about $15 by then, $23 with the teardown) |
| P3 baseline, task 4 smoke | 1:00 | 15 + 10 | a, b, c | dataplane; istiod-diag | none | REACHABLE 10/10 to both remotes; no istiod-diag dir from the sweep; manual capture clean | task 4 no-go → `ISTIOD_DIAG_ENABLED=0` from here on |
| P4 task 6 | 1:25 | 70 | P4a: a (b and c ingest it); P4b: a, b (c idle) | controlplane | none | 6 cells, istiod not restarted, no test namespace left | P4a not done by 2:20 → skip P4b; stop P4 at 2:55 whatever is left |
| P5 task 3 | 2:35 | 75 (+20 A4) | gateway Services on c only | dataplane, 006 pause | gateway-svc | a↔b REACHABLE throughout; recovery timeline per case; recovery gate passed | A4 only if A1-A3 done by 3:35; gate passed by 4:05 |
| P6 task 1 | 3:50 | 125 (+20 R3 at 250, +42 R2) | a; b and c ingest it | controlplane | none (test namespaces, never deleted) | S1 go; a row per cell; wide cells at 2000-4000 measured | see the P6 rules below |
| P7 task 4 | 5:55 | 15 | a, b, c | churn | istiod (b) | iteration 2 POISONED_RESTART or TIMEOUT_REMOTE; capture `index.tsv` with `replaced_gone`/`deleted` and `new_pod` | start by 7:00 or skip |
| P8 evidence | 6:10 | 10 | — | — | none | results backed up, re-captures done | — |
| P9 teardown | 6:20 | 55 | all | terraform | destroys | audit empty | starts by 7:45 at the latest |

Offsets are core: 45 + 15 + 25 + 70 + 75 + 125 + 15 + 10 + 55 = 435 min = 7.25 h. Each optional
block (A4, R3 at 250, R2) shifts the later phases by its length.

P6 skip and abort rules:

- An S1 no-go ends P6.
- R3's 250 cell runs only if P6 starts by 4:00.
- R2 runs only if the R1 report is done by 6:25.
- istiod above 8Gi on b or c → no larger step.
- More than about 500 Terminating namespaces on any member → billing-first teardown now.

**P1 provision.** The commands are in README, Re-run:

1. Write T0 and arm the timers (`--fire-after 8h15m` is the script's default).
2. Apply rosa-hcp and save `by_cluster.json`.
3. Apply the platform.

The 4 clusters build in parallel in about 20-25 min; the platform takes about 15-20 min.

**P2 verify and A0 inventory** (read-only). `export KUBECONFIG=$PWD/terraform/rosa-hcp/kubeconfig`, then:

```bash
rosa list clusters                                                  # 4 ready
oc --context <acm-hub-ctx> -n openshift-gitops get applications.argoproj.io   # all Synced/Healthy
for c in <mesh-a-ctx> <mesh-b-ctx> <mesh-c-ctx>; do
  oc --context "$c" exec -n mesh-wiring-verify deploy/mesh-wiring-verify -- sh /opt/check/readiness.sh
  oc --context "$c" -n istio-system get pod -l app=istiod -o jsonpath='{range .items[*]}{.metadata.name} {.spec.containers[0].resources.requests.memory}/{.spec.containers[0].resources.limits.memory}{"\n"}{end}'   # 1 pod, 8Gi/16Gi
  oc --context "$c" describe nodes | grep -A6 'Allocated resources'   # free CPU/memory baseline
done
# free pod slots on mesh-a: P4a's 250-service cells need about 520
oc --context <mesh-a-ctx> get nodes -o jsonpath='{range .items[*]}{.status.allocatable.pods}{"\n"}{end}' |
  awk '{ s += $1 } END { print "allocatable pods:", s }'
oc --context <mesh-a-ctx> get pods -A --no-headers --field-selector=status.phase=Running | wc -l
mkdir -p tests/dataplane/results/rosa-lb/a0
for c in <mesh-a-ctx> <mesh-b-ctx> <mesh-c-ctx>; do
  oc --context "$c" -n istio-system get svc -o wide >"tests/dataplane/results/rosa-lb/a0/svc-$c.txt"
  oc --context "$c" -n istio-system get svc istio-eastwestgateway -o jsonpath='{.spec.externalTrafficPolicy}{"\n"}'
done
aws elb describe-load-balancers --query "LoadBalancerDescriptions[?VPCId=='<vpc-id>'].[LoadBalancerName,DNSName]"
aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='<vpc-id>'].[LoadBalancerName,Type,DNSName]"
aws elb describe-instance-health --load-balancer-name <lb>        # or: aws elbv2 describe-target-health --target-group-arn <tg>
dig +short <ew-lb-host>                                           # repeat in P8 to catch CLB IP rotation
oc --context <mesh-a-ctx> -n istio-system exec deploy/istiod -- pilot-discovery request GET /debug/networkz
```

The VPC ids are in `~/.rosa-window/by_cluster.json`. mesh-verify must answer through each member's
ingress hostname. If mesh-a has fewer than 520 free pod slots, P4a's top cell becomes the largest
that fits, (free slots − 20) / 2 services; 001's capacity preflight refuses anything bigger anyway.

**P3 AWS dataplane baseline, then the task 4 smoke** (all 3 members, no mutation):

```bash
./tests/dataplane/003-run-sweep.sh --contexts <mesh-a-ctx>,<mesh-b-ctx>,<mesh-c-ctx> --mesh-sizes 3 \
  --on-unreachable warn --output-dir tests/dataplane/results/rosa-baseline
./tests/dataplane/004-report-results.sh --results-dir tests/dataplane/results/rosa-baseline/sweep-<RUN_ID> \
  --format markdown --fail-on-unreachable
```

The sweep uses the default QPS levels 10,100,500,1000 at 30 s each and cleans up after itself;
confirm `oc get ns dataplane-test` is gone on all members.

The task 4 smoke is task 4's first live run (about 10 min, read-only; only if its PR is in the
pinned commit). It runs before P4-P6 lean on its passive capture. It makes two captures on
`<mesh-b-ctx>`:

- **quiet:** no pod set, as for a run with no restart. Expect one `no_change` row and no evidence
  (a restart during bootstrap changes that; see Go).
- **forced:** a pre-window pod set that names a pod that does not exist. The lib then sees that pod
  as `replaced_gone` and the real istiod as `new_pod`, so the evidence path runs too: the pod list,
  events, ReplicaSets, node reads and the new pod's startup log, under the lib's bounds. All of it
  is reads.

```bash
find tests/dataplane/results/rosa-baseline -path '*istiod-diag-*' | head    # expect nothing: no restart, no capture
oc --context <mesh-b-ctx> -n istio-system get pod -l app=istiod            # note RESTARTS
d=tests/churn/results/rosa-diag-smoke
mkdir -p "$d" && echo istiod-smoke-absent >"$d/pre-podset.txt"
( set -euo pipefail; source config/versions.env; source tests/lib/common.sh
  source tests/lib/preamble.sh; source tests/lib/reach.sh; source tests/lib/istiod-diag.sh
  declare -F reach_sanitize >/dev/null || { echo "reach.sh not loaded: the capture would write nothing" >&2; exit 1; }
  istiod_diag_capture "$d/quiet" manual <mesh-b-ctx> unknown '' '' oc
  istiod_diag_capture "$d/forced" manual <mesh-b-ctx> podset_changed "$d/pre-podset.txt" '' oc )
for k in quiet forced; do
  awk -F'\t' -v k="$k" '!/^#/ && $1 != "captured_at" { print k ": pod=" $5 " change=" $6 " cause=" $7 " evidence=" $22 }' "$d/$k/index.tsv"
done
# Redaction. The context and evidence columns of index.tsv hold the context name by design (the
# lib's header), so the context-name check reads summary.md, README.md and the note column only.
grep -rlE 'ip-[0-9]+-[0-9]+-[0-9]+-[0-9]+|([0-9]{1,3}\.){3}[0-9]{1,3}' \
  --include=index.tsv --include=summary.md --include=README.md "$d"          # expect no file
grep -rlE 'cluster-00[0-9]' --include=summary.md --include=README.md "$d"    # expect no file
awk -F'\t' '!/^#/ && $1 != "captured_at" { print $23 }' "$d"/quiet/index.tsv "$d"/forced/index.tsv |
  grep -E 'cluster-00[0-9]'                                                  # expect nothing
ls -A "$d"/forced/0*/                       # summary.md pods.json events.tsv deploy-rs.json node-1*.json/tsv <pod>.startup.log.gz
zcat "$d"/forced/0*/*.startup.log.gz | wc -c   # at most about 262144: the lib's bound for a new pod's log
du -sh "$d"
```

- **Go:** all of these hold.
  - The baseline sweep created no `istiod-diag-*` directory.
  - `quiet`: exactly one row, `change=no_change` (cause `no_restart_found`, evidence `-`). If
    RESTARTS above was not 0 (istiod restarted during bootstrap, say before `cacerts` arrived),
    the one row is `restarted_untimed` with an evidence folder instead; that is a go too, and its
    `<pod>.previous.log.gz` holds at most 1048576 bytes (`ISTIOD_DIAG_LOG_BYTES`).
  - `forced`: exactly two rows, `istiod-smoke-absent` with `change=replaced_gone` and the real pod
    with `change=new_pod`. Both name the same evidence folder (`001-manual-...`), which holds the
    files listed above and no `*.unavailable` file.
  - No row anywhere is `capture_failed`, `budget_exhausted` or `skipped_deadline`.
  - The three redaction checks print nothing.
  - The startup log is at most about 262144 bytes, and the whole directory is under 2 MiB.
- **No-go:**
  - Set `ISTIOD_DIAG_ENABLED=0` in every `rosa-*.local.env` run config for the rest of the window,
    so a broken hook cannot disturb P4-P6.
  - P7 still runs: its recovery timing does not depend on the capture.
  - In P8, collect `oc logs --previous` and the istio-system events by hand.

**P4 task 6, VS/DR load in pods mode.**

- **P4a** measures mesh-a alone at 150 and 250 services × 2 replicas: 300 and 500 sidecars. At the
  20m override that is 6 and 10 vCPU of requests, so pods per node, not CPU, is the bound. b and c
  are in the mesh and ingest mesh-a's Services through remote discovery, but carry no test pods.
- **P4b** runs the largest size b can hold, 60 × 2 per member, across a and b (mesh size 2), for
  the cross-cluster view; c is idle.
- P4a goes first because it is the reason for Tier C.
- Each cell takes about 11 min (setup, two 60 s settles, the scrapes, config dumps, namespace
  delete), as in Tier B's 25- and 60-service cells, plus a few minutes at 500 pods.

```bash
# P4a, about 45 min: 4 cells
./tests/controlplane/003-run-sweep.sh --contexts <mesh-a-ctx> --mesh-sizes 1 \
  --service-counts 150,250 --replica-counts 2 --namespace-counts 1 --sidecar-scopings namespace \
  --traffic-configs none,vsdr --vsdr-every 1 --vsdr-subsets 2 --config-dump-samples 2 --settle 60 \
  --output-dir tests/controlplane/results/rosa-task6
# P4b, about 25 min: 2 cells, only if P4a is done by T0+2:20
./tests/controlplane/003-run-sweep.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> --mesh-sizes 2 \
  --service-counts 60 --replica-counts 2 --namespace-counts 1 --sidecar-scopings namespace \
  --traffic-configs none,vsdr --vsdr-every 1 --vsdr-subsets 2 --config-dump-samples 2 --settle 60 \
  --output-dir tests/controlplane/results/rosa-task6
# each sweep has its own sweep-<RUN_ID>/ directory: report both
./tests/controlplane/004-report-results.sh --results-dir tests/controlplane/results/rosa-task6/sweep-<RUN_ID> --format markdown
./tests/controlplane/004-report-results.sh --results-dir tests/controlplane/results/rosa-task6/sweep-<RUN_ID> --format json
```

Gate after each sweep: no `controlplane-test` namespace left, and istiod not restarted. P4 stops
at T0+2:55 whatever is left: interrupt the sweep, run
`./tests/controlplane/005-cleanup.sh --contexts <mesh-a-ctx>,<mesh-b-ctx>`, and start P5.

**P5 task 3, load-balancer experiments.** Gateway Service mutations happen on `<mesh-c-ctx>` only.
Dataplane 001 takes one `--source-context`, so a probe from b or c needs its own 001/002/005
cycle, about 4 min each; the 75 min include those.

```bash
./tests/dataplane/001-setup-dataplane-test.sh --source-context <src> --remote-contexts <r1>,<r2>
./tests/dataplane/002-run-latency-probe.sh --source-context <src> --remote-contexts <r1>,<r2> --mesh-size 3 \
  --qps-levels 10 --duration 10 --on-unreachable warn --output-dir tests/dataplane/results/rosa-lb
./tests/dataplane/005-cleanup.sh --contexts <src>,<r1>,<r2>
```

During a recovery, poll from the client pod with a timestamped fortio request every 5 s.

- **A1, Service recreated** (the lab's E2 analog):
  - Run `oc --context <mesh-c-ctx> -n istio-system delete svc istio-eastwestgateway` and let Argo
    CD recreate it.
  - Record when:
    - the Service is back;
    - the hostname is assigned;
    - DNS resolves;
    - the instances are InService;
    - `networkz` is updated on a and b;
    - a→c and b→c are reachable again.
  - Restart no gateway pod. a↔b stays REACHABLE throughout.
- **A2, provisioned late** (the quota-late analog). Check the ApplicationSet with `--status` first.
  The pause is a deny window on its AppProject, so record every Application it covers:

  ```bash
  tests/tuning/006-gitops-pause.sh --gitops-context <acm-hub-ctx> --appset spoke-east-west-gateway --status
  tests/tuning/006-gitops-pause.sh --gitops-context <acm-hub-ctx> --appset spoke-east-west-gateway \
    --state-file tests/dataplane/results/rosa-lb/gitops-pause-ew.json --pause
  ```

  - Save the Service YAML, delete the Service, and re-apply it with
    `service.beta.kubernetes.io/aws-load-balancer-subnets: subnet-00000000000000000`. It should stay
    `<pending>` with a cloud-provider error event.
  - Hold while probing from a and from c (about 10 min with the extra source cycle). Expected: a↔b
    OK, a→c FAIL, c→a and c→b OK.
  - Remove the annotation and time the recovery without restarting any pod.
  - If the annotation is ignored, flip `spec.type` to ClusterIP and back instead.
- **A3, gateway churn behind a live LB**:
  - Run `oc --context <mesh-c-ctx> -n istio-system rollout restart deploy/istio-eastwestgateway`,
    then scale 1 → 3 → 1.
  - The chart ships an HPA, so scale through its min/max (still under the pause) and record the
    original values.
  - Watch `describe-instance-health` and the probes. This matters most if
    `externalTrafficPolicy` is `Local`.
- **A4, NLB (optional, +20 min)**: while still paused, recreate the Service with
  `service.beta.kubernetes.io/aws-load-balancer-type: nlb`, repeat A1 and A3, and read
  `aws elbv2 describe-target-health`.
- **Recovery gate** (10 min). All of these must hold:
  - `006-gitops-pause.sh --resume --state-file tests/dataplane/results/rosa-lb/gitops-pause-ew.json`
    has run;
  - every Application is Synced/Healthy, and the Service and HPA are back to the chart spec;
  - all 3 gates report `ca=shared`;
  - a final probe from every source is all REACHABLE;
  - `005-cleanup.sh` has run on all 3 members;
  - there are exactly 2 gateway LBs per member, with no orphan CLB billing hourly.

Direct edits of these GitOps-owned objects are transient fault injection under the recorded pause.
They are never a fix.

**P6 task 1, namespace scaling** (only if its PR is in the pinned commit).

- Measurement runs on `<mesh-a-ctx>`; the istiods on b and c ingest everything through remote
  discovery.
- It leaves thousands of namespaces, so it runs after everything cross-cluster.
- This is task 1's first live run. Its flags come from its design, so check them against the merged
  `--help` in R0. Nothing after S1 runs without S1's go.

```bash
# R0, about 1 min: plan, object and pod counts, flag check
./tests/controlplane/003-run-sweep.sh --config tests/controlplane/configs/rosa-ns-scaling.local.env \
  --contexts <mesh-a-ctx> --mesh-sizes 1 --dry-run
# S1 smoke, about 15 min with its report: every growth code path once, at small N
./tests/controlplane/003-run-sweep.sh --contexts <mesh-a-ctx> --mesh-sizes 1 \
  --services-per-namespace 1 --namespace-counts 20,50 --sidecar-scopings namespace,wide \
  --workload-mode config-only --measurement-pods 2 --config-dump-samples 1 \
  --outside-namespaces 20 --outside-modes unlabeled,labeled --settle 30 --probe-settle 30 \
  --output-dir tests/controlplane/results/rosa-task1-smoke
./tests/controlplane/004-report-results.sh --results-dir tests/controlplane/results/rosa-task1-smoke/sweep-<RUN_ID> --format markdown
awk -F'\t' '!/^#/ { print FILENAME ": " NF " fields"; nextfile }' tests/controlplane/results/rosa-task1-smoke/sweep-<RUN_ID>/*.tsv
./tests/controlplane/005-cleanup.sh --contexts <mesh-a-ctx> --undiscover --no-delete    # retire S1's series
```

S1 is a go only if all of these hold:

1. 003 exits 0, with a row for every planned cell. No row is GROW_FAILED, SWITCH_FAILED or
   PROBE_FAILED, and `istiod_restarted` is 0 in every row.
2. The results TSV's header row has 62 fields.
3. The markdown report has the namespace-scaling section with the raw points.
4. `ns-lifecycle-<RUN_ID>.tsv` records objects/s and namespaces/s. R1's object count (from R0)
   divided by the measured objects/s comes to under 25 min of apply.
5. No API 429 is recorded.
6. The memory guard logged a projection for istiod and for the gateways on all three members.

On a no-go:

- Failing check 1, 2, 3 or 6 ends P6. S1's results are the record, and the window moves to P7,
  which saves about 110 min, $15.
- Failing only check 4 or 5: run R1 without its 4000-namespace step.

```bash
# R3 first, while the namespace deletion queue is empty (its fresh cells delete theirs and wait):
#   40 namespaces is core (about 15 min); add 250 (about 20 min) only if P6 started by T0+4:00.
#   One pod per Service, so 40 and 250 sidecars; R0 confirms the merged 003 takes --replica-counts here.
./tests/controlplane/003-run-sweep.sh --contexts <mesh-a-ctx> --mesh-sizes 1 --growth fresh \
  --services-per-namespace 1 --namespace-counts 40,250 --replica-counts 1 \
  --sidecar-scopings namespace --workload-mode pods
# R1, about 90 min
CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S=120 ./tests/controlplane/003-run-sweep.sh --contexts <mesh-a-ctx> \
  --mesh-sizes 1 --services-per-namespace 1 --namespace-counts 250,1000,2000,4000 \
  --sidecar-scopings namespace,wide --workload-mode config-only --measurement-pods 8 \
  --config-dump-samples 4 --outside-namespaces 2000 --outside-modes unlabeled,labeled \
  --settle 45 --probe-settle 45
./tests/controlplane/004-report-results.sh --results-dir tests/controlplane/results/sweep-<RUN_ID> --format markdown
./tests/controlplane/004-report-results.sh --results-dir tests/controlplane/results/sweep-<RUN_ID> --format json
# R2, about 37 min, only if the R1 report is done by T0+6:25. Retire R1's series first, undiscover only:
./tests/controlplane/005-cleanup.sh --contexts <mesh-a-ctx> --undiscover --no-delete
CONTROLPLANE_CONFIG_DUMP_TIMEOUT_S=120 ./tests/controlplane/003-run-sweep.sh <R1 flags> \
  --services-per-namespace 4 --namespace-counts 250,1000,2000 --sidecar-scopings namespace,wide --outside-modes none
```

- **The b and c ceiling, by hand.** Check after every R1 and R2 step, and at least every 10 min:

  ```bash
  for c in <mesh-b-ctx> <mesh-c-ctx>; do oc --context "$c" adm top pod -n istio-system -l app=istiod --no-headers; done
  ```

  If either istiod is above 8Gi, let the current step write its row, then stop the sweep: no larger
  step runs. The guard does not cover this ([b and c under the 16Gi limit](#b-and-c-under-the-16gi-limit)).
- On mesh-a, the wide cells at 2000 and 4000 namespaces now run instead of becoming
  SKIPPED_MEM_GUARD rows. The guard stops at 70% of 16Gi, 11.2Gi, below istiod's `GOMEMLIMIT` of
  14.4 GiB. A SKIPPED_MEM_GUARD row is still a valid result.
- `none` scoping is left out of R1. In growth mode it is close to `namespace` and costs about a third
  of the probe cells.
- R3 supplies the pods-mode points for task 1's required pods-vs-config-only comparison row. Its
  250 cell pairs with R1's config-only 250 cell at scale.
- No namespace is deleted inside the window; the clusters are destroyed instead. R2's series stays
  discovered for P7 (R1's, if R2 is cut).
- Task 4's passive capture stays active throughout, unless P3 was a no-go.

**P7 task 4, restart smoke.** This is the only istiod mutation, so it runs last. Task 1's objects
stay discovered, which makes the recovery time an at-scale number. It is also the first live run of
task 4's triggered path.

```bash
tests/churn/001-setup-churn-test.sh --contexts <mesh-a-ctx>,<mesh-b-ctx>,<mesh-c-ctx>
tests/churn/002-run-churn-probe.sh --source-context <mesh-a-ctx> --remote-contexts <mesh-b-ctx>,<mesh-c-ctx> --iterations 4
# during "Iteration 2/4 ... Scaling":
oc --context <mesh-b-ctx> -n istio-system delete pod -l app=istiod --wait=false
tests/churn/004-report-results.sh --results-dir <the dir 002 printed> --format markdown
```

- **Pass:**
  - iteration 2 shows POISONED_RESTART or TIMEOUT_REMOTE;
  - the capture's `index.tsv` has `replaced_gone`/`deleted` and `new_pod` rows;
  - there are no node names or IPs.
- **Fail:** record it for the campaign doc and capture by hand in P8. Nothing later depends on it.
- Skip churn `005-cleanup.sh`. It has no timeout, would queue behind task 1's namespaces on mesh-a,
  and the clusters are destroyed anyway.

**P8 evidence.**

- Run `find tests -path '*istiod-diag-*' -name index.tsv`.
- Re-capture by hand any row marked `capture_failed` or `budget_exhausted`, while the events
  (3 h TTL) still exist: load the libs as in P3 (`reach.sh` included, or nothing is written), then
  run `istiod_diag_capture <dir> manual <ctx> unknown '' '' oc`.
- Repeat the A0 `dig` against `networkz`.
- Copy `tests/*/results/` off the laptop.
- Announce the spend estimate.

**P9 teardown and audit**: see README, Verify and recover.

## 6. Isolation rules

- One suite at a time across the whole mesh: remote discovery couples the istiods, so a load on
  mesh-a shows up on b and c.
- Each workstream gets its own namespaces and results directory: `rosa-baseline`, `rosa-task6`,
  `rosa-lb`, `rosa-task1-smoke`, the task 1 sweep dir, and churn.
- One GitOps pause at a time, with its state file recorded; resume it before the next phase.
- Mutations happen on `<mesh-c-ctx>` only, apart from P7's istiod delete on `<mesh-b-ctx>`.
- No mesh-wide value changes mid-window.
- `cacerts` is never touched: the lab already confirmed the CA race.
- No OOM or liveness-probe tests on ROSA.
- No second `apply` once the teardown has started.

## 7. Spend guardrails, checkpoints, cut list

**The wall clock is the spend meter.** AWS Budgets refresh every 8-12 h, so they only catch a leak
the next day. Nothing server-side stops spend inside the window: `rosa create cluster --expiration`
is hidden and "not supported in production". T0 is on disk (`~/.rosa-window/t0`, outside the
repo). At every checkpoint:

- announce the spend estimate;
- update `~/.rosa-window/status.md`;
- check that `rosa whoami` still works (the auto-teardown needs the OCM login).

```bash
awk -v t0="$(cat ~/.rosa-window/t0)" -v now="$(date -u +%s)" -v rate=8.25 \
  'BEGIN { printf "about $%.0f so far\n", rate * (now - t0) / 3600 + 1 }'   # 6.75 for Tier B, 5.12 for A
```

The `+ 1` covers partial-hour rounding and transfer so far. At the T0+7:45 deadline it reads about
$65.

**Timers on the operator host.** The local tfstate lives there, so the backstop must too.

- `rosa-autoteardown` fires at T0+8:15 (`--fire-after 8h15m`) and `rosa-warn` at T0+7:15 (README,
  Re-run). Phone alarms at T0+7:15 and T0+7:45 back them up.
- The timer reports to the SNS topic: an "armed" email at T0, its result after the teardown.
  Nothing on the host can report a dead host, so a third phone alarm at T0+9:15 checks the result
  from off the host ([If the T0+9:15 alarm rings](#if-the-t0915-alarm-rings)).
- Check them with `systemctl --user list-timers | grep rosa`.
- The laptop stays plugged in and awake. A reboot drops both timers, so re-arm after one with the
  same `--arm` command. Without `--arm` that command fails, since a teardown needs `--now`.
- On WSL the timers live only while the distro runs. `instanceIdleTimeout=-1` from P0 keeps it
  running after the terminal closes.

**Structural caps.**

- Fixed worker counts (min = max), so nothing can grow.
- The vCPU quota caps a runaway only if it sits close to the tier's need: 64 for C, 52 for B.
  A quota already far above caps nothing. Held below 100, it makes `rosa verify quota` (and so
  `001-preflight.sh`) report one expected FAIL; P0 says how to read past it.
- One region, and `common_tags` with `purpose = "rosa-window"` and `expires`.
- Only the decided tier (C, or a listed fallback), never D, and no quota raise beyond the need plus
  8 without an explicit go before provisioning.

**AWS Budgets** (set up the day before; the first two action-enabled budgets are free). The limit is
$100 for the month: the owner's cap, in an account where nothing else bills. Read month-to-date
spend first (`m`). It includes the 2026-10-12 run, and every alert fires that much earlier in window
spend, which errs on the safe side.

```bash
aws ce get-cost-and-usage --time-period Start=<YYYY-MM-01>,End=<tomorrow> \
  --granularity MONTHLY --metrics UnblendedCost                      # m, month-to-date, $0.01 per call
cat > budget.json <<'EOF'
{"BudgetName": "rosa-window-monthly", "BudgetType": "COST", "TimeUnit": "MONTHLY",
 "BudgetLimit": {"Amount": "100", "Unit": "USD"}}
EOF
cat > notify.json <<'EOF'
[{"Notification": {"NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN",
                   "Threshold": 50, "ThresholdType": "PERCENTAGE"},
  "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "<owner-email>"}]},
 {"Notification": {"NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN",
                   "Threshold": 80, "ThresholdType": "PERCENTAGE"},
  "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "<owner-email>"}]},
 {"Notification": {"NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN",
                   "Threshold": 100, "ThresholdType": "PERCENTAGE"},
  "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "<owner-email>"}]},
 {"Notification": {"NotificationType": "FORECASTED", "ComparisonOperator": "GREATER_THAN",
                   "Threshold": 100, "ThresholdType": "PERCENTAGE"},
  "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "<owner-email>"}]}]
EOF
aws budgets create-budget --account-id <account> --budget file://budget.json \
  --notifications-with-subscribers file://notify.json
aws budgets describe-notifications-for-budget --account-id <account> --budget-name rosa-window-monthly   # 4 notifications
```

How to read the alerts:

- Write the expected month totals into `status.md`: `m + 65` (core), `m + 77` (extended) and
  `m + 81` (worst case).
- An ACTUAL alert above the line of the plan that ran means something still bills: run the audit.
- The 100% alert means the cap is gone, whatever ran.
- ACTUAL alerts fire once per budget per month.
- The FORECASTED alert needs about 5 weeks of usage history before it can fire, so on this account
  it may stay silent. It costs nothing to have.

Then:

- **`rosa-residual-daily`:** COST, DAILY, $3, ACTUAL above 100%. Create it at T+1, after a look at
  the cost by service.
  - It is the post-window leak tripwire: a day that bills more than $3 means a leftover NAT
    gateway, LB, EBS volume or cluster.
  - Created earlier, it fires on the window day itself and on ROSA Marketplace charges that post
    late.
- **Optional deny action:** on `rosa-window-monthly` at 100% ACTUAL, an `APPLY_IAM_POLICY` action.
  It is free as the first action-enabled budget.
  - It attaches a deny policy to the operator IAM user for `ec2:RunInstances`,
    `ec2:CreateNatGateway`, `ec2:AllocateAddress`, `ec2:CreateVpc` and
    `elasticloadbalancing:CreateLoadBalancer`, never any `Delete*`.
  - It needs a Budgets execution role.
  - It blocks only an accidental re-provision, stops nothing already running, and lags 8-12 h.
  - Never attach it to the clusters' operator roles: that breaks auto-repair mid-window.
- **Optional:** a Cost Anomaly Detection monitor with a $10 threshold (no charge:
  <https://aws.amazon.com/aws-cost-management/aws-cost-anomaly-detection/faqs/>, checked
  2026-10-13). Its daily summary also lags, so it is a next-day check like the budgets.

**Checkpoints (Tier C):**

| By | Check | If missed |
| --- | --- | --- |
| T0+1:15 | mesh verified (P2) | fix until T0+1:45, then tear down |
| T0+1:25 | P3 task 4 smoke: go/no-go | no-go: `ISTIOD_DIAG_ENABLED=0` from here on |
| T0+2:20 | P4a (mesh-a, 150 and 250) done | skip P4b |
| T0+2:55 | P4 done | stop the sweep, `005-cleanup.sh`, start P5 |
| T0+3:35 | A1-A3 done | skip A4 |
| T0+4:00 | P6 started | skip R3's 250 cell |
| T0+4:05 | task 3 recovery gate passed | abort P5 straight into the recovery gate |
| P6 + 16 min | S1 go/no-go | no-go: P6 ends (or R1 without 4000; see P6) |
| T0+6:25 | R1 report done | skip R2 |
| T0+7:00 | P7 started | skip P7 |
| T0+7:15 | `rosa-warn`, phone alarm | go to P8 and P9 now |
| T0+7:45 | teardown started | start it now; the auto-teardown fires at T0+8:15 |
| T0+9:15 | off-host phone alarm: teardown confirmed done (SNS "clean", or `teardown.result` CLEAN) | [If the T0+9:15 alarm rings](#if-the-t0915-alarm-rings); T0+10:30 is the last manual start under $100 |

Where the times come from:

- R2's 6:25: 7:45 − P8 10 − P7 15 − R2 42 = 6:38, less the 13 min margin used for Tier B.
- R3's 4:00: a P6 start that leaves R1's report done by 6:25 after R0, S1, R3 at 40 and 250, and R1
  (145 min).
- P7's 7:00: 7:45 − 25, less 20 min.
- The alarm's 9:15: the auto-teardown fires at 8:15 and takes about 45 min, plus 15 min for retries.
- The others are the core offsets plus 5-15 min of slack.

**Cut list**, in order:

1. task 1 R3's 250 cell
2. task 1 R2
3. task 3 A4
4. task 6 P4b (a and b at 60)
5. task 6's 250-service cells
6. task 4 restart smoke (P7)
7. task 1 R1's 4000-namespace step

Never cut a smoke step (P3's, S1) while its task still runs: it is what makes the later steps safe
to run.

## 8. Teardown, auto-teardown, audit

The planned path, the billing-first escalation, the auto-teardown and the audit list are in README,
Verify and recover. In short:

1. **Planned:** platform destroy (time-boxed to 15 min), `002-pre-destroy-vpc-cleanup.sh`, then the
   rosa-hcp destroy. On DependencyViolation, run 002 and destroy again.
2. **Escalation, or the timer at T0+8:15:** `003-auto-teardown.sh --now`.
   - It destroys `module.rosa_hcp` first: the clusters, worker pools and their IAM roles. Hourly
     billing stops, and nothing is left to recreate LBs.
   - Then it runs 002 with the saved VPC list and `--delete-interface-endpoints`.
   - Then the full destroy, with retries, and finally a read-only audit.
   - It publishes its result to the SNS topic that `--arm` requires, and writes it to
     `~/.rosa-window/teardown.result` (`CLEAN` or `FAILED`).
3. **Audit:** every check empty, also across regions.
   - At T+1 and T+2, check Cost Explorer by service: EC2, ELB, VPC, EBS and the Marketplace ROSA
     line must all be about $0.
   - Create the daily residual budget at T+1.

### If the T0+9:15 alarm rings

It rings on the phone whatever happened on the host. It is moot once a teardown's audit came back
empty and the timers were disarmed. Otherwise the auto-teardown fired at T0+8:15 and should be done:

1. **An SNS email "ROSA auto-teardown finished: clean" arrived:** the backstop worked. Run the
   README audit when back at the laptop. Done.
2. **An email "ROSA auto-teardown FAILED", or no email at all:** go to the operator host now. No
   email can mean a dead host (the timer never ran) or a teardown still running.

   The shell may be fresh (after a reboot or a new terminal), so set it up first: the
   credentials live in the named profile, and every path below is relative to the window worktree.

   ```bash
   cd <window-worktree>                                   # the pinned checkout the window ran from
   export AWS_PROFILE=<profile> AWS_REGION=us-east-2
   export RHCS_CLIENT_ID=ocm-cli RHCS_TOKEN="$(rosa token --refresh)"   # fails: run rosa login first
   systemctl --user is-active rosa-autoteardown.service   # "active": still running; tail -f ~/.rosa-window/teardown.log, look again in 15 min
   cat ~/.rosa-window/teardown.result                     # CLEAN: done, only the email failed; run the audit
   rosa list clusters                                     # none of the window's clusters?
   terraform/rosa-hcp/scripts/003-auto-teardown.sh --now  # FAILED, or no result and nothing running
   ```

   `--now` takes the same lock as the timer's run: while one runs, a second exits at once.
3. **The host cannot be brought back:** delete the clusters from another machine. The `rosa`
   CLI finds a cluster only through credentials in the AWS account that created it, so that
   machine needs both `rosa login` and credentials for the window's AWS account (any IAM user or
   role there, as a named profile): `export AWS_PROFILE=<profile> AWS_REGION=us-east-2`, then
   `rosa delete cluster --cluster <name> --yes` for each of the window's clusters (`cluster-001`
   to `cluster-004`). With no such machine, delete each cluster in OpenShift Cluster Manager
   (console.redhat.com/openshift, signed in as the Red Hat account `rosa` uses): the cluster's
   Options menu in the cluster list, or Actions on its details page, then Delete cluster. That
   needs no AWS credentials. It leaves the operator roles and the OIDC provider, which cost
   nothing. When the host is back, wait until the clusters are gone from the console before
   running `003 --now`, so Terraform does not race the deletion already under way. That stops
   $7.66 of the $8.25/h: the cluster fees, EC2, the ROSA worker fee and the root volumes (1.0000 + 3.5652 + 2.7360 + 0.3619). What may be left behind (NAT
   gateways, endpoints, LBs, monitoring volumes) bills at most about $0.58/h (0.5400 + 0.0440).
   Run `003 --now` and the audit once the host is back.

Start a manual teardown by T0+10:30 at the latest: it takes about 45 min, and billing has to end by
about T0+11:15 to stay under $100 ([Tiers](#3-tiers)). Tier B's last start is T0+13:10, Tier A's
T0+17:45 ([Fallback tiers](#fallback-tiers-b-and-a)).

## 9. Results capture

- Before P9, copy every `tests/*/results/` directory (gitignored) off the laptop:
  - the controlplane and dataplane TSVs and reports;
  - the churn results;
  - `rosa-lb/`, with A0 and the pause state file;
  - any `istiod-diag-*` evidence, which stays out of git.
- Write `docs/campaigns/<window-date>-rosa-validation.md` from `docs/campaigns/TEMPLATE.md`. Before
  quoting anything, redact:
  - context names (`<mesh-a-ctx>`);
  - node names (`<node>`);
  - LB hostnames (`<ew-lb-host>`);
  - VPC and account ids (`<vpc-id>`, `<account>`);
  - IPs.

  Pod names are fine.
- Record in the campaign doc the tier, the proxy request override and the istiod sizing: 8Gi
  request, 16Gi limit, and the b/c note. They are part of the run's configuration, even though they
  only change scheduling and headroom. Record the smoke steps' go/no-go results too: they are tasks
  1 and 4's first live validation.
- Update README's opening paragraph to "destroyed and audited empty on <date>", and commit it.

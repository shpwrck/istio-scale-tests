# Scale-test campaign results — 2026-06-17 stress shakeout (4-cluster)

A **small-scale shakeout on real ROSA-HCP infra** run *before* the expensive 21-cluster /
10,000-service campaign, to prove the harness + tuned multi-primary mesh work end-to-end and
to flush script/scale bugs cheaply. Topology: 4 clusters (1 hub + 3 mesh spokes), each pinned
at a **fixed 3 worker nodes**. This rig **cannot reach 10k services** (see the scale verdict) —
its value is validating the harness and the *shapes* of the curves, not production magnitudes.

> Resumed mid-run after a workstation crash; istiod was re-aligned 5→3 replicas to match the
> 20c/10k production plan before the suites were (re-)run. All five suites completed with valid
> reports. Full provenance + findings: `STRESS_TEST_STATUS.md` at the repo root.

---

## Scale envelope

> Pasted from the controlplane sweep's auto-generated
> [`scale-envelope-20260617T124130Z-340825.md`](../../tests/controlplane/results/) (generated, not
> hand-transcribed; `tests/lib/envelope.sh:render_scale_envelope`).

### 1. Mesh topology — what the peak mesh-size point actually contains

| Dimension | Value | Source |
|---|---|---|
| Clusters (multi-primary) | 3 | sweep peak `mesh_size` |
| Services / cluster | 40 | sweep peak `service_count` |
| Namespaces / cluster | 1 | sweep peak `namespace_count` |
| Workload replicas / service | 3 | sweep peak `replicas` |
| **Total services in mesh** | 120 | derived (N × S) |
| **Total endpoints in mesh** | 360 | derived (N × S × R) |
| **Connected proxies (measured peak)** | 57 | controlplane `connected_proxies_max` (summed across istiod replicas, n_valid-gated) |
| Per-proxy config size | 0.7 MB | controlplane `Cfg dump avg (MB)`, sidecar scoping = none |
| Sidecar scoping | none | sweep peak `sidecar_scoping` |
| Istio version | v1.28.5 | sweep header |
| Kube version(s) | v1.34.6 (all spokes) | sweep header |

### 2. Control-plane provisioning & headroom — *was anything actually stressed?*

| Resource | Provisioned (req / lim) | Measured peak | % of limit | Source |
|---|---|---|---|---|
| istiod replicas | 3 per cluster | — | — | live `deploy/istiod` |
| istiod CPU | 2000m / 4000m | ~542 m avg | **unknown%** | controlplane `CPU avg (m)` |
| istiod memory | 4096Mi / 16384Mi | ~261 Mi RSS | **unknown%** | controlplane `Mem RSS (Mi)` |
| Worker-node CPU | — | **unknown%** | **unknown%** | `kubectl top nodes` — **N/A this run** |
| Worker-node memory | — | **unknown%** | **unknown%** | `kubectl top nodes` — **N/A this run** |

> Node allocatable (source ctx): 22,500m CPU / 91,176Mi memory.
> **Utilization-% is `unknown` because the metrics API (`kubectl top`) was transiently
> unavailable for the controlplane sweep window** (recovered immediately after; metrics-server
> lagged following the istiod re-scale + namespace churn just before launch). The gate behaved
> correctly (WARN, no abort). istiod CPU/mem *magnitudes* are from the Prometheus `/metrics`
> scrape and are valid; only the `% of limit` headroom is unverified.

### 3. Workload / throughput axis (suite-specific)

| Suite | Axis swept | Values | Source |
|---|---|---|---|
| controlplane | mesh × service count | mesh 1,2,3 × svc 10,40 (scoping none) | sweep header |
| dataplane | QPS levels | 10 / 100 / 500 / 1000 (30s, 8 conns) | sweep header |
| propagation | iterations | 10 per mesh size (mesh 1,2,3) | sweep header |
| churn | churn deployments × scale range | 5 × (1→5), 5 iterations, mesh 1,2,3 | sweep header |
| churn-dataplane | churn rates × mesh | rate 1,10 /s × mesh 1,3 (trimmed shakeout matrix) | sweep header |

### Scale verdict — one line, up front

> Peak mesh carried **~57 connected proxies / 360 endpoints / 0.7 MB config per proxy** at
> istiod ~542 m CPU / ~261 Mi RSS; **node + istiod headroom is UNVERIFIED this run (metrics-API
> gap → CAUTION)**, and the mesh is **under-scaled vs the 10k-service target by ~80×** (120 of
> 10,000 services) → **trust the scaling _shapes_ and cross-cluster _overheads_, not the absolute
> magnitudes or any headroom claim.** This is a harness-validation pass on a fixed-3-node rig,
> not a capacity result.

---

## Customer SLA checklist

> Filled from the controlplane peak-mesh `sla` verdict. CAUTION/FAIL bands: 75 % / 90 %.

| Metric | Target | Observed | Margin | PASS/CAUTION/FAIL |
|---|---|---|---|---|
| istiod CPU (% of cross-replica limit) | < 75 % | unknown (metrics gap) | — | **CAUTION** |
| istiod memory (% of cross-replica limit) | < 75 % | unknown (metrics gap) | — | **CAUTION** |
| Worker-node CPU | < 75 % | unknown (metrics gap) | — | **CAUTION** |
| Worker-node memory | < 75 % | unknown (metrics gap) | — | **CAUTION** |
| istiod restarts in-window | 0 | 0 | — | **PASS** |
| Sample validity (`n_valid` / `n_total`) | all valid | 36/36 (controlplane) | — | **PASS** |

> **Customer SLA verdict: CAUTION** — one or more utilization signals unavailable (metrics API
> gap) — headroom not fully verified. (No restarts, all samples valid; the only gap is the
> transient `kubectl top` outage — re-run with metrics stable to clear it.)

---

## Per-suite results — trustworthy vs. discard

| Suite | Sweep | Status | Headline |
|---|---|---|---|
| controlplane | `sweep-20260617T124130Z-340825` | ✅ 36/36, 0 fail | **Full mesh 1,2,3 × svc 10,40, 0 `SETUP_FAILED`** after the capacity fix (istiod 5→3 + svc-count capped ≤40). istiod CPU **537→586→608 m/replica** by mesh size; CPU avg **76→542 m** (10→40 svc); per-proxy config 0.4→0.7 MB; connected proxies peak 57; 0 restarts. Charts: [`charts/2026-06-17-controlplane.md`](charts/2026-06-17-controlplane.md). |
| dataplane | `sweep-20260617T132242Z-448866` | ✅ 12 combos, 100 % success | **Cross-cluster overhead ~1–1.5 ms p50** (local ~2.3–3.2 ms vs remote ~3.4–4.5 ms), flat across mesh 1→3; all QPS 10/100/500/1000 hit target. EW-gateway `LoadBalancer` path (BLOCKER #2 fix) verified. Charts: [`charts/2026-06-17-dataplane.md`](charts/2026-06-17-dataplane.md). |
| propagation | `sweep-20260617T134154Z-470438` | ✅ 30 iters, 0 err | **Wall-clock propagation valid:** P1 local xDS ~2.0 s, P2 remote EDS ~2.0 s, **P3 remote sidecar 2.24→2.40 s avg (p99 3.2→4.5 s), rising with mesh size**. Charts: [`charts/2026-06-17-propagation.md`](charts/2026-06-17-propagation.md). |
| churn | `sweep-20260617T135405Z-495371` | ✅ 15 iters, 0 err | Convergence (syncz) ~2.3–2.8 s; **source xDS pushes avg 261 / remote avg 587; push amplification ~0.3–0.4**; proxies scale with mesh. Charts: [`charts/2026-06-17-churn.md`](charts/2026-06-17-churn.md). |
| churn-dataplane | `sweep-20260617T140548Z-539439` | ✅ 4/4, all `valid_runs=1` | **Δp99 under churn 2.09–3.08 ms** (baseline p99 ~3.9 ms → churn p99 ~6–7 ms); **EDS pushes scale with churn rate** (~6–7.5k @ 1/s → ~66–98k @ 10/s). Trimmed shakeout matrix (mesh 1,3 × rate 1,10). Charts: [`charts/2026-06-17-churn-dataplane.md`](charts/2026-06-17-churn-dataplane.md). |

### ⚠️ Discard / treat as suspect

- **Histogram-derived convergence metrics (`conv_p50/p99`) — DISCARD.** `pilot_proxy_convergence_time`
  extraction is unreliable across suites: controlplane reports the **histogram bucket floor** (100 ms /
  500 ms — Istio's two coarsest buckets) *as if* it were a measured quantile, with no caveat; propagation
  reports `n_valid=0` for it on every mesh size; churn-dataplane shows `0-100ms`. At this small scale real
  convergence is sub-100 ms so it floors. **Trust the wall-clock convergence/propagation numbers (syncz,
  P1/P2/P3); ignore the histogram convergence columns until the extraction interpolates within buckets or
  the report carries a bucket-floor caveat.** (FINDING #5A.)
- **All `% of limit` / node-utilization headroom this run — UNVERIFIED.** Metrics-API transient (above);
  re-run with metrics stable to populate. (FINDING #4.)

---

## Observations & follow-ups — the 20c/10k hardening backlog

The shakeout's real output: the harness *probes* are sound (valid reports/charts, sensible scaling shapes
and cross-cluster overheads), so the remaining 20c/10k blockers are **infrastructure / architecture**, not
probe logic.

- **BLOCKER #1 — ArgoCD↔ACM OpenAPI crash (biggest unfixed item).** ACM/MCE's `clusterview` aggregated API
  ships a malformed OpenAPI model; ArgoCD's hub cluster-cache `LoadOpenAPISchema` fails fatally → the
  app-of-apps is stuck `ComparisonError` → **no mesh ApplicationSets get created**. The tuned mesh was
  deployed via a direct bypass for this rig, but this **will block the 21-cluster GitOps run**. Durable-fix
  candidates (OpenShift GitOps version / ACM version / hub-without-the-broken-CRD) need a `/scale-test-review`.
- **FINDING #3 — per-proxy sidecar CPU request (100m) is the dominant data-plane capacity driver**, not
  istiod. On the fixed-3-node rig, 50 svc × 3 = 150 sidecar-pods overflowed the nodes (53 unschedulable);
  capped the sweep at 40 svc. At the 10k-service target this is **~1,000 cores of proxy CPU requests
  mesh-wide** — a first-order capacity-planning input. High service counts rely on the autoscaling (4→24
  node) production clusters; the fixed-3-node rig caps at ~46 svc/cluster.
- **FINDING #5A — convergence-histogram extraction** (see Discard). Highest-value report fix: it undermines
  a metric reported across multiple suites.
- **FINDING #4 — metrics-API readiness fragile right after heavy churn.** The gate is correct; operationally,
  don't launch a sweep seconds after istiod re-scale / 150-pod cleanup — let metrics-server settle.
- **Repo fixes already codified (working tree, this branch — not yet committed):**
  `charts/spoke-east-west-gateway/values.yaml` `service.type` NodePort→**LoadBalancer** (BLOCKER #2 durable
  fix; resolves the EW-gateway Argo apps' `OutOfSync` drift), `charts/spoke-ossm/values.yaml`
  `pilot.replicaCount` 5→**3** (matches the 20c/10k plan), `.gitignore` `/.bin/`. Both chart renders
  `helm template`-validated.
- **Infra-quota gate CLEARED** (verified 2026-06-17): vCPU=4000, EIP/NAT/IGW/VPC/gateway-endpoints=22 in
  us-east-2 — all approved + applied, nothing pending. No longer a blocker for the 21-cluster run.

> **Bottom line:** the harness is shakeout-validated and produces customer-grade reports/charts. Before the
> 21-cluster/10k run, the gating work is BLOCKER #1 (GitOps), the FINDING #3 capacity model on autoscaling
> clusters, and the FINDING #5A measurement fix — none of which the fixed-3-node rig can validate.

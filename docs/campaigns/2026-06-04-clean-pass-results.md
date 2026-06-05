# Scale-test campaign results — 2026-06-04 clean pass

The **clean full-workload re-run** that the [2026-06-02 workaround pass](2026-06-02-workaround-pass-results.md)
deferred. All five suites ran end-to-end against the live 10-spoke multi-primary mesh, at
**full workload** (controlplane 10×3, churn-dataplane 5×5) — enabled by fixing the O5 istiod
CPU over-reservation that forced the workaround pass down to reduced sizing.

Execution log: [`2026-06-04-clean-pass-status.md`](2026-06-04-clean-pass-status.md).

---

## Scale envelope

### 1. Mesh topology — what one mesh-size-10 point contains

| Dimension | Value | Source |
|---|---|---|
| Clusters (multi-primary, multi-network) | 10 (rosa-002…011) | sweep header |
| Services / cluster (controlplane) | 10 | controlplane header |
| Workload replicas / service | 3 | controlplane header |
| **Total services in mesh** | 100 | derived |
| **Total endpoints in mesh** | ~300 | derived (10×10×3) |
| **Connected proxies (measured peak)** | ~20 per istiod; ~224 summed-remote (churn) | controlplane `connected_proxies max`; churn `Remote connected proxies` |
| Per-proxy config size | **3.9 MB** (no scoping) → **0.5 MB** (namespace/explicit) — 87% reduction | controlplane `cfg_dump_avg` |
| Sidecar scoping | none / namespace / explicit (all three swept) | controlplane header |
| Istio version | v1.28.5 (OSSM, Sail operator `servicemesh-operator3`) | sweep header |
| Kube version(s) | v1.34.6 (all spokes) | sweep header |

### 2. Control-plane provisioning & headroom — *was anything actually stressed?*

| Resource | Provisioned (req / lim) | Measured peak | % of limit | Source |
|---|---|---|---|---|
| istiod replicas | **3** per cluster (pinned, `autoscaleEnabled=false`) | — | — | Istio CR |
| istiod CPU | **250m** / (no limit) | ~310–402 m avg under load; 2–3 m idle | n/a (no CPU limit) | controlplane `cpu_avg`; live `top` |
| istiod memory | 2Gi / **8Gi** | ~340–354 Mi under load; 310–454 Mi idle | **~4.3 %** | controlplane `mem_avg`; live `top` |
| Worker-node CPU | — (3 workers/spoke, 10.5 alloc cores) | 2–15 % (live, post-run) | low | `oc adm top nodes` |
| Worker-node memory | — (~42 GiB alloc) | 25–59 % | moderate | `oc adm top nodes` |

> **O5 fix applied this pass:** istiod `pilot.resources.requests.cpu` lowered **1 → 250m** on all
> 10 spokes via the Istio CR (Sail operator reconciles it; a raw Deployment edit reverts). That
> freed worker-node CPU headroom **~4.9 → ~7.2 cores/spoke**, which is what let controlplane run
> at full **10×3** (30 pods/cluster) instead of the workaround pass's 10×2. CPU request is
> measurement-neutral — it only affects scheduling.

### 3. Workload / throughput axis

| Suite | Axis swept | Values |
|---|---|---|
| propagation | mesh sizes × iterations | 1→10 × 10 (matrix 100) |
| churn | mesh sizes | 1→10, 5 deploys × (1→5) |
| controlplane | sidecar scopings | none, namespace, explicit (10×3 each = 30) |
| dataplane | QPS levels | 10 / 100 / 500 / 1000 (matrix 40), 100 % `pct_200` |
| churn-dataplane | churn rates | 1 / 5 / 10 ops·s⁻¹ (matrix 30) |

### Scale verdict — one line, up front

> Peak mesh carried **~20 connected proxies per istiod (~224 summed-remote) / ~300 endpoints
> per cluster / 3.9 MB config per proxy (no scoping)**; istiod ran at **~4.3 % of its 8Gi mem
> limit** and ~400 m CPU, worker nodes at **2–15 % CPU** → **still under-scaled relative to the
> infra (istiod barely stressed) → trust the scaling _shapes_ and cross-cluster _overheads_,
> not the absolute magnitudes.** This pass is nonetheless a cleaner, fuller baseline than the
> workaround pass: full 10×3 controlplane, all five suites complete, istiod pinned at 3 (not 5).

---

## Per-suite results — trustworthy vs. discard

| Suite | Sweep | Status | Headline |
|---|---|---|---|
| propagation | `sweep-20260604T024318Z-1085945` | ✅ 10/10, 0 err | **P1 (local push) & P2 (remote EDS) flat ~2.0–2.2 s across mesh 1→10**; P2 tracks P1 (fanout solid); restarted=0; skew 7–34 ms. Cleaner than workaround pass (no `TIMEOUT_P3`, no skew outlier) — O1 P3-prewarm fix now active. |
| churn | `sweep-20260604T043213Z-1465754` | ✅ 10/10, 0 err | Remote xDS ~2632 ms avg; push amplification ~0.6; connected proxies scale 8→28 src / 64→224 remote with mesh size. set-e abort gone (#31). |
| controlplane | `sweep-20260604T072535Z-51665` | ✅ 30/30, 0 err | **Full 10×3, 0 FailedScheduling — O5 resolved.** Sidecar scoping cuts per-proxy config **3.9 MB → 0.5 MB (87 %)**; istiod cpu 310–402 m / mem 340–354 Mi; convergence p99 100–500 ms (none) vs 0–100 ms (scoped); 0 restarts. |
| dataplane | `sweep-20260604T114908Z-831116` | ✅ 40, 100 % `pct_200` | **Cross-cluster overhead ~1 ms p50** (local ~2.4–2.8 ms vs remote ~2.8–3.6 ms), flat across mesh 1→10; modest p99 tail growth. |
| churn-dataplane | `sweep-20260604T170554Z-2030208` (PR #50 worktree) | ✅ 30/30, all `valid_runs=1` | **Δp99 under churn 10.7–20.9 ms** (baseline p99 3–8 ms → churn p99 17–25 ms); rises with churn rate, flat-ish across mesh size. **Re-run on the PR #50 fix** — see O10. |

### ⚠️ Discard

- **churn-dataplane `sweep-20260604T141403Z-1174742` (original run) — DISCARD.** Lost to the O10
  cleanup-cascade: even mesh-sizes (2,4,6) recorded `SETUP_FAILED`, stopped at ms7, no summary.
  Superseded by the clean re-run above.

---

## Observations & follow-ups (for the morning)

- **O5 — RESOLVED this pass** (istiod CPU request 1→250m). The fix is currently applied **live on
  the clusters only** (via Istio CR patch, GitOps disabled). To make it durable, land the same
  change in `charts/spoke-ossm/values.yaml` `pilot.resources.requests.cpu`. **Action: decide
  whether to commit the 250m default.**
- **O10 — churn-dataplane cleanup-cascade — FIX READY, NOT MERGED.** Root cause + fix in **PR #50**
  (`claude/scale-test/churn-dataplane-cleanup-cascade`, 7-agent review, 6/6 approved). The clean
  churn-dataplane data above was produced from that branch's worktree. **Action: review & merge
  PR #50**, then this campaign's churn-dataplane numbers match `main`.
- **O11 — cleanup still exceeds 240s at scale (NEW, non-fatal).** Even with PR #50, the per-mesh-size
  namespace teardown logs `CLEANUP_TIMEOUT` at ms4–10. PR #50's fix A (setup waits out the
  Terminating ns) makes this **benign** — no data lost — but the teardown itself is genuinely slow
  at higher pod counts (more sidecars × more clusters, finalizer-bound). **Follow-up: investigate
  the slow ns finalizer / consider a higher bound or parallel teardown** as a `/scale-test-review`.
- **Metadata gaps (minor):** controlplane O9 fields (`node allocatable`, `istiod limit`, `% of
  limit`) and churn-dataplane `ISTIOD_REPLICAS` recorded `unknown` — the `SCALE_*` instrumentation
  is default-off. Headroom numbers in this doc were filled by hand from `oc adm top`.
- **Still under-scaled** (istiod ~4 % of mem limit). For a run that actually stresses the control
  plane, the workload needs to grow ~20× (more services/endpoints), or the cluster shrink. The
  *shapes* and *cross-cluster overheads* here are trustworthy; the absolute magnitudes characterize
  a lightly-loaded control plane.

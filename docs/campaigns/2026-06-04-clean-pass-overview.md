# Istio Multi-Cluster Scale Test — Clean Pass

## Overview & Summary

**Date:** 2026-06-04 · **Istio:** v1.28.5 · **Kubernetes:** v1.34.6 (all spokes) · **Harness:** a4b8a18

**Topology:** 1 hub (rosa-001, no mesh) + 10 mesh spokes (rosa-002 … rosa-011), multi-primary / multi-network. rosa-002 is the source/primary; **mesh size *N*** = rosa-002 plus *N−1* remotes (so size 10 = full 10-cluster mesh).

**Control plane:** istiod pinned to 3 replicas/spoke (`autoscaleEnabled=false`, no istiod HPA); CPU request 250m (O5 fix), mem req 2Gi / limit 8Gi.

> **Status:** all 5 suites complete and clean. The 5th (churn under data-plane load) was re-run on the harness fix (PR #50) and finished a full clean 10×3 matrix. The detailed per-suite sweep summaries follow this page.

---

### Scale envelope (what was exercised)

| Dimension | Range |
|---|---|
| Mesh size (clusters) | 1 → 10 |
| istiod replicas / spoke | 3 (pinned) |
| Connected proxies — control-plane suite (max) | 20 |
| Connected proxies — churn suite (source / remote max) | 36 / 216 |
| Services in registry | 10 / cluster |
| Sidecar scoping modes | none, namespace, explicit (Sidecar API) |
| Data-plane load | 10 / 100 / 500 / 1000 QPS, 8 connections |
| Churn intensity | 5 deployments scaling 1↔5; rates 1 / 5 / 10 ops/s |
| Pods scheduled — control-plane suite (max) | 136 / 750 allocatable (~18%) |

### Headline findings

| Suite | Result | Headline |
|---|---|---|
| **1. Config / endpoint propagation** | ✅ 10/10 sizes, 0 errors | Local xDS push flat ~2.0–2.3 s and remote istiod EDS ~2.1 s at every mesh size; the long pole is **remote sidecar application — p50 ~13–18 s, p99 ~46–83 s** at scale (real, high-variance — the dominant scaling signal). |
| **2. Service/endpoint churn** | ✅ 10/10 stages, 0 errors | Local convergence ~2.4 → 3.7 s with mesh size; remote reach plateaus ~10–12 s; **push amplification stays ≤ ~1.1** (no push storm). Remote proxies scale linearly 24 → 216. |
| **3. Control-plane scaling** | ✅ 30/30 combos, **0 restarts** | istiod CPU peaks ~0.4 cores at mesh 10 (unscoped) / ~0.31 (scoped); mem flat ~330–354 Mi; **sidecar scoping cuts per-proxy config ~87–89%** (3.8 MB → 0.4–0.5 MB). O5 fix validated at full 10×3. |
| **4. Data-plane latency** | ✅ 10×4 QPS, **pct_200 = 100%** | Cross-cluster overhead **~0.5–1.0 ms at p50** (local ~2.0–2.8 ms vs remote ~2.8–3.6 ms), flat across mesh size; single-digit-ms p99 at scale; full target QPS to 1000. |
| **5. Churn under data-plane load** | ✅ 30/30 combos, 0 SETUP_FAILED, 0 restarts | idle p99 ~3.5–8 ms → under churn ~17–25 ms, i.e. **Δp99 ~13–21 ms added tail, flat** across mesh 1→10 & rate; EDS pushes scale ~7 k → ~85 k with rate. **6 `CLEANUP_TIMEOUT`s absorbed by the fix → 0 data loss** (the original run lost mesh 2/4/6). |

### Harness fix this campaign (suite 5)

The original churn-dataplane run lost **~40% of its matrix** to a setup/teardown race from the O8 *deploy-once-per-mesh-size* change: per-mesh-size namespace teardown (sidecar-injected pods) exceeded its 180 s budget → `CLEANUP_TIMEOUT`; the next mesh-size's setup then collided with the still-Terminating namespace → `SETUP_FAILED` for all its combos — a deterministic odd-✓/even-✗ pattern (sizes 2, 4, 6 lost). **Fix (PR #50):** setup now waits out a Terminating namespace before applying; cleanup fast-drains sidecar pods (5 s grace) before deleting; shared timeout 180 → 240 s. Reviewed by the 7-agent scale-test review (all six approved, round 1, zero blocking), validated live (the always-failing even sizes now pass), lesson captured as PL37.

### Campaign status

| # | Suite | Sweep | Result |
|---|---|---|---|
| 1 | Configuration / endpoint propagation | `…024318Z-1085945` | ✅ 10/10 sizes, 0 errors |
| 2 | Service/endpoint churn convergence | `…043213Z-1465754` | ✅ 10/10 stages, 0 errors |
| 3 | Control-plane resource scaling | `…072535Z-51665` | ✅ 30/30 combos, 0 restarts |
| 4 | Data-plane latency | `…114908Z-831116` | ✅ 10×4 QPS, pct_200 = 100% |
| 5 | Churn under data-plane load | `…170554Z-2030208` | ✅ 30/30 combos clean (re-run on PR #50 fix); 6 cleanup-timeouts absorbed, 0 data loss |

**Other fixes applied this campaign:** O5 (istiod CPU request — unblocks full 10×3 control-plane scheduling) · O1 (propagation pre-warm so P3 measures propagation, not pod boot) · O10 / PR #50 (churn-dataplane cleanup-cascade).

**Reading the detail pages:** a missing mesh-size row in any summary means it converged identically, not that it failed — failures appear explicitly as a non-`OK` status (`SETUP_FAILED` / `CLEANUP_TIMEOUT` / `PROBE_FAILED`), which occurs only in suite 5's *original* (discarded) run.

---

*Detailed per-suite sweep summaries follow.*

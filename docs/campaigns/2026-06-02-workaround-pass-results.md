# Scale-test campaign — results summary (workaround pass, 2026-06-02/03)

**Caveat up front:** this was the *workaround* run — istiod pinned to 5 replicas, controlplane reduced to **10×2** (not 10×3) and churn-dataplane to **3×5** for capacity (O5), and the mesh ran at **tiny scale relative to the infra** (see the Scale envelope below). So **trust the scaling _shapes_ and cross-cluster _overheads_, not the absolute magnitudes** — those characterize a small mesh, not the infra's capacity. Clean full-scale numbers come from the hardened re-run.

## Scale envelope

_What "mesh size 1→10" actually meant this run. Backfilled from the sweep reports per [`TEMPLATE.md`](TEMPLATE.md); peak = mesh-10. Mesh-wide figures are derived/measured as noted._

### 1. Mesh topology (peak, mesh-10)

| Dimension | Value | Source |
|---|---|---|
| Clusters (multi-primary) | **10** | sweep `Mesh size` |
| Services / cluster | 10 | sweep `Service count` |
| Namespaces / cluster | 1 | sweep `Namespace count` |
| Workload replicas / service | 2 | sweep `Replicas` |
| **Total services in mesh** | **~100** | 10 × 10, derived |
| **Total workload endpoints** | **~200** | 100 × 2, derived |
| **Connected proxies (measured peak)** | **~24 / cluster → ~220–240 mesh-wide** | churn mesh-10 `src_proxies`=24, `rmt_proxies`≈198 / 9 |
| &nbsp;&nbsp;↳ per istiod replica | ~4–5 | controlplane `Proxies` col (÷ 5 replicas) |
| Per-proxy config — proto xDS payload | **122 KB** → **16 KB** scoped (−87%) | controlplane `config_size_avg` |
| Per-proxy config — config-dump JSON | **3.9 MB** → **0.5 MB** scoped (−87%) | controlplane `Cfg dump avg (MB)` |
| Istio / Kube version | v1.28.5 / v1.34.6 | sweep header |

> **Proxy-count correction:** earlier wording called connected-proxies "~3–5". That was the **per-istiod-replica** count; with 5 replicas pinned per cluster the mesh actually carried **~24 sidecars/cluster (~220–240 total)** — still small, but ~10× what "3–5" implied. Report the summed, mesh-wide count.
>
> **Two config-size metrics:** the proto-encoded xDS payload (122 KB) and the human-readable config-dump JSON (3.9 MB) differ ~31× in absolute size but **agree on the −87% scoping reduction** — that ratio is the robust headline, the absolute base depends on which metric you cite.

### 2. Control-plane provisioning & headroom — *was anything actually stressed?*

| Resource | Provisioned (req / lim) | Measured peak | % of limit | % of req |
|---|---|---|---|---|
| istiod replicas | 5 / cluster (HPA removed) | — | — | — |
| istiod CPU | 1 core / (none) | ~220 m | — | **~22 %** of req |
| istiod memory | 2 Gi / 8 Gi | ~377 Mi | **~4.6 %** | ~18 % |
| Worker-node CPU | — | 2–8 % | — | — |

_istiod CPU/mem from controlplane `CPU avg (m)` / `Mem RSS (Mi)` (none-scoping, mesh 7–10); node CPU from the O9 observation._ **Nothing came within an order of magnitude of a limit → mesh was under-scaled by ~20×.**

### 3. Workload / throughput axis

| Suite | Axis swept | Values | Reps |
|---|---|---|---|
| propagation | iterations | 10, mesh 1→10 | 1 |
| controlplane | sidecar scopings × mesh | none, namespace, explicit (mesh 7–10 clean; 10×2) | 1 |
| dataplane | QPS levels | 10 / 100 / 500 / 1000 (30 s, 8 conns), mesh 1→10 | 1 |
| churn | churn intensity × scale range | 5 × (1→5), mesh 8–10 clean | 5 iter |
| churn-dataplane | churn rates | 1 / 5 / 10 (**incomplete, 11/30**) | 1 |

### Scale verdict

> Peak mesh-10 carried **~100 services / ~200 endpoints / ~220–240 connected proxies** (~24/cluster, ~4–5 per istiod replica), **~122 KB proto xDS (3.9 MB config-dump) per proxy** unscoped. istiod ran at **~4.6 % of its 8 Gi mem limit** (~22 % of its 1-core CPU request) and worker nodes at **2–8 % CPU → under-scaled by ~20× → trust scaling _shapes_ + cross-cluster _overheads_, not absolute magnitudes.**

## ✅ Usable metrics

### propagation — COMPLETE, trustworthy (P1/P2)
xDS propagation latency, mesh 1→10 (455 OK / 5 failed rows).
| metric | result |
|---|---|
| **P1** (local xDS push) | **flat ~2.0–2.4s** across mesh 1→10 |
| **P2** (remote istiod EDS) | **flat ~2.05–2.2s**, tracks P1 |
Finding: **per-cluster control-plane propagation is flat with mesh size** (multi-primary scales cleanly at this density). Fanout aggregation validated at ~90 port-forwards.

### dataplane — COMPLETE, trustworthy
Cross-cluster data-plane latency, mesh 1→10, all 4 QPS, **100% HTTP-200**.
| metric | result |
|---|---|
| local p50 | ~2.3–2.7ms (slight rise with mesh) |
| remote p50 | **~3.2–3.4ms, flat** |
| local / remote p99 | ~3–8.6 / ~5–6.9ms |
Finding: **cross-cluster overhead ≈ +1ms p50 (east-west gateway hop), flat across mesh size**; p99 tails grow modestly.

### churn — COMPLETE, trustworthy (conv_local + push counts)
Convergence under endpoint churn, mesh 1→10 (split across 2 sweep dirs; use the re-run's mesh-8).
| metric | result |
|---|---|
| **conv_local** | rises **~2.7s → ~5.6s** with mesh size |
| **src_push_triggers** | **93 → ~6,000 then plateaus ~5–6.8k** (push amplification rises with cluster count, then saturates as istiod batches) |
| connected_proxies (src) | summed correctly across 5 replicas (~24) |

### controlplane — COMPLETE at reduced 10×2, headline trustworthy
istiod resource scaling, mesh 1→10 × 3 sidecar-scopings.
| sidecar scoping | config_size_avg | istiod_mem |
|---|---|---|
| none | **122 KB** | ~380 Mi |
| namespace | **16 KB** | ~367 Mi |
| explicit | **16 KB** | ~371 Mi |
Finding: **Sidecar scoping cuts per-proxy config ~87% (122KB → 16KB)** — the clean headline. istiod memory stayed ~370–380Mi (far under the 8Gi limit → under-scaled, O9).

## ❌ Failed / not-trustworthy metrics (do not use these)
- **propagation P3** (remote-sidecar reachability): **5 rows `TIMEOUT_P3`**, and the *entire* P3 metric is **contaminated by canary pod-boot time** (O1) — ran 8–102s with no clean trend. **P3 is unusable this run.** (P1/P2 are fine.)
- **churn `conv_remote`**: **pod-readiness-dominated** (O4) — it waits for 20 newly-scaled source pods to go Ready, so it measures pod boot, not cross-cluster propagation. ~16–28s, not a control-plane signal. **Use `conv_local`, not `conv_remote`.**
- **churn-dataplane: SUITE INCOMPLETE — only 11/30 combos.** Died at combo 12 (mesh-4 cr10) on an unclean `set -e` exit (O6). Usable Δp99 (latency penalty under churn) for **mesh 1–3 only** (+ mesh-4 cr1/cr5): **+9 to +21ms**, but **noisy at `--repetitions 1`** and **mesh 5–10 missing entirely.** Treat as indicative, not final.
- **All absolute scale magnitudes** (proxy counts, istiod CPU/mem, config totals): the mesh was ~tiny vs the infra (O9) — these are *small-mesh* values, not capacity figures.

## Bottom line
- **Trust:** propagation P1/P2 (flat ~2s), dataplane local-vs-remote (+1ms cross-cluster), churn conv_local + push-amplification curve, controlplane sidecar-scoping config reduction (~87%).
- **Discard:** propagation P3, churn conv_remote, churn-dataplane mesh 4–10 (incomplete).
- **Re-run clean** (hardened harness + resized cluster, full 10×3 / 5×5, more reps) to get: trustworthy P3 (O1 fix), conv_remote split (O4), a complete churn-dataplane sweep (O6), and at-scale magnitudes (O9).

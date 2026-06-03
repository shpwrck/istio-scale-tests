# Scale-test campaign — results summary (workaround pass, 2026-06-02/03)

**Caveat up front:** this was the *workaround* run — istiod pinned to 5 replicas, controlplane reduced to **10×2** (not 10×3) and churn-dataplane to **3×5** for capacity (O5), and the mesh ran at **tiny scale relative to the infra** (connected-proxies ~3–5, istiod ~5% of its 8Gi limit, worker nodes 2–8% CPU — see O9). So **trust the scaling _shapes_ and cross-cluster _overheads_, not the absolute magnitudes** — those characterize a small mesh, not the infra's capacity. Clean full-scale numbers come from the hardened re-run.

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

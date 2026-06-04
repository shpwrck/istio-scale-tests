# Scale-test campaign status — 2026-06-04 clean pass

_Running log of the 2026-06-04 clean full-workload pass. KUBECONFIG=/tmp/campaign-kubeconfig.yaml (local, chmod 600, NOT committed); hub rosa-001; spoke contexts rosa-002…rosa-011 (10 spokes); mesh sizes 1→10._

This is the **clean re-run** that the 2026-06-02 workaround pass deferred: full workload, with the O5 istiod CPU-request fix applied so controlplane runs at full 10×3 (not the workaround 10×2).

## Preflight + de-risk — DONE

- **Auth**: OAuth exec credential works across all 11 contexts (kubeconfig exec path repointed from the operator's `/home/jskrzype/workdir/...` to this checkout's `terraform/scripts/oc-token-exec-credential.sh`).
- **Topology**: rosa-001 = hub (no mesh); rosa-002…011 = 10 mesh spokes, all reachable.
- **istiod**: 3/3 ready every spoke, pinned (`autoscaleEnabled=false, replicaCount=3`); no istiod HPA (the 2 HPAs are gateways). **Left at 3 replicas** (user decision) — a fresh clean baseline, NOT apples-to-apples with the workaround pass's 5-replica magnitudes.
- **O5 fix APPLIED mesh-wide**: istiod `spec.values.pilot.resources.requests.cpu` patched `1 → 250m` on all 10 spokes via the **Istio CR** (the istiod Deployment is owned by `IstioRevision/default` and reconciled by `servicemesh-operator3` — a raw Deployment edit would revert; the CR is the lever that sticks). Memory left at req 2Gi / limit 8Gi. All rolled cleanly to 3/3. CPU request is measurement-neutral (scheduling only).
- **Headroom**: 3 workers/spoke, 10.5 alloc cores. Free CPU rose **4.9 → 7.2 cores/spoke** after the fix → full controlplane 10×3 (3.0 cores of sidecars @100m) has ~4 cores margin.
- **Wiring**: confirmed post-restart — 10 multicluster remote secrets/spoke + istiod re-initialized all 9 remote registries (rosa-003…011 on rosa-002).
- **Clean**: no leftover `*-test` namespaces on any spoke.
- **Dry-run matrices validated** (no clusters touched): propagation 100 (10×10, `--force-large-matrix`), churn 10, controlplane 30 (10×3 scopings), dataplane 40 (10×4 QPS), churn-dataplane 30 (10×3 rates).

## Live execution (serial)

Launch mode: **live smoke first (propagation), then the rest if clean.** Contexts rosa-002..011.

| # | Suite | Status | Result dir / notes |
|---|-------|--------|--------------------|
| 1 | propagation | ✅ DONE | sweep-20260604T024318Z-1085945; **10/10 sizes, 0 errors** (~1h47m). P1/P2 flat ~2.0–2.2s all sizes; restarted=0; skew 7–34ms. Cleaner than workaround pass (no TIMEOUT_P3, no 4s skew outlier); O1 P3-prewarm fix active. sweep-summary.md written. |
| 2 | churn | ✅ DONE | sweep-20260604T043213Z-1465754; **10/10 stages, 0 errors**. set-e abort gone (PR #31 in main). Remote xDS ~2632ms avg; push amplification ~0.6; proxies scale 8→28 src / 64→224 remote. Summary written. |
| 3 | controlplane | 🔁 RELAUNCHED post-reboot | First attempt (sweep-…1683813) KILLED by host reboot mid-run (combo 1 had scheduled cleanly past O5 — left controlplane-test ns on rosa-002..006, cleaned up). Host reboot only killed local processes; ROSA clusters + istiod 250m patches unaffected. Kubeconfig recreated in /tmp. Fresh full **10×3** sweep → sweep-20260604T072535Z-51665. |
| 3b | controlplane (clean re-run) | ✅ DONE | **30/30 combos, 0 FailedScheduling/Insufficient-cpu** — O5 fully resolved at full 10×3 (the headline of this clean pass). Config dump avg 3.9MB; convergence p99 100–500ms; connected proxies 6–16; go heap ~114–158Mi. Namespaces auto-cleaned. Summary written. |
| 4 | dataplane | ✅ DONE | sweep-20260604T114908Z-831116; **10×4 QPS, pct_200=100%**. Cross-cluster overhead ~1ms p50 (local ~2.4–2.8ms vs remote ~2.8–3.6ms), flat across mesh 1→10. Summary written. |
| 5 | churn-dataplane | ❌ first run lost to O10 cascade | sweep-…1174742: ms1✅/ms2 SETUP_FAILED/ms3✅/ms4 SETUP_FAILED/ms5✅(ms5-cr5 PROBE_FAILED)/ms6 SETUP_FAILED, stopped at ms7, no summary. Even-size data lost. Verified against log — O10 diagnosis correct. DISCARD this sweep. |
| 5b | churn-dataplane (PR #50 fix) | 🟢 RE-RUNNING clean | Fix validated first (reduced ms1-3×cr1 from worktree: **ms2 even-size now OK**, delta_p99=18.72ms, 0 fail-markers). Full **5×5** 30-combo re-run launched from worktree `../istio-scale-tests-cleanup-cascade` → sweep-20260604T170554Z-2030208. This is the trustworthy churn-dataplane data. |

## Observations & issues (running log)

- **O10 — churn-dataplane cleanup-timeout → setup-failed cascade (PR #50, fix on branch, NOT yet applied to the running sweep).** In the live sweep (`sweep-20260604T141403Z-1174742`) every **even** mesh-size lost all 6 combos to `SETUP_FAILED` while odd ones completed: ms1✅ → `ms1-cleanup` CLEANUP_TIMEOUT → ms2❌(×6) → ms3✅ → `ms3-cleanup` CLEANUP_TIMEOUT → ms4❌(×6) → ms5(cr1✅, cr5 PROBE_FAILED). **Root cause:** O8 deploy-once moved cleanup to per-mesh-size; the shared `churn-dataplane-test` ns (fortio + 5×5 sidecar pods) exceeds the 180s `NS_DELETE_TIMEOUT` → CLEANUP_TIMEOUT → next mesh-size's `001` applies the chart's `kind: Namespace` into the still-Terminating ns → fast SETUP_FAILED for all combos; the setup-failure path's own cleanup then waits it out, so the *next* mesh-size recovers (the oscillation). **Net ~40% data loss** (even mesh-sizes 2,4,6,8,10). **Fix (PR #50, 7-agent scale-test-review, all six APPROVEd round 1):** `001` PL4-waits out a Terminating ns before apply (`--ns-wait-timeout`/`COEXEC_SETUP_NS_WAIT_SEC`); `006` fast-drains sidecar pods with a 5s grace before the ns delete (`COEXEC_CLEANUP_GRACE_SEC`); shared bound 180→240; PL37 captured. Worked entirely in a worktree — the running sweep's script files were left untouched. **Action for this campaign:** the current sweep will keep losing even mesh-sizes (ms6,8,10 still to come); re-run churn-dataplane from PR #50's branch once it's merged (or cherry-pick) to get a clean 10×3 matrix.

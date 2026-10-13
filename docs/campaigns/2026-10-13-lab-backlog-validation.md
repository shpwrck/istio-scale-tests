# 2026-10-13 lab validation of backlog tasks 2, 3, 5 and 6

Live checks of the harness changes for backlog tasks 2, 3, 5 and 6 ([`BACKLOG.md`](../../BACKLOG.md))
on the existing-cluster lab, plus the experiments for task 3's two root-cause hypotheses.
This is not a scale run. The lab proves the mechanisms; the absolute numbers are lab-sized.

## Rig

- Two mesh members, `<mesh-a-ctx>` and `<mesh-b-ctx>`, and an ACM hub `<acm-hub-ctx>` running Argo CD
  (not a mesh member). See [`docs/runbooks/existing-cluster-lab/`](../runbooks/existing-cluster-lab/README.md).
- Single-node OpenShift 4.21 on bare metal (19.5 CPU, about 93Gi, 250 pods per node), MetalLB for
  LoadBalancer Services (a two-address pool per member: ingress + east-west gateway).
- OSSM 3.4 / Istio v1.30.5, multi-primary multi-network, shared root from the hub (ESO PushSecret,
  5-minute refresh). istiod 1 replica at 1-2 CPU / 3Gi unless noted.
- Harness at the integrated commit of tasks 2, 6, 5 and 3 (before task 7 and the fix pass below).
- One task at a time. After each: all 30 Applications Synced/Healthy, both mesh-wiring gates
  `Ready ... ca=shared`, no sync windows, istiod back to 1 replica, no test namespaces.

## Results

| Task | Result | Headline |
| --- | --- | --- |
| 6 VS/DR axis | PASS | +20 clusters per proxy (= 10 services × 2 subsets); CDS +115%, RDS +66% |
| 2 per-cluster proxies | PASS | 3 istiod replicas: per-replica 7/6/9, per-cluster 22 = Running sidecar pods |
| 5 local baseline | PASS | 1 starved server replica: 88% of 1000 QPS, flagged; 2 replicas: 999.9 QPS, OK |
| 3 harness | PASS | Unreachable remotes listed in every format; `fail` policy exits 3 |
| 3 CA race | CONFIRMED | Reproduces the campaign signature; the PreSync hook prevents it |
| 3 LB reprovision | NOT REPRODUCED on MetalLB | istiod follows a new east-west address within ~1 s, no restart |

### Task 6: VS/DR traffic-management axis

`003-run-sweep.sh --mesh-sizes 1,2 --service-counts 10 --replica-counts 2 --traffic-configs none,vsdr`
(every service configured, 2 subsets, settle 60 s): 6 valid rows, no istiod restarts.

| Per proxy | none | vsdr | Delta |
| --- | --- | --- | --- |
| CDS clusters | 25 | 45 | +20 (expected 10 × 2) |
| CDS bytes | 59.2 KB | 127.4 KB | +115% |
| RDS bytes | 18.5 KB | 30.6 KB | +66% |
| config_dump | 0.41 MB | 0.55-0.57 MB | +36-39% |

istiod ingested 10/10 VirtualServices (`pilot_virt_services`). Subset clusters had healthy local and
remote endpoints; the configured route carried timeout 5 s, 3 retries and a 50/50 split. istiod
CPU, heap, push count and push time rose slightly (for example push time 0.37 → 0.61 ms at mesh
size 1), but at 10 services those are shape, not numbers.

### Task 2: per-cluster connected proxies

10 services × 2 replicas per member, so 22 expected proxies (20 test pods + 2 gateways).

- 1 istiod replica: per-pod 22, per-cluster 22, Running sidecar pods 22, `proxy_check=OK`.
- 3 replicas on `<mesh-b-ctx>` (Istio CR patched under a GitOps pause): new replicas read 0 (not
  N/A) until proxies rebalanced. After a rollout the per-pod values were 7/6/9, so the per-replica
  peak was 9 while the per-cluster total stayed 22 and matched an independent pilot_xds sum and the
  `oc` sidecar count. This is the ~1/3 reading of the 20-cluster campaign: a per-replica value read
  as a cluster value.
- 5 extra annotated pods without proxies: 22 vs 27 → `LOW` with a warning in every format; exit code
  still 0 (warning only). Raising the tolerance or the minimum difference turns it back to `OK`.
- The 001 capacity preflight now counts only non-terminal pods: 76 free slots instead of 28 on one
  member.

### Task 5: local baseline

An unthrottled server replica could not be saturated on this hardware at the suite's QPS levels
(about 5.9k QPS with one replica vs 6.9k with two at 8 connections; latency-bound). To emulate the
campaign's starved server, the `<mesh-a-ctx>` server sidecar was limited to 100m CPU.

- 1 replica: local QPS 1000 delivered 881.5 (88.1%) → `QPS_SHORTFALL`; the report's local-baseline
  verdict read `DROPPED ... reason=saturated ... server_replicas=1/1 remote=1/1`. The remote at 1000
  QPS was OK.
- 2 replicas (the new default), same throttle: 999.9 QPS, local baseline OK at every level.
- Unthrottled sweep with defaults: local baseline OK at every level, local p99 3.4 ms at 1000 QPS.
- The verdict checks delivered QPS and errors, not tail latency: two throttled replicas were OK
  with a 31 ms local p99.

### Task 3: harness

Both suites print a "Remote coverage" section and write `reach-<RUN_ID>.tsv`.

- Happy path: `REACHABLE 10/10` local and remote in one attempt; coverage 1/1; `--fail-on-unreachable` exits 0.
- A deny-ingress NetworkPolicy in the remote test namespace: `UNREACHABLE 0/10` after 3 attempts,
  `UNREACHABLE` rows instead of silent `n_valid < n_total`; 004 `--fail-on-unreachable` exits 3 and
  names the rule; `--on-unreachable fail` stops the probe and both sweeps with exit 3 and cleans up.
- On OVN-Kubernetes a new NetworkPolicy does not cut established connections: the east-west
  gateway's pooled connections kept the remote reachable until the remote server pods restarted.
- churn-dataplane's merged Service did not hide a blackholed remote: the load window failed on a
  client timeout (FAILED), because nothing failed fast enough for a retry. The per-cluster
  `fortio-server-<ctx>` Services and the reach check name the remote either way.

### Task 3: CA race (the likely root cause)

On `<mesh-b-ctx>`, `cacerts` was deleted right after an ESO push and the istiod pod restarted:

- istiod logged `Use self-signed certificate as the CA certificate`; the namespace root ConfigMaps
  switched to the self-signed root.
- Membership looked healthy: both istiods listed both clusters as `synced`.
- Cross-cluster traffic failed in **both directions** (`UNREACHABLE 0/10`, 503 `upstream connect
  error ... remote connection failure`), local traffic was fine. This is the campaign's signature:
  healthy membership, failed cross-cluster mTLS.
- ESO re-pushed `cacerts` 5 minutes later. 200 s after that istiod was still on the self-signed root
  (it saw the Secret event but did not reload). The gate reported `NotReady: istiod is not using the
  shared mesh root from cacerts (it started before cacerts existed; restart istiod)`.
- Recovery: restarting istiod alone put it on the shared root and the gate back to Ready; after the
  test workloads restarted, traffic was reachable both ways. No gateway restart was needed.

The fix from the modernization PR, a PreSync hook holding the Istio install until `cacerts` exists:
with GitOps paused, `cacerts` and the Istio CR were deleted, then GitOps resumed. The
`wait-for-cacerts` Job held the install for 270 s, released it 10 s after ESO re-pushed `cacerts`,
and istiod started on the shared root. The gate went Ready and traffic worked both ways with no
workload or gateway restart.

### Task 3: east-west load balancer reprovisioned

The MetalLB analog of the campaign's other hypothesis (a gateway LoadBalancer provisioned late or
rebuilt). In every case `<mesh-a-ctx>` → `<mesh-b-ctx>` traffic failed while the address was gone,
the gates and `remote-clusters` stayed healthy, and the gateway pods were never restarted.

| Case | Outage | Recovery after the address returned |
| --- | --- | --- |
| E1 address released (bogus pool annotation), same address back | 415 s | ≤ 1 s |
| E2 Service deleted and recreated, same address | 119 s | ~2 s |
| E3 both gateway Services deleted, east-west gets a **new** address | 30 s | same second; istiod's `networkz` showed the new address |
| E3 restore (east-west moves back to its original address) | 13 s | 1 s |

On MetalLB, istiod follows a changed east-west address within about a second, so "the gateway
needs a restart after its LB is rebuilt" does not reproduce here. What only AWS can show: ELB/NLB
target registration and health checks after a Service is rebuilt, hostname-based LB addresses and
DNS propagation, quota-late provisioning, and the 3-cluster partial-mesh pattern.

## Conclusion for task 3

The campaign's 7-of-19 failure matches the CA race exactly, and the CA race is now prevented
(PreSync hook) and detected (gate `ca=` check, reach check). The load-balancer hypothesis did not
reproduce on MetalLB. Whether AWS load balancers add a failure mode of their own needs the ROSA
window in [`docs/runbooks/rosa-validation/`](../runbooks/rosa-validation/README.md).

## Fixed after this run

Found here and fixed before merge:

- The reach detail showed fortio's generic `Error status -1` instead of the real error.
- A blackholed remote cost about 120 s in the reach check: its requests ran one after another.
- The detail request timed out (3 s) before Envoy gave up on the remote (a 10 s connect timeout
  plus Istio's default retries), so Envoy's own reason never showed. It now waits up to
  `REACH_DETAIL_TIMEOUT_SEC` (35 s), on the last attempt only.
- Unreachable rows were counted as "dropped (poisoned)" in the dataplane report.
- The istiod replica count came from the first context only; it is now probed on every context
  and shown as a range when members differ.
- Two cosmetic log issues.

Re-checked on the lab after the fixes:

- NetworkPolicy-blocked remote and a blackholed east-west gateway (address released): the probe
  took 73 s instead of about 150 s, and the detail read `upstream connect error or
  disconnect/reset before headers. retried and the latest reset reason: connection timeout`.
- Task 7: a controlplane sweep driven by `--config tests/controlplane/configs/smoke.env`
  (4 combinations, both members). The config overrode an exported environment value, the
  `--output-dir` flag overrode the config's results dir, all rows were OK, and the TSV preamble,
  the JSON report and the sweep's config snapshot carried the config path and sha256. Cleanup ran
  through the same config.

# 2026-06-17 stress shakeout — findings log

A 4-cluster ROSA HCP stress test (1 hub + 3 mesh spokes, fixed 3 nodes each) that checked
the tuned OSSM multi-primary mesh and the harness end to end before the 20-cluster / 10k run.
Code comments cite the `BLOCKER #N` / `FINDING #N` labels defined here.

> **Superseded remedy:** the `server-foundation` disable recommended below for BLOCKER #1 is
> wrong — it breaks spoke imports. The 2026-06-22 run fixed the crash with MCE ≥ 2.11.3 and
> nothing disabled; see [`2026-06-22-20c-10k-10k-results.md`](2026-06-22-20c-10k-10k-results.md#findings--fixes-codified).
> BLOCKER #2, FINDING #3 and FINDING #5 fixes are on `main`.

## Rig
- `terraform/rosa-hcp`: cluster_count=4, fixed 3 nodes (min=max=3), manage_service_quotas=false.
- `terraform/platform`: mesh_member_count=0 (all spokes), cluster_provider=rosa.
- Contexts: cluster-001 (hub: ACM + GitOps), cluster-002/003/004 (mesh spokes).
- Tuned mesh: spoke-ossm tuningBaseline.{discoverySelectors,sidecar,telemetryFiltering,accessLogFiltering}.enabled all true; profiles 04/05 unconditional.
- AWS quotas for the 21-cluster run (us-east-2), all approved and applied: On-Demand Standard vCPUs=4000,
  EC2-VPC Elastic IPs=22, NAT gateways/AZ=22, Gateway VPC endpoints/Region=22, Internet gateways/Region=22,
  VPCs/Region=22.

## Phase summary
| Phase | Result | Evidence |
|---|---|---|
| 0 Cluster bring-up | DONE | 4 clusters Ready, 3 nodes each, kubeconfig exported. |
| 1 Platform + tuned mesh (GitOps) | DONE via bypass | ACM 2.16.2, GitOps 1.20.4, 4 managed clusters AVAILABLE. app-of-apps blocked by the openapi bug (BLOCKER #1), so the tuned mesh was deployed through the spoke ApplicationSets directly: operator/namespaces/ossm/ingress-gw/east-west-gw Synced+Healthy on cluster-002/003/004. Verified tuned: Istio Healthy, 5 istiod replicas, discoverySelectors (2 selectors), istiod 2cpu/4Gi, 3 Sidecar CRs (root + 2 gateway exemptions), 2 Telemetry CRs, sidecar 100m. Gateways: ingress=1, eastwest=2 per spoke. Shared CA (cacerts) and remote secrets applied directly (hub CA/ESO chain was Argo-blocked). |
| 2 Mesh verification | DONE | All 3 spokes see the other 2 SYNCED. After the BLOCKER #2 fix (network labels + EW LoadBalancer), in-mesh curl of mesh-verify-echo from cluster-002 returned an even 6/6/6 across cluster-002/003/004: cross-cluster east-west routing proven with VPC peering off (public NLB :15443 AUTO_PASSTHROUGH). |
| 3 Harness shakeout | DONE (capped) | Controlplane capped to mesh-sizes 1,2,3 × service-counts 10,40 (FINDING #3); see results below and FINDING #4/#5. |
| 4 Readiness audit | DONE | 6-lens scale-test-reviewer panel; prioritized backlog below. |
| 5 Wrap + destroy | DONE | Rig destroyed (see Teardown). |

## Shakeout results (3 mesh spokes)
- **controlplane** (`sweep-20260617T124130Z`): scale envelope 3 clusters / 40 svc per cluster / 120 services /
  360 endpoints / 57 measured proxies; SLA verdict CAUTION (headroom not verified: metrics API gap, FINDING #4).
  istiod CPU 537 → 586 → 608m by mesh size.
- **propagation:** local xDS ~2.0s, remote EDS ~2.0s, remote sidecar (P3) 2.2 → 2.4s avg / p99 3.2 → 4.5s,
  rising with mesh size. Histogram `conv_p50/p99` had n_valid=0 (FINDING #5).
- **dataplane:** local ~2.3–3.2ms, remote ~3.4–4.5ms.
- **churn:** push amplification ~0.3–0.4.

## Decisions / issues log
- **BLOCKER #1 (Phase 1, MAJOR — must fix for 21-cluster GO): ArgoCD↔ACM openapi crash.**
  ACM/MCE 2.11.2 registers aggregated API `clusterview.open-cluster-management.io` (ocm-proxyserver),
  whose `v1alpha1.UserPermission` ships a malformed OpenAPI model (`UserPermissionStatus` unknown ref,
  from `github.com/stolostron/cluster-lifecycle-api`). ArgoCD app-controller's hub cluster-cache calls
  `LoadOpenAPISchema` (fetches the WHOLE `/openapi/v2`) which fails fatally → `hub-gitops-root`
  (app-of-apps) stuck `ComparisonError`, so NO mesh ApplicationSets get created. Spokes are clean
  (clusterview is hub-only) — spoke caches sync fine.
  Tried + FAILED: (a) ArgoCD `resourceExclusions` — exclusions filter resource *listing*, NOT the
  openapi-doc load, so they can't fix it; (b) delete the 2 clusterview apiservices + scale
  ocm-proxyserver/MCE-operator to 0 + restart app-controller — apiservices delete cleanly and stay
  gone, BUT the ROSA-HCP managed kube-apiserver KEEPS the deleted apiservice's openapi spec in
  `/openapi/v2` (stale, won't purge; can't restart the managed apiserver to force it). So ArgoCD's hub
  deploy is unfixable from the cluster side here.
  DURABLE FIX (Phase 4 — research/implement): candidates = (1) OpenShift GitOps version whose
  gitops-engine makes openapi-load non-fatal, (2) run hub ArgoCD without the broken ACM CRD exposure,
  (3) MCE/ACM version that fixes the UserPermission openapi. This WILL block the 21-cluster GitOps run.
- **WORKAROUND for the stress test:** deploy the TUNED mesh via the working paths — spoke components
  via their ApplicationSets (appset-controller generates spoke apps; spoke caches sync fine), hub-side
  CA/ESO/push-secrets via direct `helm template | oc apply` (bypassing the broken hub cache). Charts are
  the same merged main charts, so the mesh is still the TUNED baseline.
- MCE-operator + ocm-proxyserver restored to replicas=1 after the apiservice experiment (ACM healthy;
  openapi broken regardless).
- **BLOCKER #2 (Phase 2, MAJOR — must fix for 21-cluster GO): cross-cluster DATA plane broken with
  peering off.** Tuned mesh + control-plane cross-cluster discovery WORK (istioctl remote-clusters all
  synced via shared openssl CA + remote secrets). But data-plane east-west FAILS: a cluster-002 mesh pod
  curling mesh-verify-echo got only local (cluster-002) responses; cross-cluster attempts failed (~15/18).
  Root causes: (a) istio-system namespace `topology.istio.io/network` label is EMPTY on all spokes → istiod
  shows remote endpoints as raw POD IPs (not routed via EW gateway); (b) EW gateway is **NodePort** (values
  service.type) and ROSA workers have **NO external IPs** (only internal 10.2.x) → with VPC peering OFF,
  other clusters' VPCs (10.0.x) CANNOT reach the EW NodePort. Commit 235ea6d switched EW→NodePort for a
  HOMELAB/MetalLB flat network ("routable 172.16.10.x:31443") — that assumption is FALSE on ROSA multi-VPC.
  FIX (applying): EW gateway → **LoadBalancer** (public AWS NLB, routable cross-cluster over the internet,
  mTLS AUTO_PASSTHROUGH) + set the istio-system network label. For the 21-cluster run the spoke-east-west-
  gateway chart needs an environment-aware service.type (LoadBalancer for ROSA/peering-off; NodePort only
  for flat-network homelab) — this is a repo fix for the GO report.

- **FINDING #3 (Phase 3 — controlplane sweep capacity ceiling; binding constraint = per-proxy sidecar CPU).**
  The overnight controlplane sweep `SETUP_FAILED`ed on every `service_count=50` combo (mesh_size 1 & 2
  recorded; combo-6 was a 50-svc combo crashing mid-setup). Reproduced cleanly 2026-06-17.
  **Root cause (evidence-backed by CPU-request arithmetic):** the controlplane-test namespace enables
  sidecar injection (`istio.io/rev: default`), so every dummy pod gets a tuned istio-proxy sidecar
  requesting **~100m CPU**. The dummy app container itself is 0-request busybox, so the sidecar IS the
  load. Capacity model per 3-node spoke (≈22,500m alloc): baseline ≈8,600m (istiod + OpenShift system)
  → ≈13,900m free → ≈139 sidecar-pods → **≈46 services max**.
    - At **istiod=5** (2 cores × 5 = 10,000m baseline-heavy): 50 svc × 3 = 150 pods → **97 Running / 53
      Pending**, `FailedScheduling: Insufficient cpu`, autoscaler `NotTriggerScaleUp: max node group size
      reached` (rig is **fixed min=max=3 nodes**, can't scale).
    - After dropping **istiod 5→3** (frees 4 cores; matches the 20c/10k production plan): 50 svc → **137
      Running / 13 Pending** — still ~13 short (150×100m = 15,000m > 13,900m free). **40 services (120
      pods, 12,000m) fits with margin; 50 overflows.**
  How istiod was dropped on the rig: the spoke `Istio` CR is GitOps-managed by Argo app `<cluster>-ossm`
  (repo `main`, path `charts/spoke-ossm`, `syncPolicy.automated.selfHeal=true`), itself generated by the
  `spoke-ossm` **ApplicationSet** (no owner/root-app — the hub root app is dead per BLOCKER #1). Live CR
  patches and app patches both get reverted (appset regenerates the app). **Durable lever: patch the
  `spoke-ossm` ApplicationSet** `.spec.template.spec.source.helm.parameters` to add
  `pilot.replicaCount=3` (preserving `clusterName={{clusterName}}`) → appset regenerates apps → Argo
  auto-syncs CR → Sail scales istiod to 3. Done live on all 3 spokes (verified 3/3, mesh Healthy).
  **Repo fix for GO:** set `charts/spoke-ossm/values.yaml` `pilot.replicaCount: 3` on `main` (rig is
  currently heavier than the production plan intends).
  **Biggest GO-report implication:** the **per-proxy sidecar CPU request (100m) × workload count is the
  dominant data-plane capacity driver**, not istiod. At the 10k-service production target that is
  ~1,000 cores of proxy CPU *requests* mesh-wide — a first-order capacity-planning input. High service
  counts rely on the production autoscaling (4→24 node) clusters; the fixed-3-node stress rig caps at
  ~40 services/cluster. NOT a harness bug — a rig-capacity artifact + a real scale finding.

- **FINDING #4 (Phase 3 — metrics-API transient, NOT a harness bug; re-run needed).** The capped
  controlplane sweep `sweep-20260617T124130Z` completed all combos with valid istiod CPU/convergence/xDS
  data, but `METRICS_API=unavailable` and node-utilization columns (`node_cpu_pct`, `node_mem_pct`,
  istiod `*_pct` that need `kubectl top`) are N/A for EVERY row. Root cause: the metrics API (metrics.k8s.io
  on the ROSA spokes) was genuinely down for the whole sweep window (12:41–~13:00Z) and recovered right
  after — almost certainly metrics-server lag because the sweep was launched seconds after churning istiod
  5→3 + deleting 150-pod test namespaces. The `calib-metrics-timeout-ns-wait` gate behaved CORRECTLY:
  `cap_metrics_ready` (`top nodes --request-timeout=15s`, 120s readiness poll) detected the outage, WARNed,
  and proceeded without aborting (utilization is observability, not the core measurement). `kubectl top
  nodes` returns in ~1.9s once healthy. **Action: re-run the controlplane sweep once metrics are stable;
  do NOT launch a sweep immediately after heavy istiod/namespace churn — let metrics-server settle first.**

- **FINDING #5 (Phase 3 — report-validity, controlplane; campaign verifies charts/reports too).**
  Validating the rendered controlplane report (`sweep-20260617T124130Z`) surfaced two output-quality issues:
  (A) **convergence_p50/p99 and queue_p50/p99 are histogram-bucket FLOORS, not interpolated quantiles** —
  33/36 rows = 100, 3/36 = 500, i.e. exactly Istio's coarsest `pilot_proxy_convergence_time` buckets
  (0.1s, 0.5s). At small scale convergence is sub-100ms so everything floors to 100ms; the report presents
  these as measured quantiles with no "bucket-floored / unresolved below 100ms" caveat → misleading. (Real
  signal would appear at 10k-service scale in higher buckets.) CROSS-SUITE: the propagation suite's
  histogram-derived `conv_p50/p99` is `n_valid=0` on every mesh size too (its wall-clock P1/P2/P3
  propagation measurements ARE valid: local xDS ~2.0s, remote EDS ~2.0s, remote sidecar 2.2→2.4s avg /
  p99 3.2→4.5s scaling with mesh size). So `pilot_proxy_convergence_time` histogram extraction is
  unreliable across suites — trust the wall-clock signals; treat histogram convergence as suspect until
  fixed. Fix: interpolate within buckets OR clearly
  caveat the bucket-floor in the report. (B) [CORRECTED] The sweep DOES emit a proper scale-envelope
  artifact (`scale-envelope-*.md`, separate from the per-phase `controlplane-*.md` I first read): it leads
  with mesh topology (3 clusters / 40 svc per cluster / 120 services / 360 endpoints / 57 measured proxies),
  a provisioning+headroom table, and a one-line SLA verdict — and it CORRECTLY degraded to "CAUTION —
  headroom not fully verified (metrics API gap)" with utilization shown as `unknown%`. So the envelope/
  headroom design is good; the only gap is the unknown utilization values = FINDING #4 (metrics transient),
  not a missing section. Charts artifact (`sweep-charts-*.md`) renders real data (istiod CPU 537→586→608m by
  mesh size). Remaining audit item from this suite is (A) the convergence/queue bucket-floor caveat.

- **BLOCKER #1 — live investigation 2026-06-17 (clusters kept up specifically for this; reproduced + 1 fix tried, FAILED).**
  - REPRODUCED + confirmed exactly as documented: `hub-gitops-root` (targets hub `kubernetes.default.svc`) sync=Unknown,
    ComparisonError = `error getting openapi resources: SchemaError(github.com/stolostron/cluster-lifecycle-api/
    clusterview/v1alpha1.UserPermission.status): unknown model in reference` — the malformed clusterview OpenAPI breaks
    the hub cluster-cache sync, so the app-of-apps can't compute state.
  - SECONDARY issue found: spoke cluster caches ALSO fail openapi reload but with a 401 ("the server has asked for the
    client to provide credentials", server=cluster-002/003/004) — spoke ArgoCD cluster creds look EXPIRED after ~13h.
    Separate from BLOCKER #1 (which is hub-local) but will block spoke app syncs (e.g. cluster-004-ossm cache errors).
  - Approach A (GitOps version bump) premise INVALIDATED: already on **ArgoCD v3.3.10** (built 2026-05-20, recent).
  - No GitOps OPERATOR is running anywhere (no deploy/pod/CSV/subscription; CRD label points at openshift-operators but
    it's gone — reconciled once at install, since removed). So the ArgoCD CR is NOT reconciled → direct statefulset
    patches STICK (no revert). `.spec.controller.env` on the CR is therefore inert.
  - FIX TRIED + FAILED: the documented `ARGOCD_CLUSTER_CACHE_LOAD_OPEN_API_SCHEMA=false` (argo-cd #22757/#25976; the
    Kueue VisibilityOnDemand class). Injected DIRECTLY into the app-controller statefulset (confirmed present in the
    running pod's env). The SchemaError STILL fires on every cache sync (fresh logs 15:53/15:54Z) → the env var does NOT
    gate this code path on v3.3.10 (likely wired in a later ArgoCD/gitops-engine version). **So BLOCKER #1 is NOT the
    trivial one-setting fix the web workaround implies — at least not on OpenShift GitOps 3.3.10.**
  - REMAINING candidates: (1) find the ArgoCD/gitops-engine version that actually honors the openapi-skip flag and bump
    to it (research offline, verify on a future hub); (2) neutralize the malformed clusterview OpenAPI at the source
    (prior attempt failed: ROSA-managed apiserver keeps the stale `/openapi/v2` after apiservice deletion); (3) deeper
    gitops-engine source check on how v3.3.10 reads the flag. The reproduce step needed the live hub; the version/knob
    research does NOT — can be done offline, then verified on a short-lived hub.
  - Left the (inert) env var on the statefulset; can revert. Clusters STILL UP (burning) pending the next decision.
  - **ROOT-CAUSE CONCLUSION (from gitops-engine source, `pkg/cache/cluster.go` master 2026-06):** the cluster cache
    loads `/openapi/v2` UNCONDITIONALLY and in `sync()` treats a load failure as FATAL (`return fmt.Errorf("failed to
    load open api schema while syncing cluster cache: %w")` — the EXACT error we see). There is **NO setting to skip it**
    and the latest master is still fatal. THEREFORE: **a GitOps/ArgoCD version bump will NOT fix BLOCKER #1** (approach A
    is definitively dead), and the `ARGOCD_CLUSTER_CACHE_LOAD_OPEN_API_SCHEMA` env var is NOT a real gitops-engine knob.
    The ONLY fix is to make the hub's `/openapi/v2` VALID — i.e. remove/fix the malformed clusterview `UserPermission`
    model at the SOURCE (MCE). Options: (1) cleanly delete the `v1.clusterview.open-cluster-management.io` APIService and
    confirm `/openapi/v2` purges (prior overnight attempt said it does NOT purge on ROSA HCP, but that attempt scaled
    ocm-proxyserver to 0 which leaves the apiservice "unavailable"/stale — a CLEAN delete is untested; needs user consent,
    destructive to MCE); (2) upgrade MCE/ACM (2.11.2) to a version that fixes the `UserPermissionStatus` openapi bug
    (heavy, partly out of our control). **BLOCKER #1 is therefore an MCE/ACM-source problem, NOT an ArgoCD config/version
    problem — a real risk for the 21-cluster GO that the GitOps stack can't paper over.**
  - **CLEAN source-removal experiment (2026-06-17, user-approved) — CONFIRMS removal does NOT work on ROSA HCP.**
    Paused the MCE *operator* (not the proxyserver — the prior attempt's mistake), deleted BOTH clusterview
    APIServices (v1 + v1alpha1); they STAYED gone for 105s, but `/openapi/v2` kept all 3 `UserPermissionStatus`
    refs the whole time — the hosted kube-apiserver does NOT rebuild `/openapi/v2` on APIService deletion (would
    need an apiserver restart, impossible on ROSA-HCP managed control plane). State fully RESTORED afterward
    (MCE operator→2, CR Available, proxyserver 2/2, apiservices recreated). So source-removal is definitively dead.
  - **DEFINITIVE BLOCKER #1 VERDICT:** unfixable via (a) ArgoCD config — no skip flag exists; (b) ArgoCD/GitOps
    version bump — load is unconditional+fatal on latest master; (c) clusterview APIService removal — `/openapi/v2`
    won't purge on ROSA HCP. **The ONLY fix is running an MCE/ACM version that publishes VALID clusterview
    `UserPermission` OpenAPI from the start (so `/openapi/v2` is never poisoned).** That is a version-SELECTION task
    for the 21-cluster run (research which MCE ≥2.11.2 fixes the `cluster-lifecycle-api` UserPermissionStatus model),
    NOT something to verify on this disposable rig. **Live-grinding value on BLOCKER #1 is EXHAUSTED** — remaining
    work is offline MCE-version research + the real-run install. Headline 21-cluster GO blocker, partly upstream.
  - **BLOCKER #1 — GO recommendations (offline research 2026-06-17):**
    1. NO ArgoCD-side fix exists (confirmed from gitops-engine source) — do NOT waste time on ArgoCD config/version.
    2. PRIMARY: treat ACM/MCE↔GitOps OpenAPI compatibility as a GO gate. MCE 2.11.2 / ACM 2.16.2 poisons
       `/openapi/v2` with the malformed `clusterview/v1alpha1.UserPermission` (`UserPermissionStatus` unknown-model,
       a `github.com/stolostron/cluster-lifecycle-api` codegen bug). On a FRESH hub, verify the chosen ACM/MCE
       version serves valid clusterview OpenAPI (check ACM release notes / file upstream) BEFORE the 21-cluster run.
    3. CANDIDATE within-our-control workaround (test on next fresh hub): disable the MCE component that registers the
       clusterview aggregated API via `MultiClusterEngine spec.overrides.components[].enabled=false` AT INITIAL INSTALL
       (so the hosted apiserver never caches the broken `/openapi/v2` — it won't purge post-hoc, proven above). Need to
       identify which component owns `ocm-proxyserver`/clusterview (mechanism confirmed; `cluster-proxy-addon` is one
       disableable component but likely not the right one — confirm). Only viable if clusterview isn't needed for the
       mesh GitOps (it's an ACM console/RBAC feature — almost certainly not needed by the mesh app-of-apps).
    4. SECONDARY (separate, also needed for the real run): the spoke ArgoCD cluster credentials expired after ~13h
       (401 on spoke cache openapi reload) — the multi-hour real run needs long-lived / auto-refreshing spoke creds.

## Teardown final state (2026-06-17) + one billing flag for the operator
- ROSA rig FULLY destroyed: `rosa list clusters` → none; `terraform/rosa-hcp` state = 0 resources. The 4 cluster
  VPCs needed manual deletion of orphaned ROSA `vpce-private-router` SGs (ROSA-created, outside the tf VPC
  module — they blocked VPC delete); done, then `terraform destroy` removed all 4 VPCs. No running instances,
  no rig NAT/EIP. **Rig billable footprint = $0.** Platform tf state cleaned to just the rosa remote-state data
  source (the 2 acm k8s-manifest entries state-rm'd — resources gone with the cluster).
- ⚠️ **BILLING FLAG (NOT this repo's terraform — operator decision):** a CloudFormation stack
  `rosa-network-stack-<aws-account-id>` (tags `service=ROSA`, `rosa_hcp_policies=true`) owns VPC
  `<vpc-id>` (10.0.0.0/16) with a **NAT gateway (`<nat-gateway-id>`) + 5 Interface VPC
  endpoints = ~$0.10/hr billable**. This is the ROSA-HCP account network stack (from `rosa create network` /
  account setup), separate from the per-cluster rig VPCs. NOT deleted (could be intentional/shared). If
  abandoned, remove via `aws cloudformation delete-stack --stack-name rosa-network-stack-<aws-account-id>`.

## Phase 4 readiness audit — prioritized 20c/10k GO backlog (6-lens panel, 2026-06-17)
Verdict: **NO-GO until the P0s below are codified.** The probe logic is sound and the harness is well-hardened
on known axes; the gaps are scale-up issues the fixed-3-node/4-cluster rig couldn't surface. Build on
BLOCKER #1/#2 + FINDING #3/#4/#5 (don't re-derive).

P0 (block or corrupt the 20c/10k run — fix before GO):
- **P0-a (istio) istio-system `topology.istio.io/network` label NOT codified** — fixed live-only in Phase 2; the
  go-prep branch only carries the EW `service.type` flip, not this. Without it istiod advertises local workloads
  as raw pod IPs → cross-network data plane dead mesh-wide. Add to `charts/spoke-istio-namespaces/templates/
  namespace-istio-system.yaml` (`topology.istio.io/network: {{clusterName}}-{{networkSuffix}}`).
- **P0-b (scale) capacity preflight does `get pods -A -o json` per context per combo** (`tests/controlplane/
  001-…:274`, `tests/lib/capacity.sh:335`) — hundreds of MB through jq × 20 ctx, serial, on the hot path at 10k
  pods. Scope to test ns / names-only / `--chunk-size`.
- **P0-c (scale+repro) fanout dimensioned & `FANOUT_MAX_SKEW_MS=1000` calibrated for ≤10 contexts** (`tests/lib/
  fanout.sh:56-94,165-192`) — at 20c×5=100 PFs the skew ceiling mass-drops rows (n_valid collapse at the key data
  point) and PF readiness is serial O(sum). Re-derive skew from a real high-context run; parallelize readiness.
- **P0-d (istio) discoverySelectors egressHosts are EXACT ns matches** — `namespaceCount>1` (`controlplane-test-0`
  vs `controlplane-test/*`) silently strips sidecar egress → no endpoints. Make egress ns-count-aware or fail fast.
- **P0-e (conventions) ACM/MCE pinned by floating CHANNEL not version** (`config/versions.env`, `charts/acm-operator`)
  — collides with BLOCKER #1's version-selection. Pin a concrete MCE CSV; record in versions.env.
- **P0-f (conventions) BLOCKER #1 server-foundation disable has no codified home** — land in `charts/acm-
  multicluster-hub` `multiclusterHub.spec.overrides.components` + a TF `acm_disabled_components` var; `/openapi/v2`
  preflight as a numbered script. (Component name `server-foundation` CONFIRMED via the live hub test.)
- **P0-g (repro) RUN_ID not propagated into controlplane/dataplane report outputs** (`004-report-results.sh`) —
  committed campaign artifacts are unattributable. Emit RUN_ID in text/csv/md/json metadata.
- **P0-h (usability) FINDING #3 capacity unmitigated operationally** — no pre-run capacity gate; operator must
  hand-cap `--service-counts`. Add a dry-run capacity WARN (services-that-fit = (node_alloc − istiod)/(reps×sidecar_m)).
- **(measurement) FINDING #5 histogram floor — FIXED (commit 58686fa).** ✓

P1 (fix before relying on a multi-hour unattended run):
- No kubectl `--qps/--burst` tuning ANYWHERE (default 5/10) — the single biggest unaddressed apiserver throttle at
  20 ctx; add a documented client-rate override + bounded retry on the apply path (429 → SETUP_FAILED today).
- Controlplane cleanup at 10k sidecar-pods will hit the 300s ns-delete bound → PL37 SETUP_FAILED cascade; port the
  churn-dataplane fast-drain (scale-to-0 before ns delete) into controlplane 005 + raise the timeout.
- `explicit` sidecar-scoping = ~1500-object single SSA stream/context → throttle/partial-fail; chunk it.
- istiod 4Gi request vs whole-mesh cache (~30k endpoints across 20 primaries) → OOM-mid-sweep risk; size request to
  measured steady-state; add `process_resident_memory_bytes` headroom to the SLA envelope.
- No `--resume <sweep-dir>`; a 6-hr sweep that dies at combo 40/64 restarts from 1. Add resume-skipping-completed.
- Floor-pinned/single-bucket caveat still not rendered in reports (now that #5 interpolates, flag single-bucket-pinned).
- Propagation cross-run percentile is nearest-rank with no min-n gate (p99≈max(N) at small n).
- Runbook (`docs/scale-test-campaign/`) missing: capacity formula, metrics-settle-after-churn rule (FINDING #4),
  and a one-screen campaign GO/NO-GO rollup across the 5 suites. EW gateway `service.type` knob undocumented.
- Remote-secret fan-out O(N²) (20 primaries → ~380 secrets, each istiod watches 19 remote apiservers) — assert
  `istiod_managed_clusters==N-1` per cluster; ensure mesh-wiring `expectedMembers` wired to 20 not 4.

P2: config-dump exec needs `--request-timeout`; tfvars comment drift on the 4→21 flip + chart/README pin-bumps;
client retry budget docs.

## GO-prep close-out — ALL TIERS MERGED TO main (2026-06-17)
- **P0 (PR #69, merged)** — 8 GO-gating fixes: istio-system network label, capacity preflight scoping,
  fanout readiness/budget, egress fail-fast, ACM/MCE version-pin path, BLOCKER #1 server-foundation
  disable + /openapi/v2 preflight, RUN_ID propagation, plan-time capacity WARN. Plus BLOCKER #2
  (EW LoadBalancer), FINDING #3 (istiod replicaCount=3), FINDING #5 (histogram interpolation).
- **P1 (PR #70, merged)** — kubectl --qps/--burst + apply retry, cleanup fast-drain, chunked apply,
  istiod RSS mem in SLA, sweep --resume, single-bucket caveat, propagation min-n gate, mesh-wiring
  N-1 assertion, runbook (capacity formula / metrics-settle / GO-NO-GO rollup).
- **P2 (PR #71, merged)** — config-dump exec timeout + ACM version-pin README note. (tfvars comment
  drift was local-only/gitignored — fixed locally; .example was already clean.)
- The campaign sample report (PR #68) was CLOSED (too many data gaps to keep in-repo).

**REMAINING for the real run (cannot be codified offline — runtime/decision items):**
1. **BLOCKER #1 — disable `server-foundation` at install is the PRIMARY remedy** (superseded — see the note at the top) (live-proven + deep-research-
   corroborated 2026-06-21; see the dated section below). MCE-version selection is the BACKSTOP only, and the
   2026-06-21 research pass came back **UNRESOLVED** for a concrete fixed `ACM_MCE_VERSION` — no errata found —
   so do NOT count on a version bump; leave `ACM_MCE_VERSION` documented-but-unset and rely on the disable.
2. **`FANOUT_MAX_SKEW_MS`** — re-derive from a real ~100-PF (20-context) skew distribution; do NOT run on
   the provisional 1000ms default.
3. **istiod mem request** — size to measured steady-state cache (whole-mesh ~30k endpoints) before GO.
4. **Validate** the server-foundation-disabled mesh on a fresh **ROSA-HCP** hub: the disable was empirically
   proven on a self-managed OCP hub (poison removed, cluster-manager survives) but the end-to-end path —
   ArgoCD hub cache recovers → app-of-apps/ApplicationSets deploy → spokes register — was never run to
   completion (rig torn down). Confirm at-install on ROSA-HCP (can't purge post-hoc there). Also check Red Hat
   SUPPORTED status of disabling server-foundation.
5. Flip `terraform/rosa-hcp/terraform.tfvars` cluster_count 4→21 + autoscale 4/24; platform mesh_member_count→20.

## 2026-06-21 — BLOCKER #1 deep-research corroboration (multi-source, adversarially verified)
> Superseded by the 2026-06-22 run: disabling `server-foundation` breaks spoke imports (see the note at the top).

Ran the `deep-research` workflow (98-agent fan-out: search → fetch 15 sources → 3-vote refutation → cited
synthesis) against the ACM/MCE `/openapi/v2` poison, WITHOUT giving the panel our live-test memory. It
independently reached the same conclusion as our live hub test, raising confidence:
- **THREAD A — disable `server-foundation`: GO (high confidence).** Primary-source-confirmed that the mesh's
  critical path (ManagedCluster registration + OCM Placement/PlacementDecision + ArgoCD cluster secrets) is
  owned by the separate **`cluster-manager`** core (upstream OCM = only cluster/work/addon/operator API
  groups; clusterview/UserPermission are an ACM/MCE add-on), and Foundation depends on Cluster-Manager
  one-way — so the disable cannot break registration/placement/secret generation.
- **Mechanism confirmed at source:** gitops-engine `pkg/cache/cluster.go sync()` loads `/openapi/v2`
  unconditionally + fatally; `ARGOCD_CLUSTER_CACHE_LOAD_OPEN_API_SCHEMA` has ZERO grep matches (the web
  "env-var workaround" is a hallucination — matches our live finding). Same failure class fixed in **Kueue
  v0.17.0** (kueue#8873/#9051) by correcting OpenAPI codegen.
- **THREAD B — fixed MCE/ACM version: UNRESOLVED.** No concrete errata/release identified, so the disable is
  the actionable remedy, not a fallback.
- **Reconciliation with our live test:** the panel hedged that the exact `spec.overrides.components[].name`
  string wasn't on a primary Red Hat docs page (MCE 2.11 docs citation refuted 0-3). Our live test already
  applied `{name: server-foundation, enabled: false}` and it worked (ocm-proxyserver + both clusterview
  APIServices removed, `/openapi/v2` UserPermissionStatus refs 3→0, cluster-manager survived 3/3) — so the
  override key is empirically confirmed and trumps the docs gap.
- **Net:** BLOCKER #1 de-risked to "very likely correct, pending one ROSA-HCP-at-install end-to-end
  confirmation pass" (item #4 above). The fix stays codified (`charts/acm-multicluster-hub` disabledComponents,
  TF `var.acm_disabled_components`, `terraform/platform/scripts/001-openapi-preflight.sh`).

# Backlog

Open work for istio-scale-tests, moved here from GitHub issues (#84, #85, #86, #87, #88, #91) so
it travels with the repo. Status reflects the backlog PR of 2026-10-13 (tasks 2, 3, 5, 6 and 7),
validated on the existing-cluster lab
([`docs/campaigns/2026-10-13-lab-backlog-validation.md`](docs/campaigns/2026-10-13-lab-backlog-validation.md)),
and the ROSA validation window of 2026-10-14 (tasks 1, 3, 4, 6), which also queued the fixes in
section 9 ([`docs/campaigns/2026-10-14-rosa-validation.md`](docs/campaigns/2026-10-14-rosa-validation.md)).
The original issue texts are in the appendix.

| # | Task | Status | Left / validate on |
| --- | --- | --- | --- |
| 1 | Namespace scaling factor (customer: thousands of namespaces, 1–5 services each) | Implemented; validated on ROSA 2026-10-14 with numbers to 6000 discovered namespaces / 8000 Services | per-namespace vs per-Service istiod split on a clean cluster; lab L2-L4; customer questions |
| 2 | Per-cluster connected-proxy count + sanity check (was #85) | Done, lab-validated with 3 istiod replicas | campaign-scale check optional (ROSA) |
| 3 | East-west failures on some clusters (was #86) | Done: CA race confirmed on the lab; AWS LB lifecycle validated on ROSA (always self-heals) | hypothesis H1 (gateway OOM at 10k) against the June records |
| 4 | Capture istiod restart diagnostics (was #87) | Capture done in every suite; validated live on ROSA (smoke, passive, real restart) | lab: node-reboot capture, forced OOM, forced failed capture, pod delete in dataplane and controlplane |
| 5 | Local baseline saturates one server replica (was #88) | Done, lab-validated | — |
| 6 | VirtualService/DestinationRule load in controlplane (was #84) | Done; lab shape, ROSA numbers at 60-250 Services × 2 | convergence p99 question (9.11); thousands of Services |
| 7 | Shared `--config FILE` library (was #91) | Done for controlplane, dataplane, churn, churn-dataplane, propagation | tuning suite (follow-up) |
| 8 | Gateway API multicluster ingress check: does an HTTPRoute need its Service (or its namespace) in every member? | Done, lab-validated 2026-10-14 (22/22 predictions matched) | — |
| 9 | Fixes from the 2026-10-14 ROSA window (17 issues → 12 items) | All 12 implemented 2026-10-16; lab-validated where the lab can (see each item); 9.8/9.9 as recommended, confirmed by the owner 2026-10-16 | ROSA: 9.1 greenfield race, 9.2 under load, 9.8 NLB, 9.9 at campaign scale, 9.11 at 150-250 Services; results backup destination (owner) |

## 1. Namespace scaling factor

**Goal:** tell a customer with several thousand namespaces (one microservice or a handful of related
services each) how namespace count drives istiod and proxy cost.

**What exists:** the controlplane suite sweeps `--namespace-counts` (a fixed number of services
spread round-robin across N namespaces) × service count × replicas × mesh size × Sidecar scoping
(`none`/`namespace`/`explicit`), and reports istiod CPU/memory, xDS pushes, convergence p99 and
per-proxy config size. Multi-namespace runs were broken before #95 (only the last namespace was
created), so older namespace results are invalid.

**Implemented (controlplane growth mode; see
[`tests/controlplane/README.md`](tests/controlplane/README.md#namespace-scaling-growth-mode)):**
- `003 --services-per-namespaces K` growth series: N namespaces × K services (block layout),
  grown in place up the `--namespace-counts` ladder with a `grow` window per step (always under
  `namespace` scoping) and a `probe` window per scoping (`none`, `namespace`, new `wide` = a
  per-namespace `*/*` Sidecar); `--growth fresh` deploys and deletes every cell for the
  in-place-vs-fresh check.
- `--workload-mode config-only`: Services without pods plus M measurement pods;
  `--measurement-pod-counts 4,16` re-probes at the largest N (does istiod heap grow with M?).
- `--outside-namespaces X --outside-modes unlabeled,labeled`: namespaces outside the mesh, with and
  without the discovery label (what `discoverySelectors` saves).
- Memory stop guard (istiod heap and gateway Envoy memory on every member, projected per step;
  `SKIPPED_MEM_GUARD` rows), a namespace-lifecycle TSV (apply/delete rates, HTTP 429s),
  `005 --undiscover --no-delete` so thousands of namespaces leave the mesh without queueing deletes.
- TSV schema 63 (columns 52-63) and a "Namespace scaling" report section in all formats: linear
  fits per 100 namespaces with R², log-log exponent and raw points, one per series (a sweep's
  RUN_ID x mesh size x K x workload, so a base-dir report never mixes series); pods vs
  config-only (required row), M-sweep, discovery and fresh-vs-in-place tables.

**Validated (ROSA, 2026-10-14; numbers in the campaign record):** S1 smoke GO, then R1 (K=1 to
4000 namespaces + 2000 outside), R1b, R2 (K=4), R3 (pods mode) and the extensions X1 (K=4 to 8000
Services, M-sweep) and X2 (6000 discovered). Per 1000: istiod heap about +100 Mi per 1000
namespaces at K=1; east-west gateway clusters +2000 and Envoy memory +143-144 Mi per 1000 **Services**
(K=1 and K=4 alike; ingress +1000 clusters, about +91 Mi); `wide` scoping costs every proxy +5.72 MiB config and +117 Mi Envoy memory per
1000 Services, while `namespace` scoping stays flat (351-369 KiB). `discoverySelectors` keeps
excluded namespaces out of xDS (Services, gateway clusters, root-cert ConfigMaps all +0) but not
out of istiod's informer heap. The pods-vs-config-only row exists: per-proxy figures match;
config-only does not model push fan-out (pushes 38× higher at 250 namespaces with one proxy per pod).
**The east-west gateway, not istiod, is the binding resource** (9.9).

**Left:**
- The per-namespace vs per-Service split of istiod heap (two K values): R2/X1 were confounded by
  thousands of leftover undiscovered namespaces (9.10). Rerun K=1 and K=4 at 1000 and 2000 on a
  clean cluster (lab, or the first series of a ROSA window). This needs a gateway memory limit of at
  least 2Gi first (9.9, or a `gitops_app_overrides` limit as in the window's extension): at 1Gi the
  K=4 N=2000 step (8000 Services) is `SKIPPED_MEM_GUARD`, as in R2.
- Lab: L2 fresh-vs-in-place, L2b guard proof with `--mem-stop-pct 5` (now also for 9.4-9.6), L3 up
  to N=400 / X=200, L4 cleanup. L1's calibration and deletion rate came from ROSA (0.6-2.0
  namespaces/s).
- Not built yet: charts for the growth cells, parallel apply.
- Open for the customer: are all namespaces in the mesh, and do they use Sidecars or a root Sidecar
  today? (`wide`-like scoping at their scale costs each proxy roughly 0.5-1 Gi.)

## 2. Per-cluster connected-proxy count + sanity check (was #85) — done

**Done:** every controlplane row carries `cluster_connected_proxies` (pilot_xds summed over the
cluster's istiod pods from one scrape batch; N/A on a short scrape or a changed pod set),
`sidecar_pods` (Running injected pods) and `proxy_check` (OK/LOW/HIGH against
`CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT` and `_MIN_DIFF`). The report and scale envelope show the
per-cluster peak next to the per-replica peak, plus a proxy-check tally with a warning. The 001
capacity preflight counts only non-terminal pods. The envelope reports the istiod replica count per
cluster (a range when members differ).

**Validated (lab):** with 3 istiod replicas on one member the per-replica values were 7/6/9 and the
per-cluster total 22, equal to the Running sidecar pods; 5 extra pods without proxies gave `LOW`.
This reproduces the campaign's ~1/3 reading as a per-replica value. Real under-connection at 10k
(hypothesis B) can no longer be ruled out retroactively; the next campaign's proxy check will show it.

## 3. East-west failures on some clusters (was #86) — done (CA race on the lab, LB lifecycle on ROSA)

**Confirmed (lab, 2026-10-13):** an istiod that starts before `cacerts` exists runs a self-signed
root and keeps it after `cacerts` arrives (it reads `cacerts` only at startup). Membership stays
`synced` while cross-cluster mTLS fails in both directions: the campaign's signature. Restarting
istiod (then the pods that started meanwhile) recovers it. The PreSync hook from #95 held a fresh
install for 270 s until ESO pushed `cacerts`, and istiod came up on the shared root; the gate flags
the mismatch when it happens.

**Not reproduced on MetalLB:** a released, rebuilt or re-addressed east-west LoadBalancer recovered
within about a second of its address returning, with no gateway restart.

**Harness (done):** dataplane and churn-dataplane check every remote before the load
(`tests/lib/reach.sh`, `reach-<RUN_ID>.tsv`), print a "Remote coverage" section in every report
format, and `--on-unreachable fail` / `--fail-on-unreachable` exit 3. churn-dataplane has
per-cluster `fortio-server-<ctx>` Services and an `ERROR_RATE_HIGH` rule.

**Validated (ROSA, 2026-10-14):** with mutations on one member's east-west gateway only, every
case that replaced or delayed the LB reproduced the June signature (only paths into the bad member
fail, its own outbound keeps working) and healed by itself without a restart: Service recreated
(CLB) 120 s; provisioned late (bogus subnet, held 4.5 min) 103 s after the fix; recreated as an NLB
167-188 s (NLB DNS activation dominates). A rollout restart and scale 1→3→1 behind a CLB or an NLB
caused no failure at all. Recovery waits for the hostname, InService, DNS and then every peer
istiod's `networkz`. The LB lifecycle therefore cannot explain members that stayed broken; the CA
race can, and its `cacerts` wait held on ROSA on a member whose sync was delayed 40 min (9.1).

**Left:** hypothesis **H1**: at 10k Services the east-west gateways need well over their 1Gi limit
(about 1450 Mi, 1.4 GiB, allocated; more after bursts; 9.9), so in June some may have been OOM-killed. Check
the June campaign records and any retained events for gateway restarts or `OOMKilled` before
treating the CA race as the only cause. Confirming #86 at the original 19-cluster scale is still a
20-cluster run.

## 4. Capture istiod restart diagnostics (was #87) — validated on ROSA, lab items open

**Done:** `tests/lib/istiod-diag.sh` saves the evidence when a suite detects an istiod restart.
It runs at every detection point: controlplane 002 (after each window, from the rows it
wrote), dataplane 002, churn 002 (source and remotes), churn-dataplane 002/003 and
propagation 002; tuning runs them. Churn and propagation also capture a pod replaced
between iterations, at the next port-forward re-open (trigger `podset_changed`).
Evidence goes to `istiod-diag-<RUN_ID>/` next to the run's TSV:
- `index.tsv` has one sanitized row per pod: what changed, the cause (`oom_killed`,
  `probe_kill`, `crash`, `killed`, `exited`, `node_restart`, `evicted`, `preempted`,
  `node_lost`, `rollout`, `deleted`, `scaled`, `no_restart_found`), `lastState.terminated`,
  the restart count, the memory limit, and the suite's own pre-window RSS, heap, goroutines
  and proxies.
- One raw folder per capture: the previous container's log, events, Deployment and
  ReplicaSet revisions, node conditions and events, the pre-window `/metrics`, and a
  `summary.md` with the PromQL query for the memory history.

It costs nothing without a restart and is bounded otherwise
(`ISTIOD_DIAG_*` in `config/options.env`). It never changes a row or fails a run. The
dataplane, churn, churn-dataplane and propagation reports show it in text, md and json.
Details are in the dataplane README, "Restart evidence".

**Finding:** the Sail istiod Deployment on the lab has only a readiness probe (no liveness or
startup probe, and the Istio CR has no field for one), so a probe cannot restart istiod as
shipped. That rules out the "liveness timeout" explanation for #87 unless the Deployment was
edited. `probe_kill` stays in the classifier for hand-edited Deployments and is validated
offline only.

**Validate (lab):**
1. Read-only: capture the existing node-reboot evidence on `<mesh-a-ctx>`.
2. Delete an istiod pod during a dataplane, controlplane and churn run on `<mesh-b-ctx>`.
3. Force an OOM with a low memory limit on the Istio CR, under `006-gitops-pause`, then
   restore it with `--resume` and the recovery gate.
4. Force a failed capture with `ISTIOD_DIAG_REQUEST_TIMEOUT=1ms`; the run must continue.

Check each row's cause and that the redaction grep finds nothing. ROSA cannot reproduce the
original 20-cluster × 10k restart.

**Validated (ROSA, 2026-10-14):** the read-only smoke was a GO (`quiet` `no_change`; `forced`
`replaced_gone` + `new_pod` with complete evidence, bounds held, redaction clean); the passive
capture stayed silent through every other suite of the day (no false capture); in a churn run an
istiod pod delete on a remote member was row `POISONED_RESTART` and captured as
`replaced_gone`/`deleted` + `new_pod`/`replacement`, deduplicated as `already_captured` at the next
re-open. The replacement was Ready 11 s after the delete with 6000 discovered Services. Lab items
1, 3 and 4 above, and item 2 for dataplane and controlplane (ROSA covered churn), are still open.

**Follow-ups (task 4):**
- Add the controlplane 004 report section once task 1 has merged (004 is task 1's file).
- Restarts in place between measurement windows (churn scale-down and settle, propagation
  drain) are still not seen; only a replaced pod is, at the next re-open.
- Propagation keeps a timeout or `SCRAPE_INCOMPLETE` status on the row of a replaced pod; the
  index has the cause, but the row is not relabeled `RESTART`.
- churn-dataplane watches the source context's istiod only.
- Fetch the memory history from cluster monitoring automatically (today: the PromQL query
  in `summary.md`).
- Move `reach_sanitize` into `common.sh` once task 1 has merged.

## 5. Local baseline saturates one server replica (was #88) — done

**Done:** `--server-replicas` (`DATAPLANE_SERVER_REPLICAS`, default 2) for the local and remote
targets alike; rows below `--min-qps-ratio` × target are `QPS_SHORTFALL`; the error-rate threshold is
`DATAPLANE_MIN_PCT_200`; fortio parsing lives in `tests/lib/fortio.sh`; the report always prints a
"Local baseline" verdict (OK, or DROPPED/DEGRADED/UNCHECKED/MISSING per cell with the reason).
The separate local-baseline QPS cap was dropped on purpose: it would hide saturation in a different
QPS cell. Runs from 2026-10-13 on are not directly comparable with the June runs (1 server pod).

**Validated (lab):** one starved replica delivered 88% of 1000 QPS and was flagged; two replicas
delivered 999.9 QPS with the local baseline OK at every level.

## 6. VirtualService/DestinationRule load in controlplane (was #84) — done

**Done:** opt-in sweep axis `--traffic-configs none,vsdr` with `--vsdr-every N` and
`--vsdr-subsets N`: a VirtualService (weighted route, timeout, retries) and a DestinationRule
(subsets, connectionPool, outlierDetection) per configured Service, replicas split over one
Deployment per subset. The report pairs none and vsdr cells (istiod cost, per-proxy clusters and
CDS/RDS bytes). The `none` render is unchanged.

**Validated (lab, 10 services):** +20 clusters per proxy (10 × 2 subsets), CDS +115%, RDS +66%.
istiod cost deltas need hundreds to thousands of services (ROSA).

**Validated (ROSA, 2026-10-14, pods mode):** at 150 and 250 Services × 2 on one member, vsdr
added exactly 2 clusters per Service (+300 / +500), CDS +246-255%, RDS +125-128%, config dump
1.40 → 3.60 MiB and 2.11 → 5.78 MiB, istiod heap in use -13% / +37% (RSS +56% / +78%, order-biased
per the report), xDS pushes +23-30%, push time 3-4×; at 60 × 2 per member across two members, CDS
186 → 594 KiB and push time 0.72 → 1.52 ms.
**Left:** the convergence p99 jump at 150-250 Services (9.11); thousands of Services × 2 need more
worker nodes (pod slots: 645 were free on the three nodes) or a `vsdr` config-only mode.

## 7. Shared `--config FILE` library (was #91) — done except tuning

**Done:** `tests/lib/config.sh` parses (never sources) `KEY=value` run configs against a per-suite
allowlist from `config/options.env`; precedence flag > config > env > default, with no change when
`--config` is absent. Every numbered script of controlplane, dataplane, churn, churn-dataplane and
propagation accepts `--config`; TSV preambles and every report format record `RUN_CONFIG` and its
sha256, and each sweep keeps a copy of the config. Worked examples: `tests/<suite>/configs/`.

**Left:** the tuning suite (it chains the other suites), and centralizing the per-script flag
parsers.

## 8. Gateway API multicluster ingress check — done, lab-validated

**Question:** with Gateway API (HTTPRoute), must every member carry the backend Service even
without a local workload, so a request entering any member's ingress reaches the workload? And
must it carry the backend's namespace?

**Done:** `charts/mesh-verify-gateway-api` (deployed with
`charts/mesh-verify-gateway-api-appset.yaml`; routes on every member, echo workload on one) and `tests/gateway-api/001-run-ingress-check.sh`,
which records status, traffic, endpoints and Argo CD health per member and leads its report with
the answers. Predicted from the Istio 1.30.5 source: no Service needed for traffic, but the route's
status says `BackendNotFound` where the Service is missing; with a `kind: Service` backendRef the
namespace is needed (it holds the route or the ReferenceGrant, which istiod reads locally only)
but not the Service (S7 vs S7b), with a `Hostname` backendRef or a classic VirtualService it is not
([`tests/gateway-api/README.md`](tests/gateway-api/README.md)).

**Validated:** on the lab, 2026-10-14: 22 of 22 rows matched
([`docs/campaigns/2026-10-14-gateway-api-multicluster-lab.md`](docs/campaigns/2026-10-14-gateway-api-multicluster-lab.md)).
Argo CD marks every HTTPRoute with `ResolvedRefs=False` as Degraded, so a remote-only backend
routes but keeps its Application Degraded; a Service on every member avoids that.

**Left:** nothing for the lab. Optional: run it on ROSA (it needs two members and no extra
LoadBalancer IP).

## 9. Fixes from the 2026-10-14 ROSA window

The window found 17 issues
([campaign record, "Issues found"](docs/campaigns/2026-10-14-rosa-validation.md#issues-found));
they reduce to the 12 items below (11 open, 9.12 done). Each item names where the fix lands, the
proposed fix, how to accept it, and where it can be tested: **offline** (bats, `--dry-run`,
`helm template`), the **lab** (powered off again since 2026-10-14, after task 8's run; power-on
steps in [`docs/runbooks/existing-cluster-lab/README.md`](docs/runbooks/existing-cluster-lab/README.md)),
or **ROSA** (the next window). The window's raw data (needed to calibrate 9.4 and to analyze 9.11)
is listed in the record's ["Raw data"](docs/campaigns/2026-10-14-rosa-validation.md#raw-data).

**Suggested PRs and order:**
- **A** = 9.1 and **B** = 9.2: independent of everything else.
- **C** = 9.3-9.7, the harness: `003`, `tests/lib/growth.sh`, `tests/lib/fit.sh`,
  `tests/lib/capacity.sh`, `001` auto-sizing, `002` + `004` + their bats for 9.5's schema bump,
  `config/options.env`, and the README / window-plan schema notes.
- **D** = 9.8 + 9.9, after the owner decisions and after C (9.9 is accepted with 9.5's guard).
- **E** = 9.10 + 9.11, after C: 9.10 shares `003`, `004` and the growth preamble with C; 9.11 shares
  `001`, `002` and `003`'s legacy cell loop with C.

**Owner decisions pending:** 9.8 (NLB for the ingress), 9.9 (gateway memory defaults), and where to
copy the window's results off the operator laptop.

**Status 2026-10-16:** every item below is implemented (one branch, one commit per area); the
owner confirmed 9.8 and 9.9 as proposed. Each item ends with **Done**,
**Validated** and **Left**. The same pass fixed the report errors an audit of the window's
reports found: istiod "CPU avg" was a per-window peak, "KB"/"MB" were KiB/MiB, the SLA headline
and envelope read istiod CPU from one end-of-window `kubectl top` snapshot, two-point fits
printed R² 1.000, exponents leaked into tables and JSON, config-only cells claimed endpoints, and
the churn, churn-dataplane, dataplane, propagation and tuning reports averaged N/A as 0 or
bucketed means of p99s (all fixed, with bats; the window record's units are corrected). Lab
validation also found the capacity plan ignoring the CPU other pods request (fixed under 9.7).
**Lab caveat:** the workstation's resolver failed over from the lab DNS twice mid-run; the lab
runs used a scratch kubeconfig that pins the API addresses (`tls-server-name` keeps TLS valid).

### 9.1 Argo CD leaves a member without a controller shard (finding 1) — fix decided

- **Seen:** right after the platform apply, every cluster logged "has no assigned shard" (OpenShift
  GitOps, `consistent-hashing`, 2 controller replicas, `dynamicScalingEnabled`); two members and the
  hub were picked up later, one member never was. Its 6 Applications had empty sync/health status
  for 35 min and 4 PushSecrets failed (`namespaces "istio-system" not found`) as a consequence. The
  controller start that logged it was the operator's own dynamic-scaling restart, seconds after
  Terraform created the cluster secrets. A manual restart of the
  `openshift-gitops-application-controller` pods made the member's Applications reconcile within
  30 s; all 40 Applications were Synced/Healthy about 6 min later (the PushSecrets retry every 5 min).
- **Where:** `terraform/platform/platform_gitops.tf` (the `local-exec` that runs
  `terraform/scripts/create-argocd-cluster-secret.sh`, around line 451) and a step after the last
  cluster secret.
- **Fix (owner decision, 2026-10-14):** once every cluster secret exists, first wait for the
  operator's own dynamic-scaling reconcile to finish (the application-controller StatefulSet at its
  expected replica count, `oc rollout status` complete), then restart the controller pods and wait
  for Ready. **Proposed addition (not part of the decision):** a post-apply check that fails when an
  Application still has an empty sync or health status after a timeout of at least 10 min, naming
  the destination cluster.
- **Accept:** a fresh ROSA apply converges with no manual step. **Test:** offline (`terraform
  validate`, a script dry run); lab, mechanics only unless 2 controller shards are forced (the lab's
  3 Argo CD clusters fit one shard at `clustersPerShard` 3: set `minShards` 2 or `clustersPerShard` 1
  through `argocd_config_values`), then re-register a member by deleting and recreating its cluster
  secret; ROSA next window.
- **Done:** `terraform/scripts/argocd-controller-reshard.sh` (MODE=reshard) runs after the last
  cluster secret and before the placement generator: it waits for the controller StatefulSet to
  settle (Ready at its replica count, rollout complete, three polls in a row), deletes the
  controller pods once and waits for Ready replacements. MODE=app-status runs at the end of the
  apply and fails after `argocd_app_status_timeout_sec` (900, 0 disables) naming every
  Application with an empty sync or health status and its destination cluster. Switch:
  `argocd_restart_controller_after_cluster_secrets`. **Validated:** stub-kubectl bats (settle,
  terminating pods, stale pods, replacements never Ready, app-status pass/fail/empty); live on the
  lab hub (1 shard, settled in 3 polls, replacement Ready, all 30 Applications with status).
  **Left:** the race itself needs a greenfield ROSA apply (the lab was not forced to 2 shards: the
  hub's memory would not hold 2-3 controller replicas).

### 9.2 Kubeconfig exec plugin logs in on every `oc` call (finding 2)

- **Seen:** `oc-token-exec-credential.sh` does a full OAuth password login per invocation (no
  `expirationTimestamp`, no cache). The harness runs thousands of `oc` processes: 3843
  OAuthAccessTokens on one member at 19:37 UTC, and intermittent `failed to obtain OAuth token`,
  which broke a series retire (9.3) and a probe-namespace retire.
- **Where:** `terraform/scripts/oc-token-exec-credential.sh` (its arguments are only
  `<api_server_url> <username> <password>`); the kubeconfig exec block in
  `terraform/rosa-hcp/outputs.tf` (around lines 87-91).
- **Fix:** cache the token per API server and user in a 0600 file under
  `${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/oc-token-cache/`, never inside the repo (a repo-local path
  would need a `.gitignore` entry in the same change: no secrets in git). Write it atomically, reuse
  it until shortly before the `expires_in` the OAuth redirect returns, return
  `status.expirationTimestamp`, and retry the login a few times with backoff before failing.
- **Accept:** 1000 consecutive `oc get ns` create at most one new OAuthAccessToken; a full sweep has
  no auth error. **Test:** offline bats with a stubbed `curl`; ROSA next window.
- **Done:** as proposed: cache key sha256(API server, user, password; the password is never
  written), 0600 file in a 0700 dir under `${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/oc-token-cache`,
  atomic write, reuse until 300 s before `expires_in`, `status.expirationTimestamp`, a mkdir lock
  (a dead owner's lock is broken), 4 login attempts with doubling backoff; `OC_TOKEN_CACHE=0`
  restores the old behaviour. **Validated:** bats with a stubbed `curl` (50 calls → 1 login, 8
  parallel callers → 1 login, retries, margin, no password on disk). **Left:** ROSA (the lab
  authenticates with client certificates): count OAuthAccessTokens after a sweep.

### 9.3 A failed series retire passes silently (finding 3)

- **Seen:** R1b's `g_retire` → `005 --undiscover` failed on an auth error; `003` printed a warning
  and exited 0, and the next series (R2) started with 2000 extra namespaces discovered. It was
  stopped within seconds, before any cell, undiscovered by hand and rerun.
- **Where:** `tests/controlplane/003-run-sweep.sh` `g_retire()` (around line 1452) and
  `004-report-results.sh` `STATUS_RE` (line 714). Today bats runs 003 live only against an empty
  kubeconfig in legacy mode, which never reaches `g_retire`, and 003 calls 005 through a fixed path.
- **Fix:** add a bounded retry and a check that no namespace of the series still carries
  `istio-discovery` or `istio.io/rev` into a sourced lib function (for example in
  `tests/lib/growth.sh`) that takes the cleanup command as arguments; `g_retire` calls it and fails
  the sweep (non-zero, a `RETIRE_FAILED` status row that `STATUS_RE` recognizes) so no later series
  runs on a contaminated baseline.
- **Accept:** bats on that function with a failing 005/kubectl stub → non-zero; a 004 bats fixture
  with a `RETIRE_FAILED` row → reported; a growth-mode live run against an empty kubeconfig exits
  non-zero with a `RETIRE_FAILED` row. **Test:** offline; lab (point the retire at an unreachable
  context).
- **Done:** `growth_retire_verified` (`tests/lib/growth.sh`) runs the cleanup and checks that no
  namespace of the series carries `istio-discovery` or `istio.io/rev`, `CONTROLPLANE_RETIRE_ATTEMPTS`
  (3) times; on failure 003 records `RETIRE_FAILED` (window `retire`), runs no later series and
  exits 1 after its report, and every report format warns. `--growth fresh` verifies each cell's
  delete the same way; `--series-retire keep` with more than one series is refused. **Validated:**
  all three acceptance tests (bats); live, twice by accident: the workstation lost the lab API's
  DNS mid-run and both sweeps stopped with `RETIRE_FAILED` and exit 1; a normal lab series retired
  and verified cleanly. **Left:** —

### 9.4 Memory guard: stale base and unguarded first step (findings 4, 15)

- **Seen:** the guard projects `base + (current - base) × ratio^power` from the series-start memory
  (`mem_guard_project` in `tests/lib/fit.sh`). (a) Envoy kept about 500 Mi after a series was
  undiscovered, so a later series' base was inflated and its 8000-Service step would have been
  under-projected (beyond the 1Gi limit). (b) The first step has ratio 1 (the code comment says so),
  so it is never projected: X1's 0 → 4000-Service step read 9 Mi and ran, and left a working set of
  1075-1119 Mi, above the original 1Gi limit.
- **Where:** `003-run-sweep.sh` `guard_baseline()` / `guard_check()` (around lines 1222-1282) and
  `tests/lib/fit.sh` (`mem_guard_project`).
- **Fix:** add an absolute projection next to the relative one, as a function in
  `tests/lib/fit.sh`: memory ≈ intercept + per-Service cost × discovered Services after the step ×
  burst factor, with per-gateway keys in `config/options.env` (east-west
  `CONTROLPLANE_EWGW_MI_PER_1000_SVC=145` and `CONTROLPLANE_EWGW_BURST_FACTOR` (measured 1.7-2.9);
  ingress `CONTROLPLANE_INGW_MI_PER_1000_SVC=91`, factor about 1.2 (working set 1.14-1.17× allocated, no burst
  retention); intercept about 10 Mi). Stop when
  either projection crosses the limit; warn when the base reading is far above the absolute model
  (stale gateway memory) and recommend a gateway restart.
- **Accept:** bats cases for a first step and an inflated base. **Test:** offline; lab L2b
  (`--mem-stop-pct 5`, a one-step series).
- **Done:** `mem_guard_project_abs` and the gateway branch of `guard_check`: projected =
  max(relative, absolute), absolute = (intercept + Mi per 1000 Services × (istiod
  `pilot_services` + Services the step adds) / 1000) × burst factor, plus the container's
  non-heap memory (working set − Envoy physical heap) for a working-set reading. Keys:
  `CONTROLPLANE_GW_MI_INTERCEPT` (10), `CONTROLPLANE_EWGW_MI_PER_1000_SVC` (145),
  `CONTROLPLANE_EWGW_BURST_FACTOR` (2.0), `CONTROLPLANE_INGW_MI_PER_1000_SVC` (91),
  `CONTROLPLANE_INGW_BURST_FACTOR` (1.2). A gateway whose Envoy allocated memory at the series
  start exceeds 1.5 × the model + 100 Mi prints a WARNING (restart the gateways) and a
  `stale_base` guard row. **Validated:** bats; lab L2b: `--mem-stop-pct 5` skipped the first step
  (0 → 500 Services) on every component; lab ladder 500 → 1000 → 2000 Services: the absolute
  projection stopped the 2000 step on the remote member's east-west gateway (770 Mi projected vs
  717 Mi = 70% of 1Gi; working set then 359 Mi). The first version compared the working set with
  a heap-only model and flagged the 40-200 Mi outside Envoy's heap as stale memory; fixed before
  commit. **Left:** the model is conservative at small scale (about 250 Mi above the measured
  working set at 2000 Services); recalibrate the factors on ROSA.

### 9.5 Memory guard and fits measure allocated memory, not the working set (finding 16)

- **Seen:** the guard and `gateway_mem_mi` read Envoy `server.memory_allocated`
  (`tests/lib/growth.sh` `growth_envoy_stats`); istiod uses Go `heap_inuse`. The OOM killer acts on
  the container working set, which on east-west gateways ran 1.2-2.9× the allocated figure (1.7-1.9×
  after X1's 0 → 4000 burst, 2.6-2.9× after X2's 4000 + 2000 bursts; tcmalloc keeps freed memory), and istiod RSS ran about 2× `heap_inuse`.
- **Where:** `tests/lib/growth.sh`, the guard in `003`, the growth columns of `002`, `004` and the
  bats that count growth columns and preamble keys; also `003`'s own schema copy
  (`CONTROLPLANE_TSV_HEADER`, `emit_failed_row`, its `CONTROLPLANE_SCHEMA` marker), 002's marker, and
  `004`'s width partition (keep 63 as a supported older width).
- **Fix:** guard on the working set (`oc adm top` / `container_memory_working_set_bytes`, or Envoy
  `server.memory_physical_size` as a proxy) against the limit; keep allocated as the fit metric and
  record both (a TSV schema bump with new columns; the report labels each).
- **Accept:** guard log lines show both figures and stop on the working set; bats for the parser and
  the new columns. **Test:** offline; lab burst (9.9).
- **Done:** the guard reads istiod RSS (`process_resident_memory_bytes`) and each gateway's
  istio-proxy working set (`kubectl top --containers`; else Envoy `server.memory_physical_size`,
  else `server.memory_allocated`), and its TSV (`GUARD_SCHEMA=2`) names the metric. TSV schema 66
  adds `gateway_physical_mi_max` and `gateway_ws_mi_max`; allocated stays the fit metric; 004
  fits and labels all three. **Validated:** bats; lab: every guard row read `ws`, the TSV carried
  allocated / physical / working set (80 / 107 / 206 Mi at 500 Services on the measured member).
  **Left:** —

### 9.6 Memory guard misses members without `--config` (finding 5)

- **Seen:** without `--config` or `--mem-guard-contexts`, the guard samples `--contexts` plus the
  `SETUP_CONTEXTS` default from `config/versions.env` (2 members); the third member's istiod and
  gateways were not sampled until `--mem-guard-contexts` was passed. The dry run already prints the
  guard set, but it cannot know about a member the configuration does not name.
- **Where:** `003-run-sweep.sh` (guard contexts, around line 920); `config/versions.env`.
- **Fix:** in a live run, list the members from the `istio/multiCluster` remote secrets on the
  measured context (`istio-remote-secret-<cluster>`; context names equal the cluster names) and add
  the missing ones to the guard set, or warn. The dry run keeps printing the configured set.
- **Accept:** a live lab run with neither `--config` nor `--mem-guard-contexts` guards (or warns
  about) every member; offline bats on the parser that turns a remote-secret list into contexts.
- **Done:** `growth_mesh_members` (the `networking.istio.io/cluster` annotation, else the secret
  name); a live growth sweep adds every member with a kube context of that name and stops when one
  has none (with `--mem-guard-contexts` it warns instead). **Validated:** bats; lab, with
  `SETUP_CONTEXTS` set to the measured member only: "added mesh member(s) <other member>", and the
  guard sampled its istiod and both gateways. **Left:** —

### 9.7 Capacity planner ignores real requests (finding 6)

- **Seen:** the planner multiplies pods by `SCALE_PER_POD_CPU_M=200` and warned "~46 services max"
  for 250 × 2, which fit easily: the dummy app requests nothing and the sidecar requested 20m. (A run
  config with `SCALE_PER_POD_CPU_M=20` already gives the right estimate; the fix removes the need.)
- **Where:** `003-run-sweep.sh` `capacity_plan_warn` (around line 785), `001`'s auto-sizing
  (`PER_POD_CPU_M`), `tests/lib/capacity.sh` (a shared reader), `config/options.env`.
- **Fix:** in live runs, read `spec.values.global.proxy.resources.requests.cpu` from the Istio CR
  plus the rendered pod's own requests, falling back to `SCALE_PER_POD_CPU_M`.
- **Accept:** a live run prints pods × the Istio CR's proxy request: about 50 cores for 500 pods on
  the lab's default (100m), about 10 with ROSA's 20m override; offline bats on the Istio CR reader.
  The `options.env` default becomes empty so the fallback can tell "unset" apart; decide whether an
  explicit `SCALE_PER_POD_CPU_M` in a run config overrides the live reading.
- **Done:** `cap_proxy_requests` / `cap_per_pod_requests` (`tests/lib/capacity.sh`): the first
  Istio CR's `spec.values.global.proxy.resources.requests` (CPU and memory), Istio's 100m / 128Mi
  when unset, used by 003's plan and 001's auto-sizing. `SCALE_PER_POD_CPU_M` / `_MEM_MI` default
  empty; a set value wins (precedence flag > config > env) and the plan names the live value next
  to it. One shared quantity parser now reads decimal suffixes too (`8G` broke the old jq).
  Found in lab validation: the free side was wrong too. The plan took allocatable minus istiod's
  limit on the first context (17.5 of 19.5 cores on the lab hub) while other pods already requested
  14.6, so 30 × 2 "fit" and 11 pods stayed Pending until the 300 s wait recorded SETUP_FAILED.
  `cap_requested` now sums what non-terminal pods on the workers request (the scheduler's rule for
  init and native-sidecar containers, plus overhead); the plan checks every member against
  allocatable minus the other pods' requests and names the tightest, and 001 refuses a step whose
  pods' requests do not fit (`SCALE_CPU_PREFLIGHT_ENFORCE=0` only warns, for a node autoscaler).
  The capacity wrappers no longer end a `set -e` caller when kubectl fails.
  **Validated:** bats (parser, wrapper, 001 against a stub cluster); lab: "per pod: istio-cr on
  <member>", 100m. **Left:** ROSA: the 20m override should read 20m.

### 9.8 Classic LBs break HTTP through the ingress gateway on AWS (findings 7, 11) — decided 2026-10-16

- **Seen:** through a Classic LB the ingress gateway receives each HTTP request followed by a FIN
  0.01 ms later and aborts it; clients get no response. The failing members varied over the day.
  The same gateway behind an NLB answered 36/36; east-west (mTLS passthrough) was unaffected on CLBs.
  Mesh checks through the ingress fail intermittently on ROSA as a result.
- **Where:** no chart change needed: `charts/spoke-ingress-gateway` already takes
  `service.annotations`; set `service.beta.kubernetes.io/aws-load-balancer-type: nlb`. Docs: the
  root README "Verify" and `docs/runbooks/rosa-validation/README.md` "Verify and recover".
- **Decision needed:** make it the default in rosa mode (`terraform/platform`, when
  `cluster_provider = "rosa"`), or only document the override? A rosa-mode default must be its own
  values document in `helm_release.gitops_hub_app_of_apps`, placed before the user overrides so Helm
  deep-merges it with any `spoke-ingress-gateway-appset` override: `gitops_app_overrides` goes to the
  app of apps as is, Terraform's `merge()` is shallow, and a later `-var-file` replaces the whole map.
  On an existing deployment the ingress Service must be recreated to move from CLB to NLB. Also:
  should the east-west gateway move to NLB too (no failure seen; slower DNS activation, 152 s vs
  97 s)?
- **Accept:** on ROSA, mesh-verify through every member's ingress answers 100% for 10 min.
  **Test:** offline `helm template`; ROSA only.
- **Done (owner confirmed 2026-10-16):** rosa-mode default `rosa_ingress_nlb = true` in
  `terraform/platform`: its own values document before `gitops_app_overrides`, so Helm deep-merges
  an override of the same app into it; east-west stays on a Classic LB (no failure seen). README
  "Per-environment values" says how to switch an existing CLB Service (delete it once).
  **Validated:** `helm template` of the app of apps with the default and a MetalLB override
  renders both annotations; `terraform validate`. **Left:** ROSA (the accept test above).

### 9.9 Gateway memory sizing (findings 8, 14, 17) — decided 2026-10-16

- **Seen:** east-west gateway Envoy memory is +143-144 Mi allocated per 1000 discovered Services (2
  clusters per Service), whatever the namespace shape; the ingress gateway about +91 Mi (1 cluster per
  Service). The east-west gateway also keeps memory after config bursts: one 0 → 4000-Service step
  left a working set of 1075-1119 Mi (1.05-1.09 GiB) against 581-633 Mi allocated (no working set
  was sampled for R1's gradual growth, which reached 582 Mi allocated); after 4000 + 2000 bursts the
  working set was 2252-2514 Mi (2.20-2.46 GiB, 73-82% of a 3Gi limit) with about 0.9 GiB allocated
  and the tcmalloc heap at the limit. The ingress gateway tracked its live data. With the charts' 1Gi
  limit the mesh tops out near 5000 Services, and a burst of a few thousand exceeds it.
- **Where:** `charts/spoke-east-west-gateway/values.yaml` and
  `charts/spoke-ingress-gateway/values.yaml` (`resources.limits.memory: 1024Mi`); docs sizing.
- **Decision needed:** the default limits. The chart defaults are sized for the 20-cluster / 10k
  campaign (AGENTS.md), which needs about 1450 Mi (1.4 GiB) allocated on the east-west gateway, more
  with bursts. Proposal: east-west 4Gi limit / 1Gi request, ingress 2Gi limit, plus a sizing rule in
  the docs (about 145 Mi per 1000 Services allocated on the east-west gateway, about 91 Mi on the
  ingress, times 2-3 for burst headroom on the east-west gateway).
- **Investigate:** whether Envoy can release memory after bursts (tcmalloc release rate, an overload
  manager with a fixed-heap monitor) so the limit can track live data; then hypothesis H1 (task 3).
- **Accept:** a burst test (0 → N Services in one step vs a ladder) stays under the new limit with
  9.5's guard; a campaign-scale run without a gateway restart. **Test:** lab (burst reproduction at
  a few thousand Services; the lab gateways should show the same retention if it is Envoy-side),
  ROSA.
- **Done (owner confirmed 2026-10-16):** chart defaults east-west limit 4Gi / request 1Gi,
  ingress limit 2Gi; the sizing rule is in both charts' values and `docs/scale-test-campaign`
  ((10 + 145 × Services / 1000) Mi × 2.5 east-west, × 1.5 ingress with 91 Mi). **Validated (lab,
  1Gi limits, gateways restarted before each run):** 1000 Services in one step vs a ladder
  (200 → 400 → 1000) on the measured member: allocated 152 Mi both, physical 200 vs 184 Mi,
  working set 239 vs 219 Mi. The burst keeps more memory, as on ROSA, but only about 9% at this
  size (ROSA: 1.7-1.9× at 4000). The lab cannot go further: at 1Gi the guard stops the 2000-Service
  step (9.4), and the charts' new limits reach the lab only after merge. **Left:** whether Envoy
  can release the retained memory (tcmalloc release rate, overload manager); the burst at
  campaign scale on ROSA; hypothesis H1 (task 3).

### 9.10 Leftover undiscovered namespaces distort later series (finding 13)

- **Seen:** the window never deleted test namespaces (by design: deletion queues). Thousands of
  undiscovered namespaces stayed in istiod's informer cache and in the remote watches of the other
  members; later series ran with inflated istiod heap (587 Mi at N=1000 in R1b and 798 Mi at N=40
  in the calibration, against 192 Mi at N=1000 in R1), so their absolute istiod numbers and the
  per-namespace vs per-Service split are unreliable. Deltas within a series stay valid.
- **Where:** method (window-plan, runbook); `003` at each series start (`run_growth_series` /
  `guard_baseline`); `tests/lib/preamble.sh` `growth_preamble_lines` (the growth TSV keys; not
  `write_preamble`); `004`.
- **Fix:** count the test namespaces (the controlplane-test selector; discovered and undiscovered) at
  the start of every series and record the count per series (a namespace-lifecycle row: `ns_lifecycle_row`
  already has series, namespaces and status columns, so no controlplane TSV bump is needed; or a
  column carried in C's 9.5 schema bump), plus the run-start count in the preamble; the report warns
  above a threshold. Plan clean-cluster series for absolute numbers (delete between series when time
  allows: 0.6-2.0 namespaces/s), and run the K split first on a fresh cluster.
- **Accept:** the per-series count recorded and a report warning above the threshold. **Test:**
  offline (bats fixtures); lab.
- **Done:** a live growth sweep counts the test namespaces on the measured members first: a
  discovered one stops it, undiscovered ones above `CONTROLPLANE_LEFTOVER_NS_WARN` (100) warn
  (preamble `LEFTOVER_TEST_NAMESPACES`, `LEFTOVER_NS_WARN`); each series start is a
  `leftover-check` row in the namespace-lifecycle TSV; every growth row carries
  `leftover_test_namespaces` (schema 66, namespaces not of this series); 004 warns in every format
  above the threshold. **Validated:** bats; lab: 126, 376 and 626 leftovers recorded per series
  and per row, with the warning in the sweep log and every report format; after a
  `--series-retire keep` sweep, the next sweep stopped before its first cell (5 discovered
  namespaces on the measured member, exit 1). **Left:** plan
  clean-cluster series on ROSA for absolute numbers (unchanged).

### 9.11 VS/DR convergence p99 at 150-250 Services (finding 12) — analysis first

- **Seen:** in both P4a `vsdr` cells the `pilot_proxy_convergence_time` p99 bucket jumped from
  100-1000 ms to 10-20 s, and `pilot_proxy_queue_time` p99 jumped to the same bucket; at 60 Services
  across two members convergence rose only from 0-100 ms to 100-500 ms. The queue time points at
  push queueing in istiod (debounce, push throttle) as well as proxy startup.
- **Where:** `tests/controlplane/002-collect-resource-metrics.sh` (convergence from the histogram
  delta, around line 1416); the `vsdr` render: VS/DR in
  `tests/controlplane/chart/templates/traffic-management.yaml`, the per-subset Deployments in
  `dummy-deployment.yaml`; `003`'s legacy cell loop (002 baseline → 001 → 002 final). 001 renders the
  chart once and applies it in batches, so today the subset pods start while the VS/DR already exist.
- **Next:** add a two-phase `vsdr` apply (for example `001 --parts traffic`, applying VS/DR after
  the subset Deployments are Ready, with 002's baseline taken in between; today any `--parts` other than `all`
  is growth-only and growth mode rejects `vsdr`, so `--parts traffic` must be allowed in legacy mode
  for `vsdr`), or document a manual split apply; then rerun `vsdr` on the lab at 50 / 100 / 150 Services. A fix only if it is a harness
  artifact.
- **Done:** `003 --vsdr-apply split` (`CONTROLPLANE_VSDR_APPLY`, default `together`): `001 --parts
  workloads` (everything but the VS/DR, Ready) before the baseline, then the window covers only
  `001 --parts traffic`; rows carry `window_kind traffic` and the preamble `VSDR_APPLY`; the `none`
  cell's window is idle over the same workloads, so the VS/DR effect table reads as the VS/DR cost
  alone ("(split apply)"). **Validated:** bats; lab, 20 Services × 2 replicas on two members (the
  hub's free CPU caps it near 24): `together` vsdr convergence p99 0-100 ms on both members (as
  `none`), 866 pushes; `split` 0-100 ms on one member and 100-500 ms on the other, 208 pushes,
  istiod CPU peak 12 → 46 m for the VS/DR alone. Nothing at this size reproduces the jump.
  **Left:** ROSA: both modes at 150-250 Services to tell a harness artifact from a real cost.

### 9.12 Plan and doc corrections (findings 9, 10) — done in the window-record PR

The 63-field header, the missing east-west HPA, `--mem-guard-contexts`, the retire check and the
gateway resets are now listed at the top of
[`window-plan.md`](docs/runbooks/rosa-validation/window-plan.md).

## Follow-ups found during the 2026-10-13 work

- churn suite: `source/remote_connected_proxies` use the lenient `fanout_gauge_sum`, which
  undercounts silently when a pod scrape fails (PL29); switch to `fanout_gauge_sum_strict`.
- churn-dataplane: adopt the dataplane `--server-replicas` knob and the `QPS_SHORTFALL` rule.
- Propagation: use a VS/DR change (route weight flip) as a propagation trigger.
- Local baseline verdict checks delivered QPS and errors, not tail latency (two throttled replicas
  were OK with a 31 ms local p99).
- Scale envelope: optional mesh-wide proxy total (sum of per-cluster totals per scrape window).
- controlplane 001 `--dry-run` needs a reachable cluster (server-side dry-run apply).
- Dataplane local-baseline verdict still reads "OK at every QPS level" when a mesh size has OK
  local cells plus a failed repetition's placeholder (the placeholder is named next to it).
- churn-dataplane records `ISTIOD_REPLICAS` for the source context only (what its probe measures);
  the controlplane suite now probes every context.
- `reach_sanitize` masks an unbracketed IPv6 address without `::` only from 4 groups on (a
  3-group form is indistinguishable from HH:MM:SS).
- `PROPAGATION_METRICS_TIMEOUT` is not checked up front by the propagation sweep.
- `charts/spoke-ossm/templates/tuning-sidecar.yaml` says the gateway `workloadSelector` Sidecars
  "take precedence", but Router proxies (gateways) never select a Sidecar in Istio 1.30.5
  (`pilot/pkg/model/push_context.go:1178-1195`), so the two exemption Sidecars are inert and PL38's
  premise needs re-checking against the deployed version (found by the Gateway API check's review).
- controlplane `--resume` treats two `unknown` config hashes (no sha256 tool) as equal.

## Validation environment

The lab covered tasks 2, 3 (except AWS load balancers), 5 and 6 at small size, and task 8. The ROSA
window of 2026-10-14 (Tier C: a hub plus 3 members; about $82, torn down and audited clean; plan in
[`docs/runbooks/rosa-validation/window-plan.md`](docs/runbooks/rosa-validation/window-plan.md))
covered task 3's AWS load balancers, task 6 at 60-250 Services, task 4 live and task 1's numbers.

**Lab, once powered on** (one suite at a time, as on ROSA):
1. Task 4: the node-reboot read-only capture, a forced OOM (low Istio CR limit under
   `006-gitops-pause`, then `--resume`), a forced failed capture
   (`ISTIOD_DIAG_REQUEST_TIMEOUT=1ms`), an istiod pod delete during a dataplane and a controlplane run.
2. Task 1: L2 fresh-vs-in-place, L2b guard proof, L3 to N=400 / X=200, L4 cleanup; the K=1 vs K=4
   split on a clean cluster (9.10), with the gateway limit raised first (9.9).
3. Fix verification: 9.1 (re-register a member), 9.3 (failing retire), 9.4-9.6 (guard with
   `--mem-stop-pct 5` and a one-step burst), 9.9 (gateway burst retention: 0 → N Services in one
   step vs a ladder), 9.11 (`vsdr` at 50-150 Services).

**ROSA only** (next window, after the fixes): 9.2 (exec plugin), 9.8 (ingress NLB), 9.1 on a
greenfield apply, the 9.9 limits under a campaign-sized burst, and optionally task 8. Reproducing
task 4's original restart or task 3 at the original scale still needs a 20-cluster run (about $26/h
with 2× m7i.xlarge members, about $248/h shaped like the June campaign).

---

## Appendix: original issue texts

### Original issue #85: investigate: controlplane connected_proxies reads ~200/cluster at 10k (expected ~500); mislabeled 'mesh-wide'
#### Observation

In the 2026-06-22 20c/10k campaign (controlplane sweeps `sweep-20260622T165640Z` / `sweep-20260622T174414Z`), the `connected_proxies` metric read **~186–207 per cluster** (one value per context row in the controlplane TSV; max 207).

Two problems:

1. **The value is too low.** Each cluster ran **500 Services × 1 replica = ~500 sidecar-injected workload pods**, so each cluster's istiods should see **~500 connected proxies** (one `pilot_xds` connection per proxy). We observed **~200/cluster** — roughly **1/3** of expected, which is suspiciously close to **500 ÷ 3 istiod replicas ≈ 167**.

2. **The scale-envelope mislabels it.** `tests/lib/envelope.sh` renders `connected_proxies_max` as the **'mesh-wide proxy count'**, but it is a **per-cluster (peak)** value, not a mesh-wide sum. Mesh-wide there are ~10,000 sidecars. (This number was **dropped from the customer brief** for being confusing/incorrect — Red Hat → <customer> 20c/10k validation.)

#### Hypotheses to test
- **(A) Scrape/fan-out artifact (most likely):** `pilot_xds` is a per-istiod-pod gauge; a single scrape sees only ~1/replicas of a cluster's proxies. `tests/lib/fanout.sh` intends to `extract_gauge_sum` per pod and **sum across pods** (see comments ~L8/L32/L396), but the observed ~200 ≈ 500/3 suggests the **cross-replica summation is not actually capturing all 3 istiod replicas** (e.g. only one replica scraped, or port-forward fan-out missing pods).
- **(B) Real under-connection:** not all 500 sidecars per cluster were connected/synced at the 10k peak (genuine finding — would matter for scale claims).
- **(C) Fewer proxies than assumed:** the controlplane chart deploys fewer sidecar'd pods than services×replicas (verify the chart).

#### Where to look
- `tests/lib/fanout.sh` — the `pilot_xds` gauge collection + cross-pod summation.
- `tests/lib/metrics.sh` — `extract_gauge_sum`.
- `tests/controlplane/002-collect-resource-metrics.sh` — how `connected_proxies` is assembled per row.
- `tests/lib/envelope.sh` — the 'mesh-wide proxy count' label (fix to 'per-cluster peak').

#### Outcome
Determine whether ~200 is a measurement artifact (A/C — fix the metric + the envelope label) or a real connection gap (B — a scale finding). Either way, correct the scale-envelope wording so the number is honest, and add a sanity check (connected_proxies vs scheduled sidecar pods).

Filed from the campaign retrospective.



### Original issue #86: investigate: cross-cluster east-west data-plane fails on 7 of 19 clusters (007-012, 014) — 12/19 coverage, root cause unconfirmed
#### Observation

In the 2026-06-22 20c/10k campaign, the **data-plane** and **churn-dataplane** suites captured valid cross-cluster traffic for only **12 of 19 remote clusters** — both runs. The same 7 clusters failed every time: **cluster-007, 008, 009, 010, 011, 012, 014**.

- Their **control-plane membership was healthy** throughout (`istioctl remote-clusters` synced; gateways/LBs showed Ready).
- Yet **cross-cluster mTLS traffic through their east-west gateway load balancers failed** (no latency data returned).

#### Best hypothesis (NOT confirmed)

The 7 failing clusters are exactly the ones whose **east-west gateway LoadBalancer Services were (re)provisioned late** — after the AWS Classic-ELB quota was raised mid-campaign — **and** were churned by the gateway HPA→fixed-replica pin. This points to a **load-balancer target-registration / SNI-passthrough artifact** on the reprovisioned ELBs, i.e. the NLB/ELB never (re)registered the gateway pod targets after the Service was rebuilt.

Suspected remediation: **re-register the LB targets / restart the east-west gateway pods** on the affected clusters (NOT istiod — istiod was healthy). This was **left unconfirmed at teardown** (out of budget), so it remains a hypothesis.

#### Why it matters

- It silently halved-ish the cross-cluster data-plane coverage and forced the customer brief to caveat 12/19.
- If it is a real reprovision/registration race, it can recur on any campaign that raises LB quota mid-run or churns gateways.

#### Asks
1. **Reproduce**: provision a spoke's east-west gateway LB *late* (or delete+recreate the Service) and check whether cross-cluster traffic registers without a gateway-pod restart.
2. **Confirm or refute** the LB-target-registration hypothesis (compare target groups / endpoints on a healthy vs failing cluster).
3. **Harness**: make the data-plane / churn-dataplane suites **surface partial coverage loudly** (e.g. fail or warn with the list of unreachable remotes) instead of silently returning n_valid<n_total.

Filed from the 20c/10k campaign retrospective. Related: bare-Services traffic-management gap #84.



### Original issue #87: investigate: istiod restarted mid-run during churn convergence sweep (POISONED_RESTART) at 20c/10k
#### Observation

In the 2026-06-22 20c/10k campaign, the **churn convergence** sweep (`tests/churn/results/sweep-20260622T221037Z-3665828`) recorded **iteration 3 as `POISONED_RESTART`** — istiod actually restarted mid-iteration (a ~345s recovery gap before iteration 4). 5 of 6 completed iterations were valid; iteration 3 was correctly excluded.

#### Why it's worth a look

- istiod **RSS at the 10k peak was only ~19%** of the 16 GiB limit, so this was **not** a memory-ceiling OOM — the cause is unclear.
- The campaign results doc attributed that churn run's low n to the `grep -c` arithmetic bug (since fixed, **PR #82**) and **does not mention the restart** — so the restart itself is currently unexplained/undocumented.
- An istiod restart **under configuration churn at 10k scale** is a control-plane stability signal that should be root-caused before it's dismissed.

#### Asks
1. Pull the istiod pod's **prior-container logs / exit reason / events** for that window if still available (or reproduce a churn run and watch for restarts).
2. Determine whether it was an **OOMKill** (cgroup memory vs the 16Gi limit — RSS top was 19% but transient spikes under churn could differ), a **liveness-probe timeout**, or a **crash**.
3. If reproducible under churn, file a follow-up with the mechanism; if a one-off infra blip, note and close.

Context: push amplification stayed ~1× (0.8–1.2, n=5) and local convergence ~7s on the valid iterations, so steady-state churn behavior looked healthy apart from this single restart.

Filed from the 20c/10k campaign retrospective.



### Original issue #88: harness: data-plane same-cluster (local) baseline saturates single test-server replica → n_valid=0 at high QPS
#### Observation

In the 2026-06-22 20c/10k campaign, the **data-plane** suite's **same-cluster (local) baseline** rows came back `n_valid=0` at the higher QPS levels in **both** runs — the local echo/test server is a **single replica** and saturated (sustained ~686 of 1000 target QPS), tripping `ERROR_RATE_HIGH`.

Consequence: there was **no usable same-cluster latency baseline** from the data-plane suite itself. The customer brief had to source its ~2.8 ms same-cluster figure from the **churn-dataplane** baseline instead, and the cross-cluster 'hop adds X ms' comparison is weaker than it should be.

This is a **test-workload sizing artifact, not a mesh effect** — but it degrades a metric the suite is supposed to produce.

#### Asks
1. **Scale the local test/echo server** (multiple replicas, or a higher-throughput server) so the same-cluster baseline survives the top QPS levels — OR
2. **Cap the local-baseline QPS** to a level the single replica can serve cleanly (decouple local-baseline QPS from the cross-cluster sweep QPS), and/or
3. Make the suite **report explicitly** when the local baseline is saturated/dropped (so a downstream reader knows the same-cluster number is missing rather than silently absent).

Goal: the data-plane suite should always yield a trustworthy same-cluster baseline to anchor the cross-cluster hop delta.

Filed from the 20c/10k campaign retrospective.



### Original issue #84: test(controlplane): add basic Istio traffic-management resources (VirtualService/DestinationRule) to reflect configured-mesh config scale
#### Motivation

The scale suites deploy **bare `Service` objects + sidecar injection** plus the tuned baseline (sidecar scoping, discovery selectors, telemetry/access-log filtering). They do **not** create VirtualServices or DestinationRules.

Real production meshes carry VS/DR per service (routing, retries, timeouts, subsets, outlier detection, connection pools). These are config istiod must **compute into Envoy config, cache (mesh-wide in multi-primary), and push via xDS** — so they materially increase control-plane load.

In the **2026-06-22 20c/10k campaign** (`docs/campaigns/2026-06-22-20c-10k-10k-results.md`), istiod sat at **~19% of its 16Gi mem limit and ~3% CPU** at 10,000 Services. That headroom is **optimistic relative to a fully-configured production mesh** — a mesh with VS/DR at the same Service count consumes more istiod memory/CPU and slows convergence. The campaign measures **Service-object scale, not configured-mesh config scale**, and the customer brief notes this as a boundary.

#### Proposal

Add basic, **representative** Istio traffic-management resources to the test workloads where it makes sense, behind a **toggle/axis** so bare-vs-configured can be compared (the delta is the interesting number):

- **Control-plane suite (primary):** optional VirtualService + DestinationRule per Service (or per N Services). Keep them basic but real — e.g. a VS with a route + retry/timeout, a DR with ~2 subsets + a connection pool / outlier detection — enough to exercise RDS route expansion + CDS subset/EDS-per-subset expansion without being arbitrary.
- **Propagation suite (secondary):** a VS/DR change is a realistic propagation trigger; consider exercising it.
- **Data-plane suite:** lower priority — basic routing VS/DR don't materially change request latency (unless DR enables path-altering features); only worth it to test outlier-detection/conn-pool behavior.

#### What to measure
- istiod **memory (RSS) / CPU / push-cost / convergence** delta vs. bare Services at the same Service count.
- Per-proxy config size delta (RDS/CDS growth).

#### Scope notes
- Make density **and** complexity configurable so it doesn't bloat the default sweep but can be turned on for a 'configured production mesh' run.
- Route the harness change through `/scale-test-review` per the contributing process.

Filed from the campaign retrospective (Red Hat → <customer> 20c/10k validation).



### Original issue #91: harness: shared config-file library so suite scripts take a --config FILE instead of re-tracking every parameter
#### Problem

Every numbered script in each suite (`controlplane`, `dataplane`, `churn`, `churn-dataplane`, `propagation`, `tuning`) hand-rolls its own long parameter surface — a large `--flag`/getopts-style parser plus a parallel set of environment-variable defaults (`SETUP_CONTEXTS`, `CONTROLPLANE_SERVICE_COUNT`, `CONTROLPLANE_REPLICAS_PER_SERVICE`, sweep matrix knobs, `--sidecar-scopings`, `--settle`, `--output-dir`, …), with deprecated aliases layered on top.

Two costs fall out of this:

1. **Operator burden — every parameter must be re-tracked and re-passed across the whole 5–7 step lifecycle of a suite.** A single experiment is defined by the same contexts / service counts / scoping / matrix passed to `001-setup`, `002`, `003-run-sweep`, `004-report`, and `005-cleanup`. Today that lives in the operator's shell history (or a wrapper they wrote themselves). There's no single artifact that *is* the run definition, which hurts reproducibility — a property the suites otherwise take seriously (TSV preamble metadata, per-sweep output subdirs, run identifiers).
2. **Maintenance burden — the arg-parsing boilerplate is duplicated per script.** Adding or renaming a parameter means editing the parser, the usage text, and the env-var default block in N places, and keeping the deprecated-alias warnings consistent.

`config/options.env` + `config/versions.env` already cover *operational* defaults (sourced env), but per-run *experiment* parameters have no equivalent — they must be threaded by flag/env into each step individually.

#### Proposal

Add a **shared config-file library** under `tests/lib/` (e.g. `tests/lib/config.sh`, sibling to `common.sh`) that any numbered script can source to accept a `--config FILE` carrying the run's parameters, so the operator defines a run once and replays it across every step of the suite.

Suggested shape (to be refined in design):

- A single loader, `load_config <file>`, that reads a declarative config (env-style `KEY=value`, reusing the existing `options.env` precedent, or a small TSV/YAML if we want structure) and populates the same variables the scripts already consume — so it layers cleanly under the existing env-var defaults.
- **Precedence stays explicit and documented:** explicit CLI flag > `--config FILE` value > env var > built-in default. This keeps every current invocation working unchanged (no config = today's behavior) while letting a config file replace a wall of flags.
- Centralize the repeated per-flag parse/validate/alias-warn logic the loader and parsers share, leaning on the existing helpers in `common.sh` (`split_csv`, `is_pos_int`, `validate_scoping`, …).
- Keep it **shared and suite-agnostic**: the library handles loading + precedence + validation generically; each suite declares which keys it honors.

#### Acceptance

- New `tests/lib/config.sh` sourced by the suite scripts; `--config FILE` accepted by at least the multi-step suites' scripts.
- Documented precedence order (flag > config > env > default), with no behavior change when `--config` is absent.
- One worked example config checked in (or in a suite README) showing a full run defined in a single file and replayed across `setup → sweep → report → cleanup`.
- Help text on each affected script mentions `--config`.
- Existing flags/env vars and their deprecation warnings continue to work (backward compatible).

#### Notes / open questions

- Config format: env-style (`source`-able, matches `options.env`) is the lowest-friction option and reuses existing infra; a structured format (YAML/TSV) is more validatable but adds a parser dependency. Decide in design.
- Scope: land the library + one suite (`controlplane` is the richest parameter surface) as a tracer-bullet slice, then fan out to the other suites in follow-ups.




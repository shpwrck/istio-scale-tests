# Scale-test campaign — repeatable runbook

How to run the full multi-suite scale-test campaign across mesh sizes and collect comparable results. Two execution modes share one procedure:
- **Mode A — Manual** (no AI): a human runs the ordered commands below.
- **Mode B — Agent-driven**: a coding session follows [`agent-operator-brief.md`](agent-operator-brief.md).

The campaign runs all five suites — `propagation`, `churn`, `controlplane`, `dataplane`, `churn-dataplane` — each sweeping the configured mesh-size list, and produces a per-suite markdown summary + TSV under each suite's `results/sweep-<RUN_ID>/`.

> Cluster/context names in this repo are **placeholders** — always pass your own via `--contexts` / `SETUP_CONTEXTS`. Never commit real cluster names, hostnames, or kubeconfig contents (see `AGENTS.md`).

## Prerequisites (must all hold before starting)
1. **Multi-primary mesh deployed and healthy** across your `N` spoke clusters (the hub/ACM cluster is **not** a mesh member). Verify per `AGENTS.md` → "Verify the mesh".
2. **istiod pinned to a FIXED replica count** (HPA disabled) on every spoke — `charts/spoke-ossm` `pilot.autoscaleEnabled: false`, `pilot.replicaCount: <K>`. This is required for **measurement fidelity**: the probes attribute xDS counters/histograms across a *stable* control-plane topology; an autoscaling istiod scaling mid-sweep corrupts the deltas.
3. **Cluster sized for the workload.** A pinned istiod reserves CPU on every node; the suites also deploy many sidecar-injected pods (controlplane: `service-count × replicas`; churn-dataplane: `deployment-count × scale-to`). If nodes are too small you get `FailedScheduling: Insufficient cpu`. Give the clusters enough nodes/CPU, and keep istiod's CPU **request** modest (it's measurement-neutral — only affects scheduling).
4. **KUBECONFIG with every spoke context.** Set `SETUP_CONTEXTS` in `config/versions.env` (comma-separated) or pass `--contexts`. If the kubeconfig uses a token/OAuth credential, ensure it stays valid for the **entire** multi-hour run.
5. **Tools:** `kubectl`/`oc`, `helm`, `jq`, `curl`, `awk`.

## 500-spoke target profile (OCP 4.21 / ACM 2.16 / GitOps 1.20)

This profile is for one ACM/OpenShift GitOps hub and **500 pre-existing spoke connections**. It assumes the spokes are already created, imported into ACM, and reachable through kubeconfig contexts before this campaign starts; the campaign does not provision or import the 500 spokes. The hub remains ACM/GitOps control infrastructure only and must not be labeled into the mesh or included in `CONTEXTS`; `mesh_member_count` counts selected spokes only. Apply `istio-mesh-member=true` only to the intended 500 spoke `ManagedCluster` resources, and keep that selected set aligned with the 500 contexts in `CONTEXTS`. It also assumes every selected spoke can expose its east-west gateway and reach every other selected spoke's east-west gateway: service port `15443` for LoadBalancer exposure, or the configured `service.nodePorts.tls` value for NodePort exposure (`31443` by default in `charts/spoke-east-west-gateway/values.yaml`). The campaign kubeconfig credentials must remain valid or refreshable for the full multi-hour run. Keep istiod pinned to a fixed replica count on every spoke for the whole campaign; the current `charts/spoke-ossm` defaults set `pilot.autoscaleEnabled: false` and `pilot.replicaCount: 5`. It can be prepared and dry-run without cluster access, but live success still depends on hub CPU/memory, API responsiveness, network reachability, and credential lifetime.

No-cluster validation only proves renders, command shape, and sweep matrix size. Hub capacity, ACM Placement pagination, ESO PushSecret fan-out, east-west gateway reachability, and istiod remote-cluster ingestion must close through the live preflight and staged functional gates below before the campaign is considered ready to run.

Version compatibility references:

- [RHACM 2.16 support matrix](https://access.redhat.com/articles/7136928) lists Red Hat OpenShift Container Platform 4.21 as supported for both hub and managed clusters.
- [OpenShift GitOps 1.20 release notes](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.20/html-single/release_notes/index) list OpenShift Container Platform 4.21 as supported for GitOps 1.20.
- [OCM Placement documentation](https://open-cluster-management.io/docs/concepts/content-placement/placement/) documents that large scheduling results are paginated across `PlacementDecision` resources labeled `cluster.open-cluster-management.io/placement=<placement name>`.
- [Argo CD cluster decision resource documentation](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Cluster-Decision-Resource/) documents that `clusterDecisionResource` can use a `labelSelector` instead of one exact resource name.

Support caveat: OpenShift GitOps 1.20 release notes still classify dynamic shard scaling as Technology Preview. This scale-test bed accepts that Technology Preview dependency. This repo uses ArgoCD `spec.controller.sharding.dynamicScalingEnabled` plus `minShards`/`maxShards` so the application-controller starts with enough shards for large fleets; choose a different sharding approach if the hub must use only GA GitOps features.

Use these platform settings as the starting point in `terraform/platform/terraform.tfvars`:

```hcl
acm_channel             = "release-2.16"
gitops_operator_channel = "gitops-1.20"
mesh_member_count       = 500

# 500 spokes + in-cluster = 501 Argo CD clusters. With 50 clusters/shard,
# Terraform computes minShards = ceil(501 / 50) = 11 and renders maxShards >= 11.
# Do not use the repo default argocd_clusters_per_shard=3 on a 3-node hub unless
# the hub is intentionally sized for 167 application-controller pods.
argocd_clusters_per_shard = 50
argocd_max_shards         = 20
```

With that profile, the hub creates **501 Argo CD cluster entries** (500 spokes plus `in-cluster`) and starts **11 application-controller shards**. The chart defaults in `charts/argocd-config/values.yaml` request **2 CPU / 4Gi per controller shard**, so controller shards alone request **22 CPU / 44Gi**. Including the repo server, Argo CD server, and ApplicationSet controller defaults, OpenShift GitOps requests about **25 CPU / 50Gi** before ACM, OpenShift control-plane services, cert-manager, ESO, and workload overhead. If the 3-node hub cannot comfortably absorb that, do not apply all 500 mesh members yet; either increase hub node capacity or raise `argocd_clusters_per_shard` and rerun the staged smoke checks.

If the hub node sizes are not known yet, treat capacity as an unresolved preflight gate. Before applying `mesh_member_count = 500`, collect aggregate allocatable CPU/memory and current GitOps usage from the live hub, without recording real node names in committed artifacts:

```bash
oc get nodes -o json \
  | jq '[.items[].status.allocatable | {cpu, memory}]'
oc adm top nodes
oc adm top pods -n openshift-gitops
```

The 500-member mesh also creates quadratic remote-secret fan-out. Expect roughly:

- **500** hub intermediate CA Certificates.
- **1500** hub PushSecrets from `hub-mesh-push-secrets` (cacerts, kubeconfig, and remote-secret per member).
- **250,000** remote-secret writes from the 500 remote-secret PushSecrets fanning out to 500 spoke SecretStores.
- **500** `istio/multiCluster=true` remote secrets per spoke namespace when fan-out is complete.

The intended end state for this test bed is **all 500 spokes in one mesh**, with the hub outside the mesh, as long as mesh functionality remains healthy. Treat each membership increase as a functional gate rather than a blind scaling step:

```hcl
mesh_member_count = 1    # single-spoke smoke
mesh_member_count = 10   # ApplicationSet, ESO, and istiod fan-out smoke
mesh_member_count = 100  # hub/API pressure smoke
mesh_member_count = 500  # final target
```

After each gate, verify mesh-wiring health, remote-secret fan-out, sampled istiod `clusterz` sync, and `mesh-verify` cross-cluster traffic before increasing `mesh_member_count` again. If any gate breaks mesh functionality, hold at the last known-good member count and fix the root cause before continuing; do not run the larger campaign against a partially wired or degraded mesh.

For the actual campaign, `CONTEXTS` must contain **only the 500 spoke contexts**, in the same order you want `mesh_size=1..500` to mean. Do not include the hub context.

Without cluster access, validate the command matrices with placeholder context names:

```bash
N=500
CONTEXTS="$(seq -f 'spoke-%03g' -s, 1 "$N")"
MESH="$(seq -s, 1 "$N")"
```

On a live hub, verify the large-fleet GitOps fan-out before running tests:

```bash
# The 500 spokes already exist as ACM ManagedClusters before mesh fan-out.
oc get managedcluster --no-headers | wc -l

# Exactly 500 selected mesh members; no hub or extra spokes should match this label.
oc get managedcluster -l istio-mesh-member=true --no-headers | wc -l

# The campaign context list has exactly 500 selected spokes, all present in kubeconfig.
echo "$CONTEXTS" | tr ',' '\n' | wc -l
missing=0
for ctx in $(echo "$CONTEXTS" | tr ',' '\n'); do
  kubectl config get-contexts "$ctx" >/dev/null || missing=$((missing + 1))
done
printf 'missing contexts: %s\n' "$missing"

# PlacementDecision pages must sum to 500; large placements are split.
oc -n openshift-gitops get placementdecision \
  -l cluster.open-cluster-management.io/placement=acm-openshift-gitops-placement \
  -o json | jq '[.items[].status.decisions[]] | length'

# Argo CD controller shard count should match the profile math (11 with 50 clusters/shard).
oc -n openshift-gitops get statefulset openshift-gitops-application-controller \
  -o jsonpath='{.status.readyReplicas}{" / "}{.spec.replicas}{"\n"}'

# Sample east-west gateway exposure shape without printing hostnames.
for ctx in $(echo "$CONTEXTS" | tr ',' '\n' | awk 'NR==1 || NR==250 || NR==500'); do
  oc --context="$ctx" -n istio-system get svc istio-eastwestgateway \
    -o jsonpath='{.spec.type}{" servicePort="}{.spec.ports[?(@.name=="tls")].port}{" nodePort="}{.spec.ports[?(@.name=="tls")].nodePort}{"\n"}'
done | sort | uniq -c

# Hub capacity sanity. Compare these against the GitOps request math above.
oc adm top nodes
oc adm top pods -n openshift-gitops

# PushSecret count should be about 1500 once the mesh-push ApplicationSet is synced.
oc -n external-secrets-operator get pushsecret --no-headers | wc -l

# Spot-check remote-secret fan-out on early/middle/last spoke contexts.
for ctx in $(echo "$CONTEXTS" | tr ',' '\n' | awk 'NR==1 || NR==250 || NR==500'); do
  printf '%s ' "$ctx"
  oc --context="$ctx" -n istio-system get secret -l istio/multiCluster=true --no-headers | wc -l
done
```

For this 500-spoke bed, use the milestone mesh sizes as the default campaign:

```bash
MESH="1,10,50,100,250,500"
```

Use the suite commands below as written for the first milestone campaign. That keeps the current workload defaults for service counts, replica counts, churn deployment sizing, and per-suite timing, with only the documented sweep axes (`sidecar-scopings`, `qps-levels`, and `churn-rates`) set explicitly. Do not increase workload knobs until this baseline pass is clean.

The full `MESH="$(seq -s, 1 500)"` campaign is intentionally supported as a follow-up if you need every integer mesh size, but it is a very large, attended run: propagation alone is 5000 iterations at `--iterations 10`, and the data-plane/co-exec suites multiply each mesh size by QPS or churn-rate dimensions.

## Procedure (5 stages — same for both modes)

```bash
# Set once. CONTEXTS = your spoke contexts; MESH = the mesh-size list for this run.
CONTEXTS="$SETUP_CONTEXTS"           # e.g. "cluster-001,cluster-002,...,cluster-010"
MESH="1,2,3,4,5,6,7,8,9,10"          # adjust to your N
export KUBECONFIG=/path/to/your/kubeconfig
```

### Stage 0 — Verify the mesh
On every spoke: `kubectl -n istio-system get deploy istiod` shows the pinned `K/K` ready, and istiod's remote-cluster view is fully synced:
```bash
for ctx in ${CONTEXTS//,/ }; do
  pod=$(kubectl --context="$ctx" -n istio-system get pod -l app=istiod -o name | head -1)
  kubectl --context="$ctx" -n istio-system exec "${pod#pod/}" -c discovery -- \
    pilot-discovery request GET /debug/clusterz | grep -o '"syncStatus":"[^"]*"' | sort | uniq -c
done
# Expect: every spoke reports N entries (1 local + N-1 remote), all "synced".
```

### Stage 1 — Preflight
- Tools present (Prereq 5).
- **No leftover `*-test` namespaces** on any spoke (`propagation-test`, `controlplane-test*`, `dataplane-test`, `churn-test`, `churn-dataplane-test`). If any exist, run that suite's `00X-cleanup.sh` first.
- Confirm the pinned replica count matches expectations on every spoke.

### Stage 2 — Dry-run every sweep (no clusters touched)
Validate the planned matrix vs the safety cap (`*_MAX_MATRIX`, default 64) **before** committing hours:
```bash
tests/propagation/006-run-sweep.sh    --contexts "$CONTEXTS" --mesh-sizes "$MESH" --iterations 10 --force-large-matrix --dry-run
tests/churn/003-run-sweep.sh          --contexts "$CONTEXTS" --mesh-sizes "$MESH" --dry-run
tests/controlplane/003-run-sweep.sh   --contexts "$CONTEXTS" --mesh-sizes "$MESH" --sidecar-scopings none,namespace,explicit --force-large-matrix --dry-run
tests/dataplane/003-run-sweep.sh      --contexts "$CONTEXTS" --mesh-sizes "$MESH" --qps-levels 10,100,500,1000 --force-large-matrix --dry-run
tests/churn-dataplane/004-run-sweep.sh --contexts "$CONTEXTS" --mesh-sizes "$MESH" --churn-rates 1,5,10 --force-large-matrix --dry-run
```
`--force-large-matrix` is needed whenever a suite's planned matrix exceeds its safety cap (default 64). Confirm each printed matrix is what you intend before running live.

### Stage 3 — Run the suites SERIALLY (light → heavy)
**Never run two suites at once** — they all measure the *same* istiod; concurrent runs contaminate each other's xDS counters/histograms/CPU. Run in this order, each to completion, re-confirming a clean mesh between them:
```bash
# 1. propagation  (xDS propagation latency; ~tens of min)
tests/propagation/006-run-sweep.sh    --contexts "$CONTEXTS" --mesh-sizes "$MESH" --iterations 10 --force-large-matrix --tsv

# 2. churn  (convergence under endpoint churn; ~tens of min)
tests/churn/003-run-sweep.sh          --contexts "$CONTEXTS" --mesh-sizes "$MESH"

# 3. controlplane  (istiod resource scaling; 60s settles dominate; ~1–2h)
tests/controlplane/003-run-sweep.sh   --contexts "$CONTEXTS" --mesh-sizes "$MESH" --sidecar-scopings none,namespace,explicit --force-large-matrix

# 4. dataplane  (cross-cluster data-plane latency; QPS load dominates; ~2h+)
tests/dataplane/003-run-sweep.sh      --contexts "$CONTEXTS" --mesh-sizes "$MESH" --qps-levels 10,100,500,1000 --force-large-matrix

# 5. churn-dataplane  (latency delta under churn; per-combo setup/teardown; longest)
tests/churn-dataplane/004-run-sweep.sh --contexts "$CONTEXTS" --mesh-sizes "$MESH" --churn-rates 1,5,10 --force-large-matrix
```
**Between every suite:** verify the prior suite's `*-test` namespaces are gone on all spokes (run its `00X-cleanup.sh` if not), and re-confirm istiod is healthy (Stage 0). Then start the next.

### Stage 4 — Collect results
Each suite writes `tests/<suite>/results/sweep-<RUN_ID>/` containing per-run TSV(s) and an auto-generated **markdown summary** (re-generate manually with the suite's `004`/`005` report script if needed). The report scripts filter poisoned/incomplete rows and report `n_valid` vs `n_total` — check those footnotes when reading aggregates.

### Stage 5 — Teardown / cleanup (always, even on failure)
The campaign deploys workloads into `*-test` namespaces on every active spoke; leaving them behind wastes resources and pollutes the next run's baseline. Run **every** suite's cleanup (idempotent — safe if a namespace is already gone), then **wait out the async namespace termination** and verify nothing is left:
```bash
tests/churn-dataplane/006-cleanup.sh --contexts "$CONTEXTS"
tests/churn/005-cleanup.sh           --contexts "$CONTEXTS"
tests/controlplane/005-cleanup.sh    --contexts "$CONTEXTS"
tests/dataplane/005-cleanup.sh       --contexts "$CONTEXTS"
tests/propagation/007-cleanup.sh     --contexts "$CONTEXTS"

# Namespace deletion is async — re-check until clear (Terminating can take a minute
# while sidecar-injected pods drain). Expect NO output when fully clean:
for ctx in ${CONTEXTS//,/ }; do
  kubectl --context="$ctx" get ns 2>/dev/null \
    | grep -E 'propagation-test|controlplane-test|dataplane-test|churn-test|churn-dataplane-test' \
    && echo "  ^ still on $ctx"
done
```
Run this after the campaign completes **and** any time a suite dies mid-run before re-running it. The mesh itself (istiod/gateways/Argo) is **not** torn down by this — only the test workloads.

## Pitfalls & how to handle them (hard-won)
- **`FailedScheduling: Insufficient cpu`** → capacity. The pinned istiod's CPU *requests* + the suites' sidecar-injected pods exceed node allocatable. Add nodes/CPU, or reduce `--service-counts`/`--replica-counts` (controlplane) and `--deployment-count`/`--scale-to` (churn-dataplane) to fit. Lowering istiod's CPU **request** is measurement-neutral and frees scheduling room.
- **A sweep dies/hangs mid-run.** Today a *single* probe-instance failure (a transient scrape returning non-zero, a stuck `kubectl port-forward`) can abort an entire multi-hour sweep under `set -euo pipefail`. **You must actively watch for this** — a hung port-forward looks like *no log growth while the process is still alive* (not a crash). On failure: run the suite's `00X-cleanup.sh`, then re-run only the remaining `--mesh-sizes`. (The harness-hardening work — record-and-continue per probe — removes this; until then, monitor.)
- **Serial only.** See Stage 3.
- **Credential window.** A multi-hour campaign needs the kubeconfig credential valid throughout; rotate *after*, not during.
- **Runtime.** Expect several hours total; churn-dataplane is the long pole (per-combo setup + teardown). Adding nodes (faster pod scheduling) and the deploy-once-per-mesh-size optimization shorten it without affecting fidelity.

## Mode A — Manual (no AI)
Run Stages 0–5 above by hand. Concretely:
1. Stage 0 + Stage 1 checks; fix any failures before proceeding.
2. Stage 2: run all five `--dry-run`s; eyeball each matrix.
3. Stage 3: launch suite 1; **watch it** — `tail -f` the output and periodically confirm the process is alive *and* the log is still growing. When it finishes, run Stage-0 + namespace-clean checks, then launch the next. Repeat for all five.
4. If a suite dies: clean up (its `00X-cleanup.sh`), re-run remaining mesh sizes, continue.
5. Stage 4: read the markdown summaries.
6. **Stage 5: run the teardown cleanup and verify no `*-test` namespaces remain on any spoke.**
Budget a full day of attended wall-clock; keep a notepad of which suites/sizes completed.

## Mode B — Agent-driven
Hand a coding session [`agent-operator-brief.md`](agent-operator-brief.md). It encodes the same procedure plus the operational discipline that makes an unattended run safe: robust crash **and** stall detection (so a silent hang is caught), record-and-continue, a `CAMPAIGN_STATUS.md` progress file, and "investigate + fix a breaking error before retrying."

## See also
- Per-suite details: `tests/<suite>/README.md`.
- Harness review process: `docs/scale-test-team/`.
- Version/identity pins & contexts: `config/versions.env`, `config/options.env`.

# 500-spoke target profile (OCP 4.21 / ACM 2.17 / GitOps 1.22)

Settings and gates for running the [campaign](README.md) on one ACM/OpenShift GitOps hub with
**500 pre-existing spokes**. The campaign does not create or import the spokes.

## Assumptions

- The 500 spokes already exist, are imported into ACM, and are reachable as kubeconfig contexts.
- The hub is control infrastructure only: never labeled into the mesh and never in `CONTEXTS`.
  `mesh_member_count` counts spokes only.
- `istio-mesh-member=true` is applied to exactly the 500 spoke `ManagedCluster`s named in `CONTEXTS`.
- Every spoke can reach every other spoke's east-west gateway: port `15443` with LoadBalancer
  exposure (the chart default), or `service.nodePorts.tls` (`31443`) with NodePort exposure
  (`charts/spoke-east-west-gateway/values.yaml`).
- Kubeconfig credentials stay valid or refreshable for the whole multi-hour run.
- istiod stays pinned to a fixed replica count on every spoke (`charts/spoke-ossm` defaults:
  `pilot.autoscaleEnabled: false`, `pilot.replicaCount: 3`).

Offline dry-runs only prove renders, command shape and matrix size. Hub capacity, ACM Placement
pagination, ESO PushSecret fan-out, east-west reachability and istiod remote-cluster ingestion
are proven only by the live checks and staged gates below.

## Versions and support

- [RHACM 2.17 support matrix](https://access.redhat.com/articles/7142376): check hub and managed
  cluster OpenShift versions here (Red Hat login required).
- [OpenShift GitOps 1.22 release notes](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.22/html-single/release_notes/index):
  supported on OpenShift 4.18–4.22. Dynamic shard scaling is still **Technology Preview**; this
  test bed accepts that. The repo enables `spec.controller.sharding.dynamicScalingEnabled` with
  `minShards`/`maxShards` so the application controller starts with enough shards. Pick another
  sharding approach if the hub must use GA features only.
- [OCM Placement](https://open-cluster-management.io/docs/concepts/content-placement/placement/):
  large results are paginated across `PlacementDecision`s labeled
  `cluster.open-cluster-management.io/placement=<placement name>`.
- [Argo CD Cluster Decision Resource generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Cluster-Decision-Resource/):
  `clusterDecisionResource` can use a `labelSelector` instead of one resource name.

## Platform settings

Start from these in `terraform/platform/terraform.tfvars`:

```hcl
acm_channel             = "release-2.17"
gitops_operator_channel = "gitops-1.22"
mesh_member_count       = 500

# 500 spokes + in-cluster = 501 Argo CD clusters. With 50 clusters/shard,
# Terraform computes minShards = ceil(501 / 50) = 11 and renders maxShards >= 11.
# Do not use the repo default argocd_clusters_per_shard=3 on a 3-node hub unless
# the hub is intentionally sized for 167 application-controller pods.
argocd_clusters_per_shard = 50
argocd_max_shards         = 20
```

## Hub capacity

This creates **501 Argo CD cluster entries** and **11 application-controller shards**. Each
shard requests **2 CPU / 4Gi** (`charts/argocd-config/values.yaml`), so the shards alone request
**22 CPU / 44Gi**; with the repo server, Argo CD server and ApplicationSet controller, OpenShift
GitOps requests about **25 CPU / 50Gi** before ACM, OpenShift services, cert-manager, ESO and
workloads. If the hub cannot absorb that, add hub capacity or raise `argocd_clusters_per_shard`
before applying all 500 members.

If hub node sizes are unknown, treat capacity as an open preflight gate. Collect aggregate
allocatable CPU/memory and current GitOps usage (do not record node names):

```bash
oc get nodes -o json \
  | jq '[.items[].status.allocatable | {cpu, memory}]'
oc adm top nodes
oc adm top pods -n openshift-gitops
```

## Remote-secret fan-out

The mesh fan-out is quadratic. Expect roughly:

- **500** hub intermediate CA Certificates.
- **1000** hub PushSecrets from `hub-mesh-push-secrets` (cacerts and remote-secret per member).
- **250,000** remote-secret writes (500 remote-secret PushSecrets × 500 spoke SecretStores).
- **500** `istio/multiCluster=true` remote secrets per spoke once fan-out completes.

## Staged membership gates

The end state is all 500 spokes in one mesh. Treat each step as a functional gate:

```hcl
mesh_member_count = 1    # single-spoke smoke
mesh_member_count = 10   # ApplicationSet, ESO, and istiod fan-out smoke
mesh_member_count = 100  # hub/API pressure smoke
mesh_member_count = 500  # final target
```

After each step, check mesh-wiring health, remote-secret fan-out, sampled istiod `clusterz`
sync and `mesh-verify` cross-cluster traffic. If a step breaks the mesh, hold at the last good
count and fix the cause first.

## Contexts and live checks

`CONTEXTS` holds **only the 500 spoke contexts**, in the order you want `mesh_size=1..500` to
mean. For offline dry-runs, use placeholder names:

```bash
N=500
CONTEXTS="$(seq -f 'spoke-%03g' -s, 1 "$N")"
MESH="$(seq -s, 1 "$N")"
```

On the live hub, verify the GitOps fan-out before running tests:

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

# PushSecret count should be about 1000 once the mesh-push ApplicationSet is synced.
oc -n external-secrets-operator get pushsecret --no-headers | wc -l

# Spot-check remote-secret fan-out on early/middle/last spoke contexts.
for ctx in $(echo "$CONTEXTS" | tr ',' '\n' | awk 'NR==1 || NR==250 || NR==500'); do
  printf '%s ' "$ctx"
  oc --context="$ctx" -n istio-system get secret -l istio/multiCluster=true --no-headers | wc -l
done
```

## Mesh sizes

Use milestone mesh sizes for the first campaign, with the suite commands from the
[runbook](README.md#procedure) unchanged (default workload knobs):

```bash
MESH="1,10,50,100,250,500"
```

Do not raise workload knobs until this baseline pass is clean. A full `MESH="$(seq -s, 1 500)"`
run is supported but very large: propagation alone is 5000 iterations at `--iterations 10`, and
the data-plane and churn-dataplane suites multiply each mesh size by QPS levels or churn rates.

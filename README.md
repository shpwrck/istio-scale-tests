# istio-scale-tests

This repository holds automation and manifests used to scale-test Istio in a multi-cluster setup on OpenShift. The target pattern is multi-primary, multi-network mesh: several independent clusters share one logical mesh (common mesh id and trust), with Istio delivered via the Sail operator (`Istio` / `IstioCNI` CRs). Procedures follow [Red Hat OSSM 3.3 — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies); pinned OpenShift / Kubernetes / Istio versions live in `config/versions.env`.

Use it to reproduce installs, certificate wiring, remote secrets, east-west gateways, and sample workloads — then measure behavior under load or changing cluster counts.

```
   Multi-primary, multi-network mesh — mesh-id: mesh1
   Shared plug-in CA: cert-manager root + per-cluster intermediates

     ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
     │  cluster-1   │    │  cluster-2   │    │  cluster-3   │
     │  (ACM hub)   │    │  network-2   │    │  network-3   │
     ├──────────────┤    ├──────────────┤    ├──────────────┤
     │ Argo CD      │    │ istiod       │    │ istiod       │
     │ cert-manager │    │ ingress-gw   │    │ ingress-gw   │
     │ ESO          │    │ east-west-gw │◄─▶│ east-west-gw │
     │              │    │  :15443      │    │  :15443      │
     └──────┬───────┘    └──────┬───────┘    └──────┬───────┘
            └── Argo CD ApplicationSets (ACM Placement) ──┘
              Hub pushes cacerts + remote secrets via ESO
```

---

## Quick start

Provision clusters and deploy the full mesh with two Terraform modules:

```bash
# 1. Create ROSA HCP clusters
cd terraform/rosa-hcp
export RHCS_TOKEN='...'
terraform init && terraform apply

# 2. Get a merged kubeconfig for all clusters
terraform output -raw kubeconfig > ~/.kube/rosa-config
export KUBECONFIG=~/.kube/rosa-config

# 3. Install ACM + GitOps + full mesh
cd ../platform
terraform init && terraform apply
```

The platform module installs ACM, imports spoke clusters, deploys OpenShift GitOps (Argo CD), and syncs the app-of-apps which rolls out the entire mesh: Sail operator, Istio CRs, cert-manager CAs, External Secrets for cacerts and remote secrets, ingress gateways, and east-west gateways.

By default `mesh_member_count = 0` labels all spokes as mesh members. Set it to `1` to start with a single spoke and [incrementally add clusters](#incremental-mesh-deployment).

No clusters yet? See [Provision clusters](#1-provision-clusters-terraform). Want to verify the mesh? See [Verify the mesh install](#verify-the-mesh-install).

---

## End-to-end order

1. Infrastructure — provision clusters with Terraform (`terraform/rosa-hcp/`).
2. Platform + Mesh — apply the platform Terraform module (`terraform/platform/`). This installs ACM, GitOps, and the full Istio mesh via Argo CD ApplicationSets.
3. Propagation testing — measure xDS propagation latency across clusters (`propagation-test/`).
4. Load testing — deploy the multicluster Isotope topology (`isotope-multicluster/`).

---

## What you need

On the machine where you run repo commands:

| Binary / runtime | Notes |
| --- | --- |
| `oc` or `kubectl` | With a kubeconfig that can reach every cluster; context names should match `cluster_name_format` in your Terraform config. |
| `terraform` | To apply `terraform/rosa-hcp/` (pinned version: see `versions.tf`). |
| `helm` | Helm 3 for charts under `charts/`. |
| `istioctl` | For mesh verification; align the build with `ISTIO_VERSION` in `config/versions.env`. Place at `.bin/istioctl` and prefix `PATH="$PWD/.bin:$PATH"`. |
| `jq`, `curl` | `jq` for Terraform JSON, `curl` for ingress checks. |

Optional: Go on `PATH` when running `isotope-multicluster/` against a local [istio/tools](https://github.com/istio/tools) checkout.

Configuration: version pins and mesh identity live in `config/versions.env`; operational defaults (namespaces, logging, test params) are in `config/options.env`, sourced automatically.

---

## 1. Provision clusters (Terraform)

Use `terraform/rosa-hcp/` to create ROSA HCP clusters (upstream module `terraform-redhat/rosa-hcp/rhcs`). You set `cluster_count`, `cluster_name_format`, and `vpc_cidr_format` (plus pins such as `openshift_version`); each cluster gets its own VPC, OIDC stack, and IAM roles. Outputs include API URLs, a shared `cluster_admin_login`, and a merged `kubeconfig` (exec plugin auth). See `terraform/rosa-hcp/README.md`.

---

## 2. Deploy the mesh (GitOps)

After clusters exist, apply the platform module (`terraform/platform/`). This installs everything via GitOps:

1. ACM operator + MultiClusterHub + spoke import
2. OpenShift GitOps (Argo CD) + app-of-apps

The app-of-apps (`hub-gitops-root`) syncs child Applications from `charts/gitops-hub-apps/applications/`, each deploying an ApplicationSet that targets spoke clusters via ACM Placement. The sync wave order ensures dependencies resolve correctly:

| Wave | Component | Chart |
| ---- | --------- | ----- |
| 8    | Sail operator (OLM) | `charts/spoke-ossm-operator/` |
| 10   | cert-manager operator (OLM) | `charts/cert-manager-operator/` |
| 12   | External Secrets operator | `charts/external-secrets-operator/` |
| 13   | Mesh root CA + ClusterIssuer | `charts/hub-mesh-ca/` |
| 15   | Per-cluster intermediate CAs | `charts/hub-mesh-ca-intermediate/` |
| 16   | Kubeconfig extraction from Argo secrets | `charts/hub-kubeconfig-from-argosecret/` |
| 19   | Push cacerts + kubeconfigs + remote secrets to spokes | `charts/hub-mesh-push-secrets/` |
| 21   | Istio + IstioCNI CRs | `charts/spoke-ossm/` |
| 24   | North-south ingress gateway | `charts/spoke-ingress-gateway/` |
| 27   | East-west gateway + cross-network Gateway CR | `charts/spoke-east-west-gateway/` |


<details>
<summary>Repository layout — directories and Helm charts (click to expand)</summary>

| Path | Role |
| ---- | ---- |
| `terraform/rosa-hcp/` | ROSA HCP cluster provisioning (VPCs, clusters, worker pools, VPC peering). |
| `terraform/platform/` | ACM + OpenShift GitOps platform setup (reads rosa-hcp state via `terraform_remote_state`). |
| `terraform/platform/platform_acm.tf` | ACM operator + MultiClusterHub + KlusterletConfig. |
| `terraform/platform/platform_acm_spokes.tf` | Spoke ManagedCluster + auto-import-secret per non-hub cluster. |
| `terraform/platform/platform_gitops.tf` | OpenShift GitOps operator + ArgoCD config + ACM GitOps wiring + app-of-apps. |
| `charts/spoke-ossm-operator/` | Helm chart: OLM Subscription for Sail operator on each spoke. |
| `charts/spoke-ossm/` | Helm chart: `Istio` + `IstioCNI` CRs per spoke (multi-primary, multi-network). |
| `charts/spoke-ingress-gateway/` | Helm chart: north-south ingress gateway (LoadBalancer) per spoke. |
| `charts/spoke-east-west-gateway/` | Helm chart: east-west gateway + cross-network Gateway CR per spoke. |
| `charts/hub-mesh-ca/` | Helm chart: cert-manager root CA + ClusterIssuer on the hub. |
| `charts/hub-mesh-ca-intermediate/` | Helm chart: one intermediate CA Certificate per spoke cluster. |
| `charts/hub-mesh-push-secrets/` | Helm chart: ESO PushSecrets for cacerts, kubeconfigs, and Istio remote secrets to spokes. |
| `charts/hub-kubeconfig-from-argosecret/` | Helm chart: ESO SecretStore + ExternalSecret extracting kubeconfigs from Argo cluster secrets. |
| `charts/external-secrets-operator/` | Helm chart: OLM install for External Secrets Operator per spoke. |
| `charts/cert-manager-operator/` | Helm chart: OLM install for cert-manager Operator on the hub. |
| `charts/mesh-verify/` | Helm chart: standalone echo workload for multicluster mesh verification (not in root app). |
| `charts/propagation-test/` | Helm chart: watcher and canary workloads for measuring xDS propagation latency. |
| `charts/istiod-monitor/` | Helm chart: OpenShift UWM ServiceMonitor + PrometheusRule for istiod pilot metrics. |
| `charts/gitops-hub-ocm-placement-appset/` | Reusable Helm chart: Argo CD ApplicationSet + RBAC for ACM Placement; preset value files per component. |
| `charts/gitops-hub-app-of-apps/` | Helm chart: Argo CD Application `hub-gitops-root` (directory sync of child Applications). |
| `charts/gitops-hub-apps/` | Child Application manifests under `applications/`; synced by `hub-gitops-root`. |
| `charts/acm-operator/` | Helm chart: OLM Subscription for ACM (Terraform `platform_acm.tf`). |
| `charts/acm-multicluster-hub/` | Helm chart: MultiClusterHub CR (Terraform `platform_acm.tf`). |
| `charts/acm-klusterlet-config/` | Helm chart: KlusterletConfig CR (Terraform `platform_acm.tf`). |
| `charts/acm-managed-cluster/` | Helm chart: one ManagedCluster per spoke (Terraform `platform_acm_spokes.tf`). |
| `charts/openshift-gitops-operator/` | Helm chart: OLM Subscription for OpenShift GitOps (Terraform `platform_gitops.tf`). |
| `charts/acm-openshift-gitops-resources/` | Helm chart: ManagedClusterSetBinding, Placement, GitOpsCluster for hub Argo CD. |
| `charts/acm-gitops-cluster/` | Helm chart: GitOpsCluster CR binding ACM Placement to an Argo CD instance. |
| `charts/argocd-config/` | Helm chart: ArgoCD custom resource configuration. |
| `config/versions.env` | Core version pins and mesh identity; sources `config/options.env` for operational defaults. |
| `propagation-test/` | Propagation latency test suite: active probes + metrics collection + sweep orchestrator. |
| `isotope-multicluster/` | Multicluster isotope load test workload generator and applier. |

</details>

### ACM + GitOps (Terraform)

After provisioning clusters, the platform module installs ACM and OpenShift GitOps:

```bash
cd terraform/platform
cp terraform.tfvars.example terraform.tfvars   # edit as needed
terraform init && terraform apply
# This installs ACM, imports spokes, installs GitOps, deploys app-of-apps,
# and rolls out the entire Istio mesh via Argo CD ApplicationSets.
```

See `terraform/platform/terraform.tfvars.example` for variables controlling ACM channel, GitOps config, and spoke import behavior.

---

## Incremental mesh deployment

The `mesh_member_count` variable (in `terraform/platform/`) controls how many spoke clusters participate in the Istio mesh. Spokes are labeled with `istio-mesh-member=true` in sorted key order; the ACM Placement selects only labeled spokes.

| `mesh_member_count` | Labeled spokes | Behavior |
| --- | --- | --- |
| `0` | All spokes | All spokes get Istio (default, backward-compatible) |
| `1` | First spoke only | Single-cluster Istio, no multicluster |
| `2` | First two spokes | Two-cluster mesh with cross-cluster discovery |
| `N` | First N spokes | N-cluster mesh |

```bash
# Start with one cluster (in terraform/platform/)
# In terraform.tfvars: mesh_member_count = 1
terraform apply

# Verify single-cluster Istio works (see next section)

# Add a second cluster
# In terraform.tfvars: mesh_member_count = 2
terraform apply

# Verify cross-cluster load balancing works
```

For quick iteration without Terraform, label clusters directly:

```bash
# Add a cluster to the mesh
oc label managedcluster/<cluster-3> istio-mesh-member=true

# Remove a cluster from the mesh
oc label managedcluster/<cluster-3> istio-mesh-member-
```

Manual labels take effect immediately (next ACM reconciliation cycle). The next `terraform apply` reconciles labels to match `mesh_member_count`.

Check which spokes are currently mesh members:

```bash
oc get managedcluster -l istio-mesh-member=true
```

---

## Verify the mesh install

The `mesh-verify` chart (`charts/mesh-verify/`) deploys a lightweight echo workload for validating Istio. It runs an `http-echo` pod per cluster that returns its cluster name, exposed via an Istio VirtualService on `Host: mesh-verify.local`. A DestinationRule disables locality-aware load balancing so requests spread evenly across clusters.

The chart is **not** part of the root app-of-apps — deploy it manually via a standalone ApplicationSet. It uses the same ACM Placement as the mesh components, so it only targets clusters with the `istio-mesh-member` label.

### Deploy and test

```bash
# Deploy the mesh-verify ApplicationSet
oc apply -f charts/mesh-verify-appset.yaml

# Wait for Argo CD to sync (check the mesh-verify-appset Application in the UI,
# or wait for pods to appear):
oc get pods -n mesh-verify --context <cluster-2>
```

Once pods are running, curl any mesh member's ingress gateway:

```bash
INGRESS=$(oc get svc istio-ingressgateway -n istio-system --context <cluster-2> \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

for i in {1..10}; do
  curl -s -H 'Host: mesh-verify.local' "http://$INGRESS/"
done
```

### What to expect

**Single cluster** (`mesh_member_count = 1`): all responses return the same cluster name. This confirms Istio, the ingress gateway, and sidecar injection are working on that cluster.

**Multiple clusters** (`mesh_member_count >= 2`): responses should come from different cluster names. This confirms east-west gateways, remote secrets, and cross-cluster endpoint discovery are all functioning.

### Deeper diagnostics

```bash
# Check that istiod discovers remote clusters
istioctl remote-clusters --context <cluster-2>

# Verify cross-cluster endpoints are visible to a sidecar
istioctl proxy-config endpoints deploy/mesh-verify-echo -n mesh-verify \
  --context <cluster-2> | grep mesh-verify

# Check remote secrets exist on a spoke
oc get secret -n istio-system -l istio/multiCluster=true --context <cluster-2>
```

### Clean up

```bash
oc delete -f charts/mesh-verify-appset.yaml
```

This removes the ApplicationSet and all generated Applications. The `mesh-verify` namespace and its resources are cleaned up on each spoke by Argo CD's prune policy.

---

## 3. Propagation Latency Testing (`propagation-test/`)

Measure how quickly the multi-cluster control plane propagates endpoint and config changes across clusters. Two complementary approaches:

- **Active probes** — deploy a canary service, poll istiod debug endpoints and sidecar proxy-config, record wall-clock propagation times
- **Passive metrics** — OpenShift User Workload Monitoring ServiceMonitor for istiod (`charts/istiod-monitor/`)

Run the sweep to compare propagation latency across mesh sizes (1, 2, 3, ... N clusters):

```bash
./propagation-test/006-run-sweep.sh \
  --contexts rosa-001,rosa-002,rosa-003 \
  --mesh-sizes 1,2,3 --iterations 5
```

See `propagation-test/README.md` for full usage.

---

## 4. Run Isotope (`isotope-multicluster/`)

Multicluster [istio/tools isotope](https://github.com/istio/tools/tree/master/isotope) workload: generate a chain topology from Terraform `cluster_keys`, render manifests, and apply per context. Requires a local istio/tools clone, Go, and an isotope service image. Run after the mesh is deployed and verified. See `isotope-multicluster/README.md`.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Remote secrets missing on spokes | ESO PushSecret not synced | Check `oc get pushsecret -n external-secrets-operator` on the hub; verify spoke SecretStores are healthy. |
| Ingress LoadBalancer returns connection refused on ROSA AWS | NLB security groups missing | Set `AWS_LOAD_BALANCER_SECURITY_GROUPS` in `config/options.env`. |
| `istioctl` errors on unrecognized API versions | Local `istioctl` doesn't match `ISTIO_VERSION` | Place a matching binary at `.bin/istioctl` and prefix `PATH="$PWD/.bin:$PATH"`. |
| `proxy-status` only lists local endpoints | Remote secrets not labeled correctly | Check `oc get secret -n istio-system -l istio/multiCluster=true`; verify `hub-mesh-push-secrets` chart synced. |
| Cross-cluster requests time out | Ingress gateway Service has `topology.istio.io/network` label | This label should only be on the east-west gateway Service, not the ingress gateway. |

---

## References

- [Red Hat OpenShift Service Mesh 3.3 — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies)
- Coding agents: see [`AGENTS.md`](AGENTS.md) for project context, edit conventions, and keeping docs aligned with code changes.

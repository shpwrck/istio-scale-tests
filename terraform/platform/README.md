# Platform Setup — Terraform

Installs ACM (Red Hat Advanced Cluster Management), OpenShift GitOps (Argo CD), and deploys the full Istio mesh via GitOps. The module can read cluster metadata from `terraform/rosa-hcp/` state (`cluster_provider = "rosa"`) or from an existing kubeconfig (`cluster_provider = "kubeconfig"`).

## Prerequisites

- Terraform >= 1.14.8.
- For `cluster_provider = "rosa"`: `terraform/rosa-hcp/` applied first; this module reads its state via `terraform_remote_state` (local backend).
- For `cluster_provider = "kubeconfig"`: a kubeconfig that can reach the hub and every spoke context.
- `KUBECONFIG` or `kubeconfig_path` set to reach the hub cluster.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit: set gitops_app_repo_url to your fork/clone of this repo.
# For private repos, set gitops_app_repo_password or gitops_app_repo_ssh_private_key
# (prefer TF_VAR_ env vars to avoid committing secrets).

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

See `terraform.tfvars.example` for all configurable variables.

### Existing-cluster kubeconfig mode

Use this mode for a prebuilt testbed, including a 500-spoke bed. Keep real context names in local, gitignored `terraform.tfvars` only.

```hcl
cluster_provider      = "kubeconfig"
kubeconfig_path       = "~/.kube/scale-test"
hub_cluster_context   = "hub-cluster"
spoke_cluster_contexts = [
  "spoke-001",
  "spoke-002",
  # ...
  "spoke-500",
]
```

## What it deploys

The module deploys resources in order, waiting for dependencies at each step:

1. **ACM operator** — OLM Subscription + MultiClusterHub + KlusterletConfig (`platform_acm.tf`)
2. **Spoke registration** — ManagedCluster + auto-import-secret per non-hub cluster (`platform_acm_spokes.tf`)
3. **OpenShift GitOps operator** — OLM Subscription + ArgoCD resource limits and ApplicationSet config (`platform_gitops.tf`)
4. **ACM GitOps wiring** — ManagedClusterSetBinding and Placement binding spokes to Argo CD
5. **Hub app-of-apps** — Argo CD Application pointing to `charts/gitops-hub-apps/applications/`, which rolls out the entire mesh via ApplicationSets (Sail operator, Istio CRs, cert-manager, ESO, gateways)
6. **Cluster secret creation** — Terraform-owned Argo CD cluster secrets pointing at each spoke's direct external API URL (`create-argocd-cluster-secret.sh`). We own these instead of ACM's GitOpsCluster controller, which forces an unreachable internal/cluster-proxy URL.

Steps 3–6 are skipped when `enable_gitops = false`.

Mesh restart (istiod and gateways) is handled by the GitOps sync wave 30 chart (`charts/spoke-mesh-restart/`), not by Terraform.

## Incremental mesh deployment

The `mesh_member_count` variable controls how many spokes get Istio (0 = all). See the main [README](../../README.md#incremental-mesh-deployment) for usage details.

## Large fleet GitOps sizing

For 500 spoke clusters on a 3-node hub, do not leave `argocd_clusters_per_shard` at the small-fleet default of `3` unless the hub is deliberately sized for the resulting 167 application-controller shards. Start with:

```hcl
gitops_operator_channel   = "gitops-1.20"
mesh_member_count         = 500
argocd_clusters_per_shard = 50
argocd_max_shards         = 20
```

Terraform computes `minShards = ceil((spoke_count + 1) / argocd_clusters_per_shard)` and renders `maxShards` as at least that value, so large fleets do not produce an invalid `minShards > maxShards` ArgoCD spec. Validate hub capacity before applying all mesh members; with the chart defaults, each controller shard requests 2 CPU and 4Gi memory.

## Outputs

| Output | Description |
| --- | --- |
| `acm_hub_cluster_key` | Terraform cluster key used as the ACM hub |
| `acm_spoke_cluster_keys` | Cluster keys registered as ACM spoke ManagedClusters |
| `acm_cluster_set` | ManagedClusterSet name applied to spokes |
| `acm_local_cluster_name` | MultiClusterHub localClusterName (defaults to first cluster key) |
| `gitops_namespace` | Namespace for Argo CD and ACM GitOps CRs |
| `mesh_member_spoke_keys` | Spoke keys labeled as Istio mesh members |

## State and secrets

Local state is the default. For shared use, configure a remote `backend` in a separate file. Do not commit `terraform.tfvars`, tokens, or credentials.

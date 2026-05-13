# Platform Setup — Terraform

Installs ACM (Red Hat Advanced Cluster Management), OpenShift GitOps (Argo CD), and deploys the full Istio mesh via GitOps on clusters provisioned by `terraform/rosa-hcp/`.

## Prerequisites

- Terraform >= 1.14.8.
- `terraform/rosa-hcp/` applied first — this module reads its state via `terraform_remote_state` (local backend).
- `KUBECONFIG` set to reach the hub cluster (first cluster from rosa-hcp).

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

## What it deploys

The module deploys resources in order, waiting for dependencies at each step:

1. **ACM operator** — OLM Subscription + MultiClusterHub + KlusterletConfig (`platform_acm.tf`)
2. **Spoke registration** — ManagedCluster + auto-import-secret per non-hub cluster (`platform_acm_spokes.tf`)
3. **OpenShift GitOps operator** — OLM Subscription + ArgoCD resource limits and ApplicationSet config (`platform_gitops.tf`)
4. **ACM GitOps wiring** — ManagedClusterSetBinding, Placement, and GitOpsCluster binding spokes to Argo CD
5. **Hub app-of-apps** — Argo CD Application pointing to `charts/gitops-hub-apps/applications/`, which rolls out the entire mesh via ApplicationSets (Sail operator, Istio CRs, cert-manager, ESO, gateways)
6. **Cluster secret patching** — corrects spoke API URLs in Argo CD cluster secrets

Steps 3–6 are skipped when `enable_gitops = false`.

Mesh restart (istiod and gateways) is handled by the GitOps sync wave 30 chart (`charts/spoke-mesh-restart/`), not by Terraform.

## Incremental mesh deployment

The `mesh_member_count` variable controls how many spokes get Istio (0 = all). See the main [README](../../README.md#incremental-mesh-deployment) for usage details.

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

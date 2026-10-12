# Platform and mesh (Terraform)

Installs ACM and OpenShift GitOps on the hub, registers the other clusters, and starts the Argo CD
app-of-apps that deploys the whole mesh (Sail operator, Istio, shared CA, secrets, gateways).

Two ways to find clusters:

| `cluster_provider` | Clusters come from | Hub |
| --- | --- | --- |
| `rosa` (default) | `terraform/rosa-hcp` state | the first cluster |
| `kubeconfig` | `kubeconfig_path` + context names | `hub_cluster_context` |

The hub runs ACM and Argo CD and is never a mesh member. Spoke context names become
ManagedCluster names, so use short lowercase names.

## Run

```bash
cp terraform.tfvars.example terraform.tfvars   # repo URL/branch, cluster_provider, contexts
./scripts/001-openapi-preflight.sh --contexts <acm-hub-ctx>   # existing hubs only
terraform init
terraform plan -out=platform.tfplan
terraform apply platform.tfplan
```

Then watch the rollout: `oc --context <acm-hub-ctx> get applications.argoproj.io -n openshift-gitops`
until every application is Synced/Healthy (about 15–20 minutes).

## Existing clusters

| Already installed on the hub | Set |
| --- | --- |
| ACM | `acm_install_operator = false`, `acm_local_cluster_name = "local-cluster"` |
| OpenShift GitOps | `gitops_install_operator = false` |
| cert-manager | `gitops_app_overrides = { "hub-cert-manager-operator" = { enabled = false } }` |

If the spokes are already ACM-managed, import their namespaces once before the first apply:
`terraform import 'kubernetes_manifest.spoke_namespace["<ctx>"]' "apiVersion=v1,kind=Namespace,name=<ctx>"`.

## Per-environment values

The chart defaults are sized for the 20-cluster campaign. Override them per environment without forking:

- `gitops_app_overrides`: per child app `enabled` and `values` (for example a smaller istiod, or a
  MetalLB pool for the gateways). See `terraform.tfvars.example`.
- `argocd_config_values`: Argo CD resources on a small hub. Keep the controller limit near 6Gi.
- `mesh_member_count`: how many spokes join the mesh, in sorted order (0 = all).
- Large fleets: `argocd_clusters_per_shard` / `argocd_max_shards`.

The child apps sync from `gitops_app_repo_url` at `gitops_app_repo_revision`, so a fork or branch
deploys from itself. Edited charts roll out on the next apply.

## Tear down

`terraform destroy` deletes the Argo CD apps first, then uninstalls the operators Terraform installed.
For ROSA, then follow `terraform/rosa-hcp/README.md`.

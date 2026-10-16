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

Two steps guard Argo CD's controller sharding. Once every cluster secret exists, the apply waits for
the GitOps operator's own dynamic-scaling restart of the application controller to settle, then
restarts the controller pods once: a controller that starts while the secrets change can leave a
cluster without a shard, and that cluster's Applications never get a status. At the end, the apply
waits until every spoke has Applications (the ApplicationSets generate them a few minutes after
the apply's own Applications) and fails if one has none, or an Application still has an empty sync
or health status, after `argocd_app_status_timeout_sec` (default 900; 0 disables), naming the
destination cluster. For an empty status the fix is the same restart:
`oc -n openshift-gitops delete pod -l app.kubernetes.io/name=openshift-gitops-application-controller`;
for a spoke with no Applications, check its ACM PlacementDecision and its Argo CD cluster Secret.

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
- ROSA: the ingress gateway Service gets an AWS NLB (`rosa_ingress_nlb`, default true). Behind a
  Classic LB it aborted HTTP requests (each arrived followed by a FIN); the east-west gateway
  (mTLS passthrough) stays on a Classic LB. This default is merged under `gitops_app_overrides`,
  so an override of `spoke-ingress-gateway-appset` adds to it. A Service created as a CLB does not
  change type in place: delete it once and Argo CD recreates it as an NLB.

The child apps sync from `gitops_app_repo_url` at `gitops_app_repo_revision`, so a fork or branch
deploys from itself. Edited charts roll out on the next apply.

## Tear down

`terraform destroy` deletes the Argo CD apps first, then uninstalls the operators Terraform installed.
For ROSA, then follow `terraform/rosa-hcp/README.md`.

On an existing hub (`acm_install_operator = false`) destroy keeps the MultiClusterHub and the
KlusterletConfig, but still deletes:

- the spoke ManagedClusters, unless `acm_keep_managed_clusters_on_destroy = true`;
- the spoke namespaces you imported. To keep them, first run
  `terraform state rm 'kubernetes_manifest.spoke_namespace'`;
- the OSSM operator on every spoke.

Destroy leaves the Argo CD cluster Secrets, which hold spoke credentials. Delete them afterwards:
`oc -n openshift-gitops delete secret <spoke>-argocd-gitops-cluster-secret` per spoke, or
`oc -n openshift-gitops delete secret -l argocd.argoproj.io/secret-type=cluster` if that Argo CD
manages no other clusters.

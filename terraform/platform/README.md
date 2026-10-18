# Platform and mesh (Terraform)

Installs Argo CD on the hub, registers the other clusters with it, and starts the Argo CD
app-of-apps that deploys the whole mesh (Sail operator, Istio, shared CA, secrets, gateways).

| `platform` | Hub gets | Clusters join through | Members get |
| --- | --- | --- | --- |
| `kubernetes` (default) | upstream Argo CD (`argo-cd` Helm chart) | an Argo CD cluster Secret each, with a ServiceAccount token | the upstream Sail operator (Helm) |
| `openshift` (optional, untested) | ACM and OpenShift GitOps (OLM) | ACM ManagedClusters, plus the Argo CD cluster Secrets | OSSM 3 (OLM) |

Two ways to find clusters:

| `cluster_provider` | Clusters come from | Hub |
| --- | --- | --- |
| `kubeconfig` (default) | `kubeconfig_path` + context names | `hub_cluster_context` |
| `rosa` (implies `platform = "openshift"`) | `terraform/rosa-hcp` state | the first cluster |

`platform` defaults to `kubernetes`, or to `openshift` with `cluster_provider = "rosa"`.

The hub runs Argo CD (and ACM on OpenShift) and is never a mesh member. Spoke context names become
the Argo CD cluster names (and ManagedCluster names on OpenShift), so they must be DNS-1123 labels:
short, lowercase, no `:` or `/`. Rename a context that is not, for example an EKS ARN:
`kubectl config rename-context <arn> mesh-a` (or `aws eks update-kubeconfig --alias mesh-a`).

## Run

```bash
cp terraform.tfvars.example terraform.tfvars   # platform, repo URL/branch, cluster_provider, contexts
./scripts/001-openapi-preflight.sh --contexts <hub-ctx>   # existing OpenShift hubs only
terraform init
terraform plan -out=platform.tfplan
terraform apply platform.tfplan
```

Then watch the rollout until every Application is Synced/Healthy (about 15–20 minutes):
`kubectl --context <hub-ctx> get applications.argoproj.io -n argocd` (`terraform output
gitops_namespace` names the namespace: `openshift-gitops` on OpenShift). A kind lab on one machine:
[docs/runbooks/kind-lab](../../docs/runbooks/kind-lab/README.md).

What the apply needs to reach:

- Every cluster's API server from this machine (the kubeconfig's URLs), and every member's API
  server from the hub's pods: the URL goes into the member's Argo CD cluster Secret and from there
  into the External Secrets stores and the Istio remote secrets. When the kubeconfig's URL works
  only from this machine (kind writes `https://127.0.0.1:<port>`), set the hub-side URL in
  `cluster_api_url_overrides`.
- The Argo CD chart repo (`argocd_chart_repository`) from this machine, and the git repo
  (`gitops_app_repo_url`) plus the operator chart repos from the hub (Argo CD pulls them): a
  mirror goes in through `gitops_app_overrides` (`terraform.tfvars.example`).

On `kubernetes` each member gets a ServiceAccount bound to `cluster-admin`
(`gitops_managed_service_account_name` in `spoke_service_account_namespace`, `kube-system` by
default) whose token authenticates Argo CD, the External Secrets pushes and the Istio remote
secrets to it. The hub's Argo CD Secret holds that token: treat the hub as the mesh's trust root.

At the end, the apply waits until every spoke has Applications (the ApplicationSets generate them a
few minutes after the apply's own Applications) and fails if one has none, or an Application still
has an empty sync or health status, after `argocd_app_status_timeout_sec` (default 900; 0
disables), naming the destination cluster. For a spoke with no Applications, check its Argo CD
cluster Secret (`kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster
--show-labels`: mesh members carry `istio-mesh-member=true`; on OpenShift also its ACM
PlacementDecision).

On OpenShift a second step guards Argo CD's controller sharding: once every cluster Secret exists,
the apply waits for the GitOps operator's own dynamic-scaling restart of the application controller
to settle, then restarts the controller pods once. A controller that starts while the Secrets
change can leave a cluster without a shard, and that cluster's Applications never get a status;
the fix by hand is the same restart:
`oc -n openshift-gitops delete pod -l app.kubernetes.io/name=openshift-gitops-application-controller`.
On `kubernetes` the controller runs a fixed number of replicas, so nothing rescales it mid-apply.

## Existing clusters

| Already installed on the hub | Set |
| --- | --- |
| Argo CD (`kubernetes`), in `gitops_namespace` | `gitops_install_operator = false` |
| cert-manager | `gitops_app_overrides = { "hub-cert-manager-operator" = { enabled = false } }` |
| ACM (`openshift`) | `acm_install_operator = false`, `acm_local_cluster_name = "local-cluster"` |
| OpenShift GitOps (`openshift`) | `gitops_install_operator = false` |

An existing Argo CD must run with the release name `argocd` (its controllers' ServiceAccounts are
`argocd-application-controller` and `argocd-applicationset-controller`, which the charts' RBAC
expects) and carry the settings `platform_gitops.tf` gives the chart (`argocd_upstream_values`):
the Sail health checks, the resource exclusions and git submodules off.

If the spokes are already ACM-managed (OpenShift), import their namespaces once before the first
apply: `terraform import 'kubernetes_manifest.spoke_namespace["<ctx>"]' "apiVersion=v1,kind=Namespace,name=<ctx>"`.

## Per-environment values

The chart defaults are sized for the 20-cluster campaign. Override them per environment without forking:

- `gitops_app_overrides`: per child app `enabled` and `values` (for example a smaller istiod, a
  MetalLB pool for the gateways, or a chart mirror). See `terraform.tfvars.example`.
- `argocd_helm_values` (`kubernetes`): values for the `argo-cd` chart, merged over the repo's
  tuning (`charts/argocd-config/values.yaml`); for example smaller requests on a small hub.
  `argocd_config_values` is the same for the OpenShift GitOps ArgoCD CR. Keep the controller
  limit near 6Gi on a busy hub.
- `mesh_member_count`: how many spokes join the mesh, in sorted order (0 = all).
- Large fleets: `argocd_clusters_per_shard` / `argocd_max_shards`.
- ROSA: the ingress gateway Service gets an AWS NLB (`rosa_ingress_nlb`, default true). Behind a
  Classic LB it aborted HTTP requests (each arrived followed by a FIN); the east-west gateway
  (mTLS passthrough) stays on a Classic LB. This default is merged under `gitops_app_overrides`,
  so an override of `spoke-ingress-gateway-appset` adds to it. A Service created as a CLB does not
  change type in place: delete it once and Argo CD recreates it as an NLB. On EKS set the same
  annotation yourself (`service.beta.kubernetes.io/aws-load-balancer-type: nlb`) through
  `gitops_app_overrides`.

The child apps sync from `gitops_app_repo_url` at `gitops_app_repo_revision`, so a fork or branch
deploys from itself. Edited charts roll out on the next apply.

## Tear down

`terraform destroy` deletes the Argo CD apps first, then uninstalls what Terraform installed. On
`kubernetes` it also deletes each spoke's Argo CD cluster Secret and its ServiceAccount, so no
cluster-admin token is left behind. For ROSA, then follow `terraform/rosa-hcp/README.md`.

On an existing OpenShift hub (`acm_install_operator = false`) destroy keeps the MultiClusterHub and
the KlusterletConfig, but still deletes:

- the spoke ManagedClusters, unless `acm_keep_managed_clusters_on_destroy = true`;
- the spoke namespaces you imported. To keep them, first run
  `terraform state rm 'kubernetes_manifest.spoke_namespace'`;
- the OSSM operator on every spoke.

On OpenShift destroy leaves the Argo CD cluster Secrets, which hold spoke credentials. Delete them
afterwards: `oc -n openshift-gitops delete secret <spoke>-argocd-gitops-cluster-secret` per spoke,
or `oc -n openshift-gitops delete secret -l argocd.argoproj.io/secret-type=cluster` if that Argo CD
manages no other clusters.

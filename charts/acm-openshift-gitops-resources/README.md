# acm-openshift-gitops-resources

Installs ManagedClusterSetBinding and Placement (plus, optionally, a ManagedClusterSet, the ApplicationSet placement-generator ConfigMap, and Argo CD application-controller RBAC) into `${GITOPS_NAMESPACE}` so the hub OpenShift GitOps / Argo CD instance can target spokes selected by an ACM Placement ([RHACM GitOps overview](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/gitops/gitops-overview)).

Applied by Terraform (`terraform/platform/platform_gitops.tf`, `helm_release.acm_gitops_resources`) after the OpenShift GitOps operator. This chart does **not** create a `GitOpsCluster`. The per-spoke Argo CD cluster `Secret`s are created and owned directly by Terraform (`create-argocd-cluster-secret.sh`) pointing at each spoke's direct external API URL — we deliberately do not let ACM's GitOpsCluster controller generate them, because it writes an unreachable `server` (`https://<name>-control-plane` in pull mode, or a flaky cluster-proxy URL in push mode) and reconciles it back on every change.

Default `clusterSet` is `istio-scale-tests`. When `managedClusterSet.create` is `true` (default), the chart installs a ManagedClusterSet with `spec: {}` (empty spec per hub requirement) named `istio-scale-tests`, a ManagedClusterSetBinding with the same name pointing at that set, and a Placement with `spec.clusterSets: [istio-scale-tests]`. Spokes must carry `cluster.open-cluster-management.io/clusterset=istio-scale-tests` (set by `charts/acm-managed-cluster` / `ACM_CLUSTER_SET`). Set `managedClusterSet.create: false` if the ManagedClusterSet already exists on the hub.

Placement sets `spec.clusterSets: [<clusterSet>]` so the controller selects that bound set; omitting `clusterSets` often yields status `NoManagedClusterSetBindings` / “No valid ManagedClusterSetBindings found”.

When `argocdPlacementDecisionGenerator.create` is true (default), the chart also installs ConfigMap `argocdPlacementDecisionGenerator.configMapName` (default `acm-gitops-placement-generator`) in `gitopsNamespace`. Hub ApplicationSet chart `charts/gitops-hub-ocm-placement-appset` (preset value files) references that ConfigMap for `clusterDecisionResource` and, by default, selects every `PlacementDecision` labeled `cluster.open-cluster-management.io/placement=<placement.name>`. This is required for large fleets where OCM splits one `Placement` across multiple `PlacementDecision` resources.

When `argocdApplicationControllerRbac.create` is true (default), the chart installs a ClusterRole and ClusterRoleBinding so the OpenShift GitOps Argo CD application controller service account can manage cluster-scoped `ManagedClusterSet` objects (`managedclustersets.cluster.open-cluster-management.io`). Disable only if you grant equivalent RBAC elsewhere.

## Placement “all except the first cluster”

By default `placement.excludeHubLocalClusterLabel: true`: the Placement selects every ManagedCluster in the bound set except those labeled `local-cluster` (the ACM hub / terraform `first_cluster`). Spokes must carry `cluster.open-cluster-management.io/clusterset=<clusterSet>` (see `charts/acm-managed-cluster`).

To select all clusters in the set (including the hub), set `placement.excludeHubLocalClusterLabel` to `false` (not typical for Argo CD).

## Required values

- `argoServer.cluster` — hub ManagedCluster name (`MultiClusterHub.spec.localClusterName`). Only gates the placement-generator ConfigMap: when empty, the chart renders ManagedClusterSet (optional), ManagedClusterSetBinding, Placement, and RBAC, but **skips** the ConfigMap. In the Terraform deployment this is left empty on purpose — Terraform creates the placement-generator ConfigMap itself (`kubernetes_manifest.placement_generator_configmap`) only after the cluster secrets exist.

## Example

```bash
helm upgrade --install acm-openshift-gitops-resources ./charts/acm-openshift-gitops-resources \
  --kube-context "$HUB_CTX" \
  --namespace openshift-gitops --create-namespace \
  --set argoServer.cluster="$HUB_MANAGED_CLUSTER_NAME" \
  --set clusterSet=istio-scale-tests
```

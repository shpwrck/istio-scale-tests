# acm-openshift-gitops-resources

Installs **ManagedClusterSetBinding**, **Placement**, and **GitOpsCluster** into `${GITOPS_NAMESPACE}` so the hub OpenShift GitOps / Argo CD instance registers spokes ([RHACM GitOps overview](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/gitops/gitops-overview)).

Applied by `istio-setup/011-acm-openshift-gitops.sh` after the OpenShift GitOps operator chart.

Default **`clusterSet`** is **`istio-scale-tests`**. When **`managedClusterSet.create`** is `true` (default), the chart installs a **ManagedClusterSet** with **`spec: {}`** (empty spec per hub requirement) named **`istio-scale-tests`**, a **ManagedClusterSetBinding** with the same name pointing at that set, **Placement** with **`spec.clusterSets: [istio-scale-tests]`**, and **GitOpsCluster** referencing that Placement. Spokes must carry **`cluster.open-cluster-management.io/clusterset=istio-scale-tests`** (**001** / `ACM_CLUSTER_SET`). Set **`managedClusterSet.create: false`** if the **ManagedClusterSet** already exists on the hub.

**Placement** sets **`spec.clusterSets: [<clusterSet>]`** so the controller selects that bound set; omitting **`clusterSets`** often yields status **`NoManagedClusterSetBindings`** / “No valid ManagedClusterSetBindings found”.

## Placement “all except the first cluster”

By default **`placement.excludeHubLocalClusterLabel: true`**: the Placement selects every ManagedCluster in the bound set **except** those labeled `local-cluster` (the ACM hub / terraform `first_cluster`). Spokes must carry `cluster.open-cluster-management.io/clusterset=<clusterSet>` (see `charts/acm-managed-cluster` / **001**).

To select **all** clusters in the set (including the hub), set `placement.excludeHubLocalClusterLabel` to `false` (not typical for Argo CD).

## Required values

- `argoServer.cluster` — hub **ManagedCluster** name (`localClusterName`).

## Example

```bash
helm upgrade --install acm-openshift-gitops-resources ./charts/acm-openshift-gitops-resources \
  --kube-context "$HUB_CTX" \
  --namespace openshift-gitops --create-namespace \
  --set argoServer.cluster="$HUB_MANAGED_CLUSTER_NAME" \
  --set clusterSet=istio-scale-tests
```

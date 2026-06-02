# acm-managed-cluster Helm chart

Install once per spoke: one cluster-scoped `ManagedCluster` on the hub. Release names should be unique per cluster (for example `acm-managed-cluster-cluster-002`).

Terraform (`terraform/platform/platform_acm_spokes.tf`) installs one `helm_release.acm_managed_cluster` per spoke on the hub and writes an `auto-import-secret` in that spoke's hub namespace; the RHACM import controller consumes the secret and registers the spoke (no manual `import.yaml` extraction).

## Values

- `managedCluster.name` (required) — must match the spoke’s kubectl/oc context name and the hub namespace RHACM creates for that cluster.
- `clustersetName` (default `istio-scale-tests`) — sets label `cluster.open-cluster-management.io/clusterset=<name>` for ManagedClusterSet membership (must match `var.acm_cluster_set` and the `acm-openshift-gitops-resources` chart `clusterSet`).
- `managedCluster.labels` — merged over `defaultLabels` and the clusterset label (can override membership if needed).

## Manual Helm

```bash
helm upgrade --install acm-managed-cluster-cluster-002 ./charts/acm-managed-cluster \
  --kube-context "$HUB_CONTEXT" \
  --namespace open-cluster-management --create-namespace \
  --set managedCluster.name=cluster-002 \
  --set clustersetName=istio-scale-tests
```

See RHACM docs for import secrets (`${CLUSTER_NAME}-import`, `auto-import-secret`, manual import). Terraform automates this per spoke via the `auto-import-secret` (see `terraform/platform/platform_acm_spokes.tf`).

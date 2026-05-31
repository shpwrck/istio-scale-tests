# acm-managed-cluster Helm chart

Install once per spoke: one cluster-scoped `ManagedCluster` on the hub. Release names should be unique per cluster (for example `acm-managed-cluster-cluster-002`).

`platform-setup/001-acm-install-hub.sh` processes each Terraform spoke key in order: `helm upgrade --install` on the hub, waits for the hub import / auto-import secret (`import.yaml`), applies `crds.yaml` from that secret on the spoke when present (else CRD stanzas embedded in `import.yaml`), then applies the full `import.yaml` on the spoke (with retries). Repeat for the next cluster.

## Values

- `managedCluster.name` (required) — must match the spoke’s kubectl/oc context name and the hub namespace RHACM creates for that cluster.
- `clustersetName` (default `istio-scale-tests`) — sets label `cluster.open-cluster-management.io/clusterset=<name>` for ManagedClusterSet membership (`ACM_CLUSTER_SET` / platform-setup/002 chart `clusterSet` must match).
- `managedCluster.labels` — merged over `defaultLabels` and the clusterset label (can override membership if needed).

## Manual Helm

```bash
helm upgrade --install acm-managed-cluster-cluster-002 ./charts/acm-managed-cluster \
  --kube-context "$HUB_CONTEXT" \
  --namespace open-cluster-management --create-namespace \
  --set managedCluster.name=cluster-002 \
  --set clustersetName=istio-scale-tests
```

See RHACM docs for import secrets (`${CLUSTER_NAME}-import`, `auto-import-secret`, manual import). platform-setup/001 automates the full flow per cluster.

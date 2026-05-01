# acm-managed-cluster Helm chart

Install **once per spoke**: one cluster-scoped `ManagedCluster` on the hub. Release names should be unique per cluster (for example `acm-managed-cluster-rosa-002`).

`istio-setup/001-acm-install-hub.sh` processes each Terraform spoke key in order: `helm upgrade --install` on the **hub**, waits for the hub import / **auto-import** secret (`import.yaml`), applies **`crds.yaml`** from that secret on the **spoke** when present (else CRD stanzas embedded in `import.yaml`), then applies the full `import.yaml` on the **spoke** (with retries). Repeat for the next cluster.

## Values

- `managedCluster.name` (required) — must match the spoke’s kubectl/oc context name and the hub namespace RHACM creates for that cluster.
- `managedCluster.labels` — merged over `defaultLabels`.

## Manual Helm

```bash
helm upgrade --install acm-managed-cluster-rosa-002 ./charts/acm-managed-cluster \
  --kube-context "$HUB_CONTEXT" \
  --namespace open-cluster-management --create-namespace \
  --set managedCluster.name=rosa-002
```

See RHACM docs for import secrets (`${CLUSTER_NAME}-import`, `auto-import-secret`, manual import). **001** automates the full flow per cluster.

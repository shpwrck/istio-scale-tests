# acm-managed-cluster Helm chart

Install **once per spoke**: one cluster-scoped **`ManagedCluster`** on the hub. Release names should be unique per cluster (for example `acm-managed-cluster-rosa-002`).

`istio-setup/001-acm-install-hub.sh` loops Terraform spoke keys and runs `helm upgrade --install` for each.

## Values

- **`managedCluster.name`** (required) — must match the spoke’s kubectl/oc context name and the hub namespace RHACM creates for that cluster.
- **`managedCluster.labels`** — merged over **`defaultLabels`**.

## Manual Helm

```bash
helm upgrade --install acm-managed-cluster-rosa-002 ./charts/acm-managed-cluster \
  --kube-context "$HUB_CONTEXT" \
  --namespace open-cluster-management --create-namespace \
  --set managedCluster.name=rosa-002
```

Import klusterlet on the spoke using the hub secret **`${CLUSTER_NAME}-import`** (see RHACM docs) or rely on **001** automation.

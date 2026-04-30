# acm-hub Helm chart

Templates for installing the **Red Hat Advanced Cluster Management** hub operator on OpenShift: `Namespace`, `OperatorGroup`, `Subscription`, and optionally `MultiClusterHub`.

## Editing manifests

- **`values.yaml`** — channels, names, `MultiClusterHub.spec`, target namespaces for the OperatorGroup.
- **`templates/`** — Kubernetes shapes when you need schema changes beyond values.

The install script `istio-setup/001-acm-install-hub.sh` runs Helm in two phases (`multiclusterHub.enabled=false` then `true`) so the operator CSV can succeed before the hub CR is applied.

## Overrides

Pass a custom values file when running Helm yourself:

```bash
helm upgrade --install acm-hub ./charts/acm-hub \
  --namespace open-cluster-management --create-namespace \
  --set subscription.channel=release-2.15 \
  -f my-acm-values.yaml
```

Do **not** set `multiclusterHub.enabled=false` on an existing release that already has the hub running unless you intend Helm to drop that resource from the release (and likely delete the CR).

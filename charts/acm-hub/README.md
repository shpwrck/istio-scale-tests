# acm-hub Helm chart

Templates for installing the **Red Hat Advanced Cluster Management** hub operator on OpenShift: `Namespace`, `OperatorGroup`, `Subscription`, and `MultiClusterHub` in one release.

## Editing manifests

- `values.yaml` — channels, names, `MultiClusterHub.spec`, target namespaces for the OperatorGroup. `spec.localClusterName` is injected by `istio-setup/001-acm-install-hub.sh` from Terraform `first_cluster.cluster_name` (RHACM max **34** characters); override with `--local-cluster-name` or `ACM_LOCAL_CLUSTER_NAME`.
- `templates/` — Kubernetes shapes when you need schema changes beyond values.

The install script `istio-setup/001-acm-install-hub.sh` applies this chart once (`helm upgrade --install`), then waits for the operator CSV and `MultiClusterHub` phase **Running** (unless `--skip-wait`). After **Running**, it merges kubeconfig via `terraform/scripts/001-oc-login-merge-kubeconfig.sh`, installs `charts/acm-managed-cluster` per Terraform spoke key (excluding the hub), and applies RHACM import YAML on each spoke. Use `--skip-managed-clusters` or `--skip-import` to skip parts of that flow.

## Overrides

Pass a custom values file when running Helm yourself:

```bash
helm upgrade --install acm-hub ./charts/acm-hub \
  --namespace open-cluster-management --create-namespace \
  --set subscription.channel=release-2.16 \
  -f my-acm-values.yaml
```

The operator reconciles `MultiClusterHub` after the subscription installs; until the CSV succeeds, the hub CR may stay pending—use `oc get csv,mch -n open-cluster-management` to watch progress.

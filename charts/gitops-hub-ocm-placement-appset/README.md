# gitops-hub-ocm-placement-appset

Standard Argo CD ApplicationSet for RHACM GitOps: `clusterDecisionResource` (shared duck-type ConfigMap from `charts/acm-openshift-gitops-resources`) plus optional list generator for the hub Argo cluster name (`in-cluster` by default).

Preset value files:

- `values-external-secrets.yaml` — installs `charts/external-secrets-operator` on every cluster in Placement (`clusterDecisionResource`, typically spokes without `local-cluster`) plus the hub list entry (`in-cluster` default, `destination.mode: clusterName` on each Application).
- `values-kubeconfig-from-argosecret.yaml` — installs `charts/hub-kubeconfig-from-argosecret` on the hub only (`destination.mode: inClusterServer`), one child Application per Placement cluster plus the hub list row (External Secrets reads each `*-application-manager-cluster-secret` and writes `kubeconfig-*` Secrets).
- `values-mesh-ca-intermediate.yaml` — installs `charts/hub-mesh-ca-intermediate` only on the hub API (`destination.mode: inClusterServer`).

Override `repo.url` / `placement.name` / `generatorConfigMap` / RBAC names via Helm or Argo `parameters` as needed.

`values-mesh-ca-intermediate.yaml` uses `destination.mode: inClusterServer`; the chart template emits the `clusterName` Helm parameter with a literal `{{clusterName}}` for ApplicationSet substitution (do not copy that string into another values file with `| quote` in a custom template). Per-cluster presets use `destination.mode: clusterName` and set `template.source.helm.releaseName` only for that mode so hub-only installs do not inherit an OLM `releaseName` from chart defaults.

```bash
helm upgrade --install gitops-hub-ocm-placement-es ./charts/gitops-hub-ocm-placement-appset \
  --namespace openshift-gitops \
  -f charts/gitops-hub-ocm-placement-appset/values-external-secrets.yaml \
  --set repo.url="https://github.com/example-org/istio-scale-tests.git" \
  --set repo.revision=main
```

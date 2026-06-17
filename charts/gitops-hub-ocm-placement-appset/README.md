# gitops-hub-ocm-placement-appset

Standard Argo CD ApplicationSet for RHACM GitOps: `clusterDecisionResource` (shared duck-type ConfigMap from `charts/acm-openshift-gitops-resources`) plus optional list generator for the hub Argo cluster name (`in-cluster` by default).

By default the chart selects all `PlacementDecision` objects labeled for `placement.name` (`cluster.open-cluster-management.io/placement=<placement.name>`). Keep `placement.placementDecisionName` empty for large fleets, because OCM can split one `Placement` across multiple `PlacementDecision` resources. Set `placement.placementDecisionName` only when you intentionally want one exact decision resource.

Preset value files:

- `values-external-secrets.yaml` — installs `charts/external-secrets-operator` on every cluster in Placement (`clusterDecisionResource`, typically spokes without `local-cluster`) plus the hub list entry (`in-cluster` default, `destination.mode: clusterName` on each Application).
- `values-kubeconfig-from-argosecret.yaml` — installs `charts/hub-kubeconfig-from-argosecret` on the hub only (`destination.mode: inClusterServer`), child Applications use `destination.namespace: external-secrets-operator` (SecretStore/ExternalSecret land where the ESO operand reconciles; Argo cluster Secrets are read from `openshift-gitops` via chart values).
- `values-mesh-ca-intermediate.yaml` — installs `charts/hub-mesh-ca-intermediate` only on the hub API (`destination.mode: inClusterServer`).

Override `repo.url` / `placement.name` / `generatorConfigMap` / RBAC names via Helm or Argo `parameters` as needed.

Child Helm values can be supplied to the generated Application by **name** via `template.source.helm.valuesObject` (a YAML map) in addition to the positional `template.source.helm.parameters` list. The chart emits `valuesObject` verbatim into each Application's `spec.source.helm.valuesObject`, which Argo merges into the child chart's values. Prefer `valuesObject` for static, name-addressed values (e.g. `expectedMembers`) so reordering/inserting `parameters` entries cannot misroute them; keep `parameters` for values that must carry an ApplicationSet generator placeholder like `{{clusterName}}`. `values-mesh-wiring-verify.yaml` uses this split (Terraform sets `template.source.helm.valuesObject.expectedMembers` by name — see issue #28).

`values-mesh-ca-intermediate.yaml` uses `destination.mode: inClusterServer`; the chart template emits the `clusterName` Helm parameter with a literal `{{clusterName}}` for ApplicationSet substitution (do not copy that string into another values file with `| quote` in a custom template). Per-cluster presets use `destination.mode: clusterName` and set `template.source.helm.releaseName` only for that mode so hub-only installs do not inherit an OLM `releaseName` from chart defaults.

```bash
helm upgrade --install gitops-hub-ocm-placement-es ./charts/gitops-hub-ocm-placement-appset \
  --namespace openshift-gitops \
  -f charts/gitops-hub-ocm-placement-appset/values-external-secrets.yaml \
  --set repo.url="https://github.com/example-org/istio-scale-tests.git" \
  --set repo.revision=main
```

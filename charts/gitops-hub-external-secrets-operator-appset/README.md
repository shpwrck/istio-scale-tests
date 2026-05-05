# gitops-hub-external-secrets-operator-appset

Installs:

- RBAC — ApplicationSet controller reads placementdecisions in applicationSetNamespace; Argo application controller can sync this chart into that namespace.
- Optional ConfigMap — duck-type for ApplicationSet clusterDecisionResource only when `generatorConfigMap.create` is true (default false: use the shared ConfigMap from `charts/acm-openshift-gitops-resources`).
- ApplicationSet with two generators:
  - clusterDecisionResource — spokes from PlacementDecision `{placement.name}-decision-1` by default.
  - list (optional, `inClusterGenerator.enabled`) — static hub entry with Argo cluster name `in-cluster` (Placement excludes the hub via RHACM ManagedCluster label `local-cluster=true`).

Generated Applications install Helm chart `charts/external-secrets-operator` on each Argo-registered cluster: `spec.destination.name` is the cluster name; namespace is `applicationDestinationNamespace` (default `external-secrets-operator`).

Disable the static hub app with `inClusterGenerator.enabled: false`.

```bash
helm upgrade --install gitops-hub-external-secrets-operator-appset ./charts/gitops-hub-external-secrets-operator-appset \
  --namespace openshift-gitops \
  --set applicationSetNamespace=openshift-gitops \
  --set placement.name=acm-openshift-gitops-placement \
  --set repo.url="https://github.com/example-org/istio-scale-tests.git" \
  --set repo.revision=main
```

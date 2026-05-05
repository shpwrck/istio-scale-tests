# gitops-hub-mesh-ca-intermediate-appset

Installs:

- RBAC — ApplicationSet controller reads `placementdecisions` in `applicationSetNamespace`; Argo application controller can sync this chart into that namespace.
- Optional ConfigMap — duck-type for ApplicationSet `clusterDecisionResource` only when `generatorConfigMap.create` is true (default false: use the shared ConfigMap from `charts/acm-openshift-gitops-resources`, `argocdPlacementDecisionGenerator.configMapName`, installed earlier by `platform-setup/002`).
- ApplicationSet with two generators:
  - `clusterDecisionResource` — spokes from PlacementDecision named `{placement.name}-decision-1` by default (override with `placement.placementDecisionName`). Must match the Placement from `charts/acm-openshift-gitops-resources`.
  - `list` (optional, `inClusterGenerator.enabled`) — one static Application for the hub using Argo cluster name `in-cluster`, because the Placement excludes the hub ManagedCluster (RHACM label `local-cluster=true`).

Generated Applications use `applicationDestinationNamespace` (default `openshift-gitops`) and Helm `charts/hub-mesh-ca-intermediate` with `clusterName` from each generator.

Disable the static hub entry with `inClusterGenerator.enabled: false`.

```bash
helm upgrade --install gitops-hub-mesh-ca-intermediate-appset ./charts/gitops-hub-mesh-ca-intermediate-appset \
  --namespace openshift-gitops \
  --set applicationSetNamespace=openshift-gitops \
  --set placement.name=acm-openshift-gitops-placement \
  --set repo.url="https://github.com/example-org/istio-scale-tests.git" \
  --set repo.revision=main
```

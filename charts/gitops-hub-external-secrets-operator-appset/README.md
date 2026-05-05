# gitops-hub-external-secrets-operator-appset

Installs:

- ConfigMap — duck-type for ApplicationSet clusterDecisionResource (OCM PlacementDecision).
- RBAC — ApplicationSet controller reads placementdecisions in applicationSetNamespace; Argo application controller can sync this chart into that namespace.
- ApplicationSet with two generators:
  - clusterDecisionResource — spokes from placement.placementDecisionName (default acm-openshift-gitops-placement-decision-1 in openshift-gitops, same as GitOps Placement).
  - list (optional, localClusterGenerator.enabled) — one static Application for the hub using clusterName local-cluster, because GitOps Placement excludes the hub.

Generated Applications install Helm chart charts/external-secrets-operator on each Argo-registered cluster: spec.destination.name is the cluster name (ManagedCluster / PlacementDecision clusterName), and namespace is applicationDestinationNamespace (default external-secrets-operator).

Disable the static hub app with localClusterGenerator.enabled: false.

```bash
helm upgrade --install gitops-hub-external-secrets-operator-appset ./charts/gitops-hub-external-secrets-operator-appset \
  --namespace openshift-gitops \
  --set applicationSetNamespace=openshift-gitops \
  --set placement.placementDecisionName=acm-openshift-gitops-placement-decision-1 \
  --set repo.url="https://github.com/example-org/istio-scale-tests.git" \
  --set repo.revision=main
```

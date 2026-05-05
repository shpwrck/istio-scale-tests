# gitops-hub-ocm-placement-appset

Standard Argo CD ApplicationSet for RHACM GitOps: **clusterDecisionResource** (shared duck-type ConfigMap from `charts/acm-openshift-gitops-resources`) plus optional **list** generator for the hub Argo cluster name (`in-cluster` by default).

Preset value files:

- `values-external-secrets.yaml` — installs `charts/external-secrets-operator` on **every cluster** in Placement plus the hub (`destination.mode: clusterName`).
- `values-mesh-ca-intermediate.yaml` — installs `charts/hub-mesh-ca-intermediate` only on the hub API (`destination.mode: inClusterServer`).

Override `repo.url` / `placement.name` / `generatorConfigMap` / RBAC names via Helm or Argo `parameters` as needed.

```bash
helm upgrade --install gitops-hub-ocm-placement-es ./charts/gitops-hub-ocm-placement-appset \
  --namespace openshift-gitops \
  -f charts/gitops-hub-ocm-placement-appset/values-external-secrets.yaml \
  --set repo.url="https://github.com/example-org/istio-scale-tests.git" \
  --set repo.revision=main
```

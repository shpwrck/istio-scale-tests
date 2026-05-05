# gitops-hub-mesh-ca-intermediate-appset

Installs:

- **ConfigMap** — duck-type for ApplicationSet [clusterDecisionResource](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Cluster-Decision-Resource/) (OCM `PlacementDecision`).
- **RBAC** — ApplicationSet controller reads **`placementdecisions`** in **`applicationSetNamespace`**; Argo application controller can sync this chart into that namespace.
- **ApplicationSet** with two generators:
  - **clusterDecisionResource** — spokes from **`placement.placementDecisionName`** (default **`acm-openshift-gitops-placement-decision-1`** in **`openshift-gitops`**, same as GitOps **`Placement`**).
  - **list** (optional, **`localClusterGenerator.enabled`**) — one static Application for the hub using **`clusterName`** **`local-cluster`** (Argo in-cluster), because GitOps **`Placement`** excludes the hub.

Generated Applications use **`applicationDestinationNamespace`** (default **`openshift-gitops`**) and Helm **`charts/hub-mesh-ca-intermediate`** with **`clusterName`** from each generator.

Disable the static hub app with **`localClusterGenerator.enabled: false`**.

```bash
helm upgrade --install gitops-hub-mesh-ca-intermediate-appset ./charts/gitops-hub-mesh-ca-intermediate-appset \
  --namespace openshift-gitops \
  --set applicationSetNamespace=openshift-gitops \
  --set placement.placementDecisionName=acm-openshift-gitops-placement-decision-1 \
  --set repo.url="https://github.com/example-org/istio-scale-tests.git" \
  --set repo.revision=main
```

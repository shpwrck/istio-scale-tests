# gitops-hub-mesh-ca-intermediate-appset

Installs:

- **ConfigMap** — duck-type definition for Argo CD ApplicationSet [clusterDecisionResource](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Cluster-Decision-Resource/) (OCM `PlacementDecision`).
- **Role** / **RoleBinding** — lets **`openshift-gitops-applicationset-controller`** read `placementdecisions` in **`gitopsNamespace`**.
- **ApplicationSet** — **clusterDecisionResource** targets one **PlacementDecision** by **`metadata.name`** (`placement.placementDecisionName`, default **`global-decision-1`**) so decisions include the hub cluster as well as spokes; each entry syncs **`charts/hub-mesh-ca-intermediate`** with **`clusterName`** set.

Requires **`repo.url`** (same fork Argo uses). Hub **`hub-mesh-ca`** Application should set **`intermediates.enabled=false`** so root CA stays in `charts/hub-mesh-ca` and intermediates come only from this ApplicationSet.

The OpenShift GitOps instance must run the **ApplicationSet controller** (included with typical OpenShift GitOps subscriptions).

OCM expects the hub GitOps namespace to be bound to the relevant **ManagedClusterSet** so PlacementDecisions are readable (`clusteradm clusterset bind … --namespace openshift-gitops` or equivalent RBAC). See [Integration with Argo CD](https://open-cluster-management.io/docs/scenarios/integration-with-argocd).

```bash
helm upgrade --install gitops-hub-mesh-ca-intermediate-appset ./charts/gitops-hub-mesh-ca-intermediate-appset \
  --kube-context "$HUB_CTX" \
  --namespace openshift-gitops \
  --set gitopsNamespace=openshift-gitops \
  --set repo.url="https://github.com/example-org/istio-scale-tests.git" \
  --set repo.revision=main
```

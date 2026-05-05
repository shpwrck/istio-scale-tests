# gitops-hub-mesh-ca-intermediate-appset

Installs:

- **ConfigMap** — duck-type definition for Argo CD ApplicationSet [clusterDecisionResource](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Cluster-Decision-Resource/) (OCM `PlacementDecision`).
- **Role** / **RoleBinding** — lets **`openshift-gitops-applicationset-controller`** read **`placementdecisions`** in **`applicationSetNamespace`** (same namespace as the **PlacementDecision**, default **`open-cluster-management-global-set`**).
- **ApplicationSet** — **clusterDecisionResource** resolves **`placement.placementDecisionName`** (default **`global-decision-1`**) in **`applicationSetNamespace`**. Each matching cluster syncs **`charts/hub-mesh-ca-intermediate`**; generated Applications use **`applicationDestinationNamespace`** (default **`openshift-gitops`**) for Helm on the hub.

The Argo CD **clusterDecisionResource** generator looks up the named resource in the **same namespace as the ApplicationSet**, so **`applicationSetNamespace`** must match where **`global-decision-1`** lives.

Requires **`repo.url`** (same fork Argo uses). Hub **`hub-mesh-ca`** Application should set **`intermediates.enabled=false`** so root CA stays in `charts/hub-mesh-ca` and intermediates come only from this ApplicationSet.

The OpenShift GitOps instance must run the **ApplicationSet controller**. If you install the **ApplicationSet** outside **`openshift-gitops`**, the `ArgoCD` custom resource may need **`spec.applicationSet.sourceNamespaces`** including **`open-cluster-management-global-set`** so the controller reconciles it (see [AppSets in any namespace](https://argocd-operator.readthedocs.io/en/latest/usage/appsets-in-any-namespace/) / product docs for your version).

```bash
helm upgrade --install gitops-hub-mesh-ca-intermediate-appset ./charts/gitops-hub-mesh-ca-intermediate-appset \
  --kube-context "$HUB_CTX" \
  --namespace open-cluster-management-global-set \
  --set applicationSetNamespace=open-cluster-management-global-set \
  --set applicationDestinationNamespace=openshift-gitops \
  --set repo.url="https://github.com/example-org/istio-scale-tests.git" \
  --set repo.revision=main
```

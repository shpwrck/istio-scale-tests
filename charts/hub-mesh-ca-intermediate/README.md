# hub-mesh-ca-intermediate

Renders one intermediate mesh CA `Certificate` in **`namespace`** (default `cert-manager`), signed by **`rootClusterIssuerName`** (default `mesh-root-ca` from `charts/hub-mesh-ca`).

**`clusterName`** must be set (typically from Argo CD ApplicationSet `clusterDecisionResource` / OCM `PlacementDecision`).

Installed on the hub only; destination cluster is always the hub API server. When **`rbac.enabled`** is true (default), this chart installs a **Role** and **RoleBinding** in **`namespace`** so `openshift-gitops-argocd-application-controller` can manage **`certificates.cert-manager.io`** and **Secrets** there (same scope as `charts/hub-mesh-ca` namespaced RBAC). That is required for ApplicationSet-driven installs: `charts/gitops-hub-ocm-placement-appset` only grants the controller RBAC in `openshift-gitops`, not in `cert-manager`.

See `charts/gitops-hub-ocm-placement-appset` and `values-mesh-ca-intermediate.yaml` for the ApplicationSet that instantiates one Application per Placement cluster.

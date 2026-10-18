# hub-mesh-ca-intermediate

Renders one intermediate mesh CA `Certificate` in **`namespace`** (default `cert-manager`), signed by **`rootClusterIssuerName`** (default `mesh-root-ca` from `charts/hub-mesh-ca`).

**`clusterName`** must be set: the ApplicationSet sets it per mesh member (on Kubernetes from the Argo CD cluster Secret's name, on OpenShift from the ACM `PlacementDecision`).

Installed on the hub only; destination cluster is always the hub API server. When **`rbac.enabled`** is true (default), this chart installs a **Role** and **RoleBinding** in **`namespace`** so the Argo CD application controller (`argocd/argocd-application-controller`; `openshift-gitops/openshift-gitops-argocd-application-controller` on OpenShift, from `values-openshift.yaml`) can manage **`certificates.cert-manager.io`** and **Secrets** there (same scope as `charts/hub-mesh-ca` namespaced RBAC). That is required for ApplicationSet-driven installs: `charts/gitops-hub-ocm-placement-appset` only grants the controller RBAC in the Argo CD namespace, not in `cert-manager`.

See `charts/gitops-hub-ocm-placement-appset` and `values-mesh-ca-intermediate.yaml` for the ApplicationSet that instantiates one Application per mesh member.

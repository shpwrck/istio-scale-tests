# hub-mesh-ca-intermediate

Renders one intermediate mesh CA `Certificate` in **`namespace`** (default `cert-manager`), signed by **`rootClusterIssuerName`** (default `mesh-root-ca` from `charts/hub-mesh-ca`).

**`clusterName`** must be set (typically from Argo CD ApplicationSet `clusterDecisionResource` / OCM `PlacementDecision`).

Installed on the hub only; destination cluster is always the hub API server. RBAC for the Argo CD application controller to manage `cert-manager.io` resources in `cert-manager` is provided by `charts/hub-mesh-ca` (`rbac` templates).

See `charts/gitops-hub-mesh-ca-intermediate-appset` for the ApplicationSet that instantiates one Application per Placement cluster.

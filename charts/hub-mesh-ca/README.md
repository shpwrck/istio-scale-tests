# hub-mesh-ca

Mesh root CA chain on the hub, synced by the Argo CD Application `hub-mesh-ca`
(`charts/gitops-hub-apps`). Requires the cert-manager operator.

| Kind | Name |
| --- | --- |
| ClusterIssuer | `mesh-selfsigned-bootstrap` (self-signed) |
| Certificate (in `namespace`) | `mesh-root-ca`, Secret `mesh-root-ca-material` |
| ClusterIssuer | `mesh-root-ca` (CA backed by the root Secret) |
| Role/RoleBinding, ClusterRole/ClusterRoleBinding | Argo CD controller access (`rbac.enabled`) |

Per-cluster intermediate CAs come from `charts/hub-mesh-ca-intermediate`; their Istio
`cacerts` Secrets are pushed to each spoke by `charts/hub-mesh-push-secrets`.

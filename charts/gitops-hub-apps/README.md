# gitops-hub-apps

Helm chart rendered by the root Application `hub-gitops-root`
(`charts/gitops-hub-app-of-apps`). It creates the child Argo CD Applications; sync waves
are listed in [`../README.md`](../README.md).

| Value | Default | Purpose |
| --- | --- | --- |
| `gitopsNamespace` | `openshift-gitops` | Namespace of the child Applications |
| `repo.url` | `""` (required) | Git URL for every child Application and ApplicationSet |
| `repo.revision` | `main` | Git revision for the same |
| `apps.<name>.enabled` | `true` | Render that child Application |

Disable an app when that operator is already installed, e.g.
`apps.hub-cert-manager-operator.enabled=false`.

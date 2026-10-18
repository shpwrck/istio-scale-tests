# gitops-hub-app-of-apps

Installed by Terraform (`helm_release.gitops_hub_app_of_apps`). Renders one Argo CD
Application, `hub-gitops-root`, which Helm-renders `charts/gitops-hub-apps` from
`repo.url` at `repo.revision` and passes `gitopsNamespace`, `repo` and `apps` to it.

| Value | Default | Purpose |
| --- | --- | --- |
| `platform` | `kubernetes` | `kubernetes` or `openshift`; passed to `charts/gitops-hub-apps` |
| `gitopsNamespace` | `argocd` (`openshift-gitops` on OpenShift) | Argo CD namespace |
| `repo.url` | `""` (required) | Git URL (your fork) |
| `repo.revision` | `main` | Branch, tag or commit |
| `apps` | `{}` | Per-app toggles, e.g. `{hub-cert-manager-operator: {enabled: false}}` |
| `syncPolicy.automated` | `prune: false`, `selfHeal: true` | Root sync policy |

For a private repo, Terraform creates the Argo CD repository Secret first
(`var.gitops_app_repo_password` or `var.gitops_app_repo_ssh_private_key`).

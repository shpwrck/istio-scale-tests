# gitops-hub-app-of-apps

Renders Argo CD `Application` objects into `${GITOPS_NAMESPACE}`:

- `hub-gitops-root` — directory-syncs `charts/gitops-hub-apps/applications` from your Git fork (plain YAML; add child `Application` manifests there so they are picked up after push + sync).
- Child apps (for example `hub-cert-manager-operator`, `hub-mesh-ca`) live in that directory in Git — not as Helm templates in this chart.

Requires `repo.url` (terraform `var.gitops_app_repo_url`). Each child Application’s `spec.source.repoURL` must match the URL Argo uses for the repo (same fork).

For a private Git repository, Terraform applies an Argo CD repository `Secret` (label `argocd.argoproj.io/secret-type=repository`) before this chart: set `var.gitops_app_repo_password` (with optional `var.gitops_app_repo_username`) for HTTPS, or `var.gitops_app_repo_ssh_private_key` with an SSH `var.gitops_app_repo_url`.

```bash
helm upgrade --install gitops-hub-app-of-apps ./charts/gitops-hub-app-of-apps \
  --kube-context "$HUB_CTX" \
  --namespace openshift-gitops \
  --set gitopsNamespace=openshift-gitops \
  --set repo.url="https://github.com/example-org/istio-scale-tests.git" \
  --set repo.revision=main
```

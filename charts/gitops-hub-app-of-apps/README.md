# gitops-hub-app-of-apps

Renders Argo CD `Application` objects into `${GITOPS_NAMESPACE}`:

- `hub-gitops-root` — directory-syncs `charts/gitops-hub-apps/applications` from your Git fork (plain YAML; add child `Application` manifests there so they are picked up after push + sync).
- Child apps (for example `hub-cert-manager-operator`, `hub-mesh-ca`) live in that directory in Git — not as Helm templates in this chart.

Requires `repo.url` (set `GITOPS_APP_REPO_URL` when using `platform-setup/002-acm-openshift-gitops.sh`). Each child Application’s `spec.source.repoURL` must match the URL Argo uses for the repo (same fork).

For a private Git repository, `002` can apply an Argo CD repository `Secret` (label `argocd.argoproj.io/secret-type=repository`) before this chart: set `GITOPS_APP_REPO_TOKEN` / `GITOPS_APP_REPO_TOKEN_FILE` / `GITOPS_APP_REPO_PASSWORD` with optional `GITOPS_APP_REPO_USERNAME` for HTTPS, or `GITOPS_APP_REPO_SSH_PRIVATE_KEY_FILE` with an SSH `GITOPS_APP_REPO_URL`. See `platform-setup/002-acm-openshift-gitops.sh --help`.

```bash
helm upgrade --install gitops-hub-app-of-apps ./charts/gitops-hub-app-of-apps \
  --kube-context "$HUB_CTX" \
  --namespace openshift-gitops \
  --set gitopsNamespace=openshift-gitops \
  --set repo.url="https://github.com/example-org/istio-scale-tests.git" \
  --set repo.revision=main
```

# gitops-hub-app-of-apps

Renders Argo CD `Application` objects into `${GITOPS_NAMESPACE}`:

- `hub-gitops-root` — Helm-syncs `charts/gitops-hub-apps` from your Git fork (add child `Application` YAML under that chart’s `templates/`).
- `hub-cert-manager-operator` — Helm-syncs `charts/cert-manager-operator` (OLM install for cert-manager Operator for Red Hat OpenShift on the hub).

Requires `repo.url` (set `GITOPS_APP_REPO_URL` when using `platform-setup/002-acm-openshift-gitops.sh`).

For a private Git repository, `002` can apply an Argo CD repository `Secret` (label `argocd.argoproj.io/secret-type=repository`) before this chart: set `GITOPS_APP_REPO_TOKEN` / `GITOPS_APP_REPO_TOKEN_FILE` / `GITOPS_APP_REPO_PASSWORD` with optional `GITOPS_APP_REPO_USERNAME` for HTTPS, or `GITOPS_APP_REPO_SSH_PRIVATE_KEY_FILE` with an SSH `GITOPS_APP_REPO_URL`. See `platform-setup/002-acm-openshift-gitops.sh --help`.

```bash
helm upgrade --install gitops-hub-app-of-apps ./charts/gitops-hub-app-of-apps \
  --kube-context "$HUB_CTX" \
  --namespace openshift-gitops \
  --set gitopsNamespace=openshift-gitops \
  --set repo.url="https://github.com/example-org/istio-scale-tests.git" \
  --set repo.revision=main
```

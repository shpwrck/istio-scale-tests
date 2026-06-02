# gitops-hub-apps

Hub-only Argo CD child `Application` manifests for the hub **app of apps** pattern.

The Argo CD Application `hub-gitops-root` (installed by `charts/gitops-hub-app-of-apps` via Terraform `helm_release.gitops_hub_app_of_apps`) uses a **directory** source pointing at `applications/` in this tree (`charts/gitops-hub-apps/applications` in the Git repo). Add or edit `*.yaml` files there; after commit and push, refresh/sync `hub-gitops-root` so Argo applies the child Applications.

The Helm chart metadata under this directory (`Chart.yaml`, `templates/_helpers.tpl`) remains for `helm lint` in CI/scripts; Argo does not Helm-install this chart for the app-of-apps flow.

See `applications/README.md` for conventions (including matching `spec.source.repoURL` to your fork).

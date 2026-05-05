# Hub GitOps child Applications

YAML in this directory is synced by the Argo CD Application **hub-gitops-root** (directory source, recursive). Each file should define one `Application` CR (typically `*.yaml`).

Adding a new app: commit a new `Application` manifest here with `metadata.namespace: openshift-gitops` (or your `GITOPS_NAMESPACE`), `spec.source.path` pointing at a chart or manifests in this repo, and **`spec.source.repoURL` matching** the Git URL used for `hub-gitops-root` (same as `GITOPS_APP_REPO_URL` when using `platform-setup/002`). Forks must replace the default `repoURL` in every file if it differs from upstream.

**`hub-acm-openshift-gitops-resources`** syncs `charts/acm-openshift-gitops-resources` when `GITOPS_ACM_RESOURCES_VIA_ARGO=1` (default in `platform-setup/002`); the script patches Helm parameters (`argoServer.cluster`, `gitopsNamespace`, etc.) after `hub-gitops-root` creates this Application.

**`hub-mesh-ca-intermediate-appset`** installs **`charts/gitops-hub-ocm-placement-appset`** with **`values-mesh-ca-intermediate.yaml`** (hub-only destination).

**`hub-external-secrets-operator-appset`** installs the same chart with **`values-external-secrets.yaml`** so External Secrets is deployed on **every cluster** in Placement plus **`in-cluster`** (`spec.destination.name` per Application).

Exclude patterns on the root Application omit `*.md` so this README is not applied as a manifest.

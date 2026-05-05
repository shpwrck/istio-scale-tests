# Hub GitOps child Applications

YAML in this directory is synced by the Argo CD Application **hub-gitops-root** (directory source, recursive). Each file should define one `Application` CR (typically `*.yaml`).

Adding a new app: commit a new `Application` manifest here with `metadata.namespace: openshift-gitops` (or your `GITOPS_NAMESPACE`), `spec.source.path` pointing at a chart or manifests in this repo, and **`spec.source.repoURL` matching** the Git URL used for `hub-gitops-root` (same as `GITOPS_APP_REPO_URL` when using `platform-setup/002`). Forks must replace the default `repoURL` in every file if it differs from upstream.

**`hub-mesh-ca-intermediate-appset`** installs the ApplicationSet in **`openshift-gitops`**: **`clusterDecisionResource`** uses the shared duck-type ConfigMap from **`charts/acm-openshift-gitops-resources`** and PlacementDecision `{placement.name}-decision-1`; a **`list`** generator adds a static **`in-cluster`** hub app. Override **`placement.name`** / **`inClusterGenerator`** via Helm parameters if needed.

**`hub-external-secrets-operator-appset`** installs the ApplicationSet `hub-external-secrets-operator` in **`openshift-gitops`** (same Placement wiring); each child Application targets that cluster via **`spec.destination.name`** (spokes + **`in-cluster`**).

Exclude patterns on the root Application omit `*.md` so this README is not applied as a manifest.

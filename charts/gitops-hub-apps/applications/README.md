# Hub GitOps child Applications

YAML in this directory is synced by the Argo CD Application **hub-gitops-root** (directory source, recursive). Each file should define one `Application` CR (typically `*.yaml`).

Adding a new app: commit a new `Application` manifest here with `metadata.namespace: openshift-gitops` (or your `GITOPS_NAMESPACE`), `spec.source.path` pointing at a chart or manifests in this repo, and **`spec.source.repoURL` matching** the Git URL used for `hub-gitops-root` (same as `GITOPS_APP_REPO_URL` when using `platform-setup/002`). Forks must replace the default `repoURL` in every file if it differs from upstream.

**`hub-mesh-ca-intermediate-appset`** installs the ApplicationSet in **`openshift-gitops`**: **`clusterDecisionResource`** uses **`acm-openshift-gitops-placement-decision-1`** (spokes); a **`list`** generator adds a static **`local-cluster`** hub app. Override **`placement.placementDecisionName`** / **`localClusterGenerator`** via Helm parameters if needed.

**`hub-external-secrets-operator-appset`** installs the ApplicationSet `hub-external-secrets-operator` in **`openshift-gitops`**, generating one **`charts/external-secrets-operator`** Application per cluster (same Placement + **`local-cluster`** pattern); each child Application targets that cluster via **`spec.destination.name`**.

Exclude patterns on the root Application omit `*.md` so this README is not applied as a manifest.

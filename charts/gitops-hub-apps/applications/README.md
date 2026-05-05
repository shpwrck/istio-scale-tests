# Hub GitOps child Applications

YAML in this directory is synced by the Argo CD Application **hub-gitops-root** (directory source, recursive). Each file should define one `Application` CR (typically `*.yaml`).

Adding a new app: commit a new `Application` manifest here with `metadata.namespace: openshift-gitops` (or your `GITOPS_NAMESPACE`), `spec.source.path` pointing at a chart or manifests in this repo, and **`spec.source.repoURL` matching** the Git URL used for `hub-gitops-root` (same as `GITOPS_APP_REPO_URL` when using `platform-setup/002`). Forks must replace the default `repoURL` in every file if it differs from upstream.

**`hub-mesh-ca-intermediate-appset`** installs the ApplicationSet that generates per-cluster **`hub-mesh-ca-intermediate`** Applications (after **`hub-mesh-ca`** sync wave). Helm destination namespace is **`openshift-gitops`** so **`clusterDecisionResource`** resolves **`PlacementDecision`** **`acm-openshift-gitops-placement-decision-1`** (same namespace as **`charts/acm-openshift-gitops-resources`** **Placement**). Override **`applicationSetNamespace`** / **`repo.url`** / **`placement.placementDecisionName`** if you renamed **Placement** or use a non-default **`decisionStrategy`**.

Exclude patterns on the root Application omit `*.md` so this README is not applied as a manifest.

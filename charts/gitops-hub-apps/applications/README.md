# Hub GitOps child Applications

YAML in this directory is synced by the Argo CD Application **hub-gitops-root** (directory source, recursive). Each file should define one `Application` CR (typically `*.yaml`).

Adding a new app: commit a new `Application` manifest here with `metadata.namespace: openshift-gitops` (or your `GITOPS_NAMESPACE`), `spec.source.path` pointing at a chart or manifests in this repo, and **`spec.source.repoURL` matching** the Git URL used for `hub-gitops-root` (same as `GITOPS_APP_REPO_URL` when using `platform-setup/002`). Forks must replace the default `repoURL` in every file if it differs from upstream.

**`hub-acm-openshift-gitops-resources`** syncs `charts/acm-openshift-gitops-resources` when `GITOPS_ACM_RESOURCES_VIA_ARGO=1` (default in `platform-setup/002`); the script patches Helm parameters (`argoServer.cluster`, `gitopsNamespace`, etc.) after `hub-gitops-root` creates this Application.

**`hub-mesh-ca-intermediate-appset`** installs **`charts/gitops-hub-ocm-placement-appset`** with **`values-mesh-ca-intermediate.yaml`** (hub-only destination).

`hub-external-secrets-operator-appset` installs `charts/gitops-hub-ocm-placement-appset` with `values-external-secrets.yaml` so External Secrets is deployed on each cluster in Placement (spokes) plus `in-cluster` for the hub; each generated Application sets `spec.destination.name` to that cluster. Do not use a separate hub-only Application targeting `charts/external-secrets-operator` if you rely on spokes.

`hub-kubeconfig-from-argosecret-appset` installs the same placement chart with `values-kubeconfig-from-argosecret.yaml` on the hub: generated Applications remain `destination.inClusterServer` with `destination.namespace: external-secrets-operator` so ESO reconciles the CRs; each child Helm value `clusterName` matches a `ManagedCluster` name so the chart can read that cluster’s `*-application-manager-cluster-secret` in `openshift-gitops` and emit a `kubeconfig` Secret. Set `inClusterGenerator.clusterName` in the value file to the hub’s `ManagedCluster` name (not `in-cluster`). Install after or with External Secrets on the hub (wave 18 after ESO appset wave 12).

Exclude patterns on the root Application omit `*.md` so this README is not applied as a manifest.

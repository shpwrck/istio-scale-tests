# gitops-hub-apps (Helm)

Hub-only resources reconciled by Argo CD `Application` `hub-gitops-root` (Helm source path `charts/gitops-hub-apps`).

Add optional `Application` or other manifests as YAML under `templates/`. Use `metadata.namespace` (typically `openshift-gitops`) or set `gitopsNamespace` in `values.yaml` for templates that reference it.

This chart intentionally ships without extra Kubernetes objects beyond Helm helpers so operators start from an empty sync.

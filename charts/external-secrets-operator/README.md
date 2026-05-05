# external-secrets-operator (Helm)

Installs External Secrets Operator for Red Hat OpenShift via OLM (Namespace, OperatorGroup all namespaces, Subscription).

Synced per cluster by `charts/gitops-hub-ocm-placement-appset` with `values-external-secrets.yaml` (child Applications under `hub-external-secrets-operator-appset`).

Procedure reference: [External Secrets Operator for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/security_and_compliance/external-secrets-operator-for-red-hat-openshift).

Red Hat documents installing cert-manager before External Secrets on a cluster; ensure cert-manager is available where you rely on that integration.

Override `values.yaml` keys (channel, catalog source) for disconnected mirrors or version pinning.

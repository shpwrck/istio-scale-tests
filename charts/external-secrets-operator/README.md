# external-secrets-operator (Helm)

Installs External Secrets Operator for Red Hat OpenShift via OLM (Namespace, OperatorGroup all namespaces, Subscription).

Do not sync this chart via a hub-only Application. Use `charts/gitops-hub-ocm-placement-appset` with `values-external-secrets.yaml`: the `hub-external-secrets-operator-appset` Application under `charts/gitops-hub-apps/applications` renders an ApplicationSet that targets every cluster in Placement (spokes via `PlacementDecision`) plus `in-cluster` for the ACM hub GitOps endpoint.

Optional `rbac` templates default on: namespaced `operators.coreos.com` rules bind `openshift-gitops-argocd-application-controller` so Argo can apply OLM resources in `namespace` (Namespace creation remains cluster-scope; clusters that deny it usually pre-create the operand namespace).

Procedure reference: [External Secrets Operator for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/security_and_compliance/external-secrets-operator-for-red-hat-openshift).

Red Hat documents installing cert-manager before External Secrets on a cluster; ensure cert-manager is available where you rely on that integration.

Override `values.yaml` keys (channel, catalog source) for disconnected mirrors or version pinning.

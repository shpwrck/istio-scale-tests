# cert-manager-operator (Helm)

Installs the **cert-manager Operator for Red Hat OpenShift** via OLM (Namespace, OperatorGroup AllNamespaces, Subscription).

Synced on the hub by the Argo CD `Application` `hub-cert-manager-operator` (declared in `charts/gitops-hub-apps/applications/cert-manager-operator.yaml`, applied when `hub-gitops-root` syncs).

Procedure reference: [Installing the cert-manager Operator for Red Hat OpenShift](https://docs.openshift.com/container-platform/latest/security/cert_manager_operator/index.html).

Override `values.yaml` keys (channel, catalog source) for disconnected mirrors or version pinning.

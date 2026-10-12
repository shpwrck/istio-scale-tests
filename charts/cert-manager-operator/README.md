# cert-manager-operator

Installs the cert-manager Operator for Red Hat OpenShift on the hub through OLM (Namespace,
OperatorGroup, Subscription). Synced by the Argo CD Application `hub-cert-manager-operator`
(`charts/gitops-hub-apps`).

If the hub already runs the cert-manager operator, disable this app
(`apps.hub-cert-manager-operator.enabled=false`); otherwise Argo adopts the existing
Subscription and adds a second OperatorGroup to its namespace.

Deleting the Application runs a PreDelete Job that deletes the Subscription and then the
operator CSV (`image.repository`/`image.tag`, match the tag to the cluster's OpenShift minor).

Reference: [cert-manager Operator for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/security_and_compliance/cert-manager-operator-for-red-hat-openshift).

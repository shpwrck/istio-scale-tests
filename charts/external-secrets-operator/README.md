# external-secrets-operator

Installs the External Secrets Operator for Red Hat OpenShift through OLM, plus the
`ExternalSecretsConfig` that makes the operator deploy ESO. Installed on the hub only
(`in-cluster`) by `values-external-secrets.yaml` in `charts/gitops-hub-ocm-placement-appset`;
the hub ESO pushes secrets to the spokes with PushSecrets.

`spokeEgress` adds a NetworkPolicy in the operand namespace (`external-secrets`) that lets
the ESO controller reach spoke API servers on ports 443 and 6443.

Deleting the Application runs a PreDelete Job that deletes the Subscription and then the
operator CSV (`image.repository`/`image.tag`, match the tag to the cluster's OpenShift minor).

Reference: [External Secrets Operator for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/security_and_compliance/external-secrets-operator-for-red-hat-openshift).

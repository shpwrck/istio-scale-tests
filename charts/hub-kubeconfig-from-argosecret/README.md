# hub-kubeconfig-from-argosecret

Hub-only Helm chart: one `ExternalSecret` plus `SecretStore` (Kubernetes provider) that reads the ACM/GitOps Argo cluster Secret `{clusterName}-application-manager-cluster-secret` in `openshift-gitops`, and writes a `Secret` (default `kubeconfig-{clusterName}`) with key `kubeconfig` containing a full kubectl kubeconfig (bearer token and server from the Argo `config` JSON; cluster, context, and user names from the Argo `name` field).

Designed for `charts/gitops-hub-ocm-placement-appset` with `values-kubeconfig-from-argosecret.yaml`: one generated Application per ManagedCluster in Placement (spokes) and one list element for the hub. Set `inClusterGenerator.clusterName` to the hub `ManagedCluster.metadata.name` (not the literal `in-cluster` Argo endpoint name) so the source Secret name matches RHACM (`{hub}-application-manager-cluster-secret`).

Prerequisites on the hub: External Secrets Operator (for example via `hub-external-secrets-operator-appset`), and the usual `*-application-manager-cluster-secret` objects created by the GitOps addon.

Template logic lives in `files/eso-kubeconfig.tpl` (External Secrets engine v2 / sprig); Helm does not interpret that file so ESO `{{ ... }}` expressions pass through unchanged.

`SecretStore` and `ExternalSecret` use `apiVersion: external-secrets.io/v1` for External Secrets Operator installs that expose the stable v1 API (for example Red Hat OpenShift).

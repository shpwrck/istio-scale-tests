# hub-kubeconfig-from-argosecret

Hub-only Helm chart: one `ExternalSecret` plus `SecretStore` (Kubernetes provider) that reads the ACM/GitOps Argo cluster Secret `{clusterName}-application-manager-cluster-secret` from `sourceSecretsNamespace` (default `openshift-gitops`), and writes a `Secret` (default `kubeconfig-{clusterName}`) with key `kubeconfig` containing a full kubectl kubeconfig.

CRs (`SecretStore`, `ExternalSecret`, store `ServiceAccount`, generated kubeconfig `Secret`) are installed into `namespace` (default `external-secrets-operator`) so the Red Hat External Secrets operand actually reconciles them. The operand subscribes with an OperatorGroup that scopes reconciliation to the operand namespace; `SecretStore` objects only in `openshift-gitops` are ignored. When `namespace` and `sourceSecretsNamespace` differ, the chart adds a `Role` + `RoleBinding` in `sourceSecretsNamespace` so the store `ServiceAccount` (living in `namespace`) can still `get` the Argo cluster Secrets.

Designed for `charts/gitops-hub-ocm-placement-appset` with `values-kubeconfig-from-argosecret.yaml`: child Applications use `destination.namespace: external-secrets-operator`. Set `inClusterGenerator.clusterName` to the hub `ManagedCluster.metadata.name` (not `in-cluster`) so the source Secret name matches RHACM.

Prerequisites on the hub: External Secrets Operator (for example via `hub-external-secrets-operator-appset`), and the usual `*-application-manager-cluster-secret` objects in `openshift-gitops`.

Template logic lives in `files/eso-kubeconfig.tpl` (External Secrets engine v2 / sprig); Helm does not interpret that file so ESO `{{ ... }}` expressions pass through unchanged.

`SecretStore` and `ExternalSecret` use `apiVersion: external-secrets.io/v1` for External Secrets Operator installs that expose the stable v1 API (for example Red Hat OpenShift).

The kubernetes provider `SecretStore` sets `spec.provider.kubernetes.server.caProvider` to the platform root CA from a ConfigMap in the same namespace as the `SecretStore` (`kube-root-ca.crt` / `ca.crt` by default). It sets `auth.serviceAccount.namespace` next to `name`. The store `ServiceAccount` receives RBAC to read secrets in `sourceSecretsNamespace`.

If `SecretStore` never reaches Ready: `kubectl describe secretstore -n external-secrets-operator`, confirm `kube-root-ca.crt` exists there, and ensure your Argo CD `AppProject` allows sync to both `external-secrets-operator` and `openshift-gitops` when those differ. You can set `namespace` and `sourceSecretsNamespace` to the same value (for example both `openshift-gitops`) only if your operand is configured to reconcile that namespace.

Disable the CA block with `kubernetesAPI.caFromConfigMap.enabled: false` when the apiserver chain is already trusted by the operator image.

# hub-kubeconfig-from-argosecret

Hub-only chart, one release per mesh member (`values-kubeconfig-from-argosecret.yaml` in
`charts/gitops-hub-ocm-placement-appset`). An ExternalSecret reads the Terraform-created
Argo CD cluster Secret `{clusterName}-{managedServiceAccountName}-cluster-secret` in
`argocd` (`openshift-gitops` on OpenShift) and writes `kubeconfig-{clusterName}` in `external-secrets-operator`
(keys `kubeconfig`, `bearer-token`, `ca.crt`, `client-cert`, `client-key`).

The Secret stays on the hub. `charts/hub-mesh-push-secrets` uses it to authenticate to the
spoke and to build the Istio remote secret.

Requires the hub External Secrets operator. If the SecretStore is not Ready, check
`kubectl describe secretstore -n external-secrets-operator` and that `kube-root-ca.crt` exists
there. Templates under `files/` are ESO templates; Helm passes them through unchanged.

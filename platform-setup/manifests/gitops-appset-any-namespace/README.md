# gitops-appset-any-namespace

RBAC and reference notes for RHACM [Enabling the ApplicationSet resource in any namespace](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/gitops/gitops-overview#enable-gitops-appset): `ClusterRole` / `ClusterRoleBinding` match `stolostron/multicloud-integrations` `deploy/appset-any-namespace`. The binding uses `envsubst` with `GITOPS_NAMESPACE` from `platform-setup/002-acm-openshift-gitops.sh`.

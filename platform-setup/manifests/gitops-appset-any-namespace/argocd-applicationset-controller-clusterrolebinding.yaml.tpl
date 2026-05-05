# Vendored from stolostron/multicloud-integrations deploy/appset-any-namespace (subject namespace templated).
# Requires env GITOPS_NAMESPACE (see platform-setup/002-acm-openshift-gitops.sh).
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    app.kubernetes.io/name: argocd-applicationset-controller
    app.kubernetes.io/part-of: argocd-applicationset
    app.kubernetes.io/component: controller
    cluster.open-cluster-management.io/backup: ""
  name: openshift-gitops-applicationset-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: openshift-gitops-applicationset-controller
subjects:
  - kind: ServiceAccount
    name: openshift-gitops-applicationset-controller
    namespace: ${GITOPS_NAMESPACE}

# Sample ApplicationSet for ACM + OpenShift GitOps (manual test only; not run by istio-setup scripts).
# Expects cluster Secrets in ${GITOPS_NAMESPACE} labeled argocd.argoproj.io/secret-type=cluster
# (created after GitOpsCluster reconciles for Placement-selected clusters).
#
# Apply (repo root, hub kube context):
#   source config/versions.env
#   envsubst < samples/acm-gitops/applicationset-guestbook.yaml.tpl | oc --context "$CTX" apply -f -
#
# Remove:
#   oc --context "$CTX" delete applicationset acm-test-guestbook -n "${GITOPS_NAMESPACE:-openshift-gitops}"
#
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: acm-test-guestbook
  namespace: ${GITOPS_NAMESPACE}
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            argocd.argoproj.io/secret-type: cluster
  template:
    metadata:
      name: '{{name}}-guestbook'
      labels:
        sample.acm-gitops/scope: guestbook-test
    spec:
      project: default
      source:
        repoURL: https://github.com/argoproj/argocd-example-apps.git
        targetRevision: HEAD
        path: guestbook
      destination:
        server: '{{server}}'
        namespace: acm-gitops-test-guestbook
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true

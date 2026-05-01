# Sample ApplicationSet for ACM + OpenShift GitOps (manual apply; not run by istio-setup scripts).
# Expects Argo cluster Secrets in ${GITOPS_NAMESPACE} (GitOpsCluster / ACM gitops-addon).
#
# Uses this repo's OpenShift-safe manifests (port 8080) — not argoproj/guestbook (binds :80, fails SCC on ROSA).
#
# Apply (repo root, hub context):
#   source config/versions.env
#   envsubst < samples/acm-gitops/applicationset-guestbook.yaml.tpl | oc --context "$CTX" apply -f -
#
# Requires: hub can clone GITOPS_SAMPLE_REPO_URL at GITOPS_SAMPLE_REPO_REVISION (push commits before sync).
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
        repoURL: ${GITOPS_SAMPLE_REPO_URL}
        targetRevision: ${GITOPS_SAMPLE_REPO_REVISION}
        path: samples/acm-gitops/hello-openshift
      destination:
        server: '{{server}}'
        namespace: acm-gitops-test-guestbook
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true

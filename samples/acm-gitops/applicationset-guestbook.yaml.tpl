# Sample ApplicationSet for ACM + OpenShift GitOps (manual apply; not part of the app-of-apps).
# Expects Argo cluster Secrets in ${GITOPS_NAMESPACE} (GitOpsCluster / ACM gitops-addon).
#
# Uses the small public Argo **helm-guestbook** chart with **hello-openshift** (8080) so workloads stay
# Healthy on ROSA restricted SCC without cloning huge repos or rendering heavy third-party charts (repo-server
# OOM has been seen at default limits when rendering Bitnami nginx).
#
# Apply:
#   source config/versions.env
#   envsubst < samples/acm-gitops/applicationset-guestbook.yaml.tpl | oc --context "$CTX" apply -f -
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
        path: helm-guestbook
        helm:
          values: |
            image:
              repository: quay.io/openshift/origin-hello-openshift
              tag: latest
            containerPort: 8080
            service:
              port: 8080
      destination:
        server: '{{server}}'
        namespace: acm-gitops-test-guestbook
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true

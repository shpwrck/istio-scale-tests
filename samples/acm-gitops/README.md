# ACM GitOps samples (manual)

Use after **platform-setup/002** succeeds.

## ApplicationSet (`applicationset-guestbook.yaml.tpl`)

Targets every Argo **cluster** secret in `${GITOPS_NAMESPACE}`.

**Default manifest** syncs the small public [Argo `helm-guestbook`](https://github.com/argoproj/argocd-example-apps/tree/master/helm-guestbook) chart with **`quay.io/openshift/origin-hello-openshift`** on **8080** (ROSA-friendly). No GitHub credential is required on the hub.

If **repo-server** restarts with **OOMKilled** while syncing heavier Helm sources, raise limits on the hub instance, for example:

```bash
oc patch argocd openshift-gitops -n openshift-gitops --type merge -p '{"spec":{"repo":{"resources":{"limits":{"memory":"2Gi"},"requests":{"memory":"512Mi"}}}}}'
```

```bash
source config/versions.env
export CTX=<hub-kube-context>
envsubst < samples/acm-gitops/applicationset-guestbook.yaml.tpl | oc --context "$CTX" apply -f -
```

### In-repo `hello-openshift/` (optional)

`hello-openshift/` is an OpenShift **hello** Deployment (**8080**). To use it, edit the ApplicationSet `source` to point at a **public** Git URL (or create an Argo CD **Repository** secret on the hub for a private repo). Cloning `Repository not found` usually means the repo is **private** without credentials.

### Spokes unreachable from Argo (`*.control-plane`, ComparisonError)

Patch ACM cluster secrets (**public API URL** + **kubeconfig JSON** token from your workstation):

```bash
./platform-setup/002-acm-openshift-gitops.sh --patch-argoc-cluster-secrets-only --context "$CTX"
```

Then optionally restart: `oc delete pod -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-application-controller`.

### Checks

```bash
oc --context "$CTX" get applicationset,applications.argoproj.io -n "${GITOPS_NAMESPACE}"
oc --context <spoke> get pods -n acm-gitops-test-guestbook
```

Cleanup:

```bash
oc --context "$CTX" delete applicationset acm-test-guestbook -n "${GITOPS_NAMESPACE}"
```

Spokes need **`cluster.open-cluster-management.io/clusterset=istio-scale-tests`** (**platform-setup/001** / **`ACM_CLUSTER_SET`**).

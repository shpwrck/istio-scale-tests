# ACM GitOps samples (manual)

These manifests are **not** applied by `istio-setup/011-acm-openshift-gitops.sh`. Use them after **011** succeeds.

## Guestbook ApplicationSet (`applicationset-guestbook.yaml.tpl`)

Syncs **`samples/acm-gitops/hello-openshift/`** from **`GITOPS_SAMPLE_REPO_URL`** (default `https://github.com/shpwrck/istio-scale-tests.git`) at **`GITOPS_SAMPLE_REPO_REVISION`** (`main`) to every Argo **cluster** secret in `${GITOPS_NAMESPACE}`.  
Uses **`quay.io/openshift/origin-hello-openshift`** on **port 8080** so ROSA restricted SCC is satisfied (upstream argoproj `guestbook` binds **:80** and fails).

**Push commits to `GITOPS_SAMPLE_REPO_URL` before** applying the ApplicationSet, or sync will fail.

```bash
source config/versions.env
export CTX=<hub-kube-context>
envsubst < samples/acm-gitops/applicationset-guestbook.yaml.tpl | oc --context "$CTX" apply -f -
```

### Argo cannot reach spokes (`*.control-plane`, ComparisonError, unknown)

ACM secrets often set **`server`** to an **internal** API hostname that does not resolve from hub pods. Patch **`server`** to **`ManagedCluster.spec.managedClusterClientConfigs[0].url`** and add **`config`** (bearer token from your kubeconfig):

```bash
./istio-setup/012-acm-argoc-managed-cluster-secrets.sh --hub-context "$CTX"
```

Then restart tends to clear: `oc delete pod -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-application-controller`.

Check:

```bash
oc --context "$CTX" get applicationset,applications.argoproj.io -n "${GITOPS_NAMESPACE}"
```

On a spoke:

```bash
oc --context <spoke-context> get pods -n acm-gitops-test-guestbook
```

Cleanup:

```bash
oc --context "$CTX" delete applicationset acm-test-guestbook -n "${GITOPS_NAMESPACE}"
```

Spokes must carry **`cluster.open-cluster-management.io/clusterset=istio-scale-tests`** (see **001** / **`ACM_CLUSTER_SET`**).

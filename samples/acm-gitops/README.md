# ACM GitOps samples (manual)

These manifests are **not** applied by `istio-setup/011-acm-openshift-gitops.sh`. Use them to validate OpenShift GitOps + ACM **GitOpsCluster** after **011** succeeds.

## Guestbook ApplicationSet

Deploys the upstream [Argo CD guestbook example](https://github.com/argoproj/argocd-example-apps/tree/master/guestbook) to **every** cluster represented by an Argo CD cluster `Secret` in `${GITOPS_NAMESPACE}` (typically `openshift-gitops`), matching the label `argocd.argoproj.io/secret-type=cluster`.

Prerequisites: **001** + **011** with ACM GitOps resources applied; **GitOpsCluster** healthy; spoke clusters in your **Placement**.

```bash
source config/versions.env
export CTX=<hub-kube-context>
envsubst < samples/acm-gitops/applicationset-guestbook.yaml.tpl | oc --context "$CTX" apply -f -
```

Check:

```bash
oc --context "$CTX" get applicationset,applications -n "${GITOPS_NAMESPACE}"
```

On a spoke:

```bash
oc --context <spoke-context> get pods -n acm-gitops-test-guestbook
```

Cleanup:

```bash
oc --context "$CTX" delete applicationset acm-test-guestbook -n "${GITOPS_NAMESPACE}"
```

If **no** Applications appear, confirm cluster secrets exist (`oc get secrets -n "${GITOPS_NAMESPACE}" -l argocd.argoproj.io/secret-type=cluster`) and that your **Placement** includes the spokes.

Spokes must match **ManagedClusterSet** **`istio-scale-tests`** (default **`ACM_CLUSTER_SET`**): each **ManagedCluster** needs `cluster.open-cluster-management.io/clusterset=<set>`. **001** sets this via `clustersetName` / `ACM_CLUSTER_SET`. Existing clusters: `oc label managedcluster NAME cluster.open-cluster-management.io/clusterset=istio-scale-tests --overwrite`, then re-run **011** (or `helm upgrade` **`acm-openshift-gitops-resources`**) and wait for GitOpsCluster to reconcile.

# acm-openshift-gitops-resources

Installed by Terraform only (`helm_release.acm_gitops_resources`). Renders, in `gitopsNamespace`:

- ManagedClusterSet `clusterSet` (skip with `managedClusterSet.create=false`)
- ManagedClusterSetBinding to that set
- Placement `placement.name`: clusters in the set, minus the ACM hub (`local-cluster` label),
  and only those labeled `istio-mesh-member=true`

Every ApplicationSet in `charts/gitops-hub-ocm-placement-appset` reads this Placement through
the `acm-gitops-placement-generator` ConfigMap, which Terraform creates after the Argo CD
cluster Secrets exist.

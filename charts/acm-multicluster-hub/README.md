# acm-multicluster-hub

One MultiClusterHub CR. Installed by Terraform (`helm_release.acm_multicluster_hub`) after the
ACM operator CSV is ready. `multiclusterHub.spec` is passed through verbatim; Terraform sets
`multiclusterHub.spec.localClusterName` (RHACM limit: 34 characters).

`keepOnUninstall: true` adds `helm.sh/resource-policy: keep`, so `helm uninstall` leaves the CR in
place. Terraform sets it when `acm_install_operator = false` (an adopted hub).

Do not disable the MCE `server-foundation` component; it runs the managed-cluster import
controller.

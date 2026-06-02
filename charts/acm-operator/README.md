# acm-operator

OperatorGroup + Subscription for the advanced-cluster-management package from OperatorHub. Applied first; wait for the ACM ClusterServiceVersion Succeeded before installing `charts/acm-multicluster-hub`.

Configured by Terraform (`terraform/platform/platform_acm.tf`, via `var.acm_channel` / `var.acm_namespace`).

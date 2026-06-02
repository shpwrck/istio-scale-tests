# acm-multicluster-hub

Single MultiClusterHub custom resource. Install after the ACM operator CSV has installed the MultiClusterHub CRD. `spec.localClusterName` is set by Terraform (`terraform/platform/platform_acm.tf`, `helm_release.acm_multicluster_hub`, from `acm_local_cluster_name`), RHACM max 34 characters.

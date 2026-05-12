output "acm_hub_cluster_key" {
  description = "Terraform cluster key used as the ACM hub."
  value       = local.first_cluster_key
}

output "acm_spoke_cluster_keys" {
  description = "Terraform cluster keys registered as ACM spoke ManagedClusters."
  value       = keys(local.spoke_cluster_keys)
}

output "acm_cluster_set" {
  description = "ManagedClusterSet name applied to spoke ManagedClusters."
  value       = var.acm_cluster_set
}

output "acm_local_cluster_name" {
  description = "MultiClusterHub spec.localClusterName / GitOpsCluster argoServer.cluster."
  value       = local.acm_local_cluster_name
}

output "gitops_namespace" {
  description = "Namespace for Argo CD and ACM GitOps CRs."
  value       = var.gitops_namespace
}

output "mesh_member_spoke_keys" {
  description = "Spoke cluster keys labeled as Istio mesh members."
  value       = local.mesh_member_spoke_keys
}

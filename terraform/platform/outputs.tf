output "platform" {
  description = "kubernetes (upstream Argo CD and operator charts) or openshift (OpenShift GitOps, ACM, OLM)."
  value       = local.platform
}

output "hub_cluster_key" {
  description = "Terraform cluster key of the hub (Argo CD; the ACM hub on openshift)."
  value       = local.first_cluster_key
}

output "spoke_cluster_keys" {
  description = "Terraform cluster keys registered with Argo CD as spokes (ACM ManagedClusters on openshift)."
  value       = keys(local.spoke_cluster_keys)
}

output "acm_cluster_set" {
  description = "platform openshift: ManagedClusterSet name applied to spoke ManagedClusters (null on kubernetes)."
  value       = local.is_openshift ? var.acm_cluster_set : null
}

output "acm_local_cluster_name" {
  description = "platform openshift: MultiClusterHub spec.localClusterName (null on kubernetes)."
  value       = local.is_openshift ? local.acm_local_cluster_name : null
}

output "gitops_namespace" {
  description = "Argo CD namespace (on openshift also the ACM Placement and ManagedClusterSetBinding)."
  value       = local.gitops_namespace
}

output "mesh_member_spoke_keys" {
  description = "Spoke cluster keys labeled as Istio mesh members."
  value       = local.mesh_member_spoke_keys
}

output "cluster_ids" {
  description = "Map of Terraform cluster key → RHCS cluster ID."
  value       = { for k, m in module.rosa_hcp : k => m.cluster_id }
}

output "cluster_api_urls" {
  description = "Map of Terraform cluster key → Kubernetes API URL."
  value       = { for k, m in module.rosa_hcp : k => m.cluster_api_url }
}

output "cluster_console_urls" {
  description = "Map of Terraform cluster key → OpenShift console URL."
  value       = { for k, m in module.rosa_hcp : k => m.cluster_console_url }
}

output "vpc_ids" {
  description = "Map of Terraform cluster key → AWS VPC ID."
  value       = { for k, m in module.vpc : k => m.vpc_id }
}

output "oidc_config_ids" {
  description = "Per-cluster OIDC config IDs (each module instance uses create_oidc = true)."
  value       = { for k, m in module.rosa_hcp : k => m.oidc_config_id }
}

output "oidc_endpoint_urls" {
  description = "Per-cluster OIDC issuer URLs used for operator trust policies."
  value       = { for k, m in module.rosa_hcp : k => m.oidc_endpoint_url }
}

output "cluster_admin_usernames" {
  description = "Present when create_cluster_admin_user is true for that cluster."
  value       = { for k, m in module.rosa_hcp : k => m.cluster_admin_username }
}

output "cluster_admin_passwords" {
  description = "Sensitive — only set when create_cluster_admin_user is true."
  sensitive   = true
  value       = { for k, m in module.rosa_hcp : k => m.cluster_admin_password }
}

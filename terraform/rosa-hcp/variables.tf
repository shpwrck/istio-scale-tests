variable "aws_region" {
  type        = string
  description = "AWS region where ROSA HCP clusters and VPCs are created."
}

variable "rhcs_token" {
  type        = string
  description = "Red Hat OpenShift Cluster Manager API token (offline token). Prefer environment variable RHCS_TOKEN; use TF_VAR_rhcs_token if setting via env for Terraform."
  sensitive   = true
  default     = null
}

variable "openshift_version" {
  type        = string
  description = "OpenShift version for new clusters (example: 4.18.38). Align with config/versions.env when using this repo's mesh scripts."
}

variable "clusters" {
  type = map(object({
    cluster_name              = string
    vpc_cidr                  = string
    availability_zones_count  = optional(number, 3)
    replicas                  = optional(number)
    create_cluster_admin_user = optional(bool, false)
    tags                      = optional(map(string), {})
  }))
  description = <<-EOT
    One entry per ROSA HCP cluster. Each cluster gets:
    - Its own AWS VPC via terraform-redhat/rosa-hcp/rhcs//modules/vpc (unique vpc_cidr required to avoid overlap).
    - Its own STS stack: create_account_roles / create_oidc / create_operator_roles per module instance = distinct IAM/OIDC per cluster.

    Map keys are stable labels (e.g. rosa-001) used in Terraform addresses and outputs.
  EOT

  validation {
    condition     = length(var.clusters) >= 1
    error_message = "Define at least one cluster in var.clusters."
  }
}

variable "default_tags" {
  type        = map(string)
  description = "Tags merged into each VPC module and passed to the ROSA HCP module (cluster AWS resources)."
  default     = {}
}

variable "ec2_metadata_http_tokens" {
  type        = string
  description = "IMDS settings for worker nodes (optional/required)."
  default     = "required"
}

variable "wait_for_create_complete" {
  type        = bool
  description = "Wait for cluster creation (upstream module waiter)."
  default     = true
}

variable "wait_for_std_compute_nodes_complete" {
  type        = bool
  description = "Wait for initial machine pool (upstream module waiter)."
  default     = true
}

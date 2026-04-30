variable "aws_region" {
  type        = string
  description = "AWS region where every cluster VPC and ROSA HCP worker footprint is created."
}

variable "rhcs_token" {
  type        = string
  sensitive   = true
  default     = null
  description = "Red Hat OpenShift API token. Leave null and export RHCS_TOKEN in the shell instead."
}

variable "openshift_version" {
  type        = string
  description = "OpenShift version for all clusters (e.g. 4.18.38). Align with config/versions.env when using this repo's mesh scripts."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.openshift_version))
    error_message = "openshift_version must look like major.minor.patch (e.g. 4.18.38)."
  }
}

variable "common_tags" {
  type        = map(string)
  default     = {}
  description = "Tags merged into each cluster's AWS-tagged resources (plus any per-cluster tags)."
}

variable "manage_service_quotas" {
  type        = bool
  default     = true
  description = "When true, apply aws_servicequotas_service_quota so AWS applied limits are at least usage plus this stack (see service_quotas.tf). Set false if your org blocks Service Quotas changes."
}

variable "service_quota_buffer" {
  type        = number
  default     = 2
  description = "Headroom added to computed minimum quota targets."

  validation {
    condition     = var.service_quota_buffer >= 0
    error_message = "service_quota_buffer must be >= 0."
  }
}

variable "service_quota_iam_roles_per_new_cluster" {
  type        = number
  default     = 55
  description = "Estimated IAM roles created per new ROSA HCP cluster (account + operator + OIDC), used only for Roles-per-account quota math."
}

variable "clusters" {
  type = map(object({
    cluster_name             = string
    vpc_cidr                 = string
    replicas                 = optional(number)
    compute_machine_type     = optional(string)
    ec2_metadata_http_tokens = optional(string, "required")
    tags                     = optional(map(string), {})
  }))
  description = <<-EOT
    One independent ROSA HCP cluster per map entry: dedicated VPC, subnets, OIDC config, and
    account/operator IAM roles (no shared STS or networking between entries). Use non-overlapping
    vpc_cidr values. Map keys are labels only (for outputs/state); cluster_name is the OCM cluster name.
    Each cluster is fixed to a single availability zone (first AZ in the region returned by AWS for the VPC submodule).
    Cluster-admin is always created with a single Terraform-generated password shared across all clusters
    (see output cluster_admin_login).
  EOT

  validation {
    condition     = length(var.clusters) > 0
    error_message = "Define at least one cluster in var.clusters."
  }
}

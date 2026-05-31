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
  description = "OpenShift version for all clusters (e.g. 4.21.11). Align with config/versions.env when using this repo's mesh scripts."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.openshift_version))
    error_message = "openshift_version must look like major.minor.patch (e.g. 4.21.11)."
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

variable "default_compute_machine_type" {
  type        = string
  default     = "m5.xlarge"
  description = "Instance type for the default worker pool when cluster_defaults.compute_machine_type is null (rhcs_hcp_machine_pool.aws_node_pool.instance_type is required)."
}

variable "cluster_count" {
  type        = number
  description = "How many independent ROSA HCP clusters to create (each: dedicated VPC, subnets, OIDC, account/operator IAM roles)."
  validation {
    condition     = var.cluster_count >= 1
    error_message = "cluster_count must be >= 1."
  }
}

variable "cluster_index_start" {
  type        = number
  default     = 1
  description = "First number substituted into cluster_name_format (e.g. 1 with \"cluster-%03d\" → cluster-001 for the first cluster)."
}

variable "vpc_cidr_index_start" {
  type        = number
  default     = 0
  description = "Added to each cluster index (0 .. cluster_count-1) before formatting vpc_cidr_format (defaults: \"10.%d.0.0/16\" → 10.0.0.0/16, 10.1.0.0/16, …)."
}

variable "cluster_name_format" {
  type        = string
  default     = "cluster-%03d"
  description = "format() pattern for Terraform map keys, OCM cluster_name, and kubectl/oc context names (one integer: idx + cluster_index_start; must yield unique keys)."
}

variable "vpc_cidr_format" {
  type        = string
  default     = "10.%d.0.0/16"
  description = "VPC CIDR per cluster; format() with one integer: idx + vpc_cidr_index_start. Use non-overlapping ranges (e.g. increment second octet)."
}

variable "vpc_peering_enabled" {
  type        = bool
  default     = true
  description = "Create VPC peering connections (full mesh) between every cluster pair so cross-cluster traffic (API, east-west gateway, istiod) can flow without traversing the public internet."
}

variable "cluster_defaults" {
  type = object({
    replicas                 = optional(number)
    compute_machine_type     = optional(string)
    ec2_metadata_http_tokens = optional(string)
    tags                     = optional(map(string))
    worker_autoscale_min     = optional(number)
    worker_autoscale_max     = optional(number)
  })
  default     = {}
  description = "Shared settings for every generated cluster (optional fields fall back to ROSA/upstream defaults where noted in README)."

  validation {
    condition = (
      coalesce(var.cluster_defaults.worker_autoscale_min, 2) >= 2 &&
      coalesce(var.cluster_defaults.worker_autoscale_min, 2) <= coalesce(var.cluster_defaults.worker_autoscale_max, 10)
    )
    error_message = "cluster_defaults.worker_autoscale_min must be >= 2 and <= worker_autoscale_max."
  }
}

variable "cluster_overrides" {
  type = map(object({
    replicas                 = optional(number)
    compute_machine_type     = optional(string)
    ec2_metadata_http_tokens = optional(string)
    tags                     = optional(map(string))
    worker_autoscale_min     = optional(number)
    worker_autoscale_max     = optional(number)
  }))
  default     = {}
  description = "Per-cluster overrides keyed by cluster name (e.g. cluster-001). Fields merge over cluster_defaults."
}

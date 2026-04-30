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

variable "kubeconfig_output_path" {
  type        = string
  nullable    = true
  default     = null
  description = "Destination file for the merged kubeconfig (cluster-admin + generated password). Default: rosa-generated.kubeconfig next to this stack. Treat as secret; path is gitignored when using the default name pattern."
}

variable "kubeconfig_skip_tls_verify" {
  type        = bool
  default     = false
  description = "When true, kubeconfig sets insecure-skip-tls-verify (no CA fetch). Use if tls_certificate against the API fails during apply."
}

variable "default_compute_machine_type" {
  type        = string
  default     = "m5.xlarge"
  description = "Instance type for the default worker pool when a cluster entry omits compute_machine_type (rhcs_hcp_machine_pool.aws_node_pool.instance_type is required)."
}

variable "clusters" {
  type = map(object({
    cluster_name             = string
    vpc_cidr                 = string
    replicas                 = optional(number)
    compute_machine_type     = optional(string)
    ec2_metadata_http_tokens = optional(string, "required")
    tags                     = optional(map(string), {})
    worker_autoscale_min     = optional(number, 2)
    worker_autoscale_max     = optional(number, 10)
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

  validation {
    condition = alltrue([
      for _, c in var.clusters :
      c.worker_autoscale_min >= 2 && c.worker_autoscale_min <= c.worker_autoscale_max
    ])
    error_message = "Each cluster needs worker_autoscale_min >= 2 (single-zone ROSA minimum) and worker_autoscale_min <= worker_autoscale_max."
  }
}

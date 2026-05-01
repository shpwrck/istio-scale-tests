# First regional AZ (single-AZ clusters). Passed explicitly so VPC subnet/NAT/EIP counts are known at plan
# time (the upstream VPC module otherwise reads AZs internally, which breaks when module depends_on quotas).
locals {
  clusters = {
    for idx in range(var.cluster_count) :
    format(var.cluster_name_format, idx + var.cluster_index_start) => {
      cluster_name             = format(var.cluster_name_format, idx + var.cluster_index_start)
      vpc_cidr                 = format(var.vpc_cidr_format, idx + var.vpc_cidr_index_start)
      replicas                 = try(var.cluster_defaults.replicas, null)
      compute_machine_type     = try(var.cluster_defaults.compute_machine_type, null)
      ec2_metadata_http_tokens = coalesce(try(var.cluster_defaults.ec2_metadata_http_tokens, null), "required")
      tags                     = coalesce(try(var.cluster_defaults.tags, null), {})
      worker_autoscale_min     = coalesce(try(var.cluster_defaults.worker_autoscale_min, null), 2)
      worker_autoscale_max     = coalesce(try(var.cluster_defaults.worker_autoscale_max, null), 10)
    }
  }

  # Terraform sorts map keys lexicographically — same order as cluster_keys output.
  sorted_cluster_keys = sort(keys(local.clusters))
  first_cluster_key   = local.sorted_cluster_keys[0]
}

data "aws_availability_zones" "cluster" {
  state = "available"
}

# Pin: keep this version identical on both module blocks (Terraform allows only a literal here).
module "vpc" {
  source  = "terraform-redhat/rosa-hcp/rhcs//modules/vpc"
  version = "1.7.3"

  for_each = local.clusters

  name_prefix        = each.value.cluster_name
  vpc_cidr           = each.value.vpc_cidr
  availability_zones = slice(data.aws_availability_zones.cluster.names, 0, 1)
  tags               = merge(var.common_tags, each.value.tags)
}

module "rosa_hcp" {
  source  = "terraform-redhat/rosa-hcp/rhcs"
  version = "1.7.3"

  for_each = local.clusters

  cluster_name      = each.value.cluster_name
  openshift_version = var.openshift_version
  machine_cidr      = module.vpc[each.key].cidr_block
  aws_subnet_ids = concat(
    module.vpc[each.key].public_subnets,
    module.vpc[each.key].private_subnets,
  )
  aws_availability_zones = module.vpc[each.key].availability_zones
  # ROSA HCP single-zone minimum is 2 worker nodes (upstream module / installer expectation).
  replicas = coalesce(each.value.replicas, 2)

  # Pool-level min/max is managed by rhcs_hcp_machine_pool.default_workers in worker_pool.tf.
  # Do not enable rhcs_hcp_cluster_autoscaler via this module here: the provider often returns
  # a different ResourceLimits shape from Update vs Get, causing inconsistent apply/refresh.
  compute_machine_type     = each.value.compute_machine_type
  create_admin_user        = true
  ec2_metadata_http_tokens = each.value.ec2_metadata_http_tokens
  tags                     = merge(var.common_tags, each.value.tags)

  admin_credentials_password = random_password.cluster_admin.result

  # STS: isolated per cluster (separate account roles, OIDC, operator roles).
  create_account_roles  = true
  account_role_prefix   = "${each.value.cluster_name}-account"
  create_oidc           = true
  create_operator_roles = true
  operator_role_prefix  = "${each.value.cluster_name}-operator"
}

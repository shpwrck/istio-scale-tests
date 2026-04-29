# Multi-cluster ROSA **Hosted Control Plane (HCP)** only.
# Consumes the upstream Red Hat module (not classic ROSA):
# https://github.com/terraform-redhat/terraform-rhcs-rosa-hcp
#
# Registry: terraform-redhat/rosa-hcp/rhcs
# Terraform requires a literal module version string (cannot use variables). Bump both
# blocks together when upgrading: https://github.com/terraform-redhat/terraform-rhcs-rosa-hcp/releases

module "vpc" {
  source   = "terraform-redhat/rosa-hcp/rhcs//modules/vpc"
  version  = "1.7.3"
  for_each = var.clusters

  name_prefix              = each.value.cluster_name
  vpc_cidr                 = each.value.vpc_cidr
  availability_zones_count = each.value.availability_zones_count
  tags                     = merge(var.default_tags, try(each.value.tags, {}))
}

module "rosa_hcp" {
  source   = "terraform-redhat/rosa-hcp/rhcs"
  version  = "1.7.3"
  for_each = var.clusters

  cluster_name      = each.value.cluster_name
  openshift_version = var.openshift_version

  machine_cidr = module.vpc[each.key].cidr_block
  aws_subnet_ids = concat(
    module.vpc[each.key].public_subnets,
    module.vpc[each.key].private_subnets,
  )
  aws_availability_zones = module.vpc[each.key].availability_zones

  replicas = coalesce(
    each.value.replicas,
    length(module.vpc[each.key].availability_zones),
  )

  ec2_metadata_http_tokens = var.ec2_metadata_http_tokens

  # Each cluster instance creates its own STS resources — distinct account roles,
  # OIDC configuration/provider, and operator roles (no sharing across clusters).
  create_account_roles  = true
  account_role_prefix   = "${each.value.cluster_name}-account"
  create_oidc           = true
  create_operator_roles = true
  operator_role_prefix  = "${each.value.cluster_name}-operator"

  create_admin_user = each.value.create_cluster_admin_user

  wait_for_create_complete            = var.wait_for_create_complete
  wait_for_std_compute_nodes_complete = var.wait_for_std_compute_nodes_complete

  tags = merge(var.default_tags, try(each.value.tags, {}))
}

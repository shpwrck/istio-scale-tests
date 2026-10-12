# Regional limits for ROSA HCP + terraform-redhat/rosa-hcp/rhcs VPC (one VPC per cluster, 1 AZ → 1 NAT + 1 EIP each).
# Resource: https://registry.terraform.io/providers/hashicorp/aws/6.43.0/docs/resources/aws_servicequotas_service_quota
#
# Quota targets are pure functions of cluster_count so they stay stable
# across re-applies (no data-source counting that would double-count
# resources this stack already created).

locals {
  num_clusters = var.cluster_count

  # Applied limits (0 when quota management is off, so the API is never called).
  current_vpc_max        = var.manage_service_quotas ? data.aws_servicequotas_service_quota.vpc_max[0].value : 0
  current_igw_max        = var.manage_service_quotas ? data.aws_servicequotas_service_quota.igw_max[0].value : 0
  current_eip_max        = var.manage_service_quotas ? data.aws_servicequotas_service_quota.eip_max[0].value : 0
  current_nat_per_az_max = var.manage_service_quotas ? data.aws_servicequotas_service_quota.nat_per_az_max[0].value : 0
  current_gw_ep_max      = var.manage_service_quotas ? data.aws_servicequotas_service_quota.gw_ep_max[0].value : 0
  current_iam_roles_max  = var.manage_service_quotas ? data.aws_servicequotas_service_quota.iam_roles_max[0].value : 0

  vpc_quota_target       = local.num_clusters + var.service_quota_buffer
  igw_quota_target       = local.vpc_quota_target
  eip_quota_target       = local.num_clusters + var.service_quota_buffer
  nat_quota_target       = local.num_clusters + var.service_quota_buffer
  gw_ep_quota_target     = local.num_clusters + var.service_quota_buffer
  iam_roles_quota_target = (local.num_clusters * var.service_quota_iam_roles_per_new_cluster) + var.service_quota_buffer

  # Never request a quota below what AWS already reports as applied.
  vpc_quota_candidate         = max(local.current_vpc_max, local.vpc_quota_target)
  igw_quota_candidate         = max(local.current_igw_max, local.igw_quota_target)
  eip_quota_candidate         = max(local.current_eip_max, local.eip_quota_target)
  nat_per_az_quota_candidate  = max(local.current_nat_per_az_max, local.nat_quota_target)
  gw_endpoint_quota_candidate = max(local.current_gw_ep_max, local.gw_ep_quota_target)
  iam_roles_quota_candidate   = max(local.current_iam_roles_max, local.iam_roles_quota_target)
}

data "aws_servicequotas_service_quota" "vpc_max" {
  count        = var.manage_service_quotas ? 1 : 0
  service_code = "vpc"
  quota_code   = "L-F678F1CE"
}

data "aws_servicequotas_service_quota" "igw_max" {
  count        = var.manage_service_quotas ? 1 : 0
  service_code = "vpc"
  quota_code   = "L-A4707A72"
}

data "aws_servicequotas_service_quota" "eip_max" {
  count        = var.manage_service_quotas ? 1 : 0
  service_code = "ec2"
  quota_code   = "L-0263D0A3"
}

data "aws_servicequotas_service_quota" "nat_per_az_max" {
  count        = var.manage_service_quotas ? 1 : 0
  service_code = "vpc"
  quota_code   = "L-FE5A380F"
}

data "aws_servicequotas_service_quota" "gw_ep_max" {
  count        = var.manage_service_quotas ? 1 : 0
  service_code = "vpc"
  quota_code   = "L-1B52E74A"
}

data "aws_servicequotas_service_quota" "iam_roles_max" {
  count        = var.manage_service_quotas ? 1 : 0
  provider     = aws.quota_iam
  service_code = "iam"
  quota_code   = "L-FE177D64"
}

resource "aws_servicequotas_service_quota" "vpc" {
  count        = var.manage_service_quotas && local.vpc_quota_candidate > local.current_vpc_max ? 1 : 0
  service_code = "vpc"
  quota_code   = "L-F678F1CE"
  value        = local.vpc_quota_candidate
}

resource "aws_servicequotas_service_quota" "internet_gateway" {
  count        = var.manage_service_quotas && local.igw_quota_candidate > local.current_igw_max ? 1 : 0
  service_code = "vpc"
  quota_code   = "L-A4707A72"
  value        = local.igw_quota_candidate
}

resource "aws_servicequotas_service_quota" "eip" {
  count        = var.manage_service_quotas && local.eip_quota_candidate > local.current_eip_max ? 1 : 0
  service_code = "ec2"
  quota_code   = "L-0263D0A3"
  value        = local.eip_quota_candidate
}

resource "aws_servicequotas_service_quota" "nat_per_az" {
  count        = var.manage_service_quotas && local.nat_per_az_quota_candidate > local.current_nat_per_az_max ? 1 : 0
  service_code = "vpc"
  quota_code   = "L-FE5A380F"
  value        = local.nat_per_az_quota_candidate
}

resource "aws_servicequotas_service_quota" "gateway_vpc_endpoint" {
  count        = var.manage_service_quotas && local.gw_endpoint_quota_candidate > local.current_gw_ep_max ? 1 : 0
  service_code = "vpc"
  quota_code   = "L-1B52E74A"
  value        = local.gw_endpoint_quota_candidate
}

resource "aws_servicequotas_service_quota" "iam_roles" {
  count        = var.manage_service_quotas && local.iam_roles_quota_candidate > local.current_iam_roles_max ? 1 : 0
  provider     = aws.quota_iam
  service_code = "iam"
  quota_code   = "L-FE177D64"
  value        = local.iam_roles_quota_candidate
}

# Regional limits for ROSA HCP + terraform-redhat/rosa-hcp/rhcs VPC (one VPC per cluster, 1 AZ → 1 NAT + 1 EIP each).
# Resource: https://registry.terraform.io/providers/hashicorp/aws/6.43.0/docs/resources/aws_servicequotas_service_quota

data "aws_vpcs" "current" {}

data "aws_eips" "regional" {}

data "aws_iam_roles" "account" {
  provider = aws.quota_iam
}

locals {
  num_clusters = var.cluster_count

  # One EIP and one NAT per cluster (single-AZ VPC layout).
  new_stack_eip_total = local.num_clusters
}

data "aws_nat_gateways" "all" {}

locals {
  # NAT per AZ (L-FE5A380F): DescribeNatGateways has no AZ filter; upper-bound busiest AZ as all regional NATs + one new NAT per cluster (same first AZ per VPC).
  nat_quota_target = length(data.aws_nat_gateways.all.ids) + local.num_clusters + var.service_quota_buffer

  vpc_quota_target   = length(data.aws_vpcs.current.ids) + local.num_clusters + var.service_quota_buffer
  igw_quota_target   = local.vpc_quota_target
  eip_quota_target   = length(data.aws_eips.regional.allocation_ids) + local.new_stack_eip_total + var.service_quota_buffer
  gw_ep_quota_target = length(data.aws_vpcs.current.ids) + local.num_clusters + var.service_quota_buffer

  iam_roles_quota_target = length(tolist(data.aws_iam_roles.account.names)) + (
    local.num_clusters * var.service_quota_iam_roles_per_new_cluster
  ) + var.service_quota_buffer

  # Never request a quota below what AWS reports as applied or below computed need (whichever is higher).
  vpc_quota_candidate         = max(data.aws_servicequotas_service_quota.vpc_max.value, local.vpc_quota_target)
  igw_quota_candidate         = max(data.aws_servicequotas_service_quota.igw_max.value, local.igw_quota_target)
  eip_quota_candidate         = max(data.aws_servicequotas_service_quota.eip_max.value, local.eip_quota_target)
  nat_per_az_quota_candidate  = max(data.aws_servicequotas_service_quota.nat_per_az_max.value, local.nat_quota_target)
  gw_endpoint_quota_candidate = max(data.aws_servicequotas_service_quota.gw_ep_max.value, local.gw_ep_quota_target)
  iam_roles_quota_candidate   = max(data.aws_servicequotas_service_quota.iam_roles_max.value, local.iam_roles_quota_target)
}

data "aws_servicequotas_service_quota" "vpc_max" {
  service_code = "vpc"
  quota_code   = "L-F678F1CE"
}

data "aws_servicequotas_service_quota" "igw_max" {
  service_code = "vpc"
  quota_code   = "L-A4707A72"
}

data "aws_servicequotas_service_quota" "eip_max" {
  service_code = "ec2"
  quota_code   = "L-0263D0A3"
}

data "aws_servicequotas_service_quota" "nat_per_az_max" {
  service_code = "vpc"
  quota_code   = "L-FE5A380F"
}

data "aws_servicequotas_service_quota" "gw_ep_max" {
  service_code = "vpc"
  quota_code   = "L-1B52E74A"
}

data "aws_servicequotas_service_quota" "iam_roles_max" {
  provider     = aws.quota_iam
  service_code = "iam"
  quota_code   = "L-FE177D64"
}

resource "aws_servicequotas_service_quota" "vpc" {
  count        = var.manage_service_quotas ? 1 : 0
  service_code = "vpc"
  quota_code   = "L-F678F1CE"
  value        = local.vpc_quota_candidate
}

resource "aws_servicequotas_service_quota" "internet_gateway" {
  count        = var.manage_service_quotas ? 1 : 0
  service_code = "vpc"
  quota_code   = "L-A4707A72"
  value        = local.igw_quota_candidate
}

resource "aws_servicequotas_service_quota" "eip" {
  count        = var.manage_service_quotas ? 1 : 0
  service_code = "ec2"
  quota_code   = "L-0263D0A3"
  value        = local.eip_quota_candidate
}

resource "aws_servicequotas_service_quota" "nat_per_az" {
  count        = var.manage_service_quotas ? 1 : 0
  service_code = "vpc"
  quota_code   = "L-FE5A380F"
  value        = local.nat_per_az_quota_candidate
}

resource "aws_servicequotas_service_quota" "gateway_vpc_endpoint" {
  count        = var.manage_service_quotas ? 1 : 0
  service_code = "vpc"
  quota_code   = "L-1B52E74A"
  value        = local.gw_endpoint_quota_candidate
}

resource "aws_servicequotas_service_quota" "iam_roles" {
  count        = var.manage_service_quotas ? 1 : 0
  provider     = aws.quota_iam
  service_code = "iam"
  quota_code   = "L-FE177D64"
  value        = local.iam_roles_quota_candidate
}

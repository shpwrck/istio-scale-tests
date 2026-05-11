locals {
  # Build every unique unordered pair of cluster keys: {a, b} where a < b.
  cluster_pairs = var.vpc_peering_enabled ? {
    for pair in [
      for combo in setproduct(local.sorted_cluster_keys, local.sorted_cluster_keys) :
      { a = combo[0], b = combo[1] } if index(local.sorted_cluster_keys, combo[0]) < index(local.sorted_cluster_keys, combo[1])
    ] : "${pair.a}--${pair.b}" => pair
  } : {}

  # Static set of clusters that participate in peering (for data source for_each).
  peering_cluster_keys = var.vpc_peering_enabled ? { for k in local.sorted_cluster_keys : k => k } : {}

  # Build route entries with static keys: each pair × each side × {public, private}.
  peering_routes = var.vpc_peering_enabled ? merge([
    for pair_key, pair in local.cluster_pairs : {
      "${pair_key}--${pair.a}-public" = {
        cluster                = pair.a
        route_type             = "public"
        destination_cidr_block = module.vpc[pair.b].cidr_block
        peering_key            = pair_key
      }
      "${pair_key}--${pair.a}-private" = {
        cluster                = pair.a
        route_type             = "private"
        destination_cidr_block = module.vpc[pair.b].cidr_block
        peering_key            = pair_key
      }
      "${pair_key}--${pair.b}-public" = {
        cluster                = pair.b
        route_type             = "public"
        destination_cidr_block = module.vpc[pair.a].cidr_block
        peering_key            = pair_key
      }
      "${pair_key}--${pair.b}-private" = {
        cluster                = pair.b
        route_type             = "private"
        destination_cidr_block = module.vpc[pair.a].cidr_block
        peering_key            = pair_key
      }
    }
  ]...) : {}
}

# Look up the public route table for each cluster VPC.
data "aws_route_table" "public" {
  for_each = local.peering_cluster_keys

  vpc_id = module.vpc[each.key].vpc_id

  filter {
    name   = "association.subnet-id"
    values = module.vpc[each.key].public_subnets
  }
}

# Look up the private route table for each cluster VPC.
data "aws_route_table" "private" {
  for_each = local.peering_cluster_keys

  vpc_id = module.vpc[each.key].vpc_id

  filter {
    name   = "association.subnet-id"
    values = module.vpc[each.key].private_subnets
  }
}

resource "aws_vpc_peering_connection" "mesh" {
  for_each = local.cluster_pairs

  vpc_id      = module.vpc[each.value.a].vpc_id
  peer_vpc_id = module.vpc[each.value.b].vpc_id
  auto_accept = true

  tags = merge(var.common_tags, {
    Name = "${each.value.a}--${each.value.b}"
  })
}

resource "aws_route" "peering" {
  for_each = local.peering_routes

  route_table_id = (
    each.value.route_type == "public"
    ? data.aws_route_table.public[each.value.cluster].id
    : data.aws_route_table.private[each.value.cluster].id
  )
  destination_cidr_block    = each.value.destination_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.mesh[each.value.peering_key].id
}

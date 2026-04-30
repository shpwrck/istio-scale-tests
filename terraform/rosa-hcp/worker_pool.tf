# Default ROSA HCP worker pool is created with the cluster. Managing it as
# rhcs_hcp_machine_pool with name "workers" triggers provider "magic import"
# (see terraform-redhat/terraform-provider-rhcs machine_pool_resource.go) so
# we can enable autoscaling without a separate terraform import step.

resource "rhcs_hcp_machine_pool" "default_workers" {
  for_each = var.clusters

  cluster   = module.rosa_hcp[each.key].cluster_id
  name      = "workers"
  subnet_id = module.vpc[each.key].private_subnets[0]

  auto_repair = true

  autoscaling = {
    enabled      = true
    min_replicas = each.value.worker_autoscale_min
    max_replicas = each.value.worker_autoscale_max
  }

  # Omit `version`: desired release tracks the cluster; setting it can trigger
  # upgrade logic and provider/API normalization mismatches on refresh.

  aws_node_pool = {
    instance_type            = coalesce(each.value.compute_machine_type, var.default_compute_machine_type)
    tags                     = merge(var.common_tags, each.value.tags)
    ec2_metadata_http_tokens = each.value.ec2_metadata_http_tokens
  }

  lifecycle {
    # OCM/AWS often returns extra tag keys on the node pool; the provider keeps
    # them in state while the plan only has merge(common_tags, cluster tags),
    # which triggers "Provider produced inconsistent result after apply".
    ignore_changes = [aws_node_pool.tags]
  }
}

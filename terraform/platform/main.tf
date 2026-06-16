# --------------------------------------------------------------------------
# Cluster metadata — resolved from ROSA remote state or kubeconfig
# --------------------------------------------------------------------------

# --- ROSA mode: read from rosa-hcp module's local state ---
data "terraform_remote_state" "rosa" {
  count   = var.cluster_provider == "rosa" ? 1 : 0
  backend = "local"
  config = {
    path = "${path.module}/../rosa-hcp/terraform.tfstate"
  }
}

# --- Kubeconfig mode: resolve API URLs from kubeconfig contexts ---
data "external" "cluster_api_url" {
  for_each = var.cluster_provider == "kubeconfig" ? toset(concat([var.hub_cluster_context], var.spoke_cluster_contexts)) : toset([])

  program = [
    "bash", "-c",
    "CLUSTER=$(kubectl --kubeconfig \"$1\" config view -o json | jq -r --arg ctx \"$2\" '.contexts[] | select(.name==$ctx) | .context.cluster') && URL=$(kubectl --kubeconfig \"$1\" config view -o json | jq -r --arg c \"$CLUSTER\" '.clusters[] | select(.name==$c) | .cluster.server') && jq -n --arg url \"$URL\" '{url:$url}'",
    "--",
    pathexpand(var.kubeconfig_path),
    each.key,
  ]
}

locals {
  use_kubeconfig = var.cluster_provider == "kubeconfig"

  cluster_keys = (
    local.use_kubeconfig
    ? concat([var.hub_cluster_context], var.spoke_cluster_contexts)
    : data.terraform_remote_state.rosa[0].outputs.cluster_keys
  )

  first_cluster_key = (
    local.use_kubeconfig
    ? var.hub_cluster_context
    : data.terraform_remote_state.rosa[0].outputs.first_cluster_key
  )

  by_cluster = (
    local.use_kubeconfig
    ? { for ctx in local.cluster_keys : ctx => {
        cluster_api_url = data.external.cluster_api_url[ctx].result.url
      }
    }
    : data.terraform_remote_state.rosa[0].outputs.by_cluster
  )

  admin_password = local.use_kubeconfig ? "" : data.terraform_remote_state.rosa[0].outputs.cluster_admin_password
  token_script   = local.use_kubeconfig ? "" : data.terraform_remote_state.rosa[0].outputs.token_script_path
  kubeconfig     = local.use_kubeconfig ? abspath(pathexpand(var.kubeconfig_path)) : ""

  hub_cluster_key = local.first_cluster_key
  hub_api_url     = local.by_cluster[local.first_cluster_key].cluster_api_url
  hub_admin_pass  = local.admin_password

  sorted_cluster_keys = sort(local.cluster_keys)
  spoke_cluster_keys = {
    for k in local.sorted_cluster_keys : k => k if k != local.first_cluster_key
  }

  acm_local_cluster_name = coalesce(var.acm_local_cluster_name, local.first_cluster_key)
  gitops_enabled         = var.enable_gitops

  argocd_cluster_count        = length(local.spoke_cluster_keys) + 1
  argocd_computed_min_shards  = max(1, ceil(local.argocd_cluster_count / var.argocd_clusters_per_shard))
  argocd_effective_max_shards = max(var.argocd_max_shards, local.argocd_computed_min_shards)
}

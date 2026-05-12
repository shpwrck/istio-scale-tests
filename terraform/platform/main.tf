# Read cluster outputs from the rosa-hcp module's local state.
data "terraform_remote_state" "rosa" {
  backend = "local"
  config = {
    path = "${path.module}/../rosa-hcp/terraform.tfstate"
  }
}

locals {
  cluster_keys      = data.terraform_remote_state.rosa.outputs.cluster_keys
  first_cluster_key = data.terraform_remote_state.rosa.outputs.first_cluster_key
  by_cluster        = data.terraform_remote_state.rosa.outputs.by_cluster
  admin_password    = data.terraform_remote_state.rosa.outputs.cluster_admin_password
  token_script      = data.terraform_remote_state.rosa.outputs.token_script_path

  hub_cluster_key = local.first_cluster_key
  hub_api_url     = local.by_cluster[local.first_cluster_key].cluster_api_url
  hub_admin_pass  = local.admin_password

  sorted_cluster_keys = sort(local.cluster_keys)
  spoke_cluster_keys = {
    for k in local.sorted_cluster_keys : k => k if k != local.first_cluster_key
  }

  acm_local_cluster_name = coalesce(var.acm_local_cluster_name, local.first_cluster_key)
  gitops_enabled         = var.enable_gitops
}

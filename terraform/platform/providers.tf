provider "kubernetes" {
  alias          = "hub"
  host           = local.use_kubeconfig ? null : local.hub_api_url
  config_path    = local.use_kubeconfig ? local.kubeconfig : null
  config_context = local.use_kubeconfig ? local.hub_cluster_key : null

  dynamic "exec" {
    for_each = local.use_kubeconfig ? [] : [1]
    content {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "bash"
      args        = [local.token_script, local.hub_api_url, "cluster-admin", local.hub_admin_pass]
    }
  }
}

provider "helm" {
  alias = "hub"

  kubernetes = local.use_kubeconfig ? {
    config_path    = local.kubeconfig
    config_context = local.hub_cluster_key
    host           = null
    exec           = null
  } : {
    config_path    = null
    config_context = null
    host           = local.hub_api_url
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "bash"
      args        = [local.token_script, local.hub_api_url, "cluster-admin", local.hub_admin_pass]
    }
  }
}

provider "time" {}

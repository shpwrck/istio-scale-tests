provider "kubernetes" {
  alias = "hub"
  host  = local.hub_api_url

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "bash"
    args        = [local.token_script, local.hub_api_url, "cluster-admin", local.hub_admin_pass]
  }
}

provider "helm" {
  alias = "hub"
  kubernetes = {
    host = local.hub_api_url

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "bash"
      args        = [local.token_script, local.hub_api_url, "cluster-admin", local.hub_admin_pass]
    }
  }
}

provider "time" {}

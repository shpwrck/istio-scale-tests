provider "aws" {
  region = var.aws_region
}

# IAM service quotas are global; the Service Quotas API expects us-east-1 (commercial).
provider "aws" {
  alias  = "quota_iam"
  region = "us-east-1"
}

provider "rhcs" {
  # Authenticate with OpenShift Cluster Manager (export RHCS_TOKEN), or set
  # TF_VAR_rhcs_token for CI. See https://registry.terraform.io/providers/terraform-redhat/rhcs/latest/docs
  token = var.rhcs_token
}

# Hub cluster providers for ACM + GitOps resources (platform_acm.tf, platform_gitops.tf).
# OpenShift uses OAuth tokens, not HTTP Basic Auth. The exec plugin exchanges
# cluster-admin credentials for a bearer token via the OAuth token endpoint.
# Phase 1 (enable_platform_setup = false): these providers are configured but never used,
# so Terraform does not attempt to connect. Phase 2: resources reference these providers.

locals {
  hub_api_url      = try(module.rosa_hcp[local.first_cluster_key].cluster_api_url, "")
  hub_admin_pass   = try(random_password.cluster_admin.result, "")
  hub_token_script = "${path.module}/../scripts/oc-token-exec-credential.sh"
}

provider "kubernetes" {
  alias = "hub"
  host  = local.hub_api_url

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "bash"
    args        = [local.hub_token_script, local.hub_api_url, "cluster-admin", local.hub_admin_pass]
  }
}

provider "helm" {
  alias = "hub"
  kubernetes = {
    host = local.hub_api_url

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "bash"
      args        = [local.hub_token_script, local.hub_api_url, "cluster-admin", local.hub_admin_pass]
    }
  }
}

provider "time" {}

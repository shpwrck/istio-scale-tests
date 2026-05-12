output "cluster_keys" {
  description = "Logical cluster keys (lexicographically sorted), same as generated Terraform map keys. Use the same names for kubectl/oc contexts when merging credentials manually."
  value       = local.sorted_cluster_keys
}

output "first_cluster_key" {
  description = "Lexicographically first generated cluster key — default ACM hub candidate when contexts match TF keys."
  value       = local.first_cluster_key
}

output "first_cluster" {
  description = "Summary for the first cluster (same ordering as first_cluster_key)."
  value = {
    key                 = local.first_cluster_key
    cluster_name        = local.clusters[local.first_cluster_key].cluster_name
    cluster_api_url     = module.rosa_hcp[local.first_cluster_key].cluster_api_url
    cluster_console_url = module.rosa_hcp[local.first_cluster_key].cluster_console_url
    cluster_id          = module.rosa_hcp[local.first_cluster_key].cluster_id
    vpc_id              = module.vpc[local.first_cluster_key].vpc_id
    openshift_version   = var.openshift_version
  }
}

output "by_cluster" {
  description = "Per-cluster API endpoints, OCM id, and VPC id after apply."
  value = {
    for k, m in module.rosa_hcp : k => {
      cluster_id           = m.cluster_id
      cluster_name         = local.clusters[k].cluster_name
      cluster_api_url      = m.cluster_api_url
      cluster_console_url  = m.cluster_console_url
      cluster_state        = m.cluster_state
      vpc_id               = module.vpc[k].vpc_id
      machine_cidr         = module.vpc[k].cidr_block
      account_role_prefix  = m.account_role_prefix
      operator_role_prefix = m.operator_role_prefix
    }
  }
}

output "service_quota_targets" {
  description = "Computed minimum quota levels (before max with current AWS limits). For debugging; see service_quotas.tf."
  value = {
    vpc_and_igw = local.vpc_quota_target
    eip         = local.eip_quota_target
    nat_per_az  = local.nat_quota_target
    gw_endpoint = local.gw_ep_quota_target
    iam_roles   = local.iam_roles_quota_target
  }
}

output "cluster_admin_login" {
  description = "Shared cluster-admin credentials for every cluster (same password). Retrieve with: terraform output cluster_admin_login (sensitive)."
  sensitive   = true
  value = {
    username = "cluster-admin"
    password = random_password.cluster_admin.result
  }
}

output "cluster_admin_password" {
  description = "Shared cluster-admin password for all clusters. Used by the platform module for Kubernetes/Helm provider authentication."
  sensitive   = true
  value       = random_password.cluster_admin.result
}

output "token_script_path" {
  description = "Absolute path to oc-token-exec-credential.sh for exec credential plugins."
  value       = abspath("${path.module}/../scripts/oc-token-exec-credential.sh")
}

resource "local_sensitive_file" "kubeconfig" {
  filename        = "${path.module}/kubeconfig"
  file_permission = "0600"
  content = yamlencode({
    apiVersion = "v1"
    kind       = "Config"
    clusters = [for k in local.sorted_cluster_keys : {
      name = k
      cluster = {
        server                     = module.rosa_hcp[k].cluster_api_url
        "insecure-skip-tls-verify" = true
      }
    }]
    users = [for k in local.sorted_cluster_keys : {
      name = k
      user = {
        exec = {
          apiVersion = "client.authentication.k8s.io/v1beta1"
          command    = "bash"
          args = [
            "${abspath(path.module)}/../scripts/oc-token-exec-credential.sh",
            module.rosa_hcp[k].cluster_api_url,
            "cluster-admin",
            random_password.cluster_admin.result,
          ]
        }
      }
    }]
    contexts = [for k in local.sorted_cluster_keys : {
      name = k
      context = {
        cluster = k
        user    = k
      }
    }]
    current-context = local.first_cluster_key
  })
}

output "kubeconfig_path" {
  description = "Absolute path to the generated kubeconfig file."
  value       = local_sensitive_file.kubeconfig.filename
}

output "kubeconfig" {
  description = "Merged kubeconfig for all clusters (exec plugin auth via oc-token-exec-credential.sh). Also written to kubeconfig in the module directory."
  sensitive   = true
  value = yamlencode({
    apiVersion = "v1"
    kind       = "Config"
    clusters = [for k in local.sorted_cluster_keys : {
      name = k
      cluster = {
        server                     = module.rosa_hcp[k].cluster_api_url
        "insecure-skip-tls-verify" = true
      }
    }]
    users = [for k in local.sorted_cluster_keys : {
      name = k
      user = {
        exec = {
          apiVersion = "client.authentication.k8s.io/v1beta1"
          command    = "bash"
          args = [
            "${abspath(path.module)}/../scripts/oc-token-exec-credential.sh",
            module.rosa_hcp[k].cluster_api_url,
            "cluster-admin",
            random_password.cluster_admin.result,
          ]
        }
      }
    }]
    contexts = [for k in local.sorted_cluster_keys : {
      name = k
      context = {
        cluster = k
        user    = k
      }
    }]
    current-context = local.first_cluster_key
  })
}

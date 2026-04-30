locals {
  kubeconfig_output_path_resolved = coalesce(var.kubeconfig_output_path, "${path.module}/rosa-generated.kubeconfig")

  kubeconfig_ca_b64 = var.kubeconfig_skip_tls_verify ? {} : {
    for k, _ in var.clusters : k => base64encode(join("\n", compact([
      for c in data.tls_certificate.cluster_api[k].certificates : trimspace(c.cert_pem)
    ])))
  }

  kubeconfig_render_spec = {
    current_context = local.first_cluster_key
    clusters = [
      for k in local.sorted_cluster_keys : {
        key            = k
        api_url        = module.rosa_hcp[k].cluster_api_url
        cluster_domain = module.rosa_hcp[k].cluster_domain
        username       = module.rosa_hcp[k].cluster_admin_username
        password       = module.rosa_hcp[k].cluster_admin_password
        ca_b64         = var.kubeconfig_skip_tls_verify ? "" : local.kubeconfig_ca_b64[k]
        insecure       = var.kubeconfig_skip_tls_verify ? true : false
      }
    ]
  }
}

# TLS chain for each API (skipped when kubeconfig uses insecure TLS).
data "tls_certificate" "cluster_api" {
  for_each = var.kubeconfig_skip_tls_verify ? {} : var.clusters

  url          = replace(module.rosa_hcp[each.key].cluster_api_url, "https://", "tls://")
  verify_chain = false
}

# OpenShift ignores username/password in kubeconfig; refresh tokens when clusters, CA, password, or path change.
resource "null_resource" "kubeconfig" {
  triggers = {
    cluster_revision = sha256(jsonencode({ for k, m in module.rosa_hcp : k => m.cluster_id }))
    password_id      = random_password.cluster_admin.id
    skip_tls         = var.kubeconfig_skip_tls_verify
    ca_bundle        = sha256(jsonencode(local.kubeconfig_ca_b64))
    out              = abspath(local.kubeconfig_output_path_resolved)
  }

  provisioner "local-exec" {
    environment = {
      OUT       = abspath(local.kubeconfig_output_path_resolved)
      SPEC      = jsonencode(local.kubeconfig_render_spec)
      SCRIPTDIR = abspath("${path.module}/scripts")
    }
    command = "bash \"${path.module}/scripts/render-rosa-kubeconfig.sh\""
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -f '${self.triggers.out}'"
  }
}

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
    "URL=$(kubectl --kubeconfig \"$1\" config view --minify --context \"$2\" -o jsonpath='{.clusters[0].cluster.server}') && [ -n \"$URL\" ] || { echo \"no API server URL for kubeconfig context '$2'\" >&2; exit 1; }; jq -n --arg url \"$URL\" '{url:$url}'",
    "--",
    pathexpand(var.kubeconfig_path),
    each.key,
  ]
}

locals {
  use_kubeconfig = var.cluster_provider == "kubeconfig"

  # Content hash of each local chart, passed as a release value: the helm
  # provider only upgrades on value or chart-version changes, so without this
  # an edited chart file would never roll out on apply.
  charts_dir = "${path.module}/../../charts"
  chart_checksum = { for c in [
    "acm-klusterlet-config", "acm-managed-cluster", "acm-multicluster-hub",
    "acm-openshift-gitops-resources", "argocd-config", "gitops-hub-app-of-apps",
    "gitops-hub-ocm-placement-appset",
    ] : c => sha1(join("", [for f in sort(fileset("${local.charts_dir}/${c}", "**")) : filesha1("${local.charts_dir}/${c}/${f}")]))
  }

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

  # Per-provider child-app defaults, deep-merged under gitops_app_overrides (BACKLOG 9.8):
  # on ROSA the ingress gateway gets an NLB. Behind a Classic LB it received each HTTP
  # request followed by a FIN and aborted it, so mesh checks through the ingress failed
  # intermittently; the same gateway behind an NLB answered 36/36 (2026-10-14).
  provider_app_defaults = var.cluster_provider == "rosa" && var.rosa_ingress_nlb ? {
    "spoke-ingress-gateway-appset" = {
      values = { template = { source = { helm = { valuesObject = {
        service = { annotations = { "service.beta.kubernetes.io/aws-load-balancer-type" = "nlb" } }
      } } } } }
    }
  } : {}

  argocd_cluster_count        = length(local.spoke_cluster_keys) + 1
  argocd_computed_min_shards  = max(1, ceil(local.argocd_cluster_count / var.argocd_clusters_per_shard))
  argocd_effective_max_shards = max(var.argocd_max_shards, local.argocd_computed_min_shards)
}

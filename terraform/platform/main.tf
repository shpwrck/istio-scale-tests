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
    "URL=$(kubectl --kubeconfig \"$1\" config view --minify --context \"$2\" -o jsonpath='{.clusters[0].cluster.server}') && [ -n \"$URL\" ] || { echo \"no API server URL for context '$2' in the kubeconfig file $1 (kubeconfig_path; KUBECONFIG is not read)\" >&2; exit 1; }; jq -n --arg url \"$URL\" '{url:$url}'",
    "--",
    pathexpand(var.kubeconfig_path),
    each.key,
  ]
}

# --- Kubeconfig mode: is the hub OpenShift? (it serves security.openshift.io/v1) ---
# kubeconfig mode defaults to platform kubernetes. Planned that way, an OpenShift deployment
# whose tfvars never set platform would lose the ArgoCD CR and the ACM releases, and the
# app-of-apps would move to argocd: its finalizer deletes the mesh. The postcondition fails the
# plan, before any change, when the hub disagrees with platform (Terraform 1.14 reports it as a
# warning in a destroy plan). A hub that cannot be read reads as unknown and only warns (check
# "hub_platform" below): that plan cannot change the hub anyway, and terraform destroy or a
# plan that leaves the hub alone still runs.
data "external" "hub_platform" {
  count = local.use_kubeconfig ? 1 : 0

  program = ["bash", "-c", local.hub_platform_script, "--", pathexpand(var.kubeconfig_path), var.hub_cluster_context]

  lifecycle {
    postcondition {
      condition     = self.result.openshift == "unknown" || (self.result.openshift == "true") == local.is_openshift
      error_message = self.result.openshift == "true" ? "The hub (context ${var.hub_cluster_context}) runs OpenShift: it serves security.openshift.io/v1. But platform is \"${local.platform}\"${var.platform == null ? " (the kubeconfig-mode default)" : ""}. Set platform = \"openshift\" in your tfvars and plan again. Planned as kubernetes, an OpenShift deployment loses its ArgoCD CR and ACM releases, and the app-of-apps moves to argocd, which deletes the mesh." : "The hub (context ${var.hub_cluster_context}) does not serve security.openshift.io/v1, so it is not OpenShift, but platform = \"openshift\". Remove the platform setting (kubernetes is the default) or fix hub_cluster_context."
    }
  }
}

check "hub_platform" {
  assert {
    condition     = try(data.external.hub_platform[0].result.openshift, "") != "unknown"
    error_message = "Could not read the hub's API groups (kubectl api-versions, context ${var.hub_cluster_context}): ${try(data.external.hub_platform[0].result.error, "")}. So this plan did not check platform = \"${local.platform}\" against the hub. An OpenShift hub needs platform = \"openshift\"."
  }
}

locals {
  use_kubeconfig = var.cluster_provider == "kubeconfig"

  # kubernetes: upstream Argo CD, cluster Secrets, upstream operator charts. openshift:
  # OpenShift GitOps, ACM and OLM operators (the only choice on ROSA).
  platform         = coalesce(var.platform, var.cluster_provider == "rosa" ? "openshift" : "kubernetes")
  is_openshift     = local.platform == "openshift"
  gitops_namespace = coalesce(var.gitops_namespace, local.is_openshift ? "openshift-gitops" : "argocd")

  # data.external.hub_platform: {"openshift": "true" | "false" | "unknown", "error": "..."}.
  # The same test as tests/lib/platform.sh; a failed read is unknown, never a guess.
  hub_platform_script = <<-EOT
    err=$(mktemp) || exit 1
    trap 'rm -f "$err"' EXIT
    if groups=$(kubectl --kubeconfig "$1" --context "$2" --request-timeout=20s api-versions 2>"$err"); then
      if printf '%s\n' "$groups" | grep -qx 'security.openshift.io/v1'; then os=true; else os=false; fi
      jq -n --arg os "$os" '{openshift: $os, error: ""}'
    else
      jq -n --arg e "$(tail -n 3 "$err" | tr '\n' ' ')" '{openshift: "unknown", error: $e}'
    fi
  EOT

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
      cluster_api_url = lookup(var.cluster_api_url_overrides, ctx, data.external.cluster_api_url[ctx].result.url)
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

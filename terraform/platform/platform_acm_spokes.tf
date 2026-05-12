# --------------------------------------------------------------------------
# ACM spoke registration — ManagedCluster + auto-import-secret
#
# Uses the RHACM auto-import-secret approach instead of the manual
# import.yaml extraction from the bash scripts. The ACM import controller
# picks up the auto-import-secret and handles spoke registration.
# --------------------------------------------------------------------------

locals {
  sorted_spoke_keys = sort(keys(local.spoke_cluster_keys))
  mesh_member_spoke_keys = (
    var.mesh_member_count == 0
    ? local.sorted_spoke_keys
    : slice(local.sorted_spoke_keys, 0, min(var.mesh_member_count, length(local.sorted_spoke_keys)))
  )
  mesh_member_spoke_set = toset(local.mesh_member_spoke_keys)
}

data "external" "spoke_token" {
  for_each = local.spoke_cluster_keys

  program = [
    "bash", "-c",
    "TOKEN=$(\"$1\" \"$2\" \"$3\" \"$4\" | jq -r '.status.token') && jq -n --arg token \"$TOKEN\" '{\"token\":$token}'",
    "--",
    local.token_script,
    local.by_cluster[each.key].cluster_api_url,
    "cluster-admin",
    local.admin_password,
  ]
}

resource "kubernetes_manifest" "spoke_namespace" {
  for_each = local.spoke_cluster_keys
  provider = kubernetes.hub

  manifest = {
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = each.key
    }
  }

  computed_fields = ["metadata.labels", "metadata.annotations"]

  field_manager {
    name            = "terraform"
    force_conflicts = true
  }

  depends_on = [time_sleep.wait_acm_ocm_webhook]
}

resource "helm_release" "acm_managed_cluster" {
  for_each = local.spoke_cluster_keys
  provider = helm.hub

  name             = "acm-managed-cluster-${each.key}"
  chart            = "${path.module}/../../charts/acm-managed-cluster"
  namespace        = var.acm_namespace
  create_namespace = false
  wait             = true
  timeout          = 300

  set = concat(
    [
      {
        name  = "managedCluster.name"
        value = each.key
      },
      {
        name  = "clustersetName"
        value = var.acm_cluster_set
      },
    ],
    contains(local.mesh_member_spoke_set, each.key) ? [
      {
        name  = "managedCluster.labels.istio-mesh-member"
        value = "true"
        type  = "string"
      },
    ] : [],
  )

  depends_on = [kubernetes_manifest.spoke_namespace]
}

resource "kubernetes_secret_v1" "auto_import" {
  for_each = local.spoke_cluster_keys
  provider = kubernetes.hub

  metadata {
    name      = "auto-import-secret"
    namespace = each.key
  }

  data = {
    server = local.by_cluster[each.key].cluster_api_url
    token  = data.external.spoke_token[each.key].result.token
  }

  type = "Opaque"

  lifecycle {
    ignore_changes = [data]
  }

  depends_on = [helm_release.acm_managed_cluster]
}

resource "time_sleep" "wait_spoke_registration" {
  count = length(local.spoke_cluster_keys) > 0 ? 1 : 0

  depends_on      = [kubernetes_secret_v1.auto_import]
  create_duration = "300s"
}

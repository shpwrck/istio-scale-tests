# --------------------------------------------------------------------------
# ACM spoke registration — ManagedCluster + auto-import-secret
# Maps to platform-setup/001-acm-install-hub.sh steps 5-6.
#
# Uses the RHACM auto-import-secret approach instead of the manual
# import.yaml extraction from the bash scripts. The ACM import controller
# picks up the auto-import-secret and handles spoke registration.
# --------------------------------------------------------------------------

# Check whether each spoke ManagedCluster is already joined.
# Returns {"joined":"true"} or {"joined":"false"}.
data "external" "spoke_joined" {
  for_each = local.platform_enabled ? local.spoke_cluster_keys : {}

  program = [
    "bash", "-c",
    "S=$(kubectl get managedcluster \"$1\" -o jsonpath='{.status.conditions[?(@.type==\"ManagedClusterJoined\")].status}' 2>/dev/null); if [ \"$S\" = \"True\" ]; then echo '{\"joined\":\"true\"}'; else echo '{\"joined\":\"false\"}'; fi",
    "--",
    each.key,
  ]

  depends_on = [time_sleep.wait_acm_ocm_webhook]
}

locals {
  spokes_needing_import = {
    for k, v in local.spoke_cluster_keys : k => v
    if local.platform_enabled && try(data.external.spoke_joined[k].result.joined, "false") != "true"
  }

  sorted_spoke_keys = sort(keys(local.spoke_cluster_keys))
  mesh_member_spoke_keys = (
    var.mesh_member_count == 0
    ? local.sorted_spoke_keys
    : slice(local.sorted_spoke_keys, 0, min(var.mesh_member_count, length(local.sorted_spoke_keys)))
  )
  mesh_member_spoke_set = toset(local.mesh_member_spoke_keys)
}

# Obtain an OAuth bearer token only for spokes that need importing.
data "external" "spoke_token" {
  for_each = local.spokes_needing_import

  program = [
    "bash", "-c",
    "TOKEN=$(\"${path.module}/../scripts/oc-token-exec-credential.sh\" \"$1\" \"$2\" \"$3\" | jq -r '.status.token') && jq -n --arg token \"$TOKEN\" '{\"token\":$token}'",
    "--",
    module.rosa_hcp[each.key].cluster_api_url,
    "cluster-admin",
    random_password.cluster_admin.result,
  ]
}

resource "kubernetes_manifest" "spoke_namespace" {
  for_each = local.platform_enabled ? local.spoke_cluster_keys : {}
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
  for_each = local.platform_enabled ? local.spoke_cluster_keys : {}
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

# Auto-import secret — only created for spokes not yet joined.
# RHACM's import controller consumes and deletes this secret after use.
resource "kubernetes_secret_v1" "auto_import" {
  for_each = local.spokes_needing_import
  provider = kubernetes.hub

  metadata {
    name      = "auto-import-secret"
    namespace = each.key
  }

  data = {
    server = module.rosa_hcp[each.key].cluster_api_url
    token  = data.external.spoke_token[each.key].result.token
  }

  type = "Opaque"

  lifecycle {
    ignore_changes = [data]
  }

  depends_on = [helm_release.acm_managed_cluster]
}

resource "time_sleep" "wait_spoke_registration" {
  count = local.platform_enabled && length(local.spokes_needing_import) > 0 ? 1 : 0

  depends_on      = [kubernetes_secret_v1.auto_import]
  create_duration = "300s"
}

# --------------------------------------------------------------------------
# ACM hub — operator, MultiClusterHub, KlusterletConfig
# Maps to platform-setup/001-acm-install-hub.sh steps 1-4.
# --------------------------------------------------------------------------

locals {
  hub_cluster_key        = local.first_cluster_key
  acm_local_cluster_name = coalesce(var.acm_local_cluster_name, local.first_cluster_key)
  spoke_cluster_keys = {
    for k in local.sorted_cluster_keys : k => k if k != local.first_cluster_key
  }
  platform_enabled = var.enable_platform_setup
  gitops_enabled   = var.enable_platform_setup && var.enable_gitops
}

# --- ACM namespace ---

resource "kubernetes_manifest" "acm_namespace" {
  count    = local.platform_enabled ? 1 : 0
  provider = kubernetes.hub

  manifest = {
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = var.acm_namespace
    }
  }

  computed_fields = ["metadata.labels", "metadata.annotations"]

  field_manager {
    name            = "terraform"
    force_conflicts = true
  }
}

# --- ACM operator (OLM OperatorGroup + Subscription) ---

resource "kubernetes_manifest" "acm_operator_group" {
  count    = local.platform_enabled ? 1 : 0
  provider = kubernetes.hub

  manifest = {
    apiVersion = "operators.coreos.com/v1"
    kind       = "OperatorGroup"
    metadata = {
      name      = "default"
      namespace = var.acm_namespace
    }
    spec = {
      targetNamespaces = [var.acm_namespace]
    }
  }

  depends_on = [kubernetes_manifest.acm_namespace]
}

resource "kubernetes_manifest" "acm_subscription" {
  count    = local.platform_enabled ? 1 : 0
  provider = kubernetes.hub

  manifest = {
    apiVersion = "operators.coreos.com/v1alpha1"
    kind       = "Subscription"
    metadata = {
      name      = "acm-operator-subscription"
      namespace = var.acm_namespace
    }
    spec = {
      channel             = var.acm_channel
      installPlanApproval = "Automatic"
      name                = "advanced-cluster-management"
      source              = "redhat-operators"
      sourceNamespace     = "openshift-marketplace"
    }
  }

  wait {
    fields = {
      "status.state" = "AtLatestKnown"
    }
  }

  timeouts {
    create = "15m"
    update = "15m"
  }

  depends_on = [kubernetes_manifest.acm_operator_group]
}

# Buffer for operator CRDs to register after CSV Succeeded.
resource "time_sleep" "wait_acm_operator" {
  count = local.platform_enabled ? 1 : 0

  depends_on      = [kubernetes_manifest.acm_subscription]
  create_duration = "60s"
}

# --- MultiClusterHub ---

resource "helm_release" "acm_multicluster_hub" {
  count    = local.platform_enabled ? 1 : 0
  provider = helm.hub

  name             = "acm-multicluster-hub"
  chart            = "${path.module}/../../charts/acm-multicluster-hub"
  namespace        = var.acm_namespace
  create_namespace = false
  wait             = true
  timeout          = 1200

  set = [
    {
      name  = "multiclusterHub.spec.localClusterName"
      value = local.acm_local_cluster_name
    },
  ]

  depends_on = [time_sleep.wait_acm_operator]
}

# Buffer for MultiClusterHub to reach Running and KlusterletConfig CRD to register.
resource "time_sleep" "wait_acm_multicluster_hub" {
  count = local.platform_enabled ? 1 : 0

  depends_on      = [helm_release.acm_multicluster_hub]
  create_duration = "120s"
}

# --- KlusterletConfig ---

resource "helm_release" "acm_klusterlet_config" {
  count    = local.platform_enabled && var.acm_install_klusterletconfig ? 1 : 0
  provider = helm.hub

  name             = "acm-klusterlet-config"
  chart            = "${path.module}/../../charts/acm-klusterlet-config"
  namespace        = var.acm_namespace
  create_namespace = false
  wait             = true
  timeout          = 600

  depends_on = [time_sleep.wait_acm_multicluster_hub]
}

# Buffer for OCM validating webhook TLS readiness before spoke registration.
resource "time_sleep" "wait_acm_ocm_webhook" {
  count = local.platform_enabled ? 1 : 0

  depends_on      = [time_sleep.wait_acm_multicluster_hub]
  create_duration = "120s"
}

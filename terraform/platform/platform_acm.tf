# --------------------------------------------------------------------------
# ACM hub — operator, MultiClusterHub, KlusterletConfig
# --------------------------------------------------------------------------

# --- ACM namespace ---

resource "kubernetes_manifest" "acm_namespace" {
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

resource "time_sleep" "wait_acm_operator" {
  depends_on      = [kubernetes_manifest.acm_subscription]
  create_duration = "60s"
}

# --- MultiClusterHub ---

resource "helm_release" "acm_multicluster_hub" {
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

resource "time_sleep" "wait_acm_multicluster_hub" {
  depends_on      = [helm_release.acm_multicluster_hub]
  create_duration = "120s"
}

# --- KlusterletConfig ---

resource "helm_release" "acm_klusterlet_config" {
  count    = var.acm_install_klusterletconfig ? 1 : 0
  provider = helm.hub

  name             = "acm-klusterlet-config"
  chart            = "${path.module}/../../charts/acm-klusterlet-config"
  namespace        = var.acm_namespace
  create_namespace = false
  wait             = true
  timeout          = 600

  depends_on = [time_sleep.wait_acm_multicluster_hub]
}

resource "time_sleep" "wait_acm_ocm_webhook" {
  depends_on      = [time_sleep.wait_acm_multicluster_hub]
  create_duration = "120s"
}

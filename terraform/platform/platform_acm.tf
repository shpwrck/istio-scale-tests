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

resource "terraform_data" "acm_csv_cleanup" {
  input = {
    token_script      = local.token_script
    hub_api_url       = local.hub_api_url
    hub_admin_pass    = local.hub_admin_pass
    kubeconfig_path   = local.kubeconfig
    hub_context       = local.hub_cluster_key
    sub_namespace     = var.acm_namespace
    sub_name          = "acm-operator-subscription"
    package_name      = "advanced-cluster-management"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash '${path.module}/../scripts/cleanup-olm-csv.sh'"
    environment = {
      TOKEN_SCRIPT    = self.input.token_script
      API_URL         = self.input.hub_api_url
      ADMIN_PASS      = self.input.hub_admin_pass
      KUBECONFIG_PATH = self.input.kubeconfig_path
      KUBE_CONTEXT    = self.input.hub_context
      SUB_NAMESPACE   = self.input.sub_namespace
      SUB_NAME        = self.input.sub_name
      PACKAGE_NAME    = self.input.package_name
    }
  }

  depends_on = [kubernetes_manifest.acm_subscription]
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
  take_ownership   = true
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
  take_ownership   = true
  wait             = true
  timeout          = 600

  set = local.use_kubeconfig ? [
    {
      name  = "klusterletConfig.spec.hubKubeAPIServerConfig.serverVerificationStrategy"
      value = "UseAutoDetectedCABundle"
    },
  ] : []

  depends_on = [time_sleep.wait_acm_multicluster_hub]
}

resource "time_sleep" "wait_acm_ocm_webhook" {
  depends_on      = [time_sleep.wait_acm_multicluster_hub]
  create_duration = "120s"
}

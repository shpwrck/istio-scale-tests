# --------------------------------------------------------------------------
# ACM hub — operator, MultiClusterHub, KlusterletConfig (platform openshift only)
# --------------------------------------------------------------------------

# --- ACM namespace ---

resource "kubernetes_manifest" "acm_namespace" {
  count    = local.is_openshift && var.acm_install_operator ? 1 : 0
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
  count    = local.is_openshift && var.acm_install_operator ? 1 : 0
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
  count    = local.is_openshift && var.acm_install_operator ? 1 : 0
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

  depends_on = [kubernetes_manifest.acm_operator_group]
}

# Waits for the install and prints what blocks it as soon as it shows (platform_gitops.tf,
# gitops_subscription_ready).
resource "terraform_data" "acm_subscription_ready" {
  count = local.is_openshift && var.acm_install_operator ? 1 : 0

  triggers_replace = [var.acm_namespace, var.acm_channel]

  input = {
    token_script    = local.token_script
    hub_api_url     = local.hub_api_url
    hub_admin_pass  = local.hub_admin_pass
    kubeconfig_path = local.kubeconfig
    hub_context     = local.hub_cluster_key
    sub_namespace   = var.acm_namespace
    sub_name        = "acm-operator-subscription"
  }

  provisioner "local-exec" {
    command = "bash '${path.module}/../scripts/olm-subscription-wait.sh'"
    environment = {
      TOKEN_SCRIPT    = self.input.token_script
      API_URL         = self.input.hub_api_url
      ADMIN_PASS      = self.input.hub_admin_pass
      KUBECONFIG_PATH = self.input.kubeconfig_path
      KUBE_CONTEXT    = self.input.hub_context
      SUB_NAMESPACE   = self.input.sub_namespace
      SUB_NAME        = self.input.sub_name
    }
  }

  depends_on = [kubernetes_manifest.acm_subscription]
}

resource "terraform_data" "acm_csv_cleanup" {
  count = local.is_openshift && var.acm_install_operator ? 1 : 0

  input = {
    token_script    = local.token_script
    hub_api_url     = local.hub_api_url
    hub_admin_pass  = local.hub_admin_pass
    kubeconfig_path = local.kubeconfig
    hub_context     = local.hub_cluster_key
    sub_namespace   = var.acm_namespace
    sub_name        = "acm-operator-subscription"
    package_name    = "advanced-cluster-management"
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

  depends_on = [terraform_data.acm_subscription_ready]
}

resource "time_sleep" "wait_acm_operator" {
  count = local.is_openshift ? 1 : 0

  # Through the cleanup hook, so on destroy the CSV cleanup runs only after
  # everything that needs the operator (MultiClusterHub, spokes) is gone.
  depends_on      = [terraform_data.acm_csv_cleanup]
  create_duration = var.acm_install_operator ? "60s" : "0s"
}

# --- kubeconfig mode: free pod slots on the hub before the MultiClusterHub ---
# ACM 2.17 starts about 81 pods on the hub, and OpenShift GitOps and the hub charts about 20
# more (homelab 2026-10-26). Pods beyond the hub's free slots (each node's allocatable pods, 250
# by default, minus the pods on it) stay Pending ("Too many pods"), and the apply fails at the
# first step that waits for one. Warn at plan when no MultiClusterHub exists yet and the nodes
# that take ordinary pods (not cordoned, no NoSchedule or NoExecute taint) have fewer than 100.

locals {
  # data.external.hub_pod_slots: {"free": "<n>", "mch": "true" | "false"}; both "" when the
  # hub cannot be read (check "hub_platform" warns about that).
  hub_pod_slots_script = <<-EOT
    kc() { kubectl --kubeconfig "$KC_FILE" --context "$KC_CTX" --request-timeout=20s "$@"; }
    KC_FILE=$1 KC_CTX=$2
    nodes=$(kc get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.allocatable.pods} {.spec.unschedulable} {.spec.taints[*].effect}{"\n"}{end}' 2>/dev/null) &&
      pods=$(kc get pods -A --field-selector=status.phase!=Succeeded,status.phase!=Failed -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null) ||
      { jq -n '{free: "", mch: ""}'; exit 0; }
    free=$({ printf '%s\n' "$nodes"; echo --; printf '%s\n' "$pods"; } | awk '
      $0 == "--" { pods = 1; next }
      !pods { if ($3 != "true" && $0 !~ / (NoSchedule|NoExecute)( |$)/) cap[$1] = $2; next }
      ($1 in cap) { used[$1]++ }
      END { for (n in cap) free += cap[n] - used[n]; print free + 0 }')
    if kc get multiclusterhubs.operator.open-cluster-management.io -A -o name 2>/dev/null | grep -q .; then mch=true; else mch=false; fi
    jq -n --arg free "$free" --arg mch "$mch" '{free: $free, mch: $mch}'
  EOT
}

data "external" "hub_pod_slots" {
  count = local.use_kubeconfig && local.is_openshift ? 1 : 0

  program = ["bash", "-c", local.hub_pod_slots_script, "--", pathexpand(var.kubeconfig_path), var.hub_cluster_context]
}

check "hub_pod_slots" {
  assert {
    condition     = try(data.external.hub_pod_slots[0].result.mch, "true") != "false" || try(tonumber(data.external.hub_pod_slots[0].result.free), 100) >= 100
    error_message = "The hub (context ${var.hub_cluster_context}) has ${try(data.external.hub_pod_slots[0].result.free, "?")} free pod slots on the nodes that take ordinary pods (allocatable pods minus the pods there), and the apply starts about 100 pods there: ACM's MultiClusterHub about 81, OpenShift GitOps and the hub charts about 20. Pods beyond the free slots stay Pending (\"Too many pods\") and the apply fails at the first step that waits for one. Free slots first: remove workloads the hub does not need, add a node, or raise maxPods with a KubeletConfig."
  }
}

# --- MultiClusterHub ---

resource "helm_release" "acm_multicluster_hub" {
  count    = local.is_openshift ? 1 : 0
  provider = helm.hub

  name             = "acm-multicluster-hub"
  chart            = "${path.module}/../../charts/acm-multicluster-hub"
  namespace        = var.acm_namespace
  create_namespace = false
  take_ownership   = true
  wait             = true
  timeout          = 1200

  values = [yamlencode({ chartChecksum = local.chart_checksum["acm-multicluster-hub"] })]

  set = [
    {
      name  = "multiclusterHub.spec.localClusterName"
      value = local.acm_local_cluster_name
    },
    {
      # An adopted hub (ACM installed before Terraform) keeps its MultiClusterHub on destroy.
      name  = "keepOnUninstall"
      value = tostring(!var.acm_install_operator)
    },
  ]

  depends_on = [time_sleep.wait_acm_operator]
}

resource "time_sleep" "wait_acm_multicluster_hub" {
  count = local.is_openshift ? 1 : 0

  depends_on      = [helm_release.acm_multicluster_hub]
  create_duration = "120s"
}

# --- KlusterletConfig ---

resource "helm_release" "acm_klusterlet_config" {
  count    = local.is_openshift && var.acm_install_klusterletconfig ? 1 : 0
  provider = helm.hub

  name             = "acm-klusterlet-config"
  chart            = "${path.module}/../../charts/acm-klusterlet-config"
  namespace        = var.acm_namespace
  create_namespace = false
  take_ownership   = true
  wait             = true
  timeout          = 600

  values = [yamlencode({ chartChecksum = local.chart_checksum["acm-klusterlet-config"] })]

  set = concat(
    [
      {
        name  = "keepOnUninstall"
        value = tostring(!var.acm_install_operator)
      },
    ],
    local.use_kubeconfig ? [
      {
        name  = "klusterletConfig.spec.hubKubeAPIServerConfig.serverVerificationStrategy"
        value = "UseAutoDetectedCABundle"
      },
    ] : [],
  )

  depends_on = [time_sleep.wait_acm_multicluster_hub]
}

resource "time_sleep" "wait_acm_ocm_webhook" {
  count = local.is_openshift ? 1 : 0

  depends_on      = [time_sleep.wait_acm_multicluster_hub]
  create_duration = "120s"
}

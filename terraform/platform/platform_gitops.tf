# --------------------------------------------------------------------------
# OpenShift GitOps — operator, ArgoCD config, ACM GitOps wiring
# --------------------------------------------------------------------------

# --- GitOps operator (OLM Subscription) ---

resource "kubernetes_manifest" "gitops_subscription" {
  count    = local.gitops_enabled ? 1 : 0
  provider = kubernetes.hub

  manifest = {
    apiVersion = "operators.coreos.com/v1alpha1"
    kind       = "Subscription"
    metadata = {
      name      = "openshift-gitops-operator"
      namespace = var.gitops_operator_namespace
    }
    spec = {
      channel             = var.gitops_operator_channel
      installPlanApproval = "Automatic"
      name                = "openshift-gitops-operator"
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

  depends_on = [time_sleep.wait_acm_ocm_webhook]
}

resource "terraform_data" "gitops_csv_cleanup" {
  count = local.gitops_enabled ? 1 : 0

  input = {
    token_script   = local.token_script
    hub_api_url    = local.hub_api_url
    hub_admin_pass = local.hub_admin_pass
    csv_namespace  = var.gitops_operator_namespace
    package_name   = "openshift-gitops-operator"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash '${path.module}/../scripts/cleanup-olm-csv.sh' '${self.input.token_script}' '${self.input.hub_api_url}' '${self.input.hub_admin_pass}' '${self.input.csv_namespace}' '${self.input.package_name}'"
  }

  depends_on = [kubernetes_manifest.gitops_subscription]
}

resource "time_sleep" "wait_gitops_operator" {
  count = local.gitops_enabled ? 1 : 0

  depends_on      = [kubernetes_manifest.gitops_subscription]
  create_duration = "60s"
}

resource "time_sleep" "wait_argocd_stabilized" {
  count = local.gitops_enabled ? 1 : 0

  depends_on      = [time_sleep.wait_gitops_operator]
  create_duration = "300s"
}

# --- ArgoCD configuration (resource limits + ApplicationSet) ---

resource "terraform_data" "adopt_argocd_for_helm" {
  count = local.gitops_enabled ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      TOKEN=$("${local.token_script}" "${local.hub_api_url}" "cluster-admin" "${local.hub_admin_pass}" | jq -r '.status.token')
      KC="kubectl --server=${local.hub_api_url} --token=$TOKEN --insecure-skip-tls-verify"
      $KC annotate argocd "${var.gitops_argocd_cr_name}" -n "${var.gitops_namespace}" \
        meta.helm.sh/release-name=argocd-config \
        meta.helm.sh/release-namespace="${var.gitops_namespace}" \
        --overwrite 2>/dev/null || true
      $KC label argocd "${var.gitops_argocd_cr_name}" -n "${var.gitops_namespace}" \
        app.kubernetes.io/managed-by=Helm \
        --overwrite 2>/dev/null || true
    EOT
  }

  depends_on = [time_sleep.wait_argocd_stabilized]
}

resource "helm_release" "argocd_config" {
  count    = local.gitops_enabled ? 1 : 0
  provider = helm.hub

  name             = "argocd-config"
  chart            = "${path.module}/../../charts/argocd-config"
  namespace        = var.gitops_namespace
  create_namespace = false
  take_ownership   = true
  wait             = true
  timeout          = 300

  set = concat(
    [
      {
        name  = "argocd.name"
        value = var.gitops_argocd_cr_name
      },
    ],
    var.gitops_rhacm_appset_any_namespace ? [
      {
        name  = "argocd.applicationSet.env[0].name"
        value = "ARGOCD_APPLICATIONSET_CONTROLLER_NAMESPACES"
      },
      {
        name  = "argocd.applicationSet.env[0].value"
        value = "*"
      },
      {
        name  = "argocd.applicationSet.env[1].name"
        value = "ARGOCD_APPLICATIONSET_CONTROLLER_ENABLE_SCM_PROVIDERS"
      },
      {
        name  = "argocd.applicationSet.env[1].value"
        value = "false"
        type  = "string"
      },
    ] : [],
    [for i, ns in var.gitops_applicationset_source_namespaces : {
      name  = "argocd.applicationSet.sourceNamespaces[${i}]"
      value = ns
    }],
  )

  depends_on = [terraform_data.adopt_argocd_for_helm]
}

# --- RHACM ApplicationSet-in-any-namespace RBAC ---

resource "kubernetes_manifest" "appset_cluster_role" {
  count    = local.gitops_enabled && var.gitops_rhacm_appset_any_namespace ? 1 : 0
  provider = kubernetes.hub

  manifest = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name = "openshift-gitops-applicationset-controller"
      labels = {
        "app.kubernetes.io/name"      = "argocd-applicationset-controller"
        "app.kubernetes.io/part-of"   = "argocd-applicationset"
        "app.kubernetes.io/component" = "controller"
      }
    }
    rules = [
      {
        apiGroups = ["argoproj.io"]
        resources = ["applications", "applicationsets", "applicationsets/finalizers"]
        verbs     = ["create", "delete", "get", "list", "patch", "update", "watch"]
      },
      {
        apiGroups = ["argoproj.io"]
        resources = ["applicationsets/status"]
        verbs     = ["get", "patch", "update"]
      },
      {
        apiGroups = ["argoproj.io"]
        resources = ["appprojects"]
        verbs     = ["get", "list", "watch"]
      },
      {
        apiGroups = [""]
        resources = ["events"]
        verbs     = ["create", "get", "list", "patch", "watch"]
      },
      {
        apiGroups = [""]
        resources = ["configmaps"]
        verbs     = ["create", "update", "delete", "get", "list", "patch", "watch"]
      },
      {
        apiGroups = [""]
        resources = ["secrets"]
        verbs     = ["get", "list", "watch"]
      },
      {
        apiGroups = ["apps", "extensions"]
        resources = ["deployments"]
        verbs     = ["get", "list", "watch"]
      },
      {
        apiGroups = ["coordination.k8s.io"]
        resources = ["leases"]
        verbs     = ["create", "delete", "get", "list", "patch", "update", "watch"]
      },
      {
        apiGroups = ["cluster.open-cluster-management.io"]
        resources = ["placementdecisions"]
        verbs     = ["get", "list", "watch"]
      },
    ]
  }

  depends_on = [time_sleep.wait_argocd_stabilized]
}

resource "kubernetes_manifest" "appset_cluster_role_binding" {
  count    = local.gitops_enabled && var.gitops_rhacm_appset_any_namespace ? 1 : 0
  provider = kubernetes.hub

  manifest = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata = {
      name = "openshift-gitops-applicationset-controller"
      labels = {
        "app.kubernetes.io/name"      = "argocd-applicationset-controller"
        "app.kubernetes.io/part-of"   = "argocd-applicationset"
        "app.kubernetes.io/component" = "controller"
      }
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = "openshift-gitops-applicationset-controller"
    }
    subjects = [
      {
        kind      = "ServiceAccount"
        name      = "openshift-gitops-applicationset-controller"
        namespace = var.gitops_namespace
      },
    ]
  }

  depends_on = [kubernetes_manifest.appset_cluster_role]
}

# --- ACM GitOps resources (ManagedClusterSetBinding, Placement, etc.) ---

resource "helm_release" "acm_gitops_resources" {
  count    = local.gitops_enabled ? 1 : 0
  provider = helm.hub

  name             = "acm-openshift-gitops-resources"
  chart            = "${path.module}/../../charts/acm-openshift-gitops-resources"
  namespace        = var.gitops_namespace
  create_namespace = true
  take_ownership   = true
  wait             = true
  timeout          = 300

  set = [
    {
      name  = "gitopsNamespace"
      value = var.gitops_namespace
    },
    {
      name  = "clusterSet"
      value = var.acm_cluster_set
    },
    {
      name  = "placement.name"
      value = "acm-openshift-gitops-placement"
    },
    {
      name  = "argoServer.cluster"
      value = local.acm_local_cluster_name
    },
  ]

  depends_on = [helm_release.argocd_config]
}

# --- Argo CD repository credentials Secret (private repos) ---

locals {
  gitops_repo_has_https_creds = var.gitops_app_repo_password != ""
  gitops_repo_has_ssh_creds   = var.gitops_app_repo_ssh_private_key != ""
  gitops_repo_has_creds       = local.gitops_repo_has_https_creds || local.gitops_repo_has_ssh_creds
}

resource "kubernetes_manifest" "gitops_repo_credentials" {
  count    = local.gitops_enabled && var.gitops_app_repo_url != "" && local.gitops_repo_has_creds ? 1 : 0
  provider = kubernetes.hub

  manifest = {
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = var.gitops_app_repo_credentials_secret_name
      namespace = var.gitops_namespace
      labels = {
        "argocd.argoproj.io/secret-type" = "repository"
      }
    }
    type = "Opaque"
    stringData = merge(
      {
        type = "git"
        url  = var.gitops_app_repo_url
      },
      local.gitops_repo_has_https_creds ? {
        username = var.gitops_app_repo_username
        password = var.gitops_app_repo_password
      } : {},
      local.gitops_repo_has_ssh_creds ? {
        sshPrivateKey = var.gitops_app_repo_ssh_private_key
      } : {},
    )
  }

  computed_fields = ["metadata.labels", "metadata.annotations", "stringData"]

  field_manager {
    name            = "terraform"
    force_conflicts = true
  }

  depends_on = [time_sleep.wait_argocd_stabilized]
}

# --- Hub app-of-apps (Argo CD root Application) ---

resource "helm_release" "gitops_hub_app_of_apps" {
  count    = local.gitops_enabled && var.gitops_app_repo_url != "" ? 1 : 0
  provider = helm.hub

  name             = "gitops-hub-app-of-apps"
  chart            = "${path.module}/../../charts/gitops-hub-app-of-apps"
  namespace        = var.gitops_namespace
  create_namespace = false
  take_ownership   = true
  wait             = true
  timeout          = 300

  set = [
    {
      name  = "gitopsNamespace"
      value = var.gitops_namespace
    },
    {
      name  = "repo.url"
      value = var.gitops_app_repo_url
      type  = "string"
    },
    {
      name  = "repo.revision"
      value = var.gitops_app_repo_revision
      type  = "string"
    },
  ]

  depends_on = [helm_release.acm_gitops_resources, kubernetes_manifest.gitops_repo_credentials]
}

# --- GitOpsCluster CR ---

resource "helm_release" "gitops_cluster" {
  count    = local.gitops_enabled ? 1 : 0
  provider = helm.hub

  name             = "acm-gitops-cluster"
  chart            = "${path.module}/../../charts/acm-gitops-cluster"
  namespace        = var.gitops_namespace
  create_namespace = false
  take_ownership   = true
  wait             = true
  timeout          = 300

  set = [
    {
      name  = "gitopsCluster.argoServer.cluster"
      value = local.acm_local_cluster_name
    },
    {
      name  = "gitopsCluster.argoServer.argoNamespace"
      value = var.gitops_namespace
    },
    {
      name  = "gitopsCluster.placementRef.name"
      value = "acm-openshift-gitops-placement"
    },
    {
      name  = "gitopsCluster.gitopsAddon.enabled"
      value = tostring(var.gitops_addon_enabled)
      type  = "string"
    },
    {
      name  = "gitopsCluster.managedServiceAccountRef"
      value = var.gitops_managed_service_account_name
    },
  ]

  depends_on = [helm_release.acm_gitops_resources]
}

# --- ArgoCD cluster secrets (correct server URL) ---
# ACM's gitops-addon creates cluster secrets with internal control-plane
# URLs that are unreachable. We wait for them to appear, then overwrite
# the server and config fields with the correct external API URL.

resource "time_sleep" "wait_argocd_cluster_secrets" {
  count = local.gitops_enabled && length(local.spoke_cluster_keys) > 0 ? 1 : 0

  depends_on      = [helm_release.gitops_cluster, time_sleep.wait_spoke_registration]
  create_duration = "120s"
}

resource "terraform_data" "patch_argocd_cluster_secret" {
  for_each = local.gitops_enabled ? local.spoke_cluster_keys : {}

  triggers_replace = [
    local.by_cluster[each.key].cluster_api_url,
    helm_release.acm_managed_cluster[each.key].metadata.revision,
    timestamp(),
  ]

  input = {
    spoke_name              = each.key
    api_url                 = local.by_cluster[each.key].cluster_api_url
    token                   = data.external.spoke_token[each.key].result.token
    token_script            = local.token_script
    hub_api_url             = local.hub_api_url
    hub_admin_pass          = local.hub_admin_pass
    gitops_namespace        = var.gitops_namespace
    managed_sa_name         = var.gitops_managed_service_account_name
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/../scripts/patch-argocd-cluster-secret.sh"
    environment = {
      SPOKE_NAME       = self.input.spoke_name
      API_URL          = self.input.api_url
      SPOKE_TOKEN      = self.input.token
      HUB_TOKEN_SCRIPT = self.input.token_script
      HUB_API_URL      = self.input.hub_api_url
      HUB_ADMIN_PASS   = self.input.hub_admin_pass
      GITOPS_NAMESPACE = self.input.gitops_namespace
      MANAGED_SA_NAME  = self.input.managed_sa_name
    }
  }

  depends_on = [time_sleep.wait_argocd_cluster_secrets]
}

# --- Destroy-time cleanup: cascade-delete all Argo CD Applications ---

resource "terraform_data" "argocd_app_cleanup" {
  count = local.gitops_enabled && var.gitops_app_repo_url != "" ? 1 : 0

  input = {
    token_script     = local.token_script
    hub_api_url      = local.hub_api_url
    hub_admin_pass   = local.hub_admin_pass
    gitops_namespace = var.gitops_namespace
  }

  depends_on = [
    helm_release.gitops_hub_app_of_apps,
    helm_release.gitops_cluster,
  ]

  provisioner "local-exec" {
    when    = destroy
    command = "bash ${path.module}/../scripts/argocd-app-cleanup.sh '${self.input.token_script}' '${self.input.hub_api_url}' '${self.input.hub_admin_pass}' '${self.input.gitops_namespace}'"
  }
}

# --------------------------------------------------------------------------
# OpenShift GitOps — operator, ArgoCD config, ACM GitOps wiring
# Maps to platform-setup/002-acm-openshift-gitops.sh.
# --------------------------------------------------------------------------

# --- GitOps operator (OLM Subscription) ---
# No OperatorGroup: openshift-gitops-operator uses the cluster-default AllNamespaces OperatorGroup.

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

resource "time_sleep" "wait_gitops_operator" {
  count = local.gitops_enabled ? 1 : 0

  depends_on      = [kubernetes_manifest.gitops_subscription]
  create_duration = "60s"
}

# ArgoCD instance is created by the operator; wait for it to stabilize.
resource "time_sleep" "wait_argocd_stabilized" {
  count = local.gitops_enabled ? 1 : 0

  depends_on      = [time_sleep.wait_gitops_operator]
  create_duration = "300s"
}

# --- ArgoCD configuration (resource limits + ApplicationSet) ---

resource "kubernetes_manifest" "argocd_config" {
  count    = local.gitops_enabled ? 1 : 0
  provider = kubernetes.hub

  manifest = {
    apiVersion = "argoproj.io/v1beta1"
    kind       = "ArgoCD"
    metadata = {
      name      = var.gitops_argocd_cr_name
      namespace = var.gitops_namespace
    }
    spec = {
      controller = {
        resources = {
          limits = {
            cpu    = var.argocd_resource_limits_cpu
            memory = var.argocd_resource_limits_memory
          }
        }
      }
      repo = {
        resources = {
          limits = {
            cpu    = var.argocd_resource_limits_cpu
            memory = var.argocd_resource_limits_memory
          }
        }
      }
      server = {
        resources = {
          limits = {
            cpu    = var.argocd_resource_limits_cpu
            memory = var.argocd_resource_limits_memory
          }
        }
      }
      applicationSet = {
        enabled = true
        resources = {
          limits = {
            cpu    = var.argocd_resource_limits_cpu
            memory = var.argocd_resource_limits_memory
          }
        }
        env = var.gitops_rhacm_appset_any_namespace ? [
          {
            name  = "ARGOCD_APPLICATIONSET_CONTROLLER_NAMESPACES"
            value = "*"
          },
          {
            name  = "ARGOCD_APPLICATIONSET_CONTROLLER_ENABLE_SCM_PROVIDERS"
            value = "false"
          },
        ] : []
        sourceNamespaces = var.gitops_applicationset_source_namespaces
      }
    }
  }

  computed_fields = ["metadata.labels", "metadata.annotations", "metadata.resourceVersion"]

  field_manager {
    name            = "terraform"
    force_conflicts = true
  }

  depends_on = [time_sleep.wait_argocd_stabilized]
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
  ]

  depends_on = [kubernetes_manifest.argocd_config]
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

resource "kubernetes_manifest" "gitops_cluster" {
  count    = local.gitops_enabled ? 1 : 0
  provider = kubernetes.hub

  manifest = {
    apiVersion = "apps.open-cluster-management.io/v1beta1"
    kind       = "GitOpsCluster"
    metadata = {
      name      = "acm-openshift-gitops"
      namespace = var.gitops_namespace
    }
    spec = {
      argoServer = {
        cluster       = local.acm_local_cluster_name
        argoNamespace = var.gitops_namespace
      }
      placementRef = {
        kind       = "Placement"
        apiVersion = "cluster.open-cluster-management.io/v1beta1"
        name       = "acm-openshift-gitops-placement"
        namespace  = var.gitops_namespace
      }
      gitopsAddon = {
        enabled = var.gitops_addon_enabled
      }
    }
  }

  depends_on = [helm_release.acm_gitops_resources]
}

# --- Patch ACM ArgoCD cluster secrets ---
# ACM's GitOps addon creates *-application-manager-cluster-secret per spoke
# with internal *-control-plane URLs that are unreachable from the hub.
# Wait for the addon to create them, then patch with real API URLs + tokens.

resource "time_sleep" "wait_gitops_addon_secrets" {
  count = local.gitops_enabled && length(local.spoke_cluster_keys) > 0 ? 1 : 0

  depends_on      = [kubernetes_manifest.gitops_cluster, time_sleep.wait_spoke_registration]
  create_duration = "120s"

  # Re-sleep when any ManagedCluster Helm release changes (e.g. label update),
  # giving ACM time to reconcile before we patch ArgoCD cluster secrets.
  triggers = {
    managed_cluster_revisions = join(",", [
      for k in sort(keys(local.spoke_cluster_keys)) :
      helm_release.acm_managed_cluster[k].metadata.revision
    ])
  }
}

data "external" "spoke_cluster_secret_token" {
  for_each = local.gitops_enabled ? local.spoke_cluster_keys : {}

  program = [
    "bash", "-c",
    "TOKEN=$(\"${path.module}/../scripts/oc-token-exec-credential.sh\" \"$1\" \"$2\" \"$3\" | jq -r '.status.token') && jq -n --arg token \"$TOKEN\" '{\"token\":$token}'",
    "--",
    module.rosa_hcp[each.key].cluster_api_url,
    "cluster-admin",
    random_password.cluster_admin.result,
  ]
}

data "external" "patch_argocd_cluster_secret" {
  for_each = local.gitops_enabled ? local.spoke_cluster_keys : {}

  program = [
    "bash",
    "${path.module}/../scripts/patch-argocd-cluster-secret.sh",
    each.key,
    module.rosa_hcp[each.key].cluster_api_url,
    data.external.spoke_cluster_secret_token[each.key].result.token,
    var.gitops_namespace,
  ]

  depends_on = [time_sleep.wait_gitops_addon_secrets]
}

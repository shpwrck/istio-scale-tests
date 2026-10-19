# --------------------------------------------------------------------------
# Argo CD — upstream chart (kubernetes) or OpenShift GitOps operator, ArgoCD config
# and ACM GitOps wiring (openshift); cluster Secrets and the app-of-apps (both)
# --------------------------------------------------------------------------

# --- kubernetes: upstream Argo CD (argo-cd Helm chart) ---
# charts/argocd-config/values.yaml is the one place the hub's Argo CD tuning is set: on
# openshift it becomes the ArgoCD CR, on kubernetes Terraform maps it onto the argo-cd
# chart's values here. The release is named argocd, so the controllers' ServiceAccounts
# are argocd-application-controller and argocd-applicationset-controller, the names the
# charts' RBAC defaults expect.

locals {
  argocd_tuning = yamldecode(file("${local.charts_dir}/argocd-config/values.yaml")).argocd

  argocd_upstream_values = {
    dex           = { enabled = false }
    notifications = { enabled = false }
    configs = {
      cm = merge(
        {
          "timeout.reconciliation" = local.argocd_tuning.controller.appSync
          # Replaces the chart's default list, as resourceExclusions does on openshift.
          "resource.exclusions" = yamlencode(local.argocd_tuning.resourceExclusions)
        },
        { for h in local.argocd_tuning.resourceHealthChecks :
          "resource.customizations.health.${h.group}_${h.kind}" => h.check
        },
      )
      params = {
        "controller.status.processors"    = local.argocd_tuning.controller.processors.status
        "controller.operation.processors" = local.argocd_tuning.controller.processors.operation
        "controller.sharding.algorithm"   = local.argocd_tuning.controller.kubernetesShardingAlgorithm
        # No chart needs the repo's git submodules (the bats test frameworks on github.com).
        # Cloning them for every render fails wherever github.com is unreachable (a git mirror).
        "reposerver.enable.git.submodule"               = "false"
        "applicationsetcontroller.enable.git.submodule" = "false"
      }
    }
    # A fixed replica count, ceil((spokes + 1) / argocd_clusters_per_shard), and a shard pinned
    # in each spoke's cluster Secret (create_argocd_cluster_secret, local.argocd_cluster_shard):
    # the replicas agree on every owner without the openshift reshard restart, and a spoke
    # changes owner only through its own Secret, which makes the old owner drop its cache.
    controller = {
      replicas  = local.argocd_computed_min_shards
      resources = local.argocd_tuning.controller.resources
    }
    repoServer = {
      replicas  = local.argocd_tuning.repo.replicas
      resources = local.argocd_tuning.repo.resources
    }
    server         = { resources = local.argocd_tuning.server.resources }
    applicationSet = { resources = local.argocd_tuning.applicationSetResources }
  }
}

resource "helm_release" "argocd" {
  count    = local.gitops_enabled && !local.is_openshift && var.gitops_install_operator ? 1 : 0
  provider = helm.hub

  name             = "argocd"
  repository       = var.argocd_chart_repository
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = local.gitops_namespace
  create_namespace = true
  wait             = true
  timeout          = 900

  # Helm deep-merges the documents in order, so argocd_helm_values overrides any key.
  values = [yamlencode(local.argocd_upstream_values), yamlencode(var.argocd_helm_values)]

  lifecycle {
    precondition {
      condition     = length(keys(var.argocd_config_values)) == 0
      error_message = "argocd_config_values sets the OpenShift GitOps ArgoCD CR (platform openshift). On platform kubernetes put the same settings in argocd_helm_values, in the argo-cd chart's schema (e.g. controller.resources)."
    }
  }
}

# With gitops_install_operator = false there is no helm_release.argocd, so neither its
# precondition nor argocd_helm_values applies: say so instead of ignoring them silently.
check "argocd_values_unused" {
  assert {
    condition     = local.is_openshift || var.gitops_install_operator || (length(keys(var.argocd_helm_values)) == 0 && length(keys(var.argocd_config_values)) == 0)
    error_message = "gitops_install_operator = false: Terraform installs no Argo CD on platform kubernetes, so it applies neither argocd_helm_values nor argocd_config_values. Give the existing Argo CD those settings yourself (terraform/platform/README.md, Existing clusters)."
  }
}

# --- openshift: GitOps operator (OLM Subscription) ---

resource "kubernetes_manifest" "gitops_subscription" {
  count    = local.gitops_enabled && local.is_openshift && var.gitops_install_operator ? 1 : 0
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
  count = local.gitops_enabled && local.is_openshift && var.gitops_install_operator ? 1 : 0

  input = {
    token_script    = local.token_script
    hub_api_url     = local.hub_api_url
    hub_admin_pass  = local.hub_admin_pass
    kubeconfig_path = local.kubeconfig
    hub_context     = local.hub_cluster_key
    sub_namespace   = var.gitops_operator_namespace
    sub_name        = "openshift-gitops-operator"
    package_name    = "openshift-gitops-operator"
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

  depends_on = [kubernetes_manifest.gitops_subscription]
}

resource "time_sleep" "wait_gitops_operator" {
  count = local.gitops_enabled && local.is_openshift ? 1 : 0

  # Through the cleanup hook, so on destroy the CSV cleanup runs only after the
  # ArgoCD CR (whose finalizer the operator handles) and all apps are gone.
  depends_on      = [terraform_data.gitops_csv_cleanup]
  create_duration = var.gitops_install_operator ? "60s" : "0s"
}

resource "time_sleep" "wait_argocd_stabilized" {
  count = local.gitops_enabled && local.is_openshift ? 1 : 0

  depends_on      = [time_sleep.wait_gitops_operator]
  create_duration = var.gitops_install_operator ? "300s" : "0s"
}

# --- openshift: ArgoCD configuration (resource limits + ApplicationSet) ---

resource "helm_release" "argocd_config" {
  count    = local.gitops_enabled && local.is_openshift ? 1 : 0
  provider = helm.hub

  name             = "argocd-config"
  chart            = "${path.module}/../../charts/argocd-config"
  namespace        = local.gitops_namespace
  create_namespace = false
  take_ownership   = true
  wait             = true
  timeout          = 300

  values = [yamlencode(var.argocd_config_values), yamlencode({ chartChecksum = local.chart_checksum["argocd-config"] })]

  set = concat(
    [
      {
        name  = "argocd.name"
        value = var.gitops_argocd_cr_name
      },
      {
        name  = "argocd.controller.sharding.clustersPerShard"
        value = tostring(var.argocd_clusters_per_shard)
      },
      # minShards = ceil((spokes + 1 for in-cluster) / clustersPerShard)
      # Guarantees the statefulset starts with enough replicas so no Application
      # gets an empty controllerNamespace while dynamic scaling catches up.
      {
        name  = "argocd.controller.sharding.minShards"
        value = tostring(local.argocd_computed_min_shards)
      },
      {
        name  = "argocd.controller.sharding.maxShards"
        value = tostring(local.argocd_effective_max_shards)
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

  depends_on = [time_sleep.wait_argocd_stabilized]
}

# --- openshift: RHACM ApplicationSet-in-any-namespace RBAC ---

resource "kubernetes_manifest" "appset_cluster_role" {
  count    = local.gitops_enabled && local.is_openshift && var.gitops_rhacm_appset_any_namespace ? 1 : 0
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
  count    = local.gitops_enabled && local.is_openshift && var.gitops_rhacm_appset_any_namespace ? 1 : 0
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
        namespace = local.gitops_namespace
      },
    ]
  }

  depends_on = [kubernetes_manifest.appset_cluster_role]
}

# --- openshift: ACM GitOps resources (ManagedClusterSetBinding, Placement, etc.) ---

resource "helm_release" "acm_gitops_resources" {
  count    = local.gitops_enabled && local.is_openshift ? 1 : 0
  provider = helm.hub

  name             = "acm-openshift-gitops-resources"
  chart            = "${path.module}/../../charts/acm-openshift-gitops-resources"
  namespace        = local.gitops_namespace
  create_namespace = true
  take_ownership   = true
  wait             = true
  timeout          = 300

  values = [yamlencode({ chartChecksum = local.chart_checksum["acm-openshift-gitops-resources"] })]

  set = [
    {
      name  = "gitopsNamespace"
      value = local.gitops_namespace
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
      namespace = local.gitops_namespace
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

  depends_on = [time_sleep.wait_argocd_stabilized, helm_release.argocd]
}

# --- Hub app-of-apps (Argo CD root Application) ---

resource "helm_release" "gitops_hub_app_of_apps" {
  count    = local.gitops_enabled && var.gitops_app_repo_url != "" ? 1 : 0
  provider = helm.hub

  name             = "gitops-hub-app-of-apps"
  chart            = "${path.module}/../../charts/gitops-hub-app-of-apps"
  namespace        = local.gitops_namespace
  create_namespace = false
  take_ownership   = true
  wait             = true
  timeout          = 300

  # Provider defaults come as their own values document BEFORE the user overrides, so
  # Helm deep-merges an override of the same app into them (Terraform's merge() is
  # shallow, and a later -var-file replaces the whole gitops_app_overrides map).
  values = [yamlencode({
    platform        = local.platform
    gitopsNamespace = local.gitops_namespace
    repo = {
      url      = var.gitops_app_repo_url
      revision = var.gitops_app_repo_revision
    }
    }), yamlencode({ apps = local.provider_app_defaults }),
    yamlencode({ apps = var.gitops_app_overrides }),
  yamlencode({ chartChecksum = local.chart_checksum["gitops-hub-app-of-apps"] })]

  depends_on = [helm_release.acm_gitops_resources, helm_release.argocd, kubernetes_manifest.gitops_repo_credentials]
}

# --- Mesh-wiring health gate ApplicationSet ---
# Deploys charts/mesh-wiring-verify on every istio-mesh-member (the cluster Secret label;
# on openshift acm-openshift-gitops-placement, requireMeshMemberLabel=true). Each member runs
# a readiness-gated pod that goes NotReady — flipping its Argo Application
# Degraded — when it is missing remote secrets or istiod has not synced every
# cluster. This surfaces partial ESO PushSecret fan-out, which both Argo
# (no PushSecret health check) and ESO (reports Synced=True on partial push)
# otherwise hide.
#
# expectedMembers and expectedClusters (the members' names) are derived here from the same
# source of truth that labels mesh members, so a change to mesh_member_count automatically
# updates the gate. With the names each gate checks every other member by name and names a
# remote secret or cluster of any other (a removed member's stays behind), which a count
# cannot tell from a member's.
resource "helm_release" "mesh_wiring_verify_appset" {
  count    = local.gitops_enabled && var.gitops_app_repo_url != "" ? 1 : 0
  provider = helm.hub

  name             = "mesh-wiring-verify-appset"
  chart            = "${path.module}/../../charts/gitops-hub-ocm-placement-appset"
  namespace        = local.gitops_namespace
  create_namespace = false
  take_ownership   = true
  wait             = true
  timeout          = 300

  values = [
    file("${path.module}/../../charts/gitops-hub-ocm-placement-appset/values-mesh-wiring-verify.yaml"),
    file("${path.module}/../../charts/gitops-hub-ocm-placement-appset/platform-${local.platform}.yaml"),
    # The members' names, which are their Istio cluster IDs and remote-secret suffixes: the
    # ApplicationSets pass each member its Argo CD cluster name (the spoke key) as clusterName.
    # A list in a values document: a set value would split on the commas.
    yamlencode({ template = { source = { helm = { valuesObject = {
      expectedClusters = local.mesh_member_spoke_keys
    } } } } }),
    yamlencode({ chartChecksum = local.chart_checksum["gitops-hub-ocm-placement-appset"] }),
  ]

  set = [
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
    {
      # Set expectedMembers BY NAME via Argo helm.valuesObject (not a positional
      # parameters[N] index), so reordering/inserting parameter entries can never
      # misroute the mesh size — see issue #28. The ApplicationSet template emits
      # this map into each per-spoke Application's spec.source.helm.valuesObject,
      # and Argo merges it into the mesh-wiring-verify child chart's Helm values
      # (charts/mesh-wiring-verify reads .Values.expectedMembers).
      name  = "template.source.helm.valuesObject.expectedMembers"
      value = tostring(length(local.mesh_member_spoke_keys))
      type  = "string"
    },
  ]

  depends_on = [helm_release.acm_gitops_resources, helm_release.acm_managed_cluster, helm_release.argocd]
}

# --- ArgoCD cluster secrets (direct external URL, Terraform-owned) ---
# kubernetes: the cluster Secrets are how the spokes join at all. The script creates a
# ServiceAccount bound to cluster-admin on each spoke (spoke_service_account_namespace, a
# namespace it creates unless it exists) and puts its token in the Secret; mesh members
# carry the istio-mesh-member label the ApplicationSets select. A changed trigger re-runs
# the script, which updates the Secret in place; a new namespace moves the ServiceAccount
# there and then removes the old one. spoke_access_cleanup removes the Secret and the
# ServiceAccount on destroy.
#
# openshift: we create these secrets ourselves instead of letting ACM's GitOpsCluster
# controller generate them. That controller only ever writes an unreachable
# server URL — https://<name>-control-plane in gitops-addon/pull mode, or a
# flaky cluster-proxy tunnel URL in push mode — and reconciles it back on every
# change, so the old patch-on-apply approach lost the race indefinitely.
#
# With the GitOpsCluster removed, nothing reconciles the server field, so the
# secret durably points at the spoke's direct external API URL. The secret name
# and data keys (name/server/config) match what the hub-kubeconfig-from-argosecret
# ESO chart reads, so Argo CD push-sync AND the ESO mesh-CA distribution both
# resolve the spoke via the same reliable external URL.

resource "terraform_data" "create_argocd_cluster_secret" {
  for_each = local.gitops_enabled ? local.spoke_cluster_keys : {}

  # The namespace only on kubernetes (it is unused on openshift), and the shard pin only where
  # Terraform installs Argo CD on kubernetes, appended so that openshift state keeps its
  # trigger list (and its input) unchanged. A new pin re-runs the script: that update of the
  # spoke's own Secret is what makes the controller that owned the spoke drop its cache.
  triggers_replace = concat(
    [
      local.platform,
      local.by_cluster[each.key].cluster_api_url,
      contains(local.mesh_member_spoke_set, each.key),
      try(helm_release.acm_managed_cluster[each.key].metadata.revision, ""),
    ],
    local.is_openshift ? [] : [var.spoke_service_account_namespace],
    local.argocd_pin_shards ? [local.argocd_cluster_shard[each.key]] : [],
  )

  input = merge({
    platform           = local.platform
    spoke_name         = each.key
    api_url            = local.by_cluster[each.key].cluster_api_url
    mesh_member        = tostring(contains(local.mesh_member_spoke_set, each.key))
    token_script       = local.token_script
    hub_api_url        = local.hub_api_url
    hub_admin_pass     = local.hub_admin_pass
    kubeconfig_path    = local.kubeconfig
    hub_context        = local.hub_cluster_key
    spoke_context      = each.key
    gitops_namespace   = local.gitops_namespace
    managed_sa_name    = var.gitops_managed_service_account_name
    spoke_sa_namespace = var.spoke_service_account_namespace
  }, local.argocd_pin_shards ? { shard = local.argocd_cluster_shard[each.key] } : {})

  provisioner "local-exec" {
    command = "bash ${path.module}/../scripts/create-argocd-cluster-secret.sh"
    environment = {
      PLATFORM           = self.input.platform
      SPOKE_NAME         = self.input.spoke_name
      API_URL            = self.input.api_url
      MESH_MEMBER        = self.input.mesh_member
      HUB_TOKEN_SCRIPT   = self.input.token_script
      HUB_API_URL        = self.input.hub_api_url
      HUB_ADMIN_PASS     = self.input.hub_admin_pass
      KUBECONFIG_PATH    = self.input.kubeconfig_path
      HUB_CONTEXT        = self.input.hub_context
      SPOKE_CONTEXT      = self.input.spoke_context
      GITOPS_NAMESPACE   = self.input.gitops_namespace
      MANAGED_SA_NAME    = self.input.managed_sa_name
      SPOKE_SA_NAMESPACE = self.input.spoke_sa_namespace
      SHARD              = try(self.input.shard, "")
    }
  }

  # wait_spoke_registration: spoke ManagedCluster registered + MSA token minted on the hub.
  # acm_gitops_resources / argocd: the Argo CD namespace and instance exist to hold the secret.
  depends_on = [time_sleep.wait_spoke_registration, helm_release.acm_gitops_resources, helm_release.argocd]
}

# --- kubernetes, destroy-time cleanup: each spoke's cluster Secret and ServiceAccount ---
# (and its namespace if the script created it; never kube-system or one it did not create).
# The Secret holds a cluster-admin token for the spoke. A separate resource, so a re-run of
# create_argocd_cluster_secret (any changed input) never deletes the Secret: that would
# drop every Application of the spoke. argocd_app_cleanup depends on it, so on destroy the
# member Applications are deleted first, while Argo CD can still reach the spoke.

resource "terraform_data" "spoke_access_cleanup" {
  for_each = local.gitops_enabled && !local.is_openshift ? local.spoke_cluster_keys : {}

  input = {
    spoke_name         = each.key
    kubeconfig_path    = local.kubeconfig
    hub_context        = local.hub_cluster_key
    spoke_context      = each.key
    gitops_namespace   = local.gitops_namespace
    managed_sa_name    = var.gitops_managed_service_account_name
    spoke_sa_namespace = var.spoke_service_account_namespace
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash ${path.module}/../scripts/create-argocd-cluster-secret.sh"
    environment = {
      ACTION             = "delete"
      PLATFORM           = "kubernetes"
      SPOKE_NAME         = self.input.spoke_name
      KUBECONFIG_PATH    = self.input.kubeconfig_path
      HUB_CONTEXT        = self.input.hub_context
      SPOKE_CONTEXT      = self.input.spoke_context
      GITOPS_NAMESPACE   = self.input.gitops_namespace
      MANAGED_SA_NAME    = self.input.managed_sa_name
      SPOKE_SA_NAMESPACE = self.input.spoke_sa_namespace
    }
  }

  depends_on = [terraform_data.create_argocd_cluster_secret]
}

# --- Argo CD controller restart after the cluster secrets (BACKLOG 9.1) ---
# With dynamicScalingEnabled the GitOps operator restarts the application controller
# seconds after the cluster secrets appear. A controller that starts mid-change can log
# "has no assigned shard" for a cluster and never pick it up: on the 2026-10-14 ROSA
# window one member's Applications had no status for 35 min until the controller pods
# were restarted by hand. Wait for the operator's reconcile to settle, then restart the
# controller pods once, before the placement generator lets the ApplicationSets render
# the member Applications. Re-runs whenever a cluster secret is re-created.

resource "terraform_data" "argocd_controller_reshard" {
  count = local.gitops_enabled && local.is_openshift && var.argocd_restart_controller_after_cluster_secrets && length(local.spoke_cluster_keys) > 0 ? 1 : 0

  triggers_replace = [for k in sort(keys(local.spoke_cluster_keys)) : terraform_data.create_argocd_cluster_secret[k].id]

  input = {
    token_script     = local.token_script
    hub_api_url      = local.hub_api_url
    hub_admin_pass   = local.hub_admin_pass
    kubeconfig_path  = local.kubeconfig
    hub_context      = local.hub_cluster_key
    gitops_namespace = local.gitops_namespace
    argocd_name      = var.gitops_argocd_cr_name
  }

  provisioner "local-exec" {
    command = "bash '${path.module}/../scripts/argocd-controller-reshard.sh'"
    environment = {
      MODE            = "reshard"
      TOKEN_SCRIPT    = self.input.token_script
      API_URL         = self.input.hub_api_url
      ADMIN_PASS      = self.input.hub_admin_pass
      KUBECONFIG_PATH = self.input.kubeconfig_path
      KUBE_CONTEXT    = self.input.hub_context
      GITOPS_NS       = self.input.gitops_namespace
      ARGOCD_NAME     = self.input.argocd_name
    }
  }

  depends_on = [terraform_data.create_argocd_cluster_secret, helm_release.argocd_config]
}

# --- Post-apply check: Argo CD has rendered and compared everything (BACKLOG 9.1) ---
# An empty status means no controller shard processes the Application's destination
# cluster. Fails the apply after argocd_app_status_timeout_sec, naming what is missing. It
# also waits for what the ApplicationSets generate minutes after this resource starts (ROSA
# 2026-10-16: 13 of 40 existed when it ran; kind: 3 of 33): every Application and
# ApplicationSet that an Application lists in its resources, an Application for every mesh
# member, and one per mesh member from each of the repo's member ApplicationSets. And it
# fails when Argo CD cannot reach a cluster at its cluster-Secret URL or cannot render an
# Application (sync Unknown with a ComparisonError), quoting each error when first seen.
# A status from before the check never counts: a registration change does not make Argo CD
# compare again (kind, Argo CD 3.5: statuses stayed stale for minutes), so the check requests
# one refresh of every Application and waits until each has been compared again.
# Re-runs when the app-of-apps or any cluster Secret registration changes (a new spoke,
# mesh_member_count, a new URL), and on kubernetes when the argo-cd release does (a new
# controller replica count re-shards the clusters).

resource "terraform_data" "argocd_app_status_check" {
  count = local.gitops_enabled && var.gitops_app_repo_url != "" && var.argocd_app_status_timeout_sec > 0 ? 1 : 0

  triggers_replace = [
    helm_release.gitops_hub_app_of_apps[0].metadata.revision,
    [for r in terraform_data.argocd_controller_reshard : r.id],
    [for r in terraform_data.create_argocd_cluster_secret : r.id],
    [for r in helm_release.argocd : r.metadata.revision],
  ]

  input = {
    token_script     = local.token_script
    hub_api_url      = local.hub_api_url
    hub_admin_pass   = local.hub_admin_pass
    kubeconfig_path  = local.kubeconfig
    hub_context      = local.hub_cluster_key
    gitops_namespace = local.gitops_namespace
    argocd_name      = local.is_openshift ? var.gitops_argocd_cr_name : "argocd"
    timeout_sec      = tostring(var.argocd_app_status_timeout_sec)
    # Only mesh members get Applications (mesh_member_count can leave spokes out).
    expected_dests = join(" ", local.mesh_member_spoke_keys)
  }

  provisioner "local-exec" {
    command = "bash '${path.module}/../scripts/argocd-controller-reshard.sh'"
    environment = {
      MODE                   = "app-status"
      APP_STATUS_TIMEOUT_SEC = self.input.timeout_sec
      EXPECTED_DESTINATIONS  = self.input.expected_dests
      TOKEN_SCRIPT           = self.input.token_script
      API_URL                = self.input.hub_api_url
      ADMIN_PASS             = self.input.hub_admin_pass
      KUBECONFIG_PATH        = self.input.kubeconfig_path
      KUBE_CONTEXT           = self.input.hub_context
      GITOPS_NS              = self.input.gitops_namespace
      ARGOCD_NAME            = self.input.argocd_name
    }
  }

  depends_on = [
    helm_release.gitops_hub_app_of_apps,
    helm_release.mesh_wiring_verify_appset,
    kubernetes_manifest.placement_generator_configmap,
    terraform_data.argocd_controller_reshard,
    terraform_data.create_argocd_cluster_secret,
  ]
}

# --- openshift: Placement-generator ConfigMap (deferred until cluster secrets exist) ---
# ApplicationSets use this ConfigMap to discover spoke clusters via ACM PlacementDecisions.
# Created AFTER create_argocd_cluster_secret so that ApplicationSets only generate spoke
# apps once the cluster secrets exist with correct external API URLs.

resource "kubernetes_manifest" "placement_generator_configmap" {
  count    = local.gitops_enabled && local.is_openshift && length(local.spoke_cluster_keys) > 0 ? 1 : 0
  provider = kubernetes.hub

  manifest = {
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "acm-gitops-placement-generator"
      namespace = local.gitops_namespace
    }
    data = {
      apiVersion    = "cluster.open-cluster-management.io/v1beta1"
      kind          = "placementdecisions"
      statusListKey = "decisions"
      matchKey      = "clusterName"
    }
  }

  field_manager {
    name            = "terraform"
    force_conflicts = true
  }

  depends_on = [terraform_data.create_argocd_cluster_secret, terraform_data.argocd_controller_reshard]
}

# --- openshift, destroy-time cleanup: OSSM operator CSV on spoke clusters ---
# Argo CD's PreDelete hook may not run if apps are force-deleted, so we
# clean up the OSSM CSV directly on each spoke after Argo CD apps are gone.

resource "terraform_data" "spoke_ossm_csv_cleanup" {
  for_each = local.gitops_enabled && local.is_openshift ? local.spoke_cluster_keys : {}

  input = {
    token_script    = local.token_script
    spoke_api_url   = local.by_cluster[each.key].cluster_api_url
    admin_pass      = local.admin_password
    kubeconfig_path = local.kubeconfig
    spoke_context   = each.key
    sub_namespace   = "openshift-operators"
    sub_name        = "servicemeshoperator3"
    package_name    = "servicemeshoperator3"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash '${path.module}/../scripts/cleanup-olm-csv.sh'"
    environment = {
      TOKEN_SCRIPT    = self.input.token_script
      API_URL         = self.input.spoke_api_url
      ADMIN_PASS      = self.input.admin_pass
      KUBECONFIG_PATH = self.input.kubeconfig_path
      KUBE_CONTEXT    = self.input.spoke_context
      SUB_NAMESPACE   = self.input.sub_namespace
      SUB_NAME        = self.input.sub_name
      PACKAGE_NAME    = self.input.package_name
    }
  }
}

# --- Destroy-time cleanup: cascade-delete all Argo CD Applications ---

resource "terraform_data" "argocd_app_cleanup" {
  count = local.gitops_enabled && var.gitops_app_repo_url != "" ? 1 : 0

  input = {
    token_script     = local.token_script
    hub_api_url      = local.hub_api_url
    hub_admin_pass   = local.hub_admin_pass
    kubeconfig_path  = local.kubeconfig
    hub_context      = local.hub_cluster_key
    gitops_namespace = local.gitops_namespace
  }

  # Destroyed before these: the member apps are deleted while Argo CD can still reach the
  # spokes through their cluster Secrets.
  depends_on = [
    helm_release.gitops_hub_app_of_apps,
    terraform_data.spoke_ossm_csv_cleanup,
    terraform_data.spoke_access_cleanup,
  ]

  provisioner "local-exec" {
    when    = destroy
    command = "bash ${path.module}/../scripts/argocd-app-cleanup.sh"
    environment = {
      TOKEN_SCRIPT    = self.input.token_script
      API_URL         = self.input.hub_api_url
      ADMIN_PASS      = self.input.hub_admin_pass
      KUBECONFIG_PATH = self.input.kubeconfig_path
      KUBE_CONTEXT    = self.input.hub_context
      GITOPS_NS       = self.input.gitops_namespace
    }
  }
}

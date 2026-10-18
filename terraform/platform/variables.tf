# --------------------------------------------------------------------------
# Platform and cluster provider — what runs on the hub and how clusters are found
# --------------------------------------------------------------------------

variable "platform" {
  type        = string
  default     = null
  description = "'kubernetes': upstream Argo CD (argo-cd Helm chart) on the hub, the mesh members registered as Argo CD cluster Secrets, and the upstream cert-manager, External Secrets and Sail operator charts. 'openshift': OpenShift GitOps, ACM and the Red Hat operators (OLM). Null (the default) means openshift for cluster_provider = 'rosa', else kubernetes."

  validation {
    condition     = contains(["kubernetes", "openshift"], coalesce(var.platform, "kubernetes"))
    error_message = "platform must be kubernetes or openshift."
  }

  validation {
    condition     = !(var.cluster_provider == "rosa" && var.platform == "kubernetes")
    error_message = "cluster_provider = \"rosa\" needs platform = \"openshift\" (ROSA clusters run OpenShift)."
  }
}

variable "cluster_provider" {
  type        = string
  default     = "kubeconfig"
  description = "Cluster provisioning backend. 'kubeconfig' reads from a kubeconfig file with explicit context names (any Kubernetes or OpenShift clusters). 'rosa' reads from terraform_remote_state (rosa-hcp module)."

  validation {
    condition     = contains(["rosa", "kubeconfig"], var.cluster_provider)
    error_message = "cluster_provider must be one of: rosa, kubeconfig."
  }
}

variable "rosa_ingress_nlb" {
  type        = bool
  default     = true
  description = "rosa mode: give the ingress gateway Service an AWS NLB (service.beta.kubernetes.io/aws-load-balancer-type: nlb). Behind a Classic LB the gateway aborted HTTP requests (2026-10-14 ROSA window). The east-west gateway (mTLS passthrough) stays on a Classic LB. An existing CLB-backed Service must be deleted once (Argo CD recreates it) to switch."
}

variable "kubeconfig_path" {
  type        = string
  default     = ""
  description = "Path to a kubeconfig file (~ is expanded). Required when cluster_provider = 'kubeconfig'; $KUBECONFIG is not read."

  validation {
    condition     = var.cluster_provider != "kubeconfig" || var.kubeconfig_path != ""
    error_message = "kubeconfig_path is required when cluster_provider = \"kubeconfig\"."
  }
}

variable "hub_cluster_context" {
  type        = string
  default     = ""
  description = "Kubeconfig context of the management cluster: Argo CD, the mesh CA and External Secrets (ACM too on openshift). Never a mesh member. Required when cluster_provider = 'kubeconfig'."

  validation {
    condition     = var.cluster_provider != "kubeconfig" || var.hub_cluster_context != ""
    error_message = "hub_cluster_context is required when cluster_provider = \"kubeconfig\"."
  }
}

variable "spoke_cluster_contexts" {
  type        = list(string)
  default     = []
  description = "Kubeconfig contexts of the spoke (mesh member) clusters. Context names become the Argo CD cluster names (and ACM ManagedCluster names on openshift), so they must be DNS-1123 labels of at most 44 characters: the hub's per-member objects push-remote-secret-<ctx> and <ctx>-spoke-istio-system must fit in 63 (the network label <ctx>-network too), and the test suites' per-cluster Services (dataplane-server-<ctx>) allow at most 46 and need a letter first. Required when cluster_provider = 'kubeconfig'."

  validation {
    condition     = alltrue([for c in var.spoke_cluster_contexts : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", c)) && length(c) <= 44])
    error_message = "spoke_cluster_contexts must be DNS-1123 labels (lowercase letters, digits and '-') of at most 44 characters: they name the Argo CD clusters, the Istio networks and per-member objects such as push-remote-secret-<ctx> (63 at most). Rename a context with kubectl config rename-context (aws eks update-kubeconfig --alias for an EKS ARN)."
  }
}

variable "cluster_api_url_overrides" {
  type        = map(string)
  default     = {}
  description = "kubeconfig mode: the API URL a member is registered at, keyed by context, when the kubeconfig's server URL works only from this machine (kind and kubeadm write https://127.0.0.1:<port>). The URL goes into the member's Argo CD cluster Secret, and from there into the ESO SecretStores and the Istio remote secrets, so the hub's pods and every other member's istiod must reach it. On kind use https://<cluster>-control-plane:6443 (the kind Docker network). A hub entry changes nothing: only the ROSA token path reads the hub's URL."

  validation {
    condition     = alltrue([for k, v in var.cluster_api_url_overrides : startswith(v, "https://")])
    error_message = "cluster_api_url_overrides values must be https:// URLs."
  }

  validation {
    condition = alltrue([for k in keys(var.cluster_api_url_overrides) :
    var.cluster_provider == "kubeconfig" && contains(concat([var.hub_cluster_context], var.spoke_cluster_contexts), k)])
    error_message = "cluster_api_url_overrides keys must be hub_cluster_context or one of spoke_cluster_contexts (cluster_provider = \"kubeconfig\")."
  }
}

variable "spoke_service_account_namespace" {
  type        = string
  default     = "istio-scale-tests-access"
  description = "platform kubernetes: namespace of the ServiceAccount (gitops_managed_service_account_name) that Terraform creates on every spoke, bound to cluster-admin. Its token authenticates Argo CD, the ESO pushes and the Istio remote secrets to the spoke. Terraform creates the namespace when it does not exist (labelled istio-scale-tests/created-by) and deletes it on destroy only with that label. Not kube-system: its ServiceAccounts share the API server's workload-high priority level with the controllers the suites measure. Changing it moves the ServiceAccount on the next apply and removes the old one."

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.spoke_service_account_namespace)) && length(var.spoke_service_account_namespace) <= 63
    error_message = "spoke_service_account_namespace must be a namespace name (a DNS-1123 label of at most 63 characters)."
  }
}

# --------------------------------------------------------------------------
# ACM (Red Hat Advanced Cluster Management), platform openshift only
# --------------------------------------------------------------------------

variable "acm_channel" {
  type        = string
  default     = "release-2.17"
  description = "OLM subscription channel for the ACM operator. Align with openshift_version per RHACM support matrix."
}

variable "acm_install_operator" {
  type        = bool
  default     = true
  description = "Install the ACM operator (namespace, OperatorGroup, Subscription). Set false when ACM is already installed on the hub; the existing MultiClusterHub is then adopted."
}

variable "acm_namespace" {
  type        = string
  default     = "open-cluster-management"
  description = "Namespace for the ACM operator, MultiClusterHub, and ManagedCluster resources."
}

variable "acm_cluster_set" {
  type        = string
  default     = "istio-scale-tests"
  description = "ManagedClusterSet name applied to every spoke ManagedCluster. Must match Placement and ManagedClusterSetBinding in GitOps resources."
}

variable "acm_local_cluster_name" {
  type        = string
  default     = null
  description = "MultiClusterHub spec.localClusterName (the hub's own ManagedCluster name). Max 34 characters. Defaults to the hub cluster key when null; set it to the existing value (usually \"local-cluster\") when adopting an installed ACM."

  validation {
    condition     = var.acm_local_cluster_name == null || length(var.acm_local_cluster_name) <= 34
    error_message = "acm_local_cluster_name must be at most 34 characters (RHACM limit)."
  }
}

variable "acm_install_klusterletconfig" {
  type        = bool
  default     = true
  description = "Install the KlusterletConfig chart after the MultiClusterHub is running."
}

variable "acm_keep_managed_clusters_on_destroy" {
  type        = bool
  default     = false
  description = "Leave the spoke ManagedClusters registered on destroy (helm.sh/resource-policy: keep). Set true when the spokes were ACM-managed before Terraform adopted them."
}

# --------------------------------------------------------------------------
# Argo CD (upstream on kubernetes, OpenShift GitOps on openshift)
# --------------------------------------------------------------------------

variable "enable_gitops" {
  type        = bool
  default     = true
  description = "Install Argo CD on the hub and register the spokes with it (on openshift: OpenShift GitOps and the ACM GitOps wiring)."
}

variable "gitops_namespace" {
  type        = string
  default     = null
  description = "Argo CD namespace: Applications, the cluster Secrets and (openshift) the ACM Placement and ManagedClusterSetBinding. Null (the default) means argocd on kubernetes, openshift-gitops on openshift."
}

variable "gitops_install_operator" {
  type        = bool
  default     = true
  description = "Install Argo CD: the argo-cd Helm chart as release argocd (kubernetes) or the OpenShift GitOps operator Subscription (openshift). Set false when it is already installed on the hub; on kubernetes it must then use the upstream resource names (argocd-application-controller, argocd-applicationset-controller) in gitops_namespace."
}

variable "argocd_chart_repository" {
  type        = string
  default     = "https://argoproj.github.io/argo-helm"
  description = "platform kubernetes: Helm repository of the argo-cd chart (a mirror works)."
}

# Keep in sync: terraform.tfvars.example, and charts/argocd-config/values.yaml restates this
# chart's resource exclusions.
variable "argocd_chart_version" {
  type        = string
  default     = "10.9.6"
  description = "platform kubernetes: argo-cd chart version (10.9.6 is Argo CD v3.5.3)."
}

variable "argocd_helm_values" {
  type        = any
  default     = {}
  description = "platform kubernetes: extra values for the argo-cd chart, in its own schema (e.g. smaller controller/repoServer/server resources on a small hub). Helm deep-merges them over the values Terraform derives from charts/argocd-config/values.yaml."
}

variable "gitops_operator_namespace" {
  type        = string
  default     = "openshift-operators"
  description = "platform openshift: namespace for the OpenShift GitOps operator OLM Subscription."
}

variable "gitops_operator_channel" {
  type        = string
  default     = "gitops-1.22"
  description = "platform openshift: OLM subscription channel for the OpenShift GitOps operator."
}

variable "gitops_argocd_cr_name" {
  type        = string
  default     = "openshift-gitops"
  description = "platform openshift: name of the ArgoCD custom resource created by the GitOps operator on the hub."
}

variable "gitops_app_repo_url" {
  type        = string
  default     = ""
  description = "Git repo URL for Argo CD hub Application sources. When empty, the hub app-of-apps chart is skipped."
}

variable "gitops_app_repo_revision" {
  type        = string
  default     = "main"
  description = "Branch/tag/commit for hub Argo CD Applications."
}

variable "gitops_app_overrides" {
  type        = any
  default     = {}
  description = "Per-app overrides for the hub app-of-apps, keyed by child Application name (charts/gitops-hub-apps values.yaml). Each entry takes enabled (false skips the app, e.g. an operator already installed on the hub) and/or values (the Application's helm.valuesObject; for ApplicationSet apps put member-chart values under template.source.helm.valuesObject)."
}

variable "gitops_app_repo_username" {
  type        = string
  default     = "git"
  description = "HTTPS username for the Argo CD repository Secret. Defaults to 'git' (standard for PAT/token auth with GitHub/GitLab)."
}

variable "gitops_app_repo_password" {
  type        = string
  sensitive   = true
  default     = ""
  description = "HTTPS password or PAT for the Argo CD repository Secret. Required for private repos. Mutually exclusive with gitops_app_repo_ssh_private_key."
}

variable "gitops_app_repo_ssh_private_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "SSH private key for the Argo CD repository Secret. Use with an SSH clone URL in gitops_app_repo_url. Mutually exclusive with gitops_app_repo_password."
}

variable "gitops_app_repo_credentials_secret_name" {
  type        = string
  default     = "gitops-hub-app-repo"
  description = "Name of the Argo CD repository credentials Secret (label argocd.argoproj.io/secret-type=repository)."
}

variable "argocd_config_values" {
  type        = any
  default     = {}
  description = "platform openshift: extra values for charts/argocd-config, the ArgoCD CR (e.g. smaller argocd.controller/repo/server resources on a small hub). The chart defaults are sized for the 20-cluster campaign. On kubernetes use argocd_helm_values."
}

variable "gitops_rhacm_appset_any_namespace" {
  type        = bool
  default     = true
  description = "platform openshift: enable RHACM ApplicationSet-in-any-namespace: ArgoCD applicationSet env + ClusterRole/Binding for the applicationset-controller."
}

variable "argocd_clusters_per_shard" {
  type        = number
  default     = 3
  description = "ArgoCD controller sharding: max clusters per shard (clustersPerShard). Terraform uses this to compute minShards = ceil((spoke_count + 1) / argocd_clusters_per_shard) so the statefulset always has enough replicas from the start and no Application gets an empty controllerNamespace. On kubernetes minShards is the controller's replica count. For large 3-node hubs, raise this value to keep controller shard count within hub capacity."

  validation {
    condition     = var.argocd_clusters_per_shard > 0 && var.argocd_clusters_per_shard == floor(var.argocd_clusters_per_shard)
    error_message = "argocd_clusters_per_shard must be a positive whole number."
  }
}

variable "argocd_restart_controller_after_cluster_secrets" {
  type        = bool
  default     = true
  description = "platform openshift: after the Argo CD cluster secrets exist, wait for the GitOps operator's dynamic-scaling reconcile of the application controller to settle, then restart the controller pods once so every cluster is assigned a shard (terraform/scripts/argocd-controller-reshard.sh). On kubernetes the controllers run a fixed replica count with round-robin sharding, on which every replica agrees, so it is skipped."
}

variable "argocd_app_status_timeout_sec" {
  type        = number
  default     = 900
  description = "Post-apply check: fail when, after this many seconds, an Argo CD Application still has an empty sync or health status (no controller shard owns its destination cluster), a mesh member still has no Application (its ApplicationSets generated none), or Argo CD still cannot reach a cluster at its cluster-Secret URL (sync Unknown with a live-state ComparisonError), or has not compared an Application again since the check started (it requests one refresh of every Application, so a status from before the apply never counts). 0 disables the check."

  validation {
    condition     = var.argocd_app_status_timeout_sec == 0 || var.argocd_app_status_timeout_sec >= 600
    error_message = "argocd_app_status_timeout_sec must be 0 (disabled) or at least 600: the member Applications can take several minutes to get their first status."
  }
}

variable "argocd_max_shards" {
  type        = number
  default     = 20
  description = "platform openshift: ArgoCD controller sharding maxShards. Terraform renders max(var.argocd_max_shards, computed minShards) so large fleets do not produce minShards > maxShards. No effect on kubernetes, where the controller replica count is the computed minShards."

  validation {
    condition     = var.argocd_max_shards > 0 && var.argocd_max_shards == floor(var.argocd_max_shards)
    error_message = "argocd_max_shards must be a positive whole number."
  }
}

variable "gitops_applicationset_source_namespaces" {
  type        = list(string)
  default     = ["open-cluster-management-global-set"]
  description = "platform openshift: namespaces merged into ArgoCD spec.applicationSet.sourceNamespaces."
}

variable "gitops_managed_service_account_name" {
  type        = string
  default     = "argocd-gitops"
  description = "The ServiceAccount whose token authenticates the Terraform-owned Argo CD cluster Secret to each spoke: on kubernetes created by Terraform in spoke_service_account_namespace, on openshift the ACM ManagedServiceAccount (acm-managed-cluster chart, rotated token). The secret name follows <spoke>-<this>-cluster-secret, which the hub-kubeconfig-from-argosecret ESO chart also reads."
}

# --------------------------------------------------------------------------
# Incremental mesh deployment
# --------------------------------------------------------------------------

variable "mesh_member_count" {
  type        = number
  default     = 0
  description = "Number of spoke clusters to label as Istio mesh members (0 = all spokes): the istio-mesh-member label on the Argo CD cluster Secret (on openshift, on the ManagedCluster). Spokes are labeled in sorted key order (e.g. istio-002 first when hub is istio-001)."

  validation {
    condition     = var.mesh_member_count >= 0
    error_message = "mesh_member_count must be >= 0 (0 = all spokes)."
  }
}

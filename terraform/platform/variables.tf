# --------------------------------------------------------------------------
# Cluster provider — controls how the platform module discovers clusters
# --------------------------------------------------------------------------

variable "cluster_provider" {
  type        = string
  default     = "rosa"
  description = "Cluster provisioning backend. 'rosa' reads from terraform_remote_state (rosa-hcp module). 'kubeconfig' reads from a kubeconfig file with explicit context names."

  validation {
    condition     = contains(["rosa", "kubeconfig"], var.cluster_provider)
    error_message = "cluster_provider must be one of: rosa, kubeconfig."
  }
}

variable "kubeconfig_path" {
  type        = string
  default     = ""
  description = "Absolute path to a kubeconfig file. Required when cluster_provider = 'kubeconfig'."
}

variable "hub_cluster_context" {
  type        = string
  default     = ""
  description = "Kubeconfig context name for the ACM hub cluster. Required when cluster_provider = 'kubeconfig'."
}

variable "spoke_cluster_contexts" {
  type        = list(string)
  default     = []
  description = "Kubeconfig context names for spoke clusters. Required when cluster_provider = 'kubeconfig'."
}

# --------------------------------------------------------------------------
# ACM (Red Hat Advanced Cluster Management)
# --------------------------------------------------------------------------

variable "acm_channel" {
  type        = string
  default     = "release-2.16"
  description = "OLM subscription channel for the ACM operator. Align with openshift_version per RHACM support matrix."
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
  description = "MultiClusterHub spec.localClusterName and GitOpsCluster argoServer.cluster. Max 34 characters. Defaults to the first Terraform cluster key when null."

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

# --------------------------------------------------------------------------
# OpenShift GitOps / Argo CD
# --------------------------------------------------------------------------

variable "enable_gitops" {
  type        = bool
  default     = true
  description = "Install OpenShift GitOps and configure ACM GitOps wiring."
}

variable "gitops_namespace" {
  type        = string
  default     = "openshift-gitops"
  description = "Operand namespace for Argo CD and ACM GitOps CRs (GitOpsCluster, Placement, ManagedClusterSetBinding)."
}

variable "gitops_operator_namespace" {
  type        = string
  default     = "openshift-operators"
  description = "Namespace for the OpenShift GitOps operator OLM Subscription."
}

variable "gitops_operator_channel" {
  type        = string
  default     = "gitops-1.20"
  description = "OLM subscription channel for the OpenShift GitOps operator."
}

variable "gitops_argocd_cr_name" {
  type        = string
  default     = "openshift-gitops"
  description = "Name of the ArgoCD custom resource created by the GitOps operator on the hub."
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

variable "gitops_rhacm_appset_any_namespace" {
  type        = bool
  default     = true
  description = "Enable RHACM ApplicationSet-in-any-namespace: ArgoCD applicationSet env + ClusterRole/Binding for the applicationset-controller."
}

variable "argocd_clusters_per_shard" {
  type        = number
  default     = 3
  description = "ArgoCD controller sharding: max clusters per shard (clustersPerShard). Terraform uses this to compute minShards = ceil((spoke_count + 1) / argocd_clusters_per_shard) so the statefulset always has enough replicas from the start and no Application gets an empty controllerNamespace. For large 3-node hubs, raise this value to keep controller shard count within hub capacity."

  validation {
    condition     = var.argocd_clusters_per_shard > 0 && var.argocd_clusters_per_shard == floor(var.argocd_clusters_per_shard)
    error_message = "argocd_clusters_per_shard must be a positive whole number."
  }
}

variable "argocd_max_shards" {
  type        = number
  default     = 20
  description = "ArgoCD controller sharding maxShards. Terraform renders max(var.argocd_max_shards, computed minShards) so large fleets do not produce minShards > maxShards."

  validation {
    condition     = var.argocd_max_shards > 0 && var.argocd_max_shards == floor(var.argocd_max_shards)
    error_message = "argocd_max_shards must be a positive whole number."
  }
}

variable "gitops_applicationset_source_namespaces" {
  type        = list(string)
  default     = ["open-cluster-management-global-set"]
  description = "Namespaces merged into ArgoCD spec.applicationSet.sourceNamespaces."
}

variable "gitops_managed_service_account_name" {
  type        = string
  default     = "argocd-gitops"
  description = "ManagedServiceAccount name created per spoke (acm-managed-cluster chart). Its rotated token authenticates the Terraform-owned Argo CD cluster Secret to the spoke. The secret name follows <spoke>-<this>-cluster-secret, which the hub-kubeconfig-from-argosecret ESO chart also reads."
}

# --------------------------------------------------------------------------
# Incremental mesh deployment
# --------------------------------------------------------------------------

variable "mesh_member_count" {
  type        = number
  default     = 0
  description = "Number of spoke clusters to label as Istio mesh members (0 = all spokes). Spokes are labeled in sorted key order (e.g. istio-002 first when hub is istio-001)."

  validation {
    condition     = var.mesh_member_count >= 0
    error_message = "mesh_member_count must be >= 0 (0 = all spokes)."
  }
}

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
  default     = "gitops-1.14"
  description = "OLM subscription channel for the OpenShift GitOps operator."
}

variable "gitops_argocd_cr_name" {
  type        = string
  default     = "openshift-gitops"
  description = "Name of the ArgoCD custom resource created by the GitOps operator on the hub."
}

variable "argocd_resource_limits_cpu" {
  type        = string
  default     = "4"
  description = "CPU limit for ArgoCD components (controller, repo-server, server, applicationSet)."
}

variable "argocd_resource_limits_memory" {
  type        = string
  default     = "8Gi"
  description = "Memory limit for ArgoCD components (controller, repo-server, server, applicationSet)."
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

variable "gitops_applicationset_source_namespaces" {
  type        = list(string)
  default     = ["open-cluster-management-global-set"]
  description = "Namespaces merged into ArgoCD spec.applicationSet.sourceNamespaces."
}

variable "gitops_addon_enabled" {
  type        = bool
  default     = true
  description = "GitOpsCluster spec.gitopsAddon.enabled — enables the gitops-addon on spoke ManagedClusters."
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

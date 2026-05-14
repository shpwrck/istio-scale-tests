# Helm Charts

All mesh and platform resources are deployed as Helm charts, synced by Argo CD ApplicationSets via ACM Placement. Terraform installs the platform charts directly; the mesh charts are deployed through the hub app-of-apps.

## Deployment order

The app-of-apps syncs child Applications with sync-wave ordering:

| Wave | Chart | Purpose |
| --- | --- | --- |
| 4 | `spoke-istio-namespaces/` | istio-system + istio-cni namespaces on each spoke |
| 8 | `spoke-ossm-operator/` | Sail operator (OLM) on each spoke |
| 10 | `cert-manager-operator/` | cert-manager operator (OLM) on the hub |
| 12 | `external-secrets-operator/` | External Secrets operator on each spoke |
| 13 | `hub-mesh-ca/` | Root CA + ClusterIssuer on the hub |
| 15 | `hub-mesh-ca-intermediate/` | Per-cluster intermediate CA on the hub |
| 16 | `hub-kubeconfig-from-argosecret/` | Kubeconfig extraction from Argo cluster secrets |
| 19 | `hub-mesh-push-secrets/` | Push cacerts + kubeconfigs + remote secrets to spokes |
| 21 | `spoke-ossm/` | Istio + IstioCNI CRs per spoke |
| 24 | `spoke-ingress-gateway/` | North-south ingress gateway per spoke |
| 27 | `spoke-east-west-gateway/` | East-west gateway + cross-network Gateway CR per spoke |

## All charts

| Chart | Description |
| --- | --- |
| `acm-gitops-cluster/` | GitOpsCluster CR binding ACM Placement to an Argo CD instance |
| `acm-klusterlet-config/` | KlusterletConfig for RHACM hub |
| `acm-managed-cluster/` | Single RHACM ManagedCluster (one release per spoke) |
| `acm-multicluster-hub/` | MultiClusterHub CR for RHACM |
| `acm-openshift-gitops-resources/` | ManagedClusterSetBinding, Placement, and GitOpsCluster for hub GitOps |
| `acm-operator/` | ACM operator OLM Subscription |
| `argocd-config/` | ArgoCD custom resource configuration |
| `cert-manager-operator/` | cert-manager operator OLM Subscription (hub) |
| `external-secrets-operator/` | External Secrets operator OLM Subscription (per spoke) |
| `gitops-hub-app-of-apps/` | Root app-of-apps: directory sync of child Applications |
| `gitops-hub-apps/` | Child Application manifests synced by the root app-of-apps |
| `gitops-hub-ocm-placement-appset/` | Reusable ApplicationSet for ACM Placement with preset value files |
| `hub-kubeconfig-from-argosecret/` | ExternalSecret extracting kubeconfigs from Argo cluster secrets |
| `hub-mesh-ca/` | cert-manager root CA + ClusterIssuer on the hub |
| `hub-mesh-ca-intermediate/` | Per-cluster intermediate CA Certificate |
| `hub-mesh-push-secrets/` | PushSecrets for cacerts, kubeconfigs, and Istio remote secrets to spokes |
| `istiod-monitor/` | ServiceMonitor + PrometheusRule for istiod pilot metrics |
| `mesh-verify/` | Echo workload for cross-cluster mesh verification |
| `openshift-gitops-operator/` | OpenShift GitOps operator OLM Subscription (hub) |
| `propagation-test/` | Watcher and canary workloads for xDS propagation latency testing |
| `spoke-east-west-gateway/` | East-west gateway + cross-network Gateway CR per spoke |
| `spoke-ingress-gateway/` | North-south ingress gateway (LoadBalancer) per spoke |
| `spoke-ossm/` | Istio + IstioCNI CRs per spoke (multi-primary, multi-network) |
| `spoke-istio-namespaces/` | istio-system and istio-cni namespaces per spoke |
| `spoke-ossm-operator/` | Sail operator OLM Subscription per spoke |

## Standalone files

- `mesh-verify-appset.yaml` — standalone ApplicationSet for deploying the mesh-verify chart (not part of the root app-of-apps). See [Verify the mesh install](../README.md#verify-the-mesh-install).

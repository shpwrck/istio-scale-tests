# Helm charts

Terraform installs the platform charts on the ACM hub. The root Application
`hub-gitops-root` (`gitops-hub-app-of-apps/`) renders `gitops-hub-apps/`, whose child
Applications deploy the mesh. Spoke charts reach every mesh member through ApplicationSets
built from `gitops-hub-ocm-placement-appset/`.

## Sync waves (child Applications of `hub-gitops-root`)

| Wave | Application | Chart | Runs on |
| --- | --- | --- | --- |
| 0 | `hub-cert-manager-operator` | `cert-manager-operator/` | hub |
| 4 | `spoke-istio-namespaces-appset` | `spoke-istio-namespaces/` | each mesh member |
| 5 | `hub-mesh-ca` | `hub-mesh-ca/` | hub |
| 8 | `spoke-ossm-operator-appset` | `spoke-ossm-operator/` | each mesh member |
| 12 | `hub-external-secrets-operator-appset` | `external-secrets-operator/` | hub |
| 15 | `hub-mesh-ca-intermediate-appset` | `hub-mesh-ca-intermediate/` | hub, one per member |
| 18 | `hub-kubeconfig-from-argosecret-appset` | `hub-kubeconfig-from-argosecret/` | hub, one per member |
| 19 | `hub-mesh-push-secrets-appset` | `hub-mesh-push-secrets/` | hub, one per member |
| 21 | `spoke-ossm-appset` | `spoke-ossm/` | each mesh member |
| 24 | `spoke-ingress-gateway-appset` | `spoke-ingress-gateway/` | each mesh member |
| 27 | `spoke-east-west-gateway-appset` | `spoke-east-west-gateway/` | each mesh member |

Waves order creation only; they do not wait for a child to be healthy. The child and the
generated per-cluster Applications retry a failed sync (10 tries, backoff up to 5 min), so
one that needs a CRD from an earlier wave converges once that CRD exists.

Skip a child Application with `apps.<name>.enabled=false` (see `gitops-hub-apps/`).

## All charts

| Chart | Installed by | Purpose |
| --- | --- | --- |
| `acm-klusterlet-config/` | Terraform | KlusterletConfig `global` |
| `acm-managed-cluster/` | Terraform | One ManagedCluster (+ ManagedServiceAccount) per spoke |
| `acm-multicluster-hub/` | Terraform | MultiClusterHub CR |
| `acm-openshift-gitops-resources/` | Terraform | ManagedClusterSet, binding and the mesh Placement |
| `argocd-config/` | Terraform | ArgoCD CR tuning (sharding, resources) |
| `gitops-hub-app-of-apps/` | Terraform | Root Application `hub-gitops-root` |
| `gitops-hub-apps/` | app-of-apps | Child Applications (table above) |
| `gitops-hub-ocm-placement-appset/` | app-of-apps, Terraform | Placement-driven ApplicationSet with one preset per chart |
| `cert-manager-operator/` | app-of-apps | cert-manager operator (OLM), hub |
| `external-secrets-operator/` | app-of-apps | External Secrets operator (OLM), hub only |
| `hub-mesh-ca/` | app-of-apps | Mesh root CA chain (cert-manager) |
| `hub-mesh-ca-intermediate/` | app-of-apps | Intermediate CA per mesh member |
| `hub-kubeconfig-from-argosecret/` | app-of-apps | Hub-side kubeconfig Secret per member from the Argo cluster Secret |
| `hub-mesh-push-secrets/` | app-of-apps | PushSecrets: cacerts and Istio remote secrets to spoke `istio-system` |
| `spoke-istio-namespaces/` | app-of-apps | `istio-system` and `istio-cni` namespaces |
| `spoke-ossm-operator/` | app-of-apps | OSSM 3 (Sail) operator (OLM) |
| `spoke-ossm/` | app-of-apps | Istio + IstioCNI CRs (multi-primary, multi-network) |
| `spoke-ingress-gateway/` | app-of-apps | North-south ingress gateway |
| `spoke-east-west-gateway/` | app-of-apps | East-west gateway + cross-network Gateway |
| `mesh-wiring-verify/` | Terraform (`values-mesh-wiring-verify.yaml`) | Per-member health gate for remote secrets and istiod sync |
| `mesh-verify/` | `mesh-verify-appset.yaml` | Cross-cluster echo workload |
| `mesh-verify-gateway-api/` | `mesh-verify-gateway-api-appset.yaml` | Gateway API ingress check: HTTPRoutes on every member, echo on one ([tests/gateway-api](../tests/gateway-api/README.md)) |
| `istiod-monitor/` | manual `helm install` | ServiceMonitor + PrometheusRule for istiod |

`mesh-verify-appset.yaml` and `mesh-verify-gateway-api-appset.yaml` are standalone Applications
(`oc apply -f` / `oc delete -f`); set both repo URLs and both revisions to your fork/branch, and in
the second also the workload member's ManagedCluster name (`workloadCluster`). See
[Verify](../README.md#verify).

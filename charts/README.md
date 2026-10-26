# Helm charts

Terraform installs the platform charts on the hub. The root Application
`hub-gitops-root` (`gitops-hub-app-of-apps/`) renders `gitops-hub-apps/`, whose child
Applications deploy the mesh. Spoke charts reach every mesh member through ApplicationSets
built from `gitops-hub-ocm-placement-appset/`. Its cluster generator follows the platform: on
`kubernetes` (the default) it selects the Argo CD cluster Secrets labeled
`istio-mesh-member=true` (`platform-kubernetes.yaml`), on `openshift` the ACM Placement's
decisions (`platform-openshift.yaml`).

Where a chart differs by platform, the Kubernetes source comes first and the OpenShift one (OLM)
follows in parentheses.

## Sync waves (child Applications of `hub-gitops-root`)

| Wave | Application | Chart | Runs on |
| --- | --- | --- | --- |
| 0 | `hub-cert-manager-operator` | upstream `cert-manager` chart (`cert-manager-operator/`) | hub |
| 4 | `spoke-istio-namespaces-appset` | `spoke-istio-namespaces/` | each mesh member |
| 5 | `hub-mesh-ca` | `hub-mesh-ca/` | hub |
| 8 | `spoke-ossm-operator-appset` | upstream `sail-operator` chart (`spoke-ossm-operator/`: OSSM 3) | each mesh member |
| 12 | `hub-external-secrets-operator-appset` | upstream `external-secrets` chart (`external-secrets-operator/`) | hub |
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
| `acm-klusterlet-config/` | Terraform (openshift) | KlusterletConfig `global` |
| `acm-managed-cluster/` | Terraform (openshift) | One ManagedCluster (+ ManagedServiceAccount) per spoke |
| `acm-multicluster-hub/` | Terraform (openshift) | MultiClusterHub CR |
| `acm-openshift-gitops-resources/` | Terraform (openshift) | ManagedClusterSet, binding and the mesh Placement |
| `argocd-config/` | Terraform | Argo CD tuning (sharding, resources): its `values.yaml` feeds the `argo-cd` chart on kubernetes and the ArgoCD CR on openshift |
| `gitops-hub-app-of-apps/` | Terraform | Root Application `hub-gitops-root` |
| `gitops-hub-apps/` | app-of-apps | Child Applications (table above) |
| `gitops-hub-ocm-placement-appset/` | app-of-apps, Terraform | ApplicationSet over the mesh members, one preset per chart (`values-*.yaml`) and one per platform (`platform-*.yaml`) |
| `cert-manager-operator/` | app-of-apps (openshift) | cert-manager operator (OLM), hub |
| `external-secrets-operator/` | app-of-apps (openshift) | External Secrets operator (OLM), hub only |
| `hub-mesh-ca/` | app-of-apps | Mesh root CA chain (cert-manager) |
| `hub-mesh-ca-intermediate/` | app-of-apps | Intermediate CA per mesh member |
| `hub-kubeconfig-from-argosecret/` | app-of-apps | Hub-side kubeconfig Secret per member from the Argo cluster Secret |
| `hub-mesh-push-secrets/` | app-of-apps | PushSecrets: cacerts and Istio remote secrets to spoke `istio-system` |
| `spoke-istio-namespaces/` | app-of-apps | `istio-system` and `istio-cni` namespaces |
| `spoke-ossm-operator/` | app-of-apps (openshift) | OSSM 3 (Sail) operator (OLM); on kubernetes the upstream Sail operator chart (`values-sail-operator.yaml`) |
| `spoke-ossm/` | app-of-apps | Istio + IstioCNI CRs (multi-primary, multi-network) |
| `spoke-ingress-gateway/` | app-of-apps | North-south ingress gateway |
| `spoke-east-west-gateway/` | app-of-apps | East-west gateway + cross-network Gateway |
| `mesh-wiring-verify/` | Terraform (`values-mesh-wiring-verify.yaml`) | Per-member health gate for remote secrets and istiod sync, each member by name |
| `mesh-verify/` | `mesh-verify-appset.yaml` | Cross-cluster echo workload |
| `mesh-verify-gateway-api/` | `mesh-verify-gateway-api-appset.yaml` | Gateway API ingress check: HTTPRoutes on every member, echo on one ([misc_tests/gateway-api](../misc_tests/gateway-api/README.md)) |
| `istiod-monitor/` | manual `helm install` | ServiceMonitor + PrometheusRule for istiod |

`mesh-verify-appset.yaml` and `mesh-verify-gateway-api-appset.yaml` are standalone Applications
(`kubectl apply -f -` / `kubectl delete -f -`). Both keep `<repo-url>`, `<revision>`, `<platform>`
and `<gitops-namespace>` placeholders in git: fill them in with `sed` on the way to the hub, from
the hub's `hub-gitops-root` Application, so the check deploys the same repo and revision as the mesh
([Verify](../README.md#2-check-the-mesh)). The second also needs the workload member's cluster name
(`workloadCluster`) in its `<workload-cluster>` placeholder, so the name stays out of git
([misc_tests/gateway-api](../misc_tests/gateway-api/README.md#deploy)).

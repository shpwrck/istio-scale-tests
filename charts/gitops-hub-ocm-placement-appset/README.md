# gitops-hub-ocm-placement-appset

One Argo CD ApplicationSet over the mesh members (or the hub), built from one preset per chart
(`values-*.yaml`) and one overlay per platform (`platform-*.yaml`, listed after the preset).
`values.yaml` holds the shared defaults, which are the Kubernetes ones; each preset and overlay
sets only what differs.

| Platform | Generator | Mesh members |
| --- | --- | --- |
| `kubernetes` (`platform-kubernetes.yaml`, empty) | `clusters` | the Argo CD cluster Secrets that match `clusters.selector`: `istio-mesh-member=true`, which `terraform/platform` sets on each member's Secret |
| `openshift` (`platform-openshift.yaml`) | `clusterDecisionResource` | the ACM Placement `acm-openshift-gitops-placement` (ConfigMap created by Terraform). The overlay also sets the OpenShift GitOps namespace and ServiceAccounts and adds each member chart's `values-openshift.yaml` (`memberValueFiles`) |

| Preset | Deploys | Destination |
| --- | --- | --- |
| `values-istio-namespaces.yaml` | `charts/spoke-istio-namespaces` | each mesh member |
| `values-sail-operator.yaml` | the upstream Sail operator chart (kubernetes) | each mesh member |
| `values-ossm-operator.yaml` | `charts/spoke-ossm-operator`: OSSM 3 through OLM (openshift) | each mesh member |
| `values-external-secrets.yaml` | the upstream External Secrets chart (kubernetes) | hub only (`in-cluster`) |
| `values-external-secrets-olm.yaml` | `charts/external-secrets-operator`: OLM (openshift) | hub only (`in-cluster`) |
| `values-mesh-ca-intermediate.yaml` | `charts/hub-mesh-ca-intermediate` | hub, one app per member |
| `values-kubeconfig-from-argosecret.yaml` | `charts/hub-kubeconfig-from-argosecret` | hub, one app per member |
| `values-mesh-push-secrets.yaml` | `charts/hub-mesh-push-secrets` | hub, one app per member |
| `values-ossm.yaml` | `charts/spoke-ossm` | each mesh member |
| `values-ingress-gateway.yaml` | `charts/spoke-ingress-gateway` | each mesh member |
| `values-east-west-gateway.yaml` | `charts/spoke-east-west-gateway` | each mesh member |
| `values-mesh-wiring-verify.yaml` | `charts/mesh-wiring-verify` (installed by Terraform, which adds `expectedMembers` and `expectedClusters`) | each mesh member |
| `values-mesh-verify.yaml` | `charts/mesh-verify` (via `charts/mesh-verify-appset.yaml`) | each mesh member |
| `values-mesh-verify-gateway-api.yaml` | `charts/mesh-verify-gateway-api` (via `charts/mesh-verify-gateway-api-appset.yaml`; `valuesObject.workloadCluster`) | each mesh member |

`destination.mode: clusterName` targets each member cluster by name;
`inClusterServer` targets the hub API and passes `clusterName`/`clusterServer` to the
child chart. Write a member's name as `{{clusterName}}`, in `template.source.helm.parameters`
or in a string of `template.source.helm.valuesObject` (the gate's preset passes its `clusterName`
so): the template rewrites it to `{{name}}` for the `clusters` generator, and Argo CD fills it in
for each member. Static values go in `template.source.helm.valuesObject`.

```bash
helm template x charts/gitops-hub-ocm-placement-appset \
  -f charts/gitops-hub-ocm-placement-appset/values-ossm.yaml \
  -f charts/gitops-hub-ocm-placement-appset/platform-kubernetes.yaml \
  --set repo.url=https://github.com/<org>/istio-scale-tests.git --set repo.revision=main
```

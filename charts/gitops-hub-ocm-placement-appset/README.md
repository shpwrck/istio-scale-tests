# gitops-hub-ocm-placement-appset

One Argo CD ApplicationSet driven by the ACM Placement `acm-openshift-gitops-placement`
(`clusterDecisionResource` generator, ConfigMap created by Terraform). `values.yaml` holds
the shared defaults; each preset sets only what differs.

| Preset | Deploys | Destination |
| --- | --- | --- |
| `values-istio-namespaces.yaml` | `charts/spoke-istio-namespaces` | each mesh member |
| `values-ossm-operator.yaml` | `charts/spoke-ossm-operator` | each mesh member |
| `values-external-secrets.yaml` | `charts/external-secrets-operator` | hub only (`in-cluster`) |
| `values-mesh-ca-intermediate.yaml` | `charts/hub-mesh-ca-intermediate` | hub, one app per member |
| `values-kubeconfig-from-argosecret.yaml` | `charts/hub-kubeconfig-from-argosecret` | hub, one app per member |
| `values-mesh-push-secrets.yaml` | `charts/hub-mesh-push-secrets` | hub, one app per member |
| `values-ossm.yaml` | `charts/spoke-ossm` | each mesh member |
| `values-ingress-gateway.yaml` | `charts/spoke-ingress-gateway` | each mesh member |
| `values-east-west-gateway.yaml` | `charts/spoke-east-west-gateway` | each mesh member |
| `values-mesh-wiring-verify.yaml` | `charts/mesh-wiring-verify` (installed by Terraform) | each mesh member |
| `values-mesh-verify.yaml` | `charts/mesh-verify` (via `charts/mesh-verify-appset.yaml`) | each mesh member |

`destination.mode: clusterName` targets each Placement cluster by name;
`inClusterServer` targets the hub API and passes `clusterName`/`clusterServer` to the
child chart. Put generator placeholders such as `{{clusterName}}` in
`template.source.helm.parameters`; put static values in `template.source.helm.valuesObject`.

```bash
helm template x charts/gitops-hub-ocm-placement-appset \
  -f charts/gitops-hub-ocm-placement-appset/values-ossm.yaml \
  --set repo.url=https://github.com/<org>/istio-scale-tests.git --set repo.revision=main
```

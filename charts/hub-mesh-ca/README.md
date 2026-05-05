# hub-mesh-ca

Helm chart for a cert-manager PKI stack on the hub: self-signed bootstrap `ClusterIssuer`, long-lived root CA `Certificate`, CA `ClusterIssuer` backed by the root secret, and one intermediate CA `Certificate` per spoke cluster.

Prerequisites: cert-manager Operator installed and healthy; operand namespace `cert-manager` (default) exists.

## Argo CD RBAC (default)

When **`rbac.enabled`** is true (default), the chart installs a **Role** and **RoleBinding** in **`namespace`** (`cert-manager` by default) so the OpenShift GitOps application controller service account can manage **`certificates.cert-manager.io`** and **`Secrets`** there. A **ClusterRole** and **ClusterRoleBinding** grant **`clusterissuers.cert-manager.io`**. Targets **`rbac.argocd.namespace`** / **`rbac.argocd.serviceAccountName`** (OpenShift GitOps defaults: `openshift-gitops`, `openshift-gitops-argocd-application-controller`). Override for upstream Argo CD (`argocd`, `argocd-application-controller`). Hooks run before other manifests so permissions exist before Certificate sync.

Disable with **`rbac.enabled: false`** if you manage this RBAC outside the chart (for example in `platform-setup`).

## Intermediate CAs: Placement (default)

With `intermediates.source: placement` (default), the chart uses Helm `lookup` on the **PlacementDecision** that matches **`global.placement`** — same namespace/name convention as `charts/acm-openshift-gitops-resources` (`Placement` `acm-openshift-gitops-placement` in `openshift-gitops`). Each entry in `status.decisions[].clusterName` becomes one intermediate (`mesh-intermediate-<clusterName>`).

Override **`global.placement.placementDecisionName`** if your hub uses a different `PlacementDecision` metadata name (`oc get placementdecision -n openshift-gitops`). Defaults to **`global.placement.name`**.

Optional **`intermediates.clusterOverrides`** keys off ManagedCluster name for `commonName`, `duration`, `secretName`, or `privateKey`.

`helm template` without a live kube client leaves `lookup` empty — no intermediate `Certificate` manifests until you render against the hub (`helm template ... --kubeconfig` / install on cluster).

## Intermediate CAs: static list

Set **`intermediates.source: static`** and populate **`intermediates.clusters`** (each entry needs **`key`**) as before.

## Install

```bash
helm upgrade --install hub-mesh-ca ./charts/hub-mesh-ca \
  --kubeconfig "$HUB_KUBECONFIG" \
  -n openshift-gitops
```

## Relationship to `istio-setup/001-ossm-mc-cacerts.sh`

This chart issues TLS secrets in cert-manager’s shape. To feed Istio `cacerts`, export PEMs from each issued `Secret` into `ca-cert.pem` / `ca-key.pem` / `cert-chain.pem` / `root-cert.pem`, or use Istio-CSR / upstream integration. See `manifests/cert-manager-samples/README.md`.

## Objects

| Kind | Name(s) |
|------|---------|
| Role / RoleBinding | `<helm-release>-argocd-sync` in operand namespace (Argo CD SA → Certificate + Secret in `namespace`) |
| ClusterRole / ClusterRoleBinding | `<helm-namespace>-<helm-release>-argocd-sync` (Argo CD SA → ClusterIssuer), unless `rbac.enabled` is false |
| ClusterIssuer | `mesh-selfsigned-bootstrap`, `mesh-root-ca` |
| Certificate (namespace) | `mesh-root-ca`, `mesh-intermediate-<cluster>` per PlacementDecision or static key |

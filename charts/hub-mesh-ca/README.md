# hub-mesh-ca

Helm chart for a cert-manager PKI stack on the hub: self-signed bootstrap `ClusterIssuer`, long-lived root CA `Certificate`, CA `ClusterIssuer` backed by the root secret, and one intermediate CA `Certificate` per spoke cluster.

Prerequisites: cert-manager Operator installed and healthy; operand namespace `cert-manager` (default) exists.

## Argo CD RBAC (default)

When **`rbac.enabled`** is true (default), the chart installs a **Role** and **RoleBinding** in **`namespace`** (`cert-manager` by default) so the OpenShift GitOps application controller service account can manage **`certificates.cert-manager.io`** and **`Secrets`** there. A **ClusterRole** and **ClusterRoleBinding** grant **`clusterissuers.cert-manager.io`**. Targets **`rbac.argocd.namespace`** / **`rbac.argocd.serviceAccountName`** (OpenShift GitOps defaults: `openshift-gitops`, `openshift-gitops-argocd-application-controller`). Override for upstream Argo CD (`argocd`, `argocd-application-controller`). Hooks run before other manifests so permissions exist before Certificate sync.

Disable with **`rbac.enabled: false`** if you manage this RBAC outside the chart (for example in `platform-setup`).

## Argo CD sync waves (default)

When **`argoSyncWaves.enabled`** is true (default), manifests include **`argocd.argoproj.io/sync-wave`** so Argo applies resources in order: RBAC → bootstrap `ClusterIssuer` → root `Certificate` → root CA `ClusterIssuer` → intermediate `Certificate` resources (defaults `-20`, `0`, `1`, `2`, `3`). Override integers under **`argoSyncWaves`**.

Waves fix apply ordering only; cert-manager still reconciles certificates asynchronously. If an intermediate appears before the root `Secret` is ready, Argo self-heal or a sync retry usually clears it. Disable waves for non-Argo Helm installs with **`argoSyncWaves.enabled: false`**.

Placement-based intermediates still require a successful **`lookup`** on `PlacementDecision` at template time—waves do not create intermediates if Helm renders none.

## Argo CD: intermediates via ApplicationSet (recommended)

Argo CD cannot evaluate Helm **`lookup`** against the hub API. Use **`charts/gitops-hub-ocm-placement-appset`** with **`values-mesh-ca-intermediate.yaml`**, which combines **`clusterDecisionResource`** (GitOps **`Placement`**, spokes only) with a static **`list`** generator entry **`in-cluster`** for the hub intermediate **`Certificate`**.

The **`hub-mesh-ca`** Application under `charts/gitops-hub-apps/applications/` passes **`intermediates.enabled: false`** so this chart only manages the root CA chain; intermediate CAs come from the ApplicationSet.

## Intermediate CAs: Placement (helm CLI / live API)

With `intermediates.source: placement` (default), the chart uses Helm `lookup` on the **PlacementDecision** that matches **`global.placement`** — same namespace/name convention as `charts/acm-openshift-gitops-resources` (`Placement` `acm-openshift-gitops-placement` in `openshift-gitops`). Each entry in `status.decisions[].clusterName` becomes one intermediate (`mesh-intermediate-<clusterName>`).

Override **`global.placement.placementDecisionName`** if your hub uses a different `PlacementDecision` (`oc get placementdecision -A`). When unset, the chart looks up **`<placement.name>-decision-1`** in **`global.placement.namespace`** (default **`openshift-gitops`**).

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

---
leave-behind: v1
state-scope: existing-cluster-lab
status: current
---

# Existing-cluster lab leave-behind

The repo's platform and mesh are deployed onto three existing single-node
OpenShift 4.21 clusters (bare metal, MetalLB for LoadBalancer Services) with
`terraform/platform` in kubeconfig mode. Roles: `<acm-hub-ctx>` runs ACM and
OpenShift GitOps and is never a mesh member; `<mesh-a-ctx>` and `<mesh-b-ctx>`
are the two mesh members (OSSM 3.4 / Istio v1.30.5). The clusters are shared with
unrelated workloads, so only this repo's namespaces and the objects below are owned here.

## Operability

### State and access

- Cluster access: the operator's kubeconfig (default `~/.kube/config`) holds one
  context per cluster, authenticated with each cluster's kube-admin client
  certificate. The API certificates are publicly trusted, so no CA data is needed. Credentials stay in that kubeconfig.
- Terraform: local state in `terraform/platform/terraform.tfstate` (default
  workspace, gitignored). Inputs in `terraform/platform/lab.tfvars` (gitignored),
  always passed with `-var-file=lab.tfvars`. The `rosa` workspace belongs to the
  separate `rosa-validation` scope.
- Argo CD syncs from the public GitHub repo at `gitops_app_repo_revision`.
- Adopted, not installed (owned by the cluster owner): ACM and its MultiClusterHub
  (`local-cluster`), the OpenShift GitOps operator, cert-manager on the hub, and
  the OSSM operator Subscription on the members (Argo adopts it; deleting the
  `<member>-ossm-operator` Application uninstalls OSSM).
- Lab overrides in `lab.tfvars`: `acm_install_operator = false`,
  `gitops_install_operator = false`, `gitops_app_overrides` (cert-manager app
  disabled; istiod 1 replica at 1-2 CPU / 3Gi; gateway Services pinned to the
  MetalLB pool `gw-ingress` with `metallb.io/address-pool`), and
  `argocd_config_values` (small Argo CD requests, 6Gi controller limit).
- Removed earlier at the owner's request: a pre-existing, unrelated Istio mesh
  (backup on the operator workstation under `~/backups/<prior-mesh>-<date>/`, mode 700).
- MetalLB: each member keeps one two-address pool (`gw-ingress`,
  autoAssign off). The ingress and east-west gateways use both addresses.

### Template map

terraform/platform/terraform.tfvars.example -> terraform/platform/lab.tfvars (per-lab inputs, gitignored)
charts/gitops-hub-app-of-apps -> Application `hub-gitops-root` in `openshift-gitops` on `<acm-hub-ctx>`
charts/gitops-hub-apps/templates/*.yaml -> child Applications in `openshift-gitops` (values from `gitops_app_overrides`)
charts/gitops-hub-ocm-placement-appset/values-*.yaml -> ApplicationSets that render one Application per mesh member
charts/argocd-config -> ArgoCD CR `openshift-gitops` (sharding, resources, exclusions, Sail health checks)
terraform/scripts/create-argocd-cluster-secret.sh -> Secret `<member>-argocd-gitops-cluster-secret` in `openshift-gitops`
charts/acm-managed-cluster -> ManagedCluster `<member>` + `auto-import-secret` in namespace `<member>` on `<acm-hub-ctx>`

### Re-run

Prerequisites: `kubectl`, `oc`, `jq`, `terraform >= 1.14.8`, a kubeconfig with the
three contexts. First-time adoption of already-joined members also needs their
ACM namespaces imported:

```bash
./terraform/platform/scripts/001-openapi-preflight.sh --contexts <acm-hub-ctx>
cd terraform/platform
terraform init
terraform import -var-file=lab.tfvars 'kubernetes_manifest.spoke_namespace["<mesh-a-ctx>"]' "apiVersion=v1,kind=Namespace,name=<mesh-a-ctx>"   # once per member, only if already ACM-managed
terraform plan -var-file=lab.tfvars -out=plan.tfplan
terraform apply plan.tfplan
```

The apply is convergent. Edited chart files roll out because each release carries
its chart's checksum. A follow-up `terraform plan -var-file=lab.tfvars -detailed-exitcode`
returns 0 when there is no drift.

### Verify and recover

- `oc --context <acm-hub-ctx> get applications.argoproj.io -n openshift-gitops`: all Synced/Healthy (30 apps).
- `oc --context <mesh-a-ctx> exec -n mesh-wiring-verify deploy/mesh-wiring-verify -- bash /opt/check/readiness.sh`:
  `Ready: secrets=2 istiod_managed=2 ... ca=shared` on each member.
- Data plane: apply `charts/mesh-verify-appset.yaml` (point revision at your branch),
  curl each member's ingress (`.status.loadBalancer.ingress[0].ip`) with
  `Host: mesh-verify.local`: answers alternate between both clusters. `oc delete -f` cascades.
- Gate reports `ca=` mismatch (istiod started before cacerts): delete the
  member's `<member>-ossm` Application on the hub. The ApplicationSet recreates it, and the
  PreSync hook waits for cacerts. Then `oc rollout restart` the member's two gateway Deployments.
- ESO pods Pending / no cacerts pushed: the hub is out of memory. Lower
  `argocd_config_values` requests and re-apply. If an ESO Application is stuck
  "Retrying operation. Attempt #1" after an Argo controller restart, terminate the operation
  (`oc patch app <name> --type merge -p '{"status":{"operationState":{"phase":"Terminating"}}}'`)
  and auto-sync starts a fresh one.
- Argo controller OOMKilled in a loop: raise its limit in `argocd_config_values`
  (it uses ~3Gi here even with the default exclusions).
- Workstation can't resolve the API names after a lab power cycle: the local resolver
  failed over to a public DNS server. Restart it (`systemctl restart systemd-resolved`).
- Namespaces stuck Terminating behind a deleted CSI driver: run the driver's
  DaemonSet in a scratch namespace until the kubelet unmounts, then delete it.

## Decision log

### Decisions

- Prior mesh removed (owner decision): both meshes need the single cluster-wide `IstioCNI`.
- Brownfield switches instead of importing ACM. Terraform's OperatorGroup and
  Subscription names differ from the console's, and a second one breaks OLM.
  `acm_local_cluster_name = "local-cluster"` keeps the MultiClusterHub unchanged.
- cert-manager on the hub serves the cluster's own API and ingress certificates, so the
  repo's cert-manager app is disabled there (its PreDelete hook would uninstall it).
- On the hub, one Manual-approval Subscription in `openshift-operators` holds every
  upgrade in that namespace. One pending InstallPlan was approved, with owner consent,
  to reach GitOps 1.22. The Manual setting stays, so `gitops_install_operator = false`
  (Terraform's AtLatestKnown wait would otherwise time out).
- Per-environment chart values go through `gitops_app_overrides` /
  `argocd_config_values`, not forks: the chart defaults stay sized for the 20-cluster campaign.

### How to drive it

1. Edit charts or Terraform on a branch, push, set `gitops_app_repo_revision` to it in `lab.tfvars`.
2. `terraform plan -var-file=lab.tfvars`, check that only intended resources change, then apply.
3. Watch `oc --context <acm-hub-ctx> get applications.argoproj.io -n openshift-gitops -w` until Synced/Healthy, then run Verify.
4. Run suites against the members only: `--contexts <mesh-a-ctx>,<mesh-b-ctx>`.
5. Record adopted or removed objects in State and access, and non-obvious choices in Decisions.

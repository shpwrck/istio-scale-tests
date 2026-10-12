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
are the two mesh members. The clusters are shared with unrelated workloads, so
only this repo's namespaces and the objects listed below are owned here.

## Operability

### State and access

- Cluster access: the operator's kubeconfig (default `~/.kube/config`) holds one
  context per cluster, authenticated with each cluster's kube-admin client
  certificate. The API certificates are publicly trusted, so the contexts carry
  no CA data. Credentials stay in that kubeconfig and are never copied into the repo.
- Terraform state: local state in `terraform/platform/terraform.tfstate`
  (gitignored). Inputs: `terraform/platform/terraform.tfvars` (gitignored).
- Argo CD pulls charts from the public GitHub repo. The root Application tracks
  `gitops_app_repo_url` and `gitops_app_repo_revision` from tfvars.
- Pre-existing operators on `<acm-hub-ctx>` that this deploy adopts rather than
  installs: ACM (`release-2.17`), OpenShift GitOps, and cert-manager. Their OLM
  objects belong to the cluster owner.
- Removed state: a pre-existing, unrelated Istio mesh (a Sail `Istio` CR in its
  own namespace, a cluster-wide `IstioCNI`, SPIRE with SPIFFE CSI drivers and
  SCCs) was deleted from both mesh members at the owner's request so that this
  repo's mesh owns the single `IstioCNI`. A full YAML export (including Secrets)
  is kept on the operator workstation under `~/backups/<prior-mesh>-<date>/`
  (mode 700), outside the repo.
- MetalLB: each mesh member has one existing two-address `IPAddressPool` with
  its `L2Advertisement` in `metallb-system`. It is kept and reused for the
  ingress and east-west gateway LoadBalancer Services.

### Template map

terraform/platform/terraform.tfvars.example -> terraform/platform/terraform.tfvars (gitignored, per-lab inputs)
charts/gitops-hub-app-of-apps -> Application `hub-gitops-root` in `openshift-gitops` on `<acm-hub-ctx>`
charts/gitops-hub-apps/templates/*.yaml -> child Applications in `openshift-gitops` on `<acm-hub-ctx>`
charts/gitops-hub-ocm-placement-appset/values-*.yaml -> ApplicationSets that render one Application per mesh member
terraform/scripts/create-argocd-cluster-secret.sh -> Secret `<member>-argocd-gitops-cluster-secret` in `openshift-gitops`
charts/acm-managed-cluster -> ManagedCluster `<member>` plus `auto-import-secret` in namespace `<member>` on `<acm-hub-ctx>`

### Re-run

Prerequisites: `kubectl`, `oc`, `jq`, `terraform >= 1.14.8`, and a kubeconfig
with the three contexts. Then:

```bash
./terraform/platform/scripts/001-openapi-preflight.sh --contexts <acm-hub-ctx>
cd terraform/platform
cp terraform.tfvars.example terraform.tfvars
# set: cluster_provider = "kubeconfig", kubeconfig_path, hub_cluster_context,
#      spoke_cluster_contexts, gitops_app_repo_url, gitops_app_repo_revision,
#      and for adopted operators:
#      acm_install_operator = false, acm_local_cluster_name = "local-cluster",
#      gitops_disabled_apps = ["hub-cert-manager-operator"]
terraform init
terraform plan -out=plan.tfplan
terraform apply plan.tfplan
```

The apply is convergent: re-running it reconciles labels, the Argo cluster
Secrets and the app-of-apps values. If the GitOps Subscription already exists
with the default name, import it before the first apply so that Terraform manages it:
`terraform import 'kubernetes_manifest.gitops_subscription[0]' "apiVersion=operators.coreos.com/v1alpha1,kind=Subscription,namespace=openshift-operators,name=openshift-gitops-operator"`.

### Verify and recover

- Hub health: `oc --context <acm-hub-ctx> get managedcluster` shows both members
  `JOINED=True AVAILABLE=True`, and `oc --context <acm-hub-ctx> get applications -n openshift-gitops`
  shows every Application `Synced/Healthy`.
- Wiring gate: `oc --context <mesh-a-ctx> get pods -n mesh-wiring-verify` is Ready
  on each member (each holds a remote secret per member and istiod manages them all).
- Data plane: apply `charts/mesh-verify-appset.yaml` on `<acm-hub-ctx>` and curl
  each member's ingress gateway (the LB address is `.status.loadBalancer.ingress[0].ip`
  on MetalLB). Responses should come from both clusters.
- API names stop resolving on the workstation after a lab power cycle: the
  local resolver can fail over to a public DNS server that has no records for
  the lab zone. Restart the local resolver (`systemctl restart systemd-resolved`)
  and confirm with `getent hosts <api-host>`.
- Namespaces stuck in `Terminating` with pods whose volumes use a CSI driver
  that was deleted first: re-run the driver's DaemonSet in a scratch namespace
  so the kubelet can unmount the volumes, wait for the namespaces to go, then
  delete the scratch namespace. Don't force-delete pods, which leaves orphaned mounts.
- Restoring the removed mesh: `oc apply` the exported cluster-scoped objects,
  then the namespaces, from the backup directory. That requires deleting this
  repo's `IstioCNI` first (only one per cluster).

## Decision log

### Decisions

- The prior mesh was removed rather than run alongside, by owner decision. Both
  meshes need the one cluster-wide `IstioCNI`, and this repo's chart pins its
  namespace and version.
- Brownfield switches (`acm_install_operator`, `gitops_install_operator`,
  `gitops_disabled_apps`) were added instead of importing ACM. The existing ACM
  OperatorGroup and Subscription have different names from Terraform's, and a
  second OperatorGroup or Subscription in the namespace breaks OLM for ACM.
  `acm_local_cluster_name = "local-cluster"` keeps the existing MultiClusterHub
  from being renamed.
- cert-manager on the hub serves the cluster's own API and ingress
  certificates, so the repo's cert-manager Application is disabled there rather
  than letting a PreDelete hook ever uninstall it.
- On the ACM hub, one Manual-approval Subscription in `openshift-operators`
  holds every upgrade in that namespace (OLM bundles them into one InstallPlan).
  The pending plan was approved once, with owner consent, to move GitOps to
  1.22. The Manual setting itself was left unchanged.
- Version targets: OSSM operator channel `stable-3.4`, Istio `v1.30.5`, ACM
  `release-2.17`, GitOps `gitops-1.22`.

### How to drive it

1. Edit charts or Terraform on a branch, push it, and set `gitops_app_repo_revision`
   to that branch in `terraform.tfvars`.
2. `terraform plan` to check that only the intended resources change, then `terraform apply`.
3. Watch `oc --context <acm-hub-ctx> get applications -n openshift-gitops -w`
   until everything is `Synced/Healthy`, then run the Verify checks above.
4. Run test suites against the members only: `--contexts <mesh-a-ctx>,<mesh-b-ctx>`.
5. Record any new adopted or removed object in this file (State and access), and
   any non-obvious choice under Decisions.

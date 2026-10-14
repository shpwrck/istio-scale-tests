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

- **Powered on again 2026-10-14** after a graceful shutdown on 2026-10-13 (power-on steps are in
  "Verify and recover"). The mesh, platform and Terraform state were unchanged. After the
  Gateway API check (backlog task 8) and its cleanup the lab is clean:
  - no test namespaces and no sync windows;
  - istiod at 1 replica;
  - all 30 Applications Synced/Healthy and every cluster operator settled;
  - both mesh-wiring gates `Ready ... ca=shared`.
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
  `acm_keep_managed_clusters_on_destroy = true` (destroy leaves the members registered in ACM),
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
terraform workspace select default   # the rosa workspace is the other scope
terraform import -var-file=lab.tfvars 'kubernetes_manifest.spoke_namespace["<mesh-a-ctx>"]' "apiVersion=v1,kind=Namespace,name=<mesh-a-ctx>"   # once per member, only if already ACM-managed
terraform plan -var-file=lab.tfvars -out=plan.tfplan
terraform apply plan.tfplan
```

The apply is convergent. Edited chart files roll out because each release carries
its chart's checksum. A follow-up `terraform plan -var-file=lab.tfvars -detailed-exitcode`
returns 0 when there is no drift.

### Verify and recover

- Shut down: first take an etcd backup on each node
  (`oc debug node/<node> -- chroot /host /usr/local/bin/cluster-backup.sh /home/core/assets/backup`),
  then halt the members and the ACM hub last (`oc debug node/<node> -- chroot /host shutdown -h 1`).
  Before a long shutdown, read the restart deadline:
  `oc -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}'`.
  For the 2026-10-13 shutdown it is September 2027. The backups stay on each node under
  `/home/core/assets/backup`.
- Power on: start all three hosts (any order). When the APIs answer, approve any pending CSRs
  (`oc get csr`, then `oc adm certificate approve <name>`), wait for `oc get nodes` Ready and
  `oc get clusteroperators` settled, and restart the workstation's resolver if the API names don't
  resolve. Then run the checks below. `cacerts` is stored in each member's etcd, so istiod starts
  on the shared root without waiting for the hub.
  - 2026-10-14 power-on: nodes were Ready within about 3 minutes after approving 6 node CSRs. One
    of them was OVN-Kubernetes' per-node client certificate (`system:ovn-node:<node>`, signer
    `kubernetes.io/kube-apiserver-client`). A member whose node goes Ready late keeps its pods in
    ContainerCreating until OVN is up (about 8 more minutes here).
  - The hub's External Secrets Application can read Degraded (`CatalogSourcesUnhealthy`) until the
    catalog pods start; it recovers on its own.
- `oc --context <acm-hub-ctx> get applications.argoproj.io -n openshift-gitops`: all Synced/Healthy (30 apps).
- `oc --context <mesh-a-ctx> exec -n mesh-wiring-verify deploy/mesh-wiring-verify -- bash /opt/check/readiness.sh`:
  `Ready: secrets=2 istiod_managed=2 ... ca=shared` on each member.
- Data plane: apply `charts/mesh-verify-appset.yaml` (set both `targetRevision` and the
  `repo.revision` parameter to your branch),
  curl each member's ingress (`.status.loadBalancer.ingress[0].ip`) with
  `Host: mesh-verify.local`: answers alternate between both clusters. `oc delete -f` cascades.
- Gate reports `ca=` mismatch (istiod started before cacerts): once `cacerts` exists in
  `istio-system`, restart istiod (`oc -n istio-system delete pod -l app=istiod`). istiod reads
  `cacerts` only at startup, so it does not recover by itself. Then restart every pod that started
  while istiod ran on the self-signed root, because it holds a certificate from that root. On a
  fresh install that includes the two gateway Deployments; gateways that predate the race keep
  working (lab-checked 2026-10-13). If `cacerts` is missing, delete the member's `<member>-ossm`
  Application on the hub instead. The ApplicationSet recreates it, and the PreSync hook holds the
  install until cacerts arrives.
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
- Temporary experiments on mesh objects (more istiod replicas, a deleted `cacerts` or Istio CR,
  a rebuilt gateway Service) run under a deny sync window from
  `tests/tuning/006-gitops-pause.sh --appset <appset> --state-file <scratch>/<name>.json --pause`
  so Argo does not undo them mid-test, and end with `--resume` on the same state file. Three istiod
  replicas fit on one member at the lab sizing (1 CPU / 3Gi each): patch the member's Istio CR
  `spec.values.pilot.replicaCount` under a `spoke-ossm` pause and patch it back before resuming.
  The east-west and ingress Services share a two-address pool, so deleting both and recreating
  east-west first swaps their addresses; recreate ingress first to keep the original assignment.
  A deny NetworkPolicy used to make a remote unreachable only affects new connections on
  OVN-Kubernetes: the east-west gateway's pooled connections survive it, so restart the target
  pods after applying it or the remote still answers.

### How to drive it

1. Edit charts or Terraform on a branch, push, set `gitops_app_repo_revision` to it in `lab.tfvars`.
2. `terraform plan -var-file=lab.tfvars`, check that only intended resources change, then apply.
3. Watch `oc --context <acm-hub-ctx> get applications.argoproj.io -n openshift-gitops -w` until Synced/Healthy, then run Verify.
4. Run suites against the members only: `--contexts <mesh-a-ctx>,<mesh-b-ctx>`.
5. Record adopted or removed objects in State and access, and non-obvious choices in Decisions.

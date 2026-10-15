---
leave-behind: v1
state-scope: existing-cluster-lab
status: current
---

# Existing-cluster lab leave-behind

The repo's platform and mesh run on three existing single-node OpenShift 4.21 clusters (bare
metal, MetalLB for LoadBalancer Services), deployed by `terraform/platform` in kubeconfig mode.
- `<acm-hub-ctx>` runs ACM and OpenShift GitOps. It is never a mesh member.
- `<mesh-a-ctx>` and `<mesh-b-ctx>` are the two mesh members (OSSM 3.4 / Istio v1.30.5).

The clusters are shared with unrelated workloads, so only this repo's namespaces and the objects
below are owned here.

## Operability

### State and access

- **Powered off since 2026-10-14, about 19:30 UTC.** All three clusters had a graceful node
  shutdown, the ACM hub last, after the Gateway API check (backlog task 8). It was the second
  power cycle in two days: off on 2026-10-13, on again for the check on 2026-10-14.
  - Nothing was torn down; the mesh, platform and Terraform state are unchanged.
  - The lab was clean before the halt: no test namespaces, no sync windows, no on-demand checks
    deployed, istiod at 1 replica, all 30 Applications Synced/Healthy, every cluster operator
    settled, and both mesh-wiring gates `Ready ... ca=shared`.
  - Power-on steps and the restart deadline are in "Verify and recover".
- Cluster access: the operator's kubeconfig (default `~/.kube/config`) holds one context per
  cluster, each authenticated with that cluster's kube-admin client certificate. The API
  certificates are publicly trusted, so no CA data is needed. Credentials stay in that kubeconfig.
  - The ROSA validation scope uses its own kubeconfigs, not this file.
  - Always pass `--context` explicitly.
- Terraform: local state in `terraform/platform/terraform.tfstate` (default workspace,
  gitignored). Inputs are in `terraform/platform/lab.tfvars` (gitignored), always passed with
  `-var-file=lab.tfvars`. The `rosa` workspace belongs to the separate `rosa-validation` scope.
- Argo CD syncs from the public GitHub repo at `gitops_app_repo_revision`.
- Adopted, not installed (owned by the cluster owner):
  - ACM and its MultiClusterHub (`local-cluster`);
  - the OpenShift GitOps operator;
  - cert-manager on the hub;
  - the OSSM operator Subscription on the members. Argo adopts it, so deleting the
    `<member>-ossm-operator` Application uninstalls OSSM.
- Lab overrides in `lab.tfvars`:
  - `acm_install_operator = false`;
  - `acm_keep_managed_clusters_on_destroy = true` (destroy leaves the members registered in ACM);
  - `gitops_install_operator = false`;
  - `gitops_app_overrides`: the cert-manager app disabled; istiod 1 replica at 1-2 CPU / 3Gi;
    gateway Services pinned to the MetalLB pool `gw-ingress` with `metallb.io/address-pool`;
  - `argocd_config_values`: small Argo CD requests, 6Gi controller limit.
- Removed earlier at the owner's request: a pre-existing, unrelated Istio mesh. Its backup is on
  the operator workstation under `~/backups/<prior-mesh>-<date>/` (mode 700).
- MetalLB: each member keeps one two-address pool (`gw-ingress`, autoAssign off). The ingress and
  east-west gateways use both addresses, so nothing that needs a new LoadBalancer IP can run here.
- On-demand checks are not part of the app-of-apps: `mesh-verify` and the Gateway API check.
  Each is an Application applied by hand on `<acm-hub-ctx>` and deleted after use. None is
  deployed now.

### Template map

terraform/platform/terraform.tfvars.example -> terraform/platform/lab.tfvars (per-lab inputs, gitignored)
charts/gitops-hub-app-of-apps -> Application `hub-gitops-root` in `openshift-gitops` on `<acm-hub-ctx>`
charts/gitops-hub-apps/templates/*.yaml -> child Applications in `openshift-gitops` (values from `gitops_app_overrides`)
charts/gitops-hub-ocm-placement-appset/values-*.yaml -> ApplicationSets that render one Application per mesh member
charts/argocd-config -> ArgoCD CR `openshift-gitops` (sharding, resources, exclusions, Sail health checks)
terraform/scripts/create-argocd-cluster-secret.sh -> Secret `<member>-argocd-gitops-cluster-secret` in `openshift-gitops`
charts/acm-managed-cluster -> ManagedCluster `<member>` + `auto-import-secret` in namespace `<member>` on `<acm-hub-ctx>`
charts/mesh-verify-appset.yaml -> on demand: Application `mesh-verify-appset` + per-member `mesh-verify` echo apps
charts/mesh-verify-gateway-api-appset.yaml (workload member filled in by `sed` on the way to the hub) -> on demand: Application `mesh-verify-gateway-api-appset`, ApplicationSet `mesh-verify-gwapi`, per-member Applications `<member>-mesh-verify-gwapi`
charts/mesh-verify-gateway-api -> on each member: namespaces `mesh-verify-gwapi` + `mesh-verify-gwapi-shared` and the Gateway API Gateway `istio-system/mesh-verify-gwapi`; on the workload member also `mesh-verify-gwapi-remote` and the echo Deployments

### Re-run

Prerequisites: `kubectl`, `oc`, `jq`, `terraform >= 1.14.8`, and a kubeconfig with the three
contexts. First-time adoption of members that are already joined also needs their ACM namespaces
imported:

```bash
./terraform/platform/scripts/001-openapi-preflight.sh --contexts <acm-hub-ctx>
cd terraform/platform
terraform init
terraform workspace select default   # the rosa workspace is the other scope
terraform import -var-file=lab.tfvars 'kubernetes_manifest.spoke_namespace["<mesh-a-ctx>"]' "apiVersion=v1,kind=Namespace,name=<mesh-a-ctx>"   # once per member, only if already ACM-managed
terraform plan -var-file=lab.tfvars -out=plan.tfplan
terraform apply plan.tfplan
```

The apply is convergent. Edited chart files roll out because each release carries its chart's
checksum. A follow-up `terraform plan -var-file=lab.tfvars -detailed-exitcode` returns 0 when
there is no drift.

Gateway API multicluster check, on demand. It is read-only apart from the Application. Use
istioctl at the mesh's version.

```bash
sed -e 's/<workload-cluster>/<member-managed-cluster-name>/' charts/mesh-verify-gateway-api-appset.yaml \
  | oc --context <acm-hub-ctx> apply -f -
tests/gateway-api/001-run-ingress-check.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> \
  --workload-context <mesh-b-ctx> --hub-context <acm-hub-ctx>
oc --context <acm-hub-ctx> delete -f charts/mesh-verify-gateway-api-appset.yaml
```

To pin the deployed chart to the commit you run the script from, also replace `main` in
`targetRevision` and in the `repo.revision` value with that commit; the 2026-10-14 run did this.

### Verify and recover

- Shut down:
  1. Take an etcd backup on each node:
     `oc debug node/<node> -- chroot /host /usr/local/bin/cluster-backup.sh /home/core/assets/backup`.
     The backups stay on each node under `/home/core/assets/backup`.
  2. Halt the members, and the ACM hub last: `oc debug node/<node> -- chroot /host shutdown -h 1`.
     Wait until each API refuses connections; the hub answers with InternalError for about
     20 s before it does.

  Before a long shutdown, read the restart deadline:
  `oc -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}'`.
  For the 2026-10-14 shutdown it is 2027-09-15 on the ACM hub and 2027-09-24 on the members:
  power on before the earliest. Each node holds backups from both 2026-10-13 and 2026-10-14.
- Power on:
  1. Start all three hosts, in any order.
  2. When the APIs answer, approve any pending CSRs (`oc get csr`, then
     `oc adm certificate approve <name>`).
  3. Wait for `oc get nodes` Ready and `oc get clusteroperators` settled.
  4. If the API names don't resolve, restart the workstation's resolver.
  5. Run the checks below. `cacerts` is stored in each member's etcd, so istiod starts on the shared
     root without waiting for the hub.

  Seen on the 2026-10-14 power-on:
  - Nodes were Ready within about 3 minutes, after approving 6 node CSRs. One was OVN-Kubernetes'
    per-node client certificate (`system:ovn-node:<node>`, signer
    `kubernetes.io/kube-apiserver-client`).
  - A member whose node goes Ready late keeps its pods in ContainerCreating until OVN is up (about
    8 more minutes here).
  - The hub's External Secrets Application can read Degraded (`CatalogSourcesUnhealthy`) until the
    catalog pods start; it recovers on its own.
- `oc --context <acm-hub-ctx> get applications.argoproj.io -n openshift-gitops`: all Synced/Healthy
  (30 apps when no on-demand check is deployed).
- `oc --context <mesh-a-ctx> exec -n mesh-wiring-verify deploy/mesh-wiring-verify -- bash /opt/check/readiness.sh`:
  `Ready: secrets=2 istiod_managed=2 ... ca=shared` on each member.
- Data plane:
  1. Apply `charts/mesh-verify-appset.yaml` (set both `targetRevision` and the `repo.revision`
     parameter to your branch).
  2. Curl each member's ingress (`.status.loadBalancer.ingress[0].ip`) with
     `Host: mesh-verify.local`. Answers alternate between both clusters.
  3. Remove it with `oc delete -f`, which cascades.
- Gateway API check:
  - Expected result: `22 MATCH, 0 DEVIATION, 0 UNKNOWN` and the two answers recorded in
    `docs/campaigns/2026-10-14-gateway-api-multicluster-lab.md`.
  - While deployed, both member Applications read Degraded by design: C1's backend does not exist,
    and Argo CD marks every HTTPRoute with `ResolvedRefs=False` as Degraded.
  - After `oc delete -f`, the finalizers remove everything within about 20 s. That includes the
    `istio-system` Gateway, so `get ns mesh-verify-gwapi mesh-verify-gwapi-shared
    mesh-verify-gwapi-remote` should find nothing on either member.
  - If the Gateway survives, delete `gateways.gateway.networking.k8s.io/mesh-verify-gwapi` in
    `istio-system`. Spell out the resource name: `gateway` alone is ambiguous with Istio's.
- Gate reports a `ca=` mismatch (istiod started before cacerts):
  1. Once `cacerts` exists in `istio-system`, restart istiod
     (`oc -n istio-system delete pod -l app=istiod`). istiod reads `cacerts` only at startup, so it
     does not recover by itself.
  2. Restart every pod that started while istiod ran on the self-signed root, because it holds a
     certificate from that root. On a fresh install that includes the two gateway Deployments;
     gateways that predate the race keep working (lab-checked 2026-10-13).
  3. If `cacerts` is missing, delete the member's `<member>-ossm` Application on the hub instead.
     The ApplicationSet recreates it, and the PreSync hook holds the install until cacerts arrives.
- ESO pods Pending, or no cacerts pushed: the hub is out of memory. Lower the
  `argocd_config_values` requests and re-apply.
  - If an ESO Application is stuck at "Retrying operation. Attempt #1" after an Argo controller
    restart, terminate the operation
    (`oc patch app <name> --type merge -p '{"status":{"operationState":{"phase":"Terminating"}}}'`)
    and auto-sync starts a fresh one.
- Argo controller OOMKilled in a loop: raise its limit in `argocd_config_values`. It uses about 3Gi
  here even with the default exclusions.
- Workstation can't resolve the API names after a lab power cycle: the local resolver failed over
  to a public DNS server. Restart it (`systemctl restart systemd-resolved`). This is
  workstation-wide, so check first that no other session (for example a ROSA window) is
  mid-operation.
- Namespaces stuck Terminating behind a deleted CSI driver: run the driver's DaemonSet in a scratch
  namespace until the kubelet unmounts, then delete it.

## Decision log

### Decisions

- Prior mesh removed (owner decision): both meshes need the single cluster-wide `IstioCNI`.
- Brownfield switches instead of importing ACM:
  - Terraform's OperatorGroup and Subscription names differ from the console's, and a second one
    breaks OLM.
  - `acm_local_cluster_name = "local-cluster"` keeps the MultiClusterHub unchanged.
- cert-manager on the hub serves the cluster's own API and ingress certificates. The repo's
  cert-manager app is therefore disabled there, because its PreDelete hook would uninstall it.
- On the hub, one Manual-approval Subscription in `openshift-operators` holds every upgrade in that
  namespace.
  - One pending InstallPlan was approved, with owner consent, to reach GitOps 1.22.
  - The Manual setting stays, so `gitops_install_operator = false`; Terraform's AtLatestKnown wait
    would otherwise time out.
- Per-environment chart values go through `gitops_app_overrides` / `argocd_config_values`, not
  forks. The chart defaults stay sized for the 20-cluster campaign.
- Temporary experiments on mesh objects (more istiod replicas, a deleted `cacerts` or Istio CR, a
  rebuilt gateway Service) run under a deny sync window, so Argo does not undo them mid-test.
  - Open it with `tests/tuning/006-gitops-pause.sh --appset <appset> --state-file <scratch>/<name>.json --pause`
    and end with `--resume` on the same state file.
  - Three istiod replicas fit on one member at the lab sizing (1 CPU / 3Gi each). Patch the
    member's Istio CR `spec.values.pilot.replicaCount` under a `spoke-ossm` pause, and patch it
    back before resuming.
  - The east-west and ingress Services share a two-address pool. Deleting both and recreating
    east-west first swaps their addresses, so recreate ingress first to keep the original
    assignment.
  - On OVN-Kubernetes, a deny NetworkPolicy used to make a remote unreachable only affects new
    connections. The east-west gateway's pooled connections survive it, so restart the target pods
    after applying it, or the remote still answers.
- The Gateway API check binds a Gateway API Gateway onto the existing `istio-ingressgateway` by
  manual deployment (`spec.addresses` of type Hostname, Gateway in `istio-system`).
  - An automated Gateway would need a third MetalLB address, and the pool has none.
  - The check's namespaces need no `egressHosts` entry in `charts/spoke-ossm`: gateway proxies
    never select a `Sidecar` in Istio 1.30.5.
  - It answered: no Service is needed on every member for traffic, but with `kind: Service` the
    namespace is. Argo CD flags remote-only backends as Degraded.
- The owner powers the lab off between validation runs (2026-10-13, and again 2026-10-14). Each
  power-off takes fresh etcd backups first and records the restart deadline here.

### How to drive it

1. Power on if needed ("Verify and recover"), then run the health checks.
2. Edit charts or Terraform on a branch, push, and set `gitops_app_repo_revision` to that branch in
   `lab.tfvars`.
3. Run `terraform plan -var-file=lab.tfvars`, check that only the intended resources change, then
   apply.
4. Watch `oc --context <acm-hub-ctx> get applications.argoproj.io -n openshift-gitops -w` until
   Synced/Healthy, then run Verify.
5. Run suites against the members only: `--contexts <mesh-a-ctx>,<mesh-b-ctx>`.
6. For on-demand checks (mesh-verify, Gateway API), apply the Application, run the check, and
   delete it before you finish. Then confirm the 30-app Synced/Healthy count again.
7. Record adopted or removed objects in State and access, non-obvious choices in Decisions, and
   any run results under `docs/campaigns/`.
8. When done, shut down: back up, halt the members, then the hub. Update the State line here.

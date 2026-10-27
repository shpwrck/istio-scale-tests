---
leave-behind: v1
state-scope: existing-cluster-lab
status: current
---

# Existing-cluster lab leave-behind

The repo's platform and mesh run on three existing single-node OpenShift 4.21 clusters (bare
metal, MetalLB for LoadBalancer Services), deployed by `terraform/platform` in kubeconfig mode
(rebuilt from scratch on 2026-10-26).
- `<acm-hub-ctx>` runs ACM and OpenShift GitOps. It is never a mesh member.
- `<mesh-a-ctx>` and `<mesh-b-ctx>` are the two mesh members (OSSM 3.4 / Istio v1.30.5).

The clusters are shared with unrelated workloads, so only this repo's namespaces and the objects
below are owned here.

## Operability

### State and access

- **Running since the rebuild of 2026-10-26.** The platform and mesh were torn down on
  2026-10-21 after another lab, and that Terraform state was lost. The rebuild ran from the
  head of PR #110 (charts from `main`), then that PR's smoke run.
  - The lab was clean after the smoke: no test namespaces, no sync windows, no on-demand checks
    deployed, istiod at 1 replica, all 30 Applications Synced/Healthy, both mesh-wiring gates
    `Ready ... ca=shared`, and `terraform plan` reported no changes.
  - Capacity after the rebuild: the ACM hub runs about 210 of its 250 pods (ACM alone about 81)
    and requests about 10 of 31.5 CPU; each member runs about 118 pods and requests 4.7 of 19.5
    CPU.
  - Power-off and power-on steps, and the restart deadline, are in "Verify and recover".
- Cluster access: the operator's kubeconfig (default `~/.kube/config`) holds one context per
  cluster, each authenticated with that cluster's kube-admin client certificate. The API
  certificates are publicly trusted, so no CA data is needed. Credentials stay in that kubeconfig.
  - The ROSA validation scope uses its own kubeconfigs, not this file.
  - Always pass `--context` explicitly.
- Terraform: local state in `terraform/platform/terraform.tfstate` (default workspace,
  gitignored) of the checkout that ran the 2026-10-26 rebuild on the operator workstation. It is
  the only state of this lab, so keep it. Inputs are in `terraform/platform/terraform.tfvars`
  there (gitignored), which Terraform reads without a flag.
- Argo CD syncs from the public GitHub repo (`gitops_app_repo_url` in the tfvars) at
  `gitops_app_repo_revision`. After the repo moves, set the new URL there and re-apply.
- Installed at the rebuild: Terraform installed ACM 2.17 with its MultiClusterHub (the hub's own
  ManagedCluster takes the hub's context name, the default `acm_local_cluster_name`) and
  OpenShift GitOps 1.22 on the hub. Argo CD installs External Secrets on the hub and OSSM 3.4 on
  the members, so deleting a `<member>-ossm-operator` Application uninstalls OSSM.
- Used, not installed (owned by the cluster owner): cert-manager on the hub. Also the owner's and
  untouched: the hub's OSSM operator, which serves that cluster's own Gateway API. Its Manual
  Subscription is why GitOps installs and upgrades wait for approval (Decisions).
- Lab inputs in `terraform.tfvars`:
  - `platform = "openshift"`: kubeconfig mode defaults to `kubernetes`, and without this line the
    plan stops at its hub platform check (terraform/platform/README.md);
  - `hub_cluster_context` and `spoke_cluster_contexts`: the three contexts;
  - `gitops_operator_namespace = "openshift-operators"`: the rebuild installed GitOps there, the
    default until 2026-10-26, and without this line the plan stops at its check for a GitOps
    Subscription in another namespace;
  - `gitops_app_overrides`: the cert-manager app disabled; istiod 1 replica at 1-2 CPU / 3Gi;
    gateway Services pinned to the MetalLB pool `gw-ingress` with `metallb.io/address-pool`;
  - `argocd_config_values`: small Argo CD requests, 6Gi controller limit.
- Removed earlier at the owner's request: a pre-existing, unrelated Istio mesh. Its backup is on
  the operator workstation under `~/backups/<prior-mesh>-<date>/` (mode 700).
- Removed at the owner's request at the 2026-10-26 rebuild, to free pod slots and CPU: the
  unrelated operators and demos on all three clusters (OpenShift AI, the NVIDIA GPU operator and
  NFD, Connectivity Link, ACS, Trusted Artifact Signer with its Keycloak, Network Observability
  with Loki, Compliance, a demo app and self-hosted CI runners). Their CRDs stay.
- MetalLB: each member keeps one two-address pool (`gw-ingress`, autoAssign off). The ingress and
  east-west gateways use both addresses, so nothing that needs a new LoadBalancer IP can run here.
- On-demand checks are not part of the app-of-apps: `mesh-verify` and the Gateway API check.
  Each is an Application applied by hand on `<acm-hub-ctx>` and deleted after use. None is
  deployed now.

### Template map

terraform/platform/terraform.tfvars.example -> terraform/platform/terraform.tfvars (per-lab inputs, gitignored)
charts/gitops-hub-app-of-apps -> Application `hub-gitops-root` in `openshift-gitops` on `<acm-hub-ctx>`
charts/gitops-hub-apps/templates/*.yaml -> child Applications in `openshift-gitops` (values from `gitops_app_overrides`)
charts/gitops-hub-ocm-placement-appset/values-*.yaml -> ApplicationSets that render one Application per mesh member
charts/argocd-config -> ArgoCD CR `openshift-gitops` (sharding, resources, exclusions, Sail health checks)
terraform/scripts/create-argocd-cluster-secret.sh -> Secret `<member>-argocd-gitops-cluster-secret` in `openshift-gitops`
charts/acm-managed-cluster -> ManagedCluster `<member>` + `auto-import-secret` in namespace `<member>` on `<acm-hub-ctx>`
charts/mesh-verify-appset.yaml -> on demand: Application `mesh-verify-appset` + per-member `mesh-verify` echo apps
charts/mesh-verify-gateway-api-appset.yaml (repo, revision, platform, Argo CD namespace and workload member filled in by `sed` on the way to the hub) -> on demand: Application `mesh-verify-gateway-api-appset`, ApplicationSet `mesh-verify-gwapi`, per-member Applications `<member>-mesh-verify-gwapi`
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
terraform import 'kubernetes_manifest.spoke_namespace["<mesh-a-ctx>"]' "apiVersion=v1,kind=Namespace,name=<mesh-a-ctx>"   # once per member, only if already ACM-managed
terraform plan -out=plan.tfplan
./scripts/002-plan-leftover-check.sh plan.tfplan   # objects already on the hub
terraform apply plan.tfplan
```

The apply is convergent. Edited chart files roll out because each release carries its chart's
checksum. A follow-up `terraform plan -detailed-exitcode` returns 0 when there is no drift.

A rebuild on a fresh state met three stops on 2026-10-26: an earlier deploy's object on the hub,
the GitOps InstallPlan waiting for approval, and the hub's pod limit. The leftover check, the
apply's operator wait and the plan's pod-slot warning now name each of them ("Verify and recover").

Gateway API multicluster check, on demand. It is read-only apart from the Application. Use
istioctl at the mesh's version.

```bash
NS=openshift-gitops PLATFORM=openshift WORKLOAD=<member-managed-cluster-name>
read -r REPO REV < <(kubectl --context <acm-hub-ctx> -n "$NS" \
  get applications.argoproj.io hub-gitops-root \
  -o jsonpath='{.spec.source.repoURL} {.spec.source.targetRevision}')
fill() { sed -e "s|<repo-url>|${REPO:?}|g" -e "s|<revision>|${REV:?}|g" \
  -e "s|<platform>|${PLATFORM}|g" -e "s|<gitops-namespace>|${NS}|g" \
  -e "s|<workload-cluster>|${WORKLOAD:?}|g" charts/mesh-verify-gateway-api-appset.yaml; }
fill | kubectl --context <acm-hub-ctx> apply -f -
misc_tests/gateway-api/001-run-ingress-check.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> \
  --workload-context <mesh-b-ctx> --hub-context <acm-hub-ctx>
fill | kubectl --context <acm-hub-ctx> delete -f -
```

The check deploys the charts at the revision the hub syncs. To pin it to the commit you run the
script from, set `gitops_app_repo_revision` to that commit and apply first (the `<revision>` then
reads it); the 2026-10-14 run pinned its commit. This script and `tests/tuning/006-gitops-pause.sh`
find the Argo CD namespace from the hub (`openshift-gitops` here); `GWAPI_ARGOCD_NAMESPACE` and
`TUNING_GITOPS_NAMESPACE` override it.

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
- `kubectl --context <acm-hub-ctx> get applications.argoproj.io -n openshift-gitops`: all Synced/Healthy
  (30 apps when no on-demand check is deployed).
- `kubectl --context <mesh-a-ctx> exec -n mesh-wiring-verify deploy/mesh-wiring-verify -- sh /opt/check/readiness.sh`:
  `Ready: secrets=2 istiod_managed=2 ... members=<mesh-a-ctx>,<mesh-b-ctx> ca=shared` on each member.
- Data plane:
  1. Apply `charts/mesh-verify-appset.yaml` with the `fill` recipe in
     [docs/reference.md](../../reference.md#the-end-to-end-echo-check-by-hand)
     (`NS=openshift-gitops PLATFORM=openshift`); it deploys the revision the hub syncs.
     `tests/preflight/001-check-mesh.sh --hub-context <acm-hub-ctx> --echo` does the whole echo
     check in one command.
  2. Curl each member's ingress (`.status.loadBalancer.ingress[0].ip`) with
     `Host: mesh-verify.local`. Answers alternate between both clusters.
  3. Remove it with the same `fill`, piped to `kubectl --context <acm-hub-ctx> delete -f -`; the
     delete cascades.
- Gateway API check:
  - Expected result, again on 2026-10-26: `22 MATCH, 0 DEVIATION, 0 UNKNOWN` and the two answers
    recorded in `docs/campaigns/2026-10-14-gateway-api-multicluster-lab/README.md`.
  - While deployed, both member Applications read Degraded by design: C1's backend does not exist,
    and Argo CD marks every HTTPRoute with `ResolvedRefs=False` as Degraded.
  - After `fill | kubectl --context <acm-hub-ctx> delete -f -`, the finalizers remove everything
    within about 20 s. That includes the `istio-system` Gateway, so `get ns mesh-verify-gwapi
    mesh-verify-gwapi-shared mesh-verify-gwapi-remote` should find nothing on either member.
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
    (`oc patch applications.argoproj.io <name> --type merge -p '{"status":{"operationState":{"phase":"Terminating"}}}'`)
    and auto-sync starts a fresh one.
- Argo controller OOMKilled in a loop: raise its limit in `argocd_config_values`. It uses about 3Gi
  here even with the default exclusions.
- Workstation can't resolve the API names after a lab power cycle: the local resolver failed over
  to a public DNS server. Restart it (`systemctl restart systemd-resolved`). This is
  workstation-wide, so check first that no other session (for example a ROSA window) is
  mid-operation.
- Namespaces stuck Terminating behind a deleted CSI driver: run the driver's DaemonSet in a scratch
  namespace until the kubelet unmounts, then delete it.
- `002-plan-leftover-check.sh` lists an object the plan creates that is still on the cluster
  (2026-10-26: ClusterRole and ClusterRoleBinding `openshift-gitops-applicationset-controller` on
  the hub, from a lost state; the apply stopped on "Cannot create resource that already exists").
  Import it with the command the check prints, or save it with `-o yaml` and delete it with the
  owner's consent; then plan again.
- The apply prints `InstallPlan <name> waits for a manual approval` while
  `terraform_data.gitops_subscription_ready` waits (up to 15 min): the owner's Manual OSSM
  Subscription holds it (Decisions). Check that the CSVs it lists are only the GitOps one, then
  approve it with the owner's consent, using the command it prints; the apply goes on. After the
  wait has timed out, plan (it replaces the failed wait) and apply. When GitOps is installed
  already and only its upgrade waits, the apply names the InstallPlan and goes on with the
  installed version.
- The plan warns `free pod slots` while no MultiClusterHub exists yet, or the reshard step names
  Argo CD pods `Pending (Unschedulable: ... Too many pods)`: the hub is at its 250-pod limit.
  Free pod slots (2026-10-26: the owner's unrelated workloads were removed), or raise `maxPods`
  with a KubeletConfig, which reboots the single node. Then plan (it replaces the failed step) and
  apply.

## Decision log

### Decisions

- Prior mesh removed (owner decision): both meshes need the single cluster-wide `IstioCNI`.
- Until 2026-10-21, brownfield switches instead of importing ACM (superseded by the rebuild, where
  Terraform installed ACM and GitOps, since neither was left on the hub):
  - Terraform's OperatorGroup and Subscription names differ from the console's, and a second one
    breaks OLM.
  - `acm_local_cluster_name = "local-cluster"` kept the MultiClusterHub unchanged.
- cert-manager on the hub serves the cluster's own API and ingress certificates. The repo's
  cert-manager app is therefore disabled there, because its PreDelete hook would uninstall it.
- On the hub, one Manual-approval Subscription in `openshift-operators` (the owner's OSSM) makes
  OLM hold every install and upgrade in that namespace for approval, the GitOps operator's too.
  - Before 2026-10-21, `gitops_install_operator = false` adopted an installed GitOps (one pending
    InstallPlan was approved, with owner consent, to reach 1.22).
  - At the 2026-10-26 rebuild Terraform installed GitOps, and its InstallPlan was approved by
    hand once, with owner consent ("Verify and recover"). The Manual setting stays, so a GitOps
    upgrade needs the same.
  - The repo now installs GitOps in a namespace of its own (`openshift-gitops-operator`), out of
    reach of that setting. This lab keeps `openshift-operators` (`gitops_operator_namespace`):
    moving an installed operator means reinstalling it, which nobody has tried here.
- 2026-10-26, owner decision: the unrelated workloads were removed from all three clusters, after
  ACM and Argo CD together hit the hub's 250-pod limit. Raising `maxPods` (one reboot of the hub)
  was the alternative.
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
   `terraform.tfvars`.
3. Run `terraform plan`, check that only the intended resources change, then apply.
4. Watch `oc --context <acm-hub-ctx> get applications.argoproj.io -n openshift-gitops -w` until
   Synced/Healthy, then run Verify.
5. Run suites against the members only: `--contexts <mesh-a-ctx>,<mesh-b-ctx>`.
6. For on-demand checks (mesh-verify, Gateway API), apply the Application, run the check, and
   delete it before you finish. Then confirm the 30-app Synced/Healthy count again.
7. Record adopted or removed objects in State and access, non-obvious choices in Decisions, and
   any run results under `docs/campaigns/`.
8. When done, shut down: back up, halt the members, then the hub. Update the State line here.

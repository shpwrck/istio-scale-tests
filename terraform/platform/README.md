# Platform and mesh (Terraform)

Installs Argo CD on the hub, registers the other clusters with it, and starts the Argo CD
app-of-apps that deploys the whole mesh (Sail operator, Istio, shared CA, secrets, gateways).

| `platform` | Hub gets | Clusters join through | Members get |
| --- | --- | --- | --- |
| `kubernetes` (default) | upstream Argo CD (`argo-cd` Helm chart) | an Argo CD cluster Secret each, with a ServiceAccount token | the upstream Sail operator (Helm) |
| `openshift` (optional, untested) | ACM and OpenShift GitOps (OLM) | ACM ManagedClusters, plus the Argo CD cluster Secrets | OSSM 3 (OLM) |

Two ways to find clusters:

| `cluster_provider` | Clusters come from | Hub |
| --- | --- | --- |
| `kubeconfig` (default) | `kubeconfig_path` + context names | `hub_cluster_context` |
| `rosa` (implies `platform = "openshift"`) | `terraform/rosa-hcp` state | the first cluster |

`platform` defaults to `kubernetes`, or to `openshift` with `cluster_provider = "rosa"`.
Upgrading a deployment from before `platform` existed (OpenShift only, `cluster_provider`
defaulting to `rosa`): set `cluster_provider = "rosa"`, or `platform = "openshift"` for OpenShift
clusters from a kubeconfig, before the first plan. In kubeconfig mode every plan reads the hub's
API groups and fails before any change when they disagree with `platform` (an OpenShift hub serves
`security.openshift.io/v1`); a destroy plan, or a hub it cannot read, only gives a warning.

The hub runs Argo CD (and ACM on OpenShift) and is never a mesh member. Spoke context names become
the Argo CD cluster names (and ManagedCluster names on OpenShift), so they must be DNS-1123 labels:
short, lowercase, no `:` or `/`. Rename a context that is not, for example an EKS ARN:
`kubectl config rename-context <arn> mesh-a` (or `aws eks update-kubeconfig --alias mesh-a`).

## Run

```bash
cp terraform.tfvars.example terraform.tfvars   # platform, repo URL/branch, cluster_provider, contexts
./scripts/001-openapi-preflight.sh --contexts <hub-ctx>   # existing OpenShift hubs only
terraform init
terraform plan -out=platform.tfplan
terraform apply platform.tfplan
```

Then watch the rollout until every Application is Synced/Healthy (about 15–20 minutes):
`kubectl --context <hub-ctx> get applications.argoproj.io -n argocd` (`terraform output
gitops_namespace` names the namespace: `openshift-gitops` on OpenShift). A kind lab on one machine:
[docs/runbooks/kind-lab](../../docs/runbooks/kind-lab/README.md).

What the apply needs to reach:

- Every cluster's API server from this machine (the kubeconfig's URLs), and every member's API
  server from the hub's pods and from every other member: the URL goes into the member's Argo CD
  cluster Secret and from there into the External Secrets stores and the Istio remote secrets,
  which the other members' istiod use. When the kubeconfig's URL works only from this machine
  (kind writes `https://127.0.0.1:<port>`), set a URL that works from all of them in
  `cluster_api_url_overrides`. The apply fails at its end when Argo CD cannot reach a member (see
  below), and the wiring gate on each member names a member its istiod cannot sync.
- The Argo CD chart repo (`argocd_chart_repository`) from this machine, and the git repo
  (`gitops_app_repo_url`) plus the operator chart repos from the hub (Argo CD pulls them): a
  mirror goes in through `gitops_app_overrides` (`terraform.tfvars.example`).

On `kubernetes` each member gets a ServiceAccount bound to `cluster-admin`
(`gitops_managed_service_account_name` in `spoke_service_account_namespace`,
`istio-scale-tests-access` by default) whose token authenticates Argo CD, the External Secrets
pushes and the Istio remote secrets to it. The hub's Argo CD Secret holds that token: treat the
hub as the mesh's trust root. The apply creates the namespace when it is missing, labelled
`istio-scale-tests/created-by`, and destroy deletes it only with that label. It is not
`kube-system`: ServiceAccounts there share the API server's `workload-high` priority level
(FlowSchema `kube-system-service-accounts`) with the controllers the suites measure, while this
token falls under `service-accounts` (`workload-low`). Setting it to `kube-system` keeps the old
layout.

A deployment from before this default has the ServiceAccount in `kube-system`, and the next apply
moves it. Per member it creates the new ServiceAccount, its token and the binding, points the hub's
cluster Secret at the new token, then deletes the old ServiceAccount and token Secret (only those
labelled `app.kubernetes.io/part-of=istio-scale-tests`; `kube-system` itself stays) and prints
which it removed, found missing or left. Argo CD switches at once. The other members' istiod keep the old token until External Secrets pushes the
new remote secret, up to about 10 minutes (the ExternalSecret and the PushSecret each refresh every
5): until then they log `watch error in cluster <member>: Unauthorized` and keep that member's last
endpoints, then reconnect without a restart (66 s and 4.5 minutes on the kind lab). Run no suite
until every istiod replica of every other member has logged
`stopping previous cluster <member> after new cluster synced` for each moved member
(`kubectl -n istio-system logs -l app=istiod --prefix --tail=-1 | grep 'stopping previous cluster'`;
`Update cluster` marks only the start of the switch): the wiring gate cannot see this, because
istiod's sync metric changes only when it reconnects.

At the end, the apply waits until Argo CD has rendered and compared everything it deploys, and
fails after `argocd_app_status_timeout_sec` (default 900; 0 disables), naming what is missing and
the fix. Every Application or ApplicationSet that an Application lists in its resources must exist
(the app-of-apps lists its child Applications, each child the ApplicationSet it deploys); each of
the repo's ApplicationSets that selects clusters must own an Application per mesh member (the
hub-side presets' Applications target the hub, so they are counted, not matched; the failure
gives `<k> of <N>` and the ApplicationSet's `ErrorOccurred` message); every mesh member must be the
destination of an Application; and every Application must have a sync and health status. The
ApplicationSets generate the member Applications minutes after the apply's own (on the kind lab
3 of 33 existed after 11 s). For a spoke with no Applications, check its Argo CD
cluster Secret (`kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster
--show-labels`: mesh members carry `istio-mesh-member=true`; on OpenShift also its ACM
PlacementDecision). Argo CD's errors are printed once each when first seen, so you can stop the
apply and fix them; they fail the check if they last until the deadline. When Argo CD cannot
load state from a member (its Applications are sync `Unknown` with `Failed to load live state` or
`failed to get cluster info`): the registered URL is unreachable from the hub
(`cluster_api_url_overrides`), or `Unauthorized` or `Forbidden` says the token is not accepted (see
[Rotating a member's token](#rotating-a-members-token)). Any other `ComparisonError` (a chart that
fails to render, a repository Argo CD cannot read) means that Application never deploys. A status
from before the apply never counts: the check asks Argo CD to refresh every Application once
(`argocd.argoproj.io/refresh=normal`) and waits until each has been compared again, naming any
that never is. It runs again on every apply that changes a member's registration or, on
`kubernetes`, the Argo CD release.

On OpenShift a second step guards Argo CD's controller sharding: once every cluster Secret exists,
the apply waits for the GitOps operator's own dynamic-scaling restart of the application controller
to settle, then restarts the controller pods once. A controller that starts while the Secrets
change can leave a cluster without a shard, and that cluster's Applications never get a status;
the fix by hand is the same restart:
`oc -n openshift-gitops delete pod -l app.kubernetes.io/name=openshift-gitops-application-controller`.
On `kubernetes` the controller runs a fixed number of replicas (the computed count, or
`argocd_helm_values`' `controller.replicas`), so nothing rescales it mid-apply, and the apply pins
each spoke to one: the `shard` key of the spoke's cluster Secret is its index in name order plus 1,
mod the replica count. The spokes spread round-robin, and the hub's own `in-cluster`, which has no
Secret, stays on shard 0, where round-robin (`kubernetesShardingAlgorithm` in
`charts/argocd-config`) puts it. Unpinned, Argo CD re-indexes its clusters whenever one is added or
removed, but a replica drops a cluster's cache only when that cluster's own Secret changes, so while
the Secrets arrive one at a time replicas keep caching clusters they no longer own. A pinned spoke
changes owner only when the apply updates its Secret, and the replica that owned it then drops its
cache. Adding or removing a spoke re-pins the spokes after it in name order, and a new replica count
re-pins most of them (the apply changes the replica count first: until it re-pins, a spoke whose pin
is at or above the new count sits on shard 0, and the controller logs
`is greater than the number of available shard`). With `gitops_install_operator = false` the apply
pins nothing (it does not know the existing Argo CD's replica count; restart its controller pods
after adding spokes, or pin the shards yourself) and drops a pin it wrote before; a `shard` key
someone else set stays, and the apply warns about it. The controller logs say
which replica owns which cluster (every replica logs the whole map):
`kubectl -n argocd logs argocd-application-controller-0 | grep -e 'assigned to shard' -e 'changed shard'`.

## Existing clusters

| Already installed on the hub | Set |
| --- | --- |
| Argo CD (`kubernetes`), in `gitops_namespace` | `gitops_install_operator = false` |
| cert-manager | `gitops_app_overrides = { "hub-cert-manager-operator" = { enabled = false } }` |
| ACM (`openshift`) | `acm_install_operator = false`, `acm_local_cluster_name = "local-cluster"` |
| OpenShift GitOps (`openshift`) | `gitops_install_operator = false` |

An existing Argo CD must run with the release name `argocd` (its controllers' ServiceAccounts are
`argocd-application-controller` and `argocd-applicationset-controller`, which the charts' RBAC
expects) and carry the settings `platform_gitops.tf` gives the chart (`argocd_upstream_values`):
the Sail health checks, the resource exclusions, round-robin sharding and git submodules off. With
`gitops_install_operator = false` nothing applies `argocd_helm_values`, so the plan warns when it
is set.

If the spokes are already ACM-managed (OpenShift), import their namespaces once before the first
apply: `terraform import 'kubernetes_manifest.spoke_namespace["<ctx>"]' "apiVersion=v1,kind=Namespace,name=<ctx>"`.

## Per-environment values

The chart defaults are sized for the 20-cluster campaign: about 12.2 CPU / 49 GiB of requests per
member (istiod's 3 replicas of 4 CPU / 16 GiB) and, on the hub, Argo CD's 3 CPU / 6 GiB plus 2 CPU /
4 GiB per controller replica, ceil((spokes + 1) / `argocd_clusters_per_shard`): 5 CPU / 10 GiB
for 2 members, 17 CPU / 34 GiB for 20. Override them per environment without forking:

- `gitops_app_overrides`: per child app `enabled` and `values` (for example a smaller istiod, a
  MetalLB pool for the gateways, or a chart mirror). See `terraform.tfvars.example`.
- `argocd_helm_values` (`kubernetes`): values for the `argo-cd` chart, merged over the repo's
  tuning (`charts/argocd-config/values.yaml`); for example smaller requests on a small hub.
  `argocd_config_values` is the same for the OpenShift GitOps ArgoCD CR. Keep the controller
  limit near 6Gi on a busy hub.
- `mesh_member_count`: how many spokes join the mesh, in sorted order (0 = all).
- Large fleets: `argocd_clusters_per_shard` (`argocd_max_shards` only on OpenShift; on
  `kubernetes` the replica count is the computed one unless `argocd_helm_values` sets
  `controller.replicas`, and the shard pins follow it).
- ROSA: the ingress gateway Service gets an AWS NLB (`rosa_ingress_nlb`, default true). Behind a
  Classic LB it aborted HTTP requests (each arrived followed by a FIN); the east-west gateway
  (mTLS passthrough) stays on a Classic LB. This default is merged under `gitops_app_overrides`,
  so an override of `spoke-ingress-gateway-appset` adds to it. A Service created as a CLB does not
  change type in place: delete it once and Argo CD recreates it as an NLB. On EKS set the same
  annotation yourself (`service.beta.kubernetes.io/aws-load-balancer-type: nlb`) through
  `gitops_app_overrides`.

The child apps sync from `gitops_app_repo_url` at `gitops_app_repo_revision`, so a fork or branch
deploys from itself. Edited charts roll out on the next apply.

## Rotating a member's token

On `kubernetes` the token in a member's Argo CD cluster Secret comes from the Secret
`argocd-gitops-token` (`<gitops_managed_service_account_name>-token`) in
`spoke_service_account_namespace` on the member. It never expires. Its claims are the
ServiceAccount's name and UID and the Secret's name, so with an RSA signing key (kind's and
kubeadm's) a recreated Secret brings back the same token. Recovering a deleted token Secret is
therefore a re-registration; rotating the token (revoking the old one) deletes the ServiceAccount
too:

```bash
# Rotate only: revoke the current token. Skip both lines to recover a deleted token Secret.
kubectl --context <ctx> -n istio-scale-tests-access delete secret argocd-gitops-token
kubectl --context <ctx> -n istio-scale-tests-access delete serviceaccount argocd-gitops
# Register the member again: ServiceAccount, token and binding, then the hub's cluster Secret.
terraform plan -replace='terraform_data.create_argocd_cluster_secret["<ctx>"]' -out=rotate.tfplan
terraform apply rotate.tfplan
```

The replace updates the hub's cluster Secret in place (deleting it would delete the member's
Applications), and the apply's status check runs again. While the member has no working token:

- Argo CD answers from its cache. Only an Application whose comparison needs a fresh call goes sync
  `Unknown` with `... Unauthorized`; the rest can read Synced/Healthy for minutes.
- Every other member's istiod logs `watch error in cluster <ctx>: Unauthorized` as its watches
  restart (each within 5 to 10 minutes) and keeps that member's last endpoints. The wiring gates
  stay Ready: istiod's sync metric changes only when it reconnects.
- The hub's PushSecrets go `Errored` with `could not write remote ref ... to target secretstore
  <ctx>-spoke-istio-system: Unauthorized` (`kubectl -n external-secrets-operator get
  pushsecrets`): nothing new reaches the member.

After the apply a recovered token, being the same, works everywhere at once (one that differs,
under another signing key type, goes the way of a rotated one). A rotated one works
for Argo CD at once and reaches the other members through External Secrets: the
`kubeconfig-<ctx>` ExternalSecret and the `push-remote-secret-<ctx>` PushSecret each refresh every
5 minutes, so within about 10 (17 seconds to 4.5 minutes on the kind lab). Each istiod replica
then reconnects without a restart: it logs `Update cluster` when it starts the new connection and
`stopping previous cluster <ctx> after new cluster synced` once that one has synced
(`kubectl -n istio-system logs -l app=istiod --prefix --tail=-1 | grep 'stopping previous cluster'`).
Run no suite before every replica of every other member has logged the second. On the kind lab
(Istio 1.30.5) one istiod went on logging `watch error in
cluster <ctx>: failed to list *v1.ConfigMap: Unauthorized` about once a minute for over 30 minutes
after that, from a watch the previous connection left behind, while `istioctl remote-clusters` read
`synced` and the member's endpoints stayed current. Restarting that member's istiod pods leaves
only the current connection; do it before a measured run, one pod at a time (`kubectl -n
istio-system delete pod <istiod-pod>`, then wait for its replacement to be Ready): `kubectl rollout
restart` starts a full set of new replicas first (maxSurge 100%), which needs room for as many more
istiod pods. On `openshift` the ACM ManagedServiceAccount issues and rotates the token.

## Tear down

`terraform destroy` deletes the Argo CD apps first, then uninstalls what Terraform installed. On
`kubernetes` it also deletes each spoke's Argo CD cluster Secret and its ServiceAccount, so no
cluster-admin token is left behind, and the `spoke_service_account_namespace` namespace when the
apply created it (never `kube-system` or a namespace without its label). For ROSA, then follow
`terraform/rosa-hcp/README.md`.

On an existing OpenShift hub (`acm_install_operator = false`) destroy keeps the MultiClusterHub and
the KlusterletConfig, but still deletes:

- the spoke ManagedClusters, unless `acm_keep_managed_clusters_on_destroy = true`;
- the spoke namespaces you imported. To keep them, first run
  `terraform state rm 'kubernetes_manifest.spoke_namespace'`;
- the OSSM operator on every spoke.

On OpenShift destroy leaves the Argo CD cluster Secrets, which hold spoke credentials. Delete them
afterwards: `oc -n openshift-gitops delete secret <spoke>-argocd-gitops-cluster-secret` per spoke,
or `oc -n openshift-gitops delete secret -l argocd.argoproj.io/secret-type=cluster` if that Argo CD
manages no other clusters.

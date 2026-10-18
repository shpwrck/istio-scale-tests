# Gateway API Multicluster Ingress Check

A read-only, on-demand check for one question about the multi-primary, multi-network mesh:

> Does an HTTPRoute need its backend Service in **every** member, even a member that runs no
> workload? Goal: a request that enters **any** member's ingress reaches the workload wherever
> it runs.

And a follow-up: does the ingress member need the backend's **namespace**, even without the
Service (S7–S9, with S7b as the "namespace yes, Service no" control)?

The check itself is deployed by GitOps
([`charts/mesh-verify-gateway-api`](../../charts/mesh-verify-gateway-api)): HTTPRoutes on every
member, the echo workload on one. [`001-run-ingress-check.sh`](001-run-ingress-check.sh) reads
what each member resolved, sends traffic through every member's ingress, and writes a report
that leads with both answers.

**Status:** confirmed in the lab on 2026-10-14 on OpenShift (OSSM 3.4.3): 22 of 22 rows matched
the predictions below, and Argo CD marks every HTTPRoute with `ResolvedRefs=False` as Degraded
([campaign record](../../docs/campaigns/2026-10-14-gateway-api-multicluster-lab.md)). Confirmed
again on 2026-10-18 on kind ([kind lab](../../docs/runbooks/kind-lab/README.md): upstream Istio
1.30.5 through the Sail operator 1.31.1, Gateway API v1.6.1 standard channel): 22 of 22 rows
matched.

## Answer (Istio 1.30.5, OSSM 3.4.3 and upstream; predicted from the source, confirmed in the lab 2026-10-14 and on kind 2026-10-18)

**For traffic, no. For the HTTPRoute status, yes.** An HTTPRoute attached to a Gateway routes to a
Service that exists only in another member; the only side effect is that the route's status on
the ingress member says the backend is missing. Citations are to the Istio 1.30.5 tree
(`gw/` = `pilot/pkg/config/kube/gateway/`).

- **Status.** istiod checks a `kind: Service` backendRef only against its own cluster's Service
  informer, not the multicluster registry (`gw/controller.go:185,200`). A missing Service sets
  `ResolvedRefs=False` / `BackendNotFound` (`gw/conversion.go:1164-1169`); `Accepted` stays
  `True` (`gw/conditions.go:154-167`). Upstream reports the same: istio/istio#60971 (open; its
  fix, #60984, was closed unmerged on 2026-10-04).
- **Traffic.** BackendNotFound is a soft error: the destination host is still built and kept
  (`gw/conversion.go:1011-1022`, `1262-1265`), and the ingress resolves it against the merged
  registry of every member (`pilot/pkg/serviceregistry/aggregate/controller.go:237-275`). EDS
  replaces the workload member's endpoints with its east-west gateway on 15443, when the endpoint
  is mTLS-capable, i.e. has a sidecar (`pilot/pkg/xds/endpoints/ep_filters.go:172-178`). A host
  that exists in no member gets Envoy's 500 (`pilot/pkg/networking/core/route/route.go:617-621`).
- **Sidecar scoping does not apply.** Gateways (proxy type Router) always get the default gateway
  scope and never select a `Sidecar` (`pilot/pkg/model/push_context.go:1178-1195`), so the mesh-wide
  root Sidecar and its `egressHosts` list (`charts/spoke-ossm`) do not narrow
  `istio-ingressgateway` (or the east-west gateway). Neither of the check's namespaces needs an
  `egressHosts` entry, and `spoke-ossm` is unchanged (PL38 does not apply).
- **What every ingress member does need locally:** the routing config (Gateway, HTTPRoute, and a
  ReferenceGrant if the backendRef crosses namespaces) in a namespace its discoverySelectors
  select, because routes are read from the local cluster only (`gw/controller.go:186-211`). For a
  `kind: Service` backend that means the backend's namespace, see the next section. The
  workload's namespace must carry `istio-discovery=enabled` on the workload member too: an istiod
  applies its own selectors to remote clusters (`pkg/kube/multicluster/cluster.go:225-227`).
- **Exception: GAMMA (mesh) routes**, whose parentRef is a Service: a missing local parent Service
  gives `Accepted=False` and nothing is programmed (`gw/conversion.go:636-652`).
- **Where "deploy the Service everywhere" comes from:** DNS for in-mesh clients. The ingress routes
  by Host header to an EDS cluster and never needs a local ClusterIP.

## Does the namespace have to exist locally? (S7–S9; confirmed in the lab)

S1–S5 keep every backend in `mesh-verify-gwapi`, which exists on every member, so they cannot
tell whether the ingress member needs the backend's **namespace**. S7–S9 put their backends in
`mesh-verify-gwapi-remote`, which exists on the workload member only; their routes stay in
`mesh-verify-gwapi`.

- **`kind: Service` (S7): yes, the namespace, though not the Service.** A backendRef into another
  namespace needs a ReferenceGrant in the backend's namespace, and istiod reads ReferenceGrants
  from its own cluster only (`gw/controller.go:209,242`;
  `pilot/pkg/config/kube/gatewaycommon/references.go:236-253`). A member without the namespace
  has no grant, so the backendRef is rejected with `RefNotPermitted` and an **empty** destination
  (`gw/conversion.go:1143-1152`). That becomes Envoy cluster `UnknownService`
  (`pilot/pkg/networking/core/route/route.go:350-354`) and Gateway API's 500 (`route.go:617-621`).
  Unlike BackendNotFound, nothing routes. The ingress still holds the backend's cluster and its
  east-west endpoint (`PILOT_FILTER_GATEWAY_CLUSTER_CONFIG` is off by default); only the route
  refuses it. The grant can only exist where its namespace exists, so with `kind: Service` the
  ingress member always needs the backend's namespace: either it holds the HTTPRoute
  (same-namespace reference, no grant; then S2 applies) or it holds the ReferenceGrant.
- **`networking.istio.io/Hostname` (S8): no.** It has no namespace field, so no grant check
  applies, and its lookup uses the route's namespace (`gw/conversion.go:1170-1177`):
  `ServiceIndex.HostnameAndNamespace[host][route namespace]`
  (`pilot/pkg/config/kube/gatewaycommon/context.go:162-163`), an index keyed by the Service's own
  namespace (`pilot/pkg/model/push_context.go:1573-1588`). A route outside the Service's namespace
  therefore reads `ResolvedRefs=False` / `BackendNotFound` on **every** member, the workload member
  too (istio/istio#62027). It is a soft error: the destination is still programmed and traffic
  flows.
- **Classic VirtualService (S9): no.** A VirtualService may name any host; there is no namespace
  or grant check.
- **The namespace and its grant without the Service (S7b): enough.** S7b's backend namespace
  `mesh-verify-gwapi-shared` exists on every member with a ReferenceGrant for the routes'
  namespace, while its Service and echo Deployment exist on the workload member only. The grant
  check passes locally; the local Service lookup misses, which is the soft BackendNotFound of S2
  (`gw/conversion.go:1143-1169`), and the host is returned with that soft error
  (`gw/conversion.go:1262-1265`). Predicted: `ResolvedRefs=False` / `BackendNotFound` on the other
  members and 200 from the workload member. S7 and S7b differ only in whether the namespace and the
  grant exist on the ingress member, so S7b is what makes S7's "yes" mean "the namespace, for the
  ReferenceGrant", not "the Service".

**Consequence for production (confirmed in the lab):** with `kind: Service` backendRefs, every ingress
member needs the backend's namespace (holding the HTTPRoute or a ReferenceGrant), though not the
Service (S7 vs S7b). Without a local namespace, the options are a `Hostname` backendRef (status
says `BackendNotFound` everywhere) or a classic VirtualService (no status at all).

## Scenarios and predictions

W = the workload member, O = every other member. "Status" is the HTTPRoute's
`Accepted`/`ResolvedRefs` from `istio.io/gateway-controller`. Each scenario has its own host, and
each backend Service serves one scenario (C2 reuses `echo-s2`: it tests the route, not the
backend), so no scenario can change another's merged Service entry. The same table, as data, is
`SCENARIOS` in the script; `tests/lib/test/gateway-api.bats` checks that the chart renders
exactly these routes, Services, namespaces, Deployments and ReferenceGrants, that the chart's
scenario set id (`mesh-verify-gwapi/scenario-set`, now `v3`) equals the script's `SCENARIO_SET`,
and that the chart's render still has the sha256 pinned for that set (`RENDER_PIN` in the bats
file). A change to the chart's output fails CI until the set is bumped: `SCENARIO_SET` in the
script, `scenarioSet` in `_helpers.tpl` and `version` in `Chart.yaml` (`v3` = `0.3.0`) together,
then `RENDER_PIN` to the new set and the sha256 the failing test prints. Never update the sha256
alone.

| ID | Host | Route → backend | Service exists on | Status on O | HTTP via O | HTTP via W | Endpoints via O | Confidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | `s1.classic.test` | classic Gateway + VirtualService → `echo-s1` | W | (no status) | 200 from W | 200 | `remote-ewgw:15443` | high |
| S2 | `s2.gwapi.test` | HTTPRoute → Service `echo-s2` | W | `ResolvedRefs=False:BackendNotFound` | 200 from W | 200 | `remote-ewgw:15443` | high (status), medium (traffic) |
| S3 | `s3.gwapi.test` | HTTPRoute → Service `echo-s3` | every member (stub on O) | `ResolvedRefs=True` | 200 from W | 200 | `remote-ewgw:15443` | high |
| S4 | `s4.gwapi.test` | HTTPRoute → `networking.istio.io/Hostname` `echo-s4.<ns>.svc.cluster.local` | W | `ResolvedRefs=True` (after istiod's first push) | 200 from W | 200 | `remote-ewgw:15443` | medium-high (status) |
| S5 | `s5.gwapi.test` | HTTPRoute → `multicluster.x-k8s.io/ServiceImport` `echo-s5` | W | `ResolvedRefs=False:BackendNotFound` | 200 from W | 200 | `remote-ewgw:15443` | high |
| S7 | `s7.gwapi.test` | HTTPRoute → Service `mesh-verify-gwapi-remote/echo-s7`, ReferenceGrant there | W, namespace too | `ResolvedRefs=False:RefNotPermitted` | 500 | 200 | `remote-ewgw:15443` | high |
| S7b | `s7b.gwapi.test` | HTTPRoute → Service `mesh-verify-gwapi-shared/echo-s7b`, ReferenceGrant there | W (namespace and grant on every member) | `ResolvedRefs=False:BackendNotFound` | 200 from W | 200 | `remote-ewgw:15443` | high |
| S8 | `s8.gwapi.test` | HTTPRoute → `networking.istio.io/Hostname` `echo-s8.mesh-verify-gwapi-remote.svc.cluster.local` | W, namespace too | `ResolvedRefs=False:BackendNotFound` (W too) | 200 from W | 200 | `remote-ewgw:15443` | medium-high |
| S9 | `s9.classic.test` | classic VirtualService → `echo-s9.mesh-verify-gwapi-remote` | W, namespace too | (no status) | 200 from W | 200 | `remote-ewgw:15443` | high |
| C1 | `neg.gwapi.test` | HTTPRoute → Service `echo-none` | nowhere | `ResolvedRefs=False:BackendNotFound` (W too) | 500 | 500 | `none` | high |
| C2 | `s6.gwapi.test` | HTTPRoute on W only → Service `echo-s2` | W | (no route) | 404 | 200 | – | medium-high |

Every `Accepted` is predicted `True`. Through W's own ingress every route resolves (except C1, and
S8, whose route is outside its Service's namespace) and answers from the local pod (`direct`: any
endpoint port but 15443), with no east-west hop. On O, a `direct` endpoint would mean the ingress
got W's pod address instead of W's east-west gateway, i.e. it lacks W's network metadata (a
multi-network misconfiguration), not a stray local pod. C2 uses host `s6.gwapi.test`, a host of
its own so its route cannot merge with S2's on the workload member; there is no scenario S6.
S7's 500 through O comes from the route, not from missing endpoints: the ingress still holds
`echo-s7`'s cluster with W's east-west endpoint. S3's stub contributes no endpoints; the merge
keeps the first-seen ports, so the stub comes from the same template as the real Service. S5:
with `ENABLE_MCS_HOST=false` (the default) a ServiceImport is handled exactly like
`kind: Service`, and no ServiceImport CRD or object is read.

## The chart

[`charts/mesh-verify-gateway-api`](../../charts/mesh-verify-gateway-api), synced to every member
by the placement ApplicationSet (preset `values-mesh-verify-gateway-api.yaml`), like
`mesh-verify`:

- Namespace `mesh-verify-gwapi` (`istio.io/rev: default`, `istio-discovery: enabled`).
- Gateway API `Gateway` `istio-system/mesh-verify-gwapi`, bound to the existing
  `istio-ingressgateway` (manual deployment: one `Hostname` address, so no new Deployment and no
  new LoadBalancer IP). Listener port 80 (the Service port; Envoy listens on 8080), hosts
  `*.gwapi.test`, routes only from the test namespace. It must live in `istio-system`, because a
  Gateway binds only to Services in its own namespace.
- The classic `Gateway` with S1's and S9's `VirtualService`s, the HTTPRoutes, the Services (one
  template, so the S3 stub is byte-identical), and, on the workload member only, the
  sidecar-injected `hashicorp/http-echo` Deployment `gwapi-echo`, whose body is the member's
  cluster name.
- On the workload member only: namespace `mesh-verify-gwapi-remote` (`remoteNamespace`, same
  labels; the label is what lets the other members' istiods discover its Services) with a second
  `gwapi-echo` Deployment, Services `echo-s7`, `echo-s8`, `echo-s9`, and ReferenceGrant `s7`
  (HTTPRoutes from `mesh-verify-gwapi` to Service `echo-s7`).
- On every member: namespace `mesh-verify-gwapi-shared` (`sharedNamespace`, same labels) with
  ReferenceGrant `s7b` (HTTPRoutes from `mesh-verify-gwapi` to Service `echo-s7b`); on the
  workload member also a third `gwapi-echo` Deployment and Service `echo-s7b` there.
- The scenario set id, annotation `mesh-verify-gwapi/scenario-set` on every namespace and on the
  Gateway API Gateway (`_helpers.tpl`, not a value). The script records it per member and marks a
  member that runs another set (`SCENARIO_SET_MISMATCH`).
- `workloadCluster` (the workload member's cluster name, below) decides where the
  Deployments, the workload-only Services, the backend namespace and C2 go. Empty, or the
  `<workload-cluster>` placeholder, fails every member's render with a message rather than
  deploying a check without a workload; a render with no `clusterName` (CI's `helm lint`) shows
  what a member without the workload gets.

## Deploy

Needs the Gateway API CRDs on every member, ReferenceGrant included (the script stops when
HTTPRoute is missing), and the `istio` GatewayClass, which istiod creates. Kubernetes does not
ship the CRDs: install the standard channel on every member, at a version your Istio supports.
The check was confirmed with v1.6.1 (the release cloud-provider-kind v0.12.0 installs on kind):

```bash
kubectl --context <member-ctx> apply --server-side \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
```

The preflight records the bundle version each member has. Recent OpenShift releases install the
standard channel through the ingress operator.

1. Pick the workload member. A member's cluster name is its Argo CD cluster name: the kubeconfig
   context it was registered with (`terraform -chdir=terraform/platform output
   mesh_member_spoke_keys` lists them), which on OpenShift is also its ACM ManagedCluster name.
2. Read what the hub syncs the mesh from. [`charts/mesh-verify-gateway-api-appset.yaml`](../../charts/mesh-verify-gateway-api-appset.yaml)
   keeps five placeholders: `<repo-url>`, `<revision>`, `<platform>`, `<gitops-namespace>` and
   `<workload-cluster>`. `fill` fills them in on the way to the hub, so the check runs the same
   charts as the mesh and the cluster name never lands in git.

   ```bash
   NS=argocd PLATFORM=kubernetes   # OpenShift: NS=openshift-gitops PLATFORM=openshift
   WORKLOAD=<member-cluster-name>
   read -r REPO REV < <(kubectl --context <hub-ctx> -n "$NS" get application hub-gitops-root \
     -o jsonpath='{.spec.source.repoURL} {.spec.source.targetRevision}')
   fill() { sed -e "s|<repo-url>|${REPO:?}|g" -e "s|<revision>|${REV:?}|g" \
     -e "s|<platform>|${PLATFORM:?}|g" -e "s|<gitops-namespace>|${NS:?}|g" \
     -e "s|<workload-cluster>|${WORKLOAD:?}|g" charts/mesh-verify-gateway-api-appset.yaml; }
   ```

3. Apply it on the hub, and wait for the per-member Applications:

   ```bash
   fill | kubectl --context <hub-ctx> apply -f -
   kubectl --context <hub-ctx> get applications.argoproj.io -n "$NS" | grep mesh-verify-gwapi
   ```

   An Application may report `Degraded`: C1's missing backend is intentional, and Argo CD may
   read S2/S5/S7b/S8's `BackendNotFound` and S7's `RefNotPermitted` the same way (S8 on the
   workload member too). Whether it does is one of the things the run records (`--hub-context`).

## Run

```bash
tests/gateway-api/001-run-ingress-check.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> \
  --workload-context <mesh-b-ctx> --hub-context <hub-ctx> --dry-run
tests/gateway-api/001-run-ingress-check.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> \
  --workload-context <mesh-b-ctx> --hub-context <hub-ctx>
```

`--contexts` lists mesh members only (at least two); `--workload-context` is the member whose
cluster name is the chart's `workloadCluster`. The script deploys nothing, prints where its
results will go, and:

1. **Preflight**, per member, recorded in the TSV preamble (`unset` = Istio's default; `unknown`
   = the read failed, never a guessed value):
   - the Gateway API CRD bundle version, GatewayClass `istio` (controller, Accepted), the
     namespace labels, and the scenario set the chart stamped (`SCENARIO_SET[ctx]`);
   - istiod's overrides of `PILOT_ENABLE_GATEWAY_API`, `PILOT_ENABLE_GATEWAY_API_STATUS`,
     `PILOT_GATEWAY_API_CONTROLLER_NAME`, `ENABLE_GATEWAY_API_MANUAL_DEPLOYMENT`,
     `PILOT_FILTER_GATEWAY_CLUSTER_CONFIG`, `PILOT_SCOPE_GATEWAY_TO_NAMESPACE`,
     `PILOT_MULTI_NETWORK_DISCOVER_GATEWAY_API`, `ENABLE_MCS_HOST`, `ENABLE_MCS_SERVICE_DISCOVERY`
     and `ENABLE_MCS_CLUSTER_LOCAL`;
   - the builds that ran: istiod's `discovery` image (`ISTIOD_IMAGE`), the ingress `istio-proxy`
     image (`INGRESS_PROXY_IMAGE`), each as the image's last path component plus the digest that
     ran (the registry host and path are dropped; several are `+`-joined), and the operator build
     (`OSSM_OPERATOR`, shown as "Operator build": on OpenShift the OSSM CSV, such as
     `servicemeshoperator3:3.4.3/Succeeded`; on Kubernetes the Sail operator's image tag, the
     digest its pod runs and its state, such as `sail-operator:1.31.1@sha256:<digest>/Available`;
     `absent` only when the platform's own operator read answers with none on a platform asked
     of the member; `unknown`, with a warning, when the platform or that read is unknown, or
     when `TEST_PLATFORM` set the platform and that read found none); the Istio CR version and
     the tuning baseline;
   - the platform record every suite writes (`tests/lib/platform.sh`): `PLATFORM`,
     `TEST_PLATFORM` and, per member, `PLATFORM_BY_CONTEXT`, `MESH_OPERATOR_BY_CONTEXT`,
     `ISTIOD_IMAGE_BY_CONTEXT`, `PROXY_IMAGE_BY_CONTEXT` and `NODE_PROVIDER_BY_CONTEXT` (the nodes'
     providerID scheme: `kind`, `aws`, ...). `TEST_PLATFORM` (`config/options.env`, default
     `auto`) picks each member's platform: `auto` asks the member (it serves
     `security.openshift.io/v1` on OpenShift), `kubernetes` or `openshift` is taken as given, and
     any other value stops the run;
   - the ingress replica count (`INGRESS_REPLICAS`) and the istiod and ingress pods' start times
     and restart counts (for `ISTIOD_RESTARTED` / `INGRESS_RESTARTED`, below);
   - the echo Deployments (Ready and sidecar-injected on the workload member, absent elsewhere),
     namespace `mesh-verify-gwapi-remote` (expected on the workload member only), namespace
     `mesh-verify-gwapi-shared` and its ReferenceGrant `s7b` (expected on every member), and the
     backend Services in both shared namespaces (`BACKEND_SERVICES[ctx]`).

   It stops, writing nothing, when a member answers none of these reads (a mistyped context, an
   API server it cannot reach, no access; the first read is retried once before that, so one slow
   API server is not a dead member; the message quotes kubectl's first error), when the check
   is not deployed (a backend namespace missing on the workload member included), or when
   `--workload-context` names the wrong member. A read that fails on its own is a warning with
   kubectl's error. These do not stop the run; the rows that depend on them become `UNKNOWN`:
   - the S7–S9 namespace on another member, or an unreadable one (`NS_SCENARIO_INVALID` /
     `NS_SCENARIO_UNVERIFIED`), and likewise S7b's namespace or ReferenceGrant missing there;
   - a backend Service where the scenario assumes none (S1, S2, S4, S5, S7b, C1 on another member),
     or S3's stub missing there (`SVC_SCENARIO_INVALID` / `SVC_SCENARIO_UNVERIFIED`). The Service is
     read directly, not inferred from `BackendNotFound`, which an upstream fix for #60971 would
     turn `True`;
   - a member whose deployed scenario set is not the script's `SCENARIO_SET`
     (`SCENARIO_SET_MISMATCH`: "the deployed chart is not the version this script expects"; on the
     workload member, which holds every backend, every member's rows). An unreadable stamp is not a
     match either: `SCENARIO_SET_UNVERIFIED`, which leaves a match standing but makes a deviation
     `UNKNOWN` and keeps a failure out of the answers.
2. **Waits** up to `--wait-timeout` (180 s) for the Gateway's `Programmed=True`, the three echo
   Deployments and istio's status on every route (progress `[elapsed/bound s] pending: …` when it
   changes; `WAIT_SEC` is how long it took). Rows still without status say `STATUS_TIMEOUT`. Then
   the **data-plane gate**: a settled control plane does not mean every ingress has W's east-west
   endpoint yet. Each round requests S1 (classic) and S3 (HTTPRoute with a local stub Service),
   whose 200s depend on neither question, through every ingress; S3's also shows the Gateway API
   listener and routes reached that ingress. The gate passes after `GWAPI_GATE_PASSES` (3) rounds
   in a row in which both answer 200 with the echo text (curl may reach any ingress replica, and
   each istiod replica pushes on its own), one round per second. The same deadline ends it at the
   first failed round after it; a streak already under way may finish. Then `GWAPI_SETTLE_SEC`
   (5 s) more for the other backends (`SETTLE_SEC`). `DATAPLANE_GATE_SEC` is the gate's own
   duration, without the settle. `DATAPLANE_READY_SEC[ctx]` is the time from the gate's start until
   that ingress passed, to within one round (1 s plus curl's latency); it includes the
   `GWAPI_GATE_PASSES` − 1 confirming rounds, so an ingress ready from the start reads about 2 s
   with the default 3. `timeout`: never; `unknown`: no ingress address. Each ingress prints one
   line when it passes. A member that timed out has `DATAPLANE_NOT_READY` rows, and the warning
   says "no HTTP answer from this ingress" when no request got one.
3. **Traffic:** `--requests` (10) requests per member ingress × scenario host (`curl -H "Host: …"`),
   with `--timeout` (5 s) each, between `TRAFFIC_START` and `TRAFFIC_END` (UTC). Below 3 requests
   the run warns: a YES would rest on that few. The ingress address comes from the LoadBalancer
   status, or `--ingress CTX=ADDR[:PORT]` (recorded as `override:port=N`, never the address). A cell
   with a timed-out request gets one more request with `GWAPI_DETAIL_TIMEOUT_SEC` (35 s): Envoy
   answers a dead east-west hop only after 3 × 10 s connect timeouts (one try plus Istio's default
   two retries), so the long timeout records Envoy's own verdict instead of a client timeout, and
   only once per such cell. Then the **re-probe**: the gate covers the main namespace's echo pod
   only, and the S7–S9 and S7b pods are others whose endpoints can reach an ingress later. Every
   cell that did not answer 200 with the echo text on every request gets `--requests` more after
   `GWAPI_REPROBE_DELAY_SEC` (15 s; `REPROBE_DELAY_SEC`; `REPROBE_CELLS` counts them) when it was
   predicted 200, or when its failure makes a YES although predicted (S7 through the other
   members), so every YES rests on two probes. Not through an ingress whose gate never passed
   (its rows are tainted already). `detail` records the re-probe's codes. If it passes then, the
   row says `LATE_ENDPOINT`: predicted 200, the row is `UNKNOWN`, never a deviation, and the cell
   counts as answered for a NO; S7 answering then is unclear. If it fails again,
   `REPROBE_FAILED`. Either way its failure counts toward a YES only when the re-probe repeats it,
   and a re-probe that left no record (`REPROBE_NO_RECORD`) confirms nothing.
4. **Endpoint evidence** (best effort; skipped by `--skip-proxy-config` or without `istioctl`):
   one `istioctl proxy-config endpoints` dump per ingress (limit `GWAPI_ISTIOCTL_TIMEOUT_SEC`),
   from the first Running ingress pod (`PROXY_CONFIG_POD`; curl may reach any replica), filtered
   in one `jq` pass for each backend's `outbound|8080||<FQDN>` cluster: a class (`direct`,
   `remote-ewgw:15443`, `mixed`, `none`), a count and a healthy count. Addresses are never recorded.
   At most 4 ingresses are read and parsed at once: istioctl decodes Envoy's whole cluster dump, and
   one `jq` pass over a 20k-cluster dump peaks near 0.5 GB on the host running the script. So on a
   large mesh the last ingresses are read a few rounds after the first. The parse has the same
   limit as the read, each dump is deleted once parsed, and an ingress whose turn does not come
   within ⌈members / 4⌉ × 2 × that limit reads `timeout`.
5. **Argo CD health** (best effort; `--hub-context` only): each per-member Application's health,
   sync and synced git revision, and the health of its HTTPRoutes. The revision is the chart
   content that was deployed (`CHART_REVISION`; `HARNESS_SHA` only describes the script); when it
   is not the script's commit the run warns and records `CHART_REVISION_VS_HARNESS=differs`
   (`same` when it is, `same-dirty` when it is but the script's tree has uncommitted changes).
6. Rereads the route status (S4's status depends on istiod's push timing; a route that was not
   in place when the wait ended, or whose status was unread then, but is in place now says
   `STATUS_CHANGED`; `detail` keeps the status the wait ended on) and the istiod and ingress pods
   (`ISTIOD_RESTARTED` / `INGRESS_RESTARTED`: `1` = a pod restarted, was replaced or added during
   the run, `0` = unchanged, `unknown` = a read failed, which flags the rows
   `*_RESTART_UNVERIFIED`). An ingress pod still Pending at the preflight (an HPA scale-out) gets
   its start time later and reads as restarted: the safe side, `UNKNOWN` rather than a verdict on
   a moving replica set. Then it writes
   `<results-dir>/run-<RUN_ID>/`: `gateway-api-<RUN_ID>.tsv`, `summary-<RUN_ID>.md`,
   `argocd-<RUN_ID>.tsv` with `--hub-context`, and `run-config-<RUN_ID>.env` (a copy of the run
   config) with `--config`.

A failed best-effort step prints its reason and the run goes on. Response bodies and error text are
masked (`reach_sanitize`: IPs and host names); context names are recorded as given.

**Exit status:** 0 whenever the report is written, whatever the answers (read the summary, not the
exit code); 1 on an argument error, a member that answers no preflight read, or a check that is
not deployed, and then nothing is written.

## Read the report

The summary starts with two answers. Each one keeps its label in every outcome (`… NO`, `… YES`,
`… INCONCLUSIVE`), and an INCONCLUSIVE says how the other members split and why. A YES must be the
specific failure the hypothesis predicts, through a route in place for the whole traffic window,
for a scenario that works through the workload member; anything else is INCONCLUSIVE with the
reason. A failure counts only as Envoy's empty-bodied reply for a dropped destination, on every
request, repeated by the re-probe (every YES rests on two probes):

- **HTTPRoute: 500 with an empty body.** An empty or unknown destination has no Envoy cluster, and
  Gateway API routes answer that with `ClusterNotFoundResponseCode=INTERNAL_SERVER_ERROR`
  (`route.go:617-621`), a local reply without a body. C1 is the reference: a 500 counts only where
  C1 answered the same empty-bodied 500 through the same ingress. A 500 with a body is not that
  reply. For S7 the 500 must be the missing ReferenceGrant's: its route reads `RefNotPermitted`
  after the traffic, else INCONCLUSIVE with the status it read. A 503 means the ingress has the
  backend's cluster but no healthy endpoint (EDS lag or the east-west path: the destination was
  kept), and a 404 means the route had not reached that ingress's Envoy. All of these are
  INCONCLUSIVE.
- **Classic VirtualService: 503 with an empty body** (Envoy's NC: no cluster for the host). A 503
  `no healthy upstream` (UH: the cluster is there, its endpoints are not) is INCONCLUSIVE.
- **The re-probe must repeat it.** Every such failure was re-probed (step 3): on a cell predicted
  200, and S7 through the other members, predicted 500. It counts only when the re-probe failed by
  the same rule; a re-probe that left no record confirms nothing. A re-probe that answered
  otherwise makes it INCONCLUSIVE, "the failure was not stable": a 500 and then a 503 means the
  cluster appeared, i.e. the remote Service was discovered late, not dropped. A cell predicted 200
  that answered 200 with the echo text only on the re-probe (`LATE_ENDPOINT`) counts as answered
  for a NO, and the NO says how many members answered only then; it never counts as a failure (S7
  answering only then is INCONCLUSIVE). Where the workload member's own cell or a reference
  answered only on the re-probe, the INCONCLUSIVE says so.

The first answer, from S2 and S3:

- **NO** (no Service needed for traffic): S2 answered 200 with the workload's echo text, on every
  request, through every other member's ingress, and the preflight read no `echo-s2` there.
- **YES**: through every other member's ingress S2 returned 500 on a route in place for the whole
  traffic window (`Accepted=True` both when the wait ended and after the traffic, no `STATUS_*`
  flag), on a path with no taint (gate passed, no late endpoint, no restart, verified), and
  again on the re-probe, while S2 answered 200 through the workload member itself, C1 answered
  an empty-bodied 500 through the same other-member ingress, and S3 (the same route plus a stub
  Service) answered 200 from the workload member. It lists the codes per member, the re-probe's
  codes, and says what they mean.
- **INCONCLUSIVE**: anything else, with the reason: S2's route not in place for the whole window,
  another code than an empty-bodied 500 (with what it means), a re-probe that did not repeat the
  failure or left no record, S2 failing through the workload member too (or answering there only on
  the re-probe), C1 not answering an empty-bodied 500, S2 failing where S7b, on the same code path
  (its grant passes, the local Service lookup misses, a soft error), answered 200, also only on
  the re-probe ("contradicts S7b"), S2 and S3 both failing (S1 answering means the Gateway API
  path is broken; S1 failing too, the cross-cluster path: check mesh-verify and the east-west
  gateways), a Service where none belongs or no S3 stub, another or an unreadable scenario set, an
  ingress without an address or an answer, a data path that was not ready, a late endpoint, a
  restart during the run or one that could not be checked, members that disagree, or an unknown
  echo text.

When the echo Deployment's `-text` could not be read, the expected body is the workload ingress's
own most frequent answer in the run (`EXPECTED_BODY_SOURCE=local-answer`), and the answer says so.

The second, "Local namespace needed on the ingress cluster", has one line per backend kind, each
judged through every other member's ingress, which has no `mesh-verify-gwapi-remote`:

- `kind: Service` from S7, `Hostname` from S8, classic VirtualService from S9.
- **NO**: the scenario answered 200 with the workload's echo text on every request.
- **YES**: it failed with the code above, on both probes, under the same conditions as the first
  answer's YES (route in place for the whole window, no taint, 200 through the workload member, C1's
  empty-bodied 500 for an HTTPRoute; for S7 a route that reads `RefNotPermitted` after the
  traffic), while another scenario with its backend in the same namespace (S9/S8 for S7, S9 for
  S8, S8 for S9) answered 200 through the same ingress, so the failure is the kind's own. For
  `kind: Service`, the line adds S7b: "it needs the namespace (for the ReferenceGrant) but not the
  Service" when S7b answered 200; "S7b failed like S2 … consistent with the first answer, so it
  needs the Service too" when S7b failed through every other member and the first answer is YES;
  else whether the Service is needed too stays INCONCLUSIVE with S7b's reason.
- **INCONCLUSIVE**, with the reason: all of them failed (S7b or S1 answering means the path to the
  backend namespace is broken: check its `istio-discovery` label on the workload member, whether
  the echo pod there has a sidecar, and whether its endpoints were pushed yet; both failing, the
  cross-cluster path), a reference that answered only on the re-probe, members disagree, any of
  the first answer's reasons, or a precondition does not hold (a member has the namespace itself,
  or it could not be read).

Then the S2 status and the S7–S9 and S7b results on each other member, the MATCH/DEVIATION/UNKNOWN
counts (with "endpoints not read: N rows" when the endpoint evidence was skipped or failed), Argo
CD health, the matrix, every row that is not MATCH with its prediction and confidence, the
preflight tables (state, builds, pods, readiness), and the run settings. The YAML frontmatter
repeats every TSV preamble line.

**Comparing re-runs:** each run writes a fresh `run-<RUN_ID>/`. Runs whose preambles match on
`GWAPI_SCHEMA` (the rules that turn codes into answers), `SCENARIO_SET` (and `SCENARIO_SET[ctx]`),
`PLATFORM`, `ISTIOD_IMAGE`, `OSSM_OPERATOR` and the knobs that shape a verdict (`REQUESTS`, `TIMEOUT_SEC`: a
reply slower than it is `000`, `GATE_PASSES`, `SETTLE_SEC`, `REPROBE_DELAY_SEC`) have comparable
verdicts and answers; their codes and timings (`DATAPLANE_READY_SEC`, `WAIT_SEC`) will differ.

TSV (`GWAPI_SCHEMA=5`; 21 tab-separated columns), one row per member × scenario: `run_id
ingress_ctx role scenario kind host route backend expected_status observed_status expected_code
observed_codes expected_body body_match top_body expected_endpoints observed_endpoints
endpoints_healthy verdict row_status detail`. Schema 2 added S7b, the `direct` endpoint class
(schema 1: `local-pod`), the precondition, scenario-set, data-plane and restart flags, and their
preamble keys. Schema 3 changed what counts toward an answer (above), added the
`STATUS_CHANGED`, `LATE_ENDPOINT`, `REPROBE_FAILED` and `*_UNVERIFIED` flags, the preamble keys
`DATAPLANE_GATE_HOSTS` (was `DATAPLANE_GATE_HOST`), `GATE_PASSES` and `REPROBE_CELLS`, and
`DATAPLANE_GATE_SEC` no longer includes the settle. Schema 4 changed what counts again: a
failure needs its re-probe to repeat it, an HTTPRoute's 500 needs an empty body, and a cell that
answered only on the re-probe counts as answered for a NO. The re-probe waits
`GWAPI_REPROBE_DELAY_SEC` (preamble `REPROBE_DELAY_SEC`; schema 3 reused the settle) and skips
ingresses whose gate never passed; `detail` always has the re-probe's codes and, after a status
change, the status the wait ended on. Schema 5 re-probes S7 through the other members too
(`REPROBE_CELLS` counts it), so every YES rests on two probes; S7's failure counts only on a route
that reads `RefNotPermitted` after the traffic; C1 is the 500 reference only with empty bodies;
and a queued cell whose re-probe left no record is unclear (`REPROBE_NO_RECORD`). The columns are
unchanged.

- `backend` is the backendRef as the chart writes it; a backend in another namespace as
  `Service mesh-verify-gwapi-remote/echo-s7`.
- `expected_status` / `observed_status`: `Accepted=<s>[:<reason>]/ResolvedRefs=<s>[:<reason>]`
  from istio's parent entry for the Gateway, read after the traffic; for a classic route
  `present`; `absent` = no route on that member (C2 off the workload member); `no-status` = the
  route exists but istio wrote no status for it; `stale` = the status is for an older generation;
  `unknown` = the read failed. `detail` notes a status that differs from the one the wait ended on
  ("unread" when that read failed).
- `expected_code`: one code; `observed_codes`: `code:count` by count (`200:10`, `200:7,503:3`),
  `000` = no HTTP answer within `--timeout`, `-` = not probed (no ingress address, an unreachable
  ingress). `expected_body`: the workload's echo text when 200 is expected, else `-`.
- `body_match`: `yes`, `no`, `partial:k/n`, `n/a` (no 200s), `unknown` (the echo text is unknown),
  or `-` (not probed, or no 200 expected or seen). It is also filled for unexpected 200s (S7
  answering through another member), which then deviate on the code alone. `top_body`: the most
  frequent first body line, masked (`-` = empty).
- `expected_endpoints` / `observed_endpoints`: `direct`, `remote-ewgw:15443`, `mixed`, `none`;
  expected `-` = not judged (C2 off the workload member); observed `skipped` (no evidence:
  `--skip-proxy-config` or no istioctl), `unknown` (istioctl failed: its error is printed) or
  `timeout` (the dump or its parse took longer than `GWAPI_ISTIOCTL_TIMEOUT_SEC`, or its turn
  did not come: raise it on a large mesh).
  `endpoints_healthy`: `healthy/total` endpoints, `-` when not read; it is recorded, not judged.
- `verdict`: `UNKNOWN` if a precondition does not hold (the "voids" flags below), whatever was
  observed; else `DEVIATION` if any checked part differs from the prediction, unless a "taints"
  flag explains it (then `UNKNOWN`, with the reason in `detail`); else `UNKNOWN` if a part could not
  be observed; else `MATCH`. A tainted row's MATCH stays a MATCH (it was observed regardless), but
  its failure never counts toward an answer. Endpoints count only when they were read.
- `row_status`: `OK`, or a comma list of these flags:

  | Flag | Meaning | Effect |
  | --- | --- | --- |
  | `SCENARIO_SET_MISMATCH` | the member (or W) runs another scenario set than the script | voids |
  | `SCENARIO_SET_UNVERIFIED` | the member's (or W's) scenario set stamp could not be read | taints |
  | `NS_SCENARIO_INVALID` | S7–S9: the member has `mesh-verify-gwapi-remote`; S7b: it lacks `mesh-verify-gwapi-shared` or its grant | voids |
  | `NS_SCENARIO_UNVERIFIED` | that namespace or grant could not be read | voids |
  | `SVC_SCENARIO_INVALID` | the backend Service is there, or not, against the scenario's assumption | voids |
  | `SVC_SCENARIO_UNVERIFIED` | the member's Services could not be read | voids |
  | `STATUS_TIMEOUT` | the route still had no current status when the wait timed out | taints |
  | `STATUS_PENDING` | the wait ended in time, but the final read found no current status | taints |
  | `STATUS_UNREADABLE` | the final route read failed | unknown status |
  | `STATUS_CHANGED` | not in place (or unread) when the wait ended, in place by the final read | taints |
  | `NO_INGRESS_ADDR` | no ingress address (LoadBalancer pending, no `--ingress`) | not probed |
  | `INGRESS_UNREACHABLE` | no request through that ingress got an HTTP answer (from here) | not probed |
  | `NOT_PROBED` | the cell's traffic produced no record | not probed |
  | `CURL_TIMEOUT` | some requests got no answer in `--timeout`; the detail request is in `detail` | none |
  | `LATE_ENDPOINT` | failed during the traffic, answered on the re-probe | taints; answered for a NO (S7: unclear) |
  | `REPROBE_FAILED` | failed during the traffic and on the re-probe (codes in `detail`) | none; counts if both fail alike |
  | `REPROBE_NO_RECORD` | queued for the re-probe, which left no record | none; its failure does not count |
  | `PROXY_CONFIG_FAILED` | the endpoint evidence could not be read (`unknown`/`timeout`) | none: endpoints not judged |
  | `DATAPLANE_NOT_READY` | the data-plane gate never passed through that ingress | taints |
  | `ISTIOD_RESTARTED` / `INGRESS_RESTARTED` | a pod restarted, was replaced or added during the run | taints |
  | `ISTIOD_RESTART_UNVERIFIED` / `INGRESS_RESTART_UNVERIFIED` | whether one did could not be read | taints |

  "Voids": the row is `UNKNOWN` and cannot count for or against an answer. "Taints": a deviation
  becomes `UNKNOWN`, and a failure there does not count. "Not probed": no traffic, so `UNKNOWN`.
  "Unknown status": the status part is `UNKNOWN`, a code that differs still makes a `DEVIATION`,
  and the row never counts toward an answer (its route is not shown in place).
- `detail`: the reasons, `; `-separated, or `-`.

## What the lab run must confirm

1. A's ingress programs B's endpoints for S2, S4 and S5: only `remote-ewgw:15443` endpoint(s),
   healthy (`observed_endpoints`; on ROSA the east-west NLB hostname resolves to several
   addresses, so several 15443 endpoints). By hand:
   `istioctl --context <mesh-a-ctx> -n istio-system pc endpoints deploy/istio-ingressgateway
   --cluster 'outbound|8080||echo-s2.mesh-verify-gwapi.svc.cluster.local'`.
2. Routes and the 500 semantics: `istioctl … pc routes deploy/istio-ingressgateway --name http.8080
   -o json` shows s2–s5 pointing at `outbound|8080||echo-sN…` with `clusterNotFoundResponseCode`
   `INTERNAL_SERVER_ERROR`, s1 without it, and s3 identical to s2.
3. The status matrix on both members, including S4's push-timing caveat (`detail` notes a status
   that changed during the run).
4. Traffic: S1–S5 answer 200 from the workload through every ingress, C1 500, C2 404 off the
   workload member. The ingress access log (on: `charts/spoke-ossm/templates/istio.yaml`) names
   the east-west gateway as the upstream.
5. OSSM 3.4.3 matches upstream 1.30.5: no istiod overrides (preamble `ISTIOD_ENV`), GatewayClass
   `istio` Accepted, the Gateway Programmed. If S2 returns 500 instead of 200, a downstream patch
   to the local check is the first suspect.
6. Argo CD: is the S2/S5 Application on a member without the workload Degraded? Confirmed
   2026-10-14 on OpenShift GitOps: every HTTPRoute with `ResolvedRefs=False` is Degraded (S2, S5,
   S7, S7b, S8, C1 on the other member; S8 and C1 on the workload member too).
7. No regression: mesh-verify still answers from every member, and its `http.8080` virtual host is
   unchanged.
8. The namespace scenarios through A's ingress: S7 answers 500 with `RefNotPermitted`, its route
   in `pc routes` points at `UnknownService`, and `pc endpoints --cluster
   'outbound|8080||echo-s7.mesh-verify-gwapi-remote.svc.cluster.local'` still shows B's east-west
   endpoint; S8 and S9 answer 200 from B; S8 reads `BackendNotFound` on B too. Preamble
   `REMOTE_NAMESPACE_LABELS` shows the namespace on B only.
9. S7b through A's ingress: `ResolvedRefs=False:BackendNotFound` and 200 from B, with namespace
   `mesh-verify-gwapi-shared` and its ReferenceGrant on A (`SHARED_NAMESPACE_LABELS`,
   `SHARED_REFERENCEGRANTS`) and no `echo-s7b` there (`BACKEND_SERVICES`).
10. The run is valid: `SCENARIO_SET[ctx]` equals `SCENARIO_SET` everywhere, `DATAPLANE_READY_SEC`
    is a number for every member, `ISTIOD_RESTARTED` / `INGRESS_RESTARTED` are 0, no row says
    `*_UNVERIFIED`, `STATUS_CHANGED` or `LATE_ENDPOINT`, and `ISTIOD_IMAGE` / `OSSM_OPERATOR` name
    the build the answer applies to.

## Cleanup

```bash
fill | kubectl --context <hub-ctx> delete -f -   # fill from Deploy, step 2
```

The finalizers remove the ApplicationSet, the per-member Applications and everything they deployed,
including the Gateway in `istio-system`, namespace `mesh-verify-gwapi-shared` and, on the workload
member, namespace `mesh-verify-gwapi-remote`. By hand, on each member: delete namespaces
`mesh-verify-gwapi` and `mesh-verify-gwapi-shared` and
`gateways.gateway.networking.k8s.io/mesh-verify-gwapi` in `istio-system` (spell out the resource:
`gateway` alone is ambiguous with Istio's), and on the workload member also namespace
`mesh-verify-gwapi-remote`. Leave GatewayClass `istio` alone; istiod owns it.

## Production recommendation (confirmed in the lab 2026-10-14)

1. **Apply the same Service manifest in every member and the Deployment only where the workload
   runs**, rendered from one chart so ports and port names cannot drift, plus the Gateway and
   HTTPRoute in every member. Status reads `ResolvedRefs=True` everywhere, Argo CD stays Healthy (S3),
   it conforms to the Gateway API spec, and it keeps working whichever way upstream resolves
   #60971. In-mesh DNS and GAMMA routes work too. Cost: one Service and one ClusterIP per service
   per member; at thousands of namespaces × 1–5 services, size the service CIDR for it.
2. A `networking.istio.io/Hostname` backendRef is acceptable when a Service cannot exist in the
   ingress member. Its status is right only when the HTTPRoute lives in the Service's namespace
   (S4; istio/istio#62027); from another namespace it reads `BackendNotFound` and Argo CD shows
   Degraded on every member (S8). It is Istio-specific and does nothing for DNS or GAMMA.
3. Do not rely on a bare reference to a Service that exists only remotely: it routes on 1.30.5, but
   the status says the backend is broken, Argo CD shows Degraded (S2, S5), and it contradicts the
   spec's 500 rule for invalid backends, so an upgrade can change it.
4. Do not use ServiceImport/MCS for this: with default flags it behaves like `kind: Service`, and
   enabling MCS discovery makes endpoints cluster-local unless they are exported.
5. Classic Gateway + VirtualService needs no stub for ingress-only use and shows no misleading
   status.
6. Namespaces: with `kind: Service`, the backend's namespace must exist on every ingress member
   (it holds the HTTPRoute, or the ReferenceGrant for a route elsewhere), even where the Service
   does not (S7 vs S7b, both confirmed in the lab).
   Recommendation 1 already gives you that. Without a local namespace, only a `Hostname`
   backendRef (status `BackendNotFound` everywhere, #62027) or a classic VirtualService routes.

## Run config (`--config FILE`)

The script takes `--config FILE`, one file of `KEY=value` lines (shared rules:
[Run config](../../README.md#run-config---config-file)).
[`configs/smoke.env`](configs/smoke.env) is a worked example (5 requests per cell, a 120 s bound
on the wait and the gate, no istioctl evidence):

```bash
./tests/gateway-api/001-run-ingress-check.sh --config tests/gateway-api/configs/smoke.env \
  --contexts <mesh-a-ctx>,<mesh-b-ctx> --workload-context <mesh-b-ctx> --dry-run
```

- **Keys:** `SETUP_CONTEXTS` and the `config/options.env` keys `GWAPI_*`: `GWAPI_WORKLOAD_CONTEXT`,
  `GWAPI_HUB_CONTEXT`, `GWAPI_INGRESS`, `GWAPI_REQUESTS`, `GWAPI_TIMEOUT_SEC`,
  `GWAPI_WAIT_TIMEOUT_SEC`, `GWAPI_SKIP_PROXY_CONFIG` and `GWAPI_RESULTS_DIR` back the flags
  (a relative `GWAPI_RESULTS_DIR` starts at the repo root, unlike `--results-dir`);
  `GWAPI_GATE_PASSES`, `GWAPI_SETTLE_SEC`, `GWAPI_REPROBE_DELAY_SEC`, `GWAPI_DETAIL_TIMEOUT_SEC`,
  `GWAPI_KUBECTL_TIMEOUT_SEC`, `GWAPI_ISTIOCTL_TIMEOUT_SEC`, `GWAPI_NAMESPACE`,
  `GWAPI_REMOTE_NAMESPACE` (the chart's `remoteNamespace`), `GWAPI_SHARED_NAMESPACE`
  (`sharedNamespace`), `GWAPI_GATEWAY`, `GWAPI_ARGOCD_NAMESPACE` (empty by default: the Argo CD
  namespace of the hub's platform, `openshift-gitops` on OpenShift, else `argocd`; the run logs
  which) and `GWAPI_ARGOCD_APPSET` have no flag. `TEST_PLATFORM` (above) is a key of every suite.
- The shared `ISTIOD_DIAG_*` keys are accepted and unused. The script copies the config into the
  run directory as `run-config-<RUN_ID>.env`.
- **Flags only:** `--dry-run`. Keep context names in `configs/<name>.local.env` (gitignored).

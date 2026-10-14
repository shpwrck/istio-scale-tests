# Gateway API Multicluster Ingress Check

A read-only, on-demand check for one question about the multi-primary, multi-network mesh:

> Does an HTTPRoute need its backend Service in **every** member, even a member that runs no
> workload? Goal: a request that enters **any** member's ingress reaches the workload wherever
> it runs.

And a follow-up: does the ingress member need the backend's **namespace**, even without the
Service (S7–S9)?

The check itself is deployed by GitOps
([`charts/mesh-verify-gateway-api`](../../charts/mesh-verify-gateway-api)): HTTPRoutes on every
member, the echo workload on one. [`001-run-ingress-check.sh`](001-run-ingress-check.sh) reads
what each member resolved, sends traffic through every member's ingress, and writes a report
that leads with both answers.

**Status:** built and verified offline (bats with stub clusters). The lab run that confirms or
refutes the predictions below is pending; the lab is powered off (`BACKLOG.md`, "Validation
environment").

## Predicted answer (Istio 1.30.5 / OSSM 3.4.3; not yet confirmed in the lab)

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

## Does the namespace have to exist locally? (predicted; S7–S9)

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

**Consequence for production (prediction):** with `kind: Service` backendRefs, every ingress
member needs the backend's namespace (holding the HTTPRoute or a ReferenceGrant), though not the
Service. Without a local namespace, the options are a `Hostname` backendRef (status says
`BackendNotFound` everywhere) or a classic VirtualService (no status at all).

## Scenarios and predictions

W = the workload member, O = every other member. "Status" is the HTTPRoute's
`Accepted`/`ResolvedRefs` from `istio.io/gateway-controller`. Each scenario has its own host and
its own Service, so none can change another's merged Service entry. The same table, as data, is
`SCENARIOS` in the script; `tests/lib/test/gateway-api.bats` checks that the chart renders
exactly these routes, Services, namespaces, Deployments and ReferenceGrants.

| ID | Host | Route → backend | Service exists on | Status on O | HTTP via O | HTTP via W | Endpoints via O | Confidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | `s1.classic.test` | classic Gateway + VirtualService → `echo-s1` | W | (no status) | 200 from W | 200 | `remote-ewgw:15443` | high |
| S2 | `s2.gwapi.test` | HTTPRoute → Service `echo-s2` | W | `ResolvedRefs=False:BackendNotFound` | 200 from W | 200 | `remote-ewgw:15443` | high (status), medium until seen live (traffic) |
| S3 | `s3.gwapi.test` | HTTPRoute → Service `echo-s3` | every member (stub on O) | `ResolvedRefs=True` | 200 from W | 200 | `remote-ewgw:15443` | high |
| S4 | `s4.gwapi.test` | HTTPRoute → `networking.istio.io/Hostname` `echo-s4.<ns>.svc.cluster.local` | W | `ResolvedRefs=True` (after istiod's first push) | 200 from W | 200 | `remote-ewgw:15443` | medium-high (status) |
| S5 | `s5.gwapi.test` | HTTPRoute → `multicluster.x-k8s.io/ServiceImport` `echo-s5` | W | `ResolvedRefs=False:BackendNotFound` | 200 from W | 200 | `remote-ewgw:15443` | high |
| S7 | `s7.gwapi.test` | HTTPRoute → Service `mesh-verify-gwapi-remote/echo-s7`, ReferenceGrant there | W, namespace too | `ResolvedRefs=False:RefNotPermitted` | 500 | 200 | `remote-ewgw:15443` | high |
| S8 | `s8.gwapi.test` | HTTPRoute → `networking.istio.io/Hostname` `echo-s8.mesh-verify-gwapi-remote.svc.cluster.local` | W, namespace too | `ResolvedRefs=False:BackendNotFound` (W too) | 200 from W | 200 | `remote-ewgw:15443` | medium-high |
| S9 | `s9.classic.test` | classic VirtualService → `echo-s9.mesh-verify-gwapi-remote` | W, namespace too | (no status) | 200 from W | 200 | `remote-ewgw:15443` | high |
| C1 | `neg.gwapi.test` | HTTPRoute → Service `echo-none` | nowhere | `ResolvedRefs=False:BackendNotFound` (W too) | 500 | 500 | `none` | high |
| C2 | `s6.gwapi.test` | HTTPRoute on W only → Service `echo-s2` | W | (no route) | 404 | 200 | – | medium-high |

Every `Accepted` is predicted `True`. Through W's own ingress every route resolves (except C1, and
S8, whose route is outside its Service's namespace) and answers from the local pod (`local-pod`),
with no east-west hop. S7's 500 through O comes from the route, not from missing endpoints: the
ingress still holds `echo-s7`'s cluster with W's east-west endpoint. S3's stub contributes no
endpoints; the merge keeps the first-seen ports, so the stub comes from the same template as the
real Service. S5: with `ENABLE_MCS_HOST=false` (the default) a ServiceImport is handled exactly
like `kind: Service`, and no ServiceImport CRD or object is read.

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
  ManagedCluster name.
- On the workload member only: namespace `mesh-verify-gwapi-remote` (`remoteNamespace`, same
  labels; the label is what lets the other members' istiods discover its Services) with a second
  `gwapi-echo` Deployment, Services `echo-s7`, `echo-s8`, `echo-s9`, and ReferenceGrant `s7`
  (HTTPRoutes from `mesh-verify-gwapi` to Service `echo-s7`).
- `workloadCluster` (the workload member's ACM ManagedCluster name) decides where the
  Deployments, the workload-only Services, the backend namespace and C2 go. Empty, or the
  `<workload-cluster>` placeholder, fails every member's render with a message rather than
  deploying a check without a workload; a render with no `clusterName` (CI's `helm lint`) shows
  what a member without the workload gets.

## Deploy

Needs the Gateway API CRDs on every member, ReferenceGrant included (recent OpenShift releases
install the standard channel through the ingress operator; the script stops when HTTPRoute is
missing), and the `istio` GatewayClass, which istiod creates.

1. Pick the workload member: `oc --context <acm-hub-ctx> get managedclusters`.
2. Edit [`charts/mesh-verify-gateway-api-appset.yaml`](../../charts/mesh-verify-gateway-api-appset.yaml):
   both revisions (`spec.source.targetRevision`, `repo.revision`), both repo URLs if you use a
   fork, and `template.source.helm.valuesObject.workloadCluster` (the ManagedCluster name).
3. Apply it on the hub and wait for the per-member Applications:

   ```bash
   oc --context <acm-hub-ctx> apply -f charts/mesh-verify-gateway-api-appset.yaml
   oc --context <acm-hub-ctx> get applications.argoproj.io -n openshift-gitops | grep mesh-verify-gwapi
   ```

   An Application may report `Degraded`: C1's missing backend is intentional, and Argo CD may
   read S2/S5/S8's `BackendNotFound` and S7's `RefNotPermitted` the same way (S8 on the workload
   member too). Whether it does is one of the things the run
   records (`--hub-context`).

## Run

```bash
tests/gateway-api/001-run-ingress-check.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> \
  --workload-context <mesh-b-ctx> --hub-context <acm-hub-ctx> --dry-run
tests/gateway-api/001-run-ingress-check.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> \
  --workload-context <mesh-b-ctx> --hub-context <acm-hub-ctx>
```

`--contexts` lists mesh members only (at least two); `--workload-context` is the member whose
ManagedCluster name is the chart's `workloadCluster`. The script deploys nothing. It:

1. **Preflight**, per member, recorded in the TSV preamble: the Gateway API CRD bundle version,
   GatewayClass `istio` (controller, Accepted), the namespace labels, istiod's overrides of
   `PILOT_ENABLE_GATEWAY_API`, `ENABLE_GATEWAY_API_MANUAL_DEPLOYMENT`,
   `PILOT_FILTER_GATEWAY_CLUSTER_CONFIG`, `ENABLE_MCS_HOST` and `ENABLE_MCS_SERVICE_DISCOVERY`
   (`unset` = Istio's default; `unknown` = the read failed), the Istio CR version, the tuning
   baseline, the echo Deployment (Ready and sidecar-injected on the workload member, absent
   elsewhere), and namespace `mesh-verify-gwapi-remote` with its echo Deployment (expected on the
   workload member only). It stops, writing nothing, when the check is not deployed (the backend
   namespace missing on the workload member included) or `--workload-context` names the wrong
   member. The backend namespace on another member does not stop the run: that member's S7–S9 rows
   become `UNKNOWN` (`NS_SCENARIO_INVALID`), because they can no longer show whether a local
   namespace is needed.
2. **Waits** up to `--wait-timeout` (180 s) for the Gateway's `Programmed=True`, both echo
   Deployments, and istio's status on every route. Rows still without status say `STATUS_TIMEOUT`.
3. **Traffic:** `--requests` (10) requests per member ingress × scenario host
   (`curl -H "Host: …"`), with `--timeout` (5 s) each. The ingress address comes from the
   LoadBalancer status, or `--ingress CTX=ADDR[:PORT]`. A cell with a timed-out request gets one
   more request with `GWAPI_DETAIL_TIMEOUT_SEC` (35 s): Envoy answers a dead east-west hop only
   after 3 × 10 s connect timeouts (one try plus Istio's default two retries), so the long timeout
   records Envoy's own verdict instead of a client timeout, and only once per such cell.
4. **Endpoint evidence** (best effort; skipped by `--skip-proxy-config` or without `istioctl`):
   `istioctl proxy-config endpoints` on each ingress for `outbound|8080||<backend FQDN>`, as a
   class (`local-pod`, `remote-ewgw:15443`, `mixed`, `none`), a count and a healthy count.
   Addresses are never recorded.
5. **Argo CD health** (best effort; `--hub-context` only): each per-member Application's health,
   sync and synced git revision, and the health of its HTTPRoutes. The revision is the chart
   content that was deployed (preamble `CHART_REVISION`; `HARNESS_SHA` only describes the script).
6. Rereads the route status (S4's status depends on istiod's push timing) and writes
   `<results-dir>/run-<RUN_ID>/`: `gateway-api-<RUN_ID>.tsv`, `summary-<RUN_ID>.md`, and
   `argocd-<RUN_ID>.tsv` with `--hub-context`.

A failed best-effort step prints its reason and the run goes on. Response bodies and error text are
masked (`reach_sanitize`: IPs and host names); context names are recorded as given.

## Read the report

The summary starts with two answers. The first, from S2 and S3:

- **NO** (no Service needed for traffic): S2 answered 200 with the workload's echo text, on every
  request, through every other member's ingress.
- **YES**: S2 failed through every other member's ingress while S3 (the same route plus a stub
  Service) answered 200 from the workload member.
- **INCONCLUSIVE**: anything else, with the reason: S2 and S3 both failed (the cross-cluster path
  itself is broken: check S1, mesh-verify and the east-west gateways), members disagree, an
  ingress had no address or never answered, or the workload's echo text is unknown.

The second, "Local namespace needed on the ingress cluster", has one verdict per backend kind,
each judged through every other member's ingress, which has no `mesh-verify-gwapi-remote`:

- `kind: Service` from S7, `Hostname` from S8, classic VirtualService from S9.
- **NO**: the scenario answered 200 with the workload's echo text on every request.
- **YES**: it failed while another scenario with its backend in the same namespace (S8/S9 for S7,
  S9 for S8, S8 for S9) answered 200 through the same ingress, so the failure is the kind's own.
- **INCONCLUSIVE**, with the reason: all of them failed (the path to the backend namespace itself
  is broken; check its `istio-discovery` label on the workload member), members disagree, or a
  member has the namespace itself (`NS_SCENARIO_INVALID`) or could not be read
  (`NS_SCENARIO_UNVERIFIED`).

Then the S2 status and the S7–S9 results on each other member, the MATCH/DEVIATION/UNKNOWN
counts, Argo CD health, the matrix, every row that is not MATCH with its prediction and
confidence, the preflight table, and the run settings. The YAML frontmatter repeats every TSV
preamble line.

TSV (`GWAPI_SCHEMA=1`), one row per member × scenario: `run_id ingress_ctx role scenario kind
host route backend expected_status observed_status expected_code observed_codes expected_body
body_match top_body expected_endpoints observed_endpoints endpoints_healthy verdict row_status
detail`.

- `backend` is the backendRef as the chart writes it; a backend in the other namespace as
  `Service mesh-verify-gwapi-remote/echo-s7`.
- `observed_codes` is `code:count` by count (`200:10`, `200:7,503:3`); `000` = no HTTP answer
  within `--timeout`. `body_match` is `yes`, `no`, `partial:k/n` or `n/a` (no 200s); it is also
  filled for unexpected 200s (S7 answering through another member), which then deviate on the
  code alone.
- `verdict`: `DEVIATION` if any checked part differs from the prediction; else `UNKNOWN` if a part
  could not be observed; else `MATCH`. Endpoints count only when they were read.
- `row_status`: `OK`, or a comma list of `STATUS_TIMEOUT` (no status when the wait ended),
  `STATUS_PENDING`, `STATUS_UNREADABLE`, `NO_INGRESS_ADDR`, `INGRESS_UNREACHABLE` (no request
  through that ingress got an HTTP answer: a path problem from where the script runs, not a mesh
  result), `NOT_PROBED`, `CURL_TIMEOUT` (the detail request's answer is in `detail`),
  `PROXY_CONFIG_FAILED`, `NS_SCENARIO_INVALID` (an S7–S9 row on a member other than the workload
  member that has `mesh-verify-gwapi-remote` itself) and `NS_SCENARIO_UNVERIFIED` (whether it
  has the namespace could not be read). Rows with either are `UNKNOWN` whatever they observed.

## What the lab run must confirm

1. A's ingress programs B's endpoints for S2, S4 and S5: one `remote-ewgw:15443` endpoint, healthy
   (`observed_endpoints`). By hand: `istioctl --context <mesh-a-ctx> -n istio-system pc endpoints
   deploy/istio-ingressgateway --cluster 'outbound|8080||echo-s2.mesh-verify-gwapi.svc.cluster.local'`.
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
6. Argo CD: is the S2/S5 Application on a member without the workload Degraded? (Inferred from
   Argo's upstream HTTPRoute health check, not verified for OpenShift GitOps.)
7. No regression: mesh-verify still answers from every member, and its `http.8080` virtual host is
   unchanged.
8. The namespace scenarios through A's ingress: S7 answers 500 with `RefNotPermitted`, its route
   in `pc routes` points at `UnknownService`, and `pc endpoints --cluster
   'outbound|8080||echo-s7.mesh-verify-gwapi-remote.svc.cluster.local'` still shows B's east-west
   endpoint; S8 and S9 answer 200 from B; S8 reads `BackendNotFound` on B too. Preamble
   `REMOTE_NAMESPACE_LABELS` shows the namespace on B only.

## Cleanup

```bash
oc --context <acm-hub-ctx> delete -f charts/mesh-verify-gateway-api-appset.yaml
```

The finalizers remove the ApplicationSet, the per-member Applications and everything they deployed,
including the Gateway in `istio-system` and, on the workload member, namespace
`mesh-verify-gwapi-remote`. By hand, on each member: delete namespace `mesh-verify-gwapi` and
`gateways.gateway.networking.k8s.io/mesh-verify-gwapi` in `istio-system` (spell out the resource:
`gateway` alone is ambiguous with Istio's), and on the workload member also namespace
`mesh-verify-gwapi-remote`. Leave GatewayClass `istio` alone; istiod owns it.

## Production recommendation (the prediction; confirm with the lab run first)

1. **Apply the same Service manifest in every member and the Deployment only where the workload
   runs**, rendered from one chart so ports and port names cannot drift, plus the Gateway and
   HTTPRoute in every member. Status reads `ResolvedRefs=True` everywhere, Argo CD stays Healthy,
   it conforms to the Gateway API spec, and it keeps working whichever way upstream resolves
   #60971. In-mesh DNS and GAMMA routes work too. Cost: one Service and one ClusterIP per service
   per member; at thousands of namespaces × 1–5 services, size the service CIDR for it.
2. A `networking.istio.io/Hostname` backendRef is acceptable when a Service cannot exist in the
   ingress member. Its status is right only when the HTTPRoute lives in the Service's namespace
   (istio/istio#62027); it is Istio-specific and does nothing for DNS or GAMMA.
3. Do not rely on a bare reference to a Service that exists only remotely: it routes on 1.30.5, but
   the status says the backend is broken, Argo CD probably shows Degraded, and it contradicts the
   spec's 500 rule for invalid backends, so an upgrade can change it.
4. Do not use ServiceImport/MCS for this: with default flags it behaves like `kind: Service`, and
   enabling MCS discovery makes endpoints cluster-local unless they are exported.
5. Classic Gateway + VirtualService needs no stub for ingress-only use and shows no misleading
   status.
6. Namespaces: with `kind: Service`, the backend's namespace must exist on every ingress member
   (it holds the HTTPRoute, or the ReferenceGrant for a route elsewhere), even where the Service
   does not. Recommendation 1 already gives you that. Without a local namespace, only a `Hostname`
   backendRef (status `BackendNotFound` everywhere, #62027) or a classic VirtualService routes.

## Run config (`--config FILE`)

The script takes `--config FILE`, one file of `KEY=value` lines (shared rules:
[Run config](../../README.md#run-config---config-file)).
[`configs/smoke.env`](configs/smoke.env) is a worked example (5 requests per cell, a 120 s wait,
no istioctl evidence):

```bash
./tests/gateway-api/001-run-ingress-check.sh --config tests/gateway-api/configs/smoke.env \
  --contexts <mesh-a-ctx>,<mesh-b-ctx> --workload-context <mesh-b-ctx> --dry-run
```

- **Keys:** `SETUP_CONTEXTS` and the `config/options.env` keys `GWAPI_*`: `GWAPI_WORKLOAD_CONTEXT`,
  `GWAPI_HUB_CONTEXT`, `GWAPI_INGRESS`, `GWAPI_REQUESTS`, `GWAPI_TIMEOUT_SEC`,
  `GWAPI_WAIT_TIMEOUT_SEC`, `GWAPI_SKIP_PROXY_CONFIG` and `GWAPI_RESULTS_DIR` back the flags
  (a relative `GWAPI_RESULTS_DIR` starts at the repo root, unlike `--results-dir`);
  `GWAPI_DETAIL_TIMEOUT_SEC`, `GWAPI_KUBECTL_TIMEOUT_SEC`, `GWAPI_ISTIOCTL_TIMEOUT_SEC`,
  `GWAPI_NAMESPACE`, `GWAPI_REMOTE_NAMESPACE` (the chart's `remoteNamespace`), `GWAPI_GATEWAY`,
  `GWAPI_ARGOCD_NAMESPACE` and `GWAPI_ARGOCD_APPSET` have no flag. The shared `ISTIOD_DIAG_*` keys are accepted and unused.
- **Flags only:** `--dry-run`. Keep context names in `configs/<name>.local.env` (gitignored).

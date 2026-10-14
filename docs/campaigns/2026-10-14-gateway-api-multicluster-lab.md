# 2026-10-14 lab run of the Gateway API multicluster ingress check

The first live run of [`tests/gateway-api/`](../../tests/gateway-api/README.md) (backlog task 8). It
asks whether Gateway API (HTTPRoute) needs the backend Service, or its namespace, on every mesh
member so that a request entering any member's ingress reaches a workload that runs on one member.
This is a functional check, not a scale run.

## Rig

- Two mesh members and an ACM hub `<acm-hub-ctx>` running Argo CD (not a mesh member). See
  [`docs/runbooks/existing-cluster-lab/`](../runbooks/existing-cluster-lab/README.md).
  - `<mesh-b-ctx>` ran the echo workload: the "workload member".
  - `<mesh-a-ctx>` did not run it: the "other member", whose ingress is the cross-cluster test.
- Single-node OpenShift 4.21 on bare metal, MetalLB for LoadBalancer Services.
- OSSM 3.4.3 / Istio v1.30.5, multi-primary multi-network, shared root, istiod 1 replica. Both
  members ran the same builds:
  - istiod `istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7`
  - ingress `istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109`
  - No istiod env overrides of the Gateway API, gateway-cluster-filter or MCS flags; every one
    read `unset`.
- Gateway API CRDs v1.3.0 (standard channel, installed by OpenShift). GatewayClass `istio`
  (`istio.io/gateway-controller`) was Accepted on both members, and istiod had also created
  `istio-remote`.
- Harness and chart at `415b361` (main after shpwrck/istio-scale-tests#102): scenario set `v3`,
  report schema 5. The Application was pinned to that commit, and the run recorded the chart
  revision as `same`. istioctl 1.30.5.
- The Gateway API Gateway bound to the existing `istio-ingressgateway` by manual deployment, so
  the run needed no extra LoadBalancer IP.

## Result: 22 MATCH, 0 DEVIATION, 0 UNKNOWN

Every prediction from the Istio 1.30.5 source held. The data-plane gate passed after 2 s on both
members (S1 and S3, three rounds in a row). There were no restarts, and the scenario set matched
on both members. Each cell got 10 requests. The traffic window was 19:17:16–19:17:17 UTC, and
the S7 cell was re-probed 15 s later.

| Question | Answer | Evidence through the other member's ingress |
| --- | --- | --- |
| Service needed on every member for HTTPRoute traffic? | **NO** | S2: `200:10` from the workload member, with no `echo-s2` there. Status `Accepted=True / ResolvedRefs=False:BackendNotFound`. Endpoint: the workload member's east-west gateway on 15443, 1/1 healthy. |
| Backend namespace needed, `kind: Service`? | **YES**, for the ReferenceGrant, not the Service | S7: `500:10` (Envoy's empty cluster-not-found reply, as for C1), repeated on the re-probe, status `RefNotPermitted`. S7b (namespace + grant there, no Service): `200:10`, `BackendNotFound`. |
| Backend namespace needed, `Hostname` backendRef? | **NO** | S8: `200:10`, but `BackendNotFound` on **both** members. |
| Backend namespace needed, classic VirtualService? | **NO** | S9: `200:10`. |

| Scenario | Backend | Other member: status / HTTP | Workload member: status / HTTP |
| --- | --- | --- | --- |
| S1 classic | Service on workload member only | present / 200 | present / 200 |
| S2 | Service on workload member only | BackendNotFound / 200 | True / 200 |
| S3 | Service everywhere (stub on the other) | True / 200 | True / 200 |
| S4 | Hostname, same namespace | True / 200 | True / 200 |
| S5 | ServiceImport (MCS off) | BackendNotFound / 200 | True / 200 |
| S7 | Service, namespace absent on the other member | RefNotPermitted / 500 | True / 200 |
| S7b | Service, namespace + grant everywhere, Service on workload only | BackendNotFound / 200 | True / 200 |
| S8 | Hostname into the remote-only namespace | BackendNotFound / 200 | BackendNotFound / 200 |
| S9 classic | VirtualService into the remote-only namespace | present / 200 | present / 200 |
| C1 | no backend anywhere | BackendNotFound / 500 | BackendNotFound / 500 |
| C2 | route on the workload member only | absent / 404 | True / 200 |

All 200s through the other member's ingress carried the workload member's echo text. The istioctl
endpoints for those cells were `remote-ewgw:15443` (1/1 healthy). Through the workload member they
were `direct`.

### Argo CD health (the open question): HTTPRoutes with `ResolvedRefs=False` are Degraded

OpenShift GitOps marked each HTTPRoute with `ResolvedRefs=False` as Degraded, and therefore each
member's Application as Degraded.

| Application | HTTPRoute health |
| --- | --- |
| other member | c1, s2, s5, s7, s7b, s8 Degraded; s3, s4 Healthy |
| workload member | c1, s8 Degraded; c2, s2, s3, s4, s5, s7, s7b Healthy |

So a bare reference to a Service that exists only on another member routes correctly but keeps
the Application Degraded. A `Hostname` backendRef into another namespace (S8) is Degraded even on
the member that has the Service. A stub Service (S3) or a same-namespace Hostname (S4) stays
Healthy.

## What this means for production

The prediction-time recommendation now stands as observed. Render the same Service in every
member and the Deployment only where the workload runs, plus the Gateway and HTTPRoute in every
member. That gives the following:
- traffic from every ingress;
- `ResolvedRefs=True` everywhere;
- Argo CD Healthy (S3);
- independence from how upstream resolves istio/istio#60971.

With `kind: Service`, the backend's namespace must exist on every ingress member even if the
Service does not (S7 vs S7b). Without a local namespace, a `Hostname` backendRef (S8) or a classic
VirtualService (S9) routes, but the Hostname route is Degraded in Argo CD everywhere.

## Not checked in this run

From the README's "What the lab run must confirm":
- The route's `clusterNotFoundResponseCode` was not read with `istioctl pc routes`. The empty-body
  500s on S7 and C1 are the observable form of it.
- The ingress access log was not read; the istioctl endpoints name the east-west gateway instead.
- The mesh-verify regression check was not run, because mesh-verify was not deployed.
  - The check left nothing behind: deleting the Application removed every object on both members
    within 20 s.
  - After cleanup, all 30 Applications were Synced/Healthy and both wiring gates were Ready.

## Lab power-on timeline (same day)

The lab had been powered off since 2026-10-13. After power-on:

| Time (UTC) | Event |
| --- | --- |
| about 19:01 | APIs answering on the members; the ACM hub still refused connections |
| by 19:04 | Nodes Ready on all three clusters, after approving 6 node CSRs (one was the OVN per-node client certificate `system:ovn-node:<node>`) |
| about 19:12 | Last member's istio-system pods Running (OVN finished after its late CSR) |
| 19:16 | Check deployed |
| 19:17 | Run finished |
| 19:18 | Check cleaned up |

Power-on to answer took about 18 minutes. The hub's External Secrets Application was briefly
Degraded (catalog source starting) and recovered on its own.

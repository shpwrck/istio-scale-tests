# spoke-east-west-gateway

Per-spoke **east-west gateway** + cross-network `Gateway` CR for the multi-primary, multi-network mesh. Exposes TLS `AUTO_PASSTHROUGH` on port `15443` so cross-cluster mTLS traffic routes between clusters' networks. Synced by the `spoke-east-west-gateway` ApplicationSet (wave 27).

See the repo `AGENTS.md` and [OSSM 3.3 multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies) for the surrounding architecture.

## `service.type` — LoadBalancer vs NodePort (the reachability knob)

The east-west gateway must be reachable from **every other cluster's** sidecars/gateways. How it is exposed depends on the network fabric, set via `service.type` in `values.yaml`:

| `service.type` | When to use | Why |
|----------------|-------------|-----|
| **`LoadBalancer`** (default) | ROSA / AWS / any cloud where worker nodes have **no routable external IP** and VPC peering is **off** (clusters in separate VPCs) | A public cloud NLB is reachable cross-cluster over the internet (mTLS `AUTO_PASSTHROUGH` keeps it secure). A NodePort would not be reachable — other clusters' VPCs (e.g. `10.x`) cannot reach a worker's internal-only `10.x` NodePort. |
| `NodePort` | A **flat/routable** network (e.g. a MetalLB homelab where nodes share a routable subnet like `172.16.x`) | The nodePort (`service.nodePorts.tls`, default `31443`) is directly reachable across the flat network without provisioning a cloud LB. |

The chart **default is `LoadBalancer`** — the correct value for the ROSA/peering-off target this repo provisions. (An earlier commit set NodePort for a MetalLB homelab whose flat network made NodePorts routable; that environment no longer points at this repo, so the default is now the cloud-correct value. A LoadBalancer Service still allocates a nodePort, so `service.nodePorts.tls` stays pinned for stability and is harmless when `type=LoadBalancer`.)

> **Symptom of the wrong choice:** control-plane cross-cluster discovery succeeds (`istioctl remote-clusters` all synced) but **data-plane** east-west traffic fails — a sidecar curling a cross-cluster Service gets only local responses, cross-cluster attempts time out. On ROSA with peering off, that is a NodePort that other VPCs cannot reach; switch to `LoadBalancer`. (Pair this with the `istio-system` namespace `topology.istio.io/network` label, without which istiod advertises local workloads as raw pod IPs instead of routing via the gateway.)

## Key values

| Key | Default | Purpose |
|-----|---------|---------|
| `clusterName` | `""` | Injected per-cluster by the ApplicationSet generator (`{{clusterName}}`). |
| `networkSuffix` | `network` | Network id suffix (`<clusterName>-<networkSuffix>`). |
| `service.type` | `LoadBalancer` | Exposure mode — see the table above. |
| `service.nodePorts.tls` | `"31443"` | Pinned nodePort for the `15443` TLS port (used directly under NodePort; allocated-but-stable under LoadBalancer). |
| `service.annotations` | `{}` | Service annotations (e.g. cloud-LB controller hints). |
| `replicaCount` / `autoscaling.*` | `1` / `1-5` @ 80% | Gateway replica count and HPA bounds. |
| `resources` | `100m`/`128Mi` req, `2000m`/`1024Mi` lim | Gateway pod resources. At large mesh sizes watch gateway proxy RSS — the mesh-wide root `Sidecar` egress narrowing does NOT shrink the injected gateways (PL38). |

Version pins live in `config/versions.env`; do not duplicate them here.

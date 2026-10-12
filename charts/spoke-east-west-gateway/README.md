# spoke-east-west-gateway

East-west gateway and cross-network `Gateway` for a multi-primary, multi-network mesh. It exposes TLS `AUTO_PASSTHROUGH` on port `15443` so mTLS traffic can cross between cluster networks. The `spoke-east-west-gateway` ApplicationSet deploys it to every mesh member.

Architecture: [OSSM 3.4 multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.4/html/installing/ossm-multi-cluster-topologies).

## `service.type`

Every other mesh member must be able to reach this gateway. istiod advertises the address it finds on the Service.

| `service.type` | Address istiod advertises | Use when |
|----------------|---------------------------|----------|
| `LoadBalancer` (default) | `status.loadBalancer.ingress` IP (MetalLB) or hostname (cloud LB) | The cluster has an LB provider. With a MetalLB pool set to `autoAssign: false`, request the pool: `service.annotations: {metallb.io/address-pool: <pool>}`. |
| `NodePort` | Node IPs, port `service.nodePorts.tls` | Node IPs are routable between clusters. Also set the `traffic.istio.io/nodeSelector` annotation in `service.annotations`; without it istiod advertises no address. |

A `LoadBalancer` Service with no address (`<pending>`) gives this symptom: `istioctl remote-clusters` shows every cluster synced, but cross-cluster requests time out or reach only local endpoints.

## Key values

| Key | Default | Purpose |
|-----|---------|---------|
| `clusterName` | — (required) | Set per cluster by the ApplicationSet. |
| `networkSuffix` | `network` | Network name is `<clusterName>-<networkSuffix>`. Must match the `istio-system` namespace label. |
| `service.type` | `LoadBalancer` | See above. |
| `service.annotations` | `{}` | MetalLB pool or Istio node selector. |
| `service.nodePorts.tls` | `"31443"` | Fixed nodePort for `15443`. |
| `replicaCount` / `autoscaling.*` | `1` / off | A PodDisruptionBudget renders only with more than one replica. |
| `waitForIstiod.image` | `ubi9/ubi-minimal:9.8` | PreSync Job that waits for istiod. |

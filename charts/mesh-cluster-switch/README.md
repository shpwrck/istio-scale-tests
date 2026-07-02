# mesh-cluster-switch

A mesh-wide traffic switch for a multi-primary, multi-network Istio mesh: one
`DestinationRule` in the root namespace (`istio-system`) that steers **100% of
meshed traffic to a chosen cluster**, or restores balanced cross-cluster load
balancing. No per-service `VirtualService`/`DestinationRule` changes are needed —
the switch operates on every `*.svc.cluster.local` host at once.

Standalone chart (not in the root app-of-apps), applied directly with
`helm template … | oc apply`, like `mesh-verify`.

## How it works

- Every endpoint's locality is derived by istiod from the **node** it runs on —
  including endpoints discovered in remote clusters through Istio remote secrets.
  A one-time node label makes each cluster its own region, so "cluster" becomes a
  routable locality.
- The chart renders a wildcard `DestinationRule` in `istio-system` (the mesh-wide
  default layer) with `localityLbSetting.distribute`, sending weight 100 to the
  chosen region from every client locality (`from: "*"`).
- Envoy requires outlier detection to activate locality load balancing, so the
  rule carries deliberately lax settings that keep health-based ejection out of
  the way of the deterministic pin.

## One-time prerequisite: label nodes with a region

Each cluster's nodes get their cluster name as region (zone label added for
locality-string robustness). For every context in `SETUP_CONTEXTS`:

```bash
for ctx in cluster-001 cluster-002; do
  oc --context "$ctx" label node --all \
    "topology.kubernetes.io/region=$ctx" "topology.kubernetes.io/zone=$ctx" --overwrite
done
```

No restarts are needed: endpoint locality is recomputed by istiod from its node
informers, and the switch matches `from: "*"` so client proxies' own
(bootstrap-time) locality never matters.

## Operating the switch

The rendered `DestinationRule` exists in **all** states, so every transition is a
plain `oc apply` of a new render — no deletes. In a multi-primary mesh each istiod
only programs its own cluster's sidecars, so **always apply the flip to every
cluster**:

```bash
# Pin all meshed traffic to cluster-001
for ctx in cluster-001 cluster-002; do
  helm template switch charts/mesh-cluster-switch --set activeCluster=cluster-001 \
    | oc --context "$ctx" apply -f -
done

# Flip to cluster-002
for ctx in cluster-001 cluster-002; do
  helm template switch charts/mesh-cluster-switch --set activeCluster=cluster-002 \
    | oc --context "$ctx" apply -f -
done

# Restore balanced cross-cluster load balancing
for ctx in cluster-001 cluster-002; do
  helm template switch charts/mesh-cluster-switch --set activeCluster=balanced \
    | oc --context "$ctx" apply -f -
done

# Remove the switch entirely
for ctx in cluster-001 cluster-002; do
  oc --context "$ctx" delete destinationrule mesh-cluster-switch -n istio-system
done
```

| `activeCluster` | Behavior |
| --------------- | -------- |
| `<region name>` | Every meshed client on every cluster sends 100% of traffic to endpoints in that region (crossing the east-west gateway when the target is remote). |
| `balanced` (default) | `localityLbSetting.enabled: false` — endpoint-proportional load balancing across all clusters. |

## Demo: prove the pin with mesh-verify

```bash
# 1. Deploy the echo workload on both clusters (see charts/mesh-verify/), then
#    REMOVE its per-service DestinationRule — a host-specific DR fully shadows
#    the mesh-wide switch for that host (see Caveats):
for ctx in cluster-001 cluster-002; do
  helm template mv charts/mesh-verify --set clusterName="$ctx" | oc --context "$ctx" apply -f -
  oc --context "$ctx" delete destinationrule mesh-verify-echo -n mesh-verify
done

# 2. From a meshed client pod, sample the echo service:
kubectl exec -n mesh-verify deploy/<client> -- bash -c \
  'for i in $(seq 1 20); do curl -s http://mesh-verify-echo.mesh-verify.svc.cluster.local:8080/; done' \
  | sort | uniq -c
# balanced            → responses from both clusters
# activeCluster=X     → 20/20 responses from X, from clients on BOTH clusters

# 3. Inspect the Envoy view — endpoint localities and effective weights:
istioctl proxy-config endpoints deploy/<client>.mesh-verify \
  --cluster "outbound|8080||mesh-verify-echo.mesh-verify.svc.cluster.local" -o json \
  | grep -E 'region|address|weight'
```

## Caveats

- **Host-specific DestinationRules shadow the switch (no merging).** Istio picks
  the most specific DR per host; it never merges policies across DRs. Any service
  that ships its own DR (e.g. `mesh-verify`, whose DR intentionally disables
  locality LB) escapes the switch until that DR is removed or given the same
  policy. Audit with: `oc get destinationrules -A`.
- **Do not co-apply tuning profile 12.** `tests/tuning/profiles/12-connection-pools.yaml`
  creates another `*.svc.cluster.local` DR in `istio-system`; two wildcard DRs on
  the same host in the same namespace is undefined-precedence territory.
- **Meshed clients only.** The switch is client-side Envoy configuration. Traffic
  that bypasses sidecars (host-level curl, NodePort, sidecar-less pods) is
  unaffected.
- **Health can override the pin.** Outlier detection is required for locality LB
  to activate; if every endpoint in the pinned region is ejected, Envoy
  redistributes to surviving localities instead of failing requests. The lax
  defaults make this practically unreachable in a demo, but strictly the semantic
  is "all traffic to X *while X answers*".
- **`balanced` still carries the (lax) outlier detection**, since the DR object is
  kept across states for apply-only transitions. Delete the DR to return to a
  fully pristine mesh default.

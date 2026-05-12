# Propagation Latency Test Suite

Automated measurement of how quickly Istio's multi-cluster control plane propagates endpoint changes across clusters.

## What Gets Measured

### Endpoint Propagation (002)

| Phase | What | How |
|-------|------|-----|
| P1 | Local istiod pushes xDS to local sidecars | Poll istiod `/debug/syncz` |
| P2 | Remote istiod discovers new endpoints | Poll remote istiod `/debug/endpointz` |
| P3 | Remote sidecar has HEALTHY endpoints | Poll watcher pod's Envoy admin API (`/clusters`) |

In multi-primary Istio, only endpoints propagate cross-cluster. VirtualService and DestinationRule are local config processed only by the istiod that owns the namespace.

## Prerequisites

- `oc` or `kubectl`, `helm`, `jq`, `curl`
- Multi-primary mesh deployed (see root README)
- Kube contexts configured for each cluster

## Quick Start

```bash
# 1. Setup watcher pods on all clusters
./propagation-test/001-setup-propagation-test.sh --contexts rosa-001,rosa-002,rosa-003

# 2. Run endpoint probe (2-cluster)
./propagation-test/002-run-endpoint-probe.sh \
  --source-context rosa-001 --remote-contexts rosa-002 \
  --iterations 10

# 3. View results
./propagation-test/005-report-results.sh
```

## Sweep Across Mesh Sizes

Compare propagation latency at different cluster counts:

```bash
# Run probes at mesh_size=1, 2, 3
./propagation-test/006-run-sweep.sh \
  --contexts rosa-001,rosa-002,rosa-003 \
  --mesh-sizes 1,2,3 \
  --iterations 5

# Dry-run to see plan without executing
./propagation-test/006-run-sweep.sh --dry-run
```

The sweep orchestrator:
1. Sets up watcher pods on clusters for each mesh size
2. Runs endpoint probe (002) at each size
3. Generates a comparison report grouped by mesh_size

## Passive Metrics Collection

### Via port-forward (004)

```bash
# One-shot snapshot
./propagation-test/004-collect-pilot-metrics.sh --contexts rosa-001,rosa-002

# Watch mode during load test
./propagation-test/004-collect-pilot-metrics.sh --watch --interval 10
```

### Via OpenShift User Workload Monitoring

Deploy the `istiod-monitor` chart on each spoke:

```bash
helm install istiod-monitor charts/istiod-monitor -n istio-system --context rosa-001
```

This creates a ServiceMonitor scraping istiod's `pilot_*` metrics. Query via thanos-querier:

```promql
histogram_quantile(0.99, rate(pilot_proxy_convergence_time_bucket[5m]))
```

## Results Format

TSV files in `propagation-test/results/` (gitignored):

```
run_id  mesh_size  iteration  source_ctx  remote_ctx  t0_epoch_ns  p1_local_ms  p2_discovery_ms  p3_dataplane_ms  status
```

Report output groups by mesh_size with min/max/avg/p50/p95/p99 statistics.

## Cleanup

```bash
./propagation-test/007-cleanup.sh --contexts rosa-001,rosa-002,rosa-003
```

## Scripts

| Script | Purpose |
|--------|---------|
| `001-setup-propagation-test.sh` | Deploy/cleanup watcher pods and namespace |
| `002-run-endpoint-probe.sh` | Measure endpoint propagation (P1/P2/P3) |
| `004-collect-pilot-metrics.sh` | Scrape istiod Prometheus metrics |
| `005-report-results.sh` | Generate summary statistics from TSV results |
| `006-run-sweep.sh` | Orchestrate probes across multiple mesh sizes |
| `007-cleanup.sh` | Remove all propagation-test resources |

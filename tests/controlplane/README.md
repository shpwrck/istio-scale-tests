# Control-Plane Resource Scaling Test Suite

Measure istiod CPU, memory, and xDS metrics as a function of mesh size and workload density.

## What Gets Measured

| Metric | Source | What it shows |
|--------|--------|---------------|
| istiod CPU (millicores) | `kubectl top pod` | Control-plane CPU cost per cluster count |
| istiod Memory (MiB) | `kubectl top pod` | Control-plane memory cost per cluster count |
| `pilot_proxy_convergence_time` p50/p99 | istiod Prometheus | How fast config reaches all sidecars |
| `pilot_proxy_queue_time` p50/p99 | istiod Prometheus | How long pushes wait in istiod's queue |
| `pilot_xds_pushes` | istiod Prometheus | Total xDS push count |
| `pilot_k8s_cfg_events` | istiod Prometheus | Kubernetes watch event rate |
| `pilot_xds` | istiod Prometheus | Connected proxy count |
| `pilot_xds_config_size_bytes` | istiod Prometheus | xDS push payload size |

## Prerequisites

- `oc` or `kubectl`, `helm`, `jq`, `curl`
- Multi-primary mesh deployed (see root README)
- Kube contexts configured for each cluster

## Quick Start

```bash
# 1. Deploy dummy workloads on all clusters
./tests/controlplane/001-setup-controlplane-test.sh --contexts rosa-001,rosa-002,rosa-003

# 2. Collect metrics snapshot
./tests/controlplane/002-collect-resource-metrics.sh --contexts rosa-001,rosa-002,rosa-003

# 3. View results
./tests/controlplane/004-report-results.sh
```

## Sweep Across Mesh Sizes

Compare istiod resource consumption at different cluster counts:

```bash
# Deploy, collect, cleanup at mesh_size=1, 2, 3
./tests/controlplane/003-run-sweep.sh \
  --contexts rosa-001,rosa-002,rosa-003 \
  --mesh-sizes 1,2,3 \
  --service-count 50

# Dry-run to see plan without executing
./tests/controlplane/003-run-sweep.sh --dry-run
```

## Watch Mode

Monitor istiod metrics continuously during a load test:

```bash
./tests/controlplane/002-collect-resource-metrics.sh --watch --interval 15
```

## Results Format

TSV files in `tests/controlplane/results/` (gitignored):

```
timestamp  context  mesh_size  service_count  replicas  istiod_cpu_m  istiod_mem_mi  convergence_p50_ms  convergence_p99_ms  queue_p50_ms  queue_p99_ms  xds_pushes  k8s_events  connected_proxies  config_size_bytes
```

## Cleanup

```bash
./tests/controlplane/005-cleanup.sh --contexts rosa-001,rosa-002,rosa-003
```

## Scripts

| Script | Purpose |
|--------|---------|
| `001-setup-controlplane-test.sh` | Deploy dummy workloads on target clusters |
| `002-collect-resource-metrics.sh` | Scrape istiod resource usage and Prometheus metrics |
| `003-run-sweep.sh` | Orchestrate deploy/collect/cleanup across mesh sizes |
| `004-report-results.sh` | Generate summary statistics from TSV results |
| `005-cleanup.sh` | Remove all controlplane-test resources |

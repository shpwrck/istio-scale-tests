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

## Sweep Dimensions

`003-run-sweep.sh` iterates the **cross-product** of four independent axes,
so the operator can isolate the effect of each one on istiod cost:

| Axis | Flag | What it changes | Why it matters |
|------|------|-----------------|----------------|
| Mesh size | `--mesh-sizes CSV` | Number of clusters participating | Distinguishes "more clusters" from "more config" |
| Service count | `--service-counts CSV` | Total dummy services per cluster | Push cost scales roughly with services × sidecars |
| Replicas | `--replicas-counts CSV` | Pods per service (endpoint count) | EDS push payload + endpoint update churn |
| Namespace count | `--namespace-counts CSV` | Namespaces holding the services | Exposes namespace-informer overhead at high cardinality |

The sweep runs `len(mesh-sizes) × len(service-counts) × len(replicas-counts) × len(namespace-counts)` combinations. To keep operators from accidentally launching a multi-day sweep, the script **refuses to run a matrix larger than 64 combinations** unless `--force-large-matrix` is passed.

Services are distributed deterministically: service `i` is created in namespace `i mod namespace-count`. When `namespace-count = 1` the single namespace keeps its legacy name (`controlplane-test`), so existing tooling and `--namespace` overrides still work.

## Sweep Examples

```bash
# Default: sweep mesh sizes 1..N, single (10 svc × 3 replicas × 1 ns) point each
./tests/controlplane/003-run-sweep.sh \
  --contexts rosa-001,rosa-002,rosa-003

# Mesh-size × service-count grid (3 × 3 = 9 combos)
./tests/controlplane/003-run-sweep.sh \
  --contexts rosa-001,rosa-002,rosa-003 \
  --mesh-sizes 1,2,3 \
  --service-counts 10,100,500

# Hold mesh fixed; sweep namespace cardinality to expose informer overhead
./tests/controlplane/003-run-sweep.sh \
  --contexts rosa-001,rosa-002,rosa-003 \
  --mesh-sizes 3 \
  --service-counts 200 \
  --namespace-counts 1,5,25,50

# Dry-run prints the planned matrix and exits without touching clusters
./tests/controlplane/003-run-sweep.sh --dry-run \
  --contexts a,b,c --service-counts 10,100 --namespace-counts 1,5

# Bigger sweep that exceeds the 64-combo safety: opt in explicitly
./tests/controlplane/003-run-sweep.sh --force-large-matrix \
  --mesh-sizes 1,2,3 --service-counts 10,100,500,1000 \
  --replicas-counts 1,3,5 --namespace-counts 1,5,25
```

## Watch Mode

Monitor istiod metrics continuously during a load test:

```bash
./tests/controlplane/002-collect-resource-metrics.sh --watch --interval 15
```

## Results Format

TSV files in `tests/controlplane/results/` (gitignored):

```
timestamp  context  mesh_size  service_count  replicas  namespace_count  istiod_cpu_m  istiod_mem_mi  convergence_p50_ms  convergence_p99_ms  queue_p50_ms  queue_p99_ms  xds_pushes  k8s_events  connected_proxies  config_size_bytes
```

`004-report-results.sh` groups rows by `(mesh_size, service_count, replicas, namespace_count)` and emits `text`, `csv`, `json`, or `markdown` summaries via `--format`.

## Cleanup

```bash
./tests/controlplane/005-cleanup.sh --contexts rosa-001,rosa-002,rosa-003
```

Cleanup deletes every namespace labelled `app.kubernetes.io/instance=controlplane-test` on each context — covering both single- and multi-namespace runs — plus the legacy unlabeled `controlplane-test` namespace if present.

## Scripts

| Script | Purpose |
|--------|---------|
| `001-setup-controlplane-test.sh` | Deploy dummy workloads (one sweep point) on target clusters |
| `002-collect-resource-metrics.sh` | Scrape istiod resource usage and Prometheus metrics |
| `003-run-sweep.sh` | Orchestrate the mesh × services × replicas × namespaces cross-product |
| `004-report-results.sh` | Aggregate TSV rows by the four sweep axes (text/csv/json/markdown) |
| `005-cleanup.sh` | Remove all controlplane-test resources |

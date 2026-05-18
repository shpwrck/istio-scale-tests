# Cross-Cluster Data-Plane Latency Test Suite

Measure request latency and throughput through Istio east-west gateways using fortio.

## What Gets Measured

| Metric | How |
|--------|-----|
| Same-cluster baseline latency | fortio client → local fortio server (no east-west gateway) |
| Cross-cluster latency (p50/p90/p99/p99.9/max) | fortio client → remote fortio server (through east-west gateway) |
| Throughput (actual QPS achieved) | fortio load at target QPS levels |
| Latency under load | Multiple QPS levels: 10, 100, 500, 1000 (configurable) |

## Prerequisites

- `oc` or `kubectl`, `helm`, `jq`
- Multi-primary mesh deployed with east-west gateways (see root README)
- Kube contexts configured for each cluster

## Quick Start

```bash
# 1. Deploy fortio server on all clusters, client on source
./dataplane-test/001-setup-dataplane-test.sh \
  --source-context rosa-001 --remote-contexts rosa-002,rosa-003

# 2. Run latency probes
./dataplane-test/002-run-latency-probe.sh \
  --source-context rosa-001 --remote-contexts rosa-002,rosa-003

# 3. View results
./dataplane-test/004-report-results.sh
```

## Sweep Across Mesh Sizes

Compare data-plane latency at different cluster counts:

```bash
./dataplane-test/003-run-sweep.sh \
  --contexts rosa-001,rosa-002,rosa-003 \
  --mesh-sizes 1,2,3

# Dry-run to see plan
./dataplane-test/003-run-sweep.sh --dry-run
```

## Custom QPS Levels

```bash
./dataplane-test/002-run-latency-probe.sh \
  --source-context rosa-001 --remote-contexts rosa-002 \
  --qps-levels 50,200,500 --duration 60 --connections 16
```

## Results Format

TSV files in `dataplane-test/results/` (gitignored):

```
run_id  mesh_size  source_ctx  target_ctx  qps_target  qps_actual  connections  duration_s  p50_ms  p90_ms  p99_ms  p999_ms  max_ms  status
```

## Cleanup

```bash
./dataplane-test/005-cleanup.sh --contexts rosa-001,rosa-002,rosa-003
```

## Scripts

| Script | Purpose |
|--------|---------|
| `001-setup-dataplane-test.sh` | Deploy fortio server and client pods |
| `002-run-latency-probe.sh` | Run fortio load tests and record latency |
| `003-run-sweep.sh` | Orchestrate probes across mesh sizes |
| `004-report-results.sh` | Generate summary statistics from TSV results |
| `005-cleanup.sh` | Remove all dataplane-test resources |

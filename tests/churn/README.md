# Churn / Convergence Test Suite

Measure control-plane convergence time under simultaneous endpoint churn across clusters.

## What Gets Measured

| Metric | How |
|--------|-----|
| Local convergence time | Time until all local proxies are SYNCED after scaling (poll istiod `/debug/syncz`). Cross-check with `source_push_triggers_delta` — a zero value means istiod hadn't processed the change yet. |
| Remote convergence time | Time until remote sidecars see at least 1 new endpoint per deployment (poll watcher Envoy `/clusters`). Threshold = `baseline + deployment_count`, confirming EDS propagation for all services without gating on full pod rollout time. |
| Push triggers delta (source) | `pilot_push_triggers` counter delta on the source cluster's istiod during the churn event |
| Push triggers delta (remote) | `pilot_push_triggers` counter delta summed across all remote istiods |
| xDS pushes delta (source) | `pilot_xds_pushes` counter delta on the source istiod (compare with triggers for coalescing ratio) |
| xDS pushes delta (remote) | `pilot_xds_pushes` counter delta summed across all remote istiods |
| Queue time p99 (source) | `pilot_proxy_queue_time` **delta-window** p99 on the source istiod — computed from pre/post histogram bucket subtraction, isolating only this churn event's queue times. Reported as a bucket range (e.g. `0-100`). |
| Queue time p99 (remote) | `pilot_proxy_queue_time` delta-window p99, max across all remote istiods |

### Inter-iteration settling

After each scale-down, the probe waits for all proxies to reach SYNCED (via syncz polling) before starting the next iteration. This ensures scale-down push storms don't contaminate the next measurement window.

## Prerequisites

- `oc` or `kubectl`, `helm`, `jq`, `curl`
- Multi-primary mesh deployed (see root README)
- Kube contexts configured for each cluster

## Quick Start

```bash
# 1. Deploy churn targets and watcher pods
./tests/churn/001-setup-churn-test.sh --contexts rosa-001,rosa-002,rosa-003

# 2. Run churn probe (scale 5 deployments from 1 to 5 replicas)
./tests/churn/002-run-churn-probe.sh \
  --source-context rosa-001 --remote-contexts rosa-002 \
  --iterations 5

# 3. View results
./tests/churn/004-report-results.sh
```

## Sweep Across Mesh Sizes and Churn Intensities

```bash
# Sweep mesh sizes with default churn
./tests/churn/003-run-sweep.sh \
  --contexts rosa-001,rosa-002,rosa-003 \
  --mesh-sizes 1,2,3

# Sweep churn intensities (5, 10, 20 deployments)
./tests/churn/003-run-sweep.sh \
  --contexts rosa-001,rosa-002 \
  --churn-intensities 5,10,20

# Dry-run
./tests/churn/003-run-sweep.sh --dry-run
```

## Results Format

TSV files in per-sweep subdirectories under `tests/churn/results/` (gitignored):

```
run_id  mesh_size  churn_intensity  base_replicas  scale_to  iteration  t0_epoch_ns  convergence_local_ms  convergence_remote_ms  source_push_triggers_delta  remote_push_triggers_delta  source_xds_pushes_delta  remote_xds_pushes_delta  source_queue_time_p99_ms  remote_queue_time_p99_ms  status
```

## Cleanup

```bash
./tests/churn/005-cleanup.sh --contexts rosa-001,rosa-002,rosa-003
```

## Scripts

| Script | Purpose |
|--------|---------|
| `001-setup-churn-test.sh` | Deploy churn target workloads and watcher pods |
| `002-run-churn-probe.sh` | Trigger scaling events and measure convergence |
| `003-run-sweep.sh` | Orchestrate probes across mesh sizes and churn intensities |
| `004-report-results.sh` | Generate summary statistics from TSV results |
| `005-cleanup.sh` | Remove all churn-test resources |

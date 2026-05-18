# Churn / Convergence Test Suite

Measure control-plane convergence time under simultaneous endpoint churn across clusters.

## What Gets Measured

| Metric | How |
|--------|-----|
| Local convergence time | Time until all local proxies are SYNCED after scaling (poll istiod `/debug/syncz`) |
| Remote convergence time | Time until remote sidecars see updated endpoint counts (poll watcher Envoy `/clusters`) |
| Push triggers delta | `pilot_push_triggers` change during churn event |
| xDS pushes delta | `pilot_xds_pushes` change during churn event (compare with triggers for coalescing ratio) |
| Queue time p99 | `pilot_proxy_queue_time` p99 after churn — how backed up the push queue gets |

## Prerequisites

- `oc` or `kubectl`, `helm`, `jq`, `curl`
- Multi-primary mesh deployed (see root README)
- Kube contexts configured for each cluster

## Quick Start

```bash
# 1. Deploy churn targets and watcher pods
./churn-test/001-setup-churn-test.sh --contexts rosa-001,rosa-002,rosa-003

# 2. Run churn probe (scale 5 deployments from 1 to 5 replicas)
./churn-test/002-run-churn-probe.sh \
  --source-context rosa-001 --remote-contexts rosa-002 \
  --iterations 5

# 3. View results
./churn-test/004-report-results.sh
```

## Sweep Across Mesh Sizes and Churn Intensities

```bash
# Sweep mesh sizes with default churn
./churn-test/003-run-sweep.sh \
  --contexts rosa-001,rosa-002,rosa-003 \
  --mesh-sizes 1,2,3

# Sweep churn intensities (5, 10, 20 deployments)
./churn-test/003-run-sweep.sh \
  --contexts rosa-001,rosa-002 \
  --churn-intensities 5,10,20

# Dry-run
./churn-test/003-run-sweep.sh --dry-run
```

## Results Format

TSV files in `churn-test/results/` (gitignored):

```
run_id  mesh_size  churn_intensity  iteration  t0_epoch_ns  convergence_local_ms  convergence_remote_ms  push_triggers_delta  xds_pushes_delta  queue_time_p99_ms  status
```

## Cleanup

```bash
./churn-test/005-cleanup.sh --contexts rosa-001,rosa-002,rosa-003
```

## Scripts

| Script | Purpose |
|--------|---------|
| `001-setup-churn-test.sh` | Deploy churn target workloads and watcher pods |
| `002-run-churn-probe.sh` | Trigger scaling events and measure convergence |
| `003-run-sweep.sh` | Orchestrate probes across mesh sizes and churn intensities |
| `004-report-results.sh` | Generate summary statistics from TSV results |
| `005-cleanup.sh` | Remove all churn-test resources |

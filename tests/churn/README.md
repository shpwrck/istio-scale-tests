# Churn / Convergence Test Suite

Measure control-plane convergence time under simultaneous endpoint churn across clusters.

## What Gets Measured

| Metric | How |
|--------|-----|
| Local convergence time | Time until all local proxies are SYNCED after scaling (poll istiod `/debug/syncz`). Cross-check with `source_push_triggers_delta` — a zero value means istiod hadn't processed the change yet. |
| Remote endpoint reachable (`remote_endpoint_reachable_ms`) | **Data-plane reachability.** Time until remote sidecars report at least 1 new `health_flags::healthy` endpoint per deployment (poll watcher Envoy `/clusters`; threshold = `baseline + deployment_count`). `health_flags::healthy` requires the source pod to be **Ready** (scheduled + sidecar started), so this is a legitimate end-to-end churn-lifecycle number that **includes** pod scheduling and sidecar startup — not a pure control-plane signal. Analogous to propagation **P3**. (Was `convergence_remote_ms` before the EDS split.) |
| Remote EDS converged (`convergence_remote_eds_ms`) | **Control-plane only.** Time to the **first** remote EDS push after t0 (`pilot_xds_pushes{type="eds"}` delta `>= 1`, summed across the remote's istiod pods). **Pod-boot-free** — answers "how fast does the remote control plane learn the churn and push EDS", the true cross-cluster xDS scaling signal. This times the first cross-cluster EDS push, **not** per-deployment fan-in: istiod debounces/coalesces concurrent scales into fewer than `deployment_count` pushes, so a per-deployment threshold would spuriously TIMEOUT a converged mesh. The counter is mesh-wide, so it does not disambiguate a concurrent unrelated EDS push (acceptable — in a churn run the scale event is the dominant in-window activity). Analogous to propagation **P2**. Churn scales replicas of existing deployments (no Service is created/deleted), so unlike propagation P2 there is **no** clean `pilot_services` registry-delta cross-check available. |
| Push triggers delta (source) | `pilot_push_triggers` counter delta on the source cluster's istiod during the churn event |
| Push triggers delta (remote) | `pilot_push_triggers` counter delta summed across all remote istiods |
| xDS pushes delta (source) | `pilot_xds_pushes` counter delta on the source istiod (compare with triggers for coalescing ratio) |
| xDS pushes delta (remote) | `pilot_xds_pushes` counter delta summed across all remote istiods |
| Queue time p99 (source) | `pilot_proxy_queue_time` **delta-window** p99 on the source istiod — computed from pre/post histogram bucket subtraction, isolating only this churn event's queue times. Reported as a bucket range (e.g. `0-100`). |
| Queue time p99 (remote) | `pilot_proxy_queue_time` delta-window p99, max across all remote istiods |
| Connected proxies (source) | `pilot_xds` gauge on the source istiod — number of xDS-connected proxies at measurement time |
| Connected proxies (remote) | `pilot_xds` gauge summed across all remote istiods |
| Push time p99 (source) | `pilot_xds_push_time` delta-window p99 on the source istiod — time spent computing and sending each xDS push. Reported as a bucket range. |
| Push time p99 (remote) | `pilot_xds_push_time` delta-window p99, max across all remote istiods |
| Push amplification ratio | Derived: `(source_xds_pushes + remote_xds_pushes) / source_push_triggers`. Measures total mesh-wide push fan-out per source event — tracks whether adding clusters causes superlinear push growth. |

### Inter-iteration settling

After each scale-down, the probe waits for all proxies to reach SYNCED (via syncz polling) before starting the next iteration. This ensures scale-down push storms don't contaminate the next measurement window.

## Prerequisites

- `oc` or `kubectl`, `helm`, `jq`, `curl`
- Multi-primary mesh deployed (see root README)
- Kube contexts configured for each cluster

## Quick Start

```bash
# 1. Deploy churn targets and watcher pods
./tests/churn/001-setup-churn-test.sh --contexts cluster-001,cluster-002,cluster-003

# 2. Run churn probe (scale 5 deployments from 1 to 5 replicas)
./tests/churn/002-run-churn-probe.sh \
  --source-context cluster-001 --remote-contexts cluster-002 \
  --iterations 5

# 3. View results
./tests/churn/004-report-results.sh
```

## Sweep Across Mesh Sizes and Churn Intensities

```bash
# Sweep mesh sizes with default churn
./tests/churn/003-run-sweep.sh \
  --contexts cluster-001,cluster-002,cluster-003 \
  --mesh-sizes 1,2,3

# Sweep churn intensities (5, 10, 20 deployments)
./tests/churn/003-run-sweep.sh \
  --contexts cluster-001,cluster-002 \
  --churn-intensities 5,10,20

# Dry-run
./tests/churn/003-run-sweep.sh --dry-run
```

## Results Format

TSV files in per-sweep subdirectories under `tests/churn/results/` (gitignored):

```
run_id  mesh_size  churn_intensity  base_replicas  scale_to  iteration  t0_epoch_ns  convergence_local_ms  remote_endpoint_reachable_ms  convergence_remote_eds_ms  source_push_triggers_delta  remote_push_triggers_delta  source_xds_pushes_delta  remote_xds_pushes_delta  source_queue_time_p99_ms  remote_queue_time_p99_ms  source_connected_proxies  remote_connected_proxies  source_push_time_p99_ms  remote_push_time_p99_ms  status
```

The remote convergence signal is **split into two columns** (mirroring the
propagation suite's P2/P3 distinction):
`remote_endpoint_reachable_ms` is the data-plane reachability time (Envoy
`health_flags::healthy`, includes pod scheduling + sidecar start), and
`convergence_remote_eds_ms` is the control-plane-only EDS-push time
(time to the first `pilot_xds_pushes{type="eds"}` push after t0, delta `>= 1`,
pod-boot-free). The column count is 21;
the report (`004`) requires `NF >= 21` and prints a stderr warning when it
encounters a pre-split (20-column) TSV, whose rows it skips.

The preamble (`#`-comment lines above the header) records run metadata including
`ISTIOD_REPLICAS=<n>` — the number of Running source istiod pods discovered at
preflight (provenance for the per-pod fanout, PL2). Note: churn and
churn-dataplane record this as a single source-context scalar; the propagation
suite records a per-context CSV (`ctx=N,...`) because it fans out over the source
**and** every remote context.

The `status` column is one of: `OK`, `TIMEOUT_LOCAL`, `TIMEOUT_REMOTE`,
`POISONED_RESTART` (a mid-window istiod restart — local or remote — was detected,
so the istiod-side counter/histogram deltas are emitted as `N/A`), or
`SCRAPE_INCOMPLETE` (a per-pod `/metrics` scrape was empty/unreachable, so the
summed counters / merged histograms are undercounted). The report
(`004-report-results.sh`) aggregates numeric columns over `status==OK` rows only
and shows `n_valid`/`n_total` so the filter rate is visible (PL13/PL15).

### Multi-replica istiod fanout

The mesh runs a FIXED multi-replica istiod (HPA disabled). A single
`kubectl port-forward svc/istiod` load-balances to one random replica, so a lone
scrape sees only `~1/replicas` of the proxies/pushes. The probe instead
port-forwards EVERY Running istiod pod per context (`tests/lib/fanout.sh`) and
aggregates: `pilot_xds` (connected proxies) and the counter deltas
(`pilot_push_triggers`, `pilot_xds_pushes`) are **summed** across replicas;
`pilot_proxy_queue_time` / `pilot_xds_push_time` histogram buckets are
**bucket-summed** across replicas before the delta/quantile; `/debug/syncz` is
fanned out across all source pods (converged only when every replica reports 0
stale); the `convergence_remote_eds_ms` poller fans out the
`pilot_xds_pushes{type="eds"}` counter across each remote's istiod pods (summed)
each tick (it reuses a fixed scrape prefix so each tick's per-pod `/metrics`
bodies overwrite the prior tick's — disk stays bounded across the poll window).
Restart detection uses a per-pod
`process_start_time_seconds` signature (any pod's start advancing OR a pod-set
change → `POISONED_RESTART`); a `POISONED_RESTART` row emits `N/A` for
`convergence_remote_eds_ms` too (the remote EDS counter reset on restart). The
probe requires only `>= 1` Running istiod pod per context.

## Cleanup

```bash
./tests/churn/005-cleanup.sh --contexts cluster-001,cluster-002,cluster-003
```

## Scripts

| Script | Purpose |
|--------|---------|
| `001-setup-churn-test.sh` | Deploy churn target workloads and watcher pods |
| `002-run-churn-probe.sh` | Trigger scaling events and measure convergence |
| `003-run-sweep.sh` | Orchestrate probes across mesh sizes and churn intensities |
| `004-report-results.sh` | Generate summary statistics from TSV results |
| `005-cleanup.sh` | Remove all churn-test resources |

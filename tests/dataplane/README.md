# Cross-Cluster Data-Plane Latency Test Suite

Measure request latency and throughput through Istio east-west gateways using fortio.

## What Gets Measured

| Metric | How |
|--------|-----|
| Intra-cluster (sidecar-to-sidecar) baseline latency | fortio client → `dataplane-server` Service (selects local pods under locality LB) |
| Cross-cluster latency (p50/p90/p99/p99.9/max) | fortio client → `dataplane-server-${remote_ctx}` Service (per-cluster selector, no local endpoint, so traffic traverses the east-west gateway) |
| Throughput (actual QPS achieved) | fortio load at target QPS levels |
| HTTP 200 rate (`pct_200`) | Fraction of 200 responses from fortio `RetCodes`; cells with <99% 200s are flagged `ERROR_RATE_HIGH` |
| Latency under load | Multiple QPS levels: 10, 100, 500, 1000 (configurable) |

The **baseline** is _intra-cluster (sidecar-to-sidecar)_, **not** a no-mesh baseline. Both endpoints have sidecars. A real no-mesh baseline would require a no-inject sibling pod and is out of scope.

Use `--repetitions N` on 003 to get multiple independent samples per cell.

## How the Cross-Cluster Probe Works

The chart emits **two Services** per cluster:

1. `dataplane-server` — generic selector. Under `PILOT_ENABLE_LOCALITY_LB=true` (OSSM 3.3 default), traffic from a same-cluster client lands on a local endpoint, so this is the **intra-cluster baseline**.
2. `dataplane-server-${clusterName}` — per-cluster selector (`cluster=${clusterName}` label). The source cluster has no pod matching this selector, so traffic must leave via the east-west gateway. This is what makes the **cross-cluster** probe actually cross-cluster.

## Prerequisites

- `oc` or `kubectl`, `helm`, `jq`
- Multi-primary mesh deployed with east-west gateways (see root README)
- Kube contexts configured for each cluster

## Quick Start

```bash
# 1. Deploy fortio server on all clusters, client on source
./tests/dataplane/001-setup-dataplane-test.sh \
  --source-context cluster-001 --remote-contexts cluster-002,cluster-003

# 2. Run latency probes
./tests/dataplane/002-run-latency-probe.sh \
  --source-context cluster-001 --remote-contexts cluster-002,cluster-003

# 3. View results
./tests/dataplane/004-report-results.sh
```

## Sweep Across Mesh Sizes

Compare data-plane latency at different cluster counts. The sweep mints a `sweep-${RUN_ID}/` subdirectory under `--output-dir` so each sweep's TSVs stay together.

```bash
./tests/dataplane/003-run-sweep.sh \
  --contexts cluster-001,cluster-002,cluster-003 \
  --mesh-sizes 1,2,3

# 3 repetitions per mesh size for statistical confidence:
./tests/dataplane/003-run-sweep.sh \
  --contexts cluster-001,cluster-002,cluster-003 \
  --repetitions 3

# Dry-run to see the planned matrix
./tests/dataplane/003-run-sweep.sh --dry-run
```

## Settle Time

After 001 returns, sidecar xDS endpoints may not have converged on the source cluster. 002 sleeps `--settle SEC` (default 30; env `DATAPLANE_SETTLE_SEC`) before starting any probe to mitigate cold-start cluster-lookup bias on low mesh sizes.

```bash
./tests/dataplane/002-run-latency-probe.sh \
  --source-context cluster-001 --remote-contexts cluster-002 --settle 60
```

## Envoy Warmup

After settle, 002 runs a short throwaway `fortio load` (QPS=10) against every target URL to warm Envoy's upstream mTLS connection pools. Without this, the first few measured requests include lazy TLS handshake latency, inflating tail percentiles.

```bash
# Custom warmup duration (default: 5s; set to 0 to disable):
./tests/dataplane/002-run-latency-probe.sh \
  --source-context cluster-001 --remote-contexts cluster-002 --warmup-duration 10
```

Environment: `DATAPLANE_WARMUP_DURATION_SEC`.

## istiod restart detection

002 port-forwards to istiod on **every cluster** in the mesh and samples `process_start_time_seconds` from each at probe start and end. If any cluster's start time advances, all rows in that run are tagged `istiod_restarted=1`. 004 excludes such rows from numeric aggregation (but still counts them in `n_total`).

## Custom QPS Levels

```bash
./tests/dataplane/002-run-latency-probe.sh \
  --source-context cluster-001 --remote-contexts cluster-002 \
  --qps-levels 50,200,500 --duration 60 --connections 16
```

## Results Format

TSV files in `tests/dataplane/results/sweep-${RUN_ID}/` (gitignored). Schema:

```
run_id  mesh_size  source_ctx  target_ctx  qps_target  qps_actual  connections
duration_s  p50_ms  p90_ms  p99_ms  p999_ms  max_ms
status  pct_200  istiod_restarted  target_class
```

`status` values:
- `OK` — measurement looks good.
- `FAILED` — fortio exec failed (network, pod missing, etc.).
- `PERCENTILE_MISSING` — fortio JSON lacked one of the requested percentiles.
- `ERROR_RATE_HIGH` — `pct_200 < 0.99`.

`target_class`:
- `local` — same cluster as source.
- `remote` — different cluster (routed via east-west gateway).

`istiod_restarted`:
- `0` — istiod process_start_time_seconds unchanged across the probe.
- `1` — istiod restarted; row is poisoned.
- `unknown` — could not scrape istiod metrics.

## Report Formats

```bash
# Aggregated text (default), grouped by (mesh_size, qps_target, target_class):
./tests/dataplane/004-report-results.sh

# Other formats:
./tests/dataplane/004-report-results.sh --format csv
./tests/dataplane/004-report-results.sh --format markdown
./tests/dataplane/004-report-results.sh --format json

# Per-sweep:
./tests/dataplane/004-report-results.sh --results-dir tests/dataplane/results/sweep-20260520T120000Z-12345
```

All formats propagate the TSV preamble metadata (RUN_ID, HARNESS_SHA, ISTIO_VERSION, KUBE_VERSION[ctx], FORTIO_IMAGE, SETTLE_SEC, ...).

## Cleanup

```bash
./tests/dataplane/005-cleanup.sh --contexts cluster-001,cluster-002,cluster-003

# Skip waiting for namespace termination:
./tests/dataplane/005-cleanup.sh --no-wait-deletion --contexts cluster-001
```

## Caveats / Known Limitations

- **No no-mesh baseline.** The "local baseline" still has both sidecars in the path.
- **Avg-of-percentiles.** 004 currently averages percentiles across rows; this is statistically suspect when samples have very different cell counts. Future work: pool raw fortio histograms.
- **Local baseline includes mesh-wide control-plane overhead.** At mesh_size > 1, the local baseline (target_class=local) includes istiod overhead from managing the full multi-cluster mesh. The p99 jump between mesh_size=1 and mesh_size=2 local baselines is real control-plane overhead, not noise. To isolate this, compare local baselines across mesh sizes.

## Scripts

| Script | Purpose |
|--------|---------|
| `001-setup-dataplane-test.sh` | Deploy fortio server and client pods (per-cluster Service + generic Service) |
| `002-run-latency-probe.sh` | Run fortio load tests, record latency + pct_200 + istiod_restarted |
| `003-run-sweep.sh` | Orchestrate probes across mesh sizes into a sweep-${RUN_ID}/ subdir |
| `004-report-results.sh` | Aggregate by (mesh_size, qps_target, target_class), filter poisoned rows, emit text/csv/markdown/json |
| `005-cleanup.sh` | Remove all dataplane-test resources (waits for ns termination by default) |

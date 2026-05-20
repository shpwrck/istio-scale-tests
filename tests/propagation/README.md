# Propagation Latency Test Suite

Automated measurement of how quickly Istio's multi-cluster control plane propagates endpoint changes across clusters.

## What Gets Measured

### Endpoint Propagation (002)

| Phase | What | How |
|-------|------|-----|
| P1 | Local istiod pushes xDS to local sidecars | Delta of `pilot_proxy_convergence_time` histogram on source istiod (converged when delta `_count` reaches connected proxy count). Reports both wall-clock detection time and delta-window p50/p99 of the histogram itself. |
| P2 | Remote istiod discovers new endpoints | Delta of `pilot_xds_pushes{type="eds"}` counter on each remote istiod. First non-zero delta = remote learned about the new endpoint and pushed EDS. |
| P3 | Remote sidecar has HEALTHY endpoints | Watcher pod's Envoy admin `/clusters` polled at >= 1 Hz (the only data-plane-side signal without a custom xDS client). |

In multi-primary Istio, only endpoints propagate cross-cluster. VirtualService and DestinationRule are local config processed only by the istiod that owns the namespace.

### Why histogram-based P1 (not /debug/syncz)

`/debug/syncz` and `/debug/endpointz` serialize the full push context (or endpoint catalogue) per request — at hundreds of services and many clusters that is hundreds of MB of JSON and seconds of CPU per poll. The probe ends up competing with the work it's measuring; the recorded timestamp reflects when istiod could finally serve the debug endpoint, not when convergence happened.

`pilot_proxy_convergence_time` is the same histogram that the repo's `charts/istiod-monitor/templates/prometheusrule.yaml` aggregates into `pilot:proxy_convergence_time:p99_5m`. It records one sample per proxy per push-ACK. The probe captures a snapshot of `_bucket`/`_sum`/`_count` before the canary apply, then polls until the delta `_count` matches the source-cluster connected proxy count — i.e. every connected proxy has ACKed the resulting push.

## Prerequisites

- `oc` or `kubectl`, `helm`, `jq`, `curl`, `awk`
- Multi-primary mesh deployed (see root README)
- Kube contexts configured for each cluster

## Quick Start

```bash
# 1. Setup watcher pods on all clusters
./tests/propagation/001-setup-propagation-test.sh --contexts rosa-001,rosa-002,rosa-003

# 2. Run endpoint probe (2-cluster)
./tests/propagation/002-run-endpoint-probe.sh \
  --source-context rosa-001 --remote-contexts rosa-002 \
  --iterations 10 --tsv

# 3. View results
./tests/propagation/005-report-results.sh
```

## Sweep Across Mesh Sizes

Compare propagation latency at different cluster counts:

```bash
# Run probes at mesh_size=1, 2, 3
./tests/propagation/006-run-sweep.sh \
  --contexts rosa-001,rosa-002,rosa-003 \
  --mesh-sizes 1,2,3 \
  --iterations 5 --tsv

# Dry-run prints the planned matrix to stderr without touching clusters
./tests/propagation/006-run-sweep.sh \
  --contexts rosa-001,rosa-002,rosa-003 \
  --mesh-sizes 1,2,3 --dry-run
```

Each sweep writes into `tests/propagation/results/sweep-${RUN_ID}/` so individual sweep runs are not interleaved with one another.

The sweep orchestrator:
1. Sets up watcher pods on clusters for each mesh size
2. Runs endpoint probe (002) at each size
3. Sleeps `--settle-sec` (default 5s) between mesh-size steps
4. Generates a comparison report grouped by mesh_size

## Passive Metrics Collection

### Via port-forward (004)

```bash
# One-shot snapshot
./tests/propagation/004-collect-pilot-metrics.sh --contexts rosa-001,rosa-002

# Watch mode during load test
./tests/propagation/004-collect-pilot-metrics.sh --watch --interval 10
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

TSV files in `tests/propagation/results/` (gitignored). Sweep runs use `tests/propagation/results/sweep-${RUN_ID}/`.

### TSV preamble

Each TSV begins with `# KEY=VALUE` comment lines:

```
# RUN_ID=20250520T101530-12345
# HARNESS_SHA=abc1234
# ISTIO_VERSION=v1.28.5
# KUBE_VERSIONS=rosa-001=v1.34.6,rosa-002=v1.34.6,rosa-003=unreachable
# SOURCE_CTX=rosa-001
# REMOTES=rosa-002 rosa-003
# MESH_SIZE=3
# ITERATIONS=10
# POLL_INTERVAL_S=0.250
# TIMEOUT_SEC=120
# SETTLE_SEC=5
# DATE=2025-05-20T10:15:30+00:00
```

`KUBE_VERSIONS` is probed concurrently with `--request-timeout=5s`; unreachable contexts emit `unreachable`, contexts that respond without parseable version emit `unknown`.

### TSV columns

```
run_id  mesh_size  iteration  source_ctx  remote_ctx  t0_epoch_ns
p1_ms  p2_ms  p3_ms  status
p1_conv_p50_ms  p1_conv_p99_ms  p1_sample_count  p1_proxy_count  p1_overflow
restarted  window_ms  scrape_skew_ms
```

| Column | Meaning |
|--------|---------|
| `p1_ms` | Wall-clock ms from canary apply until source istiod histogram delta `_count` reached the proxy count. `TIMEOUT` or `N/A` (when `restarted=1`). |
| `p2_ms` | Wall-clock ms until remote istiod `pilot_xds_pushes{type="eds"}` delta > 0. |
| `p3_ms` | Wall-clock ms until watcher Envoy `/clusters` reports healthy canary endpoints. |
| `p1_conv_p50_ms`, `p1_conv_p99_ms` | Quantiles computed over the per-bucket delta of the source-istiod histogram across the iteration window. `N/A` if `restarted=1`. `overflow` if quantile falls in the `+Inf` bucket. |
| `p1_sample_count` | `attempted/got` — `proxy_count` and delta-`_count`. |
| `p1_overflow` | `1` if the `+Inf` bucket gained more samples than any finite bucket (statistically unsafe — quantiles below). |
| `restarted` | `0`/`1` — `1` if `process_start_time_seconds` on the source istiod changed mid-iteration. |
| `window_ms` | Wall-clock duration of the per-iteration measurement window. |
| `scrape_skew_ms` | Worst-case skew between concurrent baseline scrapes across contexts. |

Old `p1_ms`/`p2_ms`/`p3_ms` columns are preserved (pre-branch TSV readers continue to work). Histogram-derived columns are appended after.

### Reporting

`005-report-results.sh`:

- Filters out rows where `restarted=1` or `p1_overflow=1`.
- Emits both `n_total` (rows considered) and `n_valid` (rows used).
- Carries forward all preamble metadata into `text`, `csv`, `json`, and `markdown` output.

## Cleanup

```bash
./tests/propagation/007-cleanup.sh --contexts rosa-001,rosa-002,rosa-003
```

## Scripts

| Script | Purpose |
|--------|---------|
| `001-setup-propagation-test.sh` | Deploy/cleanup watcher pods and namespace |
| `002-run-endpoint-probe.sh` | Measure endpoint propagation (P1/P2/P3) via `pilot_proxy_convergence_time` + `pilot_xds_pushes{type="eds"}` + watcher Envoy |
| `004-collect-pilot-metrics.sh` | Scrape istiod Prometheus metrics |
| `005-report-results.sh` | Generate summary statistics from TSV results |
| `006-run-sweep.sh` | Orchestrate probes across multiple mesh sizes; writes into per-sweep `sweep-${RUN_ID}/` subdir |
| `007-cleanup.sh` | Remove all propagation-test resources |

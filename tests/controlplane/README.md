# Control-Plane Resource Scaling Test Suite

Measure istiod CPU, memory, and xDS metrics as a function of mesh size, workload
density, and `Sidecar` CR scoping.

## What Gets Measured

| Metric | Source | What it shows |
|--------|--------|---------------|
| istiod CPU (millicores) | `kubectl top pod` | Control-plane CPU cost per cluster count |
| istiod Memory (MiB) | `kubectl top pod` | Control-plane memory cost per cluster count |
| `pilot_proxy_convergence_time` p50/p99 (delta) | istiod Prometheus | How fast config reaches all sidecars |
| `pilot_proxy_queue_time` p50/p99 (delta) | istiod Prometheus | How long pushes wait in istiod's queue |
| `pilot_xds_pushes` (delta) | istiod Prometheus | Total xDS push count over the window |
| `pilot_k8s_cfg_events` (delta) | istiod Prometheus | Kubernetes watch event rate |
| `pilot_xds` | istiod Prometheus | Connected proxy count (gauge) |
| `pilot_xds_config_size_bytes` (delta) | istiod Prometheus | xDS push payload size accumulator |
| `process_start_time_seconds` | istiod Prometheus | Restart detection across the window |
| Per-sidecar `/config_dump` byte size | `kubectl exec` into istio-proxy | **Real** per-proxy config cost per scoping mode |

All histogram and counter metrics are reported as **deltas over the scrape
window** (baseline snapshot, settle, final snapshot). The reported
`scrape_window_sec` is the wall-clock interval between snapshots.

## Sidecar scoping

`Sidecar` CRs are istiod's primary scaling lever: they limit per-proxy
configuration to only the upstream services the workload actually needs.
Without them, every proxy gets every Service in the mesh, and per-proxy config
grows `O(services × sidecars)`.

This suite sweeps three modes:

| Mode | Sidecar CRs | Effect |
|------|-------------|--------|
| `none` | 0 | Baseline / worst case: every proxy sees every Service in the mesh. |
| `namespace` | 1 per workload namespace (no `workloadSelector`) | Realistic operator config. `egress.hosts` restricts each proxy to its own namespace + `istio-system`. |
| `explicit` | 1 per Deployment (with `workloadSelector.labels.app: dummy-svc-<i>`) | Maximum precision; many CRs, smallest per-proxy config. |

Expected per-proxy config size ordering: `none` ≫ `namespace` ≥ `explicit`.
The 003 sweep cross-products `(mesh_size × sidecar_scoping)` so 004 can render
the reduction percentage as the headline of the report.

## Prerequisites

- `oc` or `kubectl`, `helm`, `jq`, `curl`
- Multi-primary mesh deployed (see root README)
- Kube contexts configured for each cluster

## Quick Start

```bash
# 1. Deploy dummy workloads on all clusters (baseline; no Sidecar CRs).
./tests/controlplane/001-setup-controlplane-test.sh --contexts rosa-001,rosa-002,rosa-003

# 2. Collect metrics snapshot (delta-window).
./tests/controlplane/002-collect-resource-metrics.sh --contexts rosa-001,rosa-002,rosa-003

# 3. View results.
./tests/controlplane/004-report-results.sh
```

## Sweep Across (mesh size × sidecar scoping)

Compare istiod resource consumption and per-proxy config size at different
cluster counts and scoping modes:

```bash
# Full 3×3 sweep: 1,2,3 clusters × none,namespace,explicit
./tests/controlplane/003-run-sweep.sh \
  --contexts rosa-001,rosa-002,rosa-003 \
  --mesh-sizes 1,2,3 \
  --sidecar-scopings none,namespace,explicit \
  --service-count 50

# Dry-run to see plan without executing.
./tests/controlplane/003-run-sweep.sh --dry-run \
  --contexts a,b --sidecar-scopings none,namespace,explicit
```

Singular `--sidecar-scoping VALUE` and `--mesh-size N` aliases are accepted for
muscle-memory parity with 001/002 but print a deprecation warning to stderr.

## Watch Mode

Monitor istiod metrics continuously during a load test (raw cumulative values,
no delta):

```bash
./tests/controlplane/002-collect-resource-metrics.sh --watch --interval 15
```

## Results Format

TSV files in `tests/controlplane/results/sweep-<RUN_ID>/` (gitignored). Each
TSV starts with a `#`-prefixed preamble that records `RUN_ID`, `HARNESS_SHA`,
`ISTIO_VERSION`, kube versions per context, settle/scoping/sample counts.

The data schema (tab-separated columns) is:

```
timestamp
context
mesh_size
service_count
replicas
sidecar_scoping             # none | namespace | explicit
istiod_cpu_m
istiod_mem_mi
convergence_p50_ms          # delta-window p50; "overflow" when target falls in +Inf bucket
convergence_p99_ms          # delta-window p99; "overflow" possible
queue_p50_ms                # delta-window p50
queue_p99_ms                # delta-window p99
xds_pushes                  # delta over window
k8s_events                  # delta over window
connected_proxies           # instantaneous gauge from final snapshot
config_size_bytes           # pilot_xds_config_size_bytes delta
sidecar_config_bytes_avg    # mean of per-pod /config_dump bytes
sidecar_config_bytes_p50    # median of per-pod /config_dump bytes
sidecar_config_bytes_max    # max of per-pod /config_dump bytes
sidecar_config_bytes_samples  # actual samples retrieved (decremented on exec failure)
scrape_window_sec           # wall-clock window: min(final.start) - max(baseline.end)
scrape_skew_ms              # max(ts) - min(ts) across contexts in either snapshot
istiod_restarted            # 0 | 1 | unknown (when either process_start_time was missing)
settle_sec                  # operator's --settle input (intent)
```

## Cleanup

```bash
./tests/controlplane/005-cleanup.sh --contexts rosa-001,rosa-002,rosa-003
```

Cleanup awaits namespace deletion (PL4) and confirms no `Sidecar` CRs remain;
since `Sidecar` is namespace-scoped, removing the namespace removes them.

## Scripts

| Script | Purpose |
|--------|---------|
| `001-setup-controlplane-test.sh` | Deploy dummy workloads + Sidecar CRs on target clusters |
| `002-collect-resource-metrics.sh` | Delta-window scrape istiod metrics + sample per-pod /config_dump |
| `003-run-sweep.sh` | Orchestrate deploy/collect/cleanup across (mesh_size × sidecar_scoping) |
| `004-report-results.sh` | Aggregate TSVs and emit text/csv/markdown/json reports |
| `005-cleanup.sh` | Remove all controlplane-test resources |

## Known limitations

- **`/config_dump` exec cost is O(N samples × clusters × combos)**: at default
  `--config-dump-samples 3` and a 3×3 sweep with 3 clusters, that's 81
  per-pod exec round-trips per full sweep. Each exec runs `curl localhost:15000`
  inside the `istio-proxy` container; clusters under heavy churn may see exec
  timeouts. Set `--config-dump-samples 0` to disable sampling entirely.
- **Watch mode reports raw cumulative metrics**, not deltas. Use one-shot mode
  for percentile / counter measurements over a defined window.
- **`namespaceCount > 1` is honoured by the Sidecar template** but the runtime
  sweep across namespace counts is owned by a sibling branch. Until that lands,
  only the single-namespace deployment is created at apply time even when
  multiple Sidecar CRs are rendered.

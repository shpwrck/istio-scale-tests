# Control-Plane Resource Scaling Test Suite

Measure istiod CPU, memory, and xDS metrics as a function of mesh size and workload density.

## What Gets Measured

All histogram and counter metrics are computed as **deltas over a wall-clock
window**. The 003 sweep splits the window into three phases per combo so the
work itself lands inside the measurement:

1. **Baseline scrape** — `002 --phase baseline` runs *before* 001 deploys.
2. **Deploy + settle** — 001 creates the workloads; 003 then sleeps `--settle`.
3. **Final scrape + emit** — `002 --phase final` reads the baseline back from
   `--state-dir`, scrapes again, and writes one TSV row covering the entire
   baseline → deploy → settle window.

This is why the rate denominators (`xds_pushes_rate`, `cpu_m_delta`,
histogram quantile windows, etc.) are meaningful: they cover the period when
istiod is actually pushing config to sidecars. Earlier versions ran 002 only
*after* 001 returned, by which point the push storm was already over and the
delta read ~0 even on a 60-service deploy.

Standalone use of 002 (without 003) still works via the default
`--phase combined`, which does baseline → sleep → final in one invocation.
Operators just need to know that combined-mode measures the *settle window
only*, not the deploy itself.

| Metric | Source | What it shows |
|--------|--------|---------------|
| istiod CPU window-average (millicores) | `process_cpu_seconds_total` delta over the scrape window | **Primary** CPU measurement — average millicores consumed during the actual push window. `N/A` if istiod restarted (counter resets), baseline scrape was missing, or window was non-positive |
| istiod CPU spot-check (millicores) | `kubectl top pod` snapshot taken after settle | Single point-in-time CPU sample retained for sanity-check comparison; reads near-idle on quiet istiods because all push work has already completed when the snapshot fires. Use `istiod_cpu_m_delta` for analysis |
| istiod Memory (MiB) | `kubectl top pod` | Control-plane memory cost per cluster count (memory is a gauge, so a snapshot is representative) |
| `pilot_proxy_convergence_time` p50/p99 (delta) | istiod Prometheus | How fast config reaches all sidecars during the window |
| `pilot_proxy_queue_time` p50/p99 (delta) | istiod Prometheus | How long pushes wait in istiod's queue during the window |
| `pilot_xds_pushes` delta + rate | istiod Prometheus | xDS push count during the window (and per-second rate) |
| `pilot_xds_pushes` by type | istiod Prometheus | One column per xDS type (cds, eds, lds, rds, nds) so EDS-vs-CDS scaling can be separated |
| `pilot_k8s_cfg_events` delta + rate | istiod Prometheus | Kubernetes watch events during the window |
| `pilot_xds` | istiod Prometheus | Connected proxy count (gauge — read from final scrape) |
| `pilot_xds_config_size_bytes` avg | istiod Prometheus | Average xDS payload bytes during the window (histogram `_sum`/`_count` delta) |
| `scrape_window_sec` / `scrape_skew_ms` | Internal | Actual wall-clock window length (conservative: `min(final.start) − max(baseline.end)`, used as the rate denominator) and max clock skew across concurrent per-context scrapes |
| `settle_sec` | Internal | Operator-supplied `--settle` value (intent — distinct from `scrape_window_sec` which is the observed elapsed window) |
| `istiod_restarted` | istiod Prometheus | `1` if `process_start_time_seconds` moved forward between baseline and final scrape (istiod restarted mid-window — counters/histograms for that row under-report); `0` if both readings were present and equal; the literal string `unknown` if either side's `process_start_time_seconds` was missing (e.g. baseline scrape failed) so we couldn't tell |
| `istiod_cpu_m_delta` | istiod Prometheus | Primary CPU metric: `(final − baseline) ÷ scrape_window_sec × 1000` from `process_cpu_seconds_total`. Replaces the `kubectl top` snapshot as the main CPU column because the snapshot misses the actual work period (settle has already concluded by the time `top` fires, so istiod reads idle) |

Histogram cells whose target quantile lands in the `+Inf` overflow bucket are
emitted as the literal string `overflow` in TSV/CSV/text/markdown outputs and
as JSON `null` in JSON output — so an operator can spot "p99 is above our
biggest bucket" rather than seeing a misleading `0`.

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

| Axis | Flag (CSV) | Singular alias (one value) | What it changes | Why it matters |
|------|------------|----------------------------|-----------------|----------------|
| Mesh size | `--mesh-sizes CSV` | (CSV only) | Number of clusters participating | Distinguishes "more clusters" from "more config" |
| Service count | `--service-counts CSV` | `--service-count N` | Total dummy services per cluster | Push cost scales roughly with services × sidecars (CDS load) |
| Replicas | `--replica-counts CSV` | `--replicas N` | Pods per service (endpoint count) | EDS push payload + endpoint update churn |
| Namespace count | `--namespace-counts CSV` | `--namespace-count N` | Namespaces holding the services | Exposes namespace-informer overhead at high cardinality |

Splitting "service count" from "replica count" lets you separate CDS scaling
(driven by service count) from EDS scaling (driven by endpoint count =
services × replicas) — the new TSV emits per-type push deltas
(`xds_pushes_cds`, `xds_pushes_eds`, …) to make that comparison direct.

The sweep runs `len(mesh-sizes) × len(service-counts) × len(replica-counts) × len(namespace-counts)` combinations. To keep operators from accidentally launching a multi-day sweep, the script **refuses to run a matrix larger than `CONTROLPLANE_MAX_MATRIX` combinations** (default 64) unless `--force-large-matrix` is passed.

Services are distributed deterministically: service `i` is created in namespace `i mod namespace-count`. When `namespace-count = 1` the single namespace keeps its legacy name (`controlplane-test`), so existing tooling and `--namespace` overrides still work.

### Known limitations / out of scope

- **Service distribution across namespaces is uniform**; real meshes are
  long-tail (Zipf). Treat namespace-count results as a *lower bound* on
  per-namespace push cost.
- **This branch measures kube-apiserver / namespace-informer cardinality.**
  Istiod's per-namespace `Sidecar` CR resolution cost is measured in branch
  `claude/scale-test/sidecar-scoping` (next).
- **No `--samples N` repeated scrapes per cell** — every sweep point is a
  single (baseline + final) window. Re-run the sweep to get N samples per
  cell.
- **Settle time is single-valued** across the entire sweep. The operator's
  intent is recorded per-row in the TSV (`settle_sec`), while the observed
  wall-clock window lives in `scrape_window_sec` — auto-scaling settle time
  as a function of matrix point is out of scope.
- **No resource-quota or node-capacity precheck.** The sweep will happily
  schedule workloads it cannot fit; verify cluster headroom manually before
  large runs.
- **Each `002` invocation generates a fresh `RUN_ID` and writes a new TSV;
  the script is not resumable across operator retries.** A retry produces a
  separate TSV in the per-sweep subdir — `004` will aggregate every TSV it
  finds in `--results-dir`, so retries appear as additional samples under
  the same `(mesh_size, service_count, replicas, namespace_count)` 4-tuple
  rather than replacing the earlier row.

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
  --replica-counts 1,3,5 --namespace-counts 1,5,25

# Singular aliases — handy for copy-paste from older single-value invocations
./tests/controlplane/003-run-sweep.sh \
  --contexts rosa-001 --service-count 50 --replicas 3
```

## Watch Mode

Monitor istiod metrics continuously during a load test:

```bash
./tests/controlplane/002-collect-resource-metrics.sh --watch --interval 15
```

## Results Format

Each sweep gets its own subdirectory under `tests/controlplane/results/`:
`results/sweep-<RUN_ID>/controlplane-<RUN_ID>.tsv`. Back-to-back sweeps never
conflate. TSV files carry a metadata preamble:

```
# Control-plane resource metrics — 2026-05-20T18:32:01+00:00
# ISTIO_VERSION=1.24.0
# HARNESS_SHA=4139b50
# KUBE_VERSIONS=rosa-001=v1.29.4, rosa-002=v1.29.4, rosa-003=v1.29.4
# SETTLE_SEC=60
# RUN_ID=20260520T183201Z-12345
```

The `KUBE_VERSIONS` preamble records one entry per `--contexts` value. Each value is either the apiserver `gitVersion` (e.g. `v1.30.4`), or one of:

- `unreachable` — `kubectl version` returned a non-zero exit (timeout or connection refused) within `--request-timeout=5s`. The cluster could not be contacted at sweep startup.
- `unknown` — `kubectl version` succeeded but `jq .serverVersion.gitVersion` returned empty (unexpected schema, very old client). The cluster *was* reachable; we just couldn't parse a version out of the response.

Followed by the 28-column data schema:

```
timestamp  context  mesh_size  service_count  replicas  namespace_count
istiod_cpu_m  istiod_mem_mi
convergence_p50_ms  convergence_p99_ms  queue_p50_ms  queue_p99_ms
xds_pushes_delta  xds_pushes_rate
xds_pushes_cds  xds_pushes_eds  xds_pushes_lds  xds_pushes_rds  xds_pushes_nds
k8s_events_delta  k8s_events_rate
connected_proxies  config_size_avg_bytes
scrape_window_sec  scrape_skew_ms
settle_sec  istiod_restarted
istiod_cpu_m_delta
```

`scrape_window_sec` is the observed wall-clock window — `min(final.start) − max(baseline.end)` in seconds (one decimal) — used as the denominator for `xds_pushes_rate` and `k8s_events_rate`. The lower bound is each baseline scrape's *end* timestamp (not its start), so the window represents the conservative interval every counter saw the same elapsed time. `settle_sec` is the operator's `--settle` value; surfacing both lets operators see intent vs. actual elapsed window. `istiod_restarted` is `1` when istiod's `process_start_time_seconds` moved forward between baseline and final (counters reset mid-window, row's deltas under-report), `0` when both readings were present and equal, or the literal string `unknown` when either side's `process_start_time_seconds` was missing.

`004-report-results.sh` groups rows by `(mesh_size, service_count, replicas, namespace_count)` and emits `text`, `csv`, `json`, or `markdown` summaries via `--format`. Each output carries the same `ISTIO_VERSION` / `HARNESS_SHA` / `files_consumed` / `skipped_legacy` metadata (preamble in text/csv, frontmatter in markdown, top-level object in JSON). Each aggregated row also gains a `restarts` column counting how many input rows for that 4-tuple had `istiod_restarted=1`; markdown output appends a footnote when any restarts occurred. Legacy TSV files with the pre-28-column schema are skipped with a stderr warning.

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

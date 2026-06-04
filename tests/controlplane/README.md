# Control-Plane Resource Scaling Test Suite

Measure istiod CPU, memory, and xDS metrics as a function of mesh size, workload
density, namespace cardinality, and `Sidecar` CR scoping.

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
| istiod CPU (millicores) | `process_cpu_seconds_total` delta over the scrape window | Peak of (window-average millicores, peak 5-second interval rate). The poller samples every 5 s during the settle window so deploy-time CPU spikes are captured even if they subside before the final scrape. `N/A` if istiod restarted (counter resets), baseline scrape was missing, or window was non-positive |
| istiod Memory (MiB) | `process_resident_memory_bytes` from istiod `/metrics` | Peak of (baseline, polled samples, final scrape). A background poller samples every 5 s during the measurement window so memory spikes during the deploy storm are captured even if RSS settles before the final scrape |
| `pilot_proxy_convergence_time` p50/p99 (delta) | istiod Prometheus | How fast config reaches all sidecars during the window |
| `pilot_proxy_queue_time` p50/p99 (delta) | istiod Prometheus | How long pushes wait in istiod's queue during the window |
| `pilot_xds_pushes` delta + rate | istiod Prometheus | xDS push count during the window (and per-second rate) |
| `pilot_xds_pushes` by type | istiod Prometheus | One column per xDS type (cds, eds, lds, rds, nds) so EDS-vs-CDS scaling can be separated |
| `pilot_k8s_cfg_events` delta + rate | istiod Prometheus | Kubernetes watch events during the window |
| `pilot_xds` | istiod Prometheus | Connected proxy count (gauge — read from final scrape) |
| `pilot_xds_config_size_bytes` avg | istiod Prometheus | Average xDS payload bytes during the window (histogram `_sum`/`_count` delta) |
| Per-sidecar `/config_dump` size (MB) | `pilot-agent request` into istio-proxy | **Real** per-proxy config cost per scoping mode |
| `scrape_window_sec` / `scrape_skew_ms` | Internal | Actual wall-clock window length and max clock skew across concurrent per-context scrapes |
| `settle_sec` | Internal | Operator-supplied `--settle` value (intent — distinct from `scrape_window_sec` which is the observed elapsed window) |
| `istiod_restarted` | istiod Prometheus | `1` if `process_start_time_seconds` moved forward between baseline and final scrape; `0` if both readings were present and equal; `unknown` if either side was missing |
| `istiod_cpu_m_delta` | istiod Prometheus | CPU metric: `(final − baseline) ÷ scrape_window_sec × 1000` from `process_cpu_seconds_total` |

Histogram cells whose target quantile lands in the `+Inf` overflow bucket are
emitted as the literal string `overflow` in TSV/CSV/text/markdown outputs and
as JSON `null` in JSON output.

## Sidecar Scoping

`Sidecar` CRs are istiod's primary scaling lever: they limit per-proxy
configuration to only the upstream services the workload actually needs.
Without them, every proxy gets every Service in the mesh, and per-proxy config
grows `O(services × sidecars)`.

This suite sweeps three modes:

| Mode | Sidecar CRs | Effect |
|------|-------------|--------|
| `none` | 0 | Baseline / worst case: every proxy sees every Service in the mesh. |
| `namespace` | 1 in the primary namespace (no `workloadSelector`) | Realistic operator config. `egress.hosts` restricts each proxy to its own namespace + `istio-system`. |
| `explicit` | 1 per Deployment (with `workloadSelector.labels.app: dummy-svc-<i>`) | Maximum precision; many CRs, smallest per-proxy config. |

Expected per-proxy config size ordering: `none` >> `namespace` >= `explicit`.
The 003 sweep cross-products all five axes so 004 can render the reduction
percentage in the markdown report.

## Multi-Replica istiod

The suite supports any number of istiod replicas. Each running istiod pod
gets its own port-forward and emits its own TSV row, so per-replica resource
consumption is visible. In split-phase mode (`003` orchestrator), a `pods.tsv`
manifest is persisted to `--state-dir` during the baseline phase and reloaded
during the final phase, ensuring baseline and final scrapes always target the
same physical process.

If a pinned pod disappears between phases (e.g. HPA scale-down or restart),
the row is emitted with `istiod_restarted=unknown` and counter/histogram
deltas are excluded from aggregation.

## Fault-tolerance: degraded rows and the `context` sentinel

The suite never aborts a multi-hour sweep on a single per-combo failure. Instead
it records a **degraded row** that is counted in `n_total` but excluded from
`n_valid` (the report admits a row to `n_valid` only when `istiod_restarted == 0`,
so every degraded row carries `istiod_restarted=unknown` and `N/A` for all
counter/histogram/gauge columns — PL13/PL15). The `context` column carries a
sentinel naming the fault:

| `context` sentinel | Emitted by | Meaning |
| ------------------ | ---------- | ------- |
| `SETUP_FAILED` | `003-run-sweep.sh` | `001-setup` exited non-zero for this combo; the background peak poller is stopped, a row is recorded, cleanup runs, and the sweep continues. |
| `PROBE_FAILED` | `003-run-sweep.sh` | The baseline or final `002` scrape exited non-zero for this combo. |
| `ZERO_PODS` | `002-collect-resource-metrics.sh` | A context had **zero running istiod pods** (whole-cluster istiod outage — a rolling restart normally leaves ≥1 Running replica, so it does NOT trip this). The context is dropped from the scrape set and this degraded row records that the combo measured fewer control planes than requested. `002` still `die`s only when **all** contexts are zero-pod. |

The sweep TSV preamble is pre-created by `003` before the first combo, so a
first-combo `SETUP_FAILED`/`PROBE_FAILED` cannot strip the run's provenance
(`ISTIO_VERSION`/`HARNESS_SHA`/`KUBE_VERSIONS`) — the metadata always survives.

## Histogram Bucket Ranges

Convergence and queue-time p99 values are reported as **bucket ranges**
(e.g. `0-100`) rather than point values, since the underlying Prometheus
histograms only resolve to bucket boundaries. The bucket boundaries compiled
into istiod are: 100, 500, 1000, 3000, 5000, 10000, 20000, 30000 ms
(i.e. 0.1, 0.5, 1, 3, 5, 10, 20, 30 s).
A reported range of `100-500` means the p99 fell in the bucket with upper
bound 500 ms — the actual value is somewhere in that interval.

## Prerequisites

- `oc` or `kubectl`, `helm`, `jq`, `curl`
- Multi-primary mesh deployed (see root README)
- Kube contexts configured for each cluster

## Quick Start

```bash
# 1. Deploy dummy workloads on all clusters (baseline; no Sidecar CRs).
./tests/controlplane/001-setup-controlplane-test.sh --contexts cluster-001,cluster-002,cluster-003

# 2. Collect metrics snapshot (delta-window).
./tests/controlplane/002-collect-resource-metrics.sh --contexts cluster-001,cluster-002,cluster-003

# 3. View results.
./tests/controlplane/004-report-results.sh
```

## Sweep Dimensions

`003-run-sweep.sh` iterates the **cross-product** of five independent axes:

| Axis | Flag (CSV) | Singular alias | What it changes | Why it matters |
|------|------------|----------------|-----------------|----------------|
| Mesh size | `--mesh-sizes CSV` | (CSV only) | Number of clusters participating | Distinguishes "more clusters" from "more config" |
| Service count | `--service-counts CSV` | `--service-count N` | Total dummy services per cluster | Push cost scales roughly with services x sidecars (CDS load) |
| Replicas | `--replica-counts CSV` | `--replicas N` | Pods per service (endpoint count) | EDS push payload + endpoint update churn |
| Namespace count | `--namespace-counts CSV` | `--namespace-count N` | Namespaces holding the services | Exposes namespace-informer overhead at high cardinality |
| Sidecar scoping | `--sidecar-scopings CSV` | `--sidecar-scoping MODE` | Sidecar CR mode: none, namespace, explicit | Per-proxy config size / push cost reduction |

The sweep runs `mesh-sizes x service-counts x replica-counts x namespace-counts x sidecar-scopings` combinations. To keep operators from accidentally launching a multi-day sweep, the script **refuses to run a matrix larger than `CONTROLPLANE_MAX_MATRIX` combinations** (default 64) unless `--force-large-matrix` is passed.

Services are distributed deterministically: service `i` is created in namespace `i mod namespace-count`. When `namespace-count = 1` the single namespace keeps its legacy name (`controlplane-test`).

## Sweep Examples

```bash
# Default: sweep mesh sizes 1..N, single (10 svc x 3 replicas x 1 ns x none) point each
./tests/controlplane/003-run-sweep.sh \
  --contexts cluster-001,cluster-002,cluster-003

# Mesh-size x service-count grid (3 x 3 = 9 combos)
./tests/controlplane/003-run-sweep.sh \
  --contexts cluster-001,cluster-002,cluster-003 \
  --mesh-sizes 1,2,3 \
  --service-counts 10,100,500

# Full 3x3 sidecar scoping sweep
./tests/controlplane/003-run-sweep.sh \
  --contexts cluster-001,cluster-002,cluster-003 \
  --mesh-sizes 1,2,3 \
  --sidecar-scopings none,namespace,explicit \
  --service-count 50

# Hold mesh fixed; sweep namespace cardinality to expose informer overhead
./tests/controlplane/003-run-sweep.sh \
  --contexts cluster-001,cluster-002,cluster-003 \
  --mesh-sizes 3 \
  --service-counts 200 \
  --namespace-counts 1,5,25,50

# Dry-run prints the planned matrix and exits without touching clusters
./tests/controlplane/003-run-sweep.sh --dry-run \
  --contexts a,b,c --service-counts 10,100 --sidecar-scopings none,namespace

# Disable config_dump sampling (faster sweep, no exec round-trips)
./tests/controlplane/003-run-sweep.sh \
  --contexts cluster-001 --config-dump-samples 0
```

`SETTLE_SEC` is applied at TWO points inside each combo: (1) between the
deploy step (001) and the final scrape, (2) **after** the combo's namespace
deletion in 005, before the next combo's 001. The post-cleanup settle lets
istiod finish re-pushing the broader (no-Sidecar) config to remaining
proxies, so the previous combo's post-cleanup settle serves as a de facto
pre-baseline rest for subsequent combos.

## Watch Mode

Monitor istiod metrics continuously during a load test (raw cumulative values,
no delta):

```bash
./tests/controlplane/002-collect-resource-metrics.sh --watch --interval 15
```

The O9 capacity columns (node/istiod utilization, pods scheduled) are re-read at
the start of each watch window rather than memoized once, so a long-running watch
tracks capacity changes instead of freezing them at the first window's reading.

## Results Format

Each sweep gets its own subdirectory under `tests/controlplane/results/`:
`results/sweep-<RUN_ID>/controlplane-<RUN_ID>.tsv`. Back-to-back sweeps never
conflate. TSV files carry a metadata preamble:

```
# Control-plane resource metrics — 2026-05-20T18:32:01+00:00
# ISTIO_VERSION=1.24.0
# HARNESS_SHA=4139b50
# KUBE_VERSIONS=cluster-001=v1.29.4, cluster-002=v1.29.4, cluster-003=v1.29.4
# SIDECAR_SCOPING=none
# CONTROLPLANE_SCHEMA=40
# CONFIG_DUMP_SAMPLES=3
# SETTLE_SEC=60
# RUN_ID=20260520T183201Z-12345
# NODE_ALLOC_CPU_M=16000
# NODE_ALLOC_MEM_MI=64000
# ISTIOD_CPU_LIMIT_M=2000
# ISTIOD_MEM_LIMIT_MI=8192
# SCALE_TARGET_FRACTION=0.7
```

The `KUBE_VERSIONS` preamble records one entry per `--contexts` value. Each
value is either the apiserver `gitVersion` (e.g. `v1.30.4`), `unreachable`, or
`unknown`. The `NODE_ALLOC_*` / `ISTIOD_*_LIMIT_*` / `SCALE_TARGET_FRACTION`
keys (O9 scale-coverage legibility) are read once from the source context via
read-only `kubectl get`; any may be `unknown` if the cluster is unreachable.
`CONTROLPLANE_SCHEMA=40` marks the TSV column-schema version (O9 appended cols
35-40); the report skips files whose width differs (with a counted stderr warning),
so a 34-column pre-O9 file is never aggregated alongside 40-column O9 files. (The
aggregated *report* output is a separate 34-column shape — see `004`'s aggregate
header — and is unrelated to the 40-column input width.)

Note: `istiod_cpu_pct_of_limit` / `node_cpu_pct` are **point samples** taken once
per context at row-assembly time (outside the measurement window), unlike the
windowed `istiod_cpu_m_delta` (col 32) — don't compare the two as if both are
window averages. The istiod %-of-limit denominator is the *aggregate* limit
(per-replica limit × replica count), matching the across-replica usage numerator.

Followed by the 40-column data schema:

```
timestamp  context  mesh_size  service_count  replicas  namespace_count  sidecar_scoping
istiod_mem_mi
convergence_p50_ms  convergence_p99_ms  queue_p50_ms  queue_p99_ms
xds_pushes_delta  xds_pushes_rate
xds_pushes_cds  xds_pushes_eds  xds_pushes_lds  xds_pushes_rds  xds_pushes_nds
k8s_events_delta  k8s_events_rate
connected_proxies  config_size_avg_bytes
sidecar_config_bytes_avg  sidecar_config_bytes_p50  sidecar_config_bytes_max  sidecar_config_bytes_samples (got/attempted)
scrape_window_sec  scrape_skew_ms
settle_sec  istiod_restarted
istiod_cpu_m_delta
go_heap_alloc_mi  go_heap_inuse_mi
istiod_cpu_pct_of_limit  istiod_mem_pct_of_limit   (O9 cols 35-36)
node_cpu_pct  node_mem_pct                         (O9 cols 37-38)
pods_scheduled  pods_allocatable                   (O9 cols 39-40)
```

The six O9 columns (35-40) are per-row read-only capacity legibility: istiod
CPU/mem as a percent of its live `resources.limits` (CR-patched, read from the
live Deployment), worker-node CPU/mem utilization percent (`kubectl top nodes`,
worker nodes only), and worker pod-slot occupancy. Any column is `N/A` when the
underlying read is unavailable (e.g. metrics-server absent). They are surfaced
in the report's "Achieved scale vs capacity" block (text + markdown), not the
csv/json aggregate rows.

`go_heap_alloc_mi` (`go_memstats_alloc_bytes`) and `go_heap_inuse_mi`
(`go_memstats_heap_inuse_bytes`) are point-in-time values from the final scrape,
not peaks. They reveal steady-state memory independently of RSS, which stays
inflated after GC due to `MADV_FREE`.

**EDS is included in config_dump by design.** Envoy's default `/config_dump`
omits the `EndpointsConfigDump`, but EDS is the dominant per-proxy size driver —
exactly the cost that `Sidecar` scoping is designed to reduce. We request
`/config_dump?include_eds` via `pilot-agent request` (works with distroless
sidecar images) so the headline reduction (none -> namespace / explicit) is
visible. The byte count is piped through `wc -c` on the local side.

`004-report-results.sh` groups rows by `(mesh_size, service_count, replicas,
namespace_count, sidecar_scoping)` and emits `text`, `csv`, `json`, or
`markdown` summaries via `--format`. The markdown format includes a "Sidecar
scoping effect" table showing config size reduction percentages across modes.
The report also prints an **"Achieved scale vs capacity" (O9)** block at the top
of the text + markdown formats: max connected proxies, istiod/node utilization
percentages, and a `SCALE_COVERAGE:` line. The same provenance is carried in the
other two formats so all four are at parity: `csv` emits it as `# capacity:` /
`# achieved:` / `# SCALE_COVERAGE:` comment lines (the aggregate row schema is
unchanged), and `json` nests `capacity`, `achieved_scale`, and `coverage` objects
under `metadata` (the `results` array is unchanged). On a multi-context sweep the
`SCALE_COVERAGE:` line is tagged `(fleet: …)` because `pods_scheduled`/`allocatable`
are maxed independently across contexts, so the fraction is a fleet-level proxy
rather than a single-cluster paired ratio. `services_total` is labelled
`[configured]` — controlplane has no distinct achieved-services metric, so it
surfaces the configured axis value, not a measured count. Legacy TSV files with a
non-40-column schema are skipped with a stderr warning.

### Scale coverage (O9)

By default the harness only *reports* achieved scale vs capacity (the six
columns above + the achieved-scale block); no sizing or gating behaviour
changes. Two DEFAULT-OFF knobs (in `config/options.env`) enable Phase 2:

- `SCALE_SIZING_MODE=auto` — `001` derives `SERVICE_COUNT` from capacity
  (`cap_max_pods / replicas`) on the source context instead of the fixed CLI/env
  value. With the default `fixed`, sizing is unchanged.
- `SCALE_COVERAGE_ENFORCE=1` — turns the under-provision coverage check (achieved
  pods / allocatable `< SCALE_COVERAGE_MIN_FRACTION`) from a warning into a hard
  failure, in both `001`'s preflight and `004`'s report. Default `0` = warn only.

`SCALE_TARGET_FRACTION` (default `0.7`) is the explicit O9↔O8 throttle:
larger = more pods = slower. `SCALE_SYSTEM_RESERVE_FRACTION` (default `0.15`)
holds back node allocatable for system/daemonset/gateway overhead before sizing.

## Cleanup

```bash
./tests/controlplane/005-cleanup.sh --contexts cluster-001,cluster-002,cluster-003
```

Cleanup deletes every namespace labelled `app.kubernetes.io/instance=controlplane-test`
on each context — covering both single- and multi-namespace runs — plus the
legacy unlabeled `controlplane-test` namespace if present. Post-deletion, it
confirms no `Sidecar` CRs leaked.

## Scripts

| Script | Purpose |
|--------|---------|
| `001-setup-controlplane-test.sh` | Deploy dummy workloads + optional Sidecar CRs on target clusters |
| `002-collect-resource-metrics.sh` | Delta-window scrape istiod metrics + optional per-pod /config_dump sampling |
| `003-run-sweep.sh` | Orchestrate the 5-axis cross-product (mesh x svc x reps x ns x scoping) |
| `004-report-results.sh` | Aggregate TSV rows by the five sweep axes (text/csv/json/markdown) |
| `005-cleanup.sh` | Remove all controlplane-test resources |

## Known Limitations

- **`/config_dump` exec cost is O(N samples x clusters x combos)**: at default
  `--config-dump-samples 3` and a 3x3 sweep with 3 clusters, that's 81
  per-pod exec round-trips per full sweep. Set `--config-dump-samples 0` to
  disable sampling entirely.
- **Service distribution across namespaces is uniform**; real meshes are
  long-tail (Zipf). Treat namespace-count results as a *lower bound* on
  per-namespace push cost.
- **No `--samples N` repeated scrapes per cell** — every sweep point is a
  single (baseline + final) window. Re-run the sweep to get N samples per cell.
- **Settle time is single-valued** across the entire sweep.
- **Watch mode reports raw cumulative metrics**, not deltas. Use one-shot mode
  for percentile / counter measurements over a defined window.
- **`namespace-count` must be <= `service-count`**: the setup script rejects
  configurations where namespaces would be empty (no services mapped to them).
- **`namespaceCount > 1` with sidecar scoping**: Sidecar CRs are only emitted
  into the primary namespace. Pods in additional namespaces have no Sidecar CR
  and receive the full unscoped config. Config-dump sampling selects pods
  across all test namespaces via the `app.kubernetes.io/instance` label.

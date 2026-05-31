# Endpoint Churn × Data-plane Co-execution Test Suite

Measure **how p99 request latency degrades when istiod is busy with endpoint
churn**.

`tests/churn/` measures convergence under endpoint churn but with no
data-plane load. `tests/dataplane/` measures latency percentiles against a
steady mesh. Either in isolation will miss a regression that, say, doubles
p99 only while endpoint churn is active. This suite closes that gap: it
co-deploys fortio (client + server) and churn-target workloads in a **single
shared namespace**, runs two paired measurement windows — baseline (no
churn) and endpoint-churn (load + Deployment scale events) — and reports
the delta.

## What we measure / what we don't

The churn driver scales `churn-target-N` Deployments between
`--base-replicas` and `--scale-to` replicas at a configurable ops-per-second
rate. Each scale event produces an Endpoint add/remove, which istiod
translates into an **EDS push** to the affected sidecars. So what this suite
exercises is **endpoint flux only**.

What this suite does **not** cover:

- **Rolling updates / Pod restarts.** Real workload updates trigger CDS+EDS
  (and often LDS) pushes plus sidecar bootstrap; scaling a Deployment between
  two replica counts does not.
- **Config drift** — VirtualService/DestinationRule/Sidecar changes, which
  ride a different code path through istiod.
- **Sidecar restarts** — proxy lifecycle perturbations affecting connection
  pools and pending requests.
- **istiod HA / leader election** — the suite assumes a single istiod
  replica per cluster (see precondition below).
- **Sidecar-side (Envoy admin) metrics** — the suite captures istiod-side
  xDS push metrics for attribution but does not capture Envoy admin stats
  from the fortio sidecars. This means we can see that istiod was busy
  pushing xDS configs but cannot directly observe how long the sidecars
  spent processing those updates.

The istiod-side metrics (`pilot_xds_pushes`, `pilot_proxy_convergence_time`,
`pilot_proxy_queue_time`, `pilot_xds_push_time`) enable **attribution**: if
`Δp99_ms` is high and `churn_eds_pushes` / `churn_conv_p99` are
correspondingly elevated, the latency delta is attributable to control-plane
contention rather than node-level effects alone.

If you need any of those, layer additional probes on top — this suite is
deliberately narrow so the `Δp99_ms` number is unambiguous.

## What gets measured

| Metric | How |
|--------|-----|
| Baseline p50 / p99 / p999 / max latency | fortio at fixed QPS against `fortio-server` in shared namespace, no churn |
| Baseline actual QPS | `fortio.ActualQPS` |
| Under-churn p50 / p99 / p999 / max latency | Same fortio invocation, while a deterministic churn driver scales `churn-target-N` Deployments at `--churn-rates` ops/s |
| Under-churn actual QPS | `fortio.ActualQPS` |
| `Δp99_ms` | `churn_p99_ms − baseline_p99_ms` per combo |
| `stdev(Δp99_ms)` | Standard deviation of `Δp99_ms` across repetitions (when `n_valid >= 2`) |
| `istiod_restarted` | `0` / `1` / `unknown` based on `process_start_time_seconds` delta during the window (PL9) |
| istiod xDS push count | `pilot_xds_pushes` counter delta during measurement window (total + EDS-only) |
| istiod push triggers | `pilot_push_triggers` counter delta during measurement window |
| istiod convergence p99 | `pilot_proxy_convergence_time` histogram delta-window p99 |
| istiod queue time p99 | `pilot_proxy_queue_time` histogram delta-window p99 |
| istiod push time p99 | `pilot_xds_push_time` histogram delta-window p99 |

## Co-namespace label scheme (Branch-4 N1)

Both fortio and churn-target Pods live in `churn-dataplane-test` namespace
with sidecar injection on. To prevent fortio's traffic from accidentally
landing on churn-target Pods (which would invert the measurement), distinct
top-level labels are used:

- `app=fortio-server` — fortio echo server; `fortio-server` Service selects only this label
- `app=fortio-client` — fortio load generator
- `app=churn-target`, `churn-index=N` — churn workloads; each `churn-target-N` Service selects on the index

`fortio.load` always targets `http://fortio-server.churn-dataplane-test.svc:8080/echo`.

### Explicit no-traffic contract

Fortio and churn-target workloads share the namespace (and therefore istiod
/ CNI / kubelet contention) but **never exchange traffic** — fortio's
Service selector is `app=fortio-server` only, and churn-targets use
`app=churn-target` + `churn-index=N`. The label namespaces are disjoint, so
the two Service selectors cannot accidentally pick up each other's Pods
under any concurrent scale event. This guarantees that the only thing
churn is doing to fortio's measurement is contending for control-plane and
node-level resources — not stealing or injecting traffic.

## Churn-rate semantics (Branch-4 N2)

`--churn-rates CSV` is interpreted as **deployment scale operations per
second**. At rate `R` for `D` seconds, exactly `R * D` `kubectl scale`
operations are issued, one every `1/R` seconds. The chosen index sequence is
a deterministic seeded shuffle of `0..--deployment-count` (PL16: bash/awk
LCG, no `shuf`). Each operation alternates the chosen Deployment between
`--base-replicas` and `--scale-to` replicas — so churn does not monotonically
inflate or deflate the mesh.

The driver uses **drift-compensated scheduling** (A5): each iteration sleeps
until `start_ns + (op+1) * period_ns` rather than a fixed `1/R` slice, so
the time `kubectl scale` itself takes does not bleed the effective rate
below target at high rates. Each op also captures the exit status of every
parallel `kubectl scale`; rows where `succeeded / attempted < 90%` are
flagged `status=CHURN_RATE_NOT_MET` and filtered from the aggregated
report (A4).

## Known limitations

- **Practical churn-rate ceiling ~100 ops/s.** Each churn operation forks
  `date +%s%N` and awk for drift-compensated scheduling, plus one or more
  `kubectl scale` subprocesses. At rates above ~100 ops/s, the per-op
  overhead (~5-10ms) consumes the inter-op interval, and the driver falls
  behind. Rows where `churn_ops_succeeded / churn_ops_attempted < 90%` are
  automatically flagged `CHURN_RATE_NOT_MET` and filtered from the report,
  so this manifests as low `n_valid` rather than wrong numbers.
- **Single istiod replica per cluster, required.** 002/003 detect istiod
  restarts via `kubectl port-forward svc/istiod` and reading
  `process_start_time_seconds`. `port-forward` against the Service
  load-balances across replicas, so an HA istiod deployment can land the
  pre-window and post-window scrapes on different pods — yielding a
  spurious `istiod_restarted=1` and poisoning every row. 001 enforces this
  precondition at setup time and dies with a clear message if any active
  context has more than one Running istiod pod (A2).
- **Endpoint flux only.** See "What we measure / what we don't" above.
- **Reproducibility is per-configuration, not per-byte.** `RUN_ID` is
  **per-invocation**: it is composed of `date +%Y%m%dT%H%M%S` plus the
  invoking shell's PID (`$$`), so every invocation gets a fresh id. Re-running
  the same config produces a brand-new `sweep-${RUN_ID}/` subdirectory and
  never overwrites a prior run's results — that is the PL5/PL6 guarantee.
  But rows from two reruns of an identical config are **not bit-identical**:
  wall-clock latencies vary with kernel scheduling and apiserver load, and
  although the churn driver's chosen index sequence is deterministic given
  `--seed` (PL16), the actual `kubectl scale` ACK timings are not. Treat
  reproducibility as "same combo → comparable distribution", not "same
  bytes on disk".

## Quick start

```bash
# 1. Setup composite chart on three clusters (shared namespace on each)
./tests/churn-dataplane/001-setup-coexec-test.sh \
    --source-context cluster-001 \
    --remote-contexts cluster-002,cluster-003 \
    --deployment-count 10

# 2. Baseline (no churn) — 60s at 200 QPS
#    Use --output-file to set an explicit path reused by step 3.
TSV=tests/churn-dataplane/results/churn-dataplane-smoke.tsv
./tests/churn-dataplane/002-run-baseline-probe.sh \
    --source-context cluster-001 \
    --remote-contexts cluster-002,cluster-003 \
    --duration 60 --qps 200 \
    --combo-id smoke-run \
    --output-file "$TSV"

# 3. Churn (200 QPS + 10 scale ops/s) — writes a row into the same TSV
#    and computes Δp99 vs the matching baseline row.
./tests/churn-dataplane/003-run-churn-probe.sh \
    --source-context cluster-001 \
    --remote-contexts cluster-002,cluster-003 \
    --duration 60 --qps 200 --churn-rate 10 \
    --combo-id smoke-run \
    --baseline-file "$TSV" \
    --output-file   "$TSV"

# 4. Aggregate
./tests/churn-dataplane/005-report-results.sh \
    --results-dir tests/churn-dataplane/results
```

## Full sweep

```bash
# 2 mesh sizes × 3 churn rates × 2 repetitions = 12 combinations
./tests/churn-dataplane/004-run-sweep.sh \
    --contexts     cluster-001,cluster-002,cluster-003 \
    --mesh-sizes   1,2 \
    --churn-rates  1,5,10 \
    --repetitions  2

# Dry-run to inspect the plan:
./tests/churn-dataplane/004-run-sweep.sh --dry-run \
    --contexts     a,b \
    --mesh-sizes   1,2 \
    --churn-rates  1,5,10
```

The sweep:

1. Creates a per-sweep subdir `tests/churn-dataplane/results/sweep-${RUN_ID}/`. (PL6)
2. Writes one TSV containing baseline+churn rows for every combo. (PL2 preamble, PL19 propagation)
3. Enforces a matrix cap of **64 combinations**; bypass with `--force-large-matrix`. (PL10)
4. Sleeps `--inter-combo-settle` (default 15s) between combos, **after** cleanup completes. (PL18)
5. Awaits namespace deletion synchronously between combos. (PL4 via `006-cleanup.sh --wait-deletion`)
6. Calls `005-report-results.sh` at the end.

## TSV schema (one row per phase)

| # | Column | Notes |
|---|--------|-------|
| 1 | `run_id` | Sweep / probe identifier (timestamp + PID) |
| 2 | `harness_sha` | `git describe --always --dirty --abbrev=7` (PL2) |
| 3 | `combo_id` | Stable per-combo id linking baseline & churn rows; format `ms{N}-cr{R}` from 004 |
| 4 | `mesh_size` | Integer |
| 5 | `churn_rate` | Integer, scale-ops/s; always `0` on baseline rows |
| 6 | `phase` | `baseline`, `churn`, or `cleanup` (cleanup rows are PL23 markers) |
| 7 | `duration_s` | Fortio measurement window length |
| 8 | `qps_target` | Fortio `-qps` value |
| 9 | `qps_actual` | `fortio.ActualQPS` |
| 10 | `p50_ms` | `DurationHistogram.Percentiles[50] * 1000` |
| 11 | `p90_ms` | Same, `Percentile == 90` |
| 12 | `p99_ms` | Same, `Percentile == 99` |
| 13 | `p999_ms` | Same, `Percentile == 99.9` |
| 14 | `max_ms` | `DurationHistogram.Max * 1000` |
| 15 | `delta_p99_ms` | `churn_p99 − baseline_p99` for the same `combo_id`. `N/A` on baseline rows. Only computed when the baseline row has `status=OK` (A3). |
| 16 | `istiod_restarted` | `0` if `process_start_time_seconds` unchanged across window; `1` if changed; `unknown` if either probe failed (PL9) |
| 17 | `status` | `OK`, `FAILED`, `POISONED_RESTART`, `CLEANUP_TIMEOUT`, `CHURN_RATE_NOT_MET` |
| 18 | `churn_ops_attempted` | Total scale-op iterations the driver attempted in the window (one log line per op). `N/A` on baseline / cleanup rows. (A4) |
| 19 | `churn_ops_succeeded` | Subset of attempted ops where every parallel `kubectl scale` exited 0. `N/A` on baseline / cleanup rows. (A4) |
| 20 | `xds_pushes_delta` | `pilot_xds_pushes` counter delta during measurement window. `N/A` when istiod restarted or scrape failed. |
| 21 | `eds_pushes_delta` | `pilot_xds_pushes{type="eds"}` counter delta — the EDS subset of total pushes. |
| 22 | `push_triggers_delta` | `pilot_push_triggers` counter delta during measurement window. |
| 23 | `convergence_p99_ms` | `pilot_proxy_convergence_time` histogram delta-window p99 (bucket upper bound in ms). |
| 24 | `queue_time_p99_ms` | `pilot_proxy_queue_time` histogram delta-window p99. |
| 25 | `push_time_p99_ms` | `pilot_xds_push_time` histogram delta-window p99. |

`status=CHURN_RATE_NOT_MET` is set by 003 when
`churn_ops_succeeded / churn_ops_attempted < 90%` (typically apiserver 429s
at high rates). 005 filters these rows from numeric aggregation, the same
way it filters `POISONED_RESTART`.

Preamble comment lines (PL2 / PL19) above the header carry: `RUN_ID`,
`HARNESS_SHA`, `ISTIO_VERSION`, `KUBE_VERSIONS`, `SETTLE_SEC`,
`BASELINE_DURATION_SEC`, `CHURN_DURATION_SEC`, `QPS`, `CONNECTIONS`,
`NAMESPACE`, plus a `# combo=... phase=... window_start_ns=... window_end_ns=...`
marker just before every data row (PL3 wall-clock window). Churn rows
additionally carry `churn_ops_attempted=... churn_ops_succeeded=...` in
that marker (A4).

`005-report-results.sh` filters rows whose `istiod_restarted` is `1` or
`unknown`, or whose `status` is not `OK` (including
`CHURN_RATE_NOT_MET`), and reports `total_runs` vs `valid_runs` per
combination (PL15). All four output formats (`text`, `csv`, `json`, `md`)
propagate the preamble metadata (PL19). The report's headline column order
is (A7):

```
mesh_size | churn_rate | delta_p99_ms | stdev_delta_p99 | total_runs | valid_runs |
baseline_p99_ms | churn_p99_ms | baseline_p50_ms | churn_p50_ms | baseline_qps | churn_qps |
churn_eds_pushes | churn_convergence_p99
```

### Manual baseline/churn pairing via combo_id

To pair baseline and churn rows manually (outside `004-run-sweep.sh`),
invoke `002` and `003` with the same `--combo-id`. `005` joins on this
column (PL20). When `--combo-id` is omitted, the per-probe `RUN_ID` is used
as the combo id, which only pairs probes within a single invocation.

## Cleanup

```bash
./tests/churn-dataplane/006-cleanup.sh \
    --contexts cluster-001,cluster-002,cluster-003 \
    --wait-deletion --timeout 180
```

Use `--wait-deletion` between manual probe runs to avoid the next setup
hitting an in-flight namespace teardown (PL4).

## Scripts

| Script | Purpose |
|--------|---------|
| `001-setup-coexec-test.sh` | Render+apply the composite chart on every active context (server-side apply, PL5). `--dry-run` does not touch clusters. |
| `002-run-baseline-probe.sh` | Run one fortio measurement window with NO churn; emit `phase=baseline` TSV row with istiod metrics. |
| `003-run-churn-probe.sh` | Run one fortio measurement window while the churn driver runs concurrently; emit `phase=churn` TSV row with istiod metrics plus `delta_p99_ms`. |
| `004-run-sweep.sh` | Orchestrate `001 → 002 → 003 → 006 → settle` across mesh_size × churn_rate × repetitions combos; PL6 per-sweep dir, PL10 matrix cap. |
| `005-report-results.sh` | Aggregate joined baseline+churn pairs by combo_id, filter poisoned rows, emit text/csv/json/md. |
| `006-cleanup.sh` | Tear down the shared namespace; `--wait-deletion` for PL4 synchronous semantics. |

## Environment variables (defaults in `config/options.env`)

| Variable | Default | Used by |
|----------|---------|---------|
| `COEXEC_TEST_NAMESPACE` | `churn-dataplane-test` | All scripts; shared namespace name. |
| `COEXEC_BASELINE_DURATION_SEC` | `60` | `002-run-baseline-probe.sh`, `004-run-sweep.sh`. |
| `COEXEC_CHURN_DURATION_SEC` | `60` | `003-run-churn-probe.sh`, `004-run-sweep.sh`. |
| `COEXEC_CHURN_RATES` | `1,5,10` | `004-run-sweep.sh`. |
| `COEXEC_SETTLE_SEC` | `10` | Pre-window settle in 002/003. |
| `COEXEC_INTER_COMBO_SETTLE_SEC` | `15` | Sweep-level inter-combo gap (PL18). |
| `COEXEC_QPS` | `200` | Target QPS for both phases. |
| `COEXEC_NUM_CONNECTIONS` | `8` | Fortio `-c`. |
| `COEXEC_CHURN_SEED` | `42` | PL16 deterministic-shuffle seed. |
| `COEXEC_REPETITIONS` | `1` | Probe repetitions per combination in `004-run-sweep.sh`. |
| `COEXEC_ISTIOD_PF_PORT` | `15014` | Local port for istiod scrapes. |
| `COEXEC_NS_DELETE_TIMEOUT_SEC` | `180` | PL4 wait bound. |
| `COEXEC_SERVICE_PORT` | `8080` | Fortio target port. |

Shared from `config/versions.env`: `SETUP_CONTEXTS`, `ISTIO_VERSION`.

## Process-learnings status

| PL | Status |
|----|--------|
| PL1 (delta-window scraping) | N/A — fortio JSON already returns per-window aggregates; istiod is scraped only for restart detection. |
| PL2 (preamble + concurrent kube-version probes) | APPLIED (`lib/preamble.sh` `write_preamble`, `probe_kube_versions`). |
| PL3 (wall-clock window distinct from settle) | APPLIED — `WINDOW_START_NS` / `WINDOW_END_NS` markers, `--settle-sec` separate. |
| PL4 (await async cluster ops) | APPLIED — `006-cleanup.sh --wait-deletion`; sweep always uses it. |
| PL5 (server-side apply) | APPLIED in `001-setup-coexec-test.sh`. |
| PL6 (per-sweep output subdir) | APPLIED — `sweep-${RUN_ID}/`. |
| PL7 (plural CSV with singular alias warning) | APPLIED — `--churn-rates` plural, `--churn-rate` deprecated. |
| PL8 (concurrent multi-context scrapes) | APPLIED in `probe_kube_versions`. |
| PL9 (istiod restart 0/1/unknown) | APPLIED via `process_start_time_seconds` delta. |
| PL10 (matrix safety cap 64) | APPLIED — `--force-large-matrix` bypass. |
| PL11 (histograms as histograms) | APPLIED — istiod-side histograms (`pilot_proxy_convergence_time`, `pilot_proxy_queue_time`, `pilot_xds_push_time`) are scraped as raw buckets and quantiles computed via delta-window interpolation in `lib/metrics.sh`. |
| PL12 (gauge sum across permutations) | N/A — no gauge aggregation in this suite (fortio is the source of truth for latency). |
| PL13 (poisoned rows when restarted != 0) | APPLIED — quantiles emit `N/A`, status `POISONED_RESTART`. |
| PL14 (negative histogram bucket delta -> N/A) | APPLIED — `delta_histogram_p99` in `lib/metrics.sh` emits `N/A` when any per-bucket delta is negative. |
| PL15 (005 filters poisoned; reports n_total/n_valid) | APPLIED. |
| PL16 (deterministic seeded shuffle, no `shuf`) | APPLIED — awk-LCG in `003-run-churn-probe.sh`. |
| PL17 (sample count as got/attempted) | APPLIED implicitly — `n_total` vs `n_valid` in 005. |
| PL18 (settle gap after cleanup) | APPLIED — `--inter-combo-settle`. |
| PL19 (005 propagates ALL preamble metadata to ALL formats) | APPLIED — text, csv, json, md. |
| PL20 (Δ accounts for multi-push semantics) | N/A — this suite does not use EDS push-count thresholds for convergence detection; it measures fortio latency directly. Δp99 is computed only across baseline/churn rows that share `combo_id` and are both valid (PL15 join). |
| PL21 (gauges from SAME baseline scrape) | APPLIED — single scrape per `istiod_start_time_seconds` call, single awk pass. |
| PL22 (single-file scrape, single awk pass) | APPLIED — `scrape_istiod_metrics` in `lib/metrics.sh` writes once to temp file; `extract_gauge`, `extract_counter_sum`, `extract_counter_by_label`, and `delta_histogram_p99` each awk-pass the same file. |
| PL23 (drain/cleanup timeout -> row status) | APPLIED — sweep emits a `phase=cleanup status=CLEANUP_TIMEOUT` row when 006 fails. |

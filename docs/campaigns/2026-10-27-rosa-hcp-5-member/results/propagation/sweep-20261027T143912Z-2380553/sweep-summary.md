---
SWEEP_RUN_ID: "20261027T143912Z-2380553"
HARNESS_SHA: "d21a197"
ISTIO_VERSION: "v1.30.5"
ISTIO_VERSION_PIN: "v1.30.5"
ISTIO_VERSION_SOURCE: "live"
ISTIO_VERSION_BY_CONTEXT: "<mesh-a-ctx>=v1.30.5,<mesh-b-ctx>=v1.30.5,<mesh-c-ctx>=v1.30.5,<mesh-d-ctx>=v1.30.5,<mesh-e-ctx>=v1.30.5"
ISTIO_ACTIVE_REVISIONS: "<mesh-a-ctx>=default,<mesh-b-ctx>=default,<mesh-c-ctx>=default,<mesh-d-ctx>=default,<mesh-e-ctx>=default"
ISTIO_GENERATIONS: "<mesh-a-ctx>=1/1,<mesh-b-ctx>=1/1,<mesh-c-ctx>=1/1,<mesh-d-ctx>=1/1,<mesh-e-ctx>=1/1"
SOURCE_CTX: "<mesh-a-ctx>"
ITERATIONS: "10"
POLL_INTERVAL_S: "0.250"
TIMEOUT_SEC: "120"
SETTLE_SEC: "5"
FANOUT_MAX_SKEW_MS: "1000"
FANOUT_METRICS_TIMEOUT: "30"
BACKER_IMAGE: "hashicorp/http-echo:1.0"
TUNING_BASELINE: "sidecar=on,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on"
SIDECAR_EGRESS_HOSTS: "./* istio-system/* mesh-verify/* churn-test/* churn-dataplane-test/* controlplane-test/* dataplane-test/* propagation-test/*"
RUN_CONFIG: "tests/campaign/profiles/rosa/propagation.env"
RUN_CONFIG_SHA256: "9dd833c17bd66ac30a2c1fb991ccf7c0de3a6974d2f42885ead2a309e4835d2c"
PLATFORM: "openshift"
TEST_PLATFORM: "auto"
PLATFORM_BY_CONTEXT: "<mesh-a-ctx>=openshift,<mesh-b-ctx>=openshift,<mesh-c-ctx>=openshift,<mesh-d-ctx>=openshift,<mesh-e-ctx>=openshift"
MESH_OPERATOR_BY_CONTEXT: "<mesh-a-ctx>=servicemeshoperator3:3.4.3,<mesh-b-ctx>=servicemeshoperator3:3.4.3,<mesh-c-ctx>=servicemeshoperator3:3.4.3,<mesh-d-ctx>=servicemeshoperator3:3.4.3,<mesh-e-ctx>=servicemeshoperator3:3.4.3"
ISTIOD_IMAGE_BY_CONTEXT: "<mesh-a-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-b-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-c-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-d-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7,<mesh-e-ctx>=istio-pilot-rhel9@sha256:0153604b88f0cee3514551cad3e796a7b0245d2881978848c4a115d3d30ad3b7"
PROXY_IMAGE_BY_CONTEXT: "<mesh-a-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-b-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-c-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-d-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109,<mesh-e-ctx>=istio-proxyv2-rhel9@sha256:b722c0999b9442a444bcc8e4dc718b09a067646f5ffe075edf003b3f1e65c109"
NODE_PROVIDER_BY_CONTEXT: "<mesh-a-ctx>=aws,<mesh-b-ctx>=aws,<mesh-c-ctx>=aws,<mesh-d-ctx>=aws,<mesh-e-ctx>=aws"
ISTIOD_ENV_BY_CONTEXT: "<mesh-a-ctx>=0c3d8d887772,<mesh-b-ctx>=0c3d8d887772,<mesh-c-ctx>=0c3d8d887772,<mesh-d-ctx>=0c3d8d887772,<mesh-e-ctx>=0c3d8d887772"
iterations:
  -
    RUN_ID: "20261027T143920Z-2382827"
    DATE: "2026-10-27T14:39:21+00:00"
    MESH_SIZE: "1"
    REMOTES: "none"
    KUBE_VERSIONS: "<mesh-a-ctx>=v1.34.6"
  -
    RUN_ID: "20261027T144050Z-2386779"
    DATE: "2026-10-27T14:40:51+00:00"
    MESH_SIZE: "2"
    REMOTES: "<mesh-b-ctx>"
    KUBE_VERSIONS: "<mesh-a-ctx>=v1.34.6,<mesh-b-ctx>=v1.34.6"
  -
    RUN_ID: "20261027T144229Z-2393975"
    DATE: "2026-10-27T14:42:30+00:00"
    MESH_SIZE: "3"
    REMOTES: "<mesh-b-ctx> <mesh-c-ctx>"
    KUBE_VERSIONS: "<mesh-a-ctx>=v1.34.6,<mesh-b-ctx>=v1.34.6,<mesh-c-ctx>=v1.34.6"
  -
    RUN_ID: "20261027T144415Z-2401746"
    DATE: "2026-10-27T14:44:16+00:00"
    MESH_SIZE: "4"
    REMOTES: "<mesh-b-ctx> <mesh-c-ctx> <mesh-d-ctx>"
    KUBE_VERSIONS: "<mesh-a-ctx>=v1.34.6,<mesh-b-ctx>=v1.34.6,<mesh-c-ctx>=v1.34.6,<mesh-d-ctx>=v1.34.6"
  -
    RUN_ID: "20261027T144609Z-2410551"
    DATE: "2026-10-27T14:46:11+00:00"
    MESH_SIZE: "5"
    REMOTES: "<mesh-b-ctx> <mesh-c-ctx> <mesh-d-ctx> <mesh-e-ctx>"
    KUBE_VERSIONS: "<mesh-a-ctx>=v1.34.6,<mesh-b-ctx>=v1.34.6,<mesh-c-ctx>=v1.34.6,<mesh-d-ctx>=v1.34.6,<mesh-e-ctx>=v1.34.6"
tsv_columns: [23]
generated: 2026-10-27T14:48:49+00:00
---

# Endpoint Propagation Latency

> **Sweep outcome** (`sweep-20261027T143912Z-2380553`): all 5 cells ran

**Source files:** 5 TSV file(s)

- `endpoint-20261027T143920Z-2382827.tsv`
- `endpoint-20261027T144050Z-2386779.tsv`
- `endpoint-20261027T144229Z-2393975.tsv`
- `endpoint-20261027T144415Z-2401746.tsv`
- `endpoint-20261027T144609Z-2410551.tsv`

## Mesh size: 1

| Phase | n_total | n_valid | n_attempted | min (ms) | max (ms) | avg (ms) | p50 (ms) | p95 (ms) | p99 (ms) |
|-------|---------|---------|-------------|----------|----------|----------|----------|----------|----------|
| P1 local xDS (wall) | 10 | 10 | 10 | 610 | 683 | 635 | 626 | N/A | N/A |
| P1 conv_p50 (hist) | 10 | 0 | 10 | - | - | - | - | - | - |
| P1 conv_p99 (hist) | 10 | 0 | 10 | - | - | - | - | - | - |
| P2 remote istiod EDS | 10 | 0 | 10 | - | - | - | - | - | - |
| P3 remote sidecar | 10 | 0 | 10 | - | - | - | - | - | - |

## Mesh size: 2

| Phase | n_total | n_valid | n_attempted | min (ms) | max (ms) | avg (ms) | p50 (ms) | p95 (ms) | p99 (ms) |
|-------|---------|---------|-------------|----------|----------|----------|----------|----------|----------|
| P1 local xDS (wall) | 10 | 10 | 10 | 606 | 795 | 668 | 664 | N/A | N/A |
| P1 conv_p50 (hist) | 10 | 0 | 10 | - | - | - | - | - | - |
| P1 conv_p99 (hist) | 10 | 0 | 10 | - | - | - | - | - | - |
| P2 remote istiod EDS | 10 | 10 | 10 | 602 | 870 | 673 | 659 | N/A | N/A |
| P3 remote sidecar | 10 | 10 | 10 | 601 | 768 | 644 | 629 | N/A | N/A |

## Mesh size: 3

| Phase | n_total | n_valid | n_attempted | min (ms) | max (ms) | avg (ms) | p50 (ms) | p95 (ms) | p99 (ms) |
|-------|---------|---------|-------------|----------|----------|----------|----------|----------|----------|
| P1 local xDS (wall) | 10 | 10 | 10 | 629 | 691 | 661 | 660 | N/A | N/A |
| P1 conv_p50 (hist) | 10 | 0 | 10 | - | - | - | - | - | - |
| P1 conv_p99 (hist) | 10 | 0 | 10 | - | - | - | - | - | - |
| P2 remote istiod EDS | 20 | 20 | 20 | 577 | 672 | 617 | 612 | 668 | 672 |
| P3 remote sidecar | 20 | 20 | 20 | 561 | 667 | 604 | 595 | 647 | 667 |

## Mesh size: 4

| Phase | n_total | n_valid | n_attempted | min (ms) | max (ms) | avg (ms) | p50 (ms) | p95 (ms) | p99 (ms) |
|-------|---------|---------|-------------|----------|----------|----------|----------|----------|----------|
| P1 local xDS (wall) | 10 | 10 | 10 | 617 | 883 | 678 | 640 | N/A | N/A |
| P1 conv_p50 (hist) | 10 | 0 | 10 | - | - | - | - | - | - |
| P1 conv_p99 (hist) | 10 | 0 | 10 | - | - | - | - | - | - |
| P2 remote istiod EDS | 30 | 30 | 30 | 586 | 981 | 674 | 656 | 773 | 981 |
| P3 remote sidecar | 30 | 30 | 30 | 580 | 956 | 682 | 670 | 902 | 956 |

## Mesh size: 5

| Phase | n_total | n_valid | n_attempted | min (ms) | max (ms) | avg (ms) | p50 (ms) | p95 (ms) | p99 (ms) |
|-------|---------|---------|-------------|----------|----------|----------|----------|----------|----------|
| P1 local xDS (wall) | 10 | 10 | 10 | 601 | 662 | 636 | 640 | N/A | N/A |
| P1 conv_p50 (hist) | 10 | 0 | 10 | - | - | - | - | - | - |
| P1 conv_p99 (hist) | 10 | 0 | 10 | - | - | - | - | - | - |
| P2 remote istiod EDS | 40 | 40 | 40 | 579 | 666 | 620 | 620 | 655 | 666 |
| P3 remote sidecar | 40 | 40 | 40 | 579 | 696 | 625 | 624 | 667 | 696 |

## Comparison across mesh sizes

Averages over rows surviving the report filter (P1: its source side, p1_status != OK, p1_overflow=1 or a high source skew drop it; P2/P3: the remote side, remote_status != OK or a high remote skew; P2 also drops p2_dirty=1 rows; DRAIN_TIMEOUT counts as OK). Cells show `avg (n_valid)`, except P1 conv_p99: the worst bucket any valid row hit `(n_valid)`, never averaged. Per-mesh-size tables above carry the full breakdown.

| Mesh Size | P1 wall avg (ms) | P1 conv_p99 worst (ms) | P2 EDS avg (ms) | P3 sidecar avg (ms) |
|-----------|------------------|------------------------|-----------------|---------------------|
| 1 | 635 (10) | -- (0) | -- (0) | -- (0) |
| 2 | 668 (10) | -- (0) | 673 (10) | 644 (10) |
| 3 | 661 (10) | -- (0) | 617 (20) | 604 (20) |
| 4 | 678 (10) | -- (0) | 674 (30) | 682 (30) |
| 5 | 636 (10) | -- (0) | 620 (40) | 625 (40) |

## istiod restart diagnostics

None captured: no `istiod-diag-*/index.tsv` under the results dir (no restart or `unknown` status triggered a capture, or `ISTIOD_DIAG_ENABLED=0`).


## Glossary

Definitions for every phase and statistic column in the tables above (see also
`tests/propagation/README.md`). Each phase measures one stage of a single config change
propagating across the mesh; all values are **milliseconds**. Remote phases (P2/P3) are
undefined at mesh size 1 (no remote cluster). P2 and P3 are measured on a remote, so a row
is dropped from them (not counted in `n_valid`) only for that remote's side:
`remote_status != OK` (its istiod restarted or unknown, a P2 or P3 timeout, a canary
endpoint not drained before t0 (`NOT_DRAINED`), its scrape incomplete) or
`remote_scrape_skew_ms` over `FANOUT_MAX_SKEW_MS`, never for the source's restart, P1
timeout or `p1_overflow`. A TSV without `remote_status` cannot split a row by side:
`status != OK`, `restarted ∈ {1, unknown}` or a high `scrape_skew_ms` drop it. P2
additionally drops `p2_dirty=1` rows (an EDS bump not confirmed by the remote sidecar going
healthy). The P1 phases are measured on the source, so only the source side drops an
iteration's P1: `p1_status != OK` (a P1 timeout, a source istiod restart or unknown restart
state, a source sidecar `NOT_DRAINED`, a source scrape that failed), `p1_overflow=1`, or
`p1_scrape_skew_ms` over `FANOUT_MAX_SKEW_MS`; a remote that timed out or restarted does
not. `DRAIN_TIMEOUT` in any status column (the drain after the iteration timed out) counts
as `OK`: the values were measured before that drain; a warning above gives the number of
such iterations per mesh size.

| Phase | Units | Source | Definition / caveats |
|-------|-------|--------|----------------------|
| `P1_local_wall` | ms (wall clock) | timing + source `pilot_proxy_convergence_time` | Time from the t0 active-label flip until the source istiod has pushed the change to all connected proxies (delta `_count` reaches proxy count). |
| `P1_conv_p50` | ms (bucket range) | source `pilot_proxy_convergence_time` histogram delta | p50 of the per-bucket convergence-time delta in the window; bucket range (boundaries 100/500/1000/3000/5000/10000/20000/30000 ms); `N/A` if restarted or below the p50 min-sample floor. An iteration whose window put any sample in `+Inf` (`p1_overflow=1`) is dropped from the P1 phases (never from P2/P3), so `overflow` never reaches this table: it shows as `n_valid < n_total`. |
| `P1_conv_p99` | ms (bucket range) | source `pilot_proxy_convergence_time` histogram delta | p99 of the convergence-time delta; same bucket-range and overflow handling; `N/A` if restarted or below the p99 min-sample floor (`PROPAGATION_PERCENTILE_MIN_N`). |
| `P2_discovery` | ms (wall clock) | remote `pilot_xds_pushes{type="eds"}` counter delta | Time until the remote istiod pushes EDS for the new endpoint (control-plane discovery); excluded when `p2_dirty=1`. |
| `P3_dataplane` | ms (wall clock) | remote watcher Envoy `/clusters` | Time until the remote sidecar reports the canary endpoint healthy (full data-plane apply); typically ~10× P1/P2. |

| Stat column | Definition |
|-------------|------------|
| `n_total` | All rows considered for the phase/mesh size, kept or dropped. For the P1 phases, iterations (distinct run_id and iteration, as the probe's summary counts them), so a clean run reads `n_total == n_valid` and an overflowed iteration shows as one less `n_valid`. |
| `n_valid` | Samples used for the statistics: rows surviving the drop filters above. For the P1 phases, iterations: P1 is measured on the source once per iteration and repeated on every remote's row, so it counts once per iteration whose source side is clean (from the iteration's first valid row in a TSV without `p1_status`). |
| `n_attempted` | What the probes were configured to run, from each TSV's `ITERATIONS` and `REMOTES`: iterations for the P1 phases, `ITERATIONS` x remotes rows (one row per iteration with no remote) for P2/P3. `n_total` below it means iterations or rows that never ran (a warning above says so); `-` when a TSV does not record it. A `SETUP_FAILED` / `PROBE_FAILED` cell counts its status row in `n_total` and what it was configured to run here. |
| `min_ms` / `max_ms` / `avg_ms` | Minimum / maximum / mean (rounded to ms) latency across the `n_valid` samples. A histogram row (`P1 conv_*`) has no average (`-`): the mean of bucket bounds can land in a bucket no row hit, so read `max` (the worst bucket). CSV and JSON keep the numbers and add `worst_bucket`, the range of `max_ms`, for those phases. |
| `p50_ms` / `p95_ms` / `p99_ms` | Nearest-rank percentiles across the `n_valid` samples; `p95`/`p99` are `N/A` below `PROPAGATION_PERCENTILE_MIN_N` samples (a single worst sample would otherwise masquerade as a tail quantile). |
| `tsv_columns` | The column counts of the input rows (front matter). More than one means inputs from different harness versions, filtered by different rules (fewer than 23: no `remote_status`; fewer than 21: no `p1_status`; 18: no `p2_dirty` or skew); a warning above says so. |

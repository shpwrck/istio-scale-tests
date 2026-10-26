# Churn / Convergence Test Suite

Measures how fast the mesh converges under endpoint churn. The probe scales the
churn-target deployments on one **source** cluster and times when the source sees
the new pods and when each **remote** cluster sees them. Remote clusters stay at
base replicas, so the remote numbers are cross-cluster propagation only.

## At a glance

**Question:** when Deployments scale up on one cluster, how long until the proxies on that
cluster, and on every other cluster, can reach the new pods?

**What it deploys**, in namespace `churn-test` on every member it uses: 5 small Deployments (the
churn targets, 1 replica each) and one watcher pod whose proxy the probe reads. The sweep removes
them when it ends.

**What a run does:** for each mesh size and churn intensity (the number of Deployments scaled),
set up, then repeat 5 times: scale every churn target on the source member from 1 to 5 replicas
at once, time how long the local and remote proxies take to see the new pods, scale back and
settle. Then clean up and write the report. Rough time with two members at the defaults: 10 to
15 minutes.

**Reading the results:** the sweep's `sweep-<RUN_ID>.md` averages, per mesh size and intensity:

| Column | What it times, from the scale-up |
| --- | --- |
| `convergence_local_ms` | until the source member's proxies see the new pods and istiod reports every proxy in sync (includes pod start-up) |
| `convergence_remote_eds_ms` | until the remote istiod pushes the change (control plane only) |
| `remote_endpoint_reachable_ms` | until a remote proxy has the new pods as healthy endpoints: the end-to-end number |

Smaller is better; watch how the remote numbers grow with mesh size and intensity. For scale, the
June 2026 ten-cluster ROSA run measured local convergence of 2.4 to 3.7 s and remote reach of 7.8
to 12 s ([record](../../docs/campaigns/2026-06-04-clean-pass-results.md)). Rows with a status
other than `OK` are counted in `n_total` but not averaged; [What gets measured](#what-gets-measured)
lists them, and [Reading results](../../docs/reading-results.md) the checks that apply to every
suite.

## Architecture

> Diagram conventions are shared across suites — see
> [`docs/scale-test-campaign/architecture.md`](../../docs/scale-test-campaign/architecture.md#diagram-conventions).

```mermaid
graph TB
    DRV["churn probe (002)<br/>scales churn-target-N on the source only<br/>base → scale-to, all deployments at t0"]

    subgraph SRC["source cluster"]
        direction TB
        CT["churn-target-N (scaled)"]
        SP["istiod"]
        LSC["local sidecars"]
        SWENV["churn-watcher sidecar"]
    end
    subgraph RMT["remote cluster · churn targets stay at base"]
        direction TB
        RP["istiod"]
        WENV["churn-watcher sidecar"]
    end

    DRV -->|"scale up / down"| CT
    CT -->|"endpoint add / remove"| SP
    SP -->|"xDS push"| LSC
    SP -->|"EDS push"| SWENV
    CT -->|"cross-cluster endpoint watch"| RP
    RP -->|"EDS push"| WENV
    DRV -.->|"convergence_local_ms: /clusters"| SWENV
    DRV -.->|"then /debug/syncz all SYNCED"| SP
    DRV -.->|"convergence_remote_eds_ms: first EDS push"| RP
    DRV -.->|"remote_endpoint_reachable_ms: /clusters"| WENV

    classDef cluster fill:#eceff1,stroke:#90a4ae,color:#000;
    classDef controlplane fill:#e3f2fd,stroke:#1e88e5,color:#000;
    classDef dataplane fill:#e8f5e9,stroke:#43a047,color:#000;
    classDef harness fill:#f3e5f5,stroke:#8e24aa,color:#000;
    class DRV harness;
    class SRC,RMT cluster;
    class SP,RP controlplane;
    class CT,LSC,SWENV,WENV dataplane;
```

## What gets measured

One TSV row per iteration. istiod metrics are summed or merged across all istiod
replicas. Remote times and p99s are the max across remote clusters; remote counters the sum.
With no remote (mesh size 1) the remote columns are `N/A`.

| Column | Meaning |
|--------|---------|
| `convergence_local_ms` | The source watcher sees at least one new Ready pod per deployment and the source istiod reports every proxy SYNCED (`/debug/syncz`). Includes pod scheduling and sidecar start. |
| `convergence_remote_eds_ms` | First EDS push on the remote istiod after t0 (`pilot_xds_pushes{type="eds"}`). Control plane only. Polled from `/metrics`, so it can trail `remote_endpoint_reachable_ms` by a poll tick. |
| `remote_endpoint_reachable_ms` | Every churn target on the remote watcher has more healthy endpoint weight than before t0: at least one new Ready source pod per deployment. Includes pod scheduling and sidecar start. |
| `*_push_triggers_delta` | `pilot_push_triggers` increase during the iteration. |
| `*_xds_pushes_delta` | `pilot_xds_pushes` increase (one per proxy connection per xDS type). |
| `*_queue_time_p99_ms` / `*_push_time_p99_ms` | p99 of `pilot_proxy_queue_time` / `pilot_xds_push_time` for the iteration, interpolated within its histogram bucket and rounded to ms; `overflow` when it falls in the `+Inf` bucket. |
| `*_connected_proxies` | `pilot_xds` gauge before scaling. |
| `status` | See below. |

On a multi-network mesh a remote sidecar reaches source pods through the east-west
gateway: the gateway endpoint's weight, not the endpoint count, grows with the number of
Ready source pods. The probe therefore sums healthy endpoint weight.

`status` values: `OK`; `TIMEOUT_LOCAL` / `TIMEOUT_REMOTE` (no convergence within
`--timeout`); `POISONED_RESTART` (an istiod restarted mid-iteration, istiod columns are
`N/A`); `SCRAPE_INCOMPLETE` (an istiod `/metrics` scrape failed, counters undercounted);
`SCRAPE_INCOMPLETE_REMOTE_EDS` (a remote's EDS poll never completed a scrape of its istiod,
so `convergence_remote_eds_ms` was not measured and reads `N/A`; no remote timed out);
`TIMEOUT_REMOTE_EDS` (no remote EDS push within `--timeout`); `MISSING_VALUE` (another
measured column has no number: a watcher that did not list every churn target, or a push
counter in neither istiod scrape, e.g. renamed; the probe's stderr names the column);
`SETUP_FAILED` / `PROBE_FAILED` (placeholder for a failed iteration or sweep combo).
An `OK` row has a number in every convergence column and push-counter delta.
The report averages `OK` rows only and shows `n_total` and `n_valid` (`--help` lists the
statuses). A row an older `002` wrote as `OK` with no number in a measured column counts as
`TIMEOUT_REMOTE_EDS` or `MISSING_VALUE`, with a warning on stderr. The p99 columns are
not averaged: the report shows the worst bucket range a valid row hit (e.g. `500-1000`),
or `overflow (N rows)` when N valid rows had their p99 in the `+Inf` bucket (csv: the
`worst_bucket` and `n_overflow` columns).

The TSV preamble records [what every result records](../../docs/reference.md#what-every-result-records),
read before the first churn event (a sweep reads the platform record once for all its combos).
`004` prints it in every format (text, csv, md, charts; it has no json), per member as
`<ctx>=mixed:a;b` with a warning in the report itself when the inputs differ (`KUBE_VERSIONS`:
different Kubernetes versions) or a value could not be read in some of them. A TSV written before
`HARNESS_SHA` or `ISTIO_VERSION` was recorded reads `unknown (not recorded)`, and one from before
the platform record (the suite supported only OpenShift with OSSM then) reads `unknown` there.
Timestamps are UTC.

Every source or remote istiod status other than `0` also saves the restart evidence to
`istiod-diag-<RUN_ID>/` next to the TSV, tag `iter<N>`, after the row is written; a failed
capture never adds a `SETUP_FAILED` row. A pod replaced between iterations (scale-down,
settle) is in no row; the next iteration's port-forward check sees the new pod set and
captures it (trigger `podset_changed`, tag `before-iter<N>`). Contents, settings and
redaction are in the [dataplane README](../dataplane/README.md#restart-evidence-istiod-diag-run_id);
the report ends text and md with an "istiod restart diagnostics" section.

The report's push amplification is `(source + remote xDS pushes) / source push triggers`.
It grows with connected proxies, so compare it across mesh sizes, not against 1.

## Quick start

Needs `kubectl` or `oc`, `helm`, `jq`, `curl`, the deployed mesh (see the root README)
and kube contexts for the mesh members (not the hub).

```bash
# 1. Deploy churn targets and a watcher on each mesh member
./tests/churn/001-setup-churn-test.sh --contexts <mesh-a-ctx>,<mesh-b-ctx>

# 2. Scale 5 deployments 1 -> 5 replicas on the source, 5 iterations
./tests/churn/002-run-churn-probe.sh \
  --source-context <mesh-a-ctx> --remote-contexts <mesh-b-ctx> --iterations 5

# 3. Summarize tests/churn/results/
# (it reads every run under the results dir; with more than one there it stops and
#  lists the --results-dir that reports each, or pools them with --allow-multi-run)
./tests/churn/004-report-results.sh --format md

# 4. Remove the test namespace
./tests/churn/005-cleanup.sh --contexts <mesh-a-ctx>,<mesh-b-ctx>
```

Add `--dry-run` to any script to see what it would do without changing the clusters.

## Sweep

```bash
./tests/churn/003-run-sweep.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> --churn-intensities 5,10,20
```

For each mesh size (default `1..N`; the first context is the source) and each churn
intensity (deployment count) the sweep runs setup, probe and cleanup. It writes the TSVs,
`sweep-<run-id>.md` and `sweep-charts-<run-id>.md` to `tests/churn/results/sweep-<run-id>/`.
Charts need at least three contexts (two mesh sizes with a remote).
A failed setup or probe becomes a placeholder row and the sweep moves on.

Exit codes: `0` every cell (mesh size x intensity) ran; `1` the sweep stopped (a bad flag or
precondition, or an unexpected error); `130`, `143` or `129` it was interrupted; `4` it finished
and wrote its reports, but some cells failed (a `SETUP_FAILED` / `PROBE_FAILED` placeholder) or it
recorded a problem ([How a sweep ends](../../docs/reference.md#how-a-sweep-ends) has those, and the
`sweep-outcome.txt` record every report repeats). The last line on stderr says how many, by
reason. When a sweep did not finish and no sweep runs any more, run `005-cleanup.sh --contexts <the
sweep's members>`, then run the sweep again into a new dir; the rows already in the dir cover only
the cells it finished.
Rows a probe wrote with a non-OK status (`TIMEOUT_*`, `MISSING_VALUE`,
...) are measurements, not failed cells: the report counts them in `n_total`.

## Run config (`--config FILE`)

Every script takes `--config FILE`, one file of `KEY=value` lines for a whole run (shared
rules: [Run config](../../docs/reference.md#run-config---config-file)).
[`configs/smoke.env`](configs/smoke.env) is a worked example (mesh sizes 1 and 2,
2 and 4 Deployments scaled 1 to 2, 2 iterations):

```bash
./tests/churn/003-run-sweep.sh --config tests/churn/configs/smoke.env --dry-run
./tests/churn/003-run-sweep.sh --config tests/churn/configs/smoke.env
./tests/churn/004-report-results.sh --config tests/churn/configs/smoke.env \
  --results-dir tests/churn/results/smoke/sweep-<RUN_ID> --format md
./tests/churn/005-cleanup.sh --config tests/churn/configs/smoke.env
```

- **Keys:** `SETUP_CONTEXTS` and the `config/options.env` keys `CHURN_*`, `FANOUT_*`,
  `ISTIOD_DIAG_*` (restart evidence), `TEST_PLATFORM` (the members' platform),
  `PLATFORM_READ_TIMEOUT` (each read of the platform record), `PLATFORM_READ_PARALLEL` (members
  read at once) and `METRICS_SCRAPE_TIMEOUT`. `CHURN_TEST_NAMESPACE` stays environment only.
- **One value or a list:** `001` and `002` read `CHURN_DEPLOYMENT_COUNT`; the sweep reads the
  CSV `CHURN_INTENSITIES` (`--churn-intensities`; empty: `CHURN_DEPLOYMENT_COUNT`) and
  `CHURN_MESH_SIZES` (`--mesh-sizes`; empty: 1 to the number of contexts). A list key exported
  in the environment beats a one-value key in the file.
- **Other run keys:** `CHURN_RESULTS_DIR` (`--output-dir`, `--results-dir`; a relative path
  starts at the repo root, unlike the flags) and `CHURN_WAIT_TIMEOUT_SEC`
  (`001 --wait-timeout`).
- **Flags only:** `--source-context`, `--remote-contexts`, `--mesh-size`,
  `--tuning-baseline` and `--sidecar-egress-hosts` (`002`; the sweep sets them),
  `--allow-multi-run` (`004`), `--format` and `--dry-run`.

## Settings

Defaults live in `config/options.env` and flags override them: `CHURN_TEST_NAMESPACE`
(`churn-test`), `CHURN_DEPLOYMENT_COUNT` (5), `CHURN_BASE_REPLICAS` (1),
`CHURN_SCALE_TO_REPLICAS` (5, must exceed base), `CHURN_ITERATIONS` (5),
`CHURN_TIMEOUT_SEC` (120), `CHURN_POLL_INTERVAL_MS` (250).

## Scripts

| Script | Purpose |
|--------|---------|
| `001-setup-churn-test.sh` | Deploy churn targets and the watcher on each context. |
| `002-run-churn-probe.sh` | Scale the source, measure convergence, write one TSV row per iteration. |
| `003-run-sweep.sh` | Run setup, probe and cleanup across mesh sizes and churn intensities. |
| `004-report-results.sh` | Summarize TSVs as text, csv, md or charts. |
| `005-cleanup.sh` | Delete the test namespace. |

# Tuning profiles

Measure what an Istio tuning change does to a test suite. A sweep measures the
GitOps baseline, then applies each profile, runs the suite's probe and reverts,
and writes a comparison table.

## Prerequisites

- bash 4+, `kubectl` or `oc`, and `python3` with PyYAML.
- The mesh deployed by GitOps (`charts/spoke-ossm`). Its baseline already has root
  Sidecar scoping, discoverySelectors, client-metric and access-log filtering, istiod
  at 4 CPU / 16Gi and sidecar limits. Profiles change things on top of that.
- Contexts for the mesh members and for the ACM hub (Argo CD runs there).

## Profiles

| Profile | Change | OSSM | Suites |
| --- | --- | --- | --- |
| `01-push-throttling` | istiod env `PILOT_DEBOUNCE_AFTER=200ms`, `PILOT_DEBOUNCE_MAX=15s`, `PILOT_PUSH_THROTTLE=20` | configurable | churn, churn-dataplane, propagation, controlplane |
| `02-xds-cache-off` | istiod env `PILOT_ENABLE_CDS_CACHE=false`, `PILOT_ENABLE_RDS_CACHE=false` | configurable | propagation, churn, controlplane |
| `03-gateway-cluster-filter` | istiod env `PILOT_FILTER_GATEWAY_CLUSTER_CONFIG=true` (experimental) | configurable | controlplane, dataplane |
| `04-connection-pools` | DestinationRule `tuning-connection-pool` in `istio-system` for `*.svc.cluster.local` | supported | dataplane, churn-dataplane |

**supported**: a documented OSSM API. **configurable**: set through
`spec.values.pilot.env` on the Istio CR; Red Hat does not document the variable.
Each profile YAML lists the Istio 1.30 defaults it changes.

To measure a baseline lever (Sidecar scoping, discoverySelectors, telemetry), toggle
`tuningBaseline.*` in `charts/spoke-ossm/values.yaml` through Git.

## Run a sweep

```bash
./tests/tuning/003-run-tuning-sweep.sh --suite churn \
  --contexts <mesh-a-ctx>,<mesh-b-ctx> --gitops-context <acm-hub-ctx> --dry-run
```

`--dry-run` prints every command and checks the probe arguments; remove it to run.
`--suite` is one of `propagation`, `controlplane`, `dataplane`, `churn`,
`churn-dataplane`. The first context is the source for suites that take one.
Other options: `--profiles 01-push-throttling,04-connection-pools`, `--no-baseline`,
`--skip-setup`, `--keep-workloads`, `--settle SEC`, `--churn-rate N` (see `--help`).

The sweep:

1. Pauses Argo CD auto-sync of the `<cluster>-ossm` Applications (006).
2. Runs the suite's setup once.
3. For the baseline and each profile: apply (001), wait `--settle`, run the probe,
   revert (002). A failed revert stops the sweep.
4. Writes `sweep-comparison.md` (004), runs the suite's cleanup, resumes Argo CD.
   On Ctrl-C or an error it still reverts the active profile and resumes Argo CD.

## Results

```
tests/tuning/results/sweep-<RUN_ID>/
├── sweep-metadata.txt
├── sweep-comparison.md      # means of valid rows; profiles show % change vs baseline
├── baseline/                # suite TSV + .md, probe-output.log
└── 01-push-throttling/      # same, plus state/ (revert data)
```

`SETUP_FAILED`, `PROBE_FAILED` or `REVERT_FAILED` in a pass directory shows in the
table. Re-render: `./tests/tuning/004-compare-profiles.sh --results-dir <sweep-dir> --format markdown`.

## One profile by hand

```bash
./tests/tuning/006-gitops-pause.sh --gitops-context <acm-hub-ctx> --pause
./tests/tuning/001-apply-profile.sh --profile 01-push-throttling --contexts <mesh-a-ctx>,<mesh-b-ctx>
# ... run a suite probe ...
./tests/tuning/002-revert-profile.sh --state-dir tests/tuning/results/state-01-push-throttling
./tests/tuning/006-gitops-pause.sh --resume
```

## How apply, revert and the Argo CD pause work

- **001** saves the Istio CR and builds a merge patch that restores the saved value,
  or removes the key, at every path the profile sets. It refuses to overwrite a
  resource that already exists, so it never touches baseline objects.
- **002** applies that patch, deletes the profile's resources, then checks that those
  paths and resources match the pre-apply state. On failure it exits 3 and keeps the
  `active-profile` marker so it can be retried.
- **006** adds a deny sync window for the Applications to their AppProject (and
  removes it on resume). Patching an Application's `syncPolicy` would be undone by
  the ApplicationSet controller.

## After an interrupted run

```bash
./tests/tuning/005-cleanup.sh --contexts <mesh-a-ctx>,<mesh-b-ctx>
```

Reverts profiles still marked active, deletes leftover profile resources (label
`istio-scale-tests/tuning-profile`) and resumes recorded Argo CD pauses. Run the
suite's own cleanup too if its workloads are still deployed.

## Adding a profile

A profile YAML has `description`, `ossm_support` (`supported` or `configurable`),
optional `ossm_support_detail`, `istio_cr_patch` (under `spec` only; `pilot.env`
values are quoted strings) and `resources` (DestinationRule, Sidecar, Telemetry or
EnvoyFilter, with names the baseline does not use). It must change something the
baseline does not already set. Skip proxy settings (`meshConfig.defaultConfig`,
`global.proxy`): they only reach pods injected after the change, and the sweep does
not restart workloads.

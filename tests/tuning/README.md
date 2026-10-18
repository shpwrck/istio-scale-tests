# Tuning profiles

Measure what an Istio tuning change does to a test suite. A sweep measures the
GitOps baseline, then applies each profile, runs the suite's probe and reverts,
and writes a comparison table.

## Prerequisites

- bash 4+, `kubectl` or `oc`, and `python3` with PyYAML.
- The mesh deployed by GitOps (`charts/spoke-ossm`). Its baseline already has root
  Sidecar scoping, discoverySelectors, and client-metric and access-log filtering.
  Profiles change things on top of that.
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
  --contexts <mesh-a-ctx>,<mesh-b-ctx> --gitops-context <acm-hub-ctx> \
  --profiles 02-xds-cache-off --settle 30 --dry-run
```

`--dry-run` prints every command and checks the probe arguments; remove it to run.
`--suite` is one of `propagation`, `controlplane`, `dataplane`, `churn`,
`churn-dataplane`. The first context is the source for suites that take one.
Without `--profiles` the sweep runs every profile. Other options: `--no-baseline`,
`--skip-setup`, `--keep-workloads`, `--churn-rate N` (see `--help`).

The suite's setup and probes take their sizes from `config/options.env`. Override
them in the environment, for example `CHURN_ITERATIONS=2 ./tests/tuning/003-run-tuning-sweep.sh ...`.

The sweep:

1. Pauses Argo CD auto-sync of the `<cluster>-ossm` Applications (006).
2. Runs the suite's setup once.
3. For the baseline and each profile: apply (001), wait `--settle`, run the probe,
   revert (002). A failed revert stops the sweep.
4. Writes `sweep-comparison.md` (004), runs the suite's cleanup, resumes Argo CD.

On Ctrl-C or an error the sweep still reverts the active profile and resumes Argo CD.
It leaves the suite's workloads; remove them with the suite's cleanup script. A signal
sent to the sweep's process alone (`kill <pid>`, `kill -INT <pid>`) reaches the step that runs
and every process under it at once (any still running `SWEEP_STOP_GRACE_SEC`, 30 s by default,
later get SIGKILL), before the revert. For a sweep in a terminal's foreground, a `kill -INT` or
`kill -HUP` sent from elsewhere skips the processes in that foreground (a Ctrl-C reaches them
itself): they get SIGKILL after the grace, with no cleanup, so stop such a sweep from elsewhere
with SIGTERM. The sweep's own commands between steps finish first, each bounded: the `--settle`
wait and the proxy reads after it, the generation reads around each apply and revert, and the
end-of-sweep recheck. Stopping the step's tree needs a `ps` that lists start times (procps, or
macOS's): without one, the sweep warns at its start, and a stop reaches only the step's own process.

A profile's apply and revert patch the Istio CR, which raises its generation and its active
IstioRevision's. The sweep reads the generations again after the suite setup, before and after
each apply, and after each revert, so each pass's TSVs record the ones it ran on, and the check
at the end covers only the time after the last revert; it reads the proxy versions
(`ISTIO_PROXY_VERSIONS`) once each pass has settled, before its probes (right after a rollout,
old istiod pods may still be terminating; a pod being deleted is left out of that read, with a
note). 001 records the generations once its apply settled (`istio-generations-applied` in the
pass's `state/`; the sweep then writes its own read there); 002 compares them before its
revert. The sweep reports these as problems (exit `4`, the revert still runs):

- the Istio CR changed during a pass, after its apply settled and not by its profile
  (Argo CD not paused, another operator, an OSSM operator upgrade; 002 warns and writes
  `istio-edited-during-pass` in `state/`). A re-run of 002 after a revert that stopped
  partway (`revert-started` in `state/`: it may have patched the Istio CR already) skips this
  check, with a note, and keeps what the first run found;
- it changed while the sweep changed nothing: during the suite setup, the baseline pass, a
  profile that leaves the Istio CR alone (`istio_cr_patch: {}`), between one pass's revert
  and the next pass's apply, or after the last revert (the end check);
- its generation rose by more than 1, or fell, across a profile's apply or revert: that
  step's merge patch raises it by exactly 1, so something else edited it (or deleted and
  created it) during the step (the IstioRevision's is left out: Sail moves it as it renders);
- a member's Istio CR `spec` after the last revert differs from the sweep's start (an
  incomplete revert; the differing paths are named, and both specs are in `istio-spec/`).

A member whose generations could not be read for one of these comparisons (a read that
failed twice, on a busy API server) is not compared: the sweep warns and its outcome notes
the span it could not check (`NOTE=`; for 002's comparison, `istio-generations-unchecked` in
`state/`), so an edit in that span is not ruled out. 001 warns when it records a member as
`unknown`. A new apply clears what an earlier apply and its revert left in `state/`.

Exit codes: `0` every pass ran its probe; `1` the sweep stopped (a bad flag or precondition, also
another live run that holds the sweep dir's `.sweep.lock`; a failed suite setup, a failed
revert, or an unexpected error); `4` it finished, reverted every profile and wrote
`sweep-comparison.md`, but some passes failed (`SETUP_FAILED`: the profile did not apply;
`PROBE_FAILED`: the probe exited non-zero, including a reachability stop), or the mesh changed
under it: the Istio version or active revision changed during the sweep, the generation of the
Istio CR or its active IstioRevision went up other than by the sweep's own apply and revert (an
edit with the same version, an OSSM operator upgrade or a TLS profile change; see above), or
the last revert left the Istio CR's spec unlike the start; or its harness (`HARNESS_SHA`)
changed during the sweep. Each is an `error:` line on stderr; the failed passes' line says how
many, by reason; `sweep-outcome.txt` and the end of `sweep-comparison.md` keep the outcome.
From the sweep's start until it writes its outcome, `sweep-outcome.txt` holds a not-finished
record (`EXIT=unfinished`, `STARTED_AT`, `RUN_ID`, `HARNESS_SHA`, and what to do), so a report of a
sweep that died, or still runs, or (with when and by which signal) was interrupted says "this
sweep has not finished" in every format (json `sweep_outcome`: `"exit": null`, `"unfinished":
true`; a finished one reads `"unfinished": false`; one that stopped on an error after its start
records the stop and its reason instead, `STOPPED=1` and `CUT_SHORT=1`, see the top-level
README): when no sweep runs any more, check that no profile is still applied (`005-cleanup.sh`)
and that Argo CD auto-sync is resumed (`006-gitops-pause.sh --resume`), then run the sweep again
into a new dir. Proxies connected on another Istio version than their istiod
(`ISTIO_PROXY_VERSIONS`, as last read: after the last pass's settle) are a note of the outcome,
never a failure. `130` / `143` / `129`: interrupted (Ctrl-C, SIGTERM, SIGHUP), after reverting the
active profile; `sweep-outcome.txt` then says when and by which signal, with what the generation
checks found until then (each problem as a note: a not-finished record counts nothing; a stop record
keeps it as a problem).

## Results

```
tests/tuning/results/sweep-<RUN_ID>/
├── sweep-metadata.txt       # suite, passes, HARNESS_SHA, HARNESS_CONTENT_KEY, ISTIO_VERSION (read
│                            # live once; every probe records it), the pin, ISTIO_NOTREADY_AT_START
├── sweep-comparison.md      # means of valid rows with n and range (histogram p99s: worst bucket); % change vs baseline
├── istio-spec/              # each member's Istio CR spec at the start and after the last revert (start-<ctx>.json, end-<ctx>.json)
├── baseline/                # suite TSV + .md, probe-output.log
└── 01-push-throttling/      # same, plus state/ (revert data, istio-generations-applied)
```

`SETUP_FAILED`, `PROBE_FAILED` or `REVERT_FAILED` in a pass directory shows in the
table. Data-plane rows are split by target class (local or remote) and QPS; a row that
missed its target QPS (`QPS_SHORTFALL`) is not valid, and the data-plane servers run
`DATAPLANE_SERVER_REPLICAS` pods per cluster (2 by default). Histogram p99 rows
(convergence, push time) are never averaged: they show the worst bucket range a valid row
hit, or `overflow (N rows)` when N rows had their p99 in the +Inf bucket; propagation's P1
convergence counts iterations instead, `overflow (N iterations)`: N iterations put a sample
in the +Inf bucket (counted, although propagation 005 leaves them out of its means). The
`P1 local push` cell adds `(N overflowed)` for the iterations its mean leaves out for that
overflow (`- (N overflowed)` when every one did); P1 is left out of an iteration only for a
source-side reason, as in 005 (a remote that timed out or restarted keeps it). Units: memory
in Mi, CPU in millicores (the controlplane's `istiod CPU peak (m)` and `istiod memory peak
(Mi)` are window peaks), the sidecar config in KiB. Under each metric, `n (got/attempted)`
counts the valid samples with a value over what the pass's probe was configured to take, where
its TSV records it (propagation: iterations for P1 and its convergence, iterations x remotes
for P2 and P3; churn: iterations), else over every row the pass wrote (failed and timed-out
rows included); `range` gives its min to max. "TSV columns" gives the data rows' column count,
per pass when the passes differ, with a warning: their rows were written by different harness
versions. It reads `none (no pass wrote a TSV)` when no pass wrote one, and `none (no pass's
TSV has a data row)` when none has a row. The `Istio CR / IstioRevision generations` row gives
each pass's `ISTIO_GENERATIONS` from its own TSVs: a profile's apply and revert raise them, so
each pass ran on its own (`2/2 (every member)` when every member has one value; `mixed:...`
when the pass's TSVs disagree, `unknown` for a TSV without the key, `-` for a pass without a
TSV). The "Harness (HARNESS_SHA)" row gives each pass's `HARNESS_SHA` from its own TSVs: passes
on different harnesses get a WARNING (a profile's change may come from the harness), or a note
when every pass records one `HARNESS_CONTENT_KEY` (they differ only in `git describe`). A
propagation comparison counts a `DRAIN_TIMEOUT` side, as 005 does (measured before that drain),
and adds a "Drain timeouts (iterations, counted)" row when a pass has one. The page also
records `REPORT_HARNESS_SHA` (text: `REPORT_HARNESS_SHA=... (this report's own)`), the harness
the comparison itself ran on, next to the sweep's `HARNESS_SHA`: a comparison made again later,
or from another checkout, may count rows by other rules. The sweep dir it reads never counts as
a change to that harness. The markdown starts with a YAML frontmatter of these keys (`suite`,
`run_id`, `contexts`, `passes`, the `istio_*` keys, `harness_sha`, `report_harness_sha`,
`tsv_columns`). A profile whose n differs from the baseline's shows `(baseline n ...)` and the
page warns: its mean comes from other iterations, so a profile that timed out on the slow ones
can look faster than it is. Re-render:
`./tests/tuning/004-compare-profiles.sh --results-dir <sweep-dir> --format md`.

## One profile by hand

```bash
./tests/tuning/006-gitops-pause.sh --gitops-context <acm-hub-ctx> --pause
./tests/tuning/001-apply-profile.sh --profile 01-push-throttling --contexts <mesh-a-ctx>,<mesh-b-ctx>
# ... run a suite probe ...
./tests/tuning/002-revert-profile.sh --state-dir tests/tuning/results/state-01-push-throttling
./tests/tuning/006-gitops-pause.sh --resume
```

`006-gitops-pause.sh --gitops-context <acm-hub-ctx> --status` lists the sync windows.

## How apply, revert and the Argo CD pause work

- **001** saves the Istio CR and builds a merge patch that restores the saved value,
  or removes the key, at every path the profile sets. It refuses to overwrite a
  resource that already exists, so it never touches baseline objects.
- **002** applies that patch, deletes the profile's resources, then checks that those
  paths and resources match the pre-apply state. On failure it exits 3 and keeps the
  `active-profile` marker so it can be retried. With
  `TUNING_REVERT_HEALTHCHECK_NS_PROBE=1` it also checks that istiod still delivers
  `istio-ca-root-cert` to a new namespace.
- **006** adds a deny sync window for the Applications to their AppProject. Resume
  removes it from the context and namespace recorded at pause. Patching an
  Application's `syncPolicy` would be undone by the ApplicationSet controller.

## After a killed run

If the sweep could not clean up (for example `kill -9` or a lost shell), run:

```bash
./tests/tuning/005-cleanup.sh --contexts <mesh-a-ctx>,<mesh-b-ctx>
```

It reverts profiles still marked active, deletes leftover profile resources (label
`istio-scale-tests/tuning-profile`) and resumes recorded Argo CD pauses. Add
`--results-dir DIR` if the sweep used `--output-dir`. Then run the suite's cleanup.
001 and 003 refuse to start while a profile is still marked active.

## Adding a profile

A profile YAML has `description`, `ossm_support` (`supported` or `configurable`),
optional `ossm_support_detail`, `istio_cr_patch` (under `spec` only; `pilot.env`
values are quoted strings) and `resources` (DestinationRule, Sidecar, Telemetry or
EnvoyFilter, with names the baseline does not use). It must change something the
baseline does not already set. Skip proxy settings (`meshConfig.defaultConfig`,
`global.proxy`): they only reach pods injected after the change, and the sweep does
not restart workloads.

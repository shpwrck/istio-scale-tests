# Tuning profiles

Measure what an Istio tuning change does to a test suite. A sweep measures the
GitOps baseline, then applies each profile, runs the suite's probe and reverts,
and writes a comparison table.

## Prerequisites

- bash 4+, `kubectl` or `oc`, `jq`, and `python3` with PyYAML.
- The mesh deployed by GitOps (`charts/spoke-ossm`). Its baseline already has root
  Sidecar scoping, discoverySelectors, and client-metric and access-log filtering.
  Profiles change things on top of that.
- Contexts for the mesh members and for the hub (Argo CD runs there).

## Profiles

| Profile | Change | OSSM | Suites |
| --- | --- | --- | --- |
| `01-push-throttling` | istiod env `PILOT_DEBOUNCE_AFTER=200ms`, `PILOT_DEBOUNCE_MAX=15s`, `PILOT_PUSH_THROTTLE=20` | configurable | churn, churn-dataplane, propagation, controlplane |
| `02-xds-cache-off` | istiod env `PILOT_ENABLE_CDS_CACHE=false`, `PILOT_ENABLE_RDS_CACHE=false` | configurable | propagation, churn, controlplane |
| `03-gateway-cluster-filter` | istiod env `PILOT_FILTER_GATEWAY_CLUSTER_CONFIG=true` (experimental) | configurable | controlplane, dataplane |
| `04-connection-pools` | DestinationRule `tuning-connection-pool` in `istio-system` for `*.svc.cluster.local` | supported | dataplane, churn-dataplane |

**supported**: a documented OSSM API. **configurable**: set through
`spec.values.pilot.env` on the Istio CR; Red Hat does not document the variable. The OSSM column
is Red Hat's support status, for the OpenShift profile; on Kubernetes the upstream Sail operator
takes the same Istio CR, so every profile applies the same way.
Each profile YAML lists the Istio 1.30 defaults it changes.

To measure a baseline lever (Sidecar scoping, discoverySelectors, telemetry), toggle
`tuningBaseline.*` in `charts/spoke-ossm/values.yaml` through Git.

## Run a sweep

```bash
./tests/tuning/003-run-tuning-sweep.sh --suite churn \
  --contexts <mesh-a-ctx>,<mesh-b-ctx> --gitops-context <hub-ctx> \
  --profiles 02-xds-cache-off --settle 30 --dry-run
```

`--dry-run` prints every command and checks the probe arguments; remove it to run.
`--suite` is one of `propagation`, `controlplane`, `dataplane`, `churn`,
`churn-dataplane`. The first context is the source for suites that take one.
Without `--profiles` the sweep runs every profile; list each profile once (each pass writes to
a directory named after its profile, so the sweep refuses one listed twice). Other options:
`--no-baseline`, `--skip-setup`, `--keep-workloads`, `--churn-rate N` (see `--help`).

The suite's setup and probes take their sizes from `config/options.env`. Override
them in the environment, for example `CHURN_ITERATIONS=2 ./tests/tuning/003-run-tuning-sweep.sh ...`.

The sweep:

1. Pauses Argo CD auto-sync of the `<cluster>-ossm` Applications (006).
2. Runs the suite's setup once.
3. For the baseline and each profile: apply (001), wait `--settle`, read the platform
   record, run the probe, read the record again, revert (002). A failed revert stops the
   sweep.
4. Writes `sweep-comparison.md` (004), runs the suite's cleanup, resumes Argo CD.

On Ctrl-C or an error the sweep still reverts the active profile and resumes Argo CD.
It leaves the suite's workloads; remove them with the suite's cleanup script. On a signal
(Ctrl-C, `kill <pid>`) the running step's process group gets SIGTERM, and SIGKILL
`SWEEP_STOP_GRACE_SEC` (30 s by default) later, before the revert. The sweep's own commands
between steps finish first, each bounded: the `--settle` wait, the platform reads around each
pass's probes, and the end-of-sweep checks.

A profile's apply and revert patch the Istio CR, which raises its generation and its active
IstioRevision's. 001 records them once its apply has settled (`istio-generations-applied` in the
pass's `state/`, warning once when it cannot read a member), and the pass's TSVs record that
value. 002 reads them again before its revert: a move means something else edited the Istio CR
during the pass (Argo CD not paused, another operator, an OSSM operator upgrade), so 002 warns,
writes `istio-edited-during-pass` in `state/`, and the sweep makes it a problem naming the pass
(a re-run of 002 after a revert that stopped partway, `revert-started` in `state/`, skips the
check with a note). The baseline pass has no apply and revert to bracket it: the sweep reads the
generations before its first probe and after its last, and a move is a problem naming the pass.
After the last revert the sweep reads each member's Istio version and active revision again (a
change is a problem), and the generations too when no profile was applied (every apply stopped
before its first change), and compares its Istio CR `spec` with the sweep's start:
a difference (an incomplete revert, or an edit no revert undid, since they restore only the
profiles' keys) is a problem naming the differing paths, with both specs in `istio-spec/`.

Exit codes: `0` every pass ran its probe; `1` the sweep stopped (a bad flag or precondition, a
failed suite setup, a failed revert, or an unexpected error); `4` it finished, reverted every
profile and wrote `sweep-comparison.md`, but some passes failed (`SETUP_FAILED`: the profile did
not apply; `PROBE_FAILED`: the probe exited non-zero, including a reachability stop), or it
recorded a problem (those of [every sweep](../../README.md#how-a-sweep-ends); the Istio CR or a
member's platform record changed during a pass, above and below; or the last revert left the
Istio CR's spec unlike the start); `130` / `143` / `129`: interrupted (Ctrl-C, SIGTERM, SIGHUP),
after reverting the active profile. `sweep-comparison.md` repeats `sweep-outcome.txt`. When a
sweep did not finish and no sweep runs any more, check that no profile is still applied
(`005-cleanup.sh`) and that Argo CD auto-sync is resumed (`006-gitops-pause.sh --resume`), then run
the sweep again into a new dir.

## Results

```
tests/tuning/results/sweep-<RUN_ID>/
├── sweep-metadata.txt       # suite, passes, HARNESS_SHA, ISTIO_VERSION (read live once; every
│                            # probe records it), the pin, each member's revision and generations
├── sweep-comparison.md      # means of valid rows with n and range (histogram p99s: worst bucket); % change vs baseline
├── gitops-pause.json        # only while the sweep holds Argo CD paused, or after it was killed
├── istio-spec/              # each member's Istio CR spec at the start and after the last revert (start-<ctx>.json, end-<ctx>.json)
├── baseline/                # suite TSV + .md, probe-output.log, platform-record.txt
└── 01-push-throttling/      # same, plus state/ (patch.json, the revert data and istio-generations-applied)
```

004 reads each pass's TSVs, `sweep-metadata.txt` and `sweep-outcome.txt`: keep them when you
archive a sweep. `platform-record.txt` hands the record read before a pass's probe to the probe;
`gitops-pause.json` is what 005 resumes a pause from (see "After a killed run").

`SETUP_FAILED`, `PROBE_FAILED` or `REVERT_FAILED` in a pass directory shows in the table's
`Pass status` row (`ok` otherwise), and so does `no data`: a pass without TSVs (one the metadata
lists without its directory, or whose probe wrote none). Data-plane rows are split by target class
(local or remote) and QPS; a row that missed its target QPS (`QPS_SHORTFALL`) is not valid, and the
data-plane servers run `DATAPLANE_SERVER_REPLICAS` pods per cluster (2 by default). Histogram p99
rows (convergence, push time) are never averaged: they show the worst bucket range a valid row hit,
or `overflow (N rows)` when N rows had their p99 in the +Inf bucket; propagation's P1 convergence
counts iterations instead, `overflow (N iterations)`: N iterations put a sample in the +Inf bucket
(counted, although propagation 005 leaves them out of its means). The `P1 local push` cell adds
`(N overflowed)` for the iterations its mean leaves out for that overflow (`- (N overflowed)` when
every one did); P1 is left out of an iteration only for a source-side reason, as in 005 (a remote
that timed out or restarted keeps it). Units: memory in Mi, CPU in millicores (the controlplane's
`istiod CPU peak (m)` and `istiod memory peak (Mi)` are window peaks), the sidecar config in KiB.
Under each metric, `n (got/attempted)` counts the valid samples with a value over what the pass's
probe was configured to take, where its TSV records it (propagation: iterations for P1 and its
convergence, iterations x remotes for P2 and P3; churn: iterations), else over every row the pass
wrote (failed and timed-out rows included); `range` gives its min to max. The header gives the
sweep's `HARNESS_SHA`; a "Harness (HARNESS_SHA)" row, each pass's from its own TSVs, shows only when
one differs from it, and passes on different harnesses get a WARNING (a profile's change may come
from the harness). The header also gives each member's active revision and Istio CR generations over
the sweep's start and its passes (a profile's apply and revert raise them). A propagation comparison
counts a `DRAIN_TIMEOUT` side, as 005 does (measured before that drain), and adds a "Drain timeouts
(iterations, counted)" row when a pass has one. The markdown starts with a YAML frontmatter of these
keys (`suite`, `run_id`, `contexts`, `passes`, the `istio_*` keys, `harness_sha`, and `settle_sec`
and `churn_rate` when the sweep recorded them). A profile whose n differs from the baseline's shows
`(baseline n ...)` and the page warns: its mean comes from other iterations, so a profile that timed
out on the slow ones can look faster than it is. Re-render:
`./tests/tuning/004-compare-profiles.sh --results-dir <sweep-dir> --format md`.

Each pass reads the platform record live before its probe
([`tests/lib/platform.sh`](../lib/platform.sh): the platform, the mesh operator, istiod and
gateway proxy builds, the nodes' provider, istiod's settings), and its tuning levers and root
Sidecar egress hosts on the source member; the probe's TSVs carry them, with each member's
Kubernetes version and, as its suite records them, istiod's limits (controlplane) and replica
counts (controlplane: each member's Deployment replicas; propagation and churn: each member's
Running istiod pods; churn-dataplane: the source member's; dataplane: none). `platform-record.txt`
in the pass directory hands the record over. After the probe the pass reads the record again: a
value that changed during the pass (a profile reverted by hand, an Argo CD sync that put istiod's
settings back, a control-plane upgrade) is a problem of the sweep's outcome naming the pass, the
key, the member and both values, and a member it cannot read again is a note there.

The table's `Platform record` row compares each pass with the baseline (without a baseline, the
first pass with data, which reads `reference`; the baseline reads `baseline`), each side merged
over its TSVs: on every record key but istiod's settings, and on `KUBE_VERSIONS`,
`TUNING_BASELINE` (each lever `on` or `off`), `SIDECAR_EGRESS_HOSTS` (the root Sidecar's) and
istiod's limits (`ISTIOD_LIM_CPU_M`, `ISTIOD_LIM_MEM_MI`) and replica counts
(`ISTIOD_REPLICAS_BY_CONTEXT`, `ISTIOD_REPLICAS`) where its suite records them. A pass reads
`same`; `differs (see warnings)` when a key differs, with a warning that names the pass and the
key and gives both values (each with its member count, digests shortened, a long value cut), since
its change against the baseline is then not the profile's alone; `unknown (see notes)` when a key
was not read or not recorded on one side (a digest `@unknown`, a member's version `unreachable`, a
lever `unknown`, a TSV from before the key), so whether it differs is not known; `-` without data.
A member whose TSVs disagree (`mixed:<a>;<b>`) matches the other side when that side ran the same
values. The profiles in `profiles/` set only istiod's env and root-namespace resources, so a lever
or replica count that differs was changed by something else. The header gives the reference
pass's record in one line.

Only the controlplane suite's TSVs record istiod's limits, and the dataplane suite's record no
replica count, so those sweeps compare none of them. Nothing else shows a CPU limit that changes:
istiod's Deployment sets `GOMAXPROCS` from `limits.cpu` by reference (`valueFrom`, so the env
digest does not change with it), and `GOMAXPROCS` sets the defaults of `PILOT_PUSH_THROTTLE`
(which profile 01 tunes) and `PILOT_MAX_REQUESTS_PER_SECOND`, each min(15 + 5 × `GOMAXPROCS`,
100); keep istiod's resources fixed during such a sweep. No pass records the rest of the Istio CR
either (`meshConfig` but `discoverySelectors`, `global.proxy`), which istiod reloads without a
restart: keep it fixed during a sweep, but for what the profiles change.

The `istiod env` row is each pass's digest of istiod's settings (`ISTIOD_ENV_BY_CONTEXT`, which a
profile's `spec.values.pilot.env` changes on purpose), so you can see that a profile reached
istiod and match a re-run's pass to this one's: one digest when every member ran the same
settings (`(partly unknown)` after it when some were not read), `unknown` when none was read,
`mixed` when the members, the TSVs or a member's istiod pods differ (a rollout caught midway), and
`-` for a pass without data. 001 verifies that its apply reached istiod.

`TEST_PLATFORM` ([the platform record](../../README.md#the-platform-record)) also sets, with
`TUNING_GITOPS_NAMESPACE` empty, the platform of the hub whose Argo CD namespace 006 pauses in;
`TUNING_GITOPS_NAMESPACE` overrides that namespace. 001 and 003 read every member for a profile's
objects or marker before they change anything, and 003 reads every member's record twice per pass
(before and after its probe), each read within `PLATFORM_READ_TIMEOUT`.

## One profile by hand

```bash
./tests/tuning/006-gitops-pause.sh --gitops-context <hub-ctx> --pause
./tests/tuning/001-apply-profile.sh --profile 01-push-throttling --contexts <mesh-a-ctx>,<mesh-b-ctx>
# ... run a suite probe ...
./tests/tuning/002-revert-profile.sh --state-dir tests/tuning/results/state-01-push-throttling
./tests/tuning/006-gitops-pause.sh --resume
```

`006-gitops-pause.sh --gitops-context <hub-ctx> --status` lists the sync windows (`none` when
there are none).

## How apply, revert and the Argo CD pause work

- **001** saves the Istio CR and builds a merge patch that restores the saved value,
  or removes the key, at every path the profile sets. Before it changes anything it
  puts a marker ConfigMap, `istio-system/tuning-profile-<profile>` (labelled
  `istio-scale-tests/tuning-profile=<profile>`), on each member: the profile's name,
  description, when it was applied and that member's revert patch. While a marker or a
  profile's objects are on a member, 001 and 003 refuse to start and the other sweeps
  warn, so a profile that only sets istiod's env shows too. It refuses to overwrite a resource
  that already exists, so it never touches baseline objects, and refuses to start while
  any member holds a profile's objects or marker. A new apply first clears what an earlier
  apply and its revert left in the state dir (`revert-started`, `istio-edited-during-pass`,
  `istio-generations-applied`). After the apply it checks each member (`--skip-verify` skips
  this): the profile's values in the live Istio CR, its `pilot.env` in istiod's `discovery`
  container, its resources and the marker; it exits `2` when the profile applied but a check
  failed.
- **002** applies that patch, deletes the profile's resources, then checks that those
  paths and resources match the pre-apply state. Only when the check passes does it
  delete the markers. On failure it exits 3 and keeps the `active-profile` state and
  the markers, so it can be retried and the sweeps keep refusing to start or warning. With
  `TUNING_REVERT_HEALTHCHECK_NS_PROBE=1` it also checks that istiod still delivers
  `istio-ca-root-cert` to a new namespace.
- **006** adds a deny sync window for the Applications to their AppProject. Resume
  removes it from the context and namespace recorded at pause. `--clear` removes it without
  the record: the window is the same for the same Applications, so it is found by its value.
  Patching an Application's `syncPolicy` would be undone by the ApplicationSet controller.

## After a killed run

If the sweep could not clean up (for example `kill -9` or a lost shell), run:

```bash
./tests/tuning/005-cleanup.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> --gitops-context <hub-ctx>
```

It reverts profiles still marked active, then restores each member's Istio CR from the
markers left on it (newest first: the revert patch, istiod's rollout within
`--rollout-timeout` (`TUNING_ROLLOUT_TIMEOUT`, 300 s by default), a check that the patch took,
then the marker's delete; every member's patch goes out before it waits for any, so their
rollouts overlap; on a member it stops at the first that fails, leaving it in place, and the
cleanup exits non-zero), deletes leftover profile resources (label
`istio-scale-tests/tuning-profile`) and resumes the Argo CD pauses recorded under
`--results-dir` (add it, `DIR`, if the sweep used `--output-dir`). The markers live on the
members, so their restore works from any checkout, even without the sweep's state directory;
the pause record does not. With `--gitops-context` (or `TUNING_GITOPS_CONTEXT`) the cleanup
also removes the deny window a pause adds on that hub, recorded or not
(`006-gitops-pause.sh --clear`); without it, a cleanup that restored markers but found no pause
record warns that Argo CD was not checked, and any cleanup without it ends by saying that the hub
was checked only for the pauses recorded under `--results-dir`: a run killed before its first
profile leaves a pause but no marker. Then run the suite's cleanup. 001 and 003 refuse to
start while a profile is still marked active or any member holds a profile's objects or marker,
and every other suite's sweep warns as it starts (and every report in its body) when a member
does: run 005 then, unless a tuning run is in progress on those members.

`--clear`, and so the cleanup, fails when an AppProject holds a deny window of this tool's
shape for other Applications than the ApplicationSet owns now, all named as it names them
(`*-ossm`: a pause from before a member was added or removed), naming that window's Applications
and its index; nothing removes it by value. A window of that shape for any other Application is
another team's, and is left alone. Remove the stale one by hand:
`./tests/tuning/006-gitops-pause.sh --gitops-context <hub-ctx> --status` prints the Applications,
then each AppProject's sync windows with their index (`<i>` below): the pause of those
Applications (which `--resume` removes with its pause record, and `--clear` without one) on one
line, a stale pause with the window whole on the line under it (`<window>` below), and any
other window as it is:

```bash
kubectl --context <hub-ctx> -n <argocd-namespace> patch appprojects.argoproj.io <project> --type json \
  -p '[{"op":"test","path":"/spec/syncWindows/<i>","value":<window>},
       {"op":"remove","path":"/spec/syncWindows/<i>"}]'
```

The `test` step makes the patch change nothing unless that index still holds that very window
(not one added or removed since `--status`, nor another team's of the same shape). Then run the
cleanup again.

## Adding a profile

A profile's file name, without `.yaml`, is its name: a DNS label (lowercase letters, digits
and `-`) of at most 48 characters, since it labels the profile's objects and names its marker
(`tuning-profile-<name>`), and not `none`, `unknown`, `mixed` or `unlabelled`, the words the
platform record uses for itself, or `baseline`, the name of the sweep's pass without a profile.
001 refuses any other name, and 003 refuses one before its sweep starts, as it does a profile
listed twice in `--profiles` (each pass has its own directory).

A profile YAML has `description`, `ossm_support` (`supported` or `configurable`),
optional `ossm_support_detail`, `istio_cr_patch` (under `spec` only; `pilot.env`
values are quoted strings) and `resources` (DestinationRule, Sidecar, Telemetry or
EnvoyFilter, with names the baseline does not use). It must change something the
baseline does not already set. Skip proxy settings (`meshConfig.defaultConfig`,
`global.proxy`): they only reach pods injected after the change, and the sweep does
not restart workloads.

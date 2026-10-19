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
Without `--profiles` the sweep runs every profile. Other options: `--no-baseline`,
`--skip-setup`, `--keep-workloads`, `--churn-rate N` (see `--help`).

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
It leaves the suite's workloads; remove them with the suite's cleanup script.

## Results

```
tests/tuning/results/sweep-<RUN_ID>/
├── sweep-metadata.txt
├── sweep-comparison.md      # means of valid rows (histogram p99s: worst bucket); % change vs baseline
├── gitops-pause.json        # only while the sweep holds Argo CD paused, or after it was killed
├── baseline/                # suite TSV + .md, probe-output.log, platform-record.txt, platform-drift.txt
└── 01-push-throttling/      # same, plus state/ (patch.json, objects and the revert data)
```

004 reads each pass's TSVs, its `platform-drift.txt` (what the read after its probe found
changed during the pass and could not compare) and, for a profile pass, `state/patch.json` and
`state/objects` (what 001 patched and applied): keep them when you archive a sweep. Without the
drift file 004 warns that the pass was not read again at its end; without the state it cannot
see what the profile sets, and checks the profile against its marker alone, with a warning that
its istiod settings were not checked. `platform-record.txt` hands the record read before a
pass's probe to the probe; `gitops-pause.json` is what 005 resumes a pause from (see "After a
killed run").

`SETUP_FAILED`, `PROBE_FAILED` or `REVERT_FAILED` in a pass directory shows in the
table. Data-plane rows are split by target class (local or remote) and QPS; a row that
missed its target QPS (`QPS_SHORTFALL`) is not valid, and the data-plane servers run
`DATAPLANE_SERVER_REPLICAS` pods per cluster (2 by default). Histogram p99 rows
(convergence, push time) are never averaged: they show the worst bucket range a valid row
hit, or `overflow (N rows)`. Units: memory in Mi, CPU in millicores (the controlplane's
`istiod CPU peak (m)` and `istiod memory peak (Mi)` are window peaks), the sidecar config
in KiB. Re-render:
`./tests/tuning/004-compare-profiles.sh --results-dir <sweep-dir> --format md`.

Each pass reads the platform record live before its probe
([`tests/lib/platform.sh`](../lib/platform.sh): the platform, the mesh operator, istiod and
gateway proxy builds, the nodes' provider, istiod's settings, the tuning profile objects), and
its tuning levers and root Sidecar egress hosts on the source member; the probe's TSVs carry
them, with each member's Kubernetes version and, for the controlplane suite, istiod's limits
(`platform-record.txt` in the pass directory hands the record over). The pass reads them again
after the probe, always, and writes what that read found to the pass's `platform-drift.txt`:
what changed in between (a profile reverted by hand, an Argo CD sync that put istiod's settings
back, a lever, an istiod limit, a control-plane upgrade), the other members whose istiod limits
differ from the source member's, and what it could not compare (a value not read at either
end, or an image whose digest is `@unknown`: no pod had started).

The table's `Platform record` row compares each pass's record, tuning levers, root Sidecar egress
hosts and istiod limits with the baseline's (without a baseline, the first pass with data's,
which reads `reference`; the baseline reads `baseline`): member by member for the builds, the
Kubernetes versions and the limits, lever by lever for the levers. A pass reads:

- `same`;
- `same (see notes)`: only what its profile sets differs, a lever or the egress hosts whose
  object its `state/objects` lists (a root Sidecar of its own, a `tuning-metrics` or
  `tuning-access-log` Telemetry), or `discoverySelectors` or a limit its `state/patch.json` sets
  (also what the reference pass's profile sets, without a baseline); the notes say which;
- `differs (see notes)`;
- `changed (see notes)`: the read after its probe found a build, a Kubernetes version, a tuning
  lever or an istiod limit changed during the pass;
- `mixed (see notes)`: its TSVs disagree;
- `unknown (see notes)`: a value not read or not recorded in one of them (a digest `@unknown`, a
  member's version `unreachable`, a lever `unknown`), or not compared at the pass's end (a value
  the read after its probe could not compare, or no `platform-drift.txt`: that read did not run);
- `-`: no data.

The baseline (or reference) pass reads `baseline (see notes)` when its own values changed during
it, its TSVs disagree or it was not compared at its end, and its warning says that no profile's
change against it is the profile's alone. A member that changed during a pass, or whose TSVs
disagree, matches the other side when one of its values is that side's (the pass's own warning
covers the change), so a pass on a version the baseline ended with reads `same`, and one on a
version the baseline never ran there still `differs`: an upgrade rolling through the members
shows in each pass it reaches. A mesh operator that differs only in its state (`Available`,
`Unavailable`) is the same build. Only the controlplane suite's TSVs record istiod's limits, so
another suite's sweep compares none, and nothing else shows a CPU limit that changes: istiod's
Deployment sets `GOMAXPROCS` from `limits.cpu` by reference (`valueFrom`, so the env digest does
not change with it), and `GOMAXPROCS` sets `PILOT_PUSH_THROTTLE`'s default, min(15 + 5 ×
`GOMAXPROCS`, 100), which profile 01 tunes; keep istiod's resources fixed during such a sweep.

The row leaves out istiod's settings (`ISTIOD_ENV_BY_CONTEXT`) and the profile's objects
(`TUNING_OBJECTS_BY_CONTEXT`), which a profile changes on purpose (`spec.values.pilot.env`, the
objects labelled `istio-scale-tests/tuning-profile`); two rows of their own show them, and both
read `-` for a pass without data. `istiod env` is each pass's digest of istiod's settings, so you
can see that a profile reached istiod and match a re-run's pass to this one's. With a warning, it
reads `by member (see notes)` when the pass's members ran different settings, `mixed (see notes)`
when its TSVs or the read after its probe disagree (the settings changed during the pass),
`unknown (see notes)` when no member's settings could be read, and the digest with `(see notes)`
when a member's could not be read (not known, never other settings), when a member's istiod pods
ran different settings at once (their digests `+`-joined: a rollout caught midway, a pod stuck
Terminating or a second istiod Deployment), or when it contradicts the profile: the baseline's
digest, on a member or one of its pods, though the profile sets `spec.values.pilot.env` (the
pass's `state/patch.json`), or another though it does not patch the Istio CR (a profile that
changes other Istio CR values only is not checked, since some of them reach istiod's env too).
A pass whose `state/patch.json` is gone warns that this was not checked. `Tuning objects` reads
`none` (no profile's objects or marker, as in the baseline), `own` (every object of the pass's
own profile on every member, its marker and its resources as `state/objects` lists them, and no
other), `other (see notes)` (another profile's, or any in the baseline: a profile left applied),
`missing (see notes)` (one of its own is not on a member: the profile was undone during the pass
or never applied there, or the TSVs predate the markers) or `unknown (see notes)` (not read);
all but `none` and `own` warn that the pass did not measure what its name says.

The record follows the table once, digests shortened to 12 hex digits (a value its members do
not share by value, five named), then each pass that differs, changed, is mixed, cannot be
compared or has what its profile sets, with those keys' values: one value when every member
shares it, else only the members that do not match the reference pass, five at most, with a
count (`m7=proxyv2:1.30.6 (1 of 500 members; the other 499 match)`), what changed during it
(`v1.33.1 to v1.33.2 on m7`), what it could not compare at its end, and what its profile sets;
one line for a pass whose every value is unknown, such as one from before the record. A pass that
differs (an operator upgrade, a gateway roll or a lever put back between passes), changed, is
mixed or cannot be compared gets a warning in the notes and on stderr: its change against the
baseline is then not the profile's alone, or not known to be (without a baseline, its difference
from the reference pass is not the profiles' alone).

`TEST_PLATFORM` (`config/options.env`; `auto`, `kubernetes` or `openshift`) sets the platform
instead of asking each cluster, for the probe suite's chart overlay and, with
`TUNING_GITOPS_NAMESPACE` empty, for the hub whose Argo CD namespace 006 pauses in;
`TUNING_GITOPS_NAMESPACE` overrides that namespace. The platform record still asks each member
what it serves, and warns when that is not `TEST_PLATFORM`. 001 and 003 also read every member
before they change anything (a profile's objects or marker), and 003 reads every member's record
twice per pass (before and after its probe): each read is bounded by
`PLATFORM_READ_TIMEOUT` (20 s by default) and `PLATFORM_READ_PARALLEL` members (20) are read at
once, so raise the first for slow API servers and lower the second on a small runner.

## One profile by hand

```bash
./tests/tuning/006-gitops-pause.sh --gitops-context <hub-ctx> --pause
./tests/tuning/001-apply-profile.sh --profile 01-push-throttling --contexts <mesh-a-ctx>,<mesh-b-ctx>
# ... run a suite probe ...
./tests/tuning/002-revert-profile.sh --state-dir tests/tuning/results/state-01-push-throttling
./tests/tuning/006-gitops-pause.sh --resume
```

`006-gitops-pause.sh --gitops-context <hub-ctx> --status` lists the sync windows.

## How apply, revert and the Argo CD pause work

- **001** saves the Istio CR and builds a merge patch that restores the saved value,
  or removes the key, at every path the profile sets. Before it changes anything it
  puts a marker ConfigMap, `istio-system/tuning-profile-<profile>` (labelled
  `istio-scale-tests/tuning-profile=<profile>`), on each member: the profile's name,
  description, when it was applied and that member's revert patch. Every platform
  record lists the marker with the profile's objects (`TUNING_OBJECTS_BY_CONTEXT`), so
  a profile that only sets istiod's env shows too. It refuses to overwrite a resource
  that already exists, so it never touches baseline objects, and refuses to start while
  any member holds a profile's objects or marker.
- **002** applies that patch, deletes the profile's resources, then checks that those
  paths and resources match the pre-apply state. Only when the check passes does it
  delete the markers. On failure it exits 3 and keeps the `active-profile` state and
  the markers, so it can be retried and every record and sweep keeps warning. With
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
`./tests/tuning/006-gitops-pause.sh --gitops-context <hub-ctx> --status` prints the Applications
and each AppProject's sync windows with their index (`<i>` below) and marks those of this
tool's shape for `*-ossm` Applications:

```bash
kubectl --context <hub-ctx> -n <argocd-namespace> patch appprojects.argoproj.io <project> --type json \
  -p '[{"op":"test","path":"/spec/syncWindows/<i>/kind","value":"deny"},
       {"op":"test","path":"/spec/syncWindows/<i>/schedule","value":"* * * * *"},
       {"op":"remove","path":"/spec/syncWindows/<i>"}]'
```

The `test` steps make the patch change nothing when that index holds another window (one added
or removed since `--status`). Then run the cleanup again.

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

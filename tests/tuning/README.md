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
check with a note). After the last revert the sweep reads each member's Istio version and active
revision again (a change is a problem), and compares its Istio CR `spec` with the sweep's start:
a difference (an incomplete revert, or an edit no revert undid, since they restore only the
profiles' keys) is a problem naming the differing paths, with both specs in `istio-spec/`.

Exit codes: `0` every pass ran its probe; `1` the sweep stopped (a bad flag or precondition, also
another live run that holds the sweep dir's `.sweep.lock`; a failed suite setup, a failed
revert, or an unexpected error); `4` it finished, reverted every profile and wrote
`sweep-comparison.md`, but some passes failed (`SETUP_FAILED`: the profile did not apply;
`PROBE_FAILED`: the probe exited non-zero, including a reachability stop), or the mesh changed
under it: the Istio version or active revision changed during the sweep, the Istio CR changed
during a pass (above), or the last revert left the Istio CR's spec unlike the start; or its
harness (`HARNESS_SHA`) changed during the sweep (read at its start and its end). Each is an
`error:` line on stderr; the failed passes' line says how many, by reason. `sweep-outcome.txt` keeps the outcome
(`STATUS=running` until the sweep ends, then `finished`, `stopped` or `interrupted`), and
`sweep-comparison.md` repeats it. When a sweep did not finish and no sweep runs any more, check
that no profile is still applied (`005-cleanup.sh`) and that Argo CD auto-sync is resumed
(`006-gitops-pause.sh --resume`), then run the sweep again into a new dir. `130` / `143` / `129`:
interrupted (Ctrl-C, SIGTERM, SIGHUP), after reverting the active profile; `sweep-outcome.txt`
then says when and by which signal, with the problems found until then.

## Results

```
tests/tuning/results/sweep-<RUN_ID>/
├── sweep-metadata.txt       # suite, passes, HARNESS_SHA, ISTIO_VERSION (read live once; every
│                            # probe records it), the pin, each member's revision and generations
├── sweep-comparison.md      # means of valid rows with n and range (histogram p99s: worst bucket); % change vs baseline
├── gitops-pause.json        # only while the sweep holds Argo CD paused, or after it was killed
├── istio-spec/              # each member's Istio CR spec at the start and after the last revert (start-<ctx>.json, end-<ctx>.json)
├── baseline/                # suite TSV + .md, probe-output.log, platform-record.txt, platform-drift.txt
└── 01-push-throttling/      # same, plus state/ (patch.json, objects, the revert data and istio-generations-applied)
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
table's `Pass status` row (`ok` otherwise), and so does `no data`: a pass without TSVs (one the
metadata lists without its directory, or whose probe wrote none). Data-plane rows are split by
target class (local or remote) and QPS; a row that missed its target QPS (`QPS_SHORTFALL`) is
not valid, and the data-plane servers run `DATAPLANE_SERVER_REPLICAS` pods per cluster (2 by
default). Histogram p99 rows (convergence, push time) are never averaged: they show the worst
bucket range a valid row hit, or `overflow (N rows)` when N rows had their p99 in the +Inf
bucket; propagation's P1 convergence counts iterations instead, `overflow (N iterations)`: N
iterations put a sample in the +Inf bucket (counted, although propagation 005 leaves them out of
its means). The `P1 local push` cell adds `(N overflowed)` for the iterations its mean leaves
out for that overflow (`- (N overflowed)` when every one did); P1 is left out of an iteration
only for a source-side reason, as in 005 (a remote that timed out or restarted keeps it). Units:
memory in Mi, CPU in millicores (the controlplane's `istiod CPU peak (m)` and `istiod memory
peak (Mi)` are window peaks), the sidecar config in KiB. Under each metric, `n (got/attempted)`
counts the valid samples with a value over what the pass's probe was configured to take, where
its TSV records it (propagation: iterations for P1 and its convergence, iterations x remotes for
P2 and P3; churn: iterations), else over every row the pass wrote (failed and timed-out rows
included); `range` gives its min to max. "TSV columns" gives the data rows' column count, per
pass when the passes differ, with a warning: their rows were written by different harness
versions. It reads `none (no pass wrote a TSV)` when no pass wrote one, and `none (no pass's TSV
has a data row)` when none has a row. The `Istio CR / IstioRevision generations` row gives each
pass's `ISTIO_GENERATIONS` from its own TSVs: a profile's apply and revert raise them, so each
pass ran on its own (`2/2 (every member)` when every member has one value; `mixed:...` when the
pass's TSVs disagree, `unknown` for a TSV without the key, `-` for a pass without a TSV). The
"Harness (HARNESS_SHA)" row gives each pass's `HARNESS_SHA` from its own TSVs: passes on
different harnesses get a WARNING (a profile's change may come from the harness). A propagation
comparison counts a `DRAIN_TIMEOUT` side, as 005 does (measured before that drain), and adds a
"Drain timeouts (iterations, counted)" row when a pass has one. The markdown starts with a YAML
frontmatter of these keys (`suite`, `run_id`, `contexts`, `passes`, the `istio_*` keys,
`harness_sha`, `tsv_columns`). A profile whose n differs from the baseline's shows `(baseline n ...)` and the
page warns: its mean comes from other iterations, so a profile that timed out on the slow ones
can look faster than it is. Re-render:
`./tests/tuning/004-compare-profiles.sh --results-dir <sweep-dir> --format md`.

Each pass reads the platform record live before its probe
([`tests/lib/platform.sh`](../lib/platform.sh): the platform, the mesh operator, istiod and
gateway proxy builds, the nodes' provider, istiod's settings, the tuning profile objects), and
its tuning levers and root Sidecar egress hosts on the source member; the probe's TSVs carry
them, with each member's Kubernetes version, for the controlplane suite istiod's limits, and
istiod's replica counts at the probe's start as the suite records them (controlplane: each
member's Deployment replicas; propagation and churn: each member's Running istiod pods;
churn-dataplane: the source member's; dataplane: none). `platform-record.txt` in the pass
directory hands the record over. The pass reads them again after the probe, always, and writes
what that read found to the pass's `platform-drift.txt`: what changed in between (a profile
reverted by hand, an Argo CD sync that put istiod's settings back, a lever, an istiod limit, a
member's istiod replica count, a control-plane upgrade), the other members' istiod limits where
they differ from the source member's, and what it could not compare (a value not read at either
end, or an image whose digest is `@unknown`: no pod had started). Nothing records the other
members' limits at a pass's start, so theirs are their limits at its end: a change there during
a pass reads as a difference from that pass on, not as a change during it, and one undone before
the pass ends is not seen. That read compares each member's istiod replica count with the one its
TSVs record, counted as they count it (controlplane: the Deployment's replicas; the others:
Running istiod pods): a pass whose profile turns autoscaling on is said to have its HPA move them,
and when they read the same at its end on every member, it has a note that the HPA may have raised
and lowered them in between (`same (see notes)` when nothing else differs), which says where a
row shows what it ran with: in a controlplane pass, each cell's own count of istiod pods,
`istiod_pods_avg` in `tests/controlplane/004-report-results.sh --results-dir <pass dir> --format
csv`; in the other suites, a row whose window saw istiod's pods change counts it as an istiod
restart. Where its TSVs do not record each member's count (churn-dataplane's remotes, every member
in dataplane), such a pass reads `unknown (see notes)` and warns that whether its HPA held the
count all through the pass is not known. A controlplane window whose Running istiod pods changed
also writes its `cluster_connected_proxies` as `N/A`.

The table's `Platform record` row compares each pass's record and the values its TSVs record
outside it with the baseline's (without a baseline, the first pass with data's, which reads
`reference`; the baseline reads `baseline`): member by member for the builds, the Kubernetes
versions, istiod's limits and replica counts, lever by lever for the levers. Those values are
`TUNING_BASELINE` (each lever `on` or `off`), `SIDECAR_EGRESS_HOSTS` (the root Sidecar's),
`ISTIOD_CPU_LIMIT_M_BY_CONTEXT` (millicores), `ISTIOD_MEM_LIMIT_MI_BY_CONTEXT` (Mi) and
`ISTIOD_REPLICAS_BY_CONTEXT`. A pass reads:

- `same`;
- `same (see notes)`: only what its profile sets differs (a lever or the egress hosts whose
  object its `state/objects` lists: a root Sidecar of its own, a `tuning-metrics` or
  `tuning-access-log` Telemetry; or `discoverySelectors`, a limit or the replica count its
  `state/patch.json` sets; without a baseline, also what the reference pass's profile sets), or
  it ran one of the values the reference pass ran more than one of (one that changed during that
  pass, or that its TSVs disagree on), or its profile turns autoscaling on and the read at its
  end found each member's replica count it started with; the notes say which;
- `differs (see notes)`;
- `not in effect (see notes)`: a member did not run a limit or the replica count that its
  `state/patch.json` sets to one value (not rolled out there; a limit or a count that changed
  during the pass, a count its TSVs disagree on or an HPA set, or a Terminating pod still
  counted as Running after a short `--settle`: the suites other than controlplane count
  Running istiod pods; a patch that turns autoscaling on is not checked against its
  `replicaCount`);
- `changed (see notes)`: the read after its probe found a build, a Kubernetes version, a tuning
  lever, an istiod limit or a member's istiod replica count changed during the pass;
- `mixed (see notes)`: its TSVs disagree;
- `unknown (see notes)`: a value not read or not recorded in one of them (a digest `@unknown`, a
  member's version `unreachable`, a lever `unknown`), a limit or replica count its profile sets
  that its TSVs do not record on a member, a replica count its profile's HPA sets (autoscaling
  on) where its TSVs do not record each member's count (churn-dataplane's remotes, dataplane), or
  not compared at the pass's end (a value the read after its probe could not compare, or no
  `platform-drift.txt`: that read did not run);
- `-`: no data.

The baseline pass reads `baseline (see notes)` (a reference pass `reference (see notes)`) when its
own values changed during it, its TSVs disagree, it was not compared at its end or (a reference
pass) its profile's value was not in effect or is not known to be, and its warning says that no
profile's change against it is the profile's alone, or, when it was not compared at its end, that
none is known to be. A reference pass whose one note is its profile's HPA (the counts it started
with held to its end on every member) reads `reference (see notes)` and does not warn, as
`same (see notes)` does not. A member that changed during a pass, or whose TSVs disagree, matches
the other side when one of its values is that side's (the pass's own warning covers the change), so
a pass on a version the baseline ended with reads `same (see notes)`, its notes naming that
version, and one on a version the baseline never ran there still `differs`: an upgrade rolling
through the members shows in each pass it reaches. A mesh operator that differs only in its state
(`Available`, `Unavailable`) is the same build.

Only the controlplane suite's TSVs record istiod's limits, and the dataplane suite's record no
replica count, so those sweeps compare none of them, and a pass whose profile sets one reads
`unknown (see notes)` and warns that whether it was in effect is not known; so does one whose
profile sets the replica count in a churn-dataplane sweep, which records the source member's
only, for every other member. Nothing else shows a CPU limit that changes: istiod's
Deployment sets `GOMAXPROCS` from `limits.cpu` by reference (`valueFrom`, so the env digest does
not change with it), and `GOMAXPROCS` sets the defaults of `PILOT_PUSH_THROTTLE` (which profile
01 tunes) and `PILOT_MAX_REQUESTS_PER_SECOND`, each min(15 + 5 × `GOMAXPROCS`, 100); keep
istiod's resources fixed during such a sweep. No pass records the rest of the Istio CR either
(`meshConfig` but `discoverySelectors`, `global.proxy`), which istiod reloads without a restart:
keep it fixed during a sweep, but for what the profiles change.

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

The record follows the table once, digests shortened to 12 hex digits (a value its members do not
share by value, five named, as is one that names fewer members than the record: churn-dataplane's
replica counts), then each pass with notes, with those keys' values: where it differs, is mixed or
cannot be compared, the one value every member shares when all of them differ, else the members
that differ from the reference pass, then those not read or not recorded on a side (`m2=unknown`),
then those that ran more than one value (`m3=mixed: 1 and 2`), five at most, with a count
(`m7=proxyv2:1.30.6 (1 of 500 members; the other 499 match)`); what changed during it (`v1.33.1 to
v1.33.2 on m7`); what it could not compare at its end; what its profile sets; the members that did
not run the profile's value; and which value it ran where the reference pass ran more than one. One
line stands for a pass whose every value is unknown, such as one from before the record. A pass
that differs (an operator upgrade, a gateway roll or a lever put back between passes), whose
profile's value was not in effect, that changed, is mixed or cannot be compared gets a warning in
the notes and on stderr: its change against the baseline is then not the profile's alone, or not
known to be (without a baseline, its difference from the reference pass is not the profiles'
alone). The passes not read again at their end share one warning.

`TEST_PLATFORM` (`config/options.env`; `auto`, `kubernetes` or `openshift`) sets the platform
instead of asking each cluster, for the probe suite's chart overlay and, with
`TUNING_GITOPS_NAMESPACE` empty, for the hub whose Argo CD namespace 006 pauses in;
`TUNING_GITOPS_NAMESPACE` overrides that namespace. The platform record still asks each member
what it serves, and warns when that is not `TEST_PLATFORM`. 001 and 003 also read every member
before they change anything (a profile's objects or marker), and 003 reads every member's record
twice per pass (before and after its probe): each read is bounded by `PLATFORM_READ_TIMEOUT`
(20 s by default) and `PLATFORM_READ_PARALLEL` members (20) are read at once, so raise the first
for slow API servers and lower the second on a small runner. The read after the probe also reads
the levers, each member's istiod limits and Kubernetes version, each bounded by 5 s as the
probes' own reads are and asked once more when it comes back unknown; what still does not answer
is not compared at the pass's end.

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

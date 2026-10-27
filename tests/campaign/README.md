# Campaign runner

**Question:** none of its own. It runs the suites one after another, unattended, from one
profile per environment, so a whole campaign is one command.

**At a glance:** `001-run-profile.sh --profile <name>` runs the preflight check (with `--echo`),
then each suite of the profile in its order. Each suite gets the profile's `<suite>.env` as its
`--config`. Before each later suite the preflight runs again without the echo. A failed suite
is recorded and the next one starts. A failed preflight stops the run, because every suite
after it would measure a broken mesh. Past the profile's deadline no suite starts, and the
running one is stopped: its sweep cleans up and records itself as interrupted. Not a suite:
it has no chart and measures nothing itself.

## Profiles

| Profile | Environment | Members | Suites, in order | Time |
| --- | --- | --- | --- | --- |
| `kind` | [kind lab](../../docs/runbooks/kind-lab/README.md), one machine | 2 | dataplane, propagation, churn, churn-dataplane, controlplane (a small cell matrix), tuning | about 1.5 h, mostly tuning's settle time |
| `openshift` | [existing OpenShift clusters](../../docs/runbooks/existing-cluster-lab/README.md), a small lab | 2 | the same, tuning before controlplane's namespace scaling at lab size (100 to 400 namespaces) | about 4-5 h |
| `rosa` | [ROSA HCP](../../docs/runbooks/rosa-validation/README.md), a night | 4 | the same, namespace scaling at customer size (250 to 4000 namespaces); deadline 510 min | about 8.5 h, cut by the deadline |

Times are estimates from the suites' own figures; the report records the real ones.

A profile is a directory: `profile.env` holds the runner's keys (`CAMPAIGN_*`, described in
[config/options.env](../../config/options.env)), and `<suite>.env` is that suite's run config
([Run config](../../docs/reference.md#run-config---config-file)). Every sweep's mesh sizes are
left empty, so each grows the mesh from 1 member to all the members you pass. Namespace scaling
runs last on OpenShift and ROSA: it leaves its namespaces undiscovered but not deleted
(deleting thousands takes hours there), on the first member.

The profiles hold no context names. To change a profile for one run, copy its directory to
`profiles/<name>.local/` (ignored by git), edit it and pass `--profile <name>.local`.

## Run it

```bash
export SETUP_CONTEXTS=<mesh-a-ctx>,<mesh-b-ctx>          # the members, never the hub
tests/campaign/001-run-profile.sh --profile kind --hub-context <hub-ctx> --dry-run
tests/campaign/001-run-profile.sh --profile kind --hub-context <hub-ctx>
```

`--dry-run` checks the profile and every run config, prints the plan, and runs each sweep's own
`--dry-run`. Run it before an unattended night: a typo in a run config stops the real run before
any cluster call too, but then you are not there to see it.

`--suites dataplane,churn` runs only those of the profile's suites. `--deadline-min N` overrides
the profile's deadline.

**ROSA:** the deadline stops the tests, not the billing. Arm the teardown timer separately
(`terraform/rosa-hcp/scripts/003-auto-teardown.sh --arm`, [window plan](../../docs/runbooks/rosa-validation/window-plan.md)),
set after the deadline, and copy the results off the machine before the teardown. The machine
that runs the campaign must stay awake all night (no sleep, no update restart).

## Results

`tests/campaign/results/<profile>-<RUN_ID>/` (ignored by git):

| File | What it holds |
| --- | --- |
| `campaign-<RUN_ID>.md` | The run (profile, members, harness, deadline, outcome), a row per suite (status, exit, start, minutes, sweep dir), then each sweep's own outcome |
| `<suite>/sweep-<RUN_ID>/` | The suite's results and its report, as when it runs alone |
| `<suite>/console.log` | The suite's console output; a stopped suite names its cleanup command here |
| `preflight-*.log` | Each preflight check |
| `suites.tsv`, `sweep-outcome.txt` | The rows of the table; the run's own outcome record |
| `profile/` | The profile as run |

A suite's status: `OK`, `FAILED_CELLS` (it finished, some cells failed: its report says which),
`UNREACHABLE` (its reachability gate stopped it), `STOPPED` (a precondition or an error),
`STOPPED_AT_DEADLINE`, `SKIPPED_DEADLINE` (not started), `NOT_RUN` (a preflight failed first).

Exit codes: 0 every suite ran clean; 1 stopped (a bad flag or profile, a failed preflight, an
error); 4 a suite did not end `OK`, or the deadline skipped one; 129, 130, 143 a signal (the
running sweep is stopped and cleans up first).

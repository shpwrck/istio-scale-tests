# Result examples: good and bad

What good and bad results look like for each suite, so you can tell at a glance whether a run
found something, or whether the run itself went wrong.

A result can be bad in two ways, and the difference matters:

- **The mesh behaved badly.** The run was clean, and the numbers show a real problem: a slow
  path, a member that cannot be reached, a component near its limit. That is a finding. Report
  it, with the run's folder.
- **The run went wrong.** The numbers cannot be trusted: too few valid samples, a broken step,
  a load the cluster could not generate. That is not a finding. Fix the cause and run again.

Most examples are excerpts from recorded runs in [docs/campaigns](campaigns/README.md). Those
records were written by older versions of the harness, so a column name can differ slightly
from today's report, and each record's erratum still applies. Examples marked **illustrative**
show the shape of a problem with invented numbers; no recorded run had it.

Before any of these, [Reading results](reading-results.md) lists the five checks every run must
pass.

## Before any suite: the wiring gate

**Good.** Every member reads Ready, with the same `root=` everywhere:

```
mesh-a: Ready: secrets=2 ... members=mesh-a,mesh-b ca=shared synced=1 replicas=3 root=3f9a0c1e5b7d2a46 eastwest=<address>
mesh-b: Ready: secrets=2 ... members=mesh-a,mesh-b ca=shared synced=1 replicas=3 root=3f9a0c1e5b7d2a46 eastwest=<address>
```

**Bad (real, existing-cluster lab, 2026-10-13).** istiod started before its CA certificate
(`cacerts`) arrived, so it signed with a CA of its own and the other members do not trust it.
Cross-cluster calls to that member fail, while every in-cluster number still looks fine:

```
NotReady: istiod is not using the shared mesh root ...
```

Do not run any suite until it is fixed (README, Troubleshooting). `tests/preflight/001-check-mesh.sh`
catches both this and members whose `root=` differs.

## Propagation

**Good (real, 10-member ROSA mesh, 2026-06-04).** Excerpt of the comparison across mesh sizes:

| Mesh Size | P1 wall avg (ms) | P2 EDS avg (ms) | P3 sidecar avg (ms) |
| --- | --- | --- | --- |
| 1 | 2038 (10) | -- (0) | -- (0) |
| 2 | 1965 (10) | 1969 (10) | 25860 (10) |
| 5 | 2004 (40) | 2027 (40) | 20257 (40) |
| 10 | 2079 (90) | 2106 (90) | 18071 (90) |

What to notice:
- Every count in brackets is the full number of samples: no row was dropped.
- P1 (the source's istiod) and P2 (each remote istiod) stay at about 2 s from 1 to 10 members:
  the control planes do not slow down as the mesh grows.
- Mesh size 1 has no P2 or P3: there is no remote. `--` with `(0)` is expected there.
- P3 (a remote proxy reports the endpoint healthy) is much slower, about 20 s, with a p99 of 46
  to 83 s in the per-size tables. That is not a broken run: it is a real finding, and that
  record calls it the dominant scaling signal.

**Bad mesh (illustrative).** P2 grows with every member added:

| Mesh Size | P1 wall avg (ms) | P2 EDS avg (ms) | P3 sidecar avg (ms) |
| --- | --- | --- | --- |
| 2 | 2010 (10) | 2050 (10) | 3900 (10) |
| 4 | 2040 (10) | 5800 (30) | 8100 (30) |
| 8 | 2020 (10) | 14900 (68) | 17300 (68) |

P1 is flat, so the source is fine; the remote control planes take longer to learn each change
as the mesh grows. Look at the remote istiods' CPU (the controlplane suite) and at their logs
for slow or repeated syncs of the other members. The `(68)` against 70 expected also shows two
remote rows timed out: the per-size table names their status.

**Bad run (illustrative).** One mesh size kept 3 of 10 samples:

```
| P2 remote istiod EDS | 10 | 3 | 1998 | 2107 | 2051 | 2044 | N/A | N/A |
WARNING: mesh_size=2: SCRAPE_INCOMPLETE=7 ...
```

Seven iterations could not read istiod's metrics in time, so the average rests on 3 samples and
p95/p99 read `N/A`. Raise `METRICS_SCRAPE_TIMEOUT` (or `FANOUT_MAX_SKEW_MS` when the warning is
about skew) and run again.

## Churn

**Good (real, 10-member ROSA mesh, 2026-06-04).** Excerpt, 5 Deployments scaled 1 to 5:

| mesh | n_valid / n_total | local_avg (ms) | remote_reach_avg (ms) | remote_eds_avg (ms) | rmt_proxies | amplification |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 5 / 5 | 2442 | N/A | N/A | 0 | 0.1 |
| 2 | 5 / 5 | 2558 | 7817 | 2989 | 28 | 0.5 |
| 5 | 5 / 5 | 3101 | 9629 | 4849 | 96 | 0.4 |
| 10 | 5 / 5 | 3682 | 11154 | 3913 | 216 | 0.3 |

What to notice:
- Every iteration valid. Local convergence grows slowly (2.4 to 3.7 s) while remote proxies grow
  from 28 to 216.
- Remote reach levels off at about 10 to 12 s instead of growing with the mesh.
- Push amplification stays at or below about 1: one change does not set off a storm of pushes.
  It grows with connected proxies, so compare it across mesh sizes, not against a fixed number.

**Bad mesh (illustrative).** Amplification and remote pushes climb much faster than the
proxies do (for example amplification 1.2, 4.8, 19.5 at mesh sizes 2, 4, 8), or remote reach
grows in step with mesh size. Either means each change costs more the bigger the mesh gets.
Rows reading `TIMEOUT_REMOTE` mean some remotes never saw the new pods within `--timeout`.

**Bad run (real, 20-member ROSA run, 2026-06-22).** A harness bug (an arithmetic error on an
empty count) capped the first churn run at `n_valid=1`. One sample is not an average: the record
re-ran it after the fix. Whenever `n_valid` is far below `n_total`, read the status counts
before the numbers.

## Controlplane

**Good (real, 10-member ROSA mesh, 2026-06-04).** Excerpt, 10 services × 3 replicas per member;
the CPU column is a per-window peak (that record's erratum):

| mesh_size | scoping | n_total | n_valid | cpu (m) | mem (Mi) | conv_p99 (ms) | cfg_dump_avg (MiB) | restarts |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | none | 3 | 3 | 139 | 354 | 100-500 | 3.8 | 0 |
| 1 | namespace | 3 | 3 | 95 | 329 | 0-100 | 0.4 | 0 |
| 10 | none | 30 | 30 | 402 | 354 | 100-500 | 3.9 | 0 |
| 10 | namespace | 30 | 30 | 310 | 340 | 0-100 | 0.5 | 0 |

What to notice:
- `Sidecar` scoping does what it should: each proxy's configuration drops from 3.8 MiB to 0.4
  MiB (about 89% less), and changes reach the proxies faster (0-100 ms instead of 100-500 ms).
- Memory stays flat and CPU grows moderately with mesh size; no istiod restarted.

**But not a scale result.** The same report said
`SCALE_COVERAGE: UNDER (achieved 136/750 pods = 0.181 < min 0.25)`: the cluster was barely
loaded. A flat, healthy istiod at 18% of the cluster's pod capacity says nothing about how it
behaves near capacity. Treat `UNDER` as "the shape is real, the headroom is unproven".

**Bad mesh (real, ROSA, 2026-10-14).** At thousands of Services the east-west gateway, not
istiod, ran out of room. The memory guard skipped cells it projected over its limit
(`SKIPPED_MEM_GUARD`), and the gateway's working set reached 2.2 to 2.5 GiB after bursts of
changes, against the 1 GiB limit it then had. The finding: size the east-west gateway's memory
for the Service count (the chart's limit was raised to 5 GiB as a result).

**Bad mesh (illustrative).** `cfg_dump_avg` reads about the same for `none` and `namespace`
scoping: the `Sidecar` resource is not applied, so proxies still carry the whole mesh. Check
that the test namespace is in the Sidecar's egress hosts and has the `istio-discovery=enabled`
label.

**Bad run (real, 20-member ROSA run, 2026-06-22).** The report said PASS with istiod at 3% of
its CPU limit. Later work found the figure was one `kubectl top` snapshot at the end of each
window, which misses bursts, and the east-west gateways' memory was never measured. The verdict
is now marked unconfirmed in that record. A PASS is only as good as what was measured: check the
report's data warnings and that the cells reached the scale you meant to test.

## Dataplane

**Good (real, 3-member ROSA mesh, 2026-10-14).** Both remotes reachable 10/10, local baseline OK
at every level:

| QPS | Local p50 / p99 (ms) | Remote p50 / p99 (ms) | Achieved QPS | HTTP 200 |
| --- | --- | --- | --- | --- |
| 10 | 2.35 / 3.72 | 3.80 / 5.27 | 10.0 | 100% |
| 100 | 1.54 / 2.89 | 3.53 / 5.16 | 100.0 | 100% |
| 500 | 1.50 / 2.73 | 3.23 / 4.36 | 499.9-500.0 | 100% |
| 1000 | 1.47 / 2.00 | 2.54 / 3.96 | 999.9 | 100% |

What to notice:
- Every request answered with 200, and the achieved rate matches the target at every level.
- The cross-cluster hop adds about 1 to 2 ms at p50 and stays in the single digits at p99.
- The local baseline is valid, so the remote-minus-local comparison means something.

**Bad mesh (real, 20-member ROSA run, 2026-06-22).** Only 12 of 19 remote members took load in
both runs: the other 7 failed the cross-cluster check, although their istiods reported every
member synced and their gateways looked healthy. Traffic through those members' east-west
gateways did not get through. The latency table only covers the 12 that worked, so the run's
"Remote coverage" section, not the latency, is the headline: 7 members were cut off.

**Bad run (real, same run).** At 1000 QPS the local baseline answered only about 686 requests per
second with errors, because the test ran a single server pod and it saturated. The current
report flags such a cell like this:

```
Local baseline: DROPPED mesh_size=2 qps_target=1000 n_valid=0/1 reason=saturated qps_actual=686.2 (68.6% of target) server_replicas=1/1 ...
```

With no valid local row at that rate there is nothing to compare the remote numbers against.
That is the server's limit, not the mesh's: run more server replicas (the default is now 2,
`DATAPLANE_SERVER_REPLICAS`) or drop that rate.

## Churn-dataplane

**Good (real, 20-member ROSA run, 2026-06-22).** At 10 scale operations per second, 600 of 600
operations succeeded and p50 moved from 2.82 to 2.99 ms: `Δp99 = +1.72 ms`, no istiod restart.
Churn barely affects requests. (That record's erratum: its churn rates may be overstated.)

**A real effect (real, 10-member ROSA mesh, 2026-06-04).** p99 rose from 3 to 8 ms without churn
to 17 to 25 ms under churn, a `Δp99` of 11 to 21 ms. Small in absolute terms, but the tail grew
several times over. That is worth reporting with the churn rates that caused
it. A `Δp99` whose spread (stdev) is as large as its mean is noise: run more repetitions.

**Bad run (real, 2026-06-04).** The first sweep recorded `SETUP_FAILED` for every combination
at mesh sizes 2, 4 and 6 (the previous size's namespace was still being deleted), stopped at
size 7 and wrote no summary. Discarded and re-run after a fix. A pattern of whole mesh sizes
failing points at the harness or the cluster, never at the mesh.

**Bad run (real, 2026-06-22).** Of three churn rates, only one produced a valid pair of windows:
the others had a `FAILED` baseline, because the cross-cluster problem above leaked into the load.
One valid pair answers the question for one rate only; check `valid_runs` against `total_runs`
for every row before comparing rates.

## Tuning

**Good (illustrative).** The baseline and the profile each have every pass `ok`, and the change
is larger than the spread of the baseline itself:

| Metric | baseline | 02-xds-cache-off |
| --- | --- | --- |
| Pass status | ok | ok |
| P1 local push (ms) | 2051, n 10/10, range 1990-2110 | 2690 (+31.2%), n 10/10, range 2580-2810 |

The ranges do not overlap: with the caches off, istiod pushes more slowly. A clear result,
whichever direction it goes.

**Bad (illustrative).** A change of a few percent inside the baseline's own range (for example
-4% with ranges 1990-2110 and 1950-2090) is noise, not an effect. A `Pass status` of
`REVERT_FAILED` means the profile may still be applied: run `tests/tuning/005-cleanup.sh`
before anything else.

## One-off: the Gateway API check

Not a scale suite: a one-off check of one yes/no question ([README](../tests/gateway-api/README.md)).

**Good (real, existing-cluster lab 2026-10-14, and kind 2026-10-18).** 22 of 22 scenarios read
`MATCH`: every route behaved as predicted, and both answers are definite (`NO` or `YES`).

**Bad (illustrative).** An answer reads `INCONCLUSIVE` with a route status like
`STATUS_TIMEOUT` or `STATUS_PENDING`: the routes had not settled when the traffic ran. Wait
until Argo CD shows the check's Applications synced and run it again. A row that reads anything
other than `MATCH` on a settled run is a real difference from the prediction: that is the
finding to report, with the Istio version.

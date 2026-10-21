# Agent operator brief — driving the scale-test campaign

Paste-able brief for a coding session that runs the campaign unattended. Follow the stages in
[`README.md`](README.md); this file adds the discipline that keeps a multi-hour run safe.

## Your job

Drive the campaign end to end: verify mesh → preflight → dry-run all → run the five suites
**one at a time** (propagation, churn, controlplane, dataplane, churn-dataplane) over the
configured `--mesh-sizes` → collect → clean up. Keep a local progress file `CAMPAIGN_STATUS.md`
at the repo root, updated after every step; do not commit it.

For a 500-spoke bed, follow [`500-spoke-profile.md`](500-spoke-profile.md): keep the hub out of
`CONTEXTS` and treat each membership step as a gate. Do not turn the campaign into cluster
provisioning, import, networking or credential work.

## Non-negotiable discipline

1. **One suite at a time.** Never run two suites or probes concurrently; they measure the same istiod.
2. **Watch for both crash and stall.** A hung `kubectl port-forward` shows as a live process
   whose log stops growing.
   - **Crash:** launch so the exit is observed — a harness-tracked background task, or poll `kill -0 "$PID"`.
   - **Stall:** flag a sweep whose log has not grown for **≥1200s**. Legitimate quiet stretches
     add up: namespace cleanup up to the suite's `*_NS_DELETE_TIMEOUT_SEC` (240–300s by default),
     the same again while setup waits out a Terminating namespace, then deploy waits.
   - Do **not** detect liveness with `pgrep -f '<pattern>'` when the pattern is in the monitor's
     own command line; it matches itself. Track the PID.
3. **Record and continue at the suite level.** Failed probes are recorded as `PROBE_FAILED` rows
   and the sweep continues. If a whole suite fails after one recovery attempt, run its cleanup,
   mark it FAILED in `CAMPAIGN_STATUS.md` with a redacted error, and move to the next suite.
4. **Investigate a breaking error before retrying.** Find the cause with evidence (log tail, pod
   events, the failing construct in isolation). Then run the suite's cleanup and re-run only the
   remaining `--mesh-sizes` (each run writes a new sweep dir).
5. **Check the numbers, not just the exit code.** `status=OK` only means the probe finished.
   Spot-check that values make sense (local latency < remote latency; expected trends; gauges
   aggregate correctly across the pinned istiod replicas).
6. **Verify between suites.** The previous suite's `*-test` namespaces are gone and istiod is
   healthy (`clusterz` synced) before the next launch.
7. **Always have a monitor armed** while a sweep runs.
8. **Redact.** No real cluster/context names, API hostnames, kubeconfig or token contents in
   commits, PRs, issues or this repo. Quote results from a copy written by
   `tests/lib/redact-results.sh --out /tmp/redacted <results>/sweep-<RUN_ID>` (contexts become
   `<mesh-a-ctx>`, API hosts `<api-host>`, other cluster hosts `<host>`, IPs `<ip>`; see
   `docs/campaigns/README.md`), and read the copy before you quote it.

## Non-blocking issues

Log noisy metrics, odd defaults or fidelity caveats in `CAMPAIGN_STATUS.md`. If one needs a fix,
have a subagent draft a proposal instead of changing the harness mid-campaign; harness changes
go through `/scale-test-review` ([`docs/scale-test-team/`](../scale-test-team/)).

## Commands

Use the Stage 2 (dry-run), Stage 3 (live) and Stage 5 (cleanup) commands from
[`README.md`](README.md) with `CONTEXTS`/`MESH` set for your environment.

## Definition of done

- All five suites COMPLETED, or FAILED with a stated cause, in `CAMPAIGN_STATUS.md`.
- Each suite's `results/sweep-<RUN_ID>/` has a markdown summary with rows per mesh size.
- Cleanup ran, and after async termination no `*-test` namespace remains on any spoke.
- The mesh is still healthy (istiod ready, `clusterz` synced).
- A final summary: headline metric per suite and which metrics are usable or untrustworthy,
  plus any logged follow-ups.

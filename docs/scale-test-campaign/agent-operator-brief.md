# Agent operator brief — driving the scale-test campaign

Paste-able brief for a coding session (e.g. Claude Code) to run the campaign autonomously. Follow [`README.md`](README.md) for the 5-stage procedure; this file adds the **operational discipline** that makes an unattended multi-hour run safe. It was distilled from real runs where single-probe failures silently killed multi-hour sweeps.

## Your job
Drive the campaign end-to-end: verify mesh → preflight → dry-run all → run the five suites **serially** (propagation, churn, controlplane, dataplane, churn-dataplane) at `--mesh-sizes 1…N` → collect. Keep a `CAMPAIGN_STATUS.md` progress file at the repo root, updated after every step.

## Non-negotiable discipline
1. **Serial only.** Never run two suites (or two probes) concurrently — they measure the same istiod; concurrency contaminates the data. One sweep at a time.
2. **Monitor for BOTH crash and stall.** A sweep failure is often *not* a crash — a hung `kubectl port-forward` shows as **the process still alive but the log not growing**. For every long sweep, watch:
   - **Crash:** launch the sweep so its exit is reliably observed — either a harness-tracked background task, or track the PID and poll `kill -0 "$PID"`.
   - **Stall:** if the log hasn't grown for longer than the suite's longest *legitimate* quiet stretch (setup deploy-waits up to ~300s + namespace cleanup up to ~180s → use a **≥600–1200s** threshold), flag it. A true hang is permanent; a generous threshold avoids false positives.
   - **Pitfall:** do **not** detect liveness with a `pgrep -f '<pattern>'` whose pattern appears in the monitor's *own* command line — it self-matches and never fires. Track by **PID** (`kill -0`).
3. **Record-and-continue at the suite level.** If a suite errors after you've tried to recover it, run its `00X-cleanup.sh`, mark it FAILED in `CAMPAIGN_STATUS.md` (with a **redacted** error — no cluster names/hosts/tokens), and continue to the next suite. One suite failing must not abort the campaign.
4. **Breaking error → investigate, then fix, then retry.** Do not blind-retry. Find the root cause with concrete evidence (read the log tail, check pod scheduling/events, test the failing shell construct in isolation). Two real examples: a bare command returning non-zero by-design under `set -e` (fix: `|| true` where the next line already handles it), and a `curl` readiness probe with no `--max-time` hanging on a stuck port-forward (fix: `--max-time` + restart the PF). Re-run only the remaining `--mesh-sizes` after fixing.
5. **Validate data sanity, not just exit status.** "status=OK" only means the probe finished. Spot-check that the numbers are physically sensible (e.g. local latency < remote latency; a metric is flat/rising as expected; aggregated gauges sum/peak correctly across the pinned istiod replicas) before trusting a suite's output.
6. **Verify between suites.** Confirm the prior suite's `*-test` namespaces are gone on all spokes and istiod is healthy (clusterz synced) before launching the next.
7. **Don't sit idle without a live detector.** If nothing is watching, a silent stall goes unnoticed. Keep a monitor armed whenever a sweep is running.
8. **Redaction.** Never write real cluster/context names, API hostnames, or kubeconfig/token contents into commits, PRs, issues, or this repo (`AGENTS.md` rule 1). Use placeholders.

## Non-blocking observations
When you notice an issue that isn't breaking (a noisy metric, a suboptimal default, a fidelity caveat), **log it to `CAMPAIGN_STATUS.md`** and — if it warrants a fix — spawn a **subagent to investigate and draft a proposal** rather than fixing inline mid-campaign. Route harness code changes through `/scale-test-review` (see `docs/scale-test-team/`).

## Commands
Use the exact Stage-2 (dry-run) and Stage-3 (live) commands from [`README.md`](README.md), with `CONTEXTS`/`MESH` set for your environment. Dry-run all five first; confirm matrices; then run serially.

## Definition of done
All five suites COMPLETED (or clearly-marked FAILED with cause) in `CAMPAIGN_STATUS.md`; each suite's `results/sweep-<RUN_ID>/` has a markdown summary with non-empty rows per mesh size; all `*-test` namespaces cleaned up; the mesh still healthy (istiod ready, clusterz synced). Then post a final summary: headline metric per suite + any observations logged for follow-up.

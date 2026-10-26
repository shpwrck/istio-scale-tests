# Reading results

What a finished run leaves behind, how to tell whether you can trust it, and what the words in
the reports mean. Each suite's README starts with "At a glance", which explains its own numbers;
this page covers what they share. [Result examples](result-examples.md) shows good and bad
results for every suite, and the exact rules are in [Reference](reference.md).

## Where results go

Every suite writes under `tests/<suite>/results/`. A sweep (the script you normally run) puts
everything from one run in its own folder:

```
tests/<suite>/results/sweep-<RUN_ID>/
├── sweep-outcome.txt     # did the sweep finish? read this first
├── *.tsv                 # the raw rows: a "# KEY=value" header, then one row per measurement
├── *.md                  # the report: open this one
└── istiod-diag-<RUN_ID>/ # only when istiod restarted: the evidence (logs, events)
```

`RUN_ID` is the start time in UTC plus a random suffix, such as `20261026T193327Z-1470`. The
TSVs are the data; the markdown report is a summary computed from them, and you can recompute it
at any time with the suite's report script (`--results-dir <that folder> --format markdown`).

## Is this run trustworthy? Five checks

Go through these in order. Stop at the first one that fails: the numbers below it are not
reliable.

1. **The exit code and `sweep-outcome.txt`.** `STATUS=finished` with exit `0` means every cell
   ran. Exit `4` means it finished, but some cells failed or something changed during the run:
   the `PROBLEM=` lines say what. `STATUS=stopped` (exit `1`) or `interrupted` (`130`, `143`,
   `129`) means the run did not finish; clean up and run it again into a new folder.
   `STATUS=running` on a sweep that is no longer running means it was killed outright.
2. **`n_valid` against `n_total`.** Every table shows how many rows went into each average
   (`n_valid`) out of how many were recorded (`n_total`). Rows with a status other than `OK`
   are left out of the averages. A cell with `n_valid` 0, or far below `n_total`, did not measure
   what it claims; the status counts next to it say why.
3. **Warnings in the report.** Every report prints its warnings in its body (lines starting with
   `WARNING`, `> **Data warning:**`, or a `warnings` list in json). Each one names what is off.
   Read them all before quoting a number.
4. **`mixed:` values.** A provenance key that reads `mixed:<a>,<b>` means the report pooled
   results from different harness versions, Istio versions or platforms. Report one run at a
   time instead (the report stops and tells you how when its folder holds more than one run).
5. **Where it ran.** On kind, all clusters share one machine: latencies and capacity figures
   describe the host, not Istio, and the reports say so. Use kind to learn the harness, never for
   numbers you publish.

## Row statuses

Every row has a `status`. `OK` means it measured cleanly. Anything else keeps the row in
`n_total` but out of the averages. The names differ a little between suites; the meaning is the
same.

| Status | Meaning | Suites |
| --- | --- | --- |
| `OK` | Measured cleanly; counted. | all |
| `TIMEOUT_*` | What the probe waited for did not happen within `--timeout`. A real result (the mesh was slower than the timeout), but not a number. | propagation, churn |
| `RESTART`, `POISONED_RESTART`, `istiod_restarted=1` | istiod restarted during the measurement, so its counters reset. The evidence is in `istiod-diag-<RUN_ID>/`. | all measuring suites |
| `SCRAPE_INCOMPLETE`, `POISONED_SCRAPE` | An istiod metrics read failed, or the reads were too far apart in time. | propagation, churn, churn-dataplane |
| `NOT_DRAINED`, `DRAIN_TIMEOUT` | The previous iteration's endpoint was still there (not counted), or it left late after this iteration (counted, the value was taken before). | propagation |
| `QPS_SHORTFALL` | The load generator did not reach the requested requests per second, so the server was saturated and the latency is not comparable. | dataplane |
| `ERROR_RATE_HIGH` | Fewer than 99% of requests got HTTP 200. | dataplane, churn-dataplane |
| `UNREACHABLE`, `REMOTE_UNREACHABLE` | A remote member could not be reached before the load started, so no load ran against it. | dataplane, churn-dataplane |
| `CHURN_RATE_NOT_MET` | Under 90% of the requested scale operations succeeded. | churn-dataplane |
| `MISSING_VALUE`, `PERCENTILE_MISSING` | A column the row needs has no number. | churn, dataplane, churn-dataplane |
| `SETUP_FAILED`, `PROBE_FAILED` | A placeholder: the sweep's setup or probe step failed for that cell, so nothing was measured. The sweep goes on to the next cell and exits `4`. | all sweeps |
| `SKIPPED_MEM_GUARD` | The controlplane memory guard skipped a cell that would have pushed istiod or a gateway near its memory limit. | controlplane |

The full list for each suite is in its README.

## Words the reports use

| Term | Meaning |
| --- | --- |
| mesh size | How many members took part in that cell. A sweep runs size 1 (one member, no cross-cluster path) up to all members. |
| source, remote | The member where the change or the load starts, and the other members. Remote numbers are cross-cluster. |
| p50, p99 | The median and the 99th percentile. p99 needs enough samples: below the minimum it reads `N/A`. |
| worst bucket, `100-500` | istiod reports some timings only as histogram buckets. The report shows the slowest bucket a valid row reached, as a range in ms, never an average. |
| `overflow` | The value fell in the histogram's last bucket (above its highest bound): slower than istiod can say. |
| `N/A` | Not measured, or too few samples. Never the same as 0. |
| `unknown` | A value that was not read (a failed read, or a file from before the key existed). |
| delta, `Δ` | The change over a measurement window (counters), or between two windows (`Δp99` in churn-dataplane: p99 under churn minus p99 without). |
| xDS push | istiod sending configuration to a proxy. More pushes per change means more control-plane work. |
| convergence | The time until every proxy has the new configuration. |
| `PASS`, `CAUTION`, `FAIL` | The controlplane scale-envelope verdict: istiod CPU or memory under 75% of its limit, between 75% and 90%, or over 90% (or a restart). |
| `HARNESS_SHA` | The commit of this repo that produced the result (`-dirty.<hash>` when it had local changes). |

## Sharing results

Results name your clusters and contexts. Before you paste them into a ticket or into
`docs/campaigns/`, make a redacted copy:

```bash
tests/lib/redact-results.sh --out /tmp/redacted tests/<suite>/results/sweep-<RUN_ID>
```

[docs/campaigns/TEMPLATE.md](campaigns/TEMPLATE.md) is the layout for a recorded campaign.

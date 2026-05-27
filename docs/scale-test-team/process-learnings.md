# Process Learnings (PL Catalog)

This is the carry-forward catalog every implementer brief draws from. New PLs are appended after each cycle when a reviewer surfaces a failure mode the existing list didn't cover.

Each entry:
- **Catalog line** — one-line label suitable for citing in a brief ("PL1 delta-window scraping")
- **Why** — what failure mode this prevents
- **How to preempt** — concrete code/structure guidance for the implementer

---

## PL1 — Delta-window scraping for cumulative istiod metrics

**Why:** Prometheus metrics on istiod (`pilot_xds_pushes`, `pilot_k8s_cfg_events`, `process_cpu_seconds_total`, histogram `_bucket`/`_sum`/`_count`) are cumulative since the process started. Reading once per sweep point gives the lifetime total, not the work-during-the-window. Cross-row comparisons of cumulative values are meaningless.

**How to preempt:** Scrape `/metrics` twice (baseline before work, final after settle), persist both files, compute deltas. Histogram quantiles must be computed on per-bucket *deltas*, not on the raw bucket counts.

## PL2 — TSV preamble with run metadata

**Why:** Without provenance metadata, a TSV row 3 months later is uninterpretable. "Was this an Istio 1.27 run or 1.28? Same harness commit as last week or a hacked-up branch?"

**How to preempt:** Every TSV-writing script emits a preamble block:
```
# RUN_ID=<timestamp + $$>
# HARNESS_SHA=$(git describe --always --dirty --abbrev=7)
# ISTIO_VERSION=<from config/versions.env>
# KUBE_VERSIONS[ctx]=<per-context, concurrent probes, --request-timeout=5s>
# SETTLE_SEC=<value>
# (any other knob that affects the result)
```
Use `date -u -Iseconds` (UTC) for timestamps. `HARNESS_SHA` must include `--dirty` so a hacked-up working tree is visible.

## PL3 — Wall-clock window distinct from operator settle

**Why:** The actual elapsed time between baseline and final scrapes is rarely exactly `--settle` (scrape latency, settle drift, async cluster ops). Using the operator's intent as the rate denominator overstates or understates the rates.

**How to preempt:** Capture per-context request-start and request-end timestamps; compute `scrape_window_sec = (min(final.start) − max(baseline.end)) / 1000`. Emit as a TSV column. Keep `settle_sec` (operator intent) as a separate column. Use `scrape_window_sec` as the denominator for `*_rate` columns.

## PL4 — Await async cluster ops

**Why:** Namespace deletion is async (`Terminating` can take minutes). A cleanup script that returns when the delete is *accepted* races the next combo's setup; residual istiod state pollutes the next baseline.

**How to preempt:** Cleanup scripts poll `kubectl get ns -l app.kubernetes.io/instance=<suite>-test -o name` (or equivalent) with a 180-300s timeout until empty. Surface timeouts as a row status (e.g. `DRAIN_TIMEOUT`), not as a `|| true`-swallowed warning.

## PL5 — Server-side apply for large workloads

**Why:** `kubectl apply -f -` uses the client-side `last-applied-configuration` annotation, which has a 256 KiB per-object limit and renders the full manifest stream into kubectl memory. At 5k+ services the pipe builds a GB-class stream and OOMs.

**How to preempt:** `kubectl apply --server-side --force-conflicts -f -`. Use `--dry-run=client` only for dry-runs.

## PL6 — Per-sweep output subdir

**Why:** A flat `results/` directory mixes back-to-back sweeps. The report aggregator globs all matching TSVs and silently conflates configurations.

**How to preempt:** The sweep orchestrator (`003` or `004`) mints `RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)-$$` and creates `${OUTPUT_DIR_BASE}/sweep-${RUN_ID}/`. Passes the subdir as `--output-dir` to the probe and `--results-dir` to the report.

## PL7 — Plural-CSV on sweep scripts with singular alias + deprecation warning

**Why:** Sweep scripts iterate axes (CSV input); standalone setup scripts take one config (singular). Naming mismatch between them trips operators. Renaming a flag mid-project loses muscle memory.

**How to preempt:** Sweep scripts accept `--<axis>s CSV` (plural). Provide singular `--<axis>` as a one-value alias. When the singular form is used, print a stderr deprecation warning naming the canonical plural form.

## PL8 — Concurrent multi-context scrapes with `scrape_skew_ms`

**Why:** Serial per-context scrapes at scale build seconds of drift between the first and last cluster's snapshot. Counter deltas later attributed to "this combo's window" mix in that drift.

**How to preempt:** Fan out scrapes with `&` + `wait`. Record per-context request-start timestamps. Emit `scrape_skew_ms = max(ts) − min(ts)` across the per-context files (NOT the total batch wall-clock).

## PL9 — istiod restart detection: `0 | 1 | unknown`

**Why:** A mid-window istiod restart resets every counter to 0. The resulting deltas are nonsensical (negative, or "near baseline"). Without a restart flag the report silently produces wrong numbers.

**How to preempt:** Read `process_start_time_seconds` baseline + final per context. Emit `istiod_restarted` as:
- `1` — `final > baseline` (restart detected)
- `0` — both present, equal
- `unknown` — either side missing (don't claim "no restart" when you couldn't measure)

Report aggregator filters BOTH `1` and `unknown` from numeric averages and surfaces a count.

## PL10 — Matrix safety cap + `--force-large-matrix`

**Why:** Operators routinely typo a sweep input that produces a thousand-combo matrix. Without a gate, a misclick burns a multi-day run.

**How to preempt:** Sweep orchestrators compute the cross-product size upfront and refuse to run if it exceeds `CONTROLPLANE_MAX_MATRIX` (default 64). `--force-large-matrix` bypasses with an explicit acknowledgment. The error message names the actual size AND the factor breakdown so the operator can fix the typo.

## PL11 — Histogram metrics handled as histograms, not counters

**Why:** `pilot_xds_config_size_bytes` (and similar) emit `_bucket`, `_sum`, `_count` lines. Summing all matching lines as a "counter total" double-counts the bucket rows and yields a meaningless number.

**How to preempt:** For "average payload" use `(_sum.final − _sum.baseline) / (_count.final − _count.baseline)`. For percentiles, use the standard bucket-walking algorithm on per-bucket deltas (see PL14 for the negative-bucket guard).

## PL12 — Gauge extraction sums across label permutations

**Why:** `pilot_xds` (connected proxies) and similar gauges are emitted with labels like `{type="ads"}`. A regex that exits after the first match returns one permutation's value instead of the total.

**How to preempt:** Gauge extractors `accumulate $NF` across all matching lines, not just the first. Document in a comment that the metric must be name-anchored so it doesn't prefix-collide with `_pushes` / `_config_size_bytes` etc.

## PL13 — Restart guard on counter deltas + histogram quantiles

**Why:** Even with PL9 restart detection, the numeric delta columns will contain garbage values for restarted-mid-window rows. If the aggregator includes them, the average is poisoned.

**How to preempt:** When `istiod_restarted == "1"` (and also `"unknown"`), the probe emits `N/A` for every counter delta and histogram quantile in that row. The aggregator skips rows where `restarted != 0` from numeric averages but still counts them in `n_total`.

## PL14 — Negative histogram bucket delta → `N/A`

**Why:** Final < baseline in any `le=` bucket (counter rotation, label-set drift, mid-window restart not yet flagged) produces a non-monotone CDF; walking it for a target quantile returns nonsense.

**How to preempt:** The histogram-quantile extractor checks each per-bucket delta; if any is negative, emit `N/A` (don't attempt to repair monotonicity — `N/A` is the honest signal).

## PL15 — Report aggregator filters poisoned rows; emits `n_total` and `n_valid`

**Why:** Operators need to see both "how many samples did we attempt" and "how many survived the filters". A report that silently drops poisoned rows hides the failure rate.

**How to preempt:** The aggregator counts `n_total` (all rows for the cell) and `n_valid` (rows passing the filters: `restarted=0`, `status=OK`, `overflow=0`, etc.). Both columns appear in every output format. A markdown footnote fires when `n_total > n_valid` for any cell.

## PL16 — Bash/awk-only deterministic seeded shuffle (no `shuf`)

**Why:** `shuf` is non-deterministic by default AND not on the agreed tool list. Two sweeps with the same args pick different random samples, breaking reproducibility.

**How to preempt:** Implement a deterministic shuffle in awk (LCG or hash-by-key) seeded from `RUN_ID + context_name`. Pick top-N from the sorted list. Same seed → same picks.

## PL17 — Sample-count column format: `got/attempted`

**Why:** When a column records partial successes, recording only `got` is indistinguishable from "configured low" — operators can't tell whether 2 of 3 samples failed or whether `--samples 1` was passed.

**How to preempt:** Format as `<got>/<attempted>` consistently across code, TSV, README, and report. Document the order; an inverted order in the README would be worse than no docs.

## PL18 — Settle gap between cleanup and next combo setup

**Why:** Even after PL4 confirms namespace deletion completed, istiod is still draining the push context for the just-deleted workloads. The next combo's baseline scrape lands inside this drain storm and inflates the deltas.

**How to preempt:** The orchestrator sleeps `--settle SEC` (or a fixed minimum) after `005` returns and before the next combo's `001` starts. This is in addition to the within-combo settle between baseline and final scrapes.

## PL19 — Report metadata propagation to all 4 output formats

**Why:** The TSV preamble (PL2) is provenance gold. If the report drops it, downstream consumers reading the report alone can't reconstruct what was measured.

**How to preempt:** The report (`004` or `005`) reads the first TSV's preamble lines and emits them as:
- `text` / `csv` — `# KEY=VALUE` lines above the data
- `markdown` — YAML frontmatter (`---\nKEY: VALUE\n---`)
- `json` — top-level `metadata` object alongside `results` array

When there are 5+ preamble fields, propagate ALL of them, not just `RUN_ID` and `HARNESS_SHA`.

## PL20 — Multi-push detection thresholds

**Why:** A `delta._count >= source_proxy_count` threshold for "convergence detected" assumes one push per Service apply. Istiod batches: a Service+Endpoints apply commonly produces CDS + EDS + Sidecar-recompute pushes. The flat threshold satisfies at *partial* convergence.

**How to preempt:** Either (a) scale the threshold by observed `pilot_xds_pushes` delta (`target = proxy_count * pushes_delta`), or (b) filter `pilot_xds_pushes{type="eds"}` specifically when the goal is endpoint discovery. Document the choice with an inline comment.

## PL21 — Single-scrape consistency for gauge + histogram pairs

**Why:** If `proxy_count` is read in one scrape and the histogram baseline in another, a proxy connecting/disconnecting between them invalidates the threshold. The same race applies to any pair of values that must come from the same istiod snapshot.

**How to preempt:** Parse all needed fields from a single `/metrics` scrape blob. No second HTTP round-trip for gauges when a baseline blob is already in hand.

## PL22 — Single awk pass per scrape, not multi-pipe

**Why:** Hot-path scrapes do 4× `echo "$metrics" | awk` per tick (one per extractor). At MB-sized payloads × N contexts × 4 Hz polling, that's hundreds of MB/s of subshell churn on the harness host — probe-self-noise.

**How to preempt:** Scrape to a tempfile once per tick. One awk pass emits all needed fields (gauge values, counter values, histogram buckets, process_start_time, etc.) in a structured KV format the caller reads.

## PL23 — Drain/cleanup timeouts propagate as row status

**Why:** When `wait_sidecar_endpoint_removed` (or equivalent) times out, returning `|| true` and emitting a warning lets the next iteration's baseline include the un-drained workload. The report has no idea the row is contaminated.

**How to preempt:** Timeout → emit a row with `status=DRAIN_TIMEOUT` (or `CLEANUP_TIMEOUT`); the report aggregator filters non-OK status from numeric aggregation alongside `restarted` and `overflow`.

## PL24 — Window must cover the deploy storm, not just the settle

**Why:** A delta-window that starts *after* the setup script returns misses the entire push-storm period — istiod is back to idle by then. Even cumulative-counter deltas read near-zero, and quantiles over the resulting bucket-counts include only the settle period.

**How to preempt:** Split the probe into `--phase baseline | final` with a `--state-dir` to ferry baseline files across the setup step. The orchestrator calls `baseline` *before* `001`, then `001`, then sleeps settle, then `final`. The wall-clock window now spans the entire deploy + settle.

(PL24 was added after the homelab CPU-spike data on PR #2 — see `controlplane-test/README.md` "What Gets Measured" for the resulting orchestration.)

## PL25 — Drop snapshots that read idle

**Why:** Once a delta-window measurement exists for a quantity (e.g. `cpu_m_delta` from `process_cpu_seconds_total`), keeping the *kubectl-top snapshot* as a "spot check" doesn't add information — the snapshot reads ~1-2 m on idle istiods regardless of the work that just happened, so it's just noise that invites confusion about which column to trust.

**How to preempt:** When the delta-window version of a metric is added, *remove* the snapshot version from the schema, not "demote it to informational". Keep snapshots only for gauges (memory, connected_proxies) where a single observation is genuinely representative.

(PL25 was added after PR #2's third round of feedback — `cpu_top` was demoted to spot-check, then removed entirely.)

## PL26 — Multi-input report preamble: scalar/sequence partition

**Why:** PL19 propagates the TSV preamble into all four report formats, but when a sweep feeds N per-iteration TSVs into one report, the naive "last-value-wins per key" aggregation collapses per-iteration scalars (`RUN_ID`, `DATE`, `MESH_SIZE`, `REMOTES`, `KUBE_VERSIONS`) to whichever input file sorted last. The resulting frontmatter advertises *one* iteration's identity (e.g. `MESH_SIZE: 2`) while the report body summarises the whole sweep (e.g. comparison table listing sizes 1, 2, 4, 8). Operators reading the report file detached from its directory are actively misled about provenance.

**How to preempt:** Classify preamble keys into two partitions before propagation:
- **Sweep-level scalars** — values that must be identical across every input TSV in a coherent run (`SWEEP_RUN_ID`, `HARNESS_SHA`, `ISTIO_VERSION`, sweep-wide knobs like `SETTLE_SEC`/`TIMEOUT_SEC`/`ITERATIONS`). Rendered as scalars at the top of the metadata block.
- **Per-iteration values** — keys whose values legitimately vary across the N input TSVs (`RUN_ID`, `DATE`, `MESH_SIZE`, per-iteration `REMOTES`/`KUBE_VERSIONS`). Rendered as a sequence (`iterations:` YAML block for markdown/text, `# iterations:` comment block for CSV, `"iterations":[...]` array for JSON) with one entry per input TSV. A single-input report still renders a one-element sequence so the schema is uniform.

The sweep orchestrator threads a `SWEEP_RUN_ID` from the wrapper → probe → TSV preamble (probe omits the line when the flag is unset so standalone runs stay clean) and the report emits it as the first scalar key. The classification predicate (sweep-level keys must be homogeneous across inputs) is a correctness invariant — implementers should consider a stderr warning when a sweep-level key actually varies across inputs, since silent last-wins on a key the operator marked sweep-level is the same failure mode in miniature.

(PL26 was added after PR for issue #11: the propagation sweep was refactored to use the report script for markdown summary; round-1 reviewers (usability + reproducibility) caught that PL19 propagation alone is insufficient when N TSVs feed one report.)

## PL27 — Scope Helm renders to the resources being mutated

**Why:** When a probe script uses `helm template | kubectl apply` to create or update a single resource (e.g. a canary Deployment), the default `helm template` renders the *entire* chart — including resources the probe doesn't own (e.g. watcher Deployments). Server-side apply with `--force-conflicts` then overwrites those resources with the chart's default values, silently reverting operator-configured settings (like `replicaCount`) on every iteration.

**How to preempt:** Use `helm template --show-only templates/<file>.yaml` to scope the render to only the templates the probe needs. This is especially important when the chart contains resources managed by a separate setup script with its own CLI flags (e.g. `--watcher-replicas`). The probe must not re-apply resources it doesn't own.

(PL27 was added after PR #2: the propagation probe's `helm template` rendered the full chart each iteration, overwriting watcher Deployment `replicaCount` from 30 back to the chart default of 1, dropping connected proxy count mid-sweep and losing histogram quantile data.)

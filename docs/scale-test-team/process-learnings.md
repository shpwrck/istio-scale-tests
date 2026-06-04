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

**How to preempt:** Fan out scrapes with `&` + `wait`. Record per-pod/per-context scrape **completion** timestamps (in `tests/lib/fanout.sh`, `now_ns` is stamped after `_fanout_scrape_one` returns). Emit `scrape_skew_ms = max(ts) − min(ts)` across the per-context files (NOT the total batch wall-clock).

**Completion- vs start-stamping (deliberate):** completion-spread is the more *conservative* coherence signal. A `/metrics` snapshot is only coherent if all bodies were *read* close together — a cumulative counter can advance between a fast read and a slow read of the same batch, so the spread of *completions* bounds how stale the earliest body is relative to the latest. Start-stamping would measure only subshell-dispatch jitter (tens of ms) and would NOT catch a curl that queued for seconds behind dozens of port-forward proxies. Keep completion-stamping as the gating signal; if a start-spread diagnostic is ever wanted, record BOTH spreads but gate on completion.

**Bound the skew, don't just record it (O3):** `scrape_skew_ms` is provenance only unless something gates on it. A single batch whose completion-spread approaches the curl timeout (e.g. one curl near `FANOUT_METRICS_TIMEOUT` at ~50 concurrent port-forwards → multi-second skew) yields counter/histogram deltas computed across an incoherent snapshot, and the row counts toward averages with no flag. Add a `FANOUT_MAX_SKEW_MS` ceiling (default 1000 — above the ~100–350 ms normal spread, below the multi-second outlier, above the ~2 s P1/P2 signal floor) and, when a batch exceeds it, tag the row via the **existing** incomplete/poison plumbing (`SCRAPE_INCOMPLETE` / `POISONED_SCRAPE`) so the report filters it. `tests/lib/fanout.sh` persists each batch's skew to a `<prefix>.skew` sidecar and exposes `fanout_scrape_skew_high <dir> <prefix>` (mirrors the `.failed` / `fanout_scrape_failed_count` pattern); keep the skew-computing awk pass byte-identical (PL22) and still emit the raw skew in the TSV for provenance.

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

## PL28 — Multi-replica istiod fanout: gauge sum-vs-invariant classification

**Why:** When a probe scrapes a single istiod (`svc/istiod` port-forward → one replica), every metric is read from one pod. The moment the control plane is pinned to N replicas and the probe fans out (scrapes every istiod pod), aggregation acquires a SECOND axis — across pods — and metrics split into classes that aggregate differently. Summing the wrong class silently N×'s or undercounts a value. Specifically: `connected_proxies` (`pilot_xds`) is per-replica (each proxy holds exactly one istiod connection) and must **sum across replicas**, while `pilot_services` (and any mesh-global registry gauge) is **identical on every replica** and must be treated **invariant (max/any), NOT summed** — summing it 5×'s the service count and breaks any "services delta ≥ 1" clean-check. Compounding trap: PL12's `extract_gauge` returns the *last* matching line, not a within-pod sum across label permutations — so a naive `fanout_gauge_sum` built on it is a double no-op (wrong within-pod, then summed across pods).

**How to preempt:** Provide an `extract_gauge_sum` that accumulates `$NF` across all name-anchored permutations within a pod (don't reuse `extract_gauge`, which is last-match). Then classify each gauge: SUM-across-pods (`connected_proxies`) vs INVARIANT/max-across-pods (`pilot_services`). Counters always sum across pods (each event emitted by one replica). Histograms sum per-bucket counts across pods *before* computing deltas/quantiles (never average per-pod quantiles). Restart detection fires on ANY pod restart OR pod-set change. Unit-test the sum-vs-invariant distinction with fixtures carrying MULTIPLE label permutations per pod (e.g. `pilot_xds{type=ads}`+`{type=grpc}`) so the within-pod axis is actually exercised, plus a regression test documenting that plain `extract_gauge` is NOT a sum.

(PL28 was added after the istiod-fanout PR: round-1 measurement + istio reviewers caught that the cross-pod gauge sum was built on `extract_gauge`'s last-match behaviour and that `pilot_services` would be 5×'d if summed like `pilot_xds`.)

## PL29 — Empty/short fanout scrape must be distinguishable from a legitimate zero

**Why:** With one scrape per measurement, a failed scrape is obvious (the whole probe errors). With a fanned-out scrape of N pods, a single dead/slow port-forward writes an EMPTY `/metrics` file that every summing aggregator silently treats as 0 — so the summed value (e.g. `pilot_xds`, the P1 convergence-threshold denominator `Σ delta_count ≥ Σ proxy_count`) drops by ~1/N and the probe "converges" early on a smaller target, emitting plausible-but-wrong latency with no failure flag. At 10 contexts × 5 replicas ≈ 50 port-forwards over a multi-hour sweep, a PF drop is near-certain. An empty scrape MUST NOT be indistinguishable from a pod that legitimately reports 0.

**How to preempt:** In the fanout scrape helper, reject bodies below a `FANOUT_MIN_SCRAPE_BYTES` floor (a truncated 200-byte body is a failure, not a zero), retry each failed pod ONCE in-tick (reopen the port-forward), persist the still-failed pod count (e.g. `<prefix>.failed`) and return non-zero. The probe reads the failed count and, when non-zero, skips the convergence test for that tick and tags the row `SCRAPE_INCOMPLETE` (or a suite-local `POISONED_*` equivalent) so the report aggregator filters it (alongside `restarted`/`TIMEOUT_*` per PL13/PL15). `fanout_open` should tolerate one unreachable pod (skip it, die only when ZERO replicas serve) so a transiently-Running-not-Ready pod during a rolling restart doesn't abort the whole probe.

(PL29 was added after the istiod-fanout PR: round-1 scale + reproducibility reviewers caught that an empty per-pod scrape was being summed as 0, undercounting the convergence denominator without any row flag.)

## PL30 — Isolate "config propagation" from "workload boot": pre-warm + flip, don't create at t0

**Why:** A probe that measures how fast a *config change* propagates must not start its clock before a *workload* exists. The propagation probe captured `T0` immediately before `helm template | kubectl apply` created a **fresh** canary Deployment+Service every iteration, so the data-plane phase (P3, "remote sidecar has a healthy endpoint") inevitably included pod scheduling + image pull (`:latest`, no readiness probe, no `imagePullPolicy`) + sidecar startup. P3 ran 8–102 s and was non-monotonic — it measured "new workload reachable", not xDS/EDS propagation, and the boot variance swamped the ~2 s control-plane signal. The same trap applies to any suite that stamps `t0` and then *creates* the thing whose propagation it wants to time.

**How to preempt:** Pre-warm the workload in the setup script (`001`): a single already-Ready backer pod with the image **pinned + `imagePullPolicy: IfNotPresent`**, the sidecar up, and a `readinessProbe`, NOT yet selected by the Service. Gate Service membership on a separate **active-flip label** (the Service selects on the stable pod label **AND** `…-active: "true"`), so the backer is Ready-but-unselected until `t0`. At `t0`, capture the pod **before** setting `T0`, then do a **config-only** mutation — `kubectl label pod <pod> <key>=true --overwrite` (PL5 server-side) — so the endpoint appears via an EDS push with no reschedule. Drain = remove the label (`<key>-`); the backer stays warm for the next iteration and the Deployment/Service persist. Keep ONE shared `T0` across all phases so they stay comparable, and render only the templates being shown/applied (PL27). Watch two follow-on traps the new topology introduces: (a) the Service now persists across iterations, so a data-plane "drained?" check that waited for the *cluster name* to disappear from Envoy `/clusters` must instead wait for the absence of a **healthy** endpoint (the inverse of the detection match); (b) guard that the backer is genuinely `Ready` before `t0` (a flip onto a not-yet-Ready pod re-introduces the boot latency the pre-warm was meant to remove).

(PL30 was added after campaign observation O1: the propagation P3 phase was measuring canary pod boot, not propagation. The fix pre-warms a backer and flips a label at t0.)

## PL31 — A topology change silently invalidates secondary "is-this-clean" discriminators; the naive fix samples one causal step too early

**Why:** PL30 names two *data-plane* follow-on traps of the pre-warm+flip topology. There is a third, on a *different phase's* dirty/cleanliness discriminator. The propagation P2 phase (remote registry discovery) flagged a row dirty when an EDS bump arrived **without** an accompanying `pilot_services` gauge delta ≥ 1 — a correct "this was unrelated churn, not our change" test **only while t0 *created* a new canary Service** (the registry gained a Service → `pilot_services` +1). Under the PL30 label-flip topology the Service is created once in `001` and **persists**, so at t0 the flip adds only an *endpoint*, the `pilot_services` delta is always 0, **every** row is flagged dirty, and the report silently drops the entire P2 column — a structurally-empty metric masquerading as "filtered for quality". Compounding trap (caught a round later): the obvious fix — replace the stale discriminator with the canary's `health_flags::healthy` signal sampled **at the EDS-bump instant** — re-introduces the bias from the opposite side, because the confirming signal is **causally downstream** of the trigger: istiod increments `pilot_xds_pushes{type=eds}` when it *issues* the push, but the sidecar reports `health_flags::healthy` only after it *applies* it, and that lag *is* the P2→P3 gap being measured. So a genuinely-clean iteration reads "not healthy yet → dirty" and the column collapses again.

**How to preempt:** When a probe's t0 trigger changes shape (create→config-only mutation, or any analogous reshaping), audit **every downstream discriminator** — dirty flags, cleanliness gates, drain detectors, threshold denominators — not just the headline metric. For each, name the side-effect of the *old* trigger it was keyed to, and re-derive it for the *new* trigger. For an "is this measurement ours/clean" discriminator, gate on the window's **terminal outcome** (did the thing converge by end-of-window?), never on an instantaneous read at the trigger instant when the confirming signal is causally downstream of the trigger. Prefer reconciling against an **existing phase's terminal result** (here: `p2_dirty = p2_ms numeric AND p3_ms non-numeric` — "EDS bumped but the canary never went healthy in-window") over adding a second consumer that races the authoritative poller on the same port-forward. Lock the predicate with an inline truth-table comment so a later refactor can't silently re-break it.

(PL31 was added after the O1+O3 review cycle: round-1 istio caught that the label-flip topology always-dirtied P2 because the discriminator was keyed to the old create's `pilot_services` delta; round-2 istio caught that the naive `health_flags::healthy`-at-bump fix sampled the replacement signal one causal step too early. Fixed by reconciling `p2_dirty` against the P3 terminal outcome.)

## PL32 — Under `set -e`, EVERY per-combo orchestrator step is a whole-sweep killer — wrap them all, and the likeliest killer is setup, not the probe

**Why:** A multi-hour sweep orchestrator runs a sequence of step scripts per combo (`001-setup`, the `002` probe, `005`/`006` cleanup, and for tuning `001-apply-profile`/`002-revert-profile`). Each is a bare `"$SCRIPT_DIR/0NN-….sh"` call under `set -euo pipefail`, so a single non-zero exit aborts the *entire* sweep at that combo — and because reports run only *after* the loop, an abort at combo 50/200 discards all 49 completed combos of overnight data. Hardening only the *probe* call (the obvious one) leaves the others live: at scale (~50 port-forwards, hundreds of combos) the **setup/deploy** step (`helm template|apply` + label-selector `kubectl wait` timeouts) is the *most probable* per-combo failure, more likely than the probe.

**How to preempt:** Wrap every per-combo step `if ! "$SCRIPT_DIR/0NN-….sh" …; then warn; <record the failure visibly>; cleanup; settle; continue; fi`. "Record visibly" = emit a status row (`SETUP_FAILED`/`PROBE_FAILED`, counted in `n_total`, excluded from `n_valid` per PL15) for emit-row suites, or a placeholder row / marker file for log-and-continue suites (so a fully-crashed combo is not silently *absent* from the report — indistinguishable from never-planned). On a setup-failure path, also tear down anything the success path would (e.g. a background metrics poller started before the step) before `continue`. Degraded rows carry N/A numerics + `restarted=unknown` (PL13); a baseline-phase failure must still bucket into the **real** `(axis…)` cell, and the orchestrator must pre-create the TSV preamble before the first step so a first-combo failure can't strip run provenance (PL2/PL19). Reserve `die` for whole-run preconditions only (bad args, missing tools, zero istiod across ALL contexts).

(PL32 was added after the O6 fault-tolerance cycle: round-1 wrapped the probe calls but the scale lens found `001-setup` bare in all 5 orchestrators — the likeliest sweep-killer — plus a fully-crashed mesh size vanishing from the report and a baseline-failure mis-bucketing to a phantom cell; later rounds wrapped setup + tuning apply/revert and added placeholder rows. Lesson: harden the *whole per-combo step sequence*, not just the headline call.)

## PL33 — A regression guard must be verified end-to-end through its real entrypoint against a live positive instance — not just its inner unit

**Why:** A lint/check added to prevent a class of bug gives **false confidence** if it passes its own unit test but is never actually dispatched to the file it was meant to guard. The O6 orchestrator-step lint was generalized specifically to catch tuning's bare step calls, and its direct-invocation regression test passed — but the production entrypoint (`lint_bare_scrape_paths`, what `verify.sh` runs) dispatched the check only to `*-run-sweep.sh`, which does **not** match `003-run-tuning-sweep.sh`. So the guard was toothless for the exact file it was added for, while every signal (unit test, `verify.sh` green) said "covered." A second bug hid behind it: the guard's "is this call guarded?" test read only the first physical line, so a `\`-continued statement with its `||` guard on a later line was a false positive — which would only have surfaced *after* the dispatch gap was closed.

**How to preempt:** Validate a new guard the way an adversary would: (1) run it through the **production entrypoint** (the command `verify.sh`/CI actually invokes), not just the inner function; (2) prove it **fires** by introducing a live positive instance (temporarily un-guard a real call) and confirming the entrypoint reports it, then restore; (3) confirm its **dispatch/glob actually matches** every target file (enumerate what the glob matches vs the files that exist); (4) test multi-line / continuation forms, not just single-line fixtures. A guard that can't be shown to fail on a real violation isn't a guard. And when a reviewer claims "the gate fails/passes," reproduce the exit code before acting — the stated mechanism may be the symptom of a deeper escape.

(PL33 was added after the O6 cycle round-4: the conventions reviewer reported the lint failed `verify.sh` on guarded tuning code; reproducing the actual exit codes revealed the opposite — `verify.sh` passed because the lint never reached tuning at all (dispatch-glob gap), masking a real multi-line-guard false positive. Both were fixed only because the claim was reproduced against real exit codes rather than acted on directly.)

## PL34 — "Deploy once, sweep an inner axis" is only fidelity-neutral if you restore the per-iteration starting state the probe assumes — and a failed restore is a new silent-contamination path

**Why:** A big wall-clock win is to hoist setup/teardown out of an inner sweep loop and reuse one deployed workload across the inner axis (e.g. churn-dataplane deploying once per mesh-size and sweeping all churn rates on it, instead of redeploy-per-rate). But "reuse the workload" is **not** the same as "reproduce the measured conditions." The inner-axis probe almost always assumes a specific *starting state*: churn-dataplane's `003` initializes its per-target PARITY tracker to all-base and toggles from there, and it never resets replicas at the end — so after one rate the churn-targets are left in a **mixed** state. Naively reusing that workload for the next rate (a) contaminates the next rate's **baseline** (it now measures a non-all-base mesh — a "no baseline reuse" violation in disguise), and (b) **desyncs the probe's own state model**: PARITY=0 issues `scale --replicas=scale-to` against deployments already at scale-to → no-op scales → **undercounted EDS/xDS push deltas**. The fresh redeploy you removed was silently providing that clean starting state.

**How to preempt:** Before each inner-axis iteration after the first, explicitly **restore the exact starting state a fresh deploy gave** (here: `kubectl scale -l <workload-selector> --replicas=<base>` on every active context, scoped by a label that excludes the measurement workload), then **drain** the restore's own control-plane activity with the existing inter-iteration settle before measuring. Keep the per-iteration baseline. Crucially, the restore is itself a cluster op that can fail — and a *failed* restore is a brand-new failure mode that the redeploy-per-iteration design could never have. Treat it like a setup failure: have the restore **report** non-zero (don't swallow it best-effort), and on failure record a degraded status row (`RESET_FAILED`, counted in `n_total`, excluded from `n_valid` per PL15/PL32) and **skip** that iteration's measurement rather than measuring against a known-contaminated mesh. Bound the restore with a request timeout (PL/O6 `--max-time` discipline) so a hung apiserver degrades to that recorded skip instead of stalling the sweep. Also update every doc that described the old per-iteration structure (README "how the sweep works", the script-table flow, the `--settle` help, the status enum) — a deploy-once restructure changes the operator's runtime/isolation mental model, and stale docs read as "fresh-namespace isolation between every iteration" when there no longer is any.

(PL34 was added after the O8 runtime cycle: round-1 reviewers confirmed the deploy-once refactor was fidelity-neutral *only because* of the reset-to-base guard, but three lenses independently flagged that a *failed* reset silently admitted a contaminated rate into `n_valid` — converted in round-2 to a recorded-and-skipped `RESET_FAILED`, mirroring the O6/PL32 setup-failure philosophy.)

## PL35 — A `%-of-capacity` ratio must share aggregation scope numerator↔denominator; and an "achieved scale" legibility block must mirror the `n_valid` filter, not re-ingest configured/failed rows

**Why:** Adding utilization legibility (a "%-of-limit" column, an "achieved scale" report block) is high-value but has two recurring traps. (1) **Ratio scope mismatch:** the numerator and denominator must be aggregated over the *same* set. istiod usage was summed across *all* replicas (`kubectl top pod -l app=istiod`) while the limit was read *per replica* (`deploy.spec...resources.limits`), so `% of limit` read up to ~R×100% on an R-replica control plane that was actually idle — the metric did not measure what its name claimed. This is the same family as PL28 (sum-vs-invariant for multi-replica istiod): any cross-replica ratio has to multiply the per-replica denominator by the replica count (or average the numerator). (2) **Legibility must mirror validity:** an "achieved scale" block that takes `max()` over *every* row re-ingests the rows the rest of the report already excludes — a `SETUP_FAILED`/restarted row still carries the *configured* axis value (`service_count`) and a mid-reconnect gauge (`connected_proxies`), so the headline read "200 services achieved" when zero deployed. A legibility aggregate over measured data must apply the **same `n_valid` gate** (here `istiod_restarted==0`) the numeric aggregates use; otherwise it reports configured intent as achieved fact.

**How to preempt:** When adding any `pct_of_X` column, write down the scope of both operands and make them match (sum/sum or per-unit/per-unit) — and unit-test the **R>1** path explicitly (a single-replica fixture hides the bug). When adding a report block that summarizes "what we actually achieved," gate its ingestion on the same validity predicate as `n_valid` (skip restarted/failed/degraded rows), and label values honestly (a *configured* axis surfaced as "achieved" should say so). Bump the TSV schema as a clean append (old cols byte-identical, new cols appended), stamp a `…_SCHEMA=<n>` preamble marker so a future same-width-different-semantics schema can't silently mis-aggregate, and skip + count (not silently drop) legacy-width files. Keep the environmental capacity reads OUT of the measurement window and off the default path (legibility always-on and read-only; capacity-*derived sizing* behind a default-off flag) so the change is observability-only until calibrated on a real cluster.

(PL35 was added after the O9 scale-coverage cycle: round-1 istio caught the per-replica-denominator ratio bug and measurement caught the achieved-scale block ingesting `service_count`/`connected_proxies` from `SETUP_FAILED`/restarted rows; both fixed in round-2 by multiplying the limit by replicas and gating the block on `istiod_restarted==0`.)

**Corollary (caught in an O9 fast-follow):** "mirror `n_valid`" applies to *every* surface that aggregates istiod-sourced numbers, not just the new legibility block. The per-combo `aggregate()` in `004` had long gated its **counters/histograms** on `istiod_restarted==0` but ingested the **gauges** (memory, connected proxies, Go heap) unconditionally — the achieved-scale fix gated the headline block while the per-combo table still leaked a restarted row's mid-reconnect `connected_proxies` into `proxies_min/max/avg`. The trap: "gauges are point-in-time so they're always valid" is false across a restart — a gauge read mid-reconnect or just after a fresh start is a transient, just as suspect as a reset counter. When you gate one aggregation site on a validity predicate, grep for *every* `ingest()`/min/max/avg over the same row set and gate them identically; the only metrics that legitimately stay ungated are ones sourced independently of the failed component (here the proxy-side config-dump bytes).

## PL36 — A resilience "pre-create" of a shared artifact silently defeats a `! -f`-guarded fuller initializer: both writers must emit the identical key set

**Why:** To make provenance survive a first-combo failure (PL2/PL26 rationale), an orchestrator may **pre-create** the shared output file before the loop (here `003-run-sweep.sh:precreate_tsv_preamble` writes the TSV preamble up front). But the per-combo collector that *normally* writes that preamble guards its block on `! -f` (here `002`: "only write the preamble if the file doesn't exist yet"). The two interact destructively: once the pre-create runs, the collector's richer initialization is **skipped entirely**, so any key the pre-creator forgot is *never* written — not by the pre-creator (it didn't know about it) and not by the collector (its `! -f` guard short-circuited). The failure is invisible: the file exists, has a valid header, rows append fine, and only a *downstream reader* (`004`'s `preamble_get`) surfaces the gap as `unknown` — far from the cause, looking like a read bug or a metrics-availability problem rather than a write-path omission. In O9 this dropped five capacity-provenance lines (`NODE_ALLOC_*`, `ISTIOD_*_LIMIT`, `SCALE_TARGET_FRACTION`), hollowing out the entire "Achieved scale vs capacity" block on a sweep that read every value fine.

**How to preempt:** When more than one code path can create the same artifact and one of them guards on existence (`! -f`, `if not exists`, create-once), treat the writers as a **contract**: they must emit the *identical* key/field set, or the guard turns an optimization into silent data loss. (1) Factor the preamble/header emission into **one shared function** both callers invoke, so a new key can't be added to one writer and missed by the other. (2) If they must stay separate, add a test that **diffs the key set** the two writers produce (grep `^# [A-Z_]*=` from each, assert equality) — symmetry is the invariant, not any single key. (3) Make the downstream reader **loud about missing-but-expected** provenance: a required key resolving to `unknown` should be distinguishable from "legitimately N/A," ideally with a one-line diagnostic pointing at the write path, so the next occurrence is debugged at the source not the symptom. (4) When you add a key to the collector's preamble, grep for every *other* place that writes that preamble (the pre-create, any failed-row emitter) and add it there too — the `! -f` guard guarantees only the *first* writer's content reaches the file.

(PL36 was added after the O9 capacity-legibility fast-follow (#45): the 2026-06-04 clean pass reported `node allocatable: unknown / istiod limit: unknown` despite the reads succeeding, because `003`'s resilience pre-create omitted the capacity lines `002` would have written and `002`'s `! -f` guard then skipped its whole preamble block. Fixed by writing the capacity lines in the pre-creator too, recording `SCALE_SIZING_MODE` for downstream reproducibility, and the reproducibility reviewer flagging the residual `ISTIO_VERSION` vs `ISTIO_VERSION_TAG` / `CONTROLPLANE_SCHEMA` asymmetry between the two writers as the same class of latent gap.)

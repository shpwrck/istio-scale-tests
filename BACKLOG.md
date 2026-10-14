# Backlog

Open work for istio-scale-tests, moved here from GitHub issues (#84, #85, #86, #87, #88, #91) so
it travels with the repo. Status reflects the backlog PR of 2026-10-13 (tasks 2, 3, 5, 6 and 7),
validated on the existing-cluster lab: see
[`docs/campaigns/2026-10-13-lab-backlog-validation.md`](docs/campaigns/2026-10-13-lab-backlog-validation.md).
The original issue texts are in the appendix.

| # | Task | Status | Left / validate on |
| --- | --- | --- | --- |
| 1 | Namespace scaling factor (customer: thousands of namespaces, 1–5 services each) | Planned | lab for shape, ROSA for numbers |
| 2 | Per-cluster connected-proxy count + sanity check (was #85) | Done, lab-validated with 3 istiod replicas | campaign-scale check optional (ROSA) |
| 3 | East-west failures on some clusters (was #86) | Root cause confirmed on the lab (CA race); fix verified; harness reports unreachable remotes | AWS load-balancer checks (ROSA) |
| 4 | Capture istiod restart diagnostics (was #87) | Not started | needs a scale run to reproduce |
| 5 | Local baseline saturates one server replica (was #88) | Done, lab-validated | — |
| 6 | VirtualService/DestinationRule load in controlplane (was #84) | Done, lab-validated (shape) | numbers at scale (ROSA) |
| 7 | Shared `--config FILE` library (was #91) | Done for controlplane, dataplane, churn, churn-dataplane, propagation | tuning suite (follow-up) |

## 1. Namespace scaling factor

**Goal:** tell a customer with several thousand namespaces (one microservice or a handful of related
services each) how namespace count drives istiod and proxy cost.

**What exists:** the controlplane suite sweeps `--namespace-counts` (a fixed number of services
spread round-robin across N namespaces) × service count × replicas × mesh size × Sidecar scoping
(`none`/`namespace`/`explicit`), and reports istiod CPU/memory, xDS pushes, convergence p99 and
per-proxy config size. Multi-namespace runs were broken before #95 (only the last namespace was
created), so older namespace results are invalid.

**Plan (extend the controlplane suite, no new suite):**
- `--services-per-namespace K` growth mode: N namespaces × K services, swept over N (e.g. 100, 500,
  1000, 2000, 4000).
- Config-only option: Services without backing pods plus a small fixed set of measurement pods, since
  a node holds ~250 pods by default and the cost being measured is mostly config.
- Report the scaling factor as linear fits with the raw points: istiod memory/CPU per 100
  namespaces; per-proxy config size per namespace with and without per-namespace Sidecar scoping;
  push volume and convergence p99 vs namespace count.
- Open question for the customer: are all namespaces in the mesh? If not, also measure what
  `discoverySelectors` saves (add namespaces outside the mesh, with and without the label).

## 2. Per-cluster connected-proxy count + sanity check (was #85) — done

**Done:** every controlplane row carries `cluster_connected_proxies` (pilot_xds summed over the
cluster's istiod pods from one scrape batch; N/A on a short scrape or a changed pod set),
`sidecar_pods` (Running injected pods) and `proxy_check` (OK/LOW/HIGH against
`CONTROLPLANE_PROXY_CHECK_TOLERANCE_PCT` and `_MIN_DIFF`). The report and scale envelope show the
per-cluster peak next to the per-replica peak, plus a proxy-check tally with a warning. The 001
capacity preflight counts only non-terminal pods. The envelope reports the istiod replica count per
cluster (a range when members differ).

**Validated (lab):** with 3 istiod replicas on one member the per-replica values were 7/6/9 and the
per-cluster total 22, equal to the Running sidecar pods; 5 extra pods without proxies gave `LOW`.
This reproduces the campaign's ~1/3 reading as a per-replica value. Real under-connection at 10k
(hypothesis B) can no longer be ruled out retroactively; the next campaign's proxy check will show it.

## 3. East-west failures on some clusters (was #86) — root cause confirmed on the lab

**Confirmed (lab, 2026-10-13):** an istiod that starts before `cacerts` exists runs a self-signed
root and keeps it after `cacerts` arrives (it reads `cacerts` only at startup). Membership stays
`synced` while cross-cluster mTLS fails in both directions: the campaign's signature. Restarting
istiod (then the pods that started meanwhile) recovers it. The PreSync hook from #95 held a fresh
install for 270 s until ESO pushed `cacerts`, and istiod came up on the shared root; the gate flags
the mismatch when it happens.

**Not reproduced on MetalLB:** a released, rebuilt or re-addressed east-west LoadBalancer recovered
within about a second of its address returning, with no gateway restart.

**Harness (done):** dataplane and churn-dataplane check every remote before the load
(`tests/lib/reach.sh`, `reach-<RUN_ID>.tsv`), print a "Remote coverage" section in every report
format, and `--on-unreachable fail` / `--fail-on-unreachable` exit 3. churn-dataplane has
per-cluster `fortio-server-<ctx>` Services and an `ERROR_RATE_HIGH` rule.

**Left (ROSA):** ELB/NLB target registration and health checks after a gateway Service is rebuilt,
hostname-based LB addresses and DNS propagation, quota-late provisioning, and the 3-cluster
partial-mesh pattern (only pairs that include the bad cluster fail).

## 4. Capture istiod restart diagnostics (was #87)

**Left:** when a suite detects an istiod restart (`istiod_restarted=1`, `POISONED_RESTART`), save the
previous container's exit reason and code (`lastState.terminated`), its previous logs
(`oc logs --previous`), the pod's events, and memory at the time, next to the run's TSV. Then try to
reproduce under churn at mid scale (a few thousand services). The original restart happened at 20
clusters × 10k services and may need that scale.

**Validate:** force restarts (delete the pod, a low memory limit for an OOM, a failing probe) and
check each cause is captured correctly.

## 5. Local baseline saturates one server replica (was #88) — done

**Done:** `--server-replicas` (`DATAPLANE_SERVER_REPLICAS`, default 2) for the local and remote
targets alike; rows below `--min-qps-ratio` × target are `QPS_SHORTFALL`; the error-rate threshold is
`DATAPLANE_MIN_PCT_200`; fortio parsing lives in `tests/lib/fortio.sh`; the report always prints a
"Local baseline" verdict (OK, or DROPPED/DEGRADED/UNCHECKED/MISSING per cell with the reason).
The separate local-baseline QPS cap was dropped on purpose: it would hide saturation in a different
QPS cell. Runs from 2026-10-13 on are not directly comparable with the June runs (1 server pod).

**Validated (lab):** one starved replica delivered 88% of 1000 QPS and was flagged; two replicas
delivered 999.9 QPS with the local baseline OK at every level.

## 6. VirtualService/DestinationRule load in controlplane (was #84) — done

**Done:** opt-in sweep axis `--traffic-configs none,vsdr` with `--vsdr-every N` and
`--vsdr-subsets N`: a VirtualService (weighted route, timeout, retries) and a DestinationRule
(subsets, connectionPool, outlierDetection) per configured Service, replicas split over one
Deployment per subset. The report pairs none and vsdr cells (istiod cost, per-proxy clusters and
CDS/RDS bytes). The `none` render is unchanged.

**Validated (lab, 10 services):** +20 clusters per proxy (10 × 2 subsets), CDS +115%, RDS +66%.
istiod cost deltas need hundreds to thousands of services (ROSA).

## 7. Shared `--config FILE` library (was #91) — done except tuning

**Done:** `tests/lib/config.sh` parses (never sources) `KEY=value` run configs against a per-suite
allowlist from `config/options.env`; precedence flag > config > env > default, with no change when
`--config` is absent. Every numbered script of controlplane, dataplane, churn, churn-dataplane and
propagation accepts `--config`; TSV preambles and every report format record `RUN_CONFIG` and its
sha256, and each sweep keeps a copy of the config. Worked examples: `tests/<suite>/configs/`.

**Left:** the tuning suite (it chains the other suites), and centralizing the per-script flag
parsers.

## Follow-ups found during the 2026-10-13 work

- churn suite: `source/remote_connected_proxies` use the lenient `fanout_gauge_sum`, which
  undercounts silently when a pod scrape fails (PL29); switch to `fanout_gauge_sum_strict`.
- churn-dataplane: adopt the dataplane `--server-replicas` knob and the `QPS_SHORTFALL` rule.
- Propagation: use a VS/DR change (route weight flip) as a propagation trigger.
- Local baseline verdict checks delivered QPS and errors, not tail latency (two throttled replicas
  were OK with a 31 ms local p99).
- Scale envelope: optional mesh-wide proxy total (sum of per-cluster totals per scrape window).
- controlplane 001 `--dry-run` needs a reachable cluster (server-side dry-run apply).
- Dataplane local-baseline verdict still reads "OK at every QPS level" when a mesh size has OK
  local cells plus a failed repetition's placeholder (the placeholder is named next to it).
- churn-dataplane records `ISTIOD_REPLICAS` for the source context only (what its probe measures);
  the controlplane suite now probes every context.
- `reach_sanitize` masks an unbracketed IPv6 address without `::` only from 4 groups on (a
  3-group form is indistinguishable from HH:MM:SS).
- `PROPAGATION_METRICS_TIMEOUT` is not checked up front by the propagation sweep.
- controlplane `--resume` treats two `unknown` config hashes (no sha256 tool) as equal.

## Validation environment

The lab covered tasks 2, 3 (except AWS load balancers), 5 and 6 at small size: 3 istiod replicas
fit on one member at the lab's istiod sizing. What still needs ROSA: task 3's AWS load-balancer
checks, task 6 numbers at hundreds to thousands of services, and task 1's customer-grade numbers.
Plan: one concentrated window
([`docs/runbooks/rosa-validation/window-plan.md`](docs/runbooks/rosa-validation/window-plan.md)):
Tier C (owner decision, 2026-10-13). It is a hub plus 3 members: `<mesh-a-ctx>` on 3× r7i.2xlarge,
the other two on 3× m7i.xlarge. It costs $8.25/hour: about $65 core and at most $77 extended (prices
checked 2026-10-13). The worst case is about $81, under the owner's $100 hard cap, because
`terraform/rosa-hcp/scripts/003-auto-teardown.sh` tears the clusters down on a timer at T0+8:15.
Task 6 runs in pods mode at 150 and 250 services × 2 replicas on mesh-a. Tasks 1 and 4 get their
first live runs there, because the lab was powered off; each starts with a smoke step and a go/no-go.
Tier B ($6.75/hour, at most about $60) is the fallback. Reproducing task 4's original restart, or
confirming task 3 at the original 19-cluster scale, needs a 20-cluster run (about $26/hour with 2×
m7i.xlarge members, about $248/hour shaped like the June campaign); only do that if the small runs
don't settle it.

---

## Appendix: original issue texts

### Original issue #85: investigate: controlplane connected_proxies reads ~200/cluster at 10k (expected ~500); mislabeled 'mesh-wide'
#### Observation

In the 2026-06-22 20c/10k campaign (controlplane sweeps `sweep-20260622T165640Z` / `sweep-20260622T174414Z`), the `connected_proxies` metric read **~186–207 per cluster** (one value per context row in the controlplane TSV; max 207).

Two problems:

1. **The value is too low.** Each cluster ran **500 Services × 1 replica = ~500 sidecar-injected workload pods**, so each cluster's istiods should see **~500 connected proxies** (one `pilot_xds` connection per proxy). We observed **~200/cluster** — roughly **1/3** of expected, which is suspiciously close to **500 ÷ 3 istiod replicas ≈ 167**.

2. **The scale-envelope mislabels it.** `tests/lib/envelope.sh` renders `connected_proxies_max` as the **'mesh-wide proxy count'**, but it is a **per-cluster (peak)** value, not a mesh-wide sum. Mesh-wide there are ~10,000 sidecars. (This number was **dropped from the customer brief** for being confusing/incorrect — Red Hat → <customer> 20c/10k validation.)

#### Hypotheses to test
- **(A) Scrape/fan-out artifact (most likely):** `pilot_xds` is a per-istiod-pod gauge; a single scrape sees only ~1/replicas of a cluster's proxies. `tests/lib/fanout.sh` intends to `extract_gauge_sum` per pod and **sum across pods** (see comments ~L8/L32/L396), but the observed ~200 ≈ 500/3 suggests the **cross-replica summation is not actually capturing all 3 istiod replicas** (e.g. only one replica scraped, or port-forward fan-out missing pods).
- **(B) Real under-connection:** not all 500 sidecars per cluster were connected/synced at the 10k peak (genuine finding — would matter for scale claims).
- **(C) Fewer proxies than assumed:** the controlplane chart deploys fewer sidecar'd pods than services×replicas (verify the chart).

#### Where to look
- `tests/lib/fanout.sh` — the `pilot_xds` gauge collection + cross-pod summation.
- `tests/lib/metrics.sh` — `extract_gauge_sum`.
- `tests/controlplane/002-collect-resource-metrics.sh` — how `connected_proxies` is assembled per row.
- `tests/lib/envelope.sh` — the 'mesh-wide proxy count' label (fix to 'per-cluster peak').

#### Outcome
Determine whether ~200 is a measurement artifact (A/C — fix the metric + the envelope label) or a real connection gap (B — a scale finding). Either way, correct the scale-envelope wording so the number is honest, and add a sanity check (connected_proxies vs scheduled sidecar pods).

Filed from the campaign retrospective.



### Original issue #86: investigate: cross-cluster east-west data-plane fails on 7 of 19 clusters (007-012, 014) — 12/19 coverage, root cause unconfirmed
#### Observation

In the 2026-06-22 20c/10k campaign, the **data-plane** and **churn-dataplane** suites captured valid cross-cluster traffic for only **12 of 19 remote clusters** — both runs. The same 7 clusters failed every time: **cluster-007, 008, 009, 010, 011, 012, 014**.

- Their **control-plane membership was healthy** throughout (`istioctl remote-clusters` synced; gateways/LBs showed Ready).
- Yet **cross-cluster mTLS traffic through their east-west gateway load balancers failed** (no latency data returned).

#### Best hypothesis (NOT confirmed)

The 7 failing clusters are exactly the ones whose **east-west gateway LoadBalancer Services were (re)provisioned late** — after the AWS Classic-ELB quota was raised mid-campaign — **and** were churned by the gateway HPA→fixed-replica pin. This points to a **load-balancer target-registration / SNI-passthrough artifact** on the reprovisioned ELBs, i.e. the NLB/ELB never (re)registered the gateway pod targets after the Service was rebuilt.

Suspected remediation: **re-register the LB targets / restart the east-west gateway pods** on the affected clusters (NOT istiod — istiod was healthy). This was **left unconfirmed at teardown** (out of budget), so it remains a hypothesis.

#### Why it matters

- It silently halved-ish the cross-cluster data-plane coverage and forced the customer brief to caveat 12/19.
- If it is a real reprovision/registration race, it can recur on any campaign that raises LB quota mid-run or churns gateways.

#### Asks
1. **Reproduce**: provision a spoke's east-west gateway LB *late* (or delete+recreate the Service) and check whether cross-cluster traffic registers without a gateway-pod restart.
2. **Confirm or refute** the LB-target-registration hypothesis (compare target groups / endpoints on a healthy vs failing cluster).
3. **Harness**: make the data-plane / churn-dataplane suites **surface partial coverage loudly** (e.g. fail or warn with the list of unreachable remotes) instead of silently returning n_valid<n_total.

Filed from the 20c/10k campaign retrospective. Related: bare-Services traffic-management gap #84.



### Original issue #87: investigate: istiod restarted mid-run during churn convergence sweep (POISONED_RESTART) at 20c/10k
#### Observation

In the 2026-06-22 20c/10k campaign, the **churn convergence** sweep (`tests/churn/results/sweep-20260622T221037Z-3665828`) recorded **iteration 3 as `POISONED_RESTART`** — istiod actually restarted mid-iteration (a ~345s recovery gap before iteration 4). 5 of 6 completed iterations were valid; iteration 3 was correctly excluded.

#### Why it's worth a look

- istiod **RSS at the 10k peak was only ~19%** of the 16 GiB limit, so this was **not** a memory-ceiling OOM — the cause is unclear.
- The campaign results doc attributed that churn run's low n to the `grep -c` arithmetic bug (since fixed, **PR #82**) and **does not mention the restart** — so the restart itself is currently unexplained/undocumented.
- An istiod restart **under configuration churn at 10k scale** is a control-plane stability signal that should be root-caused before it's dismissed.

#### Asks
1. Pull the istiod pod's **prior-container logs / exit reason / events** for that window if still available (or reproduce a churn run and watch for restarts).
2. Determine whether it was an **OOMKill** (cgroup memory vs the 16Gi limit — RSS top was 19% but transient spikes under churn could differ), a **liveness-probe timeout**, or a **crash**.
3. If reproducible under churn, file a follow-up with the mechanism; if a one-off infra blip, note and close.

Context: push amplification stayed ~1× (0.8–1.2, n=5) and local convergence ~7s on the valid iterations, so steady-state churn behavior looked healthy apart from this single restart.

Filed from the 20c/10k campaign retrospective.



### Original issue #88: harness: data-plane same-cluster (local) baseline saturates single test-server replica → n_valid=0 at high QPS
#### Observation

In the 2026-06-22 20c/10k campaign, the **data-plane** suite's **same-cluster (local) baseline** rows came back `n_valid=0` at the higher QPS levels in **both** runs — the local echo/test server is a **single replica** and saturated (sustained ~686 of 1000 target QPS), tripping `ERROR_RATE_HIGH`.

Consequence: there was **no usable same-cluster latency baseline** from the data-plane suite itself. The customer brief had to source its ~2.8 ms same-cluster figure from the **churn-dataplane** baseline instead, and the cross-cluster 'hop adds X ms' comparison is weaker than it should be.

This is a **test-workload sizing artifact, not a mesh effect** — but it degrades a metric the suite is supposed to produce.

#### Asks
1. **Scale the local test/echo server** (multiple replicas, or a higher-throughput server) so the same-cluster baseline survives the top QPS levels — OR
2. **Cap the local-baseline QPS** to a level the single replica can serve cleanly (decouple local-baseline QPS from the cross-cluster sweep QPS), and/or
3. Make the suite **report explicitly** when the local baseline is saturated/dropped (so a downstream reader knows the same-cluster number is missing rather than silently absent).

Goal: the data-plane suite should always yield a trustworthy same-cluster baseline to anchor the cross-cluster hop delta.

Filed from the 20c/10k campaign retrospective.



### Original issue #84: test(controlplane): add basic Istio traffic-management resources (VirtualService/DestinationRule) to reflect configured-mesh config scale
#### Motivation

The scale suites deploy **bare `Service` objects + sidecar injection** plus the tuned baseline (sidecar scoping, discovery selectors, telemetry/access-log filtering). They do **not** create VirtualServices or DestinationRules.

Real production meshes carry VS/DR per service (routing, retries, timeouts, subsets, outlier detection, connection pools). These are config istiod must **compute into Envoy config, cache (mesh-wide in multi-primary), and push via xDS** — so they materially increase control-plane load.

In the **2026-06-22 20c/10k campaign** (`docs/campaigns/2026-06-22-20c-10k-10k-results.md`), istiod sat at **~19% of its 16Gi mem limit and ~3% CPU** at 10,000 Services. That headroom is **optimistic relative to a fully-configured production mesh** — a mesh with VS/DR at the same Service count consumes more istiod memory/CPU and slows convergence. The campaign measures **Service-object scale, not configured-mesh config scale**, and the customer brief notes this as a boundary.

#### Proposal

Add basic, **representative** Istio traffic-management resources to the test workloads where it makes sense, behind a **toggle/axis** so bare-vs-configured can be compared (the delta is the interesting number):

- **Control-plane suite (primary):** optional VirtualService + DestinationRule per Service (or per N Services). Keep them basic but real — e.g. a VS with a route + retry/timeout, a DR with ~2 subsets + a connection pool / outlier detection — enough to exercise RDS route expansion + CDS subset/EDS-per-subset expansion without being arbitrary.
- **Propagation suite (secondary):** a VS/DR change is a realistic propagation trigger; consider exercising it.
- **Data-plane suite:** lower priority — basic routing VS/DR don't materially change request latency (unless DR enables path-altering features); only worth it to test outlier-detection/conn-pool behavior.

#### What to measure
- istiod **memory (RSS) / CPU / push-cost / convergence** delta vs. bare Services at the same Service count.
- Per-proxy config size delta (RDS/CDS growth).

#### Scope notes
- Make density **and** complexity configurable so it doesn't bloat the default sweep but can be turned on for a 'configured production mesh' run.
- Route the harness change through `/scale-test-review` per the contributing process.

Filed from the campaign retrospective (Red Hat → <customer> 20c/10k validation).



### Original issue #91: harness: shared config-file library so suite scripts take a --config FILE instead of re-tracking every parameter
#### Problem

Every numbered script in each suite (`controlplane`, `dataplane`, `churn`, `churn-dataplane`, `propagation`, `tuning`) hand-rolls its own long parameter surface — a large `--flag`/getopts-style parser plus a parallel set of environment-variable defaults (`SETUP_CONTEXTS`, `CONTROLPLANE_SERVICE_COUNT`, `CONTROLPLANE_REPLICAS_PER_SERVICE`, sweep matrix knobs, `--sidecar-scopings`, `--settle`, `--output-dir`, …), with deprecated aliases layered on top.

Two costs fall out of this:

1. **Operator burden — every parameter must be re-tracked and re-passed across the whole 5–7 step lifecycle of a suite.** A single experiment is defined by the same contexts / service counts / scoping / matrix passed to `001-setup`, `002`, `003-run-sweep`, `004-report`, and `005-cleanup`. Today that lives in the operator's shell history (or a wrapper they wrote themselves). There's no single artifact that *is* the run definition, which hurts reproducibility — a property the suites otherwise take seriously (TSV preamble metadata, per-sweep output subdirs, run identifiers).
2. **Maintenance burden — the arg-parsing boilerplate is duplicated per script.** Adding or renaming a parameter means editing the parser, the usage text, and the env-var default block in N places, and keeping the deprecated-alias warnings consistent.

`config/options.env` + `config/versions.env` already cover *operational* defaults (sourced env), but per-run *experiment* parameters have no equivalent — they must be threaded by flag/env into each step individually.

#### Proposal

Add a **shared config-file library** under `tests/lib/` (e.g. `tests/lib/config.sh`, sibling to `common.sh`) that any numbered script can source to accept a `--config FILE` carrying the run's parameters, so the operator defines a run once and replays it across every step of the suite.

Suggested shape (to be refined in design):

- A single loader, `load_config <file>`, that reads a declarative config (env-style `KEY=value`, reusing the existing `options.env` precedent, or a small TSV/YAML if we want structure) and populates the same variables the scripts already consume — so it layers cleanly under the existing env-var defaults.
- **Precedence stays explicit and documented:** explicit CLI flag > `--config FILE` value > env var > built-in default. This keeps every current invocation working unchanged (no config = today's behavior) while letting a config file replace a wall of flags.
- Centralize the repeated per-flag parse/validate/alias-warn logic the loader and parsers share, leaning on the existing helpers in `common.sh` (`split_csv`, `is_pos_int`, `validate_scoping`, …).
- Keep it **shared and suite-agnostic**: the library handles loading + precedence + validation generically; each suite declares which keys it honors.

#### Acceptance

- New `tests/lib/config.sh` sourced by the suite scripts; `--config FILE` accepted by at least the multi-step suites' scripts.
- Documented precedence order (flag > config > env > default), with no behavior change when `--config` is absent.
- One worked example config checked in (or in a suite README) showing a full run defined in a single file and replayed across `setup → sweep → report → cleanup`.
- Help text on each affected script mentions `--config`.
- Existing flags/env vars and their deprecation warnings continue to work (backward compatible).

#### Notes / open questions

- Config format: env-style (`source`-able, matches `options.env`) is the lowest-friction option and reuses existing infra; a structured format (YAML/TSV) is more validatable but adds a parser dependency. Decide in design.
- Scope: land the library + one suite (`controlplane` is the richest parameter surface) as a tracer-bullet slice, then fan out to the other suites in follow-ups.




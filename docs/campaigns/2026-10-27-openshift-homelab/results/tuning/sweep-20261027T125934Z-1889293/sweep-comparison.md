---
suite: "propagation"
run_id: "20261027T125934Z-1889293"
contexts: "<mesh-a-ctx>,<mesh-b-ctx>"
passes: "baseline,01-push-throttling,02-xds-cache-off,03-gateway-cluster-filter,04-connection-pools"
istio_version: "v1.30.5"
istio_version_source: "live"
istio_version_pin: "v1.30.5"
istio_version_by_context: "<mesh-a-ctx>=v1.30.5,<mesh-b-ctx>=v1.30.5"
istio_active_revisions: "<mesh-a-ctx>=default,<mesh-b-ctx>=default"
istio_generations: "mixed:<mesh-a-ctx>=3/3,<mesh-b-ctx>=3/3 | <mesh-a-ctx>=4/4,<mesh-b-ctx>=4/4 | <mesh-a-ctx>=6/6,<mesh-b-ctx>=6/6 | <mesh-a-ctx>=8/8,<mesh-b-ctx>=8/8 | <mesh-a-ctx>=9/9,<mesh-b-ctx>=9/9"
harness_sha: "d21a197"
settle_sec: 60
---

# Tuning sweep comparison

- Suite: propagation
- Run: 20261027T125934Z-1889293
- Contexts: <mesh-a-ctx>,<mesh-b-ctx>
- Istio: v1.30.5 (source live, pin v1.30.5; by member <mesh-a-ctx>=v1.30.5,<mesh-b-ctx>=v1.30.5)
- HARNESS_SHA=d21a197 (the sweep's)
- SETTLE_SEC=60 (each pass's wait after its apply, before its probe)
- Active revisions and Istio CR generations (the sweep's start and its passes): ISTIO_ACTIVE_REVISIONS=<mesh-a-ctx>=default,<mesh-b-ctx>=default; ISTIO_GENERATIONS=mixed:<mesh-a-ctx>=3/3,<mesh-b-ctx>=3/3 | <mesh-a-ctx>=4/4,<mesh-b-ctx>=4/4 | <mesh-a-ctx>=6/6,<mesh-b-ctx>=6/6 | <mesh-a-ctx>=8/8,<mesh-b-ctx>=8/8 | <mesh-a-ctx>=9/9,<mesh-b-ctx>=9/9
- Platform record of the baseline: openshift (TEST_PLATFORM auto); nodes none; operator servicemeshoperator3:3.4.3; istiod istio-pilot-rhel9@sha256:0153604b88f0; gateway proxy istio-proxyv2-rhel9@sha256:b722c0999b94; Kubernetes v1.34.8
- Values are means over the samples the propagation report (005) counts: P1 once per iteration, left out only for a source-side reason (p1_status other than OK or DRAIN_TIMEOUT, a +Inf overflow, a source scrape skew over FANOUT_MAX_SKEW_MS; a remote that timed out or restarted keeps it), P2 and P3 per remote row, left out only for that remote's side (remote_status other than OK or DRAIN_TIMEOUT, its scrape skew over FANOUT_MAX_SKEW_MS; the source's restart, P1 timeout or overflow keeps them); "(N overflowed)" in the P1 local push cell counts the iterations its mean leaves out for a +Inf overflow. Profiles show the change against the baseline in brackets.
- "Platform record" compares each pass with the baseline on its platform, builds, node provider, Kubernetes versions, tuning levers, root Sidecar egress hosts and istiod limits and replica counts, as its TSVs record them: a key that differs warns with both values, one not read on a side is a note. "istiod env" is each pass's digest of istiod's settings, which a profile changes.
- "Drain timeouts (iterations, counted)" (shown when a pass has one): iterations whose drain after the window timed out (DRAIN_TIMEOUT). Their values count, as in 005: they were measured before that drain.
- Under each metric: n is got/attempted (valid samples with a value / what the probe was configured to take where its TSV records it, else every row the pass wrote, failed and timed-out rows included) and range is its min to max.
- Histogram p99 rows ("worst bucket") are never averaged: they show the highest bucket range a valid row hit, or "overflow (N rows)" when N rows had their p99 in the +Inf bucket (propagation's P1 convergence: "overflow (N iterations)" when N iterations put a sample in the +Inf bucket, whatever their p99; counted although 005 leaves those iterations out of its means).

> **Sweep outcome** (`sweep-20261027T125934Z-1889293`): all 5 passes ran

| Metric | baseline | 01-push-throttling | 02-xds-cache-off | 03-gateway-cluster-filter | 04-connection-pools |
|---|---|---|---|---|---|
| Pass status | ok | ok | ok | ok | ok |
| Valid / total rows | 10/10 | 10/10 | 10/10 | 10/10 | 10/10 |
| Platform record | baseline | same | same | same | same |
| istiod env | 0c3d8d887772 | 0a5358173660 | 5ba384260ad7 | 28068f61ea8b | 0c3d8d887772 |
| P1 local push (ms) | 647.40 | 636.80 (-1.6%) | 638.00 (-1.5%) | 663.80 (+2.5%) | 642.50 (-0.8%) |
|   n (got/attempted) | 10/10 | 10/10 | 10/10 | 10/10 | 10/10 |
|   range (min to max) | 604.00 to 732.00 | 599.00 to 684.00 | 605.00 to 675.00 | 634.00 to 734.00 | 612.00 to 688.00 |
| P2 remote EDS (ms) | 641.60 | 634.20 (-1.2%) | 635.30 (-1.0%) | 660.30 (+2.9%) | 641.50 (-0.0%) |
|   n (got/attempted) | 10/10 | 10/10 | 10/10 | 10/10 | 10/10 |
|   range (min to max) | 602.00 to 733.00 | 596.00 to 681.00 | 601.00 to 672.00 | 632.00 to 731.00 | 609.00 to 686.00 |
| P3 remote sidecar (ms) | 1336.10 | 1332.80 (-0.2%) | 1334.40 (-0.1%) | 1355.20 (+1.4%) | 1337.60 (+0.1%) |
|   n (got/attempted) | 10/10 | 10/10 | 10/10 | 10/10 | 10/10 |
|   range (min to max) | 1298.00 to 1412.00 | 1294.00 to 1377.00 | 1298.00 to 1372.00 | 1326.00 to 1418.00 | 1307.00 to 1385.00 |
| P1 convergence p99 worst bucket (ms) | - | - | - | - | - |
|   n (got/attempted) | 0/10 | 0/10 | 0/10 | 0/10 | 0/10 |
|   range (min to max) | - | - | - | - | - |

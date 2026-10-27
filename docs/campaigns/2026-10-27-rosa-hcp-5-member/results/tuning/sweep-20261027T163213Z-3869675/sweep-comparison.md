---
suite: "propagation"
run_id: "20261027T163213Z-3869675"
contexts: "<mesh-a-ctx>,<mesh-b-ctx>,<mesh-c-ctx>,<mesh-d-ctx>,<mesh-e-ctx>"
passes: "baseline,01-push-throttling,02-xds-cache-off,03-gateway-cluster-filter,04-connection-pools"
istio_version: "v1.30.5"
istio_version_source: "live"
istio_version_pin: "v1.30.5"
istio_version_by_context: "<mesh-a-ctx>=v1.30.5,<mesh-b-ctx>=v1.30.5,<mesh-c-ctx>=v1.30.5,<mesh-d-ctx>=v1.30.5,<mesh-e-ctx>=v1.30.5"
istio_active_revisions: "<mesh-a-ctx>=default,<mesh-b-ctx>=default,<mesh-c-ctx>=default,<mesh-d-ctx>=default,<mesh-e-ctx>=default"
istio_generations: "mixed:<mesh-a-ctx>=1/1,<mesh-b-ctx>=1/1,<mesh-c-ctx>=1/1,<mesh-d-ctx>=1/1,<mesh-e-ctx>=1/1 | <mesh-a-ctx>=2/2,<mesh-b-ctx>=2/2,<mesh-c-ctx>=2/2,<mesh-d-ctx>=2/2,<mesh-e-ctx>=2/2 | <mesh-a-ctx>=4/4,<mesh-b-ctx>=4/4,<mesh-c-ctx>=4/4,<mesh-d-ctx>=4/4,<mesh-e-ctx>=4/4 | <mesh-a-ctx>=6/6,<mesh-b-ctx>=6/6,<mesh-c-ctx>=6/6,<mesh-d-ctx>=6/6,<mesh-e-ctx>=6/6 | <mesh-a-ctx>=7/7,<mesh-b-ctx>=7/7,<mesh-c-ctx>=7/7,<mesh-d-ctx>=7/7,<mesh-e-ctx>=7/7"
harness_sha: "d21a197"
settle_sec: 60
---

# Tuning sweep comparison

- Suite: propagation
- Run: 20261027T163213Z-3869675
- Contexts: <mesh-a-ctx>,<mesh-b-ctx>,<mesh-c-ctx>,<mesh-d-ctx>,<mesh-e-ctx>
- Istio: v1.30.5 (source live, pin v1.30.5; by member <mesh-a-ctx>=v1.30.5,<mesh-b-ctx>=v1.30.5,<mesh-c-ctx>=v1.30.5,<mesh-d-ctx>=v1.30.5,<mesh-e-ctx>=v1.30.5)
- HARNESS_SHA=d21a197 (the sweep's)
- SETTLE_SEC=60 (each pass's wait after its apply, before its probe)
- Active revisions and Istio CR generations (the sweep's start and its passes): ISTIO_ACTIVE_REVISIONS=<mesh-a-ctx>=default,<mesh-b-ctx>=default,<mesh-c-ctx>=default,<mesh-d-ctx>=default,<mesh-e-ctx>=default; ISTIO_GENERATIONS=mixed:<mesh-a-ctx>=1/1,<mesh-b-ctx>=1/1,<mesh-c-ctx>=1/1,<mesh-d-ctx>=1/1,<mesh-e-ctx>=1/1 | <mesh-a-ctx>=2/2,<mesh-b-ctx>=2/2,<mesh-c-ctx>=2/2,<mesh-d-ctx>=2/2,<mesh-e-ctx>=2/2 | <mesh-a-ctx>=4/4,<mesh-b-ctx>=4/4,<mesh-c-ctx>=4/4,<mesh-d-ctx>=4/4,<mesh-e-ctx>=4/4 | <mesh-a-ctx>=6/6,<mesh-b-ctx>=6/6,<mesh-c-ctx>=6/6,<mesh-d-ctx>=6/6,<mesh-e-ctx>=6/6 | <mesh-a-ctx>=7/7,<mesh-b-ctx>=7/7,<mesh-c-ctx>=7/7,<mesh-d-ctx>=7/7,<mesh-e-ctx>=7/7
- Platform record of the baseline: openshift (TEST_PLATFORM auto); nodes aws; operator servicemeshoperator3:3.4.3; istiod istio-pilot-rhel9@sha256:0153604b88f0; gateway proxy istio-proxyv2-rhel9@sha256:b722c0999b94; Kubernetes v1.34.6
- Values are means over the samples the propagation report (005) counts: P1 once per iteration, left out only for a source-side reason (p1_status other than OK or DRAIN_TIMEOUT, a +Inf overflow, a source scrape skew over FANOUT_MAX_SKEW_MS; a remote that timed out or restarted keeps it), P2 and P3 per remote row, left out only for that remote's side (remote_status other than OK or DRAIN_TIMEOUT, its scrape skew over FANOUT_MAX_SKEW_MS; the source's restart, P1 timeout or overflow keeps them); "(N overflowed)" in the P1 local push cell counts the iterations its mean leaves out for a +Inf overflow. Profiles show the change against the baseline in brackets.
- "Platform record" compares each pass with the baseline on its platform, builds, node provider, Kubernetes versions, tuning levers, root Sidecar egress hosts and istiod limits and replica counts, as its TSVs record them: a key that differs warns with both values, one not read on a side is a note. "istiod env" is each pass's digest of istiod's settings, which a profile changes.
- "Drain timeouts (iterations, counted)" (shown when a pass has one): iterations whose drain after the window timed out (DRAIN_TIMEOUT). Their values count, as in 005: they were measured before that drain.
- Under each metric: n is got/attempted (valid samples with a value / what the probe was configured to take where its TSV records it, else every row the pass wrote, failed and timed-out rows included) and range is its min to max.
- Histogram p99 rows ("worst bucket") are never averaged: they show the highest bucket range a valid row hit, or "overflow (N rows)" when N rows had their p99 in the +Inf bucket (propagation's P1 convergence: "overflow (N iterations)" when N iterations put a sample in the +Inf bucket, whatever their p99; counted although 005 leaves those iterations out of its means).

> **Sweep outcome** (`sweep-20261027T163213Z-3869675`): all 5 passes ran

| Metric | baseline | 01-push-throttling | 02-xds-cache-off | 03-gateway-cluster-filter | 04-connection-pools |
|---|---|---|---|---|---|
| Pass status | ok | ok | ok | ok | ok |
| Valid / total rows | 40/40 | 40/40 | 40/40 | 40/40 | 40/40 |
| Platform record | baseline | same | same | same | same |
| istiod env | 0c3d8d887772 | 0a5358173660 | 5ba384260ad7 | 28068f61ea8b | 0c3d8d887772 |
| P1 local push (ms) | 617.60 | 1118.10 (+81.0%) | 662.80 (+7.3%) | 629.60 (+1.9%) | 655.20 (+6.1%) |
|   n (got/attempted) | 10/10 | 10/10 | 10/10 | 10/10 | 10/10 |
|   range (min to max) | 586.00 to 659.00 | 1095.00 to 1142.00 | 618.00 to 775.00 | 593.00 to 718.00 | 611.00 to 705.00 |
| P2 remote EDS (ms) | 657.73 | 1081.30 (+64.4%) | 653.95 (-0.6%) | 612.70 (-6.8%) | 619.17 (-5.9%) |
|   n (got/attempted) | 40/40 | 40/40 | 40/40 | 40/40 | 40/40 |
|   range (min to max) | 609.00 to 762.00 | 1025.00 to 1139.00 | 572.00 to 791.00 | 560.00 to 711.00 | 559.00 to 672.00 |
| P3 remote sidecar (ms) | 640.27 | 1933.90 (+202.0%) | 678.30 (+5.9%) | 652.25 (+1.9%) | 792.85 (+23.8%) |
|   n (got/attempted) | 40/40 | 40/40 | 40/40 | 40/40 | 40/40 |
|   range (min to max) | 573.00 to 739.00 | 1847.00 to 3149.00 | 595.00 to 817.00 | 549.00 to 770.00 | 620.00 to 1981.00 |
| P1 convergence p99 worst bucket (ms) | - | - | - | - | - |
|   n (got/attempted) | 0/10 | 0/10 | 0/10 | 0/10 | 0/10 |
|   range (min to max) | - | - | - | - | - |

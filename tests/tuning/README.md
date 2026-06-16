# Performance Tuning Test Suite

Apply Istio tuning profiles to a live mesh, measure their impact using the
existing test suites, and compare results across profiles.

## How It Works

1. **001-apply-profile.sh** patches the Istio CR and deploys any additional
   resources (Sidecar CRs, Telemetry API objects, DestinationRules) defined
   by a profile.
2. The operator runs one or more existing test suite probes (controlplane,
   propagation, dataplane, churn, churn-dataplane) against the tuned mesh.
3. **002-revert-profile.sh** restores the Istio CR to its pre-patch state
   and deletes any resources the profile deployed.
4. **003-run-tuning-sweep.sh** automates the full cycle: for each profile,
   apply → run probes → collect results → revert.
5. **004-compare-profiles.sh** reads results across profile-tagged
   subdirectories and emits a side-by-side comparison.

## Profiles

Each profile is a YAML file under `profiles/` containing:

- A human-readable description and expected impact
- An `ossm_support` field indicating Red Hat support status
- An `istio_cr_patch` (strategic-merge patch for the Istio CR)
- A `resources` list (additional Kubernetes objects to apply)

### OSSM Support Status

| Status | Meaning |
|--------|---------|
| `supported` | Fully supported on OSSM 3.x. Documented by Red Hat as a standard Istio API or Sail operator field. |
| `configurable` | Mechanically works via the Sail operator's Helm values passthrough (`spec.values.pilot.env`) but NOT explicitly documented by Red Hat for OSSM 3. Red Hat support coverage for issues caused by non-default values is uncertain. |
| `not-supported-multicluster` | Supported on OSSM for single-cluster only. Not available for multicluster topologies. |
| `not-supported` | Requires external projects not included in or supported by OSSM. |

### Profile Summary

| # | Profile | Tier | OSSM Support | Primary Lever | Expected Impact |
|---|---------|------|-------------|---------------|-----------------|
| 01 | sidecar-scoping | 1 | **Supported** | Sidecar CR in root namespace | 80-95% proxy config size reduction |
| 02 | discovery-selectors | 1 | **Supported** | meshConfig.discoverySelectors | istiod ignores non-mesh namespaces |
| 03 | push-throttling | 1 | **Configurable** | PILOT_DEBOUNCE_*, PILOT_PUSH_THROTTLE | Fewer push storms, lower CPU |
| 04 | istiod-resources | 1 | **Supported** | pilot resources (GOMEMLIMIT auto-derived) | Prevents OOM, faster pushes |
| 05 | proxy-resources | 1 | **Supported** | global.proxy.resources | Eliminates sidecar CPU throttling |
| 06 | xds-cache-tuning | 2 | **Configurable** | Disable CDS/RDS cache | Lower propagation delay (CPU tradeoff) |
| 07 | telemetry-filtering | 2 | **Supported** | Telemetry API metric overrides | 40-50% metric volume reduction |
| 08 | access-log-filtering | 2 | **Supported** | Telemetry API access log filter | 95-99% log volume reduction |
| 09 | gateway-scoping | 2 | **Configurable** (experimental upstream) | PILOT_FILTER_GATEWAY_CLUSTER_CONFIG | Gateway config size reduction |
| 10 | envoy-concurrency | 3 | **Supported** | meshConfig.defaultConfig.concurrency | Match threads to CPU limits |
| 11 | traffic-exclusions | 3 | **Supported** | proxy.excludeOutboundPorts | Bypass proxy for DB/cache ports |
| 12 | connection-pools | 3 | **Supported** | DestinationRule connection pool | Circuit breaking + load distribution |
| 13 | dns-proxy | 3 | **Supported** | DNS capture + auto-allocate | Reduced CoreDNS pressure |

### Profiles Using Undocumented Pilot Env Vars (Configurable)

**03-push-throttling**, **06-xds-cache-tuning**, and **09-gateway-scoping**
use `PILOT_*` environment variables set through `spec.values.pilot.env` in
the Sail operator Istio CR. The Sail operator passes all Helm chart values
through to Istio, so these variables are mechanically configurable. However,
Red Hat does not document individual pilot env vars for OSSM 3 — they defer
to upstream Istio documentation.

What this means in practice:
- The variables **work** — they are standard upstream Istio features used in
  production by Airbnb, Expedia, and many others.
- Red Hat **support coverage** for issues caused by non-default pilot env var
  values is uncertain. Red Hat may ask you to reproduce issues with default
  values before investigating.
- **09-gateway-scoping** uses `PILOT_FILTER_GATEWAY_CLUSTER_CONFIG`, which
  is defined in `pilot/pkg/features/experimental.go` upstream and has known
  stability issues (#29131, #37997, #44439). This is the highest-risk profile
  in the configurable set.

**04-istiod-resources** is fully GA (pilot resources are documented and
supported). `GOMEMLIMIT` is auto-derived from `limits.memory` by the istiod
Helm chart via a `resourceFieldRef`. Do **not** set `GOMEMLIMIT` manually via
`pilot.env` — the Deployment will have both `value` and `valueFrom` on the
same env var, which Kubernetes rejects, causing Sail operator reconciliation
to fail silently (limits are dropped from the Deployment).

## Prerequisites

- `oc` or `kubectl`, `jq`, `yq` (v4+)
- Multi-primary mesh deployed (see root README)
- Kube contexts configured for each cluster
- At least one existing test suite available to run probes

## Quick Start

```bash
# Apply a single profile and inspect what changed.
./tests/tuning/001-apply-profile.sh \
  --contexts cluster-001,cluster-002,cluster-003 \
  --profile profiles/01-sidecar-scoping.yaml

# Run the controlplane probe to measure impact.
./tests/controlplane/002-collect-resource-metrics.sh \
  --contexts cluster-001,cluster-002,cluster-003

# Revert the profile.
./tests/tuning/002-revert-profile.sh \
  --contexts cluster-001,cluster-002,cluster-003

# Or use the sweep orchestrator to automate multiple profiles.
./tests/tuning/003-run-tuning-sweep.sh \
  --contexts cluster-001,cluster-002,cluster-003 \
  --profiles 01-sidecar-scoping,03-push-throttling,06-xds-cache-tuning \
  --suite controlplane

# Compare results across profiles.
./tests/tuning/004-compare-profiles.sh --format markdown
```

## Sweep Orchestrator

`003-run-tuning-sweep.sh` runs the full apply → probe → revert cycle for
each profile. For each profile it:

1. Saves the current Istio CR as a baseline snapshot
2. Applies the profile patch + resources
3. Waits for istiod to roll out the new configuration
4. Runs the specified test suite probe(s)
5. Collects results into `results/sweep-<RUN_ID>/<profile-name>/`
6. Reverts the Istio CR and deletes profile resources
7. Waits for istiod to stabilize before the next profile

The `--suite` flag accepts: `controlplane`, `propagation`, `dataplane`,
`churn`, `churn-dataplane`, or a comma-separated combination.

## Results Format

Results are organized by profile under the sweep directory:

```
results/sweep-<RUN_ID>/
├── baseline/
│   └── <suite>-<RUN_ID>.tsv
├── 01-sidecar-scoping/
│   └── <suite>-<RUN_ID>.tsv
├── 03-push-throttling/
│   └── <suite>-<RUN_ID>.tsv
└── sweep-comparison.md
```

If a profile's apply or probe fails, the sweep does **not** abort — it records a
marker file in that profile's directory (`SETUP_FAILED` for an apply/rollout failure,
`PROBE_FAILED` for a probe failure) instead of a `.tsv`, attempts a best-effort revert
(on apply failure) so istiod returns to default, and continues to the next profile.
`004-compare-profiles.sh` skips marker-only directories, so a failed profile is visibly
absent from the comparison table while the marker remains for operator inspection.

## Combining Profiles

Profiles can be combined (stacked) by passing multiple profile names to the
apply script. They are applied in order; patches are merged. Be aware that
some combinations may interact:

- `01-sidecar-scoping` + `09-gateway-scoping` — complementary, both scope
  different proxy types.
- `03-push-throttling` + `06-xds-cache-tuning` — both reduce push overhead
  via different mechanisms; effects may compound or overlap.
- `04-istiod-resources` + `05-proxy-resources` — independent; no interaction.

## Scripts

| Script | Purpose |
|--------|---------|
| `001-apply-profile.sh` | Apply a tuning profile to the live mesh |
| `002-revert-profile.sh` | Revert the mesh to its pre-profile baseline state |
| `003-run-tuning-sweep.sh` | Orchestrate apply → probe → revert for multiple profiles |
| `004-compare-profiles.sh` | Compare results across profiles (text/csv/json/markdown) |
| `005-cleanup.sh` | Remove all tuning test resources and revert any active profile |

## Campaign baseline (baked supported-only profiles)

For the 20-cluster / 10k-service campaign the mesh comes up
**production-configured**: the four SUPPORTED levers — **01 sidecar-scoping**,
**02 discovery-selectors**, **07 telemetry-filtering**, **08
access-log-filtering** — are baked into `charts/spoke-ossm` (alongside the
04/05 resource profiles from PR #62) rather than applied at runtime. Each is
individually toggleable under `tuningBaseline.*` in
`charts/spoke-ossm/values.yaml`. The runtime profiles under `profiles/` remain
the A/B sweep mechanism and are unchanged in purpose.

Two correctness notes specific to the baked baseline:

- **Sidecar egress is the cross-namespace graph, not `./*`-only.** The runtime
  profile's `./*`-local default understates per-proxy config at campaign scale
  (workloads talk cross-namespace / cross-cluster). The baseline default spans
  `istio-system` plus the suite + `mesh-verify` namespaces; widen/narrow via
  `tuningBaseline.sidecar.egressHosts`. The root Sidecar governs the SIDECAR
  proxies only — the injected ingress/east-west gateways are exempted to `*/*`
  egress by `workloadSelector` Sidecars in
  `charts/spoke-ossm/templates/tuning-sidecar.yaml` so the cross-cluster
  mesh-verify path is not severed.
  > **Forward-looking (10k scale):** because the gateway proxies carry a `*/*`
  > (full-mesh) egress view while the sidecars are narrowed, at full 10k-service
  > scale the gateway istio-proxy RSS / `xds_config` footprint can dominate. Watch
  > the gateway pods' `memory.limits` (currently 1Gi in the gateway charts) — they
  > may need raising even though the sidecars are scoped down.
- **discoverySelectors must cover istio-system.** istiod does NOT auto-include
  its own namespace, and the east-west / ingress gateways live there, so the
  baseline ORs a second selector matching
  `kubernetes.io/metadata.name=istio-system`. Suite namespaces are matched via
  `istio-discovery=enabled` (stamped by each suite's `namespace.yaml`).
- **Run provenance: `TUNING_BASELINE` / `SIDECAR_EGRESS_HOSTS`.** Every suite's TSV
  preamble records which levers were live at run time, **live-queried from the
  cluster** (not read from chart defaults — the deployed state can diverge from a
  GitOps/`--set` override). Each lever reads `on` | `off` | `unknown`; `unknown`
  means istiod or the query was unreachable, **not** that the lever is off — a run
  carrying any `unknown` is **not comparable** to a fully-resolved run (same caveat
  as `istiod_restarted`'s `0|1|unknown`). `SIDECAR_EGRESS_HOSTS` records the live
  root-Sidecar egress graph (`none` when no root Sidecar is applied).

> **⚠️ LOUD WARNING — `egressHosts` namespace parts are EXACT matches, not
> glob-prefixes.** An Istio Sidecar egress host `"<namespace>/<dnsName>"` matches
> the namespace part **exactly**: `"controlplane-test/*"` does **NOT** cover
> `"controlplane-test-0/*"`. So when `controlplane.namespaceCount > 1` the suite
> mints `controlplane-test-0`, `controlplane-test-1`, … and the bare
> `controlplane-test/*` entry in `tuningBaseline.sidecar.egressHosts` is **dead
> (unused)** for those workloads. Raising `controlplane.namespaceCount` therefore
> **requires adding a `controlplane-test-<i>/*` entry per extra namespace** — the
> bare `controlplane-test/*` does not glob. (Harmless at the default
> `namespaceCount=1`, where controlplane lands workloads only in its primary
> namespace, but a forward-looking trap.)

**Adding a new mesh namespace** (a namespace whose pods carry sidecars and must
participate in the mesh):

1. Label the namespace `istio-discovery=enabled` — otherwise the campaign
   baseline's `discoverySelectors` make istiod ignore it entirely (no informers,
   no proxy config, the workload never gets a sidecar config). Suite
   `chart/templates/namespace.yaml` templates already stamp this.
2. Add `"<ns>/*"` to `tuningBaseline.sidecar.egressHosts` — otherwise the
   namespace is discovered but its sidecars have no egress to it under the root
   Sidecar's narrowed graph.

Both steps are required; doing only (1) gives a discovered-but-unreachable
namespace, only (2) gives an egress entry istiod never watches.

> **Do NOT "fix" `mesh-wiring-verify`'s missing labels.** The
> `mesh-wiring-verify` namespace
> (`charts/mesh-wiring-verify/templates/namespace.yaml`) is **intentionally**
> left without `istio.io/rev` and without `istio-discovery=enabled`: it is the
> always-on wiring health gate, holds **no mesh workloads / no sidecars**, and
> must not be injected into the mesh it checks. istiod ignoring it under the
> baseline `discoverySelectors` is correct and desired — adding the label would
> needlessly pull a non-mesh namespace into istiod's watch set.

## Known Limitations

- **Istio CR patches trigger an istiod restart**: most pilot env var changes
  require an istiod rollout. The sweep orchestrator waits for rollout
  completion, but this adds ~60-90s per profile switch.
- **Discovery selectors (profile 02) require namespace labelling**: the
  apply script labels mesh namespaces, but namespaces created by other test
  suites may not have the label. Run setup scripts after applying this profile.
  Note: each suite's `chart/templates/namespace.yaml` now stamps
  `istio-discovery: enabled`, so suite namespaces created via their setup
  scripts are discovered automatically (see "Campaign baseline" below).
- **Gateway scoping (profile 09) has known upstream bugs**: #29131 and #37997
  can cause issues with ext_authz and EnvoyFilter references.

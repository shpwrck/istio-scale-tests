# Campaign summary — template

Copy this into `YYYY-MM-DD-<slug>-results.md` at the start of a campaign write-up.

The **non-negotiable rule:** lead with the *Scale envelope* below before any
per-metric findings. "Mesh size 1→10" is a cluster count, not a scale — it says nothing
about how many proxies, endpoints, or config bytes the control plane actually carried, or
whether the run stressed the infra at all. A reader must be able to answer *"how big was
this, and was anything near a limit?"* from the first screen, without opening a sweep dir.

Every field below is already emitted by the per-suite sweep reports or obtainable from one
listed command — none of it requires re-running anything. Fill the measured columns from
the **peak** mesh-size point of the run (usually mesh-10), not mesh-1.

---

## Scale envelope

### 1. Mesh topology — what one mesh-size-N point actually contains

| Dimension | Value | Source |
|---|---|---|
| Clusters (multi-primary) | _N_ | sweep header `Mesh size` |
| Services / cluster | _S_ | sweep header `Service count` |
| Namespaces / cluster | _NS_ | sweep header `Namespace count` |
| Workload replicas / service | _R_ | sweep header `Replicas` |
| **Total services in mesh** | _N × S_ | derived |
| **Total endpoints in mesh** | _N × S × R_ | derived; cross-check `istioctl proxy-config endpoints` or controlplane `EDS Δ` |
| **Connected proxies per cluster (measured peak)** | _…_ | controlplane report `connected_proxies per cluster (max)`: `pilot_xds` summed over one cluster's istiod replicas at one scrape. Should be about that cluster's Running injected pods (gateways included); not a mesh-wide sum |
| Connected proxies per istiod replica (peak) | _…_ | controlplane report `connected_proxies per istiod replica (max)`: the busiest single replica, about 1/R of the cluster figure with R replicas |
| Proxy check vs Running sidecar pods | ok / low / high / n/a / excluded | controlplane report `proxy check`; any `low`/`high` comes with a WARNING naming the cluster scrape. A large `n/a` or `excluded` share means most scrapes were not checked |
| Per-proxy config size | _… KiB/MiB_ | controlplane `cfg_dump_avg (MiB)` (varies by sidecar scoping) |
| Sidecar scoping | none / namespace / explicit | sweep header `Sidecar scoping` |
| Traffic management | none / vsdr | controlplane envelope `Traffic management` (sweep peak `traffic_config`; none when both were swept) |
| Istio version | _…_ | sweep header `Istio version` |
| Kube version(s) | _…_ | sweep header `Kube versions` |
| Platform / mesh build | _kubernetes or openshift; node provider; operator, istiod and gateway proxy builds; istiod env digest; tuning objects (none)_ | controlplane envelope `Platform / mesh build`; run summary row `Platform`, report keys `PLATFORM`, `MESH_OPERATOR_BY_CONTEXT`, `ISTIOD_IMAGE_BY_CONTEXT`, `PROXY_IMAGE_BY_CONTEXT` (the ingress and east-west gateways' build), `NODE_PROVIDER_BY_CONTEXT`, `ISTIOD_ENV_BY_CONTEXT` (the envelope's `istiod env`: a digest of istiod's settings) and `TUNING_OBJECTS_BY_CONTEXT` (the envelope's `tuning objects`: `none` unless a tuning profile's objects were left in place). Upstream (Sail) and OSSM builds, and kind and cloud nodes, are different measurements: compare like with like. On kind, capacity and headroom figures overstate the host (the envelope's verdict leaves the node figures out), and remote latency runs through cloud-provider-kind's userspace Envoy on the shared host. Copy the envelope's `> **Data warning:**` lines with it |

### 2. Control-plane provisioning & headroom — *was anything actually stressed?*

This block is the one most often missing and the most important. Numbers far below their
limits mean the mesh was small **relative to the infra**, so the magnitudes characterize a
small mesh, not capacity — say so explicitly here, not in a footnote.

| Resource | Provisioned (req / lim) | Measured peak | % of limit | Source |
|---|---|---|---|---|
| istiod replicas | _… per cluster (a range such as 1-3 when members differ)_ | — | — | sweep header `istiod replicas` (read on every context) |
| istiod CPU | _req / lim_ | _… m_ | _…%_ | `kubectl top pod -n istio-system -l app=istiod`; controlplane `CPU avg (m)` |
| istiod memory | _req / lim_ | _… Mi_ | _…%_ | controlplane `Mem RSS (Mi)` |
| Worker-node CPU | — | _…%_ | _…%_ | `kubectl top nodes` at peak |
| Worker-node memory | — | _…%_ | _…%_ | `kubectl top nodes` at peak |

### 3. Workload / throughput axis (suite-specific)

| Suite | Axis swept | Values | Source |
|---|---|---|---|
| propagation | iterations | _…_ | sweep header `Iterations` |
| controlplane | sidecar scopings | none, namespace, explicit | sweep header |
| controlplane | traffic configs (optional) | none, vsdr | sweep header `TRAFFIC_CONFIG` (+ `VSDR_EVERY`, `VSDR_SUBSETS`) |
| dataplane | QPS levels | _10 / 100 / 500 / 1000_ | sweep header `QPS levels` (+ `Duration`, `Connections`, `Server replicas`) |
| churn | churn deployments × scale range | _… × (1→N)_ | sweep header `Deployments`, `Scale range` |
| churn-dataplane | churn rates | _… /s_ | sweep header `Churn rates` |
| _(all)_ | repetitions | _…_ | run flag `--repetitions` |

### 4. Data-plane coverage and run provenance

`n_valid` / `n_total` says rows were dropped, not that a remote was unreachable or a
local baseline cell is missing; read these before quoting any data-plane number.

| Check | Value | Source |
|---|---|---|
| Remote coverage (dataplane / churn-dataplane) | all REACHABLE / _remotes not REACHABLE, with status (FLAPPING, DEGRADED, UNREACHABLE, UNKNOWN)_ | report section `Remote coverage` (JSON `summary.remotes_not_reachable`); `004` / `005 --fail-on-unreachable` exits 3 when a remote is not REACHABLE |
| Local baseline (dataplane) | OK / _cells DROPPED, DEGRADED, UNCHECKED or MISSING, with reason_ | dataplane report `Local baseline` (JSON `local_baseline`); rows below `MIN_QPS_RATIO` × target are `QPS_SHORTFALL`, dropped as reason `saturated` |
| Run config | _path_ (sha256 _…_) / none | every report's `RUN_CONFIG` + `RUN_CONFIG_SHA256` (TSV preamble); the sweep dir keeps the file as `run-config-<RUN_ID>.env` |

### Scale verdict — one line, up front

> _One sentence stating the realized magnitude and the headroom, e.g.:_
> "Peak mesh carried **~X connected proxies / ~Y endpoints / ~Z KiB config per proxy**;
> istiod ran at **~W % of its mem limit** and worker nodes at **~V % CPU** → **under-scaled
> by ~Nx → trust the scaling _shapes_ and cross-cluster _overheads_, not the absolute
> magnitudes.**"

---

## Customer SLA checklist

A normative pass/fail gate for the customer deliverable. Fill `observed` from the **peak
mesh-size** point's n_valid-gated aggregates (the controlplane report's "Achieved scale"
block / `sla` JSON object — never the configured axis values).

`Margin` = headroom to the target = `target_pct − observed_pct` (percentage points; a
positive margin is headroom remaining, a negative margin means the target is breached).
For the integrity rows (restarts, validity) there is no numeric margin — leave it `—`.

The CAUTION/FAIL utilization bands are `SCALE_SLA_CAUTION_PCT` (default 75) and
`SCALE_SLA_FAIL_PCT` (default 90) in `config/options.env`; the verdict per row:

- **PASS** — observed < `SCALE_SLA_CAUTION_PCT` % (default < 75 %) of the limit.
- **CAUTION** — observed in `[CAUTION, FAIL)` % (default 75–90 %), a metrics signal is
  unavailable, or some samples were filtered (`n_valid < n_total`).
- **FAIL** — observed ≥ `SCALE_SLA_FAIL_PCT` % (default ≥ 90 %), an istiod restart
  occurred inside a measurement window, or no valid samples survived the filters.

| Metric | Target | Observed | Margin | PASS/CAUTION/FAIL |
|---|---|---|---|---|
| istiod CPU (% of cross-replica limit) | < 75 % | _…%_ | _…_ | _…_ |
| istiod memory (% of cross-replica limit) | < 75 % | _…%_ | _…_ | _…_ |
| Worker-node CPU | < 75 % | _…%_ | _…_ | _…_ |
| Worker-node memory | < 75 % | _…%_ | _…_ | _…_ |
| istiod restarts in-window | 0 | _…_ | — | _…_ |
| Sample validity (`n_valid` / `n_total`) | all valid | _…/…_ | — | _…_ |

The controlplane report (`004-report-results.sh`) emits a one-line headline verdict in
every format: `Customer SLA verdict: PASS|CAUTION|FAIL — <reason>`.

For a filled-in example see [`2026-06-22-20c-10k-10k-results.md`](2026-06-22-20c-10k-10k-results.md).

---

## Generated, not hand-transcribed

`tests/controlplane/003-run-sweep.sh` writes the Scale-envelope block to
`sweep-<RUN_ID>/scale-envelope-<RUN_ID>.md` at campaign end (`render_scale_envelope` in
`tests/lib/envelope.sh`). Paste that block in rather than transcribing by hand, and fill the
Customer SLA checklist from the same report's `sla` verdict. Paste from a redacted copy:
`tests/lib/redact-results.sh --out /tmp/redacted <results>/sweep-<RUN_ID>` (see
[README](README.md), "Redact before you paste"), and read the copy, file names included,
before you commit it (the README lists what the script has no pattern for). For older
sweeps without the generator, fill by hand from the peak-mesh sweep.

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
| **Connected proxies (measured peak)** | _…_ | controlplane report `Proxies` column — **report the measured peak across the mesh, not the configured count** |
| Per-proxy config size | _… KB/MB_ | controlplane `Cfg dump avg (MB)` (varies by sidecar scoping) |
| Sidecar scoping | none / namespace / explicit | sweep header `Sidecar scoping` |
| Istio version | _…_ | sweep header `Istio version` |
| Kube version(s) | _…_ | sweep header `Kube versions` |

### 2. Control-plane provisioning & headroom — *was anything actually stressed?*

This block is the one most often missing and the most important. Numbers far below their
limits mean the mesh was small **relative to the infra**, so the magnitudes characterize a
small mesh, not capacity — say so explicitly here, not in a footnote.

| Resource | Provisioned (req / lim) | Measured peak | % of limit | Source |
|---|---|---|---|---|
| istiod replicas | _… per cluster_ | — | — | sweep header `istiod replicas` |
| istiod CPU | _req / lim_ | _… m_ | _…%_ | `kubectl top pod -n istio-system -l app=istiod`; controlplane `CPU avg (m)` |
| istiod memory | _req / lim_ | _… Mi_ | _…%_ | controlplane `Mem RSS (Mi)` |
| Worker-node CPU | — | _…%_ | _…%_ | `kubectl top nodes` at peak |
| Worker-node memory | — | _…%_ | _…%_ | `kubectl top nodes` at peak |

### 3. Workload / throughput axis (suite-specific)

| Suite | Axis swept | Values | Source |
|---|---|---|---|
| propagation | iterations | _…_ | sweep header `Iterations` |
| controlplane | sidecar scopings | none, namespace, explicit | sweep header |
| dataplane | QPS levels | _10 / 100 / 500 / 1000_ | sweep header `QPS levels` (+ `Duration`, `Connections`) |
| churn | churn deployments × scale range | _… × (1→N)_ | sweep header `Deployments`, `Scale range` |
| churn-dataplane | churn rates | _… /s_ | sweep header `Churn rates` |
| _(all)_ | repetitions | _…_ | run flag `--repetitions` |

### Scale verdict — one line, up front

> _One sentence stating the realized magnitude and the headroom, e.g.:_
> "Peak mesh carried **~X connected proxies / ~Y endpoints / ~Z KB config per proxy**;
> istiod ran at **~W % of its mem limit** and worker nodes at **~V % CPU** → **under-scaled
> by ~Nx → trust the scaling _shapes_ and cross-cluster _overheads_, not the absolute
> magnitudes.**"

---

## Customer SLA checklist

A normative pass/fail gate for the customer deliverable. Fill `observed` from the **peak
mesh-size** point's n_valid-gated aggregates (the controlplane report's "Achieved scale"
block / `sla` JSON object — never the configured axis values). `margin` is headroom to the
target. The verdict per row:

- **PASS** — observed is comfortably within target (e.g. utilization < 75 % of limit).
- **CAUTION** — within target but limited headroom (utilization 75–90 %), a metrics signal
  is unavailable, or some samples were filtered (`n_valid < n_total`).
- **FAIL** — at/over a limit (utilization ≥ 90 %), an istiod restart occurred inside a
  measurement window, or no valid samples survived the filters.

| Metric | Target | Observed | Margin | PASS/CAUTION/FAIL |
|---|---|---|---|---|
| istiod CPU (% of cross-replica limit) | < 75 % | _…%_ | _…_ | _…_ |
| istiod memory (% of cross-replica limit) | < 75 % | _…%_ | _…_ | _…_ |
| Worker-node CPU | < 75 % | _…%_ | _…_ | _…_ |
| Worker-node memory | < 75 % | _…%_ | _…_ | _…_ |
| istiod restarts in-window | 0 | _…_ | — | _…_ |
| Sample validity (`n_valid` / `n_total`) | all valid | _…/…_ | — | _…_ |

The controlplane report (`004-report-results.sh`) emits a **one-line headline verdict** in
every format (`Customer SLA verdict: PASS|CAUTION|FAIL — <reason>`), and the sweep
orchestrator writes the full **Scale envelope** block (above) to
`sweep-<RUN_ID>/scale-envelope-<RUN_ID>.md` at campaign end — generated, not hand-filled.

---

## Worked example — 2026-06-02 workaround pass

Demonstrates the envelope filled from that run's reports (see
[`2026-06-02-workaround-pass-results.md`](2026-06-02-workaround-pass-results.md)):

- **Topology (peak):** 10 clusters × 10 svc × 2 reps ≈ **100 services / ~200 endpoints per
  cluster**, but **measured connected-proxies only ~3–5** — the mesh was tiny vs. the infra.
  Per-proxy config: **122 KB** (no scoping) → **16 KB** (namespace/explicit).
- **Provisioning & headroom:** istiod pinned **5 replicas**, req `1 CPU / 2Gi`, **lim 8Gi**.
  Measured istiod **~370 Mi RSS ≈ 4.6 % of the 8Gi limit**; worker nodes **2–8 % CPU**.
- **Throughput:** dataplane QPS 10/100/500/1000; churn 5 deploys × (1→5); controlplane 3 scopings.
- **Scale verdict:** "~3–5 proxies / ~370 Mi istiod (≈5 % of limit) / 2–8 % node CPU →
  under-scaled by ~20× → trust shapes + cross-cluster overheads, not magnitudes."

That verdict is exactly what belonged on screen one and didn't have a home before this template.

---

## Generated, not hand-transcribed

The Scale-envelope tables are mechanical — every measured cell maps to a sweep-report field
or a `kubectl top` call — so they are now **auto-generated**. `tests/lib/envelope.sh`
(`render_scale_envelope`) rolls the controlplane report's peak-mesh row + capacity metadata
together with a read-only `kubectl top` / istiod-resource / network snapshot across
`--contexts` into the Scale-envelope block. `003-run-sweep.sh` writes it to
`sweep-<RUN_ID>/scale-envelope-<RUN_ID>.md` at campaign end. Paste that block in here rather
than transcribing by hand; fill the Customer SLA checklist from the same report's `sla`
verdict. (For older sweeps without the generator, fill by hand from the peak-mesh sweep.)

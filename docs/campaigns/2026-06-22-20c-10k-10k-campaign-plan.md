# 20c/10k/10k peak campaign plan

Date: 2026-06-22

This is the execution plan for a disposable full-lifecycle campaign on latest `main`.
It provisions 21 ROSA HCP clusters, uses one hub plus 20 mesh-member spokes, verifies
the full 20-cluster Istio mesh on small fixed worker pools first, scales the spokes up
only after Istio works, then runs the campaign at `mesh_size=20` (the control-plane
proof ladders Service count up to the 10,000 peak).

Target definition:

- 20 mesh-member spoke clusters.
- 500 Kubernetes Services per spoke.
- 1 workload replica per Service — one endpoint per Service. This is deliberately
  **not** 10 endpoints per Service; the campaign sweeps Service-object count, not
  endpoint fan-out.
- 10,000 Kubernetes Service objects total.
- 10,000 workload endpoints total.

Repeated service names across clusters are acceptable for this campaign. The run is
measuring the 10,000 Kubernetes Service object / endpoint shape, not 10,000 globally
unique hostnames.

The single-endpoint-per-Service shape is what sizes the worker pools below: peak
data-plane load is ~10,000 sidecars x ~100m CPU request ~= 1,000 cores mesh-wide
(~50 cores per spoke), which fits the 8-node campaign pools. A 10-endpoints-per-Service
variant would be ~10x that (~500 cores per spoke) and would not fit — it would need a
fundamentally larger worker footprint.

## Proof criteria

This campaign exists to *prove* an organization can operate at 20 clusters / 10,000
Services / 10,000 endpoints, so the bar is accurate, complete, attributable evidence —
not realism. Declare the pass criteria before running; the outcome is an objective PASS
or FAIL against them, not a narrative.

PASS requires all of the following, each evidenced from a generated artifact:

- **Scale actually reached.** All 10,000 Service objects and 10,000 endpoints created
  and converged — 500 per spoke across all 20 spokes — with zero `Pending` pods. The
  control-plane report's achieved-vs-capacity block is the evidence; a shortfall on any
  cluster is a documented FAIL, never a silent gap.
- **Full mesh formed.** Every spoke registers the other 19 (`istiod_managed_clusters
  == 19` per cluster) and `mesh-wiring-verify` is Ready mesh-wide.
- **Headroom, measured — not N/A.** At the peak, node CPU and istiod CPU stay under the
  SLA-caution band (`SCALE_SLA_CAUTION_PCT`, default 75%) and istiod RSS stays under a
  stated fraction of the 16Gi limit. A metrics-API gap that leaves utilization N/A is a
  re-run trigger, not a PASS with "headroom unknown".
- **Reproducible.** The headline control-plane peak is run at least twice (ideally 3x);
  the PASS numbers hold across runs and run-to-run variance is reported. One sweep is an
  anecdote, not proof.
- **Every number valid.** Rows are `n_valid` (no istiod-restart / dropped-sample
  poisoning); percentiles are reported only where the sample size supports them;
  histogram-derived convergence is treated as non-load-bearing — the wall-clock
  propagation measurements are the trustworthy signal.

Record the concrete numeric thresholds (the RSS fraction, the convergence target, the
acceptable variance) in `CAMPAIGN_STATUS.md` at execution start, before the first sweep,
so the verdict is falsifiable.

## Budget guard

Hard cap: do not exceed **$1,500 incremental campaign spend from execution start**.
Existing month-to-date AWS spend is recorded as context, but is not charged against
this run.

Terraform quota management must stay disabled. Quotas are checked read-only before
apply; Terraform must not request quota increases.

Cost tracking:

- Create a local spend ledger at execution start and update it before and after every
  phase, every 30 minutes while infrastructure is up, before spoke scale-up, and
  before each suite.
- Track spend as the maximum of projected resource-time burn, Cost Explorer delta from
  execution start when available, and visible service-specific actuals.
- Treat Cost Explorer as delayed. The projected meter is authoritative for stop
  decisions while the campaign is running.

Conservative budget meter:

- 3-node verification phase: count as `$125/hour`.
- 8-node campaign phase: count as `$300/hour`.
- Teardown is always allowed, even after a stop threshold.

Stop thresholds:

- Projected `$900`: stop optional diagnostics and keep only required gates.
- Projected `$1,100`: do not scale spokes to 8 nodes unless the remaining planned run
  still fits the budget.
- Projected `$1,200`: start no new suite.
- Projected `$1,300`: begin teardown immediately.
- Any hard functional gate failure: stop and report the blocker rather than reducing
  the target.

Reference estimate used for the meter:

- `m5.4xlarge` in `us-east-2`: `$0.768/hour` EC2 on-demand Linux price checked by the
  AWS Pricing API on 2026-06-22.
- ROSA HCP service fees are estimated from worker vCPU service fees plus per-cluster
  fees.
- 3-node phase worker shape: 64 `m5.4xlarge` worker instances, about `$94/hour` for
  EC2 workers plus ROSA service fees before smaller network, storage, and load
  balancer overhead.
- 8-node phase worker shape: 164 `m5.4xlarge` worker instances, about `$239/hour` for
  EC2 workers plus ROSA service fees before smaller network, storage, and load
  balancer overhead.

## Infrastructure plan

Prepare local, gitignored Terraform variables.

`terraform/rosa-hcp/terraform.tfvars`:

- `cluster_count = 21`.
- `manage_service_quotas = false`.
- Instance type: set `compute_machine_type = "m5.4xlarge"` **explicitly**. The rosa-hcp
  default (`default_compute_machine_type`) is `m5.xlarge` (4 vCPU); leaving the type
  unset under-provisions every worker ~4x and the 500-Service control-plane peak will
  not fit.
- Worker pools are modelled as `cluster_defaults` (applied to every cluster) plus
  per-cluster `cluster_overrides` — there is no hub/spoke group abstraction. Express the
  two shapes as:
  - `cluster_defaults` = the spoke shape (20 of the 21 clusters), with
    `compute_machine_type = "m5.4xlarge"`.
  - a `cluster_overrides` entry for the hub (cluster-001) = `4 x m5.4xlarge`.
- Hub cluster: fixed `4 x m5.4xlarge` (via the hub override).
- Spoke clusters, initial verification phase: fixed `3 x m5.4xlarge` (via
  `cluster_defaults`).
- Spoke clusters, campaign phase: fixed `8 x m5.4xlarge` (raise the spoke
  `cluster_defaults` node count to 8 and re-apply; leave the hub override at 4).
- Fixed means `replicas`, `worker_autoscale_min`, and `worker_autoscale_max` are all
  set to the same node count for that cluster group.
- Keep `compute_machine_type` constant across the 3 -> 8 scale-up so only the node
  count changes — that is an in-place machine-pool resize, not a pool replacement.

`terraform/platform/terraform.tfvars`:

- `mesh_member_count = 20`.
- `acm_disabled_components = ["server-foundation"]`.
- `argocd_clusters_per_shard = 10`.
- `argocd_max_shards = 5`.
- `gitops_app_repo_revision = "main"`.

Read-only preflight before any apply:

- Confirm Standard On-Demand vCPU headroom in `us-east-2`.
- Confirm VPC, Elastic IP, NAT gateway, internet gateway, gateway endpoint, and IAM role
  headroom.
- Confirm no existing regional usage makes the planned 8-node phase exceed available
  quota.
- Confirm required credentials are present locally, but never write tokens,
  kubeconfigs, API hosts, or account identifiers into committed artifacts.

## Mesh bring-up and scale-up

1. Apply ROSA HCP Terraform with 3-node spokes.
2. Write kubeconfig locally and `export SETUP_CONTEXTS=cluster-002,...,cluster-021`
   (the repo convention for the spoke context list; the sweep commands below pass it
   through `--contexts`).
3. Apply platform Terraform.
4. Run `terraform/platform/scripts/001-openapi-preflight.sh` on the hub.
5. Ramp mesh membership through `1 -> 5 -> 10 -> 20` by re-applying platform Terraform
   with `mesh_member_count` set to each step in turn (the tfvars value above is the
   final `20`). Do not jump straight to 20 — clear the ramp gate below at each step.
6. At every ramp gate, verify:
   - Argo applications are synced and healthy.
   - `mesh-wiring-verify` is ready.
   - each spoke has the expected remote secrets.
   - istiod remote-cluster sync is healthy.
   - east-west gateway exposure is correct.
   - `mesh-verify` returns cross-cluster traffic.
7. Only after full 20-cluster mesh verification, update spoke pools to fixed
   `8 x m5.4xlarge` and re-apply ROSA Terraform.
8. Wait for new nodes Ready, mesh pods healthy, Argo clean, and metrics API stable.
9. Re-run mesh verification and the live capacity gate before starting campaign suites.

Hard stop gates:

- Failed OpenAPI preflight.
- Any degraded mesh-wiring gate at the target member count.
- Failed remote-cluster sync.
- Cross-cluster data plane not working.
- Metrics API unable to stabilize before the control-plane suite.
- Capacity will not fit `500 services x 1 replica`. The plan-time check in
  `controlplane/003-run-sweep.sh` (`capacity_plan_warn`) is a **WARN only**; the
  blocking gate is the per-context preflight in `controlplane/001`, which fails the
  combo at apply time. Treat the 003 WARN as a stop, and rely on 001 to hard-fail per
  context.
- istiod restart, OOM, or RSS approaching the 16Gi per-pod limit.

istiod is sized at 4 CPU / 16Gi (Guaranteed QoS, `charts/spoke-ossm/values.yaml`); the
16Gi limit is hard, so an istiod approaching it at the 10k-Service peak is a
stop-and-report, not an in-run retune (raising it needs a chart change + mesh redeploy,
which costs budget and time).

Before peak sweeps, calibrate `FANOUT_MAX_SKEW_MS` from a low-impact 20-context probe
instead of trusting the provisional default.

## Per-suite capacity

Only the control-plane suite needs the 8-node spoke pools. It is the one suite whose
footprint scales with its sweep axis: `--service-counts 500 --replica-counts 1` stands
up ~500 sidecar-injected pods per spoke (~50 cores of proxy CPU request per spoke). The
other four suites vary a traffic or churn *rate* (or an iteration count) against a
small, fixed workload, so their per-spoke node footprint is roughly constant and small.
The verification phase already proves the full 20-cluster mesh runs on 3-node spokes
(istiod 3 x 4 CPU + gateways fit with room to spare), so the light suites fit there too.

| Suite | Sweep axis | Steady workload per spoke | Needs 8-node pools? |
|---|---|---|---|
| Control plane | Service / pod **count** (500 x 1) | ~500 sidecar pods (~50 cores) | **Yes** |
| Data plane | fortio **QPS** (10-1000, swept in-probe) | fortio server + client (fixed) | No |
| Propagation | xDS push latency (30 iterations) | watcher + one canary endpoint | No |
| Churn | churn **intensity/rate** | ~5 churn targets + watcher | No |
| Churn + data plane | churn **rate** (1,5,10) under traffic | ~10 churn targets + fortio | No |

Budget option: because only control plane needs the 8-node pools, run it first (as the
matrix below already directs), then optionally scale the spoke pools back to fixed
`3 x m5.4xlarge` for the remaining four suites. The instance type is unchanged, so this
is an in-place machine-pool resize, and it drops the burn from the `$300/hour` 8-node
meter to the `$125/hour` 3-node meter (~`$175/hour` saved for the rest of the campaign).
The trade-off is one extra scale-down plus a mesh-health and metrics-settle re-check
between control plane and the next suite; the simpler default is to hold 8 nodes through
all five suites. After any scale-down, re-verify mesh health and let the metrics API
settle before resuming.

## Campaign matrix

Use `MESH=20` only. Run suites serially. Never run two suites or probes at the same
time because they share the same istiod metrics and xDS counters.

Run the control-plane suite **first**. It is the headline deliverable (the actual
10,000-Service / 10,000-endpoint measurement), it is the only suite that needs the
8-node spoke pools (see Per-suite capacity above), and running it first secures the
marquee result before any budget stop threshold can cut the run short. The remaining
suites are lighter and follow in the order below.

Control plane (run first — this is the proof):

Ladder the service count so the result is a smooth scaling curve up to the 10k peak, not
a single dot that cannot distinguish "sustainable" from "knife-edge". Run the whole
sweep at least twice for reproducibility and report run-to-run variance.

```bash
tests/controlplane/003-run-sweep.sh \
  --contexts "$SETUP_CONTEXTS" \
  --mesh-sizes 20 \
  --service-counts 100,300,500 \
  --replica-counts 1 \
  --namespace-counts 1 \
  --sidecar-scopings none,namespace,explicit
```

`--service-counts` is per spoke (peak `500 x 20 = 10,000`). Under budget pressure the
minimum proof is `--service-counts 500` (the peak alone) run twice, optionally at a
single representative `--sidecar-scopings`; the ladder and the full scoping sweep are
stronger evidence and should be funded first — if needed by dropping the
churn-plus-data-plane suite, not the ladder or the repeat.

Data plane:

```bash
tests/dataplane/003-run-sweep.sh \
  --contexts "$SETUP_CONTEXTS" \
  --mesh-sizes 20 \
  --qps-levels 10,100,500,1000
```

Propagation:

```bash
tests/propagation/006-run-sweep.sh \
  --contexts "$SETUP_CONTEXTS" \
  --mesh-sizes 20 \
  --iterations 30 \
  --tsv
```

Churn:

```bash
tests/churn/003-run-sweep.sh \
  --contexts "$SETUP_CONTEXTS" \
  --mesh-sizes 20 \
  --churn-intensities 5 \
  --iterations 20
```

`--iterations` is 20 (not a token 5) so any reported convergence percentile clears the
min-n gate; propagation's 30 already does.

Churn plus data plane:

```bash
tests/churn-dataplane/004-run-sweep.sh \
  --contexts "$SETUP_CONTEXTS" \
  --mesh-sizes 20 \
  --churn-rates 1,5,10
```

Between suites:

- Run and verify cleanup for the previous suite.
- Wait until zero `*-test` namespaces remain.
- Re-check istiod readiness and remote-cluster sync.
- Update the spend ledger.
- Confirm the next suite still fits within the budget stop thresholds.

## Artifacts and completion

Maintain local `CAMPAIGN_STATUS.md` and a local spend ledger during the run. These are
operational artifacts and must be redacted before any commit.

Each completed suite must produce TSV plus markdown summary under:

```text
tests/<suite>/results/sweep-<RUN_ID>/
```

Assemble the durable campaign report from `docs/campaigns/TEMPLATE.md`:

```text
docs/campaigns/YYYY-MM-DD-20c-10k-10k-results.md
```

The report must lead with the generated scale envelope and SLA verdict. Commit only the
redacted campaign report and selected charts to a branch/PR. Never commit kubeconfigs,
tfvars, raw secrets, account IDs, API hosts, real cluster names, or unredacted logs.

Report fidelity (this is a proof, so every number must be defensible):

- Lead with the scale-envelope artifact (`scale-envelope-*.md`): mesh topology
  (clusters / Services / endpoints / measured proxies), the provisioning + headroom
  table, and the one-line SLA verdict. That artifact is the proof; the per-suite reports
  are its backing detail.
- State the PASS/FAIL against the pre-declared proof criteria explicitly, naming the
  evidencing cell for each (achieved-vs-capacity, `istiod_managed_clusters`, peak
  utilization, RSS, run-to-run variance).
- Use the wall-clock propagation measurements (P1/P2/P3) as the propagation result;
  label histogram-derived convergence non-load-bearing where it is bucket-floored or
  `n_valid=0`. Never present a floored value as a measured quantile.
- Report coverage honestly: how many combos/rows were valid vs dropped (and why), and
  the sample size behind every percentile.

Bound the claim — what this proves and what it does not:

- Proves: 20 mesh-member clusters, 10,000 Kubernetes Service objects, 10,000 endpoints
  (1 per Service) formed one mesh and operated within the stated headroom.
- Does not prove: multi-endpoint-per-Service fan-out (this run is 1 endpoint/Service),
  10,000 globally unique hostnames (names repeat across clusters), or behavior under a
  loaded-mesh data plane (the non-control-plane suites are isolated, unloaded baselines).
  State these boundaries in the report so the result is not over-read.

Final cleanup always runs:

1. All suite cleanup scripts.
2. Poll until zero `*-test` namespaces remain.
3. Verify mesh health.
4. Destroy platform Terraform.
5. Destroy ROSA HCP Terraform.
6. If VPC deletion blocks on ROSA-created leftovers, run the repo pre-destroy cleanup
   helper and retry destroy.

The campaign is done only when the report is assembled, the cleanup is verified, and
the disposable infrastructure is destroyed or an explicit user decision keeps it up.

# 20c/10k/10k peak campaign plan

Date: 2026-06-22

This is the execution plan for a disposable full-lifecycle campaign on latest `main`.
It provisions 21 ROSA HCP clusters, uses one hub plus 20 mesh-member spokes, verifies
the full 20-cluster Istio mesh on small fixed worker pools first, scales the spokes up
only after Istio works, then runs a peak-only campaign at `mesh_size=20`.

Target definition:

- 20 mesh-member spoke clusters.
- 500 Kubernetes Services per spoke.
- 1 workload replica per Service.
- 10,000 Kubernetes Service objects total.
- 10,000 workload endpoints total.

Repeated service names across clusters are acceptable for this campaign. The run is
measuring the 10,000 Kubernetes Service object / endpoint shape, not 10,000 globally
unique hostnames.

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
- Hub cluster: fixed `4 x m5.4xlarge`.
- Spoke clusters, initial verification phase: fixed `3 x m5.4xlarge`.
- Spoke clusters, campaign phase: fixed `8 x m5.4xlarge`.
- Fixed means `replicas`, `worker_autoscale_min`, and `worker_autoscale_max` are all
  set to the same node count for the relevant cluster group.

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
2. Write kubeconfig locally and set `CONTEXTS=cluster-002,...,cluster-021`.
3. Apply platform Terraform.
4. Run `terraform/platform/scripts/001-openapi-preflight.sh` on the hub.
5. Ramp mesh membership through `1 -> 5 -> 10 -> 20`.
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
- Live capacity gate says `500 services x 1 replica` will not fit.
- istiod restart, OOM, or RSS approaching the 16Gi per-pod limit.

Before peak sweeps, calibrate `FANOUT_MAX_SKEW_MS` from a low-impact 20-context probe
instead of trusting the provisional default.

## Campaign matrix

Use `MESH=20` only. Run suites serially. Never run two suites or probes at the same
time because they share the same istiod metrics and xDS counters.

Propagation:

```bash
tests/propagation/006-run-sweep.sh \
  --contexts "$CONTEXTS" \
  --mesh-sizes 20 \
  --iterations 30 \
  --tsv
```

Churn:

```bash
tests/churn/003-run-sweep.sh \
  --contexts "$CONTEXTS" \
  --mesh-sizes 20 \
  --churn-intensities 5 \
  --iterations 5
```

Control plane:

```bash
tests/controlplane/003-run-sweep.sh \
  --contexts "$CONTEXTS" \
  --mesh-sizes 20 \
  --service-counts 500 \
  --replica-counts 1 \
  --namespace-counts 1 \
  --sidecar-scopings none,namespace,explicit
```

Data plane:

```bash
tests/dataplane/003-run-sweep.sh \
  --contexts "$CONTEXTS" \
  --mesh-sizes 20 \
  --qps-levels 10,100,500,1000
```

Churn plus data plane:

```bash
tests/churn-dataplane/004-run-sweep.sh \
  --contexts "$CONTEXTS" \
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

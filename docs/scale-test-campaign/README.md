# Scale-test campaign runbook

How to run all five suites (`propagation`, `churn`, `controlplane`, `dataplane`,
`churn-dataplane`) across a list of mesh sizes and collect comparable results. Each suite
writes a markdown summary and TSVs under `tests/<suite>/results/sweep-<RUN_ID>/`.

- **Manual:** run the stages below by hand.
- **Agent-driven:** give a coding session [`agent-operator-brief.md`](agent-operator-brief.md).
- **500 spokes:** also follow [`500-spoke-profile.md`](500-spoke-profile.md).
- **Diagrams:** [`architecture.md`](architecture.md). **Past results:** [`docs/campaigns/`](../campaigns/).

> Context names in this repo are placeholders. Pass your own with `--contexts` /
> `SETUP_CONTEXTS`, and never commit real cluster names, hostnames or kubeconfig contents.

## Prerequisites

1. **A healthy multi-primary mesh** across your spoke clusters. The ACM hub is not a mesh member.
   Verify per [README → Verify](../../README.md#verify).
2. **istiod pinned to a fixed replica count** (HPA off) on every spoke: `charts/spoke-ossm`
   `pilot.autoscaleEnabled: false`, `pilot.replicaCount: <K>` (default 3). An autoscaling istiod
   changes topology mid-sweep and corrupts the xDS deltas.
3. **Enough CPU for the workload** — see [Capacity planning](#capacity-planning).
4. **A kubeconfig with every mesh-member context.** Set `SETUP_CONTEXTS` in `config/versions.env`
   or pass `--contexts`: mesh members only, never the ACM hub. Token/OAuth credentials must stay
   valid for the whole multi-hour run.
5. **Tools:** `kubectl`/`oc`, `helm`, `jq`, `curl`, `awk`.

## Capacity planning

Sidecar CPU requests, not istiod, are the main capacity driver. Every test pod gets an
istio-proxy sidecar requesting **100m** (`charts/spoke-ossm` `proxy.resources`); the app
container requests ~0. On a fixed node count this caps services per cluster:

```
max_services_per_cluster ≈ (node_alloc_cpu − istiod_cpu_limit × istiod_replicas) / (replicas × sidecar_request_m)
```

`tests/controlplane/003-run-sweep.sh` prints a plan-time WARN for the largest combo using
`SCALE_PER_POD_CPU_M` (default **200m**, a 2× margin over the real 100m request), and
`001-setup` refuses to start when a cluster lacks pod slots. OpenShift system pods reduce the
free CPU further.

Example with current defaults (istiod 3 × 4000m) on the 2026-06-22 spokes (124,000m allocatable):
`(124,000 − 12,000) / (1 × 100) ≈ 1,120` services per cluster at 1 replica (≈560 by the 200m WARN).
That run used 500.

> **Let metrics-server settle after heavy churn.** The utilization columns
> (`istiod_*_pct_of_limit`, `node_*_pct`) come from `kubectl top`. Right after scaling istiod or
> deleting thousands of pods, metrics-server can be unavailable and those columns go N/A for the
> whole sweep (the harness warns and continues). Wait until `kubectl top nodes` succeeds on every
> context before the next sweep.

## Procedure

```bash
# Set once. Mesh members only — never the ACM hub.
CONTEXTS="<mesh-a-ctx>,<mesh-b-ctx>"
MESH="1,2"                            # mesh sizes to sweep; up to the number of contexts
export KUBECONFIG=<path-to-kubeconfig>
```

### Stage 0 — Verify the mesh

On every spoke, istiod shows the pinned `K/K` ready and its remote-cluster view is synced:

```bash
for ctx in ${CONTEXTS//,/ }; do
  pod=$(kubectl --context="$ctx" -n istio-system get pod -l app=istiod -o name | head -1)
  kubectl --context="$ctx" -n istio-system exec "${pod#pod/}" -c discovery -- \
    pilot-discovery request GET /debug/clusterz | grep -o '"syncStatus":"[^"]*"' | sort | uniq -c
done
# Expect: every spoke reports N entries (1 local + N-1 remote), all "synced".
```

### Stage 1 — Preflight

- Tools present.
- No leftover `*-test` namespaces (`propagation-test`, `controlplane-test*`, `dataplane-test`,
  `churn-test`, `churn-dataplane-test`). If any exist, run that suite's cleanup script first.

### Stage 2 — Dry-run every sweep (no clusters touched)

```bash
tests/propagation/006-run-sweep.sh    --contexts "$CONTEXTS" --mesh-sizes "$MESH" --iterations 10 --force-large-matrix --dry-run
tests/churn/003-run-sweep.sh          --contexts "$CONTEXTS" --mesh-sizes "$MESH" --dry-run
tests/controlplane/003-run-sweep.sh   --contexts "$CONTEXTS" --mesh-sizes "$MESH" --sidecar-scopings none,namespace,explicit --force-large-matrix --dry-run
tests/dataplane/003-run-sweep.sh      --contexts "$CONTEXTS" --mesh-sizes "$MESH" --qps-levels 10,100,500,1000 --force-large-matrix --dry-run
tests/churn-dataplane/004-run-sweep.sh --contexts "$CONTEXTS" --mesh-sizes "$MESH" --churn-rates 1,5,10 --force-large-matrix --dry-run
```

`--force-large-matrix` is needed when a matrix exceeds the suite's cap (`*_MAX_MATRIX`,
default 64). Check each printed matrix before running live.

### Stage 3 — Run the suites one at a time

Never run two suites at once: they all measure the same istiod. Run in this order, each to
completion:

```bash
# 1. propagation — xDS propagation latency (~tens of min)
tests/propagation/006-run-sweep.sh    --contexts "$CONTEXTS" --mesh-sizes "$MESH" --iterations 10 --force-large-matrix --tsv

# 2. churn — convergence under endpoint churn (~tens of min)
tests/churn/003-run-sweep.sh          --contexts "$CONTEXTS" --mesh-sizes "$MESH"

# 3. controlplane — istiod resource scaling (~1–2h)
tests/controlplane/003-run-sweep.sh   --contexts "$CONTEXTS" --mesh-sizes "$MESH" --sidecar-scopings none,namespace,explicit --force-large-matrix

# 4. dataplane — cross-cluster latency (~2h+)
tests/dataplane/003-run-sweep.sh      --contexts "$CONTEXTS" --mesh-sizes "$MESH" --qps-levels 10,100,500,1000 --force-large-matrix

# 5. churn-dataplane — latency delta under churn (longest)
tests/churn-dataplane/004-run-sweep.sh --contexts "$CONTEXTS" --mesh-sizes "$MESH" --churn-rates 1,5,10 --force-large-matrix
```

Between suites, confirm the previous suite's `*-test` namespaces are gone and repeat Stage 0.

### Stage 4 — Collect results

Read each suite's markdown summary (re-generate with its `004`/`005` report script if needed).
Reports drop poisoned or incomplete rows and print `n_valid` vs `n_total`; read that first.
Fill one row per suite:

| Suite | SLA verdict | Headline (one line) | Usable? |
|-------|-------------|---------------------|---------|
| propagation | PASS/CAUTION/FAIL | _e.g. P3 remote sidecar p99 X ms_ | yes/no |
| churn | PASS/CAUTION/FAIL | _e.g. push amplification ~X_ | yes/no |
| controlplane | PASS/CAUTION/FAIL | _verdict line from `scale-envelope-<RUN_ID>.md`_ | yes/no |
| dataplane | PASS/CAUTION/FAIL | _e.g. cross-cluster p99 X ms at QPS Y_ | yes/no |
| churn-dataplane | PASS/CAUTION/FAIL | _e.g. Δp99 under churn X ms_ | yes/no |

The campaign is **GO** only if every suite is usable and no verdict is FAIL. A CAUTION or FAIL
on low `n_valid` means re-run, not a final verdict. Write up the run from
[`docs/campaigns/TEMPLATE.md`](../campaigns/TEMPLATE.md).

### Stage 5 — Clean up (always, even after a failure)

Cleanup is idempotent and removes only the test workloads, not the mesh:

```bash
tests/churn-dataplane/006-cleanup.sh --contexts "$CONTEXTS"
tests/churn/005-cleanup.sh           --contexts "$CONTEXTS"
tests/controlplane/005-cleanup.sh    --contexts "$CONTEXTS"
tests/dataplane/005-cleanup.sh       --contexts "$CONTEXTS"
tests/propagation/007-cleanup.sh     --contexts "$CONTEXTS"

# Namespace deletion is async. Re-run until it prints nothing:
for ctx in ${CONTEXTS//,/ }; do
  kubectl --context="$ctx" get ns 2>/dev/null \
    | grep -E 'propagation-test|controlplane-test|dataplane-test|churn-test|churn-dataplane-test' \
    && echo "  ^ still on $ctx"
done
```

## Pitfalls

- **`FailedScheduling: Insufficient cpu`:** not enough CPU. Add nodes, lower
  `--service-counts`/`--replica-counts` (controlplane) or `--deployment-count`/`--scale-to`
  (churn-dataplane), or lower istiod's CPU request (scheduling only, not measurements).
- **Failures mid-sweep:** a failed probe is recorded as a `PROBE_FAILED` row and the sweep
  continues. A hung port-forward still shows as a live process with no log growth, so keep
  watching the log. If a sweep process dies, run that suite's cleanup and re-run the remaining
  `--mesh-sizes` (controlplane: `--resume <sweep-dir>`).
- **Credentials:** rotate after the campaign, not during it.
- **Runtime:** several hours in total; churn-dataplane is the longest. More nodes shorten pod
  scheduling without affecting results.

## See also

- Per-suite details: `tests/<suite>/README.md`.
- Harness change review: [`docs/scale-test-team/`](../scale-test-team/).
- Version pins and defaults: `config/versions.env`, `config/options.env`.

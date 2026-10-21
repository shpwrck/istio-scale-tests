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

1. **A healthy multi-primary mesh** across your spoke clusters. The hub is not a mesh member.
   Verify per [README → Verify](../../README.md#verify).
2. **istiod pinned to a fixed replica count** (HPA off) on every spoke: `charts/spoke-ossm`
   `pilot.autoscaleEnabled: false`, `pilot.replicaCount: <K>` (default 3). An autoscaling istiod
   changes topology mid-sweep and corrupts the xDS deltas.
3. **Enough CPU for the workload** — see [Capacity planning](#capacity-planning).
4. **A kubeconfig with every mesh-member context.** Set `SETUP_CONTEXTS` in `config/versions.env`
   or pass `--contexts`: mesh members only, never the hub. Token/OAuth credentials must stay
   valid for the whole multi-hour run.
5. **Tools:** `kubectl`/`oc`, `helm`, `jq`, `curl`, `awk`, and GNU `timeout` (macOS: `brew install
   coreutils` for `gtimeout`; the controlplane suite stops at startup without one).
6. **The `ISTIO_VERSION` pin matches the mesh.** Every suite but gateway-api reads the version
   each member runs (its active IstioRevision) before its first change and stops when it differs
   from `ISTIO_VERSION` (`config/versions.env`), when members differ, or when one cannot be read;
   gateway-api, a read-only check, records it and goes on. Fix the pin (or the mesh);
   `ISTIO_VERSION_CHECK=warn` runs anyway and records what the mesh runs. A member whose istiod
   or IstioCNI is not ready, or whose istiod is rolling out, is read again for up to
   `ISTIO_VERSION_READY_WAIT_SEC` (60 s), then recorded with a warning (a rollout still going
   on reads as unknown); the members still not ready are in `ISTIO_NOTREADY_AT_START` in every
   TSV preamble and report. A sweep reads it again at the end and exits 4 when the version or the
   active revision changed during the sweep, or when the generation of a member's Istio CR or
   active IstioRevision went up with the same version (an edit of the Istio CR, an OSSM operator
   upgrade, a TLS profile change; a tuning sweep's own apply and revert do not count), and
   when its harness (`HARNESS_SHA`: a file under `tests/`, `config/`, `charts/` or `terraform/`)
   changed during it. Every sweep ends by writing `sweep-outcome.txt` to its results dir (exit
   code, failed cells, the version recheck), and its reports repeat those errors and warnings.
   Until then the file says `STATUS=running`; a sweep that stops on an error records
   `STATUS=stopped` with its reason, one interrupted `STATUS=interrupted` with the signal, and
   one killed outright leaves `STATUS=running`. A sweep dir without that file is from a sweep that
   stopped before its start (nothing ran) or from an older harness. Do not edit, check out or
   pull the checkout a sweep runs from until it ends.

## Capacity planning

Sidecar CPU requests, not istiod, are the main capacity driver. Every test pod gets an
istio-proxy sidecar requesting **100m** (`charts/spoke-ossm` `proxy.resources`); the app
container requests ~0. On a fixed node count this caps services per cluster:

```
max_services_per_cluster ≈ (node_alloc_cpu − cpu_requested_by_other_pods) / (replicas × sidecar_request_m)
```

`tests/controlplane/003-run-sweep.sh` prints a plan-time WARN for the largest combo using the
sidecar CPU request it reads from the live Istio CR (`spec.values.global.proxy.resources`; Istio's
100m when unset), or `SCALE_PER_POD_CPU_M` when set, against each member's worker allocatable minus
what its running pods (OpenShift, istiod, gateways, monitoring) already request; the tightest
member decides. `001-setup` refuses a step when a member lacks pod slots or free CPU requests for
it (`SCALE_CPU_PREFLIGHT_ENFORCE=0` warns instead, for a node autoscaler). On the lab hub the
other pods requested 14.6 of 19.5 cores, so about 49 test pods fit, not the 175 that allocatable
minus istiod suggested.

Rough example counting only istiod (3 × 4000m) on the 2026-06-22 spokes (124,000m allocatable):
`(124,000 − 12,000) / (1 × 100) ≈ 1,120` services per cluster at 1 replica; that run used 500.
OpenShift's own pods lower it; the plan prints the real figure per member.

**Gateway memory.** Every gateway keeps `*/*`, so its Envoy memory follows the Services in the
whole mesh, not the cluster: the east-west gateway allocates about **145 Mi per 1000 Services**
and the ingress gateway about **91 Mi** (ROSA, 2026-10-14). After config bursts the east-west
gateway's working set ran 1.2-2.9× its allocated memory (tcmalloc keeps freed pages), so size
its limit as `(10 + 145 × Services / 1000) Mi × 2.5` and the ingress as `(10 + 91 × Services /
1000) Mi × 1.5`. For the 10k campaign that is about 3.6 GiB and 1.4 GiB: the chart defaults are
5Gi and 2Gi. The east-west default sits above the rule because a one-step burst to 10k Services
peaked at 3.4 GiB (ROSA, 2026-10-16) and a second burst keeps more. The controlplane sweep's
memory guard uses the same model. Both figures and the 2.5× / 1.5× guard factors come from OSSM
3.x proxies on ROSA and are not validated on upstream Istio builds or on kind (where every node
reports the whole host): measure them before sizing a campaign there.

> **Let metrics-server settle after heavy churn.** The utilization columns
> (`istiod_*_pct_of_limit`, `node_*_pct`) come from `kubectl top`. Right after scaling istiod or
> deleting thousands of pods, metrics-server can be unavailable and those columns go N/A for the
> whole sweep (the harness warns and continues). Wait until `kubectl top nodes` succeeds on every
> context before the next sweep.

## Procedure

```bash
# Set once. Mesh members only — never the hub.
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
tests/propagation/006-run-sweep.sh    --contexts "$CONTEXTS" --mesh-sizes "$MESH" --iterations 10 --force-large-matrix

# 2. churn — convergence under endpoint churn (~tens of min)
tests/churn/003-run-sweep.sh          --contexts "$CONTEXTS" --mesh-sizes "$MESH"

# 3. controlplane — istiod resource scaling (~1–2h)
tests/controlplane/003-run-sweep.sh   --contexts "$CONTEXTS" --mesh-sizes "$MESH" --sidecar-scopings none,namespace,explicit --force-large-matrix
#    Optional (off by default): add --traffic-configs none,vsdr to also measure a
#    VirtualService + DestinationRule per service (doubles the matrix).

# 4. dataplane — cross-cluster latency (~2h+)
tests/dataplane/003-run-sweep.sh      --contexts "$CONTEXTS" --mesh-sizes "$MESH" --qps-levels 10,100,500,1000 --force-large-matrix

# 5. churn-dataplane — latency delta under churn (longest)
tests/churn-dataplane/004-run-sweep.sh --contexts "$CONTEXTS" --mesh-sizes "$MESH" --churn-rates 1,5,10 --force-large-matrix
```

Between suites, confirm the previous suite's `*-test` namespaces are gone and repeat Stage 0.
Check each sweep's exit code: `4` means it finished and wrote its reports but some cells
failed (the last stderr line says how many, by reason; their placeholder rows are in the
report), or the mesh changed under it (the Istio version, the active revision, or the
generation of an Istio CR or active IstioRevision; or that end-of-sweep check failed), or its
harness did (`HARNESS_SHA`); `3` a reachability stop; `1` it stopped; `130`, `143` or `129` it
was interrupted (Ctrl-C, SIGTERM, a closed terminal). `sweep-outcome.txt` in each sweep dir
keeps the outcome. Each suite README lists its codes.

### Stage 4 — Collect results

Read each suite's markdown summary (re-generate it with the suite's `004`/`005` report script
and `--results-dir tests/<suite>/results/sweep-<RUN_ID>`; a report of a dir with more than one
run stops and lists them, unless `--allow-multi-run` pools them on purpose).
Reports drop poisoned or incomplete rows and print `n_valid` vs `n_total`; read that first.
For dataplane and churn-dataplane, also read the `Remote coverage` section (every remote
REACHABLE?) and, for dataplane, the `Local baseline` verdict (OK at every QPS level?):
`n_valid` vs `n_total` does not name an unreachable remote or a dropped local cell. To
gate on coverage, run the report with `--fail-on-unreachable` (exit 3 names the remotes).
Record the `Run config` (path + sha256) the sweeps ran with.
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
  `--mesh-sizes` (each run writes a new sweep dir).
- **Credentials:** rotate after the campaign, not during it.
- **Runtime:** several hours in total; churn-dataplane is the longest. More nodes shorten pod
  scheduling without affecting results.

## See also

- Per-suite details: `tests/<suite>/README.md`.
- Harness change review: [`docs/scale-test-team/`](../scale-test-team/).
- Version pins and defaults: `config/versions.env`, `config/options.env`.

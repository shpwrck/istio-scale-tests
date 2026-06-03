# Scale-test campaign — repeatable runbook

How to run the full multi-suite scale-test campaign across mesh sizes and collect comparable results. Two execution modes share one procedure:
- **Mode A — Manual** (no AI): a human runs the ordered commands below.
- **Mode B — Agent-driven**: a coding session follows [`agent-operator-brief.md`](agent-operator-brief.md).

The campaign runs all five suites — `propagation`, `churn`, `controlplane`, `dataplane`, `churn-dataplane` — each sweeping mesh size `1…N`, and produces a per-suite markdown summary + TSV under each suite's `results/sweep-<RUN_ID>/`.

> Cluster/context names in this repo are **placeholders** — always pass your own via `--contexts` / `SETUP_CONTEXTS`. Never commit real cluster names, hostnames, or kubeconfig contents (see `AGENTS.md`).

## Prerequisites (must all hold before starting)
1. **Multi-primary mesh deployed and healthy** across your `N` spoke clusters (the hub/ACM cluster is **not** a mesh member). Verify per `AGENTS.md` → "Verify the mesh".
2. **istiod pinned to a FIXED replica count** (HPA disabled) on every spoke — `charts/spoke-ossm` `pilot.autoscaleEnabled: false`, `pilot.replicaCount: <K>`. This is required for **measurement fidelity**: the probes attribute xDS counters/histograms across a *stable* control-plane topology; an autoscaling istiod scaling mid-sweep corrupts the deltas.
3. **Cluster sized for the workload.** A pinned istiod reserves CPU on every node; the suites also deploy many sidecar-injected pods (controlplane: `service-count × replicas`; churn-dataplane: `deployment-count × scale-to`). If nodes are too small you get `FailedScheduling: Insufficient cpu`. Give the clusters enough nodes/CPU, and keep istiod's CPU **request** modest (it's measurement-neutral — only affects scheduling).
4. **KUBECONFIG with every spoke context.** Set `SETUP_CONTEXTS` in `config/versions.env` (comma-separated) or pass `--contexts`. If the kubeconfig uses a token/OAuth credential, ensure it stays valid for the **entire** multi-hour run.
5. **Tools:** `kubectl`/`oc`, `helm`, `jq`, `curl`, `awk`.

## Procedure (5 stages — same for both modes)

```bash
# Set once. CONTEXTS = your spoke contexts; MESH = 1..N (N = number of contexts).
CONTEXTS="$SETUP_CONTEXTS"           # e.g. "cluster-001,cluster-002,...,cluster-010"
MESH="1,2,3,4,5,6,7,8,9,10"          # adjust to your N
export KUBECONFIG=/path/to/your/kubeconfig
```

### Stage 0 — Verify the mesh
On every spoke: `kubectl -n istio-system get deploy istiod` shows the pinned `K/K` ready, and istiod's remote-cluster view is fully synced:
```bash
for ctx in ${CONTEXTS//,/ }; do
  pod=$(kubectl --context="$ctx" -n istio-system get pod -l app=istiod -o name | head -1)
  kubectl --context="$ctx" -n istio-system exec "${pod#pod/}" -c discovery -- \
    pilot-discovery request GET /debug/clusterz | grep -o '"syncStatus":"[^"]*"' | sort | uniq -c
done
# Expect: every spoke reports N entries (1 local + N-1 remote), all "synced".
```

### Stage 1 — Preflight
- Tools present (Prereq 5).
- **No leftover `*-test` namespaces** on any spoke (`propagation-test`, `controlplane-test*`, `dataplane-test`, `churn-test`, `churn-dataplane-test`). If any exist, run that suite's `00X-cleanup.sh` first.
- Confirm the pinned replica count matches expectations on every spoke.

### Stage 2 — Dry-run every sweep (no clusters touched)
Validate the planned matrix vs the safety cap (`*_MAX_MATRIX`, default 64) **before** committing hours:
```bash
tests/propagation/006-run-sweep.sh    --contexts "$CONTEXTS" --mesh-sizes "$MESH" --iterations 10 --force-large-matrix --dry-run
tests/churn/003-run-sweep.sh          --contexts "$CONTEXTS" --mesh-sizes "$MESH" --dry-run
tests/controlplane/003-run-sweep.sh   --contexts "$CONTEXTS" --mesh-sizes "$MESH" --sidecar-scopings none,namespace,explicit --dry-run
tests/dataplane/003-run-sweep.sh      --contexts "$CONTEXTS" --mesh-sizes "$MESH" --qps-levels 10,100,500,1000 --dry-run
tests/churn-dataplane/004-run-sweep.sh --contexts "$CONTEXTS" --mesh-sizes "$MESH" --churn-rates 1,5,10 --dry-run
```
`--force-large-matrix` is needed for propagation when `mesh_sizes × iterations > 64` (a deliberate override for a full campaign). Confirm each printed matrix is what you intend.

### Stage 3 — Run the suites SERIALLY (light → heavy)
**Never run two suites at once** — they all measure the *same* istiod; concurrent runs contaminate each other's xDS counters/histograms/CPU. Run in this order, each to completion, re-confirming a clean mesh between them:
```bash
# 1. propagation  (xDS propagation latency; ~tens of min)
tests/propagation/006-run-sweep.sh    --contexts "$CONTEXTS" --mesh-sizes "$MESH" --iterations 10 --force-large-matrix --tsv

# 2. churn  (convergence under endpoint churn; ~tens of min)
tests/churn/003-run-sweep.sh          --contexts "$CONTEXTS" --mesh-sizes "$MESH"

# 3. controlplane  (istiod resource scaling; 60s settles dominate; ~1–2h)
tests/controlplane/003-run-sweep.sh   --contexts "$CONTEXTS" --mesh-sizes "$MESH" --sidecar-scopings none,namespace,explicit

# 4. dataplane  (cross-cluster data-plane latency; QPS load dominates; ~2h+)
tests/dataplane/003-run-sweep.sh      --contexts "$CONTEXTS" --mesh-sizes "$MESH" --qps-levels 10,100,500,1000

# 5. churn-dataplane  (latency delta under churn; per-combo setup/teardown; longest)
tests/churn-dataplane/004-run-sweep.sh --contexts "$CONTEXTS" --mesh-sizes "$MESH" --churn-rates 1,5,10
```
**Between every suite:** verify the prior suite's `*-test` namespaces are gone on all spokes (run its `00X-cleanup.sh` if not), and re-confirm istiod is healthy (Stage 0). Then start the next.

### Stage 4 — Collect results
Each suite writes `tests/<suite>/results/sweep-<RUN_ID>/` containing per-run TSV(s) and an auto-generated **markdown summary** (re-generate manually with the suite's `004`/`005` report script if needed). The report scripts filter poisoned/incomplete rows and report `n_valid` vs `n_total` — check those footnotes when reading aggregates.

## Pitfalls & how to handle them (hard-won)
- **`FailedScheduling: Insufficient cpu`** → capacity. The pinned istiod's CPU *requests* + the suites' sidecar-injected pods exceed node allocatable. Add nodes/CPU, or reduce `--service-counts`/`--replica-counts` (controlplane) and `--deployment-count`/`--scale-to` (churn-dataplane) to fit. Lowering istiod's CPU **request** is measurement-neutral and frees scheduling room.
- **A sweep dies/hangs mid-run.** Today a *single* probe-instance failure (a transient scrape returning non-zero, a stuck `kubectl port-forward`) can abort an entire multi-hour sweep under `set -euo pipefail`. **You must actively watch for this** — a hung port-forward looks like *no log growth while the process is still alive* (not a crash). On failure: run the suite's `00X-cleanup.sh`, then re-run only the remaining `--mesh-sizes`. (The harness-hardening work — record-and-continue per probe — removes this; until then, monitor.)
- **Serial only.** See Stage 3.
- **Credential window.** A multi-hour campaign needs the kubeconfig credential valid throughout; rotate *after*, not during.
- **Runtime.** Expect several hours total; churn-dataplane is the long pole (per-combo setup + teardown). Adding nodes (faster pod scheduling) and the deploy-once-per-mesh-size optimization shorten it without affecting fidelity.

## Mode A — Manual (no AI)
Run Stages 0–4 above by hand. Concretely:
1. Stage 0 + Stage 1 checks; fix any failures before proceeding.
2. Stage 2: run all five `--dry-run`s; eyeball each matrix.
3. Stage 3: launch suite 1; **watch it** — `tail -f` the output and periodically confirm the process is alive *and* the log is still growing. When it finishes, run Stage-0 + namespace-clean checks, then launch the next. Repeat for all five.
4. If a suite dies: clean up (its `00X-cleanup.sh`), re-run remaining mesh sizes, continue.
5. Stage 4: read the markdown summaries.
Budget a full day of attended wall-clock; keep a notepad of which suites/sizes completed.

## Mode B — Agent-driven
Hand a coding session [`agent-operator-brief.md`](agent-operator-brief.md). It encodes the same procedure plus the operational discipline that makes an unattended run safe: robust crash **and** stall detection (so a silent hang is caught), record-and-continue, a `CAMPAIGN_STATUS.md` progress file, and "investigate + fix a breaking error before retrying."

## See also
- Per-suite details: `tests/<suite>/README.md`.
- Harness review process: `docs/scale-test-team/`.
- Version/identity pins & contexts: `config/versions.env`, `config/options.env`.

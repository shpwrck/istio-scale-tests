# istio-scale-tests

Deploy a multi-primary, multi-network Istio mesh (the Sail operator) across several Kubernetes
clusters, then measure how it scales. One cluster is the hub (Argo CD, cert-manager, External
Secrets); every other cluster runs its own istiod and joins the mesh through east-west gateways,
with a shared root CA.

Vanilla Kubernetes is the default (`platform = "kubernetes"`), with upstream Argo CD and the
upstream Sail operator. It is tested on kind; other conformant clusters (kubeadm, EKS, ...) need
only what [What you need](#what-you-need) lists. OpenShift is an optional profile
(`platform = "openshift"`): Red Hat OpenShift Service Mesh 3, OpenShift GitOps and ACM, on existing
clusters or new ROSA ones. It is kept for teams that run OpenShift but is untested: its last end to
end run (ROSA, October 2026) predates the switch to Kubernetes by default.

```mermaid
flowchart TB
    hub["<b>hub</b><br/><i>never a mesh member</i><br/>Argo CD · cert-manager · ESO<br/>(+ ACM on OpenShift)"]

    subgraph A["mesh member A"]
        direction TB
        istiodA["istiod"]
        ingA["ingress gw"]
        ewA["east-west gw"]
    end

    subgraph B["mesh member B"]
        direction TB
        istiodB["istiod"]
        ingB["ingress gw"]
        ewB["east-west gw"]
    end

    ew(["east-west :15443<br/>(cross-network mTLS)"])

    hub -->|"charts: Argo CD ApplicationSets"| A
    hub -.->|"ESO: cacerts +<br/>Istio remote secrets"| A
    hub --> B
    hub -.-> B
    ewA <--> ew
    ewB <--> ew
```

## What you need

- `kubectl` (`oc` also works), `terraform` >= 1.14.8, `helm` (3 or 4), `jq`, `curl`, bash 4+
- `istioctl` matching `ISTIO_VERSION` in `config/versions.env` (for diagnostics)
- `python3` with PyYAML (tuning suite only)
- Mesh members must be able to provision `type: LoadBalancer` Services (a cloud provider, MetalLB,
  or cloud-provider-kind on kind), and the hub must reach every member's API server.
- The Gateway API CRDs on every member for the gateway-api check (OpenShift installs them).
- The metrics API (metrics-server) on every member for the controlplane suite's utilization-%
  columns (OpenShift ships it); without it those columns read `N/A`.

## Deploy

**Kubernetes (default):** use `terraform/platform` in kubeconfig mode. Name the hub context and
the member contexts (DNS labels: they become the cluster names). The apply installs Argo CD on the
hub with its Helm chart and registers every member as an Argo CD cluster (a cluster-admin
ServiceAccount token per member). See [terraform/platform/README.md](terraform/platform/README.md).
To try it on one machine, [docs/runbooks/kind-lab](docs/runbooks/kind-lab/README.md) builds a hub
and two members with kind.

**OpenShift (optional profile):** set `platform = "openshift"`. On existing clusters use kubeconfig
mode, with the brownfield switches for anything already installed. For new ROSA clusters, create
them with [terraform/rosa-hcp](terraform/rosa-hcp/README.md) (it covers the one-time AWS and Red Hat
account setup and a preflight check), then apply `terraform/platform` with
`cluster_provider = "rosa"`. The apply installs ACM and OpenShift GitOps unless already present.

Either way the apply starts the app-of-apps, and Argo CD rolls out the mesh in sync waves
([charts/README.md](charts/README.md)). It's done when every Application on the hub is
Synced/Healthy (`terraform output gitops_namespace` names the namespace: `argocd`, or
`openshift-gitops` on OpenShift):

```bash
kubectl --context <hub-ctx> get applications.argoproj.io -n argocd
```

## Verify

Every member runs `mesh-wiring-verify`, a gate that is Ready only when the member holds a remote
secret for every member, istiod has ingested them all, and istiod signs with the shared root.
Otherwise its Argo Application goes Degraded.

```bash
kubectl --context <mesh-a-ctx> exec -n mesh-wiring-verify deploy/mesh-wiring-verify -- sh /opt/check/readiness.sh
# Ready: secrets=2 istiod_managed=2 (local=1 remote=1) expected=2 ca=shared
```

End to end: deploy the echo app and call it through any member's ingress gateway. Answers should come
from every member. The manifest keeps placeholders for the repo, the revision, the platform and the
Argo CD namespace; fill them in on the way to the hub from what the hub already syncs, so the check
runs the same charts as the mesh.

```bash
NS=argocd PLATFORM=kubernetes   # OpenShift: NS=openshift-gitops PLATFORM=openshift
read -r REPO REV < <(kubectl --context <hub-ctx> -n "$NS" get application hub-gitops-root \
  -o jsonpath='{.spec.source.repoURL} {.spec.source.targetRevision}')
fill() { sed -e "s|<repo-url>|${REPO:?}|g" -e "s|<revision>|${REV:?}|g" \
  -e "s|<platform>|${PLATFORM}|g" -e "s|<gitops-namespace>|${NS}|g" charts/mesh-verify-appset.yaml; }
fill | kubectl --context <hub-ctx> apply -f -
INGRESS=$(kubectl --context <mesh-a-ctx> get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}')
for i in $(seq 10); do curl -s -H 'Host: mesh-verify.local' "http://$INGRESS/"; done
fill | kubectl --context <hub-ctx> delete -f -
```

Gateway API: [`tests/gateway-api`](tests/gateway-api/README.md) checks whether an HTTPRoute reaches a
workload that runs in another member, with or without a Service, or the Service's namespace, in the
ingress member (`charts/mesh-verify-gateway-api-appset.yaml` deploys it the same way).

## Run tests

Point the suites at the **mesh members only** (`--contexts <mesh-a-ctx>,<mesh-b-ctx>`, or
`SETUP_CONTEXTS`), never the hub. Each suite writes TSV data plus a markdown summary under its
`results/` directory. Every script has `--help`, and scripts that change a cluster also accept
`--dry-run`.

| Suite | Measures | Start with |
| --- | --- | --- |
| [propagation](tests/propagation/README.md) | How fast an endpoint change reaches the other clusters | `tests/propagation/006-run-sweep.sh` |
| [controlplane](tests/controlplane/README.md) | istiod CPU/memory, xDS pushes and per-proxy config size vs mesh size and Sidecar scoping | `tests/controlplane/003-run-sweep.sh` |
| [dataplane](tests/dataplane/README.md) | Same-cluster vs cross-cluster latency through the east-west gateways | `tests/dataplane/003-run-sweep.sh` |
| [churn](tests/churn/README.md) | Convergence time when Deployments scale on one cluster | `tests/churn/003-run-sweep.sh` |
| [churn-dataplane](tests/churn-dataplane/README.md) | p99 latency change while endpoint churn runs | `tests/churn-dataplane/004-run-sweep.sh` |
| [tuning](tests/tuning/README.md) | Any suite above, with and without an istiod/proxy tuning profile | `tests/tuning/003-run-tuning-sweep.sh` |
| [gateway-api](tests/gateway-api/README.md) | Whether an HTTPRoute needs its backend Service, or its namespace, in every member (read-only check; deploy `charts/mesh-verify-gateway-api-appset.yaml` first) | `tests/gateway-api/001-run-ingress-check.sh` |

```bash
tests/propagation/006-run-sweep.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> --mesh-sizes 1,2 --iterations 5 --dry-run
```

Settings and image pins live in `config/versions.env` and `config/options.env`. The deployed Istio
version is `istioVersion` in `charts/spoke-ossm/values.yaml`; keep `ISTIO_VERSION` equal to it.

### Run config (`--config FILE`)

Every numbered script of propagation, controlplane, dataplane, churn, churn-dataplane and
gateway-api takes `--config FILE`: one file of `KEY=value` lines (the suite's `config/options.env`
keys plus `SETUP_CONTEXTS`) that describes a whole run, so setup, sweep, report and cleanup read
the same values. Each of these suites has a worked example, `tests/<suite>/configs/smoke.env`,
and a "Run config" section in its README that lists its keys. Tuning does not take one yet.

- **Precedence:** flag > `--config` > environment > default. The file loads before
  `options.env`, so the defaults derived there follow it. Each key is logged on stderr, with the
  environment value it overrides. `KEY=` (empty) means the built-in default.
- **Syntax:** the file is parsed, never sourced, so it cannot run code:
  `[export ]KEY=value [# comment]`, where the value is unquoted from `[A-Za-z0-9_.,:/@%+=-]`,
  `'...'`, or `"..."` without `"`, `$`, `` ` `` and `\`. No spaces around `=`, each key once. A
  bad line or a key outside the suite's list rejects the whole file before anything runs, with
  `file:line` and the reason.
- **Environment only:** `*_TEST_NAMESPACE` (cleanup deletes that namespace), `*_MAX_MATRIX` (the
  `--force-large-matrix` acknowledgment stays per run) and the version pins in
  `config/versions.env`.
- **Flags only:** run switches such as `--dry-run`, `--force-large-matrix` and `--format`, and
  what a sweep passes to each step (`--source-context`, `--remote-contexts`, `--mesh-size`, ...).
  A standalone step still takes those on the command line.
- **Sweeps:** the steps a sweep runs inherit the file's values; the flags it passes them still
  win. Before the first step a sweep checks its numeric knobs: the ones it passes its steps as
  flags (durations, QPS, connections, settle times, ...) and the ones only its steps read (setup
  and cleanup timeouts, poll intervals, ...). A value such as `5m` fails `--dry-run` instead of
  every setup, every cleanup, or the probe window (fortio would read `5m` seconds as 5 ms).
- **Context names:** keep real ones out of git. Copy an example to
  `tests/<suite>/configs/<name>.local.env` (gitignored) and set `SETUP_CONTEXTS` there.
- **Provenance:** every TSV preamble records `RUN_CONFIG` (the file's path from the repo root, or
  only its name outside the repo; `none` without `--config`) and `RUN_CONFIG_SHA256`, and every
  report format repeats them: `unknown` for files written before these keys existed, and
  `mixed:<a>,<b>` with a warning when the inputs disagree. A sweep copies the file to
  `sweep-<RUN_ID>/run-config-<RUN_ID>.env`, and every probe's per-run markdown summary has a
  `Run config` row. With `--config` but no `--results-dir`, a report warns
  when the results dir holds more than one run (each `sweep-*` directory is one run; outside
  one, each `RUN_ID`).

## Grow the mesh

`mesh_member_count` in `terraform/platform` sets how many spokes join, in sorted order (0 = all).
Raise it and re-apply; the wiring gate's expected size follows automatically.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Gate says `istiod is not using the shared mesh root` | istiod started before `cacerts`. Delete the member's `<member>-ossm` Application on the hub (it's recreated and waits for `cacerts`), then restart that member's gateways. |
| No `cacerts` or remote secrets on members | Check the ESO pods on the hub (`kubectl get pods -n external-secrets-operator`); on a small hub lower the Argo CD requests with `argocd_helm_values` (`argocd_config_values` on OpenShift). |
| Gateway Service stays `<pending>` | No LoadBalancer provider, or a MetalLB pool with auto-assign off: add `metallb.io/address-pool` via `gitops_app_overrides`. |
| `istioctl` errors on API versions | Use an `istioctl` that matches `ISTIO_VERSION`. |

## More

- [AGENTS.md](AGENTS.md): repo conventions for contributors and coding agents
- [docs/scale-test-campaign](docs/scale-test-campaign/README.md): end-to-end campaign runbook; [docs/campaigns](docs/campaigns/README.md): recorded results
- [docs/runbooks](docs/runbooks): a kind lab on one machine, operating a deployed lab, or a ROSA validation run

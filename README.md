# istio-scale-tests

Deploy a multi-primary, multi-network Istio mesh (the Sail operator) across several Kubernetes
clusters, then measure how it scales. One cluster is the hub (Argo CD, cert-manager, External
Secrets); every other cluster runs its own istiod and joins the mesh through east-west gateways,
with a shared root CA.

Vanilla Kubernetes is the default (`platform = "kubernetes"`), with upstream Argo CD and the
upstream Sail operator. It is tested on kind; other conformant clusters (kubeadm, EKS, ...) need
what [What you need](#what-you-need) lists, its capacity included. OpenShift is an optional profile
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
  or cloud-provider-kind on kind). Each member is registered at one API server URL (its
  kubeconfig context's server, or `cluster_api_url_overrides`): the hub's pods and every other
  member's istiod must all reach it.
- Capacity, at the chart defaults (sized for the 20-cluster campaign): each member requests about
  12.2 CPU / 49 GiB (istiod 3 × 4 CPU / 16 GiB, the two gateways 0.2 CPU / 1.1 GiB). The hub's
  Argo CD requests about 3 CPU / 6 GiB plus 2 CPU / 4 GiB per application controller, one per
  3 clusters counting the hub (`argocd_clusters_per_shard`): 5 CPU / 10 GiB with 2 members,
  17 CPU / 34 GiB with 20. Smaller clusters need the overrides in
  [terraform.tfvars.example](terraform/platform/terraform.tfvars.example) (`gitops_app_overrides`
  for istiod, `argocd_helm_values` for Argo CD), as the
  [kind lab](docs/runbooks/kind-lab/README.md) sets them.
- The CNI plugin and its config where the Sail `default` profile puts them (`/opt/cni/bin`,
  `/etc/cni/net.d`). k3s, MicroK8s and other distributions that keep them elsewhere need
  `istioCni.values` in `charts/spoke-ossm` (e.g. `global.platform: k3s`) through
  `gitops_app_overrides` for `spoke-ossm-appset`.
- The Gateway API CRDs on every member for the gateway-api check (OpenShift installs them; on
  Kubernetes use the pinned install in [tests/gateway-api](tests/gateway-api/README.md#deploy)).
- The metrics API (metrics-server) on every member for the controlplane report's utilization-%
  columns (OpenShift ships it); without it `istiod_*_pct_of_limit` and `node_*_pct` read `N/A`
  and the memory guard reads the gateways from Envoy's stats. kind: see its
  [runbook](docs/runbooks/kind-lab/README.md#6-smoke-run-a-suite), which also lists the figures a
  kind lab cannot give.

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
secret for every member, every Ready istiod replica has ingested them all and synced every other
member, istiod signs with the shared root, and the east-west gateway has an address. Otherwise its
Argo Application goes Degraded, and the gate's output says why.

```bash
kubectl --context <mesh-a-ctx> exec -n mesh-wiring-verify deploy/mesh-wiring-verify -- sh /opt/check/readiness.sh
# Ready: secrets=2 istiod_managed=2 (local=1 remote=1) expected=2 ca=shared synced=1 replicas=3 root=<fingerprint> eastwest=<address>
```

`root=` is the first 16 hex digits of the SHA-256 of the root certificate in `cacerts`: compare it
across members, it must read the same on every one. `replicas=` counts the Ready istiod replicas
the gate read; each connects to every member on its own, so the istiod figures and `synced=` are
the lowest any of them reports. `synced=` comes from istiod's metric, which changes only when
istiod (re)connects: a member token revoked later still reads synced, and shows as errors in
istiod's log.

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
# Wait for the echo workload on every member (Argo CD creates it within a few minutes).
for ctx in <mesh-a-ctx> <mesh-b-ctx>; do
  for i in $(seq 60); do kubectl --context "$ctx" -n mesh-verify get deploy mesh-verify-echo >/dev/null 2>&1 && break; sleep 5; done
  kubectl --context "$ctx" -n mesh-verify rollout status deploy/mesh-verify-echo --timeout=300s
done
INGRESS=$(kubectl --context <mesh-a-ctx> get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}')
: "${INGRESS:?the ingress gateway Service has no address yet (see Troubleshooting)}"
for i in $(seq 10); do curl -sS -H 'Host: mesh-verify.local' "http://$INGRESS/"; done
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

Every TSV, run summary and report also records what each member ran on: Kubernetes or OpenShift,
the mesh operator build, the istiod and proxy images and the nodes' provider
([tests/lib/platform.sh](tests/lib/platform.sh)). `TEST_PLATFORM` (`auto`, the default, asks each
member; `kubernetes` or `openshift` is used as given) picks each suite chart's OpenShift overlay;
the record still asks each member what it serves, outside every measurement window, and warns when
that differs from the override. A report warns when its inputs differ on any of these, so compare
results within one platform and mesh build. On kind every node reports the whole host, so the
controlplane report flags its capacity figures.

| Record key | Values |
| --- | --- |
| `PLATFORM` | `kubernetes` or `openshift` over the members; `mixed` when they run both, else `unknown` when any member is |
| `TEST_PLATFORM` | The override as set: `auto`, `kubernetes` or `openshift` |
| `PLATFORM_BY_CONTEXT` | What each member serves, asked even with an override |
| `MESH_OPERATOR_BY_CONTEXT` | `sail-operator:<tag>[@<digest>]/<state>` (Kubernetes) or `servicemeshoperator3:<version>/<phase>` (OpenShift). The state (`Available`, `Unavailable`: no available replica, or a CSV phase) is never compared, only the build before it. `absent`: the member answered and runs none where the charts install it |
| `ISTIOD_IMAGE_BY_CONTEXT` | The istiod pods' `discovery` image and the digest that ran |
| `PROXY_IMAGE_BY_CONTEXT` | The `istio-proxy` image of the ingress and east-west gateway pods. The test pods' sidecars get the injector's current build (normally istiod's), which can be newer than a gateway not restarted since an upgrade |
| `NODE_PROVIDER_BY_CONTEXT` | The nodes' `spec.providerID` scheme (`kind`, `aws`, ...); `none`: nodes without one; `no-nodes`: no nodes listed; `unrecognized`: a providerID without `<scheme>://` |

In every key `unknown` means not read (a failed read, with a warning; a `--dry-run`; a file from
before the record), never none, and several values on one member are `+`-joined. A report whose
inputs disagree for a member shows `mixed:<a>;<b>` there and says so in its body
(`mixed:unknown,...` when only some inputs carry the key); a sweep whose record changed between
its start and end marks its reports `mixed:`.

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
| Pods stay `Pending` with `Insufficient cpu` or `Insufficient memory` (`kubectl describe pod`) | The chart defaults need the capacity in [What you need](#what-you-need). Lower istiod with `gitops_app_overrides` (`spoke-ossm-appset`) and Argo CD with `argocd_helm_values`, as in `terraform/platform/terraform.tfvars.example`. |
| The apply fails on `helm_release.argocd` after 900 s (`context deadline exceeded`) | Usually the same: the Argo CD pods cannot schedule on the hub (`kubectl -n argocd get pods`, then `describe` a Pending one). Lower the requests with `argocd_helm_values` and apply again. |
| The apply fails: `Argo CD on the hub cannot load state from these clusters` | The member's registered URL is not reachable from the hub's pods (a kubeconfig that points at `127.0.0.1`, a private endpoint). Set `cluster_api_url_overrides` to an address that the hub and every member reach, and apply again. `Unauthorized` or `Forbidden` in the quoted message is the member's token instead ([terraform/platform/README.md](terraform/platform/README.md#rotating-a-members-token)). |
| Gate says `istiod pod <pod> (<address>) has synced <n> remote cluster(s) < <need>` | That istiod replica cannot use the named member's remote secret: that member's API server URL is unreachable from its node, or its token is wrong. `istioctl remote-clusters` lists each one's state, and `kubectl -n istio-system logs -l app=istiod --prefix --tail=-1 \| grep <member>` says why, per replica: `remote cluster <member> failed to sync after 30s` (fix the URL with `cluster_api_url_overrides`) or `watch error in cluster <member>: Unauthorized` ([terraform/platform/README.md](terraform/platform/README.md#rotating-a-members-token)). |
| Gate says `cannot list the EndpointSlices of the istiod Service` (HTTP 403) | The gate's Role lacks the chart's EndpointSlice rule (it reads every istiod replica through them): sync the member's `mesh-wiring-verify` Application on the hub. |
| Gateway Applications stay `Progressing`, the gateway Service `<pending>` | No LoadBalancer provider, or a MetalLB pool with auto-assign off: add `metallb.io/address-pool` via `gitops_app_overrides`. The gate says `has no external address yet` for the east-west gateway. |
| `istioctl` errors on API versions | Use an `istioctl` that matches `ISTIO_VERSION`. |

## More

- [AGENTS.md](AGENTS.md): repo conventions for contributors and coding agents
- [docs/scale-test-campaign](docs/scale-test-campaign/README.md): end-to-end campaign runbook; [docs/campaigns](docs/campaigns/README.md): recorded results
- [docs/runbooks](docs/runbooks): a kind lab on one machine, operating a deployed lab, or a ROSA validation run

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

- `kubectl` (`oc` also works), `terraform` >= 1.14.8, `helm` (3 or 4), `jq`, `curl`, bash 4.3+ (macOS ships 3.2: `brew install bash`)
- GNU coreutils `timeout` for live controlplane runs (macOS has none: `brew install coreutils`, which adds `gtimeout`)
- `istioctl` matching `ISTIO_VERSION` in `config/versions.env` (for diagnostics)
- `ps` from procps (Linux; macOS's own works) for the sweeps, which stop a step's whole process tree
  with it (on Linux, `/proc` stands in for a missing or busybox `ps`; a sweep warns at its start
  only when neither works)
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
Unverified there: the wiring gate counts istiod's `closed` sync state (a remote secret changed and
the new connection synced) only when istiod's `istio_build` tag reads 1.30 or a later 1.x. If OSSM's
istiod reports another tag, the gate fails closed, never open: after a remote secret changes it reads
NotReady, advising an istiod restart.

Either way the apply starts the app-of-apps, and Argo CD rolls out the mesh in sync waves
([charts/README.md](charts/README.md)). It's done when every Application on the hub is
Synced/Healthy (`terraform output gitops_namespace` names the namespace: `argocd`, or
`openshift-gitops` on OpenShift):

```bash
kubectl --context <hub-ctx> get applications.argoproj.io -n argocd
```

## Verify

Every member runs `mesh-wiring-verify`, a gate that is Ready only when the member holds the remote
secret of every other member, every Ready istiod replica has synced each of them, no remote secret
or cluster of anything else is left (a removed member's stays behind), istiod signs with the shared
root, and the east-west gateway has an address. Otherwise its Argo Application goes Degraded, and
the gate's output says why, naming each member, secret and replica.

```bash
kubectl --context <mesh-a-ctx> exec -n mesh-wiring-verify deploy/mesh-wiring-verify -- sh /opt/check/readiness.sh
# Ready: secrets=2 istiod_managed=2 (local=1 remote=1) expected=2 members=<mesh-a-ctx>,<mesh-b-ctx> ca=shared synced=1 replicas=3 root=<fingerprint> eastwest=<address>
```

`root=` is the first 16 hex digits of the SHA-256 of the root certificate in `cacerts`: compare it
across members, it must read the same on every one. `replicas=` counts the Ready istiod replicas
the gate read; each connects to every member on its own, so the istiod figures and `synced=` are
the lowest any of them reports. `synced=` comes from istiod's metric, which changes only when
istiod (re)connects: a member token revoked later still reads synced, and shows as errors in
istiod's log. `members=` lists the members it checked by name: Terraform sets them, each member's
Argo CD cluster name, which is also its Istio cluster ID and the suffix of its remote secret
`istio-remote-secret-<member>`. A gate installed without them counts instead (`members=unchecked`),
and a count cannot tell a removed member's leftover secret from a member's.

End to end: deploy the echo app and call it through any member's ingress gateway. Answers should come
from every member. The manifest keeps placeholders for the repo, the revision, the platform and the
Argo CD namespace; fill them in on the way to the hub from what the hub already syncs, so the check
runs the same charts as the mesh.

```bash
NS=argocd PLATFORM=kubernetes   # OpenShift: NS=openshift-gitops PLATFORM=openshift
read -r REPO REV < <(kubectl --context <hub-ctx> -n "$NS" \
  get applications.argoproj.io hub-gitops-root \
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
ingress member (`charts/mesh-verify-gateway-api-appset.yaml` deploys it the same way, with one more
placeholder for the member that runs the workload).

## Run tests

Point the suites at the **mesh members only** (`--contexts <mesh-a-ctx>,<mesh-b-ctx>`, or
`SETUP_CONTEXTS`), never the hub, each member once: a list that names one twice, or a
`--remote-contexts` that names the source, stops before any cluster call. Each suite writes
TSV data plus a markdown summary under its `results/` directory; a sweep writes its TSVs and
reports into its own `results/sweep-<RUN_ID>/`. A sweep whose setup or probe failed for some
cells still writes its report, then ends with `N of M cells failed` (by reason) and exit code
4, as it does when the mesh changed under it (the Istio version or active revision changed
during the sweep, or the generation of a member's Istio CR or active IstioRevision went up: an
edit with the same version, an OSSM operator upgrade, a TLS profile change; or that end-of-sweep
check failed) and when its harness changed under it (below). `sweep-outcome.txt` in the sweep
dir keeps the outcome. While a sweep runs, its dir holds a lock (`.sweep.lock`, its PID):
another run into that dir, or a `--resume` of it, is refused until it ends (a PID another user
runs counts as alive; the lock of a run that died is taken over, by one run at a time). Each
suite README lists its exit codes. Every script has `--help`, and scripts that change a cluster
also accept `--dry-run`.

Every result records the harness that wrote it as `HARNESS_SHA`: `git describe`, plus
`-dirty.<8hex>` when a file under `tests/`, `config/`, `charts/` or `terraform/` differs from that
commit (an added untracked file there counts too, unless git ignores it: a run config in
`tests/<suite>/configs/` counts unless it is named `*.local.env`; an ignored file never counts, also
what your global `core.excludesFile`, or git's default `~/.config/git/ignore` when that key is
unset, ignores; your other git settings, `.git/info/attributes` included, never change the value; a
run's own results do not count). Next to it, `HARNESS_CONTENT_KEY` (12 hex characters) identifies
the content of those files alone; the `<8hex>` is its start. A sweep reads them again before its
steps (at most every `HARNESS_SHA_CHECK_SEC`, 60 s by default, `config/options.env`) and at its end,
and each probe's and setup step's own read counts too. A file edited, added or removed there during
the sweep (or a `git checkout`, `pull` or commit that changes one) is a problem in its outcome
(exit 4) when a read sees it, also when it was undone before the sweep's next read and only a step
read it (an edit made after a step's only read and undone before the next read is not seen); the
problem names both values and when the change was first seen, and the rows measured after it carry
the new value in their TSV (controlplane: a `# HARNESS_CHANGED_AT=` line in its one TSV;
churn-dataplane: each row's `harness_sha`), while the sweep's own records (the TSV preamble,
`sweep-outcome.txt`) keep the start's. A commit or tag that left those files as they were changes
only the name `git describe` gives: a note, and every step keeps recording the start's
`HARNESS_SHA`. Each report also records the harness it ran on as `REPORT_HARNESS_SHA`; the results
dir it reads never counts as a change.

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
Before its first change, every suite reads the version each member runs: the IstioRevision its
`istios.sailoperator.io default` CR names as active (`.status.activeRevisionName`), and that
revision's `.spec.version`, which must be an exact version (an alias such as `v1.30-latest` is
not). A CR or IstioRevision that is not reconciled yet (generation, `Reconciled` condition), has
no active revision, or is migrating between revisions reads as unknown. A CR whose only issue is
readiness (its state is not Healthy because istiod or IstioCNI is not ready) still gives its
version: the suite reads it again every `ISTIO_VERSION_READY_POLL_SEC` (5) for up to
`ISTIO_VERSION_READY_WAIT_SEC` (60) seconds, then records the version with a warning on stderr. An
istiod rollout in progress (its Deployment has fewer updated pods than pods, a generation not
observed yet, or pods still terminating, also while the CR already reads Healthy) is waited for
the same way, and reads as unknown if it outlasts the wait: old and new istiod pods both serve. A
pod stuck in Terminating (on a lost node, for example) reads this way until it is force-deleted;
the message then says "istiod pods still terminating" and shows how to list them. A rollout that
ends on the last read before the deadline is read once more, one poll later. A member stays in the
wait until the deadline or until it is ready, so a CR that is briefly not settled meanwhile does
not stop the run early; its answer at the deadline counts. The suite records the result as
`ISTIO_VERSION`, next to the pin (`ISTIO_VERSION_PIN`), `ISTIO_VERSION_SOURCE` (`live`; `pin` in a
`--dry-run`, which reads nothing), `ISTIO_VERSION_BY_CONTEXT`, each member's active revision in
`ISTIO_ACTIVE_REVISIONS` (`<ctx>=<revision>,...`, `<ctx>=` for a member whose Istio CR could not
be read; `unchecked` in a `--dry-run`, `unknown` after a version check that stopped unexpectedly
and, in a report, for a TSV written before the key existed; a controlplane `--resume` refuses a
member whose active revision changed since the sweep started), `ISTIO_GENERATIONS` (`<ctx>=<Istio
CR generation>/<active IstioRevision generation>`: a sweep compares them at its end, and a
controlplane `--resume` against the first run's, so a spec edited and changed back during the
sweep is a problem too), `ISTIO_PROXY_VERSIONS` (`<ctx>=<version>:<count>+...`: the proxies
connected to each member's istiod by Istio version, from istiod's `pilot_xds` gauge, read through
the API server's pod proxy, `ISTIO_PROXY_READ_PARALLEL` (20) members at once and one pod of a
member at a time, a pod being deleted left out with a note (the counts are approximate: a proxy can
move to another pod during the read); `none` or `unknown` per member; proxies on another version
than their istiod, such as sidecars not restarted after an upgrade, are a warning and a note of the
sweep outcome, never a stop), and the members still not ready after the wait in
`ISTIO_NOTREADY_AT_START` (the wait in `ISTIO_READY_WAITED_SEC`), which a sweep's outcome repeats as
a note. `ISTIO_NOTREADY_AT_START` reads `none` (every member was ready), `<ctx>=<state>,...` (the
Istio CR's state, such as `IstiodNotReady`), `<ctx>=rolling` (an istiod rollout still in progress),
`<ctx>=unreadable` (a rollout at the first read, then every re-read failed), `unchecked` (a
`--dry-run`, or a version check that stopped unexpectedly) or, in a report, `unknown` (a TSV written
before the key existed). A controlplane `--resume` keeps the first run's value in the TSV, and
records its own, with its UTC start time, in a note of the sweep outcome
(`ISTIO_NOTREADY_AT_RESUME=...`) and in the sweep dir's append-only `resumes.txt`, one line per
resume. With `ISTIO_VERSION_CHECK=fail` (the default) a member on another version than the pin,
members on different versions, or a member that cannot be read stop every suite but gateway-api (a
read-only check that only records it) before it changes anything; `ISTIO_VERSION_CHECK=warn` goes on
and records what the mesh runs (`mixed:<a>/<b>` or `unknown` when they differ or cannot be read). A
version check that stops unexpectedly counts as unknown: `fail` stops the run, `warn` records
`unknown`, and at the end of a sweep it is a problem (exit 4). A sweep reads it again at the end and
exits 4 when the version, the active revision or the generation of the Istio CR or its active
IstioRevision changed (also when the Istio CR is not settled at the end, or its istiod Deployment
cannot be read, but its active revision reads another version); istiod or IstioCNI not ready at the
end, on the same version, is a warning. From its start the sweep keeps a not-finished record in
`sweep-outcome.txt` in its results dir (`EXIT=unfinished`), and every report of that dir says the
sweep has not finished (it died, or still runs; json `sweep_outcome.unfinished`); at its end the
sweep writes its outcome there, and every report re-generated from that dir repeats its errors,
warnings and notes (json `"unfinished": false`). A sweep that ends between the two says how in that
record: one that stops on an error (a check it makes, or an unexpected abort whose `FATAL:` line
names the script, line and command) records a stop (`STOPPED=1`, the reason in `STOP_REASON`,
`TOTAL=unknown`, `CUT_SHORT=1`; every report shows the stop and its reason; exit 1, whatever code
the failed command had); one interrupted (Ctrl-C, SIGTERM, or SIGHUP when its terminal closes) stays
not finished and records when and by which signal (`ENDED_AT`, `ENDED_SIGNAL`; reports say
"interrupted at ...", json `interrupted_at`, `interrupted_by`; exit 130, 143 or 129); only one
killed outright (SIGKILL, out of memory, a lost host) leaves the record as it was. A signal sent to
the sweep's process alone (`kill <pid>`, `kill -INT <pid>`, a service manager) reaches the step that
runs (a setup, a probe, a cleanup) and every process under it (its kubectl calls, its per-member
workers) at once; the sweep ends once they have, or sends SIGKILL to what still runs
`SWEEP_STOP_GRACE_SEC` (30) seconds later (their own cleanup does not run; the warning names the
suite's cleanup command), and only then releases its lock. For a sweep in a terminal's foreground (a
terminal, a tmux or screen pane), a `kill -INT` or `kill -HUP` sent from elsewhere skips the
processes in that foreground, which a Ctrl-C reaches itself: they get SIGKILL after the grace, with
no cleanup, so stop such a sweep from elsewhere with SIGTERM (`kill <pid>`). The sweep's own
commands between steps finish first, each bounded: a settle wait, the Istio version and proxy reads
(tuning: the generation reads around each apply and revert), controlplane's leftover counts, and the
end-of-sweep recheck. Stopping the step's tree needs a `ps` that lists every process with its start
time (procps, or macOS's), or Linux's `/proc` in its place: without either, the sweep warns at its
start, and a stop reaches only the step's own process (a `--dry-run` warns too; when the sweep's
stdin is a terminal, a `kill -INT` or `kill -HUP` from elsewhere then reaches nothing: it is taken
for a Ctrl-C, which reached the step itself). A results dir without `sweep-outcome.txt` is from a
sweep that stopped before its start (nothing ran) or from an older harness. A kubectl error quoted
in a record or a report names the API server as `<api-host>` or `<ip>`, never its address.
`ISTIO_VERSION_CHECK`, `ISTIO_VERSION_READY_*`, `ISTIO_PROXY_READ_PARALLEL`, `HARNESS_SHA_CHECK_SEC`
and `SWEEP_STOP_GRACE_SEC` are set in the environment, never in a `--config` file.

Every TSV, run summary and report also records what each member ran on: Kubernetes or OpenShift,
the mesh operator build, the istiod and proxy images, istiod's env and the nodes' provider
([tests/lib/platform.sh](tests/lib/platform.sh)). `TEST_PLATFORM` (`auto`, the default, asks each
member; `kubernetes` or `openshift` is used as given) picks each suite chart's OpenShift overlay;
the record still asks each member what it serves, outside every measurement window, and warns when
that differs from the override. A report warns when its inputs differ on any of these, so compare
results within one platform and mesh build. On kind every node reports the whole host, so the
controlplane report flags its capacity figures and its SLA verdict leaves the node figures out
(`CAUTION`); so does a member whose node provider could not be read. k3d (`k3s://`) and minikube
clusters that share one host are not detected: their node figures are the host's too, so read them
the same way. The cross-cluster path on kind runs through cloud-provider-kind's userspace Envoy on
the shared host, so the dataplane and churn-dataplane reports flag their remote latency.

| Record key | Values |
| --- | --- |
| `PLATFORM` | `kubernetes` or `openshift` over the members; `mixed` when they run both, else `unknown` when any member is |
| `TEST_PLATFORM` | The override as set: `auto`, `kubernetes` or `openshift` |
| `PLATFORM_BY_CONTEXT` | What each member serves, asked even with an override |
| `MESH_OPERATOR_BY_CONTEXT` | `sail-operator:<tag>@<digest>/<state>` (Kubernetes) or `servicemeshoperator3:<version>/<phase>` (OpenShift). The state (`Available`, `Unavailable`: no available replica, or a CSV phase) is never compared, only the build before it (`@unknown` as below). `absent`: the member answered and runs none where the charts install it |
| `ISTIOD_IMAGE_BY_CONTEXT` | The istiod pods' `discovery` image and the digest that ran; `<image>@unknown`: none of them has started (below); `none`: no istiod pod on that member |
| `PROXY_IMAGE_BY_CONTEXT` | The `istio-proxy` image of the ingress and east-west gateway pods; `@unknown` and `none` as for istiod. The test pods' sidecars get the injector's current build (normally istiod's), which can be newer than a gateway not restarted since an upgrade |
| `ISTIOD_ENV_BY_CONTEXT` | A 12-hex digest of istiod's `discovery` container env (each `name=value`, or `name=` and its `valueFrom`, sorted) without `CLUSTER_ID`, the one variable that differs by member. It changes when a tuning profile's `spec.values.pilot.env` or a hand edit changes istiod's settings (tuning 004 leaves it out of its pass comparison: a profile changes it on purpose). `none` and `unknown` as for the images |
| `NODE_PROVIDER_BY_CONTEXT` | The nodes' `spec.providerID` scheme (`kind`, `aws`, ...); `none`: nodes without one; `no-nodes`: no nodes listed; `unrecognized`: a providerID without `<scheme>://`. Nodes without one beside a provider's (`aws+none`: a control-plane node, a virtual node) compare as that provider's |
| `TUNING_OBJECTS_BY_CONTEXT` | The objects a tuning profile created, labelled `istio-scale-tests/tuning-profile` (DestinationRules, Sidecars, EnvoyFilters and Telemetries in any namespace), and the marker ConfigMap `istio-system/tuning-profile-<profile>` that `tests/tuning/001-apply-profile.sh` puts on each member it applies a profile to (so a profile that only sets istiod's env shows too), as `<profile>:<Kind>/<namespace>/<name>`; `none` outside a tuning run. A member that has some was left with a profile applied (a tuning run killed before its revert; `tests/tuning/005-cleanup.sh` restores the Istio CR from each marker and deletes the objects): every sweep warns as it starts and every report in its body, since profile 04's root DestinationRule changes every proxy's clusters, and a tuning run refuses to start. Tuning 004 leaves the key out of its pass comparison and checks instead that each pass held every object of its own profile on every member and no other profile's (its "Tuning objects" row) |

In every key `unknown` means not read (a failed read, with a warning; a `--dry-run`; a file from
before the record), never none, and several values on one member are `+`-joined. An image whose
pods have not started (Pending, still pulling, evicted; an operator scaled to 0) is not another
build: the record takes the pods that report a digest, and when none does it records the spec image
as `<name>:<tag>@unknown` (its pinned digest when the spec image has one), which every comparison
takes as not read (a warning), never as a different build. A report whose
inputs disagree for a member shows `mixed:<a>;<b>` there and says so in its body
(`mixed:unknown,...` when only some inputs carry the key, with a warning that counts the inputs
from before the key). A sweep reads the record once at its start and hands it to its steps in
`platform-record.txt` in the sweep dir (each step still reads a member it recorded `unknown`; a
controlplane `--resume` writes the file anew from its own read, while the TSV's preamble keeps
the record of the sweep's start). It reads the record again at its end, with each member's
Kubernetes version and its first member's tuning levers, Sidecar egress hosts and istiod limits
when its TSVs record them (`TUNING_BASELINE`: four levers, each `on`, `off` or `unknown`, as
"Tuning levers" in [tests/controlplane/README.md](tests/controlplane/README.md) describes), and
every other member's istiod limits against the recorded ones (the controlplane report divides
every member's window-peak CPU and RSS % by those), and each member's istiod replica count against
the recorded one (controlplane: its Deployment's replicas; propagation, churn and churn-dataplane:
its Running istiod pods, churn-dataplane's on its source member only): a value that changed goes to
`platform-drift.txt` in the sweep dir, and every report of the sweep says so in its body, naming
the sweep dir and the value at the start and at the end (the record's keys read `mixed:`, as does
`KUBE_VERSIONS` in churn's report, which merges it); so does a value the read could not compare
(not read at either end, or a digest `@unknown`), which the reports call not known. Members that
changed the same way share one warning, which names five of them and counts the rest. A controlplane
`--resume` stops on a definite difference from what the sweep's TSV records: a member's platform,
mesh operator build (not its state), istiod or gateway proxy build, istiod env digest, tuning
profile objects, node provider or Kubernetes version, or the source member's (the TSV's first)
tuning baseline, Sidecar egress hosts or istiod CPU and memory limits; whatever it cannot read only
warns. It also only warns when node allocatable, istiod's requests, a member's istiod replica count
or the network topology differ (an autoscaler or an HPA moves some of them);
[tests/controlplane/README.md](tests/controlplane/README.md) lists every check. Each record read is
bounded by `PLATFORM_READ_TIMEOUT` (`config/options.env`, 20s; raise it for members with many
nodes), and `PLATFORM_READ_PARALLEL` members are read at once for the record, the tuning profile
objects, the Kubernetes versions, istiod's replica counts, and istiod's limits and replica counts
read again at a run's end (20; lower it when the machine running the suite runs short of memory or
processes on a large mesh).

### Run config (`--config FILE`)

Every numbered script of propagation, controlplane, dataplane, churn, churn-dataplane and
gateway-api takes `--config FILE`: one file of `KEY=value` lines (`SETUP_CONTEXTS` and the suite's
keys in `config/options.env`, the ones its README lists; not every key there, see "Environment
only" below) that describes a whole run, so setup, sweep, report and cleanup read
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
  `--force-large-matrix` acknowledgment stays per run), `*_EXTEND_PLAN` (so does a controlplane
  `--resume`'s `--extend-plan`), `ISTIO_VERSION_CHECK`, `ISTIO_VERSION_READY_*` and
  `ISTIO_PROXY_READ_PARALLEL` (the version check above), `HARNESS_SHA_CHECK_SEC` and
  `SWEEP_STOP_GRACE_SEC` (every sweep, above) and the version pins in `config/versions.env`.
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
  `Run config` row.
- **One run per report:** a report reads every TSV under its results dir. When that dir holds
  more than one run (each `sweep-*` directory is one run; outside one, each `RUN_ID`), it stops,
  lists the runs and prints the `--results-dir <dir>/sweep-<RUN_ID>` that reports each alone.
  `--allow-multi-run` pools them on purpose, and every format then says it pools N runs and
  lists their `HARNESS_SHA` and `ISTIO_VERSION` values. A key that differs across the inputs reads
  `mixed:<a>,<b>`, never one file's value. `HARNESS_SHA` values that differ while every input
  records one `HARNESS_CONTENT_KEY` differ only in git describe: every report then gives a note
  ("differ only in git describe: every ... records HARNESS_CONTENT_KEY=..., the same harness files")
  instead of a warning, which an input without the key keeps. A report repeats only its results
  dir's own `sweep-outcome.txt`: the record of a `sweep-*` dir below it (a pooled run, or one
  sweep reported from its parent dir) that has not finished, was interrupted, stopped early or
  records a `PROBLEM` is named in a note and a warning on stderr (json `pooled_sweep_outcomes`);
  controlplane names one that has not finished, was interrupted or stopped early in a data
  warning (on stderr too), and counts and names each record's `PROBLEM`s in its verdict instead.
  Report that sweep dir alone to see its outcome.

## Grow the mesh

`mesh_member_count` in `terraform/platform` sets how many spokes join, in sorted order (0 = all).
Raise it, or add a spoke, and re-apply; the wiring gate's member list follows automatically. Change
membership between test runs, not during one: every istiod connects to a new member, and on
`kubernetes` adding or removing a spoke moves the spokes that sort after it to another Argo CD
controller shard, which rebuilds their cache there (the shard pins in [terraform/platform/README.md](terraform/platform/README.md#run)).
Until the new member is wired, every gate reads NotReady and names it (no remote secret yet, then
not synced); wait until all of them read Ready again.

When a member leaves, External Secrets leaves its remote secret on every other member, and istiod
keeps that cluster until the secret is deleted. Each remaining member's gate reads NotReady and
prints the delete command; run it on each of them:

```bash
kubectl --context <mesh-ctx> -n istio-system delete secret istio-remote-secret-<removed-member>
```

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Gate says `istiod is not using the shared mesh root` | istiod started before `cacerts`. Delete the member's `<member>-ossm` Application on the hub (it's recreated and waits for `cacerts`), then restart that member's gateways. |
| No `cacerts` or remote secrets on members | Check the ESO pods on the hub (`kubectl get pods -n external-secrets-operator`); on a small hub lower the Argo CD requests with `argocd_helm_values` (`argocd_config_values` on OpenShift). |
| Pods stay `Pending` with `Insufficient cpu` or `Insufficient memory` (`kubectl describe pod`) | The chart defaults need the capacity in [What you need](#what-you-need). Lower istiod with `gitops_app_overrides` (`spoke-ossm-appset`) and Argo CD with `argocd_helm_values`, as in `terraform/platform/terraform.tfvars.example`. |
| The apply fails on `helm_release.argocd` after 900 s (`context deadline exceeded`) | Usually the same: the Argo CD pods cannot schedule on the hub (`kubectl -n argocd get pods`, then `describe` a Pending one). Lower the requests with `argocd_helm_values` and apply again. |
| The apply fails: `Argo CD on the hub cannot load state from these clusters` | The member's registered URL is not reachable from the hub's pods (a kubeconfig that points at `127.0.0.1`, a private endpoint). Set `cluster_api_url_overrides` to an address that the hub and every member reach, and apply again. `Unauthorized` or `Forbidden` in the quoted message is the member's token instead ([terraform/platform/README.md](terraform/platform/README.md#rotating-a-members-token)). |
| Gate says `no remote secret here for mesh member(s) <member>` | The hub has not pushed that member's remote secret to this one. On the hub, `kubectl -n external-secrets-operator describe pushsecret push-remote-secret-<member>` shows the stores it reached and its last error (`Unauthorized` for this member's store: [rotate this member's token](terraform/platform/README.md#rotating-a-members-token)). Right after a member joins, wait: the push takes up to about 10 minutes. |
| Gate says `remote secret(s) of no mesh member` | A member left, and External Secrets leaves what it pushed: run the `kubectl ... delete secret` the gate prints, on this member ([Grow the mesh](#grow-the-mesh)). Check first that the name is not a member being added: its secret can arrive a moment before this gate restarts with the new list. |
| Gate says `has not synced mesh member(s) <member> (not managed)` | The remote secret is here but istiod built no cluster from it: `kubectl -n istio-system logs <pod> \| grep <member>` says why (a kubeconfig it cannot use, a data key other than the member's name, or a cluster ID another secret already holds). |
| Gate says `manages remote cluster(s) of no mesh member` or `manages this member's own name as a remote cluster` | A remote secret holds a cluster that is no member: the gate prints a command that lists each remote secret's clusters; delete the secret (or the key) of a cluster that left. Its own name: this member's Istio cluster ID is not its Argo CD name (`spec.values.global.multiCluster.clusterName` in its Istio CR). |
| Gate says `expectedMembers is <n> but expectedClusters names <m>`, or `this member (<name>) is not in expectedClusters` | The gate's values disagree with the mesh: Terraform sets both from the mesh members, so apply `terraform/platform` again. A member that just joined reads the second until that apply has updated the gate's ApplicationSet. |
| Gate says `istiod pod <pod> (<address>) has not synced mesh member(s) <member> (<state>)` (counting: `has synced <n> remote cluster(s) < <need>`) | That istiod replica cannot use the named member's remote secret: that member's API server URL is unreachable from its node, or its token is wrong. `istioctl remote-clusters` lists each one's state, and `kubectl -n istio-system logs -l app=istiod --prefix --tail=-1 \| grep <member>` says why, per replica: `remote cluster <member> failed to sync after 30s` (fix the URL with `cluster_api_url_overrides`) or `watch error in cluster <member>: Unauthorized` ([terraform/platform/README.md](terraform/platform/README.md#rotating-a-members-token)). |
| Gate says `cannot list the EndpointSlices of the istiod Service` (HTTP 403) | The gate's Role lacks the chart's EndpointSlice rule (it reads every istiod replica through them): sync the member's `mesh-wiring-verify` Application on the hub. |
| Gateway Applications stay `Progressing`, the gateway Service `<pending>` | No LoadBalancer provider, or a MetalLB pool with auto-assign off: add `metallb.io/address-pool` via `gitops_app_overrides`. The gate says `has no external address yet` for the east-west gateway. |
| `istioctl` errors on API versions | Use an `istioctl` that matches `ISTIO_VERSION`. |

## Moving or forking the repo

Nothing in the code names the repo's home, so a move is settings, not code:

1. Point the platform at the new repo: set `gitops_app_repo_url` and `gitops_app_repo_revision` in
   your tfvars (plus `gitops_app_repo_password` or `gitops_app_repo_ssh_private_key` for a private
   repo) and re-apply `terraform/platform`. The on-demand checks read both from the hub when you
   apply them ([Verify](#verify)), so they follow.
2. Recreate CI: enable Actions, then protect `main` with a rule that requires a pull request and the
   checks `validate (ubuntu-latest)` and `validate (macos-latest)`
   ([portability.yml](.github/workflows/portability.yml); keep those job names). CI also runs on
   every push to `main`, weekly, and on demand (Actions, "Run workflow"), so drift shows up
   without a PR.
3. Name the owners in [.github/CODEOWNERS](.github/CODEOWNERS) and turn on "Require review from
   Code Owners" in that rule.
4. Tag the hand-over commit with an annotated tag (`git tag -a v1.0.0 -m "<note>"`, then
   `git push origin v1.0.0`). Results record `git describe` as `HARNESS_SHA`, so runs from that
   commit name the tag.

## More

- [AGENTS.md](AGENTS.md): repo conventions for contributors and coding agents
- [docs/scale-test-campaign](docs/scale-test-campaign/README.md): end-to-end campaign runbook; [docs/campaigns](docs/campaigns/README.md): recorded results
  (paste from a copy that `tests/lib/redact-results.sh --out <dir> <results-dir>` redacted)
- [docs/runbooks](docs/runbooks): a kind lab on one machine, operating a deployed lab, or a ROSA validation run

## License

[Apache License 2.0](LICENSE).

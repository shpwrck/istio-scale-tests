# istio-scale-tests

Deploy a multi-primary, multi-network Istio mesh on OpenShift (Red Hat OpenShift Service Mesh 3,
Sail operator) across several clusters, then measure how it scales. One cluster is the ACM + Argo CD
hub; every other cluster runs its own istiod and joins the mesh through east-west gateways, with a
shared root CA.

```mermaid
flowchart TB
    hub["<b>hub</b><br/><i>never a mesh member</i><br/>ACM · Argo CD<br/>cert-manager · ESO"]

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

    hub -->|"charts: Argo CD ApplicationSets<br/>(ACM Placement)"| A
    hub -.->|"ESO: cacerts +<br/>Istio remote secrets"| A
    hub --> B
    hub -.-> B
    ewA <--> ew
    ewB <--> ew
```

## What you need

- `oc` and `kubectl`, `terraform` >= 1.14.8, `helm` (3 or 4), `jq`, `curl`, bash 4.3+ (macOS ships 3.2: `brew install bash`)
- `istioctl` matching `ISTIO_VERSION` in `config/versions.env` (for diagnostics)
- `python3` with PyYAML (tuning suite only)
- Mesh members must be able to provision `type: LoadBalancer` Services (cloud provider or MetalLB).

## Deploy

**Existing clusters:** use `terraform/platform` in kubeconfig mode. Name the hub context and the
member contexts, and set the brownfield switches for anything already installed. See
[terraform/platform/README.md](terraform/platform/README.md).

**New ROSA clusters:** create them with [terraform/rosa-hcp](terraform/rosa-hcp/README.md) (it covers
the one-time AWS and Red Hat account setup and a preflight check), then apply `terraform/platform`
with `cluster_provider = "rosa"`.

Either way the platform apply installs ACM and OpenShift GitOps (unless already present) and starts
the app-of-apps. Argo CD then rolls out the mesh in sync waves ([charts/README.md](charts/README.md)).
It's done when every Application on the hub is Synced/Healthy:

```bash
oc --context <acm-hub-ctx> get applications.argoproj.io -n openshift-gitops
```

## Verify

Every member runs `mesh-wiring-verify`, a gate that is Ready only when the member holds a remote
secret for every member, istiod has ingested them all, and istiod signs with the shared root.
Otherwise its Argo Application goes Degraded.

```bash
oc --context <mesh-a-ctx> exec -n mesh-wiring-verify deploy/mesh-wiring-verify -- bash /opt/check/readiness.sh
# Ready: secrets=2 istiod_managed=2 (local=1 remote=1) expected=2 ca=shared
```

End to end: deploy the echo app and call it through any member's ingress gateway. Answers should come
from every member. The manifest keeps `<repo-url>` and `<revision>` placeholders; fill them in on the
way to the hub from the repo and revision the hub already syncs, so the check runs the same charts
as the mesh.

```bash
read -r REPO REV < <(oc --context <acm-hub-ctx> -n openshift-gitops get application hub-gitops-root \
  -o jsonpath='{.spec.source.repoURL} {.spec.source.targetRevision}')
sed -e "s|<repo-url>|${REPO:?}|g" -e "s|<revision>|${REV:?}|g" charts/mesh-verify-appset.yaml \
  | oc --context <acm-hub-ctx> apply -f -
INGRESS=$(oc --context <mesh-a-ctx> get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}')
for i in $(seq 10); do curl -s -H 'Host: mesh-verify.local' "http://$INGRESS/"; done
oc --context <acm-hub-ctx> delete -f charts/mesh-verify-appset.yaml
```

Gateway API: [`tests/gateway-api`](tests/gateway-api/README.md) checks whether an HTTPRoute reaches a
workload that runs in another member, with or without a Service, or the Service's namespace, in the
ingress member (`charts/mesh-verify-gateway-api-appset.yaml` deploys it the same way, with one more
placeholder for the member that runs the workload).

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
| No `cacerts` or remote secrets on members | Check the ESO pods on the hub (`oc get pods -n external-secrets`); on a small hub lower the Argo CD requests with `argocd_config_values`. |
| Gateway Service stays `<pending>` | No LoadBalancer provider, or a MetalLB pool with auto-assign off: add `metallb.io/address-pool` via `gitops_app_overrides`. |
| `istioctl` errors on API versions | Use an `istioctl` that matches `ISTIO_VERSION`. |

## Moving or forking the repo

Nothing in the code names the repo's home, so a move is settings, not code:

1. Point the platform at the new repo: set `gitops_app_repo_url` and `gitops_app_repo_revision` in
   your tfvars (plus `gitops_app_repo_password` or `gitops_app_repo_ssh_private_key` for a private
   repo) and re-apply `terraform/platform`. The on-demand checks read both from the hub when you
   apply them ([Verify](#verify)), so they follow.
2. Recreate CI: enable Actions, then protect `main` with a rule that requires a pull request and the
   checks `validate (ubuntu-latest)` and `validate (macos-latest)`
   ([portability.yml](.github/workflows/portability.yml); keep those job names).
3. Name the owners in [.github/CODEOWNERS](.github/CODEOWNERS) and turn on "Require review from
   Code Owners" in that rule.
4. Tag the hand-over commit with an annotated tag (`git tag -a v1.0.0 -m "<note>"`, then
   `git push origin v1.0.0`). Results record `git describe` as `HARNESS_SHA`, so runs from that
   commit name the tag.

## More

- [AGENTS.md](AGENTS.md): repo conventions for contributors and coding agents
- [docs/scale-test-campaign](docs/scale-test-campaign/README.md): end-to-end campaign runbook; [docs/campaigns](docs/campaigns/README.md): recorded results
- [docs/runbooks](docs/runbooks): operating a deployed lab or ROSA validation run

## License

[Apache License 2.0](LICENSE).

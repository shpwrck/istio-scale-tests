# istio-scale-tests

Deploy a multi-primary, multi-network Istio mesh on OpenShift (Red Hat OpenShift Service Mesh 3,
Sail operator) across several clusters, then measure how it scales. One cluster is the ACM + Argo CD
hub; every other cluster runs its own istiod and joins the mesh through east-west gateways, with a
shared root CA.

```
            ┌──────────────────────────┐
            │ hub (never a mesh member)│
            │ ACM · Argo CD            │
            │ cert-manager · ESO       │
            └────────────┬─────────────┘
       Argo CD ApplicationSets (ACM Placement) push charts;
       ESO pushes cacerts + Istio remote secrets
         ┌───────────────┴───────────────┐
 ┌───────▼────────┐              ┌───────▼────────┐
 │ mesh member A  │              │ mesh member B  │
 │ istiod         │◄──:15443───►│ istiod         │
 │ ingress gw     │  east-west   │ ingress gw     │
 └────────────────┘              └────────────────┘
```

## What you need

- `oc` and `kubectl`, `terraform` >= 1.14.8, `helm` (3 or 4), `jq`, `curl`, bash 4+
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
from every member. If you're not on `main`, set both `spec.source.targetRevision` and the
`repo.revision` parameter in the manifest to your branch (and both repo URLs if you use a fork).

```bash
oc --context <acm-hub-ctx> apply -f charts/mesh-verify-appset.yaml
INGRESS=$(oc --context <mesh-a-ctx> get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}')
for i in $(seq 10); do curl -s -H 'Host: mesh-verify.local' "http://$INGRESS/"; done
oc --context <acm-hub-ctx> delete -f charts/mesh-verify-appset.yaml
```

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

```bash
tests/propagation/006-run-sweep.sh --contexts <mesh-a-ctx>,<mesh-b-ctx> --mesh-sizes 1,2 --iterations 5 --dry-run
```

Settings and image pins live in `config/versions.env` and `config/options.env`. The deployed Istio
version is `istioVersion` in `charts/spoke-ossm/values.yaml`; keep `ISTIO_VERSION` equal to it.

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

## More

- [AGENTS.md](AGENTS.md): repo conventions for contributors and coding agents
- [docs/scale-test-campaign](docs/scale-test-campaign/README.md): end-to-end campaign runbook; [docs/campaigns](docs/campaigns/README.md): recorded results
- [docs/runbooks](docs/runbooks): operating a deployed lab or ROSA validation run

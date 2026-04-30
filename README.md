# istio-scale-tests

This repository holds automation and manifests used to **scale-test Istio in a multi-cluster setup** on OpenShift. The target pattern is **multi-primary, multi-network** mesh: several independent clusters share one logical mesh (common mesh id and trust), with **Istio** delivered via the **Sail operator** (`Istio` / `IstioCNI` CRs). Procedures follow **[Red Hat OSSM 3.3 — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies)**; pinned OpenShift / Kubernetes / Istio versions live in `**config/versions.env`**.

Use it to reproduce installs, certificate wiring, remote secrets, east–west gateways, and sample workloads—then measure behavior under load or changing cluster counts.

**Maintainer note:** When you add or rename scripts under `**setup-scripts/`**, change default contexts (`rosa-*`), Istio versions, or manifest paths, update this README in the same change so operators stay aligned.

---

## What you need

- `**oc`** / `**kubectl`** logged into every test cluster (example contexts used in scripts: `rosa-001`, `rosa-002`, `rosa-003`—**edit the scripts** if your kubeconfig uses different names).
- **Platform / mesh pins** (defaults): OpenShift **4.18.38**, Kubernetes **v1.31.14**, Istio `**spec.version`** **v1.28.5** — see `**config/versions.env`** (override with env vars when testing other trains).
- `**istioctl`** matching `**ISTIO_VERSION`** from `**config/versions.env`**. Scripts often expect `istioctl` on `PATH`, or place a binary at `**.bin/istioctl`** and prepend `PATH="$PWD/.bin:$PATH"`.
- `**openssl`**, `**jq`**, `**bash` 4+**, `**curl`** (used by various scripts).
- `**envsubst`** from **gettext** (template rendering for `**02`** and `**06`**).
- `**git`**, Helm 3 — `**setup-scripts/03`** installs `**istio/gateway**` from `**ISTIO_HELM_REPO_URL**` at `**ISTIO_GATEWAY_CHART_VERSION**`.
- **OpenShift Service Mesh / Sail operator** installed on each cluster so `istio.sailoperator.io` and `istiocni.sailoperator.io` CRDs exist before applying manifests.

---

## Repository layout


| Path                                | Role                                                                                                                                                                                                                                                     |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `**setup-scripts/`**                | Numbered shell helpers for mesh install and wiring (run in order; see below).                                                                                                                                                                            |
| `**manifests/ossm-multi-cluster/`** | `**templates/*.yaml.tpl`** — rendered by `**setup-scripts/02`** / `**06`** (`envsubst` + `**config/versions.env**`); `**east-west/common/**`, `**ingress-verify/**`, optional `**samples/**`. Ingress gateways use Helm `**istio/gateway**` in `**03**`. |
| `**cacerts/**`                      | Generated plug-in CA material and per-cluster intermediates (created by `**setup-scripts/00-ossm-mc-cacerts.sh**`).                                                                                                                                      |
| `**.gitignore**`                    | Ignores `**/cacerts/**` and `**/manifests/**` so secrets and environment-specific YAML are not committed by default. Files already tracked by Git stay tracked; adjust `.gitignore` if you want to version canonical templates only.                     |
| `**terraform/rosa-hcp/**`           | Optional Terraform stack for **ROSA HCP** (upstream `terraform-redhat/rosa-hcp/rhcs`): one VPC and STS stack per cluster (`for_each`) — see `**terraform/rosa-hcp/README.md`**.                                                                          |


---

## How to run the stack (operational order)

Setup scripts in `**setup-scripts/`** are prefixed `**00`–`08`** in the sequence they are normally executed.


| Step   | Script                                                          | Purpose                                                                                                                                                                                                                                                                                                         |
| ------ | --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **00** | `setup-scripts/00-ossm-mc-cacerts.sh`                           | Generate a shared root + per-cluster intermediate CAs; `**verify`**; optional `**apply`** to create the `**cacerts**` Secret in `istio-system` and label `**topology.istio.io/network**` on each cluster.                                                                                                       |
| **01** | `setup-scripts/01-ossm-mc-kubeconfig-embed-api-ca.sh`           | **Optional.** Embeds API server TLS chains into your kubeconfig so `**istioctl create-remote-secret`** produces Secrets **istiod** can use (e.g. ROSA APIs with Let’s Encrypt). Run before **04** if remote watches fail with TLS errors.                                                                       |
| **02** | `setup-scripts/02-ossm-mc-apply-istio.sh`                       | Renders `**templates/istio-cni.yaml.tpl`** and `**templates/istio.cluster.yaml.tpl`** (`**--contexts`** / `**SETUP_CONTEXTS`**). `**Istio/default**` sets mesh Envoy **access logging** via `**meshConfig`** (`**ACCESS_LOG_*`** in `**config/versions.env`**). Waits for Ready (skipped with `**--dry-run`**). |
| **03** | `setup-scripts/03-ossm-mc-apply-ingress-gateway.sh`             | Per cluster: `**istio/gateway`** → `**istio-system/istio-ingressgateway`** LoadBalancer (**HTTP 80/HTTPS 443**). SCC-safe Helm flags; optional `**AWS_LOAD_BALANCER_*_SECURITY_GROUPS`** (see `**config/versions.env`**) for ROSA/NLB SGs. `**--contexts`** / `**SETUP_CONTEXTS**`.                             |
| **04** | `setup-scripts/04-ossm-mc-remote-secrets.sh`                    | For each ordered pair of clusters, runs `**istioctl create-remote-secret`** and applies the result to the other clusters’ `**istio-system`** so **istiod** can discover remote services.                                                                                                                        |
| **05** | `setup-scripts/05-ossm-mc-remote-secrets-insecure-apiserver.sh` | **Optional fallback.** Patches remote-secret kubeconfigs to `**insecure-skip-tls-verify: true`** for remote apiservers when CA embedding alone is not enough (lab only; prefer proper CA bundles for production). Restart `**istiod`** afterward if endpoints do not refresh.                                   |
| **06** | `setup-scripts/06-ossm-mc-apply-east-west.sh`                   | Renders `**templates/east-west-gateway.yaml.tpl`** per cluster; applies `**east-west/common/expose-services.yaml`** (`cross-network-gateway`, port **15443**).                                                                                                                                                  |
| **07** | `setup-scripts/07-ossm-mc-verify-east-west.sh`                  | Prints `**istioctl proxy-status`**, east–west **Service** / **Endpoints**, and **istiod** pods per context.                                                                                                                                                                                                     |
| **08** | `setup-scripts/08-ossm-mc-verify-ingress-gateway.sh`            | **Optional.** Deploys `**ingress-verify`** echo workload + Gateway/VS (`**manifests/ossm-multi-cluster/ingress-verify/`**), then `**curl`**s the ingress LB per context (`**--contexts`** / `**SETUP_CONTEXTS**`). `**--cleanup**` removes the namespace after success.                                         |


Typical one-liners (from repo root):

```bash
./setup-scripts/00-ossm-mc-cacerts.sh generate --base "$PWD" --clusters rosa-001,rosa-002,rosa-003
./setup-scripts/00-ossm-mc-cacerts.sh verify --base "$PWD"
./setup-scripts/00-ossm-mc-cacerts.sh apply --base "$PWD" \
  --context-map 'rosa-001:rosa-001,rosa-002:rosa-002,rosa-003:rosa-003' --replace --network-suffix network

./setup-scripts/02-ossm-mc-apply-istio.sh --contexts rosa-001,rosa-002,rosa-003
./setup-scripts/03-ossm-mc-apply-ingress-gateway.sh --contexts rosa-001,rosa-002,rosa-003
./setup-scripts/08-ossm-mc-verify-ingress-gateway.sh --contexts rosa-001,rosa-002,rosa-003
PATH="$PWD/.bin:$PATH" ./setup-scripts/04-ossm-mc-remote-secrets.sh
./setup-scripts/06-ossm-mc-apply-east-west.sh
PATH="$PWD/.bin:$PATH" ./setup-scripts/07-ossm-mc-verify-east-west.sh
```

Most setup scripts accept `**--dry-run**` (typically `**oc apply --dry-run=client**`) to validate YAML without mutating clusters; `**07**` is read-only and documents `**--dry-run**` as a no-op. `**08**` supports `**--dry-run**` and optional `**--cleanup**`.

---

## Sample workloads (cross-cluster HTTP)

Under `**manifests/ossm-multi-cluster/samples/**` there are split **helloworld** and **sleep** YAML files used to validate routing and load balancing across clusters (e.g. **v1** on one cluster, **v2** on another, client on a third). Apply them with `**oc apply`** per cluster after sidecar injection is enabled on namespace `**sample`**. A `**DestinationRule`** is included to relax locality load balancing for demos.

---

## References

- [Red Hat OpenShift Service Mesh 3.3 — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies)

---

## Contributing / keeping docs fresh

- **Cursor / AI agents:** see `**AGENTS.md`** in the repo root for project context and edit conventions.
- Bump **script numbers**, **paths**, and **table rows** in this file whenever you add or reorder automation under `**setup-scripts/`**.
- If defaults change (`meshID`, `**spec.version`**, cluster names, namespaces), mirror those defaults here or point to the manifest files explicitly.
- Prefer small, focused edits to this README alongside functional changes so scale-test operators always have a single place to read.


# istio-scale-tests

This repository holds automation and manifests used to **scale-test Istio in a multi-cluster setup** on OpenShift. The target pattern is **multi-primary, multi-network** mesh: several independent clusters share one logical mesh (common mesh id and trust), with **Istio** delivered via the **Sail operator** (`Istio` / `IstioCNI` CRs). Procedures follow **[Red Hat OSSM 3.3 — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies)**; pinned OpenShift / Kubernetes / Istio versions live in `**config/versions.env`**.

Use it to reproduce installs, certificate wiring, remote secrets, east–west gateways, and sample workloads—then measure behavior under load or changing cluster counts.

**Maintainer note:** When you add or rename scripts under `**istio-setup/`**, change default contexts (`rosa-*`), Istio versions, or manifest paths, update this README in the same change so operators stay aligned.

---

## What you need

- `**oc`** / `**kubectl`** logged into every test cluster (example contexts used in scripts: `rosa-001`, `rosa-002`, `rosa-003`—**edit the scripts** if your kubeconfig uses different names).
- **Platform / mesh pins** (defaults): OpenShift **4.18.38**, Kubernetes **v1.31.14**, Istio `**spec.version`** **v1.28.5**, optional RHACM hub channel **`release-2.15`** — see `**config/versions.env`** (override with env vars when testing other trains). Keep **`ACM_CHANNEL`** aligned with **`OPENSHIFT_VERSION`** using the [RHACM support matrix](https://access.redhat.com/articles/7133095).
- `**istioctl`** matching `**ISTIO_VERSION`** from `**config/versions.env`**. Scripts often expect `istioctl` on `PATH`, or place a binary at `**.bin/istioctl`** and prepend `PATH="$PWD/.bin:$PATH"`.
- `**openssl`**, `**jq`**, `**bash` 4+**, `**curl`** (used by various scripts).
- `**envsubst`** from **gettext** (template rendering for `**004`** and `**008`**).
- `**git`**, Helm 3 — `**istio-setup/001`** installs the RHACM hub from `**charts/acm-hub**`; `**istio-setup/005`** installs `**istio/gateway**` from `**ISTIO_HELM_REPO_URL**` at `**ISTIO_GATEWAY_CHART_VERSION**`.
- **OpenShift Service Mesh / Sail operator** installed on each cluster so `istio.sailoperator.io` and `istiocni.sailoperator.io` CRDs exist before applying manifests.

---

## Repository layout


| Path                                | Role                                                                                                                                                                                                                                                     |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `**istio-setup/`**                  | Numbered shell helpers (`**001`–`010**`) for mesh install and wiring (run in order; see below).                                                                                                                                                         |
| `**charts/acm-hub/**`               | Local Helm chart for the RHACM hub (`**001-acm-install-hub.sh**`) — Namespace, OperatorGroup, Subscription, MultiClusterHub; edit `**values.yaml`** / `**templates/**` without changing the script.                                                      |
| `**manifests/ossm-multi-cluster/`** | `**templates/*.yaml.tpl`** — rendered by `**istio-setup/004`** / `**008`** (`envsubst` + `**config/versions.env**`); `**east-west/common/**`, `**ingress-verify/**`, optional `**samples/**`. Ingress gateways use Helm `**istio/gateway**` in `**005**`. |
| `**cacerts/**`                      | Generated plug-in CA material and per-cluster intermediates (created by `**istio-setup/002-ossm-mc-cacerts.sh**`).                                                                                                                                       |
| `**.gitignore**`                    | Ignores `**/cacerts/**` and `**/manifests/**` so secrets and environment-specific YAML are not committed by default. Files already tracked by Git stay tracked; adjust `.gitignore` if you want to version canonical templates only.                     |
| `**terraform/rosa-hcp/**`           | Optional Terraform stack for **ROSA HCP** (upstream `terraform-redhat/rosa-hcp/rhcs`): one VPC and STS stack per cluster (`for_each`) — see `**terraform/rosa-hcp/README.md`**.                                                                          |


---

## How to run the stack (operational order)

Setup scripts in `**istio-setup/`** use prefixes `**001`–`010`** in the sequence they are normally executed. Use **`001`** when you want an **ACM hub** on the first ROSA cluster from Terraform outputs (optional for mesh workflows).


| Step    | Script                                                           | Purpose                                                                                                                                                                                                                                                                                                         |
| ------- | ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **001** | `istio-setup/001-acm-install-hub.sh`                             | **Optional.** Installs **Red Hat Advanced Cluster Management** hub via Helm (`**charts/acm-hub**`): OLM subscription + **MultiClusterHub** on **one** cluster. Default **`ACM_CHANNEL`** pairs with **`OPENSHIFT_VERSION`** in `**config/versions.env`**. Pass **`--context`** or rely on **`terraform/rosa-hcp`** output **`first_cluster`** to pick the kube context (API URL match). Run first if the hub should own cluster imports before mesh install. |
| **002** | `istio-setup/002-ossm-mc-cacerts.sh`                             | Generate a shared root + per-cluster intermediate CAs; `**verify`**; optional `**apply`** to create the `**cacerts**` Secret in `istio-system` and label `**topology.istio.io/network**` on each cluster.                                                                                                       |
| **003** | `istio-setup/003-ossm-mc-kubeconfig-embed-api-ca.sh`             | **Optional.** Embeds API server TLS chains into your kubeconfig so `**istioctl create-remote-secret`** produces Secrets **istiod** can use (e.g. ROSA APIs with Let’s Encrypt). Run before **006** if remote watches fail with TLS errors.                                                                      |
| **004** | `istio-setup/004-ossm-mc-apply-istio.sh`                         | Renders `**templates/istio-cni.yaml.tpl`** and `**templates/istio.cluster.yaml.tpl`** (`**--contexts`** / `**SETUP_CONTEXTS`**). `**Istio/default**` sets mesh Envoy **access logging** via `**meshConfig`** (`**ACCESS_LOG_*`** in `**config/versions.env`**). Waits for Ready (skipped with `**--dry-run`**). |
| **005** | `istio-setup/005-ossm-mc-apply-ingress-gateway.sh`               | Per cluster: `**istio/gateway`** → `**istio-system/istio-ingressgateway`** LoadBalancer (**HTTP 80/HTTPS 443**). SCC-safe Helm flags; optional `**AWS_LOAD_BALANCER_*_SECURITY_GROUPS`** (see `**config/versions.env`**) for ROSA/NLB SGs. `**--contexts`** / `**SETUP_CONTEXTS**`.                             |
| **006** | `istio-setup/006-ossm-mc-remote-secrets.sh`                      | For each ordered pair of clusters, runs `**istioctl create-remote-secret`** and applies the result to the other clusters’ `**istio-system`** so **istiod** can discover remote services.                                                                                                                        |
| **007** | `istio-setup/007-ossm-mc-remote-secrets-insecure-apiserver.sh`   | **Optional fallback.** Patches remote-secret kubeconfigs to `**insecure-skip-tls-verify: true`** for remote apiservers when CA embedding alone is not enough (lab only; prefer proper CA bundles for production). Restart `**istiod`** afterward if endpoints do not refresh.                                   |
| **008** | `istio-setup/008-ossm-mc-apply-east-west.sh`                       | Renders `**templates/east-west-gateway.yaml.tpl`** per cluster; applies `**east-west/common/expose-services.yaml`** (`cross-network-gateway`, port **15443**).                                                                                                                                                  |
| **009** | `istio-setup/009-ossm-mc-verify-east-west.sh`                    | Prints `**istioctl proxy-status`**, east–west **Service** / **Endpoints**, and **istiod** pods per context.                                                                                                                                                                                                     |
| **010** | `istio-setup/010-ossm-mc-verify-ingress-gateway.sh`              | **Optional.** Deploys `**ingress-verify`** echo workload + Gateway/VS (`**manifests/ossm-multi-cluster/ingress-verify/`**), then `**curl`**s the ingress LB per context (`**--contexts`** / `**SETUP_CONTEXTS**`). `**--cleanup**` removes the namespace after success.                                          |

Typical one-liners (from repo root):

```bash
# Optional: ACM hub on first Terraform cluster (context auto-resolved when state exists)
./istio-setup/001-acm-install-hub.sh --context rosa-001

./istio-setup/002-ossm-mc-cacerts.sh generate --base "$PWD" --clusters rosa-001,rosa-002,rosa-003
./istio-setup/002-ossm-mc-cacerts.sh verify --base "$PWD"
./istio-setup/002-ossm-mc-cacerts.sh apply --base "$PWD" \
  --context-map 'rosa-001:rosa-001,rosa-002:rosa-002,rosa-003:rosa-003' --replace --network-suffix network

./istio-setup/004-ossm-mc-apply-istio.sh --contexts rosa-001,rosa-002,rosa-003
./istio-setup/005-ossm-mc-apply-ingress-gateway.sh --contexts rosa-001,rosa-002,rosa-003
./istio-setup/010-ossm-mc-verify-ingress-gateway.sh --contexts rosa-001,rosa-002,rosa-003
PATH="$PWD/.bin:$PATH" ./istio-setup/006-ossm-mc-remote-secrets.sh
./istio-setup/008-ossm-mc-apply-east-west.sh
PATH="$PWD/.bin:$PATH" ./istio-setup/009-ossm-mc-verify-east-west.sh
```

Most setup scripts accept `**--dry-run**` (typically `**oc apply --dry-run=client**`) to validate YAML without mutating clusters; `**009**` is read-only and documents `**--dry-run**` as a no-op. `**010**` supports `**--dry-run**` and optional `**--cleanup**`.

---

## Sample workloads (cross-cluster HTTP)

Under `**manifests/ossm-multi-cluster/samples/**` there are split **helloworld** and **sleep** YAML files used to validate routing and load balancing across clusters (e.g. **v1** on one cluster, **v2** on another, client on a third). Apply them with `**oc apply`** per cluster after sidecar injection is enabled on namespace `**sample`**. A `**DestinationRule`** is included to relax locality load balancing for demos.

---

## References

- [Red Hat OpenShift Service Mesh 3.3 — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies)

---

## Contributing / keeping docs fresh

- **Cursor / AI agents:** see `**AGENTS.md`** in the repo root for project context and edit conventions.
- Bump **script numbers**, **paths**, and **table rows** in this file whenever you add or reorder automation under `**istio-setup/`**.
- If defaults change (`meshID`, `**spec.version`**, cluster names, namespaces), mirror those defaults here or point to the manifest files explicitly.
- Prefer small, focused edits to this README alongside functional changes so scale-test operators always have a single place to read.


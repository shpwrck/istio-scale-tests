# istio-scale-tests

This repository holds automation and manifests used to scale-test Istio in a multi-cluster setup on OpenShift. The target pattern is multi-primary, multi-network mesh: several independent clusters share one logical mesh (common mesh id and trust), with Istio delivered via the Sail operator (`Istio` / `IstioCNI` CRs). Procedures follow [Red Hat OSSM 3.3 — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies); pinned OpenShift / Kubernetes / Istio versions live in `config/versions.env`.

Use it to reproduce installs, certificate wiring, remote secrets, east–west gateways, and sample workloads—then measure behavior under load or changing cluster counts.

---

## What you need

On the machine where you run repo commands (tests assume bash 4+):


| Binary / runtime  | Notes                                                                                                                                                             |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bash`            | 4 or newer (`platform-setup/` and `istio-setup/` scripts use bash).                                                                                               |
| `oc` or `kubectl` | With a kubeconfig that can reach every cluster; context names should match what you pass to `--contexts` / `SETUP_CONTEXTS` (examples in docs use `rosa-001`, …). |
| `terraform`       | To apply `terraform/rosa-hcp/` (pinned Terraform version: see that directory’s `versions.tf`).                                                                    |
| `helm`            | Helm 3 for `platform-setup/001`, `istio-setup/004`, and charts under `charts/`.                                                                                   |
| `istioctl`        | On `PATH`, or a binary at `.bin/istioctl` with `PATH="$PWD/.bin:$PATH"`; align the build with `ISTIO_VERSION` in `config/versions.env`.                           |
| `jq`              | JSON filtering (Terraform merge helper, script outputs).                                                                                                          |
| `openssl`         | CA generation (`istio-setup/001`).                                                                                                                                |
| `curl`            | Ingress checks and helpers.                                                                                                                                       |
| `envsubst`        | Usually from gettext — template rendering (`istio-setup/003`, `istio-setup/007`).                                                                                 |
| `git`             | Only if you clone or vendor tooling outside this repo.                                                                                                            |


Optional (later steps): Go on `PATH` when running `isotope-multicluster/` against a local [istio/tools](https://github.com/istio/tools) checkout.

---

## End-to-end order

Run automation in this sequence:

1. Infrastructure — provision clusters with Terraform (`terraform/rosa-hcp/`).
2. Optional ACM / GitOps and mesh — `platform-setup/` for RHACM hub + hub GitOps (`001`, `002`), then install and verify Istio across clusters (`istio-setup/`, `001`–`009`).
3. Load testing — deploy the multicluster Isotope topology (`isotope-multicluster/`).
4. Results — collect metrics and reports from the run *(section reserved; tooling not yet in this repository)*.

---

## 1. Provision clusters (Terraform)

Use `terraform/rosa-hcp/` to create ROSA HCP clusters (upstream module `terraform-redhat/rosa-hcp/rhcs`). You set `cluster_count`, `cluster_name_format`, and `vpc_cidr_format` (plus pins such as `openshift_version`); each cluster gets its own VPC, OIDC stack, and IAM roles. Outputs include API URLs and a shared `cluster_admin_login`; kubeconfig is built outside Terraform (see `terraform/rosa-hcp/README.md` and `terraform/scripts/001-oc-login-merge-kubeconfig.sh`).

---

## 2. Optional ACM / GitOps (`platform-setup/`) and mesh (`istio-setup/`)

After clusters exist and you can `oc login`, run scripts in directory order: optional `platform-setup/` 001 (ACM hub) and 002 (OpenShift GitOps + ACM GitOpsCluster on the hub), then `istio-setup/` 001–009 for CA material, optional kubeconfig CA embedding, Istio CRs, ingress gateway, remote secrets, east–west gateways, and checks.


| Path                                     | Role                                                                                                                                                                                                                              |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `platform-setup/`                        | Optional 001 ACM hub + 002 hub GitOps / Argo wiring (`README.md` in this directory).                                                                                                                                              |
| `istio-setup/`                           | Mesh install and checks (001–009; table below).                                                                                                                                                                                   |
| `charts/acm-operator/`                   | OLM OperatorGroup + Subscription for the ACM operator (`platform-setup/001-acm-install-hub.sh`).                                                                                                                                  |
| `charts/acm-multicluster-hub/`           | `MultiClusterHub` CR only (`platform-setup/001`).                                                                                                                                                                                 |
| `charts/acm-klusterlet-config/`          | `KlusterletConfig` CR only (`platform-setup/001`, after CRD exists).                                                                                                                                                              |
| `charts/acm-managed-cluster/`            | One `ManagedCluster` per Helm release / spoke; `platform-setup/001-acm-install-hub.sh` loops Terraform keys (excluding hub) after MCH Running, then applies hub secret `import.yaml` on each spoke context.                       |
| `charts/openshift-gitops-operator/`      | OLM OperatorGroup + Subscription for Red Hat OpenShift GitOps (`platform-setup/002-acm-openshift-gitops.sh`).                                                                                                                     |
| `charts/acm-openshift-gitops-resources/` | Helm — ManagedClusterSetBinding, Placement, GitOpsCluster for hub Argo CD (`platform-setup/002`).                                                                                                                                 |
| `charts/gitops-hub-app-of-apps/`        | Helm — Argo CD `Application` CRs: `hub-gitops-root` + `hub-cert-manager-operator` (`platform-setup/002`).                                                                                                                          |
| `charts/gitops-hub-apps/`                 | Helm — hub child Applications / YAML under `templates/`; synced by `hub-gitops-root`.                                                                                                                                              |
| `charts/cert-manager-operator/`          | Helm — OLM install for cert-manager Operator for Red Hat OpenShift; synced by `hub-cert-manager-operator`.                                                                                                                        |
| `manifests/ossm-multi-cluster/`          | `templates/*.yaml.tpl` — rendered by `istio-setup/003` / `istio-setup/007` (`envsubst` + `config/versions.env`); `east-west/common/`, `ingress-verify/`, optional `samples/`. Ingress gateways use Helm `istio/gateway` in `004`. |
| `cacerts/`                               | Generated plug-in CA material and per-cluster intermediates (created by `istio-setup/001-ossm-mc-cacerts.sh`).                                                                                                                    |


### Platform scripts (`platform-setup/`)

Use 001 for an ACM hub on the first ROSA cluster from Terraform outputs (optional for mesh-only workflows). Use 002 after 001 to install OpenShift GitOps and wire ACM GitOpsCluster ([RHACM GitOps overview](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/gitops/gitops-overview)).


| Step | Script                                       | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ---- | -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 001  | `platform-setup/001-acm-install-hub.sh`      | Optional. Merged kubeconfig from Terraform (unless `--skip-managed-clusters`), then `charts/acm-operator` → wait CSV → `charts/acm-multicluster-hub` → wait Running → `charts/acm-klusterlet-config` (optional) → `charts/acm-managed-cluster` + import on spokes → wait ManagedCluster Joined+Available for each Terraform cluster key. Default `ACM_CHANNEL` pairs with `OPENSHIFT_VERSION` in `config/versions.env`. `ACM_WAIT_MANAGED_CLUSTER_READY`, `ACM_INSTALL_KLUSTERLETCONFIG`, `--skip-managed-clusters`, `--skip-import`, `--skip-wait`, `--dry-run` control behavior. |
| 002  | `platform-setup/002-acm-openshift-gitops.sh` | Optional (ACM). After platform 001: Helm `charts/openshift-gitops-operator` → wait for CSV + Argo CD → Helm `charts/gitops-hub-app-of-apps` (hub Argo Applications pointing at repo charts) → Helm `charts/acm-openshift-gitops-resources` (ManagedClusterSetBinding, Placement excluding hub, GitOpsCluster), then patches Argo cluster Secrets by default (public API URL + token; `--patch-argoc-cluster-secrets-only` to re-run). Uses `config/versions.env`.                                                                                                             |


### Mesh scripts (`istio-setup/`)


| Step | Script                                                         | Purpose                                                                                                                                                                                                                                                                 |
| ---- | -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 001  | `istio-setup/001-ossm-mc-cacerts.sh`                           | Generate a shared root + per-cluster intermediate CAs; `verify`; optional `apply` to create the `cacerts` Secret in `istio-system` and label `topology.istio.io/network` on each cluster.                                                                               |
| 002  | `istio-setup/002-ossm-mc-kubeconfig-embed-api-ca.sh`           | Optional. Embeds API server TLS chains into your kubeconfig so `istioctl create-remote-secret` produces Secrets istiod can use (e.g. ROSA APIs with Let’s Encrypt). Run before 005 if remote watches fail with TLS errors.                                              |
| 003  | `istio-setup/003-ossm-mc-apply-istio.sh`                       | Renders `templates/istio-cni.yaml.tpl` and `templates/istio.cluster.yaml.tpl` (`--contexts` / `SETUP_CONTEXTS`). `Istio/default` sets mesh Envoy access logging via `meshConfig` (`ACCESS_LOG`_* in `config/versions.env`). Waits for Ready (skipped with `--dry-run`). |
| 004  | `istio-setup/004-ossm-mc-apply-ingress-gateway.sh`             | Per cluster: `istio/gateway` → `istio-system/istio-ingressgateway` LoadBalancer (HTTP 80/HTTPS 443). SCC-safe Helm flags; optional `AWS_LOAD_BALANCER_*_SECURITY_GROUPS` (see `config/versions.env`) for ROSA/NLB SGs. `--contexts` / `SETUP_CONTEXTS`.                 |
| 005  | `istio-setup/005-ossm-mc-remote-secrets.sh`                    | For each ordered pair of clusters, runs `istioctl create-remote-secret` and applies the result to the other clusters’ `istio-system` so istiod can discover remote services.                                                                                            |
| 006  | `istio-setup/006-ossm-mc-remote-secrets-insecure-apiserver.sh` | Optional fallback. Patches remote-secret kubeconfigs to `insecure-skip-tls-verify: true` for remote apiservers when CA embedding alone is not enough (lab only; prefer proper CA bundles for production). Restart istiod afterward if endpoints do not refresh.         |
| 007  | `istio-setup/007-ossm-mc-apply-east-west.sh`                   | Renders `templates/east-west-gateway.yaml.tpl` per cluster; applies `east-west/common/expose-services.yaml` (`cross-network-gateway`, port 15443).                                                                                                                      |
| 008  | `istio-setup/008-ossm-mc-verify-east-west.sh`                  | Prints `istioctl proxy-status`, east–west Service / Endpoints, and istiod pods per context.                                                                                                                                                                             |
| 009  | `istio-setup/009-ossm-mc-verify-ingress-gateway.sh`            | Optional. Deploys `ingress-verify` echo workload + Gateway/VS (`manifests/ossm-multi-cluster/ingress-verify/`), then curls the ingress LB per context (`--contexts` / `SETUP_CONTEXTS`). `--cleanup` removes the namespace after success.                               |


Typical one-liners (from repo root):

```bash
# Optional: ACM hub on first Terraform cluster (context auto-resolved when state exists)
./platform-setup/001-acm-install-hub.sh --context rosa-001

# Optional: OpenShift GitOps + ACM GitOpsCluster on hub (after platform 001; mesh CA is istio-setup/001 below)
./platform-setup/002-acm-openshift-gitops.sh --context rosa-001

./istio-setup/001-ossm-mc-cacerts.sh generate --base "$PWD" --clusters rosa-001,rosa-002,rosa-003
./istio-setup/001-ossm-mc-cacerts.sh verify --base "$PWD"
./istio-setup/001-ossm-mc-cacerts.sh apply --base "$PWD" \
  --context-map 'rosa-001:rosa-001,rosa-002:rosa-002,rosa-003:rosa-003' --replace --network-suffix network

./istio-setup/003-ossm-mc-apply-istio.sh --contexts rosa-001,rosa-002,rosa-003
./istio-setup/004-ossm-mc-apply-ingress-gateway.sh --contexts rosa-001,rosa-002,rosa-003
./istio-setup/009-ossm-mc-verify-ingress-gateway.sh --contexts rosa-001,rosa-002,rosa-003
PATH="$PWD/.bin:$PATH" ./istio-setup/005-ossm-mc-remote-secrets.sh
./istio-setup/007-ossm-mc-apply-east-west.sh
PATH="$PWD/.bin:$PATH" ./istio-setup/008-ossm-mc-verify-east-west.sh
```

Most setup scripts accept `--dry-run` (typically `oc apply --dry-run=client`) to validate YAML without mutating clusters; 008 is read-only and documents `--dry-run` as a no-op. 009 supports `--dry-run` and optional `--cleanup`.

### Sample workloads (optional)

Under `manifests/ossm-multi-cluster/samples/` there are split helloworld and sleep YAML files used to validate routing and load balancing across clusters (e.g. v1 on one cluster, v2 on another, client on a third). Apply them with `oc apply` per cluster after sidecar injection is enabled on namespace `sample`. A `DestinationRule` is included to relax locality load balancing for demos.

---

## 3. Run Isotope (`isotope-multicluster/`)

Multicluster [istio/tools isotope](https://github.com/istio/tools/tree/master/isotope) workload: generate a chain topology from Terraform `cluster_keys`, render manifests, and apply per context. Requires a local istio/tools clone, Go, and an isotope service image. Run after mesh steps `003`–`007` (remote secrets and east–west). See `isotope-multicluster/README.md` for prerequisites, `001-generate-topology-from-terraform.sh`, and `002-apply-isotope-multicluster.sh`.

---

## 4. Gather results

*This step is not implemented in the repository yet. It will document how to pull telemetry, Fortio output, and other artifacts into a single report after Isotope (or other load generators) finish.*

---

## References

- [Red Hat OpenShift Service Mesh 3.3 — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies)

---

## Coding agents

See `AGENTS.md` in the repository root for project context, edit conventions, and keeping documentation aligned with code changes.
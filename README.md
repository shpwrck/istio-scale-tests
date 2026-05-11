# istio-scale-tests

This repository holds automation and manifests used to scale-test Istio in a multi-cluster setup on OpenShift. The target pattern is multi-primary, multi-network mesh: several independent clusters share one logical mesh (common mesh id and trust), with Istio delivered via the Sail operator (`Istio` / `IstioCNI` CRs). Procedures follow [Red Hat OSSM 3.3 — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies); pinned OpenShift / Kubernetes / Istio versions live in `config/versions.env`.

Use it to reproduce installs, certificate wiring, remote secrets, east–west gateways, and sample workloads—then measure behavior under load or changing cluster counts.

```
   Multi-primary, multi-network mesh — mesh-id: mesh1
   Shared plug-in CA: root + per-cluster intermediates (cacerts/)

     ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
     │   rosa-001   │    │   rosa-002   │    │   rosa-003   │
     │  network-1   │    │  network-2   │    │  network-3   │
     ├──────────────┤    ├──────────────┤    ├──────────────┤
     │ istiod       │    │ istiod       │    │ istiod       │
     │ ingress-gw   │    │ ingress-gw   │    │ ingress-gw   │
     │ east-west-gw │◄─▶│ east-west-gw │◄─▶│ east-west-gw │
     │  :15443      │    │  :15443      │    │  :15443      │
     └──────┬───────┘    └──────┬───────┘    └──────┬───────┘
            └────── remote secrets (istio-setup/005) ──────┘
              istiod on each cluster watches remote APIs
```

---

## Quick start

Already have three ROSA HCP clusters with merged kubeconfig contexts `rosa-001`, `rosa-002`, `rosa-003`? Run a mesh-only install end-to-end from the repo root:

```bash
export SETUP_CONTEXTS=rosa-001,rosa-002,rosa-003
source config/versions.env

# Plug-in CA + Istio + ingress
./istio-setup/001-ossm-mc-cacerts.sh generate --base "$PWD" --clusters "$SETUP_CONTEXTS"
./istio-setup/001-ossm-mc-cacerts.sh apply --base "$PWD" \
  --context-map 'rosa-001:rosa-001,rosa-002:rosa-002,rosa-003:rosa-003' \
  --replace --network-suffix network
./istio-setup/003-ossm-mc-apply-istio.sh
./istio-setup/004-ossm-mc-apply-ingress-gateway.sh

# Multi-cluster wiring + verify
PATH="$PWD/.bin:$PATH" ./istio-setup/005-ossm-mc-remote-secrets.sh
./istio-setup/007-ossm-mc-apply-east-west.sh
PATH="$PWD/.bin:$PATH" ./istio-setup/008-ossm-mc-verify-east-west.sh
```

No clusters yet? Start at [§1 Provision clusters](#1-provision-clusters-terraform). Want GitOps-driven installs? Enable `enable_platform_setup = true` in Terraform (see `terraform/rosa-hcp/README.md`).

---

## End-to-end order

Run automation in this sequence:

1. Infrastructure — provision clusters with Terraform (`terraform/rosa-hcp/`).
2. Mesh — install and verify Istio across clusters (`istio-setup/`, `001`–`009`). Optional GitOps overlay: set `enable_platform_setup = true` in Terraform.
3. Load testing — deploy the multicluster Isotope topology (`isotope-multicluster/`).

---

## What you need

On the machine where you run repo commands (tests assume bash 4+):


| Binary / runtime  | Notes                                                                                                                                                             |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bash`            | 4 or newer (`istio-setup/` scripts use bash).                                                                                                                     |
| `oc` or `kubectl` | With a kubeconfig that can reach every cluster; context names should match what you pass to `--contexts` / `SETUP_CONTEXTS` (examples in docs use `rosa-001`, …). |
| `terraform`       | To apply `terraform/rosa-hcp/` (pinned Terraform version: see that directory’s `versions.tf`).                                                                    |
| `helm`            | Helm 3 for `istio-setup/004` and charts under `charts/`.                                                                                                          |
| `istioctl`        | On `PATH`, or a binary at `.bin/istioctl` with `PATH="$PWD/.bin:$PATH"`; align the build with `ISTIO_VERSION` in `config/versions.env`.                           |
| `jq`, `openssl`, `curl`, `envsubst` | Standard Unix utilities — `jq` for Terraform/script JSON, `openssl` for `istio-setup/001` CA generation, `curl` for ingress checks, `envsubst` (gettext) renders templates in `istio-setup/003` and `007`. |


Optional (later steps): Go on `PATH` when running `isotope-multicluster/` against a local [istio/tools](https://github.com/istio/tools) checkout.

**Configuration:** most scripts read defaults from `config/versions.env`. `source` it before overriding any variable; common ones: `SETUP_CONTEXTS`, `ISTIO_VERSION`, `MESH_ID`, `OPENSHIFT_VERSION`.

---

## 1. Provision clusters (Terraform)

Use `terraform/rosa-hcp/` to create ROSA HCP clusters (upstream module `terraform-redhat/rosa-hcp/rhcs`). You set `cluster_count`, `cluster_name_format`, and `vpc_cidr_format` (plus pins such as `openshift_version`); each cluster gets its own VPC, OIDC stack, and IAM roles. Outputs include API URLs and a shared `cluster_admin_login`. Log in with `oc login` per cluster (see `terraform/rosa-hcp/README.md`). Optional: set `enable_platform_setup = true` to install ACM + GitOps on the hub in a second apply.

---

## 2. Install the mesh (`istio-setup/`)

After clusters exist and you can `oc login`, run `istio-setup/` 001–009 for CA material, optional kubeconfig CA embedding, Istio CRs, ingress gateway, remote secrets, east–west gateways, and checks. If you want a GitOps-driven workflow on top, set `enable_platform_setup = true` in Terraform before running mesh scripts.

<details>
<summary><b>Repository layout</b> — directories and Helm charts (click to expand)</summary>

| Path                                     | Role                                                                                                                                                                                                                              |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `terraform/rosa-hcp/platform_acm.tf`     | ACM operator + MultiClusterHub + KlusterletConfig on the hub (gated by `enable_platform_setup`).                                                                                                                                  |
| `terraform/rosa-hcp/platform_acm_spokes.tf` | Spoke ManagedCluster + auto-import-secret per non-hub cluster.                                                                                                                                                                |
| `terraform/rosa-hcp/platform_gitops.tf`  | OpenShift GitOps operator + ArgoCD config + ACM GitOps wiring + app-of-apps.                                                                                                                                                      |
| `istio-setup/`                           | Mesh install and checks (001–009; table below).                                                                                                                                                                                   |
| `charts/acm-operator/`                   | Helm chart: OLM OperatorGroup + Subscription for ACM (used by Terraform `platform_acm.tf`).                                                                                                                                       |
| `charts/acm-multicluster-hub/`           | Helm chart: `MultiClusterHub` CR only (Terraform `platform_acm.tf`).                                                                                                                                                              |
| `charts/acm-klusterlet-config/`          | Helm chart: `KlusterletConfig` CR only (Terraform `platform_acm.tf`, after CRD exists).                                                                                                                                           |
| `charts/acm-managed-cluster/`            | Helm chart: one `ManagedCluster` per spoke (Terraform `platform_acm_spokes.tf`).                                                                                                                                                   |
| `charts/openshift-gitops-operator/`      | Helm chart: OLM Subscription for Red Hat OpenShift GitOps (Terraform `platform_gitops.tf`).                                                                                                                                        |
| `charts/acm-openshift-gitops-resources/` | Helm — ManagedClusterSetBinding, Placement, GitOpsCluster for hub Argo CD (Terraform `platform_gitops.tf`).                                                                                                                        |
| `charts/gitops-hub-app-of-apps/`        | Helm — Argo CD `Application` CR `hub-gitops-root` (directory sync of `charts/gitops-hub-apps/applications`) (Terraform `platform_gitops.tf`).                                                                                      |
| `charts/gitops-hub-apps/`                 | Plain YAML child `Application` manifests under `applications/`; applied when `hub-gitops-root` syncs.                                                                                                                               |
| `charts/cert-manager-operator/`          | Helm — OLM install for cert-manager Operator for Red Hat OpenShift; synced by `hub-cert-manager-operator`.                                                                                                                        |
| `charts/hub-mesh-ca/`                    | Helm — cert-manager mesh root + `ClusterIssuer` stack; intermediates optional or delegated to `hub-mesh-ca-intermediate` + ApplicationSet (after operator).                                                                        |
| `charts/hub-mesh-ca-intermediate/`       | Helm — single intermediate CA `Certificate` per cluster name (synced by ApplicationSet-generated Applications).                                                                                                                      |
| `charts/hub-kubeconfig-from-argosecret/` | Helm — External Secrets `SecretStore` + `ExternalSecret` per cluster name; deploys CRs into the External Secrets operand namespace (default `external-secrets-operator`), reads Argo `*-application-manager-cluster-secret` from `openshift-gitops` (ApplicationSet preset `values-kubeconfig-from-argosecret.yaml`). |
| `charts/gitops-hub-ocm-placement-appset/` | Helm — standard ApplicationSet + RBAC (`values-mesh-ca-intermediate.yaml` / `values-external-secrets.yaml` / `values-kubeconfig-from-argosecret.yaml`); shared PlacementDecision duck-type ConfigMap from `acm-openshift-gitops-resources`. |
| `manifests/ossm-multi-cluster/`          | `templates/*.yaml.tpl` — rendered by `istio-setup/003` / `istio-setup/007` (`envsubst` + `config/versions.env`); `east-west/common/`, `ingress-verify/`, optional `samples/`. Ingress gateways use Helm `istio/gateway` in `004`. |
| `cacerts/`                               | Generated plug-in CA material and per-cluster intermediates (created by `istio-setup/001-ossm-mc-cacerts.sh`).                                                                                                                    |

</details>


### Optional — ACM + GitOps (Terraform)

Skip this subsection for mesh-only flows. ACM and OpenShift GitOps are installed via Terraform with a two-phase apply. After provisioning clusters, set `enable_platform_setup = true` and re-apply:

```bash
# In terraform/rosa-hcp/:
# 1. First apply creates ROSA clusters (enable_platform_setup defaults to false)
terraform apply

# 2. Set enable_platform_setup = true in terraform.tfvars, then:
terraform apply
# This installs ACM operator, MultiClusterHub, imports spokes, installs GitOps,
# configures ArgoCD, and deploys the app-of-apps.
```

See `terraform/rosa-hcp/README.md` for variables controlling ACM channel, GitOps config, and spoke import behavior.


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


Most setup scripts accept `--dry-run` (typically `oc apply --dry-run=client`) to validate YAML without mutating clusters; 008 is read-only and documents `--dry-run` as a no-op. 009 supports `--dry-run` and optional `--cleanup`.

### Sample workloads (optional)

Under `manifests/ossm-multi-cluster/samples/` there are split helloworld and sleep YAML files used to validate routing and load balancing across clusters (e.g. v1 on one cluster, v2 on another, client on a third). Apply them with `oc apply` per cluster after sidecar injection is enabled on namespace `sample`. A `DestinationRule` is included to relax locality load balancing for demos.

---

## Verify the mesh install

Two scripts confirm the multi-cluster mesh is wired correctly:

- **`istio-setup/009-ossm-mc-verify-ingress-gateway.sh`** — deploys an echo workload + Gateway/VirtualService per cluster and curls the ingress LoadBalancer. Each context should return HTTP 200 from the per-cluster hostname.
- **`istio-setup/008-ossm-mc-verify-east-west.sh`** — prints `istioctl proxy-status`, east–west Service/Endpoints, and istiod pods. In `proxy-status`, proxies should report `SYNCED` for endpoints from the *other* clusters (proof remote secrets propagated).

If 008 only shows local endpoints, remote secrets aren't reaching istiod — re-run `istio-setup/005`, and fall back to `istio-setup/006` (lab only) if TLS to remote API servers is the blocker.

---

## 3. Run Isotope (`isotope-multicluster/`)

Multicluster [istio/tools isotope](https://github.com/istio/tools/tree/master/isotope) workload: generate a chain topology from Terraform `cluster_keys`, render manifests, and apply per context. Requires a local istio/tools clone, Go, and an isotope service image. Run after mesh steps `003`–`007` (remote secrets and east–west). See `isotope-multicluster/README.md` for prerequisites, `001-generate-topology-from-terraform.sh`, and `002-apply-isotope-multicluster.sh`.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Remote watches fail with TLS errors after `istio-setup/005` | Remote API server cert chain not trusted by istiod | Run `istio-setup/002` to embed CA chains into your kubeconfig, then re-run 005. Lab fallback: `istio-setup/006` (`insecure-skip-tls-verify`). |
| Ingress LoadBalancer returns connection refused on ROSA AWS | NLB security groups missing or wrong | Set `AWS_LOAD_BALANCER_SECURITY_GROUPS` (and optionally `_EXTRA_`) per the notes in `config/versions.env`, or use `config/ingress-lb-security-groups.map`. |
| `istioctl` errors on unrecognized API versions or schema | Local `istioctl` doesn't match `ISTIO_VERSION` | Place a matching binary at `.bin/istioctl` and prefix `PATH="$PWD/.bin:$PATH"` before mesh scripts. |
| `proxy-status` only lists local endpoints | Remote secrets not propagated | Re-run `istio-setup/005`; restart istiod after applying secrets if endpoints don't refresh. |

---

## References

- [Red Hat OpenShift Service Mesh 3.3 — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies)
- Coding agents: see [`AGENTS.md`](AGENTS.md) for project context, edit conventions, and keeping docs aligned with code changes.
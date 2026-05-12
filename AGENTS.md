# Agent instructions — istio-scale-tests

Use this file with Cursor agents working in this repository. For human-oriented setup and commands, prefer `README.md`.

## Source of truth

Canonical procedures and command patterns for multi-cluster Service Mesh on OpenShift are:

[Red Hat OpenShift Service Mesh 3.3 — Installing — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies)

Base Helm charts and GitOps configuration on this documentation. When generic upstream Istio docs disagree with RH OSSM 3.3 guidance for this stack, prefer OSSM 3.3.

## Implementation rules

- No secrets in git: Never add commits that contain secrets or credentials (see Conventions for edits).
- Mesh via GitOps: The mesh is deployed via Helm charts under `charts/`, synced by Argo CD ApplicationSets using ACM Placement. Do not add bash scripts for mesh installation — use Helm charts and Argo CD Applications instead.
- Numbered bash scripts: Name repo-owned executable bash helpers `NNN-kebab-case.sh` with a three-digit prefix (`001`, `002`, ...). The number reflects typical execution order within that directory (e.g. `isotope-multicluster/001`-`002`). Use this pattern for all such scripts in `isotope-multicluster/`, `terraform/**/scripts/` (when used), and future automation directories — never add unnumbered `*.sh` peers without renumbering the folder. When you add or renumber a script, update callers (e.g. Terraform `external`, other bash wrappers) and README / AGENTS references in the same change.
- Helm charts: Use Helm charts under `charts/` for all mesh resources, platform resources, and operator installations. Follow the established patterns (e.g. `spoke-istio/`, `spoke-ingress-gateway/`, `hub-mesh-push-secrets/`).
- Avoid storing file content in scripts. Use templates appropriate for the situation (Helm charts under `charts/`, etc.) rather than large inline YAML or kubeconfig bodies in bash.
- --dry-run: Setup scripts that mutate clusters (`oc` / `kubectl` / `istioctl apply`) should accept `--dry-run` (typically `oc apply --dry-run=client`) so operators can validate renders without changing the cluster.
- Pinned versions: Maintain a single pin list in `config/versions.env`. Current targets: OpenShift 4.21.11, Kubernetes v1.34.6, Istio / Sail `spec.version` v1.28.5 (match `istioctl`), RHACM hub `ACM_CHANNEL` default `release-2.16` (supported with OpenShift 4.21.x per RHACM matrix — bump with `OPENSHIFT_VERSION`). Bump `README.md` when pins change.

## Script variables and naming (bash)

Keep automation scripts consistent so operators can rely on the same env vars, flags, and internal names.

- Defaults: Scripts that use pinned versions or mesh-wide settings `source "${ROOT}/config/versions.env"` after setting `ROOT`. Put shared defaults (cluster lists, mesh/network IDs) in `config/versions.env` instead of copying literals into each script.
- Kubernetes contexts — environment: `SETUP_CONTEXTS` — comma-separated `kubectl` / `oc` context names (must match kubeconfig). Exported from `config/versions.env`.
- Kubernetes contexts — CLI: Where a script accepts multiple contexts, expose `--contexts CSV` using the same comma-separated format as `SETUP_CONTEXTS`.
- Internal names: Parse `--contexts` into `CONTEXTS_CSV` (string), then split into a bash array `CONTEXTS[@]`. Loop with `ctx` when calling `oc --context="$ctx"` / `kubectl --context="$ctx"`.
- Dry run: Internal `DRY_RUN` (`0`/`1`); user-facing `--dry-run`. Pair them consistently and mention both in `usage` when applicable.
- Repo root: From peer dirs, `ROOT="$(cd "$(dirname "$0")/.." && pwd)"`. Use the same depth pattern if you add scripts under subdirectories (adjust `..` segments).

## Purpose

This repository exists so operators can end-to-end: provision ROSA clusters (or equivalent OpenShift targets), install multi-cluster Istio / OSSM on them following [Red Hat OpenShift Service Mesh multi-cluster documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies) (multi-primary, multi-network meshes using the Sail operator — `Istio`, `IstioCNI`), load dynamic scale tests into those clusters, and produce reports from the runs. The mesh is deployed via GitOps (Argo CD ApplicationSets) rather than manual scripts.

## Repository map


| Path | Use |
| ---- | --- |
| `config/versions.env` | Pinned `OPENSHIFT_VERSION`, `KUBERNETES_VERSION`, `ISTIO_VERSION`, optional `ACM_CHANNEL` / `ACM_NAMESPACE`, `GITOPS_NAMESPACE` / `GITOPS_OPERATOR_NAMESPACE` / `GITOPS_OPERATOR_CHANNEL` / `GITOPS_ARGOCD_CR_NAME`, `ACCESS_LOG_FILE` / `ACCESS_LOG_ENCODING`, `SETUP_CONTEXTS`, mesh/network defaults; `OSSM_DOC_MULTI_CLUSTER_URL`. Sourced by automation scripts; ACM/GitOps defaults also used by Terraform `terraform/platform/variables.tf`. |
| `charts/spoke-ossm-operator/` | Helm chart: OLM Subscription for Sail operator on each spoke (ApplicationSet wave 8). |
| `charts/spoke-istio/` | Helm chart: `Istio` + `IstioCNI` CRs per spoke cluster with per-cluster clusterName, network, meshID (wave 21). |
| `charts/spoke-ingress-gateway/` | Helm chart: north-south ingress gateway (LoadBalancer) per spoke — Deployment, Service, HPA, PDB, RBAC (wave 24). |
| `charts/spoke-east-west-gateway/` | Helm chart: east-west gateway + cross-network Gateway CR per spoke — TLS AUTO_PASSTHROUGH on port 15443 (wave 27). |
| `charts/hub-mesh-ca/` | Helm chart: cert-manager root CA + `ClusterIssuer` chain on the hub. |
| `charts/hub-mesh-ca-intermediate/` | Helm chart: one intermediate CA `Certificate` for a single `clusterName`. |
| `charts/hub-mesh-push-secrets/` | Helm chart: ESO PushSecrets pushing cacerts, kubeconfigs, and Istio remote secrets (with `istio/multiCluster` label) to spoke `istio-system` namespaces. |
| `charts/hub-kubeconfig-from-argosecret/` | Helm chart: `SecretStore` + `ExternalSecret` extracting kubeconfigs from Argo cluster secrets. |
| `charts/external-secrets-operator/` | Helm chart: OLM install for External Secrets Operator per spoke. |
| `charts/cert-manager-operator/` | Helm chart: OLM install for cert-manager Operator on the hub. |
| `charts/mesh-verify/` | Helm chart: standalone echo workload for multicluster mesh verification (not in root app-of-apps). |
| `charts/propagation-test/` | Helm chart: watcher and canary workloads for measuring xDS propagation latency (namespace, watcher pod, conditional canary service/VS/DR). |
| `charts/istiod-monitor/` | Helm chart: OpenShift User Workload Monitoring ServiceMonitor + PrometheusRule for istiod `pilot_*` metrics. |
| `charts/gitops-hub-ocm-placement-appset/` | Reusable Helm chart: Argo CD `ApplicationSet` for OCM Placement + RBAC; preset value files per component (e.g. `values-istio.yaml`, `values-ingress-gateway.yaml`, `values-mesh-push-secrets.yaml`). |
| `charts/gitops-hub-app-of-apps/` | Helm chart: Argo CD `Application` CRs on the hub — `hub-gitops-root` (directory path `charts/gitops-hub-apps/applications` for child `Application` YAML) (Terraform `terraform/platform/platform_gitops.tf`). |
| `charts/gitops-hub-apps/` | Child hub `Application` manifests under `applications/` (directory-synced by `hub-gitops-root`). |
| `charts/acm-operator/` | Helm chart: OLM OperatorGroup + Subscription for ACM (Terraform `terraform/platform/platform_acm.tf`). |
| `charts/acm-multicluster-hub/` | Helm chart: `MultiClusterHub` CR only (Terraform `terraform/platform/platform_acm.tf`). |
| `charts/acm-klusterlet-config/` | Helm chart: `KlusterletConfig` CR only (Terraform `terraform/platform/platform_acm.tf`). |
| `charts/acm-managed-cluster/` | Helm chart for a single spoke `ManagedCluster`; Terraform `terraform/platform/platform_acm_spokes.tf` installs one release per non-hub cluster. |
| `charts/openshift-gitops-operator/` | Helm chart: OLM Subscription for Red Hat OpenShift GitOps (Terraform `terraform/platform/platform_gitops.tf`). |
| `charts/acm-openshift-gitops-resources/` | Helm chart: ManagedClusterSetBinding, Placement, GitOpsCluster into GitOps namespace (Terraform `terraform/platform/platform_gitops.tf`). |
| `manifests/acm-gitops/` | Pointer README — ACM GitOps wiring lives in `charts/acm-openshift-gitops-resources`. |
| `terraform/rosa-hcp/` | Terraform root for ROSA Hosted Control Plane cluster provisioning (VPCs, clusters, worker pools, VPC peering). |
| `terraform/platform/` | Terraform root for ACM + OpenShift GitOps platform setup; reads rosa-hcp state via `terraform_remote_state`. |
| `propagation-test/` | Propagation latency test suite: numbered scripts (001-006) for setup, endpoint probe, config probe, metrics collection, reporting, and mesh-size sweep. See `propagation-test/README.md`. |
| `isotope-multicluster/` | [istio/tools isotope](https://github.com/istio/tools/tree/master/isotope) multicluster workload: chain graph from `terraform output cluster_keys`, per-cluster rendering and apply. See `isotope-multicluster/README.md`. |


## Conventions for edits

- Markdown: Do not use GFM bold (two asterisk characters immediately before and after a phrase) in repository Markdown (`README.md`, `AGENTS.md`, chart READMEs, and other checked-in `.md`). Prefer headings, plain wording, or inline code for emphasis; single-asterisk italics are acceptable when useful. When documentation must show glob syntax that contains consecutive asterisk characters, put it in backticks (for example `terraform/**/scripts/`) so it is not parsed as bold.
- Shell: Bash 4+; `set -euo pipefail` where already used.
- Contexts: Follow Script variables and naming; cluster names are placeholders — override via `SETUP_CONTEXTS` / `--contexts`.
- Paths: Helpers resolve repo root via `"$(cd "$(dirname "$0")/.." && pwd)"` from peer dirs (`isotope-multicluster/`, etc.) — adjust `..` depth for deeper subtrees; keep this pattern for new automation scripts.
- Secrets — never commit: Do not commit secrets, credentials, kubeconfigs with live tokens, private keys, CA material, API keys, or other sensitive values to git. Rely on `.gitignore` (e.g. `/cacerts/`, `/manifests/` at repo root) and local secret stores; use placeholders or templates for examples. If something might be secret, treat it as secret.
- READMEs: After each update, check each relevant README (`README.md` at repo root and under affected subtrees — e.g. `terraform/`, `isotope-multicluster/`) for necessary changes so commands, paths, prerequisites, and examples stay accurate. When you add or rename charts, change defaults, or move YAML, update those READMEs in the same change.

## Tools agents may assume

- `oc` / `kubectl`, `istioctl` (version aligned with `ISTIO_VERSION` / `spec.version` — see `config/versions.env`).
- `jq`, `curl` as documented in `README.md`.
- `git`, Helm 3 for charts under `charts/` and Terraform `helm_release` resources.

## References

- [OSSM 3.3 — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies) — primary reference for this repository.
- [OSSM 3.3 — Gateways — Installing a gateway using gateway injection](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/gateways/ossm-about-gateways#ossm-installing-gateway-using-gateway-injection_ossm-about-gateways) — Red Hat reference for north-south ingress gateway injection.

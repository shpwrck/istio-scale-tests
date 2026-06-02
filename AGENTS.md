# Agent instructions — istio-scale-tests

Project conventions and implementation rules for AI coding assistants. For human-oriented setup and commands, prefer `README.md`.

## Quick context

What is currently implemented:

1. ROSA HCP cluster provisioning via Terraform (`terraform/rosa-hcp/`)
2. ACM hub + GitOps wiring via Terraform (`terraform/platform/`)
3. Multi-primary, multi-network Istio mesh via GitOps (Helm charts under `charts/` synced by Argo CD ApplicationSets)
4. xDS propagation latency test suite (`tests/propagation/`)
5. Control-plane resource scaling test suite (`tests/controlplane/`)
6. Cross-cluster data-plane latency test suite (`tests/dataplane/`)
7. Churn/convergence test suite (`tests/churn/`)
8. Churn × data-plane co-execution test suite (`tests/churn-dataplane/`)
9. Performance tuning profile evaluation suite (`tests/tuning/`)

## Source of truth

Canonical procedures and command patterns for multi-cluster Service Mesh on OpenShift are:

[Red Hat OpenShift Service Mesh 3.3 — Installing — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies)

Base Helm charts and GitOps configuration on this documentation. When generic upstream Istio docs disagree with RH OSSM 3.3 guidance for this stack, prefer OSSM 3.3.

## Implementation rules

- No sensitive or identifying data in PRs, issues, commit messages, code comments, or any other public artifact (this is a top priority): Never paste a reporter's email, username, organization, real cluster/host names, IP addresses, account IDs, internal URLs, kubeconfig fragments, OpenShift / kubectl context strings, or any other identifier that could deanonymize a person or environment. When quoting an error message or log, **redact first** — replace identifiers with generic placeholders (`<user>`, `<api-host>`, `<account>`, `<TMPDIR>`, `<seconds>`) and strip surrounding context that re-identifies them. Applies equally to GitHub PR titles/bodies, issue comments, review replies, commit messages, and any artifact pushed to the repository. If unsure, ask the user before posting.
- No secrets in git: Never commit secrets, credentials, kubeconfigs with live tokens, private keys, CA material, or API keys. Rely on `.gitignore` (e.g. `/cacerts/` at repo root) and local secret stores; use placeholders or templates for examples.
- Mesh via GitOps: The mesh is deployed via Helm charts under `charts/`, synced by Argo CD ApplicationSets using ACM Placement. Do not add bash scripts for mesh installation — use Helm charts and Argo CD Applications instead.
- Numbered bash scripts: Name repo-owned executable bash helpers `NNN-kebab-case.sh` with a three-digit prefix (`001`, `002`, ...). The number reflects typical execution order within that directory (e.g. `propagation-test/001`-`002`). Use this pattern for all such scripts in `tests/propagation/`, `tests/controlplane/`, `tests/dataplane/`, `tests/churn/`, `terraform/**/scripts/` (when used), and future automation directories — never add unnumbered `*.sh` peers without renumbering the folder. When you add or renumber a script, update callers (e.g. Terraform `external`, other bash wrappers) and README / AGENTS references in the same change.
- Helm charts: Use Helm charts under `charts/` for all mesh resources, platform resources, and operator installations. Follow the established patterns (e.g. `spoke-ossm/`, `spoke-ingress-gateway/`, `hub-mesh-push-secrets/`).
- Avoid storing file content in scripts. Use templates appropriate for the situation (Helm charts under `charts/`, etc.) rather than large inline YAML or kubeconfig bodies in bash.
- --dry-run: Setup scripts that mutate clusters (`oc` / `kubectl` / `istioctl apply`) should accept `--dry-run` (typically `oc apply --dry-run=client`) so operators can validate renders without changing the cluster.
- Pinned versions: All version pins live in `config/versions.env` — do not duplicate version numbers elsewhere. Bump `README.md` when pins change.
- Markdown summary: All test suites must output a markdown summary file (`.md`) alongside raw TSV data so results are human-readable without post-processing. Sweep orchestrators should call the report script with `--format md` and write the output to the sweep results directory.

## Script variables and naming (bash)

Keep automation scripts consistent so operators can rely on the same env vars, flags, and internal names.

- Defaults: Scripts that use pinned versions or mesh-wide settings `source "${ROOT}/config/versions.env"` after setting `ROOT`. Put shared defaults (cluster lists, mesh/network IDs) in `config/versions.env` instead of copying literals into each script.
- Shared helpers: Source `"${ROOT}/tests/lib/common.sh"` (and optionally `timestamp.sh`, `preamble.sh`, `metrics.sh`) after `config/versions.env`. Do not inline functions that exist in the shared lib.
- Kubernetes contexts — environment: `SETUP_CONTEXTS` — comma-separated `kubectl` / `oc` context names (must match kubeconfig). Exported from `config/versions.env`.
- Kubernetes contexts — CLI: Where a script accepts multiple contexts, expose `--contexts CSV` using the same comma-separated format as `SETUP_CONTEXTS`.
- Internal names: Parse `--contexts` into `CONTEXTS_CSV` (string), then split into a bash array `CONTEXTS[@]`. Loop with `ctx` when calling `oc --context="$ctx"` / `kubectl --context="$ctx"`.
- Dry run: Internal `DRY_RUN` (`0`/`1`); user-facing `--dry-run`. Pair them consistently and mention both in `usage` when applicable.
- Repo root: From peer dirs, `ROOT="$(cd "$(dirname "$0")/.." && pwd)"`. Use the same depth pattern if you add scripts under subdirectories (adjust `..` segments).

## Purpose

Provide reproducible Istio scale testing across many dimensions — mesh size, workload complexity, xDS propagation, control-plane resource consumption — and across several cluster and infrastructure configurations (ROSA HCP today, other OpenShift targets in the future). The mesh is deployed via GitOps (Argo CD ApplicationSets) following [Red Hat OpenShift Service Mesh 3.3 multi-cluster documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies) so results are repeatable and infrastructure is declarative.

## Repository map

| Path | Use |
| ---- | --- |
| `config/versions.env` | Core version pins (`OPENSHIFT_VERSION`, `KUBERNETES_VERSION`, `ISTIO_VERSION`, `ACM_CHANNEL`, `GITOPS_OPERATOR_CHANNEL`), mesh identity (`MESH_ID`, `ACM_CLUSTER_SET`), and cluster contexts (`SETUP_CONTEXTS`). Sources `config/options.env` automatically. |
| `config/options.env` | Operational defaults: operator namespaces, GitOps config, mesh/logging defaults, AWS infra, and propagation/controlplane/dataplane test parameters. Sourced by `versions.env`; ACM/GitOps defaults are mirrored in `terraform/platform/variables.tf`. |
| `charts/spoke-ossm-operator/` | Helm chart: OLM Subscription for Sail operator on each spoke (ApplicationSet wave 8). |
| `charts/spoke-ossm/` | Helm chart: `Istio` + `IstioCNI` CRs per spoke cluster with per-cluster clusterName, network, meshID (wave 21). |
| `charts/spoke-ingress-gateway/` | Helm chart: north-south ingress gateway (LoadBalancer) per spoke — Deployment, Service, HPA, PDB, RBAC (wave 24). |
| `charts/spoke-east-west-gateway/` | Helm chart: east-west gateway + cross-network Gateway CR per spoke — TLS AUTO_PASSTHROUGH on port 15443 (wave 27). |
| `charts/hub-mesh-ca/` | Helm chart: cert-manager root CA + `ClusterIssuer` chain on the hub. |
| `charts/hub-mesh-ca-intermediate/` | Helm chart: one intermediate CA `Certificate` for a single `clusterName`. |
| `charts/hub-mesh-push-secrets/` | Helm chart: ESO PushSecrets pushing cacerts, kubeconfigs, and Istio remote secrets (with `istio/multiCluster` label) to spoke `istio-system` namespaces. |
| `charts/hub-kubeconfig-from-argosecret/` | Helm chart: `SecretStore` + `ExternalSecret` extracting kubeconfigs from Argo cluster secrets. |
| `charts/external-secrets-operator/` | Helm chart: OLM install for External Secrets Operator per spoke. |
| `charts/cert-manager-operator/` | Helm chart: OLM install for cert-manager Operator on the hub. |
| `charts/spoke-mesh-restart/` | Helm chart: restart Job (PostSync hook) for istiod and gateways after mesh GitOps sync completes (wave 30). |
| `charts/mesh-verify/` | Helm chart: standalone echo workload for multicluster mesh verification (not in root app-of-apps). |
| `charts/istiod-monitor/` | Helm chart: OpenShift User Workload Monitoring ServiceMonitor + PrometheusRule for istiod `pilot_*` metrics. |
| `charts/gitops-hub-ocm-placement-appset/` | Reusable Helm chart: Argo CD `ApplicationSet` for OCM Placement + RBAC; preset value files per component (e.g. `values-ossm.yaml`, `values-ingress-gateway.yaml`, `values-mesh-push-secrets.yaml`). |
| `charts/gitops-hub-app-of-apps/` | Helm chart: Argo CD `Application` CRs on the hub — `hub-gitops-root` (directory path `charts/gitops-hub-apps/applications` for child `Application` YAML) (Terraform `terraform/platform/platform_gitops.tf`). |
| `charts/gitops-hub-apps/` | Child hub `Application` manifests under `applications/` (directory-synced by `hub-gitops-root`). |
| `charts/acm-operator/` | Helm chart: OLM OperatorGroup + Subscription for ACM (Terraform `terraform/platform/platform_acm.tf`). |
| `charts/acm-multicluster-hub/` | Helm chart: `MultiClusterHub` CR only (Terraform `terraform/platform/platform_acm.tf`). |
| `charts/acm-klusterlet-config/` | Helm chart: `KlusterletConfig` CR only (Terraform `terraform/platform/platform_acm.tf`). |
| `charts/acm-managed-cluster/` | Helm chart for a single spoke `ManagedCluster`; Terraform `terraform/platform/platform_acm_spokes.tf` installs one release per non-hub cluster. |
| `charts/openshift-gitops-operator/` | Helm chart: OLM Subscription for Red Hat OpenShift GitOps (Terraform `terraform/platform/platform_gitops.tf`). |
| `charts/acm-openshift-gitops-resources/` | Helm chart: ManagedClusterSetBinding and Placement into GitOps namespace (Terraform `terraform/platform/platform_gitops.tf`). |
| `charts/argocd-config/` | Helm chart: ArgoCD custom resource configuration (requires OpenShift GitOps operator CRDs). |
| `terraform/rosa-hcp/` | Terraform root for ROSA Hosted Control Plane cluster provisioning (VPCs, clusters, worker pools, VPC peering). |
| `terraform/platform/` | Terraform root for ACM + OpenShift GitOps platform setup; reads rosa-hcp state via `terraform_remote_state`. |
| `tests/propagation/` | Propagation latency test suite: numbered scripts + `chart/` Helm chart for watcher/canary workloads. See `tests/propagation/README.md`. |
| `tests/controlplane/` | Control-plane resource scaling test suite: numbered scripts + `chart/` Helm chart for dummy services. See `tests/controlplane/README.md`. |
| `tests/dataplane/` | Data-plane latency test suite: numbered scripts + `chart/` Helm chart for fortio server/client. See `tests/dataplane/README.md`. |
| `tests/churn/` | Churn/convergence test suite: numbered scripts + `chart/` Helm chart for churn targets/watcher. See `tests/churn/README.md`. |
| `presentations/istio-mc-secrets/` | Self-contained reveal.js deck (~20 min) explaining how cert-manager + ESO + ACM produce and distribute the three Secrets (`cacerts`, per-spoke kubeconfigs, Istio remote secrets) that wire the multi-primary, multi-network mesh together. Open `index.html` in a browser. See `presentations/istio-mc-secrets/README.md`. |
| `tests/churn-dataplane/` | Churn × data-plane co-execution test suite: numbered scripts + composite `chart/` co-deploying fortio (server+client) and churn-target Pods in one shared namespace; emits `Δp99_ms` (latency delta under churn). See `tests/churn-dataplane/README.md`. |
| `tests/tuning/` | Performance tuning profile evaluation suite: applies Istio tuning profiles (Sidecar scoping, push throttling, xDS cache tuning, telemetry filtering, etc.) to the live mesh, runs existing test suite probes, and compares results across profiles. 15 profiles in 4 tiers with OSSM support annotations. See `tests/tuning/README.md`. |
| `tests/lib/` | Shared bash helper functions sourced by all test suites: `common.sh` (die, split_csv, validation), `timestamp.sh` (portable ns/ms timestamps), `preamble.sh` (harness metadata, TSV preamble), `metrics.sh` (Prometheus metric extraction). |
| `tests/lib/test/` | bats-core unit tests for shared helpers. Submodules: `bats-core/`, `bats-assert/`, `bats-support/`. Run with `tests/lib/test/bats-core/bin/bats tests/lib/test/*.bats`. |

## Common tasks

### Deploy the full mesh (Terraform + GitOps)

```bash
# Phase 1: Create ROSA clusters (terraform/rosa-hcp/)
cd terraform/rosa-hcp
export RHCS_TOKEN='...'
terraform init && terraform apply

# Get kubeconfig
terraform output -raw kubeconfig > ~/.kube/rosa-config
export KUBECONFIG=~/.kube/rosa-config

# Phase 2: Install ACM + GitOps + mesh (terraform/platform/)
cd ../platform
terraform init && terraform apply
```

### Verify the mesh

```bash
# Deploy mesh-verify test
oc apply -f charts/mesh-verify-appset.yaml

# Curl any cluster's ingress — should see responses from different clusters
INGRESS=$(oc get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
for i in {1..10}; do curl -s -H 'Host: mesh-verify.local' "http://$INGRESS/"; done

# Clean up
oc delete -f charts/mesh-verify-appset.yaml
```

### Update pinned versions

Edit `config/versions.env` (or `config/options.env` for operational defaults), then update:

- `README.md` (prerequisites, quick start examples)
- `AGENTS.md` (version references)
- `terraform/platform/variables.tf` defaults if the change affects Terraform-managed config

## Testing and verification

**Shared lib unit tests (bats-core):** Vendored as git submodules under `tests/lib/test/`. After cloning, run `git submodule update --init`. Run tests with `tests/lib/test/bats-core/bin/bats tests/lib/test/*.bats`.

**Pre-merge gate:** Changes to `tests/lib/*.sh` must pass `tests/lib/verify.sh` before merge. It runs syntax checks, shellcheck, inline-definition audits, bats tests, and optionally `--dry-run` sweeps. Use `--skip-dry-run` without cluster access.

**Manual mesh verification:**

- `charts/mesh-verify/` — standalone echo workload for cross-cluster load balancing verification
- `istioctl remote-clusters` — check istiod remote cluster discovery
- `istioctl proxy-config endpoints` — verify cross-cluster endpoint propagation

## Conventions for edits

- Shell: Bash 4+; `set -euo pipefail` where already used.
- Contexts: Follow Script variables and naming; cluster names are placeholders — override via `SETUP_CONTEXTS` / `--contexts`.
- Paths: Helpers resolve repo root via `"$(cd "$(dirname "$0")/../.." && pwd)"` from test dirs (`tests/propagation/`, etc.) — adjust `..` depth for deeper subtrees; keep this pattern for new automation scripts.
- READMEs: After each update, check each relevant README (`README.md` at repo root and under affected subtrees — e.g. `terraform/`, `tests/propagation/`) for necessary changes so commands, paths, prerequisites, and examples stay accurate. When you add or rename charts, change defaults, or move YAML, update those READMEs in the same change.

## Tools agents may assume

- `bash` 4+, `oc` or `kubectl`, `istioctl` (version aligned with `ISTIO_VERSION` — see `config/versions.env`)
- `terraform` (for `terraform/rosa-hcp/` and `terraform/platform/`)
- `helm` 3 (for charts under `charts/` and Terraform `helm_release` resources)
- `jq`, `curl`, `awk`

## Scale-test improvement cycle

For non-trivial changes to anything under `tests/` (a new sweep axis, a probe correctness fix, a new suite), invoke the 7-agent improvement cycle:

```
/scale-test-review <proposal description or existing branch name>
```

The cycle is one Implementer + six lens-specialized reviewers (Istio domain, measurement validity, repo conventions, usability, scale pragmatist, reproducibility). It iterates to consensus, then opens or updates a PR. See [`docs/scale-test-team/`](docs/scale-test-team/) for the full procedure and the carry-forward [process-learnings catalog](docs/scale-test-team/process-learnings.md) every implementer brief should preempt. The agents are defined under [`.claude/agents/`](.claude/agents/); the slash command is at [`.claude/commands/scale-test-review.md`](.claude/commands/scale-test-review.md).

## References

- [OSSM 3.3 — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies) — primary reference for this repository.
- [OSSM 3.3 — Gateways — Installing a gateway using gateway injection](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/gateways/ossm-about-gateways#ossm-installing-gateway-using-gateway-injection_ossm-about-gateways) — Red Hat reference for north-south ingress gateway injection.

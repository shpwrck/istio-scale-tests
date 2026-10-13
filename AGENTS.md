# Agent instructions — istio-scale-tests

Conventions and rules for coding agents. For setup and commands, see [README.md](README.md).

## What this repo is

1. `terraform/rosa-hcp/`: ROSA HCP cluster provisioning (optional).
2. `terraform/platform/`: ACM + OpenShift GitOps on the hub and spoke registration. Clusters come from
   ROSA state or an existing kubeconfig; brownfield switches reuse installed operators.
3. `charts/`: the multi-primary, multi-network mesh as Helm charts, synced by Argo CD
   ApplicationSets through ACM Placement.
4. `tests/`: six bash test suites (propagation, controlplane, dataplane, churn, churn-dataplane,
   tuning) plus a shared library in `tests/lib/`.

Source of truth for mesh procedures: [Red Hat OpenShift Service Mesh 3.4 — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.4/html/installing/ossm-multi-cluster-topologies).
Prefer it over generic upstream Istio docs when they disagree.

## Rules

- **No identifying data in public artifacts (top priority).** PRs, issues, commits, code and docs
  never contain real emails, usernames, cluster/host names, IPs, account IDs, internal URLs,
  kubeconfig fragments or context names. Redact logs first (`<api-host>`, `<account>`,
  `<mesh-a-ctx>`). If unsure, ask.
- **No secrets in git:** credentials, kubeconfigs, keys, CA material, tfvars, state and plan files
  stay out (`.gitignore` covers them). Use placeholders in examples.
- **Mesh via GitOps:** mesh, platform and operator resources are Helm charts under `charts/`, never
  install scripts. Per-environment differences go through `gitops_app_overrides` /
  `argocd_config_values`, not forks; chart defaults stay sized for the 20-cluster campaign.
- **Numbered scripts:** executable helpers in `tests/*/` and `terraform/*/scripts/` are named
  `NNN-kebab-case.sh` in execution order. When you add or renumber one, update every caller and
  README in the same change. Exception: `terraform/scripts/` holds helpers invoked by Terraform
  `local-exec`; keep their names (generated kubeconfigs reference them).
- **`--dry-run`:** scripts that change a cluster accept `--dry-run` and run it without a reachable
  cluster. Annotate with `# ci-dry-run: <args>` (or `# ci-dry-run-skip: <reason>`) so CI runs it.
- **Version pins:**
  - deployed Istio: `istioVersion` in `charts/spoke-ossm/values.yaml`; OSSM channel:
    `charts/spoke-ossm-operator/values.yaml`
  - ACM/GitOps channels: `terraform/platform/variables.tf`
  - test images and the `ISTIO_VERSION` recorded in results: `config/versions.env`, with a
    keep-in-sync comment next to each duplicated value (chart image tags, `istioVersion`).
- **Reports:** every suite writes a markdown summary next to its TSV data. Sweeps call their report
  script with `--format markdown`.

## Bash conventions

- `set -euo pipefail`. Repo root from a suite dir: `ROOT="$(cd "$(dirname "$0")/../.." && pwd)"`.
- Source `"${ROOT}/config/versions.env"` first (it sources `options.env`), then the `tests/lib/*.sh`
  you need. Don't re-implement lib functions; `tests/lib/verify.sh` audits for inline copies.
- Contexts: env `SETUP_CONTEXTS` and flag `--contexts CSV` list **mesh members only**, never the
  ACM hub. Parse into `CONTEXTS_CSV`, split into `CONTEXTS[@]`, loop with `ctx`.
- `DRY_RUN` (0/1) pairs with `--dry-run`; `--help` exits 0 and lists every flag the parser accepts.
- Tunables get defaults in `config/options.env` (one short comment each), not only inline.

## Repository map

| Path | Use |
| --- | --- |
| `config/versions.env`, `config/options.env` | Test image pins, `ISTIO_VERSION`, `SETUP_CONTEXTS`; suite defaults |
| `terraform/rosa-hcp/` | ROSA clusters; `scripts/001-preflight.sh` (account checks), `scripts/002-pre-destroy-vpc-cleanup.sh` |
| `terraform/platform/` | ACM, GitOps, spoke registration, app-of-apps, mesh-wiring gate; `scripts/001-openapi-preflight.sh` |
| `terraform/scripts/` | `local-exec` helpers (OAuth token, Argo cluster secrets, CSV and app cleanup on destroy) |
| `charts/gitops-hub-app-of-apps/` | Root Application `hub-gitops-root` (Helm source on `charts/gitops-hub-apps`) |
| `charts/gitops-hub-apps/` | Child Applications (repo URL/branch templated; `apps.<name>.enabled/values`) |
| `charts/gitops-hub-ocm-placement-appset/` | Reusable ApplicationSet + presets `values-*.yaml` |
| `charts/argocd-config/` | ArgoCD CR: sharding, resources, exclusions, Sail Istio/IstioCNI health checks |
| `charts/acm-*` | MultiClusterHub, KlusterletConfig, ManagedCluster, ClusterSet binding + Placement |
| `charts/cert-manager-operator/`, `charts/external-secrets-operator/` | Hub operators (OLM) |
| `charts/hub-mesh-ca/`, `charts/hub-mesh-ca-intermediate/` | Shared root CA and per-member intermediates |
| `charts/hub-kubeconfig-from-argosecret/`, `charts/hub-mesh-push-secrets/` | ESO: member kubeconfigs on the hub; push `cacerts` + Istio remote secrets |
| `charts/spoke-istio-namespaces/`, `charts/spoke-ossm-operator/`, `charts/spoke-ossm/` | Member namespaces, Sail operator, Istio/IstioCNI (waits for `cacerts`) + tuning baseline |
| `charts/spoke-ingress-gateway/`, `charts/spoke-east-west-gateway/` | Member gateways |
| `charts/mesh-wiring-verify/` | Always-on gate per member (remote secrets, istiod ingestion, shared root) |
| `charts/mesh-verify/`, `charts/mesh-verify-appset.yaml` | On-demand cross-cluster echo check |
| `charts/istiod-monitor/` | Optional ServiceMonitor + recording rules for istiod |
| `tests/<suite>/` | Numbered scripts + `chart/`; see each suite README |
| `tests/tuning/profiles/` | Four profiles that each change something vs the chart's tuning baseline |
| `tests/lib/` | `common.sh`, `timestamp.sh`, `preamble.sh`, `metrics.sh`, `fanout.sh`, `capacity.sh`, `envelope.sh`, `lint-bare-scrape.sh`, `verify.sh`, `fortio.sh`, `reach.sh`; bats tests in `test/` |
| `docs/scale-test-campaign/`, `docs/campaigns/` | Campaign runbook; recorded results |
| `docs/scale-test-team/` | The `/scale-test-review` cycle and the process-learnings (PL) catalog |
| `docs/runbooks/` | Leave-behind runbooks for deployed environments |

## Testing and verification

- `git submodule update --init`, then `tests/lib/verify.sh`: syntax, shellcheck, inline-copy
  audit, bats, and every `# ci-dry-run:` script against an empty kubeconfig (no cluster needed).
  Required before merging changes to `tests/lib/`.
- Charts: `helm lint` / `helm template` each touched chart with its presets
  (`charts/gitops-hub-apps` needs `--set repo.url=<url>`).
- Terraform: `terraform fmt -check -recursive` and `terraform validate` in both roots.
- CI (`.github/workflows/portability.yml`) runs all of the above on Linux, plus portability checks on
  macOS. The job names are required checks; don't rename them.
- Live: deploy, then check that every hub Application is Synced/Healthy, the `mesh-wiring-verify`
  gate is Ready (`ca=shared`), and mesh-verify answers from every member (README "Verify").

## Tools

`bash` 4+, `oc` and `kubectl`, `terraform` >= 1.14.8, `helm` 3 or 4, `jq`, `curl`, `awk`,
`istioctl` matching `ISTIO_VERSION`, `python3` + PyYAML (tuning suite), `aws` + `rosa` (ROSA only).

## Scale-test improvement cycle

For non-trivial changes under `tests/`, run `/scale-test-review <proposal or branch>`: one
implementer plus six lens reviewers, iterated to consensus. See
[docs/scale-test-team/](docs/scale-test-team/README.md); agents are in `.claude/agents/`.

# Claude Code Guide — istio-scale-tests

This repository automates multi-cluster Istio (Red Hat OpenShift Service Mesh 3.3) deployments on OpenShift. For comprehensive implementation rules, conventions, and repository structure, see **[AGENTS.md](AGENTS.md)**.

## Quick Context

**What this repo does:**
1. Provisions ROSA HCP clusters via Terraform (`terraform/rosa-hcp/`)
2. Installs ACM hub + GitOps wiring via Terraform (`terraform/platform/`)
3. Deploys multi-primary, multi-network Istio mesh via GitOps (Helm charts under `charts/` synced by Argo CD ApplicationSets)
4. Deploys multicluster load test workloads (`isotope-multicluster/`)

**Source of truth:** [Red Hat OSSM 3.3 — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies)

## Working in This Repo

### Configuration & Versions

All pinned versions and environment variables live in **`config/versions.env`** — always source this file in scripts. Current pins:
- OpenShift 4.21.11, Kubernetes v1.34.6, Istio v1.28.5
- RHACM 2.16, OpenShift GitOps 1.14

### Helm Charts

The mesh is deployed via Helm charts under `charts/`, synced by Argo CD ApplicationSets using ACM Placement to target spoke clusters. Key charts:

- `spoke-istio/` — Istio + IstioCNI CRs per spoke
- `spoke-ingress-gateway/` — North-south ingress gateway per spoke
- `spoke-east-west-gateway/` — East-west gateway + cross-network Gateway CR per spoke
- `hub-mesh-push-secrets/` — ESO PushSecrets for cacerts, kubeconfigs, and Istio remote secrets
- `gitops-hub-ocm-placement-appset/` — Reusable ApplicationSet chart with preset value files

### Script Conventions

Automation scripts are **numbered bash** (`NNN-kebab-case.sh`) reflecting execution order:
- `isotope-multicluster/001-002`: Load test workload generation and application
- `terraform/scripts/`: Helper scripts for Terraform providers

**Every script must:**
- Use `#!/usr/bin/env bash` + `set -euo pipefail`
- Source `"${ROOT}/config/versions.env"` after setting `ROOT="$(cd "$(dirname "$0")/.." && pwd)"`
- Accept `--dry-run` flag for mutations (`oc apply --dry-run=client`)
- Provide usage with examples via `usage()` function

**When adding scripts:** renumber the entire directory if needed — no unnumbered `*.sh` peers allowed. Update callers and READMEs in the same commit.

### Templates vs. Helm

- **Mesh resources:** Use Helm charts under `charts/` (deployed via Argo CD ApplicationSets)
- **Platform resources:** Use Helm charts under `charts/` (ACM, GitOps, ingress gateway)
- Never inline large YAML blocks in bash scripts

### Testing & Verification

**No CI/test framework configured.** Manual verification via:
- `charts/mesh-verify/` — standalone echo workload for cross-cluster load balancing verification
- `istioctl remote-clusters` — check istiod remote cluster discovery
- `istioctl proxy-config endpoints` — verify cross-cluster endpoint propagation

### Git & Secrets

**Never commit:**
- Secrets, credentials, CA material (`/cacerts/` is gitignored)
- Kubeconfigs with live tokens
- Terraform state (`*.tfstate`, `terraform.tfvars`)
- Environment-specific manifests (`/manifests/` at repo root)

Use `.gitignore` patterns and local secret stores.

**Worktrees:** This repo uses `.worktrees/` for isolated checkouts (gitignored).

## Common Tasks

### Deploy the Full Mesh (Terraform + GitOps)

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

### Verify the Mesh

```bash
# Deploy mesh-verify test
oc apply -f charts/mesh-verify-appset.yaml

# Curl any cluster's ingress — should see responses from different clusters
INGRESS=$(oc get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
for i in {1..10}; do curl -s -H 'Host: mesh-verify.local' "http://$INGRESS/"; done

# Clean up
oc delete -f charts/mesh-verify-appset.yaml
```

### Update Pinned Versions

Edit `config/versions.env`, then update:
- `README.md` (prerequisites, quick start examples)
- `AGENTS.md` (version references)
- Chart dependencies if applicable (e.g., `ISTIO_GATEWAY_CHART_VERSION`)

## Tools Required

From `config/versions.env` and AGENTS.md:
- `bash` 4+, `oc` or `kubectl`, `istioctl` (version-aligned with `ISTIO_VERSION`)
- `terraform` (for `terraform/rosa-hcp/`)
- `helm` 3 (for platform charts)
- `jq`, `curl`
- Optional: `go` (for isotope multicluster workload generation)

## Reference Docs

- **AGENTS.md** — comprehensive implementation rules, variable naming, repository map
- **README.md** — end-user quickstart, step-by-step procedures
- **terraform/rosa-hcp/README.md** — cluster provisioning details
- **isotope-multicluster/README.md** — load test workload setup

## For Claude Code

When making changes:
1. Read AGENTS.md for implementation rules
2. Update READMEs when adding/renaming charts or scripts
3. Use templates, not inline YAML
4. Provide `--dry-run` for mutations in scripts
5. Follow Helm chart patterns established in existing charts under `charts/`

Permissions configured in `.claude/settings.json` allow common read-only operations without prompts.

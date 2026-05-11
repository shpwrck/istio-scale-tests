# Claude Code Guide — istio-scale-tests

This repository automates multi-cluster Istio (Red Hat OpenShift Service Mesh 3.3) deployments on OpenShift. For comprehensive implementation rules, conventions, and repository structure, see **[AGENTS.md](AGENTS.md)**.

## Quick Context

**What this repo does:**
1. Provisions ROSA HCP clusters via Terraform (`terraform/rosa-hcp/`)
2. Optional: ACM hub + GitOps wiring via Terraform (`terraform/rosa-hcp/`, `enable_platform_setup = true`)
3. Installs multi-primary, multi-network Istio mesh using Sail operator (`istio-setup/` 001–009)
4. Deploys multicluster load test workloads (`isotope-multicluster/`)

**Source of truth:** [Red Hat OSSM 3.3 — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies)

## Working in This Repo

### Configuration & Versions

All pinned versions and environment variables live in **`config/versions.env`** — always source this file in scripts. Current pins:
- OpenShift 4.21.11, Kubernetes v1.34.6, Istio v1.28.5
- RHACM 2.16, OpenShift GitOps 1.14

### Script Conventions

Automation scripts are **numbered bash** (`NNN-kebab-case.sh`) reflecting execution order:
- `istio-setup/001-009`: Mesh install + verification

**Every mesh script must:**
- Use `#!/usr/bin/env bash` + `set -euo pipefail`
- Source `"${ROOT}/config/versions.env"` after setting `ROOT="$(cd "$(dirname "$0")/.." && pwd)"`
- Accept `--contexts CSV` flag (comma-separated kube context names, defaults to `SETUP_CONTEXTS`)
- Accept `--dry-run` flag for mutations (`oc apply --dry-run=client`)
- Provide usage with examples via `usage()` function

**When adding scripts:** renumber the entire directory if needed — no unnumbered `*.sh` peers allowed. Update callers and READMEs in the same commit.

### Templates vs. Helm

- **Mesh resources:** Use `manifests/ossm-multi-cluster/templates/*.yaml.tpl` + `envsubst` (variables from `config/versions.env`)
- **Platform resources:** Use Helm charts under `charts/` (ACM, GitOps, ingress gateway)
- Never inline large YAML blocks in bash scripts

### Testing & Verification

**No CI/test framework configured.** Manual verification via:
- `istio-setup/008-ossm-mc-verify-east-west.sh` — proxy-status, endpoints, istiod health
- `istio-setup/009-ossm-mc-verify-ingress-gateway.sh --cleanup` — ingress smoke test

Shellcheck directives are inline (no `.shellcheckrc`).

### Git & Secrets

**Never commit:**
- Secrets, credentials, CA material (`/cacerts/` is gitignored)
- Kubeconfigs with live tokens
- Terraform state (`*.tfstate`, `terraform.tfvars`)
- Environment-specific manifests (`/manifests/` at repo root)

Use `.gitignore` patterns and local secret stores.

**Worktrees:** This repo uses `.worktrees/` for isolated checkouts (gitignored).

## Common Tasks

### Run a Mesh Install End-to-End

From repo root with contexts `rosa-001,rosa-002,rosa-003`:

```bash
export SETUP_CONTEXTS=rosa-001,rosa-002,rosa-003
source config/versions.env

# CA + Istio CRs + ingress
./istio-setup/001-ossm-mc-cacerts.sh generate --base "$PWD" --clusters "$SETUP_CONTEXTS"
./istio-setup/001-ossm-mc-cacerts.sh apply --base "$PWD" \
  --context-map 'rosa-001:rosa-001,rosa-002:rosa-002,rosa-003:rosa-003' \
  --replace --network-suffix network
./istio-setup/003-ossm-mc-apply-istio.sh
./istio-setup/004-ossm-mc-apply-ingress-gateway.sh

# Remote secrets + east-west gateways
PATH="$PWD/.bin:$PATH" ./istio-setup/005-ossm-mc-remote-secrets.sh
./istio-setup/007-ossm-mc-apply-east-west.sh
PATH="$PWD/.bin:$PATH" ./istio-setup/008-ossm-mc-verify-east-west.sh
```

### Provision Clusters + ACM + GitOps (Terraform)

See `terraform/rosa-hcp/README.md`. Two-phase apply:
1. Set `RHCS_TOKEN`, `cluster_count`, `openshift_version` in variables or env
2. `terraform init && terraform apply` — creates ROSA clusters
3. Set `enable_platform_setup = true`, `terraform apply` — installs ACM + GitOps on the hub
4. Log in with `oc login` per cluster using `terraform output cluster_admin_login`

### Update Pinned Versions

Edit `config/versions.env`, then update:
- `README.md` (prerequisites, quick start examples)
- `AGENTS.md` (line 21 version references)
- Chart dependencies if applicable (e.g., `ISTIO_GATEWAY_CHART_VERSION`)

## Tools Required

From `config/versions.env` and AGENTS.md:
- `bash` 4+, `oc` or `kubectl`, `istioctl` (version-aligned with `ISTIO_VERSION`)
- `terraform` (for `terraform/rosa-hcp/`)
- `helm` 3 (for platform charts and ingress gateway)
- `openssl`, `jq`, `curl`, `envsubst` (gettext)
- Optional: `go` (for isotope multicluster workload generation)

## Reference Docs

- **AGENTS.md** — comprehensive implementation rules, variable naming, repository map
- **README.md** — end-user quickstart, step-by-step procedures
- **terraform/rosa-hcp/README.md** — cluster provisioning details
- **isotope-multicluster/README.md** — load test workload setup

## For Claude Code

When making changes:
1. Read AGENTS.md lines 13–36 for implementation rules
2. Follow script variable naming (lines 24–36): `SETUP_CONTEXTS`, `--contexts`, internal `CONTEXTS[@]`
3. Update READMEs when adding/renaming scripts (convention line 80)
4. Maintain numbered script sequence (line 17)
5. Use templates, not inline YAML (line 18)
6. Provide `--dry-run` for mutations (line 20)

Permissions configured in `.claude/settings.json` allow common read-only operations without prompts.

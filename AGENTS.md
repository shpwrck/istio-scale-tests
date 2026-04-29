# Agent instructions — istio-scale-tests

Use this file with Cursor agents working in this repository. For human-oriented setup and commands, prefer `**README.md**`.

## Source of truth

**Canonical procedures and command patterns** for multi-cluster Service Mesh on OpenShift are:

**[Red Hat OpenShift Service Mesh 3.3 — Installing — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies)**

Base logic in `**setup-scripts/`** (and related manifests) on this documentation. When generic upstream Istio docs disagree with RH OSSM 3.3 guidance for this stack, prefer **OSSM 3.3**.

## Implementation rules

- **No secrets in git:** Never add commits that contain secrets or credentials (see **Conventions for edits**).
- **Shell only:** Mesh setup and repo automation use `**bash`** under `**setup-scripts/`**. Do not add Python, Ruby, or other runtimes for install or wiring unless the user explicitly requests it.
- **Templates:** Prefer `**manifests/ossm-multi-cluster/templates/*.yaml.tpl`** with `**envsubst`** and variables from `**config/versions.env`** instead of duplicating per-cluster static YAML. Shared non-templated snippets may remain under `**east-west/common/`** when appropriate.
- `**--dry-run`:** Setup scripts that mutate clusters (`**oc`** / `**kubectl`** / `**istioctl apply`**) should accept `**--dry-run`** (typically `**oc apply --dry-run=client**`) so operators can validate renders without changing the cluster. Purely read-only scripts may treat `**--dry-run**` as documented no-op.
- **Pinned versions:** Maintain a single pin list in `**config/versions.env`**. Current targets: OpenShift 4.18.38, Kubernetes v1.31.14, Istio / Sail `spec.version` v1.28.5 (match `**istioctl`**). Bump `**README.md**` when pins change.
- **Script variables:** Expose and name env vars, flags, and bash identifiers consistently across `**setup-scripts/`** — see **Script variables and naming** (especially `**SETUP_CONTEXTS`**, `**--contexts`**, `**CONTEXTS**` / `**DRY_RUN**`).

## Script variables and naming (bash)

Keep `**setup-scripts/**` consistent so operators can rely on the same env vars, flags, and internal names across scripts.

- **Defaults:** Scripts that use pinned versions or mesh-wide settings `**source "${ROOT}/config/versions.env"`** after setting `**ROOT`**. Put shared defaults (cluster lists, mesh/network IDs) in `**config/versions.env**` instead of copying literals into each script.
- **Kubernetes contexts — environment:** `**SETUP_CONTEXTS`** — comma-separated `**kubectl` / `oc` context names** (must match kubeconfig). Exported from `**config/versions.env`**. These names usually double as Istio primary-remote identifiers when they match `**istioctl create-remote-secret --name`**.
- **Kubernetes contexts — CLI:** Where a script accepts multiple contexts, expose `**--contexts CSV`** using the **same** comma-separated format as `**SETUP_CONTEXTS`**. Scripts that take contexts positionally must still document defaults tied to `**SETUP_CONTEXTS`** in `**usage**` (and an `**Environment:**` block listing `**SETUP_CONTEXTS**` and any script-specific vars).
- **Internal names:** Parse `**--contexts`** into `**CONTEXTS_CSV`** (string), then split into a bash array `**CONTEXTS[@]**`. Loop with `**ctx**` when calling `**oc --context="$ctx"**` / `**kubectl --context="$ctx"**`. Prefer `**CONTEXTS**` for these arrays in **new or substantially edited** scripts; some older scripts use `**CLUSTERS=(...)`** — treat as the **same** meaning (kube context names, not AWS/GCP cluster IDs).
- **Dry run:** Internal `**DRY_RUN`** (`0`/`1`); user-facing `**--dry-run`**. Pair them consistently and mention both in `**usage**` when applicable.
- **Repo root:** From `**setup-scripts/`**, `**ROOT="$(cd "$(dirname "$0")/.." && pwd)"`**. Use the same depth pattern if you add scripts under subdirectories of `**setup-scripts/**` (adjust `**..**` segments).
- **Templates (`envsubst`):** Per-context exports must stay aligned with template names already in `**manifests/ossm-multi-cluster/templates/`** (e.g. `**CLUSTER_KEY`**, `**NETWORK**` / `**NETWORK_SUFFIX**` from `**versions.env**`).
- **Per-context AWS env overrides:** Follow `**config/versions.env`**: variables such as `**AWS_LOAD_BALANCER_*_<CONTEXT_SUFFIX>`** where `**CONTEXT_SUFFIX**` is the kube context name uppercased with `**/**`, `**:**`, `**-**` replaced by `**_**` (example: `**rosa-001**` → `**ROSA_001**`).
- **Exception — 00-ossm-mc-cacerts.sh:** Uses `**--clusters CSV`** for **logical cluster keys** (directory names under `**cacerts/`**) and optional `**--context-map key:ctx,...`** when keys differ from kube context names. When keys match context names, keep `**--clusters**` aligned with `**SETUP_CONTEXTS**`.

## Purpose

This repository exists so operators can **end-to-end**: provision **ROSA** clusters (or equivalent OpenShift targets), **install multi-cluster Istio / OSSM** on them following **[Red Hat OpenShift Service Mesh multi-cluster documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies)** (multi-primary, multi-network meshes using the **Sail operator** — `Istio`, `IstioCNI`), **load dynamic scale tests** into those clusters, and **produce reports** from the runs. Automation and manifests focus on that workflow rather than ad-hoc manual installs only.

## Repository map


| Path                                          | Use                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `**config/versions.env`**                     | Pinned `**OPENSHIFT_VERSION`**, `**KUBERNETES_VERSION`**, `**ISTIO_VERSION**`, `**ACCESS_LOG_FILE**` / `**ACCESS_LOG_ENCODING**` (mesh Envoy access logs in `**istio.cluster.yaml.tpl**`), `**ISTIO_GATEWAY_CHART_VERSION**` / `**ISTIO_HELM_REPO_URL**` (official `**istio/gateway**` Helm chart), optional `**AWS_LOAD_BALANCER_*_SECURITY_GROUPS**` (ingress LB on AWS/ROSA), `**SETUP_CONTEXTS**` (comma-separated kube contexts), mesh/network defaults; `**OSSM_DOC_MULTI_CLUSTER_URL**`. Sourced by `**setup-scripts**`. |
| `**setup-scripts/**`                          | Numbered `**00`–`08**` bash scripts — mesh CA, kubeconfig CA prep, templated Istio CRs, Helm ingress gateway (`**03**`), remote secrets, optional insecure API fallback, east–west gateways, verification (`**07**`), optional ingress smoke test (`**08**`). Run from **repo root**; order matters.                                                                                                                                                                                                                            |
| `**manifests/ossm-multi-cluster/templates/`** | `***.yaml.tpl`** for `**Istio`**, `**IstioCNI`**, east–west gateway; rendered by `**02**` / `**06**` (`**03**` uses Helm `istio/gateway`, not `envsubst`).                                                                                                                                                                                                                                                                                                                                                                      |
| `**manifests/ossm-multi-cluster/**`           | `**east-west/common/**`, `**samples/**`, cluster placeholder dirs — see READMEs under each subtree.                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `**cacerts/**`                                | Generated plug-in CA material (from `**setup-scripts/00-ossm-mc-cacerts.sh**`). Treat as sensitive.                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `**terraform/rosa-hcp/**`                     | Optional Terraform root for **ROSA Hosted Control Plane** clusters via upstream `**terraform-redhat/rosa-hcp/rhcs`** — see `**terraform/rosa-hcp/README.md`**. Mesh install remains under `**setup-scripts/`**.                                                                                                                                                                                                                                                                                                                 |


## Conventions for edits

- **Shell:** Bash 4+; `**set -euo pipefail`** where already used; match existing style in `**setup-scripts/`**.
- **Contexts:** Follow **Script variables and naming**; `**rosa-001`**, `**rosa-002`**, `**rosa-003**` are placeholders—override via `**SETUP_CONTEXTS**` / `**--contexts**`.
- **Paths:** Helpers resolve repo root via `"$(cd "$(dirname "$0")/.." && pwd)"` from `**setup-scripts/`** — keep that pattern if you add sibling scripts.
- **Secrets — never commit:** Do **not** commit secrets, credentials, kubeconfigs with live tokens, private keys, CA material, API keys, or other sensitive values to git. Rely on `**.gitignore`** (e.g. `**/cacerts/`**, `**/manifests/`**) and local secret stores; use placeholders or templates for examples. If something might be secret, treat it as secret.
- **READMEs:** After each update, check **each** relevant README (`**README.md`** at repo root and under affected subtrees—e.g. `**setup-scripts/`**, `**manifests/`**, `**terraform/**`) for necessary changes so commands, paths, prerequisites, and examples stay accurate. When you add or rename setup scripts, change defaults, or move YAML, update those READMEs in the same change.

## Tools agents may assume

- `**oc`** / `**kubectl`**, `**istioctl`** (version aligned with `**ISTIO_VERSION**` / `**spec.version**` in templates — see `**config/versions.env**`).
- `**openssl**`, `**jq**`, `**curl**` for setup scripts as documented in `**README.md**`.
- `**envsubst**` (gettext package) for template rendering in `**02**` and `**06**`.
- `**git**`, **Helm 3** for `**setup-scripts/03-ossm-mc-apply-ingress-gateway.sh`** (`**istio/gateway`** chart).

## References

- [OSSM 3.3 — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-multi-cluster-topologies) — primary reference for this repository.
- [OSSM 3.3 — Gateways — Installing a gateway using gateway injection](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/gateways/ossm-about-gateways#ossm-installing-gateway-using-gateway-injection_ossm-about-gateways) — Red Hat reference for north–south ingress (`istio/gateway`, `**setup-scripts/03-ossm-mc-apply-ingress-gateway.sh`**, related `**ingress-verify`** checks).
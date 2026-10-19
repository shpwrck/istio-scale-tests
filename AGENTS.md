# Agent instructions — istio-scale-tests

Conventions and rules for coding agents. For setup and commands, see [README.md](README.md).

## What this repo is

1. `terraform/rosa-hcp/`: ROSA HCP cluster provisioning (optional).
2. `terraform/platform/`: ACM + OpenShift GitOps on the hub and spoke registration. Clusters come from
   ROSA state or an existing kubeconfig; brownfield switches reuse installed operators.
3. `charts/`: the multi-primary, multi-network mesh as Helm charts, synced by Argo CD
   ApplicationSets (members by cluster-Secret label on Kubernetes, by ACM Placement on OpenShift).
4. `tests/`: seven bash test suites (propagation, controlplane, dataplane, churn, churn-dataplane,
   tuning, and the read-only gateway-api check) plus a shared library in `tests/lib/`.

The default platform is vanilla Kubernetes (`platform = "kubernetes"`): upstream Argo CD (Helm),
members registered as Argo CD cluster Secrets and selected by the label `istio-mesh-member=true`,
and the upstream cert-manager, External Secrets and Sail operator charts. It is tested on kind
([docs/runbooks/kind-lab](docs/runbooks/kind-lab/README.md)). OpenShift (`platform = "openshift"`)
is an optional, untested profile: ROSA, ACM, OpenShift GitOps, ACM Placement and OSSM through OLM
belong to it only. Keep both working: a chart that differs by platform gets a
`values-openshift.yaml` overlay (member charts, suite charts) or a `platform-*.yaml` overlay (the
ApplicationSet chart, whose `values-*.yaml` are the per-component presets), and Kubernetes stays
the default. Every repo chart an ApplicationSet deploys has a `values-openshift.yaml` (`{}` when
nothing differs), since its OpenShift Applications list it (`tests/lib/test/chart-platforms.bats`
checks). The suites add their chart's overlay when a member serves OpenShift's API groups
(`tests/lib/platform.sh`; `TEST_PLATFORM` overrides the detection).

Source of truth for mesh procedures: on Kubernetes, the [Sail operator multicluster docs](https://github.com/istio-ecosystem/sail-operator/blob/main/docs/deployment-models/multicluster.adoc)
and upstream Istio's [multi-primary on different networks](https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/);
on OpenShift, [Red Hat OpenShift Service Mesh 3.4 — Multi-cluster topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.4/html/installing/ossm-multi-cluster-topologies),
which wins over the upstream docs there when they disagree.

## Rules

- **No identifying data in public artifacts (top priority).** PRs, issues, commits, code and docs
  never contain real emails, usernames, cluster/host names, IPs, account IDs, internal URLs,
  kubeconfig fragments or context names. Redact logs first (`<api-host>`, `<account>`,
  `<mesh-a-ctx>`). If unsure, ask.
- **No secrets in git:** credentials, kubeconfigs, keys, CA material, tfvars, state and plan files
  stay out (`.gitignore` covers them). Use placeholders in examples.
- **Mesh via GitOps:** mesh, platform and operator resources are Helm charts under `charts/`, never
  install scripts. Per-environment differences go through `gitops_app_overrides` /
  `argocd_helm_values` (`argocd_config_values` on OpenShift), not forks; chart defaults stay sized
  for the 20-cluster campaign.
- **Numbered scripts:** executable helpers in `tests/*/` and `terraform/*/scripts/` are named
  `NNN-kebab-case.sh` in execution order. When you add or renumber one, update every caller and
  README in the same change. Exception: `terraform/scripts/` holds helpers invoked by Terraform
  `local-exec`; keep their names (generated kubeconfigs reference them).
- **`--dry-run`:** scripts that change a cluster accept `--dry-run` and run it without a reachable
  cluster. Annotate with `# ci-dry-run: <args>` (or `# ci-dry-run-skip: <reason>`) so CI runs it.
  Exempt: the `terraform/scripts/` `local-exec` helpers. Terraform runs them, so `terraform plan`
  is their dry run; test them with bats against a stub `kubectl` (`tests/lib/test/argocd-*.bats`).
  The member's bootstrap credential (`create-argocd-cluster-secret.sh`) stays in that script, not
  a chart: Argo CD needs it before it can reach the member.
- **Version pins:**
  - deployed Istio: `istioVersion` in `charts/spoke-ossm/values.yaml`; Sail operator chart:
    `charts/gitops-hub-ocm-placement-appset/values-sail-operator.yaml` (it must list
    `istioVersion`); External Secrets chart: `values-external-secrets.yaml` there; cert-manager
    chart: `charts/gitops-hub-apps/values.yaml`; Argo CD chart: `argocd_chart_version` in
    `terraform/platform/variables.tf`; OSSM channel (OpenShift): `charts/spoke-ossm-operator/values.yaml`
  - the curl image of the wiring gate and the wait Jobs (`docker.io/curlimages/curl`):
    `charts/mesh-wiring-verify/values.yaml`, `waitForCacerts.image` in `charts/spoke-ossm/values.yaml`
    and both gateways' `waitForIstiod.image`, each with a keep-in-sync comment naming the others
    (`charts/spoke-east-west-gateway/README.md` repeats it)
  - ACM/GitOps channels: `terraform/platform/variables.tf`
  - test images and the `ISTIO_VERSION` recorded in results: `config/versions.env`, with a
    keep-in-sync comment next to each duplicated value (chart image tags, `istioVersion`).
- **Reports:** every suite writes a markdown summary next to its TSV data. Sweeps call their report
  script with `--format markdown`.

## Bash conventions

- `set -euo pipefail`. Repo root from a suite dir: `ROOT="$(cd "$(dirname "$0")/../.." && pwd)"`.
- Source `"${ROOT}/config/versions.env"` first (it sources `options.env`), then the `tests/lib/*.sh`
  you need. Don't re-implement lib functions; `tests/lib/verify.sh` audits for inline copies.
- Exception, scripts that take `--config FILE` (every suite but tuning): source `tests/lib/common.sh`
  and `tests/lib/config.sh`, call `config_preload <suite> "$@"`, then source `versions.env` (or
  `options.env`) and the other libs (`fanout.sh` reads its defaults when sourced). The
  file's values must be in the environment before `options.env` fills in (and derives) defaults.
  Precedence is flag > `--config` > env > default; `tests/lib/test/config.bats` checks the order.
- Contexts: env `SETUP_CONTEXTS` and flag `--contexts CSV` list **mesh members only**, never the
  ACM hub. Parse into `CONTEXTS_CSV`, split into `CONTEXTS[@]`, loop with `ctx`.
- `DRY_RUN` (0/1) pairs with `--dry-run`; `--help` exits 0 and lists every flag the parser accepts.
- Tunables get defaults in `config/options.env` (one short comment each), not only inline. A flag
  that shapes a run needs such a key, read before the flag parser: the `--config` vocabulary is the
  `options.env` exports matching the suite's key list (`config_suite_prefixes`), so the key also
  makes it config-settable. A sweep axis gets a plural CSV key that falls back to the singular one.
- Platform record: every TSV writer and placeholder calls `platform_probe` before any window and
  writes `platform_preamble_lines` next to `config_preamble_lines`; a run's markdown summary adds
  `platform_md_row` after its `| Run config |` row; every suite report merges the record over its
  inputs with `platform_report_values` and prints `platform_report_warnings` in every format's body
  (tuning 004 compares each pass's record with the reference pass's, the baseline's or else the
  first pass with data's, over `PLATFORM_PASS_KEYS`, every record key but `ISTIOD_ENV_BY_CONTEXT`
  and `TUNING_OBJECTS_BY_CONTEXT`, which a profile changes and its `istiod env` and `Tuning objects`
  rows show per pass, in its `Platform record` row and notes instead); a suite's sweep calls
  `platform_probe_share` right after its `platform_probe` (controlplane: after its `--resume`
  check), then `platform_start_warnings`, and `platform_drift_check` after its last step, before
  its reports (tuning 003 refuses to start on a profile's objects with
  `platform_tuning_objects_refuse` instead of warning, and since a profile changes the record, each
  pass calls `platform_probe_reset`, `platform_probe` and `platform_probe_share` before its probes
  and `platform_drift_check` after them; 004 compares the passes); every script that sources
  `platform.sh` calls `platform_validate` with its argument checks (`tests/lib/platform.sh`;
  `tests/lib/test/config-suites.bats` and `platform.bats` check the pairing). `TEST_PLATFORM`,
  `PLATFORM_READ_TIMEOUT` and `PLATFORM_READ_PARALLEL` are keys of
  every suite (`CONFIG_SHARED_PREFIXES`, `tests/lib/config.sh`).

## Repository map

| Path | Use |
| --- | --- |
| `config/versions.env`, `config/options.env` | Test image pins, `ISTIO_VERSION`, `SETUP_CONTEXTS`; suite defaults |
| `terraform/rosa-hcp/` | ROSA clusters; `scripts/001-preflight.sh` (account checks), `scripts/002-pre-destroy-vpc-cleanup.sh` |
| `terraform/platform/` | Argo CD (ACM and OpenShift GitOps on OpenShift), spoke registration, app-of-apps, mesh-wiring gate; `scripts/001-openapi-preflight.sh` (OpenShift hubs) |
| `terraform/scripts/` | `local-exec` helpers (OAuth token, Argo cluster secrets, CSV and app cleanup on destroy; `argocd-controller-reshard.sh`: the OpenShift controller restart and the apply's Application status check) |
| `charts/gitops-hub-app-of-apps/` | Root Application `hub-gitops-root` (Helm source on `charts/gitops-hub-apps`) |
| `charts/gitops-hub-apps/` | Child Applications (repo URL/branch templated; `apps.<name>.enabled/values`) |
| `charts/gitops-hub-ocm-placement-appset/` | Reusable ApplicationSet + presets `values-*.yaml` + platform overlays `platform-*.yaml` (cluster-Secret label or ACM Placement) |
| `charts/argocd-config/` | Argo CD tuning (sharding, resources, exclusions, Sail Istio/IstioCNI health checks): the `argo-cd` chart's values on Kubernetes, the ArgoCD CR on OpenShift |
| `charts/acm-*` | OpenShift only: MultiClusterHub, KlusterletConfig, ManagedCluster, ClusterSet binding + Placement |
| `charts/cert-manager-operator/`, `charts/external-secrets-operator/` | Hub operators through OLM (OpenShift); Kubernetes uses the upstream charts |
| `charts/hub-mesh-ca/`, `charts/hub-mesh-ca-intermediate/` | Shared root CA and per-member intermediates |
| `charts/hub-kubeconfig-from-argosecret/`, `charts/hub-mesh-push-secrets/` | ESO: member kubeconfigs on the hub; push `cacerts` + Istio remote secrets |
| `charts/spoke-istio-namespaces/`, `charts/spoke-ossm-operator/`, `charts/spoke-ossm/` | Member namespaces, Sail operator (OSSM through OLM on OpenShift; the upstream chart on Kubernetes), Istio/IstioCNI (waits for `cacerts`) + tuning baseline |
| `charts/spoke-ingress-gateway/`, `charts/spoke-east-west-gateway/` | Member gateways |
| `charts/mesh-wiring-verify/` | Always-on gate per member (each other member's remote secret and istiod sync, by name; shared root, east-west address) |
| `charts/mesh-verify/`, `charts/mesh-verify-appset.yaml` | On-demand cross-cluster echo check |
| `charts/mesh-verify-gateway-api/`, `charts/mesh-verify-gateway-api-appset.yaml` | On-demand Gateway API check: HTTPRoutes on every member, echo workload on one (`tests/gateway-api`) |
| `charts/istiod-monitor/` | Optional ServiceMonitor + recording rules for istiod |
| `tests/<suite>/` | Numbered scripts + `chart/` (its `values-openshift.yaml` is added on OpenShift members by `tests/lib/platform.sh`; gateway-api deploys `charts/mesh-verify-gateway-api` instead; all but tuning also `configs/`, example run configs); see each suite README |
| `tests/tuning/profiles/` | Four profiles that each change something vs the chart's tuning baseline |
| `tests/lib/` | `common.sh`, `timestamp.sh`, `preamble.sh`, `metrics.sh`, `fanout.sh`, `capacity.sh`, `envelope.sh`, `lint-bare-scrape.sh`, `verify.sh`, `fortio.sh`, `reach.sh`, `config.sh`; bats tests in `test/` |
| `docs/scale-test-campaign/`, `docs/campaigns/` | Campaign runbook; recorded results |
| `docs/scale-test-team/` | The `/scale-test-review` cycle and the process-learnings (PL) catalog |
| `docs/runbooks/` | Leave-behind runbooks for deployed environments; `kind-lab/` builds a hub and two members on one machine |

## Testing and verification

- `git submodule update --init`, then `tests/lib/verify.sh`: syntax, shellcheck, inline-copy
  audit, bats, and every `# ci-dry-run:` script against an empty kubeconfig (no cluster needed).
  Required before merging changes to `tests/lib/`.
- Charts: `helm lint` / `helm template` each touched chart with its presets
  (`charts/gitops-hub-apps` needs `--set repo.url=<url>`), with and without its `values-openshift.yaml`;
  each ApplicationSet preset with both platform overlays (`platform-kubernetes.yaml`, `platform-openshift.yaml`).
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

# ROSA Hosted Control Plane (HCP) — Terraform

Provisions N independent [ROSA HCP](https://docs.openshift.com/rosa/rosa_hcp/rosa-hcp-sts-creating-a-cluster-quickly.html) clusters using the upstream module [`terraform-redhat/rosa-hcp/rhcs`](https://github.com/terraform-redhat/terraform-rhcs-rosa-hcp) ([registry](https://registry.terraform.io/modules/terraform-redhat/rosa-hcp/rhcs/latest)).

## Isolation model

Clusters are generated from `cluster_count` and naming/CIDR `format()` strings (see variables). Each cluster gets:

- Its own VPC (`…//modules/vpc`) — separate CIDR, subnets, gateways, always one availability zone (first AZ in the region from the upstream VPC submodule).
- Its own OIDC stack and account/operator IAM roles (`create_oidc`, `create_account_roles`, `create_operator_roles` all `true`), with prefixes derived from that cluster’s `cluster_name`.

Nothing in this root module shares VPCs or STS assets between clusters.

## Prerequisites

- Terraform >= 1.14.8 (matches the pinned module).
- AWS credentials for the target account/region.
- [ROSA AWS prerequisites](https://console.redhat.com/openshift/create/rosa/getstarted) completed.
- `RHCS_TOKEN` ([OpenShift offline token](https://console.redhat.com/openshift/token)) exported, or set `rhcs_token` in `terraform.tfvars` (never commit tokens).

## Usage

From this directory:

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit: aws_region, openshift_version (default pin 4.21.11 — align with config/versions.env),
#       cluster_count, cluster_name_format, vpc_cidr_format (+ index starts).

export RHCS_TOKEN='…'

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Scaling: change `cluster_count` (and optionally `cluster_name_format` / `cluster_index_start` / `vpc_cidr_format` / `vpc_cidr_index_start`). Terraform creates one map entry per index `0 .. cluster_count-1`. Each cluster’s Terraform key, OCM `cluster_name`, and intended kubectl context string share `format(cluster_name_format, idx + cluster_index_start)`; VPC CIDRs use `vpc_cidr_format` with `idx + vpc_cidr_index_start` (default `10.%d.0.0/16` → non-overlapping `10.0.0.0/16`, `10.1.0.0/16`, …). Shrinking `cluster_count` destroys the removed clusters — plan carefully.

Multi-AZ VPCs are not configurable here (always one AZ per cluster; one NAT and one EIP per cluster).

Default worker replicas at cluster install is 2 (ROSA single-zone minimum) unless `cluster_defaults.replicas` is set. The default machine pool (`workers`) is managed by Terraform with autoscaling (2–10 nodes by default unless `cluster_defaults.worker_autoscale_*` overrides), via `worker_pool.tf`. This root module does not manage `rhcs_hcp_cluster_autoscaler` (pool bounds still define scaling range; enabling the autoscaler resource in the upstream module has triggered provider apply/refresh inconsistencies for some API responses).

After apply, use `terraform output by_cluster` for each cluster’s `cluster_api_url` (and console URL). This stack does not generate a kubeconfig from Terraform itself. Terraform creates a shared cluster-admin password for every cluster (`password.tf`); read it with `terraform output cluster_admin_login` (sensitive). Log in with `oc login <cluster_api_url> -u cluster-admin -p ‘<password>’` per cluster and name your kubectl/oc contexts to match `cluster_name_format` (e.g. `rosa-001`, `rosa-002`) so they align with `SETUP_CONTEXTS` in `config/versions.env` and `istio-setup/` scripts. Do not commit kubeconfigs.

## ACM + GitOps (platform setup)

Set `enable_platform_setup = true` (default `false`) and re-apply to install RHACM and OpenShift GitOps on the hub cluster. This is a two-phase apply: the first apply creates ROSA clusters, the second installs platform components. The hub is always the lexicographically first cluster (`first_cluster_key`).

Resources created (in `platform_acm.tf`, `platform_acm_spokes.tf`, `platform_gitops.tf`):
- ACM operator namespace, Subscription, MultiClusterHub, KlusterletConfig
- Per-spoke ManagedCluster + auto-import-secret (idempotent — skips already-joined spokes)
- OpenShift GitOps operator Subscription, ArgoCD CR configuration
- ACM GitOps resources (ManagedClusterSetBinding, Placement, GitOpsCluster)
- Hub app-of-apps (when `gitops_app_repo_url` is set)
- ArgoCD cluster secret patching (public API URL + TLS CA chain)

Key variables: `acm_channel`, `gitops_operator_channel`, `gitops_app_repo_url`, `gitops_app_repo_revision`, `enable_gitops`. See `platform_variables.tf` and `terraform.tfvars.example`.

Every cluster gets a cluster-admin user. Terraform generates one random password (`password.tf`) and applies it to all clusters so you can log in everywhere with the same credentials. Read them with `terraform output cluster_admin_login` (sensitive); username is `cluster-admin`.

## Service quotas (AWS)

Before VPCs and clusters apply, `service_quotas.tf` can raise selected [Service Quotas](https://docs.aws.amazon.com/servicequotas/latest/userguide/intro.html) using the HashiCorp AWS provider resource [`aws_servicequotas_service_quota`](https://registry.terraform.io/providers/hashicorp/aws/6.43.0/docs/resources/aws_servicequotas_service_quota) (same family as provider 6.43.0). For each quota it sets value to `max(current_applied_limit_from_AWS, estimated_need)` where estimated_need uses live counts (VPCs, EIPs, IAM roles) plus your new clusters and `service_quota_buffer`, so Terraform never asks AWS for a quota below the applied limit the data source returns. (A Terraform-managed historical ceiling would require a separate store; `terraform_data` cannot reference its own configuration.) NAT per AZ is bounded as all regional NAT gateways + one new NAT per cluster (conservative for a single-AZ footprint because `DescribeNatGateways` has no availability-zone filter).

Covered today: VPCs per Region, Internet gateways per Region, EC2-VPC Elastic IPs, NAT gateways per Availability Zone, Gateway VPC endpoints per Region, IAM roles per account (IAM quota API is always queried in `us-east-1` via the `aws.quota_iam` alias).

- Set `manage_service_quotas = false` to skip quota resources if your org restricts quota changes (clusters still apply; you may hit hard limits).
- Tune `service_quota_iam_roles_per_new_cluster` if ROSA versions change role counts materially.
- Quota increases can remain pending for hours; apply may still fail until AWS approves. This stack does not wait beyond what the provider does for each `aws_servicequotas_service_quota`.

## Module version

`main.tf` pins the same literal `version` on both the root ROSA module and the VPC submodule. Bump both together when upgrading; see the upstream [changelog](https://github.com/terraform-redhat/terraform-rhcs-rosa-hcp/releases).

## State and secrets

Local state is the default. For shared use, configure a remote `backend` in a separate file. Do not commit `terraform.tfvars`, tokens, or kubeconfigs.

# ROSA Hosted Control Plane (HCP) — Terraform

Provisions N independent [ROSA HCP](https://docs.openshift.com/rosa/rosa_hcp/rosa-hcp-sts-creating-a-cluster-quickly.html) clusters using the upstream module [`terraform-redhat/rosa-hcp/rhcs`](https://github.com/terraform-redhat/terraform-rhcs-rosa-hcp) ([registry](https://registry.terraform.io/modules/terraform-redhat/rosa-hcp/rhcs/latest)).

## Isolation model

Clusters are generated from `cluster_count` and naming/CIDR `format()` strings (see variables). Each cluster gets:

- Its own VPC (`…//modules/vpc`) — separate CIDR, subnets, gateways, always one availability zone (first AZ in the region from the upstream VPC submodule).
- Its own OIDC stack and account/operator IAM roles (`create_oidc`, `create_account_roles`, `create_operator_roles` all `true`), with prefixes derived from that cluster's `cluster_name`.

Nothing in this root module shares VPCs or STS assets between clusters.

## Prerequisites

- Terraform >= 1.14.8 (matches the pinned module).
- AWS credentials for the target account/region.
- [ROSA AWS prerequisites](https://console.redhat.com/openshift/create/rosa/getstarted) completed.
- `RHCS_TOKEN` ([OpenShift offline token](https://console.redhat.com/openshift/token)) exported, or set `rhcs_token` in `terraform.tfvars` (never commit tokens).

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit: aws_region, openshift_version, cluster_count, cluster_name_format,
#       vpc_cidr_format (see terraform.tfvars.example for details).

export RHCS_TOKEN='…'

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### Scaling

Change `cluster_count` to add or remove clusters. Each cluster's Terraform key, OCM `cluster_name`, and kubectl context share `format(cluster_name_format, idx + cluster_index_start)`. VPC CIDRs use `vpc_cidr_format` with `idx + vpc_cidr_index_start` (default `10.%d.0.0/16` — non-overlapping). Shrinking `cluster_count` destroys removed clusters — plan carefully.

Default worker replicas at install is 2 (ROSA single-zone minimum). Autoscaling is enabled with a 2–10 node range by default; override via `cluster_defaults.worker_autoscale_*`.

### Outputs

After apply:

- `terraform output by_cluster` — each cluster's API and console URLs.
- `terraform output cluster_admin_login` — shared cluster-admin credentials (sensitive). Log in with `oc login <cluster_api_url> -u cluster-admin -p '<password>'` and name your contexts to match `cluster_name_format` so they align with `SETUP_CONTEXTS` in `config/versions.env`.
- `terraform output -raw kubeconfig > ~/.kube/rosa-config` — merged kubeconfig with exec credential plugin for automatic token refresh. Do not commit kubeconfigs.

## ACM + GitOps (platform setup)

ACM and OpenShift GitOps are managed in a separate Terraform module at `terraform/platform/`. After clusters are up:

```bash
cd ../platform
cp terraform.tfvars.example terraform.tfvars   # edit as needed
terraform init && terraform apply
```

The platform module reads this module's state via `terraform_remote_state` (local backend). See `terraform/platform/terraform.tfvars.example` for variables.

## Service quotas (AWS)

Before VPCs and clusters apply, `service_quotas.tf` auto-raises selected AWS Service Quotas (VPCs, EIPs, Internet/NAT gateways, IAM roles) based on current usage plus the new clusters. Set `manage_service_quotas = false` to skip if your org restricts quota changes. Quota increases can remain pending for hours; apply may fail until AWS approves.

## Module version

`main.tf` pins the same literal `version` on both the root ROSA module and the VPC submodule. Bump both together when upgrading; see the upstream [changelog](https://github.com/terraform-redhat/terraform-rhcs-rosa-hcp/releases).

## State and secrets

Local state is the default. For shared use, configure a remote `backend` in a separate file. Do not commit `terraform.tfvars`, tokens, or kubeconfigs.

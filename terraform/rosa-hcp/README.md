# ROSA Hosted Control Plane (HCP) — Terraform

Provisions **N** independent [ROSA HCP](https://docs.openshift.com/rosa/rosa_hcp/rosa-hcp-sts-creating-a-cluster-quickly.html) clusters using the upstream module [`terraform-redhat/rosa-hcp/rhcs`](https://github.com/terraform-redhat/terraform-rhcs-rosa-hcp) ([registry](https://registry.terraform.io/modules/terraform-redhat/rosa-hcp/rhcs/latest)).

## Isolation model

Each entry in `var.clusters` gets:

- Its own **VPC** (`…//modules/vpc`) — separate CIDR, subnets, gateways, **always one availability zone** (first AZ in the region from the upstream VPC submodule).
- Its own **OIDC** stack and **account/operator IAM roles** (`create_oidc`, `create_account_roles`, `create_operator_roles` all `true`), with prefixes derived from that cluster’s `cluster_name`.

Nothing in this root module shares VPCs or STS assets between clusters.

## Prerequisites

- Terraform **>= 1.14.8** (matches the pinned module).
- AWS credentials for the target account/region.
- [ROSA AWS prerequisites](https://console.redhat.com/openshift/create/rosa/getstarted) completed.
- `RHCS_TOKEN` ([OpenShift offline token](https://console.redhat.com/openshift/token)) exported, **or** set `rhcs_token` in `terraform.tfvars` (never commit tokens).

## Usage

From this directory:

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit: aws_region, openshift_version, clusters (unique cluster_name and vpc_cidr per entry).

export RHCS_TOKEN='…'

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Add or remove map entries in `clusters` to scale cluster count. Use **non-overlapping** `vpc_cidr` values. Multi-AZ VPCs are **not** configurable here (always one AZ per cluster; one NAT and one EIP per cluster).

Default **worker `replicas`** is **2** (ROSA single-zone minimum) unless you set `replicas` on a cluster entry.

After apply, use `outputs.by_cluster` for API URLs and align kubeconfig context names with your workflow (for example `SETUP_CONTEXTS` in `config/versions.env`).

Every cluster gets a **cluster-admin** user. Terraform generates **one** random password (`password.tf`) and applies it to **all** clusters so you can log in everywhere with the same credentials. Read them with `terraform output cluster_admin_login` (sensitive); username is `cluster-admin`.

## Service quotas (AWS)

Before VPCs and clusters apply, `service_quotas.tf` can raise selected [Service Quotas](https://docs.aws.amazon.com/servicequotas/latest/userguide/intro.html) using the HashiCorp AWS provider resource [`aws_servicequotas_service_quota`](https://registry.terraform.io/providers/hashicorp/aws/6.43.0/docs/resources/servicequotas_service_quota) (same family as provider **6.43.0**). For each quota it sets `value = max(current_applied_limit, estimated_need)` where **estimated_need** uses live counts (VPCs, EIPs, IAM roles) plus your new clusters and `service_quota_buffer`. **NAT per AZ** is bounded as **all regional NAT gateways + one new NAT per cluster** (conservative for a single-AZ footprint because `DescribeNatGateways` has no availability-zone filter).

Covered today: **VPCs per Region**, **Internet gateways per Region**, **EC2-VPC Elastic IPs**, **NAT gateways per Availability Zone**, **Gateway VPC endpoints per Region**, **IAM roles per account** (IAM quota API is always queried in `us-east-1` via the `aws.quota_iam` alias).

- Set **`manage_service_quotas = false`** to skip quota resources if your org restricts quota changes (clusters still apply; you may hit hard limits).
- Tune **`service_quota_iam_roles_per_new_cluster`** if ROSA versions change role counts materially.
- Quota increases can remain **pending** for hours; apply may still fail until AWS approves. This stack does not wait beyond what the provider does for each `aws_servicequotas_service_quota`.

## Module version

`main.tf` pins the same literal `version` on both the root ROSA module and the VPC submodule. Bump both together when upgrading; see the upstream [changelog](https://github.com/terraform-redhat/terraform-rhcs-rosa-hcp/releases).

## State and secrets

Local state is the default. For shared use, configure a remote `backend` in a separate file. Do not commit `terraform.tfvars`, tokens, or kubeconfigs.

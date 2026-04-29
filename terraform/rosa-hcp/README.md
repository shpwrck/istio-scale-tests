# ROSA Hosted Control Plane (HCP) — Terraform carve-out

This directory provisions **Red Hat OpenShift on AWS (ROSA) Hosted Control Plane** clusters using the upstream [`terraform-redhat/terraform-rhcs-rosa-hcp`](https://github.com/terraform-redhat/terraform-rhcs-rosa-hcp) module published as [`terraform-redhat/rosa-hcp/rhcs`](https://registry.terraform.io/modules/terraform-redhat/rosa-hcp/rhcs/latest) on the Terraform Registry.

It does **not** use the classic (non-HCP) ROSA Terraform modules; HCP typically provisions faster for lab and scale-test iteration.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) **>= 1.14.9** (matches upstream constraints).
- AWS credentials with permissions to create VPCs, IAM roles/policies, OIDC providers, and supporting ROSA STS resources.
- [ROSA AWS prerequisites](https://console.redhat.com/openshift/create/rosa/getstarted) completed for the account.
- A valid [OpenShift Cluster Manager offline token](https://console.redhat.com/openshift/token), exported as **`RHCS_TOKEN`** (recommended), or set **`TF_VAR_rhcs_token`** for automation (never commit tokens).

Optional: `aws`, `rosa`, `oc` CLIs for post-install actions used elsewhere in this repository (`setup-scripts/`).

## Layout

| File / path | Purpose |
| ----------- | ------- |
| `main.tf` | `for_each` over `var.clusters`: one [`modules/vpc`](https://registry.terraform.io/modules/terraform-redhat/rosa-hcp/rhcs/latest/submodules/vpc) + one root ROSA HCP module instance per cluster. |
| `variables.tf` | Cluster map, region, OpenShift version, RHCS token variable. |
| `providers.tf` | `aws` + `rhcs` providers. |
| `outputs.tf` | API URLs, VPC IDs, OIDC identifiers per cluster key. |
| `terraform.tfvars.example` | Sample multi-cluster tfvars (distinct **vpc_cidr** per cluster). |
| `quota-assumptions.env` | **Plan-mode inputs** for the quota helper (per-cluster EIP/NAT/IAM estimates). Sync **`UPSTREAM_MODULE_VERSION`** with **`main.tf`** when bumping the module; see **`docs/quota-assumptions.source.md`**. |
| `docs/quota-assumptions.source.md` | **Provenance** for each assumption (upstream VPC submodule, repo layout) and **refresh checklist** when the Terraform module version changes. |
| `helpers/rosa-hcp-aws-quotas.sh` | **`check`** — table of current quotas; **`plan --clusters N`** — reads **`quota-assumptions.env`**, compares to live AWS quotas, prints **`request-service-quota-increase`** only where needed. |
| `.terraform.lock.hcl` | Provider pin file — commit for reproducible `terraform init`. |

Upstream module version is pinned as a **literal** `version = "..."` in `main.tf` (Terraform does not allow variables there). Bump both module blocks together when upgrading.

## Multi-VPC and multi-OIDC design

**Requirement:** *N* clusters, each in a **different VPC**, each with a **different OIDC configuration** for STS.

**Pattern used here:** a single root module with **`module "vpc"`** and **`module "rosa_hcp"`** both keyed by **`for_each = var.clusters`**.

1. **Different VPC per cluster** — Each map entry provisions a dedicated VPC via `terraform-redhat/rosa-hcp/rhcs//modules/vpc` with its own `vpc_cidr`, subnets, and gateways. Pass non-overlapping CIDRs per cluster (required for routing sanity if networks interact later).

2. **Different OIDC provider per cluster** — For each `module "rosa_hcp"` instance we set **`create_oidc = true`** (and **`create_account_roles`** / **`create_operator_roles`**). The upstream module creates a dedicated OIDC config/provider stack per instance; **`account_role_prefix`** / **`operator_role_prefix`** are derived from **`cluster_name`** so IAM assets remain unique within the account.

**Alternative:** Terraform **workspaces** with **one** cluster per workspace reuses the same `.tf` files but isolates state; you still instantiate one VPC module + one ROSA module per workspace. That pattern trades duplication of root vars for separate state files (useful for blast-radius or separate IAM principals).

**Not mixed:** Sharing one OIDC across multiple HCP clusters is not what this layout targets; if you intentionally reuse STS/OIDC, use upstream inputs **`create_oidc = false`**, **`oidc_config_id`**, and **`oidc_endpoint_url`** instead (see upstream README).

## AWS service quotas (often ≤ five clusters)

Many accounts default to **five VPCs per Region** (`VPCs per Region`, quota code **`L-F678F1CE`** under service **`vpc`**). With one VPC per ROSA cluster, you often hit this ceiling **before** other limits—plan quota increases early.

Other quotas that frequently matter when stacking multiple clusters in one account/region:

| Area | Service (CLI `service-code`) | Typical constraint |
| ---- | ---------------------------- | ------------------ |
| VPC count | `vpc` | **VPCs per Region** — often **5** default |
| Internet/NAT footprint | `vpc` | Internet gateways per Region; NAT gateways per AZ |
| Elastic IPs | `ec2` | **EC2-VPC Elastic IPs** — NAT and load balancers consume EIPs |
| IAM roles | `iam` (global; API region `us-east-1`) | Many roles per ROSA cluster |
| OIDC providers | `iam` | One provider stack per cluster when `create_oidc = true` |

Quota helper (from **`terraform/rosa-hcp/`**):

```bash
./helpers/rosa-hcp-aws-quotas.sh check --region YOUR_REGION    # optional: --profile NAME
./helpers/rosa-hcp-aws-quotas.sh plan --clusters N --region YOUR_REGION [--buffer 2]
```

**`plan`** loads **`quota-assumptions.env`** (override with **`QUOTA_ASSUMPTIONS_FILE`**) for per-cluster estimates **derived from the pinned upstream VPC submodule and this repo’s layout** — see **`docs/quota-assumptions.source.md`**. It compares those estimates to live quotas and emits **`aws service-quotas request-service-quota-increase`** lines with suggested **`--desired-value`** (required + **`--buffer`**). Review before running.

For console steps: **AWS Console → Service Quotas → AWS services →** **Amazon VPC** / **Amazon EC2** / **IAM** — see [Requesting a quota increase](https://docs.aws.amazon.com/servicequotas/latest/userguide/request-quota-increase.html).

## Configure and run

From **`terraform/rosa-hcp/`**:

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: aws_region, openshift_version, clusters (unique vpc_cidr each).

export RHCS_TOKEN='***'   # OpenShift offline token

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

**Backend:** this skeleton uses local state. For teams, configure a remote `backend "s3"` (or equivalent) in a separate `backend.tf` — do **not** commit buckets or lock-table secrets.

**Kubeconfig:** after apply, use `rosa login` / `oc login` with your chosen identity flow (cluster-admin user is optional via `create_cluster_admin_user` per cluster).

## Relationship to the rest of this repo

Mesh installation, certificates, and gateways remain under **`setup-scripts/`** and **`manifests/ossm-multi-cluster/`**. Use Terraform outputs (API URL, contexts you configure in kubeconfig) to align **`SETUP_CONTEXTS`** / **`--contexts`** with the clusters you created here.

Pin **`openshift_version`** to the same train as **`OPENSHIFT_VERSION`** / **`ISTIO_VERSION`** in **`config/versions.env`** when running OSSM scale tests.

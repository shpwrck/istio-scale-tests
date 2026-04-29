# Quota plan assumptions — sources and updates

The **`plan`** mode of **`helpers/rosa-hcp-aws-quotas.sh`** reads numeric assumptions from **`../quota-assumptions.env`** (override path with **`QUOTA_ASSUMPTIONS_FILE`**). This document explains **where each value comes from** and **what to do when upstream changes**.

## 1. Upstream Terraform module (authoritative for VPC/NAT/EIP shape)

| Field | Source |
| ----- | ------ |
| **Module tag** | Must match **`version = "..."`** on **both** `module "vpc"` and `module "rosa_hcp"` in **`main.tf`**. **`UPSTREAM_MODULE_VERSION`** in **`quota-assumptions.env`** mirrors that tag (e.g. **`1.7.3`**). |
| **VPC submodule** | **`modules/vpc/main.tf`** at the same tag as **`main.tf`** (example tag [**`v1.7.3`**](https://github.com/terraform-redhat/terraform-rhcs-rosa-hcp/blob/v1.7.3/modules/vpc/main.tf)). |

### NAT gateways and NAT EIPs (per cluster)

In the VPC submodule, **`aws_eip.eip`** and **`aws_nat_gateway.public_nat_gateway`** both use:

`count = length(local.availability_zones)`

So for **one cluster**, the Terraform-managed NAT footprint in **that** VPC is:

- **NAT gateways** inside the VPC: **one per availability zone** used by the VPC (same as **`availability_zones_count`** in this repo’s **`var.clusters`**).
- **EIPs** attached to those NAT gateways: **same count** (one EIP per NAT).

That drives:

- **`QUOTA_ASSUMED_AVAILABILITY_ZONES_COUNT`** — set to the **maximum** **`availability_zones_count`** you use across **`var.clusters`** (default **3** in **`terraform.tfvars.example`**).
- **`QUOTA_ASSUMED_VPC_NAT_EIP_PER_CLUSTER`** — equals that AZ count (NAT EIPs only).
- **`QUOTA_ASSUMED_NAT_PER_VPC`** — max NAT in a **single** VPC for this layout (= AZ count).
- **`QUOTA_ASSUMED_NAT_PER_AZ_PER_CLUSTER`** — **1** NAT per AZ **per cluster** (used with cluster count **N** for the **“NAT gateways per Availability Zone”** account quota).

### Extra EIPs (not from the VPC submodule)

Load balancers, ROSA networking, and other AWS resources can allocate **additional** EIPs. Those are **not** counted in **`modules/vpc/main.tf`**. **`QUOTA_ASSUMED_EIP_EXTRA_PER_CLUSTER`** is a **buffer**; adjust it using measurement (e.g. compare account EIP usage before/after one test cluster) or team policy, and note the change in git.

### Total EIPs per cluster (plan math)

**`QUOTA_ASSUMED_EIP_PER_CLUSTER`** = **`QUOTA_ASSUMED_VPC_NAT_EIP_PER_CLUSTER` + `QUOTA_ASSUMED_EIP_EXTRA_PER_CLUSTER`** (computed in **`quota-assumptions.env`**).

## 2. Structural counts (this repository)

| Item | Source |
| ---- | ------ |
| **1 VPC per cluster** | **`main.tf`**: `module "vpc"` **`for_each = var.clusters`**. |
| **1 internet gateway per VPC** | Same VPC submodule ( **`aws_internet_gateway`** ). |
| **1 OIDC-related stack per cluster** | **`main.tf`**: **`create_oidc = true`** per **`module "rosa_hcp"`** instance — distinct OIDC per cluster. |

No separate env vars: **`plan`** uses cluster count **N** for VPC, IGW, and OIDC provider quotas.

## 3. IAM roles per cluster (estimate)

IAM role creation is driven by the **ROSA HCP / STS** path in the **`rhcs`** root module, not the VPC submodule. **`QUOTA_ASSUMED_IAM_ROLES_PER_CLUSTER`** is an **order-of-magnitude** placeholder.

**When to refresh:**

- Bump **`UPSTREAM_MODULE_VERSION`** / OpenShift version, or
- After a pilot install, run **`aws iam list-roles`** (and similar) and derive **roles per cluster** for your account pattern.

Point **`quota-assumptions.env`** at that measurement and/or cite Red Hat/AWS ROSA documentation links you used.

## 4. Update checklist (when `main.tf` module version changes)

1. Note the new **`version = "X.Y.Z"`** in **`main.tf`**.
2. Open **`https://github.com/terraform-redhat/terraform-rhcs-rosa-hcp/blob/vX.Y.Z/modules/vpc/main.tf`** and confirm **`aws_eip`** / **`aws_nat_gateway`** **`count`** logic is still **`length(local.availability_zones)`** (or update §1 in this file).
3. Update **`UPSTREAM_MODULE_VERSION`** and any derived defaults in **`quota-assumptions.env`**.
4. Re-run **`./helpers/rosa-hcp-aws-quotas.sh plan --clusters …`** for a sanity check.
5. Align **`QUOTA_ASSUMED_AVAILABILITY_ZONES_COUNT`** with **`terraform.tfvars`** if you changed default AZ counts.

## 5. Live quota *values* (not assumptions)

**`check`** and **`plan`** still call **AWS Service Quotas** (**`aws service-quotas get-service-quota`**) for **current effective limits** in your account. Those numbers always come from **AWS**, not from this file.

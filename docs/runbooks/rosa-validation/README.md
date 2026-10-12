---
leave-behind: v1
state-scope: rosa-validation
status: current
---

# ROSA validation leave-behind

How to stand up the ROSA path end to end (`terraform/rosa-hcp`, then
`terraform/platform` in rosa mode, then a mesh check) and tear it all down
again. No ROSA clusters exist right now: the last run (3 HCP clusters, ~1h50m) was
destroyed and verified empty. Only the account-level ROSA setup remains (the
OCM role, the user role and the `ManagedOpenShift-HCP-ROSA-*` account roles), so the next run can skip it.

## Operability

### State and access

- AWS: an IAM user with AdministratorAccess (never root keys, which `rosa` rejects) in a
  named AWS CLI profile in `~/.aws/`. Export `AWS_PROFILE=<profile>` for every
  terraform, rosa and aws command.
- Red Hat: `rosa login --use-auth-code` (session in `~/.config/ocm/ocm.json`).
  Terraform's rhcs provider reuses it through
  `RHCS_CLIENT_ID=ocm-cli RHCS_TOKEN="$(rosa token --refresh)"`.
- One-time account setup: in the AWS console, open Red Hat OpenShift Service on AWS → Get started,
  enable ROSA, then "Continue to Red Hat" and sign in as the Red Hat account `rosa` uses. Then
  `rosa create ocm-role --mode auto --yes` and `rosa create user-role --mode auto --yes`.
  An AWS account's ROSA subscription can be linked to only one Red Hat account,
  and demo-platform sandbox accounts usually come pre-linked to someone else.
- Terraform state: `terraform/rosa-hcp/terraform.tfstate` (local, gitignored) and the
  platform's rosa-mode state (a separate workspace or checkout, never mixed with
  kubeconfig-mode state). Inputs in `terraform.tfvars` / `rosa.tfvars` (gitignored).
- Cluster access: `terraform/rosa-hcp/kubeconfig` (mode 0600; exec plugin that logs in as
  `cluster-admin` with the Terraform-generated password).

### Template map

terraform/rosa-hcp/terraform.tfvars.example -> terraform/rosa-hcp/terraform.tfvars (region, version, count, sizing)
terraform/rosa-hcp/outputs.tf (local.kubeconfig_yaml) -> terraform/rosa-hcp/kubeconfig (merged kubeconfig, mode 0600)
terraform/platform/terraform.tfvars.example -> terraform/platform/rosa.tfvars (cluster_provider = "rosa", repo URL and revision, small istiod override)

### Re-run

```bash
export AWS_PROFILE=<profile>
terraform/rosa-hcp/scripts/001-preflight.sh          # read-only; prints the fix for each failed check
export RHCS_CLIENT_ID=ocm-cli RHCS_TOKEN="$(rosa token --refresh)"
cd terraform/rosa-hcp && terraform init && terraform plan -out=rosa.tfplan && terraform apply rosa.tfplan
cd ../platform && terraform plan -var-file=rosa.tfvars -out=platform.tfplan && terraform apply platform.tfplan
```

Sizing that fits and is cheap: the hub on m5.2xlarge, members on the default m7i.xlarge,
2 workers each (`worker_autoscale_min = worker_autoscale_max = 2`), and the
small-istiod `gitops_app_overrides` entry from the tfvars example (the default
istiod is 3 × 4 CPU, which doesn't fit an m7i.xlarge pair).

### Verify and recover

- `rosa list clusters`: all `ready`. `oc --kubeconfig terraform/rosa-hcp/kubeconfig --context cluster-001 get applications.argoproj.io -n openshift-gitops`: all Synced/Healthy (31 apps).
- On each member, `oc exec -n mesh-wiring-verify deploy/mesh-wiring-verify -- bash /opt/check/readiness.sh`: `Ready ... ca=shared`.
- mesh-verify through each member's ingress (`.status.loadBalancer.ingress[0].hostname` on AWS): answers come from both members.
- Teardown, in order:

```bash
export AWS_PROFILE=<profile> RHCS_CLIENT_ID=ocm-cli RHCS_TOKEN="$(rosa token --refresh)"
(cd terraform/platform && terraform destroy -var-file=rosa.tfvars)
terraform/rosa-hcp/scripts/002-pre-destroy-vpc-cleanup.sh       # removes load balancers the gateways created
(cd terraform/rosa-hcp && terraform destroy)
# If the VPCs fail with DependencyViolation: ROSA left a <cluster-id>-vpce-private-router
# security group behind. Run 002-pre-destroy-vpc-cleanup.sh again, then terraform destroy again.
rosa list clusters                                                 # expect: none
```

- Confirm nothing billable is left: no clusters, NAT gateways, load balancers or Elastic IPs (`aws ec2 describe-nat-gateways`, `aws elb/elbv2 describe-load-balancers`, `aws ec2 describe-addresses`).

## Decision log

### Decisions

- Purpose: prove the ROSA path (greenfield: Terraform installs ACM, GitOps and the mesh), which the
  existing-cluster lab (brownfield) cannot. Both paths were verified on 2026-10-12.
- Account traps found live, all now caught by `001-preflight.sh`: expired keys, root keys,
  no OCM role or user role, the AWS account linked to a different Red Hat org, and the browser
  reusing the wrong Red Hat SSO session (use a private window for `rosa login`).
- Machine type: the repo passes one resolved type to both the cluster and its worker pool
  (OCM's default changed to m7i.xlarge; a mismatch is immutable and fails the apply).
- Destroy order: operator CSV cleanup runs only after the ArgoCD CR, apps and MultiClusterHub are
  gone (before, it ran in parallel and the ArgoCD CR hung on its finalizer).

### How to drive it

1. Run the preflight until it passes.
2. Apply `terraform/rosa-hcp`, then the platform in rosa mode.
3. Verify, then tear down straight away; the clusters bill hourly (about $3.5/hour for 3 small clusters).
4. Confirm empty: `terraform -chdir=terraform/rosa-hcp state list` prints nothing and `rosa list clusters` shows none.

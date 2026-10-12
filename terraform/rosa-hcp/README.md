# ROSA HCP clusters (Terraform)

Creates N independent [ROSA with hosted control planes](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/install_clusters/rosa-hcp-sts-creating-a-cluster-quickly)
clusters with the [`terraform-redhat/rosa-hcp/rhcs`](https://registry.terraform.io/modules/terraform-redhat/rosa-hcp/rhcs/latest)
module. Each cluster gets its own VPC, OIDC config, and account/operator roles. Cluster 1
becomes the ACM hub, and the rest become mesh members (see `terraform/platform`).

## One-time account setup

1. **AWS credentials:** an IAM user with AdministratorAccess, in a named profile
   (`aws configure --profile <name>`, then `export AWS_PROFILE=<name>`). `rosa` rejects root keys.
2. **Enable ROSA and link billing:** AWS console → Red Hat OpenShift Service on AWS → Get started.
   Enable ROSA, then **Continue to Red Hat** and sign in with the Red Hat account you'll use below.
   An AWS account's ROSA subscription links to only one Red Hat account, and sandbox accounts are
   often pre-linked to someone else's. In that case, use a different AWS account.
3. **Log in and create the link roles:**
   ```bash
   rosa login --use-auth-code      # use a private browser window to pick the right Red Hat account
   rosa create ocm-role --mode auto --yes
   rosa create user-role --mode auto --yes
   ```

## Run

```bash
cp terraform.tfvars.example terraform.tfvars   # region, openshift_version, cluster_count, sizing
./scripts/001-preflight.sh                     # read-only; prints the fix for anything missing
export RHCS_CLIENT_ID=ocm-cli RHCS_TOKEN="$(rosa token --refresh)"
terraform init
terraform plan -out=rosa.tfplan
terraform apply rosa.tfplan
```

Clusters take about 20 minutes. Outputs: `terraform output by_cluster` (API and console URLs),
`terraform output cluster_admin_login` (sensitive), and a merged kubeconfig at `./kubeconfig`
(mode 0600). Next, apply `terraform/platform` with `cluster_provider = "rosa"`.

Sizing: workers default to m7i.xlarge with 2 nodes (the ROSA minimum). Use `cluster_overrides` for
a bigger hub (for example m5.2xlarge), and `cluster_defaults.worker_autoscale_{min,max}` for autoscaling.
`service_quotas.tf` raises the VPC/EIP/NAT/IAM quotas the clusters need. Set
`manage_service_quotas = false` if your org blocks quota changes.

## Tear down

Clusters bill hourly. Destroy the platform first, then:

```bash
./scripts/002-pre-destroy-vpc-cleanup.sh --dry-run
./scripts/002-pre-destroy-vpc-cleanup.sh       # removes load balancers created by the gateways
terraform destroy
```

If `terraform destroy` fails on a VPC with `DependencyViolation`, ROSA left its
`<cluster-id>-vpce-private-router` security group behind. Run `002-pre-destroy-vpc-cleanup.sh`
again, then `terraform destroy` again.

Keep `terraform.tfvars`, state, and `kubeconfig` out of git (they're already in `.gitignore`).

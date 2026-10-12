---
leave-behind: v1
state-scope: rosa-validation
status: current
---

# ROSA validation clusters leave-behind

Three temporary ROSA HCP clusters (`cluster-001` = ACM hub on m5.2xlarge,
`cluster-002`/`cluster-003` = mesh members on m5.xlarge, 2–3 workers each) in
one AWS region. They exist to prove the ROSA path end to end
(`terraform/rosa-hcp` → `terraform/platform` in rosa mode → mesh verify) and are
destroyed afterwards. While they exist they bill hourly (cluster fee, EC2, NAT
gateways), so finish with the teardown in "Verify and recover".

## Operability

### State and access

- AWS credentials: the named AWS CLI profile `istio-scale-tests` in `~/.aws/`.
  Export `AWS_PROFILE=istio-scale-tests` before any terraform or rosa command.
- Red Hat credentials: the `rosa login` session (`~/.config/ocm/ocm.json`). The
  Terraform `rhcs` provider accepts that session's refresh token only when it is
  told the client id: `RHCS_CLIENT_ID=ocm-cli RHCS_TOKEN="$(rosa token --refresh)"`.
  A console offline token or a service account (`RHCS_CLIENT_ID`/`RHCS_CLIENT_SECRET`)
  also works.
- Account linkage (one-time, reversible): `ManagedOpenShift-OCM-Role-<org>` and
  `ManagedOpenShift-User-<user>-Role` IAM roles, linked to the OCM organization
  with `rosa create ocm-role --mode auto` and `rosa create user-role --mode auto`.
  Without them cluster creation fails with `CLUSTERS-MGMT-403 ... not authorized to access AWS Account`.
- Terraform state: `terraform/rosa-hcp/terraform.tfstate` (local, gitignored) and the
  platform's `rosa` workspace (`terraform/platform/terraform.tfstate.d/rosa/`).
  Inputs: `terraform/rosa-hcp/terraform.tfvars` and `terraform/platform/rosa.tfvars` (gitignored).
- Cluster access: the generated `terraform/rosa-hcp/kubeconfig` (exec plugin that
  logs in as `cluster-admin` with the Terraform-generated password).

### Template map

terraform/rosa-hcp/terraform.tfvars.example -> terraform/rosa-hcp/terraform.tfvars (region, version, count, sizing)
terraform/rosa-hcp/outputs.tf (local.kubeconfig_yaml) -> terraform/rosa-hcp/kubeconfig (merged kubeconfig, mode 0600)
terraform/platform/terraform.tfvars.example -> terraform/platform/rosa.tfvars (cluster_provider = "rosa", repo URL and revision)

### Re-run

```bash
export AWS_PROFILE=istio-scale-tests
export RHCS_CLIENT_ID=ocm-cli RHCS_TOKEN="$(rosa token --refresh)"
cd terraform/rosa-hcp
terraform init
terraform plan -out=rosa.tfplan && terraform apply rosa.tfplan
cd ../platform
TF_WORKSPACE=rosa terraform plan -var-file=rosa.tfvars -out=rosa-platform.tfplan
TF_WORKSPACE=rosa terraform apply rosa-platform.tfplan
```

Both applies converge: after a partial failure, fix the cause and re-run
the same commands.

### Verify and recover

- Clusters: `rosa list clusters` shows the three clusters `ready`; `terraform -chdir=terraform/rosa-hcp output by_cluster` has their API URLs.
- Platform and mesh: same checks as `docs/runbooks/existing-cluster-lab/README.md`
  (ManagedClusters joined, Argo Applications Synced/Healthy, mesh-wiring-verify Ready, mesh-verify answers from both members).
- Teardown (always run it when you're done, in this order):

```bash
export AWS_PROFILE=istio-scale-tests RHCS_CLIENT_ID=ocm-cli RHCS_TOKEN="$(rosa token --refresh)"
(cd terraform/platform && TF_WORKSPACE=rosa terraform destroy -var-file=rosa.tfvars)
terraform/rosa-hcp/scripts/001-pre-destroy-vpc-cleanup.sh --dry-run
terraform/rosa-hcp/scripts/001-pre-destroy-vpc-cleanup.sh
(cd terraform/rosa-hcp && terraform destroy)
rosa list clusters          # expect: No clusters available
```

- Optional, only if this account won't run ROSA again: `rosa unlink user-role` / `rosa delete user-role`,
  then `rosa unlink ocm-role` / `rosa delete ocm-role`.

## Decision log

### Decisions

- Purpose: prove the ROSA path, which can't be tested on the self-managed lab, then tear it all down.
- Sizing: the ACM hub gets m5.2xlarge workers (ACM + Argo CD); members stay on the m5.xlarge default; autoscale 2–3 caps the cost.
- OpenShift 4.21.35: the newest 4.21 that ROSA HCP offered at the time. It keeps the same minor as the lab clusters, so results are comparable.
- The platform runs in its own Terraform workspace with its own var file, so the
  rosa-mode state can never be mixed with the lab's kubeconfig-mode state in the same directory.

### How to drive it

1. Export the AWS profile and the RHCS token as shown above.
2. Apply `terraform/rosa-hcp`, then the platform `rosa` workspace.
3. Run the verify checks.
4. Run the teardown, and confirm `rosa list clusters` is empty and no
   `terraform/rosa-hcp` resources remain (`terraform -chdir=terraform/rosa-hcp state list` prints nothing).
5. When the teardown is done, set this file's `status` to `retired` (or delete it) in the same PR.

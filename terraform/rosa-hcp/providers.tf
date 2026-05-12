provider "aws" {
  region = var.aws_region
}

# IAM service quotas are global; the Service Quotas API expects us-east-1 (commercial).
provider "aws" {
  alias  = "quota_iam"
  region = "us-east-1"
}

provider "rhcs" {
  # Authenticate with OpenShift Cluster Manager (export RHCS_TOKEN), or set
  # TF_VAR_rhcs_token for CI. See https://registry.terraform.io/providers/terraform-redhat/rhcs/latest/docs
  token = var.rhcs_token
}

provider "time" {}

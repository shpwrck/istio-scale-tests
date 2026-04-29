provider "aws" {
  region = var.aws_region
}

# Authentication: export RHCS_TOKEN (offline token from https://console.redhat.com/openshift/token ).
# If var.rhcs_token is set, it is passed explicitly (e.g. CI secrets via TF_VAR_rhcs_token).
provider "rhcs" {
  token = var.rhcs_token
}

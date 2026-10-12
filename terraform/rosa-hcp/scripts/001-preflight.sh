#!/usr/bin/env bash
# ci-dry-run: --dry-run
set -euo pipefail

# Read-only check of every account prerequisite for `terraform apply` in
# terraform/rosa-hcp. Each failed check prints the command that fixes it.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="${SCRIPT_DIR}/.."

DRY_RUN=0
REGION=""
VERSION=""
OCM_API="https://api.openshift.com"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Check that this machine can create ROSA HCP clusters with terraform/rosa-hcp:
AWS credentials, rosa login, OCM/user roles linked to your Red Hat org, the
AWS account linked to that org for billing, AWS quotas, and the OpenShift
version. Read-only; prints a fix for each failure. Exit 1 if any check fails.

Options:
  --region REGION    AWS region (default: aws_region in terraform.tfvars, then \$AWS_REGION,
                     \$AWS_DEFAULT_REGION, aws config)
  --version X.Y.Z    OpenShift version to check (default: openshift_version in terraform.tfvars)
  --dry-run          List the checks without running them
  -h, --help         Show this help

Uses the active AWS profile (set AWS_PROFILE) and the current 'rosa login'.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --region)
    [[ -n "${2:-}" ]] || die "--region requires a value"
    REGION="$2"
    shift 2
    ;;
  --version)
    [[ -n "${2:-}" ]] || die "--version requires a value"
    VERSION="$2"
    shift 2
    ;;
  --dry-run)
    DRY_RUN=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    die "unknown option: $1 (try --help)"
    ;;
  esac
done

if [[ -z "$VERSION" && -f "${TF_DIR}/terraform.tfvars" ]]; then
  VERSION="$(sed -n 's/^[[:space:]]*openshift_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${TF_DIR}/terraform.tfvars" | head -1)"
fi
# Check the region terraform will create the clusters in, not the profile's default.
if [[ -z "$REGION" && -f "${TF_DIR}/terraform.tfvars" ]]; then
  REGION="$(sed -n 's/^[[:space:]]*aws_region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${TF_DIR}/terraform.tfvars" | head -1)"
fi

CHECKS=(
  "tools: aws, rosa, jq, curl, terraform on PATH"
  "AWS credentials work (aws sts get-caller-identity)"
  "rosa is logged in (rosa whoami)"
  "an OCM role is linked to your Red Hat org"
  "a user role is linked to your Red Hat user"
  "the AWS account is linked to your Red Hat org for billing (AWS Marketplace)"
  "AWS service quotas are enough for ROSA (rosa verify quota)"
  "OpenShift version is offered for HCP (rosa list versions --hosted-cp)"
)

if ((DRY_RUN)); then
  echo "[dry-run] checks:"
  printf '  - %s\n' "${CHECKS[@]}"
  exit 0
fi

FAILS=0
ok() { echo "  OK    $*"; }
fail() {
  echo "  FAIL  $1"
  shift
  local line
  for line in "$@"; do echo "        fix: $line"; done
  FAILS=$((FAILS + 1))
}

echo "=== ROSA HCP preflight ==="

missing=()
for t in aws rosa jq curl terraform; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
if ((${#missing[@]})); then
  fail "missing tools: ${missing[*]}" "install them and re-run"
  exit 1
fi
ok "tools present"

if ! ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
  fail "AWS credentials are missing or expired (profile: ${AWS_PROFILE:-default})" \
    "aws configure --profile <name>   (or aws sso login --profile <name>), then export AWS_PROFILE=<name>"
  exit 1
fi
REGION="${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}}"
[[ -n "$REGION" ]] || die "no AWS region: pass --region or set AWS_REGION"
ok "AWS account ****${ACCOUNT: -4}, profile ${AWS_PROFILE:-default}, region ${REGION}"

ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"' EXIT
if ! WHOAMI="$(rosa whoami -o json 2>"$ERR_FILE")"; then
  err="$(grep -v '^W:' "$ERR_FILE" | head -1)"
  case "$err" in
  *"root account is not supported"*)
    fail "the AWS profile uses root-account keys, which rosa rejects" \
      "create an IAM user with AdministratorAccess, add a CLI access key, aws configure --profile <name>" ;;
  *)
    fail "rosa whoami failed: ${err:-unknown error}" \
      "rosa login --use-auth-code   (log in as the Red Hat account the AWS account is linked to)" ;;
  esac
  exit 1
fi
ORG_ID="$(jq -r '."OCM Organization ID"' <<<"$WHOAMI")"
ORG_NAME="$(jq -r '."OCM Organization Name"' <<<"$WHOAMI")"
ok "rosa logged in as $(jq -r '."OCM Account Username"' <<<"$WHOAMI") (org: ${ORG_NAME})"

if rosa list ocm-roles -o json 2>/dev/null | jq -e 'any(.[]?; .Linked == "Yes")' >/dev/null; then
  ok "OCM role linked"
else
  fail "no OCM role linked to org '${ORG_NAME}'" "rosa create ocm-role --mode auto --yes"
fi

if rosa list user-roles -o json 2>/dev/null | jq -e 'any(.[]?; .Linked == "Yes")' >/dev/null; then
  ok "user role linked"
else
  fail "no user role linked to your Red Hat user" "rosa create user-role --mode auto --yes"
fi

TOKEN="$(rosa token 2>/dev/null || true)"
LINKED="$(curl -s --max-time 30 -H "Authorization: Bearer ${TOKEN}" \
  "${OCM_API}/api/accounts_mgmt/v1/organizations/${ORG_ID}/quota_cost?fetchCloudAccounts=true" |
  jq --arg a "$ACCOUNT" '[.items[]?.cloud_accounts[]? | select(.cloud_account_id == $a)] | length' 2>/dev/null || echo 0)"
if [[ "$LINKED" =~ ^[0-9]+$ ]] && ((LINKED > 0)); then
  ok "AWS account linked to org '${ORG_NAME}' for billing"
else
  fail "AWS account ****${ACCOUNT: -4} is not linked to org '${ORG_NAME}' for billing" \
    "AWS console > Red Hat OpenShift Service on AWS > Get started > enable ROSA, then 'Continue to Red Hat'" \
    "log in there with a Red Hat account in org '${ORG_NAME}' (or 'rosa login' as the account you linked)"
fi

if rosa verify quota --region "$REGION" >/dev/null 2>&1; then
  ok "AWS quotas sufficient in ${REGION}"
else
  fail "AWS quotas are too low for ROSA in ${REGION}" "rosa verify quota --region ${REGION}   (shows which quota), then request an increase"
fi

if [[ -n "$VERSION" ]]; then
  if rosa list versions --hosted-cp -o json 2>/dev/null | jq -e --arg v "$VERSION" 'any(.[]?; .raw_id == $v and .enabled == true)' >/dev/null; then
    ok "OpenShift ${VERSION} offered for HCP"
  else
    fail "OpenShift ${VERSION} is not offered for HCP" "rosa list versions --hosted-cp   (pick one and set openshift_version in terraform.tfvars)"
  fi
else
  echo "  SKIP  OpenShift version (no --version and no openshift_version in terraform.tfvars)"
fi

echo ""
if ((FAILS)); then
  echo "${FAILS} check(s) failed."
  exit 1
fi
echo "All checks passed. Terraform's rhcs provider can use this rosa login:"
echo "  export RHCS_CLIENT_ID=ocm-cli RHCS_TOKEN=\"\$(rosa token --refresh)\""

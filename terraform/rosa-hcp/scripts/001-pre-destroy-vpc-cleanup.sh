#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="${SCRIPT_DIR}/.."

DRY_RUN=0
REGION=""
POLL_TIMEOUT=120
POLL_INTERVAL=5

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Clean up orphan AWS resources (load balancers, ENIs, security groups) in VPCs
managed by the rosa-hcp Terraform module. Run this before 'terraform destroy'
to prevent VPC deletion failures.

VPC IDs are read from: terraform -chdir=${TF_DIR} output -json by_cluster

Options:
  --dry-run       Show what would be deleted without acting
  --region REGION Override AWS region (default: from terraform output)
  -h, --help      Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --dry-run)
    DRY_RUN=1
    shift
    ;;
  --region)
    [[ -n "${2:-}" ]] || die "--region requires a value"
    REGION="$2"
    shift 2
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

command -v aws >/dev/null 2>&1 || die "aws CLI not found"
command -v jq >/dev/null 2>&1 || die "jq not found"
command -v terraform >/dev/null 2>&1 || die "terraform not found"

# --- Resolve VPC IDs and region from terraform output ---

BY_CLUSTER="$(terraform -chdir="${TF_DIR}" output -json by_cluster 2>/dev/null)" \
  || die "failed to read terraform output 'by_cluster' — is the rosa-hcp module initialized?"

VPC_IDS=()
CLUSTER_NAMES=()
while IFS= read -r key; do
  vpc_id="$(echo "${BY_CLUSTER}" | jq -r --arg k "$key" '.[$k].vpc_id')"
  VPC_IDS+=("$vpc_id")
  CLUSTER_NAMES+=("$key")
done < <(echo "${BY_CLUSTER}" | jq -r 'keys[]')

[[ ${#VPC_IDS[@]} -gt 0 ]] || die "no VPCs found in terraform output"

if [[ -z "${REGION}" ]]; then
  REGION="$(aws configure get region 2>/dev/null)" \
    || die "could not determine AWS region — pass --region or set AWS_DEFAULT_REGION"
fi

AWS=(aws --region "${REGION}" --output json)

echo "=== Pre-destroy VPC cleanup ==="
echo "Region:  ${REGION}"
echo "VPCs:    ${#VPC_IDS[@]}"
echo "Dry run: $( (( DRY_RUN )) && echo "yes" || echo "no" )"
echo ""

ERRORS=0
TOTAL_DELETED=0

action() {
  if (( DRY_RUN )); then
    echo "  [dry-run] would $*"
  else
    echo "  $*"
  fi
}

# --- Per-VPC cleanup ---

for i in "${!VPC_IDS[@]}"; do
  vpc="${VPC_IDS[$i]}"
  cluster="${CLUSTER_NAMES[$i]}"
  vpc_deleted=0

  echo "--- ${cluster} (${vpc}) ---"

  # 1. Delete NLB/ALB load balancers
  lb_arns="$("${AWS[@]}" elbv2 describe-load-balancers \
    --query "LoadBalancers[?VpcId=='${vpc}'].LoadBalancerArn" 2>/dev/null | jq -r '.[]')" || lb_arns=""

  for arn in ${lb_arns}; do
    action "delete load balancer ${arn}"
    if (( ! DRY_RUN )); then
      "${AWS[@]}" elbv2 delete-load-balancer --load-balancer-arn "${arn}" 2>/dev/null || true
    fi
    (( vpc_deleted++ )) || true
  done

  # 1b. Delete classic ELBs
  classic_lbs="$("${AWS[@]}" elb describe-load-balancers \
    --query "LoadBalancerDescriptions[?VPCId=='${vpc}'].LoadBalancerName" 2>/dev/null | jq -r '.[]')" || classic_lbs=""

  for name in ${classic_lbs}; do
    action "delete classic load balancer ${name}"
    if (( ! DRY_RUN )); then
      "${AWS[@]}" elb delete-load-balancer --load-balancer-name "${name}" 2>/dev/null || true
    fi
    (( vpc_deleted++ )) || true
  done

  # 2. Wait for LB ENIs to release
  if [[ -n "${lb_arns}${classic_lbs}" ]] && (( ! DRY_RUN )); then
    echo "  waiting for load balancer ENIs to release..."
    elapsed=0
    while (( elapsed < POLL_TIMEOUT )); do
      lb_enis="$("${AWS[@]}" ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=${vpc}" "Name=interface-type,Values=network_load_balancer,elastic_load_balancing" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' 2>/dev/null | jq -r '.[]')" || lb_enis=""
      [[ -z "${lb_enis}" ]] && break
      sleep "${POLL_INTERVAL}"
      (( elapsed += POLL_INTERVAL ))
    done
    if [[ -n "${lb_enis}" ]]; then
      echo "  warning: LB ENIs still present after ${POLL_TIMEOUT}s — continuing anyway"
    fi
  fi

  # 3. Detach and delete ENIs
  eni_ids="$("${AWS[@]}" ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=${vpc}" \
    --query 'NetworkInterfaces[].[NetworkInterfaceId,Attachment.AttachmentId,Status]' 2>/dev/null \
    | jq -r '.[] | @tsv')" || eni_ids=""

  while IFS=$'\t' read -r eni_id attachment_id status; do
    [[ -z "${eni_id}" ]] && continue
    action "delete ENI ${eni_id} (status: ${status})"
    if (( ! DRY_RUN )); then
      if [[ "${status}" == "in-use" && "${attachment_id}" != "null" && -n "${attachment_id}" ]]; then
        "${AWS[@]}" ec2 detach-network-interface --attachment-id "${attachment_id}" --force 2>/dev/null || true
        sleep 2
      fi
      "${AWS[@]}" ec2 delete-network-interface --network-interface-id "${eni_id}" 2>/dev/null || {
        echo "  warning: failed to delete ENI ${eni_id}"
        (( ERRORS++ )) || true
      }
    fi
    (( vpc_deleted++ )) || true
  done <<< "${eni_ids}"

  # 4. Revoke SG rules (break circular references before deletion)
  sg_ids="$("${AWS[@]}" ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${vpc}" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" 2>/dev/null | jq -r '.[]')" || sg_ids=""

  for sg in ${sg_ids}; do
    ingress_rules="$("${AWS[@]}" ec2 describe-security-groups \
      --group-ids "${sg}" \
      --query 'SecurityGroups[0].IpPermissions' 2>/dev/null)" || ingress_rules="[]"
    if [[ "${ingress_rules}" != "[]" && "${ingress_rules}" != "null" ]]; then
      if (( ! DRY_RUN )); then
        "${AWS[@]}" ec2 revoke-security-group-ingress --group-id "${sg}" \
          --ip-permissions "${ingress_rules}" 2>/dev/null || true
      fi
    fi

    egress_rules="$("${AWS[@]}" ec2 describe-security-groups \
      --group-ids "${sg}" \
      --query 'SecurityGroups[0].IpPermissionsEgress' 2>/dev/null)" || egress_rules="[]"
    if [[ "${egress_rules}" != "[]" && "${egress_rules}" != "null" ]]; then
      if (( ! DRY_RUN )); then
        "${AWS[@]}" ec2 revoke-security-group-egress --group-id "${sg}" \
          --ip-permissions "${egress_rules}" 2>/dev/null || true
      fi
    fi
  done

  # 5. Delete security groups
  for sg in ${sg_ids}; do
    action "delete security group ${sg}"
    if (( ! DRY_RUN )); then
      "${AWS[@]}" ec2 delete-security-group --group-id "${sg}" 2>/dev/null || {
        echo "  warning: failed to delete SG ${sg}"
        (( ERRORS++ )) || true
      }
    fi
    (( vpc_deleted++ )) || true
  done

  TOTAL_DELETED=$(( TOTAL_DELETED + vpc_deleted ))
  if (( vpc_deleted == 0 )); then
    echo "  (clean — no orphan resources found)"
  fi
  echo ""
done

# --- Summary ---

echo "=== Summary ==="
echo "Resources cleaned: ${TOTAL_DELETED}"
if (( ERRORS > 0 )); then
  echo "Errors: ${ERRORS} (re-run or check manually)"
  exit 1
fi
echo "Done. Safe to run 'terraform destroy'."

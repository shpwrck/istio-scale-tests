#!/usr/bin/env bash
# ci-dry-run-skip: needs AWS credentials for resource listing
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
  --region REGION Override AWS region (default: the VPCs' region in terraform state, then
                  \$AWS_REGION, \$AWS_DEFAULT_REGION, aws config)
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

# --- Selection logic (pure jq over raw AWS/terraform JSON) ---

# Region of each aws_vpc in `terraform show -json` (from arn:aws:ec2:<region>:<acct>:vpc/<id>).
state_vpc_regions() {
  jq -r '[.. | objects | select(.type? == "aws_vpc") | .values.arn? // empty | split(":")[3]] | unique | .[]'
}

# describe-network-interfaces JSON -> "<eni> <action> <attachment|-> <status> <detail>" per ENI.
# Action: instance (a node; removed with the cluster), requester (owned by an AWS service such as a
# NAT gateway, load balancer or VPC endpoint; AWS refuses to delete it), or delete.
eni_plan() {
  jq -r '.NetworkInterfaces[] | [
      .NetworkInterfaceId,
      (if .Attachment.InstanceId then "instance" elif .RequesterManaged == true then "requester" else "delete" end),
      (.Attachment.AttachmentId // "-"),
      (.Status // "-"),
      (.Attachment.InstanceId // .InterfaceType // "-")
    ] | @tsv'
}

# ENIs that stay after step 3 (the ones eni_plan does not delete).
eni_remaining() {
  jq '{NetworkInterfaces: [.NetworkInterfaces[] | select(.Attachment.InstanceId or .RequesterManaged == true)]}'
}

# stdin: describe-security-groups JSON, then remaining-ENIs JSON.
# -> "<sg> delete|in-use" per non-default SG; in-use = attached to a remaining ENI.
sg_plan() {
  jq -rs '.[0] as $sgs | ([.[1].NetworkInterfaces[].Groups[]?.GroupId] | unique) as $used
    | $sgs.SecurityGroups[] | select(.GroupName != "default") | .GroupId as $g
    | [$g, (if any($used[]; . == $g) then "in-use" else "delete" end)] | @tsv'
}

# stdin: describe-security-groups JSON. $1 = SG id, $2 = IpPermissions|IpPermissionsEgress,
# $3 = space-separated SGs being deleted. Prints the rules to revoke, or nothing:
# every rule of a deleted SG; on an in-use SG only the references to deleted SGs.
sg_revoke_rules() {
  jq -c --arg g "$1" --arg field "$2" --arg del "$3" '
    ($del | split(" ") | map(select(. != ""))) as $del
    | .SecurityGroups[] | select(.GroupId == $g) | (.[$field] // []) as $perms
    | (if any($del[]; . == $g) then $perms
       else [$perms[] | ((.UserIdGroupPairs // []) | map(select(.GroupId as $p | any($del[]; . == $p)))) as $pairs
             | select($pairs | length > 0)
             | del(.IpRanges, .Ipv6Ranges, .PrefixListIds) | .UserIdGroupPairs = $pairs]
       end)
    | select(length > 0)'
}

# --- Resolve VPC IDs from terraform output, or from state after a partial destroy ---

STATE_JSON="$(terraform -chdir="${TF_DIR}" show -json 2>/dev/null)" || STATE_JSON="{}"

VPC_IDS=()
CLUSTER_NAMES=()
if BY_CLUSTER="$(terraform -chdir="${TF_DIR}" output -json by_cluster 2>/dev/null)"; then
  while IFS= read -r key; do
    VPC_IDS+=("$(echo "${BY_CLUSTER}" | jq -r --arg k "$key" '.[$k].vpc_id')")
    CLUSTER_NAMES+=("$key")
  done < <(echo "${BY_CLUSTER}" | jq -r 'keys[]')
else
  # Outputs are gone once a destroy has started; the VPCs are still in state.
  while IFS=$'\t' read -r key vpc_id; do
    VPC_IDS+=("$vpc_id")
    CLUSTER_NAMES+=("$key")
  done < <(echo "${STATE_JSON}" |
    jq -r '.. | objects | select(.type? == "aws_vpc") | [(.address | capture("\\[\"(?<k>[^\"]+)\"\\]").k // .address), .values.id] | @tsv')
fi

[[ ${#VPC_IDS[@]} -gt 0 ]] || die "no VPCs found in terraform output or state — is the rosa-hcp module initialized?"

if [[ -z "${REGION}" ]]; then
  # The VPCs' own ARNs say where the clusters are; AWS_REGION may point elsewhere.
  state_regions="$(echo "${STATE_JSON}" | state_vpc_regions 2>/dev/null)" || state_regions=""
  if [[ $(grep -c . <<<"${state_regions}") -gt 1 ]]; then
    die "VPCs in state span several regions ($(echo "${state_regions}" | tr '\n' ' ')) — pass --region"
  fi
  REGION="${state_regions:-${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}}"
  [[ -n "${REGION}" ]] || die "could not determine AWS region — pass --region or set AWS_REGION"
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

  # A VPC ID from state that this region does not know means the region is wrong; every
  # lookup below would come back empty and the VPC would look clean.
  if ! "${AWS[@]}" ec2 describe-vpcs --vpc-ids "${vpc}" >/dev/null 2>&1; then
    echo "  error: VPC ${vpc} not found in ${REGION} (wrong region? pass --region)"
    (( ERRORS++ )) || true
    echo ""
    continue
  fi

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

  # 3. Detach and delete orphan ENIs. Skip node ENIs (removed with the cluster) and
  # requester-managed ENIs (NAT gateway, load balancers, VPC endpoints; AWS refuses).
  enis_json="$("${AWS[@]}" ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=${vpc}" 2>/dev/null)" || enis_json='{"NetworkInterfaces":[]}'

  while IFS=$'\t' read -r eni_id eni_action attachment_id status detail; do
    [[ -z "${eni_id}" ]] && continue
    case "${eni_action}" in
    instance)
      echo "  skip ENI ${eni_id} (attached to instance ${detail}; removed with the cluster)"
      continue
      ;;
    requester)
      echo "  skip ENI ${eni_id} (requester-managed ${detail}; removed with its owner)"
      continue
      ;;
    esac
    action "delete ENI ${eni_id} (status: ${status})"
    if (( ! DRY_RUN )); then
      if [[ "${status}" == "in-use" && "${attachment_id}" != "-" ]]; then
        "${AWS[@]}" ec2 detach-network-interface --attachment-id "${attachment_id}" --force 2>/dev/null || true
        sleep 2
      fi
      "${AWS[@]}" ec2 delete-network-interface --network-interface-id "${eni_id}" 2>/dev/null || {
        echo "  warning: failed to delete ENI ${eni_id}"
        (( ERRORS++ )) || true
      }
    fi
    (( vpc_deleted++ )) || true
  done < <(echo "${enis_json}" | eni_plan)

  # 4. Security groups still attached to an ENI belong to something alive (nodes, the
  # PrivateLink endpoint): leave them. The rest are orphans to delete.
  sgs_json="$("${AWS[@]}" ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${vpc}" 2>/dev/null)" || sgs_json='{"SecurityGroups":[]}'
  if (( DRY_RUN )); then
    remaining_json="$(echo "${enis_json}" | eni_remaining)" || remaining_json="${enis_json}"
  else
    # Re-read: an ENI that failed to delete still holds its groups.
    remaining_json="$("${AWS[@]}" ec2 describe-network-interfaces \
      --filters "Name=vpc-id,Values=${vpc}" 2>/dev/null)" || remaining_json="${enis_json}"
  fi

  sg_delete=""
  sg_in_use=""
  while IFS=$'\t' read -r sg sg_action; do
    [[ -z "${sg}" ]] && continue
    if [[ "${sg_action}" == "delete" ]]; then
      sg_delete="${sg_delete} ${sg}"
    else
      sg_in_use="${sg_in_use} ${sg}"
    fi
  done < <(printf '%s\n%s\n' "${sgs_json}" "${remaining_json}" | sg_plan)

  # 5. Revoke rules that would block deletion: all rules of the orphans, and only the
  # references to orphans on in-use groups (their other rules keep the cluster working).
  for sg in ${sg_delete} ${sg_in_use}; do
    for field in IpPermissions IpPermissionsEgress; do
      rules="$(echo "${sgs_json}" | sg_revoke_rules "${sg}" "${field}" "${sg_delete}")" || rules=""
      [[ -n "${rules}" ]] || continue
      if (( DRY_RUN )); then
        if [[ " ${sg_delete} " == *" ${sg} "* ]]; then
          echo "  [dry-run] would revoke ${field} rules on ${sg}"
        else
          echo "  [dry-run] would revoke ${field} references to deleted groups on ${sg}"
        fi
        continue
      fi
      if [[ "${field}" == "IpPermissions" ]]; then
        "${AWS[@]}" ec2 revoke-security-group-ingress --group-id "${sg}" --ip-permissions "${rules}" >/dev/null 2>&1 || true
      else
        "${AWS[@]}" ec2 revoke-security-group-egress --group-id "${sg}" --ip-permissions "${rules}" >/dev/null 2>&1 || true
      fi
    done
  done

  # 6. Delete the orphan security groups
  for sg in ${sg_in_use}; do
    echo "  skip SG ${sg} (in use)"
  done
  for sg in ${sg_delete}; do
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

#!/usr/bin/env bash
# ci-dry-run-skip: needs AWS credentials for resource listing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="${SCRIPT_DIR}/.."

DRY_RUN=0
REGION=""
BY_CLUSTER_JSON=""
DELETE_INTERFACE_ENDPOINTS=0
POLL_TIMEOUT=120
POLL_INTERVAL=5

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Clean up orphan AWS resources (load balancers, ENIs, security groups and, on
request, interface VPC endpoints) in VPCs managed by the rosa-hcp Terraform
module. Run this before 'terraform destroy' to prevent VPC deletion failures.

VPC IDs come from every source available, merged:
  - the saved copy given with --by-cluster-json (save it right after apply:
    terraform -chdir=${TF_DIR} output -json by_cluster > <file>);
  - terraform -chdir=${TF_DIR} output -json by_cluster;
  - the aws_vpc resources in terraform state.
After 'terraform destroy -target=module.rosa_hcp' the by_cluster output is empty,
so the saved copy and the state are what still name the VPCs. An exported
TF_WORKSPACE is ignored: rosa-hcp uses only the default workspace.

Options:
  --by-cluster-json FILE        Saved 'terraform output -json by_cluster'
  --delete-interface-endpoints  Also delete interface VPC endpoints that Terraform
                                does not manage (ROSA's private-router endpoint),
                                but only in a VPC with no instances left. Use it
                                after the clusters are destroyed: while a cluster
                                runs, its workers reach the hosted control plane
                                through that endpoint.
  --dry-run                     Show what would be deleted without acting
  --region REGION               Override AWS region (default: the VPCs' region from
                                terraform state or the saved by_cluster copy, then
                                \$AWS_REGION, \$AWS_DEFAULT_REGION, aws config)
  -h, --help                    Show this help

A listed VPC that AWS no longer knows counts as already deleted when the region
is certain (--region, or read from the state or the saved copy) or another listed
VPC was found there; otherwise it is an error (probably the wrong region).
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
  --by-cluster-json)
    [[ -n "${2:-}" ]] || die "--by-cluster-json requires a file"
    BY_CLUSTER_JSON="$2"
    shift 2
    ;;
  --delete-interface-endpoints)
    DELETE_INTERFACE_ENDPOINTS=1
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

command -v aws >/dev/null 2>&1 || die "aws CLI not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

# rosa-hcp has only the default workspace (terraform/platform reads ../rosa-hcp/terraform.tfstate
# by path). A TF_WORKSPACE exported for the platform's 'rosa' workspace would make the state and
# output below read as empty.
if [[ -n "${TF_WORKSPACE:-}" ]]; then
  [[ "${TF_WORKSPACE}" == "default" ]] ||
    echo "note: ignoring TF_WORKSPACE=${TF_WORKSPACE}: terraform/rosa-hcp uses only the default workspace" >&2
  unset TF_WORKSPACE
fi
HAVE_TERRAFORM=1
if ! command -v terraform >/dev/null 2>&1; then
  [[ -n "${BY_CLUSTER_JSON}" ]] || die "terraform not found (or pass --by-cluster-json)"
  HAVE_TERRAFORM=0
  echo "warning: terraform not found; using only ${BY_CLUSTER_JSON}" >&2
fi

# --- Selection logic (pure jq over raw AWS/terraform JSON) ---

# Region of each aws_vpc in `terraform show -json` (from arn:aws:ec2:<region>:<acct>:vpc/<id>).
state_vpc_regions() {
  jq -r '[.. | objects | select(.type? == "aws_vpc") | .values.arn? // empty | split(":")[3]] | unique | .[]'
}

# `terraform show -json` -> "<cluster key> <vpc id>" per aws_vpc.
state_vpcs() {
  jq -r '.. | objects | select(.type? == "aws_vpc") | [(.address | capture("\\[\"(?<k>[^\"]+)\"\\]").k // .address), .values.id] | @tsv'
}

# `terraform show -json` -> space-separated ids of the VPC endpoints Terraform manages.
state_endpoint_ids() {
  jq -r '[.. | objects | select(.type? == "aws_vpc_endpoint") | .values.id? // empty] | join(" ")'
}

# by_cluster JSON (the output, or its saved copy) -> "<cluster key> <vpc id>" per cluster.
by_cluster_vpcs() {
  jq -r 'to_entries[] | select((.value.vpc_id? // "") | length > 0) | [.key, .value.vpc_id] | @tsv'
}

# by_cluster JSON -> the aws_region each entry records (older copies have none).
by_cluster_regions() {
  jq -r '[.[] | .aws_region? // empty] | unique | .[]'
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

# ENIs that stay after step 3 (the ones eni_plan does not delete), minus the
# comma-separated ENIs in $1 (those of interface endpoints being deleted).
eni_remaining() {
  jq --arg drop "${1:-}" '($drop | split(",") | map(select(. != ""))) as $d
    | {NetworkInterfaces: [.NetworkInterfaces[]
        | select(.Attachment.InstanceId or .RequesterManaged == true)
        | select(.NetworkInterfaceId as $id | any($d[]; . == $id) | not)]}'
}

# describe-vpc-endpoints JSON -> "<endpoint> <action> <service> <eni,eni...>" per endpoint.
# $1 = space-separated endpoint ids Terraform manages. Action: managed (Terraform deletes it),
# gone (already deleting/deleted), or delete.
endpoint_plan() {
  jq -r --arg managed "${1:-}" '($managed | split(" ") | map(select(. != ""))) as $m
    | .VpcEndpoints[] | .VpcEndpointId as $id | ((.State // "") | ascii_downcase) as $s
    | [$id,
       (if any($m[]; . == $id) then "managed"
        elif ($s == "deleted" or $s == "deleting") then "gone"
        else "delete" end),
       (.ServiceName // "-"),
       ((.NetworkInterfaceIds // []) | join(","))
      ] | @tsv'
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

# --- Resolve VPC IDs: saved by_cluster copy, terraform output and state, merged ---

STATE_JSON="{}"
BY_CLUSTER=""
if ((HAVE_TERRAFORM)); then
  STATE_JSON="$(terraform -chdir="${TF_DIR}" show -json 2>/dev/null)" || STATE_JSON="{}"
  BY_CLUSTER="$(terraform -chdir="${TF_DIR}" output -json by_cluster 2>/dev/null)" || BY_CLUSTER=""
fi
SAVED_JSON=""
if [[ -n "${BY_CLUSTER_JSON}" ]]; then
  [[ -r "${BY_CLUSTER_JSON}" ]] || die "--by-cluster-json: cannot read ${BY_CLUSTER_JSON}"
  SAVED_JSON="$(cat "${BY_CLUSTER_JSON}")"
  echo "${SAVED_JSON}" | jq -e 'type == "object"' >/dev/null 2>&1 ||
    die "--by-cluster-json: ${BY_CLUSTER_JSON} is not a by_cluster JSON object"
fi

VPC_IDS=()
CLUSTER_NAMES=()
VPC_SOURCES=()
declare -A VPC_INDEX=()
add_vpc() {
  local key="$1" vpc="$2" src="$3" idx
  [[ -n "${vpc}" && "${vpc}" != "null" ]] || return 0
  if [[ -n "${VPC_INDEX["${vpc}"]+x}" ]]; then
    idx="${VPC_INDEX["${vpc}"]}"
    [[ ",${VPC_SOURCES[idx]}," == *",${src},"* ]] || VPC_SOURCES[idx]+=",${src}"
    return 0
  fi
  VPC_INDEX["${vpc}"]=${#VPC_IDS[@]}
  VPC_IDS+=("${vpc}")
  CLUSTER_NAMES+=("${key}")
  VPC_SOURCES+=("${src}")
}

n_saved=0
n_output=0
n_state=0
if [[ -n "${SAVED_JSON}" ]]; then
  while IFS=$'\t' read -r key vpc_id; do
    [[ -n "${key}" ]] || continue
    add_vpc "${key}" "${vpc_id}" saved
    n_saved=$((n_saved + 1))
  done < <(echo "${SAVED_JSON}" | by_cluster_vpcs)
fi
if [[ -n "${BY_CLUSTER}" ]]; then
  while IFS=$'\t' read -r key vpc_id; do
    [[ -n "${key}" ]] || continue
    add_vpc "${key}" "${vpc_id}" output
    n_output=$((n_output + 1))
  done < <(echo "${BY_CLUSTER}" | by_cluster_vpcs 2>/dev/null)
fi
# Outputs are empty or gone once a destroy has started; the VPCs are still in state.
while IFS=$'\t' read -r key vpc_id; do
  [[ -n "${key}" ]] || continue
  add_vpc "${key}" "${vpc_id}" state
  n_state=$((n_state + 1))
done < <(echo "${STATE_JSON}" | state_vpcs 2>/dev/null)

[[ ${#VPC_IDS[@]} -gt 0 ]] || die "no VPCs found in the saved by_cluster copy, terraform output or state — is the rosa-hcp module initialized?"

# Check the saved copy against what terraform knows; the merged list covers both.
if [[ -n "${SAVED_JSON}" ]] && ((n_state > 0)); then
  for i in "${!VPC_IDS[@]}"; do
    case ",${VPC_SOURCES[$i]}," in
    *,saved,*) [[ ",${VPC_SOURCES[$i]}," == *,state,* ]] ||
      echo "note: ${VPC_IDS[$i]} (${CLUSTER_NAMES[$i]}) is in the saved copy but not in terraform state (destroyed already, or state lost)" ;;
    *) echo "warning: ${VPC_IDS[$i]} (${CLUSTER_NAMES[$i]}) is in terraform state but not in the saved copy (stale copy?)" ;;
    esac
  done
fi

REGION_CERTAIN=0
if [[ -n "${REGION}" ]]; then
  REGION_CERTAIN=1
else
  # The VPCs' own ARNs (or the region saved with them) say where the clusters are;
  # AWS_REGION may point elsewhere.
  known_regions="$(
    {
      echo "${STATE_JSON}" | state_vpc_regions 2>/dev/null || true
      [[ -z "${SAVED_JSON}" ]] || echo "${SAVED_JSON}" | by_cluster_regions 2>/dev/null || true
      [[ -z "${BY_CLUSTER}" ]] || echo "${BY_CLUSTER}" | by_cluster_regions 2>/dev/null || true
    } | grep . | sort -u
  )" || known_regions=""
  if [[ $(grep -c . <<<"${known_regions}") -gt 1 ]]; then
    die "the VPCs span several regions ($(echo "${known_regions}" | tr '\n' ' ')) — pass --region"
  fi
  if [[ -n "${known_regions}" ]]; then
    REGION="${known_regions}"
    REGION_CERTAIN=1
  else
    REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
  fi
  [[ -n "${REGION}" ]] || die "could not determine AWS region — pass --region or set AWS_REGION"
fi

AWS=(aws --region "${REGION}" --output json)

echo "=== Pre-destroy VPC cleanup ==="
echo "Region:  ${REGION}$( ((REGION_CERTAIN)) || echo " (from the environment)")"
echo "VPCs:    ${#VPC_IDS[@]} (saved copy: ${n_saved}, terraform output: ${n_output}, state: ${n_state})"
echo "Interface endpoints: $( ((DELETE_INTERFACE_ENDPOINTS)) && echo "delete unmanaged ones in VPCs without instances" || echo "report only")"
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

# --- Verify the list against AWS before touching anything ---

# found | missing | error per VPC. A wrong region makes every lookup below come back empty,
# so a missing VPC only counts as deleted when the region is certain or another VPC was found.
VPC_STATUS=()
FOUND_ANY=0
for i in "${!VPC_IDS[@]}"; do
  if err="$("${AWS[@]}" ec2 describe-vpcs --vpc-ids "${VPC_IDS[$i]}" 2>&1 >/dev/null)"; then
    VPC_STATUS[i]="found"
    FOUND_ANY=1
  elif [[ "${err}" == *InvalidVpcID.NotFound* ]]; then
    VPC_STATUS[i]="missing"
  else
    VPC_STATUS[i]="error: $(grep -v '^[[:space:]]*$' <<<"${err}" | head -1)"
  fi
done

TF_ENDPOINT_IDS="$(echo "${STATE_JSON}" | state_endpoint_ids 2>/dev/null)" || TF_ENDPOINT_IDS=""

# --- Per-VPC cleanup ---

for i in "${!VPC_IDS[@]}"; do
  vpc="${VPC_IDS[$i]}"
  cluster="${CLUSTER_NAMES[$i]}"
  vpc_deleted=0

  echo "--- ${cluster} (${vpc}; from ${VPC_SOURCES[$i]}) ---"

  case "${VPC_STATUS[$i]}" in
  found) ;;
  missing)
    if ((REGION_CERTAIN || FOUND_ANY)); then
      echo "  already deleted (not found in ${REGION})"
    else
      echo "  error: VPC ${vpc} not found in ${REGION} (wrong region? pass --region)"
      (( ERRORS++ )) || true
    fi
    echo ""
    continue
    ;;
  *)
    echo "  error: cannot look up VPC ${vpc}: ${VPC_STATUS[$i]#error: }"
    (( ERRORS++ )) || true
    echo ""
    continue
    ;;
  esac

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

  # 1c. Interface VPC endpoints Terraform does not manage (ROSA's private-router endpoint).
  # Their requester-managed ENIs, and the <cluster-id>-vpce-private-router security group
  # attached to them, block the subnet and VPC deletes if ROSA leaves them behind.
  eps_json="$("${AWS[@]}" ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${vpc}" "Name=vpc-endpoint-type,Values=Interface" 2>/dev/null)" ||
    eps_json='{"VpcEndpoints":[]}'
  ep_delete=""
  ep_enis=""
  ep_hold=""
  if (( DELETE_INTERFACE_ENDPOINTS )); then
    # Workers reach their hosted control plane through the endpoint: leave it while any
    # instance is left in the VPC (or when that cannot be checked).
    live="$("${AWS[@]}" ec2 describe-instances \
      --filters "Name=vpc-id,Values=${vpc}" "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
      --query 'Reservations[].Instances[].InstanceId' 2>/dev/null | jq -r 'length')" || live="unknown"
    [[ "${live}" == "0" ]] || ep_hold="${live}"
  fi
  while IFS=$'\t' read -r ep_id ep_action ep_service ep_eni_list; do
    [[ -n "${ep_id}" ]] || continue
    case "${ep_action}" in
    managed) echo "  skip endpoint ${ep_id} (${ep_service}; managed by terraform)" ;;
    gone) echo "  skip endpoint ${ep_id} (${ep_service}; already deleting)" ;;
    delete)
      if (( ! DELETE_INTERFACE_ENDPOINTS )); then
        echo "  note: interface endpoint ${ep_id} (${ep_service}) left in place; it goes with the cluster."
        echo "        If 'terraform destroy' then fails on this VPC, re-run with --delete-interface-endpoints."
      elif [[ -n "${ep_hold}" ]]; then
        echo "  skip endpoint ${ep_id} (${ep_service}): ${ep_hold} instance(s) still in the VPC; re-run once the cluster is gone"
      else
        action "delete interface endpoint ${ep_id} (${ep_service})"
        ep_delete="${ep_delete} ${ep_id}"
        ep_enis="${ep_enis},${ep_eni_list}"
        (( vpc_deleted++ )) || true
      fi
      ;;
    esac
  done < <(echo "${eps_json}" | endpoint_plan "${TF_ENDPOINT_IDS}")

  if [[ -n "${ep_delete}" ]] && (( ! DRY_RUN )); then
    # shellcheck disable=SC2086 # word-split the endpoint id list
    del_out="$("${AWS[@]}" ec2 delete-vpc-endpoints --vpc-endpoint-ids ${ep_delete} 2>&1)" || del_out='{"Unsuccessful":[{"Error":{"Message":"delete-vpc-endpoints failed"}}]}'
    failed_eps="$(echo "${del_out}" | jq -r '(.Unsuccessful // [])[] | "\(.ResourceId // "-"): \(.Error.Message // "unknown")"' 2>/dev/null)" ||
      failed_eps="${del_out}"
    if [[ -n "${failed_eps}" ]]; then
      echo "  warning: endpoint delete failed: ${failed_eps}"
      (( ERRORS++ )) || true
    fi
    echo "  waiting for endpoint ENIs to release..."
    elapsed=0
    while (( elapsed < POLL_TIMEOUT )); do
      ep_left="$("${AWS[@]}" ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=${vpc}" "Name=interface-type,Values=vpc_endpoint" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' 2>/dev/null | jq -r '.[]')" || ep_left=""
      [[ -z "${ep_left}" ]] && break
      sleep "${POLL_INTERVAL}"
      (( elapsed += POLL_INTERVAL ))
    done
    if [[ -n "${ep_left}" ]]; then
      echo "  warning: endpoint ENIs still present after ${POLL_TIMEOUT}s — continuing anyway"
    fi
  fi

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
    # The ENIs of endpoints that would be deleted would release their groups too.
    remaining_json="$(echo "${enis_json}" | eni_remaining "${ep_enis}")" || remaining_json="${enis_json}"
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

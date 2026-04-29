#!/usr/bin/env bash
# List / plan AWS service quotas for multiple ROSA HCP clusters (VPC, NAT, EIPs,
# IAM roles, OIDC providers).
#
# Modes:
#   check — print current effective quotas (tables)
#   plan  — given intended cluster count, compare to assumptions and emit increase CLI
#
# Requires: aws CLI v2, jq, bash 4+, awk (for floats)
# Credentials: standard AWS provider chain.

set -euo pipefail

usage() {
	cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  check              Print current effective service quotas (tabular).
  plan               For --clusters N, estimate required quotas vs current and print
                     aws service-quotas request-service-quota-increase commands where needed.

Options:
  --profile NAME     AWS CLI profile (optional).
  --region REGION    Region for regional VPC/EC2 quotas (default: AWS_REGION or us-east-1).
  --clusters N       Required for plan: number of ROSA HCP clusters (each own VPC/OIDC).
  --buffer N         Extra headroom added to suggested --desired-value (default: 2).

Plan mode reads ../quota-assumptions.env (override with QUOTA_ASSUMPTIONS_FILE). Provenance and
refresh steps: terraform/rosa-hcp/docs/quota-assumptions.source.md (sync UPSTREAM_MODULE_VERSION
with main.tf module version).

Environment:
  AWS_REGION             Default region when --region is omitted.
  QUOTA_ASSUMPTIONS_FILE Optional path to quota-assumptions.env (plan mode only).

Requires: aws CLI v2, jq, awk, bash 4+
EOF
}

PROFILE=""
REGION="${AWS_REGION:-us-east-1}"
MODE=""
CLUSTER_COUNT=""
BUFFER=2

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
	case "$1" in
	check | plan)
		[[ -n "$MODE" ]] && die "duplicate command: $1"
		MODE="$1"
		shift
		;;
	--profile)
		PROFILE="${2:?}"
		shift 2
		;;
	--region)
		REGION="${2:?}"
		shift 2
		;;
	--clusters)
		CLUSTER_COUNT="${2:?}"
		shift 2
		;;
	--buffer)
		BUFFER="${2:?}"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown argument: $1 (try --help)"
		;;
	esac
done

[[ -z "$MODE" ]] && MODE=check

if [[ "$MODE" == plan ]]; then
	[[ -n "$CLUSTER_COUNT" ]] || die "plan requires --clusters N"
	[[ "$CLUSTER_COUNT" =~ ^[1-9][0-9]*$ ]] || die "--clusters must be a positive integer"
fi
[[ "$BUFFER" =~ ^[0-9]+$ ]] || die "--buffer must be a non-negative integer"

# shellcheck disable=SC2034
QUOTA_ASSUMPTIONS_RESOLVED=""
load_quota_assumptions_for_plan() {
	if [[ "$MODE" != plan ]]; then
		return 0
	fi
	local root f
	root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	f="${QUOTA_ASSUMPTIONS_FILE:-$root/quota-assumptions.env}"
	[[ -f "$f" ]] ||
		die "missing quota assumptions file: $f — create from terraform/rosa-hcp/quota-assumptions.env or see docs/quota-assumptions.source.md"
	QUOTA_ASSUMPTIONS_RESOLVED="$f"
	# shellcheck disable=SC1090
	source "$f"
	[[ "${UPSTREAM_MODULE_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
		die "quota file ${f}: UPSTREAM_MODULE_VERSION must match semver (sync with main.tf module version)"
	[[ "${QUOTA_ASSUMED_AVAILABILITY_ZONES_COUNT:-}" =~ ^[1-9][0-9]*$ ]] ||
		die "quota file ${f}: QUOTA_ASSUMED_AVAILABILITY_ZONES_COUNT must be a positive integer"
	[[ "${QUOTA_ASSUMED_EIP_PER_CLUSTER:-0}" =~ ^[1-9][0-9]*$ ]] ||
		die "quota file ${f}: QUOTA_ASSUMED_EIP_PER_CLUSTER invalid (check VPC_NAT + EXTRA arithmetic)"
	[[ "${QUOTA_ASSUMED_IAM_ROLES_PER_CLUSTER:-0}" =~ ^[1-9][0-9]*$ ]] ||
		die "quota file ${f}: QUOTA_ASSUMED_IAM_ROLES_PER_CLUSTER must be a positive integer"
	[[ "${QUOTA_ASSUMED_NAT_PER_AZ_PER_CLUSTER:-0}" =~ ^[1-9][0-9]*$ ]] ||
		die "quota file ${f}: QUOTA_ASSUMED_NAT_PER_AZ_PER_CLUSTER must be a positive integer"
	[[ "${QUOTA_ASSUMED_NAT_PER_VPC:-0}" =~ ^[1-9][0-9]*$ ]] ||
		die "quota file ${f}: QUOTA_ASSUMED_NAT_PER_VPC must be a positive integer"
	[[ "${QUOTA_ASSUMED_VPC_NAT_EIP_PER_CLUSTER:-0}" =~ ^[0-9]+$ ]] ||
		die "quota file ${f}: QUOTA_ASSUMED_VPC_NAT_EIP_PER_CLUSTER invalid"
}

load_quota_assumptions_for_plan

AWS=(aws --region "$REGION")
if [[ -n "$PROFILE" ]]; then
	AWS+=(--profile "$PROFILE")
fi

IAM_AWS=(aws --region us-east-1)
if [[ -n "$PROFILE" ]]; then
	IAM_AWS+=(--profile "$PROFILE")
fi

echo "Region: $REGION"
if [[ -n "$PROFILE" ]]; then
	echo "Profile: $PROFILE"
fi
echo ""

# JSON number only (no jq errors to stderr for missing quota).
get_quota_json() {
	local service_code="$1"
	local quota_code="$2"
	local mode="${3:-regional}"
	local -a cmd=( "${AWS[@]}" )
	[[ "$mode" == "iam" ]] && cmd=( "${IAM_AWS[@]}" )
	"${cmd[@]}" service-quotas get-service-quota \
		--service-code "$service_code" \
		--quota-code "$quota_code" \
		--output json 2>/dev/null || true
}

get_quota_value() {
	local json
	json=$(get_quota_json "$1" "$2" "${3:-regional}")
	[[ -z "$json" ]] && echo "" && return 0
	echo "$json" | jq -r '.Quota | (.Value // .Quota.Value) | tostring'
}

# Emit one tab-separated row for check mode tables.
list_quota_line() {
	local service_code="$1"
	local quota_code="$2"
	local label="$3"
	local mode="${4:-regional}"
	local json
	json=$(get_quota_json "$service_code" "$quota_code" "$mode")
	[[ -z "$json" ]] && return 0
	echo "$json" | jq -r --arg lbl "$label" --arg sc "$service_code" --arg qc "$quota_code" '
      .Quota |
      "\($lbl)\t\($sc)\t\($qc)\t\(.Value // .Quota.Value)\t\(.Adjustable // .Quota.Adjustable)"'
}

print_check_tables() {
	echo "=== Selected quotas (current effective value in this account/region) ==="
	echo ""

	echo "--- Amazon VPC (service-code: vpc) — often limits cluster count first ---"
	{
		printf '%s\t%s\t%s\t%s\t%s\n' "Quota name" "Service" "Quota code" "Value" "Adjustable"
		list_quota_line vpc L-F678F1CE "VPCs per Region" || true
		list_quota_line vpc L-A4707A72 "Internet gateways per Region" || true
		list_quota_line vpc L-FE5A380F "NAT gateways per Availability Zone" || true
		list_quota_line vpc L-12E49864 "Regional NAT gateways per VPC" || true
	} | column -t -s $'\t'
	echo ""

	echo "--- Amazon EC2 (service-code: ec2) — Elastic IPs for NAT / load balancers ---"
	{
		printf '%s\t%s\t%s\t%s\t%s\n' "Quota name" "Service" "Quota code" "Value" "Adjustable"
		list_quota_line ec2 L-0263D0A3 "EC2-VPC Elastic IPs" || true
	} | column -t -s $'\t'
	echo ""

	echo "--- AWS Identity and Access Management (service-code: iam) — global IAM ---"
	{
		printf '%s\t%s\t%s\t%s\t%s\n' "Quota name" "Service" "Quota code" "Value" "Adjustable"
		list_quota_line iam L-FE177D64 "Roles per account" iam || true
		list_quota_line iam L-858F3967 "OpenID Connect providers per account" iam || true
	} | column -t -s $'\t'
	echo ""

	echo "Tip: run \"$(basename "$0") plan --clusters N\" to compare required limits for N clusters."
}

# Returns 0 if a > b (floats via awk).
float_gt() {
	awk -v a="$1" -v b="$2" 'BEGIN { exit !(a+0 > b+0) }'
}

# Integer required + buffer → suggested --desired-value.
ceil_desired() {
	echo $(($1 + $2))
}

print_plan() {
	local n="$CLUSTER_COUNT"
	local buf="$BUFFER"

	echo "=== Plan for ${n} ROSA HCP cluster(s) (distinct VPC + OIDC each) ==="
	echo ""
	echo "Assumption file: ${QUOTA_ASSUMPTIONS_RESOLVED}"
	echo "Upstream module version (sync with main.tf): ${UPSTREAM_MODULE_VERSION}"
	echo ""
	echo "Inputs (see docs/quota-assumptions.source.md):"
	echo "  • VPCs / internet gateways: ${n} each (one VPC + IGW per cluster)"
	echo "  • NAT gateways per AZ (account): ${n} × ${QUOTA_ASSUMED_NAT_PER_AZ_PER_CLUSTER} per AZ used"
	echo "  • Regional NAT gateways per VPC (single VPC max): ${QUOTA_ASSUMED_NAT_PER_VPC}"
	echo "  • Elastic IPs per cluster: ${QUOTA_ASSUMED_VPC_NAT_EIP_PER_CLUSTER} (VPC NAT EIPs) + ${QUOTA_ASSUMED_EIP_EXTRA_PER_CLUSTER} (extra, non-Terraform VPC) = ${QUOTA_ASSUMED_EIP_PER_CLUSTER}; × ${n} clusters"
	echo "  • IAM roles: ${n} × ${QUOTA_ASSUMED_IAM_ROLES_PER_CLUSTER} (estimate — validate for your OpenShift/rhcs release)"
	echo "  • OIDC providers: ${n}"
	echo "  • Suggested headroom on quota increases: +${buf} (see --buffer)"
	echo ""

	local cur_vpc cur_igw cur_nat_az cur_nat_vpc cur_eip cur_roles cur_oidc
	cur_vpc=$(get_quota_value vpc L-F678F1CE)
	cur_igw=$(get_quota_value vpc L-A4707A72)
	cur_nat_az=$(get_quota_value vpc L-FE5A380F)
	cur_nat_vpc=$(get_quota_value vpc L-12E49864)
	cur_eip=$(get_quota_value ec2 L-0263D0A3)
	cur_roles=$(get_quota_value iam L-FE177D64 iam)
	cur_oidc=$(get_quota_value iam L-858F3967 iam)

	local req_vpc req_igw req_nat_az req_nat_vpc req_eip req_roles req_oidc
	req_vpc=$n
	req_igw=$n
	req_nat_az=$((n * QUOTA_ASSUMED_NAT_PER_AZ_PER_CLUSTER))
	req_nat_vpc=$QUOTA_ASSUMED_NAT_PER_VPC
	req_eip=$((n * QUOTA_ASSUMED_EIP_PER_CLUSTER))
	req_roles=$((n * QUOTA_ASSUMED_IAM_ROLES_PER_CLUSTER))
	req_oidc=$n

	echo "--- Comparison (required vs current effective quota) ---"
	{
		printf '%s\t%s\t%s\t%s\n' "Quota" "Required" "Current" "OK?"
		printf '%s\t%s\t%s\t%s\n' "VPCs per Region" "$req_vpc" "${cur_vpc:-?}" "$(awk -v r="$req_vpc" -v c="${cur_vpc:-0}" 'BEGIN{if(c==""||c=="?"){print "?"} else if(r<=c+0){print "yes"} else {print "NO"}}')"
		printf '%s\t%s\t%s\t%s\n' "Internet gateways per Region" "$req_igw" "${cur_igw:-?}" "$(awk -v r="$req_igw" -v c="${cur_igw:-0}" 'BEGIN{if(c==""||c=="?"){print "?"} else if(r<=c+0){print "yes"} else {print "NO"}}')"
		printf '%s\t%s\t%s\t%s\n' "NAT gateways per Availability Zone" "$req_nat_az" "${cur_nat_az:-?}" "$(awk -v r="$req_nat_az" -v c="${cur_nat_az:-0}" 'BEGIN{if(c==""||c=="?"){print "?"} else if(r<=c+0){print "yes"} else {print "NO"}}')"
		printf '%s\t%s\t%s\t%s\n' "Regional NAT gateways per VPC" "$req_nat_vpc" "${cur_nat_vpc:-?}" "$(awk -v r="$req_nat_vpc" -v c="${cur_nat_vpc:-0}" 'BEGIN{if(c==""||c=="?"){print "?"} else if(r<=c+0){print "yes"} else {print "NO"}}')"
		printf '%s\t%s\t%s\t%s\n' "EC2-VPC Elastic IPs" "$req_eip" "${cur_eip:-?}" "$(awk -v r="$req_eip" -v c="${cur_eip:-0}" 'BEGIN{if(c==""||c=="?"){print "?"} else if(r<=c+0){print "yes"} else {print "NO"}}')"
		printf '%s\t%s\t%s\t%s\n' "IAM roles per account" "$req_roles" "${cur_roles:-?}" "$(awk -v r="$req_roles" -v c="${cur_roles:-0}" 'BEGIN{if(c==""||c=="?"){print "?"} else if(r<=c+0){print "yes"} else {print "NO"}}')"
		printf '%s\t%s\t%s\t%s\n' "OIDC providers per account" "$req_oidc" "${cur_oidc:-?}" "$(awk -v r="$req_oidc" -v c="${cur_oidc:-0}" 'BEGIN{if(c==""||c=="?"){print "?"} else if(r<=c+0){print "yes"} else {print "NO"}}')"
	} | column -t -s $'\t'
	echo ""

	local need_any=0
	local d_vpc="" d_igw="" d_nat_az="" d_nat_vpc="" d_eip="" d_roles="" d_oidc=""

	if [[ -n "$cur_vpc" ]] && float_gt "$req_vpc" "$cur_vpc"; then
		need_any=1
		d_vpc=$(ceil_desired "$req_vpc" "$buf")
	fi
	if [[ -n "$cur_igw" ]] && float_gt "$req_igw" "$cur_igw"; then
		need_any=1
		d_igw=$(ceil_desired "$req_igw" "$buf")
	fi
	if [[ -n "$cur_nat_az" ]] && float_gt "$req_nat_az" "$cur_nat_az"; then
		need_any=1
		d_nat_az=$(ceil_desired "$req_nat_az" "$buf")
	fi
	if [[ -n "$cur_nat_vpc" ]] && float_gt "$req_nat_vpc" "$cur_nat_vpc"; then
		need_any=1
		d_nat_vpc=$(ceil_desired "$req_nat_vpc" "$buf")
	fi
	if [[ -n "$cur_eip" ]] && float_gt "$req_eip" "$cur_eip"; then
		need_any=1
		d_eip=$(ceil_desired "$req_eip" "$buf")
	fi
	if [[ -n "$cur_roles" ]] && float_gt "$req_roles" "$cur_roles"; then
		need_any=1
		d_roles=$(ceil_desired "$req_roles" "$buf")
	fi
	if [[ -n "$cur_oidc" ]] && float_gt "$req_oidc" "$cur_oidc"; then
		need_any=1
		d_oidc=$(ceil_desired "$req_oidc" "$buf")
	fi

	if ((need_any == 0)); then
		echo "=== No increases required under current assumptions (or quota fetch incomplete). ==="
		echo "Review the comparison table; if Current was \"?\", fix credentials and re-run."
		return 0
	fi

	echo "=== Suggested AWS CLI commands (review numbers before running) ==="
	echo ""

	aws_prefix=(aws)
	[[ -n "$PROFILE" ]] && aws_prefix+=(--profile "$PROFILE")

	if [[ -n "${d_vpc:-}" ]]; then
		echo "# VPCs per Region → desired ${d_vpc}"
		echo "${aws_prefix[*]} --region ${REGION} service-quotas request-service-quota-increase \\"
		echo "  --service-code vpc --quota-code L-F678F1CE --desired-value ${d_vpc}"
		echo ""
	fi
	if [[ -n "${d_igw:-}" ]]; then
		echo "# Internet gateways per Region → desired ${d_igw}"
		echo "${aws_prefix[*]} --region ${REGION} service-quotas request-service-quota-increase \\"
		echo "  --service-code vpc --quota-code L-A4707A72 --desired-value ${d_igw}"
		echo ""
	fi
	if [[ -n "${d_nat_az:-}" ]]; then
		echo "# NAT gateways per Availability Zone → desired ${d_nat_az}"
		echo "${aws_prefix[*]} --region ${REGION} service-quotas request-service-quota-increase \\"
		echo "  --service-code vpc --quota-code L-FE5A380F --desired-value ${d_nat_az}"
		echo ""
	fi
	if [[ -n "${d_nat_vpc:-}" ]]; then
		echo "# Regional NAT gateways per VPC → desired ${d_nat_vpc}"
		echo "${aws_prefix[*]} --region ${REGION} service-quotas request-service-quota-increase \\"
		echo "  --service-code vpc --quota-code L-12E49864 --desired-value ${d_nat_vpc}"
		echo ""
	fi
	if [[ -n "${d_eip:-}" ]]; then
		echo "# EC2-VPC Elastic IPs → desired ${d_eip}"
		echo "${aws_prefix[*]} --region ${REGION} service-quotas request-service-quota-increase \\"
		echo "  --service-code ec2 --quota-code L-0263D0A3 --desired-value ${d_eip}"
		echo ""
	fi
	if [[ -n "${d_roles:-}" ]]; then
		echo "# IAM roles per account → desired ${d_roles}"
		echo "${aws_prefix[*]} --region us-east-1 service-quotas request-service-quota-increase \\"
		echo "  --service-code iam --quota-code L-FE177D64 --desired-value ${d_roles}"
		echo ""
	fi
	if [[ -n "${d_oidc:-}" ]]; then
		echo "# OIDC providers per account → desired ${d_oidc}"
		echo "${aws_prefix[*]} --region us-east-1 service-quotas request-service-quota-increase \\"
		echo "  --service-code iam --quota-code L-858F3967 --desired-value ${d_oidc}"
		echo ""
	fi

	echo "# Docs: https://docs.aws.amazon.com/servicequotas/latest/userguide/request-quota-increase.html"
}

case "$MODE" in
check)
	print_check_tables
	;;
plan)
	print_plan
	;;
esac

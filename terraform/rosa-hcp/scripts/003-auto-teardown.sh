#!/usr/bin/env bash
# ci-dry-run-skip: even --dry-run reads terraform state, AWS (sts, describe-*) and the rosa login, which CI lacks; dry-run it on the operator host the day before the window (docs/runbooks/rosa-validation/window-plan.md, P0)
set -euo pipefail

# Billing-first, unattended teardown of the ROSA HCP clusters in terraform/rosa-hcp:
# the backstop of a cost-capped validation window. Runs from a systemd user timer
# with a minimal environment (see --arm). Idempotent: a second run finds nothing to
# destroy and only repeats the audit.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SELF="${SCRIPT_DIR}/$(basename "$0")"

MODE=""
DRY_RUN=0
STATE_DIR="${HOME:+${HOME}/.rosa-window}"
BY_CLUSTER_JSON=""
LOG_FILE=""
REGION=""
REGION_FROM_FLAG=0
RETRIES=3
RETRY_WAIT=60
LOCK_TIMEOUT="5m"
SNS_TOPIC_ARN=""
# Tier C of docs/runbooks/rosa-validation/window-plan.md; fallback tiers pass --fire-after.
FIRE_AFTER="8h15m"
FIRE_AFTER_SET=0
UNIT="rosa-autoteardown"
UNIT_SET=0
# WSL detection reads this file (overridable for tests).
PROC_VERSION_FILE="${ROSA_TEARDOWN_PROC_VERSION:-/proc/version}"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") --now | --arm | --disarm | --dry-run [OPTIONS]

Billing-first teardown of every ROSA HCP cluster in terraform/rosa-hcp, built to
run unattended from a systemd user timer as the backstop of a cost-capped
validation window. Order:
  0. Merge 'terraform output -json by_cluster' into the saved copy (never drops
     an entry), so the VPC ids survive the next step.
  1. terraform destroy -target=module.rosa_hcp: the clusters, their worker pools
     and IAM roles. ROSA, EC2 and EBS billing stops, and no controller is left to
     recreate load balancers.
  2. 002-pre-destroy-vpc-cleanup.sh --delete-interface-endpoints, plus
     --by-cluster-json <saved copy> once that copy lists a VPC: orphan load
     balancers, ENIs, security groups and interface endpoints in the cluster VPCs.
     Skipped when no VPC is known (no saved copy, no aws_vpc in state).
  3. terraform destroy: VPCs, NAT gateways, Elastic IPs, peering.
     Steps 2-3 repeat (DependencyViolation) up to --retries rounds.
  4. Read-only audit: terraform state, 'rosa list clusters', the saved VPCs, and
     unattached EBS volumes created since T0. Exit 1 if anything still bills or
     cannot be checked.
Every terraform attempt first refreshes the OCM token for the rhcs provider
(RHCS_TOKEN="\$(rosa token --refresh)"). Each step retries --retries times, every
step runs even if an earlier one failed, and everything is appended to the log.
terraform/rosa-hcp uses only the default workspace, so an exported TF_WORKSPACE
(the platform's 'rosa') is ignored. It never touches terraform/platform: discard
that rosa workspace by hand afterwards (docs/runbooks/rosa-validation/README.md).

Modes (exactly one; --dry-run alone checks the teardown without --now):
  --now                  Tear down now. Nothing is destroyed without it, so a
                         re-arm that forgets --arm fails instead of destroying.
  --arm                  Arm a systemd user timer (--unit) that runs this script
                         with --now at T0 + --fire-after through two triggers:
                         --on-active (monotonic; stalls while the machine sleeps)
                         and an absolute --on-calendar time in UTC (fires on
                         wake). T0 is the epoch in <state-dir>/t0, or now if that
                         file is missing. The unit gets PATH, AWS_PROFILE and
                         AWS_REGION (plus AWS_CONFIG_FILE,
                         AWS_SHARED_CREDENTIALS_FILE and OCM_CONFIG when set)
                         from this shell, so it first runs the same preflight as
                         --dry-run and refuses to arm if a check fails. On WSL
                         the timer lives only while the distro runs: it also
                         requires [general] instanceIdleTimeout=-1 in
                         %UserProfile%\\.wslconfig. Everywhere it requires
                         --sns-topic-arn with a confirmed subscription, and
                         publishes an "armed" message there once armed. Re-arm
                         after any reboot: transient timers do not survive one.
  --disarm               Stop the timer. A teardown already running continues.

Options:
  --state-dir DIR        Window files kept outside git: t0, by_cluster.json,
                         teardown.log, teardown.result and the run lock
                         (default: ~/.rosa-window)
  --by-cluster-json FILE Saved 'terraform output -json by_cluster'
                         (default: <state-dir>/by_cluster.json)
  --log FILE             Log to append to (default: <state-dir>/teardown.log)
  --region REGION        AWS region (default: aws_region in terraform.tfvars, then
                         \$AWS_REGION, \$AWS_DEFAULT_REGION)
  --retries N            Attempts per step, and rounds of steps 2-3 (default: 3)
  --retry-wait SEC       Pause between attempts (default: 60)
  --sns-topic-arn ARN    Also publish the result to this SNS topic (an email
                         subscription reaches a phone when the laptop cannot).
                         Required with --arm. --arm and --dry-run check that the
                         topic has a confirmed subscription.
  --fire-after DURATION  --arm: offset from T0, like 8h15m, 45m or 3600 (default:
                         8h15m, the window plan's Tier C; Tier B uses 7h15m)
  --unit NAME            --arm/--disarm: systemd unit name (default: rosa-autoteardown)
  --dry-run              Check what the unattended run needs (tools on PATH, AWS
                         credentials, rosa login and token refresh, tfvars, state,
                         the saved VPC list, the SNS subscription; on WSL,
                         .wslconfig; with --arm: systemd and linger), run
                         002 --dry-run once a VPC is known, and print the plan.
                         Changes nothing. Exit 1 if a check fails.
  -h, --help             Show this help

The log also reaches the journal: journalctl --user -u <unit>.
EOF
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

set_mode() {
  [[ -z "${MODE}" || "${MODE}" == "$1" ]] || die "--${MODE} and --$1 exclude each other"
  MODE="$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --now)
    set_mode now
    shift
    ;;
  --arm)
    set_mode arm
    shift
    ;;
  --disarm)
    set_mode disarm
    shift
    ;;
  --dry-run)
    DRY_RUN=1
    shift
    ;;
  --state-dir | --by-cluster-json | --log | --region | --retries | --retry-wait | --sns-topic-arn | --fire-after | --unit)
    [[ -n "${2:-}" ]] || die "$1 requires a value"
    case "$1" in
    --state-dir) STATE_DIR="$2" ;;
    --by-cluster-json) BY_CLUSTER_JSON="$2" ;;
    --log) LOG_FILE="$2" ;;
    --region)
      REGION="$2"
      REGION_FROM_FLAG=1
      ;;
    --retries) RETRIES="$2" ;;
    --retry-wait) RETRY_WAIT="$2" ;;
    --sns-topic-arn) SNS_TOPIC_ARN="$2" ;;
    --fire-after)
      FIRE_AFTER="$2"
      FIRE_AFTER_SET=1
      ;;
    --unit)
      UNIT="$2"
      UNIT_SET=1
      ;;
    esac
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

# A re-arm that forgets --arm must not turn into a teardown mid-window.
if ((FIRE_AFTER_SET)) && [[ "${MODE}" != "arm" ]]; then
  die "--fire-after needs --arm (nothing done; a teardown needs --now)"
fi
if ((UNIT_SET)) && [[ "${MODE}" != "arm" && "${MODE}" != "disarm" ]]; then
  die "--unit needs --arm or --disarm (nothing done; a teardown needs --now)"
fi
if [[ -z "${MODE}" ]]; then
  if ((DRY_RUN)); then
    MODE="now"
  else
    die "choose a mode: --now (tear down now), --arm, --disarm, or --dry-run (try --help)"
  fi
fi

[[ -n "${STATE_DIR}" ]] || die "HOME is not set: pass --state-dir"
[[ "${RETRIES}" =~ ^[1-9][0-9]*$ ]] || die "--retries must be a positive integer"
is_uint "${RETRY_WAIT}" || die "--retry-wait must be a non-negative integer"
[[ "${UNIT}" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "--unit: letters, digits and _.@- only"
if [[ -n "${SNS_TOPIC_ARN}" && ! "${SNS_TOPIC_ARN}" =~ ^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]+:[A-Za-z0-9_-]+$ ]]; then
  die "--sns-topic-arn does not look like an SNS topic ARN"
fi
BY_CLUSTER_JSON="${BY_CLUSTER_JSON:-${STATE_DIR}/by_cluster.json}"
LOG_FILE="${LOG_FILE:-${STATE_DIR}/teardown.log}"

if [[ -z "${REGION}" && -f "${TF_DIR}/terraform.tfvars" ]]; then
  REGION="$(sed -n 's/^[[:space:]]*aws_region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${TF_DIR}/terraform.tfvars" | head -1)"
fi
REGION="${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"

# rosa-hcp has only the default workspace (terraform/platform reads ../rosa-hcp/terraform.tfstate
# by path). A TF_WORKSPACE exported for the platform's 'rosa' workspace would point every command
# here at an empty workspace, where destroy "succeeds" with nothing destroyed.
IGNORED_TF_WORKSPACE=""
if [[ -n "${TF_WORKSPACE:-}" ]]; then
  [[ "${TF_WORKSPACE}" == "default" ]] || IGNORED_TF_WORKSPACE="${TF_WORKSPACE}"
  unset TF_WORKSPACE
fi

# --- Helpers ---

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

PROBLEMS=0
check_ok() { log "  OK    $*"; }
check_info() { log "  INFO  $*"; }
check_fail() {
  log "  FAIL  $*"
  PROBLEMS=$((PROBLEMS + 1))
}

# "8h15m" / "45m" / "90s" / "3600" -> seconds.
duration_to_sec() {
  local d="$1" total=0 n
  if is_uint "${d}"; then
    echo "${d}"
    return 0
  fi
  [[ "${d}" =~ ^([0-9]+h)?([0-9]+m)?([0-9]+s)?$ && -n "${d}" ]] || return 1
  while [[ "${d}" =~ ^([0-9]+)([hms])(.*)$ ]]; do
    n=$((10#${BASH_REMATCH[1]}))
    case "${BASH_REMATCH[2]}" in
    h) total=$((total + n * 3600)) ;;
    m) total=$((total + n * 60)) ;;
    s) total=$((total + n)) ;;
    esac
    d="${BASH_REMATCH[3]}"
  done
  echo "${total}"
}

# Epoch seconds -> UTC time in the given strftime format (GNU date, then BSD date).
fmt_utc() {
  date -u -d "@$1" "+$2" 2>/dev/null || date -u -r "$1" "+$2"
}

# T0 (epoch seconds) from <state-dir>/t0, or nothing.
read_t0() {
  local t0=""
  [[ -r "${STATE_DIR}/t0" ]] && t0="$(tr -dc '0-9' <"${STATE_DIR}/t0")"
  [[ -n "${t0}" ]] && echo "${t0}"
}

# Sets RHCS_CLIENT_ID/RHCS_TOKEN for the rhcs provider. `rosa token --refresh` prints the
# offline refresh token, from which the provider mints access tokens itself.
refresh_rhcs_token() {
  local tok
  if tok="$(rosa token --refresh 2>/dev/null)" && [[ -n "${tok}" ]]; then
    export RHCS_CLIENT_ID=ocm-cli RHCS_TOKEN="${tok}"
    return 0
  fi
  return 1
}

# by_cluster JSON on stdin -> number of entries with a vpc_id.
count_vpcs() { jq '[.[]? | .vpc_id? // empty] | length' 2>/dev/null || echo 0; }

saved_vpc_count() {
  if [[ -s "${BY_CLUSTER_JSON}" ]]; then count_vpcs <"${BY_CLUSTER_JSON}"; else echo 0; fi
}

# terraform state list -> STATE_N (resource count, or "unreadable" when state exists but cannot
# be read) and STATE_VPCS (managed aws_vpc resources: what 002 can find without the saved copy).
STATE_N=0
STATE_VPCS=0
state_scan() {
  local out
  STATE_VPCS=0
  if out="$(terraform -chdir="${TF_DIR}" state list 2>&1)"; then
    STATE_N="$(grep -c . <<<"${out}" || true)"
    STATE_VPCS="$(awk '!/(^|\.)data\./ && /(^|\.)aws_vpc\./' <<<"${out}" | grep -c . || true)"
  elif [[ ! -f "${TF_DIR}/terraform.tfstate" || "${out}" == *"No state file was found"* ]]; then
    STATE_N=0
  else
    STATE_N="unreadable"
  fi
}

# Workspaces other than default that hold resources, as "name(count) ...": this script cannot see them.
other_workspace_states() {
  local f n
  for f in "${TF_DIR}"/terraform.tfstate.d/*/terraform.tfstate; do
    [[ -f "${f}" ]] || continue
    n="$(jq '[.resources[]? | select(.mode == "managed")] | length' "${f}" 2>/dev/null)" || n="?"
    [[ "${n}" == "0" ]] || printf '%s(%s) ' "$(basename "$(dirname "${f}")")" "${n}"
  done
}

# Step 2's command for the current saved copy: --by-cluster-json only once it lists a VPC
# (002 dies on a missing file, and falls back to the aws_vpc entries in state without one).
build_cleanup() {
  CLEANUP=("${SCRIPT_DIR}/002-pre-destroy-vpc-cleanup.sh" --delete-interface-endpoints)
  if (($(saved_vpc_count) > 0)); then
    CLEANUP+=(--by-cluster-json "${BY_CLUSTER_JSON}")
  fi
  if ((REGION_FROM_FLAG)); then
    CLEANUP+=(--region "${REGION}")
  fi
  return 0
}

# A VPC 002 could clean: one in the saved copy or in state (call state_scan first).
vpc_known() {
  (($(saved_vpc_count) > 0)) || [[ "${STATE_VPCS}" =~ ^[1-9] ]]
}

# --- WSL: the timer lives only while the distro runs ---

is_wsl() { grep -qi microsoft "${PROC_VERSION_FILE}" 2>/dev/null; }

# %UserProfile%\.wslconfig as a Linux path, through Windows interop.
wslconfig_path() {
  local up dir
  command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1 || return 1
  up="$(cd / && cmd.exe /c 'echo %UserProfile%' 2>/dev/null | tr -d '\r' | grep -E '^[A-Za-z]:' | tail -1)" || return 1
  [[ -n "${up}" ]] || return 1
  dir="$(wslpath -u "${up}" 2>/dev/null)" || return 1
  [[ -n "${dir}" ]] || return 1
  echo "${dir%/}/.wslconfig"
}

# INI value: $1 file, $2 section, $3 key (case-insensitive), or nothing.
ini_value() {
  awk -v sec="$2" -v key="$3" '
    { sub(/\r$/, ""); sub(/[#;].*/, "") }
    /^[[:space:]]*\[/ {
      s = tolower($0); sub(/^[[:space:]]*\[[[:space:]]*/, "", s); sub(/[[:space:]]*\].*$/, "", s)
      in_sec = (s == tolower(sec)); next
    }
    in_sec && index($0, "=") {
      k = substr($0, 1, index($0, "=") - 1); v = substr($0, index($0, "=") + 1)
      gsub(/[[:space:]]/, "", k); gsub(/[[:space:]]/, "", v)
      if (tolower(k) == tolower(key)) val = v
    }
    END { if (val != "") print val }' "$1" 2>/dev/null
}

# WSL stops a distro about 15 s after its last wsl.exe session closes, systemd units or not, and
# the transient timer dies with it, silently. Only [general] instanceIdleTimeout=-1 prevents that.
check_wsl_keepalive() {
  local f v fix
  is_wsl || return 0
  fix="set [general] instanceIdleTimeout=-1 (and [wsl2] vmIdleTimeout=-1) in %UserProfile%\\.wslconfig, then 'wsl --shutdown' from Windows and reopen"
  if ! f="$(wslconfig_path)"; then
    check_info "WSL: cannot locate %UserProfile%\\.wslconfig (Windows interop off?); without it the timer dies about 15 s after the last terminal closes: ${fix}"
    return 0
  fi
  v="$(ini_value "${f}" general instanceIdleTimeout)" || v=""
  if [[ "${v}" == "-1" ]]; then
    check_ok "WSL: instanceIdleTimeout=-1 in ${f} (the distro, and the timer, outlive the terminal)"
  else
    check_fail "WSL: ${f} has no [general] instanceIdleTimeout=-1 (${v:-unset}); the distro stops about 15 s after the last terminal closes and the timer with it: ${fix}"
  fi
}

# The SNS topic's region, from its ARN (arn:aws:sns:<region>:<account>:<name>).
sns_region() {
  local r
  IFS=: read -r _ _ _ r _ <<<"${SNS_TOPIC_ARN}"
  printf '%s\n' "${r}"
}

# The SNS email is the only alert that reaches an operator away from this host when the
# timer's teardown fails. An email subscription delivers nothing until it is confirmed.
check_sns() {
  local n
  if [[ -z "${SNS_TOPIC_ARN}" ]]; then
    if [[ "${MODE}" == "arm" ]]; then
      check_fail "no --sns-topic-arn: --arm needs a topic with a confirmed email subscription, the alert that reaches an absent operator (docs/runbooks/rosa-validation/window-plan.md, P0)"
    else
      check_info "no --sns-topic-arn: the result reaches only this host's desktop (--arm requires a topic)"
    fi
    return 0
  fi
  if n="$(aws --region "$(sns_region)" sns get-topic-attributes --topic-arn "${SNS_TOPIC_ARN}" \
    --query 'Attributes.SubscriptionsConfirmed' --output text 2>/dev/null)" && is_uint "${n}"; then
    if ((n > 0)); then
      check_ok "SNS topic: ${n} confirmed subscription(s)"
    else
      check_fail "SNS topic has no confirmed subscription: confirm the email (aws sns list-subscriptions-by-topic --topic-arn ${SNS_TOPIC_ARN})"
    fi
  else
    check_fail "cannot read SNS topic ${SNS_TOPIC_ARN} (wrong ARN, or no sns:GetTopicAttributes)"
  fi
}

# --- Preflight: what the unattended run needs ---

preflight() {
  local t missing=() saved ws others
  log "Preflight (terraform dir: ${TF_DIR})"
  for t in terraform aws jq rosa; do command -v "${t}" >/dev/null 2>&1 || missing+=("${t}"); done
  if ((${#missing[@]})); then
    check_fail "not on PATH: ${missing[*]} (PATH=${PATH})"
  else
    check_ok "terraform, aws, jq and rosa on PATH"
  fi
  if [[ -n "${REGION}" ]]; then
    check_ok "region ${REGION}"
  else
    check_fail "no region: pass --region, or set aws_region in terraform.tfvars or AWS_REGION"
  fi
  if command -v aws >/dev/null 2>&1 && aws sts get-caller-identity --output json >/dev/null 2>&1; then
    check_ok "AWS credentials (profile ${AWS_PROFILE:-default})"
  else
    check_fail "AWS credentials missing or expired (profile ${AWS_PROFILE:-default}); for the timer, export AWS_PROFILE before --arm"
  fi
  if command -v rosa >/dev/null 2>&1 && refresh_rhcs_token; then
    check_ok "rosa token --refresh works (RHCS_TOKEN set for the rhcs provider)"
  else
    check_fail "rosa token --refresh failed: run 'rosa login --use-auth-code'"
  fi
  if command -v rosa >/dev/null 2>&1 && rosa whoami >/dev/null 2>&1; then
    check_ok "rosa whoami"
  else
    check_fail "rosa whoami failed: run 'rosa login --use-auth-code'"
  fi
  # Checked when arming or dry-running only; the teardown itself just publishes.
  if ((DRY_RUN)) || [[ "${MODE}" == "arm" ]]; then
    check_sns
  fi
  if [[ -n "${IGNORED_TF_WORKSPACE}" ]]; then
    check_info "TF_WORKSPACE=${IGNORED_TF_WORKSPACE} ignored: terraform/rosa-hcp uses only the default workspace"
  fi
  ws=""
  [[ -r "${TF_DIR}/.terraform/environment" ]] && ws="$(tr -d '[:space:]' <"${TF_DIR}/.terraform/environment")"
  if [[ -n "${ws}" && "${ws}" != "default" ]]; then
    check_fail "workspace '${ws}' is selected in ${TF_DIR}, which uses only the default one: terraform -chdir=${TF_DIR} workspace select default"
  fi
  if ! command -v terraform >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  others="$(other_workspace_states)"
  if [[ -n "${others}" ]]; then
    check_fail "resources in other rosa-hcp workspaces: ${others}(this script destroys only the default workspace; destroy those by hand)"
  fi
  state_scan
  saved="$(saved_vpc_count)"
  if [[ "${STATE_N}" == "unreadable" ]]; then
    check_fail "cannot read terraform state in ${TF_DIR}"
  elif ((STATE_N == 0)); then
    check_info "terraform state is empty: nothing to destroy (before apply, or already torn down)"
  else
    check_ok "terraform state: ${STATE_N} resources, ${STATE_VPCS} VPC(s)"
    if [[ -f "${TF_DIR}/terraform.tfvars" ]]; then
      check_ok "terraform.tfvars present (destroy needs its required variables)"
    else
      check_fail "no ${TF_DIR}/terraform.tfvars: terraform destroy cannot run without it"
    fi
    if [[ -d "${TF_DIR}/.terraform" ]]; then
      check_ok "terraform initialized"
    else
      check_info "terraform not initialized: the run starts with 'terraform init -input=false'"
    fi
  fi
  if ((saved > 0)); then
    check_ok "saved by_cluster copy lists ${saved} VPC(s): ${BY_CLUSTER_JSON}"
  elif ((STATE_VPCS > 0)); then
    check_info "no saved by_cluster copy at ${BY_CLUSTER_JSON}: step 0 writes it; save it now with: terraform -chdir=${TF_DIR} output -json by_cluster > ${BY_CLUSTER_JSON}"
  else
    check_info "no saved by_cluster copy and no VPC in state yet (save the copy right after apply)"
  fi
}

# --- Teardown steps ---

# Step 0: merge the live by_cluster output into the saved copy. Never drops an entry: after a
# partial destroy the output lists fewer clusters, but their VPCs may still exist.
save_by_cluster() {
  local out saved merged
  out="$(terraform -chdir="${TF_DIR}" output -json by_cluster 2>/dev/null)" || out="{}"
  [[ "$(count_vpcs <<<"${out}")" -gt 0 ]] || out="{}"
  saved="{}"
  [[ -s "${BY_CLUSTER_JSON}" ]] && saved="$(cat "${BY_CLUSTER_JSON}")"
  merged="$(jq -s '(.[0] | if type == "object" then . else {} end) * .[1]' <<<"${saved}"$'\n'"${out}" 2>/dev/null)" || merged="${out}"
  if [[ "$(count_vpcs <<<"${merged}")" -eq 0 ]]; then
    log "warning: no VPC ids saved or in the output; 002 falls back to terraform state"
    return 0
  fi
  if [[ "${merged}" != "$(jq . <<<"${saved}" 2>/dev/null)" ]]; then
    (umask 077 && printf '%s\n' "${merged}" >"${BY_CLUSTER_JSON}.tmp") && mv -f "${BY_CLUSTER_JSON}.tmp" "${BY_CLUSTER_JSON}"
    log "saved by_cluster copy: ${BY_CLUSTER_JSON} ($(count_vpcs <<<"${merged}") VPCs)"
  fi
}

TF_DESTROY=(terraform -chdir="${TF_DIR}" destroy -auto-approve -input=false -no-color -lock-timeout="${LOCK_TIMEOUT}")
CLEANUP=()

attempt() {
  local label="$1" rc=0
  shift
  log "BEGIN ${label}"
  "$@" || rc=$?
  log "END   ${label}: exit ${rc}"
  return "${rc}"
}

with_retries() {
  local label="$1" i
  shift
  for ((i = 1; i <= RETRIES; i++)); do
    refresh_rhcs_token || log "warning: rosa token --refresh failed; the rhcs provider may not authenticate"
    attempt "${label} (attempt ${i}/${RETRIES})" "$@" && return 0
    if ((i < RETRIES)); then
      log "retrying in ${RETRY_WAIT}s"
      sleep "${RETRY_WAIT}"
    fi
  done
  return 1
}

AUDIT_LEAKS=0
audit() {
  local t0 t0iso names vpc err count others
  AUDIT_LEAKS=0
  log "Audit (region ${REGION:-unknown})"
  state_scan
  if [[ "${STATE_N}" == "0" ]]; then
    check_ok "terraform state is empty"
  else
    log "  LEAK  terraform state still holds ${STATE_N} resources"
    AUDIT_LEAKS=$((AUDIT_LEAKS + 1))
  fi
  others="$(other_workspace_states)"
  if [[ -n "${others}" ]]; then
    log "  LEAK  resources in other rosa-hcp workspaces: ${others}"
    AUDIT_LEAKS=$((AUDIT_LEAKS + 1))
  fi
  names="$(jq -c '[.[]? | .cluster_name? // empty]' "${BY_CLUSTER_JSON}" 2>/dev/null)" || names="[]"
  if [[ "${names}" == "[]" ]]; then
    log "  LEAK? no saved cluster names: check 'rosa list clusters' by hand"
    AUDIT_LEAKS=$((AUDIT_LEAKS + 1))
  elif count="$(rosa list clusters -o json 2>/dev/null | jq --argjson names "${names}" '[.[]? | select(.name as $n | $names | index($n))] | length')"; then
    if ((count == 0)); then
      check_ok "rosa list clusters: none of the window's clusters"
    else
      log "  LEAK  rosa list clusters still shows ${count} of the window's clusters"
      AUDIT_LEAKS=$((AUDIT_LEAKS + 1))
    fi
  else
    log "  LEAK? rosa list clusters failed: check by hand"
    AUDIT_LEAKS=$((AUDIT_LEAKS + 1))
  fi
  if [[ -z "${REGION}" ]]; then
    log "  LEAK? no region: AWS checks skipped"
    AUDIT_LEAKS=$((AUDIT_LEAKS + 1))
    return 0
  fi
  while IFS= read -r vpc; do
    [[ -n "${vpc}" ]] || continue
    if err="$(aws --region "${REGION}" ec2 describe-vpcs --vpc-ids "${vpc}" 2>&1 >/dev/null)"; then
      log "  LEAK  VPC ${vpc} still exists (NAT gateway, endpoints and LBs inside it may still bill)"
      AUDIT_LEAKS=$((AUDIT_LEAKS + 1))
    elif [[ "${err}" == *InvalidVpcID.NotFound* ]]; then
      check_ok "VPC ${vpc} deleted"
    else
      log "  LEAK? VPC ${vpc}: lookup failed: $(head -1 <<<"${err}")"
      AUDIT_LEAKS=$((AUDIT_LEAKS + 1))
    fi
  done < <(jq -r '.[]? | .vpc_id? // empty' "${BY_CLUSTER_JSON}" 2>/dev/null || true)
  if t0="$(read_t0)"; then
    t0iso="$(fmt_utc "${t0}" '%Y-%m-%dT%H:%M:%S')"
    if count="$(aws --region "${REGION}" ec2 describe-volumes --filters Name=status,Values=available --output json 2>/dev/null |
      jq --arg t0 "${t0iso}" '[.Volumes[] | select((.CreateTime // "")[0:19] >= $t0)] | length')"; then
      if ((count == 0)); then
        check_ok "no unattached EBS volume created since T0 (${t0iso}Z)"
      else
        log "  LEAK  ${count} unattached EBS volume(s) created since T0 (${t0iso}Z): cluster PVs? check their tags"
        AUDIT_LEAKS=$((AUDIT_LEAKS + 1))
      fi
    else
      log "  LEAK? describe-volumes failed: check by hand"
      AUDIT_LEAKS=$((AUDIT_LEAKS + 1))
    fi
  else
    check_info "no ${STATE_DIR}/t0: the EBS volume check is skipped"
  fi
  # Region-wide counts for context; the runbook's unfiltered audit across regions decides.
  count="$(aws --region "${REGION}" ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query 'length(Reservations[].Instances[])' --output text 2>/dev/null)" || count="?"
  check_info "region-wide: ${count} instance(s) not terminated"
  count="$(aws --region "${REGION}" ec2 describe-nat-gateways --filter Name=state,Values=pending,available,deleting --query 'length(NatGateways)' --output text 2>/dev/null)" || count="?"
  check_info "region-wide: ${count} NAT gateway(s)"
  count="$(aws --region "${REGION}" elb describe-load-balancers --query 'length(LoadBalancerDescriptions)' --output text 2>/dev/null)" || count="?"
  check_info "region-wide: ${count} classic load balancer(s)"
  count="$(aws --region "${REGION}" elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text 2>/dev/null)" || count="?"
  check_info "region-wide: ${count} NLB/ALB(s)"
  count="$(aws --region "${REGION}" ec2 describe-addresses --query 'length(Addresses[?AssociationId==null])' --output text 2>/dev/null)" || count="?"
  check_info "region-wide: ${count} unassociated Elastic IP(s)"
  return 0
}

sns_publish() {
  local subject="$1" body="$2" err
  [[ -n "${SNS_TOPIC_ARN}" ]] || return 0
  if err="$(aws --region "$(sns_region)" sns publish --topic-arn "${SNS_TOPIC_ARN}" \
    --subject "${subject}" --message "${body}" 2>&1 >/dev/null)"; then
    log "published to SNS: ${subject}"
  else
    log "warning: SNS publish failed: $(head -1 <<<"${err}")"
  fi
}

notify() {
  local subject="$1" body="$2"
  sns_publish "${subject}" "${body}"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u critical "${subject}" "${body}" >/dev/null 2>&1 || true
  fi
}

run_teardown() {
  local rc_tools=0 step1="FAILED" step3="FAILED" round result summary t
  log "=== ROSA auto-teardown$( ((DRY_RUN)) && echo " (dry run)") ==="
  log "terraform dir: ${TF_DIR}"
  log "saved VPC list: ${BY_CLUSTER_JSON}"
  preflight

  if ((DRY_RUN)); then
    check_wsl_keepalive
    build_cleanup
    log "Plan (billing-first):"
    log "  0. merge 'terraform output -json by_cluster' into ${BY_CLUSTER_JSON}"
    log "  1. ${TF_DESTROY[*]} -target=module.rosa_hcp   (up to ${RETRIES} attempts, ${RETRY_WAIT}s apart)"
    log "  2. ${CLEANUP[*]}$( (($(saved_vpc_count) > 0)) || echo "   (adds --by-cluster-json once step 0 saves a VPC there)")"
    log "  3. ${TF_DESTROY[*]}   (steps 2-3: up to ${RETRIES} rounds)"
    log "  4. audit; notify$([[ -n "${SNS_TOPIC_ARN}" ]] && echo " (SNS + desktop)" || echo " (desktop only; add --sns-topic-arn)")"
    if command -v terraform >/dev/null 2>&1 && command -v aws >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
      state_scan
      if vpc_known; then
        log "002 --dry-run (what step 2 would clean right now; while the clusters run, most of it is skipped):"
        if ! "${CLEANUP[@]}" --dry-run 2>&1 | sed 's/^/    /'; then
          check_fail "002 --dry-run failed (output above)"
        fi
      else
        check_info "no VPC known yet (no saved copy, no aws_vpc in state): 002 --dry-run skipped"
      fi
    fi
    log "Dry run: ${PROBLEMS} problem(s)."
    ((PROBLEMS == 0)) || return 1
    return 0
  fi

  for t in terraform aws jq; do command -v "${t}" >/dev/null 2>&1 || rc_tools=1; done
  if ((rc_tools)); then
    summary="teardown NOT started: terraform, aws or jq missing from PATH (${PATH})"
    log "${summary}"
    printf '%s FAILED %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${summary}" >"${STATE_DIR}/teardown.result"
    notify "ROSA auto-teardown FAILED" "${summary}. Log: ${LOG_FILE}. Tear down by hand now."
    return 1
  fi

  if [[ ! -d "${TF_DIR}/.terraform" ]]; then
    attempt "terraform init" terraform -chdir="${TF_DIR}" init -input=false -no-color || true
  fi
  save_by_cluster || log "warning: could not update ${BY_CLUSTER_JSON}"

  if with_retries "step 1/4: destroy -target=module.rosa_hcp" "${TF_DESTROY[@]}" -target=module.rosa_hcp; then
    step1="ok"
  else
    log "step 1 FAILED after ${RETRIES} attempts; continuing (the full destroy retries the clusters too)"
  fi

  for ((round = 1; round <= RETRIES; round++)); do
    # Rebuilt every round: the saved copy may have appeared, and state shrinks with each destroy.
    build_cleanup
    state_scan
    if vpc_known; then
      attempt "step 2/4 (round ${round}/${RETRIES}): 002-pre-destroy-vpc-cleanup.sh" "${CLEANUP[@]}" ||
        log "warning: 002 reported errors; running terraform destroy anyway"
    else
      log "step 2/4 (round ${round}/${RETRIES}): skipped, no VPC known (no saved copy, no aws_vpc in state)"
    fi
    refresh_rhcs_token || log "warning: rosa token --refresh failed; the rhcs provider may not authenticate"
    if attempt "step 3/4 (round ${round}/${RETRIES}): terraform destroy" "${TF_DESTROY[@]}"; then
      step3="ok"
      break
    fi
    if ((round < RETRIES)); then
      log "retrying steps 2-3 in ${RETRY_WAIT}s"
      sleep "${RETRY_WAIT}"
    fi
  done

  audit || true
  if [[ "${step3}" == "ok" && ${AUDIT_LEAKS} -eq 0 ]]; then
    result="CLEAN"
  else
    result="FAILED"
  fi
  summary="cluster destroy: ${step1}; full destroy: ${step3}; audit: ${AUDIT_LEAKS} item(s) still billing or unchecked"
  log "RESULT ${result}: ${summary}"
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${result}" "${summary}" >"${STATE_DIR}/teardown.result"
  if [[ "${result}" == "CLEAN" ]]; then
    notify "ROSA auto-teardown finished: clean" "${summary}. Still run the runbook's cross-region audit. Log: ${LOG_FILE}"
    return 0
  fi
  notify "ROSA auto-teardown FAILED" "${summary}. Log: ${LOG_FILE}. Finish the teardown by hand (runbook: Verify and recover)."
  return 1
}

run_arm() {
  local offset now t0 t0_src deadline remaining calendar state linger v armed_subject armed_body
  local env_args=() args=() cmd=()
  log "=== Arm the ROSA auto-teardown timer$( ((DRY_RUN)) && echo " (dry run)") ==="
  offset="$(duration_to_sec "${FIRE_AFTER}")" || die "--fire-after: not a duration (like 8h15m, 45m, 3600): ${FIRE_AFTER}"
  now="$(date -u +%s)"
  if t0="$(read_t0)"; then
    t0_src="T0 from ${STATE_DIR}/t0"
  else
    t0="${now}"
    t0_src="now (no ${STATE_DIR}/t0)"
  fi
  deadline=$((t0 + offset))
  remaining=$((deadline - now))
  ((remaining >= 60)) || die "the deadline (${t0_src} + ${FIRE_AFTER}) has passed or is under a minute away: tear down now instead"
  calendar="$(fmt_utc "${deadline}" '%Y-%m-%d %H:%M:%S') UTC"
  log "fires at ${calendar} (${t0_src} + ${FIRE_AFTER}; ${remaining}s from now)"

  # The timer runs with this shell's PATH and AWS settings: check now that they suffice.
  preflight
  log "Timer"
  check_wsl_keepalive
  if command -v systemd-run >/dev/null 2>&1; then
    check_ok "systemd-run on PATH"
  else
    check_fail "systemd-run not found (WSL: enable systemd in /etc/wsl.conf, then 'wsl --shutdown')"
  fi
  state="$(systemctl --user is-system-running 2>/dev/null || true)"
  case "${state}" in
  running | degraded) check_ok "systemd user manager: ${state}" ;;
  *) check_fail "systemd user manager not running (${state:-unknown})" ;;
  esac
  linger="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)"
  if [[ "${linger}" == "yes" ]]; then
    check_ok "linger enabled (the timer survives logout)"
  else
    check_fail "linger is off: run 'loginctl enable-linger'"
  fi
  if systemctl --user is-active --quiet "${UNIT}.timer" 2>/dev/null; then
    check_fail "${UNIT}.timer is already armed: run --disarm first"
  fi
  [[ -n "${AWS_PROFILE:-}" ]] || check_info "AWS_PROFILE is not set: the unit uses the default credentials"

  env_args=(--setenv=PATH="${PATH}")
  [[ -n "${AWS_PROFILE:-}" ]] && env_args+=(--setenv=AWS_PROFILE="${AWS_PROFILE}")
  [[ -n "${REGION}" ]] && env_args+=(--setenv=AWS_REGION="${REGION}")
  for v in AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE OCM_CONFIG; do
    [[ -n "${!v:-}" ]] && env_args+=(--setenv="${v}=${!v}")
  done
  args=(--now --state-dir "${STATE_DIR}" --by-cluster-json "${BY_CLUSTER_JSON}" --log "${LOG_FILE}"
    --retries "${RETRIES}" --retry-wait "${RETRY_WAIT}")
  ((REGION_FROM_FLAG)) && args+=(--region "${REGION}")
  [[ -n "${SNS_TOPIC_ARN}" ]] && args+=(--sns-topic-arn "${SNS_TOPIC_ARN}")
  cmd=(systemd-run --user --unit="${UNIT}" --description="ROSA billing-first auto-teardown"
    --on-active="${remaining}s" --on-calendar="${calendar}" --timer-property=AccuracySec=1s
    "${env_args[@]}" -- "${SELF}" "${args[@]}")
  # Sent once armed: the phone must show it, which proves the alert path end to end.
  armed_subject="ROSA auto-teardown armed: fires at ${calendar}"
  armed_body="The billing-first teardown fires at ${calendar} (${t0_src} + ${FIRE_AFTER}) and reports its result here. No 'finished: clean' message within about an hour of that time: check by hand (docs/runbooks/rosa-validation/README.md, Verify and recover)."

  if ((DRY_RUN)); then
    log "would run:$(printf ' %q' "${cmd[@]}")"
    log "would publish to SNS: ${armed_subject}"
    log "Dry run: ${PROBLEMS} problem(s)."
    ((PROBLEMS == 0)) || return 1
    return 0
  fi
  ((PROBLEMS == 0)) || die "not arming: ${PROBLEMS} problem(s) above"
  mkdir -p "${STATE_DIR}"
  "${cmd[@]}"
  systemctl --user list-timers "${UNIT}.timer" --all --no-pager || true
  sns_publish "${armed_subject}" "${armed_body}"
  log "armed. Check: systemctl --user list-timers | grep ${UNIT}; the SNS email '${armed_subject}' on the phone; disarm: $(basename "$0") --disarm"
}

run_disarm() {
  local cmd=(systemctl --user stop "${UNIT}.timer")
  if ((DRY_RUN)); then
    log "would run:$(printf ' %q' "${cmd[@]}")"
    return 0
  fi
  "${cmd[@]}"
  systemctl --user reset-failed "${UNIT}.service" "${UNIT}.timer" >/dev/null 2>&1 || true
  if systemctl --user is-active --quiet "${UNIT}.service" 2>/dev/null; then
    log "note: a teardown is running right now (${UNIT}.service); it continues"
  fi
  systemctl --user list-timers --all --no-pager | grep -F "${UNIT}" || log "${UNIT}.timer is disarmed"
}

# --- Main ---

case "${MODE}" in
arm)
  run_arm
  exit $?
  ;;
disarm)
  run_disarm
  exit $?
  ;;
now) ;;
*) die "unknown mode: ${MODE}" ;;
esac

if ((DRY_RUN)); then
  run_teardown
  exit $?
fi

mkdir -p "${STATE_DIR}"
LOCK_DIR="${STATE_DIR}/teardown.lock"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    log "another teardown (pid ${pid}) holds ${LOCK_DIR}; exiting"
    exit 0
  fi
  rm -rf "${LOCK_DIR}"
  mkdir "${LOCK_DIR}" || die "cannot take the lock ${LOCK_DIR}"
fi
echo "$$" >"${LOCK_DIR}/pid"
trap 'rm -rf "${LOCK_DIR}"' EXIT

exec > >(tee -a "${LOG_FILE}") 2>&1
rc=0
run_teardown || rc=$?
exit "${rc}"

#!/usr/bin/env bash
set -euo pipefail

# Wait until an OLM Subscription has installed its operator: the Subscription AtLatestKnown and
# its installed ClusterServiceVersion Succeeded. It replaces kubernetes_manifest's wait on
# status.state, which said only "timed out waiting on field matchers" after 15 minutes
# (homelab 2026-10-26: an InstallPlan waited for a manual approval). Printed once, when first
# seen, so the operator can act while this waits:
#   - an InstallPlan that waits for a manual approval. OLM makes every InstallPlan in a
#     namespace Manual while any Subscription there asks for Manual approval: the message names
#     those Subscriptions, the CSVs the plan installs and the approve command, and an approval
#     lets this wait go on. An installed operator (its CSV Succeeded) whose upgrade waits for
#     an approval passes: the operator works, and the upgrade is not this apply's to approve;
#   - a Subscription condition that blocks the install (ResolutionFailed,
#     CatalogSourcesUnhealthy, InstallPlanFailed, InstallPlanMissing), and a failed InstallPlan.
# Fails after TIMEOUT_SEC with the last state, repeating those messages.
#
# Auth modes (via environment variables):
#   Kubeconfig: KUBECONFIG_PATH + KUBE_CONTEXT
#   Token:      TOKEN_SCRIPT + API_URL + ADMIN_PASS
#
# Required: SUB_NAMESPACE, SUB_NAME
# Optional: TIMEOUT_SEC (900), POLL_SEC (10)

: "${SUB_NAMESPACE:?SUB_NAMESPACE is required}"
: "${SUB_NAME:?SUB_NAME is required}"
TIMEOUT_SEC="${TIMEOUT_SEC:-900}"
POLL_SEC="${POLL_SEC:-10}"

for v in TIMEOUT_SEC POLL_SEC; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "error: $v must be a non-negative integer (got: ${!v})" >&2; exit 1; }
done

if [[ -n "${KUBECONFIG_PATH:-}" ]] && [[ -n "${KUBE_CONTEXT:-}" ]]; then
  KC=(kubectl "--kubeconfig=$KUBECONFIG_PATH" "--context=$KUBE_CONTEXT" --request-timeout=60s)
  CTX_FLAG="--context ${KUBE_CONTEXT} "
elif [[ -n "${TOKEN_SCRIPT:-}" ]] && [[ -n "${API_URL:-}" ]] && [[ -n "${ADMIN_PASS:-}" ]]; then
  TOKEN=$("$TOKEN_SCRIPT" "$API_URL" "cluster-admin" "$ADMIN_PASS" | jq -r '.status.token')
  KC=(kubectl "--server=$API_URL" "--token=$TOKEN" --insecure-skip-tls-verify --request-timeout=60s)
  CTX_FLAG=""
else
  echo "error: set KUBECONFIG_PATH+KUBE_CONTEXT or TOKEN_SCRIPT+API_URL+ADMIN_PASS" >&2
  exit 1
fi

SUB="${SUB_NAMESPACE}/${SUB_NAME}"
NOTES=""

# note <message>: print it the first time only.
note() {
  grep -qxF -- "$1" <<<"$NOTES" && return 0
  NOTES+="$1"$'\n'
  echo "  $1"
}

# check_plan <installplan> [installed CSV]: note a plan that waits for a manual approval (and
# set WAITS_APPROVAL), or one that failed.
check_plan() {
  local ip approval approved phase csvs manual next
  ip="$("${KC[@]}" -n "$SUB_NAMESPACE" get installplans.operators.coreos.com "$1" -o json 2>/dev/null)" || return 0
  read -r approval approved phase < <(jq -r '"\(.spec.approval // "-") \(.spec.approved // false) \(.status.phase // "-")"' <<<"$ip")
  if [[ "$approval" == Manual && "$approved" == false ]]; then
    WAITS_APPROVAL=1
    next="Approve it, and this wait goes on"
    if [[ -n "${2:-}" ]]; then next="The apply goes on with ${2}, installed; to upgrade, approve it"; fi
    csvs="$(jq -r '.spec.clusterServiceVersionNames // [] | join(", ")' <<<"$ip")"
    manual="$("${KC[@]}" -n "$SUB_NAMESPACE" get subscriptions.operators.coreos.com -o json 2>/dev/null \
      | jq -r '[.items[] | select(.spec.installPlanApproval == "Manual") | .metadata.name] | join(", ")')" || manual=""
    note "InstallPlan $1 waits for a manual approval (it installs ${csvs:-?}): OLM makes every InstallPlan in ${SUB_NAMESPACE} Manual while a Subscription there asks for Manual approval (${manual:-none found}). ${next}: kubectl ${CTX_FLAG}-n ${SUB_NAMESPACE} patch installplan $1 --type merge -p '{\"spec\":{\"approved\":true}}'"
  fi
  if [[ "$phase" == Failed ]]; then
    note "InstallPlan $1 failed: $(jq -r '[.status.conditions[]? | .message // .reason // empty] | last // "no message" | gsub("[\t\n\r]+"; " ")' <<<"$ip")"
  fi
}

echo "=== Waiting for ${SUB} to install its operator (up to ${TIMEOUT_SEC}s) ==="
deadline=$((SECONDS + TIMEOUT_SEC))
last=""
while :; do
  state="-" csv="-" plan="-" phase="-" WAITS_APPROVAL=0
  if sub="$("${KC[@]}" -n "$SUB_NAMESPACE" get subscriptions.operators.coreos.com "$SUB_NAME" -o json 2>/dev/null)"; then
    read -r state csv plan < <(jq -r '"\(.status.state // "-") \(.status.installedCSV // "-") \(.status.installPlanRef.name // .status.installplan.name // "-")"' <<<"$sub")
    while IFS= read -r line; do
      if [[ -n "$line" ]]; then note "$line"; fi
    done < <(jq -r '
      .status.conditions[]?
      | select(.status == "True")
      | select(.type == "ResolutionFailed" or .type == "CatalogSourcesUnhealthy" or .type == "InstallPlanFailed" or .type == "InstallPlanMissing")
      | "\(.type): \(.message // .reason // "" | gsub("[\t\n\r]+"; " "))"
    ' <<<"$sub")
    if [[ "$csv" != - ]]; then
      phase="$("${KC[@]}" -n "$SUB_NAMESPACE" get clusterserviceversions.operators.coreos.com "$csv" -o jsonpath='{.status.phase}' 2>/dev/null)" || phase="-"
      if [[ "$state" == AtLatestKnown && "$phase" == Succeeded ]]; then
        echo "  ${SUB}: ${csv} Succeeded"
        exit 0
      fi
    fi
    installed=""
    if [[ "$phase" == Succeeded ]]; then installed="$csv"; fi
    if [[ "$plan" != - ]]; then check_plan "$plan" "$installed"; fi
    if ((WAITS_APPROVAL)) && [[ -n "$installed" ]]; then
      echo "  ${SUB}: ${csv} Succeeded"
      exit 0
    fi
  else
    state="unreadable"
  fi
  key="state=${state} csv=${csv} phase=${phase:--} installPlan=${plan}"
  if [[ "$key" != "$last" ]]; then
    echo "  ${SUB}: ${key}"
    last="$key"
  fi
  if ((SECONDS >= deadline)); then
    echo "error: ${SUB} did not install its operator within ${TIMEOUT_SEC}s (${key})" >&2
    while IFS= read -r line; do
      if [[ -n "$line" ]]; then echo "  $line" >&2; fi
    done <<<"$NOTES"
    exit 1
  fi
  sleep "$POLL_SEC"
done

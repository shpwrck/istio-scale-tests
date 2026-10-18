#!/usr/bin/env bash
set -euo pipefail

# Argo CD application-controller sharding fix-ups for the platform apply (BACKLOG 9.1).
#
# MODE=reshard (default): run once every Argo CD cluster Secret exists. With
#   dynamicScalingEnabled the GitOps operator restarts the controller StatefulSet
#   seconds after the Secrets appear; a controller that starts mid-change can log
#   "has no assigned shard" for a cluster and never pick it up (its Applications keep
#   an empty sync/health status). Wait until the operator's own reconcile has settled
#   (StatefulSet at its replica count, rollout complete, STABLE_POLLS polls in a row),
#   then delete the controller pods once and wait until every replacement is Ready.
# MODE=app-status: fail when an Application still has an empty sync or health status
#   after APP_STATUS_TIMEOUT_SEC, naming its destination cluster. With
#   EXPECTED_DESTINATIONS (destination cluster names or servers, space or comma
#   separated) it also waits until at least one Application targets each of them: the
#   ApplicationSets generate the member Applications minutes after the apply, so
#   without it the check can pass on the hub's own Applications alone (ROSA 2026-10-16:
#   13 of 40 existed when it ran). It also fails on Applications whose sync status is
#   Unknown because Argo CD cannot load state from their destination cluster (a
#   ComparisonError about the cluster, such as a URL the hub cannot reach), quoting one
#   per cluster. Each poll reads the Applications once, so the tests see one list. A status
#   read when the check starts can predate the change that triggered it (a cluster Secret's
#   new URL or token takes effect at Argo CD's next comparison), so the first read notes
#   every Application's reconciledAt and requests a refresh, and an Application counts only
#   once Argo CD has compared it again.
#
# Auth modes (via environment variables):
#   Kubeconfig: KUBECONFIG_PATH + KUBE_CONTEXT
#   Token:      TOKEN_SCRIPT + API_URL + ADMIN_PASS
#
# Required: GITOPS_NS, ARGOCD_NAME (the ArgoCD CR; the StatefulSet is
#   <ARGOCD_NAME>-application-controller)
# Optional: MODE, SETTLE_SEC (30: let the operator see the new Secrets first),
#   POLL_SEC (10), STABLE_POLLS (3), ROLLOUT_TIMEOUT_SEC (600), APP_STATUS_TIMEOUT_SEC (900),
#   EXPECTED_DESTINATIONS (app-status; empty = no per-destination check)

: "${GITOPS_NS:?GITOPS_NS is required}"
: "${ARGOCD_NAME:?ARGOCD_NAME is required}"
MODE="${MODE:-reshard}"
SETTLE_SEC="${SETTLE_SEC:-30}"
POLL_SEC="${POLL_SEC:-10}"
STABLE_POLLS="${STABLE_POLLS:-3}"
ROLLOUT_TIMEOUT_SEC="${ROLLOUT_TIMEOUT_SEC:-600}"
APP_STATUS_TIMEOUT_SEC="${APP_STATUS_TIMEOUT_SEC:-900}"
EXPECTED_DESTINATIONS="${EXPECTED_DESTINATIONS:-}"

for v in SETTLE_SEC POLL_SEC STABLE_POLLS ROLLOUT_TIMEOUT_SEC APP_STATUS_TIMEOUT_SEC; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "error: $v must be a non-negative integer (got: ${!v})" >&2; exit 1; }
done
((STABLE_POLLS >= 1)) || STABLE_POLLS=1

if [[ -n "${KUBECONFIG_PATH:-}" ]] && [[ -n "${KUBE_CONTEXT:-}" ]]; then
  KC=(kubectl "--kubeconfig=$KUBECONFIG_PATH" "--context=$KUBE_CONTEXT" --request-timeout=60s)
elif [[ -n "${TOKEN_SCRIPT:-}" ]] && [[ -n "${API_URL:-}" ]] && [[ -n "${ADMIN_PASS:-}" ]]; then
  TOKEN=$("$TOKEN_SCRIPT" "$API_URL" "cluster-admin" "$ADMIN_PASS" | jq -r '.status.token')
  KC=(kubectl "--server=$API_URL" "--token=$TOKEN" --insecure-skip-tls-verify --request-timeout=60s)
else
  echo "error: set KUBECONFIG_PATH+KUBE_CONTEXT or TOKEN_SCRIPT+API_URL+ADMIN_PASS" >&2
  exit 1
fi

STS="${ARGOCD_NAME}-application-controller"
SELECTOR="app.kubernetes.io/name=${STS}"

# sts_state: "<settled 0/1> <replicas> <updateRevision>" from the StatefulSet; settled
# means the controller has observed the latest spec and every replica is updated and Ready.
sts_state() {
  local json
  json="$("${KC[@]}" -n "$GITOPS_NS" get statefulset "$STS" -o json 2>/dev/null)" || { echo "0 - -"; return 0; }
  jq -r '
    (.spec.replicas // 1) as $want
    | (.status.readyReplicas // 0) as $ready
    | (.status.updatedReplicas // 0) as $upd
    | ((.status.observedGeneration // 0) == (.metadata.generation // 0)) as $obs
    | ((.status.currentRevision // "") == (.status.updateRevision // "")) as $rev
    | "\(if $obs and $rev and $ready == $want and $upd == $want then 1 else 0 end) \($want) \(.status.updateRevision // "-")"
  ' <<<"$json"
}

# pod_lines: "<uid> <ready true/false> <terminating 0/1>" per controller pod.
pod_lines() {
  "${KC[@]}" -n "$GITOPS_NS" get pods -l "$SELECTOR" -o json 2>/dev/null | jq -r '
    .items[]
    | "\(.metadata.uid) \(([.status.conditions[]? | select(.type == "Ready") | .status] | first) == "True") \(if .metadata.deletionTimestamp then 1 else 0 end)"
  ' || true
}

wait_settled() {
  local deadline=$((SECONDS + ROLLOUT_TIMEOUT_SEC)) streak=0 prev="" settled want rev key
  while :; do
    read -r settled want rev <<<"$(sts_state)"
    key="${want}/${rev}"
    if [[ "$settled" == 1 ]] && ! pod_lines | awk '$3 == 1 { found = 1 } END { exit !found }'; then
      if [[ "$key" == "$prev" ]]; then streak=$((streak + 1)); else streak=1; fi
      prev="$key"
      if ((streak >= STABLE_POLLS)); then
        echo "  ${STS}: settled at ${want} replica(s), revision ${rev} (${streak} polls in a row)"
        return 0
      fi
    else
      streak=0
      prev=""
    fi
    if ((SECONDS >= deadline)); then
      echo "error: ${STS} did not settle within ${ROLLOUT_TIMEOUT_SEC}s (last state: settled=${settled} replicas=${want} revision=${rev})" >&2
      return 1
    fi
    sleep "$POLL_SEC"
  done
}

reshard() {
  "${KC[@]}" -n "$GITOPS_NS" get statefulset "$STS" -o name >/dev/null \
    || { echo "error: StatefulSet ${GITOPS_NS}/${STS} not found" >&2; exit 1; }
  if ((SETTLE_SEC > 0)); then
    echo "=== Waiting ${SETTLE_SEC}s for the GitOps operator to react to the cluster Secrets ==="
    sleep "$SETTLE_SEC"
  fi
  echo "=== Waiting for the operator's controller reconcile to settle ==="
  wait_settled
  local -a old=()
  local uid ready term
  while read -r uid ready term; do
    [[ -n "$uid" ]] && old+=("$uid")
  done < <(pod_lines)
  echo "=== Restarting ${#old[@]} application-controller pod(s) so every cluster is assigned a shard ==="
  "${KC[@]}" -n "$GITOPS_NS" delete pod -l "$SELECTOR" --wait=false
  local deadline=$((SECONDS + ROLLOUT_TIMEOUT_SEC)) settled want rev n_new n_ready stale
  while :; do
    read -r settled want rev <<<"$(sts_state)"
    n_new=0 n_ready=0 stale=0
    while read -r uid ready term; do
      [[ -n "$uid" ]] || continue
      if printf '%s\n' "${old[@]}" | grep -qxF "$uid"; then stale=1; continue; fi
      n_new=$((n_new + 1))
      [[ "$ready" == true && "$term" == 0 ]] && n_ready=$((n_ready + 1))
    done < <(pod_lines)
    if [[ "$settled" == 1 ]] && ((stale == 0 && n_new == want && n_ready == want)); then
      echo "  ${STS}: ${n_ready}/${want} replacement pod(s) Ready"
      return 0
    fi
    if ((SECONDS >= deadline)); then
      echo "error: ${STS}: replacement pods not Ready within ${ROLLOUT_TIMEOUT_SEC}s (${n_ready}/${want} Ready, old pods left: ${stale})" >&2
      exit 1
    fi
    sleep "$POLL_SEC"
  done
}

# The tests below read `kubectl get applications -o json` on stdin.

# app_status_missing: "<app>\t<destination>" for every Application whose sync or health
# status is empty (no controller shard has processed it).
app_status_missing() {
  jq -r '
    .items[]
    | select(((.status.sync.status // "") == "") or ((.status.health.status // "") == ""))
    | "\(.metadata.name)\t\(.spec.destination.name // .spec.destination.server // "?")"
  '
}

# dests_without_apps: every EXPECTED_DESTINATIONS entry that no Application targets yet
# (matched against destination.name and destination.server).
dests_without_apps() {
  [[ -n "$EXPECTED_DESTINATIONS" ]] || return 0
  jq -r --arg want "$EXPECTED_DESTINATIONS" '
    [.items[] | .spec.destination | (.name // empty), (.server // empty)] as $have
    | ($want | gsub(","; " ") | split(" ") | map(select(. != ""))) - $have
    | .[]
  '
}

# apps_unreachable: "<destination>\t<app>\t<message>" for every Application whose sync
# status is Unknown with a ComparisonError about its cluster: "Failed to load live state"
# or "failed to get cluster version/info" (connection refused, timeouts, 401/403). A repo
# or manifest error ("failed to generate manifest") is not counted: the cluster answered.
apps_unreachable() {
  jq -r '
    .items[]
    | select((.status.sync.status // "") == "Unknown")
    | . as $a
    | [.status.conditions[]? | select(.type == "ComparisonError") | (.message // "")
        | select(test("Failed to load live state|failed to get cluster (version|info)"))] as $m
    | select($m | length > 0)
    | "\($a.spec.destination.name // $a.spec.destination.server // "?")\t\($a.metadata.name)\t\($m[0] | gsub("[\t\n\r]+"; " "))"
  '
}

# apps_reconciled: {"<app>": "<reconciledAt>"} for every Application that has one.
apps_reconciled() {
  jq -c '[.items[] | select(.status.reconciledAt != null) | {key: .metadata.name, value: .status.reconciledAt}] | from_entries'
}

# apps_stale <apps_reconciled at the start>: "<app>\t<destination>" for every Application
# that Argo CD has not compared since then (same reconciledAt). One created since counts as
# compared, and one never compared shows in app_status_missing.
apps_stale() {
  jq -r --argjson since "$1" '
    .items[]
    | select(.status.reconciledAt != null and $since[.metadata.name] == .status.reconciledAt)
    | "\(.metadata.name)\t\(.spec.destination.name // .spec.destination.server // "?")"
  '
}

# request_refresh: ask Argo CD to compare every Application now (the refresh annotation that
# `argocd app get --refresh` sets) instead of at its periodic reconciliation. Best effort:
# that reconciliation (timeout.reconciliation, minutes) still comes without it.
request_refresh() {
  if ! "${KC[@]}" -n "$GITOPS_NS" annotate applications.argoproj.io --all \
    argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>"$APP_ERR_FILE"; then
    echo "WARNING: could not request a refresh of the Applications ($(tr '\n' ' ' <"$APP_ERR_FILE")); waiting for Argo CD's periodic reconciliation instead" >&2
  fi
}

app_status() {
  echo "=== Checking that every Application has a sync and health status (timeout ${APP_STATUS_TIMEOUT_SEC}s) ==="
  [[ -z "$EXPECTED_DESTINATIONS" ]] || echo "  and that each of these destinations has Applications: ${EXPECTED_DESTINATIONS}"
  local deadline=$((SECONDS + APP_STATUS_TIMEOUT_SEC)) apps total missing absent unreachable stale since="" read_err=""
  APP_ERR_FILE=$(mktemp)
  trap 'rm -f "$APP_ERR_FILE"' EXIT
  while :; do
    missing="" absent="" unreachable="" stale=""
    if apps="$("${KC[@]}" -n "$GITOPS_NS" get applications.argoproj.io -o json 2>"$APP_ERR_FILE")" \
      && total="$(jq '.items | length' <<<"$apps")" \
      && { [[ -n "$since" ]] || { since="$(apps_reconciled <<<"$apps")" && request_refresh; }; } \
      && missing="$(app_status_missing <<<"$apps")" \
      && absent="$(dests_without_apps <<<"$apps")" \
      && unreachable="$(apps_unreachable <<<"$apps")" \
      && stale="$(apps_stale "$since" <<<"$apps")"; then
      read_err=""
      if [[ -z "$missing" && -z "$absent" && -z "$unreachable" && -z "$stale" ]] && ((total > 0)); then
        echo "  all ${total} Application(s) have a sync and health status$([[ -z "$EXPECTED_DESTINATIONS" ]] || echo ", and every expected destination has Applications")"
        return 0
      fi
    else
      read_err="$(tr '\n' ' ' <"$APP_ERR_FILE")"
      read_err="${read_err:-the reply was not a list of Applications}"
    fi
    if ((SECONDS >= deadline)); then
      if [[ -n "$read_err" ]]; then
        echo "error: could not read the Applications in ${GITOPS_NS} after ${APP_STATUS_TIMEOUT_SEC}s: ${read_err}" >&2
        exit 1
      fi
      if [[ -z "$missing" && -z "$absent" && -z "$unreachable" && -z "$stale" ]]; then
        echo "error: no Applications found in ${GITOPS_NS} after ${APP_STATUS_TIMEOUT_SEC}s" >&2
        exit 1
      fi
      if [[ -n "$missing" ]]; then
        echo "error: Applications without a sync or health status after ${APP_STATUS_TIMEOUT_SEC}s; no controller shard owns their destination cluster:" >&2
        printf '%s\n' "$missing" | awk -F'\t' 'NF { printf "  %s (destination %s)\n", $1, $2 }' >&2
        echo "  Fix: delete the ${STS} pods in ${GITOPS_NS} once the StatefulSet is settled, then re-run the apply." >&2
      fi
      if [[ -n "$unreachable" ]]; then
        echo "error: Argo CD on the hub cannot load state from these clusters after ${APP_STATUS_TIMEOUT_SEC}s (their Applications are sync Unknown); one message per cluster:" >&2
        printf '%s\n' "$unreachable" | awk -F'\t' '
          NF >= 3 { if (!($1 in msg)) { order[++k] = $1; app[$1] = $2; msg[$1] = $3 } n[$1]++ }
          END { for (i = 1; i <= k; i++) { d = order[i]; printf "  %s: %s%s: %s\n", d, app[d], (n[d] > 1 ? " and " (n[d] - 1) " more" : ""), msg[d] } }' >&2
        echo "  Fix: a connection error (dial tcp, i/o timeout, no such host) means the URL the cluster was registered at is not reachable from the hub's Argo CD pods. That URL is the kubeconfig context's server unless cluster_api_url_overrides sets one; the hub and every other member (istiod reads the same URL) must reach it. Set cluster_api_url_overrides and re-run the apply. Unauthorized (401) or Forbidden (403) means the registration's token no longer works: see \"Rotating a member's token\" in terraform/platform/README.md." >&2
      fi
      if [[ -n "$stale" ]]; then
        echo "error: Argo CD has not compared these Applications again in the ${APP_STATUS_TIMEOUT_SEC}s since this check started, so their status can predate the apply:" >&2
        printf '%s\n' "$stale" | awk -F'\t' 'NF { printf "  %s (destination %s)\n", $1, $2 }' >&2
        echo "  Fix: check the ${STS} logs in ${GITOPS_NS} (a controller that owns no shard of a cluster never compares its Applications), then re-run the apply." >&2
      fi
      if [[ -n "$absent" ]]; then
        echo "error: no Application targets these destination clusters after ${APP_STATUS_TIMEOUT_SEC}s; they are mesh members, so every member ApplicationSet should have generated Applications for them. On kubernetes the ApplicationSets select the Argo CD cluster Secrets labelled istio-mesh-member=true (check: kubectl -n ${GITOPS_NS} get secrets -l argocd.argoproj.io/secret-type=cluster --show-labels); on openshift, the ACM PlacementDecisions. The ApplicationSets' conditions say why they generated nothing (kubectl -n ${GITOPS_NS} get applicationsets -o yaml):" >&2
        printf '%s\n' "$absent" | sed 's/^/  /' >&2
      fi
      exit 1
    fi
    sleep "$POLL_SEC"
  done
}

case "$MODE" in
reshard) reshard ;;
app-status) app_status ;;
*)
  echo "error: MODE must be reshard or app-status (got: $MODE)" >&2
  exit 1
  ;;
esac

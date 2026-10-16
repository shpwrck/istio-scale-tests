#!/usr/bin/env bash
set -euo pipefail

# Obtain an OpenShift OAuth bearer token and emit ExecCredential JSON
# for the Terraform kubernetes/helm provider exec plugin and the generated kubeconfig.
#
# Usage:  oc-token-exec-credential.sh <api_server_url> <username> <password>
#
# The token is cached per API server, user and password (a sha256 key; the password
# itself is never written) in a 0600 file under
#   ${OC_TOKEN_CACHE_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/oc-token-cache}
# and reused until OC_TOKEN_REFRESH_MARGIN_SEC before the expires_in the OAuth server
# returned, so thousands of `oc` calls share one OAuthAccessToken instead of logging in
# each time (BACKLOG 9.2). The ExecCredential carries status.expirationTimestamp, so
# kubectl and the providers also reuse it within a process. Concurrent callers wait on
# a lock instead of logging in in parallel. A failed login is retried
# OC_TOKEN_LOGIN_ATTEMPTS times with doubling backoff from OC_TOKEN_BACKOFF_S.
#
# Environment: OC_TOKEN_CACHE=0 disables the cache; OC_TOKEN_CACHE_DIR,
#   OC_TOKEN_REFRESH_MARGIN_SEC (300), OC_TOKEN_LOGIN_ATTEMPTS (4), OC_TOKEN_BACKOFF_S (2),
#   OC_TOKEN_LOCK_WAIT_SEC (60). To drop a token (a revoked one), delete the cache dir.

USAGE="usage: $0 <api_server_url> <username> <password>"
API_SERVER="${1:?$USAGE}"
USERNAME="${2:?$USAGE}"
PASSWORD="${3:?$USAGE}"

CACHE_ON="${OC_TOKEN_CACHE:-1}"
CACHE_DIR="${OC_TOKEN_CACHE_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/oc-token-cache}"
MARGIN="${OC_TOKEN_REFRESH_MARGIN_SEC:-300}"
ATTEMPTS="${OC_TOKEN_LOGIN_ATTEMPTS:-4}"
BACKOFF="${OC_TOKEN_BACKOFF_S:-2}"
LOCK_WAIT="${OC_TOKEN_LOCK_WAIT_SEC:-60}"
for v in MARGIN ATTEMPTS BACKOFF LOCK_WAIT; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "ERROR: ${v} must be a non-negative integer (got: ${!v})" >&2; exit 1; }
done
((ATTEMPTS >= 1)) || ATTEMPTS=1

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{ print $1 }'
  else shasum -a 256 | awk '{ print $1 }'; fi
}

# rfc3339 <epoch>: UTC timestamp (GNU date, then BSD date).
rfc3339() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

emit() {
  local token="$1" expires="$2"
  jq -n --arg t "$token" --arg e "$(rfc3339 "$expires")" \
    '{apiVersion: "client.authentication.k8s.io/v1beta1", kind: "ExecCredential",
      status: {token: $t, expirationTimestamp: $e}}'
}

# login: one OAuth challenge login; prints "<token> <expires_in>" or fails.
login() {
  local oauth_authorize location token expires_in
  oauth_authorize=$(curl -sk --max-time 30 "${API_SERVER}/.well-known/oauth-authorization-server" \
    | jq -r '.authorization_endpoint // empty' 2>/dev/null) || true
  if [[ -z "${oauth_authorize}" ]]; then
    echo "WARNING: no OAuth authorization endpoint at ${API_SERVER}" >&2
    return 1
  fi
  location=$(curl -sk --max-time 30 -u "${USERNAME}:${PASSWORD}" \
    "${oauth_authorize}?client_id=openshift-challenging-client&response_type=token" \
    -H "X-CSRF-Token: 1" \
    -D - -o /dev/null 2>/dev/null \
    | grep -i '^location:') || true
  token=$(echo "$location" | sed -n 's/.*access_token=\([^&]*\).*/\1/p' | tr -d '\r')
  expires_in=$(echo "$location" | sed -n 's/.*expires_in=\([0-9]*\).*/\1/p' | tr -d '\r')
  if [[ -z "${token}" ]]; then
    echo "WARNING: OAuth login to ${API_SERVER} returned no token" >&2
    return 1
  fi
  # The OAuth server always returns expires_in; assume its 24h default if it did not.
  printf '%s %s\n' "$token" "${expires_in:-86400}"
}

# login_retry: login with OC_TOKEN_LOGIN_ATTEMPTS tries and doubling backoff.
login_retry() {
  local i delay="$BACKOFF" out
  for ((i = 1; i <= ATTEMPTS; i++)); do
    if out="$(login)"; then
      printf '%s\n' "$out"
      return 0
    fi
    ((i < ATTEMPTS)) || break
    echo "WARNING: OAuth login attempt ${i}/${ATTEMPTS} failed; retrying in ${delay}s" >&2
    sleep "$delay"
    delay=$((delay * 2))
  done
  echo "ERROR: failed to obtain OAuth token from ${API_SERVER} after ${ATTEMPTS} attempt(s)" >&2
  return 1
}

if [[ "$CACHE_ON" == 0 ]]; then
  read -r token expires_in <<<"$(login_retry)" || exit 1
  [[ -n "${token:-}" ]] || exit 1
  emit "$token" $(($(date +%s) + expires_in))
  exit 0
fi

umask 077
mkdir -p "$CACHE_DIR"
chmod 700 "$CACHE_DIR" 2>/dev/null || true
KEY="$(printf '%s\n%s\n%s' "$API_SERVER" "$USERNAME" "$PASSWORD" | sha256_hex)"
CACHE_FILE="${CACHE_DIR}/${KEY}.json"
LOCK_DIR="${CACHE_DIR}/${KEY}.lock"

# cached: print "<token> <expires_epoch>" when the cache holds a token valid past the margin.
cached() {
  [[ -s "$CACHE_FILE" ]] || return 1
  local line token expires
  line="$(jq -r '"\(.token // "") \(.expires // 0)"' "$CACHE_FILE" 2>/dev/null)" || return 1
  read -r token expires <<<"$line"
  [[ -n "$token" && "$expires" =~ ^[0-9]+$ ]] || return 1
  (($(date +%s) + MARGIN < expires)) || return 1
  printf '%s %s\n' "$token" "$expires"
}

if hit="$(cached)"; then
  read -r token expires <<<"$hit"
  emit "$token" "$expires"
  exit 0
fi

# Lock (mkdir is atomic): one caller logs in, the others wait and then read its token.
# A lock whose owner is gone is broken.
release() { rm -rf "$LOCK_DIR"; }
locked=0
deadline=$((SECONDS + LOCK_WAIT))
while :; do
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" >"${LOCK_DIR}/pid"
    locked=1
    trap release EXIT
    break
  fi
  owner="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
  if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
    rm -rf "$LOCK_DIR"
    continue
  fi
  if hit="$(cached)"; then
    read -r token expires <<<"$hit"
    emit "$token" "$expires"
    exit 0
  fi
  ((SECONDS < deadline)) || break
  sleep 1
done
((locked)) || echo "WARNING: token cache lock ${LOCK_DIR} held for over ${LOCK_WAIT}s; logging in without it" >&2

if hit="$(cached)"; then
  read -r token expires <<<"$hit"
  emit "$token" "$expires"
  exit 0
fi

out="$(login_retry)" || exit 1
read -r token expires_in <<<"$out"
expires=$(($(date +%s) + expires_in))
tmp="$(mktemp "${CACHE_DIR}/.tok.XXXXXX")"
jq -n --arg t "$token" --argjson e "$expires" '{token: $t, expires: $e}' >"$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$CACHE_FILE"
emit "$token" "$expires"

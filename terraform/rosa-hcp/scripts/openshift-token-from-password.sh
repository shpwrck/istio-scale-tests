#!/usr/bin/env bash
# Reads JSON on stdin: api_url, cluster_domain, username, password. Prints {"token":"..."}.
# ROSA HCP: OAuth lives at oauth.<cluster_domain> (from /.well-known/oauth-authorization-server),
# not oauth-openshift.apps.<cluster_domain>. Password grant is usually disabled; implicit works.
# Requires: curl, jq
set -euo pipefail

INPUT="$(cat)"
API="$(echo "$INPUT" | jq -r .api_url)"
DOMAIN="$(echo "$INPUT" | jq -r .cluster_domain)"
USER="$(echo "$INPUT" | jq -r .username)"
PASS="$(echo "$INPUT" | jq -r .password)"

if [[ -z "$API" || "$API" == "null" ]]; then
  echo '{"error":"missing api_url"}' >&2
  exit 1
fi

API="${API%/}"

oauth_discovery() {
  curl -sk "${API}/.well-known/oauth-authorization-server"
}

extract_access_token_from_fragment() {
  local url="$1"
  local fragment
  fragment="${url#*#}"
  [[ "$fragment" != "$url" ]] || return 1
  local pair
  IFS='&' read -ra pairs <<<"$fragment"
  for pair in "${pairs[@]}"; do
    if [[ "$pair" == access_token=* ]]; then
      printf '%s' "${pair#access_token=}"
      return 0
    fi
  done
  return 1
}

try_password_grant() {
  local disc token_ep tmp http resp
  disc="$(oauth_discovery)" || return 1
  echo "$disc" | jq -e '.grant_types_supported | index("password") != null' >/dev/null 2>&1 || return 1
  token_ep="$(echo "$disc" | jq -r .token_endpoint)"
  [[ -n "$token_ep" && "$token_ep" != "null" ]] || return 1

  tmp="$(mktemp)"
  http="$(curl -sk -o "$tmp" -w '%{http_code}' -X POST "$token_ep" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "username=${USER}" \
    --data-urlencode "password=${PASS}" \
    --data-urlencode "client_id=openshift-cli-client")"
  resp="$(cat "$tmp")"
  rm -f "$tmp"
  if [[ "$http" == "200" ]]; then
    echo "$resp" | jq -r '.access_token // empty'
    return 0
  fi
  return 1
}

try_implicit_grant() {
  local disc auth_ep oauth loc
  disc="$(oauth_discovery)" || return 1
  auth_ep="$(echo "$disc" | jq -r '.authorization_endpoint // empty')"
  if [[ -z "$auth_ep" || "$auth_ep" == "null" ]]; then
    [[ -n "$DOMAIN" && "$DOMAIN" != "null" ]] || return 1
    auth_ep="https://oauth.${DOMAIN}/oauth/authorize"
  fi
  oauth="${auth_ep}?client_id=openshift-challenging-client&response_type=token"
  loc="$(curl -sk -u "${USER}:${PASS}" \
    -H "X-CSRF-Token: 1" \
    -o /dev/null -D - \
    "$oauth" | tr -d '\r' | grep -i '^location:' | tail -1 | sed 's/^[Ll]ocation: //; s/\r$//')"
  [[ -n "$loc" ]] || return 1
  extract_access_token_from_fragment "$loc"
}

TOK=""
TOK="$(try_password_grant)" || true
if [[ -z "$TOK" ]]; then
  TOK="$(try_implicit_grant)" || true
fi

if [[ -z "$TOK" ]]; then
  echo '{"error":"could not obtain OAuth token (password grant unsupported or failed; implicit authorize failed)"}' >&2
  exit 1
fi

jq -n --arg token "$TOK" '{token: $token}'

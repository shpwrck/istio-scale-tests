#!/usr/bin/env bats
# terraform/scripts/oc-token-exec-credential.sh (BACKLOG 9.2) against a stub curl: one OAuth
# login serves every call until shortly before the token expires, the cache file is 0600 and
# holds no password, failed logins are retried, and the ExecCredential carries an expiry.

load test_helper

SCRIPT="${ROOT}/terraform/scripts/oc-token-exec-credential.sh"

setup() {
	STUB_DIR="$(mktemp -d)"
	export STUB_DIR
	mkdir -p "${STUB_DIR}/bin"
	echo 0 >"${STUB_DIR}/logins"
	# curl: discovery answers with an authorize endpoint; each login answers with a fresh
	# token (tok-<n>) unless $STUB_DIR/fail holds a count of logins still to fail.
	cat >"${STUB_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
case " $* " in
*"/.well-known/oauth-authorization-server"*)
	echo '{"authorization_endpoint":"https://oauth.example/oauth/authorize"}' ;;
*"response_type=token"*)
	n=$(( $(cat "$STUB_DIR/logins") + 1 ))
	echo "$n" >"$STUB_DIR/logins"
	f=$(cat "$STUB_DIR/fail" 2>/dev/null || echo 0)
	if ((f > 0)); then
		echo $((f - 1)) >"$STUB_DIR/fail"
		printf 'HTTP/1.1 401 Unauthorized\r\n\r\n'
		exit 0
	fi
	printf 'HTTP/1.1 302 Found\r\nLocation: https://oauth.example/oauth/token/implicit#access_token=sha256~tok-%s&expires_in=%s&scope=user%%3Afull&token_type=Bearer\r\n\r\n' \
		"$n" "${STUB_EXPIRES_IN:-86400}" ;;
*) exit 7 ;;
esac
EOF
	chmod +x "${STUB_DIR}/bin/curl"
	export PATH="${STUB_DIR}/bin:${PATH}"
	export OC_TOKEN_CACHE_DIR="${STUB_DIR}/cache" OC_TOKEN_BACKOFF_S=0
}

teardown() {
	rm -rf "$STUB_DIR"
}

@test "token cache: 50 calls, one login, same token, an expirationTimestamp" {
	for _ in $(seq 1 50); do
		run bash "$SCRIPT" https://api.mesh-a.example:443 cluster-admin s3cret
		assert_success
		[ "$(jq -r .status.token <<<"$output")" = "sha256~tok-1" ]
	done
	[ "$(cat "${STUB_DIR}/logins")" -eq 1 ]
	exp="$(jq -r .status.expirationTimestamp <<<"$output")"
	[[ "$exp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
	run jq -r '.kind + " " + .apiVersion' <<<"$output"
	assert_output "ExecCredential client.authentication.k8s.io/v1beta1"
}

@test "token cache: the cache file is 0600, outside the repo, and holds no password" {
	run bash "$SCRIPT" https://api.mesh-a.example:443 cluster-admin s3cret
	assert_success
	f="$(find "${STUB_DIR}/cache" -name '*.json' -type f)"
	[ -n "$f" ]
	[ -n "$(find "$f" -perm 600)" ]
	[ -n "$(find "${STUB_DIR}/cache" -maxdepth 0 -perm 700)" ]
	run grep -c s3cret "$f"
	assert_output 0
}

@test "token cache: another API server, user or password is a separate entry" {
	bash "$SCRIPT" https://api.mesh-a.example:443 cluster-admin s3cret >/dev/null
	bash "$SCRIPT" https://api.mesh-b.example:443 cluster-admin s3cret >/dev/null
	bash "$SCRIPT" https://api.mesh-a.example:443 other s3cret >/dev/null
	bash "$SCRIPT" https://api.mesh-a.example:443 cluster-admin n3w >/dev/null
	bash "$SCRIPT" https://api.mesh-a.example:443 cluster-admin s3cret >/dev/null
	[ "$(cat "${STUB_DIR}/logins")" -eq 4 ]
}

@test "token cache: a token inside the refresh margin is replaced" {
	# expires_in 200 s is inside the default 300 s margin: every call logs in again.
	STUB_EXPIRES_IN=200 bash "$SCRIPT" https://api.mesh-a.example:443 cluster-admin s3cret >/dev/null
	STUB_EXPIRES_IN=200 bash "$SCRIPT" https://api.mesh-a.example:443 cluster-admin s3cret >/dev/null
	[ "$(cat "${STUB_DIR}/logins")" -eq 2 ]
	# A margin below the lifetime keeps it.
	OC_TOKEN_REFRESH_MARGIN_SEC=60 run bash "$SCRIPT" https://api.mesh-a.example:443 cluster-admin s3cret
	assert_success
	[ "$(cat "${STUB_DIR}/logins")" -eq 2 ]
}

@test "token cache: a failed login is retried with backoff, then succeeds" {
	echo 2 >"${STUB_DIR}/fail"
	run bash "$SCRIPT" https://api.mesh-a.example:443 cluster-admin s3cret
	assert_success
	assert_output --partial "attempt 1/4 failed"
	assert_output --partial "attempt 2/4 failed"
	[ "$(cat "${STUB_DIR}/logins")" -eq 3 ]
}

@test "token cache: every attempt failing exits 1 and caches nothing" {
	echo 9 >"${STUB_DIR}/fail"
	OC_TOKEN_LOGIN_ATTEMPTS=3 run bash "$SCRIPT" https://api.mesh-a.example:443 cluster-admin s3cret
	assert_failure
	assert_output --partial "failed to obtain OAuth token from https://api.mesh-a.example:443 after 3 attempt(s)"
	[ "$(cat "${STUB_DIR}/logins")" -eq 3 ]
	[ -z "$(find "${STUB_DIR}/cache" -name '*.json')" ]
}

@test "token cache: parallel callers share one login" {
	for i in $(seq 1 8); do
		bash "$SCRIPT" https://api.mesh-a.example:443 cluster-admin s3cret >"${STUB_DIR}/out.${i}" &
	done
	wait
	[ "$(cat "${STUB_DIR}/logins")" -eq 1 ]
	[ "$(cat "${STUB_DIR}"/out.* | jq -r .status.token | sort -u)" = "sha256~tok-1" ]
}

@test "token cache: a lock left by a dead process is broken" {
	bash "$SCRIPT" https://api.mesh-a.example:443 cluster-admin s3cret >/dev/null
	key="$(basename "$(find "${STUB_DIR}/cache" -name '*.json')" .json)"
	rm -f "${STUB_DIR}/cache/${key}.json"
	mkdir "${STUB_DIR}/cache/${key}.lock"
	echo 999999 >"${STUB_DIR}/cache/${key}.lock/pid"
	OC_TOKEN_LOCK_WAIT_SEC=5 run bash "$SCRIPT" https://api.mesh-a.example:443 cluster-admin s3cret
	assert_success
	refute_output --partial "logging in without it"
	[ ! -d "${STUB_DIR}/cache/${key}.lock" ]
}

@test "token cache: OC_TOKEN_CACHE=0 logs in every time and writes nothing" {
	OC_TOKEN_CACHE=0 bash "$SCRIPT" https://api.mesh-a.example:443 cluster-admin s3cret >/dev/null
	OC_TOKEN_CACHE=0 run bash "$SCRIPT" https://api.mesh-a.example:443 cluster-admin s3cret
	assert_success
	[ "$(jq -r .status.token <<<"$output")" = "sha256~tok-2" ]
	[ ! -d "${STUB_DIR}/cache" ]
}

#!/usr/bin/env bash
# Patch istio-remote-secret-* Secrets so embedded kubeconfigs use insecure-skip-tls-verify for the
# remote apiserver TLS handshake (lab fallback per OSSM multi-cluster troubleshooting — see AGENTS.md).
#
# Requires: bash 4+, oc, jq, base64, awk
#
# Usage: ./istio-setup/007-ossm-mc-remote-secrets-insecure-apiserver.sh [--dry-run]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

DRY_RUN=0
for a in "$@"; do
	[[ "$a" == "--dry-run" ]] && DRY_RUN=1
done

CLUSTERS=(rosa-001 rosa-002 rosa-003)
NS=istio-system

# stdin: kubeconfig YAML (istioctl remote-secret shape)
# stdout: patched YAML — strips certificate-authority* under each "- cluster:" block and ensures
#          insecure-skip-tls-verify: true (idempotent if already present).
patch_kubeconfig_tls_insecure() {
	awk '
	BEGIN { after_cluster_key = 0; inserted_insecure = 0 }
	/^[[:space:]]*-[[:space:]]*cluster:[[:space:]]*$/ {
		print
		after_cluster_key = 1
		inserted_insecure = 0
		next
	}
	after_cluster_key == 1 {
		if ($0 ~ /^[[:space:]]*certificate-authority-data:/) next
		if ($0 ~ /^[[:space:]]*certificate-authority:/) next
		if ($0 ~ /^[[:space:]]*insecure-skip-tls-verify:/) {
			inserted_insecure = 1
			print
			next
		}
		if ($0 ~ /^[[:space:]]{4}[^[:space:]]/) {
			if (!inserted_insecure) {
				print "    insecure-skip-tls-verify: true"
				inserted_insecure = 1
			}
			print
			next
		}
		if ($0 ~ /^[[:space:]]{2}[a-zA-Z]/ && $0 !~ /^[[:space:]]{4}/) {
			if (!inserted_insecure) {
				print "    insecure-skip-tls-verify: true"
				inserted_insecure = 1
			}
			after_cluster_key = 0
			print
			next
		}
		print
		next
	}
	{ print }
	'
}

patch_secret() {
	local dst=$1 src=$2
	local sec="istio-remote-secret-${src}"
	local key=$src

	local obj
	if ! obj=$(oc --context="$dst" get secret -n "$NS" "$sec" -o json 2>/dev/null); then
		return 0
	fi

	local b64
	b64=$(echo "$obj" | jq -r --arg k "$key" '.data[$k] // empty')
	if [[ -z "$b64" || "$b64" == "null" ]]; then
		return 0
	fi

	local cfg patched new_b64
	cfg=$(printf '%s' "$b64" | base64 -d)
	patched=$(printf '%s' "$cfg" | patch_kubeconfig_tls_insecure)
	new_b64=$(printf '%s' "$patched" | base64 -w0 2>/dev/null || printf '%s' "$patched" | base64 | tr -d '\n')

	if ((DRY_RUN)); then
		echo "dry-run: would patch ${sec} on ${dst} (secret bytes omitted)" >&2
		return 0
	fi

	echo "$obj" | jq --arg k "$key" --arg v "$new_b64" '.data[$k] = $v' |
		oc --context="$dst" apply -f -
	echo "patched ${sec} on ${dst}" >&2
}

main() {
	local dst src
	for dst in "${CLUSTERS[@]}"; do
		for src in "${CLUSTERS[@]}"; do
			[[ "$src" == "$dst" ]] && continue
			patch_secret "$dst" "$src"
		done
	done
}

# Allow `source`ing this file to reuse patch_kubeconfig_tls_insecure in tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi

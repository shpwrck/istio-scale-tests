#!/usr/bin/env bash
# Embed API server TLS material into kubeconfig for each context so istioctl create-remote-secret
# produces Secrets istiod can use when verifying remote apiservers.
# Procedure aligns with OSSM 3.3 multi-cluster preparation (see AGENTS.md / RH doc).
#
# ROSA public API often presents Let's Encrypt chains; kube-root-ca alone is not enough.
# This script builds a PEM from:
#   openssl s_client -showcerts (live chain) + https://letsencrypt.org/certs/isrgrootx1.pem
#
# If istiod still logs x509 errors on remote watches, use after regenerating secrets:
#   ./setup-scripts/05-ossm-mc-remote-secrets-insecure-apiserver.sh
# (development / lab only — skips apiserver TLS verification inside embedded kubeconfigs.)
#
# Updates your active kubeconfig (set KUBECONFIG to use a copy).
#
# Usage: ./setup-scripts/01-ossm-mc-kubeconfig-embed-api-ca.sh [--dry-run] [context ...]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

DRY_RUN=0
CTXS=()
for a in "$@"; do
	if [[ "$a" == "--dry-run" ]]; then
		DRY_RUN=1
		continue
	fi
	CTXS+=("$a")
done
((${#CTXS[@]})) || CTXS=(rosa-001 rosa-002 rosa-003)

TMPDIR=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

LE_ROOT_URL=https://letsencrypt.org/certs/isrgrootx1.pem
LE_ROOT="$TMPDIR/isrgrootx1.pem"

if ((DRY_RUN)); then
	echo "dry-run: would curl $LE_ROOT_URL"
	echo "dry-run: for each context, would openssl s_client + append ISRG root, then kubectl config set-cluster ..."
	for ctx in "${CTXS[@]}"; do
		echo "  context=$ctx"
	done
	echo "Done (dry-run)."
	exit 0
fi

curl -fsS "$LE_ROOT_URL" -o "$LE_ROOT"

for ctx in "${CTXS[@]}"; do
	if ! kubectl config get-contexts "$ctx" &>/dev/null; then
		echo "error: no kube context '$ctx'" >&2
		exit 1
	fi
	cluster=$(kubectl config view --raw --minify --context="$ctx" -o jsonpath='{.clusters[0].name}')
	server=$(kubectl config view --raw --minify --context="$ctx" -o jsonpath='{.clusters[0].cluster.server}')
	hostport=${server#https://}
	apihost=${hostport%%:*}
	cafile="$TMPDIR/ca-${ctx}-full.pem"
	echo | timeout 20 openssl s_client -showcerts -servername "$apihost" -connect "${apihost}:443" 2>/dev/null |
		sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' >"$cafile"
	cat "$LE_ROOT" >>"$cafile"
	kubectl config set-cluster "$cluster" --server="$server" --embed-certs=true --certificate-authority="$cafile"
	echo "embedded API CA (+ ISRG root) for context=$ctx cluster=$cluster"
done
echo "Done. Re-run: PATH=\"\$REPO/.bin:\$PATH\" ./setup-scripts/04-ossm-mc-remote-secrets.sh"
echo "Then restart istiod on each cluster if endpoints do not refresh:"
echo "  for c in rosa-001 rosa-002 rosa-003; do oc --context=\$c rollout restart deploy/istiod -n istio-system; done"

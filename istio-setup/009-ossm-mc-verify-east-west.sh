#!/usr/bin/env bash
# Verification helpers after east-west gateways + remote secrets + Istio are configured (read-only).
# Requires: oc contexts rosa-001/002/003; istioctl on PATH or ${REPO}/.bin (version pinned in config/versions.env).
#
# Usage (repo root): ./setup-scripts/07-ossm-mc-verify-east-west.sh [--dry-run]
# (--dry-run: no effect; all operations are read-only — accepted for consistent CLI with other setup scripts)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
export PATH="${ROOT}/.bin:${PATH}"

for a in "$@"; do
	[[ "$a" == "--dry-run" ]] && echo "note: --dry-run is a no-op; this script only runs read-only checks." >&2
done

if ! command -v istioctl &>/dev/null; then
	echo "error: istioctl not found. Add Istio-aligned istioctl (${ISTIO_VERSION}) to PATH or ${ROOT}/.bin/istioctl" >&2
	exit 2
fi

CLUSTERS=(rosa-001 rosa-002 rosa-003)

for ctx in "${CLUSTERS[@]}"; do
	echo "==================== ${ctx} ===================="
	echo "--- proxy-status (first 40 lines) ---"
	istioctl proxy-status --context="$ctx" 2>/dev/null | head -40 || echo "(istioctl failed — check kubeconfig)"
	echo "--- istio-system east-west Service / endpoints ---"
	oc --context="$ctx" get svc -n istio-system istio-eastwestgateway -o wide 2>/dev/null || true
	oc --context="$ctx" get endpoints -n istio-system istio-eastwestgateway -o wide 2>/dev/null || true
	echo "--- istiod pods ---"
	oc --context="$ctx" get pods -n istio-system -l app=istiod -o wide 2>/dev/null || true
	echo ""
done

echo "Optional: remote cluster discovery in istiod logs (example)"
echo "  oc --context=rosa-001 -n istio-system logs deploy/istiod --tail=200 | grep -iE 'remote|cluster|secret'"
echo ""
echo "Optional: endpoint dump from an injected workload pod"
echo "  istioctl proxy-config endpoint <pod>.<namespace> --context=<ctx>"

#!/usr/bin/env bash
# Multi-primary: install remote kubeconfig secrets so each istiod can read the others.
# Commands must match Red Hat OSSM 3.3 multi-cluster topologies (create-remote-secret).
#
# Requires: istioctl on PATH (pin ISTIO / Istio version via config/versions.env + AGENTS.md),
#           oc logged into all contexts.
#
# Usage: ./setup-scripts/04-ossm-mc-remote-secrets.sh [--dry-run]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

if ! command -v istioctl &>/dev/null; then
	echo "error: istioctl not found on PATH. Install OSSM/Istio-aligned istioctl (${ISTIO_VERSION}) or add ${ROOT}/.bin to PATH." >&2
	exit 2
fi

DRY_RUN=0
for a in "$@"; do
	[[ "$a" == "--dry-run" ]] && DRY_RUN=1
done

CLUSTERS=(rosa-001 rosa-002 rosa-003)

for SRC in "${CLUSTERS[@]}"; do
	for DST in "${CLUSTERS[@]}"; do
		[[ "$SRC" == "$DST" ]] && continue
		echo "--- Secret from ${SRC} (--name=${SRC}) -> ${DST} istio-system ---"
		if ((DRY_RUN)); then
			istioctl create-remote-secret \
				--context="${SRC}" \
				"--name=${SRC}" \
				--create-service-account=false |
				oc --context="${DST}" apply --dry-run=client -n istio-system -f -
		else
			istioctl create-remote-secret \
				--context="${SRC}" \
				"--name=${SRC}" \
				--create-service-account=false |
				oc --context="${DST}" apply -n istio-system -f -
		fi
	done
done
echo "Done."

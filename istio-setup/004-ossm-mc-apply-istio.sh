#!/usr/bin/env bash
# Apply Sail Operator Istio + IstioCNI from templates (OSSM 3.3 multi-cluster doc — see AGENTS.md).
# Istio/default includes mesh-wide Envoy access logging via meshConfig (ACCESS_LOG_* in config/versions.env).
#
# Requires: envsubst (gettext), oc
# Usage (repo root):
#   ./istio-setup/004-ossm-mc-apply-istio.sh [--contexts CSV] [--dry-run]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

SETUP_CONTEXTS="${SETUP_CONTEXTS:-rosa-001,rosa-002,rosa-003}"
CONTEXTS_CSV=""
DRY_RUN=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV   Comma-separated kube/oc context names (default: ${SETUP_CONTEXTS}).
  --dry-run        oc apply --dry-run=client only.

Environment:
  SETUP_CONTEXTS    Same as --contexts when the flag is omitted.
  ACCESS_LOG_FILE   Mesh access log path (default from versions.env, typically /dev/stdout).
  ACCESS_LOG_ENCODING  TEXT or JSON (default JSON).

Requires envsubst (gettext) and oc.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
		shift
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

[[ -z "$CONTEXTS_CSV" ]] && CONTEXTS_CSV="$SETUP_CONTEXTS"

CLUSTERS=()
IFS=',' read -ra _raw <<<"$CONTEXTS_CSV"
for c in "${_raw[@]}"; do
	c="${c#"${c%%[![:space:]]*}"}"
	c="${c%"${c##*[![:space:]]}"}"
	[[ -n "$c" ]] && CLUSTERS+=("$c")
done
((${#CLUSTERS[@]})) || die "no contexts parsed from: ${CONTEXTS_CSV}"

if ! command -v envsubst >/dev/null 2>&1; then
	echo "error: envsubst not found (install gettext / gettext-envsubst)" >&2
	exit 2
fi

apply=(oc apply)
((DRY_RUN)) && apply=(oc apply --dry-run=client)

TPL="${ROOT}/manifests/ossm-multi-cluster/templates"

for ctx in "${CLUSTERS[@]}"; do
	export CLUSTER_KEY="$ctx"
	export NETWORK="${CLUSTER_KEY}-${NETWORK_SUFFIX}"
	echo "[$ctx] IstioCNI (${ISTIO_VERSION})"
	envsubst <"${TPL}/istio-cni.yaml.tpl" | "${apply[@]}" --context="$ctx" -f -
	echo "[$ctx] Istio/default (${CLUSTER_KEY} / ${NETWORK}) — access logs: ${ACCESS_LOG_FILE} (${ACCESS_LOG_ENCODING})"
	envsubst <"${TPL}/istio.cluster.yaml.tpl" | "${apply[@]}" --context="$ctx" -f -
	if ((DRY_RUN)); then
		echo "[$ctx] dry-run: skipping wait for Istio Ready"
		continue
	fi
	echo "[$ctx] waiting for Istio/default Ready (timeout 5m)"
	oc --context="$ctx" wait --for=condition=Ready "istio/default" --timeout=5m 2>/dev/null || {
		echo "[$ctx] warn: wait timed out or condition unknown — check: oc --context=$ctx describe istio default"
	}
done
echo "Done."

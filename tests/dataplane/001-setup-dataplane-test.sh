#!/usr/bin/env bash
# Deploy fortio server and client pods for cross-cluster data-plane latency testing.
#
# The chart emits two Services per cluster:
#   - dataplane-server                  (generic; selects local pods under locality LB)
#   - dataplane-server-${clusterName}   (per-cluster; forces cross-cluster routing)
#
# Usage:
#   ./tests/dataplane/001-setup-dataplane-test.sh --source-context CTX [--remote-contexts CSV] [options]
#
# Examples:
#   # Server on all clusters, client on rosa-001:
#   ./tests/dataplane/001-setup-dataplane-test.sh --source-context rosa-001 --remote-contexts rosa-002,rosa-003
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

SOURCE_CTX=""
REMOTE_CONTEXTS_CSV=""
DRY_RUN=0
WAIT_TIMEOUT=300
NS="${DATAPLANE_TEST_NAMESPACE:-dataplane-test}"
FORTIO_TAG="${FORTIO_VERSION:-stable}"

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --source-context CTX     Kube context for the client (required).
  --remote-contexts CSV    Remote cluster contexts for servers (comma-separated).
  --dry-run                Pass --dry-run=client to oc apply.
  --wait-timeout N         Seconds to wait for pods (default: 300).
  -h, --help               Show this help.

Environment:
  SETUP_CONTEXTS, DATAPLANE_TEST_NAMESPACE, FORTIO_VERSION.
EOF
}

split_csv() {
	local csv="$1"
	local -n _out="$2"
	_out=()
	local x
	IFS=',' read -ra _raw <<<"$csv"
	for x in "${_raw[@]}"; do
		x="${x#"${x%%[![:space:]]*}"}"
		x="${x%"${x##*[![:space:]]}"}"
		[[ -n "$x" ]] && _out+=("$x")
	done
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--source-context)
		[[ -n "${2:-}" ]] || die "--source-context requires a value"
		SOURCE_CTX="$2"
		shift 2
		;;
	--remote-contexts)
		[[ -n "${2:-}" ]] || die "--remote-contexts requires a value"
		REMOTE_CONTEXTS_CSV="$2"
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--wait-timeout)
		[[ -n "${2:-}" ]] || die "--wait-timeout requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--wait-timeout must be a positive integer"
		(( $2 > 0 )) || die "--wait-timeout must be > 0"
		WAIT_TIMEOUT="$2"
		shift 2
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

[[ -n "$SOURCE_CTX" ]] || die "--source-context is required"

if command -v oc >/dev/null 2>&1; then
	KUBECTL=(oc)
elif command -v kubectl >/dev/null 2>&1; then
	KUBECTL=(kubectl)
else
	die "neither oc nor kubectl found on PATH"
fi

command -v helm >/dev/null 2>&1 || die "helm not found on PATH"

REMOTES=()
if [[ -n "$REMOTE_CONTEXTS_CSV" ]]; then
	split_csv "$REMOTE_CONTEXTS_CSV" REMOTES
fi

ALL_CTXS=("$SOURCE_CTX" "${REMOTES[@]}")

apply=("${KUBECTL[@]}" apply --server-side --force-conflicts)
((DRY_RUN)) && apply=("${KUBECTL[@]}" apply --dry-run=client)

CHART_DIR="${ROOT}/tests/dataplane/chart"

# Build --set flags for allClusterNames so every cluster gets per-cluster
# Services for ALL clusters. Without this, DNS can't resolve
# dataplane-server-${remote} on the source cluster (unless Istio DNS
# proxying is enabled, which is not the default on OSSM 3.x).
ALL_CN_SETS=()
for i in "${!ALL_CTXS[@]}"; do
	ALL_CN_SETS+=(--set "allClusterNames[$i]=${ALL_CTXS[$i]}")
done

echo "Deploying fortio server on all clusters (image tag: ${FORTIO_TAG})..."
for ctx in "${ALL_CTXS[@]}"; do
	echo "  Server on $ctx"
	helm template dataplane-test "$CHART_DIR" \
		--set clusterName="$ctx" \
		--set namespace="$NS" \
		--set role=server \
		--set image.tag="$FORTIO_TAG" \
		"${ALL_CN_SETS[@]}" \
		| "${apply[@]}" --context="$ctx" -f -
done

echo "Deploying fortio client on source cluster $SOURCE_CTX..."
helm template dataplane-test "$CHART_DIR" \
	--set clusterName="$SOURCE_CTX" \
	--set namespace="$NS" \
	--set role=both \
	--set image.tag="$FORTIO_TAG" \
	"${ALL_CN_SETS[@]}" \
	| "${apply[@]}" --context="$SOURCE_CTX" -f -

if ((DRY_RUN)); then
	echo "Dry-run complete."
	exit 0
fi

echo "Waiting for pods to be ready (timeout: ${WAIT_TIMEOUT}s)..."
for ctx in "${ALL_CTXS[@]}"; do
	echo "  Waiting for deployments on $ctx..."
	"${KUBECTL[@]}" --context="$ctx" -n "$NS" wait \
		--for=condition=Available deployment \
		-l app.kubernetes.io/instance=dataplane-test \
		--timeout="${WAIT_TIMEOUT}s" || die "deployment(s) not ready on $ctx"
done

echo "Setup complete. Server on: ${ALL_CTXS[*]}  Client on: $SOURCE_CTX"

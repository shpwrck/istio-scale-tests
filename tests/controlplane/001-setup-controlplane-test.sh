#!/usr/bin/env bash
# Deploy dummy workloads for measuring istiod control-plane resource consumption.
#
# Usage:
#   ./tests/controlplane/001-setup-controlplane-test.sh [--contexts CSV] [options]
#
# Examples:
#   # Setup on all default clusters:
#   ./tests/controlplane/001-setup-controlplane-test.sh
#
#   # Setup with custom workload size:
#   ./tests/controlplane/001-setup-controlplane-test.sh --service-count 50 --replicas 5
#
#   # Setup with namespace-scoped Sidecar CRs:
#   ./tests/controlplane/001-setup-controlplane-test.sh --sidecar-scoping namespace
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
DRY_RUN=0
WAIT_TIMEOUT=300
NS="${CONTROLPLANE_TEST_NAMESPACE:-controlplane-test}"
SERVICE_COUNT="${CONTROLPLANE_SERVICE_COUNT:-10}"
REPLICAS="${CONTROLPLANE_REPLICAS_PER_SERVICE:-3}"
SIDECAR_SCOPING="${CONTROLPLANE_SIDECAR_SCOPING:-none}"

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV             Kube contexts to target (default: \$SETUP_CONTEXTS).
  --service-count N          Number of dummy services per cluster (default: $SERVICE_COUNT).
  --replicas N               Replicas per service (default: $REPLICAS).
  --sidecar-scoping MODE     Sidecar CR scoping: none|namespace|explicit (default: $SIDECAR_SCOPING).
                             none      - no Sidecar CRs (baseline; worst-case config size).
                             namespace - one namespace-scoped Sidecar per workload namespace.
                             explicit  - one Sidecar per Deployment with workloadSelector.
  --dry-run                  Pass --dry-run=client to oc apply.
  --wait-timeout N           Seconds to wait for pods (default: 300).
  -h, --help                 Show this help.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_TEST_NAMESPACE, CONTROLPLANE_SERVICE_COUNT,
  CONTROLPLANE_REPLICAS_PER_SERVICE, CONTROLPLANE_SIDECAR_SCOPING.
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

validate_scoping() {
	case "$1" in
	none | namespace | explicit) return 0 ;;
	*) die "--sidecar-scoping must be one of [none, namespace, explicit]; got '$1'" ;;
	esac
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"
		shift 2
		;;
	--service-count)
		[[ -n "${2:-}" ]] || die "--service-count requires a value"
		SERVICE_COUNT="$2"
		shift 2
		;;
	--replicas)
		[[ -n "${2:-}" ]] || die "--replicas requires a value"
		REPLICAS="$2"
		shift 2
		;;
	--sidecar-scoping)
		[[ -n "${2:-}" ]] || die "--sidecar-scoping requires a value"
		SIDECAR_SCOPING="$2"
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--wait-timeout)
		[[ -n "${2:-}" ]] || die "--wait-timeout requires a value"
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

validate_scoping "$SIDECAR_SCOPING"

if command -v oc >/dev/null 2>&1; then
	KUBECTL=(oc)
elif command -v kubectl >/dev/null 2>&1; then
	KUBECTL=(kubectl)
else
	die "neither oc nor kubectl found on PATH"
fi

command -v helm >/dev/null 2>&1 || die "helm not found on PATH"

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_csv "$CONTEXTS_CSV" CONTEXTS
else
	split_csv "$SETUP_CONTEXTS" CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

# Server-side apply avoids kubectl OOM at thousands of objects (PL5).
apply=("${KUBECTL[@]}" apply --server-side --force-conflicts)
((DRY_RUN)) && apply=("${KUBECTL[@]}" apply --dry-run=client)

CHART_DIR="${ROOT}/tests/controlplane/chart"

for ctx in "${CONTEXTS[@]}"; do
	echo "Setting up controlplane-test on context $ctx (${SERVICE_COUNT} services × ${REPLICAS} replicas, sidecar-scoping=${SIDECAR_SCOPING})"
	helm template controlplane-test "$CHART_DIR" \
		--set clusterName="$ctx" \
		--set namespace="$NS" \
		--set serviceCount="$SERVICE_COUNT" \
		--set replicasPerService="$REPLICAS" \
		--set sidecarScoping="$SIDECAR_SCOPING" \
		| "${apply[@]}" --context="$ctx" -f -
done

if ((DRY_RUN)); then
	echo "Dry-run complete."
	exit 0
fi

echo "Waiting for dummy deployments to be ready (timeout: ${WAIT_TIMEOUT}s)..."
for ctx in "${CONTEXTS[@]}"; do
	echo "  Waiting on context $ctx..."
	for ((i = 0; i < SERVICE_COUNT; i++)); do
		"${KUBECTL[@]}" --context="$ctx" -n "$NS" wait "deployment/dummy-svc-${i}" \
			--for=condition=Available --timeout="${WAIT_TIMEOUT}s" || die "dummy-svc-${i} not ready on $ctx"
	done
	echo "  All deployments ready on $ctx."
done

# PL4: confirm Sidecar CRs landed when scoping is enabled.
if [[ "$SIDECAR_SCOPING" != "none" ]]; then
	echo "Verifying Sidecar CRs (sidecar-scoping=${SIDECAR_SCOPING})..."
	for ctx in "${CONTEXTS[@]}"; do
		deadline=$(( $(date +%s) + 30 ))
		count=0
		while (( $(date +%s) < deadline )); do
			count=$("${KUBECTL[@]}" --context="$ctx" -n "$NS" get sidecars.networking.istio.io \
				--no-headers --ignore-not-found 2>/dev/null | wc -l | tr -d ' ')
			[[ -z "$count" ]] && count=0
			(( count > 0 )) && break
			sleep 1
		done
		(( count > 0 )) || die "no Sidecar CRs found on $ctx after 30s (expected >=1 for scoping=$SIDECAR_SCOPING)"
		echo "  [$ctx] Sidecar CR count: $count"
	done
fi

echo "Setup complete. ${SERVICE_COUNT} services × ${REPLICAS} replicas (sidecar-scoping=${SIDECAR_SCOPING}) on: ${CONTEXTS[*]}"

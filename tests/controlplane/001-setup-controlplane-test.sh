#!/usr/bin/env bash
# Deploy dummy workloads for measuring istiod control-plane resource consumption.
#
# Applies one workload configuration (single point in the sweep cube) to each
# target cluster: SERVICE_COUNT services × REPLICAS pods, distributed across
# NAMESPACE_COUNT namespaces (service `i` lands in namespace `i mod N`).
#
# Backwards compat: when --namespace-count is 1 (default), the single namespace
# keeps its historical name `${NS}` (e.g. `controlplane-test`). When > 1,
# namespaces are named `${NS}-0`, `${NS}-1`, ..., `${NS}-(N-1)`.
#
# Manifests are applied with server-side apply (`--server-side
# --force-conflicts`); we use a label-selector wait per namespace instead of
# looping per Deployment.
#
# Usage:
#   ./tests/controlplane/001-setup-controlplane-test.sh [--contexts CSV] [options]
#
# Examples:
#   # Setup on all default clusters (single namespace, 10 services × 3 replicas):
#   ./tests/controlplane/001-setup-controlplane-test.sh
#
#   # Setup with custom workload size:
#   ./tests/controlplane/001-setup-controlplane-test.sh --service-count 50 --replicas 5
#
#   # Spread 100 services across 10 namespaces:
#   ./tests/controlplane/001-setup-controlplane-test.sh --service-count 100 --namespace-count 10
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
NAMESPACE_COUNT="${CONTROLPLANE_NAMESPACE_COUNT:-1}"

die() { echo "error: $*" >&2; exit 1; }

is_pos_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
is_nonneg_int() { [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --contexts CSV       Kube contexts to target (default: \$SETUP_CONTEXTS).
  --service-count N    Number of dummy services per cluster (default: $SERVICE_COUNT).
  --replicas N         Replicas per service (default: $REPLICAS).
  --namespace-count N  Spread services across N namespaces (default: $NAMESPACE_COUNT).
                       N=1 -> single namespace named '$NS'.
                       N>1 -> namespaces '${NS}-0' .. '${NS}-(N-1)';
                       service i lands in namespace (i mod N).
  --dry-run            Pass --dry-run=client to oc apply
                       (skips the --server-side path).
  --wait-timeout N     Seconds to wait for pods (default: 300).
  -h, --help           Show this help.

Environment:
  SETUP_CONTEXTS, CONTROLPLANE_TEST_NAMESPACE, CONTROLPLANE_SERVICE_COUNT,
  CONTROLPLANE_REPLICAS_PER_SERVICE, CONTROLPLANE_NAMESPACE_COUNT.
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
	--namespace-count)
		[[ -n "${2:-}" ]] || die "--namespace-count requires a value"
		NAMESPACE_COUNT="$2"
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

is_pos_int "$SERVICE_COUNT" || die "--service-count must be a positive integer (got: $SERVICE_COUNT)"
is_pos_int "$REPLICAS" || die "--replicas must be a positive integer (got: $REPLICAS)"
is_pos_int "$NAMESPACE_COUNT" || die "--namespace-count must be a positive integer (got: $NAMESPACE_COUNT)"
is_nonneg_int "$WAIT_TIMEOUT" || die "--wait-timeout must be a non-negative integer (got: $WAIT_TIMEOUT)"

if ((NAMESPACE_COUNT > SERVICE_COUNT)); then
	echo "warning: --namespace-count ($NAMESPACE_COUNT) > --service-count ($SERVICE_COUNT); some namespaces will be empty" >&2
fi

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

# Compute the list of namespaces to wait against. Mirror the chart's
# backwards-compat rule (N=1 -> single namespace = $NS; N>1 -> $NS-i).
NAMESPACES=()
if ((NAMESPACE_COUNT <= 1)); then
	NAMESPACES=("$NS")
else
	for ((n = 0; n < NAMESPACE_COUNT; n++)); do
		NAMESPACES+=("${NS}-${n}")
	done
fi

echo "=== Control-plane test setup ==="
echo "Contexts:        ${CONTEXTS[*]}"
echo "Services:        $SERVICE_COUNT"
echo "Replicas/svc:    $REPLICAS"
echo "Namespace count: $NAMESPACE_COUNT"
echo "Namespaces:      ${NAMESPACES[*]}"
((DRY_RUN)) && echo "Mode:            dry-run"
echo ""

# Use server-side apply so partial updates and field-manager ownership are
# tracked by the API server (no client-side last-applied annotation). With
# --force-conflicts we win any field-ownership conflict from a previous
# kubectl-client-side-apply run, which is what we want for a benchmarking
# harness that owns these namespaces exclusively.
apply=("${KUBECTL[@]}" apply --server-side --force-conflicts)
((DRY_RUN)) && apply=("${KUBECTL[@]}" apply --dry-run=client)

CHART_DIR="${ROOT}/tests/controlplane/chart"

for ctx in "${CONTEXTS[@]}"; do
	echo "Setting up controlplane-test on context $ctx (${SERVICE_COUNT} services × ${REPLICAS} replicas across ${NAMESPACE_COUNT} namespace(s))"
	helm template controlplane-test "$CHART_DIR" \
		--set clusterName="$ctx" \
		--set namespacePrefix="$NS" \
		--set namespaceCount="$NAMESPACE_COUNT" \
		--set serviceCount="$SERVICE_COUNT" \
		--set replicasPerService="$REPLICAS" \
		| "${apply[@]}" --context="$ctx" -f -
done

if ((DRY_RUN)); then
	echo "Dry-run complete."
	exit 0
fi

# Wait per-namespace using a label selector — one kubectl call covers every
# dummy-svc-* Deployment in that namespace, regardless of count. Much faster
# than per-Deployment loops, and survives missing-name races during rollout.
echo "Waiting for dummy deployments to be ready (timeout: ${WAIT_TIMEOUT}s)..."
for ctx in "${CONTEXTS[@]}"; do
	echo "  Waiting on context $ctx..."
	for svc_ns in "${NAMESPACES[@]}"; do
		"${KUBECTL[@]}" --context="$ctx" -n "$svc_ns" wait \
			--for=condition=Available deployment \
			-l app.kubernetes.io/instance=controlplane-test \
			--timeout="${WAIT_TIMEOUT}s" \
			|| die "deployments in namespace $svc_ns on $ctx not Available within ${WAIT_TIMEOUT}s"
	done
	echo "  All deployments ready on $ctx."
done

echo "Setup complete. ${SERVICE_COUNT} services × ${REPLICAS} replicas across ${NAMESPACE_COUNT} namespace(s) on: ${CONTEXTS[*]}"

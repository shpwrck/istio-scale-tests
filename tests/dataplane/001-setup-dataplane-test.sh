#!/usr/bin/env bash
# Deploy fortio server pods on every cluster and the fortio client on the source.
#
# Every cluster gets a Service dataplane-server-<ctx> for each context, selecting
# only that cluster's server pods: the source's own Service is the local baseline,
# the others force traffic through the east-west gateway. Every cluster runs the
# same number of server pods (--server-replicas), so local and remote targets have
# the same server capacity.
#
# Usage:
#   ./tests/dataplane/001-setup-dataplane-test.sh --source-context CTX [--remote-contexts CSV] [options]
#
# Examples:
#   # Server on both clusters, client on the first:
#   ./tests/dataplane/001-setup-dataplane-test.sh --source-context <mesh-a-ctx> --remote-contexts <mesh-b-ctx>
#
#   # Server replicas and wait timeout from a run config (README, "Run config"):
#   ./tests/dataplane/001-setup-dataplane-test.sh --config tests/dataplane/configs/smoke.env \
#     --source-context <mesh-a-ctx> --remote-contexts <mesh-b-ctx>
# ci-dry-run-skip: needs valid kubeconfig context for kubectl apply --dry-run=client
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
config_preload dataplane "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

SOURCE_CTX=""
REMOTE_CONTEXTS_CSV=""
DRY_RUN=0
WAIT_TIMEOUT="${DATAPLANE_WAIT_TIMEOUT_SEC:-300}"
NS="${DATAPLANE_TEST_NAMESPACE:-dataplane-test}"
FORTIO_TAG="$FORTIO_VERSION"
SERVER_REPLICAS="${DATAPLANE_SERVER_REPLICAS:-2}"


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE            Run config of KEY=value lines (config/options.env keys; see
                           tests/dataplane/README.md, "Run config").
                           Precedence: flag > --config > environment > default.
  --source-context CTX     Kube context for the client (required).
  --remote-contexts CSV    Remote cluster contexts for servers (comma-separated).
  --dry-run                Pass --dry-run=client to oc apply.
  --wait-timeout N         Seconds to wait for pods (default: $WAIT_TIMEOUT).
  --server-replicas N      fortio server pods per cluster, local and remote alike
                           (default: $SERVER_REPLICAS).
  -h, --help               Show this help.

Context names are used in Service names (dataplane-server-<ctx>), so each must
be a lowercase DNS label of at most 46 characters; rename others with
'kubectl config rename-context'.

Environment:
  DATAPLANE_TEST_NAMESPACE, DATAPLANE_SERVER_REPLICAS, FORTIO_VERSION,
  DATAPLANE_WAIT_TIMEOUT_SEC (--wait-timeout default, 300).
EOF
}


while [[ $# -gt 0 ]]; do
	case "$1" in
	--config)
		# Loaded by config_preload above.
		[[ -n "${2:-}" ]] || die "--config requires a value"
		shift 2
		;;
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
	--server-replicas)
		[[ -n "${2:-}" ]] || die "--server-replicas requires a value"
		SERVER_REPLICAS="$2"
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
is_pos_int "$WAIT_TIMEOUT" || die "--wait-timeout (or DATAPLANE_WAIT_TIMEOUT_SEC) must be a positive integer; got '$WAIT_TIMEOUT'"
is_pos_int "$SERVER_REPLICAS" || die "--server-replicas (or DATAPLANE_SERVER_REPLICAS) must be a positive integer; got '$SERVER_REPLICAS'"

KUBECTL=()
resolve_kubectl KUBECTL
command -v helm >/dev/null 2>&1 || die "helm not found on PATH"

REMOTES=()
if [[ -n "$REMOTE_CONTEXTS_CSV" ]]; then
	split_contexts "$REMOTE_CONTEXTS_CSV" REMOTES --remote-contexts "$SOURCE_CTX"
fi

ALL_CTXS=("$SOURCE_CTX" "${REMOTES[@]}")

# "dataplane-server-" + ctx must be a valid Service name (DNS-1035 label, <= 63).
for ctx in "${ALL_CTXS[@]}"; do
	is_dns_label_for dataplane-server- "$ctx" \
		|| die "context '$ctx' is not a lowercase DNS label of <= 46 chars (used in Service name dataplane-server-<ctx>); rename it with: kubectl config rename-context '$ctx' <new-name>"
done

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

if (( ${#ALL_CTXS[@]} > 10 )); then
	echo "warn: ${#ALL_CTXS[@]} clusters creates ~$(( ${#ALL_CTXS[@]} * ${#ALL_CTXS[@]} )) Services (N² scaling); expect slower setup and higher istiod memory" >&2
fi

# Apply the server to every context concurrently, wait for all, THEN apply
# role=both on the source (it supersedes the source's server-only render). Both
# renders set server.replicas, or the role=both apply would reset it (PL27).
echo "Deploying fortio server on all clusters (image tag: ${FORTIO_TAG})..."
echo "Server replicas per cluster: ${SERVER_REPLICAS}"
APPLY_PIDS=()
for ctx in "${ALL_CTXS[@]}"; do
	(
		echo "  Server on $ctx"
		helm template dataplane-test "$CHART_DIR" \
			--set clusterName="$ctx" \
			--set namespace="$NS" \
			--set role=server \
			--set server.replicas="$SERVER_REPLICAS" \
			--set image.tag="$FORTIO_TAG" \
			"${ALL_CN_SETS[@]}" \
			| "${apply[@]}" --context="$ctx" -f - \
			|| { echo "error: server apply failed on $ctx" >&2; exit 1; }
	) &
	APPLY_PIDS+=($!)
done
for pid in "${APPLY_PIDS[@]}"; do
	wait "$pid" || die "one or more contexts failed the fortio-server apply"
done

echo "Deploying fortio client on source cluster $SOURCE_CTX..."
helm template dataplane-test "$CHART_DIR" \
	--set clusterName="$SOURCE_CTX" \
	--set namespace="$NS" \
	--set role=both \
	--set server.replicas="$SERVER_REPLICAS" \
	--set image.tag="$FORTIO_TAG" \
	"${ALL_CN_SETS[@]}" \
	| "${apply[@]}" --context="$SOURCE_CTX" -f -

if ((DRY_RUN)); then
	echo "Dry-run complete."
	exit 0
fi

echo "Waiting for pods to be ready (timeout: ${WAIT_TIMEOUT}s)..."
WAIT_PIDS=()
for ctx in "${ALL_CTXS[@]}"; do
	(
		echo "  Waiting for deployments on $ctx..."
		"${KUBECTL[@]}" --context="$ctx" -n "$NS" wait \
			--for=condition=Available deployment \
			-l app.kubernetes.io/instance=dataplane-test \
			--timeout="${WAIT_TIMEOUT}s" \
			|| { echo "error: deployment(s) not ready on $ctx" >&2; exit 1; }
		# Available can be true before every server replica is Ready (and stays
		# true while an in-place re-run scales up), so also wait for the rollout (PL4).
		"${KUBECTL[@]}" --context="$ctx" -n "$NS" rollout status \
			deployment/dataplane-server --timeout="${WAIT_TIMEOUT}s" \
			|| { echo "error: dataplane-server rollout (${SERVER_REPLICAS} replicas) not complete on $ctx" >&2; exit 1; }
	) &
	WAIT_PIDS+=($!)
done
for pid in "${WAIT_PIDS[@]}"; do
	wait "$pid" || die "one or more contexts failed deployment readiness check"
done

echo "Setup complete. Server (${SERVER_REPLICAS} replicas each) on: ${ALL_CTXS[*]}  Client on: $SOURCE_CTX"

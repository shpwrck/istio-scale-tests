#!/usr/bin/env bash
# Deploy co-located fortio (server + client) and churn-target workloads in a
# single shared namespace for measuring data-plane latency delta under churn.
# Every cluster also gets a Service fortio-server-<ctx> per context that selects
# only that cluster's fortio-server pod, so 002's reach check can test each remote
# on its own (the merged fortio-server Service plus Istio retries would hide one).
#
# Usage:
#   ./tests/churn-dataplane/001-setup-coexec-test.sh \
#       --source-context CTX [--remote-contexts CSV] [options]
#
# Examples:
#   ./tests/churn-dataplane/001-setup-coexec-test.sh \
#     --source-context <mesh-a-ctx> --remote-contexts <mesh-b-ctx>
#   ./tests/churn-dataplane/001-setup-coexec-test.sh \
#     --source-context <mesh-a-ctx> --remote-contexts <mesh-b-ctx> --dry-run
# ci-dry-run: --source-context ci-dummy
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/timestamp.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/fanout.sh"

SOURCE_CTX=""
REMOTE_CONTEXTS_CSV=""
DRY_RUN=0
WAIT_TIMEOUT=300
NS="${COEXEC_TEST_NAMESPACE:-churn-dataplane-test}"
CHURN_DEPLOYMENT_COUNT_OPT="${CHURN_DEPLOYMENT_COUNT:-5}"
CHURN_BASE_REPLICAS_OPT="${CHURN_BASE_REPLICAS:-1}"
# fortio-server port; 002/003 send load to the same port.
SERVICE_PORT="${COEXEC_SERVICE_PORT:-8080}"
# Applying into a still-Terminating namespace fails, so wait (bounded) for a
# namespace a previous run is still deleting to disappear first. An Active
# namespace is re-applied in place.
SETUP_NS_WAIT_SEC="${COEXEC_SETUP_NS_WAIT_SEC:-${COEXEC_NS_DELETE_TIMEOUT_SEC:-240}}"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --source-context CTX     Context where fortio-client is deployed (required).
  --remote-contexts CSV    Additional contexts that also receive fortio-server +
                           churn-target workloads (comma-separated).
  --deployment-count N     Number of churn-target Deployments (default: $CHURN_DEPLOYMENT_COUNT_OPT).
  --base-replicas N        Initial replicas per churn-target Deployment (default: $CHURN_BASE_REPLICAS_OPT).
  --wait-timeout N         Seconds to wait for Deployments to become Available (default: $WAIT_TIMEOUT).
  --ns-wait-timeout N      Seconds to wait for a Terminating namespace from a previous
                           run to disappear before applying (default: $SETUP_NS_WAIT_SEC).
  --dry-run                Render the chart and run apply --dry-run=client; contexts
                           missing from the kubeconfig get the render only.
  -h, --help               Show this help.

Context names are used in Service names (fortio-server-<ctx>), so each must be a
lowercase DNS label of at most 49 characters; rename others with
'kubectl config rename-context'.

Environment:
  COEXEC_TEST_NAMESPACE, CHURN_DEPLOYMENT_COUNT, CHURN_BASE_REPLICAS,
  COEXEC_ISTIOD_REPLICAS (expected istiod replica pin; warns on mismatch),
  COEXEC_SERVICE_PORT (fortio-server port; default 8080),
  COEXEC_SETUP_NS_WAIT_SEC (pre-apply wait for a Terminating namespace to clear;
  defaults to COEXEC_NS_DELETE_TIMEOUT_SEC, then 240),
  FANOUT_PF_BASE (per-pod istiod port-forward block base; default 21014).
EOF
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
	--deployment-count)
		[[ -n "${2:-}" ]] || die "--deployment-count requires a value"
		CHURN_DEPLOYMENT_COUNT_OPT="$2"
		shift 2
		;;
	--base-replicas)
		[[ -n "${2:-}" ]] || die "--base-replicas requires a value"
		CHURN_BASE_REPLICAS_OPT="$2"
		shift 2
		;;
	--wait-timeout)
		[[ -n "${2:-}" ]] || die "--wait-timeout requires a value"
		WAIT_TIMEOUT="$2"
		shift 2
		;;
	--ns-wait-timeout)
		[[ -n "${2:-}" ]] || die "--ns-wait-timeout requires a value"
		SETUP_NS_WAIT_SEC="$2"
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

[[ -n "$SOURCE_CTX" ]] || die "--source-context is required"
if ! is_pos_int "$SERVICE_PORT" || ((SERVICE_PORT > 65535)); then
	die "COEXEC_SERVICE_PORT must be a port number (1-65535), got: $SERVICE_PORT"
fi

KUBECTL=()
resolve_kubectl KUBECTL

command -v helm >/dev/null 2>&1 || die "helm not found on PATH"

REMOTES=()
if [[ -n "$REMOTE_CONTEXTS_CSV" ]]; then
	split_csv "$REMOTE_CONTEXTS_CSV" REMOTES
fi
ALL_CTXS=("$SOURCE_CTX" "${REMOTES[@]}")

# "fortio-server-" + ctx must be a valid Service name (DNS-1035 label, <= 63).
for ctx in "${ALL_CTXS[@]}"; do
	is_dns_label_for fortio-server- "$ctx" \
		|| die "context '$ctx' is not a lowercase DNS label of <= 49 chars (used in Service name fortio-server-<ctx>); rename it with: kubectl config rename-context '$ctx' <new-name>"
done

# allClusterNames for every render: each cluster gets fortio-server-<ctx> for every
# context, so the source resolves every remote's per-cluster Service locally.
ALL_CN_SETS=()
for i in "${!ALL_CTXS[@]}"; do
	ALL_CN_SETS+=(--set "allClusterNames[$i]=${ALL_CTXS[$i]}")
done

# Preflight: require >= 1 Running istiod pod per context (002/003 scrape every
# pod) and warn if the count differs from COEXEC_ISTIOD_REPLICAS. Skipped in --dry-run.
if ! ((DRY_RUN)); then
	EXPECTED_REPLICAS="${COEXEC_ISTIOD_REPLICAS:-}"
	for ctx in "${ALL_CTXS[@]}"; do
		replicas="$(fanout_preflight_istiod "$ctx" "${KUBECTL[@]}")"
		echo "  [$ctx] Running istiod replicas: $replicas"
		if [[ -n "$EXPECTED_REPLICAS" && "$replicas" != "$EXPECTED_REPLICAS" ]]; then
			echo "warn: context $ctx has $replicas Running istiod pods, expected pin COEXEC_ISTIOD_REPLICAS=$EXPECTED_REPLICAS" >&2
		fi
	done
fi

# Print the namespace phase (Active, Terminating) or nothing when it is absent.
ns_phase() {
	"${KUBECTL[@]}" --context="$1" get namespace "$NS" --ignore-not-found \
		-o jsonpath='{.status.phase}' 2>/dev/null
}

# Wait until the namespace is not Terminating (0) or SETUP_NS_WAIT_SEC passes (1).
wait_ns_gone() {
	local ctx="$1" deadline now
	if [[ "$(ns_phase "$ctx")" != "Terminating" ]]; then
		return 0
	fi
	echo "  [$ctx] namespace $NS is Terminating; waiting up to ${SETUP_NS_WAIT_SEC}s for it to clear before apply..." >&2
	deadline=$(( $(date +%s) + SETUP_NS_WAIT_SEC ))
	while [[ "$(ns_phase "$ctx")" == "Terminating" ]]; do
		now=$(date +%s)
		if (( now > deadline )); then
			echo "  [$ctx] namespace $NS did not clear within ${SETUP_NS_WAIT_SEC}s; cannot apply into a Terminating namespace; check stuck finalizers: ${KUBECTL[*]} --context=$ctx get ns $NS -o jsonpath='{.spec.finalizers}'" >&2
			return 1
		fi
		sleep 2
	done
	echo "  [$ctx] namespace $NS cleared; proceeding with apply." >&2
	return 0
}

if ((DRY_RUN)); then
	echo "  [dry-run] would wait up to ${SETUP_NS_WAIT_SEC}s for a Terminating ns ($NS) on each context before apply" >&2
fi

if ! ((DRY_RUN)); then
	NS_WAIT_PIDS=()
	for ctx in "${ALL_CTXS[@]}"; do
		wait_ns_gone "$ctx" &
		NS_WAIT_PIDS+=($!)
	done
	for pid in "${NS_WAIT_PIDS[@]}"; do
		wait "$pid" || die "pre-existing namespace $NS did not clear within ${SETUP_NS_WAIT_SEC}s on one or more contexts; refusing to apply into a Terminating namespace"
	done
fi

CHART_DIR="${ROOT}/tests/churn-dataplane/chart"

# Server-side apply; --dry-run uses a client-side dry run.
apply=("${KUBECTL[@]}" apply --server-side --force-conflicts)
if ((DRY_RUN)); then
	apply=("${KUBECTL[@]}" apply --dry-run=client)
fi

# render_for <ctx> <role>: helm template the chart for one cluster and fortio role.
render_for() {
	local ctx="$1" role="$2"
	helm template churn-dataplane-test "$CHART_DIR" \
		--set namespace="$NS" \
		--set clusterName="$ctx" \
		"${ALL_CN_SETS[@]}" \
		--set fortioRole="$role" \
		--set churnDeploymentCount="$CHURN_DEPLOYMENT_COUNT_OPT" \
		--set churnBaseReplicas="$CHURN_BASE_REPLICAS_OPT" \
		--set service.port="$SERVICE_PORT" \
		--set churnImage.tag="$BUSYBOX_VERSION" \
		--set fortioImage.tag="$FORTIO_VERSION"
}

# apply_to <ctx> <role>: render and apply one context. In --dry-run a context
# missing from the kubeconfig gets the render only, so the plan works offline.
apply_to() {
	local ctx="$1" role="$2" objs
	if ((DRY_RUN)) && ! "${KUBECTL[@]}" config get-contexts "$ctx" >/dev/null 2>&1; then
		objs=$(render_for "$ctx" "$role" | awk '/^kind:/ { print $2 }' | sort | uniq -c | awk '{ printf "%s%s=%s", sep, $2, $1; sep = " " }') \
			|| { echo "error: render failed for $ctx" >&2; return 1; }
		echo "  [dry-run] $ctx is not in the kubeconfig; rendered only: $objs"
		return 0
	fi
	render_for "$ctx" "$role" | "${apply[@]}" --context="$ctx" -f - \
		|| { echo "error: apply failed on $ctx" >&2; return 1; }
}

# Source gets fortio server+client, remotes get fortio-server; all get the churn
# targets. Contexts are applied concurrently; any failure fails the join.
APPLY_PIDS=()
echo "Setup [source=$SOURCE_CTX]: fortio (server+client) + ${CHURN_DEPLOYMENT_COUNT_OPT} churn-targets in ns=${NS}"
apply_to "$SOURCE_CTX" both &
APPLY_PIDS+=($!)
for ctx in "${REMOTES[@]}"; do
	echo "Setup [remote=$ctx]: fortio-server + ${CHURN_DEPLOYMENT_COUNT_OPT} churn-targets in ns=${NS}"
	apply_to "$ctx" server &
	APPLY_PIDS+=($!)
done
for pid in "${APPLY_PIDS[@]}"; do
	wait "$pid" || die "one or more contexts failed the workload apply"
done

if ((DRY_RUN)); then
	echo "Dry-run complete."
	exit 0
fi

echo "Waiting for Deployments to be Available (timeout: ${WAIT_TIMEOUT}s)..."
WAIT_PIDS=()
for ctx in "${ALL_CTXS[@]}"; do
	(
		echo "  [$ctx] waiting for all deployments..."
		"${KUBECTL[@]}" --context="$ctx" -n "$NS" wait deployment \
			-l "app.kubernetes.io/instance=churn-dataplane-test" \
			--for=condition=Available --timeout="${WAIT_TIMEOUT}s" \
			|| { echo "error: deployments not ready on $ctx" >&2; exit 1; }
		echo "  [$ctx] all deployments ready."
	) &
	WAIT_PIDS+=($!)
done
for pid in "${WAIT_PIDS[@]}"; do
	wait "$pid" || die "one or more contexts failed deployment readiness check"
done

echo "Setup complete. Contexts: ${ALL_CTXS[*]}  Namespace: ${NS}"

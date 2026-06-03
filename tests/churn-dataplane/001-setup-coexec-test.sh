#!/usr/bin/env bash
# Deploy co-located fortio (server + client) and churn-target workloads in a
# single shared namespace for measuring data-plane latency delta under churn.
#
# Usage:
#   ./tests/churn-dataplane/001-setup-coexec-test.sh \
#       --source-context CTX [--remote-contexts CSV] [options]
#
# Examples:
#   # Source on cluster-001 with two remote clusters as additional server endpoints:
#   ./tests/churn-dataplane/001-setup-coexec-test.sh \
#     --source-context cluster-001 --remote-contexts cluster-002,cluster-003
#
#   # Dry-run (templates rendered through `oc apply --dry-run=client`):
#   ./tests/churn-dataplane/001-setup-coexec-test.sh \
#     --source-context cluster-001 --remote-contexts cluster-002 --dry-run
# ci-dry-run-skip: needs valid kubeconfig context for kubectl apply --dry-run=client
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
CHURN_DEPLOYMENT_COUNT_OPT="${CHURN_DEPLOYMENT_COUNT:-10}"
CHURN_BASE_REPLICAS_OPT="${CHURN_BASE_REPLICAS:-1}"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --source-context CTX     Context where fortio-client is deployed (required).
  --remote-contexts CSV    Additional contexts that also receive fortio-server +
                           churn-target workloads (comma-separated).
  --deployment-count N     Number of churn-target Deployments (default: $CHURN_DEPLOYMENT_COUNT_OPT).
  --base-replicas N        Initial replicas per churn-target Deployment (default: $CHURN_BASE_REPLICAS_OPT).
  --wait-timeout N         Seconds to wait for Deployments to become Available (default: $WAIT_TIMEOUT).
  --dry-run                Pass --dry-run=client to oc apply; do not touch clusters.
  -h, --help               Show this help.

Environment:
  SETUP_CONTEXTS, COEXEC_TEST_NAMESPACE, CHURN_DEPLOYMENT_COUNT, CHURN_BASE_REPLICAS,
  COEXEC_ISTIOD_REPLICAS (expected istiod replica pin; warns on mismatch),
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

# Preflight: 002/003 fan out a port-forward to EVERY Running istiod pod per
# context (tests/lib/fanout.sh) and aggregate per-pod scrapes, so multi-replica
# istiod is fully supported. We no longer die on > 1 replica — we only require
# >= 1 Running pod and record the per-context replica count (warning if it
# differs from the expected pin). Skip in --dry-run since the user may not have
# live clusters available.
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

CHART_DIR="${ROOT}/tests/churn-dataplane/chart"

# PL5: server-side apply by default; allow --dry-run=client for verification.
apply=("${KUBECTL[@]}" apply --server-side --force-conflicts)
if ((DRY_RUN)); then
	apply=("${KUBECTL[@]}" apply --dry-run=client)
fi

render_for() {
	local ctx="$1" role="$2"
	helm template churn-dataplane-test "$CHART_DIR" \
		--set clusterName="$ctx" \
		--set namespace="$NS" \
		--set fortioRole="$role" \
		--set churnDeploymentCount="$CHURN_DEPLOYMENT_COUNT_OPT" \
		--set churnBaseReplicas="$CHURN_BASE_REPLICAS_OPT" \
		--set churnImage.tag="$BUSYBOX_VERSION" \
		--set fortioImage.tag="$FORTIO_VERSION"
}

# O8 item 6: apply source (role=both) and every remote (role=server) concurrently
# — disjoint contexts, setup-only, fidelity-neutral. Each context's apply runs in
# its own background subshell; a non-zero exit in ANY context fails the join below
# (preserving the original `set -e` semantics so 004's SETUP_FAILED wrap still fires).
APPLY_PIDS=()
(
	echo "Setup [source=$SOURCE_CTX]: fortio (server+client) + ${CHURN_DEPLOYMENT_COUNT_OPT} churn-targets in ns=${NS}"
	render_for "$SOURCE_CTX" both | "${apply[@]}" --context="$SOURCE_CTX" -f - \
		|| { echo "error: apply failed on source $SOURCE_CTX" >&2; exit 1; }
) &
APPLY_PIDS+=($!)
# Remote contexts: server + churn-targets (no client; that lives on source).
for ctx in "${REMOTES[@]}"; do
	(
		echo "Setup [remote=$ctx]: fortio-server + ${CHURN_DEPLOYMENT_COUNT_OPT} churn-targets in ns=${NS}"
		render_for "$ctx" server | "${apply[@]}" --context="$ctx" -f - \
			|| { echo "error: apply failed on remote $ctx" >&2; exit 1; }
	) &
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

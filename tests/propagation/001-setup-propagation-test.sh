#!/usr/bin/env bash
# Deploy the propagation-test namespace, watcher pods and the pre-warmed backer
# (canary Deployment + Service) on target clusters. Remove them with 007-cleanup.sh.
#
# Usage:
#   ./tests/propagation/001-setup-propagation-test.sh [--config FILE] [--contexts CSV] [--dry-run]
#
# Examples:
#   # Setup on all default clusters:
#   ./tests/propagation/001-setup-propagation-test.sh
#
#   # Setup on specific clusters:
#   ./tests/propagation/001-setup-propagation-test.sh --contexts <mesh-a-ctx>,<mesh-b-ctx>
#
#   # Watcher replicas and wait timeout from a run config (README, "Run config"):
#   ./tests/propagation/001-setup-propagation-test.sh --config tests/propagation/configs/smoke.env
# ci-dry-run-skip: needs valid kubeconfig context for kubectl apply --dry-run=client
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
config_preload propagation "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/platform.sh"  # platform_chart_args: the OpenShift overlay per member

CONTEXTS_CSV=""
DRY_RUN=0
WAIT_TIMEOUT="${PROPAGATION_WAIT_TIMEOUT_SEC:-300}"
WATCHER_REPLICAS="${PROPAGATION_WATCHER_REPLICAS}"


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE         Run config of KEY=value lines (config/options.env keys; see
                        tests/propagation/README.md, "Run config"). Precedence: flag >
                        --config > environment > default.
  --contexts CSV        Kube contexts to target (default: \$SETUP_CONTEXTS).
  --watcher-replicas N  Watcher pod replicas per cluster (default: \$PROPAGATION_WATCHER_REPLICAS=$WATCHER_REPLICAS).
  --dry-run             Pass --dry-run=client to kubectl apply.
  --wait-timeout N      Seconds to wait for the watcher and backer pods to become
                        Ready (default: $WAIT_TIMEOUT).
  -h, --help            Show this help.

Environment:
  SETUP_CONTEXTS, PROPAGATION_TEST_NAMESPACE, PROPAGATION_WATCHER_REPLICAS,
  BUSYBOX_VERSION, HTTP_ECHO_VERSION,
  PROPAGATION_WAIT_TIMEOUT_SEC (--wait-timeout default, 300),
  TEST_PLATFORM (auto, kubernetes or openshift: whether a member gets the chart's
  values-openshift.yaml; auto asks each member, and a --dry-run renders kubernetes).
EOF
}


while [[ $# -gt 0 ]]; do
	case "$1" in
	--config)
		# Loaded by config_preload above.
		[[ -n "${2:-}" ]] || die "--config requires a value"
		shift 2
		;;
	--contexts)
		[[ -n "${2:-}" ]] || die "--contexts requires a value"
		CONTEXTS_CSV="$2"
		shift 2
		;;
	--watcher-replicas)
		[[ -n "${2:-}" ]] || die "--watcher-replicas requires a value"
		WATCHER_REPLICAS="$2"
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

platform_validate
is_pos_int "$WATCHER_REPLICAS" || die "--watcher-replicas must be a positive integer (got: $WATCHER_REPLICAS)"
is_pos_int "$WAIT_TIMEOUT" || die "--wait-timeout (or PROPAGATION_WAIT_TIMEOUT_SEC) must be a positive integer (got: $WAIT_TIMEOUT)"

KUBECTL=()
resolve_kubectl KUBECTL
command -v helm >/dev/null 2>&1 || die "helm not found on PATH"

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_csv "$CONTEXTS_CSV" CONTEXTS
else
	split_csv "$SETUP_CONTEXTS" CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

NS="${PROPAGATION_TEST_NAMESPACE}"

apply=("${KUBECTL[@]}" apply --server-side --force-conflicts)
((DRY_RUN)) && apply=("${KUBECTL[@]}" apply --dry-run=client)

CHART_DIR="${ROOT}/tests/propagation/chart"

# Apply each context concurrently; any failure fails the join below.
APPLY_PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	(
		echo "Setting up propagation-test on context $ctx"
		platform_chart_args "$CHART_DIR" "$ctx" PLATFORM_ARGS || exit 1
		# The backer is rendered on every context; only the source context's backer
		# is flipped by the probe, so on remotes the canary Service stays empty.
		helm template propagation-test "$CHART_DIR" ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} \
			--set clusterName="$ctx" \
			--set namespace="$NS" \
			--set backer.enabled=true \
			--set backer.active=false \
			--set backer.image.tag="$HTTP_ECHO_VERSION" \
			--set watcher.image.tag="$BUSYBOX_VERSION" \
			--set watcher.replicaCount="$WATCHER_REPLICAS" \
			| "${apply[@]}" --context="$ctx" -f - \
			|| { echo "error: apply failed on $ctx" >&2; exit 1; }
	) &
	APPLY_PIDS+=($!)
done
for pid in "${APPLY_PIDS[@]}"; do
	wait "$pid" || die "one or more contexts failed the propagation-test apply"
done

if ((DRY_RUN)); then
	echo "Dry-run complete."
	exit 0
fi

echo "Waiting for watcher and backer pods to be ready (timeout: ${WAIT_TIMEOUT}s)..."
WAIT_PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	(
		echo "  Waiting on context $ctx..."
		"${KUBECTL[@]}" --context="$ctx" -n "$NS" wait deployment/propagation-watcher \
			--for=condition=Available --timeout="${WAIT_TIMEOUT}s" \
			|| { echo "error: watcher not ready on $ctx" >&2; exit 1; }
		# The backer must be Available before the first probe iteration so the t0
		# label flip is a pure config push.
		"${KUBECTL[@]}" --context="$ctx" -n "$NS" wait deployment/propagation-canary \
			--for=condition=Available --timeout="${WAIT_TIMEOUT}s" \
			|| { echo "error: backer not ready on $ctx" >&2; exit 1; }
		echo "  Watcher + backer ready on $ctx."
	) &
	WAIT_PIDS+=($!)
done
for pid in "${WAIT_PIDS[@]}"; do
	wait "$pid" || die "one or more contexts failed readiness check"
done

echo "Setup complete. Watcher + pre-warmed backer pods running on: ${CONTEXTS[*]}"

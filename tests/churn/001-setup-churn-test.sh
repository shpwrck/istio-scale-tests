#!/usr/bin/env bash
# Deploy churn target workloads and watcher pods for convergence testing.
#
# Usage:
#   ./tests/churn/001-setup-churn-test.sh [--contexts CSV] [options]
#
# Examples:
#   ./tests/churn/001-setup-churn-test.sh --contexts <mesh-a-ctx>,<mesh-b-ctx>
#   ./tests/churn/001-setup-churn-test.sh --deployment-count 10 --base-replicas 1
#   ./tests/churn/001-setup-churn-test.sh --config tests/churn/configs/smoke.env
# ci-dry-run: --contexts ci-dummy
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"
# --config FILE: export the file's keys before versions.env/options.env fill in defaults.
config_preload churn "$@"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
DRY_RUN=0
WAIT_TIMEOUT="${CHURN_WAIT_TIMEOUT_SEC:-300}"
NS="${CHURN_TEST_NAMESPACE:-churn-test}"
DEPLOYMENT_COUNT="${CHURN_DEPLOYMENT_COUNT:-5}"
BASE_REPLICAS="${CHURN_BASE_REPLICAS:-1}"


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE          Run config of KEY=value lines (config/options.env keys; see
                         tests/churn/README.md, "Run config"). Precedence: flag >
                         --config > environment > default.
  --contexts CSV         Kube contexts to target (default: \$SETUP_CONTEXTS).
  --deployment-count N   Number of churn target deployments (default: $DEPLOYMENT_COUNT).
  --base-replicas N      Initial replicas per deployment (default: $BASE_REPLICAS).
  --dry-run              Render the chart and run apply --dry-run=client; contexts
                         missing from the kubeconfig get the render only.
  --wait-timeout N       Seconds to wait for pods (default: $WAIT_TIMEOUT).
  -h, --help             Show this help.

Environment:
  SETUP_CONTEXTS, CHURN_TEST_NAMESPACE, CHURN_DEPLOYMENT_COUNT, CHURN_BASE_REPLICAS,
  CHURN_WAIT_TIMEOUT_SEC (--wait-timeout default, 300).
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
	--deployment-count)
		[[ -n "${2:-}" ]] || die "--deployment-count requires a value"
		DEPLOYMENT_COUNT="$2"
		shift 2
		;;
	--base-replicas)
		[[ -n "${2:-}" ]] || die "--base-replicas requires a value"
		BASE_REPLICAS="$2"
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

is_pos_int "$WAIT_TIMEOUT" || die "--wait-timeout (or CHURN_WAIT_TIMEOUT_SEC) must be a positive integer; got '$WAIT_TIMEOUT'"

KUBECTL=()
resolve_kubectl KUBECTL

command -v helm >/dev/null 2>&1 || die "helm not found on PATH"

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_contexts "$CONTEXTS_CSV" CONTEXTS --contexts
else
	split_contexts "$SETUP_CONTEXTS" CONTEXTS SETUP_CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

apply=("${KUBECTL[@]}" apply)
((DRY_RUN)) && apply=("${KUBECTL[@]}" apply --dry-run=client)

CHART_DIR="${ROOT}/tests/churn/chart"

render() {
	helm template churn-test "$CHART_DIR" \
		--set namespace="$NS" \
		--set deploymentCount="$DEPLOYMENT_COUNT" \
		--set baseReplicas="$BASE_REPLICAS" \
		--set image.tag="$BUSYBOX_VERSION" \
		--set watcher.image.tag="$BUSYBOX_VERSION"
}

# Apply to every context concurrently; any failure fails the join below.
APPLY_PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	(
		echo "Setting up churn-test on context $ctx (${DEPLOYMENT_COUNT} deployments × ${BASE_REPLICAS} replicas)"
		# Offline dry-run: a context not in the kubeconfig gets the render only.
		if ((DRY_RUN)) && ! "${KUBECTL[@]}" config get-contexts "$ctx" >/dev/null 2>&1; then
			objs=$(render | awk '/^kind:/ { print $2 }' | sort | uniq -c | awk '{ printf "%s%s=%s", sep, $2, $1; sep = " " }') \
				|| { echo "error: render failed for $ctx" >&2; exit 1; }
			echo "  [dry-run] $ctx is not in the kubeconfig; rendered only: $objs"
			exit 0
		fi
		render | "${apply[@]}" --context="$ctx" -f - \
			|| { echo "error: apply failed on $ctx" >&2; exit 1; }
	) &
	APPLY_PIDS+=($!)
done
for pid in "${APPLY_PIDS[@]}"; do
	wait "$pid" || die "one or more contexts failed the churn-test apply"
done

if ((DRY_RUN)); then
	echo "Dry-run complete."
	exit 0
fi

# One label-selector rollout wait per context (targets and watcher share the
# instance label). rollout status, not condition=Available, so a re-apply that
# replaces pods finishes before the probe takes its baselines.
echo "Waiting for deployments to be ready (timeout: ${WAIT_TIMEOUT}s)..."
WAIT_PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	(
		echo "  Waiting on context $ctx..."
		"${KUBECTL[@]}" --context="$ctx" -n "$NS" rollout status \
			deployment -l app.kubernetes.io/instance=churn-test \
			--timeout="${WAIT_TIMEOUT}s" \
			|| { echo "error: deployments not ready on $ctx" >&2; exit 1; }
		echo "  All deployments ready on $ctx."
	) &
	WAIT_PIDS+=($!)
done
for pid in "${WAIT_PIDS[@]}"; do
	wait "$pid" || die "one or more contexts failed deployment readiness check"
done

echo "Setup complete. ${DEPLOYMENT_COUNT} churn targets + watcher on: ${CONTEXTS[*]}"

#!/usr/bin/env bash
# Remove the dataplane-test namespace from target clusters.
#
# Usage:
#   ./tests/dataplane/005-cleanup.sh [--config FILE] [--contexts CSV] [--dry-run] [--no-wait-deletion]
# ci-dry-run: --contexts ci-dummy
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
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/platform.sh"  # platform_validate (TEST_PLATFORM)

CONTEXTS_CSV=""
DRY_RUN=0
WAIT_DELETION=1
DELETION_TIMEOUT="${DATAPLANE_NS_DELETE_TIMEOUT_SEC:-180}"
NS="${DATAPLANE_TEST_NAMESPACE:-dataplane-test}"


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE          Run config of KEY=value lines (config/options.env keys; see
                         tests/dataplane/README.md, "Run config"). Precedence: flag >
                         --config > environment > default.
  --contexts CSV         Kube contexts to clean up (default: \$SETUP_CONTEXTS).
  --dry-run              Print the delete commands without contacting any cluster.
  --no-wait-deletion     Return once the delete is accepted (default: wait).
  --deletion-timeout N   Seconds to wait for namespace termination (default: $DELETION_TIMEOUT).
  -h, --help             Show this help.

Environment:
  SETUP_CONTEXTS, DATAPLANE_TEST_NAMESPACE,
  DATAPLANE_NS_DELETE_TIMEOUT_SEC (--deletion-timeout default, 180).
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
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--no-wait-deletion)
		WAIT_DELETION=0
		shift
		;;
	--deletion-timeout)
		[[ -n "${2:-}" ]] || die "--deletion-timeout requires a value"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--deletion-timeout must be a positive integer"
		(( $2 > 0 )) || die "--deletion-timeout must be > 0"
		DELETION_TIMEOUT="$2"
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
is_pos_int "$DELETION_TIMEOUT" || die "--deletion-timeout (or DATAPLANE_NS_DELETE_TIMEOUT_SEC) must be a positive integer; got '$DELETION_TIMEOUT'"

KUBECTL=()
resolve_kubectl KUBECTL

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_contexts "$CONTEXTS_CSV" CONTEXTS --contexts
else
	split_contexts "$SETUP_CONTEXTS" CONTEXTS SETUP_CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

wait_for_ns_termination() {
	local ctx="$1"
	local waited=0
	while "${KUBECTL[@]}" --context="$ctx" get ns "$NS" -o name 2>/dev/null | grep -q .; do
		sleep 2
		waited=$((waited + 2))
		((waited >= DELETION_TIMEOUT)) && {
			echo "  [$ctx] ns termination timeout after ${DELETION_TIMEOUT}s"
			return 1
		}
	done
	return 0
}

echo "=== Data-plane test cleanup ==="
echo "Contexts: ${CONTEXTS[*]}"
echo "Namespace: $NS"
echo "Wait for deletion: $((WAIT_DELETION))"
((DRY_RUN)) && echo "Mode: dry-run"
echo ""

if ((DRY_RUN)); then
	for ctx in "${CONTEXTS[@]}"; do
		echo "  [dry-run] ${KUBECTL[*]} --context=$ctx delete namespace $NS --ignore-not-found=true --wait=false"
		((WAIT_DELETION)) && echo "  [dry-run] wait up to ${DELETION_TIMEOUT}s for namespace $NS to disappear on $ctx"
	done
	exit 0
fi

# --ignore-not-found makes an absent namespace a no-op, so a failed delete means
# the context itself failed. --wait=false so the bounded loop below is the only wait.
PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	(
		echo "--- Cleaning up context: $ctx ---"
		"${KUBECTL[@]}" --context="$ctx" delete namespace "$NS" --ignore-not-found=true --wait=false \
			|| { echo "  [$ctx] error: delete failed" >&2; exit 1; }
		if ((WAIT_DELETION)); then
			echo "  [$ctx] waiting for namespace termination (timeout ${DELETION_TIMEOUT}s)..."
			wait_for_ns_termination "$ctx" || exit 1
		fi
		echo "  [$ctx] Done."
	) &
	PIDS+=($!)
done

FAILED=0
for pid in ${PIDS[@]+"${PIDS[@]}"}; do
	wait "$pid" || FAILED=$((FAILED + 1))
done

echo ""
if ((FAILED > 0)); then
	echo "Cleanup finished with $FAILED failed context(s)."
	exit 1
fi
echo "Cleanup complete."

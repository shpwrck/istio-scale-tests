#!/usr/bin/env bash
# Remove the propagation-test namespace (watcher, backer, canary Service) from
# target clusters. Safe to run at any time: the delete uses --ignore-not-found.
#
# Usage:
#   ./tests/propagation/007-cleanup.sh [--config FILE] [--contexts CSV] [--dry-run]
#
# Examples:
#   # Clean up all default clusters:
#   ./tests/propagation/007-cleanup.sh
#
#   # Clean up specific clusters:
#   ./tests/propagation/007-cleanup.sh --contexts <mesh-a-ctx>,<mesh-b-ctx>
# ci-dry-run: --contexts ci-dummy
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

CONTEXTS_CSV=""
DRY_RUN=0


usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --config FILE    Run config of KEY=value lines (config/options.env keys; see
                   tests/propagation/README.md, "Run config"). Precedence: flag >
                   --config > environment > default.
  --contexts CSV   Kube contexts to clean up (default: \$SETUP_CONTEXTS).
  --dry-run        Print the delete commands without contacting any cluster.
  -h, --help       Show this help.

Environment:
  SETUP_CONTEXTS, PROPAGATION_TEST_NAMESPACE.
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
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown option: $1 (try --help)"
		;;
	esac
done

KUBECTL=()
resolve_kubectl KUBECTL

CONTEXTS=()
if [[ -n "$CONTEXTS_CSV" ]]; then
	split_csv "$CONTEXTS_CSV" CONTEXTS
else
	split_csv "$SETUP_CONTEXTS" CONTEXTS
fi
((${#CONTEXTS[@]})) || die "no contexts resolved"

NS="${PROPAGATION_TEST_NAMESPACE}"

echo "=== Propagation test cleanup ==="
echo "Contexts: ${CONTEXTS[*]}"
echo "Namespace: $NS"
((DRY_RUN)) && echo "Mode: dry-run"
echo ""

if ((DRY_RUN)); then
	for ctx in "${CONTEXTS[@]}"; do
		echo "  [dry-run] ${KUBECTL[*]} --context=$ctx delete namespace $NS --ignore-not-found=true"
	done
	exit 0
fi

# Deleting the namespace removes everything the chart created. --ignore-not-found
# makes an absent namespace a no-op, so a non-zero exit means the context itself
# failed (unreachable, auth, ...).
PIDS=()
for ctx in "${CONTEXTS[@]}"; do
	(
		echo "  [$ctx] Deleting namespace $NS..."
		if ! "${KUBECTL[@]}" --context="$ctx" delete namespace "$NS" --ignore-not-found=true; then
			echo "  [$ctx] error: delete failed" >&2
			exit 1
		fi
		echo "  [$ctx] Done."
	) &
	PIDS+=($!)
done

FAILED=0
for pid in "${PIDS[@]}"; do
	wait "$pid" || FAILED=$((FAILED + 1))
done

echo ""
if ((FAILED > 0)); then
	echo "Cleanup finished with $FAILED failed context(s)."
	exit 1
fi
echo "Cleanup complete."

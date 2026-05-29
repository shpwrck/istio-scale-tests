#!/usr/bin/env bash
# Clean up any active tuning profile and remove tuning-specific resources.
#
# Reverts any active profile (if a state directory exists), then deletes
# any tuning-related resources (Sidecar CRs, Telemetry objects,
# DestinationRules) that may have been left behind.
#
# Usage:
#   ./tests/tuning/005-cleanup.sh [--contexts CSV] [options]
#
# Examples:
#   ./tests/tuning/005-cleanup.sh --contexts rosa-001,rosa-002,rosa-003
#   ./tests/tuning/005-cleanup.sh --dry-run
# ci-dry-run: --contexts ci-dummy
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

TUNING_DIR="${ROOT}/tests/tuning"
CONTEXTS_CSV=""
DRY_RUN=0
KUBECTL="kubectl"

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Revert any active tuning profile and clean up tuning-specific resources.

Options:
  --contexts CSV   Kube contexts to target (default: \$SETUP_CONTEXTS).
  --dry-run        Show what would be cleaned without changing clusters.
  -h, --help       Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--contexts) CONTEXTS_CSV="$2"; shift 2 ;;
	--dry-run) DRY_RUN=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) die "Unknown option: $1" ;;
	esac
done

CONTEXTS_CSV="${CONTEXTS_CSV:-$SETUP_CONTEXTS}"
[[ -n "$CONTEXTS_CSV" ]] || die "No contexts (set --contexts or SETUP_CONTEXTS)"

IFS=',' read -ra CONTEXTS <<<"$CONTEXTS_CSV"

TUNING_NS="istio-system"
TUNING_RESOURCES=(
	"sidecar/default"
	"sidecar/east-west-gateway"
	"telemetry/tuning-metrics"
	"telemetry/tuning-access-log"
	"destinationrule/tuning-connection-pool"
)

active_states=()
while IFS= read -r f; do
	active_states+=("$(dirname "$f")")
done < <(find "${TUNING_DIR}/results" -maxdepth 3 -name 'active-profile' -type f 2>/dev/null | sort -u)

echo "=== Tuning Cleanup ==="
echo "    Contexts: ${CONTEXTS_CSV}"
echo ""

if [[ ${#active_states[@]} -gt 0 ]]; then
	echo "--- Active profiles found ---"
	for s in "${active_states[@]}"; do
		profile="$(<"${s}/active-profile")"
		echo "    ${profile} (state: ${s})"
		if ((DRY_RUN)); then
			echo "    [dry-run] Would revert via 002-revert-profile.sh --state-dir ${s}"
		else
			"${TUNING_DIR}/002-revert-profile.sh" \
				--state-dir "$s" \
				--contexts "$CONTEXTS_CSV" || true
		fi
	done
	echo ""
fi

echo "--- Cleaning up tuning resources ---"
for ctx in "${CONTEXTS[@]}"; do
	ctx="${ctx#"${ctx%%[![:space:]]*}"}"
	ctx="${ctx%"${ctx##*[![:space:]]}"}"
	[[ -z "$ctx" ]] && continue

	for res in "${TUNING_RESOURCES[@]}"; do
		if ((DRY_RUN)); then
			echo "  [dry-run] ${ctx}: would delete ${res} -n ${TUNING_NS}"
		else
			$KUBECTL --context="$ctx" delete --ignore-not-found \
				"$res" -n "$TUNING_NS" 2>/dev/null || true
		fi
	done
done

echo ""
echo "=== Cleanup complete ==="

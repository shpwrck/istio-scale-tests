#!/usr/bin/env bash
# Revert the mesh to its pre-profile baseline state.
#
# Restores the Istio CR from the baseline snapshot saved by 001-apply-profile.sh
# and deletes any additional resources the profile deployed.
#
# Usage:
#   ./tests/tuning/002-revert-profile.sh [--state-dir DIR] [--contexts CSV] [options]
#
# Examples:
#   # Revert using the default state dir for a profile:
#   ./tests/tuning/002-revert-profile.sh --state-dir results/state-01-sidecar-scoping
#
#   # Dry-run to see what would be reverted:
#   ./tests/tuning/002-revert-profile.sh --state-dir results/state-03-push-throttling --dry-run
# ci-dry-run-skip: needs --state-dir from a prior 001-apply-profile.sh run
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

STATE_DIR=""
CONTEXTS_CSV=""
DRY_RUN=0
ISTIO_CR_NAMESPACE="istio-system"
ROLLOUT_TIMEOUT=300
KUBECTL="kubectl"

die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Revert the mesh to its pre-profile state using the baseline snapshot saved
by 001-apply-profile.sh.

Options:
  --state-dir DIR        Directory containing baseline state (required).
  --contexts CSV         Kube contexts to target (default: \$SETUP_CONTEXTS).
  --rollout-timeout N    Seconds to wait for istiod rollout (default: $ROLLOUT_TIMEOUT).
  --dry-run              Show what would be reverted without changing clusters.
  -h, --help             Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--state-dir) STATE_DIR="$2"; shift 2 ;;
	--contexts) CONTEXTS_CSV="$2"; shift 2 ;;
	--rollout-timeout) ROLLOUT_TIMEOUT="$2"; shift 2 ;;
	--dry-run) DRY_RUN=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) die "Unknown option: $1" ;;
	esac
done

[[ -n "$STATE_DIR" ]] || die "--state-dir is required"
[[ -d "$STATE_DIR" ]] || die "State directory not found: $STATE_DIR"

CONTEXTS_CSV="${CONTEXTS_CSV:-$SETUP_CONTEXTS}"
[[ -n "$CONTEXTS_CSV" ]] || die "No contexts specified (set --contexts or SETUP_CONTEXTS)"

IFS=',' read -ra CONTEXTS <<<"$CONTEXTS_CSV"

ACTIVE_PROFILE=""
if [[ -f "${STATE_DIR}/active-profile" ]]; then
	ACTIVE_PROFILE="$(<"${STATE_DIR}/active-profile")"
fi

echo "=== Reverting profile: ${ACTIVE_PROFILE:-unknown} ==="
echo "    State dir: ${STATE_DIR}"
echo "    Contexts:  ${CONTEXTS_CSV}"
echo ""

if ((DRY_RUN)); then
	echo "--- DRY RUN: Would restore baseline Istio CRs from: ---"
	for ctx in "${CONTEXTS[@]}"; do
		ctx="${ctx#"${ctx%%[![:space:]]*}"}"
		ctx="${ctx%"${ctx##*[![:space:]]}"}"
		[[ -z "$ctx" ]] && continue
		baseline="${STATE_DIR}/istio-baseline-${ctx}.yaml"
		if [[ -f "$baseline" ]]; then
			echo "  ${ctx}: ${baseline}"
		else
			echo "  ${ctx}: MISSING (${baseline})"
		fi
	done
	if [[ -f "${STATE_DIR}/applied-resources.yaml" ]]; then
		echo ""
		echo "--- DRY RUN: Would delete these resources: ---"
		cat "${STATE_DIR}/applied-resources.yaml"
	fi
	exit 0
fi

for ctx in "${CONTEXTS[@]}"; do
	ctx="${ctx#"${ctx%%[![:space:]]*}"}"
	ctx="${ctx%"${ctx##*[![:space:]]}"}"
	[[ -z "$ctx" ]] && continue

	if [[ -f "${STATE_DIR}/applied-resources.yaml" ]]; then
		echo "--- ${ctx}: deleting profile resources ---"
		$KUBECTL --context="$ctx" delete --ignore-not-found \
			-f "${STATE_DIR}/applied-resources.yaml" 2>/dev/null || true
	fi

	baseline="${STATE_DIR}/istio-baseline-${ctx}.yaml"
	if [[ -f "$baseline" ]]; then
		echo "--- ${ctx}: restoring baseline Istio CR ---"
		$KUBECTL --context="$ctx" apply --server-side --force-conflicts \
			-f "$baseline"
	else
		echo "WARNING: No baseline found for ${ctx} — skipping Istio CR restore"
	fi
done

echo ""
echo "=== Waiting for istiod rollout ==="
for ctx in "${CONTEXTS[@]}"; do
	ctx="${ctx#"${ctx%%[![:space:]]*}"}"
	ctx="${ctx%"${ctx##*[![:space:]]}"}"
	[[ -z "$ctx" ]] && continue

	echo "--- ${ctx}: waiting up to ${ROLLOUT_TIMEOUT}s ---"
	$KUBECTL --context="$ctx" rollout status deployment/istiod \
		-n "$ISTIO_CR_NAMESPACE" \
		--timeout="${ROLLOUT_TIMEOUT}s" 2>/dev/null || true
done

rm -f "${STATE_DIR}/active-profile"
rm -f "${STATE_DIR}/applied-resources.yaml"

echo ""
echo "=== Revert complete ==="

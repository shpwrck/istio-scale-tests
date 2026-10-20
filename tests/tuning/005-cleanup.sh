#!/usr/bin/env bash
# Undo whatever an interrupted tuning run left behind:
#   1. revert every profile still marked active under the results directory,
#   2. delete profile resources still on the clusters (found by label),
#   3. resume Argo CD for every pause still recorded under the results directory.
#
# Usage:
#   ./tests/tuning/005-cleanup.sh [--contexts CSV] [--results-dir DIR] [--dry-run]
# ci-dry-run: --contexts ci-dummy
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"

TUNING_DIR="${ROOT}/tests/tuning"
RESULTS="${TUNING_DIR}/results"
CONTEXTS_CSV=""
DRY_RUN=0
LABEL="istio-scale-tests/tuning-profile"
# Every kind a profile may create (tests/tuning/lib/tuning.py ALLOWED_KINDS).
KINDS="destinationrules.networking.istio.io,sidecars.networking.istio.io,envoyfilters.networking.istio.io,telemetries.telemetry.istio.io"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Revert active profiles, delete leftover profile resources and resume Argo CD.

Options:
  --contexts CSV     Mesh member contexts for the resource sweep (default: \$SETUP_CONTEXTS).
                     Reverts use the contexts recorded when each profile was applied.
  --results-dir DIR  Where to look for revert state and Argo CD pause records
                     (default: tests/tuning/results; use the sweep's --output-dir).
  --dry-run          Show what would be done; do not touch clusters.
  -h, --help         Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--contexts | --results-dir)
		[[ -n "${2:-}" ]] || die "$1 requires a value"
		case "$1" in
		--contexts) CONTEXTS_CSV="$2" ;;
		--results-dir) RESULTS="$2" ;;
		esac
		shift 2
		;;
	--dry-run) DRY_RUN=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) die "unknown option: $1 (try --help)" ;;
	esac
done

CONTEXTS=()
split_contexts "${CONTEXTS_CSV:-${SETUP_CONTEXTS:-}}" CONTEXTS "--contexts (or SETUP_CONTEXTS)"
((${#CONTEXTS[@]})) || die "no contexts (set --contexts or SETUP_CONTEXTS)"

run() {
	if ((DRY_RUN)); then
		echo "  [dry-run] ${*//"${ROOT}"\//}"
	else
		"$@"
	fi
}

fail=0
echo "=== Tuning cleanup ==="

echo "--- Active profiles ---"
found=0
while IFS= read -r marker; do
	found=1
	sd="$(dirname "$marker")"
	echo "  $(<"$marker") (${sd#"${ROOT}"/})"
	run "${TUNING_DIR}/002-revert-profile.sh" --state-dir "$sd" || fail=1
done < <(find "$RESULTS" -name active-profile -type f 2>/dev/null | sort)
((found)) || echo "  none"

echo "--- Leftover profile resources (label ${LABEL}) ---"
KUBECTL=(kubectl)
((DRY_RUN)) || resolve_kubectl KUBECTL
for ctx in "${CONTEXTS[@]}"; do
	run "${KUBECTL[@]}" --context="$ctx" delete "$KINDS" -A -l "$LABEL" --ignore-not-found || fail=1
done

echo "--- Argo CD pauses ---"
found=0
while IFS= read -r state; do
	found=1
	run "${TUNING_DIR}/006-gitops-pause.sh" --resume --state-file "$state" || fail=1
done < <(find "$RESULTS" -name gitops-pause.json -type f 2>/dev/null | sort)
((found)) || echo "  none"

if ((fail)); then
	echo "=== Cleanup finished with errors (see above) ===" >&2
	exit 1
fi
echo "=== Cleanup complete ==="

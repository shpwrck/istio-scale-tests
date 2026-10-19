#!/usr/bin/env bash
# Undo whatever an interrupted tuning run left behind:
#   1. revert every profile still marked active under the results directory,
#   2. on each member, restore the Istio CR from every profile marker still there (the ConfigMap
#      001-apply-profile.sh creates, holding the merge patch that undoes the profile on that
#      member), newest first, check it, then delete the marker; this undoes a profile left
#      applied by a run of any checkout, even one that only set istiod's env,
#   3. delete profile resources still on the clusters (found by label),
#   4. resume Argo CD for every pause still recorded under the results directory.
#
# Usage:
#   ./tests/tuning/005-cleanup.sh [--contexts CSV] [--results-dir DIR] [--rollout-timeout N] [--dry-run]
# ci-dry-run: --contexts ci-dummy
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/platform.sh"  # platform_validate (TEST_PLATFORM)
# shellcheck disable=SC1091
source "${ROOT}/tests/tuning/lib/tuning.sh"  # wait_for_istiod

TUNING_DIR="${ROOT}/tests/tuning"
HELPER="${TUNING_DIR}/lib/tuning.py"
RESULTS="${TUNING_DIR}/results"
CONTEXTS_CSV=""
ROLLOUT_TIMEOUT=300
DRY_RUN=0
# The label, every kind a profile may create and its marker's: the platform record's
# (tests/lib/platform.sh), which tests/tuning/lib/tuning.py's LABEL, ALLOWED_KINDS and
# MARKER_KIND match (platform.bats checks).
LABEL="$PLATFORM_TUNING_LABEL"
KINDS="$PLATFORM_TUNING_RESOURCE_KINDS"
MARKER_KIND="$PLATFORM_TUNING_MARKER_KIND"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Revert active profiles, restore each member's Istio CR from the profile markers still
on it, delete leftover profile resources and resume Argo CD.

Options:
  --contexts CSV     Mesh member contexts for the marker restore and the resource sweep
                     (default: \$SETUP_CONTEXTS). Reverts use the contexts recorded when
                     each profile was applied.
  --results-dir DIR  Where to look for revert state and Argo CD pause records
                     (default: tests/tuning/results; use the sweep's --output-dir).
  --rollout-timeout N
                     Seconds to wait for the operator and istiod rollout after a restore
                     from a marker (default: ${ROLLOUT_TIMEOUT}).
  --dry-run          Show what would be done; do not touch clusters.
  -h, --help         Show this help.

Exit status: 0 nothing left behind, 1 something could not be undone (see the output; a
marker whose restore failed stays on its member, so the next tuning run refuses to start).
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--contexts | --results-dir | --rollout-timeout)
		[[ -n "${2:-}" ]] || die "$1 requires a value"
		case "$1" in
		--contexts) CONTEXTS_CSV="$2" ;;
		--results-dir) RESULTS="$2" ;;
		--rollout-timeout) ROLLOUT_TIMEOUT="$2" ;;
		esac
		shift 2
		;;
	--dry-run) DRY_RUN=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) die "unknown option: $1 (try --help)" ;;
	esac
done

platform_validate
is_pos_int "$ROLLOUT_TIMEOUT" || die "--rollout-timeout must be a positive integer"
CONTEXTS=()
split_csv "${CONTEXTS_CSV:-${SETUP_CONTEXTS:-}}" CONTEXTS
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

KUBECTL=(kubectl)
((DRY_RUN)) || resolve_kubectl KUBECTL
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Restore one member's Istio CR from its markers, newest first, and delete each once the CR
# matches its patch; stop at the first that cannot be undone (an older one's patch would leave
# a mix of both profiles), keeping it and the older ones.
restore_markers() {
	local ctx="$1" d="${WORK}/$(ctx_key "$1")" ns name prof patch row
	local -a rows=()
	mkdir -p "$d"
	if ! "${KUBECTL[@]}" --context="$ctx" get "$MARKER_KIND" -A -l "$LABEL" -o json >"${d}/list.json"; then
		echo "  FAIL  ${ctx}: the profile markers could not be listed; the next tuning run refuses to start until they can" >&2
		return 1
	fi
	if ! python3 -I "$HELPER" markers "${d}/list.json" "$d" >"${d}/rows"; then
		echo "  FAIL  ${ctx}: the profile markers' list did not parse" >&2
		return 1
	fi
	mapfile -t rows <"${d}/rows"
	((${#rows[@]})) || { echo "  ${ctx}: none"; return 0; }
	for row in "${rows[@]}"; do
		read -r ns name prof patch <<<"$row"
		echo "  ${ctx}: profile ${prof} (marker ${ns}/${name})"
		if [[ "$patch" == "-" ]]; then
			echo "  FAIL  ${ctx}: ${ns}/${name} holds no revert patch to restore the Istio CR from; restore the settings tests/tuning/profiles/${prof}.yaml changes by hand, then delete it: ${KUBECTL[*]} --context=${ctx} -n ${ns} delete ${MARKER_KIND} ${name}" >&2
			return 1
		fi
		if [[ "$(<"$patch")" != "{}" ]]; then
			if ! "${KUBECTL[@]}" --context="$ctx" patch istio.sailoperator.io default --type=merge --patch-file="$patch" ||
				! wait_for_istiod "$ctx" "$ROLLOUT_TIMEOUT" ||
				! "${KUBECTL[@]}" --context="$ctx" get istio.sailoperator.io default -o json >"${d}/live.json" ||
				! python3 -I "$HELPER" check-revert "$patch" "${d}/live.json"; then
				echo "  FAIL  ${ctx}: the Istio CR is not back to its state before ${prof}; the marker ${ns}/${name} stays (fix it, then run this again)" >&2
				return 1
			fi
		fi
		if ! "${KUBECTL[@]}" --context="$ctx" -n "$ns" delete "$MARKER_KIND" "$name" --ignore-not-found >/dev/null; then
			echo "  FAIL  ${ctx}: the Istio CR is restored, but the marker ${ns}/${name} could not be deleted; delete it: ${KUBECTL[*]} --context=${ctx} -n ${ns} delete ${MARKER_KIND} ${name}" >&2
			return 1
		fi
		echo "  PASS  ${ctx}: marker ${ns}/${name} removed"
	done
}

echo "--- Profile markers (${MARKER_KIND}, label ${LABEL}) ---"
for ctx in "${CONTEXTS[@]}"; do
	if ((DRY_RUN)); then
		echo "  [dry-run] ${ctx}: restore the Istio CR from each profile marker, newest first, check it, then delete the marker"
	else
		restore_markers "$ctx" || fail=1
	fi
done

echo "--- Leftover profile resources (label ${LABEL}) ---"
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

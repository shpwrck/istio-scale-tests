#!/usr/bin/env bash
# Undo whatever an interrupted tuning run left behind:
#   1. revert every profile still marked active under the results directory,
#   2. on each member, restore the Istio CR from every profile marker still there (the ConfigMap
#      001-apply-profile.sh creates, holding the merge patch that undoes the profile on that
#      member), newest first, check it, then delete the marker; this undoes a profile left
#      applied by a run of any checkout, even one that only set istiod's env,
#   3. delete profile resources still on the clusters (found by label),
#   4. resume Argo CD for every pause still recorded under the results directory, and with
#      --gitops-context remove the deny window the pause adds even when no record names it
#      (a run whose results are elsewhere or gone).
#
# Usage:
#   ./tests/tuning/005-cleanup.sh [--contexts CSV] [--results-dir DIR] [--gitops-context CTX]
#                                 [--rollout-timeout N] [--dry-run]
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
GITOPS_CTX="${TUNING_GITOPS_CONTEXT:-}"
ROLLOUT_TIMEOUT="${TUNING_ROLLOUT_TIMEOUT:-300}"
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
on it, delete leftover profile resources and resume Argo CD. The markers are on the
members, so their restore needs no results; an Argo CD pause is recorded only in the
results of the run that made it (--results-dir), or found on the hub (--gitops-context).

Options:
  --contexts CSV     Mesh member contexts for the marker restore and the resource sweep
                     (default: \$SETUP_CONTEXTS). Reverts use the contexts recorded when
                     each profile was applied.
  --results-dir DIR  Where to look for revert state and Argo CD pause records
                     (default: tests/tuning/results; use the sweep's --output-dir).
  --gitops-context CTX
                     Hub context running Argo CD (default: \$TUNING_GITOPS_CONTEXT): after
                     the recorded pauses, remove the deny window a pause adds there even
                     when no record names it (006-gitops-pause.sh --clear). Without it, and
                     with markers restored but no pause recorded, a warning says to check.
  --rollout-timeout N
                     Seconds to wait for the operator and istiod rollout after a restore
                     from a marker (default: ${ROLLOUT_TIMEOUT}, from \$TUNING_ROLLOUT_TIMEOUT).
  --dry-run          Show what would be done; do not touch clusters.
  -h, --help         Show this help.

Exit status: 0 nothing left behind, 1 something could not be undone (see the output; a
marker whose restore failed stays on its member, so the next tuning run refuses to start).
Requires python3 (the standard library only).
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--contexts | --results-dir | --gitops-context | --rollout-timeout)
		[[ -n "${2:-}" ]] || die "$1 requires a value"
		case "$1" in
		--contexts) CONTEXTS_CSV="$2" ;;
		--results-dir) RESULTS="$2" ;;
		--gitops-context) GITOPS_CTX="$2" ;;
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
((DRY_RUN)) || command -v python3 >/dev/null ||
	die "python3 is required (the standard library only): the revert and the restore from the profile markers read their patches with it"

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

# list_markers <ctx>: the member's profile markers, newest first, as tuning.py markers prints them
# (<ns> <name> <profile> <patch-file>), into ${WORK}/<ctx>/rows; return 1 with a FAIL line when
# they cannot be listed.
list_markers() {
	local ctx="$1" d="${WORK}/$(ctx_key "$1")"
	mkdir -p "$d"
	if ! "${KUBECTL[@]}" --context="$ctx" get "$MARKER_KIND" -A -l "$LABEL" -o json >"${d}/list.json"; then
		echo "  FAIL  ${ctx}: the profile markers could not be listed; the next tuning run refuses to start until they can" >&2
		return 1
	fi
	if ! python3 -I "$HELPER" markers "${d}/list.json" "$d" >"${d}/rows"; then
		echo "  FAIL  ${ctx}: the profile markers' list did not parse" >&2
		return 1
	fi
}

# Restore each member's Istio CR from its markers, newest first, and delete each once the CR
# matches its patch; on a member, stop at the first that cannot be undone (an older one's patch
# would leave a mix of both profiles), keeping it and the older ones. Each round patches every
# member's next marker before it waits for any of them, so the members' rollouts overlap (as
# 002-revert-profile.sh's do).
RESTORED=0
echo "--- Profile markers (${MARKER_KIND}, label ${LABEL}) ---"
if ((DRY_RUN)); then
	for ctx in "${CONTEXTS[@]}"; do
		echo "  [dry-run] ${ctx}: restore the Istio CR from each profile marker, newest first, check it, then delete the marker"
	done
else
	# Per member: the index of its next marker, how many it has, and its marker this round.
	declare -A NEXT=() COUNT=() CUR=()
	LIVE=()
	for ctx in "${CONTEXTS[@]}"; do
		list_markers "$ctx" || { fail=1; continue; }
		mapfile -t rows <"${WORK}/$(ctx_key "$ctx")/rows"
		if ((${#rows[@]})); then
			NEXT[$ctx]=0
			COUNT[$ctx]="${#rows[@]}"
			LIVE+=("$ctx")
		else
			echo "  ${ctx}: none"
		fi
	done
	while ((${#LIVE[@]})); do
		WAIT=()
		for ctx in "${LIVE[@]}"; do
			mapfile -t rows <"${WORK}/$(ctx_key "$ctx")/rows"
			n="${NEXT[$ctx]}"
			CUR[$ctx]="${rows[n]}"
			read -r ns name prof patch <<<"${CUR[$ctx]}"
			echo "  ${ctx}: profile ${prof} (marker ${ns}/${name})"
			if [[ "$patch" == "-" ]]; then
				echo "  FAIL  ${ctx}: ${ns}/${name} holds no revert patch to restore the Istio CR from; restore the settings tests/tuning/profiles/${prof}.yaml changes by hand, then delete it: ${KUBECTL[*]} --context=${ctx} -n ${ns} delete ${MARKER_KIND} ${name}" >&2
				fail=1
				continue
			fi
			if [[ "$(<"$patch")" != "{}" ]] &&
				! "${KUBECTL[@]}" --context="$ctx" patch istio.sailoperator.io default --type=merge --patch-file="$patch"; then
				echo "  FAIL  ${ctx}: the Istio CR could not be patched back to its state before ${prof}; the marker ${ns}/${name} stays (fix it, then run this again)" >&2
				fail=1
				continue
			fi
			WAIT+=("$ctx")
		done
		LIVE=()
		for ctx in ${WAIT[@]+"${WAIT[@]}"}; do
			read -r ns name prof patch <<<"${CUR[$ctx]}"
			d="${WORK}/$(ctx_key "$ctx")"
			if [[ "$(<"$patch")" != "{}" ]]; then
				if ! wait_for_istiod "$ctx" "$ROLLOUT_TIMEOUT" ||
					! "${KUBECTL[@]}" --context="$ctx" get istio.sailoperator.io default -o json >"${d}/live.json" ||
					! python3 -I "$HELPER" check-revert "$patch" "${d}/live.json"; then
					echo "  FAIL  ${ctx}: the Istio CR is not back to its state before ${prof}; the marker ${ns}/${name} stays (fix it, then run this again)" >&2
					fail=1
					continue
				fi
			fi
			if ! "${KUBECTL[@]}" --context="$ctx" -n "$ns" delete "$MARKER_KIND" "$name" --ignore-not-found >/dev/null; then
				echo "  FAIL  ${ctx}: the Istio CR is restored, but the marker ${ns}/${name} could not be deleted; delete it: ${KUBECTL[*]} --context=${ctx} -n ${ns} delete ${MARKER_KIND} ${name}" >&2
				fail=1
				continue
			fi
			echo "  PASS  ${ctx}: marker ${ns}/${name} removed"
			RESTORED=1
			n=$((${NEXT[$ctx]} + 1))
			NEXT[$ctx]="$n"
			((n >= ${COUNT[$ctx]})) || LIVE+=("$ctx")
		done
	done
fi

echo "--- Leftover profile resources (label ${LABEL}) ---"
for ctx in "${CONTEXTS[@]}"; do
	run "${KUBECTL[@]}" --context="$ctx" delete "$KINDS" -A -l "$LABEL" --ignore-not-found || fail=1
done

echo "--- Argo CD pauses (recorded under ${RESULTS#"${ROOT}"/}) ---"
found=0
while IFS= read -r state; do
	found=1
	run "${TUNING_DIR}/006-gitops-pause.sh" --resume --state-file "$state" || fail=1
done < <(find "$RESULTS" -name gitops-pause.json -type f 2>/dev/null | sort)
((found)) || echo "  none recorded there"
unchecked=0
if [[ -n "$GITOPS_CTX" ]]; then
	echo "--- Argo CD pause on ${GITOPS_CTX}, recorded or not ---"
	run "${TUNING_DIR}/006-gitops-pause.sh" --gitops-context "$GITOPS_CTX" --clear || fail=1
elif ((RESTORED && found == 0)); then
	# The markers outlived their run's results, and the pause record lives there.
	unchecked=1
	echo "warning: the markers restored above were left by a run whose results are not under ${RESULTS#"${ROOT}"/}; if it paused Argo CD, its deny sync window is still on the hub and the Istio CR Applications do not sync: run this again with --gitops-context <hub> (or --results-dir <that run's --output-dir>), or list the windows with ./tests/tuning/006-gitops-pause.sh --gitops-context <hub> --status" >&2
fi

if ((fail)); then
	echo "=== Cleanup finished with errors (see above) ===" >&2
	exit 1
fi
if ((unchecked)); then
	echo "=== Cleanup complete on the members; Argo CD not checked (see the warning above) ==="
else
	echo "=== Cleanup complete ==="
fi

#!/usr/bin/env bash
# Apply one tuning profile to the mesh: merge-patch the Istio CR with the profile's
# istio_cr_patch and server-side apply its resources. Saves what 002-revert-profile.sh
# needs to undo exactly those changes, and the members' Istio CR and IstioRevision
# generations once the apply settled (istio-generations-applied), which 002 compares
# before its revert. A new apply clears what an earlier apply and its revert left in the
# state dir (revert-started, istio-edited-during-pass, istio-generations-unchecked,
# istio-generations-applied). First it puts a marker ConfigMap on each member
# (tuning.py marker) that names the profile and holds that member's Istio CR revert patch:
# every platform record shows it, and 005-cleanup.sh can undo the profile from it alone.
# Refuses while any member holds a profile's objects already (a profile left applied).
#
# Does not pause Argo CD; use 006-gitops-pause.sh (or 003-run-tuning-sweep.sh).
#
# Usage:
#   ./tests/tuning/001-apply-profile.sh --profile NAME|PATH [--contexts CSV] [options]
# ci-dry-run-skip: needs python3 with PyYAML, which not every CI runner has
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh" # istio_generations_read
# shellcheck disable=SC1091
source "${ROOT}/tests/tuning/lib/tuning.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/platform.sh"  # platform_validate, platform_tuning_objects_refuse

TUNING_DIR="${ROOT}/tests/tuning"
HELPER="${TUNING_DIR}/lib/tuning.py"
PROFILE=""
CONTEXTS_CSV=""
STATE_DIR=""
ROLLOUT_TIMEOUT="${TUNING_ROLLOUT_TIMEOUT:-300}"
SKIP_VERIFY=0
DRY_RUN=0

usage() {
	cat <<EOF
Usage: $(basename "$0") --profile NAME|PATH [options]

Apply a tuning profile: patch the Istio CR and apply the profile's resources. Saves what
002-revert-profile.sh needs, and the members' Istio CR and IstioRevision generations once
the apply settled (istio-generations-applied; a member it could not read is a warning).
A new apply clears what an earlier apply and its revert left in the state dir
(revert-started, istio-edited-during-pass, istio-generations-unchecked,
istio-generations-applied). First it puts a marker ConfigMap on each member that names the
profile and holds the patch that restores that member's Istio CR (002-revert-profile.sh
deletes it last). It refuses to start while a member holds a profile's objects or marker
already: a profile left applied, which ./tests/tuning/005-cleanup.sh undoes.

Options:
  --profile NAME|PATH    Profile name (e.g. 01-push-throttling) or YAML path (required).
  --contexts CSV         Mesh member contexts (default: \$SETUP_CONTEXTS).
  --state-dir DIR        Where to save revert state
                         (default: tests/tuning/results/state-<profile>).
  --rollout-timeout N    Seconds to wait for the operator and istiod rollout
                         (default: ${ROLLOUT_TIMEOUT}, from \$TUNING_ROLLOUT_TIMEOUT).
  --skip-verify          Skip the post-apply checks.
  --dry-run              Print the patch and resources; do not touch clusters.
  -h, --help             Show this help.

Environment:
$(platform_help_lines reads)

Exit status: 0 applied and verified, 1 error, 2 applied but verification failed.
Requires python3 with PyYAML.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--profile | --contexts | --state-dir | --rollout-timeout)
		[[ -n "${2:-}" ]] || die "$1 requires a value"
		case "$1" in
		--profile) PROFILE="$2" ;;
		--contexts) CONTEXTS_CSV="$2" ;;
		--state-dir) STATE_DIR="$2" ;;
		--rollout-timeout) ROLLOUT_TIMEOUT="$2" ;;
		esac
		shift 2
		;;
	--skip-verify) SKIP_VERIFY=1; shift ;;
	--dry-run) DRY_RUN=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) die "unknown option: $1 (try --help)" ;;
	esac
done

[[ -n "$PROFILE" ]] || die "--profile is required"
is_pos_int "$ROLLOUT_TIMEOUT" || die "--rollout-timeout (or TUNING_ROLLOUT_TIMEOUT) must be a positive integer; got '${ROLLOUT_TIMEOUT}'"
platform_validate
if [[ ! -f "$PROFILE" ]]; then
	for cand in "${TUNING_DIR}/profiles/${PROFILE}" "${TUNING_DIR}/profiles/${PROFILE}.yaml"; do
		[[ -f "$cand" ]] && { PROFILE="$cand"; break; }
	done
fi
[[ -f "$PROFILE" ]] || die "profile not found: $PROFILE (see tests/tuning/profiles/)"
PROFILE_NAME="$(basename "$PROFILE" .yaml)"

CONTEXTS_CSV="${CONTEXTS_CSV:-${SETUP_CONTEXTS:-}}"
CONTEXTS=()
split_contexts "$CONTEXTS_CSV" CONTEXTS "--contexts (or SETUP_CONTEXTS)"
((${#CONTEXTS[@]})) || die "no contexts (set --contexts or SETUP_CONTEXTS)"
ctx_keys_distinct "${CONTEXTS[@]}"
STATE_DIR="${STATE_DIR:-${TUNING_DIR}/results/state-${PROFILE_NAME}}"

python3 -I -c 'import yaml' 2>/dev/null \
	|| die "python3 with PyYAML is required (dnf install python3-pyyaml, apt install python3-yaml, or pip install pyyaml)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 -I "$HELPER" load "$PROFILE" "$WORK"
HAS_PATCH=0
[[ "$(<"$WORK/patch.json")" != "{}" ]] && HAS_PATCH=1
HAS_RESOURCES=0
[[ -s "$WORK/resources.yaml" ]] && HAS_RESOURCES=1

echo "=== Profile ${PROFILE_NAME} ==="
echo "    $(<"$WORK/description")"
echo "    OSSM support: $(<"$WORK/ossm_support")"
detail="$(<"$WORK/ossm_support_detail")"
[[ -n "$detail" ]] && echo "    ${detail}"
echo "    Contexts:     ${CONTEXTS[*]}"
echo "    State dir:    ${STATE_DIR}"

if ((DRY_RUN)); then
	echo ""
	echo "--- Before any change ---"
	echo "check that no member holds a tuning profile's objects or marker (label ${PLATFORM_TUNING_LABEL}); stop if one does"
	echo "--- Istio CR merge patch ---"
	if ((HAS_PATCH)); then cat "$WORK/patch.json"; else echo "(none)"; fi
	echo "--- Resources (server-side apply) ---"
	if ((HAS_RESOURCES)); then cat "$WORK/resources.yaml"; else echo "(none)"; fi
	echo "--- Marker (server-side apply on each member, before any change) ---"
	echo '{}' >"$WORK/revert-none.json"
	python3 -I "$HELPER" marker "$PROFILE_NAME" "$WORK/description" "$WORK/revert-none.json" dry-run "$WORK/marker.json"
	read -r m_kind m_name m_ns < <(python3 -I "$HELPER" resources "$WORK/marker.json")
	echo "${m_kind} ${m_ns}/${m_name}, labelled ${PLATFORM_TUNING_LABEL}=${PROFILE_NAME}:"
	echo "  it holds the merge patch that restores that member's Istio CR"
	echo "--- Dry run: no cluster changes; would save revert state to ${STATE_DIR}/ ---"
	exit 0
fi

KUBECTL=()
resolve_kubectl KUBECTL

# --- Preflight on every context before changing any of them ---
RES_LINES=()
if ((HAS_RESOURCES)); then
	res_text="$(python3 -I "$HELPER" resources "$WORK/resources.yaml")"
	mapfile -t RES_LINES <<<"$res_text"
fi
[[ ! -f "${STATE_DIR}/active-profile" ]] \
	|| die "${STATE_DIR} already holds an applied profile; revert it first (002-revert-profile.sh --state-dir ${STATE_DIR})"
# A profile left applied by an interrupted run would end up in this profile's revert state.
# The results dir does not exist on a fresh clone.
if [[ -d "${TUNING_DIR}/results" ]]; then
	leftover="$(find "${TUNING_DIR}/results" -name active-profile -type f 2>/dev/null | head -1)"
	[[ -z "$leftover" ]] \
		|| die "profile $(<"$leftover") is still applied (${leftover%/active-profile}); run ./tests/tuning/005-cleanup.sh first"
fi
# And on the members: a profile's objects or marker from a run this checkout has no state of.
platform_tuning_objects_refuse "$CONTEXTS_CSV" "this profile"
mkdir -p "$STATE_DIR"
APPLIED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for ctx in "${CONTEXTS[@]}"; do
	key="$(ctx_key "$ctx")"
	"${KUBECTL[@]}" --context="$ctx" get istio.sailoperator.io default -o json >"${STATE_DIR}/istio-before-${key}.json" \
		|| die "${ctx}: cannot read Istio CR 'default'"
	python3 -I "$HELPER" revert-patch "$WORK/patch.json" "${STATE_DIR}/istio-before-${key}.json" \
		"${STATE_DIR}/istio-revert-${key}.json"
	python3 -I "$HELPER" marker "$PROFILE_NAME" "$WORK/description" "${STATE_DIR}/istio-revert-${key}.json" \
		"$APPLIED_AT" "${STATE_DIR}/marker-${key}.json"
	for line in ${RES_LINES[@]+"${RES_LINES[@]}"}; do
		read -r kind name ns <<<"$line"
		if "${KUBECTL[@]}" --context="$ctx" -n "$ns" get "$kind" "$name" -o name >/dev/null 2>&1; then
			die "${ctx}: ${kind}/${name} already exists in ${ns}; refusing to overwrite it (part of the GitOps baseline or a leftover? see 005-cleanup.sh)"
		fi
	done
done

# Record state before mutating so an interrupted apply can still be reverted. A revert's
# markers, and the generations recorded after an earlier apply in this state dir, do not
# belong to this one.
rm -f "${STATE_DIR}/revert-started" "${STATE_DIR}/istio-edited-during-pass" \
	"${STATE_DIR}/istio-generations-unchecked" "${STATE_DIR}/istio-generations-applied"
cp "$WORK/patch.json" "${STATE_DIR}/patch.json"
cp "$WORK/resources.yaml" "${STATE_DIR}/applied-resources.yaml"
(IFS=,; echo "${CONTEXTS[*]}") >"${STATE_DIR}/contexts"
echo "$PROFILE_NAME" >"${STATE_DIR}/active-profile"

# The marker on every member before any change (002-revert-profile.sh deletes it last).
read -r MARKER_KIND MARKER_NAME MARKER_NS < <(python3 -I "$HELPER" resources "${STATE_DIR}/marker-$(ctx_key "${CONTEXTS[0]}").json")
# The objects the profile puts on every member, as the platform record names them: tuning 004
# checks that each pass's record holds them all.
{
	echo "${MARKER_KIND}/${MARKER_NS}/${MARKER_NAME}"
	for line in ${RES_LINES[@]+"${RES_LINES[@]}"}; do
		read -r kind name ns <<<"$line"
		echo "${kind}/${ns}/${name}"
	done
} >"${STATE_DIR}/objects"
for ctx in "${CONTEXTS[@]}"; do
	echo "--- ${ctx}: marking ${PROFILE_NAME} applied (${MARKER_KIND} ${MARKER_NS}/${MARKER_NAME}) ---"
	"${KUBECTL[@]}" --context="$ctx" apply --server-side --field-manager=tuning-profile \
		-f "${STATE_DIR}/marker-$(ctx_key "$ctx").json" \
		|| die "${ctx}: could not create the profile's marker; nothing is patched yet. Remove the markers already created with ./tests/tuning/002-revert-profile.sh --state-dir ${STATE_DIR}"
done

for ctx in "${CONTEXTS[@]}"; do
	if ((HAS_PATCH)); then
		echo "--- ${ctx}: patching Istio CR ---"
		"${KUBECTL[@]}" --context="$ctx" patch istio.sailoperator.io default --type=merge \
			--patch-file="$WORK/patch.json"
	fi
	if ((HAS_RESOURCES)); then
		echo "--- ${ctx}: applying resources ---"
		"${KUBECTL[@]}" --context="$ctx" apply --server-side --field-manager=tuning-profile \
			-f "$WORK/resources.yaml"
	fi
done

if ((HAS_PATCH)); then
	echo "--- Waiting for the operator and istiod rollout ---"
	deadline=$(($(date +%s) + ROLLOUT_TIMEOUT))
	for ctx in "${CONTEXTS[@]}"; do
		wait_for_istiod "$ctx" "$ROLLOUT_TIMEOUT" "$deadline" || die "${ctx}: istiod did not roll out; revert with 002-revert-profile.sh --state-dir ${STATE_DIR}"
	done
fi

# The generations this apply left (the patch raises the Istio CR's, and Sail the active
# IstioRevision's): 002 reads them again before its revert, and a member whose generation
# moved in between had its Istio CR edited by something else during the pass. A member
# whose read failed is recorded as unknown, which 002 cannot compare: say so now.
GENS_APPLIED="$(istio_generations_read "$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}")"
if ! printf '%s\n' "$GENS_APPLIED" >"${STATE_DIR}/istio-generations-applied"; then
	echo "warn: could not write ${STATE_DIR}/istio-generations-applied; 002 cannot check that nothing else edited the Istio CR during the pass" >&2
elif [[ "$GENS_APPLIED" == *unknown* ]]; then
	echo "warn: the Istio CR generations of a member could not be read after the apply settled (${GENS_APPLIED}): 002 cannot check that member for an edit during the pass, and says so (istio-generations-unchecked)" >&2
fi

REVERT_HINT="Revert: ./tests/tuning/002-revert-profile.sh --state-dir ${STATE_DIR}"
if ((SKIP_VERIFY)); then
	echo "=== ${PROFILE_NAME} applied (not verified) ==="
	echo "    ${REVERT_HINT}"
	exit 0
fi

echo "--- Verifying ---"
fail=0
for ctx in "${CONTEXTS[@]}"; do
	echo "  ${ctx}:"
	if ((HAS_PATCH)); then
		"${KUBECTL[@]}" --context="$ctx" get istio.sailoperator.io default -o json >"$WORK/live.json"
		rev="$("${KUBECTL[@]}" --context="$ctx" get istio.sailoperator.io default -o jsonpath='{.status.activeRevisionName}')"
		deploy="istiod"
		[[ "$rev" != "default" ]] && deploy="istiod-${rev}"
		"${KUBECTL[@]}" --context="$ctx" -n istio-system get deployment "$deploy" -o json >"$WORK/deploy.json"
		python3 -I "$HELPER" check "$WORK/patch.json" "$WORK/live.json" "$WORK/deploy.json" || fail=1
	fi
	for line in ${RES_LINES[@]+"${RES_LINES[@]}"} "${MARKER_KIND} ${MARKER_NAME} ${MARKER_NS}"; do
		read -r kind name ns <<<"$line"
		if "${KUBECTL[@]}" --context="$ctx" -n "$ns" get "$kind" "$name" -o name >/dev/null 2>&1; then
			echo "  PASS  ${kind}/${name} exists in ${ns}"
		else
			echo "  FAIL  ${kind}/${name} missing in ${ns}"
			fail=1
		fi
	done
done

if ((fail)); then
	echo "=== ${PROFILE_NAME} applied, but verification FAILED ===" >&2
	echo "    ${REVERT_HINT}" >&2
	exit 2
fi
echo "=== ${PROFILE_NAME} applied and verified ==="
echo "    ${REVERT_HINT}"

#!/usr/bin/env bash
# Apply one tuning profile to the mesh: merge-patch the Istio CR with the profile's
# istio_cr_patch and server-side apply its resources. Saves what 002-revert-profile.sh
# needs to undo exactly those changes.
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
source "${ROOT}/tests/tuning/lib/tuning.sh"

TUNING_DIR="${ROOT}/tests/tuning"
HELPER="${TUNING_DIR}/lib/tuning.py"
PROFILE=""
CONTEXTS_CSV=""
STATE_DIR=""
ROLLOUT_TIMEOUT=300
SKIP_VERIFY=0
DRY_RUN=0

usage() {
	cat <<EOF
Usage: $(basename "$0") --profile NAME|PATH [options]

Apply a tuning profile: patch the Istio CR and apply the profile's resources.

Options:
  --profile NAME|PATH    Profile name (e.g. 01-push-throttling) or YAML path (required).
  --contexts CSV         Mesh member contexts (default: \$SETUP_CONTEXTS).
  --state-dir DIR        Where to save revert state
                         (default: tests/tuning/results/state-<profile>).
  --rollout-timeout N    Seconds to wait for the operator and istiod rollout
                         (default: ${ROLLOUT_TIMEOUT}).
  --skip-verify          Skip the post-apply checks.
  --dry-run              Print the patch and resources; do not touch clusters.
  -h, --help             Show this help.

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
is_pos_int "$ROLLOUT_TIMEOUT" || die "--rollout-timeout must be a positive integer"
if [[ ! -f "$PROFILE" ]]; then
	for cand in "${TUNING_DIR}/profiles/${PROFILE}" "${TUNING_DIR}/profiles/${PROFILE}.yaml"; do
		[[ -f "$cand" ]] && { PROFILE="$cand"; break; }
	done
fi
[[ -f "$PROFILE" ]] || die "profile not found: $PROFILE (see tests/tuning/profiles/)"
PROFILE_NAME="$(basename "$PROFILE" .yaml)"

CONTEXTS_CSV="${CONTEXTS_CSV:-${SETUP_CONTEXTS:-}}"
CONTEXTS=()
split_csv "$CONTEXTS_CSV" CONTEXTS
((${#CONTEXTS[@]})) || die "no contexts (set --contexts or SETUP_CONTEXTS)"
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
	echo "--- Istio CR merge patch ---"
	if ((HAS_PATCH)); then cat "$WORK/patch.json"; else echo "(none)"; fi
	echo "--- Resources (server-side apply) ---"
	if ((HAS_RESOURCES)); then cat "$WORK/resources.yaml"; else echo "(none)"; fi
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
leftover="$(find "${TUNING_DIR}/results" -name active-profile -type f 2>/dev/null | head -1)"
[[ -z "$leftover" ]] \
	|| die "profile $(<"$leftover") is still applied (${leftover%/active-profile}); run ./tests/tuning/005-cleanup.sh first"
mkdir -p "$STATE_DIR"
for ctx in "${CONTEXTS[@]}"; do
	key="$(ctx_key "$ctx")"
	"${KUBECTL[@]}" --context="$ctx" get istio.sailoperator.io default -o json >"${STATE_DIR}/istio-before-${key}.json" \
		|| die "${ctx}: cannot read Istio CR 'default'"
	python3 -I "$HELPER" revert-patch "$WORK/patch.json" "${STATE_DIR}/istio-before-${key}.json" \
		"${STATE_DIR}/istio-revert-${key}.json"
	for line in "${RES_LINES[@]}"; do
		read -r kind name ns <<<"$line"
		if "${KUBECTL[@]}" --context="$ctx" -n "$ns" get "$kind" "$name" -o name >/dev/null 2>&1; then
			die "${ctx}: ${kind}/${name} already exists in ${ns}; refusing to overwrite it (part of the GitOps baseline or a leftover? see 005-cleanup.sh)"
		fi
	done
done

# Record state before mutating so an interrupted apply can still be reverted.
cp "$WORK/patch.json" "${STATE_DIR}/patch.json"
cp "$WORK/resources.yaml" "${STATE_DIR}/applied-resources.yaml"
(IFS=,; echo "${CONTEXTS[*]}") >"${STATE_DIR}/contexts"
echo "$PROFILE_NAME" >"${STATE_DIR}/active-profile"

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
	for ctx in "${CONTEXTS[@]}"; do
		wait_for_istiod "$ctx" "$ROLLOUT_TIMEOUT" || die "${ctx}: istiod did not roll out; revert with 002-revert-profile.sh --state-dir ${STATE_DIR}"
	done
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
	for line in "${RES_LINES[@]}"; do
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

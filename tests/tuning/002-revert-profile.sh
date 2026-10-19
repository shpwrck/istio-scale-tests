#!/usr/bin/env bash
# Revert a profile applied by 001-apply-profile.sh: delete its resources and
# merge-patch the Istio CR back to the saved values at every path the profile set.
# Then check that those paths and resources match the pre-apply state, and only then
# delete the profile's marker ConfigMap on each member (a failed revert keeps it, so
# every platform record and the next tuning run see the profile still applied).
#
# Usage:
#   ./tests/tuning/002-revert-profile.sh --state-dir DIR [--contexts CSV] [options]
# ci-dry-run-skip: needs --state-dir from a prior 001-apply-profile.sh run
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/tuning/lib/tuning.sh"

HELPER="${ROOT}/tests/tuning/lib/tuning.py"
STATE_DIR=""
CONTEXTS_CSV=""
ROLLOUT_TIMEOUT=300
DRY_RUN=0
NS_PROBE="${TUNING_REVERT_HEALTHCHECK_NS_PROBE:-0}"
NS_PROBE_TIMEOUT="${TUNING_REVERT_HEALTHCHECK_TIMEOUT:-60}"

usage() {
	cat <<EOF
Usage: $(basename "$0") --state-dir DIR [options]

Undo a profile applied by 001-apply-profile.sh and check the result. Only when the
check passes does it delete the profile's marker ConfigMap on each member, so a failed
revert stays visible to every platform record and blocks the next tuning run.

Options:
  --state-dir DIR        State directory written by 001-apply-profile.sh (required).
  --contexts CSV         Contexts to revert (default: the contexts recorded at apply).
  --rollout-timeout N    Seconds to wait for the operator and istiod rollout
                         (default: ${ROLLOUT_TIMEOUT}).
  --dry-run              Print the revert patches, resources and markers; do not touch
                         clusters.
  -h, --help             Show this help.

Environment:
  TUNING_REVERT_HEALTHCHECK_NS_PROBE=1  Also create a probe namespace and wait up to
                                        TUNING_REVERT_HEALTHCHECK_TIMEOUT seconds for
                                        istio-ca-root-cert to appear in it.

Exit status: 0 reverted and checked, 1 error, 3 the post-revert check failed.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--state-dir | --contexts | --rollout-timeout)
		[[ -n "${2:-}" ]] || die "$1 requires a value"
		case "$1" in
		--state-dir) STATE_DIR="$2" ;;
		--contexts) CONTEXTS_CSV="$2" ;;
		--rollout-timeout) ROLLOUT_TIMEOUT="$2" ;;
		esac
		shift 2
		;;
	--dry-run) DRY_RUN=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) die "unknown option: $1 (try --help)" ;;
	esac
done

[[ -n "$STATE_DIR" ]] || die "--state-dir is required"
[[ -d "$STATE_DIR" ]] || die "state directory not found: $STATE_DIR"
is_pos_int "$ROLLOUT_TIMEOUT" || die "--rollout-timeout must be a positive integer"
if [[ -z "$CONTEXTS_CSV" && -f "${STATE_DIR}/contexts" ]]; then
	CONTEXTS_CSV="$(<"${STATE_DIR}/contexts")"
fi
CONTEXTS=()
split_csv "${CONTEXTS_CSV:-${SETUP_CONTEXTS:-}}" CONTEXTS
((${#CONTEXTS[@]})) || die "no contexts (set --contexts or SETUP_CONTEXTS)"

PROFILE_NAME="unknown"
[[ -f "${STATE_DIR}/active-profile" ]] && PROFILE_NAME="$(<"${STATE_DIR}/active-profile")"
RESOURCES="${STATE_DIR}/applied-resources.yaml"
HAS_RESOURCES=0
[[ -s "$RESOURCES" ]] && HAS_RESOURCES=1


echo "=== Reverting ${PROFILE_NAME} ==="
echo "    State dir: ${STATE_DIR}"
echo "    Contexts:  ${CONTEXTS[*]}"
[[ -f "${STATE_DIR}/active-profile" ]] || echo "    note: no active-profile marker (already reverted?); reverting anyway"

if ((DRY_RUN)); then
	for ctx in "${CONTEXTS[@]}"; do
		f="${STATE_DIR}/istio-revert-$(ctx_key "$ctx").json"
		echo "--- ${ctx}: Istio CR merge patch ---"
		if [[ -f "$f" ]]; then cat "$f"; else echo "MISSING: $f"; fi
	done
	echo "--- Resources to delete ---"
	if ((HAS_RESOURCES)); then cat "$RESOURCES"; else echo "(none)"; fi
	echo "--- Markers to delete once the check passes ---"
	for ctx in "${CONTEXTS[@]}"; do
		f="${STATE_DIR}/marker-$(ctx_key "$ctx").json"
		if [[ -f "$f" ]]; then
			read -r m_kind m_name m_ns < <(python3 -I "$HELPER" resources "$f")
			echo "${ctx}: ${m_kind} ${m_ns}/${m_name}"
		else
			echo "${ctx}: (none recorded: applied before profiles had markers)"
		fi
	done
	echo "--- Dry run: no cluster changes ---"
	exit 0
fi

KUBECTL=()
resolve_kubectl KUBECTL

# Optional end-to-end check that istiod still distributes the root cert to a new,
# discoverable namespace.
ns_probe() {
	local ctx="$1" ns="tuning-revert-probe-$$" deadline ok=1
	"${KUBECTL[@]}" --context="$ctx" create namespace "$ns" >/dev/null || return 1
	"${KUBECTL[@]}" --context="$ctx" label namespace "$ns" istio-discovery=enabled >/dev/null || ok=0
	deadline=$(($(date +%s) + NS_PROBE_TIMEOUT))
	until "${KUBECTL[@]}" --context="$ctx" -n "$ns" get configmap istio-ca-root-cert >/dev/null 2>&1; do
		(($(date +%s) < deadline)) || { ok=0; break; }
		sleep 5
	done
	"${KUBECTL[@]}" --context="$ctx" delete namespace "$ns" --wait=false >/dev/null 2>&1 || true
	((ok))
}

fail=0
PATCHED=()
for ctx in "${CONTEXTS[@]}"; do
	if ((HAS_RESOURCES)); then
		echo "--- ${ctx}: deleting profile resources ---"
		"${KUBECTL[@]}" --context="$ctx" delete --ignore-not-found -f "$RESOURCES" || fail=1
	fi
	revert="${STATE_DIR}/istio-revert-$(ctx_key "$ctx").json"
	if [[ ! -f "$revert" ]]; then
		echo "  FAIL  ${ctx}: no saved revert patch ($revert)" >&2
		fail=1
		continue
	fi
	if [[ "$(<"$revert")" != "{}" ]]; then
		echo "--- ${ctx}: restoring Istio CR ---"
		if "${KUBECTL[@]}" --context="$ctx" patch istio.sailoperator.io default --type=merge --patch-file="$revert"; then
			PATCHED+=("$ctx")
		else
			fail=1
		fi
	fi
done

for ctx in "${PATCHED[@]}"; do
	wait_for_istiod "$ctx" "$ROLLOUT_TIMEOUT" || fail=1
done

echo "--- Post-revert check ---"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
for ctx in "${CONTEXTS[@]}"; do
	echo "  ${ctx}:"
	revert="${STATE_DIR}/istio-revert-$(ctx_key "$ctx").json"
	if [[ -f "$revert" && "$(<"$revert")" != "{}" ]]; then
		if "${KUBECTL[@]}" --context="$ctx" get istio.sailoperator.io default -o json >"$WORK/live.json"; then
			python3 -I "$HELPER" check-revert "$revert" "$WORK/live.json" || fail=1
		else
			fail=1
		fi
	fi
	if ((HAS_RESOURCES)); then
		left="$("${KUBECTL[@]}" --context="$ctx" get --ignore-not-found -f "$RESOURCES" -o name 2>&1)" || left="query failed: ${left}"
		if [[ -z "$left" ]]; then
			echo "  PASS  profile resources removed"
		else
			echo "  FAIL  still present: ${left//$'\n'/ }"
			fail=1
		fi
	fi
	if [[ "$NS_PROBE" == "1" ]]; then
		if ns_probe "$ctx"; then
			echo "  PASS  istio-ca-root-cert reached a new namespace"
		else
			echo "  FAIL  istio-ca-root-cert did not reach a new namespace within ${NS_PROBE_TIMEOUT}s"
			fail=1
		fi
	fi
done

# The markers last, once everything else is back (a state dir from before the markers has none).
if ((fail == 0)); then
	for ctx in "${CONTEXTS[@]}"; do
		marker="${STATE_DIR}/marker-$(ctx_key "$ctx").json"
		[[ -f "$marker" ]] || continue
		left=""
		if "${KUBECTL[@]}" --context="$ctx" delete --ignore-not-found -f "$marker" >/dev/null &&
			left="$("${KUBECTL[@]}" --context="$ctx" get --ignore-not-found -f "$marker" -o name 2>&1)" && [[ -z "$left" ]]; then
			echo "  PASS  ${ctx}: profile marker removed"
		else
			echo "  FAIL  ${ctx}: profile marker still present: ${left:-the delete failed}"
			fail=1
		fi
	done
fi

if ((fail)); then
	echo "=== Revert of ${PROFILE_NAME} FAILED the check; the mesh may still carry profile changes ===" >&2
	echo "    Fix it, then re-run: ./tests/tuning/002-revert-profile.sh --state-dir ${STATE_DIR}" >&2
	exit 3
fi
rm -f "${STATE_DIR}/active-profile"
echo "=== ${PROFILE_NAME} reverted ==="

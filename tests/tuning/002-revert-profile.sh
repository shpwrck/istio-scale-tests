#!/usr/bin/env bash
# Revert a profile applied by 001-apply-profile.sh: delete its resources and
# merge-patch the Istio CR back to the saved values at every path the profile set.
# Then check that those paths and resources match the pre-apply state. Before it changes
# anything, it compares the members' Istio CR and IstioRevision generations with the ones
# 001 recorded once its apply settled: one that moved means something else edited the
# Istio CR during the pass (warned, and written to istio-edited-during-pass in the state
# dir, which 003-run-tuning-sweep.sh reports as a problem); the revert still runs. A member
# whose generations could not be read, now or then, is not compared: warned, and written to
# istio-generations-unchecked, which 003 notes. It writes revert-started in the state dir
# before its first change: a re-run (after a revert that stopped partway) skips that
# comparison, since its own first run may have patched the Istio CR already, and keeps
# what that run found.
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
source "${ROOT}/tests/lib/preamble.sh" # istio_generations_read, istio_generations_diff
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

Undo a profile applied by 001-apply-profile.sh and check the result.

Options:
  --state-dir DIR        State directory written by 001-apply-profile.sh (required).
  --contexts CSV         Contexts to revert (default: the contexts recorded at apply).
  --rollout-timeout N    Seconds to wait for the operator and istiod rollout
                         (default: ${ROLLOUT_TIMEOUT}).
  --dry-run              Print the revert patches and resources; do not touch clusters.
  -h, --help             Show this help.

Environment:
  TUNING_REVERT_HEALTHCHECK_NS_PROBE=1  Also create a probe namespace and wait up to
                                        TUNING_REVERT_HEALTHCHECK_TIMEOUT seconds for
                                        istio-ca-root-cert to appear in it.

Before the revert it compares the members' Istio CR and IstioRevision generations with
the ones recorded after the apply (istio-generations-applied in the state dir: 001's,
or 003-run-tuning-sweep.sh's read once the apply settled). A generation that moved means
something else edited the Istio CR (Argo CD not paused, another operator, an OSSM
operator upgrade) during the pass, or, after an apply that failed (SETUP_FAILED beside
the state dir, under 003), between that apply and this revert: it warns and writes
istio-edited-during-pass in the state dir (003-run-tuning-sweep.sh then fails the sweep,
exit 4), and the revert still runs. A member whose generations could not be read (now or
then) is not compared: it warns and writes istio-generations-unchecked (003 adds a note
to its outcome). Its exit status does not change. A re-run after a revert that stopped
partway (revert-started in the state dir: it may have patched the Istio CR already)
skips this comparison, with a note, and keeps what the first run found.

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
split_contexts "${CONTEXTS_CSV:-${SETUP_CONTEXTS:-}}" CONTEXTS "--contexts (or SETUP_CONTEXTS, or the state dir's contexts file)"
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

# Did anything but this profile edit the Istio CR since 001's apply settled? Only on the
# first revert of this apply: a re-run (revert-started) may follow its own patch, which
# raised the generations, and keeps istio-edited-during-pass as the first run left it.
# The span: the pass, or under 003-run-tuning-sweep.sh after an apply that failed (its
# SETUP_FAILED next to the state dir: no probe ran), from that apply to this revert, named
# as 003 names it. A re-run after a revert that finished has no active-profile left: the
# pass is then the state dir's parent (003's <pass>/state), else "its pass".
in_span="during the pass" changed="during the pass of ${PROFILE_NAME}, after its apply settled and"
effect="The pass's probes may have measured another configuration."
if [[ -e "${STATE_DIR}/../SETUP_FAILED" ]]; then
	pass_l="$PROFILE_NAME"
	if [[ "$pass_l" == unknown ]]; then
		pass_l="$(cd "${STATE_DIR}/.." 2>/dev/null && pwd)" || pass_l=""
		pass_l="${pass_l##*/}"
	fi
	if [[ -n "$pass_l" ]]; then pass_l="pass ${pass_l}"; else pass_l="its pass"; fi
	in_span="between the failed apply of ${pass_l} and its revert"
	changed="${in_span}," effect="The passes after it may have measured another configuration."
fi
if [[ -e "${STATE_DIR}/revert-started" ]]; then
	echo "    note: a revert of this apply started before ($(head -n 1 "${STATE_DIR}/revert-started" 2>/dev/null || echo "time unknown")) and may have patched the Istio CR already: no check that it was left alone ${in_span} (that run's finding, if any, stays in istio-edited-during-pass)"
elif [[ -s "${STATE_DIR}/istio-generations-applied" ]]; then
	rm -f "${STATE_DIR}/istio-edited-during-pass" "${STATE_DIR}/istio-generations-unchecked"
	gen_applied="$(<"${STATE_DIR}/istio-generations-applied")"
	gen_now="$(istio_generations_read "$(IFS=,; echo "${CONTEXTS[*]}")" "${KUBECTL[@]}")"
	gen_moved="$(istio_generations_diff "$gen_applied" "$gen_now")"
	# A member whose generations could not be read (now, or when the apply settled) is not
	# compared: say so, and leave it in istio-generations-unchecked for 003's outcome.
	gen_unchecked="$(istio_generations_diff --unchecked "$gen_applied" "$gen_now")"
	if [[ -n "$gen_unchecked" ]]; then
		printf '%s\n' "$gen_unchecked" >"${STATE_DIR}/istio-generations-unchecked" \
			|| echo "warn: could not write ${STATE_DIR}/istio-generations-unchecked" >&2
		echo "warning: the Istio CR generations of a member could not be compared with the ones recorded once the apply of ${PROFILE_NAME} settled (a read failed): ${gen_unchecked}. An edit of its Istio CR ${in_span} is not ruled out (istio-generations-unchecked in the state dir). Reverting anyway." >&2
	fi
	if [[ -n "$gen_moved" ]]; then
		printf '%s\n' "$gen_moved" >"${STATE_DIR}/istio-edited-during-pass" \
			|| echo "warn: could not write ${STATE_DIR}/istio-edited-during-pass" >&2
		tab=$'\t'
		echo "WARNING: the Istio CR changed ${changed} not by this profile: ${gen_moved#*"$tab"}. Likely: $(istio_generation_causes "${gen_moved%%"$tab"*}"). ${effect} Reverting anyway." >&2
	fi
else
	rm -f "${STATE_DIR}/istio-edited-during-pass"
	echo "    note: no istio-generations-applied in the state dir (001 stopped before its apply settled, could not write it, or an older 001 ran): no check that the Istio CR was left alone ${in_span}"
	printf '%s\n' "every member (no istio-generations-applied in the state dir)" >"${STATE_DIR}/istio-generations-unchecked" \
		|| echo "warn: could not write ${STATE_DIR}/istio-generations-unchecked" >&2
fi
# Before the first change: a re-run of this revert knows one started.
date -u +%Y-%m-%dT%H:%M:%SZ >"${STATE_DIR}/revert-started" \
	|| echo "warn: could not write ${STATE_DIR}/revert-started; a re-run of this revert would compare the generations again" >&2

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

for ctx in ${PATCHED[@]+"${PATCHED[@]}"}; do
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

if ((fail)); then
	echo "=== Revert of ${PROFILE_NAME} FAILED the check; the mesh may still carry profile changes ===" >&2
	echo "    Fix it, then re-run: ./tests/tuning/002-revert-profile.sh --state-dir ${STATE_DIR}" >&2
	exit 3
fi
rm -f "${STATE_DIR}/active-profile"
echo "=== ${PROFILE_NAME} reverted ==="

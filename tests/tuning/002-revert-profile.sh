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
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"

STATE_DIR=""
CONTEXTS_CSV=""
DRY_RUN=0
ISTIO_CR_NAME="default"
ISTIO_CR_NAMESPACE="istio-system"
ROLLOUT_TIMEOUT=300
KUBECTL="kubectl"

# Issue #19 post-revert health gate knobs (defaulted from config/options.env).
HEALTHCHECK_NS_PROBE="${TUNING_REVERT_HEALTHCHECK_NS_PROBE:-0}"
HEALTHCHECK_TIMEOUT="${TUNING_REVERT_HEALTHCHECK_TIMEOUT:-60}"
HEALTHCHECK_INTERVAL="${TUNING_REVERT_HEALTHCHECK_INTERVAL:-5}"
HEALTHCHECK_NS_PREFIX="${TUNING_REVERT_HEALTHCHECK_NS_PREFIX:-tuning-revert-probe}"
# shellcheck disable=SC2206  # intentional word-split of the space-separated path list
DIRTY_PATHS=(${TUNING_REVERT_DIRTY_PATHS:-.spec.values.meshConfig.discoverySelectors .spec.values.pilot.env.PILOT_ENABLE_CDS_CACHE})

# --- Issue #19: baseline-integrity detector (shared by 001 capture + 002 restore) ---
# A baseline snapshot is captured by reading the LIVE Istio CR. If the live CR already
# carries a stale tuning override (e.g. a prior sweep was interrupted before its revert),
# that override is baked INTO the snapshot — so a later "revert" faithfully restores the
# DIRTY state and the mesh is never actually returned to default. This is the root cause
# class behind #19. We cannot tell a legitimately-configured field from a leaked override
# purely offline, so we DETECT the known tuning-override fields in a baseline YAML and WARN
# loudly; we never silently mutate the snapshot. The ideal long-term fix is to capture the
# baseline from the GitOps/Argo source of truth rather than the live CR (see README +
# PR notes) — this detector is the in-suite guard until then.
# Usage: baseline_dirty_warn <baseline-yaml-file> <context-label>
# Returns 0 always (advisory). Echoes WARN lines for any override field found.
# shellcheck disable=SC2329
baseline_dirty_warn() {
	local file="$1" label="$2"
	[[ -f "$file" ]] || return 0
	command -v yq >/dev/null 2>&1 || return 0
	local p val found=0
	for p in "${DIRTY_PATHS[@]}"; do
		# yq eval of the path; a non-empty, non-"null" result means the field is present.
		val="$(yq -r "${p} // \"\"" "$file" 2>/dev/null)" || val=""
		if [[ -n "$val" && "$val" != "null" ]]; then
			echo "  WARN  ${label}: captured baseline already contains tuning-override field ${p} (= ${val})" >&2
			found=1
		fi
	done
	if ((found)); then
		echo "  WARN  ${label}: this baseline was captured from a LIVE Istio CR that still" >&2
		echo "        carried a tuning override — reverting to it will NOT return the mesh to" >&2
		echo "        default (issue #19). Capture the baseline from the GitOps source of truth," >&2
		echo "        or restore the mesh to default before re-capturing." >&2
	fi
	return 0
}

# --- Issue #19: post-revert mesh-health gate ---
# After a revert, assert the mesh is actually back to default. Two layers:
#   (1) ALWAYS: the known tuning-override fields (DIRTY_PATHS — discoverySelectors,
#       PILOT_ENABLE_CDS_CACHE, …) must be ABSENT from the live Istio CR. A surviving
#       discoverySelectors is exactly what stopped istio-ca-root-cert distributing to
#       new namespaces and stuck pods in Init:0/2 (#19).
#   (2) OPT-IN (TUNING_REVERT_HEALTHCHECK_NS_PROBE=1): create a throwaway namespace,
#       label it istio-discovery=enabled so it is discoverable under the campaign
#       baseline, and confirm the istio-ca-root-cert configmap lands in it within the
#       timeout — an end-to-end proof that cert distribution to NEW namespaces works.
# The function is offline-safe to DEFINE (it only touches a cluster when called at
# revert time) and is a no-op under --dry-run. It returns non-zero (and prints a loud
# DIRTY banner) if the mesh is left modified, so the caller (003 trap / sweep) can
# surface that the mesh needs manual attention; it does not itself exit.
# Usage: revert_health_check <context>   ->  0 = clean, 1 = dirty
# shellcheck disable=SC2329
revert_health_check() {
	local ctx="$1"
	local dirty=0 p val

	echo "--- ${ctx}: post-revert health check ---"

	# Layer 1: assert override fields are gone from the live Istio CR.
	for p in "${DIRTY_PATHS[@]}"; do
		val="$($KUBECTL --context="$ctx" get istio "$ISTIO_CR_NAME" \
			-n "$ISTIO_CR_NAMESPACE" \
			-o "jsonpath={${p}}" 2>/dev/null)" || val=""
		if [[ -n "$val" ]]; then
			echo "  FAIL  ${ctx}: Istio CR still has ${p} = ${val} after revert" >&2
			dirty=1
		else
			echo "  PASS  ${ctx}: Istio CR ${p} absent"
		fi
	done

	# Layer 2 (opt-in): freshly-created namespace must receive istio-ca-root-cert.
	if [[ "$HEALTHCHECK_NS_PROBE" == "1" ]]; then
		local probe_ns="${HEALTHCHECK_NS_PREFIX}-${ctx}-$$"
		echo "  ${ctx}: probing istio-ca-root-cert distribution via namespace ${probe_ns}"
		if $KUBECTL --context="$ctx" create namespace "$probe_ns" >/dev/null 2>&1; then
			$KUBECTL --context="$ctx" label namespace "$probe_ns" \
				istio-discovery=enabled --overwrite >/dev/null 2>&1 || true
			local deadline got=0
			deadline=$(( $(date +%s) + HEALTHCHECK_TIMEOUT ))
			while (( $(date +%s) < deadline )); do
				if $KUBECTL --context="$ctx" get configmap istio-ca-root-cert \
					-n "$probe_ns" >/dev/null 2>&1; then
					got=1
					break
				fi
				sleep "$HEALTHCHECK_INTERVAL"
			done
			if ((got)); then
				echo "  PASS  ${ctx}: istio-ca-root-cert distributed to ${probe_ns}"
			else
				echo "  FAIL  ${ctx}: istio-ca-root-cert NOT distributed to ${probe_ns} within ${HEALTHCHECK_TIMEOUT}s — mesh cert distribution is broken (#19)" >&2
				dirty=1
			fi
			$KUBECTL --context="$ctx" delete namespace "$probe_ns" \
				--ignore-not-found --wait=false >/dev/null 2>&1 || true
		else
			echo "  WARN  ${ctx}: could not create probe namespace ${probe_ns} — skipping cert-distribution probe" >&2
		fi
	fi

	if ((dirty)); then
		echo "" >&2
		echo "  *** MESH LEFT DIRTY on ${ctx} after revert (issue #19). Inspect the Istio CR" >&2
		echo "      and restore it to default manually before running further suites. ***" >&2
		return 1
	fi
	return 0
}

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
		# Issue #19: warn if the snapshot we are about to restore is itself dirty
		# (a stale override baked in at capture time). Restoring it cannot clean the mesh.
		baseline_dirty_warn "$baseline" "$ctx"
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

echo ""
echo "=== Post-revert mesh-health check (issue #19) ==="
REVERT_DIRTY=0
for ctx in "${CONTEXTS[@]}"; do
	ctx="${ctx#"${ctx%%[![:space:]]*}"}"
	ctx="${ctx%"${ctx##*[![:space:]]}"}"
	[[ -z "$ctx" ]] && continue
	revert_health_check "$ctx" || REVERT_DIRTY=1
done

rm -f "${STATE_DIR}/active-profile"
rm -f "${STATE_DIR}/applied-resources.yaml"

echo ""
if ((REVERT_DIRTY)); then
	echo "=== Revert complete — BUT mesh health check FAILED (mesh left dirty, see above) ==="
	exit 3
fi
echo "=== Revert complete ==="

#!/usr/bin/env bash
# Orchestrate tuning profile evaluation: for each profile, apply the profile
# to the mesh, run the specified test suite probe(s), collect results into a
# profile-tagged subdirectory, then revert the mesh to baseline.
#
# Usage:
#   ./tests/tuning/003-run-tuning-sweep.sh --suite <suite> [--profiles CSV] [options]
#
# Examples:
#   # Sweep two profiles against the controlplane suite:
#   ./tests/tuning/003-run-tuning-sweep.sh \
#     --contexts cluster-001,cluster-002,cluster-003 \
#     --profiles 01-sidecar-scoping,03-push-throttling \
#     --suite controlplane
#
#   # Sweep all supported profiles against propagation:
#   ./tests/tuning/003-run-tuning-sweep.sh \
#     --contexts cluster-001,cluster-002,cluster-003 \
#     --suite propagation
#
#   # Dry-run to see the plan:
#   ./tests/tuning/003-run-tuning-sweep.sh --dry-run \
#     --profiles 01-sidecar-scoping,06-xds-cache-tuning --suite controlplane
# ci-dry-run-skip: needs yq and valid --suite directory with profiles
set -euo pipefail
# P3: loud ERR trap so an unexpected abort self-reports the failing line. Per-profile
# probe failures are caught via PIPESTATUS below and degraded to warn+continue.
# shellcheck disable=SC2154  # rc is assigned at the head of the trap body
trap 'rc=$?; echo "FATAL: ${0##*/} aborted (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"

TUNING_DIR="${ROOT}/tests/tuning"
PROFILES_DIR="${TUNING_DIR}/profiles"

PROFILES_CSV=""
SUITE=""
CONTEXTS_CSV=""
DRY_RUN=0
SETTLE_SEC="${TUNING_SETTLE_SEC:-60}"
OUTPUT_DIR_BASE="${TUNING_DIR}/results"
INCLUDE_BASELINE=1
ROLLOUT_TIMEOUT=300

# Issue #19: track the state dir of the profile currently applied to the mesh so the
# guaranteed-revert trap below knows what to undo. Empty string = no profile active
# (baseline measurement, or already reverted) -> the trap is a safe no-op. Set right
# before a profile's apply and cleared right after its revert succeeds.
ACTIVE_STATE_DIR=""

# Guaranteed revert (issue #19): a sweep that is interrupted (Ctrl-C / SIGTERM) or that
# aborts on an unexpected error between a profile's apply and its revert would otherwise
# leave the Istio CR mutated — the exact failure that left meshConfig.discoverySelectors
# active and stopped istio-ca-root-cert from distributing to new namespaces, breaking
# every later suite. This EXIT/INT/TERM trap reverts whatever profile is currently active,
# idempotently: it does nothing when no profile is active, and the underlying
# 002-revert-profile.sh is itself safe to re-run (apply --server-side of the baseline +
# ignore-not-found deletes). The trap NEVER aborts (it tolerates a failing revert and a
# missing cluster) so it cannot mask the original exit status.
# shellcheck disable=SC2329
revert_active_profile() {
	local sd="$ACTIVE_STATE_DIR"
	[[ -n "$sd" ]] || return 0          # no profile active -> nothing to revert
	[[ -d "$sd" ]] || return 0          # state dir gone -> nothing to revert
	[[ -f "${sd}/active-profile" ]] || return 0  # already reverted -> idempotent no-op
	echo "" >&2
	echo ">>> [trap] reverting active profile (state: ${sd}) to leave the mesh clean (#19)" >&2
	"${TUNING_DIR}/002-revert-profile.sh" \
		--state-dir "$sd" \
		--contexts "$CONTEXTS_CSV" \
		--rollout-timeout "$ROLLOUT_TIMEOUT" >&2 \
		|| echo "warn: [trap] revert of ${sd} failed; mesh may be left dirty — inspect the Istio CR manually (#19)" >&2
	ACTIVE_STATE_DIR=""
}

# shellcheck disable=SC2329
on_signal() {
	local sig="$1"
	echo "" >&2
	echo ">>> [trap] sweep interrupted by SIG${sig} — reverting active profile before exit (#19)" >&2
	# Explicitly exit (128+signo) so the EXIT trap fires and runs the revert exactly once.
	# A bare INT/TERM handler that just returned would NOT terminate the script under bash.
	case "$sig" in
	INT) exit 130 ;;
	TERM) exit 143 ;;
	*) exit 1 ;;
	esac
}

# INT/TERM log the interruption then exit, which fires the EXIT trap that does the revert,
# so the revert runs exactly once regardless of whether we exit normally, on error, or on
# a signal. DRY_RUN installs the traps too but exits before any apply (ACTIVE_STATE_DIR
# stays empty -> revert is a no-op), so dry-run never touches a cluster.
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap revert_active_profile EXIT

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Run the apply → probe → revert cycle for each tuning profile.

Options:
  --profiles CSV         Profile names to sweep (without .yaml extension).
                         Default: all supported profiles in profiles/.
  --suite SUITE          Test suite to run: controlplane, propagation,
                         dataplane, churn, churn-dataplane (required).
  --contexts CSV         Kube contexts (default: \$SETUP_CONTEXTS).
  --settle SEC           Seconds to wait after profile apply and after
                         revert before probing (default: $SETTLE_SEC).
  --output-dir DIR       Results base directory; sweep gets a sweep-<RUN_ID>/
                         subdir (default: tests/tuning/results).
  --no-baseline          Skip the initial baseline (no-profile) measurement.
  --rollout-timeout N    Seconds to wait for istiod rollout (default: $ROLLOUT_TIMEOUT).
  --dry-run              Print the plan and exit.
  -h, --help             Show this help.

Environment:
  SETUP_CONTEXTS, TUNING_SETTLE_SEC.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--profiles) PROFILES_CSV="$2"; shift 2 ;;
	--suite) SUITE="$2"; shift 2 ;;
	--contexts) CONTEXTS_CSV="$2"; shift 2 ;;
	--settle) SETTLE_SEC="$2"; shift 2 ;;
	--output-dir) OUTPUT_DIR_BASE="$2"; shift 2 ;;
	--no-baseline) INCLUDE_BASELINE=0; shift ;;
	--rollout-timeout) ROLLOUT_TIMEOUT="$2"; shift 2 ;;
	--dry-run) DRY_RUN=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) die "Unknown option: $1" ;;
	esac
done

[[ -n "$SUITE" ]] || die "--suite is required"

CONTEXTS_CSV="${CONTEXTS_CSV:-$SETUP_CONTEXTS}"
[[ -n "$CONTEXTS_CSV" ]] || die "No contexts (set --contexts or SETUP_CONTEXTS)"

SUITE_DIR="${ROOT}/tests/${SUITE}"
[[ -d "$SUITE_DIR" ]] || die "Suite directory not found: ${SUITE_DIR}"

resolve_probe_script() {
	local suite_dir="$1"
	local probe=""
	case "$(basename "$suite_dir")" in
	controlplane)
		probe="${suite_dir}/002-collect-resource-metrics.sh"
		;;
	propagation)
		probe="${suite_dir}/002-run-endpoint-probe.sh"
		;;
	dataplane)
		probe="${suite_dir}/002-run-latency-probe.sh"
		;;
	churn)
		probe="${suite_dir}/002-run-churn-probe.sh"
		;;
	churn-dataplane)
		probe="${suite_dir}/002-run-baseline-probe.sh"
		;;
	*)
		die "Unknown suite: $(basename "$suite_dir")"
		;;
	esac
	[[ -x "$probe" ]] || die "Probe script not found or not executable: $probe"
	echo "$probe"
}

PROBE_SCRIPT="$(resolve_probe_script "$SUITE_DIR")"

PROFILES=()
if [[ -n "$PROFILES_CSV" ]]; then
	split_csv "$PROFILES_CSV" PROFILES
else
	while IFS= read -r f; do
		name="$(basename "$f" .yaml)"
		support="$(yq -r '.ossm_support // "unknown"' "$f")"
		if [[ "$support" == "supported" || "$support" == "configurable" ]]; then
			PROFILES+=("$name")
		fi
	done < <(find "$PROFILES_DIR" -maxdepth 1 -name '*.yaml' -type f | sort)
fi

[[ ${#PROFILES[@]} -gt 0 ]] || die "No profiles to sweep"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SWEEP_DIR="${OUTPUT_DIR_BASE}/sweep-${RUN_ID}"

echo "=== Tuning Sweep ==="
echo "    RUN_ID:    ${RUN_ID}"
echo "    Suite:     ${SUITE}"
echo "    Probe:     $(basename "$PROBE_SCRIPT")"
echo "    Contexts:  ${CONTEXTS_CSV}"
echo "    Profiles:  ${PROFILES[*]}"
echo "    Baseline:  $( ((INCLUDE_BASELINE)) && echo "yes" || echo "no" )"
echo "    Settle:    ${SETTLE_SEC}s"
echo "    Output:    ${SWEEP_DIR}/"
echo ""

total=$((INCLUDE_BASELINE + ${#PROFILES[@]}))
echo "    Total measurement passes: ${total}"
echo ""

if ((DRY_RUN)); then
	echo "--- DRY RUN: Planned sweep ---"
	step=1
	if ((INCLUDE_BASELINE)); then
		echo "  ${step}. [baseline] — no profile applied"
		((step++))
	fi
	for p in "${PROFILES[@]}"; do
		pfile="${PROFILES_DIR}/${p}.yaml"
		if [[ -f "$pfile" ]]; then
			support="$(yq -r '.ossm_support // "unknown"' "$pfile")"
			desc="$(yq -r '.description // ""' "$pfile" | head -1)"
			echo "  ${step}. [${p}] (${support}) — ${desc}"
		else
			echo "  ${step}. [${p}] — PROFILE NOT FOUND: ${pfile}"
		fi
		((step++))
	done
	exit 0
fi

mkdir -p "$SWEEP_DIR"

{
	echo "# Tuning sweep — ${RUN_ID}"
	echo "# SUITE=${SUITE}"
	echo "# CONTEXTS=${CONTEXTS_CSV}"
	echo "# PROFILES=${PROFILES[*]}"
	echo "# SETTLE_SEC=${SETTLE_SEC}"
	echo "# BASELINE=${INCLUDE_BASELINE}"
} > "${SWEEP_DIR}/sweep-metadata.txt"

run_probe() {
	local label="$1"
	local result_dir="${SWEEP_DIR}/${label}"
	mkdir -p "$result_dir"

	echo ""
	echo ">>> Running probe for: ${label}"
	echo "    Settling for ${SETTLE_SEC}s..."
	sleep "$SETTLE_SEC"

	echo "    Executing: $(basename "$PROBE_SCRIPT") --contexts ${CONTEXTS_CSV}"
	# P0/P4: the probe is piped through tee, so the pipeline's `$?` is tee's (always 0)
	# and a probe failure was silently swallowed — recording nothing and continuing as
	# if the profile measured cleanly. `set -o pipefail` is on, but a bare failing
	# pipeline under `set -e` would instead ABORT the whole multi-profile sweep. So we
	# capture PIPESTATUS[0] (the probe's real exit) and treat non-zero as a failed
	# profile: warn, drop a PROBE_FAILED marker in the result dir for 004-compare to see,
	# and continue to the next profile. The probe owns its own per-suite TSV; on success
	# it is copied below, on failure no TSV is copied (the profile is visibly absent).
	"$PROBE_SCRIPT" --contexts "$CONTEXTS_CSV" \
		2>&1 | tee "${result_dir}/probe-output.log"
	local probe_rc="${PIPESTATUS[0]}"
	if (( probe_rc != 0 )); then
		echo "warn: probe for '${label}' exited ${probe_rc}; recording PROBE_FAILED and continuing to next profile" >&2
		echo "PROBE_FAILED rc=${probe_rc} $(date -u -Iseconds)" > "${result_dir}/PROBE_FAILED"
		return 0
	fi

	local suite_results="${SUITE_DIR}/results"
	if [[ -d "$suite_results" ]]; then
		local latest
		latest="$(find "$suite_results" -maxdepth 1 -name '*.tsv' -newer "${result_dir}" -type f 2>/dev/null | head -1)"
		if [[ -n "$latest" ]]; then
			cp "$latest" "${result_dir}/"
			echo "    Results copied to: ${result_dir}/$(basename "$latest")"
		fi
	fi
}

step=1

if ((INCLUDE_BASELINE)); then
	echo ""
	echo "=== [${step}/${total}] Baseline measurement (no profile) ==="
	run_probe "baseline"
	((step++))
fi

for p in "${PROFILES[@]}"; do
	pfile="${PROFILES_DIR}/${p}.yaml"
	[[ -f "$pfile" ]] || { echo "WARNING: profile not found: ${pfile} — skipping"; ((step++)); continue; }

	echo ""
	echo "=== [${step}/${total}] Profile: ${p} ==="

	state_dir="${SWEEP_DIR}/${p}/state"
	# Issue #19: mark this profile active BEFORE apply so the EXIT/INT/TERM trap can
	# revert it if the apply, probe, or revert is interrupted or aborts mid-way.
	ACTIVE_STATE_DIR="$state_dir"

	echo "--- Applying profile ---"
	# R3-1 (B1 class): apply is the most probable per-profile failure at scale (a
	# rollout-timeout when the tuned istiod won't go Ready). Bare under set -e it would
	# abort the whole multi-profile sweep, discarding every completed profile (004-compare
	# runs separately, post-sweep). On failure: warn, drop a SETUP_FAILED marker in the
	# profile result dir (same mechanism as run_probe's PROBE_FAILED — 004-compare skips
	# a marker-only dir, so the profile is visibly absent rather than silently aborting),
	# ATTEMPT a best-effort revert (so istiod returns to default for the next profile),
	# then continue. Reserve die for whole-run preconditions only.
	if ! "${TUNING_DIR}/001-apply-profile.sh" \
		--profile "$pfile" \
		--contexts "$CONTEXTS_CSV" \
		--state-dir "$state_dir" \
		--rollout-timeout "$ROLLOUT_TIMEOUT"; then
		echo "warn: [profile ${p}] apply failed; recording SETUP_FAILED and continuing to next profile" >&2
		mkdir -p "${SWEEP_DIR}/${p}"
		echo "SETUP_FAILED (001-apply-profile) $(date -u -Iseconds)" > "${SWEEP_DIR}/${p}/SETUP_FAILED"
		echo "--- Best-effort revert after apply failure ---"
		"${TUNING_DIR}/002-revert-profile.sh" \
			--state-dir "$state_dir" \
			--contexts "$CONTEXTS_CSV" \
			--rollout-timeout "$ROLLOUT_TIMEOUT" || \
			echo "warn: [profile ${p}] best-effort revert after apply failure also failed; istiod may be left in a non-default config (next profile re-applies)" >&2
		# Best-effort revert attempted (002 removes active-profile on success); clear the
		# trap's active-profile marker so EXIT does not double-revert (#19).
		ACTIVE_STATE_DIR=""
		((step++))
		continue
	fi

	run_probe "$p"

	echo "--- Reverting profile ---"
	# R3-1: a bare revert failure under set -e would abort the sweep AND leave istiod
	# stuck in this profile's non-default tuning. Warn and continue instead — the next
	# profile's apply overwrites the config anyway. Never abort.
	"${TUNING_DIR}/002-revert-profile.sh" \
		--state-dir "$state_dir" \
		--contexts "$CONTEXTS_CSV" \
		--rollout-timeout "$ROLLOUT_TIMEOUT" || \
		echo "warn: [profile ${p}] revert failed; istiod may be left in this profile's non-default config (next profile re-applies)" >&2
	# Revert attempted for this profile; clear the trap marker so a later interrupt
	# (e.g. during the settle/next profile) does not redundantly re-revert it (#19).
	ACTIVE_STATE_DIR=""

	echo "--- Post-revert settle: ${SETTLE_SEC}s ---"
	sleep "$SETTLE_SEC"

	((step++))
done

echo ""
echo "=== Sweep complete ==="
echo "    Results: ${SWEEP_DIR}/"
echo "    Compare: ./tests/tuning/004-compare-profiles.sh --results-dir ${SWEEP_DIR}"

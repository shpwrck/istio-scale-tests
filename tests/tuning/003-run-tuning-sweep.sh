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
#     --contexts rosa-001,rosa-002,rosa-003 \
#     --profiles 01-sidecar-scoping,03-push-throttling \
#     --suite controlplane
#
#   # Sweep all supported profiles against propagation:
#   ./tests/tuning/003-run-tuning-sweep.sh \
#     --contexts rosa-001,rosa-002,rosa-003 \
#     --suite propagation
#
#   # Dry-run to see the plan:
#   ./tests/tuning/003-run-tuning-sweep.sh --dry-run \
#     --profiles 01-sidecar-scoping,06-xds-cache-tuning --suite controlplane
# ci-dry-run-skip: needs yq and valid --suite directory with profiles
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

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

die() { echo "error: $*" >&2; exit 1; }

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

split_csv() {
	local csv="$1"
	local -n _out="$2"
	_out=()
	local x
	IFS=',' read -ra _raw <<<"$csv"
	for x in "${_raw[@]}"; do
		x="${x#"${x%%[![:space:]]*}"}"
		x="${x%"${x##*[![:space:]]}"}"
		[[ -n "$x" ]] && _out+=("$x")
	done
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
	"$PROBE_SCRIPT" --contexts "$CONTEXTS_CSV" \
		2>&1 | tee "${result_dir}/probe-output.log"

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

	echo "--- Applying profile ---"
	"${TUNING_DIR}/001-apply-profile.sh" \
		--profile "$pfile" \
		--contexts "$CONTEXTS_CSV" \
		--state-dir "$state_dir" \
		--rollout-timeout "$ROLLOUT_TIMEOUT"

	run_probe "$p"

	echo "--- Reverting profile ---"
	"${TUNING_DIR}/002-revert-profile.sh" \
		--state-dir "$state_dir" \
		--contexts "$CONTEXTS_CSV" \
		--rollout-timeout "$ROLLOUT_TIMEOUT"

	echo "--- Post-revert settle: ${SETTLE_SEC}s ---"
	sleep "$SETTLE_SEC"

	((step++))
done

echo ""
echo "=== Sweep complete ==="
echo "    Results: ${SWEEP_DIR}/"
echo "    Compare: ./tests/tuning/004-compare-profiles.sh --results-dir ${SWEEP_DIR}"

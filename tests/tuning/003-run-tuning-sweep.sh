#!/usr/bin/env bash
# Sweep tuning profiles against one test suite. Pauses Argo CD auto-sync of the
# Istio CR Applications, runs the suite's setup once, then measures the baseline and
# each profile (apply -> settle -> probe -> revert), writes sweep-comparison.md,
# runs the suite's cleanup and resumes Argo CD. It refuses to start while a member
# holds a tuning profile's objects or marker (a profile left applied). Each pass reads
# its own platform record before its probes and again after them, so a profile undone
# or istiod's settings put back during the pass show in its comparison.
#
# Usage:
#   ./tests/tuning/003-run-tuning-sweep.sh --suite SUITE --gitops-context CTX [options]
# ci-dry-run: --suite churn-dataplane --contexts ci-dummy,ci-dummy2 --gitops-context ci-hub
set -euo pipefail
# shellcheck disable=SC2154  # rc is assigned at the head of the trap body
trap 'rc=$?; echo "FATAL: ${0##*/} aborted (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # _config_sha256 (platform_probe: the istiod env digest)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/reach.sh"  # reach_sanitize (platform_probe: masked addresses)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/capacity.sh"  # cap_istiod_limits (platform_drift_check: istiod's limits)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/platform.sh"  # platform_validate (TEST_PLATFORM), platform_tuning_objects_refuse, each pass's record
# shellcheck disable=SC1091
source "${ROOT}/tests/tuning/lib/tuning.sh"  # ctx_keys_distinct

TUNING_DIR="${ROOT}/tests/tuning"
SUITE=""
CONTEXTS_CSV=""
GITOPS_CTX="${TUNING_GITOPS_CONTEXT:-}"
GITOPS_PAUSE=1
PROFILES_CSV=""
INCLUDE_BASELINE=1
RUN_SETUP=1
RUN_CLEANUP=1
SETTLE_SEC="${TUNING_SETTLE_SEC:-60}"
CHURN_RATE="${TUNING_COEXEC_CHURN_RATE:-5}"
OUTPUT_BASE="${TUNING_DIR}/results"
ROLLOUT_TIMEOUT="${TUNING_ROLLOUT_TIMEOUT:-300}"
DRY_RUN=0

usage() {
	cat <<EOF
Usage: $(basename "$0") --suite SUITE --gitops-context CTX [options]

For the baseline and each profile: apply, wait --settle seconds, run the suite's
probe, revert. Writes sweep-comparison.md into the sweep directory. Refuses to start
while a profile is left applied: its state under the results directory, or its objects
or marker on a member (./tests/tuning/005-cleanup.sh undoes both).

Options:
  --suite SUITE          propagation | controlplane | dataplane | churn |
                         churn-dataplane (required).
  --contexts CSV         Mesh member contexts; the first is the source for suites
                         that take one (default: \$SETUP_CONTEXTS).
  --gitops-context CTX   Hub context running Argo CD, where its auto-sync is paused
                         for the run (default: \$TUNING_GITOPS_CONTEXT).
  --no-gitops-pause      Do not pause Argo CD (mesh not managed by GitOps).
  --profiles CSV         Profile names (default: every profile in profiles/).
  --no-baseline          Skip the no-profile pass.
  --skip-setup           Do not run the suite's setup (workloads already deployed).
  --keep-workloads       Do not run the suite's cleanup at the end.
  --settle SEC           Wait after each apply before probing (default: ${SETTLE_SEC}).
  --churn-rate N         churn-dataplane only: churn operations/s (default: ${CHURN_RATE}).
  --output-dir DIR       Results base; the run writes sweep-<RUN_ID>/ there
                         (default: tests/tuning/results).
  --rollout-timeout N    Seconds to wait for istiod after apply/revert
                         (default: ${ROLLOUT_TIMEOUT}, from \$TUNING_ROLLOUT_TIMEOUT).
  --dry-run              Print the plan, check the probe arguments with each probe's
                         own --dry-run, and exit. Touches no cluster.
  -h, --help             Show this help.

Environment:
  SETUP_CONTEXTS, TUNING_GITOPS_CONTEXT, TUNING_SETTLE_SEC, TUNING_COEXEC_CHURN_RATE,
  TUNING_ROLLOUT_TIMEOUT.
  006-gitops-pause.sh, which pauses Argo CD, reads TUNING_GITOPS_NAMESPACE (the Argo CD
  namespace; empty: from the hub's platform, openshift-gitops on OpenShift, else argocd) and
  TUNING_GITOPS_APPSET (the ApplicationSet of the Istio CR Applications, ${TUNING_GITOPS_APPSET}).
  TEST_PLATFORM (config/options.env; auto, kubernetes or openshift; now ${TEST_PLATFORM:-auto}):
  kubernetes or openshift is taken as the platform instead of asking each cluster, for the probe
  suite's chart overlay and, with TUNING_GITOPS_NAMESPACE empty, for the hub whose Argo CD
  namespace 006 pauses in (TUNING_GITOPS_NAMESPACE overrides that). The platform record of each
  pass still asks every member what it serves.
$(platform_help_lines reads)
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--suite | --contexts | --gitops-context | --profiles | --settle | --churn-rate | --output-dir | --rollout-timeout)
		[[ -n "${2:-}" ]] || die "$1 requires a value"
		case "$1" in
		--suite) SUITE="$2" ;;
		--contexts) CONTEXTS_CSV="$2" ;;
		--gitops-context) GITOPS_CTX="$2" ;;
		--profiles) PROFILES_CSV="$2" ;;
		--settle) SETTLE_SEC="$2" ;;
		--churn-rate) CHURN_RATE="$2" ;;
		--output-dir) OUTPUT_BASE="$2" ;;
		--rollout-timeout) ROLLOUT_TIMEOUT="$2" ;;
		esac
		shift 2
		;;
	--no-gitops-pause) GITOPS_PAUSE=0; shift ;;
	--no-baseline) INCLUDE_BASELINE=0; shift ;;
	--skip-setup) RUN_SETUP=0; shift ;;
	--keep-workloads) RUN_CLEANUP=0; shift ;;
	--dry-run) DRY_RUN=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) die "unknown option: $1 (try --help)" ;;
	esac
done

platform_validate
case "$SUITE" in
propagation | controlplane | dataplane | churn | churn-dataplane) ;;
"") die "--suite is required (propagation, controlplane, dataplane, churn, churn-dataplane)" ;;
*) die "unknown suite: $SUITE (propagation, controlplane, dataplane, churn, churn-dataplane)" ;;
esac
SUITE_DIR="${ROOT}/tests/${SUITE}"
is_nonneg_int "$SETTLE_SEC" || die "--settle (or TUNING_SETTLE_SEC) must be a non-negative integer; got '${SETTLE_SEC}'"
is_pos_int "$CHURN_RATE" || die "--churn-rate (or TUNING_COEXEC_CHURN_RATE) must be a positive integer; got '${CHURN_RATE}'"
is_pos_int "$ROLLOUT_TIMEOUT" || die "--rollout-timeout (or TUNING_ROLLOUT_TIMEOUT) must be a positive integer; got '${ROLLOUT_TIMEOUT}'"
if ((GITOPS_PAUSE)) && [[ -z "$GITOPS_CTX" ]]; then
	die "--gitops-context is required: the hub context whose Argo CD manages the Istio CRs (or pass --no-gitops-pause)"
fi

CONTEXTS=()
split_csv "${CONTEXTS_CSV:-${SETUP_CONTEXTS:-}}" CONTEXTS
((${#CONTEXTS[@]})) || die "no contexts (set --contexts or SETUP_CONTEXTS)"
# What 001-apply-profile.sh refuses for every profile pass, refused before the setup and the
# baseline pass run.
ctx_keys_distinct "${CONTEXTS[@]}"
CONTEXTS_CSV="$(IFS=,; echo "${CONTEXTS[*]}")"
SOURCE_CTX="${CONTEXTS[0]}"
REMOTE_CSV="$(IFS=,; echo "${CONTEXTS[*]:1}")"

PROFILES=()
if [[ -n "$PROFILES_CSV" ]]; then
	split_csv "$PROFILES_CSV" PROFILES
else
	for f in "${TUNING_DIR}"/profiles/*.yaml; do
		[[ -f "$f" ]] && PROFILES+=("$(basename "$f" .yaml)")
	done
fi
((${#PROFILES[@]})) || die "no profiles to sweep"
command -v python3 >/dev/null ||
	die "python3 is required (and PyYAML for a run): tests/tuning/lib/tuning.py checks each profile's name and applies it"
declare -A LISTED=()
for i in "${!PROFILES[@]}"; do
	PROFILES[i]="${PROFILES[i]%.yaml}"
	[[ -f "${TUNING_DIR}/profiles/${PROFILES[i]}.yaml" ]] || die "profile not found: ${PROFILES[i]} (see tests/tuning/profiles/)"
	# Each pass has its own directory: a name listed twice, or baseline (the pass without a
	# profile), would share one. tuning.py's rule, which 001 applies too.
	[[ -z "${LISTED[${PROFILES[i]}]+x}" ]] || die "profile ${PROFILES[i]} is listed twice in --profiles"
	LISTED[${PROFILES[i]}]=1
	python3 -I "${TUNING_DIR}/lib/tuning.py" check-name "${PROFILES[i]}" || exit 1
done
PASSES=()
((INCLUDE_BASELINE)) && PASSES+=(baseline)
PASSES+=("${PROFILES[@]}")

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SWEEP_DIR="${OUTPUT_BASE}/sweep-${RUN_ID}"
PAUSE_STATE="${SWEEP_DIR}/gitops-pause.json"
TUNING_BASELINE="unknown"
SIDECAR_EGRESS_HOSTS="unknown"

# --- Per-suite commands -------------------------------------------------------
remote_args=()
[[ -n "$REMOTE_CSV" ]] && remote_args=(--remote-contexts "$REMOTE_CSV")
case "$SUITE" in
propagation)
	SETUP_CMD=("${SUITE_DIR}/001-setup-propagation-test.sh" --contexts "$CONTEXTS_CSV")
	CLEANUP_CMD=("${SUITE_DIR}/007-cleanup.sh" --contexts "$CONTEXTS_CSV") ;;
controlplane)
	SETUP_CMD=("${SUITE_DIR}/001-setup-controlplane-test.sh" --contexts "$CONTEXTS_CSV")
	CLEANUP_CMD=("${SUITE_DIR}/005-cleanup.sh" --contexts "$CONTEXTS_CSV") ;;
dataplane)
	SETUP_CMD=("${SUITE_DIR}/001-setup-dataplane-test.sh" --source-context "$SOURCE_CTX" "${remote_args[@]}")
	CLEANUP_CMD=("${SUITE_DIR}/005-cleanup.sh" --contexts "$CONTEXTS_CSV") ;;
churn)
	SETUP_CMD=("${SUITE_DIR}/001-setup-churn-test.sh" --contexts "$CONTEXTS_CSV")
	CLEANUP_CMD=("${SUITE_DIR}/005-cleanup.sh" --contexts "$CONTEXTS_CSV") ;;
churn-dataplane)
	SETUP_CMD=("${SUITE_DIR}/001-setup-coexec-test.sh" --source-context "$SOURCE_CTX" "${remote_args[@]}")
	CLEANUP_CMD=("${SUITE_DIR}/006-cleanup.sh" --contexts "$CONTEXTS_CSV" --wait-deletion) ;;
esac

# Set PROBE_ARGV to the suite's n-th probe command for one pass (1-based);
# return 1 when the suite has no n-th probe.
probe_argv() {
	local n="$1" label="$2" dir="$3"
	local tb=(--tuning-baseline "$TUNING_BASELINE" --sidecar-egress-hosts "$SIDECAR_EGRESS_HOSTS")
	local src=(--source-context "$SOURCE_CTX" "${remote_args[@]}")
	local cd_file="${dir}/churn-dataplane-${label}.tsv"
	case "${SUITE}:${n}" in
	propagation:1) PROBE_ARGV=("${SUITE_DIR}/002-run-endpoint-probe.sh" "${src[@]}" --tsv --output-dir "$dir" "${tb[@]}") ;;
	controlplane:1) PROBE_ARGV=("${SUITE_DIR}/002-collect-resource-metrics.sh" --contexts "$CONTEXTS_CSV" --output-dir "$dir") ;;
	dataplane:1) PROBE_ARGV=("${SUITE_DIR}/002-run-latency-probe.sh" "${src[@]}" --output-dir "$dir" "${tb[@]}") ;;
	churn:1) PROBE_ARGV=("${SUITE_DIR}/002-run-churn-probe.sh" "${src[@]}" --output-dir "$dir" "${tb[@]}") ;;
	churn-dataplane:1) PROBE_ARGV=("${SUITE_DIR}/002-run-baseline-probe.sh" "${src[@]}" --combo-id "$label"
		--run-id "$RUN_ID" --output-file "$cd_file" "${tb[@]}") ;;
	churn-dataplane:2) PROBE_ARGV=("${SUITE_DIR}/003-run-churn-probe.sh" "${src[@]}" --combo-id "$label"
		--run-id "$RUN_ID" --churn-rate "$CHURN_RATE" --output-file "$cd_file" --baseline-file "$cd_file" "${tb[@]}") ;;
	*) return 1 ;;
	esac
}

# Print a command with repo paths shortened.
show() { local a=("${@//"${ROOT}"\//}"); echo "${a[*]}"; }

echo "=== Tuning sweep ${RUN_ID} ==="
echo "    Suite:     ${SUITE}"
echo "    Contexts:  ${CONTEXTS_CSV} (source ${SOURCE_CTX})"
echo "    Passes:    ${PASSES[*]}"
echo "    Settle:    ${SETTLE_SEC}s"
echo "    Argo CD:   $( ((GITOPS_PAUSE)) && echo "pause on ${GITOPS_CTX}" || echo "not paused")"
echo "    Output:    ${SWEEP_DIR}/"

# A profile left applied by an interrupted run would contaminate every pass.
# Checked before --dry-run exits, so CI (no results dir yet) runs this path too.
for base in "${TUNING_DIR}/results" "$OUTPUT_BASE"; do
	[[ -d "$base" ]] || continue
	leftover="$(find "$base" -name active-profile -type f 2>/dev/null | head -1)"
	[[ -n "$leftover" ]] || continue
	hint="./tests/tuning/005-cleanup.sh --contexts ${CONTEXTS_CSV}"
	[[ "$base" == "${TUNING_DIR}/results" ]] || hint+=" --results-dir ${base}"
	die "profile $(<"$leftover") is still applied (${leftover%/active-profile}); run ${hint} first"
done

if ((DRY_RUN)); then
	echo ""
	echo "--- Plan ---"
	echo "# check that no member holds a tuning profile's objects or marker (label ${PLATFORM_TUNING_LABEL}); stop if one does"
	if ((GITOPS_PAUSE)); then
		show "${TUNING_DIR}/006-gitops-pause.sh" --gitops-context "$GITOPS_CTX" --pause --state-file "$PAUSE_STATE"
	fi
	if ((RUN_SETUP)); then show "${SETUP_CMD[@]}"; fi
	for p in "${PASSES[@]}"; do
		echo "# pass ${p}"
		if [[ "$p" != baseline ]]; then
			show "${TUNING_DIR}/001-apply-profile.sh" --profile "$p" --contexts "$CONTEXTS_CSV" \
				--state-dir "${SWEEP_DIR}/${p}/state" --rollout-timeout "$ROLLOUT_TIMEOUT"
		fi
		if [[ "$SUITE" == churn-dataplane ]]; then
			echo "kubectl scale deployment -l churn-target=true --replicas=${CHURN_BASE_REPLICAS:-1}  # each context"
		fi
		echo "sleep ${SETTLE_SEC}"
		show "# read the platform record of every member into ${SWEEP_DIR}/${p}/platform-record.txt, and the tuning levers on ${SOURCE_CTX}"
		n=1
		while probe_argv "$n" "$p" "${SWEEP_DIR}/${p}"; do show "${PROBE_ARGV[@]}"; n=$((n + 1)); done
		show "# read it again; what changed during the pass, and what it could not compare, goes to ${SWEEP_DIR}/${p}/platform-drift.txt"
		if [[ "$p" != baseline ]]; then
			show "${TUNING_DIR}/002-revert-profile.sh" --state-dir "${SWEEP_DIR}/${p}/state" \
				--rollout-timeout "$ROLLOUT_TIMEOUT"
		fi
	done
	show "${TUNING_DIR}/004-compare-profiles.sh" --results-dir "$SWEEP_DIR" --format markdown --output "${SWEEP_DIR}/sweep-comparison.md"
	if ((RUN_CLEANUP)); then show "${CLEANUP_CMD[@]}"; fi
	if ((GITOPS_PAUSE)); then
		show "${TUNING_DIR}/006-gitops-pause.sh" --resume --state-file "$PAUSE_STATE"
	fi
	echo ""
	echo "--- Checking probe arguments (each probe's --dry-run) ---"
	check_dir="$(mktemp -d)"
	n=1
	while probe_argv "$n" baseline "$check_dir"; do
		if ! "${PROBE_ARGV[@]}" --dry-run >"${check_dir}/check.log" 2>&1; then
			cat "${check_dir}/check.log" >&2
			rm -rf "$check_dir"
			die "probe rejected its arguments: $(show "${PROBE_ARGV[@]}")"
		fi
		echo "  ok: $(basename "${PROBE_ARGV[0]}")"
		n=$((n + 1))
	done
	rm -rf "$check_dir"
	echo "=== Dry run complete ==="
	exit 0
fi

# --- Live run -------------------------------------------------------------------
python3 -I -c 'import yaml' 2>/dev/null \
	|| die "python3 with PyYAML is required (dnf install python3-pyyaml, apt install python3-yaml, or pip install pyyaml)"
KUBECTL=()
resolve_kubectl KUBECTL
# A profile left applied by a run whose state is not under the results dirs above (another
# checkout, a deleted dir), or objects applied by hand, would contaminate every pass too.
platform_tuning_objects_refuse "$CONTEXTS_CSV" "every pass of this sweep (the baseline included)"

ACTIVE_STATE_DIR=""
GITOPS_PAUSED=0

# EXIT trap: revert a profile left applied, then resume Argo CD. Never aborts.
on_exit() {
	local sd="$ACTIVE_STATE_DIR"
	if [[ -n "$sd" && -f "${sd}/active-profile" ]]; then
		echo ">>> reverting $(<"${sd}/active-profile") before exit" >&2
		"${TUNING_DIR}/002-revert-profile.sh" --state-dir "$sd" --rollout-timeout "$ROLLOUT_TIMEOUT" >&2 \
			|| echo "warn: revert failed; re-run: ./tests/tuning/002-revert-profile.sh --state-dir ${sd}" >&2
	fi
	if ((GITOPS_PAUSED)); then
		"${TUNING_DIR}/006-gitops-pause.sh" --resume --state-file "$PAUSE_STATE" >&2 \
			|| echo "warn: Argo CD still paused; run: ./tests/tuning/006-gitops-pause.sh --resume --state-file ${PAUSE_STATE}" >&2
	fi
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$SWEEP_DIR"
{
	echo "# SUITE=${SUITE}"
	echo "# RUN_ID=${RUN_ID}"
	echo "# CONTEXTS=${CONTEXTS_CSV}"
	echo "# PASSES=$(IFS=,; echo "${PASSES[*]}")"
	echo "# SETTLE_SEC=${SETTLE_SEC}"
	if [[ "$SUITE" == churn-dataplane ]]; then echo "# CHURN_RATE=${CHURN_RATE}"; fi
	echo "# HARNESS_SHA=$(harness_sha)"
} >"${SWEEP_DIR}/sweep-metadata.txt"

if ((GITOPS_PAUSE)); then
	# Set first: a partial pause is still undone by the EXIT trap.
	GITOPS_PAUSED=1
	"${TUNING_DIR}/006-gitops-pause.sh" --gitops-context "$GITOPS_CTX" --pause --state-file "$PAUSE_STATE" \
		|| die "could not pause Argo CD auto-sync"
fi

if ((RUN_SETUP)); then
	echo "--- Suite setup ---"
	"${SETUP_CMD[@]}" || die "suite setup failed"
fi

# Run one pass's probe(s) into its result directory.
run_pass() {
	local label="$1" dir="${SWEEP_DIR}/$1" n=1 rc
	mkdir -p "$dir"
	if [[ "$SUITE" == churn-dataplane ]]; then
		# A churn phase leaves churn-target replicas mixed; start each pass from base.
		for ctx in "${CONTEXTS[@]}"; do
			"${KUBECTL[@]}" --context="$ctx" -n "${COEXEC_TEST_NAMESPACE:-churn-dataplane-test}" scale deployment \
				-l churn-target=true --replicas="${CHURN_BASE_REPLICAS:-1}" >/dev/null \
				|| echo "warn: ${ctx}: churn-target reset failed" >&2
		done
	fi
	echo "--- Settle ${SETTLE_SEC}s ---"
	sleep "$SETTLE_SEC"
	# This pass's own platform record (a profile changes istiod's env and its objects), read once
	# for its probes, which reuse it (platform-record.txt in the pass dir), and its tuning levers,
	# which its TSVs record; both read again after the probes: a profile undone, istiod's
	# settings put back, a lever, an istiod limit or a Kubernetes version changed during the pass
	# go to its platform-drift.txt, which 004 reads for the pass.
	platform_probe_reset
	platform_probe "$CONTEXTS_CSV"
	platform_probe_share "$dir"
	while IFS= read -r kv; do
		case "$kv" in
		TUNING_BASELINE=*) TUNING_BASELINE="${kv#*=}" ;;
		SIDECAR_EGRESS_HOSTS=*) SIDECAR_EGRESS_HOSTS="${kv#*=}" ;;
		esac
	done < <(tuning_baseline_state "$SOURCE_CTX" "${KUBECTL[@]}")
	while probe_argv "$n" "$label" "$dir"; do
		echo "--- Probe: $(show "${PROBE_ARGV[@]}")"
		rc=0
		"${PROBE_ARGV[@]}" 2>&1 | tee -a "${dir}/probe-output.log" || rc=${PIPESTATUS[0]}
		if ((rc != 0)); then
			echo "warn: probe for ${label} exited ${rc}; marking PROBE_FAILED" >&2
			echo "PROBE_FAILED rc=${rc} $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${dir}/PROBE_FAILED"
			break
		fi
		n=$((n + 1))
	done
	platform_drift_check "$dir" "$CONTEXTS_CSV" pass
}

ABORTED=0
step=0
for p in "${PASSES[@]}"; do
	step=$((step + 1))
	echo ""
	echo "=== [${step}/${#PASSES[@]}] ${p} ==="
	if [[ "$p" == baseline ]]; then
		run_pass baseline
		continue
	fi
	state_dir="${SWEEP_DIR}/${p}/state"
	ACTIVE_STATE_DIR="$state_dir"
	if ! "${TUNING_DIR}/001-apply-profile.sh" --profile "$p" --contexts "$CONTEXTS_CSV" \
		--state-dir "$state_dir" --rollout-timeout "$ROLLOUT_TIMEOUT"; then
		echo "warn: applying ${p} failed; marking SETUP_FAILED" >&2
		echo "SETUP_FAILED $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${SWEEP_DIR}/${p}/SETUP_FAILED"
	else
		run_pass "$p"
	fi
	if [[ -f "${state_dir}/active-profile" ]]; then
		if ! "${TUNING_DIR}/002-revert-profile.sh" --state-dir "$state_dir" --rollout-timeout "$ROLLOUT_TIMEOUT"; then
			echo "REVERT_FAILED $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${SWEEP_DIR}/${p}/REVERT_FAILED"
			echo "error: reverting ${p} failed; stopping the sweep so later passes are not contaminated" >&2
			ABORTED=1
			break
		fi
	fi
	ACTIVE_STATE_DIR=""
done

echo ""
"${TUNING_DIR}/004-compare-profiles.sh" --results-dir "$SWEEP_DIR" --format markdown \
	--output "${SWEEP_DIR}/sweep-comparison.md" || echo "warn: comparison failed" >&2

if ((RUN_CLEANUP)); then
	echo "--- Suite cleanup ---"
	"${CLEANUP_CMD[@]}" || echo "warn: suite cleanup failed; re-run: $(show "${CLEANUP_CMD[@]}")" >&2
fi

echo "=== Sweep ${RUN_ID} $( ((ABORTED)) && echo "STOPPED (revert failed)" || echo "complete") ==="
echo "    Results:    ${SWEEP_DIR}/"
echo "    Comparison: ${SWEEP_DIR}/sweep-comparison.md"
if ((ABORTED)); then exit 1; fi

#!/usr/bin/env bash
# Sweep tuning profiles against one test suite. Pauses Argo CD auto-sync of the
# Istio CR Applications, runs the suite's setup once, then measures the baseline and
# each profile (apply -> settle -> probe -> revert), writes sweep-comparison.md,
# runs the suite's cleanup and resumes Argo CD. It refuses to start while a member
# holds a tuning profile's objects or marker (a profile left applied). Each pass reads
# its own platform record before its probes and again after them: a build or istiod
# setting that changed during the pass is a problem of the sweep's outcome.
#
# Usage:
#   ./tests/tuning/003-run-tuning-sweep.sh --suite SUITE --gitops-context CTX [options]
# ci-dry-run: --suite churn-dataplane --contexts ci-dummy,ci-dummy2 --gitops-context ci-hub
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# Loud ERR trap for unexpected aborts.
# sweep_err_trap prints the FATAL line and keeps it as the stop reason a sweep that
# aborts after its start records (the EXIT trap sweep_start sets).
trap 'sweep_err_trap "$?" "$LINENO" "$BASH_COMMAND"' ERR
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/reach.sh"  # reach_sanitize (platform_probe: masked addresses)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/platform.sh"  # platform_validate (TEST_PLATFORM), platform_tuning_objects_refuse, each pass's record
# shellcheck disable=SC1091
source "${ROOT}/tests/tuning/lib/tuning.sh"  # ctx_key, ctx_keys_distinct

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

For the baseline and each profile: apply, wait --settle seconds, run the suite's probe,
revert; then writes sweep-comparison.md (004). Refuses to start while a profile is left
applied (./tests/tuning/005-cleanup.sh undoes it).

Options:
  --suite SUITE          propagation | controlplane | dataplane | churn |
                         churn-dataplane (required).
  --contexts CSV         Mesh member contexts; the first is the source for suites
                         that take one (default: \$SETUP_CONTEXTS).
  --gitops-context CTX   Hub context running Argo CD, where its auto-sync is paused
                         for the run (default: \$TUNING_GITOPS_CONTEXT).
  --no-gitops-pause      Do not pause Argo CD (mesh not managed by GitOps).
  --profiles CSV         Profile names, each once (default: every profile in profiles/).
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

Environment (config/options.env describes each): SETUP_CONTEXTS, TUNING_GITOPS_CONTEXT,
TUNING_SETTLE_SEC, TUNING_COEXEC_CHURN_RATE, TUNING_ROLLOUT_TIMEOUT, TUNING_GITOPS_NAMESPACE,
TUNING_GITOPS_APPSET (${TUNING_GITOPS_APPSET}), the probe suite's keys, TEST_PLATFORM (${TEST_PLATFORM:-auto}),
PLATFORM_READ_TIMEOUT (${PLATFORM_READ_TIMEOUT}), PLATFORM_READ_PARALLEL (${PLATFORM_READ_PARALLEL}), ISTIO_VERSION_CHECK,
ISTIO_VERSION_READY_WAIT_SEC, SWEEP_STOP_GRACE_SEC. Requires python3 with PyYAML.

Exit codes: 0 every pass ran its probe; 1 stopped (a bad flag or precondition, a failed setup,
REVERT_FAILED, an error); 4 failed passes or a problem (sweep-outcome.txt); 129, 130, 143 a
signal (the active profile is reverted and Argo CD resumed first).

See tests/tuning/README.md.
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
sweep_settings_check
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
split_contexts "${CONTEXTS_CSV:-${SETUP_CONTEXTS:-}}" CONTEXTS "--contexts (or SETUP_CONTEXTS)"
((${#CONTEXTS[@]})) || die "no contexts (set --contexts or SETUP_CONTEXTS)"
# What 001-apply-profile.sh refuses for every profile pass, refused before the setup and the
# baseline pass run.
ctx_keys_distinct "${CONTEXTS[@]}"
# Each member under a name of its own in the platform record (platform_members_check): refused
# here, before any cluster call, in a --dry-run too.
platform_members_check "${CONTEXTS[@]}"
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
	[[ -z "${LISTED[${PROFILES[i]}]+x}" ]] \
		|| die "profile listed twice in --profiles: ${PROFILES[i]} (each pass writes to a directory named after its profile): list each once"
	LISTED[${PROFILES[i]}]=1
	python3 -I "${TUNING_DIR}/lib/tuning.py" check-name "${PROFILES[i]}" || exit 1
done
PASSES=()
((INCLUDE_BASELINE)) && PASSES+=(baseline)
PASSES+=("${PROFILES[@]}")

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SWEEP_DIR="${OUTPUT_BASE}/sweep-${RUN_ID}"
# The harness at the sweep's start (sweep-metadata.txt, sweep-outcome.txt); its results
# under the output dir do not count, for its steps either (HARNESS_SHA_EXCLUDE).
# sweep_finish reads it again: a harness that changed during the sweep is a problem.
HARNESS_SHA_EXCLUDE="$OUTPUT_BASE"
[[ "$HARNESS_SHA_EXCLUDE" == /* ]] || HARNESS_SHA_EXCLUDE="${PWD%/}/${HARNESS_SHA_EXCLUDE}"
export HARNESS_SHA_EXCLUDE
HARNESS_SHA="$(harness_sha)"
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
	SETUP_CMD=("${SUITE_DIR}/001-setup-dataplane-test.sh" --source-context "$SOURCE_CTX" ${remote_args[@]+"${remote_args[@]}"})
	CLEANUP_CMD=("${SUITE_DIR}/005-cleanup.sh" --contexts "$CONTEXTS_CSV") ;;
churn)
	SETUP_CMD=("${SUITE_DIR}/001-setup-churn-test.sh" --contexts "$CONTEXTS_CSV")
	CLEANUP_CMD=("${SUITE_DIR}/005-cleanup.sh" --contexts "$CONTEXTS_CSV") ;;
churn-dataplane)
	SETUP_CMD=("${SUITE_DIR}/001-setup-coexec-test.sh" --source-context "$SOURCE_CTX" ${remote_args[@]+"${remote_args[@]}"})
	CLEANUP_CMD=("${SUITE_DIR}/006-cleanup.sh" --contexts "$CONTEXTS_CSV" --wait-deletion) ;;
esac

# Set PROBE_ARGV to the suite's n-th probe command for one pass (1-based);
# return 1 when the suite has no n-th probe.
probe_argv() {
	local n="$1" label="$2" dir="$3"
	local tb=(--tuning-baseline "$TUNING_BASELINE" --sidecar-egress-hosts "$SIDECAR_EGRESS_HOSTS")
	local src=(--source-context "$SOURCE_CTX" ${remote_args[@]+"${remote_args[@]}"})
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
_argo_line="not paused"
if ((GITOPS_PAUSE)); then _argo_line="pause on ${GITOPS_CTX}"; fi
echo "    Argo CD:   ${_argo_line}"
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
		[[ "$p" != baseline ]] || echo "# read the Istio CR generations of every member"
		n=1
		while probe_argv "$n" "$p" "${SWEEP_DIR}/${p}"; do show "${PROBE_ARGV[@]}"; n=$((n + 1)); done
		show "# read the platform record again: a value that changed during the pass is a problem of the outcome"
		[[ "$p" != baseline ]] || echo "# read the generations again: a move during the pass is a problem of the outcome"
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
	trap 'rm -rf "$check_dir" || true' EXIT
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
# The controlplane probe bounds its config-dump and Envoy-stats reads with timeout or
# gtimeout and stops without either: check here, before any profile is applied.
[[ "$SUITE" != controlplane ]] || require_timeout
KUBECTL=()
resolve_kubectl KUBECTL
# A profile left applied by a run whose state is not under the results dirs above (another
# checkout, a deleted dir), or objects applied by hand, would contaminate every pass too.
platform_tuning_objects_refuse "$CONTEXTS_CSV" "every pass of this sweep (the baseline included)"
# The Istio version every member runs, read once before the first profile or setup
# and exported, so every probe of every pass records it (ISTIO_VERSION_CHECK=fail stops
# here on a mismatch, before anything changes).
istio_version_resolve "$CONTEXTS_CSV" 0 "${KUBECTL[@]}"
echo "    Istio:     $(istio_version_label)"

ACTIVE_STATE_DIR=""
GITOPS_PAUSED=0

# tuning_cleanup: revert a profile left applied (a failed revert, or one the sweep did not
# reach: PL32), then resume Argo CD auto-sync when the sweep paused it; each that fails is a
# note of the outcome (the console names the command). The sweep runs it at its end, and the
# EXIT trap when the sweep ends before (die, an unexpected abort, Ctrl-C), after it recorded
# how (tests/lib/common.sh, sweep_start).
tuning_cleanup() {
	local sd="$ACTIVE_STATE_DIR" prof
	if [[ -n "$sd" && -f "${sd}/active-profile" ]]; then
		prof="$(<"${sd}/active-profile")"
		echo ">>> reverting ${prof} before exit" >&2
		if ! "${TUNING_DIR}/002-revert-profile.sh" --state-dir "$sd" --rollout-timeout "$ROLLOUT_TIMEOUT" >&2; then
			echo "warn: revert failed; re-run: ./tests/tuning/002-revert-profile.sh --state-dir ${sd}" >&2
			sweep_note "REVERT_FAILED: profile ${prof} is still applied (its revert on exit failed): run 002-revert-profile.sh --state-dir on its pass dir's state before any other run"
		fi
	fi
	ACTIVE_STATE_DIR=""
	if ((GITOPS_PAUSED)); then
		GITOPS_PAUSED=0
		if ! "${TUNING_DIR}/006-gitops-pause.sh" --resume --state-file "$PAUSE_STATE" >&2; then
			echo "warn: Argo CD still paused; run: ./tests/tuning/006-gitops-pause.sh --resume --state-file ${PAUSE_STATE}" >&2
			sweep_note "Argo CD auto-sync is still paused (its resume on exit failed): run 006-gitops-pause.sh --resume"
		fi
	fi
}

mkdir -p "$SWEEP_DIR"
{
	echo "# SUITE=${SUITE}"
	echo "# RUN_ID=${RUN_ID}"
	echo "# CONTEXTS=${CONTEXTS_CSV}"
	echo "# PASSES=$(IFS=,; echo "${PASSES[*]}")"
	echo "# SETTLE_SEC=${SETTLE_SEC}"
	if [[ "$SUITE" == churn-dataplane ]]; then echo "# CHURN_RATE=${CHURN_RATE}"; fi
	echo "# HARNESS_SHA=${HARNESS_SHA}"
	istio_version_kv | sed 's/^/# /'
} >"${SWEEP_DIR}/sweep-metadata.txt"
# What the console names when the sweep ends before its end, one command to paste each: the
# profile cleanup, which also resumes Argo CD from any pause record left under the results
# dir (the EXIT trap does both, unless it fails or a second signal cuts it short), then the
# suite's cleanup (the trap leaves its resources).
_tc=("${TUNING_DIR}/005-cleanup.sh" --contexts "$CONTEXTS_CSV")
[[ "$OUTPUT_BASE" == "${TUNING_DIR}/results" ]] || _tc+=(--results-dir "$OUTPUT_BASE")
SWEEP_CLEANUP_CMD="./$(show "${_tc[@]}"); ./$(show "${CLEANUP_CMD[@]}")"
# sweep-outcome.txt says the sweep runs until sweep_finish writes its outcome; one that ends
# before records how, then runs tuning_cleanup.
sweep_start "$SWEEP_DIR" "$RUN_ID" --unit passes --cleanup tuning_cleanup

if ((GITOPS_PAUSE)); then
	# Set first: a partial pause is still undone by the EXIT trap.
	GITOPS_PAUSED=1
	sweep_step "${TUNING_DIR}/006-gitops-pause.sh" --gitops-context "$GITOPS_CTX" --pause --state-file "$PAUSE_STATE" \
		|| die "could not pause Argo CD auto-sync"
fi

# The members' Istio CR spec before the first profile, to check at the end that the last
# revert restored it (an incomplete revert): istio-spec/start-<ctx>.json.
SPEC_DIR="${SWEEP_DIR}/istio-spec"
has_profile=0
for p in "${PASSES[@]}"; do [[ "$p" == baseline ]] || has_profile=1; done
if ((has_profile)); then
	mkdir -p "$SPEC_DIR"
	for ctx in "${CONTEXTS[@]}"; do
		if ! "${KUBECTL[@]}" --context="$ctx" get istio.sailoperator.io default -o json 2>/dev/null \
			| jq -S '.spec' >"${SPEC_DIR}/start-$(ctx_key "$ctx").json" 2>/dev/null; then
			rm -f "${SPEC_DIR}/start-$(ctx_key "$ctx").json"
			echo "warn: ${ctx}: could not read its Istio CR's spec; the end of the sweep cannot check that the last revert restored it" >&2
		fi
	done
fi

if ((RUN_SETUP)); then
	echo "--- Suite setup ---"
	sweep_step "${SETUP_CMD[@]}" || die "suite setup failed"
fi

# Run one pass's probe(s) into its result directory.
run_pass() {
	local label="$1" dir="${SWEEP_DIR}/$1" n=1 rc gens="" moved
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
	# This pass's own platform record (a profile changes istiod's env), read once for its probes,
	# which reuse it (platform-record.txt in the pass dir), and read again after them
	# (platform_drift_check); and its tuning levers, which its TSVs record.
	platform_probe "$CONTEXTS_CSV"
	platform_probe_share "$dir"
	while IFS= read -r kv; do
		case "$kv" in
		TUNING_BASELINE=*) TUNING_BASELINE="${kv#*=}" ;;
		SIDECAR_EGRESS_HOSTS=*) SIDECAR_EGRESS_HOSTS="${kv#*=}" ;;
		esac
	done < <(tuning_baseline_state "$SOURCE_CTX" "${KUBECTL[@]}")
	# The baseline has no apply and revert to bracket it (001 and 002 do for a profile pass): its
	# generations before its first probe and after its last.
	[[ "$label" != baseline ]] || gens="$(istio_generations_read "$CONTEXTS_CSV" "${KUBECTL[@]}")"
	while probe_argv "$n" "$label" "$dir"; do
		echo "--- Probe: $(show "${PROBE_ARGV[@]}")"
		rc=0
		# Its output on the console and in the pass's log; the step is the probe itself, so a
		# SIGTERM reaches it (sweep_step).
		sweep_step "${PROBE_ARGV[@]}" > >(tee -a "${dir}/probe-output.log") 2>&1 || rc=$?
		if ((rc != 0)); then
			echo "warn: probe for ${label} exited ${rc}; marking PROBE_FAILED" >&2
			echo "PROBE_FAILED rc=${rc} $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${dir}/PROBE_FAILED"
			break
		fi
		n=$((n + 1))
	done
	if [[ "$label" == baseline ]]; then
		moved="$(istio_generations_diff "$gens" "$(istio_generations_read "$CONTEXTS_CSV" "${KUBECTL[@]}")")"
		[[ -z "$moved" ]] || sweep_problem "pass baseline: the Istio CR changed during the pass: ${moved}; its probes may have measured another configuration"
	fi
	platform_drift_check "$CONTEXTS_CSV" "${label} pass"
}

ABORTED=0 ABORT_REASON=""
# An apply that got as far as its state (active-profile) may have patched the Istio CR, and its
# revert does: the end's read then cannot compare the generations.
patched=0
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
	applied=1
	if ! sweep_step "${TUNING_DIR}/001-apply-profile.sh" --profile "$p" --contexts "$CONTEXTS_CSV" \
		--state-dir "$state_dir" --rollout-timeout "$ROLLOUT_TIMEOUT"; then
		echo "warn: applying ${p} failed; marking SETUP_FAILED" >&2
		# 001 can fail before it creates the state dir, so the pass dir may not exist yet.
		mkdir -p "${SWEEP_DIR}/${p}"
		echo "SETUP_FAILED $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${SWEEP_DIR}/${p}/SETUP_FAILED"
		applied=0
	fi
	if ((applied)); then
		# The apply raised the generations: the pass's probes record the ones 001 read once
		# it settled (unknown when it could not).
		ISTIO_GENERATIONS=unknown
		[[ ! -s "${state_dir}/istio-generations-applied" ]] || ISTIO_GENERATIONS="$(<"${state_dir}/istio-generations-applied")"
		export ISTIO_GENERATIONS
		run_pass "$p"
	fi
	if [[ -f "${state_dir}/active-profile" ]]; then
		patched=1
		revert_ok=1
		sweep_step "${TUNING_DIR}/002-revert-profile.sh" --state-dir "$state_dir" --rollout-timeout "$ROLLOUT_TIMEOUT" || revert_ok=0
		# 002 found an edit of the Istio CR by something else during the pass.
		if [[ -s "${state_dir}/istio-edited-during-pass" ]]; then
			sweep_problem "pass ${p}: the Istio CR changed during the pass, after its apply settled and not by its profile: $(<"${state_dir}/istio-edited-during-pass"); its probes may have measured another configuration (002-revert-profile.sh, istio-edited-during-pass in its state dir)"
		fi
		if ((revert_ok == 0)); then
			echo "REVERT_FAILED $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${SWEEP_DIR}/${p}/REVERT_FAILED"
			echo "error: reverting ${p} failed; stopping the sweep so later passes are not contaminated" >&2
			ABORTED=1 ABORT_REASON="REVERT_FAILED: reverting pass ${p} failed, so later passes did not run"
			break
		fi
	fi
	ACTIVE_STATE_DIR=""
done

echo ""
# The Istio version and active revision again, after the last pass and its revert, before
# the comparison (read-only); the generations too when no profile was applied (every apply
# stopped before its first change), since then nothing of the sweep's raised them.
if ((patched)); then
	istio_version_recheck --no-generations "${KUBECTL[@]}"
else
	istio_version_recheck "${KUBECTL[@]}"
fi
# An incomplete revert, or an edit by something else that no revert undid (they restore
# only the profiles' keys): a member's Istio CR spec now, against the start's.
if ((has_profile)); then
	for ctx in "${CONTEXTS[@]}"; do
		start_spec="${SPEC_DIR}/start-$(ctx_key "$ctx").json"
		[[ -s "$start_spec" ]] || continue
		end_spec="${SPEC_DIR}/end-$(ctx_key "$ctx").json"
		if ! "${KUBECTL[@]}" --context="$ctx" get istio.sailoperator.io default -o json 2>/dev/null \
			| jq -S '.spec' >"$end_spec" 2>/dev/null; then
			rm -f "$end_spec"
			sweep_note "could not read ${ctx}'s Istio CR spec at the end, so no check that the last revert restored it"
			continue
		fi
		cmp -s "$start_spec" "$end_spec" && continue
		spec_paths="$(jq -rn --slurpfile a "$start_spec" --slurpfile b "$end_spec" '
			($a[0] // {}) as $x | ($b[0] // {}) as $y
			| ([$x, $y] | map([paths(scalars)]) | add | unique)
			| map(. as $p | select(($x | try getpath($p) catch null) != ($y | try getpath($p) catch null)) | map(tostring) | join("."))
			| join(", ")' 2>/dev/null)" || spec_paths=""
		sweep_problem "${ctx}'s Istio CR spec after the last revert differs from the sweep's start (an incomplete revert, or an edit by something else that no revert undid: they restore only the profiles' keys): ${spec_paths:-see istio-spec/ in the sweep dir}; the mesh is not as the sweep found it"
	done
fi
if ((RUN_CLEANUP)); then
	echo "--- Suite cleanup ---"
	sweep_step "${CLEANUP_CMD[@]}" || echo "warn: suite cleanup failed; re-run: $(show "${CLEANUP_CMD[@]}")" >&2
fi
tuning_cleanup

# A pass whose profile did not apply or whose probe exited non-zero has its marker
# file (run_pass and the loop above never abort on one, so every profile was reverted
# first, PL32). Count them by reason, before the comparison (it reads sweep-outcome.txt);
# a failed revert (exit 1) wins over 4.
FAILED_CELLS=()
for p in "${PASSES[@]}"; do
	for marker in SETUP_FAILED PROBE_FAILED; do
		if [[ -f "${SWEEP_DIR}/${p}/${marker}" ]]; then FAILED_CELLS+=("$marker"); break; fi
	done
done
outcome_rc=0 stop_args=()
((ABORTED == 0)) || stop_args=(--stopped 1 --stop-reason "$ABORT_REASON")
sweep_finish ${stop_args[@]+"${stop_args[@]}"} \
	--where "Each has its marker file in its pass directory, and its Pass status in sweep-comparison.md names it" \
	"${#PASSES[@]}" ${FAILED_CELLS[@]+"${FAILED_CELLS[@]}"} || outcome_rc=$?
"${TUNING_DIR}/004-compare-profiles.sh" --results-dir "$SWEEP_DIR" --format markdown \
	--output "${SWEEP_DIR}/sweep-comparison.md" || echo "warn: comparison failed" >&2

_end_word="finished"
if ((ABORTED)); then _end_word="STOPPED (revert failed)"; fi
echo "=== Sweep ${RUN_ID} ${_end_word} ==="
echo "    Results:    ${SWEEP_DIR}/"
echo "    Comparison: ${SWEEP_DIR}/sweep-comparison.md"
exit "$outcome_rc"

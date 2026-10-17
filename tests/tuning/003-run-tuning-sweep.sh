#!/usr/bin/env bash
# Sweep tuning profiles against one test suite. Pauses Argo CD auto-sync of the
# Istio CR Applications, runs the suite's setup once, then measures the baseline and
# each profile (apply -> settle -> probe -> revert), writes sweep-comparison.md,
# runs the suite's cleanup and resumes Argo CD.
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
# I5: sweep_err_trap prints the FATAL line and keeps it as the stop reason a sweep that
# aborts after its start records (sweep_outcome_on_exit in the EXIT trap).
trap 'sweep_err_trap "$?" "$LINENO" "$BASH_COMMAND"' ERR
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/preamble.sh"

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
ROLLOUT_TIMEOUT=300
DRY_RUN=0

usage() {
	cat <<EOF
Usage: $(basename "$0") --suite SUITE --gitops-context CTX [options]

For the baseline and each profile: apply, wait --settle seconds, run the suite's
probe, revert. Writes sweep-comparison.md into the sweep directory.

Options:
  --suite SUITE          propagation | controlplane | dataplane | churn |
                         churn-dataplane (required).
  --contexts CSV         Mesh member contexts; the first is the source for suites
                         that take one (default: \$SETUP_CONTEXTS).
  --gitops-context CTX   ACM hub context running OpenShift GitOps, where Argo CD
                         auto-sync is paused for the run (default: \$TUNING_GITOPS_CONTEXT).
  --no-gitops-pause      Do not pause Argo CD (mesh not managed by GitOps).
  --profiles CSV         Profile names (default: every profile in profiles/).
  --no-baseline          Skip the no-profile pass.
  --skip-setup           Do not run the suite's setup (workloads already deployed).
  --keep-workloads       Do not run the suite's cleanup at the end.
  --settle SEC           Wait after each apply before probing (default: ${SETTLE_SEC}).
  --churn-rate N         churn-dataplane only: churn operations/s (default: ${CHURN_RATE}).
  --output-dir DIR       Results base; the run writes sweep-<RUN_ID>/ there
                         (default: tests/tuning/results).
  --rollout-timeout N    Seconds to wait for istiod after apply/revert (default: ${ROLLOUT_TIMEOUT}).
  --dry-run              Print the plan, check the probe arguments with each probe's
                         own --dry-run, and exit. Touches no cluster.
  -h, --help             Show this help.

Environment:
  ISTIO_VERSION_CHECK (fail, the default, or warn): stop before any change, or warn and
  record what the mesh runs, when a member's active IstioRevision version is not
  ISTIO_VERSION. ISTIO_VERSION_READY_WAIT_SEC / ISTIO_VERSION_READY_POLL_SEC (60 / 5): how
  long, and how often, to read again a member whose istiod or IstioCNI is not ready, or
  whose istiod is rolling out; a rollout still running after the wait reads as unknown.
  SETUP_CONTEXTS, TUNING_GITOPS_CONTEXT, TUNING_SETTLE_SEC, TUNING_COEXEC_CHURN_RATE.

Exit codes:
  0  every pass (baseline and each profile) ran its probe
  1  the sweep stopped: a bad flag or precondition, the suite setup failed, a profile
     could not be reverted (REVERT_FAILED; later passes skipped), or an unexpected error;
     after its start, sweep-outcome.txt records the stop and its reason (STOPPED=1,
     STOP_REASON, CUT_SHORT=1), after the active profile is reverted
  4  the sweep finished, reverted every profile and wrote sweep-comparison.md, but N
     passes failed (the profile did not apply, SETUP_FAILED, or a probe exited
     non-zero, PROBE_FAILED; stderr ends with "N of M passes failed" by reason) or the
     Istio version or active revision changed during the sweep (read again at its end);
     the outcome is also in sweep-outcome.txt and sweep-comparison.md
  129/130/143  interrupted (SIGHUP, Ctrl-C, SIGTERM); the active profile is reverted
     first, then sweep-outcome.txt stays "not finished" and says when and by which
     signal (ENDED_AT, ENDED_SIGNAL); a SIGTERM to the sweep's process alone waits for
     its current command (signal its process group)
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

case "$SUITE" in
propagation | controlplane | dataplane | churn | churn-dataplane) ;;
"") die "--suite is required (propagation, controlplane, dataplane, churn, churn-dataplane)" ;;
*) die "unknown suite: $SUITE (propagation, controlplane, dataplane, churn, churn-dataplane)" ;;
esac
SUITE_DIR="${ROOT}/tests/${SUITE}"
is_nonneg_int "$SETTLE_SEC" || die "--settle must be a non-negative integer"
is_pos_int "$CHURN_RATE" || die "--churn-rate must be a positive integer"
is_pos_int "$ROLLOUT_TIMEOUT" || die "--rollout-timeout must be a positive integer"
if ((GITOPS_PAUSE)) && [[ -z "$GITOPS_CTX" ]]; then
	die "--gitops-context is required: the ACM hub context whose Argo CD manages the Istio CRs (or pass --no-gitops-pause)"
fi

CONTEXTS=()
split_contexts "${CONTEXTS_CSV:-${SETUP_CONTEXTS:-}}" CONTEXTS "--contexts (or SETUP_CONTEXTS)"
((${#CONTEXTS[@]})) || die "no contexts (set --contexts or SETUP_CONTEXTS)"
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
for i in "${!PROFILES[@]}"; do
	PROFILES[i]="${PROFILES[i]%.yaml}"
	[[ -f "${TUNING_DIR}/profiles/${PROFILES[i]}.yaml" ]] || die "profile not found: ${PROFILES[i]} (see tests/tuning/profiles/)"
done
PASSES=()
((INCLUDE_BASELINE)) && PASSES+=(baseline)
PASSES+=("${PROFILES[@]}")

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SWEEP_DIR="${OUTPUT_BASE}/sweep-${RUN_ID}"
# J7: read once, so sweep-metadata.txt and sweep-outcome.txt name the same harness.
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
		n=1
		while probe_argv "$n" "$p" "${SWEEP_DIR}/${p}"; do show "${PROBE_ARGV[@]}"; n=$((n + 1)); done
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
# The controlplane probe bounds its config-dump and Envoy-stats reads with timeout or
# gtimeout and stops without either (R17): check here, before any profile is applied.
[[ "$SUITE" != controlplane ]] || require_timeout
KUBECTL=()
resolve_kubectl KUBECTL
# R4: the Istio version every member runs, read once before the first profile or setup
# and exported, so every probe of every pass records it (ISTIO_VERSION_CHECK=fail stops
# here on a mismatch, before anything changes).
istio_version_resolve "$CONTEXTS_CSV" 0 "${KUBECTL[@]}"
echo "    Istio:     $(istio_version_label)"

ACTIVE_STATE_DIR=""
GITOPS_PAUSED=0

# EXIT trap: revert a profile left applied, then resume Argo CD, then (I5, PL32: only
# after the revert) a sweep that ends before its outcome says how in that record: stopped
# with its reason (die, an unexpected abort), or interrupted (Ctrl-C, SIGTERM), with a note
# for a revert or resume that failed here. Never aborts.
# shellcheck disable=SC2329  # invoked by the EXIT trap below
on_exit() {
	local rc=$? sd="$ACTIVE_STATE_DIR" prof
	local -a notes=()
	if [[ -n "$sd" && -f "${sd}/active-profile" ]]; then
		prof="$(<"${sd}/active-profile")"
		echo ">>> reverting ${prof} before exit" >&2
		if ! "${TUNING_DIR}/002-revert-profile.sh" --state-dir "$sd" --rollout-timeout "$ROLLOUT_TIMEOUT" >&2; then
			echo "warn: revert failed; re-run: ./tests/tuning/002-revert-profile.sh --state-dir ${sd}" >&2
			notes+=(--note "REVERT_FAILED: profile ${prof} is still applied (its revert on exit failed): run 002-revert-profile.sh --state-dir on its pass dir's state before any other run")
		fi
	fi
	if ((GITOPS_PAUSED)); then
		if ! "${TUNING_DIR}/006-gitops-pause.sh" --resume --state-file "$PAUSE_STATE" >&2; then
			echo "warn: Argo CD still paused; run: ./tests/tuning/006-gitops-pause.sh --resume --state-file ${PAUSE_STATE}" >&2
			notes+=(--note "Argo CD auto-sync is still paused (its resume on exit failed): run 006-gitops-pause.sh --resume")
		fi
	fi
	sweep_outcome_on_exit "$rc" ${notes[@]+"${notes[@]}"} || true
}
# `|| true`: set -e off inside, so an echo to a terminal that closed (SIGHUP) cannot
# stop the trap before the revert.
trap 'on_exit || true' EXIT
# Ctrl-C, SIGTERM and SIGHUP: trapped by sweep_outcome_start below (sweep_trap_signals),
# which runs this trap and dies of the signal; before it, bash runs this trap on them too.

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
# A3: sweep-outcome.txt says "not finished" until sweep_outcome replaces it at the end,
# so the comparison of a sweep that died says so.
sweep_outcome_start "$SWEEP_DIR" "$RUN_ID" --unit passes --next "if it died, check that no profile is still applied (005-cleanup.sh) and Argo CD auto-sync is resumed (006-gitops-pause.sh --resume), then run the sweep again into a new dir"

if ((GITOPS_PAUSE)); then
	# Set first: a partial pause is still undone by the EXIT trap.
	GITOPS_PAUSED=1
	"${TUNING_DIR}/006-gitops-pause.sh" --gitops-context "$GITOPS_CTX" --pause --state-file "$PAUSE_STATE" \
		|| die "could not pause Argo CD auto-sync"
fi

while IFS= read -r kv; do
	case "$kv" in
	TUNING_BASELINE=*) TUNING_BASELINE="${kv#*=}" ;;
	SIDECAR_EGRESS_HOSTS=*) SIDECAR_EGRESS_HOSTS="${kv#*=}" ;;
	esac
done < <(tuning_baseline_state "$SOURCE_CTX" "${KUBECTL[@]}")

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
	while probe_argv "$n" "$label" "$dir"; do
		echo "--- Probe: $(show "${PROBE_ARGV[@]}")"
		rc=0
		"${PROBE_ARGV[@]}" 2>&1 | tee -a "${dir}/probe-output.log" || rc=${PIPESTATUS[0]}
		if ((rc != 0)); then
			echo "warn: probe for ${label} exited ${rc}; marking PROBE_FAILED" >&2
			echo "PROBE_FAILED rc=${rc} $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${dir}/PROBE_FAILED"
			return 0
		fi
		n=$((n + 1))
	done
}

ABORTED=0 ABORT_REASON=""
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
		# 001 can fail before it creates the state dir, so the pass dir may not exist yet.
		mkdir -p "${SWEEP_DIR}/${p}"
		echo "SETUP_FAILED $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${SWEEP_DIR}/${p}/SETUP_FAILED"
	else
		run_pass "$p"
	fi
	if [[ -f "${state_dir}/active-profile" ]]; then
		if ! "${TUNING_DIR}/002-revert-profile.sh" --state-dir "$state_dir" --rollout-timeout "$ROLLOUT_TIMEOUT"; then
			echo "REVERT_FAILED $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${SWEEP_DIR}/${p}/REVERT_FAILED"
			echo "error: reverting ${p} failed; stopping the sweep so later passes are not contaminated" >&2
			ABORTED=1 ABORT_REASON="REVERT_FAILED: reverting pass ${p} failed, so later passes did not run"
			break
		fi
	fi
	ACTIVE_STATE_DIR=""
done

echo ""
# A6: the Istio version again, after the last pass and its revert, before the comparison
# (read-only).
IV_END=()
istio_version_recheck IV_END "${KUBECTL[@]}"
# A3: the outcome is written after the comparison: it says so (a line that sweep_outcome
# --md replaces).
export _SWEEP_OUTCOME_PENDING=1
"${TUNING_DIR}/004-compare-profiles.sh" --results-dir "$SWEEP_DIR" --format markdown \
	--output "${SWEEP_DIR}/sweep-comparison.md" || echo "warn: comparison failed" >&2

if ((RUN_CLEANUP)); then
	echo "--- Suite cleanup ---"
	"${CLEANUP_CMD[@]}" || echo "warn: suite cleanup failed; re-run: $(show "${CLEANUP_CMD[@]}")" >&2
fi

echo "=== Sweep ${RUN_ID} $( ((ABORTED)) && echo "STOPPED (revert failed)" || echo "finished") ==="
echo "    Results:    ${SWEEP_DIR}/"
echo "    Comparison: ${SWEEP_DIR}/sweep-comparison.md"

# R19: a pass whose profile did not apply or whose probe exited non-zero has its marker
# file (run_pass and the loop above never abort on one, so every profile was reverted
# first, PL32). Count them by reason, also in sweep-outcome.txt and the comparison (C3);
# a failed revert (exit 1) wins over 4.
FAILED_CELLS=()
for p in "${PASSES[@]}"; do
	for marker in SETUP_FAILED PROBE_FAILED; do
		if [[ -f "${SWEEP_DIR}/${p}/${marker}" ]]; then FAILED_CELLS+=("$marker"); break; fi
	done
done
outcome_rc=0 stop_args=()
((ABORTED == 0)) || stop_args=(--stopped 1 --stop-reason "$ABORT_REASON")
sweep_outcome ${stop_args[@]+"${stop_args[@]}"} ${IV_END[@]+"${IV_END[@]}"} --run-id "$RUN_ID" --unit passes \
	--where "Each has its marker file in its pass directory, and its Pass status in sweep-comparison.md names it" \
	--record "$SWEEP_DIR" --md "${SWEEP_DIR}/sweep-comparison.md" "${#PASSES[@]}" ${FAILED_CELLS[@]+"${FAILED_CELLS[@]}"} || outcome_rc=$?
if ((ABORTED)); then exit 1; fi
exit "$outcome_rc"

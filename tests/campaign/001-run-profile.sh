#!/usr/bin/env bash
# Run a whole test campaign from one profile: the preflight check, then each suite's sweep
# in the profile's order, each with the profile's run config for that suite, unattended.
# A profile is a directory under tests/campaign/profiles/ (kind, openshift, rosa): its
# profile.env says which suites run and how the run is guarded (CAMPAIGN_* keys of
# config/options.env), and <suite>.env is the --config each sweep gets. A suite that fails
# is recorded and the next one starts; a failed preflight stops the run, because every
# suite after it would measure a broken mesh. Past the deadline no suite starts and the
# running one is stopped (its sweep cleans up and writes what it has). Writes
# campaign-<RUN_ID>.md: one row per suite and each sweep's own outcome.
#
# Usage:
#   ./tests/campaign/001-run-profile.sh --profile NAME --contexts CSV [--hub-context CTX] [options]
# ci-dry-run: --profile kind --contexts ci-a,ci-b --hub-context ci-hub
set -euo pipefail

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
	echo "error: bash ${BASH_VERSION} is too old: the harness needs bash 4.3 or later (macOS: brew install bash, then run the scripts with that bash)" >&2
	exit 1
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/common.sh"
# Loud ERR trap for unexpected aborts; a suite's own failure is handled below.
trap 'sweep_err_trap "$?" "$LINENO" "$BASH_COMMAND"' ERR
# shellcheck disable=SC1091
source "${ROOT}/tests/lib/config.sh"  # load_config (profile.env, and the tuning probe's config)

CAMPAIGN_DIR="${ROOT}/tests/campaign"
# The suites a profile may list, and each one's sweep.
declare -A SWEEP_OF=(
	[dataplane]="tests/dataplane/003-run-sweep.sh"
	[propagation]="tests/propagation/006-run-sweep.sh"
	[churn]="tests/churn/003-run-sweep.sh"
	[churn-dataplane]="tests/churn-dataplane/004-run-sweep.sh"
	[controlplane]="tests/controlplane/003-run-sweep.sh"
	[tuning]="tests/tuning/003-run-tuning-sweep.sh"
)
KNOWN_SUITES="dataplane, propagation, churn, churn-dataplane, controlplane, tuning"

# --profile first: profile.env's keys go into the environment before options.env fills in
# the defaults, so flag > profile > env > default, as --config does for a suite.
PROFILE=""
_args=("$@")
for ((_i = 0; _i < ${#_args[@]}; _i++)); do
	case "${_args[_i]}" in
	--profile)
		[[ -z "$PROFILE" ]] || die "--profile given more than once"
		PROFILE="${_args[_i + 1]:-}"
		[[ -n "$PROFILE" && "$PROFILE" != -* ]] || die "--profile requires a value (a name under tests/campaign/profiles/, or a directory)"
		;;
	esac
done
PROFILE_DIR=""
if [[ -n "$PROFILE" ]]; then
	case "$PROFILE" in
	*/*) PROFILE_DIR="$PROFILE" ;;
	*) PROFILE_DIR="${CAMPAIGN_DIR}/profiles/${PROFILE}" ;;
	esac
	[[ -f "${PROFILE_DIR}/profile.env" ]] \
		|| die "--profile ${PROFILE}: no profile.env in ${PROFILE_DIR} (profiles: $(cd "${CAMPAIGN_DIR}/profiles" && echo */ | tr -d /))"
	PROFILE_DIR="$(cd "$PROFILE_DIR" && pwd)"
	load_config "${PROFILE_DIR}/profile.env" campaign
fi
# shellcheck disable=SC1091
source "${ROOT}/config/versions.env"

CONTEXTS_CSV=""
HUB_CTX="${PREFLIGHT_HUB_CONTEXT:-}"
SUITES_CSV="${CAMPAIGN_SUITES}"
DEADLINE_MIN="${CAMPAIGN_DEADLINE_MIN}"
PREFLIGHT=1
OUTPUT_BASE="${CAMPAIGN_DIR}/results"
DRY_RUN=0

usage() {
	cat <<EOF
Usage: $(basename "$0") --profile NAME --contexts CSV [--hub-context CTX] [options]

Runs the preflight check, then each suite of the profile in its order, each sweep with the
profile's <suite>.env as its --config, and writes campaign-<RUN_ID>.md under the output dir.
A failed suite is recorded and the next one runs; a failed preflight stops the run.

  --profile NAME         A directory under tests/campaign/profiles/ (kind, openshift, rosa),
                         or a path to one. Required.
  --contexts CSV         Mesh members, never the hub; the first is the source for the
                         suites that take one (default: \$SETUP_CONTEXTS).
  --hub-context CTX      The hub's context: the preflight's echo check and tuning's Argo CD
                         pause need it (default: \$PREFLIGHT_HUB_CONTEXT).
  --suites CSV           Run these of the profile's suites only, in the profile's order
                         (default: \$CAMPAIGN_SUITES, the profile's list).
  --deadline-min N       Minutes after the start when no suite starts any more and the
                         running one is stopped; 0 = none (default: \$CAMPAIGN_DEADLINE_MIN).
  --no-preflight         Skip every preflight check (not for an unattended run).
  --output-dir DIR       Results base; the run writes <profile>-<RUN_ID>/ there
                         (default: tests/campaign/results).
  --dry-run              Check the profile, print the plan and each sweep's own --dry-run
                         plan, and exit. Touches no cluster.
  -h, --help             Show this help.

Environment (config/options.env describes each): SETUP_CONTEXTS, PREFLIGHT_HUB_CONTEXT, the
CAMPAIGN_* keys (a profile's profile.env sets them), each suite's keys (its <suite>.env sets
them), SWEEP_STOP_GRACE_SEC.

Exit codes: 0 every suite ran clean; 1 stopped (a bad flag or profile, a failed preflight,
an error); 4 a suite failed, stopped or found failed cells, or the deadline skipped one
(campaign-<RUN_ID>.md names it); 129, 130, 143 a signal.

See tests/campaign/README.md.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--profile | --contexts | --hub-context | --suites | --deadline-min | --output-dir)
		[[ -n "${2:-}" ]] || die "$1 requires a value"
		case "$1" in
		--contexts) CONTEXTS_CSV="$2" ;;
		--hub-context) HUB_CTX="$2" ;;
		--suites) SUITES_CSV="$2" ;;
		--deadline-min) DEADLINE_MIN="$2" ;;
		--output-dir) OUTPUT_BASE="$2" ;;
		esac
		shift 2
		;;
	--no-preflight) PREFLIGHT=0; shift ;;
	--dry-run) DRY_RUN=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) die "unknown option: $1 (try --help)" ;;
	esac
done

sweep_settings_check
[[ -n "$PROFILE" ]] || die "--profile is required (profiles: $(cd "${CAMPAIGN_DIR}/profiles" && echo */ | tr -d /))"
PROFILE_NAME="$(basename "$PROFILE_DIR")"
is_nonneg_int "$DEADLINE_MIN" || die "--deadline-min (or CAMPAIGN_DEADLINE_MIN) must be a non-negative integer of minutes; got '${DEADLINE_MIN}'"
[[ "$CAMPAIGN_PREFLIGHT_ECHO" =~ ^[01]$ ]] || die "CAMPAIGN_PREFLIGHT_ECHO must be 0 or 1; got '${CAMPAIGN_PREFLIGHT_ECHO}'"
[[ "$CAMPAIGN_PREFLIGHT_BETWEEN" =~ ^[01]$ ]] || die "CAMPAIGN_PREFLIGHT_BETWEEN must be 0 or 1; got '${CAMPAIGN_PREFLIGHT_BETWEEN}'"

CONTEXTS=()
split_contexts "${CONTEXTS_CSV:-${SETUP_CONTEXTS:-}}" CONTEXTS "--contexts (or SETUP_CONTEXTS)"
((${#CONTEXTS[@]})) || die "no contexts (set --contexts or SETUP_CONTEXTS)"
CONTEXTS_CSV="$(IFS=,; echo "${CONTEXTS[*]}")"
for ctx in "${CONTEXTS[@]}"; do
	[[ "$ctx" != "$HUB_CTX" ]] || die "the hub (${HUB_CTX}) is listed in --contexts: list the mesh members only"
done

# The profile's suites, in its order; --suites picks among them.
PROFILE_SUITES=() SUITES=() PICK=()
split_csv "$CAMPAIGN_SUITES" PROFILE_SUITES
((${#PROFILE_SUITES[@]})) || die "${PROFILE_NAME}/profile.env lists no suites (CAMPAIGN_SUITES)"
declare -A SEEN=()
for s in "${PROFILE_SUITES[@]}"; do
	[[ -n "${SWEEP_OF[$s]+x}" ]] || die "${PROFILE_NAME}/profile.env: unknown suite '${s}' in CAMPAIGN_SUITES (suites: ${KNOWN_SUITES})"
	[[ -z "${SEEN[$s]+x}" ]] || die "${PROFILE_NAME}/profile.env: suite '${s}' listed twice in CAMPAIGN_SUITES (each writes to a directory named after it)"
	SEEN[$s]=1
done
split_csv "$SUITES_CSV" PICK
declare -A PICKED=()
for s in "${PICK[@]}"; do
	[[ -n "${SEEN[$s]+x}" ]] || die "--suites: '${s}' is not one of the profile's suites (${CAMPAIGN_SUITES})"
	PICKED[$s]=1
done
for s in "${PROFILE_SUITES[@]}"; do
	[[ -z "${PICKED[$s]+x}" ]] || SUITES+=("$s")
done
((${#SUITES[@]})) || die "no suites to run"

# Each suite's run config; tuning probes with CAMPAIGN_TUNING_SUITE's config, from the
# environment (tuning takes no --config).
config_of() {
	if [[ "$1" == tuning ]]; then echo "${PROFILE_DIR}/${CAMPAIGN_TUNING_SUITE}.env"; else echo "${PROFILE_DIR}/$1.env"; fi
}
for s in "${SUITES[@]}"; do
	if [[ "$s" == tuning ]]; then
		case "$CAMPAIGN_TUNING_SUITE" in
		propagation | dataplane | churn | churn-dataplane | controlplane) ;;
		*) die "CAMPAIGN_TUNING_SUITE must be one of propagation, dataplane, churn, churn-dataplane, controlplane; got '${CAMPAIGN_TUNING_SUITE}'" ;;
		esac
		[[ -n "$HUB_CTX" ]] || die "the tuning suite pauses Argo CD on the hub: pass --hub-context (or set PREFLIGHT_HUB_CONTEXT)"
	fi
	[[ -f "$(config_of "$s")" ]] || die "${PROFILE_NAME}: no run config for ${s}: $(config_of "$s")"
	# Rejected now, not hours into the run: a bad key or line stops the run before any cluster call.
	(load_config "$(config_of "$s")" "$([[ "$s" == tuning ]] && echo "$CAMPAIGN_TUNING_SUITE" || echo "$s")" 2>/dev/null) \
		|| die "${PROFILE_NAME}: $(config_of "$s") is not a valid run config (run the suite's sweep with --config on it to see why)"
done
if ((PREFLIGHT && CAMPAIGN_PREFLIGHT_ECHO)) && [[ -z "$HUB_CTX" ]]; then
	die "${PROFILE_NAME}/profile.env asks for the preflight echo check (CAMPAIGN_PREFLIGHT_ECHO=1): pass --hub-context"
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
case "$OUTPUT_BASE" in /*) ;; *) OUTPUT_BASE="${ROOT}/${OUTPUT_BASE}" ;; esac
RUN_DIR="${OUTPUT_BASE}/${PROFILE_NAME}-${RUN_ID}"

# suite_argv <suite>: the sweep's command line into ARGV, and into PREFIX what runs it
# (with_config for tuning, nothing for the others).
suite_argv() {
	local s="$1" out="${RUN_DIR}/$1"
	ARGV=("${ROOT}/${SWEEP_OF[$s]}") PREFIX=()
	if [[ "$s" == tuning ]]; then
		PREFIX=(with_config "$(config_of tuning)" "$CAMPAIGN_TUNING_SUITE")
		ARGV+=(--suite "$CAMPAIGN_TUNING_SUITE" --gitops-context "$HUB_CTX")
		[[ -z "$CAMPAIGN_TUNING_PROFILES" ]] || ARGV+=(--profiles "$CAMPAIGN_TUNING_PROFILES")
	else
		ARGV+=(--config "$(config_of "$s")")
	fi
	ARGV+=(--contexts "$CONTEXTS_CSV" --output-dir "$out")
}

# with_config <file> <suite> <cmd>...: run <cmd> with the run config's keys in the
# environment (for tuning, which takes no --config; its probes inherit them).
with_config() {
	local f="$1" s="$2"
	shift 2
	load_config "$f" "$s"
	"$@"
}

PREFLIGHT_ARGV=("${ROOT}/tests/preflight/001-check-mesh.sh" --contexts "$CONTEXTS_CSV")
[[ -z "$HUB_CTX" ]] || PREFLIGHT_ARGV+=(--hub-context "$HUB_CTX")

show() { local a=("${@//"${ROOT}"\//}"); echo "${a[*]}"; }

echo "=== Campaign: profile ${PROFILE_NAME}, ${#CONTEXTS[@]} member(s), ${#SUITES[@]} suite(s) ==="
echo "  results:  ${RUN_DIR#"${ROOT}"/}/"
if ((DEADLINE_MIN)); then echo "  deadline: ${DEADLINE_MIN} min after the start"; else echo "  deadline: none"; fi
if ((PREFLIGHT)); then
	_echo=""
	((CAMPAIGN_PREFLIGHT_ECHO == 0)) || _echo=" --echo"
	echo "  preflight: $(show "${PREFLIGHT_ARGV[@]}")${_echo}"
	if ((CAMPAIGN_PREFLIGHT_BETWEEN)); then echo "             and again (no echo) before each suite"; fi
fi
for s in "${SUITES[@]}"; do
	suite_argv "$s"
	echo "  ${s}: $(show "${ARGV[@]}")$( ((${#PREFIX[@]} == 0)) || echo " (with ${PREFIX[1]#"${ROOT}"/} in the environment)")"
done

if ((DRY_RUN)); then
	rc=0
	for s in "${SUITES[@]}"; do
		echo "--- ${s}: its own --dry-run ---"
		suite_argv "$s"
		# A subshell: with_config exports the tuning probe's keys, which must not reach the
		# next suite's dry run.
		(${PREFIX[@]+"${PREFIX[@]}"} "${ARGV[@]}" --dry-run) || { rc=$?; echo "error: ${s}'s dry run failed (exit ${rc})" >&2; }
	done
	((rc == 0)) || exit 1
	echo "Dry run: no cluster touched."
	exit 0
fi

mkdir -p "$RUN_DIR"
# The profile as run, for a replay and for the report.
cp -R "$PROFILE_DIR" "${RUN_DIR}/profile"
SUMMARY_TSV="${RUN_DIR}/suites.tsv"
printf 'suite\tstatus\texit\tstarted_at\tminutes\tsweep_dir\n' >"$SUMMARY_TSV"
SWEEP_CLEANUP_CMD="the cleanup command each suite's console names in ${RUN_DIR#"${ROOT}"/}/<suite>/console.log"
sweep_start "$RUN_DIR" "$RUN_ID" --unit suites
START_EPOCH="$(date +%s)"
DEADLINE_EPOCH=0
((DEADLINE_MIN == 0)) || DEADLINE_EPOCH=$((START_EPOCH + DEADLINE_MIN * 60))
REASONS=() STOPPED="" STOP_WHY=""

# record <suite> <status> <exit> <started_at> <minutes> <sweep_dir>
record() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >>"$SUMMARY_TSV"; }

# run_preflight <label> [--echo]: 0 when the mesh passed.
run_preflight() {
	local label="$1" log="${RUN_DIR}/preflight-$1.log"
	shift
	echo "--- preflight (${label}) ---"
	sweep_step "${PREFLIGHT_ARGV[@]}" "$@" > >(tee -a "$log") 2>&1
}

if ((PREFLIGHT)); then
	pf_args=()
	((CAMPAIGN_PREFLIGHT_ECHO == 0)) || pf_args=(--echo)
	if ! run_preflight start ${pf_args[@]+"${pf_args[@]}"}; then
		STOPPED=1 STOP_WHY="the preflight failed before the first suite (preflight-start.log)"
	fi
fi

for s in "${SUITES[@]}"; do
	if [[ -n "$STOPPED" ]]; then
		record "$s" NOT_RUN - - - -
		REASONS+=(NOT_RUN)
		continue
	fi
	now="$(date +%s)"
	if ((DEADLINE_EPOCH && now >= DEADLINE_EPOCH)); then
		echo "--- ${s}: skipped, the deadline (${DEADLINE_MIN} min) has passed ---"
		record "$s" SKIPPED_DEADLINE - - - -
		REASONS+=(SKIPPED_DEADLINE)
		continue
	fi
	if ((PREFLIGHT && CAMPAIGN_PREFLIGHT_BETWEEN)) && [[ "$s" != "${SUITES[0]}" ]] && ! run_preflight "before-${s}"; then
		STOPPED=1 STOP_WHY="the preflight before ${s} failed (preflight-before-${s}.log): the mesh is not as the run found it"
		record "$s" NOT_RUN - - - -
		REASONS+=(NOT_RUN)
		continue
	fi
	suite_argv "$s"
	mkdir -p "${RUN_DIR}/${s}"
	now="$(date +%s)"
	started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "=== ${s} (started ${started}) ==="
	rc=0
	if ((DEADLINE_EPOCH)); then
		left=$((DEADLINE_EPOCH - now))
		# SIGTERM at the deadline: the sweep stops its step, cleans up and records itself
		# as interrupted; SIGKILL only if it is still running a grace later.
		((left > 0)) || left=1
		sweep_step ${PREFIX[@]+"${PREFIX[@]}"} run_timeout -k "$((${SWEEP_STOP_GRACE_SEC:-30} + 300))" "$left" "${ARGV[@]}" \
			> >(tee -a "${RUN_DIR}/${s}/console.log") 2>&1 || rc=$?
	else
		sweep_step ${PREFIX[@]+"${PREFIX[@]}"} "${ARGV[@]}" > >(tee -a "${RUN_DIR}/${s}/console.log") 2>&1 || rc=$?
	fi
	minutes=$((($(date +%s) - now + 30) / 60))
	sweep_dir="$(find "${RUN_DIR}/${s}" -maxdepth 1 -type d -name 'sweep-*' | sort | tail -n1)"
	sweep_dir="${sweep_dir#"${RUN_DIR}"/}"
	case "$rc" in
	0) status=OK ;;
	4) status=FAILED_CELLS ;;
	3) status=UNREACHABLE ;;
	124 | 137) status=STOPPED_AT_DEADLINE ;;
	1) status=STOPPED ;;
	*) status="EXIT_${rc}" ;;
	esac
	record "$s" "$status" "$rc" "$started" "$minutes" "${sweep_dir:--}"
	[[ "$status" == OK ]] || REASONS+=("$status")
	echo "=== ${s}: ${status} (exit ${rc}, ${minutes} min) ==="
done

stop_args=()
[[ -z "$STOPPED" ]] || stop_args=(--stopped 1 --stop-reason "$STOP_WHY")
outcome_rc=0
sweep_finish ${stop_args[@]+"${stop_args[@]}"} \
	--where "suites.tsv and campaign-${RUN_ID}.md name each one; its own sweep dir says why" \
	"${#SUITES[@]}" ${REASONS[@]+"${REASONS[@]}"} || outcome_rc=$?
# A suite the deadline skipped is skipped on purpose for the sweep record, but the run did
# not do what the profile asked: exit 4 so a wrapper notices.
((outcome_rc != 0)) || [[ " ${REASONS[*]-} " != *" SKIPPED_DEADLINE "* ]] || outcome_rc="$SWEEP_FAILED_EXIT"

# The report: the run, one row per suite, then each sweep's own outcome record.
REPORT="${RUN_DIR}/campaign-${RUN_ID}.md"
{
	echo "# Campaign ${RUN_ID}: profile ${PROFILE_NAME}"
	echo
	echo "| Run | Value |"
	echo "| --- | --- |"
	echo "| Profile | \`$(md_cell "$PROFILE_NAME")\` (copy in \`profile/\`), profile.env sha256 \`${RUN_CONFIG_SHA256:0:12}\` |"
	echo "| Members | ${#CONTEXTS[@]} |"
	echo "| Harness | \`${HARNESS_SHA:-unknown}\` |"
	echo "| Istio pin | ${ISTIO_VERSION} |"
	echo "| Deadline | $( ((DEADLINE_MIN)) && echo "${DEADLINE_MIN} min" || echo none) |"
	echo "| Outcome | exit ${outcome_rc}$([[ -z "$STOPPED" ]] || echo ", stopped: $(md_cell "$STOP_WHY")") |"
	echo
	echo "| Suite | Status | Exit | Started (UTC) | Minutes | Results |"
	echo "| --- | --- | --- | --- | --- | --- |"
	while IFS=$'\t' read -r _s _st _rc _at _min sd; do
		[[ "$_s" != suite ]] || continue
		echo "| ${_s} | ${_st} | ${_rc} | ${_at} | ${_min} | $([[ "$sd" == - ]] && echo - || echo "\`${sd}/\`") |"
	done <"$SUMMARY_TSV"
	echo
	echo "Each suite's report is in its sweep dir; its console output in \`<suite>/console.log\`."
	echo
	echo "## Sweep outcomes"
	echo
	while IFS=$'\t' read -r _s _st _rc _at _min sd; do
		[[ "$_s" != suite ]] || continue
		echo "### ${_s}"
		echo
		if [[ "$_rc" == - ]]; then
			echo "Not run (${_st})."
			echo
		elif [[ "$sd" == - ]]; then
			echo "${_st}, exit ${_rc}, with no sweep dir: it stopped before its sweep started (see \`${_s}/console.log\`)."
			echo
		elif [[ -f "${RUN_DIR}/${sd}/sweep-outcome.txt" ]]; then
			sweep_outcome_lines md "${RUN_DIR}/${sd}"
		else
			echo "No sweep-outcome.txt in \`${sd}/\`: the sweep stopped before its start (see \`${_s}/console.log\`)."
			echo
		fi
	done <"$SUMMARY_TSV"
} >"$REPORT"

echo "=== Campaign ${RUN_ID} finished (exit ${outcome_rc}) ==="
echo "    Report: ${REPORT#"${ROOT}"/}"
exit "$outcome_rc"

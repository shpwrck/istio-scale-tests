#!/usr/bin/env bats
# tests/campaign/001-run-profile.sh in a copy of the repo whose sweeps and preflight are stubs:
# every suite runs in the profile's order with its own --config, tuning with its probe's config
# in the environment; a failed suite is recorded and the next one runs; a failed preflight runs
# nothing; a bad profile, a hub among the members or a bad run config stops before any cluster
# call. The deadline was checked by hand (it needs minutes of wall clock).

load test_helper
bats_require_minimum_version 1.5.0

setup() {
	T="$BATS_TEST_TMPDIR"
	R="${T}/repo"
	export T
	mkdir -p "${R}/tests/campaign/profiles/p" "${R}/tests/lib" "${R}/tests/preflight" "${R}/config"
	cp "${ROOT}/tests/campaign/001-run-profile.sh" "${R}/tests/campaign/"
	cp "${ROOT}"/tests/lib/*.sh "${R}/tests/lib/"
	cp "${ROOT}"/config/*.env "${R}/config/"
	# A stub sweep: logs its name and arguments (and PROPAGATION_ITERATIONS, the tuning probe's
	# key), writes a sweep dir with a finished record under --output-dir, exits rc.<suite>.
	local suite path
	for suite in dataplane:003-run-sweep.sh propagation:006-run-sweep.sh churn:003-run-sweep.sh \
		churn-dataplane:004-run-sweep.sh controlplane:003-run-sweep.sh tuning:003-run-tuning-sweep.sh; do
		path="${R}/tests/${suite%%:*}/${suite#*:}"
		mkdir -p "$(dirname "$path")"
		cat >"$path" <<'EOF'
#!/usr/bin/env bash
s="$(basename "$(dirname "$0")")" out=""
echo "${s} $* PI=${PROPAGATION_ITERATIONS:-}" >>"$T/calls.log"
for ((i = 1; i <= $#; i++)); do [[ "${!i}" == --output-dir ]] && { j=$((i + 1)); out="${!j}"; }; done
[[ "$*" != *--dry-run* ]] || exit 0
rc="$(cat "$T/rc.${s}" 2>/dev/null || echo 0)"
mkdir -p "${out}/sweep-x"
printf 'STATUS=finished\nEXIT=%s\nTOTAL=1\nFAILED=0\n' "$rc" >"${out}/sweep-x/sweep-outcome.txt"
exit "$rc"
EOF
		chmod +x "$path"
	done
	cat >"${R}/tests/preflight/001-check-mesh.sh" <<'EOF'
#!/usr/bin/env bash
echo "preflight $*" >>"$T/calls.log"
exit "$(cat "$T/rc.preflight" 2>/dev/null || echo 0)"
EOF
	chmod +x "${R}/tests/preflight/001-check-mesh.sh"
	P="${R}/tests/campaign/profiles/p"
	printf '%s\n' 'CAMPAIGN_SUITES=dataplane,tuning,churn' 'CAMPAIGN_TUNING_SUITE=propagation' >"${P}/profile.env"
	echo 'DATAPLANE_DURATION_SEC=5' >"${P}/dataplane.env"
	echo 'PROPAGATION_ITERATIONS=7' >"${P}/propagation.env"
	echo 'CHURN_ITERATIONS=2' >"${P}/churn.env"
	RUN=("${R}/tests/campaign/001-run-profile.sh" --profile p --contexts m-a,m-b --hub-context hub
		--output-dir "${T}/out")
}

report() { cat "${T}"/out/p-*/campaign-*.md; }

@test "campaign: every suite in order with its config, tuning with its probe's config in the environment; the report has a row each" {
	run "${RUN[@]}"
	assert_success
	run grep -o '^[a-z-]*' "${T}/calls.log"
	assert_output "$(printf '%s\n' preflight dataplane preflight tuning preflight churn)"
	run cat "${T}/calls.log"
	assert_line --index 0 --partial '--contexts m-a,m-b --hub-context hub --echo'
	assert_line --index 1 --partial "--config ${R}/tests/campaign/profiles/p/dataplane.env --contexts m-a,m-b --output-dir ${T}/out/p-"
	assert_line --index 2 --partial '--hub-context hub'
	refute_line --index 2 --partial '--echo'
	assert_line --index 3 --regexp '^tuning --suite propagation --gitops-context hub --contexts m-a,m-b .* PI=7$'
	refute_line --index 5 --partial 'PI=7'
	run report
	assert_output --partial '| dataplane | OK | 0 | '
	assert_output --partial '### churn'
	assert_output --regexp '\| tuning \| OK \| 0 \| .* \| `tuning/sweep-x/` \|'
	assert_output --partial '| churn | OK | 0 |'
	assert_output --partial '| Outcome | exit 0 |'
	[[ -d "$(echo "${T}"/out/p-*/profile)" ]]
}

@test "campaign: a failed suite is recorded and the next one runs (exit 4); a failed preflight runs no suite (exit 1)" {
	echo 4 >"${T}/rc.dataplane"
	run "${RUN[@]}"
	assert_failure 4
	run report
	assert_output --partial '| dataplane | FAILED_CELLS | 4 |'
	assert_output --partial '| churn | OK | 0 |'
	assert_output --partial 'Sweep outcomes'

	rm -rf "${T}/out" "${T}/rc.dataplane"
	: >"${T}/calls.log"
	echo 1 >"${T}/rc.preflight"
	run "${RUN[@]}"
	assert_failure 1
	run grep -c '^preflight' "${T}/calls.log"
	assert_output 1
	run grep -vc '^preflight' "${T}/calls.log"
	assert_output 0
	run report
	assert_output --partial '| dataplane | NOT_RUN | - |'
	assert_output --partial 'stopped: the preflight failed before the first suite'
}

@test "campaign: a bad profile, the hub among the members, or a bad run config stops before any call" {
	run "${R}/tests/campaign/001-run-profile.sh" --profile nope --contexts m-a
	assert_failure 1
	assert_output --partial 'no profile.env'
	run "${RUN[@]}" --suites churn,controlplane
	assert_failure 1
	assert_output --partial "'controlplane' is not one of the profile's suites"
	run "${R}/tests/campaign/001-run-profile.sh" --profile p --contexts m-a,hub --hub-context hub
	assert_failure 1
	assert_output --partial 'the hub (hub) is listed in --contexts'
	run "${R}/tests/campaign/001-run-profile.sh" --profile p --contexts m-a
	assert_failure 1
	assert_output --partial 'pass --hub-context'
	echo 'CHURN_NOT_A_KEY=1' >"${P}/churn.env"
	run "${RUN[@]}"
	assert_failure 1
	assert_output --partial 'churn.env is not a valid run config'
	printf '%s\n' 'CAMPAIGN_SUITES=dataplane,dataplane' >"${P}/profile.env"
	run "${RUN[@]}"
	assert_failure 1
	assert_output --partial "suite 'dataplane' listed twice"
	run ! test -e "${T}/calls.log"
}

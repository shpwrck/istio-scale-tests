#!/usr/bin/env bats
# tuning 004-compare-profiles through its real entrypoint (PL33), per pass: each pass's
# Istio CR / IstioRevision generations from its own TSVs (a profile's apply and revert
# raise them), "TSV columns: none" that says why, and the --help that names the sweep's
# own PROBLEM causes and REPORT_HARNESS_SHA. Contexts are placeholders (ci-a, ci-b).

bats_require_minimum_version 1.5.0
load test_helper

COMPARE="${ROOT}/tests/tuning/004-compare-profiles.sh"
CP_HDR=$'timestamp\tistiod_restarted\tistiod_mem_mi\tgo_heap_inuse_mi\tistiod_cpu_m_delta\tconvergence_p99_ms\txds_pushes_delta\tsidecar_config_bytes_avg\tconnected_proxies'

# _pass <dir> <ISTIO_GENERATIONS or -> [rows]: a controlplane pass TSV in <dir>, with
# the generations line unless -, and one data row unless rows is 0.
_pass() {
	mkdir -p "$1"
	{
		[[ "$2" == - ]] || echo "# ISTIO_GENERATIONS=$2"
		echo "$CP_HDR"
		[[ "${3:-1}" == 0 ]] || printf 't\t0\t512\t300\t250\t99\t438\t20480\t10\n'
	} > "$1/controlplane-$(basename "$1").tsv"
}

setup() {
	S="${BATS_TEST_TMPDIR}/sweep"
	mkdir -p "$S"
	printf '# SUITE=controlplane\n# PASSES=baseline,01-x,02-y,03-z\n# ISTIO_GENERATIONS=ci-a=1/1,ci-b=1/1\n' > "${S}/sweep-metadata.txt"
}

@test "tuning 004: a per-pass generations row gives each pass's own, from its TSVs, in md and text" {
	_pass "${S}/baseline" "ci-a=2/2,ci-b=2/2"
	_pass "${S}/01-x" "ci-a=3/3,ci-b=4/4"
	_pass "${S}/02-y" -
	# 03-z wrote no TSV (no data).
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	# One value for every member prints once; members that differ print as recorded; a
	# TSV without the key reads unknown; a pass with no TSV has no cell.
	assert_line "| Istio CR / IstioRevision generations | 2/2 (every member) | ci-a=3/3,ci-b=4/4 | unknown | - |"
	assert_output --partial "each pass's ISTIO_GENERATIONS from its own TSVs"
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_output --regexp $'\nIstio CR / IstioRevision generations +2/2 \\(every member\\) +ci-a=3/3,ci-b=4/4 +unknown +-\n'
	# Two TSVs of one pass that disagree read mixed in its cell.
	{ echo "# ISTIO_GENERATIONS=ci-a=5/5,ci-b=5/5"; echo "$CP_HDR"; printf 't\t0\t512\t300\t250\t99\t438\t20480\t10\n'; } > "${S}/01-x/controlplane-second.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_line --partial "| Istio CR / IstioRevision generations | 2/2 (every member) | mixed:ci-a=3/3,ci-b=4/4 \\| ci-a=5/5,ci-b=5/5 | unknown | - |"
}

@test "tuning 004: TSV columns none says no pass wrote a TSV, or that no TSV has a data row" {
	mkdir -p "${S}/baseline" "${S}/01-x" "${S}/02-y" "${S}/03-z"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_line "- TSV columns: none (no pass wrote a TSV)"
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_line "TSV columns: none (no pass wrote a TSV)"
	_pass "${S}/baseline" - 0
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_line "- TSV columns: none (no pass's TSV has a data row)"
	_pass "${S}/baseline" -
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_line "- TSV columns: 9"
}

@test "tuning 004 --help names the sweep's own problem causes and REPORT_HARNESS_SHA" {
	run "$COMPARE" --help
	assert_success
	local flat
	flat="$(tr '\n' ' ' <<<"$output" | tr -s ' ')"
	[[ "$flat" == *"during a pass, after its apply settled and not by its profile"* ]]
	[[ "$flat" == *"an incomplete revert: a member's Istio CR spec after the last revert differs from the sweep's start"* ]]
	[[ "$flat" == *"REPORT_HARNESS_SHA (every format, next to it) is the harness this report ran on"* ]]
	[[ "$flat" == *'"none" when no pass wrote a TSV'* ]]
}

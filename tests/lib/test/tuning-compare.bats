#!/usr/bin/env bats
# tuning 004-compare-profiles through its real entrypoint: histogram p99 rows show the
# worst bucket (or overflow) instead of a mean of interpolated values, labels carry the
# right units (Mi, m, KiB, "peak"), and counts print as integers.

bats_require_minimum_version 1.5.0
load test_helper

COMPARE="${ROOT}/tests/tuning/004-compare-profiles.sh"
CP_HDR=$'timestamp\tistiod_restarted\tistiod_mem_mi\tgo_heap_inuse_mi\tistiod_cpu_m_delta\tconvergence_p99_ms\txds_pushes_delta\tsidecar_config_bytes_avg\tconnected_proxies'

setup() {
	S="${BATS_TEST_TMPDIR}/sweep"
	mkdir -p "${S}/baseline" "${S}/01-x"
	printf '# SUITE=controlplane\n# PASSES=baseline,01-x\n' > "${S}/sweep-metadata.txt"
	# baseline: convergence p99 99 and 600 average to ~350 ("100-500"), a bucket no row hit.
	{
		echo "$CP_HDR"
		printf 't\t0\t512\t300\t250\t99\t438\t20480\t10\n'
		printf 't\t0\t512\t300\t250\t600\t438\t20480\t10\n'
		# A restarted row is not valid and never counts.
		printf 't\t1\t9999\t9999\t9999\toverflow\t9999\t9999\t9999\n'
	} > "${S}/baseline/controlplane-r1.tsv"
	# profile: one row's convergence p99 overflowed.
	{
		echo "$CP_HDR"
		printf 't\t0\t256\t300\t250\t100\t400\t10240\t10\n'
		printf 't\t0\t256\t300\t250\toverflow\t400\t10240\t11\n'
	} > "${S}/01-x/controlplane-r2.tsv"
}

@test "tuning 004: histogram p99 is the worst bucket or overflow, never a mean" {
	run "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Convergence p99 worst bucket (ms) | 500-1000 | overflow (1 row) |"
	refute_output --partial "349.50"
	run "$COMPARE" --results-dir "$S"
	assert_output --regexp 'Convergence p99 worst bucket \(ms\) +500-1000 +overflow \(1 row\)'
}

@test "tuning 004: units are Mi, m and KiB with peak stated; counts print as integers" {
	run "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Valid / total rows | 2/3 | 2/2 |"
	assert_output --partial "| istiod memory peak (Mi) | 512 | 256 (-50.0%) |"
	assert_output --partial "| Go heap in use (Mi) | 300 | 300 (+0.0%) |"
	assert_output --partial "| istiod CPU peak (m) | 250 | 250 (+0.0%) |"
	assert_output --partial "| xDS pushes | 438 | 400 (-8.7%) |"
	assert_output --partial "| Sidecar config (KiB) | 20.0 | 10.0 (-50.0%) |"
	# A mean that is not whole keeps one decimal.
	assert_output --partial "| Connected proxies / istiod replica | 10 | 10.5 (+5.0%) |"
	refute_output --partial "MiB"
	refute_output --partial "millicores"
	refute_output --partial "(bytes)"
	refute_output --partial "438.00"
}

@test "tuning 004: every metric shows n got/attempted and its range; a profile whose n differs is flagged (R12)" {
	P="${BATS_TEST_TMPDIR}/psweep"
	mkdir -p "${P}/baseline" "${P}/01-x"
	printf '# SUITE=propagation\n# PASSES=baseline,01-x\n' > "${P}/sweep-metadata.txt"
	hdr=$'timestamp\trestarted\tstatus\tp1_ms\tp2_ms\tp3_ms\tp1_conv_p99_ms'
	{
		echo "$hdr"
		for v in 100 200 300 400; do printf 't\t0\tOK\t%s\t50\t60\t99\n' "$v"; done
	} > "${P}/baseline/propagation.tsv"
	# The profile timed out on 2 of 4 iterations: its P1 mean (110) looks better
	# than the baseline's (250) only because the slow iterations are missing.
	{
		echo "$hdr"
		printf 't\t0\tOK\t100\t50\t60\t99\n'
		printf 't\t0\tOK\t120\t50\t60\toverflow\n'
		printf 't\t0\tTIMEOUT\tTIMEOUT\tN/A\tN/A\tN/A\n'
		printf 't\t0\tTIMEOUT\tTIMEOUT\tN/A\tN/A\tN/A\n'
	} > "${P}/01-x/propagation.tsv"
	run "$COMPARE" --results-dir "$P" --format md
	assert_success
	assert_output --partial "| P1 local push (ms) | 250.00 | 110.00 (-56.0%) |"
	assert_output --partial "|   n (got/attempted) | 4/4 | 2/4 (baseline n 4/4) |"
	assert_output --partial "|   range (min to max) | 100.00 to 400.00 | 100.00 to 120.00 |"
	assert_output --partial "|   range (min to max) | 0-100 to 0-100 | 0-100 to overflow |"
	assert_output --partial "n differs from the baseline"
	run "$COMPARE" --results-dir "$P"
	assert_success
	assert_output --regexp 'n \(got/attempted\) +4/4 +2/4 \(baseline n 4/4\)'
	assert_output --regexp 'range \(min to max\) +100\.00 to 400\.00 +100\.00 to 120\.00'
	assert_output --partial "WARNING: a profile's n differs from the baseline's"
}

@test "tuning 004: a metric no valid row has is shown as n 0/N, not hidden (R12)" {
	P="${BATS_TEST_TMPDIR}/psweep0"
	mkdir -p "${P}/baseline"
	printf '# SUITE=propagation\n# PASSES=baseline\n' > "${P}/sweep-metadata.txt"
	{
		printf 'timestamp\trestarted\tstatus\tp1_ms\tp2_ms\tp3_ms\tp1_conv_p99_ms\n'
		printf 't\t0\tTIMEOUT\tTIMEOUT\tN/A\tN/A\tN/A\n'
		printf 't\t0\tTIMEOUT\tTIMEOUT\tN/A\tN/A\tN/A\n'
	} > "${P}/baseline/propagation.tsv"
	run "$COMPARE" --results-dir "$P" --format md
	assert_success
	assert_output --partial "| P1 local push (ms) | - |"
	assert_output --partial "|   n (got/attempted) | 0/2 |"
	refute_output --partial "n differs from the baseline"
}

@test "tuning 004: an invalid (restarted) row counts as attempted in n (R12)" {
	run "$COMPARE" --results-dir "$S" --format md
	assert_success
	# The restarted baseline row counts as attempted: 2 of 3 rows have a value.
	assert_output --partial "|   n (got/attempted) | 2/3 | 2/2 (baseline n 2/3) |"
	assert_output --partial "|   range (min to max) | 512 to 512 | 256 to 256 |"
}

@test "tuning 003 live: a profile that does not apply and a probe that fails are counted, the sweep finishes and exits 4 (R19)" {
	# python3 passes the PyYAML check and fails everything else (001-apply-profile cannot
	# load the profile: SETUP_FAILED); every kubectl call fails (the churn probe: PROBE_FAILED);
	# no Istio CR answers, so ISTIO_VERSION_CHECK=warn records unknown (R4).
	local bin="${BATS_TEST_TMPDIR}/bin" out="${BATS_TEST_TMPDIR}/res" d
	mkdir -p "$bin"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log"
	printf '#!/bin/sh\n[ "$*" = "-I -c import yaml" ] && exit 0\nexit 1\n' > "${bin}/python3"
	printf '#!/bin/sh\necho "$*" >> "$STUB_LOG"\nexit 1\n' > "${bin}/kubectl"
	chmod +x "${bin}/python3" "${bin}/kubectl"
	ISTIO_VERSION_CHECK=warn PATH="${bin}:${PATH}" run --separate-stderr "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" \
		--suite churn --contexts ci-a --no-gitops-pause --skip-setup --keep-workloads \
		--profiles 01-push-throttling --settle 0 --output-dir "$out"
	assert_failure 4
	[[ "$stderr" == *"warn: applying 01-push-throttling failed; marking SETUP_FAILED"* ]]
	[[ "$stderr" == *"warn: probe for baseline exited "*"; marking PROBE_FAILED"* ]]
	[[ "$stderr" == *"error: 2 of 2 cells failed: PROBE_FAILED x1, SETUP_FAILED x1. The report includes them as placeholder rows (in n_total, not n_valid); exit 4." ]]
	assert_output --partial "=== Sweep "
	d="$(find "$out" -maxdepth 1 -name 'sweep-*' -type d)"
	[ -f "${d}/baseline/PROBE_FAILED" ]
	[ -f "${d}/01-push-throttling/SETUP_FAILED" ]
	# The comparison is still written (PL32), and the sweep metadata records the version
	# the mesh answered: none, so unknown, next to the pin.
	[ -s "${d}/sweep-comparison.md" ]
	grep -qx '# ISTIO_VERSION=unknown' "${d}/sweep-metadata.txt"
	grep -qx '# ISTIO_VERSION_SOURCE=live' "${d}/sweep-metadata.txt"
	grep -q '^# ISTIO_VERSION_PIN=.' "${d}/sweep-metadata.txt"
	grep -qx '# ISTIO_VERSION_BY_CONTEXT=ci-a=unknown' "${d}/sweep-metadata.txt"
	# The probe inherited the sweep's reading: one Istio CR read in the whole run.
	[ "$(grep -c 'get istios.sailoperator.io default' "$STUB_LOG")" -eq 1 ]
}

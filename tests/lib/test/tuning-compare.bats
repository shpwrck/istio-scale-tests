#!/usr/bin/env bats
# tuning 004-compare-profiles through its real entrypoint: histogram p99 rows show the
# worst bucket (or overflow) instead of a mean of interpolated values, labels carry the
# right units (Mi, m, KiB, "peak"), and counts print as integers.

load test_helper
bats_require_minimum_version 1.5.0  # run --separate-stderr

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

# with_record <pass> [sed program]: put the platform record a current writer adds (edited by
# the sed program) at the top of that pass's TSV.
with_record() {
	local f
	f="$(ls "${S}/$1"/controlplane-*.tsv)"
	{ platform_fixture_lines | sed "${2:-}"; cat "$f"; } > "${f}.new"
	mv "${f}.new" "$f"
}

@test "tuning 004: each pass's platform record gets a row; a pass whose record differs from the baseline's warns" {
	with_record baseline
	with_record 01-x
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform | kubernetes | kubernetes |"
	assert_output --partial "| Mesh operator | sail-operator:1.31.1/Available | sail-operator:1.31.1/Available |"
	assert_output --partial "| Node provider | kind | kind |"
	refute_output --partial "**Warning:**"
	[ -z "$stderr" ]
	# The profile ran on another proxy build: its change is not the profile's alone.
	rm "${S}"/01-x/controlplane-*.tsv
	printf '%s\n' "$CP_HDR" $'t\t0\t256\t300\t250\t100\t400\t10240\t10' > "${S}/01-x/controlplane-r2.tsv"
	with_record 01-x 's/proxyv2:1.30.5/proxyv2:1.30.6/g'
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Proxy image | proxyv2:1.30.5 | proxyv2:1.30.6 |"
	assert_output --partial "- **Warning:** pass 01-x and the baseline differ on PROXY_IMAGE_BY_CONTEXT (baseline: ctx-a=proxyv2:1.30.5,ctx-b=proxyv2:1.30.5; 01-x: ctx-a=proxyv2:1.30.6,ctx-b=proxyv2:1.30.6)"
	[[ "$stderr" == *"warning: pass 01-x and the baseline differ on PROXY_IMAGE_BY_CONTEXT"* ]]
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_output --partial "WARNING: pass 01-x and the baseline differ on PROXY_IMAGE_BY_CONTEXT"
	# A pass from before the record reads unknown, and differs from a baseline that has one.
	rm "${S}"/01-x/controlplane-*.tsv
	printf '%s\n' "$CP_HDR" $'t\t0\t256\t300\t250\t100\t400\t10240\t10' > "${S}/01-x/controlplane-r2.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_output --partial "| Platform | kubernetes | unknown |"
	assert_output --partial "- **Warning:** pass 01-x and the baseline differ on PLATFORM"
}

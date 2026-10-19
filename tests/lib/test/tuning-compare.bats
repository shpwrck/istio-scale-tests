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

# digest <two hex digits>: a sha256 digest of that pair repeated, as the record holds one.
digest() { printf 'sha256:'; printf "${1}%.0s" {1..32}; }

# five_passes: a baseline and four profiles whose records carry full digests: 01-same as the
# baseline, 02-state only another operator state, 03-proxy another gateway proxy build,
# 04-legacy from before the record. Sets digests (the sed program that adds them).
five_passes() {
	local p
	rm -rf "$S"
	mkdir -p "$S"
	printf '# SUITE=controlplane\n# PASSES=baseline,01-same,02-state,03-proxy,04-legacy\n' > "${S}/sweep-metadata.txt"
	for p in baseline 01-same 02-state 03-proxy 04-legacy; do
		mkdir -p "${S}/${p}"
		printf '%s\n' "$CP_HDR" $'t\t0\t512\t300\t250\t99\t438\t20480\t10' > "${S}/${p}/controlplane-${p}.tsv"
	done
	digests="s/sail-operator:1.31.1/sail-operator:1.31.1@$(digest ab)/g; s/pilot:1.30.5/pilot:1.30.5@$(digest cd)/g; s/proxyv2:1.30.5/proxyv2:1.30.5@$(digest ef)/g"
	with_record baseline "$digests"
	with_record 01-same "$digests"
	with_record 02-state "${digests}; s#/Available#/Unavailable#g"
	with_record 03-proxy "${digests}; s/proxyv2:1.30.5@$(digest ef)/proxyv2:1.30.6@$(digest 01)/g"
}

@test "tuning 004 (H3): one Platform record row keeps the table narrow; a differing pass is flagged, a state-only operator difference is not" {
	five_passes
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | same | same | differs (see notes) | unknown (see notes) |"
	# Every table row stays well below 200 characters (it was 542 with six rows of full digests).
	local line widest=0
	while IFS= read -r line; do
		[[ "$line" == '|'* ]] || continue
		((${#line} <= widest)) || widest="${#line}"
	done <<<"$output"
	[ "$widest" -gt 0 ]
	[ "$widest" -lt 120 ]
	# The record once, after the table, digests shortened to 12 hex digits.
	assert_output --partial "### Platform record"
	assert_output --partial "- MESH_OPERATOR_BY_CONTEXT: \`sail-operator:1.31.1@sha256:abababababab/Available\`"
	assert_output --partial "- PROXY_IMAGE_BY_CONTEXT: \`proxyv2:1.30.5@sha256:efefefefefef\`"
	refute_output --partial "$(digest ef)"
	# The differing pass: its keys and values, a warning in the notes and on stderr.
	assert_output --partial "Pass 03-proxy, differs on PROXY_IMAGE_BY_CONTEXT:"
	assert_output --partial "- PROXY_IMAGE_BY_CONTEXT: \`proxyv2:1.30.6@sha256:010101010101\`"
	assert_output --partial "- **Warning:** pass 03-proxy differs from the baseline on PROXY_IMAGE_BY_CONTEXT (its values follow the table), so its change against the baseline is not the profile's alone"
	[[ "$stderr" == *"warning: pass 03-proxy differs from the baseline on PROXY_IMAGE_BY_CONTEXT"* ]]
	# A pass from before the record cannot be compared (unknown, not "differs"): one line after
	# the table, not a list of unknowns.
	assert_output --partial "Pass 04-legacy: every value of its platform record is unknown (its TSVs predate the record, or nothing could be read)."
	refute_output --partial "Pass 04-legacy, cannot be compared on"
	assert_output --partial "- **Warning:** pass 04-legacy: no key of its platform record can be compared with the baseline's (its TSVs predate the record, or nothing could be read)"
	refute_output --partial "04-legacy differs"
	# Available vs Unavailable is the same operator build: no warning, no block entry.
	refute_output --partial "02-state"$'\n'
	[[ "$output" != *"pass 02-state"* && "$output" != *"Pass 02-state"* ]]
	[[ "$stderr" != *"02-state"* ]]
	# Text: the same row, the block after the table, every table line narrow.
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_output --regexp 'Platform record +baseline +same +same +differs \(see notes\) +unknown \(see notes\)'
	assert_output --partial "WARNING: pass 03-proxy differs from the baseline on PROXY_IMAGE_BY_CONTEXT"
	assert_output --partial "Platform record of the baseline (digests shortened to 12 hex digits; the TSVs keep them in full):"
	assert_output --regexp '  PROXY_IMAGE_BY_CONTEXT +proxyv2:1.30.5@sha256:efefefefefef'
	assert_output --partial "Pass 04-legacy: every value of its platform record is unknown (its TSVs predate the record, or nothing could be read)."
	refute_output --partial "Pass 04-legacy, cannot be compared on"
	widest=0
	while IFS= read -r line; do
		[[ "$line" != "Platform record of"* ]] || break
		((${#line} <= widest)) || widest="${#line}"
	done < <(sed -n '/^Metric/,$p' <<<"$output")
	[ "$widest" -gt 0 ]
	[ "$widest" -lt 120 ]
}

@test "tuning 004: without a baseline, the first pass with data is the reference" {
	five_passes
	rm -rf "${S}/baseline"
	printf '# SUITE=controlplane\n# PASSES=01-same,02-state,03-proxy,04-legacy\n' > "${S}/sweep-metadata.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | reference | same | differs (see notes) | unknown (see notes) |"
	assert_output --partial "The pass 01-same (the first pass with data)'s (digests shortened"
	assert_output --partial "- **Warning:** pass 03-proxy differs from the pass 01-same (the first pass with data) on PROXY_IMAGE_BY_CONTEXT"
}

@test "tuning 004: a pass with one value not read names that key and its value after the table" {
	five_passes
	printf '%s\n' "$CP_HDR" $'t\t0\t512\t300\t250\t99\t438\t20480\t10' > "${S}/01-same/controlplane-01-same.tsv"
	with_record 01-same "${digests}; s/pilot:1.30.5@$(digest cd)/unknown/g"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | unknown (see notes) | same | differs (see notes) | unknown (see notes) |"
	assert_output --partial "Pass 01-same, cannot be compared on ISTIOD_IMAGE_BY_CONTEXT:"
	assert_output --partial "- ISTIOD_IMAGE_BY_CONTEXT: \`unknown\`"
	assert_output --partial "- **Warning:** pass 01-same: ISTIOD_IMAGE_BY_CONTEXT could not be compared with the baseline's (not read, or not recorded, in one of them)"
	refute_output --partial "Pass 01-same: every value"
}

@test "tuning 004: a pass whose TSVs disagree within it differs from the baseline" {
	five_passes
	# A second TSV in 01-same, on another istiod build: the pass's own record is mixed.
	{
		platform_fixture_lines | sed "${digests}; s/pilot:1.30.5@$(digest cd)/pilot:1.30.6@$(digest 23)/g"
		printf '%s\n' "$CP_HDR" $'t\t0\t512\t300\t250\t99\t438\t20480\t10'
	} > "${S}/01-same/controlplane-second.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Platform record | baseline | differs (see notes) | same | differs (see notes) | unknown (see notes) |"
	assert_output --partial "Pass 01-same, differs on ISTIOD_IMAGE_BY_CONTEXT:"
	# Both members hold both builds: the value they share, once.
	assert_output --partial "- ISTIOD_IMAGE_BY_CONTEXT: \`mixed:pilot:1.30.5@sha256:cdcdcdcdcdcd;pilot:1.30.6@sha256:232323232323\`"
}

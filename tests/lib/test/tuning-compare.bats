#!/usr/bin/env bats
# tuning 004-compare-profiles through its real entrypoint: its measurement rules (histogram p99
# rows show the worst bucket or overflow, never a mean; units Mi, m and KiB; n got/attempted and
# ranges; propagation counted as 005 counts it; one Connected proxies / cluster value per cluster
# scrape), each pass's platform record against the reference pass's (a key that differs warns
# with both values, one not read is a note), the istiod env and harness rows, and its refusals;
# and tuning 003 where it ends in 004. Both formats render one set of rows, warnings and notes:
# the table is checked in markdown, the text format where a line is its own.

bats_require_minimum_version 1.5.0
load test_helper

COMPARE="${ROOT}/tests/tuning/004-compare-profiles.sh"
CP_HDR=$'timestamp\tistiod_restarted\tistiod_mem_mi\tgo_heap_inuse_mi\tistiod_cpu_m_delta\tconvergence_p99_ms\txds_pushes_delta\tsidecar_config_bytes_avg\tconnected_proxies'
CD_HDR=$'run_id\tharness_sha\tcombo_id\tmesh_size\tchurn_rate\tphase\tduration_s\tqps_target\tqps_actual\tp50_ms\tp90_ms\tp99_ms\tp999_ms\tmax_ms\tdelta_p99_ms\tistiod_restarted\tstatus\tchurn_ops_attempted\tchurn_ops_succeeded\txds_pushes_delta\teds_pushes_delta\tpush_triggers_delta\tconvergence_p99_ms\tqueue_time_p99_ms\tpush_time_p99_ms'

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

# PROP_HDR / prop_row: the propagation endpoint TSV (19 columns, as 002 writes it).
# prop_row <iteration> <remote> <p1_ms> <status> <p1_conv_p99_ms> [<p2_ms>]: p3 60 ms.
PROP_HDR=$'run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms'
prop_row() {
	local p2="${6:-50}" p3=60
	[[ "$4" == OK ]] || { p2=N/A p3=N/A; }
	printf 'r1\t2\t%s\tsrc\t%s\t0\t%s\t%s\t%s\t%s\t99\t%s\t10/10\t10\t0\t0\t0\t5000\t10\n' "$1" "$2" "$3" "$p2" "$p3" "$4" "$5"
}

@test "tuning 004: a histogram p99 row is the worst bucket a valid row hit or overflow (N rows; N iterations for propagation's P1 convergence), never a mean or a better bucket" {
	local i r P="${BATS_TEST_TMPDIR}/psweep5"
	run "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Convergence p99 worst bucket (ms) | 500-1000 | overflow (1 row) |"
	refute_output --partial "349.50"
	# The text table, laid out by its own code.
	run "$COMPARE" --results-dir "$S"
	assert_output --regexp 'Convergence p99 worst bucket \(ms\) +500-1000 +overflow \(1 row\)'
	mkdir -p "${P}/baseline" "${P}/01-x"
	printf '# SUITE=propagation\n# PASSES=baseline,01-x\n' > "${P}/sweep-metadata.txt"
	{
		echo "# RUN_ID=r1"
		echo "$PROP_HDR"
		for i in 1 2 3 4 5; do for r in b c; do prop_row "$i" "$r" 100 OK 1000; done; done
	} > "${P}/baseline/endpoint-r1.tsv"
	# Iterations 2, 3 and 4 overflowed (+Inf; every remote row carries p1_overflow=1); in
	# iteration 5 istiod also restarted, which drops it before the overflow counts.
	{
		echo "# RUN_ID=r2"
		echo "$PROP_HDR"
		for i in 1 2 3 4 5; do for r in b c; do prop_row "$i" "$r" 100 OK 99; done; done \
			| awk -F'\t' 'BEGIN { OFS = "\t" } $3 >= 2 && $3 <= 4 { $15 = 1 } $3 == 5 { $15 = 1; $16 = 1 } 1'
	} > "${P}/01-x/endpoint-r2.tsv"
	run "$COMPARE" --results-dir "$P" --format md
	assert_success
	# An older report read 0-100 for the profile (better than the baseline's 500-1000) from its one
	# clean iteration.
	[[ "$output" == *"| P1 convergence p99 worst bucket (ms) | 500-1000 | overflow (3 iterations) |"$'\n'"|   n (got/attempted) | 5/5 | 4/5 (baseline n 5/5) |"* ]]
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

@test "tuning 004: the settle time and a churn-dataplane sweep's churn rate, as the sweep recorded them, are in both formats' header and the markdown frontmatter" {
	local f pfx p cd="${BATS_TEST_TMPDIR}/cdsweep"
	mkdir -p "${cd}/baseline" "${cd}/01-x"
	printf '# SUITE=churn-dataplane\n# PASSES=baseline,01-x\n# SETTLE_SEC=60\n# CHURN_RATE=5\n' > "${cd}/sweep-metadata.txt"
	for p in baseline 01-x; do
		{
			echo "$CD_HDR"
			printf 'r1\tsha\tc1\t2\t0\tbaseline\t60\t50\t50\t2\t3\t5\t6\t7\tN/A\t0\tOK\t10\t10\t100\tN/A\t5\tN/A\tN/A\tN/A\n'
			printf 'r1\tsha\tc1\t2\t5\tchurn\t60\t50\t48\t4\t3\t9\t6\t7\tN/A\t0\tOK\t10\t10\t100\t30\t5\t99\tN/A\tN/A\n'
		} > "${cd}/${p}/churn-dataplane-${p}.tsv"
	done
	for f in text md; do
		pfx=""
		[[ "$f" != md ]] || pfx="- "
		run --separate-stderr "$COMPARE" --results-dir "$cd" --format "$f"
		assert_success
		assert_line --regexp "^${pfx}SETTLE_SEC=60 "
		assert_line --regexp "^${pfx}CHURN_RATE=5 "
	done
	# In the frontmatter as bare numbers.
	[ "$(sed -n '2,/^---$/p' <<<"$output" | grep -cx 'settle_sec: 60\|churn_rate: 5')" = 2 ]
}

# tsv_record [sed program]: the preamble lines a suite TSV of a tuning pass carries, edited by
# the sed program: each member's Kubernetes version (tests/lib/preamble.sh), then the platform
# record (members ctx-a,ctx-b).
tsv_record() {
	{ echo "# KUBE_VERSIONS=ctx-a=v1.33.1,ctx-b=v1.33.1"; platform_fixture_lines; } | sed "${1:-}"
}

# digest <two hex digits>: a sha256 digest of that pair repeated, as the record holds one.
digest() { printf 'sha256:'; printf "${1}%.0s" {1..32}; }

# rec_sweep <pass>...: a controlplane sweep of the baseline and those passes, each with one TSV of
# one valid row under the record tsv_record makes. rec_edit <pass> <sed program> edits that TSV;
# rec_second <pass> [sed program] adds a second TSV to the pass, its record edited by the program;
# with_keys <pass> <KEY=value>... puts those preamble keys at the top of the pass's TSV.
rec_sweep() {
	local p
	rm -rf "$S"
	mkdir -p "$S"
	printf '# SUITE=controlplane\n# PASSES=%s\n' "$(IFS=,; echo "baseline,$*")" > "${S}/sweep-metadata.txt"
	for p in baseline "$@"; do
		mkdir -p "${S}/${p}"
		{ tsv_record; printf '%s\n' "$CP_HDR" $'t\t0\t512\t300\t250\t99\t438\t20480\t10'; } > "${S}/${p}/controlplane-${p}.tsv"
	done
}
rec_edit() { sed -i "$2" "${S}/$1/controlplane-$1.tsv"; }
rec_second() { { tsv_record "${2:-}"; printf '%s\n' "$CP_HDR" $'t\t0\t512\t300\t250\t99\t438\t20480\t10'; } > "${S}/$1/controlplane-second.tsv"; }
with_keys() {
	local f="${S}/$1/controlplane-$1.tsv"
	shift
	{ printf '# %s\n' "$@"; cat "$f"; } > "${f}.new"
	mv "${f}.new" "$f"
}
SO_BASE="so its change against the baseline is not the profile's alone"

@test "tuning 004: a pass whose platform record differs from the reference pass's (the baseline, else the first pass with data) reads differs and warns with both values, in both formats and on stderr; one that matches reads same; the tuning levers, egress hosts and istiod limits and replica counts are compared as the TSVs record them" {
	local p levers="sidecar=on,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on"
	rec_sweep 01-same 02-proxy
	rec_edit 02-proxy "/^# PROXY_IMAGE_BY_CONTEXT=/s/ctx-b=proxyv2:1.30.5/ctx-b=proxyv2:1.30.6@$(digest 01)/"
	local w="pass 02-proxy: PROXY_IMAGE_BY_CONTEXT is proxyv2:1.30.5 (1 member), proxyv2:1.30.6@sha256:010101010101 (1 member), against proxyv2:1.30.5 in the baseline, ${SO_BASE}"
	local rec="kubernetes (TEST_PLATFORM auto); nodes kind; operator sail-operator:1.31.1; istiod pilot:1.30.5; gateway proxy proxyv2:1.30.5; Kubernetes v1.33.1"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_line "| Platform record | baseline | same | differs (see warnings) |"
	assert_line "- Platform record of the baseline: ${rec}"
	# Both values without the members' names, digests shortened (the TSVs keep them in full).
	assert_line "- **Warning:** ${w}"
	refute_output --partial "$(digest 01)"
	refute_output --partial "pass 01-same"
	[ "$(grep -c '^warning: ' <<<"$stderr")" -eq 1 ]
	[[ "$stderr" == *"warning: ${w}"* ]]
	run --separate-stderr "$COMPARE" --results-dir "$S"
	assert_success
	assert_line "Platform record of the baseline: ${rec}"
	assert_line "WARNING: ${w}"
	# Without a baseline, the first pass with data is the reference.
	rec_sweep 01-a 02-b
	rm -rf "${S}/baseline"
	printf '# SUITE=controlplane\n# PASSES=01-a,02-b\n' > "${S}/sweep-metadata.txt"
	rec_edit 02-b "s/pilot:1.30.5/pilot:1.30.6/g"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_line "| Platform record | reference | differs (see warnings) |"
	assert_line --partial "- **Warning:** pass 02-b: ISTIOD_IMAGE_BY_CONTEXT is pilot:1.30.6, against pilot:1.30.5 in the reference pass (01-a, the first with data)"
	refute_output --partial "$SO_BASE"
	# The keys the TSVs record past the platform's.
	rec_sweep 01-lever 02-hosts 03-limit 04-replicas
	for p in baseline 01-lever 02-hosts 03-limit 04-replicas; do
		with_keys "$p" "TUNING_BASELINE=${levers}" "SIDECAR_EGRESS_HOSTS=./* istio-system/*" ISTIOD_LIM_CPU_M=2000 \
			ISTIOD_REPLICAS=1 ISTIOD_REPLICAS_BY_CONTEXT=ctx-a=1,ctx-b=1
	done
	rec_edit 01-lever "s/^# TUNING_BASELINE=sidecar=on/# TUNING_BASELINE=sidecar=off/"
	rec_edit 02-hosts "s|^# SIDECAR_EGRESS_HOSTS=.*|# SIDECAR_EGRESS_HOSTS=none|"
	rec_edit 03-limit "s/^# ISTIOD_LIM_CPU_M=2000/# ISTIOD_LIM_CPU_M=4000/"
	rec_edit 04-replicas "s/^# ISTIOD_REPLICAS=1/# ISTIOD_REPLICAS=1-2/; s/^# ISTIOD_REPLICAS_BY_CONTEXT=.*/# ISTIOD_REPLICAS_BY_CONTEXT=ctx-a=1,ctx-b=2/"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_line "| Platform record | baseline | differs (see warnings) | differs (see warnings) | differs (see warnings) | differs (see warnings) |"
	assert_line "- **Warning:** pass 01-lever: TUNING_BASELINE is sidecar=off,discoverySelectors=on,telemetryFiltering=on,accessLogFiltering=on, against ${levers} in the baseline, ${SO_BASE}"
	assert_line "- **Warning:** pass 02-hosts: SIDECAR_EGRESS_HOSTS is none, against ./* istio-system/* in the baseline, ${SO_BASE}"
	assert_line "- **Warning:** pass 03-limit: ISTIOD_LIM_CPU_M is 4000, against 2000 in the baseline, ${SO_BASE}"
	# The controlplane's ISTIOD_REPLICAS summarizes its ISTIOD_REPLICAS_BY_CONTEXT: one warning.
	assert_line "- **Warning:** pass 04-replicas: ISTIOD_REPLICAS_BY_CONTEXT is 1 (1 member), 2 (1 member), against 1 in the baseline, ${SO_BASE}"
	[ "$(grep -c '^- \*\*Warning:\*\* pass 04-replicas: ' <<<"$output")" -eq 1 ]
	# No TSV records istiod's memory limit: nothing is said of it.
	refute_output --partial "ISTIOD_LIM_MEM_MI"
	[ "$(grep -c '^warning: ' <<<"$stderr")" -eq 4 ]
}

@test "tuning 004: the istiod env row is each pass's one digest, partly unknown, unknown or mixed; a profile changes it, so it is never compared" {
	rec_sweep 01-env 02-mixed 03-part 04-none
	rec_edit 01-env "/^# ISTIOD_ENV_BY_CONTEXT=/s/0123456789ab/fedcba987654/g"
	rec_edit 02-mixed "/^# ISTIOD_ENV_BY_CONTEXT=/s/ctx-b=0123456789ab/ctx-b=fedcba987654/"
	rec_edit 03-part "/^# ISTIOD_ENV_BY_CONTEXT=/s/ctx-b=0123456789ab/ctx-b=unknown/"
	rec_edit 04-none "/^# ISTIOD_ENV_BY_CONTEXT=/s/=0123456789ab/=unknown/g"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_line "| istiod env | 0123456789ab | fedcba987654 | mixed | 0123456789ab (partly unknown) | unknown |"
	assert_line "| Platform record | baseline | same | same | same | same |"
	refute_output --partial "ISTIOD_ENV_BY_CONTEXT"
	[ -z "$stderr" ]
	# Two TSVs of one pass on different settings: mixed.
	rec_second 01-env
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_line "| istiod env | 0123456789ab | mixed | mixed | 0123456789ab (partly unknown) | unknown |"
}

@test "tuning 004: a key not read, or not recorded, on a side is one note and reads unknown, never same or differs, also when neither side read it; a key that differs still warns" {
	rec_sweep 01-kube 02-old 03-both 04-legacy
	# 01-kube: ctx-b's Kubernetes version not read; 02-old: a second TSV from before the node
	# provider key; 03-both: istiod's digest not read on ctx-a, and another gateway proxy build;
	# 04-legacy: a TSV from before the record.
	rec_edit 01-kube "s/^# KUBE_VERSIONS=.*/# KUBE_VERSIONS=ctx-a=v1.33.1,ctx-b=unreachable/"
	rec_second 02-old "/^# NODE_PROVIDER_BY_CONTEXT=/d"
	rec_edit 03-both "/^# ISTIOD_IMAGE_BY_CONTEXT=/s/ctx-a=pilot:1.30.5/ctx-a=pilot:1.30.5@unknown/; s/proxyv2:1.30.5/proxyv2:1.30.6/g"
	rec_edit 04-legacy "/^# [A-Z_]*=/d"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_line "| Platform record | baseline | unknown (see notes) | unknown (see notes) | differs (see warnings) | unknown (see notes) |"
	assert_line "- Note: pass 01-kube: KUBE_VERSIONS is not known to match the baseline (not read, or not recorded, on one side): v1.33.1 (1 member), unreachable (1 member), against v1.33.1 in the baseline"
	assert_line "- Note: pass 02-old: NODE_PROVIDER_BY_CONTEXT is not known to match the baseline (not read, or not recorded, on one side): mixed:unknown, kind (2 members), against kind in the baseline"
	assert_line "- Note: pass 03-both: ISTIOD_IMAGE_BY_CONTEXT is not known to match the baseline (not read, or not recorded, on one side): pilot:1.30.5@unknown (1 member), pilot:1.30.5 (1 member), against pilot:1.30.5 in the baseline"
	assert_line "- **Warning:** pass 03-both: PROXY_IMAGE_BY_CONTEXT is proxyv2:1.30.6, against proxyv2:1.30.5 in the baseline, ${SO_BASE}"
	# A pass from before the record: each key one note, no warning of its own.
	assert_line "- Note: pass 04-legacy: PROXY_IMAGE_BY_CONTEXT is not known to match the baseline (not read, or not recorded, on one side): unknown, against proxyv2:1.30.5 in the baseline"
	[ "$(grep -c '^- Note: pass 04-legacy: ' <<<"$output")" -eq 8 ]
	refute_output --partial "Warning:** pass 04-legacy"
	[ "$(grep -c '^- Note: ' <<<"$output")" -eq 11 ]
	[ "$(grep -c '^warning: ' <<<"$stderr")" -eq 1 ]
	# Not read on both sides is not the same either (PL61).
	rec_edit baseline "s/^# KUBE_VERSIONS=.*/# KUBE_VERSIONS=ctx-a=v1.33.1,ctx-b=unreachable/"
	rm -rf "${S}/02-old/controlplane-second.tsv" "${S}/03-both" "${S}/04-legacy"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_line "| Platform record | baseline | unknown (see notes) | unknown (see notes) | - | - |"
	assert_line "- Note: pass 01-kube: KUBE_VERSIONS is not known to match the baseline (not read, or not recorded, on one side): v1.33.1 (1 member), unreachable (1 member), against v1.33.1 (1 member), unreachable (1 member) in the baseline"
}

@test "tuning 004: a pass whose TSVs ran two builds differs from a baseline that ran one, and the other way round; the same two on both sides are the same" {
	rec_sweep 01-two
	rec_second 01-two "s/pilot:1.30.5/pilot:1.30.6@$(digest 23)/g"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_line "| Platform record | baseline | differs (see warnings) |"
	assert_line "- **Warning:** pass 01-two: ISTIOD_IMAGE_BY_CONTEXT is mixed: pilot:1.30.5 and pilot:1.30.6@sha256:232323232323, against pilot:1.30.5 in the baseline, ${SO_BASE}"
	cp "${S}/01-two/controlplane-second.tsv" "${S}/baseline/"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_line "| Platform record | baseline | same |"
	rm "${S}/01-two/controlplane-second.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_line "| Platform record | baseline | differs (see warnings) |"
	assert_line "- **Warning:** pass 01-two: ISTIOD_IMAGE_BY_CONTEXT is pilot:1.30.5, against mixed: pilot:1.30.5 and pilot:1.30.6@sha256:232323232323 in the baseline, ${SO_BASE}"
}

@test "tuning 004: HARNESS_SHA is in the header; a row of each pass's only when one differs from it, with a warning when the passes ran different harnesses" {
	printf '# HARNESS_SHA=abc1234\n' >> "${S}/sweep-metadata.txt"
	sed -i '1i # HARNESS_SHA=abc1234' "${S}/baseline/controlplane-r1.tsv" "${S}/01-x/controlplane-r2.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_line "- HARNESS_SHA=abc1234 (the sweep's)"
	refute_output --partial "| Harness (HARNESS_SHA) |"
	refute_output --partial "different harnesses"
	sed -i 's/^# HARNESS_SHA=abc1234$/# HARNESS_SHA=def5678-dirty/' "${S}/01-x/controlplane-r2.tsv"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_line "| Harness (HARNESS_SHA) | abc1234 | def5678-dirty |"
	assert_line --partial "- **Warning:** the passes ran on different harnesses (HARNESS_SHA baseline abc1234; 01-x def5678-dirty)"
	[[ "$stderr" == *"WARNING: the passes ran on different harnesses"* ]]
}

@test "tuning 004: the sweep's outcome comes before the table: a build that changed during a pass is an error there" {
	local pr="PROXY_IMAGE_BY_CONTEXT on ctx-b changed during the 01-x pass: proxyv2:1.30.5 at its start, proxyv2:1.30.6 at its end: its rows are not all from one build"
	printf '%s\n' STATUS=finished RUN_ID=r1 HARNESS_SHA=unknown UNIT=passes EXIT=4 TOTAL=2 FAILED=0 SKIPPED=0 "PROBLEM=${pr}" > "${S}/sweep-outcome.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_line "> **Sweep outcome** (\`sweep\`): **finished**, exit 4"
	[[ "$output" == *"> - error: ${pr}"*"| Metric |"* ]]
}

@test "tuning 004 (U9-N5, U10-S1, U11-S1): what is not a tuning sweep is refused, naming what to give instead, as is an unknown --format; a pass the metadata lists without its directory shows no data" {
	run --separate-stderr "$COMPARE" --results-dir "$S" --format html
	assert_failure
	[[ "$stderr" == *"--format must be text or md (or markdown), not html"* ]]
	mkdir -p "${BATS_TEST_TMPDIR}/empty"
	run --separate-stderr "$COMPARE" --results-dir "${BATS_TEST_TMPDIR}/empty"
	assert_failure
	[[ "$stderr" == *"no pass directories in ${BATS_TEST_TMPDIR}/empty: give a tuning sweep directory"* ]]
	# A pass directory (its state/ is no pass), or another suite's sweep: the TSVs are its own.
	mkdir -p "${S}/01-x/state"
	run --separate-stderr "$COMPARE" --results-dir "${S}/01-x"
	assert_failure
	[[ "$stderr" == *"${S}/01-x holds TSVs itself (a pass directory, or another suite's sweep): give a tuning sweep directory"* ]]
	mkdir -p "${BATS_TEST_TMPDIR}/sweep-prop/logs"
	printf '%s\n' $'p1_ms\tp2_ms\tp3_ms' $'1\t2\t3' > "${BATS_TEST_TMPDIR}/sweep-prop/propagation-r1.tsv"
	run --separate-stderr "$COMPARE" --results-dir "${BATS_TEST_TMPDIR}/sweep-prop"
	assert_failure
	[[ "$stderr" == *"${BATS_TEST_TMPDIR}/sweep-prop holds TSVs itself"* ]]
	# A pass the metadata lists without its directory, before any with data (no SUITE line: the
	# first pass with a TSV names it): no data.
	printf '# PASSES=03-gone,baseline,01-x\n' > "${S}/sweep-metadata.txt"
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "- Suite: controlplane"
	assert_output --partial "| Pass status | no data | ok | ok |"
	assert_output --partial "| Valid / total rows | 0/0 | 2/3 | 2/2 |"
	assert_output --partial "| istiod memory peak (Mi) | - | 512 | 256 (-50.0%) |"
	# The directory that holds the sweeps (tests/tuning/results): it names the last of them.
	mkdir -p "${BATS_TEST_TMPDIR}/results"
	cp -r "$S" "${BATS_TEST_TMPDIR}/results/sweep-20260101T000000Z-1"
	cp -r "$S" "${BATS_TEST_TMPDIR}/results/sweep-20260102T000000Z-1"
	run --separate-stderr "$COMPARE" --results-dir "${BATS_TEST_TMPDIR}/results"
	assert_failure
	[[ "$stderr" == *"(the last by name: ${BATS_TEST_TMPDIR}/results/sweep-20260102T000000Z-1)"* ]] || { echo "$stderr"; false; }
}

@test "tuning 004: every metric shows n got/attempted and its range, attempted being what the probe was configured to run (PL17), a restarted row included; a metric no valid row has shows n 0/N; a profile whose n differs is flagged" {
	local i r P="${BATS_TEST_TMPDIR}/psweep" P0="${BATS_TEST_TMPDIR}/psweep0" P4="${BATS_TEST_TMPDIR}/psweep4" C="${BATS_TEST_TMPDIR}/csweep"
	# The restarted baseline row counts as attempted: 2 of 3 rows have a value.
	run "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "|   n (got/attempted) | 2/3 | 2/2 (baseline n 2/3) |"
	assert_output --partial "|   range (min to max) | 512 to 512 | 256 to 256 |"
	mkdir -p "${P}/baseline" "${P}/01-x"
	printf '# SUITE=propagation\n# PASSES=baseline,01-x\n' > "${P}/sweep-metadata.txt"
	{
		echo "$PROP_HDR"
		for i in 1 2 3 4; do prop_row "$i" b "${i}00" OK 99; done
	} > "${P}/baseline/endpoint-r1.tsv"
	# The profile timed out on 2 of 4 iterations: its P1 mean (110) looks better
	# than the baseline's (250) only because the slow iterations are missing.
	{
		echo "$PROP_HDR"
		prop_row 1 b 100 OK 99
		prop_row 2 b 120 OK 500
		prop_row 3 b TIMEOUT TIMEOUT_P1 N/A
		prop_row 4 b TIMEOUT TIMEOUT_P1 N/A
	} > "${P}/01-x/endpoint-r2.tsv"
	run "$COMPARE" --results-dir "$P" --format md
	assert_success
	assert_output --partial "| P1 local push (ms) | 250.00 | 110.00 (-56.0%) |"
	assert_output --partial "|   n (got/attempted) | 4/4 | 2/4 (baseline n 4/4) |"
	assert_output --partial "|   range (min to max) | 100.00 to 400.00 | 100.00 to 120.00 |"
	assert_output --partial "|   range (min to max) | 0-100 to 0-100 | 0-100 to 100-500 |"
	assert_output --partial "n differs from the baseline"
	# No valid row: n 0/2, the metric still shown.
	mkdir -p "${P0}/baseline"
	printf '# SUITE=propagation\n# PASSES=baseline\n' > "${P0}/sweep-metadata.txt"
	{
		echo "$PROP_HDR"
		prop_row 1 b TIMEOUT TIMEOUT_P1 N/A
		prop_row 2 b TIMEOUT TIMEOUT_P1 N/A
	} > "${P0}/baseline/endpoint-r1.tsv"
	run "$COMPARE" --results-dir "$P0" --format md
	assert_success
	assert_output --partial "| P1 local push (ms) | - |"
	assert_output --partial "|   n (got/attempted) | 0/2 |"
	refute_output --partial "n differs from the baseline"
	# The profile's probe stopped after 2 of its 4 iterations: 2/4, not 2/2.
	mkdir -p "${P4}/baseline" "${P4}/01-x"
	printf '# SUITE=propagation\n# PASSES=baseline,01-x\n' > "${P4}/sweep-metadata.txt"
	{
		printf '# RUN_ID=r1\n# ITERATIONS=4\n# REMOTES=b c\n'
		echo "$PROP_HDR"
		for i in 1 2 3 4; do for r in b c; do prop_row "$i" "$r" 100 OK 99; done; done
	} > "${P4}/baseline/endpoint-r1.tsv"
	{
		printf '# RUN_ID=r2\n# ITERATIONS=4\n# REMOTES=b c\n'
		echo "$PROP_HDR"
		for i in 1 2; do for r in b c; do prop_row "$i" "$r" 100 OK 99; done; done
	} > "${P4}/01-x/endpoint-r2.tsv"
	run "$COMPARE" --results-dir "$P4" --format md
	assert_success
	[[ "$output" == *"| P1 local push (ms) | 100.00 | 100.00 (+0.0%) |"$'\n'"|   n (got/attempted) | 4/4 | 2/4 (baseline n 4/4) |"* ]]
	[[ "$output" == *"| P2 remote EDS (ms) | 50.00 | 50.00 (+0.0%) |"$'\n'"|   n (got/attempted) | 8/8 | 4/8 (baseline n 8/8) |"* ]]
	assert_output --partial "| Valid / total rows | 8/8 | 4/4 |"
	# churn: its Iterations line.
	mkdir -p "${C}/baseline"
	printf '# SUITE=churn\n# PASSES=baseline\n' > "${C}/sweep-metadata.txt"
	{
		echo "# Deployments: 2  Scale: 1 -> 5  Iterations: 5"
		printf 'run_id\titeration\tconvergence_local_ms\tstatus\n'
		printf 'r1\t1\t100\tOK\nr1\t2\t200\tOK\n'
	} > "${C}/baseline/churn-r1.tsv"
	run "$COMPARE" --results-dir "$C" --format md
	assert_success
	[[ "$output" == *"| Local convergence (ms) | 150.00 |"$'\n'"|   n (got/attempted) | 2/5 |"* ]]
}

@test "tuning 004: a propagation pass counts what 005 counts: P1 once per iteration, the same n and mean" {
	P="${BATS_TEST_TMPDIR}/psweep3"
	mkdir -p "${P}/baseline"
	printf '# SUITE=propagation\n# PASSES=baseline\n' > "${P}/sweep-metadata.txt"
	local i r
	{
		echo "# RUN_ID=r1"
		echo "$PROP_HDR"
		# 5 iterations x 3 remotes; P1 is the source's, repeated on each remote's row.
		for i in 1 2 3 4 5; do for r in b c d; do prop_row "$i" "$r" "$((100 * i))" OK 99; done; done
		# A dirty P2 (EDS bumped, canary never healthy) and a skewed row, both as 005 sees them.
		printf 'r1\t2\t6\tsrc\tb\t0\t600\t70\t60\tOK\t99\t99\t10/10\t10\t0\t0\t1\t5000\t10\n'
		printf 'r1\t2\t7\tsrc\tb\t0\t700\t50\t60\tOK\t99\t99\t10/10\t10\t0\t0\t0\t5000\t5000\n'
	} > "${P}/baseline/endpoint-r1.tsv"
	run "$COMPARE" --results-dir "$P" --format md
	assert_success
	# P1 over iterations 1-6 (the skewed 7th is dropped): mean 350, n 6; P2 15 clean of 16 rows.
	# Without ITERATIONS in the preamble, P1 is attempted once per iteration the pass wrote (7),
	# not per row (17).
	[[ "$output" == *"| P1 local push (ms) | 350.00 |"$'\n'"|   n (got/attempted) | 6/7 |"* ]]
	[[ "$output" == *"| P2 remote EDS (ms) | 50.00 |"$'\n'"|   n (got/attempted) | 15/17 |"* ]]
	# 005 on the same rows: the same n and mean (its stderr warns that the TSV predates the
	# platform record).
	run --separate-stderr "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "${P}/baseline" --format json
	assert_success
	[ "$(jq -c '[.rows[] | select(.phase == "P1_local_wall" or .phase == "P2_discovery") | [.phase, .n_valid, .avg_ms]]' <<<"$output")" = \
		'[["P1_local_wall",6,350],["P2_discovery",15,50]]' ]
}

@test "tuning 003 live: a profile that does not apply and a probe that fails are counted, the sweep finishes, writes its comparison and exits 4" {
	# python3 passes the PyYAML check and the profile name check and fails everything else
	# (001-apply-profile cannot load the profile: SETUP_FAILED); every kubectl call but the list of
	# tuning profile objects (none) fails (the churn probe: PROBE_FAILED);
	# no Istio CR answers, so ISTIO_VERSION_CHECK=warn records unknown.
	local bin="${BATS_TEST_TMPDIR}/bin" out="${BATS_TEST_TMPDIR}/res" d
	mkdir -p "$bin"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log"
	printf '#!/bin/sh\n[ "$*" = "-I -c import yaml" ] && exit 0\ncase "$*" in *"/tuning.py check-name "*) exit 0 ;; esac\nexit 1\n' > "${bin}/python3"
	cat > "${bin}/kubectl" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
case "$*" in *" -l istio-scale-tests/tuning-profile "*) echo '{"kind":"List","items":[]}'; exit 0 ;; esac
exit 1
EOF
	chmod +x "${bin}/python3" "${bin}/kubectl"
	ISTIO_VERSION_CHECK=warn PATH="${bin}:${PATH}" run --separate-stderr "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" \
		--suite churn --contexts ci-a --no-gitops-pause --skip-setup --keep-workloads \
		--profiles 01-push-throttling --settle 0 --output-dir "$out"
	assert_failure 4
	[[ "$stderr" == *"error: 2 of 2 passes failed: PROBE_FAILED x1, SETUP_FAILED x1."* ]]
	d="$(find "$out" -maxdepth 1 -name 'sweep-*' -type d)"
	[ -f "${d}/baseline/PROBE_FAILED" ]
	[ -f "${d}/01-push-throttling/SETUP_FAILED" ]
	# The comparison is still written (PL32), its outcome first; the sweep metadata records the
	# version the mesh answered: none, so unknown, next to the pin.
	grep -qF "> **Sweep outcome** (\`${d##*/}\`): **finished**, exit 4" "${d}/sweep-comparison.md"
	grep -qx 'EXIT=4' "${d}/sweep-outcome.txt"
	grep -qx '# ISTIO_VERSION=unknown' "${d}/sweep-metadata.txt"
	grep -q '^# ISTIO_VERSION_PIN=.' "${d}/sweep-metadata.txt"
	grep -qx '# ISTIO_VERSION_BY_CONTEXT=ci-a=unknown' "${d}/sweep-metadata.txt"
}

@test "tuning 003 --suite controlplane without timeout or gtimeout: stops at startup, before any profile or kubectl call" {
	# A PATH with every tool but timeout and gtimeout (the first of each name, linked one PATH
	# directory at a time), a python3 that passes the PyYAML check and the profile name check,
	# and a kubectl that logs its calls.
	local d="${BATS_TEST_TMPDIR}/path" out="${BATS_TEST_TMPDIR}/res" p
	local -a dirs
	mkdir -p "$d"
	IFS=: read -r -a dirs <<<"$PATH"
	for p in "${dirs[@]}"; do
		[[ -d "$p" ]] || continue
		ln -s "$p"/* "$d"/ 2>/dev/null || true
	done
	rm -f "${d}/timeout" "${d}/gtimeout" "${d}/kubectl" "${d}/oc" "${d}/python3"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log"
	printf '#!/bin/sh
[ "$*" = "-I -c import yaml" ] && exit 0
case "$*" in *"/tuning.py check-name "*) exit 0 ;; esac
exit 1
' > "${d}/python3"
	printf '#!/bin/sh
echo "$*" >> "$STUB_LOG"
exit 1
' > "${d}/kubectl"
	chmod +x "${d}/python3" "${d}/kubectl"
	PATH="$d" run --separate-stderr "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" \
		--suite controlplane --contexts ci-a --no-gitops-pause --skip-setup --keep-workloads \
		--profiles 01-push-throttling --settle 0 --output-dir "$out"
	assert_failure 1
	[[ "$stderr" == *"error: neither 'timeout' nor 'gtimeout' (GNU coreutils) is on PATH"*"brew install coreutils"* ]]
	[ ! -s "$STUB_LOG" ]
	[ -z "$(find "$out" -name 'sweep-metadata.txt' 2>/dev/null)" ]
	# Another suite does not need it: the sweep goes on to its first kubectl call (the list of
	# tuning profile objects, which fails here and stops it: a member that cannot be asked may
	# hold a profile's objects).
	PATH="$d" run --separate-stderr "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" \
		--suite churn --contexts ci-a --no-gitops-pause --skip-setup --keep-workloads \
		--profiles 01-push-throttling --settle 0 --output-dir "$out"
	assert_failure 1
	[[ "$stderr" != *"timeout"*"gtimeout"* ]]
	[[ "$stderr" == *"the tuning profile objects (label istio-scale-tests/tuning-profile) could not be listed on ci-a"* ]]
	[ -s "$STUB_LOG" ]
}

# cp_cluster_tsv <file> <row>...: a controlplane TSV with timestamp, context, istiod_restarted,
# istiod_mem_mi, connected_proxies and cluster_connected_proxies (M13-S1).
cp_cluster_tsv() {
	local f="$1"
	shift
	{
		printf 'timestamp\tcontext\tistiod_restarted\tistiod_mem_mi\tconnected_proxies\tcluster_connected_proxies\n'
		printf '%b\n' "$@"
	} > "$f"
}

@test "tuning 004 (M13-S1): Connected proxies / cluster takes one value per cluster scrape, not one per istiod pod row, and none from a scrape with a restarted istiod pod, as the controlplane report has it" {
	cp_cluster_tsv "${S}/baseline/controlplane-r1.tsv" 't1\tctx-a\t0\t500\t1000\t1000' 't1\tctx-b\t0\t500\t100\t100' \
		't2\tctx-a\t0\t500\t1000\t1000' 't2\tctx-b\t0\t500\t100\t100'
	# 01-x: ctx-a on two istiod replicas (an HPA); no cluster's proxies changed.
	cp_cluster_tsv "${S}/01-x/controlplane-r2.tsv" 't1\tctx-a\t0\t500\t500\t1000' 't1\tctx-a\t0\t500\t500\t1000' 't1\tctx-b\t0\t500\t100\t100' \
		't2\tctx-a\t0\t500\t500\t1000' 't2\tctx-a\t0\t500\t500\t1000' 't2\tctx-b\t0\t500\t100\t100'
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Valid / total rows | 4/4 | 6/6 |"
	assert_output --partial "| Connected proxies / istiod replica | 550 | 366.7 (-33.3%) |"
	# Its n counts cluster scrapes: four in each pass.
	assert_output --regexp '\| Connected proxies / cluster \| 550 \| 550 \(\+0\.0%\) \|
\|   n \(got/attempted\) \| 4/4 \| 4/4 \|
\|   range \(min to max\) \| 100 to 1000 \| 100 to 1000 \|'
	cp_cluster_tsv "${S}/baseline/controlplane-r1.tsv" 't1\tctx-a\t0\t500\t500\t1000' 't1\tctx-a\t0\t500\t500\t1000' 't1\tctx-b\t0\t500\t1000\t1000'
	# 01-x: one of ctx-a's two istiod pods restarted; its sibling's row carries the cluster's sum.
	cp_cluster_tsv "${S}/01-x/controlplane-r2.tsv" 't1\tctx-a\t1\t500\t20\t520' 't1\tctx-a\t0\t500\t500\t520' 't1\tctx-b\t0\t500\t1000\t1000'
	run --separate-stderr "$COMPARE" --results-dir "$S" --format md
	assert_success
	assert_output --partial "| Valid / total rows | 3/3 | 2/3 |"
	assert_output --regexp '\| Connected proxies / cluster \| 1000 \| 1000 \(\+0\.0%\) \|
\|   n \(got/attempted\) \| 2/2 \| 1/2 \(baseline n 2/2\) \|'
	refute_output --partial "760"
}

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

# PROP_HDR / prop_row: the propagation endpoint TSV (19 columns, as 002 writes it).
# prop_row <iteration> <remote> <p1_ms> <status> <p1_conv_p99_ms> [<p2_ms>]: p3 60 ms.
PROP_HDR=$'run_id\tmesh_size\titeration\tsource_ctx\tremote_ctx\tt0_epoch_ns\tp1_ms\tp2_ms\tp3_ms\tstatus\tp1_conv_p50_ms\tp1_conv_p99_ms\tp1_sample_count\tp1_proxy_count\tp1_overflow\trestarted\tp2_dirty\twindow_ms\tscrape_skew_ms'
prop_row() {
	local p2="${6:-50}" p3=60
	[[ "$4" == OK ]] || { p2=N/A p3=N/A; }
	printf 'r1\t2\t%s\tsrc\t%s\t0\t%s\t%s\t%s\t%s\t99\t%s\t10/10\t10\t0\t0\t0\t5000\t10\n' "$1" "$2" "$3" "$p2" "$p3" "$4" "$5"
}

@test "tuning 004: every metric shows n got/attempted and its range; a profile whose n differs is flagged (R12)" {
	P="${BATS_TEST_TMPDIR}/psweep"
	mkdir -p "${P}/baseline" "${P}/01-x"
	printf '# SUITE=propagation\n# PASSES=baseline,01-x\n' > "${P}/sweep-metadata.txt"
	{
		echo "$PROP_HDR"
		for v in 1 2 3 4; do prop_row "$v" b "${v}00" OK 99; done
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
		echo "$PROP_HDR"
		prop_row 1 b TIMEOUT TIMEOUT_P1 N/A
		prop_row 2 b TIMEOUT TIMEOUT_P1 N/A
	} > "${P}/baseline/endpoint-r1.tsv"
	run "$COMPARE" --results-dir "$P" --format md
	assert_success
	assert_output --partial "| P1 local push (ms) | - |"
	assert_output --partial "|   n (got/attempted) | 0/2 |"
	refute_output --partial "n differs from the baseline"
}

@test "tuning 004: a propagation pass counts what 005 counts: P1 once per iteration, the same n and mean (D2)" {
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
	assert_output --partial "| P1 local push (ms) | 350.00 |"
	assert_output --partial "| P2 remote EDS (ms) | 50.00 |"
	run "$COMPARE" --results-dir "$P" --format md
	# Without ITERATIONS in the preamble, P1 is attempted once per iteration the pass
	# wrote (7), not per row (17) (X2).
	[[ "$output" == *"| P1 local push (ms) | 350.00 |"$'\n'"|   n (got/attempted) | 6/7 |"* ]]
	[[ "$output" == *"| P2 remote EDS (ms) | 50.00 |"$'\n'"|   n (got/attempted) | 15/17 |"* ]]
	# 005 on the same rows: the same n and mean.
	run "${ROOT}/tests/propagation/005-report-results.sh" --results-dir "${P}/baseline" --format json
	assert_success
	[ "$(jq -c '[.rows[] | select(.phase == "P1_local_wall" or .phase == "P2_discovery") | [.phase, .n_valid, .avg_ms]]' <<<"$output")" = \
		'[["P1_local_wall",6,350],["P2_discovery",15,50]]' ]
}

@test "tuning 004: attempted is what the probe was configured to run, not the rows it wrote (D3, PL17)" {
	P="${BATS_TEST_TMPDIR}/psweep4"
	mkdir -p "${P}/baseline" "${P}/01-x"
	printf '# SUITE=propagation\n# PASSES=baseline,01-x\n' > "${P}/sweep-metadata.txt"
	local i r
	{
		printf '# RUN_ID=r1\n# ITERATIONS=4\n# REMOTES=b c\n'
		echo "$PROP_HDR"
		for i in 1 2 3 4; do for r in b c; do prop_row "$i" "$r" 100 OK 99; done; done
	} > "${P}/baseline/endpoint-r1.tsv"
	# The profile's probe stopped after 2 of its 4 iterations: 2/4, not 2/2.
	{
		printf '# RUN_ID=r2\n# ITERATIONS=4\n# REMOTES=b c\n'
		echo "$PROP_HDR"
		for i in 1 2; do for r in b c; do prop_row "$i" "$r" 100 OK 99; done; done
	} > "${P}/01-x/endpoint-r2.tsv"
	run "$COMPARE" --results-dir "$P" --format md
	assert_success
	[[ "$output" == *"| P1 local push (ms) | 100.00 | 100.00 (+0.0%) |"$'\n'"|   n (got/attempted) | 4/4 | 2/4 (baseline n 4/4) |"* ]]
	[[ "$output" == *"| P2 remote EDS (ms) | 50.00 | 50.00 (+0.0%) |"$'\n'"|   n (got/attempted) | 8/8 | 4/8 (baseline n 8/8) |"* ]]
	assert_output --partial "| Valid / total rows | 8/8 | 4/4 |"
	# churn: its Iterations line.
	C="${BATS_TEST_TMPDIR}/csweep"
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

@test "tuning 004: a propagation profile whose P1 convergence overflowed shows overflow (N iterations), never a better bucket (M2)" {
	P="${BATS_TEST_TMPDIR}/psweep5"
	mkdir -p "${P}/baseline" "${P}/01-x"
	printf '# SUITE=propagation\n# PASSES=baseline,01-x\n' > "${P}/sweep-metadata.txt"
	local i r
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
	# Without M2 the profile read 0-100 (better than the baseline's 500-1000) from its one
	# clean iteration.
	[[ "$output" == *"| P1 convergence p99 worst bucket (ms) | 500-1000 | overflow (3 iterations) |"$'\n'"|   n (got/attempted) | 5/5 | 4/5 (baseline n 5/5) |"* ]]
	assert_output --partial "overflow (N iterations)"
	run "$COMPARE" --results-dir "$P"
	assert_output --regexp 'P1 convergence p99 worst bucket \(ms\) +500-1000 +overflow \(3 iterations\)'
	# One overflowed iteration reads singular.
	awk -F'\t' 'BEGIN { OFS = "\t" } $3 == 3 || $3 == 4 { $15 = 0 } 1' "${P}/01-x/endpoint-r2.tsv" > "${P}/x.tsv"
	mv "${P}/x.tsv" "${P}/01-x/endpoint-r2.tsv"
	run "$COMPARE" --results-dir "$P" --format md
	assert_output --partial "| overflow (1 iteration) |"
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
	# In the tuning's own words: passes, marker files, Pass status (C4).
	[[ "$stderr" == *"error: 2 of 2 passes failed: PROBE_FAILED x1, SETUP_FAILED x1. Each has its marker file in its pass directory, and its Pass status in sweep-comparison.md names it; exit 4." ]]
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
	# R2: nothing was not ready (it could not be read at all), so nobody was waited for.
	grep -qx '# ISTIO_NOTREADY_AT_START=none' "${d}/sweep-metadata.txt"
	grep -qx '# ISTIO_READY_WAITED_SEC=0' "${d}/sweep-metadata.txt"
	grep -qx -- '- Start-of-run readiness: ISTIO_NOTREADY_AT_START=none, ISTIO_READY_WAITED_SEC=0' "${d}/sweep-comparison.md"
	# The probe inherited the sweep's reading: the Istio CR is read at the start and again
	# at the end (A6), each a read and its one retry; never by the probe.
	[ "$(grep -c 'get istios.sailoperator.io default' "$STUB_LOG")" -eq 4 ]
	# The outcome stays with the results (C3).
	grep -qx 'EXIT=4' "${d}/sweep-outcome.txt"
	grep -qx 'UNIT=passes' "${d}/sweep-outcome.txt"
	grep -qx '## Sweep outcome' "${d}/sweep-comparison.md"
}

@test "tuning 003 --suite controlplane without timeout or gtimeout: stops at startup, before any profile or kubectl call (C1, R17)" {
	# A PATH with every tool but timeout and gtimeout, a python3 that passes the PyYAML
	# check, and a kubectl that logs its calls.
	local d="${BATS_TEST_TMPDIR}/path" out="${BATS_TEST_TMPDIR}/res" p f n
	mkdir -p "$d"
	local IFS=:
	for p in $PATH; do
		[[ -d "$p" ]] || continue
		for f in "$p"/*; do
			n="${f##*/}"
			[[ -x "$f" && ! -e "${d}/${n}" && "$n" != timeout && "$n" != gtimeout ]] && ln -s "$f" "${d}/${n}"
		done
	done
	unset IFS
	rm -f "${d}/kubectl" "${d}/oc" "${d}/python3"
	export STUB_LOG="${BATS_TEST_TMPDIR}/kubectl.log"
	printf '#!/bin/sh
[ "$*" = "-I -c import yaml" ] && exit 0
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
	[[ "$stderr" == *"error: neither 'timeout' nor 'gtimeout' (GNU coreutils) is on PATH"*"On macOS: brew install coreutils"* ]]
	[ ! -s "$STUB_LOG" ]
	[ -z "$(find "$out" -name 'sweep-metadata.txt' 2>/dev/null)" ]
	# Another suite does not need it: the sweep goes on to its first kubectl call (the Istio
	# version read, which fails here and stops it under ISTIO_VERSION_CHECK=fail).
	PATH="$d" run --separate-stderr "${ROOT}/tests/tuning/003-run-tuning-sweep.sh" \
		--suite churn --contexts ci-a --no-gitops-pause --skip-setup --keep-workloads \
		--profiles 01-push-throttling --settle 0 --output-dir "$out"
	assert_failure 1
	[[ "$stderr" != *"timeout"*"gtimeout"* ]]
	[[ "$stderr" == *"cannot read the running Istio version on 1 of 1 members"* ]]
	[ -s "$STUB_LOG" ]
}
